# Troubleshooting Ableton Live on Linux

Here are some common ailments we've seen, and how to fix them.


## Live has no sound

Open **Settings > Audio** and select:

- **Driver Type:** ASIO
- **Audio Device:** PipeASIO

Confirm that PipeWire and WirePlumber are running on the host. If audio
crackles, try a larger PipeASIO buffer:

```bash
PIPEASIO_PREFERRED_BUFFERSIZE=512 ableton-live
```

See the [PipeASIO implementation note](notes/ABLETON-WINE-PIPEASIO.md) for
driver details.

## A plugin window resizes repeatedly or shows stale pixels

Right-click the affected plugin in Live's device rack, disable
**Auto-Scale Plugin Window**, then reopen the plugin.

This workaround is only needed for affected plugins. See the
[Pianoteq investigation](notes/ABLETON-WINE-PIANOTEQ-DPI-GHOST-BUG.md) for the
confirmed failure mode.

## Live 11: Max for Live fails after the first launch

After running Live 11 once, close Live and run:

```bash
sh ~/Downloads/install-ableton-latest.run --extract /tmp/ableton-kit
bash /tmp/ableton-kit/scripts/setup-prefix.sh --post-first-run
```

The repair moves Max 8's incompatible preferences to a timestamped backup.
Max creates a clean preferences file when it next starts.

## Live 11: media files can crash Live

Do not preview or import WMA or video files in Live 11. Wine's current
`wmvcore.dll` implementation can crash Live on that path. Live 12 does not use
the affected path.

See the [WMVCore investigation](notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md).

## The launcher finds more than one Live installation

When both Live 11 and Live 12 are installed, `ableton-live` starts the newest
major version. Select Live 11 with:

```bash
ABLETON_LIVE_VERSION=11 ableton-live
```

When one prefix contains multiple editions of the same major version, the
launcher refuses to guess. Set `ABLETON_LIVE_EXE` to the exact executable you
want to start.

## Using Linux-native plugins

Linux-native VST and CLAP integration is not implemented in this project yet.
The experimental workaround runs the plugin in Carla and routes audio and MIDI
through PipeWire.

See [Linux-native plugin routing](notes/ABLETON-WINE-PLUGIN-BRIDGING.md) for
the current test procedure and limitations.

## Push 2 does not connect

Configure exactly one `Push2` control-surface row with **Ableton Push 2 Live
Port** as both its input and output. Remove duplicate `Push2` rows, close Live
normally, then reconnect Push 2 and start Live again.

See the [Push 2 display bridge note](notes/ABLETON-WINE-PUSH2-DISPLAY.md) for
USB diagnostics.

## Ableton Link does not find peers

Link peers must share a local network that carries multicast. Many guest and
public Wi-Fi networks block multicast. Multicast also stops at a VPN tunnel:
peers on the far side of a VPN cannot be discovered, while peers on your own
network remain reachable with the VPN connected.

Check these in order:

1. If you run a firewall, allow UDP port 20808.
2. If you installed with `--no-link`, run the installer again with `--link`.
3. Otherwise, close Live and retry the setup:

   ```bash
   ~/.local/share/ableton-wine/setup-link.sh
   ```

Start Live and enable **Show Link Toggle** and Link again. See
[Ableton Link diagnostics](notes/ABLETON-WINE-LINK.md) if peers still do not
appear.

## Audio cuts out for a few seconds, or plays at the wrong speed

Another audio application (usually a JACK one) told PipeWire to run at a
different buffer size. Live mutes for a few seconds while the driver
switches to that size, then audio comes back on its own. If it happens
once, there is nothing to do.

If it keeps happening, or audio plays too fast or too slow instead of
coming back (releases up to 2026.08.04.1 do this), clear the stuck buffer
size and restart Live:

```bash
pw-metadata -n settings 0 clock.force-quantum 0
```

If you still have problems, try rebooting. If they come back after that,
run `./scripts/audio-report.sh` from a repository checkout and attach the
output to an issue.

## Live is slow and CPU use stays high

Live runs much slower without a Linux feature called ntsync. The launcher
warns at each startup while it is missing. Turn it on now and at every
boot:

```bash
sudo modprobe ntsync
echo ntsync | sudo tee /etc/modules-load.d/90-ableton-ntsync.conf
```

Restart Live. The startup warning no longer appears.

If the first command reports that the module does not exist, move to a kernel
that provides ntsync (Linux 6.14 or newer) and run the commands again.

## Audio latency remains high

PipeWire 1.6 or newer can match its graph quantum to PipeASIO's buffer. Check
the PipeWire version before changing the host.

For advanced host tuning from a repository checkout, run:

```bash
./scripts/setup-realtime.sh
```

The script requests `sudo` before changing realtime permissions, swappiness,
or CPU-governor settings. Log out and back in after it completes. Run
`ABLETON_RT=off ableton-live` to compare normal scheduling.

## Display scaling is wrong

Restart Live after moving it between monitors with different scale factors.
Override automatic detection for one launch with `ABLETON_DPI_MODE`; available
values are listed in [the build and configuration reference](BUILDING.md#environment-variables).

## Report a problem

Use the [GitHub issue form](https://github.com/shibco/ableton-linux/issues/new/choose).
Include the Live edition, this project's release number, Linux distribution,
desktop environment, and the exact action that failed. Do not attach Ableton
installers, authorization files, licence keys, projects, or plugin credentials.
