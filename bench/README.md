# CPU and audio benchmark suite

This directory contains the immutable Live workloads and the reporting protocol
for CPU/PipeASIO work. The normal command is:

```bash
scripts/bench-suite.sh --tag before/my-change
```

The suite performs five 30-second measurements, in this fixed order:

1. `Benchmark_Zero` — Live alone, idle, with no Max for Live controller.
2. `Benchmark_Empty` — the controller only, playing.
3. `Benchmark_Inbuilts` — stock devices, playing.
4. `Benchmark_Max4Live` — stock and Max for Live devices, playing.
5. `Benchmark_VSTs` — Dexed and Nils' K1v, playing.

The single `--duration` value (default exactly 30 seconds) is passed to every
set and governs the `/proc` CPU interval, OSC listener, `pw-top`, and PipeWire
metadata monitor. Startup, set readiness, and the short stabilisation period are
outside that measurement window. A quick preflight that launches nothing is:

```bash
scripts/bench-suite.sh --dry-run --tag before/my-change
```

Do not run Live yourself. The suite refuses any existing Live session, an
already-active configured Wine prefix, an occupied OSC report port, missing set
assets, or missing VST fixtures. It gives each launch a unique environment token
and revalidates that token before signalling an exact Live PID. It never runs
`wineserver -k`, never matches a global image name for teardown, and never
changes PipeWire metadata or profiles.

## Output

By default a new ignored directory is created under `bench/reports/`. Use
`--output` to put it elsewhere. It contains:

- `report.json`: complete machine-readable run/profile/set results.
- `report.md`: a compact comparison table and reproduction identity.
- `run.json`: tag, canonical order, common duration, status, and runner hash.
- `suite.log`: the complete post-preflight orchestrator and teardown narrative.
- `profile/profile.json`: system, CPU topology, GPU/audio inventory, PipeWire
  and WirePlumber state, runtime/Wine identity, prefix identity, PipeASIO and
  launcher configuration hashes, installed Live versions, `Options.txt`, and
  `MaxAudioThreads` worker setting.
- `profile/raw/`: unmodified command output including `lscpu`, PCI/USB/ALSA,
  `wpctl`, `pw-metadata`, `pw-dump`, Wine/runtime build information, and the hash
  manifest.
- `sets/NN-SET/measurement.json`: CPU/context-switch/schedstat deltas per
  process and thread, host CPU, PipeWire ERR delta, quantum transitions, OSC DSP
  average and peak, observed `AudioCalc` worker count, Live's runtime-visible
  performance/efficiency-core counts, log evidence, and crackle classification.
- `sets/NN-SET/raw/`: before/after `/proc` snapshots, `pw-top`, PipeWire
  metadata events, OSC rows, launcher diagnostics, Live log slices, and matched
  xrun lines.

The prefix identity is a documented composite SHA-256 over its ownership marker
and Wine registry files; it is not a costly hash of mutable cache content. The
runtime identity similarly covers build information, Wine, and both PipeASIO
halves. Every constituent path, size, and digest remains in the raw manifest.

## Crackle observations

Counters cannot prove what was audible. Add an observation for any set:

```bash
scripts/bench-suite.sh --tag after/my-change \
  --crackle Inbuilts=not-heard \
  --crackle Max4Live=heard
```

The report uses four deliberately narrow values:

- `detected`: a matching PipeWire ERR counter increased or an xrun-like
  PipeASIO/Live diagnostic appeared.
- `manual`: the operator heard crackle without a corroborating instrumented
  event.
- `no-instrumented-evidence`: usable instrumentation was clean. This does not
  claim that no crackle was audible.
- `unknown`: usable instrumentation was unavailable and there was no positive
  manual observation.

Manual `not-heard` is recorded separately and never turns missing
instrumentation into a clean result.

Because an observation is often known only after listening, it can be added
without rerunning Live; this rewrites only the derived measurement/report JSON
and Markdown, never the raw evidence:

```bash
python3 scripts/bench-report.py annotate \
  --run-dir bench/reports/20260826T120000Z-after \
  --set-name Benchmark_Max4Live \
  --manual-crackle heard
```

## Comparing a change

Run the same installed Live version, prefix, audio device/profile, sample rate,
quantum, window state, and power conditions for both sides:

```bash
scripts/bench-suite.sh --tag before/my-change
# install or enable exactly one change, then relaunch through the suite
scripts/bench-suite.sh --tag after/my-change
```

Compare the JSON values rather than drawing a conclusion from one total. The
report separates host utilisation, the whole Wine prefix, Live, PipeWire, and
individual threads. Treat a quantum transition, an ERR increase, a changed
profile/config hash, or a missing OSC sample as a confounder that must be
explained before accepting a CPU result.

`scripts/bench-run.sh` is the lower-level single-window collector used by the
suite. It can measure a set an operator already opened, but it does not start or
stop Wine. `scripts/bench-osc.py` is the small OSC sender/listener/probe used by
both layers. Their `--help` output documents the supported arguments.

## Workload assets

The committed `.als`, audio samples, and Max for Live controller are canonical
fixtures. Never edit a workload in place: add a newly named set when the content
must change. Live's generated `Backup/` directories are ignored and must not be
imported. Preflight verifies these inputs against `bench/SHA256SUMS` before it
creates a report directory. `Benchmark_VSTs` requires the Windows VST3 builds
of Dexed and Nils' K1v described in
[the project readme](BenchmarkSets%20Project/README.md).

The deterministic test gate needs neither Live nor PipeWire:

```bash
make test-bench
```
