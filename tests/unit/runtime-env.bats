#!/usr/bin/env bats
#
# scripts/runtime-env.sh — the shared runtime and prefix resolution.
#
# Seven scripts resolved these paths independently until this existed. The
# resolvers are pure so they can be tested here rather than through a launcher
# sandbox, which is the whole reason they echo instead of assigning.
#
#   ./tests/run.sh tests/unit/runtime-env.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    setup_stubs
    stub pgrep 1                # runtime_busy's fallback must not read the host
    HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset ABLETON_WINE_ROOT ABLETON_WINEPREFIX
    unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH WINEESYNC WINEFSYNC
    . "$REPO/scripts/runtime-env.sh"
}

@test "runtime root: ABLETON_WINE_ROOT wins, so a bisect or VM run can pin one" {
    ABLETON_WINE_ROOT=/tmp/altroot
    [ "$(ableton_wine_root)" = "/tmp/altroot" ]
}

@test "prefix: defaults to ~/.wine-ableton" {
    [ "$(ableton_wine_prefix)" = "$HOME/.wine-ableton" ]
}

@test "prefix: ABLETON_WINEPREFIX wins, which the clone workflow depends on" {
    ABLETON_WINEPREFIX=/tmp/altpfx
    [ "$(ableton_wine_prefix)" = "/tmp/altpfx" ]
}

@test "root and prefix are independent: overriding one leaves the other alone" {
    ABLETON_WINE_ROOT=/tmp/altroot
    [ "$(ableton_wine_prefix)" = "$HOME/.wine-ableton" ]
    unset ABLETON_WINE_ROOT
    ABLETON_WINEPREFIX=/tmp/altpfx
    [ "$(ableton_wine_root)" = "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]
}

@test "the resolvers are pure: calling them exports and unsets nothing" {
    WINEDLLOVERRIDES=mscoree=n
    ableton_wine_root >/dev/null
    ableton_wine_prefix >/dev/null
    [ "${WINEDLLOVERRIDES:-gone}" = "mscoree=n" ]
    [ -z "${WINEPREFIX:-}" ]
    [ -z "${WINESERVER:-}" ]
}

@test "binding exports the prefix, the server, and the runtime's bin on PATH" {
    ABLETON_WINE_ROOT=/tmp/altroot
    ableton_bind_runtime
    [ "$WINE_ROOT" = "/tmp/altroot" ]
    [ "$WINESERVER" = "/tmp/altroot/bin/wineserver" ]
    [ "${PATH%%:*}" = "/tmp/altroot/bin" ]
    [ "$WINEPREFIX" = "$HOME/.wine-ableton" ]
}

# guards: the four cleared here are the launchers' long-standing set
@test "binding clears inherited Wine settings that would reach the wrong build" {
    WINELOADER=/usr/bin/wine WINEDLLPATH=/usr/lib WINEDLLOVERRIDES=mscoree=n WINEARCH=win32
    ableton_bind_runtime
    for v in WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH; do
        [ -z "${!v:-}" ] || { echo "$v survived binding as '${!v}'" >&2; false; }
    done
}

# guards: setup-prefix.sh clears these two itself; folding them in would drop a
# user's WINEESYNC on every launch, a behaviour change wearing a refactor's clothes
@test "binding leaves the sync backends alone, unlike setup-prefix.sh's own unset" {
    WINEESYNC=1 WINEFSYNC=1
    ableton_bind_runtime
    [ "${WINEESYNC:-}" = "1" ]
    [ "${WINEFSYNC:-}" = "1" ]
}

# --- process detection -------------------------------------------------------
# /proc cannot be stubbed through PATH, so the lib reads ABLETON_PROC_ROOT and
# these build a fixture tree instead of trusting whatever the machine is doing.

fake_proc() {   # fake_proc <pid> <exe-target> [cmdline]
    local d="$ABLETON_PROC_ROOT/$1"
    mkdir -p "$d"
    ln -sfn "$2" "$d/exe"
    [ $# -lt 3 ] || printf '%s\0' "$3" > "$d/cmdline"
}

proc_setup() {
    export ABLETON_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    export ABLETON_WINE_ROOT="$BATS_TEST_TMPDIR/rt"
    mkdir -p "$ABLETON_PROC_ROOT"
}

@test "runtime pids: a process running from the runtime is found" {
    proc_setup
    fake_proc 101 "$ABLETON_WINE_ROOT/bin/wineserver"
    [ "$(ableton_runtime_pids)" = "101" ]
}

# guards: scoping — a Live under an unrelated Wine is neither counted nor killed
@test "runtime pids: a process from another Wine install is ignored" {
    proc_setup
    fake_proc 202 "/usr/lib/wine/wine-preloader" "Ableton Live 12 Suite.exe"
    [ -z "$(ableton_runtime_pids)" ]
}

@test "runtime pids: non-numeric entries in the tree are skipped" {
    proc_setup
    mkdir -p "$ABLETON_PROC_ROOT/self" "$ABLETON_PROC_ROOT/sys"
    ln -sfn "$ABLETON_WINE_ROOT/bin/wine" "$ABLETON_PROC_ROOT/self/exe"
    [ -z "$(ableton_runtime_pids)" ]
}

@test "live pids: Live is told apart from the support processes around it" {
    proc_setup
    fake_proc 101 "$ABLETON_WINE_ROOT/bin/wineserver" "wineserver"
    fake_proc 102 "$ABLETON_WINE_ROOT/bin/wine-preloader" \
        'C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'
    [ "$(ableton_live_pids)" = "102" ]
    ableton_live_running
}

# guards: the launcher's stale-wineserver kill — a lingering server must still
# read as "Live is down", or that kill never runs
@test "a lingering wineserver means busy, but not that Live is running" {
    proc_setup
    fake_proc 101 "$ABLETON_WINE_ROOT/bin/wineserver" "wineserver"
    ableton_runtime_busy
    ! ableton_live_running
}

@test "an idle machine is neither busy nor running Live" {
    proc_setup
    ! ableton_runtime_busy
    ! ableton_live_running
}

# guards: observed during the first real migration — six "/proc/PID/cmdline:
# No such file or directory" lines, because the processes exited between the
# scan and the read. tr's 2>/dev/null cannot suppress that: the shell reports a
# failed redirection itself, before tr runs. Same bug is in install.sh on main.
@test "live pids: a process that exits mid-scan is skipped, not an error" {
    proc_setup
    fake_proc 101 "$ABLETON_WINE_ROOT/bin/wine-preloader"   # exe, but no cmdline
    run ableton_live_pids
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr$output" != *"No such file"* ]]
}

# --- runtime tarball selection -----------------------------------------------
# Shared because it was not: install.sh, make-installer.sh and build-audit.sh
# each carried a copy and the same defect was in all three — a release both
# assembled and audited from whatever sort -V put last.

setup_dist() {
    DIST="$BATS_TEST_TMPDIR/dist"
    mkdir -p "$DIST"
    NAME="$(ableton_runtime_name)"
}

# guards: sort -V orders the -debug suffix last, so glob+tail installs a tree with no share/
@test "the runtime wins over a debug tree sitting beside it" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ "$(basename "$(ableton_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the newest dated runtime wins when several are present" {
    setup_dist; for v in 2026.07.29.1 2026.08.01.1 2026.07.23.1; do : > "$DIST/$NAME-$v.tar.zst"; done
    [ "$(basename "$(ableton_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the same-day counter orders numerically, not lexically" {
    setup_dist; for n in 1 2 10; do : > "$DIST/$NAME-2026.08.01.$n.tar.zst"; done
    [ "$(basename "$(ableton_pick_tarball "$DIST")")" = "$NAME-2026.08.01.10.tar.zst" ]
}

@test "a debug tree on its own selects nothing, so the caller fails loudly" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ -z "$(ableton_pick_tarball "$DIST")" ]
}

# guards: the beta channel — a nightly artifact must never be taken for the stable runtime
@test "an undated or suffixed artifact is not mistaken for the runtime" {
    setup_dist; : > "$DIST/$NAME-nightly.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-rc2.tar.zst"
    [ -z "$(ableton_pick_tarball "$DIST")" ]
}

@test "an empty directory selects nothing rather than erroring" {
    setup_dist; run ableton_pick_tarball "$DIST"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a missing directory selects nothing rather than erroring" {
    setup_dist; run ableton_pick_tarball "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# <dir> holding a BUILD-INFO with the given body, so a test names only the
# fields it cares about. Values are column-padded exactly as the build writes
# them, because the separator the parser has to cope with is the padding.
make_tree() {
    TREE="$BATS_TEST_TMPDIR/tree$RANDOM"
    mkdir -p "$TREE"
    printf '%s\n' "$@" > "$TREE/ABLETON-WINE-BUILD-INFO.txt"
}

# guards: /proc/PID/exe reports resolved paths, so a channel-path root matches no
# process and the busy guard fails open while install.sh renames the directory

# guards: the same resolution a running process reports, so the two can be
# compared at all

# One test is still held back with the version store: the migration's own
# behaviour, in migrate-layout.bats. ableton_wine_root resolves one
# way today because there is only one layout; both tests return when there
# are two.

# New on the integration branch: the predicate the selector and make-installer
# share. Its own tests, because make-installer is the caller that packaging
# defects reach through, and "the selector still works" does not cover it.

# guards: a kit packed around a name the installer cannot select builds cleanly
# and fails on the user's machine — reproduced 2026-08-05
@test "tarball predicate: the dated release form is accepted" {
    ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst"
}

@test "tarball predicate: a full path is judged by its basename" {
    ableton_is_runtime_tarball "/any/where/wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst"
}

# guards: bin/ and lib/ with no share/ — passes `wine --version`, then fails at
# launch with "could not exec the wine loader"
@test "tarball predicate: a debug tree is refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1-debug.tar.zst"
}

# guards: this is the only runtime artifact the nightly channel publishes, so
# refusing it left that channel with nothing installable
@test "tarball predicate: a nightly label is accepted" {
    ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+nightly.bf76bb2.tar.zst"
}

# guards: a label is a suffix on the release form, not a licence to accept any
# trailing text — `-debug` must keep falling out
@test "tarball predicate: a labelled debug tree is still refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+nightly.bf76bb2-debug.tar.zst"
}

@test "tarball predicate: an empty label is refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+.tar.zst"
}

# guards: both in one directory is the nightly builder's own dist/, and the
# labelled build must not become what an unqualified install picks up
@test "tarball selector: the plain release wins over a labelled one beside it" {
    local d="$BATS_TEST_TMPDIR/dist"; mkdir -p "$d"
    local nm; nm="$(ableton_runtime_name)"
    : > "$d/${nm}-2026.08.04.1.tar.zst"
    : > "$d/${nm}-2026.08.04.1+nightly.bf76bb2.tar.zst"
    [ "$(basename "$(ableton_pick_tarball "$d")")" = "${nm}-2026.08.04.1.tar.zst" ]
}

@test "tarball selector: a labelled build alone is selectable" {
    local d="$BATS_TEST_TMPDIR/dist"; mkdir -p "$d"
    local nm; nm="$(ableton_runtime_name)"
    : > "$d/${nm}-2026.08.04.1+nightly.bf76bb2.tar.zst"
    [ -n "$(ableton_pick_tarball "$d")" ]
}

@test "tarball predicate: another Wine base is refused" {
    # Derived, never spelled out. A second Wine version written literally here is
    # a second place the runtime name lives, which repo-hygiene refuses - and
    # rightly: a base bump would leave the literal behind.
    local nm base; nm="$(ableton_runtime_name)"
    base="${nm%.*}.$(( ${nm##*.} + 1 ))"
    ! ableton_is_runtime_tarball "${base}-2026.08.04.1.tar.zst"
}

@test "tarball predicate: an undated artifact is refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-release.tar.zst"
}

# guards: the same-day counter must not be read as a date component
@test "tarball predicate: a partial download is refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst.part"
}

# guards: the value names a symlink and, for the updater, part of a URL —
# configuration the build does not control must not shape a request

# --- how a nightly is named ---------------------------------------------------
# dist-version is the date the build happened, for every build. `nightly` rides
# in the discriminator, so the date is written once and the id keeps its single
# separator. Putting the kind in dist-version instead would need either a second
# date or a second `+`, and the id is <version>+<discriminator>.

id_of() {   # id_of <build-info lines...>
    local d="$BATS_TEST_TMPDIR/rt"; mkdir -p "$d"
    printf '%s\n' "$@" > "$d/ABLETON-WINE-BUILD-INFO.txt"
    ableton_runtime_id "$d"
}

@test "tarball predicate: the nightly artifact name is accepted" {
    ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.06.1+nightly.badafaf.tar.zst"
}

# --- the names this library used to answer to ---------------------------------
# The rename arrives with a migration that moves every path as well; honouring
# the old names for a release means a person adjusts once, not twice. The VM
# harness alone sets ABLETON_WINEPREFIX in seven places.

# guards: someone with both set has already migrated and left the old one in a
# shell profile — the new name is the deliberate one

