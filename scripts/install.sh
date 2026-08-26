#!/usr/bin/env bash
# Install independently selectable runtime, desktop-integration, and Link-asset
# components.  Prefix creation is deliberately separate (setup-prefix.sh).
set -euo pipefail
export LC_ALL=C.UTF-8
ARCH="${ARCH:-$(uname -m)}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/config.sh"
. "$here/lib/lifecycle.sh"
. "$here/lib/manifest.sh"
if [ "$ARCH" = "x86_64" ]; then
. "$here/lib/pipeasio.sh"
fi

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

ableton_config_init
export WINEPREFIX="$ABLETON_WINEPREFIX"
data="$ABLETON_DATA_HOME"
bin="$ABLETON_BIN_HOME"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
mime_root="${XDG_DATA_HOME:-$HOME/.local/share}/mime"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
ownership_manifest_was_present=0
[ ! -r "$ABLETON_STATE_HOME/install-manifest.tsv" ] || ownership_manifest_was_present=1

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
    local txn="$1" rc=0
    preflight_rollback_transaction "$txn" || return 1
    rollback_runtime "$txn" || rc=1
    ableton_txn_rollback_files "$txn" || rc=1
    update-mime-database "$mime_root" >/dev/null 2>&1 || true
    update-desktop-database "$apps" >/dev/null 2>&1 || true
    gtk-update-icon-cache -q "$icons" >/dev/null 2>&1 || true
    if [ "$rc" -eq 0 ]; then
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
    local txn="$1" metadata_pending="${2:-1}" target backup rollback marker marker_tmp=""
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
    rm -f -- "$txn/active" || return 1
}

case "$operation" in
    preflight-rollback) preflight_rollback_transaction "$transaction_arg"; exit ;;
    preflight-commit) preflight_commit_transaction "$transaction_arg"; exit ;;
    rollback) rollback_transaction "$transaction_arg"; exit ;;
    commit) commit_transaction "$transaction_arg"; exit ;;
esac

[ "$want_runtime$want_integration$want_link" != 000 ] || {
    echo "!! select at least one component" >&2; exit 2; }

own_transaction=0
if [ -n "$transaction_arg" ]; then
    ABLETON_TRANSACTION_DIR="$transaction_arg"
elif [ "$validate_only" -eq 1 ] || [ "$dry_run" -eq 1 ] \
     || { [ "$want_runtime" -eq 1 ] && [ "$want_integration" -eq 0 ] && [ "$want_link" -eq 0 ]; }; then
    ABLETON_TRANSACTION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ableton-install-plan.XXXXXX")"
    own_transaction=1
else
    ableton_mark_state_home
    mkdir -p -- "$ABLETON_STATE_HOME/transactions"
    ABLETON_TRANSACTION_DIR="$(mktemp -d "$ABLETON_STATE_HOME/transactions/install.XXXXXX")"
    own_transaction=1
fi
export ABLETON_TRANSACTION_DIR
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_component_transaction()
{
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ "$own_transaction" -eq 1 ] \
       && ! rm -rf -- "$ABLETON_TRANSACTION_DIR"; then
        echo "!! failed to remove unstarted component transaction: $ABLETON_TRANSACTION_DIR" >&2
    fi
    exit "$rc"
}
trap cleanup_unstarted_component_transaction EXIT
ableton_txn_init
ableton_validate_install_state_journals
stage=""
component_commit_started=0
cleanup()
{
    local rc=$? restore_error="" restoration_complete=yes
    trap - EXIT
    if [ -n "$stage" ] && ! rm -rf -- "$stage"; then
        restore_error="temporary runtime cleanup failed"
        rc=1
    fi
    if [ "$rc" -ne 0 ] && [ "$component_commit_started" -eq 1 ]; then
        printf 'component=install.sh\nstatus=committed-cleanup-incomplete\nexit=%s\ncleanup_error=%s\n' \
            "$rc" "$restore_error" > "$ABLETON_TRANSACTION_DIR/COMMITTED_CLEANUP_FAILURE" 2>/dev/null || true
        echo "!! component installation is committed, but cleanup is incomplete" >&2
        echo "!! inspect $ABLETON_TRANSACTION_DIR/COMMITTED_CLEANUP_FAILURE before retrying" >&2
    elif [ "$rc" -ne 0 ] && [ -e "$ABLETON_TRANSACTION_DIR/active" ]; then
        echo "!! component installation failed; rolling its recorded mutations back" >&2
        if ! rollback_transaction "$ABLETON_TRANSACTION_DIR"; then
            restore_error="${restore_error}${restore_error:+; }component rollback failed"
        fi
        [ -z "$restore_error" ] || restoration_complete=no
        if [ "$own_transaction" -eq 1 ]; then
            printf 'component=install.sh\nexit=%s\nrestoration_complete=%s\nrestoration_error=%s\n' \
                "$rc" "$restoration_complete" "$restore_error" \
                > "$ABLETON_TRANSACTION_DIR/FAILURE" || true
            if [ "$restoration_complete" = yes ]; then
                echo "!! rollback complete; failure record: $ABLETON_TRANSACTION_DIR/FAILURE" >&2
            else
                echo "!! component rollback is incomplete: $restore_error" >&2
                echo "!! inspect $ABLETON_TRANSACTION_DIR/FAILURE before retrying" >&2
            fi
        fi
    elif [ "$rc" -ne 0 ] && [ -n "$restore_error" ]; then
        echo "!! component cleanup is incomplete: $restore_error" >&2
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
    version_lines="$(wc -l < "$root/VERSION")"
    version="$(sed -n '1p' "$root/VERSION")"
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
    actual_sha="$(sha256sum -- "$tarball" | awk '{print $1}')"
    [ "$actual_sha" = "$expected_sha" ] || { echo "!! runtime checksum does not match" >&2; return 1; }
    runtime_info="$root/BUILD-INFO-$version.txt"
    [ -s "$runtime_info" ] || runtime_info="$root/dist/BUILD-INFO-$version.txt"
    [ -s "$runtime_info" ] || { echo "!! exact BUILD-INFO-$version.txt is missing" >&2; return 1; }
    bundle_probe="$root/bin/pipewire-version-probe"
    [ -x "$bundle_probe" ] || bundle_probe="$root/dist/pipewire-version-probe"
    [ -x "$bundle_probe" ] || { echo "!! installer kit is missing its PipeWire compatibility check" >&2; return 1; }
    echo "== validate runtime payload: $(basename "$tarball") =="
    echo "$(basename "$tarball"): OK"
    local parent
    parent="$(dirname "$ABLETON_WINE_ROOT")"
    if [ "$validate_only" -eq 1 ] || [ "$dry_run" -eq 1 ]; then
        stage="$(mktemp -d "${TMPDIR:-/tmp}/ableton-runtime-validate.XXXXXX")"
    else
        mkdir -p -- "$parent"
        stage="$(mktemp -d "$parent/.ableton-runtime-stage.XXXXXX")"
    fi
    local extract_timeout
    extract_timeout="$(ableton_timeout_value "${ABLETON_RUNTIME_EXTRACT_TIMEOUT:-1800}" ABLETON_RUNTIME_EXTRACT_TIMEOUT 60 7200)"
    echo "   extracting and checking the staged runtime (bounded to ${extract_timeout}s)"
    if tar --help 2>&1 | grep -q -- '--checkpoint'; then
        ableton_run_bounded "$extract_timeout" tar --checkpoint=500 --checkpoint-action=dot \
            -C "$stage" -I zstd -xf "$tarball"
        printf '\n' >&2
    else
        ableton_run_bounded "$extract_timeout" tar -C "$stage" -I zstd -xf "$tarball"
    fi
    candidate="$stage/$ABLETON_RUNTIME_NAME"
    local required
    for required in \
        bin/wine bin/wineserver \
        lib/wine/$ARCH-windows/libusb-1.0.dll \
        lib/wine/$ARCH-unix/libusb-1.0.so \
        lib/wine/$ARCH-unix/comdlg32.so \
        lib/wine/$ARCH-unix/winealsa.so \
        lib/wine/$ARCH-unix/winegstreamer.so \
        bin/pipewire-version-probe \
        ABLETON-WINE-BUILD-INFO.txt \
        lib/wine/$ARCH-windows/pipeasio64.dll \
        lib/wine/$ARCH-windows/pipeasio.dll \
        lib/wine/$ARCH-unix/pipeasio64.dll.so \
        lib/wine/$ARCH-unix/pipeasio.dll.so; do
        [ -s "$candidate/$required" ] || { echo "!! runtime payload is missing $required" >&2; if [ "$ARCH" = "x86_64" ]; then return 1; fi  }
    done
    [ ! -e "$candidate/lib/wine/i386-windows/libusb-1.0.dll" ] || {
        echo "!! runtime unexpectedly contains a 32-bit Push bridge" >&2; return 1; }
    if command -v readelf >/dev/null 2>&1 && [ "$ARCH" = "x86_64" ] && command -v strings >/dev/null 2>&1; then
        readelf -d "$candidate/lib/wine/x86_64-unix/libusb-1.0.so" | grep -F 'Shared library: [libusb-1.0.so.0]' >/dev/null
        strings "$candidate/lib/wine/x86_64-unix/comdlg32.so" | grep -F 'org.freedesktop.portal.FileChooser' >/dev/null
        readelf -d "$candidate/lib/wine/x86_64-unix/pipeasio64.dll.so" | grep -F 'Shared library: [libpipewire-0.3.so.0]' >/dev/null
        readelf -d "$candidate/lib/wine/x86_64-unix/winegstreamer.so" | grep -F 'Shared library: [libgstreamer-1.0.so.0]' >/dev/null
    ableton_pipeasio_validate_runtime "$candidate" "$runtime_info" "$version"
    fi
    cmp -s -- "$bundle_probe" "$candidate/bin/pipewire-version-probe" || {
        echo "!! installer and runtime compatibility checks do not match" >&2; return 1; }
    ableton_run_bounded 30 "$candidate/bin/wine" --version
}

validate_integration_sources()
{
    local required probe_source="" ntsync_probe_source=""
    for required in ableton-live max9 detect-scale.sh detect-theme.sh shortcut-hold.sh \
                    setup-realtime.sh audio-report.sh check-ntsync.sh rollback.sh; do
        [ -f "$here/$required" ] || { echo "!! installer kit is missing scripts/$required" >&2; return 1; }
    done
    for required in config.sh lifecycle.sh live-options.sh manifest.sh pipeasio.sh; do
        [ -f "$here/lib/$required" ] || { echo "!! installer kit is missing scripts/lib/$required" >&2; return 1; }
    done
    for required in "$ABLETON_WINE_ROOT/bin/pipewire-version-probe" \
                    "$root/bin/pipewire-version-probe" "$root/dist/pipewire-version-probe"; do
        [ -x "$required" ] || continue
        probe_source="$required"
        break
    done
    [ -n "$probe_source" ] || {
        echo "!! installer kit is missing its PipeWire compatibility check" >&2
        return 1
    }
    for required in "$here/ntsyncprobe.exe" \
                    "$root/beta/tester-kit/probes/windows/ntsyncprobe.exe"; do
        [ -f "$required" ] || continue
        ntsync_probe_source="$required"
        break
    done
    [ -n "$ntsync_probe_source" ] || {
        echo "!! installer kit is missing its NTSync semantics probe" >&2
        return 1
    }
    for required in ableton-live.desktop.in ableton-linux-protocol.desktop.in \
                    ableton-linux-auz.desktop.in x-wine-extension-auz.xml \
                    icons/application-ableton-live.xml max9.desktop.in \
                    wine-protocol-c74max.desktop.in; do
        [ -f "$root/desktop/$required" ] || {
            echo "!! installer kit is missing desktop/$required" >&2; return 1; }
    done
    for required in xdg-mime update-desktop-database update-mime-database; do
        command -v "$required" >/dev/null 2>&1 || {
            echo "!! $required is required for desktop and MIME integration" >&2; return 1; }
    done
}

validate_link_sources()
{
    local file needed
    for file in "$here/../bin/ableton-linkd" "$root/dist/ableton-linkd"; do
        [ -f "$file" ] && { linkd_source="$file"; break; }
    done
    [ -n "$linkd_source" ] || { echo "!! installer kit is missing bin/ableton-linkd" >&2; return 1; }
    unit_source="$here/ableton-linkd.service"
    [ -f "$unit_source" ] || unit_source="$root/scripts/ableton-linkd.service"
    [ -f "$unit_source" ] || { echo "!! installer kit is missing ableton-linkd.service" >&2; return 1; }
    [ -f "$here/ableton-linkctl" ] || { echo "!! installer kit is missing ableton-linkctl" >&2; return 1; }
    if command -v readelf >/dev/null 2>&1; then
        needed="$(readelf -d "$linkd_source" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')"
        for file in $needed; do
            case "$file" in linux-vdso.so*|libm.so*|libc.so*|libpthread.so*|libatomic.so*|ld-linux*.so*) ;;
                *) echo "!! ableton-linkd links unexpected library $file" >&2; return 1 ;;
            esac
        done
    fi
    ableton_run_bounded 10 "$linkd_source" --help >/dev/null
}

[ "$want_runtime" -eq 0 ] || validate_runtime_payload
[ "$want_integration" -eq 0 ] || validate_integration_sources
[ "$want_link" -eq 0 ] || validate_link_sources

if [ "$validate_only" -eq 1 ]; then
    echo "OK: selected component payloads are valid"
    if [ -n "$stage" ]; then
        case "$(basename "$stage")" in ableton-runtime-validate.*) ;; *)
            echo "!! refusing unexpected validation staging path: $stage" >&2; exit 1 ;; esac
        [ -d "$stage" ] && [ ! -L "$stage" ] \
            && rm -rf -- "$stage" && [ ! -e "$stage" ] || exit 1
        stage=""
    fi
    rm -f -- "$ABLETON_TRANSACTION_DIR/active"
    if [ "$own_transaction" -eq 1 ]; then
        rm -rf -- "$ABLETON_TRANSACTION_DIR"
    fi
    trap - EXIT
    exit 0
fi

if [ "$dry_run" -eq 1 ]; then
    echo "PLAN: resolved configuration"
    [ "$want_runtime" -eq 0 ] || {
        printf '  replace runtime tree atomically: %s\n' "$ABLETON_WINE_ROOT"
        printf '  write runtime ownership marker: %s/.ableton-linux-runtime\n' "$ABLETON_WINE_ROOT"
    }
    if [ "$want_integration" -eq 1 ]; then
        printf '  write launcher: %s/ableton-live\n' "$bin"
        printf '  write launcher support and recovery tools below: %s\n' "$data"
        printf '  write NTSync diagnostic: %s/{check-ntsync.sh,ntsyncprobe.exe}\n' "$data"
        printf '  write helper assets when packaged: %s/{setsyscolors.exe,learnheal.exe}\n' "$data"
        printf '  write desktop entries: %s/{ableton-live,%s,%s}\n' \
            "$apps" "$ABLETON_PROTOCOL_DESKTOP_ID" "$ABLETON_AUZ_DESKTOP_ID"
        printf '  write staged callback entries: %s/{%s,%s}\n' \
            "$data" "$ABLETON_PROTOCOL_DESKTOP_ID" "$ABLETON_AUZ_DESKTOP_ID"
        printf '  write icon files below: %s/{scalable,symbolic}\n' "$icons"
        printf '  write MIME packages below: %s/packages\n' "$mime_root"
        printf '  record/modify MIME defaults: %s/mime-prestate.tsv and %s\n' \
            "$ABLETON_STATE_HOME" "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
        if [ -f "$ABLETON_WINEPREFIX/drive_c/Program Files/Cycling '74/Max 9/Max.exe" ]; then
            printf '  write Max launcher and desktop/protocol entries: %s/max9, %s/{max9,wine-protocol-c74max}.desktop\n' "$bin" "$apps"
        fi
    fi
    if [ "$want_link" -eq 1 ]; then
        if [ "$ABLETON_LINKD" = "$ABLETON_DATA_HOME/ableton-linkd" ]; then
            printf '  write Link binary: %s\n' "$ABLETON_LINKD"
        else
            printf '  use external Link binary without taking ownership: %s\n' "$ABLETON_LINKD"
        fi
        printf '  write Link controller/setup/unit assets: %s/{ableton-linkctl,setup-link.sh,ableton-linkd.service}\n' "$data"
        printf '  write Link support libraries: %s/lib/{config.sh,lifecycle.sh,manifest.sh}\n' "$data"
    fi
    if [ "$want_integration" -eq 1 ] || [ "$want_link" -eq 1 ]; then
        printf '  write component version: %s/VERSION\n' "$data"
    fi
    if [ "$want_integration" -eq 1 ] || [ "$want_link" -eq 1 ] \
       || { [ "$want_runtime" -eq 1 ] && [ "$ownership_manifest_was_present" -eq 1 ]; }; then
        printf '  update ownership manifest: %s/install-manifest.tsv\n' "$ABLETON_STATE_HOME"
    fi
    if [ -n "$stage" ]; then
        case "$(basename "$stage")" in ableton-runtime-validate.*) ;; *)
            echo "!! refusing unexpected validation staging path: $stage" >&2; exit 1 ;; esac
        [ -d "$stage" ] && [ ! -L "$stage" ] \
            && rm -rf -- "$stage" && [ ! -e "$stage" ] || exit 1
        stage=""
    fi
    rm -f -- "$ABLETON_TRANSACTION_DIR/active"
    if [ "$own_transaction" -eq 1 ]; then
        rm -rf -- "$ABLETON_TRANSACTION_DIR"
    fi
    trap - EXIT
    exit 0
fi

# Direct component use receives the same gate as the wrapper. Validation and
# dry-run remain usable without a running daemon; Link/integration-only work
# carries no PipeASIO driver replacement and is not gated.
if [ "$want_runtime" -eq 1 ]; then
    if [ "$ARCH" = "x86_64" ]; then
        ableton_pipewire_preflight "$candidate/bin/pipewire-version-probe" "installing PipeASIO"
    fi
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
    local all scoped foreign pid answer=""
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
            printf 'Stop every client in this prefix (including Live or Max)? [y/N] ' >&2
            read -r -t 60 answer || answer=""
            case "$answer" in y|Y|yes|YES|Yes) ;; *) return 1 ;; esac
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
    parent="$(dirname "$target")"
    mkdir -p -- "$parent"
    safe="$(ableton_path_is_safe_delete_target "$target")" || { echo "!! unsafe runtime target: $target" >&2; return 1; }
    backup=absent
    if [ -e "$safe" ]; then
        [ ! -L "$safe" ] || { echo "!! refusing to replace symlink runtime $safe" >&2; return 1; }
        ableton_adopt_runtime_marker "$safe" "$ABLETON_RUNTIME_NAME" || {
            echo "!! refusing to replace an unrecognised runtime directory: $safe" >&2
            return 1
        }
        backup="$safe.transaction-${ABLETON_TRANSACTION_DIR##*/}"
        [ ! -e "$backup" ] && [ ! -L "$backup" ] \
            || { echo "!! transaction backup already exists: $backup" >&2; return 1; }
    fi
    stop_runtime_clients
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
    ableton_promote_directory "$candidate" "$safe" "$backup" "$record"
    ableton_runtime_marker_valid "$safe" "$ABLETON_RUNTIME_NAME" || {
        echo "!! promoted runtime lost its ownership marker" >&2; return 1; }
    ABLETON_RUNTIME_INSTALLED=1
    export ABLETON_RUNTIME_INSTALLED
    ableton_run_bounded 30 "$safe/bin/wine" --version
}

sed_escape()
{
    printf '%s' "$1" | sed 's/[\\&#]/\\&/g'
}

record_mime_prestate()
{
    local state="$ABLETON_STATE_HOME/mime-prestate.tsv" type old tmp
    ableton_validate_mime_prestate "$state" || return 1
    [ -e "$state" ] && return 0
    ableton_txn_snapshot "$state"
    ableton_mark_state_home
    tmp="$(mktemp "$ABLETON_STATE_HOME/.mime-prestate.XXXXXX")" || return 1
    if command -v xdg-mime >/dev/null 2>&1; then
        for type in x-scheme-handler/ableton application/x-wine-extension-auz \
                    application/x-ableton-live-set application/x-ableton-live-clip \
                    application/x-ableton-live-pack application/x-ableton-live-max-device \
                    x-scheme-handler/c74max; do
            old="$(xdg-mime query default "$type" 2>/dev/null || true)"
            printf '%s\t%s\n' "$type" "$old" >> "$tmp"
        done
    fi
    if ! chmod 600 "$tmp" \
       || ! ableton_txn_expect "$state" "$(ableton_regular_source_token "$tmp")" \
       || ! mv -f -- "$tmp" "$state"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Wine and other packages use some of these desktop entry names.  The installer
# leaves an entry that does not run its own launcher, and never makes that entry
# the default for the types it registers.
desktop_entry_is_foreign()
{
    local target="$1" owner="$2"
    [ -e "$target" ] || return 1
    ! grep -qxF "Exec=$owner %f" "$target" \
        && ! grep -qxF "Exec=$owner %u" "$target"
}

install_integration()
{
    local tool source target tmp newest="" exe live_name="Ableton Live" live_icon=live-suite live_wmclass="" edition d i
    local live_desktop_foreign=0 max_desktop_foreign=0 max_protocol_foreign=0 foreign=0
    local probe_source="" ntsync_probe_source="" mime_stage="" mimeapps_file="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
    local max_unix="$ABLETON_WINEPREFIX/drive_c/Program Files/Cycling '74/Max 9/Max.exe"
    local -a handler_ids=("$ABLETON_PROTOCOL_DESKTOP_ID" "$ABLETON_AUZ_DESKTOP_ID")
    local -a handler_templates=(ableton-linux-protocol ableton-linux-auz)
    echo "== install launchers and host integration =="
    for tool in config.sh lifecycle.sh live-options.sh manifest.sh pipeasio.sh; do
        ableton_install_file 644 "$here/lib/$tool" "$data/lib/$tool"
    done
    # An update refreshes this project launcher when its saved checksum differs.
    # The update preserves a symlink.
    ableton_install_file 755 "$here/ableton-live" "$bin/ableton-live" file refresh-stale-record
    for tool in detect-scale.sh detect-theme.sh shortcut-hold.sh; do
        ableton_install_file 644 "$here/$tool" "$data/$tool"
    done
    for tool in setup-realtime.sh audio-report.sh check-ntsync.sh rollback.sh; do
        ableton_install_file 755 "$here/$tool" "$data/$tool"
    done
    for source in "$here/ntsyncprobe.exe" \
                  "$root/beta/tester-kit/probes/windows/ntsyncprobe.exe"; do
        [ -f "$source" ] || continue
        ntsync_probe_source="$source"
        break
    done
    [ -n "$ntsync_probe_source" ] || {
        echo "!! installer kit is missing its NTSync semantics probe" >&2
        return 1
    }
    ableton_install_file 644 "$ntsync_probe_source" "$data/ntsyncprobe.exe"
    for source in "$ABLETON_WINE_ROOT/bin/pipewire-version-probe" \
                  "$root/bin/pipewire-version-probe" "$root/dist/pipewire-version-probe"; do
        [ -x "$source" ] || continue
        probe_source="$source"
        break
    done
    [ -n "$probe_source" ] || {
        echo "!! installer kit is missing its PipeWire compatibility check" >&2
        return 1
    }
    ableton_install_file 755 "$probe_source" "$data/pipewire-version-probe"
    for tool in setsyscolors.exe learnheal.exe; do
        for source in "$here/$tool" "$root/tools/$tool"; do
            [ -f "$source" ] || continue
            ableton_install_file 644 "$source" "$data/$tool"
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
    tmp="$(mktemp)"
    sed -e "s#@HOME@#$(sed_escape "$HOME")#g" \
        -e "s#@BIN@#$(sed_escape "$bin")#g" \
        -e "s#@PREFIX@#$(sed_escape "$ABLETON_WINEPREFIX")#g" \
        -e "s#@NAME@#$(sed_escape "$live_name")#g" \
        -e "s#@ICON@#$(sed_escape "$live_icon")#g" \
        -e "s#@WMCLASS@#$(sed_escape "$live_wmclass")#g" \
        "$root/desktop/ableton-live.desktop.in" > "$tmp"
    [ -n "$live_wmclass" ] || sed -i '/^StartupWMClass=/d' "$tmp"
    if desktop_entry_is_foreign "$apps/ableton-live.desktop" "$bin/ableton-live"; then
        live_desktop_foreign=1
        echo "   preserving foreign $apps/ableton-live.desktop"
        echo "   the Live file types stay with their current application"
    else
        # The launcher updates this generated entry after Live starts. An update
        # refreshes the entry when its saved checksum differs.
        ableton_install_file 644 "$tmp" "$apps/ableton-live.desktop" file refresh-stale-record
    fi
    rm -f -- "$tmp"

    for ((i=0; i<${#handler_ids[@]}; i++)); do
        d="${handler_ids[i]}"
        tmp="$(mktemp)"
        sed -e "s#@HOME@#$(sed_escape "$HOME")#g" -e "s#@BIN@#$(sed_escape "$bin")#g" \
            "$root/desktop/${handler_templates[i]}.desktop.in" > "$tmp"
        ableton_install_file 644 "$tmp" "$data/$d"
        ableton_install_file 644 "$tmp" "$apps/$d"
        rm -f -- "$tmp"
    done

    # Retire only the legacy handlers written by this project.  Wine may still
    # own files with these globally contested names, so an entry that does not
    # route through ableton-live stays in place while the default moves to the
    # project-specific ID.
    for target in \
        "$data/wine-protocol-ableton.desktop" "$data/wine-extension-auz.desktop" \
        "$apps/wine-protocol-ableton.desktop" "$apps/wine-extension-auz.desktop"; do
        [ -e "$target" ] || continue
        if grep -Eq '^Exec=.*/ableton-live (%u|%f)$' "$target"; then
            echo "   removing legacy project handler $target"
            ableton_remove_managed_file "$target"
        else
            echo "   preserving foreign legacy handler $target"
        fi
    done

    for source in "$root"/desktop/icons/scalable/apps/*.svg; do
        ableton_install_file 644 "$source" "$icons/scalable/apps/$(basename "$source")"
    done
    for source in "$root"/desktop/icons/scalable/mimetypes/*.svg; do
        ableton_install_file 644 "$source" "$icons/scalable/mimetypes/$(basename "$source")"
    done
    for source in "$root"/desktop/icons/symbolic/apps/*.svg; do
        ableton_install_file 644 "$source" "$icons/symbolic/apps/$(basename "$source")"
    done
    ableton_install_file 644 "$root/desktop/x-wine-extension-auz.xml" "$mime_root/packages/x-wine-extension-auz.xml"
    ableton_install_file 644 "$root/desktop/icons/application-ableton-live.xml" "$mime_root/packages/application-ableton-live.xml"

    # The loop below writes the Max entries, but this stages their defaults,
    # so settle their ownership first.
    if desktop_entry_is_foreign "$apps/max9.desktop" "$bin/max9"; then
        max_desktop_foreign=1
    fi
    if desktop_entry_is_foreign "$apps/wine-protocol-c74max.desktop" "$bin/max9"; then
        max_protocol_foreign=1
    fi

    record_mime_prestate
    if command -v xdg-mime >/dev/null 2>&1; then
        if [ -e "$mimeapps_file" ] || [ -L "$mimeapps_file" ]; then
            [ -f "$mimeapps_file" ] && [ ! -L "$mimeapps_file" ] || {
                echo "!! refusing unsafe MIME association file $mimeapps_file" >&2; return 1; }
        fi
        mime_stage="$(mktemp -d "${TMPDIR:-/tmp}/ableton-mimeapps.XXXXXX")" || return 1
        [ ! -e "$mimeapps_file" ] || cp -- "$mimeapps_file" "$mime_stage/mimeapps.list"
        if ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                "$ABLETON_PROTOCOL_DESKTOP_ID" x-scheme-handler/ableton \
           || ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                "$ABLETON_AUZ_DESKTOP_ID" application/x-wine-extension-auz \
           || { [ "$live_desktop_foreign" -eq 0 ] \
                && ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                    ableton-live.desktop application/x-ableton-live-set \
                    application/x-ableton-live-clip application/x-ableton-live-pack; }; then
            rm -rf -- "$mime_stage"
            echo "!! MIME association staging failed; existing associations were unchanged" >&2
            return 1
        fi
        if [ -f "$max_unix" ] \
           && { { [ "$max_desktop_foreign" -eq 0 ] \
                  && ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                      max9.desktop application/x-ableton-live-max-device; } \
                || { [ "$max_protocol_foreign" -eq 0 ] \
                     && ! env XDG_CONFIG_HOME="$mime_stage" xdg-mime default \
                         wine-protocol-c74max.desktop x-scheme-handler/c74max; }; }; then
            rm -rf -- "$mime_stage"
            echo "!! MIME association staging failed; existing associations were unchanged" >&2
            return 1
        fi
        if [ -e "$mime_stage/mimeapps.list" ]; then
            ableton_txn_replace_unowned_file "$mime_stage/mimeapps.list" "$mimeapps_file"
        fi
        rm -rf -- "$mime_stage"
    fi

    if [ -f "$max_unix" ]; then
        ableton_install_file 755 "$here/max9" "$bin/max9"
        for d in max9 wine-protocol-c74max; do
            tmp="$(mktemp)"
            sed -e "s#@HOME@#$(sed_escape "$HOME")#g" -e "s#@BIN@#$(sed_escape "$bin")#g" \
                -e "s#@PREFIX@#$(sed_escape "$ABLETON_WINEPREFIX")#g" \
                "$root/desktop/$d.desktop.in" > "$tmp"
            target="$apps/$d.desktop"
            case "$d" in
                max9) foreign="$max_desktop_foreign" ;;
                *) foreign="$max_protocol_foreign" ;;
            esac
            if [ "$foreign" -eq 1 ]; then
                echo "   preserving foreign $target"
                echo "   its associations stay with their current application"
            else
                ableton_install_file 644 "$tmp" "$target"
            fi
            rm -f -- "$tmp"
        done
    fi

    echo "== register desktop and MIME integration =="
    update-mime-database "$mime_root" || {
        echo "!! failed to update the MIME database at $mime_root" >&2; return 1; }
    update-desktop-database "$apps" || {
        echo "!! failed to update the desktop application database at $apps" >&2; return 1; }

    pin_mime_default()
    {
        local id="$1" type="$2" current
        xdg-mime default "$id" "$type" || {
            echo "!! failed to set $type to $id" >&2; return 1; }
        current="$(xdg-mime query default "$type")" || {
            echo "!! failed to query the active handler for $type" >&2; return 1; }
        [ "$current" = "$id" ] || {
            echo "!! $type resolves to '${current:-no handler}' after registration; expected $id" >&2
            return 1
        }
    }
    pin_mime_default "$ABLETON_PROTOCOL_DESKTOP_ID" x-scheme-handler/ableton
    pin_mime_default "$ABLETON_AUZ_DESKTOP_ID" application/x-wine-extension-auz
    if [ "$live_desktop_foreign" -eq 0 ]; then
        for d in application/x-ableton-live-set application/x-ableton-live-clip application/x-ableton-live-pack; do
            pin_mime_default ableton-live.desktop "$d"
        done
    fi
    if [ -f "$max_unix" ]; then
        if [ "$max_desktop_foreign" -eq 0 ]; then
            pin_mime_default max9.desktop application/x-ableton-live-max-device
        fi
        if [ "$max_protocol_foreign" -eq 0 ]; then
            pin_mime_default wine-protocol-c74max.desktop x-scheme-handler/c74max
        fi
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q "$icons" || \
            echo "!! warning: failed to refresh the icon cache at $icons" >&2
    fi
}

install_link_assets()
{
    echo "== install Link assets (not enabled or started) =="
    local tool restart_always=0 fragment="" expected_unit
    local managed_linkd="$ABLETON_DATA_HOME/ableton-linkd"
    local legacy_custom="${ABLETON_PR182_CUSTOM_LINKD:-}"
    if [ -x "$ABLETON_LINKD" ]; then
        [ "$ABLETON_LINK_MODE" != always ] || restart_always=1
        if command -v systemctl >/dev/null 2>&1; then
            fragment="$(ableton_run_bounded 20 systemctl --user show -p FragmentPath --value ableton-linkd.service 2>/dev/null || true)"
            expected_unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ableton-linkd.service"
            if [ -n "$fragment" ] \
               && [ "$(ableton_realpath_m "$fragment")" = "$(ableton_realpath_m "$expected_unit")" ] \
               && grep -qxF 'X-AbletonLinuxOwned=true' "$expected_unit" 2>/dev/null; then
                ableton_run_bounded 20 systemctl --user stop ableton-linkd.service >/dev/null 2>&1 || return 1
            fi
        fi
        "$here/ableton-linkctl" stop || return 1
    fi
    # setup-link.sh sources manifest.sh and stops without it, so a Link-only
    # install ships it too.
    for tool in config.sh lifecycle.sh manifest.sh; do
        ableton_install_file 644 "$here/lib/$tool" "$data/lib/$tool"
    done
    if [ -n "$legacy_custom" ]; then
        # Seal the proof first and keep it: the VERSION write below stops the live
        # recogniser matching, and the sealed copy is what authorises this path for
        # the rest of the transaction.  Then dispose of it the way every other
        # relinquished managed file is disposed of.  An unmodified object is removed
        # and any pre-install file it displaced comes back; a changed one is left
        # exactly where it is and only the ownership claim is dropped.
        ableton_txn_authorize_pr182_custom_link "$legacy_custom" || {
            echo "!! legacy custom Link ownership could not be verified" >&2
            return 1
        }
        if ableton_pr182_custom_link_owned "$legacy_custom"; then
            ableton_remove_managed_file "$legacy_custom" || return 1
            echo "   retired the PR #182 custom Link binary ownership"
        else
            ableton_abandon_managed_file "$legacy_custom" || return 1
            echo "   kept and de-owned the modified former PR #182 Link binary"
        fi
    fi
    # A configured external Link daemon may be executed by the controller, but
    # it is never installed, claimed, restored, or removed by this project.
    if [ "$ABLETON_LINKD" = "$managed_linkd" ]; then
        ableton_install_file 755 "$linkd_source" "$managed_linkd"
    else
        [ -x "$ABLETON_LINKD" ] || {
            echo "!! configured external Link daemon is not executable: $ABLETON_LINKD" >&2
            return 1
        }
        printf '   using external Link daemon without taking ownership: %s\n' "$ABLETON_LINKD"
    fi
    ableton_install_file 755 "$here/ableton-linkctl" "$data/ableton-linkctl"
    ableton_install_file 755 "$here/setup-link.sh" "$data/setup-link.sh"
    ableton_install_file 644 "$unit_source" "$data/ableton-linkd.service"
    if [ "$restart_always" -eq 1 ]; then
        ableton_run_bounded 20 systemctl --user start ableton-linkd.service
    fi
}

[ "$want_runtime" -eq 0 ] || promote_runtime
if [ "$want_integration" -eq 1 ]; then
    install_integration
    if [ "$ARCH" = "x86_64" ]; then
        ableton_pipeasio_optional_tools_advice
    fi
fi
[ "$want_link" -eq 0 ] || install_link_assets

# The panel follows the selected runtime even for a runtime-only update.  An
# integration-only install remains independently usable when no runtime has
# been installed yet.
if [ "$want_runtime" -eq 1 ] && [ "$ARCH" = "x86_64" ]; then
    ableton_pipeasio_validate_runtime "$ABLETON_WINE_ROOT"
    if [ "$want_integration" -eq 1 ]; then
        ableton_pipeasio_sync_panel "$ABLETON_WINE_ROOT" install
    else
        ableton_pipeasio_sync_panel "$ABLETON_WINE_ROOT" reconcile
    fi
elif [ "$want_integration" -eq 1 ]; then
    if grep -qxF 'pipeasio-panel: built' "$ABLETON_WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null \
       || grep -qxF 'pipeasio-panel: skipped' "$ABLETON_WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt" 2>/dev/null; then
        if ableton_pipeasio_validate_runtime "$ABLETON_WINE_ROOT" >/dev/null 2>&1; then
            ableton_pipeasio_sync_panel "$ABLETON_WINE_ROOT" install
        else
            echo "   kept existing PipeASIO panel links because this runtime uses another panel format"
        fi
    else
        echo "   launcher integration continues with the available PipeASIO files"
    fi
fi

if [ "$want_integration" -eq 1 ] || [ "$want_link" -eq 1 ]; then
    version_tmp=""
    mkdir -p -- "$data"
    version_tmp="$(mktemp "$data/.VERSION.XXXXXX")" || exit 1
    if ! printf '%s\n' "$(cat "$root/VERSION" 2>/dev/null || echo unknown)" > "$version_tmp" \
       || ! ableton_install_file 644 "$version_tmp" "$data/VERSION"; then
        rm -f -- "$version_tmp"
        exit 1
    fi
    rm -f -- "$version_tmp"
fi
if [ "$want_integration" -eq 1 ] || [ "$want_link" -eq 1 ] \
   || { [ "$want_runtime" -eq 1 ] && [ "$ownership_manifest_was_present" -eq 1 ]; }; then
    ableton_write_ownership_manifest
fi

[ -z "$stage" ] || rm -rf -- "$stage"
stage=""
if [ "$own_transaction" -eq 1 ]; then
    commit_transaction "$ABLETON_TRANSACTION_DIR" 0
    if ! rm -rf -- "$ABLETON_TRANSACTION_DIR"; then
        echo "!! committed component transaction could not be retired" >&2
        exit 1
    fi
else
    rm -f -- "$ABLETON_TRANSACTION_DIR/active"
fi
trap - EXIT
echo "OK: selected components installed transactionally"
if [ "$want_integration" -eq 1 ]; then
    printf '   Audio report: %s/audio-report.sh\n' "$data"
    printf '   NTSync check: %s/check-ntsync.sh\n' "$data"
    printf '   Realtime setup: %s/setup-realtime.sh\n' "$data"
    printf '   Runtime rollback: %s/rollback.sh\n' "$data"
fi
