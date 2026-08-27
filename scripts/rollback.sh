#!/usr/bin/env bash
# Restore the newest versioned runtime rollback and its recorded configuration.
# The displaced runtime becomes the next rollback, so the operation is itself
# reversible.  User-owned panel paths are never replaced or removed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
for lib in "$here/lib/config.sh" "$here/config.sh" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    # shellcheck disable=SC1090
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 || {
    echo "!! The previous-version restore cannot find its installation settings." >&2; exit 1; }
# Saved settings are optional to the runtime rollback.  Repair mode salvages
# any individually valid paths from a damaged settings file and, when trusted
# paths were supplied by the caller, lets the core runtime/registry checks
# proceed.  The post-core settings restore below still refuses directories,
# symlinks, and concurrent changes without undoing a valid runtime swap.
ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix state'
export ABLETON_CONFIG_LAYOUT_ROOTS
ableton_config_init repair
for name in lifecycle manifest pipeasio; do
    found=""
    for lib in "$here/lib/$name.sh" "$ABLETON_DATA_HOME/lib/$name.sh"; do
        [ -r "$lib" ] || continue
        # shellcheck disable=SC1090
        . "$lib"
        found=1
        break
    done
    [ -n "$found" ] || { echo "!! The previous-version restore is missing $name.sh." >&2; exit 1; }
done

[ $# -eq 0 ] || { echo "!! Restoring the previous Wine version does not take options." >&2; exit 2; }
ableton_install_lock_acquire

runtime="$ABLETON_WINE_ROOT"
runtime_parent="$(dirname "$runtime")"
runtime_base="$(basename "$runtime")"
if [ -L "$runtime" ] || ! ableton_runtime_marker_valid "$runtime" "$ABLETON_RUNTIME_NAME"; then
    echo "!! The installed Wine runtime is not recognized." >&2
    exit 1
fi

saved=""
saved_mtime=-1
candidate_inventory="$(mktemp "${TMPDIR:-/tmp}/ableton-runtime-rollbacks.XXXXXX")" || {
    echo "!! cannot prepare the search for a previous Wine runtime" >&2
    exit 1
}
if ! find "$runtime_parent" -maxdepth 1 -mindepth 1 -type d -print0 > "$candidate_inventory"; then
    rm -f -- "$candidate_inventory" 2>/dev/null || true
    echo "!! cannot inspect the previous Wine runtimes under $runtime_parent" >&2
    exit 1
fi
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
    if ! candidate_mtime="$(stat -c '%Y' -- "$candidate" 2>/dev/null)"; then
        continue
    fi
    if [ "$candidate_mtime" -gt "$saved_mtime" ]; then
        saved="$candidate"
        saved_mtime="$candidate_mtime"
    fi
done < "$candidate_inventory"
rm -f -- "$candidate_inventory" 2>/dev/null || true
[ -n "$saved" ] || { echo "!! There is no previous Wine version to restore." >&2; exit 1; }
for required in bin/wine bin/wineserver \
    lib/wine/x86_64-windows/pipeasio64.dll \
    lib/wine/x86_64-unix/pipeasio64.dll.so; do
    [ -s "$saved/$required" ] || { echo "!! The previous Wine version is incomplete: $required" >&2; exit 1; }
done
ableton_pipeasio_validate_runtime "$runtime" >/dev/null 2>&1 || {
    echo "!! The installed Wine runtime did not pass its Wine and PipeASIO checks." >&2
    exit 1
}
ableton_pipeasio_validate_runtime "$saved" >/dev/null 2>&1 || {
    echo "!! The previous Wine version did not pass its Wine and PipeASIO checks." >&2
    exit 1
}

saved_meta_dir="$saved/.ableton-linux-rollback"
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
load_saved_settings()
{
    local format recorded_runtime recorded_prefix recorded_installer_path
    local recorded_pipeasio_path saved_installer_state saved_pipeasio_state saved_panel
    [ -d "$saved_meta_dir" ] && [ ! -L "$saved_meta_dir" ] || return 1
    [ -f "$metadata" ] && [ ! -L "$metadata" ] && [ -r "$metadata" ] \
        && ableton_file_has_no_nul "$metadata" || return 1
    format="$(metadata_value format)" || return 1
    recorded_runtime="$(metadata_value runtime_root)" || return 1
    recorded_prefix="$(metadata_value prefix)" || return 1
    recorded_installer_path="$(metadata_value installer_config_path)" || return 1
    recorded_pipeasio_path="$(metadata_value pipeasio_config_path)" || return 1
    saved_installer_state="$(metadata_value installer_config_state)" || return 1
    saved_pipeasio_state="$(metadata_value pipeasio_config_state)" || return 1
    saved_panel="$(metadata_value panel_integration)" || return 1
    [ "$format" = 1 ] \
        && [ "$recorded_runtime" = "$runtime" ] \
        && [ "$recorded_prefix" = "$ABLETON_WINEPREFIX" ] \
        && [ "$recorded_installer_path" = "$installer_config_path" ] \
        && [ "$recorded_pipeasio_path" = "$pipeasio_config_path" ] || return 1
    case "$saved_installer_state:$saved_pipeasio_state:$saved_panel" in
        present:present:0|present:present:1|present:absent:0|present:absent:1|\
        present:unchanged:0|present:unchanged:1|\
        absent:present:0|absent:present:1|absent:absent:0|absent:absent:1|\
        absent:unchanged:0|absent:unchanged:1|\
        unchanged:present:0|unchanged:present:1|\
        unchanged:absent:0|unchanged:absent:1|\
        unchanged:unchanged:0|unchanged:unchanged:1) ;;
        *) return 1 ;;
    esac
    [ "$saved_installer_state" != present ] \
        || rollback_config_snapshot_valid "$saved/.ableton-linux-rollback/installer-config" \
        || return 1
    [ "$saved_pipeasio_state" != present ] \
        || rollback_config_snapshot_valid "$saved/.ableton-linux-rollback/pipeasio-config.ini" \
        || return 1
    installer_config_state="$saved_installer_state"
    pipeasio_config_state="$saved_pipeasio_state"
    desired_panel="$saved_panel"
    metadata_present=1
}
if [ -e "$saved_meta_dir" ] || [ -L "$saved_meta_dir" ]; then
    if ! load_saved_settings; then
        installer_config_state=unchanged
        pipeasio_config_state=unchanged
        desired_panel=0
        metadata_present=0
        echo "!! The saved runtime is usable, but its saved settings are unavailable. Current settings will stay in place." >&2 \
            || true
    fi
fi

refuse_runtime_users()
{
    local runtime_users pid selected_prefix_user=0
    runtime_users="$({ ableton_runtime_pids "$runtime"; ableton_runtime_pids "$saved"; } | sort -u)"
    [ -z "$runtime_users" ] || {
        for pid in $runtime_users; do
            ableton_pid_uses_prefix "$pid" && selected_prefix_user=1
        done
        if [ "$selected_prefix_user" -eq 1 ]; then
            echo "!! Close Live, Max, or the listed Wine program before restoring the previous version." >&2
        else
            echo "!! Close the listed program using this Wine runtime before restoring the previous version." >&2
        fi
        # "close Live" is unactionable when the holder is a windowless agent.
        for pid in $runtime_users; do
            printf '   %s (pid %s)\n' "$(ableton_pid_image "$pid")" "$pid" >&2
        done
        return 1
    }
}
refuse_runtime_users

probe="$runtime/bin/pipewire-version-probe"
ableton_pipewire_preflight "$probe" "rolling PipeASIO back"

transaction=""
transaction_kind=none
transaction_parent=""
# A failure record is useful, but it is not a prerequisite for swapping two
# already validated runtimes. Prefer durable state, fall back to private
# temporary scratch, and continue without either if the host cannot create it.
if ableton_prepare_transactions_dir >/dev/null 2>&1 \
   && transaction="$(mktemp -d "$ABLETON_STATE_HOME/transactions/rollback.XXXXXX" 2>/dev/null)"; then
    transaction_kind=state
    transaction_parent="$ABLETON_STATE_HOME/transactions"
elif transaction="$(mktemp -d "${TMPDIR:-/tmp}/ableton-runtime-restore.XXXXXX" 2>/dev/null)"; then
    transaction_kind=temporary
    transaction_parent="${transaction%/*}"
else
    transaction=""
fi
# The runtime swap has no host-file mutations to journal, so optional panel
# repair does not use manifest.sh's file transaction.
ABLETON_TRANSACTION_DIR=""
export ABLETON_TRANSACTION_DIR

remove_failure_scratch()
{
    local expected_prefix
    [ -n "$transaction" ] || return 0
    case "$transaction_kind" in
        state) expected_prefix="$ABLETON_STATE_HOME/transactions/rollback." ;;
        temporary) expected_prefix="$transaction_parent/ableton-runtime-restore." ;;
        *) return 1 ;;
    esac
    case "$transaction" in "$expected_prefix"*) ;; *) return 1 ;; esac
    if [ ! -e "$transaction" ] && [ ! -L "$transaction" ]; then return 0; fi
    [ -d "$transaction" ] && [ ! -L "$transaction" ] || return 1
    rm -rf -- "$transaction"
    [ ! -e "$transaction" ] && [ ! -L "$transaction" ]
}
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_rollback()
{
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && ! remove_failure_scratch; then
        echo "!! The previous-version restore stopped before changing Wine. Temporary files remain at $transaction." >&2 \
            || true
    fi
    exit "$rc"
}
trap cleanup_unstarted_rollback EXIT

now="$(date -u +%Y%m%dT%H%M%SZ)"
reverse="$runtime-rollback-$now"
if [ -e "$reverse" ] || [ -L "$reverse" ]; then reverse="$reverse-$$"; fi
[ ! -e "$reverse" ] && [ ! -L "$reverse" ] || {
    echo "!! A safe path for the current Wine version could not be prepared." >&2; exit 1; }
current_moved=0
saved_promoted=0
registration_attempted=0
reverse_meta=""
reverse_meta_tmp=""
reverse_meta_preexisting=0
reverse_metadata_ready=0
config_restore_ready=1
panel_restore_ready=1
rollback_committed=0

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
    local rc=$? restore_error="" runtime_layout_restored=1 failure_complete failure_record=""
    trap - EXIT
    # Recovery must not depend on being able to write its explanation to a
    # terminal that may already have closed.
    set +e
    # A normal end reaches the EXIT trap too.  It needs no recovery message;
    # printing the committed-error warning here would falsely tell every
    # successful rollback to rerun the installer.
    [ "$rc" -ne 0 ] || return 0
    if [ "$rollback_committed" -eq 1 ]; then
        echo "!! The previous Wine version is restored. Run the installer again to retry its shortcuts or saved settings." >&2 || true
        exit 0
    fi
    case "$reverse_meta_tmp" in
        "$reverse_meta/.metadata."*)
            if ! rm -f -- "$reverse_meta_tmp"; then
                restore_error="temporary rollback metadata cleanup failed"
            fi ;;
    esac
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
            if ! ableton_pipewire_preflight "$runtime/bin/pipewire-version-probe" \
                    "restoring the original PipeASIO registration" >/dev/null 2>&1 \
               || ! ableton_pipeasio_register rollback_wine rollback_wineserver_wait \
                    >/dev/null 2>&1; then
                restore_error="${restore_error}${restore_error:+; }original PipeASIO registration could not be restored"
            fi
        else
            restore_error="${restore_error}${restore_error:+; }original PipeASIO registration was not retried"
        fi
    fi
    failure_complete="$([ -z "$restore_error" ] && echo yes || echo no)"
    if [ -n "$transaction" ]; then
        failure_record="$transaction/FAILURE"
        if ! printf 'exit=%s\nsaved=%s\nruntime_restored=%s\nrestoration_complete=%s\n' \
            "$rc" "$saved" "$([ "$runtime_layout_restored" -eq 1 ] && echo yes || echo no)" \
            "$failure_complete" > "$failure_record"; then
            failure_record=""
        fi
    fi
    if [ -n "$restore_error" ]; then
        printf '!! The previous Wine version could not be restored automatically: %s\n' \
            "$restore_error" >&2 || true
        if [ -n "$failure_record" ]; then
            echo "!! Leave both Wine runtime directories in place and keep $failure_record before retrying." >&2 \
                || true
        else
            echo "!! Leave both Wine runtime directories in place before retrying; failure details could not be saved." >&2 \
                || true
        fi
    else
        echo "!! The restore did not finish. The Wine version from before this attempt is back in place." >&2 \
            || true
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

echo "== Restore the previous Wine version ==" || true
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

# The runtime swap is usable only after PipeASIO has been registered from the
# restored runtime.  This is the last core rollback step; failures before it put
# the original runtime and registration back.
if [ -f "$ABLETON_WINEPREFIX/system.reg" ]; then
    export WINEPREFIX="$ABLETON_WINEPREFIX"
    probe="$runtime/bin/pipewire-version-probe"
    ableton_pipewire_preflight "$probe" "registering the restored PipeASIO"
    registration_attempted=1
    ableton_pipeasio_register rollback_wine rollback_wineserver_wait
fi
rollback_committed=1
# Everything after the validated runtime swap and PipeASIO registration is
# optional repair, cleanup, or presentation. A closed terminal must not stop
# later saved-setting, panel, inventory, and recovery-file work from running.
set +e

# Save enough information to undo this rollback. This is a convenience after
# the restored runtime and registry are already valid, so failure only removes
# the automatic undo option; it does not reverse a successful rollback.
save_reverse_metadata()
{
    reverse_meta="$reverse/.ableton-linux-rollback"
    if [ -e "$reverse_meta" ] || [ -L "$reverse_meta" ]; then
        [ ! -L "$reverse_meta" ] && [ -d "$reverse_meta" ] || return 1
        reverse_meta_preexisting=1
    else
        mkdir -p -- "$reverse_meta" || return 1
    fi
    if [ -e "$installer_config_path" ] || [ -L "$installer_config_path" ]; then
        ableton_atomic_restore_object "$installer_config_path" \
            "$reverse_meta/installer-config" || return 1
        reverse_installer_state=present
    else
        rm -f -- "$reverse_meta/installer-config" || return 1
        reverse_installer_state=absent
    fi
    if [ -e "$pipeasio_config_path" ] || [ -L "$pipeasio_config_path" ]; then
        ableton_atomic_restore_object "$pipeasio_config_path" \
            "$reverse_meta/pipeasio-config.ini" || return 1
        reverse_pipeasio_state=present
    else
        rm -f -- "$reverse_meta/pipeasio-config.ini" || return 1
        reverse_pipeasio_state=absent
    fi
    reverse_meta_tmp="$(mktemp "$reverse_meta/.metadata.XXXXXX")" || return 1
    if ! {
        printf 'format=1\n'
        printf 'runtime_root=%s\n' "$runtime"
        printf 'prefix=%s\n' "$ABLETON_WINEPREFIX"
        printf 'installer_config_path=%s\n' "$installer_config_path"
        printf 'installer_config_state=%s\n' "$reverse_installer_state"
        printf 'pipeasio_config_path=%s\n' "$pipeasio_config_path"
        printf 'pipeasio_config_state=%s\n' "$reverse_pipeasio_state"
        printf 'panel_integration=%s\n' "$panel_integration_now"
    } > "$reverse_meta_tmp" \
       || ! chmod 600 "$reverse_meta_tmp" \
       || ! mv -f -- "$reverse_meta_tmp" "$reverse_meta/metadata"; then
        return 1
    fi
    reverse_meta_tmp=""
    reverse_metadata_ready=1
}

if ! save_reverse_metadata; then
    case "$reverse_meta_tmp" in
        "$reverse_meta/.metadata."*) rm -f -- "$reverse_meta_tmp" 2>/dev/null || true ;;
    esac
    echo "!! The previous Wine version is restored, but the newer version could not be saved for another switch." >&2 \
        || true
fi

restore_config_snapshot()
{
    local state="$1" source="$2" target="$3"
    [ "$state" != unchanged ] || return 0
    [ ! -d "$target" ] || { echo "!! refusing to replace configuration directory $target" >&2; return 1; }
    if [ "$state" = present ]; then
        ableton_atomic_restore_object "$source" "$target" || return 1
    else
        rm -f -- "$target" || return 1
    fi
}

echo "== Restore saved settings ==" || true
if ! restore_config_snapshot "$installer_config_state" \
    "$runtime/.ableton-linux-rollback/installer-config" "$installer_config_path"; then
    config_restore_ready=0
    echo "!! The previous Wine version is restored, but its installer settings could not be restored." >&2 \
        || true
fi
if ! restore_config_snapshot "$pipeasio_config_state" \
    "$runtime/.ableton-linux-rollback/pipeasio-config.ini" "$pipeasio_config_path"; then
    config_restore_ready=0
    echo "!! The previous Wine version is restored, but its PipeASIO settings could not be restored." >&2 \
        || true
fi

if ableton_pipeasio_validate_runtime "$runtime" >/dev/null 2>&1; then
    if [ "$desired_panel" -eq 1 ]; then
        ableton_pipeasio_sync_panel "$runtime" install || panel_restore_ready=0
    else
        ableton_pipeasio_remove_panel_integration || panel_restore_ready=0
    fi
else
    # Legacy runtimes have no sealed panel contract.  Remove only projections
    # whose literal manifest digest still proves this project owns them.
    ableton_pipeasio_remove_panel_integration || panel_restore_ready=0
fi
[ "$panel_restore_ready" -eq 1 ] \
    || echo "!! The previous Wine version is restored, but the PipeASIO Settings shortcut could not be updated." >&2 \
    || true

ABLETON_RUNTIME_INSTALLED=1
export ABLETON_RUNTIME_INSTALLED
ableton_write_ownership_manifest \
    || echo "!! The previous Wine version is restored, but the installed-file list could not be updated." >&2 \
    || true
update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true

rollback_cleanup_ready=1
remove_failure_scratch || rollback_cleanup_ready=0
[ "$rollback_cleanup_ready" -eq 1 ] \
    || echo "!! The previous Wine version is restored, but temporary files remain at $transaction." >&2 \
    || true

echo "OK: The previous Wine version is restored." || true
printf '   Wine runtime: %s\n' "$runtime" || true
if [ "$reverse_metadata_ready" -eq 1 ]; then
    printf '   newer Wine version saved at: %s\n' "$reverse" || true
else
    echo "   newer Wine version: not saved" || true
fi
[ "$config_restore_ready" -eq 1 ] || echo "   saved settings: retry needed" || true
