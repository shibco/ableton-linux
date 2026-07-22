#!/usr/bin/env bash
# Remove what install.sh added. The Wine prefix (~/.wine-ableton) is kept unless you pass --prefix.
set -euo pipefail
OPT="$HOME/.local/opt/wine-d2d1-nspa-11.11"
BIN="$HOME/.local/bin/ableton-live"
APPS="$HOME/.local/share/applications"

rm -rf "$OPT"        && echo "removed $OPT"
for d in "$OPT"-rollback-* "$OPT".failed-*; do
    [ -e "$d" ] || continue     # unmatched glob stays literal; skip, don't abort
    rm -rf "$d" && echo "removed $d"
done
rm -f  "$BIN"        && echo "removed $BIN"
rm -f  "$BIN".rollback-*
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
    read -rp "Also delete $pfx? This removes your Live installation AND its authorization. [y/N] " a
    case "$a" in
        [yY]|[yY][eE][sS]) rm -rf "$pfx" && echo "removed $pfx" ;;
        *) echo "kept $pfx" ;;
    esac
fi
echo "done."
