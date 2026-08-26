# CPU and audio benchmark guide

Use this suite to compare Live CPU use and audio performance before and after
one change. Start a normal run with:

```bash
scripts/bench-suite.sh --tag before/my-change
```

The suite measures 5 sets for 30 seconds each. It uses this order:

1. Run `Benchmark_Zero` with Live idle and the control device closed.
2. Run `Benchmark_Empty` with only the control device.
3. Run `Benchmark_Inbuilts` with Live instruments and effects.
4. Run `Benchmark_Max4Live` with Live and Max for Live devices.
5. Run `Benchmark_VSTs` with Dexed and Nils' K1v.

## Measurement period

One `--duration` value applies to every set. Its default value is exactly 30
seconds.

The suite uses one deadline for CPU figures, OSC messages, `pw-top`, and
PipeWire settings. Set start-up and stabilisation happen before that period.

CPU snapshots extend a few milliseconds around the requested period. The data
collectors start one after another just after the period starts.

The JSON records the CPU interval, collection bounds, process lifetime, and
first and last output times. A usable collector runs for at least 29 seconds
and produces data. Periodic OSC and `pw-top` data cover both the first and last
second. An early exit or a silent final period gives limited crackle evidence.

Check the planned run with:

```bash
scripts/bench-suite.sh --dry-run --tag before/my-change
```

## Session safety

Let the suite start and close Live. Before it starts, the suite checks these
conditions:

- an idle Live session and selected Wine prefix
- the OSC report port is available
- each set file has the expected hash
- the required VST3 files are present

Each launch receives a unique session token. The suite checks that token and
the exact Live process before it sends a signal. Other Wine sessions remain
outside that process selection. PipeWire settings and profiles retain their
original values.

## Report contents

The suite creates an ignored folder under `bench/reports/`. Use `--output` to
choose another folder.

The main files have these purposes:

| Path | Contents |
|---|---|
| `report.json` | full machine-readable results |
| `report.md` | short results table and run identity |
| `run.json` | tag, set order, duration, status, and runner hash |
| `suite.log` | start-up, set changes, and session close events |
| `profile/profile.json` | system, hardware, audio, Wine, PipeASIO, prefix, and Live details |
| `profile/raw/` | original output from each system check |
| `sets/NN-SET/measurement.json` | CPU, thread, audio, worker, power, and crackle results for one set |
| `sets/NN-SET/raw/` | original snapshots, messages, logs, and audio error lines |

Each set records CPU use for the host, Live, Wine, PipeWire, and their threads.
It also records context switches, task changes, audio errors, Live CPU values,
and observed `AudioCalc` workers.

The report saves before and after values for interrupts, audio devices, links,
sample rate, buffer size, power profile, and CPU policy. A changed endpoint
marks a comparison limit. The report calls a difference that can explain a CPU
change a `confounder`.

PipeWire settings remain under watch throughout the measurement. A profile or
link can change and return to its first value between snapshots. Treat that
case as a measurement limit.

The prefix identity combines its ownership marker and Wine registry files into
one SHA-256 value. The runtime identity covers build details, Wine, and both
PipeASIO files.

PipeASIO selects its configuration from these locations in order:

1. Use `$XDG_CONFIG_HOME/pipeasio/config.ini` when it exists.
2. Use `$HOME/.config/pipeasio/config.ini` in other cases.

The raw manifest records every source path, file size, and hash. It also records
all Dexed and K1v file hashes and available product versions.

## Crackle evidence

Audio counters detect some problems. Listening detects other problems. Add a
listening result with:

```bash
scripts/bench-suite.sh --tag after/my-change \
  --crackle Inbuilts=not-heard \
  --crackle Max4Live=heard
```

The report uses these values:

- `detected`: PipeWire reported more errors, or a Live or PipeASIO log reported an xrun
- `manual`: the listener heard crackle and the tools recorded zero matching events
- `no-instrumented-evidence`: all usable tools completed and reported zero matching events
- `unknown`: the run needs more tool or listener evidence

`not-heard` records only the listener's experience during that run. Use the
full report to judge system stability.

Add a listening result after a run with:

```bash
python3 scripts/bench-report.py annotate \
  --run-dir bench/reports/20260826T120000Z-after \
  --set-name Benchmark_Max4Live \
  --manual-crackle heard
```

The command updates the derived JSON and Markdown files. The raw files retain
their original contents.

## Before and after comparison

Use the same Live version, Wine prefix, audio device, profile, sample rate,
buffer size, window state, and power conditions for each run.

```bash
scripts/bench-suite.sh --tag before/my-change
# Enable one change, then let the suite start Live.
scripts/bench-suite.sh --tag after/my-change
```

Create the comparison after both runs finish:

```bash
python3 scripts/bench-report.py compare \
  --before bench/reports/BEFORE --after bench/reports/AFTER \
  --output bench/reports/BEFORE-vs-AFTER
# Equivalent command:
make bench-compare BEFORE=... AFTER=... OUTPUT=...
```

The command accepts complete canonical runs with matching 30-second periods
and endpoint timing evidence. It writes `comparison.json` and `comparison.md`.

The report lists changes in hardware, audio, PipeWire, Wine, Live, settings,
plug-ins, power, and the `WINE_APC_FASTPATH` value. Review each listed change
before you accept a CPU result.

Each set includes before, after, difference, and percentage values. These values
cover CPU use, scheduling, audio, task changes, collection time, and interrupts.
The status field records `undefined` when sampling yields zero records or the
starting value equals zero.

One pair describes one result. Repeated pairs support a stronger conclusion.
Review the JSON values for each component instead of one total value.

Endpoint snapshots cover processes and threads present at either endpoint.
Short-lived tasks between the endpoints remain outside those snapshots. Review
task changes, node changes, buffer changes, audio errors, settings changes, and
OSC coverage before you accept the result.

## Individual measurement tools

`scripts/bench-run.sh` measures one set that you already opened. The full suite
manages the Live session and set order.

`scripts/bench-osc.py` sends and receives control messages. Each command provides
usage details through `--help`.

## Set files

Keep the committed `.als` files, audio samples, and control device unchanged.
Add a newly named set when you change its contents.

Live places generated files in `Backup/` folders. Git ignores these folders.
Keep generated backups outside commits.

Preflight checks every set against `bench/SHA256SUMS` before it creates a report
folder. `Benchmark_VSTs` uses the Windows VST3 files from the
[benchmark set guide](BenchmarkSets%20Project/README.md).

Run the test suite with:

```bash
make test-bench
```
