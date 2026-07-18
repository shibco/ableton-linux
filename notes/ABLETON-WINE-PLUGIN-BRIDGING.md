# Linux-native plugin bridging via PipeWire (issue #15)

## Motivation

[#15](https://github.com/shibco/ableton-linux/issues/15) asks for
Linux-native plugins inside Live, via
[Winesulin](https://github.com/falkTX/winesulin) — a native-Linux
plugin host embedded in the Windows VST host process under Wine, the
inverse of yabridge. The justification: Linux-only plugins exist, and
Ildaeil would also cover LV2.

Assessment (2026-07-18): Winesulin is explicitly "still highly
experimental", and embedding it would add a second plugin ABI surface
to support. A zero-Wine-changes alternative exists today: PipeASIO is
a native PipeWire client, so its ports sit in the same graph as any
native host, and PipeWire routes between them. #15 stays open as a
clearly-marked experimental/low-priority tracker; this page documents
the supported recipe.

## Recipe: Carla or Ildaeil + PipeWire routing

1. Install Carla (or falkTX's Ildaeil for LV2) from distro packages.
   Start it under PipeWire's JACK shim so its ports appear in the
   PipeWire graph:

   ```bash
   pw-jack carla      # or: pw-jack ildaeil
   ```

2. Load the Linux-only plugin in Carla's rack.

3. Launch Live with PipeASIO selected (Preferences → Audio → Driver
   Type ASIO → Device PipeASIO). The driver's ports appear in the
   graph: 2 in / 2 out, fixed 256-frame buffer, autoconnect, per
   `~/.config/pipeasio/config.ini` (see
   `notes/ABLETON-WINE-PIPEASIO.md`).

4. Connect with qpwgraph or `pw-link`:

   - Carla outputs → PipeASIO inputs: the plugin lands on an armed
     audio track in Live.
   - PipeASIO outputs → Carla inputs: send/return FX loops through the
     plugin.
   - MIDI: over the ALSA sequencer ports `winealsa.drv` already
     exposes to Live (qpwgraph shows them in its MIDI view;
     `aconnect -l` lists them from the shell).

   Port discovery and wiring from the shell:

   ```bash
   pw-link -o                      # list output ports
   pw-link -i                      # list input ports
   pw-link <output> <input>        # connect one pair
   ```

   PipeASIO's inputs present as `in_1` / `in_2` (verified in the
   PipeASIO validation); Carla's port names depend on the host build —
   confirm them with the listing commands above.

5. Save the connection set as a qpwgraph patchbay profile so the
   routing restores per session.

## Caveats

- This page documents the recommended routing from the design review;
  it has not been run end to end against this tree. Everything except
  the PipeASIO port layout (which comes from the PipeASIO validation)
  is untested — treat the exact port names of Carla/Ildaeil and the
  MIDI wiring as to-be-confirmed on your system.
- The plugin chain shares the graph quantum with Live (256 frames by
  default, force-quantum from `~/.config/pipeasio/config.ini`). Watch
  `pw-top` for xruns on a loaded machine, as with any routing.
- If in-process bridging is ever pursued for #15, prefer a
  PipeWire/JACK-level bridge over embedding a native host in Live's
  process: in-process embedding couples a second plugin ABI's crash
  surface to Live's address space — precisely the stability property
  this distribution exists to protect.
