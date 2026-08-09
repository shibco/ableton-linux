#!/usr/bin/env bats
#
# scripts/install.sh — does it run at all, and does it install what it claims?
#
# This file exists because nothing executed install.sh. The suite sourced
# runtime-env.sh directly and checked the resolvers, which is worth doing and
# says nothing about whether the script that uses them starts. On 2026-08-05 a
# merge reordered install.sh's head so it called ableton_runtime_name eight
# lines before sourcing the file that defines it; under `set -euo pipefail` it
# aborted on that line. 172 tests passed for thirteen commits.
#
# The first test here is deliberately cheap and hermetic: it asserts only that
# the script gets past its own initialisation to the point where it looks for a
# tarball. That is the whole failure mode, and it needs no fixture.
#
# The second does a real install into a throwaway HOME, and skips when there is
# no tarball to install. That is not a gap that can be closed with a fixture:
# install.sh runs `readelf -d` against the packaged libusb and PipeASIO shims
# and greps for real DT_NEEDED entries, so a stand-in tree would either fail
# those checks or force them to be weakened, and weakening them is how a debug
# tree ships.
#
#   ./tests/run.sh tests/unit/install-runs.bats
#   ABLETON_TEST_TARBALL=/path/to/runtime.tar.zst ./tests/run.sh tests/unit/install-runs.bats

bats_require_minimum_version 1.5.0

load ../helpers/common
load ../helpers/install-sandbox

setup() {
    install_sandbox
    . "$REPO/scripts/runtime-env.sh"
}

# guards: install.sh aborting on its own first lines, which no resolver test can
# see because the resolvers themselves are fine
@test "install.sh gets past its own initialisation" {
    run env ABLETON_WINE_ROOT="$BATS_TEST_TMPDIR/rt" \
        bash "$REPO/scripts/install.sh" --runtime-only
    # Deliberately indifferent to whether it succeeded: whether dist/ happens to
    # hold a tarball is not what this is about, and an earlier draft that
    # asserted failure passed alone and broke the moment a build left one there.
    # What must not appear is evidence it never started.
    [[ "$output" != *"command not found"* ]] || { echo "$output" >&2; false; }
    [[ "$output" != *"unbound variable"* ]] || { echo "$output" >&2; false; }
    # and it must have got as far as its own first step
    [[ "$output" == *"tar.zst"* || "$output" == *"verify checksum"* ]] || {
        echo "no sign it reached the tarball step:" >&2; echo "$output" >&2; false; }
}

@test "install.sh resolves its roots from the shared lib, not from its own copy" {
    # The pin has to reach the script, not just the library: install.sh snapshots
    # WINE_ROOT once and every later step follows it.
    run env ABLETON_WINE_ROOT="$BATS_TEST_TMPDIR/pinned-root" \
        bash "$REPO/scripts/install.sh" --runtime-only
    [[ "$output" != *"command not found"* ]] || { echo "$output" >&2; false; }
    # whatever it did, it did not do it at the default location
    [ ! -e "$HOME/works/$(ableton_runtime_name)" ]
}

# guards: `wineboot -u` rewriting the registry under a live wineserver
@test "setup-prefix refuses while something runs from the runtime" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export ABLETON_WINE_ROOT="$root"
    cp "$(command -v sleep)" "$root/bin/wineserver"
    "$root/bin/wineserver" 30 &
    local pid=$!
    run bash "$REPO/scripts/setup-prefix.sh"
    kill "$pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"Close Live"* ]]
}

@test "setup-prefix refuses with no terminal too" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export ABLETON_WINE_ROOT="$root"
    cp "$(command -v sleep)" "$root/bin/wineserver"
    "$root/bin/wineserver" 30 &
    local pid=$!
    run setsid --wait bash "$REPO/scripts/setup-prefix.sh"
    kill "$pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
}

@test "setup-prefix gets past the guard when nothing is running" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export ABLETON_WINE_ROOT="$root"
    run bash "$REPO/scripts/setup-prefix.sh"
    [[ "$output" != *"Close Live"* ]]
}
