# Sourceable display-DPI policy resolution. This file does not mutate a Wine
# prefix: it converts a detected display scale and compositor strategy into a
# calibrated block consumed by setup-prefix.sh and ableton-live.

ableton_scale_to_dpi() {
    awk -v scale="$1" 'BEGIN {
        if (scale !~ /^[0-9]+([.][0-9]+)?$/ || scale <= 0) exit 1
        printf "%d\n", int((scale * 96) + 0.5)
    }'
}

ableton_dpi_to_dword() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -gt 0 ] || return 1
    printf '%08x\n' "$1"
}

ableton_desktop_kind() {
    local desktop
    desktop="${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-${DESKTOP_SESSION:-}}}"
    desktop="$(printf '%s' "$desktop" | tr '[:upper:]' '[:lower:]')"
    case "$desktop" in
        *hyprland*|*omarchy*) echo hyprland ;;
        *gnome*|*mutter*)     echo gnome ;;
        *kde*|*plasma*)       echo kde ;;
        *sway*)               echo sway ;;
        *)
            if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
                echo hyprland
            else
                echo unknown
            fi ;;
    esac
}

ableton_hyprland_force_zero_scaling() {
    command -v hyprctl >/dev/null 2>&1 || return 1
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 1
    local out
    out="$(timeout 5 hyprctl getoption xwayland:force_zero_scaling -j 2>/dev/null)" || return 1
    printf '%s\n' "$out" | grep -Eq '"int"[[:space:]]*:[[:space:]]*1([^0-9]|$)'
}

# Print one calibrated block:
#   100          -> LogPixels 96, no IFEO
#   fractional   -> legacy Mutter policy: LogPixels 192, IFEO=2
#   native:<dpi> -> application-side scaling at the exact compositor DPI,
#                   no IFEO
# Return 1 when the compositor/XWayland strategy is not calibrated.
# Optional desktop and zero-scaling arguments make the resolver pure in tests.
ableton_resolve_dpi_policy() {
    local scale="$1" desktop="${2:-}" zero_scaling="${3:-}" dpi
    dpi="$(ableton_scale_to_dpi "$scale")" || return 1
    [ -n "$desktop" ] || desktop="$(ableton_desktop_kind)"

    if [ "$desktop" = hyprland ]; then
        if [ -z "$zero_scaling" ]; then
            if ableton_hyprland_force_zero_scaling; then
                zero_scaling=1
            else
                zero_scaling=0
            fi
        fi
        if [ "$zero_scaling" = 1 ]; then
            if [ "$dpi" -eq 96 ]; then
                echo 100
            else
                echo "native:$dpi"
            fi
            return 0
        fi
    fi

    case "$dpi" in
        96)  echo 100 ;;
        120) echo fractional ;;
        *)   return 1 ;;
    esac
}
