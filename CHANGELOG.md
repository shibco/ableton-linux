# Changelog

## Unreleased

- Live's GPU renderer is available on the Intel graphics built into 2015
  through 2019 processors (Wine patch 0066). Wine's device table skipped 24
  of those models, among them the UHD Graphics 630 in the Core i5-8400
  through i7-8700, and reported each as "Intel(R) HD Graphics 4000", so the
  Preferences dialog greyed out "Enable GPU Renderer". Live matches the
  device's ID number, not its name, and the number Wine invents for a model
  it cannot identify belongs to a 2012 part Live refuses. Wine now reports
  the real device.
- Graphics cards missing from Wine's table keep their real identity even when
  the driver reports no video memory (Wine patch 0067). Wine reads that figure
  from an optional graphics-driver feature, and a driver that does not offer it
  used to make Wine report the card under the invented 2012 identity instead.
- Added `WINE_D3D_FORCE_GPU_RENDERING=1`, which offers Live's GPU renderer on
  the older Intel graphics Live refuses by model (Wine patch 0068). Run
  `WINE_D3D_FORCE_GPU_RENDERING=1 ableton-live` to try it. Diagnostics sent to
  Ableton then carry an inaccurate GPU model, and Live's device name marks the
  substitution so Ableton engineering can see it, for example
  "Intel(R) HD Graphics 4000 (reporting as Intel(R) UHD Graphics 630)".

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
  to 1-2%. Some edge cases remain under investigation. See
  [the GPU renderer note](notes/ABLETON-WINE-GPU-RENDERER.md).
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
- Menu colors now follow the desktop theme correctly (issue 35, Wine patches
  0049 to 0052). The menu bar takes the darker chrome color and dropdowns take
  the lighter content color, grayed items lose the engraved bevel,
  `SetSysColors` invalidates the per-process color cache and repaints the
  non-client area, and the menu bar hides its alt-key mnemonic underlines until
  Alt is held. The theme watcher waits on inotify when `inotify-tools` is
  installed and selects the newest `Preferences.cfg` by modification time. A
  live theme switch can still take a few seconds to appear. See
  [the menu color note](notes/ABLETON-WINE-MENU-COLOR-THEMING.md).
- Moved the Wine base from 11.11 to 11.13 (giang17/wine `d2d1-dcomp-11.13` at
  `5c23dd1c`). Wine patches 0046 to 0048 fix the series against 11.13's
  frame-latency, fractional-DPI, and libusb detection changes. The runtime now
  installs to `~/.local/opt/wine-d2d1-nspa-11.13`; the 11.11 directory from
  earlier releases stays on disk and can be deleted, about 380 MB. See
  [the base bump note](notes/ABLETON-WINE-11.11-TO-11.13-BASE-BUMP.md).
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
  matching `RegisterDragDrop`. Fix by Giang Nguyen. See
  [the WebView2 close-crash note](notes/ABLETON-WINE-WEBVIEW2-PLUGIN-CLOSE-CRASH.md).
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
  reports the peer count and tempo. See
  [the Link notes](notes/ABLETON-WINE-LINK.md).
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
- Added Live-themed and system-themed menu colors, Ableton Sans menu text, and
  the `setsyscolors.exe` live refresh helper.

## 2026.07.18.1

- Added experimental Live 11 setup through `ABLETON_LIVE_VERSION=11`.
- Corrected GPU identification for Intel Arc B580 device `0xe20b` (issue 11).
- Stopped DirectComposition re-blits when its d2d1 device failed to initialize,
  including the reported NVIDIA setup under NixOS and `steam-run` (issue 16).
- Added display-scale profiles from 100% to 250% and
  `ABLETON_DPI_MODE=dpi<N>`.
- Added the initial, unverified Link route setup and optional `jack_link`
  launcher integration.
- Added `setup-realtime.sh`.
- Added `-DontCombineAPCs` to reduce an idle Wine thread. Release 2026.07.19.1
  removed it because it broke playback.
- Synced Win32 menu colors to the desktop light or dark scheme.
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
- Added host light and dark menu-color sync.
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
