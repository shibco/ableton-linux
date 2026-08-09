#!/usr/bin/env bats
#
# scripts/runtime-env.sh — the flat-to-store migration.
#
# This renames the directory an existing user's Wine runs from, so every row of
# the decision table gets a test, including the ones that must refuse. The rule
# throughout is that ambiguity is an error: a live tree that cannot be named
# from its own BUILD-INFO means the script cannot know what it is about to
# install over, and guessing wrong swaps a runtime out from under a running
# Live.
#
# Nothing here touches a real install: WORKS_HOME points the resolvers at
# a throwaway tree.
#
#   ./tests/run.sh tests/unit/migrate-layout.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export WORKS_HOME="$BATS_TEST_TMPDIR/opt"
    unset WORKS_RUNTIME
    mkdir -p "$HOME" "$WORKS_HOME"
    . "$REPO/scripts/runtime-env.sh"
    # Derived, never spelled out: a literal here would be a second place the
    # runtime name lives, which repo-hygiene rightly refuses.
    LEGACY="$(works_legacy_root)"
    NAME="${LEGACY##*/}"
    CONTAINER="$(works_runtime_store)"
}

# A runtime is recognisable by shape, so the tests plant one rather than an
# empty directory: a bare mkdir would pass assertions a real move would not.
plant() {
    local dir="$1" ver="${2:-2026.08.01.1}" disc="${3:-aaaaaaabbbbbbb}" at="${4:-}"
    mkdir -p "$dir/bin" "$dir/share/wine"
    : > "$dir/bin/wine"
    { printf 'dist-version: %s\n' "$ver"
      printf 'patch-stack:  %s\n' "$disc"
      [ -z "$at" ] || printf 'built-at:     %s\n' "$at"
    } > "$dir/ABLETON-WINE-BUILD-INFO.txt"
}

# --- the migrating rows -------------------------------------------------------

@test "a flat install moves into the store under its own name" {
    plant "$LEGACY" 2026.08.01.1 b4d2f10aaaa
    run works_migrate_layout
    [ "$status" -eq 0 ]
    [ -f "$CONTAINER/2026.08.01.1+b4d2f10/bin/wine" ]
    [ -L "$CONTAINER/stable" ]
    [ "$(readlink "$CONTAINER/stable")" = "2026.08.01.1+b4d2f10" ]
}

# guards: the primary path ended in a bare `mv` while both sibling writers into
# the store guard first. With an entry already carrying this id, mv landed the
# legacy tree *inside* it — invisible to retention and to the container-scoped
# uninstall, the channel pointing at the incumbent, and the command reporting
# success. Reachable whenever the channel symlink is genuinely absent rather
# than dangling, which is what this sets up.
@test "an id collision sets the old tree aside instead of nesting it in the entry" {
    plant "$LEGACY" 2026.08.01.1 b4d2f10aaaa
    plant "$CONTAINER/2026.08.01.1+b4d2f10" 2026.08.01.1 b4d2f10aaaa
    [ ! -e "$CONTAINER/stable" ]          # absent, not dangling

    run works_migrate_layout
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ ! -e "$CONTAINER/2026.08.01.1+b4d2f10/$NAME" ] \
        || { echo "the legacy tree was nested inside the entry" >&2; false; }
    [ -n "$(find "$CONTAINER" -maxdepth 1 -name 'superseded-*' -type d)" ] \
        || { echo "the legacy tree was not set aside anywhere" >&2; false; }
    [ "$(readlink "$CONTAINER/stable")" = "2026.08.01.1+b4d2f10" ]
}

# guards: the report must not claim a move that did not happen — "moved the
# runtime to" on a collision is how this stayed invisible
@test "a collision says the tree was set aside, not that it was moved" {
    plant "$LEGACY" 2026.08.01.1 b4d2f10aaaa
    plant "$CONTAINER/2026.08.01.1+b4d2f10" 2026.08.01.1 b4d2f10aaaa
    run works_migrate_layout
    [[ "$output" == *"set aside"* ]] || { echo "$output" >&2; false; }
    [[ "$output" != *"moved the runtime to"* ]]
}

# guards: nothing is left behind for an older .run to overwrite, and a migrated
# install ends in the same shape a fresh one does
@test "nothing remains at the legacy path" {
    plant "$LEGACY"
    works_migrate_layout
    [ ! -e "$LEGACY" ] && [ ! -L "$LEGACY" ]
}

# guards: the resolver and the migration must agree, or the install replaces a
# directory nothing is looking at
@test "the resolver follows the runtime to its new name" {
    plant "$LEGACY" 2026.08.01.1 b4d2f10aaaa
    works_migrate_layout
    [ "$(works_runtime_path)" = "$CONTAINER/2026.08.01.1+b4d2f10" ]
}

# guards: dated rollbacks are the reason the store exists — a timestamp records
# when a runtime was replaced, which is not the question anyone asks
@test "dated rollbacks are renamed by the build they hold" {
    plant "$LEGACY"                            2026.08.01.1 b4d2f10aaaa
    plant "$LEGACY-rollback-20260802T194734Z"  2026.07.29.1 9614003ccc
    plant "$LEGACY-rollback-20260804T113605Z"  2026.07.23.1 237e53cddd
    works_migrate_layout
    [ -f "$CONTAINER/2026.07.29.1+9614003/bin/wine" ]
    [ -f "$CONTAINER/2026.07.23.1+237e53c/bin/wine" ]
    [ -z "$(find "$WORKS_HOME" -maxdepth 1 -name "$NAME-rollback-*")" ]
}

# guards: two installs of one build collapse to one entry, and the loser is set
# aside rather than deleted — these are multi-gigabyte trees
@test "two rollbacks holding one build keep one and set the rest aside" {
    plant "$LEGACY"                            2026.08.01.1 b4d2f10aaaa
    plant "$LEGACY-rollback-20260802T194734Z"  2026.07.29.1 9614003ccc
    plant "$LEGACY-rollback-20260804T113605Z"  2026.07.29.1 9614003ccc
    works_migrate_layout
    [ -f "$CONTAINER/2026.07.29.1+9614003/bin/wine" ]
    [ -n "$(find "$CONTAINER" -maxdepth 1 -name 'superseded-*' -type d)" ]
    [ -n "$(find "$CONTAINER"/superseded-* -name 'bin' -type d)" ]
}

# guards: a debug tree rolled back by the selector bug has no dist-version at
# all; refusing the whole migration over debris would block anyone who ever hit
# that bug
@test "a rollback that cannot be named moves aside instead of blocking" {
    plant "$LEGACY"
    mkdir -p "$LEGACY-rollback-20260804T130806Z/bin"
    : > "$LEGACY-rollback-20260804T130806Z/bin/wine"
    run works_migrate_layout
    [ "$status" -eq 0 ]
    [ -n "$(find "$CONTAINER" -maxdepth 1 -name 'failed-*' -type d)" ]
}

@test "failed-install debris travels too, so uninstall still finds it" {
    plant "$LEGACY"
    mkdir -p "$LEGACY.failed-20260801T101010Z/bin"
    works_migrate_layout
    [ -z "$(find "$WORKS_HOME" -maxdepth 1 -name "$NAME.failed-*")" ]
}

# guards: 11.11 and 11.14 trees coexist on the development machine and are not
# this installer's to move
@test "runtimes from other Wine bases are left alone" {
    plant "$LEGACY"
    other="$WORKS_HOME/${NAME%.*}.11"
    plant "$other"
    works_migrate_layout
    [ -f "$other/bin/wine" ]
}

# --- the no-op rows -----------------------------------------------------------

@test "a fresh install migrates nothing and creates nothing" {
    run works_migrate_layout
    [ "$status" -eq 0 ]
    [ ! -e "$CONTAINER" ]
}

@test "running it twice is a no-op, not a second move" {
    plant "$LEGACY" 2026.08.01.1 b4d2f10aaaa
    works_migrate_layout
    run works_migrate_layout
    [ "$status" -eq 0 ]
    [ -f "$CONTAINER/2026.08.01.1+b4d2f10/bin/wine" ]
    [ ! -e "$CONTAINER/2026.08.01.1+b4d2f10/ableton-wine" ]
}

@test "an overridden runtime root is left exactly where the user pinned it" {
    plant "$LEGACY"
    WORKS_RUNTIME="$BATS_TEST_TMPDIR/pinned"
    run works_migrate_layout
    [ "$status" -eq 0 ]
    [ -d "$LEGACY" ]
    [ ! -e "$CONTAINER" ]
}

# --- the recovering row -------------------------------------------------------

# guards: an older .run over a migrated install writes a flat tree at the legacy
# path. That is a normal action on a machine holding an older installer, not
# corruption, and refusing would leave two runtimes and no way to tell which is
# live.
@test "an older installer's tree beside a migrated one is adopted when newer" {
    plant "$CONTAINER/2026.07.29.1+9614003" 2026.07.29.1 9614003ccc 2026-07-29T10:00:00Z
    ln -s "2026.07.29.1+9614003" "$CONTAINER/stable"
    plant "$LEGACY" 2026.08.04.1 b4d2f10aaaa 2026-08-04T10:00:00Z
    run works_migrate_layout
    [ "$status" -eq 0 ]
    [ "$(readlink "$CONTAINER/stable")" = "2026.08.04.1+b4d2f10" ]
    [ -f "$CONTAINER/2026.07.29.1+9614003/bin/wine" ]   # the older one is kept
    [ ! -e "$LEGACY" ]
}

@test "an older installer's tree that is older stays a store entry" {
    plant "$CONTAINER/2026.08.04.1+b4d2f10" 2026.08.04.1 b4d2f10aaaa 2026-08-04T10:00:00Z
    ln -s "2026.08.04.1+b4d2f10" "$CONTAINER/stable"
    plant "$LEGACY" 2026.07.29.1 9614003ccc 2026-07-29T10:00:00Z
    works_migrate_layout
    [ "$(readlink "$CONTAINER/stable")" = "2026.08.04.1+b4d2f10" ]
    [ -f "$CONTAINER/2026.07.29.1+9614003/bin/wine" ]
    [ ! -e "$LEGACY" ]
}

# --- the refusing rows --------------------------------------------------------

# guards: the destructive case. Installing over a runtime that cannot be
# identified is a guess, and the guess is made while holding `mv`.
@test "a live tree that cannot be named refuses, and moves nothing" {
    mkdir -p "$LEGACY/bin"
    : > "$LEGACY/bin/wine"
    run works_migrate_layout
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"cannot be named"* ]]
    [ -f "$LEGACY/bin/wine" ]
    [ ! -e "$CONTAINER" ]
}

@test "neither tree nameable refuses rather than picking one" {
    mkdir -p "$CONTAINER/anon/bin"
    ln -s "anon" "$CONTAINER/stable"
    mkdir -p "$LEGACY/bin"
    run works_migrate_layout
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"neither"* ]]
    [ -d "$LEGACY" ]
}

@test "a symlink left by an earlier layout refuses instead of migrating" {
    mkdir -p "$(dirname "$LEGACY")"
    ln -s "runtimes/stable" "$LEGACY"
    run works_migrate_layout
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"symlink"* ]]
}

# --- retention ----------------------------------------------------------------

plant_at() { plant "$1" "$2" "$3" "$4"; }

@test "retention keeps the configured number of entries, oldest first" {
    mkdir -p "$CONTAINER"
    plant_at "$CONTAINER/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z
    plant_at "$CONTAINER/2026.02.01.1+bbbbbbb" 2026.02.01.1 bbbbbbbxxx 2026-02-01T00:00:00Z
    plant_at "$CONTAINER/2026.03.01.1+ccccccc" 2026.03.01.1 cccccccxxx 2026-03-01T00:00:00Z
    ln -s "2026.03.01.1+ccccccc" "$CONTAINER/stable"
    WORKS_RUNTIME_KEEP=2 works_prune_runtimes
    [ ! -e "$CONTAINER/2026.01.01.1+aaaaaaa" ]      # oldest went
    [ -d "$CONTAINER/2026.02.01.1+bbbbbbb" ]
    [ -d "$CONTAINER/2026.03.01.1+ccccccc" ]
}

# guards: names tie across every nightly between two releases, so ordering on
# the name falls through to comparing hashes — deterministic, unrelated to age
@test "retention orders by built-at, not by the name" {
    mkdir -p "$CONTAINER"
    # same dist-version; the name would sort these the wrong way round
    plant_at "$CONTAINER/2026.08.04.1+zzzzzzz" 2026.08.04.1 zzzzzzzxxx 2026-08-04T01:00:00Z
    plant_at "$CONTAINER/2026.08.04.1+aaaaaaa" 2026.08.04.1 aaaaaaaxxx 2026-08-04T09:00:00Z
    ln -s "2026.08.04.1+aaaaaaa" "$CONTAINER/stable"
    WORKS_RUNTIME_KEEP=1 works_prune_runtimes
    [ ! -e "$CONTAINER/2026.08.04.1+zzzzzzz" ]      # older by built-at
    [ -d "$CONTAINER/2026.08.04.1+aaaaaaa" ]
}

# guards: a channel pointing at a pruned entry is a broken install produced by
# housekeeping
@test "retention never removes what the channel points at" {
    mkdir -p "$CONTAINER"
    plant_at "$CONTAINER/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z
    plant_at "$CONTAINER/2026.02.01.1+bbbbbbb" 2026.02.01.1 bbbbbbbxxx 2026-02-01T00:00:00Z
    ln -s "2026.01.01.1+aaaaaaa" "$CONTAINER/stable"   # channel at the OLDEST
    WORKS_RUNTIME_KEEP=1 works_prune_runtimes
    [ -d "$CONTAINER/2026.01.01.1+aaaaaaa" ]
    [ -n "$(works_runtime_path)" ]
}

@test "retention leaves set-aside trees alone; they are not entries" {
    mkdir -p "$CONTAINER/superseded-20260805T000000Z/old" "$CONTAINER"
    plant_at "$CONTAINER/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z
    ln -s "2026.01.01.1+aaaaaaa" "$CONTAINER/stable"
    WORKS_RUNTIME_KEEP=1 works_prune_runtimes
    [ -d "$CONTAINER/superseded-20260805T000000Z/old" ]
}

@test "a nonsense retention value reverts to the default rather than pruning all" {
    mkdir -p "$CONTAINER"
    plant_at "$CONTAINER/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z
    ln -s "2026.01.01.1+aaaaaaa" "$CONTAINER/stable"
    WORKS_RUNTIME_KEEP="lots" works_prune_runtimes
    [ -d "$CONTAINER/2026.01.01.1+aaaaaaa" ]
}

# --- removal ------------------------------------------------------------------

@test "removal takes the container and everything inside it" {
    plant "$CONTAINER/2026.01.01.1+aaaaaaa"
    mkdir -p "$CONTAINER/superseded-20260805T000000Z"
    ln -s "2026.01.01.1+aaaaaaa" "$CONTAINER/stable"
    works_remove_runtimes
    [ ! -e "$CONTAINER" ]
}

@test "removal handles a flat install that never migrated" {
    plant "$LEGACY"
    plant "$LEGACY-rollback-20260802T194734Z"
    works_remove_runtimes
    [ -z "$(find "$WORKS_HOME" -maxdepth 1 -name "$NAME*")" ]
}

# guards: a stale exported WORKS_RUNTIME from a test session would otherwise
# have this run rm -rf on whatever it names
@test "removal refuses a pinned root that is not a runtime" {
    target="$BATS_TEST_TMPDIR/not-a-runtime"
    mkdir -p "$target/documents"
    run env WORKS_RUNTIME="$target" bash -c \
        ". '$REPO/scripts/runtime-env.sh'; works_remove_runtimes"
    [ "$status" -ne 0 ]
    [ -d "$target/documents" ]
}

@test "removal refuses a pinned root of \$HOME" {
    run env WORKS_RUNTIME="$HOME" bash -c \
        ". '$REPO/scripts/runtime-env.sh'; works_remove_runtimes"
    [ "$status" -ne 0 ]
    [ -d "$HOME" ]
}

# --- the prefix becomes a Plug -------------------------------------------------
# A runtime can be downloaded again; a prefix holds Live, its authorisation and
# the user's settings, and cannot. Every branch that is not certain refuses.

plug_setup() {
    LEGACY_PLUG="$HOME/.wine-ableton"
    DEST_PLUG="$(works_plug_path)"
}

a_prefix() {   # a_prefix <dir>
    mkdir -p "$1/drive_c/users" "$1/dosdevices"
    : > "$1/system.reg"
    ln -sfn ../drive_c "$1/dosdevices/c:"
    printf 'a set\n' > "$1/drive_c/users/mine.als"
}

@test "plug: a flat prefix moves into the store" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    run works_migrate_plug
    [ "$status" -eq 0 ]
    [ -d "$DEST_PLUG" ] && [ ! -e "$LEGACY_PLUG" ]
}

# guards: the prefix is the one thing here that cannot be re-downloaded
@test "plug: the contents survive the move intact" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    works_migrate_plug >/dev/null
    [ "$(cat "$DEST_PLUG/drive_c/users/mine.als")" = "a set" ]
    [ -L "$DEST_PLUG/dosdevices/c:" ]
    [ "$(readlink "$DEST_PLUG/dosdevices/c:")" = "../drive_c" ]
}

@test "plug: re-running after a successful move is a no-op" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    works_migrate_plug >/dev/null
    run works_migrate_plug
    [ "$status" -eq 0 ]
    [ -f "$DEST_PLUG/drive_c/users/mine.als" ]
}

@test "plug: nothing installed is not an error" {
    plug_setup
    run works_migrate_plug
    [ "$status" -eq 0 ]
    [ ! -e "$DEST_PLUG" ]
}

# guards: two prefixes can hold different Lives and different authorisations —
# picking one silently loses the other's work
@test "plug: a prefix at both paths refuses, naming both" {
    plug_setup; a_prefix "$LEGACY_PLUG"; a_prefix "$DEST_PLUG"
    run works_migrate_plug
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"$LEGACY_PLUG"* ]]
    [[ "$stderr$output" == *"$DEST_PLUG"* ]]
    [ -d "$LEGACY_PLUG" ]
}

@test "plug: a symlink where the prefix belongs refuses" {
    plug_setup; mkdir -p "$HOME/elsewhere"
    ln -s "$HOME/elsewhere" "$LEGACY_PLUG"
    run works_migrate_plug
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"symlink"* ]]
}

# guards: a pinned prefix is a deliberate choice — the VM harness runs two
@test "plug: an explicit WORKS_PLUG is left alone" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    WORKS_PLUG="$HOME/pinned" run works_migrate_plug
    [ "$status" -eq 0 ]
    [ -d "$LEGACY_PLUG" ]
}

# guards: renaming a prefix out from under a live wineserver corrupts its
# registry, and install.sh's stop is scoped to the runtime, which is a
# different set of processes
@test "plug: a prefix something is running from is not moved" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    export WORKS_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$WORKS_PROC_ROOT/4242"
    printf 'PATH=/usr/bin\0WINEPREFIX=%s\0HOME=%s\0' "$LEGACY_PLUG" "$HOME" \
        > "$WORKS_PROC_ROOT/4242/environ"
    run works_migrate_plug
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"still running"* ]]
    [ -d "$LEGACY_PLUG" ]
}

@test "plug: a process holding a different prefix does not block the move" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    export WORKS_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$WORKS_PROC_ROOT/4242"
    printf 'WINEPREFIX=%s\0' "$HOME/.wine-somethingelse" > "$WORKS_PROC_ROOT/4242/environ"
    run works_migrate_plug
    [ "$status" -eq 0 ]
    [ -d "$DEST_PLUG" ]
}

@test "plug: an unreadable process entry is skipped, not fatal" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    export WORKS_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$WORKS_PROC_ROOT/4242" "$WORKS_PROC_ROOT/self"
    : > "$WORKS_PROC_ROOT/4242/environ"; chmod 000 "$WORKS_PROC_ROOT/4242/environ"
    run works_migrate_plug
    chmod 644 "$WORKS_PROC_ROOT/4242/environ" 2>/dev/null || true
    [ "$status" -eq 0 ]
}

# guards: environ is mode 400 and gated by ptrace_may_access, so `[ -r ]` passes
# where the read still fails — and the shell prints its own redirection error
# before tr can suppress it. A scan that noisy is a scan nobody reads.
@test "plug: an unreadable process entry says nothing on stderr" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    export WORKS_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$WORKS_PROC_ROOT/4242"
    : > "$WORKS_PROC_ROOT/4242/environ"; chmod 000 "$WORKS_PROC_ROOT/4242/environ"
    run works_migrate_plug
    chmod 644 "$WORKS_PROC_ROOT/4242/environ" 2>/dev/null || true
    [[ "$stderr" != *"Permission denied"* ]] || { echo "leaked: $stderr" >&2; false; }
}

@test "plug: the refusal names what is holding the prefix" {
    plug_setup; a_prefix "$LEGACY_PLUG"
    export WORKS_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    mkdir -p "$WORKS_PROC_ROOT/4242"
    printf 'WINEPREFIX=%s\0' "$LEGACY_PLUG" > "$WORKS_PROC_ROOT/4242/environ"
    printf 'wineserver\0' > "$WORKS_PROC_ROOT/4242/cmdline"
    run works_migrate_plug
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"4242"* ]] && [[ "$stderr$output" == *"wineserver"* ]]
}

# --- the prefix, when a destination already exists -----------------------------

setup_plug() {   # legacy has a real prefix; $1 decides what is at the destination
    mkdir -p "$HOME/.wine-ableton/drive_c/users" "$HOME/.wine-ableton/dosdevices"
    printf 'WINE REGISTRY Version 2\n#arch=win64\n' > "$HOME/.wine-ableton/system.reg"
    DEST="$(works_plug_path)"
    case "$1" in
        prefix) mkdir -p "$DEST/drive_c/users"
                printf 'WINE REGISTRY Version 2\n#arch=win64\n' > "$DEST/system.reg" ;;
        stub)   mkdir -p "$DEST/drive_c/users" "$DEST/drive_c/windows"
                printf 'WINE REGISTRY Version 2\n' > "$DEST/system.reg" ;;
        empty)  mkdir -p "$DEST" ;;
        none)   : ;;
    esac
}

# guards: refusing here aborted a whole install over a directory nothing reads.
# If the destination holds a prefix the machine is already on the new layout -
# works_plug_path resolves there and the launcher opens it - so there is nothing
# to migrate and the legacy path is leftover, not a decision to make.
@test "a prefix already at the destination means the move is done, not ambiguous" {
    setup_plug prefix
    run works_migrate_plug
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"already at"* ]]
    [ -d "$HOME/.wine-ableton" ]          # left alone, not deleted behind their back
}

# guards: an unfinished prefix is not a prefix, and keeping it means Wine
# refuses every 64-bit application in it forever
# guards: nothing here deletes a prefix. The store sets a runtime it cannot use
# aside rather than removing it, and a prefix is worth more than a runtime - one
# can be downloaded again and the other cannot.
@test "an unfinished prefix at the destination is set aside, not deleted" {
    setup_plug stub
    run works_migrate_plug
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ ! -e "$HOME/.wine-ableton" ]
    grep -q '^#arch' "$DEST/system.reg"
    [ -n "$(find "$(dirname "$DEST")" -maxdepth 1 -name "$(basename "$DEST").unfinished-*")" ] \
        || { echo "the unfinished prefix was removed rather than set aside" >&2; false; }
}

@test "an empty directory at the destination does not block the move" {
    setup_plug empty
    run works_migrate_plug
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.wine-ableton" ]
    grep -q '^#arch' "$DEST/system.reg"
}
