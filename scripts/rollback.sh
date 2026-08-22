#!/usr/bin/env bash
# Restore the newest versioned runtime rollback and its recorded configuration.
# The displaced runtime becomes the next rollback, so the operation is itself
# reversible.  User-owned panel paths are never replaced or removed.
set -euo pipefail

ARCH="${ARCH:-$(uname -m)}"

here="$(cd "$(dirname "$0")" && pwd)"
for lib in "$here/lib/config.sh" "$here/config.sh" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    # shellcheck disable=SC1090
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 || {
    echo "!! rollback cannot find its installation configuration" >&2; exit 1; }
ableton_config_init
for name in lifecycle manifest pipeasio; do
    found=""
    for lib in "$here/lib/$name.sh" "$ABLETON_DATA_HOME/lib/$name.sh"; do
        [ -r "$lib" ] || continue
        # shellcheck disable=SC1090
        . "$lib"
        found=1
        break
    done
    [ -n "$found" ] || { echo "!! rollback helper $name.sh is missing" >&2; exit 1; }
done

[ $# -eq 0 ] || { echo "!! rollback takes no arguments" >&2; exit 2; }
ableton_install_lock_acquire

runtime="$ABLETON_WINE_ROOT"
runtime_parent="$(dirname "$runtime")"
runtime_base="$(basename "$runtime")"
if [ -L "$runtime" ] || ! ableton_runtime_marker_valid "$runtime" "$ABLETON_RUNTIME_NAME"; then
    echo "!! current runtime is not a managed Ableton runtime" >&2
    exit 1
fi

saved=""
saved_mtime=-1
while IFS= read -r -d '' candidate; do
    [ -n "$candidate" ] || continue
    candidate_base="$(basename "$candidate")"
    [[ "$candidate_base" = "$runtime_base-rollback-"* ]] || continue
    if [ -L "$candidate" ] \
       || ! ableton_runtime_marker_valid "$candidate" "$ABLETON_RUNTIME_NAME"; then
        continue
    fi
    if [ -e "$candidate/.ableton-linux-rollback-incomplete" ] \
       || [ -L "$candidate/.ableton-linux-rollback-incomplete" ]; then
        continue
    fi
    candidate_mtime="$(stat -c '%Y' -- "$candidate" 2>/dev/null || printf 0)"
    if [ "$candidate_mtime" -gt "$saved_mtime" ]; then
        saved="$candidate"
        saved_mtime="$candidate_mtime"
    fi
done < <(find "$runtime_parent" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
[ -n "$saved" ] || { echo "!! no completed runtime rollback is available" >&2; exit 1; }
for required in bin/wine bin/wineserver \
    lib/wine/$ARCH-windows/pipeasio64.dll \
    lib/wine/$ARCH-unix/pipeasio64.dll.so; do
    [ -s "$saved/$required" ] || { echo "!! saved runtime is incomplete: $required" >&2; exit 1; }
done

saved_meta_dir="$saved/.ableton-linux-rollback"
if [ -e "$saved_meta_dir" ] || [ -L "$saved_meta_dir" ]; then
    [ ! -L "$saved_meta_dir" ] && [ -d "$saved_meta_dir" ] || {
        echo "!! saved rollback metadata directory is unsafe" >&2; exit 1; }
fi
metadata="$saved_meta_dir/metadata"
rollback_config_snapshot_valid()
{
    local snapshot="$1" digest
    if [ -L "$snapshot" ]; then
        digest="$(ableton_manifest_digest "$snapshot" 2>/dev/null || true)"
        [ -n "$digest" ]
        return
    fi
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] && [ -r "$snapshot" ] \
        && ableton_file_has_no_nul "$snapshot" || return 1
    digest="$(ableton_manifest_digest "$snapshot" 2>/dev/null || true)"
    [ -n "$digest" ]
}
if [ -e "$metadata" ] || [ -L "$metadata" ]; then
    if ! { [ -f "$metadata" ] && [ ! -L "$metadata" ] && [ -r "$metadata" ] \
           && ableton_file_has_no_nul "$metadata"; }; then
        echo "!! saved rollback metadata is unsafe or unreadable" >&2
        exit 1
    fi
fi
metadata_value()
{
    local key="$1" count value
    count="$(grep -c "^${key}=" "$metadata" 2>/dev/null || true)"
    [ "$count" -eq 1 ] || return 1
    value="$(sed -n "s/^${key}=//p" "$metadata")"
    printf '%s\n' "$value"
}

installer_config_path="$ABLETON_CONFIG_FILE"
pipeasio_config_parent="$(ableton_realpath_m "${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio")"
pipeasio_config_path="$pipeasio_config_parent/config.ini"
installer_config_state=unchanged
pipeasio_config_state=unchanged
desired_panel=0
metadata_present=0
if [ -r "$metadata" ]; then
    metadata_present=1
    [ "$(metadata_value format)" = 1 ] || { echo "!! saved rollback metadata is invalid" >&2; exit 1; }
    [ "$(metadata_value runtime_root)" = "$runtime" ] || {
        echo "!! saved rollback belongs to a different runtime path" >&2; exit 1; }
    recorded_prefix="$(metadata_value prefix)"
    [ "$recorded_prefix" = "$ABLETON_WINEPREFIX" ] || {
        echo "!! saved rollback belongs to a different Wine prefix" >&2; exit 1; }
    [ "$(metadata_value installer_config_path)" = "$installer_config_path" ] || {
        echo "!! saved rollback belongs to a different configuration directory" >&2; exit 1; }
    [ "$(metadata_value pipeasio_config_path)" = "$pipeasio_config_path" ] || {
        echo "!! saved rollback belongs to a different PipeASIO configuration directory" >&2; exit 1; }
    installer_config_state="$(metadata_value installer_config_state)"
    pipeasio_config_state="$(metadata_value pipeasio_config_state)"
    desired_panel="$(metadata_value panel_integration)"
    case "$installer_config_state:$pipeasio_config_state:$desired_panel" in
        present:present:0|present:present:1|present:absent:0|present:absent:1|\
        absent:present:0|absent:present:1|absent:absent:0|absent:absent:1) ;;
        *) echo "!! saved rollback configuration state is invalid" >&2; exit 1 ;;
    esac
    [ "$installer_config_state" != present ] \
        || rollback_config_snapshot_valid "$saved/.ableton-linux-rollback/installer-config" \
        || { echo "!! saved installer configuration is missing" >&2; exit 1; }
    [ "$pipeasio_config_state" != present ] \
        || rollback_config_snapshot_valid "$saved/.ableton-linux-rollback/pipeasio-config.ini" \
        || { echo "!! saved PipeASIO configuration is missing" >&2; exit 1; }
fi

for current_config in "$installer_config_path" "$pipeasio_config_path"; do
    if [ -e "$current_config" ] || [ -L "$current_config" ]; then
        rollback_config_snapshot_valid "$current_config" || {
            echo "!! current rollback configuration is unsafe: $current_config" >&2
            exit 1
        }
    fi
done

refuse_runtime_users()
{
    local runtime_users pid selected_prefix_user=0
    runtime_users="$({ ableton_runtime_pids "$runtime"; ableton_runtime_pids "$saved"; } | sort -u)"
    [ -z "$runtime_users" ] || {
        for pid in $runtime_users; do
            ableton_pid_uses_prefix "$pid" && selected_prefix_user=1
        done
        if [ "$selected_prefix_user" -eq 1 ]; then
            echo "!! Live, Max, or another Wine client is running; close it before rollback" >&2
        else
            echo "!! another Wine prefix is using this runtime; close it before rollback" >&2
        fi
        # "close Live" is unactionable when the holder is a windowless agent.
        for pid in $runtime_users; do
            printf '   %s (pid %s)\n' "$(ableton_pid_image "$pid")" "$pid" >&2
        done
        return 1
    }
}
refuse_runtime_users

probe="$ABLETON_DATA_HOME/pipewire-version-probe"
[ -x "$probe" ] || probe="$runtime/bin/pipewire-version-probe"
ableton_pipewire_preflight "$probe" "rolling PipeASIO back"

ableton_mark_state_home
mkdir -p -- "$ABLETON_STATE_HOME/transactions"
transaction="$(mktemp -d "$ABLETON_STATE_HOME/transactions/rollback.XXXXXX")"
ABLETON_TRANSACTION_DIR="$transaction"
export ABLETON_TRANSACTION_DIR
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_rollback()
{
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && ! rm -rf -- "$transaction"; then
        echo "!! failed to remove unstarted rollback transaction: $transaction" >&2
    fi
    exit "$rc"
}
trap cleanup_unstarted_rollback EXIT
ableton_txn_init

now="$(date -u +%Y%m%dT%H%M%SZ)"
reverse="$runtime-rollback-$now"
if [ -e "$reverse" ] || [ -L "$reverse" ]; then reverse="$reverse-$$"; fi
[ ! -e "$reverse" ] && [ ! -L "$reverse" ] || {
    echo "!! cannot choose an unused reverse-rollback path" >&2; exit 1; }
current_moved=0
saved_promoted=0
registration_attempted=0
reverse_meta=""
reverse_meta_tmp=""
reverse_meta_preexisting=0

rollback_wine()
{
    ableton_run_bounded 60 "$runtime/bin/wine" "$@"
}
rollback_wineserver_wait()
{
    ableton_prefix_wait "$runtime"
}

move_runtime_to_empty()
{
    local source="$1" target="$2"
    [ -d "$source" ] && [ ! -L "$source" ] \
        && [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
    mv -T -n -- "$source" "$target"
    [ ! -e "$source" ] && [ ! -L "$source" ] \
        && [ -d "$target" ] && [ ! -L "$target" ]
}

rollback_failure()
{
    local rc=$? restore_error="" runtime_layout_restored=1 failure_complete
    trap - EXIT
    case "$reverse_meta_tmp" in
        "$reverse_meta/.metadata."*)
            if ! rm -f -- "$reverse_meta_tmp"; then
                restore_error="temporary rollback metadata cleanup failed"
            fi ;;
    esac
    if ! ableton_txn_rollback_files "$transaction" >/dev/null 2>&1; then
        restore_error="host file restoration failed"
    fi
    if [ "$reverse_meta_preexisting" -eq 0 ] && [ -n "$reverse_meta" ]; then
        if ! rmdir -- "$reverse_meta" 2>/dev/null; then
            restore_error="${restore_error}${restore_error:+; }temporary rollback directory cleanup failed"
        fi
    fi
    if [ "$saved_promoted" -eq 1 ]; then
        if [ ! -e "$runtime" ] || [ -L "$runtime" ] \
           || [ -e "$saved" ] || [ -L "$saved" ] || [ ! -e "$reverse" ]; then
            runtime_layout_restored=0
            restore_error="${restore_error}${restore_error:+; }runtime layout changed while handling the failure"
        elif move_runtime_to_empty "$runtime" "$saved"; then
            if ! move_runtime_to_empty "$reverse" "$runtime"; then
                runtime_layout_restored=0
                restore_error="${restore_error}${restore_error:+; }could not put the displaced runtime back"
            fi
        else
            runtime_layout_restored=0
            restore_error="${restore_error}${restore_error:+; }could not return the promoted runtime to its saved path"
        fi
    elif [ "$current_moved" -eq 1 ]; then
        if [ -e "$runtime" ] || [ -L "$runtime" ] || [ ! -e "$reverse" ]; then
            runtime_layout_restored=0
            restore_error="${restore_error}${restore_error:+; }runtime layout changed while handling the failure"
        elif ! move_runtime_to_empty "$reverse" "$runtime"; then
            runtime_layout_restored=0
            restore_error="${restore_error}${restore_error:+; }could not put the displaced runtime back"
        fi
    fi
    if [ "$registration_attempted" -eq 1 ]; then
        if [ "$runtime_layout_restored" -eq 1 ] && [ -x "$runtime/bin/wine" ] \
           && [ -f "$ABLETON_WINEPREFIX/system.reg" ]; then
            if ! ableton_pipeasio_register rollback_wine rollback_wineserver_wait >/dev/null 2>&1; then
                restore_error="${restore_error}${restore_error:+; }original PipeASIO registration could not be restored"
            fi
        else
            restore_error="${restore_error}${restore_error:+; }original PipeASIO registration was not retried"
        fi
    fi
    failure_complete="$([ -z "$restore_error" ] && echo yes || echo no)"
    if ! printf 'exit=%s\nsaved=%s\nruntime_restored=%s\nrestoration_complete=%s\n' \
        "$rc" "$saved" "$([ "$runtime_layout_restored" -eq 1 ] && echo yes || echo no)" \
        "$failure_complete" > "$transaction/FAILURE"; then
        restore_error="${restore_error}${restore_error:+; }failure record could not be written"
    fi
    if [ -n "$restore_error" ]; then
        printf '!! rollback failed and automatic runtime restoration is incomplete: %s\n' \
            "$restore_error" >&2
        echo "!! Leave the runtime directories in place and inspect the failure record." >&2
    else
        echo "!! rollback failed; the previous runtime and files were restored" >&2
    fi
    exit "$rc"
}
trap rollback_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

panel_integration_now=0
manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
if [ -r "$manifest" ] && awk -F '\t' -v b="$ABLETON_BIN_HOME/pipeasio-settings" \
    -v d="${XDG_DATA_HOME:-$HOME/.local/share}/applications/pipeasio-settings.desktop" \
    -v i="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/pipeasio.svg" \
    '$2==b || $2==d || $2==i { found=1 } END { exit !found }' "$manifest"; then
    panel_integration_now=1
fi
[ "$metadata_present" -eq 1 ] || desired_panel="$panel_integration_now"

echo "== restore the previous runtime =="
refuse_runtime_users
# The two same-filesystem renames are a single logical swap.  Ignore terminal
# signals only for this tiny critical section so EXIT recovery never observes
# a completed rename with its state flag still unset.
trap '' INT TERM
if ! move_runtime_to_empty "$runtime" "$reverse"; then
    trap 'exit 130' INT; trap 'exit 143' TERM
    exit 1
fi
current_moved=1
if ! move_runtime_to_empty "$saved" "$runtime"; then
    trap 'exit 130' INT; trap 'exit 143' TERM
    exit 1
fi
saved_promoted=1
trap 'exit 130' INT
trap 'exit 143' TERM

# Store the state being displaced inside the reverse rollback before changing
# host configuration.  This makes a second invocation a safe undo.
reverse_meta="$reverse/.ableton-linux-rollback"
if [ -e "$reverse_meta" ] || [ -L "$reverse_meta" ]; then
    [ ! -L "$reverse_meta" ] && [ -d "$reverse_meta" ] || {
        echo "!! current runtime has an unsafe rollback metadata directory" >&2; exit 1; }
    reverse_meta_preexisting=1
else
    mkdir -p -- "$reverse_meta"
fi
ableton_txn_snapshot "$reverse_meta/installer-config"
ableton_txn_snapshot "$reverse_meta/pipeasio-config.ini"
ableton_txn_snapshot "$reverse_meta/metadata"
if [ -e "$installer_config_path" ] || [ -L "$installer_config_path" ]; then
    ableton_txn_expect "$reverse_meta/installer-config" \
        "$(ableton_object_token "$installer_config_path")"
    ableton_atomic_restore_object "$installer_config_path" "$reverse_meta/installer-config"
    reverse_installer_state=present
else
    ableton_txn_expect "$reverse_meta/installer-config" absent
    rm -f -- "$reverse_meta/installer-config"
    reverse_installer_state=absent
fi
if [ -e "$pipeasio_config_path" ] || [ -L "$pipeasio_config_path" ]; then
    ableton_txn_expect "$reverse_meta/pipeasio-config.ini" \
        "$(ableton_object_token "$pipeasio_config_path")"
    ableton_atomic_restore_object "$pipeasio_config_path" "$reverse_meta/pipeasio-config.ini"
    reverse_pipeasio_state=present
else
    ableton_txn_expect "$reverse_meta/pipeasio-config.ini" absent
    rm -f -- "$reverse_meta/pipeasio-config.ini"
    reverse_pipeasio_state=absent
fi
reverse_meta_tmp="$(mktemp "$reverse_meta/.metadata.XXXXXX")"
{
    printf 'format=1\n'
    printf 'runtime_root=%s\n' "$runtime"
    printf 'prefix=%s\n' "$ABLETON_WINEPREFIX"
    printf 'installer_config_path=%s\n' "$installer_config_path"
    printf 'installer_config_state=%s\n' "$reverse_installer_state"
    printf 'pipeasio_config_path=%s\n' "$pipeasio_config_path"
    printf 'pipeasio_config_state=%s\n' "$reverse_pipeasio_state"
    printf 'panel_integration=%s\n' "$panel_integration_now"
} > "$reverse_meta_tmp"
chmod 600 "$reverse_meta_tmp"
ableton_txn_expect "$reverse_meta/metadata" \
    "$(ableton_regular_source_token "$reverse_meta_tmp")"
mv -f -- "$reverse_meta_tmp" "$reverse_meta/metadata"

restore_config_snapshot()
{
    local state="$1" source="$2" target="$3"
    [ "$state" != unchanged ] || return 0
    ableton_txn_snapshot "$target"
    [ ! -d "$target" ] || { echo "!! refusing to replace configuration directory $target" >&2; return 1; }
    if [ "$state" = present ]; then
        ableton_txn_expect "$target" "$(ableton_object_token "$source")"
    else
        ableton_txn_expect "$target" absent
    fi
    if [ "$state" = present ]; then
        ableton_atomic_restore_object "$source" "$target"
    else
        rm -f -- "$target"
    fi
}

echo "== restore recorded configuration =="
restore_config_snapshot "$installer_config_state" \
    "$runtime/.ableton-linux-rollback/installer-config" "$installer_config_path"
restore_config_snapshot "$pipeasio_config_state" \
    "$runtime/.ableton-linux-rollback/pipeasio-config.ini" "$pipeasio_config_path"

if ableton_pipeasio_validate_runtime "$runtime" >/dev/null 2>&1; then
    if [ "$desired_panel" -eq 1 ]; then
        ableton_pipeasio_sync_panel "$runtime" install
    else
        ableton_pipeasio_remove_panel_integration
    fi
else
    # Legacy runtimes have no sealed panel contract.  Remove only projections
    # whose literal manifest digest still proves this project owns them.
    ableton_pipeasio_remove_panel_integration
fi

if [ -f "$ABLETON_WINEPREFIX/system.reg" ]; then
    export WINEPREFIX="$ABLETON_WINEPREFIX"
    probe="$ABLETON_DATA_HOME/pipewire-version-probe"
    [ -x "$probe" ] || probe="$reverse/bin/pipewire-version-probe"
    ableton_pipewire_preflight "$probe" "registering the restored PipeASIO"
    registration_attempted=1
    ableton_pipeasio_register rollback_wine rollback_wineserver_wait
fi

ABLETON_RUNTIME_INSTALLED=1
export ABLETON_RUNTIME_INSTALLED
ableton_write_ownership_manifest
update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true
gtk-update-icon-cache -q "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" >/dev/null 2>&1 || true

rm -f -- "$transaction/active"
trap - EXIT
case "$transaction" in "$ABLETON_STATE_HOME/transactions/rollback."*) rm -rf -- "$transaction" ;; esac

echo "OK: restored the previous runtime and its recorded configuration"
printf '   current runtime: %s\n   undo rollback: %s\n' "$runtime" "$reverse"
