# Changelog

## Unreleased

- Updates replace project-managed launcher and Live menu files when their saved checksums differ (#251).
- CPU optimisation via a provided limit for audio workers with small PipeASIO buffers.

## 2026.08.19.1

- Fixed a slew of problems introduced by redesigning the new Installer too defensively, therefore **breaking it** for lots of people :( :
  - Fixed an issue where a Micros*ft installer bundled with Live 12 would hang after installation and be considered a fatal error by our installer. This caused a perceived hang and crashout, despite the install completing successfully. The installer would then 
    delete the completed install. Even better: on an upgrade it restored the old prefix and
    discarded the new runtime! **lol, lmao even!** Now the installer hunts the Micros*ft installer by name and **terminates it with extreme prejudice**.
  - The installer now asks you to confirm you're ok with it stopping everything running in its Ableton prefix (including Live or Max) before an install or upgrade. Use the flag `--yes`
    to auto-agree in advance.
  - Following a seriously botched attempt by @shibco to be extremely clever, the installer would fail with a baffling 'out of disk space' error during the Live install. This was because @shibco decided it would be cool to **extract the Live install files into RAM before copying said installer to the target directory**. You can't vibe code this clever act. Now, the installer stages the Live payload beside the zip and reuses a completed
  extraction, so no more RAM-dump, and subsequent attempts to install don't waste your time by re-extracting over the top of already-ready files.
  - Updates now replace the Live menu entry the installer manages (#211). Again, too cautious and being concerned that people were **actually editing the desktop file by hand** which is simply not the case.
- Closing Live or Max now brings the whole session down. Custom cleanup code to get around fun Wine shenanigans. Thanks Lucas Gillingham.
- If you run Live via the `ableton-live` terminal command, you can use that terminal again  as soon as Live closes.
- Uninstall keeps a runtime and prefix that a running program still uses, and reports the uninstall as partial.
- Fixed Live crashing while it loads a set that uses a Max for Live gen~ device. **This marks another first for the project:** we are now actually shipping memory management code, lmao. In this case, a large set exhausts the runtime's reserved memory pool, and the device's compiled code then lands too far from its base address and the app crashes out. Now, the runtime grows the pool in order to accommodate this situation. Thanks Lucas Gillingham.
- The Live launcher has cool new flags! Including `--version`, `--help` and `--config`. `--config`
  describes every launcher environment variable and its default, and the launcher warns about unknown arguments. Thanks, Sebastian Thümmel!
- We updated the troubleshooting guide to account for new quirks in the wild and to mitigate some of our egregiously clever code.

## 2026.08.14.3
- **ROLLED OUT THE NEW INPUT SYSTEM ABANDONED IN `2026.08.14.1`!!**
  - Added fine vertical and horizontal scrolling, pinch zoom, and middle-button
    navigation. Middle-button dragging moves the content with the pointer on
    both axes. Holding Ctrl during that drag zooms instead, with a drag towards
    the top of the screen zooming in. A plain middle click remains a click.
  - Scrolling sends fractional movement by default. Selecting the XI2 events it
    needs once made faders and knobs cross their whole range from a small
    movement on XWayland; the held-button repair below stops that, so the
    setting no longer has to be off. `WINE_X11_SMOOTH_SCROLLING=disabled`
    restores whole wheel notches. Found by Lucas Gillingham.
  - Fixed left- and right-button control drags speeding up when a second touch
    starts scrolling. Normal one-finger dragging and middle-button navigation
    remain unchanged.
  - Touchpad scrolling and pinch zoom cannot move a control while a mouse button
    is held. A mouse wheel still works except during middle-button navigation,
    and pressing a button stops earlier continued movement.
  - Added scrolling inertia and middle-drag throw. Both are on by default and
    have separate off switches. Fast releases keep their speed, then movement
    slows gradually. A short or curved middle-button drag can throw. New input
    or a window change stops it. Live does not replay missed movement after a
    pause.
  - Added a repair for fader jumps after loading a Max for Live device. Testing
    on the affected Fedora computer remains open.
  - Fixed faders, sliders and knobs jumping, running ahead of the pointer or
    snapping back on release during left- and right-button drags. While any
    ordinary mouse button is held, Wine now leaves the drag entirely to the X
    server's stock pointer path: no smooth-scroll selection, no XInput2
    reconstruction, no inertia, no pinch, and no coordinate rewrites, on every
    desktop and from the moment Live loads.
  - Added an XWayland repair for faders and knobs that move farther than the
    pointer. It defaults to `auto`, engaging only after Wine observes failed
    warps, and a button release is repaired only when the drag's own motion was.
    Desktop testing remains open.
  - Added `WINE_X11_POINTER_FEATURES=disabled`, a master switch that turns every
    pointer feature off for one launch for baseline comparisons.
  - Named pointer values ignore letter case. `off` and `0` work wherever
    `disabled` works. Invalid settings appear in the normal launch log. 
  - Added a mitigation strategy in response to consistent reports of 
    misbehaving drag inputs on COSMIC. The held-button repair above answers
    those reports: on COSMIC, as on every other desktop, holding a button hands
    the whole drag to the X server.
- **Substantially hardened the new Runtime+Ableton Live installer script:** 
  - Hardened `sudo` password requests in the rare case that the installer
    requires admin privileges.
  - When asking for `sudo` privileges, the installer waits 120 seconds for your
    password, then stops and tells you that it timed out.
  - A failed install no longer reports that it could not undo itself when it did.
  - A failed install will now reliably write the reason its recovery failed into 
    `rollback.log`, next to the failure record.
  - The installer checks every file it copies into your menus before it changes
    anything.
  - If you have an Ableton Live or Max desktop file from some other Wine project, 
    the installer now won't make assumptions and 'helpfully' remove it.
  - For safety reasons, the real-time setup now checks `ABLETON_RT_GROUP` before 
    it completing setup. It will reject a user group that grants more than audio 
    access.
  - `installer update` and `installer prefix update` will now tell you what it is
    actually missing when it can't find a runtime, prefix or component.
- Revised the `uninstall` command in the installer script. Uninstall now:
  - properly clears the file types and links it registered.
  - recovers old file types that you assigned yourself.
  - tells you when it encounters a file it does not recognise.
- The Ableton Link portion of the installer has also been hardened since its
  redesign:
  - The Ableton Link service will now start on computers that don't have systemd 
    user service. You only need systemd if you plan leaving `ableton-linkd` running
    in the background even when Live isn't running.
  - `installer link enable` now installs every file that
    `~/.local/share/ableton-wine/setup-link.sh` needs to run, even if installing
    separately to Live.
  - `installer link status` will let you query the state of the Link install process
    while an install, update, or uninstall runs.
  - Stopping the Link daemon waits for the lock the launcher uses, so starting
    Live during an install cannot leave a daemon behind. (Thanks Lucas Gillingham!)
  - Similar to the `sudo` hardening above, Link setup will now actually tell you
    why it needs your password for any `sudo` command.
  - Real-time setup detects attempts to run blindly as root. 

## 2026.08.14.2

- Registering the audio driver no longer reports failure after it succeeded.
  Windows `reg` ends its lines with a carriage return, which the check did not
  strip, so the CLSID never matched. Fix by Lucas Gillingham.
- README and TROUBLESHOOTING match the commands the installer actually takes.

## 2026.08.14.1

- The original installer was written at a time where the potential of this
  project was unfathomable. Completed a complete rewrite of the installer:
  - The installer can update individual parts, restore the previous runtime, and
    remove files while preserving user changes.
  - Link setup retries after an incomplete service step.
  - A failed install or update now restores the saved installer and PipeASIO
    configuration as well as the previous runtime.
  - The single-file installer includes audio reporting, real-time setup, and
    rollback tools.
  - Official packages now require a completed ThreadSanitizer run. Local builds
    that skip a recognised ThreadSanitizer startup limitation cannot be released.
  - Release checks now reject incomplete patch lists and mismatched build,
    runtime, or installer records.
  - The session power setting now stays active when Live starts from an
    `ableton://` URL or an `.auz` file.
  - An unresponsive power service no longer stalls Live's launch.
  - The real-time setup removes the boot-time CPU setting used by earlier
    releases.
  - `ableton-linkd` rejects fractional linger values instead of treating them as
    a request to stay open forever.
  - Closing a file dialog with the titlebar X or Escape now cancels it instead
    of opening Wine's own dialog (issue 146). Affected Mint 22 and Ubuntu
    24.04.
  - Live no longer shows two icons in the taskbar. The launcher now takes the
    name, icon and window class from the version it finds. Entries you wrote
    yourself are left alone.
  - The desktop entries describe Live in plain words instead of naming the
    build's internals.
  - Fixed the beta launcher's icon.
- Completed a substantial upgrade to the Ableton-Linux audio system:
  - Updated the audio driver from PipeASIO 1.2.2 to 1.5.0.
  - The installer and audio driver now require PipeWire 1.4.2 or newer.
  - Enabled the ability to use every buffer size from 32 to 8192 frames.
  - Live now pauses audio while it changes to the PipeWire buffer size used by 
    another audio programme, then resumes at the correct speed.
  - Any sample rate accepted by Live is now retained after the audio engine 
    restarts.
  - MIDI timestamps continue across a 49.7-day timer wrap while audio is running.
  - PipeASIO Settings ships with the runtime and can be accessed from applications
    (eg in Live's Settings -> Audio, Hardware Config).
  - PipeASIO real-time scheduling is off by default. Its environment override now
    accepts `1/0`, `true/false`, `yes/no`, `on/off`, and `enabled/disabled`.
- Attempted (and aborted) an ambitious and optimised input Wine patch.
  (see `2026.08.14.3`):
  - .... :(
- Completed the first part of a multi-stage performance moonshot:
  - Unlocked Live's GPU renderer on Intel GPU chipsets built into 2015
    through 2019 processors (Wine patch 0066). Wine's device table skipped 24
    of those models, and reported every one of them to Ableton Live as a 2012
    Ivy Bridge chipset that Live refuses to use.
  - Graphics cards missing from Wine's device table keep their real identity
    even when the driver reports no video memory, instead of falling back to
    that refused 2012 model (Wine patch 0067).
  - Bypassed Live's GPU deny-list, that specifically contained a GPU chipsets
    with terrible closed-source Windows drivers (thanks, Microsoft and Intel!!)
    but have good Linux support. We do this by lying to Live's deny list,
    reporting a device ID that is not on it. Live reads the ID alone when it
    decides, so your card keeps its real name and carries the reported one
    alongside it. For affected machines, this is the first time you can run Live
    with GPU acceleration, providing a noticeable performance boost.
  - Added `WINE_D3D_FORCE_GPU_RENDERING=1` to enable the above GPU denylist
    bypass (Wine patch 0068). In crash logs, we tell Ableton's engineering team
    that the GPU listed in the crash log is substituted, to avoid poisoning
    Ableton's QA team data set.
- The launch log now warns when a drawing fault holds Live on the slow copy
  path, which costs about one core of CPU with nothing on screen to show it
  (issue 100 follow-up, Wine patch 0071).
- **Completed an entirely custom and open-source font anti-aliasing renderer for
  Wine applications**:
  - Experimental ClearType-style subpixel rendering is now available to
    DirectWrite, Direct2D and GDI text. Prefix setup enables it by default and
    follows the desktop's RGB/BGR order; set `ABLETON_TEXT_SMOOTHING=grayscale`
    for deliberate greyscale rendering or `preserve` to leave an existing
    prefix policy untouched. An explicitly disabled `FontSmoothing=0` is never
    overwritten by the launcher.
  - Added standalone DirectWrite, Direct2D and GDI probes for checking the text
    path without launching Live. The ClearType texture probe uses an outline
    size and compares each RGB coverage triple, so symmetric filtering no longer
    produces a false greyscale verdict.
  - Added a downstream `DesktopUIFont` integration hook for changing Wine's
    semantic desktop UI stock font without globally substituting Tahoma.
    This means that applications (including Live) launched in this runtime
    will render with your DE's interface font.

- Significantly revised window management, logic and user interface behaviour:  
  - A Live window sized to fill the monitor can be resized again (Wine patch
    0069). `WINE_WIN32_RESIZABLE_CLASS=off` turns the fix off.
  - Completed a full pass over Live's keyboard shortcuts, meaning Live now
    responds exactly as expected to keyboard shortcuts. (Wine patch 0070).
    For system shortcuts especially, the runtime now catches those before the DE
    but will give them back on exit. Run 
    `env ABLETON_SHORTCUTS=take ableton-live` to enable this feature.
  - An application can maximise its own window while a startup dialog holds it
    disabled (Wine patch 0077).
  - Windows open at the size they ask for on per-monitor-aware applications
    (Wine patch 0078). Wine 11.13 sized them at a quarter of the request.

- Shaved about two seconds off Live's startup time by focusing on specific
  Max 4 Live startup optimisations. (Wine patch 0096). In this case, Max 4 Live's
  startup forces the system to re-read every host font on every launch.  
  We now cache this in the prefix and re-run when your font directories (eg 
  `~/.fonts`) change. `env WINE_DISABLE_HOST_FONT_CACHE=1` turns the cache off.
- Fixed three missing entry points that ended a plugin or helper process
  outright (Wine patches 0075, 0076 and 0080). Patch 0080 implements the four
  entry points beside it as well, which belong to the same lifecycle and would
  each have ended the process in turn.
- Fixed an application scanning every window on the desktop twice a frame
  while it drew its interface (Wine patch 0079).

## 2026.08.04.1

- Full Screen works (issue 42). Entering it no longer shifts Live's
  content or makes clicks land away from their targets, and leaving it no
  longer keeps the fullscreen image on screen until the window is moved.
  Contributed by trendwhore.
- The Live 12 installer now runs by itself during setup: no clicking
  through its window, and it skips Ableton's Windows-only USB audio
  driver. Live 11 ships a different installer that ignores the same
  instructions, so it still opens its window; click through it as before.
  Telling the two installers apart is by Lucas Gillingham.
- Setup no longer stops at a "Wine Mono Installer" window. Live does not
  use Mono, so setup turns it off and Wine stops asking; unattended
  installs no longer hang there. Fix by Lucas Gillingham.
- Installing Live 11 no longer shows two "Program Error" windows (issue
  111). A helper of Ableton's installer fails in a way that changes
  nothing, and the install was always fine; the alarming windows are gone.
  Fix by Lucas Gillingham.
- Updating while Live is running now works. The updater used to refuse
  and ask you to close Live and rerun; it now closes everything the old
  version left running, and asks first when Live itself is open, since
  closing Live discards unsaved work. Pressing Ctrl-C during an update
  now puts the previous version back, or reports that nothing was
  changed. Confirmation and safeguards by Lucas Gillingham.
- Updates to ableton-linkd apply immediately. The updater now restarts
  it, so the old copy no longer keeps running until the computer
  restarts.
- ableton-linkd now writes a log line only when something changes: an
  app joining or leaving the Link session, a tempo change, or play and
  stop. The status line it repeated every 10 seconds filled the system
  log and made a healthy process look stuck; `--verbose` brings it back.

## 2026.08.01.1

- Live's GPU renderer is available again on Intel graphics newer than 2019
  (issue 84, Wine patch 0057). Wine reported every Intel GPU from Ice Lake
  through Lunar Lake, and the Arc A-series cards, as "Intel(R) HD Graphics
  4000", a 2012 device that Live refuses to use, so the Preferences dialog
  greyed out "Enable GPU Renderer". Wine now reports the real device names.
  Reported by stickyfran.
- Fixed Live's frame drawn too low under fractional display scaling, a black
  band on top and the bottom rows clipped (PR 98, issue 100, Wine patches
  0058 and 0059). The frame's destination rectangle was captured in the
  window's DPI context, but the present-time blit re-queried the client rect
  in the render thread's context, and at 125% or similar scaling the two
  disagreed by the difference. Both queries now run in the window's DPI
  context, and any frame where they still disagree takes the GDI path, which
  renders correctly under the mismatch. Reported by v33 and NoskyD.
- GPUs missing from Wine's device table now report their real names (Wine
  patch 0061). Unlisted cards fell back to a guess from the OpenGL feature
  level, so a Radeon RX 7900 XT was reported as "ATI Radeon HD 5600 Series"
  and newer Intel GPUs as "Intel(R) HD Graphics 4000". The name, PCI IDs and
  video memory now come from the driver's own report, as the Vulkan backend
  already does. Contributed by Lucas Gillingham.
- Fixed Live freezing when loading certain Max for Live devices: window
  black and unresponsive, audio still playing. Devices authored on macOS
  name fonts that do not exist here, and Max's own last-resort fallback is
  Bitstream Vera, which neither Wine nor Live nor modern distributions
  ship, so Max parked Live's UI thread waiting for a font that never came.
  The Bitstream Vera faces are now vendored, installed and registered by
  prefix setup. Diagnosis and fix by Lucas Gillingham.
- Fixed a black flash of Live's whole window when selecting away from and
  back to a Max for Live track under Xwayland (Wine patch 0062). The M4L
  device view's child window toggled Live's client surface between two
  rendering paths, and each toggle unmapped and remapped the full client
  window mid-frame. The launcher now keeps Live's top-level window on the
  offscreen-composited path (`WINE_X11_FORCE_OFFSCREEN_CLASS`). Contributed
  by trendwhore.
- Non-Latin menu text renders correctly (issue 35, Wine patch 0054). Live's
  menus use its own Latin-only fonts, so Cyrillic, CJK and other non-Latin
  menu items, project names and track names showed as boxes or nothing.
  Menu drawing now falls back to a linked font for missing glyphs, and
  prefix setup registers a glyph fallback chain for Live's fonts.
  Contributed by Lucas Gillingham.
- mp3 and video import works again (issue 44). The build silently dropped
  Wine's GStreamer support when the GStreamer development packages were
  missing from the build image, so Live's import path had no decoder and
  failed without an error message. The build and the installer now fail
  loudly when the component is missing, and GStreamer with its base and
  good plugin sets joins the runtime requirements.
- Deleting files from Live's browser works (Wine patch 0060). Live deletes
  through `IFileOperation::DeleteItem`, which Wine left unimplemented, so
  browser deletion and the pruning of old project backups failed. Deletes
  now run through Wine's existing file operation engine and keep the
  recycle-bin behaviour.
- "Show in Explorer" on a folder opens the desktop file manager (issue 41,
  Wine patches 0063 and 0064). Folder targets went through the OpenURI
  portal's OpenDirectory method, which is defined for files, so on the
  reported setups the reveal fell back to Wine Explorer, and the library
  panel's folder-open form (`explorer.exe /e`) was never intercepted at
  all. Reveals now call `org.freedesktop.FileManager1.ShowItems`, which
  opens the parent folder with the target selected, and folder opens call
  `ShowFolders`, which opens the folder itself; the portal and Wine
  Explorer remain the fallbacks. File targets are unchanged.

## 2026.07.29.1

- Live now uses its GPU renderer. Prefix setup removes the legacy
  `-_ForceGdiBackend` line from `Options.txt` (step 5c). This removes the
  Learn View and Splice view flicker in the measured cases and drops idle CPU
  to 1-2%. Some edge cases remain under investigation.
- Fixed windows fighting an interactive resize below the app minimum
  (Wine patch 0053). winex11 now exports the `WM_GETMINMAXINFO` minimum
  as the X11 `PMinSize` hint, and the window manager stops the drag at
  the minimum.
- Fixed high CPU use and display traffic with the GPU renderer (issue 91,
  Wine patch 0055). Wine copied every finished frame of Live's main window
  from the graphics card back into main memory and sent it to the display
  server as a full image, about 650 MB per second during continuous UI
  activity such as mouse movement. Wine now shows finished frames directly
  from the graphics card. Set `WINE_DISABLE_GL_PRESENT=1` to restore the
  previous behaviour. Diagnosis and measurements by Lucas Gillingham.
- Fixed the flicker left behind in the Learn View's rectangle after the pane
  closes (issue 57, Wine patch 0056). Live parks the WebView2 pane rather than
  destroying it, so Wine kept stamping the last captured frame into the closed
  pane's area at timer cadence. DirectComposition re-blits now stop while the
  target window's ancestor chain is hidden. Reported by jttdev, reviewed by
  Giang Nguyen.
- Menu colours now follow the desktop theme correctly (issue 35, Wine patches
  0049 to 0052). The menu bar takes the darker chrome colour and dropdowns take
  the lighter content colour, greyed items lose the engraved bevel,
  `SetSysColors` invalidates the per-process colour cache and repaints the
  non-client area, and the menu bar hides its alt-key mnemonic underlines until
  Alt is held. The theme watcher waits on inotify when `inotify-tools` is
  installed and selects the newest `Preferences.cfg` by modification time. A
  live theme switch can still take a few seconds to appear.
- Moved the Wine base from 11.11 to 11.13 (giang17/wine `d2d1-dcomp-11.13` at
  `5c23dd1c`). Wine patches 0046 to 0048 fix the series against 11.13's
  frame-latency, fractional-DPI, and libusb detection changes. The runtime now
  installs to `~/.local/opt/wine-d2d1-nspa-11.13`; the 11.11 directory from
  earlier releases stays on disk and can be deleted, about 380 MB.
- The installer now configures Ableton Link during installation. Setup no
  longer adds a multicast route or NetworkManager hook: the Link SDK selects
  its interfaces itself. `sudo` is used to open UDP port 20808 when UFW or
  firewalld is active, and on existing installs to remove the old hook and
  route during one setup re-run. `--no-link` skips the step and is
  remembered on later runs; `--link` opts back in.
- The README now covers installation and ordinary use. Troubleshooting, source
  builds, configuration overrides, and maintainer material have dedicated
  documents. The credits name the giang17/wine `d2d1-dcomp` stack this project
  builds on.
- Added a repository Code of Conduct.
- Fixed a Live crash when closing WebView2 plugin editors (issue 52, Wine
  patch 0045). `RevokeDragDrop` now rejects windows owned by another process,
  matching `RegisterDragDrop`. Fix by Giang Nguyen.
- `build.sh` now creates `dist/ableton-linkd`. Installer packaging calls the
  same Podman helper when that artifact is absent or not executable. The
  helper builds against the vendored Ableton Link SDK.
- Fixed Live installers failing on non-ASCII Max filenames under the `C`
  locale (issues 51 and 55). Setup now uses `C.UTF-8`. The fault affected only
  fresh installer runs.
- Prefix setup now shows the failing command and exit status when winetricks
  fails (issue 28).
- `scripts/release.sh --notes-file <path>` places a hand-written summary at the
  top of the GitHub release body, above the install instructions and build
  provenance the workflow generates. The file is read at publish time and is
  committed nowhere.
- CI builds Wine on pull requests that touch the runtime, using ccache.

## 2026.07.23.1

- Added built-in Ableton Link support. `ableton-linkd` is a passive native peer
  that remains in the session while Live restarts. `ableton-linkd --probe 10`
  reports the peer count and tempo.
- Added `linkprobe.exe` to test Wine multicast on UDP port 20808 without Live.
- Shipped `setup-link.sh`. It configures the multicast route, adds a UDP 20808
  allowance when UFW or firewalld is installed, installs a NetworkManager hook
  when its dispatcher directory exists, and enables `ableton-linkd.service`
  when its files are present.
- Added COSMIC display-scale detection. Contributed by ClickSentinel in pull
  request 54.

## 2026.07.22.1

- Show in Explorer now opens the host file manager when the XDG portal accepts
  the request (issue 41, Wine patch 0043). Wine Explorer remains the fallback.
- Added a Max 9 launcher, desktop entry, `c74max` URL handler, and Max for Live
  file association.
- Added the missing `learnheal.exe` to the installer kit.
- PipeASIO now registers without a `regsvr32` dialog. Contributed by jackson-57
  in pull request 37.

## 2026.07.21.2

- Fixed unbounded main-window growth during interactive resize at 125% scale.
  Wine now returns the requested Win32 geometry when the host grant differs
  only by sub-scale rounding (Wine patch 0042).
- Added `learnheal.exe` to repair a clipped Learn View after its layout settles.
- Added `learnheal.c`, `fakepane.c`, `livepanes.c`, `menucmd.c`,
  `build_learnheal.sh`, `posteresize.exe`, `uidrag.c`, and `ukey.c`.
- Set the installer locale to `C` so localized `readelf` output could not break
  the Push 2 check (issue 36). This was changed to `C.UTF-8` after issues 51
  and 55.
- The launcher now accepts Live documents from the command line (issue 38).
  The installer also registers Live file types and icons (issue 40).
- Desktop entry names, icons, and window classes now match the installed Live
  edition (issue 39). Icons were contributed by yioannides in pull request 25.

## 2026.07.21.1

- Corrected Live's menu-band size model at 96 and 192 DPI (Wine patch 0040).
  This fixed tiling but did not fix every interactive resize. Release
  2026.07.21.2 addressed the remaining parity loop.
- Changed Learn View's DirectComposition handling so current frames reach the
  screen (Wine patch 0041). A one-pixel splitter resize was still needed when
  Chromium opened the pane with a stale layout.
- Added `posteresize.c`, `metricprobe2.c`, `xclose.c`, and `uiclick.c`.

## 2026.07.19.2

- Fixed Live dropdown windows changing from unmanaged popups to managed
  dialogs while open (issue 3, Wine patch 0039). That transition caused lost
  clicks, flashes, and duplicate shadows.

## 2026.07.19.1

- Removed `-DontCombineAPCs` from `Options.txt`. The option introduced slow and
  broken playback in 2026.07.18.1 (issue 29).
- Added `ABLETON_RT=off` for normal-scheduling comparisons and low-core hosts.
- Pinned the base image, Ubuntu archive snapshot, and LLVM version used by the
  build.
- Fixed menu cancellation after transient X11 focus changes (issue 3, Wine
  patch 0038).
- Kept the close button on Live's title bar while its startup modal is open
  under KDE (issue 31, Wine patch 0037).
- Added Live-themed and system-themed menu colours, Ableton Sans menu text, and
  the `setsyscolors.exe` live refresh helper.

## 2026.07.18.1

- Added experimental Live 11 setup through `ABLETON_LIVE_VERSION=11`.
- Corrected GPU identification for Intel Arc B580 device `0xe20b` (issue 11).
- Stopped DirectComposition re-blits when its d2d1 device failed to initialise,
  including the reported NVIDIA setup under NixOS and `steam-run` (issue 16).
- Added display-scale profiles from 100% to 250% and
  `ABLETON_DPI_MODE=dpi<N>`.
- Added the initial, unverified Link route setup and optional `jack_link`
  launcher integration.
- Added `setup-realtime.sh`.
- Added `-DontCombineAPCs` to reduce an idle Wine thread. Release 2026.07.19.1
  removed it because it broke playback.
- Synced Win32 menu colours to the desktop light or dark scheme.
- Changed Learn View to use SwiftShader and added `ABLETON_DCOMP=off`.
  Later releases refined the Learn View fix.
- Reused Live's bundled VC++ redistributable when it was already valid.
- Added `setup-prefix.sh --post-first-run` for the Max 8 preferences crash.
- Refused ambiguous launcher selection when one prefix contains several
  editions of the same Live major.
- Serialized launcher setup to prevent concurrent prefix changes.
- Disabled Wine's Mono and HTML-help hooks for Live.
- Added a capped `WINE_CPU_TOPOLOGY` value for future runtime support.
- Added `scripts/ableton-profile.sh` for the Live 11 and 12 product matrix.
- Documented Linux-native plugins routed through PipeWire.
- Added `ntsyncprobe`, beta test documentation, and `scripts/bench-run.sh`.
- Removed machine-specific paths from probe builds, the beta prefix, and the
  beta desktop entry.

## 2026.07.17.3

- Fixed dropped MIDI input under PipeASIO. The driver now reports
  `timeGetTime`, matching the clock Live uses for MIDI timestamps.

## 2026.07.17.2

- Replaced WineASIO with PipeASIO 1.2.2.
- Added host light and dark menu-colour sync.
- Added the installer's `--update` mode.

## 2026.07.17.1

- Added ntsync. This reduced reported wineserver idle CPU use.

## 2026.07.14.2

- Added CI jobs that draft releases and verify locally built release assets.
- Stripped debug data and removed development files from the runtime.
- Simplified beta environment reports and tightened redaction.
- Added the bug-report issue template.

## 2026.07.14.1

- Published the first release with Wine 11.11, the d2d1-dcomp stack, 33 Wine
  patches, one WineASIO patch, WineASIO 1.3.0, launchers, installer, and beta
  kit.
- Set `WINE_DISABLE_UNIX_MOUNT_REPARSE=1` so Live treats host mount points as
  directories.
- Made patch application reproducible with synthesized `git am` headers.
