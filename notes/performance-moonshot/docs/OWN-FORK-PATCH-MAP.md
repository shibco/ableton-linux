# Ableton-wine patch map: what the fork already changes

This document inventories every patch the ableton-wine fork carries, so that later performance and stability work does not duplicate fixes that already exist. It is a map, not an evaluation: it records what each patch does and where it came from, and proposes nothing.

## Scope and base

- The series holds 62 top-level patch files, numbered 0001 through 0064. Numbers 0027 and 0044 are intentionally absent (`patches/BASE.txt:14-15`).
- A two-patch sub-series for the PipeASIO audio driver lives in `patches/pipeasio/`.
- The base is `giang17/wine` branch `d2d1-dcomp-11.13` at commit `5c23dd1c`: Wine 11.13 plus a DirectComposition/D2D stack (`patches/BASE.txt:3-5`, https://github.com/giang17/wine).
- Per-patch provenance is recorded in `patches/BASE.txt:32-240`.
- Patch purposes below summarize each patch's own commit message. The Subject line sits at line 1 of each patch file, except patches 0037, 0040, 0041, 0042, 0043, 0045, 0063, and 0064, where it sits at line 4.

## How to read the tables

One table per category. Columns:

- **Patch**: number and short name. The full file is `patches/<number>-<slug>.patch`.
- **Purpose**: one line, from the patch's commit message.
- **Relevance**: `performance` (changes CPU use, bandwidth, latency, or throughput), `stability` (prevents a crash, hang, loop, or flicker), or `correctness` (behavioral or visual fidelity only).
- **Origin**: `upstreamable` (a general Wine fix that upstream could take) or `experimental` (fork-specific heuristic, environment-variable switch, Live-specific workaround, or third-party patchset). Provenance cites `patches/BASE.txt`.
- **Note**: the `notes/` document covering the patch, where one exists. `BASE` means only `patches/BASE.txt` records it.

## Terms used in this document

- **Non-client (NC) area**: the window zone outside the app's drawing area — title bar, borders, menu band. Live draws its own, which is why so many patches touch it.
- **MWM / Motif hints**: X11 properties that tell the window manager which decorations and buttons a window wants.
- **Frame extents**: the `_NET_FRAME_EXTENTS` X11 property reporting the window manager's frame thickness.
- **Override-redirect**: an X11 window the window manager ignores; Wine uses it for popup menus.
- **DirectComposition (dcomp)**: Microsoft's window-composition API; WebView2 and JUCE plugin editors present through it.
- **Comp buffer / reblit**: the fork keeps a persistent composition buffer per swapchain and re-copies ("reblits") it into the target window on a 200 ms timer. Six patches tune this machinery.
- **Present / swapchain**: a present hands a finished Direct3D frame to the display; the swapchain is the object that owns the frame buffers. `wined3d` is Wine's Direct3D implementation.
- **GDI**: Windows' 2D drawing API; also Wine's fallback present path that copies frames through main memory.
- **DPI awareness context**: the scaling mode a thread uses when reading window metrics. Mismatched contexts misplace frames at fractional display scales.
- **XDG Desktop Portal**: the D-Bus service Linux desktops provide for native file dialogs and file-manager actions.
- **ASIO / PipeASIO**: ASIO is the low-latency audio driver API Live uses; PipeASIO is the PipeWire-native ASIO driver this project ships.
- **PipeWire graph**: PipeWire's processing network. It owns the sample rate and the buffer quantum.

## Windowing and non-client decorations

The largest category. Most entries fight window-growth loops, double frames, or decoration mismatches around Live's custom-drawn frame. Patches 0006 through 0013 are a title-bar experiment series and its reverts; `patches/BASE.txt:27-29` requires applying them in sequence.

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0002 NSPA visible-rect + decoration gates | Moves the window==client check after the style-mask lookup so custom-NC apps still get decoration masking; stops a 4 px/frame growth loop (Wine bug 57955) | stability | Experimental — from nine7nine/wine-nspa-src (`patches/BASE.txt:34-36`) | `notes/ABLETON-WINE-REBASE-11.13.md:21` (bug 57955 open as of 2026-07-17; current status Unverified — bugs.winehq.org was not reachable for re-check) |
| 0003 NSPA 1c frame extents + reentrancy | Frame-extents handling, reentrancy suppression, ncsize guard; fixes the winex11 atom enum order locally | stability | Experimental — nine7nine plus local fix (`patches/BASE.txt:34-36`) | same as 0002 |
| 0004 GNOME per-thread reentrant state | Makes reentrant-WM_WINDOWPOSCHANGED state per-thread (menu wedge race); drops MWM decor for custom-NC windows | stability | Local (`patches/BASE.txt:37-38`); plausibly upstreamable, general reentrancy bug | BASE |
| 0005 no frame allowance for custom-NC | Removes the white rim around Live's modal dialogs | correctness | Local; Live-specific visual fix | BASE |
| 0006 disable frame-extents reconstruction | Stops comdlg32 dialogs landing off-screen at high DPI | stability | Local workaround; later reverted and re-instated by 0008/0009 | `notes/ABLETON-WINE-RESIZE-BUG.md` |
| 0007 clamp top-level size to monitor | Anti-growth clamp for bug 57955; reverted by 0008 | stability | Local experiment, reverted | `notes/ABLETON-WINE-RESIZE-BUG.md` |
| 0008 re-enable frame-extents round-trip | Reverts 0006 and 0007 to converge Live's window feedback via the real WM frame | stability | Local experiment | `notes/ABLETON-WINE-RESIZE-BUG.md` |
| 0009 revert frame-extents re-enable | Undoes 0008: the re-enable reintroduced a strobing white border and did not stop the resize loop | stability | Local revert | `notes/ABLETON-WINE-RESIZE-BUG.md` |
| 0010 captioned tool windows use WM decor | Lets captioned tool windows take WM decorations at high DPI; reverted by 0013 | correctness | Local experiment, reverted | BASE |
| 0011 frame extents for tool windows | Re-enables frame-extents reconstruction for tool windows only; reverted by 0012 | correctness | Local experiment, reverted | BASE |
| 0012 revert of 0011 | Revert | correctness | Revert | BASE |
| 0013 revert of 0010 | Revert | correctness | Revert | BASE |
| 0014 native WM frame for captioned tool windows | Gives plugin editors the native frame and maps the X window to exactly the client area, so the oversized Wine caption is never drawn | correctness | Local; general mechanism, Live-motivated | `notes/ABLETON-WINE-PLUGIN-TITLEBAR-BUG.md` |
| 0015 sync layered attributes on every flush | Forwards color-key/alpha to the scaled surface target each flush; fixes opaque black JUCE shadows | correctness | Local; plausibly upstreamable | `notes/ABLETON-WINE-PLUGIN-TITLEBAR-BUG.md` |
| 0017 real timestamps in _NET_ACTIVE_WINDOW | Sends the last input timestamp; GNOME's mutter drops timestamp-0 activation requests, which wedged menus and focus | stability | Local; flagged upstreamable (`notes/ABLETON-WINE-INPUT-BUG.md:93`) | `notes/ABLETON-WINE-INPUT-BUG.md` |
| 0037 always advertise MWM_FUNC_CLOSE | Keeps Live's close button present while its startup modal disables the main window (KWin) | correctness | Local; upstreamable candidate, general hint behavior | BASE (issue #31) |
| 0039 never flip a mapped window to managed | Refuses the unmanaged-to-managed transition while mapped; stops dropdown unmap/remap flashes and eaten clicks | stability | Local; upstreamable candidate | `notes/ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md` |
| 0053 export minimum tracking size as PMinSize | The WM clamps interactive resizes at Live's minimum, ending the below-minimum drag fight | stability | Local; upstreamable candidate | `notes/ABLETON-WINE-GPU-RENDERER.md` |

## Audio

One Wine patch and the two PipeASIO driver patches. No patch touches Wine's audio streaming paths (winepulse, winealsa audio, mmdevapi buffering).

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0021 mmdevapi FriendlyName re-wrap | Stops wrapping a stored endpoint FriendlyName again on every reload; the multi-level names crashed or hung Live's device enumeration | stability | Local; upstreamable, general bug | `notes/ABLETON-WINE-AUDIO-CRASH-BUG.md` |
| pipeasio 0001 keep graph sample rate | Reports success at the PipeWire graph rate instead of ASE_NoClock; Live treated the refusal as fatal and crash-looped on fresh installs (`patches/pipeasio/0001-asio-keep-graph-sample-rate-instead-of-ASE_NoClock.patch:14-30`) | stability | Experimental — downstream patch to vendored PipeASIO 1.2.2 | `notes/ABLETON-WINE-PIPEASIO.md` |
| pipeasio 0002 timeGetTime systemTime | Reports `timeGetTime()` as the ASIO systemTime so Live stops dropping live-played MIDI as out of window (`patches/pipeasio/0002-asio-report-timeGetTime-in-ASIO-systemTime.patch:17`) | correctness | Experimental — downstream PipeASIO patch | `notes/ABLETON-WINE-PIPEASIO.md` |

## MIDI and input

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0028 winealsa MIDI re-subscribe | Re-subscribes open MIDI ports when a device reappears on the ALSA sequencer | stability | Local; upstreamable | `notes/ABLETON-WINE-MIDI-HOTPLUG.md` |
| 0034 flush XdndStatus replies | Flushes each drag-status reply so a fast source's XdndLeave cannot overtake drop acceptance | stability | From ENCORE (`patches/BASE.txt:59-61`); upstreamable, general X fix | `notes/ABLETON-WINE-ENCORE-REVIEW.md` |
| 0038 keep menu tracking on in-process focus | Sends WM_CANCELMODE only when another client's window actually holds X focus; stops dropdowns closing under mutter/muffin focus shuffles | stability | Local; upstreamable candidate | `notes/ABLETON-WINE-MENU-FOCUSOUT.md` |

## Sync and threading

Two patches, both about the wineserver shared session mapping (a shared-memory region holding window-class objects). No patch touches wait paths, APC delivery, or thread scheduling.

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0018 pre-dirty shared session pages | wineserver memsets grown session blocks so clients fault in real pages; fixes a block-boundary match | stability | Local; upstreamable candidate | `notes/ABLETON-WINE-INPUT-BUG.md` |
| 0019 map session views MAP_SHARED | Maps session views read-write/shared so clients keep seeing server writes; a private mapping lost class registrations and crashed window creation | stability | Local; flagged for upstream review (`notes/ABLETON-WINE-INPUT-BUG.md:93-94`) | `notes/ABLETON-WINE-INPUT-BUG.md` |

## Graphics and GL, including DirectComposition

The second-largest category. It holds the fork's DirectComposition reblit machinery and its two measured present-path wins (0055, 0059).

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0001 sashaduke redraw patchset | Implements dcomp/dxgi frame statistics, refresh-rate-aware WaitForVBlank, refresh-rate fallback in swapchain descs, color-space semi-stubs, `WINED3D_DCOMP_FORCE_FULL_REDRAW`, and cs.c assert relaxations | performance + stability | Experimental — third-party patchset from sashaduke/ableton-live12-linux (`patches/BASE.txt:32-33`) | `notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md` |
| 0016 orphaned dcomp target subclass | Keeps the window's true original wndproc; an orphaned subclass swallowed all mouse input on JUCE D2D editors | stability | Local; flagged upstreamable (`notes/ABLETON-WINE-INPUT-BUG.md:93`) | `notes/ABLETON-WINE-INPUT-BUG.md` |
| 0020 sRGB pixel formats on EGL | Advertises and honors sRGB-capable formats; baseview/nih-plug editors aborted Live without one | stability | Local; upstreamable | `notes/ABLETON-WINE-INPUT-BUG.md` |
| 0022 reblit timer stops forcing Present | Timer ticks signal the frame-latency event and refresh from the comp buffer instead of forcing a Present | performance | Local; experimental, fork-specific reblit design | BASE (`patches/BASE.txt:37-38` range; message at `patches/0022-dxgi-stop-forcing-swapchain-presents-from-the-dcomp-.patch:1`) |
| 0025 suspend reblits for abandoned swapchains | Skips comp-buffer blits after 3 s idle; its idle-abandonment was later removed by 0041 | performance | Local; experimental; partly superseded | BASE |
| 0026 report drawable visual | Fills the real visual in set_dc_drawable/ReleaseDC; fixes the BadMatch crash that shrank OpenGL plugin editors to 1x1 on depth-32 windows | stability | Local; upstreamable | `notes/ABLETON-WINE-GL-PLUGIN-EDITOR-CRASH-BUG.md` |
| 0030 no stale-sized comp-buffer blits | Gates both comp-buffer blit sites on the buffer matching the swapchain's current size | correctness | Local; experimental | `notes/ABLETON-WINE-LEARNVIEW-FLICKER.md` (partial fix per `patches/BASE.txt:46-47`) |
| 0035 Intel Battlemage G21 | Adds the Arc B580 device ID so wined3d stops reporting it as "HD Graphics 4000", a string Live 12 blacklists into the GDI fallback | performance | Local; commit message says "Should also be upstreamed to Wine" (`patches/0035-wined3d-add-Intel-Battlemage-G21.patch` body) | BASE (issue #11, `patches/BASE.txt:62-64`) |
| 0036 suspend reblits on null d2d1 device | Backs off and kills the reblit timer when the d2d1 device never came up; the poll spun a full core (`patches/0036-dxgi-suspend-dcomp-reblits-on-a-null-d2d1-device.patch:9`) | performance | Local; experimental | BASE (issue #16, `patches/BASE.txt:65-67`) |
| 0041 dcomp presents visible on WebView2 targets | Normalizes unattributed layered targets, retries stale resize blits on a 120 ms timer, removes 0025's idle abandonment | stability + performance | Local; experimental | `notes/ABLETON-WINE-LEARNVIEW-FLICKER.md`, `notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md` |
| 0055 prefer GL present for top-level windows | Sets WINED3D_SWAPCHAIN_PREFER_GL_PRESENT on top-level swapchains; the GDI path cost ~650 MB/s and over one core, GL costs ~0.4 MB/s and ~20% of a core (`patches/0055-dxgi-prefer-GL-present-for-top-level-swapchain-devic.patch:10-13`) | performance | Local; experimental, `WINE_DISABLE_GL_PRESENT` kill switch | `notes/ABLETON-WINE-GPU-RENDERER.md` |
| 0056 gate parked reblits on visibility | Skips reblits for parked (hidden-ancestor) WebView2 panes; the stale stamps fought Live's own UI | stability + performance | Local; experimental | BASE (issue #57, `patches/BASE.txt:182-184`) |
| 0057 Intel devices Ice Lake to Lunar Lake | Adds post-2019 Intel GPU IDs so Live stops blacklisting them as HD Graphics 4000 | performance | Local; marked for upstreaming (`patches/0057-wined3d-add-Intel-graphics-devices-from-Ice-Lake-to-.patch` body) | `notes/ABLETON-WINE-GPU-RENDERER.md` (issue #84) |
| 0058 GDI present on client-rect disagreement | Routes a frame to the GDI path when the CS-thread client rect disagrees with the captured destination rect; prevents frames landing low with a black band | correctness | Local; experimental safety gate | `notes/ABLETON-WINE-GPU-RENDERER.md` (issue #100, PR 98) |
| 0059 query flip rect in window's DPI context | Brackets the y-flip's client-rect query like 0023; restores the GL path under fractional scaling (98.9% back to 29.8% of a core, `patches/0059-wined3d-query-the-flip-s-client-rect-in-the-window-s.patch:32`) | performance + correctness | Local; upstreamable, same class as 0023 | `notes/ABLETON-WINE-GPU-RENDERER.md` |
| 0061 describe unlisted GPUs from driver string | Synthesizes the GPU description from the driver's own renderer string instead of guessing a 2010-era card Live blacklists | performance | Local; upstreamable, mirrors the Vulkan backend's behavior | `notes/ABLETON-WINE-GPU-RENDERER.md` (issue #84) |

## DPI and display

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0023 present/resize rects in window's DPI context | Brackets the present-time client-rect queries with the window's own DPI awareness context | correctness | Local; upstreamable | `notes/ABLETON-WINE-PIANOTEQ-DPI-GHOST-BUG.md:32-35` |
| 0024 present/resize DPI diagnostics at trace | Demotes the PRESENT-DBG/RESIZE-DBG probes from fixme to trace | correctness | Local; fork diagnostics, not for upstream | `notes/ABLETON-WINE-PIANOTEQ-DPI-GHOST-BUG.md:37-38` |
| 0029 menu bar SM_CYMENU + 4 | Lays out the menu band 4 px taller so NCCALCSIZE matches Live's outer-rect model at 96 DPI | correctness | Local; Live-specific geometry matching | `notes/ABLETON-WINE-DPI-SCALE-100.md` (per `patches/BASE.txt:43-45`) |
| 0040 scale menu band with menu DPI | Makes the band max(4, muldiv(4, dpi, 96) − 1); the resize negotiation converges in one pass at 125–200% | stability + correctness | Local; Live-specific geometry matching | `notes/ABLETON-WINE-DPI-SCALE-100.md`, `notes/FINDINGS-RESIZE-GROWTH-2026-07-21.md` |
| 0042 alias sub-scale WM config rounding | Treats sub-scale grant/request differences as compositor rounding instead of feeding them to Win32; stops the 2 px/cycle growth and answers in-band requests locally, removing one request per pointer motion during drags | stability + performance | Adapted from ENCORE (`patches/BASE.txt:86-90`); experimental workaround — an upstream *report* is drafted, not a patch | `notes/FINDINGS-RESIZE-GROWTH-2026-07-21.md`, `notes/ABLETON-WINE-DPI-SCALE-100.md`, `notes/ABLETON-WINE-RESIZE-BUG.md`, `notes/UPSTREAM-ISSUE-DRAFT-RESIZE-PARITY.md`, `notes/ABLETON-WINE-ENCORE-REVIEW.md` |

## Portals and desktop integration

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0031 XDG file dialog portal | Adds the portal backend to comdlg32: GetOpenFileName, GetSaveFileName, IFileDialog, SHBrowseForFolder go through native dialogs | correctness | Port of Wine MR !10060 v5 (`patches/BASE.txt:48-51`); the MR remained an unmerged draft as of 2026-07-17 (`notes/ABLETON-WINE-REBASE-11.13.md:19-20`) and Wine's review list still shows it as Draft on 2026-08-01 (https://source.winehq.org/reviews; MR: https://gitlab.winehq.org/wine/wine/-/merge_requests/10060) | `notes/ABLETON-WINE-FILE-PORTAL.md` |
| 0043 reveal /select via OpenURI portal | Routes `explorer.exe /select,"<file>"` to `org.freedesktop.portal.OpenURI.OpenDirectory` | correctness | Local; builds on 0031's portal library | `notes/ABLETON-WINE-SHOW-IN-EXPLORER.md` |
| 0063 reveal /select folders via FileManager1 | Routes folder /select targets to `org.freedesktop.FileManager1.ShowItems`; OpenDirectory is file-only | correctness | Local; same basis | `notes/ABLETON-WINE-SHOW-IN-EXPLORER.md` |
| 0064 route folder-open commands to host | Routes `/e,`, `/root,`, and bare-directory explorer commands to `FileManager1.ShowFolders` | correctness | Local; same basis | `notes/ABLETON-WINE-SHOW-IN-EXPLORER.md` |

## Menus, theming, and fonts

All five serve the native win32 menu chrome that the launcher themes to match Live. Mechanisms are general win32u fixes.

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0049 drop grayed-item engraved bevel | Single-draws grayed menu items in COLOR_GRAYTEXT; the two-pass bevel looked wrong on dark themes | correctness | Bug is upstream ("zero diff from stock Wine", `patches/BASE.txt:115-121`); upstreamable | `notes/ABLETON-WINE-MENU-COLOR-THEMING.md` |
| 0050 invalidate sys-color cache on WM_SYSCOLORCHANGE | Re-reads colors and frees cached brushes/pens when another process calls SetSysColors | correctness | Local; upstreamable | `notes/ABLETON-WINE-MENU-COLOR-THEMING.md:139,226`, `notes/FINDINGS-LIVE-THEME-PREVIEW-SIGNAL-2026-07-26.md` |
| 0051 SetSysColors repaints non-client area | Adds RDW_FRAME to the forced repaint so menu bars and captions follow | correctness | Local; upstreamable | `notes/ABLETON-WINE-MENU-COLOR-THEMING.md:151,227` |
| 0052 hide menu-bar mnemonic underlines | Hides the alt-key underlines real Windows only shows after Alt; also makes the dead DT_HIDEPREFIX flag actually work in user32 | correctness | Mixed: the DT_HIDEPREFIX gating fix is upstreamable; hiding the underlines is a style choice (`patches/BASE.txt:138-148`) | `notes/ABLETON-WINE-MENU-COLOR-THEMING.md:196,228` |
| 0054 linked-font fallback for menu glyphs | Falls back to SystemLink families when the Ableton Sans substitute lacks a glyph; measures with the same fallback font | correctness | Local; experimental — whole-string swap trade-off recorded in the commit message | `notes/ABLETON-WINE-MENU-FONT-FALLBACK.md` |

## Live-specific workarounds

Patches that exist only because of Live's behavior or hardware.

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0032 host USB bridge for Push 2 | Exports the 16-function Win64 libusb 1.0.23 ABI so Push2DisplayProcess.exe drives the Push 2 display through host libusb | stability | Experimental — helper-scoped bridge, i386 half disabled (`patches/BASE.txt:52-55`) | `notes/ABLETON-WINE-PUSH2-DISPLAY.md` |
| 0033 WINE_DISABLE_UNIX_MOUNT_REPARSE | Reports Unix mount points as plain directories; Live's browser omitted folders behind unresolvable junctions | correctness | From ENCORE (`patches/BASE.txt:56-58`); experimental environment-variable workaround | `notes/ABLETON-WINE-ENCORE-REVIEW.md` |
| 0062 keep a selected top-level class offscreen | `WINE_X11_FORCE_OFFSCREEN_CLASS` pins Live's main window class on the offscreen path; M4L track selection no longer unmaps/reparents the whole client (black flash) | stability | Local; experimental — environment variable with an exact class name | `notes/ABLETON-WINE-M4L-SELECTION-FLICKER.md` |

## Misc: shell, OLE, and build maintenance

| Patch | Purpose | Relevance | Origin | Note |
|---|---|---|---|---|
| 0045 reject foreign-process RevokeDragDrop | Returns DRAGDROP_E_INVALIDHWND instead of dereferencing another process's drop-target pointer; fixes the WebView2 plugin-close crash | stability | Ported from giang17/wine `fafb443f85e0`; not in upstream Wine as of 2026-07-24 (`patches/0045-ole32-reject-RevokeDragDrop-for-windows-owned-by-oth.patch:28`), current status Unverified | `notes/ABLETON-WINE-WEBVIEW2-PLUGIN-CLOSE-CRASH.md` |
| 0046 build fix: frame-latency semaphore | Adapts the reblit timer to 11.13's frame-latency-as-semaphore refactor | correctness | Fork maintenance, not for upstream | `notes/ABLETON-WINE-11.11-TO-11.13-BASE-BUMP.md` |
| 0047 build fix: fractional-DPI ratio | Wraps the menu-band DPI math in round_dpi() after 11.13's struct-ratio refactor | correctness | Fork maintenance | `notes/ABLETON-WINE-11.11-TO-11.13-BASE-BUMP.md` |
| 0048 build fix: libusb detection | Checks the cache variable 11.13's AC_CHECK_FUNC actually sets, so the Push 2 bridge builds again | correctness | Fork maintenance | `notes/ABLETON-WINE-11.11-TO-11.13-BASE-BUMP.md` |
| 0060 implement IFileOperation DeleteItem | Implements Live's shared deletion path through the copy engine; Wine's method was an E_NOTIMPL stub | correctness | Local; upstreamable, real implementation of a stub | BASE (`patches/BASE.txt:210-214`, PR 108) |

## Performance measures outside the patch series

These systems already cover performance ground without being Wine patches. Later work must not duplicate them.

| System | What it does | Evidence |
|---|---|---|
| ntsync (kernel fast path for NT synchronization) | The build vendors `linux/ntsync.h` and fails if either runtime half is missing. Without it every NT wait crosses wineserver: ~45% of one core idle and ~9,000 context switches/s; restoring it gave 4–50× synchronization throughput | `notes/ABLETON-WINE-NTSYNC-REGRESSION.md:3-14`, `vendor/ntsync-uapi/` |
| Real-time scheduling | The launcher starts Wine under `SCHED_RR` priority 10 when permitted; PipeASIO requests `SCHED_FIFO` 15 for its data-loop thread | `notes/ABLETON-WINE-RT-SCHEDULING.md:3-5,16-17` |
| Live GPU renderer enablement | `setup-prefix.sh` removes `-_ForceGdiBackend` so Live uses its Direct2D/D3D11 renderer; idle CPU dropped from ~59% of one core to 1–2% | `notes/ABLETON-WINE-GPU-RENDERER.md:8-9,28-29` |
| PipeASIO driver | Native PipeWire ASIO client; replaced WineASIO and removed JACK from Live's audio path in release 2026.07.17.2 | `notes/ABLETON-WINE-PIPEASIO.md:3-4` |
| Ableton Link | Live joins Link through Wine's unmodified network stack; a native daemon (`tools/ableton-linkd.cpp`) holds the session across restarts | `notes/ABLETON-WINE-LINK-FIRSTCLASS.md:11`, `notes/ABLETON-WINE-LINK.md` |
| APC coalescing fix | Proposal only. Unimplemented: the `-DontCombineAPCs` experiment was reverted and current releases strip it | `notes/ABLETON-WINE-APC-COALESCING.md:9,77-79` |
| Tempo ramp timing drift | Investigation open, no fix; ruled out ntsync, scheduling, QPC, and pipeasio 0002 | `notes/FINDINGS-TEMPO-RAMP-2026-07-31.md:3,38-41` |

## Coverage summary

Patch counts per category (64 total: 62 top-level + 2 pipeasio): windowing/NC 18, graphics/GL 16, DPI/display 5, menus/theming 5, portals 4, misc 5, audio 3, MIDI/input 3, Live-specific 3, sync/threading 2.

**Heavily invested areas:**

- **Window geometry at fractional scale.** 23 patches across windowing and DPI fight growth loops, double frames, and resize feedback (Wine bug 57955 lineage plus the 0040/0042 menu-band and rounding work). This is the fork's deepest investment, and it is converged-behavior work, not throughput work.
- **The DirectComposition and present path.** 16 graphics patches, including the fork's own reblit timer design (0022, 0025, 0030, 0036, 0041, 0056) and the two measured CPU/bandwidth wins (0055, 0059). GPU identification (0035, 0057, 0061) exists to keep Live off its GDI fallback.
- **Desktop fit and finish.** Portals (4), menu theming and fonts (5), and explorer integration are well covered and mostly correctness-class.

**Lightly touched or untouched areas:**

- **Sync and threading.** Only 0018/0019, both stability fixes for session shared memory. No patch touches wineserver wait paths, alertable waits, APC delivery, or thread priorities. The APC coalescing fix is an unimplemented proposal (`notes/ABLETON-WINE-APC-COALESCING.md:77`). ntsync coverage is build-level, not a patch (`notes/ABLETON-WINE-NTSYNC-REGRESSION.md`).
- **Audio streaming.** One Wine patch (0021, endpoint naming) plus two PipeASIO driver patches. Wine's audio engines (winepulse, winealsa audio, mmdevapi buffering and event delivery) carry no fork patches.
- **MIDI.** One hotplug patch (0028). MIDI timestamping is covered only inside PipeASIO (pipeasio 0002).
- **Live 11.** The wmvcore media-playback crash is documented with no patch (`notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md:3`).
- **Startup cost, registry, fonts at load, memory use, wineserver protocol volume, and networking.** No patch targets these. Networking is deliberately unpatched (`notes/ABLETON-WINE-LINK-FIRSTCLASS.md:11`).
- **The known tempo-ramp timing divergence** has no fix and no assigned subsystem (`notes/FINDINGS-TEMPO-RAMP-2026-07-31.md:3`).
