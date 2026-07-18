# Tester kit

`run-session` is the automated half of the beta test plan: it records the
system, installs the build under test and runs the regression probes,
then writes one session report. Start with the [quick start](../README.md);
the manual checks are in [TESTING.md](../TESTING.md).

Use a physical x64 Linux machine. VMs are not supported.

## Default flow

From the root of this repository:

```bash
./tester-kit/run-session
```

1. Prepares an empty Wine folder at `~/.wine-ableton` (a non-empty folder
   is refused unless `--reuse-prefix` is given).
2. Collects the redacted Linux system report.
3. Downloads the Para-Repos installer from `config/installer-url` and
   verifies its SHA-256 before running it. No unverified remote code runs
   unless the tester deliberately passes `--allow-unverified-installer`.
4. Verifies every shipped probe against `probes/SHA256SUMS` and
   `probes/advanced/SHA256SUMS`; a mismatch stops the session as a damaged
   kit.
5. Initialises the prefix with the installed Wine (`wineboot`) and runs
   the test set below.
6. Writes `session-YYYY-MM-DD-HHMMSS.txt` into the current directory (or
   `--output-dir`).

Every check appends a result row — `PASS`, `FAIL`, `WARN`, `REVIEW`,
`SKIP` or `INFO` — and the summary at the end of the report. A session
with any `FAIL` exits non-zero. File one issue per `FAIL` and attach the
unchanged session file; review the report before sharing it.

## Options

| Option | Effect |
| --- | --- |
| `--output-dir DIR` | Directory for the final session text file |
| `--prefix DIR` | Test prefix; default `~/.wine-ableton` |
| `--reuse-prefix` | Permit a non-empty existing prefix |
| `--installer-url URL` | Override the provisional Para-Repos URL |
| `--installer-sha256 SHA256` | Expected installer hash |
| `--allow-unverified-installer` | Run a downloaded installer without a checksum |
| `--skip-installer` | Do not download or run the installer |
| `--wine PATH` | Wine binary to test; required with `--skip-installer` |
| `--live-probes` | Add passive probes while Ableton Live is running |
| `--live-only` | Run only host readiness and passive Live probes |
| `--advanced-input-trace` | Add an explicitly confirmed global Wine input trace |
| `--non-interactive` | Skip tests that need visual confirmation |
| `--quick` | Use 5,000 rather than 30,000 stress iterations |
| `--keep-work` | Keep the private temporary evidence directory |
| `--list` | List the test set without changing anything |

With neither `--wine` nor an installer, the kit looks for an installed
patched Wine under `~/.local/opt` and in
`~/.config/ableton-wine/runtime-path`.

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
| L01–L12 | Optional passive and manual Live-session probes |
| A01 | Optional global Wine mouse and JUCE input trace |

The Live probes (L01–L05) inspect Live's open windows without clicking or
typing in it; L10–L12 are manual observations. A01 is the only test that
hooks input, needs the tester to type `TRACE`, and is documented with the
other investigation tools in [probes/advanced/README.md](probes/advanced/README.md).

## Layout

- `run-session` — the entry point above.
- `config/installer-url` — default installer location, one URL.
- `lib/` — the collector, installer fetch/verify and probe runner sourced
  by `run-session`.
- `probes/src` + `probes/windows` — the PE regression probes and their
  sources; `probes/advanced` holds the investigation tools that change
  Live, input or audio connections (never run by the normal session).

## Privacy

The collector omits unique hardware identifiers, account paths, MAC
addresses, credential-like values and captured window titles; the exact
scope is documented in [../scripts/README.md](../scripts/README.md). A
report containing excluded data is a collector failure: keep it local and
report the failure instead of cleaning and sharing it manually.

## Rebuilding the probes (maintainers)

The shipped PE probes are rebuilt against a Wine build tree:

```bash
ABLETON_WINE_SOURCE=/path/to/wine-d2d1-nspa-src \
  ./tester-kit/probes/build-maintainer-probes.sh
```

The tree must contain the `build-wow64` build directory (or point
`ABLETON_WINE_BUILD` at it). The script rebuilds every probe and
regenerates both `SHA256SUMS` files, so run it after changing any probe
source — never edit a checksum by hand. `./tester-kit/probes/build-native-tools`
builds the Linux-side advanced tools instead and needs only a C compiler.
