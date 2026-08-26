# Live worker count and Linux process CPU report

Date: 20 August 2026

## Measured result

A 16-worker limit reduced the Live process's Linux CPU use by 36.77% in the
tested 64-frame empty Set. Voluntary context switches fell by 42.42%. Wine
reported 32 logical CPUs. Live had access to all 32 Linux CPUs.

These figures are not Live's Average or Current CPU meter.
[Ableton defines that meter](https://help.ableton.com/hc/en-us/articles/360019151379-Live-s-CPU-Meter)
as audio-processing time relative to the buffer duration. Waiting for worker
threads can therefore consume the deadline without consuming the same amount
of processor time. The launcher change writes Live's `-MaxAudioThreads`
option. It changes no PipeASIO or Wine audio-path code.

The result applies to the measured empty Set. Plug-ins and graphics add costs
that depend on the Set. Scheduling affects when audio threads receive processor
time.

The main comparison ran the whole Wine process with `SCHED_RR` at priority 10.
Its PipeASIO configuration also requested real-time callback scheduling. The
absolute result therefore includes both scheduler policies. Both runs used the
same Live version, audio settings, CPU access, and 30-second window. The CPU
share uses one logical CPU as 100%.

| Live setting | Worker threads | CPU use | Voluntary switches each second | Warning lines added | PipeWire ERR added |
|---|---:|---:|---:|---:|---:|
| Live default | 31 | 48.11% | 80,601 | 0 | 0 |
| 16-worker limit | 16 | 30.42% | 46,407 | 0 | 0 |

A voluntary context switch records a Live thread that enters a wait or yields
its processor.

The warning column counts PipeASIO log lines. The number on each line is the
total missed periods since PipeASIO started the current audio processing. The
line count and missed-period count measure different quantities. PipeWire ERR
counts graph errors after the Ableton node starts. A node represents one program
or device in the graph.

An earlier comparison disabled the launcher's process-wide real-time policy.
Its PipeASIO configuration still requested real-time callback scheduling. Each
lower worker count reduced process CPU and voluntary context switches. The
warning-line rate fell. The ERR rate fell.

| Live setting | Worker threads | CPU use | Voluntary switches each second | Warning lines each second | ERR added each second |
|---|---:|---:|---:|---:|---:|
| Live default | 31 | 40.61% | 77,293 | 0.167 | 10.33 |
| 16-worker limit | 16 | 31.22% | 43,623 | 0.100 | 5.06 |
| 8-worker limit | 8 | 18.22% | 23,130 | 0.033 | 2.53 |

16 matches the physical core count on the test host. 8 gave a further
reduction in the empty Set. The result does not select a safe value for a
demanding Set or a low-core host. The package provides a user-selected limit.

## Same-host project report

A tester later compared one Live Set on the same Linux Mint system and
hardware. Both runs used active NTSync. The tester identified the first build
as the latest `main` available during the test. The exact commit and worker
counts remain unrecorded.

These values come from Live's Average CPU meter. They measure deadline use,
while the controlled tables above measure Linux process CPU.

| Buffer frames | Earlier `main` | Physical-core policy |
|---:|---:|---:|
| 1024 | 7% to 8% | 7% to 8% |
| 512 | 8% to 9% | 8% to 9% |
| 256 | 9% to 10% | 8% to 9% |
| 128 | 11% to 12% | 9% to 10% |
| 64 | 15% to 16% | 10% to 11% |
| 32 | about 25% to 30% | about 15% to 16% |

The physical-core policy lowered the reported average most at 32 and 64
frames. The same Set still produced spikes above 100% at those sizes. Its
128-frame run produced overloads at a comparable or slightly higher rate.

An empty project stayed stable. A lighter project produced few spikes. The
tester associated the remaining spikes with one complex project's VST load.
The report supports the worker-coordination result, while deadline behaviour
remains specific to the Set and its plug-ins.

## Audio processing path

The PipeWire graph connects audio inputs, programs, and outputs. One graph
period processes one audio block through these connections.

1. PipeWire starts an audio block after a device or timer event.
2. PipeASIO receives the block on PipeWire's data-loop thread.
3. PipeASIO calls Live inside the Live process.
4. Live divides the block between its audio worker threads.
5. Wine sleeps and wakes those threads through Windows wait operations.
6. PipeASIO returns the completed audio to PipeWire.

PipeWire waits for graph events between blocks. PipeASIO runs its callback on
that data-loop thread. At 48 kHz, a 64-frame block gives Live 1.33 ms. This block
size creates 750 calls each second. Each call repeats worker wake requests,
waits, clock reads, and audio port work.

The package writes 256 frames into each new PipeASIO configuration. That value
creates 187.5 calls each second at 48 kHz. PipeASIO's built-in 1024-frame value
creates 46.875 calls each second. Use 128 or 256 frames when the extra latency
suits your work.

Live 12.4.3 created 31 workers when Wine reported 32 logical CPUs. Live created
30 workers when Wine reported 16 logical CPUs.

## Cause review and Wine CPU experiment

The review compared these possible causes:

| Possible cause | Evidence |
|---|---|
| Continuous graph work | PipeWire waited for graph events. PipeASIO ran its callback on that data-loop thread. |
| Different block sizes | PipeWire and Live both used 64 frames. |
| Wine thread waits | The Wine build contained NTSync support. The measurement did not dynamically prove that its wineserver opened `/dev/ntsync`. |
| Wine time read | PipeASIO made one Wine clock read per Live call. |
| Driver start and stop | The measured driver stayed active. |
| Live worker count | Each lower Live limit reduced CPU use. Each lower limit reduced thread waits. |

PipeWire waited for each graph event. During stable audio processing, equal
block sizes produced one Live call per graph period. Lower Live limits reduced
process CPU and voluntary context switches. This supports a Live worker-count
policy. It does not identify a costly native PipeASIO loop.

The launcher requests real-time priority 10 when the host grants real-time
rights. PipeASIO requests standard scheduling for its audio callback by default.

An experimental Wine patch changed the logical CPU count that Wine reported.
The patch also restricted Live to the same number of Linux CPUs.

| Wine CPU count | Linux CPUs available | Live workers | CPU share of one logical CPU | ERR added each second |
|---:|---:|---:|---:|---:|
| 32 | 32 | 31 | 40.61% | 10.33 |
| 16 | 16 | 30 | 47.21% | 18.66 |
| 12 | 12 | 22 | 38.28% | 61.80 |

The Wine patch changed worker creation and processor access together. The
16-CPU test created 30 workers and raised the error rate. The 12-CPU test
reduced workers and raised the error rate further.

The Live setting created 16 workers while Wine reported 32 CPUs. The package
uses that setting.

## Package option

The launcher accepts `auto`, `off`, or a value from one to 63. The default,
`auto`, counts the physical cores and logical processors available to the
launcher. It chooses the greater of the physical core count and half of Live's
own worker count, up to Live's own count. Before Live 12 starts, it applies a
value below Live's own count. The measured 16-core, 32-thread computer therefore
uses 16 of Live's 31 workers. The setting keeps at least half of Live's workers
on processors with fewer cores. `off` removes a value that the launcher set and
lets Live choose. Existing settings and user edits take priority. A number from
one to 63 requests a limit. The launcher uses the limit when it is below Live's
calculated count. At or above that count, Live uses its calculated count.

Existing worker settings, earlier launcher choices, and later file contents
take priority over implicit `auto`. An explicit `auto` recalculates an untouched
launcher-managed value. A fresh user profile receives the value before Live
starts. If Live transfers an older profile after the first launch, the next
cold launch can apply the policy when the profile has no existing choice.

Live reads the worker setting when it starts. PipeWire can change the buffer
size later. The launcher chooses from the physical core count and Live's own
count. Live uses that worker count for the whole session.

Start with the automatic value. Use audio tests before release. Compare 3 values
on a computer with simultaneous multithreading (SMT) and up to 15 physical
cores:

- the physical core count
- the automatic value
- Live's own value

Use a busy Set with independent audio chains. Test 32, 64 and 128 frames. Record
Live's deadline load, audible dropouts and Linux process CPU. Record voluntary
context switches. Record PipeWire xruns, which count missed audio periods.

The selected executable supplies the Live version. A Live 11 executable
preserves each Live 12 profile. The prefix registry selects the Live edition for
Ableton URLs and `.auz` licence files.

The script opens each preferences directory before a write. During directory
replacement, it continues to write to the opened directory. New files use mode
600. The script prepares each new file before it gives the file its final name.
The installer and its ownership record include the script.

## Sources and test records

The review used these versions:

- the work started from commit `ee464eb379dec6f4f7664b3860ccf6fd766f9ef0`.
- Ableton Live was version 12.4.3.
- PipeASIO was version 1.5.0 with 9 package patches.
- the PipeASIO build used Ubuntu's PipeWire 1.6.2 development package.
- the host PipeWire service was version 1.6.8.
- the reviewed PipeWire 1.6.2 tag was `95da54a482b68475958bbc3fa572a9c20df0df74`.
- the reviewed PipeWire 1.6.8 tag was `b741e0c74f5436f0c925f7741140db0efd32cf4e`.
- the Wine runtime included the project's patches through patch 0099.

The comparison runs used separate Wine prefix copies. A Wine prefix stores one
Windows installation. The 7 comparisons used 48 kHz and matching 64-frame
blocks. Each measurement window lasted 30.014 to 30.017 seconds. The PipeASIO
configuration requested real-time scheduling. That setting confounds any claim
about the absolute scheduler cost, even though it was matched within each
worker-count comparison.

The fresh-profile test used settings script SHA-256
`cf4d99335489f00e56f251051c43cabeba427c6a9ac301306f3367c95856daa3`.
It created 16 workers. Live saved `Preferences.cfg`. The final real-time run used
an earlier script with SHA-256
`49c5d24a28c381d442ec7c345f920b37fed166ee4f614f2e2c459bab2e8b1b53`.
The current script changes comments and messages from that earlier script. Its
SHA-256 is `839940472f6921ca4874b575415c86fc2f99aee15221648561b6aff233b32062`.

The current source passed 7 shell suites with 250 checks after the policy and
prose edits:

- the settings script passed 30 focused cases.
- the shortcut hold script passed 47 recovery and concurrency cases.
- the desktop integration test passed 6 cases.
- the release policy test passed 7 cases.
- the ThreadSanitizer policy test passed 2 cases.
- the installer lifecycle test passed 74 cases.
- the PipeASIO installer test passed 84 cases.
- the shell syntax, whitespace, and pointer safety checks passed.

The retained run directories start from the worktree root:

- the native run with standard scheduling is in `../.pipeasio-live-ab-cpu-evidence/n32-native-20260820T050957`.
- the 16-worker run with standard scheduling is in `../.pipeasio-live-ab-cpu-evidence/n32-maxaudio16-20260820T051432b`.
- the 8-worker run with standard scheduling is in `../.pipeasio-live-ab-cpu-evidence/n32-maxaudio8-20260820T051949`.
- the 16-CPU Wine run is in `../.pipeasio-live-ab-cpu-evidence/n16-exact-20260820T050418`.
- the 12-CPU Wine run is in `../.pipeasio-live-ab-cpu-evidence/n12-exact-20260820T050640`.
- the real-time native run is in `../.pipeasio-live-ab-cpu-evidence/rtdefault-native32-20260820T061633`.
- the 16-worker run with real-time scheduling is in `../.pipeasio-live-ab-cpu-evidence/rtdefault-optin-max16-20260820T062946`.
- the fresh-profile run is in `../.pipeasio-live-ab-cpu-evidence/first-launch-finalcf4d-20260820T055435`.

Future release decisions require these tests:

- compare the physical-core value, automatic value and Live's calculated value
  on an SMT computer with up to 15 physical cores.
- use 24 to 32 independent audio chains in each Set.
- compare standard and real-time scheduling for both Live and PipeASIO.
- measure the same Set at 32, 64 and 128 frames. Keep 256 frames as the CPU
  reference with higher latency.
- close Live and run `scripts/check-ntsync.sh` to prove which wait driver the
  tested runtime uses.
- record monotonic wall time and callback-thread CPU time for PipeASIO callback
  entry, the call into Live, and output queuing. Publish only aggregate
  p50/p95/p99/max values away from the audio thread.
- prototype AVRT/MMCSS mapping for Live's `Pro Audio` threads before changing
  the process-wide scheduler policy.
- record each audio stall with its missed-period count.
- measure CPU use while PipeASIO starts and stops with its graph node active.
- measure the Wine clock read's CPU cost.
- check MIDI timing during the clock-read comparison.
