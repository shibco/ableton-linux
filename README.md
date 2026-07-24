# Ableton Live 12, Max For Live, Link and Push on Linux

Write, compose, experiment and perform with Ableton Live 12 (and, experimentally, Live 11), Max for Live, and Ableton Push 1 and 2 on your distro of choice with a fully customised, purpose-built Wine fork that makes Live a first-class Linux citizen. 

**Very unofficial, not endorsed by or affiliated in any way with Ableton.** 

![screenshot.png](screenshot.png)

DOWNLOAD HERE: https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run

Place this installer + an Ableton Live zip file downloaded from Ableton.com in the same directory, and run. For more details, see [Getting Started](#getting-started).

**Credits:** maintained by [Cade 'shibco' Diehm](https://shiba.computer/about), with support from [ClickSentinel](https://github.com/ClickSentinel) and the Ableton Linux Discord community including [jackson-57](https://github.com/jackson-57), [jttdev](https://github.com/jttdev), [astrazds](https://github.com/astrazds), [Version33](https://github.com/Version33) and [0tanh](https://github.com/0tanh). Application and MIME type icons by [yioannides](https://github.com/yioannides). Shout out to [wowitsjack](https://github.com/wowitsjack)/Antlers! on the Ableton Linux Discord server for [ENCORE](https://github.com/wowitsjack/ENCORE).

## Features

- Support for all Live 12 editions (Intro, Standard, Suite, Trial), and experimental Live 12 Beta support.
- Experimental Live 11 support: see [Live 11](#live-11).
- Push 1 + 2 support (with highly speculative and experimental Push 3 support).
- Experimental Ableton Link support: keep tempo in sync with other apps and instruments on your network. See [Ableton Link](#ableton-link).
- Device recovery: audio and MIDI devices (Push included) survive in-session disconnect and reconnect.
- Experimental Max/MSP and Max for Live support.
- Open/save dialogs use your system's native file picker.
- Show in Explorer opens your system's file manager with the file selected.
- Dark/light theme mode that follows your system's settings.
- Unified top bar: Live's menu bar and menus take the colors of your Ableton theme and render in Ableton's own typeface, like the official Push standalone. Theme changes apply to the running Live when the settings dialog closes.
- System font support: display Ableton's UI with your desktop interface fonts.
- Low-latency audio via autobuilt PipeASIO, a native PipeWire ASIO driver, at 256 frames, with additional hardening to prevent crashes. Live can record from any PipeWire source, out of the box.
- Optional one-command tuning that lets Live run at even lower latency without crackles. See [Lower latency](#lower-latency-optional).
- VST3/JUCE/OpenGL editor windows render, take input, and scale correctly.
- HiDPI support: display scales from 100% to 250% are auto-detected and recalibrated on every launch.
- Experimental support for Ableton's forthcoming Extensions SDK.
- VST specific fixes for Arturia, Pianoteq, SWAM, U-he, KORG and many others, with more to follow.
- Reproducible builds.
- Stable, fast, and integrated into your Linux operating system.

## Getting started

Most popular distros and configs are supported. Flatpak / steam-run / sandboxed environments are not yet fully supported!

You need a 64-bit x86 machine, a 2022-or-newer distro (glibc 2.35+), and PipeWire 0.3.56 or newer (1.6+ recommended for the lowest latency). The installer checks all of this and tells you what's missing.

1. Download Ableton Live from ableton.com (the `ableton_live*.zip` download, any edition).
2. Download the latest installer: [install-ableton-latest.run](https://github.com/shibco/ableton-linux/releases/latest/download/install-ableton-latest.run) (versioned builds are on the Releases tab).
3. Put both files in the same directory (or keep the Ableton zip in `~/Proprietary`), then run the installer and follow its instructions: double click `install-ableton-latest.run`, or run

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

1. Download the newest installer.
2. Run it: `sh install-ableton-latest.run --update`
3. There is no step 3!

This updates the patched Wine, the launcher and the prefix policy. Ableton Live itself, your settings and your license are kept. Running the installer without `--update` offers the same update when it finds an existing installation.

Updating from 2026.07.18.1 also removes the `-DontCombineAPCs` line that release added to Live's Options.txt. The line causes stuttering, slowed-down audio during playback (issue #29). The update removes it even if you added it by hand.

## Nix and NixOS

The repo is also a Nix flake that builds the whole stack from source — the patched Wine, PipeASIO, and the launcher — as one package. The `.run` installer above remains the path for every other distro.

Quick start (flakes enabled, x86_64-linux only):

```bash
# 1. put your ableton_live*.zip (any edition, from ableton.com) in ~/Proprietary
# 2. build the runtime and create the prefix; ABLETON_LIVE_AUTOINSTALL=1 opts in
#    to running that zip's installer (silent — Ableton's EULA then appears on
#    Live's first launch; leave it unset to install Live yourself)
ABLETON_LIVE_AUTOINSTALL=1 nix run github:shibco/ableton-linux#setup-prefix
# 3. launch
nix run github:shibco/ableton-linux
```

The first build compiles Wine from source (no binary cache) and takes a while; after that everything comes from your Nix store. The prefix step is per user and idempotent — rerunning it later heals the prefix without touching Live. The Live 12 support files (corefonts, vcrun2022, mfc42) install from the winetricks cache vendored in the package, so `setup-prefix` needs no network for them; the Live 11 recipe still downloads its extras (see [Live 11](#live-11)). Host requirements: a running PipeWire daemon and `/dev/ntsync` (kernel 6.14+ with the `ntsync` module; `scripts/check-ntsync.sh` verifies).

For daily use prefer `nix profile install github:shibco/ableton-linux` (or the NixOS config below) over bare `nix run`: `nix run` leaves no GC root, so a `nix-collect-garbage` deletes the compiled Wine and the next run rebuilds it.

Optional extras, mirroring the tarball flow: `nix run github:shibco/ableton-linux#setup-realtime` installs the host pro-audio profile (rtprio limits, swappiness, performance governor — after a re-login the launcher's realtime probe turns on), and `...#setup-link` prepares Ableton Link networking (multicast route, firewall, jack_link bridge). Both change host policy and use sudo. Live 11 works the same as the tarball flow: `ABLETON_LIVE_VERSION=11 nix run github:shibco/ableton-linux#setup-prefix` — see [Live 11](#live-11).

### NixOS configuration

```nix
# flake.nix
inputs.ableton-linux.url = "github:shibco/ableton-linux";
# No nixpkgs.follows on purpose: the flake pins the nixpkgs its Wine was built
# and tested against; following your system nixpkgs rebuilds Wine from source
# on every channel bump.
```

```nix
# configuration.nix
{ inputs, ... }: {
  environment.systemPackages = [
    inputs.ableton-linux.packages.x86_64-linux.default
    # or pin PipeASIO audio settings declaratively — the launcher exports each
    # pin as the driver's own PIPEASIO_* override, which beats config.ini/panel
    # edits without touching that file; unpinned keys keep following config.ini,
    # and PIPEASIO_* variables you set yourself still win per launch:
    # (inputs.ableton-linux.packages.x86_64-linux.default.override {
    #   pipeasioSettings = {
    #     buffer_size = 256;             # frames; match your PipeWire quantum
    #     inputs = 2; outputs = 2;       # hardware channel counts
    #     # output_device = "Scarlett 18i20"; sample_rate = 48000; ...
    #   };
    # })
    # Display scale needs no pin: the launcher auto-detects it, and
    # ABLETON_DPI_MODE overrides per launch — see below.
  ];
  services.pipewire.enable = true;
}
```

This puts `ableton-live` on every user's PATH. Each user still runs the one-time `nix run github:shibco/ableton-linux#setup-prefix` — the prefix is per-user state in `~/.wine-ableton`, not something a system rebuild can produce. Desktop menu entries ship rendered in `share/applications/`, so a profile install or `environment.systemPackages` puts Ableton Live in the menu automatically; bare `nix run` registers nothing.

Standalone Max 9 (installed into the same prefix with `msiexec`) launches with `max9` from the package. Its menu entries are not active by default — the store cannot see whether Max is installed; copy them from `share/ableton-wine/desktop/` into `~/.local/share/applications` if you use Max.

## Issues?

File an issue on GitHub. There are diagnostic scripts in ./beta/scripts that will help pin down the problem.

## First launch

A few more things to do after you launch for the first time:

1. Ableton's Settings → untick Auto-Scale Plugin Window (prevents a plugin-window resize loop).
2. Preferences → Audio → Driver Type ASIO → Device PipeASIO.

If you encounter any unexpected audio behaviour, open an issue or +1 an existing one and I'll fix as a priority!

## Live 11

Live 11 support is new and experimental. A Live 11 install differs in three ways:

1. Set `ABLETON_LIVE_VERSION=11` when you run the installer. Live 11 needs a different set of support files than Live 12, and this installs the right ones. They are downloaded during setup, so you need to be online:

   ```
   ABLETON_LIVE_VERSION=11 sh ~/Downloads/install-ableton-latest.run
   ```

2. After your first Live 11 launch, run the Max for Live fixup once. Max 8 crashes on its second start over a preferences file its first start wrote. The fixup moves that file aside (nothing is deleted) and Max regenerates it:

   ```
   sh ~/Downloads/install-ableton-latest.run --extract /tmp/ableton-kit
   bash /tmp/ableton-kit/scripts/setup-prefix.sh --post-first-run
   ```

   On Nix: `nix run github:shibco/ableton-linux#setup-prefix -- --post-first-run`

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

Ableton Link syncs tempo, beat and phase between apps and devices on your local network (UDP port 20808). Support is built in: the installer ships a small native helper, `ableton-linkd`, which joins the Link session on your machine and anchors it. The shared tempo survives Live restarts, and native Linux apps such as Bitwig, Ardour and SuperCollider can sync with Live. The anchor is passive: it never sets Live's tempo. Live joins the session as its own peer.

One-time setup (optional, safe to re-run, uses sudo for the network and firewall changes):

```
sudo ~/.local/share/ableton-wine/setup-link.sh
```

(from a checkout of this repository: `sudo ./scripts/setup-link.sh`). The script finds your network interface, and refuses VPNs because Link does not work over them. It adds the network route Link's traffic needs, with a hook so the route survives reboots. It opens UDP port 20808 in your firewall, and enables the `ableton-linkd.service` user unit so the anchor runs from login. The launcher also starts the anchor on every Live start.

Then enable Link in Live: Preferences → Link, Tempo & MIDI → "Show Link Toggle", and click the control-bar indicator so it shows Enabled. Your router must forward multicast, and Link never crosses VPNs.

To verify, with Link Enabled somewhere (Live, or any Link app on the network):

```
~/.local/share/ableton-wine/ableton-linkd --probe 10
```

It prints `peers: N` and `tempo: T.T`, and exits 0 when at least one peer is in the session. Details and triage: [notes/ABLETON-WINE-LINK.md](notes/ABLETON-WINE-LINK.md).

Not working? Check these, in order:

- [ ] `ip route show 224.0.0.0/4` lists a route via the physical LAN interface, not a VPN device
- [ ] Firewall: `sudo ufw status | grep 20808` or `firewall-cmd --list-ports` shows `20808/udp`
- [ ] `pgrep -a ableton-linkd` shows the anchor running, and `~/.log/ableton-linkd/` records session activity
- [ ] `~/.local/share/ableton-wine/ableton-linkd --probe 10` prints `peers: 1` or more and exits 0
- [ ] Live's Control-Bar Link indicator shows Enabled and reports a peer count ≥ 1
- [ ] A tempo change on any peer propagates to all others

## Lower latency (optional)

From a checkout of this repository, run:

```
./scripts/setup-realtime.sh
```

It applies the standard Linux pro-audio settings: permission for Live to use realtime scheduling, less eager memory swapping, and a service that keeps the CPU at full speed. It uses sudo and prints every file it writes. Deeper tweaks (kernel options) are only suggested, never applied.

Log out and back in, then check that `ulimit -r` prints 95. The launcher checks for realtime permission on every start and from now on runs Live with it.

Some distributions grant realtime permission out of the box (CachyOS is one), so Live may already run with realtime scheduling before you run the script. `ulimit -r` printing 10 or higher means the launcher uses it. Launch with `ABLETON_RT=off ableton-live` to run without realtime scheduling, for a comparison run or on a machine with few CPU cores.

## Project structure

- [patches/](patches/): the Wine patch series + the pipeasio series
- [scripts/](scripts/): install, prefix setup, launcher
- [flake.nix](flake.nix) + [nix/](nix/): the Nix packaging (see "Nix and NixOS")
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

### Nix build

`nix build` produces the same runtime as the container pipeline, from the same vendored sources and patch series, with build-time gates: the patch series must match `patches/SERIES.sha256`, ntsync must be compiled into wineserver and ntdll, and PipeASIO must register end to end in a throwaway prefix.

```bash
nix build .#wine-d2d1-nspa   # just the patched Wine
nix build .#pipeasio         # just the ASIO driver
nix build                    # full runtime: Wine + PipeASIO + launcher -> result/
```

### Single-file installer

`./scripts/make-installer.sh` compiles everything into `dist/ableton-wine-setup-<version>.run`.

It verifies itself, installs the runtime, detects the display scale, creates the prefix, then runs the Ableton installer it finds next to itself (pauses so you can add one; prints the manual commands otherwise).

#### Display scale

`setup-prefix.sh` and the launcher auto-detect the display scale (GNOME, KDE, sway, Hyprland, niri, X11 `Xft.dpi`); the launcher recalibrates the prefix DPI on every start. Scales from 100% to 250% are calibrated: on GNOME the prefix tracks mutter's upscaled framebuffer (`LogPixels = 96 × ceil(scale)` plus a per-monitor DPI flag), on other desktops plain `LogPixels = round(96 × scale)`. Unfortunately, switching monitors still needs a Live restart if those monitors have different DPIs. You can manually override the default scaling behaviours with `ABLETON_DPI_MODE`.

### Other environment variables

Mostly unnecessary. But in case you need them:

- `ABLETON_WINE_ROOT` runtime path (default `~/.local/opt/wine-d2d1-nspa-11.11`)
- `ABLETON_WINEPREFIX` prefix path (default `~/.wine-ableton`)
- `ABLETON_LIVE_VERSION` `11` | `12`: the Live version the prefix setup prepares for and the launcher picks (see [Live 11](#live-11))
- `ABLETON_LIVE_EXE` full path to a Live exe inside the prefix; picks one exact install when several editions coexist (the launcher refuses to guess)
- `ABLETON_DPI_MODE` `auto` | `preserve` | `100` | `fractional` | `dpi<N>` (force `LogPixels` N with no per-monitor flag, e.g. `dpi144` for 150% on a non-GNOME desktop)
- `ABLETON_THEME_MODE` `auto` | `dark` | `light` | `preserve`: the launcher syncs Live's light/dark theme key to the desktop scheme on every start; this overrides it
- `ABLETON_TOPBAR_MODE` `live` | `system` | `preserve` | `'#RRGGBB #RRGGBB'`: the launcher colours Live's menu bar and menus like your Ableton theme (`live`, the default) or like your desktop titlebar (`system`: KDE colour scheme, or the stock GNOME header colours). `preserve` keeps the plain scheme colours, a hex pair forces bar and text colours
- `ABLETON_UI_FONT` `auto` | `preserve` | `off` | a font family name: the launcher renders Live's menu bar and dialogs with the Ableton Sans typeface shipped inside your Live install. `off` restores Tahoma, a family name uses that instead
- `ABLETON_DCOMP` `on` (default) | `off`: disables DirectComposition for that launch; an A/B check if the Learn View misrenders
- `ABLETON_RT` `on` (default) | `off`: runs Live without realtime scheduling even when the system permits it (see [Lower latency](#lower-latency-optional))
- `PIPEASIO_*` audio driver overrides, e.g. `PIPEASIO_PREFERRED_BUFFERSIZE=512` if you hear crackles; defaults live in `~/.config/pipeasio/config.ini`
- `ABLETON_INSTALLER_DIR` where `setup-prefix.sh` looks for your `ableton_live*.zip` (default `~/Proprietary`)
- `ABLETON_LIVE_AUTOINSTALL` set to `1` to let `setup-prefix.sh` run the Ableton installer it finds (opt-in; by default it only prints the manual install steps)
- `ABLETON_INSTALLER_UI` set to `1` for the Ableton installer window instead of the default silent install
- `ENGINE=docker` for `build.sh` / `make-installer.sh`

### Steam Deck

Desktop Mode only. The installer bundles everything it needs, so no extra SteamOS packages are required and updates survive SteamOS upgrades.

## More

You can learn all about the patches here: [patches/BASE.txt](patches/BASE.txt).

Questions? [cade@parare.al](mailto:cade@parare.al)

### AI Disclosure

Local models (Qwen 3.6) and Claude Opus were used during QA testing, documentation checking, and to help setup the build pipeline at the very end of this project's release.
