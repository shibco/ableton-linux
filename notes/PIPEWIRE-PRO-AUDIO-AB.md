# PipeWire Pro Audio profile comparison

Use the tool to compare your current audio profile with PipeWire Pro Audio.
Run the comparison for one audio device at a time.

Pro Audio changes routing, channel count, and interrupt timing. Profile changes
can raise or lower CPU use. Treat each result as specific to one device and one
configuration.

PipeWire uses the name `pro-audio` for a Linux audio device profile. Windows
uses the same words for an audio task class. The 2 names describe separate
features.

The source basis is:

- PipeWire 1.6.8 profile code in `spa/plugins/alsa/acp/acp.c`
- WirePlumber 0.5.15 profile choice code in
  `src/scripts/device/find-best-profile.lua`
- WirePlumber ALSA guidance in
  `docs/rst/daemon/configuration/alsa.rst`

## Tool actions

The script takes a PipeWire device ID and an existing Wine prefix. A Wine prefix
stores the Windows files and settings. The script then:

1. Records the device, routes, links, settings, defaults, and current profile.
2. Checks that Live and the selected Wine prefix are idle.
3. Checks that the target audio device is idle.
4. Runs your command with the current profile.
5. Selects Pro Audio temporarily for the target device.
6. Runs the same command with Pro Audio.
7. Restores the original profile.
8. Compares the final state with the recorded state.

Your command must close every process that it starts before it exits. The
script restores the profile after command errors and caught `HUP`, `INT`, or
`TERM` signals.

The tool records each stage in a separate directory. It also records command
output, run time, exit status, and profile changes.

The state check compares stable device details. PipeWire can assign new internal
IDs during a profile change. The check therefore compares names, routes,
channels, and device paths.

The tool writes `recovery-command.txt` before the first profile change. Use that
command after power loss, `SIGKILL`, or a PipeWire service restart. Confirm the
device identity first because PipeWire can assign a new device ID.

The script keeps the saved WirePlumber profile choice throughout the
comparison.

PipeWire provides a short interval between the final state check and the
profile change. The script records an extra state check immediately before that
change. Review that record with the result.

## Device discovery

1. Close Live.
2. Close each process that uses the selected Wine prefix.
3. Find the device ID under `Devices` in `wpctl status --name`.
4. Run discovery with a new output path.

```bash
scripts/pipewire-pro-audio-ab.sh \
  --device 42 \
  --wine-prefix "$HOME/.wine-ableton" \
  --output /tmp/live-pro-audio-discovery \
  --discover
```

Review the following files before the full comparison:

- `before/device.json`
- `before/associated-nodes.semantic.json`
- `before/associated-links.json`
- `before/target-device-activity.json`
- `before/routes.json`
- `status.json`

The command accepts a new output path. It stops when the output path already
exists.

## Profile comparison

Use an integration worktree that contains both scripts. Then run both profile
tests with the benchmark suite:

```bash
scripts/pipewire-pro-audio-ab.sh \
  --device 42 \
  --wine-prefix "$HOME/.wine-ableton" \
  --output /tmp/live-pro-audio-ab-01 \
  -- sh -c 'exec scripts/bench-suite.sh \
      --tag "pipewire-profile/$ABLETON_PRO_AUDIO_LEG" \
      --output "$ABLETON_PRO_AUDIO_LEG_DIR/suite"'
```

The wrapper provides 2 values to the command:

- `ABLETON_PRO_AUDIO_LEG=baseline|pro-audio`
- `ABLETON_PRO_AUDIO_LEG_DIR=.../A-original|.../B-pro-audio`

The default settle time is 2 seconds for each profile. Set
`PIPEWIRE_PRO_AUDIO_SETTLE_SECONDS` from 0 to 30 when the device needs more
time. Use the same value for both profiles.

The default child exit wait is 5 seconds. Set
`PIPEWIRE_PRO_AUDIO_SIGNAL_WAIT_TIMEOUT` from one to 60 when the benchmark needs
more time to close.

## Result checks

Use `status.json` to check the comparison state. Use CPU data when the status is
`ab-complete` and the recorded environment stays equal across both runs.

Review the following conditions:

- the same physical input and output routes
- the same channel count
- the same sample rate and buffer size
- the same Live, Wine, prefix, plug-ins, and benchmark Sets
- stable power and temperature conditions
- each measurement tool covers the full run
- continuous audio reported by the listener
- stable PipeWire error and missed audio deadline counts
- successful restoration of the original profile

Compare total host, Wine prefix, PipeWire, and interrupt CPU. A Live process
value can fall when another process takes the work.

Run at least 5 matched pairs for each profile. Repeat the pairs at 32, 64, and
128 frames with loaded Sets.

Apply a result to the tested device and configuration. Test each additional
device separately.

The session on 26 August 2026 completed state discovery for internal ALSA
device 69. The target USB interface requires a connected hardware test before
profile selection and Live measurement.

## Tool tests

```bash
make test-pipewire-pro-audio-ab
```
