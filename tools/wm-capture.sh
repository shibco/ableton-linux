#!/usr/bin/env bash
# Capture the host-side window state needed to classify a stuck, missing,
# or misbehaving window (for example a Trial window that will not close):
#   tools/wm-capture.sh [outdir]
#
# Records, for every managed X client: geometry, map/viewable and
# override-redirect state, WM_CLASS/WM_NAME, WM_TRANSIENT_FOR, group
# leader, _NET_WM_WINDOW_TYPE, _MOTIF_WM_HINTS, WM_STATE, _NET_WM_STATE
# and _NET_WM_DESKTOP - plus the root window's active-window/desktop
# state, the window manager's identity, monitor layout, and the complete
# window tree (which also lists override-redirect windows the client
# list omits). Run it WHILE the problem is on screen.
#
# Pair it with the Wine-side transition trace (patch 0090), which lands
# in ~/.log/ableton-wine/live.log:
#   env ABLETON_WM_TRACE=1 ableton-live

set -uo pipefail

OUT="${1:-$PWD/wm-capture-$(date +%Y%m%dT%H%M%S)}"

command -v xprop >/dev/null || { echo "!! xprop not found (install xorg-xprop)"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "!! DISPLAY is not set (X11/XWayland session required)"; exit 1; }
# Capture what the installed tools allow: xprop alone still records every
# property. xwininfo adds geometry/map state and the full window tree.
HAVE_XWININFO=1
command -v xwininfo >/dev/null || { HAVE_XWININFO=0; echo "!! xwininfo not found (install xorg-xwininfo); capturing properties only"; }

mkdir -p "$OUT/windows" || exit 1
echo "==> output: $OUT"

# --- session environment ------------------------------------------------------
{
    echo "date: $(date -Is)"
    echo "DISPLAY=$DISPLAY"
    echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
    echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-}"
    echo "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-}"
    # Under a Wayland compositor without a built-in XWayland WM, note the
    # xwayland-satellite version: 0.8.2 misclassifies some transient dialogs
    # as popups (xwayland-satellite issue 470).
    if command -v xwayland-satellite >/dev/null; then
        echo "xwayland-satellite: $(xwayland-satellite --version 2>&1 | head -1)"
    fi
    pgrep -a -f 'xwayland-satellite|Xwayland' 2>/dev/null | sed 's/^/proc: /'
} > "$OUT/env.txt"

command -v xrandr >/dev/null && xrandr --query > "$OUT/monitors.txt" 2>&1

# --- root window: WM identity, active window, desktops, supported hints -------
{
    xprop -root _NET_SUPPORTING_WM_CHECK _NET_ACTIVE_WINDOW _NET_CURRENT_DESKTOP \
                _NET_NUMBER_OF_DESKTOPS _NET_CLIENT_LIST _NET_CLIENT_LIST_STACKING
    wmwin="$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -o '0x[0-9a-f]*' | head -1)"
    [ -n "$wmwin" ] && { echo "--- WM check window $wmwin ---"; xprop -id "$wmwin" _NET_WM_NAME; }
    echo "--- _NET_SUPPORTED ---"
    xprop -root -notype _NET_SUPPORTED
} > "$OUT/root.txt" 2>&1

# --- complete tree (includes override-redirect windows) -----------------------
[ "$HAVE_XWININFO" = 1 ] && xwininfo -root -tree > "$OUT/tree.txt" 2>&1

# --- per-window detail for every managed client -------------------------------
ids="$(xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -o '0x[0-9a-f]*')"
count=0
for id in $ids; do
    {
        echo "=== $id ==="
        [ "$HAVE_XWININFO" = 1 ] && xwininfo -id "$id" -stats -wm
        echo "--- properties ---"
        xprop -id "$id"
    } > "$OUT/windows/$id.txt" 2>&1
    count=$((count + 1))
done
echo "==> captured $count managed windows, root state, and the window tree"
echo "==> attach the whole directory to the report: $OUT"
