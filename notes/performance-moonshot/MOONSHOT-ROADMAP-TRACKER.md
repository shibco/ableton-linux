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
| P1 | Host `/dev/ntsync` launch gate | high | minimal | recovers a silently lost ~1 core / 4-50x sync on affected hosts | very high | in progress |
| P2 | Run the written scheduling A/B | n/a (measurement) | none | decides the RR default, quantifies the inversion | high | in progress |
| P3 | Audio hardening F0-F8 + PipeWire host arm | high | medium | fixes the audible defect classes (issue 49, crackle, recording offsets) | high | in progress |
| P4 | Thread-priority chain (avrt de-stub, server RT band, retire whole-process RR, RTKit) | high problem / medium gain | high | audio outranks UI per thread; biggest dropout-margin lever at 64-128 frames | medium-high | not started |
| P5 | Idle-thread trace, then APC/alertable fast path | high cost / medium mechanism | high | 30-40% idle core to under 5%, server churn cut | medium | not started |
| P6 | Present path finishing (reblit timers, popup GL, flush throttle) | high waste | medium-high | idle pane damage near zero, popups off the copy path | medium-high | not started |
| P7 | fsync fallback tier, issue 109, ntsync off-switch | high | medium | pre-6.14 hosts recover most of the sync win | medium-high | not started |
| P8 | Topology consumer port-or-delete, hybrid placement (no 8-cap default) | high inertness / medium gain | medium | P/E-core placement; scsynth precedent is a 40-50% swing | medium-high | not started |
| P9 | nspa memory ports (mlockall, TEB), source availability first | medium | medium | deadline-tail insurance | medium | not started |
| P10 | Timing fidelity (version check, then QPC/TSC, MIDI jitter) | low-medium | low | fidelity, not throughput | medium | not started |
| P11 | One contained compiler-flag pair series | high (that gains are small) | low | closes the flags debate with pairs | uncertain by design | not started |
| P12 | Device hotplug, MIDI and audio, any order, any time | high problem / medium mechanism | medium-high | any controller works whether it is plugged in before or after Live starts, and recovers on its own after any unplug | medium | not started |

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

- P2 low-core arms ran 2026-08-02: on a 4-CPU cpuset, whole-process RR
  produced zero xruns idle and playing where `ABLETON_RT=off` produced 242
  and 228, so the launcher default stands; the same arm started Live about
  six times slower there, which is the cost P4's narrowing targets. Full
  rows: `notes/FINDINGS-RT-AB-2026-08-02.md`. Still open in P2: the
  wineserver `chrt -f` boost arm (needs root), the narrowed arm (needs
  P4), loaded-set re-runs (need the reference set), and a many-core
  off-pair.
- P3 started 2026-08-02 with F0 from the plan of record
  (`notes/ABLETON-WINE-PIPEASIO-CRACKLE.md`, ported from
  `fixes/audio-hardening` with a status addendum): launcher session log,
  driver warnings kept visible, startup pin warning,
  `scripts/audio-report.sh`, and pipeasio patch 0003 correcting the
  mismatch warning text. F6 was already closed by P1; F4 as written is
  rejected by the P2 measurement and folds into P4. F2 landed 2026-08-02
  as pipeasio patch 0004: any buffer size in [16, 8192] is accepted, every
  adjustment is logged, nothing is substituted silently; verified end to
  end at 192 the same day. F1 landed the same day as pipeasio patch 0005:
  predict (offer a global forced quantum from GetBufferSize), adopt
  (two-poll watcher convergence with a per-minute cap), mute-on-mismatch
  with PIPEASIO_ALLOW_QUANTUM_MISMATCH=on as the escape hatch, and port
  buffers sized to the quantum limit; verified in production the same day
  (pre-launch pin 384 predicted cleanly, mid-run pin 768 converged with
  one mute episode; G1 answered yes). Next: F8. Driver patches need a
  container build to ship.
- P12 added 2026-08-02 from issue 46 and the Discord thread behind it.
  The goal is one sentence: any MIDI or audio device works whether it was
  connected before Live started or after it started, and comes back on its
  own after any unplug, without restarting Live. Patch 0028 covers one
  quadrant of that today. A MIDI device Wine enumerated at startup is
  re-subscribed when it returns, matched by display name on
  `SND_SEQ_EVENT_PORT_START`. A device first connected after startup stays
  invisible until Live restarts. Three layers hold that shut, all read in
  the sources on 2026-08-02: `alsa_midi_init()` is one-shot behind
  `init_done`, and `port_add()` reallocs the `srcs`/`dests` arrays, so
  growing the table at runtime moves entries that other threads hold
  pointers into; winmm fixes the device count in `llTypes[type].wMaxId`
  during `MMDRV_InitPerType()` and never raises it, so `midiInGetNumDevs()`
  stays stale even if the driver does grow; and nothing in the prefix
  broadcasts `WM_DEVICECHANGE`, so Live is never told to re-enumerate. The
  audio half is a different mechanism, not the same fix twice: PipeASIO
  already watches the PipeWire registry
  (`audio_on_registry_global`/`_global_remove`) and already owns a host
  reset path (`kAsioResetRequest`), so what it needs is a stated policy for
  a selected device that disappears and returns, not new plumbing. First
  step is the four-quadrant behaviour matrix, MIDI and audio against
  before-start and after-start, measured on real hardware; work happens in
  the `moonshot-midi-hotplug` worktree. P12 owns no patch numbers yet.
- Wine patches from moonshot items land in `patches/performance/`;
  apply-order wiring in `container-build.sh` and build-audit fingerprint
  entries land with the first such patch. P1 produced no patch (launcher,
  setup, and docs only).

## Ordering constraints

- Whole-process RR stays the default until P2 and P4 produce the evidence
  to retire it (P4 step c depends on P2 pairs).
- The `WINEDEBUG=+server` trace gates any P5 patch work.
- P3's capture tooling (F0) lands before any quantum behavior change.
- P9 starts with verifying that wine-nspa 11.x sources are available.
- P12's audio half sits behind P3 F8: patch 0006 defined how a device is
  chosen and cached, and any reattach policy has to agree with it. P12's
  MIDI half is independent and can start now.

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
