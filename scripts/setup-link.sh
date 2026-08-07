#!/usr/bin/env bash
# Ableton Link setup: firewall allowance plus the ableton-linkd session
# anchor. The main installer runs this once. It remains safe to re-run.
# The daemon ships in the .run installer (installed to
# ~/.local/share/ableton-wine/ableton-linkd); this script never builds software.
#
# Link needs no multicast route: the Link SDK binds every discovery socket to
# its interface with IP_MULTICAST_IF, which bypasses the routing-table lookup
# that makes routeless multicast sends fail with ENETUNREACH. Versions 1 and 2
# of this script added a 224.0.0.0/4 route and a NetworkManager hook to keep
# it alive; version 3 removed both. Version 4 stopped enabling the
# ableton-linkd user unit: the launchers start a session-scoped daemon that
# exits on its own, and the unit stays registered as the explicit opt-in for
# an always-on anchor. Version 5 records the configured marker only when the
# anchor step completed; version 4 wrote it unconditionally, so a run that
# skipped the anchor hid the version-4 migration from every later run. sudo
# is used only to open the firewall port when a firewall is active and to
# remove the old hook where one exists.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# Bump whenever this script's system-level effects change (firewall rule, unit
# handling): forces one re-run on hosts with a stale marker so an existing
# install picks up the fix instead of silently keeping old behavior.
LINK_SETUP_VERSION=5

if pgrep -f "Ableton Live.*\.exe" >/dev/null 2>&1; then
    echo "!! Live is running: close it before changing Link networking" >&2
    exit 1
fi

echo "== [1/3] firewall =="
# Discovery rides the fixed UDP port 20808 (multicast group 224.76.78.75);
# unicast measurement uses ephemeral ports, which conntrack already covers for
# outbound-initiated exchanges, so 20808/udp is the only firewall rule Link
# needs. Only an active firewall warrants a sudo prompt. Neither activity
# check needs privileges: the ufw check reads its world-readable config, and
# firewall-cmd --state asks the daemon itself, which also works without
# systemd as the init.
if command -v ufw >/dev/null 2>&1 \
   && grep -qsi '^ENABLED=yes' /etc/ufw/ufw.conf; then
    echo "   ufw is active: allowing UDP port 20808 (this asks for sudo)"
    sudo ufw allow 20808/udp
elif command -v firewall-cmd >/dev/null 2>&1 \
     && firewall-cmd --state >/dev/null 2>&1; then
    echo "   firewalld is active: allowing UDP port 20808 (this asks for sudo)"
    sudo firewall-cmd --permanent --add-port=20808/udp
    sudo firewall-cmd --reload
else
    echo "   no active ufw/firewalld: nothing to open; if you run another firewall, allow UDP 20808 yourself"
fi

echo "== [2/3] leftovers from earlier setups =="
# Versions 1 and 2 installed a multicast route and a NetworkManager hook as
# root, so removing the hook needs sudo. Version 1's hook could move the
# route onto a VPN tunnel; without it the stale route is harmless to Link
# and clears on reboot, so a route alone does not warrant a sudo prompt.
hook=/etc/NetworkManager/dispatcher.d/50-link-multicast
if [ -e "$hook" ]; then
    echo "   an earlier setup installed $hook; removing it (this asks for sudo)"
    if sudo rm -f "$hook"; then
        echo "   removed $hook"
        sudo ip route del 224.0.0.0/4 2>/dev/null || true
    else
        # Do not mark this version configured with the hook still in place:
        # the marker would stop every later update from retrying the removal.
        echo "!! could not remove it; remove it yourself with: sudo rm $hook" >&2
        echo "!! then re-run this script" >&2
        exit 1
    fi
elif ip -4 route show 224.0.0.0/4 2>/dev/null | grep -q .; then
    echo "   a 224.0.0.0/4 route from an earlier setup is still present; it is harmless"
    echo "   and clears on reboot, or remove it now with: sudo ip route del 224.0.0.0/4"
else
    echo "   none found"
fi

echo "== [3/3] Ableton Link service =="
# The daemon and its unit ship in the .run installer; a missing binary is a
# skip, not a failure because the firewall setup above stands on its own.
# Since version 4 the unit is registered but not enabled: the launchers start
# ableton-linkd per session, and it exits on its own once no peer is left
# (see --linger in the daemon). Enabling the unit is the explicit opt-in for
# an always-on anchor, so this script never touches an enablement made after
# the version-5 migration below. Version 4 only existed in pre-release
# testing, where this marker could be written without the migration running,
# so a marker reading 4 cannot be trusted as a deliberate choice.
linkd="${ABLETON_LINKD:-$HOME/.local/share/ableton-wine/ableton-linkd}"
marker="$HOME/.local/share/ableton-wine/link-configured"
prior_version="$(sed -n 2p "$marker" 2>/dev/null || true)"
case "$prior_version" in ''|*[!0-9]*) prior_version=0 ;; esac
anchor=skipped
service_checked=0
if [ ! -x "$linkd" ]; then
    echo "   ableton-linkd not found (looked at $linkd): skipping" >&2
    echo "   the .run installer provides it; re-run this script after installing" >&2
else
    # The unit ships next to the daemon; fall back to a copy beside this
    # script (repo checkout, or the kit's scripts directory).
    unit_src="$(dirname "$linkd")/ableton-linkd.service"
    [ -f "$unit_src" ] || unit_src="$here/ableton-linkd.service"
    if [ ! -f "$unit_src" ]; then
        echo "   ableton-linkd.service not found next to $linkd or in $here: skipping" >&2
    else
        unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        mkdir -p "$unit_dir"
        cp "$unit_src" "$unit_dir/ableton-linkd.service"
        anchor=session
        if ! command -v systemctl >/dev/null 2>&1; then
            # No systemctl means no unit management exists, so the migration
            # below has nothing to check; record this version normally.
            service_checked=1
        elif systemctl --user daemon-reload 2>/dev/null; then
            service_checked=1
            # One-time migration: setups before version 5 may have enabled the
            # unit at login. For versions 1-3 nobody chose that. Version 4 was
            # never released, and its marker could be written without this
            # migration running, so prior=4 gets the same check; a real opt-in
            # is one command away and the closing message names it.
            if [ "$prior_version" -lt 5 ] \
               && systemctl --user is-enabled --quiet ableton-linkd.service 2>/dev/null; then
                if systemctl --user disable --now ableton-linkd.service >/dev/null 2>&1; then
                    echo "   earlier setups ran ableton-linkd from login; disabled that"
                else
                    echo "!! could not disable the earlier always-on ableton-linkd service" >&2
                    echo "!! run: systemctl --user disable --now ableton-linkd.service" >&2
                    echo "!! then re-run ~/.local/share/ableton-wine/setup-link.sh" >&2
                    exit 1
                fi
            fi
        else
            # Mirror the hook convention above: do not mark this version
            # configured when the anchor state could not even be checked, or
            # the marker would stop every later update from retrying. The
            # session bus is usually what is missing (an SSH session), so
            # point at a real login.
            echo "!! could not check the Link background service from this session" >&2
            echo "!! log in on the machine itself and run ~/.local/share/ableton-wine/setup-link.sh again" >&2
            exit 1
        fi
    fi
fi
# A daemon from before the migration predates the idle exit and would run
# until reboot; stop it so the session model applies now. Live is closed
# (checked at the top), so no session loses its anchor.
if [ "$prior_version" -lt 5 ] && pkill -x ableton-linkd 2>/dev/null; then
    echo "   stopped the running always-on ableton-linkd"
fi

echo
if [ "$anchor" = session ]; then
    echo "OK: Link setup complete; the launchers start ableton-linkd with Live"
    echo "    (always-on anchor instead: systemctl --user enable --now ableton-linkd.service)"
else
    echo "OK: Link firewall setup complete; the ableton-linkd anchor was skipped,"
    echo "    so this run is not recorded and setup runs again on a later update"
fi
# Record the version only when the anchor step ran to completion: that alone
# proves the unit registration and the migration check above really happened.
if [ "$anchor" = session ] && [ "$service_checked" -eq 1 ]; then
    mkdir -p "$HOME/.local/share/ableton-wine"
    printf 'configured\n%s\n' "$LINK_SETUP_VERSION" > "$marker"
fi
