# Tester kit

`run-session` collects a system report, installs the test build, runs the
automated probes, and writes one session file. Start with the
[quick start](../README.md). The [test plan](../TESTING.md) lists the manual
checks.

Use a physical x86-64 Linux machine. The kit does not support virtual machines.

## Default flow

From the root of this repository:

```bash
./beta/tester-kit/run-session
```

1. Prepares an empty Wine prefix at `~/works/plugs/studio`. A non-empty prefix
   requires `--reuse-prefix`.
2. Collects the redacted Linux system report.
3. Downloads the installer from `config/installer-url` and verifies its
   SHA-256 before running it. `--allow-unverified-installer` bypasses this
   requirement.
4. Verifies every shipped probe against `probes/SHA256SUMS` and
   `probes/advanced/SHA256SUMS`; a mismatch stops the session as a damaged
   kit.
5. Initialises the prefix with the installed Wine (`wineboot`) and runs
   the test set below.
6. Writes `session-YYYY-MM-DD-HHMMSS.txt` to the current directory or the
   directory set by `--output-dir`.

Each check records `PASS`, `FAIL`, `WARN`, `REVIEW`, `SKIP`, or `INFO`. A
session with any `FAIL` exits with a nonzero status. Review the report, then
file one issue per failure and attach the unchanged session file.

## Options

| Option | Effect |
| --- | --- |
| `--output-dir DIR` | Directory for the final session text file |
| `--prefix DIR` | Test prefix; default `~/works/plugs/studio` |
| `--reuse-prefix` | Permit a non-empty existing prefix |
| `--installer-url URL` | Override the URL in `config/installer-url` |
| `--installer-sha256 SHA256` | Expected installer hash |
| `--allow-unverified-installer` | Run a downloaded installer without a checksum |
| `--skip-installer` | Do not download or run the installer |
| `--wine PATH` | Prefer this Wine binary over discovered runtimes |
| `--live-probes` | Add Live window probes and three manual checks |
| `--live-only` | Run only host readiness and Live checks |
| `--advanced-input-trace` | Add an explicitly confirmed global Wine input trace |
| `--non-interactive` | Suppress prompts; manual results become `SKIP` or `REVIEW` |
| `--quick` | Use 5,000 rather than 30,000 stress iterations |
| `--keep-work` | Keep the private temporary evidence directory |
| `--list` | List the test set without changing anything |

The kit checks known paths under `~/works` and
`~/.config/ableton-wine/runtime-path` after any path supplied with `--wine`.

## Test set

| ID | Check |
| --- | --- |
| W00 | Runtime startup and fresh-prefix initialisation |
| H01 | WirePlumber session-manager readiness |
| H02 | PipeWire-Pulse graph readiness |
| T01 | Shared-session allocator stress |
| T02 | Pop-up menu creation |
| T03 | Live-style menu/resize convergence |
| T03M | Raw DPI and non-client metrics |
| T04 | OpenGL child context and sRGB pixel format |
| T05 | Plug-in title bars and layered shadows, visual |
| T06 | XDG portal file dialogue, visual |
| T07 | Virtual MIDI controller replug |
| C01 | DPI, file-dialogue and audio-driver policy snapshot |
| C02 | Nested audio endpoint FriendlyName guard |
| L01-L05, L10-L12 | Optional passive and manual Live-session probes |
| A01 | Optional global Wine mouse and JUCE input trace |

L01-L05 inspect Live's open windows without clicking or typing. L10-L12 ask
for manual observations. A01 hooks Wine input and requires you to type
`TRACE`. See [Advanced test tools](probes/advanced/README.md).

## Layout

- `run-session`: session entry point.
- `config/installer-url`: default installer URL.
- `lib/`: collector, installer fetcher, verifier, and probe runner sourced
  by `run-session`.
- `probes/src` and `probes/windows`: PE probes and their sources.
- `probes/advanced`: investigation tools that can change Live, input, or audio
  routing.

## Privacy

The collector removes unique hardware identifiers. It redacts account paths,
MAC addresses, credential lines, and captured window titles. The
[profiler privacy guide](../scripts/README.md) defines the full scope. If
excluded data appears, keep the report local and report the collector failure.
Do not share that report, even after removing the data.

## Rebuilding the probes (maintainers)

The maintainer script rebuilds six PE artifacts against a Wine build tree:

```bash
WORKS_RUNTIME_SOURCE=/path/to/wine-d2d1-nspa-src \
  ./beta/tester-kit/probes/build-maintainer-probes.sh
```

The source tree must contain `build-wow64`, or `ABLETON_WINE_BUILD` must point
to that build directory. The command also requires Clang and LLD. The script
currently rebuilds `resizeprobe.exe`,
`pluginwindowprobe.exe`, `portalprobe.exe`, `ntsyncprobe.exe`, `spyhost.exe`,
and `mousespy.dll`. It then regenerates both checksum files for the binaries
already present. Do not edit checksums by hand.

Build the Linux tools with:

```bash
./beta/tester-kit/probes/build-native-tools
```

This command needs a C compiler. Individual tools also need the development
libraries reported by the build script.
