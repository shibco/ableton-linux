# Project technologies inventory

This document helps a performance-moonshot planner see every technology the
ableton-linux stack is built from, where each is pinned or defined, and why it
matters for speed or stability. Scope: the repository at branch
`performance-moonshot`, VERSION `2026.08.01.1` (VERSION:1). One section per
technology area. Terms are defined at first use.

## Wine base

Wine is a compatibility layer that runs Windows programs on Linux by
implementing the Windows APIs. This project ships a patched Wine fork named
`wine-d2d1-nspa-11.13` (scripts/container-build.sh:11).

- Upstream source: `https://github.com/giang17/wine.git`, branch
  `d2d1-dcomp-11.13`, commit `5c23dd1c` (patches/BASE.txt:3-5;
  README.md:273-276). The branch tracks Wine 11.13; the project rebased from
  the `d2d1-dcomp-11.11` branch on 2026-07-21 (patches/BASE.txt:7-12).
- `d2d1-dcomp` means the fork carries Direct2D (2D graphics API) and
  DirectComposition (window compositing API) work beyond mainline Wine. Live
  12's UI relies on this stack (scripts/ableton-live:33-35).
- `nspa` comes from nine7nine's wine-nspa-src tree, source of patches 0002 and
  0003 (patches/BASE.txt:34-35).
- The source is not fetched at build time. It is vendored as
  `vendor/wine-base-5c23dd1c.tar.zst` and verified against
  `vendor/wine-base.sha256` before every build (build.sh:25;
  scripts/container-build.sh:21-23). Rebuilds cannot drift.

Why it matters: the base pins the DirectComposition renderer, the present
path, and windowing behaviour that Live's frame rate and UI stability depend
on. Patch 0055 alone moved the main window from a ~650 MB/s GDI copy path to
direct GL presents (patches/BASE.txt:167-178).

## Patch series and application mechanism

The series holds 62 Wine patch files, numbered 0001-0064 with 0027 and 0044
intentionally absent (patches/BASE.txt:14-15). A two-patch sub-series for
PipeASIO lives in `patches/pipeasio/` (patches/SERIES.sha256:63-64).

Application happens inside the build container
(scripts/container-build.sh:25-47):

1. Unpack the vendored base tarball (scripts/container-build.sh:23).
2. `git init`, commit the base, then `git am --3way` each `patches/00*.patch`
   in lexical order (scripts/container-build.sh:37-45; patches/BASE.txt:19-25).
3. Patch files without mail headers get a fixed identity and date first, so
   the apply is reproducible (scripts/container-build.sh:34-44).

Integrity controls:

- `patches/SERIES.sha256` freezes every patch file's hash;
  `scripts/build-audit.sh --freeze` regenerates it (scripts/build-audit.sh:11-23).
- The build stamps per-patch hashes into the shipped tree as
  `ABLETON-WINE-PATCH-STACK.txt` and writes per-artifact hashes to
  `BUILD-INFO` (scripts/container-build.sh:207-233).
- `scripts/build-audit.sh` diffs the shipped stamp against
  `patches/SERIES.sha256` and checks per-patch binary fingerprints in the
  built DLLs; it runs as the last build stage and again before installer
  packaging (scripts/container-build.sh:267-268; scripts/make-installer.sh:26-27).

Why it matters: any performance patch enters through this series, so its
audit trail is automatic. The `--3way` apply also means a base bump keeps
conflict resolution mechanical.

## Compiler toolchain and flags

The build uses a split toolchain, standard for Wine's WoW64 mode (running
64-bit and 32-bit Windows code without a 32-bit Linux userspace):

| Component | Toolchain | Where defined |
| --- | --- | --- |
| Unix side (`.so` halves, wineserver) | gcc from `build-essential` | Containerfile:38-39; scripts/container-build.sh:49 |
| PE side (Windows-format DLLs) | clang/lld 21, exact package version pinned | Containerfile:13-17, 40-42 |
| Diagnostic PE probes | clang `-target x86_64-windows-gnu -fuse-ld=lld`, no CRT, `-O2` | tools/build_midihot.sh:14-23 |
| ableton-linkd | g++ `-std=c++17 -O2`, static libstdc++/libgcc | tools/build_ableton-linkd.sh:33-38 |
| PipeASIO objects | gcc `-O2 -fPIC -fvisibility=hidden -fno-strict-aliasing` | scripts/container-build.sh:150-158 |

Key facts:

- The LLVM pin is an exact apt package version
  (`1:21.1.8~++20251221032842+...`, Containerfile:17). When apt.llvm.org ages
  it out, the install fails loudly rather than drifting (Containerfile:14-16).
- ccache covers both gcc and clang through a shim directory; cache cap 5 GB
  (Containerfile:71-92). CI reuses it across runs
  (.github/workflows/ci-pr-build.yml:14-16).
- Wine itself is configured with
  `CPPFLAGS="-I/opt/ntsync-uapi" ... --enable-archs=i386,x86_64 --disable-tests`
  (scripts/container-build.sh:53-56). The repo passes no `CFLAGS` and no
  optimization-level override for Wine; the build uses Wine's own defaults.
- Shipped binaries are stripped: `llvm-strip --strip-all` for PE files,
  `strip --strip-unneeded` for Unix objects (scripts/container-build.sh:178-186).

Why it matters: the pinned clang/lld pair decides PE codegen quality, and the
absence of project-set `CFLAGS` is the current ceiling on any
optimization-flag moonshot (see "Gaps and unknowns").

## Container build flow

Builds run in Podman (`ENGINE` overridable, build.sh:12) inside an Ubuntu
22.04 image pinned by digest (Containerfile:10). All apt traffic after
bootstrap resolves against one Ubuntu snapshot, `20260718T000000Z`
(Containerfile:19, 31-34).

`./build.sh` runs four stages (build.sh:24-47):

1. Verify vendored inputs against pinned checksums (build.sh:25).
2. Build the container image (build.sh:28).
3. Run `scripts/container-build.sh` in the container with the repo mounted
   read-only and `dist/` writable (build.sh:34-41). This script unpacks the
   base, applies patches, configures and builds Wine (WoW64), builds PipeASIO
   against the fresh Wine, strips and prunes, and packs a relocatable tarball
   compressed with `zstd -19 --long=27` (scripts/container-build.sh:237).
4. Build `ableton-linkd` in the same image (build.sh:44;
   scripts/build-ableton-linkd.sh:48-52).

Two gates run before packaging finishes:

- Relocation and registration gate: the packaged tree runs from a random path
  and PipeASIO registers through Live's load path, with a stub PipeWire
  library to satisfy the loader (scripts/container-build.sh:240-265).
- Build audit against the frozen series (scripts/container-build.sh:267-268).

`scripts/make-installer.sh` then assembles the single-file `.run` installer:
a self-extracting header plus a tar payload carrying the runtime tarball,
scripts, desktop files, winetricks payloads, static cabextract, ableton-linkd,
and licence texts (scripts/make-installer.sh:1-4, 61-119). Releases never
rebuild Wine in CI; `scripts/release.sh` uploads the locally built artifacts
and a verify job re-downloads and checks them
(.github/workflows/release.yml:1-8).

Build-time component gates that affect runtime capability: the build fails if
`winealsa.so` (ALSA MIDI), `winegstreamer.so` (mp3/mp4/wma import), the Push 2
USB bridge, or ntsync support is missing (scripts/container-build.sh:63-123).
GStreamer codecs come from the host at runtime (Containerfile:59-62;
README.md:41).

Why it matters: the flow is fully pinned and audited, so a moonshot change
gets a clean before/after artifact pair for free. The ccache mounts
(build.sh:31, 37) keep iteration fast.

## Vendored inputs

All external inputs are pinned in `vendor/` and checked by `make verify`
(Makefile:21-22) and build.sh:25.

| Input | Version | Pin file | Used for |
| --- | --- | --- | --- |
| Wine base tarball | giang17 `5c23dd1c` (Wine 11.13 line) | vendor/wine-base.sha256 | the runtime |
| PipeASIO | 1.2.2 | vendor/pipeasio.sha256 | ASIO audio driver |
| PipeWire SDK (3 Ubuntu debs) | 1.6.2-1ubuntu1.1 | vendor/pipewire-sdk.sha256 | PipeASIO link-time headers/libs |
| ntsync UAPI header | kernel 6.14 API | vendor/ntsync-uapi.sha256 | kernel-sync build gate |
| Ableton Link SDK | 4.0 | vendor/link.sha256 | ableton-linkd |
| cabextract | 1.11 | vendor/cabextract.sha256 | static tool in installer |
| Bitstream Vera fonts | upstream 1.10, byte-identical | vendor/bitstream-vera.sha256 | Max for Live font fallback |
| winetricks | 20260125 | vendored script, vendor/winetricks:9 | prefix setup |

The winetricks cache (`vendor/winetricks-cache/`) holds corefonts, vcrun2022,
and vcrun6 payloads for offline prefix setup (listing under
vendor/winetricks-cache/). Live 12 gets `corefonts vcrun2022 mfc42`; Live 11
gets `corefonts vcrun2019 gdiplus` (scripts/setup-prefix.sh:279-285).

## Audio stack: PipeASIO on PipeWire

PipeWire is the Linux audio and video server. ASIO (Audio Stream Input/Output)
is Steinberg's low-latency Windows driver API; Live uses it for pro audio.
PipeASIO is an ASIO driver implemented as a Wine DLL that forwards to the
host's PipeWire.

- Version 1.2.2, vendored (vendor/pipeasio-1.2.2.tar.gz). Two local patches:
  keep the graph sample rate instead of failing with `ASE_NoClock`, and
  report `timeGetTime` in ASIO systemTime (patches/SERIES.sha256:63-64).
- Built against the just-built Wine's headers (ABI-matched) and the vendored
  PipeWire 1.6.2 SDK, with `winebuild`/`winegcc` producing the PE/Unix pair
  (scripts/container-build.sh:131-176).
- The SDK is link-time only. The shipped `pipeasio64.dll.so` records
  `DT_NEEDED libpipewire-0.3.so.0` and resolves against the user's PipeWire at
  runtime; the enforced floor is 0.3.56, the first release with the
  thread-utils API (Containerfile:100-105; scripts/container-build.sh:144-147,
  165-170). An rpath into the build container fails the build
  (scripts/container-build.sh:167-170).
- Host requirement: PipeWire 0.3.56 or newer, 1.6+ recommended for audio
  performance (README.md:40).
- Per-launch `PIPEASIO_*` overrides exist (BUILDING.md:77).
- ALSA MIDI rides Wine's `winealsa.drv`, which the build treats as mandatory
  (Containerfile:53-58; scripts/container-build.sh:89-94). Patch 0028
  re-subscribes MIDI devices after reconnect (patches/BASE.txt:41-42).

Why it matters: this is the latency-critical path. PipeASIO's data-loop
thread requests `SCHED_FIFO` priority 15 (see next section), and the
sample-rate patch removes a whole crash class on rate mismatch
(scripts/check-live-audio.sh:49-52).

## Realtime scheduling and host tuning

Realtime (RT) scheduling lets audio threads preempt normal processes.

- Launcher: if `chrt -r 10 true` succeeds, Live starts as `chrt -r 10 wine`
  (SCHED_RR priority 10) (scripts/ableton-live:780-782). `ABLETON_RT=off`
  disables this for one launch (BUILDING.md:76).
- PipeASIO separately requests SCHED_FIFO 15 for its data-loop thread;
  `ABLETON_RT=off` does not affect it
  (notes/ABLETON-WINE-RT-SCHEDULING.md:4-8). The effect on low-core systems is
  unmeasured (notes/ABLETON-WINE-RT-SCHEDULING.md:5-6).
- `scripts/setup-realtime.sh` installs the host profile: PAM limits rtprio 95,
  memlock unlimited, nice -19 for the RT group (scripts/setup-realtime.sh:72-77);
  `vm.swappiness = 10` (scripts/setup-realtime.sh:80-83); a systemd unit
  forcing the `performance` CPU governor (scripts/setup-realtime.sh:106-122).
- The script advises, but never applies, the `threadirqs` kernel parameter and
  a lowlatency/PREEMPT_RT kernel (scripts/setup-realtime.sh:124-151). A
  wineserver `chrt -f 95` boost is deliberately left out and kept as a manual
  A/B experiment (scripts/setup-realtime.sh:22-25).

Why it matters: scheduling is the cheapest latency lever, and the repo
already has the probe-and-grant structure a moonshot can extend.

## ntsync

ntsync is a Linux kernel driver (merged in kernel 6.14) that implements
Windows NT synchronization primitives in the kernel. Without it, every NT
sync wait becomes a round trip to wineserver, Wine's userspace coordinator
process.

- The build needs `linux/ntsync.h`, which Ubuntu 22.04's 5.15 headers lack, so
  the header is vendored and sha256-pinned (Containerfile:94-98).
- The build hard-fails if `HAVE_LINUX_NTSYNC_H` is unset or if either
  wineserver or `ntdll.so` lacks ntsync references; the comment records the
  cost of shipping without it as ~1.3 cores of wineserver traffic with Live
  running (scripts/container-build.sh:104-123). Two 2026-07 builds shipped
  this regression unnoticed (scripts/container-build.sh:104-107;
  notes/ABLETON-WINE-NTSYNC-REGRESSION.md).
- Runtime verification: `scripts/check-ntsync.sh` runs `ntsyncprobe.exe`
  against a scratch prefix, checks sync semantics, and confirms wineserver
  holds an open `/dev/ntsync` fd when the device exists
  (scripts/check-ntsync.sh:1-6, 52-76).

Why it matters: ntsync is the single biggest sync-overhead reducer in the
stack, and the repo has both the gates and the probe to A/B it.

## Ableton Link

Ableton Link is a LAN protocol that synchronizes tempo and beat position
between music applications. Discovery rides multicast group 224.76.78.75, UDP
port 20808 (tools/ableton-linkd.cpp:3; scripts/setup-link.sh:26-28).

- `ableton-linkd` is a small native C++17 daemon built from the vendored
  Ableton Link 4.0 SDK (GPLv2+, corresponding source ships in the installer;
  scripts/make-installer.sh:93-102; https://github.com/Ableton/link). It is
  the longest-lived session peer: it holds tempo and timeline across Live
  restarts and relays Start Stop Sync without owning a transport
  (tools/ableton-linkd.cpp:1-16). It is strictly passive after construction
  (tools/ableton-linkd.cpp:13-15).
- Modes: foreground anchor, `--daemon`, and `--probe` for a scriptable
  peers/tempo verdict (tools/ableton-linkd.cpp:21-28).
- It runs as a systemd user unit with restart-on-failure
  (scripts/ableton-linkd.service), or the launcher starts it when systemd is
  unavailable (scripts/setup-link.sh:95-96).
- Setup opens UDP 20808 in ufw or firewalld when one is active; no multicast
  route is needed because the Link SDK binds discovery sockets with
  `IP_MULTICAST_IF` (scripts/setup-link.sh:6-12, 25-44).
- `tools/jacklinkd.c` exists as a JACK-transport-related utility; the daemon
  header notes native apps join the session directly and upstream jack_link
  remains an option (tools/ableton-linkd.cpp:17-19).

Why it matters: the anchor removes session-reestablishment stalls when Live
restarts, and the native peer sidesteps running the Link stack under Wine.

## Desktop and OS integration

XDG portals are D-Bus services that let sandboxed or foreign toolkits use
native host dialogs. Desktop files and MIME entries register apps and file
types with the Linux desktop.

- File dialogs: patch 0031 adds an XDG file-dialog portal backend to comdlg32
  (patches/BASE.txt:48-51). `bin/set-file-portal-policy` sets the
  `FileDialogPortal` registry policy (bin/set-file-portal-policy:20-23).
  `bin/ableton-live-portal` and `bin/ableton-wine-portal` launch a separate
  `-portal` runtime variant with `WINE_FORCE_PORTAL=1` as an option
  (bin/ableton-live-portal:4, 29-31).
- File-manager integration: patches 0043, 0063, and 0064 route Live's "Show in
  Explorer" requests through `org.freedesktop.FileManager1` and the OpenURI
  portal (patches/BASE.txt:91-94, 229-240).
- Desktop entries and MIME types for Live sets/clips/packs, the `ableton://`
  URL scheme, and `.auz` authorization files are defined under `desktop/`
  (desktop/ableton-live.desktop.in:9-10; desktop/x-wine-extension-auz.xml:3-6).
  The launcher repairs handler entries a foreign prefix hijacked
  (scripts/ableton-live:52-73).
- Push 2 display: patch 0032 adds a host libusb-1.0 bridge exporting the
  16-function Win64 ABI `Push2DisplayProcess.exe` needs; the build verifies
  every export ordinal (patches/BASE.txt:52-55;
  scripts/container-build.sh:63-87).
- WebView2 (Chromium embed for Live's Learn View): the launcher forces the
  SwiftShader software-rendering path and `--no-sandbox`
  (scripts/ableton-live:39-42). Software rendering here is a correctness fix,
  not a performance choice.
- Display scale: `scripts/detect-scale.sh` probes GNOME, KDE, sway, Hyprland,
  COSMIC, and Xft.dpi, and the launcher recalibrates prefix DPI each launch
  (scripts/detect-scale.sh:1-5; scripts/ableton-live:199-204).
- Theme: `scripts/detect-theme.sh` reads the XDG settings portal and GNOME
  gsettings; a watcher thread re-syncs Win32 colors live
  (scripts/detect-theme.sh:1-6; scripts/ableton-live:437-441).
- Fonts: vendored Bitstream Vera terminates Max for Live's font fallback
  chain; without it an M4L device can hang Live (scripts/make-installer.sh:78-89;
  scripts/check-m4l-fonts.sh:1-13).

Why it matters: portal dialogs and native file-manager calls remove slow or
fragile Wine fallbacks; the USB bridge and DPI calibration are stability
work, and the launcher knob set below is performance work.

## Launcher runtime knobs

`scripts/ableton-live` exports a fixed environment per launch. The
performance-relevant subset:

| Variable | Default | Effect | Where |
| --- | --- | --- | --- |
| `WINEDEBUG` | `-all` | Disables Wine debug logging; fixme spam stalls Live's UI thread | scripts/ableton-live:16-17 |
| `WINE_D3D_CONFIG` | `csmt=0x1` | Enables wined3d's command-stream thread | scripts/ableton-live:18 |
| `WINED3D_DCOMP_FORCE_FULL_REDRAW` | `1` | Full-redraw mode for the DComp stack | scripts/ableton-live:19 |
| `WINE_X11_FORCE_OFFSCREEN_CLASS` | `Ableton Live Window Class` | Keeps Live on winex11's offscreen path (M4L flicker fix) | scripts/ableton-live:20-23 |
| `WINE_DISABLE_UNIX_MOUNT_REPARSE` | `1` | Mount points appear as plain dirs | scripts/ableton-live:24-26 |
| `WINE_CPU_TOPOLOGY` | capped at 8 | Groundwork only: no consumer in this runtime yet | scripts/ableton-live:75-108 |
| `WINEDLLOVERRIDES` | `mscoree,mshtml=` | Keeps Mono/.NET and HTML-help hooks out of Live | scripts/ableton-live:29-32 |

Patch 0055 adds `WINE_DISABLE_GL_PRESENT=1` as an escape hatch back to the
GDI present path (patches/BASE.txt:176-177).

## Benchmarking and diagnostics

An xrun is an audio buffer under- or overrun, heard as a click or dropout.
DSP load is Live's own audio-engine utilization meter.

- `scripts/bench-run.sh` appends one CSV row per measurement under fixed
  reference conditions (committed reference set, 48 kHz / 256 frames, fixed
  window geometry). Two metrics are automated: `wined3d_cs` thread %CPU from
  60 s of `top` samples, and the wineserver context-switch delta over 60 s.
  Two are operator-entered: xruns per 5 minutes from `pw-top`'s ERR delta,
  and Live's DSP load reading. The unit of evidence is a before/after pair
  committed with the change (scripts/bench-run.sh:1-17, 52-103). No
  `bench/` results directory exists in the repo.
- Checks: `scripts/check-ntsync.sh` (sync semantics and ntsync activity),
  `scripts/check-live-audio.sh` (Live opens PipeASIO without a FatalError;
  scripts/check-live-audio.sh:1-3), `scripts/check-m4l-fonts.sh` (font
  fallback regression tests; scripts/check-m4l-fonts.sh:1-13),
  `scripts/build-audit.sh` (patch-stack provenance).
- Beta tester kit: `beta/tester-kit/run-session` collects a redacted system
  report, installs the build, and runs checksum-verified probes: shared-session
  allocator stress, menu/resize convergence, OpenGL child/sRGB, portal dialog,
  MIDI replug, DPI metrics, and optional live-Live window probes
  (beta/tester-kit/README.md:14-32, 59-81). Probe sources and PE binaries live
  under `beta/tester-kit/probes/`, rebuilt by maintainers against a Wine build
  tree with clang and LLD (beta/tester-kit/README.md:101-115).
- Cross-platform profilers for issue reports: Linux, macOS, and Windows
  scripts in `beta/scripts/` (beta/scripts/ listing;
  beta/scripts/ableton-linux-profiler.sh:1-3).
- `tools/` holds about 40 diagnostic utilities: PE probes built like Wine's
  own PE modules (swamprobe, liveinject, midihot, linkprobe, mousespy,
  setsyscolors, learnheal, webviewclose, metricprobe2; the nine with
  `build_*.sh` scripts), plus X11-side helpers (xmon, xdrag, xclose, ukey,
  uidrag) and one-off probes without build scripts. `tools/m4l-hang-capture.sh`
  and `tools/m4l-font-audit.py` target Max for Live stalls.

Why it matters: the bench harness defines the project's evidence standard
(every moonshot claim needs a committed before/after pair), but the
automated metrics cover only wined3d_cs CPU and wineserver context switches.

## Gaps and unknowns

- The exact diff between giang17's `d2d1-dcomp-11.13` branch and WineHQ's
  11.13 release is not determinable from this repo; only the vendored binary
  tarball is pinned, not a verifiable git reference.
- The repo sets no `CFLAGS` or optimization level for the Wine build itself
  (only `CPPFLAGS`, scripts/container-build.sh:53-56). What `-O` level and
  target flags Wine's configure picks for this tree is unverified here.
- No compiler-based hardening or LTO settings are visible anywhere in the
  build; whether clang LTO is feasible for the PE side is unexplored in the
  repo.
- `WINE_CPU_TOPOLOGY` is exported by the launcher but is inert: the patched
  ntdll/wineserver consumer has not landed (scripts/ableton-live:78-79). Its
  intended design is not documented in the repo.
- Whether this Wine tree supports esync/fsync is not stated anywhere; the
  wrappers only unset `WINEESYNC`/`WINEFSYNC` defensively
  (bin/ableton-wine-portal:15). ntsync is the documented sync path.
- The `-portal` runtime variant (`wine-d2d1-nspa-11.13-portal`,
  bin/ableton-live-portal:4) has no build recipe in this repo; how it differs
  from the main build beyond patch 0031 is undetermined.
- No committed benchmark data exists (`bench/results.csv` is created on first
  use; scripts/bench-run.sh:97-101). There is no performance baseline history
  in the repo, only per-release notes.
- The automated bench metrics omit PipeASIO-level latency (round-trip latency,
  callback period jitter). pw-top ERR deltas are operator-entered
  (scripts/bench-run.sh:34, 48-50).
- The RT effect on low-core-count systems is unmeasured
  (notes/ABLETON-WINE-RT-SCHEDULING.md:5-6), and the wineserver priority boost
  is an untested manual experiment by policy (scripts/setup-realtime.sh:22-25).
- Most `tools/*.c` utilities have no build script in the repo (only nine
  `build_*.sh` exist); their build commands are unrecorded.
- Which glibc floor the shipped binaries actually require is asserted as
  Ubuntu 22.04 / glibc 2.35 (scripts/container-build.sh:230; README.md:39)
  but not mechanically gated beyond the container base.
