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

This requests `sudo` only when an active firewall needs the UDP 20808
allowance, or when a hook from an earlier setup version needs removing.

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

## Environment variables

- `ABLETON_WINE_ROOT` selects the Wine runtime. The default is
  `~/.local/opt/wine-d2d1-nspa-11.13`.
- `ABLETON_WINEPREFIX` selects the Wine prefix. The default is
  `~/.wine-ableton`.
- `ABLETON_LIVE_VERSION=11|12` selects a Live major version.
- `ABLETON_LIVE_EXE` selects one exact Live executable.
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
- `ABLETON_POWER=off` keeps the computer's power mode unchanged for one
  launch.
- `ABLETON_LINKD_LINGER` sets how many seconds `ableton-linkd` waits with no
  Link peers before it exits. Whole seconds only. The default is 900; 0
  keeps it running.
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

The patch list and provenance are in [`patches/BASE.txt`](patches/BASE.txt).
