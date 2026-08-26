# abl-bench-m4l: the benchmark control device

A Max for Live audio effect that sits on a track in every benchmark set and
connects Live to the bench harness over OSC. It reports readiness, transport
state, and the CPU meter on UDP 19002, and takes transport commands on UDP
19001. `scripts/bench-osc.py` probes and drives it from the shell, and
`scripts/bench-run.sh` records DSP average and peak from its reports.

Files here:

- `abl-bench-m4l.amxd`: the device. Drag it onto a track in each set.
- `abl-bench-osc.js`: the device's logic. The device loads it from this
  folder at run time; the device is deliberately not frozen, so edits to
  the script reach every set on the next load.

Verified 2026-08-01 inside Live 12.4.3 on runtime 2026.08.01.1: ready,
playing, pong, play, stop, rewind, and cpu all behave as documented below.

## Rebuilding the device

Needed only if `abl-bench-m4l.amxd` is lost or the patcher must change.

1. In Live, drop a blank Max Audio Effect on any track and open its editor.
2. Copy the JSON block below, click into the patcher, and paste. Keep the
   template's `plugin~` and `plugout~` objects corded left-to-left and
   right-to-right; without them the device silences its track.
3. Save the device as `bench/m4l/abl-bench-m4l.amxd`, next to
   `abl-bench-osc.js`, so the `js` object finds the script. Do not freeze.

```json
{
    "boxes": [
        {"box": {"id": "obj-1", "maxclass": "newobj", "text": "live.thisdevice", "numinlets": 1, "numoutlets": 3, "outlettype": ["bang", "int", "int"], "patching_rect": [30.0, 30.0, 95.0, 22.0]}},
        {"box": {"id": "obj-2", "maxclass": "newobj", "text": "udpreceive 19001", "numinlets": 1, "numoutlets": 1, "outlettype": [""], "patching_rect": [160.0, 30.0, 110.0, 22.0]}},
        {"box": {"id": "obj-3", "maxclass": "newobj", "text": "js abl-bench-osc.js", "numinlets": 1, "numoutlets": 1, "outlettype": [""], "patching_rect": [30.0, 90.0, 120.0, 22.0]}},
        {"box": {"id": "obj-4", "maxclass": "newobj", "text": "udpsend 127.0.0.1 19002", "numinlets": 1, "numoutlets": 0, "outlettype": [], "patching_rect": [30.0, 150.0, 150.0, 22.0]}},
        {"box": {"id": "obj-5", "maxclass": "comment", "text": "abl-bench-m4l: commands in on 19001, reports out on 19002", "numinlets": 1, "numoutlets": 0, "patching_rect": [30.0, 190.0, 330.0, 20.0]}}
    ],
    "lines": [
        {"patchline": {"source": ["obj-1", 0], "destination": ["obj-3", 0]}},
        {"patchline": {"source": ["obj-2", 0], "destination": ["obj-3", 0]}},
        {"patchline": {"source": ["obj-3", 0], "destination": ["obj-4", 0]}}
    ],
    "appversion": {"major": 9, "minor": 0, "revision": 0, "architecture": "x64", "modernui": 1}
}
```

After a rebuild or a script edit, delete the device from the track and drag
it back on: that re-fires `live.thisdevice` and gives the script a clean
init. A script edit alone hot-reloads the code but resets its state, so the
device stays quiet until that re-add.

## Protocol

Commands, harness to device, UDP 19001:

| Address | Effect |
|---|---|
| `/abl/bench/ping [args]` | echoed back as `/abl/bench/pong` |
| `/abl/bench/play` | start the transport |
| `/abl/bench/stop` | stop the transport |
| `/abl/bench/rewind` | set the song position to 0 |
| `/abl/bench/poll` | one immediate `/abl/bench/cpu` report |
| `/abl/bench/cpu-period MS` | report interval in ms; 0 stops reports; default 500 |

Reports, device to harness, UDP 19002:

| Address | Meaning |
|---|---|
| `/abl/bench/ready 0\|1` | Live API up; 1 means the CPU meter was readable at init |
| `/abl/bench/playing 0\|1` | transport state, on every change and once at init |
| `/abl/bench/cpu AVG PEAK` | CPU meter values in percent; -1 -1 means not yet readable |
| `/abl/bench/pong [args]` | ping echo |

The CPU values come from `average_process_usage` and `peak_process_usage`
on the Live API's Application object (Live 11 and newer) and are percent,
the same unit as the `dsp_load_pct` column. A `ready 0` means the init
raced the Live API; the script then retries the meter with a fresh handle
on every report until it reads, so a short run of `-1 -1` rows heals
itself.

## Verifying after a change

1. In one terminal: `scripts/bench-osc.py dump`.
2. Load a set containing the device. Expect a `ready` row, a `playing`
   row, and `cpu` rows with non-negative percent values.
3. `scripts/bench-osc.py send /abl/bench/ping 1` and expect `pong 1`.
4. `scripts/bench-osc.py send /abl/bench/play`; Live starts playing and a
   `playing 1` row arrives. Send `/abl/bench/stop` to end it.

## Notes

- A set containing this device boots the Max runtime at load, so every
  scenario includes `max_boot` and absolute startup times include Max.
  The cost is identical across sets and across before/after pairs.
- `udpreceive` binds all interfaces. The installer's firewall handling
  opens only Link's port 20808, so 19001 stays unreachable from outside
  unless a firewall rule is added by hand.
- Harness integration: the suite proves readiness with a nonce ping, rewinds
  and starts transport, then `bench-run.sh` records `/abl/bench/cpu` average
  and peak values for exactly the same duration as its CPU and PipeWire
  captures.
