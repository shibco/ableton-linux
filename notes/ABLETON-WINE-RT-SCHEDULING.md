# Realtime scheduling: probe reach and low-core verification (2026-07-19)

The launcher probes `chrt -r 10` and, when it succeeds, runs the whole
Live process under SCHED_RR 10 (scripts/ableton-live, present since the
first release). The assumption was that the probe only fires after a user
runs setup-realtime.sh. Issue #29 disproved that: the reporter had
`ulimit -r` = 99 on CachyOS without ever running it. Distributions with
audio-tuned defaults grant rtprio out of the box, so whole-process RR is
already live for part of the user base with no opt-in.

Not the cause of issue #29 (2026.07.17.3 was fine under the same rights);
that was the Options.txt seed (notes/ABLETON-WINE-APC-COALESCING.md).

## Why whole-process RR is suspect on small machines

1. RT throttling: with kernel defaults (sched_rt_runtime_us 950000/
   1000000), saturated RR load loses a 50 ms non-RT window per second per
   core. On few cores that lands on the audio callback as a periodic
   stutter.
2. Same-priority round robin: every Live thread sits at RR 10, so the
   audio callback queues behind GUI and render threads for multiples of
   sched_rr_timeslice_ms (100 ms default) when cores are scarce.
3. Inversion against the wineserver: Live's RR threads outrank the
   SCHED_OTHER wineserver they do round trips through. Harmless on 32
   cores; unmeasured on 4.

## Override

`ABLETON_RT=off` (added 2026.07.19.1) skips the probe for A/B runs and as
the escape hatch on machines where RR is a net loss.

## Verification run (pending)

On a 4-core restriction of the build machine, paired via
scripts/bench-run.sh:

    taskset -c 0-3 ableton-live
    ABLETON_RT=off taskset -c 0-3 ableton-live

Confirm scheduling actually differs (`ps -eLo pid,tid,cls,rtprio,comm`
shows RR vs TS), then record pw-top xruns over 10 minutes of the reference
set and UI responsiveness in both rows. Decide from the numbers whether
the probe stays whole-process, scopes to audio threads only, or gains a
core-count floor. Until then the default stays as shipped.
