#!/usr/bin/env bash
# Remove only project-owned installation state.  Parsing, target validation,
# prefix confirmation, and running-client checks all precede the first mutation.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for lib in "$here/lib/config.sh" "$here/config.sh" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 || {
    echo "!! Uninstall support is incomplete. Run the latest installer again, then retry uninstall." >&2
    exit 1
}
# shellcheck disable=SC1090
for lib in "$here/lib/ui.sh" "$here/ui.sh" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/ui.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ui_step_begin >/dev/null 2>&1 || {
    echo "!! Uninstall support is incomplete. Run the latest installer again, then retry uninstall." >&2
    exit 1
}
# Installer settings are cleanup/retry convenience, not deletion authority.
# Repair mode salvages valid path values (or accepts explicit caller values);
# the runtime/prefix markers and registry checks below remain the hard proof.
ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix'
export ABLETON_CONFIG_LAYOUT_ROOTS
ableton_config_init repair
for lib in "$here/lib/lifecycle.sh" "$ABLETON_DATA_HOME/lib/lifecycle.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_prefix_busy >/dev/null 2>&1 || {
    echo "!! Uninstall support is incomplete. Run the latest installer again, then retry uninstall." >&2
    exit 1
}
for lib in "$here/lib/manifest.sh" "$ABLETON_DATA_HOME/lib/manifest.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_legacy_owned_path >/dev/null 2>&1 || {
    echo "!! Uninstall support is incomplete. Run the latest installer again, then retry uninstall." >&2; exit 1; }
for lib in "$here/lib/pipeasio.sh" "$ABLETON_DATA_HOME/lib/pipeasio.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_pipeasio_unregister >/dev/null 2>&1 || {
    echo "!! PipeASIO removal support is incomplete. Run the latest installer again, then retry uninstall." >&2
    exit 1
}
for lib in "$here/lib/preferences.sh" "$ABLETON_DATA_HOME/lib/preferences.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done

delete_prefix=0
keep_prefix=0
assume_yes=0
dry_run=0
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            ui_note u_usage_line1
            ui_note u_usage_line2
            exit 0 ;;
        --keep-prefix) keep_prefix=1 ;;
        --delete-prefix) delete_prefix=1 ;;
        --prefix) delete_prefix=1; ui_warn u_prefix_flag_deprecated ;;
        --yes|-y) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        *) echo "!! unknown uninstall option: $1" >&2; exit 2 ;;
    esac
    shift
done
[ "$delete_prefix" -eq 0 ] || [ "$keep_prefix" -eq 0 ] || { echo "!! --keep-prefix and --delete-prefix conflict" >&2; exit 2; }
launcher_preferences="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/preferences"
launcher_preferences_token=""
launcher_preferences_snapshot=0
if declare -F ableton_preferences_object_token >/dev/null 2>&1 \
   && launcher_preferences_token="$(
        ableton_preferences_object_token "$launcher_preferences"
   )"; then
    launcher_preferences_snapshot=1
fi
ABLETON_UI_ACTION="${ABLETON_UI_ACTION:-uninstall}"
export ABLETON_UI_ACTION
case "$ABLETON_UI_ACTION" in plan) ui_step_begin s_plan ;; *) ui_step_begin s_remove ;; esac
trap 'ui_cleanup $?' EXIT

retry_mode=--keep-prefix
[ "$delete_prefix" -eq 0 ] || retry_mode=--delete-prefix
optional_cleanup_incomplete=0
retain_retry_support=0

# These fixed support locations are project publications, not user-managed
# configuration. Keep the relative inventory authoritative for both manifest
# filtering and final file/link removal, regardless of the installed bytes.
authoritative_support_relatives=(
    VERSION
    lib/config.sh lib/lifecycle.sh lib/live-options.sh lib/manifest.sh
    lib/pipeasio.sh lib/preferences.sh lib/ui.sh
    detect-scale.sh detect-theme.sh shortcut-hold.sh setup-realtime.sh
    audio-report.sh check-ntsync.sh rollback.sh ntsyncprobe.exe
    pipewire-version-probe setsyscolors.exe learnheal.exe
    "$ABLETON_PROTOCOL_DESKTOP_ID" "$ABLETON_AUZ_DESKTOP_ID"
    ableton-linkd ableton-linkctl setup-link.sh ableton-linkd.service
)
historical_authoritative_support_root=""
historical_support_candidate="$(ableton_realpath_m \
    "$HOME/.local/share/ableton-wine" 2>/dev/null || true)"
if [ -n "$historical_support_candidate" ] \
   && ableton_legacy_project_evidence; then
    historical_authoritative_support_root="$historical_support_candidate"
fi

authoritative_support_path_in_root()
{
    local root="$1" path="$2" relative
    for relative in "${authoritative_support_relatives[@]}"; do
        [ "$path" != "$root/$relative" ] || return 0
    done
    return 1
}

current_authoritative_support_path()
{
    authoritative_support_path_in_root "$ABLETON_DATA_HOME" "$1"
}

authoritative_support_path()
{
    current_authoritative_support_path "$1" && return 0
    [ -n "$historical_authoritative_support_root" ] \
        && authoritative_support_path_in_root \
            "$historical_authoritative_support_root" "$1"
}

print_uninstall_retry()
{
    if [ -n "${ABLETON_INSTALLER_PATH:-}" ]; then
        ui_info u_retry_installer "$ABLETON_INSTALLER_PATH" "$retry_mode"
        printf '   Retry: %q uninstall %s --yes\n' "$ABLETON_INSTALLER_PATH" "$retry_mode" >&2 || true
    else
        ui_info u_retry_script "$here/uninstall.sh" "$retry_mode"
        printf '   Retry: bash %q %s --yes\n' "$here/uninstall.sh" "$retry_mode" >&2 || true
    fi
}

# Optional cleanup warnings take the message key, the remedy key, then the
# message's arguments followed by the remedy's. The log keeps the "!!" line.
warn_optional_notice()
{
    local key="$1" remedy="$2" n
    shift 2
    n="${UI_TEXT[$key]//[!%]/}"
    ui_warn "$key" "${@:1:${#n}}"
    printf '!! warning: %s\n' "$(ui_text "$key" "${@:1:${#n}}")" >&2 || true
    ui_info "$remedy" "${@:${#n}+1}"
    optional_cleanup_incomplete=1
    return 0
}

warn_optional_remaining()
{
    warn_optional_notice "$@"
    retain_retry_support=1
    return 0
}

manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
prestate="$ABLETON_STATE_HOME/install-prestate.tsv"
mime_prestate="$ABLETON_STATE_HOME/mime-prestate.tsv"
uninstall_state_digest()
{
    if [ -e "$1" ] || [ -L "$1" ]; then
        ableton_manifest_digest "$1"
    else
        printf 'absent\n'
    fi
}
safe_runtime="$(ableton_path_is_safe_delete_target "$ABLETON_WINE_ROOT")" || {
    echo "!! unsafe runtime target in configuration: $ABLETON_WINE_ROOT" >&2; exit 2; }
safe_prefix="$(ableton_path_is_safe_delete_target "$ABLETON_WINEPREFIX")" || {
    echo "!! unsafe prefix target in configuration: $ABLETON_WINEPREFIX" >&2; exit 2; }
[ ! -L "$ABLETON_WINE_ROOT" ] || { echo "!! refusing symlink runtime: $ABLETON_WINE_ROOT" >&2; exit 2; }
[ ! -L "$ABLETON_WINEPREFIX" ] || { echo "!! refusing symlink prefix: $ABLETON_WINEPREFIX" >&2; exit 2; }

uninstall_paths_overlap()
{
    local first="$1" second="$2"
    [ "$first" = "$second" ] || [[ "$first" = "$second/"* ]] \
        || [[ "$second" = "$first/"* ]]
}

state_home_overlaps_core=0
if uninstall_paths_overlap "$ABLETON_STATE_HOME" "$safe_runtime" \
   || uninstall_paths_overlap "$ABLETON_STATE_HOME" "$safe_prefix"; then
    state_home_overlaps_core=1
fi

if [ "$state_home_overlaps_core" -eq 0 ] \
   && ableton_install_state_has_active_transaction; then
    echo "!! An earlier installation stopped before recovery finished. Run the latest installer again before uninstalling." >&2
    exit 1
fi
manifest_present=0
[ "$state_home_overlaps_core" -eq 1 ] \
    || { [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; } \
    || manifest_present=1
optional_inventory_usable=1
mime_prestate_usable=1
if [ "$state_home_overlaps_core" -eq 1 ]; then
    optional_inventory_usable=0
    mime_prestate_usable=0
elif [ -e "$mime_prestate" ] || [ -L "$mime_prestate" ]; then
    if [ ! -f "$mime_prestate" ] || [ -L "$mime_prestate" ] || [ ! -r "$mime_prestate" ]; then
        mime_prestate_usable=0
        warn_optional_remaining u_mime_prestate_unsafe u_mime_prestate_unsafe_hint "$mime_prestate"
    elif ! ableton_validate_mime_prestate "$mime_prestate" >/dev/null 2>&1; then
        mime_prestate_usable=0
        warn_optional_remaining u_mime_prestate_unrecognised u_mime_prestate_unrecognised_hint "$mime_prestate"
    fi
else
    mime_prestate_usable=0
fi

pr182_custom_link_adoption=0
if [ "$ABLETON_LINKD" != "$ABLETON_DATA_HOME/ableton-linkd" ] \
   && ableton_pr182_custom_link_recorded "$ABLETON_LINKD"; then
    pr182_custom_link_adoption=1
fi

legacy_state_adoption=0
state_home_usable=1
if [ "$state_home_overlaps_core" -eq 1 ]; then
    state_home_usable=0
    warn_optional_remaining u_state_overlaps_core u_state_overlaps_core_hint "$ABLETON_STATE_HOME"
elif [ -e "$ABLETON_STATE_HOME" ] || [ -L "$ABLETON_STATE_HOME" ]; then
    if ableton_state_marker_valid "$ABLETON_STATE_HOME"; then
        :
    elif [ -d "$ABLETON_STATE_HOME" ] && [ ! -L "$ABLETON_STATE_HOME" ] \
         && ableton_legacy_shortcut_state_valid "$ABLETON_STATE_HOME"; then
        legacy_state_adoption=1
    else
        state_home_usable=0
        optional_inventory_usable=0
        warn_optional_remaining u_state_unrecognised u_state_unrecognised_hint "$ABLETON_STATE_HOME"
    fi
fi
legacy_prefix_adoption=0
if [ "$delete_prefix" -eq 1 ] && [ -e "$safe_prefix" ]; then
    if ! ableton_prefix_marker_valid "$safe_prefix" "$safe_prefix"; then
        if ableton_legacy_default_prefix_valid "$safe_prefix"; then
            legacy_prefix_adoption=1
        else
        echo "!! The Wine prefix was not deleted because the installer could not confirm that it created it: $safe_prefix" >&2
        exit 2
        fi
    fi
    [ -f "$safe_prefix/system.reg" ] || {
        echo "!! The Wine prefix was not deleted because required registry data is missing: $safe_prefix" >&2; exit 2; }
fi
legacy_runtime_adoption=0
if [ -e "$safe_runtime" ] \
   && ! ableton_runtime_marker_valid "$safe_runtime" "$ABLETON_RUNTIME_NAME"; then
    if ableton_legacy_default_runtime_valid "$safe_runtime"; then
        legacy_runtime_adoption=1
    else
        echo "!! The Wine runtime was not deleted because the installer could not confirm that it created it: $safe_runtime" >&2
        exit 2
    fi
fi

mime_prestate_before=unavailable
if [ "$mime_prestate_usable" -eq 1 ]; then
    if ! mime_prestate_before="$(ableton_manifest_digest "$mime_prestate" 2>/dev/null)"; then
        mime_prestate_usable=0
        warn_optional_remaining u_mime_prestate_unreadable u_check_file_permissions_hint "$mime_prestate"
    fi
fi
managed_runtimes=("$safe_runtime")
declare -A managed_runtime_names=(["$safe_runtime"]="$ABLETON_RUNTIME_NAME")
manifest_runtime_records=()

validate_uninstall_state()
{
    local kind path detail extra status backup expected digest candidate record
    local path_hash_record path_hash
    local -A claimed=() prestates=()
    local -a manifest_lines=() prestate_lines=()
    [ "$state_home_usable" -eq 1 ] || return 1
    ableton_validate_install_state_journals >/dev/null 2>&1 || return 1
    if [ -r "$manifest" ]; then
        if ! mapfile -t manifest_lines < "$manifest"; then
            echo "!! the installed-file list could not be read" >&2
            return 1
        fi
        for record in "${manifest_lines[@]}"; do
            if ! IFS=$'\t' read -r kind path detail extra <<< "$record"; then
                echo "!! the installed-file list is invalid" >&2
                return 1
            fi
            if [ -n "$extra" ] || [ -z "$path" ] || ! ableton_manifest_path_ok "$path" \
               || [ -n "${claimed[$path]+x}" ]; then
                echo "!! the installed-file list is invalid or ambiguous" >&2
                return 1
            fi
            claimed["$path"]="$kind"
            case "$kind" in
                file|config|symlink)
                    ableton_managed_path_allowed "$kind" "$path" \
                        && [[ "$detail" =~ ^[0-9a-f]{64}$ ]] || {
                        echo "!! invalid installed-file entry for $path" >&2; return 1; } ;;
                runtime)
                    [ "$detail" = "$ABLETON_RUNTIME_NAME" ] || {
                        echo "!! invalid Wine entry for $path" >&2; return 1; }
                    candidate="$(ableton_path_is_safe_delete_target "$path")" || {
                        echo "!! unsafe Wine path in the installed-file list: $path" >&2; return 1; }
                    [ "$candidate" = "$path" ] || {
                        echo "!! unexpected Wine path in the installed-file list: $path" >&2; return 1; }
                    [ ! -e "$path" ] || ableton_runtime_marker_valid "$path" "$detail" \
                        || { [ "$path" = "$safe_runtime" ] \
                             && [ "$legacy_runtime_adoption" -eq 1 ] \
                             && ableton_legacy_default_runtime_valid "$path"; } || {
                        echo "!! Wine installation is not recognised at $path" >&2; return 1; } ;;
                *) echo "!! unknown entry in the installed-file list: $kind" >&2; return 1 ;;
            esac
        done
    fi

    if [ -e "$prestate" ] || [ -L "$prestate" ]; then
        [ -f "$prestate" ] && [ ! -L "$prestate" ] || {
            echo "!! the list of saved earlier files is unsafe" >&2; return 1; }
        if ! mapfile -t prestate_lines < "$prestate"; then
            echo "!! the list of saved earlier files could not be read" >&2
            return 1
        fi
        for record in "${prestate_lines[@]}"; do
            if ! IFS=$'\t' read -r status path backup extra <<< "$record"; then
                echo "!! the list of saved earlier files is invalid" >&2
                return 1
            fi
            if [ -n "$extra" ] || [ "$status" != present ] || [ -z "$path" ] \
               || ! ableton_manifest_path_ok "$path" || [ -n "${prestates[$path]+x}" ] \
               || [ -z "${claimed[$path]+x}" ] \
               || { [ "${claimed[$path]}" != file ] \
                    && [ "${claimed[$path]}" != config ] \
                    && [ "${claimed[$path]}" != symlink ]; }; then
                echo "!! the list of saved earlier files is invalid or ambiguous" >&2
                return 1
            fi
            path_hash_record="$(printf '%s' "$path" | sha256sum)" || {
                echo "!! the saved earlier copy of $path could not be verified" >&2
                return 1
            }
            path_hash="${path_hash_record%% *}"
            [[ "$path_hash" =~ ^[0-9a-f]{64}$ ]] || {
                echo "!! the saved earlier copy of $path could not be verified" >&2
                return 1
            }
            expected="$ABLETON_STATE_HOME/install-prestate/$path_hash"
            if [ "$backup" != "$expected" ] \
               || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
                echo "!! the saved earlier copy of $path cannot be restored safely" >&2
                return 1
            fi
            digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
            [ -n "$digest" ] || {
                echo "!! the saved earlier copy of $path cannot be read" >&2
                return 1
            }
            prestates["$path"]="$backup"
        done
    fi

    return 0
}

leave_optional_inventory_untouched()
{
    [ "$optional_inventory_usable" -eq 1 ] || return 0
    optional_inventory_usable=0
    manifest_runtime_records=()
    managed_runtimes=("$safe_runtime")
    warn_optional_remaining u_inventory_untrusted u_inventory_untrusted_hint "$manifest" "$prestate"
}

if [ "$optional_inventory_usable" -eq 1 ] \
   && ! validate_uninstall_state >/dev/null 2>&1; then
    leave_optional_inventory_untouched
fi

manifest_before=unavailable
prestate_before=unavailable
if [ "$optional_inventory_usable" -eq 1 ]; then
    if ! manifest_before="$(uninstall_state_digest "$manifest" 2>/dev/null)" \
       || ! prestate_before="$(uninstall_state_digest "$prestate" 2>/dev/null)"; then
        leave_optional_inventory_untouched
    fi
fi

if [ "$optional_inventory_usable" -eq 1 ] && [ -r "$manifest" ]; then
    if ! mapfile -t manifest_runtime_records < "$manifest"; then
        leave_optional_inventory_untouched
    else
        inventory_runtime_invalid=0
        for manifest_record in "${manifest_runtime_records[@]}"; do
            if ! IFS=$'\t' read -r kind path detail extra <<< "$manifest_record" \
               || [ -n "$extra" ]; then
                inventory_runtime_invalid=1
                break
            fi
            [ "$kind" = runtime ] || continue
            [ "$path" != "$safe_runtime" ] || continue
            if ! candidate="$(ableton_path_is_safe_delete_target "$path")" \
               || [ "$candidate" != "$path" ] || [ -L "$path" ] \
               || [ "$detail" != "$ABLETON_RUNTIME_NAME" ] \
               || { [ -e "$candidate" ] \
                    && ! ableton_runtime_marker_valid "$candidate" "$detail"; }; then
                inventory_runtime_invalid=1
                break
            fi
            managed_runtimes+=("$candidate")
            managed_runtime_names["$candidate"]="$detail"
        done
        if [ "$inventory_runtime_invalid" -eq 1 ]; then
            leave_optional_inventory_untouched
        fi
    fi
fi

if [ "$dry_run" -eq 1 ]; then
    ui_status u_plan_heading
    ui_status u_plan_remove_runtimes "${managed_runtimes[*]}"
    if [ "$optional_inventory_usable" -eq 0 ]; then
        ui_status u_plan_leave_desktop
    else
        ui_status u_plan_remove_desktop
    fi
    if [ "$mime_prestate_usable" -eq 1 ]; then
        ui_status u_plan_restore_mime
    elif [ "$optional_inventory_usable" -eq 1 ]; then
        ui_status u_plan_clear_mime
    else
        ui_status u_plan_leave_mime
    fi
    ui_status u_plan_remove_settings
    if [ "$delete_prefix" -eq 0 ] && [ -f "$safe_prefix/system.reg" ]; then
        ui_status u_plan_unregister_pipeasio "$safe_prefix"
    fi
    if ! "$here/setup-link.sh" plan-disable; then
        warn_optional_notice u_plan_link_failed u_plan_link_failed_hint
    fi
    [ "$delete_prefix" -eq 0 ] || ui_status u_plan_delete_prefix "$safe_prefix"
    ui_step_end ok
    exit 0
fi

# Gather all consent before stopping anything or deleting any file.
if [ "$delete_prefix" -eq 1 ] && [ -e "$safe_prefix" ] && [ "$assume_yes" -ne 1 ]; then
    answer=""
    if [ -t 0 ]; then
        ui_status u_plan_delete_prefix "$safe_prefix"
        ui_question u_q_delete_prefix k u_q_delete_yes u_q_delete_no
        answer="$UI_ANSWER"
    fi
    [ "$answer" = d ] || { echo "!! prefix deletion was not confirmed; nothing was changed" >&2; exit 1; }
fi

runtime_pids_all=""
runtime_stop_confirmed="$assume_yes"
for proc in /proc/[0-9]*; do
    pid="${proc#/proc/}"
    ableton_pid_uses_runtime "$pid" && runtime_pids_all="$runtime_pids_all $pid"
done
if [ -n "$runtime_pids_all" ]; then
    scoped=" $(ableton_prefix_pids | tr '\n' ' ') "
    for pid in $runtime_pids_all; do
        case "$scoped" in *" $pid "*) ;; *)
            echo "!! runtime is used by another prefix (PID $pid); close it before uninstalling" >&2
            exit 1 ;;
        esac
    done
    if [ "$assume_yes" -ne 1 ]; then
        answer=""
        if [ -t 0 ]; then
            ui_question u_q_stop_clients l q_stop_prefix_end q_stop_prefix_leave
            answer="$UI_ANSWER"
        fi
        [ "$answer" = e ] || { echo "!! nothing was changed" >&2; exit 1; }
        runtime_stop_confirmed=1
    fi
fi

# A previous configured runtime may also remain in the ownership manifest.
# Never delete it while any process still executes from it; those clients are
# outside the currently selected runtime coordinator and must be closed first.
declare -A skipped_managed_runtimes=()
for candidate in "${managed_runtimes[@]}"; do
    [ "$candidate" != "$safe_runtime" ] || continue
    [ -z "${skipped_managed_runtimes[$candidate]+x}" ] || continue
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        case "$exe" in "$candidate"/*)
            skipped_managed_runtimes["$candidate"]=1
            warn_optional_remaining u_old_runtime_in_use u_old_runtime_in_use_hint "$pid" "$candidate"
            break ;;
        esac
    done
done

# All refusal checks and any interactive consent happen before the lock creates
# installer state.  Once serialized, verify that the inspected installation did
# not change while this process was waiting for the lock.
ableton_install_lock_acquire
if [ "$state_home_overlaps_core" -eq 0 ] \
   && ableton_install_state_has_active_transaction; then
    echo "!! unfinished installer recovery appeared while uninstall was waiting; finish or roll it back first" >&2
    exit 1
fi
if [ "$optional_inventory_usable" -eq 1 ]; then
    manifest_after=unavailable
    prestate_after=unavailable
    if ! manifest_after="$(uninstall_state_digest "$manifest" 2>/dev/null)" \
       || ! prestate_after="$(uninstall_state_digest "$prestate" 2>/dev/null)" \
       || [ "$manifest_before" != "$manifest_after" ] \
       || [ "$prestate_before" != "$prestate_after" ] \
       || ! validate_uninstall_state >/dev/null 2>&1; then
        leave_optional_inventory_untouched
    fi
fi
if [ "$mime_prestate_usable" -eq 1 ]; then
    if ! mime_prestate_after="$(ableton_manifest_digest "$mime_prestate" 2>/dev/null)"; then
        mime_prestate_usable=0
        warn_optional_remaining u_mime_prestate_reread_failed u_check_file_permissions_hint "$mime_prestate"
    elif [ "$mime_prestate_before" != "$mime_prestate_after" ] \
       || ! ableton_validate_mime_prestate "$mime_prestate" >/dev/null 2>&1; then
        mime_prestate_usable=0
        warn_optional_remaining u_mime_prestate_changed u_mime_prestate_changed_hint "$mime_prestate"
    fi
fi
if [ "$state_home_usable" -eq 1 ] \
   && { [ -e "$ABLETON_STATE_HOME" ] || [ -L "$ABLETON_STATE_HOME" ]; } \
   && ! ableton_state_marker_valid "$ABLETON_STATE_HOME" \
   && ! { [ "$legacy_state_adoption" -eq 1 ] \
          && ableton_legacy_shortcut_state_valid "$ABLETON_STATE_HOME"; }; then
    if [ "$legacy_runtime_adoption" -eq 1 ] || [ "$legacy_prefix_adoption" -eq 1 ]; then
        echo "!! The Ableton Linux support directory changed while uninstall was starting, so the older runtime or prefix was left unchanged. Run uninstall again." >&2
        exit 1
    fi
    state_home_usable=0
    legacy_state_adoption=0
    leave_optional_inventory_untouched
    warn_optional_remaining u_state_changed u_inspect_directory_hint "$ABLETON_STATE_HOME"
fi
[ ! -L "$ABLETON_WINE_ROOT" ] && [ ! -L "$ABLETON_WINEPREFIX" ] || {
    echo "!! installation paths changed; retry uninstall" >&2
    exit 1
}
[ ! -e "$safe_runtime" ] \
    || ableton_runtime_marker_valid "$safe_runtime" "$ABLETON_RUNTIME_NAME" \
    || { [ "$legacy_runtime_adoption" -eq 1 ] \
         && ableton_legacy_default_runtime_valid "$safe_runtime"; } || {
    echo "!! The Wine runtime changed or is no longer recognised; nothing was deleted. Run uninstall again." >&2
    exit 1
}
if [ "$delete_prefix" -eq 1 ] && [ -e "$safe_prefix" ]; then
    ableton_prefix_marker_valid "$safe_prefix" "$safe_prefix" \
        || { [ "$legacy_prefix_adoption" -eq 1 ] \
             && ableton_legacy_default_prefix_valid "$safe_prefix"; } || {
        echo "!! The Wine prefix changed or is no longer recognised; nothing was deleted. Run uninstall again." >&2
        exit 1
    }
fi
for candidate in "${managed_runtimes[@]}"; do
    [ "$candidate" = "$safe_runtime" ] || [ -z "${skipped_managed_runtimes[$candidate]+x}" ] \
        || continue
    [ ! -e "$candidate" ] \
        || ableton_runtime_marker_valid "$candidate" "${managed_runtime_names[$candidate]}" \
        || { [ "$candidate" = "$safe_runtime" ] \
             && [ "$legacy_runtime_adoption" -eq 1 ] \
             && ableton_legacy_default_runtime_valid "$candidate"; } || {
        if [ "$candidate" = "$safe_runtime" ]; then
            echo "!! The Wine runtime at $candidate changed or is no longer recognised; nothing was deleted. Run uninstall again." >&2
            exit 1
        fi
        skipped_managed_runtimes["$candidate"]=1
        warn_optional_remaining u_old_runtime_unrecognised u_inspect_runtime_hint "$candidate"
    }
done
if [ "$legacy_state_adoption" -eq 1 ] \
   && [ "$legacy_runtime_adoption" -eq 0 ] && [ "$legacy_prefix_adoption" -eq 0 ]; then
    if ! ableton_mark_state_home; then
        state_home_usable=0
        legacy_state_adoption=0
        leave_optional_inventory_untouched
        warn_optional_remaining u_legacy_state_unprepared u_inspect_path_hint "$ABLETON_STATE_HOME"
    fi
fi
uninstall_adoption_transaction=""
uninstall_adoption_active=0
uninstall_adoption_core_complete=0
uninstall_adoption_cleanup()
{
    local rc=$? restore_rc=0
    trap - EXIT
    ui_cleanup "$rc"
    if [ "$uninstall_adoption_active" -eq 1 ] && [ "$rc" -ne 0 ]; then
        ableton_txn_rollback_files "$uninstall_adoption_transaction" || restore_rc=1
        if [ "$restore_rc" -eq 0 ]; then
            rm -f -- "$uninstall_adoption_transaction/active" 2>/dev/null || true
            if [ -e "$uninstall_adoption_transaction/active" ] \
               || [ -L "$uninstall_adoption_transaction/active" ]; then
                restore_rc=1
            fi
        fi
        if [ "$restore_rc" -eq 0 ]; then
            rm -rf -- "$uninstall_adoption_transaction" 2>/dev/null || true
            if [ -e "$uninstall_adoption_transaction" ] \
               || [ -L "$uninstall_adoption_transaction" ]; then
                restore_rc=1
            fi
        fi
        if [ "$restore_rc" -ne 0 ]; then
            echo "!! Uninstall stopped and the older installation may still need repair. Keep the files at $uninstall_adoption_transaction and report the problem before retrying." >&2
            print_uninstall_retry
        fi
    fi
    exit "$rc"
}
if [ "$legacy_runtime_adoption" -eq 1 ] || [ "$legacy_prefix_adoption" -eq 1 ]; then
    # The adoption transaction itself creates project state. Establish that
    # directory's ownership before creating transactions beneath it, otherwise
    # a legacy install with no prior state would later look like foreign state
    # created by the uninstall itself.
    ableton_prepare_transactions_dir || {
        echo "!! The older Ableton Linux installation could not be prepared safely, so nothing was deleted." >&2
        exit 1
    }
    uninstall_adoption_transaction="$(mktemp -d "$ABLETON_STATE_HOME/transactions/uninstall-adopt.XXXXXX")"
    ABLETON_TRANSACTION_DIR="$uninstall_adoption_transaction"
    export ABLETON_TRANSACTION_DIR
    uninstall_adoption_active=1
    trap uninstall_adoption_cleanup EXIT
    ableton_txn_init
    if [ "$legacy_runtime_adoption" -eq 1 ]; then
        ableton_adopt_runtime_marker "$safe_runtime" "$ABLETON_RUNTIME_NAME"
    fi
    if [ "$legacy_prefix_adoption" -eq 1 ]; then
        ableton_adopt_prefix_marker "$safe_prefix" "$safe_prefix"
    fi
    # Keep only these marker snapshots until uninstall succeeds.  Later file
    # lifecycle work has its own durable records and must not append to this
    # narrow legacy-adoption transaction.
    unset ABLETON_TRANSACTION_DIR
fi
locked_runtime_pids="$(ableton_runtime_pids)"
if [ -n "$locked_runtime_pids" ]; then
    for pid in $locked_runtime_pids; do
        if ! ableton_pid_uses_prefix "$pid"; then
            echo "!! runtime is used by another prefix (PID $pid); close it before uninstalling" >&2
            exit 1
        fi
    done
    [ "$runtime_stop_confirmed" -eq 1 ] || {
        echo "!! a Wine client started while uninstall was waiting; retry when it is closed" >&2
        exit 1
    }
fi
for candidate in "${managed_runtimes[@]}"; do
    [ "$candidate" != "$safe_runtime" ] || continue
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        case "$exe" in "$candidate"/*)
            skipped_managed_runtimes["$candidate"]=1
            warn_optional_remaining u_old_runtime_in_use_late u_old_runtime_in_use_hint "$pid" "$candidate"
            break ;;
        esac
    done
done

# Marker adoption is itself the migration commit.  Finish its private journal
# before the first destructive uninstall action and retain the canonical
# markers on every later partial failure, so a retry no longer depends on
# legacy launcher/VERSION evidence that the first attempt may have removed.
if [ "$uninstall_adoption_active" -eq 1 ]; then
    uninstall_adoption_active=0
    trap 'ui_cleanup $?' EXIT
    if ableton_mark_transaction_core_complete "$uninstall_adoption_transaction" \
        2>/dev/null; then
        uninstall_adoption_core_complete=1
    fi
    rm -f -- "$uninstall_adoption_transaction/active" 2>/dev/null || true
    rm -rf -- "$uninstall_adoption_transaction" 2>/dev/null || true
    if [ -e "$uninstall_adoption_transaction" ] || [ -L "$uninstall_adoption_transaction" ]; then
        if [ "$uninstall_adoption_core_complete" -eq 1 ] \
           || { [ ! -e "$uninstall_adoption_transaction/active" ] \
                && [ ! -L "$uninstall_adoption_transaction/active" ]; }; then
            warn_optional_notice u_adoption_tmp_remains u_adoption_tmp_remains_hint "$uninstall_adoption_transaction"
        else
            warn_optional_remaining u_adoption_tmp_active u_adoption_tmp_active_hint "$uninstall_adoption_transaction"
        fi
    fi
fi

# Resolve every recursive runtime target before deleting any of them. A failed
# or partial directory scan must not look like an empty rollback inventory.
managed_rollbacks=()
declare -A managed_rollback_names=()
declare -A managed_rollback_owners=()
declare -A skipped_managed_rollbacks=()
runtime_inventory=""
if ! runtime_inventory="$(mktemp "${TMPDIR:-/tmp}/ableton-uninstall-runtimes.XXXXXX")"; then
    warn_optional_notice u_rollback_scan_tmp_failed u_rollback_scan_tmp_failed_hint
fi
if [ -n "$runtime_inventory" ]; then
    for candidate in "${managed_runtimes[@]}"; do
        [ -z "${skipped_managed_runtimes[$candidate]+x}" ] || continue
        if ! runtime_parent="$(dirname "$candidate")" \
           || ! runtime_base="$(basename "$candidate")"; then
            warn_optional_remaining u_rollback_scan_path_failed u_rollback_scan_path_failed_hint "$candidate"
            continue
        fi
        if [ -e "$runtime_parent" ] || [ -L "$runtime_parent" ]; then
            if [ ! -d "$runtime_parent" ] || [ -L "$runtime_parent" ]; then
                warn_optional_remaining u_rollback_parent_unsafe u_inspect_that_path_hint "$runtime_parent"
                continue
            fi
        else
            continue
        fi
        if ! : > "$runtime_inventory"; then
            warn_optional_notice u_rollback_scan_tmp_unwritable u_rollback_scan_tmp_unwritable_hint "$runtime_inventory"
            break
        fi
        if ! find "$runtime_parent" -maxdepth 1 -mindepth 1 -type d -print0 \
            > "$runtime_inventory" 2>/dev/null; then
            warn_optional_remaining u_rollback_parent_unreadable u_check_directory_permissions_hint "$runtime_parent"
            continue
        fi
        while IFS= read -r -d '' old_runtime; do
            if ! old_runtime_base="$(basename "$old_runtime")"; then
                warn_optional_remaining u_rollback_unidentified u_inspect_that_path_hint "$old_runtime"
                continue
            fi
            if [[ "$old_runtime_base" != "$runtime_base-rollback-"* \
               && "$old_runtime_base" != "$runtime_base.failed-"* \
               && "$old_runtime_base" != "$runtime_base.transaction-"* ]]; then
                continue
            fi
            if ! old_runtime_safe="$(ableton_path_is_safe_delete_target "$old_runtime")" \
               || [ "$old_runtime_safe" != "$old_runtime" ] || [ -L "$old_runtime" ] \
               || ! ableton_runtime_marker_valid \
                    "$old_runtime" "${managed_runtime_names[$candidate]}"; then
                warn_optional_remaining u_rollback_unrecognised u_rollback_unrecognised_hint "$old_runtime"
                continue
            fi
            managed_rollbacks+=("$old_runtime")
            managed_rollback_names["$old_runtime"]="${managed_runtime_names[$candidate]}"
            managed_rollback_owners["$old_runtime"]="$candidate"
        done < "$runtime_inventory"
    done
    rm -f -- "$runtime_inventory" 2>/dev/null || true
    if [ -e "$runtime_inventory" ] || [ -L "$runtime_inventory" ]; then
        warn_optional_notice u_scan_tmp_remains u_tmp_remains_hint "$runtime_inventory"
    fi
fi

ui_item_begin u_stop_services
uninstall_partial=0
mime_backend_unavailable=0
if [ "$optional_inventory_usable" -eq 1 ] \
   && ! "$here/setup-link.sh" disable; then
    warn_optional_remaining u_link_still_enabled u_link_still_enabled_hint
fi
# Not "busy && stop": under set -euo pipefail a straggler that survives the stop
# makes the compound fail, and the script exits here - after the trap is cleared,
# silently, skipping the PipeASIO unregister, the shortcut restore, the MIME
# cleanup and the runtime removal below.  The stop is best-effort; the gates that
# follow decide what a straggler is allowed to block.
if ableton_prefix_busy "$safe_runtime" "$safe_prefix"; then
    # A surviving process is recorded, not just announced.  The gate below exits
    # before any rm -rf, so marking the uninstall partial is what stops a live
    # client having its runtime - and, under --delete-prefix, its prefix - removed
    # from underneath it.  None of the deletion sites re-check for processes.
    ableton_stop_prefix "$safe_runtime" "$safe_prefix" || true
    if ableton_prefix_busy "$safe_runtime" "$safe_prefix"; then
        echo "!! A Wine program is still running, so the Wine runtime and prefix were left unchanged." >&2
        uninstall_partial=1
    fi
fi
if [ "$uninstall_partial" -eq 1 ]; then
    echo "!! close the remaining Wine program, then run uninstall again" >&2
    exit 1
fi
ui_item_end ok

# A retained prefix must not keep a CLSID pointing into a runtime that is about
# to disappear.  Refuse the runtime deletion unless both exact PipeASIO keys
# are gone and verified; deleting the whole prefix needs no registry mutation.
if [ "$delete_prefix" -eq 0 ] && [ -f "$safe_prefix/system.reg" ]; then
    [ -x "$safe_runtime/bin/wine" ] && [ -x "$safe_runtime/bin/wineserver" ] || {
        echo "!! cannot safely unregister PipeASIO; the selected runtime is incomplete" >&2
        exit 1
    }
    export WINEPREFIX="$safe_prefix"
    uninstall_wine()
    {
        ableton_run_bounded 60 "$safe_runtime/bin/wine" "$@"
    }
    uninstall_wineserver_wait()
    {
        ableton_prefix_wait "$safe_runtime" "$safe_prefix"
    }
    ui_item_begin u_unregister_pipeasio
    ableton_pipeasio_unregister uninstall_wine uninstall_wineserver_wait
    ui_item_end ok
fi

shortcut_helper="$ABLETON_DATA_HOME/shortcut-hold.sh"
shortcut_state="$ABLETON_STATE_HOME/hold-v2"
legacy_shortcut_state="$safe_prefix/.ableton-shortcut-hold"
if [ "$optional_inventory_usable" -eq 1 ] \
   && { [ -e "$shortcut_state" ] || [ -e "$legacy_shortcut_state" ]; }; then
    if [ -r "$shortcut_helper" ] && command -v gsettings >/dev/null 2>&1; then
        # prepare with holding disabled performs both V1 migration and V2 crash
        # recovery, while preserving any shortcut the user changed meanwhile.
        if ! ableton_legacy_owned_path "$shortcut_helper" \
           || ! . "$shortcut_helper" 2>/dev/null \
           || ! declare -F ableton_shortcuts_prepare >/dev/null 2>&1; then
            warn_optional_remaining u_shortcuts_helper_unusable u_shortcuts_helper_unusable_hint "$shortcut_helper"
        elif ! ABLETON_SHORTCUTS=preserve \
             ableton_shortcuts_prepare "" "$legacy_shortcut_state" 0; then
            warn_optional_remaining u_shortcuts_unfinished u_shortcuts_unfinished_hint "$ABLETON_STATE_HOME"
        fi
    fi
    if [ -e "$shortcut_state" ] || [ -e "$legacy_shortcut_state" ]; then
        warn_optional_remaining u_shortcuts_incomplete u_shortcuts_incomplete_hint "${shortcut_state}${legacy_shortcut_state:+ or $legacy_shortcut_state}"
    fi
fi

# The launcher updates the name, icon, and window class in the managed Live
# desktop entry. The saved checksum then describes the earlier file. The shared
# recogniser confirms the template fields and project launcher path. The path
# check limits this instruction to the Live desktop entry.
live_entry_launcher_updated()
{
    local path="$1"
    case "$path" in
        */applications/ableton-live.desktop) ;;
        *) return 1 ;;
    esac
    [ -f "$path" ] || return 1
    [ ! -L "$path" ] || return 1
    ableton_legacy_owned_path "$path"
}

# A launcher replacement keeps the displaced object beside the generated
# launcher as <name>.bak.  New installations deliberately do not duplicate that
# object in the support directory, so the adjacent copy is the user's recovery
# copy.  Resolve the two manifest records together: deleting them independently
# would delete both the generated launcher and the object it replaced.
restore_adjacent_launcher_backup()
{
    local path="$1" path_digest="$2" saved="$3" saved_digest="$4"
    local saved_prestate="${5:-}" saved_prestate_digest="${6:-}"
    local current="" saved_current="" restored="" project_launcher=0

    if [ -e "$path" ] || [ -L "$path" ]; then
        current="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    fi
    if [ -e "$saved" ] || [ -L "$saved" ]; then
        saved_current="$(ableton_manifest_digest "$saved" 2>/dev/null || true)"
    fi

    # A previous attempt may have restored the exact saved launcher and then
    # failed to remove its adjacent copy.  Finish that retry without mistaking
    # the restored launcher for an unrecognised modification.
    if [ -n "$current" ] && [ "$current" = "$saved_digest" ]; then
        if [ -n "$saved_prestate" ]; then
            restore_adjacent_backup_prestate \
                "$saved" "$saved_prestate" "$saved_prestate_digest" "$saved_digest"
            return 0
        fi
        if [ "$saved_current" = "$saved_digest" ]; then
            rm -f -- "$saved" 2>/dev/null || true
            if [ -e "$saved" ] || [ -L "$saved" ]; then
                warn_optional_remaining u_launcher_restored_copy_remains u_check_saved_copy_permissions_hint "$path" "$saved"
            else
                ui_status u_kept_restored_launcher "$path"
            fi
        elif [ ! -e "$saved" ] && [ ! -L "$saved" ]; then
            ui_status u_kept_restored_launcher "$path"
        else
            warn_optional_remaining u_kept_restored_launcher_changed_copy u_kept_restored_launcher_changed_copy_hint "$path" "$saved"
        fi
        return 0
    fi

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        project_launcher=1
    elif [ -n "$current" ] && [ "$current" = "$path_digest" ]; then
        project_launcher=1
    elif live_entry_launcher_updated "$path" \
         || ableton_legacy_owned_path "$path"; then
        project_launcher=1
    fi

    if [ "$project_launcher" -ne 1 ]; then
        warn_optional_remaining u_kept_modified_launcher u_kept_modified_launcher_hint "$path" "$saved"
        return 0
    fi
    if [ -z "$saved_current" ] || [ "$saved_current" != "$saved_digest" ]; then
        warn_optional_remaining u_launcher_saved_copy_invalid u_launcher_saved_copy_invalid_hint "$path" "$saved"
        return 0
    fi

    ableton_atomic_restore_object "$saved" "$path" 2>/dev/null || true
    restored="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    if [ "$restored" != "$saved_digest" ]; then
        warn_optional_remaining u_launcher_restore_failed u_check_destination_permissions_hint "$saved" "$path"
        return 0
    fi

    if [ -n "$saved_prestate" ]; then
        restore_adjacent_backup_prestate \
            "$saved" "$saved_prestate" "$saved_prestate_digest" "$saved_digest"
        return 0
    fi

    rm -f -- "$saved" 2>/dev/null || true
    if [ -e "$saved" ] || [ -L "$saved" ]; then
        warn_optional_remaining u_launcher_restored_copy_remains_late u_check_saved_copy_permissions_hint "$path" "$saved"
    else
        ui_status u_restored_earlier_launcher "$path"
    fi
    return 0
}

# After the adjacent launcher has returned to its canonical path, put back a
# foreign object that occupied <launcher>.bak before installation. The current
# adjacent object may be replaced only when it is the managed displaced
# launcher; any other bytes are preserved alongside the durable saved copy.
restore_adjacent_backup_prestate()
{
    local path="$1" backup="$2" backup_digest="$3" replaceable_digest="$4"
    local current=""
    if [ -e "$path" ] || [ -L "$path" ]; then
        current="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    fi
    if [ "$current" = "$backup_digest" ]; then
        ui_status u_kept_restored_file "$path"
        return 0
    fi
    if [ -n "$current" ] && [ "$current" != "$replaceable_digest" ]; then
        warn_optional_remaining u_kept_changed_saved_launcher u_kept_changed_saved_launcher_hint "$path" "$backup"
        return 0
    fi
    ableton_atomic_restore_object "$backup" "$path" 2>/dev/null || true
    if [ "$(ableton_manifest_digest "$path" 2>/dev/null || true)" != "$backup_digest" ]; then
        warn_optional_remaining u_file_restore_failed u_check_destination_permissions_hint "$path" "$backup"
    else
        ui_status u_restored_earlier_file "$path"
    fi
    return 0
}

remove_owned_manifest_files()
{
    local kind path digest extra current backup backup_digest backup_expected backup_count record
    local launcher saved_path prestate_status prestate_path prestate_backup prestate_digest
    local prestate="$ABLETON_STATE_HOME/install-prestate.tsv" path_hash_record path_hash
    local -a owned_records=() prestate_records=()
    local -A owned_kinds=() owned_digests=() prestate_paths=()
    local -A prestate_backups=() prestate_digests=()
    local -A launcher_backups=() backup_launchers=()
    [ -r "$manifest" ] || return 1
    if ! mapfile -t owned_records < "$manifest"; then
        echo "!! The list of installed support files could not be read; no other support files were removed." >&2
        return 1
    fi
    # Build the complete relation before mutating either member.  Pairing is a
    # fallback only for current snapshot-free installs; an older persistent
    # pre-install record remains authoritative for both paths.
    for record in "${owned_records[@]}"; do
        if ! IFS=$'\t' read -r kind path digest extra <<< "$record"; then
            echo "!! The list of installed support files is not recognised; no other support files were removed." >&2
            return 1
        fi
        current_authoritative_support_path "$path" && continue
        if [ -n "$extra" ]; then
            echo "!! The list of installed support files is not recognised; no other support files were removed." >&2
            return 1
        fi
        case "$kind" in
            file|config|symlink)
                owned_kinds["$path"]="$kind"
                owned_digests["$path"]="$digest" ;;
            runtime) ;;
        esac
    done
    if [ -r "$prestate" ]; then
        if ! mapfile -t prestate_records < "$prestate"; then
            echo "!! The saved copies of files replaced during installation could not be read; no other support files were removed." >&2
            return 1
        fi
        for record in "${prestate_records[@]}"; do
            if ! IFS=$'\t' read -r prestate_status prestate_path prestate_backup extra \
                 <<< "$record"; then
                echo "!! The saved copies of files replaced during installation are not recognised; no other support files were removed." >&2
                return 1
            fi
            current_authoritative_support_path "$prestate_path" && continue
            if [ -n "$extra" ] || [ "$prestate_status" != present ]; then
                echo "!! The saved copies of files replaced during installation are not recognised; no other support files were removed." >&2
                return 1
            fi
            prestate_digest="$(ableton_manifest_digest "$prestate_backup" 2>/dev/null || true)"
            if [ -z "$prestate_digest" ]; then
                echo "!! A saved earlier file could not be read; no other support files were removed." >&2
                return 1
            fi
            prestate_paths["$prestate_path"]=1
            prestate_backups["$prestate_path"]="$prestate_backup"
            prestate_digests["$prestate_path"]="$prestate_digest"
        done
    fi
    for saved_path in "${!owned_kinds[@]}"; do
        case "$saved_path" in *.bak) ;; *) continue ;; esac
        launcher="${saved_path%.bak}"
        [ -n "${owned_kinds[$launcher]+x}" ] || continue
        ableton_launcher_path_allowed "$launcher" || continue
        case "${owned_kinds[$launcher]}:${owned_kinds[$saved_path]}" in
            file:file|file:symlink|symlink:file|symlink:symlink) ;;
            *) continue ;;
        esac
        [ -z "${prestate_paths[$launcher]+x}" ] || continue
        # A launcher from an older release can be byte-identical to the new
        # one while differing only in mode. Both manifest rows then have the
        # same digest, so there is no distinct foreign object to resurrect.
        # Let the normal per-record cleanup remove them (and independently
        # restore anything that previously occupied the adjacent path). This
        # also remains correct when a previous uninstall already removed one
        # member of the pair.
        [ "${owned_digests[$launcher]}" != "${owned_digests[$saved_path]}" ] \
            || continue
        launcher_backups["$launcher"]="$saved_path"
        backup_launchers["$saved_path"]="$launcher"
    done
    for record in "${owned_records[@]}"; do
        if ! IFS=$'\t' read -r kind path digest extra <<< "$record"; then
            echo "!! The list of installed support files is not recognised; no other support files were removed." >&2
            return 1
        fi
        current_authoritative_support_path "$path" && continue
        if [ -n "$extra" ]; then
            echo "!! The list of installed support files is not recognised; no other support files were removed." >&2
            return 1
        fi
        case "$kind" in
            file|config|symlink)
                # The canonical record resolves a snapshot-free launcher pair.
                # Skip the adjacent row so it can never be deleted first.
                [ -z "${backup_launchers[$path]+x}" ] || continue
                if [ -n "${launcher_backups[$path]+x}" ]; then
                    saved_path="${launcher_backups[$path]}"
                    restore_adjacent_launcher_backup \
                        "$path" "$digest" "$saved_path" "${owned_digests[$saved_path]}" \
                        "${prestate_backups[$saved_path]-}" \
                        "${prestate_digests[$saved_path]-}"
                    continue
                fi
                backup=""
                if [ -r "$prestate" ]; then
                    backup_count="$(awk -F '\t' -v p="$path" \
                        '$1=="present" && $2==p { n++ } END { print n+0 }' "$prestate")" || {
                        echo "!! The saved copies of replaced files could not be checked; no other support files were removed." >&2
                        return 1
                    }
                    backup="$(awk -F '\t' -v p="$path" \
                        '$1=="present" && $2==p { print $3; exit }' "$prestate")" || {
                        echo "!! The saved earlier copy of $path could not be checked; no other support files were removed." >&2
                        return 1
                    }
                    case "$backup_count" in ''|*[!0-9]*)
                        echo "!! The saved earlier copy of $path is not recognised; no other support files were removed." >&2
                        return 1 ;;
                    esac
                    if [ "$backup_count" -gt 1 ]; then
                        echo "!! More than one earlier copy was recorded for $path, so it was left unchanged." >&2
                        return 1
                    fi
                fi
                if [ -n "$backup" ]; then
                    path_hash_record="$(printf '%s' "$path" | sha256sum)" || {
                        echo "!! The saved earlier copy of $path could not be verified; no other support files were removed." >&2
                        return 1
                    }
                    path_hash="${path_hash_record%% *}"
                    [[ "$path_hash" =~ ^[0-9a-f]{64}$ ]] || {
                        echo "!! The saved earlier copy of $path could not be verified; no other support files were removed." >&2
                        return 1
                    }
                    backup_expected="$ABLETON_STATE_HOME/install-prestate/$path_hash"
                    if [ "$backup" != "$backup_expected" ] \
                       || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
                        echo "!! The earlier copy of $path could not be restored safely; no other support files were removed." >&2
                        return 1
                    fi
                    backup_digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
                    if [ -z "$backup_digest" ]; then
                        echo "!! The earlier copy of $path could not be read; no other support files were removed." >&2
                        return 1
                    fi
                fi
                if [ ! -e "$path" ] && [ ! -L "$path" ]; then
                    if [ -n "$backup" ]; then
                        ableton_atomic_restore_object "$backup" "$path" || true
                        if [ "$(ableton_manifest_digest "$path" 2>/dev/null || true)" != "$backup_digest" ]; then
                            warn_optional_remaining u_file_restore_failed u_check_destination_permissions_hint "$path" "$backup"
                        else
                            ui_status u_restored_earlier_file "$path"
                        fi
                    fi
                    continue
                fi
                current="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
                if [ "$current" = "$digest" ] || live_entry_launcher_updated "$path" \
                   || ableton_legacy_owned_path "$path"; then
                    if [ -n "$backup" ]; then
                        ableton_atomic_restore_object "$backup" "$path" || true
                        if [ "$(ableton_manifest_digest "$path" 2>/dev/null || true)" != "$backup_digest" ]; then
                            warn_optional_remaining u_file_replace_failed u_file_replace_failed_hint "$path" "$backup"
                        else
                            ui_status u_restored_earlier_file "$path"
                        fi
                    else
                        rm -f -- "$path" 2>/dev/null || true
                        if [ -e "$path" ] || [ -L "$path" ]; then
                            warn_optional_remaining u_file_remains u_check_file_permissions_hint "$path"
                        else
                            ui_status u_removed_path "$path"
                        fi
                    fi
                elif [ -n "$backup" ] && [ "$current" = "$backup_digest" ]; then
                    # A prior partial uninstall may already have restored this
                    # exact pre-install object before another path failed.
                    # Treat that as completed work so a retry can finish.
                    ui_status u_kept_restored_file "$path"
                else
                    if [ "$kind" = config ]; then
                        warn_optional_remaining u_kept_modified_config u_kept_modified_config_hint "$path"
                    elif [ "$kind" = symlink ]; then
                        warn_optional_remaining u_kept_changed_link u_kept_changed_link_hint "$path"
                    elif [ "$pr182_custom_link_adoption" -eq 1 ] \
                         && [ "$path" = "$ABLETON_LINKD" ]; then
                        warn_optional_remaining u_kept_custom_linkd u_kept_custom_linkd_hint "$path"
                    else
                        warn_optional_remaining u_kept_unrecognised_file u_move_aside_if_certain_hint "$path"
                    fi
                fi ;;
            runtime) ;;
        esac
    done
    return 0
}

remove_legacy_files()
{
    local data_root apps icons mime path source relative
    local legacy_data_root
    local legacy_project_proven=0
    data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
    apps="$data_root/applications"; icons="$data_root/icons/hicolor"; mime="$data_root/mime/packages"
    legacy_data_root="$(ableton_realpath_m "$HOME/.local/share/ableton-wine")" || legacy_data_root=""
    if [ -n "$legacy_data_root" ] \
       && [ "$legacy_data_root" = "$historical_authoritative_support_root" ]; then
        legacy_project_proven=1
    fi

    legacy_remove_if_owned()
    {
        local target="$1" original="${2:-}" owned_data_home="${3:-}" owned=0
        [ -e "$target" ] || [ -L "$target" ] || return 0
        authoritative_support_path "$target" && return 0
        if [ -n "$owned_data_home" ]; then
            ABLETON_DATA_HOME="$owned_data_home" \
                ableton_legacy_owned_path "$target" && owned=1
        elif ableton_legacy_owned_path "$target"; then
            owned=1
        fi
        if [ "$owned" -eq 1 ] \
           || { [ -n "$original" ] && [ -f "$original" ] \
                && [ ! -L "$target" ] && cmp -s -- "$original" "$target"; }; then
            rm -f -- "$target" 2>/dev/null || true
            if [ -e "$target" ] || [ -L "$target" ]; then
                warn_optional_remaining u_legacy_file_remains u_check_its_permissions_hint "$target"
            else
                ui_status u_removed_legacy_file "$target"
            fi
        else
            # Wine and other packages install files under these names, and this
            # branch has no digest to tell one of those from a file of ours that
            # the user changed.  Stop rather than guess.
            warn_optional_remaining u_kept_unrecognised_legacy_file u_move_aside_if_certain_hint "$target"
        fi
    }

    if [ "$legacy_project_proven" -eq 1 ]; then
        legacy_remove_if_owned "$legacy_data_root/wine-protocol-ableton.desktop" \
            "" "$legacy_data_root"
        legacy_remove_if_owned "$legacy_data_root/wine-extension-auz.desktop" \
            "" "$legacy_data_root"
    fi

    for path in \
        "$ABLETON_BIN_HOME/ableton-live" "$ABLETON_BIN_HOME/max9" \
        "$ABLETON_DATA_HOME/wine-protocol-ableton.desktop" \
        "$ABLETON_DATA_HOME/wine-extension-auz.desktop" \
        "$apps/ableton-live.desktop" "$apps/$ABLETON_PROTOCOL_DESKTOP_ID" \
        "$apps/$ABLETON_AUZ_DESKTOP_ID" "$apps/wine-protocol-ableton.desktop" \
        "$apps/wine-extension-auz.desktop" "$apps/max9.desktop" \
        "$apps/wine-protocol-c74max.desktop" \
        "$mime/x-wine-extension-auz.xml" "$mime/application-ableton-live.xml"; do
        legacy_remove_if_owned "$path"
    done
    for source in "$here/../desktop/icons/scalable/apps"/*.svg \
                  "$here/../desktop/icons/scalable/mimetypes"/*.svg \
                  "$here/../desktop/icons/symbolic/apps"/*.svg; do
        [ -f "$source" ] || continue
        relative="${source#"$here/../desktop/icons/"}"
        legacy_remove_if_owned "$icons/$relative" "$source"
    done
}

remove_authoritative_support_files()
{
    local root relative path
    local -a roots=("$ABLETON_DATA_HOME")
    if [ -n "$historical_authoritative_support_root" ] \
       && [ "$historical_authoritative_support_root" != "$ABLETON_DATA_HOME" ]; then
        roots+=("$historical_authoritative_support_root")
    fi
    for root in "${roots[@]}"; do
        for relative in "${authoritative_support_relatives[@]}"; do
            path="$root/$relative"
            [ -e "$path" ] || [ -L "$path" ] || continue
            rm -f -- "$path" 2>/dev/null || true
            if [ -e "$path" ] || [ -L "$path" ]; then
                warn_optional_remaining u_file_remains u_check_its_permissions_hint "$path"
            else
                ui_status u_removed_path "$path"
            fi
        done
        rmdir -- "$root/lib" "$root" 2>/dev/null || true
    done
}

# PipeASIO 1.5 panel projections from the pre-manifest installer are adopted
# only when their exact legacy shape still proves project ownership.  Run this
# before removing the legacy VERSION/runtime evidence used by that check.
remove_legacy_panel_files()
{
    local path manifest_count
    for path in \
        "$ABLETON_BIN_HOME/pipeasio-settings" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications/pipeasio-settings.desktop" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/pipeasio.svg"; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        if [ -r "$manifest" ]; then
            manifest_count="$(awk -F '\t' -v p="$path" \
                '$2==p && ($1=="file" || $1=="config" || $1=="symlink") { n++ } END { print n+0 }' \
                "$manifest")" || return 1
            case "$manifest_count" in ''|*[!0-9]*)
                return 1 ;;
            esac
            [ "$manifest_count" -eq 0 ] || continue
        fi
        if ableton_legacy_owned_path "$path"; then
            rm -f -- "$path" 2>/dev/null || true
            if [ -e "$path" ] || [ -L "$path" ]; then
                warn_optional_remaining u_legacy_panel_file_remains u_check_its_permissions_hint "$path"
            else
                ui_status u_removed_legacy_panel_file "$path"
            fi
        else
            warn_optional_remaining u_kept_foreign_panel_file u_kept_foreign_panel_file_hint "$path"
        fi
    done
}

# The explicit "[Default Applications]" line for a type, empty when the file has
# no such line.  Group aware, so an "[Added Associations]" entry never supplies
# the default.  A line before the first group header is malformed, but xdg-mime
# still honours it, so read that too: the clear below has to reach whatever the
# query can see.
mime_explicit_default()
{
    local file="$1" type="$2"
    [ -f "$file" ] || return 0
    awk -v t="$type" '
        /^\[/ { section = $0; next }
        section != "" && section != "[Default Applications]" { next }
        {
            eq = index($0, "=")
            if (eq > 0 && substr($0, 1, eq - 1) == t) { print substr($0, eq + 1); exit }
        }
    ' "$file"
}

discard_mime_scratch()
{
    local tmp="$1"
    rm -f -- "$tmp" 2>/dev/null || true
    if [ -e "$tmp" ] || [ -L "$tmp" ]; then
        warn_optional_notice u_mime_tmp_remains u_tmp_remains_hint "$tmp"
    fi
}

# Drop one type's default.  Group aware for the same reason as the reader: an
# "[Added Associations]" line is the user's own list of applications that may
# open the file, and this project never wrote it.
mime_clear_default()
{
    local file="$1" type="$2" tmp explicit_after
    [ -f "$file" ] || return 0
    tmp="$(mktemp "$(dirname "$file")/.mimeapps.XXXXXX")" || return 1
    if ! awk -v t="$type" '
        /^\[/ { section = $0; print; next }
        section == "" || section == "[Default Applications]" {
            eq = index($0, "=")
            if (eq > 0 && substr($0, 1, eq - 1) == t) { next }
        }
        { print }
    ' "$file" > "$tmp"; then
        discard_mime_scratch "$tmp"
        return 1
    fi
    # Copy the original mode so mv is fully atomic and mode-preserving.  The old
    # sed -i also renamed into place; cat > "$file" truncates first, so a kill
    # mid-write leaves the user's list empty.  Surviving a symlinked
    # mimeapps.list is a bonus, not the main reason.
    if chmod --reference="$file" "$tmp"; then
        mv -f -- "$tmp" "$file" 2>/dev/null || true
    fi
    if explicit_after="$(mime_explicit_default "$file" "$type" 2>/dev/null)" \
       && ! mime_id_is_managed "$explicit_after"; then
        discard_mime_scratch "$tmp"
        return 0
    fi
    discard_mime_scratch "$tmp"
    return 1
}

mime_id_is_managed()
{
    [ -n "$1" ] || return 1
    case "$1" in
        ableton-live.desktop|"$ABLETON_PROTOCOL_DESKTOP_ID"|"$ABLETON_AUZ_DESKTOP_ID"|\
        wine-protocol-ableton.desktop|wine-extension-auz.desktop|max9.desktop|\
        wine-protocol-c74max.desktop) return 0 ;;
    esac
    return 1
}

mime_type_label()
{
    case "$1" in
        x-scheme-handler/ableton) printf '%s\n' 'Ableton browser links' ;;
        application/x-wine-extension-auz) printf '%s\n' 'Ableton authorisation files (.auz)' ;;
        application/x-ableton-live-set) printf '%s\n' 'Live Sets (.als)' ;;
        application/x-ableton-live-clip) printf '%s\n' 'Live Clips (.alc)' ;;
        application/x-ableton-live-pack) printf '%s\n' 'Live Packs (.alp)' ;;
        application/x-ableton-live-max-device) printf '%s\n' 'Max for Live devices (.amxd)' ;;
        x-scheme-handler/c74max) printf '%s\n' 'Max callback links' ;;
        *) printf '%s\n' 'an Ableton file type' ;;
    esac
}

# Restoration takes two passes: one needs our desktop entries present, the other
# needs them gone.
#
# This is the first.  Delete an entry and xdg-mime reports no default for a line
# that still names it, which is how stale lines survived.  Clear here, and verify
# by re-reading mimeapps.list, because a query still resolves the live entries.
clear_mime_defaults()
{
    local type prior extra explicit current mimeapps record type_label
    [ "${#mime_records[@]}" -gt 0 ] || return 0
    if ! command -v xdg-mime >/dev/null 2>&1; then
        mime_backend_unavailable=1
        warn_optional_remaining u_mime_xdg_missing u_mime_xdg_missing_hint
        return 0
    fi
    mimeapps="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
    ui_item_begin u_restore_mime_defaults
    for record in "${mime_records[@]}"; do
        IFS=$'\t' read -r type prior extra <<< "$record"
        [ -n "$type" ] || continue
        type_label="$(mime_type_label "$type")"
        if ! current="$(xdg-mime query default "$type" 2>/dev/null)"; then
            warn_optional_remaining u_mime_query_failed u_mime_query_failed_hint "$type_label"
            continue
        fi
        if ! explicit="$(mime_explicit_default "$mimeapps" "$type")"; then
            warn_optional_remaining u_mime_file_unreadable u_check_file_permissions_hint "$type_label" "$mimeapps"
            continue
        fi
        mime_id_is_managed "$explicit" || mime_id_is_managed "$current" || continue
        if mime_id_is_managed "$explicit" \
           && ! mime_clear_default "$mimeapps" "$type"; then
            warn_optional_remaining u_mime_still_default u_check_file_permissions_hint "$type_label" "$mimeapps"
            continue
        fi
        if ! explicit="$(mime_explicit_default "$mimeapps" "$type")"; then
            warn_optional_remaining u_mime_verify_failed u_check_file_permissions_hint "$type_label" "$mimeapps"
            continue
        fi
        if mime_id_is_managed "$explicit"; then
            warn_optional_remaining u_mime_still_default u_mime_still_default_hint "$type_label" "$mimeapps"
        fi
    done
    ui_item_end ok
    return 0
}

# The second pass runs after the entries are gone and update-desktop-database
# has rebuilt its cache, so a query now reports what the type resolves to
# without this project.  Write the recorded handler back only when the type does
# not already resolve to it.  A default the install found implicit must not come
# back as an explicit line the user never had.
reconcile_mime_defaults()
{
    local type prior extra current explicit mimeapps record type_label
    [ "$mime_prestate_usable" -eq 1 ] && [ -r "$restore_mime" ] || return 0
    [ "$mime_backend_unavailable" -eq 0 ] \
        && command -v xdg-mime >/dev/null 2>&1 || return 0
    mimeapps="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
    for record in "${mime_records[@]}"; do
        IFS=$'\t' read -r type prior extra <<< "$record"
        [ -n "$type" ] || continue
        type_label="$(mime_type_label "$type")"
        if ! current="$(xdg-mime query default "$type" 2>/dev/null)"; then
            warn_optional_remaining u_mime_query_failed_after u_mime_query_failed_hint "$type_label"
            continue
        fi
        # A prior that is itself a managed id names a file this run deleted, so
        # writing it back would recreate the dangling default the first pass
        # cleared.  Leaving it out is safe: a surviving entry still resolves.
        if [ -z "$prior" ] || mime_id_is_managed "$prior"; then
            if mime_id_is_managed "$current"; then
                # Our own entries are out of the desktop database by now, so one
                # of these names can only be a file this run deliberately left
                # alone.  Where it points is the user's business, and the first
                # pass already proved no explicit line of ours survives.
                ui_status u_mime_foreign_default_kept "$type_label"
            fi
            continue
        fi
        [ "$current" != "$prior" ] || continue
        xdg-mime default "$prior" "$type" >/dev/null 2>&1 || true
        if ! explicit="$(mime_explicit_default "$mimeapps" "$type")" \
           || [ "$explicit" != "$prior" ]; then
            warn_optional_remaining u_mime_restore_failed u_mime_restore_failed_hint "$type_label" "$mimeapps"
        fi
    done
    return 0
}

restore_mime="$ABLETON_STATE_HOME/mime-prestate.tsv"
mime_records=()
if [ "$mime_prestate_usable" -eq 1 ]; then
    if ! mapfile -t mime_records < "$restore_mime"; then
        mime_prestate_usable=0
        mime_records=()
        warn_optional_remaining u_mime_prestate_unreadable u_check_file_permissions_hint "$restore_mime"
    else
        declare -A mime_record_types=()
        for mime_record in "${mime_records[@]}"; do
            IFS=$'\t' read -r mime_type mime_prior mime_extra <<< "$mime_record"
            mime_record_valid=1
            [ -z "$mime_extra" ] && [ -n "$mime_type" ] \
                && [ -z "${mime_record_types[$mime_type]+x}" ] \
                || mime_record_valid=0
            case "$mime_type" in
                x-scheme-handler/ableton|application/x-wine-extension-auz|\
                application/x-ableton-live-set|application/x-ableton-live-clip|\
                application/x-ableton-live-pack|application/x-ableton-live-max-device|\
                x-scheme-handler/c74max) ;;
                *) mime_record_valid=0 ;;
            esac
            [ -z "$mime_prior" ] \
                || [[ "$mime_prior" =~ ^[A-Za-z0-9_.+-]+[.]desktop$ ]] \
                || mime_record_valid=0
            if [ "$mime_record_valid" -ne 1 ]; then
                mime_prestate_usable=0
                mime_records=()
                warn_optional_remaining u_mime_prestate_changed_late u_mime_prestate_changed_hint "$restore_mime"
                break
            fi
            mime_record_types["$mime_type"]=1
        done
    fi
fi
mime_cleanup_authorized="$mime_prestate_usable"
if [ "$optional_inventory_usable" -eq 0 ]; then
    mime_cleanup_authorized=0
    mime_records=()
elif [ "$mime_cleanup_authorized" -eq 0 ]; then
    apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    for manifest_record in "${manifest_runtime_records[@]}"; do
        IFS=$'\t' read -r manifest_kind manifest_path _ <<< "$manifest_record"
        case "$manifest_kind:$manifest_path" in
            file:"$apps/ableton-live.desktop"|file:"$apps/max9.desktop"|\
            file:"$apps/$ABLETON_PROTOCOL_DESKTOP_ID"|\
            file:"$apps/$ABLETON_AUZ_DESKTOP_ID"|\
            file:"$apps/wine-protocol-ableton.desktop"|\
            file:"$apps/wine-extension-auz.desktop"|\
            file:"$apps/wine-protocol-c74max.desktop")
                mime_cleanup_authorized=1
                break ;;
        esac
    done
fi
if [ "$optional_inventory_usable" -eq 1 ] \
   && [ "$mime_cleanup_authorized" -eq 0 ]; then
    for mime_project_entry in \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications/ableton-live.desktop" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications/max9.desktop" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$ABLETON_PROTOCOL_DESKTOP_ID" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$ABLETON_AUZ_DESKTOP_ID" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications/wine-protocol-c74max.desktop"; do
        if ableton_legacy_owned_path "$mime_project_entry"; then
            mime_cleanup_authorized=1
            break
        fi
    done
fi
if [ "$mime_cleanup_authorized" -eq 1 ] && [ "${#mime_records[@]}" -eq 0 ]; then
    # Current installs own their default-handler IDs authoritatively and do not
    # retain the default they replaced. Remove only our exact IDs; every other
    # mimeapps.list line stays byte-for-byte in place.
    mime_records=(
        $'x-scheme-handler/ableton\t'
        $'application/x-wine-extension-auz\t'
        $'application/x-ableton-live-set\t'
        $'application/x-ableton-live-clip\t'
        $'application/x-ableton-live-pack\t'
        $'application/x-ableton-live-max-device\t'
        $'x-scheme-handler/c74max\t'
    )
fi
clear_mime_defaults
ui_item_begin u_remove_runtime_files
authoritative_cleanup_ready=0
if [ "$optional_inventory_usable" -eq 1 ]; then
    if ! remove_legacy_panel_files; then
        warn_optional_remaining u_panel_shortcuts_unconfirmed u_panel_shortcuts_unconfirmed_hint
    fi
fi
if [ "$manifest_present" -eq 1 ] && [ "$optional_inventory_usable" -eq 1 ]; then
    if ! remove_owned_manifest_files; then
        leave_optional_inventory_untouched
        warn_optional_remaining u_files_unconfirmed u_files_unconfirmed_hint
    else
        authoritative_cleanup_ready=1
    fi
elif [ "$manifest_present" -eq 0 ] && [ "$optional_inventory_usable" -eq 1 ]; then
    remove_legacy_files
    authoritative_cleanup_ready=1
fi
[ "$authoritative_cleanup_ready" -eq 0 ] || remove_authoritative_support_files

# Revalidate every recursive target as one complete set immediately before the
# first tree deletion. Integration cleanup above is intentionally non-fatal,
# but it must never weaken the ownership proof for a runtime removal.
if [ "$delete_prefix" -eq 1 ] \
   && { [ -e "$safe_prefix" ] || [ -L "$safe_prefix" ]; }; then
    prefix_safe="$(ableton_path_is_safe_delete_target "$safe_prefix")" || {
        echo "!! refusing an unsafe prefix target: $safe_prefix" >&2
        exit 1
    }
    if [ "$prefix_safe" != "$safe_prefix" ] || [ -L "$safe_prefix" ] \
       || ! ableton_prefix_marker_valid "$safe_prefix" "$safe_prefix"; then
        echo "!! The Wine prefix at $safe_prefix changed or is no longer recognised; the runtime and prefix were left unchanged." >&2
        exit 1
    fi
fi
for candidate in "${managed_runtimes[@]}"; do
    [ -z "${skipped_managed_runtimes[$candidate]+x}" ] || continue
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ] && continue
    candidate_safe=""
    candidate_target_valid=1
    candidate_safe="$(ableton_path_is_safe_delete_target "$candidate")" \
        || candidate_target_valid=0
    if [ "$candidate_target_valid" -ne 1 ] \
       || [ "$candidate_safe" != "$candidate" ] || [ -L "$candidate" ] \
       || ! ableton_runtime_marker_valid "$candidate" "${managed_runtime_names[$candidate]}"; then
        if [ "$candidate" = "$safe_runtime" ]; then
            echo "!! The Wine runtime at $candidate changed or is no longer recognised; the runtime and prefix were left unchanged." >&2
            exit 1
        fi
        skipped_managed_runtimes["$candidate"]=1
        warn_optional_remaining u_old_runtime_location_unrecognised u_inspect_runtime_hint "$candidate"
    fi
done
for old_runtime in "${managed_rollbacks[@]}"; do
    if [ "$optional_inventory_usable" -eq 0 ] \
       && [ "${managed_rollback_owners[$old_runtime]}" != "$safe_runtime" ]; then
        skipped_managed_rollbacks["$old_runtime"]=1
        continue
    fi
    [ ! -e "$old_runtime" ] && [ ! -L "$old_runtime" ] && continue
    old_runtime_safe=""
    old_runtime_target_valid=1
    old_runtime_safe="$(ableton_path_is_safe_delete_target "$old_runtime")" \
        || old_runtime_target_valid=0
    if [ "$old_runtime_target_valid" -ne 1 ] \
       || [ "$old_runtime_safe" != "$old_runtime" ] || [ -L "$old_runtime" ] \
       || [ -z "${managed_rollback_names[$old_runtime]:-}" ] \
       || ! ableton_runtime_marker_valid \
            "$old_runtime" "${managed_rollback_names[$old_runtime]}"; then
        skipped_managed_rollbacks["$old_runtime"]=1
        warn_optional_remaining u_rollback_target_unrecognised u_inspect_runtime_hint "$old_runtime"
    fi
done

for candidate in "${managed_runtimes[@]}"; do
    [ -z "${skipped_managed_runtimes[$candidate]+x}" ] || continue
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        candidate_safe=""
        candidate_target_valid=1
        candidate_safe="$(ableton_path_is_safe_delete_target "$candidate")" \
            || candidate_target_valid=0
        if [ "$candidate_target_valid" -ne 1 ] \
           || [ "$candidate_safe" != "$candidate" ] || [ -L "$candidate" ] \
           || ! ableton_runtime_marker_valid \
                "$candidate" "${managed_runtime_names[$candidate]}"; then
            if [ "$candidate" = "$safe_runtime" ]; then
                echo "!! The Wine runtime at $candidate changed or is no longer recognised; it was left unchanged and deletion stopped." >&2
                exit 1
            fi
            skipped_managed_runtimes["$candidate"]=1
            warn_optional_remaining u_old_runtime_location_changed u_inspect_runtime_hint "$candidate"
            continue
        fi
        rm -rf -- "$candidate" 2>/dev/null || true
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            if [ "$candidate" = "$safe_runtime" ]; then
                echo "!! could not remove configured runtime $candidate" >&2
                uninstall_partial=1
            else
                warn_optional_remaining u_old_runtime_remains u_check_its_permissions_hint "$candidate"
            fi
        else
            ui_status u_removed_path "$candidate"
        fi
    fi
done
for old_runtime in "${managed_rollbacks[@]}"; do
    [ -z "${skipped_managed_rollbacks[$old_runtime]+x}" ] || continue
    if [ -e "$old_runtime" ] || [ -L "$old_runtime" ]; then
        old_runtime_safe=""
        old_runtime_target_valid=1
        old_runtime_safe="$(ableton_path_is_safe_delete_target "$old_runtime")" \
            || old_runtime_target_valid=0
        if [ "$old_runtime_target_valid" -ne 1 ] \
           || [ "$old_runtime_safe" != "$old_runtime" ] || [ -L "$old_runtime" ] \
           || ! ableton_runtime_marker_valid \
                "$old_runtime" "${managed_rollback_names[$old_runtime]}"; then
            warn_optional_remaining u_rollback_target_changed u_inspect_runtime_hint "$old_runtime"
            continue
        fi
        rm -rf -- "$old_runtime" 2>/dev/null || true
        if [ -e "$old_runtime" ] || [ -L "$old_runtime" ]; then
            warn_optional_remaining u_rollback_remains u_check_its_permissions_hint "$old_runtime"
        else
            ui_status u_removed_path "$old_runtime"
        fi
    fi
done

if [ "$uninstall_partial" -eq 1 ]; then
    echo "!! runtime removal is incomplete; prefix and uninstall support files were retained" >&2
    print_uninstall_retry
    exit 1
fi

mime_cache_dir="${XDG_DATA_HOME:-$HOME/.local/share}/mime"
if [ -d "$mime_cache_dir" ]; then
    if ! command -v update-mime-database >/dev/null 2>&1; then
        warn_optional_notice u_mime_cache_not_refreshed u_mime_cache_not_refreshed_hint "$mime_cache_dir"
    elif ! update-mime-database "$mime_cache_dir" >/dev/null 2>&1; then
        warn_optional_notice u_mime_cache_refresh_failed u_mime_cache_refresh_failed_hint "$mime_cache_dir"
    fi
fi
desktop_cache_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
if [ -d "$desktop_cache_dir" ]; then
    if ! command -v update-desktop-database >/dev/null 2>&1; then
        warn_optional_notice u_desktop_cache_not_refreshed u_desktop_cache_not_refreshed_hint "$desktop_cache_dir"
    elif ! update-desktop-database "$desktop_cache_dir" >/dev/null 2>&1; then
        warn_optional_notice u_desktop_cache_refresh_failed u_desktop_cache_refresh_failed_hint "$desktop_cache_dir"
    fi
fi
reconcile_mime_defaults

if [ "$delete_prefix" -eq 1 ] \
   && { [ -e "$safe_prefix" ] || [ -L "$safe_prefix" ]; }; then
    prefix_safe="$(ableton_path_is_safe_delete_target "$safe_prefix")" || {
        echo "!! refusing an unsafe prefix target: $safe_prefix" >&2
        exit 1
    }
    if [ "$prefix_safe" != "$safe_prefix" ] || [ -L "$safe_prefix" ] \
       || ! ableton_prefix_marker_valid "$safe_prefix" "$safe_prefix"; then
        echo "!! The Wine prefix at $safe_prefix changed or is no longer recognised; it was left unchanged." >&2
        exit 1
    fi
    rm -rf -- "$safe_prefix" 2>/dev/null || true
    if [ -e "$safe_prefix" ] || [ -L "$safe_prefix" ]; then
        echo "!! The Wine prefix could not be removed: $safe_prefix" >&2
        uninstall_partial=1
    else
        ui_status u_removed_path "$safe_prefix"
    fi
elif [ -e "$safe_prefix" ] || [ -L "$safe_prefix" ]; then
    ui_status u_kept_prefix "$safe_prefix"
else
    ui_status u_no_prefix "$safe_prefix"
fi

if [ "$uninstall_partial" -eq 1 ]; then
    echo "!! prefix removal is incomplete; uninstall support files were retained" >&2
    print_uninstall_retry
    exit 1
fi

# Mutable launcher choices use their own generation check. Core runtime and
# requested-prefix removal finish first, and a changed or unsafe object stays.
if [ "$launcher_preferences_snapshot" -eq 1 ] \
   && declare -F ableton_preferences_remove >/dev/null 2>&1; then
    ableton_preferences_remove \
        "$launcher_preferences" "$launcher_preferences_token" >/dev/null 2>&1 || true
fi

safe_cache="$(ableton_path_is_safe_delete_target "$ABLETON_CACHE_HOME")" || safe_cache=""
[ ! -L "$ABLETON_CACHE_HOME" ] || safe_cache=""
if [ -n "$safe_cache" ]; then
    rmdir -- "$safe_cache" 2>/dev/null || true
    if [ -e "$safe_cache" ] || [ -L "$safe_cache" ]; then
        warn_optional_notice u_cache_dir_remains u_cache_dir_remains_hint "$safe_cache"
    fi
elif [ -e "$ABLETON_CACHE_HOME" ] || [ -L "$ABLETON_CACHE_HOME" ]; then
    warn_optional_notice u_cache_path_unsafe u_inspect_path_remove_if_recognised_hint "$ABLETON_CACHE_HOME"
fi

# Keep enough project support information for a direct retry whenever an
# earlier optional operation left something behind. Otherwise retire each
# support object by outcome, never by a cleanup command's status alone.
if [ "$retain_retry_support" -eq 0 ]; then
    rm -f -- "$restore_mime" 2>/dev/null || true
    if [ -e "$restore_mime" ] || [ -L "$restore_mime" ]; then
        warn_optional_remaining u_mime_prestate_remains u_check_file_permissions_hint "$restore_mime"
    fi
fi
if [ "$retain_retry_support" -eq 0 ]; then
    rm -f -- "$manifest" 2>/dev/null || true
    if [ -e "$manifest" ] || [ -L "$manifest" ]; then
        warn_optional_remaining u_manifest_remains u_check_file_permissions_hint "$manifest"
    fi
fi

if [ "$retain_retry_support" -eq 0 ]; then
    # Managed-file failures have already retained the manifest above.  A data
    # directory can stay nonempty because uninstall just restored the user's
    # earlier files (or because it contains unrelated files).  Preserve those
    # contents without inventing a cleanup failure or retaining stale recovery
    # state forever.
    rmdir -- "$ABLETON_DATA_HOME/lib" "$ABLETON_DATA_HOME" 2>/dev/null || true
fi

if [ "$retain_retry_support" -eq 0 ] \
   && { [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; }; then
    if ableton_managed_config_valid "$ABLETON_CONFIG_FILE"; then
        rm -f -- "$ABLETON_CONFIG_FILE" 2>/dev/null || true
        if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
            warn_optional_remaining u_settings_remain u_check_file_permissions_hint "$ABLETON_CONFIG_FILE"
        fi
    else
        warn_optional_remaining u_settings_changed u_settings_changed_hint "$ABLETON_CONFIG_FILE"
    fi
fi
if [ "$retain_retry_support" -eq 0 ]; then
    # As with the data directory, unrelated files beside the managed settings
    # are not failed uninstall work and do not need installer recovery records.
    rmdir -- "$ABLETON_CONFIG_HOME" 2>/dev/null || true
fi

if [ "$retain_retry_support" -eq 0 ] \
   && { [ -e "$ABLETON_STATE_HOME" ] || [ -L "$ABLETON_STATE_HOME" ]; }; then
    safe_state=""
    if ! safe_state="$(ableton_path_is_safe_delete_target "$ABLETON_STATE_HOME")"; then
        warn_optional_remaining u_state_unsafe_remove u_inspect_path_remove_if_recognised_hint "$ABLETON_STATE_HOME"
    elif [ "$safe_state" != "$ABLETON_STATE_HOME" ] || [ -L "$ABLETON_STATE_HOME" ] \
         || ! ableton_state_marker_valid "$safe_state"; then
        warn_optional_remaining u_state_unconfirmed u_inspect_directory_hint "$ABLETON_STATE_HOME"
    else
        state_marker="$safe_state/.ableton-linux-state"
        backup_root="$safe_state/backups"
        # Keep the ownership marker until every other entry is gone. A partial
        # recursive cleanup therefore remains safe and directly retryable.
        # Per-run overwrite backups are inert manual recovery files. Uninstall
        # never consumes or removes them.
        find "$safe_state" -depth -mindepth 1 \
            ! -path "$state_marker" \
            ! -path "$backup_root" ! -path "$backup_root/*" \
            -delete >/dev/null 2>&1 || true
        if ! state_remaining="$(find "$safe_state" -mindepth 1 \
                ! -path "$state_marker" \
                ! -path "$backup_root" ! -path "$backup_root/*" \
                -printf x -quit 2>/dev/null)"; then
            warn_optional_remaining u_state_check_failed u_state_check_failed_hint "$safe_state"
        elif [ -n "$state_remaining" ]; then
            warn_optional_remaining u_state_files_remain u_state_files_remain_hint "$safe_state"
        elif [ -e "$backup_root" ] || [ -L "$backup_root" ]; then
            ui_status u_kept_backups "$backup_root"
        elif ! ableton_state_marker_valid "$safe_state"; then
            warn_optional_remaining u_state_changed_cleanup u_inspect_directory_hint "$safe_state"
        else
            rm -f -- "$state_marker" 2>/dev/null || true
            if [ -e "$state_marker" ] || [ -L "$state_marker" ]; then
                warn_optional_remaining u_state_marker_remains u_check_file_permissions_hint "$state_marker"
            else
                rmdir -- "$safe_state" 2>/dev/null || true
                if [ -e "$safe_state" ] || [ -L "$safe_state" ]; then
                    if [ -d "$safe_state" ] && [ ! -L "$safe_state" ]; then
                        state_marker_tmp="$(mktemp "$safe_state/.state-marker.XXXXXX" 2>/dev/null || true)"
                        if [ -n "$state_marker_tmp" ]; then
                            if ! printf 'format=1\nowner=ableton-linux\n' > "$state_marker_tmp" \
                               || ! chmod 600 "$state_marker_tmp" \
                               || ! mv -T -n -- "$state_marker_tmp" "$state_marker"; then
                                rm -f -- "$state_marker_tmp" 2>/dev/null || true
                            fi
                        fi
                    fi
                    if ableton_state_marker_valid "$safe_state"; then
                        warn_optional_remaining u_state_dir_empty_remains u_state_dir_empty_remains_hint "$safe_state"
                    else
                        warn_optional_remaining u_state_path_empty_unprepared u_state_path_empty_unprepared_hint "$safe_state"
                    fi
                fi
            fi
        fi
    fi
fi

[ "$optional_cleanup_incomplete" -eq 0 ] || ui_info u_done_with_warnings
ui_item_end ok
[ "$retain_retry_support" -eq 0 ] || print_uninstall_retry
ui_step_end ok
