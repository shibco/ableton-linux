# Max 9 test harness

Small Max patches that test one subsystem each without mouse or keyboard
input. Each patch runs its test from a loadbang when it opens and prints
markers. Max mirrors console prints into
`AppData/Roaming/Cycling '74/Max 9/Logs/Max.log` in the prefix, so a shell
can open a patch with the max9 launcher, wait, and grep the log for the
result. This works where outside input injection does not: XTEST never
reaches Wine windows, and SetCursorPos cannot warp the pointer under
XWayland, so SendInput mouse clicks land nowhere. SendInput keyboard from
inside the prefix (liveinject) still works, but needs the target window
foreground, so it must not run while the desktop is in use.

- t01-dsp-probe: lists the audio drivers, reports the current one, starts DSP.
- t02-pipeasio-switch: switches the driver to PipeASIO by menu index (2),
  starts DSP, reports the final driver. Index order observed on this
  install: None, FL Studio ASIO, PipeASIO Driver, ad_directsound, ad_mme.
- t03-jweb-cef: embeds a jweb browser pointed at https://example.com.
  Blank area = the CEF GPU-compositor fault; page visible = fixed.
- t06-node-auto: goes into max-test-patches/node4max/04-outlet-methods/
  (needs outlet-methods.js beside it); round-trips a message through the
  bundled Windows node.exe.
- t09-midi-probe: dumps the winmm MIDI port lists. Known authoring flaw:
  midiinfo has one outlet, the second patchcord gets dropped at load.
- t11-umenu-click: a umenu wired to print. Needs a real click to open the
  dropdown (the historical Max 7 crash class): run it in a quiet session
  with SendInput keyboard/mouse from inside the prefix.

The downloaded community patch corpus (55 patches, ten subsystems) lives in
the session scratchpad; DOWNLOADED-PATCHES-MANIFEST.md preserves its source
URLs and per-file notes so it can be refetched.

Results and findings: notes/performance-moonshot/MAX9-STABILITY-2026-08-05.md
