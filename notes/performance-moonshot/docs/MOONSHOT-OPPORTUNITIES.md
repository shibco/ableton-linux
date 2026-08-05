# Moonshot opportunities: ranked performance and stability work

Use this document to pick the next performance or stability task for the
ableton-wine stack, see what it costs, and see how to prove it worked. It
merges the eight performance-moonshot research documents into one ranked
list. Duplicates are folded into a single item with every source cited.

Scope: Ableton Live 12 under the `wine-d2d1-nspa-11.13` fork, PipeASIO on
PipeWire, ntsync for synchronization. Citations are relative paths from the
repository root. Anything marked "Unverified:" is a claim the research did
not confirm.

## Terms

- **xrun**: an audio buffer under- or overrun; one missed processing cycle,
  heard as a click or dropout.
- **DSP load**: Live's own audio-engine meter. It compares buffer processing
  time with buffer playback time. Over 100 percent means a dropout.
- **wineserver**: Wine's single-threaded userspace coordinator process.
  Classic NT synchronization waits cross a socket to it twice per call.
- **ntsync**: a Linux kernel driver (6.14+) that implements Windows NT
  synchronization primitives in the kernel, so waits skip wineserver.
- **APC**: asynchronous procedure call, a callback Windows queues onto a
  specific thread. Live's APC-coalescing thread burns 30-40% of one core at
  idle; ntsync does not cover alertable waits or APC delivery.
- **quantum**: PipeWire's buffer size in frames per processing cycle. 256
  frames at 48 kHz is about 5.3 ms.
- **RTL**: round-trip latency; the time for a signal to enter the interface,
  pass through software, and leave again.
- **SCHED_RR / SCHED_FIFO**: Linux realtime scheduling policies. The launcher
  runs the whole Wine process tree under SCHED_RR 10; PipeASIO requests
  SCHED_FIFO 15 for its data-loop thread.
- **LTO / ThinLTO**: link-time optimization; cross-module inlining at link
  time. **PGO**: profile-guided optimization; recompiling with branch data
  from a recorded run. **THP**: transparent huge pages; 2 MB memory pages
  that cut address-translation misses.
- **PI**: priority inheritance; temporarily raising a lock holder's priority
  to stop priority inversion.

## Source documents

| Key | Path |
|---|---|
| TECH | notes/performance-moonshot/PROJECT-TECHNOLOGIES.md |
| LIVE | notes/performance-moonshot/ABLETON-LIVE-TECHNICAL.md |
| SYNC | notes/performance-moonshot/PROTON-SYNC-AND-CPU.md |
| GFX | notes/performance-moonshot/PROTON-GRAPHICS-AND-RUNTIME.md |
| PATCHMAP | notes/performance-moonshot/OWN-FORK-PATCH-MAP.md |
| BUILD | notes/performance-moonshot/OWN-FORK-BUILD-AND-RUNTIME.md |
| FORKS | notes/performance-moonshot/OTHER-FORKS-SURVEY.md |
| AUDIO | notes/performance-moonshot/AUDIO-LATENCY-ECOSYSTEM.md |

## Try first

High impact, low-to-medium effort, measurable with the existing bench and
probe tooling. Ordered by impact per unit of effort; the top three are
T1-T3.

| # | Opportunity | Impact | Effort | Sources |
|---|---|---|---|---|
| T1 | **Check `/dev/ntsync` at launch and close the host gap.** Warn loudly when the device is missing; detect a kernel >= 6.14 with the module unloaded and ship a `modprobe.d`/udev drop-in or exact load instructions via the setup scripts. Today the build gate guarantees the binary supports ntsync but nothing checks the host. Users without the device silently lose 4-50x sync throughput and burn ~45% of a core in wineserver at idle. | High | Low | SYNC, BUILD, TECH |
| T2 | **Run the deferred scheduling A/B and narrow realtime scope.** Execute the written 4-CPU `taskset` protocol (notes/ABLETON-WINE-RT-SCHEDULING.md). Arms: default RR 10, `ABLETON_RT=off`, wineserver `chrt -f` boost, RT narrowed to audio threads. Audit whether Wine maps Live's Windows thread priorities to Linux scheduling at all (Unverified), and check whether Proton 9.0-4's new-thread priority fix has an upstream equivalent. Targets the recorded priority-inversion shape: Live's RT threads make synchronous calls into a `SCHED_OTHER` wineserver. | High on low-core machines, medium elsewhere | Low (protocol and harness exist) | LIVE, SYNC, BUILD, AUDIO, FORKS |
| T3 | **Automate the bench harness and commit the reference set.** Capture `pw-top -b` ERR deltas and `pw-metadata` rate/quantum inside `scripts/bench-run.sh`; add startup-time and idle-CPU (APC-thread) columns; commit the reference set under `bench/`. Today the headline xrun metric is hand-entered and the "committed reference set" the protocol requires is not in the repo. Every other item on this page is judged by this harness. | High (enables all other items) | Low-medium | BUILD, TECH |
| T4 | **Buffer, quantum, and rate pass on PipeWire.** Measure and lower the fixed 256-frame default per interface class (USB floor ~512, HDA 128-256), with a documented per-interface recommendation. Verify quantum matching: it needs PipeWire 1.6+ but the runtime accepts 0.3.56, so older hosts get the 1024 default with no warning; warn or ship a `clock.force-quantum` fallback at install. Lock the graph rate to the hardware rate so PipeWire never resamples Live. Close the PipeASIO validation gaps: sample-rate change while open, single-rate hardware, controlled xrun comparisons. | High (halves or quarters buffer latency; a mismatched quantum is a direct xrun source) | Low-medium | AUDIO, BUILD, LIVE |
| T5 | **Compiler-flags comparison builds.** Adopt Proton's proven baseline (`-O2 -fwrapv -fno-strict-aliasing -march=nocona -mtune=core-avx2 -mfpmath=sse`); the build passes no CFLAGS at all today (scripts/container-build.sh:53-56). Then A/B `-O3` and `-march=x86-64-v2` (v2 is near-universal; ship v3/AVX2 as an opt-in variant). Kron4ek ships `-O3 -msse3`; CachyOS ships v3/v4+LTO. Optionally a newer gcc inside the same jammy image (keeps the glibc 2.35 floor). Most CPU in a session burns inside Live.exe and plugins, not Wine DLLs, so expect small gains; measure, do not assume. Gate each variant on the relocation gate, build audit, and a bench pair. | Low-medium | Low | GFX, BUILD, FORKS, TECH |
| T6 | **Audit hybrid-core thread placement and publish affinity guidance.** Check which cores Live, PipeASIO, PipeWire, and wineserver threads land on. The scsynth benchmark measured a 40-50% CPU swing from E-core versus P-core placement, erased by pinning. Publish `taskset`/cpuset guidance for Intel P/E and Ryzen X3D hosts; optional launcher pinning. The launcher already honors cgroup cpusets (scripts/ableton-live:85-97). | High on affected CPUs | Low for guidance, medium for pinning | AUDIO, SYNC, BUILD |

## Worth a spike

Promising but uncertain, or medium effort. Unranked; pick by available
hardware and time.

| # | Opportunity | Impact | Effort | Sources |
|---|---|---|---|---|
| S1 | **Land the `WINE_CPU_TOPOLOGY` consumer patch.** The launcher computes and exports an 8-CPU cap but marks it inert; the ntdll/wineserver consumer is the missing half. Port Proton's patch. Fixes worker-pool oversizing on >8-core hosts and enables V-Cache/P-core pinning. | Medium on >8-core hosts | Medium | SYNC, BUILD, TECH |
| S2 | **A/B DXVK for Live's D3D11 UI, wined3d-Vulkan first.** Prefix-level experiment, no rebuild; the vendored winetricks carries dxvk verbs. Risks are concrete: patches 0055/0058/0059 become dead code under Vulkan swapchains, and Live's device-name gate (patches 0057/0061) may reject DXVK's adapter names (Unverified: whether the check passes on every supported GPU family). Abandon if the gate greys out or the WebView2 panes regress. | Medium if it works, likely low (2D UI) | Medium | GFX |
| S3 | **Extend the direct GL present path to `WS_POPUP` and `WS_CHILD` windows.** Kills the remaining ~650 MB/s-class copy traffic for Settings, the auth dialog, and embedded plugin editors. Must solve the black-before-first-input popup issue. | Medium | Medium | LIVE |
| S4 | **Implement a real `dxgi_output_WaitForVBlank`.** The current semi-stub (dlls/dxgi/output.c:371) only calls `Sleep(16)`; it paces all Max for Live device redraw (meters, jsui). Unverified: whether it costs smoothness or CPU in normal use. | Medium | Medium | LIVE |
| S5 | **Extend `scripts/setup-realtime.sh` into a full host-audio audit.** Governor, `threadirqs`/rtirq, RTTIME limits and rtkit presence (GNOME 45+ forces rtkit, whose 200 ms RTTIME cap throttles audio threads), swappiness, PipeWire `rt.prio`. Automate IRQ affinity instead of advising it; fail the realtime check when `threadirqs` is missing rather than printing once at setup. | Medium | Low-medium | AUDIO, BUILD |
| S6 | **ThinLTO on the clang PE side, after T5 lands.** clang 21 + lld is already the PE toolchain, so ThinLTO needs no new dependency. Unverified: whether the Wine PE build survives `-flto=thin`; winebuild-generated assembly and `.spec` handling are the usual failure points. Gate on the relocation gate plus a bench pair. Valve avoids LTO, so there is no upstream proof. | Medium-high | Medium | BUILD, GFX |
| S7 | **Add a round-trip latency probe.** Loopback cable plus a `jack_iodelay`-style measurement through PipeWire, packaged for the tester kit. Turns "feels faster" into a number that feeds `bench/results.csv`. No RTL tooling exists in the repo. | Medium | Medium | AUDIO, TECH |
| S8 | **THP experiment on the audio workload.** Compare xruns and `perf` TLB-miss rates with THP `madvise` versus `never` on a large session; Live holds multi-GB sample buffers in ordinary pages. If it helps, ship a launcher-side wrapper, not a system-wide change. No upstream implementation exists to copy. Unverified benefit. | Low-medium | Low | GFX |
| S9 | **Verify the upstream non-ntsync in-process fallback.** Unverified: community guides claim Wine >= 10.15 has an eventfd in-process fallback when `/dev/ntsync` is absent; this repo's header-less fallback builds paid full wineserver round trips, but that build may have lacked the configure gate. If the fallback is real and not header-gated, users on kernels < 6.14 get a free win. | Medium | Low | SYNC |
| S10 | **Test and document the external-plugin-host workflow.** Carla over PipeWire is the documented-but-untested way to isolate unstable Linux-native plugins from Live's audio thread. Live hosts plugins in-process, so a plugin fault is a Live fault; no Wine tuning changes that. | Medium (stability) | Medium | AUDIO, LIVE |
| S11 | **Benchmark Wine file I/O for sample streaming.** Disk overloads cause dropouts on the real-time path; no repo measurement exists of Wine file-I/O latency versus Windows. | Unknown, potentially medium | Low-medium | LIVE |
| S12 | **Resolve the tempo-ramp export difference (issue 101).** Exports render ~0.08% shorter than on Windows; leading hypothesis is a Live-version mismatch, unproven. The export test needs no Windows machine. | Low-medium | Low | LIVE, PATCHMAP |
| S13 | **Measure and document Link Audio (Live 12.4).** Timed network audio joins the audio clock domain; it needs the same xrun-style measurement as PipeASIO before anyone claims support. Documentation arm only; the implementation arm is M4. | Medium | Low | LIVE |
| S14 | **Make wineserver persistent across launches (`wineserver -p`).** Cuts cold-start time and the per-launch `wineboot`. No steady-state audio effect. | Low-medium (launch feel) | Low | BUILD |
| S15 | **Evaluate a PREEMPT_RT or lowlatency kernel as a supported configuration.** PREEMPT_RT is mainline since 6.12. It buys worst-case scheduling jitter, not average speed, and has measurable scheduling overheads. Recommend only with measured xrun deltas, not blanket advice. | Medium | Medium | AUDIO, BUILD |
| S16 | **Evaluate proton-cachyos' `winepipewire.drv`** as an mmdevapi-level PipeWire reference for the non-ASIO paths (WebView2 pane audio, plugin preview sound). | Low | Medium | FORKS |
| S17 | **Audit Wine font APIs for Windows-lax behaviour Max relies on.** The vendored-font fix removed one M4L hang trigger, not the flaw; Wine's honesty about font failure turns Windows-latent Max defects into Live hangs. | Medium (prevents the next M4L hang class) | Medium | LIVE |
| S18 | **Revisit the WebView2 SwiftShader flags once dcomp compositing improves.** CPU rendering of every visible Learn pane is a standing UI-thread cost, accepted for correctness. Low effort to re-test; the fix depends on upstream dcomp work. | Medium (UI) | Low to re-test | BUILD |
| S19 | **Run the missing WineASIO-versus-PipeASIO xrun comparison** under identical load. Confirms a decision already made; closes the last evidence gap from the 2026-07-17 evaluation. | Low | Medium | AUDIO, LIVE |
| S20 | **Identify and implement the `wmvcore` export Live 11 calls.** Live 11 is experimental, so this is low priority. | Low | Medium | LIVE |
| S21 | **Standing practices.** Keep every new performance patch behind an environment toggle (the Proton/GE pattern; this repo's `WINE_DISABLE_GL_PRESENT` is the precedent). Track Valve Proton experimental, proton-cachyos, Proton-EM, and vkd3d-proton present timing as a watch list, not as patch sources. | Low | Low | FORKS, GFX |

## Moonshots

High effort or high risk, potentially large payoff.

| # | Opportunity | Impact | Effort | Sources |
|---|---|---|---|---|
| M1 | **APC / alertable-wait fast path.** Deliver same-process user APCs through ntsync's alert event instead of wineserver round trips. Must preserve FIFO ordering, special APCs, and I/O completion ordering. Step zero: read wine-staging's `ntdll-APC_Performance` set before writing anything (its mechanism is Unverified; the definition file did not fetch). Needs a new `apcprobe`. This is the largest measured CPU sink outside the driver: 30-40% of one core at idle, plus per-APC wineserver serialization as the playback-fault hypothesis. ntsync covers handle waits only; alertable sleeps and APC delivery still cross wineserver. The sync/threading area is otherwise untouched by the patch series. | High | High | LIVE, SYNC, FORKS, PATCHMAP, BUILD |
| M2 | **Port Wine-NSPA's portable client-side work.** The portable subset: message rings with empty-poll caching, local events/timers/sections, shared-state readers (zero-time waits without a server round trip), TEB hot-state caching, cacheline-shaped userspace sync, AVX2 string loops, `mlockall`/hugepage heap backing, and PI for `CRITICAL_SECTION` (targets the wineserver priority inversion directly). Unverified: whether full 11.x sources or patch files are public; the repo publishes design and validation documents, so verify before planning ports. The kernel-dependent items (IPC overlay, PI ntsync) assume the custom Linux-NSPA kernel and are out of scope. Port precedent exists: patches 0002-0003 came from nine7nine's tree. | High | High | FORKS, SYNC, PATCHMAP |
| M3 | **PGO for the PE build.** Needs a scripted, replayable Live workload to profile inside the container; clang PGO on Wine PE is unexplored here. No `-fprofile` flag exists anywhere in the repo, and Valve ships no PGO. | Medium | High | BUILD, GFX |
| M4 | **Implement Link Audio (Live 12.4).** Multichannel timed audio over LAN arrives as an input in Live and joins the audio clock domain. Implement only if the S13 measurement shows demand and feasibility. | Medium | High | LIVE |

## Do not pursue

Techniques the research rejected. Each line is the decision of record.

| Technique | Reason | Sources |
|---|---|---|
| esync / fsync / fastsync | Superseded by ntsync, which is already shipped, has exact NT semantics, and has no fd pressure. Nothing there is worth resurrecting. | SYNC |
| `-DontCombineAPCs` | Removes the idle-core burn but starves playback; reverted and stripped from releases. The fix is M1, not the flag. | LIVE, PATCHMAP |
| Wineserver replacement or rewrite | No credible effort exists as of August 2026; the working strategy is shrinking wineserver's role, not replacing it. | SYNC |
| vkd3d-proton | No D3D12 anywhere in this workload. Watch item only. | GFX |
| DXVK-NVAPI | Game latency-reduction and upscaling features a DAW UI cannot use. | GFX |
| Fossilize shader pre-caching | Vulkan-only; this stack's GPU work is OpenGL and software rendering, and Live's fixed shader set has no stutter problem. | GFX |
| pressure-vessel container | The pinned relocatable tarball already provides library isolation; a DAW needs host PipeWire, ALSA, USB, RT scheduling, and portals, so a container adds failure modes for no gain. | GFX |
| gamescope and frame-latency tooling | Live is a multi-window desktop app, not a fullscreen surface; the equivalent present-path work already shipped in patches 0055/0058/0059. | GFX |
| GE-Proton as a runtime | Game-targeted and Steam-container-bound; supported outside Steam only through umu. | GFX, FORKS |
| FAudio / winepulse tuning | Live's engine rides ASIO -> PipeASIO -> PipeWire; winepulse carries only incidental sound. | GFX, AUDIO |
| WineASIO / JACK return | PipeASIO superseded it: WineASIO summed inputs to mono, showed high latency under load, and lost PipeWire links on hotplug. | AUDIO |
| wine-rt-style `WINE_RT` patch | Superseded by the launcher's `chrt` policy. | FORKS |
| wine-wayland migration | The patch series is deeply winex11-shaped; the Wayland driver is still landing windowing basics in mid-2026. Re-check later. | FORKS |
| wine-tkg / GE game patches (FSR, fs-hack, raw input, compositor bypass, media foundation) | Game-only; Live's media import already works through winegstreamer. | FORKS |
| hangover / box64 | x86-on-ARM emulation; this project targets x86-64 only. | FORKS |
| Allocator swaps and Proton heap options | Game bug workarounds, not optimizations. | GFX |
| Blanket PREEMPT_RT recommendation | Buys worst-case jitter, not speed, with real scheduling overheads; only S15's measured deltas justify a recommendation. | AUDIO |

## Measurement plan

The project's evidence standard is a committed before/after pair from
`scripts/bench-run.sh` under fixed reference conditions. No performance
claim ships without one.

### Existing tools

| Tool | What it measures or gates |
|---|---|
| `scripts/bench-run.sh` | One CSV row per run into `bench/results.csv`. Automated: `wined3d_cs_pct` (60 s of per-thread `top` samples) and `wineserver_ctxt_delta` (60 s of `/proc` counters). Operator-entered: `xruns_5min` (pw-top ERR delta) and `dsp_load_pct` (Live's meter). |
| `scripts/check-ntsync.sh` | ntsync semantics probe, `/dev/ntsync` presence, wineserver open-fd check, wineserver context-switch delta. |
| `scripts/check-live-audio.sh` | Live opens PipeASIO without a FatalError or hang; sample-rate line present; points at `pw-metadata` for forced quantum. |
| `scripts/check-m4l-fonts.sh` | M4L font-fallback hang regression. |
| `scripts/build-audit.sh` | Patch-stack provenance and per-patch binary fingerprints; the relocation gate (scripts/container-build.sh:240-265) proves the packaged tree runs. |
| `beta/tester-kit/run-session` + `beta/tester-kit/probes/src/` | Redacted system report plus checksum-verified probes: `ntsyncprobe.c` (sync throughput table), `stresstest.c`, `resizeprobe.c`, `menumeasure.c`, `glchild.c`, `portalprobe.c`, `midihot.c`, `dcompspy.c`. |
| `tools/` | Diagnostic probes: `midihot`, `linkprobe`, `mousespy`, `metricprobe2`, `stresstest`, `m4l-hang-capture.sh`, `m4l-font-audit.py`. Diagnostics, not benchmarks. |
| External | `pw-top`, `pw-metadata`, `top -H`, `perf`. |

### Verification per top-tier opportunity

| Opportunity | How to verify | Baseline to close first |
|---|---|---|
| T1 `/dev/ntsync` launch check | `check-ntsync.sh` verdict on a host with the module unloaded; bench pair on `wineserver_ctxt_delta`; `ntsyncprobe` throughput table | None |
| T2 Scheduling A/B | `bench-run.sh` pairs across arms (`ABLETON_RT=off`, default, wineserver boost, narrowed RT) under the written 4-CPU `taskset` protocol; xrun and DSP rows per arm | Committed reference set (T3); a low-core machine for the comparison |
| T3 Bench automation | The harness itself; a `bench/` directory with the reference set and rows | Self-contained |
| T4 Buffer/quantum/rate | `check-live-audio.sh` at each buffer size; `pw-metadata` force-quantum readout; bench pairs at 512/256/128/64 frames | Automated xrun capture (T3); RTL probe (S7) for absolute latency numbers |
| T5 Compiler flags | Relocation gate plus `build-audit.sh` for correctness; bench pairs on `wined3d_cs_pct` and `wineserver_ctxt_delta`; `ntsyncprobe` throughput; the present-bandwidth method from issue 91 | Committed reference set (T3) |
| T6 Hybrid-core placement | Bench pairs pinned versus unpinned; `top -H` inspection of which cores Live, PipeASIO, and wineserver threads occupy | A hybrid-core machine for the comparison |

### Missing baseline

These gaps block or weaken measurement today:

- No committed `bench/` directory or reference set. The harness protocol
  requires a committed reference set; the repo does not contain one.
  Unverified: testers may hold it privately.
- The headline xrun metric is operator-entered. No automated `pw-top -b`
  capture exists.
- No RTL or callback-period-jitter measurement exists anywhere in the repo.
- No startup-time, idle-CPU (APC-thread), or UI-responsiveness metrics.
- The RT policy's effect on low-core-count systems is unmeasured.
- Wine file-I/O latency versus Windows is unmeasured.
- The WineASIO-versus-PipeASIO controlled comparison was never run.
- Bench rows do not record Live, WebView2, or GPU-driver versions, although
  those are uncontrolled variables: WebView2 Evergreen self-updates inside
  the prefix and regressed rendering once already. Record versions per row.
- No documented per-interface buffer floors.
