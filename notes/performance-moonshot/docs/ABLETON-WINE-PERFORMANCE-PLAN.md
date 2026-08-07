# Ableton Wine performance and stability plan

Review date: 2026-08-01. Target: Ableton Live 12.4.3 on the Wine 11.13 base
recorded in [`patches/BASE.txt`](../patches/BASE.txt).

This review separates measured behavior, source inspection, and proposed work.
The proposals are not performance claims. Each proposal needs a controlled test
before it becomes a default.

## What should change first

The first target is audio deadline reliability. Average CPU use is secondary.
Live must finish every audio buffer before the device consumes it.

| Order | Change | Expected result | Main risk |
| --- | --- | --- | --- |
| 0 | Expand the benchmark and regression gates. | Comparable results and safe rejection of regressions. | Poor workloads can give false confidence. |
| 1 | Implement Windows multimedia thread scheduling and remove process-wide real-time scheduling. | The audio threads run early without raising the UI, scanner, indexer, and browser processes. | A bad priority order can stall the audio callback or the desktop. |
| 2 | Trace and shorten same-process wake-ups, starting with queued audio work. | Less wineserver work and lower wake-up delay. | Windows ordering rules are strict. |
| 3 | Report processor topology and allowed CPUs accurately. | Live assigns audio work to the intended cores and keeps its available parallelism. | Incorrect core classes can reduce capacity. |
| 4 | Replace recurring DirectComposition repair work with current composition handling. | Lower idle and interaction CPU use; remove polling helpers. | Child windows and WebView2 depend on the current workarounds. |
| 5 | Update and instrument PipeASIO. | Measured callback delay, clock drift, buffer state, and audio buffer failures. | An upstream update has not yet been confirmed with Live. |
| 6 | Test a native PipeWire Wine driver for Windows audio outside ASIO. | Lower delay and CPU use for Max, browser media, helpers, and fallback audio. | Live's main ASIO path will not use it. Published results are from one machine. |
| 7 | Test Vulkan renderers behind a switch. | Possible lower render overhead and fewer driver-specific OpenGL faults. | This fork's DirectComposition work depends on Wine DXGI and wined3d behavior. |
| 8 | Port only measured server-bypass work from research forks. | Lower startup, file, message, or wait overhead where traces justify it. | Broad bypasses enlarge the correctness burden. |
| 9 | Test profile-guided build optimization last. | Smaller gains in Wine code that remains hot after structural work. | Most audio processing runs in Live and plug-in binaries, not Wine. |

Do not merge an experiment unless it preserves audio output, MIDI order, file
behavior, window behavior, clean shutdown, and recovery from a forced exit.

## What this project uses now

This repository packages a focused Wine fork. It is not a copy of the full Wine
source tree. The build unpacks a pinned source archive, applies 62 Wine patches
and two PipeASIO patches, then packages the result. The process is defined by
[`Containerfile`](../Containerfile),
[`scripts/container-build.sh`](../scripts/container-build.sh), and
[`patches/BASE.txt`](../patches/BASE.txt).

| Area | Current technology | Current behavior |
| --- | --- | --- |
| Wine base | `giang17/wine` `d2d1-dcomp-11.13` at `5c23dd1c` | Adds the Direct2D and DirectComposition support that Live and WebView2 need. |
| Build | Podman; Ubuntu 22.04 snapshot; GCC; Clang and lld 21.1.8; ccache | Builds Windows-format 64-bit and 32-bit modules with Wine's newer 64-bit layout for 32-bit support. Build inputs and hashes are pinned. |
| Synchronization | Wine kernel synchronization (`NTSync`) plus a vendored Linux header | Uses `/dev/ntsync` on a suitable kernel. Otherwise it falls back to wineserver. Both Wine halves are checked at build time. |
| Main graphics | Live Direct3D 11 (`D3D11`) and DirectX Graphics Infrastructure (`DXGI`); Wine wined3d; OpenGL and GLX; X11 or XWayland | The main Live window can present directly from the graphics card. This avoids the old full-window readback. |
| Embedded graphics | Wine Direct2D and DirectComposition; WebView2 forced to software rendering | Local patches repair composition, resizing, hidden panes, child windows, and fractional scaling. |
| Audio | Live Audio Stream Input/Output (`ASIO`); PipeASIO 1.2.2; native PipeWire | Opens a direct PipeWire node. The default is two inputs, two outputs, 48 kHz testing, and 256 frames. |
| MIDI | Wine ALSA MIDI | A local patch restores devices after reconnect. PipeASIO supplies the clock value used for ASIO MIDI timing. |
| Other Windows audio | Wine PulseAudio and ALSA drivers | Used outside the main PipeASIO path. |
| Media | Wine GStreamer | Imports MP3 and video through host GStreamer libraries. |
| Desktop integration | XDG portals and D-Bus | Provides file dialogs, file reveal, and folder opening. |
| Hardware | A narrow native `libusb` bridge | Supports the 64-bit Push 2 display helper. |
| Network sync | Ableton Link 4.0 native helper | Keeps a classic Link peer present across Live restarts. It is not a Link Audio test. |
| Support code | Bash, C, C++, and one Python audit tool | Provides launch, setup, probes, packaging, and the Link helper. |

The shipped series has most of its source changes in `winex11`, `win32u`,
`comdlg32`, `dxgi`, and `wined3d`. It has little local work in `ntdll`,
`server`, `mmdevapi`, and `winealsa`. This is an engineering history, not a
runtime profile, but it shows that scheduling and wait paths have received less
local work than graphics and desktop integration.

The project does not ship DXVK, vkd3d-proton, Wine Staging, a Proton runtime,
or a Steam container.

## How Live divides its work

### The audio deadline is the controlling measure

Live processes independent signal paths in parallel. Devices on the same path,
sidechains, routed tracks, and mix points must run in order. The longest ordered
path limits the set. Live supports up to 64 audio calculation threads, but more
threads cannot shorten one ordered path. Its CPU meter reports buffer processing
time against buffer playback time; it does not report total machine CPU use.
[Ableton documents this scheduling model and meter behavior](https://help.ableton.com/hc/en-us/articles/209067649-Multi-core-performance-in-Ableton-Live-FAQ).

The active audio path is:

```text
Live audio workers -> ASIO callback -> PipeASIO -> PipeWire -> audio device
```

At 48 kHz, a 256-frame buffer lasts 5.33 ms. A 64-frame buffer lasts 1.33 ms.
The useful measure is the worst callback and worker delay relative to that
deadline. A low average can still produce an audio buffer underrun or overrun
(`xrun`).

### Live asks Windows to schedule multimedia work

Local inspection of the installed 64-bit Live 12.4.3 files found imports for:

- the Windows multimedia scheduling calls `AvSetMmThreadCharacteristicsW`,
  `AvSetMmThreadPriority`, and `AvRevertMmThreadCharacteristics` in Live and its
  audio engine;
- the Windows real-time work queue library (`RTWorkQ.dll`) in the audio engine;
- Windows thread priority, affinity, processor topology, waitable timers, and
  high-resolution clocks; and
- the `Pro Audio` multimedia task name.

Windows uses these APIs to raise only time-sensitive multimedia threads while
retaining CPU time for other work. The [Windows low-latency audio example](https://learn.microsoft.com/en-us/windows/win32/coreaudio/exclusive-mode-streams)
uses the same `Pro Audio` task for a buffer thread.

The pinned Wine base does not provide that behavior:

- [`avrt.dll` returns placeholder success](https://github.com/giang17/wine/blob/5c23dd1c/dlls/avrt/main.c#L57-L92);
- the multimedia registration functions in
  [`RTWorkQ.dll` return `E_NOTIMPL`](https://github.com/giang17/wine/blob/5c23dd1c/dlls/rtworkq/queue.c#L1663-L1724); and
- the Linux Wine server maps ordinary Windows priorities to `nice`, then stops
  below the Windows real-time band. Its source contains an explicit
  [`SCHED_RR` follow-up](https://github.com/giang17/wine/blob/5c23dd1c/server/thread.c#L236-L269).

The launcher currently compensates by starting the entire Wine process at
`SCHED_RR` priority 10 when permitted. Every inheriting UI, browser, scanner,
and background thread receives that policy. PipeASIO separately requests
`SCHED_FIFO` priority 15 for its data loop. Wineserver remains under normal
scheduling. The risks are recorded in
[`notes/ABLETON-WINE-RT-SCHEDULING.md`](ABLETON-WINE-RT-SCHEDULING.md).

### Live depends on accurate processor information

On hybrid processors, Live normally puts audio work on performance cores. Its
Windows 11 default differs from its Windows 10 default. Live also imports the
Windows topology and affinity APIs.

The pinned Wine base counts online host CPUs rather than CPUs allowed to the
process. It reports one processor group, has an explicit limit in the code for
systems above 64 logical processors, and obtains performance-core data from a
single optional Linux path. The launcher's proposed cap of eight CPUs is marked
as inactive groundwork. Enabling that cap would conflict with Live's ability to
use up to 64 audio threads.

### Live is a set of processes and embedded platforms

Local runtime and binary inspection found these main roles:

| Role | Process or technology | Performance concern |
| --- | --- | --- |
| Main application | Live executable and `Ableton Live Engine.dll` | Audio deadlines, UI, plug-ins, project state, and recovery. |
| Plug-in discovery | Ableton Plugin Scanner | Startup CPU, directory scans, process exit, and malformed plug-ins. |
| Content search | Ableton Index | Background file reads, database writes, and change notices. |
| Network services | Web Connector and Link | Browser handoff, network changes, clocks, and shutdown. |
| Max for Live | Max, MaxRT, CEF, Node, and helpers | A second application platform with its own audio, graphics, file, and process behavior. |
| Web content | Edge WebView2 browser and renderer processes | DirectComposition, child windows, drag and drop, resizing, and teardown. |
| Push | Qt/QML display process, MIDI, and USB helper | GPU presentation, USB transfer, device reconnect, and process lifetime. |
| Machine learning | ONNX Runtime and bundled models | CPU, memory, and file load during stem separation. The exact internal split is not public. |

Ableton states that a loaded VST runs inside Live and can terminate Live when it
crashes. The scanner's separate process protects discovery, not playback.
[Ableton's crash guide describes this boundary](https://help.ableton.com/hc/en-us/articles/5301568366354-Reading-Ableton-Live-Crash-Reports).

### Live 12.4 adds a second real-time network path

Live 12.4 added Link Audio. It streams audio between peers, buffers each peer,
and ties latency to both the network and the audio buffer. Live 12.4.3 fixed a
crash involving some Link Audio peers. These behaviors require a separate test
lane from classic Link tempo discovery.
[The Live 12 release notes describe Link Audio and its buffering](https://www.ableton.com/en/release-notes/live-12/).

## What Proton changes for performance

Proton's gains come from replacing expensive subsystems and controlling their
deployment. They do not come from one compiler setting.

| Proton work | Effect | State in this project | Action here |
| --- | --- | --- | --- |
| In-process Windows synchronization | Proton 11 prefers NTSync, uses its earlier fast synchronization path (`fsync`) when NTSync is unavailable and the kernel supports it, then uses wineserver. This removes many server round trips. | NTSync is already compiled and checked. It is active only when `/dev/ntsync` is available. | Keep NTSync. Add a launch-time active-state report and reject silent fallback in performance tests. Consider fsync only as an opt-in fallback for older kernels. Never combine the two. |
| DXVK | Converts Direct3D 9, 10, and 11 to Vulkan. Modern versions prepare more graphics work away from the draw call to reduce some stalls. | Live uses Wine D3D11, DXGI, wined3d, and custom DirectComposition changes. | Test it in an isolated prefix. Do not make it the default until composition, child windows, plug-ins, WebView2, and audio-under-render-load pass. |
| vkd3d-proton | Converts Direct3D 12 to Vulkan. | The main Live renderer is D3D11. Some bundled machine-learning components may use other graphics APIs, but their division of work is not public. | Use only for a traced D3D12 feature. It is not a main-renderer optimization. |
| Steam Linux Runtime | Gives Proton a controlled user-space library set. | The build is controlled, but the installed runtime uses host graphics, PipeWire, GStreamer, portals, USB, and desktop libraries. | Keep the reproducible build. Test selective library bundling before a full runtime container, which would complicate low-latency devices and portals. |
| Per-application switches | Lets Valve disable one feature or select a fallback for one title without changing every title. | This project has several environment switches, but no unified experiment record. | Give every risky optimization one switch, one recorded default, and one benchmark pair. |
| Continuous rebasing and upstreaming | Removes local patches as Wine absorbs them and reduces long-term conflicts. | The fork carries 62 Wine patches and some experiment/revert pairs. | Rebase on a fixed cadence, drop patches that have no final effect, and upstream general fixes. |
| Focused component rebuilds and tests | Lets Proton change one component and check title regressions quickly. | The project has many probes and a beta plan, but the benchmark is narrow and Wine is configured with tests disabled. | Add a test build that runs the touched Wine module tests and the Live workload matrix. |
| Prefix control | Uses locks, versioned upgrades, and native case-insensitive directories where supported. | The launcher serializes initial setup, but prefix migrations and filename behavior have separate paths. | Keep every migration versioned and reversible. Test a new case-insensitive prefix for large plug-in trees; never alter an existing prefix in place. |
| Diagnostics | Supports per-application logs, early debugger attachment, crash directories, symbols, and unstripped builds. | This project has probes and privacy-aware reports, but no single performance crash bundle. | Record the Wine revision, kernel, active wait and audio paths, buffer, thread policies, underruns, and loaded module names. Redact user paths and license data. |

Proton exposes NTSync, fsync, and renderer choices as reversible runtime options.
Its current README marks esync as obsolete in Proton 11. The Linux kernel
documentation states that NTSync exists because a user-space implementation
cannot provide both Windows semantics and comparable performance. Sources:
[Proton README](https://github.com/ValveSoftware/Proton),
[NTSync kernel documentation](https://docs.kernel.org/userspace-api/ntsync.html),
and [DXVK README](https://github.com/ValveSoftware/dxvk).

Proton's own build remains conservative. It uses moderate optimization (`-O2`),
defined integer-overflow behavior, and information needed for useful crash
traces. Its distributed build targets broadly compatible x86 processors. It
does not use a general replacement allocator, whole-project link-time
optimization, profile-guided optimization, `-O3`, or `-march=native`. This
supports putting compiler experiments after wait, scheduling, audio, and
graphics work.

## What other Wine projects provide

The survey covers active or directly relevant projects. It is not a claim that
every public Wine branch is maintained or suitable for Live.

| Project | Relevant work | Use here | Limit |
| --- | --- | --- | --- |
| [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) | Valve Proton plus Wine Staging, current codecs, and application-specific fixes. | Use its patch history as a source of specific compatibility fixes. | Its defaults target Steam games. Importing the whole build would add unrelated behavior. |
| [wine-tkg and proton-tkg](https://github.com/Frogging-Family/wine-tkg-git) | Reproducible switches for Wine Staging, NTSync, older sync methods, and community experiments. | Use the configuration as an experiment index and compare one change at a time. | Many combinations are unsupported. Several older options are obsolete on modern Wine. |
| [Wine Staging](https://github.com/wine-staging/wine-staging) | Experimental fixes before or outside upstream Wine. Historical work includes Wine priority controls. | Review current patch groups by touched subsystem and test selected changes. | The old global real-time controls can slow applications and do not reproduce Windows multimedia scheduling. |
| [Wine-NSPA](https://nine7nine.github.io/Wine-NSPA/) | Per-thread priority mapping, priority-aware locks, same-process events and messages, server bypasses, direct audio callbacks, and extensive hot-path experiments. | Treat it as a research source. Start with scheduling, traces, and narrow same-process paths. | It changes Wine and the kernel together. Published performance results are self-reported and need local reproduction. |
| [Proton-CachyOS](https://github.com/CachyOS/proton-cachyos) and [`winepipewire.drv`](https://github.com/M0n7y5/wine-cachyos/tree/cachyos_11.0_release/_upstream_pipewire/dlls/winepipewire.drv) | A native PipeWire Wine audio driver and a separate [comparison harness](https://github.com/M0n7y5/winepipewire-bench). | Port the driver and unchanged harness behind build and runtime switches. Add Live, Max, capture, device-change, and long-run tests. | The published results are developer-owned, single-machine Windows Audio Session API (`WASAPI`) results. They do not measure Live through ASIO. |
| [wine-osu patches](https://github.com/whrvt/wine-osu-patches) | Small multimedia scheduling, PulseAudio callback, buffer, clock, wait, and server experiments for a latency-sensitive application. | Use its scheduling patch as a starting example and evaluate audio patches one at a time. | The scheduling example does not restore priority. The full patch set is application-specific, high-risk, and lacks one repository-wide license. |
| [ENCORE](ABLETON-WINE-ENCORE-REVIEW.md) | Ableton-focused launcher and Wine fixes. | Continue comparing its small, relevant changes. This project already adapted mount, drag, and resize fixes. | The original repository is no longer public at the recorded URL. The local review preserves the relevant findings. |
| [`giang17/wine`](https://github.com/giang17/wine) | The Direct2D and DirectComposition base used here, with later composition work. | Rebase or port the newer composition model before adding more timer repairs. | A large composition update needs the full window, display-scaling, plug-in, and WebView2 matrix. |
| [PipeASIO](https://m0n7y5.github.io/pipeasio/) | A direct PipeWire ASIO driver. Current 1.2.3 adds monitoring, live configuration, and device-clock handling. | Review the 1.2.2 to 1.2.3 update and reuse its measurements. | Upstream states that 1.2.3 is not yet confirmed with Ableton Live. |
| [WineASIO](https://github.com/wineasio/wineasio) | Mature JACK-backed ASIO with flexible channels, buffer changes, and JACK transport. | Keep a controlled comparison on the same machine and device. | It adds a JACK layer and does not explain Wine engine scheduling. |
| [yabridge](https://github.com/robbert-vdh/yabridge) | Real-time setup, plug-in process grouping, and practical Wine plug-in tests. | Reuse its host checks and scheduling lessons. | It runs Windows plug-ins in Linux hosts, which is the reverse of Live's normal path. |
| Upstream Wine Wayland driver | Direct Wayland output without XWayland. | Maintain a separate long-term branch and measure window latency and stability. | Most local window patches target `winex11`. A direct switch would discard years of tested behavior. |
| [Kron4ek Wine Builds](https://github.com/Kron4ek/Wine-Builds) and [Bottles runners](https://github.com/bottlesdevs/wine) | Build and delivery matrices for vanilla, Staging, TkG, Proton, and Bottles variants. | Use them as packaging comparisons. | Their aggressive build flags have no published Ableton evidence and are not a distinct runtime design. |

The strongest outside ideas are narrow scheduling, fewer same-process server
calls, priority-aware locks, direct PipeWire for non-ASIO audio, better audio
instrumentation, and fewer repeated graphics copies. Large fork merges are not
justified. Current Wine Staging does not supply the older esync or fsync patch
sets, so old Staging tuning guides are not a Wine 11 plan.

## How to test each high-priority change

### 0. Measure missed deadlines and long delays

[`scripts/bench-run.sh`](../scripts/bench-run.sh) records average
`wined3d_cs` CPU, wineserver context switches, an operator-entered xrun count,
and Live's audio-engine load meter. It does not record callback delay, thread
policy, wake-up delay, server request types, start time, memory faults, frame
timing, or crashes.

Add these measures before performance patches:

| Area | Required measure |
| --- | --- |
| Audio | Callback duration; time between callbacks; 99th, 99.9th, and worst delay; xruns; reported input and output latency; clock drift. |
| Scheduling | Policy, priority, CPU, voluntary switches, forced switches, wake-up delay, and runtime for each important thread. |
| Wine server | Requests by type, total handling time by type, queue depth, and blocked caller time. |
| Graphics | CPU by render thread, bytes read back from the graphics card, present interval, long frames, and memory use. |
| Startup | Cold and warm launch; project load; plug-in scan; index completion; helper creation and exit. |
| Files | Directory scan rate, metadata calls, mapped-file faults, flush time, and database lock waits. |
| Stability | Clean exits, forced-exit recovery, hangs, crashes, device loss, and a long playback soak. |

Use one fixed Live set, one fixed plug-in set, a stable power state, and repeated
before/after runs in alternating order. Keep the existing 48 kHz and 256-frame
reference. Add 64 and 128 frames for deadline pressure, then 512 for slower
systems. Use 32 frames only on hardware that passes 64 frames.

The test matrix must include:

- idle, ordinary playback, and the longest practical ordered audio path;
- project load and save while audio runs;
- plug-in scan and content indexing while audio runs;
- VST2, VST3, Max for Live, OpenGL, D3D11, and WebView2 windows;
- repeated window resize, pane changes, plug-in window open and close, and
  fractional scaling;
- MIDI input and output, hotplug, Push 2, and an interface with more than two
  channels;
- Link Audio peer join, leave, packet loss, clock drift, and different buffers;
- X11 and XWayland; AMD, Intel, and NVIDIA graphics; and
- a low-core system, a many-core system, and an Intel hybrid processor.

Keep the broader release matrix in [`beta/TESTING.md`](../beta/TESTING.md).

### 1. Schedule the audio threads instead of the whole process

Implement `avrt.dll` task registration and the related `RTWorkQ.dll`
registration calls. First map the observed `Pro Audio` class and relative
priority through Wine's existing per-thread `nice` support. Restore the original
state on unregister and thread exit, including nested registrations. Keep an
environment switch that restores the current behavior.

Then test a separate mapping from the Windows real-time band to Linux
`SCHED_RR` or `SCHED_FIFO`, limited to registered multimedia threads and only
when the user has permission. This second step must remain off by default until
the starvation tests pass.

Define and test a priority order. The PipeWire data loop, Live's audio work,
supporting Wine work, and wineserver must not wait on a lower-priority holder.
Do not select fixed production numbers until traces show which threads block
which callers. Never raise wineserver above the audio callback by default.

Once the mapping passes, remove the launcher's inherited `chrt -r 10` default.
Keep it only as a comparison mode. This is the closest direct match for what
Live requests on Windows and the highest-confidence structural opportunity.

Pass gates:

- fewer or equal xruns and lower worst callback delay at 64, 128, and 256 frames;
- normal scheduling for UI, scanner, indexer, browser, and maintenance threads;
- exact priority restoration after `AvRevertMmThreadCharacteristics`;
- no starvation during plug-in scan, project save, or window movement; and
- Wine AVRT, RTWorkQ, thread, process, and multimedia tests.

### 2. Shorten queued audio wake-ups without changing their order

The local test that disabled batching for Windows queued asynchronous procedure
calls (`-DontCombineAPCs`) removed a 30-40% idle thread but made playback slow
and broken. The recorded analysis concludes that uncombined queued work likely
increased traffic through the single-threaded wineserver and delayed PipeASIO.
The option was correctly removed. See
[`notes/ABLETON-WINE-APC-COALESCING.md`](ABLETON-WINE-APC-COALESCING.md).

First trace queued calls, alertable waits, server requests, and wake-up targets
during idle and playback. If the calls are same-process and dominate the trace,
prototype a client path backed by the existing NTSync alert event. Keep server
handling for cross-process work, I/O completion, suspension, termination, and
any case whose order cannot be proved locally.

Borrow the narrow design pattern, not the full Wine-NSPA dispatcher. Test queue
order, cancellation, nested alertable waits, process exit, and 24-hour playback.

### 3. Report allowed CPUs and core classes accurately

Replace the inactive eight-CPU proposal with one consistent topology model:

1. Start with CPUs in `sched_getaffinity()`, not all online CPUs.
2. Read package, core, sibling, and capacity data for those CPUs.
3. Report processor groups correctly above 64 logical processors.
4. Give every topology and affinity API the same numbering and masks.
5. Distinguish performance and efficiency cores only when the host provides
   reliable data.
6. Compare the result with the same hardware running Windows 10 and Windows 11.

Test Live's default and
`-RestrictAudioCalculationToPerformanceCores=true/false`. Do not assume that
performance-core-only is faster for every set. It can reduce parallel capacity.

### 4. Remove recurring graphics repair work

The current graphics work already produced the largest measured local gain:
enabling Live's D3D11 renderer reduced idle CPU from about 59% to 1-2%, and
direct OpenGL presentation removed about 650 MB/s of full-window display
traffic. These results are recorded in
[`notes/ABLETON-WINE-GPU-RENDERER.md`](ABLETON-WINE-GPU-RENDERER.md).

The remaining composition path still uses periodic re-blits and a resident
`learnheal.exe` process that scans windows each second and performs a delayed
one-pixel resize. Later work in the base fork implements more complete
composition surfaces and skips unchanged composition trees.

Rebase that work in an isolated branch. The goal is to delete timer repairs,
not add another timer. Remove `learnheal.exe` only after Learn View, Splice,
Max, plug-in editors, hidden panes, and repeated resizes pass without it.

### 5. Make PipeASIO observable and current

The current integration is sound but its performance evidence is incomplete.
The 2026-07-17 test recorded two PipeWire errors on a loaded machine and about
8% on Live's audio-engine load meter, but it was not a controlled comparison.
See
[`notes/ABLETON-WINE-PIPEASIO.md`](ABLETON-WINE-PIPEASIO.md).

Review PipeASIO 1.2.3 against the two local patches. Adopt or expose:

- callback interval and callback duration;
- driver and device rate, buffer size, selected ports, and clock owner;
- xrun count and reason;
- ASIO sample position, host time, input latency, and output latency;
- configuration changes without restarting Live; and
- more than two channels.

Compare PipeASIO 1.2.2, 1.2.3, and WineASIO on the same device, graph, project,
and buffer. Preserve the current direct PipeWire path unless another driver
wins both deadline and correctness tests.

### 6. Test native PipeWire for Windows audio outside ASIO

Proton-CachyOS added `winepipewire.drv`, a direct PipeWire backend for Wine's
Windows audio APIs. Its developer's one-machine comparison reports lower stream
open time, event timing variation, and total client-plus-daemon CPU than
`winepulse.drv`, with the same tested `mmdevapi` results. These are useful leads,
not local evidence.

Port it behind `--with-pipewire` and a runtime audio-driver switch. Run its
[published harness](https://github.com/M0n7y5/winepipewire-bench) unchanged
before adding local probes. Test shared and exclusive playback, capture, rate
changes, suspend, device removal, Max, WebView media, and a long run.

This path does not replace PipeASIO. Live configured for ASIO bypasses Wine's
normal Windows audio driver. Keep PipeASIO as the main path and compare the new
driver as a fallback and for helper processes.

### 7. Test graphics alternatives without replacing the known path

Use two separate experiments:

1. Wine's built-in wined3d Vulkan renderer. This retains more of Wine's DXGI
   structure and is the lower-integration-risk first test.
2. DXVK for D3D11. This has the stronger game record but can bypass code that
   the DirectComposition patches expect.

Measure idle, continuous mouse movement, large window resize, animated plug-in
editors, WebView2, fractional scaling, and audio at 64 frames. Retain the
current OpenGL path as the control and fallback.

### 8. Move only traced work out of wineserver

Wine-NSPA reports large synthetic or local gains from same-process events,
message rings, empty message-poll caching, shared thread and process state,
local file operations, and a custom kernel dispatcher. Those changes are too
broad to import together.

Add per-request timing to this fork, then select one frequent operation. A safe
order is:

1. read-only thread or process queries;
2. repeated empty message polls;
3. eligible local file metadata during indexing;
4. same-process events and waits; and
5. any custom dispatcher or kernel change only after the user-space options
   have reached a measured limit.

Every fast path needs a server fallback and upstream Wine tests. Do not require
a custom kernel for the default runtime.

### 9. Optimize startup after the playback path is stable

Profile the scanner, indexer, database, directory changes, file mapping, and
helper-process lifetime. Live 12.1 already separates plug-in scan data from the
main content database. Repeated scans usually indicate a correctness problem,
not a need for faster scanning.

Useful candidates are duplicate change-notice removal, correct file identity,
fewer metadata server calls, and clean helper exit detection. Generic
asynchronous file work or the Linux `io_uring` file API is justified only if a
trace shows blocked Wine file calls. Keep indexing below audio work.

Also test a newly created prefix on a file system with native case-insensitive
directory support. This can avoid repeated case-insensitive searches in large
plug-in trees. Treat it as a new-prefix experiment. Do not convert an existing
authorized prefix in place.

### 10. Test compiler work only on remaining Wine hot paths

The build uses default Wine optimization. PipeASIO alone adds `-O2 -DNDEBUG`.
Possible experiments are a separate AVX2-capable artifact, link-time
optimization, and profile-guided optimization from the fixed Live workload.

Do not use `-march=native` for a distributed runtime. Do not change
floating-point contraction, rounding, denormal handling, or exception behavior
without reference-render tests. Live requires AVX2, but that does not prove that
every wider instruction set is available. Measure Wine-side CPU, not Live's
total audio-engine load, when judging these builds.

## What should not become a default

- Do not combine the older event-based synchronization path (`esync`), fsync,
  or a spin count with NTSync. NTSync already addresses the same wait problem
  with stronger Windows semantics. An fsync experiment is only a fallback for
  a host without `/dev/ntsync`.
- Do not run every Wine thread under `SCHED_FIFO` or `SCHED_RR`.
- Do not raise wineserver above audio callbacks without a blocked-caller trace.
- Do not enable the eight-CPU cap.
- Do not make DXVK, the wined3d Vulkan renderer, or native Wayland the default
  before the complete window and audio matrix passes.
- Do not merge GE-Proton, wine-tkg, Wine Staging, or Wine-NSPA as a patch bundle.
- Do not use broad memory locking. Live, Max, browser processes, samples, and
  machine-learning models can reserve large amounts of memory. Lock only small,
  proven audio buffers and prepare their pages before playback.
- Do not require a custom kernel. Use a supported NTSync kernel for the fast
  path and retain a correct fallback.
- Do not use allocator replacements, huge pages, `-O3`, or native CPU tuning
  without a measured Wine hot path and a stability result.
- Do not set 0.2-0.4 ms audio periods as a default. They reduce the time
  available to recover from ordinary scheduling delay.
- Do not disable runtime checks for speed. A media path can depend on those
  checks for correct fault handling.
- Do not treat a lower buffer size as a performance win if it adds missed
  deadlines.

## How the work should be staged

| Stage | Deliverable | Exit condition |
| --- | --- | --- |
| A | Benchmark collector and fixed workloads | Repeated control runs have stable distributions and complete metadata. |
| B | `avrt.dll`, `RTWorkQ.dll` multimedia registration, and per-thread priority mapping | Beats normal scheduling and process-wide `SCHED_RR` without starvation. |
| C | CPU topology correction | Matches Windows observations and improves or preserves both long-path and many-track tests. |
| D | Queued-work trace and one narrow fast path | Reduces server work and worst callback delay with full ordering tests. |
| E | Current DirectComposition rebase | Removes repair timers or helpers and passes the graphics matrix. |
| F | PipeASIO update and driver comparison | Produces reliable timing data and passes rate, buffer, channel, hotplug, and soak tests. |
| G | Native PipeWire Wine driver | Beats Wine PulseAudio for non-ASIO uses and passes playback, capture, device, Max, and soak tests. |
| H | Vulkan renderer trials | One renderer wins a defined workload without composition regressions. |
| I | One traced startup or server bypass | Shows a repeatable gain and retains a simple fallback. |
| J | Build optimization | Improves a remaining Wine hot path without numerical or compatibility changes. |

Release each stage separately. Keep one switch that restores the prior path.
Record failed experiments as clearly as successful ones.

## Evidence limits

- Live is proprietary. Its internal worker scheduler and process protocols are
  not public. Local conclusions use documented behavior, imports, process
  observation, and sanitized runtime evidence; they do not assume unseen code.
- The exact Live calls into the Windows multimedia scheduling libraries still
  need a trace.
- The role of Microsoft's DirectML graphics computing library in current
  Windows features is not public. Ableton states that Windows stem separation
  uses the CPU.
- Link Audio transport ports were not documented in the reviewed Ableton pages.
- PipeASIO 1.2.3, Wine-NSPA results, and fork claims have not been reproduced in
  this repository.
- Patch counts show maintenance focus, not runtime cost.

Primary external references used in addition to the linked project sources:
[Ableton Live 12 manual](https://www.ableton.com/en/live-manual/12/),
[Ableton Live 12 release notes](https://www.ableton.com/en/release-notes/live-12/),
[Ableton multi-core FAQ](https://help.ableton.com/hc/en-us/articles/209067649-Multi-core-performance-in-Ableton-Live-FAQ),
[Ableton audio resource guide](https://www.ableton.com/en/live-manual/12/computer-audio-resources-and-strategies/),
[Microsoft multimedia scheduling API](https://learn.microsoft.com/en-us/windows/win32/api/avrt/nf-avrt-avsetmmthreadpriority),
[Proton](https://github.com/ValveSoftware/Proton), and
[Linux NTSync documentation](https://docs.kernel.org/userspace-api/ntsync.html).
