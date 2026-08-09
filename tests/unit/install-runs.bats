#!/usr/bin/env bats
#
# scripts/install.sh — does it run at all, and does it install what it claims?
#
# This file exists because nothing executed install.sh. The suite sourced
# runtime-env.sh directly and checked the resolvers, which is worth doing and
# says nothing about whether the script that uses them starts. On 2026-08-05 a
# merge reordered install.sh's head so it called works_runtime_name eight
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
#   WORKS_TEST_TARBALL=/path/to/runtime.tar.zst ./tests/run.sh tests/unit/install-runs.bats

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
    run env WORKS_RUNTIME="$BATS_TEST_TMPDIR/rt" \
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
    run env WORKS_RUNTIME="$BATS_TEST_TMPDIR/pinned-root" \
        bash "$REPO/scripts/install.sh" --runtime-only
    [[ "$output" != *"command not found"* ]] || { echo "$output" >&2; false; }
    # whatever it did, it did not do it at the default location
    [ ! -e "$HOME/works/$(works_runtime_name)" ]
}

# guards: the whole install path — staging, the required-file gate, promote,
# the launcher, and the shared lib landing where the launcher can source it
@test "a real tarball installs, and the tree identifies itself" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WORKS_TEST_TARBALL to run this"

    root="$BATS_TEST_TMPDIR/rt"
    run env WORKS_RUNTIME="$root" WORKS_RUNTIME_TARBALL="$tarball" \
        bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    [ -x "$root/bin/wine" ]
    [ -n "$(works_runtime_id "$root")" ]
    # the launcher and the resolver it sources both land
    [ -x "$HOME/.local/bin/ableton-live" ]
    [ -f "$HOME/works/lib/runtime-env.sh" ]
    # and nothing was written to the default location
    [ ! -e "$HOME/works/$(works_runtime_name)" ]
}

# guards: the promote step and its dated rollback, which is where the store's
# layout will later be maintained or broken
@test "a second install promotes and leaves the previous runtime behind" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WORKS_TEST_TARBALL to run this"

    root="$BATS_TEST_TMPDIR/rt"
    env WORKS_RUNTIME="$root" WORKS_RUNTIME_TARBALL="$tarball" \
        bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    run env WORKS_RUNTIME="$root" WORKS_RUNTIME_TARBALL="$tarball" \
        bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    [ -x "$root/bin/wine" ]
    # exactly one dated rollback, beside the runtime
    n="$(find "$(dirname "$root")" -maxdepth 1 -name "$(basename "$root")-rollback-*" | wc -l)"
    [ "$n" -eq 1 ] || { echo "expected 1 rollback, found $n" >&2; false; }
}

# --- the store ----------------------------------------------------------------
# These are the ones that would have caught the promote defect: against a
# correctly shaped store, one ordinary install replaced the channel with a real
# directory, left a rollback symlink pointing into the store, and filed the new
# build under no name at all. The store survived no installs, and the migration
# read the result as already migrated.

@test "a fresh install lands in the store, not the flat path" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WORKS_TEST_TARBALL to run this"

    run env WORKS_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    container="$(works_runtime_store)"
    [ -L "$container/stable" ]
    id="$(readlink "$container/stable")"
    [ -f "$container/$id/bin/wine" ]
    [ "$id" = "$(works_runtime_id "$container/$id")" ]
    # a new user never sees the flat layout
    [ ! -e "$(works_legacy_root)" ]
}

# guards: the resolver, the process scan and the install must all name the same
# tree, which is what /proc/PID/exe reporting resolved paths makes non-obvious
@test "after installing, the resolver points at a real build directory" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WORKS_TEST_TARBALL to run this"

    env WORKS_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    root="$(works_runtime_path)"
    [ -d "$root" ] && [ ! -L "$root" ]
    [ -x "$root/bin/wine" ]
    [ "$root" = "$(readlink -f "$(works_runtime_store)/stable")" ]
}

# guards: an existing flat install is what nearly every user has
@test "a flat install is migrated by the installer, not just by the library" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WORKS_TEST_TARBALL to run this"

    legacy="$(works_legacy_root)"
    mkdir -p "$legacy/bin"
    : > "$legacy/bin/wine"
    printf 'dist-version: 2026.01.01.1\npatch-stack:  0ldbui1daaa\n' \
        > "$legacy/ABLETON-WINE-BUILD-INFO.txt"

    run env WORKS_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    container="$(works_runtime_store)"
    [ ! -e "$legacy" ]
    [ -d "$container/2026.01.01.1+0ldbui1" ]   # the old build, now readable
    [ -L "$container/stable" ]
    [ "$(readlink "$container/stable")" != "2026.01.01.1+0ldbui1" ]  # channel moved on
}

# --- channels -----------------------------------------------------------------
# Which kit you download is the channel choice. install.sh must follow the kit,
# not the machine: installing a nightly while configured for stable would
# otherwise point `stable` at a nightly build.

# guards: install.sh writes the channel file, so "removed everything install.sh
# added" has to include it — left behind, a later install is followed by an
# `works-update` pointed at a channel nothing on the machine chose

# guards: the config directory is not ours to clear out — only the one file is
# guards: the Plug holds Live, its authorisation and the user's sets — the one
# thing here that cannot be reinstalled, so removal must be asked for

# --- setup-prefix.sh's own guard ----------------------------------------------
# Through the .run this never fires, because install.sh stops everything first.
# Standalone it is the only guard there is -- and install.sh's last line tells
# you to run it standalone, so that path is the documented one.

# guards: `wineboot -u` rewriting the registry under a live wineserver
@test "setup-prefix refuses while something runs from the runtime" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export WORKS_RUNTIME="$root"
    cp "$(command -v sleep)" "$root/bin/wineserver"
    "$root/bin/wineserver" 30 &
    local pid=$!
    run bash "$REPO/scripts/setup-prefix.sh"
    kill "$pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"Close Live"* ]]
}

# guards: the refusal must not depend on a terminal -- an unattended run is
# exactly when nobody notices the prefix being rewritten
@test "setup-prefix refuses with no terminal too" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export WORKS_RUNTIME="$root"
    cp "$(command -v sleep)" "$root/bin/wineserver"
    "$root/bin/wineserver" 30 &
    local pid=$!
    run setsid --wait bash "$REPO/scripts/setup-prefix.sh"
    kill "$pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
}

# guards: the guard must not block the .run, where install.sh has already
# stopped everything -- getting past it is the whole requirement
@test "setup-prefix gets past the guard when nothing is running" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export WORKS_RUNTIME="$root"
    run bash "$REPO/scripts/setup-prefix.sh"
    [[ "$output" != *"Close Live"* ]]
}

# guards: the app directory must contain the app — a launcher that lives only on
# PATH means backing up ~/works misses the entry point, and removing the app
# leaves a working command pointing at nothing

# guards: one dated copy per install, on the PATH, pruned by nothing — the
# defect the version store exists to end, in a second place

