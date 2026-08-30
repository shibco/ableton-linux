#!/usr/bin/env bash
# Manifest-driven removal for the standalone installer.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib/config.sh"
. "$here/lib/lifecycle.sh"
. "$here/lib/manifest.sh"
. "$here/lib/preferences.sh"
. "$here/lib/ui.sh"

scope=runtime
scope_seen=""
assume_yes=0
dry_run=0

usage()
{
    cat <<'EOF'
Usage: uninstall.sh [--keep-prefix | --prefix-only | --delete-prefix] [--yes] [--dry-run]

  --keep-prefix    remove Linux integration and the Wine runtime (default)
  --prefix-only    remove only the ableton-linux prefix
  --delete-prefix  remove Linux integration, runtime, prefix, and installer state
EOF
}

for argument in "$@"; do
    case "$argument" in
        --keep-prefix)
            [ -z "$scope_seen" ] || [ "$scope_seen" = runtime ] || {
                printf '!! uninstall scope flags conflict\n' >&2; exit 2;
            }
            scope=runtime; scope_seen=runtime ;;
        --prefix-only)
            [ -z "$scope_seen" ] || [ "$scope_seen" = prefix ] || {
                printf '!! uninstall scope flags conflict\n' >&2; exit 2;
            }
            scope=prefix; scope_seen=prefix ;;
        --delete-prefix)
            [ -z "$scope_seen" ] || [ "$scope_seen" = all ] || {
                printf '!! uninstall scope flags conflict\n' >&2; exit 2;
            }
            scope=all; scope_seen=all ;;
        --yes|-y) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf '!! unknown uninstall option: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
    esac
done

ABLETON_UI_ACTION=uninstall
export ABLETON_UI_ACTION

runtime_status=Remains
prefix_status=Remains
integration_status=Remains
settings_status=Remains
state_status=Remains
report_on_exit=0
lock_held=0

path_exists()
{
    [ -e "$1" ] || [ -L "$1" ]
}

print_report()
{
    ui_heading u_report_heading
    ui_note u_report_runtime "$runtime_status"
    ui_note u_report_prefix "$prefix_status"
    ui_note u_report_integration "$integration_status"
    ui_note u_report_settings "$settings_status"
    ui_note u_report_state "$state_status"
}

cleanup()
{
    local status="$?"
    trap - EXIT HUP INT TERM
    if [ "$lock_held" -eq 1 ]; then
        ableton_install_lock_release >/dev/null 2>&1 || true
    fi
    ui_cleanup "$status" || true
    [ "$report_on_exit" -eq 0 ] || print_report
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

fail()
{
    ableton_config_error "$*"
    return 1
}

raw_target_safe()
{
    local label="$1" raw="$2" safe
    [ -n "$raw" ] && [ ! -L "$raw" ] || {
        fail "unsafe $label target: $raw"
        return 1
    }
    safe="$(ableton_path_is_safe_delete_target "$raw" 2>/dev/null || true)"
    [ -n "$safe" ] || {
        fail "unsafe $label target: $raw"
        return 1
    }
}

resolved_target_safe()
{
    local label="$1" raw="$2" resolved="$3" safe
    safe="$(ableton_path_is_safe_delete_target "$raw" 2>/dev/null || true)"
    [ "$safe" = "$resolved" ] || {
        fail "unsafe $label target: $raw"
        return 1
    }
    if path_exists "$raw"; then
        [ -d "$raw" ] && [ ! -L "$raw" ] || {
            fail "unsafe $label target: $raw"
            return 1
        }
    fi
}

configured_path_matches()
{
    local key="$1" expected="$2" raw resolved
    raw="$(ableton_config_file_value "$key" 2>/dev/null || true)"
    [ -n "$raw" ] || return 1
    resolved="$(ableton_realpath_m "$raw" 2>/dev/null || true)"
    [ "$resolved" = "$expected" ]
}

manifest_parent_safe()
{
    local path="$1" parent resolved expected
    parent="$(dirname -- "$path")" || return 1
    resolved="$(ableton_realpath_m "$parent")" || return 1
    expected="$resolved/$(basename -- "$path")"
    [ "$expected" = "$path" ]
}

validate_manifest()
{
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    local kind path detail extra runtime_count=0
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] || {
        fail "the installed-file list is missing or unsafe: $manifest"
        return 1
    }
    ableton_validate_ownership_manifest "$manifest" || return 1
    while IFS=$'\t' read -r kind path detail extra || [ -n "$kind$path$detail$extra" ]; do
        case "$kind" in
            runtime)
                runtime_count=$((runtime_count + 1))
                [ "$path" = "$ABLETON_WINE_ROOT" ] \
                    && [ "$detail" = "$ABLETON_RUNTIME_NAME" ] || {
                    fail "the installed-file list names a different Wine runtime"
                    return 1
                } ;;
            file|config|symlink)
                manifest_parent_safe "$path" || {
                    fail "the installed-file list reaches an unsafe parent: $path"
                    return 1
                } ;;
        esac
    done < "$manifest"
    [ "$runtime_count" -eq 1 ] || {
        fail "the installed-file list must include one Wine runtime entry"
        return 1
    }
    ableton_validate_prestate_store
}

verify_runtime()
{
    path_exists "$ABLETON_WINE_ROOT" || return 0
    [ -d "$ABLETON_WINE_ROOT" ] && [ ! -L "$ABLETON_WINE_ROOT" ] \
        && ableton_runtime_marker_valid "$ABLETON_WINE_ROOT" "$ABLETON_RUNTIME_NAME" || {
        fail "The Wine runtime marker names a different runtime: $ABLETON_WINE_ROOT"
        return 1
    }
}

verify_prefix()
{
    path_exists "$ABLETON_WINEPREFIX" || return 0
    [ -d "$ABLETON_WINEPREFIX" ] && [ ! -L "$ABLETON_WINEPREFIX" ] \
        && ableton_prefix_marker_valid "$ABLETON_WINEPREFIX" "$ABLETON_WINEPREFIX" || {
        fail "The ableton-linux prefix marker names a different prefix: $ABLETON_WINEPREFIX"
        return 1
    }
}

runtime_idle()
{
    local running
    running="$(ableton_runtime_pids "$ABLETON_WINE_ROOT")"
    [ -z "$running" ] || {
        fail "Wine processes are still using the selected runtime: $running"
        return 1
    }
}

prefix_idle()
{
    local running
    running="$(ableton_prefix_wine_processes_any_runtime \
        "$ABLETON_WINEPREFIX" "$ABLETON_WINE_ROOT")"
    [ -z "$running" ] || {
        fail "Wine processes are still using the selected prefix: $running"
        return 1
    }
}

trash_backend=""

select_trash_backend()
{
    if command -v gio >/dev/null 2>&1; then
        trash_backend=gio
    elif command -v trash-put >/dev/null 2>&1; then
        trash_backend=trash-put
    elif command -v kioclient >/dev/null 2>&1; then
        trash_backend=kioclient
    else
        trash_backend=permanent
    fi
}

remove_path()
{
    local path="$1" status=0
    path_exists "$path" || return 0
    case "$trash_backend" in
        gio) gio trash -- "$path" || status=$? ;;
        trash-put) trash-put "$path" || status=$? ;;
        kioclient) kioclient move "$path" trash:/ || status=$? ;;
        permanent) rm -rf -- "$path" || status=$? ;;
        *) return 1 ;;
    esac
    if [ "$status" -ne 0 ] || path_exists "$path"; then
        fail "removal stopped at $path after the chosen Trash program failed"
        return 1
    fi
    if [ "$trash_backend" = permanent ]; then
        ui_status u_deleted_permanently "$path"
    else
        ui_status u_moved_to_trash "$path"
    fi
}

prestate_backup()
{
    local path="$1" index="$ABLETON_STATE_HOME/install-prestate.tsv"
    [ -f "$index" ] && [ ! -L "$index" ] || return 1
    awk -F '\t' -v p="$path" '$1=="present" && $2==p { print $3; found=1 } END { exit !found }' \
        "$index"
}

restore_previous()
{
    local path="$1" backup backup_digest current_digest
    backup="$(prestate_backup "$path" 2>/dev/null || true)"
    [ -n "$backup" ] || return 0
    backup_digest="$(ableton_manifest_digest "$backup")" || return 1
    current_digest="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    [ "$current_digest" != "$backup_digest" ] || return 0
    path_exists "$path" && return 1
    ableton_atomic_restore_object "$backup" "$path" || return 1
    current_digest="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    [ "$current_digest" = "$backup_digest" ] || return 1
    ui_status pa_restored_previous "$path"
}

remove_installed_path()
{
    remove_path "$1" && restore_previous "$1"
}

live_matches_manifest()
{
    local kind="$1" path="$2" expected="$3" actual
    case "$kind" in
        file|config) [ -f "$path" ] && [ ! -L "$path" ] || return 1 ;;
        symlink) [ -L "$path" ] || return 1 ;;
        *) return 1 ;;
    esac
    actual="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    [ "$actual" = "$expected" ]
}

live_matches_prestate()
{
    local path="$1" backup current_digest backup_digest
    backup="$(prestate_backup "$path" 2>/dev/null || true)"
    [ -n "$backup" ] || return 1
    current_digest="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    backup_digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
    [ -n "$current_digest" ] && [ "$current_digest" = "$backup_digest" ]
}

integration_changed=0

remove_integration()
{
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    local kind path detail extra
    ui_item_begin u_component_integration
    while IFS=$'\t' read -r -u 3 kind path detail extra \
          || [ -n "$kind$path$detail$extra" ]; do
        case "$kind" in file|config|symlink) ;; *) continue ;; esac
        if ! path_exists "$path"; then
            if ! restore_previous "$path"; then
                ui_item_end fail
                fail "restoring the earlier file or link failed at $path"
                return 1
            fi
        elif live_matches_manifest "$kind" "$path" "$detail"; then
            if ! remove_installed_path "$path"; then
                ui_item_end fail
                fail "removal failed for the installed file or link at $path"
                return 1
            fi
        elif live_matches_prestate "$path"; then
            :
        else
            ui_status u_changed_path "$path"
            ui_item_end ok
            ui_question u_q_remove_changed k u_q_remove_changed_yes u_q_remove_changed_no
            ui_item_begin u_component_integration
            if [ "$UI_ANSWER" = r ]; then
                if ! remove_installed_path "$path"; then
                    ui_item_end fail
                    fail "removal failed for the installed file or link at $path"
                    return 1
                fi
            else
                integration_changed=1
                ui_status u_kept_changed "$path"
            fi
        fi
    done 3< "$manifest"
    if [ "$integration_changed" -eq 0 ]; then
        integration_status=Removed
    else
        integration_status='Changed files remain'
    fi
    ui_item_end ok
}

remove_runtime()
{
    ui_item_begin u_component_runtime
    verify_runtime && runtime_idle || { ui_item_end fail; return 1; }
    remove_path "$ABLETON_WINE_ROOT" || { ui_item_end fail; return 1; }
    runtime_status=Removed
    ui_item_end ok
}

remove_prefix()
{
    ui_item_begin u_component_prefix
    verify_prefix && prefix_idle || { ui_item_end fail; return 1; }
    remove_path "$ABLETON_WINEPREFIX" || { ui_item_end fail; return 1; }
    prefix_status=Removed
    ui_item_end ok
}

settings_changed=0

remove_settings()
{
    local preferences="$ABLETON_CONFIG_HOME/preferences" preference_token
    ui_item_begin u_component_settings
    if path_exists "$ABLETON_CONFIG_FILE"; then
        if ableton_managed_config_valid "$ABLETON_CONFIG_FILE"; then
            remove_path "$ABLETON_CONFIG_FILE" || { ui_item_end fail; return 1; }
        else
            settings_changed=1
            ui_status u_kept_changed "$ABLETON_CONFIG_FILE"
        fi
    fi
    if path_exists "$preferences"; then
        if ableton_preferences_valid "$preferences"; then
            preference_token="$(ableton_preferences_object_token "$preferences")" \
                || { ui_item_end fail; return 1; }
            ableton_preferences_remove "$preferences" "$preference_token" remove_path \
                || { ui_item_end fail; return 1; }
        else
            settings_changed=1
            ui_status u_kept_changed "$preferences"
        fi
    fi
    if [ "$settings_changed" -eq 0 ]; then
        settings_status=Removed
    else
        settings_status='Changed files remain'
    fi
    ui_item_end ok
}

prestate_is_restored()
{
    local index="$ABLETON_STATE_HOME/install-prestate.tsv"
    local status path backup extra live_digest backup_digest
    [ -e "$index" ] || return 0
    while IFS=$'\t' read -r status path backup extra || [ -n "$status$path$backup$extra" ]; do
        live_digest="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
        backup_digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
        [ -n "$live_digest" ] && [ "$live_digest" = "$backup_digest" ] || return 1
    done < "$index"
}

state_has_only_removable_data()
{
    local name
    ableton_state_marker_valid "$ABLETON_STATE_HOME" || return 1
    ableton_validate_ownership_manifest "$ABLETON_STATE_HOME/install-manifest.tsv" || return 1
    ableton_validate_prestate_store || return 1
    prestate_is_restored || return 1
    while IFS= read -r name; do
        name="${name##*/}"
        case "$name" in
            .ableton-linux-state|install-manifest.tsv|install-prestate.tsv|install-prestate) ;;
            *) return 1 ;;
        esac
    done < <(find "$ABLETON_STATE_HOME" -mindepth 1 -maxdepth 1 -print)
}

remove_state()
{
    ui_item_begin u_component_state
    if [ "$integration_changed" -eq 0 ] && [ "$settings_changed" -eq 0 ] \
       && state_has_only_removable_data; then
        remove_path "$ABLETON_STATE_HOME" || { ui_item_end fail; return 1; }
        state_status=Removed
    else
        ui_status u_kept_changed "$ABLETON_STATE_HOME"
        state_status=Remains
    fi
    ui_item_end ok
}

ui_step_begin s_remove

ableton_require_home || exit 1
: "${ABLETON_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine}"
: "${ABLETON_CONFIG_FILE:=$ABLETON_CONFIG_HOME/config}"

config_valid=0
runtime_from_config=0
prefix_from_config=0
ableton_managed_config_valid "$ABLETON_CONFIG_FILE" >/dev/null 2>&1 && config_valid=1
if [ -n "${ABLETON_WINE_ROOT+x}" ]; then
    raw_runtime="$ABLETON_WINE_ROOT"
elif [ "$config_valid" -eq 1 ]; then
    raw_runtime="$(ableton_config_file_value runtime_root)"
    runtime_from_config=1
else
    raw_runtime="$HOME/.local/opt/$ABLETON_RUNTIME_NAME"
fi
if [ -n "${ABLETON_WINEPREFIX+x}" ]; then
    raw_prefix="$ABLETON_WINEPREFIX"
elif [ "$config_valid" -eq 1 ]; then
    raw_prefix="$(ableton_config_file_value prefix)"
    prefix_from_config=1
else
    raw_prefix="$HOME/.wine-ableton"
fi

case "$scope" in
    runtime) raw_target_safe runtime "$raw_runtime" || exit 1 ;;
    prefix) raw_target_safe prefix "$raw_prefix" || exit 1 ;;
    all)
        raw_target_safe runtime "$raw_runtime" || exit 1
        raw_target_safe prefix "$raw_prefix" || exit 1 ;;
esac

ABLETON_CONFIG_LAYOUT_ROOTS=none
ABLETON_WINE_ROOT="$raw_runtime"
ABLETON_WINEPREFIX="$raw_prefix"
export ABLETON_CONFIG_LAYOUT_ROOTS ABLETON_WINE_ROOT ABLETON_WINEPREFIX
ableton_config_init repair || exit 1

case "$scope" in
    runtime)
        resolved_target_safe runtime "$raw_runtime" "$ABLETON_WINE_ROOT" || exit 1
        layout_roots='runtime data config state bin' ;;
    prefix)
        resolved_target_safe prefix "$raw_prefix" "$ABLETON_WINEPREFIX" || exit 1
        layout_roots='prefix state' ;;
    all)
        resolved_target_safe runtime "$raw_runtime" "$ABLETON_WINE_ROOT" || exit 1
        resolved_target_safe prefix "$raw_prefix" "$ABLETON_WINEPREFIX" || exit 1
        layout_roots='runtime prefix data config state bin' ;;
esac

if { [ "$runtime_from_config" -eq 1 ] \
     && ! configured_path_matches runtime_root "$ABLETON_WINE_ROOT"; } \
   || { [ "$prefix_from_config" -eq 1 ] \
        && ! configured_path_matches prefix "$ABLETON_WINEPREFIX"; }; then
    fail "the installer configuration names a different runtime or prefix"
    exit 1
fi
ableton_config_validate_layout "$layout_roots" || exit 1

ableton_install_lock_acquire || exit 1
lock_held=1

[ -d "$ABLETON_STATE_HOME" ] && [ ! -L "$ABLETON_STATE_HOME" ] \
    && ableton_state_marker_valid "$ABLETON_STATE_HOME" || {
    fail "the shared installer state needs a valid ownership marker: $ABLETON_STATE_HOME"
    exit 1
}
validate_manifest || exit 1

case "$scope" in
    runtime)
        verify_runtime && runtime_idle || exit 1 ;;
    prefix)
        verify_prefix && prefix_idle || exit 1 ;;
    all)
        verify_runtime && verify_prefix && runtime_idle && prefix_idle || exit 1 ;;
esac

if [ "$dry_run" -eq 1 ]; then
    report_on_exit=1
    exit 0
fi

if [ "$scope" = prefix ] || [ "$scope" = all ]; then
    if [ "$assume_yes" -eq 0 ]; then
        ui_question u_q_delete_prefix k u_q_delete_yes u_q_delete_no
        [ "$UI_ANSWER" = d ] || exit 0
    fi
fi

select_trash_backend
if [ "$trash_backend" = permanent ]; then
    ui_host_warning u_no_trash
    if [ "$assume_yes" -eq 0 ]; then
        ui_question u_q_permanent k u_q_permanent_yes u_q_permanent_no
        [ "$UI_ANSWER" = d ] || exit 0
    fi
fi

report_on_exit=1
case "$scope" in
    runtime)
        remove_integration || exit 1
        remove_runtime || exit 1 ;;
    prefix)
        remove_prefix || exit 1 ;;
    all)
        remove_integration || exit 1
        remove_runtime || exit 1
        remove_prefix || exit 1
        remove_settings || exit 1
        remove_state || exit 1 ;;
esac

exit 0
