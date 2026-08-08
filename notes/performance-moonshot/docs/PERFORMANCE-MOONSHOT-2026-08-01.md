# Performance moonshot research, 2026-08-01

This document records the research pass behind the `performance-moonshot`
branch. It describes how Ableton Live behaves as a Windows application, what
Proton and other Wine forks do for speed and stability, where our own stack
stands, and which improvements we should try, in ranked order. It records
research only. Nothing in this document is implemented.

## How to read this document

Sections 1 to 4 are the four reviews. Section 5 is the combined opportunity
list. Every opportunity names its evidence, its cost, and the measurement that
proves or disproves it. A performance claim needs a before/after pair from
`scripts/bench-run.sh` under the reference conditions in that script's header.

## The stack today

Facts about the current runtime, for calibration. File references point at the
source of each fact.

- The Wine base is 11.13, from `giang17/wine` branch `d2d1-dcomp-11.13` at
  commit `5c23dd1c` (`patches/BASE.txt`). That branch carries a Direct2D and
  DirectComposition rendering stack that Live 12's interface needs.
- 62 Wine patches apply on top (`patches/`). Most fix window management,
  redraw, display scaling, dialogs, and GPU identification. They are
  correctness patches, not speed patches.
- Audio runs through PipeASIO 1.2.2, an ASIO driver that talks to PipeWire
  directly (`vendor/pipeasio-1.2.2.tar.gz`, two patches in
  `patches/pipeasio/`). ASIO is the Windows low-latency audio driver
  interface that Live prefers. The PipeWire floor is 0.3.56.
- NT synchronization uses ntsync, the Linux kernel driver that implements
  Windows wait primitives. The build fails if either the wineserver half or
  the ntdll half is missing (`scripts/container-build.sh`). Without ntsync,
  every wait becomes a round trip to wineserver, Wine's central coordination
  process, which cost about 1.3 CPU cores with Live running
  (`scripts/container-build.sh`, step 3 comments).
- The launcher (`scripts/ableton-live`) disables Wine debug logging, keeps the
  multithreaded Direct3D command stream on, forces full DirectComposition
  redraws, pins Live's main window class to an offscreen rendering path, and
  runs the whole process under round-robin realtime scheduling at priority 10
  when the system grants realtime rights.
- The main window presents frames through OpenGL directly from the GPU
  (patch 0055). Before that patch, every frame crossed to main memory and
  back, about 650 MB per second (issue 91). A per-frame gate falls back to
  the old path when window geometry disagrees mid-frame (patches 0058, 0059).
- Live's embedded browser views (WebView2) render in software via SwiftShader,
  set by launcher flags. This is a stability choice with a known speed cost.
- The host profile (`scripts/setup-realtime.sh`) grants realtime priority 95,
  unlimited locked memory, and nice -19 to the audio group, sets swappiness
  to 10, and installs a performance CPU governor unit. It advises threaded
  interrupts and a realtime kernel but changes neither.
- The launcher exports `WINE_CPU_TOPOLOGY` (capped at 8 CPUs), but the
  launcher comment records that nothing in this Wine base consumes it yet.
- The build uses Wine's stock compiler optimization level. No -O3, no
  link-time optimization, no profile-guided optimization, no CPU baseline
  above generic x86-64 (`scripts/container-build.sh`). Builds are
  containerized, input-pinned, stripped, and audited per patch
  (`scripts/build-audit.sh`).
- Measurement exists: `scripts/bench-run.sh` records the Direct3D command
  stream thread's CPU share, wineserver context switches per minute, audio
  dropouts per 5 minutes, and Live's DSP load into `bench/results.csv`.

## 1. How Ableton Live works

Facts about Live as a Windows application, from Ableton documentation,
release notes, and credible measurements. Full source URLs are in the
Sources section.

### Engine and threading

- Live parallelizes across independent signal paths only. Everything along
  one signal path runs serially, and the longest path bounds capacity on one
  core. Wake-up latency of a few hot threads therefore matters more than
  total throughput.
- Live's audio workers are Windows realtime threads registered through MMCSS,
  the Windows service that boosts audio threads. Windows caps them at 32 per
  process; Live 12.4 adds an option (`EnableRealTimeWorkQueue`) that raises
  the pool to 64 threads through the Real-Time Work Queue API. The manual
  states that Live expects the audio thread to hold the highest priority.
  Wine implements MMCSS as a stub, so under Wine this entire priority
  structure silently disappears.
- Since Live 11.3, Live restricts audio processing to performance cores on
  hybrid CPUs, and it decides based on the reported Windows version:
  `-RestrictAudioCalculationToPerformanceCores` defaults to true when Live
  sees Windows 11. What Windows version and CPU topology our prefix reports
  therefore changes Live's own thread placement.
- The CPU meter reports buffer processing time divided by buffer duration, a
  deadline ratio, not an operating-system CPU percentage. It is
  frequency-scaling sensitive, and it works as a free fidelity benchmark
  against Windows on identical hardware.
- Effects with no incoming audio suspend automatically. Unused audio
  interface channels cost constant CPU, and Live never disables them at run
  time because drivers misbehave on configuration changes.

### The ASIO contract

- Live does more than exchange buffers with an ASIO driver: it sets and
  validates the sample rate, queries clock sources, opens the driver's own
  control panel from the Hardware Setup button, and derives recording
  offsets from the latencies the driver reports. Wrong reported latency
  shifts every recording; the Driver Error Compensation setting exists to
  paper over exactly that.
- Hidden options (`-AsioNoSetSampleRate`, `-AsioDisableMultiClient`, and
  others) toggle parts of this contract per install.

### Rendering

- Live's default Windows rendering is software rasterization with one final
  Direct3D composite and scale step. Live 12.2 added an opt-in GPU renderer,
  and Ableton's own release notes fixed interface stalls above 100 ms and
  audio glitches attributed to that renderer. `-_ForceGdiBackend` forces a
  pure CPU path. Renderer choice is a first-class stability knob even on
  Windows.
- The stack under the composite step is Direct3D 11 with DirectComposition,
  which is why this fork's base branch exists. Ableton requires whole or
  half display scaling steps (100, 150, 200 percent) and no per-application
  DPI override.

### Embedded browser views

- WebView2 (the Edge-based embedded browser) is load-bearing in current
  Live: the Learn View (12.4) is a WebView with a separate
  picture-in-picture window, and Splice integration (12.3) refuses to run
  without the WebView2 runtime. WebView2 initialization fails outright on a
  DPI-awareness mismatch between host window and runtime.

### Timers, MIDI, disk

- Live requests 1 ms timer resolution and schedules outgoing MIDI itself
  because Windows MME MIDI carries no timestamps. Timer granularity and
  monotonic clock quality directly set MIDI jitter.
- Samples stream from disk by default under a per-buffer deadline; the Disk
  Overload indicator reports missed deadlines. Live writes a continuous
  undo and crash-recovery journal instead of timed autosaves, and the
  browser is a SQLite database with documented disk-error corruption modes.
  File-system semantics in Wine (sync behavior, locking, memory mapping)
  sit under all three paths.
- The plugin scanner skips NTFS reparse points, so symbolic links to plugin
  folders are invisible to it under Wine; hard links work.

### Portability boundary

- Push 3 standalone runs Live's engine as a native Linux binary on an Intel
  Core i3 with a PREEMPT_RT kernel and ALSA. The DSP core is proven
  portable; the Windows-bound surface is the desktop shell: Direct3D and
  DirectComposition UI, WebView2, plugin hosting, MME MIDI, MMCSS
  scheduling. Every dropout under Wine is attributable to platform layers we
  control.
- Live 12 refuses to start without AVX2 CPU instructions, so AVX2 is a
  guaranteed baseline on every Live 12 machine. Live 11 has no such floor.
- Ableton's own performance guidance (performance power plans, no frequency
  scaling, USB selective suspend off, antivirus exclusions) matches what our
  host realtime profile already automates or advises.

## 2. What Proton does for speed and stability

Proton is Valve's Wine distribution for games. The review checked each Proton
mechanism against our actual base (verified by extracting and searching the
vendored Wine 11.13 source) and against Valve's current trees.

### Already in our base, inherited from upstream Wine

Valve and CodeWeavers upstreamed most of their performance work, and Wine
11.13 contains it. We ship all of the following today:

- ntsync (called "inproc sync" upstream). This is the end state of the
  esync, fsync, ntsync lineage. Against plain wineserver synchronization it
  measures 50 to 150 percent faster in many programs; against fsync it is
  roughly equal in throughput and better in correctness and frame-time
  consistency.
- Shared-memory session state. Cursor position, key state, queue status, and
  window class lookups read shared memory instead of calling wineserver.
  Polling loops in a user interface thread are already round-trip-free. Most
  "wineserver makes Wine slow" folklore predates this work.
- The heap rewrite with the Low Fragmentation Heap frontend (Wine 8.3).
- Write-watch tracking via userfaultfd (Wine 10.7).
- FAudio, the low-latency winepulse rework, and winegstreamer.
- Windows thread priorities map to Linux nice values (Wine 11.0), but only
  when the process may lower niceness, and the realtime priority band is
  explicitly clamped away. The source carries a FIXME at the clamp.
- winedmo, an FFmpeg-based media decoding alternative to winegstreamer,
  ships in our base dormant behind a registry value.

### Proton-only, the actionable gap list

- Per-thread realtime scheduling for the Windows realtime priority band:
  implemented by nobody, upstream or Proton. The wineserver FIXME above is
  an open opportunity, and it matters most for a DAW, where the audio
  threads must outrank the interface threads. Our whole-process `SCHED_RR`
  wrapper currently flattens exactly that differentiation.
- MMCSS (the Windows service that boosts audio threads, used through
  avrt.dll) is a stub in upstream and in Proton. Live's "Pro Audio" thread
  registrations do nothing everywhere. No Wine tree integrates RTKit.
- `WINE_CPU_TOPOLOGY` has its consumer only in Proton's tree
  (`fill_cpu_override`, about 200 lines, prefers physical and performance
  cores). Our launcher export does nothing on our base: port the patch or
  delete the export.
- fsync remains in Proton as the fallback for kernels older than 6.14
  without ntsync. Our fork has no such tier; those users fall to full
  wineserver synchronization. Proton also carries an ntsync kill switch
  (`PROTON_NO_NTSYNC`); we have no equivalent A/B switch.
- Heap crash-triage switches: Proton exposes `WINE_HEAP_DELAY_FREE` and
  heap zeroing as environment gates over machinery our base already
  contains. Useful against use-after-free bugs in third-party plugins. A
  few-line port.
- DXVK and vkd3d-proton translate Direct3D to Vulkan. Direct2D runs on the
  public Direct3D 11 API, so Live-style interface workloads ride DXVK by
  default under Proton, which makes DXVK a credible, heavily field-tested
  A/B candidate against our wined3d OpenGL present path. DirectComposition
  is the exception: Proton has nothing there, and our giang17 base is ahead
  of Proton on that axis.
- Prefix lifecycle management: Proton stamps prefixes with a version file,
  tracks every file it installs, and replays migrations on upgrade. Our
  launcher repairs prefix drift ad hoc. The pattern is cheap to adopt.
- The knob discipline itself: every risky Proton mechanism has a documented
  one-line off switch honored per run. That is what makes field debugging
  tractable, and our `ABLETON_*`/`PIPEASIO_*` variables already follow it in
  part.

### Checked and not applicable

- Timer resolution (`timeBeginPeriod`): a stub in every tree, and harmless
  on Linux because waits use high-resolution timers anyway.
- Large page support: implemented nowhere; transparent hugepages are the
  only effect in play.
- Fossilize shader pre-caching and the Steam media converter: bound to
  Steam infrastructure, and a Direct2D interface compiles too few pipelines
  to need caching.
- Steam Linux Runtime containers: our pinned container build and vendored
  inputs already serve the same purpose at build time.

## 3. Where our own stack can improve

Findings from the audit of this repository. File references point at the
evidence.

### Baselines already measured

- Live idles with one Wine thread coalescing asynchronous procedure calls
  (APCs, the mechanism Windows programs use to run a callback on another
  thread) at 30 to 40 percent of one core
  (`notes/ABLETON-WINE-APC-COALESCING.md`). The `-DontCombineAPCs` option
  removed the cost but broke playback (issue 29) and was reverted.
- Without ntsync, idle Live at buffer size 256 drives wineserver to about 45
  percent of a core and 9,000 context switches per second. Synchronization
  probes run 4 to 50 times faster with ntsync
  (`notes/ABLETON-WINE-NTSYNC-REGRESSION.md`).
- The retired CPU present path copied about 650 MB per second to the display
  server and held more than one core while the mouse moved. The OpenGL
  present path idles at 1 to 2 percent (`notes/ABLETON-WINE-GPU-RENDERER.md`,
  issue 91). With gate patches 0058 and 0059 both applied, presenting costs
  about 25 percent of one core at 125 percent scale with the mouse moving.
- PipeASIO at 48 kHz and buffer size 256 measures about 8 percent DSP load in
  Live (`notes/ABLETON-WINE-PIPEASIO.md`).
- The bench harness (`scripts/bench-run.sh`) has produced zero committed
  rows. `bench/results.csv` does not exist in history. Every claim below
  names the measurement that would decide it.

### Audio path

- PipeASIO forces its configured buffer size onto the PipeWire graph
  (`PW_KEY_NODE_FORCE_QUANTUM`, PipeASIO `src/audio.c`). PipeWire arbitrates
  competing forced sizes by recency. When another client wins, the driver
  warns once and keeps feeding Live its own buffer size each graph cycle,
  which plays audio at the wrong speed. This is the issue 49 mechanism.
- Configuration validation silently replaces any buffer size that is not a
  power of two between 16 and 8192 with 1024 (`src/asio.c`). The circulated
  workaround value 192 lands at 1024.
- The driver's realtime thread setup calls `pthread_setschedparam` directly
  with no RTKit fallback. RTKit is the desktop service that grants realtime
  priority to unprivileged processes. On stock Fedora and Ubuntu the audio
  thread silently runs without realtime scheduling.
- Live's entire audio processing runs synchronously inside the PipeWire data
  loop cycle. The copy cost is one memory copy per direction per channel per
  cycle, which is negligible.
- The driver reports a fixed one-buffer latency estimate to Live and never
  invokes the latency-changed callback, so Live's driver latency compensation
  never learns the real device and resampler delay.
- A quantum-follow mode (`follow_device_clock`) already contains the
  renegotiation machinery a general fix needs. It is gated to that mode.
- The seeded duplex configuration resolves the default input and output
  devices independently. Two different devices means two sample clocks in
  one graph and periodic resync crackle.

### Rendering and window machinery

- Every DirectComposition target keeps a 200 ms reblit timer for the whole
  session (patches 0036 and 0041). Patch 0056 gates the blit on visibility;
  the timer keeps ticking. An open embedded-browser pane receives a full-pane
  copy at 5 Hz with content that hashed identical in 30 of 30 samples.
- Patch 0055 excludes `WS_POPUP` windows from the OpenGL present path because
  they show black until the first interaction. Popups and gated frames keep
  the full-frame CPU copy path.
- The launcher forces full DirectComposition redraws
  (`WINED3D_DCOMP_FORCE_FULL_REDRAW=1`). The flag predates the GPU renderer
  and suppresses dirty-rectangle presents wherever the CPU path still runs.
- Two host helpers poll: `learnheal.exe` walks the full window tree once per
  second for the whole session, and the theme watcher wakes every 2 seconds
  and scans the process list.

### Scheduling

- wineserver maps Windows thread priorities to niceness only, and only when
  the host profile's nice -19 grant exists. A Windows realtime priority never
  becomes Linux realtime scheduling; the source carries a FIXME for exactly
  this (`server/thread.c` in the Wine base).
- The launcher's whole-process `SCHED_RR 10` is therefore the only realtime
  scheduling Live's audio worker threads ever receive. PipeASIO's data loop
  runs `SCHED_FIFO 15` and waits on Live workers that may hold no realtime
  priority at all on stock distributions: a priority inversion.
- `WINE_CPU_TOPOLOGY` is inert. The variable appears nowhere in the vendored
  Wine base or the patch series.

### Synchronization residue with ntsync active

- Queueing an APC to another thread is a wineserver round trip, and an
  alertable sleep waits in the server (`dlls/ntdll/unix/thread.c`,
  `unix/sync.c` in the Wine base). Live runs an APC loop near 1 kHz. This is
  the measured idle cost above and the reason `bench-run.sh` records
  wineserver context switches.
- Message waits and handle lifecycle also remain server-side.

### Build

- Effective compiler flags are Wine's defaults: `-g -O2 -fno-strict-aliasing`
  on the Unix side, `-g -O2` on the PE side. No CPU baseline raise, no
  link-time optimization, no profile-guided optimization.
- The build audit fingerprints shipped binaries per patch
  (`scripts/build-audit.sh`). A post-link optimization step would add
  unpinned inputs to that chain.

### Unmerged work and open issues

- Branch `fixes/audio-hardening` holds the corrected issue 49 analysis
  (`notes/ABLETON-WINE-PIPEASIO-CRACKLE.md` on that branch) and an ordered
  fix plan, F0 through F8, with a risk table and a three-distribution
  verification matrix. It is the most valuable unmerged artifact in the
  repository.
- Branch `fixes/options-txt-perf` holds the known-bad `-DontCombineAPCs`
  experiment. Keep it as history.
- Open performance and stability issues: 49 (crackle), 109 (ntsync waits
  return instantly; an installer spun at 18,700 waits per second), 63 (VST
  interaction delay, no measurements yet), 115 (Convolution Reverb freeze on
  device open), 87 (Splice pane stops receiving input after collapse and
  reopen; 28,730 versus 710 mouse messages measured), 92 (black screen on
  F11), 42 (fullscreen), 111 (installer hang while the USB driver runs), 46
  (MIDI hotplug).

## 4. What other Wine forks do

Survey of the fork landscape as of 2026-08-01, ordered by relevance to this
project.

### wine-nspa, the closest prior art

wine-nspa (nine7nine) is a pro-audio Wine for native Windows DAWs, alive on a
Wine 11.8 base, and it benchmarks its changes on Ableton Live 12 workloads,
so its measurements transfer to our application directly. Its design
invariant: with its realtime variable unset, every code path is byte
identical to upstream Wine.

We took two windowing commits from it (our patches 0002 and 0003) and nothing
else. The unadopted remainder, with wine-nspa's own measurements on Live:

- Per-thread realtime layering: Windows time-critical threads and audio
  threads get realtime classes at distinct priorities, plugin worker threads
  included, instead of one flat process priority.
- MMCSS mapped to real scheduling: thread boosts derive from the
  application's own AvSetMmThreadCharacteristics calls.
- Priority inheritance on locks (priority inheritance means a lock lends its
  waiter's priority to the current holder, which prevents a low-priority
  thread from stalling a realtime one): critical sections ride
  `FUTEX_LOCK_PI` on a stock kernel, condition variables use requeue-PI, and
  worst-case condition wait latency fell from 263 to 152 microseconds.
- Memory locking under a realtime gate: `mlockall` with on-fault locking cut
  maximum futex wait from 94 to 49 microseconds and page faults by 20
  percent on Live playback. Huge-page promotion follows on top.
- Hot-path work: thread-local state moved into the thread environment block
  cut CPU cycles 14.3 percent on a 30 second Live playback; an X11 flush
  throttle plus a vectorized surface copy cut winex11 CPU 64 percent; heap
  commit hysteresis and cache-line isolation round it out.
- Message rings: shared-memory rings for same-process Win32 messages cut
  message round trips by 78 to 99 percent on Live. One caution transfers:
  their session-wide shared-memory variant caused a Live library-panel
  regression, fixed by per-queue memory; our own shared-session patches
  (0018, 0019) sit near the same ground.
- io_uring file paths, a client-side scheduler thread, and local timer and
  event objects that avoid wineserver.
- A custom-kernel overlay (priority-ordered ntsync waits, mutex-owner
  priority boosting, kernel channel objects that replaced its wineserver
  fast path, 95 percent dispatcher CPU cut). This tier conflicts with our
  every-Linux-computer target and only fits as an optional future overlay.

The stock-kernel tier is portable to our base with medium effort; the fork
force-pushes and its numbers are whole-stack rather than per patch, so each
port must be measured on our side.

### The wine-osu lineage

wine-osu (whrvt/wine-osu-patches, Wine 11.12 plus staging, one minor version
from our base) maintains the low-latency audio patch line. Directly relevant
pieces:

- An avrt patch that maps AvSetMmThreadCharacteristics("Pro Audio") to
  time-critical thread priority: the missing top half of the scheduling
  chain in section 5's first opportunity.
- Removal of the 10 millisecond period floor in mmdevapi plus period and
  buffer environment overrides. Our engine path bypasses this (ASIO), but
  every shared-mode Windows audio consumer inside the prefix gains from it.
- A current rebase (by Paul Gofman) of fsync as an automatic fallback behind
  ntsync for kernels without `/dev/ntsync`, with pick order ntsync, fsync,
  server. This is the exact missing tier from section 2.
- A working-in-progress winepipewire.drv (39 patches, originally by the
  PipeASIO author) giving Wine a native PipeWire audio backend. The same
  driver ships enabled by default in proton-cachyos since July 2026.
- Evidence for the timing investigation: upstream Wine answers
  QueryPerformanceCounter through a system-call clock path, while Windows
  stamps time from the TSC, the CPU's built-in timestamp counter; a
  community proton_QPC patch exists. This is a concrete mechanism candidate
  for the 0.08 percent tempo-ramp delta and for MIDI jitter.

### GE-Proton and wine-tkg

- GE-Proton applies wine-staging minus roughly 30 exclusions with written
  rationale per exclusion: a vetted map of known-bad staging patches worth
  keeping. Its video rework routes all media through FFmpeg and winedmo with
  winegstreamer removed, a maintained fallback architecture if winegstreamer
  fails us. One GE patch preserves runtime OpenGL GPU descriptions and
  overlaps our patches 0057 and 0061; worth a diff. A winepulse fix recovers
  from timestamp wrap in sessions past a few hours.
- wine-tkg is an options matrix, not a patch source: ntsync toggles, a
  wineserver realtime capability option, and prefix hygiene switches that
  stop Wine from registering file associations system-wide. Its compiler
  defaults stay at -O2 with no LTO, PGO, or march raise on offer.

### wine-staging today

esync left staging when ntsync went upstream; no scheduling or timer
patchsets remain. The few sets relevant to a GUI plus audio application:
`server-Signal_Thread` (a thread-termination race), PeekMessage and message
order correctness, and window style attribute sync. One warning transfers:
Kron4ek's build config excludes staging's DirectComposition patch as broken,
so staging dcomp must never mix into our d2d1-dcomp base.

### Build-optimization distributions

- CachyOS builds Wine at -O2 with AVX explicitly disabled, ships a separate
  x86-64-v3 variant, and wires no profile-guided optimization for Wine.
  Kron4ek builds at -O3 with a generic x86-64 baseline: the one precedent
  for portable -O3.
- No surveyed fork uses profile-guided optimization or post-link
  optimization for Wine. That work would be novel, not adoption.
- proton-cachyos ships the winepipewire driver enabled by default and
  documents Proton's nice-based thread priority model, the weakest form of
  the differentiation section 5 targets.

### App-specific forks and our own upstream

- ElementalWarrior's Affinity fork dissolved itself upstream: WineHQ merged
  the general work and the app now runs on stock Wine plus two drop-in
  files. The pattern to copy: keep patches single-topic, push what
  generalizes upstream, ship the pinned tarball meanwhile.
- giang17, our base: the `d2d1-dcomp-11.13` branch was force-refreshed into
  a single snapshot commit after we vendored it, so our exact base commit no
  longer exists upstream as history (our vendored tarball is now the
  provenance record). A `d2d1-dcomp-11.14` branch exists as of 2026-07-31
  with upstream Wine 11.14 underneath, including a winegstreamer stride fix
  and a winewayland deadlock fix. That branch is the natural next base bump.

### Adjacent projects

- yabridge (plugin bridging): preallocated shared-memory audio buffers with
  sockets doubling as wakeups so the realtime path takes no locks, and a
  two-sided watchdog that unblocks stuck calls when either side dies. Its
  Wine variant delegates thread priority to Wine and keeps priority
  inheritance mutexes off the callback body. This is the blueprint for both
  PipeASIO hardening and any future Linux-plugin bridge.
- PipeASIO upstream released 1.2.3 (we ship 1.2.2): build fixes only,
  including a link fix for distributions that inject link-time optimization
  flags. Low-cost vendor bump.
- JACK-era lore that still applies: a realtime watchdog with eviction rather
  than hope, dropout accounting as a first-class counter, and the priority
  ladder device interrupts above audio server above clients. PipeWire's data
  threads default to realtime priority 88 to sit above threaded interrupts
  at 50; on a PREEMPT_RT kernel every interrupt becomes a thread at 50, so
  that ladder needs a verification run on a realtime kernel before we advise
  users about one.

## 5. Opportunities

Ranked by expected impact over effort. Each entry states the change, the
evidence, where the work lands, and the measurement that decides it. Entries
marked Speed, Stability, or Both. A claim counts as proven only with a
before/after pair from `scripts/bench-run.sh` under its reference conditions.

### 0. Record baselines first (prerequisite, Both)

Change: run and commit `bench/results.csv` rows for the current release,
idle and reference-set playback, before any change lands. Extend the harness
with three columns: Live process total CPU, the APC-coalescing thread's CPU,
and Live's own CPU meter reading. Live's meter is a deadline ratio (section
1), so the same Set on the same hardware under Windows gives a direct
fidelity target.
Evidence: the harness exists with zero committed rows (section 3).
Lands: bench/, `scripts/bench-run.sh`.
Verify: rows exist; every later entry cites them.

### 1. Restore Live's thread-priority structure (Both)

The centerpiece. Live registers its audio workers as realtime threads
through MMCSS and expects them to outrank everything else (section 1). Wine
stubs MMCSS, wineserver clamps the realtime band to nice values (section 2),
and our whole-process `SCHED_RR 10` gives the interface the same priority as
the audio path (section 3). Nobody in the ecosystem ships the fix; wine-nspa
proves the model on Live itself (section 4).

Change, in order:
1. De-stub avrt so AvSetMmThreadCharacteristics("Pro Audio") yields
   time-critical priority. Base: the wine-osu avrt patch.
2. Implement the `server/thread.c` FIXME: map the Windows realtime band to
   per-thread `SCHED_FIFO`/`SCHED_RR`, budgeted under the host rtprio grant,
   placed below PipeASIO's data loop (FIFO 15) and PipeWire (88). Gate
   behind an environment switch for A/B runs.
3. Only then retire whole-process `SCHED_RR` as the default. It is currently
   the only realtime scheduling Live's workers get; removing it first would
   regress every stock machine (section 3 ordering constraint).
4. Add the RTKit fallback in PipeASIO last: RTKit imposes a runtime budget
   that would kill the process while interface threads still run realtime.
Lands: wine patch (avrt, server), launcher, pipeasio patch.
Verify: `ps -eLo pid,tid,cls,rtprio,comm` shows realtime only on threads
that asked; bench pairs on a high-core and a 4-core machine; dropout count
at buffer sizes 128 and 64; DSP-load delta on the reference Set.

### 2. Same-process APC fast path (Speed)

Change: deliver same-process user APCs through the ntsync alert event
instead of a wineserver round trip, draining before server APCs;
cross-process APCs keep the server path.
Evidence: Live runs an APC loop near 1 kHz; the coalescing thread burns 30
to 40 percent of a core at idle; the design sketch exists in
`notes/ABLETON-WINE-APC-COALESCING.md` (section 3). The `-DontCombineAPCs`
experiment proved the cost is real and the application-side shortcut breaks
playback, so the fix belongs in Wine.
Lands: wine patch (ntdll).
Verify: wineserver context-switch delta collapses; the coalescing thread
drops under 5 percent idle; playback and automation stay correct on the
reference Set; a dedicated APC-order probe in the tester kit passes.

### 3. Finish the audio-hardening plan (Both)

Change: execute the ordered plan already written on branch
`fixes/audio-hardening`: capture-and-diagnose tooling first, then quantum
convergence (follow the graph cycle size instead of forcing our own, accept
sizes that are not powers of two, stop silently replacing invalid
configuration values with 1024), then correct latency reporting with the
latency-changed notification, then a single-clock duplex default. Add
priority-inheritance mutexes on driver state shared with the realtime
thread, a stall watchdog that silences rather than hopes (the JACK eviction
model, section 4), and the PipeASIO 1.2.3 vendor bump.
Evidence: issue 49 remains open; the mechanism is confirmed (section 3);
Live derives recording offsets from reported latency (section 1), so the
static one-buffer guess shifts recordings today.
Lands: pipeasio patches, launcher, `scripts/setup-prefix.sh`, docs. Every
new patch needs its build-audit fingerprint entry.
Verify: the plan's own three-distribution matrix; loopback tests at pinned
graph sizes 192, 384, 1024 with a second forcing client; wall-clock equals
sample count; recording alignment against a loopback cable.

### 4. Finish the present path (Speed)

Change: stop the perpetual 200 ms reblit timers when panes are hidden and
re-arm on show; make visible-pane reblits event-driven instead of a 5 Hz
tick; lift the popup-window exclusion from the OpenGL present path by fixing
the first-map black frame; port wine-nspa's X11 flush throttle and
vectorized surface copy for every window still on the CPU path; A/B the
forced full-redraw launcher default.
Evidence: open panes take identical-content full-pane copies at 5 Hz;
popups still pay the copy path that cost about one core before patch 0055
(section 3); the flush throttle cut winex11 CPU 64 percent on Live playback
(section 4).
Risk: the steady reblit keeps embedded-browser panes composited (patch 0041
rationale). Change only with the damage-counter and frame-hash evidence at
100, 125, and 200 percent scale.
Lands: wine patches (dxgi, winex11).
Verify: pane damage rate drops to near zero at idle; Learn View, the
documentation sidebar, and Splice survive open, close, and reopen; bench
pairs while dragging inside dialogs.

### 5. Sync coverage and trust (Stability)

Change: root-cause issue 109 (ntsync waits returning instantly in a spin)
and add a livelock regression case to the ntsync probe; port the maintained
fsync fallback so kernels older than 6.14 get futex-based sync instead of
full wineserver round trips; add an ntsync off-switch environment variable
for A/B runs, mirroring Proton.
Evidence: section 3 (issue 109, 18,700 waits per second), section 2 (the
missing tier and missing switch), section 4 (the fallback rebase exists and
is current).
Lands: wine patches (server, ntdll), probe suite, TROUBLESHOOTING.md.
Verify: the new probe case fails on an affected kernel and passes after the
fix; the stuck installer completes; sync on/off bench pairs on one machine.

### 6. Memory and locality (Speed)

Change: gate `mlockall` with on-fault locking behind the existing realtime
switch; port the thread-environment-block hot-state patch; add the two heap
environment switches (delayed free, zeroed free) as crash-triage tools for
plugin bugs. Huge-page experiments follow later, not first.
Evidence: measured on Live by wine-nspa: maximum futex wait halved, 14.3
percent cycle cut (section 4); the heap switches are a few-line port over
machinery our base already contains (section 2). Locked memory is already
provisioned by the host profile.
Lands: wine patches (ntdll), launcher, docs.
Verify: bench pairs plus perf counters for page faults and futex wait
times; the heap switches documented and off by default.

### 7. Core topology and placement (Speed on hybrid CPUs)

Change: port Proton's `WINE_CPU_TOPOLOGY` consumer (it prefers physical and
performance cores) or delete our inert export; verify which Windows version
the prefix reports, because Live restricts audio to performance cores only
when it sees Windows 11 (section 1); then choose and document a deliberate
policy for hybrid CPUs.
Evidence: the export provably does nothing today (section 3); the consumer
is about 200 self-contained lines (section 2).
Lands: wine patch (ntdll), launcher, docs.
Verify: Live's worker placement on a hybrid CPU before and after; dropout
pairs on a performance-plus-efficiency-core machine.

### 8. Timing fidelity (Both)

Change: review the community QPC patch and the timestamp-counter evidence,
then decide whether our QueryPerformanceCounter should read the CPU's
timestamp counter; run
the deferred tempo-ramp export comparison (buffer 64 versus 2048, and 192
once entry 3 makes it legal); measure MIDI output jitter, since Live
schedules MIDI itself against the 1 ms timer (section 1).
Evidence: upstream answers QPC through a system-call path where Windows
uses TSC (section 4); the 0.08 percent ramp delta remains unexplained
(section 3).
Lands: notes first; wine patch only if the evidence says so.
Verify: ramp-duration comparison against the Windows reference; MIDI
loopback jitter distribution before and after.

### 9. Prefix lifecycle engine (Stability)

Change: adopt Proton's prefix pattern: a version stamp in the prefix, a
manifest of every file our tooling installs, and replayable migrations on
update, replacing ad hoc repair passes.
Evidence: section 2; our launcher already repairs handler entries and prefix
drift case by case (section 3).
Lands: launcher and installer scripts.
Verify: update from the previous release replays cleanly on a copy of a
real prefix; uninstall removes exactly the manifest.

### 10. Strategic tracks (park until the above land)

- winepipewire.drv port: native PipeWire for every non-ASIO audio path in
  the prefix, from the PipeASIO author, shipping default-on in
  proton-cachyos. Supersedes the shared-mode floor patches when mature.
- DXVK as an opt-in A/B for Live's Direct3D 11 interface compositing:
  heavily field-tested under Proton for exactly this workload class, but it
  forfeits our tuned OpenGL present path, so it must win pairs to earn a
  default.
- Base bump to giang17 `d2d1-dcomp-11.14`: upstream is snapshot-rebuilt, so
  plan a rebase narrative like the 11.11 to 11.13 bump. Brings a
  winegstreamer stride fix and a winewayland deadlock fix.
- wine-nspa message rings and local objects: the largest remaining
  wineserver cuts with Live-measured numbers, medium-high port effort, and
  a known Live library-panel regression in one variant near our own
  shared-session patches. Measure carefully.
- A Linux-plugin bridge on the yabridge model (shared-memory audio, no
  locks on the realtime path, two-sided watchdog) once the engine-path work
  is stable.

### Small stability fixes, do opportunistically

- Land the parked cross-process visible-region fix (patch 0046 on
  `fixes/issue-57-crossproc-visrgn`), then retest the Splice input-dead
  pane (issue 87): same machinery family.
- Port staging `server-Signal_Thread` (thread-termination race; plugin
  robustness).
- Port GE-Proton's winepulse timestamp-wrap recovery for sessions past a
  few hours.
- Check our fractional-scaling DPI override against WebView2's refusal to
  initialize on DPI-awareness mismatches (section 1).
- Diff GE-Proton's GPU-description patch against our 0057 and 0061.
- Document: hard links, never symbolic links, for plugin folders (Live's
  scanner skips reparse points); the `/dev/ntsync` requirement and the
  global forced-quantum symptom in TROUBLESHOOTING.md.

### Deliberate non-changes

- Compiler flags stay at Wine's defaults. No fork ships profile-guided or
  post-link optimization for Wine; every hotspot found in this research is
  algorithmic, not code generation. A raised CPU baseline would break Live
  11 machines and the one-tarball distribution model. Live 12 guarantees
  AVX2 on its hosts, so hand-vectorized routines with runtime dispatch
  (the wine-nspa approach) are the acceptable form of vectorization.
- Timer-resolution calls stay stubs: Linux waits are already
  high-resolution, so there is no coarse quantum to defeat.
- No staging DirectComposition patches into this base, ever (known broken
  with the d2d1-dcomp stack).
- No runtime library container: the pinned build container and vendored
  inputs already cover what Steam's runtime solves.
- Whole-process realtime stays the default until entry 1 step 3's evidence
  exists.

## Sources

Repository evidence: `patches/BASE.txt`, `scripts/container-build.sh`,
`scripts/ableton-live`, `scripts/setup-realtime.sh`, `scripts/bench-run.sh`,
`scripts/build-audit.sh`, `notes/ABLETON-WINE-APC-COALESCING.md`,
`notes/ABLETON-WINE-NTSYNC-REGRESSION.md`, `notes/ABLETON-WINE-GPU-RENDERER.md`,
`notes/ABLETON-WINE-PIPEASIO.md`, `notes/ABLETON-WINE-RT-SCHEDULING.md`,
`notes/FINDINGS-TEMPO-RAMP-2026-07-31.md`, branch `fixes/audio-hardening`
(`notes/ABLETON-WINE-PIPEASIO-CRACKLE.md`), the vendored Wine source, the
PipeASIO 1.2.2 source, and the open issue tracker.

Ableton: multi-core FAQ (help.ableton.com article 209067649), CPU usage
monitoring (209069609), CPU meter (360019151379), latency articles
(360010545559, 209072409, 209072249), ASIO buffer and sample-rate handling
(209770985), Windows optimization (209071469, 209071269), graphics settings
(4405388230674), Options.txt (6003224107292), video (209773125), disk
overload (115001041970), crash recovery (115001878844), browser database
(360000794970), system requirements (115001663530, 12971338677148), Live 12
release notes (ableton.com/en/release-notes/live-12), Live 12 manual chapter
37, MIDI fact sheet. Renderer measurements: camplaix.github.io. Windows
realtime-thread cap: helpcenter.steinberg.de article 115000535804. Push 3
teardown: mslinn.com/av_studio/ableton-p3s-linux.html. Options catalogue:
studiocode.dev/kb/Ableton/ableton-options.

Proton and upstream Wine: github.com/ValveSoftware/Proton (script,
changelog wiki), github.com/ValveSoftware/wine branch bleeding-edge, Wine
GitLab merge requests 1628 (heap), 3103, 5896, 8976, 8061, 9000 (shared
session state), Phoronix reports on Wine 8.3, 10.7, 10.16, ntsync in Linux
6.14, and Fossilize; fedoraproject.org/wiki/Changes/NTSYNC.

Forks and adjacent: github.com/nine7nine/Wine-NSPA and wine-nspa-src with
the document set at nine7nine.github.io/Wine-NSPA (client scheduler, cs-pi,
condvar-pi, gamma channel dispatcher, message rings, io_uring, memory and
large pages, hot paths, audio stack, yabridge-nspa, ntsync-pi driver,
current state); github.com/whrvt/wine-osu-patches (branch winello);
github.com/NelloKudo/osu-winello; github.com/GloriousEggroll/proton-ge-custom
(protonprep script, GE-Proton11-1 notes); github.com/Frogging-Family/wine-tkg-git
and community-patches (proton_QPC); github.com/wine-staging/wine-staging;
github.com/CachyOS/CachyOS-PKGBUILDS (wine-cachyos) and
github.com/CachyOS/proton-cachyos; github.com/Kron4ek/Wine-Builds;
github.com/giang17/wine (branches d2d1-dcomp-11.13, d2d1-dcomp-11.14);
github.com/robbert-vdh/yabridge (architecture document);
github.com/wineasio/wineasio; github.com/M0n7y5/pipeasio (release 1.2.3);
docs.pipewire.org (module-rt); blog.thepoon.fr/osuLinuxAudioLatency;
affinity.liz.pet and codeberg.org/wanesty/affinity-wine-docs
(ElementalWarrior outcome).
