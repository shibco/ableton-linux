# Releasing

Nothing is built or pushed from a maintainer's machine. CI builds, a person verifies, publishing promotes.

## The short version

```
gh workflow run release-build.yml -f mode=build             # full build of main
gh workflow run release-build.yml -f mode=promote-nightly   # bless the soaked nightly
```

Either ends at a **draft** release for `v<VERSION>` with the installer, the runtime tarball, checksums and the stable manifest attached. Nothing users can reach changes until the draft is published.

## Before the button

A release is decided by a normal PR that sets `VERSION` and renames the CHANGELOG's `## Unreleased` section to it. The workflow refuses a VERSION/CHANGELOG mismatch, an existing tag, or an existing release, so re-running it is always safe.

## Which mode

`build` runs the same container path the nightly does, pinned to the committed VERSION. Forty minutes cold, a few with warm caches.

`promote-nightly` ships the bits that already soaked: it downloads what the nightly channel published, verifies it against the nightly's own manifest and checksums, refuses a commit that is not on main, restamps the identity (`dist-version` becomes the release; `source-commit` and `built-at` survive, which is what ties the release to the build that soaked; `promoted-from` records the nightly it was), re-audits every patch fingerprint in the binaries, and repacks the kit around the nightly's own ableton-linkd. Minutes. Pass `-f expected_commit=<sha>` to refuse anything but the nightly you meant.

Both modes install the kit they just packed on the runner, runtime-only, and refuse to publish a kit that does not install and run.

## The draft is the verification

CI cannot launch Ableton Live, so the one check that matters stays human: download the draft's `install-ableton-latest.run`, install it, start Live. Then

```
gh release edit v<VERSION> --draft=false
```

Publishing flips `/releases/latest`, makes the manifest live for `works-update`, and runs `release.yml`'s verify job over every asset. A draft that fails the human check is deleted, not published; the tag can be reused after `git push --delete origin v<VERSION>`.

## The plumbing, for when it misbehaves

The workflow commits `dist/BUILD-INFO-<VERSION>.txt` and pushes the `v<VERSION>` tag itself, then creates the draft directly - a tag pushed with the workflow token starts no workflows, so `release.yml`'s draft job does not fire for it. That job still serves the local fallback: `./build.sh && ./scripts/make-installer.sh && GH_TOKEN=… ./scripts/release.sh`, unchanged, for a release cut without CI.

A dispatch-only workflow is invisible to `gh workflow run` until the file exists on the default branch; after first merge this is never an issue again.
