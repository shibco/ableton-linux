# Max 9 on Wine: research source catalog

Date: 2026-08-05. This file is source material for MAX9-STABILITY-2026-08-05.md. It keeps the original technical form and the links. Read the main document first.

---

Compiled 2026-08-05 from Cycling '74 forums, Reddit (via Arctic Shift), WineHQ AppDB/bugzilla, GitHub, and blog reports. Confidence labels: [confirmed] = firsthand user report(s); [secondhand] = summarized/relayed claim; [speculation] = inference, no direct report.

Coverage notes:
- WineHQ AppDB: effectively dead for Max. Only entries: Max/MSP 4.6.3 Runtime (ancient, PACE era) and a Max 8.15 version entry (iId=38431) whose test result concerns the file browser failing until a stray system libcef.dll was removed. No Max 9 entry exists.
- Wine bugzilla: no bugs filed against Max.exe/Cycling '74 specifically. Relevant generic bugs: 21232 and 39403 (Chromium sandbox incompatible with Wine, use --no-sandbox), 38960 (CEF apps, winver-XP workaround, old), 37797 (CEF/V8 crash when Arial is Liberation-substituted, install corefonts).
- Master threads (each spans 2016 to 2026):
  - https://cycling74.com/forums/max-on-linux (replies/2, replies/3, ?replyPage=4)
  - https://cycling74.com/forums/max-from-windows-to-linux-wine-for-realtime-sound-processing (+ /replies/1)
  - https://cycling74.com/forums/max-9-installer-hanging-under-wine-caculating-disk-space
  - https://reddit.com/r/MaxMSP/comments/17qjet3/max_on_linux/ (2023 post; key Max 9 report in comments 2026-02-20)
  - https://roosnaflak.com/tech-and-research/run-max-msp-on-arch-linux.html (2022-02-04, Max 8.1.11)

Big picture: Max 8 under wine-staging (with full VC redists) reached "runs perfectly / 95% functionality" consensus by 2019. Max 9 is more Wine-hostile than Max 8 per multiple reports; successes exist (CachyOS+KDE, Manjaro+Crossover 26, Debian+Bottles+GE-Proton11-1, all late-2025/early-2026) but licensing is the recurring wall. Max's UI platform is JUCE. Max 9 ships CEF 122 (9.0.0) then CEF 135 (9.1.0), V8 JS objects, and gen~/RNBO compile in-process via bundled LLVM/Clang JIT.

## DEALBREAKERS

### D1. License activation / sign-in fails (CEF + TLS chain), the #1 Max 9 blocker
- Licensing is in-app: Help > User Account and Licenses, CEF-rendered. Internet required to authorize; perpetual license = 180 days offline, subscription = 30 days. Ref: https://support.cycling74.com/hc/en-us/articles/360049995834-Max-7-9-Authorization
- [confirmed] Max 9 + wine-staging 11.2 (Lutris, CachyOS, KDE Wayland, 2026-02-20): stable except "License activation / License Manager not working" (reddit 17qjet3 comment o6h5b08).
- [confirmed] Max 9 License Manager crashes with "network change notifier" errors; resolved by newer GE-Proton (10-27/10-34 era) (max-on-linux?replyPage=4).
- [confirmed] Max 8 auth: "handshake failed; SSL error code 1, net_error -207"; workaround `wine Max.exe --disable-web-security --ignore-certificate-errors` then sign-in succeeds (max-on-linux/replies/3).
- [confirmed] Max 8 trial reauthorization needs working jweb/CEF ("CEF missing" in console = auth impossible); fresh clean prefix fixed it.
- [confirmed] Max 8.1.11 auth dialog: text input invisible, clipboard broken; workaround: toggle virtual desktop off during auth, right-click-paste password (roosnaflak.com).
- [confirmed] Working: Manjaro + Crossover 26.0 + Max 9.1 incl. license; Linux Mint + Proton "license authentication possible after a few attempts".
- iLok escape hatch not viable: PACE historically hard-blocks Max under Wine.

### D2. Autocomplete/focus-steal typing bug, patching unusable
- [confirmed, many reports 2022-2026] typing one letter into a new object box instantly selects the first completion and commits it. WM-dependent.
- Workarounds [confirmed]: KDE KWin focus-protection rule; winecfg "Allow the window manager to control the windows" unticked (KDE/XFCE); GNOME `gsettings set org.gnome.desktop.wm.preferences focus-new-windows 'strict'` suggested, but replies/3 states "no confirmed solution for GNOME/Wayland"; Wine virtual desktop (conflicts with our first-class-window policy); type in external editor and paste.
- Counter-report: CachyOS + KDE Plasma 6 Wayland + wine-staging 11.2: autocomplete works out of the box (2026-02-20).

### D3. Max 9 MSI installer hangs at "calculating disk space" (+ GNOME kills it)
- [confirmed] Max 9.03 installer hangs on disk-space calculation; Ubuntu/GNOME force-quit prompt kills it (cycling74 forum thread above).
- Workarounds [confirmed]: wait + `gsettings set org.gnome.mutter check-alive-timeout 120000`; administrative extraction `msiexec /a Max903.msi /qb TARGETDIR=...` then move runtime DLLs.
- Related [confirmed]: post-install generated launcher unreliable; point the launch target at Max.exe directly, never the .msi.

### D4. umenu / popup-menu crash class
- [confirmed, historical] Max 7: clicking any umenu dropdown = page fault, instant crash, consistent across distros/GPUs/Wine 2.x-9.23.
- Resolved in Max 8 on wine-staging with full VC redists. But one Max 9-in-Bottles report says "umenu object non-functional, unresolved" (replyPage=4).

### D5. Whole-UI failure modes: black UI / frozen GUI
- [confirmed] "UI goes black and stays that way, program still running underneath" (Max 7 era, GPU mismatch).
- [confirmed] GUI frozen on Debian + Wayland; workaround: X11 session or older GE-Proton.
- [confirmed] Intel HD 5500 + DXVK: startup failures; disable DXVK on iGPU, use wined3d GL.
- [secondhand] "Wayland rendering glitches on some setups".

### D6. Wine-version sensitivity / regressions (meta-issue)
- [confirmed] strong version-lock culture: wine-staging 4.21 golden for Max 8; Max 9 "worse compatibility on newer Wine"; several users stuck on Max 8; distro wine builds repeatedly reported broken.
- Known-good recent configs [confirmed]: wine-staging 11.2 minus licensing; GE-Proton 10-27/10-34 incl. License Manager; Crossover 26.0 full stack; Bottles + ge-proton11-1 + vcredist2022 + esync (Max 9.1.3, Jan 2026; recipe includes "install FL Studio first", 160-180 DPI scaling).

## MAJOR

### M1. All CEF surfaces: Package Manager, File Browser, in-app docs, Welcome window, jweb/jweb~
- Max 9.0.0 ships CEF 122.1.13; 9.1.0 ships CEF v135. Bundled at resources/support/CEF/.
- [confirmed] Package Manager / File Browser: black or blank screens, "connection refused", install failures; file browser dead until stray system-wide libcef.dll deleted.
- [confirmed] "CEF missing" console error = jweb dead = auth dead.
- [confirmed, minor variant] Package Manager renders but UI hit-targets offset (webview scaling); buttons still clickable.
- Wine-generic CEF facts: Chromium sandbox incompatible (bugs 21232/39403) so --no-sandbox; GPU-process crashes: --disable-gpu, --use-angle, last-resort --single-process (CEF issue 3028); winver-XP workaround for old CEF (bug 38960); corefonts against the Arial-substitution crash (bug 37797). Max forwards Chromium-style switches from its own command line (the D1 SSL workaround proves it).
- Escape hatch [confirmed]: `Max.exe --nocef` (since 9.0.0) disables CEF entirely; manual package install into ~/Documents/Max 9/Packages is the fallback.
- LOCAL RESULT 2026-08-05: jweb blank under default flags on our 11.13 fork; `--disable-gpu --disable-gpu-compositing` fixes it (verified, example.com renders).

### M2. jweb inside M4L devices crashes Live at set-load (cef_initialize)
- [confirmed on native macOS + one Windows system, Live 11.3.3] any M4L device containing jweb, saved in a set, crashes Live at set-load, 100% repro, stack ends in cef_initialize. Loading the device manually after startup is fine. Repro: export node4max express example as M4L device, put on track, save set, reopen Live. https://cycling74.com/forums/crash-at-launch-with-any-max-for-live-pluging-with-cef-in-them-percent100-reproducibility
- Wine amplification [speculation]: startup race class that Wine timing differences make worse.

### M3. Node for Max (node.script / node.debug)
- [confirmed] "no connection to node process manager" / "process manager quit after 5 restarts" (Max 8.1.11 under Wine; same bug existed natively, fixed by 8.2.2/8.2.6).
- [confirmed, secondhand] Max 9 under GE-Proton: "errors spawn; functionality continues".
- [background] node.exe under Wine generally works; scripts on Z:\ paths misbehave vs C:\.
- LOCAL RESULT 2026-08-05: three node.exe helpers spawn, gRPC + websocket connect, RNBO mdns fails and falls back to bonjour-service; one "process_id already set" warning.

### M4. Audio drivers (ad_mme / ad_directsound / ad_wasapi / ad_asio)
- [confirmed, good] Max 8 + wineasio + JACK + wine-staging 4.21: stable, 64-sample buffers, 4-9 ms round trip; "Audio Interrupt off improves results".
- [confirmed, bad] wineasio + PipeWire 1.0.5 (Ubuntu Studio 24.04): driver recognized but scratchy audio, buffer over/underruns; open (github.com/wineasio/wineasio/issues/108). Baseline warning for ASIO hosts on PipeWire; PipeASIO is a distinct implementation.
- [confirmed, good] Max 9 ad_directsound over PipeWire-Pulse in Lutris/GE-Proton: works, stable, incl. Bluetooth A2DP.
- [secondhand] wine WASAPI timing not stable.
- Max 9.0.0 fixed FlexASIO usage + "invalid memory access when switching audio devices" (native crash class relevant to device-switch stress).
- LOCAL RESULT 2026-08-05: PipeASIO enumerates and runs at 256/48000 when selected; default falls back to ad_mme because shared prefs name the "Live" driver (M4L writes prefdrivername Live).

### M5. MIDI (winmm): no hotplug, static port list
- [confirmed] ports enumerated only at launch; hardware changes invisible until restart; dynamic virtual outs impossible. Workaround: create ALSA virtual ports / a2jmidid before launch. Same class as moonshot P12; Max is a second validation host.

### M6. Jitter video: engine-dependent
- Windows engines: viddll (default, bundled FFmpeg, no Media Foundation dependency) and qt (= DirectShow, legacy). jit.grab ignores the engine pref, uses DirectShow capture.
- [confirmed, dated] jit.grab/viddll crashes in some Max 8-era setups.
- [confirmed] jit.grab camera freezes on second open (Max 9 era).
- @engine qt paths hit Wine quartz/DirectShow, expect codec failures [speculation].

### M7. Jitter OpenGL (jit.gl.* / jit.world)
- [confirmed] GL worked even in old setups; Max 8 GL3 + VIDDLL "quite well"; Max 9 "Jitter functional, ~50 fps, DXVK recommended". Failure mode is machine-level (D5), not object-level. Multi-window/multi-context GL: no reports, untested territory.

### M8. hid object crashes Max
- [confirmed, 2 reports, 2019] hid crashes: "unimplemented function" in 64-bit code (Max 8, wine-staging ~4.x). Needs retest on 11.x.

### M9. shell / OS-integration objects
- [confirmed, brief] community shell object non-functional under Wine (likely path/quoting).

### M10. Standalone export
- [confirmed, brief] exporting standalones has inconsistent path handling; exported standalones themselves run (umenu caveat applies).

## MINOR and background

1. Package Manager webview hit-target offset at scaling; test 100% vs 160-180 DPI.
2. Fonts: winetricks corefonts on every working recipe (CEF/V8 Arial crash class, wine bug 37797). JUCE 8 Windows font-rendering-quality regression exists natively (forum.juce.com/t/juce-8-decline-in-windows-font-rendering-quality/65557); whether Max 9 is on JUCE 8 Direct2D is unverified. Local action: verify whether Max 9's UI hits our custom d2d1/DirectWrite stack.
3. Wine-mono conflict: one recipe says do NOT install wine-mono; another guide installed it. Unresolved.
4. Installer download UA-gate: cycling74.com serves the Mac installer to Linux browsers; spoof a Windows UA for the .msi.
5. Winetricks base recipe (Max 8 consensus): corefonts + vcrun2010/2013/2015 (+2017/2022 for Max 9), winver win7+; Bottles recipe: vcredist2022 + esync.
6. gen~ compiles in-process via bundled LLVM/Clang JIT; zero Wine-specific failure reports. RNBO plugin/C++ export is the risky half: cloud build jobs + sample-dependency packaging (path bugs fixed in RNBO 1.1).
7. V8 objects: no Wine-specific reports. Test ES6 + XMLHttpRequest (9.1.0).
8. MC: no reports; low risk.
9. ABL objects (9.1): no reports; if Link discovery, UDP multicast through winsock; cross-check linkd.
10. Multiple instances: --new-instance since 9.0.0.
11. File dialogs: 9.0.0 moved to IFileDialog; same common-dialog surface we patched for Live; regression-test.
12. Preferences corruption: native remedy = delete Settings folder; keep as reset lever.
13. Performance: Max 8 under Wine "2-5% higher CPU than Windows, 95% functionality" (one user).
14. "Audio Interrupt: off improves results significantly" under Wine (Max 8).

## Suggested test order (mapping)
1. Clean-prefix MSI install, timed (D3). 2. Welcome paint (M1) + sign-in (D1). 3. Object-box typing on GNOME Wayland (D2). 4. umenu + context menus (D4). 5. Audio Status all drivers + device-switch stress (M4). 6. MIDI hotplug (M5). 7. CEF trio + --nocef A/B (M1). 8. Node for Max + node.debug (M3). 9. jit.movie viddll/qt, jit.grab reopen, jit.world multi-window (M6/M7). 10. gen~ live-recompile, v8, RNBO export (minor 6/7). 11. M4L jweb-device set-load (M2).
