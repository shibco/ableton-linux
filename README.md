# Ableton Live 12, Max For Live and Push on Linux

Run Ableton Live 12 (and, experimentally, Live 11), Max for Live and Ableton Push 1 and 2 on a patched Wine. Featuring dozens of QoL fixes, reproducible builds, a single-file installer, and a beta test program with remote diagnostics. Very unofficial, not endorsed or affiliated in any way with Ableton. 

![screenshot.png](screenshot.png)

Follow me on [Mastodon](https://post.lurk.org/@shibacomputer) or [Bluesky](https://bsky.app/profile/shibco.newdesigncongress.org) to keep track of development.

DOWNLOAD HERE: https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run

Place this installer + an Ableton Live zip file downloaded from Ableton.com in the same directory, and run.

## Features

- Support for all Live 12 editions (Intro, Standard, Suite, Trial), and experimental Live 12 Beta support.
- Experimental Live 11 support: see [Live 11](#live-11).
- Push 1 + 2 support.
- Device recovery: audio and MIDI devices (Push included) survive in-session disconnect and reconnect.
- Experimental Max/MSP and Max for Live support.
- File dialogues including open/save dialogs are handled by your system's native file picker. 
- Dark/light theme mode that follows your system's settings.
- Unified top bar: Live's menu bar and menus take the colors of your Ableton theme and render in Ableton's own typeface, like the official Push standalone. Theme changes apply to the running Live when the settings dialog closes.
- System font support: display Ableton's UI with your desktop interface fonts.
- Low-latency audio via autobuilt PipeASIO, a native PipeWire ASIO driver, at 256 frames, with additional hardening to prevent crashes. Live can record from any PipeWire source, no JACK layer needed.
- VST3/JUCE/OpenGL editor windows render, take input, and scale correctly.
- HiDPI support: display scales from 100% to 250% are auto-detected and recalibrated on every launch.
- Extensions SDK support.
- VST specific fixes for Autuira, Pianoteq, SWAM and KORG (with others to follow).
- Reproducible builds.

## Getting started

Most popular distros and configs are supported. Flatpak / steam-run / sandboxed environments are not supported!

You need a 64-bit x86 machine, a 2022-or-newer distro (glibc 2.35+), and PipeWire 0.3.56 or newer (1.6+ recommended for the lowest latency). The installer checks all of this and tells you what's missing.

1. Download Ableton Live from ableton.com (the `ableton_live*.zip` download, any edition).
2. Download the latest installer: [install-ableton-latest.run](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run) (versioned builds are on the Releases tab).
3. Put both files in the same directory, then run the installer and follow its instructions: double click `install-ableton-latest.run`, or run

```
sh ~/Downloads/install-ableton-latest.run
```

The installer verifies itself, installs the patched Wine to `~/.local/opt`, detects your display scale, creates the Wine prefix at `~/.wine-ableton`, then starts the Ableton installer it found next to itself. Click through that as normal. Nothing outside your home directory is touched.

Then launch Live from your applications menu, or with:

```
ableton-live
```

Installing Live 11? Read [Live 11](#live-11) first.

## Updating

Download the newest installer and run it with `--update`:

`sh install-ableton-latest.run --update`

This updates the patched Wine, the launcher and the prefix policy. Ableton Live itself, your settings and your license are kept. Running the installer without `--update` offers the same update when it finds an existing installation.

## Issues?

File an issue on GitHub, there's some diagnostics scripts that will help diagnose the problem in ./beta/scripts.

## First launch

A few more things to do after you launch for the first time:

1. Ableton's Settings → untick Auto-Scale Plugin Window (prevents a plugin-window resize loop).
2. Preferences → Audio → Driver Type ASIO → Device PipeASIO.

If you encounter any unexpected audio behaviour, open an issue or +1 an existing one and I'll fix as a priority!

## Live 11

Live 11 support is new and experimental. A Live 11 install differs in three ways:

1. Set `ABLETON_LIVE_VERSION=11` when you run the installer. The prefix then gets the Live 11 runtime set (vcrun2019 and gdiplus instead of vcrun2022 and mfc42, plus Windows 10 mode). These pieces are downloaded during setup, so you need to be online:

    ```
    ABLETON_LIVE_VERSION=11 sh ~/Downloads/install-ableton-latest.run
    ```

2. After your first Live 11 launch, run the Max for Live fixup once. Max 8 crashes on its second start over a preferences file its first start wrote. The fixup moves that file aside (nothing is deleted) and Max regenerates it:

    ```
    sh ~/Downloads/install-ableton-latest.run --extract /tmp/ableton-kit
    bash /tmp/ableton-kit/scripts/setup-prefix.sh --post-first-run
    ```

3. Known limitation: previewing or importing WMA or video files crashes Live 11. A fix is planned. Avoid those files in Live's browser for now; details in [notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md](notes/ABLETON-WINE-LIVE11-WMVCORE-STUB.md).

The launcher finds Live 11 by itself. With both 11 and 12 in the prefix the newest wins; launch a specific version with `ABLETON_LIVE_VERSION=11 ableton-live`, or pin an exact edition with `ABLETON_LIVE_EXE`.

## Installing plugins

To run a plugin installer inside your Live environment:
```
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.11/bin/wine \
    "/path/to/PluginInstaller.exe"
```
You can also manually install plugin .vst3 files inside the `~/.wine-ableton/drive_c/Program Files/Common Files/VST3/` directory.

### Linux-native plugins

Do you have a Linux-only plugin? Run them in Carla or Ildaeil alongside Live and route audio and MIDI over PipeWire! Guide for this to follow!

## Push 1 + 2 support

This is built in. Use Preferences → Link, Tempo & MIDI → enable one `Push2` row, Live Port for both input and output, and enable the remote toggles. 

Like all other MIDI and Audio devices, Push will survive in-session disconnects. 

## Ableton Link

Link syncs tempo, beat and phase between apps on your LAN over UDP multicast (port 20808). Support is new and experimental. Two complementary setups, both applied by `./scripts/setup-link.sh` from a checkout of this repository (optional, idempotent, uses sudo for the route and firewall changes):

- Option A: Live joins directly. The script detects your primary LAN interface (refusing VPN carriers; Link does not work over VPN), adds a multicast route for `224.0.0.0/4`, and allows UDP 20808 in ufw/firewalld. Then enable the Link toggle in Live (Preferences → Link, Tempo & MIDI → "Show Link Toggle").
- Option B: native bridge (recommended). [jack_link](https://github.com/rncbc/jack_link), a small native Link peer, anchors the session on the JACK transport hosted by PipeWire, so it survives Live restarts and can sync native Linux apps. Build jack_link and create the `jack-link.service` user unit per [notes/ABLETON-WINE-LINK.md](notes/ABLETON-WINE-LINK.md), then re-run the script to enable it. The launcher also starts the bridge when it is installed but not already running.

Your router must forward multicast, and Link never crosses VPNs. Option A is unverified end-to-end under Wine: if Live's peer count stays at zero while traffic shows in tcpdump, the bridge still anchors and monitors the session.

Verification checklist:

- [ ] `ip route show 224.0.0.0/4` lists a route via the physical LAN interface, not a VPN device
- [ ] Firewall: `sudo ufw status | grep 20808` or `firewall-cmd --list-ports` shows `20808/udp`
- [ ] `sudo tcpdump -i <iface> -n udp port 20808` shows datagrams to `224.76.78.75.20808` once any peer is active
- [ ] `pgrep -a jack_link` shows the bridge running, and `~/.log/jack_link/` records session activity
- [ ] Live's Control-Bar Link indicator is enabled and reports a peer count ≥ 1
- [ ] A tempo change on any peer propagates to all others

## Lower latency (optional)

From a checkout of this repository, run:

```
./scripts/setup-realtime.sh
```

It installs the standard Linux pro-audio profile: realtime scheduling rights for the `audio` group, `vm.swappiness=10`, and a systemd unit that keeps the CPU governor on `performance`. It uses sudo, prints every file it writes, and never touches your bootloader (it advises about `threadirqs` and realtime kernels instead).

Log out and back in, then check that `ulimit -r` prints 95. The launcher probes for realtime rights on every start and from now on runs Live under realtime scheduling.

## Project structure

- [patches/](patches/): the Wine patch series + the pipeasio series
- [scripts/](scripts/): install, prefix setup, launcher
- [vendor/](vendor/): pinned build inputs
- [notes/](notes/): patch notes and investigations
- [tools/](tools/): diagnostic tools
- [bin/](bin/): launchers
- [dist/](dist/): build outputs
- [beta/](beta/): beta test program

## Development

Building needs `podman` or `docker`, about 10 GB of disk, `zstd`, `cabextract` and `binutils`. If you're working on this and want to try building and installing:

```bash
./build.sh
./scripts/install.sh
./scripts/setup-prefix.sh
WINEPREFIX=~/.wine-ableton ~/.local/opt/wine-d2d1-nspa-11.11/bin/wine \
    "/path/to/Ableton Live 12 Suite Installer.exe"
ableton-live
```

### Single-file installer

`./scripts/make-installer.sh` compiles everything into `dist/ableton-wine-setup-<version>.run`.

It verifies itself, installs the runtime, detects the display scale, creates the prefix, then runs the Ableton installer it finds next to itself (pauses so you can add one; prints the manual commands otherwise). 

#### Display scale

`setup-prefix.sh` and the launcher auto-detect the display scale (GNOME, KDE, sway, Hyprland, X11 `Xft.dpi`); the launcher recalibrates the prefix DPI on every start. Scales from 100% to 250% are calibrated: on GNOME the prefix tracks mutter's upscaled framebuffer (`LogPixels = 96 × ceil(scale)` plus a per-monitor DPI flag), on other desktops plain `LogPixels = round(96 × scale)`. Unfortunately, switching monitors still needs a Live restart if those monitors have different DPIs. You can manually override the default scaling behaviours with `ABLETON_DPI_MODE`.

### Other environment variables

Mostly unnecessary. But in case you need them: 

- `ABLETON_WINE_ROOT` runtime path (default `~/.local/opt/wine-d2d1-nspa-11.11`)
- `ABLETON_WINEPREFIX` prefix path (default `~/.wine-ableton`)
- `ABLETON_LIVE_VERSION` `11` | `12`: the Live version the prefix setup prepares for and the launcher picks (see [Live 11](#live-11))
- `ABLETON_LIVE_EXE` full path to a Live exe inside the prefix; picks one exact install when several editions coexist (the launcher refuses to guess)
- `ABLETON_DPI_MODE` `auto` | `preserve` | `100` | `fractional` | `dpi<N>` (force `LogPixels` N with no per-monitor flag, e.g. `dpi144` for 150% on a non-GNOME desktop)
- `ABLETON_THEME_MODE` `auto` | `dark` | `light` | `preserve`: the launcher syncs Live's light/dark theme key to the desktop scheme on every start; this overrides it
- `ABLETON_TOPBAR_MODE` `live` | `system` | `preserve` | `'#RRGGBB #RRGGBB'`: the launcher colors Live's menu bar and menus like your Ableton theme (`live`, the default) or like your desktop titlebar (`system`: KDE color scheme, or the stock GNOME header colors). `preserve` keeps the plain scheme colors, a hex pair forces bar and text colors
- `ABLETON_UI_FONT` `auto` | `preserve` | `off` | a font family name: the launcher renders Live's menu bar and dialogs with the Ableton Sans typeface shipped inside your Live install. `off` restores Tahoma, a family name uses that instead
- `ABLETON_DCOMP` `on` (default) | `off`: disables DirectComposition for that launch; an A/B check if the Learn View misrenders
- `PIPEASIO_*` audio driver overrides, e.g. `PIPEASIO_PREFERRED_BUFFERSIZE=512` if you hear crackles; defaults live in `~/.config/pipeasio/config.ini`
- `ENGINE=docker` for `build.sh` / `make-installer.sh`

### Steam Deck

Desktop Mode only. Add the host packages once, and (unfortunately) again after every SteamOS update.

```bash
sudo steamos-readonly disable
sudo pacman-key --init && sudo pacman-key --populate archlinux holo
sudo pacman -S cabextract binutils
sudo steamos-readonly enable
```

## More

You can learn all about the patches here: [patches/BASE.txt](patches/BASE.txt).

Questions? [cade@parare.al](mailto:cade@parare.al)

### AI Disclosure

Local models (Qwen 3.6) and Claude Opus were used during QA testing, documentation checking, and to help setup the build pipeline at the very end of this project's release.
