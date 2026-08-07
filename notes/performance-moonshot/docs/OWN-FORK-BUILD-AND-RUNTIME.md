# Own-fork build and runtime review for the performance moonshot

This document helps the reader decide which build-system and runtime-environment changes are worth making to get xrun-free low-latency audio and a responsive UI out of Ableton Live under this Wine fork. An xrun is an audio buffer overrun or underrun: one missed processing cycle, heard as a click or dropout.

Scope: `build.sh`, `Makefile`, `Containerfile`, the launcher, setup and diagnostic scripts under `scripts/`, the portal helpers under `bin/`, and the probes under `tools/`. The patch series under `patches/` is out of scope; a sibling document owns it. Where a launcher variable only exists because of a patch, this document covers the variable, not the patch.

## How the runtime is built today

The build is a pinned, containerized Wine compile. Facts:

| Fact | Value | Evidence |
|---|---|---|
| Base image | Ubuntu 22.04, pinned by digest | `Containerfile:10` |
| Unix-side compiler | gcc from jammy `build-essential` (gcc 11.2) | `Containerfile:37-39`; [packages.ubuntu.com/jammy/gcc](https://packages.ubuntu.com/jammy/gcc) |
| PE-side compiler | clang/lld 21, exact package version pinned | `Containerfile:13-17` |
| Configure invocation | `CPPFLAGS=-I/opt/ntsync-uapi` only; no `CFLAGS`, `CROSSCFLAGS`, or `LDFLAGS` overrides | `scripts/container-build.sh:53-56` |
| Effective optimization | `-O2` with debug info on both sides: the vendored base's `configure` defaults `CFLAGS` to `-g -O2` (configure lines 5649/5655) and the PE cross flags to `-g -O2` (line 7627) inside `vendor/wine-base-5c23dd1c.tar.zst` | `scripts/container-build.sh:53-56` (nothing overrides them) |
| PipeASIO compile | gcc `-fPIC -O2 -DNDEBUG -fvisibility=hidden` | `scripts/container-build.sh:150-158` |
| ableton-linkd compile | g++ `-O2`, static libstdc++/libgcc | `tools/build_ableton-linkd.sh:33-38` |
| Architectures | i386 + x86_64 WoW64 | `scripts/container-build.sh:55` |
| Debug info | built with `-g`, then stripped (`llvm-strip --strip-all` on PE, `strip --strip-unneeded` on Unix) | `scripts/container-build.sh:178-186` |
| Build cache | ccache, 5 GB, host directory bind-mounted | `build.sh:31,37`; `Containerfile:90-92` |
| Packaging | zstd `-19 --long=27` tarball | `scripts/container-build.sh:237` |
| Tool probes | clang `-O2`, CRT-free PE builds | `tools/build_metricprobe2.sh:16-24`, `tools/build_mousespy.sh:14-16` |

`Makefile` is a thin wrapper over `build.sh` and the install scripts (`Makefile:1-28`). `build.sh` verifies vendored checksums, builds the image, runs `container-build.sh`, then builds ableton-linkd (`build.sh:24-44`).

## Compiler optimization gaps

The build ships Wine's configure defaults. Nothing raises them.

- No `-O3` anywhere. Both compiler sides run `-O2`.
- No `-march` / `-mtune` anywhere. The shipped binaries use the generic x86-64 baseline. This is a deliberate property of a relocatable tarball for unknown user machines, not an oversight, but it leaves instruction-set headroom (SSE4.2, AVX2, BMI2) unused.
- No LTO (link-time optimization: cross-module inlining at link time). clang 21 + lld is already the PE toolchain, so ThinLTO is available without new dependencies. Unverified: whether the Wine PE build survives `-flto=thin`; winebuild-generated assembly and `.spec` handling are the usual failure points, so this needs a build plus the existing relocation gate (`scripts/container-build.sh:240-265`) to prove.
- No PGO (profile-guided optimization: recompiling with branch hints from a recorded run). No `-fprofile` flag appears anywhere in the repo. Effort is high because a representative Live workload must be scripted and replayed inside the container.
- No `-fno-plt` and no linker relaxations (`-Wl,-O1`, `-z now`, `-Bsymbolic-functions`). `-fno-plt` removes one indirection on every cross-library call on the Unix side; wineserver, ntdll, win32u, and wined3d make such calls constantly.
- gcc 11.2 compiles the Unix side while clang 21 compiles the PE side. Newer gcc releases improve code generation incrementally. Unverified: whether a newer gcc for jammy (toolchain PPA) keeps the glibc 2.35 runtime floor the tarball promises (`scripts/container-build.sh:230`). Building inside the same jammy image keeps the floor regardless of compiler version.

## What the launcher sets and does not set

`scripts/ableton-live` is the canonical runtime environment. Variables it sets:

| Variable | Value | Purpose | Evidence |
|---|---|---|---|
| `WINEDEBUG` | `-all` | kills fixme spam that stalls Live's UI thread | `scripts/ableton-live:16-17` |
| `WINE_D3D_CONFIG` | `csmt=0x1` | enables wined3d's command-stream thread | `scripts/ableton-live:18` |
| `WINED3D_DCOMP_FORCE_FULL_REDRAW` | `1` | full-surface redraws; correctness over UI throughput | `scripts/ableton-live:19` |
| `WINE_X11_FORCE_OFFSCREEN_CLASS` | `Ableton Live Window Class` | keeps Live on the offscreen path (M4L flicker fix) | `scripts/ableton-live:20-23` |
| `WINE_DISABLE_UNIX_MOUNT_REPARSE` | `1` | browser treats host mounts as plain dirs | `scripts/ableton-live:24-26` |
| `WINEDLLOVERRIDES` | `mscoree,mshtml=` (plus `dcomp=` opt-in) | keeps Mono/HTML-help hooks out | `scripts/ableton-live:29-38` |
| `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` | SwiftShader software rendering, `--no-sandbox` | Learn View renders where Wine GPU compositing does not | `scripts/ableton-live:39-42` |
| `WINE_CPU_TOPOLOGY` | capped at 8 CPUs | groundwork only: "Inert on this runtime until the patched ntdll/wineserver consumer lands" | `scripts/ableton-live:75-108` |
| `WINESERVER` | this build's wineserver | binds the prefix to the patched server | `scripts/ableton-live:27` |

Absences and behaviors:

- `WINEESYNC`/`WINEFSYNC` are explicitly unset by the portal wrappers and setup (`bin/ableton-live-portal:24`, `bin/ableton-wine-portal:15`, `scripts/setup-prefix.sh:56`). ntsync is the synchronization path; nothing to add here.
- No `/dev/ntsync` presence check at launch. On a kernel without it, every NT synchronization wait becomes a wineserver round trip, and the user gets no warning. The build-time comment prices this at "~1.3 cores with Live running" (`scripts/container-build.sh:104-107`); the regression note measured ~45% of one core and ~9,000 context switches per second at idle with the ASIO device open (`notes/ABLETON-WINE-NTSYNC-REGRESSION.md:11-14`).
- No wineserver persistence flag. Each cold launch kills stale servers and runs a synchronous `wineboot` (`scripts/ableton-live:187-196`). That is startup cost, not steady-state audio cost.
- No `taskset`/affinity or `nice` adjustment on the Live process. The launcher-wide RT wrapper is the only scheduling control (next section).
- The WebView2 flags force CPU rendering (SwiftShader) for Live 12's Learn View (`scripts/ableton-live:42`). Deliberate correctness tradeoff; it spends CPU on every visible Learn pane.

## Realtime scheduling, governor, IRQs, rtkit

`scripts/setup-realtime.sh` is the host-tuning surface. It writes drop-ins and applies them; it advises on, but never performs, bootloader and kernel changes.

| Measure | Status | Evidence |
|---|---|---|
| rtprio 95, memlock unlimited, nice -19 for the `audio` group | installed | `scripts/setup-realtime.sh:72-77` |
| `vm.swappiness = 10` | installed + applied | `scripts/setup-realtime.sh:80-88` |
| CPU governor `performance` + systemd unit | installed + applied | `scripts/setup-realtime.sh:90-122` |
| `threadirqs` kernel parameter | advised only | `scripts/setup-realtime.sh:124-133` |
| rtirq (IRQ threading priorities) | enabled only if already installed | `scripts/setup-realtime.sh:134-144` |
| lowlatency / PREEMPT_RT kernel | advised only, for sub-256-frame buffers | `scripts/setup-realtime.sh:146-151` |
| wineserver `chrt -f 95` boost | deliberately omitted (root per launch; priority inversion risk) | `scripts/setup-realtime.sh:23-25` |

At launch, the launcher probes `chrt -r 10 true` and runs the whole Wine process tree under `SCHED_RR` priority 10 when the probe succeeds (`scripts/ableton-live:780-783`). SCHED_RR is a realtime round-robin policy: GUI threads inherit it along with audio threads. PipeASIO separately requests `SCHED_FIFO` priority 15 for its data-loop thread (`notes/ABLETON-WINE-RT-SCHEDULING.md:3-7`). The same note lists the open risks—Linux throttles realtime tasks to 950 ms per second by default, all inherited threads share one RR priority, and Live's realtime threads outrank the `SCHED_OTHER` wineserver they make synchronous calls to (`notes/ABLETON-WINE-RT-SCHEDULING.md:31-41`)—and prescribes a pending 4-CPU A/B comparison before changing the default (`notes/ABLETON-WINE-RT-SCHEDULING.md:43-82`). That comparison is still unrun; no `bench/` directory or committed results exist in the repo.

rtkit (a D-Bus service that grants realtime scheduling to unprivileged clients) is not referenced anywhere in the repo. PipeWire uses it for its own data loops on hosts where it is installed; this project neither requires nor verifies it.

## PipeWire and the audio path

- PipeASIO is the only shipped ASIO driver; it is a native PipeWire client with no JACK layer (`notes/ABLETON-WINE-PIPEASIO.md:3-5`).
- Prefix setup seeds `~/.config/pipeasio/config.ini`: 2 inputs, 2 outputs, fixed 256-frame buffer, auto-connect (`scripts/setup-prefix.sh:591-603`). `PIPEASIO_*` variables override per launch (`scripts/ableton-live:760-762`).
- PipeWire 1.6 or newer can match the graph quantum (the processing cycle size in frames) to the ASIO buffer; a 256-frame configuration produced `force-quantum` 256 in validation (`notes/ABLETON-WINE-PIPEASIO.md:20,72`). The runtime accepts host PipeWire 0.3.56 or newer (`Containerfile:100-105`), so hosts on 0.3.x-1.5 get no quantum matching and nothing warns them. The README recommends 1.6+ (`README.md:40`); TROUBLESHOOTING repeats the version check (`TROUBLESHOOTING.md:106`).
- No PipeWire host configuration (clock rate, quantum, wireplumber device rules) is seeded or verified by any script. The only quantum evidence path is manual `pw-metadata -n settings` / `pw-top`, referenced by the tester kit (`beta/tester-kit/lib/collect-linux.sh:148-149`) and the audio check's failure hint (`scripts/check-live-audio.sh:57-60`).
- Validation recorded ~8% Live DSP load at 48 kHz / 256 frames, with the PipeWire error counter moving 24→26 on a loaded machine; the note itself flags this as not a controlled latency comparison (`notes/ABLETON-WINE-PIPEASIO.md:83-85`).
- The one measured audio-adjacent CPU sink outside the driver is Live's APC-coalescing thread: 30-40% of one core at idle. ntsync does not accelerate the alertable waits behind it. The attempted `-DontCombineAPCs` workaround caused playback starvation and was reverted; a Wine-side fix is proposed but unimplemented (`notes/ABLETON-WINE-APC-COALESCING.md:3-16`).

## Kernel requirements

| Requirement | Needed for | Where checked | Evidence |
|---|---|---|---|
| kernel ≥ 6.14 (`/dev/ntsync`) | ntsync; without it every NT wait is a wineserver round trip | build-time header gate; `check-ntsync.sh` notes the missing device; no launch-time check | `Containerfile:94-98`; `scripts/check-ntsync.sh:38`; `scripts/container-build.sh:104-123` |
| `threadirqs` cmdline | IRQ threading | advised by setup-realtime.sh only | `scripts/setup-realtime.sh:124-133` |
| lowlatency / PREEMPT_RT kernel | sub-256-frame buffers | advised by setup-realtime.sh only | `scripts/setup-realtime.sh:146-151` |
| glibc ≥ 2.35 | runtime floor of the tarball | stated in BUILD-INFO | `scripts/container-build.sh:230` |

ntsync's measured value: 4-50x more synchronization throughput after it was restored, and wineserver idle load dropped from ~45% of a core (`notes/ABLETON-WINE-NTSYNC-REGRESSION.md:11-14`).

## Benchmarking and probe coverage

The harness is `scripts/bench-run.sh`. Its protocol: before/after row pairs under fixed reference conditions: a committed reference set, 48 kHz / 256 frames, fixed window geometry, one machine per comparison (`scripts/bench-run.sh:7-11`). Four metrics:

| Metric | How captured | Evidence |
|---|---|---|
| `wined3d_cs_pct` | automated: 60 s of per-thread `top` samples | `scripts/bench-run.sh:52-65` |
| `wineserver_ctxt_delta` | automated: 60 s of `/proc` ctxt-switch counters | `scripts/bench-run.sh:67-95` |
| `xruns_5min` | operator-entered from a `pw-top` ERR delta | `scripts/bench-run.sh:34,50` |
| `dsp_load_pct` | operator-entered from Live's DSP meter | `scripts/bench-run.sh:35` |

Coverage gaps:

- No automated xrun capture. The headline metric is typed in by a human reading `pw-top`.
- No round-trip latency measurement (loopback), no DSP-load automation, no startup-time metric, no UI-responsiveness metric (frame pacing, input latency), no idle-CPU metric for the APC-coalescing thread. The APC note says to record those "separately unless that script is extended" (`notes/ABLETON-WINE-APC-COALESCING.md:59-63`).
- The "committed reference set" the protocol requires is not in the repo: no `bench/` directory exists. Unverified: testers may hold it privately; either way it is not committed.
- Gates that do exist: `scripts/check-ntsync.sh` (semantics probe + `/dev/ntsync` open check, with wineserver context-switch delta at `scripts/check-ntsync.sh:52-62`), `scripts/check-live-audio.sh` (Live log scan for a clean ASIO open), `scripts/check-m4l-fonts.sh` (font-fallback hang regression), `scripts/build-audit.sh` (per-patch artifact fingerprints). These are correctness gates, not performance gates.
- `tools/` probes are diagnostic, not benchmarks: `mousespy.c` (global mouse-hook routing trace), `linkprobe.c` (Link multicast verdict), `midihot.c` (MIDI hotplug listener), `metricprobe2.c` (DPI metric pinning), `stresstest.c` (session-allocator hammer), `xsamp.c`/`xrec.c` (X-side pixel and protocol spies). None measures latency or throughput under load.

## Key opportunities

Ranked by expected impact on xrun-free low-latency audio and UI responsiveness. Planned items are proposals, not verified results.

1. **Add a launch-time `/dev/ntsync` check with a loud fallback warning.** Impact: high (users on kernel < 6.14 silently lose ~1 core to wineserver round trips). Effort: low (a `[ -c /dev/ntsync ]` test plus message in `scripts/ableton-live`). Evidence: `scripts/container-build.sh:104-107`, `scripts/check-ntsync.sh:38`, `notes/ABLETON-WINE-NTSYNC-REGRESSION.md:11-14`.
2. **Automate the benchmark harness's audio metrics and commit the reference set.** Planned: capture `pw-top -b` ERR deltas and `pw-metadata` rate/quantum directly in `bench-run.sh`, add a startup-time and an idle-CPU column, commit the reference set under `bench/`. Impact: high (every other opportunity here is judged by this harness; today the headline metric is hand-entered and the reference set is absent). Effort: low-medium. Evidence: `scripts/bench-run.sh:34-50`; no `bench/` directory in the repo.
3. **Run the prescribed SCHED_RR A/B and narrow realtime to audio threads.** The launcher puts the whole Wine process under RR 10, GUI threads included; the pending 4-CPU comparison decides whether that helps, needs a CPU-count floor, or should shrink to the PipeASIO data loop's FIFO 15. Impact: high on low-core machines, medium elsewhere. Effort: low (protocol and tooling already written). Evidence: `notes/ABLETON-WINE-RT-SCHEDULING.md:31-82`, `scripts/ableton-live:780-783`.
4. **Raise compiler optimization: `-O3` plus ThinLTO on the clang PE side, `-O3 -fno-plt` on hot Unix halves.** clang 21 + lld is already the PE toolchain; ThinLTO needs no new dependency. Unverified: PE build survival under LTO, and the size of the win; gate on the existing relocation gate plus a bench pair. Impact: medium-high. Effort: medium. Evidence: `scripts/container-build.sh:53-56` (no flag overrides), `Containerfile:13-17`.
5. **Seed and verify PipeWire host configuration.** Planned: at setup or launch, check the PipeWire version (quantum matching needs 1.6+), verify or set the device's clock rate and quantum via metadata/wireplumber rules, and warn when the graph quantum disagrees with the ASIO buffer. Impact: medium-high (a mismatched quantum is a direct xrun source; today nothing checks it). Effort: low-medium. Evidence: `notes/ABLETON-WINE-PIPEASIO.md:20,72`, `TROUBLESHOOTING.md:106`, `scripts/check-live-audio.sh:57-60`.
6. **Ship a `-march=x86-64-v2` build (SSE4.2/PopCNT, 2009-era floor), optionally with a v3 variant.** The tarball currently targets the generic baseline. v2 is near-universal on machines that run Live 12; v3 (AVX2) could be a separate opt-in artifact. Impact: medium. Effort: low (one flag each side, once). Evidence: `scripts/container-build.sh:53-56`; relocatable-tarball policy at `build.sh:15-17`.
7. **Complete the `WINE_CPU_TOPOLOGY` consumer so the 8-CPU cap actually applies.** The launcher computes and exports the cap but marks it inert; on high-core machines Live sizes thread pools from the full CPU count. Impact: medium on >8-core machines. Effort: medium (the consumer is a wineserver/ntdll change, patch territory; the launcher half is done). Evidence: `scripts/ableton-live:75-108`.
8. **Automate IRQ affinity instead of advising it.** Planned: package or vendor an rtirq equivalent, and fail the realtime check when `threadirqs` is missing rather than printing a note once at setup. Impact: medium. Effort: medium (host policy surface). Evidence: `scripts/setup-realtime.sh:124-144`.
9. **Add a kernel check to the realtime report: lowlatency/PREEMPT_RT and `threadirqs` presence, surfaced by the launcher or tester kit.** Sub-256-frame buffers are the project's own stated case for these kernels; today the advice prints once during setup. Impact: medium. Effort: low. Evidence: `scripts/setup-realtime.sh:146-151`, `beta/tester-kit/lib/collect-linux.sh:148-154`.
10. **Upgrade the Unix-side compiler past gcc 11.2 inside the same jammy image.** Keeps the glibc 2.35 floor while picking up several years of code-generation improvements. Unverified: exact gain; measure with a bench pair. Impact: low-medium. Effort: low-medium (one apt pin in `Containerfile`). Evidence: `Containerfile:37-39`, [packages.ubuntu.com/jammy/gcc](https://packages.ubuntu.com/jammy/gcc), floor at `scripts/container-build.sh:230`.
11. **Make wineserver persistent across launches (`wineserver -p`) or skip re-boot when the session is already bound to this build.** Cuts cold-start time and the per-launch `wineboot`; no steady-state audio effect. Impact: low-medium (UI responsiveness at launch). Effort: low. Evidence: `scripts/ableton-live:187-196`.
12. **PGO for the PE build using a scripted Live workload.** Unverified: needs a reproducible Live session to profile, and clang PGO on Wine PE is unexplored here. Impact: medium. Effort: high. Evidence: no `-fprofile` anywhere in the repo (grep over `scripts/`, `tools/`, `Containerfile`, `build.sh`).
13. **Revisit the WebView2 SwiftShader flags once Wine GPU compositing improves.** CPU rendering of every Learn View pane is a standing UI-thread cost, accepted for correctness. Impact: medium (UI). Effort: low to re-test, unknown to fix (depends on the GPU-renderer work tracked elsewhere). Evidence: `scripts/ableton-live:39-42`, `notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md`.
