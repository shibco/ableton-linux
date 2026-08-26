# PipeWire Pro Audio exact-device A/B

This is evaluation tooling, not a new default. PipeWire's `pro-audio` profile
is an ALSA card profile. It is unrelated to the Windows MMCSS task string
`Pro Audio`, and it is not a hidden PipeASIO processing mode.

PipeWire 1.6.8 builds the profile from raw playback and capture PCMs, exposes
AUX channels, and can choose different grouping and IRQ-driven behavior
(`spa/plugins/alsa/acp/acp.c:331-496`). Changing profile disables old mappings,
changes the card/UCM state, and enables new mappings
(`spa/plugins/alsa/acp/acp.c:1787-1880`). The probed channel count is also
configurable (`spa/plugins/alsa/acp/acp.c:1935-1974`). WirePlumber 0.5.15 does
not choose generic Pro Audio automatically
(`src/scripts/device/find-best-profile.lua:13-74`). Its ALSA documentation
explicitly describes an interrupt-frequency versus CPU tradeoff for batch and
non-batch devices
(`docs/rst/daemon/configuration/alsa.rst:340-400`).

Consequently, Pro Audio may expose more channels, generate more interrupts,
keep additional nodes active, increase idle/IRQ CPU, or lose desktop mixer and
UCM routes. A lower Live-process CPU value can simply mean that work or routing
moved. Pro Audio is not a CPU optimization by definition.

## Safety model

`scripts/pipewire-pro-audio-ab.sh` accepts only an exact decimal PipeWire
Device global ID and an explicit existing Wine prefix. It:

1. creates a new private artifact directory and takes a read-only graph,
   device, associated-node/link, route, default, settings, and profile-state
   snapshot;
2. discovers exactly one available profile named `pro-audio` on that ALSA
   device;
3. refuses when any Live process or Wine process for the exact prefix is
   already active; a Wine-like process whose prefix environment cannot be read
   is conservatively reported as `prefix-unresolved` and also refused, with no
   override; it also refuses a `running` node or `active` link connected to the
   exact device, while allowing suspended nodes and paused passive DSP links;
4. waits the same explicit settle interval (two seconds by default), rechecks
   identity, profile, activity, and state, then runs the supplied command once
   under the untouched original profile;
5. requires the command to leave Live and the prefix idle, then rechecks the
   numeric ID, device fingerprint, original profile, and exact-device graph;
6. selects only that device's discovered Pro Audio index with
   `pw-cli set-param ... '{"index":N,"save":false}'` and verifies both its index
   and name, waits the same settle interval, and repeats the profile and activity
   checks before running the same command again;
7. restores and verifies the exact original index and name on success,
   benchmark failure, switch failure, `HUP`, `INT`, or `TERM`; and
8. fails the experiment if defaults, WirePlumber's persisted profile-state
   hash, target routes, the associated-node fingerprint, settings, or device
   identity do not return to the recorded state, or if guarded activity appears
   after B or restoration.

The associated-node result is deliberately named a *fingerprint*: it compares
media class, node name and description, profile name, ALSA path, channel count,
and channel positions while allowing transient global/object IDs to churn. The
complete before/after graphs are retained for review. `verified` does not claim
that every volatile PipeWire node property was byte-identical.

Each graph check retains full target node objects in `associated-nodes.json`,
full connected Link objects in `associated-links.json`, and the focused blocker
classification in `target-device-activity.json`. Only node state `running` and
Link state `active` block. This intentionally does not reject the host's normal
`suspended` device nodes or `paused` passive convolver/EQ links.

The tool deliberately does not use `wpctl set-profile`. In WirePlumber 0.5.15,
that command builds a Profile parameter with `save=true`
(`src/tools/wpctl.c:1342-1390`), and the profile-state policy persists
user-generated choices when that flag is set
(`src/scripts/device/state-profile.lua:67-129`). PipeWire's Profile parameter
defines an explicit `save` Boolean
(`spa/include/spa/param/profile.h:19-42`); the tool sends `save:false` for both
the experimental switch and restoration. It installs no PipeWire or
WirePlumber configuration and never selects Pro Audio automatically.

`SIGKILL`, host power loss, PipeWire/WirePlumber failure, device removal, and a
hostile benchmark command cannot be made transactional by a shell script. The
original profile and a transient recovery command are therefore written to
`recovery-command.txt` before the first switch. PipeWire global IDs are
session-scoped: after a service or device restart, verify the recorded identity
again before using that command. On `HUP`, `INT`, or `TERM`, the tool signals only
the exact direct benchmark child and waits at most five seconds by default. It
does not broadly kill a process group or descendants; an uncooperative child is
recorded as `signal-child-active` and restoration proceeds. A benchmark command
must fully stop everything it starts; if guarded activity remains after B or is
observed after restoration, the tool records that contract violation and fails
the pair because leaving the device changed is worse.

There is necessarily a small race between the last `pw-dump` graph snapshot and
`pw-cli set-param`: PipeWire exposes no shell-level transaction that reserves a
device and changes its profile atomically. The tool minimizes that window with
an immediate graph-only recheck, records it under
`events/immediately-before-switch/`, and never represents the guard as a lock on
other clients.

## Use

First close Live and every process in the target prefix. Find the numeric ID in
the `Devices` section of `wpctl status --name`, then run read-only discovery:

```bash
scripts/pipewire-pro-audio-ab.sh \
  --device 42 \
  --wine-prefix "$HOME/.wine-ableton" \
  --output /tmp/live-pro-audio-discovery \
  --discover
```

An existing output path is refused. Review `before/device.json`,
`before/associated-nodes.semantic.json`, `before/associated-links.json`,
`before/target-device-activity.json`, `before/routes.json`, and
`status.json` before running the experiment.

Both legs use `PIPEWIRE_PRO_AUDIO_SETTLE_SECONDS=2`. It accepts an integer from
0 to 30; use a larger value when the interface needs more time to settle, but do
not use different values for the two legs. Signal cleanup's exact-child wait is
bounded by `PIPEWIRE_PRO_AUDIO_SIGNAL_WAIT_TIMEOUT=5` (1 to 60 seconds).

For the benchmark reporter branch, let each invocation derive its own output
from the per-leg environment supplied by the A/B tool:

```bash
scripts/pipewire-pro-audio-ab.sh \
  --device 42 \
  --wine-prefix "$HOME/.wine-ableton" \
  --output /tmp/live-pro-audio-ab-01 \
  -- sh -c 'exec scripts/bench-suite.sh \
      --tag "pipewire-profile/$ABLETON_PRO_AUDIO_LEG" \
      --output "$ABLETON_PRO_AUDIO_LEG_DIR/suite"'
```

The command is executed directly without `eval`; `sh -c` above is explicit so
that its shell, not the A/B tool, expands:

- `ABLETON_PRO_AUDIO_LEG=baseline|pro-audio`
- `ABLETON_PRO_AUDIO_LEG_DIR=.../A-original|.../B-pro-audio`

This prevents the two identical command invocations from colliding on one
explicit reporter output path. The A/B wrapper's own stdout, stderr, exit code,
timing, and state evidence always remain under those distinct leg directories.

## Reading the result

`status.json` is authoritative for orchestration status, not for performance.
It records the equal settle interval, both command exit codes and elapsed times,
switch/restoration state, activity checks, and all restored-state comparisons.
Raw evidence is retained under:

- `before/`
- `A-original/`
- `B-pro-audio/`
- `after-restoration/`
- `events/`

Do not interpret CPU when the result is anything other than `ab-complete`, or
when the benchmark report shows route/channel, rate, quantum, crackle, xrun,
PipeWire error, process-identity, power, or thermal differences. A release
recommendation requires at least five matched pairs per profile at 32, 64, and
128 frames on the real interface and loaded Sets. Compare whole-prefix,
PipeWire, kernel IRQ, and host CPU—not only Live—and require no audible crackle,
deadline, route, channel, or continuity regression. Even a clean result only
supports that exact interface and configuration; it does not justify a broad
WirePlumber rule.

The hermetic policy and failure-path suite is:

```bash
make test-pipewire-pro-audio-ab
```
