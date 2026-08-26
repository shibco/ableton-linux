#!/usr/bin/env bash
# Remove only project-owned installation state.  Parsing, target validation,
# prefix confirmation, and running-client checks all precede the first mutation.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for lib in "$here/lib/config.sh" "$here/config.sh" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 || { echo "!! uninstall: config helper is missing" >&2; exit 1; }
ableton_config_init
if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
    ableton_managed_config_valid "$ABLETON_CONFIG_FILE" || {
        echo "!! installer configuration is malformed or user-owned; nothing was changed" >&2
        exit 2
    }
fi
for lib in "$here/lib/lifecycle.sh" "$ABLETON_DATA_HOME/lib/lifecycle.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_prefix_busy >/dev/null 2>&1 || { echo "!! uninstall: lifecycle helper is missing" >&2; exit 1; }
for lib in "$here/lib/manifest.sh" "$ABLETON_DATA_HOME/lib/manifest.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_legacy_owned_path >/dev/null 2>&1 || {
    echo "!! uninstall: ownership helper is missing" >&2; exit 1; }
for lib in "$here/lib/pipeasio.sh" "$ABLETON_DATA_HOME/lib/pipeasio.sh"; do
    if [ -r "$lib" ]; then . "$lib"; break; fi
done
declare -F ableton_pipeasio_unregister >/dev/null 2>&1 || {
    echo "!! uninstall: PipeASIO lifecycle helper is missing" >&2; exit 1; }

delete_prefix=0
keep_prefix=0
assume_yes=0
dry_run=0
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            cat <<'EOF'
Usage: uninstall.sh [--keep-prefix|--delete-prefix] [--yes] [--dry-run]

The prefix is kept by default. --delete-prefix removes Live and its Wine-side
authorisation after validating a project marker (or the legacy default path).
EOF
            exit 0 ;;
        --keep-prefix) keep_prefix=1 ;;
        --delete-prefix) delete_prefix=1 ;;
        --prefix) delete_prefix=1; echo "WARNING: --prefix is deprecated; use --delete-prefix" >&2 ;;
        --yes|-y) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        *) echo "!! unknown uninstall option: $1" >&2; exit 2 ;;
    esac
    shift
done
[ "$delete_prefix" -eq 0 ] || [ "$keep_prefix" -eq 0 ] || { echo "!! --keep-prefix and --delete-prefix conflict" >&2; exit 2; }

manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
prestate="$ABLETON_STATE_HOME/install-prestate.tsv"
mime_prestate="$ABLETON_STATE_HOME/mime-prestate.tsv"
safe_runtime="$(ableton_path_is_safe_delete_target "$ABLETON_WINE_ROOT")" || {
    echo "!! unsafe runtime target in configuration: $ABLETON_WINE_ROOT" >&2; exit 2; }
safe_prefix="$(ableton_path_is_safe_delete_target "$ABLETON_WINEPREFIX")" || {
    echo "!! unsafe prefix target in configuration: $ABLETON_WINEPREFIX" >&2; exit 2; }
[ ! -L "$ABLETON_WINE_ROOT" ] || { echo "!! refusing symlink runtime: $ABLETON_WINE_ROOT" >&2; exit 2; }
[ ! -L "$ABLETON_WINEPREFIX" ] || { echo "!! refusing symlink prefix: $ABLETON_WINEPREFIX" >&2; exit 2; }

for journal in "$manifest" "$prestate" "$mime_prestate"; do
    if [ -e "$journal" ] || [ -L "$journal" ]; then
        [ -f "$journal" ] && [ ! -L "$journal" ] && [ -r "$journal" ] || {
            echo "!! refusing unsafe or unreadable uninstall state: $journal" >&2
            exit 2
        }
    fi
done
ableton_validate_install_state_journals || exit 2
ableton_validate_mime_prestate "$mime_prestate" || exit 2

pr182_custom_link_adoption=0
if [ "$ABLETON_LINKD" != "$ABLETON_DATA_HOME/ableton-linkd" ] \
   && ableton_pr182_custom_link_recorded "$ABLETON_LINKD"; then
    pr182_custom_link_adoption=1
fi

legacy_state_adoption=0
if [ -e "$ABLETON_STATE_HOME" ] || [ -L "$ABLETON_STATE_HOME" ]; then
    if ! { [ -d "$ABLETON_STATE_HOME" ] && [ ! -L "$ABLETON_STATE_HOME" ] \
           && { ableton_state_marker_valid "$ABLETON_STATE_HOME" \
                || ableton_legacy_shortcut_state_valid "$ABLETON_STATE_HOME"; }; }; then
        echo "!! refusing malformed installation state: $ABLETON_STATE_HOME" >&2
        exit 2
    fi
    ableton_state_marker_valid "$ABLETON_STATE_HOME" || legacy_state_adoption=1
fi
legacy_prefix_adoption=0
if [ "$delete_prefix" -eq 1 ] && [ -e "$safe_prefix" ]; then
    if ! ableton_prefix_marker_valid "$safe_prefix" "$safe_prefix"; then
        if ableton_legacy_default_prefix_valid "$safe_prefix"; then
            legacy_prefix_adoption=1
        else
        echo "!! refusing to delete unrecognised custom prefix: $safe_prefix" >&2
        exit 2
        fi
    fi
    [ -f "$safe_prefix/system.reg" ] || {
        echo "!! refusing prefix deletion because system.reg is missing: $safe_prefix" >&2; exit 2; }
fi
legacy_runtime_adoption=0
if [ -e "$safe_runtime" ] \
   && ! ableton_runtime_marker_valid "$safe_runtime" "$ABLETON_RUNTIME_NAME"; then
    if ableton_legacy_default_runtime_valid "$safe_runtime"; then
        legacy_runtime_adoption=1
    else
        echo "!! refusing to delete unrecognised custom runtime: $safe_runtime" >&2
        exit 2
    fi
fi

# Validate every lifecycle journal before any service, registry, Link, or file
# mutation.  This also makes dry-run refuse unsafe state rather than presenting
# a plan that the real uninstall could not safely execute.
ableton_validate_install_state_journals || exit 2
ableton_validate_mime_prestate "$mime_prestate" || exit 2

manifest_before="$(ableton_manifest_digest "$manifest" 2>/dev/null || printf absent)"
prestate_before="$(ableton_manifest_digest "$prestate" 2>/dev/null || printf absent)"
mime_prestate_before="$(ableton_manifest_digest "$mime_prestate" 2>/dev/null || printf absent)"
managed_runtimes=("$safe_runtime")
declare -A managed_runtime_names=(["$safe_runtime"]="$ABLETON_RUNTIME_NAME")
if [ -r "$manifest" ]; then
    while IFS=$'\t' read -r kind path detail; do
        [ "$kind" = runtime ] || continue
        candidate="$(ableton_path_is_safe_delete_target "$path")" || {
            echo "!! unsafe runtime in ownership manifest: $path" >&2; exit 2; }
        [ ! -L "$path" ] || { echo "!! refusing symlink runtime from ownership manifest: $path" >&2; exit 2; }
        [ "$detail" = "$ABLETON_RUNTIME_NAME" ] || {
            echo "!! runtime ownership record has an invalid runtime name: $path" >&2; exit 2; }
        [ ! -e "$candidate" ] || ableton_runtime_marker_valid "$candidate" "$detail" || {
            echo "!! refusing unmarked runtime from ownership manifest: $candidate" >&2; exit 2; }
        duplicate=0
        for path in "${managed_runtimes[@]}"; do
            if [ "$path" = "$candidate" ]; then
                duplicate=1
                [ "${managed_runtime_names[$candidate]}" = "$detail" ] || {
                    echo "!! conflicting runtime ownership records: $candidate" >&2; exit 2; }
            fi
        done
        if [ "$duplicate" -ne 1 ]; then
            managed_runtimes+=("$candidate")
            managed_runtime_names["$candidate"]="$detail"
        fi
    done < "$manifest"
fi

validate_uninstall_state()
{
    local kind path detail extra status backup expected digest type prior candidate
    local manifest_rows=0
    local -A claimed=() prestates=() mime_types=()
    if [ -r "$manifest" ]; then
        while IFS=$'\t' read -r kind path detail extra || [ -n "$kind$path$detail$extra" ]; do
            if [ -n "$extra" ] || [ -z "$path" ] || ! ableton_manifest_path_ok "$path" \
               || [ -n "${claimed[$path]+x}" ]; then
                echo "!! installation ownership manifest is invalid or ambiguous" >&2
                return 1
            fi
            claimed["$path"]="$kind"
            case "$kind" in
                file|config|symlink)
                    [[ "$detail" =~ ^[0-9a-f]{64}$ ]] || {
                        echo "!! invalid ownership digest for $path" >&2; return 1; } ;;
                runtime)
                    [ "$detail" = "$ABLETON_RUNTIME_NAME" ] || {
                        echo "!! invalid runtime ownership record for $path" >&2; return 1; }
                    candidate="$(ableton_path_is_safe_delete_target "$path")" || {
                        echo "!! unsafe runtime ownership record: $path" >&2; return 1; }
                    [ "$candidate" = "$path" ] || {
                        echo "!! non-canonical runtime ownership record: $path" >&2; return 1; }
                    [ ! -e "$path" ] || ableton_runtime_marker_valid "$path" "$detail" || {
                        echo "!! invalid runtime ownership marker: $path" >&2; return 1; } ;;
                *) echo "!! unknown installation ownership record: $kind" >&2; return 1 ;;
            esac
            manifest_rows=$((manifest_rows + 1))
        done < "$manifest"
        [ "$manifest_rows" -gt 0 ] || {
            echo "!! installation ownership manifest is empty" >&2; return 1; }
    fi

    if [ -e "$prestate" ] || [ -L "$prestate" ]; then
        [ -f "$prestate" ] && [ ! -L "$prestate" ] || {
            echo "!! pre-install state index is unsafe" >&2; return 1; }
        while IFS=$'\t' read -r status path backup extra || [ -n "$status$path$backup$extra" ]; do
            if [ -n "$extra" ] || [ "$status" != present ] || [ -z "$path" ] \
               || ! ableton_manifest_path_ok "$path" || [ -n "${prestates[$path]+x}" ] \
               || [ -z "${claimed[$path]+x}" ] \
               || { [ "${claimed[$path]}" != file ] \
                    && [ "${claimed[$path]}" != config ] \
                    && [ "${claimed[$path]}" != symlink ]; }; then
                echo "!! pre-install state is invalid or ambiguous" >&2
                return 1
            fi
            expected="$ABLETON_STATE_HOME/install-prestate/$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
            if [ "$backup" != "$expected" ] \
               || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
                echo "!! cannot safely restore the recorded pre-install file $path" >&2
                return 1
            fi
            digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
            [ -n "$digest" ] || {
                echo "!! cannot read the recorded pre-install file $path" >&2
                return 1
            }
            prestates["$path"]="$backup"
        done < "$prestate"
    fi

    if [ -r "$mime_prestate" ]; then
        while IFS=$'\t' read -r type prior extra || [ -n "$type$prior$extra" ]; do
            [ -z "$extra" ] && [ -n "$type" ] && [ -z "${mime_types[$type]+x}" ] || {
                echo "!! MIME restoration state is invalid or ambiguous" >&2; return 1; }
            case "$type" in
                x-scheme-handler/ableton|application/x-wine-extension-auz|\
                application/x-ableton-live-set|application/x-ableton-live-clip|\
                application/x-ableton-live-pack|application/x-ableton-live-max-device|\
                x-scheme-handler/c74max) ;;
                *) echo "!! MIME restoration state has an unknown type: $type" >&2; return 1 ;;
            esac
            [ -z "$prior" ] || [[ "$prior" =~ ^[A-Za-z0-9_.+-]+[.]desktop$ ]] || {
                echo "!! MIME restoration state has an invalid desktop entry" >&2; return 1; }
            mime_types["$type"]=1
        done < "$mime_prestate"
    fi
    return 0
}

validate_uninstall_state || {
    echo "!! uninstall state is inconsistent; nothing was changed" >&2
    exit 1
}

if [ "$dry_run" -eq 1 ]; then
    echo "PLAN: uninstall project-owned state"
    printf '  remove marked runtime tree(s) and marked rollback siblings: %s\n  ownership manifest: %s\n' \
        "${managed_runtimes[*]}" "$manifest"
    if [ -r "$manifest" ]; then cut -f2 "$manifest" | sed 's/^/  owned file: /'; else echo "  legacy owned integration paths"; fi
    printf '  restore MIME defaults from: %s/mime-prestate.tsv\n' "$ABLETON_STATE_HOME"
    printf '  remove managed config/state after owned files: %s, %s\n' "$ABLETON_CONFIG_FILE" "$ABLETON_STATE_HOME"
    if [ "$delete_prefix" -eq 0 ] && [ -f "$safe_prefix/system.reg" ]; then
        printf '  unregister PipeASIO from retained prefix: %s\n' "$safe_prefix"
    fi
    "$here/setup-link.sh" plan-disable
    [ "$delete_prefix" -eq 0 ] || printf '  delete validated prefix: %s\n' "$safe_prefix"
    exit 0
fi

# Gather all consent before stopping anything or deleting any file.
if [ "$delete_prefix" -eq 1 ] && [ -e "$safe_prefix" ] && [ "$assume_yes" -ne 1 ]; then
    answer=""
    if [ -t 0 ]; then
        printf 'Delete %s? This removes Live and its Wine-side authorisation. [y/N] ' "$safe_prefix" >&2
        read -r -t 60 answer || answer=""
    fi
    case "$answer" in y|Y|yes|YES|Yes) ;; *) echo "!! prefix deletion was not confirmed; nothing was changed" >&2; exit 1 ;; esac
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
            printf 'Stop every running client in the selected prefix and uninstall? [y/N] ' >&2
            read -r -t 60 answer || answer=""
        fi
        case "$answer" in y|Y|yes|YES|Yes) ;; *) echo "!! nothing was changed" >&2; exit 1 ;; esac
        runtime_stop_confirmed=1
    fi
fi

# A previous configured runtime may also remain in the ownership manifest.
# Never delete it while any process still executes from it; those clients are
# outside the currently selected runtime coordinator and must be closed first.
for candidate in "${managed_runtimes[@]}"; do
    [ "$candidate" != "$safe_runtime" ] || continue
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        case "$exe" in "$candidate"/*)
            echo "!! previously managed runtime $candidate is still in use by PID $pid; close it before uninstalling" >&2
            exit 1 ;;
        esac
    done
done

# All refusal checks and any interactive consent happen before the lock creates
# installer state.  Once serialized, verify that the inspected installation did
# not change while this process was waiting for the lock.
ableton_install_lock_acquire
[ "$manifest_before" = "$(ableton_manifest_digest "$manifest" 2>/dev/null || printf absent)" ] || {
    echo "!! installation ownership changed; retry uninstall" >&2
    exit 1
}
[ "$prestate_before" = "$(ableton_manifest_digest "$prestate" 2>/dev/null || printf absent)" ] || {
    echo "!! pre-install restoration state changed; retry uninstall" >&2
    exit 1
}
[ "$mime_prestate_before" = "$(ableton_manifest_digest "$mime_prestate" 2>/dev/null || printf absent)" ] || {
    echo "!! MIME restoration state changed; retry uninstall" >&2
    exit 1
}
# The lock serializes project installers, but it may have been contended while
# consent was gathered.  Re-run the full byte-level and relationship checks,
# not only the digests, before adopting ownership or stopping anything.
ableton_validate_install_state_journals || exit 1
ableton_validate_mime_prestate "$mime_prestate" || exit 1
validate_uninstall_state || {
    echo "!! uninstall state changed or became inconsistent; retry uninstall" >&2
    exit 1
}
[ ! -e "$ABLETON_STATE_HOME" ] || ableton_state_marker_valid "$ABLETON_STATE_HOME" \
    || { [ "$legacy_state_adoption" -eq 1 ] \
         && ableton_legacy_shortcut_state_valid "$ABLETON_STATE_HOME"; } || {
    echo "!! installation state ownership changed; retry uninstall" >&2
    exit 1
}
[ ! -L "$ABLETON_WINE_ROOT" ] && [ ! -L "$ABLETON_WINEPREFIX" ] || {
    echo "!! installation paths changed; retry uninstall" >&2
    exit 1
}
[ ! -e "$safe_runtime" ] \
    || ableton_runtime_marker_valid "$safe_runtime" "$ABLETON_RUNTIME_NAME" \
    || { [ "$legacy_runtime_adoption" -eq 1 ] \
         && ableton_legacy_default_runtime_valid "$safe_runtime"; } || {
    echo "!! runtime ownership changed; retry uninstall" >&2
    exit 1
}
if [ "$delete_prefix" -eq 1 ] && [ -e "$safe_prefix" ]; then
    ableton_prefix_marker_valid "$safe_prefix" "$safe_prefix" \
        || { [ "$legacy_prefix_adoption" -eq 1 ] \
             && ableton_legacy_default_prefix_valid "$safe_prefix"; } || {
        echo "!! prefix ownership changed; retry uninstall" >&2
        exit 1
    }
fi
for candidate in "${managed_runtimes[@]}"; do
    [ ! -e "$candidate" ] \
        || ableton_runtime_marker_valid "$candidate" "${managed_runtime_names[$candidate]}" \
        || { [ "$candidate" = "$safe_runtime" ] \
             && [ "$legacy_runtime_adoption" -eq 1 ] \
             && ableton_legacy_default_runtime_valid "$candidate"; } || {
        echo "!! runtime ownership changed; retry uninstall: $candidate" >&2
        exit 1
    }
done
if [ "$legacy_state_adoption" -eq 1 ]; then
    ableton_mark_state_home || {
        echo "!! legacy installation state could not be adopted safely" >&2
        exit 1
    }
fi
uninstall_adoption_transaction=""
uninstall_adoption_active=0
uninstall_adoption_cleanup()
{
    local rc=$? restore_rc=0
    trap - EXIT
    if [ "$uninstall_adoption_active" -eq 1 ] && [ "$rc" -ne 0 ]; then
        ableton_txn_rollback_files "$uninstall_adoption_transaction" || restore_rc=1
        if [ "$restore_rc" -eq 0 ]; then
            rm -f -- "$uninstall_adoption_transaction/active" || restore_rc=1
        fi
        if [ "$restore_rc" -eq 0 ]; then
            rm -rf -- "$uninstall_adoption_transaction" || restore_rc=1
        fi
        if [ "$restore_rc" -ne 0 ]; then
            echo "!! legacy ownership-marker restoration or transaction cleanup is incomplete; inspect $uninstall_adoption_transaction" >&2
        fi
    fi
    exit "$rc"
}
if [ "$legacy_runtime_adoption" -eq 1 ] || [ "$legacy_prefix_adoption" -eq 1 ]; then
    mkdir -p -- "$ABLETON_STATE_HOME/transactions"
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
            echo "!! previously managed runtime $candidate became busy; retry uninstall" >&2
            exit 1 ;;
        esac
    done
done

# Marker adoption is itself the migration commit.  Finish its private journal
# before the first destructive uninstall action and retain the canonical
# markers on every later partial failure, so a retry no longer depends on
# legacy launcher/VERSION evidence that the first attempt may have removed.
if [ "$uninstall_adoption_active" -eq 1 ]; then
    uninstall_adoption_active=0
    trap - EXIT
    if ! rm -f -- "$uninstall_adoption_transaction/active" \
       || ! rm -rf -- "$uninstall_adoption_transaction" \
       || [ -e "$uninstall_adoption_transaction" ] \
       || [ -L "$uninstall_adoption_transaction" ]; then
        echo "!! legacy ownership was adopted, but migration cleanup is incomplete; retry uninstall" >&2
        exit 1
    fi
fi

echo "== stop project-owned services and processes =="
uninstall_partial=0
# A MIME failure must not reach the gate that guards the runtime removal, so
# this folds it into uninstall_partial only at the final gate.
mime_partial=0
"$here/setup-link.sh" disable
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
    ableton_stop_prefix "$safe_runtime" "$safe_prefix" || {
        echo "!! a program in the prefix outlived the stop; keeping the runtime and prefix" >&2
        uninstall_partial=1
    }
fi

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
    echo "== unregister PipeASIO from the retained prefix =="
    ableton_pipeasio_unregister uninstall_wine uninstall_wineserver_wait
fi

shortcut_helper="$ABLETON_DATA_HOME/shortcut-hold.sh"
shortcut_state="$ABLETON_STATE_HOME/hold-v2"
legacy_shortcut_state="$safe_prefix/.ableton-shortcut-hold"
if [ -e "$shortcut_state" ] || [ -e "$legacy_shortcut_state" ]; then
    if [ -r "$shortcut_helper" ] && command -v gsettings >/dev/null 2>&1; then
        # prepare with holding disabled performs both V1 migration and V2 crash
        # recovery, while preserving any shortcut the user changed meanwhile.
        . "$shortcut_helper"
        ABLETON_SHORTCUTS=preserve ableton_shortcuts_prepare "" "$legacy_shortcut_state" 0
    fi
    if [ -e "$shortcut_state" ] || [ -e "$legacy_shortcut_state" ]; then
        echo "!! shortcut recovery state could not be fully restored; keeping installer state for retry" >&2
        uninstall_partial=1
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

remove_owned_manifest_files()
{
    local kind path digest current backup backup_digest backup_expected backup_count
    local prestate="$ABLETON_STATE_HOME/install-prestate.tsv" rc=0
    [ -r "$manifest" ] || return 1
    while IFS=$'\t' read -r kind path digest; do
        case "$kind" in
            file|config|symlink)
                backup=""
                if [ -r "$prestate" ]; then
                    backup_count="$(awk -F '\t' -v p="$path" \
                        '$1=="present" && $2==p { n++ } END { print n+0 }' "$prestate")"
                    backup="$(awk -F '\t' -v p="$path" '$1=="present" && $2==p { print $3; exit }' "$prestate")"
                    if [ "$backup_count" -gt 1 ]; then
                        echo "!! pre-install state is ambiguous for $path" >&2
                        rc=1; uninstall_partial=1; continue
                    fi
                fi
                if [ -n "$backup" ]; then
                    backup_expected="$ABLETON_STATE_HOME/install-prestate/$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
                    if [ "$backup" != "$backup_expected" ] \
                       || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
                        echo "!! cannot safely restore the recorded pre-install file $path" >&2
                        rc=1; uninstall_partial=1; continue
                    fi
                    backup_digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
                    if [ -z "$backup_digest" ]; then
                        echo "!! cannot read the recorded pre-install file $path" >&2
                        rc=1; uninstall_partial=1; continue
                    fi
                fi
                if [ ! -e "$path" ] && [ ! -L "$path" ]; then
                    if [ -n "$backup" ]; then
                        if ! ableton_atomic_restore_object "$backup" "$path" \
                           || [ "$(ableton_manifest_digest "$path" 2>/dev/null || true)" != "$backup_digest" ]; then
                            echo "!! could not restore pre-install file $path" >&2
                            rc=1; uninstall_partial=1
                        else
                            echo "restored pre-install file $path"
                        fi
                    fi
                    continue
                fi
                current="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
                if [ "$current" = "$digest" ] || live_entry_launcher_updated "$path"; then
                    if [ -n "$backup" ]; then
                        if ! ableton_atomic_restore_object "$backup" "$path" \
                           || [ "$(ableton_manifest_digest "$path" 2>/dev/null || true)" != "$backup_digest" ]; then
                            echo "!! managed file could not be replaced by its pre-install file: $path" >&2
                            rc=1; uninstall_partial=1
                        else
                            echo "restored pre-install file $path"
                        fi
                    else
                        if ! rm -f -- "$path" || [ -e "$path" ] || [ -L "$path" ]; then
                            echo "!! could not remove managed file $path" >&2
                            rc=1; uninstall_partial=1
                        else
                            echo "removed $path"
                        fi
                    fi
                elif [ -n "$backup" ] && [ "$current" = "$backup_digest" ]; then
                    # A prior partial uninstall may already have restored this
                    # exact pre-install object before another path failed.
                    # Treat that as completed work so a retry can finish.
                    echo "kept already-restored pre-install file $path"
                else
                    if [ "$kind" = config ]; then
                        echo "kept user-modified configuration $path"
                    elif [ "$kind" = symlink ]; then
                        echo "kept user-owned link $path"
                    elif [ "$pr182_custom_link_adoption" -eq 1 ] \
                         && [ "$path" = "$ABLETON_LINKD" ]; then
                        echo "kept modified former PR #182 Link binary $path"
                    else
                        echo "kept modified file $path" >&2
                        uninstall_partial=1
                    fi
                fi ;;
            runtime) ;;
        esac
    done < "$manifest"
    return "$rc"
}

remove_legacy_files()
{
    local data_root apps icons mime path source relative
    data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
    apps="$data_root/applications"; icons="$data_root/icons/hicolor"; mime="$data_root/mime/packages"

    legacy_remove_if_owned()
    {
        local target="$1" original="${2:-}"
        [ -e "$target" ] || [ -L "$target" ] || return 0
        if ableton_legacy_owned_path "$target" \
           || { [ -n "$original" ] && [ -f "$original" ] && cmp -s -- "$original" "$target"; }; then
            rm -f -- "$target"
            echo "removed legacy project file $target"
        else
            # Wine and other packages install files under these names, and this
            # branch has no digest to tell one of those from a file of ours that
            # the user changed.  Stop rather than guess.
            echo "kept unrecognised or modified legacy file $target" >&2
            echo "   this project did not install it, or you changed it. Move or delete" >&2
            echo "   it, then run uninstall again to finish." >&2
            uninstall_partial=1
        fi
    }

    for path in \
        "$ABLETON_BIN_HOME/ableton-live" "$ABLETON_BIN_HOME/max9" \
        "$ABLETON_DATA_HOME/$ABLETON_PROTOCOL_DESKTOP_ID" \
        "$ABLETON_DATA_HOME/$ABLETON_AUZ_DESKTOP_ID" \
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

# PipeASIO 1.5 panel projections from the pre-manifest installer are adopted
# only when their exact legacy shape still proves project ownership.  Run this
# before removing the legacy VERSION/runtime evidence used by that check.
remove_legacy_panel_files()
{
    local path
    for path in \
        "$ABLETON_BIN_HOME/pipeasio-settings" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications/pipeasio-settings.desktop" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/pipeasio.svg"; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        if [ -r "$manifest" ] && awk -F '\t' -v p="$path" \
            '$2==p && ($1=="file" || $1=="config" || $1=="symlink") { found=1 } END { exit !found }' \
            "$manifest"; then
            continue
        fi
        if ableton_legacy_owned_path "$path"; then
            rm -f -- "$path"
            echo "removed legacy PipeASIO panel file $path"
        else
            echo "kept independently installed PipeASIO panel file $path"
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

# Drop one type's default.  Group aware for the same reason as the reader: an
# "[Added Associations]" line is the user's own list of applications that may
# open the file, and this project never wrote it.
mime_clear_default()
{
    local file="$1" type="$2" tmp
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
        rm -f -- "$tmp"
        return 1
    fi
    # Copy the original mode so mv is fully atomic and mode-preserving.  The old
    # sed -i also renamed into place; cat > "$file" truncates first, so a kill
    # mid-write leaves the user's list empty.  Surviving a symlinked
    # mimeapps.list is a bonus, not the main reason.
    if ! chmod --reference="$file" "$tmp" || ! mv -f -- "$tmp" "$file"; then
        echo "!! could not restore mimeapps.list from $tmp" >&2
        return 1
    fi
    return 0
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

# Restoration takes two passes: one needs our desktop entries present, the other
# needs them gone.
#
# This is the first.  Delete an entry and xdg-mime reports no default for a line
# that still names it, which is how stale lines survived.  Clear here, and verify
# by re-reading mimeapps.list, because a query still resolves the live entries.
clear_mime_defaults()
{
    local type prior explicit current mimeapps
    [ -r "$restore_mime" ] && command -v xdg-mime >/dev/null 2>&1 || return 0
    mimeapps="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
    echo "== restore MIME defaults =="
    while IFS=$'\t' read -r type prior; do
        [ -n "$type" ] || continue
        if ! current="$(xdg-mime query default "$type" 2>/dev/null)"; then
            echo "!! could not inspect the MIME default for $type" >&2
            mime_partial=1
            continue
        fi
        if ! explicit="$(mime_explicit_default "$mimeapps" "$type")"; then
            echo "!! could not read the MIME defaults list for $type" >&2
            mime_partial=1
            continue
        fi
        mime_id_is_managed "$explicit" || mime_id_is_managed "$current" || continue
        if mime_id_is_managed "$explicit" \
           && ! mime_clear_default "$mimeapps" "$type"; then
            echo "!! could not clear the MIME default for $type" >&2
            mime_partial=1
            continue
        fi
        if ! explicit="$(mime_explicit_default "$mimeapps" "$type")"; then
            echo "!! could not verify the MIME default for $type" >&2
            mime_partial=1
            continue
        fi
        if mime_id_is_managed "$explicit"; then
            echo "!! the managed MIME default for $type is still active" >&2
            mime_partial=1
        fi
    done < "$restore_mime"
    return 0
}

# The second pass runs after the entries are gone and update-desktop-database
# has rebuilt its cache, so a query now reports what the type resolves to
# without this project.  Write the recorded handler back only when the type does
# not already resolve to it.  A default the install found implicit must not come
# back as an explicit line the user never had.
reconcile_mime_defaults()
{
    local type prior current explicit mimeapps
    [ -r "$restore_mime" ] && command -v xdg-mime >/dev/null 2>&1 || return 0
    mimeapps="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
    while IFS=$'\t' read -r type prior; do
        [ -n "$type" ] || continue
        if ! current="$(xdg-mime query default "$type" 2>/dev/null)"; then
            echo "!! could not inspect the MIME default for $type" >&2
            mime_partial=1
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
                echo "$type still opens with $current, which this project did not install"
            fi
            continue
        fi
        [ "$current" != "$prior" ] || continue
        if ! xdg-mime default "$prior" "$type"; then
            echo "!! could not restore the MIME default for $type" >&2
            mime_partial=1
            continue
        fi
        if ! explicit="$(mime_explicit_default "$mimeapps" "$type")" \
           || [ "$explicit" != "$prior" ]; then
            echo "!! could not restore the MIME default for $type" >&2
            mime_partial=1
        fi
    done < "$restore_mime"
    return 0
}

restore_mime="$ABLETON_STATE_HOME/mime-prestate.tsv"
clear_mime_defaults
echo "== remove owned runtime and integration =="
remove_legacy_panel_files
if [ -r "$manifest" ]; then
    if ! remove_owned_manifest_files; then uninstall_partial=1; fi
else
    remove_legacy_files
fi
if [ "$uninstall_partial" -eq 1 ]; then
    echo "!! uninstall could not restore every managed file; runtime and ownership state were retained" >&2
    exit 1
fi
for candidate in "${managed_runtimes[@]}"; do
    if [ -e "$candidate" ]; then
        if ! ableton_runtime_marker_valid "$candidate" "${managed_runtime_names[$candidate]}"; then
            echo "!! kept runtime with an invalid ownership marker: $candidate" >&2
            uninstall_partial=1
        elif ! rm -rf -- "$candidate" || [ -e "$candidate" ] || [ -L "$candidate" ]; then
            echo "!! could not remove managed runtime $candidate" >&2
            uninstall_partial=1
        else
            echo "removed $candidate"
        fi
    fi
    # Dated rollbacks and failed candidates are project-owned siblings.  Do
    # not traverse symlinks and require a Wine binary or marker before deletion.
    runtime_parent="$(dirname "$candidate")"
    runtime_base="$(basename "$candidate")"
    while IFS= read -r -d '' old_runtime; do
        [ -n "$old_runtime" ] || continue
        old_runtime_base="$(basename "$old_runtime")"
        if [[ "$old_runtime_base" != "$runtime_base-rollback-"* \
           && "$old_runtime_base" != "$runtime_base.failed-"* \
           && "$old_runtime_base" != "$runtime_base.transaction-"* ]]; then
            continue
        fi
        [ ! -L "$old_runtime" ] || { echo "kept symlink rollback $old_runtime" >&2; continue; }
        ableton_runtime_marker_valid "$old_runtime" "${managed_runtime_names[$candidate]}" || {
            echo "kept rollback with an invalid ownership marker: $old_runtime" >&2
            continue
        }
        if ! rm -rf -- "$old_runtime" || [ -e "$old_runtime" ] || [ -L "$old_runtime" ]; then
            echo "!! could not remove managed rollback $old_runtime" >&2
            uninstall_partial=1
        else
            echo "removed $old_runtime"
        fi
    done < <(find "$runtime_parent" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
done

update-mime-database "${XDG_DATA_HOME:-$HOME/.local/share}/mime" >/dev/null 2>&1 || true
update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true
reconcile_mime_defaults

if [ "$delete_prefix" -eq 1 ] && [ -e "$safe_prefix" ]; then
    if ! ableton_prefix_marker_valid "$safe_prefix" "$safe_prefix"; then
        echo "!! kept prefix with an invalid ownership marker: $safe_prefix" >&2
        uninstall_partial=1
    elif ! rm -rf -- "$safe_prefix" || [ -e "$safe_prefix" ] || [ -L "$safe_prefix" ]; then
        echo "!! could not remove managed prefix $safe_prefix" >&2
        uninstall_partial=1
    else
        echo "removed $safe_prefix"
    fi
elif [ -e "$safe_prefix" ] || [ -L "$safe_prefix" ]; then
    echo "kept Wine prefix $safe_prefix"
else
    echo "no Wine prefix to remove at $safe_prefix"
fi

if [ "$mime_partial" -eq 1 ]; then uninstall_partial=1; fi
if [ "$uninstall_partial" -eq 1 ]; then
    echo "!! uninstall left modified managed files in place; ownership state was retained" >&2
    exit 1
fi
if ableton_managed_config_valid "$ABLETON_CONFIG_FILE"; then
    rm -f -- "$ABLETON_CONFIG_FILE"
fi
safe_cache="$(ableton_path_is_safe_delete_target "$ABLETON_CACHE_HOME")" || safe_cache=""
[ ! -L "$ABLETON_CACHE_HOME" ] || safe_cache=""
[ -z "$safe_cache" ] || rmdir -- "$safe_cache" 2>/dev/null || true
rm -f -- "$manifest" "$restore_mime"
rmdir -- "$ABLETON_CONFIG_HOME" "$ABLETON_DATA_HOME/lib" "$ABLETON_DATA_HOME" 2>/dev/null || true
safe_state="$(ableton_path_is_safe_delete_target "$ABLETON_STATE_HOME")" || safe_state=""
[ ! -L "$ABLETON_STATE_HOME" ] || safe_state=""
if [ -n "$safe_state" ] \
   && ableton_state_marker_valid "$safe_state"; then
    rm -rf -- "$safe_state"
elif [ -n "$safe_state" ]; then
    rmdir -- "$safe_state/transactions" "$safe_state/logs" "$safe_state/run" "$safe_state" 2>/dev/null || true
fi
echo "OK: uninstall complete"
