# PipeASIO callback timing

Date: 26 August 2026

## Use

Use the timing report to find where each audio callback spends time. Run normal
CPU comparisons with the default setting.

Start one controlled timing run with:

```sh
env PIPEASIO_TELEMETRY=on ableton-live
```

Set `PIPEASIO_TELEMETRY=on` to start telemetry. The default path performs zero
telemetry clock reads.

The driver reports results once per second. It measures these 3 parts:

- work in PipeASIO before Live receives the buffer
- time inside Live's buffer callback
- PipeASIO work after Live returns the buffer

Each part reports elapsed time and callback thread CPU time. The report includes
`p50`, `p95`, `p99`, and the largest value.

Long elapsed time with little CPU use often means that the thread waited. High
CPU time shows work on the callback thread.

## Audio safety rules

The callback writes fixed numeric samples into a fixed-size queue. A full queue
discards samples and counts each discarded sample.

A separate worker copies, sorts, and summarises the samples once per second.
The audio callback continues during that work.

The output write returns immediately when a pipe reaches capacity. The driver
discards that report. Slow storage can delay the separate worker while the
callback continues.

During shutdown, the driver removes the shared timing state before it closes
or frees that state.

## Measurement limits

Each measured callback reads a clock 6 times. These reads change the measured
work. Use default mode for before and after CPU results.

Use timing reports with the 30-second benchmark, PipeWire error counts, and
Live's CPU value. Add a listening result when you assess audible crackle.

## Release checks

The 2 patches apply after PipeASIO patch 0012. Run the unit, ABI, minimal driver,
ASan, UBSan, and TSan tests with the normal runtime build.

Run PipeWire tests at 32, 64, 128, and 256 frames. Compare default and enabled
timing runs to measure the added work. Use a slow report destination to check
discarded reports and audio deadlines.
