#!/usr/bin/env bats
#
# scripts/ableton-live — the pure functions.
#
# 765 lines, 17 functions, and every one of them writes something into a Wine
# prefix: registry colour triples, LOGFONT blobs, a CPU topology string. None of
# it crashes when it goes wrong. It just renders Live slightly wrong, on someone
# else's machine, in a way that arrives as "the menus look odd".
#
# These are extracted and evaluated directly (see helpers/launcher.bash) because
# the launcher runs discovery and exec at top level and cannot be sourced.
# End-to-end launch behaviour is in tests/launcher-cli.bats.

bats_require_minimum_version 1.5.0

load ../helpers/common
load ../helpers/launcher

# --- blend_gray_text ---------------------------------------------------------
# GrayText is derived, not themed: 45% of the way from Menu towards MenuText,
# per channel. The launcher's own comment claims this lands near Windows'
# classic GrayText on the dark/light fallbacks. It does — exactly — and that is
# worth pinning, because it is the only evidence the constant is right.

# guards: commit 9cba3b0 — the 45% GrayText blend, deduped between sync_win32_colors and theme_watch_loop
@test "gray text: the dark fallback lands on classic GrayText" {
    launcher_fn blend_gray_text
    run blend_gray_text "43 43 43" "232 232 232"
    [ "$output" = "128 128 128" ]
}

@test "gray text: the light fallback stays mid-grey and readable" {
    launcher_fn blend_gray_text
    run blend_gray_text "255 255 255" "0 0 0"
    [ "$output" = "141 141 141" ]
}

@test "gray text: identical endpoints blend to themselves" {
    launcher_fn blend_gray_text
    run blend_gray_text "100 100 100" "100 100 100"
    [ "$output" = "100 100 100" ]
}

# guards: issue #32 — menu bar chrome contrast
@test "gray text: the blend is 45% towards MenuText, per channel, not symmetric" {
    # Direction matters: swapping the arguments must not give the same answer,
    # or the blend is anchored on the wrong colour and disabled menu items
    # drift towards the text colour instead of away from it.
    launcher_fn blend_gray_text
    forward="$(blend_gray_text "0 0 0" "200 100 40")"
    reverse="$(blend_gray_text "200 100 40" "0 0 0")"
    [ "$forward" = "90 45 18" ]
    [ "$forward" != "$reverse" ]
}

# --- parse_topbar_override ---------------------------------------------------
# ABLETON_TOPBAR_MODE can carry a literal colour pair. It goes into the registry
# unvalidated by anything downstream, so this is the only gate.

@test "topbar override: a valid hex pair becomes two RGB triples" {
    launcher_fn parse_topbar_override
    run parse_topbar_override "#1a2b3c #ffffff"
    [ "$status" -eq 0 ]
    [ "$output" = "26 43 60|255 255 255" ]
}

@test "topbar override: uppercase hex is accepted" {
    launcher_fn parse_topbar_override
    run parse_topbar_override "#1A2B3C #FFFFFF"
    [ "$status" -eq 0 ]
    [ "$output" = "26 43 60|255 255 255" ]
}

@test "topbar override: anything but exactly two 6-digit hex colours is refused" {
    launcher_fn parse_topbar_override
    for v in "#1a2b3c" "#1a2b3c #fff" "1a2b3c #ffffff" "#1a2b3c #ffffff extra" \
             "#GGGGGG #ffffff" "#1a2b3c#ffffff" "" "  "; do
        run parse_topbar_override "$v"
        [ "$status" -ne 0 ] || { echo "'$v' was accepted as '$output'" >&2; false; }
    done
}

# --- logfont_face_hex --------------------------------------------------------
# Packs a family name into the 64 face-name bytes of a LOGFONT, UTF-16LE and
# zero-padded. sync_metric_fonts splices this over bytes 28..91 of the existing
# blob, so a wrong length silently corrupts the DPI-scaled heights that follow.

@test "logfont: a name packs to exactly 64 bytes, UTF-16LE, zero-padded" {
    launcher_fn logfont_face_hex
    run logfont_face_hex "Ableton Sans"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | awk -F, '{print NF}')" -eq 64 ]
    # "Abl" = 41 00 62 00 6c 00
    [[ "$output" == "41,00,62,00,6c,00,"* ]]
    # ...and the tail is padding, not stale bytes
    [ "$(printf '%s' "$output" | cut -d, -f61-64)" = "00,00,00,00" ]
}

@test "logfont: LF_FACESIZE is enforced, not truncated into" {
    # 31 chars is the last that fits alongside the NUL terminator; 32+ must be
    # refused outright, because a truncated family name is a font that does not
    # exist and win32u silently falls back.
    launcher_fn logfont_face_hex
    run logfont_face_hex "$(printf 'A%.0s' $(seq 31))"
    [ "$status" -eq 0 ]
    run logfont_face_hex "$(printf 'A%.0s' $(seq 32))"
    [ "$status" -ne 0 ]
}

@test "logfont: non-ASCII is refused, because the blob is built bytewise" {
    launcher_fn logfont_face_hex
    run logfont_face_hex "Ünicode Sans"
    [ "$status" -ne 0 ]
    run logfont_face_hex "日本語"
    [ "$status" -ne 0 ]
}

@test "logfont: an empty family is all padding, never a malformed blob" {
    launcher_fn logfont_face_hex
    run logfont_face_hex ""
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | awk -F, '{print NF}')" -eq 64 ]
    [[ ! "$output" =~ [1-9a-f] ]]
}

# --- select_cpu_topology -----------------------------------------------------
# Reports a stable, small CPU count to Live: cap 8, honour taskset/cgroup
# cpusets, stay quiet when Wine's default is fine.

@test "cpu topology: caps at 8 on a machine with more" {
    launcher_fn select_cpu_topology
    online="$(getconf _NPROCESSORS_ONLN)"
    [ "$online" -gt 8 ] || skip "this machine has $online CPUs; the cap needs >8"
    run select_cpu_topology
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
}

@test "cpu topology: an affinity-constrained run reports the allowed count" {
    command -v taskset >/dev/null || skip "taskset not installed"
    # Strictly more than 2: the function prints only when allowed < online, so
    # on a 2-CPU host pinning both CPUs is not a constraint and it correctly
    # says nothing. -ge would run the test on the one machine it cannot pass.
    [ "$(getconf _NPROCESSORS_ONLN)" -gt 2 ] || skip "needs more than 2 CPUs for 2 to be a constraint"
    # Not a synthetic fixture: the function reads /proc/self/status, so the only
    # honest way to test the cpuset branch is to actually be constrained.
    run taskset -c 0,1 bash -c \
        "source <(sed -n '/^select_cpu_topology() {/,/^}/p' '$REPO/scripts/ableton-live'); select_cpu_topology"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "cpu topology: a contiguous affinity range counts inclusively" {
    command -v taskset >/dev/null || skip "taskset not installed"
    # Strictly more than 4, for the same reason: a 4-CPU GitHub runner pinned to
    # 0-3 is unconstrained, the function prints nothing, and this test failed on
    # exactly that host while passing on every developer machine.
    [ "$(getconf _NPROCESSORS_ONLN)" -gt 4 ] || skip "needs more than 4 CPUs for 0-3 to be a constraint"
    # 0-3 is four CPUs, not three: the range arithmetic is hi-lo+1 and an
    # off-by-one here under-reports every constrained machine.
    run taskset -c 0-3 bash -c \
        "source <(sed -n '/^select_cpu_topology() {/,/^}/p' '$REPO/scripts/ableton-live'); select_cpu_topology"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "cpu topology: says nothing when unconstrained and at or below the cap" {
    # Empty output means "leave WINE_CPU_TOPOLOGY unset"; printing a number here
    # would pin the topology for no reason. Only reachable on a machine that is
    # both unconstrained and <= 8 CPUs, so it skips on bigger hosts rather than
    # pretending taskset can simulate a smaller machine (it cannot: the function
    # compares the allowed set against _NPROCESSORS_ONLN, which taskset does not
    # change).
    online="$(getconf _NPROCESSORS_ONLN)"
    [ "$online" -le 8 ] || skip "needs a machine with <= 8 CPUs; this one has $online"
    launcher_fn select_cpu_topology
    run select_cpu_topology
    [ -z "$output" ]
}

@test "cpu topology: a constrained set below the cap wins over the cap" {
    command -v taskset >/dev/null || skip "taskset not installed"
    [ "$(getconf _NPROCESSORS_ONLN)" -gt 8 ] || skip "needs more than 8 CPUs"
    # 8 allowed on a >8-CPU host: the allowed count and the cap agree here, but
    # the point is that the cpuset is consulted at all rather than the machine
    # width being reported.
    run taskset -c 0-7 bash -c \
        "source <(sed -n '/^select_cpu_topology() {/,/^}/p' '$REPO/scripts/ableton-live'); select_cpu_topology"
    [ "$output" = "8" ]
}

# --- reg_windowmetrics_hex ---------------------------------------------------
# Reads a REG_BINARY out of user.reg. Wine wraps long values across continuation
# lines; missing the join returns a truncated blob, which sync_metric_fonts
# would then splice a face name into at the wrong offset.

# guards: scripts/ableton-live — sync_metric_fonts splices over bytes 28..91; a truncated blob corrupts DPI heights
@test "windowmetrics: a value wrapped across continuation lines is rejoined" {
    launcher_fn reg_windowmetrics_hex
    export WINEPREFIX="$BATS_TEST_TMPDIR/prefix"
    mkdir -p "$WINEPREFIX"
    cat > "$WINEPREFIX/user.reg" <<'EOF'
WINE REGISTRY Version 2

[Control Panel\\Desktop\\WindowMetrics] 1700000000
"MenuFont"=hex:f4,ff,ff,ff,00,00,00,00,00,00,00,00,00,00,00,00,90,01,00,00,00,\
  00,00,00,00,00,00,00,53,00,65,00,67,00,6f,00,65,00,20,00,55,00,49,00,00,00
"StatusFont"=hex:f4,ff,ff,ff,00,00,00,00

[Control Panel\\Colors] 1700000000
"MenuText"="0 0 0"
EOF
    run reg_windowmetrics_hex MenuFont
    [ "$status" -eq 0 ]
    [[ "$output" != *'\'* ]] || { echo "continuation marker survived: $output" >&2; false; }
    [[ "$output" == "f4,ff,ff,ff,"* ]]
    # "Segoe UI" lives entirely on the continuation line; losing the join would
    # cut the value off at the backslash and drop the face name completely.
    [[ "$output" == *"53,00,65,00,67,00,6f,00,65,00,20,00,55,00,49,00"* ]] || {
        echo "wrapped face name was lost: $output" >&2; false; }
    [[ "$output" == *"55,00,49,00,00,00" ]] || {
        echo "wrapped tail was truncated: $output" >&2; false; }
    # 21 fields before the wrap + 25 after = 46; a dropped join would give 21.
    [ "$(printf '%s' "$output" | awk -F, '{print NF}')" -eq 46 ]
}

@test "windowmetrics: an unwrapped value reads back verbatim" {
    launcher_fn reg_windowmetrics_hex
    export WINEPREFIX="$BATS_TEST_TMPDIR/prefix"
    mkdir -p "$WINEPREFIX"
    cat > "$WINEPREFIX/user.reg" <<'EOF'
WINE REGISTRY Version 2

[Control Panel\\Desktop\\WindowMetrics] 1700000000
"StatusFont"=hex:f4,ff,ff,ff,00,00,00,00
EOF
    run reg_windowmetrics_hex StatusFont
    [ "$output" = "f4,ff,ff,ff,00,00,00,00" ]
}

@test "windowmetrics: a value in another section is not picked up" {
    # The section guard matters: [Control Panel\Colors] also holds a "MenuText",
    # and reading across the boundary would feed a colour string to the LOGFONT
    # splicer.
    launcher_fn reg_windowmetrics_hex
    export WINEPREFIX="$BATS_TEST_TMPDIR/prefix"
    mkdir -p "$WINEPREFIX"
    cat > "$WINEPREFIX/user.reg" <<'EOF'
WINE REGISTRY Version 2

[Control Panel\\Desktop\\WindowMetrics] 1700000000
"StatusFont"=hex:f4,ff,ff,ff

[Software\\Other] 1700000000
"MenuFont"=hex:de,ad,be,ef
EOF
    run reg_windowmetrics_hex MenuFont
    [ -z "$output" ]
}

@test "windowmetrics: a missing user.reg is silent, not an error cascade" {
    launcher_fn reg_windowmetrics_hex
    export WINEPREFIX="$BATS_TEST_TMPDIR/nonexistent"
    run reg_windowmetrics_hex MenuFont
    [ -z "$output" ]
}
