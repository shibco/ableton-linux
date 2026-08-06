# Build and configure Ableton Live on Linux

This document covers source builds and configuration overrides for developers
and advanced users.

## Requirements

The build requires:

- Podman
- about 10 GB of free disk space
- `zstd`
- `cabextract`
- `binutils`

## Build and install from source

Run:

```bash
./build.sh
./scripts/install.sh
./scripts/setup-prefix.sh
WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" \
  "/path/to/Ableton Live 12 Suite Installer.exe"
ableton-live
```

`build.sh` creates the patched Wine runtime and `dist/ableton-linkd`.
`install.sh` installs both under your home directory.

Configure Ableton Link networking with:

```bash
./scripts/setup-link.sh
```

This requests `sudo` for the multicast route and firewall allowance.

## Build the single-file installer

Run:

```bash
./scripts/make-installer.sh
```

The result is `dist/ableton-wine-setup-<version>.run`. The installer includes
the runtime, launchers, Ableton Link support, setup scripts, and corresponding
source required by bundled licences.

Verify pinned source inputs with:

```bash
make verify
```

## Nix build

The flake builds the same runtime as the Podman pipeline, from the same
vendored sources and patch series, and applies the same build-time gates: the
patch series must match `patches/SERIES.sha256`, ntsync must be compiled into
wineserver and ntdll, ALSA must be built, and PipeASIO must register end to end
in a throwaway prefix.

```bash
nix build .#wine-d2d1-nspa   # the patched Wine only
nix build .#pipeasio         # the ASIO driver only
nix build .#ableton-linkd    # the Ableton Link peer only
nix build                    # the full runtime -> result/
```

The flake also exposes the setup steps as apps: `.#setup-prefix`,
`.#setup-realtime` and `.#setup-link`. See the Nix section of the README for
installation instructions.

## Environment variables

- `ABLETON_WINE_ROOT` selects the Wine runtime. The default is
  `~/.local/opt/wine-d2d1-nspa-11.13`.
- `ABLETON_WINEPREFIX` selects the Wine prefix. The default is
  `~/.wine-ableton`.
- `ABLETON_LIVE_VERSION=11|12` selects a Live major version.
- `ABLETON_LIVE_EXE` selects one exact Live executable.
- `ABLETON_INSTALLER_DIR` selects where `setup-prefix.sh` looks for your
  Ableton Live installation ZIP. The default is `~/Proprietary`.
- `ABLETON_LIVE_AUTOINSTALL=1` lets `setup-prefix.sh` run the Ableton installer
  it finds. Without it the script only prints the manual install steps.
- `ABLETON_INSTALLER_UI=1` shows the Ableton installer window instead of
  running it silently. Only Live 12 has a silent mode here — Live 11 ships a
  WiX Burn bundle and always opens its window.
- `ABLETON_LINKD` selects the `ableton-linkd` binary the launcher and
  `setup-link.sh` use.
- `ABLETON_DPI_MODE=auto|preserve|100|fractional|dpi<N>|fractional<N>`
  overrides display-scale detection.
- `ABLETON_THEME_MODE=auto|dark|light|preserve` controls desktop theme sync.
- `ABLETON_TOPBAR_MODE=live|system|preserve|'#RRGGBB #RRGGBB'` controls menu
  colors.
- `ABLETON_UI_FONT=auto|preserve|off|<family>` controls the Wine UI font.
- `ABLETON_DCOMP=off` disables DirectComposition for one launch.
- `WINE_X11_FORCE_OFFSCREEN_CLASS=off` disables the default Max for Live
  selection-flicker fix for one launch.
- `WINE_WIN32_FULLSCREEN_CLASS=off` disables the default Live fullscreen
  layout and exit-state fix for one launch.
- `WINE_WIN32_RESIZABLE_CLASS=off` disables the monitor-sized Live window
  resizability fix for one launch without disabling fullscreen normalization.
- `ABLETON_RT=off` disables realtime scheduling for one launch.
- `PIPEASIO_*` variables override PipeASIO settings for one launch.
- `ENGINE` selects the container engine used by build scripts. The default is
  `podman`.

## Repository layout

- [`patches`](patches/): Wine and PipeASIO patches
- [`scripts`](scripts/): build, install, setup, and launch scripts
- [`vendor`](vendor/): pinned build inputs
- [`notes`](notes/): implementation records and investigations
- [`tools`](tools/): diagnostic and build tools
- [`bin`](bin/): installed launchers
- [`dist`](dist/): build output
- [`beta`](beta/): beta test kit
- [`flake.nix`](flake.nix) and [`nix`](nix/): Nix flake packaging

The patch list and provenance are in [`patches/BASE.txt`](patches/BASE.txt).
