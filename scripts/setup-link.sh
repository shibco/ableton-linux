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

action="${1:-enable}"
[ $# -eq 0 ] || shift
mode=session
transaction_dir=""
case "$action" in
    snapshot|preflight-rollback|preflight-commit|rollback|commit)
        [ $# -ge 1 ] || { echo "!! setup-link.sh $action needs a transaction directory" >&2; exit 2; }
        transaction_dir="$1"
        shift ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --mode=session|--mode=always) mode="${1#--mode=}" ;;
        *) echo "!! unknown Link option: $1" >&2; exit 2 ;;
    esac
    shift
done
if [ -n "$transaction_dir" ]; then
    ABLETON_TRANSACTION_DIR="$transaction_dir"
    export ABLETON_TRANSACTION_DIR
fi
case "$action" in enable|disable|status|snapshot|preflight-rollback|preflight-commit|rollback|commit|plan-enable|plan-disable) ;;
    *) echo "usage: setup-link.sh enable [--mode=session|always] | disable | status" >&2; exit 2 ;;
esac

LINK_COORDINATED_ACTION=0
coordinator_dir="${ABLETON_TRANSACTION_DIR:-}"
if [ "${ABLETON_LINK_COORDINATED:-0}" = 1 ]; then
    LINK_COORDINATED_ACTION=1
fi
case "$action:$coordinator_dir" in
    enable:/*|disable:/*)
        if [ -d "$coordinator_dir" ] && [ ! -L "$coordinator_dir" ] \
           && [ -f "$coordinator_dir/active" ] && [ ! -L "$coordinator_dir/active" ] \
           && [ ! -s "$coordinator_dir/active" ]; then
            LINK_COORDINATED_ACTION=1
        fi ;;
esac

repair_link_config_before_init()
{
    local candidate parent name header format nul_count
    case "$action" in enable|disable) ;; *) return 0 ;; esac
    if [ "${ABLETON_CONFIG_REPAIR_MODE:-0}" = 1 ] \
       && [ -n "${ABLETON_CONFIG_SNAPSHOT_PATH:-}" ] \
       && [ -n "${ABLETON_CONFIG_SNAPSHOT_TOKEN:-}" ] \
       && [ -n "${ABLETON_CONFIG_SNAPSHOT_VALUES:-}" ]; then
        # The public installer already bound this object under the lifecycle
        # lock and salvaged/defaulted its usable values.
        return 0
    fi
    candidate="${ABLETON_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/config}"
    parent="$(ableton_realpath_m "$(dirname -- "$candidate")")" || return 1
    name="$(basename -- "$candidate")" || return 1
    candidate="$parent/$name"
    [ -e "$candidate" ] || [ -L "$candidate" ] || return 0
    ableton_managed_config_valid "$candidate" && return 0
    # A project-owned regular file from an older format can be repaired by the
    # shared field-by-field parser. Foreign objects, directories, and symlinks
    # remain a hard pre-mutation boundary.
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -r "$candidate" ] || {
        echo "!! Installer settings at $candidate were left unchanged because they are not a regular project file" >&2
        return 1
    }
    nul_count="$(LC_ALL=C tr -cd '\000' < "$candidate" 2>/dev/null | wc -c)" \
        || return 1
    [ "$nul_count" -eq 0 ] || return 1
    IFS= read -r header < "$candidate" || return 1
    [ "$header" = '# ableton-linux installer configuration; managed by the installer' ] || {
        echo "!! Installer settings at $candidate were left unchanged because they do not belong to Ableton Linux" >&2
        return 1
    }
    format="$(awk -F = '$1=="format" { n++; value=substr($0, index($0, "=")+1) } END { if (n==1) print value; else exit 1 }' "$candidate")" || return 1
    [ "$format" = 1 ] || return 1
    return 0
}

if ! repair_link_config_before_init; then
    echo "!! Installer settings are damaged. Re-run the main installer to rebuild them before changing Link." >&2
    exit 1
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
    *)
        ABLETON_CONFIG_LAYOUT_ROOTS='data config state'; ableton_config_init repair ;;
esac
export ABLETON_CONFIG_LAYOUT_ROOTS
for lib in "$here/lib/manifest.sh" "$ABLETON_DATA_HOME/lib/manifest.sh"; do
    # The first installed/repository helper wins.
    # shellcheck disable=SC1090
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_validate_install_state_journals >/dev/null 2>&1 || {
    echo "!! setup-link: lifecycle helper is missing" >&2; exit 1; }

case "$action" in
    enable|disable|snapshot|preflight-rollback|preflight-commit|rollback|commit)
        ableton_install_lock_acquire
        # Link files are generated integration. Stale installed-file or legacy
        # restoration records must not prevent them from being rebuilt.
        if ! ableton_validate_install_state_journals repair >/dev/null 2>&1; then
            echo "!! Old Link file records could not be repaired; Link will ignore them" >&2
        fi ;;
    status) ;;
esac

state_file="$ABLETON_STATE_HOME/link-firewall"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit_file="$unit_dir/ableton-linkd.service"
data_unit="$ABLETON_DATA_HOME/ableton-linkd.service"
linkctl="$ABLETON_DATA_HOME/ableton-linkctl"
link_pid_file="${XDG_RUNTIME_DIR:-$ABLETON_STATE_HOME/run}/ableton-wine/linkd.pid"
legacy_policy_file="$ABLETON_DATA_HOME/link-configured"
legacy_hook=/etc/NetworkManager/dispatcher.d/50-link-multicast
LINK_ENABLE_RECOVERED_STATUS=75
LINK_ENABLE_INCOMPLETE_STATUS=70
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

stop_owned_service()
{
    loaded_unit_is_owned || return 0
    stop_canonical_link_service
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

snapshot_link_service_state()
{
    local snapshot="$1" first_pid="" enabled_status=0 active_status=0
    if systemd_user_available; then
        : > "$snapshot/manager" || return 1
        ableton_run_bounded 20 systemctl --user is-enabled --quiet \
            ableton-linkd.service 2>/dev/null || enabled_status=$?
        ableton_run_bounded 20 systemctl --user is-active --quiet \
            ableton-linkd.service 2>/dev/null || active_status=$?
        case "$enabled_status" in 0|1|3|4) ;; *)
            echo "!! Ableton Link could not read the current user-service setting" >&2
            return 1 ;;
        esac
        case "$active_status" in 0|1|3|4) ;; *)
            echo "!! Ableton Link could not read whether its user service is running" >&2
            return 1 ;;
        esac
        if [ "$enabled_status" -eq 0 ]; then
            : > "$snapshot/enabled" || return 1
        else
            : > "$snapshot/enabled.absent" || return 1
        fi
        if [ "$active_status" -eq 0 ]; then
            : > "$snapshot/active" || return 1
        else
            : > "$snapshot/active.absent" || return 1
        fi
    else
        : > "$snapshot/manager.absent" || return 1
        : > "$snapshot/enabled.absent" || return 1
        : > "$snapshot/active.absent" || return 1
    fi
    first_pid="$(first_owned_link_pid)" || return 1
    if [ -n "$first_pid" ]; then
        : > "$snapshot/detached-active" || return 1
    else
        : > "$snapshot/detached-active.absent" || return 1
    fi
}

link_snapshot_prior_token()
{
    local base="$1"
    if [ -e "$base" ] || [ -L "$base" ]; then
        ableton_object_token "$base"
    elif [ -f "$base.absent" ] && [ ! -L "$base.absent" ]; then
        printf '%s\n' absent
    else
        return 1
    fi
}

link_service_matches_snapshot()
{
    local snapshot="$1" enabled_status=0 active_status=0
    [ -e "$snapshot/manager" ] || return 0
    systemd_user_available || return 1
    ableton_run_bounded 20 systemctl --user is-enabled --quiet \
        ableton-linkd.service 2>/dev/null || enabled_status=$?
    ableton_run_bounded 20 systemctl --user is-active --quiet \
        ableton-linkd.service 2>/dev/null || active_status=$?
    case "$enabled_status:$active_status" in
        0:0|0:1|0:3|0:4|1:0|1:1|1:3|1:4|3:0|3:1|3:3|3:4|4:0|4:1|4:3|4:4) ;;
        *) return 1 ;;
    esac
    if [ -e "$snapshot/enabled" ]; then
        [ "$enabled_status" -eq 0 ] || return 1
    else
        [ "$enabled_status" -ne 0 ] || return 1
    fi
    if [ -e "$snapshot/active" ]; then
        [ "$active_status" -eq 0 ]
    else
        [ "$active_status" -ne 0 ]
    fi
}

link_detached_matches_snapshot()
{
    local snapshot="$1" pid=""
    pid="$(first_owned_link_pid)" || return 1
    { [ -e "$snapshot/detached-active" ] && [ -n "$pid" ]; } \
        || { [ -e "$snapshot/detached-active.absent" ] && [ -z "$pid" ]; }
}

quiesce_link_process_state_for_restore()
{
    local snapshot="$1" rc=0 restore_service=1 restore_detached=1
    if [ -e "$snapshot/local-recovery" ]; then
        [ -e "$snapshot/service-mutating" ] || restore_service=0
        [ -e "$snapshot/detached-mutating" ] || restore_detached=0
    else
        link_service_matches_snapshot "$snapshot" && restore_service=0
        link_detached_matches_snapshot "$snapshot" && restore_detached=0
    fi
    if [ "$restore_service" -eq 1 ] && [ -e "$snapshot/manager" ]; then
        systemd_user_available || {
            echo "!! The previous Link service state cannot be restored outside a running user session" >&2
            return 1
        }
        stop_owned_service || rc=$?
    elif [ "$restore_service" -eq 1 ] && [ -e "$snapshot/service-mutating" ]; then
        echo "!! The previous Link service state cannot be restored outside a running user session" >&2
        rc=1
    fi
    if [ "$rc" -eq 0 ] && [ "$restore_detached" -eq 1 ]; then
        stop_owned_detached_link_daemons || rc=$?
    fi
    return "$rc"
}

restore_link_process_state()
{
    local snapshot="$1" ctl actual_enabled=0 actual_active=0 restored_pid="" rc=0
    local restore_service=1 restore_detached=1
    if [ -e "$snapshot/local-recovery" ]; then
        [ -e "$snapshot/service-mutating" ] || restore_service=0
        [ -e "$snapshot/detached-mutating" ] || restore_detached=0
    fi
    if [ "$restore_service" -eq 1 ] && [ -e "$snapshot/manager" ]; then
        systemd_user_available || {
            echo "!! no systemd user manager is reachable to restore the Link unit state" >&2
            return 1
        }
        ableton_run_bounded 20 systemctl --user daemon-reload >/dev/null 2>&1 || true
        if [ -e "$snapshot/enabled" ]; then
            unit_is_owned || rc=1
            [ "$rc" -ne 0 ] || ableton_run_bounded 20 systemctl --user enable \
                ableton-linkd.service >/dev/null 2>&1 || true
        elif unit_is_owned; then
            ableton_run_bounded 20 systemctl --user disable \
                ableton-linkd.service >/dev/null 2>&1 || true
        fi
        if [ "$rc" -eq 0 ] && [ -e "$snapshot/active" ]; then
            unit_is_owned || rc=1
            [ "$rc" -ne 0 ] || ableton_run_bounded 20 systemctl --user start \
                ableton-linkd.service >/dev/null 2>&1 || true
        elif [ "$rc" -eq 0 ] && loaded_unit_is_owned; then
            ableton_run_bounded 20 systemctl --user stop \
                ableton-linkd.service >/dev/null 2>&1 || true
        fi
    fi
    if [ "$rc" -eq 0 ] && [ -e "$snapshot/manager" ]; then
        systemd_user_available || rc=1
        if [ "$rc" -eq 0 ]; then
            ableton_run_bounded 20 systemctl --user is-enabled --quiet \
                ableton-linkd.service 2>/dev/null || actual_enabled=$?
            ableton_run_bounded 20 systemctl --user is-active --quiet \
                ableton-linkd.service 2>/dev/null || actual_active=$?
            case "$actual_enabled:$actual_active" in
                0:0|0:1|0:3|0:4|1:0|1:1|1:3|1:4|3:0|3:1|3:3|3:4|4:0|4:1|4:3|4:4) ;;
                *) rc=1 ;;
            esac
            if [ "$rc" -eq 0 ] \
               && { { [ -e "$snapshot/enabled" ] && [ "$actual_enabled" -ne 0 ]; } \
               || { [ -e "$snapshot/enabled.absent" ] && [ "$actual_enabled" -eq 0 ]; } \
               || { [ -e "$snapshot/active" ] && [ "$actual_active" -ne 0 ]; } \
               || { [ -e "$snapshot/active.absent" ] && [ "$actual_active" -eq 0 ]; }; }; then
                echo "!! The previous Link user-service state could not be verified" >&2
                rc=1
            fi
        fi
    fi
    ctl="$here/ableton-linkctl"; [ -x "$ctl" ] || ctl="$linkctl"
    if [ "$rc" -eq 0 ] && [ "$restore_detached" -eq 1 ] \
       && [ -e "$snapshot/detached-active" ]; then
        [ -x "$ctl" ] || rc=1
        [ "$rc" -ne 0 ] || ABLETON_LINK_MODE=session "$ctl" start || true
    fi
    if [ "$rc" -eq 0 ]; then
        restored_pid="$(first_owned_link_pid)" || rc=$?
        if { [ -e "$snapshot/detached-active" ] && [ -z "$restored_pid" ]; } \
           || { [ -e "$snapshot/detached-active.absent" ] && [ -n "$restored_pid" ]; }; then
            echo "!! The previous Link process state could not be verified" >&2
            rc=1
        fi
    fi
    return "$rc"
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

snapshot_link_firewall_state()
{
    local destination="$1"
    if [ ! -e "$state_file" ] && [ ! -L "$state_file" ]; then
        : > "$destination.absent" || return 1
        return 0
    fi
    validate_link_firewall_state || {
        echo "!! unsafe Link firewall ownership record: $state_file" >&2
        return 1
    }
    cp -a -- "$state_file" "$destination"
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
            echo "-- removing the ufw rule added for Ableton Link"
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
            echo "-- removing the firewalld rule added for Ableton Link"
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

restore_firewall_snapshot()
{
    local snapshot="$1" prior="" current="" rc=0
    if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
        link_firewall_record_valid "$snapshot" || return 1
        prior="$(sed -n '1p' "$snapshot")"
    fi
    validate_link_firewall_state || return 1
    [ ! -r "$state_file" ] || current="$(sed -n '1p' "$state_file")"
    if [ -r "$snapshot" ] && [ "$current" = "$prior" ]; then
        # The ownership record is authoritative. Revalidate/repair the actual
        # owned rule as well; equal record bytes alone do not prove host state.
        case "$prior" in
            ufw-added|firewalld-added) restore_firewall_record "$prior" ;;
            none) return 0 ;;
        esac
        return
    fi
    [ ! -e "$state_file" ] && [ ! -L "$state_file" ] \
        || remove_owned_firewall || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ -r "$snapshot" ]; then
        restore_firewall_record "$prior"
    else
        rm -f -- "$state_file" 2>/dev/null || true
        [ ! -e "$state_file" ] && [ ! -L "$state_file" ] || \
            echo "!! The old Link firewall information could not be removed" >&2
    fi
}

firewall_matches_snapshot()
{
    local snapshot="$1" prior current rule_state=0
    prior="$(link_snapshot_prior_token "$snapshot")" || return 1
    current="$(ableton_object_token "$state_file" 2>/dev/null || true)"
    [ "$current" = "$prior" ] || return 1
    [ ! -e "$snapshot" ] && return 0
    case "$(sed -n '1p' "$snapshot")" in
        ufw-added)
            ufw_link_rule_state || rule_state=$?
            [ "$rule_state" -eq 0 ] ;;
        firewalld-added)
            if command -v firewall-cmd >/dev/null 2>&1 \
               && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
                firewalld_link_rule_state || rule_state=$?
                [ "$rule_state" -eq 0 ] || return 1
                rule_state=0
                firewalld_runtime_link_rule_state || rule_state=$?
            else
                firewalld_offline_link_rule_state || rule_state=$?
            fi
            [ "$rule_state" -eq 0 ] ;;
        none) return 0 ;;
        *) return 1 ;;
    esac
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

snapshot_legacy_network()
{
    local destination="$1" route_line=""
    if legacy_hook_is_owned; then
        cp -a -- "$legacy_hook" "$destination.hook" || return 1
        route_line="$(first_multicast_route)" || {
            echo "!! Link cannot safely inspect the old multicast route" >&2
            return 1
        }
        if [ -n "$route_line" ]; then
            printf '%s\n' "$route_line" > "$destination.route" || return 1
        else
            : > "$destination.route.absent" || return 1
        fi
    else
        : > "$destination.hook.absent" || return 1
        # No recognised project hook means this command will not touch the
        # legacy route, so its live value is outside Link recovery.
        : > "$destination.route.absent" || return 1
    fi
}

restore_legacy_network()
{
    local snapshot="$1" mode route_line current_route prior_hook current_hook
    [ -e "$snapshot.hook" ] || return 0
    if [ -e "$legacy_hook" ] && ! legacy_hook_is_owned; then
        echo "!! The old Link network hook changed, so it was left alone" >&2
        return 1
    fi
    mode="$(stat -c '%a' "$snapshot.hook")" || return 1
    prior_hook="$(ableton_object_token "$snapshot.hook" 2>/dev/null || true)"
    [ -n "$prior_hook" ] || return 1
    ableton_sudo_run_bounded 120 install -m "$mode" -- "$snapshot.hook" "$legacy_hook" || true
    current_hook="$(ableton_object_token "$legacy_hook" 2>/dev/null || true)"
    [ "$current_hook" = "$prior_hook" ] || {
        echo "!! The old Link network hook could not be restored" >&2
        return 1
    }
    route_line="$(sed -n '1p' "$snapshot.route" 2>/dev/null || true)"
    if [ -n "$route_line" ]; then
        local -a route_args=()
        read -r -a route_args <<< "$route_line"
        [ "${route_args[0]:-}" = 224.0.0.0/4 ] || {
            echo "!! The saved multicast route is unreadable" >&2; return 1; }
        ableton_sudo_run_bounded 120 ip route replace "${route_args[@]}" || true
        current_route="$(first_multicast_route)" || return 1
        [ "$current_route" = "$route_line" ] || {
            echo "!! The previous multicast route could not be restored" >&2
            return 1
        }
    else
        current_route="$(first_multicast_route)" || return 1
        [ -z "$current_route" ] || {
            echo "!! The multicast route changed while Link was being restored" >&2
            return 1
        }
    fi
}

legacy_network_safe_for_restore()
{
    local snapshot="$1" prior_route current_route prior_hook=absent current_hook=absent
    [ -e "$snapshot.hook" ] || return 0
    [ ! -e "$snapshot.hook" ] \
        || prior_hook="$(ableton_object_token "$snapshot.hook" 2>/dev/null || true)"
    [ ! -e "$legacy_hook" ] \
        || current_hook="$(ableton_object_token "$legacy_hook" 2>/dev/null || true)"
    [ -n "$prior_hook$current_hook" ] || return 1
    [ "$current_hook" = absent ] || [ "$current_hook" = "$prior_hook" ] \
        || legacy_hook_is_owned || return 1
    prior_route="$(sed -n '1p' "$snapshot.route" 2>/dev/null || true)"
    current_route="$(first_multicast_route)" || return 1
    [ -z "$current_route" ] || [ "$current_route" = "$prior_route" ]
}

legacy_network_matches_snapshot()
{
    local snapshot="$1" prior_hook=absent current_hook=absent prior_route current_route
    [ -e "$snapshot.hook" ] || return 0
    [ ! -e "$snapshot.hook" ] \
        || prior_hook="$(ableton_object_token "$snapshot.hook" 2>/dev/null || true)"
    [ ! -e "$legacy_hook" ] \
        || current_hook="$(ableton_object_token "$legacy_hook" 2>/dev/null || true)"
    prior_route="$(sed -n '1p' "$snapshot.route" 2>/dev/null || true)"
    current_route="$(first_multicast_route)" || return 1
    [ "$current_hook" = "$prior_hook" ] && [ "$current_route" = "$prior_route" ]
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
    echo "-- removing the old Ableton Link multicast hook"
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

manifest_digest_for()
{
    local wanted="$1" kind path digest extra found=""
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] || return 1
    while IFS=$'\t' read -r kind path digest extra; do
        [ "$kind" = file ] && [ "$path" = "$wanted" ] || continue
        [ -z "$extra" ] && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        [ -z "$found" ] || return 1
        found="$digest"
    done < "$manifest"
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

legacy_link_file_is_owned()
{
    local target="$1"
    [ -f "$target" ] && [ ! -L "$target" ] && [ -r "$target" ] || return 1
    case "$target" in
        "$ABLETON_DATA_HOME/ableton-linkd")
            strings "$target" 2>/dev/null \
                | grep -xF 'ableton-linkd: native Ableton Link session anchor and probe' \
                    >/dev/null ;;
        "$ABLETON_DATA_HOME/ableton-linkctl")
            ableton_file_has_no_nul "$target" \
                && [ "$(sed -n '1p' "$target")" = '#!/usr/bin/env bash' ] \
                && grep -qxF '# Project-owned Ableton Link lifecycle controller.  The PID record plus exact' \
                    "$target" \
                && grep -qxF "case \"\$link_action\" in" "$target" \
                && grep -qxF '    *) echo "usage: ableton-linkctl start|stop|restart|status" >&2; exit 2 ;;' \
                    "$target" ;;
        "$ABLETON_DATA_HOME/setup-link.sh")
            ableton_file_has_no_nul "$target" \
                && [ "$(sed -n '1p' "$target")" = '#!/usr/bin/env bash' ] \
                && grep -qxF '# Enable, disable, or inspect the single persistent Ableton Link policy.' \
                    "$target" \
                && grep -qxF "legacy_policy_file=\"\$ABLETON_DATA_HOME/link-configured\"" \
                    "$target" \
                && grep -qxF '    enable) enable_link ;;' "$target" ;;
        "$ABLETON_DATA_HOME/ableton-linkd.service")
            cmp -s -- "$target" <(cat <<'EOF'
# Template only. setup-link.sh renders @ABLETON_LINKD@ to the one resolved
# executable path and adds the ownership marker before installing this unit.
[Unit]
Description=Ableton Link session anchor (ableton-linkd)
After=default.target
X-AbletonLinuxOwned=true

[Service]
ExecStart="@ABLETON_LINKD@" --linger 0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
            ) ;;
        *) return 1 ;;
    esac
}

generated_link_file_is_owned()
{
    local target="$1" expected current
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
    case "$target" in
        "$unit_file") unit_is_owned; return ;;
    esac
    expected="$(manifest_digest_for "$target" 2>/dev/null || true)"
    if [ -n "$expected" ]; then
        current="$(link_path_digest "$target" 2>/dev/null || true)"
        [ -n "$current" ] && [ "$current" = "$expected" ] && return 0
    fi
    legacy_link_file_is_owned "$target"
}

legacy_policy_file_is_owned()
{
    [ -f "$legacy_policy_file" ] && [ ! -L "$legacy_policy_file" ] \
        && [ -r "$legacy_policy_file" ] \
        && ableton_file_has_no_nul "$legacy_policy_file" \
        && [ "$(wc -l < "$legacy_policy_file")" -eq 1 ] || return 1
    case "$(sed -n '1p' "$legacy_policy_file")" in
        configured|declined) return 0 ;;
        *) return 1 ;;
    esac
}

link_binary_is_owned()
{
    local expected current
    [ "$ABLETON_LINKD" = "$ABLETON_DATA_HOME/ableton-linkd" ] || return 1
    expected="$(manifest_digest_for "$ABLETON_LINKD" 2>/dev/null || true)"
    if [ -n "$expected" ]; then
        current="$(link_path_digest "$ABLETON_LINKD" 2>/dev/null || true)"
        [ -n "$current" ] && [ "$current" = "$expected" ] && return 0
    fi
    legacy_link_file_is_owned "$ABLETON_LINKD"
}

link_path_digest()
{
    if [ -L "$1" ]; then
        { printf 'symlink\0'; readlink -n -- "$1"; } | sha256sum | awk '{print $1}'
    elif [ -f "$1" ]; then
        sha256sum -- "$1" | awk '{print $1}'
    else
        return 1
    fi
}

link_cleanup_warning()
{
    link_residual=1
    printf '!! %s\n' "$*" >&2 || true
    return 0
}

remove_owned_link_file()
{
    local target="$1" before current
    [ -e "$target" ] || [ -L "$target" ] || return 0
    if ! generated_link_file_is_owned "$target"; then
        printf '!! Kept %s because it does not match a file installed by Ableton Linux\n' \
            "$target" >&2 || true
        return 0
    fi
    before="$(ableton_object_token "$target" 2>/dev/null || true)"
    current="$(ableton_object_token "$target" 2>/dev/null || true)"
    if [ -z "$before" ] || [ "$current" != "$before" ] \
       || ! generated_link_file_is_owned "$target"; then
        printf '!! Kept %s because it changed while Ableton Link was being turned off\n' \
            "$target" >&2 || true
        return 0
    fi
    rm -f -- "$target" 2>/dev/null || true
    [ ! -e "$target" ] && [ ! -L "$target" ] || \
        link_cleanup_warning "An obsolete Link file could not be removed: $target"
}

remove_legacy_policy_file()
{
    local before current
    [ -e "$legacy_policy_file" ] || [ -L "$legacy_policy_file" ] || return 0
    if ! legacy_policy_file_is_owned; then
        printf '!! Kept %s because it is not an old Ableton Linux Link setting\n' \
            "$legacy_policy_file" >&2 || true
        return 0
    fi
    before="$(ableton_object_token "$legacy_policy_file" 2>/dev/null || true)"
    current="$(ableton_object_token "$legacy_policy_file" 2>/dev/null || true)"
    if [ -z "$before" ] || [ "$current" != "$before" ] \
       || ! legacy_policy_file_is_owned; then
        printf '!! Kept %s because it changed while Ableton Link was being updated\n' \
            "$legacy_policy_file" >&2 || true
        return 0
    fi
    rm -f -- "$legacy_policy_file" 2>/dev/null || true
    [ ! -e "$legacy_policy_file" ] && [ ! -L "$legacy_policy_file" ] || \
        link_cleanup_warning "The old Link setting could not be removed: $legacy_policy_file"
}

prune_link_metadata()
{
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    local index="$ABLETON_STATE_HOME/install-prestate.tsv" tmp="" target id
    local legacy_custom="${ABLETON_PR182_CUSTOM_LINKD:-}"
    local -a targets=("$ABLETON_DATA_HOME/ableton-linkd" "$data_unit" "$linkctl" \
        "$ABLETON_DATA_HOME/setup-link.sh")
    if [ -e "$manifest" ] || [ -L "$manifest" ]; then
        if [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] \
           && tmp="$(mktemp "$ABLETON_STATE_HOME/.installed-files-link.XXXXXX")" \
           && awk -F '\t' -v a="${targets[0]}" -v b="${targets[1]}" \
                -v c="${targets[2]}" -v d="${targets[3]}" \
                -v e="$legacy_custom" \
                '$2 != a && $2 != b && $2 != c && $2 != d && (e == "" || $2 != e)' \
                "$manifest" > "$tmp" \
           && chmod 600 "$tmp" && mv -f -- "$tmp" "$manifest"; then
            :
        else
            [ -z "$tmp" ] || rm -f -- "$tmp"
            link_cleanup_warning "Old Link file records could not be updated; a later installer run can rebuild them"
        fi
    fi
    if [ -e "$index" ] || [ -L "$index" ]; then
        tmp=""
        if [ -f "$index" ] && [ ! -L "$index" ] && [ -r "$index" ] \
           && tmp="$(mktemp "$ABLETON_STATE_HOME/.old-link-files.XXXXXX")" \
           && awk -F '\t' -v a="${targets[0]}" -v b="${targets[1]}" \
                -v c="${targets[2]}" -v d="${targets[3]}" \
                '$2 != a && $2 != b && $2 != c && $2 != d' \
                "$index" > "$tmp" \
           && chmod 600 "$tmp" && mv -f -- "$tmp" "$index"; then
            for target in "${targets[@]}"; do
                id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')" \
                    || continue
                rm -f -- "$ABLETON_STATE_HOME/install-prestate/$id" 2>/dev/null || true
                [ ! -e "$ABLETON_STATE_HOME/install-prestate/$id" ] \
                    && [ ! -L "$ABLETON_STATE_HOME/install-prestate/$id" ] || \
                    link_cleanup_warning "An obsolete Link backup could not be removed"
            done
        else
            [ -z "$tmp" ] || rm -f -- "$tmp"
            link_cleanup_warning "Old Link restoration records could not be updated; they will be ignored"
        fi
    fi
}

disable_link()
{
    local firewall_trusted=1
    trap 'if [ "$LINK_DISABLE_COMMITTED" -eq 1 ]; then exit 0; else exit 130; fi' INT
    trap 'if [ "$LINK_DISABLE_COMMITTED" -eq 1 ]; then exit 0; else exit 143; fi' TERM
    # Repair project settings before any firewall or service change. A later
    # genuine host failure must not leave an interrupted old generation behind.
    if [ "${ABLETON_CONFIG_REPAIR_NEEDED:-0}" = 1 ]; then
        if ! save_link_mode; then
            echo "!! Installer settings could not be repaired yet; continuing with the Link change" >&2
        fi
    fi
    printf '%s\n' "== turn off Ableton Link ==" || true
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
    # From here on the requested external Link state is off. Generated-file,
    # preference, and terminal cleanup cannot turn that completed outcome into
    # an installer failure.
    set +e
    remove_owned_link_file "$unit_file"
    # Clear the directory if nothing else is using it.
    rmdir --ignore-fail-on-non-empty -- "$unit_dir" 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
        ableton_run_bounded 20 systemctl --user daemon-reload >/dev/null 2>&1 || \
            link_cleanup_warning "The user-service list will refresh at the next login"
    fi
    remove_owned_link_file "$ABLETON_DATA_HOME/ableton-linkd"
    if [ -n "${ABLETON_PR182_CUSTOM_LINKD:-}" ]; then
        echo "   Kept the older custom Link helper at $ABLETON_PR182_CUSTOM_LINKD"
    fi
    if [ "$ABLETON_LINKD" != "$ABLETON_DATA_HOME/ableton-linkd" ]; then
        echo "   Kept the external Link helper at $ABLETON_LINKD"
    fi
    remove_owned_link_file "$data_unit"
    remove_owned_link_file "$linkctl"
    remove_owned_link_file "$ABLETON_DATA_HOME/setup-link.sh"
    prune_link_metadata
    remove_legacy_policy_file
    if [ "$LINK_COORDINATED_ACTION" -ne 1 ]; then
        if [ "$LINK_SETTING_SAVED" -ne 1 ]; then
            echo "OK: Ableton Link is off; run the installer again to save that preference"
        elif [ "$link_residual" -eq 0 ]; then
            echo "OK: Ableton Link is off"
        else
            echo "OK: Ableton Link is off; some obsolete local files can be cleaned up by a later installer run"
        fi
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
    local tmp="" expected="" actual=""
    if [ -L "$ABLETON_CONFIG_FILE" ]; then
        echo "!! Ableton Link left the settings symlink unchanged: $ABLETON_CONFIG_FILE" >&2
        return 1
    fi
    if [ -d "$ABLETON_CONFIG_FILE" ] && [ ! -L "$ABLETON_CONFIG_FILE" ]; then
        echo "!! Ableton Link cannot replace a directory at $ABLETON_CONFIG_FILE" >&2
        return 1
    fi
    if [ -e "$ABLETON_CONFIG_FILE" ] && [ ! -f "$ABLETON_CONFIG_FILE" ]; then
        echo "!! Ableton Link left the non-file settings object unchanged: $ABLETON_CONFIG_FILE" >&2
        return 1
    fi
    mkdir -p -- "$ABLETON_CONFIG_HOME" || return 1
    tmp="$(mktemp "$ABLETON_CONFIG_HOME/.config.XXXXXX")" || return 1
    if ! chmod 600 "$tmp" \
       || ! ableton_render_config > "$tmp" \
       || ! ableton_managed_config_valid "$tmp"; then
        rm -f -- "$tmp"
        echo "!! Ableton Link could not save its setting" >&2
        return 1
    fi
    expected="$(ableton_config_object_token "$tmp")" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -T -f -- "$tmp" "$ABLETON_CONFIG_FILE" 2>/dev/null || true
    actual="$(ableton_config_object_token "$ABLETON_CONFIG_FILE" 2>/dev/null || true)"
    if [ "$actual" != "$expected" ] \
       || ! ableton_managed_config_valid "$ABLETON_CONFIG_FILE"; then
        rm -f -- "$tmp"
        echo "!! Ableton Link could not save its setting" >&2
        return 1
    fi
    [ ! -e "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || \
        echo "!! Temporary Link settings could not be removed: $tmp" >&2
    # This checksum only coordinates later installer helpers. The settings file
    # above is already complete and verified, so bookkeeping cannot undo it.
    ableton_config_snapshot_capture >/dev/null 2>&1 || true
    ABLETON_CONFIG_REPAIR_NEEDED=0
    export ABLETON_CONFIG_REPAIR_NEEDED
}

install_unit()
{
    local loaded_fragment="" tmp=""
    [ -x "$ABLETON_LINKD" ] || {
        echo "!! The Ableton Link helper is missing. Re-run the installer to restore it." >&2
        return 1
    }
    if [ -d "$unit_file" ] && [ ! -L "$unit_file" ]; then
        echo "!! Ableton Link cannot replace a directory at $unit_file" >&2
        return 1
    fi
    if systemd_user_available; then
        if ! loaded_fragment="$(ableton_run_bounded 20 systemctl --user show \
                -p FragmentPath --value ableton-linkd.service 2>/dev/null)"; then
            echo "!! Ableton Link could not inspect the user service" >&2
            return 1
        fi
        if [ -n "$loaded_fragment" ] && [ "$(ableton_realpath_m "$loaded_fragment")" != "$(ableton_realpath_m "$unit_file")" ]; then
            echo "!! Another user service already uses the name ableton-linkd.service: $loaded_fragment" >&2
            return 1
        fi
    fi
    mkdir -p -- "$unit_dir" || {
        echo "!! Ableton Link could not create its user-service directory" >&2
        return 1
    }
    tmp="$(mktemp "$unit_dir/.ableton-linkd.service.XXXXXX")" || return 1
    if ! render_owned_link_unit > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! chmod 644 "$tmp"; then
        rm -f -- "$tmp"
        echo "!! Ableton Link could not write its user service" >&2
        return 1
    fi
    mv -T -f -- "$tmp" "$unit_file" 2>/dev/null || true
    if ! unit_is_owned; then
        rm -f -- "$tmp"
        echo "!! Ableton Link could not write its user service" >&2
        return 1
    fi
    [ ! -e "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || \
        echo "!! Temporary Link service files could not be removed: $tmp" >&2
    # This writes the unit for a later session either way. With no running user
    # manager there is nothing to reload, and session policy never needs it.
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
            echo "   Checking the ufw rule for Link (UDP 20808)"
            ufw_link_rule_state || rule_state=$?
            if [ "$rule_state" -eq 1 ]; then
                echo "   Restoring the missing ufw rule for Link"
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
            echo "   Checking the firewalld rule for Link (UDP 20808)"
            if command -v firewall-cmd >/dev/null 2>&1 \
               && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
                firewalld_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    echo "   Restoring the missing firewalld rule for Link"
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
                    echo "   Restoring the missing firewalld rule for Link"
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
            echo "   ufw already allows UDP 20808; leaving the existing rule unchanged"
        elif [ "$rule_state" -eq 1 ]; then
            echo "   ufw is active: opening UDP 20808 for Ableton Link"
            write_link_firewall_state ufw-added || {
                echo "!! Ableton Link cannot safely track a new ufw rule" >&2
                return 1
            }
            # Persist ownership before ufw can make a partial change. The
            # caller's recovery can then remove only this attempted rule.
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
            echo "   firewalld already allows UDP 20808; leaving the existing rule unchanged"
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
            echo "   firewalld is active: opening UDP 20808 for Ableton Link"
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
        echo "   No active ufw or firewalld; the firewall is unchanged"
    fi
}

restore_firewall_record()
{
    local prior="$1" rc=0 rule_state=0
    ableton_mark_state_home || return 1
    case "$prior" in
        ufw-added)
            ufw_link_rule_state || rule_state=$?
            if [ "$rule_state" -eq 1 ]; then
                ableton_sudo_run_bounded 120 ufw allow 20808/udp || true
            elif [ "$rule_state" -ne 0 ]; then
                rc=1
            fi
            if [ "$rc" -eq 0 ]; then
                rule_state=0
                ufw_link_rule_state || rule_state=$?
                [ "$rule_state" -eq 0 ] || rc=1
            fi ;;
        firewalld-added)
            if command -v firewall-cmd >/dev/null 2>&1 \
               && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
                rule_state=0
                firewalld_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    ableton_sudo_run_bounded 120 firewall-cmd --permanent --add-port=20808/udp || true
                    ableton_sudo_run_bounded 120 firewall-cmd --reload || true
                elif [ "$rule_state" -ne 0 ]; then
                    rc=1
                fi
                if [ "$rc" -eq 0 ]; then
                    rule_state=0
                    firewalld_link_rule_state || rule_state=$?
                    [ "$rule_state" -eq 0 ] || rc=1
                fi
                if [ "$rc" -eq 0 ]; then
                    rule_state=0
                    firewalld_runtime_link_rule_state || rule_state=$?
                    [ "$rule_state" -eq 0 ] || rc=1
                fi
            elif command -v firewall-offline-cmd >/dev/null 2>&1; then
                rule_state=0
                firewalld_offline_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    ableton_sudo_run_bounded 120 \
                        firewall-offline-cmd --add-port=20808/udp || true
                elif [ "$rule_state" -ne 0 ]; then
                    rc=1
                fi
                if [ "$rc" -eq 0 ]; then
                    rule_state=0
                    firewalld_offline_link_rule_state || rule_state=$?
                    [ "$rule_state" -eq 0 ] || rc=1
                fi
            else
                rc=127
            fi ;;
        none|'') ;;
        *) echo "!! cannot restore unknown firewall record '$prior'" >&2; return 1 ;;
    esac
    [ "$rc" -eq 0 ] || return "$rc"
    write_link_firewall_state "$prior"
}

populate_link_transaction_snapshot()
{
    local snap="$1"
    printf '3\n' > "$snap/format" || return 1
    printf '%s\n' "$ABLETON_LINK_MODE" > "$snap/policy" || return 1
    snapshot_link_firewall_state "$snap/firewall" || return 1
    snapshot_legacy_network "$snap/legacy" || return 1
    snapshot_link_service_state "$snap" || return 1
    : > "$snap/ready" || return 1
}

snapshot_link_transaction()
{
    local snap="$transaction_dir/link" build="" entries=""
    ableton_txn_init || return 1
    if [ -e "$snap" ] || [ -L "$snap" ]; then
        [ -d "$snap" ] && [ ! -L "$snap" ] || {
            echo "!! Link transaction snapshot path is unsafe" >&2
            return 1
        }
        entries="$(find "$snap" -mindepth 1 -maxdepth 1 -print -quit)" || return 1
        if [ -n "$entries" ]; then
            if validate_link_transaction_snapshot; then
                return 0
            fi
            # This directory is generated by this helper inside the caller's
            # new work area. Rebuild it instead of making stale local data a gate.
            rm -rf -- "$snap" 2>/dev/null || true
            [ ! -e "$snap" ] && [ ! -L "$snap" ] || return 1
        else
            rmdir -- "$snap" 2>/dev/null || true
            [ ! -e "$snap" ] && [ ! -L "$snap" ] || return 1
        fi
    fi
    build="$(mktemp -d "$transaction_dir/.link-snapshot.XXXXXX")" || return 1
    if ! populate_link_transaction_snapshot "$build"; then
        rm -rf -- "$build" 2>/dev/null || true
        [ ! -e "$build" ] && [ ! -L "$build" ] || \
            echo "!! Temporary Link recovery files could not be removed: $build" >&2
        return 1
    fi
    if ! mv -T -n -- "$build" "$snap" \
       || [ -e "$build" ] || [ ! -d "$snap" ] || [ -L "$snap" ]; then
        [ ! -e "$build" ] || rm -rf -- "$build"
        echo "!! Ableton Link could not save the current firewall and service settings" >&2
        return 1
    fi
    validate_link_transaction_snapshot
}

link_snapshot_pair_valid()
{
    local base="$1" type="$2" absent_path="${3:-$1.absent}" present=0 absent=0 digest
    [ ! -e "$base" ] && [ ! -L "$base" ] || present=1
    [ ! -e "$absent_path" ] && [ ! -L "$absent_path" ] || absent=1
    [ $((present + absent)) -eq 1 ] || return 1
    if [ "$absent" -eq 1 ]; then
        [ -f "$absent_path" ] && [ ! -L "$absent_path" ] && [ ! -s "$absent_path" ]
        return
    fi
    case "$type" in
        regular)
            [ -f "$base" ] && [ ! -L "$base" ] && [ -r "$base" ] \
                && ableton_file_has_no_nul "$base" ;;
        object)
            { [ -f "$base" ] || [ -L "$base" ]; } \
                && digest="$(ableton_manifest_digest "$base" 2>/dev/null || true)" \
                && [ -n "$digest" ] ;;
        directory) [ -d "$base" ] && [ ! -L "$base" ] ;;
        marker) [ -f "$base" ] && [ ! -L "$base" ] && [ ! -s "$base" ] ;;
        *) return 1 ;;
    esac
}

validate_link_transaction_snapshot()
{
    local snap="$transaction_dir/link" prior name names_count=0 members=""
    [ ! -e "$snap" ] && [ ! -L "$snap" ] && return 0
    [ -d "$snap" ] && [ ! -L "$snap" ] || {
        echo "!! Link transaction snapshot is unsafe" >&2; return 1; }
    [ -f "$snap/ready" ] && [ ! -L "$snap/ready" ] && [ ! -s "$snap/ready" ] || {
        echo "!! Link transaction ready marker is invalid" >&2; return 1; }
    [ -f "$snap/format" ] && [ ! -L "$snap/format" ] \
        && [ "$(sed -n '1p' "$snap/format")" = 3 ] \
        && [ "$(wc -l < "$snap/format")" -eq 1 ] || {
        echo "!! Link transaction snapshot format is invalid" >&2; return 1; }
    [ -f "$snap/policy" ] && [ ! -L "$snap/policy" ] \
        && ableton_file_has_no_nul "$snap/policy" \
        && [ "$(wc -l < "$snap/policy")" -eq 1 ] || {
        echo "!! Link transaction policy is invalid" >&2; return 1; }
    prior="$(sed -n '1p' "$snap/policy")"
    case "$prior" in off|session|always) ;; *) echo "!! Link transaction policy is invalid" >&2; return 1 ;; esac
    members="$(find "$snap" -mindepth 1 -maxdepth 1 -printf '%f\n')" || return 1
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        names_count=$((names_count + 1))
        case "$name" in
            ready|format|policy|firewall|firewall.absent|manager|manager.absent|\
            enabled|enabled.absent|active|active.absent|\
            detached-active|detached-active.absent|legacy.hook|legacy.hook.absent|\
            legacy.route|legacy.route.absent) ;;
            *) echo "!! Link transaction snapshot has an unknown member: $name" >&2; return 1 ;;
        esac
    done <<< "$members"
    # format/ready/policy plus exactly one member from each of seven evidence
    # pairs below.
    [ "$names_count" -eq 10 ] || {
        echo "!! Link transaction snapshot inventory is incomplete" >&2; return 1; }
    if ! { link_snapshot_pair_valid "$snap/firewall" regular \
           && link_snapshot_pair_valid "$snap/manager" marker \
           && link_snapshot_pair_valid "$snap/enabled" marker \
           && link_snapshot_pair_valid "$snap/active" marker \
           && link_snapshot_pair_valid "$snap/detached-active" marker \
           && link_snapshot_pair_valid "$snap/legacy.hook" regular \
           && link_snapshot_pair_valid "$snap/legacy.route" regular; }; then
        echo "!! Link transaction present/absent evidence is invalid" >&2
        return 1
    fi
    [ ! -e "$snap/firewall" ] || link_firewall_record_valid "$snap/firewall" || {
        echo "!! Link firewall snapshot is invalid" >&2; return 1; }
    [ ! -e "$snap/legacy.hook" ] || {
        grep -qxF '#!/bin/sh' "$snap/legacy.hook" \
            && grep -qF "[ \"\$2\" = \"up\" ] || exit 0" "$snap/legacy.hook" \
            && grep -qF 'ip route replace 224.0.0.0/4' "$snap/legacy.hook"; } || {
        echo "!! Link legacy-hook snapshot is invalid" >&2; return 1; }
    if [ -e "$snap/legacy.route" ]; then
        case "$(sed -n '1p' "$snap/legacy.route")" in 224.0.0.0/4\ *) ;; *)
            echo "!! Link legacy-route snapshot is invalid" >&2; return 1 ;; esac
    fi
}

preflight_link_transaction()
{
    local snap="$transaction_dir/link"
    validate_link_transaction_snapshot || return 1
    validate_link_firewall_state || {
        echo "!! Link firewall information changed before the previous system settings could be restored" >&2
        return 1
    }
    legacy_network_safe_for_restore "$snap/legacy" || {
        echo "!! The old multicast route changed before it could be restored" >&2
        return 1
    }
}

preflight_link_commit_transaction()
{
    # Successful Link actions do not depend on disposable recovery files.
    return 0
}

rollback_link_transaction()
{
    local snap="$transaction_dir/link" rc=0
    preflight_link_transaction || return 1
    [ -e "$snap/ready" ] || return 0
    quiesce_link_process_state_for_restore "$snap" || rc=$?
    [ "$rc" -ne 0 ] || restore_firewall_snapshot "$snap/firewall" || rc=$?
    [ "$rc" -ne 0 ] || restore_legacy_network "$snap/legacy" || rc=$?
    [ "$rc" -ne 0 ] || restore_link_process_state "$snap" || rc=$?
    [ "$rc" -ne 0 ] || firewall_matches_snapshot "$snap/firewall" || rc=1
    [ "$rc" -ne 0 ] || legacy_network_matches_snapshot "$snap/legacy" || rc=1
    [ "$rc" -eq 0 ] || {
        echo "!! The previous Link firewall or service settings could not be fully restored" >&2
        return "$rc"
    }
    rm -rf -- "$snap" 2>/dev/null || true
    [ ! -e "$snap" ] && [ ! -L "$snap" ] || \
        echo "!! Temporary Link recovery files could not be removed: $snap" >&2 || true
    return 0
}

commit_link_transaction()
{
    local snap="$transaction_dir/link"
    [ -e "$snap" ] || [ -L "$snap" ] || return 0
    if [ -d "$snap" ] && [ ! -L "$snap" ]; then
        rm -rf -- "$snap" 2>/dev/null || true
        [ ! -e "$snap" ] && [ ! -L "$snap" ] || \
            echo "!! Temporary Link recovery files could not be removed: $snap" >&2 || true
    else
        echo "!! Temporary Link recovery files could not be removed: $snap" >&2 || true
    fi
    return 0
}

plan_link()
{
    local output=""
    if [ "$action" = plan-disable ]; then
        echo "PLAN: Turn off Ableton Link"
        echo '  Stop the Ableton Link service and helper'
        [ ! -r "$state_file" ] || echo '  Remove the firewall rule added for Link'
        [ ! -e "$legacy_hook" ] || echo '  Remove the old Link multicast route'
        echo '  Remove generated Link files and save Link as off'
        return 0
    fi
    echo "PLAN: Enable Ableton Link"
    [ ! -e "$legacy_hook" ] || echo '  Remove the old Link multicast route'
    if command -v ufw >/dev/null 2>&1 && grep -qsi '^ENABLED=yes' /etc/ufw/ufw.conf; then
        if output="$(ableton_run_bounded 20 ufw status 2>/dev/null)"; then
            if grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)' \
                <<< "$output"; then
                echo '  Keep the existing UFW rule for UDP 20808'
            else
                echo '  Open UDP 20808 with UFW'
            fi
        else
            echo '  Check UFW and open UDP 20808 if needed'
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 \
         && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
        if output="$(ableton_run_bounded 20 firewall-cmd --permanent --list-ports 2>/dev/null)"; then
            if grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)' \
                <<< "$output"; then
                echo '  Keep the existing firewalld rule for UDP 20808'
            else
                echo '  Open UDP 20808 with firewalld'
            fi
        else
            echo '  Check firewalld and open UDP 20808 if needed'
        fi
    else
        echo '  Leave the firewall unchanged'
    fi
    case "$mode" in
        session) echo '  Start Link only while Ableton Live is running' ;;
        always) echo '  Start Link in the background with your user session' ;;
    esac
    echo '  Save the Link setting'
}

ABLETON_LINK_ENABLE_RECOVERY_ERROR=""
link_enable_recovery_error()
{
    ABLETON_LINK_ENABLE_RECOVERY_ERROR="${ABLETON_LINK_ENABLE_RECOVERY_ERROR}${ABLETON_LINK_ENABLE_RECOVERY_ERROR:+; }$1"
}

populate_link_enable_snapshot()
{
    local snapshot="$1"
    printf '3\n' > "$snapshot/format" || return 1
    : > "$snapshot/local-recovery" || return 1
    snapshot_link_firewall_state "$snapshot/firewall" || return 1
    snapshot_legacy_network "$snapshot/legacy" || return 1
    snapshot_link_service_state "$snapshot" || return 1
    : > "$snapshot/ready" || return 1
}

LINK_ENABLE_UNSTARTED_SNAPSHOT=""
LINK_ENABLE_ACTIVE_SNAPSHOT=""
LINK_ENABLE_COMMITTED=0
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_link_enable_snapshot()
{
    local rc=$?
    trap - EXIT
    case "$LINK_ENABLE_UNSTARTED_SNAPSHOT" in
        "$ABLETON_STATE_HOME"/.link-enable.*)
            if [ -d "$LINK_ENABLE_UNSTARTED_SNAPSHOT" ] \
               && [ ! -L "$LINK_ENABLE_UNSTARTED_SNAPSHOT" ]; then
                rm -rf -- "$LINK_ENABLE_UNSTARTED_SNAPSHOT" 2>/dev/null || true
                [ ! -e "$LINK_ENABLE_UNSTARTED_SNAPSHOT" ] \
                    && [ ! -L "$LINK_ENABLE_UNSTARTED_SNAPSHOT" ] || \
                    echo "!! Temporary Link recovery files could not be removed: $LINK_ENABLE_UNSTARTED_SNAPSHOT" >&2
            fi ;;
    esac
    exit "$rc"
}

validate_link_enable_snapshot()
{
    local snapshot="$1" name members
    [ -d "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    [ -f "$snapshot/format" ] && [ "$(sed -n '1p' "$snapshot/format")" = 3 ] \
        && [ -f "$snapshot/ready" ] && [ ! -s "$snapshot/ready" ] \
        && [ -f "$snapshot/local-recovery" ] && [ ! -s "$snapshot/local-recovery" ] \
        || return 1
    members="$(find "$snapshot" -mindepth 1 -maxdepth 1 -printf '%f\n')" || return 1
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$name" in
            format|ready|local-recovery|firewall|firewall.absent|\
            manager|manager.absent|enabled|enabled.absent|active|active.absent|\
            detached-active|detached-active.absent|legacy.hook|legacy.hook.absent|\
            legacy.route|legacy.route.absent|\
            service-mutating|detached-mutating|FAILURE) ;;
            *) return 1 ;;
        esac
    done <<< "$members"
    link_snapshot_pair_valid "$snapshot/firewall" regular \
        && link_snapshot_pair_valid "$snapshot/manager" marker \
        && link_snapshot_pair_valid "$snapshot/enabled" marker \
        && link_snapshot_pair_valid "$snapshot/active" marker \
        && link_snapshot_pair_valid "$snapshot/detached-active" marker \
        && link_snapshot_pair_valid "$snapshot/legacy.hook" regular \
        && link_snapshot_pair_valid "$snapshot/legacy.route" regular || return 1
    [ ! -e "$snapshot/firewall" ] || link_firewall_record_valid "$snapshot/firewall" || return 1
    for name in service-mutating detached-mutating; do
        [ ! -e "$snapshot/$name" ] \
            || { [ -f "$snapshot/$name" ] && [ ! -L "$snapshot/$name" ] \
                 && [ ! -s "$snapshot/$name" ]; } || return 1
    done
}

write_link_enable_failure()
{
    local snapshot="$1" operation_rc="$2"
    printf 'operation=enable\noperation_exit=%s\nrestoration_complete=no\nrestoration_error=%s\n' \
        "$operation_rc" "$ABLETON_LINK_ENABLE_RECOVERY_ERROR" \
        > "$snapshot/FAILURE" 2>/dev/null || true
}

restore_link_enable_snapshot()
{
    local snapshot="$1" operation_rc="$2" recovery_rc=0
    ABLETON_LINK_ENABLE_RECOVERY_ERROR=""
    validate_link_enable_snapshot "$snapshot" || {
        ABLETON_LINK_ENABLE_RECOVERY_ERROR="the saved firewall or service state is incomplete"
        write_link_enable_failure "$snapshot" "$operation_rc"
        return 1
    }
    legacy_network_safe_for_restore "$snapshot/legacy" || {
        link_enable_recovery_error "the old multicast route changed"
        recovery_rc=1
    }
    [ "$recovery_rc" -eq 0 ] || {
        write_link_enable_failure "$snapshot" "$operation_rc"
        return 1
    }
    if [ "$recovery_rc" -eq 0 ] \
       && ! quiesce_link_process_state_for_restore "$snapshot"; then
        link_enable_recovery_error "the Link service could not be stopped"
        recovery_rc=1
    fi
    if [ "$recovery_rc" -eq 0 ] && ! restore_firewall_snapshot "$snapshot/firewall"; then
        link_enable_recovery_error "the previous firewall setting could not be restored"; recovery_rc=1
    fi
    if [ "$recovery_rc" -eq 0 ] && ! restore_legacy_network "$snapshot/legacy"; then
        link_enable_recovery_error "the previous multicast route could not be restored"; recovery_rc=1
    fi
    if [ "$recovery_rc" -eq 0 ] && ! restore_link_process_state "$snapshot"; then
        link_enable_recovery_error "the previous Link service state could not be restored"
        recovery_rc=1
    fi
    if [ "$recovery_rc" -eq 0 ]; then
        firewall_matches_snapshot "$snapshot/firewall" || recovery_rc=1
        legacy_network_matches_snapshot "$snapshot/legacy" || recovery_rc=1
        [ "$recovery_rc" -eq 0 ] \
            || link_enable_recovery_error "the restored firewall or service setting could not be verified"
    fi
    if [ "$recovery_rc" -eq 0 ]; then
        rm -rf -- "$snapshot" 2>/dev/null || true
        [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || \
            echo "!! Temporary Link recovery files could not be removed: $snapshot" >&2
        return 0
    fi
    write_link_enable_failure "$snapshot" "$operation_rc"
    return "$recovery_rc"
}

finish_link_enable_recovery()
{
    local snapshot="$1" operation_rc="$2"
    trap - EXIT
    # Once restoration starts, a second Ctrl-C/TERM must not interrupt the
    # recovery that the first signal requested. Every external step remains
    # bounded, so ignoring those signals here cannot hang indefinitely.
    trap '' INT TERM
    LINK_ENABLE_ACTIVE_SNAPSHOT=""
    if restore_link_enable_snapshot "$snapshot" "$operation_rc"; then
        echo "!! Ableton Link could not be enabled. The previous firewall and service settings were restored." >&2
        trap - INT TERM
        return "$LINK_ENABLE_RECOVERED_STATUS"
    fi
    echo "!! Ableton Link could not be enabled, and the previous system settings were not fully restored: $ABLETON_LINK_ENABLE_RECOVERY_ERROR" >&2
    echo "!! Recovery details were kept at $snapshot" >&2
    trap - INT TERM
    return "$LINK_ENABLE_INCOMPLETE_STATUS"
}

# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
link_enable_recovery_trap()
{
    local operation_rc="$1" outcome=0 snapshot="$LINK_ENABLE_ACTIVE_SNAPSHOT"
    trap - EXIT
    trap '' INT TERM
    set +e
    [ "$LINK_ENABLE_COMMITTED" -ne 1 ] || exit 0
    if [ -n "$snapshot" ]; then
        finish_link_enable_recovery "$snapshot" "$operation_rc" || outcome=$?
    else
        outcome="$operation_rc"
    fi
    exit "$outcome"
}

enable_link()
{
    # Availability check only, against a local: a packaged install stages
    # Packaged installs place the controller beside this script; repository
    # installs also keep a copy in the generated data directory.
    local ctl="$here/ableton-linkctl"
    [ -x "$ctl" ] || ctl="$linkctl"
    [ -x "$ctl" ] || {
        echo "!! The Ableton Link controller is missing. Re-run the installer to restore it." >&2
        return 1
    }
    [ -x "$ABLETON_LINKD" ] || {
        echo "!! The Ableton Link helper is missing. Re-run the installer to restore it." >&2
        return 1
    }
    echo "== enable Ableton Link =="
    local snapshot rc=0 outcome=0 enabled_status=0 active_status=0
    if [ "$mode" = always ] && ! systemd_user_available; then
        echo "!! Background Link mode needs a running systemd user session" >&2
        return 127
    fi
    # Publish a complete salvaged project configuration before the first host
    # mutation. The requested mode is saved separately after it is achieved.
    if [ "${ABLETON_CONFIG_REPAIR_NEEDED:-0}" = 1 ]; then
        if ! save_link_mode; then
            echo "!! Installer settings could not be repaired yet; continuing with the Link change" >&2
        fi
    fi
    ABLETON_LINK_MODE="$mode"
    export ABLETON_LINK_MODE
    ableton_mark_state_home || {
        echo "!! Ableton Link cannot safely save the firewall changes it may need to undo" >&2
        return 1
    }
    prepare_link_firewall_state_for_enable || return 1
    snapshot="$(mktemp -d "$ABLETON_STATE_HOME/.link-enable.XXXXXX")" || {
        echo "!! Ableton Link cannot save the current firewall and service settings, so nothing was changed" >&2
        return 1
    }
    LINK_ENABLE_UNSTARTED_SNAPSHOT="$snapshot"
    trap cleanup_unstarted_link_enable_snapshot EXIT
    if ! populate_link_enable_snapshot "$snapshot"; then
        rm -rf -- "$snapshot" 2>/dev/null || true
        [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || \
            echo "!! Temporary Link recovery files could not be removed: $snapshot" >&2
        LINK_ENABLE_UNSTARTED_SNAPSHOT=""
        trap - EXIT
        echo "!! Ableton Link cannot save the current firewall and service settings, so nothing was changed" >&2
        return 1
    fi
    if [ "$mode" = always ] && [ ! -e "$snapshot/manager" ]; then
        rm -rf -- "$snapshot" 2>/dev/null || true
        [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || \
            echo "!! Temporary Link recovery files could not be removed: $snapshot" >&2
        LINK_ENABLE_UNSTARTED_SNAPSHOT=""
        trap - EXIT
        echo "!! Background Link mode needs a running systemd user session" >&2
        return 127
    fi
    LINK_ENABLE_UNSTARTED_SNAPSHOT=""
    trap - EXIT
    LINK_ENABLE_ACTIVE_SNAPSHOT="$snapshot"
    trap 'link_enable_recovery_trap $?' EXIT
    trap 'link_enable_recovery_trap 130' INT
    trap 'link_enable_recovery_trap 143' TERM
    remove_owned_legacy_hook || rc=$?
    if [ "$rc" -eq 0 ]; then configure_firewall || rc=$?; fi
    if [ "$rc" -eq 0 ] && [ "$mode" = always ]; then
        if ! systemd_user_available; then
            echo "!! Background Link mode needs a running systemd user session" >&2
            rc=127
        else
            : > "$snapshot/service-mutating"
            stop_canonical_link_service || rc=$?
        fi
    fi
    if [ "$rc" -eq 0 ] && ! install_unit; then
        if [ "$mode" = always ]; then
            rc=1
        else
            link_cleanup_warning "The optional background Link service could not be prepared; Link will still run with Ableton Live"
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        finish_link_enable_recovery "$snapshot" "$rc" || outcome=$?
        return "$outcome"
    fi
    case "$mode" in
        session)
            if systemd_user_available; then
                : > "$snapshot/service-mutating"
            fi
            stop_canonical_link_service || rc=$? ;;
        always)
            : > "$snapshot/detached-mutating"
            stop_owned_detached_link_daemons || rc=$?
            [ "$rc" -ne 0 ] || \
                ableton_run_bounded 20 systemctl --user enable --now \
                    ableton-linkd.service || true ;;
    esac
    if [ "$rc" -ne 0 ]; then
        finish_link_enable_recovery "$snapshot" "$rc" || outcome=$?
        return "$outcome"
    fi
    if [ "$mode" = always ]; then
        ableton_run_bounded 20 systemctl --user is-enabled --quiet \
            ableton-linkd.service 2>/dev/null || enabled_status=$?
        ableton_run_bounded 20 systemctl --user is-active --quiet \
            ableton-linkd.service 2>/dev/null || active_status=$?
        [ "$enabled_status" -eq 0 ] && [ "$active_status" -eq 0 ] || rc=1
        [ -z "$(first_owned_link_pid)" ] || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        finish_link_enable_recovery "$snapshot" "$rc" || outcome=$?
        return "$outcome"
    fi
    if ! save_link_mode; then
        LINK_SETTING_SAVED=0
        echo "!! Ableton Link system changes completed, but its saved preference could not be updated" >&2
    fi
    LINK_ENABLE_COMMITTED=1
    LINK_ENABLE_ACTIVE_SNAPSHOT=""
    trap - EXIT
    trap '' INT TERM PIPE
    # The requested firewall/service state is now complete. Preference failure
    # was already reported and everything below is disposable cleanup/reporting.
    set +e
    remove_legacy_policy_file
    rm -rf -- "$snapshot" 2>/dev/null || true
    [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || \
        echo "!! Ableton Link is enabled, but temporary recovery files could not be removed: $snapshot" >&2
    if [ "$LINK_COORDINATED_ACTION" -ne 1 ]; then
        if [ "$LINK_SETTING_SAVED" -ne 1 ]; then
            echo "OK: Ableton Link system changes finished; run the installer again to save the preference"
        else
            case "$mode" in
                session) echo "OK: Ableton Link is enabled when Ableton Live is running" ;;
                always) echo "OK: Ableton Link is enabled in the background" ;;
            esac
        fi
    fi
    return 0
}

case "$action" in
    enable) enable_link ;;
    disable) disable_link ;;
    status)
        case "$ABLETON_LINK_MODE" in
            off) echo 'mode: off' ;;
            session) echo 'mode: session (while Ableton Live is running)' ;;
            always) echo 'mode: always (background)' ;;
        esac
        status_pid=""
        if [ "$ABLETON_LINK_MODE" = always ] && loaded_unit_is_owned \
           && ableton_run_bounded 20 systemctl --user is-active --quiet \
                ableton-linkd.service 2>/dev/null; then
            echo 'state: running (systemd)'
        elif status_pid="$(first_owned_link_pid)" \
             && [ -n "$status_pid" ]; then
            printf 'state: running (pid %s)\n' "$status_pid"
        elif [ -x "$ABLETON_LINKD" ]; then
            echo 'state: stopped'
        else
            echo 'state: not installed'
        fi
        if ! validate_link_firewall_state; then
            echo 'firewall: unknown (the saved Link firewall information is unreadable)'
        elif [ ! -r "$state_file" ]; then
            echo 'firewall: unchanged'
        else
            case "$(sed -n '1p' "$state_file")" in
                ufw-added) echo 'firewall: UDP 20808 opened with ufw' ;;
                firewalld-added) echo 'firewall: UDP 20808 opened with firewalld' ;;
                none) echo 'firewall: unchanged' ;;
            esac
        fi
        ;;
    snapshot) snapshot_link_transaction ;;
    preflight-rollback) preflight_link_transaction ;;
    preflight-commit) preflight_link_commit_transaction ;;
    rollback) rollback_link_transaction ;;
    commit) commit_link_transaction ;;
    plan-enable|plan-disable) plan_link ;;
esac
