# Audio device disconnect/reconnect

## Symptoms

Unplug and replug an audio interface while Live runs: the ports return,
Live stays silent until its audio engine is restarted.

## Research

Not a Wine bug, and since 2026.07.17.2 no longer a link-restoration bug
either. Under PipeASIO Live is a native PipeWire client — the graph
survives hardware changes, and the session manager (WirePlumber) owns
reconnecting native streams when a device node returns. The launcher
starts no helper daemon.

The WineASIO era (through 2026.07.17.1) was worse: Live's ASIO "device"
was the PipeWire-JACK graph, and what died on unplug were the JACK links
between wineasio's ports and the hardware ports. PipeWire destroys them
with the device node, and neither PipeWire nor WirePlumber restores JACK
links (restore logic covers pulse/native streams only). The launcher
therefore started `jacklinkd`, a JACK client that tracked every link in
the graph, remembered the links of a port that died, and re-created them
when a port with a remembered name registered again. JACK is out of
Live's path now, so the launcher no longer starts it.

## Mitigations

None required in the default setup: replug the device and WirePlumber
re-links Live's native streams. `jacklinkd`
([../tools/jacklinkd.c](../tools/jacklinkd.c), also in the tester-kit
advanced probes) remains for setups that route a separate JACK graph —
it guards every JACK link it has seen, but it has nothing to do with
Live's own PipeASIO connections.

## Caveats

- Restores only links the session manager has seen; neither WirePlumber
  nor jacklinkd can invent routing for a never-connected device.
- Name-matched: a device that renumbers its ports on replug (rare under
  PipeWire) doesn't re-match; identically-named devices collide.
- Sample-rate mismatch on replug is resampled by PipeWire as usual. Live
  requesting a rate the graph doesn't run at is covered by the clamp in
  [../patches/pipeasio/](../patches/pipeasio/) (previously ASE_NoClock,
  startup crash).
