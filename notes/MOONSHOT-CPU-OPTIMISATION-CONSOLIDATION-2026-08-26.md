# CPU optimisation consolidation

Date: 26 August 2026

## Executive decision

The strongest measured result is not a PipeASIO native-loop saving. It is a
Live worker-coordination result: on one 16-core/32-thread host at 64 frames, 16
Live workers reduced whole-Live Linux CPU by 36.77% and voluntary context
switches by 42.42%. The later loaded-Set report also favoured the physical-core
policy at 32 and 64 frames, but still showed deadline spikes. The evidence and
its limits are in `notes/FINDINGS-PIPEASIO-CPU-2026-08-20.md:7-20` and
`:57-83`.

Consequently, the next release candidate should combine measurement and small,
bounded changes, not turn every hidden switch on:

1. Use the five-Set, 30-second reporting suite and prove NTSync/topology first.
2. Evaluate the reliability-hardened Live worker formula on real 4-to-8-core
   hardware before release.
3. A/B the one-operation PipeASIO output-publication saving and the node-ID
   quantum ownership fix.
4. Treat ALSA Pro Audio as a device-profile A/B, not a PipeASIO mode.
5. Evaluate only the three bounded Wine fast paths after their semantic probes.
6. Keep automatic E-core placement, PipeASIO `SCHED_FIFO`, broad APC/hook
   caches, and continuous PipeWire-setting writers off.

This is deliberately conservative. Lower process CPU is not a win if Live uses
more of the audio deadline, PipeWire records errors, or a listener hears a
discontinuity.

## Evidence convention and source ledger

`Fact` below means directly present in source, a retained measurement, or
current GitHub metadata. `Inference` means the smallest explanation consistent
with those facts. `Decision` is the proposed policy and is not presented as an
upstream guarantee.

The external trees are clean, version-pinned local checkouts unless noted:

- `REPO` = `/home/theo/Projects/Code/ableton-linux-worktree/moonshot-cpu-optimiser-research-consolidation`, commit `5493354`.
- `PW` = `/tmp/moonshot-pipewire-source-1.6.8`, official PipeWire tag `1.6.8`, commit `b741e0c74f5436f0c925f7741140db0efd32cf4e`.
- `WP` = `/tmp/moonshot-wireplumber-source-0.5.15`, official WirePlumber tag `0.5.15`, commit `bc4fa8f5e84806f86530c97cb35283eecc3ec081`.
- `WINE` = `/tmp/rebuild-0105/wine-src`, the locally replayed Wine 11.13 package series, commit `5efbab2d2fda0ca498cb992c254d9d50a1910307`.
  Its packaged base and reproducible apply procedure are recorded at
  `REPO/patches/BASE.txt:1-24` and `REPO/scripts/container-build.sh:138-164`.
- `PASIO` = `/home/theo/Projects/Code/ableton-linux-worktree/pipeasio-cpu/build-analysis/pipeasio-1.5.0`, PipeASIO 1.5.0 plus the audited package series through its local commit `8ed2f924a7019927db9f5771d33af2f7b1a3cc74`; current later package patches remain under `REPO/patches/pipeasio/`.
- `WINE-CAND` = `/tmp/moonshot-wine-replay.v9QRic/src`, a clean proof replay over `WINE` with candidate commits `3ac8632`, `e9d769e`, and `6f797fd`. It is not the shipped runtime.
- `WORKERS` = `/home/theo/Projects/Code/ableton-linux-worktree/moonshot-cpu-optimiser-live-workers`, commit `330dc246649e6c21be1274787e780a8a50eae422`.
- `TOPOLOGY` = `/home/theo/Projects/Code/ableton-linux-worktree/moonshot-cpu-optimiser-hybrid-topology`, commit `c4ef087ec5e81e0a9dab0b46f2414c9cd8aa7a4c`.
- `NTSYNC` = `/home/theo/Projects/Code/ableton-linux-worktree/moonshot-cpu-optimiser-ntsync-proof`, commit `04f131dc23b31c4a76ffdce3fad86e3931e197c4`.
- `HOTPATH` = `/home/theo/Projects/Code/ableton-linux-worktree/moonshot-cpu-optimiser-pipeasio-hotpath`, commit `3c3ccf908f144c532cb49450128b453a34ca2a5a`.
- `TELEMETRY` = `/home/theo/Projects/Code/ableton-linux-worktree/moonshot-cpu-optimiser-pipeasio-telemetry`, commit `11a68b0ae967dc18ef9767a279f4b1b20a913fd7`.
- `ARBITRATION` = `/home/theo/Projects/Code/ableton-linux-worktree/moonshot-cpu-optimiser-pipewire-arbitration`, commit `644b842fb52ff2fb60deea2c86c55cbc98ffc55c`.
- `BENCH` = `/home/theo/Projects/Code/ableton-linux-worktree/moonshot-cpu-optimiser-bench-report`, commit `726c9d7a96ca6b64793a20e5445f7f3ff84491dc`.

GitHub PR state was queried from `shibco/ableton-linux` on 26 August 2026.
Those facts are time-sensitive and are linked at the claim.

## 1. Environment-feature audit

### What a normal launch already does

| Surface | Fact | Decision |
|---|---|---|
| Live workers | `ABLETON_MAX_AUDIO_THREADS` already defaults to `auto`; current `main` resolves that to allowed physical cores and applies it only before a cold Live 12 start (`REPO/scripts/ableton-live:299-318`, `:597-622`). | Keep `auto`, but replace the physical-only calculation with the guarded formula in section 3 after low-core validation. Preserve explicit numeric/off and ownership markers. |
| Launcher scheduling | Where the capability probe succeeds, the launcher wraps the whole Wine process in `SCHED_RR` priority 10. `ABLETON_RT=off` is the A/B escape (`REPO/scripts/ableton-live:1306-1315`). | Do not raise it further. Run a matched `ABLETON_RT=off/on` experiment; a future selective AVRT design must precede any policy change. |
| Power | A session-scoped performance-profile hold is default-on and `ABLETON_POWER=off` opts out (`REPO/scripts/ableton-live:1317-1336`). | Already enabled. Record the actual hold/profile and frequency; do not add a competing governor writer. |
| Wine presentation | CSMT, DComp full redraw, three Live class selectors, and mount-reparse compatibility are defaulted at launch (`REPO/scripts/ableton-live:409-432`). | Keep for their compatibility purposes. None is new PipeASIO CPU evidence. |
| PipeASIO baseline | New configuration is seeded once at two inputs, two outputs, fixed 256 frames (`REPO/scripts/setup-prefix.sh:1141-1157`). | This is already a small graph. Keep user-owned later edits. Measure any channel or buffer change as a workload change, not a driver optimisation. |
| PipeASIO callback scheduling | PipeASIO normalises its callback to ordinary scheduling by default; `PIPEASIO_REALTIME=on` is explicit (`REPO/notes/PIPEASIO-15.md:45-58`). | Keep off. Upstream's local 64-frame FL Studio measurement reported about 39 times more xruns with FIFO because callback and host worker priorities diverged (`PASIO/README.md:525-547`). |

### Switches considered and rejected as defaults

| Switch or idea | Fact and failure mode | Decision |
|---|---|---|
| `PIPEASIO_REALTIME=on` | It elevates only the callback/pump, while a multithreaded host's DSP workers remain ordinary (`PASIO/README.md:525-534`). | Rejected as a default. It is a diagnostic A/B only. |
| `ABLETON_DCOMP=off` | It disables the DComp stack that the runtime otherwise configures and is explicitly documented as an opt-out A/B (`REPO/scripts/ableton-live:435-448`). | Rejected. Possible graphics CPU savings do not justify broken Learn View/WebView presentation. |
| `WINE_D3D_FORCE_GPU_RENDERING=1` | It spoofs a GPU identity for the entire prefix, not just a renderer choice (`REPO/notes/DEFAULT-ON-FEATURE-AUDIT-2026-08-23.md:36-43`). | Keep explicit for denylisted GPUs. |
| `PIPEASIO_ALLOW_QUANTUM_MISMATCH=on` | It continues across a host/graph block mismatch and playback speed can differ (`REPO/notes/PIPEASIO-15.md:20-27`). | Diagnostic only; never a CPU default. |
| `PIPEASIO_FOLLOW_DEVICE_CLOCK=on` | It is required for device-driven clocks such as Bluetooth, adds asynchronous scheduling and one period of latency (`PASIO/README.md:498-508`). | Device-specific recovery, not a general CPU optimisation. |
| Global `clock.force-quantum` loop | Every metadata change recalculates the graph (`PW/src/pipewire/settings.c:131-192`). | Rejected. One owner and event observation are required; section 6 defines the rule. |
| Debug/telemetry always on | Callback telemetry adds six clocks per measured callback (`TELEMETRY/notes/MOONSHOT-CPU-PIPEASIO-TELEMETRY.md:36-42`). | Off during before/after CPU claims. Enable for one attribution run only. |
| `WINE_APC_FASTPATH` / `WINE_MSG_FASTPATH` | These switches do not exist in current `REPO`/`WINE`. The three-candidate proof replay defaults them on and accepts `0`/`off` as rollback (`WINE-CAND/dlls/ntdll/unix/sync.c:81-98`; `WINE-CAND/dlls/win32u/message.c:47-62`). | Do not add them to the launcher merely to expose them. If the bounded patches pass section 7, keep their own rollback controls and test each flag separately. |
| Old same-process APC and hook caches | The APC experiment adds a registry, generation/handle cache, client event, split client/server FIFO, and many fallback transitions (`/home/theo/Projects/Code/ableton-linux-worktree/pr-118-cpu-completion/patches/performance/0002-ntdll-same-process-user-apc-fast-path.patch:7-59`, `:127-140`). The hook experiment documents a self-unhook semantic delta without a server lifetime lease (`.../0003-win32u-cache-thread-hook-chains.patch:65-88`). | Rejected. Do not revive merely because targeted RPC counts fell. |

`Fact:` turning on every environment feature would combine contradictory
scheduler and graph policies. `Decision:` each switch gets its own branch and
matched A/B; rollback flags are not tuning knobs to stack together.

## 2. PipeWire Pro Audio is a card profile, not a PipeASIO pro mode

### Source semantics

`Fact:` ACP constructs a profile literally named `pro-audio`, uses 32-bit
samples and the configured probe rate/channel count, and enumerates every raw
`hw:card,device` playback and capture PCM into AUX-channel mappings
(`PW/spa/plugins/alsa/acp/acp.c:331-475`). For the simple one-input/one-output
or FireWire case it groups and auto-links the nodes and selects IRQ rather than
timer scheduling (`PW/spa/plugins/alsa/acp/acp.c:478-496`). `api.acp.pro-channels`
controls the probed channel count (`PW/spa/plugins/alsa/acp/acp.c:1935-1974`).

`Fact:` WirePlumber does not choose `pro-audio` as its generic highest-priority
profile; it skips it unless a preferred/explicit profile selected it
(`WP/src/scripts/device/find-best-profile.lua:13-74`). Once nodes exist,
Pro-named mappings receive a driver-priority bonus, while ALSA nodes default to
`node.pause-on-idle=false` (`WP/src/scripts/monitors/alsa.lua:234-282`). A
user-generated profile change can be stored and restored on later starts
(`WP/src/scripts/device/state-profile.lua:20-64`, `:67-129`).

`Fact:` profile switching is disruptive: ACP disables mappings absent from the
new profile, changes UCM state, enables the new mappings, and signals the
profile change (`PW/spa/plugins/alsa/acp/acp.c:1787-1880`). PipeWire reads the
`device.profile.pro` marker into ALSA state at
`PW/spa/plugins/alsa/alsa-pcm.c:968-980`; that file contains no further use of
`is_pro` in 1.6.8. The performance-relevant behavior therefore comes from the
different card mappings, links, scheduling properties, channels, and policy,
not a hidden alternate PipeASIO callback implementation.

`Inference:` Pro Audio may help a particular interface by exposing direct PCMs
and choosing a better driver, or hurt by exposing more channels, changing
routes, using a higher interrupt cadence, or losing mixer/UCM behavior. The
official WirePlumber documentation makes the CPU/reliability trade explicit:
batch devices need sufficiently frequent interrupts at a CPU cost; non-batch
devices prefer a lower interrupt frequency (`WP/docs/rst/daemon/configuration/alsa.rst:340-359`),
and period/headroom/buffer formulas differ by class (`:361-400`).

### Safe A/B gate

`Decision:` do not install a persistent `51-alsa-pro-audio.conf` for the first
test. The documented rule form is persistent and broad
(`WP/docs/rst/daemon/configuration/migration.rst:84-128`), and user profile
actions may be saved. Instead:

1. Close Live and all PipeASIO clients. Save `wpctl status`, `pw-dump`, the card
   profile, routes, defaults, rate/quantum metadata, and WirePlumber state-file
   hash.
2. Switch only the exact target card for the experimental leg. Confirm the same
   physical output/input, sample rate, quantum, and usable channel count before
   launching Live.
3. Run at least five matched 30-second suites per profile at 32, 64, and 128
   frames on the real interface. Keep the same Set order and thermal/power state.
4. Record card/profile/node IDs, IRQ rate, PipeWire ERR/xrun deltas, audible
   crackle, whole-prefix and PipeWire CPU, callback deadline, context switches,
   and migrations.
5. Close Live, restore the exact profile/routes/defaults, and prove the original
   nodes return. A route loss, unexpected persistence, extra channel graph, or
   quantum transition fails the leg before CPU is interpreted.

Pro Audio becomes a recommended device-specific profile only when it gives a
repeatable loaded-Set benefit with no continuity or route regression. It is not
a project-wide default.

## 3. Live worker policy for low buffers

### What is actually measured

At 64 frames, the retained empty-Set comparisons were:

| Workers | Whole-Live CPU | Voluntary switches/s | Warning lines/s | PipeWire ERR/s |
|---:|---:|---:|---:|---:|
| 31 | 40.61% | 77,293 | 0.167 | 10.33 |
| 16 | 31.22% | 43,623 | 0.100 | 5.06 |
| 8 | 18.22% | 23,130 | 0.033 | 2.53 |

Those rows are `REPO/notes/FINDINGS-PIPEASIO-CPU-2026-08-20.md:42-55`.
The matched RR comparison found 48.11% to 30.42% for 31 to 16 workers
(`:22-34`). These are Linux CPU and wait-coordination measurements, not proof
that eight workers meet a demanding audio deadline.

The later project report found its largest average deadline-meter reduction at
32 and 64 frames, but the complex Set still spiked above 100%, and 128-frame
overloads were comparable or slightly worse (`:57-83`). Restricting Wine's CPU
mask was worse because it changed both processor visibility and capacity: the
16- and 12-CPU legs increased ERR rate (`:131-145`). Affinity is therefore not a
substitute for the Live option.

### Hardened automatic formula

Let:

- `N` be logical processors available to the launcher;
- `L = clamp(2N - 2, 1, 31)`, Live's observed/calculated pool model;
- `P` be unique physical package/core pairs among those allowed CPUs; and
- `W = min(L, max(P, ceil(L / 2)))`.

The implementation is `WORKERS/scripts/lib/live-options.sh:35-90`. It preserves
the measured `16/31`, never selects fewer allowed physical cores, never cuts
more than half of `L`, and never exceeds `L`.

Representative cases pinned by the 1-to-32 logical-CPU test are:

| Allowed logical `N` | Allowed physical `P` | `L` | `W` |
|---:|---:|---:|---:|
| 1 | 1 | 1 | 1 |
| 2 | 1 | 2 | 1 |
| 4 | 2 | 6 | 3 |
| 8 | 4 | 14 | 7 |
| 12 | 6 | 22 | 11 |
| 16 | 8 | 30 | 15 |
| 32 | 16 | 31 | 16 |
| 8, no SMT | 8 | 14 | 8 |
| 16, no SMT | 16 | 30 | 16 |
| 32, no SMT | 32 | 31 | 31 |

Fixture coverage includes SMT, no-SMT, two packages, a sparse affinity mask,
every `N` from 1 through 32, invalid counts, `16/31`, `4/8 -> 7`, and
`8/16 -> 15` (`WORKERS/scripts/test-live-options.sh:45-116`).

`Decision:` this formula is the resolution of the already-existing `auto` mode,
not a new unconditional override. Explicit `1..63` and `off` keep their meaning;
an implicit auto preserves existing/user-edited settings, explicit auto may
recalculate only an untouched launcher-owned value, and `off` removes only that
owned line. Marker creation and ownership checks are at
`WORKERS/scripts/lib/live-options.sh:570-646`; launcher help and cold-start
behavior are at `WORKERS/scripts/ableton-live:33-47`, `:300-320`, and `:600-622`.

The formula belongs in `auto` because it strictly hardens the current
physical-only auto on small SMT hosts while preserving the validated 16/31
case. Nevertheless, release approval remains conditional: real loaded 4-to-8
physical-core systems have not yet validated it.

### Low-buffer matrix

At 48 kHz, callback cadence and wall budget are:

| Frames | Callbacks/s | Budget/callback | Required comparison |
|---:|---:|---:|---|
| 32 | 1,500 | 0.667 ms | guarded `auto`, explicit `P`, and `off/L` on a loaded Set |
| 64 | 750 | 1.333 ms | same three policies |
| 128 | 375 | 2.667 ms | same three policies |
| 256 | 187.5 | 5.333 ms | control and recovery margin |

Use at least 24 independent simultaneous audio chains on real 4-, 6-, and
8-core SMT hardware, five paired 30-second runs per cell. Capture Live average,
current, overload count/duration, audible crackle, PipeWire ERR/xruns,
whole-prefix and per-thread CPU, context switches, migrations, quantum events,
and worker count. A policy loses if it saves aggregate CPU but adds any
repeatable deadline failure. The earlier release plan already required a
4-to-8-core host, 24-to-32 independent chains, and multiple buffer sizes
(`REPO/notes/FINDINGS-PIPEASIO-CPU-2026-08-20.md:222-235`).

Reading the saved PipeASIO buffer to choose workers was rejected. Live consumes
the option at startup, whereas the active graph quantum can change after startup
or be negotiated by another client. A buffer watcher would either apply stale
state or become another writer competing with PipeWire and Live. This boundary
and the outstanding real-hardware gate are documented at
`WORKERS/TROUBLESHOOTING.md:521-527`.

## 4. Existing CPU work, consolidated

| Work | State on 26 August | What it proves / next action |
|---|---|---|
| Physical-core Live option, PR [#236](https://github.com/shibco/ableton-linux/pull/236) plus replacement fix [#249](https://github.com/shibco/ableton-linux/pull/249) | Merged to `main` on 22 August; default auto is present in `REPO`. | Strong one-host coordination evidence; replace with the guarded formula only after section 3's low-core gate. |
| Hardened worker formula, `330dc24` | Separate `moonshot-cpu-optimiser-live-workers` branch. | Hermetic topology/formula/ownership coverage; real loaded low-core gate remains. |
| NTSync proof, `04f131d` | Separate diagnostics branch. | Distinguishes compiled support, host device presence, and a live wineserver fd. `NTSYNC/notes/MOONSHOT-CPU-NTSYNC-PROOF.md:5-22`. |
| Hybrid topology proof, `c4ef087` | Separate instrumentation branch. | Read-only allowed CPU/core/package/SMT/capacity/type/frequency evidence; no affinity policy. |
| PipeASIO output publication, `3c3ccf9` | Separate candidate patch 0013. | Removes one redundant acquire-release attempt per delivered output/cycle while preserving fallback; needs real A/B. |
| PipeASIO phase telemetry, `11a68b0` | Separate off-by-default diagnostic. | Attributes wall vs callback CPU without blocking the callback; not itself a CPU result. |
| Quantum node ownership, `644b842` | Separate candidate patch 0013. | Uses bound node ID and complete signature to distinguish own/foreign forcers; reliability fix, not yet a measured CPU saving. |
| Five-Set reporter, `726c9d7` | Separate completed benchmark branch. | Canonical five Sets, one 30-second duration across every collector, immutable hashes, crackle evidence, full host/runtime/prefix profile. |
| Bounded Wine fast paths | Three clean proof commits in `WINE-CAND`; packaging branch still requires the gates in section 7. | Reduced specific wineserver request classes in an older trace; total Live CPU benefit remains unproved. |

PR [#118](https://github.com/shibco/ableton-linux/pull/118) is still `OPEN`; it
was created on 2 August, last updated at `2026-08-08T22:09:10Z`, targets `main`,
and carries the `performance-moonshot` head. PR
[#145](https://github.com/shibco/ableton-linux/pull/145) was merged at
`2026-08-08T14:52:07Z` into that head, not into `main`. Thus “merged PR #145”
does not mean the Wine APC/message fast paths ship on current `main`. This
distinction was already recorded at
`REPO/notes/DEFAULT-ON-FEATURE-AUDIT-2026-08-23.md:51-56`.

The old PR #118 collector is also not the new acceptance harness. Its
`--window` controls `pw-top`, while OSC is fixed at 60 seconds, `top` is twelve
five-second frames, and wineserver context switches sleep 60 seconds
(`/home/theo/Projects/Code/ableton-linux-worktree/pr-118-cpu-completion/scripts/bench-run.sh:47-54`,
`:78-108`, `:113-141`). Its workload script terminates the whole configured
wineserver (`.../scripts/bench-workload.sh:31-35`, `:164-181`). The completed
suite instead fixes the order and duration, requires an idle exact prefix, uses
a per-launch ownership token, and never invokes `wineserver -k`
(`BENCH/bench/README.md:10-32`; `BENCH/scripts/bench-suite.sh:12-42`,
`:329-385`).

`Benchmark_Zero` intentionally has no M4L controller; the other four Sets carry
one. That makes Zero-versus-Empty the controller/Max cost rather than silently
mixing it into the idle baseline
(`/home/theo/Projects/Code/ableton-linux-worktree/pr-118-cpu-completion/bench/README.md:78-107`).

## 5. Hybrid CPUs and efficiency cores

### Present evidence

The development host is a Ryzen AI MAX+ 395 with 16 physical cores, 32 SMT
threads, allowed/online `0-31`, `cpu_capacity=1024` everywhere, and no exported
`topology/core_type`, `/sys/devices/cpu_core/cpus`, or
`/sys/devices/cpu_atom/cpus`. These observations and their read-only boundary
are at `TOPOLOGY/notes/ABLETON-WINE-HYBRID-CPU-TOPOLOGY.md:8-44`.

`Fact:` patched Wine 11.13 reads `/sys/devices/cpu_core/cpus` into its
performance-core bitmap (`WINE/dlls/ntdll/unix/system.c:1103-1138`), combines it
with online CPU and SMT-sibling topology (`:1160-1229`), publishes a processor
`EfficiencyClass` (`:890-900`), and copies that class into
`SystemCpuSetInformation` (`:1785-1814`). On this homogeneous host those inputs
do not identify a slow class.

`Decision:` do not enable automatic E-core pinning here. Frequency is a mutable
snapshot, not a class. Guessing from CPU number or maximum MHz could violate an
external cpuset, collide with IRQ placement, starve a synchronous wineserver or
plugin dependency, and become wrong after suspend/hotplug.

### Safe future design

Any future policy must be instrumentation-first and fail open:

1. Intersect kernel online CPUs, the launcher's allowed mask, package/core/SMT
   siblings, `cpu_capacity`, `core_type`, and core/atom lists. Preserve sparse
   masks exactly; contradictory/missing evidence means no pinning.
2. Confirm the same mapping through Win32
   `GetLogicalProcessorInformationEx` and `GetSystemCpuSetInformation`, including
   `EfficiencyClass`. Never infer Windows-to-Linux numbering.
3. Identify a thread role from explicit lifecycle evidence before changing it.
   The PipeASIO callback, Live audio workers, wineserver, PipeWire data loop, and
   any thread on their synchronous dependency chain remain unpinned. Only
   independently proven background work may be considered for efficiency cores.
4. Retain the original affinity and scheduling policy, restore it on exit, and
   revalidate after CPU online/offline or resume. An explicit off switch is
   mandatory.
5. Validate on at least two Intel hybrid generations, one capacity-tiered
   non-Intel system, and this symmetric SMT control. Use full/sparse/external
   cpusets and loaded 32/64/128-frame runs.

The complete cross-hardware gate, including five 30-second windows and
CPU/power/reliability metrics, is
`TOPOLOGY/notes/ABLETON-WINE-HYBRID-CPU-TOPOLOGY.md:46-72`.

Wine's AVRT entry points currently return dummy success and do not create Linux
MMCSS-like scheduling: `AvSetMmThreadCharacteristicsW` returns a fixed handle,
and priority/revert are stubs (`WINE/dlls/avrt/main.c:57-92`). That makes
selective `Pro Audio` thread mapping a valuable research prototype, but not low
hanging: task-name semantics, nested registrations, handles, revert, privilege
failure, worker inheritance, and priority inversion all need tests before it
can replace whole-process RR.

## 6. One PipeWire quantum owner, no setting fights

### Arbitration facts

PipeWire exposes two different mechanisms:

- Global settings metadata `clock.force-quantum` pins the default/minimum/maximum
  quantum and causes a graph recalculation on each accepted change
  (`PW/src/pipewire/settings.c:159-192`; `PW/src/pipewire/context.c:1234-1249`).
- An active node may carry `node.force-quantum`; the key's scope is documented
  at `PW/src/pipewire/keys.h:166-180`. PipeWire stamps property changes
  (`PW/src/pipewire/impl-node.c:1291-1298`) and chooses the newest active node
  force when no global force exists (`PW/src/pipewire/context.c:1590-1610`). A
  disappearing force triggers quantum restoration (`:1642-1658`), and a new
  target becomes a pending reconfiguration (`:1740-1772`).

Current PipeASIO intentionally owns only its node request. If a global or newer
foreign node force wins, it asks Live to rebuild, sends silence during mismatch,
limits retries, and later restores the configured size
(`REPO/patches/pipeasio/0005-converge-on-a-foreign-quantum-predict-adopt-mute.patch:6-49`;
`REPO/notes/PIPEASIO-15.md:20-27`).

The remaining low-risk ownership fix is node identity. Equal names are not
ownership. The arbitration patch requires a complete private Audio/Duplex/DSP
signature before admitting a media-class-less PipeASIO filter, then treats the
bound PipeWire node ID as authoritative
(`ARBITRATION/patches/pipeasio/0013-classify-pipeasio-forcers-by-bound-node-id.patch:23-88`).
It observes global metadata but never adds a competing global writer
(`ARBITRATION/notes/PIPEASIO-15.md:20-34`).

### Ownership rules

1. A nonzero global `clock.force-quantum` is an external graph-wide owner.
   PipeASIO may observe/adopt it but must not rewrite it.
2. Without a global force, active node forces participate in PipeWire's native
   timestamp arbitration. PipeASIO changes only its own bound node property.
3. Do not add a launcher, report tool, WirePlumber rule, or timer that repeatedly
   “corrects” the quantum. The benchmark suite is read-only with respect to
   profiles and metadata (`BENCH/bench/README.md:27-32`).
4. Monitor the entire measurement window. Any quantum/rate/profile transition
   is a confounder, even if the final value matches the start.
5. Preserve user configuration. PipeASIO's `config.ini` is seeded only if
   absent (`REPO/scripts/setup-prefix.sh:1141-1159`); WirePlumber can restore a
   saved user profile (`WP/src/scripts/device/state-profile.lua:20-64`). Neither
   should be rewritten as benchmark cleanup.

Required probes are a settings-metadata snapshot and event monitor, `pw-dump`
node properties keyed by global ID, `pw-top` quantum/ERR samples, the exact
PipeASIO/Live logs for adopt/reset episodes, and before/after hashes of PipeWire,
WirePlumber, PipeASIO, and Live options. Two simultaneous same-name PipeASIO
instances at 128/256 and a foreign JACK force are mandatory adversarial cases.

## 7. Low-hanging source findings

### Priority order

| Rank | Candidate | Source evidence | Status / gate |
|---:|---|---|---|
| P0 | Reliable Live `auto` formula | Largest retained CPU/context-switch signal; formula and exhaustive topology fixtures in section 3. | Implemented on isolated branch. Gate on loaded 4-to-8-core 32/64/128 hardware before release. |
| P0 | Reproducible report and NTSync/topology proof | Without exact runtime, prefix, quantum and wait-driver identity, before/after attribution is unsafe. | Implemented as diagnostics branches; merge before claiming wins. |
| P1 | Skip redundant PipeASIO output fallback publication | A delivered callback already exchanges/queues each output; old backend cleanup repeated an empty acquire-release exchange. `HOTPATH/notes/FINDINGS-PIPEASIO-CPU-2026-08-20.md:128-147`. | Patch and deterministic delivered/undelivered tests exist. Measure whole workload; saving is one bounded operation per output/cycle. |
| P1 | Bound-node quantum ownership | Prevents a same-name instance being mistaken for self and avoids false adopt/restore competition. | Patch/tests exist. Treat primarily as reliability; require two-instance live graph. |
| P1 | Wine redundant queue-mask fast path | Current Wine already reads shared masks but still sends `set_queue_mask` when the state is not considered fresh (`WINE/dlls/win32u/message.c:3338-3385`). Candidate memo keeps the 3-second hung-queue heartbeat and verifies shared state (`WINE-CAND/dlls/win32u/message.c:2960-3024`, `:3429-3488`). | Candidate `e9d769e`; run Win32 message probes, Wine tests, and loaded CPU/request A/B. |
| P1 | Wine known-clean `GetUpdateRect` | Current path builds/queries regions and rechecks flags (`WINE/dlls/win32u/dce.c:1927-1957`). Candidate uses same-thread shared `QS_PAINT` only for the known-empty result and falls back otherwise (`WINE-CAND/dlls/win32u/dce.c:1927-1986`). | Candidate `6f797fd`; require clean/pending/erase/internal-paint/cross-thread/stale-window probe and Wine tests. |
| P1 | ALSA Pro Audio profile | Direct PCM mappings, different priorities/grouping/IRQ behavior; no alternate PipeASIO algorithm. | Configuration A/B only; section 2 gate. |
| P2 | Wine alertable zero-handle NTSync wait | Current alertable `NtDelayExecution` always asks wineserver (`WINE/dlls/ntdll/unix/sync.c:2416-2431`), although NTSync handle waits already use the per-thread alert fd (`:899-924`). Candidate uses a zero-object NTSync wait and exact server fallback (`WINE-CAND/dlls/ntdll/unix/sync.c:2436-2512`). | Candidate `3ac8632`; older idle trace saw no APC traffic, so playback benefit is unproved. Require NTSync semantics/APC probe and fallback leg. |
| P2 | Selective AVRT/MMCSS mapping | Wine AVRT is stubbed, while launcher RR is process-wide. | Prototype after tracing Live task names and callbacks. Not part of the bounded fast-path set. |

PipeASIO itself has no identified steady-state busy poll. Its process callback
dequeues buffers, calls the host once at matching quantum, publishes/returns the
buffers, and uses PipeWire loop signaling for synchronous setup
(`PASIO/src/audio.c:1875-2032`, `:2055-2075`). The headless 128-frame two-in/two-out
driver measurement was about 0.5% CPU without Live DSP
(`REPO/notes/DEFAULT-ON-FEATURE-AUDIT-2026-08-23.md:76-80`). `Inference:` the
small per-port publication saving is real, but the dominant low-buffer cost is
more likely callback-rate-amplified Live/Wine worker coordination.

### Rejected or deferred low-fruit claims

- Do not resurrect the old same-process APC queue. APC FIFO, special APCs,
  access checks, target exit, handle reuse, and client/server route transitions
  make it materially broader than the alert-event wait.
- Do not resurrect the hook snapshot cache. Self-unhook and cross-thread
  mutation can outlive a snapshot. Targeted RPC reduction is not lifetime proof.
- Do not patch the Linux scheduler or pin the whole prefix from this evidence.
  The Wine CPU-mask experiment increased PipeWire errors, this host has no
  heterogeneous class, and the 26 August host snapshot at
  `/proc/sys/kernel/sched_rt_runtime_us` is `950000`. First use
  schedstat/perf/ftrace attribution.
- Do not increase PipeWire ALSA IRQ frequency globally. WirePlumber explicitly
  documents the batch-device CPU/reliability trade; tune only the identified
  hardware under a profile A/B.
- Do not move callback execution to an unbridged PipeWire RT pool thread.
  PipeASIO must enter Wine on a thread with a Wine TEB; the current native bridge
  exists for that reason (`PASIO/src/audio.c:974-998`).
- Do not make callback telemetry permanent. It is an attribution probe whose
  own cost must be measured with telemetry off/on.
- Do not treat the three Wine candidates as a single indivisible “CPU patch.”
  Each needs its own branch, rollback flag, semantic probe, and benchmark pair.

## Prioritized decision table

| Order | Branch concept | Smallest intervention | Expected benefit | Principal risk | Merge gate |
|---:|---|---|---|---|---|
| 1 | `moonshot-cpu-optimiser-bench-report` | Reporting/scripts/assets only. | Makes every later claim attributable and crackle-aware. | Collector ownership or probe overhead. | Hermetic tests plus one supervised five-Set dry/real run. |
| 2 | `moonshot-cpu-optimiser-ntsync-proof` and `-hybrid-topology` | Read-only probes/report fields. | Prevents false wait-driver and topology conclusions. | Mislabeling absent evidence as a class. | Sparse/missing/no-SMT fixtures and live wineserver fd proof. |
| 3 | `moonshot-cpu-optimiser-live-workers` | Change only `auto` calculation; keep options/markers. | Largest measured CPU/wakeup reduction. | Low-core parallelism/deadline regression. | Loaded 4/6/8-core matrix, no crackle/xrun regression. |
| 4 | `moonshot-cpu-optimiser-pipeasio-hotpath` | Skip only the already-delivered fallback attempt. | Bounded per-output/cycle saving. | Lost silence fallback or double ownership. | Unit/ABI/sanitizers plus real 32/64/128 A/B. |
| 5 | `moonshot-cpu-optimiser-pipewire-arbitration` | Make bound node ID authoritative; no metadata writer. | Prevents reset churn and cross-instance fights. | Pre-bind classification race. | Two-instance/foreign-force/hotplug/restart tests. |
| 6 | `moonshot-cpu-optimiser-pipewire-pro-audio` | A/B tool and report only; no persistent rule. | Possible device-specific graph/IRQ improvement. | Routes, channels, profile persistence, more IRQ CPU. | Restore proof and five paired runs per quantum. |
| 7 | `moonshot-cpu-optimiser-wine-bounded-fastpaths` | Exactly alertable sleep, queue mask, known-clean update rect. | Removes bounded wineserver traffic. | Win32/APC/message semantic races. | PE probes, Wine tests, request trace, loaded suite; each flag separately. |
| 8 | future hybrid/AVRT branch | Instrument task/class mapping before policy. | Selective priority or background E-core use. | Priority inversion and hidden synchronous dependency. | Multi-generation heterogeneous hardware gate. |

## Adversarial failure modes

| Apparent win | How it can be false | Required defence |
|---|---|---|
| Live process CPU falls | Work moved to wineserver, PipeWire, kernel IRQs, or a helper. | Report whole prefix, wineserver, PipeWire, host/IRQ CPU, and per-thread deltas. |
| Fewer workers use less CPU | Serialisation consumes more of the buffer deadline. | Live deadline meter/overloads plus manual crackle and PipeWire errors. |
| Pro Audio lowers one process | Profile exposes different channels/routes or changes interrupt frequency. | Match exact physical routes/channels and record IRQ/profile/node identity. |
| Higher priority removes one xrun | Callback starves the workers it synchronously waits for. | Capture policy/priority per callback and worker; compare ordinary/FIFO/RR. |
| E-core placement lowers package power | A background-looking thread is a synchronous audio dependency. | Trace wake/wait edges; pin only proven-independent roles; fail open. |
| Quantum looks stable at end | Two writers flipped it during the window. | Metadata event log and node property snapshots for the full window. |
| Same PipeASIO name means same owner | Two Live instances collide and trigger false restore/adopt. | Bound global node ID plus simultaneous 128/256 test. |
| Wine RPC count collapses | Cached state races or changes Win32 semantics. | PE semantic probes, Wine tests, rollback leg, and total CPU/reliability results. |
| Telemetry identifies a bottleneck | Probe clocks/reporting created the timing shape. | Use telemetry for attribution only; CPU before/after runs keep it off. |
| Clean counters mean no crackle | Instrumentation was missing or reset with a node. | Manual `heard/not-heard`, raw logs, node lifetimes, and narrow report classification. |
| Before/after differs | Runtime, prefix, Live, plugin, config, power, or thermals drifted. | Composite hashes/system profile, matched identities, repetitions, randomized pair order. |
| Empty Set improves | Loaded parallel chains regress. | Require Inbuilts, Max4Live, and VSTs; Zero/Empty remain attribution controls. |

## Measurement and acceptance gate

The completed suite runs `Benchmark_Zero`, `Empty`, `Inbuilts`, `Max4Live`, and
`VSTs` in a fixed order with one duration, default 30 seconds
(`BENCH/bench/README.md:10-21`). It profiles hardware, CPU topology, audio/GPU,
PipeWire/WirePlumber, Wine runtime, prefix, Live version, PipeASIO/launcher
config, worker count, per-process/thread CPU and scheduling, quantum events,
ERR/xrun/log evidence, and manual crackle (`:34-61`). Its crackle labels avoid
claiming that clean counters prove inaudibility (`:63-95`).

The canonical CPU unit is percentage of one logical core:
`100 * delta(utime_ticks + stime_ticks) / CLK_TCK / elapsed_seconds`. The
collector keys processes and threads by PID plus start time, retains scheduling
policy/RT priority/cpuset/context-switch/schedstat deltas, and separately derives
host utilization (`BENCH/scripts/bench-report.py:292-344`, `:466-536`). The
primary comparison is the sum for the supervised Wine session, with Live,
PipeWire/WirePlumber, host CPU, and individual threads reported separately so a
change cannot claim CPU that it merely moved (`:739-766`). Live's OSC deadline
average/peak and continuity evidence remain separate axes, not substitutes for
Linux CPU.

For each candidate:

1. Run a clean preflight and record the proof tools. Use five matched before/after
   suite pairs; every Set window is 30 seconds. For buffer-sensitive policies,
   repeat the matrix at 32, 64, and 128 frames.
2. Change one concept only. Keep runtime, prefix composite, Live/plugins, Set
   assets, audio device/profile/routes, sample rate, quantum, worker setting,
   window state, power profile, and telemetry state identical.
3. Reject a run with a quantum/rate/profile transition, missing OSC on a
   controlled Set, changed configuration hash, uncontrolled process, unavailable
   critical counter, thermal/frequency excursion, or missing NTSync proof.
4. Report paired deltas and dispersion, not one total. A CPU claim must improve
   loaded Sets consistently beyond run-to-run noise and must not merely move CPU
   to PipeWire/wineserver/IRQ work.
5. Reliability is a hard gate: no added manual crackle, PipeWire ERR/xrun,
   PipeASIO missed-cycle episode, Live overload frequency/duration, route loss,
   startup failure, or recovery regression. A CPU reduction cannot compensate.
6. Run each candidate's focused semantic tests and explicit rollback leg. For
   Wine, use APC/update probes; for PipeASIO, unit/ABI/no-Qt/sanitizer and live
   graph tests; for topology, sparse/missing/hybrid fixtures.

## Open questions

1. Does the guarded worker formula meet deadlines on real loaded 4-, 6-, and
   8-core SMT machines at 32/64/128 frames?
2. In callback telemetry, how much wall and thread CPU fall before Live, inside
   Live, and after Live returns? Does wall-without-CPU confirm worker waits?
3. Does the actual USB interface's Pro Audio profile preserve routes and reduce
   whole-system CPU/xruns, or expose more channels/IRQs and cost more?
4. Which process currently writes any observed global or foreign node quantum,
   and does the node-ID arbitration eliminate all reset churn with two clients?
5. Do Live's audio threads call AVRT with the task name `Pro Audio`; how are
   registrations nested and reverted; which Linux policy reproduces MMCSS
   without priority inversion?
6. On Intel hybrid systems, do sysfs core lists, allowed cpusets, Wine
   `EfficiencyClass`, and Win32 CPU-set APIs agree after boot, suspend, and
   hotplug?
7. Do the bounded Wine queue-mask and update-rect changes reduce whole-prefix
   CPU in loaded Sets, not just targeted request counts? Does the alertable-sleep
   path see meaningful playback traffic?
8. Is the redundant output-publication exchange measurable above noise with
   two outputs, and how does it scale with deliberately higher channel counts?
9. Does current Live actually use NTSync in every benchmarked runtime/prefix,
   proven by the running wineserver fd rather than build labels or device
   presence?
10. Can an objective loopback discontinuity detector supplement, but never
    replace, the report's manual crackle observation on the real interface?

Until those questions have recorded answers, the minimal defensible release is
measurement/proof infrastructure plus individually gated small changes—not a
stack of scheduler, profile, affinity, and metadata overrides.
