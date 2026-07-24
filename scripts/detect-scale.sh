# Sourceable display-scale detection. ableton_detect_scale prints the primary monitor's scale
# ("1", "1.25", ...) or returns 1 when no probe answers (probes: GNOME, KDE, sway, Hyprland,
# niri, COSMIC, Xft.dpi). ableton_detect_scale_ex also prints which probe answered (the compositor
# family), and ableton_dpi_block_for_scale / ableton_dpi_block_values map a detected scale to
# the calibrated DPI block for that family (see the mapping comment at the bottom).

_ads_gnome() {
    local state rows all prim
    state="$(timeout 5 gdbus call --session \
        --dest org.gnome.Mutter.DisplayConfig \
        --object-path /org/gnome/Mutter/DisplayConfig \
        --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null)" || return 1
    # logical monitors serialise as "(x, y, scale, uint32 transform, primary, ..."
    rows="$(printf '%s\n' "$state" \
        | grep -oE '\(-?[0-9]+, -?[0-9]+, [0-9]+(\.[0-9]+)?, uint32 [0-9]+, (true|false)')"
    [ -n "$rows" ] || return 1
    all="$(printf '%s\n' "$rows" | awk -F', ' '{print $3}' | sort -u)"
    prim="$(printf '%s\n' "$rows" | awk -F', ' '$5=="true"{print $3; exit}')"
    [ -n "$prim" ] || prim="$(printf '%s\n' "$rows" | awk -F', ' 'NR==1{print $3}')"
    if [ "$(printf '%s\n' "$all" | wc -l)" -gt 1 ]; then
        echo "note: monitors run mixed scales ($(printf '%s' "$all" | tr '\n' ' ' )): using the primary monitor's $prim" >&2
    fi
    printf '%s\n' "$prim"
}

_ads_kde() {
    command -v kscreen-doctor >/dev/null 2>&1 || return 1
    local out prim
    out="$(timeout 5 kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
    [ -n "$out" ] || return 1
    # Plasma 5: one "Output: ..." line per screen with "primary"; Plasma 6 splits blocks, marks "priority 1".
    prim="$(printf '%s\n' "$out" | awk '
        /^Output:/ { blk++ }
        blk {
            if (match($0, /Scale: [0-9.]+/)) s[blk] = substr($0, RSTART+7, RLENGTH-7)
            if ($0 ~ / primary/ || $0 ~ /priority 1([^0-9]|$)/) p[blk] = 1
        }
        END {
            for (i = 1; i <= blk; i++) if (p[i] && s[i] != "") { print s[i]; exit }
            for (i = 1; i <= blk; i++) if (s[i] != "")          { print s[i]; exit }
        }')"
    [ -n "$prim" ] || return 1
    printf '%s\n' "$prim"
}

_ads_sway() {
    command -v swaymsg >/dev/null 2>&1 || return 1
    [ -n "${SWAYSOCK:-}" ] || return 1
    local s
    s="$(timeout 5 swaymsg -t get_outputs 2>/dev/null \
        | grep -oE '"scale": *[0-9.]+' | head -1 | grep -oE '[0-9.]+')"
    [ -n "$s" ] || return 1
    printf '%s\n' "$s"
}

_ads_hyprland() {
    command -v hyprctl >/dev/null 2>&1 || return 1
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 1
    local s
    s="$(timeout 5 hyprctl monitors 2>/dev/null \
        | grep -oE 'scale: [0-9.]+' | head -1 | grep -oE '[0-9.]+')"
    [ -n "$s" ] || return 1
    printf '%s\n' "$s"
}

_ads_niri() {
    command -v niri >/dev/null 2>&1 || return 1
    [ -n "${NIRI_SOCKET:-}" ] || return 1
    local s
    # No "primary" concept in niri: use the focused output, fall back to the first.
    s="$(timeout 5 niri msg focused-output 2>/dev/null \
        | grep -oE 'Scale: [0-9.]+' | head -1 | grep -oE '[0-9.]+')"
    [ -n "$s" ] || s="$(timeout 5 niri msg outputs 2>/dev/null \
        | grep -oE 'Scale: [0-9.]+' | head -1 | grep -oE '[0-9.]+')"
    [ -n "$s" ] || return 1
    printf '%s\n' "$s"
}

_ads_cosmic() {
    command -v cosmic-randr >/dev/null 2>&1 || return 1
    [ "${XDG_CURRENT_DESKTOP:-}" = COSMIC ] || return 1
    local out prim
    out="$(timeout 5 cosmic-randr list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
    [ -n "$out" ] || return 1
    # One "<output> (enabled|disabled)" block per monitor. Disabled outputs (e.g. a
    # closed laptop lid) can still report a Scale, so they're excluded entirely -
    # never picked as primary, never as the fallback (older COSMIC has no primary line).
    prim="$(printf '%s\n' "$out" | awk '
        /^[A-Za-z0-9_-]+ \(/ { blk++; en[blk] = ($0 ~ /\(enabled\)/) }
        blk && en[blk] {
            if (match($0, /Scale: [0-9]+%/)) s[blk] = substr($0, RSTART+7, RLENGTH-8)
            if ($0 ~ /Xwayland primary: true/) p = blk
        }
        END {
            if (p && (p in s)) { print s[p]; exit }
            for (i = 1; i <= blk; i++) if (en[i] && (i in s)) { print s[i]; exit }
        }')"
    [ -n "$prim" ] || return 1
    awk -v s="$prim" 'BEGIN { printf "%g\n", s/100 }'
}

_ads_xft() {
    [ -n "${DISPLAY:-}" ] || return 1
    command -v xrdb >/dev/null 2>&1 || return 1
    local dpi
    dpi="$(timeout 5 xrdb -query 2>/dev/null | awk '$1=="Xft.dpi:"{print $2; exit}')"
    [ -n "$dpi" ] || return 1
    awk -v d="$dpi" 'BEGIN{ printf "%g\n", d/96 }'
}

ableton_detect_scale() {
    local scale
    for probe in _ads_gnome _ads_kde _ads_sway _ads_hyprland _ads_niri _ads_cosmic _ads_xft; do
        if scale="$($probe)"; then
            # normalize: 1.0 -> 1, 1.250 -> 1.25
            printf '%s\n' "$scale" | awk '{ printf "%g\n", $1 }'
            return 0
        fi
    done
    return 1
}

# Like ableton_detect_scale, but prints "<scale> <family>": the family names the probe
# that answered (gnome|kde|sway|hyprland|niri|cosmic|xft) and picks the DPI policy below.
ableton_detect_scale_ex() {
    local scale family
    for family in gnome kde sway hyprland niri cosmic xft; do
        if scale="$("_ads_$family")"; then
            awk -v s="$scale" -v f="$family" 'BEGIN { printf "%g %s\n", s, f }'
            return 0
        fi
    done
    return 1
}

# A detected scale maps to a DPI block by compositor family. GNOME/mutter hands XWayland
# an integer-upscaled framebuffer, so it needs the matched set (LogPixels = 96 x ceil(scale)
# plus IFEO dpiAwareness=2); every other probed compositor hands X11 clients an unscaled
# framebuffer and expects application-side scaling: plain LogPixels = round(96 x scale),
# no IFEO. Block tokens: 100 (LogPixels 96, no IFEO), fractional (192, IFEO=2),
# dpi<N> (N, no IFEO), fractional<N> (N, IFEO=2). Scales outside 100-250% are refused.
# COSMIC is bucketed with the generic (non-GNOME) group: confirmed at 125% scale that
# xrandr reports the monitor's native mode unscaled, not an upscaled framebuffer — COSMIC
# expects application-side scaling, like sway/Hyprland/KDE, not mutter's model.
ableton_dpi_block_for_scale() {  # scale family -> block token
    local scale="$1" family="${2:-}" lp ceil
    case "$scale" in
        ""|*[!0-9.]*|*.*.*) return 1 ;;   # numeric scales only
    esac
    lp="$(awk -v s="$scale" 'BEGIN {
        if (s + 0 < 1 || s + 0 > 2.5) exit 1
        printf "%d", 96*s + 0.5
    }')" || return 1
    if [ "$family" = gnome ]; then
        ceil="$(awk -v s="$scale" 'BEGIN { c = int(s); print (s > c) ? c + 1 : c }')"
        if [ "$ceil" -gt 1 ]; then
            lp=$((96 * ceil))
            if [ "$lp" -eq 192 ]; then printf 'fractional\n'; else printf 'fractional%s\n' "$lp"; fi
        else
            printf '100\n'
        fi
        return 0
    fi
    if [ "$lp" -eq 96 ]; then printf '100\n'; else printf 'dpi%s\n' "$lp"; fi
}

ableton_dpi_block_values() {  # block token -> "<LogPixels> <ifeo>" (ifeo: 2 or -)
    local n ifeo=-
    case "$1" in
        100)              n=96 ;;
        fractional)       n=192; ifeo=2 ;;
        dpi[0-9]*)        n="${1#dpi}" ;;
        fractional[0-9]*) n="${1#fractional}"; ifeo=2 ;;
        *) return 1 ;;
    esac
    case "$n" in ""|*[!0-9]*) return 1 ;; esac
    n=$((10#$n))
    # the validated LogPixels window is 72..384
    [ "$n" -ge 72 ] && [ "$n" -le 384 ] || return 1
    printf '%s %s\n' "$n" "$ifeo"
}
