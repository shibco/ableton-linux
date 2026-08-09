# Tests

```sh
./tests/run.sh                      # everything (~20s, no build, no prefix, no display)
./tests/run.sh unit                 # just the shell unit tests
./tests/run.sh tests/patch-stack.bats
```

[bats-core](https://github.com/bats-core/bats-core) is the harness. `run.sh` uses `bats` from `PATH`, or `$BATS`, or clones a pinned copy into `.bats-core/` at the repo root on first use — deliberately not under `tests/`, where bats-core's own fixtures (some with intentionally duplicate test names) would be swept up by the recursive run over `tests/unit`.

[CATALOGUE.md](CATALOGUE.md) lists every individual test, what it covers, and the issue, commit or source site it came from — generated from the test files by `./tests/catalogue.sh`, with a cross-reference index at the end.

## What is here

| File | Covers | Why it exists |
| --- | --- | --- |
| `patch-stack.bats` | The Wine patch series and the PipeASIO patches: applies them all to the vendored base, checks the freeze manifest, audit registration, and numbering | A rotted patch is otherwise caught only by the ~40-minute container build, and only on PRs touching the paths `ci-pr-build.yml` filters on |
| `repo-hygiene.bats` | shellcheck, shell syntax, file modes, version/name drift, vendored checksums, desktop entries and MIME XML | The 11.11 → 11.13 rename needed a follow-up commit to finish; `release.yml` rejects a tag whose `BUILD-INFO` is missing, which is late to find out |
| `packaging.bats` | Kit completeness: everything the staged installer's own scripts reach for is staged with them | Scripts resolve every path in a checkout and only some of them in the kit; four issues carry the `installer` label |
| `launcher-cli.bats` | `scripts/ableton-live` end to end: which Live starts, ambiguity refusal, document routing, the single-instance lock, `chrt` | The half users experience. Issue #38 (a `.als` handed to `start.exe` is read as a switch) lives here |
| `unit/detect-scale.bats` | Display-scale probes and the scale → DPI block map | The block map is a calibration contract; a wrong cell mis-scales Live's entire UI |
| `unit/detect-theme.bats` | Light/dark probes, titlebar colours, `.ask` parsing, prefs-dir resolution | These values are written straight into the win32 registry; wrong ones ship unreadable chrome |
| `unit/launcher.bats` | The launcher's pure functions: GrayText blend, LOGFONT packing, CPU topology, `WindowMetrics` reading | None of these crash when wrong — they just render Live slightly off on someone else's machine |

## Conventions

**The launcher is run, not sourced.** `scripts/ableton-live` does discovery, locking and registry sync at top level and ends in `exec wine`. `helpers/launcher.bash` runs the whole thing against a throwaway `$HOME` and prefix with `ABLETON_WINE_ROOT` pointed at a fake runtime whose `wine` logs its argv and exits — so a test asserts on the command line the launcher *would* have run. Its pure functions are extracted by name and evaluated separately, since a full launch says nothing about colour arithmetic.

**Probes are tested against fixtures, not against the machine.** `tests/fixtures/` holds recorded `cosmic-randr`, `kscreen-doctor` and `gdbus` output. `helpers/common.bash` puts a stub first on `PATH`, so results do not depend on which compositor the developer or the runner happens to be using. Adding a compositor means adding a fixture, not finding a machine.

**Tests name the bug they guard.** Where a test exists because something broke once, the comment says which commit or issue. `newest prefs dir: the sort -V trap case` asserts the shape of the original bug directly, so the reason survives even if the comment does not.

**A gate that is red on a healthy tree is worthless.** Everything here passes on `main`. Checks that produced false positives on a healthy repo were dropped rather than allowlisted.

**Provenance is annotated, not remembered.** A test that exists because something broke carries a `# guards:` line above it, in `<reference> — <what it protects>` form:

```bash
# guards: issue #38 — start.exe reads a bare unix path as a switch
@test "a .als set goes straight to the Live exe, never through start.exe" {
```

`catalogue.sh` reads those into the *Guards* column and the cross-reference index. Cite only what the repo substantiates — a commit, an issue named in the source, or a documented in-source trap. After adding or renaming a test, run `./tests/catalogue.sh`; `repo-hygiene.bats` fails when the catalogue is stale.

## Adding a patch to the series

`patch-stack.bats` will fail until the patch is fully registered — by design, it is the checklist:

1. `./scripts/build-audit.sh --freeze` and commit `patches/SERIES.sha256`
2. Add a `FINGERPRINTS` line in `scripts/build-audit.sh` (a string literal the patch introduces) or a `STAMP_ONLY` line saying why it has none
3. If the patch takes a new number after a gap, add a `SERIES_GAPS` entry explaining the gap

## What this does not cover

These tests never compile Wine, create a prefix, or start Live. They catch patches that no longer *apply*, not patches that no longer *build* — `ci-pr-build.yml` remains the only thing that proves the tree compiles, and only a real prefix proves Live runs. The gap that stays open is runtime behaviour: DPI blocks, audio, MIDI hotplug and window management are still verified by hand against `beta/TESTING.md`.
