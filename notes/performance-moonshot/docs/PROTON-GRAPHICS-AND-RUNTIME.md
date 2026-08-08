# Proton's graphics and runtime work, judged for a DAW under Wine

This document helps the reader decide which of Valve Proton's performance
techniques are worth adopting for ableton-wine, and which are game-only and
can be ignored. It covers DXVK, vkd3d-proton, DXVK-NVAPI, Fossilize shader
pre-caching, Proton's compiler flags, allocator and large-page work, FAudio
versus winepulse, Proton-GE additions, the pressure-vessel container, and
frame-latency work, then maps each onto what Ableton Live and its plugin
editors actually do in this stack.

Terms used below: a *translation layer* reimplements one graphics API on top
of another (Direct3D on Vulkan, or Direct3D on OpenGL). A *present* is the
step where a finished frame is handed to the display; a *swapchain* is the
queue of frames behind a present. A *shader* is a small GPU program an app
compiles at runtime; *shader pre-caching* compiles them before launch.

## What Proton is, in 2026

Proton is Valve's Wine fork for games, shipped through Steam with a graphics
stack (DXVK, vkd3d-proton, DXVK-NVAPI), a container runtime
(pressure-vessel), and per-game workarounds. Proton 11 shipped around
2026-04 with ARM64 support via the FEX emulator
([igor'sLAB](https://www.igorslab.de/en/the-new-proton-update-now-includes-support-for-arm64-devices-as-well-as-other-new-features/)).
Its community fork GE-Proton is at GE-Proton11-1 (2026-06-24, per
[shattered.io](https://shattered.io/heroic-vs-lutris/); see the
[releases page](https://github.com/GloriousEggroll/proton-ge-custom/releases)).

Proton optimizes one workload: fullscreen 3D games that render thousands of
GPU-bound frames per second through D3D9-12. A DAW is the opposite
workload: a 2D UI that must not stall, an audio engine that must never
miss a deadline, and plugin windows that mix OpenGL, D3D, and embedded
Chromium. That difference decides every verdict below.

## The graphics stack this project already runs

Facts about the current stack, from this repository:

- Live's own UI uses its Direct2D/Direct3D 11 renderer on Wine's built-in
  wined3d, which translates D3D11 to OpenGL
  (`notes/ABLETON-WINE-GPU-RENDERER.md:8-12`).
- Presents of Live's main window take a direct GL path: patch 0055 marks
  top-level swapchains `WINED3D_SWAPCHAIN_PREFER_GL_PRESENT` and Wine shows
  frames with `glXSwapBuffers`, skipping a 14 MB-per-frame GPU-to-CPU copy
  that cost about 650 MB/s of display traffic
  (`notes/ABLETON-WINE-GPU-RENDERER.md:64-86`). Patches 0058 and 0059 keep
  that path correct under fractional scaling
  (`notes/ABLETON-WINE-GPU-RENDERER.md:99-171`).
- WebView2 panes (Learn View, Splice) are software-rendered: Live hardcodes
  `--disable-gpu --disable-gpu-compositing --disable-direct-composition`
  into its browser processes
  (`notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md:14-16`). No GPU
  translation layer can accelerate them.
- OpenGL plugin editors (JUCE/OpenGL, e.g. CHOW Tape Model) render through
  GLX directly and are composited by winex11; the crash fixed by patch 0026
  was an X11 depth mismatch, not a translation-layer problem
  (`notes/ABLETON-WINE-GL-PLUGIN-EDITOR-CRASH-BUG.md:21-36`).
- WebView2 plugin editors (Splice INSTRUMENT) crash on an OLE drag-drop
  pointer, fixed in ole32 by patch 0045, again not a graphics problem
  (`notes/ABLETON-WINE-WEBVIEW2-PLUGIN-CLOSE-CRASH.md:10-24`).
- The audio engine does not touch Wine's audio drivers: it runs ASIO through
  PipeASIO into PipeWire (`scripts/ableton-live:760-762`,
  `scripts/container-build.sh:131-176`).
- Synchronization already runs on ntsync, the kernel driver that grew out of
  Proton's esync/fsync work (`notes/ABLETON-WINE-NTSYNC-REGRESSION.md:10-14`,
  `scripts/container-build.sh:104-123`).

## DXVK

DXVK reimplements D3D9/10/11 on Vulkan. It is the single biggest
performance lever Proton has for games. Current release is 2.7.1
(2025-08-30); the next release was already overdue in 2026-01
([DXVK issue 5433](https://github.com/doitsujin/dxvk/issues/5433),
[Debian package tracker](https://tracker.debian.org/dxvk)). DXVK 2.7
deprecated its descriptor-buffer path and requires current drivers
([DXVK releases](https://github.com/doitsujin/dxvk/releases)).

Relevance here: partial, and unproven. Live's UI is D3D11, so DXVK could in
principle replace the wined3d-GL translation. wined3d serializes rendering
on one command-stream thread (the "CS thread" of
`notes/ABLETON-WINE-GPU-RENDERER.md:108-116`); DXVK's submission model is
more parallel, and its per-frame CPU cost is lower for heavy D3D11
workloads. Live's UI is not a heavy D3D11 workload (it is a 2D desktop
UI), so the expected gain is smaller than in games and may be near zero.

Risks are concrete, not theoretical:

- Patch 0055's direct GL present, and gates 0058/0059, live in wined3d's GL
  swapchain path. Under DXVK, d3d11 presents go through Vulkan swapchains
  instead; all three patches become dead code, and the 650 MB/s copy
  problem they solved (issue 91) needs a new answer.
- Live gates its GPU renderer on the device name wined3d reports, and this
  project ships patches 0057/0061 to pass that check
  (`notes/ABLETON-WINE-GPU-RENDERER.md:173-202`). DXVK reports adapter
  names from Vulkan instead. Unverified: whether Live's check passes under
  DXVK, on every GPU family this project supports.
- DXVK requires a working Vulkan driver; the GDI fallback and the
  wined3d-GL path work everywhere. A Vulkan failure would grey out or break
  the UI on machines that work today.

Cheaper experiment first: wined3d has its own Vulkan backend, selectable
without swapping DLLs. Unverified: whether that backend works with Live's
D2D usage and with the dcomp patches (0041). Either way, the test is a
prefix-level A/B (the vendored winetricks already carries dxvk verbs,
`vendor/winetricks:6887-6900`) and does not require a rebuild.

## vkd3d-proton

vkd3d-proton reimplements D3D12 on Vulkan. Current release is 3.0.1
(2026-05), which added experimental view instancing and Vulkan present
timing ([Phoronix](https://www.phoronix.com/news/VKD3D-Proton-3.0.1));
3.0 (2025-11) brought FSR4 support and a DXBC shader-backend rewrite
([9to5Linux](https://9to5linux.com/vkd3d-proton-3-0-released-with-fsr4-support-dxbc-shader-backend-rewrite)).

This does not apply. Live's renderer is D3D11, not D3D12
(`notes/ABLETON-WINE-GPU-RENDERER.md:11-12`). No mainstream VST plugin
editor uses D3D12. Unverified: whether any future plugin editor (game-engine
-based UIs) will need D3D12; worth a watch item, not work now.

## DXVK-NVAPI

DXVK-NVAPI implements NVIDIA's NVAPI (driver feature library: GPU queries,
Reflex latency reduction, DLSS hooks) on top of DXVK/Vulkan. It is actively
maintained: 0.9.1 shipped 2026-01 and 0.9.2 followed in 2026-05 with
experimental D3D12 shader extensions
([Phoronix Linux gaming archive](https://www.phoronix.com/linux/Linux+Gaming),
[dxvk-nvapi releases](https://github.com/jp7677/dxvk-nvapi/releases)).

This does not apply. NVAPI's features target games (latency reduction for
competitive play, upscaling). A DAW UI has no use for them, and the project
already solves its NVIDIA-specific problems in Wine itself.

## Shader pre-caching (Fossilize)

Fossilize is Valve's Vulkan pipeline recorder/replayer. Steam records the
Vulkan pipelines a game creates, ships them to other machines, and compiles
them before the game starts, removing first-run shader-compile stutter
([Fossilize repository](https://github.com/ValveSoftware/Fossilize)). It is
still Steam's mechanism in 2026, with known rough edges on NVIDIA
([NVIDIA developer forum, 2026-02](https://forums.developer.nvidia.com/t/steam-fossilize-doesnt-seem-to-work-on-nvidia-cards/359282)).

This does not apply. Fossilize only records Vulkan pipelines. This stack's
GPU work goes through OpenGL (wined3d-GL, GLX plugin editors), and the
WebView2 panes are software-rendered
(`notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md:14-16`). wined3d
already keeps its own on-disk GLSL shader cache. Live's UI uses a small,
fixed set of shaders; game-scale shader stutter does not exist here. If
DXVK is ever adopted (see DXVK section), DXVK's own state cache plus
Mesa's driver cache cover the same ground without Fossilize.

## Proton's compiler flags and build optimizations

Verified from the Proton source tree (branch `proton_10.0`, commit
`e91ca2be`, 2026-07-27; [Makefile.in](https://github.com/ValveSoftware/Proton/blob/proton_10.0/Makefile.in)):

| Setting | Proton 10 value | Evidence |
|---|---|---|
| Optimization | `-O2 -fwrapv -fno-strict-aliasing` | Makefile.in:59 |
| Arch tuning | `-march=nocona -mtune=core-avx2 -mfpmath=sse` (plus `-mstackrealign` i386, `-mcmodel=small` x86_64) | Makefile.in:56-57 |
| Debug info | `-ggdb -ffunction-sections -fdata-sections -fno-omit-frame-pointer`; stripped at install | Makefile.in:60, 44-51 |
| LTO | Not enabled for Wine; explicitly disabled for vkd3d ("causes the build to fail") | Makefile.in:669-671 |
| PGO | None found | whole-tree grep, unverified beyond `proton_10.0` |

Valve builds for the oldest x86-64 (nocona is the 2004 baseline) with a
modern tuning target, at `-O2`, without LTO or PGO. Downstream forks go
further: proton-cachyos ships `-O2 -march=x86-64-v3` and `-O3` LLVM
variants ([proton-cachyos CI, 2026-02](https://github.com/CachyOS/proton-cachyos/actions/runs/21804618854)).

This project currently passes no CFLAGS at all: `scripts/container-build.sh:53-56`
runs configure with only the ntsync `CPPFLAGS`, so Wine's own defaults
apply; PipeASIO is built `-O2 -DNDEBUG`
(`scripts/container-build.sh:151-158`). The toolchain is gcc for the Unix
side, pinned clang 21/lld for the PE side (`Containerfile:37-42`), and the
output is stripped (`scripts/container-build.sh:183-186`).

Judgment: Proton's flags are a conservative, proven baseline this project
can match for free, and the arch tuning is the one real delta. Caveat: most
CPU in a Live session burns inside `Live.exe` and plugin code, not inside
Wine's DLLs. Flags only speed up Wine's own code paths (wined3d translation,
dcomp blits, wineserver, heap). Expected gain is small and must be measured
with the project's existing probes, not assumed.

## Memory allocator and large pages

Proton does not replace Wine's allocator. Its allocator-adjacent options
are game workarounds, not optimizations: `PROTON_HEAP_DELAY_FREE` delays
frees to mask use-after-free bugs, and `PROTON_FORCE_LARGE_ADDRESS_AWARE`
sets a PE header flag ([GE-Proton README](https://github.com/GloriousEggroll/proton-ge-custom/blob/master/README.md)).
Neither speeds anything up.

On large pages: a request for transparent huge page (THP) support in Proton
has existed since 2022 ([Proton issue 5816](https://github.com/ValveSoftware/Proton/issues/5816)).
Unverified: its current state as of 2026-08 (GitHub API was rate-limited at
research time); no shipped Proton or Wine release implements large-page PE
mappings. There is nothing finished to adopt. A THP experiment is still
possible at the OS level (see Key opportunities): Live plus its plugins
hold multi-GB sample and DSP buffers in ordinary malloc memory, where 2 MB
pages cut TLB misses. Whether that matters for Live's worst-case audio
deadline is unknown until measured.

## FAudio versus winepulse

These are different layers that Proton comparisons often conflate:

- FAudio reimplements Microsoft's XAudio2 API. Wine has carried it in-tree
  since Wine 4.3 (2019)
  ([GamingOnLinux](https://www.gamingonlinux.com/2019/03/wine-43-is-out-with-the-xaudio2-reimplementation-faudio-included/)),
  and standalone FAudio releases continued at least through 25.09
  ([AUR faudio package](https://aur.archlinux.org/packages/faudio)).
  Games use XAudio2; Live does not.
- winepulse is Wine's mmdevapi (WASAPI) backend that talks to
  PulseAudio/PipeWire. This build includes it for Wine's own audio
  (`Containerfile:55-58`).

Neither is on the DAW's performance path. Live's engine opens the ASIO
device from PipeASIO, a native PipeWire client with no JACK layer
(`scripts/ableton-live:760-762`). winepulse only carries incidental sound:
WebView2 pane audio, plugin UIs that play preview audio through WASAPI.
There is nothing to optimize here; the Proton FAudio question is a
non-issue for this project.

## Proton-GE additions

GE-Proton adds, on top of Valve's Proton
([GE-Proton README](https://github.com/GloriousEggroll/proton-ge-custom/blob/master/README.md)):

| Addition | Purpose | Applies to a DAW? |
|---|---|---|
| Media Foundation patches | game video cutscenes | Only marginally. Live's media import already works through winegstreamer (`scripts/container-build.sh:96-102`) |
| `WINE_FULLSCREEN_FSR` upscaling | game rendering | No |
| NVIDIA CUDA / PhysX / NVAPI | game physics, DLSS | No |
| Raw input patches | game mouse input | No. MIDI and mouse already work; see `notes/ABLETON-WINE-INPUT-BUG.md` for the actual input work |
| protonfixes per-game fixes | game-specific hacks | The pattern applies (this repo's patch series is the same idea), the content does not |
| wine-staging backports | assorted | Case by case; this repo already curates its own series |
| NTSync enablement | synchronization | Already done here (`notes/ABLETON-WINE-NTSYNC-REGRESSION.md:50-56`) |

GE-Proton itself is not a candidate runtime: it targets games inside
Steam's container, and running it outside Steam is only supported through
umu with the full container environment (same README).

## The pressure-vessel container runtime

pressure-vessel is the container launcher that runs Proton against Steam
Linux Runtime, a fixed library set, so games see identical libraries on
every distribution ([Valve's steam-runtime known-issues doc](https://github.com/ValveSoftware/steam-runtime/blob/master/doc/steamlinuxruntime-known-issues.md)).
It is actively developed: Steam Linux Runtime 3.0 (sniper) was updated in
2026-06 including arm64 pressure-vessel builds
([SteamDB patch notes, 2026-06-03](https://steamdb.info/patchnotes/23181402/)).

This solves a problem the project already solved differently. The build is
fully pinned (base image digest, Ubuntu snapshot, exact LLVM package,
sha256-checked vendored inputs; `Containerfile:1-19`) and ships a
relocatable tarball proven by a relocation gate
(`build.sh:15-17`, `scripts/container-build.sh:240-265`). A DAW makes the
container trade worse than a game does: the runtime must reach the host's
PipeWire sockets, ALSA MIDI devices, USB (Push 2), real-time scheduling,
and the XDG file portal. Every one of those is a hole punched through the
container or a failure mode. Containerizing would add namespace setup to
startup and a new class of device bugs, in exchange for library isolation
the pinned build already provides. Do not adopt.

## Frame-latency work

Proton's frame-latency work targets games: DXVK's `maxFrameLatency` and
frame-rate limiter, vkd3d-proton 3.0.1's Vulkan present timing
([Phoronix](https://www.phoronix.com/news/VKD3D-Proton-3.0.1)), and
gamescope, Valve's nested compositor for fullscreen presentation. Present
timing lets an app schedule exactly when a frame lands.

For a DAW, the latency that matters is the audio callback deadline, which
none of this touches. UI frame latency affects feel, not correctness. This
project's own present-path work (the direct GL present of patch 0055 with
the 0058/0059 gates) is the equivalent optimization, already done and
measured (`notes/ABLETON-WINE-GPU-RENDERER.md:158-171`). Present timing
only exists for Vulkan, so it becomes relevant only if the DXVK experiment
lands. Gamescope does not apply: Live is a multi-window desktop app with
plugin-editor windows, portals, and WebView2 children, not a single
fullscreen surface.

## What applies and what does not

| Proton technique | Verdict for ableton-wine | One-line reason |
|---|---|---|
| DXVK (D3D11→Vulkan) | Worth one measured A/B, unproven | Live's UI is D3D11, but patches 0055/0058/0059 and the device check assume wined3d |
| wined3d Vulkan backend | Cheaper A/B than DXVK | Same translation goal, no DLL swap; compatibility unverified |
| vkd3d-proton | Does not apply | No D3D12 anywhere in this workload |
| DXVK-NVAPI | Does not apply | Game latency/upscaling features |
| Fossilize pre-caching | Does not apply | Vulkan-only; no shader-stutter problem exists here |
| Proton compiler flags | Adopt the baseline, test arch tuning | `-O2`/nocona/core-avx2 is proven; this build passes no CFLAGS at all |
| LTO / PGO | Not a proven lever | Valve avoids LTO; no PGO exists upstream |
| Allocator swap | Nothing to adopt | Proton's heap options are game bug workarounds |
| Large pages (THP) | OS-level experiment only | No upstream implementation exists; benefit unverified |
| FAudio / winepulse | Does not apply | Audio runs ASIO→PipeASIO→PipeWire, outside both |
| GE-Proton additions | Reject as a runtime | Game-targeted; Steam-container oriented |
| pressure-vessel | Do not adopt | Pinned relocatable tarball already solves isolation; DAW needs host devices |
| Frame-latency / gamescope | Does not apply (except as DXVK follow-up) | Equivalent present-path work already shipped in 0055/0058/0059 |
| ntsync lineage | Already shipped | `notes/ABLETON-WINE-NTSYNC-REGRESSION.md` |

## Key opportunities

1. **Match and extend Proton's compiler flags in the container build.**
   Add Proton's baseline (`-O2 -fwrapv -fno-strict-aliasing
   -march=nocona -mtune=core-avx2 -mfpmath=sse`) to the Wine configure in
   `scripts/container-build.sh:53-56`, then benchmark an
   `-march=x86-64-v2` or v3 variant against it using the existing probes
   (`beta/tester-kit/probes/src/ntsyncprobe.c`, the present-bandwidth
   measurement from issue 91). Impact: low to medium (Wine-internal code
   only). Effort: low. Evidence: Proton's verified flags at
   [Makefile.in:56-60](https://github.com/ValveSoftware/Proton/blob/proton_10.0/Makefile.in)
   versus no CFLAGS in `scripts/container-build.sh:53-56`.
2. **A/B test DXVK for Live's D3D11 UI on a prefix copy, with the
   wined3d Vulkan backend as the cheaper first step.** Measure Live CPU
   during continuous UI activity against the numbers in
   `notes/ABLETON-WINE-GPU-RENDERER.md:158-171`, check the device-name gate
   (`notes/ABLETON-WINE-GPU-RENDERER.md:173-202`), and verify the WebView2
   panes and GL plugin editors. Abandon if the check greys out or the
   panes regress. Impact: medium if it works, likely low. Effort: medium
   (prefix-level, no rebuild; `vendor/winetricks:6887-6900` has dxvk
   verbs). Evidence: DXVK's parallel submission versus wined3d's single CS
   thread (`notes/ABLETON-WINE-GPU-RENDERER.md:108-116`).
3. **Run a transparent-huge-pages experiment on the audio workload.**
   Compare Live's audio-thread xrun count and `perf` TLB-miss rates with
   THP `madvise` mode versus `never`, on a large session. If it helps,
   ship a launcher-side prctl/madvise wrapper rather than a system-wide
   change. Impact: low to medium, unverified. Effort: low. Evidence: no
   upstream implementation exists to copy
   ([Proton issue 5816](https://github.com/ValveSoftware/Proton/issues/5816));
   Live holds multi-GB sample buffers in normal pages.
4. **Skip, on the record: vkd3d-proton, DXVK-NVAPI, Fossilize, FAudio
   work, GE-Proton as a runtime, pressure-vessel, and gamescope.** Spending
   no effort here is itself a decision this document supports; each is
   game-only or already solved by the pinned tarball and PipeASIO
   (`scripts/container-build.sh:240-265`, `scripts/ableton-live:760-762`).
   Impact: high (saved effort). Effort: none. Evidence: the verdict table
   above.
5. **Track vkd3d-proton's present timing as a watch item, not work.** It
   matters only if the DXVK experiment (item 2) lands and UI frame pacing
   ever measures as a problem. Impact: low. Effort: none beyond reading
   release notes. Evidence: vkd3d-proton 3.0.1 added Vulkan present timing
   ([Phoronix](https://www.phoronix.com/news/VKD3D-Proton-3.0.1)).
