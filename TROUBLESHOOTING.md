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
  - [Live reports that NTSync is inactive](#live-reports-that-ntsync-is-inactive)
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
  - [Live overloads after an update](#live-overloads-after-an-update)
  - [Live uses high CPU while idle](#live-uses-high-cpu-while-idle)
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
  - [Scrolling, panning or dragging stops working](#scrolling-panning-or-dragging-stops-working)
  - [A MIDI controller does not appear](#a-midi-controller-does-not-appear)
  - [An audio interface does not appear](#an-audio-interface-does-not-appear)
  - [Push 2 connection steps](#push-2-connection-steps)
  - [Push 3 stays on the connection screen](#push-3-stays-on-the-connection-screen)
  - [Push 3 plays notes on its own](#push-3-plays-notes-on-its-own)
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

Some X11 window managers, including i3, do not tell the installer your display
scale. A fresh Live setup then stops with these messages:

```text
!! cannot detect the display scale (non-GNOME desktop or headless session?)
!! a fresh prefix needs an explicit ABLETON_DPI_MODE=100 or =dpi<N>
```

For a desktop at 100% scale, run the installer again with:

```bash
env ABLETON_DPI_MODE=100 \
  sh ~/Downloads/install-ableton-latest.run install
```

For a desktop at 125% scale, use:

```bash
env ABLETON_DPI_MODE=dpi120 \
  sh ~/Downloads/install-ableton-latest.run install
```

For another scale, choose its value from the
[display scale table](#live-is-the-wrong-size-or-looks-blurry). The installer
continues when the value is valid, and Live uses that scale on its first start.
Thanks to the reporter of
[issue 246](https://github.com/shibco/ableton-linux/issues/246) for confirming
the 100% value on i3.

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

### Live reports that NTSync is inactive

NTSync helps Live meet short audio deadlines. This project requires Linux 6.14
or newer with NTSync active.

Close Live and run the installed check:

```bash
"${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/check-ntsync.sh"
```

A working setup ends with:

```text
OK: sync semantics hold, ntsync active (server holds /dev/ntsync)
```

Any other final line means that NTSync is inactive. Install your normal system
and kernel updates, restart the computer and run the check again.

If the command is missing, or the result still differs, update this project and
include the complete output in a
[new issue](https://github.com/shibco/ableton-linux/issues/new/choose). We can
then give you directions for your distribution.

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

Now open PipeASIO Settings again. Device, buffer, sample-rate and scheduling
changes apply while Live runs. If you change the number of input or output
channels, set Live's **Audio Device** to **None** and back to **PipeASIO** once.

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

Open **PipeASIO Settings** and lower the buffer. The change applies while Live
runs. Play your instrument after each change and stop when the monitoring delay
feels comfortable.

A lower value shortens the delay and gives Live less time to finish each audio
block. Raise it again if you hear crackles or dropouts.

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
audio. Open **PipeASIO Settings** and raise the buffer. The change applies while
Live runs. If that window will not open, you can
[edit the settings file instead](#changing-your-audio-settings-when-pipeasio-settings-wont-open).

To try a size without changing anything permanently:

```bash
env PIPEASIO_PREFERRED_BUFFERSIZE=512 ableton-live
```

#### Check that your processor is running at full speed

Many versions of Linux use aggressive power saving techniques - including CPU throttling - to save energy use. But a processor that slows itself down to save power will struggle
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

### Live overloads after an update

Live 12 now uses at most one audio worker per physical CPU core by default.
This lowers processor use on many computers. A demanding Set with several
independent instrument and effect chains can perform better with Live's own
worker count.

Start with a 256-frame buffer in PipeASIO Settings. If the Set becomes stable,
lower the buffer only when you need less monitoring latency.

If the overloads began after an update, compare the new default with Live's
own count:

1. Close every Live window.
2. Start Live with this command:

   ```bash
   env ABLETON_MAX_AUDIO_THREADS=off ableton-live
   ```

3. Play the same part of the Set.
4. Compare Live's Current CPU meter, overload indicator and audible dropouts.

If `off` performs better, use that command for the demanding Set.

If `off` gives the same result, return to a normal launch and work through
[audio crackling and distortion issues](#audio-crackling-and-distortion-issues).
Existing worker settings and later edits always take priority over the default.

### Live uses high CPU while idle

Open **Settings > Display & Input** and turn on **Enable GPU Renderer**. Close
the settings window and let the empty Set sit for a moment. Live's processor
use should settle.

If **Enable GPU Renderer** is greyed out on an older Intel graphics chip, try
one launch with:

```bash
env WINE_D3D_FORCE_GPU_RENDERING=1 ableton-live
```

Open **Settings > Display & Input** again and enable the GPU renderer. The
launch override ends when Live closes. If Live crashes or shows visual damage,
start it normally to return to the standard graphics path.

If the switch stays greyed out, or an empty Set still uses high CPU, open a
[new issue](https://github.com/shibco/ableton-linux/issues/new/choose) and name
your graphics card. If processor use rises only while the pointer moves, see
[CPU spikes when moving your mouse](#cpu-spikes-when-moving-your-mouse).

### Live is the wrong size, or looks blurry

If Live opens much bigger or smaller than everything else on your desktop, or
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
The plugin window should now reopen at a stable size and fit its frame.

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

For now, you can still play them alongside Live by running them in Carla and
routing audio and MIDI through PipeWire. Live then treats the plugin as an
external instrument or effect; save the Carla session separately.

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
[Live uses high CPU while idle](#live-uses-high-cpu-while-idle).
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

### Scrolling, panning or dragging stops working

The current runtime repairs pointer state after button releases, focus changes,
closed windows and device changes. Download the latest installer, run an
update, close every Live window and start Live again.

If scrolling or dragging still stops, compare one launch with the optional
pointer features turned off:

```bash
env WINE_X11_POINTER_FEATURES=disabled ableton-live
```

This comparison keeps ordinary wheel and button input. It turns off precise
scrolling, pinch zoom, inertia and middle-button navigation. The issue 122
pointer-clipping repair stays active.

If the problem disappears during that launch, open a
[new issue](https://github.com/shibco/ableton-linux/issues/new/choose). Name
your mouse or touchpad, desktop and the action that made input stop. If the
problem remains, include that result too. It tells us to look outside the
optional pointer path.

### A MIDI controller does not appear

Connect the controller while Live runs and wait a few seconds. Open
**Settings > Link, Tempo and MIDI**:

1. Look for your controller in the **Control Surface** chooser. If it is there,
   select it, then set **Input** and **Output** to your controller's ports.
2. If it is not listed, find its ports in the **MIDI Ports** table underneath
   and turn the **Remote** switch **On** for its input port. If your controller
   has motorised faders or lit buttons, turn **Remote** on for its output port
   as well.

Live's MIDI indicators in the top-right corner flash when it receives input.
This confirms the connection.

USB MIDI ports now use Windows-style names. After updating, select the input
and output again in any old control-surface row that became blank or stopped
responding.

If the ports remain missing, run:

```bash
aconnect -l
```

If the controller appears there, Linux can see it. Update this project and
open a [new issue](https://github.com/shibco/ableton-linux/issues/new/choose)
with the controller make, model and command output. If it stays absent, try
another USB port or data-capable cable until `aconnect -l` lists it.

After setup, disconnecting and reconnecting the same controller should restore
its input and output in the current Live session.

### An audio interface does not appear

Your interface will not appear by name in Live's **Audio Device** list, and that
is normal. On Linux, Live sees a single audio device called **PipeASIO**, which
passes sound to whichever interface your system is using.

Pick your interface in **PipeASIO Settings** instead, using the **Hardware
Setup** button in **Settings > Audio**. An interface connected after Live starts
should appear there within a few seconds.

When you select a specific interface, PipeASIO remembers it. Audio stays silent
while that interface is disconnected and resumes when its complete input or
output route returns. Automatic routing follows the default device selected by
your desktop.

If PipeASIO Settings will not open, see
[I can't change any audio settings in Live](#i-cant-change-any-audio-settings-in-live)
for how to set your devices in a text file instead.

If your interface is missing from PipeASIO Settings, check your desktop's sound
settings. Reconnect the interface until it appears there. If the desktop sees
it and PipeASIO Settings still does not, update this project and open a
[new issue](https://github.com/shibco/ableton-linux/issues/new/choose). Include
the interface make and model.

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
Include your distribution and desktop.

### Push 3 stays on the connection screen

Push 3 needs the current runtime, desktop USB access and a connection before
Live starts. Work through these steps:

1. Close Live and update this project:

   ```bash
   sh ~/Downloads/install-ableton-latest.run update
   ```

2. Select Control Mode on a standalone Push 3.
3. Check the USB connection:

   ```bash
   lsusb -d 2982:1969
   ```

   A line for `2982:1969` confirms the USB connection. Try another
   data-capable cable or USB port until that line appears.

4. Add USB access for your desktop session:

   ```bash
   printf '%s\n' 'SUBSYSTEM=="usb", ATTR{idVendor}=="2982", ATTR{idProduct}=="1969", MODE="0660", TAG+="uaccess"' |
     sudo tee /etc/udev/rules.d/60-ableton-push3.rules >/dev/null
   sudo udevadm control --reload-rules
   ```

5. Disconnect and reconnect Push 3.
6. Start Live while Push 3 is connected.

Keep the Push 3 control-surface rows empty. Live creates the surface
automatically. A successful connection clears Push's connection screen and
activates its display, pads and encoders.

If Live offers a firmware update, follow the power prompt. Start Live again
after Push restarts.

If Push stays on the connection screen, open a
[new issue](https://github.com/shibco/ableton-linux/issues/new/choose). Include
your distribution, desktop, Live version, firmware version and the output from
`lsusb -d 2982:1969`.

### Push 3 plays notes on its own

Update this project, then start Live again:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

Live runs a separate helper for Push 3. Before this fix, Live and the helper
saw each other's MIDI connection as a device, and one of them opened the
other's output as an input. Live's own pad lights then came back as notes on
channel 1, so pads stuck and repeated at full speed.

If you cannot update yet, cut the loop by hand after each Live start. List
the MIDI connections:

```bash
aconnect -l
```

Find the `WINE ALSA Output` port that shows `Connecting To` a port 0 under a
second `WINE midi driver` client. Remove that one connection, with your own
numbers in place of `131:1 129:0`:

```bash
aconnect -d 131:1 129:0
```

If the notes continue after the update, open a
[new issue](https://github.com/shibco/ableton-linux/issues/new/choose) and
include the output of `aconnect -l`.

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

Start Live and enable **Show Link Toggle** and Link again. Your peers should now
appear. If they do not, open a
[new issue](https://github.com/shibco/ableton-linux/issues/new/choose) and include
your network type, whether a VPN or firewall is active, and the output of
`sh ~/Downloads/install-ableton-latest.run link status`.

## Report a problem

Use the [GitHub issue form](https://github.com/shibco/ableton-linux/issues/new/choose).
Include the Live edition, this project's release number, Linux distribution,
desktop environment, and the exact action that failed. Do not attach Ableton
installers, authorization files, licence keys, projects, or plugin credentials.
