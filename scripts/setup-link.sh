#!/usr/bin/env bash
# Enable, disable, or inspect the single persistent Ableton Link policy.
# Firewall and service state are recorded under XDG_STATE_HOME so uninstall can
# reverse only changes made by this project.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for lib in "$here/lib/config.sh" "$here/config.sh" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    # The first installed/repository helper wins.
    # shellcheck disable=SC1090
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 || { echo "!! setup-link: config helper is missing" >&2; exit 1; }
. "$here/lib/ui.sh"
trap 'ui_cleanup $?' EXIT
# Progress output is informational: a closed stdout must never stop the work
# between moving the old settings aside and writing the new ones.
trap '' PIPE

action="${1:-enable}"
[ $# -eq 0 ] || shift
mode=session
while [ $# -gt 0 ]; do
    case "$1" in
        --mode=session|--mode=always) mode="${1#--mode=}" ;;
        *) echo "!! unknown Link option: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$action" in enable|disable|status|plan-enable|plan-disable) ;;
    *) echo "usage: setup-link.sh enable [--mode=session|always] | disable | status" >&2; exit 2 ;;
esac

LINK_COORDINATED_ACTION=0
if [ "${ABLETON_LINK_COORDINATED:-0}" = 1 ]; then
    LINK_COORDINATED_ACTION=1
fi

case "$action" in
    status)
        ABLETON_CONFIG_LAYOUT_ROOTS=none
        ableton_config_init repair
        if [ "${ABLETON_CONFIG_REPAIR_NEEDED:-0}" = 1 ]; then
            echo "!! Installer settings need repair; showing Link status from the usable saved values" >&2
        fi ;;
    plan-enable|plan-disable)
        ABLETON_CONFIG_LAYOUT_ROOTS=none; ableton_config_init repair ;;
    enable|disable)
        ABLETON_CONFIG_LAYOUT_ROOTS=none
        ABLETON_SIMPLE_PROJECT_FILES=1
        export ABLETON_SIMPLE_PROJECT_FILES
        ableton_config_init repair ;;
esac
export ABLETON_CONFIG_LAYOUT_ROOTS
for lib in "$here/lib/manifest.sh" "$ABLETON_DATA_HOME/lib/manifest.sh"; do
    # The first installed/repository helper wins.
    # shellcheck disable=SC1090
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_install_project_file >/dev/null 2>&1 || {
    echo "!! setup-link: lifecycle helper is missing" >&2; exit 1; }

case "$action" in
    enable|disable) ableton_install_lock_acquire ;;
    status) ;;
esac

state_file="$ABLETON_STATE_HOME/link-firewall"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit_file="$unit_dir/ableton-linkd.service"
linkctl="$ABLETON_DATA_HOME/ableton-linkctl"
link_pid_file="${XDG_RUNTIME_DIR:-$ABLETON_STATE_HOME/run}/ableton-wine/linkd.pid"
legacy_hook=/etc/NetworkManager/dispatcher.d/50-link-multicast
link_residual=0
LINK_DISABLE_COMMITTED=0
LINK_SETTING_SAVED=1

owned_link_pids()
{
    local want proc pid exe recorded="" seen=" "
    want="$(readlink -f "$ABLETON_LINKD" 2>/dev/null || true)"
    [ -n "$want" ] || return 0
    recorded="$(sed -n '1p' "$link_pid_file" 2>/dev/null || true)"
    case "$recorded" in
        ''|*[!0-9]*) ;;
        *)
            exe="$(readlink -f "/proc/$recorded/exe" 2>/dev/null || true)"
            if kill -0 "$recorded" 2>/dev/null && [ "$exe" = "$want" ]; then
                printf '%s\n' "$recorded"
                seen=" $recorded "
            fi ;;
    esac
    # Exact-executable discovery is safe only for a project-owned binary. An
    # external configured daemon is managed solely through its exact PID file.
    link_binary_is_owned || return 0
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        case "$seen" in *" $pid "*) continue ;; esac
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        [ "$exe" = "$want" ] && printf '%s\n' "$pid"
    done
    return 0
}

first_owned_link_pid()
{
    local pids
    pids="$(owned_link_pids)" || return 1
    [ -n "$pids" ] || return 0
    printf '%s\n' "${pids%%$'\n'*}"
}

stop_owned_detached_link_daemons()
{
    # ableton-linkctl serialises its own start and stop on this lock, and the
    # launcher starts the anchor on every run.  Take the same lock, so a
    # launcher-initiated start cannot spawn a daemon between the enumeration
    # below and the PID-record removal.  The subshell keeps the descriptor from
    # leaking past the body's early returns.
    mkdir -p -- "${link_pid_file%/*}" || return 1
    (
        flock -w 10 9 || {
            echo "!! Another Ableton Link command is still running. Wait a few seconds and try again." >&2
            exit 1
        }
        stop_owned_detached_link_daemons_locked
    ) 9> "${link_pid_file%/*}/linkd.lock"
}

stop_owned_detached_link_daemons_locked()
{
    local pid exe want running=0 failed=0 pids_text=""
    local -a pids=()
    pids_text="$(owned_link_pids)" || return 1
    if [ -n "$pids_text" ]; then
        mapfile -t pids <<< "$pids_text"
    fi
    want="$(readlink -f "$ABLETON_LINKD" 2>/dev/null || true)"
    for pid in "${pids[@]}"; do
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        [ -n "$want" ] && [ "$exe" = "$want" ] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in {1..50}; do
        running=0
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && { running=1; break; }
        done
        [ "$running" -eq 1 ] || break
        sleep 0.1
    done
    for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null || continue
        # Revalidate immediately before escalation so PID reuse cannot direct
        # SIGKILL at another process.
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        [ -n "$want" ] && [ "$exe" = "$want" ] \
            && kill -KILL "$pid" 2>/dev/null || true
    done
    [ "${#pids[@]}" -eq 0 ] || sleep 0.1
    for pid in "${pids[@]}"; do
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        [ -z "$want" ] || [ "$exe" != "$want" ] || failed=1
    done
    [ "$failed" -eq 0 ] || {
        echo "!! Ableton Link is still running and could not be stopped" >&2
        return 1
    }
    rm -f -- "$link_pid_file" 2>/dev/null || true
    [ ! -e "$link_pid_file" ] && [ ! -L "$link_pid_file" ] || \
        link_cleanup_warning "Ableton Link stopped, but its old process marker could not be removed"
}

legacy_unit_is_owned()
{
    local content expected
    [ ! -L "$unit_file" ] || return 1
    content="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$unit_file" 2>/dev/null)"
    expected='[Unit]
Description=Ableton Link session anchor (ableton-linkd)
After=default.target
[Service]
ExecStart=%h/.local/share/ableton-wine/ableton-linkd
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target'
    [ "$content" = "$expected" ] && return 0
    expected='[Unit]
Description=Ableton Link session anchor (ableton-linkd)
After=default.target
[Service]
ExecStart=%h/.local/share/ableton-wine/ableton-linkd --linger 0
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target'
    [ "$content" = "$expected" ]
}

unit_is_owned()
{
    local escaped
    [ -f "$unit_file" ] && [ ! -L "$unit_file" ] || return 1
    escaped="${ABLETON_LINKD//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//%/%%}"
    cmp -s -- "$unit_file" <(cat <<EOF
[Unit]
Description=Ableton Link session anchor (ableton-linux)
After=default.target
X-AbletonLinuxOwned=true

[Service]
ExecStart="$escaped" --linger 0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    ) && return 0
    # Adopt only the two exact unit definitions shipped before ownership
    # markers. Keep any unit with another directive or executable unchanged.
    legacy_unit_is_owned
}

# Finding systemctl proves nothing. The user manager still has to answer, and it
# does not over SSH without a user bus, or in a container. Session policy never
# uses the unit, so an unreachable manager is not an error for it.
systemd_user_available()
{
    command -v systemctl >/dev/null 2>&1 || return 1
    ableton_run_bounded 10 systemctl --user show -p Version --value >/dev/null 2>&1
}

loaded_unit_is_owned()
{
    command -v systemctl >/dev/null 2>&1 || return 1
    local fragment expected exec_line
    fragment="$(ableton_run_bounded 20 systemctl --user show -p FragmentPath --value ableton-linkd.service 2>/dev/null || true)"
    [ -n "$fragment" ] || return 1
    expected="$(ableton_realpath_m "$unit_file")"
    [ "$(ableton_realpath_m "$fragment")" = "$expected" ] || return 1
    if [ -e "$unit_file" ]; then
        unit_is_owned
        return
    fi
    # A service can remain loaded after its file was removed. Prove both its
    # exact executable and that executable's project ownership before stopping
    # it; the canonical unit name alone is never sufficient.
    link_binary_is_owned || return 1
    exec_line="$(ableton_run_bounded 20 systemctl --user show -p ExecStart --value ableton-linkd.service 2>/dev/null || true)"
    case "$exec_line" in *"$ABLETON_LINKD"*) return 0 ;; *) return 1 ;; esac
}

stop_canonical_link_service()
{
    local fragment="" wants="$unit_dir/default.target.wants/ableton-linkd.service"
    local enabled_status=0 active_status=0
    if systemd_user_available; then
        if ! fragment="$(ableton_run_bounded 20 systemctl --user show \
                -p FragmentPath --value ableton-linkd.service 2>/dev/null)"; then
            echo "!! Ableton Link could not inspect the user service" >&2
            return 1
        fi
        if [ -n "$fragment" ] \
           && [ "$(ableton_realpath_m "$fragment")" != "$(ableton_realpath_m "$unit_file")" ]; then
            echo "!! Kept the unrelated user service named ableton-linkd.service: $fragment" >&2
            return 0
        fi
        if { [ -n "$fragment" ] && ! loaded_unit_is_owned; } \
           || { [ -z "$fragment" ] && ! unit_is_owned; }; then
            if [ -n "$fragment" ] || [ -e "$unit_file" ] || [ -L "$unit_file" ] \
               || [ -e "$wants" ] || [ -L "$wants" ]; then
                echo "!! Kept the unfamiliar Ableton Link user service because it does not match one installed by Ableton Linux" >&2
            fi
            return 0
        fi
        ableton_run_bounded 20 systemctl --user is-enabled --quiet \
            ableton-linkd.service 2>/dev/null || enabled_status=$?
        ableton_run_bounded 20 systemctl --user is-active --quiet \
            ableton-linkd.service 2>/dev/null || active_status=$?
        case "$enabled_status" in 0|1|3|4) ;; *)
            echo "!! Ableton Link could not determine whether its user service is enabled" >&2
            return 1 ;;
        esac
        case "$active_status" in 0|1|3|4) ;; *)
            echo "!! Ableton Link could not determine whether its user service is running" >&2
            return 1 ;;
        esac
        if [ -n "$fragment" ] || [ -e "$wants" ] || [ -L "$wants" ] \
           || [ "$enabled_status" -eq 0 ] || [ "$active_status" -eq 0 ]; then
            ableton_run_bounded 20 systemctl --user disable --now \
                ableton-linkd.service >/dev/null 2>&1 || true
            enabled_status=0
            active_status=0
            ableton_run_bounded 20 systemctl --user is-enabled --quiet \
                ableton-linkd.service 2>/dev/null || enabled_status=$?
            ableton_run_bounded 20 systemctl --user is-active --quiet \
                ableton-linkd.service 2>/dev/null || active_status=$?
            case "$enabled_status" in 1|3|4) ;; *)
                echo "!! Ableton Link is still enabled as a user service" >&2
                return 1 ;;
            esac
            case "$active_status" in 1|3|4) ;; *)
                echo "!! Ableton Link is still running as a user service" >&2
                return 1 ;;
            esac
        fi
        return 0
    fi
    if [ -e "$wants" ] || [ -L "$wants" ]; then
        if ! unit_is_owned \
           || [ ! -L "$wants" ] \
           || [ "$(readlink -f -- "$wants" 2>/dev/null || true)" \
                != "$(ableton_realpath_m "$unit_file")" ]; then
            echo "!! Kept the unfamiliar Ableton Link user-service entry: $wants" >&2
            return 0
        fi
        rm -f -- "$wants" 2>/dev/null || true
        [ ! -e "$wants" ] && [ ! -L "$wants" ] || {
            echo "!! Ableton Link could not turn off its background service" >&2
            return 1
        }
    fi
}

link_firewall_record_valid()
{
    local file="$1"
    [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] \
        && ableton_file_has_no_nul "$file" \
        && [ "$(wc -l < "$file")" -eq 1 ] || return 1
    case "$(sed -n '1p' "$file")" in
        ufw-added|firewalld-added|none) return 0 ;;
        *) return 1 ;;
    esac
}

validate_link_firewall_state()
{
    [ ! -e "$state_file" ] && [ ! -L "$state_file" ] && return 0
    ableton_state_marker_valid "$ABLETON_STATE_HOME" \
        && link_firewall_record_valid "$state_file"
}

prepare_link_firewall_state_for_enable()
{
    validate_link_firewall_state && return 0
    echo "!! Old Link firewall information was unreadable, so the firewall will be checked again" >&2
    if [ -d "$state_file" ] && [ ! -L "$state_file" ]; then
        echo "!! Ableton Link cannot replace the firewall information at $state_file" >&2
        return 1
    fi
    rm -f -- "$state_file" 2>/dev/null || true
    [ ! -e "$state_file" ] && [ ! -L "$state_file" ] || {
        echo "!! Ableton Link cannot replace its firewall information" >&2
        return 1
    }
}

write_link_firewall_state()
{
    local value="$1" tmp
    case "$value" in ufw-added|firewalld-added|none) ;; *) return 1 ;; esac
    ableton_mark_state_home || return 1
    tmp="$(mktemp "$ABLETON_STATE_HOME/.link-firewall.XXXXXX")" || return 1
    if ! printf '%s\n' "$value" > "$tmp" \
       || ! chmod 600 "$tmp" \
       || ! link_firewall_record_valid "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -T -f -- "$tmp" "$state_file" 2>/dev/null || true
    if ! link_firewall_record_valid "$state_file" \
       || [ "$(sed -n '1p' "$state_file")" != "$value" ]; then
        rm -f -- "$tmp"
        return 1
    fi
    [ ! -e "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || \
        echo "!! Temporary Link firewall files could not be removed: $tmp" >&2
}

# Return 0 when the rule exists, 1 when a successful query proves it absent,
# and 2 when the firewall state could not be read.
ufw_link_rule_state()
{
    local output
    output="$(ableton_sudo_run_bounded 120 ufw status)" || return 2
    grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)' <<< "$output"
}

firewalld_link_rule_state()
{
    local output
    output="$(ableton_sudo_run_bounded 120 \
        firewall-cmd --permanent --list-ports)" || return 2
    grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)' <<< "$output"
}

firewalld_runtime_link_rule_state()
{
    local output
    output="$(ableton_sudo_run_bounded 120 firewall-cmd --list-ports)" || return 2
    grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)' <<< "$output"
}

firewalld_offline_link_rule_state()
{
    local output
    output="$(ableton_sudo_run_bounded 120 \
        firewall-offline-cmd --list-ports)" || return 2
    grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)' <<< "$output"
}

remove_owned_firewall()
{
    validate_link_firewall_state || {
        echo "!! Link firewall information changed before its rule could be safely removed" >&2
        return 1
    }
    [ ! -e "$state_file" ] && [ ! -L "$state_file" ] && return 0
    local state rc=0 rule_state=0
    state="$(sed -n '1p' "$state_file")"
    case "$state" in
        ufw-added)
            ui_status l_remove_ufw_rule
            ufw_link_rule_state || rule_state=$?
            if [ "$rule_state" -eq 0 ]; then
                ableton_sudo_run_bounded 120 ufw delete allow 20808/udp || true
            elif [ "$rule_state" -ne 1 ]; then
                rc=1
            fi
            if [ "$rc" -eq 0 ]; then
                rule_state=0
                ufw_link_rule_state || rule_state=$?
                [ "$rule_state" -eq 1 ] || rc=1
            fi ;;
        firewalld-added)
            ui_status l_remove_firewalld_rule
            if command -v firewall-cmd >/dev/null 2>&1 \
               && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
                firewalld_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 0 ]; then
                    ableton_sudo_run_bounded 120 firewall-cmd --permanent --remove-port=20808/udp || true
                    ableton_sudo_run_bounded 120 firewall-cmd --reload || true
                elif [ "$rule_state" -ne 1 ]; then
                    rc=1
                fi
                if [ "$rc" -eq 0 ]; then
                    rule_state=0
                    firewalld_link_rule_state || rule_state=$?
                    [ "$rule_state" -eq 1 ] || rc=1
                fi
                if [ "$rc" -eq 0 ]; then
                    rule_state=0
                    firewalld_runtime_link_rule_state || rule_state=$?
                    [ "$rule_state" -eq 1 ] || rc=1
                fi
            elif command -v firewall-offline-cmd >/dev/null 2>&1; then
                firewalld_offline_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 0 ]; then
                    ableton_sudo_run_bounded 120 \
                        firewall-offline-cmd --remove-port=20808/udp || true
                elif [ "$rule_state" -ne 1 ]; then
                    rc=1
                fi
                if [ "$rc" -eq 0 ]; then
                    rule_state=0
                    firewalld_offline_link_rule_state || rule_state=$?
                    [ "$rule_state" -eq 1 ] || rc=1
                fi
            else
                rc=127
            fi ;;
        none|'') ;;
        *) echo "!! Link firewall information changed before its rule could be safely removed" >&2; return 1 ;;
    esac
    [ "$rc" -eq 0 ] || { echo "!! The firewall rule added for Ableton Link could not be removed" >&2; return "$rc"; }
    rm -f -- "$state_file" 2>/dev/null || true
    [ ! -e "$state_file" ] && [ ! -L "$state_file" ] || \
        link_cleanup_warning "The old Link firewall information could not be removed"
}

legacy_hook_is_owned()
{
    [ -f "$legacy_hook" ] && [ ! -L "$legacy_hook" ] \
        && grep -qxF '#!/bin/sh' "$legacy_hook" 2>/dev/null \
        && grep -qF "[ \"\$2\" = \"up\" ] || exit 0" "$legacy_hook" 2>/dev/null \
        && grep -qF 'ip route replace 224.0.0.0/4' "$legacy_hook" 2>/dev/null
}

first_multicast_route()
{
    local routes
    command -v ip >/dev/null 2>&1 || return 127
    routes="$(ip -4 route show 224.0.0.0/4 2>/dev/null)" || return 1
    [ -n "$routes" ] || return 0
    printf '%s\n' "${routes%%$'\n'*}"
}

remove_owned_legacy_hook()
{
    local route_line="" current_route=""
    [ -e "$legacy_hook" ] || return 0
    if ! legacy_hook_is_owned; then
        echo "!! An existing NetworkManager hook was not created by Ableton Linux and was left unchanged: $legacy_hook" >&2
        return 0
    fi
    command -v ip >/dev/null 2>&1 || {
        echo "!! The old Ableton Link multicast route cannot be checked because the ip command is missing" >&2
        return 127
    }
    route_line="$(first_multicast_route)" || {
        echo "!! The old Ableton Link multicast route could not be checked" >&2
        return 1
    }
    ui_status l_remove_multicast_hook
    if [ -n "$route_line" ]; then
        ableton_sudo_run_bounded 120 ip route del 224.0.0.0/4 >/dev/null || true
        current_route="$(first_multicast_route)" || {
            echo "!! The old Ableton Link multicast route could not be checked after removal" >&2
            return 1
        }
        [ -z "$current_route" ] || {
            echo "!! The old Ableton Link multicast route could not be removed" >&2
            return 1
        }
    fi
    if [ -e "$legacy_hook" ] && ! legacy_hook_is_owned; then
        echo "!! The old Link network hook changed and was left alone: $legacy_hook" >&2
        return 0
    fi
    ableton_sudo_run_bounded 120 rm -f -- "$legacy_hook" || true
    [ ! -e "$legacy_hook" ] && [ ! -L "$legacy_hook" ] || \
        link_cleanup_warning "The obsolete Link network hook could not be removed: $legacy_hook"
}

link_binary_is_owned()
{
    [ "$ABLETON_LINKD" = "$ABLETON_DATA_HOME/ableton-linkd" ] \
        && [ -f "$ABLETON_LINKD" ] && [ ! -L "$ABLETON_LINKD" ]
}

link_cleanup_warning()
{
    link_residual=1
    printf '!! %s\n' "$*" >&2 || true
    return 0
}

disable_link()
{
    local firewall_trusted=1
    trap 'if [ "$LINK_DISABLE_COMMITTED" -eq 1 ]; then exit 0; else exit 130; fi' INT
    trap 'if [ "$LINK_DISABLE_COMMITTED" -eq 1 ]; then exit 0; else exit 143; fi' TERM
    [ "$LINK_COORDINATED_ACTION" -eq 1 ] || ui_item_begin l_turn_off_link
    if ! validate_link_firewall_state; then
        firewall_trusted=0
        printf '%s\n' "!! Link firewall information was unreadable, so no firewall rule was changed" >&2 || true
    fi
    stop_canonical_link_service
    stop_owned_detached_link_daemons
    remove_owned_legacy_hook
    [ "$firewall_trusted" -eq 0 ] || remove_owned_firewall
    if [ "$firewall_trusted" -eq 0 ] \
       && { [ -e "$state_file" ] || [ -L "$state_file" ]; }; then
        if ableton_state_marker_valid "$ABLETON_STATE_HOME"; then
            if [ -d "$state_file" ] && [ ! -L "$state_file" ]; then
                link_cleanup_warning "Unreadable Link firewall information could not be removed"
            else
                rm -f -- "$state_file" 2>/dev/null || true
                [ ! -e "$state_file" ] && [ ! -L "$state_file" ] || \
                    link_cleanup_warning "Unreadable Link firewall information could not be removed"
            fi
        else
            echo "!! Unfamiliar Link firewall information was left unchanged: $state_file" >&2 || true
        fi
    fi
    ABLETON_LINK_MODE=off
    export ABLETON_LINK_MODE
    if ! save_link_mode; then
        LINK_SETTING_SAVED=0
        echo "!! Ableton Link is off, but its saved preference could not be updated" >&2
    fi
    LINK_DISABLE_COMMITTED=1
    trap '' INT TERM PIPE
    # From here on the requested external Link state is off. Installed support
    # files stay in place for the next enable or installer run.
    set +e
    if command -v systemctl >/dev/null 2>&1; then
        ableton_run_bounded 20 systemctl --user daemon-reload >/dev/null 2>&1 || \
            link_cleanup_warning "The user-service list will refresh at the next login"
    fi
    if [ -n "${ABLETON_PR182_CUSTOM_LINKD:-}" ]; then
        ui_status l_kept_pr182_helper "$ABLETON_PR182_CUSTOM_LINKD"
    fi
    if [ "$ABLETON_LINKD" != "$ABLETON_DATA_HOME/ableton-linkd" ]; then
        ui_status l_kept_external_helper "$ABLETON_LINKD"
    fi
    if [ "$LINK_COORDINATED_ACTION" -ne 1 ]; then
        if [ "$LINK_SETTING_SAVED" -ne 1 ]; then
            ui_status l_off_unsaved
        elif [ "$link_residual" -eq 0 ]; then
            ui_status l_off
        else
            ui_status l_off_residual
        fi
        ui_item_end ok
    fi
    return 0
}

render_owned_link_unit()
{
    local escaped
    escaped="${ABLETON_LINKD//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//%/%%}"
    cat <<EOF
[Unit]
Description=Ableton Link session anchor (ableton-linux)
After=default.target
X-AbletonLinuxOwned=true

[Service]
ExecStart="$escaped" --linger 0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

save_link_mode()
{
    local tmp="" failures_before="$ABLETON_OPTIONAL_FILE_FAILURES"
    [ "$LINK_COORDINATED_ACTION" -ne 1 ] || return 0
    tmp="$(mktemp "${TMPDIR:-/tmp}/ableton-link-config.XXXXXX")" || return 1
    if ! ableton_render_config > "$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    ableton_install_project_file 600 "$tmp" "$ABLETON_CONFIG_FILE"
    rm -f -- "$tmp" 2>/dev/null || true
    [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] \
        && [ "$ABLETON_OPTIONAL_FILE_FAILURES" -eq "$failures_before" ]
}

install_unit()
{
    local tmp="" failures_before="$ABLETON_OPTIONAL_FILE_FAILURES"
    [ -x "$ABLETON_LINKD" ] || {
        echo "!! The Ableton Link helper is missing. Re-run the installer to restore it." >&2
        return 1
    }
    if [ "${ABLETON_LINK_FILES_MAPPED:-0}" != 1 ]; then
        tmp="$(mktemp "${TMPDIR:-/tmp}/ableton-link-service.XXXXXX")" || return 1
        if ! render_owned_link_unit > "$tmp"; then
            rm -f -- "$tmp" 2>/dev/null || true
            return 1
        fi
        ableton_install_project_file 644 "$tmp" "$unit_file"
        rm -f -- "$tmp" 2>/dev/null || true
        [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] \
            && [ "$ABLETON_OPTIONAL_FILE_FAILURES" -eq "$failures_before" ] || return 1
    fi
    if [ ! -f "$unit_file" ] || [ -L "$unit_file" ]; then
        echo "!! The Ableton Link user service is missing. Re-run the installer to restore it." >&2
        return 1
    fi
    # The fixed project-file loop already installed this unit. With no running
    # user manager there is nothing to reload, and session policy never needs it.
    systemd_user_available || return 0
    if ! ableton_run_bounded 20 systemctl --user daemon-reload; then
        echo "!! The Link user service could not be refreshed yet; its requested state will be checked before setup finishes" >&2
    fi
}

ensure_recorded_firewall()
{
    local state="$1" rule_state=0
    case "$state" in
        ufw-added)
            command -v ufw >/dev/null 2>&1 || {
                echo "!! The ufw rule previously added for Link cannot be checked because ufw is missing" >&2
                return 127
            }
            ui_status l_check_ufw_rule
            ufw_link_rule_state || rule_state=$?
            if [ "$rule_state" -eq 1 ]; then
                ui_status l_restore_ufw_rule
                ableton_sudo_run_bounded 120 ufw allow 20808/udp || true
                rule_state=0
                ufw_link_rule_state || rule_state=$?
                [ "$rule_state" -eq 0 ] || {
                    echo "!! The ufw rule for Link could not be restored" >&2
                    return 1
                }
            elif [ "$rule_state" -ne 0 ]; then
                echo "!! The ufw rule for Link could not be checked" >&2
                return 1
            fi ;;
        firewalld-added)
            ui_status l_check_firewalld_rule
            if command -v firewall-cmd >/dev/null 2>&1 \
               && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
                firewalld_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    ui_status l_restore_firewalld_rule
                    ableton_sudo_run_bounded 120 \
                        firewall-cmd --permanent --add-port=20808/udp || true
                    ableton_sudo_run_bounded 120 firewall-cmd --reload || true
                elif [ "$rule_state" -ne 0 ]; then
                    echo "!! The firewalld rule for Link could not be checked" >&2
                    return 1
                fi
                rule_state=0
                firewalld_link_rule_state || rule_state=$?
                [ "$rule_state" -eq 0 ] || return 1
                rule_state=0
                firewalld_runtime_link_rule_state || rule_state=$?
                [ "$rule_state" -eq 0 ] || {
                    echo "!! The firewalld rule for Link is not active" >&2
                    return 1
                }
            elif command -v firewall-offline-cmd >/dev/null 2>&1; then
                firewalld_offline_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    ui_status l_restore_firewalld_rule
                    ableton_sudo_run_bounded 120 \
                        firewall-offline-cmd --add-port=20808/udp || true
                elif [ "$rule_state" -ne 0 ]; then
                    echo "!! The firewalld rule for Link could not be checked" >&2
                    return 1
                fi
                rule_state=0
                firewalld_offline_link_rule_state || rule_state=$?
                [ "$rule_state" -eq 0 ] || return 1
            else
                echo "!! The firewalld rule previously added for Link cannot be checked because firewalld is missing" >&2
                return 127
            fi ;;
        *) return 2 ;;
    esac
}

configure_firewall()
{
    validate_link_firewall_state || {
        echo "!! Link firewall information is unreadable" >&2
        return 1
    }
    ableton_mark_state_home || return 1
    if [ -r "$state_file" ]; then
        case "$(sed -n '1p' "$state_file")" in
            ufw-added) ensure_recorded_firewall ufw-added; return $? ;;
            firewalld-added) ensure_recorded_firewall firewalld-added; return $? ;;
            none) : ;;
            *) echo "!! Link firewall information is unreadable" >&2; return 1 ;;
        esac
    fi
    if command -v ufw >/dev/null 2>&1 && grep -qsi '^ENABLED=yes' /etc/ufw/ufw.conf; then
        local rule_state=0
        ufw_link_rule_state || rule_state=$?
        if [ "$rule_state" -eq 0 ]; then
            write_link_firewall_state none || {
                echo "!! Ableton Link could not save that the existing ufw rule was left unchanged" >&2
                return 1
            }
            ui_status l_ufw_rule_exists
        elif [ "$rule_state" -eq 1 ]; then
            ui_status l_ufw_open_port
            write_link_firewall_state ufw-added || {
                echo "!! Ableton Link cannot safely track a new ufw rule" >&2
                return 1
            }
            # Persist ownership before ufw can make a partial change so a later
            # disable or uninstall removes only the rule this project attempted.
            ableton_sudo_run_bounded 120 ufw allow 20808/udp || true
            rule_state=0
            ufw_link_rule_state || rule_state=$?
            [ "$rule_state" -eq 0 ] || {
                echo "!! ufw did not open UDP 20808 for Ableton Link" >&2
                return 1
            }
        else
            echo "!! could not inspect the active ufw rules" >&2
            return 1
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 \
         && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
        local rule_state=0
        firewalld_link_rule_state || rule_state=$?
        if [ "$rule_state" -eq 0 ]; then
            write_link_firewall_state none || {
                echo "!! Ableton Link could not save that the existing firewalld rule was left unchanged" >&2
                return 1
            }
            ui_status l_firewalld_rule_exists
            rule_state=0
            firewalld_runtime_link_rule_state || rule_state=$?
            if [ "$rule_state" -ne 0 ]; then
                ableton_sudo_run_bounded 120 firewall-cmd --reload || true
                rule_state=0
                firewalld_runtime_link_rule_state || rule_state=$?
                [ "$rule_state" -eq 0 ] || {
                    echo "!! The existing firewalld rule for Link is not active" >&2
                    return 1
                }
            fi
        elif [ "$rule_state" -eq 1 ]; then
            ui_status l_firewalld_open_port
            write_link_firewall_state firewalld-added || {
                echo "!! Ableton Link cannot safely track a new firewalld rule" >&2
                return 1
            }
            ableton_sudo_run_bounded 120 \
                firewall-cmd --permanent --add-port=20808/udp || true
            ableton_sudo_run_bounded 120 firewall-cmd --reload || true
            rule_state=0
            firewalld_link_rule_state || rule_state=$?
            [ "$rule_state" -eq 0 ] || return 1
            rule_state=0
            firewalld_runtime_link_rule_state || rule_state=$?
            [ "$rule_state" -eq 0 ] || {
                echo "!! firewalld did not open UDP 20808 for Ableton Link" >&2
                return 1
            }
        else
            echo "!! could not inspect the active firewalld rules" >&2
            return 1
        fi
    else
        write_link_firewall_state none || {
            echo "!! Ableton Link could not save its firewall status" >&2
            return 1
        }
        ui_status l_no_firewall
    fi
}

plan_link()
{
    local output=""
    if [ "$action" = plan-disable ]; then
        ui_status l_plan_disable_heading
        ui_status l_plan_stop_service
        [ ! -r "$state_file" ] || ui_status l_plan_remove_firewall
        [ ! -e "$legacy_hook" ] || ui_status l_plan_remove_multicast
        ui_status l_plan_keep_files_save_off
        return 0
    fi
    ui_status l_plan_enable_heading
    [ ! -e "$legacy_hook" ] || ui_status l_plan_remove_multicast
    if command -v ufw >/dev/null 2>&1 && grep -qsi '^ENABLED=yes' /etc/ufw/ufw.conf; then
        if output="$(ableton_run_bounded 20 ufw status 2>/dev/null)"; then
            if grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)' \
                <<< "$output"; then
                ui_status l_plan_keep_ufw
            else
                ui_status l_plan_open_ufw
            fi
        else
            ui_status l_plan_check_ufw
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 \
         && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
        if output="$(ableton_run_bounded 20 firewall-cmd --permanent --list-ports 2>/dev/null)"; then
            if grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)' \
                <<< "$output"; then
                ui_status l_plan_keep_firewalld
            else
                ui_status l_plan_open_firewalld
            fi
        else
            ui_status l_plan_check_firewalld
        fi
    else
        ui_status l_plan_firewall_unchanged
    fi
    case "$mode" in
        session) ui_status l_plan_mode_session ;;
        always) ui_status l_plan_mode_always ;;
    esac
    ui_status l_plan_save_setting
}

enable_link()
{
    local ctl="$here/ableton-linkctl" rc=0 enabled_status=0 active_status=0
    [ -x "$ctl" ] || ctl="$linkctl"
    [ -x "$ctl" ] || {
        echo "!! The Ableton Link controller is missing. Re-run the installer to restore it." >&2
        return 1
    }
    [ -x "$ABLETON_LINKD" ] || {
        echo "!! The Ableton Link helper is missing. Re-run the installer to restore it." >&2
        return 1
    }
    if [ "$mode" = always ] && ! systemd_user_available; then
        echo "!! Background Link mode needs a running systemd user session" >&2
        return 127
    fi

    [ "$LINK_COORDINATED_ACTION" -eq 1 ] || ui_item_begin l_enable_link
    ABLETON_LINK_MODE="$mode"
    export ABLETON_LINK_MODE
    ableton_mark_state_home || return 1
    prepare_link_firewall_state_for_enable || return 1
    remove_owned_legacy_hook || return
    configure_firewall || return

    if [ "$mode" = always ]; then
        stop_canonical_link_service || return
    fi
    if ! install_unit; then
        if [ "$mode" = always ]; then
            return 1
        fi
        link_cleanup_warning "The optional background Link service could not be prepared; Link will still run with Ableton Live"
    fi
    case "$mode" in
        session) stop_canonical_link_service || rc=$? ;;
        always)
            stop_owned_detached_link_daemons || rc=$?
            if [ "$rc" -eq 0 ]; then
                ableton_run_bounded 20 systemctl --user enable --now \
                    ableton-linkd.service >/dev/null 2>&1 || rc=$?
            fi ;;
    esac
    [ "$rc" -eq 0 ] || return "$rc"

    if [ "$mode" = always ]; then
        ableton_run_bounded 20 systemctl --user is-enabled --quiet \
            ableton-linkd.service 2>/dev/null || enabled_status=$?
        ableton_run_bounded 20 systemctl --user is-active --quiet \
            ableton-linkd.service 2>/dev/null || active_status=$?
        [ "$enabled_status" -eq 0 ] && [ "$active_status" -eq 0 ] || return 1
        [ -z "$(first_owned_link_pid)" ] || return 1
    fi
    if ! save_link_mode; then
        LINK_SETTING_SAVED=0
        echo "!! Ableton Link system changes completed, but its saved preference could not be updated" >&2
    fi
    # Link and its saved preference are complete. A closed progress stream or a
    # late signal cannot turn reporting into an operation failure.
    trap '' INT TERM PIPE
    set +e
    if [ "$LINK_COORDINATED_ACTION" -ne 1 ]; then
        if [ "$LINK_SETTING_SAVED" -ne 1 ]; then
            ui_status l_enabled_unsaved
        else
            case "$mode" in
                session) ui_status l_enabled_session ;;
                always) ui_status l_enabled_always ;;
            esac
        fi
        ui_item_end ok
    fi
    return 0
}

case "$action" in
    enable) enable_link ;;
    disable) disable_link ;;
    status)
        case "$ABLETON_LINK_MODE" in
            off) ui_status l_status_mode_off ;;
            session) ui_status l_status_mode_session ;;
            always) ui_status l_status_mode_always ;;
        esac
        status_pid=""
        if [ "$ABLETON_LINK_MODE" = always ] && loaded_unit_is_owned \
           && ableton_run_bounded 20 systemctl --user is-active --quiet \
                ableton-linkd.service 2>/dev/null; then
            ui_status l_status_running_systemd
        elif status_pid="$(first_owned_link_pid)" \
             && [ -n "$status_pid" ]; then
            ui_status l_status_running_pid "$status_pid"
        elif [ -x "$ABLETON_LINKD" ]; then
            ui_status l_status_stopped
        else
            ui_status l_status_not_installed
        fi
        if ! validate_link_firewall_state; then
            ui_status l_status_firewall_unknown
        elif [ ! -r "$state_file" ]; then
            ui_status l_status_firewall_unchanged
        else
            case "$(sed -n '1p' "$state_file")" in
                ufw-added) ui_status l_status_firewall_ufw ;;
                firewalld-added) ui_status l_status_firewall_firewalld ;;
                none) ui_status l_status_firewall_unchanged ;;
            esac
        fi
        ;;
    plan-enable|plan-disable) plan_link ;;
esac
