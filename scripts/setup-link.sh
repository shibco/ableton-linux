#!/usr/bin/env bash
# Enable, disable, or inspect the single persistent Ableton Link policy.
# Firewall and service state are recorded under XDG_STATE_HOME so uninstall can
# reverse only changes made by this project.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for lib in "$here/lib/config.sh" "$here/config.sh" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 || { echo "!! setup-link: config helper is missing" >&2; exit 1; }
ableton_config_init
for lib in "$here/lib/manifest.sh" "$ABLETON_DATA_HOME/lib/manifest.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_validate_install_state_journals >/dev/null 2>&1 || {
    echo "!! setup-link: ownership helper is missing" >&2; exit 1; }

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
case "$action" in
    enable|disable|snapshot|preflight-rollback|preflight-commit|rollback|commit)
        ableton_install_lock_acquire
        ableton_validate_install_state_journals ;;
    status)
        # status reads the manifest, so check it.  Taking the install lock would
        # fail status during the install someone is asking about.  Skip the
        # prestate journals: status never reads them, and an install writes them
        # in two steps, so an unlocked read can catch them half written.
        ableton_validate_ownership_manifest ;;
esac

state_file="$ABLETON_STATE_HOME/link-firewall"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit_file="$unit_dir/ableton-linkd.service"
data_unit="$ABLETON_DATA_HOME/ableton-linkd.service"
linkctl="$ABLETON_DATA_HOME/ableton-linkctl"
link_pid_file="${XDG_RUNTIME_DIR:-$ABLETON_STATE_HOME/run}/ableton-wine/linkd.pid"
legacy_hook=/etc/NetworkManager/dispatcher.d/50-link-multicast
link_residual=0
declare -A link_deowned=()

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
            echo "!! timed out waiting for the Link lifecycle lock" >&2
            exit 1
        }
        stop_owned_detached_link_daemons_locked
    ) 9> "${link_pid_file%/*}/linkd.lock"
}

stop_owned_detached_link_daemons_locked()
{
    local pid exe want running=0 failed=0
    local -a pids=()
    mapfile -t pids < <(owned_link_pids)
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
        echo "!! could not stop every project-owned detached Link daemon" >&2
        return 1
    }
    rm -f -- "$link_pid_file"
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
    if command -v systemctl >/dev/null 2>&1; then
        ableton_run_bounded 20 systemctl --user disable --now \
            ableton-linkd.service >/dev/null 2>&1 || {
            echo "!! could not stop the project-owned Link service" >&2
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
    link_firewall_record_valid "$state_file"
}

write_link_firewall_state()
{
    local value="$1" tmp token
    case "$value" in ufw-added|firewalld-added|none) ;; *) return 1 ;; esac
    ableton_mark_state_home || return 1
    ableton_txn_snapshot "$state_file" || return 1
    tmp="$(mktemp "$ABLETON_STATE_HOME/.link-firewall.XXXXXX")" || return 1
    if ! printf '%s\n' "$value" > "$tmp" \
       || ! chmod 600 "$tmp" \
       || ! link_firewall_record_valid "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    token="$(ableton_object_token "$tmp")" || { rm -f -- "$tmp"; return 1; }
    ableton_txn_expect "$state_file" "$token" || { rm -f -- "$tmp"; return 1; }
    if ! mv -T -f -- "$tmp" "$state_file" || ! link_firewall_record_valid "$state_file"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Return 0 when the rule exists, 1 when a successful query proves it absent,
# and 2 when the firewall state could not be read.
ufw_link_rule_state()
{
    local output
    output="$(ableton_sudo_run_bounded 120 ufw status)" || return 2
    printf '%s\n' "$output" \
        | grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)'
}

firewalld_link_rule_state()
{
    local output
    output="$(ableton_sudo_run_bounded 120 \
        firewall-cmd --permanent --list-ports)" || return 2
    printf '%s\n' "$output" | tr ' ' '\n' | grep -qxF 20808/udp
}

firewalld_offline_link_rule_state()
{
    local output
    output="$(ableton_sudo_run_bounded 120 \
        firewall-offline-cmd --list-ports)" || return 2
    printf '%s\n' "$output" | tr ' ' '\n' | grep -qxF 20808/udp
}

remove_owned_firewall()
{
    validate_link_firewall_state || {
        echo "!! unsafe Link firewall ownership record: $state_file" >&2
        return 1
    }
    [ ! -e "$state_file" ] && [ ! -L "$state_file" ] && return 0
    local state rc=0 rule_state=0
    state="$(sed -n '1p' "$state_file")"
    # Record the ownership file before changing the matching system rule. If a
    # later command fails, the outer transaction can still restore both.
    ableton_txn_snapshot "$state_file" || return 1
    case "$state" in
        ufw-added)
            echo "-- removing the project-owned ufw allowance for UDP 20808"
            ufw_link_rule_state || rule_state=$?
            if [ "$rule_state" -eq 0 ]; then
                ableton_sudo_run_bounded 120 ufw delete allow 20808/udp || rc=$?
            elif [ "$rule_state" -ne 1 ]; then
                rc=1
            fi ;;
        firewalld-added)
            echo "-- removing the project-owned firewalld allowance for UDP 20808"
            if command -v firewall-cmd >/dev/null 2>&1 \
               && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
                firewalld_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 0 ]; then
                    ableton_sudo_run_bounded 120 firewall-cmd --permanent --remove-port=20808/udp || rc=$?
                    [ "$rc" -ne 0 ] || ableton_sudo_run_bounded 120 firewall-cmd --reload || rc=$?
                elif [ "$rule_state" -ne 1 ]; then
                    rc=1
                fi
            elif command -v firewall-offline-cmd >/dev/null 2>&1; then
                firewalld_offline_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 0 ]; then
                    ableton_sudo_run_bounded 120 \
                        firewall-offline-cmd --remove-port=20808/udp || rc=$?
                elif [ "$rule_state" -ne 1 ]; then
                    rc=1
                fi
            else
                rc=127
            fi ;;
        none|'') ;;
        *) echo "!! unrecognised Link firewall ownership record: $state_file" >&2; return 1 ;;
    esac
    [ "$rc" -eq 0 ] || { echo "!! failed to remove the recorded Link firewall rule" >&2; return "$rc"; }
    ableton_txn_expect "$state_file" absent || return 1
    rm -f -- "$state_file"
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
        return 0
    fi
    [ ! -e "$state_file" ] && [ ! -L "$state_file" ] \
        || remove_owned_firewall || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ -r "$snapshot" ]; then
        restore_firewall_record "$prior"
    else
        ableton_txn_snapshot "$state_file" || return 1
        ableton_txn_expect "$state_file" absent || return 1
        rm -f -- "$state_file"
    fi
}

legacy_hook_is_owned()
{
    [ -f "$legacy_hook" ] && [ ! -L "$legacy_hook" ] \
        && grep -qxF '#!/bin/sh' "$legacy_hook" 2>/dev/null \
        && grep -qF '[ "$2" = "up" ] || exit 0' "$legacy_hook" 2>/dev/null \
        && grep -qF 'ip route replace 224.0.0.0/4' "$legacy_hook" 2>/dev/null
}

snapshot_legacy_network()
{
    local destination="$1" route_line=""
    if legacy_hook_is_owned; then
        cp -a -- "$legacy_hook" "$destination.hook" || return 1
    else
        : > "$destination.hook.absent" || return 1
    fi
    route_line="$(ip -4 route show 224.0.0.0/4 2>/dev/null | head -n 1 || true)"
    if [ -n "$route_line" ]; then
        printf '%s\n' "$route_line" > "$destination.route" || return 1
    else
        : > "$destination.route.absent" || return 1
    fi
}

restore_legacy_network()
{
    local snapshot="$1" mode route_line
    [ -e "$snapshot.hook" ] || return 0
    if [ -e "$legacy_hook" ] && ! legacy_hook_is_owned; then
        echo "!! refusing to overwrite unrecognised legacy-hook path $legacy_hook during rollback" >&2
        return 1
    fi
    mode="$(stat -c '%a' "$snapshot.hook")"
    ableton_sudo_run_bounded 120 install -m "$mode" -- "$snapshot.hook" "$legacy_hook"
    route_line="$(sed -n '1p' "$snapshot.route" 2>/dev/null || true)"
    if [ -n "$route_line" ]; then
        local -a route_args=()
        read -r -a route_args <<< "$route_line"
        [ "${route_args[0]:-}" = 224.0.0.0/4 ] || {
            echo "!! refusing malformed legacy route snapshot" >&2; return 1; }
        ableton_sudo_run_bounded 120 ip route replace "${route_args[@]}"
    fi
}

remove_owned_legacy_hook()
{
    local route_line=""
    [ -e "$legacy_hook" ] || return 0
    if ! legacy_hook_is_owned; then
        echo "!! keeping unrecognised legacy-hook path $legacy_hook" >&2
        return 0
    fi
    command -v ip >/dev/null 2>&1 || {
        echo "!! cannot inspect the project-owned legacy multicast route because ip is missing" >&2
        return 127
    }
    route_line="$(ip -4 route show 224.0.0.0/4 2>/dev/null | head -n 1)" || {
        echo "!! could not inspect the project-owned legacy multicast route" >&2
        return 1
    }
    echo "-- removing the project-owned legacy multicast hook"
    if [ -n "$route_line" ]; then
        ableton_sudo_run_bounded 120 ip route del 224.0.0.0/4 >/dev/null
    fi
    ableton_sudo_run_bounded 120 rm -f -- "$legacy_hook"
}

manifest_digest_for()
{
    local wanted="$1" kind path digest manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    [ -r "$manifest" ] || return 1
    while IFS=$'\t' read -r kind path digest; do
        [ "$kind" = file ] && [ "$path" = "$wanted" ] || continue
        printf '%s\n' "$digest"
        return 0
    done < "$manifest"
    return 1
}

legacy_link_file_is_owned()
{
    local target="$1"
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
    case "$target" in
        "$ABLETON_DATA_HOME/ableton-linkd")
            strings "$target" 2>/dev/null | grep -qF 'ableton-linkd: native Ableton Link session anchor and probe' ;;
        "$ABLETON_DATA_HOME/ableton-linkctl")
            grep -qF 'Project-owned Ableton Link lifecycle controller' "$target" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/setup-link.sh")
            grep -qF 'Ableton Link setup' "$target" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/ableton-linkd.service")
            grep -qF 'ableton-linkd' "$target" 2>/dev/null ;;
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
        [ -n "$current" ] && [ "$current" = "$expected" ]
        return
    fi
    legacy_link_file_is_owned "$ABLETON_LINKD"
}

remove_owned_link_file()
{
    local target="$1" expected current
    expected="$(manifest_digest_for "$target" 2>/dev/null || true)"
    if [ -n "$expected" ]; then
        current="$(link_path_digest "$target" 2>/dev/null || true)"
        if [ "$current" != "$expected" ]; then
            echo "!! keeping modified Link file $target" >&2
            ableton_abandon_managed_file "$target" || return 1
            link_deowned["$target"]=1
            link_residual=1
            return 0
        fi
    elif ! legacy_link_file_is_owned "$target"; then
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
            ableton_remove_managed_file "$target" || return 1
            link_deowned["$target"]=1
            return 0
        fi
        echo "!! keeping unowned Link path $target" >&2
        link_residual=1
        return 0
    fi
    ableton_remove_managed_file "$target" || return 1
    link_deowned["$target"]=1
}

LINK_PRESTATE_BACKUP=""
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

validate_link_prestate()
{
    local target="$1" index="$ABLETON_STATE_HOME/install-prestate.tsv"
    local backup expected count
    LINK_PRESTATE_BACKUP=""
    [ -r "$index" ] || return 0
    count="$(awk -F '\t' -v p="$target" '$1=="present" && $2==p { n++ } END { print n+0 }' "$index")"
    [ "$count" -le 1 ] || {
        echo "!! Link pre-install state is ambiguous for $target" >&2; return 1; }
    [ "$count" -eq 1 ] || return 0
    backup="$(awk -F '\t' -v p="$target" '$1=="present" && $2==p { print $3; exit }' "$index")"
    expected="$ABLETON_STATE_HOME/install-prestate/$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
    if [ "$backup" != "$expected" ] || [ ! -e "$backup" ] \
       || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
        echo "!! cannot safely restore the pre-install Link file $target" >&2
        return 1
    fi
    LINK_PRESTATE_BACKUP="$backup"
}

restore_link_prestate()
{
    local target="$1" index="$ABLETON_STATE_HOME/install-prestate.tsv" backup tmp digest
    validate_link_prestate "$target" || return 1
    backup="$LINK_PRESTATE_BACKUP"
    [ -n "$backup" ] || return 0
    digest="$(link_path_digest "$backup")" || return 1
    ableton_atomic_restore_object "$backup" "$target" || return 1
    [ "$(link_path_digest "$target" 2>/dev/null || true)" = "$digest" ] || return 1
    tmp="$(mktemp "$ABLETON_STATE_HOME/.prestate-link.XXXXXX")"
    if ! awk -F '\t' -v p="$target" '$2 != p' "$index" > "$tmp" \
       || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$index"; then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$backup" || return 1
    link_deowned["$target"]=1
}

prune_link_manifest()
{
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv" tmp kind path digest
    [ -r "$manifest" ] || return 0
    tmp="$(mktemp "$ABLETON_STATE_HOME/.manifest-link.XXXXXX")"
    while IFS=$'\t' read -r kind path digest; do
        case "$path" in
            "$ABLETON_DATA_HOME/ableton-linkd"|"$data_unit"|"$linkctl"|"$ABLETON_DATA_HOME/setup-link.sh")
                [ -z "${link_deowned[$path]+x}" ] || continue
                [ -e "$path" ] || [ -L "$path" ] || continue ;;
        esac
        printf '%s\t%s\t%s\n' "$kind" "$path" "$digest" >> "$tmp"
    done < "$manifest"
    chmod 600 "$tmp"
    if [ -n "${ABLETON_TRANSACTION_DIR:-}" ] \
       && [ -e "$ABLETON_TRANSACTION_DIR/files.tsv" ]; then
        ableton_txn_snapshot "$manifest"
        ableton_txn_expect "$manifest" "$(ableton_regular_source_token "$tmp")"
    fi
    mv -f -- "$tmp" "$manifest"
}

disable_link()
{
    echo "== disable Ableton Link =="
    validate_link_firewall_state || {
        echo "!! unsafe Link firewall ownership record: $state_file" >&2
        return 1
    }
    stop_owned_service
    stop_owned_detached_link_daemons
    remove_owned_legacy_hook
    remove_owned_firewall
    if unit_is_owned; then
        rm -f -- "$unit_file"
        # Clear the directory if nothing else is using it.
        rmdir --ignore-fail-on-non-empty -- "$unit_dir" 2>/dev/null || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
        ableton_run_bounded 20 systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    remove_owned_link_file "$ABLETON_DATA_HOME/ableton-linkd"
    if [ "$ABLETON_LINKD" != "$ABLETON_DATA_HOME/ableton-linkd" ]; then
        echo "kept externally managed Link daemon $ABLETON_LINKD"
    fi
    remove_owned_link_file "$data_unit"
    remove_owned_link_file "$linkctl"
    remove_owned_link_file "$ABLETON_DATA_HOME/setup-link.sh"
    prune_link_manifest
    rm -f -- "$ABLETON_DATA_HOME/link-configured"
    ABLETON_LINK_MODE=off
    export ABLETON_LINK_MODE
    ableton_write_config
    if [ "$link_residual" -eq 0 ]; then
        echo "OK: Link policy is off; no owned Link binary, service, firewall rule, or daemon remains"
    else
        echo "OK: Link policy is off; unowned or modified Link files were kept"
    fi
}

install_unit()
{
    local escaped loaded_fragment="" tmp=""
    [ -x "$ABLETON_LINKD" ] || { echo "!! ableton-linkd is missing at $ABLETON_LINKD" >&2; return 1; }
    if { [ -e "$unit_file" ] || [ -L "$unit_file" ]; } && ! unit_is_owned; then
        echo "!! refusing to replace foreign systemd unit $unit_file" >&2
        return 1
    fi
    if [ ! -e "$unit_file" ] && command -v systemctl >/dev/null 2>&1; then
        loaded_fragment="$(ableton_run_bounded 20 systemctl --user show -p FragmentPath --value ableton-linkd.service 2>/dev/null || true)"
        if [ -n "$loaded_fragment" ] && [ "$(ableton_realpath_m "$loaded_fragment")" != "$(ableton_realpath_m "$unit_file")" ]; then
            echo "!! refusing to shadow foreign systemd unit $loaded_fragment" >&2
            return 1
        fi
    fi
    mkdir -p -- "$unit_dir"
    escaped="${ABLETON_LINKD//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//%/%%}"
    tmp="$(mktemp "$unit_dir/.ableton-linkd.service.XXXXXX")" || return 1
    if ! cat > "$tmp" <<EOF
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
    then
        rm -f -- "$tmp"
        return 1
    fi
    if ! chmod 644 "$tmp" || ! mv -f -- "$tmp" "$unit_file"; then
        rm -f -- "$tmp"
        return 1
    fi
    # This writes the unit for a later session either way. With no running user
    # manager there is nothing to reload, and session policy never needs it.
    systemd_user_available || return 0
    ableton_run_bounded 20 systemctl --user daemon-reload
}

ensure_recorded_firewall()
{
    local state="$1" rule_state=0
    case "$state" in
        ufw-added)
            command -v ufw >/dev/null 2>&1 || {
                echo "!! cannot verify the recorded ufw rule because ufw is missing" >&2
                return 127
            }
            echo "   verifying the recorded ufw allowance for UDP 20808 (sudo, each step bounded to two minutes)"
            ufw_link_rule_state || rule_state=$?
            if [ "$rule_state" -eq 1 ]; then
                echo "   restoring the recorded ufw allowance for UDP 20808"
                ableton_sudo_run_bounded 120 ufw allow 20808/udp
            elif [ "$rule_state" -ne 0 ]; then
                echo "!! could not verify the recorded ufw rule" >&2
                return 1
            fi ;;
        firewalld-added)
            echo "   verifying the recorded firewalld allowance for UDP 20808 (sudo, each step bounded to two minutes)"
            if command -v firewall-cmd >/dev/null 2>&1 \
               && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
                firewalld_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    echo "   restoring the recorded firewalld allowance for UDP 20808"
                    ableton_sudo_run_bounded 120 \
                        firewall-cmd --permanent --add-port=20808/udp || return $?
                    ableton_sudo_run_bounded 120 firewall-cmd --reload
                elif [ "$rule_state" -ne 0 ]; then
                    echo "!! could not verify the recorded firewalld rule" >&2
                    return 1
                fi
            elif command -v firewall-offline-cmd >/dev/null 2>&1; then
                firewalld_offline_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    echo "   restoring the recorded offline firewalld allowance for UDP 20808"
                    ableton_sudo_run_bounded 120 \
                        firewall-offline-cmd --add-port=20808/udp
                elif [ "$rule_state" -ne 0 ]; then
                    echo "!! could not verify the recorded offline firewalld rule" >&2
                    return 1
                fi
            else
                echo "!! cannot verify the recorded firewalld rule because firewalld is missing" >&2
                return 127
            fi ;;
        *) return 2 ;;
    esac
}

configure_firewall()
{
    validate_link_firewall_state || {
        echo "!! unsafe Link firewall ownership record: $state_file" >&2
        return 1
    }
    ableton_mark_state_home
    if [ -r "$state_file" ]; then
        case "$(sed -n '1p' "$state_file")" in
            ufw-added) ensure_recorded_firewall ufw-added; return $? ;;
            firewalld-added) ensure_recorded_firewall firewalld-added; return $? ;;
            none) : ;;
            *) echo "!! unrecognised Link firewall ownership record: $state_file" >&2; return 1 ;;
        esac
    fi
    if command -v ufw >/dev/null 2>&1 && grep -qsi '^ENABLED=yes' /etc/ufw/ufw.conf; then
        local rule_state=0
        ufw_link_rule_state || rule_state=$?
        if [ "$rule_state" -eq 0 ]; then
            write_link_firewall_state none
            echo "   ufw already allows UDP 20808; leaving the foreign/pre-existing rule alone"
        elif [ "$rule_state" -eq 1 ]; then
            echo "   ufw is active: adding UDP 20808 (sudo, each step bounded to two minutes)"
            write_link_firewall_state ufw-added
            # Persist ownership before ufw can make a partial change. The
            # caller's recovery can then remove only this attempted rule.
            ableton_sudo_run_bounded 120 ufw allow 20808/udp || return $?
        else
            echo "!! could not inspect the active ufw rules" >&2
            return 1
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 \
         && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
        local rule_state=0
        firewalld_link_rule_state || rule_state=$?
        if [ "$rule_state" -eq 0 ]; then
            write_link_firewall_state none
            echo "   firewalld already allows UDP 20808; leaving the foreign/pre-existing rule alone"
        elif [ "$rule_state" -eq 1 ]; then
            echo "   firewalld is active: adding UDP 20808 (sudo, each step bounded to two minutes)"
            write_link_firewall_state firewalld-added
            ableton_sudo_run_bounded 120 \
                firewall-cmd --permanent --add-port=20808/udp || return $?
            # Ownership is already recorded before reload. If reload fails, the
            # caller's rollback can still remove the persistent rule.
            ableton_sudo_run_bounded 120 firewall-cmd --reload || return $?
        else
            echo "!! could not inspect the active firewalld rules" >&2
            return 1
        fi
    else
        write_link_firewall_state none
        echo "   no active ufw/firewalld; no firewall mutation"
    fi
}

restore_firewall_record()
{
    local prior="$1" rc=0 rule_state=0
    ableton_mark_state_home
    case "$prior" in
        ufw-added)
            ufw_link_rule_state || rule_state=$?
            if [ "$rule_state" -eq 1 ]; then
                ableton_sudo_run_bounded 120 ufw allow 20808/udp || rc=$?
            elif [ "$rule_state" -ne 0 ]; then
                rc=1
            fi ;;
        firewalld-added)
            if command -v firewall-cmd >/dev/null 2>&1 \
               && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
                rule_state=0
                firewalld_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    ableton_sudo_run_bounded 120 firewall-cmd --permanent --add-port=20808/udp || rc=$?
                    [ "$rc" -ne 0 ] || ableton_sudo_run_bounded 120 firewall-cmd --reload || rc=$?
                elif [ "$rule_state" -ne 0 ]; then
                    rc=1
                fi
            elif command -v firewall-offline-cmd >/dev/null 2>&1; then
                rule_state=0
                firewalld_offline_link_rule_state || rule_state=$?
                if [ "$rule_state" -eq 1 ]; then
                    ableton_sudo_run_bounded 120 \
                        firewall-offline-cmd --add-port=20808/udp || rc=$?
                elif [ "$rule_state" -ne 0 ]; then
                    rc=1
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
    local snap="$1" pids asset label manifest
    printf '%s\n' "$ABLETON_LINK_MODE" > "$snap/policy" || return 1
    if [ -f "$state_file" ] && [ ! -L "$state_file" ]; then
        cp -a -- "$state_file" "$snap/firewall" || return 1
    else
        : > "$snap/firewall.absent" || return 1
    fi
    snapshot_legacy_network "$snap/legacy" || return 1
    if [ -f "$unit_file" ] && [ ! -L "$unit_file" ]; then
        cp -a -- "$unit_file" "$snap/unit" || return 1
    else
        [ ! -e "$unit_file" ] && [ ! -L "$unit_file" ] || {
            echo "!! unsafe or foreign Link unit cannot be snapshotted: $unit_file" >&2
            return 1
        }
        : > "$snap/unit.absent" || return 1
    fi
    label=0
    for asset in "$ABLETON_DATA_HOME/ableton-linkd" "$data_unit" "$linkctl" "$ABLETON_DATA_HOME/setup-link.sh"; do
        printf '%s\n' "$asset" > "$snap/asset-$label.path" || return 1
        if [ -f "$asset" ] || [ -L "$asset" ]; then
            cp -a -- "$asset" "$snap/asset-$label.file" || return 1
        else
            [ ! -e "$asset" ] || {
                echo "!! unsafe Link asset cannot be snapshotted: $asset" >&2
                return 1
            }
            : > "$snap/asset-$label.absent" || return 1
        fi
        label=$((label + 1))
    done
    manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    if [ -f "$manifest" ] && [ ! -L "$manifest" ]; then
        cp -a -- "$manifest" "$snap/manifest" || return 1
    else
        [ ! -e "$manifest" ] && [ ! -L "$manifest" ] || {
            echo "!! unsafe Link ownership snapshot" >&2
            return 1
        }
        : > "$snap/manifest.absent" || return 1
    fi
    if [ -e "$ABLETON_STATE_HOME/install-prestate.tsv" ]; then
        cp -a -- "$ABLETON_STATE_HOME/install-prestate.tsv" \
            "$snap/prestate.tsv" || return 1
    else
        : > "$snap/prestate.absent" || return 1
    fi
    if [ -d "$ABLETON_STATE_HOME/install-prestate" ] \
       && [ ! -L "$ABLETON_STATE_HOME/install-prestate" ]; then
        cp -a -- "$ABLETON_STATE_HOME/install-prestate" \
            "$snap/prestate-dir" || return 1
    elif [ -e "$ABLETON_STATE_HOME/install-prestate" ] \
         || [ -L "$ABLETON_STATE_HOME/install-prestate" ]; then
        echo "!! unsafe Link pre-install snapshot directory" >&2
        return 1
    else
        : > "$snap/prestate-dir.absent" || return 1
    fi
    if unit_is_owned && command -v systemctl >/dev/null 2>&1; then
        if ableton_run_bounded 20 systemctl --user is-enabled --quiet \
            ableton-linkd.service 2>/dev/null; then
            : > "$snap/enabled" || return 1
        else
            : > "$snap/enabled.absent" || return 1
        fi
        if loaded_unit_is_owned \
           && ableton_run_bounded 20 systemctl --user is-active --quiet \
                ableton-linkd.service 2>/dev/null; then
            : > "$snap/active" || return 1
        else
            : > "$snap/active.absent" || return 1
        fi
    else
        : > "$snap/enabled.absent" || return 1
        : > "$snap/active.absent" || return 1
    fi
    pids="$(owned_link_pids | head -n 1)" || return 1
    if [ -z "$pids" ]; then
        : > "$snap/detached-active.absent" || return 1
    else
        : > "$snap/detached-active" || return 1
    fi
    : > "$snap/ready" || return 1
}

snapshot_link_transaction()
{
    local snap="$transaction_dir/link" build=""
    ableton_txn_init || return 1
    validate_link_firewall_state || {
        echo "!! unsafe Link firewall ownership record: $state_file" >&2
        return 1
    }
    if [ -e "$snap" ] || [ -L "$snap" ]; then
        [ -d "$snap" ] && [ ! -L "$snap" ] || {
            echo "!! Link transaction snapshot path is unsafe" >&2
            return 1
        }
        if find "$snap" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
            validate_link_transaction_snapshot || return 1
            return 0
        fi
        rmdir -- "$snap" || return 1
    fi
    build="$(mktemp -d "$transaction_dir/.link-snapshot.XXXXXX")" || return 1
    if ! populate_link_transaction_snapshot "$build"; then
        rm -rf -- "$build" || {
            echo "!! failed to remove incomplete Link transaction snapshot: $build" >&2
        }
        return 1
    fi
    if ! mv -T -n -- "$build" "$snap" \
       || [ -e "$build" ] || [ ! -d "$snap" ] || [ -L "$snap" ]; then
        [ ! -e "$build" ] || rm -rf -- "$build"
        echo "!! could not publish the complete Link transaction snapshot" >&2
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
    local snap="$transaction_dir/link" prior label path expected saved count=0 names_count=0
    local status p backup extra digest slot name
    local -A seen=() prestate_seen=() prestate_slots=()
    [ ! -e "$snap" ] && [ ! -L "$snap" ] && return 0
    [ -d "$snap" ] && [ ! -L "$snap" ] || {
        echo "!! Link transaction snapshot is unsafe" >&2; return 1; }
    [ -f "$snap/ready" ] && [ ! -L "$snap/ready" ] && [ ! -s "$snap/ready" ] || {
        echo "!! Link transaction ready marker is invalid" >&2; return 1; }
    [ -f "$snap/policy" ] && [ ! -L "$snap/policy" ] \
        && ableton_file_has_no_nul "$snap/policy" \
        && [ "$(wc -l < "$snap/policy")" -eq 1 ] || {
        echo "!! Link transaction policy is invalid" >&2; return 1; }
    prior="$(sed -n '1p' "$snap/policy")"
    case "$prior" in off|session|always) ;; *) echo "!! Link transaction policy is invalid" >&2; return 1 ;; esac
    while IFS= read -r -d '' name; do
        name="${name##*/}"; names_count=$((names_count + 1))
        case "$name" in
            ready|policy|firewall|firewall.absent|unit|unit.absent|manifest|manifest.absent|\
            prestate.tsv|prestate.absent|prestate-dir|prestate-dir.absent|\
            enabled|enabled.absent|active|active.absent|\
            detached-active|detached-active.absent|legacy.hook|legacy.hook.absent|\
            legacy.route|legacy.route.absent|\
            asset-[0-3].path|asset-[0-3].file|asset-[0-3].absent) ;;
            *) echo "!! Link transaction snapshot has an unknown member: $name" >&2; return 1 ;;
        esac
    done < <(find "$snap" -mindepth 1 -maxdepth 1 -print0)
    [ "$names_count" -eq 20 ] || {
        echo "!! Link transaction snapshot inventory is incomplete" >&2; return 1; }
    if ! { link_snapshot_pair_valid "$snap/firewall" regular \
           && link_snapshot_pair_valid "$snap/unit" regular \
           && link_snapshot_pair_valid "$snap/manifest" regular \
           && link_snapshot_pair_valid "$snap/prestate.tsv" regular "$snap/prestate.absent" \
           && link_snapshot_pair_valid "$snap/prestate-dir" directory \
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
            && grep -qF '[ "$2" = "up" ] || exit 0' "$snap/legacy.hook" \
            && grep -qF 'ip route replace 224.0.0.0/4' "$snap/legacy.hook"; } || {
        echo "!! Link legacy-hook snapshot is invalid" >&2; return 1; }
    if [ -e "$snap/legacy.route" ]; then
        case "$(sed -n '1p' "$snap/legacy.route")" in 224.0.0.0/4\ *) ;; *)
            echo "!! Link legacy-route snapshot is invalid" >&2; return 1 ;; esac
    fi
    [ ! -e "$snap/manifest" ] || ableton_validate_ownership_manifest "$snap/manifest" || return 1
    if [ -e "$snap/prestate.tsv" ]; then
        while IFS=$'\t' read -r status p backup extra || [ -n "$status$p$backup$extra" ]; do
            [ -z "$extra" ] && [ "$status" = present ] \
                && ableton_manifest_path_ok "$p" \
                && [ -z "${prestate_seen[$p]+x}" ] \
                && { ableton_managed_path_allowed file "$p" \
                     || ableton_managed_path_allowed config "$p" \
                     || ableton_managed_path_allowed symlink "$p"; } || return 1
            expected="$ABLETON_STATE_HOME/install-prestate/$(printf '%s' "$p" | sha256sum | awk '{print $1}')"
            [ "$backup" = "$expected" ] || return 1
            backup="$snap/prestate-dir/${backup##*/}"
            { [ -f "$backup" ] || [ -L "$backup" ]; } || return 1
            digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
            [ -n "$digest" ] || return 1
            prestate_seen["$p"]=1
            prestate_slots["${backup##*/}"]=1
        done < "$snap/prestate.tsv"
    fi
    if [ -d "$snap/prestate-dir" ]; then
        while IFS= read -r -d '' slot; do
            name="${slot##*/}"
            if ! { [[ "$name" =~ ^[0-9a-f]{64}$ ]] \
                   && { [ -f "$slot" ] || [ -L "$slot" ]; } \
                   && [ -n "$(ableton_manifest_digest "$slot" 2>/dev/null || true)" ] \
                   && { [ ! -e "$snap/prestate.tsv" ] \
                        || [ -n "${prestate_slots[$name]+x}" ]; }; }; then
                echo "!! Link prestate snapshot contains an unindexed object" >&2
                return 1
            fi
        done < <(find "$snap/prestate-dir" -mindepth 1 -maxdepth 1 -print0)
    fi
    for label in 0 1 2 3; do
        saved="$snap/asset-$label.path"
        [ -f "$saved" ] && [ ! -L "$saved" ] && [ -r "$saved" ] \
            && ableton_file_has_no_nul "$saved" \
            && [ "$(wc -l < "$saved")" -eq 1 ] || return 1
        label="${saved##*/asset-}"; label="${label%.path}"
        case "$label" in 0|1|2|3) ;; *) echo "!! Link asset snapshot label is invalid" >&2; return 1 ;; esac
        path="$(sed -n '1p' "$saved")"
        case "$label" in
            0) expected="$ABLETON_DATA_HOME/ableton-linkd" ;;
            1) expected="$data_unit" ;;
            2) expected="$linkctl" ;;
            3) expected="$ABLETON_DATA_HOME/setup-link.sh" ;;
        esac
        [ "$path" = "$expected" ] && [ -z "${seen[$path]+x}" ] || {
            echo "!! Link asset snapshot path is invalid" >&2; return 1; }
        seen["$path"]=1; count=$((count + 1))
        link_snapshot_pair_valid "${saved%.path}.file" object "${saved%.path}.absent" || {
            echo "!! Link asset snapshot object is unsafe" >&2; return 1; }
    done
    [ "$count" -eq 4 ] || { echo "!! Link asset snapshot set is incomplete" >&2; return 1; }

}

preflight_link_transaction()
{
    local path snap="$transaction_dir/link" saved current prior expected
    validate_link_transaction_snapshot || return 1
    if [ -e "$transaction_dir/files.tsv" ] || [ -L "$transaction_dir/files.tsv" ]; then
        ableton_txn_preflight_rollback_files "$transaction_dir" || return 1
    fi
    # Rollback removes or replaces these exact destinations. Refuse a changed
    # directory/special object before an outer transaction restores any other
    # component, and require existing Link paths to remain project-owned.
    for path in "$unit_file" "$ABLETON_DATA_HOME/ableton-linkd" "$data_unit" \
                "$linkctl" "$ABLETON_DATA_HOME/setup-link.sh" \
                "$ABLETON_STATE_HOME/install-manifest.tsv" \
                "$ABLETON_STATE_HOME/install-prestate.tsv"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] && continue
        { [ -f "$path" ] || [ -L "$path" ]; } && [ ! -d "$path" ] || {
            echo "!! Link rollback destination is unsafe: $path" >&2; return 1; }
    done
    if [ -e "$ABLETON_STATE_HOME/install-prestate" ] \
       || [ -L "$ABLETON_STATE_HOME/install-prestate" ]; then
        [ -d "$ABLETON_STATE_HOME/install-prestate" ] \
            && [ ! -L "$ABLETON_STATE_HOME/install-prestate" ] || {
            echo "!! Link rollback prestate destination is unsafe" >&2; return 1; }
    fi

    # Do not overwrite a user edit made after the snapshot. A live destination
    # must still be the snapshotted object or a replacement claimed by the
    # current project manifest.
    current="$(ableton_object_token "$unit_file" 2>/dev/null || true)"
    prior=absent
    [ ! -e "$snap/unit" ] \
        || prior="$(ableton_object_token "$snap/unit" 2>/dev/null || true)"
    if [ -z "$current" ] \
       || { [ "$current" != "$prior" ] && ! unit_is_owned; }; then
            echo "!! Link unit changed while rollback was pending: $unit_file" >&2
            return 1
    fi
    for saved in "$snap"/asset-[0-3].path; do
        path="$(sed -n '1p' "$saved")"
        current="$(ableton_object_token "$path" 2>/dev/null || true)"
        prior=absent
        [ ! -e "${saved%.path}.file" ] \
            || prior="$(ableton_object_token "${saved%.path}.file" 2>/dev/null || true)"
        expected="$(manifest_digest_for "$path" 2>/dev/null || true)"
        [ -z "$expected" ] || expected="file:$expected"
        if [ -z "$current" ] \
           || { [ "$current" != "$prior" ] && [ "$current" != "$expected" ]; }; then
            echo "!! Link asset changed while rollback was pending: $path" >&2
            return 1
        fi
    done
    if [ -e "$ABLETON_STATE_HOME/install-manifest.tsv" ]; then
        ableton_validate_ownership_manifest "$ABLETON_STATE_HOME/install-manifest.tsv" || return 1
    fi
    if [ -e "$ABLETON_STATE_HOME/install-prestate.tsv" ]; then
        ableton_validate_prestate_index \
            "$ABLETON_STATE_HOME/install-prestate.tsv" \
            "$ABLETON_STATE_HOME/install-prestate" || return 1
    fi
}

preflight_link_commit_transaction()
{
    validate_link_transaction_snapshot || return 1
    if [ -e "$transaction_dir/files.tsv" ] || [ -L "$transaction_dir/files.tsv" ]; then
        ableton_txn_preflight_commit_files "$transaction_dir" || return 1
    fi
}

rollback_link_transaction()
{
    local snap="$transaction_dir/link" prior rc=0 ctl path saved manifest
    preflight_link_transaction || return 1
    [ -e "$snap/ready" ] || return 0
    prior="$(sed -n '1p' "$snap/policy")"
    stop_owned_service || return $?
    stop_owned_detached_link_daemons || rc=$?
    ctl="$here/ableton-linkctl"; [ -x "$ctl" ] || ctl="$linkctl"
    restore_firewall_snapshot "$snap/firewall" || rc=$?
    restore_legacy_network "$snap/legacy" || rc=$?
    if [ -e "$snap/unit" ]; then
        ableton_atomic_restore_object "$snap/unit" "$unit_file" || rc=1
    elif unit_is_owned; then
        rm -f -- "$unit_file"
    fi
    for saved in "$snap"/asset-*.path; do
        [ -f "$saved" ] || continue
        path="$(sed -n '1p' "$saved")"
        saved="${saved%.path}.file"
        if [ -e "$saved" ] || [ -L "$saved" ]; then
            ableton_atomic_restore_object "$saved" "$path" || rc=1
        elif [ -e "$path" ] || [ -L "$path" ]; then
            if legacy_link_file_is_owned "$path"; then
                rm -f -- "$path"
            else
                echo "!! Link asset changed while rollback was pending: $path" >&2
                rc=1
            fi
        fi
    done
    manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    if [ -e "$snap/manifest" ]; then
        ableton_mark_state_home
        ableton_atomic_restore_object "$snap/manifest" "$manifest" || rc=1
    elif [ -e "$manifest" ] || [ -L "$manifest" ]; then
        if ableton_validate_ownership_manifest "$manifest"; then
            rm -f -- "$manifest"
        else
            rc=1
        fi
    fi
    rm -f -- "$ABLETON_STATE_HOME/install-prestate.tsv"
    rm -rf -- "$ABLETON_STATE_HOME/install-prestate"
    if [ -e "$snap/prestate.tsv" ]; then
        ableton_atomic_restore_object "$snap/prestate.tsv" \
            "$ABLETON_STATE_HOME/install-prestate.tsv" || rc=1
    fi
    if [ -d "$snap/prestate-dir" ]; then
        cp -a -- "$snap/prestate-dir" "$ABLETON_STATE_HOME/install-prestate"
    fi
    # With no reachable user manager there is no unit state to put back, so the
    # rollback is complete without this block.
    if systemd_user_available; then
        ableton_run_bounded 20 systemctl --user daemon-reload >/dev/null 2>&1 || rc=$?
        if [ -e "$snap/enabled" ]; then
            ableton_run_bounded 20 systemctl --user enable ableton-linkd.service >/dev/null 2>&1 || rc=$?
        elif unit_is_owned; then
            ableton_run_bounded 20 systemctl --user disable ableton-linkd.service >/dev/null 2>&1 || true
        fi
        if [ -e "$snap/active" ]; then
            ableton_run_bounded 20 systemctl --user start ableton-linkd.service >/dev/null 2>&1 || rc=$?
        fi
    elif [ -e "$snap/enabled" ] || [ -e "$snap/active" ]; then
        # The snapshot recorded live unit state, so a reachable manager put it
        # there. Reporting success now would hide an unfinished rollback.
        echo "!! no systemd user manager is reachable to restore the Link unit state" >&2
        rc=1
    fi
    if [ -e "$snap/detached-active" ] && [ "$prior" = session ] && [ -x "$ctl" ]; then
        ABLETON_LINK_MODE=session "$ctl" start || rc=$?
    fi
    [ "$rc" -eq 0 ] || { echo "!! Link pre-state could not be fully restored" >&2; return "$rc"; }
    rm -rf -- "$snap"
}

commit_link_transaction()
{
    local snap="$transaction_dir/link" ctl
    [ -e "$snap/ready" ] || return 0
    preflight_link_commit_transaction || return 1
    ctl="$here/ableton-linkctl"; [ -x "$ctl" ] || ctl="$linkctl"
    if [ -e "$snap/detached-active" ] && [ "$ABLETON_LINK_MODE" = session ] && [ -x "$ctl" ]; then
        "$ctl" start
    fi
    rm -rf -- "$snap"
}

plan_link()
{
    local output=""
    echo "PLAN: Ableton Link"
    if [ "$action" = plan-disable ]; then
        printf '  set persistent policy off: %s\n' "$ABLETON_CONFIG_FILE"
        printf '  stop only daemon PIDs whose executable is: %s\n' "$ABLETON_LINKD"
        unit_is_owned && printf '  disable/stop and remove owned unit: %s\n' "$unit_file"
        [ ! -r "$state_file" ] || printf '  reverse recorded firewall state (%s): %s\n' "$(sed -n '1p' "$state_file")" "$state_file"
        [ ! -e "$legacy_hook" ] || printf '  remove recognisable legacy hook/route: %s\n' "$legacy_hook"
        printf '  remove manifest-owned Link assets: %s, %s/{ableton-linkctl,setup-link.sh,ableton-linkd.service}\n' \
            "$ABLETON_DATA_HOME/ableton-linkd" "$ABLETON_DATA_HOME"
        return 0
    fi
    printf '  set persistent policy %s: %s\n' "$mode" "$ABLETON_CONFIG_FILE"
    [ ! -e "$legacy_hook" ] || printf '  remove recognisable legacy hook/route: %s\n' "$legacy_hook"
    if command -v ufw >/dev/null 2>&1 && grep -qsi '^ENABLED=yes' /etc/ufw/ufw.conf; then
        if output="$(ableton_run_bounded 20 ufw status 2>/dev/null)"; then
            if printf '%s\n' "$output" \
                | grep -Eq '(^|[[:space:]])20808/udp([[:space:]]|$)'; then
                echo '  keep pre-existing UFW UDP 20808 rule; record no ownership'
            else
                echo '  add UFW UDP 20808 rule; record project ownership'
            fi
        else
            echo '  inspect UFW UDP 20808 with sudo; add it only when absent'
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 \
         && ableton_run_bounded 20 firewall-cmd --state >/dev/null 2>&1; then
        if output="$(ableton_run_bounded 20 firewall-cmd --permanent --list-ports 2>/dev/null)"; then
            if printf '%s\n' "$output" | tr ' ' '\n' | grep -qxF 20808/udp; then
                echo '  keep pre-existing firewalld UDP 20808 rule; record no ownership'
            else
                echo '  add/reload firewalld UDP 20808 rule; record project ownership'
            fi
        else
            echo '  inspect firewalld UDP 20808 with sudo; add it only when absent'
        fi
    else
        echo '  no active UFW/firewalld mutation'
    fi
    printf '  write ownership-marked user unit with ExecStart=%s: %s\n' "$ABLETON_LINKD" "$unit_file"
    case "$mode" in
        session) echo '  disable/stop the owned always-on unit; launchers start session daemon' ;;
        always) echo '  enable/start the owned user unit' ;;
    esac
}

ABLETON_LINK_ENABLE_RECOVERY_ERROR=""
link_enable_recovery_error()
{
    ABLETON_LINK_ENABLE_RECOVERY_ERROR="${ABLETON_LINK_ENABLE_RECOVERY_ERROR}${ABLETON_LINK_ENABLE_RECOVERY_ERROR:+; }$1"
}

link_enable_record_post()
{
    local snapshot="$1" label="$2" target="$3" token
    token="$(ableton_object_token "$target" 2>/dev/null || true)"
    [ -n "$token" ] || return 1
    printf '%s\n' "$token" > "$snapshot/$label.post"
    chmod 600 "$snapshot/$label.post"
}

link_enable_target_safe_for_restore()
{
    local snapshot="$1" label="$2" target="$3" existed="$4"
    local current prior=absent post=""
    current="$(ableton_object_token "$target" 2>/dev/null || true)"
    [ -n "$current" ] || return 1
    if [ "$existed" -eq 1 ]; then
        prior="$(ableton_object_token "$snapshot/$label" 2>/dev/null || true)"
        [ -n "$prior" ] || return 1
    fi
    [ ! -e "$snapshot/$label.post" ] \
        || post="$(sed -n '1p' "$snapshot/$label.post")"
    [ "$current" = absent ] || [ "$current" = "$prior" ] \
        || { [ -n "$post" ] && [ "$current" = "$post" ]; }
}

populate_link_enable_snapshot()
{
    local snapshot="$1"
    if [ -e "$state_file" ]; then
        cp -a -- "$state_file" "$snapshot/firewall" || return 1
    fi
    snapshot_legacy_network "$snapshot/legacy" || return 1
    if [ -e "$unit_file" ] || [ -L "$unit_file" ]; then
        cp -a -- "$unit_file" "$snapshot/unit" || return 1
    fi
    if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
        cp -a -- "$ABLETON_CONFIG_FILE" "$snapshot/config" || return 1
    fi
}

LINK_ENABLE_UNSTARTED_SNAPSHOT=""
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_link_enable_snapshot()
{
    local rc=$?
    trap - EXIT
    case "$LINK_ENABLE_UNSTARTED_SNAPSHOT" in
        "$ABLETON_STATE_HOME"/.link-enable.*)
            if [ -d "$LINK_ENABLE_UNSTARTED_SNAPSHOT" ] \
               && [ ! -L "$LINK_ENABLE_UNSTARTED_SNAPSHOT" ] \
               && ! rm -rf -- "$LINK_ENABLE_UNSTARTED_SNAPSHOT"; then
                echo "!! failed to remove unstarted Link recovery snapshot: $LINK_ENABLE_UNSTARTED_SNAPSHOT" >&2
            fi ;;
    esac
    exit "$rc"
}

restore_link_enable_snapshot()
{
    local snapshot="$1" unit_existed="$2" config_existed="$3"
    local restore_config="$4" operation_rc="$5" recovery_rc=0
    ABLETON_LINK_ENABLE_RECOVERY_ERROR=""
    if ! link_enable_target_safe_for_restore "$snapshot" unit "$unit_file" "$unit_existed"; then
        link_enable_recovery_error "Link unit changed during recovery"
        recovery_rc=1
    fi
    if [ "$restore_config" -eq 1 ] \
       && ! link_enable_target_safe_for_restore \
            "$snapshot" config "$ABLETON_CONFIG_FILE" "$config_existed"; then
        link_enable_recovery_error "Link configuration changed during recovery"
        recovery_rc=1
    fi
    [ "$recovery_rc" -eq 0 ] || {
        printf 'operation=enable\noperation_exit=%s\nrestoration_complete=no\nrestoration_error=%s\n' \
            "$operation_rc" "$ABLETON_LINK_ENABLE_RECOVERY_ERROR" > "$snapshot/FAILURE" 2>/dev/null || true
        return 1
    }
    # Recheck all local destinations immediately before any restoration.  A
    # user edit made during a sudo/systemctl window must not be overwritten.
    if ! link_enable_target_safe_for_restore "$snapshot" unit "$unit_file" "$unit_existed"; then
        link_enable_recovery_error "Link unit changed during recovery"; recovery_rc=1
    fi
    if [ "$restore_config" -eq 1 ] \
       && ! link_enable_target_safe_for_restore \
            "$snapshot" config "$ABLETON_CONFIG_FILE" "$config_existed"; then
        link_enable_recovery_error "Link configuration changed during recovery"; recovery_rc=1
    fi
    if [ "$recovery_rc" -eq 0 ] && ! restore_firewall_snapshot "$snapshot/firewall"; then
        link_enable_recovery_error "firewall restoration failed"; recovery_rc=1
    fi
    if [ "$recovery_rc" -eq 0 ] && ! restore_legacy_network "$snapshot/legacy"; then
        link_enable_recovery_error "legacy network restoration failed"; recovery_rc=1
    fi
    if [ "$recovery_rc" -eq 0 ] && [ "$unit_existed" -eq 1 ]; then
        if ! ableton_atomic_restore_object "$snapshot/unit" "$unit_file"; then
            link_enable_recovery_error "Link unit restoration failed"; recovery_rc=1
        fi
    elif [ "$recovery_rc" -eq 0 ] \
         && { [ -e "$unit_file" ] || [ -L "$unit_file" ]; }; then
        if unit_is_owned; then
            if ! rm -f -- "$unit_file"; then
                link_enable_recovery_error "Link unit cleanup failed"; recovery_rc=1
            fi
        else
            link_enable_recovery_error "Link unit changed during recovery"; recovery_rc=1
        fi
    fi
    if [ "$recovery_rc" -eq 0 ] && [ "$restore_config" -eq 1 ]; then
        if [ "$config_existed" -eq 1 ]; then
            if ! ableton_atomic_restore_object "$snapshot/config" "$ABLETON_CONFIG_FILE"; then
                link_enable_recovery_error "Link configuration restoration failed"; recovery_rc=1
            fi
        elif ! rm -f -- "$ABLETON_CONFIG_FILE"; then
            link_enable_recovery_error "Link configuration cleanup failed"; recovery_rc=1
        fi
    fi
    if [ "$recovery_rc" -eq 0 ]; then
        if rm -rf -- "$snapshot"; then
            return 0
        fi
        link_enable_recovery_error "recovery snapshot cleanup failed"; recovery_rc=1
    fi
    printf 'operation=enable\noperation_exit=%s\nrestoration_complete=no\nrestoration_error=%s\n' \
        "$operation_rc" "$ABLETON_LINK_ENABLE_RECOVERY_ERROR" > "$snapshot/FAILURE" 2>/dev/null || true
    return "$recovery_rc"
}

enable_link()
{
    # Availability check only, against a local: a packaged install stages
    # ableton-linkctl beside this script and populates no $ABLETON_DATA_HOME,
    # so testing just the latter refuses to run and names assets no packaged
    # install provides. $linkctl itself must not move - restore_link_snapshot
    # and the ownership manifest address the $ABLETON_DATA_HOME path by name,
    # and pointing those at the store would record an asset this project does
    # not own and cannot restore. Same shape as plan_link and the restore path.
    local ctl="$here/ableton-linkctl"
    [ -x "$ctl" ] || ctl="$linkctl"
    [ -x "$ctl" ] || { echo "!! ableton-linkctl is missing at $ctl; install Link assets first" >&2; return 1; }
    echo "== enable Ableton Link ($mode) =="
    local snapshot unit_existed=0 config_existed=0 rc=0 stop_rc=0
    validate_link_firewall_state || {
        echo "!! unsafe Link firewall ownership record: $state_file" >&2
        return 1
    }
    # Refuse unsafe live objects before claiming state or creating a recovery
    # directory.  A dangling/foreign unit or unsafe config is not pre-state we
    # can later restore safely.
    if [ -e "$unit_file" ] || [ -L "$unit_file" ]; then
        [ -f "$unit_file" ] && [ ! -L "$unit_file" ] || {
            echo "!! unsafe or foreign Link unit cannot be snapshotted: $unit_file" >&2
            return 1
        }
    fi
    if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
        if ! { [ -f "$ABLETON_CONFIG_FILE" ] && [ ! -L "$ABLETON_CONFIG_FILE" ] \
               && ableton_managed_config_valid "$ABLETON_CONFIG_FILE"; }; then
            echo "!! unsafe installer configuration cannot be snapshotted" >&2
            return 1
        fi
    fi
    ableton_mark_state_home
    snapshot="$(mktemp -d "$ABLETON_STATE_HOME/.link-enable.XXXXXX")"
    LINK_ENABLE_UNSTARTED_SNAPSHOT="$snapshot"
    trap cleanup_unstarted_link_enable_snapshot EXIT
    if ! populate_link_enable_snapshot "$snapshot"; then
        if ! rm -rf -- "$snapshot"; then
            echo "!! failed to remove unstarted Link recovery snapshot: $snapshot" >&2
        fi
        LINK_ENABLE_UNSTARTED_SNAPSHOT=""
        trap - EXIT
        return 1
    fi
    if [ -e "$unit_file" ] || [ -L "$unit_file" ]; then
        unit_existed=1
    fi
    if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
        config_existed=1
    fi
    LINK_ENABLE_UNSTARTED_SNAPSHOT=""
    trap - EXIT
    remove_owned_legacy_hook || rc=$?
    if [ "$rc" -eq 0 ]; then configure_firewall || rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        install_unit || rc=$?
        [ ! -e "$unit_file" ] || link_enable_record_post "$snapshot" unit "$unit_file" || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        if restore_link_enable_snapshot "$snapshot" "$unit_existed" "$config_existed" 0 "$rc"; then
            echo "!! Link enable failed; the previous Link state was restored" >&2
        else
            echo "!! Link enable failed and automatic restoration is incomplete: $ABLETON_LINK_ENABLE_RECOVERY_ERROR" >&2
            echo "!! recovery snapshot kept at $snapshot" >&2
        fi
        return "$rc"
    fi
    ABLETON_LINK_MODE="$mode"
    export ABLETON_LINK_MODE
    ableton_write_config || rc=$?
    if [ -e "$ABLETON_CONFIG_FILE" ] && ableton_managed_config_valid "$ABLETON_CONFIG_FILE"; then
        link_enable_record_post "$snapshot" config "$ABLETON_CONFIG_FILE" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        case "$mode" in
            session)
                # Registration is harmless, but session policy must never leave the
                # always-on unit enabled or running where it could actually run.
                # A manager that answers and then fails is still an error.
                if systemd_user_available; then
                    ableton_run_bounded 20 systemctl --user disable --now \
                        ableton-linkd.service >/dev/null 2>&1 || rc=$?
                elif [ -L "$unit_dir/default.target.wants/ableton-linkd.service" ]; then
                    # systemd keeps the enablement on disk, so it outlives the
                    # current bus. This link survives to the next login, and the
                    # daemon would start there.
                    echo "!! the always-on Link unit is still enabled, and no systemd user manager is reachable to turn it off" >&2
                    echo "   Run 'systemctl --user disable --now ableton-linkd.service' in a desktop session, then enable Link again." >&2
                    rc=1
                fi ;;
            always)
                if ! systemd_user_available; then
                    echo "!! always-on Link policy needs a running systemd user manager" >&2
                    rc=127
                else
                    ableton_run_bounded 20 systemctl --user enable --now \
                        ableton-linkd.service || rc=$?
                fi ;;
        esac
    fi
    if [ "$rc" -ne 0 ]; then
        stop_owned_service || stop_rc=$?
        if [ "$stop_rc" -ne 0 ]; then
            ABLETON_LINK_ENABLE_RECOVERY_ERROR="Link service could not be stopped"
            printf 'operation=enable\noperation_exit=%s\nrestoration_complete=no\nrestoration_error=%s\n' \
                "$rc" "$ABLETON_LINK_ENABLE_RECOVERY_ERROR" \
                > "$snapshot/FAILURE" 2>/dev/null || true
            echo "!! Link enable failed and automatic restoration is incomplete: $ABLETON_LINK_ENABLE_RECOVERY_ERROR" >&2
            echo "!! recovery snapshot kept at $snapshot" >&2
            return "$rc"
        fi
        if restore_link_enable_snapshot "$snapshot" "$unit_existed" "$config_existed" 1 "$rc"; then
            echo "!! Link enable failed; the previous Link state was restored" >&2
        else
            echo "!! Link enable failed and automatic restoration is incomplete: $ABLETON_LINK_ENABLE_RECOVERY_ERROR" >&2
            echo "!! recovery snapshot kept at $snapshot" >&2
        fi
        return "$rc"
    fi
    if ! rm -f -- "$ABLETON_DATA_HOME/link-configured" \
       || ! rm -rf -- "$snapshot"; then
        echo "!! Link is enabled, but its recovery snapshot could not be retired: $snapshot" >&2
        return 1
    fi
    echo "OK: Link policy is $mode"
}

case "$action" in
    enable) enable_link ;;
    disable) disable_link ;;
    status)
        validate_link_firewall_state || {
            echo "!! unsafe Link firewall ownership record: $state_file" >&2
            exit 1
        }
        printf 'policy: %s\n' "$ABLETON_LINK_MODE"
        status_pid=""
        if [ "$ABLETON_LINK_MODE" = always ] && loaded_unit_is_owned \
           && ableton_run_bounded 20 systemctl --user is-active --quiet \
                ableton-linkd.service 2>/dev/null; then
            echo 'state: running (systemd)'
        elif status_pid="$(owned_link_pids | head -n 1)" \
             && [ -n "$status_pid" ]; then
            printf 'state: running (pid %s)\n' "$status_pid"
        elif [ -x "$ABLETON_LINKD" ]; then
            echo 'state: stopped'
        else
            echo 'state: not installed'
        fi
        [ -r "$state_file" ] && printf 'firewall: %s\n' "$(sed -n '1p' "$state_file")" || echo 'firewall: unrecorded'
        ;;
    snapshot) snapshot_link_transaction ;;
    preflight-rollback) preflight_link_transaction ;;
    preflight-commit) preflight_link_commit_transaction ;;
    rollback) rollback_link_transaction ;;
    commit) commit_link_transaction ;;
    plan-enable|plan-disable) plan_link ;;
esac
