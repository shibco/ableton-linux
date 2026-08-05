# Performance moonshot: final synthesis, 2026-08-01

This document adjudicates the twelve research documents in
`notes/performance-moonshot/` into one implementation list. Contested claims
were re-verified against the vendored Wine base (`vendor/wine-base-5c23dd1c.tar.zst`),
the vendored PipeASIO 1.2.2 source, the repository scripts, branch
`fixes/audio-hardening`, the open issue tracker, and live web sources on
2026-08-01. This is the list of record. The underlying documents remain
research inputs and are not retro-edited.

Ranking weighs four properties per item, as agreed: certainty of the
underlying analysis, invasiveness of the change, projected performance
result with its mechanism, and chance of success.

## 1. Corrections: claims rejected or amended

Each entry names the claim, the verdict, the evidence, and what changes.

**C1. "Upstream Wine has an eventfd in-process sync fallback when
/dev/ntsync is absent" (SYNC opportunity 5, MOONSHOT-OPPORTUNITIES S9).
Refuted.** In the vendored base, `inproc_wait` returns
`STATUS_NOT_IMPLEMENTED` when `inproc_device_fd < 0` and every caller then
falls through to `server_wait` (`dlls/ntdll/unix/sync.c:906`, `:2326`,
`:2352`). No eventfd path exists in the file. Consequence: the S9 spike is
deleted; the fsync fallback tier (item P7) is the only route for pre-6.14
kernels, and the host ntsync gate (P1) matters exactly as much as the
regression note said.

**C2. "Read wine-staging's ntdll-APC_Performance before APC work"
(OTHER-FORKS-SURVEY 2, RESEARCH 3, MOONSHOT-OPPORTUNITIES M1 step zero).
Amended.** The patchset exists in staging master, but its single patch is
"ntdll: Reuse old async fileio structures if possible", an allocation
optimization on the async I/O path. It contains nothing about APC delivery,
alertable waits, or wineserver round trips. Consequence: the step is
dropped; there is no prior art in staging for the APC fast path.

**C3. "-DontCombineAPCs toggles Windows APC batching." Rejected as
documented fact; the local measurements stand.** Ableton's Options.txt
article (fetched via the help-center API, article 6003224107292) documents
the flag as "Deactivates the APC combination mode: won't align and sync the
session rings of multiple APCs so they can be moved independently", which
is Akai APC controller behavior. PERFORMANCE-MOONSHOT-RESEARCH.md raised
this and is vindicated. What survives: the idle thread at 30 to 40 percent
of a core was measured directly, and the A/B/A on issue 29 (fault appears
with the flag, disappears without, reappears with) is real
(`notes/ABLETON-WINE-APC-COALESCING.md`). What falls: any confidence that
the flag's mechanism is engine APC batching, and with it the specific
playback-fault story. Consequence: the `WINEDEBUG=+server` trace the APC
note already prescribes is now a hard gate before any APC patch (P5).

**C4. "dxgi WaitForVBlank just calls Sleep(16)" (LIVE opportunity 3,
MOONSHOT-OPPORTUNITIES S4). Stale.** True of the raw base
(`dlls/dxgi/output.c:364-371`), but patch 0001 changes it to
`dxgi_sleep_for_refresh_interval()`, a refresh-rate-aware sleep. Max device
redraw is paced at the real refresh rate today, just without vblank phase
lock. Consequence: S4 is demoted from a spike to a low-priority refinement
with its factual basis corrected.

**C5. "WINE_CPU_TOPOLOGY: confirmed" (RESEARCH technologies table).
Misleading as written.** The launcher export is real; the consumer is not.
The string appears zero times in the entire vendored Wine tree and zero
times in `patches/`; the launcher comment says "Inert on this runtime"
(`scripts/ableton-live:78-79`). Consequence: the variable does nothing
today; P8 decides port-or-delete.

**C6. "Whether Wine maps Live's thread priorities to Linux scheduling at
all: unverified" (MOONSHOT-OPPORTUNITIES T2). Now verified.**
`server/thread.c:236-269`: NT priorities in the application band [1,15] map
to niceness via `setpriority`, only when the RLIMIT_NICE grant exists
(`nice_limit < 0`), and the realtime band is clamped to
`LOW_REALTIME_PRIORITY - 1` under the comment "FIXME: handle realtime
priorities using SCHED_RR if possible". avrt is a pure stub returning
handle `0x12345678` (`dlls/avrt/main.c`), and every rtworkq MMCSS
registration returns `E_NOTIMPL` (`dlls/rtworkq/queue.c`). Consequence: the
scheduling chain (P4) rests on verified source, not inference.

**C7. "PipeASIO 1.2.3 is the current upstream release." Stale as of
today.** 1.2.3 (July) is build fixes only, confirmed. 1.3.0 shipped
2026-08-01: it adds a realtime audio-thread setting, bumps the WoW64 ABI to
version 3, and raises the PipeWire floor to 1.4.2. Its notes report that
multi-threaded hosts under Wine can see more xruns with the new setting on
(measured with FL Studio), and no release mentions Ableton validation.
Consequence: the vendor bump splits. 1.2.3 is the safe hygiene bump; 1.3.0
needs evaluation and its floor conflicts with the runtime's 0.3.56 host
floor and the every-Linux-computer target. Do not adopt 1.3.0 without a
decision on the floor.

**C8. "Live 12 needs Media Foundation work to restore video and WMA
import" (RESEARCH 8). Overstated.** Media import in Live 12 works through
winegstreamer today (`scripts/container-build.sh:96-102`); the only
recorded media crash is Live 11's `wmvcore` path, which is experimental
scope. Consequence: no Media Foundation track; Live 11 `wmvcore` stays in
the opportunistic tier.

**C9. "Port the topology consumer to fix worker-pool oversizing; cap 8"
(SYNC 2, BUILD 7). Tempered.** ABLETON-WINE-PERFORMANCE-PLAN.md is right
that a blanket 8-CPU cap conflicts with Live's up-to-64 audio threads and
that the base counts online CPUs rather than allowed CPUs
(`dlls/ntdll/unix/system.c:1710-1731`, `_SC_NPROCESSORS_ONLN`).
Consequence: P8 ports the consumer for accurate, affinity-derived reporting
and optional pinning experiments; the 8 cap is not a default and would need
bench pairs to earn one.

**C10. Alertable-wait cost wording in the four-review doc. Refined.** With
ntsync active, alertable handle waits do run in-kernel with a cached
per-thread alert fd (`dlls/ntdll/unix/sync.c:920`, `:872-891`). The
verified server costs are: `NtQueueApcThreadEx2` is one wineserver round
trip per queued APC (`dlls/ntdll/unix/thread.c:1796-1825`), and an
alertable sleep with no handles always round-trips the server, source
comment "if alertable, we need to query the server"
(`dlls/ntdll/unix/sync.c:2419-2431`). A loop of alertable sleeps near 1 kHz
therefore pays about 1,000 server round trips per second even with ntsync.
This strengthens P5's cost case while C3 weakens its mechanism story.

## 2. Confirmed foundation

Facts the list below builds on, now verified rather than cited.

| Fact | Evidence |
|---|---|
| avrt full stub; rtworkq MMCSS all E_NOTIMPL; server maps NT priority to nice only, clamps the realtime band, FIXME on record | vendored `dlls/avrt/main.c`, `dlls/rtworkq/queue.c`, `server/thread.c:236-269` |
| Live imports AvSetMmThreadCharacteristicsW, AvSetMmThreadPriority, RTWorkQ.dll, task name "Pro Audio" | binary inspection in ABLETON-WINE-PERFORMANCE-PLAN.md, accepted |
| wine-osu carries the avrt de-stub: "Audio"/"Pro Audio" to THREAD_PRIORITY_TIME_CRITICAL plus thread naming | `9000-misc-additions/audio-thread-priority-and-name.patch` in whrvt/wine-osu-patches, fetched today |
| Without /dev/ntsync every wait is a server round trip; no intermediate tier exists | `dlls/ntdll/unix/sync.c` (C1) |
| APC queueing is a server call; alertable no-handle sleeps always hit the server | C10 |
| WINE_CPU_TOPOLOGY has no consumer anywhere; launcher counts online CPUs capped at 8 as groundwork | C5; `scripts/ableton-live:75-108` |
| No ntsync check at launch; the word does not appear in the launcher | `grep ntsync scripts/ableton-live` is empty |
| PipeASIO: silent replacement of any non power-of-two buffer with 1024; SCHED_FIFO 15 via raw `pthread_setschedparam` in its own thread-utils, no RTKit fallback; follow-device quantum machinery exists; warn-once-and-keep-feeding on quantum mismatch | `src/config.c` validate(), `include/pipeasio_config.h:54`, `src/audio.c:106-236`, `:1401-1411` |
| Branch `fixes/audio-hardening` holds the issue 49 cause table (C1 to C9) and ordered fixes F0 to F8, including F3 per-thread SCHED_FIFO wine patch, F4 ABLETON_RT default off, F5 RTKit fallback | `git show fixes/audio-hardening:notes/ABLETON-WINE-PIPEASIO-CRACKLE.md` |
| Bench harness exists with the pair protocol; no `bench/` directory or committed row exists | `scripts/bench-run.sh`, repository state |
| Whole-process SCHED_RR 10 at launch when rtprio exists; learnheal.exe resident helper; theme watcher on a 2 s loop | `scripts/ableton-live:780-783`, `:809-810`, `:437-461` |
| Issues 42, 46, 49, 63, 87, 92, 109, 111, 115 open as of today | tracker query 2026-08-01 |
| winepulse buffers three periods with a probed 10x period floor; irrelevant to the engine path (ASIO) | vendored `dlls/winepulse.drv/pulse.c:789`, `:1083` |

## 3. Verdict per source document

| Document | Verdict |
|---|---|
| PERFORMANCE-MOONSHOT-2026-08-01.md | Strongest single input. Its ranked structure and deliberate non-changes carry into this list. Amended by C7 (1.3.0), C10 (wording), and C3 (APC narrative now trace-gated). Its staging survey was right to omit the APC set (C2 confirms it is irrelevant). |
| MOONSHOT-OPPORTUNITIES.md | Best measurement plan and reject list; both adopted. T1, T2, T3, T4, T6 adopted. T5 demoted to one contained experiment series (P11). S9 deleted (C1), S4 demoted (C4), M1 step zero replaced (C2), S1 tempered (C9). |
| PERFORMANCE-MOONSHOT-RESEARCH.md | Mixed. The -DontCombineAPCs definitional catch (C3) is the single best correction in the whole set. Its technologies table misled on WINE_CPU_TOPOLOGY (C5), its Media Foundation item overstated (C8), and its staging backport row pointed at an irrelevant set (C2). |
| ABLETON-WINE-PERFORMANCE-PLAN.md | The binary-import evidence (avrt, RTWorkQ, "Pro Audio") is the most valuable new fact in the eight-document set; it turns the MMCSS de-stub from plausible into a certain target. Its stage gates, 8-cap warning (C9), and do-not-default list are adopted. |
| PROJECT-TECHNOLOGIES.md | Accurate inventory; every gap it lists verified. No corrections. |
| ABLETON-LIVE-TECHNICAL.md | Strong; the crash-class table seeds the regression matrix. S4 basis stale (C4). |
| PROTON-SYNC-AND-CPU.md | Good history and the host ntsync gap (P1). Its unverified eventfd flag was proper hedging; the claim is now refuted (C1). |
| PROTON-GRAPHICS-AND-RUNTIME.md | Verified Proton flags and a clean reject table; both adopted wholesale. DXVK risk analysis adopted for the parked A/B. |
| OWN-FORK-PATCH-MAP.md | Accurate map. Its central finding, sync and threading untouched by the series, underpins P4 and P5. |
| OWN-FORK-BUILD-AND-RUNTIME.md | Solid facts; compiler enthusiasm tempered into P11. The launch-gap item became P1. |
| OTHER-FORKS-SURVEY.md | Useful survey; staging APC content now known (C2). The nspa source-availability caveat becomes P9's step zero. |
| AUDIO-LATENCY-ECOSYSTEM.md | Strong host-side content: the rtkit RTTIME 200 ms trap, the scsynth core-placement lesson, per-interface buffer floors, graph-rate locking. All folded into P3 and P4 host arms. |

## 4. Implementation list

Ordered. Each entry states certainty (is the analysis right), invasiveness
(what it touches and can break), projected result (and the mechanism), and
chance of success (will the implementation land and hold). Every
performance claim still requires a committed before/after pair from
`scripts/bench-run.sh`; every new patch needs its build-audit fingerprint
entry.

### P0. Baselines and harness automation

Commit `bench/` rows for the current release before anything else, and
extend `bench-run.sh`: automated `pw-top -b` ERR capture, `pw-metadata`
rate and quantum, Live process total CPU, the busy idle thread's CPU,
startup time, and a version column set (Live, WebView2, GPU driver,
PipeWire), since WebView2 self-updates inside the prefix and has regressed
rendering before. Commit the reference set.

- Certainty: certain. No committed row exists; the headline xrun metric is
  operator-entered.
- Invasiveness: none. Tooling and data only.
- Projected result: none directly. It is the evidence floor for every other
  item, and Live's CPU meter doubles as a fidelity benchmark against
  Windows on the same hardware.
- Chance of success: high.
- Sources: MOONSHOT-OPPORTUNITIES T3, four-review entry 0, BUILD 2.

### P1. Host ntsync gate

Launch-time `[ -c /dev/ntsync ]` check with a loud warning, detection of a
kernel at or above 6.14 with the module unloaded, a `modprobe.d` drop-in or
exact load instructions in the setup scripts, and TROUBLESHOOTING coverage.

- Certainty: high. The fallback cost is measured (about 45 percent of a
  core and 9,000 context switches per second at idle; 4 to 50x probe
  regression), the absence of any launcher check is verified, and C1
  removes the hope of a hidden intermediate tier.
- Invasiveness: minimal. Launcher and docs; no Wine change.
- Projected result: on affected hosts, recovers the full ntsync win that is
  silently lost today. On healthy hosts, nothing changes.
- Chance of success: very high.
- Sources: SYNC 1, BUILD 1, RESEARCH 1, MOONSHOT-OPPORTUNITIES T1.

### P2. Scheduling A/B

Run the written 4-CPU protocol from `notes/ABLETON-WINE-RT-SCHEDULING.md`
with four arms: default RR 10, `ABLETON_RT=off`, wineserver `chrt -f`
boost, and realtime narrowed to audio threads once P4 provides it. Record
pairs on a low-core machine and a many-core machine.

- Certainty: the protocol exists and the three risk hypotheses are
  recorded; the outcome is unknown, which is the point.
- Invasiveness: none. Measurement only.
- Projected result: decides whether whole-process RR stays the default
  (F4), whether wineserver needs a priority floor, and quantifies the
  priority-inversion shape (Live RT threads calling a SCHED_OTHER
  wineserver) that the crackle analysis lists as cause C3.
- Chance of success: high.
- Sources: RT note, MOONSHOT-OPPORTUNITIES T2, AUDIO 1, SYNC 3.

### P3. Audio hardening, driver track

Execute F0 to F8 from `fixes/audio-hardening`, merged with the host-side
audio items: F0 capture tooling and corrected warning text first, then
quantum convergence (follow the graph cycle, accept non power-of-two sizes,
stop silently replacing invalid configuration with 1024), correct latency
reporting with the latency-changed callback, single-clock duplex default,
priority-inheritance mutexes on shared driver state, a stall watchdog on
the JACK eviction model, and the PipeASIO 1.2.3 hygiene bump. Host arm:
per-interface buffer floor guidance (USB near 512, HDA 128 to 256), a
defined policy for PipeWire hosts older than 1.6 (require or ship a
`clock.force-quantum` fallback), and graph-rate locking so PipeWire never
resamples Live. Evaluate 1.3.0 separately under C7.

- Certainty: high. Issue 49's mechanism is confirmed (forced-quantum
  recency arbitration, wrong-speed playback), the cause table and fix order
  are written, and the driver code paths were re-verified in source.
- Invasiveness: medium. Driver patches, launcher, setup, docs; it is the
  audio path, but the plan's own order puts capture tooling before any
  behavior change, and the three-distribution verification matrix exists.
- Projected result: closes the open audible-defect classes (wrong-speed
  playback, crackle under quantum contention, duplex resync crackle) and
  makes recording offsets correct, since Live derives them from reported
  latency and the driver currently reports a fixed one-buffer guess.
  In DAW terms this is the performance result that users hear.
- Chance of success: high. The plan, risk table, and regression list are
  already written; issue 49 is reproduced and understood.
- Sources: fixes/audio-hardening plan, four-review entry 3,
  MOONSHOT-OPPORTUNITIES T4, AUDIO 2, 6, 7.

### P4. Thread-priority chain, scheduler track

Restore Live's priority structure in order: (a) de-stub avrt so
"Pro Audio" registrations get time-critical priority, starting from the
wine-osu patch, which under the current server means best-nice within the
host grant; (b) implement the `server/thread.c` FIXME, mapping the Windows
realtime band to per-thread SCHED_FIFO or SCHED_RR behind an environment
gate, budgeted under the host rtprio grant and placed below PipeASIO's FIFO
15 and PipeWire's data threads; (c) only after P2 pairs exist, retire
whole-process RR as the default (F4); (d) add the RTKit fallback in
PipeASIO (F5) last, respecting the RTKit RTTIME 200 ms budget trap and its
priority cap of 20. Host arm: extend `setup-realtime.sh` into a full audit
(governor, threadirqs and rtirq, RTTIME limits, rtkit presence on GNOME 45
and newer, PipeWire rt.prio), failing the realtime check instead of
printing advice once.

- Certainty: high on the problem. Every link is verified: Live imports the
  MMCSS APIs and the "Pro Audio" task name, avrt and rtworkq are stubs, the
  server clamps the realtime band with a FIXME, and whole-process RR
  flattens audio against UI. Medium on the size of the gain: nobody ships
  this; wine-nspa proves the model on Live with self-reported numbers.
- Invasiveness: high. wineserver, ntdll, avrt, launcher, driver, and host
  policy; a wrong priority order can starve the desktop or the audio
  callback. The environment gate and the P2 protocol are the containment.
- Projected result: the audio path outranks the interface path for the
  first time, per thread, which is what Live's manual expects and what the
  whole-process wrapper cannot express. Mechanism: dropout margin at small
  buffers is set by worst-case wake-up latency of a few hot threads;
  per-thread realtime placement directly cuts that tail, and wine-nspa's
  Live measurements (condition-wait worst case 263 to 152 microseconds
  with PI locks; futex wait halved under mlockall) indicate the size class.
  Expect the largest effect at 64 to 128 frames and under UI load.
- Chance of success: medium-high. The avrt half is a small proven patch;
  the server half is a bounded change at a marked FIXME; the ordering
  constraints (never remove whole-process RR first, wineserver never above
  the callback by default) are written down.
- Sources: four-review entry 1, PLAN stage B, F3 to F5, FORKS 4, wine-osu
  patch, AUDIO 5, MOONSHOT-OPPORTUNITIES S5.

### P5. The busy idle thread: trace, then the fast path

Step one is the `WINEDEBUG=+server` trace of an idle session that the APC
note prescribes: identify the busy thread's actual loop (alertable sleeps,
handle waits, queued APCs, message waits) and count request types. C3 makes
this non-optional: the flag that anchored the coalescing story is an Akai
controller option, so the loop's shape is unknown until traced. Step two,
if the trace confirms same-process APC or alertable-sleep churn: implement
the client-side fast path through the ntsync alert event (same-process user
APCs to a client queue, drain before server APCs, cross-process and special
APCs stay server-side), plus, if the trace shows it, a client-side path for
alertable zero-handle sleeps. Ship an `apcprobe` for FIFO order,
NtTestAlert, special APCs, and I/O completion ordering before the patch.

- Certainty: high on the cost, medium on the mechanism. The 30 to 40
  percent idle core is measured; the per-call server round trips for APC
  queueing and alertable sleeps are verified in source (C10); which of them
  Live's loop actually exercises is unproven (C3).
- Invasiveness: high. Core ntdll wait and APC semantics with strict
  ordering rules; a mistake corrupts playback subtly.
- Projected result: idle CPU for the busy thread from 30 to 40 percent to
  under 5 percent, and a large cut in wineserver context switches under
  load. Mechanism: the loop pays about one server round trip per
  millisecond today; the alert event already exists per thread, so
  same-process delivery can skip the server entirely.
- Chance of success: medium. The design sketch and verification list exist;
  the trace may redirect the work (a finding that the loop is message waits
  or timer churn would send this elsewhere). The trace itself is cheap and
  cannot fail to inform.
- Sources: APC note, four-review entry 2, SYNC 4, LIVE 1,
  MOONSHOT-OPPORTUNITIES M1, C2, C3, C10.

### P6. Present path finishing

Stop the perpetual 200 ms reblit timers while panes are hidden and re-arm
on show; make visible-pane reblits event-driven instead of the 5 Hz tick
that copies identical content; lift the WS_POPUP exclusion from the GL
present path by fixing the first-map black frame; A/B the launcher's forced
full-redraw default; port wine-nspa's X11 flush throttle and vectorized
surface copy for windows that stay on the CPU path. Fold in PLAN's framing:
prefer adopting giang17's newer composition work over adding more timers,
which also feeds the parked 11.14 base bump.

- Certainty: high on the waste (30 of 30 identical-content full-pane copies
  hashed at 5 Hz; popups and children still pay the copy path that cost
  about a core before patch 0055). Medium on how much CPU returns.
- Invasiveness: medium-high. dxgi and winex11; the steady reblit is what
  keeps WebView2 panes composited (patch 0041), so removal needs the
  damage-counter and frame-hash evidence at 100, 125, and 200 percent
  scale, plus Learn View, sidebar, and Splice open-close-reopen runs.
- Projected result: idle pane damage near zero, lower CPU while dragging in
  dialogs, and the remaining full-frame copies (Settings, auth dialog,
  plugin editors) move to the GL path. Mechanism: delete recurring copies
  of unchanged pixels; the same class of change already measured 650 MB/s
  to 0.4 MB/s on the main window.
- Chance of success: medium-high. The black-popup first-map issue is the
  known hard part.
- Sources: four-review entry 4, LIVE 4, MOONSHOT-OPPORTUNITIES S3, PLAN
  stage E, PATCHMAP.

### P7. Sync coverage and trust

Root-cause issue 109 (ntsync WAIT_ANY returning instantly in a spin;
18,700 waits per second in an installer) and add a livelock case to the
ntsync probe. Port the maintained fsync fallback (Gofman rebase in the
wine-osu line) so kernels older than 6.14 get futex sync instead of full
server round trips, pick order ntsync, fsync, server. Add an ntsync
off-switch environment variable mirroring PROTON_NO_NTSYNC for A/B runs.

- Certainty: high that the tier is missing (C1 verified the fallback is
  full server). The fsync rebase's current state on our exact base is
  unverified; treat the port as needing its own validation.
- Invasiveness: medium. ntdll and server patches on well-trodden Proton
  code paths, plus probe and docs.
- Projected result: pre-6.14 hosts recover most of the sync win (fsync is
  roughly equal to ntsync in throughput with weaker semantics), and the
  issue 109 class stops shipping silently.
- Chance of success: medium-high.
- Sources: four-review entry 5, SYNC, FORKS, issue 109.

### P8. Topology and placement

Decide the WINE_CPU_TOPOLOGY consumer: port Proton's (about 200
self-contained lines, prefers physical and performance cores) or delete the
launcher export. If ported, base reported CPUs on `sched_getaffinity`
rather than online count, per PLAN. Verify which Windows version the prefix
reports, since Live restricts audio to performance cores only when it sees
Windows 11. Publish hybrid-CPU pinning guidance and run pinned versus
unpinned pairs on a P/E-core machine. No 8-CPU cap by default (C9).

- Certainty: high on the current inertness and the wrong counting basis;
  medium on gains, which are hardware-dependent.
- Invasiveness: medium. One ntdll patch plus launcher policy; reporting
  changes affect Live's own thread placement decisions.
- Projected result: on hybrid CPUs, audio workers stop landing on
  efficiency cores. The scsynth precedent showed a 40 to 50 percent CPU
  swing from placement alone, erased by pinning; that is the size class at
  stake on affected machines.
- Chance of success: medium-high for the port; the policy needs hardware to
  prove.
- Sources: SYNC 2, PLAN stage C, MOONSHOT-OPPORTUNITIES T6/S1, AUDIO 4,
  C5, C9.

### P9. Memory and locality

Step zero: verify wine-nspa 11.x sources or patch files are actually
available; the survey could not confirm it. Then, gated behind the existing
realtime switch: `mlockall` with on-fault locking, the
thread-environment-block hot-state patch, and the two heap triage switches
(delayed free, zeroed free) as documented off-by-default tools for plugin
crashes.

- Certainty: medium. The numbers are wine-nspa's own Live measurements
  (futex wait 94 to 49 microseconds, 14.3 percent cycle cut, 20 percent
  fewer page faults) and are whole-stack, not per patch.
- Invasiveness: medium. ntdll and launcher; mlockall interacts with
  multi-GB sample buffers, so lock on-fault only and measure memory
  pressure, per PLAN's warning against broad locking.
- Projected result: lower worst-case wait latency and fewer faults during
  playback, which is deadline-tail insurance rather than average speed.
- Chance of success: medium.
- Sources: four-review entry 6, FORKS 1, MOONSHOT-OPPORTUNITIES M2, PLAN.

### P10. Timing fidelity

Confirm the Live-version match first (the top hypothesis for issue 101's
0.08 percent ramp delta), then run the deferred export comparisons (buffer
64 versus 2048, and 192 once P3 makes it legal). Review the community QPC
patch and the TSC evidence before deciding whether QueryPerformanceCounter
should change. Measure MIDI output jitter against the 1 ms timer.

- Certainty: low-medium. The delta is real and unexplained; per-buffer
  quantization is quantified insufficient.
- Invasiveness: low for measurement; a QPC change is medium and only
  follows evidence.
- Projected result: fidelity and MIDI timing, not throughput.
- Chance of success: medium.
- Sources: four-review entry 8, issue 101 findings note,
  MOONSHOT-OPPORTUNITIES S12.

### P11. Compiler flag pairs, one contained series

Resolve the T5-versus-non-change conflict by running one bounded experiment
series and then closing the question either way: Proton's baseline
(`-O2 -fwrapv -fno-strict-aliasing -march=nocona -mtune=core-avx2
-mfpmath=sse`), `-O3`, and an `-march=x86-64-v2` variant, each through the
relocation gate, the build audit, and a bench pair. Ship a change only on a
measured win. The default artifact keeps a generic-to-v2 floor because one
tarball serves every machine including Live 11 hosts; a v3 build could only
ever be a separate opt-in artifact. ThinLTO and PGO stay parked as spikes
behind this gate; no surveyed fork ships either for Wine.

- Certainty: high that the expected gain is small. Every hotspot found in
  this research is algorithmic, and most session CPU burns in Live.exe and
  plugins, which no Wine flag touches.
- Invasiveness: low. Build-only, fully audited, reversible.
- Projected result: likely noise to low single digits on Wine-side
  metrics; the value is closing the question with pairs instead of
  repeated debate.
- Chance of success: builds likely succeed; wins uncertain by design.
- Sources: GFX 1, BUILD 4/6, FORKS 3, four-review deliberate non-changes,
  MOONSHOT-OPPORTUNITIES T5.

### P12. Parked strategic tracks

In rough order of readiness, all blocked on the items above or on upstream
motion:

- winepipewire.drv port for every non-ASIO audio path in the prefix;
  default-on in proton-cachyos; after P3.
- DXVK, with the wined3d Vulkan backend as the cheaper first A/B.
  Prefix-level, no rebuild. Abandon criteria are fixed in advance: Live's
  device-name gate must pass, WebView2 panes and GL plugin editors must not
  regress, and it must beat the tuned GL present path in pairs, which
  patches 0055/0058/0059 would no longer cover under Vulkan.
- Base bump to giang17 d2d1-dcomp-11.14 with the rebase narrative pattern
  from the 11.11 to 11.13 bump; brings a winegstreamer stride fix and a
  winewayland deadlock fix, and is where P6's adopt-newer-composition idea
  lands.
- wine-nspa message rings and local objects, after P9's source
  verification; known Live library-panel regression risk near our patches
  0018/0019.
- PipeASIO 1.3.0 evaluation (C7): floor decision first.
- A Linux-plugin bridge on the yabridge model, after the engine path is
  stable.
- Link Audio: measurement and documentation arm only (S13); implementation
  is out of scope until demand and feasibility are shown.

### Opportunistic small items

Cheap, independent, take when passing:

- Land the parked cross-process visible-region fix (patch 0046 on
  `fixes/issue-57-crossproc-visrgn`), then retest Splice input death
  (issue 87).
- Port staging `server-Signal_Thread` (thread-termination race) and
  GE-Proton's winepulse timestamp-wrap recovery for long sessions.
- Check the fractional-scaling DPI override against WebView2's refusal to
  initialize on DPI-awareness mismatch.
- Diff GE-Proton's GPU-description patch against 0057/0061.
- `wineserver -p` persistence or skip-reboot for launch feel (no
  steady-state audio effect).
- Document hard links for plugin folders (the scanner skips reparse
  points), the `/dev/ntsync` requirement, and the forced-quantum symptom.
- Test and document the Carla external-host workflow for unstable
  Linux-native plugins.
- Wine file-I/O streaming benchmark against the disk-overload path.
- THP `madvise` versus `never` experiment on a large session.
- M4L font-API audit for Windows-lax behaviors Max relies on.
- Live 11 `wmvcore` export identification (experimental scope).
- WineASIO-versus-PipeASIO comparison close-out (evidence hygiene only).

## 5. Do not pursue

Merged decision of record from all twelve documents, upheld here: esync or
fsync as the primary sync path (fsync appears only as the P7 fallback
tier); wineserver replacement; vkd3d-proton; DXVK-NVAPI; Fossilize;
pressure-vessel or any runtime container; gamescope; GE-Proton as a
runtime; allocator swaps; `-DontCombineAPCs` in any form (C3 adds that it
is not even the flag the lore thought it was); a blanket PREEMPT_RT
recommendation (S15's measured evaluation stands); wine-wayland migration
this year; timer-resolution de-stubbing; staging DirectComposition patches
into this base, ever; hangover and box64. Whole-process realtime stays the
default until P2 and P4 produce the evidence to retire it.

## 6. Method note

Verification used: extraction and reading of the vendored Wine base and
PipeASIO 1.2.2 sources; repository scripts and branch
`fixes/audio-hardening`; the open issue tracker on 2026-08-01; and live
fetches of the wine-staging tree listing, Ableton's Options.txt article via
the help-center API, PipeASIO releases (1.2.3 and the same-day 1.3.0), and
the wine-osu avrt patch. Claims from wine-nspa remain self-reported and are
marked as such wherever they set expectations.
