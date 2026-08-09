# Findings: what the test suite is worth

Measured against the suite as it stood on 2026-07-31 (119 tests, 8 files).

## Question

The suite passes, but passing says nothing about worth. Two things were
unknown: whether it catches regressions rather than merely running, and
whether all of it belongs on a PR or only a cheap subset.

## Method

Fifteen realistic regressions were introduced into the shipped scripts one
at a time — a flipped dark/light branch, a widened scale range, a `.als`
routed back through `start.exe`, a cap raised from 8 to 16 — and the suite
run against each. Then eight behaviour-preserving edits the same way: a
brace moved to its own line, a helper renamed, a staging block indented.
Red under the first set is a catch; red under the second is a tax. Timing
and per-path commit counts supplied the missing term in value = chance it
breaks × cost if it ships.

## Result

Thirteen of fifteen mutations were caught, most by more than one test, so
coverage overlaps rather than resting on single assertions. The `# guards:`
provenance holds: the issue 38 test does catch a `.als` handed to
`start.exe`.

Ranked by churn against cost of late discovery, over the 17 days to
2026-07-31:

| Suite | Guards | Commits | If it ships broken |
| --- | --- | --- | --- |
| patch-stack | `patches/`, `build-audit.sh` | 90, 64 | 40-minute build, or a bad release |
| launcher-cli, unit/launcher | `ableton-live` | 51 | user-visible, issue 38 class |
| repo-hygiene | VERSION, CHANGELOG, vendor, desktop | ~90 | rejected tag, broken desktop entry |
| packaging | make-installer.sh, install.sh | 43 | installer missing a file it runs |
| release | VERSION, CHANGELOG | 45 | release job rejects the tag |
| unit/detect-scale, unit/detect-theme | the probe libraries | 8, 15 | mis-scaled UI, unreadable chrome |

`patch-stack` is the most valuable tier by a wide margin, guarding the two
most-edited paths against the most expensive failure mode there is. It is
also the slowest, 13.2s of a 22.6s run, so a trim by cost cuts exactly the
wrong thing. The 42 `detect-*` tests are 36% of the count guarding the two
least-changed scripts — well built, but insurance on the quietest code here.

Trimming the PR job is not worth doing: `actions/checkout` pulls 100MB of
`vendor/` and the tooling step installs seven apt packages whatever tests
follow. If it is ever split it must stay one job, or the 100MB is paid twice
to save seconds.

Two defects surfaced, both tests failing to fire rather than costing too
much. `packaging.bats` recovers the kit contents by sed anchored at
`^cp -a scripts/`; indenting that block by two spaces takes the parsed list
from 12 names to 3 and leaves the suite green, the loops iterating over less
and reporting success. `repo-hygiene` enumerates via `git ls-files`, so
untracked files are invisible to shellcheck, syntax and mode checks — a
byte-identical script is green untracked, caught (SC2115) once staged.

## Fix

`the launch lock is released once Live has been exec'd` was removed. It could
not fail: `run_launcher` runs the launcher as a subprocess, so the kernel
closes fd 9 on exit whatever the script did, and the test stayed green with
`exec 9>&-` deleted outright. A comment records why the obvious test is the
wrong one, and that a real one needs a fake wine forking a child that holds
its fds.

`the kit staging list is still parseable out of make-installer.sh` was added,
asserting the parser recovers at least 10 entries before any test consumes
it, turning the silent degradation into a red build naming the cause.

## Limits

The churn window is 17 days and will settle, though `patches/` being the
hottest path is structural, not an artefact of a young repo.

The untracked-file gap is left open: closing it means enumerating beyond the
index, trading a local blind spot for lint noise over scratch files.

Two mutations survive. The block map's `96*s + 0.5` rounding is untested —
every scale exercised is a clean multiple where truncation agrees, while the
xft probe's `d/96` yields values like 1.104 where the half-point decides the
LogPixels. A case pinning `1.1 -> 106` would close it.

Nothing verifies a patch has effect. Every patch-stack test checks that
patches apply and are registered, none that a line survives to the shipped
tree. Patch 0007 contributes nothing — 0008 deletes its clamp, 0009 restores
only the frame-extents half — yet `build-audit.sh` lists it as `logic-only
(monitor size clamp)`, reading as though it ships. The decision was
deliberate and `ABLETON-WINE-RESIZE-BUG.md` records it correctly; only the
audit disagrees. A revert-is-a-no-op check over the applied series would
catch the accidental case at a base bump.

These tests still never compile Wine, create a prefix or start Live. They
catch patches that no longer apply, not patches that no longer build.
