# Changelog

## 2026.07.19.1

- Fix choppy, slowed-down, stuttering audio under PipeASIO after updating to 2026.07.18.1 (issue #29). That release seeded `-DontCombineAPCs` into Live's Options.txt. The option cuts idle CPU, but during playback the uncoalesced APCs flood the wineserver and starve the audio callback. The prefix refresh now removes the line instead of adding it. If you added the line by hand after reading the 2026.07.18.1 changelog, remove it. This supersedes that release's "CPU eating" item: the 30-40% idle CPU thread is back until the fix lands on the Wine side (notes/ABLETON-WINE-APC-COALESCING.md).
- New launcher override: `ABLETON_RT=off` runs Live without realtime scheduling. Some distributions grant realtime rights out of the box, so the launcher's probe can be active without ever running setup-realtime.sh. The override exists for A/B runs and low-core machines (notes/ABLETON-WINE-RT-SCHEDULING.md).
- The build container is now fully pinned: base image by digest, Ubuntu archive by snapshot date, LLVM toolchain by exact version. Between 2026.07.17.3 and 2026.07.18.1 two shipped binaries rebuilt differently with no source change; a rebuild can no longer pick up drifted inputs silently.

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