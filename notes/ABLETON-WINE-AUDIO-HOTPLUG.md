# Audio device hotplug

PipeASIO remembers the selected PipeWire interface and channel routes.

When the interface leaves, PipeASIO sends silence and accepts playback data
safely. PipeASIO restores the route set when the same interface returns. Live
and wineserver stay open.

An explicit device choice waits for that interface. Automatic routing follows
the PipeWire default. Automatic capture first follows the playback interface's
audio card.

New interfaces appear in PipeASIO Settings. A saved device choice applies while
Live runs.

PipeASIO also rebuilds its connection after delayed PipeWire startup or a
PipeWire restart. Use `pw-top` or `wpctl status` to inspect the Linux audio
graph.

Release approval adds repeated USB reconnects and a full Ableton Live
performance session with input, output and two-device setups.
