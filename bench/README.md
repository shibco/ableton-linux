# CPU and audio benchmark guide

Use the suite to compare Live CPU use and audio performance before and after
one change. Start a normal run with:

```bash
scripts/bench-suite.sh --tag before/my-change
```

A standard run measures 5 sets for 30 seconds each. The run order is:

1. Run `Benchmark_Zero` with Live idle and the control device closed.
2. Run `Benchmark_Empty` with the control device active.
3. Run `Benchmark_Inbuilts` with Live instruments and effects.
4. Run `Benchmark_Max4Live` with Live and Max for Live devices.
5. Run `Benchmark_VSTs` with Dexed and Nils' K1v.

## Measurement period

One `--duration` value applies to every set. Its default value is exactly 30
seconds.

The suite uses one deadline for CPU figures, OSC messages, `pw-top`, and
PipeWire settings. Set start-up and stabilisation happen before that period.

CPU snapshots extend a few milliseconds around the requested period. The tools
start one after another just after the period starts.

The JSON records the CPU interval, collection bounds, process lifetime, and
first and last output times. A usable tool covers at least 90% of the
period and loses at most one second during start and stop. For the default
period, its minimum run time is 29 seconds. OSC and `pw-top` data cover the
first and last second of that period. An early exit or a silent final period
gives limited crackle evidence.

The reporter also schedules a reading of the available system resources each
second. Each completed reading records its planned time, actual time, delay,
and collection time.

Check the planned run with:

```bash
scripts/bench-suite.sh --dry-run --tag before/my-change
```

## Session safety

Let the suite start and close Live. Before the run, the suite checks:

- the suite finds zero Live processes and zero processes in the selected Wine prefix
- the suite can use the OSC report port
- each set file matches its expected hash
- the suite finds the required VST3 files

Each launch receives a unique session token. The suite checks that token and
the exact Live process before it sends a signal. Other Wine sessions remain
outside that process selection. The suite observes PipeWire settings and
profiles. It leaves their control to Live and PipeWire.

## Report contents

The suite creates an ignored folder under `bench/reports/`. Use `--output` to
choose another folder.

The main files are:

| Path | Contents |
|---|---|
| `report.json` | full machine-readable results |
| `report.md` | short results table and run identity |
| `<machine-id>-<YYYYMMDDTHHMMSSffffffZ>_cpu-benchmark.csv` | resource readings, set results, and a machine summary |
| `run.json` | tag, set order, duration, report source ID, CSV filename, status, and runner hash |
| `suite.log` | start-up, set changes, and session close events |
| `profile/profile.json` | system, hardware, audio, Wine, PipeASIO, prefix, and Live details |
| `profile/raw/` | original output from each system check |
| `sets/NN-SET/measurement.json` | CPU, thread, audio, worker, power, and crackle results for one set |
| `sets/NN-SET/raw/` | original snapshots, messages, logs, and audio error lines |

Each set records CPU use for the host, Live, Wine, PipeWire, and their threads.
It also records context switches, task changes, audio errors, Live CPU values,
and observed `AudioCalc` workers.

## CSV resource report

Each completed resource reading has its own CSV row. That row includes the set
result, machine summary, and expected, recorded, and missed reading counts. A
set with no completed reading has a set summary row. A run with no completed
set has a profile row. You can filter one file by row type, set, or reading
time.

The resource fields cover:

- host CPU busy, idle, storage-wait, and virtual-machine-wait percentages
- system load and active task counts
- available memory and swap
- time tasks wait for CPU, memory, or storage

The machine summary records the available report storage before Live starts.

The first run creates a random report source ID in
`$ABLETON_CONFIG_HOME/cpu-benchmark-machine-id-v1`. Each CSV includes it in the
`machine_id` field, and later runs reuse it. The private file uses mode `0600`.

The report source ID links reports that share this private file. It does not
identify the hardware. The machine summary describes the hardware. The
`<machine-id>` part of the filename is this report source ID:

```text
<machine-id>-<YYYYMMDDTHHMMSSffffffZ>_cpu-benchmark.csv
```

The timestamp records the original run creation time in UTC. A listener update
rewrites the same CSV file.

Copying the private ID file makes another setup use the same report source ID.
Removing the file makes the next run create a new report source ID.

The report saves before and after values for interrupts, audio devices, links,
sample rate, buffer size, power profile, and CPU policy. A difference between
the start and end samples limits the comparison. The report lists a difference
that can explain a CPU change as a review item.

The suite records PipeWire settings throughout the measurement. A profile or
link can change and return to its first value between snapshots. Treat that
case as a measurement limit.

The prefix identity combines its ownership marker and Wine registry files into
one SHA-256 value. The runtime identity covers build details, Wine, and both
PipeASIO files.

PipeASIO checks the following locations in order:

1. Use `$XDG_CONFIG_HOME/pipeasio/config.ini` when it exists.
2. Use `$HOME/.config/pipeasio/config.ini` in other cases.

`profile/raw/hash-manifest.json` records paths, sizes, and hashes for prefix,
runtime, launcher, and PipeASIO settings files. `profile.json` records all
Dexed and K1v file hashes and available product versions.

## Crackle evidence

Audio counters detect some problems. Listening detects other problems. Add a
listening result with:

```bash
scripts/bench-suite.sh --tag after/my-change \
  --crackle Max4Live=heard
```

The report uses 4 crackle results:

- a tool detected a PipeWire error or an xrun report
- the listener heard crackle while the tools recorded zero matching events
- all usable tools completed and recorded zero matching events
- the report needs more tool or listener evidence

Each listener report describes one measured run. Use the full report to judge
system stability.

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

Keep the same Live version, Wine prefix, audio device, profile, sample rate,
and buffer size for each run. Keep the window state and power conditions equal.

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

The command accepts completed runs with the fixed 5-set order, 30-second
periods, and full sample timing. It writes `comparison.json` and
`comparison.md`.

The report lists changes in hardware, audio, PipeWire, Wine, Live, settings,
plug-ins, power, and the `WINE_APC_FASTPATH` value. Review each listed change
before you accept a CPU result.

Each set includes before, after, difference, and percentage values. The values
cover CPU use, scheduling, audio, task changes, collection time, and interrupts.
The status field records each sampling limit and each zero starting value.

One pair describes one result. Repeated pairs support a stronger conclusion.
Review the JSON values for each component instead of one total value.

The 2 process samples cover processes and threads present in either sample. A
short-lived task can start and finish between them. Its CPU use appears in host
CPU instead of the per-process values. Review task changes, node changes, buffer
changes, audio errors, settings changes, and OSC coverage before you accept the
result.

## Individual measurement tools

`scripts/bench-run.sh` measures one set that you already opened. The full suite
manages the Live session and set order.

`scripts/bench-osc.py` sends and receives control messages. Each command provides
usage details through `--help`.

## Set files

Keep the committed `.als` files, audio samples, and control device at their
recorded contents and hashes. Add a newly named set for revised contents.

Live places generated files in `Backup/` folders. Git ignores `Backup/` folders.
Keep generated backups outside commits.

Before a run, the suite checks every set against `bench/SHA256SUMS`. It creates
the report folder after that check. `Benchmark_VSTs` uses the Windows VST3 files
from the [benchmark set guide](BenchmarkSets%20Project/README.md).

Run the test suite with:

```bash
make test-bench
```
