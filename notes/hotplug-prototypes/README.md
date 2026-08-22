# August 2026 hotplug prototypes

These files record the uncommitted MIDI experiment from 2 August 2026. The
release build uses the main patch list, which ends at patch 0099.

- the `0067-prototype-winealsa-mmdevapi-dynamic-midi.patch` file adds entries and marks disconnected addresses as inactive.
- the `0068-prototype-winmm-refresh-midi-count.patch` file increases the Windows MIDI count for each new entry.

Together they changed the `midiwatch` count from 3 to 4 in about 450
milliseconds. The test used `fakectl`. The final patch tests will use Live and
USB hardware.

The current design replaces fixed capacity and name matching with stable
device records. It also starts device watching before a MIDI input opens.

The [reliable MIDI and audio hotplug plan](../ABLETON-WINE-DEVICE-HOTPLUG.md)
describes the release design.
