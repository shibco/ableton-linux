# Releasing from CI

A release becomes: bump VERSION, write the changelog, push a tag. Everything
after that is the pipeline the nightly already proved — build, audit, assemble,
publish, verify — with different labels.

The nightly is not a rehearsal for this. It **is** this, minus the tag and the
prerelease flag. Every step has run in CI, repeatedly, and produced an
installer that installed over a licensed prefix and launched Live.

## Today

Six steps, four of them manual and ordered:

```text
./build.sh                       40 minutes, on the maintainer's machine
./scripts/make-installer.sh      assembles the .run
git commit VERSION dist/BUILD-INFO-<ver>.txt
./scripts/release.sh             verify, tag, wait for draft, upload, publish
```

`release.yml` then drafts and, after publishing, verifies: every asset present,
every checksum good, `install-ableton-latest.run` byte-identical to the
versioned installer, and the published BUILD-INFO byte-identical to the
committed one.

What makes it fragile is the ordering, not the steps. The BUILD-INFO must be
committed *before* the tag or the draft job rejects it; the artifacts must
exist *before* `release.sh` runs; VERSION and CHANGELOG must agree. None of
that is checked until something has already been pushed.

## Shape

Tag-triggered, with two sources for the runtime and the choice recorded.

**Rebuild.** CI builds from the tagged tree. Same job as the nightly: ccache,
buildx, `build.sh`, `build-audit.sh`, `make-installer.sh`. Forty minutes,
reproducible from the tag alone.

**Promote.** CI takes the runtime tarball from a nightly that has soaked and
re-wraps it with the release version. `make-installer.sh` already does exactly
this — its header says *repackaging only; Wine is not rebuilt* — so promotion
costs minutes, and the Wine tree that ships is byte-for-byte the one testers
ran. Its sha256 is published on the nightly release, so that claim is checkable
rather than asserted.

Both keep `build-audit.sh` and the verify job. What differs is where the bits
came from, never how thoroughly they were checked.

Promotion carries an ordering constraint that is easy to miss. A runtime's
BUILD-INFO records the `dist-version` of the tree it was built from, and
promotion does not rewrite it — rewriting would end the byte-identity that is
the whole reason to promote. So promoting a nightly built *before* the VERSION
bump ships a release whose runtime reports the previous version. The workflow
that avoids it: bump VERSION first, let a nightly build at the new version,
soak that, then tag and promote it. Promotion follows the bump; it does not
precede it.

Promotion also needs `make-installer.sh:20` fixed first. It resolves its
tarball as `dist/<NAME>-<VERSION>.tar.zst` and falls back to
`ls | sort -V | tail -1` — the same selection defect fixed in `install.sh`, and
the reason it cannot currently be pointed at a specific artifact at all. A
release assembled from whatever `sort -V` put last is not a release.

## Requirements

**A `release` job in `release.yml`, triggered on `v*`.** Structurally the
nightly's build job: the same steps in the same order, with `ABLETON_DIST_LABEL`
unset so `make-installer.sh` names everything for the plain version.

**A source input.** `workflow_dispatch` with a nightly tag or commit promotes
that build; a plain tag push rebuilds. Promotion is the deliberate act and
should read like one.

**Provenance in the release body.** BUILD-INFO already records
`source-commit`, so a promoted release names the commit its runtime came from
without anything being rewritten. The body states which path produced it —
without that, the question Q3 exists to settle becomes unanswerable after the
fact, which is worse than having picked either option.

**The verify job unchanged.** It re-downloads every published asset and checks
it. It is the only step that inspects what users will actually receive, and it
gets stricter rather than weaker when CI is what produced them.

## What changes

`scripts/release.sh` loses almost everything. Verifying local artifacts,
uploading assets and publishing all move into CI. What remains is bump, commit,
tag, push — small enough to be documented rather than scripted.

`release.yml`'s draft job stops demanding a committed
`dist/BUILD-INFO-<ver>.txt`. That requirement exists only because the artifact
was built elsewhere; when CI builds it, the file does not exist until the job
runs.

`tests/release.bats` follows. *"VERSION has a committed BUILD-INFO, as
release.yml's draft job demands"* encodes the current procedure and would fail
by design. *"the BUILD-INFO for this VERSION names the patch count"* has the
same dependency. Both want re-pointing at what CI produces rather than at what
is committed.

The verify job's `cmp "BUILD-INFO-$ver.txt" "../dist/BUILD-INFO-$ver.txt"`
compares published against committed, and there is no committed copy any more.
It becomes a check that the published BUILD-INFO matches the artifact actually
shipped.

`scripts/build-audit.sh`, `make-installer.sh` and `setup-run-header.sh` are
untouched. The installer is byte-identical to what the maintainer's machine
would have produced.

## Decisions

**Rebuild by default; promotion is an explicit act.** The default should be the
one that always works, and rebuild is reproducible from the tag alone with no
dependency on a nightly existing at the right commit. Promotion stays available
for the case it is good at — shipping bits that have already soaked — and reads
as a deliberate choice rather than something that can happen by drift.

**BUILD-INFO stops being committed.** `.gitignore` currently carries an
explicit exception for it:

```text
/dist/*
!/dist/BUILD-INFO*.txt
```

That exception goes, and with it the ordering trap where a tag is rejected
because a file was not committed before it was pushed. The record does not
disappear — it moves to the release asset, which is where it is actually
consumed and where the verify job already checks it.

What is genuinely lost is durability: a release asset can be deleted, git
history cannot. The fifteen files already tracked stay as the record of
releases made under the old procedure; the practice simply stops. Anyone
needing a past BUILD-INFO after that reads the release.

`make-installer.sh:67` is unaffected. It copies `dist/BUILD-INFO-<VERSION>.txt`
into the kit, and in CI that is the file the build just produced — it was never
reading a committed copy, only a file that happened to also be committed.

**"CI never builds a release" is replaced, not abandoned.** The guarantee it
encoded — that shipped bits were verified — moves to `build-audit.sh`, which
checks every patch is present in the shipped binaries by fingerprint. That is a
stronger check than a human build receives, it already gates every nightly, and
unlike the old invariant it is mechanical rather than a matter of trust in
whoever ran the build. Both files stating the old rule need updating to say so.

## Limits

Nothing here is implemented. The nightly pipeline is the evidence that each
step works, but it has never run with a tag, a non-prerelease, or the verify
job attached.

The promote path has never been exercised at all, and it has two known
prerequisites rather than none: the tarball selection fix, and the ordering
above. `make-installer.sh` accepting a tarball it did not build is asserted
from reading its header, not observed.
