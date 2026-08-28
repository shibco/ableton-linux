#!/usr/bin/env bash
# Install independently selectable runtime, desktop-integration, and Link-asset
# components.  Prefix creation is deliberately separate (setup-prefix.sh).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/ui.sh"
export LC_ALL=C.UTF-8
. "$here/lib/config.sh"
. "$here/lib/lifecycle.sh"
. "$here/lib/manifest.sh"
. "$here/lib/pipeasio.sh"

want_runtime=0
want_integration=0
want_link=0
validate_only=0
dry_run=0
assume_yes=0
transaction_arg=""
operation=install

if [ $# -eq 0 ]; then
    want_runtime=1; want_integration=1; want_link=1
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --all) want_runtime=1; want_integration=1; want_link=1 ;;
        --runtime-only|--runtime) want_runtime=1 ;;
        --integration-only|--integration) want_integration=1 ;;
        --link-assets-only|--link-assets) want_link=1 ;;
        --validate) validate_only=1 ;;
        --dry-run) dry_run=1 ;;
        --yes) assume_yes=1 ;;
        --transaction-dir)
            [ $# -ge 2 ] || { echo "!! --transaction-dir needs a directory" >&2; exit 2; }
            transaction_arg="$2"; shift ;;
        --rollback)
            [ $# -ge 2 ] || { echo "!! --rollback needs a transaction directory" >&2; exit 2; }
            operation=rollback; transaction_arg="$2"; shift ;;
        --preflight-rollback)
            [ $# -ge 2 ] || { echo "!! --preflight-rollback needs a transaction directory" >&2; exit 2; }
            operation=preflight-rollback; transaction_arg="$2"; shift ;;
        --preflight-commit)
            [ $# -ge 2 ] || { echo "!! --preflight-commit needs a transaction directory" >&2; exit 2; }
            operation=preflight-commit; transaction_arg="$2"; shift ;;
        --commit)
            [ $# -ge 2 ] || { echo "!! --commit needs a transaction directory" >&2; exit 2; }
            operation=commit; transaction_arg="$2"; shift ;;
        *) echo "!! unknown install.sh option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$validate_only" -eq 1 ] || [ "$dry_run" -eq 1 ]; then
    ABLETON_CONFIG_LAYOUT_ROOTS=none
elif [ "$operation" != install ]; then
    # Explicit transaction records carry their own target, marker, and
    # allowlist checks. Unrelated configured roots must not veto a no-op domain
    # preflight/commit when that transaction has no record for the domain.
    ABLETON_CONFIG_LAYOUT_ROOTS=none
elif [ "$want_runtime" -eq 1 ]; then
    # Runtime promotion itself uses only the runtime root and private/external
    # transaction data. Desktop, settings, and Link roots are checked only when
    # their optional phase actually begins.
    ABLETON_CONFIG_LAYOUT_ROOTS=runtime
else
    # Optional project files are handled one destination at a time below.
    ABLETON_CONFIG_LAYOUT_ROOTS=none
    ABLETON_SIMPLE_PROJECT_FILES=1
fi
export ABLETON_CONFIG_LAYOUT_ROOTS ABLETON_SIMPLE_PROJECT_FILES
ableton_config_init repair
export WINEPREFIX="$ABLETON_WINEPREFIX"
data="$ABLETON_DATA_HOME"
bin="$ABLETON_BIN_HOME"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
mime_root="${XDG_DATA_HOME:-$HOME/.local/share}/mime"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
ABLETON_PROJECT_ASSUME_YES="$assume_yes"
export ABLETON_PROJECT_ASSUME_YES

if [ "$operation" != install ] || { [ "$validate_only" -eq 0 ] && [ "$dry_run" -eq 0 ]; }; then
    ableton_install_lock_acquire
fi

rollback_runtime()
{
    local txn="$1" target backup safe backup_safe expected_backup
    [ -r "$txn/runtime.tsv" ] || return 0
    IFS=$'\t' read -r target backup < "$txn/runtime.tsv"
    [ -n "$target" ] || return 0
    safe="$(ableton_path_is_safe_delete_target "$target")" || {
        echo "!! refusing unsafe runtime rollback target: $target" >&2; return 1; }
    [ "$target" = "$safe" ] && [ "$safe" = "$(ableton_realpath_m "$ABLETON_WINE_ROOT")" ] || {
        echo "!! runtime rollback target does not match this installation: $target" >&2; return 1; }
    if [ "$backup" != absent ]; then
        expected_backup="$safe.transaction-${txn##*/}"
        backup_safe="$(ableton_path_is_safe_delete_target "$backup")" || {
            echo "!! refusing unsafe runtime rollback backup: $backup" >&2; return 1; }
        if ! { [ "$backup" = "$expected_backup" ] && [ "$backup" = "$backup_safe" ] \
               && [ -d "$backup" ] && [ ! -L "$backup" ] \
               && ableton_runtime_marker_valid "$backup" "$ABLETON_RUNTIME_NAME"; }; then
            echo "!! runtime rollback backup is missing, misplaced, or unrecognised: $backup" >&2
            return 1
        fi
    fi
    if [ -e "$safe" ]; then
        [ ! -L "$safe" ] || { echo "!! refusing symlink runtime rollback target: $safe" >&2; return 1; }
        if ! ableton_runtime_marker_valid "$safe" "$ABLETON_RUNTIME_NAME"; then
            echo "!! refusing to remove unmarked runtime during rollback: $safe" >&2
            return 1
        fi
        rm -rf -- "$safe" || return 1
    fi
    if [ "$backup" != absent ]; then
        mv -T -n -- "$backup" "$safe" || return 1
        [ ! -e "$backup" ] && [ ! -L "$backup" ] \
            && [ -d "$safe" ] && [ ! -L "$safe" ] || return 1
    fi
    rm -f -- "$txn/runtime.tsv" || return 1
}

validate_runtime_transaction()
{
    local txn="$1" mode="${2:-rollback}" record="$1/runtime.tsv" target backup extra safe backup_safe expected_backup
    local public_record="$1/runtime-rollback-path" public="" public_parent public_base target_parent target_base
    if [ ! -e "$record" ] && [ ! -L "$record" ]; then return 0; fi
    [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] \
        && ableton_file_has_no_nul "$record" \
        && [ "$(wc -l < "$record")" -eq 1 ] || {
        echo "!! runtime rollback record is unsafe or invalid" >&2; return 1; }
    IFS=$'\t' read -r target backup extra < "$record"
    [ -z "$extra" ] && [ -n "$target" ] && [ -n "$backup" ] || {
        echo "!! runtime rollback record is malformed" >&2; return 1; }
    safe="$(ableton_path_is_safe_delete_target "$target")" || {
        echo "!! refusing unsafe runtime rollback target: $target" >&2; return 1; }
    [ "$target" = "$safe" ] && [ "$safe" = "$(ableton_realpath_m "$ABLETON_WINE_ROOT")" ] || {
        echo "!! runtime rollback target does not match this installation: $target" >&2; return 1; }
    if [ -e "$safe" ] || [ -L "$safe" ]; then
        if ! { [ -d "$safe" ] && [ ! -L "$safe" ] \
               && ableton_runtime_marker_valid "$safe" "$ABLETON_RUNTIME_NAME"; }; then
            echo "!! runtime rollback target is unrecognised: $safe" >&2
            return 1
        fi
    fi
    if [ "$backup" != absent ]; then
        expected_backup="$safe.transaction-${txn##*/}"
        backup_safe="$(ableton_path_is_safe_delete_target "$backup")" || {
            echo "!! refusing unsafe runtime rollback backup: $backup" >&2; return 1; }
        [ "$backup" = "$expected_backup" ] && [ "$backup" = "$backup_safe" ] || {
            echo "!! runtime rollback backup is misplaced: $backup" >&2; return 1; }
        if [ -e "$backup" ] || [ -L "$backup" ]; then
            if ! { [ -d "$backup" ] && [ ! -L "$backup" ] \
                   && ableton_runtime_marker_valid "$backup" "$ABLETON_RUNTIME_NAME"; }; then
                echo "!! runtime rollback backup is unrecognised: $backup" >&2
                return 1
            fi
        elif [ "$mode" != commit ]; then
            echo "!! runtime rollback backup is missing: $backup" >&2
            return 1
        fi

        if [ "$mode" = commit ] && { [ -e "$public_record" ] || [ -L "$public_record" ]; }; then
            [ -f "$public_record" ] && [ ! -L "$public_record" ] && [ -r "$public_record" ] \
                && ableton_file_has_no_nul "$public_record" \
                && [ "$(wc -l < "$public_record")" -eq 1 ] || {
                echo "!! saved runtime rollback record is unsafe" >&2; return 1; }
            public="$(sed -n '1p' "$public_record")"
            public_parent="$(ableton_realpath_m "$(dirname "$public")")" || return 1
            public_base="$(basename "$public")" || return 1
            target_parent="$(ableton_realpath_m "$(dirname "$safe")")" || return 1
            target_base="$(basename "$safe")" || return 1
            [ "$public_parent" = "$target_parent" ] \
                && [[ "$public_base" == "$target_base-rollback-"* ]] || {
                echo "!! saved runtime rollback record has an invalid path" >&2; return 1; }
            if [ -e "$public" ] || [ -L "$public" ]; then
                if ! { [ -d "$public" ] && [ ! -L "$public" ] \
                       && ableton_runtime_marker_valid "$public" "$ABLETON_RUNTIME_NAME"; }; then
                    echo "!! saved runtime rollback is unrecognised" >&2
                    return 1
                fi
            fi
        fi
        if [ "$mode" = commit ] && [ ! -d "$backup" ]; then
            [ -n "$public" ] && [ -d "$public" ] && [ ! -L "$public" ] || {
                echo "!! saved runtime transaction backup is missing" >&2; return 1; }
        fi
    fi
}

preflight_rollback_transaction()
{
    local txn="$1"
    [ -d "$txn" ] && [ ! -L "$txn" ] || {
        echo "!! component transaction directory is missing or unsafe" >&2; return 1; }
    validate_runtime_transaction "$txn" rollback || return 1
    ableton_txn_preflight_rollback_files "$txn"
}

preflight_commit_transaction()
{
    local txn="$1"
    [ -d "$txn" ] && [ ! -L "$txn" ] || return 1
    validate_runtime_transaction "$txn" commit || return 1
    ableton_txn_preflight_commit_files "$txn"
}

rollback_transaction()
{
    local txn="$1" retire_active="${2:-1}" rc=0
    preflight_rollback_transaction "$txn" || return 1
    rollback_runtime "$txn" || rc=1
    ableton_txn_rollback_files "$txn" || rc=1
    update-mime-database "$mime_root" >/dev/null 2>&1 || true
    update-desktop-database "$apps" >/dev/null 2>&1 || true
    if [ "$rc" -eq 0 ] && [ "$retire_active" -eq 1 ]; then
        rm -f -- "$txn/active" || rc=1
    fi
    return "$rc"
}

incomplete_rollback_marker_valid()
{
    local marker="$1"
    [ -f "$marker" ] && [ ! -L "$marker" ] \
        && [ "$(stat -c '%a' -- "$marker" 2>/dev/null || true)" = 600 ] \
        && cmp -s -- "$marker" <(printf 'format=1\n')
}

commit_transaction()
{
    local txn="$1" metadata_pending="${2:-1}" retire_active="${3:-1}"
    local target backup rollback marker marker_tmp=""
    local record="$1/runtime-rollback-path" record_tmp="" recorded=""
    preflight_commit_transaction "$txn" || return 1
    if [ -r "$txn/runtime.tsv" ]; then
        IFS=$'\t' read -r target backup < "$txn/runtime.tsv"
        if [ "$backup" != absent ]; then
            if [ -e "$record" ] || [ -L "$record" ]; then
                [ -f "$record" ] && [ ! -L "$record" ] \
                    && [ "$(wc -l < "$record" 2>/dev/null || true)" -eq 1 ] || {
                    echo "!! saved runtime rollback record is unsafe" >&2
                    return 1
                }
                recorded="$(sed -n '1p' "$record")" || return 1
                if [ "$(ableton_realpath_m "$(dirname "$recorded")")" \
                        = "$(ableton_realpath_m "$(dirname "$target")")" ] \
                   && [[ "$(basename "$recorded")" == "$(basename "$target")-rollback-"* ]]; then
                    rollback="$recorded"
                else
                    echo "!! saved runtime rollback record has an invalid path" >&2
                    return 1
                fi
            else
                rollback="$target-rollback-$stamp"
                if [ -e "$rollback" ] || [ -L "$rollback" ]; then rollback="$rollback-$$"; fi
                [ ! -e "$rollback" ] && [ ! -L "$rollback" ] || {
                    echo "!! cannot choose an unused runtime rollback path" >&2
                    return 1
                }
            fi
            # A public rollback name is selectable by rollback.sh.  Seal the
            # old runtime as incomplete while it still has its private
            # transaction name, then expose it with one same-filesystem rename.
            if [ -e "$backup" ] || [ -L "$backup" ]; then
                [ -d "$backup" ] && [ ! -L "$backup" ] || {
                    echo "!! saved runtime transaction backup is unsafe" >&2
                    return 1
                }
                ableton_runtime_marker_valid "$backup" "$ABLETON_RUNTIME_NAME" || {
                    echo "!! saved runtime transaction backup has an invalid ownership marker" >&2
                    return 1
                }
            elif [ ! -d "$rollback" ] || [ -L "$rollback" ]; then
                echo "!! saved runtime transaction backup is missing" >&2
                return 1
            elif ! ableton_runtime_marker_valid "$rollback" "$ABLETON_RUNTIME_NAME"; then
                echo "!! saved runtime rollback has an invalid ownership marker" >&2
                return 1
            fi
            if [ "$metadata_pending" -ne 0 ] && [ -d "$backup" ]; then
                marker="$backup/.ableton-linux-rollback-incomplete"
                if [ -e "$marker" ] || [ -L "$marker" ]; then
                    incomplete_rollback_marker_valid "$marker" || {
                        echo "!! saved runtime has an invalid rollback marker" >&2
                        return 1
                    }
                else
                    marker_tmp="$(mktemp "$backup/.rollback-incomplete.XXXXXX")" || return 1
                    if ! printf 'format=1\n' > "$marker_tmp" \
                       || ! chmod 600 "$marker_tmp" \
                       || ! incomplete_rollback_marker_valid "$marker_tmp" \
                       || ! mv -T -n -- "$marker_tmp" "$marker" \
                       || [ -e "$marker_tmp" ] || ! incomplete_rollback_marker_valid "$marker"; then
                        rm -f -- "$marker_tmp"
                        echo "!! could not seal the saved runtime rollback as incomplete" >&2
                        return 1
                    fi
                fi
            fi
            if [ ! -e "$record" ] && [ ! -L "$record" ]; then
                record_tmp="$(mktemp "$txn/.runtime-rollback-path.XXXXXX")" || return 1
                if ! printf '%s\n' "$rollback" > "$record_tmp" \
                   || ! chmod 600 "$record_tmp" \
                   || ! mv -T -n -- "$record_tmp" "$record" \
                   || [ -e "$record_tmp" ]; then
                    rm -f -- "$record_tmp"
                    echo "!! could not record the saved runtime rollback" >&2
                    return 1
                fi
            fi
            if [ -d "$backup" ]; then
                component_commit_started=1
                mv -T -n -- "$backup" "$rollback"
                [ ! -e "$backup" ] && [ ! -L "$backup" ] \
                    && [ -d "$rollback" ] && [ ! -L "$rollback" ] || {
                    echo "!! could not version the previous runtime" >&2
                    return 1
                }
            fi
            if [ "$metadata_pending" -ne 0 ]; then
                incomplete_rollback_marker_valid \
                    "$rollback/.ableton-linux-rollback-incomplete" || {
                    echo "!! public saved runtime lacks its incomplete marker" >&2
                    return 1
                }
            fi
        fi
    fi
    component_commit_started=1
    [ "$retire_active" -eq 0 ] || rm -f -- "$txn/active" || return 1
}

case "$operation" in
    preflight-rollback) preflight_rollback_transaction "$transaction_arg"; exit ;;
    preflight-commit) preflight_commit_transaction "$transaction_arg"; exit ;;
    # The public coordinator owns its top-level active marker. Domain helpers
    # may validate and retire their own rollback material, but cannot make an
    # incomplete later-domain recovery look inactive.
    rollback) rollback_transaction "$transaction_arg" 0; exit ;;
    commit) commit_transaction "$transaction_arg" 1 0; exit ;;
esac

[ "$want_runtime$want_integration$want_link" != 000 ] || {
    echo "!! select at least one component" >&2; exit 2; }

runtime_core_only=0
if [ "$want_runtime" -eq 1 ] && [ "$want_integration" -eq 0 ] \
   && [ "$want_link" -eq 0 ]; then
    runtime_core_only=1
fi
if [ -n "$transaction_arg" ] && [ "$want_runtime" -eq 1 ] \
   && { [ "$want_integration" -eq 1 ] || [ "$want_link" -eq 1 ]; }; then
    echo "!! runtime transactions cannot include desktop or Link files" >&2
    exit 2
fi

own_transaction=0
ABLETON_TRANSACTION_DIR=""
if [ "$want_runtime" -eq 1 ]; then
    if [ -n "$transaction_arg" ]; then
        ABLETON_TRANSACTION_DIR="$transaction_arg"
    else
        # Wine is the only component installed by this script that keeps an
        # automatic rollback transaction.
        ABLETON_TRANSACTION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ableton-install-plan.XXXXXX")"
        own_transaction=1
    fi
fi
export ABLETON_TRANSACTION_DIR
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_component_transaction()
{
    local rc=$?
    trap - EXIT
    ui_cleanup "$rc"
    if [ "$rc" -ne 0 ] && [ "$own_transaction" -eq 1 ] \
       && ! rm -rf -- "$ABLETON_TRANSACTION_DIR"; then
        echo "!! Temporary installer files could not be removed: $ABLETON_TRANSACTION_DIR" >&2
    fi
    exit "$rc"
}
trap cleanup_unstarted_component_transaction EXIT
[ "$want_runtime" -eq 0 ] || ableton_txn_init
stage=""
component_commit_started=0
runtime_core_committed=0
optional_files_ready=0
cleanup_preview_scratch()
{
    local stage_name=""
    if [ -n "$stage" ]; then
        stage_name="$(basename "$stage" 2>/dev/null || true)"
        case "$stage_name" in
            ableton-runtime-validate.*)
                if [ -d "$stage" ] && [ ! -L "$stage" ]; then
                    rm -rf -- "$stage" 2>/dev/null || true
                fi ;;
        esac
        if [ -e "$stage" ] || [ -L "$stage" ]; then
            echo "!! Checks finished, but temporary files remain at $stage" >&2 || true
        fi
        stage=""
    fi
    if [ "$own_transaction" -eq 1 ]; then
        rm -f -- "$ABLETON_TRANSACTION_DIR/active" 2>/dev/null || true
        rm -rf -- "$ABLETON_TRANSACTION_DIR" 2>/dev/null || true
        if [ -e "$ABLETON_TRANSACTION_DIR" ] || [ -L "$ABLETON_TRANSACTION_DIR" ]; then
            echo "!! Checks finished, but temporary files remain at $ABLETON_TRANSACTION_DIR" >&2 \
                || true
        fi
        own_transaction=0
    fi
    return 0
}
cleanup()
{
    local rc=$? restore_error="" restoration_complete=yes
    trap - EXIT
    # Recovery must not depend on whether a diagnostic stream is writable.
    # Every mutation/recovery status below is handled explicitly.
    set +e
    ui_cleanup "$rc"
    if [ "$validate_only" -eq 1 ] || [ "$dry_run" -eq 1 ]; then
        # Preview work never mutates installation state. Preserve the real
        # validation/planning result and dispose only its private scratch;
        # there is nothing to roll back or record as failed recovery.
        cleanup_preview_scratch
        exit "$rc"
    fi
    if [ -n "$stage" ] && ! rm -rf -- "$stage"; then
        restore_error="temporary runtime cleanup failed"
        rc=1
    fi
    if [ "$rc" -ne 0 ] \
       && { [ "$runtime_core_committed" -eq 1 ] || [ "$optional_files_ready" -eq 1 ]; }; then
        if [ "$runtime_core_committed" -eq 1 ]; then
            echo "!! Wine is ready. Run the installer again to retry shortcuts or Ableton Link files." >&2 || true
            [ -n "$transaction_arg" ] || ui_status i_runtime_ready
        else
            echo "!! Ableton is ready. Run the installer again to retry shortcuts or Ableton Link files." >&2 || true
        fi
        rc=0
    elif [ "$rc" -ne 0 ] && [ "$component_commit_started" -eq 1 ] \
         && [ -n "$ABLETON_TRANSACTION_DIR" ]; then
        printf 'component=install.sh\nstatus=committed-cleanup-incomplete\nexit=%s\ncleanup_error=%s\n' \
            "$rc" "$restore_error" > "$ABLETON_TRANSACTION_DIR/COMMITTED_CLEANUP_FAILURE" 2>/dev/null || true
        echo "!! Installation finished, but temporary recovery files could not be removed." >&2
        echo "!! Details were saved at $ABLETON_TRANSACTION_DIR/COMMITTED_CLEANUP_FAILURE." >&2
    elif [ "$rc" -ne 0 ] && [ -n "$ABLETON_TRANSACTION_DIR" ] \
         && [ -e "$ABLETON_TRANSACTION_DIR/active" ]; then
        echo "!! Installation did not finish. Restoring the files from before this attempt." >&2
        if ! rollback_transaction "$ABLETON_TRANSACTION_DIR"; then
            restore_error="${restore_error}${restore_error:+; }earlier files could not be fully restored"
        fi
        [ -z "$restore_error" ] || restoration_complete=no
        if [ "$own_transaction" -eq 1 ]; then
            printf 'component=install.sh\nexit=%s\nrestoration_complete=%s\nrestoration_error=%s\n' \
                "$rc" "$restoration_complete" "$restore_error" \
                > "$ABLETON_TRANSACTION_DIR/FAILURE" || true
            if [ "$restoration_complete" = yes ]; then
                echo "!! Earlier files were restored. Details: $ABLETON_TRANSACTION_DIR/FAILURE" >&2
            else
                echo "!! Automatic restoration did not finish: $restore_error" >&2
                echo "!! Keep $ABLETON_TRANSACTION_DIR/FAILURE for troubleshooting before retrying." >&2
            fi
        fi
    elif [ "$rc" -ne 0 ] && [ -n "$restore_error" ]; then
        echo "!! Temporary installer cleanup did not finish: $restore_error" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tarball=""
candidate=""
runtime_info=""
bundle_probe=""
linkd_source=""
unit_source=""

validate_runtime_payload()
{
    local version version_lines checksum expected_sha checksum_name checksum_extra actual_sha
    [ -r "$root/VERSION" ] || { echo "!! installer kit has no VERSION" >&2; return 1; }
    version_lines="$(wc -l < "$root/VERSION")" || return 1
    version="$(sed -n '1p' "$root/VERSION")" || return 1
    [ "$version_lines" -eq 1 ] && [[ "$version" =~ ^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] || {
        echo "!! installer kit has an invalid VERSION" >&2; return 1; }
    tarball="$root/dist/$ABLETON_RUNTIME_NAME-$version.tar.zst"
    [ -f "$tarball" ] || { echo "!! exact runtime $ABLETON_RUNTIME_NAME-$version.tar.zst is missing" >&2; return 1; }
    checksum="$tarball.sha256"
    [ -s "$checksum" ] || { echo "!! runtime checksum is missing" >&2; return 1; }
    [ "$(wc -l < "$checksum")" -eq 1 ] || { echo "!! runtime checksum record is malformed" >&2; return 1; }
    read -r expected_sha checksum_name checksum_extra < "$checksum"
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] && [ -z "$checksum_extra" ] || {
        echo "!! runtime checksum record is malformed" >&2; return 1; }
    checksum_name="${checksum_name#\*}"
    [ "$checksum_name" = "$(basename "$tarball")" ] || {
        echo "!! runtime checksum names a different payload" >&2; return 1; }
    actual_sha="$(sha256sum -- "$tarball" | awk '{print $1}')" || return 1
    [ "$actual_sha" = "$expected_sha" ] || { echo "!! runtime checksum does not match" >&2; return 1; }
    runtime_info="$root/BUILD-INFO-$version.txt"
    [ -s "$runtime_info" ] || runtime_info="$root/dist/BUILD-INFO-$version.txt"
    [ -s "$runtime_info" ] || { echo "!! exact BUILD-INFO-$version.txt is missing" >&2; return 1; }
    bundle_probe="$root/bin/pipewire-version-probe"
    [ -x "$bundle_probe" ] || bundle_probe="$root/dist/pipewire-version-probe"
    [ -x "$bundle_probe" ] || { echo "!! installer kit is missing its PipeWire compatibility check" >&2; return 1; }
    ui_item_begin i_check_wine_package "$(basename "$tarball")"
    ui_status i_wine_package_valid "$(basename "$tarball")"
    ui_item_end ok
    local parent
    parent="$(dirname "$ABLETON_WINE_ROOT")" || return 1
    if [ "$validate_only" -eq 1 ] || [ "$dry_run" -eq 1 ]; then
        stage="$(mktemp -d "${TMPDIR:-/tmp}/ableton-runtime-validate.XXXXXX")" || return 1
    else
        mkdir -p -- "$parent" || return 1
        stage="$(mktemp -d "$parent/.ableton-runtime-stage.XXXXXX")" || return 1
    fi
    local extract_timeout
    extract_timeout="$(ableton_timeout_value "${ABLETON_RUNTIME_EXTRACT_TIMEOUT:-1800}" ABLETON_RUNTIME_EXTRACT_TIMEOUT 60 7200)" \
        || return 1
    ui_run i_unpack_runtime -- \
        ableton_run_bounded "$extract_timeout" tar -C "$stage" -I zstd -xf "$tarball" \
        || return 1
    candidate="$stage/$ABLETON_RUNTIME_NAME"
    local required
    for required in \
        bin/wine bin/wineserver \
        lib/wine/x86_64-windows/libusb-1.0.dll \
        lib/wine/x86_64-unix/libusb-1.0.so \
        lib/wine/x86_64-unix/comdlg32.so \
        lib/wine/x86_64-unix/winealsa.so \
        lib/wine/x86_64-unix/winegstreamer.so \
        bin/pipewire-version-probe \
        ABLETON-WINE-BUILD-INFO.txt \
        lib/wine/x86_64-windows/pipeasio64.dll \
        lib/wine/x86_64-windows/pipeasio.dll \
        lib/wine/x86_64-unix/pipeasio64.dll.so \
        lib/wine/x86_64-unix/pipeasio.dll.so; do
        [ -s "$candidate/$required" ] || { echo "!! runtime payload is missing $required" >&2; return 1; }
    done
    [ ! -e "$candidate/lib/wine/i386-windows/libusb-1.0.dll" ] || {
        echo "!! runtime unexpectedly contains a 32-bit Push bridge" >&2; return 1; }
    if command -v readelf >/dev/null 2>&1 && command -v strings >/dev/null 2>&1; then
        readelf -d "$candidate/lib/wine/x86_64-unix/libusb-1.0.so" \
            | grep -F 'Shared library: [libusb-1.0.so.0]' >/dev/null || {
            echo "!! runtime Push bridge dependency validation failed" >&2; return 1; }
        strings "$candidate/lib/wine/x86_64-unix/comdlg32.so" \
            | grep -F 'org.freedesktop.portal.FileChooser' >/dev/null || {
            echo "!! runtime portal integration validation failed" >&2; return 1; }
        readelf -d "$candidate/lib/wine/x86_64-unix/pipeasio64.dll.so" \
            | grep -F 'Shared library: [libpipewire-0.3.so.0]' >/dev/null || {
            echo "!! runtime PipeASIO dependency validation failed" >&2; return 1; }
        readelf -d "$candidate/lib/wine/x86_64-unix/winegstreamer.so" \
            | grep -F 'Shared library: [libgstreamer-1.0.so.0]' >/dev/null || {
            echo "!! runtime GStreamer dependency validation failed" >&2; return 1; }
    fi
    ableton_pipeasio_validate_runtime "$candidate" "$runtime_info" "$version" || return 1
    cmp -s -- "$bundle_probe" "$candidate/bin/pipewire-version-probe" || {
        echo "!! installer and runtime compatibility checks do not match" >&2; return 1; }
    ableton_run_bounded 30 "$candidate/bin/wine" --version >/dev/null || {
        echo "!! staged runtime Wine executable did not pass its bounded version check" >&2
        return 1
    }
    ui_status i_runtime_checks_passed
}

if [ "$want_runtime" -eq 1 ]; then
    validate_runtime_payload
fi
if [ "$want_runtime" -eq 1 ] && [ "$want_integration" -eq 0 ] \
   && [ "$want_link" -eq 0 ]; then
    runtime_core_only=1
fi

if [ "$validate_only" -eq 1 ]; then
    # Validation has already succeeded. Reporting and disposal of private
    # scratch files cannot turn that result into a failure.
    set +e
    ui_status i_validate_ok
    cleanup_preview_scratch
    trap - EXIT
    ui_cleanup 0
    exit 0
fi

if [ "$dry_run" -eq 1 ]; then
    # Planning mutates no installation state. Its report and scratch cleanup
    # are presentation/housekeeping only.
    set +e
    ui_status i_plan_heading
    [ "$want_runtime" -eq 0 ] || {
        ui_status i_plan_runtime "$ABLETON_WINE_ROOT"
        ui_status i_plan_panel_shortcuts
    }
    if [ "$want_integration" -eq 1 ]; then
        ui_status i_plan_integration
        ui_status i_plan_tools
        if [ -f "$ABLETON_WINEPREFIX/drive_c/Program Files/Cycling '74/Max 9/Max.exe" ]; then
            ui_status i_plan_max9
        fi
    fi
    if [ "$want_link" -eq 1 ]; then
        if [ "$ABLETON_LINKD" = "$ABLETON_DATA_HOME/ableton-linkd" ]; then
            ui_status i_plan_link
        else
            ui_status i_plan_link_external "$ABLETON_LINKD"
        fi
    fi
    [ "$want_integration" -eq 0 ] && [ "$want_link" -eq 0 ] \
        || ui_status i_plan_backups "$ABLETON_STATE_HOME"
    cleanup_preview_scratch
    trap - EXIT
    ui_cleanup 0
    exit 0
fi

# Direct component use receives the same gate as the wrapper. Validation and
# dry-run remain usable without a running daemon; Link/integration-only work
# carries no PipeASIO driver replacement and is not gated.
if [ "$want_runtime" -eq 1 ]; then
    ableton_pipewire_preflight "$candidate/bin/pipewire-version-probe" "installing PipeASIO"
fi

runtime_pids_all()
{
    local proc pid
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        ableton_pid_uses_runtime "$pid" && printf '%s\n' "$pid"
    done
    return 0
}

stop_runtime_clients()
{
    local all scoped foreign pid
    all="$(runtime_pids_all)"
    [ -n "$all" ] || return 0
    scoped="$(ableton_prefix_pids)"
    foreign=""
    for pid in $all; do
        case " $scoped " in *" $pid "*) ;; *) foreign="$foreign $pid" ;; esac
    done
    if [ -n "$foreign" ]; then
        echo "!! runtime is used by another Wine prefix (PIDs:$foreign); close it before updating" >&2
        return 1
    fi
    echo "!! the selected prefix has running Wine clients: $(tr ' ' '\n' <<< "$scoped" | sed '/^$/d' | paste -sd, -)" >&2
    if [ "$assume_yes" -ne 1 ]; then
        if [ -t 0 ]; then
            ui_question i_q_stop_clients l q_stop_prefix_end q_stop_prefix_leave
            [ "$UI_ANSWER" = e ] || return 1
        else
            echo "!! refusing without --yes in a noninteractive session" >&2
            return 1
        fi
    fi
    ableton_stop_prefix || { echo "!! could not stop all scoped Wine clients" >&2; return 1; }
}

promote_runtime()
{
    local target="$ABLETON_WINE_ROOT" parent backup safe marker marker_tmp record
    parent="$(dirname "$target")" || return 1
    mkdir -p -- "$parent" || return 1
    safe="$(ableton_path_is_safe_delete_target "$target")" || { echo "!! unsafe runtime target: $target" >&2; return 1; }
    backup=absent
    if [ -e "$safe" ]; then
        [ ! -L "$safe" ] || { echo "!! refusing to replace symlink runtime $safe" >&2; return 1; }
        if [ "$runtime_core_only" -eq 1 ]; then
            # The directory-level runtime record is the complete rollback unit.
            # Marking a recognised legacy runtime must not add a host-file row
            # to that core record.
            ABLETON_TRANSACTION_DIR="" \
                ableton_adopt_runtime_marker "$safe" "$ABLETON_RUNTIME_NAME" || {
                echo "!! refusing to replace an unrecognised runtime directory: $safe" >&2
                return 1
            }
        else
            ableton_adopt_runtime_marker "$safe" "$ABLETON_RUNTIME_NAME" || {
                echo "!! refusing to replace an unrecognised runtime directory: $safe" >&2
                return 1
            }
        fi
        backup="$safe.transaction-${ABLETON_TRANSACTION_DIR##*/}"
        [ ! -e "$backup" ] && [ ! -L "$backup" ] \
            || { echo "!! transaction backup already exists: $backup" >&2; return 1; }
    fi
    stop_runtime_clients || return 1
    # Mark and verify the staged tree before it can become the live runtime.
    marker="$candidate/.ableton-linux-runtime"
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || {
        echo "!! staged runtime already has an ownership marker" >&2; return 1; }
    marker_tmp="$(mktemp "$candidate/.runtime-marker.XXXXXX")" || return 1
    if ! printf 'format=1\nname=%s\n' "$ABLETON_RUNTIME_NAME" > "$marker_tmp" \
       || ! chmod 600 "$marker_tmp" \
       || ! mv -T -n -- "$marker_tmp" "$marker" \
       || [ -e "$marker_tmp" ] || [ ! -f "$marker" ] || [ -L "$marker" ] \
       || ! ableton_runtime_marker_valid "$candidate" "$ABLETON_RUNTIME_NAME"; then
        rm -f -- "$marker_tmp"
        echo "!! could not mark the staged runtime safely" >&2
        return 1
    fi
    record="$ABLETON_TRANSACTION_DIR/runtime.tsv"
    ableton_promote_directory "$candidate" "$safe" "$backup" "$record" || return 1
    ableton_runtime_marker_valid "$safe" "$ABLETON_RUNTIME_NAME" || {
        echo "!! promoted runtime lost its ownership marker" >&2; return 1; }
    ABLETON_RUNTIME_INSTALLED=1
    export ABLETON_RUNTIME_INSTALLED
    ableton_run_bounded 30 "$safe/bin/wine" --version >/dev/null || return 1
}

# A direct runtime call owns no larger prefix/Live transaction. Once the live
# tree has been promoted and revalidated, retire its private rollback journal
# before touching generated desktop or Link files. Failure to name the saved
# old runtime or remove private scratch state is advisory from this boundary;
# neither may restore or invalidate the new Wine tree.
finish_direct_runtime_transaction()
{
    local txn="$ABLETON_TRANSACTION_DIR" cleanup_failed=0
    runtime_core_committed=1
    if ! commit_transaction "$txn" 0 1 >/dev/null 2>&1; then
        echo "!! Wine is ready, but the installer may not be able to restore the previous Wine version automatically. Temporary recovery files may remain." >&2 \
            || true
        cleanup_failed=1
    fi
    if { [ -e "$txn/active" ] || [ -L "$txn/active" ]; } \
       && ! rm -f -- "$txn/active"; then
        cleanup_failed=1
    fi
    if ! rm -rf -- "$txn" || [ -e "$txn" ] || [ -L "$txn" ]; then
        cleanup_failed=1
    fi
    if [ "$cleanup_failed" -ne 0 ] \
       && { [ -e "$txn" ] || [ -L "$txn" ]; }; then
        echo "!! Wine is ready, but temporary installer data remains at $txn" >&2 \
            || true
    fi
    ABLETON_TRANSACTION_DIR=""
    export ABLETON_TRANSACTION_DIR
    own_transaction=0
}

sed_escape()
{
    printf '%s' "$1" | sed 's/[\\&#]/\\&/g'
}

render_link_unit()
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

install_integration()
{
    local tool source target tmp newest="" exe live_name="Ableton Live" live_icon=live-suite live_wmclass="" edition d i
    local probe_source="" ntsync_probe_source="" mime_stage="" mime_failures_before=0
    local mimeapps_file="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
    local mime_setup_ok=1
    local failures_before="$ABLETON_OPTIONAL_FILE_FAILURES"
    local max_unix="$ABLETON_WINEPREFIX/drive_c/Program Files/Cycling '74/Max 9/Max.exe"
    local -a handler_ids=("$ABLETON_PROTOCOL_DESKTOP_ID" "$ABLETON_AUZ_DESKTOP_ID")
    local -a handler_templates=(ableton-linux-protocol ableton-linux-auz)
    local -a app_icons=(live-beta live-intro live-lite live-standard live-suite)
    local -a mimetype_icons=(
        application-x-ableton-live-clip
        application-x-ableton-live-device-group
        application-x-ableton-live-device-preset
        application-x-ableton-live-generic
        application-x-ableton-live-max-device
        application-x-ableton-live-meta-sound
        application-x-ableton-live-pack
        application-x-ableton-live-sample-analysis
        application-x-ableton-live-set
    )
    ui_item_begin i_setup_launchers
    for tool in config.sh lifecycle.sh live-options.sh manifest.sh pipeasio.sh preferences.sh ui.sh; do
        ableton_install_project_file 644 "$here/lib/$tool" "$data/lib/$tool"
    done
    ableton_install_project_file 755 "$here/ableton-live" "$bin/ableton-live"
    for tool in detect-scale.sh detect-theme.sh shortcut-hold.sh; do
        ableton_install_project_file 644 "$here/$tool" "$data/$tool"
    done
    for tool in setup-realtime.sh audio-report.sh check-ntsync.sh rollback.sh; do
        ableton_install_project_file 755 "$here/$tool" "$data/$tool"
    done
    for source in "$here/ntsyncprobe.exe" \
                  "$root/beta/tester-kit/probes/windows/ntsyncprobe.exe"; do
        [ -f "$source" ] || continue
        ntsync_probe_source="$source"
        break
    done
    if [ -z "$ntsync_probe_source" ]; then
        echo "!! installer kit is missing its NTSync semantics probe" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    else
        ableton_install_project_file 644 "$ntsync_probe_source" "$data/ntsyncprobe.exe"
    fi
    for source in "$ABLETON_WINE_ROOT/bin/pipewire-version-probe" \
                  "$root/bin/pipewire-version-probe" "$root/dist/pipewire-version-probe"; do
        [ -x "$source" ] || continue
        probe_source="$source"
        break
    done
    if [ -z "$probe_source" ]; then
        echo "!! installer kit is missing its PipeWire compatibility check" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    else
        ableton_install_project_file 755 "$probe_source" "$data/pipewire-version-probe"
    fi
    for tool in setsyscolors.exe learnheal.exe; do
        for source in "$here/$tool" "$root/tools/$tool"; do
            [ -f "$source" ] || continue
            ableton_install_project_file 644 "$source" "$data/$tool"
            break
        done
    done

    for exe in "$ABLETON_WINEPREFIX"/drive_c/ProgramData/Ableton/Live*/Program/Ableton\ Live*.exe; do
        [ -e "$exe" ] || continue
        [ -z "$newest" ] || [ "$exe" -nt "$newest" ] || continue
        newest="$exe"
    done
    if [ -n "$newest" ]; then
        live_name="$(basename "$newest" .exe)"
        live_wmclass="$(basename "$newest" | tr '[:upper:]' '[:lower:]')"
        edition="$(printf '%s' "$live_name" | awk '{print tolower($NF)}')"
        [ ! -f "$root/desktop/icons/scalable/apps/live-$edition.svg" ] || live_icon="live-$edition"
    fi
    tmp=""
    if tmp="$(mktemp)" \
       && sed -e "s#@HOME@#$(sed_escape "$HOME")#g" \
            -e "s#@BIN@#$(sed_escape "$bin")#g" \
            -e "s#@PREFIX@#$(sed_escape "$ABLETON_WINEPREFIX")#g" \
            -e "s#@NAME@#$(sed_escape "$live_name")#g" \
            -e "s#@ICON@#$(sed_escape "$live_icon")#g" \
            -e "s#@WMCLASS@#$(sed_escape "$live_wmclass")#g" \
            "$root/desktop/ableton-live.desktop.in" > "$tmp" \
       && { [ -n "$live_wmclass" ] || sed -i '/^StartupWMClass=/d' "$tmp"; }; then
        ableton_install_project_file 644 "$tmp" "$apps/ableton-live.desktop"
    else
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    fi
    [ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true

    for ((i=0; i<${#handler_ids[@]}; i++)); do
        d="${handler_ids[i]}"
        tmp=""
        if tmp="$(mktemp)" \
           && sed -e "s#@HOME@#$(sed_escape "$HOME")#g" \
                -e "s#@BIN@#$(sed_escape "$bin")#g" \
                "$root/desktop/${handler_templates[i]}.desktop.in" > "$tmp"; then
            ableton_install_project_file 644 "$tmp" "$data/$d"
            ableton_install_project_file 644 "$tmp" "$apps/$d"
        else
            ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        fi
        [ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
    done

    for d in "${app_icons[@]}"; do
        ableton_install_project_file 644 \
            "$root/desktop/icons/scalable/apps/$d.svg" "$icons/scalable/apps/$d.svg"
    done
    for d in "${mimetype_icons[@]}"; do
        ableton_install_project_file 644 \
            "$root/desktop/icons/scalable/mimetypes/$d.svg" "$icons/scalable/mimetypes/$d.svg"
    done
    ableton_install_project_file 644 \
        "$root/desktop/icons/symbolic/apps/live-symbolic.svg" \
        "$icons/symbolic/apps/live-symbolic.svg"
    ableton_install_project_file 644 "$root/desktop/x-wine-extension-auz.xml" "$mime_root/packages/x-wine-extension-auz.xml"
    ableton_install_project_file 644 "$root/desktop/icons/application-ableton-live.xml" "$mime_root/packages/application-ableton-live.xml"

    if [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 1 ]; then
        :
    elif command -v xdg-mime >/dev/null 2>&1; then
        mime_stage="$(mktemp -d "${TMPDIR:-/tmp}/ableton-mimeapps.XXXXXX")" || true
        [ -n "$mime_stage" ] || mime_setup_ok=0
        if [ -n "$mime_stage" ] && [ -f "$mimeapps_file" ] \
           && ! cp -- "$mimeapps_file" "$mime_stage/mimeapps.list"; then
            rm -rf -- "$mime_stage" 2>/dev/null || true
            echo "!! copy failed: $mimeapps_file -> $mime_stage/mimeapps.list" >&2 || true
            ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
            mime_stage=""
            mime_setup_ok=0
        fi
        if [ -n "$mime_stage" ] \
           && { ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                "$ABLETON_PROTOCOL_DESKTOP_ID" x-scheme-handler/ableton \
                || ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                "$ABLETON_AUZ_DESKTOP_ID" application/x-wine-extension-auz \
                || ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                ableton-live.desktop application/x-ableton-live-set \
                    application/x-ableton-live-clip application/x-ableton-live-pack; }; then
            rm -rf -- "$mime_stage" 2>/dev/null || true
            mime_stage=""
            mime_setup_ok=0
        fi
        if [ -n "$mime_stage" ] && [ -f "$max_unix" ] \
           && { ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                    max9.desktop application/x-ableton-live-max-device \
                || ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                    wine-protocol-c74max.desktop x-scheme-handler/c74max; }; then
            rm -rf -- "$mime_stage" 2>/dev/null || true
            mime_stage=""
            mime_setup_ok=0
        fi
        if [ -n "$mime_stage" ] && [ -f "$mime_stage/mimeapps.list" ]; then
            mime_failures_before="$ABLETON_OPTIONAL_FILE_FAILURES"
            ableton_install_project_file 644 "$mime_stage/mimeapps.list" "$mimeapps_file"
            [ "$ABLETON_OPTIONAL_FILE_FAILURES" -eq "$mime_failures_before" ] \
                || mime_setup_ok=0
        fi
        [ -z "$mime_stage" ] || rm -rf -- "$mime_stage" 2>/dev/null || true
    else
        mime_setup_ok=0
    fi
    if [ "$mime_setup_ok" -ne 1 ] && [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ]; then
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        echo "!! Could not set Ableton as the default app for Live files. Ableton itself can still be used normally." >&2 \
            || true
    fi

    if [ -f "$max_unix" ]; then
        ableton_install_project_file 755 "$here/max9" "$bin/max9"
        for d in max9 wine-protocol-c74max; do
            tmp=""
            if tmp="$(mktemp)" \
               && sed -e "s#@HOME@#$(sed_escape "$HOME")#g" \
                    -e "s#@BIN@#$(sed_escape "$bin")#g" \
                    -e "s#@PREFIX@#$(sed_escape "$ABLETON_WINEPREFIX")#g" \
                    "$root/desktop/$d.desktop.in" > "$tmp"; then
                target="$apps/$d.desktop"
                ableton_install_project_file 644 "$tmp" "$target"
            else
                ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
            fi
            [ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
        done
    fi

    ui_item_end ok
    ui_item_begin i_refresh_desktop_menus
    if command -v update-mime-database >/dev/null 2>&1; then
        update-mime-database "$mime_root" >/dev/null 2>&1 || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps" >/dev/null 2>&1 || true
    fi
    ui_item_end ok

    if [ "$ABLETON_OPTIONAL_FILE_FAILURES" -gt "$failures_before" ]; then
        echo "!! Some shortcuts or support files could not be updated. Run the installer again to retry them." >&2 \
            || true
    fi
    return 0
}

install_link_assets()
{
    [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] || return 0
    ui_item_begin i_install_link_files
    local tool source tmp="" failures_before="$ABLETON_OPTIONAL_FILE_FAILURES"
    local managed_linkd="$ABLETON_DATA_HOME/ableton-linkd"
    local installed_unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ableton-linkd.service"
    for source in "$here/../bin/ableton-linkd" "$root/dist/ableton-linkd"; do
        [ -f "$source" ] || continue
        linkd_source="$source"
        break
    done
    unit_source="$here/ableton-linkd.service"
    [ -f "$unit_source" ] || unit_source="$root/scripts/ableton-linkd.service"
    # A Link-only run needs these common support files. A combined integration
    # run already handled the same destinations once.
    if [ "$want_integration" -eq 0 ]; then
        for tool in config.sh lifecycle.sh manifest.sh preferences.sh ui.sh; do
            ableton_install_project_file 644 "$here/lib/$tool" "$data/lib/$tool"
        done
    fi
    # A configured external Link daemon may be executed by the controller, but
    # it is never installed, claimed, restored, or removed by this project.
    if [ "$ABLETON_LINKD" = "$managed_linkd" ]; then
        if [ -n "$linkd_source" ]; then
            ableton_install_project_file 755 "$linkd_source" "$managed_linkd"
        else
            ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        fi
    else
        if [ ! -x "$ABLETON_LINKD" ]; then
            echo "!! The configured Ableton Link helper cannot be run: $ABLETON_LINKD" >&2 \
                || true
            ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        else
            ui_status i_link_helper_external "$ABLETON_LINKD"
        fi
    fi
    ableton_install_project_file 755 "$here/ableton-linkctl" "$data/ableton-linkctl"
    ableton_install_project_file 755 "$here/setup-link.sh" "$data/setup-link.sh"
    if [ -n "$unit_source" ] && [ -f "$unit_source" ]; then
        ableton_install_project_file 644 "$unit_source" "$data/ableton-linkd.service"
    else
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    fi
    if [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] \
       && tmp="$(mktemp "${TMPDIR:-/tmp}/ableton-link-service.XXXXXX")" \
       && render_link_unit > "$tmp"; then
        ableton_install_project_file 644 "$tmp" "$installed_unit"
    elif [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ]; then
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        echo "!! copy failed: generated Ableton Link service -> $installed_unit" >&2 || true
    fi
    [ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
    if [ "$ABLETON_OPTIONAL_FILE_FAILURES" -gt "$failures_before" ]; then
        echo "!! Some Ableton Link files could not be updated. Run the installer again to retry them." >&2 \
            || true
    fi
    ui_item_end ok
    return 0
}

if [ "$want_runtime" -eq 1 ]; then
    promote_runtime
    ableton_pipeasio_validate_runtime "$ABLETON_WINE_ROOT"
    # Promotion and final core validation are the runtime boundary in every
    # component combination. A direct call closes its private transaction now;
    # a coordinator-owned transaction stays open for the prefix/Live parent.
    if [ "$own_transaction" -eq 1 ]; then
        finish_direct_runtime_transaction
    fi
fi
if [ "$want_integration" -eq 1 ]; then
    install_integration
    ableton_pipeasio_optional_tools_advice
fi
if [ "$want_link" -eq 1 ]; then
    install_link_assets
fi

if [ "$want_runtime" -eq 0 ]; then
    # Every selected generated-file phase returned successfully. From here on,
    # auxiliary records and cache refreshes may report a warning but cannot make
    # working launchers or Link files disappear again.
    optional_files_ready=1
fi

# Runtime updates use the selected runtime's panel record. Integration-only
# installs use the current runtime's compatible panel record when available.
postcommit_runtime_panel=0
if [ "$want_runtime" -eq 1 ]; then
    if [ "$want_integration" -eq 1 ]; then
        if ! ableton_pipeasio_sync_panel "$ABLETON_WINE_ROOT" install; then
            ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
            echo "!! Ableton was installed, but the PipeASIO settings shortcut could not be updated." >&2 \
                || true
        fi
    elif [ "$runtime_core_only" -eq 1 ]; then
        # A parent-owned core phase leaves all desktop work to the later repair
        # phase. A direct runtime update performs the same repair only after the
        # runtime has committed, so shortcut failures cannot undo valid Wine files.
        [ -n "$transaction_arg" ] || postcommit_runtime_panel=1
    else
        if ! ableton_pipeasio_sync_panel "$ABLETON_WINE_ROOT" reconcile; then
            ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
            echo "!! The runtime was installed, but the PipeASIO settings shortcut could not be updated." >&2 \
                || true
        fi
    fi
elif [ "$want_integration" -eq 1 ]; then
    if grep -qxF 'pipeasio-panel: built' "$ABLETON_WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null \
       || grep -qxF 'pipeasio-panel: skipped' "$ABLETON_WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null; then
        if ! ableton_pipeasio_sync_panel "$ABLETON_WINE_ROOT" install; then
            ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
            echo "!! Ableton was installed, but the PipeASIO settings shortcut could not be updated." >&2 \
                || true
        fi
    else
        ui_status i_panel_files_available
    fi
fi

if [ "$want_integration" -eq 1 ] || [ "$want_link" -eq 1 ]; then
    version_tmp=""
    if mkdir -p -- "$data" \
       && version_tmp="$(mktemp "$data/.VERSION.XXXXXX")" \
       && printf '%s\n' "$(cat "$root/VERSION" 2>/dev/null || echo unknown)" > "$version_tmp"; then
        ableton_install_project_file 644 "$version_tmp" "$data/VERSION"
    else
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        echo "!! Ableton was installed, but its support files could not be fully updated." >&2 \
            || true
    fi
    [ -z "$version_tmp" ] || rm -f -- "$version_tmp" 2>/dev/null || true
fi

if [ -n "$stage" ]; then
    # The validated runtime has already moved out of this private scratch tree.
    # Failure to remove that scratch directory does not invalidate Wine.
    if ! rm -rf -- "$stage" || [ -e "$stage" ] || [ -L "$stage" ]; then
        echo "!! Wine was installed, but temporary files remain at $stage" >&2 || true
    fi
    stage=""
fi
if [ "$postcommit_runtime_panel" -eq 1 ]; then
    # The runtime is committed and its private records are gone. Panel repair is
    # deliberately warning-only from this point forward.
    unset ABLETON_TRANSACTION_DIR
    panel_repair_status=0
    set +e
    (
        set -e
        ableton_pipeasio_sync_panel "$ABLETON_WINE_ROOT" reconcile
    )
    panel_repair_status=$?
    set -e
    case "$panel_repair_status" in
        0) ;;
        *)
            echo "!! Wine was installed, but the PipeASIO settings shortcut could not be updated." >&2 \
                || true ;;
    esac
fi
if [ "$ABLETON_OPTIONAL_FILES_BACKED_UP" -gt 0 ]; then
    ui_status i_backed_up_files "$ABLETON_OPTIONAL_FILES_BACKED_UP"
fi
if [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 1 ]; then
    trap - EXIT
    ui_cleanup 4
    exit 4
fi
if [ "${ABLETON_INTERNAL_OPTIONAL_STATUS:-0}" = 1 ] \
   && [ "$ABLETON_OPTIONAL_FILE_FAILURES" -gt 0 ]; then
    # Internal advisory status for the public installer summary. All selected
    # repair work and transaction cleanup above has already finished.
    trap - EXIT
    ui_cleanup 3
    exit 3
fi
# A standalone run reports its own outcome; the public installer's summary
# covers a coordinated one.
if [ -z "$transaction_arg" ] && [ "${ABLETON_INTERNAL_OPTIONAL_STATUS:-0}" != 1 ]; then
    [ "$want_runtime" -eq 0 ] || ui_status i_runtime_ready
    if [ "$ABLETON_OPTIONAL_FILE_FAILURES" -gt 0 ]; then
        ui_warn i_integration_partial
    elif [ "$ABLETON_OPTIONAL_FILES_KEPT" -gt 0 ]; then
        ui_warn i_kept_files "$ABLETON_OPTIONAL_FILES_KEPT"
    elif [ "$want_integration" -eq 1 ]; then
        ui_status i_launchers_ready
    elif [ "$want_link" -eq 1 ]; then
        ui_status i_link_files_ready
    fi
    if [ "$want_integration" -eq 1 ]; then
        ui_info i_hint_audio_report "$data"
        ui_info i_hint_ntsync_check "$data"
        ui_info i_hint_realtime_setup "$data"
        ui_info i_hint_rollback "$data"
    fi
fi
