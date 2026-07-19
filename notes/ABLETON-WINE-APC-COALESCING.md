# Live's APC coalescing: idle CPU cost and the playback-safe fix (2026-07-19)

Live under this Wine burns a steady 30-40% of a core in its engine's APC
coalescing thread. 2026.07.18.1 removed that cost by seeding
`-DontCombineAPCs` into Options.txt; playback then flooded the wineserver
with uncoalesced APCs and starved the PipeASIO callback into choppy,
slowed-down audio (issue #29, confirmed by A/B on the reporter's machine:
removing the line fixes it, restoring it reproduces it). 2026.07.19.1
reverted the seed and strips it from prefixes. This note is the plan for
winning the idle CPU back without touching Live's engine options again.

## Why coalescing costs CPU under Wine (working theory)

Live's coalescing thread batches engine APCs on a high-frequency alertable
wait. On Windows alertable waits are cheap; under Wine each one is a
wineserver round trip. ntsync does not help: it accelerates handle waits,
not alertable sleeps or APC delivery. A ~1 kHz batching loop is ~1,000
round trips/s, which matches the observed 30-40% thread.

The Live-internals half of this is inferred from the option's name and the
observed behaviour, not from profiling. Confirm before building on it:
WINEDEBUG=+server on an idle session, count select/queue_apc calls per
second from the coalescing thread, with and without the option.

## Why -DontCombineAPCs regresses playback

Uncoalesced, every engine APC is its own NtQueueApcThread: a wineserver
round trip on the playback path plus a per-APC wake of the target thread.
The wineserver is single threaded, so under playback load the storm
serializes behind it and the PipeASIO callback misses graph cycles. The
reported symptom matches a roughly half duty cycle: audio stutter at about
twice the rate of the video stutter.

## Fix: in-process user-APC delivery (patch series work)

The ntsync driver's alert mechanism exists for exactly this case: its wait
ioctls accept an alert event that aborts the wait for APC delivery. The
runtime already vendors the header and gates both binaries on ntsync
(notes/ABLETON-WINE-NTSYNC-REGRESSION.md).

1. Same-process NtQueueApcThread appends to an in-process per-thread APC
   queue and sets the target thread's ntsync alert event. One ioctl, no
   wineserver round trip.
2. Alertable waits already multiplex the alert event in-kernel; on an
   alerted wake, drain the in-process queue first, then fall through to
   the existing server-side APC check.
3. Cross-process APCs and system APCs (async I/O completion is queued by
   the server) keep the server path unchanged; the server's delivery
   notification also sets the alert event, so both sources funnel into one
   wake.
4. Result: Live's default engine config (coalescing on) gets cheap because
   the batching loop's alertable sleeps stop round-tripping, and
   -DontCombineAPCs becomes unnecessary in either mode.

Semantics to hold: per-thread user APC FIFO order across both queues,
NtTestAlert, delivery during suspend/terminate, special user APCs. Build
an apcprobe for the tester kit (pattern: ntsyncprobe) asserting delivery
order, alertable wake semantics, cross-process delivery, and I/O
completion APCs interleaved with user APCs. All assertions must pass on
the unpatched build first to establish the baseline.

## No-regression protocol

Paired runs via scripts/bench-run.sh, unpatched vs patched, each crossed
with ABLETON_RT=on/off and full cores vs `taskset -c 0-3` (low-core
stand-in; see notes/ABLETON-WINE-RT-SCHEDULING.md).

Idle: Live open, ASIO device open at 256 samples, transport stopped.
Record per-thread CPU, wineserver CPU, context switches/s (the
ntsync-regression note has the reference figures).

Playback: 10 minutes of a fixed reference set. Record pw-top xrun count on
the PipeASIO node and wineserver CPU.

Gates, all rows: playback xruns equal to the unpatched baseline (zero),
apcprobe fully green, idle coalescing-thread CPU under 5%. Any perf change
on the audio path gets this playback verification run before release; the
18.1 seed shipped on idle measurements alone, which is how issue #29
happened. Beta tester kit round before the release, not after.

## Interim position

2026.07.19.1 ships no Options.txt options and the 30-40% idle thread is
accepted until the patch lands. Distribution policy stays on surfaces this
project owns (registry, launcher environment, ~/.config/pipeasio); nothing
gets seeded into user-owned config files again.
