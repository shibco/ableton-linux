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
# Nothing here touches a real install: ABLETON_OPT_DIR points the resolvers at
# a throwaway tree.
#
#   ./tests/run.sh tests/unit/migrate-layout.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export ABLETON_OPT_DIR="$BATS_TEST_TMPDIR/opt"
    unset ABLETON_WINE_ROOT
    mkdir -p "$HOME" "$ABLETON_OPT_DIR"
    . "$REPO/scripts/runtime-env.sh"
    # Derived, never spelled out: a literal here would be a second place the
    # runtime name lives, which repo-hygiene rightly refuses.
    LEGACY="$(works_legacy_root)"
    NAME="${LEGACY##*/}"
    CONTAINER="$(ableton_container_root)"
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
    run ableton_migrate_layout
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

    run ableton_migrate_layout
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
    run ableton_migrate_layout
    [[ "$output" == *"set aside"* ]] || { echo "$output" >&2; false; }
    [[ "$output" != *"moved the runtime to"* ]]
}

# guards: nothing is left behind for an older .run to overwrite, and a migrated
# install ends in the same shape a fresh one does
@test "nothing remains at the legacy path" {
    plant "$LEGACY"
    ableton_migrate_layout
    [ ! -e "$LEGACY" ] && [ ! -L "$LEGACY" ]
}

# guards: the resolver and the migration must agree, or the install replaces a
# directory nothing is looking at
@test "the resolver follows the runtime to its new name" {
    plant "$LEGACY" 2026.08.01.1 b4d2f10aaaa
    ableton_migrate_layout
    [ "$(ableton_wine_root)" = "$CONTAINER/2026.08.01.1+b4d2f10" ]
}

# guards: dated rollbacks are the reason the store exists — a timestamp records
# when a runtime was replaced, which is not the question anyone asks
@test "dated rollbacks are renamed by the build they hold" {
    plant "$LEGACY"                            2026.08.01.1 b4d2f10aaaa
    plant "$LEGACY-rollback-20260802T194734Z"  2026.07.29.1 9614003ccc
    plant "$LEGACY-rollback-20260804T113605Z"  2026.07.23.1 237e53cddd
    ableton_migrate_layout
    [ -f "$CONTAINER/2026.07.29.1+9614003/bin/wine" ]
    [ -f "$CONTAINER/2026.07.23.1+237e53c/bin/wine" ]
    [ -z "$(find "$ABLETON_OPT_DIR" -maxdepth 1 -name "$NAME-rollback-*")" ]
}

# guards: two installs of one build collapse to one entry, and the loser is set
# aside rather than deleted — these are multi-gigabyte trees
@test "two rollbacks holding one build keep one and set the rest aside" {
    plant "$LEGACY"                            2026.08.01.1 b4d2f10aaaa
    plant "$LEGACY-rollback-20260802T194734Z"  2026.07.29.1 9614003ccc
    plant "$LEGACY-rollback-20260804T113605Z"  2026.07.29.1 9614003ccc
    ableton_migrate_layout
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
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [ -n "$(find "$CONTAINER" -maxdepth 1 -name 'failed-*' -type d)" ]
}

@test "failed-install debris travels too, so uninstall still finds it" {
    plant "$LEGACY"
    mkdir -p "$LEGACY.failed-20260801T101010Z/bin"
    ableton_migrate_layout
    [ -z "$(find "$ABLETON_OPT_DIR" -maxdepth 1 -name "$NAME.failed-*")" ]
}

# guards: 11.11 and 11.14 trees coexist on the development machine and are not
# this installer's to move
@test "runtimes from other Wine bases are left alone" {
    plant "$LEGACY"
    other="$ABLETON_OPT_DIR/${NAME%.*}.11"
    plant "$other"
    ableton_migrate_layout
    [ -f "$other/bin/wine" ]
}

# --- the no-op rows -----------------------------------------------------------

@test "a fresh install migrates nothing and creates nothing" {
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [ ! -e "$CONTAINER" ]
}

@test "running it twice is a no-op, not a second move" {
    plant "$LEGACY" 2026.08.01.1 b4d2f10aaaa
    ableton_migrate_layout
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [ -f "$CONTAINER/2026.08.01.1+b4d2f10/bin/wine" ]
    [ ! -e "$CONTAINER/2026.08.01.1+b4d2f10/ableton-wine" ]
}

@test "an overridden runtime root is left exactly where the user pinned it" {
    plant "$LEGACY"
    ABLETON_WINE_ROOT="$BATS_TEST_TMPDIR/pinned"
    run ableton_migrate_layout
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
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [ "$(readlink "$CONTAINER/stable")" = "2026.08.04.1+b4d2f10" ]
    [ -f "$CONTAINER/2026.07.29.1+9614003/bin/wine" ]   # the older one is kept
    [ ! -e "$LEGACY" ]
}

@test "an older installer's tree that is older stays a store entry" {
    plant "$CONTAINER/2026.08.04.1+b4d2f10" 2026.08.04.1 b4d2f10aaaa 2026-08-04T10:00:00Z
    ln -s "2026.08.04.1+b4d2f10" "$CONTAINER/stable"
    plant "$LEGACY" 2026.07.29.1 9614003ccc 2026-07-29T10:00:00Z
    ableton_migrate_layout
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
    run ableton_migrate_layout
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"cannot be named"* ]]
    [ -f "$LEGACY/bin/wine" ]
    [ ! -e "$CONTAINER" ]
}

@test "neither tree nameable refuses rather than picking one" {
    mkdir -p "$CONTAINER/anon/bin"
    ln -s "anon" "$CONTAINER/stable"
    mkdir -p "$LEGACY/bin"
    run ableton_migrate_layout
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"neither"* ]]
    [ -d "$LEGACY" ]
}

@test "a symlink left by an earlier layout refuses instead of migrating" {
    mkdir -p "$(dirname "$LEGACY")"
    ln -s "runtimes/stable" "$LEGACY"
    run ableton_migrate_layout
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
    ABLETON_RUNTIME_KEEP=2 ableton_prune_runtimes
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
    ABLETON_RUNTIME_KEEP=1 ableton_prune_runtimes
    [ ! -e "$CONTAINER/2026.08.04.1+zzzzzzz" ]      # older by built-at
    [ -d "$CONTAINER/2026.08.04.1+aaaaaaa" ]
}

# guards: a channel pointing at a pruned entry is a broken install produced by
# housekeeping

@test "retention leaves set-aside trees alone; they are not entries" {
    mkdir -p "$CONTAINER/superseded-20260805T000000Z/old" "$CONTAINER"
    plant_at "$CONTAINER/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z
    ln -s "2026.01.01.1+aaaaaaa" "$CONTAINER/stable"
    ABLETON_RUNTIME_KEEP=1 ableton_prune_runtimes
    [ -d "$CONTAINER/superseded-20260805T000000Z/old" ]
}

@test "a nonsense retention value reverts to the default rather than pruning all" {
    mkdir -p "$CONTAINER"
    plant_at "$CONTAINER/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z
    ln -s "2026.01.01.1+aaaaaaa" "$CONTAINER/stable"
    ABLETON_RUNTIME_KEEP="lots" ableton_prune_runtimes
    [ -d "$CONTAINER/2026.01.01.1+aaaaaaa" ]
}

# --- removal ------------------------------------------------------------------

@test "removal takes the container and everything inside it" {
    plant "$CONTAINER/2026.01.01.1+aaaaaaa"
    mkdir -p "$CONTAINER/superseded-20260805T000000Z"
    ln -s "2026.01.01.1+aaaaaaa" "$CONTAINER/stable"
    ableton_remove_runtimes
    [ ! -e "$CONTAINER" ]
}

@test "removal handles a flat install that never migrated" {
    plant "$LEGACY"
    plant "$LEGACY-rollback-20260802T194734Z"
    ableton_remove_runtimes
    [ -z "$(find "$ABLETON_OPT_DIR" -maxdepth 1 -name "$NAME*")" ]
}

# guards: a stale exported ABLETON_WINE_ROOT from a test session would otherwise
# have this run rm -rf on whatever it names
@test "removal refuses a pinned root that is not a runtime" {
    target="$BATS_TEST_TMPDIR/not-a-runtime"
    mkdir -p "$target/documents"
    run env ABLETON_WINE_ROOT="$target" bash -c \
        ". '$REPO/scripts/runtime-env.sh'; ableton_remove_runtimes"
    [ "$status" -ne 0 ]
    [ -d "$target/documents" ]
}

@test "removal refuses a pinned root of \$HOME" {
    run env ABLETON_WINE_ROOT="$HOME" bash -c \
        ". '$REPO/scripts/runtime-env.sh'; ableton_remove_runtimes"
    [ "$status" -ne 0 ]
    [ -d "$HOME" ]
}

# --- the prefix becomes a Plug -------------------------------------------------
# A runtime can be downloaded again; a prefix holds Live, its authorisation and
# the user's settings, and cannot. Every branch that is not certain refuses.

plug_setup() {
    LEGACY_PLUG="$HOME/.wine-ableton"
    DEST_PLUG="$(ableton_wine_prefix)"
}

a_prefix() {   # a_prefix <dir>
    mkdir -p "$1/drive_c/users" "$1/dosdevices"
    : > "$1/system.reg"
    ln -sfn ../drive_c "$1/dosdevices/c:"
    printf 'a set\n' > "$1/drive_c/users/mine.als"
}

# guards: two prefixes can hold different Lives and different authorisations —
# picking one silently loses the other's work

# guards: renaming a prefix out from under a live wineserver corrupts its
# registry, and install.sh's stop is scoped to the runtime, which is a
# different set of processes

# guards: environ is mode 400 and gated by ptrace_may_access, so `[ -r ]` passes
# where the read still fails — and the shell prints its own redirection error
# before tr can suppress it. A scan that noisy is a scan nobody reads.

