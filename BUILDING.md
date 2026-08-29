# Build Ableton Live on Linux

This page covers the current source build, tests, packaging, and maintainer options.

## Build

Install Podman, Git, Bash, Python 3, GNU Coreutils, GNU Findutils, GNU grep, GNU tar, binutils, `zstd`, and `cabextract`. `make check` also needs a host C compiler and maths library. Allow about 10 GB of free disk space.
Then run:

```bash
./build.sh
```

Set `ENGINE` to another compatible container command if needed. Set `JOBS` to limit parallel work:

```bash
env JOBS=8 ./build.sh
```

The build verifies the vendored Wine, PipeASIO, PipeWire SDK, ntsync, and Ableton Link inputs. It then creates the container image, builds Wine and PipeASIO, runs the compiled test suites and patch audit, and writes the runtime and build records to `dist/`.

ThreadSanitizer runs by default. Where it cannot start at all, the default permits only a recognised startup limitation and records a non-release build; races, test failures and unrecognised errors still fail the build. To require a successful ThreadSanitizer result instead, so that a startup limitation is an error:

```bash
env PIPEASIO_TSAN_MODE=require ./build.sh
```

Continuous integration sets `require`. Official packages need the successful result either way: packing, tagging and publishing all refuse a build record that does not carry it.

## Install a source build

Install `cabextract`, then run the installer dispatcher after a successful build:

```bash
./scripts/installer.sh install \
  --live-installer "/path/to/Ableton Live 12 Suite Installer.zip" \
  --live-major 12 \
  --link=session
```

The dispatcher validates the new files before changing the current installation. If an operation fails before it commits, it restores the files and configuration recorded at the start.

Use one component directly when a full install is not needed:

```bash
./scripts/installer.sh runtime install
./scripts/installer.sh prefix create --live-major 12
./scripts/installer.sh prefix update --live-major 12
./scripts/installer.sh prefix repair-live11
./scripts/installer.sh link enable --mode=session
./scripts/installer.sh link disable
./scripts/installer.sh link status
```

Preview an update while preserving current files:

```bash
./scripts/installer.sh plan update
```

Validate the paths and records for an uninstall request:

```bash
./scripts/installer.sh plan uninstall --delete-prefix
```

Run `./scripts/installer.sh --help` for the complete current command list.

## Test

Run the repository policy, launcher, installer, and PipeASIO checks:

```bash
make check
make test
```

`make check` inspects the pointer changes and tests their limits with difficult input. Neither it nor `make verify` starts Wine or Live.

`scripts/test-installer-ui.sh` covers the installer's screen. It renders a fixed run and compares the result byte for byte with a golden transcript of the template. It replays a real pseudo-terminal through a small terminal simulator to check the `└─` to `├─` rewrite. It checks every adjoining box stroke for matching direction and weight. It also confirms that colour codes apply to text while each line keeps the terminal's default colour. The remaining checks confirm that every tree glyph comes from `scripts/lib/ui.sh` and every sentence comes from the dictionary.

Verify all pinned build and packaging inputs:

```bash
make verify
```

The container build also runs PipeASIO's non-integration CTest suite, a no-Qt build, ASan and UBSan tests, ThreadSanitizer unit tests, relocation and registration checks, and the final runtime audit. These checks do not replace a run with Live and real audio hardware.

## Nix build

The flake builds the runtime from the same vendored sources and the same patch series as the Podman pipeline, and runs the same gates on the result: both patch series must match `patches/SERIES.sha256`, ntsync must be compiled into wineserver and ntdll, ALSA and GStreamer must be built, the Bitstream Vera faces must be present, and PipeASIO must register in a throwaway prefix.

```bash
nix build .#wine-d2d1-nspa   # the patched Wine only
nix build .#pipeasio         # the ASIO driver only
nix build .#ableton-linkd    # the Ableton Link peer only
nix build                    # the full runtime -> result/
```

The final `build-audit.sh` runs under `ABLETON_AUDIT_PROFILE=nix`. That profile reports six provenance records as skipped — the PipeASIO sanitizer runs, the no-Qt gate, the PipeWire probe test gate, the `cabextract-static` and `ableton-linkd` installer helper hashes, and the git source-tree digest — because the container pipeline produces them and the Nix build does not run it. The builder package manifest is not among them: the Nix build writes its own from the pinned closure, so that record is checked and passes. Every structural, patch, fingerprint and binary-hash check is unchanged, and the default `release` profile still fails on all six.

The setup steps are also flake apps: `.#setup-prefix`, `.#setup-realtime` and `.#setup-link`. `.#wine` runs a Windows executable against the Ableton prefix on this runtime, `.#check-ntsync` runs `scripts/check-ntsync.sh` with its Wine root already set to the store path, and `.#audio-report` prints the read-only audio diagnostic an issue report is expected to carry.

## Configure Ableton Link

Configure Ableton Link networking and choose when it runs:

```bash
./scripts/installer.sh link enable --mode=session
```

This requests `sudo` only when an active firewall needs the UDP 20808 allowance, or when a hook from an earlier setup version needs removing.

## Package

After a successful `./build.sh`, create the single-file installer:

```bash
./scripts/make-installer.sh
```

This writes `dist/ableton-wine-setup-<version>.run` and its SHA-256 file. Packaging refuses a build that lacks the required sanitizer result or fails the runtime audit.

To try a script change with the Wine runtime you already built, pack a development installer from the current contents of `dist/`:

```bash
./scripts/make-installer.sh --dev
```

This command writes `dist/ableton-wine-setup-<version>-dev.run` and skips the BUILD-INFO, digest, and attestation checks. Publish only the release `.run`.

The packer builds the `.run` header from `scripts/setup-run-header.sh` and inserts `scripts/lib/ui.sh` at the `@UI_LIB@` marker, so the banner and the action menu render before the installer unpacks the kit. `./scripts/make-installer.sh --render-header --version V --payload-sha S` prints that assembled header. The test suites use it to build stub installers.

## Current configuration

The installer saves the runtime root, Wine prefix, selected Live major version, and Link mode. For these values, a command-line option overrides an exported `ABLETON_*` variable, which overrides the saved XDG configuration and then the default.

- `ABLETON_WINE_ROOT` selects the Wine runtime. The default is `~/.local/opt/wine-d2d1-nspa-11.13`; the Nix package's launchers and shipped scripts default to their own store path instead.
- `ABLETON_WINEPREFIX` selects the Wine prefix. The default is `~/.wine-ableton`.
- `ABLETON_LIVE_VERSION=11|12` selects a Live major version for the launcher.
- `ABLETON_LINK_MODE=off|session|always` controls when Ableton Link runs.

`setup-prefix.sh` reads these when it prepares the prefix; they change nothing about a launch, and the `.run` installer ignores all three, installing Live from its own payload instead:

- `ABLETON_INSTALLER_DIR` selects where step [6/6] looks for your Ableton Live installation ZIP. The default is `~/Proprietary`.
- `ABLETON_LIVE_AUTOINSTALL=1` lets step [6/6] run the installer it found. Unset, the step reports what it found and prints the manual install steps instead.
- `ABLETON_INSTALLER_UI=1` shows the Ableton installer window instead of running it silently. A silent run defers Ableton's licence agreement to Live's first launch.

These environment variables change one launch without changing the saved installer configuration:

- `ABLETON_LIVE_EXE` selects one exact Live executable.
- `ABLETON_LINK_MODE=off|session|always` selects the Link policy shared by the
  installer, Live launcher, Max launcher, and service.
- `ABLETON_LINKD` selects the Link daemon path. The generated user unit uses
  this exact resolved path.
- `ABLETON_MAX_AUDIO_THREADS=auto|off|<number>` controls Live 12's audio thread
  setting. The default, `auto`, compares the available physical core count with
  half of Live's calculated count. It uses the higher value, up to Live's count.
  `off` removes the launcher's saved value and restores Live's calculated count.
  Existing settings and user edits take priority. Fewer threads reduce worker
  wake-ups, while demanding Sets can benefit from a higher count. The launcher
  accepts an explicit value from one to 63. It uses the value when it is below
  Live's calculated count. At or above that count, Live uses its calculated
  count.
- `ABLETON_SHORTCUTS=take|preserve` controls the GNOME shortcut hold. The
  default, `take`, temporarily turns off the exact Ctrl+Alt+Up and
  Ctrl+Alt+Down entries. Live 11 also turns off Ctrl+Alt+Delete. `preserve`
  leaves the desktop shortcuts unchanged.
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
- `WINE_D3D_FORCE_GPU_RENDERING=1` reports a device ID Live accepts for one
  launch, offering the GPU renderer on Intel models Live refuses; the device
  name Live shows discloses the substitution.
- `WINE_X11_SMOOTH_SCROLLING=disabled|precise|notched` controls smooth
  scrolling for one launch. `precise` is the default. `notched` keeps
  whole wheel steps. `disabled` leaves normal mouse-wheel input available.
- `WINE_X11_PINCH_ZOOM=disabled|legacy-wheel` controls touchpad pinch zoom for
  one launch. Pinch zoom is on by default.
- `WINE_X11_MIDDLE_DRAG=disabled|navigate|navigate-notched` controls
  middle-button drag navigation for one launch. Navigation is on by default.
- `WINE_X11_TOUCHPAD_INERTIA=disabled|auto|enabled` controls continued movement
  after a quick smooth scroll. It defaults to `enabled`. `auto` currently
  behaves like `disabled` on X11. Turning inertia off leaves direct scrolling
  unchanged.
- `WINE_X11_MIDDLE_DRAG_THROW=disabled|enabled` controls whether movement
  continues after the user releases a middle-button drag. It defaults to
  `enabled`. `disabled` leaves direct middle-button navigation unchanged.
- `WINE_X11_WHEEL_WHILE_BUTTON_HELD=disabled|enabled` controls physical
  mouse-wheel clicks while another button is held. It defaults to `enabled`.
  The wheel stays blocked during middle-button navigation. Touchpad scrolling,
  pinch and continued movement stay blocked during a drag.
- `WINE_X11_INERTIA_CURVE=exponential|linear` selects how continued movement
  slows. `WINE_X11_INERTIA_RATE=<0.5..16.0>` selects how soon it stops. The
  default rate is `4.0`. Lower values keep movement going for longer. Higher
  values stop it sooner.
- `WINE_X11_WARP_EMULATION=disabled|auto|enabled` controls the XWayland repair
  for faders and knobs that move farther than the pointer. It defaults to
  `auto`, which applies the repair only after Wine observes failed warps; a
  button release is repaired only when the drag's own motion was. `enabled`
  forces the repair for one launch.
- `WINE_X11_POINTER_FEATURES=disabled` turns every pointer feature off for one
  launch regardless of any other setting, restoring stock pointer behaviour
  for baseline comparisons.

Named pointer values ignore letter case. `off` and `0` mean `disabled` where
supported. Wine reports an invalid value in the normal launch log, then uses
the next saved choice or default.

The settings, defaults, limits, and hands-on checks are in
[the pointer input guide](notes/ABLETON-WINE-POINTER-GESTURES.md).

- `ABLETON_RT=off` disables realtime scheduling for one launch.
- `ABLETON_POWER=off` keeps the computer's power mode unchanged for one
  launch.
- `ABLETON_LINKD_LINGER` sets how many seconds `ableton-linkd` waits with no
  Link peers before it exits. Whole seconds only. The default is 900; 0
  keeps it running.
- `PIPEASIO_*` variables override PipeASIO settings for one launch.
- `ENGINE` selects the container engine used by build scripts. The default is
  `podman`.

The build-only `ENGINE` variable selects the container command. Its default is `podman`.

PipeASIO stores its settings in `${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini`. The installer creates a 256-frame, two-input, two-output configuration only when that file does not exist. The driver accepts buffer sizes from 32 to 8192 frames.

The optional `scripts/setup-realtime.sh` asks for `sudo`, adds the current user to the real-time audio group, writes the project audio limits and swappiness settings under `/etc`, and enables `rtirq` when it is installed. Run it only when you want those system changes, then log out and back in.

## Repository layout

- [`patches`](patches/): ordered Wine and PipeASIO patches, checksums, and provenance
- [`scripts`](scripts/): build, install, launch, test, and release scripts
- [`vendor`](vendor/): pinned source inputs
- [`tools`](tools/): diagnostic and build tools
- [`desktop`](desktop/): application and file-type integration
- [`dist`](dist/): generated build output
- [`flake.nix`](flake.nix) and [`nix`](nix/): Nix flake packaging

The authoritative patch list and provenance are in [patches/BASE.txt](patches/BASE.txt).
