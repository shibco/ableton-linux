# Troubleshooting Ableton Live on Linux

Here are some common ailments we've seen, and how to fix them.


## The installer does not finish after Live installs

If an **Ableton USB Driver** window is in your taskbar, close it. The
installer then continues by itself. If there is no such window, press
Ctrl-C, then download
[the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)
and run:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

An update that stops at `== [1/5] initialise prefix ==` has the same fix.
The update keeps your Live installation, your license, and your projects.

Ableton's own installer adds a small Windows helper program that Live does
not need on Linux. The helper stays open, often without any window, and
setup used to wait for it. Releases newer than 2026.08.04.1 stop the
helper themselves and remove its autostart entry, so the wait clears after
about half a minute and the stop does not come back.

## Online authorisation does not return to Live

First, download
[the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)
and update the project:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

Start Live once from the applications menu, then try online authorisation
again. If the browser still does not return to Live, check these in order:

1. Confirm that this project's handler is active:

   ```bash
   xdg-mime query default x-scheme-handler/ableton
   ```

   The command should print
   `io.github.shibco.ableton-linux.protocol.desktop`.

2. Test the launcher with a fake address:

   ```bash
   ableton-live 'ableton://invalid-ableton-linux-probe'
   ```

3. Test the desktop handoff with the same fake address:

   ```bash
   xdg-open 'ableton://invalid-ableton-linux-probe'
   ```

The fake address cannot authorise Live. Both test commands should open it. If
the first works and the second fails, log out and back in, then repeat both
tests. If both work but the browser still fails, try a fresh browser profile.
You can also compare the browser supplied by your distribution with its
Flatpak or Snap package.

Never share a real authorisation address or `.auz` file. When you
[open an issue](https://github.com/shibco/ableton-linux/issues), include the
handler result, your browser package, and whether each fake-address test
opened Live.

## Live cannot save a clip or track in the Browser

First, drag the same clip or track into the User Library. If that works, Live
cannot write to the original folder. Check it with:

```bash
test -w "/path/to/folder" && echo writable || echo not-writable
stat -f -c 'filesystem=%T' -- "/path/to/folder"
```

Choose another folder or correct its ownership if the first command prints
`not-writable`. System folders and read-only mounts cannot accept new Live
files. The Nix store at `/nix/store` is also read-only.

If the folder is writable and the User Library also fails, run the Linux
profiler from a repository checkout:

```bash
env ABLETON_LIBRARY_PATH="/path/to/folder" ./beta/scripts/ableton-linux-profiler.sh
```

The profiler does not print the folder path. When you
[open an issue](https://github.com/shibco/ableton-linux/issues), include its
output, your Live version and edition, and whether the User Library worked.

## Live has no sound

Open **Settings > Audio** and select:

- **Driver Type:** ASIO
- **Audio Device:** PipeASIO

Confirm that PipeWire and WirePlumber are running on the host. If audio
crackles, try a larger PipeASIO buffer:

```bash
env PIPEASIO_PREFERRED_BUFFERSIZE=512 ableton-live
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
your GPU. Every graphics chip identifies itself by a model number, and Live
keeps a list of old models it refuses to use. That number reaches Live
through Wine, and when Wine does not recognise your GPU it sends the number
of a 2012 model instead, which is on Live's list. Live then refuses a GPU
far newer than the one it thinks it sees.

To confirm this problem, open **Settings > Display & Input**. 
If **Enable GPU Renderer** is greyed out, and the note under it names a 
graphics card that is not the one in your computer, then you're seeing this
exact problem. 

To solve it: **update this project**.

Download [the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)
and run the update. It keeps your Live installation, your license, and
your projects:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

Start Live, open **Settings > Display & Input**, and turn on **Enable GPU
Renderer**. Live now names your real graphics card, and the setting stays
on.

If you still have problems, you can force this with:

```bash
env WINE_D3D_FORCE_GPU_RENDERING=1 ableton-live
```

If you run this flag, any diagnostics you send to Ableton will contain
inaccurate details about your GPU. We have added additional clarification so
crash reports, etc sent to Ableton engineering will clearly mark that your
GPU is being 'seen' by Live as a different model.

Start Live without the flag to go back.

If problems continue, [open an issue](https://github.com/shibco/ableton-linux/issues)
and include your graphics card model.

## CPU spikes when moving your mouse

Live keeps its current diagnostics in
`$XDG_STATE_HOME/ableton-wine/logs/live.log` (by default,
`~/.local/state/ableton-wine/logs/live.log`),
whether you start it from the desktop menu or a terminal. If Live's CPU
use jumps while you move the mouse, run:

```bash
grep -i "sustained present-size mismatch:" ~/.local/state/ableton-wine/logs/live.log
```

If that prints anything,
[open an issue](https://github.com/shibco/ableton-linux/issues) and paste
the whole line. It starts with `err:winediag:` and includes your desktop
environment and window DPI.

If nothing prints and Live's CPU use is still high, the cause is
different. Open an issue and describe what you were doing when it
happened.

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
env ABLETON_LIVE_VERSION=11 ableton-live
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

Check the current Link setting:

```bash
sh ~/Downloads/install-ableton-latest.run link status
```

If the command reports `policy: off`, enable Link:

```bash
sh ~/Downloads/install-ableton-latest.run link enable --mode=session
```

Start Live. Enable Show Link Toggle, then enable Link. If no peers appear,
allow UDP port 20808 in your firewall and confirm that every peer uses the same
local network. Guest and public Wi-Fi often block Link. A VPN does not make
Link peers on another network visible.

## Audio latency remains high

PipeWire 1.6 or newer can match its graph quantum to PipeASIO's buffer. Check
the PipeWire version before changing the host.

For advanced host tuning from a repository checkout, run:

```bash
./scripts/setup-realtime.sh
```

The script asks for `sudo`, gives your user account permission to run audio
at realtime priority, and tells the system to avoid moving Live's memory to
swap. Log out and back in after it completes. Run
`env ABLETON_RT=off ableton-live` to compare normal scheduling.

While Live runs, the launcher will set your computer to its fastest power
mode, and release that mode when Live exits, so battery use stays normal while
Live is closed. This uses the `power-profiles-daemon` service, which GNOME
and KDE ship by default. If you're having issues with this, you can run
Live without this feature: `env ABLETON_POWER=off ableton-live`.

You will

On Pop!_OS and other System76 computers, do not install the
`power-profiles-daemon` package. The package manager removes the System76
power management tools to make room for it. For now, you will need to manually set the performance profile yourself.

Earlier releases kept the CPU at full speed from every boot instead.
If this is happening to you, you can remove that old boot setting with:

```bash
sudo systemctl disable ableton-cpufreq-performance.service
sudo rm /etc/systemd/system/ableton-cpufreq-performance.service
sudo systemctl daemon-reload
```

From a repository checkout, run `./scripts/setup-realtime.sh` to remove it
instead.

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
sh ~/Downloads/install-ableton-latest.run update
```

Until you can update, drag Live's window once after leaving fullscreen to
clear the stuck image.

If fullscreen is still wrong after the update, launch once with
`env WINE_WIN32_FULLSCREEN_CLASS=off ableton-live`, then
[open an issue](https://github.com/shibco/ableton-linux/issues) and include
your desktop environment and whether that launch behaved differently.

## GNOME handles a Live shortcut instead of Live

GNOME uses Ctrl+Alt+Up and Ctrl+Alt+Down for workspace switching. These keys
conflict with Live's **Adjust Note Selection Chance** shortcuts. GNOME also
uses Ctrl+Alt+Delete for logout, which conflicts with **Delete Fades** in
Live 11.

Start Live with this command:

```bash
env ABLETON_SHORTCUTS=take ableton-live
```

The launcher turns off the Ctrl+Alt entries in conflict. It keeps
other keys and modifiers in the same settings. It restores the saved entries
after all Live sessions exit. It can also restore them after a crash. If you
change a shortcut while Live runs, it keeps your change.

The change applies to the complete GNOME session. The keys cannot switch a
workspace or open the logout dialog in another application while Live runs.

The default `ABLETON_SHORTCUTS=preserve` leaves every desktop shortcut
unchanged. For another desktop, change its shortcut settings when necessary.

## Report a problem

Use the [GitHub issue form](https://github.com/shibco/ableton-linux/issues/new/choose).
Include the Live edition, this project's release number, Linux distribution,
desktop environment, and the exact action that failed. Do not attach Ableton
installers, authorization files, licence keys, projects, or plugin credentials.
