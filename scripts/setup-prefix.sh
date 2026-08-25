#!/usr/bin/env bash
# End-user step 2: create or refresh the Ableton Wine prefix. Idempotent.
# Ships no Ableton Live payload and no license; step [6/6] can run the user's
# own ableton_live*.zip download (~/Proprietary by default) - strictly opt-in
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

ARCH="${ARCH:-$(uname -m)}"
here="$(cd "$(dirname "$0")" && pwd)"
for config_lib in "$here/lib/config.sh" "$here/config.sh" \
                  "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    if [ -r "$config_lib" ]; then . "$config_lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 || { echo "!! setup-prefix: config helper is missing" >&2; exit 1; }
ableton_config_init
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
    echo "!! cannot locate vendor/winetricks (looked in $here/.. and $here)" >&2
    echo "!! prefix maintenance must run from the installer kit: either:" >&2
    echo "!!     sh install-ableton-latest.run update" >&2
    echo "!!   or extract the kit and run it from there:" >&2
    echo "!!     sh install-ableton-latest.run extract /tmp/ableton-kit" >&2
    echo "!!     bash /tmp/ableton-kit/scripts/installer.sh prefix update" >&2
    exit 1
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
            [ $# -ge 2 ] || { echo "!! --transaction-dir needs a directory" >&2; exit 2; }
            transaction_dir="$2"; shift ;;
        --rollback)
            [ $# -ge 2 ] || { echo "!! --rollback needs a transaction directory" >&2; exit 2; }
            operation=rollback; transaction_dir="$2"; shift ;;
        --preflight-rollback)
            [ $# -ge 2 ] || { echo "!! --preflight-rollback needs a transaction directory" >&2; exit 2; }
            operation=preflight-rollback; transaction_dir="$2"; shift ;;
        --preflight-commit)
            [ $# -ge 2 ] || { echo "!! --preflight-commit needs a transaction directory" >&2; exit 2; }
            operation=preflight-commit; transaction_dir="$2"; shift ;;
        --commit)
            [ $# -ge 2 ] || { echo "!! --commit needs a transaction directory" >&2; exit 2; }
            operation=commit; transaction_dir="$2"; shift ;;
        *) echo "!! unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "${ABLETON_LIVE_VERSION:-12}" in
    11|12) ;;
    *) echo "!! ABLETON_LIVE_VERSION must be 11 or 12 (got '$ABLETON_LIVE_VERSION')" >&2; exit 2 ;;
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
            echo "!! prefix rollback record is unsafe or invalid" >&2; return 1; }
        IFS=$'\t' read -r target backup extra < "$record"
        [ -z "$extra" ] && [ -n "$target" ] && [ -n "$backup" ] || {
            echo "!! prefix rollback record is malformed" >&2; return 1; }
        safe="$(ableton_path_is_safe_delete_target "$target")" || {
            echo "!! unsafe prefix rollback target: $target" >&2; return 1; }
        [ "$target" = "$safe" ] \
            && [ "$safe" = "$(ableton_realpath_m "$ABLETON_WINEPREFIX")" ] || {
            echo "!! prefix rollback target does not match this installation: $target" >&2
            return 1
        }
        if [ -e "$safe" ] || [ -L "$safe" ]; then
            if ! { [ -d "$safe" ] && [ ! -L "$safe" ] \
                   && ableton_prefix_marker_valid "$safe" "$safe"; }; then
                echo "!! prefix rollback target is unrecognised: $safe" >&2
                return 1
            fi
        fi
        if [ "$backup" != absent ]; then
            expected_backup="$safe.transaction-${txn##*/}"
            backup_safe="$(ableton_path_is_safe_delete_target "$backup")" || {
                echo "!! unsafe prefix rollback backup: $backup" >&2; return 1; }
            [ "$backup" = "$expected_backup" ] && [ "$backup" = "$backup_safe" ] || {
                echo "!! prefix rollback backup is misplaced: $backup" >&2; return 1; }
            if [ -e "$backup" ] || [ -L "$backup" ]; then
                if ! { [ -d "$backup" ] && [ ! -L "$backup" ] \
                       && ableton_prefix_marker_valid "$backup" "$safe"; }; then
                    echo "!! prefix rollback backup is unrecognised: $backup" >&2
                    return 1
                fi
            elif [ "$mode" != commit ]; then
                echo "!! prefix rollback backup is missing: $backup" >&2
                return 1
            fi
        fi
    fi
    if [ -e "$txn/prefix-host" ] || [ -L "$txn/prefix-host" ]; then
        [ -d "$txn/prefix-host" ] && [ ! -L "$txn/prefix-host" ] || {
            echo "!! prefix host transaction is unsafe" >&2; return 1; }
        ableton_txn_preflight_rollback_files "$txn/prefix-host" || return 1
    elif [ -e "$record" ]; then
        echo "!! prefix host transaction is missing" >&2
        return 1
    fi
}

prefix_transaction_commit_preflight()
{
    local txn="$1" record="$1/prefix.tsv"
    prefix_transaction_preflight "$txn" commit || return 1
    if [ -e "$txn/prefix-host" ]; then
        ableton_txn_preflight_commit_files "$txn/prefix-host" || return 1
    elif [ -e "$record" ]; then
        return 1
    fi
}

prefix_transaction_rollback()
{
    local txn="$1" target backup safe="" backup_safe="" expected_backup
    local rc=0 layout_ok=1
    prefix_transaction_preflight "$txn" || return 1
    if [ -r "$txn/prefix.tsv" ]; then
        IFS=$'\t' read -r target backup < "$txn/prefix.tsv"
        if ! safe="$(ableton_path_is_safe_delete_target "$target")"; then
            echo "!! unsafe prefix rollback target: $target" >&2
            rc=1; layout_ok=0
        elif [ "$target" != "$safe" ] \
             || [ "$safe" != "$(ableton_realpath_m "$ABLETON_WINEPREFIX")" ]; then
            echo "!! prefix rollback target does not match this installation: $target" >&2
            rc=1; layout_ok=0
        fi
        if [ "$layout_ok" -eq 1 ] && [ "$backup" != absent ]; then
            expected_backup="$safe.transaction-${txn##*/}"
            if ! backup_safe="$(ableton_path_is_safe_delete_target "$backup")" \
               || [ "$backup" != "$expected_backup" ] || [ "$backup" != "$backup_safe" ] \
               || [ ! -d "$backup" ] || [ -L "$backup" ] \
               || ! ableton_prefix_marker_valid "$backup" "$safe"; then
                echo "!! prefix rollback backup is missing, misplaced, or unrecognised: $backup" >&2
                rc=1; layout_ok=0
            fi
        fi
        if [ "$layout_ok" -eq 1 ] && [ -e "$safe" ]; then
            if [ -L "$safe" ]; then
                echo "!! refusing symlink prefix rollback target: $safe" >&2
                rc=1; layout_ok=0
            elif ! ableton_prefix_marker_valid "$safe" "$safe"; then
                echo "!! refusing to remove unmarked prefix during rollback: $safe" >&2
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
    ableton_txn_rollback_files "$txn/prefix-host" || rc=1
    if [ "$rc" -eq 0 ]; then
        rm -f -- "$txn/prefix-host/active" || rc=1
    fi
    update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true
    return "$rc"
}

prefix_transaction_commit()
{
    local txn="$1" target backup safe
    prefix_transaction_commit_preflight "$txn" || return 1
    [ -r "$txn/prefix.tsv" ] || return 0
    IFS=$'\t' read -r target backup < "$txn/prefix.tsv"
    if [ "$backup" != absent ] && [ -e "$backup" ]; then
        safe="$(ableton_path_is_safe_delete_target "$backup")" || { echo "!! unsafe prefix backup: $backup" >&2; return 1; }
        [ ! -L "$safe" ] || { echo "!! refusing symlink prefix backup: $safe" >&2; return 1; }
        ableton_prefix_marker_valid "$safe" "$target" || {
            echo "!! refusing prefix backup with an invalid ownership marker: $safe" >&2
            return 1
        }
        prefix_commit_started=1
        rm -rf -- "$safe" || return 1
        [ ! -e "$safe" ] && [ ! -L "$safe" ] || return 1
    fi
    prefix_commit_started=1
    rm -f -- "$txn/prefix.tsv" || return 1
    rm -f -- "$txn/prefix-host/active" || return 1
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
    *) echo "!! ABLETON_THEME_MODE must be auto, dark, light, or preserve" >&2; exit 2 ;;
esac

if [ "$validate_only" -eq 1 ]; then
    . "$here/detect-scale.sh"
    validate_dpi="${ABLETON_DPI_MODE:-auto}"
    case "$validate_dpi" in
        auto|preserve|100|fractional) ;;
        dpi*|fractional*) ableton_dpi_block_values "$validate_dpi" >/dev/null || {
            echo "!! invalid ABLETON_DPI_MODE '$validate_dpi'" >&2; exit 2; } ;;
        *) echo "!! ABLETON_DPI_MODE must be auto, preserve, 100, fractional, dpi<N>, or fractional<N>" >&2; exit 2 ;;
    esac
    if [ "${ABLETON_RUNTIME_PENDING:-0}" != 1 ]; then
        [ -x "$WINE_ROOT/bin/wine" ] || { echo "!! patched Wine not found at $WINE_ROOT" >&2; exit 1; }
    fi
    command -v cabextract >/dev/null || { echo "!! cabextract is required for prefix setup" >&2; exit 1; }
    if [ "$refresh" -eq 1 ]; then
        [ -f "$WINEPREFIX/system.reg" ] || { echo "!! --refresh needs an existing prefix at $WINEPREFIX" >&2; exit 2; }
    fi
    echo "OK: prefix configuration is valid"
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
        echo "!! unsafe Wine prefix path: $WINEPREFIX" >&2; exit 2; }
    if ! { [ "$safe_repair_prefix" = "$WINEPREFIX" ] && [ ! -L "$WINEPREFIX" ] \
           && ableton_prefix_marker_valid "$WINEPREFIX" "$WINEPREFIX"; }; then
        echo "!! refusing Live 11 repair for an unrecognised prefix" >&2
        exit 2
    fi
    . "$here/lib/lifecycle.sh"
    if ableton_prefix_busy; then
        echo "!! Wine clients are running in $WINEPREFIX; close them before Live 11 repair" >&2
        exit 1
    fi
    [ -f "$WINEPREFIX/system.reg" ] || { echo "!! no prefix at $WINEPREFIX: nothing to run --post-first-run against" >&2; exit 2; }
    moved=0
    for maxpref in "$WINEPREFIX"/drive_c/users/*/"AppData/Roaming/Cycling '74/Max 8/Settings/maxpreferences.maxpref"; do
        [ -f "$maxpref" ] || continue
        bak="$maxpref.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        [ -e "$bak" ] && bak="$bak.$$"      # same-second re-run: keep both backups
        mv -v "$maxpref" "$bak"
        moved=1
    done
    if [ "$moved" -eq 1 ]; then
        echo "OK: Max preferences moved aside; Max regenerates them on next start"
    else
        echo "OK: no maxpreferences.maxpref under $WINEPREFIX: nothing to do (Max not run yet?)"
    fi
    exit 0
fi

[ -x "$WINE_ROOT/bin/wine" ] || {
    echo "!! patched wine not at $WINE_ROOT: run ./scripts/installer.sh runtime install first"
    exit 1
}
command -v cabextract >/dev/null || { echo "!! cabextract is required for prefix setup" >&2; exit 1; }
for required in \
    bin/pipewire-version-probe \
    ABLETON-WINE-BUILD-INFO.txt \
    lib/wine/$ARCH-unix/comdlg32.so \
    lib/wine/x86_64-windows/libusb-1.0.dll \
    lib/wine/$ARCH-unix/libusb-1.0.so \
    lib/wine/x86_64-windows/pipeasio64.dll \
    lib/wine/x86_64-windows/pipeasio.dll \
    lib/wine/x86_64-unix/pipeasio64.dll.so \
    lib/wine/x86_64-unix/pipeasio.dll.so; do
    [ -s "$WINE_ROOT/$required" ] || { echo "!! packaged runtime is missing $required"; exit 1; }
done
ableton_pipeasio_validate_runtime "$WINE_ROOT"
ableton_pipewire_preflight "$WINE_ROOT/bin/pipewire-version-probe" "configuring PipeASIO"

# Prefix changes are made against a sibling staging copy, then promoted in one
# rename.  Existing prefixes use reflink cloning where the filesystem supports
# it and a full copy otherwise.  The outer installer keeps the transaction open
# through Live installation, so any later failure can restore the old prefix.
. "$here/lib/lifecycle.sh"
if ableton_prefix_busy; then
    echo "!! Wine clients are running in $WINEPREFIX; close Live, Max, and other prefix programs first" >&2
    exit 1
fi
final_prefix="$WINEPREFIX"
final_parent="$(dirname "$final_prefix")"
final_name="$(basename "$final_prefix")"
safe_final="$(ableton_path_is_safe_delete_target "$final_prefix")" || {
    echo "!! unsafe Wine prefix path: $final_prefix" >&2; exit 2; }
[ ! -L "$final_prefix" ] || { echo "!! refusing symlink Wine prefix: $final_prefix" >&2; exit 2; }
if [ -e "$final_prefix" ] && ! ableton_prefix_marker_valid "$final_prefix" "$safe_final"; then
    if ableton_legacy_default_prefix_valid "$final_prefix"; then
        # Adopt it here, before any transaction opens. The run below moves this
        # prefix aside as its rollback backup, and the commit checks that backup
        # for the same ownership marker, so a prefix adopted any later than this
        # leaves a backup that can never satisfy it: the promotion succeeds and
        # the commit then fails with the backup unrecognised.
        adopt_marker="$final_prefix/.ableton-linux-prefix"
        [ ! -L "$adopt_marker" ] && [ ! -e "$adopt_marker" ] || {
            echo "!! existing Wine prefix has an unsafe ownership marker: $adopt_marker" >&2; exit 2; }
        adopt_tmp="$(mktemp "$final_prefix/.prefix-marker.XXXXXX")" || {
            echo "!! cannot write into the existing Wine prefix: $final_prefix" >&2; exit 2; }
        if ! printf 'format=1\nprefix=%s\n' "$safe_final" > "$adopt_tmp" \
           || ! chmod 600 "$adopt_tmp" \
           || ! mv -T -f -- "$adopt_tmp" "$adopt_marker" \
           || ! ableton_prefix_marker_valid "$final_prefix" "$safe_final"; then
            # The marker too, not just the staging file: once one exists,
            # ableton_legacy_default_prefix_valid stops recognising the prefix,
            # so a half-written one would refuse every later run as well.
            rm -f -- "$adopt_tmp" "$adopt_marker"
            echo "!! could not adopt the existing Wine prefix: $final_prefix" >&2
            exit 2
        fi
        echo ":: adopted the existing prefix at $final_prefix (it predates the ownership marker)"
    else
        echo "!! refusing to transactionally replace unrecognised custom prefix: $final_prefix" >&2
        echo "!! create it once with this project's setup so it carries .ableton-linux-prefix" >&2
        exit 2
    fi
fi
mkdir -p -- "$final_parent"
own_prefix_transaction=0
if [ -z "$transaction_dir" ]; then
    ableton_mark_state_home
    mkdir -p -- "$ABLETON_STATE_HOME/transactions"
    transaction_dir="$(mktemp -d "$ABLETON_STATE_HOME/transactions/prefix.XXXXXX")"
    own_prefix_transaction=1
else
    mkdir -p -- "$transaction_dir"
fi
ABLETON_TRANSACTION_DIR="$transaction_dir/prefix-host"
export ABLETON_TRANSACTION_DIR
stage_prefix=""
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_prefix_transaction()
{
    local rc=$? restore_ok=1
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ -e "$ABLETON_TRANSACTION_DIR/active" ]; then
        prefix_transaction_rollback "$transaction_dir" || restore_ok=0
    fi
    if [ "$rc" -ne 0 ] && [ "$own_prefix_transaction" -eq 1 ] \
       && [ "$restore_ok" -eq 1 ]; then
        rm -rf -- "$transaction_dir" || restore_ok=0
    fi
    if [ "$restore_ok" -ne 1 ]; then
        echo "!! prefix setup failed before staging and its transaction needs recovery: $transaction_dir" >&2
    fi
    exit "$rc"
}
trap cleanup_unstarted_prefix_transaction EXIT
[ -e "$ABLETON_TRANSACTION_DIR" ] || mkdir -- "$ABLETON_TRANSACTION_DIR"
ableton_txn_init
ableton_validate_install_state_journals
if [ -e "$final_prefix" ]; then
    ableton_adopt_prefix_marker "$final_prefix" "$safe_final" || {
        echo "!! refusing to update an unrecognised Wine prefix: $final_prefix" >&2
        exit 2
    }
fi
stage_prefix="$(mktemp -d "$final_parent/.${final_name}.prefix-stage.XXXXXX")"
prefix_promoted=0
prefix_cleanup()
{
    local rc=$? restore_error="" restoration_complete=yes
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
        if [ "$prefix_commit_started" -eq 1 ]; then
            printf 'status=committed-cleanup-incomplete\nprefix=%s\nexit=%s\n' \
                "$final_prefix" "$rc" > "$transaction_dir/COMMITTED_CLEANUP_FAILURE" 2>/dev/null || true
            echo "!! prefix update is committed, but cleanup is incomplete" >&2
            echo "!! inspect $transaction_dir/COMMITTED_CLEANUP_FAILURE before retrying" >&2
        elif [ "$prefix_promoted" -eq 1 ]; then
            if ! prefix_transaction_rollback "$transaction_dir"; then
                restore_error="prefix rollback failed"
            fi
        else
            if [ -d "$stage_prefix" ] && ! rm -rf -- "$stage_prefix"; then
                restore_error="staged prefix cleanup failed"
            fi
            if ! prefix_transaction_rollback "$transaction_dir"; then
                restore_error="${restore_error}${restore_error:+; }host-file rollback failed"
            fi
        fi
        if [ "$prefix_commit_started" -ne 1 ]; then
            [ -z "$restore_error" ] || restoration_complete=no
            printf 'status=failed\nprefix=%s\nexit=%s\nrestoration_complete=%s\nrestoration_error=%s\n' \
                "$final_prefix" "$rc" "$restoration_complete" "$restore_error" \
                > "$transaction_dir/prefix-failure" || true
            if [ "$restoration_complete" = yes ]; then
                echo "!! prefix setup failed; the prior prefix was preserved" >&2
            else
                echo "!! prefix setup failed and automatic restoration is incomplete: $restore_error" >&2
                echo "!! inspect $transaction_dir/prefix-failure before retrying" >&2
            fi
        fi
    fi
    exit "$rc"
}
trap prefix_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -f "$final_prefix/system.reg" ]; then
    echo "== staging a transactional copy of the existing prefix =="
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
# fresh prefix, preserves an existing one, refuses scales outside 100-250%.
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
            if ! printf '%s' "$feats" | grep -q xwayland-native-scaling; then
                echo "!! mutter experimental-features lacks xwayland-native-scaling —"
                echo "!! the '$1' DPI block expects it present; add it to"
                echo "!!   org.gnome.mutter experimental-features (gsettings)"
            fi ;;
        *)
            if printf '%s' "$feats" | grep -q xwayland-native-scaling; then
                echo "!! mutter experimental-features lists xwayland-native-scaling —"
                echo "!! the '$1' DPI block expects it absent; remove it from"
                echo "!!   org.gnome.mutter experimental-features (gsettings)"
            fi ;;
    esac
    return 0
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
        # Match with CR stripped so a CRLF-edited copy is caught too.
        tr -d '\r' < "$f" | grep -qxF -- "$line" || continue
        tmp="$(mktemp)"
        awk -v opt="$line" '{ l = $0; sub(/\r$/, "", l) } l != opt { print }' "$f" > "$tmp"
        if [ -s "$tmp" ]; then
            # Write through the existing inode: keeps the file's permissions.
            cat "$tmp" > "$f"
            rm -f "$tmp"
            echo "   removed $line from $f"
        else
            # The seed's touch created the file; nothing else in it: undo fully.
            rm -f "$tmp" "$f"
            echo "   removed $f (held only $line)"
        fi
    done
    shopt -u nullglob
}

fresh_prefix=0
[ -f "$WINEPREFIX/system.reg" ] || fresh_prefix=1
if [ "$refresh" -eq 1 ] && [ "$fresh_prefix" -eq 1 ]; then
    echo "!! --refresh needs an existing prefix at $WINEPREFIX: run without it to create one" >&2
    exit 2
fi

# Resolve the mode now so a fresh prefix fails fast, before wineboot/winetricks run.
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
        echo "!! ABLETON_DPI_MODE '$dpi_mode' is not a usable DPI block (want dpi<N> / fractional<N> with LogPixels N in 72..384)" >&2
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
                echo "   display scale $scale ($dpi_family) detected -> will apply the '$block' DPI block"
                dpi_block="$block"
            else
                have="$(current_dpi_block)"
                if [ "$have" = "$block" ]; then
                    echo "   display scale $scale detected; existing prefix already holds the '$block' block"
                else
                    echo "!! display scale $scale wants the '$block' DPI block, but this existing prefix holds '$have'"
                    echo "!! preserving it: rerun with ABLETON_DPI_MODE=$block to recalibrate deliberately"
                fi
            fi
        elif [ "$fresh_prefix" -eq 1 ]; then
            echo "!! display scale $scale is outside the calibrated 100-250% range" >&2
            echo "!! rerun with an explicit ABLETON_DPI_MODE=100 or =dpi<N> (LogPixels N in 72..384)" >&2
            exit 2
        else
            echo "!! display scale $scale is outside the calibrated 100-250% range: preserving existing prefix values"
        fi
    elif [ "$fresh_prefix" -eq 1 ]; then
        echo "!! cannot detect the display scale (non-GNOME desktop or headless session?)" >&2
        echo "!! a fresh prefix needs an explicit ABLETON_DPI_MODE=100 or =dpi<N>" >&2
        exit 2
    else
        echo "   cannot detect display scale; preserving existing prefix values"
    fi
    ;;
  *)
    echo "!! ABLETON_DPI_MODE must be auto, preserve, 100, fractional, or dpi<N>" >&2
    exit 2
    ;;
esac

# Ableton Live auto-install candidate (run by step [6/6]) and the Live major
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
# nor step [6/6] runs there: two installers writing one prefix is not a
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
            [ "$live_major" = 12 ] || \
                echo ":: $(basename "$live_zip") is Live $live_major: using the Live $live_major recipe (ABLETON_LIVE_VERSION overrides)"
            ;;
        "")
            echo ":: cannot read a Live version from $(basename "$live_zip"): using the Live 12 recipe (set ABLETON_LIVE_VERSION if that is wrong)"
            ;;
        *)
            echo "!! $(basename "$live_zip") looks like Live $zip_major: no recipe for that major (11|12); set ABLETON_LIVE_VERSION or remove the zip" >&2
            exit 2
            ;;
    esac
fi

echo "== [1/6] initialise prefix at $WINEPREFIX =="
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
    echo "== [2/6] winetricks: skipped (--refresh keeps the installed fonts/runtimes) =="
else
    # Verb set per Live major: Live 12 needs vcrun2022 + mfc42; Live 11 needs
    # vcrun2019 + gdiplus (the Ableton forum Live-on-Linux guide). vcrun2019/gdiplus
    # payloads are not vendored yet: Live 11 setup downloads them on first run.
    case "$live_major" in
        11) verbs=(corefonts vcrun2019 gdiplus) ;;
        12) verbs=(corefonts vcrun2022 mfc42) ;;
        *)  echo "!! internal: live_major '$live_major' has no winetricks recipe" >&2; exit 2 ;;
    esac
    echo "== [2/6] winetricks (Live $live_major): ${verbs[*]} =="
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
        tmpc="$(mktemp -d)"
        # Per-verb symlinks, not one dir link: the vendored cache may be
        # read-only (nix store), and verbs missing from it must still be able
        # to download into the writable parent.
        mkdir "$tmpc/winetricks"
        # nullglob: an empty cache would otherwise link a file named "*".
        ( shopt -s nullglob
          for cached in "$root/vendor/winetricks-cache"/*; do
              ln -s "$cached" "$tmpc/winetricks/"
          done )
        export XDG_CACHE_HOME="$tmpc"
        echo "   using bundled winetricks cache ($root/vendor/winetricks-cache)"
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
        rm -rf "$tmpc"
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
        echo "!! Bitstream Vera fonts not found - Max for Live devices that request"
        echo "   a missing typeface WILL hang Live (frozen window, audio still"
        echo "   playing). Vendor them into vendor/fonts/bitstream-vera/ or install"
        echo "   your distro's package (Debian/Ubuntu: ttf-bitstream-vera,"
        echo "   Fedora: bitstream-vera-fonts, Arch: ttf-bitstream-vera)."
        return 0                      # non-fatal: everything else still works
    fi

    # Non-fatal throughout, deliberately: under `set -e` a failed step here
    # would abort the whole setup and leave the prefix half-configured, which is
    # worse than a working prefix plus a loud warning. check-m4l-fonts.sh
    # catches the not-installed state later.
    if ! mkdir -p "$winfonts"; then
        echo "!! cannot create $winfonts; skipping the M4L font fallback repair"
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
            echo "!! failed to copy $n into $winfonts"
        fi
    done
    [ "$missing" -eq 1 ] && echo "   (some Vera faces absent from $src; registering what is present)"

    # One import rather than ten `wine reg add` calls: each spawns a wine
    # process, and this runs on every setup and every --refresh. Backslashes are
    # doubled and lines are CRLF because that is what .reg format wants; the
    # values land byte-identical to what reg add wrote.
    local reg_file fonts_key='HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    reg_file="$(mktemp)" || { echo "!! cannot write a temporary .reg; skipping registration"; return 0; }
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
    rm -f "$reg_file"
    ableton_wineserver_wait || true

    if [ "$registered" -eq 0 ]; then
        echo "!! MaxPlug font fallback NOT registered ($copied file(s) copied)."
        echo "   M4L devices requesting a missing typeface will hang Live."
        echo "   Re-run this script with Live closed, then verify with:"
        echo "     scripts/check-m4l-fonts.sh"
    elif [ "$registered" -lt "${#faces[@]}" ]; then
        echo "   MaxPlug font fallback partially registered ($registered/${#faces[@]}); verify with scripts/check-m4l-fonts.sh"
    else
        echo "   MaxPlug font fallback installed and registered (source: $src)"
    fi
}
echo "== fonts: Max for Live fallback chain =="
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
        *) echo "!! Live's bundled VC++ redist failed (exit $status)" >&2; return 1 ;;
    esac
    vc_runtime_ready || { echo "!! bundled redist ran, but system32 still holds placeholder/missing runtime DLLs" >&2; return 1; }
}

# wineboot -u replaces redist natives (msvcp140 etc.) with wine's higher-versioned stubs, which
# Live aborts on. Prefer the redist bundled in Live's own Redist folder; the vendored payload
# stays as the fallback and as the final gate (it also covers syswow64, which vc_redist.x64
# doesn't touch). The redist comes from the same source winetricks used: vcrun2022 (Live 12)
# or vcrun2019 (Live 11): both ship the vc_redist.x64/x86.exe pair with the same cab layout.
redist_verb=vcrun2022
[ "$live_major" = 11 ] && redist_verb=vcrun2019
echo "== [2b/6] force native VC++ runtime over wine's builtin stubs ($redist_verb) =="
kit_root || true   # vendored cache is only a candidate; absence is not fatal here
if ! vc_runtime_ready; then
    live_redist="$(find_live_redist || true)"
    if [ -n "$live_redist" ]; then
        echo "   installing VC++ redist from Live's own Redist: ${live_redist#"$WINEPREFIX"/}"
        install_live_redist "$live_redist" || \
            echo "!! falling back to the vendored vc_redist payload" >&2
    fi
fi
redist_dir=""
for d in "$root/vendor/winetricks-cache/$redist_verb" \
         "${XDG_CACHE_HOME:-$HOME/.cache}/winetricks/$redist_verb"; do
    [ -s "$d/vc_redist.x64.exe" ] && { redist_dir="$d"; break; }
done
if [ -z "$redist_dir" ]; then
    if vc_runtime_ready; then
        echo "   no vendored vc_redist.x64.exe: relying on the runtime verified above"
    else
        echo "!! vc_redist.x64.exe not found (vendor or winetricks cache): cannot assert a native VC runtime" >&2; exit 1
    fi
else
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
            echo "   restoring native $wdir/$name (was wine builtin or missing)"
            install -m 644 "$f" "$dest"
        fi
        # gate: a file still identical to wine's builtin means the heal failed
        if [ -s "$builtin" ] && cmp -s "$dest" "$builtin"; then
            echo "!! $wdir/$name is still wine's builtin stub" >&2; vc_bad=1
        fi
    done
    rm -rf "$vc_tmp"
    [ "$vc_bad" -eq 0 ] || { echo "!! native VC++ runtime gate FAILED" >&2; exit 1; }
fi

echo "== [3/6] DPI policy ($dpi_mode -> $dpi_block) =="
case "$dpi_block" in
  preserve)
    echo "   preserving current LogPixels and dpiAwareness values"
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
        echo "   (Live not installed yet: the launcher sets its per-app DPI flag on first start)"
    fi
    check_mutter_knob "$dpi_block" "$dpi_family"
    ;;
esac
ableton_wineserver_wait

echo "== [3b/6] theme policy (${ABLETON_THEME_MODE:-auto}) =="
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
    echo "   applying $theme_mode theme"
    wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d "$light_val" /f
    wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v EnableTransparency /t REG_DWORD /d 0 /f
    ableton_wineserver_wait
else
    echo "   preserving existing theme values"
fi

echo "== [3c/6] text: subpixel antialiasing =="
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
case "$smoothing_order" in 0) echo "   subpixel order: BGR" ;; *) echo "   subpixel order: RGB" ;; esac
wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothing /t REG_SZ /d 2 /f
wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d 2 /f
wine reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingOrientation /t REG_DWORD /d "$smoothing_order" /f
ableton_wineserver_wait

if [ "$ARCH" = "x86_64"]; then
echo "== [4/6] register packaged PipeASIO =="
# Recheck at the last safe point.  The prefix is still the sibling staging
# copy, so a service/client change cannot leave the retained prefix half
# registered.  Registration removes and verifies only PipeASIO's one CLSID.
# The driver's unix half must resolve libpipewire-0.3.so.0 - the tarball build
# from the host's libs (it carries no rpath on purpose), the nix build from its
# nixpkgs RUNPATH. ldd follows both; ldconfig -p sees neither on NixOS.
if ldd "$WINE_ROOT/lib/wine/x86_64-unix/pipeasio64.dll.so" 2>/dev/null \
    | grep -F 'libpipewire-0.3.so.0' | grep -q 'not found'; then
    echo "!! the PipeASIO driver cannot resolve libpipewire-0.3.so.0; install pipewire (0.3.56 or newer, 1.6+ recommended)"
fi
[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0" ] || \
    echo "!! no PipeWire socket at ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0 - Live will list no PipeASIO device until the PipeWire daemon runs"
ableton_pipewire_preflight "$WINE_ROOT/bin/pipewire-version-probe" "registering PipeASIO"
ableton_pipeasio_register wine ableton_wineserver_wait

# Seed the driver defaults once; the file is the config surface (PIPEASIO_*
# environment variables override it per launch, see the README).
pipeasio_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
if [ ! -e "$pipeasio_cfg" ] && [ ! -L "$pipeasio_cfg" ]; then
    pipeasio_tmp="$(mktemp "$transaction_dir/pipeasio.XXXXXX")"
    cat > "$pipeasio_tmp" <<'EOF'
[pipeasio]
inputs = 2
outputs = 2
buffer_size = 256
fixed_buffer_size = true
auto_connect = true
EOF
    ableton_install_file 600 "$pipeasio_tmp" "$pipeasio_cfg" config
    rm -f -- "$pipeasio_tmp"
    ableton_write_ownership_manifest
    echo "   seeded $pipeasio_cfg (2 in / 2 out, fixed 256-frame buffer)"
elif [ -L "$pipeasio_cfg" ] && [ ! -e "$pipeasio_cfg" ]; then
    echo "   kept your dangling PipeASIO configuration link: $pipeasio_cfg"
fi
fi

echo "== [5/6] set portal policy and scope the Push USB bridge to its helpers =="
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
            echo "   removing dead winemenubuilder entry: $f"
            ableton_txn_snapshot "$f"
            ableton_txn_expect "$f" absent
            rm -f "$f"
        fi
    done
done
update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" 2>/dev/null || true
ableton_wineserver_wait

echo "== [5b/6] remove the 2026.07.18.1 Options.txt seed (issue #29) =="
strip_options_txt "-DontCombineAPCs"

# -_ForceGdiBackend disables Live's GPU renderer. Early prefixes carried it
# (inherited from pre-repo setups); with the d2d1 base fork Live's GPU
# renderer works, removes the WebView2 pane flicker, and drops idle CPU.
echo "== [5c/6] remove -_ForceGdiBackend so Live uses its GPU renderer =="
strip_options_txt "-_ForceGdiBackend"

echo "== [6/6] Ableton Live =="
# Runs the USER'S OWN Ableton download - this repo ships no Live payload and no
# license. OPT-IN ONLY (ABLETON_LIVE_AUTOINSTALL=1): the automatic run is
# silent, which defers Ableton's EULA to first launch, and a prefix refresh must
# never execute an installer the user did not explicitly ask it to.
# Search dir: ~/Proprietary (the official ableton_live*.zip from ableton.com);
# ABLETON_INSTALLER_DIR overrides. The zip candidate - and the recipe major it
# implies - was resolved before step [1/6]. Under the .run this step reports and
# does nothing: installer.sh installs Live from its own payload, with the
# handling this step repeats rather than shares, that copy not being present in
# a packaged install.
live_ready=0
if [ "${ABLETON_PREFIX_MANAGED:-0}" = 1 ]; then
    live_installed && live_ready=1
    echo "   installed by the ableton-wine-setup installer, not by this step"
elif live_installed; then
    live_ready=1
    echo "   Live is already installed in this prefix - not touching it"
elif [ "${ABLETON_LIVE_AUTOINSTALL:-}" = 0 ]; then
    echo "   skipped (ABLETON_LIVE_AUTOINSTALL=0)"
elif [ "${ABLETON_LIVE_AUTOINSTALL:-0}" != 1 ]; then
    if [ -n "$live_zip" ]; then
        echo "   found $(basename "$live_zip") - rerun with ABLETON_LIVE_AUTOINSTALL=1 to install it"
        echo "   (silent install: Ableton's EULA is then shown on Live's first launch, not before)"
    else
        echo "   skipped - ABLETON_LIVE_AUTOINSTALL=1 (opt-in) installs your ableton_live*.zip from $installer_dir"
    fi
elif [ -z "$live_zip" ]; then
    if [ -n "${ABLETON_LIVE_VERSION:-}" ]; then
        echo "   no Live $ABLETON_LIVE_VERSION installer (ableton_live*_${ABLETON_LIVE_VERSION}.*.zip) in $installer_dir - manual install steps are printed below"
    else
        echo "   no ableton_live*.zip in $installer_dir - manual install steps are printed below"
    fi
    echo "   (drop the official ableton.com zip there, or point ABLETON_INSTALLER_DIR at it)"
else
    echo "   unpacking $(basename "$live_zip")"
    unpack_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ableton-wine-setup/live-installer"
    rm -rf "$unpack_dir"
    mkdir -p "$unpack_dir"
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
        echo "!! nothing available to unpack the zip (looked for unzip, bsdtar, python3)"
    fi
    live_exe=""
    if [ "$unpack_ok" -eq 1 ]; then
        # Exactly one, as installer.sh requires of the same payload: picking the
        # first of several would choose by directory order, not by intent.
        mapfile -t payload_exes < <(find "$unpack_dir" -type f -iname '*.exe' -print | sort -V)
        if [ "${#payload_exes[@]}" -eq 1 ]; then
            live_exe="${payload_exes[0]}"
        else
            echo "!! expected exactly one installer executable in the zip, found ${#payload_exes[@]}"
        fi
    fi
    if [ "$unpack_ok" -eq 0 ]; then
        echo "!! could not unpack $(basename "$live_zip") - manual install steps are printed below"
    elif [ -z "$live_exe" ]; then
        echo "!! no single installer (.exe) inside that zip - is it the official ableton.com download?"
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
            echo "   starting the Ableton installer - from here just click through its window"
            run_installer || echo "!! the Ableton installer exited with an error - manual install steps are printed below"
            end_session
        else
            echo "   installing Ableton Live silently - takes a few minutes (ABLETON_INSTALLER_UI=1 for the installer window)"
            # Keep the display attached: the installer engines need a window
            # connection even under these switches - a headless run installs
            # nothing at all; with the display it installs silently.
            run_installer "${silent_flags[@]}" || true
            end_session
            if ! live_installed; then
                echo "!! the silent install produced no installation - starting the installer window"
                run_installer || echo "!! the Ableton installer exited with an error - manual install steps are printed below"
                end_session
            fi
        fi
        if live_installed; then live_ready=1; fi
    fi
    [ ! -e "$unpack_dir" ] || rm -rf "$unpack_dir"
fi

# Promote the fully prepared prefix only after every Wine command and gate has
# succeeded.  The original remains beside it until the outer transaction commits.
prefix_marker="$WINEPREFIX/.ableton-linux-prefix"
if [ -L "$prefix_marker" ] || { [ -e "$prefix_marker" ] && [ ! -f "$prefix_marker" ]; }; then
    echo "!! staged Wine prefix has an unsafe ownership marker" >&2
    exit 1
fi
prefix_marker_tmp="$(mktemp "$WINEPREFIX/.prefix-marker.XXXXXX")"
if ! printf 'format=1\nprefix=%s\n' "$final_prefix" > "$prefix_marker_tmp" \
   || ! chmod 600 "$prefix_marker_tmp" \
   || ! mv -T -f -- "$prefix_marker_tmp" "$prefix_marker" \
   || [ -e "$prefix_marker_tmp" ] || [ ! -f "$prefix_marker" ] || [ -L "$prefix_marker" ] \
   || ! ableton_prefix_marker_valid "$WINEPREFIX" "$final_prefix"; then
    rm -f -- "$prefix_marker_tmp"
    echo "!! could not mark the staged Wine prefix safely" >&2
    exit 1
fi
prefix_backup=absent
if [ -e "$final_prefix" ]; then
    prefix_backup="$final_prefix.transaction-${transaction_dir##*/}"
    [ ! -e "$prefix_backup" ] && [ ! -L "$prefix_backup" ] \
        || { echo "!! prefix transaction backup already exists: $prefix_backup" >&2; exit 1; }
fi
ableton_promote_directory "$WINEPREFIX" "$final_prefix" "$prefix_backup" \
    "$transaction_dir/prefix.tsv"
prefix_promoted=1
export WINEPREFIX="$final_prefix"
if [ "$own_prefix_transaction" -eq 1 ]; then
    prefix_transaction_commit "$transaction_dir"
    if ! rm -rf -- "$transaction_dir"; then
        echo "!! committed prefix transaction could not be retired" >&2
        exit 1
    fi
fi

echo
echo "OK: prefix ready at $WINEPREFIX"
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
cat <<EOF

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
prefix_promoted=0
trap - EXIT
