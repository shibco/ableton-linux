# Default-on feature audit

Date: 23 August 2026

This audit reviewed merged and closed pull requests that added user-facing
behaviour behind launcher or runtime settings. Two features were present on
`main` but disabled for a normal launch. This branch turns both on. The audio
worker policy still needs the low-core workload test described below.

## Changes in this branch

| Pull requests | Feature | Decision |
|---|---|---|
| [#153](https://github.com/shibco/ableton-linux/pull/153) | GNOME global shortcut hold | Default to `ABLETON_SHORTCUTS=take`. Keep `preserve` as the opt-out. The existing recovery, concurrency, and user-edit safeguards remain. |
| [#236](https://github.com/shibco/ableton-linux/pull/236), [#249](https://github.com/shibco/ableton-linux/pull/249) | Live 12 `-MaxAudioThreads` policy and replacement fix | Use the greater of the physical core count and half of Live's own worker count, up to Live's own count. Give priority to an existing setting or a user edit. `auto` calculates a launcher value again. `off` removes that launcher value and lets Live choose. |

## Merged features already active

No default change is needed for these features:

| Pull requests | Current normal-launch behaviour |
|---|---|
| [#80](https://github.com/shibco/ableton-linux/pull/80) | Ableton Link uses session mode after a normal install. |
| [#94](https://github.com/shibco/ableton-linux/pull/94) | GPU presentation support is active. |
| [#114](https://github.com/shibco/ableton-linux/pull/114), [#125](https://github.com/shibco/ableton-linux/pull/125) | Live fullscreen and resizability fixes are active. |
| [#155](https://github.com/shibco/ableton-linux/pull/155) | Subpixel text rendering is active. |
| [#169](https://github.com/shibco/ableton-linux/pull/169), [#188](https://github.com/shibco/ableton-linux/pull/188), [#195](https://github.com/shibco/ableton-linux/pull/195) | Current patch 0100 consolidates the pointer stack. Precise scrolling stays active, and ordinary button drags suspend XI2 motion. Patch 0101 manages external drop targets. |
| [#186](https://github.com/shibco/ableton-linux/pull/186) | The Max for Live host-font cache is active. |

Current `main` replaced the separate pointer patches with consolidated patch
0100. The consolidated patch keeps precise scrolling enabled and suspends XI2
motion for ordinary core button drags. Patch 0101 contains the external
drag-and-drop lifecycle fixes. Precise scrolling is an active feature on
current `main`, with the fader-drag protection in the same patch.

## Features that remain explicit

| Pull request or evidence | Decision |
|---|---|
| [#187](https://github.com/shibco/ableton-linux/pull/187) | Keep `WINE_D3D_FORCE_GPU_RENDERING=1` explicit. It spoofs a PCI identity for every application in the prefix and is an override for Live's denylist, not a safe general default. |
| [PipeASIO issue 4](https://github.com/M0n7y5/pipeasio/issues/4) and [performance notes](https://github.com/M0n7y5/pipeasio/blob/v1.5.0/README.md#performance) | Keep PipeASIO real-time scheduling off. The upstream Ableton regression was traced to the callback entering `SCHED_FIFO`, and upstream reports substantially more xruns in one multi-threaded-host test when it is enabled. |
| Launcher-wide `ABLETON_RT` | Keep the current policy until an AVRT/MMCSS prototype can distinguish Live's `Pro Audio` threads from GUI and background threads. This branch does not guess at a new scheduler model. |

[#249](https://github.com/shibco/ableton-linux/pull/249) fixed replacement of
an earlier launcher-managed worker count. Comparisons made on the older branch
after requesting a second value cannot establish that the second value took
effect. [#237](https://github.com/shibco/ableton-linux/pull/237) predates the
worker-setting change and does not package `live-options.sh`, so a NixOS run on
that branch cannot test the worker policy.

[#145](https://github.com/shibco/ableton-linux/pull/145) merged into
`performance-moonshot`, not `main`. Its carrying
[#118](https://github.com/shibco/ableton-linux/pull/118) remains open. Current
`main` therefore has none of those Wine APC or message fast paths. Their small
idle-process result, about 3% with no measured Live-process improvement, does
not justify copying stale patches into this defaults change.

## CPU attribution correction

Live's CPU meters report audio-processing time relative to the buffer deadline,
not Linux process CPU. This distinction is documented by
[Ableton](https://help.ableton.com/hc/en-us/articles/360019151379-Live-s-CPU-Meter).
The measurements in #236 used Linux process CPU and voluntary context switches.
The patch wrote Live's `-MaxAudioThreads` option and changed no PipeASIO or Wine
audio-path file. The result is a Live worker-coordination result, not a
PipeASIO hot-path optimisation.

At 48 kHz, the callback rate is `48000 / buffer_frames`. The rounded reports
fit about 1.64 ms of aggregate Linux process CPU per callback without NTSync
and 0.134 ms with NTSync. The values sum CPU time across Live's threads, so
they can exceed the 1.33 ms wall period at 64 frames. The difference is about
twelve-fold, or roughly 92% of the aggregate per-callback CPU. The
inverse-buffer relationship is consistent with wake and wait coordination.
The relationship alone cannot identify one component.

The headless driver test recorded in
[#170](https://github.com/shibco/ableton-linux/pull/170#issuecomment-5266487099)
used two inputs, two outputs, and 128 frames without Live DSP. It measured about
0.5% process CPU. This does not measure a real Live Set, but it argues against
an expensive steady-state native driver loop.

The presence of `/dev/ntsync` is only a host capability check. Close Live and
run the installed `~/.local/share/ableton-wine/check-ntsync.sh` command. It
verifies runtime support, the test wineserver's device use, and Windows
synchronisation semantics.

## Audio worker release validation

The available measurement used an empty Set on one 16-core, 32-thread host.
The 8-worker result used the same host and reduced process CPU further than 16
workers. Those results do not establish the safe default for a demanding Set
or a low-core host.

A later same-host project report found lower Average CPU values with the
physical-core policy, especially at 32 and 64 frames. The complex Set still
spiked above its deadlines at those sizes, and its 128-frame overload rate
stayed comparable or rose slightly. The exact commit, worker count, and host
topology remain unrecorded. The
[same-host project report](FINDINGS-PIPEASIO-CPU-2026-08-20.md#same-host-project-report)
records the values and scope.

Before release, compare the physical-core value, the automatic value and Live's
own value. Use a computer with 4 to 8 physical cores. Test 32, 64 and 128 frames.
Use a demanding Set with independent audio chains. Record Live's deadline
meter, audible dropouts and Linux process CPU. Record PipeWire xruns, which
count missed audio periods.

## Separate engineering work

The current launcher can place the whole Wine process, including GUI threads,
under `SCHED_RR` at priority 10. PipeASIO then uses normal scheduling for its
callback by default or `SCHED_FIFO` at priority 15 when explicitly enabled.
The runtime's AVRT entry points do not yet map Live's `Pro Audio` request to a
selective Linux audio-thread policy. This does not reproduce Windows' audio
and UI priority structure.

Callback phase telemetry and selective AVRT/MMCSS scheduling belong in focused
changes, not in a default-policy branch. Telemetry should record both monotonic
wall time and `CLOCK_THREAD_CPUTIME_ID` for callback entry, time inside Live's
`swapBuffersWithTimeInfo`, and output queuing. It should publish only aggregate
p50, p95, p99, and maximum values away from the audio thread.

A high wall-time and low callback-CPU result inside Live points to worker waits
or scheduler delay. High callback CPU points to DSP or spinning. High pre-call
or post-call time points back to PipeASIO. Moving the callback blindly to
`PW_FILTER_FLAG_RT_PROCESS` is not a substitute: the PipeASIO maintainer
reports that PipeWire then invokes Wine code on a thread without a Wine TEB,
which crashes. See
[PipeASIO issue 21](https://github.com/M0n7y5/pipeasio/issues/21).
PipeASIO has no steady-state busy poll in this path. It calls Live once per
PipeWire graph period after upstream removed `node.async` to save one quantum
of latency.
