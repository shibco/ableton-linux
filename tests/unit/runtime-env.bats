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
    unset WORKS_RUNTIME WORKS_PLUG
    unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH WINEESYNC WINEFSYNC
    . "$REPO/scripts/runtime-env.sh"
}

@test "runtime root: an unmigrated install still resolves where it actually is" {
    [ "$(works_runtime_path)" = "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]
}

@test "runtime root: WORKS_RUNTIME wins, so a bisect or VM run can pin one" {
    WORKS_RUNTIME=/tmp/altroot
    [ "$(works_runtime_path)" = "/tmp/altroot" ]
}

@test "prefix: defaults to ~/works/plugs/studio" {
    [ "$(works_plug_path)" = "$HOME/works/plugs/studio" ]
}

# guards: found in review. install.sh hands this to `wineserver -k` *before*
# works_migrate_plug runs, so on an unmigrated machine works_plug_path names a
# directory that does not exist yet while the real prefix is still at the legacy
# path. Stopping the wrong prefix is a no-op that reports success, and the
# SIGKILL that follows is the registry corruption the migration exists to avoid.
@test "live prefix: names the legacy path while the destination is absent" {
    mkdir -p "$HOME/.wine-ableton"
    [ "$(works_plug_path_live)" = "$HOME/.wine-ableton" ]
}

@test "live prefix: names the container path once that exists" {
    mkdir -p "$HOME/.wine-ableton" "$HOME/works/plugs/studio"
    [ "$(works_plug_path_live)" = "$HOME/works/plugs/studio" ]
}

@test "live prefix: with neither present it still names where the prefix will go" {
    [ "$(works_plug_path_live)" = "$HOME/works/plugs/studio" ]
}

# guards: the stop was gated on works_runtime_busy, which resolves /proc/PID/exe
# under the runtime tree — strictly narrower than the environ match
# works_migrate_plug guards with. A process that inherited WINEPREFIX without
# executing from the runtime (ableton-linkd is exactly that) was invisible to the
# kill and visible to the guard, so the install stopped cleanly and then refused,
# and no number of reruns cleared it.
@test "busy: a prefix holder that never executed from the runtime is still seen" {
    local plug="$HOME/works/plugs/studio" pid i narrow wide
    mkdir -p "$plug"
    WINEPREFIX="$plug" sleep 30 &
    pid=$!
    for i in $(seq 1 40); do [ -e "/proc/$pid/environ" ] && break; sleep 0.05; done

    run works_runtime_busy
    narrow="$status"
    run works_anything_busy
    wide="$status"
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    [ "$narrow" -ne 0 ] || { echo "the runtime scan should not have matched it" >&2; false; }
    [ "$wide" -eq 0 ] || { echo "the union scan missed the prefix holder" >&2; false; }
}

@test "prefix: WORKS_PLUG wins, which the clone workflow depends on" {
    WORKS_PLUG=/tmp/altpfx
    [ "$(works_plug_path)" = "/tmp/altpfx" ]
}

@test "root and prefix are independent: overriding one leaves the other alone" {
    WORKS_RUNTIME=/tmp/altroot
    [ "$(works_plug_path)" = "$HOME/works/plugs/studio" ]
    unset WORKS_RUNTIME
    WORKS_PLUG=/tmp/altpfx
    [ "$(works_runtime_path)" = "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]
}

@test "the resolvers are pure: calling them exports and unsets nothing" {
    WINEDLLOVERRIDES=mscoree=n
    works_runtime_path >/dev/null
    works_plug_path >/dev/null
    [ "${WINEDLLOVERRIDES:-gone}" = "mscoree=n" ]
    [ -z "${WINEPREFIX:-}" ]
    [ -z "${WINESERVER:-}" ]
}

@test "binding exports the prefix, the server, and the runtime's bin on PATH" {
    WORKS_RUNTIME=/tmp/altroot
    works_bind_runtime
    [ "$WINE_ROOT" = "/tmp/altroot" ]
    [ "$WINESERVER" = "/tmp/altroot/bin/wineserver" ]
    [ "${PATH%%:*}" = "/tmp/altroot/bin" ]
    [ "$WINEPREFIX" = "$HOME/works/plugs/studio" ]
}

# guards: the four cleared here are the launchers' long-standing set
@test "binding clears inherited Wine settings that would reach the wrong build" {
    WINELOADER=/usr/bin/wine WINEDLLPATH=/usr/lib WINEDLLOVERRIDES=mscoree=n WINEARCH=win32
    works_bind_runtime
    for v in WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH; do
        [ -z "${!v:-}" ] || { echo "$v survived binding as '${!v}'" >&2; false; }
    done
}

# guards: setup-prefix.sh clears these two itself; folding them in would drop a
# user's WINEESYNC on every launch, a behaviour change wearing a refactor's clothes
@test "binding leaves the sync backends alone, unlike setup-prefix.sh's own unset" {
    WINEESYNC=1 WINEFSYNC=1
    works_bind_runtime
    [ "${WINEESYNC:-}" = "1" ]
    [ "${WINEFSYNC:-}" = "1" ]
}

# --- process detection -------------------------------------------------------
# /proc cannot be stubbed through PATH, so the lib reads WORKS_PROC_ROOT and
# these build a fixture tree instead of trusting whatever the machine is doing.

fake_proc() {   # fake_proc <pid> <exe-target> [cmdline]
    local d="$WORKS_PROC_ROOT/$1"
    mkdir -p "$d"
    ln -sfn "$2" "$d/exe"
    [ $# -lt 3 ] || printf '%s\0' "$3" > "$d/cmdline"
}

proc_setup() {
    export WORKS_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    export WORKS_RUNTIME="$BATS_TEST_TMPDIR/rt"
    mkdir -p "$WORKS_PROC_ROOT"
}

@test "runtime pids: a process running from the runtime is found" {
    proc_setup
    fake_proc 101 "$WORKS_RUNTIME/bin/wineserver"
    [ "$(works_runtime_pids)" = "101" ]
}

# guards: scoping — a Live under an unrelated Wine is neither counted nor killed
@test "runtime pids: a process from another Wine install is ignored" {
    proc_setup
    fake_proc 202 "/usr/lib/wine/wine-preloader" "Ableton Live 12 Suite.exe"
    [ -z "$(works_runtime_pids)" ]
}

@test "runtime pids: non-numeric entries in the tree are skipped" {
    proc_setup
    mkdir -p "$WORKS_PROC_ROOT/self" "$WORKS_PROC_ROOT/sys"
    ln -sfn "$WORKS_RUNTIME/bin/wine" "$WORKS_PROC_ROOT/self/exe"
    [ -z "$(works_runtime_pids)" ]
}

@test "live pids: Live is told apart from the support processes around it" {
    proc_setup
    fake_proc 101 "$WORKS_RUNTIME/bin/wineserver" "wineserver"
    fake_proc 102 "$WORKS_RUNTIME/bin/wine-preloader" \
        'C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'
    [ "$(ableton_live_pids)" = "102" ]
    ableton_live_running
}

# guards: the launcher's stale-wineserver kill — a lingering server must still
# read as "Live is down", or that kill never runs
@test "a lingering wineserver means busy, but not that Live is running" {
    proc_setup
    fake_proc 101 "$WORKS_RUNTIME/bin/wineserver" "wineserver"
    works_runtime_busy
    ! ableton_live_running
}

@test "an idle machine is neither busy nor running Live" {
    proc_setup
    ! works_runtime_busy
    ! ableton_live_running
}

# --- container vs legacy resolution ------------------------------------------
# The layout migration moves the runtime into a container directory. The
# resolver has to answer correctly on both sides of that move, because an
# install that has not migrated yet still has to launch.

@test "runtime root: an explicit pin beats the container" {
    export WORKS_HOME="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$WORKS_HOME/runtimes/stable"
    WORKS_RUNTIME=/tmp/pinned
    [ "$(works_runtime_path)" = "/tmp/pinned" ]
}

# guards: observed during the first real migration — six "/proc/PID/cmdline:
# No such file or directory" lines, because the processes exited between the
# scan and the read. tr's 2>/dev/null cannot suppress that: the shell reports a
# failed redirection itself, before tr runs. Same bug is in install.sh on main.
@test "live pids: a process that exits mid-scan is skipped, not an error" {
    proc_setup
    fake_proc 101 "$WORKS_RUNTIME/bin/wine-preloader"   # exe, but no cmdline
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
    NAME="$(works_runtime_name)"
}

# guards: sort -V orders the -debug suffix last, so glob+tail installs a tree with no share/
@test "the runtime wins over a debug tree sitting beside it" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ "$(basename "$(works_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the newest dated runtime wins when several are present" {
    setup_dist; for v in 2026.07.29.1 2026.08.01.1 2026.07.23.1; do : > "$DIST/$NAME-$v.tar.zst"; done
    [ "$(basename "$(works_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the same-day counter orders numerically, not lexically" {
    setup_dist; for n in 1 2 10; do : > "$DIST/$NAME-2026.08.01.$n.tar.zst"; done
    [ "$(basename "$(works_pick_tarball "$DIST")")" = "$NAME-2026.08.01.10.tar.zst" ]
}

@test "a debug tree on its own selects nothing, so the caller fails loudly" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ -z "$(works_pick_tarball "$DIST")" ]
}

# guards: the beta channel — a nightly artifact must never be taken for the stable runtime
@test "an undated or suffixed artifact is not mistaken for the runtime" {
    setup_dist; : > "$DIST/$NAME-nightly.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-rc2.tar.zst"
    [ -z "$(works_pick_tarball "$DIST")" ]
}

@test "an empty directory selects nothing rather than erroring" {
    setup_dist; run works_pick_tarball "$DIST"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a missing directory selects nothing rather than erroring" {
    setup_dist; run works_pick_tarball "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- naming an installed runtime ---------------------------------------------

# <dir> holding a BUILD-INFO with the given body, so a test names only the
# fields it cares about. Values are column-padded exactly as the build writes
# them, because the separator the parser has to cope with is the padding.
make_tree() {
    TREE="$BATS_TEST_TMPDIR/tree$RANDOM"
    mkdir -p "$TREE"
    printf '%s\n' "$@" > "$TREE/ABLETON-WINE-BUILD-INFO.txt"
}

# guards: no released runtime carries source-commit — measured across all 11 trees on the dev machine 2026-08-04
@test "a runtime without source-commit is named from its patch stack" {
    make_tree 'dist-version: 2026.08.04.1' \
              'patch-stack:  9e48edd6b39579d6bd70e73ab1a049d50d7e972a'
    [ "$(works_runtime_id "$TREE")" = "2026.08.04.1+9e48edd" ]
}

@test "source-commit is preferred over the patch stack when both are present" {
    make_tree 'dist-version: 2026.08.04.1' \
              'source-commit: 7193ece0f1a2b3c4' \
              'patch-stack:  9e48edd6b39579d6'
    [ "$(works_runtime_id "$TREE")" = "2026.08.04.1+7193ece" ]
}

# guards: 2026.07.29.1 appears four times on the dev machine under two patch stacks
@test "two builds of one version under different patch stacks get different ids" {
    make_tree 'dist-version: 2026.07.29.1' 'patch-stack:  237e53c65485761f'
    a="$(works_runtime_id "$TREE")"
    make_tree 'dist-version: 2026.07.29.1' 'patch-stack:  9614003b3a6394c2'
    [ "$a" != "$(works_runtime_id "$TREE")" ]
}

@test "the same build named twice collapses to one id, so duplicates merge" {
    make_tree 'dist-version: 2026.07.29.1' 'patch-stack:  237e53c65485761f'
    a="$(works_runtime_id "$TREE")"
    make_tree 'dist-version: 2026.07.29.1' 'patch-stack:  237e53c65485761f'
    [ "$a" = "$(works_runtime_id "$TREE")" ]
}

@test "a tree with no BUILD-INFO cannot be named, and says so by echoing nothing" {
    run works_runtime_id "$BATS_TEST_TMPDIR/absent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a version with no discriminator at all cannot be named" {
    make_tree 'dist-version: 2026.08.04.1'
    [ -z "$(works_runtime_id "$TREE")" ]
}

@test "a discriminator with no version cannot be named" {
    make_tree 'patch-stack:  9e48edd6b39579d6'
    [ -z "$(works_runtime_id "$TREE")" ]
}

# guards: the id becomes a directory name, and a BUILD-INFO is just text in a tarball
@test "a BUILD-INFO carrying path traversal is refused, not turned into a path" {
    make_tree 'dist-version: ../../../etc' 'patch-stack:  9e48edd6b39579d6'
    [ -z "$(works_runtime_id "$TREE")" ]
}

@test "a BUILD-INFO carrying a slash is refused" {
    make_tree 'dist-version: 2026.08.04.1' 'patch-stack:  9e48/edd6b39579d6'
    [ -z "$(works_runtime_id "$TREE")" ]
}

# --- resolution across the two layouts ---------------------------------------
# The store moves the runtime into a container with a channel symlink at the
# live build. The resolver has to answer on both sides of that move, because an
# install that has not migrated yet still has to launch.

# guards: an install that predates the migration must still resolve and launch
@test "runtime root: falls back to the legacy path before migrating" {
    export WORKS_HOME="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$WORKS_HOME"
    [ "$(works_runtime_path)" = "$(works_legacy_root)" ]
}

# guards: /proc/PID/exe reports resolved paths, so a channel-path root matches no
# process and the busy guard fails open while install.sh renames the directory

# guards: the same resolution a running process reports, so the two can be
# compared at all
@test "runtime root: matches what /proc would report for a process under it" {
    export WORKS_HOME="$BATS_TEST_TMPDIR/opt"
    entry="$WORKS_HOME/runtimes/2026.08.05.1+abc1234"
    mkdir -p "$entry/bin"
    : > "$entry/bin/wine"
    ln -s "2026.08.05.1+abc1234" "$WORKS_HOME/runtimes/stable"
    # what the kernel would show for a binary launched through the channel
    resolved="$(readlink -f "$WORKS_HOME/runtimes/stable/bin/wine")"
    case "$resolved" in
        "$(works_runtime_path)"/*) ;;
        *) echo "$resolved does not sit under $(works_runtime_path)" >&2; false ;;
    esac
}

# guards: the container winning over a stale legacy tree left beside it
@test "runtime root: the container wins over a legacy tree still present" {
    export WORKS_HOME="$BATS_TEST_TMPDIR/opt"
    entry="$WORKS_HOME/runtimes/2026.08.05.1+abc1234"
    mkdir -p "$entry" "$(works_legacy_root)"
    ln -s "2026.08.05.1+abc1234" "$WORKS_HOME/runtimes/stable"
    [ "$(works_runtime_path)" = "$entry" ]
}

# One test is still held back with the version store: the migration's own
# behaviour, in migrate-layout.bats. works_runtime_path resolves one
# way today because there is only one layout; both tests return when there
# are two.

# New on the integration branch: the predicate the selector and make-installer
# share. Its own tests, because make-installer is the caller that packaging
# defects reach through, and "the selector still works" does not cover it.

# guards: a kit packed around a name the installer cannot select builds cleanly
# and fails on the user's machine — reproduced 2026-08-05
@test "tarball predicate: the dated release form is accepted" {
    works_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst"
}

@test "tarball predicate: a full path is judged by its basename" {
    works_is_runtime_tarball "/any/where/wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst"
}

# guards: bin/ and lib/ with no share/ — passes `wine --version`, then fails at
# launch with "could not exec the wine loader"
@test "tarball predicate: a debug tree is refused" {
    ! works_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1-debug.tar.zst"
}

# guards: this is the only runtime artifact the nightly channel publishes, so
# refusing it left that channel with nothing installable
@test "tarball predicate: a nightly label is accepted" {
    works_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+nightly.bf76bb2.tar.zst"
}

# guards: a label is a suffix on the release form, not a licence to accept any
# trailing text — `-debug` must keep falling out
@test "tarball predicate: a labelled debug tree is still refused" {
    ! works_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+nightly.bf76bb2-debug.tar.zst"
}

@test "tarball predicate: an empty label is refused" {
    ! works_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+.tar.zst"
}

# guards: both in one directory is the nightly builder's own dist/, and the
# labelled build must not become what an unqualified install picks up
@test "tarball selector: the plain release wins over a labelled one beside it" {
    local d="$BATS_TEST_TMPDIR/dist"; mkdir -p "$d"
    local nm; nm="$(works_runtime_name)"
    : > "$d/${nm}-2026.08.04.1.tar.zst"
    : > "$d/${nm}-2026.08.04.1+nightly.bf76bb2.tar.zst"
    [ "$(basename "$(works_pick_tarball "$d")")" = "${nm}-2026.08.04.1.tar.zst" ]
}

@test "tarball selector: a labelled build alone is selectable" {
    local d="$BATS_TEST_TMPDIR/dist"; mkdir -p "$d"
    local nm; nm="$(works_runtime_name)"
    : > "$d/${nm}-2026.08.04.1+nightly.bf76bb2.tar.zst"
    [ -n "$(works_pick_tarball "$d")" ]
}

@test "tarball predicate: another Wine base is refused" {
    # Derived, never spelled out. A second Wine version written literally here is
    # a second place the runtime name lives, which repo-hygiene refuses - and
    # rightly: a base bump would leave the literal behind.
    local nm base; nm="$(works_runtime_name)"
    base="${nm%.*}.$(( ${nm##*.} + 1 ))"
    ! works_is_runtime_tarball "${base}-2026.08.04.1.tar.zst"
}

@test "tarball predicate: an undated artifact is refused" {
    ! works_is_runtime_tarball "wine-d2d1-nspa-11.13-release.tar.zst"
}

# guards: the same-day counter must not be read as a date component
@test "tarball predicate: a partial download is refused" {
    ! works_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst.part"
}

# --- channels -----------------------------------------------------------------
# One channel was assumed throughout: `stable` was hardcoded in six places and
# retention protected only that one. A second channel needs both generalised.

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
    works_runtime_id "$d"
}

@test "runtime id: a nightly says so, once, after the date" {
    [ "$(id_of 'dist-version: 2026.08.06.1' 'source-commit: badafaf995572b26' 'build-kind:   nightly')" \
      = "2026.08.06.1+nightly.badafaf" ]
}

@test "runtime id: a release carries no kind at all" {
    [ "$(id_of 'dist-version: 2026.08.04.1' 'source-commit: b0d847af6fcc7ab9')" \
      = "2026.08.04.1+b0d847a" ]
}

# guards: every runtime installed anywhere today predates source-commit
@test "runtime id: the patch-stack fallback still works with a kind" {
    [ "$(id_of 'dist-version: 2026.07.29.1' 'patch-stack:  9614003aabb' 'build-kind:   nightly')" \
      = "2026.07.29.1+nightly.9614003" ]
}

# guards: build-kind becomes a directory name like everything else in the id
@test "runtime id: a kind with a path separator is refused, not sanitised" {
    [ -z "$(id_of 'dist-version: 2026.08.06.1' 'source-commit: badafaf9' 'build-kind:   ../evil')" ]
}

@test "tarball predicate: the nightly artifact name is accepted" {
    works_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.06.1+nightly.badafaf.tar.zst"
}

# --- the names this library used to answer to ---------------------------------
# The rename arrives with a migration that moves every path as well; honouring
# the old names for a release means a person adjusts once, not twice. The VM
# harness alone sets WORKS_PLUG in seven places.

# guards: someone with both set has already migrated and left the old one in a
# shell profile — the new name is the deliberate one

