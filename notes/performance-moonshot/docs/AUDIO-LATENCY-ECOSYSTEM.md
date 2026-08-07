# Audio latency ecosystem survey for the performance moonshot

This document helps the reader decide which low-latency audio optimizations to adopt by comparing what this repository already ships against the current Wine and Linux pro-audio ecosystem. It covers WineASIO and its forks, upstream Wine audio drivers, yabridge, REAPER-on-Wine tunings, PipeWire pro-audio settings, realtime kernels, rtkit, JACK versus PipeWire, and native Linux DAWs as latency reference points.

Terms used below. ASIO (Audio Stream Input/Output) is Steinberg's Windows low-latency driver API; it is the only audio driver Live uses on this project. An xrun is a buffer under- or overrun: the audio thread missed its deadline and the glitch is audible. Quantum is PipeWire's name for the buffer size in frames per processing cycle. Round-trip latency (RTL) is the time for a signal to enter the interface, pass through the software, and leave again. `SCHED_FIFO` and `SCHED_RR` are Linux realtime scheduling policies; a thread under either preempts normal threads. JACK is the traditional pro-audio server and client API. PipeWire is the current default Linux audio server; it can serve JACK, PulseAudio, and native clients at once. WirePlumber is PipeWire's session manager; it decides which devices and links exist. yabridge runs Windows VST plugins inside Linux DAWs by bridging each plugin between a native shim and a Wine process.

## What this repository already ships

Live's audio path is: Live (Windows process under this Wine fork) → PipeASIO (an ASIO driver implemented as a native PipeWire client) → PipeWire graph → ALSA → hardware. JACK is not in Live's path since release 2026.07.17.2 (`notes/ABLETON-WINE-PIPEASIO.md:3-4`).

| Mechanism | State | Evidence |
|---|---|---|
| ASIO driver | PipeASIO 1.2.2, built from `vendor/pipeasio-1.2.2.tar.gz`, plus two local patches | `notes/ABLETON-WINE-PIPEASIO.md:27-30`, `scripts/container-build.sh:133-138` |
| Sample-rate clamp | Patch 0001 keeps the PipeWire graph rate when Live requests an unsupported rate, instead of returning `ASE_NoClock`, which crashed Live at startup | `patches/pipeasio/0001-asio-keep-graph-sample-rate-instead-of-ASE_NoClock.patch:14-30` |
| MIDI timebase | Patch 0002 reports `timeGetTime` in `ASIOSystemTime` so Live's incoming MIDI events land in its expected window | `patches/pipeasio/0002-asio-report-timeGetTime-in-ASIO-systemTime.patch:17-21` |
| Buffer default | 2 inputs, 2 outputs, fixed 256-frame buffer, auto-connect; `PIPEASIO_PREFERRED_BUFFERSIZE` overrides per launch | `notes/ABLETON-WINE-PIPEASIO.md:56-59` |
| Graph quantum matching | PipeASIO sets the PipeWire graph quantum to the ASIO buffer size on PipeWire 1.6 or newer | `notes/ABLETON-WINE-PIPEASIO.md:20` |
| Realtime scheduling | Launcher probes `chrt -r 10 true` and starts Wine under `SCHED_RR` priority 10; `ABLETON_RT=off` disables this | `scripts/ableton-live:780-782`, `notes/ABLETON-WINE-RT-SCHEDULING.md:3-7` |
| Driver thread priority | PipeASIO requests `SCHED_FIFO` priority 15 for its data-loop thread, independently of the launcher policy | `notes/ABLETON-WINE-RT-SCHEDULING.md:5-7` |
| Reconnect handling | WirePlumber restores PipeASIO streams after device hotplug; the old `jacklinkd` helper is no longer started for Live | `notes/ABLETON-WINE-AUDIO-HOTPLUG.md:1-8` |
| Resampling | PipeWire resamples a device whose rate differs from the graph rate | `notes/ABLETON-WINE-AUDIO-HOTPLUG.md:34-35` |
| Diagnostics | `scripts/check-live-audio.sh` launches Live and fails on `FatalError`, a hung `Open: started`, or a missing sample-rate line | `scripts/check-live-audio.sh:26-60` |
| Benchmark harness | `scripts/bench-run.sh` records PipeWire xrun deltas and Live DSP load into `bench/results.csv` | `notes/ABLETON-WINE-RT-SCHEDULING.md:66-79` |

Measured baseline from 2026-07-17: about 8% Live DSP load at 48 kHz and 256 frames, with PipeWire's error counter rising by 2 during a short run on a loaded machine. The note itself says this is not a controlled latency comparison (`notes/ABLETON-WINE-PIPEASIO.md:83-85`).

Open hypotheses already recorded: realtime throttling (Linux caps realtime tasks at 950 ms per second), all launcher-inherited threads sharing one `SCHED_RR` priority, and Live's realtime threads outranking the `SCHED_OTHER` wineserver they make synchronous calls to (`notes/ABLETON-WINE-RT-SCHEDULING.md:31-41`). The 4-CPU `taskset` comparison that would answer these is written down but marked pending (`notes/ABLETON-WINE-RT-SCHEDULING.md:43-81`).

## WineASIO and its forks

WineASIO is the original ASIO-to-JACK driver for Wine. The upstream repository is `wineasio/wineasio`; release 1.3.0 (July 2025) loads `libjack.so.0` dynamically at runtime, removes the ASIO SDK header dependency, and keeps configuration in the registry under `HKEY_CURRENT_USER\Software\Wine\WineASIO` with environment-variable overrides (https://github.com/wineasio/wineasio/). Its default is a fixed buffer size controlled by JACK, 16 inputs and 16 outputs, and a preferred buffer size of 1024 (https://github.com/wineasio/wineasio/).

This project replaced WineASIO with PipeASIO because WineASIO summed inputs to mono and showed high latency under load (issue #4), and because WineASIO can only see ports that PipeWire's JACK layer exposes (issue #5) (`notes/ABLETON-WINE-PIPEASIO.md:9-13`). A second, structural reason appears in the hotplug note: when a device disappears, PipeWire removes the JACK links to WineASIO and does not restore them on return, so this project had to run `jacklinkd` to recreate links (`notes/ABLETON-WINE-AUDIO-HOTPLUG.md:12-19`). WineASIO's regression risk is also visible upstream: version 1.2.0 (September 2023) exists only to "fix compatibility with Wine > 8" (https://github.com/wineasio/wineasio/). No WineASIO fork adds native PipeWire support; PipeASIO is the native-PipeWire line. Unverified: this survey did not re-audit every WineASIO fork on GitHub as of August 2026.

Relevance to the moonshot: the JACK detour is already gone. The remaining WineASIO-era gap is evidence. The two comparisons the evaluation note still lists as missing (reproducing issue #4 under WineASIO on the same interface, and comparing WineASIO and PipeASIO xruns under identical load) are still open (`notes/ABLETON-WINE-PIPEASIO.md:87-95`).

## Upstream Wine audio drivers: winepulse.drv and winealsa.drv

Live uses ASIO, so these drivers matter only as a fallback path and as context for how much latency a non-ASIO path adds.

`winepulse.drv` implements the Windows WASAPI/MMDevice API over PulseAudio's API (which PipeWire serves through `pipewire-pulse`). In upstream Wine's `dlls/winepulse.drv/pulse.c`, the stream buffer target length is three periods (`attr.tlength = period_bytes * 3`), and the default device period is probed from the server's minimum request size times ten (https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/winepulse.drv/pulse.c, as fetched August 2026). Three periods of buffering plus the server's own buffering puts the winepulse path far above ASIO latency. The same source contains no environment-variable latency override. Separate crash-bug evidence in this repo: with WirePlumber stopped, PipeWire exposes only `auto_null` and winepulse can block while Live enumerates endpoints (`notes/ABLETON-WINE-AUDIO-CRASH-BUG.md:22-24`).

`winealsa.drv` talks to ALSA directly and can beat winepulse on latency, but it bypasses PipeWire, so it grabs the device exclusively and cannot share it with other applications, exactly what a desktop DAW setup must avoid. Community references still recommend JACK/WineASIO-style paths over both drivers for Live-class workloads (https://askubuntu.com/questions/1292282/high-latency-and-poor-sound-quality-when-running-ableton-live-daw-using-wine).

Relevance to the moonshot: none of these drivers should ever serve Live's engine. The one actionable item is keeping the mmdevapi enumeration path (used by winepulse) from stalling Live's startup, which patch 0021 already addresses (`notes/ABLETON-WINE-AUDIO-CRASH-BUG.md:33-36`).

## yabridge: architecture and what it implies for plugins inside Live

yabridge runs Windows VST2, VST3, and CLAP plugins in Linux DAWs. Each plugin loads in a `yabridge-host.exe` Wine process; the DAW loads a small native `.so` shim; the two exchange audio, MIDI, and parameters through shared memory and UNIX sockets (https://github.com/robbert-vdh/yabridge, https://bonnef.in/posts/linux-music-production/). Measured bridge overhead is under 1 ms, below the buffer latency (https://bonnef.in/posts/linux-music-production/).

Two design properties matter for this project:

1. Process isolation. A crashing plugin kills its own Wine process, not the host's audio engine. yabridge's plugin groups deliberately trade this isolation away: grouping plugins into one process cuts loading time and lets instances share data, but a crash then takes the whole group (https://github.com/robbert-vdh/yabridge).
2. Call coalescing. yabridge 3.2.0 prefetches transport info and process level with each VST2 audio block, caching them on the Wine side to avoid back-and-forth IPC inside one processing cycle; this measurably cut overhead for chatty plugins (https://github.com/robbert-vdh/yabridge/blob/master/CHANGELOG.md).

The implication for Live is structural and unfavorable. Live loads every VST in its own process space, inside the same process as the audio engine. A plugin that blocks, crashes, or misbehaves on the audio thread takes the whole engine down, and no PipeWire- or Wine-level tuning can change that. The yabridge model cannot be applied inside Live without re-implementing plugin hosting. What can be applied today is the workflow this repo already documents as untested: host heavy or unstable Linux-native plugins outside Live in Carla and route audio through PipeWire (`notes/ABLETON-WINE-PLUGIN-BRIDGING.md:1-6`). Unverified: whether Live 12's VST3 hosting isolates any plugin work off the realtime thread; this survey found no public evidence either way.

yabridge's performance-tuning list doubles as the de-facto REAPER-on-Wine tuning list, because that is the community that produced it: realtime scheduling privileges, a kernel with full preemption (`preempt=full` or better), `threadirqs` plus rtirq to raise sound-card interrupt priority, the `performance` CPU frequency governor, and a Wine build with fsync (`WINEFSYNC=1`) for multithreaded plugins (https://github.com/robbert-vdh/yabridge). It also warns that rtkit-imposed `RLIMIT_RTTIME` of 200000 µs can silently cap realtime threads, and that GNOME 45 and newer force applications through rtkit (https://github.com/robbert-vdh/yabridge).

## PipeWire pro-audio settings

PipeWire's latency is `quantum / rate`. The upstream default quantum is 1024; at 48 kHz that is 21.3 ms per buffer, while 256 is 5.3 ms, 128 is 2.7 ms, and 64 is 1.3 ms (https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view).

| Setting | Effect | Source |
|---|---|---|
| `default.clock.quantum` | Graph buffer size; default 1024 | https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view |
| `default.clock.min-quantum` / `max-quantum` | Bounds what clients may request | same |
| `default.clock.rate` / `allowed-rates` | Graph rate; restricting rates avoids runtime rate switches | same |
| `pw-metadata -n settings 0 clock.force-quantum N` | Forces the graph quantum at runtime | same; this repo's own check script already points users at `pw-metadata -n settings` for forced clock rates (`scripts/check-live-audio.sh:57-60`) |
| `module.rt` `rt.prio` | Realtime priority of PipeWire's data threads (example: 88) | https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view |
| `api.alsa.disable-batch`, `api.alsa.headroom`, `api.alsa.period-size`, `api.alsa.period-num` | ALSA device buffering in WirePlumber rules | same |
| `PIPEWIRE_LATENCY=256/48000` | Per-client latency request (frames/rate) | https://juij.fun/static/Wine%20%26%20Proton%20%E5%85%BC%E5%AE%B9%E5%B1%82%E7%8E%AF%E5%A2%83%E5%8F%98%E9%87%8F%E5%8F%8A%E5%90%AF%E5%8A%A8%E9%A1%B9%E5%8F%82%E6%95%B0%E5%8F%82%E8%80%83 |

Two caveats from practice. USB interfaces often need 512 frames as the stable minimum, while built-in HDA can reach 256 and good PCIe cards 64 (https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view). And a 2023 community test found PipeWire stable at 256 samples (about 18 ms round trip) but producing xruns when pushed lower: dated, but it shows that graph-wide stability, not the driver, is the usual binding constraint (https://linuxcreative.com/articles/pipewire-the-next-big-thing-in-linux-audio-production/).

Interaction with this repo: PipeASIO already forces the graph quantum to the ASIO buffer on PipeWire 1.6+ (`notes/ABLETON-WINE-PIPEASIO.md:20`), but the shipped runtime only requires host PipeWire 0.3.56 (`notes/ABLETON-WINE-PIPEASIO.md:46-48`), so hosts on older PipeWire get no quantum matching and the graph runs at its default 1024 unless the user sets it. Unverified: the fallback behavior on those hosts has not been measured by this project.

## Realtime kernels: PREEMPT, PREEMPT_DYNAMIC, PREEMPT_RT

The PREEMPT_RT patchset merged into mainline Linux 6.12 (November 2024) after about twenty years out of tree, so current kernels build realtime support without external patches; ARM followed in Linux 7.1 (https://oneuptime.com/blog/post/2026-03-02-how-to-install-real-time-kernel-preempt-rt-on-ubuntu/view, https://www.phoronix.com/linux/Arm). Ubuntu ships a supported realtime kernel as `ubuntu-realtime`, and the lower-effort `linux-lowlatency` flavor covers most audio use (https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view, https://oneuptime.com/blog/post/2026-03-02-how-to-install-real-time-kernel-preempt-rt-on-ubuntu/view).

The Arch pro-audio guide's current position: the vanilla kernel with `CONFIG_PREEMPT` is adequate for low latency in most cases; reach for a realtime kernel only when drop-outs persist or ultra-low latency is the goal, and enable `preempt=full` when the kernel is built as `PREEMPT_DYNAMIC` without full preemption selected (https://wiki.archlinux.org/title/Professional_audio). This matches yabridge's guidance (https://github.com/robbert-vdh/yabridge).

Known 2026 wrinkle: scheduler work in late 2025 added `PREEMPT_LAZY` partly because PREEMPT_RT suffered over-scheduling that hurt throughput relative to non-RT kernels (https://patchew.org/linux/20251219101502.GB1132199@noisy.programming.kicks-ass.net/). For a DAW workload the trade still favors RT or at least full preemption, but "RT kernel" is not a free win; it mainly buys worst-case scheduling jitter, not average speed.

## rtkit and realtime privileges

rtkit (RealtimeKit) is a D-Bus service that grants realtime scheduling to unprivileged processes under strict caps. Its daemon hands out at most realtime priority 20 and only to processes whose `RLIMIT_RTTIME` is at most 200 ms; it never accepts an unlimited RTTIME (https://sources.debian.org/src/rtkit/0.10-2+wheezy1/rtkit-daemon.c/). RTTIME is the kernel's per-process realtime CPU-time budget; exceeding it kills or throttles the thread.

This creates two failure modes relevant here. First, a user without `rtprio` limits falls back to rtkit, whose priority ceiling of 20 sits below the priorities JACK and PipeWire documentation assume; the pro-audio consensus is to prefer `RLIMIT_RTPRIO` through `limits.conf` (or the `realtime-privileges` package) over rtkit (https://github.com/rerdavies/pipedal/discussions/99). Second, yabridge documents the 200 ms RTTIME cap as a concrete cause of warnings and throttled audio threads, and notes GNOME 45+ forces this path (https://github.com/robbert-vdh/yabridge).

This repo's launcher needs `rtprio` to succeed at its `chrt -r 10` probe (`scripts/ableton-live:780-782`), and `scripts/setup-realtime.sh` installs that permission; the script deliberately leaves out a wineserver `chrt -f -p 95` boost because it needs root (`scripts/setup-realtime.sh:13-23`). The moonshot decision to make is whether the priority ladder (PipeWire data threads (rtkit/rt.prio), Live under RR 10, PipeASIO at FIFO 15, wineserver at `SCHED_OTHER`) is the right order. Today the component Live's realtime threads block on most, wineserver, has the lowest priority. That is a classic priority-inversion shape, already listed as an unconfirmed hypothesis in the RT note (`notes/ABLETON-WINE-RT-SCHEDULING.md:38-41`).

## JACK versus PipeWire for this use case

The Arch guide calls JACK the mature, pro-audio-designed server and PipeWire "a sufficient server for most of the use cases," while noting open doubt about PipeWire for professional work (https://wiki.archlinux.org/title/Professional_audio). The strongest 2026 measurement found is the SuperCollider scsynth experiment: a native PipeWire backend showed 40-50% lower CPU than the JACK-on-PipeWire shim at equal DSP load, but pinning both to the same cores erased the gap: the kernel had been placing the shim's audio thread on an efficiency core and the native client's thread on a performance core of a hybrid CPU (https://scsynth.org/t/experimental-native-pipewire-audio-backend-for-scsynth-linux-feedback-wanted/13292). Two conclusions transfer directly. The JACK compatibility layer itself adds negligible per-callback work. And thread placement, especially on hybrid Intel/AMD CPUs, can dominate every other tuning decision.

For this project the JACK-versus-PipeWire question is settled: PipeASIO made Live a native PipeWire client, which also fixed hotplug and port-visibility issues JACK could not (`notes/ABLETON-WINE-PIPEASIO.md:9-21`, `notes/ABLETON-WINE-AUDIO-HOTPLUG.md:12-19`). The transferable lesson from the scsynth data is different: verify which cores Live's and PipeASIO's threads land on, and consider pinning, before touching kernels.

## Native Linux DAW reference points

Native DAWs show what the same hardware can do without Wine in the path.

| Reference | Latency data point | Source |
|---|---|---|
| JACK math (applies to any DAW) | 128 frames, 2 periods, 48 kHz: 2.7 ms capture + 5.3 ms playback ≈ 8 ms round trip; "comparable to a stage monitor 2-3 m from the ear" | https://wiki.archlinux.org/title/Professional_audio |
| REAPER native Linux | Community reports of 1.4/2.9 ms latency settings in REAPER's own audio device settings, which operate independently of PipeWire | https://forum.cockos.com/showthread.php?p=2628855, https://forum.cockos.com/showthread.php?p=2879612 |
| Ardour | Uses the same JACK/PipeWire-JACK stack; per-application quantum/rate settings let each program run its intended buffer without forcing the whole graph | https://discourse.ardour.org/t/ardour-and-pipewire-jack-quantum-sample-rate-settings/113166 |
| Bitwig Studio | Community comparison: moving from PipeWire back to real JACK let Pianoteq divide its buffer by 4, with a smaller Bitwig improvement | https://bbs.archlinux.org/viewtopic.php?id=304116&p=2 |
| SuperCollider scsynth | Native PipeWire backend sustains about 2500 voices versus 1500 through the JACK shim on one hybrid CPU (an artifact of core placement, not the shim) | https://scsynth.org/t/experimental-native-pipewire-audio-backend-for-scsynth-linux-feedback-wanted/13292 |

These are one-machine anecdotes and forum posts, not controlled benchmarks; treat the exact numbers as indicative. The consistent picture: native engines on tuned systems run stable at 128-frame buffers and below, and REAPER and Bitwig set buffer size inside the application, which then drives the graph: the same shape PipeASIO's quantum matching gives Live on PipeWire 1.6+.

## Gaps between this repo and the ecosystem

- Buffer size is fixed at 256 frames by default with a per-launch environment override; nothing measures or recommends a lower per-machine value (`notes/ABLETON-WINE-PIPEASIO.md:56-59`).
- The scheduler priority ladder (rtkit/PipeWire, RR 10, FIFO 15, wineserver) is unmeasured; the pending `taskset` comparison covers CPU count but not priority ordering or wineserver inversion (`notes/ABLETON-WINE-RT-SCHEDULING.md:43-81`).
- No tooling checks hybrid-core thread placement, governor, `threadirqs`, or RTTIME limits; `scripts/setup-realtime.sh` covers only `rtprio` (`scripts/setup-realtime.sh:13-23`).
- No round-trip latency measurement exists in the repo; `scripts/check-live-audio.sh` verifies the driver opens, not the latency it achieves (`scripts/check-live-audio.sh:26-60`).
- The PipeWire-older-than-1.6 path (no quantum matching) has no measured fallback behavior (`notes/ABLETON-WINE-PIPEASIO.md:20`, `notes/ABLETON-WINE-PIPEASIO.md:46-48`).
- Plugin process isolation does not exist inside Live; the external-host workaround is documented but untested (`notes/ABLETON-WINE-PLUGIN-BRIDGING.md:1-6`).

## Key opportunities

1. Run the pending scheduler comparison and add a wineserver-priority arm. Impact: high. Effort: low. Evidence: the comparison protocol already exists but is unrun (`notes/ABLETON-WINE-RT-SCHEDULING.md:43-81`), and the wineserver inversion hypothesis is already recorded (`notes/ABLETON-WINE-RT-SCHEDULING.md:38-41`); `scripts/setup-realtime.sh:23` notes the wineserver boost was left out for want of root.
2. Measure and lower the default buffer below 256 frames on capable hardware, with a documented per-interface floor (512 for USB, 128-256 for HDA). Impact: high (halves or quarters buffer latency). Effort: low. Evidence: current fixed 256-frame default (`notes/ABLETON-WINE-PIPEASIO.md:56-59`); quantum/latency table and per-interface guidance at https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view.
3. Add a round-trip latency probe to the tester kit using a loopback cable and a JACK-tool-style measurement through PipeWire. Impact: medium (turns "feels faster" into a number, feeding `bench/results.csv`). Effort: medium. Evidence: no RTL tooling exists in-repo (`scripts/check-live-audio.sh:26-60` checks only driver-open); the `jack_iodelay` method is standard (https://wiki.archlinux.org/title/Professional_audio, https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view).
4. Audit hybrid-core thread placement for Live, PipeASIO, PipeWire, and wineserver; add optional `taskset`/cpuset guidance or pinning to the launcher. Impact: high on affected CPUs. Effort: medium. Evidence: the scsynth benchmark showed a 40-50% CPU swing from efficiency-versus-performance core placement, erased by pinning (https://scsynth.org/t/experimental-native-pipewire-audio-backend-for-scsynth-linux-feedback-wanted/13292); the launcher already has CPU-count capping groundwork (`scripts/ableton-live:75-107`).
5. Extend `scripts/setup-realtime.sh` into a full host-audio audit: governor, `threadirqs`/rtirq, RTTIME limits, rtkit presence (GNOME 45+), swappiness, and PipeWire `rt.prio`. Impact: medium. Effort: low. Evidence: each item is a documented xrun cause (https://github.com/robbert-vdh/yabridge, https://wiki.archlinux.org/title/Professional_audio); the script currently covers only `rtprio` (`scripts/setup-realtime.sh:13-23`).
6. Define the behavior on host PipeWire older than 1.6: either require 1.6 for quantum matching or ship a `clock.force-quantum` fallback set at install time. Impact: medium. Effort: low. Evidence: matching requires 1.6 but the runtime accepts 0.3.56 (`notes/ABLETON-WINE-PIPEASIO.md:20`, `notes/ABLETON-WINE-PIPEASIO.md:46-48`); `pw-metadata` forcing is the documented runtime mechanism (https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view) and this repo's own troubleshooting already uses it (`scripts/check-live-audio.sh:57-60`).
7. Lock the PipeWire graph rate to the hardware rate (`default.clock.rate`/`allowed-rates`) so PipeWire never resamples Live or a returning device. Impact: medium (removes resampler CPU and a latency source). Effort: low. Evidence: PipeWire resamples rate-mismatched devices today (`notes/ABLETON-WINE-AUDIO-HOTPLUG.md:34-35`); allowed-rates configuration at https://oneuptime.com/blog/post/2026-03-02-configure-pipewire-low-latency-audio-ubuntu/view.
8. Test and document the external-plugin-host workflow (Carla via PipeWire) as the supported way to isolate unstable plugins from Live's audio thread. Impact: medium (stability, not latency). Effort: medium. Evidence: workflow documented but untested (`notes/ABLETON-WINE-PLUGIN-BRIDGING.md:1-6`); yabridge demonstrates the isolation-versus-IPC trade-off (https://github.com/robbert-vdh/yabridge).
9. Run the missing WineASIO-versus-PipeASIO xrun comparison under identical load to close the last evidence gap from the 2026-07-17 evaluation. Impact: low (confirms a decision already made). Effort: medium. Evidence: the gap is explicitly listed (`notes/ABLETON-WINE-PIPEASIO.md:87-95`).
10. Evaluate a full-preemption or PREEMPT_RT kernel as a supported configuration, with measured xrun deltas rather than a blanket recommendation. Impact: medium (worst-case jitter, not average speed). Effort: medium. Evidence: PREEMPT_RT is mainline since 6.12 (https://oneuptime.com/blog/post/2026-03-02-how-to-install-real-time-kernel-preempt-rt-on-ubuntu/view); vanilla kernels are adequate for most setups (https://wiki.archlinux.org/title/Professional_audio); RT has measurable scheduling overheads (https://patchew.org/linux/20251219101502.GB1132199@noisy.programming.kicks-ass.net/).
