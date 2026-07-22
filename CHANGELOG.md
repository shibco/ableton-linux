# Changelog

## Unreleased

- Show in Explorer opens your file manager with the file selected, through the same XDG portal the open/save dialogs use, instead of Wine's explorer (issue 41, Wine patch 0043, notes/ABLETON-WINE-SHOW-IN-EXPLORER.md). Wine's explorer stays the fallback when the portal is missing or the portal policy is never. New tool: showexp.c.

- Standalone Max 9 support: a max9 launcher on the shared runtime and prefix, a menu entry with a stable icon, c74max URL handling, and Max for Live devices open with it by default. Installed when Max 9 is present in the prefix; rerun the installer after adding Max. Winemenubuilder entries from a stray default-prefix Max run (they point at stock wine against the patched-runtime prefix) are removed.
- The kit stages learnheal.exe; the 2026.07.21.2 run file omitted it, so kit installs from that release lack the Learn View auto-heal until the next release. Repo installs were unaffected.

## 2026.07.21.2

- Fixed the main-window growth properly. The 2026.07.21.1 fix held for WM tiles, but any interactive resize still grew the window without bound at 125% display scale, 2 px per cycle, until it ran off the screen. Cause, from two traced sessions: at a 2x framebuffer the window manager grants only even physical sizes, Live's per-monitor layout also produces only even sizes, and Wine's frame offset between the two is odd, so each round of the resize negotiation flips parity and no size satisfies both sides. No menu-band constant can converge; 7 px and 8 px at 192 dpi both ratchet. Wine now keeps the Win32 geometry at the requested value when the window manager's reply differs only by sub-scale rounding, and answers sub-scale requests locally instead of forwarding them to X, which also removes the extra request per pointer motion that made drags rough (Wine patch 0042, adapted from ENCORE; notes/ABLETON-WINE-DPI-SCALE-100.md). Verified on Live 12.4.3 at 125%: interactive resizes, tiles and moves settle once and hold.
- The Learn View heals itself. The pane could open as a clipped stale layout and needed a manual splitter nudge once per session. learnheal.exe, installed to ~/.local/share/ableton-wine and started by the launcher, nudges each lesson pane once after its rectangle has been stable for about 3 seconds, re-arms on a material size change, and exits when Live does. The nudge healing the real pane was verified in the 2026.07.21.1 work; the helper's gating was verified against an instrumented stand-in pane.
- New tools: learnheal.c, fakepane.c, livepanes.c, menucmd.c, build_learnheal.sh (also builds posteresize.exe), uidrag.c, ukey.c.
- The installer forces the C locale; localised readelf output made the Push 2 bridge check fail on French systems (issue 36).
- Live documents open from the command line and the file manager. The launcher passes sets, clips and packs straight to the Live exe (issue 38); the previous path relied on associations the prefix does not have. The installer registers the Live file types with icons and makes the menu entry their default handler (issue 40); double-clicking a set opens it in Live.
- The menu entry's name, icon and window class track the installed Live edition instead of always claiming Suite (issue 39). App and file-type icons from pull request 25 by yioannides.

## 2026.07.21.1

- Fixed the main-window growth bug, root-caused this time. Live 12.4.3's window grew continuously after any interactive resize or WM tile at 125% display scale (+1 px per window-manager acknowledgement, self-sustaining, until the window was twice the screen height). The old notes blamed the 2024-era DPI doubling loop, but a full session trace proved that loop dead and showed a constant 1 px disagreement over the menu-bar band: Live's layout model is SM_CYMENU + 4 at 96 DPI and SM_CYMENU + 7 at 192 DPI, not the flat +4 (patch 0029) or scaled +8 (the unreleased 0040 draft) that were tried before. The band law is now max(4, 4·dpi/96 − 1), which matches Live at every scale: WM resizes land pixel-exact and hold, verified on both Live 12.4.2 and 12.4.3 (Wine patch 0040, notes/ABLETON-WINE-DPI-SCALE-100.md, FINDINGS-RESIZE-GROWTH-2026-07-21.md).
- Learn View (Help → Help View) presents now reach the screen, and a healed pane stays healed. Chromium binds the WebView2's DirectComposition swapchain to a layered window that has no GDI surface on Windows (WS_EX_NOREDIRECTIONBITMAP); Wine delivered frames into it anyway, where they were invisible, so what showed was the stale software frame underneath. The target window is normalized at bind time so presents and re-blits land visibly, a one-shot delayed re-blit closes the resize race that could strand a stale frame, and the 3-second idle suspension that reverted every healed pane to the fossil is removed (Wine patch 0041, notes/ABLETON-WINE-LEARNVIEW-FLICKER.md). Known residual: the pane can still open showing the wide-layout fossil band (Chromium lays it out once at a transient creation size, and no Wine-side trigger reliably forces the re-render). Nudge the Learn View splitter once, or run tools/posteresize.exe in the prefix, and it renders correct and stays correct. While the pane is fossilized, the band may shimmer at ~10 Hz instead of sitting static.
- New tools in tools/: posteresize.c (scriptable Learn View heal), metricprobe2.c (DPI frame-metrics dump), xclose.c, uiclick.c.

## 2026.07.19.2

- The real fix for dropdown menus misbehaving under GNOME, Cinnamon and KDE (issue #3). The 2026.07.19.1 focus fix (Wine patch 0038) turned out to cover only the menu bar; the Preferences dropdowns are Live's own popup windows, and Live pokes them while they are open with a window call that is a no-op on Windows but made Wine hand the open popup to the window manager as a normal dialog, mid-click. That handover was the flash on select, the eaten first click, the wobble under GNOME shell extensions, and the phantom "second popup" shadow under KDE. Wine now refuses to change a window's management mode while it is on screen (Wine patch 0039, notes/ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md). Root-caused from a traced live session on GNOME and verified the same way; patch 0038 stays, it covers a separate menu-bar path.

## 2026.07.19.1

- Fix choppy, slowed-down, stuttering audio under PipeASIO after updating to 2026.07.18.1 (issue #29). That release seeded `-DontCombineAPCs` into Live's Options.txt. The option cuts idle CPU, but during playback the uncoalesced APCs flood the wineserver and starve the audio callback. The prefix refresh now removes the line instead of adding it. If you added the line by hand after reading the 2026.07.18.1 changelog, remove it. This supersedes that release's "CPU eating" item: the 30-40% idle CPU thread is back until the fix lands on the Wine side (notes/ABLETON-WINE-APC-COALESCING.md).
- New launcher override: `ABLETON_RT=off` runs Live without realtime scheduling. Some distributions grant realtime rights out of the box, so the launcher's probe can be active without ever running setup-realtime.sh. The override exists for A/B runs and low-core machines (notes/ABLETON-WINE-RT-SCHEDULING.md).
- The build container is now fully pinned: base image by digest, Ubuntu archive by snapshot date, LLVM toolchain by exact version. Between 2026.07.17.3 and 2026.07.18.1 two shipped binaries rebuilt differently with no source change; a rebuild can no longer pick up drifted inputs silently.
- Fixed dropdown menus flashing closed on click, or needing repeated clicks to open, under GNOME, Cinnamon and KDE (issue #3). Those window managers shuffle the X input focus when a menu popup opens; Wine treated the resulting FocusOut as a focus loss and cancelled the menu. The cancel is now only sent when another application really holds the focus (Wine patch 0038, notes/ABLETON-WINE-MENU-FOCUSOUT.md).
- Fixed the missing close button on Live's title bar under KDE (issue #31). Wine omits the Motif close function while a window is disabled, which Live's main window is during its startup modal, and KWin takes the button away for good. The close function is now always advertised; Wine already ignores close requests while the window is disabled (Wine patch 0037).
- New: the unified top bar. Live's menu bar and menus are colored like your Ableton theme (or your desktop titlebar) and rendered with the Ableton Sans typeface from your Live install. A small helper, setsyscolors.exe, repaints the bar mid-session when the Live theme changes; without it the colors apply on the next launch. `ABLETON_TOPBAR_MODE` and `ABLETON_UI_FONT` control or disable all of this (see the README).

## 2026.07.18.1

This one's a big one. Hope I didn't break anything!!!!!

- Live 11 is now supported: `ABLETON_LIVE_VERSION=11` selects the Live 11 winetricks recipe (vcrun2019, gdiplus, win10) during prefix setup and restricts launcher discovery to that major.
- Added support for Intel Arc B580 GPUs (Battlemage G21), and similar cards, previously reported as "Intel HD Graphics 4000", a name Live 12 blacklists into GDI rendering (issue #11).
- More stability for NVIDIA cards - dxgi now stops re-blitting a DirectComposition swapchain whose d2d1 device never came up, e.g. Mesa libEGL without the NVIDIA GLVND config under NixOS/steam-run (issue #16).
- Added support for display scales from 100% to 250%, with the DPI block chosen per compositor family (GNOME tracks mutter's upscaled framebuffer, other desktops get plain application-side DPI) and a new `ABLETON_DPI_MODE=dpi<N>` override.
- Added experimental Ableton Link support: `./scripts/setup-link.sh` sets up multicast routing and the firewall, and the launcher starts the optional jack_link bridge automatically (see the README). I have no idea if this works yet.
- Added `./scripts/setup-realtime.sh`, which installs the distribution-canon pro-audio profile (rtprio limits, swappiness, performance governor) and so grants the realtime scheduling the launcher already probes for.
- Additional fixes for CPU eating, the prefix setup now seeds `-DontCombineAPCs` into Live's Options.txt, removing a steady 30-40% CPU thread that Live's APC coalescing costs under Wine.
- The launcher now syncs the win32 menu colors to the host light/dark scheme, so Live's menu bar no longer stays light in dark mode.
- Fully fixed the Learn View corruption bug, by rendering it through SwiftShader software flags, and added `ABLETON_DCOMP=off` if you have issues with this.
- Prefix now prefers the VC++ redistributable bundled with Live's own installer and skips the repair when the runtime is already intact.
- Added `setup-prefix.sh --post-first-run`, which moves Max for Live 8's stale preferences aside so Max stops crashing on its second start.
- The launcher refuses to guess when several installs of one Live major share a prefix, and prints the discovery list instead.
- The launcher takes a single-instance lock during bring-up, so a concurrent second launch cannot race the wineserver kill and the DPI/theme re-sync.
- The launcher keeps Wine's Mono/.NET and HTML-help hooks out of Live (mscoree/mshtml overrides).
- Groundwork: the launcher exports a capped `WINE_CPU_TOPOLOGY` (8 CPUs, honoring affinity masks), inert until the patched consumer lands.
- Groundwork: `scripts/ableton-profile.sh` is a sourceable product matrix for the ten supported Live products (11/12 x Suite/Standard/Intro/Lite/Trial).
- Documented running Linux-native plugins alongside Live in Carla or Ildaeil over PipeWire.
- The tester kit now ships the ntsyncprobe binary and gained READMEs for the kit and the environment profilers.
- Added `scripts/bench-run.sh` to record paired before/after performance measurements under fixed reference conditions.
- Stupid fucking bug fix: My hard-coded machine-local paths are gone from the repo: probe and tool builds now take `ABLETON_WINE_SOURCE`, the beta prefix default moved to `~/.wine-ableton-beta`, and the beta desktop entry became a template.

## 2026.07.17.3

- Fix dropped MIDI input under PipeASIO. The driver reported ASIO time on the PipeWire graph clock; Live compares MIDI timestamps against it and discarded every event. It now reports timeGetTime, as WineASIO did.

## 2026.07.17.2

- Replace WineASIO with PipeASIO 1.2.2, a native PipeWire ASIO driver. Removed the stale WineASIO entry. Defaults live in ~/.config/pipeasio/config.ini.
- Fixes for regressions in theme support.
- Fixed Webview corruption specific to the Ableton Learn View.
- Added upgrade path for the installer (see the README for details).

## 2026.07.17.1

- Added ntsync. Without it, users reported about a core of CPU in wineserver usage while Live runs. Live now idles at approx 2%-5% of total CPU.

## 2026.07.14.2

- Added the GitHub release pipeline: installers are now built and published by CI.
- The container build now strips debug info and prunes development files from the runtime, shrinking the installer download.
- Simplified the beta environment profilers and tightened report redaction.
- Added the bug-report issue template.

## 2026.07.14.1

- First public release: patched Wine 11.11 (d2d1-dcomp stack plus the 34-patch fix series) with WineASIO 1.3.0 built ABI-matched against the shipped Wine, the ableton-live launcher, the self-extracting installer and the beta tester kit.
- Launchers export WINE_DISABLE_UNIX_MOUNT_REPARSE=1 so Live's browser sees host mount points as plain directories.
- The container build now applies the patch series reproducibly (synthesised git-am headers for header-less patches).