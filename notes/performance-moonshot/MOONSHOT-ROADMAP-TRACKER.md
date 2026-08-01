# Performance moonshot roadmap tracker

Started 2026-08-01. This is the working tracker for the implementation list
in `SYNTHESIS-2026-08-01.md`, kept alongside this tracker and not yet
committed; that document holds the full entry for each item: scope,
mechanism, evidence, first step, and verification. Update the Status column as work lands. A performance claim
counts as done only with a committed before/after pair from
`scripts/bench-run.sh`; every new patch needs its build-audit fingerprint
entry.

## Main list

| # | Item | Certainty | Invasiveness | Projected result | Chance | Status |
|---|---|---|---|---|---|---|
| P0 | Bench baselines + harness automation | certain | none | evidence floor for everything | high | in progress |
| P1 | Host `/dev/ntsync` launch gate | high | minimal | recovers a silently lost ~1 core / 4-50x sync on affected hosts | very high | not started |
| P2 | Run the written scheduling A/B | n/a (measurement) | none | decides the RR default, quantifies the inversion | high | not started |
| P3 | Audio hardening F0-F8 + PipeWire host arm | high | medium | fixes the audible defect classes (issue 49, crackle, recording offsets) | high | not started |
| P4 | Thread-priority chain (avrt de-stub, server RT band, retire whole-process RR, RTKit) | high problem / medium gain | high | audio outranks UI per thread; biggest dropout-margin lever at 64-128 frames | medium-high | not started |
| P5 | Idle-thread trace, then APC/alertable fast path | high cost / medium mechanism | high | 30-40% idle core to under 5%, server churn cut | medium | not started |
| P6 | Present path finishing (reblit timers, popup GL, flush throttle) | high waste | medium-high | idle pane damage near zero, popups off the copy path | medium-high | not started |
| P7 | fsync fallback tier, issue 109, ntsync off-switch | high | medium | pre-6.14 hosts recover most of the sync win | medium-high | not started |
| P8 | Topology consumer port-or-delete, hybrid placement (no 8-cap default) | high inertness / medium gain | medium | P/E-core placement; scsynth precedent is a 40-50% swing | medium-high | not started |
| P9 | nspa memory ports (mlockall, TEB), source availability first | medium | medium | deadline-tail insurance | medium | not started |
| P10 | Timing fidelity (version check, then QPC/TSC, MIDI jitter) | low-medium | low | fidelity, not throughput | medium | not started |
| P11 | One contained compiler-flag pair series | high (that gains are small) | low | closes the flags debate with pairs | uncertain by design | not started |

## Scope notes

- P0 expanded 2026-08-01: alongside the steady-state harness
  (`scripts/bench-run.sh`, widened schema, automated xrun and version
  capture), P0 now includes the scripted workload benchmark
  (`scripts/bench-workload.sh`) timing startup, set load, plugin scan, Max
  runtime boot, and per-VST3 instantiation from Live's own log timestamps.
  Protocol and schemas in `bench/README.md`. Both tools verified on real
  runs 2026-08-01. The abl-bench-m4l OSC device (`bench/m4l/`) is built
  and verified inside Live the same day: ready, playing, pong, transport
  control, and CPU telemetry in percent; `bench-run.sh` now fills
  `dsp_load_pct` from it and records the running node quantum. Sets live as Live
  project folders under `bench/`; `00-empty Project` is saved and its
  baseline is committed at 2a4f4fc: workload medians for startup and set
  load, plus a 300 s steady-state idle row with zero xruns. Still open:
  the four remaining sets and their baselines, the reference-set
  steady-state rows, and the optional `bench-workload.sh` ready-signal
  integration.

## Ordering constraints

- Whole-process RR stays the default until P2 and P4 produce the evidence
  to retire it (P4 step c depends on P2 pairs).
- The `WINEDEBUG=+server` trace gates any P5 patch work.
- P3's capture tooling (F0) lands before any quantum behavior change.
- P9 starts with verifying that wine-nspa 11.x sources are available.

## Parked tracks

| Track | Blocked on | Status |
|---|---|---|
| winepipewire.drv port (non-ASIO prefix audio) | P3 | parked |
| DXVK A/B, wined3d-Vulkan first, fixed abandon criteria | P0 baselines | parked |
| Base bump to giang17 d2d1-dcomp-11.14 | rebase window | parked |
| wine-nspa message rings and local objects | P9 source verification | parked |
| PipeASIO 1.3.0 evaluation | PipeWire 1.4.2 floor decision | parked |
| Linux-plugin bridge (yabridge model) | stable engine path | parked |
| Link Audio measurement and documentation arm | tester hardware | parked |

Opportunistic small items (patch 0046 landing, `server-Signal_Thread`,
winepulse timestamp-wrap, GPU-description diff, `wineserver -p`, docs,
Carla workflow test, file-I/O bench, THP experiment, M4L font audit,
Live 11 wmvcore, WineASIO comparison close-out) are listed in
SYNTHESIS-2026-08-01.md section 4 and are taken when passing, not tracked
here.
