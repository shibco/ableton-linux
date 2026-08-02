# Ableton Live internals for Wine optimization

This document explains how Ableton Live works technically at the level needed to choose and implement Wine-side performance and stability optimizations. It mines this repository's notes and patch series, then fills gaps with Ableton's documentation and public bug reports. Each section ends with the implication for Wine performance or stability.

Scope: Live 12 is the production target. Live 11 support is experimental (`notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:3-4`). The tested production version across the notes is Live 12.4.3 (for example `notes/ABLETON-WINE-DPI-SCALE-100.md:5`).

Terms used throughout: ASIO (Audio Stream Input/Output) is Steinberg's low-latency audio driver interface that Live uses on Windows instead of the default MME/DirectX path (https://help.ableton.com/hc/en-us/articles/209072289-How-to-reduce-latency). PipeWire is the Linux audio server this project targets through PipeASIO. An xrun is a buffer underrun or overrun, heard as a click or dropout.

## Which Live version is which

Differences that matter for Wine work:

| Property | Live 11 | Live 12 | Evidence |
|---|---|---|---|
| Bitness | 64-bit only (plugins 64-bit since Live 10.1) | 64-bit only | https://help.ableton.com/hc/en-us/articles/209071729-Using-VST-plug-ins-on-Windows; `notes/ABLETON-WINE-PIPEASIO.md:22-23` |
| Media import/preview | Loads Windows Media Format (`wmvcore.dll`); crashes on Wine stubs | Does not use this path | `notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:3-6` |
| Bundled Max | Max 8 | Max 9 (release notes record bundled build 9.0.9) | `notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:85`; https://www.ableton.com/en/release-notes/live-12/ |
| GPU renderer | None | Hardware-accelerated GPU renderer since 12.2, off by default | https://help.ableton.com/hc/en-us/articles/4405388230674-Recommended-Graphics-Settings-Windows |
| Splice integration | None | In-browser Splice view since 12.3 (WebView2 pane) | https://www.ableton.com/en/blog/live-12-3-is-here/; `notes/ABLETON-WINE-GPU-RENDERER.md:20-21` |
| Stem Separation | None | On-device AI stem separation since 12.3 (Suite) | https://www.ableton.com/en/blog/live-12-3-is-here/ |
| Link Audio | None | Network audio streaming between devices since 12.4 | https://www.production-expert.com/production-expert-1/ableton-live-124-released-link-audio-updated-devices-and-move-and-note-20 |
| Installer extras | `tlsetupfx.exe` USB driver installer can fault under Wine | Same class of helper; not re-confirmed per release | `notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:62-64` |

## Audio path

How Live produces sound:

- Live processes audio in fixed-size buffers. The buffer size is set in Live's Audio Preferences; smaller buffers lower latency but need more CPU, and too-small buffers cause dropouts (https://help.ableton.com/hc/en-us/articles/209072289-How-to-reduce-latency).
- Live's CPU meter is not a CPU-usage meter. It compares the time needed to process one buffer with the time one buffer takes to play. Over 100 percent means a missed deadline and a dropout (https://www.ableton.com/en/manual/computer-audio-resources-and-strategies/).
- The engine is multithreaded. Live assigns independent signal-path segments to separate threads, supports up to 64 cores and 64 audio threads, enables hyper-threading automatically, and on hybrid CPUs runs audio only on performance cores (https://help.ableton.com/hc/en-us/articles/209067649-Multi-core-performance-in-Ableton-Live-FAQ). Serial dependencies (one track feeding another, sidechains, sends) force in-order processing on the critical path, so single-core speed still bounds heavy chains.
- Live's manual states: Live expects the audio thread to have the highest priority, but the OS makes the final scheduling decision (https://www.ableton.com/en/manual/computer-audio-resources-and-strategies/).
- Moving audio to and from the hardware is a constant CPU drain proportional to active channels; Live keeps unused channels enabled to avoid a driver reconfiguration hiccup (https://www.ableton.com/en/manual/computer-audio-resources-and-strategies/).
- On Windows, low latency requires ASIO. Under this project the ASIO driver is PipeASIO, a Wine ASIO driver that exposes Live as a native PipeWire client and removed JACK from Live's audio path in release 2026.07.17.2 (`notes/ABLETON-WINE-PIPEASIO.md:3-4`).
- PipeASIO defaults: two inputs, two outputs, a fixed 256-frame buffer, automatic connection, graph-rate following (`notes/ABLETON-WINE-PIPEASIO.md:57-59`). On PipeWire 1.6 or newer it can match the graph quantum to the ASIO buffer; a 256-frame configuration produced `force-quantum` 256 in validation (`notes/ABLETON-WINE-PIPEASIO.md:20`, `notes/ABLETON-WINE-PIPEASIO.md:73`).
- The project's two PipeASIO patches clamp unsupported sample-rate requests (keeping the graph rate instead of failing with `ASE_NoClock`) and report the clock Live uses for MIDI timestamps (`notes/ABLETON-WINE-PIPEASIO.md:28-30`, `patches/pipeasio/0001-asio-keep-graph-sample-rate-instead-of-ASE_NoClock.patch`, `patches/pipeasio/0002-asio-report-timeGetTime-in-ASIO-systemTime.patch`, `notes/ABLETON-WINE-AUDIO-HOTPLUG.md:35-37`).
- Validation recorded about 8 percent Live DSP load at 48 kHz and 256 frames, not a controlled latency comparison (`notes/ABLETON-WINE-PIPEASIO.md:83-85`).
- Scheduling: the launcher starts Wine under `SCHED_RR` priority 10 whenever `chrt -r 10 true` succeeds; PipeASIO separately requests `SCHED_FIFO` priority 15 for its data-loop thread (`notes/ABLETON-WINE-RT-SCHEDULING.md:3-6`, `scripts/ableton-live:780-782`). `ABLETON_RT=off` disables only the launcher's policy.
- MIDI arrives through Wine's ALSA sequencer driver (`winealsa.drv`). Wine enumerates sequencer ports once per process; patch 0028 re-subscribes when a device returns, but a device first connected after startup still needs a Live restart (`notes/ABLETON-WINE-MIDI-HOTPLUG.md:3-5`, `notes/ABLETON-WINE-MIDI-HOTPLUG.md:13-17`).
- Audio device enumeration goes through MMDevice. A stopped WirePlumber can leave only `auto_null` and block enumeration after `Audio In Out: Constructor finished`; a Wine bug re-wrapped stored endpoint names until enumeration failed (patch 0021) (`notes/ABLETON-WINE-AUDIO-CRASH-BUG.md:3-5`, `notes/ABLETON-WINE-AUDIO-CRASH-BUG.md:22-36`).
- Tempo automation timing: issue 101 reports tempo ramps render about 0.33 seconds shorter over a 7-minute export than on Windows (0.08 percent). Per-buffer tempo evaluation was simulated and is too small to explain it; the leading hypothesis is different Live versions on the two installs. Unresolved (`notes/FINDINGS-TEMPO-RAMP-2026-07-31.md:20-24`, `notes/FINDINGS-TEMPO-RAMP-2026-07-31.md:110-131`).

Synchronization load, measured on this stack:

- Live batches engine asynchronous procedure calls (APCs, Windows callbacks queued to a specific thread) with a high-frequency alertable wait. The coalescing thread used 30 to 40 percent of one core while idle. Disabling coalescing with `-DontCombineAPCs` removed that load but caused choppy, slowed playback (issue 29); the option was removed again (`notes/ABLETON-WINE-APC-COALESCING.md:2-7`).
- The unconfirmed hypothesis: a wait loop near 1 kHz, and with coalescing off, one wineserver round trip per engine APC, serialized by the single-threaded wineserver (`notes/ABLETON-WINE-APC-COALESCING.md:14-28`).
- ntsync (the Linux kernel driver for NT synchronization primitives) matters measurably: a build that omitted it pushed wineserver to about 45 percent of one core and about 9,000 context switches per second with Live idle at a 256-frame buffer; restoring it gave 4 to 50 times more synchronization throughput in probes (`notes/ABLETON-WINE-NTSYNC-REGRESSION.md:11-14`).

Implication for Wine:

- The audio thread's deadline is a few milliseconds (256 frames at 48 kHz is about 5.3 ms). Every synchronous wineserver call on an audio-pool thread is a deadline risk; ntsync coverage and any remaining server round trips in the APC path are the highest-leverage audio-stability targets (`notes/ABLETON-WINE-APC-COALESCING.md:31-47`).
- Unverified: whether Wine maps Live's Windows thread-priority requests to Linux scheduling at all, and how that interacts with the launcher's blanket `SCHED_RR`. The scheduling note lists untested hypotheses: Linux's 950 ms/s realtime throttle, all inherited threads sharing RR 10, and Live's realtime threads outranking the `SCHED_OTHER` wineserver they make synchronous calls to (`notes/ABLETON-WINE-RT-SCHEDULING.md:30-42`).
- Buffer size is the user's latency knob end to end: Live buffer, PipeASIO `PIPEASIO_PREFERRED_BUFFERSIZE`, PipeWire quantum. The chain already works (force-quantum follows the ASIO buffer), so Wine work here is validation, not plumbing (`notes/ABLETON-WINE-PIPEASIO.md:87-96`).
- Export timing (tempo ramps) is clock-independent — export reads no audio device clock — so any remaining render difference points at math or engine evaluation order, not at scheduling (`notes/FINDINGS-TEMPO-RAMP-2026-07-31.md:36-41`).

## Plugin hosting

How Live hosts plugins:

- Live supports VST2 and VST3 on Windows, 64-bit only (https://help.ableton.com/hc/en-us/articles/209071729-Using-VST-plug-ins-on-Windows).
- Live does not sandbox plugins. They load into Live's process; a plugin crash can take Live down, and plugin sandboxing is a long-standing feature request (https://forum.ableton.com/viewtopic.php?t=244536). Crash reports from plugin vendors show a plugin fault crashing the whole DAW on native Windows (for example https://forum.vital.audio/t/vital-crashes-ableton-live-11-windows-10/5634).
- Repo evidence agrees: plugin editors are child or tool windows of Live's own window tree, class `Vst3PlugWindow`, style `WS_EX_TOOLWINDOW`, in a different DPI space than Live's main window (`notes/ABLETON-WINE-PLUGIN-TITLEBAR-BUG.md:12-18`). The WebView2 plugin-close crash happened inside Live's process in `ole32` (`notes/ABLETON-WINE-WEBVIEW2-PLUGIN-CLOSE-CRASH.md:16-19`).
- Plugin GUI technologies seen in this repo's notes, with the Wine surface each one exercises:

| Plugin / framework | GUI technology | Wine surface hit | Evidence |
|---|---|---|---|
| JUCE 8 (SWAM, Pianoteq, many vendors) | Direct2D via DirectComposition; DropShadower layered windows | dcomp subclassing, layered attributes, mixed-DPI hosting | `notes/ABLETON-WINE-INPUT-BUG.md:9-24`; `notes/ABLETON-WINE-PLUGIN-TITLEBAR-BUG.md:40-45` |
| CHOW Tape Model (JUCE) | OpenGL child surface on depth-32 ARGB window | XRender pict format depth matching | `notes/ABLETON-WINE-GL-PLUGIN-EDITOR-CRASH-BUG.md:1-14` |
| nih-plug / baseview (Rust) | wgl pixel format with `srgb: true` | EGL backend sRGB formats; a miss aborted Live through a Rust panic | `notes/ABLETON-WINE-INPUT-BUG.md:61-68` |
| Splice INSTRUMENT | WebView2 editor | cross-process OLE drop-target revocation | `notes/ABLETON-WINE-WEBVIEW2-PLUGIN-CLOSE-CRASH.md:3-18` |
| Pianoteq (JUCE) | DPI-unaware editor hosted under Auto-Scale | host-driven resize negotiation loop | `notes/ABLETON-WINE-PIANOTEQ-DPI-GHOST-BUG.md:9-18` |

- Live's Auto-Scale Plugin Window is enabled by default and Ableton recommends leaving it on (https://help.ableton.com/hc/en-us/articles/4405388230674-Recommended-Graphics-Settings-Windows). Disabling it was the workaround for the Pianoteq resize loop (`notes/ABLETON-WINE-PIANOTEQ-DPI-GHOST-BUG.md:3-5`).
- Delay compensation: plugins and devices can add latency; Live compensates across tracks. An open Max for Live editor adds latency (https://help.ableton.com/hc/en-us/articles/209072289-How-to-reduce-latency).
- Linux-native plugin routing (Carla over PipeWire, Carla's Wine-native bridge, winesulin) is documented but untested by this project (`notes/ABLETON-WINE-PLUGIN-BRIDGING.md:1-6`, `notes/ABLETON-WINE-PLUGIN-BRIDGING.md:46-54`).

Implication for Wine:

- Because hosting is in-process, every Wine defect a plugin framework hits becomes a Live defect. Plugin GUI bugs dominated this project's patch series (patches 0014-0026, 0045; `patches/BASE.txt` ledger and `notes/ABLETON-WINE-INPUT-BUG.md:1-7`).
- There is no plugin-process boundary to absorb Wine regressions. A Wine change that breaks one framework's pixel-format, dcomp, or OLE path ships straight into Live's serious-program-error dialog. The repo's probe suite (`tools/glchild.c`, `tools/webviewclose.c`, `tools/fakeplugin.c`) exists precisely because of this (`notes/ABLETON-WINE-INPUT-BUG.md:73-74`, `notes/ABLETON-WINE-WEBVIEW2-PLUGIN-CLOSE-CRASH.md:31-43`, `notes/ABLETON-WINE-PLUGIN-TITLEBAR-BUG.md:27-28`).
- Mixed-DPI hosting is structural, not incidental: Live computes plugin editor insets in its own DPI space while the editor lives in another (`notes/ABLETON-WINE-PLUGIN-TITLEBAR-BUG.md:25-28`). Any present-path or resize-path change must be tested at fractional and 2x scales, per the GPU renderer note's open checks (`notes/ABLETON-WINE-GPU-RENDERER.md:58-60`).

## Graphics and UI

How Live draws:

- Live's UI is its own framework. A repo note identifies it as Skia-based (`notes/FINDINGS-LIVE-THEME-PREVIEW-SIGNAL-2026-07-26.md:10`). On Windows, Live 12.2 added a hardware-accelerated GPU renderer, off by default, enabled in Settings → Display & Input (https://help.ableton.com/hc/en-us/articles/4405388230674-Recommended-Graphics-Settings-Windows).
- On Windows the GPU renderer is Live's Direct2D/Direct3D 11 path; the fallback is a GDI renderer, forced by `-_ForceGdiBackend` in `Options.txt` (`notes/ABLETON-WINE-GPU-RENDERER.md:8-13`). This project removed that flag and runs the GPU renderer (`notes/ABLETON-WINE-GPU-RENDERER.md:8-17`).
- Live gates the GPU renderer on the reported graphics device. It reads the device name and PCI ID from the API (wined3d's device table under Wine) and rejects unknown devices with the message "Intel(R) HD Graphics 4000: Unexplained slow UI at zoom-level 100% and/or crashes". Patches 0057 and 0061 keep current Intel and Arc devices past that check (`notes/ABLETON-WINE-GPU-RENDERER.md:175-198`).
- Measured effects of the GPU renderer under this Wine: idle CPU drops from about 59 percent of one core to 1-2 percent, and the WebView2 pane flicker stops (`notes/ABLETON-WINE-GPU-RENDERER.md:19-29`).
- Present path: before patch 0055, Wine copied every finished main-window frame from the graphics card to main memory and sent it to the display server as a full-window image, about 14 MB per frame at 2560x1350, about 650 MB per second during continuous UI activity (`notes/ABLETON-WINE-GPU-RENDERER.md:64-73`). Patch 0055 presents top-level windows directly with `glXSwapBuffers`; `WS_CHILD` windows (embedded plugin editors) and `WS_POPUP` windows (Settings, the authorization dialog, context menus) keep the copy path (`notes/ABLETON-WINE-GPU-RENDERER.md:75-86`). Patches 0058/0059 fix a DPI-context disagreement that landed direct-path frames too low under fractional scaling (`notes/ABLETON-WINE-GPU-RENDERER.md:99-171`).
- Live embeds WebView2 (Microsoft's Chromium browser control) for the Learn View, documentation sidebar, and Splice view. Live hardcodes `--disable-gpu --disable-gpu-compositing --disable-direct-composition` into its browser processes, so WebView2 renders in software (`notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md:15-18`). The Evergreen runtime auto-updates inside the prefix; version 149 introduced delegated compositing, which broke rendering on the base fork (https://github.com/giang17/wine/issues/8, `notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md:93-100`). The same present-but-never-composited failure class exists on native Windows (https://github.com/MicrosoftEdge/WebView2Feedback/issues/5574).
- Live's menu bar and Preferences dropdowns are different window types. The menu bar uses Win32 `#32768` menus drawn by win32u; Preferences lists are Live-owned `WS_POPUP` windows (`notes/ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md:19-26`). Wine chrome (menu bar, dialogs) is themed to match Live through registry colors and a `SetSysColors` watcher (`notes/ABLETON-WINE-MENU-COLOR-THEMING.md:19-28`).
- Live is DPI-sensitive in a specific way: it leaves the process default DPI-unaware, selects per-monitor-v2 on individual threads, and recalculates its outer rectangle from the client area after every `ConfigureNotify`. Mixed DPI states caused layout loops of 175 to 400 no-op `SetWindowPos` calls per second at 80 to 99 percent of one core (`notes/ABLETON-WINE-RESIZE-BUG.md:9-35`, `notes/ABLETON-WINE-DPI-SCALE-100.md:62-66`). The launcher manages this with a per-executable IFEO `dpiAwareness` value and prefix calibration (`notes/ABLETON-WINE-RESIZE-BUG.md:52-68`, `notes/ABLETON-WINE-DPI-SCALE-100.md:36-43`).
- Live's Settings UI touches no file, registry key, or other observable channel while it live-previews a theme; `Preferences.cfg` is written only when the dialog closes (`notes/FINDINGS-LIVE-THEME-PREVIEW-SIGNAL-2026-07-26.md:42-49`).

Implication for Wine:

- UI rendering is GPU-bound work travelling over Wine's d2d1/wined3d/dcomp stack — the reason this fork's base is giang17's d2d1-dcomp branch (`patches/BASE.txt:3-6`). The remaining known costs are the copy path for `WS_POPUP` and `WS_CHILD` windows and any frame that fails the 0058 agreement gate (`notes/ABLETON-WINE-GPU-RENDERER.md:78-86`, `notes/ABLETON-WINE-GPU-RENDERER.md:161-165`).
- WebView2 is a second compositor inside the process, in software mode, versioned outside this project's control. An Evergreen update can regress the Learn and Splice views without any change in Wine or Live; the launcher records the WebView2 version for this reason (`notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md:186-189`).
- DPI agreement between threads is a recurring root cause (resize loop, present-path black band). Patches 0023 and 0059 bracket rect queries in the target window's DPI context; any new present or resize code needs the same discipline (`notes/ABLETON-WINE-GPU-RENDERER.md:133-156`, `notes/ABLETON-WINE-PIANOTEQ-DPI-GHOST-BUG.md:31-37`).

## Max for Live

How Max for Live works here:

- Max for Live (M4L) runs Cycling '74 Max devices (`.amxd` files) inside Live through `MaxPlug.dll`, loaded into Live's process. The hang evidence shows Max modules (`maxplug`, `patcher`, `jsui.mxe64`) on Live's own thread stacks (`notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:53-80`).
- Devices are authored on macOS and request macOS typefaces (Geneva, Menlo, Lucida Grande, Helvetica Neue) plus Consolas. On Windows, GDI font mapping never fails, so Max's fallback chain is never exercised. Under Wine the lookup fails, Max walks its hardcoded chain ending at Bitstream Vera faces, and if those are also missing, MaxPlug parks Live's UI thread on a condition variable forever. The audio pool keeps playing (`notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:12-41`, `notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:61-63`).
- Fix shipped: the installer vendors Bitstream Vera into the prefix and registers each face; both halves are required because Wine's font list is registry-driven (`notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:104-128`). `scripts/check-m4l-fonts.sh` guards the chain.
- Max renders its device UI through Direct2D/dxgi. During the deadlock investigation, Max's renderer sat in `dxgi_output_WaitForVBlank`, a Wine semi-stub that only calls `Sleep(16)` (`notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:86-88`).
- M4L device windows come and go as Live children when tracks are selected. That visibility change flipped Wine's whole client surface between attached and offscreen-composited paths, flashing the window black; patch 0062 keeps the Live class on the offscreen path (`notes/ABLETON-WINE-M4L-SELECTION-FLICKER.md:11-22`, `notes/ABLETON-WINE-M4L-SELECTION-FLICKER.md:41-58`).
- An open M4L editor window adds audio latency; Ableton recommends closing editors (https://help.ableton.com/hc/en-us/articles/209072289-How-to-reduce-latency).
- Standalone Max 9 also runs under this Wine. The project ships a `max9` desktop entry and registers the `c74max:` URL scheme and the `.amxd` MIME type (`desktop/max9.desktop.in:1-11`, `desktop/wine-protocol-c74max.desktop.in:1-8`).
- Threading trivia with operational impact: Live names 46 threads `MainThread`; identifying threads by name misled an earlier investigation (`notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:225-228`).

Implication for Wine:

- Max inherits every Wine graphics and font defect Live hits, plus its own. The font deadlock shows a class of bug where Wine's honesty (reporting font failure that Windows hides) turns a Windows-latent defect into a Live hang. Similar Windows-lax behaviours elsewhere (font substitution, GDI mapper, EnumFontFamilies output) are worth auditing before chasing M4L reports (`notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:182-197`).
- The `WaitForVBlank` semi-stub means M4L devices with continuous redraw (meters, jsui) are paced by `Sleep(16)`, not by real vblank. Unverified: whether this costs UI smoothness or CPU in normal use; it is the known pacing point for all Max rendering (`notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:86-88`).
- Known upstream failure mode to keep in mind: Live freezing at "Starting Max..." is reported on other Wine builds (https://github.com/Frogging-Family/wine-tkg-git/issues/1226); this fork's font fix addresses one specific trigger, not the general class.

## Link

How Ableton Link works here:

- Link is Ableton's protocol for synchronizing beat, tempo, phase, and start/stop across applications on one or more devices (https://ableton.github.io/link/, SDK at https://github.com/Ableton/link).
- Wire protocol: peer discovery over UDP multicast on `224.76.78.75:20808`; pairwise timeline measurement over unicast UDP on ephemeral ports (`notes/ABLETON-WINE-LINK.md:170-173`).
- Live joins as its own peer inside the Wine process. Wine 11.11 already passes the socket options the SDK needs (`IP_ADD_MEMBERSHIP`, `IP_MULTICAST_IF`, `SO_REUSEADDR`); `WSAJoinLeaf` is a Wine stub but the SDK does not use it (`notes/ABLETON-WINE-LINK-FIRSTCLASS.md:9-16`). No patch in this project touches networking.
- The project ships `ableton-linkd`, a native peer built on the vendored Link 4.0 SDK, which holds session tempo and timeline across Live restarts and enables Start Stop Sync (`notes/ABLETON-WINE-LINK.md:52-64`). A systemd user unit keeps it running (`scripts/ableton-linkd.service`).
- Live's own Link heartbeat shows up as a periodic `Log.txt` write, which once masqueraded as a settings-change signal (`notes/FINDINGS-LIVE-THEME-PREVIEW-SIGNAL-2026-07-26.md:31-33`).
- Live 12.4 (released May 2026) added Link Audio: real-time multichannel audio streaming between Link-enabled devices over LAN, with Live and Push 3 sending and receiving (https://www.production-expert.com/production-expert-1/ableton-live-124-released-link-audio-updated-devices-and-move-and-note-20, https://help.ableton.com/hc/en-us/articles/25425913328924-Link-Audio-FAQ). This project's implementation explicitly leaves Link Audio out (`notes/ABLETON-WINE-LINK-FIRSTCLASS.md:161`).

Implication for Wine:

- Classic Link works through stock Wine sockets; the stability surface is the host firewall, multicast-unfriendly access points, and prefix state, not Wine code (`notes/ABLETON-WINE-LINK.md:162-166`).
- Link Audio raises the stakes: it is timed audio over the LAN arriving as an input in Live, so it joins the audio clock domain. Unverified: how Link Audio performs under this stack; it needs the same xrun-style measurement as PipeASIO before anyone claims support.
- PipeASIO has no JACK transport layer, so external JACK bridges (`jack_link`) cannot sync Live; Live must follow the shared timeline itself (`notes/ABLETON-WINE-LINK.md:180-183`).

## File handling

How Live touches files:

- Live Sets (`.als`) are gzipped XML; the saving Live version is in the `Creator` attribute (`notes/FINDINGS-TEMPO-RAMP-2026-07-31.md:75-76`).
- File dialogs: patch 0031 routes 64-bit `GetOpenFileName`, `GetSaveFileName`, `IFileDialog`, and `SHBrowseForFolder` through the XDG Desktop Portal; 32-bit callers and unsupported options fall back to Wine's chooser (`notes/ABLETON-WINE-FILE-PORTAL.md:9-21`).
- "Show in Explorer": Live shells out with `explorer.exe /select,"<path>"` for files and `explorer.exe /e,"<folder>"` for the library panel. Patches 0043, 0063, and 0064 route these to the host file manager through the portal and `org.freedesktop.FileManager1` (`notes/ABLETON-WINE-SHOW-IN-EXPLORER.md:13-27`, `notes/ABLETON-WINE-SHOW-IN-EXPLORER.md:78-99`).
- Live's browser: Wine reported Unix mount boundaries as reparse points without data, and Live omitted them; patch 0033 (`WINE_DISABLE_UNIX_MOUNT_REPARSE`, set by the launcher) reports them as directories (`notes/ABLETON-WINE-ENCORE-REVIEW.md:11-20`).
- Patch 0060 implements `IFileOperation::DeleteItem` in shell32 (`patches/0060-shell32-implement-IFileOperation-DeleteItem.patch`).
- Live 11 loads `wmvcore.dll` (Windows Media Format) for browser preview and import of WMA/video files; Wine's stubs raise `EXCEPTION_WINE_STUB` and crash it (`notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:10-18`).
- Disk load is a real audio-path factor: the disk overload indicator flashes when audio cannot be read or written fast enough, causing gaps on record and dropouts on playback (https://www.ableton.com/en/manual/computer-audio-resources-and-strategies/).

Implication for Wine:

- File handling under Live is mostly correctness work, now largely done. The remaining performance-relevant path is sample streaming from disk into the audio engine, which crosses Wine's file I/O (`ntdll`/`kernel32`) on threads that feed the audio deadline. Unverified: whether Wine file I/O adds measurable latency to Live's disk streaming versus Windows; no note in this repo measures it.
- Every new shell32/comdlg32 routing patch needs a 32-bit-caller story, because new WoW64 cannot load the 64-bit portal Unix library (`notes/ABLETON-WINE-SHOW-IN-EXPLORER.md:111-114`).

## Authorization and online services

How licensing and online features work:

- Authorization binds to the prefix's `MachineGuid`. A response produced for another prefix cannot authorize this installation (`notes/ABLETON-WINE-ONLINE-AUTH.md:19-20`).
- Online flow: Live opens an Ableton HTTPS URL, Wine passes it through `winebrowser` and `xdg-open` to the host browser, Ableton returns an `ableton:` URL or a downloadable `.auz` file, and the desktop MIME system routes both back through the launcher into the prefix (`notes/ABLETON-WINE-ONLINE-AUTH.md:8-17`). This matches Ableton's documented online and offline authorization flows (https://help.ableton.com/hc/en-us/articles/209773585-Authorizing-Live-Online, https://help.ableton.com/hc/en-us/articles/360000573444-Authorizing-Live-Offline).
- The return path is contested: another Wine prefix can overwrite the `wine-protocol-ableton.desktop` handler. The installer replaces wrong handlers, pins defaults with `xdg-mime`, and the launcher repairs them (`notes/ABLETON-WINE-ONLINE-AUTH.md:25-60`).
- Live's in-app network access can fail under Wine; the offline `.auz` path is the fallback (`notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:102-103`).
- Online-adjacent components that update themselves inside the prefix: Live's auto-updater and the WebView2 Evergreen runtime, which updated to 149 inside the prefix on 2026-07-24 without any installer involvement (`notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md:33-36`).
- Live 12.3's Splice integration streams commercial sample content into a WebView2 pane (https://www.ableton.com/en/blog/live-12-3-is-here/).
- Push 2's display helper (`Push2DisplayProcess.exe`) is a separate Ableton process that speaks libusb; patch 0032 bridges its 16-function Win64 libusb ABI to host libusb so the display works while ALSA keeps the MIDI interfaces (`notes/ABLETON-WINE-PUSH2-DISPLAY.md:24-52`).

Implication for Wine:

- Authorization stability is launcher and MIME plumbing, not Wine internals; the failure mode is silent misrouting after another prefix installs a handler (`notes/ABLETON-WINE-ONLINE-AUTH.md:28-40`).
- Self-updating components inside the prefix (WebView2, Live itself) are uncontrolled variables in any performance experiment. Record versions before benchmarking, as the WebView2 guardrail does (`notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md:186-189`).
- The Push 2 bridge is a fixed 16-function ABI. Live updates could extend the helper's libusb usage beyond it; the bridge's limits are documented (`notes/ABLETON-WINE-PUSH2-DISPLAY.md:135-147`).

## Observed crash and hang classes

Classes observed on this stack, with root cause and status. Signatures make them recognizable in user reports.

| Class | Signature | Root cause | Status | Evidence |
|---|---|---|---|---|
| Audio enumeration hang/crash | Log stops after `Audio In Out: Constructor finished` | Stopped WirePlumber or endpoint-registry name rewrapping | Fixed (patch 0021) plus runbook | `notes/ABLETON-WINE-AUDIO-CRASH-BUG.md:3-36` |
| OpenGL plugin editor crash | `BadMatch` X error, window to 1x1 on first paint | Depth-24 pict format on depth-32 ARGB window | Fixed (patch 0026) | `notes/ABLETON-WINE-GL-PLUGIN-EDITOR-CRASH-BUG.md:5-35` |
| WebView2 plugin close crash | Serious-program-error dialog closing Splice editor | Cross-process `RevokeDragDrop` on helper-owned window | Fixed (patch 0045) | `notes/ABLETON-WINE-WEBVIEW2-PLUGIN-CLOSE-CRASH.md:9-24` |
| M4L device load hang | Window black, audio playing, 100% reproducible | MaxPlug font fallback chain dead-ends into deadlock | Fixed by vendored fonts; Max defect remains | `notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:3-41` |
| Idle CPU burn | APC coalescing thread at 30-40% of a core | High-frequency alertable waits through wineserver (hypothesis) | Open; `-DontCombineAPCs` is not a fix | `notes/ABLETON-WINE-APC-COALESCING.md:2-28` |
| Synchronization throughput collapse | wineserver at 45% core, 9k ctx/s | Build omitted ntsync | Fixed (vendored UAPI header, build gate) | `notes/ABLETON-WINE-NTSYNC-REGRESSION.md:3-14` |
| Window layout loop | 175-400 no-op `SetWindowPos`/s, 80-99% core | Mixed process/thread DPI states | Fixed (IFEO, patches 0040/0042) | `notes/ABLETON-WINE-RESIZE-BUG.md:9-63` |
| Menu/dropdown loss | Lost clicks, menus closing instantly | FocusOut cancels tracking; mapped popup flipped to managed | Fixed (patches 0038/0039) | `notes/ABLETON-WINE-MENU-FOCUSOUT.md:9-29`; `notes/ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md:28-52` |
| Plugin window creation failure | `VST3: plug window creation failed`, 2.4 s stalls | Read-only shared session mapping stopped updating | Fixed (patches 0018/0019) | `notes/ABLETON-WINE-INPUT-BUG.md:38-53` |
| Plugin editor dead to input | Editor paints but ignores mouse | Orphaned dcomp subclass swallowed window procedure | Fixed (patch 0016) | `notes/ABLETON-WINE-INPUT-BUG.md:9-24` |
| Rust plugin abort | Process abort opening nih-plug editor | EGL backend advertised no sRGB pixel formats | Fixed (patch 0020) | `notes/ABLETON-WINE-INPUT-BUG.md:61-68` |
| WebView2 pane flicker | Grey cutout alternating at 5 Hz | Two writers (Wine reblit, Chromium software frame) on one window | Resolved by GPU renderer; upstream dcomp work pending | `notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md:38-52` |
| Direct-present black band | Frame drawn low, hit-testing correct | DPI-context disagreement on present path | Fixed (patches 0058/0059) | `notes/ABLETON-WINE-GPU-RENDERER.md:99-171` |
| M4L selection black flash | Whole window flashes black on track reselect | Full-client attach/detach of offscreen client surface | Fixed (patch 0062) | `notes/ABLETON-WINE-M4L-SELECTION-FLICKER.md:11-58` |
| Live 11 media crash | `EXCEPTION_WINE_STUB` 0x80000100 | `wmvcore.dll` stubs raise on call | Open; needs trace to identify export | `notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:10-40` |
| Live 11 ASIO distortion | Distorted PipeASIO output; MME/DirectX fine | Unknown (issue 14) | Open | `notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:93-97` |
| Tempo ramp timing drift | Export 0.08% shorter than Windows | Leading hypothesis: different Live versions | Open; per-buffer evaluation ruled too small | `notes/FINDINGS-TEMPO-RAMP-2026-07-31.md:110-131` |

Reported upstream and elsewhere, for pattern matching:

- wineserver using a full CPU core with Live 10, fixed by a patch (Wine bug 47281, https://bugs.winehq.org/show_bug.cgi?id=47281 — page content not re-verified; Bugzilla currently sits behind an anti-bot wall, summary per search index).
- Live 12 severe graphical issues on default options; `-_ForceGdiBackend` workaround left Max devices' UIs frozen (Wine bug 57260, https://list.winehq.org/archives/list/wine-bugs@list.winehq.org/thread/DUN3WQJ4TUSHKDA37BVL3PELHXZD6BRP/).
- Live 12 crashes opening sets saved in older versions, and M4L freezes (Wine bugs 56540 and 56537, https://list.winehq.org/hyperkitty/list/wine-bugs@list.winehq.org/thread/O2SD7WTZRJJPOQRWUBMG6CGACLCE6FPQ/).
- Freeze at "Starting Max..." on wine-tkg (https://github.com/Frogging-Family/wine-tkg-git/issues/1226).
- The `-DontCombineAPCs` workaround predates this project in the Wine-NSPA community notes (https://github.com/nine7nine/Wine-NSPA/issues/4).
- Independent press coverage confirms the current stack runs Live 12 and Push on Linux (https://cdm.link/ableton-live-on-linux/).

Implication for Wine:

- Most historical crash classes are window-management and DPI defects, now patched. The open classes cluster around three areas: thread wakeup and synchronization cost (APC coalescing), vendor-component behaviour Wine cannot patch away (Max fonts, WebView2 Evergreen), and Live 11 media support (`wmvcore`).
- Every fixed class has a probe or audit check in `tools/`, `scripts/`, or the tester kit. New performance work should ship with the same kind of guard, because several of these bugs regressed silently once before (ntsync, WebView2 149).

## Key opportunities

1. **Same-process APC fast path through ntsync's alert event.** Impact: high (removes the 30-40% idle-core burn without the `-DontCombineAPCs` playback fault). Effort: high (must preserve FIFO ordering, special APCs, I/O completion ordering; needs a new `apcprobe`). Evidence: proposal and verification plan in `notes/ABLETON-WINE-APC-COALESCING.md:31-73`; ntsync throughput table in `notes/ABLETON-WINE-NTSYNC-REGRESSION.md:38-44`.
2. **Measure and narrow the launcher's blanket `SCHED_RR` policy.** Impact: medium (potential low-core win and priority-inversion removal; currently unmeasured). Effort: medium (A/B harness and bench script already exist). Evidence: untested hypotheses and the pending comparison protocol in `notes/ABLETON-WINE-RT-SCHEDULING.md:30-79`.
3. **Implement a real `dxgi_output_WaitForVBlank`.** Impact: medium (correct pacing for Max device redraw and any Live code waiting on vblank instead of `Sleep(16)`). Effort: medium. Evidence: semi-stub identified at `notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:86-88` (`dlls/dxgi/output.c:371`).
4. **Extend the direct GL present path to `WS_POPUP` and `WS_CHILD` windows.** Impact: medium (kills the remaining 650 MB/s-class copy traffic for Settings, auth dialog, and embedded plugin editors). Effort: medium (must solve the black-before-first-input popup issue). Evidence: `notes/ABLETON-WINE-GPU-RENDERER.md:64-86`.
5. **Close the PipeASIO validation gaps.** Impact: medium (sample-rate changes while open, single-rate hardware, controlled xrun comparisons). Effort: low. Evidence: gap list in `notes/ABLETON-WINE-PIPEASIO.md:87-96`.
6. **Audit Wine font APIs for Windows-lax behaviour Max relies on.** Impact: medium (prevents the next M4L hang class; current fix removes one trigger, not the flaw). Effort: medium. Evidence: `notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:14-19` and rejected-approach findings at `notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md:182-197`.
7. **Support Link Audio (Live 12.4) or document its behaviour.** Impact: medium (new Live feature currently unowned; timed network audio joins the clock domain). Effort: high if implemented, low if measured and documented. Evidence: `notes/ABLETON-WINE-LINK-FIRSTCLASS.md:161`; feature description at https://help.ableton.com/hc/en-us/articles/25425913328924-Link-Audio-FAQ.
8. **Resolve the tempo-ramp export difference (issue 101).** Impact: low-to-medium (timing correctness; likely a Live-version mismatch, but unproven). Effort: low (export test needs no Windows machine). Evidence: pending tests in `notes/FINDINGS-TEMPO-RAMP-2026-07-31.md:132-152`.
9. **Identify and implement the `wmvcore` export Live 11 calls.** Impact: low (Live 11 is experimental). Effort: medium. Evidence: planned fix in `notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:31-40`.
10. **Benchmark Wine file I/O for sample streaming against the audio deadline.** Impact: unknown, potentially medium (disk overloads cause dropouts on the real-time path). Effort: low-to-medium. Evidence: disk-overload behaviour at https://www.ableton.com/en/manual/computer-audio-resources-and-strategies/; no repo measurement exists yet (stated in the file-handling section above).
