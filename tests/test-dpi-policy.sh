#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../scripts/dpi-policy.sh"

failures=0
check() {
    local description="$1" expected="$2"
    shift 2
    local actual
    if actual="$("$@")" && [ "$actual" = "$expected" ]; then
        printf 'ok - %s\n' "$description"
    else
        printf 'not ok - %s (expected %s, got %s)\n' "$description" "$expected" "${actual:-<failure>}" >&2
        failures=$((failures + 1))
    fi
}
check_fails() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'not ok - %s (unexpected success)\n' "$description" >&2
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$description"
    fi
}

check 'Hyprland 1.00' 100 ableton_resolve_dpi_policy 1.00 hyprland 1
check 'Hyprland 1.25' native:120 ableton_resolve_dpi_policy 1.25 hyprland 1
check 'Hyprland 1.50' native:144 ableton_resolve_dpi_policy 1.50 hyprland 1
check 'Hyprland 1.666667' native:160 ableton_resolve_dpi_policy 1.666667 hyprland 1
check 'Hyprland normalized 1.67' native:160 ableton_resolve_dpi_policy 1.67 hyprland 1
check 'Hyprland 1.75' native:168 ableton_resolve_dpi_policy 1.75 hyprland 1
check 'Hyprland 2.00' native:192 ableton_resolve_dpi_policy 2.00 hyprland 1
check 'GNOME legacy 1.25' fractional ableton_resolve_dpi_policy 1.25 gnome 0
check 'unknown desktop 1.00' 100 ableton_resolve_dpi_policy 1 unknown 0
check_fails 'Hyprland without zero scaling preserves 1.67' ableton_resolve_dpi_policy 1.67 hyprland 0
check_fails 'unknown desktop preserves 1.67' ableton_resolve_dpi_policy 1.67 unknown 0
check '160 registry DWORD' 000000a0 ableton_dpi_to_dword 160
check '192 registry DWORD' 000000c0 ableton_dpi_to_dword 192
check_fails 'invalid scale is rejected' ableton_scale_to_dpi invalid
check_fails 'invalid DWORD is rejected' ableton_dpi_to_dword 16x

[ "$failures" -eq 0 ]
printf 'PASS: DPI policy tests\n'
