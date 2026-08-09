#!/usr/bin/env bats
#
# scripts/detect-theme.sh — host light/dark detection, titlebar colours, and
# resolving which Ableton .ask theme Live is actually rendering with.
#
# Everything here feeds the win32 [Control Panel\Colors] registry values the
# launcher writes. A wrong value is not a crash: it is Live shipping with
# unreadable chrome, which is exactly the kind of thing that reaches users.

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    setup_stubs
    clear_session_env
    for c in gdbus gsettings; do stub "$c" 1; done
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    mkdir -p "$XDG_CONFIG_HOME"
    # shellcheck source=/dev/null
    . "$REPO/scripts/detect-theme.sh"
}

# --- scheme detection --------------------------------------------------------

@test "portal probe: color-scheme 1 is dark, 2 and 0 are light" {
    for pair in "1 dark" "2 light" "0 light"; do
        set -- $pair
        printf "(<<uint32 %s>>,)\n" "$1" > "$BATS_TEST_TMPDIR/portal.txt"
        stub gdbus 0 "$BATS_TEST_TMPDIR/portal.txt"
        run _adt_portal
        [ "$status" -eq 0 ]
        [ "$output" = "$2" ] || { echo "color-scheme $1: want $2, got $output" >&2; false; }
    done
}

@test "gsettings probe: prefer-dark is dark, default and prefer-light are light" {
    for pair in "'prefer-dark' dark" "'prefer-light' light" "'default' light"; do
        set -- $pair
        printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/gs.txt"
        stub gsettings 0 "$BATS_TEST_TMPDIR/gs.txt"
        run _adt_gsettings
        [ "$status" -eq 0 ]
        [ "$output" = "$2" ] || { echo "$1: want $2, got $output" >&2; false; }
    done
}

@test "gsettings probe: an unrecognised scheme declines rather than guessing" {
    printf "'martian'\n" > "$BATS_TEST_TMPDIR/gs.txt"
    stub gsettings 0 "$BATS_TEST_TMPDIR/gs.txt"
    run _adt_gsettings
    [ "$status" -ne 0 ]
}

@test "detect_theme: the portal outranks gsettings" {
    printf '(<<uint32 1>>,)\n' > "$BATS_TEST_TMPDIR/portal.txt"
    printf "'prefer-light'\n" > "$BATS_TEST_TMPDIR/gs.txt"
    stub gdbus 0 "$BATS_TEST_TMPDIR/portal.txt"
    stub gsettings 0 "$BATS_TEST_TMPDIR/gs.txt"
    run ableton_detect_theme
    [ "$status" -eq 0 ]
    [ "$output" = dark ]
}

@test "detect_theme: returns non-zero when no probe answers" {
    run ableton_detect_theme
    [ "$status" -ne 0 ]
}

# --- colour parsing ----------------------------------------------------------
# These values land in the registry as raw win32 colour triples. A malformed
# kdeglobals entry must be rejected, never passed through.

@test "rgb parse: accepts three 0-255 components" {
    run _adt_rgb "255,255,255"; [ "$status" -eq 0 ]; [ "$output" = "255 255 255" ]
    run _adt_rgb "0,0,0";       [ "$status" -eq 0 ]; [ "$output" = "0 0 0" ]
    run _adt_rgb "35,38,41";    [ "$status" -eq 0 ]; [ "$output" = "35 38 41" ]
}

@test "rgb parse: rejects out-of-range, short, long and non-numeric input" {
    for v in "256,0,0" "1,2" "1,2,3,4" "" "a,b,c" " 1,2,3" "-1,0,0" "1,2,3 " "1.5,2,3"; do
        run _adt_rgb "$v"
        [ "$status" -ne 0 ] || { echo "'$v' was accepted as $output" >&2; false; }
    done
}

@test "kde colours: prefers the Plasma 5.25+ Header set over legacy [WM]" {
    cat > "$XDG_CONFIG_HOME/kdeglobals" <<'EOF'
[Colors:Header]
BackgroundNormal=35,38,41
ForegroundNormal=252,252,252

[WM]
activeBackground=99,99,99
activeForeground=1,1,1
EOF
    run _adtc_kde
    [ "$status" -eq 0 ]
    [ "$output" = "35 38 41|252 252 252" ]
}

@test "kde colours: falls back to [WM] when Header is absent" {
    cat > "$XDG_CONFIG_HOME/kdeglobals" <<'EOF'
[WM]
activeBackground=99,99,99
activeForeground=1,1,1
EOF
    run _adtc_kde
    [ "$status" -eq 0 ]
    [ "$output" = "99 99 99|1 1 1" ]
}

@test "kde colours: a malformed Header set falls through to [WM], not garbage" {
    cat > "$XDG_CONFIG_HOME/kdeglobals" <<'EOF'
[Colors:Header]
BackgroundNormal=not,a,colour
ForegroundNormal=252,252,252

[WM]
activeBackground=99,99,99
activeForeground=1,1,1
EOF
    run _adtc_kde
    [ "$status" -eq 0 ]
    [ "$output" = "99 99 99|1 1 1" ]
}

@test "kde colours: declines with no kdeglobals at all" {
    run _adtc_kde
    [ "$status" -ne 0 ]
}

@test "topbar colours: non-KDE hosts get the per-scheme constants" {
    run ableton_detect_topbar_colors dark
    [ "$status" -eq 0 ]; [ "$output" = "48 48 48|255 255 255" ]
    run ableton_detect_topbar_colors light
    [ "$status" -eq 0 ]; [ "$output" = "255 255 255|51 51 51" ]
    run ableton_detect_topbar_colors sideways
    [ "$status" -ne 0 ]
}

# --- .ask theme parsing ------------------------------------------------------

@test "ask colour: reads 6-digit and 8-digit (alpha) hex, ignoring the alpha byte" {
    cat > "$BATS_TEST_TMPDIR/t.ask" <<'EOF'
<Ableton>
  <ControlForeground Value="#a1b2c3" />
  <SurfaceBackground Value="#11223344" />
  <Malformed Value="#xyz" />
</Ableton>
EOF
    run ableton_ask_color "$BATS_TEST_TMPDIR/t.ask" ControlForeground
    [ "$status" -eq 0 ]; [ "$output" = "161 178 195" ]
    run ableton_ask_color "$BATS_TEST_TMPDIR/t.ask" SurfaceBackground
    [ "$status" -eq 0 ]; [ "$output" = "17 34 51" ]
}

@test "ask colour: a malformed value or missing key fails, never prints a partial triple" {
    cat > "$BATS_TEST_TMPDIR/t.ask" <<'EOF'
<Ableton><Malformed Value="#xyz" /></Ableton>
EOF
    run ableton_ask_color "$BATS_TEST_TMPDIR/t.ask" Malformed
    [ "$status" -ne 0 ]; [ -z "$output" ]
    run ableton_ask_color "$BATS_TEST_TMPDIR/t.ask" NotThere
    [ "$status" -ne 0 ]; [ -z "$output" ]
    run ableton_ask_color "$BATS_TEST_TMPDIR/no-such-file.ask" ControlForeground
    [ "$status" -ne 0 ]; [ -z "$output" ]
}

# --- prefs directory resolution ---------------------------------------------
# The bug this guards is documented at length in detect-theme.sh: `sort -V`
# ranks "Live 12.4/Preferences" AFTER "Live 12.4.3/Preferences", because the
# strings diverge into '/' (0x2F) vs '.' (0x2E) and strverscmp byte-compares
# there. That silently read a dead prefs dir every time. Resolution is by
# Preferences.cfg mtime instead — this test pins that, and would fail again
# the moment anyone "simplifies" it back to a version sort.

mkprefs() {   # <prefix> <live-dir-name> <mtime>
    local d="$1/drive_c/users/tester/AppData/Roaming/Ableton/$2/Preferences"
    mkdir -p "$d"
    printf 'stub\n' > "$d/Preferences.cfg"
    touch -d "$3" "$d/Preferences.cfg"
    printf '%s\n' "$d"
}

# guards: scripts/detect-theme.sh — sort -V ranks 'Live 12.4/' after 'Live 12.4.3/' ('/' 0x2F > '.' 0x2E)
@test "newest prefs dir: mtime wins, not a version sort" {
    p="$BATS_TEST_TMPDIR/prefix"
    mkprefs "$p" "Live 12.4"   "2026-01-01 00:00:00" >/dev/null
    want="$(mkprefs "$p" "Live 12.4.3" "2026-07-01 00:00:00")"
    run ableton_newest_prefs_dir "$p" 12
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
}

# guards: scripts/detect-theme.sh — same trap, asserted directly so the reason outlives the comment
@test "newest prefs dir: the sort -V trap case, stated explicitly" {
    # Under `ls | sort -V | tail -1` the answer here is "Live 12.4" — wrong.
    # Under mtime it is "Live 12.4.3". Assert the shape of the bug directly so
    # the reason for the test survives even if the comment does not.
    p="$BATS_TEST_TMPDIR/prefix"
    mkprefs "$p" "Live 12.4"   "2026-01-01 00:00:00" >/dev/null
    mkprefs "$p" "Live 12.4.3" "2026-07-01 00:00:00" >/dev/null
    versort="$(printf '%s\n' "$p"/drive_c/users/*/AppData/Roaming/Ableton/Live*/Preferences | sort -V | tail -1)"
    [[ "$versort" == *"Live 12.4/Preferences" ]]   # the trap is still live in sort -V
    run ableton_newest_prefs_dir "$p" 12
    [[ "$output" == *"Live 12.4.3/Preferences" ]]  # ...and the helper does not fall into it
}

@test "newest prefs dir: a directory without Preferences.cfg is skipped" {
    p="$BATS_TEST_TMPDIR/prefix"
    mkdir -p "$p/drive_c/users/tester/AppData/Roaming/Ableton/Live 12.9/Preferences"
    want="$(mkprefs "$p" "Live 12.1" "2026-01-01 00:00:00")"
    run ableton_newest_prefs_dir "$p" 12
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
}

@test "newest prefs dir: the major-version filter excludes other Live majors" {
    p="$BATS_TEST_TMPDIR/prefix"
    mkprefs "$p" "Live 11.3"  "2026-07-01 00:00:00" >/dev/null
    want="$(mkprefs "$p" "Live 12.1" "2026-01-01 00:00:00")"
    run ableton_newest_prefs_dir "$p" 12
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
}

@test "newest prefs dir: prints nothing for a prefix with no Live at all" {
    p="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$p/drive_c/users/tester"
    run ableton_newest_prefs_dir "$p" 12
    [ -z "$output" ]
}

# --- theme file resolution ---------------------------------------------------

@test "live theme file: falls back to the follow-system default per scheme" {
    p="$BATS_TEST_TMPDIR/prefix"; mkdir -p "$p"
    themes="$BATS_TEST_TMPDIR/themes"; mkdir -p "$themes"
    : > "$themes/Default Dark Neutral Medium.ask"
    : > "$themes/Default Light Neutral Medium.ask"
    run ableton_live_theme_file "$p" "$themes" 12 dark
    [ "$status" -eq 0 ]; [ "$output" = "$themes/Default Dark Neutral Medium.ask" ]
    run ableton_live_theme_file "$p" "$themes" 12 light
    [ "$status" -eq 0 ]; [ "$output" = "$themes/Default Light Neutral Medium.ask" ]
}

@test "live theme file: fails when the fallback .ask is not installed either" {
    p="$BATS_TEST_TMPDIR/prefix"; mkdir -p "$p"
    themes="$BATS_TEST_TMPDIR/empty-themes"; mkdir -p "$themes"
    run ableton_live_theme_file "$p" "$themes" 12 dark
    [ "$status" -ne 0 ]
}

@test "live theme file: a theme named in Preferences.cfg beats the default" {
    p="$BATS_TEST_TMPDIR/prefix"
    themes="$BATS_TEST_TMPDIR/themes"; mkdir -p "$themes"
    : > "$themes/Default Dark Neutral Medium.ask"
    : > "$themes/Midnight.ask"
    d="$p/drive_c/users/tester/AppData/Roaming/Ableton/Live 12.4/Preferences"
    mkdir -p "$d"
    # Preferences.cfg is binary with UTF-16LE strings in it; that is what
    # `strings -e l` recovers and what the resolver greps for.
    printf 'Midnight' | iconv -f UTF-8 -t UTF-16LE > "$d/Preferences.cfg"
    run ableton_live_theme_file "$p" "$themes" 12 dark
    [ "$status" -eq 0 ]
    [ "$output" = "$themes/Midnight.ask" ]
}
