# Default-on feature audit

Date: 23 August 2026

This audit reviewed merged and closed pull requests that added user-facing
behaviour behind launcher or runtime settings. Two safe features were present
on `main` but disabled for a normal launch. This branch turns both on.

## Changes in this branch

| Pull requests | Feature | Decision |
|---|---|---|
| [#153](https://github.com/shibco/ableton-linux/pull/153) | GNOME global shortcut hold | Default to `ABLETON_SHORTCUTS=take`. Keep `preserve` as the opt-out. The existing recovery, concurrency, and user-edit safeguards remain. |
| [#236](https://github.com/shibco/ableton-linux/pull/236), [#249](https://github.com/shibco/ableton-linux/pull/249) | Live 12 `-MaxAudioThreads` policy and replacement fix | Default to the physical cores available to the launcher. Preserve existing or edited settings. An explicit `auto` recalculates an untouched launcher value. |

## Merged features already active

No default change is needed for these features:

| Pull requests | Current normal-launch behaviour |
|---|---|
| [#80](https://github.com/shibco/ableton-linux/pull/80) | Ableton Link uses session mode after a normal install. |
| [#94](https://github.com/shibco/ableton-linux/pull/94) | GPU presentation support is active. |
| [#114](https://github.com/shibco/ableton-linux/pull/114), [#125](https://github.com/shibco/ableton-linux/pull/125) | Live fullscreen and resizability fixes are active. |
| [#155](https://github.com/shibco/ableton-linux/pull/155) | Subpixel text rendering is active. |
| [#169](https://github.com/shibco/ableton-linux/pull/169), [#188](https://github.com/shibco/ableton-linux/pull/188), [#195](https://github.com/shibco/ableton-linux/pull/195) | The current pointer stack, including precise scrolling, is active. |
| [#186](https://github.com/shibco/ableton-linux/pull/186) | The Max for Live host-font cache is active. |

[#198](https://github.com/shibco/ableton-linux/pull/198) temporarily disabled
smooth scrolling while the pointer stack was repaired. After #195,
[commit 3751ab7](https://github.com/shibco/ableton-linux/commit/3751ab7)
restored precise scrolling as the current default. It is not a hidden
off-by-default feature.

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
fit a fixed cost of about 1.64 ms without NTSync and 0.134 ms with NTSync. That
is about a twelve-fold reduction, or roughly 92% of the fixed per-callback
cost. The inverse-buffer relationship is consistent with wake and wait
coordination. It does not, by itself, identify one component.

The headless driver test recorded in
[#170](https://github.com/shibco/ableton-linux/pull/170#issuecomment-5266487099)
used two inputs, two outputs, and 128 frames without Live DSP. It measured about
0.5% process CPU. This does not measure a real Live Set, but it argues against
an expensive steady-state native driver loop.

The presence of `/dev/ntsync` is only a host capability check. Close Live and
run `./scripts/check-ntsync.sh` to verify that the runtime contains NTSync,
that its test wineserver opens the device, and that the synchronisation probe
passes.

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
