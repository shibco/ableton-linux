# Performance Moonshot: research and opportunity map

This document records what determines speed and stability for Ableton Live
under this Wine fork, and lists the highest-leverage changes to try. It is a
research input, not a plan of record. Each opportunity carries a confidence
level and a first verification step. Date: 2026-08-01.

## Scope and method

Four investigations ran in parallel:

1. The technologies this Wine fork uses, read from the repository.
2. How Ableton Live works internally, read from Ableton's public documentation.
3. Valve's Proton performance techniques, read from Proton and kernel sources.
4. Other Wine forks and Linux audio work, read from their repositories.

Findings that need a trace or a build before they become claims are marked
**unverified**. Findings confirmed by a note or a patch in this repository are
marked **confirmed**. Web sources appear inline.

## Technologies this fork uses

The fork builds from `giang17/wine` branch `d2d1-dcomp-11.13`, commit
`5c23dd1c` (see [`patches/BASE.txt`](../patches/BASE.txt)). The build runs in a
pinned Podman container on Ubuntu 22.04, with Clang and LLD 21 building the PE
(Windows) side and GCC building the Unix side. Every input is pinned by digest
and checksum.

| Area | Component | Notes |
|---|---|---|
| Sync primitives | ntsync | Kernel driver via `/dev/ntsync`; header vendored. `WINEESYNC` and `WINEFSYNC` are unset. **confirmed** |
| Graphics | wined3d, OpenGL | `WINE_D3D_CONFIG=csmt=0x1` enables command-stream multithreading. DXVK and VKD3D are not used. **confirmed** |
| Graphics | Direct2D + DirectComposition | The `d2d1-dcomp` base stack drives Live's GPU renderer and WebView2 compositing. **confirmed** |
| Present path | Direct GL present | Patches 0055, 0058, 0059 route top-level swapchains through `glXSwapBuffers`, skipping a frame copy. **confirmed** |
| Audio | PipeASIO 1.2.2 | Native PipeWire ASIO driver. Replaces WineASIO. Links `libpipewire-0.3.so.0` at runtime. **confirmed** |
| Audio fallback | winealsa, winepulse | ALSA carries MIDI; pulse is Wine's own driver. **confirmed** |
| Audio scheduling | SCHED_RR 10 process, SCHED_FIFO 15 PipeASIO | Launcher starts the whole process under round-robin priority 10. **confirmed** |
| Media | GStreamer | mp3 and video import. Host plugins decode at runtime. **confirmed** |
| CPU reporting | WINE_CPU_TOPOLOGY | Launcher caps the reported CPU count at eight, honouring the host cpuset. **confirmed** |
| Hardware | libusb bridge | x86-64 host libusb shim for the Push 2 display. **confirmed** |
| Networking | Ableton Link 4.0 | Vendored daemon joins as a native peer; Wine multicast passes through. **confirmed** |
| Tracing | `WINEDEBUG=-all` | Default in the launcher. **confirmed** |

## How Ableton Live works

Ableton does not publish Live's internals. The statements below come from the
Live 11 and 12 release notes and help articles. Anything Ableton does not state
is marked **unverified**.

### Threading

Live 12 can create up to 32 real-time audio threads on Windows, and the
`-EnableRealTimeWorkQueue` flag raises that to 64. The scheduling mechanism
(MMCSS "Pro Audio" via the AVRT API) is not documented. **unverified**
Source: https://www.ableton.com/en/release-notes/live-12/

### Audio

Live offers ASIO, MME, DirectSound, and Direct Capture drivers on Windows. ASIO
is the recommended path and is a hard requirement for Ableton Link on Windows.
WASAPI is not offered as a driver type. Buffer sizes are powers of two; 44.1 and
48 kHz are recommended. Source: https://help.ableton.com/hc/en-us/articles/360003149240

### Graphics

Live 12.2 added a Windows GPU renderer (Settings > Display & Input). Live
synchronises with the Desktop Window Manager. The exact API set (Direct2D 1.1,
Direct3D 11, DirectWrite, DirectComposition) is not named by Ableton; the
behaviour observed in this fork matches Direct2D on Direct3D 11 with
DirectComposition. **unverified** Source: https://www.ableton.com/en/release-notes/live-12/

### WebView2

A Microsoft Edge WebView hosts the Learn View and Splice panels on Windows.
Source: https://www.ableton.com/en/release-notes/live-12/

### Plugin hosting

Live hosts VST2 and VST3 on Windows. Whether hosting is in-process or
out-of-process is not documented. **unverified** JUCE-based VST3 editors with
OpenGL are confirmed working under this fork
([ABLETON-WINE-GL-PLUGIN-EDITOR-CRASH-BUG.md](ABLETON-WINE-GL-PLUGIN-EDITOR-CRASH-BUG.md)).

### Push 2 hardware

Push 2 is a USB 2.0 composite device: one MIDI port and one bulk interface for
the 960x160 RGB display. The display is driven through libusb. Source:
https://github.com/Ableton/push-interface

### Media formats

Live 12 decodes WAV, AIFF, FLAC, Ogg Vorbis, and MP3 natively. MP3 decoding
moved in-tree for Live 12 (Live 11 used a Windows ACM codec). Video import uses
Windows Media Foundation in Live 12; Live 11 used DirectShow with the Haali
splitter. GStreamer is not used by Live itself. Source:
https://help.ableton.com/hc/en-us/articles/211427589

### Hardware requirements

Live 12 requires an AVX2-capable CPU, Windows 10 22H2 or Windows 11, and 8 GB
RAM. Source: https://help.ableton.com/hc/en-us/articles/115001663530

### Linux stance

Ableton lists Windows and macOS only. There is no official Linux support and no
stated port plan. **confirmed**

### The `-DontCombineAPCs` flag needs verification

Ableton's documented definition of `-DontCombineAPCs` is about Akai APC
hardware controllers ("won't align and sync the session rings of multiple
APCs"), not Windows asynchronous procedure calls. Source:
https://help.ableton.com/hc/en-us/articles/6003224107292

The note [ABLETON-WINE-APC-COALESCING.md](ABLETON-WINE-APC-COALESCING.md)
records a measured idle CPU thread and a playback regression when the flag is
removed. Those measurements are real, but the flag's documented purpose does not
match the mechanism the note assumes. The first step before any APC work is to
trace an idle session with `WINEDEBUG=+server` and confirm what the busy thread
actually does. **unverified**

## Proton techniques and DAW applicability

Valve's Proton optimises games. The table lists each technique, its gain, its
requirement, and whether it applies to a realtime audio application.

| Technique | What it does | Requirement | Applies to a DAW |
|---|---|---|---|
| ntsync | Handles NT sync waits in the kernel, removing wineserver round trips. Merged mainline in Linux 6.14. 4-50x sync throughput over the fallback in this fork's own measurement. | Linux >= 6.14, `CONFIG_NTSYNC` | Yes. Already used. |
| fsync, esync | Predecessors of ntsync. fsync uses `FUTEX_WAIT_MULTIPLE`; esync uses eventfd. | Staging or Proton Wine | Only on kernels below 6.14. This fork unsets both in favour of ntsync. |
| Modern wow64 | Runs the 32-bit `ntdll.dll` inside the 64-bit process. Fewer syscalls and context switches for 32-bit code. | Wine 9.0+ | Yes, for 32-bit plugin hosting. |
| DXVK | Translates Direct3D 9, 10, 11 to Vulkan. Steadier rendering than OpenGL on modern GPUs. | Vulkan driver | Candidate. See the opportunity below. |
| VKD3D-Proton | Translates Direct3D 12 to Vulkan. | Vulkan driver | Low. Live does not use Direct3D 12. |
| CPU pinning and cap | Reports a chosen CPU count and topology to the app, skipping SMT siblings. | `WINE_CPU_TOPOLOGY` | Yes. Already capped at eight. |
| Large address aware | Gives the process more than 2 GB of address space. | Flag at launch | Yes. |
| `WINEDEBUG=-all` | Removes logging overhead. | Env var | Yes. Already set. |
| Feral GameMode | CPU governor, GPU performance mode, I/O priority. | Daemon | Partial. GPU mode is irrelevant; governor is host-side. |
| Gamescope | Micro-compositor with direct DRM flips. | Compositor | Low. A windowed DAW needs the desktop. |
| LatencyFleX | Frame-input latency sync. | Driver | No. Designed for games and adds microstutter. |

Proton ships no audio tuning. Steam Deck audio runs on a standard PipeWire
stack. Realtime audio behaviour comes from the host, not from Proton.

Sources: https://www.kernel.org/doc/html/latest/userspace-api/ntsync.html ,
https://github.com/ValveSoftware/Proton/blob/proton_9.0/README.md ,
https://github.com/ValveSoftware/wine/blob/experimental_9.0/dlls/ntdll/unix/system.c ,
https://github.com/doitsujin/dxvk

## Other Wine forks and borrowable work

| Fork or project | Distinctive change | Borrowable here | Conflict |
|---|---|---|---|
| GE-Proton | Media Foundation patches, ntsync enablement, raw input. | Media Foundation for video and WMA import. | FShack fullscreen breaks windowed DAW work and plugin GUIs. |
| wine-staging | `ntdll-APC_Performance`, `server-PeekMessage`, `server-Signal_Thread`, `ntdll-WRITECOPY`, `mfplat-streaming-support`. | The ntdll and server patches; mfplat for media. | Must rebase against the d2d1-dcomp base. |
| giang17/wine `d2d1-dcomp` | Direct2D 1.1 and DirectComposition enablement. | Already the base. | None. |
| wine-tkg-git | Configurable Wine with fsync and FUTEX2. | fsync on pre-6.14 kernels. | Default fshack breaks plugin GUIs. |
| WineASIO | ASIO to JACK bridge. | Pattern. PipeASIO already replaces it. | None. |
| yabridge | Out-of-process VST2, VST3, and CLAP bridge for native Linux hosts. | Realtime setup checklist: `chrt`, preempt kernel, rtirq, performance governor. | Applies to native hosts, not to Live itself. |
| CodeWeavers CrossOver | New wow64, PE DLL conversions, Direct2D and DComp fixes. | Upstream into Wine over time. | None. |

The native PipeWire Wine audio backend is not merged upstream as of Wine 9 to
10. This fork uses the PipeASIO ASIO shim, which is the working substitute.

PREEMPT_RT merged into Linux mainline in 6.12 (November 2024). A `preempt=full`
kernel no longer needs a separate patchset. Source: https://www.kernel.org/

Sources: https://github.com/GloriousEggroll/proton-ge-custom ,
https://github.com/wine-staging/wine-staging ,
https://github.com/wineasio/wineasio ,
https://github.com/robbert-vdh/yabridge ,
https://gitlab.freedesktop.org/pipewire/pipewire

## Opportunities in this fork

Each opportunity names the area, the change, the expected effect, a confidence
level, and a first step.

### Evaluate DXVK for Live's Direct2D and Direct3D 11 UI

Live's GPU renderer runs through wined3d on OpenGL. DXVK translates Direct3D
11 to Vulkan and, on modern GPU drivers, holds a steadier frame and uses less
CPU than the OpenGL path. Confidence: **unverified**. The d2d1-dcomp base is
written against Wine's own d3d11 and d2d1, so DXVK may regress DirectComposition
and WebView2 compositing. First step: build a one-off prefix with DXVK's
`d3d11.dll`, `dxgi.dll`, and `d3d10core.dll` overriding the built-ins, then run
the existing GL-present benchmark against the reference set. Track regressions
in the Learn View, Splice view, and plugin editors.

### Confirm the busy idle thread and fix its real cause

The idle CPU thread documented in
[ABLETON-WINE-APC-COALESCING.md](ABLETON-WINE-APC-COALESCING.md) uses 30 to 40
percent of one core. ntsync does not accelerate alertable waits or APC delivery,
so those still cross wineserver. Confidence: **unverified cause**. First step:
trace an idle session at 256 frames with `WINEDEBUG=+server`, then count
`select` and `queue_apc` calls on the busy thread. Match the trace to the flag
Ableton actually documents before writing a patch.

### Backport staging ntdll and server patches

The `ntdll-APC_Performance`, `server-PeekMessage`, and
`server-Signal_Thread` staging patches cut wineserver calls and message-loop
latency. Confidence: **unverified against this base**. First step: port each
patch onto `d2d1-dcomp-11.13` in isolation, run the tester kit, and record a
`bench-run.sh` pair.

### Require ntsync at runtime and warn when the kernel lacks it

The build requires the header, but a user on a kernel below 6.14, or one without
`CONFIG_NTSYNC`, silently falls back to wineserver round trips. This fork's own
probe measured 45 percent wineserver CPU and 9000 context switches per second on
the fallback. Confidence: **confirmed regression**. First step: extend the
launcher to detect `/dev/ntsync` and print a one-line warning when it is absent,
pointing at the kernel requirement.

### Measure and narrow the realtime policy

The launcher starts the whole process under `SCHED_RR` priority 10. The note
[ABLETON-WINE-RT-SCHEDULING.md](ABLETON-WINE-RT-SCHEDULING.md) lists three
untested risks on low-core systems, including Live threads outranking the
`SCHED_OTHER` wineserver they call synchronously. Confidence: **unverified**.
First step: run the documented four-core comparison with `bench-run.sh`, then
decide whether to narrow RR to the audio and render threads only.

### Pin audio and render threads to disjoint cores

PipeASIO takes `SCHED_FIFO` 15 on its data-loop thread. Live spawns up to 32
real-time audio threads. Pinning the audio threads to a fixed CPU set, separate
from the GUI and wineserver threads, reduces cache contention and scheduling
jitter. Confidence: **unverified**. First step: confirm `taskset` and
`WINE_CPU_TOPOLOGY` interaction, then run a pinned and an unpinned pair on a
machine with eight or more cores.

### Bring DXVK-style shader precompilation to plugin editors

JUCE and OpenGL plugin editors stutter on first open because wined3d compiles
shaders on demand. DXVK uses `VK_EXT_graphics_pipeline_library` to precompile.
Confidence: **unverified**. Couples to the DXVK evaluation above. First step:
confirm the stutter with a frame-time capture on a known JUCE plugin, then
measure under DXVK.

### Add Media Foundation support for Live 12 video and WMA

Live 12 imports video through Media Foundation. The GE-Proton and staging
`mfplat-streaming-support` patches cover this path. Confidence: **unverified**.
First step: list which Media Foundation entry points Live 12 hits during an MP4
import, then check coverage against the GE-Proton patch set.

### Expand GPU device identification beyond Intel

Patches 0035, 0057, and 0061 add Intel and AMD device names so Live enables its
GPU renderer. The Vulkan backend already names devices from the driver. Applying
that pattern to the OpenGL backend everywhere (not just as a fallback) removes
per-device table entries. Confidence: **unverified**. First step: audit the
wined3d device table against `pci.ids` and confirm 0061 covers the gaps.

### Verify the `-DontCombineAPCs` definition before any APC work

See the verification note above. Ableton documents this flag for Akai APC
controllers, not for Windows APCs. Confidence: **unverified**. First step: ask
Ableton support, or test the flag against an APC controller and an idle session
in the same prefix, and separate the two effects.

## Ranked opportunities

Ranking is by expected effect on audio stability and speed, divided by risk and
effort. Each row should become its own change with a `bench-run.sh` pair.

| Rank | Opportunity | Expected effect | Risk | Effort |
|---|---|---|---|---|
| 1 | Require ntsync at runtime and warn on its absence | Stops a silent 4-50x sync regression | Low | Low |
| 2 | Confirm the busy idle thread and fix its real cause | Removes 30-40% idle CPU | Medium | Medium |
| 3 | Backport staging ntdll and server patches | Cuts wineserver and message-loop latency | Medium | Medium |
| 4 | Measure and narrow the realtime policy | Removes low-core audio risk | Low | Medium |
| 5 | Pin audio and render threads to disjoint cores | Lower jitter under load | Low | Medium |
| 6 | Evaluate DXVK for the Direct2D and Direct3D 11 UI | Steadier render, lower render CPU | High | Medium |
| 7 | Bring shader precompilation to plugin editors | Removes first-open stutter | High | High |
| 8 | Add Media Foundation for Live 12 video and WMA | Restores video and WMA import | Medium | Medium |
| 9 | Expand GPU device identification | Broader GPU renderer coverage | Low | Low |
| 10 | Verify the `-DontCombineAPCs` definition | Corrects the basis for APC work | Low | Low |

## Open questions

- Whether DXVK composites correctly with DirectComposition and WebView2 on this
  base, or whether it regresses the present path that patches 0055, 0058, and
  0059 already optimise.
- Whether the busy idle thread is an APC loop, a message loop, or something
  else. The trace decides the fix.
- Whether whole-process `SCHED_RR` 10 helps or harms on a four-core machine.
- Whether the staging ntdll and server patches rebase cleanly onto
  `d2d1-dcomp-11.13` without conflicting with the 62 local patches.
- Which Media Foundation entry points Live 12 actually calls.

## Verification standard

No opportunity becomes a claim without a before-and-after pair recorded by
`scripts/bench-run.sh` under the reference conditions stated in that script:
the committed reference set, 48 kHz at 256 frames, fixed window geometry, one
machine per comparison. The unit of evidence is the pair.
