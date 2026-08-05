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

## Live's "Enable GPU Renderer" setting is greyed out

If you're experiencing performance issues or high CPU usage when idle, Live
may not be using your GPU. By default, Live will always offload the UI to
your GPU for maximum performance, but will only do so when it recognises
the name of your GPU. On Linux, GPUs will 'tell' Live their name without
any external interference, and because Live is anticipating that interference,
it may not recognise the GPU's name and refuse to use the GPU.

To confirm this problem, open **Settings > Display & Input**. 
If **Enable GPU Renderer** is greyed out, and the note under it names a 
graphics card that is not the one in your computer, then you're seeing this
exact problem. 

To solve it: **update this project**.

Download [the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)
and run the update. It keeps your Live installation, your license, and
your projects:

```bash
sh ~/Downloads/install-ableton-latest.run --update
```

Start Live, open **Settings > Display & Input**, and turn on **Enable GPU
Renderer**. Live now names your real graphics card, and the setting stays
on.

If the setting is still greyed out on 2026.08.01.1 or newer,
[open an issue](https://github.com/shibco/ableton-linux/issues) and
include your graphics card model.

## Live 11: Max for Live fails after the first launch

After running Live 11 once, close Live and run:

```bash
sh ~/Downloads/install-ableton-latest.run --extract /tmp/ableton-kit
bash /tmp/ableton-kit/scripts/setup-prefix.sh --post-first-run
```

The repair moves Max 8's incompatible preferences to a timestamped backup.
Max creates a clean preferences file when it next starts.

## A newly installed font does not show up inside Live

Live and Max for Live see the fonts installed on your computer through a
list that this project saves and reuses, which makes Live start faster. The
list refreshes itself when the fonts on your computer change, so a new font
normally appears inside Live at the next launch with no action from you.

If a font you installed is missing inside Live, check whether the saved
list is the cause. Close Live, then start it with the list turned off:

```bash
WINE_DISABLE_HOST_FONT_CACHE=1 ableton-live
```

This launch reads your fonts directly. If the missing font appears now,
delete the saved list and start Live normally. Live rebuilds the list with
your new font in it:

```bash
rm ~/.wine-ableton/drive_c/windows/wine-host-font.cache
ableton-live
```

If the font is still missing with the list turned off, the list is not the
cause. [Open an issue](https://github.com/shibco/ableton-linux/issues) and
name the font and where you installed it from. How the saved list works,
with measurements:
[the Max for Live launch note](notes/FINDINGS-M4L-LAUNCH-2026-08-04.md).

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
coming back (releases up to 2026.08.01.1 do this), clear the stuck buffer
size and restart Live:

```bash
pw-metadata -n settings 0 clock.force-quantum 0
```

If you still have problems, try rebooting. If they come back after that,
run `./scripts/audio-report.sh` from a repository checkout and attach the
output to an issue.

## Live is slow and wineserver uses a full CPU core

Without `/dev/ntsync`, every Windows synchronization wait becomes a
wineserver round trip: measured at about 45 percent of one core and 9,000
context switches per second with Live idle
([details](notes/ABLETON-WINE-NTSYNC-REGRESSION.md)). The launcher warns at
startup when the device is missing; `ls /dev/ntsync` checks by hand.

`ntsync` ships in Linux 6.14 and newer. On a 6.14+ kernel, load the module
and make the load permanent:

```bash
sudo modprobe ntsync
echo ntsync | sudo tee /etc/modules-load.d/90-ableton-ntsync.conf
```

`setup-realtime.sh` installs the same drop-in. On kernels older than 6.14,
or built without `CONFIG_NTSYNC`, move to a distribution kernel that
provides the module. Relaunch Live to verify: the warning is gone. From a
repository checkout, `./scripts/check-ntsync.sh` runs the full probe.

## Live uses much CPU when it is idle

Live sends many messages between its audio engine and its interface, also
when nothing plays. On Windows, these messages are almost free. In Wine,
each message went through a helper program (the wineserver) many times.
Release 2026.08.05.1 removes most of these requests. The measured traffic
from these messages fell by more than 99%.

If Live still uses much CPU when it is idle:

1. Do the check in "Live is slow and wineserver uses a full CPU core". A
   Linux kernel older than 6.14 can keep Live at about 30% CPU on an empty
   project. The Debian 13 kernel is older than 6.14.
2. Turn the new code off for one test, and compare the readings:

   ```bash
   WINE_APC_FASTPATH=off WINE_MSG_FASTPATH=off ableton-live
   ```

   If the CPU use changes, [open an issue](https://github.com/shibco/ableton-linux/issues) and include both readings.
3. Programs that attach tools to Live's windows (screen readers, macro
   tools, overlays) add more messages. Close them and measure again.

The measurements are in [the findings record](notes/FINDINGS-P5-TRACE-2026-08-05.md).


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

## Full Screen shows shifted content or does not fully exit

Update to a release newer than 2026.08.01.1. On 2026.08.01.1 and older,
**View > Full Screen** and F11 show Live's content shifted, clicks land away
from their targets, and leaving fullscreen keeps the fullscreen image on
screen until the window is moved.

Download [the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)
and run the update. It keeps your Live installation, your license, and
your projects:

```bash
sh ~/Downloads/install-ableton-latest.run --update
```

Until you can update, drag Live's window once after leaving fullscreen to
clear the stuck image.

If fullscreen is still wrong after the update, launch once with
`WINE_WIN32_FULLSCREEN_CLASS=off ableton-live`, then
[open an issue](https://github.com/shibco/ableton-linux/issues) and include
your desktop environment and whether that launch behaved differently.

## Report a problem

Use the [GitHub issue form](https://github.com/shibco/ableton-linux/issues/new/choose).
Include the Live edition, this project's release number, Linux distribution,
desktop environment, and the exact action that failed. Do not attach Ableton
installers, authorization files, licence keys, projects, or plugin credentials.
