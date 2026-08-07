# Ableton Live on Linux

![Ableton Live running on Linux](screenshot.png)

Compose, perform, and produce with Ableton Live on a self-sovereign, open-source
stack. This project aims to make this popular Berlin-based DAW and its ecosystem
of products a first-class Linux citizen, with zero compromises.

It is also absolutely **not affiliated with or endorsed in any way by Ableton
GmbH** and respects the Ableton terms of service.

[Download the latest installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run)

## Features

- Live 12 Intro, Standard, Suite, Lite, Trial, and beta support
- Experimental Live 11, Max for Live, and Max 9 support
- Push 1 and Push 2 support (Push 3 and Move support coming soon!)
- Local-network Ableton Link support
- Experimental support for Ableton's forthcoming Extensions SDK
- Compatibility with Ableton's Splice integration
- Automatic recovery when in-use audio hardware or startup-detected MIDI
  controllers briefly disconnect
- Low-latency PipeASIO audio for live performance
- Linux desktop integration with native file types and dialogs
- Automatic light and dark desktop theme detection
- No-fuss support for desktop resolutions, HiDPI displays, and fractional scaling
- Fixes for VST-specific display, audio, and stability problems
- Dozens of nice-to-haves, quality-of-life fixes, and other polish
- Auditable builds with pinned inputs, checksum verification, and public documentation

## Installation

### Requirements

You need an x86-64 Linux system that meets Ableton Live's hardware requirements.

Additionally, you need:

- Linux 6.14 or newer with the `ntsync` module; older kernels work with a
  large performance loss (the launcher warns when `/dev/ntsync` is missing)
- glibc 2.35 or newer
- PipeWire 0.3.56 or newer (we recommend 1.6 or newer for audio performance)
- GStreamer with its base and good plugin sets
- `tar` and `zstd`
- your installation files and activation details from Ableton

For most people, a modern and up-to-date Linux distribution, such as SteamOS,
Ubuntu, CachyOS, Pop!_OS, Debian, or Arch, will already fulfil these
requirements.

### Getting started

1. Download the Ableton Live installation ZIP from Ableton.com.
2. Download [the latest version of our installer](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run).
3. Put both files in the same directory (such as `~/Downloads`).
4. From a terminal, run the installer:

   ```bash
   sh ~/Downloads/install-ableton-latest.run
   ```

That's it!

The installer also sets up Ableton Link and may ask for `sudo` to enable
local-network discovery. Pass `--no-link` if you do not use Link; the
installer remembers this choice, and `--link` turns Link setup back on.

### Running Live

This installer will add the necessary files to integrate Ableton Live into your
OS. You can start Live from the applications menu or via the command line:

```bash
ableton-live
```

You can also specify a Live Set to quickly open on launch:

```bash
ableton-live "/path/to/Your Set.als"
```

For Live 11, follow the [Live 11 instructions](#live-11).

### First launch

When you first start Live, you'll need to set up your audio. Go to
**Settings > Audio**, set **Driver Type** to **ASIO**, and set
**Audio Device** to **PipeASIO**.

### Updates

Ableton Live handles its own application updates.

This project does not update itself by choice. We only connect to the internet
when absolutely necessary.

To update this project's Wine runtime, launchers, and compatibility fixes,
download the latest release and run:

```bash
sh ~/Downloads/install-ableton-latest.run --update
```

This will bring the new fixes and features listed in the release notes to your
Live Linux environment. Your Live installation, authorization, and projects are
preserved. Compatibility-related Wine and Live settings may be updated.

Running the installer without `--update` offers the same compatibility update
when it finds an existing installation.

### Uninstalling

To remove this project's runtime and desktop integration while keeping Live and
its authorization:

```bash
sh ~/Downloads/install-ableton-latest.run --uninstall
```

To remove Live and its authorization too:

```bash
sh ~/Downloads/install-ableton-latest.run --uninstall --prefix
```

The second command asks for confirmation. Neither command touches your Live
Sets.

## Running different versions of Ableton Live on the same computer

This installer brings Linux compatibility to every edition of Live 11 and 12.
We worked hard on this! You can install one Live 11 edition and one Live 12
edition together.

### Live 12

When you run the installer normally, we assume you are installing Live 12. The
directions above will complete that installation for you.

### Live 11

We support Live 11, but with limited resources, we are choosing to focus on
Live 12 for now. Live 11 works well in most cases, but has seen less testing
than Live 12.

To install Live 11:

1. In your terminal window, tell the installer you want to install Live 11:

   ```bash
   ABLETON_LIVE_VERSION=11 sh ~/Downloads/install-ableton-latest.run
   ```

   The first setup downloads extra Live 11 support files, so it needs internet
   access.

2. After the first launch, complete the
   [one-time Max for Live repair](TROUBLESHOOTING.md#live-11-max-for-live-fails-after-the-first-launch).

3. Before importing WMA or video files, read the
   [Live 11 media limitation](TROUBLESHOOTING.md#live-11-media-files-can-crash-live).

When you run Live from the command line, the launcher will automatically detect
Live 11 if it is the only version installed. If Live 11 and Live 12 are both
installed, the launcher defaults to the newest major version.

Use `ABLETON_LIVE_VERSION=11 ableton-live` to select Live 11. If you install
multiple editions of the same major version, follow the
[launcher troubleshooting](TROUBLESHOOTING.md#the-launcher-finds-more-than-one-live-installation).

## Instruments and Effects

We are working on ensuring compatibility with as many VSTs as possible.

There are two common ways to install Windows plugins:

### If you have a Windows installer

1. Download your VST's installer.
2. Open a terminal window and run:

   ```bash
   WINEPREFIX="$HOME/.wine-ableton" \
     "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" \
     "/path/to/PluginInstaller.exe"
   ```

3. Your installer should install directly into your Ableton environment. By
   default, this is `~/.wine-ableton`.

You can also use the command in step 2 to run patches, software updaters, and
copy-protection tools.

### If you have a VST3 file

You can install Windows `.vst3` bundles by copying them directly into:

```text
~/.wine-ableton/drive_c/Program Files/Common Files/VST3/
```

### If you have a Linux VST or CLAP instrument or effect

We are working on proper Linux VST and CLAP support, but it is not implemented
in this project yet. For now, an
[experimental Carla workflow](TROUBLESHOOTING.md#using-linux-native-plugins)
can route Linux-native plugins through PipeWire.

## Hardware

This project supports Ableton Push alongside common audio interfaces and MIDI
controllers.

### Ableton Push 1 and 2 setup

1. Connect your Ableton Push.
2. Launch Ableton Live.

Live detects Push 1 automatically.

For Push 2, configure exactly one control-surface row under
**Settings/Preferences > Link, Tempo & MIDI**:

- **Control Surface:** Push2
- **Input:** Ableton Push 2 Live Port
- **Output:** Ableton Push 2 Live Port

Enable the input and output **Remote** switches. See
[Push troubleshooting](TROUBLESHOOTING.md#push-2-does-not-connect) if its
display does not start.

## Ableton Link

The installer sets up Ableton Link for you. In Live, enable
**Show Link Toggle** under
**Settings/Preferences > Link, Tempo & MIDI**, then enable Link in the control
bar. Devices on the same local network should appear automatically.

See [Link troubleshooting](TROUBLESHOOTING.md#ableton-link-does-not-find-peers)
if no peers appear.

## Getting help

Start with the [common troubleshooting steps](TROUBLESHOOTING.md).

If you're still stuck, file an issue [on GitHub](https://github.com/shibco/ableton-linux/issues/new/choose)
or in the `#issues` forum in the
[Ableton on Linux Discord](https://discord.gg/SZ2cQgV7U). A bot syncs Discord
reports to GitHub, so you can report a problem there without a GitHub account.

## Development and contributing

We welcome all kinds of contributions. If you've found a fix for a niche VST
or a workaround for a particular environment, please tell us!

Start with:

- [Build from source](BUILDING.md)
- [Implementation notes](notes/)

Contributors must follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Credits

Maintained by [Cade 'shibco' Diehm](https://shiba.computer/about) and
[Lucas 'ClickSentinel' Gillingham](https://github.com/ClickSentinel), with help from
[trendwhore](https://github.com/trendwhore), 
[jackson-57](https://github.com/jackson-57),
[jttdev](https://github.com/jttdev),
[astrazds](https://github.com/astrazds),
[Version33](https://github.com/Version33), and
[0tanh](https://github.com/0tanh). [yioannides](https://github.com/yioannides)
made the application and MIME icons.

This project is based off the `d2d1-dcomp` stack from 
[giang17/wine](https://github.com/giang17/wine), specifically, we forked
from branch `d2d1-dcomp-11.13` and `5c23dd1c` to continue building our work 
from these solid foundations. _Thank you! <3_ 

ENCORE by [wowitsjack](https://github.com/wowitsjack) informed some early patches.

Questions: [cade@parare.al](mailto:cade@parare.al)

## AI Disclosure

This project uses open-source local models Qwen 3.5, Qwen 3.6, and
Gemma 4 and Kimi K3 to assist with diagnosis, research, QA, documentation
review, and build scripts. We will not accept fully-vibecoded contributions
as the risk of regression is too high.
