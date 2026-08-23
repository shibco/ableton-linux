# Tester kit reference

`run-session` prepares a test prefix, records a redacted Linux report, verifies
and runs a candidate installer, executes regression probes, and writes one
session report.

## Run the default checks

```bash
./beta/tester-kit/run-session
```

The default prefix is `~/.wine-ableton` and the report is written to the
current directory. The runner refuses a non-empty prefix unless you approve it
with `--reuse-prefix`.

The candidate URL comes from `config/installer-url`. The runner requires a
matching SHA-256 from `URL.sha256` or `--installer-sha256`. The
`--allow-unverified-installer` option is for deliberate local work only.

## Useful options

```text
--output-dir DIR             write the final report in DIR
--prefix DIR                 use a different test prefix
--reuse-prefix               permit a non-empty prefix
--installer-url URL          replace the configured candidate URL
--installer-sha256 SHA256    supply the expected candidate hash
--skip-installer             run probes without downloading the candidate
--wine PATH                  select a Wine binary explicitly
--live-probes                add passive and manual Live checks
--live-only                  check an existing Live installation
--advanced-input-trace       collect the confirmed global input trace
--non-interactive            turn manual results into SKIP or REVIEW
--quick                      reduce stress iterations from 30,000 to 5,000
--keep-work                  retain the private temporary evidence directory
--list                       list checks without changing anything
```

Run `./beta/tester-kit/run-session --help` for the complete usage text.

## Checks included

- `W00`: Wine startup and prefix initialisation
- `H01-H02`: WirePlumber and PipeWire-Pulse readiness
- `T01-T07D`: shared mappings, menus, resize, OpenGL, file dialogues, and MIDI hotplug
- `C01-C02`: prefix policy and endpoint registry checks
- `L01-L12`: optional Live observations and manual actions
- `A01`: optional Wine and JUCE input trace

The report distinguishes `PASS`, `FAIL`, `WARN`, `REVIEW`, `SKIP`, and `INFO`.
An automated failure makes the runner exit non-zero.

## Files

- `run-session`: session runner
- `config/installer-url`: default candidate URL
- `lib/`: collection, download, redaction, and probe helpers
- `probes/windows/`: prebuilt Wine probes
- `probes/src/`: native probe sources
- `probes/advanced/`: optional diagnostic tools
- `probes/SHA256SUMS`: distributed probe hashes

## Private data

Temporary evidence uses mode `0700` and is removed unless `--keep-work` is
set. The final report removes common identifiers, credentials, account paths,
and window titles. Review it before sharing. Do not edit a report to hide a
redaction failure; keep it local and report the collector defect.

## Rebuild distributed probes

Maintainers can rebuild native tools with:

```bash
./beta/tester-kit/probes/build-native-tools
```

Build Windows probes through the maintainer build environment, then refresh
the matching `SHA256SUMS`. Run `run-session --list` and the privacy checks
before distributing a changed kit.
