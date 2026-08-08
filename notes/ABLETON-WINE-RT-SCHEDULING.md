# Realtime scheduling and low-core systems

Status: the launcher starts Wine under `SCHED_RR` priority 10 whenever
`chrt -r 10 true` succeeds. Threads that inherit this policy use RR 10.
PipeASIO separately requests `SCHED_FIFO` priority 15 for its data-loop thread.
`ABLETON_RT=off` disables the launcher's RR policy for one launch, but not
PipeASIO's policy. The effect on low-core systems has not been measured.

Realtime scheduling was not the cause of issue #29. The same host permissions
worked in release 2026.07.17.3; the later playback fault came from
`-DontCombineAPCs`. See
[ABLETON-WINE-APC-COALESCING.md](ABLETON-WINE-APC-COALESCING.md).

## Current launcher behavior

The launcher tests `chrt -r 10 true`. When it succeeds, the launch command
starts with `chrt -r 10 wine`.

`scripts/setup-realtime.sh` can grant this permission, but some distributions
already set a high `rtprio` limit. On those systems, realtime mode starts
without running the setup script.

To force normal scheduling:

```bash
ABLETON_RT=off "$HOME/.local/bin/ableton-live"
```

## Low-core risks to test

These are hypotheses, not confirmed faults:

1. Linux normally limits realtime tasks to 950 ms of each one-second period.
   Saturated realtime work can therefore be throttled for the remaining
   50 ms.
2. Live and Wine threads that inherit the launcher's policy share the same
   round-robin priority. PipeASIO instead requests FIFO 15 for its data-loop
   thread.
3. Live's realtime threads outrank the separately running
   `SCHED_OTHER` wineserver, even though they make synchronous wineserver
   calls.

## Pending comparison

List the CPUs available to the current shell:

```bash
taskset -pc "$$"
```

Skip this comparison if the list contains fewer than four CPUs. Otherwise,
replace `0-3` below with four CPU IDs from that list:

```bash
CPUS=0-3
ABLETON_RT=off taskset -c "$CPUS" "$HOME/.local/bin/ableton-live"
taskset -c "$CPUS" "$HOME/.local/bin/ableton-live"
```

Confirm the policies during each run:

```bash
ps -eLo pid,tid,cls,rtprio,comm
```

The `ABLETON_RT=off` run should show `TS` for Live and Wine threads. The
default run should show `RR` for inherited threads. PipeASIO may show `FF` in
both runs. Play the same reference set for five minutes and record the
PipeWire xrun delta, Live's DSP load, and UI response. Keep Live open and
playing while `scripts/bench-run.sh` samples it for 60 seconds:

```bash
./scripts/bench-run.sh before/launcher-rr 3 42
./scripts/bench-run.sh after/launcher-rr 1 40
```

Use `before` for the `ABLETON_RT=off` run and `after` for the default RR run.
Replace the example numbers with each run's five-minute `pw-top` ERR delta and
Live DSP percentage. The script appends the result to `bench/results.csv`.

Keep the current default until that comparison shows whether launcher-wide RR
helps, needs a CPU-count limit, or should be narrowed.

2026-08-02: the comparison ran. Launcher-wide RR eliminated all xruns on a
four-CPU cpuset (242 to 0 idle, 228 to 0 playing) and stays the default; it
also slowed Live's startup about sixfold there. Full rows and conditions:
[FINDINGS-RT-AB-2026-08-02.md](FINDINGS-RT-AB-2026-08-02.md).
