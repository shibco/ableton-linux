# CPU optimisation review

Date: 26 August 2026

Integration record: PRs 267 to 279 after merge commit `d69b4f0`

## Decision

Main now uses the automatic Live worker rule. The rule produced the largest measured CPU saving on the review computer.

The review computer used 16 workers in place of Live's 31 workers. Linux process CPU fell by 36.77% at 64 frames. Voluntary context switches fell by 42.42%.

The result applies to one computer, one empty Set and one matched scheduler setup. Loaded Set tests on smaller computers remain the gate for a broader claim.

Main also includes the benchmark suite, CPU layout report and NTSync proof. The tools make each later result easier to reproduce.

Several tools and trials require an explicit choice:

- use `PIPEASIO_TELEMETRY=on` to start callback timing
- run the Pro Audio tool to compare one device profile and restore the original profile
- use `WINE_APC_FASTPATH=1` to select the Wine NTSync wait trial

The regular Wine wait remains the release default. Linux continues to choose CPU placement.

PipeASIO patches 0013 and 0016 run in the regular build. Patch 0013 reduces repeated output work. Patch 0016 separates buffer requests by PipeWire node ID.

## Integration record

The following table records the final state on 26 August 2026.

| PR | Result | Runtime selection |
|---|---|---|
| [267](https://github.com/shibco/ableton-linux/pull/267) | Wine restores retained dialog content after an X11 expose event. | Regular Wine patch 0107 applies. |
| [268](https://github.com/shibco/ableton-linux/pull/268) | The launcher adds Link service, socket and recovery safeguards. | Regular launcher behaviour applies. |
| [269](https://github.com/shibco/ableton-linux/pull/269) | PipeASIO completes a delivered block through the direct output path. | Regular PipeASIO patch 0013 applies. |
| [270](https://github.com/shibco/ableton-linux/pull/270) | The branch updates this research review after integration. | The documentation review remains open. |
| [271](https://github.com/shibco/ableton-linux/pull/271) | The benchmark suite records five Live Sets and produces comparable reports. | The user starts each benchmark. |
| [272](https://github.com/shibco/ableton-linux/pull/272) | The audio report records available processors, physical cores and Linux CPU classes. | The report uses read operations. |
| [273](https://github.com/shibco/ableton-linux/pull/273) | PipeASIO records callback phase timing through a separate report worker. | `PIPEASIO_TELEMETRY=on` starts the report. |
| [274](https://github.com/shibco/ableton-linux/pull/274) | PipeASIO uses its bound node ID to identify its own buffer request. | Regular PipeASIO patch 0016 applies. |
| [275](https://github.com/shibco/ableton-linux/pull/275) | The launcher and report record build, device and running wineserver NTSync evidence. | The checker requires device evidence by default. |
| [276](https://github.com/shibco/ableton-linux/pull/276) | The Pro Audio tool runs a matched profile comparison and restores the original profile. | The user starts each comparison. |
| [277](https://github.com/shibco/ableton-linux/pull/277) | Wine includes one bounded NTSync alertable wait trial. | The regular Wine wait remains the default. |
| [278](https://github.com/shibco/ableton-linux/pull/278) | The launcher chooses a reliable automatic Live worker count. | `ABLETON_MAX_AUDIO_THREADS=auto` is the default. |
| [279](https://github.com/shibco/ableton-linux/pull/279) | The installer preserves launcher and adjacent backup prestate across updates and uninstall. | Regular installer behaviour applies. |

PRs 267 to 269 and 271 to 279 are merged. PR 270 contains this final documentation review.

## Patch order

The final manifest contains 110 entries.

| Group | Count | Final entry |
|---|---:|---|
| Regular Wine | 95 | `0107-win32u-restore-offscreen-client-content-on-expose.patch` |
| Wine performance trial | 1 | `performance/0001-ntdll-alertable-sleep-fast-path.patch` |
| PipeASIO | 14 | `pipeasio/0016-classify-pipeasio-forcers-by-bound-node-id.patch` |

The regular Wine series ends at patch 0107. The build audit declares every sequence gap.

The performance series follows the regular Wine series. Both build routes apply its one patch. Wine selects the trial at run time.

PipeASIO patch 0013 changes output publication. Patches 0014 and 0015 add timing and report output. Patch 0016 adds node ID arbitration.

The [Wine patch base](../patches/BASE.txt) records the source base and patch rules. The [series manifest](../patches/SERIES.sha256) records every patch hash.

## Research sources

The review used fixed source revisions.

| Project | Version | Revision or source |
|---|---|---|
| ableton-linux research base | Release 2026.08.26.1 | `54933547bef023d937e3b5cb23d438afab7905bc` |
| Wine patch base | Wine 11.13 branch | `5c23dd1c` |
| PipeASIO | 1.5.0 | Package source plus the 14 manifest patches |
| PipeWire | 1.6.8 | `b741e0c74f5436f0c925f7741140db0efd32cf4e` |
| WirePlumber | 0.5.15 | `bc4fa8f5e84806f86530c97cb35283eecc3ec081` |
| Linux | 7.1.8 | `25c76bea853d0db65b51fb4697a47cbfd9e35e76` |

The table uses durable source identities in place of temporary working paths.

## Review computer

The review computer had these relevant properties:

- an AMD Ryzen AI MAX+ 395 processor
- 16 physical cores and 32 hardware threads
- Linux 7.1.8 with dynamic pre-emption
- PipeWire 1.6.8 and WirePlumber 0.5.15
- Wine 11.13 package version 2026.08.24.1
- Live 12.4.3
- PipeASIO with 2 inputs, 2 outputs, 48 kHz and 256 frames

Each processor reported a Linux capacity value of 1024. AMD preferred-core ranks ranged from 166 to 236.

Firmware can change those ranks during use. Linux receives each rank change and uses it for processor selection.

The saved PipeASIO file used `realtime = 1`. Each future report records the process and callback scheduler settings.

## Measured Live worker result

The main matched pair used 64 frames. Both runs used `SCHED_RR` priority 10 and PipeASIO real-time callback scheduling.

| Live setting | Workers | Linux process CPU | Voluntary switches each second |
|---|---:|---:|---:|
| Live calculation | 31 | 48.11% | 80,601 |
| Worker rule | 16 | 30.42% | 46,407 |

Linux process CPU fell by 36.77%. Voluntary context switches fell by 42.42%.

Both runs used the same Live version, CPU set, audio settings and 30-second period. Their logs recorded equal PipeASIO warning and PipeWire error counts.

Linux process CPU measures processor time. [Ableton's CPU meter](https://help.ableton.com/hc/en-us/articles/360019151379-Live-s-CPU-Meter) measures audio processing time against buffer playback time.

An earlier series used Linux's standard process scheduler. It kept PipeASIO real-time callback scheduling.

| Workers | Linux process CPU | Voluntary switches each second | PipeWire errors each second |
|---:|---:|---:|---:|
| 31 | 40.61% | 77,293 | 10.33 |
| 16 | 31.22% | 43,623 | 5.06 |
| 8 | 18.22% | 23,130 | 2.53 |

Each lower worker choice reduced process CPU and context switches. The 8-worker result requires a busy Set deadline test.

A later same-host report favoured fewer workers at 32 and 64 frames. The 128-frame result had a similar or higher overload rate.

That later report recorded meter ranges. A future run records the exact commit and worker count.

## Automatic worker rule

`ABLETON_MAX_AUDIO_THREADS=auto` is the package default for Live 12.

The launcher counts the physical cores and logical processors available to its process. It also calculates Live's own worker count.

The rule chooses the larger of these values:

- use one worker for each available physical core
- use half of Live's calculated workers, rounded up

The rule caps the result at Live's calculated count. Large positive physical-core counts use the same cap.

The review computer selects 16 workers from Live's calculated count of 31.

A user setting has priority over the automatic choice. An explicit `auto` recalculates an unchanged launcher-managed value.

A number from 1 to 63 requests a limit. `off` removes the launcher-managed value and selects Live's calculation.

Live reads the value during a cold launch. The value applies for the complete Live session.

Linux keeps full control of processor placement.

The [worker evidence report](FINDINGS-PIPEASIO-CPU-2026-08-20.md) gives the full measurements and policy details.

## Launch settings

Each launch setting changes one part of the test. Use matched pairs for each setting.

| Setting | Current use | Test rule |
|---|---|---|
| `ABLETON_MAX_AUDIO_THREADS=auto` | The launcher chooses Live's worker count. | Compare `auto` with `off` on busy Sets. |
| `ABLETON_RT` | The launcher requests round-robin scheduling when the host grants it. | Record the active policy and priority. |
| `ABLETON_POWER` | The launcher requests the performance power profile. | Record the active profile and frequency policy. |
| `PIPEASIO_REALTIME=on` | PipeASIO requests real-time callback scheduling. | Compare it with standard callback scheduling. |
| `ABLETON_DCOMP=off` | Wine uses the display compatibility path. | Reserve it for display diagnosis. |
| `WINE_D3D_FORCE_GPU_RENDERING=1` | Wine supplies the configured substitute GPU identity. | Use it for the identified GPU case. |
| `PIPEASIO_ALLOW_QUANTUM_MISMATCH=on` | PipeASIO continues through a buffer-size difference. | Reserve it for timing diagnosis. |
| `PIPEASIO_FOLLOW_DEVICE_CLOCK=on` | PipeASIO follows the audio device clock. | Use it for device-driven clocks. |
| `WINE_APC_FASTPATH=1` | Wine selects the NTSync alertable wait trial. | Use paired trial and regular runs. |
| `snd_usb_audio.lowlatency` | Linux selects the USB low-latency path. | Record the active kernel value. |

An upstream 64-frame test associated PipeASIO real-time scheduling with a higher missed-period count. Treat the scheduler choice as a separate experiment.

## Benchmark suite

The benchmark suite runs these Live Sets in order:

1. Run `Benchmark_Zero` with the control device closed.
2. Run `Benchmark_Empty` with the control device active.
3. Run `Benchmark_Inbuilts` with Live instruments and effects.
4. Run `Benchmark_Max4Live` with Live and Max for Live devices.
5. Run `Benchmark_VSTs` with Dexed and Nils' K1v.

Each Set has a 30-second measurement period. Set loading and stabilisation happen before that period.

The report records these facts:

- system, processor, memory, kernel and audio hardware
- PipeWire, WirePlumber, device, route, sample rate and buffer details
- Wine runtime, Wine prefix, Live version, worker count and plug-in hashes
- host, process and thread CPU
- context switches and processor movement
- hardware and software interrupts
- PipeWire settings, errors and missed audio deadlines
- Live deadline measurements and listener crackle reports
- power profile and processor frequency policy

Use five matched pairs for each change. Change one subject in each pair.

Accept a pair after these conditions pass:

- each Set has a complete 30-second period
- each collector covers the measurement period
- runtime, files, routes and settings match
- sample rate and buffer size stay constant
- the matching wineserver has an active NTSync file descriptor
- the listener reports continuous audio
- error, missed-deadline and overload counts match the control range
- loaded Sets show a repeated CPU saving beyond run variation

The [benchmark guide](../bench/README.md) gives commands, report fields and comparison rules.

## CPU layout evidence

The audio report records the processor set available to its own process. It records these facts:

- available, online, present and possible processor sets
- physical package, core and sibling groups
- Linux capacity and core type
- maximum and current frequency
- CPPC and `amd_pstate` preference values
- Wine and kernel CPU class inputs

Wine 11 reads the present and online sets. Its current Linux enumeration covers processor indices below 64.

The review computer reported one capacity value across all processors. Its AMD preference ranks changed independently from CPU class evidence.

Linux therefore controls processor placement on the review computer. A future placement rule requires class evidence from several processor families.

The [CPU layout report](ABLETON-WINE-HYBRID-CPU-TOPOLOGY.md) defines the fields and placement test gate.

## NTSync evidence

A useful NTSync result records three facts:

- the Wine build includes NTSync support
- the host provides `/dev/ntsync`
- the matching wineserver opens `/dev/ntsync` while Live runs

`audio-report.sh` links each wineserver to its exact Wine prefix. It then counts that process's open NTSync file descriptors.

`check-ntsync.sh` requires host device evidence by default. Pending device evidence returns status 3 before Wine starts.

Set `ABLETON_REQUIRE_NTSYNC=off` for a planned regular-route test. The report then identifies Wine's regular route.

The checker also runs 27 timing and wake tests through `ntsyncprobe.exe`.

The [NTSync proof guide](MOONSHOT-CPU-NTSYNC-PROOF.md) defines the evidence for each benchmark.

## PipeASIO output work

PipeASIO patch 0013 completes a delivered audio block through the direct output path.

The earlier fallback action used one acquire load and one acquire-release exchange. A standalone measurement recorded 5.48 ns per action.

At 48 kHz and 64 frames, each output runs 750 graph cycles each second. Two outputs at 1024 frames run about 94 actions each second.

The recovery path publishes one silent block at the current PipeWire buffer size.

The expected CPU saving is small. A loaded paired run controls any performance claim.

The [PipeASIO CPU report](FINDINGS-PIPEASIO-CPU-2026-08-20.md#repeated-output-work) gives the calculation and test scope.

## PipeASIO timing report

PipeASIO patches 0014 and 0015 add an explicit callback timing mode.

Set `PIPEASIO_TELEMETRY=on` for one cause-finding run. The regular path follows the original callback timing path.

The report measures three phases:

- PipeASIO work before Live receives the buffer
- time inside Live's buffer callback
- PipeASIO work after Live returns the buffer

Each phase reports elapsed time and callback thread CPU time. The report includes `p50`, `p95`, `p99` and maximum values.

Each measured callback performs eight clock reads. Four reads use the thread CPU clock. Four reads use the monotonic clock.

The review host measured 137.5 ns for each thread CPU read. It measured 12.1 ns for each monotonic read.

The measured callback overhead is about 598 ns. Use the regular mode for CPU result runs.

A separate worker copies and summarises timing samples once each second. Pipes and terminals use immediate report writes.

The [callback timing guide](MOONSHOT-CPU-PIPEASIO-TELEMETRY.md) gives the safety rules and test plan.

## PipeWire setting ownership

PipeWire can receive a graph-wide buffer size and a buffer request from an active node. The graph-wide value has priority.

PipeWire otherwise uses the most recent active node request.

PipeASIO patch 0016 uses its bound PipeWire node ID to recognise its own request. The ID separates 2 Live instances with the same name.

The node signature uses the Audio class, Duplex category and DSP factory. It accepts marker value `1` when PipeWire supplies it.

Test 2 Live instances at different buffer sizes. Add a separate JACK client during the same test.

The [PipeASIO 1.5 report](PIPEASIO-15.md) gives the buffer ownership and recovery rules.

## Pro Audio profile comparison

Pro Audio is a PipeWire device profile. It can change routes, channels, active devices and hardware interrupt timing.

The tool compares one device at a time. It uses this sequence:

1. Record the device, routes, links, settings and current profile.
2. Confirm that Live, the Wine prefix and the device are idle.
3. Run the benchmark with the current profile.
4. Select the comparison profile for the same device.
5. Run the same benchmark again.
6. Restore the original profile.
7. Compare the final device state with the recorded state.

The tool records a recovery command before each profile change. It restores the original profile after command errors and caught signals.

Compare total host, Wine, PipeWire and interrupt CPU. A lower Live value can accompany higher work in another process.

Run five matched pairs at 32, 64 and 128 frames. Apply the result to the tested device and configuration.

The connected target USB interface remains the hardware gate.

The [Pro Audio comparison guide](PIPEWIRE-PRO-AUDIO-AB.md) gives the commands and recovery steps.

## Wine wait trial

The release path uses Wine's regular alertable wait. `WINE_APC_FASTPATH=1` selects the NTSync alert-event trial.

The trial moves zero-handle alertable delays from wineserver to the calling thread's NTSync alert event.

Wine selects the trial after its NTSync device and alert event are ready. Every other setup result uses the regular route.

A partial relative wait measures elapsed time with `CLOCK_MONOTONIC`. The remaining wait uses the same clock as the NTSync deadline.

Wine's regular route uses `CLOCK_BOOTTIME`. That clock advances during host suspend. The monotonic clock pauses during host suspend.

Microsoft documents that Windows 8 and newer pause relative wait timeouts during low-power states. The official guides cover [single-object waits](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobjectex) and [multiple-object waits](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitformultipleobjectsex).

The trial passed 45 probe checks in the trial and regular routes. The observer identified the NTSync request and the injected error fallback.

The exact patch compiled for 32-bit and 64-bit Wine targets after regular Wine patch 0107.

Complete the host suspend matrix and loaded Set pairs before any release-default change.

The [Wine wait trial guide](MOONSHOT-CPU-WINE-BOUNDED-FASTPATHS.md) gives the probe, clock and release tests.

## Reserved Wine ideas

The review reserves four broader Wine ideas for separate tests.

| Idea | Required evidence |
|---|---|
| Same-process alert queue | Test APC order, access, process exit and handle reuse. |
| Window hook cache | Test self-removal and cross-thread hook changes. |
| Message queue cache | Test nested sends, callbacks, timeouts and every required wake. |
| Window update cache | Test visible-window paint, erase and cross-thread changes. |

The current performance series contains the bounded wait trial as patch 0001.

## Verification record

The integrated review recorded these results:

| Area | Recorded result |
|---|---|
| Benchmark report | 49 Python tests and five shell tests passed. |
| Live worker rule | 32 setting and worker tests passed. |
| CPU layout report | Seven topology tests passed. |
| NTSync policy | Five checker policy tests passed. |
| Pro Audio tool | 23 policy and recovery tests passed. |
| PipeASIO stack | All 14 patches replayed, and all 11 CTest cases passed. |
| PipeASIO telemetry | 8,217 focused timing and concurrency checks passed. |
| Wine wait trial | Both target architectures compiled, and each 45-case probe run passed. |
| Package policy | All 30 Nix checks and the release policy checks passed. |
| Installer integration | 82 lifecycle checks and 89 PipeASIO installer checks passed. |
| GitHub build for PR 279 | The full build and integration workflow passed. |

The final documentation pass checks the current manifest, local links, Markdown layout and relevant CPU test suites.

## Hardware test gates

1. Test the automatic worker choices on busy Sets with 4, 6 and 8 physical cores.
2. Run five matched pairs at 32, 64 and 128 frames.
3. Measure PipeASIO patch 0013 with 2 output channels and a larger channel count.
4. Compare regular callbacks with telemetry at 32, 64, 128 and 256 frames.
5. Run 2 Live instances with different buffer sizes and one separate JACK client.
6. Compare Pro Audio with the current profile on the target USB interface.
7. Map Linux and Windows CPU classes on 2 Intel hybrid generations.
8. Add one tiered processor and one symmetric processor as controls.
9. Run the Wine wait trial through suspend, resume and loaded Set tests.
10. Attach the running NTSync proof and a listening result to each accepted benchmark.

## Release controls

Use these controls for release and test runs.

| Subject | Release use | Test use |
|---|---|---|
| Live workers | The automatic rule selects a reversible worker count. | `ABLETON_MAX_AUDIO_THREADS=off` selects Live's calculation. |
| PipeASIO output | Patch 0013 runs in the regular build. | Measure the loaded output paths. |
| PipeASIO timing | The regular callback path runs. | `PIPEASIO_TELEMETRY=on` starts timing. |
| PipeWire ownership | Patch 0016 identifies the bound PipeASIO node. | Run the multi-instance gate. |
| NTSync proof | The launcher requires host device evidence. | `ABLETON_REQUIRE_NTSYNC=off` selects a regular-route test. |
| Pro Audio | The current device profile stays selected. | Run the comparison tool for one device. |
| Wine wait | The regular wineserver route runs. | `WINE_APC_FASTPATH=1` selects the trial. |
| CPU placement | Linux selects processors. | Use the topology report for manual experiments. |

A release claim requires repeated CPU improvement and equal audio behaviour on the tested hardware.
