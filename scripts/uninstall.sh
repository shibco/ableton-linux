#!/usr/bin/env bash
# Remove what install.sh added. The Wine prefix (~/works/plugs/studio) is kept unless you pass --prefix.
set -euo pipefail
# Matches install.sh: WORKS_RUNTIME picks a non-default runtime to remove.
# Resolved by the same function install.sh uses, rather than by a second copy
# carrying its own literal of the runtime name — this is a script that runs
# `rm -rf` on whatever it resolves, so the two disagreeing is not a cosmetic
# problem.
for _l in "$(dirname "$0")/runtime-env.sh" \
          "$(cd "$(dirname "$0")/.." && pwd)/scripts/runtime-env.sh"; do
    # shellcheck source=scripts/runtime-env.sh
    [ -r "$_l" ] && . "$_l" && break
done
command -v works_runtime_path >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found next to $0" >&2; exit 1; }
BIN="$HOME/.local/bin/ableton-live"
APPS="$HOME/.local/share/applications"

# This application's own pieces go first, unconditionally: they are what this
# script is for. The shared infrastructure - the runtimes, the works command,
# the toolkit, the channel - is decided afterwards, by who is left.
rm -f  "$BIN"        && echo "removed $BIN"
rm -f  "$BIN".rollback-*
# Legacy PATH links from installers that predate the works command.
rm -f  "$HOME/.local/bin/works-runtime" "$HOME/.local/bin/works-update" \
       "$HOME/.local/bin/ableton-runtime" "$HOME/.local/bin/ableton-update"
# Stop and drop the Ableton Link session anchor's user unit (setup-link.sh
# installs it under ~/.config); the daemon binary goes with ~/works/apps/ableton-live.
systemctl --user disable --now ableton-linkd.service 2>/dev/null || true
rm -f  "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ableton-linkd.service" \
    && echo "removed ~/.config/systemd/user/ableton-linkd.service"
systemctl --user daemon-reload 2>/dev/null || true
rm -rf "$HOME/works/apps/ableton-live" && echo "removed ~/works/apps/ableton-live"

# Everything shared goes only with the last application, and the directory is
# the census - a second application's uninstall runs these same lines and gets
# the right answer without either knowing about the other. This used to remove
# the runtimes and the works command unconditionally, which meant uninstalling
# one application took every other application's runtime and its `works` with
# it: the exact dependency between applications the bundled-infrastructure
# model exists to prevent, created by the uninstaller.
remaining="$(works_app_names 2>/dev/null || true)"
if [ -z "$remaining" ]; then
    # Removing by sibling glob around one resolved path stopped working when
    # the runtime moved into the store: works_runtime_path now names a build
    # *inside* the container, so `rm -rf` on it would take one entry and leave
    # the rest orphaned behind a dangling channel.
    works_remove_runtimes
    # The commands themselves live in works/bin; ~/.local/bin holds only links.
    rm -f  "$HOME/works/bin/works" "$HOME/works/lib/works-runtime" \
           "$HOME/works/lib/works-update" "$HOME/works/lib/works-plug"
    rmdir  "$HOME/works/bin" 2>/dev/null || true
    rm -f  "$HOME/.local/bin/works"
    rm -rf "$HOME/works/lib" "$HOME/works/apps" 2>/dev/null || true
    echo "removed ~/works/lib and the works command (no application left)"
    # The channel install.sh recorded. Not prompted for, unlike the prefix:
    # this is one word of preference, not data, and leaving it behind means a
    # later install is followed by an update pointed at a channel nothing
    # here chose.
    rm -f  "$(works_runtime_store)/.channel"
    rmdir  "$(works_runtime_store)" 2>/dev/null || true
    # Leave no empty shell behind, but never take a Plug with it: rmdir
    # refuses a directory that still holds anything.
    rmdir "$HOME/works" 2>/dev/null && echo "removed ~/works" || true
else
    echo "kept the runtimes and the works command; still installed:"
    printf '%s\n' "$remaining" | sed 's/^/     /'
fi
rmdir  "${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine" 2>/dev/null \
    && echo "removed ~/.config/ableton-wine" || true
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
    # works_plug_path, not a literal: it honours WORKS_PLUG, then the `default`
    # symlink `works plug use` writes, then studio. The literal removed the Plug
    # the machine started with rather than the one it is actually using.
    pfx="$(works_plug_path)"
    # No terminal means no answer; keep the prefix rather than delete it blind.
    read -rp "Also delete $pfx? This removes your Live installation AND its authorisation. [y/N] " a || a=n
    case "$a" in
        [yY]|[yY][eE][sS]) rm -rf "$pfx" && echo "removed $pfx" ;;
        *) echo "kept $pfx" ;;
    esac
    # Deliberately only the selected one. The others hold their own installs and
    # their own authorisations, and an uninstall that removed them without ever
    # naming them would be the single destructive surprise in a script whose job
    # is to be reversible. Name them instead.
    others="$(works_plug_names 2>/dev/null | grep -vxF "${pfx##*/}" || true)"
    if [ -n "$others" ]; then
        echo ""
        echo "These Plugs are still here, each with whatever is installed in it:"
        printf '%s\n' "$others" | sed 's/^/     works plug rm /'
    fi
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
