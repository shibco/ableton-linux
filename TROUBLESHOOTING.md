# Troubleshooting Ableton Live on Linux

Here are some common ailments we've seen, and how to fix them.

Before you begin, make sure you download
[the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run) and run the update:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

This project is in active, rapid development and a newer version may
have already fixed your issue.

## Contents

- [Installation and updates](#installation-and-updates)
  - [The installer does not finish after Live installs](#the-installer-does-not-finish-after-live-installs)
  - [The Ableton installer window never progresses or shows graphical corruption on Hyprland](#the-ableton-installer-window-never-progresses-or-shows-graphical-corruption-on-hyprland)
  - [The installer asks for an explicit display scale](#the-installer-asks-for-an-explicit-display-scale)
  - [The installer says PipeWire is too old](#the-installer-says-pipewire-is-too-old)
  - [Enable and verify NTSync](#enable-and-verify-ntsync)
- [Live versions and launching](#live-versions-and-launching)
  - [The launcher finds more than one Live installation](#the-launcher-finds-more-than-one-live-installation)
  - [Live 11: Max for Live fails after the first launch](#live-11-max-for-live-fails-after-the-first-launch)
  - [Live 11: media files can crash Live](#live-11-media-files-can-crash-live)
- [Sound and PipeASIO](#sound-and-pipeasio)
  - [Live has no sound](#live-has-no-sound)
  - [I can't change any audio settings in Live](#i-cant-change-any-audio-settings-in-live)
  - [High audio latency with Live](#high-audio-latency-with-live)
  - [Audio crackling and distortion issues](#audio-crackling-and-distortion-issues)
  - [Audio cuts out for a few seconds, or plays at the wrong speed](#audio-cuts-out-for-a-few-seconds-or-plays-at-the-wrong-speed)
- [Performance, visuals and the Live interface](#performance-visuals-and-the-live-interface)
  - [Live uses high CPU or overloads at small buffers](#live-uses-high-cpu-or-overloads-at-small-buffers)
  - [Live is the wrong size, or looks blurry](#live-is-the-wrong-size-or-looks-blurry)
- [Plugins and Max for Live devices](#plugins-and-max-for-live-devices)
  - [A plugin's installer won't start](#a-plugins-installer-wont-start)
  - [My plugin won't activate, or its copy protection fails](#my-plugin-wont-activate-or-its-copy-protection-fails)
  - [A plugin I installed doesn't appear in Live](#a-plugin-i-installed-doesnt-appear-in-live)
  - [A plugin window keeps resizing itself, is smaller than its window frame, or has visible corruption](#a-plugin-window-keeps-resizing-itself-is-smaller-than-its-window-frame-or-has-visible-corruption)
  - [A plugin loads into a Live channel fine, and can play sound, but fails to open its window](#a-plugin-loads-into-a-live-channel-fine-and-can-play-sound-but-fails-to-open-its-window)
  - [My Linux VST or CLAP plugins don't appear in Live](#my-linux-vst-or-clap-plugins-dont-appear-in-live)
- [Inputs (mouse and keyboard) and devices (MIDI and controllers)](#inputs-mouse-and-keyboard-and-devices-midi-and-controllers)
  - [Live ignores or does something unexpected when you use a keyboard shortcut](#live-ignores-or-does-something-unexpected-when-you-use-a-keyboard-shortcut)
  - [CPU spikes when moving your mouse](#cpu-spikes-when-moving-your-mouse)
  - [My MIDI controller or audio interface doesn't show up in Live](#my-midi-controller-or-audio-interface-doesnt-show-up-in-live)
  - [Push 2 connection steps](#push-2-connection-steps)
  - [Push 3 stays on the connection screen](#push-3-stays-on-the-connection-screen)
  - [Ableton Move support](#ableton-move-support)
- [Ableton Link](#ableton-link)
  - [Ableton Link does not find peers](#ableton-link-does-not-find-peers)
- [Report a problem](#report-a-problem)

## Installation and updates

### The installer does not finish after Live installs

If the installer does not finish but the terminal is still responsive,
it is likely caused by a stuck component of the Ableton Live installer.

If you have an **Ableton USB Driver** icon in your taskbar, close it and
the installer will continue by itself. This was a known early issue: 
Ableton's own installer adds a small Windows helper program that Live does
not need on Linux.

Releases newer than `2026.08.04.1` fixed this, so ensure you download
[the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)
and run:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

### The Ableton installer window never progresses or shows graphical corruption on Hyprland

We have had reports that Ableton's own installer window shows heavy graphical corruption, or never advances, under Hyprland. It affects Wine on Hyprland generally rather than anything specific to this project, and we do not have a fix.

Log in to a GNOME or KDE session, run the installer there, and return to Hyprland once it finishes. Nothing about the installed result depends on the session you installed from.

If you find a Hyprland setting that fixes this, [open an issue](https://github.com/shibco/ableton-linux/issues) and tell us.

### The installer asks for an explicit display scale

Some X11 window managers, including i3, don't openly declare their DPI and this will
throw our installer. When installing for the first time, the Ableton-Linux installer expects an
explicit value for your DPI so it knows how to scale Ableton Live properly. 

If your system isn't declaring a DPI, you'll get errors like this:

```text
!! cannot detect the display scale (non-GNOME desktop or headless session?)
!! a fresh prefix needs an explicit ABLETON_DPI_MODE=100 or =dpi<N>
```

Check whether your desktop provides an Xft DPI value:

```bash
xrdb -query | grep '^Xft\.dpi:'
```

For an empty result on a desktop at 100% scale, run the installer with
`ABLETON_DPI_MODE=100`:

```bash
env ABLETON_DPI_MODE=100 \
  sh ~/Downloads/install-ableton-latest.run install
```

For a result such as `Xft.dpi: 120`, add `dpi` before the number:

```bash
env ABLETON_DPI_MODE=dpi120 \
  sh ~/Downloads/install-ableton-latest.run install
```

For another desktop scale, select the matching value from the
[display scale table](#live-is-the-wrong-size-or-looks-blurry).
The 100% fallback resolved the i3 installation reported in
[issue 246](https://github.com/shibco/ableton-linux/issues/246).

### The installer says PipeWire is too old

Different versions of Linux ship with different versions of the Linux audio
system, known as PipeWire. For best performance, we have targeted version 1.4.2
as a minimum version for Live's demanding audio requirements.

If the installer reports that 'your version of PipeWire is too old,' you need to
update PipeWire. To do this, you need to first know which version of Linux you use,
because the steps are different depending on your version.

To see which version of Linux you have, open a terminal and run:

```bash
grep PRETTY_NAME /etc/os-release
```

This will print your Linux distribution and its version number, such as 
`Linux Mint 22.3` or `Debian GNU/Linux 12`. From here, follow the steps below:

#### Debian 12

Install the latest version of PipeWire:

```bash
echo "deb http://deb.debian.org/debian bookworm-backports main" | sudo tee /etc/apt/sources.list.d/backports.list
sudo apt update
sudo apt install -t bookworm-backports pipewire wireplumber
```

#### Linux Mint 21 and 22, Pop!_OS 22.04 and 24.04

Install the latest version of PipeWire, packaged for Ubuntu-based systems by
Rob Savoury:

```bash
sudo add-apt-repository ppa:savoury1/pipewire
sudo apt update
sudo apt full-upgrade
```

Restart your computer, then run the installer again. It checks PipeWire and
tells you what it found.

If you ever want your original audio packages back, this puts them back:

```bash
sudo apt install ppa-purge
sudo ppa-purge ppa:savoury1/pipewire
```

### Enable and verify NTSync

NTSync lets Wine complete Windows wait operations in the Linux kernel. This
project requires the complete NTSync interface from Linux 6.14 or newer for
low-latency audio. The [Linux NTSync documentation](https://docs.kernel.org/6.14/userspace-api/ntsync.html)
describes the driver and its `/dev/ntsync` device.

Check your running kernel and device:

```bash
uname -r
ls -l /dev/ntsync
```

A listed character device means that the host driver is active. A kernel that
packages NTSync as a module can load it with these commands:

```bash
sudo modprobe ntsync
ls -l /dev/ntsync
printf '%s\n' ntsync | sudo tee /etc/modules-load.d/ntsync.conf
```

If `modprobe` reports an unavailable module, install a distribution kernel
with `CONFIG_NTSYNC=y` or `CONFIG_NTSYNC=m`. Use Linux 6.14 or newer, then
restart the computer.

After you install or update Ableton Linux, close Live and verify the complete
path:

```bash
"${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/check-ntsync.sh"
```

A successful check ends with this result:

```text
OK: sync semantics hold, ntsync active (server holds /dev/ntsync)
```

The device check verifies the host kernel. The dynamic check also verifies the
bundled Wine runtime and Windows synchronisation semantics.

## Live versions and launching

### The launcher finds more than one Live installation

When both Live 11 and Live 12 are installed, `ableton-live` starts the newest
major version. You can tell the launcher to start Live 11 with:

```bash
env ABLETON_LIVE_VERSION=11 ableton-live
```

When one prefix contains multiple editions of the same major version, the
launcher refuses to guess. You will instead need to set `ABLETON_LIVE_EXE` to the 
exact executable you want to start.

### Live 11: Max for Live fails after the first launch

After running Live 11 once, close Live and run:

```bash
sh ~/Downloads/install-ableton-latest.run --extract /tmp/ableton-kit
bash /tmp/ableton-kit/scripts/installer.sh prefix repair-live11
```

Live 11 will start again. A fix for this is coming soon.

### Live 11: media files can crash Live

If you import WMA or video files in Live 11, the codecs used by Live 11 will
cause Live under Linux to crash. This is a known issue, but we do not intend to
fix it at this time.

For technical details about this, please see the [WMVCore investigation](notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md).

## Sound and PipeASIO

### Live has no sound

Open **Settings > Audio** and select:

- **Driver Type:** ASIO
- **Audio Device:** PipeASIO

Set **Audio Device** to **None**, then select **PipeASIO** again. If the sound
breaks up, open **PipeASIO Settings** from the application menu and select a
larger buffer size.

You can also try a 512-frame buffer for one launch:

```bash
env PIPEASIO_PREFERRED_BUFFERSIZE=512 ableton-live
```

### I can't change any audio settings in Live

Your audio device, buffer size, and sample rate live in **PipeASIO Settings**.
Open it with the **Hardware Setup** button in **Settings > Audio**, or from your
application menu. If nothing happens when you click it, or you see an error message,
then either PipeASIO Settings failed to install during setup, or your computer
is missing some dependencies needed for it to open.

The window is built with a desktop toolkit called Qt 6, which your computer may
not have. Run the command for your system. To check which one you have, run
`grep PRETTY_NAME /etc/os-release`.

#### Debian 12, Linux Mint 21, Pop!_OS 22.04

```bash
sudo apt install libqt6widgets6 qt6-qpa-plugins qt6-wayland
```

#### Linux Mint 22, Pop!_OS 24.04, Ubuntu 24.04

```bash
sudo apt install libqt6widgets6t64 qt6-qpa-plugins qt6-wayland
```

#### Fedora

```bash
sudo dnf install qt6-qtbase-gui qt6-qtwayland
```

#### Arch

```bash
sudo pacman -S qt6-base qt6-wayland
```

On any other system, install Qt 6 Widgets and its platform plugins with your
package manager.

Now open PipeASIO Settings again. Each time you change a setting there, set
Live's **Audio Device** to **None** and back to **PipeASIO** so Live picks it
up.

If PipeASIO Settings still does not open, download
[the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)
and run the update. This puts the window back if it went missing during setup:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

Try PipeASIO Settings once more. If it _still_ does not open, run it from a
terminal:

```bash
pipeasio-settings
```

This should show you what prevents the application from starting. [Open an issue](https://github.com/shibco/ableton-linux/issues) and include the logs printed.

#### Changing your audio settings when PipeASIO Settings won't open

You can still change your Live audio settings even if the settings window won't open. 
To do so, close Live, open this text file in any text editor, make your changes, save 
it, and start Live again:

```bash
~/.config/pipeasio/config.ini
```

A new installation looks like this:

```ini
[pipeasio]
inputs = 2
outputs = 2
buffer_size = 256
fixed_buffer_size = true
auto_connect = true
```

Every setting goes under the `[pipeasio]` line. You can use all of these:

- `inputs` and `outputs` are how many channels Live sees.
- `buffer_size` is the buffer in frames, from 32 to 8192. A smaller number gives
  you less latency and more risk of crackle.
- `fixed_buffer_size` keeps your buffer size when another audio programme asks
  for a different one. Set it to `false` to follow the rest of your system.
- `auto_connect` connects Live to your audio devices when it starts.
- `sample_rate` pins a rate, such as `48000`. Leave it out to follow the rate
  your system already runs at.
- `follow_device_clock` set to `true` follows your audio interface's own clock
  instead of the system default.
- `realtime` set to `true` asks your system for real-time audio scheduling.
- `input_device` and `output_device` name one specific interface instead of your
  default. Run `wpctl status` to see the names.

To try a different buffer size for a single launch, without editing anything:

```bash
env PIPEASIO_PREFERRED_BUFFERSIZE=512 ableton-live
```

### High audio latency with Live

The most obvious way to resolve this is the same as other systems: lower the buffer 
size with **PipeASIO Settings** in your application menu or via (`pipeasio-settings` 
in a terminal), or via the manual methods above. Then, **Audio Device** in Live to
**None** and back to **PipeASIO**. 

As with Windows and macOS a lower buffer value shortens the delay but risks
audio artifacting. If you experience audio distortion or corruption, set the 
buffer to a higher number.

You can also make Live run in an experimental real-time audio mode. 

To do so, run the configuration tool here:

```bash
~/.local/share/ableton-wine/setup-realtime.sh
```

The script asks for admin permissions and once complete, you will need to log
out of your user account and back in for the changes to take effect.

Live also performs better when your processor is not being slowed down to save
power. Whenever Live is open, the launcher moves your computer to its
performance power profile, then puts it back when you close Live.

You can do this through the Power settings of your distro's OS settings.

If your latency is still too high, run the audio report and attach it when you
[open an issue](https://github.com/shibco/ableton-linux/issues):

```bash
~/.local/share/ableton-wine/audio-report.sh
```

### Audio crackling and distortion issues

When Live struggles to maintain real-time audio, playback can crackle or
distort. Several conditions cause these symptoms, so work through the steps in
order.

#### Update to the latest release

Older installations and runtimes cause many crackling reports. Runtime updates
have fixed many of those faults. Before you change any settings, download
[the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)
and run the update:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

#### Raise your buffer size

As with Windows and macOS, a larger buffer gives Live more time to process
audio. Open **PipeASIO Settings**, raise the buffer, then set **Audio Device**
in Live to **None** and back to **PipeASIO**. If that window will not open, you
can [edit the settings file instead](#changing-your-audio-settings-when-pipeasio-settings-wont-open).

To try a size without changing anything permanently:

```bash
env PIPEASIO_PREFERRED_BUFFERSIZE=512 ableton-live
```

#### Check that your processor is running at full speed

Many versions of Linux use aggressive power saving techniques - including CPU throttling
- to save energy use. But a processor that slows itself down to save power will struggle
to play audio properly, and when this happens, Live's audio starts to distort and crackle.

By default, the launcher switches your Linux computer to its performance power profile 
whenever Live is open, but it needs the `powerprofilesctl` command to do it. The
[high audio latency](#high-audio-latency-with-live) entry above sets that up,
and turns on real-time audio mode while you are there.

In most distros, you can manually set the power mode in your settings.

#### Give Live as much of your system's resources as possible

Everything else running on your computer competes with Live for the same
processor time. 

To see if this is affecting your Live audio output, close other audio 
applications, web browsers, and anything
syncing files in the background, then close and re-open Live. 
If the crackling only starts once a set gets busy, freeze or resample 
your heaviest tracks as you would on
any other system.

#### If you use two separate audio devices

In rare cases, sometimes splitting your audio inputs and outputs on different devices
can cause crackling. If you are hearing audio artifacts when using
two different devices for input and output, then this is a bug and we would like
to hear from you.

Run the audio report and attach it when you
[open an issue](https://github.com/shibco/ableton-linux/issues). It records your
devices, your buffer, and the errors PipeWire logged:

```bash
~/.local/share/ableton-wine/audio-report.sh
```

It helps to name your devices, so that PipeASIO cannot pick up a stale system
default and drag a third clock into the graph. Run `wpctl status` to see what
yours are called, then add them to `~/.config/pipeasio/config.ini`. 

Here's an example:

```ini
[pipeasio]
input_device = <name of your input device>
output_device = <name of your output device>
```

#### Still crackling

For all other issues with audio, run the audio report and attach it when you
[open an issue](https://github.com/shibco/ableton-linux/issues).

```bash
~/.local/share/ableton-wine/audio-report.sh
```

### Audio cuts out for a few seconds, or plays at the wrong speed

Wait a few seconds. If audio returns at the correct speed, there is nothing
else to do. Another audio programme changed the buffer size shared with Live,
and PipeASIO paused while Live changed to the same size. If this happens 
continuously, [open an issue](https://github.com/shibco/ableton-linux/issues)
and we will help you track down the culprit on your system.

If audio stays silent or plays too fast or too slow, update this project. Until
you can update, close Live, run this command, then start Live again:

```bash
pw-metadata -n settings 0 clock.force-quantum 0
```

If the problem returns, run the audio report from the previous entry and attach
it when you open an issue.

## Performance, visuals and the Live interface

### Live uses high CPU or overloads at small buffers

A small PipeASIO buffer increases the number of audio blocks that enter Live.
During stable audio processing at 48 kHz, 64-frame blocks call Live 750 times
each second. A 32-frame buffer raises that rate to 1,500 calls each second.

Live's Average and Current CPU meters measure audio-processing time against
the buffer deadline. Linux process CPU measures a different value. See
[Ableton's CPU meter guide](https://help.ableton.com/hc/en-us/articles/360019151379-Live-s-CPU-Meter).

The published 23% and 37% reductions measured Linux process CPU for an empty
Set. The change reduced Live worker wake-ups. PipeASIO and Wine audio paths
stay unchanged. The
[Live worker and Linux process CPU report](notes/FINDINGS-PIPEASIO-CPU-2026-08-20.md)
records the comparisons and their limits.

The physical-core limit trades some parallel DSP capacity for fewer worker
wake-ups. A plug-in-heavy Set can show a lower average value and still cross
the audio deadline. Use 256 frames as a starting point. Try 128 frames when
the lower latency helps your work.

On a normal Live 12 launch, the launcher starts with the physical-core count
available to it when that value is below Live's calculated audio thread count.
An existing Live setting, a previous launcher choice, or a later edit takes
priority.

These commands override the policy for one cold launch:

```bash
env ABLETON_MAX_AUDIO_THREADS=auto ableton-live  # recalculate an earlier launcher value
env ABLETON_MAX_AUDIO_THREADS=8 ableton-live     # request an exact value
env ABLETON_MAX_AUDIO_THREADS=off ableton-live   # restore Live's calculated count
```

An automatic or exact count persists in Live. `off` removes the line when the
launcher's marker still describes it. A later normal launch can apply the
automatic count again. Existing settings and later user edits stay unchanged.

Use `off` for the first comparison when a demanding Set overloads after an
update. Exit every Live process, launch with `off`, and play the same Set
section. Compare Current CPU, overload events, audible glitches, and xruns.
Use the value that gives the Set enough parallel DSP capacity.

Review the value after you move the prefix to a different processor. A first
launch under `taskset` or another CPU limit can save the restricted physical
core count. Run an explicit `auto` launch with normal CPU access to recalculate
an untouched launcher value.

The launcher adds this Live 12 setting when the selected value falls below
Live's calculated count:

```text
-MaxAudioThreads=<number>
```

Live stores the setting in this file:

```text
~/.wine-ableton/drive_c/users/$USER/AppData/Roaming/Ableton/Live 12*/Preferences/Options.txt
```

Check the value that Live will read:

```bash
rg '^-MaxAudioThreads=' \
  "${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"/drive_c/users/*/AppData/Roaming/Ableton/Live\ 12*/Preferences/Options.txt
```

Exit Live before editing the file. Remove the line that starts with
`-MaxAudioThreads=` to restore Live's calculated count. Play a demanding Set
when comparing values. A smaller count reduces worker coordination. A larger
count gives independent audio chains more parallel capacity.

The controlled evidence uses an empty Set on one 16-core, 32-thread host.
Project routing, plug-ins, and processor topology change the best count. Run
the [NTSync verification](#enable-and-verify-ntsync) before CPU comparisons.

Keep PipeASIO real-time scheduling off for normal use. Upstream made it opt-in
after an Ableton regression was traced to the callback using `SCHED_FIFO`; see
[PipeASIO issue 4](https://github.com/M0n7y5/pipeasio/issues/4) and the
[PipeASIO performance notes](https://github.com/M0n7y5/pipeasio/blob/v1.5.0/README.md#performance).

At 128 or 256 frames, use this comparison.

1. Record Live's CPU use for one Set section with PipeASIO.
2. Select another audio driver in Live.
3. Record Live's CPU use for the same Set section.
4. Select PipeASIO again.
5. Open the Display and Input page in Live settings.
6. Enable the GPU renderer.
7. Record Live's CPU use for the same Set section.
8. Compare the 3 CPU measurements.

If your processor only spikes while you move the mouse, see
[CPU spikes when moving your mouse](#cpu-spikes-when-moving-your-mouse) instead.
If audio is crackling as well, work through
[audio crackling and distortion issues](#audio-crackling-and-distortion-issues).

#### If Enable GPU Renderer is greyed out

Live decides whether to offer its GPU renderer from the identity number of your
graphics chip, and it turns down a list of Intel chips sold between 2004 and
2014. 

Luckily, you are running Live on Linux, and many of those chipsets are well
supported. 

Try starting Live with:

```bash
env WINE_D3D_FORCE_GPU_RENDERING=1 ableton-live
```

Then open **Settings > Display & Input** and turn on **Enable GPU Renderer**.

If this causes a crash or any visual distortion, the setting is not saved when
Live exits. Simply run `ableton-`live without the prepended setting.

If the Enable GPU Renderer setting is still greyed out, [open an issue](https://github.com/shibco/ableton-linux/issues) and tell us which card you have.

### Live is the wrong size, or looks blurry

If Live open much bigger or smaller than everything else on your desktop, or
if its text is blurry, Live is trying to display at a resolution that isn't
aligned with your desktop.

The launcher reads your display scale every time Live starts, so this normally
takes care of itself. When it gets it wrong, tell Live your scale yourself:

1. Close Live.
2. Open your computer's Display settings and note the scale your screen is set
   to, such as 125%. If your screens use different scales, use the monitor you
   plan to use Live with.
3. Confirm your desktop type. In a terminal window, run this command:

   ```bash
   echo $XDG_CURRENT_DESKTOP
   ```

4. Look your scale up in this table and start Live with that value. GNOME
   scales differently to everything else, so it has its own column. KDE,
   Cinnamon, COSMIC, sway, Hyprland, i3, and other X11 window managers use the
   right-hand column.

| Your display scale | GNOME | Other |
| --- | --- | --- |
| 100% | `100` | `100` |
| 125% | `fractional` | `dpi120` |
| 150% | `fractional` | `dpi144` |
| 175% | `fractional` | `dpi168` |
| 200% | `fractional` | `dpi192` |
| 225% | `fractional288` | `dpi216` |
| 250% | `fractional288` | `dpi240` |

So for a KDE desktop set to 125%, you would start Live with:

```bash
env ABLETON_DPI_MODE=dpi120 ableton-live
```

For a GNOME desktop set to 150%:

```bash
env ABLETON_DPI_MODE=fractional ableton-live
```

And for Linux Mint's Cinnamon desktop set to 200%:

```bash
env ABLETON_DPI_MODE=dpi192 ableton-live
```

Start Live that way each time. Scales below 100% or above 250% are not supported.

If you have already set Live's scaling up by hand and want it left alone, start
Live like this instead:

```bash
env ABLETON_DPI_MODE=preserve ableton-live
```

If Live is still the wrong size,
[open an issue](https://github.com/shibco/ableton-linux/issues) and tell us your
desktop and the scale you have set.

#### Full Screen looks wrong, or won't go away

In Full Screen, Live's content can sit shifted from where it should be, so your
clicks land away from what you aimed at. Coming out of Full Screen can also
leave the old image on your screen.

Drag Live's window once. That clears the stuck image straight away.

If Full Screen is still shifted, start Live with:

```bash
env WINE_WIN32_FULLSCREEN_CLASS=off ableton-live
```

This setting is not saved when Live exits, so run `ableton-live` on its own to
go back to normal.

Either way, [open an issue](https://github.com/shibco/ableton-linux/issues) and
tell us your desktop, and whether Full Screen was still shifted with that
command.

## Plugins and Max for Live devices

### A plugin's installer won't start

Windows plugin installers do not run by double-clicking them. Start the
installer inside your Live environment instead:

```bash
env WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" \
  "/path/to/PluginInstaller.exe"
```

Use the same command for plugin updaters and for copy-protection tools such as
iLok License Manager.

If the installer opens but stops partway,
[open an issue](https://github.com/shibco/ableton-linux/issues) and tell us the
plugin and everything the terminal printed.

### My plugin won't activate, or its copy protection fails

Activation tools and licence managers are Windows programs too, so run them the
same way you ran the installer:

```bash
env WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" \
  "/path/to/LicenceManager.exe"
```

Copy protection is something we are actively working on, and not every scheme
works yet. One known case is an activation window that opens but whose menus
close the instant you click them, which we are tracking in
[issue 171](https://github.com/shibco/ableton-linux/issues/171).

If your plugin will not activate,
[open an issue](https://github.com/shibco/ableton-linux/issues) and tell us the
plugin, the copy-protection system it uses, and what the activation window did.

### A plugin I installed doesn't appear in Live

Windows plugins live in one of two folders inside your Live environment,
depending on their format:

```text
~/.wine-ableton/drive_c/Program Files/Common Files/VST3/
~/.wine-ableton/drive_c/Program Files/Steinberg/VSTPlugins/
```

If your plugin is in neither, its installer put it somewhere else. Run the
installer again and watch which folder it offers you, or copy the plugin into
one of these yourself.

Live finds the VST3 folder on its own. For VST2 plugins, point Live at the
folder once:

1. In Live, open **Settings > Plug-Ins**.
2. Under **Plug-In Sources**, click **Browse** next to **VST Plug-In Custom
   Folder** and choose `C:\Program Files\Steinberg\VSTPlugins`. Live sees your
   Live environment as its `C:` drive, so `~/.wine-ableton/drive_c/` is `C:\`.
3. Set **Use VST Plug-In Custom Folder** to **On**.

If you installed the plugin while Live was open, Live will not notice it until
it scans again. Press **Rescan** on that same settings page.

If the plugin is in the right folder and still does not appear,
[open an issue](https://github.com/shibco/ableton-linux/issues) and tell us the
plugin, its format, and where its installer put it.

### A plugin window keeps resizing itself, is smaller than its window frame, or has visible corruption

If you're having issues with a plugin's window, a common fix is to right-click the plugin's 
title bar in Live's device rack, turn off **Auto-Scale Plugin Window**, 
then close the plugin and open it again.

Only some plugins are affected, so leave the setting alone for the rest.

For technical details about this, please see the
[Pianoteq investigation](notes/ABLETON-WINE-PIANOTEQ-DPI-GHOST-BUG.md).

### A plugin loads into a Live channel fine, and can play sound, but fails to open its window

To diagnose this, start by running the affected plugin in Live, and then in a separate terminal window,
run this command:

```bash
grep -i "Failed to realize\|glActiveTexture" ~/.local/state/ableton-wine/logs/live.log
```

If after running that command, you receive output, this is a known issue. To mitigate it, run this command
in a terminal window:

```bash
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.13/bin/wine reg add 'HKCU\Software\Wine\X11 Driver' /v UseEGL /d N /f
```

Start Live and open the plugin again and it should open. This setting changes how Live is rendered on
your computer and the new setting is saved between Live sessions. To undo it:

```bash
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.13/bin/wine reg delete 'HKCU\Software\Wine\X11 Driver' /v UseEGL /f
```

If the plugin still does not open,
[open an issue](https://github.com/shibco/ableton-linux/issues) and include your
graphics card, driver version, and whether your session is X11 or Wayland.

### My Linux VST or CLAP plugins don't appear in Live

Live runs as a Windows program, so it only loads Windows plugins. Your
Linux-native VST and CLAP plugins will not show up in Live's browser, and no
setting will change that yet. We are working on implementing support for 
Linux native plugins.

For now, you can still play them alongside Live by running them in Carla and routing the
audio and MIDI through PipeWire. See
[Linux-native plugin routing](notes/ABLETON-WINE-PLUGIN-BRIDGING.md) for the
steps and for what does not work yet.

## Inputs (mouse and keyboard) and devices (MIDI and controllers)

### Live ignores or does something unexpected when you use a keyboard shortcut

Your desktop can claim a key combination before Live ever sees it. On GNOME,
Ctrl+Alt+Up and Ctrl+Alt+Down switch workspaces instead of running Live's
**Adjust Note Selection Chance**, and Ctrl+Alt+Delete opens the logout dialog
instead of **Delete Fades** in Live 11.

On GNOME, a normal launch borrows those keys while Live is open.

Your shortcuts come back when you close Live, and after a crash. While Live
runs, those combinations stop working elsewhere on your desktop, so you cannot
switch workspaces with them until you close Live.

To keep the desktop bindings instead, opt out for that launch:

```bash
env ABLETON_SHORTCUTS=preserve ableton-live
```

Use `ABLETON_SHORTCUTS=take` to request the normal behaviour explicitly.

On any other desktop, change the conflicting shortcut in your desktop's own
settings.

If a shortcut still does nothing in Live,
[open an issue](https://github.com/shibco/ableton-linux/issues) and tell us the
shortcut, your desktop, and what happened instead.

### CPU spikes when moving your mouse

Live's processor use climbs while you move the pointer across its window, and
settles again when you stop.

First check that **Enable GPU Renderer** is turned on, as described in
[Live uses high CPU or overloads at small buffers](#live-uses-high-cpu-or-overloads-at-small-buffers).
That accounts for most of these.

If it still happens, see whether Live recorded it:

```bash
grep -i "sustained present-size mismatch:" ~/.local/state/ableton-wine/logs/live.log
```

If that prints a line,
[open an issue](https://github.com/shibco/ableton-linux/issues) and paste the
whole line. If it prints nothing and your processor use is still high, open an
issue anyway and describe what you were doing, because the cause is something
else.

When you are testing Live 12 Beta, use `live-beta.log` in that same folder.

### My MIDI controller or audio interface doesn't show up in Live

Connect your gear before you start Live. Live only finds MIDI devices that were
already plugged in when it started, so anything you connect afterwards stays
invisible until you close Live and open it again. A device that was connected
before Live started keeps working if you unplug it and plug it back in.

#### MIDI controllers

With the controller connected and Live running, open
**Settings > Link, Tempo & MIDI**:

1. Look for your controller in the **Control Surface** chooser. If it is there,
   select it, then set **Input** and **Output** to your controller's ports.
2. If it is not listed, find its ports in the **MIDI Ports** table underneath
   and turn the **Remote** switch **On** for its input port. If your controller
   has motorised faders or lit buttons, turn **Remote** on for its output port
   as well.

Live's MIDI indicators in the top right corner flash when it receives something,
which is the quickest way to tell whether it worked.

If your controller was connected before launch and still does not appear,
[open an issue](https://github.com/shibco/ableton-linux/issues) and tell us its
make and model.

#### Audio interfaces

Your interface will not appear by name in Live's **Audio Device** list, and that
is normal. On Linux, Live sees a single audio device called **PipeASIO**, which
passes sound to whichever interface your system is using.

Pick your interface in **PipeASIO Settings** instead, using the **Hardware
Setup** button in **Settings > Audio**. If you connected the interface after
Live started, set **Audio Device** to **None** and back to **PipeASIO** first.
If it is still missing, close Live and start it again.

If PipeASIO Settings will not open, see
[I can't change any audio settings in Live](#i-cant-change-any-audio-settings-in-live)
for how to set your devices in a text file instead.

If your interface is missing from PipeASIO Settings as well, it is your system
that cannot see it rather than Live. Check that it appears in your desktop's own
sound settings first, then
[open an issue](https://github.com/shibco/ableton-linux/issues) and tell us the
make and model.

### Push 2 connection steps

Connect Push 2 before you start Live. Then open
Settings > Link, Tempo and MIDI and set up one control-surface row:

- control surface: `Push2`
- input: `Ableton Push 2 Live Port`
- output: `Ableton Push 2 Live Port`

Turn on the Remote switches for that input and output. Keep one Push2 row.

For a dark display, close Live normally. Reconnect Push 2 and start Live again.

Share unresolved display results in a
[new GitHub issue](https://github.com/shibco/ableton-linux/issues/new).
Include your distribution and desktop. The
[Push 2 display bridge note](notes/ABLETON-WINE-PUSH2-DISPLAY.md) explains the
technical design.

### Push 3 stays on the connection screen

Push 3 needs desktop USB access and a current Wine prefix. Complete these
checks:

1. Select control mode on a standalone Push 3.
2. Check the USB connection.

   ```bash
   lsusb -d 2982:1969
   ```

   A line for `2982:1969` confirms the USB connection. Try another
   data-capable cable or USB port until that line appears.

3. Add USB access for your desktop session.

   ```bash
   printf '%s\n' 'SUBSYSTEM=="usb", ATTR{idVendor}=="2982", ATTR{idProduct}=="1969", MODE="0660", TAG+="uaccess"' |
     sudo tee /etc/udev/rules.d/60-ableton-push3.rules >/dev/null
   sudo udevadm control --reload-rules
   ```

4. Disconnect and reconnect Push 3.
5. Refresh the prefix after a source build.

   ```bash
   scripts/setup-prefix.sh --refresh
   ```

6. Start Live while Push 3 is connected.

Live scans its MIDI device list during startup. Live starts `Push3.exe` after
it finds the Push USB identity. A successful session ends with `Push is go`.
Keep the Push 3 control-surface rows empty. Live detects the surface
automatically. Follow the power prompt when Live installs firmware, then start
Live again after Push restarts.

You can test host access from a source checkout:

```bash
cc -std=c11 -O2 -Wall -Wextra tools/push3usb.c \
  $(pkg-config --cflags --libs libusb-1.0) -o /tmp/push3usb
/tmp/push3usb --claim
```

With host access, the probe reports `claim=ok` for interfaces 0 and 6. A
`LIBUSB_ERROR_ACCESS` result points to the device rule.

Add your results to
[Push 3 support issue 26](https://github.com/shibco/ableton-linux/issues/26).
Include your distribution, desktop, Live version, firmware version, and probe
output. Replace the controller serial number with `[redacted]` in every shared
USB trace.

### Ableton Move support

Ableton Move support is in development. The current controller support covers
Push 1, Push 2, and Push 3 in controller mode.

## Ableton Link

### Ableton Link does not find peers

Link peers must share a local network that carries multicast. Many guest and
public Wi-Fi networks block multicast. Multicast also stops at a VPN tunnel:
peers on the far side of a VPN cannot be discovered, while peers on your own
network remain reachable with the VPN connected.

Check these in order:

1. If you run a firewall, allow UDP port 20808.
2. Check the current Link mode:

   ```bash
   sh ~/Downloads/install-ableton-latest.run link status
   ```

3. Enable session mode if Link is off:

   ```bash
   sh ~/Downloads/install-ableton-latest.run link enable --mode=session
   ```

Start Live and enable **Show Link Toggle** and Link again. See
[Ableton Link diagnostics](notes/ABLETON-WINE-LINK.md) if peers still do not
appear.

## Report a problem

Use the [GitHub issue form](https://github.com/shibco/ableton-linux/issues/new/choose).
Include the Live edition, this project's release number, Linux distribution,
desktop environment, and the exact action that failed. Do not attach Ableton
installers, authorization files, licence keys, projects, or plugin credentials.
