#!/usr/bin/env bash
# Remove what install.sh added. The Wine prefix (~/.wine-ableton) is kept unless you pass --prefix.
set -euo pipefail
OPT="$HOME/.local/opt/wine-d2d1-nspa-11.13"
BIN="$HOME/.local/bin/ableton-live"
APPS="$HOME/.local/share/applications"

rm -rf "$OPT"        && echo "removed $OPT"
for d in "$OPT"-rollback-* "$OPT".failed-*; do
    [ -e "$d" ] || continue     # unmatched glob stays literal; skip, don't abort
    rm -rf "$d" && echo "removed $d"
done
rm -f  "$BIN"        && echo "removed $BIN"
rm -f  "$BIN".rollback-*
# Stop and drop the Ableton Link session anchor's user unit (setup-link.sh
# installs it under ~/.config); the daemon binary goes with share/ableton-wine.
systemctl --user disable --now ableton-linkd.service 2>/dev/null || true
rm -f  "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ableton-linkd.service" \
    && echo "removed ~/.config/systemd/user/ableton-linkd.service"
systemctl --user daemon-reload 2>/dev/null || true
rm -rf "$HOME/.local/share/ableton-wine" && echo "removed ~/.local/share/ableton-wine"
rm -f  "$APPS/ableton-live.desktop" "$APPS/wine-protocol-ableton.desktop" "$APPS/wine-extension-auz.desktop"
rm -f  "$APPS/max9.desktop" "$APPS/wine-protocol-c74max.desktop" "$HOME/.local/bin/max9"
rm -f  "$HOME/.local/share/mime/packages/x-wine-extension-auz.xml"
rm -f  "$HOME/.local/share/mime/packages/application-ableton-live.xml"
ICONS="$HOME/.local/share/icons/hicolor"
rm -f  "$ICONS"/scalable/apps/live-{beta,intro,lite,standard,suite}.svg
rm -f  "$ICONS"/scalable/mimetypes/application-x-ableton-live-*.svg
rm -f  "$ICONS"/symbolic/apps/live-{beta,intro,lite,standard,suite}-symbolic.svg "$ICONS/symbolic/apps/live-symbolic.svg"
rm -f  "$ICONS"/{16x16,24x24,32x32,48x48,128x128,256x256}/apps/max9.png
update-mime-database "$HOME/.local/share/mime" >/dev/null 2>&1 || true
update-desktop-database "$APPS" 2>/dev/null || true
# Unpin the defaults install.sh set; lines pointing anywhere else stay.
sed -i -e '\#^x-scheme-handler/ableton=wine-protocol-ableton\.desktop;\?$#d' \
       -e '\#^application/x-wine-extension-auz=wine-extension-auz\.desktop;\?$#d' \
       -e '\#^application/x-ableton-live-[a-z-]*=ableton-live\.desktop;\?$#d' \
       -e '\#^application/x-ableton-live-max-device=max9\.desktop;\?$#d' \
       -e '\#^x-scheme-handler/c74max=wine-protocol-c74max\.desktop;\?$#d' \
       "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list" 2>/dev/null || true
echo "removed desktop entries, icons and MIME registrations"

if [ "${1:-}" = "--prefix" ]; then
    pfx="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
    # No terminal means no answer; keep the prefix rather than delete it blind.
    read -rp "Also delete $pfx? This removes your Live installation AND its authorisation. [y/N] " a || a=n
    case "$a" in
        [yY]|[yY][eE][sS]) rm -rf "$pfx" && echo "removed $pfx" ;;
        *) echo "kept $pfx" ;;
    esac
fi

# Link setup wrote these as root, so this script cannot remove them. The
# hook only comes from setups older than version 3.
hook=/etc/NetworkManager/dispatcher.d/50-link-multicast
if [ -e "$hook" ]; then
    echo ""
    echo "An earlier Ableton Link setup left a NetworkManager hook behind:"
    echo "  sudo rm $hook"
fi
# Realtime setup before 2026.08 installed this boot-time CPU speed setting
# as root, so this script cannot remove it.
govunit=/etc/systemd/system/ableton-cpufreq-performance.service
if [ -e "$govunit" ]; then
    echo ""
    echo "An earlier release set the CPU to full speed from every boot. Remove that old setting with:"
    echo "  sudo systemctl disable ableton-cpufreq-performance.service"
    echo "  sudo rm $govunit"
    echo "  sudo systemctl daemon-reload"
fi
# The port allowance persists even while the firewall is disabled, so key
# this on the tool being installed, not on it being active right now. Both
# tools can coexist and setup may have used either; mention each.
if command -v ufw >/dev/null 2>&1; then
    echo ""
    echo "If Ableton Link opened UDP port 20808 in ufw, close it with:"
    echo "  sudo ufw delete allow 20808/udp"
fi
if command -v firewall-cmd >/dev/null 2>&1; then
    echo ""
    echo "If Ableton Link opened UDP port 20808 in firewalld, close it with:"
    echo "  sudo firewall-cmd --permanent --remove-port=20808/udp && sudo firewall-cmd --reload"
    echo "or, while firewalld is stopped:"
    echo "  sudo firewall-offline-cmd --remove-port=20808/udp"
fi
echo "done."
