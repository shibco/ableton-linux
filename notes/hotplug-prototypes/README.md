# August 2026 hotplug prototypes

These files preserve the uncommitted August 2 MIDI experiment after replaying
it onto current `main`. They are evidence, not part of the numbered production
patch series.

- `0067-prototype-winealsa-mmdevapi-dynamic-midi.patch` reserves 32 winealsa
  slots, adds a port on `PORT_START`, invalidates one on `PORT_EXIT`, and
  broadcasts `DBT_DEVNODES_CHANGED`.
- `0068-prototype-winmm-refresh-midi-count.patch` re-asks lower MIDI drivers
  for a count increase and grows WinMM's table.

Together they made `midiwatch` observe a `fakectl` count increase from 3 to 4
in roughly 450 ms. They were never tested with Live or physical USB hardware.
They must not ship because they retain name-only identity, fixed-capacity and
lifetime-count behavior, unsafe shared-table lifetimes, and the announce
monitor's dependency on an open MIDI input.

The complete replacement design is in
[`../ABLETON-WINE-DEVICE-HOTPLUG.md`](../ABLETON-WINE-DEVICE-HOTPLUG.md).
