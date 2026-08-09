#!/usr/bin/env bats
#
# scripts/ableton-live — the launch contract, end to end.
#
# The launcher runs for real here: discovery, the single-instance lock, registry
# sync, argument routing, right up to the exec. What it would have exec'd is
# captured instead of run, because ABLETON_WINE_ROOT points at a fake runtime
# tree whose `wine` logs its argv and exits (see helpers/launcher.bash).
#
# This is the half that users actually experience — which Live starts, what
# happens with two installed, what a double-clicked .als does — and none of it
# was covered by anything before.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/launcher

setup() {
    setup_stubs
    launcher_sandbox
}

# --- discovery ---------------------------------------------------------------

@test "no Live installed: exits 1 and says how to install one" {
    run_launcher
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"no Ableton Live installation found"* ]]
    [[ "$stderr" == *"$PREFIX"* ]]
    [[ "$stderr" == *"ableton-wine-setup"* ]]
}

@test "one install: launches it as a C: path with backslashes" {
    install_live 12 Suite
    run_launcher
    [ "$status" -eq 0 ]
    [ "$(launched)" = 'C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe' ]
}

@test "two majors: the newest wins, and the choice is announced" {
    install_live 11 Suite
    install_live 12 Suite
    run_launcher
    [ "$status" -eq 0 ]
    [[ "$(launched)" == *"Ableton Live 12 Suite.exe" ]]
    [[ "$stderr" == *"2 Live installs"* ]]
    [[ "$stderr" == *"ABLETON_LIVE_VERSION"* ]]
}

@test "two editions of one major: refuses to guess and lists them" {
    # Deliberate: picking Suite over Standard by sort order would silently start
    # the wrong product for anyone who has both.
    install_live 12 Standard
    install_live 12 Suite
    run_launcher
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"refusing to guess"* ]]
    [[ "$stderr" == *"Ableton Live 12 Standard.exe"* ]]
    [[ "$stderr" == *"Ableton Live 12 Suite.exe"* ]]
    [[ "$stderr" == *"ABLETON_LIVE_EXE"* ]]
    [ ! -s "$WINE_LOG" ] || [[ "$(launched)" != *".exe" ]]
}

@test "ABLETON_LIVE_VERSION pins a major" {
    install_live 11 Suite
    install_live 12 Suite
    ABLETON_LIVE_VERSION=11 run_launcher
    [ "$status" -eq 0 ]
    [[ "$(launched)" == *"Ableton Live 11 Suite.exe" ]]
}

@test "ABLETON_LIVE_VERSION with no matching install names the majors present" {
    install_live 12 Suite
    ABLETON_LIVE_VERSION=11 run_launcher
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"no Live 11 install found"* ]]
    [[ "$stderr" == *"prefix holds other majors"* ]]
    [[ "$stderr" == *"Ableton Live 12 Suite.exe"* ]]
}

@test "ABLETON_LIVE_VERSION must be a number" {
    install_live 12 Suite
    ABLETON_LIVE_VERSION=twelve run_launcher
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"must be a major version number"* ]]
}

@test "ABLETON_LIVE_EXE pins an exact install and silences the ambiguity refusal" {
    install_live 12 Standard
    exe="$(install_live 12 Suite)"
    ABLETON_LIVE_EXE="$exe" run_launcher
    [ "$status" -eq 0 ]
    [[ "$(launched)" == *"Ableton Live 12 Suite.exe" ]]
    [[ "$stderr" != *"refusing to guess"* ]]
}

# --- argument routing --------------------------------------------------------
# Issue #38: a Live document handed to start.exe is read as a switch. Sets,
# clips and packs have no association inside the prefix, so they go straight to
# the Live exe as a windows path; everything else keeps the start.exe route.

# guards: issue #38 — start.exe reads a bare unix path as a switch
@test "a .als set goes straight to the Live exe, never through start.exe" {
    install_live 12 Suite
    doc="$BATS_TEST_TMPDIR/My Song.als"; : > "$doc"
    run_launcher "$doc"
    [ "$status" -eq 0 ]
    [[ "$(launched)" == *"Ableton Live 12 Suite.exe Z:"* ]]
    [[ "$(launched)" != *"start"* ]]
}

# guards: issue #38 — .alc and .alp share the .als routing
@test "clips and packs route the same way as sets, case-insensitively" {
    install_live 12 Suite
    for name in "Clip.alc" "Pack.ALP" "Set.AlS"; do
        launcher_sandbox
        install_live 12 Suite
        doc="$BATS_TEST_TMPDIR/$name"; : > "$doc"
        run_launcher "$doc"
        [ "$status" -eq 0 ]
        [[ "$(launched)" != *"start"* ]] || {
            echo "$name went through start.exe: $(launched)" >&2; false; }
    done
}

@test "a non-Live file keeps the start.exe /unix route" {
    install_live 12 Suite
    f="$BATS_TEST_TMPDIR/notes.txt"; : > "$f"
    run_launcher "$f"
    [ "$status" -eq 0 ]
    [[ "$(launched)" == "start /w /unix $f" ]]
}

@test "an ableton:// URL goes to start.exe verbatim" {
    install_live 12 Suite
    run_launcher "ableton://authorize?token=abc"
    [ "$status" -eq 0 ]
    [ "$(launched)" = "start /w ableton://authorize?token=abc" ]
}

@test "ABLETON_VDESK wraps the launch in a virtual desktop" {
    install_live 12 Suite
    ABLETON_VDESK=2560x1600 run_launcher
    [ "$status" -eq 0 ]
    [[ "$(launched)" == "explorer /desktop=AbletonLive,2560x1600 C:\\ProgramData"* ]]
}

@test "a URL with no Live installed is still handed to start.exe" {
    # require_live guards the bare launch, the virtual desktop and the document
    # path, but deliberately not this one: an ableton:// authorisation URL is
    # routed by start.exe inside the prefix, which is meaningful even before a
    # Live install exists. Pinned because it looks like a missing guard.
    run_launcher "ableton://authorize?token=abc"
    [ "$status" -eq 0 ]
    [ "$(launched)" = "start /w ableton://authorize?token=abc" ]
    [[ "$stderr" != *"no Ableton Live installation found"* ]]
}

# --- single-instance guard ---------------------------------------------------

@test "a second launcher refuses while the first is bringing Live up" {
    install_live 12 Suite
    # Hold the prefix's launch lock the way an in-flight launcher would.
    exec 8>"$PREFIX/.ableton-live.lock"
    flock -n 8 || skip "could not take the launch lock"
    run_launcher
    exec 8>&-
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"another launcher is bringing Live up"* ]]
}

# The launcher drops fd 9 (`exec 9>&-`) before the exec so a wineserver spawned
# during bring-up cannot pin the lock for the whole session. That is deliberately
# NOT tested here: run_launcher runs the launcher as a subprocess, so the kernel
# closes fd 9 on exit whatever the script did, and any test written this way
# passes with the release deleted outright. Catching a real leak needs a fake
# wine that forks a child holding its fds, and then checks the lock while that
# child is still alive.

# --- scheduling --------------------------------------------------------------

@test "realtime scheduling wraps the launch in chrt when rtprio is available" {
    install_live 12 Suite
    cat > "$STUB_DIR/chrt" <<EOF
#!/bin/sh
printf 'CHRT %s\n' "\$*" >> "$WINE_LOG"
shift 2
exec "\$@"
EOF
    chmod +x "$STUB_DIR/chrt"
    ABLETON_RT=on run_launcher
    [ "$status" -eq 0 ]
    grep -q '^CHRT -r 10 wine C:' "$WINE_LOG" || {
        echo "chrt did not wrap the launch:" >&2; cat "$WINE_LOG" >&2; false; }
}

@test "ABLETON_RT=off launches without chrt even when it would succeed" {
    install_live 12 Suite
    cat > "$STUB_DIR/chrt" <<EOF
#!/bin/sh
printf 'CHRT %s\n' "\$*" >> "$WINE_LOG"
shift 2
exec "\$@"
EOF
    chmod +x "$STUB_DIR/chrt"
    ABLETON_RT=off run_launcher
    [ "$status" -eq 0 ]
    ! grep -q '^CHRT' "$WINE_LOG"
}

# --- prefix bring-up ---------------------------------------------------------

# guards: scripts/ableton-live — reg.exe skips the wineboot wait; the FontSubstitutes HKLM write was lost this way
@test "a stale wineserver is killed and the session booted before registry writes" {
    # Ordering is load-bearing: reg.exe does not wait for the wineboot event, so
    # a write racing an async session boot can be dropped (the FontSubstitutes
    # sync lost its HKLM write exactly this way).
    install_live 12 Suite
    run_launcher
    [ "$status" -eq 0 ]
    kill_line="$(grep -n '^-k$' "$WINE_LOG" | head -1 | cut -d: -f1)"
    boot_line="$(grep -n '^wineboot$' "$WINE_LOG" | head -1 | cut -d: -f1)"
    [ -n "$kill_line" ] || { echo "no wineserver -k in the log" >&2; cat "$WINE_LOG" >&2; false; }
    [ -n "$boot_line" ] || { echo "no wineboot in the log" >&2; cat "$WINE_LOG" >&2; false; }
    [ "$kill_line" -lt "$boot_line" ]
}

@test "the launcher never leaves the fake runtime for the host's wine" {
    # PATH is prepended with $WINE_ROOT/bin; if any call escaped to a host wine
    # the log would be short. Every wine invocation should be accounted for.
    install_live 12 Suite
    run_launcher
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$WINE_LOG")" -ge 3 ]
    [[ "$(launched)" == 'C:\'* ]]
}
