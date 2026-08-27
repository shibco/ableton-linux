#!/usr/bin/env bash
# End-user step 2: create or refresh the Ableton Wine prefix. Idempotent.
# Ships no Ableton Live payload and no license; standalone setup can run the
# user's own ableton_live*.zip download (~/Proprietary by default) - strictly opt-in
# via ABLETON_LIVE_AUTOINSTALL=1, otherwise the manual steps are printed.
# --refresh: maintenance pass on an EXISTING prefix (used by the .run's update
# mode): re-applies registry policy and heals runtime DLLs, but skips the slow
# winetricks pass; the fonts/runtimes it installs are already in the prefix.
# --post-first-run: standalone fixup to run after Live's first launch: moves
# Max for Live 8's preferences aside (never deletes) so its second start stops
# crashing. Needs no wine and skips every other step.
# ABLETON_LIVE_VERSION=11|12 pins the winetricks recipe; unpinned, an opted-in
# auto-install derives it from the chosen zip's filename (default 12).
set -euo pipefail

# Terminal output is informational. A closed terminal, full log, or broken
# pipe must never change the result of prefix setup or recovery.
prefix_note()
{
    printf '%s\n' "$*" 2>/dev/null || true
    return 0
}

prefix_warn()
{
    printf '%s\n' "$*" >&2 2>/dev/null || true
    return 0
}

here="$(cd "$(dirname "$0")" && pwd)"
for config_lib in "$here/lib/config.sh" "$here/config.sh" \
                  "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    if [ -r "$config_lib" ]; then . "$config_lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 \
    || { prefix_warn "!! Setup support files are incomplete. Run the latest installer again."; exit 1; }
. "$here/lib/manifest.sh"
. "$here/lib/pipeasio.sh"

# The kit root holds vendor/. Layouts that must work:
#   <kit>/scripts/setup-prefix.sh        -> vendor at $here/../vendor (repo, extracted .run kit)
#   <dir>/setup-prefix.sh + <dir>/vendor -> vendor at $here/vendor
# Resolved lazily so --refresh (which skips the winetricks pass) never trips this;
# install.sh deliberately does not install vendor/ into ~/.local/share/ableton-wine.
root=""
kit_root() {
    [ -n "$root" ] && return 0
    local cand
    for cand in "$here/.." "$here"; do
        if [ -f "$cand/vendor/winetricks" ]; then
            root="$(cd "$cand" && pwd)"
            return 0
        fi
    done
    return 1
}
kit_root_or_die() {
    kit_root && return 0
    prefix_warn "!! The Windows support files for Live are missing."
    prefix_warn "!! Run: sh install-ableton-latest.run update"
    prefix_warn "!! Or extract the kit and run prefix setup from there."
    exit 1
}

report_existing_prefix()
{
    printf ':: Using the existing Wine prefix: %s\n' "$1" 2>/dev/null || true
    return 0
}

refresh=0
post_first_run=0
validate_only=0
transaction_dir=""
operation=setup
while [ $# -gt 0 ]; do
    case "$1" in
        --refresh) refresh=1 ;;
        --post-first-run) post_first_run=1 ;;
        --validate) validate_only=1 ;;
        --transaction-dir)
            [ $# -ge 2 ] || { prefix_warn "!! --transaction-dir needs a directory"; exit 2; }
            transaction_dir="$2"; shift ;;
        --rollback)
            [ $# -ge 2 ] || { prefix_warn "!! --rollback needs a directory"; exit 2; }
            operation=rollback; transaction_dir="$2"; shift ;;
        --preflight-rollback)
            [ $# -ge 2 ] || { prefix_warn "!! --preflight-rollback needs a directory"; exit 2; }
            operation=preflight-rollback; transaction_dir="$2"; shift ;;
        --preflight-commit)
            [ $# -ge 2 ] || { prefix_warn "!! --preflight-commit needs a directory"; exit 2; }
            operation=preflight-commit; transaction_dir="$2"; shift ;;
        --commit)
            [ $# -ge 2 ] || { prefix_warn "!! --commit needs a directory"; exit 2; }
            operation=commit; transaction_dir="$2"; shift ;;
        *) prefix_warn "!! Unknown option: $1"; exit 2 ;;
    esac
    shift
done

if [ "$operation" != setup ] || [ "$validate_only" -eq 1 ]; then
    # Recovery/preflight validates any recorded prefix target itself; a domain
    # with no prefix record is a successful no-op even if an unrelated prefix
    # path currently has a foreign shape.
    ABLETON_CONFIG_LAYOUT_ROOTS=none
elif [ "$post_first_run" -eq 1 ]; then
    ABLETON_CONFIG_LAYOUT_ROOTS=prefix
else
    ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix state'
fi
export ABLETON_CONFIG_LAYOUT_ROOTS
ableton_config_init repair

case "${ABLETON_LIVE_VERSION:-12}" in
    11|12) ;;
    *) prefix_warn "!! ABLETON_LIVE_VERSION must be 11 or 12 (got '$ABLETON_LIVE_VERSION')"; exit 2 ;;
esac

caller_winedlloverrides="${WINEDLLOVERRIDES:-}"
unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH WINEESYNC WINEFSYNC
WINE_ROOT="$ABLETON_WINE_ROOT"
export WINEPREFIX="$ABLETON_WINEPREFIX"
export PATH="$WINE_ROOT/bin:$PATH"
# The kit bin beside scripts/ carries kit-private tools: the .run kit's static
# cabextract, the nix package's cabextract and unzip symlinks.
kit_bin="$(cd "$here/../bin" 2>/dev/null && pwd)" || kit_bin=""
[ -z "$kit_bin" ] || PATH="$kit_bin:$PATH"
export WINEDEBUG=-all
export WINESERVER="$WINE_ROOT/bin/wineserver"
# Mesa prints "radv is not a conformant Vulkan implementation" once per wine
# process spawn; winetricks spawns dozens, and those lines crowd out the
# step's own output.
export MESA_VK_IGNORE_CONFORMANCE_WARNING=1
prefix_commit_started=0

prefix_transaction_preflight()
{
    local txn="$1" mode="${2:-rollback}" record="$1/prefix.tsv" target backup extra safe backup_safe expected_backup
    if [ -e "$record" ] || [ -L "$record" ]; then
        [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] \
            && ableton_file_has_no_nul "$record" \
            && [ "$(wc -l < "$record")" -eq 1 ] || {
            prefix_warn "!! The saved Wine prefix recovery data is unsafe or invalid."; return 1; }
        IFS=$'\t' read -r target backup extra < "$record" || {
            prefix_warn "!! The saved Wine prefix recovery data could not be read."; return 1; }
        [ -z "$extra" ] && [ -n "$target" ] && [ -n "$backup" ] || {
            prefix_warn "!! The saved Wine prefix recovery data is malformed."; return 1; }
        safe="$(ableton_path_is_safe_delete_target "$target")" || {
            prefix_warn "!! The saved Wine prefix path is unsafe: $target"; return 1; }
        [ "$target" = "$safe" ] \
            && [ "$safe" = "$(ableton_realpath_m "$ABLETON_WINEPREFIX")" ] || {
            prefix_warn "!! The saved Wine prefix does not match this installation: $target"
            return 1
        }
        if [ -e "$safe" ] || [ -L "$safe" ]; then
            if ! { [ -d "$safe" ] && [ ! -L "$safe" ] \
                   && ableton_prefix_marker_valid "$safe" "$safe"; }; then
                prefix_warn "!! The Wine prefix selected for recovery is not recognized: $safe"
                return 1
            fi
        fi
        if [ "$backup" != absent ]; then
            expected_backup="$safe.transaction-${txn##*/}"
            backup_safe="$(ableton_path_is_safe_delete_target "$backup")" || {
                prefix_warn "!! The saved previous Wine prefix path is unsafe: $backup"; return 1; }
            [ "$backup" = "$expected_backup" ] && [ "$backup" = "$backup_safe" ] || {
                prefix_warn "!! The saved previous Wine prefix is in the wrong place: $backup"; return 1; }
            if [ -e "$backup" ] || [ -L "$backup" ]; then
                if ! { [ -d "$backup" ] && [ ! -L "$backup" ] \
                       && ableton_prefix_marker_valid "$backup" "$safe"; }; then
                    prefix_warn "!! The saved previous Wine prefix is not recognized: $backup"
                    return 1
                fi
            elif [ "$mode" != commit ]; then
                prefix_warn "!! The saved previous Wine prefix is missing: $backup"
                return 1
            fi
        fi
    fi
    # Older releases stored host-file recovery beside the prefix record. New
    # setup runs do not create that journal, but retained old recovery remains
    # readable so an interrupted older install can still be restored safely.
    if [ -e "$txn/prefix-host" ] || [ -L "$txn/prefix-host" ]; then
        [ -d "$txn/prefix-host" ] && [ ! -L "$txn/prefix-host" ] || {
            prefix_warn "!! Saved support-file recovery data is unsafe."; return 1; }
        ableton_txn_preflight_rollback_files "$txn/prefix-host" || return 1
    fi
}

prefix_transaction_commit_preflight()
{
    local txn="$1" record="$1/prefix.tsv"
    prefix_transaction_preflight "$txn" commit || return 1
    if [ -e "$txn/prefix-host" ]; then
        ableton_txn_preflight_commit_files "$txn/prefix-host" || return 1
    fi
}

prefix_transaction_rollback()
{
    local txn="$1" target backup safe="" backup_safe="" expected_backup
    local rc=0 layout_ok=1
    prefix_transaction_preflight "$txn" || return 1
    if [ -r "$txn/prefix.tsv" ]; then
        IFS=$'\t' read -r target backup < "$txn/prefix.tsv" || {
            prefix_warn "!! The saved Wine prefix recovery data could not be read."
            return 1
        }
        if ! safe="$(ableton_path_is_safe_delete_target "$target")"; then
            prefix_warn "!! The saved Wine prefix path is unsafe: $target"
            rc=1; layout_ok=0
        elif [ "$target" != "$safe" ] \
             || [ "$safe" != "$(ableton_realpath_m "$ABLETON_WINEPREFIX")" ]; then
            prefix_warn "!! The saved Wine prefix does not match this installation: $target"
            rc=1; layout_ok=0
        fi
        if [ "$layout_ok" -eq 1 ] && [ "$backup" != absent ]; then
            expected_backup="$safe.transaction-${txn##*/}"
            if ! backup_safe="$(ableton_path_is_safe_delete_target "$backup")" \
               || [ "$backup" != "$expected_backup" ] || [ "$backup" != "$backup_safe" ] \
               || [ ! -d "$backup" ] || [ -L "$backup" ] \
               || ! ableton_prefix_marker_valid "$backup" "$safe"; then
                prefix_warn "!! The saved previous Wine prefix is missing, misplaced, or not recognized: $backup"
                rc=1; layout_ok=0
            fi
        fi
        if [ "$layout_ok" -eq 1 ] && [ -e "$safe" ]; then
            if [ -L "$safe" ]; then
                prefix_warn "!! Recovery stopped because the Wine prefix path is a link: $safe"
                rc=1; layout_ok=0
            elif ! ableton_prefix_marker_valid "$safe" "$safe"; then
                prefix_warn "!! Recovery stopped because this Wine prefix was not created by Ableton Linux: $safe"
                rc=1; layout_ok=0
            elif ! rm -rf -- "$safe"; then
                rc=1; layout_ok=0
            fi
        fi
        if [ "$layout_ok" -eq 1 ] && [ "$backup" != absent ]; then
            if ! mv -T -n -- "$backup" "$safe" \
               || [ -e "$backup" ] || [ -L "$backup" ] \
               || [ ! -d "$safe" ] || [ -L "$safe" ]; then
                rc=1; layout_ok=0
            fi
        fi
        if [ "$layout_ok" -eq 1 ]; then
            rm -f -- "$txn/prefix.tsv" || rc=1
        fi
    fi
    if [ -d "$txn/prefix-host" ] && [ ! -L "$txn/prefix-host" ]; then
        ableton_txn_rollback_files "$txn/prefix-host" || rc=1
        if [ "$rc" -eq 0 ]; then
            rm -f -- "$txn/prefix-host/active" || rc=1
        fi
    fi
    update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true
    return "$rc"
}

prefix_transaction_commit()
{
    local txn="$1" target backup safe
    prefix_transaction_commit_preflight "$txn" || return 1
    [ -r "$txn/prefix.tsv" ] || return 0
    IFS=$'\t' read -r target backup < "$txn/prefix.tsv" || {
        prefix_warn "!! The saved Wine prefix cleanup data could not be read."
        return 1
    }
    if [ "$backup" != absent ] && [ -e "$backup" ]; then
        safe="$(ableton_path_is_safe_delete_target "$backup")" || { prefix_warn "!! The saved previous Wine prefix path is unsafe: $backup"; return 1; }
        [ ! -L "$safe" ] || { prefix_warn "!! Cleanup stopped because the saved previous Wine prefix is a link: $safe"; return 1; }
        ableton_prefix_marker_valid "$safe" "$target" || {
            prefix_warn "!! Cleanup stopped because the saved previous Wine prefix is not recognized: $safe"
            return 1
        }
        prefix_commit_started=1
        rm -rf -- "$safe" || return 1
        [ ! -e "$safe" ] && [ ! -L "$safe" ] || return 1
    fi
    prefix_commit_started=1
    rm -f -- "$txn/prefix.tsv" || return 1
    if [ -d "$txn/prefix-host" ] && [ ! -L "$txn/prefix-host" ]; then
        rm -f -- "$txn/prefix-host/active" || return 1
    fi
}

if [ "$operation" != setup ]; then
    ableton_install_lock_acquire
fi
case "$operation" in
    preflight-rollback) prefix_transaction_preflight "$transaction_dir"; exit ;;
    preflight-commit) prefix_transaction_commit_preflight "$transaction_dir"; exit ;;
    rollback) prefix_transaction_rollback "$transaction_dir"; exit ;;
    commit) prefix_transaction_commit "$transaction_dir"; exit ;;
esac

case "${ABLETON_THEME_MODE:-auto}" in auto|dark|light|preserve) ;;
    *) prefix_warn "!! ABLETON_THEME_MODE must be auto, dark, light, or preserve"; exit 2 ;;
esac

if [ "$validate_only" -eq 1 ]; then
    . "$here/detect-scale.sh"
    validate_dpi="${ABLETON_DPI_MODE:-auto}"
    case "$validate_dpi" in
        auto|preserve|100|fractional) ;;
        dpi*|fractional*) ableton_dpi_block_values "$validate_dpi" >/dev/null || {
            prefix_warn "!! Invalid ABLETON_DPI_MODE '$validate_dpi'"; exit 2; } ;;
        *) prefix_warn "!! ABLETON_DPI_MODE must be auto, preserve, 100, fractional, dpi<N>, or fractional<N>"; exit 2 ;;
    esac
    if [ "${ABLETON_RUNTIME_PENDING:-0}" != 1 ]; then
        [ -x "$WINE_ROOT/bin/wine" ] || { prefix_warn "!! Patched Wine was not found at $WINE_ROOT"; exit 1; }
    fi
    if [ "$refresh" -eq 1 ]; then
        [ -f "$WINEPREFIX/system.reg" ] || { prefix_warn "!! --refresh needs an existing Wine prefix at $WINEPREFIX"; exit 2; }
    fi
    prefix_note "-- Wine prefix settings are valid"
    exit 0
fi

ableton_install_lock_acquire

# --post-first-run: Max for Live 8 (ships with Live 11) crashes on its SECOND start
# with a stale preferences file. Move it aside: never delete: so Max regenerates
# it; idempotent, and a missing file only means Max has not run yet. Needs no wine,
# so it runs before the runtime checks above matter.
if [ "$post_first_run" -eq 1 ]; then
    ableton_install_lock_acquire
    safe_repair_prefix="$(ableton_path_is_safe_delete_target "$WINEPREFIX")" || {
        prefix_warn "!! The Wine prefix path is unsafe: $WINEPREFIX"; exit 2; }
    if ! { [ "$safe_repair_prefix" = "$WINEPREFIX" ] && [ ! -L "$WINEPREFIX" ] \
           && ableton_prefix_marker_valid "$WINEPREFIX" "$WINEPREFIX"; }; then
        prefix_warn "!! Live 11 repair stopped because this Wine prefix was not created by Ableton Linux."
        exit 2
    fi
    . "$here/lib/lifecycle.sh"
    if ableton_prefix_busy; then
        prefix_warn "!! Close Live, Max, and other Wine programs before running the Live 11 repair."
        exit 1
    fi
    [ -f "$WINEPREFIX/system.reg" ] || { prefix_warn "!! No Wine prefix was found at $WINEPREFIX for Live 11 repair."; exit 2; }
    moved=0
    move_failed=0
    for maxpref in "$WINEPREFIX"/drive_c/users/*/"AppData/Roaming/Cycling '74/Max 8/Settings/maxpreferences.maxpref"; do
        [ -f "$maxpref" ] || continue
        bak="$maxpref.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        [ -e "$bak" ] && bak="$bak.$$"      # same-second re-run: keep both backups
        if mv -- "$maxpref" "$bak"; then
            moved=$((moved + 1))
        else
            printf '!! Max preferences could not be moved aside at %s. Check the file permissions and try again.\n' \
                "$maxpref" >&2 2>/dev/null || true
            move_failed=1
        fi
    done
    if [ "$move_failed" -eq 1 ]; then
        printf '!! Live 11 repair did not finish for every user. Files already moved aside were kept safely.\n' >&2 2>/dev/null || true
        exit 1
    elif [ "$moved" -gt 0 ]; then
        printf 'OK: Max preferences moved aside; Max regenerates them on next start\n' 2>/dev/null || true
    else
        printf 'OK: No Live 11 Max preferences needed repair.\n' 2>/dev/null || true
    fi
    exit 0
fi

[ -x "$WINE_ROOT/bin/wine" ] || {
    prefix_warn "!! Patched Wine was not found at $WINE_ROOT. Install the Wine runtime first."
    exit 1
}
for required in \
    bin/pipewire-version-probe \
    ABLETON-WINE-BUILD-INFO.txt \
    lib/wine/x86_64-unix/comdlg32.so \
    lib/wine/x86_64-windows/libusb-1.0.dll \
    lib/wine/x86_64-unix/libusb-1.0.so \
    lib/wine/x86_64-windows/pipeasio64.dll \
    lib/wine/x86_64-windows/pipeasio.dll \
    lib/wine/x86_64-unix/pipeasio64.dll.so \
    lib/wine/x86_64-unix/pipeasio.dll.so; do
    [ -s "$WINE_ROOT/$required" ] || { prefix_warn "!! The Wine runtime is incomplete: $required is missing."; exit 1; }
done
ableton_pipeasio_validate_runtime "$WINE_ROOT"
ableton_pipewire_preflight "$WINE_ROOT/bin/pipewire-version-probe" "configuring PipeASIO"

# Prefix changes are made against a sibling staging copy, then promoted in one
# rename.  Existing prefixes use reflink cloning where the filesystem supports
# it and a full copy otherwise.  The outer installer keeps the transaction open
# through Live installation, so any later failure can restore the old prefix.
. "$here/lib/lifecycle.sh"
if ableton_prefix_busy; then
    prefix_warn "!! Close Live, Max, and other Wine programs before updating the Wine prefix."
    exit 1
fi
final_prefix="$WINEPREFIX"
final_parent="$(dirname "$final_prefix")"
final_name="$(basename "$final_prefix")"
safe_final="$(ableton_path_is_safe_delete_target "$final_prefix")" || {
    prefix_warn "!! The Wine prefix path is unsafe: $final_prefix"; exit 2; }
[ ! -L "$final_prefix" ] || { prefix_warn "!! The Wine prefix path must not be a link: $final_prefix"; exit 2; }
if [ -e "$final_prefix" ] && ! ableton_prefix_marker_valid "$final_prefix" "$safe_final"; then
    if ableton_legacy_default_prefix_valid "$final_prefix"; then
        # Adopt it here, before any transaction opens. The run below moves this
        # prefix aside as its rollback backup, and the commit checks that backup
        # for the same ownership marker, so a prefix adopted any later than this
        # leaves a backup that can never satisfy it: the promotion succeeds and
        # the commit then fails with the backup unrecognised.
        adopt_marker="$final_prefix/.ableton-linux-prefix"
        [ ! -L "$adopt_marker" ] && [ ! -e "$adopt_marker" ] || {
            prefix_warn "!! The existing Wine prefix was left unchanged because its Ableton Linux setup record is not a regular file: $adopt_marker"
            exit 2
        }
        adopt_tmp="$(mktemp "$final_prefix/.prefix-marker.XXXXXX")" || {
            prefix_warn "!! The existing Wine prefix is not writable: $final_prefix"; exit 2; }
        if ! printf 'format=1\nprefix=%s\n' "$safe_final" > "$adopt_tmp" \
           || ! chmod 600 "$adopt_tmp" \
           || ! mv -T -f -- "$adopt_tmp" "$adopt_marker" \
           || ! ableton_prefix_marker_valid "$final_prefix" "$safe_final"; then
            # The marker too, not just the staging file: once one exists,
            # ableton_legacy_default_prefix_valid stops recognising the prefix,
            # so a half-written one would refuse every later run as well.
            rm -f -- "$adopt_tmp" "$adopt_marker"
            prefix_warn "!! The existing Wine prefix could not be prepared safely: $final_prefix"
            exit 2
        fi
        report_existing_prefix "$final_prefix"
    else
        prefix_warn "!! This Wine prefix was left unchanged because the installer could not confirm that it created it: $final_prefix"
        prefix_warn "!! Choose a different prefix, or move this one aside and run setup again."
        exit 2
    fi
fi
mkdir -p -- "$final_parent"
own_prefix_transaction=0
if [ -z "$transaction_dir" ]; then
    ableton_prepare_transactions_dir
    transaction_dir="$(mktemp -d "$ABLETON_STATE_HOME/transactions/prefix.XXXXXX")"
    own_prefix_transaction=1
else
    mkdir -p -- "$transaction_dir"
fi
unset ABLETON_TRANSACTION_DIR
stage_prefix=""
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_prefix_transaction()
{
    local rc=$? restore_ok=1
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
        prefix_transaction_rollback "$transaction_dir" || restore_ok=0
    fi
    if [ "$rc" -ne 0 ] && [ "$own_prefix_transaction" -eq 1 ] \
       && [ "$restore_ok" -eq 1 ]; then
        rm -rf -- "$transaction_dir" || restore_ok=0
    fi
    if [ "$restore_ok" -ne 1 ]; then
        prefix_warn "!! Wine prefix setup failed, and recovery did not finish. Keep the files at $transaction_dir and report the problem."
    fi
    exit "$rc"
}
trap cleanup_unstarted_prefix_transaction EXIT
if [ -e "$final_prefix" ]; then
    ableton_adopt_prefix_marker "$final_prefix" "$safe_final" || {
        prefix_warn "!! This Wine prefix was left unchanged because it was not created by Ableton Linux: $final_prefix"
        exit 2
    }
fi
stage_prefix="$(mktemp -d "$final_parent/.${final_name}.prefix-stage.XXXXXX")"
prefix_promoted=0
prefix_core_ready=0
prefix_cleanup()
{
    local rc=$? restore_error="" restoration_complete=yes
    trap - EXIT
    # This handler decides the result from the prefix/recovery state below.
    # A closed terminal or log consumer must not interrupt that decision.
    set +e
    if [ "$rc" -ne 0 ]; then
        if [ "$prefix_core_ready" -eq 1 ]; then
            echo "!! The Wine prefix is ready, but old recovery files may remain at $transaction_dir." >&2 || true
            rc=0
        elif [ "$prefix_commit_started" -eq 1 ]; then
            printf 'status=committed-cleanup-incomplete\nprefix=%s\nexit=%s\n' \
                "$final_prefix" "$rc" > "$transaction_dir/COMMITTED_CLEANUP_FAILURE" 2>/dev/null || true
            echo "!! The Wine prefix is ready, but old recovery files remain at $transaction_dir." >&2 || true
            rc=0
        elif [ "$prefix_promoted" -eq 1 ]; then
            if ! prefix_transaction_rollback "$transaction_dir"; then
                restore_error="prefix rollback failed"
            fi
        else
            if [ -d "$stage_prefix" ] && ! rm -rf -- "$stage_prefix"; then
                restore_error="staged prefix cleanup failed"
            fi
            if ! prefix_transaction_rollback "$transaction_dir"; then
                restore_error="${restore_error}${restore_error:+; }Wine prefix recovery failed"
            fi
        fi
        if [ "$rc" -ne 0 ] && [ "$prefix_commit_started" -ne 1 ]; then
            [ -z "$restore_error" ] || restoration_complete=no
            printf 'status=failed\nprefix=%s\nexit=%s\nrestoration_complete=%s\nrestoration_error=%s\n' \
                "$final_prefix" "$rc" "$restoration_complete" "$restore_error" \
                > "$transaction_dir/prefix-failure" || true
            if [ "$restoration_complete" = yes ]; then
                echo "!! Wine prefix setup failed. The previous prefix is back in place." >&2 || true
            else
                echo "!! Wine prefix setup failed, and the previous prefix could not be fully restored: $restore_error" >&2 || true
                echo "!! Keep the recovery files at $transaction_dir and report the problem." >&2 || true
            fi
        fi
    fi
    exit "$rc"
}
trap prefix_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -f "$final_prefix/system.reg" ]; then
    prefix_note "== Preparing the existing Wine prefix =="
    cp -a --reflink=auto -- "$final_prefix/." "$stage_prefix/"
fi
export WINEPREFIX="$stage_prefix"

wine_command_timeout="$(ableton_timeout_value "${ABLETON_WINE_COMMAND_TIMEOUT:-300}" ABLETON_WINE_COMMAND_TIMEOUT 10 3600)"
winetricks_timeout="$(ableton_timeout_value "${ABLETON_WINETRICKS_TIMEOUT:-1800}" ABLETON_WINETRICKS_TIMEOUT 60 7200)"
wine()
{
    ableton_run_bounded "$wine_command_timeout" "$WINE_ROOT/bin/wine" "$@"
}
wineboot()
{
    ableton_run_bounded "$wine_command_timeout" "$WINE_ROOT/bin/wineboot" "$@"
}
# WINEPREFIX moves from the staging path to the final one partway through, so
# both helpers name the prefix in force rather than the configured one.
ableton_wineserver_wait()
{
    ableton_prefix_wait "$WINE_ROOT" "$WINEPREFIX"
}
ableton_wineserver_quiesce()
{
    ableton_prefix_quiesce "$WINE_ROOT" "$WINEPREFIX"
}

# DPI blocks: a detected scale maps to a calibrated set by compositor family (see
# detect-scale.sh): GNOME gets the upscaled-framebuffer matched set (LogPixels =
# 96 x ceil(scale) + IFEO dpiAwareness=2), other compositors get plain
# LogPixels = round(96 x scale) with no IFEO. auto applies the detected block on a
# fresh prefix, falls back to 100% when detection is unusable, and preserves an
# existing prefix's settings.
# The dpiAwareness IFEO is keyed on the exe name, so it is applied per installed Live (any edition);
# on a fresh prefix Live isn't installed yet: the launcher applies it on every start.
ifeo_root='HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
live_exe_names() {   # basenames of every Live exe installed in this prefix
    local f
    for f in "$WINEPREFIX"/drive_c/ProgramData/Ableton/*/Program/"Ableton Live"*.exe; do
        [ -f "$f" ] && basename "$f"
    done
}

# Shared display-scale detection and scale -> DPI block mapping (see detect-scale.sh).
. "$here/detect-scale.sh"

# Shared host light/dark-scheme detection (see detect-theme.sh).
. "$here/detect-theme.sh"

block_for_scale() {  # scale family -> calibrated block token, fails outside 100-250%
    ableton_dpi_block_for_scale "$1" "${2:-}"
}

current_dpi_block() {  # what an EXISTING prefix holds: 100 | fractional | dpi<N> | fractional<N> | custom
    local lp n ifeo=absent name installs=0
    lp="$(wine reg query 'HKCU\Control Panel\Desktop' /v LogPixels 2>/dev/null \
          | awk '$1=="LogPixels"{gsub(/\r/,"",$3); print tolower($3)}')"   # reg output is CRLF
    [ -n "$lp" ] || lp=0x60          # wineboot default is 96
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        installs=1
        if wine reg query "$ifeo_root\\$name" /v dpiAwareness >/dev/null 2>&1; then
            ifeo=present
        fi
    done < <(live_exe_names)
    n=$((lp)) 2>/dev/null || n=0
    if [ "$ifeo" = present ]; then
        # an IFEO set is only calibrated as half of the matched set (96 x k framebuffer)
        if [ $((n % 96)) -eq 0 ] && [ "$n" -ge 192 ]; then
            if [ "$n" -eq 192 ]; then echo fractional; else echo "fractional$n"; fi
        else
            echo custom
        fi
    elif [ "$n" -eq 96 ]; then
        echo 100
    elif [ "$n" -eq 192 ] && [ "$installs" -eq 0 ]; then
        echo fractional    # no Live installed yet: LogPixels alone decides; the launcher adds the IFEO
    elif [ "$n" -gt 96 ] && [ "$n" -le 240 ]; then
        echo "dpi$n"
    else
        echo custom
    fi
}

check_mutter_knob() {  # warn when mutter's xwayland-native-scaling disagrees with the block
    local feats
    # The knob only exists under mutter; off-GNOME (a known non-gnome family) it is irrelevant.
    [ -z "${2:-}" ] || [ "$2" = gnome ] || return 0
    command -v gsettings >/dev/null 2>&1 || return 0
    feats="$(gsettings get org.gnome.mutter experimental-features 2>/dev/null)" || return 0
    case "$1" in
        fractional*)   # upscaled-framebuffer sets need the knob
            if [[ "$feats" != *xwayland-native-scaling* ]]; then
                prefix_warn "!! GNOME's xwayland-native-scaling setting is off, but the selected display scaling needs it."
                prefix_warn "!! Add xwayland-native-scaling to org.gnome.mutter experimental-features."
            fi ;;
        *)
            if [[ "$feats" = *xwayland-native-scaling* ]]; then
                prefix_warn "!! GNOME's xwayland-native-scaling setting is on, but the selected display scaling does not use it."
                prefix_warn "!! Remove xwayland-native-scaling from org.gnome.mutter experimental-features."
            fi ;;
    esac
    return 0
}

gnome_native_scaling_active()
{
    local feats
    command -v gsettings >/dev/null 2>&1 || return 1
    feats="$(gsettings get org.gnome.mutter experimental-features 2>/dev/null)" || return 1
    [[ "$feats" = *xwayland-native-scaling* ]]
}

# 2026.07.18.1 seeded -DontCombineAPCs into Options.txt to cut a 30-40% idle CPU
# thread. Under playback the uncoalesced APCs flood the wineserver and starve the
# PipeASIO callback: choppy, slowed-down audio (issue #29). Strip the line from
# every prefs copy: including hand-added ones, since the old changelog entry
# advertised it. The idle CPU cost is back until the Wine-side fix lands.
strip_options_txt() {
    local line="$1" prefs f tmp
    shopt -s nullglob
    for prefs in "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/Ableton/Live*/Preferences; do
        f="$prefs/Options.txt"
        [ -f "$f" ] || continue
        # Match with CR stripped so a CRLF-edited copy is caught too.  This is a
        # repair, not a prefix-integrity condition: an unreadable preferences
        # file is left alone and reported without discarding the prepared prefix.
        awk -v opt="$line" \
            '{ l = $0; sub(/\r$/, "", l); if (l == opt) found=1 } END { exit !found }' \
            "$f" 2>/dev/null || continue
        if ! tmp="$(mktemp)" \
           || ! awk -v opt="$line" '{ l = $0; sub(/\r$/, "", l) } l != opt { print }' \
                "$f" > "$tmp"; then
            [ -z "${tmp:-}" ] || rm -f -- "$tmp" 2>/dev/null || true
            prefix_warn "!! Could not update $f. Remove $line from that file before using Live."
            continue
        fi
        if [ -s "$tmp" ]; then
            # Write through the existing inode: keeps the file's permissions.
            if cat "$tmp" > "$f"; then
                prefix_note "   Removed $line from $f"
            else
                prefix_warn "!! Could not update $f. Remove $line from that file before using Live."
            fi
            rm -f -- "$tmp" 2>/dev/null || true
        else
            # The seed's touch created the file; nothing else in it: undo fully.
            rm -f -- "$tmp" 2>/dev/null || true
            if rm -f -- "$f"; then
                prefix_note "   Removed $f because it contained only $line"
            else
                prefix_warn "!! Could not remove $line from $f. Remove that file before using Live."
            fi
        fi
    done
    shopt -u nullglob
}

fresh_prefix=0
[ -f "$WINEPREFIX/system.reg" ] || fresh_prefix=1
if [ "$refresh" -eq 1 ] && [ "$fresh_prefix" -eq 1 ]; then
    prefix_warn "!! --refresh needs an existing Wine prefix at $WINEPREFIX. Run without --refresh to create one."
    exit 2
fi

# Resolve display scaling before Wine setup starts. Automatic detection is only
# a convenience; a fresh prefix falls back to a safe 100% when it is unavailable.
dpi_mode="${ABLETON_DPI_MODE:-auto}"
dpi_block=preserve
dpi_family=""
case "$dpi_mode" in
  100|fractional)
    dpi_block="$dpi_mode"
    ;;
  dpi[0-9]*|fractional[0-9]*)
    if ableton_dpi_block_values "$dpi_mode" >/dev/null; then
        dpi_block="$dpi_mode"
    else
        prefix_warn "!! ABLETON_DPI_MODE '$dpi_mode' is invalid. Use dpi<N> or fractional<N>, with N from 72 to 384."
        exit 2
    fi
    ;;
  preserve)
    ;;
  auto)
    if detected="$(ableton_detect_scale_ex)"; then
        scale="${detected% *}"
        dpi_family="${detected#* }"
        if block="$(block_for_scale "$scale" "$dpi_family")"; then
            if [ "$fresh_prefix" -eq 1 ]; then
                if [ "$dpi_family" = gnome ] && [[ "$block" = fractional* ]] \
                   && ! gnome_native_scaling_active; then
                    prefix_warn "!! GNOME native Xwayland scaling could not be confirmed; using 100% scaling for this fresh prefix."
                    prefix_warn "!! Set ABLETON_DPI_MODE=$block explicitly only after enabling xwayland-native-scaling."
                    dpi_block=100
                else
                    prefix_note "   Detected display scale $scale ($dpi_family); applying $block scaling settings."
                    dpi_block="$block"
                fi
            else
                have="$(current_dpi_block)"
                if [ "$have" = "$block" ]; then
                    prefix_note "   Display scaling is already configured for scale $scale."
                else
                    prefix_warn "!! Display scale $scale differs from this Wine prefix's current settings ($have)."
                    prefix_warn "!! Existing settings were kept. To change them, rerun with ABLETON_DPI_MODE=$block."
                fi
            fi
        elif [ "$fresh_prefix" -eq 1 ]; then
            dpi_block=100
            prefix_warn "!! Display scale $scale is outside the supported automatic range. Using 100% scaling."
        else
            prefix_warn "!! Display scale $scale is outside the supported automatic range. Existing settings were kept."
        fi
    elif [ "$fresh_prefix" -eq 1 ]; then
        dpi_block=100
        prefix_warn "!! Display scale could not be detected. Using 100% scaling."
    else
        prefix_note "   Display scale could not be detected; existing settings were kept."
    fi
    ;;
  *)
    prefix_warn "!! ABLETON_DPI_MODE must be auto, preserve, 100, fractional, or dpi<N>"
    exit 2
    ;;
esac

# Ableton Live auto-install candidate and the Live major
# the winetricks/redist recipes target: resolved together, up front, so an
# opted-in auto-install can never put a Live 11 zip into a prefix prepared with
# the Live 12 recipe. Major precedence: ABLETON_LIVE_VERSION pin > the major
# parsed from the chosen zip > 12.
live_installed() { ls "$WINEPREFIX"/drive_c/ProgramData/Ableton/*/Program/"Ableton Live"*.exe >/dev/null 2>&1; }
installer_dir="${ABLETON_INSTALLER_DIR:-$HOME/Proprietary}"
# Newest by the version in the name, not by the name. Ableton's downloads are
# ableton_live_<edition>_<major>.<minor>.<patch>_64.zip, so the edition sorts
# before the version ever does: a plain sort -V ranks a "trial" 11 above a
# "suite" 12, and 12.4.3 above 12.10.0. Sort on a key cut from the basename
# instead; a name carrying no version keys to 0 and can only be chosen when it
# is the only candidate.
# An unreadable directory makes find exit 1, which pipefail propagates and
# set -e would turn into a silent abort of the whole prefix setup; no candidate
# is the same answer either way.
newest_live_zip() {   # <dir> <case-insensitive glob>
    find "$1" -maxdepth 1 -type f -iname "$2" -print 2>/dev/null \
        | awk '{ n = $0; sub(/.*\//, "", n)
                 print (match(n, /[0-9]+(\.[0-9]+)+/) ? substr(n, RSTART, RLENGTH) : "0") "\t" $0 }' \
        | sort -V | tail -n 1 | cut -f2- || true
}
live_zip=""
# The .run installs Ableton Live itself, from the payload given to it, and marks
# the prefix run it owns with ABLETON_PREFIX_MANAGED=1. Neither the search below
# nor the standalone Live installer runs there: two installers writing one prefix is not a
# supported combination, and the .run's own report is the one the user follows.
if [ "${ABLETON_PREFIX_MANAGED:-0}" != 1 ] && [ -d "$installer_dir" ]; then
    if [ -n "${ABLETON_LIVE_VERSION:-}" ]; then
        # An explicit major pin only accepts a matching installer: never
        # silently install another major into a prefix prepared for this one.
        live_zip="$(newest_live_zip "$installer_dir" "ableton_live*_${ABLETON_LIVE_VERSION}.*.zip")"
    else
        live_zip="$(newest_live_zip "$installer_dir" 'ableton_live*.zip')"
    fi
fi
live_major="${ABLETON_LIVE_VERSION:-12}"
if [ "${ABLETON_PREFIX_MANAGED:-0}" != 1 ] && [ -z "${ABLETON_LIVE_VERSION:-}" ] \
    && [ "${ABLETON_LIVE_AUTOINSTALL:-0}" = 1 ] \
    && [ -n "$live_zip" ] && ! live_installed; then
    # ableton_live_<edition>_<major>.<minor>.<patch>_64.zip; sed -n exits 0
    # whether or not it matches, so set -e and pipefail are not tripped.
    zip_major="$(basename "$live_zip" | sed -nE 's/^[^0-9]*_([0-9]+)\.[0-9]+.*$/\1/p')"
    case "$zip_major" in
        11|12)
            live_major="$zip_major"
            if [ "$live_major" != 12 ]; then
                prefix_note ":: $(basename "$live_zip") is Live $live_major; preparing its required Windows support files."
            fi
            ;;
        "")
            prefix_warn "!! Could not read the Live version from $(basename "$live_zip"); preparing for Live 12. Set ABLETON_LIVE_VERSION if that is wrong."
            ;;
        *)
            prefix_warn "!! $(basename "$live_zip") looks like Live $zip_major, but setup supports Live 11 or 12. Set ABLETON_LIVE_VERSION or remove that zip."
            exit 2
            ;;
    esac
fi

prefix_note "== Preparing Wine at $WINEPREFIX =="
# While updating the prefix, wineboot offers Wine's Mono and Gecko installers. This runtime
# vendors neither, so on a machine with no cached package it opens a modal "Wine Mono
# Installer" prompt; nothing answers it in an unattended run and the wineserver -w below then
# never returns. Live needs neither - ableton-live and max9 already disable both on every
# launch - so disable them here and wineboot stops asking.
WINEDLLOVERRIDES="${caller_winedlloverrides:+$caller_winedlloverrides;}mscoree,mshtml=" wineboot -u
# A prefix that got Ableton's USB audio driver carries the driver's tray agent, and
# wineboot's startup pass relaunches it on every boot. The agent never exits by itself and
# does not always have a window: Live 11's driver MSI (v5.57 File table) installs
# AbletonPushCpl.exe under Ableton\Push Driver with a Startup shortcut; a field capture of
# a hung update shows Live 12's agent as ABLE~OCJ.EXE -hide under Ableton\USB Audio Driver,
# an Ableton*.exe started through its 8.3 path whose long name is not yet confirmed (issue
# #111). Stop the known images, then delete the autostart entries so later boots come up
# clean. wineboot runs the HKLM Run key (64-bit and Wow6432Node views), the HKCU Run key,
# and the Startup folders, so the scrub covers exactly those. Entries are matched by what
# they point at - an Ableton\USB or Ableton\Push path, long or 8.3 form - not by image
# name, because the names vary by driver generation.
for tray_image in AbletonPushCpl.exe tusbaudiocplapp.exe; do
    wine taskkill /f /im "$tray_image" >/dev/null 2>&1 || true
done
for run_key in 'HKLM\Software\Microsoft\Windows\CurrentVersion\Run' \
               'HKLM\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run' \
               'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; do
    (wine reg query "$run_key" 2>/dev/null || true) | \
        sed -n 's/^    \(.*\)    REG_[A-Z_]*    .*\(ableton\\usb\|ableton\\push\|tusbaudio\).*/\1/Ip' | \
        while IFS= read -r run_value; do
            wine reg delete "$run_key" /v "$run_value" /f >/dev/null 2>&1 || true
        done
done
for startup_root in "$WINEPREFIX/drive_c/users" "$WINEPREFIX/drive_c/ProgramData"; do
    [ -d "$startup_root" ] || continue
    find "$startup_root" -ipath '*Start Menu/Programs/Startup/*' \
        \( -iname '*ableton*' -o -iname '*push*' -o -iname '*tusbaudio*' \) -delete 2>/dev/null || true
done
# Any resident wineboot started parks this barrier forever: the agent under a name the
# taskkill missed, or WebView2's MicrosoftEdgeUpdate.exe, whose scheduled task fires about
# two minutes after a boot and has no window (the --update half of issue #111 is exactly
# this wait). The boot's registry writes are persisted when the server exits, so a
# straggler that survives the stop does not block the setup that follows.
boot_wait_rc=0
ableton_wineserver_quiesce || boot_wait_rc=$?
# 3 is a straggler that outlived the stop, which the setup below tolerates.  A wait
# that failed for any other reason - an unreadable prefix, a wineserver that would
# not run - means the boot did not complete, and the winetricks step must not run
# against a prefix in that state.
[ "$boot_wait_rc" -eq 0 ] || [ "$boot_wait_rc" -eq 3 ] || exit "$boot_wait_rc"

if [ "$refresh" -eq 1 ]; then
    prefix_note "== Keeping the installed Windows fonts and support files =="
else
    command -v cabextract >/dev/null || {
        prefix_warn "!! cabextract is needed to unpack the Windows support files. Install it and run setup again."
        exit 1
    }
    # Verb set per Live major: Live 12 needs vcrun2022 + mfc42; Live 11 needs
    # vcrun2019 + gdiplus (the Ableton forum Live-on-Linux guide). vcrun2019/gdiplus
    # payloads are not vendored yet: Live 11 setup downloads them on first run.
    case "$live_major" in
        11) verbs=(corefonts vcrun2019 gdiplus) ;;
        12) verbs=(corefonts vcrun2022 mfc42) ;;
        *)  prefix_warn "!! Live $live_major is not supported by this setup."; exit 2 ;;
    esac
    prefix_note "== Installing Windows fonts and support files for Live $live_major =="
    kit_root_or_die
    export W_CACHE_OVERRIDE=""            # unused
    export WINETRICKS_LATEST_VERSION_CHECK=disabled
    # Never set WINETRICKS_SUPER_QUIET: it silences w_die, so a fatal
    # winetricks error exits with no message at all (issue #28).
    # Use the bundled payload cache if present (mfc42 downloads if not vendored).
    tmpc=""
    original_xdg_cache_set=0
    original_xdg_cache=""
    if [ -n "${XDG_CACHE_HOME+x}" ]; then
        original_xdg_cache_set=1
        original_xdg_cache="$XDG_CACHE_HOME"
    fi
    if [ -d "$root/vendor/winetricks-cache" ]; then
        # Per-verb symlinks, not one dir link: the vendored cache may be
        # read-only (nix store), and verbs missing from it must still be able
        # to download into the writable parent. Failure to build this temporary
        # view falls back to normal winetricks downloads.
        tmpc=""
        if tmpc="$(mktemp -d)" \
           && mkdir "$tmpc/winetricks" \
           && ( shopt -s nullglob
                for cached in "$root/vendor/winetricks-cache"/*; do
                    ln -s "$cached" "$tmpc/winetricks/" || exit 1
                done ); then
            export XDG_CACHE_HOME="$tmpc"
            prefix_note "   Using the bundled dependency cache."
        else
            [ -z "$tmpc" ] || rm -rf -- "$tmpc" 2>/dev/null || true
            tmpc=""
            prefix_warn "!! The bundled dependency cache could not be prepared. Setup will download the required files instead."
        fi
    fi
    # WINE64 preset: this is a new-style WoW64 tree (single wine binary, no
    # wine64). winetricks' arch autodetection reads the ELF header of $WINE,
    # which fails when bin/wine is a wrapper script (nix) - preset both.
    ableton_run_bounded "$winetricks_timeout" env WINE="$WINE_ROOT/bin/wine" WINE64="$WINE_ROOT/bin/wine" \
        bash "$root/vendor/winetricks" -q -f "${verbs[@]}"
    if [ "$live_major" = 11 ]; then
        # Live 11 targets Windows 10 explicitly. Live 12 stays unpinned: nothing in
        # this script ever sets a Windows version, and a fresh wineboot prefix
        # already defaults to win10 (winetricks assumes the same), so the Live 12
        # recipe keeps its historical effective mode.
        ableton_run_bounded "$winetricks_timeout" env WINE="$WINE_ROOT/bin/wine" WINE64="$WINE_ROOT/bin/wine" \
            bash "$root/vendor/winetricks" -q win10
    fi
    if [ -n "$tmpc" ]; then
        rm -rf -- "$tmpc" 2>/dev/null || true
        if [ "$original_xdg_cache_set" -eq 1 ]; then
            export XDG_CACHE_HOME="$original_xdg_cache"
        else
            unset XDG_CACHE_HOME
        fi
    fi
    ableton_wineserver_wait
fi

# Repair Max for Live's font fallback chain.
#
# M4L devices are authored on macOS and name faces absent here (Geneva, Menlo,
# Lucida Grande, Helvetica Neue, Consolas). Windows' font mapper substitutes
# silently; Wine reports the failure honestly, so MaxPlug walks its own chain,
# which terminates at Bitstream Vera - shipped by neither Wine nor Live, and
# superseded on modern distros by DejaVu. The chain runs out and MaxPlug parks
# Live's UI thread on a condition variable that is never signalled: window
# frozen at zero CPU, audio still playing.
#
# Both halves below are needed. A FontSubstitutes alias only redirects
# CreateFontIndirect and never enters EnumFontFamilies, which is what Max
# matches against; and copied-in files stay invisible until registered, Wine's
# font list being registry-driven. Idempotent, and runs under --refresh too.
install_maxplug_fallback_fonts() {
    local winfonts="$WINEPREFIX/drive_c/windows/Fonts"
    local src="" d n entry missing=0
    # face name -> filename. Upstream Vera names are fixed, so no runtime probing.
    local faces=(
        "Bitstream Vera Sans:Vera.ttf"
        "Bitstream Vera Sans Bold:VeraBd.ttf"
        "Bitstream Vera Sans Oblique:VeraIt.ttf"
        "Bitstream Vera Sans Bold Oblique:VeraBI.ttf"
        "Bitstream Vera Sans Mono:VeraMono.ttf"
        "Bitstream Vera Sans Mono Bold:VeraMoBd.ttf"
        "Bitstream Vera Sans Mono Oblique:VeraMoIt.ttf"
        "Bitstream Vera Sans Mono Bold Oblique:VeraMoBI.ttf"
        "Bitstream Vera Serif:VeraSe.ttf"
        "Bitstream Vera Serif Bold:VeraSeBd.ttf"
    )

    # Prefer the vendored copy so no host font package is needed; fall back to a
    # system install if the kit was trimmed. kit_root sets $root as a side
    # effect, so it is called as a statement rather than substituted.
    if kit_root && [ -f "$root/vendor/fonts/bitstream-vera/Vera.ttf" ]; then
        src="$root/vendor/fonts/bitstream-vera"
    else
        for d in /usr/share/fonts/truetype/ttf-bitstream-vera \
                 /usr/share/fonts/bitstream-vera \
                 /usr/share/fonts/TTF; do
            [ -f "$d/Vera.ttf" ] && { src="$d"; break; }
        done
    fi

    if [ -z "$src" ]; then
        prefix_warn "!! Bitstream Vera fonts were not found. Some Max for Live devices may freeze Live when a typeface is missing."
        prefix_warn "!! Install ttf-bitstream-vera (Debian/Ubuntu or Arch) or bitstream-vera-fonts (Fedora), then rerun setup."
        return 0                      # non-fatal: everything else still works
    fi

    # Non-fatal throughout, deliberately: under `set -e` a failed step here
    # would abort the whole setup and leave the prefix half-configured, which is
    # worse than a working prefix plus a loud warning. check-m4l-fonts.sh
    # catches the not-installed state later.
    if ! mkdir -p "$winfonts"; then
        prefix_warn "!! Max for Live fallback fonts could not be installed at $winfonts."
        return 0
    fi

    local copied=0 registered=0
    for entry in "${faces[@]}"; do
        n="${entry##*:}"
        [ -f "$src/$n" ] || { missing=1; continue; }
        # -u to skip identical files on a refresh; not every cp has it.
        if cp -u "$src/$n" "$winfonts/$n" 2>/dev/null || cp "$src/$n" "$winfonts/$n"; then
            copied=$((copied + 1))
        else
            prefix_warn "!! Max for Live fallback font $n could not be copied to $winfonts."
        fi
    done
    if [ "$missing" -eq 1 ]; then
        prefix_warn "!! Some Bitstream Vera font files are missing; the available fonts will still be installed."
    fi

    # One import rather than ten `wine reg add` calls: each spawns a wine
    # process, and this runs on every setup and every --refresh. Backslashes are
    # doubled and lines are CRLF because that is what .reg format wants; the
    # values land byte-identical to what reg add wrote.
    local reg_file fonts_key='HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    reg_file="$(mktemp)" || { prefix_warn "!! Max for Live fallback fonts could not be registered."; return 0; }
    {
        printf 'REGEDIT4\r\n\r\n'
        printf '[%s]\r\n' "$fonts_key"
        for entry in "${faces[@]}"; do
            n="${entry##*:}"
            [ -f "$winfonts/$n" ] || continue
            printf '"%s (TrueType)"="%s"\r\n' "${entry%%:*}" \
                "C:\\\\windows\\\\Fonts\\\\$n"
            registered=$((registered + 1))
        done
        printf '\r\n'
    } > "$reg_file"

    if [ "$registered" -gt 0 ] && ! wine reg import "$reg_file" >/dev/null 2>&1; then
        registered=0                  # import failed: nothing landed
    fi
    rm -f -- "$reg_file" 2>/dev/null || true
    ableton_wineserver_wait || true

    if [ "$registered" -eq 0 ]; then
        prefix_warn "!! Copied $copied Max for Live fallback font files, but they could not be registered."
        prefix_warn "!! Close Live, rerun setup, then check with scripts/check-m4l-fonts.sh."
    elif [ "$registered" -lt "${#faces[@]}" ]; then
        prefix_warn "!! Only $registered of ${#faces[@]} Max for Live fallback fonts were registered. Check with scripts/check-m4l-fonts.sh."
    else
        prefix_note "   Max for Live fallback fonts are ready."
    fi
}
prefix_note "== Installing Max for Live fallback fonts =="
install_maxplug_fallback_fonts

# Live bundles the exact VC++ redistributable it was built against in its own
# Redist folder (<Live folder>/Redist, next to Program/): present only after
# Live's installer has run, so fresh prefixes never match here.
find_live_redist() {  # -> path of the VC++ redist installer bundled with an installed Live
    local d name
    for d in "$WINEPREFIX"/drive_c/ProgramData/Ableton/*/Redist; do
        [ -d "$d" ] || continue
        for name in vc_redist.exe VC_redist.x64.exe vc_redist.x64.exe vcredist.exe vcredist_x64.exe; do
            if [ -s "$d/$name" ] && [ ! -L "$d/$name" ]; then
                printf '%s\n' "$d/$name"
                return 0
            fi
        done
    done
    return 1
}

# Cheap probe for a working runtime: the four DLLs Live links against are present
# in system32 and none is one of wine's placeholder stubs (they carry the marker
# string). Needs no payload, unlike the byte-comparison gate below.
vc_runtime_ready() {
    local dll path
    for dll in vcruntime140.dll vcruntime140_1.dll msvcp140.dll msvcp140_1.dll; do
        path="$WINEPREFIX/drive_c/windows/system32/$dll"
        [ -s "$path" ] || return 1
        grep -aFq 'Wine placeholder DLL' "$path" && return 1
    done
    return 0
}

# vc_redist reports success as exit 0, 102 or 194 (reboot-required states are
# notional under Wine); the DLL probe above is the real verdict.
install_live_redist() {
    local status=0
    wine "$1" /install /quiet /norestart || status=$?
    ableton_wineserver_wait
    case "$status" in
        0|102|194) ;;
        *) prefix_warn "!! Live's Microsoft Visual C++ installer failed (exit $status)."; return 1 ;;
    esac
    vc_runtime_ready || { prefix_warn "!! Required Microsoft Visual C++ files are still missing after installation."; return 1; }
}

# wineboot -u replaces redist natives (msvcp140 etc.) with wine's higher-versioned stubs, which
# Live aborts on. Prefer the redist bundled in Live's own Redist folder; the vendored payload
# stays as the fallback and as the final gate (it also covers syswow64, which vc_redist.x64
# doesn't touch). The redist comes from the same source winetricks used: vcrun2022 (Live 12)
# or vcrun2019 (Live 11): both ship the vc_redist.x64/x86.exe pair with the same cab layout.
redist_verb=vcrun2022
[ "$live_major" = 11 ] && redist_verb=vcrun2019
prefix_note "== Checking Microsoft Visual C++ support =="
kit_root || true   # vendored cache is only a candidate; absence is not fatal here
if ! vc_runtime_ready; then
    live_redist="$(find_live_redist || true)"
    if [ -n "$live_redist" ]; then
        prefix_note "   Installing the Microsoft Visual C++ files included with Live."
        install_live_redist "$live_redist" || \
            prefix_warn "!! Trying the bundled Microsoft Visual C++ files instead."
    fi
fi
redist_dir=""
for d in "$root/vendor/winetricks-cache/$redist_verb" \
         "${XDG_CACHE_HOME:-$HOME/.cache}/winetricks/$redist_verb"; do
    [ -s "$d/vc_redist.x64.exe" ] && { redist_dir="$d"; break; }
done
if [ -z "$redist_dir" ]; then
    if vc_runtime_ready; then
        prefix_note "   Required Microsoft Visual C++ files are already installed."
    else
        prefix_warn "!! Required Microsoft Visual C++ files are missing, and their installer could not be found."
        exit 1
    fi
else
    command -v cabextract >/dev/null || {
        prefix_warn "!! cabextract is needed to unpack the Microsoft Visual C++ files. Install it and run setup again."
        exit 1
    }
    vc_tmp="$(mktemp -d)"
    for arch in x64 x86; do
        cabextract -q -d "$vc_tmp/$arch/burst" "$redist_dir/vc_redist.$arch.exe"
        for cab in "$vc_tmp/$arch/burst"/a*; do
            cabextract -q -d "$vc_tmp/$arch" "$cab" 2>/dev/null || true
        done
    done
    vc_bad=0
    for f in "$vc_tmp"/*/*.dll_amd64 "$vc_tmp"/*/*.dll_x86; do
        [ -e "$f" ] || continue
        case "$f" in
            *_amd64) name="$(basename "$f" _amd64)"; wdir=system32; barch=x86_64-windows ;;
            *)       name="$(basename "$f" _x86)";   wdir=syswow64; barch=i386-windows ;;
        esac
        dest="$WINEPREFIX/drive_c/windows/$wdir/$name"
        builtin="$WINE_ROOT/lib/wine/$barch/$name"
        if [ ! -s "$dest" ] || { [ -s "$builtin" ] && cmp -s "$dest" "$builtin"; }; then
            prefix_note "   Installing $name."
            install -m 644 "$f" "$dest"
        fi
        # gate: a file still identical to wine's builtin means the heal failed
        if [ -s "$builtin" ] && cmp -s "$dest" "$builtin"; then
            prefix_warn "!! Required Microsoft Visual C++ file $wdir/$name was not installed correctly."
            vc_bad=1
        fi
    done
    rm -rf -- "$vc_tmp" 2>/dev/null || true
    [ "$vc_bad" -eq 0 ] || { prefix_warn "!! Ableton's required Microsoft Visual C++ files could not be installed correctly."; exit 1; }
fi

prefix_note "== Configuring display scaling =="
case "$dpi_block" in
  preserve)
    prefix_note "   Existing display scaling settings were kept."
    # Still sanity-check the mutter knob against what the prefix holds.
    have="$(current_dpi_block)"
    if [ "$have" != custom ]; then
        check_mutter_knob "$have"
    fi
    ;;
  *)
    lp_ifeo="$(ableton_dpi_block_values "$dpi_block")"
    dpi_lp="${lp_ifeo% *}"
    dpi_ifeo="${lp_ifeo#* }"
    wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi_lp" /f
    ifeo_set=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        ifeo_set=1
        if [ "$dpi_ifeo" = 2 ]; then
            wine reg add "$ifeo_root\\$name" /v dpiAwareness /t REG_DWORD /d 2 /f
        else
            wine reg delete "$ifeo_root\\$name" /v dpiAwareness /f >/dev/null 2>&1 || true  # reg.exe errors land on stdout
        fi
    done < <(live_exe_names)
    if [ "$ifeo_set" -eq 0 ] && [ "$dpi_ifeo" = 2 ]; then
        prefix_note "   Live-specific scaling will be applied automatically when Live first starts."
    fi
    check_mutter_knob "$dpi_block" "$dpi_family"
    ;;
esac
ableton_wineserver_wait

prefix_note "== Configuring the desktop theme =="
# Live's "Follow system" theme reads AppsUseLightTheme; without the key it always renders
# light. Seed it from the host scheme (the launcher re-syncs on every start), plus the
# EnableTransparency=0 the known-good prefixes carry.
theme_mode="${ABLETON_THEME_MODE:-auto}"
if [ "$theme_mode" = auto ]; then
    theme_mode="$(ableton_detect_theme 2>/dev/null || true)"
fi
case "$theme_mode" in
    dark) light_val=0 ;;
    light) light_val=1 ;;
    preserve|'') light_val="" ;;
esac
if [ -n "$light_val" ]; then
    prefix_note "   Applying the $theme_mode theme."
    wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d "$light_val" /f
    wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v EnableTransparency /t REG_DWORD /d 0 /f
    ableton_wineserver_wait
else
    prefix_note "   Existing theme settings were kept."
fi

prefix_note "== Configuring text rendering =="
# Wine takes the antialiasing mode from the host's Xft resources, so a desktop
# set to grayscale renders every Win32 menu, dialog and control grayscale
# whatever the prefix asks for. Patch 0084 lets an explicit FontSmoothingType
# in the prefix outrank that, and this is what sets it. Without these values
# the patch has nothing to act on and text stays grayscale.
#
# The subpixel order follows the host where it states one: a BGR panel
# rendered as RGB fringes the wrong way.
smoothing_order=1   # FE_FONTSMOOTHINGORIENTATIONRGB
if command -v gsettings >/dev/null 2>&1; then
    case "$(gsettings get org.gnome.desktop.interface font-rgba-order 2>/dev/null | tr -d "'")" in
        bgr) smoothing_order=0 ;;
    esac
fi
case "$smoothing_order" in
    0) prefix_note "   Using BGR subpixel order." ;;
    *) prefix_note "   Using RGB subpixel order." ;;
esac
wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothing /t REG_SZ /d 2 /f
wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d 2 /f
wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingOrientation /t REG_DWORD /d "$smoothing_order" /f
ableton_wineserver_wait

prefix_note "== Configuring PipeASIO audio =="
# Recheck at the last safe point.  The prefix is still the sibling staging
# copy, so a service/client change cannot leave the retained prefix half
# registered.  Registration removes and verifies only PipeASIO's one CLSID.
# The driver's unix half must resolve libpipewire-0.3.so.0 - the tarball build
# from the host's libs (it carries no rpath on purpose), the nix build from its
# nixpkgs RUNPATH. ldd follows both; ldconfig -p sees neither on NixOS.
pipeasio_ldd="$(ldd "$WINE_ROOT/lib/wine/x86_64-unix/pipeasio64.dll.so" 2>/dev/null || true)"
if grep -Eq 'libpipewire-0[.]3[.]so[.]0.*not found' <<< "$pipeasio_ldd"; then
    prefix_warn "!! PipeASIO cannot start because the PipeWire client library is missing. Install PipeWire 1.4.2 or newer."
fi
if [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0" ]; then
    prefix_warn "!! PipeWire is not running. Live will not list a PipeASIO device until PipeWire starts."
fi
ableton_pipewire_preflight "$WINE_ROOT/bin/pipewire-version-probe" "registering PipeASIO"
ableton_pipeasio_register wine ableton_wineserver_wait

# Seed the driver defaults once; the file is the config surface (PIPEASIO_*
# environment variables override it per launch, see the README).
write_default_pipeasio_settings()
{
    local pipeasio_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
    local pipeasio_tmp="" pipeasio_parent pipeasio_seeded=0
    if [ ! -e "$pipeasio_cfg" ] && [ ! -L "$pipeasio_cfg" ]; then
        pipeasio_parent="$(dirname "$pipeasio_cfg")"
        if mkdir -p -- "$pipeasio_parent" \
           && pipeasio_tmp="$(mktemp "$pipeasio_parent/.config.ini.XXXXXX")"; then
            if cat > "$pipeasio_tmp" <<'EOF'
[pipeasio]
inputs = 2
outputs = 2
buffer_size = 256
fixed_buffer_size = true
auto_connect = true
EOF
            then
                if chmod 600 "$pipeasio_tmp" \
                   && mv -T -n -- "$pipeasio_tmp" "$pipeasio_cfg" \
                   && [ ! -e "$pipeasio_tmp" ] && [ -f "$pipeasio_cfg" ] && [ ! -L "$pipeasio_cfg" ]; then
                    pipeasio_seeded=1
                fi
            fi
        fi
        if [ "$pipeasio_seeded" -eq 1 ]; then
            printf '   created default PipeASIO settings at %s (2 in / 2 out, fixed 256-frame buffer)\n' \
                "$pipeasio_cfg" 2>/dev/null || true
        else
            [ -z "$pipeasio_tmp" ] || rm -f -- "$pipeasio_tmp" 2>/dev/null || true
            if [ -e "$pipeasio_cfg" ] || [ -L "$pipeasio_cfg" ]; then
                printf '   kept the existing PipeASIO settings at %s\n' \
                    "$pipeasio_cfg" 2>/dev/null || true
            else
                printf '%s\n' "!! Default PipeASIO settings could not be written. Run prefix update to retry." >&2 2>/dev/null || true
            fi
        fi
    elif [ -L "$pipeasio_cfg" ] && [ ! -e "$pipeasio_cfg" ]; then
        printf '   kept your PipeASIO settings link even though its target is missing: %s\n' \
            "$pipeasio_cfg" 2>/dev/null || true
    fi
    return 0
}
write_default_pipeasio_settings

prefix_note "== Configuring file dialogs and Push USB access =="
# Default only: a policy the user set with set-file-portal-policy survives re-runs.
if ! wine reg query 'HKCU\Software\Wine\X11 Driver' /v FileDialogPortal >/dev/null 2>&1; then
  wine reg add 'HKCU\Software\Wine\X11 Driver' \
    /v FileDialogPortal /t REG_SZ /d auto /f
fi
for push_helper in Push2DisplayProcess.exe Push3.exe; do
    push_key="HKCU\\Software\\Wine\\AppDefaults\\$push_helper\\DllOverrides"
    wine reg add "$push_key" /v libusb-1.0 /t REG_SZ /d builtin /f
    wine reg query "$push_key" /v libusb-1.0
done

# Ableton's tlsetupfx.exe (kernel USB driver installer) faults under Wine and pops a winedbg
# dialog mid-install - twice, on every Live 11 install. The fault is harmless: the installer
# records it (0x80070643), carries on, and Live installs fine (issue 111), but two unexplained
# "Program Error" boxes make a working install look broken. Suppress the dialog only: winedbg
# still runs and still writes the backtrace to stderr.
wine reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f

# Earlier revisions of this script registered a placeholder Ableton Push USB Audio Driver
# product (version 99.0.0, invented ProductCode {B0B57A61-11E0-4A2E-9A11-AB1E70201126})
# here, so Live 11's Burn bundle would plan its driver package out. That only works on the
# WiX 4 generation of the bundle; the seed now lives in installer.sh, gated on the bundle's
# generation. Remove any leftover registration: the ProductCode is ours, so only the
# placeholder can be under it. This also clears the orphaned InstallProperties key a WiX 3
# bundle leaves behind when its RelatedPackage sweep removes the placeholder.
wine reg delete 'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4' /v 16A75B0B0E11E2A4A911BAE107021162 /f >/dev/null 2>&1 || true
wine reg delete 'HKLM\Software\Classes\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4' /v 16A75B0B0E11E2A4A911BAE107021162 /f >/dev/null 2>&1 || true
wine reg delete 'HKLM\Software\Classes\Installer\Products\16A75B0B0E11E2A4A911BAE107021162' /f >/dev/null 2>&1 || true
wine reg delete 'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\16A75B0B0E11E2A4A911BAE107021162' /f >/dev/null 2>&1 || true
wine reg query 'HKLM\Software' >/dev/null 2>&1 || {
    prefix_warn "!! The Wine registry could not be checked after removing an old Live 11 installer workaround."
    exit 1
}
for placeholder_query in \
    'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4|/v|16A75B0B0E11E2A4A911BAE107021162' \
    'HKLM\Software\Classes\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4|/v|16A75B0B0E11E2A4A911BAE107021162' \
    'HKLM\Software\Classes\Installer\Products\16A75B0B0E11E2A4A911BAE107021162||' \
    'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\16A75B0B0E11E2A4A911BAE107021162||'; do
    IFS='|' read -r placeholder_key placeholder_option placeholder_value <<< "$placeholder_query"
    placeholder_status=0
    if [ -n "$placeholder_option" ]; then
        wine reg query "$placeholder_key" "$placeholder_option" "$placeholder_value" \
            >/dev/null 2>&1 || placeholder_status=$?
    else
        wine reg query "$placeholder_key" >/dev/null 2>&1 || placeholder_status=$?
    fi
    [ "$placeholder_status" -eq 1 ] || {
        prefix_warn "!! An old Live 11 installer workaround is still present in the Wine registry."
        exit 1
    }
done

# winemenubuilder's entries assume `wine` on PATH (never true here) and are dead buttons: disable
# it and delete entries it already wrote for this prefix (matched by WINEPREFIX=; install.sh's entries can't match).
wine reg add 'HKCU\Software\Wine\DllOverrides' /v winemenubuilder.exe /t REG_SZ /d '' /f
desktop_dir="${XDG_DESKTOP_DIR:-}"
if [ -z "$desktop_dir" ] && command -v xdg-user-dir >/dev/null 2>&1; then
    desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
fi
for entry_dir in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" "$desktop_dir"; do
    [ -n "$entry_dir" ] || continue
    [ -d "$entry_dir" ] || continue
    find "$entry_dir" -maxdepth 3 -name '*.desktop' -type f 2>/dev/null | while IFS= read -r f; do
        if grep -qF "WINEPREFIX=\"$final_prefix\"" "$f" 2>/dev/null; then
            prefix_note "   Removing an obsolete desktop shortcut: $f"
            rm -f -- "$f" 2>/dev/null \
                || prefix_warn "!! Could not remove the obsolete desktop shortcut at $f."
        fi
    done || true
done
update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" 2>/dev/null || true
ableton_wineserver_wait

prefix_note "== Removing an obsolete Live audio setting =="
strip_options_txt "-DontCombineAPCs"

# -_ForceGdiBackend disables Live's GPU renderer. Early prefixes carried it
# (inherited from pre-repo setups); with the d2d1 base fork Live's GPU
# renderer works, removes the WebView2 pane flicker, and drops idle CPU.
prefix_note "== Enabling Live's GPU renderer =="
strip_options_txt "-_ForceGdiBackend"

prefix_note "== Checking Ableton Live =="
# Runs the USER'S OWN Ableton download - this repo ships no Live payload and no
# license. OPT-IN ONLY (ABLETON_LIVE_AUTOINSTALL=1): the automatic run is
# silent, which defers Ableton's EULA to first launch, and a prefix refresh must
# never execute an installer the user did not explicitly ask it to.
# Search dir: ~/Proprietary (the official ableton_live*.zip from ableton.com);
# ABLETON_INSTALLER_DIR overrides. The zip candidate - and the recipe major it
# implies - was resolved before Wine setup. Under the .run, installer.sh installs
# Live from its own payload after this prefix is ready.
live_ready=0
remove_extracted_live_installer()
{
    local unpack_dir="$1"
    if [ -e "$unpack_dir" ] || [ -L "$unpack_dir" ]; then
        rm -rf -- "$unpack_dir" 2>/dev/null || true
    fi
    if [ -e "$unpack_dir" ] || [ -L "$unpack_dir" ]; then
        printf '!! Temporary Ableton Live installer files remain at %s.\n' \
            "$unpack_dir" >&2 2>/dev/null || true
    fi
    return 0
}
if [ "${ABLETON_PREFIX_MANAGED:-0}" = 1 ]; then
    live_installed && live_ready=1
    if [ "$live_ready" -eq 1 ]; then
        prefix_note "   Live is already installed."
    else
        prefix_note "   The installer will install Live after Wine setup finishes."
    fi
elif live_installed; then
    live_ready=1
    prefix_note "   Live is already installed; it was left unchanged."
elif [ "${ABLETON_LIVE_AUTOINSTALL:-}" = 0 ]; then
    prefix_note "   Automatic Live installation is disabled."
elif [ "${ABLETON_LIVE_AUTOINSTALL:-0}" != 1 ]; then
    if [ -n "$live_zip" ]; then
        prefix_note "   Found $(basename "$live_zip"). Set ABLETON_LIVE_AUTOINSTALL=1 to install it."
        prefix_note "   Ableton's license agreement will be shown when Live first starts."
    else
        prefix_note "   To install your own Ableton download automatically, place it in $installer_dir and set ABLETON_LIVE_AUTOINSTALL=1."
    fi
elif [ -z "$live_zip" ]; then
    if [ -n "${ABLETON_LIVE_VERSION:-}" ]; then
        prefix_warn "!! No Live $ABLETON_LIVE_VERSION installer was found in $installer_dir."
    else
        prefix_warn "!! No Ableton Live installer zip was found in $installer_dir."
    fi
    prefix_note "   Put the official ableton.com zip there, or set ABLETON_INSTALLER_DIR to its directory."
else
    prefix_note "   Unpacking $(basename "$live_zip")."
    preferred_unpack_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ableton-wine-setup/live-installer"
    unpack_dir="$preferred_unpack_dir"
    if [ -d "$unpack_dir" ] && [ ! -L "$unpack_dir" ]; then
        rm -rf -- "$unpack_dir" 2>/dev/null || true
    fi
    if [ -e "$unpack_dir" ] || [ -L "$unpack_dir" ] \
       || ! mkdir -p -- "$unpack_dir" 2>/dev/null; then
        # This is disposable extraction cache. A stale, foreign-shaped, or
        # unwritable cache path cannot veto prefix preparation; use private
        # scratch space and leave the old object untouched for inspection.
        unpack_dir="$(mktemp -d "${TMPDIR:-/tmp}/ableton-live-installer.XXXXXX")" \
            || { prefix_warn "!! Temporary space for the Live installer could not be created."; exit 1; }
        printf '!! Old extracted installer files could not be replaced at %s; using temporary space instead.\n' \
            "$preferred_unpack_dir" >&2 2>/dev/null || true
    fi
    unpack_ok=1
    extract_timeout="$(ableton_timeout_value "${ABLETON_PAYLOAD_EXTRACT_TIMEOUT:-900}" ABLETON_PAYLOAD_EXTRACT_TIMEOUT 60 7200)"
    # -o + </dev/null stop unzip hanging on a "replace? (y/n)" prompt.
    if command -v unzip >/dev/null; then
        ableton_run_bounded "$extract_timeout" unzip -q -o "$live_zip" -d "$unpack_dir" </dev/null || unpack_ok=0
    elif command -v bsdtar >/dev/null; then
        ableton_run_bounded "$extract_timeout" bsdtar -xf "$live_zip" -C "$unpack_dir" </dev/null || unpack_ok=0
    elif command -v python3 >/dev/null; then
        ableton_run_bounded "$extract_timeout" python3 -m zipfile -e "$live_zip" "$unpack_dir" </dev/null || unpack_ok=0
    else
        unpack_ok=0
        prefix_warn "!! The Live installer zip cannot be opened because unzip, bsdtar, and python3 are unavailable."
    fi
    live_exe=""
    if [ "$unpack_ok" -eq 1 ]; then
        # Exactly one, as installer.sh requires of the same payload: picking the
        # first of several would choose by directory order, not by intent.
        mapfile -t payload_exes < <(find "$unpack_dir" -type f -iname '*.exe' -print | sort -V)
        if [ "${#payload_exes[@]}" -eq 1 ]; then
            live_exe="${payload_exes[0]}"
        else
            prefix_warn "!! Expected one installer program in the Live zip, but found ${#payload_exes[@]}."
        fi
    fi
    if [ "$unpack_ok" -eq 0 ]; then
        prefix_warn "!! Could not unpack $(basename "$live_zip"). You can still install Live manually."
    elif [ -z "$live_exe" ]; then
        prefix_warn "!! The zip does not contain one clear Live installer. Use the official ableton.com download."
    else
        # The silent flags depend on the installer engine, identified by the
        # test installer.sh makes: Live 11 ships a WiX Burn bundle, Live 12 an
        # Inno Setup one, and neither engine acts on the other's switches.
        if grep -qaF '.wixburn' < <(head -c 4096 -- "$live_exe"); then
            silent_flags=(/passive /norestart)
        else
            silent_flags=(/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-)
        fi
        # Not the wine() wrapper: that bounds a wine command at
        # ABLETON_WINE_COMMAND_TIMEOUT (300s), and a Suite install runs far
        # longer than that. Same bound and same variable installer.sh uses for
        # the same work.
        live_install_timeout="$(ableton_timeout_value "${ABLETON_LIVE_INSTALL_TIMEOUT:-3600}" ABLETON_LIVE_INSTALL_TIMEOUT 60 14400)"
        run_installer() {   # extra installer arguments in "$@"
            # Run from the installer's own directory so its relative payload
            # lookups (Installer-N.bin) resolve.
            (cd "$(dirname -- "$live_exe")" \
                && ableton_run_bounded "$live_install_timeout" \
                   "$WINE_ROOT/bin/wine" "./$(basename -- "$live_exe")" "$@")
        }
        # Lingering session infra (services.exe, explorer.exe) can hold a
        # finished session open for minutes; the prefix work is done once the
        # installer returns, so end the session instead of waiting it out.
        end_session() {
            local rc=0
            ableton_wineserver_quiesce || rc=$?
            [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || return "$rc"
        }
        if [ "${ABLETON_INSTALLER_UI:-0}" = 1 ]; then
            prefix_note "   Starting the Ableton installer. Follow the installer window."
            run_installer || prefix_warn "!! The Ableton installer exited with an error. You can retry the installation manually."
            end_session
        else
            prefix_note "   Installing Ableton Live. This can take a few minutes."
            # Keep the display attached: the installer engines need a window
            # connection even under these switches - a headless run installs
            # nothing at all; with the display it installs silently.
            run_installer "${silent_flags[@]}" || true
            end_session
            if ! live_installed; then
                prefix_warn "!! Automatic installation did not install Live. Starting the installer window."
                run_installer || prefix_warn "!! The Ableton installer exited with an error. You can retry the installation manually."
                end_session
            fi
        fi
        if live_installed; then live_ready=1; fi
    fi
    remove_extracted_live_installer "$unpack_dir"
fi

# Promote the fully prepared prefix only after every Wine command and gate has
# succeeded.  The original remains beside it until the outer transaction commits.
prefix_marker="$WINEPREFIX/.ableton-linux-prefix"
if [ -L "$prefix_marker" ] || { [ -e "$prefix_marker" ] && [ ! -f "$prefix_marker" ]; }; then
    prefix_warn "!! The prepared Wine prefix is missing a valid Ableton Linux setup record."
    exit 1
fi
prefix_marker_tmp="$(mktemp "$WINEPREFIX/.prefix-marker.XXXXXX")"
if ! printf 'format=1\nprefix=%s\n' "$final_prefix" > "$prefix_marker_tmp" \
   || ! chmod 600 "$prefix_marker_tmp" \
   || ! mv -T -f -- "$prefix_marker_tmp" "$prefix_marker" \
   || [ -e "$prefix_marker_tmp" ] || [ ! -f "$prefix_marker" ] || [ -L "$prefix_marker" ] \
   || ! ableton_prefix_marker_valid "$WINEPREFIX" "$final_prefix"; then
    rm -f -- "$prefix_marker_tmp"
    prefix_warn "!! The prepared Wine prefix could not be marked safely."
    exit 1
fi
prefix_backup=absent
if [ -e "$final_prefix" ]; then
    prefix_backup="$final_prefix.transaction-${transaction_dir##*/}"
    [ ! -e "$prefix_backup" ] && [ ! -L "$prefix_backup" ] \
        || { prefix_warn "!! An old Wine prefix recovery directory already exists: $prefix_backup"; exit 1; }
fi
# Revalidate both names immediately before the rename. New project launchers
# share the global installation lock, but a direct stock-Wine command or a
# launcher using the pre-update runtime can still start against the selected
# prefix while this first update is staging. Promotion is therefore scoped by
# the exact WINEPREFIX value, not by the runtime generation. The staging check
# separately proves that our own work left no process addressing the directory
# about to be renamed.
late_prefix_holders="$(ableton_prefix_wine_processes_any_runtime "$final_prefix")"
if [ -n "$late_prefix_holders" ]; then
    IFS=$'\t' read -r late_prefix_pid late_prefix_exe <<< "$late_prefix_holders" || {
        prefix_warn "!! The Wine process using $final_prefix could not be identified."
        exit 1
    }
    prefix_warn "!! A Wine program started while setup was running (pid $late_prefix_pid, $late_prefix_exe). Close it and run setup again."
    exit 1
fi
late_prefix_holders="$(ableton_prefix_wine_processes_any_runtime "$WINEPREFIX")"
if [ -n "$late_prefix_holders" ]; then
    IFS=$'\t' read -r late_prefix_pid late_prefix_exe <<< "$late_prefix_holders" || {
        prefix_warn "!! A Wine process using the prepared prefix could not be identified."
        exit 1
    }
    prefix_warn "!! A Wine program is still using the prepared prefix (pid $late_prefix_pid, $late_prefix_exe). Close it and run setup again."
    exit 1
fi
# A direct setup has not changed the live prefix before this point. Publish its
# active marker only for the atomic promotion window where recovery may truly
# be needed; the coordinator's outer transaction already has its own marker.
if [ "$own_prefix_transaction" -eq 1 ]; then
    : > "$transaction_dir/active"
fi
if ! ableton_promote_directory "$WINEPREFIX" "$final_prefix" "$prefix_backup" \
        "$transaction_dir/prefix.tsv"; then
    prefix_warn "!! The prepared Wine prefix could not be put into place."
    exit 1
fi
prefix_promoted=1
prefix_core_ready=1
export WINEPREFIX="$final_prefix"
if [ "$own_prefix_transaction" -eq 1 ]; then
    ableton_mark_transaction_core_complete "$transaction_dir" 2>/dev/null || true
    if prefix_transaction_commit "$transaction_dir"; then
        if ! rm -rf -- "$transaction_dir"; then
            prefix_warn "!! The Wine prefix is ready, but old recovery files remain at $transaction_dir."
        fi
    else
        rm -f -- "$transaction_dir/active" 2>/dev/null || true
        prefix_warn "!! The Wine prefix is ready, but old recovery files remain at $transaction_dir."
    fi
fi

if [ "$own_prefix_transaction" -eq 1 ]; then
prefix_note ""
prefix_note "OK: Wine is ready at $WINEPREFIX"
if [ "${ABLETON_PREFIX_MANAGED:-0}" != 1 ]; then
if [ "$live_ready" -eq 1 ]; then
    banner="Remaining steps (you supply your own license):"
    step1="  1. Live is installed - nothing more to supply here."
else
    banner="Remaining steps (you supply Ableton + your own license):"
    step1="$(cat <<STEP1
  1. Install Live (any edition) through THIS wine (plain wine reads
     WINEPREFIX, not the ABLETON_* launcher variables). For Live 12 the flags
     let the installer run by itself and skip Ableton's Windows USB audio
     driver, which does nothing on Linux:
       WINEPREFIX=$WINEPREFIX \\
       $WINE_ROOT/bin/wine "/path/to/Ableton Live 12 Edition Installer.exe" \\
       /SILENT /SUPPRESSMSGBOXES /NORESTART '/MERGETASKS=!audiodriver'
     Live 11's installer is a WiX Burn bundle and ignores those flags; run it
     without them and click through its window.
STEP1
)"
fi
cat <<EOF 2>/dev/null || true

────────────────────────────────────────────────────────────────────────
$banner

$step1

  2. Launch:            ableton-live
  3. Authorize Live with your own account (binds to this prefix's MachineGuid).
  4. Audio: Settings/Preferences > Audio > Driver Type: ASIO >
     Audio Device: PipeASIO.
     PipeASIO is a native PipeWire client: no JACK layer involved.
────────────────────────────────────────────────────────────────────────
EOF
fi
fi
prefix_promoted=0
