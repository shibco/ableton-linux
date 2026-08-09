#!/usr/bin/env bats
#
# scripts/works-runtime — choosing which build is live.
#
# The store made rollback possible and nothing exposed it: switching meant
# `ln -sfn` against a name you had to look up. These cover the two things that
# matter — that `use` refuses anything that is not a runtime you could actually
# launch, and that `path` answers on both layouts, because scripts and docs
# resolve through it instead of naming a directory.
#
#   ./tests/run.sh tests/unit/works-runtime.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

RT() { bash "$REPO/scripts/works-runtime" "$@"; }

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export WORKS_HOME="$BATS_TEST_TMPDIR/opt"
    unset WORKS_RUNTIME
    mkdir -p "$HOME" "$WORKS_HOME"
    . "$REPO/scripts/runtime-env.sh"
    C="$(works_runtime_store)"
    LEGACY="$(works_legacy_root)"
}

# fake_live backgrounds a process from the test shell, so a test that fails
# before stopping it would leave it running for the length of its sleep.
#
# The wait matters as much as the kill: its argv is a Windows-style Live path,
# which is exactly what works_runtime_busy's pgrep fallback matches. Left
# unreaped it is visible to every later test file that does not stub pgrep, and
# the failure lands over there rather than here.
teardown() {
    [ -z "${FAKE_LIVE:-}" ] && return 0
    kill -9 "$FAKE_LIVE" 2>/dev/null || true
    wait "$FAKE_LIVE" 2>/dev/null || true
}

plant() {
    local dir="$1" ver="$2" disc="$3" at="${4:-}" base="${5:-wine-11.13}"
    mkdir -p "$dir/bin"
    printf '#!/bin/sh\necho wine-11.13\n' > "$dir/bin/wine"; chmod +x "$dir/bin/wine"
    { printf 'dist-version: %s\n' "$ver"; printf 'patch-stack:  %s\n' "$disc"
      printf 'wine:         %s\n' "$base"
      [ -z "$at" ] || printf 'built-at:     %s\n' "$at"; } > "$dir/ABLETON-WINE-BUILD-INFO.txt"
}

store() {
    plant "$C/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z
    plant "$C/2026.06.01.1+bbbbbbb" 2026.06.01.1 bbbbbbbxxx 2026-06-01T00:00:00Z
    ln -s "2026.06.01.1+bbbbbbb" "$C/stable"
}

# --- path ---------------------------------------------------------------------

# guards: docs and scripts resolve through this instead of naming a directory,
# so it has to answer before the store exists as well as after
@test "path answers on the flat layout" {
    plant "$LEGACY" 2026.01.01.1 aaaaaaaxxx
    run RT path
    [ "$status" -eq 0 ]
    [ "$output" = "$LEGACY" ]
}

@test "path honours an explicit pin" {
    store
    WORKS_RUNTIME="$BATS_TEST_TMPDIR/pinned" run RT path
    [ "$output" = "$BATS_TEST_TMPDIR/pinned" ]
}

# --- list ---------------------------------------------------------------------

@test "list marks the live build" {
    store
    run RT list
    [ "$status" -eq 0 ]
    [[ "$output" == *"* 2026.06.01.1+bbbbbbb"* ]]
    [[ "$output" == *"  2026.01.01.1+aaaaaaa"* ]]
}

# guards: the path is what people copy into a script, a bug report or a `cd`,
# and rebuilding it by hand from a store root and an id invites the typo
@test "list shows each build's path, abbreviated under home" {
    store
    run RT list
    [ "$status" -eq 0 ]
    [[ "$output" == *"PATH"* ]]
    [[ "$output" == *"/runtimes/2026.06.01.1+bbbbbbb"* ]]
    [[ "$output" == *"/runtimes/2026.01.01.1+aaaaaaa"* ]]
    # under $HOME it is written ~/..., never the expanded home directory
    [[ "$output" != *"$HOME/works"* ]] || { echo "home was not abbreviated" >&2; false; }
}

# guards: names tie across nightlies, so ordering is by built-at
@test "list is newest first" {
    store
    run RT list
    [ "$(echo "$output" | grep -n '2026.06.01.1' | cut -d: -f1)" -lt \
      "$(echo "$output" | grep -n '2026.01.01.1' | cut -d: -f1)" ]
}

@test "list says so when there is no store yet" {
    plant "$LEGACY" 2026.01.01.1 aaaaaaaxxx
    run RT list
    [ "$status" -eq 0 ]
    [[ "$output" == *"predates it"* ]]
}

# guards: set-aside trees are not builds you can choose, but their existence is
# worth saying so nobody thinks the migration deleted something
@test "list does not offer quarantined trees, but mentions them" {
    store
    mkdir -p "$C/superseded-20260101T000000Z/old"
    run RT list
    [[ "$output" != *"superseded-20260101T000000Z "* ]]
    [[ "$output" == *"set-aside"* ]]
}

# --- use ----------------------------------------------------------------------

@test "use --previous picks the other build" {
    store
    run RT use --previous
    [ "$status" -eq 0 ]
    [ "$(readlink "$C/stable")" = "2026.01.01.1+aaaaaaa" ]
}

@test "use --previous refuses when only one build is installed" {
    plant "$C/2026.06.01.1+bbbbbbb" 2026.06.01.1 bbbbbbbxxx
    ln -s "2026.06.01.1+bbbbbbb" "$C/stable"
    run RT use --previous
    [ "$status" -ne 0 ]
    [[ "$output" == *"only one build"* ]]
}

# guards: the channel is what the launcher resolves through — pointing it at
# something unlaunchable is how you get an install that cannot start
@test "use refuses a name that is not installed" {
    store
    run RT use 2026.99.99.9+zzzzzzz
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such build"* ]]
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}

@test "use refuses a directory with no readable BUILD-INFO" {
    store
    mkdir -p "$C/notabuild/bin"
    run RT use notabuild
    [ "$status" -ne 0 ]
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}

@test "use refuses an entry with no wine binary" {
    store
    plant "$C/2026.07.01.1+ccccccc" 2026.07.01.1 cccccccxxx
    rm -f "$C/2026.07.01.1+ccccccc/bin/wine"
    run RT use 2026.07.01.1+ccccccc
    [ "$status" -ne 0 ]
    [[ "$output" == *"no bin/wine"* ]]
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}

@test "use refuses when there is no store" {
    plant "$LEGACY" 2026.01.01.1 aaaaaaaxxx
    run RT use anything
    [ "$status" -ne 0 ]
}

# --- the Wine base ------------------------------------------------------------
# A Plug is bound to a base: Wine re-bootstraps the prefix when the runtime's
# wine.inf and the prefix's .update-timestamp disagree, and it cannot go back.
# Switching between bases is a one-way door and nothing said so.

@test "list shows the Wine base each build carries" {
    store
    run RT list
    [[ "$output" == *"WINE"* ]]
    [[ "$output" == *"wine-11.13"* ]]
}

@test "use is silent when the base is unchanged" {
    store
    run RT use 2026.01.01.1+aaaaaaa
    [ "$status" -eq 0 ]
    [[ "$output" != *"different Wine base"* ]]
}

# guards: the prefix cannot be taken back, so this must not happen quietly
@test "use refuses a base change with no terminal to ask on" {
    store
    plant "$C/2026.07.01.1+ddddddd" 2026.07.01.1 dddddddxxx 2026-07-01T00:00:00Z wine-11.14
    # setsid detaches the controlling terminal. Without it this inherits the
    # terminal of whoever ran the suite, takes the interactive branch, and blocks.
    run setsid bash "$REPO/scripts/works-runtime" use 2026.07.01.1+ddddddd
    [ "$status" -ne 0 ]
    [[ "$output" == *"different Wine base"* ]]
    [[ "$output" == *"--force"* ]]
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}

@test "use --force accepts a base change deliberately" {
    store
    plant "$C/2026.07.01.1+ddddddd" 2026.07.01.1 dddddddxxx 2026-07-01T00:00:00Z wine-11.14
    run RT use 2026.07.01.1+ddddddd --force
    [ "$status" -eq 0 ]
    [ "$(readlink "$C/stable")" = "2026.07.01.1+ddddddd" ]
}

# guards: forward Wine supports, backward it does not - the wording has to differ
@test "a downgrade is named as a downgrade" {
    plant "$C/2026.07.01.1+ddddddd" 2026.07.01.1 dddddddxxx 2026-07-01T00:00:00Z wine-11.14
    plant "$C/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z wine-11.13
    ln -s "2026.07.01.1+ddddddd" "$C/stable"
    run setsid bash "$REPO/scripts/works-runtime" use 2026.01.01.1+aaaaaaa
    [[ "$output" == *"DOWNGRADE"* ]]
    [[ "$output" == *"does not support"* ]]
}

# --- the picker ---------------------------------------------------------------

# guards: a script calling `use` with no argument must fail, not block forever
@test "use with no argument refuses when there is no terminal" {
    store
    run setsid bash "$REPO/scripts/works-runtime" use
    [ "$status" -ne 0 ]
    [[ "$output" == *"no terminal"* ]]
    [[ "$output" == *"works runtime use 2026"* ]]
}

# --- a nightly's longer name --------------------------------------------------

# guards: the BUILD column was exactly as wide as a nightly id --
# 2026.08.06.1+nightly.79d8960 is 28 characters in what was a 28-wide field, so
# it rendered with a single space and a same-day counter reaching .10 would have
# run the two columns together
@test "list: a nightly id does not crowd the WINE column" {
    plant "$C/2026.08.06.1+nightly.79d8960" 2026.08.06.1 79d8960xxx 2026-08-06T16:11:28Z
    plant "$C/2026.08.04.1+b0d847a"         2026.08.04.1 b0d847axxx 2026-08-04T09:31:00Z
    ln -s "2026.08.06.1+nightly.79d8960" "$C/nightly"
    run RT list
    [ "$status" -eq 0 ]
    while read -r line; do
        case "$line" in
            *wine-11.13*) [[ "$line" =~ [[:space:]][[:space:]]wine-11\.13 ]] \
                || { echo "columns collided: $line" >&2; false; } ;;
        esac
    done <<< "$output"
}

# guards: the id contains dots and a plus, so anything treating it as a pattern
# rather than a name would match the wrong entry or none
@test "use accepts a nightly build by its full name" {
    plant "$C/2026.08.06.1+nightly.79d8960" 2026.08.06.1 79d8960xxx 2026-08-06T16:11:28Z
    plant "$C/2026.08.04.1+b0d847a"         2026.08.04.1 b0d847axxx 2026-08-04T09:31:00Z
    ln -s "2026.08.04.1+b0d847a" "$C/stable"
    run RT use 2026.08.06.1+nightly.79d8960
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ "$(readlink "$C/stable")" = "2026.08.06.1+nightly.79d8960" ]
}

# --- stop ---------------------------------------------------------------------

# A process that reads as Live to both scans: /proc/PID/exe has to resolve inside
# the runtime, which a copy of sleep in the store gives us, and argv has to carry
# a Windows-style Live path, which `exec -a` sets. Neither can be faked with a
# plain sleep - the exe link is what the runtime scan matches on, and the command
# line is what separates Live from Wine's own services.
fake_live() {
    local bin="$C/2026.06.01.1+bbbbbbb/bin"
    cp "$(command -v sleep)" "$bin/wine-preloader"
    bash -c 'exec -a "C:\Ableton Live 12.exe" "$0" 60' "$bin/wine-preloader" &
    FAKE_LIVE=$!
    local i
    for i in $(seq 1 40); do
        [ -e "/proc/$FAKE_LIVE/exe" ] && return 0
        sleep 0.05
    done
    echo "the fake Live never appeared in /proc" >&2; false
}

@test "stop says so when nothing is running" {
    store
    run RT stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing is running"* ]]
}

# guards: stopping Live discards unsaved work, so it is the one process here
# worth asking about, and nobody can answer without a terminal
@test "stop refuses a running Live with no terminal to confirm on" {
    store
    fake_live
    run setsid bash "$REPO/scripts/works-runtime" stop
    [ "$status" -ne 0 ]
    [[ "$output" == *"pass -y"* ]]
    kill -0 "$FAKE_LIVE"        # and it is still running
}

# guards: -y was parsed by cmd_stop but never reached it. The dispatch called
# cmd_stop with no arguments at all, so the flag the refusal above tells you to
# pass did nothing, and no script could stop a running Live by any means.
@test "stop -y stops a running Live without asking" {
    store
    fake_live
    run setsid bash "$REPO/scripts/works-runtime" stop -y
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"Stopped."* ]]
    # wait reaps it too: a killed child is a zombie until then, and kill -0
    # succeeds on a zombie, so checking liveness that way would pass either way.
    # The status has to be caught rather than tested afterwards - a signalled
    # child makes wait return 143, and under set -e that ends the test first.
    rc=0; wait "$FAKE_LIVE" 2>/dev/null || rc=$?
    [ "$rc" -gt 128 ] || { echo "the fake Live exited on its own, not by signal" >&2; false; }
}

@test "stop --yes is the same flag spelled out" {
    store
    fake_live
    run setsid bash "$REPO/scripts/works-runtime" stop --yes
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    rc=0; wait "$FAKE_LIVE" 2>/dev/null || rc=$?
    [ "$rc" -gt 128 ]
}

# guards: `works stop` is the documented spelling, and it crosses two dispatchers
# before the flag is read
@test "works stop -y reaches the flag through the top-level dispatcher" {
    store
    fake_live
    run setsid bash "$REPO/scripts/works" stop -y
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    rc=0; wait "$FAKE_LIVE" 2>/dev/null || rc=$?
    [ "$rc" -gt 128 ]
}

# --- help ---------------------------------------------------------------------

# guards: every help here is a fixed line range over the file's header comment,
# so editing that comment silently drags the prose underneath into the output or
# drops a command off the end. Both read as "the last line is not a command".
@test "runtime help ends on a command, not on prose" {
    run RT --help
    [ "$status" -eq 0 ]
    last="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -1)"
    [[ "$last" == "  works runtime"* ]] \
        || { echo "help trails into prose: $last" >&2; false; }
}

@test "runtime help names every verb it dispatches" {
    run RT --help
    for v in list path use stop; do
        [[ "$output" == *"works runtime $v"* ]] || { echo "help omits $v" >&2; false; }
    done
}

@test "runtime help answers to -h and help as well" {
    run RT -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"works runtime list"* ]]
    run RT help
    [ "$status" -eq 0 ]
    [[ "$output" == *"works runtime list"* ]]
}
