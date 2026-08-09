#!/usr/bin/env bats
#
# scripts/runtime-env.sh — the channel manifest.
#
# A channel publishes one document saying what it points at. Everything before
# this re-derived that by parsing artifact filenames, which is the single
# decision behind the selector defect, the packing defect and the update prompt
# having nothing to compare.
#
# The writer and the reader live in the same file on purpose, and these tests
# round-trip them: a manifest this repo writes must be one this repo accepts.
#
#   ./tests/run.sh tests/unit/manifest.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export WORKS_CHANNEL_FILE="$BATS_TEST_TMPDIR/chan"
    unset WORKS_CHANNEL WORKS_MANIFEST_URL
    . "$REPO/scripts/runtime-env.sh"
    TREE="$BATS_TEST_TMPDIR/BUILD-INFO.txt"
    printf 'dist-version: 2026.08.04.1\nsource-commit: 0e72afb07072f7fa\nbuilt-at:     2026-08-06T13:49:38Z\nwine:         wine-11.13\n' \
        > "$TREE"
    M="$BATS_TEST_TMPDIR/manifest.txt"
}

# --- round trip ---------------------------------------------------------------

@test "a manifest this repo writes is one it accepts" {
    works_manifest_write stable "$TREE" install-ableton-latest.run deadbeef > "$M"
    works_manifest_valid "$M"
}

# guards: found in review. works-update guards its Wine-base refusal on the field
# being non-empty, so a manifest published without `wine` switches that safety
# off rather than tripping it — and this function is the hard publish gate
# standing in front of users at make-installer.sh.
@test "a manifest with no wine field is refused" {
    works_manifest_write stable "$TREE" install-ableton-latest.run deadbeef > "$M"
    works_manifest_valid "$M"                     # the control: valid to begin with
    grep -v '^wine:' "$M" > "$M.x" && mv "$M.x" "$M"
    run works_manifest_valid "$M"
    [ "$status" -ne 0 ] || { echo "a manifest with no wine field passed the gate" >&2; false; }
}

# guards: works_manifest_write emits the key unconditionally but writes whatever
# BUILD-INFO holds, so "present" was never the same as "filled in"
@test "a manifest with an empty wine field is refused" {
    works_manifest_write stable "$TREE" install-ableton-latest.run deadbeef > "$M"
    sed 's/^wine:.*/wine:         /' "$M" > "$M.x" && mv "$M.x" "$M"
    run works_manifest_valid "$M"
    [ "$status" -ne 0 ]
}

@test "every field survives the round trip" {
    works_manifest_write stable "$TREE" install-ableton-latest.run deadbeef > "$M"
    [ "$(works_buildinfo_field "$M" channel)"       = "stable" ]
    [ "$(works_buildinfo_field "$M" dist-version)"  = "2026.08.04.1" ]
    [ "$(works_buildinfo_field "$M" installer)"     = "install-ableton-latest.run" ]
    [ "$(works_buildinfo_field "$M" sha256)"        = "deadbeef" ]
    [ "$(works_buildinfo_field "$M" built-at)"      = "2026-08-06T13:49:38Z" ]
    [ "$(works_buildinfo_field "$M" wine)"          = "wine-11.13" ]
}

# guards: the updater compares source-commit to decide "do I already have this"
@test "the source commit is carried, not truncated" {
    works_manifest_write stable "$TREE" x.run abc > "$M"
    [ "$(works_buildinfo_field "$M" source-commit)" = "0e72afb07072f7fa" ]
}

@test "writing refuses a tree with no BUILD-INFO" {
    run works_manifest_write stable "$BATS_TEST_TMPDIR/nothing.txt" x.run abc
    [ "$status" -ne 0 ]
}

# --- validation ---------------------------------------------------------------
# Refusing beats half-applying: a missing field means the updater cannot answer
# "is this newer" or "does this change the Wine base".

@test "a manifest missing built-at is refused" {
    works_manifest_write stable "$TREE" x.run abc | grep -v '^built-at' > "$M"
    run works_manifest_valid "$M"
    [ "$status" -ne 0 ]
}

@test "a manifest missing the checksum is refused" {
    works_manifest_write stable "$TREE" x.run abc | grep -v '^sha256' > "$M"
    run works_manifest_valid "$M"
    [ "$status" -ne 0 ]
}

@test "a missing manifest is refused, not treated as empty" {
    run works_manifest_valid "$BATS_TEST_TMPDIR/absent"
    [ "$status" -ne 0 ]
}

# guards: the installer name becomes both a URL component and a filename
@test "an installer name containing a path is refused" {
    printf 'channel: stable\ndist-version: 1\ninstaller: ../../etc/passwd\nsha256: a\nsource-commit: b\nbuilt-at: c\n' > "$M"
    run works_manifest_valid "$M"
    [ "$status" -ne 0 ]
}

@test "an installer name that is a URL is refused" {
    printf 'channel: stable\ndist-version: 1\ninstaller: https://evil.example/x.run\nsha256: a\nsource-commit: b\nbuilt-at: c\n' > "$M"
    run works_manifest_valid "$M"
    [ "$status" -ne 0 ]
}

# --- where a channel's manifest lives -----------------------------------------

@test "each channel has a manifest URL" {
    [ -n "$(works_manifest_url stable)" ]
    [ -n "$(works_manifest_url nightly)" ]
    [ "$(works_manifest_url stable)" != "$(works_manifest_url nightly)" ]
}

# guards: the channel is user configuration and must never choose a host
@test "an unknown channel resolves no URL at all" {
    run works_manifest_url ../../evil
    [ "$status" -ne 0 ]
}

@test "the manifest URL follows the configured channel" {
    printf 'nightly\n' > "$WORKS_CHANNEL_FILE"
    [ "$(works_manifest_url)" = "$(works_manifest_url nightly)" ]
}

@test "an override wins, for testing against a local file" {
    WORKS_MANIFEST_URL="file:///tmp/x/manifest.txt"
    export WORKS_MANIFEST_URL
    [ "$(works_manifest_url)" = "file:///tmp/x/manifest.txt" ]
}

# guards: moving a release must not strand the installer it names
@test "the installer URL is resolved beside the manifest" {
    [ "$(works_manifest_installer_url https://h/x/y/manifest.txt install.run)" \
      = "https://h/x/y/install.run" ]
}

# --- where the manifest's facts come from -------------------------------------
# guards: the updater compares the manifest's source-commit against
# $root/ABLETON-WINE-BUILD-INFO.txt, which comes out of the tarball. Writing the
# manifest from dist/BUILD-INFO-<version>.txt instead compares two documents and
# hopes they agree -- and for 2026.08.04.1 they demonstrably do not, because the
# committed one predates both fields.

@test "the runtime's BUILD-INFO is read straight out of a tarball" {
    local d="$BATS_TEST_TMPDIR/rt/wine-x"; mkdir -p "$d"
    printf 'dist-version: 1\nsource-commit: abc123\nbuilt-at:     t\nwine:         wine-11.13\n' \
        > "$d/ABLETON-WINE-BUILD-INFO.txt"
    tar -C "$BATS_TEST_TMPDIR/rt" -cf - wine-x | zstd -q -o "$BATS_TEST_TMPDIR/rt.tar.zst"

    run works_tarball_buildinfo "$BATS_TEST_TMPDIR/rt.tar.zst"
    [ "$status" -eq 0 ]
    [[ "$output" == *"source-commit: abc123"* ]]
}

@test "a tarball that is not there is an error, not an empty BUILD-INFO" {
    run works_tarball_buildinfo "$BATS_TEST_TMPDIR/absent.tar.zst"
    [ "$status" -ne 0 ]
}

# guards: this is the exact shape that made the first stable manifest invalid
@test "a BUILD-INFO with no source-commit produces a manifest that is refused" {
    printf 'dist-version: 2026.08.04.1\nwine:         wine-11.13\npatches:      65\n' > "$TREE"
    works_manifest_write stable "$TREE" x.run abc > "$M"
    run works_manifest_valid "$M"
    [ "$status" -ne 0 ]
}

# guards: a fork is where nightlies are tested, and the shipped default pointing
# there would send every user's daily channel to whoever happened to build it
@test "no channel resolves to a fork" {
    for c in stable nightly; do
        [[ "$(works_manifest_url $c)" == https://github.com/shibco/* ]] \
            || { echo "$c -> $(works_manifest_url $c)" >&2; false; }
    done
}

# guards: /releases/latest/ excludes prereleases, which is what keeps the nightly
# prerelease from becoming what a stable machine follows
@test "stable resolves through latest, nightly through its own tag" {
    [[ "$(works_manifest_url stable)"  == */releases/latest/download/* ]]
    [[ "$(works_manifest_url nightly)" == */releases/download/nightly/* ]]
}
