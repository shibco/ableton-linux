# Other Wine forks: performance and stability survey

This document helps the reader decide which performance and stability work from other Wine forks is worth porting into this repository's patch series. It surveys GE-Proton, wine-tkg and proton-tkg, wine-staging, Kron4ek Wine-Builds, CachyOS builds, Valve Proton, Proton-EM, the upstream wine-wayland driver, Wine-NSPA, and the older real-time audio lineage. ENCORE, the other Ableton-focused fork, is covered separately in [ABLETON-WINE-ENCORE-REVIEW.md](../ABLETON-WINE-ENCORE-REVIEW.md).

## How this project adopts outside work

The build unpacks a pinned Wine base (giang17/wine `d2d1-dcomp-11.13` @ `5c23dd1c`, `patches/BASE.txt:3-6`) and applies 62 numbered patch files in lexical order with `git am --3way` (`patches/BASE.txt:14`, `scripts/container-build.sh:37-45`). Any adopted idea must therefore land as one or more clean `.patch` files against that tree. The precedent is selective porting: the ENCORE review took three changes and rejected the rest (`notes/ABLETON-WINE-ENCORE-REVIEW.md:1-6`).

Already covered, so forks offering these add nothing:

- ntsync, the in-kernel NT synchronization driver. The build vendors the UAPI header (`Containerfile:94-98`) and hard-fails if ntsync is missing from either wineserver or ntdll (`scripts/container-build.sh:108-123`). Adding ntsync "reduced reported wineserver idle CPU use" (`CHANGELOG.md:246`).
- Real-time scheduling. The launcher runs Wine under `SCHED_RR` priority 10 and PipeASIO requests `SCHED_FIFO` 15 for its data loop (`notes/ABLETON-WINE-RT-SCHEDULING.md:1-11`).
- A low-latency ASIO path. PipeASIO is built against this exact Wine (`scripts/container-build.sh:131-176`); ASIO (Audio Stream Input/Output) is the low-latency audio driver API DAWs use.
- A direct GL present path for Live's D3D11 swapchains, behind an env toggle (`patches/BASE.txt:167`).

## Which forks carry what

| Fork | Beyond upstream Wine | Targets | DAW relevance | Port difficulty |
|---|---|---|---|---|
| GE-Proton | Game fixes, media foundation, NVAPI, ntsync toggle | Games | Low | High |
| wine-tkg / proton-tkg | Build system with perf patch toggles | Games | Medium (mechanism, some patches) | Low–medium |
| wine-staging | ~100 experimental patch sets; a few perf-named | General + games | Medium | Low–medium |
| Kron4ek Wine-Builds | Binaries; `-O3 -msse3` flags | General | Medium (flags only) | Trivial |
| CachyOS proton-cachyos | Bleeding-edge Proton + winepipewire.drv + v3/LTO packaging | Games | Medium (audio driver) | Medium |
| Valve Proton experimental | Per-game fixes, CPU topology, thread priorities | Games | Low (watch only) | High |
| Proton-EM | winewayland.drv improvements | Games | Low (watch only) | High |
| wine-wayland (upstream) | Native Wayland driver | General | Low in 2026 | Very high |
| Wine-NSPA | RT/audio fork: PI, IPC, client-side NT, io_uring | Pro audio | Highest | Medium–high |
| wine-rt / wineasio / yabridge | Historical RT patches; plugin bridge | Pro audio | Superseded / reference | n/a |
| hangover / box64 | x86 on ARM64 emulation | ARM64 | None (x86-64 only) | n/a |

## GE-Proton: game fixes, not audio

GE-Proton carries, beyond Valve's Proton: media-foundation patches for video playback, AMD FSR upscaling patches, NVIDIA CUDA/NVAPI support, raw-input mouse patches, the protonfixes per-game fix system, selected upstream backports and wine-staging picks, and ntsync enablement when the kernel supports it (https://github.com/GloriousEggroll/proton-ge-custom). Its patches apply through one script, `patches/protonprep-valve-staging.sh`, over a Valve Proton Wine tree (same README).

Relevance to a real-time DAW: low. The media-foundation work overlaps functionality this project already ships through winegstreamer (`scripts/container-build.sh:96-102`). The rest is game compatibility. Two transferable patterns, not patches: every behavioral change sits behind an environment toggle (its README lists `PROTON_NO_NTSYNC`, `PROTON_HEAP_DELAY_FREE`, `PROTON_NO_WRITE_WATCH`), and the full patch queue lives in one ordered script. Adoption difficulty: high. The patches target Valve's Wine fork, not mainline 11.13, so each needs a rebase; the value does not justify it.

## wine-tkg and proton-tkg: a build system with toggles

wine-tkg is a build system that assembles a Wine tree from a config file; proton-tkg wraps it for Proton builds (https://github.com/Frogging-Family/wine-tkg-git). The current config options relevant to performance (https://raw.githubusercontent.com/Frogging-Family/wine-tkg-git/master/wine-tkg-git/customization.cfg):

- `_use_ntsync`: ntsync support; Wine 10.11+ and kernel 6.14+.
- `_use_esync`, `_use_fsync`, `_use_fastsync`: legacy out-of-tree sync primitives (eventfd and futex based), all marked legacy and superseded by ntsync. Skip.
- `_FS_bypass_compositor`: bypasses the compositor for fullscreen games to reduce stutter. Live runs windowed; skip.
- `_proton_fs_hack`, `_proton_rawinput`, GE game patches, `_proton_winevulkan`: game-specific; skip.
- `wine-tkg-userpatches`: a drop-in user patch directory. Same mechanism as this repo's `patches/`; nothing to adopt.

Relevance: medium as a patch source. The generated trees (Tk-Glitch/wine-tkg, wine-proton-tkg) make it possible to lift single commits as `.patch` files. Most of the queue is game work. Adoption difficulty: low to medium per patch.

## wine-staging: which patch sets touch performance

wine-staging is Wine's experimental patch queue, a staging area for work not yet merged upstream. The current master list is at https://github.com/wine-staging/wine-staging/tree/master/patches. Most sets are correctness or application-compatibility fixes. The sets with performance in scope:

| Patch set | What it does | DAW relevance |
|---|---|---|
| `ntdll-APC_Performance` | Name indicates APC overhead reduction; the exact mechanism is Unverified (its definition file did not fetch) | High if it overlaps this repo's APC problem (see below) |
| `server-PeekMessage` | Message-order correctness fix ("GetMessage should remove already seen messages with higher priority", bug 28884: https://raw.githubusercontent.com/wine-staging/wine-staging/master/patches/server-PeekMessage/definition) | Low; not a perf patch |
| `gdiplus-Performance-Improvements` | gdiplus speed-ups | Low; Live's UI is not gdiplus-based, some plugin editors are |
| `wined3d-unset-flip-gdi` | Presentation/GDI-flip handling in wined3d | Medium; adjacent to this repo's present-path work (`patches/BASE.txt:167`) |
| `shell32-IconCache`, `dxgi_getFrameStatistics` | Icon cache; DXGI frame statistics API | Low |
| `dsound-EAX` | Positional audio for games | None |

The APC set matters here. APC stands for asynchronous procedure call, a callback Windows queues onto a thread for delivery at its next alertable wait. Live's APC-coalescing thread burns 30–40% of a core at idle (`notes/ABLETON-WINE-APC-COALESCING.md:3`), and this repo has a written, unimplemented proposal to deliver same-process user APCs through the ntsync alert event instead of wineserver (`notes/ABLETON-WINE-APC-COALESCING.md:32-41`). Read `ntdll-APC_Performance` before writing that patch. Adoption difficulty for any staging set: low to medium; staging patches are formatted against the matching upstream Wine and this base is Wine 11.13 plus a fork's dcomp work, so context drift is the main risk.

## Kron4ek Wine-Builds: compiler flags, not patches

Kron4ek publishes vanilla, staging, staging-tkg, and proton-flavored Wine binaries (https://github.com/Kron4ek/Wine-Builds). The transferable content is the build configuration, not patches: amd64 builds use `-march=x86-64 -msse3 -mfpmath=sse -O3` with `--without-oss --disable-winemenubuilder --disable-tests`, targeting glibc 2.27 (same README). This project's container passes no `CFLAGS` or `-march`; it uses Wine's configure defaults (`scripts/container-build.sh:53-56`). An `-O3` comparison build is a cheap experiment. Adoption difficulty: trivial.

## CachyOS: proton-cachyos and wine-cachyos

proton-cachyos tracks Valve's Proton experimental bleeding-edge, applies wine-staging, and imports winewayland.drv improvements from Proton-EM (https://github.com/CachyOS/proton-cachyos/releases, May 2026 entry). Two items stand out for an audio workload:

- `winepipewire.drv`, a native PipeWire backend for mmdevapi (the standard Windows audio API above ASIO), enabled by default, with a documented note that full `+pipewire` tracing perturbs audio timing (https://github.com/CachyOS/proton-cachyos). This repo serves Live through PipeASIO, but an mmdevapi-level PipeWire path covers everything that is not ASIO.
- Distro-level optimization: CachyOS rebuilds packages for x86-64-v3/v4 with LTO (https://wiki.cachyos.org/features/optimized_repos/). wine-cachyos exists as a separate build with ntsync support (https://discuss.cachyos.org/t/ntsync-in-latest-proton-cachyos-wine-cachyos/5254); its exact patch list is Unverified — the repository README is the stock Wine README (https://github.com/CachyOS/wine-cachyos).

Relevance: medium. Adoption difficulty: medium for winepipewire.drv (one driver, new code rather than a conflict with the existing series), trivial for the compiler-flag idea.

## Valve Proton experimental and bleeding-edge: a watch list

Proton 11.0-1 rebased on Wine 11.0 and ships updated DXVK, vkd3d-proton, and Wine Mono; Proton experimental tracks it plus per-game fixes, current as of 2026-07-28 (https://github.com/ValveSoftware/Proton/wiki/Changelog). ntsync is the headline sync change: SteamOS 3.7.20 loads the ntsync module by default (https://www.phoronix.com/news/Steam-OS-Beta-NTSYNC, https://www.gamingonlinux.com/2026/01/steamos-3-7-20-adds-the-ntsync-driver-to-help-improve-some-game-performance/), and Proton 11 brings it to the Steam ecosystem (https://www.tweaktown.com/news/111106/valves-proton-11-beta-unlocks-more-playable-games-and-boosts-performance-for-steam-deck-and-linux-fans/index.html).

Three Proton changelog entries touch thread and CPU behavior rather than games: "Fixed Proton not setting priorities correctly for new threads" (9.0-4), "Fixed CPU topology override issues on machines with more than 32 logical cores" (10.0-1), and per-game core-count limits for old titles (9.0-1) (all: https://github.com/ValveSoftware/Proton/wiki/Changelog). Relevance: low for adoption — the fork's delta from mainline is huge and Steam-runtime-bound — but it is the fastest-moving public consumer of Wine 11 sync work. Treat it as an early-warning feed.

## Proton-EM: where Wayland fixes land first

Proton-EM is Etaash Mathamsetty's Proton fork carrying winewayland.drv improvements, HDR, and FSR4 work (https://github.com/Etaash-mathamsetty/Proton). proton-cachyos regularly imports its Wayland patches (https://www.gamingonlinux.com/2026/05/proton-cachyos-11-adds-initial-optiscaler-integration-and-lots-of-other-fixes/). Its docs (`docs/EM-ADDITIONS.md`, `docs/CHANGES.md` in that repo) are the most current public record of what winewayland still cannot do. Games-focused; relevance here is as documentation for the Wayland question below.

## wine-wayland in 2026: not a migration target

The upstream Wayland driver is improving but still acquiring windowing basics in mid-2026: Wine 11.0 shipped "better Wine Wayland driver support" (https://www.phoronix.com/news/Wine-11.0-Released), Wine 11.11 added layered windows and min/max size hints (https://www.phoronix.com/news/Wine-11.11-Released), Wine 11.12 added fractional scaling (https://www.phoronix.com/linux/WINE news archive, 29 June 2026 entry), and alpha-modifier support landed the same month (https://www.phoronix.com/news/Wine-Wayland-Alpha-Modifier). Downstream consumers still treat it as experimental: proton-cachyos documents white-window failures for CEF/Electron apps and notes Proton 11 removed Proton 10's automated Wayland hacks (https://github.com/CachyOS/proton-cachyos); GE-Proton notes Steam overlay and Steam Input do not work with the driver (https://github.com/GloriousEggroll/proton-ge-custom).

This project's series is deeply winex11-shaped — winex11 changes run through patches 0002–0017 and recur at 0039, 0042, 0053, and 0062 (`patches/BASE.txt:14` and the per-patch provenance list) — and Live's validated configuration is XWayland (see the resize and menu notes under `notes/`). Migration would port or discard most of that work for an unclear gain. Verdict: keep winex11; re-check the driver after it stops landing per-release windowing basics.

## Wine-NSPA: the pro-audio fork to mine

Wine-NSPA (nine7nine) is a PREEMPT_RT-focused fork of Wine 11.8 for pro audio — PREEMPT_RT is the kernel patch set that makes Linux fully preemptible for real-time workloads (https://github.com/nine7nine/Wine-NSPA). Its documented work, per the README's architecture index and status:

- Priority inheritance (PI) for `CRITICAL_SECTION` and Win32 condition variables, via a bundled librtpi re-implementation. PI temporarily raises a lock holder's priority to prevent priority inversion — directly relevant to this repo's noted risk that Live's real-time threads outrank the `SCHED_OTHER` wineserver they synchronously call (`notes/ABLETON-WINE-RT-SCHEDULING.md:15-20`).
- A kernel-mediated wineserver IPC layer ("gamma channel dispatcher") with aggregate-wait and burst drain, plus a kernel-side ntsync PI overlay in the companion Linux-NSPA kernel (https://github.com/nine7nine/Linux-NSPA-pkgbuild).
- Client-side NT surfaces: local events, local timers, local files, local sections, and thread/process shared-state readers that turn some waits into "zero-time" waits without a wineserver round trip.
- `io_uring` (Linux's shared-ring async I/O interface) for file and socket I/O.
- Hot-path work: message rings with empty-poll caching, TEB (thread environment block, per-thread NT state) hot-state caching, cacheline-shaped userspace sync, AVX2 string/Unicode loops.
- RT memory: `mlockall()`, automatic hugetlb promotion, heap hugepage backing.
- Audio: winejack and nspaASIO drivers; embedding protocols that let winelib hosts (winelib is Wine's library for building Unix applications against the Win32 API) embed Wine HWND plugin editors over X11 or Wayland; a Yabridge-NSPA bridge fork.
- Stated validation: native ntsync suite 3 PASS / 0 FAIL, PE matrix 32 PASS / 0 FAIL / 0 TIMEOUT (`v9-validation-default`).

This is the only surveyed fork built for the same workload class as this project, and the relationship already exists: patches 0002–0003 here are winex11 changes from nine7nine/wine-nspa-src commits (`patches/BASE.txt:34-36`). Community reports also credit the Wine-NSPA ecosystem's Ableton Options.txt tuning with large CPU reductions under Wine (https://github.com/nine7nine/Wine-NSPA/issues/4). Two cautions. First, the 11.x repository publishes "design, architecture, and validation documentation"; whether full 11.x sources or patch files are public is Unverified — verify before planning ports. Second, several items (kernel IPC overlay, PI ntsync) assume the custom Linux-NSPA kernel, which this project does not ship; the client-side items (message ring, empty-poll caching, local events/timers, `mlockall`) are the portable subset. Adoption difficulty: medium-high per item, high for the kernel-dependent items.

## wine-rt, wineasio, yabridge: the real-time lineage

- wine-rt: a 2013-era patch that gave Wine threads `SCHED_FIFO` via the `WINE_RT` environment variable (https://github.com/PlayOnLinux/wine-patches/blob/master/custom/RealTime/rt.patch); KXStudio shipped an rt-patched Wine for audio work (https://forum.winehq.org/viewtopic.php?t=32742). Superseded by this repo's launcher-level `chrt` policy (`notes/ABLETON-WINE-RT-SCHEDULING.md:1-11`). Nothing to adopt.
- wineasio: the classic ASIO-to-JACK driver. This project ships PipeASIO instead (see `notes/ABLETON-WINE-PIPEASIO.md`). Nothing to adopt.
- yabridge: runs Windows VST2/VST3/CLAP plugins in Wine for native Linux hosts, bridging over shared memory and UNIX sockets with under 1 ms added latency in one 2026 account (https://bonnef.in/posts/linux-music-production/, project at https://github.com/robbert-vdh/yabridge). Live loads plugins in-process here, so the bridge is not needed; its Yabridge-NSPA fork is worth tracking as a bellwether for Wine-NSPA's RT rules.

## hangover and box64: out of scope

hangover pairs Wine with the FEX or Box64 emulators to run x86 Windows applications on ARM64 Linux; Hangover 11.0 released alongside Wine 11.0 in January 2026 with QEMU support removed (https://www.phoronix.com/news/Hangover-11.0-Released, https://github.com/AndreRH/hangover). This project builds for i386 and x86_64 only (`scripts/container-build.sh:55`) and targets x86-64 hosts. Not applicable.

## Key opportunities

1. **Mine Wine-NSPA's portable client-side work** — message ring, empty-poll caching, local events/timers, shared-state waits, `mlockall` — as individual patches, starting with whichever maps to the largest measured wineserver load. Impact: high. Effort: high. Evidence: https://github.com/nine7nine/Wine-NSPA (documented highlights); existing port precedent at `patches/BASE.txt:34-36`.
2. **Read wine-staging's `ntdll-APC_Performance` before implementing the proposed same-process APC bypass.** Impact: high (targets a measured 30–40% idle core and suspected playback xruns). Effort: medium. Evidence: `notes/ABLETON-WINE-APC-COALESCING.md:3` and `:32-41`; patch set listed at https://github.com/wine-staging/wine-staging/tree/master/patches.
3. **Benchmark an `-O3 -march=x86-64-v3` build against the current default-flags build.** Impact: medium. Effort: low. Evidence: no `CFLAGS`/`-march` in `scripts/container-build.sh:53-56`; Kron4ek ships `-O3 -msse3` (https://github.com/Kron4ek/Wine-Builds); CachyOS ships v3/v4+LTO repos (https://wiki.cachyos.org/features/optimized_repos/).
4. **Audit Windows thread-priority mapping against the launcher's `SCHED_RR` inheritance, and check whether Proton's new-thread priority fix has an upstream equivalent.** Impact: medium. Effort: medium. Evidence: "Fixed Proton not setting priorities correctly for new threads" (https://github.com/ValveSoftware/Proton/wiki/Changelog, 9.0-4); priority-inversion risk noted at `notes/ABLETON-WINE-RT-SCHEDULING.md:15-20`.
5. **Evaluate proton-cachyos' `winepipewire.drv` as an mmdevapi-level PipeWire reference for non-ASIO audio paths.** Impact: low. Effort: medium. Evidence: enabled by default with latency-tuning notes at https://github.com/CachyOS/proton-cachyos.
6. **Keep every new performance patch behind an environment toggle, following the Proton/GE pattern.** Impact: low. Effort: low. Evidence: toggle list at https://github.com/GloriousEggroll/proton-ge-custom; this repo's own `WINE_DISABLE_GL_PRESENT` precedent (`patches/BASE.txt:167`).
7. **Track Valve Proton experimental, proton-cachyos, and Proton-EM as a standing watch list for Wine 11 sync and Wayland changes, rather than as patch sources.** Impact: low. Effort: low. Evidence: https://github.com/ValveSoftware/Proton/wiki/Changelog; import cadence shown at https://github.com/CachyOS/proton-cachyos/releases.
