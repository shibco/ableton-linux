# Max 9 stress-test patches

Collected 2026-08-05 for exercising Max 9 for Windows under Wine on Linux.
All .maxpat files verified to be JSON starting with `{` and containing `"patcher"`.

Repos used (all fetched from GitHub default branches on 2026-08-05):

- https://github.com/Cycling74/gen-workshop
- https://github.com/Cycling74/jit.mo
- https://github.com/Cycling74/eyebeam-workshop-2
- https://github.com/Cycling74/n4m-core-examples
- https://github.com/Cycling74/n4m-examples
- https://github.com/stretta/BEAP (raw files from `master`)
- https://github.com/stretta/MC-Beap
- https://github.com/mediaelement/mediaelement-files (test video only)

"Bundled" below means the dependency ships inside the stock Max 8/9 install
(BEAP, VIZZIE, jit.mo packages and the stock media files), so nothing extra
needs installing.

## audio-msp

- `cpu-tester-poly.maxpat` + `cpu-tester-poly-sub.maxpat`
  - Source: https://github.com/Cycling74/gen-workshop (patchers/)
  - Exercises: `poly~` with 128 voices of pure MSP (`cycle~`, `noise~`, `lores~`, `scale~`). Deliberate CPU-load tester.
  - Correct behavior: audio starts on `startwindow`, CPU meter climbs with voice count, no dropouts/clicks at moderate voice counts, no DSP-chain rebuild crash.
  - Dependencies: none (the -sub patch must stay in the same folder).
- `peakamp-svf.maxpat`
  - Source: https://github.com/Cycling74/eyebeam-workshop-2 (audio-analysis/)
  - Exercises: MSP filter (`svf~`), amplitude analysis, `ezdac~`, `multislider` redraw at audio-driven rate.
  - Correct behavior: patch loads clean, meters/multislider animate while DSP is on.
  - Dependencies: none.

## jitter-gl

- `jit.mo-Worms.maxpat`, `jit.mo-AnimPath.maxpat`
  - Source: https://github.com/Cycling74/jit.mo (patchers/)
  - Exercises: `jit.world` (OpenGL context + window), `jit.gl.mesh` / `jit.gl.*` pipeline driven by jit.mo generators.
  - Correct behavior: render window opens, smooth animated geometry at the world fps, no context loss on window resize.
  - Dependencies: jit.mo package (bundled with Max 8+).
- `jit.mo-AudioVisuals.maxpat`
  - Same source. Adds `adc~` audio input driving GL visuals: cross-subsystem audio+GL stress.
  - Correct behavior: renders even without a mic; with an input device the visuals react.
  - Dependencies: jit.mo (bundled); audio input device optional.

## jitter-video

- `jit.mo-Alphablend.maxpat`
  - Source: https://github.com/Cycling74/jit.mo (patchers/)
  - Exercises: two `jit.movie` instances (`@moviefile dvducks.mov`, `@moviefile dvkite.mov`) decoded and alpha-blended into a GL scene.
  - Correct behavior: both movies decode and play, blended output animates in the render window.
  - Dependencies: `dvducks.mov` / `dvkite.mov` from Max's bundled media folder (ships with Max); jit.mo (bundled).
- `test-video.mp4`
  - Source: https://raw.githubusercontent.com/mediaelement/mediaelement-files/master/echo-hereweare.mp4 (H.264/AAC, 5.4 MB)
  - Not a patch. Drop onto any `jit.movie` or send `read <path>` to test arbitrary-file decode outside the bundled media, i.e. the codec path Wine users will actually hit.

## gen

- `waveshaper.maxpat`, `codebox-if-for.maxpat`, `simplistic-karplus-strong.maxpat`
  - Source: https://github.com/Cycling74/gen-workshop (patchers/)
  - Exercises: `gen~` runtime code generation: expr patching, codebox with if/for constructs, feedback (`history`/`delay`) DSP.
  - Correct behavior: gen~ compiles silently on load (no gen compile errors in the Max console), audio runs when DSP is on.
  - Dependencies: none.
- `grranulator-patch.maxpat` + `grranulator.genexpr`
  - Same source. gen~ loading external `.genexpr` code (granulator) plus several control `buffer~`s.
  - Correct behavior: compiles, granular texture audible; multislider UI animates.
  - Dependencies: the `.genexpr` file must stay next to the patch.
- `cpu-tester-gen.maxpat` + `cpu-tester-gen-sub.maxpat`
  - Same source. `poly~` wrapping gen~ voices: many simultaneous gen~ compilations and instances. Companion to the MSP cpu tester, lets you compare gen vs classic MSP CPU cost under Wine.
  - Correct behavior: all voices compile, CPU scales linearly-ish with voices.
  - Dependencies: -sub patch in the same folder.

## jweb

- `facetracking/patchers/facetracker.maxpat` (+ `getpoint.maxpat`, `pointdist.maxpat`, `src/`)
  - Source: https://github.com/Cycling74/eyebeam-workshop-2 (facetracking/)
  - Exercises: `jweb` (CEF) loading a local HTML page (`src/mesh-tracker.html`) that runs a JS face-tracking library and getUserMedia webcam capture inside the embedded browser.
  - Correct behavior: jweb boots CEF and renders the local page. That alone is the core Wine test (CEF init, GPU/compositor path). Full function additionally needs a webcam and camera permission inside CEF.
  - Dependencies: keep the folder structure (patchers/ + src/) intact; webcam optional.
- `express/patchers/express.maxpat` (+ `express-node/`)
  - Source: https://github.com/Cycling74/n4m-examples (express/)
  - Exercises: `jweb` pointed at a local HTTP server run by `node.script` (Express). Tests CEF networking to localhost plus Node for Max in one patch.
  - Correct behavior: after `script npm install` and `script start`, jweb displays the served page.
  - Dependencies: Node for Max runtime (ships with Max), network-less npm install of `express` (needs internet once).

## node4max

- `02-message-handlers/`, `04-outlet-methods/`, `06-using-dicts/`
  - Source: https://github.com/Cycling74/n4m-core-examples
  - Exercises: `node.script` lifecycle (spawn Node process, message handlers, outlets, dict transfer). Each folder is a self-contained .maxpat + .js pair with no npm dependencies.
  - Correct behavior: `script start` spawns node, messages round-trip patch <-> Node, `node.debug`/console shows no spawn errors. Under Wine this exercises the bundled Node runtime process spawn path.
  - Dependencies: Node for Max (ships with Max). No npm install needed.
- `tonal-chord-builder/`
  - Source: https://github.com/Cycling74/n4m-examples
  - Exercises: `node.script` with an npm dependency (`tonal`), driving a `poly~` synth (`poly.phatness.maxpat`, which also uses mc objects), with `notein`/`midiin` input.
  - Correct behavior: after `script npm install` + `script start`, playing MIDI notes or clicking builds chords that sound through the poly~ synth.
  - Dependencies: Node for Max; one-time npm install; MIDI input optional.

## ui-objects

- `Simple Synth.maxpat`
  - Source: https://github.com/stretta/BEAP (examples/Synthesis Examples/), raw: https://raw.githubusercontent.com/stretta/BEAP/master/examples/Synthesis%20Examples/Simple%20Synth.maxpat
  - Exercises: dense bpatcher-based BEAP modules, each full of `live.dial`, `live.slider`, `live.toggle`, panels: 2D vector drawing stress plus presentation-mode layout.
  - Correct behavior: all modules draw correctly (no blank bpatchers), knobs drag smoothly, no redraw trails.
  - Dependencies: BEAP package (bundled with Max since Max 7).
- `Big Scope best practices.maxpat`
  - Same source (raw master, `examples/Synthesis%20Examples/Big%20Scope%20best%20practices.maxpat`).
  - Exercises: large `scope~` displays: continuous high-rate 2D redraw while DSP runs. Good frame-pacing / GDI-vs-D2D stress.
  - Correct behavior: scopes animate fluidly with DSP on; UI stays responsive.
  - Dependencies: BEAP (bundled).

## mc

- `mc.karplus.maxpat`
  - Source: https://github.com/Cycling74/gen-workshop (patchers/)
  - Exercises: pure mc chain: `mc.noise~`, `mc.sig~`, `mc.line~`, `mc.gen~` (8-channel Karplus-Strong), `mc.mixdown~`. Also covers mc+gen interaction.
  - Correct behavior: 8 plucked-string voices sound and pan down to stereo; no channel-count errors in the console.
  - Dependencies: none.
- `mc-beap/Supersaw.maxpat`, `mc-beap/Getting Started.maxpat`
  - Source: https://github.com/stretta/MC-Beap (examples/ + patchers/, flattened into one folder so the bp.mc.* modules resolve via the patch's own folder)
  - Exercises: mc.* everywhere (`mc.cycle~`-based oscillator banks, mc envelopes, mc filters via `mc.svf~`/ladder, voice combining) wrapped in UI-dense bpatchers.
  - Correct behavior: modules load (no "no such object" for bp.mc.*), audio plays; Getting Started responds to MIDI input.
  - Dependencies: bp.mc.* module patches in the same folder (included here); `bp.Stereo`, `bp.MIDI In`, `bp.Poly MIDI to mc.Signal` come from the bundled BEAP package (the last one is also included in this folder); MIDI input optional for Getting Started.

## midi

- `Virtual Instrument.maxpat`
  - Source: https://github.com/stretta/BEAP, raw: https://raw.githubusercontent.com/stretta/BEAP/master/examples/MIDI%20Examples/Virtual%20Instrument.maxpat
  - Exercises: `notein` + `midiin` directly, feeding `vst~` plugin hosting.
  - Correct behavior: MIDI input device appears and notes arrive (print/monitor); with a VST loaded into vst~ it sounds. Under Wine this is the winmm/MIDI-port enumeration test.
  - Dependencies: BEAP (bundled); a MIDI input device (hardware or virtual) to be meaningful; VST optional.
- `Arpeggiator Synth.maxpat`
  - Same source (raw master, `examples/MIDI%20Examples/Arpeggiator%20Synth.maxpat`).
  - Exercises: BEAP MIDI modules (MIDI in, arpeggiator clocking) driving a synth voice: sustained scheduler-timed MIDI event stream plus audio.
  - Correct behavior: arpeggio runs steadily from held notes; timing stays stable while UI is dragged.
  - Dependencies: BEAP (bundled); MIDI input optional (toggle/kslider style control inside).

## misc

- `Gradient Rot.maxpat`
  - Source: https://github.com/stretta/BEAP, raw: https://raw.githubusercontent.com/stretta/BEAP/master/examples/Misc%20Examples/Gradient%20Rot.maxpat
  - Exercises: large (630 KB) patch, heavy UI + modulation graph. General big-patch load/instantiation and redraw torture.
  - Correct behavior: loads without multi-second hangs, UI animates.
  - Dependencies: BEAP (bundled).
- `tempo-tests.maxpat`
  - Source: https://github.com/Cycling74/jit.mo (testpatches/)
  - Exercises: Max transport/tempo driving jit.mo + `jit.world` + `jit.gl.mesh`: scheduler/transport plus GL in one patch.
  - Correct behavior: geometry animates in sync with the transport tempo.
  - Dependencies: jit.mo (bundled).
- `classic-ringtone.maxpat`
  - Source: https://github.com/Cycling74/gen-workshop (patchers/)
  - Exercises: gen~ sequencing a melody: quick audible sanity check that scheduler + gen + audio out all work.
  - Correct behavior: plays the Nokia-style ringtone melody.
  - Dependencies: none.

## Not covered / notes

- No patch here uses `jit.grab` (webcam via DirectShow). eyebeam's optical-flow patch was the candidate but it references `my.viewr.maxpat`, which is missing from the repo, so it was dropped. The facetracking jweb patch covers webcam capture via CEF instead.
- maxforlive.com was skipped per instructions (.amxd, login-gated). stretta/monosequencer turned out to be .amxd-only and was dropped.
- Cycling74/max-test (the automated test harness) was fetched and inspected but its patches require the repo's compiled `test.*`/oscar externals, so none were included.
- BEAP example patches are large because they embed snapshot data; that is normal.
