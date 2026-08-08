# Benchmarks

This directory holds the measurement protocol and the recorded results for
performance work on this stack. A performance change ships only with a
committed before/after pair of rows from the tools below.

To measure a change:

```
scripts/bench-run.sh before/<change>    # Live open on the reference set
# apply the change, relaunch Live the same way
scripts/bench-run.sh after/<change>
```

For startup and load timings, close Live first; the workload tool launches
and quits Live itself:

```
scripts/bench-workload.sh before/<change> --set "bench/00-empty Project/00-empty.als" -n 3
```

Commit the appended rows together with the change they judge.

## Tools

- `scripts/bench-run.sh` appends one steady-state row per run to
  `results.csv`: CPU shares for the wined3d_cs thread, the whole Live
  process, and the busiest other thread; the wineserver context-switch
  delta; the PipeWire xrun delta; graph rate and quantum; and the version
  set for the run. The DSP column fills itself from the abl-bench-m4l
  device's CPU reports when the set carries the device; a percentage passed
  on the command line overrides it.
- `scripts/bench-workload.sh` appends launch-scenario rows to
  `workload.csv`. It launches Live, waits for the log to go quiet, reads
  the phase timings from the timestamps in Live's own `Log.txt`, and quits
  Live. It refuses to start while Live is already running.

Each script header documents its full option list.

## Rules

- A pair is two rows tagged `before/<change>` and `after/<change>`,
  recorded on one machine under the same conditions.
- Steady-state reference conditions: the reference set open
  (`bench/reference Project/reference.als`, still to save), 48 kHz at
  256 frames, the same window size and position for both rows.
- Evidence rows use the default 300 s xrun window. `--quick` rows use a
  60 s window and are for iteration only.
- Run workload scenarios with `-n 3` or more and compare medians. The
  `warm_start` column records whether a wineserver was already running
  when the iteration launched.
- Versions are recorded per row because Live and WebView2 update
  themselves inside the prefix, and the GPU driver and kernel change with
  host updates.

## Recording a release baseline

Record these rows once per release, before any change. Steps 1 and 2 need
the reference set from the next section.

1. Open the reference set, stop the transport, and run
   `scripts/bench-run.sh baseline/idle`.
2. Play the same set from its start marker and run
   `scripts/bench-run.sh baseline/playback`.
3. Close Live and run `scripts/bench-workload.sh baseline -n 3`, then
   `scripts/bench-workload.sh baseline --set "bench/<set> Project/<set>.als" -n 3`
   for each set.
4. Commit the appended rows.

## Benchmark sets

Each set is a Live project folder saved directly under `bench/`; with
Live's default project naming the set path is
`bench/<name> Project/<name>.als`. Save each set once, commit it, and
never edit it again: a changed workload is a new file.

| Set | Exercises | State |
|---|---|---|
| `00-empty` | bare startup and document exchange | saved 2026-08-01 |
| `10-stock-synths` | stock instruments and effects only | to save |
| `20-vst` | third-party VST3 instruments and effects | to save |
| `30-m4l` | Max for Live devices | to save |
| `reference` | the steady-state set for `results.csv` rows | to save |

Pick third-party plugins that most users have installed, and record their
names and versions in this section when the set lands. To time one
specific synth, plugin, or M4L patch, save it alone in its own small set;
its load time is then that set's `set_load` row.

Every set also carries the `abl-bench-m4l` control device on a track: it
reports readiness, transport state, and the CPU meter over OSC, and takes
transport commands, so runs need no operator input in Live. Files,
protocol, and rebuild recipe: [m4l/README.md](m4l/README.md).

## Schemas

`results.csv` columns: `timestamp, tag, wined3d_cs_pct, live_proc_pct,
busy_thread_pct, busy_thread_comm, wineserver_ctxt_delta, xruns,
xrun_window_s, dsp_load_pct, pw_rate, pw_quantum, pw_force_quantum,
pw_node_quantum, live_version, webview2_version, gpu_renderer,
pipewire_version, kernel, runtime_version`. `pw_quantum` is the graph's
default from the settings metadata; `pw_node_quantum` is the quantum
Live's own node actually ran during the window, which PipeASIO forces to
the ASIO buffer size. `NA` means the metric could not be measured on that
run; the run's stderr says why.

`workload.csv` columns: `timestamp, tag, scenario, iteration, warm_start,
metric, seconds, live_version, live_build, runtime_version`. One row per
metric:

| Metric | Measures |
|---|---|
| `startup_to_audio_open` | log start to the ASIO device finishing opening |
| `startup_to_first_doc` | log start to the first document exchange finishing |
| `set_load` | start of loading the given set to the next document exchange finishing |
| `plugin_scan` | plugin scanner start to the scanner process stopping |
| `max_boot` | log start to the Max runtime reporting its version |
| `vst3_create:<name>` | one VST3 plugin from processor load to instance creation |
| `wall_to_quiet` | launch to the last log write, measured on the runner's clock |
