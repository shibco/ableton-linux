# Benchmark control device

Four benchmark sets use this Max for Live device. It controls playback and
reports Live's CPU value to the benchmark suite.

The device receives commands on UDP port 19001. It sends state and CPU reports
on UDP port 19002.

The folder contains these files:

- `abl-bench-m4l.amxd`: add this device to one track in each controlled set
- `abl-bench-osc.js`: keep this script beside the device

We verified all documented commands with Live 12.4.3 and runtime 2026.08.01.1
on 1 August 2026.

## Device recovery and changes

Use these steps after file loss or a patch change.

1. Add a blank Max Audio Effect to a track in Live.
2. Open its editor.
3. Copy the JSON block below and paste it into the patcher.
4. Keep `plugin~` and `plugout~` connected from left to left and right to right.
5. Save the device as `bench/m4l/abl-bench-m4l.amxd` beside `abl-bench-osc.js`.
6. Keep `abl-bench-osc.js` as a separate script file.

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

After a rebuild or script edit, remove the device from the track. Then add it
again. These actions restart its reports.

## Commands and reports

The suite sends these commands to UDP port 19001:

| Address | Effect |
|---|---|
| `/abl/bench/ping [args]` | echoed back as `/abl/bench/pong` |
| `/abl/bench/play` | start the transport |
| `/abl/bench/stop` | stop the transport |
| `/abl/bench/rewind` | set the song position to 0 |
| `/abl/bench/poll` | one immediate `/abl/bench/cpu` report |
| `/abl/bench/cpu-period MS` | report interval in ms; 0 stops reports; default 500 |

The device sends these reports to UDP port 19002:

| Address | Meaning |
|---|---|
| `/abl/bench/ready 0\|1` | readiness state; 1 means Live supplied a CPU value at start |
| `/abl/bench/playing 0\|1` | playback state at start and after each change |
| `/abl/bench/cpu AVG PEAK` | CPU values in per cent; `-1 -1` marks a pending value |
| `/abl/bench/pong [args]` | ping echo |

Live supplies the average and peak CPU values as percentages. The report uses
the same unit in its `dsp_load_pct` column.

After `ready 0`, the script requests a new CPU value with every report. The
value `-1 -1` marks a pending CPU value.

## Change check

1. Run `scripts/bench-osc.py dump` in one terminal.
2. Load a set that contains the device.
3. Check for `ready`, `playing`, and `cpu` rows with values of 0 or more.
4. Run `scripts/bench-osc.py send /abl/bench/ping 1` and check for `pong 1`.
5. Run `scripts/bench-osc.py send /abl/bench/play` and check for `playing 1`.
6. Run `scripts/bench-osc.py send /abl/bench/stop` to stop playback.

## Run effects

The device starts the Max runtime when Live loads the set. Controlled sets
therefore include `max_boot` in their start-up time. Before and after runs use
the same device cost.

`udpreceive` listens on all network interfaces. The installer opens port 20808
for Link. A separate firewall rule controls external access to port 19001.

The suite checks readiness with a unique ping. It then rewinds and starts Live.
`bench-run.sh` records average and peak CPU values for the same period as its
other measurements.
