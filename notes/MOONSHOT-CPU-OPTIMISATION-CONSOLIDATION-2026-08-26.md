# CPU optimisation review

Date: 26 August 2026

## Decision

The strongest measured saving comes from the Live worker count. On one
16-core, 32-thread computer, 16 workers reduced Live CPU use by 36.77% at 64
frames. Voluntary thread switches fell by 42.42%.

A later loaded test also favoured fewer workers at 32 and 64 frames. The result
at 128 frames was mixed. Real 4-core, 6-core, and 8-core tests remain the release
gate.

The next release should start with the measurement tools and proof tools. Add
each CPU change after its own paired audio test.

Use the following policies:

- use the automatic Live worker change after the smaller-computer tests
- measure the PipeASIO output change as a small saving
- use Pro Audio as a device profile comparison
- give PipeWire graph settings one owner
- use Linux scheduling for the changing AMD preferred-core ranks
- use the Wine wait shortcut through an explicit experiment
- keep callback timing probes separate from CPU result runs

Lower CPU use helps when audio deadlines, routes, and sound quality stay equal.

## Review branches

Each branch contains one review subject. Reviewers can inspect the code and
tests beside the report.

| Branch | Purpose | Next evidence |
|---|---|---|
| moonshot-cpu-optimiser-bench-report | Runs and compares the 5 benchmark Sets | one supervised hardware run |
| moonshot-cpu-optimiser-live-workers | Chooses a smaller Live worker count | loaded tests on 4-core, 6-core, and 8-core computers |
| moonshot-cpu-optimiser-pipeasio-hotpath | Removes one repeated output action | paired tests at 32, 64, and 128 frames |
| moonshot-cpu-optimiser-pipewire-arbitration | Gives each PipeASIO instance its own graph identity | 2 Live instances with different buffer sizes |
| moonshot-cpu-optimiser-pipeasio-telemetry | Measures time across the audio callback | one short cause-finding run |
| moonshot-cpu-optimiser-ntsync-proof | Proves that the running Wine server uses the kernel wait driver | attach the proof to each CPU report |
| moonshot-cpu-optimiser-hybrid-topology | Records the processor core layout | tests on Intel hybrid computers |
| moonshot-cpu-optimiser-pipewire-pro-audio | Compares the current device profile with Pro Audio | tests with the connected target interface |
| moonshot-cpu-optimiser-wine-bounded-fastpaths | Tests one Wine wait shortcut | suspend and resume tests with loaded Sets |
| moonshot-cpu-optimiser-research-consolidation | Records the decisions and test gates | review with the 9 subject branches |

The branches are separate review units. Integration requires a new branch,
resolved file overlap, updated patch numbers, updated hashes, and the combined
test set.

## Source versions

The review used fixed source revisions:

| Project | Version | Revision or path |
|---|---|---|
| ableton-linux | common base | 54933547bef023d937e3b5cb23d438afab7905bc |
| PipeASIO | 1.5.0 with package patches | pipeasio-cpu/build-analysis/pipeasio-1.5.0 |
| PipeWire | 1.6.8 | b741e0c74f5436f0c925f7741140db0efd32cf4e |
| WirePlumber | 0.5.15 | bc4fa8f5e84806f86530c97cb35283eecc3ec081 |
| Linux | 7.1.8 | 25c76bea853d0db65b51fb4697a47cbfd9e35e76 |
| Wine | 11.13 package source | 5efbab2d2fda0ca498cb992c254d9d50a1910307 |

The supporting source folders are:

- /tmp/moonshot-pipewire-source-1.6.8
- /tmp/moonshot-wireplumber-source-0.5.15
- /tmp/moonshot-linux-source-7.1.8
- /tmp/rebuild-0105/wine-src

## Test computer

The review computer has the following relevant properties:

- AMD Ryzen AI MAX+ 395
- 16 physical cores and 32 hardware threads
- Linux 7.1.8 with dynamic pre-emption
- PipeWire 1.6.8
- WirePlumber 0.5.15
- Wine 11.13 package version 2026.08.24.1
- Live 12.4.3
- PipeASIO with 2 inputs, 2 outputs, 48 kHz, and 256 frames

Every core reports the same Linux capacity value. The computer also reports AMD
preferred-core ranks from 166 to 236. Firmware can change those ranks while the
computer runs.

The user PipeASIO file contains realtime = 1. The review preserved that file.
Existing results therefore include real-time callback scheduling. Each future
result must compare the ordinary and real-time paths separately.

## Live worker count

Live creates audio workers to process tracks and devices in parallel. A high
worker count can add waiting and context switching at small buffer sizes.

The retained 64-frame results are:

| Workers | Live CPU | Voluntary switches each second | PipeWire errors each second |
|---:|---:|---:|---:|
| 31 | 40.61% | 77,293 | 10.33 |
| 16 | 31.22% | 43,623 | 5.06 |
| 8 | 18.22% | 23,130 | 2.53 |

The 8-worker result needs a loaded audio deadline test. A lower CPU value can
also mean that Live performs less work before each deadline.

The revised automatic choice follows 2 simple limits:

- choose at least one worker for each available physical core
- choose at least half of Live's expected worker pool

The result stays within Live's pool limit of 31 workers. The 32-thread review
computer selects 16 workers.

The tests cover:

- one to 32 available hardware threads
- computers that use simultaneous multithreading
- computers that use one hardware thread per physical core
- 2 processor packages
- restricted processor sets
- user settings and launcher-owned settings

Run 5 paired tests for each worker choice at 32, 64, and 128 frames. Use loaded
Sets with at least 24 separate audio chains.

## Launch settings

Several launch settings already affect CPU use. Test each setting separately.

| Setting | Current use | Review decision |
|---|---|---|
| ABLETON_MAX_AUDIO_THREADS=auto | chooses the Live worker count before Live starts | use the revised automatic choice after the smaller-computer tests |
| ABLETON_RT | starts Wine with round-robin scheduling when the system permits it | compare the standard and round-robin runs at the current priority |
| ABLETON_POWER | asks the system for the performance power profile | record the active profile and frequency in every run |
| PIPEASIO_REALTIME=on | gives the PipeASIO callback real-time scheduling | use as a paired scheduling experiment |
| ABLETON_DCOMP=off | selects the display compatibility path | reserve for display diagnosis |
| WINE_D3D_FORCE_GPU_RENDERING=1 | gives Wine a substitute GPU identity | use for the identified GPU compatibility case |
| PIPEASIO_ALLOW_QUANTUM_MISMATCH=on | continues after a buffer-size difference | reserve for timing diagnosis because playback speed can change |
| PIPEASIO_FOLLOW_DEVICE_CLOCK=on | follows a clock supplied by the audio device | use for device-driven clocks such as Bluetooth |
| WINE_APC_FASTPATH=1 | selects the experimental kernel wait path | release runs use the ordinary Wine path |
| snd_usb_audio.lowlatency | selects the Linux USB low-latency path | the current kernel reports the path as active |

PipeASIO real-time scheduling raised missed audio deadline counts in an upstream
64-frame test.
The upstream result was about 39 times the ordinary count. Use the setting as a
separate experiment on the review computer.

## PipeWire Pro Audio

Pro Audio is a Linux audio device profile. It can change routes, channels, active
devices, and hardware interrupt timing. It uses the same words as a Windows
audio task class, while the 2 features serve separate purposes.

A lower Live CPU value can mean that PipeWire or the kernel performs more work.
Compare total host CPU, Wine CPU, PipeWire CPU, and hardware interrupts.

The profile tool follows the sequence below:

1. Record the current device state.
2. Run the benchmark with the current profile.
3. Select Pro Audio temporarily for the same device.
4. Run the same benchmark again.
5. Restore the original profile.
6. Compare routes, channels, settings, and device identity.

Run 5 matched pairs at 32, 64, and 128 frames. Apply the result to the tested
device and configuration.

The session completed device discovery for internal audio device 69. A connected
target USB interface remains part of the full profile test.

See notes/PIPEWIRE-PRO-AUDIO-AB.md in the Pro Audio branch for commands.

## PipeWire setting ownership

PipeWire can receive a graph-wide buffer size and a buffer size from an active
audio item. The graph-wide value has priority. PipeWire otherwise uses the most
recent active item.

PipeASIO should set its own audio item and observe other owners. The branch uses
the PipeWire item ID to recognise its own request. The ID also separates 2 Live
instances that share the same name.

Use a full-window setting log in each benchmark. A value that changes and then
returns can still affect the audio result.

Test the following cases:

- 2 PipeASIO instances at 128 and 256 frames
- a separate JACK client that requests a buffer size
- device removal and return
- PipeWire and WirePlumber restart

## Processor core placement

The review computer reports one processor class. Static placement would replace
Linux scheduling with a fixed guess.

AMD preferred-core ranks change while the computer runs. Linux already uses
those ranks when it selects a core. Use the topology report as evidence and let
Linux make that choice on the review computer.

A future hybrid-computer policy needs the following inputs:

- the processor set granted to the process
- physical core and hardware thread groups
- Linux performance and efficiency core lists
- the core class reported to Windows programs
- the role and dependencies of each audio thread

Move background work after tracing its dependencies. Keep the audio callback,
audio workers, PipeWire data loop, and their direct helpers under Linux
scheduling.

Test a future policy on at least 2 Intel hybrid generations and one other
capacity-based computer.

## Small source changes

The source review found the following focused candidates:

| Candidate | Expected effect | Required test |
|---|---|---|
| PipeASIO output publication | removes one repeated action for each delivered output cycle | loaded paired audio runs |
| PipeASIO timing report | shows time before, during, and after Live processing | one short cause-finding run |
| PipeASIO item identity | stops one Live instance from taking another instance's buffer request | 2 simultaneous instances |
| Wine alertable wait | moves one wait from the Wine server to NTSync | suspend, resume, fault, and loaded audio tests |
| Linux current behaviour | already provides NTSync, AMD preferred ranks, and USB low latency | record each feature in the system report |
| Wine audio task support | could apply scheduling by thread role | trace Live task registration first |

The headless PipeASIO driver used about 0.5% CPU with 2 inputs, 2 outputs, and
128 frames. The result places the likely large saving in Live and Wine worker
coordination.

The PipeASIO output change remains a small candidate. It removes one repeated
output action and keeps the recovery action for a cycle that still needs output.

The timing report adds clock reads to the callback. Enable it for cause finding.
Use the regular build for before and after CPU results.

## Larger Wine ideas

The review assigns broader Wine changes to further tests:

| Idea | Evidence needed before a release change |
|---|---|
| same-process alert queue | alert order, access, process exit, and handle reuse tests |
| window hook copy | self-removal and cross-thread change tests |
| message queue reuse | nested sends, timeouts, callbacks, and wake tests |
| window update reuse | visible-window paint, erase, and cross-thread tests |

The current Wine branch contains the smaller alertable wait experiment. Add a
broader idea after its full Windows behaviour tests pass.

## Wine wait experiment

Wine sends an alertable delay through the Wine server. The experiment sends one
specific delay through the existing NTSync alert event instead.

Release runs use the ordinary Wine path. Set WINE_APC_FASTPATH=1 for a paired
experiment.

The final branch passed the following checks:

- all 94 package patches plus the experiment applied in order
- the changed Wine targets compiled and linked
- each main Wine alert test run passed 45 of 45 checks
- the observer stayed silent on the ordinary path
- the experiment reached the NTSync wait
- an injected NTSync error returned to the ordinary path and passed 45 checks
- 30 package checks passed

The broad host build reached an OpenCL header requirement. The changed targets
and the probe runtime completed their build.

The experiment clock pauses during system suspend. The current Wine server clock
counts suspend time. Run the full suspend and resume matrix before any release
policy selects the experiment.

## Branch integration

Several branches edit the same files. The 3 PipeASIO branches also use the same
next patch number.

Use the following integration sequence:

1. Create a new integration branch from the selected release base.
2. Resolve worker, topology, NTSync, and Wine launcher changes together.
3. Give each PipeASIO patch a unique number.
4. Rebuild the patch hash files.
5. Run the full launcher, report, PipeASIO, Wine, and packaging tests.
6. Run the supervised audio comparisons.

## Benchmark report

The benchmark branch runs the following Live Sets in order:

1. Benchmark_Zero
2. Benchmark_Empty
3. Benchmark_Inbuilts
4. Benchmark_Max4Live
5. Benchmark_VSTs

Each Set runs for 30 seconds. Set loading and the short settle period sit outside
the measurement window.

The report records:

- processor, memory, kernel, and audio hardware
- PipeWire and WirePlumber versions and settings
- Wine runtime and Wine prefix, which stores Windows files and settings
- Live version, worker count, and plug-in identity
- total host, process, and thread CPU
- thread switches and processor movement
- hardware interrupts and software interrupts
- PipeWire buffer changes, errors, and missed audio deadlines
- Live deadline measurements from the benchmark controller
- listener crackle reports
- power profile and processor frequency policy

PipeWire setting changes are recorded throughout each run. Device profiles and
links are recorded at the start and end. A profile or link can change and
return between those 2 records. Use a continuous graph trace for a suspicious
run.

Listener reports and tool data serve separate roles. Use both forms of evidence
for each release decision.

The comparison checks the computer, runtime, Wine prefix, Live version, and
plug-ins. It also checks the device, routes, sample rate, buffer size, and power
state.

Use 5 matched before and after pairs for each change. Change one subject in each
pair.

Use a pair when all the following conditions apply:

- every Set has a complete 30-second window
- each collector covers the measurement window
- the runtime, files, routes, and settings stay equal
- the PipeWire sample rate and buffer size stay constant
- the running Wine server shows an active NTSync file descriptor
- the listener reports continuous audio
- PipeWire errors, missed audio deadlines, and Live overloads stay at the comparison baseline
- loaded Sets show a repeated CPU saving beyond normal run variation

The session passed the report tests, asset checks, and plug-in check. It also
completed a launch preview for all 5 Sets. A supervised Live run with the target
interface remains the next step.

See bench/README.md in the benchmark branch for commands and report fields.

## Completed checks

| Area | Result |
|---|---|
| benchmark report | 31 Python tests and 5 shell tests passed |
| benchmark assets | all 12 recorded hashes passed |
| Live workers | 32 worker and setting tests passed |
| Pro Audio tool | 20 policy and recovery tests passed |
| NTSync proof | 5 tests passed |
| core layout report | 6 tests passed |
| PipeASIO branches | patch order, focused tests, build forms, and memory and thread safety checks passed |
| Wine experiment | exact replay, 45-case runs, release policy, and 30 package checks passed |

## Remaining tests

1. Run the worker choice on loaded 4-core, 6-core, and 8-core computers.
2. Measure callback time before, during, and after Live processing.
3. Run the Pro Audio comparison on the connected target USB interface.
4. Test 2 PipeASIO instances with different buffer sizes.
5. Trace Live audio task registration before a thread scheduling policy.
6. Compare Linux and Windows core classes on Intel hybrid computers.
7. Run the Wine wait experiment through suspend and resume.
8. Measure the PipeASIO output change with 2 and many output channels.
9. Attach the running NTSync file descriptor proof to each benchmark.
10. Add a loopback sound check beside the listener report.

## Release order

1. Integrate the benchmark, NTSync, and core layout reports.
2. Integrate the Live worker choice after the smaller-computer tests pass.
3. Measure the PipeASIO output and item identity branches separately.
4. Recommend Pro Audio for each device after its profile comparison passes.
5. Enable the Wine wait experiment after the suspend and loaded audio tests pass.
6. Start thread placement work after task and dependency tracing.

Each release change needs a repeated CPU saving and equal audio behaviour.
