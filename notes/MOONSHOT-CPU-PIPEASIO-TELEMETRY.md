# PipeASIO callback-phase telemetry

Date: 26 August 2026

## Decision

Ship callback telemetry as an off-by-default diagnostic, not as an optimisation.
It is the smallest measurement that can distinguish time spent in PipeASIO from
time spent inside Live and time lost waiting to be scheduled.

Enable it for one controlled run:

```sh
env PIPEASIO_TELEMETRY=on ableton-live
```

The driver reports one-second aggregates for three phases: work before Live's
buffer callback, the Live callback itself, and work after Live returns. Each
phase includes monotonic wall time and callback-thread CPU time at p50, p95,
p99 and maximum. A high wall/low CPU value points to scheduling or worker waits;
a high CPU value identifies execution on the callback thread. The normal audio
path performs no telemetry clock reads when the variable is off.

## Real-time invariants

- The callback is the only producer and never allocates, sorts, writes a file,
  formats text, locks a mutex, or waits for the reporter.
- A bounded single-producer/single-consumer ring drops samples when full.
- A lifecycle worker aggregates and sorts copied integer samples off the audio
  thread once per second.
- The report descriptor is opened with `O_NONBLOCK|O_APPEND|O_CLOEXEC`; a full
  pipe or slow filesystem drops a report instead of blocking audio.
- Shutdown detaches the telemetry state before closing it, so the callback
  cannot publish into freed storage.

## Interpretation limits

Telemetry adds six clock reads per measured callback. It is therefore unsuitable
for before/after CPU claims and remains disabled by default. Its purpose is
attribution: use it alongside the 30-second benchmark report, PipeWire ERR
deltas and Live's DSP meter. It cannot by itself prove that audio was crackle
free.

## Validation gate

The two patches apply after the current PipeASIO 0012 hotplug patch. Their unit,
ABI, no-Qt, ASan/UBSan and TSan tests must pass in the normal runtime build. A
release decision additionally needs a real PipeWire run at 32, 64, 128 and 256
frames, comparing telemetry off against on to quantify probe effect and checking
that report backpressure produces drops rather than deadline misses.
