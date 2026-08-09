#!/usr/bin/env bats
#
# scripts/detect-scale.sh — display-scale detection and the scale -> DPI block map.
#
# Two halves, tested differently:
#   * the probes parse compositor output, so they get recorded fixtures and a
#     stubbed binary. Whatever compositor the developer or CI runner is on has
#     no bearing on the result.
#   * the block map is pure arithmetic, so it gets an exhaustive table. That
#     table is the calibration contract: changing a cell should be a deliberate
#     act with a test diff to justify it, not a silent consequence.

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    setup_stubs
    clear_session_env
    # No probe answers by accident: every probe binary is present but mute
    # until a test says otherwise.
    for c in gdbus kscreen-doctor swaymsg hyprctl cosmic-randr xrdb; do stub "$c" 1; done
    # shellcheck source=/dev/null
    . "$REPO/scripts/detect-scale.sh"
}

# --- block map: the calibration table ----------------------------------------
# GNOME/mutter hands XWayland an integer-upscaled framebuffer (matched set:
# LogPixels 96*ceil(scale) + the dpiAwareness IFEO); everyone else hands X11 an
# unscaled one and expects application-side scaling (plain round(96*scale), no
# IFEO). Regressing either column silently mis-scales Live's whole UI.

# guards: scripts/detect-scale.sh DPI policy — mutter hands XWayland an integer-upscaled framebuffer
@test "block map: gnome scales collapse onto the ceil-based matched set" {
    while read -r scale want; do
        run ableton_dpi_block_for_scale "$scale" gnome
        [ "$status" -eq 0 ]
        [ "$output" = "$want" ] || {
            echo "gnome scale $scale: want $want, got $output" >&2; false; }
    done <<'TABLE'
1        100
1.0      100
1.25     fractional
1.5      fractional
1.75     fractional
2        fractional
2.25     fractional288
2.5      fractional288
TABLE
}

# guards: scripts/detect-scale.sh DPI policy — every other compositor expects application-side scaling
@test "block map: non-gnome scales round to plain LogPixels with no IFEO" {
    while read -r scale want; do
        run ableton_dpi_block_for_scale "$scale" kde
        [ "$status" -eq 0 ]
        [ "$output" = "$want" ] || {
            echo "kde scale $scale: want $want, got $output" >&2; false; }
    done <<'TABLE'
1        100
1.25     dpi120
1.5      dpi144
1.75     dpi168
2        dpi192
2.5      dpi240
TABLE
}

@test "block map: scales outside 100-250% are refused, not clamped" {
    for scale in 0.5 0.99 2.51 3 4; do
        run ableton_dpi_block_for_scale "$scale" kde
        [ "$status" -ne 0 ] || { echo "scale $scale was accepted: $output" >&2; false; }
    done
}

@test "block map: non-numeric scales are refused" {
    for scale in "" abc 1.2.3 -1 "1 " 1e0 "1;rm"; do
        run ableton_dpi_block_for_scale "$scale" kde
        [ "$status" -ne 0 ] || { echo "'$scale' was accepted: $output" >&2; false; }
    done
}

@test "block values: every block the map can emit decodes to LogPixels + IFEO" {
    while read -r block lp ifeo; do
        run ableton_dpi_block_values "$block"
        [ "$status" -eq 0 ]
        [ "$output" = "$lp $ifeo" ] || {
            echo "block $block: want '$lp $ifeo', got '$output'" >&2; false; }
    done <<'TABLE'
100             96   -
fractional      192  2
dpi120          120  -
dpi144          144  -
dpi240          240  -
fractional288   288  2
TABLE
}

@test "block values: LogPixels outside the validated 72..384 window is refused" {
    for block in dpi71 dpi385 fractional385 dpi0 dpi bogus "" "dpi1x"; do
        run ableton_dpi_block_values "$block"
        [ "$status" -ne 0 ] || { echo "'$block' was accepted: $output" >&2; false; }
    done
}

@test "block map round-trips: for_scale output is always a valid block" {
    for scale in 1 1.25 1.5 1.75 2 2.25 2.5; do
        for family in gnome kde sway hyprland cosmic xft; do
            block="$(ableton_dpi_block_for_scale "$scale" "$family")"
            run ableton_dpi_block_values "$block"
            [ "$status" -eq 0 ] || {
                echo "$family $scale -> '$block' does not decode" >&2; false; }
        done
    done
}

# --- probes: parsers, against recorded compositor output ---------------------

# guards: commit f0fc05e — cosmic-randr reports a Scale for a disabled output; older COSMIC emits no primary line
@test "cosmic probe: a disabled lid never wins, even with no primary line" {
    # Regression for f0fc05e. Older cosmic-randr emits no "Xwayland primary"
    # line, so the fallback picks the first block with a scale — which must
    # skip the disabled internal panel and land on the external monitor.
    stub cosmic-randr 0 "$FIXTURES/cosmic-randr/lid-closed-no-primary.txt"
    XDG_CURRENT_DESKTOP=COSMIC run _ads_cosmic
    [ "$status" -eq 0 ]
    [ "$output" = "1.25" ]
}

# guards: commit f0fc05e — the fallback loop did not check enabled state at all
@test "cosmic probe: a disabled lid never wins when it is marked non-primary" {
    stub cosmic-randr 0 "$FIXTURES/cosmic-randr/lid-closed-with-primary.txt"
    XDG_CURRENT_DESKTOP=COSMIC run _ads_cosmic
    [ "$status" -eq 0 ]
    [ "$output" = "1.5" ]
}

@test "cosmic probe: picks the Xwayland primary out of three enabled monitors" {
    stub cosmic-randr 0 "$FIXTURES/cosmic-randr/three-monitor.txt"
    XDG_CURRENT_DESKTOP=COSMIC run _ads_cosmic
    [ "$status" -eq 0 ]
    [ "$output" = "1.25" ]
}

@test "cosmic probe: declines when the desktop is not COSMIC" {
    stub cosmic-randr 0 "$FIXTURES/cosmic-randr/three-monitor.txt"
    XDG_CURRENT_DESKTOP=GNOME run _ads_cosmic
    [ "$status" -ne 0 ]
}

@test "kde probe: Plasma 6 'priority 1' selects the primary output" {
    stub kscreen-doctor 0 "$FIXTURES/kscreen-doctor/plasma6-dual.txt"
    run _ads_kde
    [ "$status" -eq 0 ]
    [ "$output" = "1.25" ]
}

@test "kde probe: Plasma 5 'primary' keyword selects the primary output" {
    stub kscreen-doctor 0 "$FIXTURES/kscreen-doctor/plasma5-dual.txt"
    run _ads_kde
    [ "$status" -eq 0 ]
    [ "$output" = "1.25" ]
}

@test "gnome probe: reads the primary logical monitor, not the first" {
    # eDP-1 (2.0) is listed first and is NOT primary; DP-2 (1.25) is. Taking
    # the first row would scale Live's whole UI to the wrong monitor.
    stub gdbus 0 "$FIXTURES/gdbus/primary-not-first.txt"
    run --separate-stderr _ads_gnome
    [ "$status" -eq 0 ]
    [ "$output" = "1.25" ]
}

@test "gnome probe: warns on stderr when monitors run mixed scales" {
    stub gdbus 0 "$FIXTURES/gdbus/mixed-scales.txt"
    run --separate-stderr _ads_gnome
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"mixed scales"* ]]
}

@test "xft probe: Xft.dpi becomes a scale" {
    printf 'Xft.dpi:\t120\n*background:\t#000000\n' > "$BATS_TEST_TMPDIR/xrdb.txt"
    stub xrdb 0 "$BATS_TEST_TMPDIR/xrdb.txt"
    DISPLAY=:0 run _ads_xft
    [ "$status" -eq 0 ]
    [ "$output" = "1.25" ]
}

# --- probe ordering ----------------------------------------------------------

@test "detect_scale: returns non-zero when no probe answers" {
    run ableton_detect_scale
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "detect_scale_ex: names the probe family that answered" {
    stub kscreen-doctor 0 "$FIXTURES/kscreen-doctor/plasma6-dual.txt"
    run ableton_detect_scale_ex
    [ "$status" -eq 0 ]
    [ "$output" = "1.25 kde" ]
}

@test "detect_scale_ex: gnome outranks a lower-priority probe" {
    # Both answer; mutter's reply must win, because the family decides the DPI
    # policy and mis-attributing GNOME to 'kde' drops the required IFEO.
    stub gdbus 0 "$FIXTURES/gdbus/primary-not-first.txt"
    stub kscreen-doctor 0 "$FIXTURES/kscreen-doctor/plasma6-dual.txt"
    run --separate-stderr ableton_detect_scale_ex
    [ "$status" -eq 0 ]
    [ "$output" = "1.25 gnome" ]
}

@test "detect_scale: normalises trailing zeros" {
    printf 'Xft.dpi:\t96\n' > "$BATS_TEST_TMPDIR/xrdb.txt"
    stub xrdb 0 "$BATS_TEST_TMPDIR/xrdb.txt"
    DISPLAY=:0 run ableton_detect_scale
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}
