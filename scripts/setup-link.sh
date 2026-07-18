#!/usr/bin/env bash
# Optional Ableton Link setup: host multicast networking (Option A) plus the
# native jack_link bridge (Option B). Idempotent — safe to re-run.
# Does not install the bridge itself; the build procedure and the systemd
# unit live in notes/ABLETON-WINE-LINK.md.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

if pgrep -f "Ableton Live.*\.exe" >/dev/null 2>&1; then
    echo "!! Live is running — close it before changing Link networking" >&2
    exit 1
fi

echo "== [1/3] primary LAN interface =="
# Link speaks UDP multicast (group 224.76.78.75, port 20808) and does not
# work over VPN — the multicast route must land on the physical LAN device
# carrying the default route, never on a tunnel.
iface="$(ip -4 route show default | awk '/^default/ {for (i=1; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
if [ -z "$iface" ]; then
    echo "!! no IPv4 default route found — connect to your LAN and re-run" >&2
    exit 1
fi
case "$iface" in
    tun*|wg*|tap*)
        echo "!! the default route is a VPN interface ($iface); Link needs a physical LAN interface" >&2
        echo "!! disconnect the VPN (or give the LAN default route priority) and re-run" >&2
        exit 1 ;;
esac
echo "   primary LAN interface: $iface"

echo "== [2/3] Option A: multicast route + firewall allowance =="
# Many kernels ship no route for 224.0.0.0/4, so multicast traffic from Wine
# apps never leaves the host. 'append' with errors suppressed keeps re-runs
# idempotent (an existing identical route just fails silently).
sudo ip route append 224.0.0.0/4 dev "$iface" metric 0 2>/dev/null || true
echo "   multicast route 224.0.0.0/4 via $iface (not persistent — see the dispatcher hook in notes/ABLETON-WINE-LINK.md)"
if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 20808/udp
elif command -v firewall-cmd >/dev/null 2>&1; then
    sudo firewall-cmd --permanent --add-port=20808/udp
    sudo firewall-cmd --reload
else
    echo "   no ufw/firewalld found — skipping; if you run another firewall, allow UDP 20808 yourself"
fi

echo "== [3/3] Option B: jack_link bridge =="
# The bridge software is not installed by this script; a missing binary or
# unit exits early with guidance rather than failing inside systemctl.
command -v jack_link >/dev/null 2>&1 || {
    echo "!! jack_link not found — build and install it per notes/ABLETON-WINE-LINK.md, then re-run" >&2
    exit 1
}
unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/jack-link.service"
[ -f "$unit" ] || {
    echo "!! $unit missing — create it per notes/ABLETON-WINE-LINK.md, then re-run" >&2
    exit 1
}
systemctl --user daemon-reload
systemctl --user enable --now jack-link.service

echo
echo "OK: Link networking via $iface; jack-link.service enabled"
echo "Verify with the checklist in $root/notes/ABLETON-WINE-LINK.md"
