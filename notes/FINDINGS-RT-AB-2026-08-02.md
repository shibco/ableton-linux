# Findings: the launcher realtime A/B on four CPUs, 2026-08-02

The pending comparison from
[ABLETON-WINE-RT-SCHEDULING.md](ABLETON-WINE-RT-SCHEDULING.md) ran on
2026-08-02 (moonshot P2). Verdict: keep whole-process `SCHED_RR` as the
launcher default. On a four-CPU cpuset it produced zero xruns where normal
scheduling produced 242 idle and 228 playing, and it slowed Live's startup
about sixfold there.

## Conditions

- Machine: AMD Ryzen AI MAX+ 395, 16 cores / 32 threads; Live and the whole
  Wine tree confined with `taskset -c 0-3` (four distinct physical cores).
  PipeWire stayed unconfined, as it would on a real host.
- Set: `bench/00-empty Project/00-empty.als` with the abl-bench-m4l device;
  48 kHz, 256-frame ASIO buffer (node quantum 256, graph default 512).
- Runtime 2026.08.01.1, Live 12.4.3. One machine, same session ordering for
  both arms: fresh launch, idle window, then transport playing window.
- Rows: `bench/results.csv`, 300 s xrun windows, DSP filled by the device.
- Arms: `before/` = `ABLETON_RT=off` (no launcher realtime), `after/` =
  default launch (`chrt -r 10`, whole process). PipeASIO requests
  `SCHED_FIFO 15` for its data loop in both arms.

## Scheduling state observed per arm

| Arm | Live threads | wineserver |
|---|---|---|
| `ABLETON_RT=off` | 115 `TS`, 10 `SCHED_BATCH` (disk and trace queues), 1 `FF 15` (PipeASIO data loop) | `TS` |
| default RR | startup snapshot: 35 `RR 10`, 9 `SCHED_BATCH`; 126 threads total once running. The launcher starts the whole process under `RR 10`, so a thread runs `RR 10` unless it sets another policy, as the batch queues and the `FF 15` data loop do. | `TS` |

An unrelated host process (a Signal renderer) held two `RR 8` threads
throughout; PipeWire's data threads run `FF` at their usual priorities.

## Results

| Row | xruns/300 s | DSP % | Live proc % | wineserver ctxt/60 s |
|---|---|---|---|---|
| `before/launcher-rr-idle` | 242 | 2.4 | 8.5 | 217,831 |
| `before/launcher-rr-play` | 228 | 2.3 | 8.5 | 305,018 |
| `after/launcher-rr-idle` | 0 | 0.6 | 6.3 | 215,793 |
| `after/launcher-rr-play` | 0 | 0.6 | 7.9 | 216,326 |

Context from the P0 baseline (full machine, RR default): 0 xruns/300 s,
DSP 3.4, proc 30.4.

## The startup cost

Under the default RR arm on four CPUs, Live took about six minutes from
launch to audio-device open and telemetry, against under one minute for
the `ABLETON_RT=off` arm on the same CPUs and under half a minute
unconfined. During the delay, the log gained no lines for stretches of
about 90 seconds and then gained many at once; the process held 44 threads
(35 of them `RR 10`) with no PipeASIO thread yet; wineserver ran `TS`.
This is consistent with two hypotheses from the scheduling note: the
kernel reserves only 50 ms of each second for non-realtime tasks while
realtime tasks saturate the CPUs (the 950 ms realtime throttle), and
wineserver, which every one of those `RR` threads calls synchronously,
runs `SCHED_OTHER` and therefore only runs inside that reserve. The
mechanism is unproven; the startup delta is measured.

## What this decides, and what it does not

- The launcher default stands: with whole-process RR the low-core machine
  produced zero xruns where normal scheduling produced 242, and the DSP
  deadline ratio fell from 2.4 to 0.6 percent.
- Startup under RR on low-core machines is a separate, measured cost.
  Narrowing realtime to the audio threads (moonshot P4, plan step F4) is
  the candidate fix that keeps zero xruns at steady state and removes the
  startup delay; judge it against these rows.
- Limits: an empty set exercises the engine's idle cycle, not a loaded
  session; one machine; the playing arms carry no audio content. Re-run
  the pairs against the reference set when it exists, and on a many-core
  arm for completeness.
- Not yet run: the wineserver `chrt -f` boost arm (needs root per launch;
  `scripts/setup-realtime.sh` documents why it stays a manual experiment)
  and the narrowed-realtime arm (needs P4).
