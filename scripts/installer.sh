#!/usr/bin/env bash
# Public installer command dispatcher.  The self-extracting .run is only a
# payload transport; all policy and component selection lives here so it can be
# tested from a repository checkout or an extracted kit.
set -euo pipefail
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
if [ -d "$here/../bin" ]; then
    kit_bin="$(cd "$here/../bin" && pwd)"
    export PATH="$kit_bin:$PATH"
fi
. "$here/lib/config.sh"
. "$here/lib/pipeasio.sh"
. "$here/lib/manifest.sh"

usage()
{
    cat <<'EOF'
Usage:
  installer install [--live-installer FILE] [--prefix PATH] [--runtime-root PATH]
                    [--live-major 11|12] [--link=off|session|always]
                    [--skip-live-install] [--yes] [--dry-run]
  installer update [--prefix PATH] [--runtime-root PATH]
                   [--link=keep|off|session|always] [--yes] [--dry-run]
  installer runtime install [--runtime-root PATH] [--yes] [--dry-run]
  installer prefix create|update [--prefix PATH] [--live-major 11|12] [--dry-run]
  installer prefix repair-live11 [--prefix PATH] [--dry-run]
  installer link enable [--mode=session|always] | disable | status
  installer uninstall [--keep-prefix|--delete-prefix] [--yes] [--dry-run]
  installer plan COMMAND ...

Compatibility aliases (deprecated, conflicts are errors):
  --runtime-only, --update, --no-launch, --no-link, --link, --uninstall,
  --prefix (only as the legacy uninstall/delete-prefix pair)

Precedence: command-line paths and values override ABLETON_* environment
variables, which override the persistent XDG config and compatibility defaults.
Noninteractive installs require --live-installer or --skip-live-install.
EOF
}

warn_compat()
{
    printf 'WARNING: %s is deprecated; use %s\n' "$1" "$2" >&2
}

command_name=""
subcommand=""
dry_run=0
assume_yes=0
skip_live=0
live_payload=""
cli_prefix=""
cli_runtime=""
cli_major=""
cli_link=""
link_mode_option=""
delete_prefix=0
keep_prefix=0
compat_mode=""
compat_link=""
compat_no_launch=0
compat_prefix=0
explicit_command=0
payload_seen=0
prefix_seen=0
runtime_seen=0
major_seen=0
mode_seen=0
link_seen=0

if [ "${1:-}" = plan ]; then
    dry_run=1
    shift
fi

case "${1:-}" in
    install|update|uninstall)
        command_name="$1"; explicit_command=1; shift ;;
    runtime|prefix|link)
        command_name="$1"; explicit_command=1; shift 
        subcommand="${1:-}"
        [ -n "$subcommand" ] || {
            echo "!! $command_name needs a subcommand" >&2; usage >&2; exit 2; }
        shift ;;
    help|--help|-h) usage; exit 0 ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --live-installer)
            [ $# -ge 2 ] || { echo "!! --live-installer needs a file" >&2; exit 2; }
            [ "$payload_seen" -eq 0 ] || { echo "!! --live-installer was specified more than once" >&2; exit 2; }
            payload_seen=1
            live_payload="$2"; shift ;;
        --prefix)
            [ "$prefix_seen" -eq 0 ] || { echo "!! --prefix was specified more than once" >&2; exit 2; }
            prefix_seen=1
            if [ $# -ge 2 ] && [[ "$2" != --* ]]; then
                cli_prefix="$2"; shift
            else
                compat_prefix=1
            fi ;;
        --prefix=*)
            [ "$prefix_seen" -eq 0 ] || { echo "!! --prefix was specified more than once" >&2; exit 2; }
            prefix_seen=1; cli_prefix="${1#*=}" ;;
        --runtime-root)
            [ $# -ge 2 ] || { echo "!! --runtime-root needs a path" >&2; exit 2; }
            [ "$runtime_seen" -eq 0 ] || { echo "!! --runtime-root was specified more than once" >&2; exit 2; }
            runtime_seen=1
            cli_runtime="$2"; shift ;;
        --runtime-root=*)
            [ "$runtime_seen" -eq 0 ] || { echo "!! --runtime-root was specified more than once" >&2; exit 2; }
            runtime_seen=1; cli_runtime="${1#*=}" ;;
        --live-major)
            [ $# -ge 2 ] || { echo "!! --live-major needs 11 or 12" >&2; exit 2; }
            [ "$major_seen" -eq 0 ] || { echo "!! --live-major was specified more than once" >&2; exit 2; }
            major_seen=1
            cli_major="$2"; shift ;;
        --live-major=*)
            [ "$major_seen" -eq 0 ] || { echo "!! --live-major was specified more than once" >&2; exit 2; }
            major_seen=1; cli_major="${1#*=}" ;;
        --link=*)
            [ "$link_seen" -eq 0 ] || { echo "!! Link policy was specified more than once" >&2; exit 2; }
            link_seen=1
            cli_link="${1#*=}" ;;
        --mode=*)
            [ "$mode_seen" -eq 0 ] || { echo "!! --mode was specified more than once" >&2; exit 2; }
            mode_seen=1; link_mode_option="${1#*=}" ;;
        --skip-live-install) skip_live=1 ;;
        --yes|-y) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        --keep-prefix) keep_prefix=1 ;;
        --delete-prefix) delete_prefix=1 ;;
        --runtime-only)
            [ -z "$compat_mode" ] || { echo "!! conflicting compatibility mode flags" >&2; exit 2; }
            compat_mode=runtime
            warn_compat --runtime-only "runtime install" ;;
        --update)
            [ -z "$compat_mode" ] || { echo "!! conflicting compatibility mode flags" >&2; exit 2; }
            compat_mode=update
            warn_compat --update update ;;
        --no-launch)
            skip_live=1
            compat_no_launch=1
            warn_compat --no-launch "--skip-live-install --link=off" ;;
        --no-link)
            [ -z "$compat_link" ] || { echo "!! --no-link conflicts with --link" >&2; exit 2; }
            compat_link=off
            warn_compat --no-link --link=off ;;
        --link)
            [ -z "$compat_link" ] || { echo "!! --link conflicts with --no-link" >&2; exit 2; }
            compat_link=session
            warn_compat --link "link enable --mode=session" ;;
        --uninstall)
            [ -z "$compat_mode" ] || { echo "!! conflicting compatibility mode flags" >&2; exit 2; }
            compat_mode=uninstall
            warn_compat --uninstall uninstall ;;
        *) echo "!! unknown installer argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$explicit_command" -eq 1 ] && [ -n "$compat_mode" ]; then
    echo "!! an explicit command conflicts with a compatibility mode flag" >&2
    exit 2
fi
# The legacy --no-launch behaviour disabled both the Live payload and Link.
# Apply its Link default after parsing so an explicit modern or compatibility
# Link option wins regardless of argument order.
if [ "$compat_no_launch" -eq 1 ] && [ "$link_seen" -eq 0 ] && [ -z "$compat_link" ]; then
    compat_link=off
fi
if [ -z "$command_name" ]; then
    case "$compat_mode" in
        runtime) command_name=runtime; subcommand=install ;;
        update) command_name=update ;;
        uninstall) command_name=uninstall ;;
        '')
            if [ "$compat_link" = session ] && [ "$skip_live" -eq 0 ] && [ -z "$live_payload" ]; then
                command_name="link"; subcommand="enable"
            else
                command_name=install
            fi ;;
    esac
fi
if [ -n "$compat_link" ]; then
    [ -z "$cli_link" ] || { echo "!! compatibility Link flag conflicts with --link=..." >&2; exit 2; }
    cli_link="$compat_link"
fi
if [ "$compat_prefix" -eq 1 ]; then
    [ "$command_name" = uninstall ] || { echo "!! legacy --prefix applies only to uninstall" >&2; exit 2; }
    delete_prefix=1
    warn_compat "--uninstall --prefix" "uninstall --delete-prefix"
fi

case "$command_name:$subcommand" in
    runtime:install|prefix:create|prefix:update|prefix:repair-live11|\
    link:enable|link:disable|link:status|install:|update:|uninstall:) ;;
    *) echo "!! invalid command: $command_name ${subcommand:-}" >&2; usage >&2; exit 2 ;;
esac
[ "$prefix_seen" -eq 0 ] || [ "$compat_prefix" -eq 1 ] || [ -n "$cli_prefix" ] || {
    echo "!! --prefix needs a nonempty path" >&2; exit 2; }
[ "$runtime_seen" -eq 0 ] || [ -n "$cli_runtime" ] || {
    echo "!! --runtime-root needs a nonempty path" >&2; exit 2; }
[ "$major_seen" -eq 0 ] || [ -n "$cli_major" ] || {
    echo "!! --live-major needs 11 or 12" >&2; exit 2; }
[ "$link_seen" -eq 0 ] || [ -n "$cli_link" ] || {
    echo "!! --link needs a policy" >&2; exit 2; }
[ "$mode_seen" -eq 0 ] || [ -n "$link_mode_option" ] || {
    echo "!! --mode needs session or always" >&2; exit 2; }
[ "$delete_prefix" -eq 0 ] || [ "$keep_prefix" -eq 0 ] || { echo "!! --keep-prefix and --delete-prefix conflict" >&2; exit 2; }
case "$cli_major" in ''|11|12) ;; *) echo "!! --live-major must be 11 or 12" >&2; exit 2 ;; esac
case "$cli_link" in ''|off|session|always|keep) ;; *) echo "!! --link must be off, session, always, or keep" >&2; exit 2 ;; esac
case "$link_mode_option" in ''|session|always) ;; *) echo "!! --mode must be session or always" >&2; exit 2 ;; esac
[ "$skip_live" -eq 0 ] || [ -z "$live_payload" ] || {
    echo "!! --skip-live-install conflicts with --live-installer" >&2; exit 2; }
[ "$cli_link" != keep ] || [ "$command_name" = update ] || {
    echo "!! --link=keep is valid only for update" >&2; exit 2; }

invalid_option()
{
    echo "!! $1 cannot be used with $command_name${subcommand:+ $subcommand}" >&2
    exit 2
}

# A selected command has one fixed option schema.  Irrelevant values are
# rejected here instead of becoming order-dependent or silent no-ops.
case "$command_name:$subcommand" in
    install:)
        [ "$delete_prefix$keep_prefix" = 00 ] || invalid_option "prefix-retention options"
        [ -z "$link_mode_option" ] || invalid_option --mode ;;
    update:)
        [ -z "$live_payload" ] || invalid_option --live-installer
        [ "$skip_live" -eq 0 ] || invalid_option --skip-live-install
        [ "$delete_prefix$keep_prefix" = 00 ] || invalid_option "prefix-retention options"
        [ -z "$link_mode_option" ] || invalid_option --mode ;;
    runtime:install)
        [ -z "$live_payload$cli_prefix$cli_major$cli_link$link_mode_option" ] || invalid_option "non-runtime options"
        [ "$skip_live$delete_prefix$keep_prefix" = 000 ] || invalid_option "non-runtime options" ;;
    prefix:create|prefix:update)
        [ -z "$live_payload$cli_link$link_mode_option" ] || invalid_option "non-prefix options"
        [ "$skip_live$delete_prefix$keep_prefix$assume_yes" = 0000 ] || invalid_option "non-prefix options" ;;
    prefix:repair-live11)
        [ -z "$live_payload$cli_runtime$cli_major$cli_link$link_mode_option" ] \
            || invalid_option "non-repair options"
        [ "$skip_live$delete_prefix$keep_prefix$assume_yes" = 0000 ] \
            || invalid_option "non-repair options" ;;
    link:enable)
        if [ -n "$cli_link" ] && { [ "$explicit_command" -eq 1 ] || [ "$compat_link" != session ]; }; then
            invalid_option --link
        fi
        [ -z "$live_payload$cli_prefix$cli_runtime$cli_major" ] || invalid_option "non-Link options"
        [ "$skip_live$delete_prefix$keep_prefix$assume_yes" = 0000 ] || invalid_option "non-Link options" ;;
    link:disable|link:status)
        [ -z "$live_payload$cli_prefix$cli_runtime$cli_major$cli_link$link_mode_option" ] || invalid_option options
        [ "$skip_live$delete_prefix$keep_prefix$assume_yes" = 0000 ] || invalid_option options ;;
    uninstall:)
        [ -z "$live_payload$cli_major$cli_link$link_mode_option" ] || invalid_option "non-uninstall options"
        [ "$skip_live" -eq 0 ] || invalid_option --skip-live-install ;;
esac

if [ -n "$cli_prefix" ]; then ABLETON_WINEPREFIX="$cli_prefix"; export ABLETON_WINEPREFIX; fi
if [ -n "$cli_runtime" ]; then ABLETON_WINE_ROOT="$cli_runtime"; export ABLETON_WINE_ROOT; fi
if [ -n "$cli_major" ]; then ABLETON_LIVE_VERSION="$cli_major"; export ABLETON_LIVE_VERSION; fi
ableton_config_init

# PR #182 briefly owned a configured custom Link binary.  Only a narrowly
# proven install of that release is migrated to the canonical managed path.
if [ "$command_name" = install ] || [ "$command_name" = update ] \
   || [ "$command_name:$subcommand" = link:enable ] \
   || [ "$command_name:$subcommand" = link:disable ]; then
    if [ "$ABLETON_LINKD" != "$ABLETON_DATA_HOME/ableton-linkd" ] \
       && ableton_pr182_custom_link_recorded "$ABLETON_LINKD"; then
        ABLETON_PR182_CUSTOM_LINKD="$ABLETON_LINKD"
        ABLETON_LINKD="$ABLETON_DATA_HOME/ableton-linkd"
        export ABLETON_PR182_CUSTOM_LINKD ABLETON_LINKD
        ableton_config_snapshot_capture
    fi
fi

prior_link="$ABLETON_LINK_MODE"
desired_link="$cli_link"
case "$command_name" in
    install) [ -n "$desired_link" ] || desired_link=session ;;
    update) [ -n "$desired_link" ] || desired_link=keep ;;
    link)
        case "$subcommand" in enable) desired_link="${link_mode_option:-session}" ;; disable) desired_link=off ;; esac ;;
esac
[ "$desired_link" != keep ] || desired_link="$prior_link"
[ -n "$desired_link" ] || desired_link="$prior_link"
case "$desired_link" in off|session|always|'') ;; *) echo "!! no persistent Link policy is available; choose --link=off|session|always" >&2; exit 2 ;; esac

resolve_payload()
{
    [ "$command_name" = install ] || return 0
    [ "$skip_live" -eq 0 ] || return 0
    if [ -n "$live_payload" ]; then
        [ -f "$live_payload" ] || { echo "!! Live installer payload not found: $live_payload" >&2; return 1; }
        live_payload="$(readlink -f -- "$live_payload")"
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "!! noninteractive install requires --live-installer FILE or --skip-live-install" >&2
        return 2
    fi
    local -a found=()
    local f base answer=""
    for f in "${ABLETON_INSTALLER_MEDIA_DIR:-$PWD}"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
        case "$base" in ableton_live*.zip|*ableton*.exe|*live*.exe) found+=("$f") ;; esac
    done
    [ "${#found[@]}" -gt 0 ] || {
        echo "!! no Live installer payload found; rerun with --live-installer FILE or --skip-live-install" >&2
        return 2
    }
    if [ "${#found[@]}" -eq 1 ]; then
        live_payload="${found[0]}"
    else
        printf 'Found multiple Live installers:\n' >&2
        local i=1
        for f in "${found[@]}"; do printf '  %s) %s\n' "$i" "$f" >&2; i=$((i+1)); done
        printf 'Choose one [1-%s] (times out after 120 seconds): ' "${#found[@]}" >&2
        read -r -t 120 answer || answer=""
        case "$answer" in ''|*[!0-9]*) echo "!! no valid payload selected" >&2; return 2 ;; esac
        [ "$answer" -ge 1 ] && [ "$answer" -le "${#found[@]}" ] || { echo "!! invalid selection" >&2; return 2; }
        live_payload="${found[$((answer-1))]}"
    fi
    live_payload="$(readlink -f -- "$live_payload")"
}

payload_major()
{
    local payload="$1" names lower majors
    lower="$(basename "$payload" | tr '[:upper:]' '[:lower:]')"
    majors=""
    case "$lower" in *live*11*) majors=11 ;; esac
    case "$lower" in *live*12*) majors="${majors:+$majors }12" ;; esac
    case "$lower" in
        *.zip)
            if command -v unzip >/dev/null 2>&1; then names="$(unzip -Z1 "$payload" 2>/dev/null | head -n 200 || true)"
            elif command -v bsdtar >/dev/null 2>&1; then names="$(bsdtar -tf "$payload" 2>/dev/null | head -n 200 || true)"
            else names=""; fi ;;
        *) names="$(head -c 8388608 -- "$payload" 2>/dev/null | strings 2>/dev/null | head -n 20000 || true)" ;;
    esac
    printf '%s\n' "$names" | grep -Eqi 'Ableton[ _-]*Live[ _-]*11' && majors="${majors:+$majors }11"
    printf '%s\n' "$names" | grep -Eqi 'Ableton[ _-]*Live[ _-]*12' && majors="${majors:+$majors }12"
    tr ' ' '\n' <<< "$majors" | sed '/^$/d' | sort -u | paste -sd' ' -
}

validate_payload_major()
{
    [ -n "$live_payload" ] || return 0
    local detected
    detected="$(payload_major "$live_payload")"
    if [ -n "${ABLETON_LIVE_VERSION:-}" ]; then
        case " $detected " in *" $ABLETON_LIVE_VERSION "*) ;;
            "  ") echo "!! cannot prove that $(basename "$live_payload") matches Live $ABLETON_LIVE_VERSION" >&2; return 2 ;;
            *) echo "!! payload appears to be Live $detected, but --live-major is $ABLETON_LIVE_VERSION" >&2; return 2 ;;
        esac
    else
        case "$detected" in
            11|12) ABLETON_LIVE_VERSION="$detected"; export ABLETON_LIVE_VERSION ;;
            *) echo "!! cannot determine one Live major from $(basename "$live_payload"); pass --live-major 11|12" >&2; return 2 ;;
        esac
    fi
}

resolve_payload
validate_payload_major

host_preflight()
{
    case "$command_name:$subcommand" in
        install:|update:|runtime:install|prefix:create|prefix:update|link:enable)
            [ "$(uname -m)" = x86_64 ] \
                || { echo "lmao :3"; } ;;
            #    || { echo "!! this command requires x86_64" >&2; return 1; } ;;
    esac
    # repair-live11 runs no bounded external command, so it does not need GNU
    # timeout.  This only helps an extracted kit: the .run header needs timeout
    # for its own payload extraction and refuses before delegating here.
    case "$command_name:$subcommand" in
        prefix:repair-live11) ;;
        *) command -v timeout >/dev/null \
            || { echo "!! GNU timeout is required" >&2; return 1; } ;;
    esac
    case "$command_name" in
        install|update|runtime)
            command -v tar >/dev/null || { echo "!! tar is required" >&2; return 1; }
            command -v zstd >/dev/null || { echo "!! zstd is required" >&2; return 1; } ;;
    esac
    case "$command_name:$subcommand" in
        install:|update:|prefix:create|prefix:update)
            command -v cabextract >/dev/null || { echo "!! cabextract is required" >&2; return 1; } ;;
    esac
}
host_preflight

# Cheap checks first: none of these needs Wine, PipeWire, or the payload.  A
# missing prefix or runtime then names itself, in the words of the command the
# user typed, instead of arriving later as an audio failure.  They also run
# before the slow payload extraction.
case "$command_name:$subcommand" in
    update:)
        [ -f "$ABLETON_WINEPREFIX/system.reg" ] || {
            echo "!! update needs an existing prefix at $ABLETON_WINEPREFIX; run install first" >&2; exit 2; } ;;
    prefix:create)
        [ ! -f "$ABLETON_WINEPREFIX/system.reg" ] || {
            echo "!! prefix already exists; use prefix update" >&2; exit 2; }
        [ -x "$ABLETON_WINE_ROOT/bin/wine" ] || {
            echo "!! no runtime at $ABLETON_WINE_ROOT; run installer runtime install first" >&2; exit 2; } ;;
    prefix:update)
        [ -f "$ABLETON_WINEPREFIX/system.reg" ] || {
            echo "!! no prefix at $ABLETON_WINEPREFIX; use prefix create" >&2; exit 2; }
        [ -x "$ABLETON_WINE_ROOT/bin/wine" ] || {
            echo "!! no runtime at $ABLETON_WINE_ROOT; run installer runtime install first" >&2; exit 2; } ;;
esac

# Gate only commands that replace the PipeASIO-bearing runtime or register it.
# Plans, help, extraction transport, Link operations, and uninstall remain
# available without a running PipeWire daemon.
#if [ "$dry_run" -eq 0 ]; then
#    pipewire_probe=""
#    case "$command_name:$subcommand" in
#        install:|update:|runtime:install)
#            pipewire_probe="$root/bin/pipewire-version-probe"
#            for pipewire_probe_candidate in \
#                "$root/bin/pipewire-version-probe" "$root/dist/pipewire-version-probe"; do
#                [ -x "$pipewire_probe_candidate" ] || continue
#                pipewire_probe="$pipewire_probe_candidate"
#                break
#            done ;;
#        prefix:create|prefix:update)
#            pipewire_probe="$ABLETON_WINE_ROOT/bin/pipewire-version-probe" ;;
#    esac
#    if [ -n "$pipewire_probe" ]; then
#        ableton_pipewire_preflight "$pipewire_probe" "changing PipeASIO"
#    fi
#fi

install_args=()
[ "$assume_yes" -eq 0 ] || install_args+=(--yes)
[ "$dry_run" -eq 0 ] || install_args+=(--dry-run)
components=()
if [ "$command_name" = install ] || [ "$command_name" = update ]; then
    components=(--runtime-only --integration-only)
    if [ "$desired_link" != off ] || [ -n "${ABLETON_PR182_CUSTOM_LINKD:-}" ]; then
        components+=(--link-assets-only)
    fi
fi

case "$command_name:$subcommand" in
    uninstall:)
        args=()
        [ "$delete_prefix" -eq 0 ] || args+=(--delete-prefix)
        [ "$keep_prefix" -eq 0 ] || args+=(--keep-prefix)
        [ "$assume_yes" -eq 0 ] || args+=(--yes)
        [ "$dry_run" -eq 0 ] || args+=(--dry-run)
        exec "$here/uninstall.sh" "${args[@]}" ;;
    link:status)
        exec "$here/setup-link.sh" status ;;
    runtime:install)
        if [ "$dry_run" -eq 1 ]; then "$here/install.sh" --runtime-only --dry-run; exit; fi ;;
    prefix:create)
        "$here/setup-prefix.sh" --validate
        if [ "$dry_run" -eq 1 ]; then
            printf 'PLAN: create prefix %s using runtime %s\n' "$ABLETON_WINEPREFIX" "$ABLETON_WINE_ROOT"
            exit
        fi ;;
    prefix:update)
        "$here/setup-prefix.sh" --refresh --validate
        if [ "$dry_run" -eq 1 ]; then printf 'PLAN: transactionally update prefix %s\n' "$ABLETON_WINEPREFIX"; exit; fi ;;
    prefix:repair-live11)
        if [ "$dry_run" -eq 1 ]; then
            printf 'PLAN: move aside stale Live 11 Max preferences in %s\n' "$ABLETON_WINEPREFIX"
            exit
        fi
        # setup-prefix owns the lock and performs only the idempotent preference
        # move for this mode.  It deliberately needs neither Wine nor PipeWire.
        exec "$here/setup-prefix.sh" --post-first-run ;;
    link:enable)
        if [ "$dry_run" -eq 1 ]; then
            "$here/install.sh" --link-assets-only --dry-run
            "$here/setup-link.sh" plan-enable "--mode=$desired_link"
            exit
        fi ;;
    link:disable)
        if [ "$dry_run" -eq 1 ]; then "$here/setup-link.sh" plan-disable; exit; fi ;;
    install:|update:)
        prefix_validate=()
        [ "$command_name" != update ] || prefix_validate+=(--refresh)
        ABLETON_RUNTIME_PENDING=1 "$here/setup-prefix.sh" "${prefix_validate[@]}" --validate
        if [ "$dry_run" -eq 1 ]; then
            "$here/install.sh" "${components[@]}" --dry-run
            printf '  transactionally %s prefix: %s\n' "$([ "$command_name" = update ] && echo update || echo create)" "$ABLETON_WINEPREFIX"
            printf '  stage prefix as a sibling, promote only after all checks, then write: %s/pipeasio/config.ini\n' \
                "${XDG_CONFIG_HOME:-$HOME/.config}"
            [ -z "$live_payload" ] || printf '  run bounded Live %s installer: %s\n' "$ABLETON_LIVE_VERSION" "$live_payload"
            printf '  write persistent resolved configuration: %s\n' "$ABLETON_CONFIG_FILE"
            if [ "$desired_link" = off ]; then
                "$here/setup-link.sh" plan-disable
            else
                "$here/setup-link.sh" plan-enable "--mode=$desired_link"
            fi
            printf '  final Link policy: %s\n' "$desired_link"
            exit
        fi ;;
esac

# Every path reaching this point performs a component, prefix, or Link
# mutation.  Child scripts inherit the locked directory descriptor.
ableton_install_lock_acquire

if [ "$command_name:$subcommand" = runtime:install ]; then
    transaction="$(mktemp -d "${TMPDIR:-/tmp}/ableton-runtime-install.XXXXXX")"
else
    ableton_mark_state_home
    mkdir -p -- "$ABLETON_STATE_HOME/transactions"
    transaction="$(mktemp -d "$ABLETON_STATE_HOME/transactions/installer.XXXXXX")"
fi
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_transaction()
{
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && ! rm -rf -- "$transaction"; then
        echo "!! failed to remove unstarted installer transaction: $transaction" >&2
    fi
    exit "$rc"
}
trap cleanup_unstarted_transaction EXIT
ABLETON_TRANSACTION_DIR="$transaction"
export ABLETON_TRANSACTION_DIR
config_backup="$transaction/config.before"
config_existed=0
if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
    { [ -f "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; } \
        && [ ! -d "$ABLETON_CONFIG_FILE" ] \
        && [ -n "$(ableton_manifest_digest "$ABLETON_CONFIG_FILE" 2>/dev/null || true)" ] || {
        echo "!! current installer configuration is unsafe" >&2
        exit 1
    }
    mkdir -p -- "$(dirname "$config_backup")"
    cp -a -- "$ABLETON_CONFIG_FILE" "$config_backup"
    config_existed=1
fi
pipeasio_config_parent="$(ableton_realpath_m "${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio")"
pipeasio_config="$pipeasio_config_parent/config.ini"
case "$pipeasio_config" in *$'\n'*|*$'\r'*|*$'\t'*)
    echo "!! PipeASIO configuration path contains a newline or tab" >&2; exit 2 ;;
esac
pipeasio_config_backup="$transaction/pipeasio-config.before"
pipeasio_config_existed=0
if [ -e "$pipeasio_config" ] || [ -L "$pipeasio_config" ]; then
    { [ -f "$pipeasio_config" ] || [ -L "$pipeasio_config" ]; } \
        && [ ! -d "$pipeasio_config" ] \
        && [ -n "$(ableton_manifest_digest "$pipeasio_config" 2>/dev/null || true)" ] || {
        echo "!! current PipeASIO configuration is unsafe" >&2
        exit 1
    }
    cp -a -- "$pipeasio_config" "$pipeasio_config_backup"
    pipeasio_config_existed=1
fi
panel_integration_existed=0
ownership_manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
if [ -r "$ownership_manifest" ] && awk -F '\t' -v b="$ABLETON_BIN_HOME/pipeasio-settings" \
    -v d="${XDG_DATA_HOME:-$HOME/.local/share}/applications/pipeasio-settings.desktop" \
    -v i="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/pipeasio.svg" \
    '$2==b || $2==d || $2==i { found=1 } END { exit !found }' "$ownership_manifest"; then
    panel_integration_existed=1
fi
transaction_complete=0
rollback_log="$transaction/rollback.log"
rollback_sink="$rollback_log"
committed_cleanup_step=""
link_transaction=0
live_unpack=""
config_post_token=""

cleanup_live_unpack()
{
    local safe
    [ -n "$live_unpack" ] || return 0
    safe="$(ableton_path_is_safe_delete_target "$live_unpack")" || return 1
    case "$(basename "$safe")" in ableton-live-installer.*) ;; *) return 1 ;; esac
    [ ! -L "$safe" ] || return 1
    rm -rf -- "$safe"
    live_unpack=""
}

# Rollback children write their diagnostics to disk, not the terminal, so a
# failed restoration leaves its reason behind instead of needing a repeat run.
rollback_log_step()
{
    printf -- '-- %s\n' "$1" >> "$rollback_sink" 2>/dev/null || true
}

rollback_all()
{
    local rc=$? restore_error="" restoration_complete=yes failure_record="$transaction/FAILURE"
    local rollback_preflight_ok=1 config_current_token="" config_prior_token=""
    trap - EXIT
    if [ "$transaction_complete" -ne 1 ]; then
        echo "!! installer transaction failed; restoring the previous component and prefix state" >&2
        # A log the installer cannot open must not stop the restoration: a
        # child redirected to an unopenable path never runs at all.
        if ! : 2>/dev/null >> "$rollback_sink"; then
            echo "!! rollback diagnostics cannot be written to $rollback_log" >&2
            rollback_sink=/dev/null
            rollback_log=""
        fi
        rollback_log_step "rollback started for $command_name${subcommand:+ $subcommand} (exit $rc)"
        rollback_log_step "prefix rollback preflight"
        if ! "$here/setup-prefix.sh" --preflight-rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="prefix rollback preflight failed"
            rollback_preflight_ok=0
        fi
        rollback_log_step "component rollback preflight"
        if ! "$here/install.sh" --preflight-rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="${restore_error}${restore_error:+; }component rollback preflight failed"
            rollback_preflight_ok=0
        fi
        [ "$link_transaction" -ne 1 ] || rollback_log_step "Link rollback preflight"
        if [ "$link_transaction" -eq 1 ] \
           && ! "$here/setup-link.sh" preflight-rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="${restore_error}${restore_error:+; }Link rollback preflight failed"
            rollback_preflight_ok=0
        fi
        if [ "$config_existed" -eq 1 ] \
           && { [ ! -f "$config_backup" ] || [ -L "$config_backup" ]; }; then
            restore_error="${restore_error}${restore_error:+; }installer configuration snapshot is unsafe"
            rollback_preflight_ok=0
        fi
        if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
            if [ -d "$ABLETON_CONFIG_FILE" ] \
               || { [ ! -f "$ABLETON_CONFIG_FILE" ] && [ ! -L "$ABLETON_CONFIG_FILE" ]; }; then
                restore_error="${restore_error}${restore_error:+; }installer configuration destination is unsafe"
                rollback_preflight_ok=0
            fi
        fi
        if [ "$rollback_preflight_ok" -eq 1 ] && [ -n "$config_post_token" ]; then
            config_current_token="$(ableton_object_token "$ABLETON_CONFIG_FILE" 2>/dev/null || true)"
            if [ "$config_existed" -eq 1 ]; then
                config_prior_token="$(ableton_object_token "$config_backup" 2>/dev/null || true)"
            else
                config_prior_token=absent
            fi
            if [ -z "$config_current_token" ] \
               || { [ "$config_current_token" != "$config_post_token" ] \
                    && [ "$config_current_token" != "$config_prior_token" ]; }; then
                restore_error="${restore_error}${restore_error:+; }installer configuration changed while the transaction was open"
                rollback_preflight_ok=0
            fi
        fi
        [ "$rollback_preflight_ok" -ne 1 ] || rollback_log_step "prefix rollback"
        if [ "$rollback_preflight_ok" -eq 1 ] \
           && ! "$here/setup-prefix.sh" --rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="prefix rollback failed"
        fi
        [ "$rollback_preflight_ok" -ne 1 ] || rollback_log_step "component rollback"
        if [ "$rollback_preflight_ok" -eq 1 ] \
           && ! "$here/install.sh" --rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="${restore_error}${restore_error:+; }component rollback failed"
        fi
        if [ "$rollback_preflight_ok" -eq 1 ] && [ "$config_existed" -eq 1 ]; then
            if ! ableton_atomic_restore_object "$config_backup" "$ABLETON_CONFIG_FILE"; then
                restore_error="${restore_error}${restore_error:+; }installer configuration restoration failed"
            fi
        elif [ "$rollback_preflight_ok" -eq 1 ] \
             && [ "$config_existed" -eq 0 ] \
             && ! rm -f -- "$ABLETON_CONFIG_FILE"; then
            restore_error="${restore_error}${restore_error:+; }installer configuration cleanup failed"
        fi
        if [ "$rollback_preflight_ok" -eq 1 ] && [ "$link_transaction" -eq 1 ]; then
            rollback_log_step "Link rollback"
            if ! "$here/setup-link.sh" rollback "$transaction" >> "$rollback_sink" 2>&1; then
                restore_error="${restore_error}${restore_error:+; }Link rollback failed"
            fi
        fi
        if [ "$rollback_preflight_ok" -eq 1 ] && ! cleanup_live_unpack; then
            restore_error="${restore_error}${restore_error:+; }temporary Live payload cleanup failed"
        fi
        [ -z "$restore_error" ] || restoration_complete=no
        printf 'command=%s %s\nexit=%s\nrestoration_complete=%s\nrestoration_error=%s\nrollback_log=%s\n' \
            "$command_name" "$subcommand" "$rc" "$restoration_complete" "$restore_error" "$rollback_log" \
            > "$failure_record" || true
        if [ "$restoration_complete" = yes ]; then
            echo "!! rollback complete; failure record: $failure_record" >&2
        else
            echo "!! installer rollback is incomplete: $restore_error" >&2
            echo "!! inspect $failure_record${rollback_log:+ and $rollback_log} before retrying" >&2
        fi
    elif [ "$rc" -ne 0 ]; then
        printf 'command=%s %s\nstatus=committed-cleanup-incomplete\nstep=%s\nexit=%s\n' \
            "$command_name" "$subcommand" "${committed_cleanup_step:-unknown}" "$rc" \
            > "$transaction/COMMITTED_CLEANUP_FAILURE"
        echo "!! installation committed, but rollback metadata or cleanup was incomplete: $transaction/COMMITTED_CLEANUP_FAILURE" >&2
    fi
    exit "$rc"
}
trap rollback_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$command_name:$subcommand" in
    install:|update:|link:enable|link:disable)
        "$here/setup-link.sh" snapshot "$transaction"
        link_transaction=1 ;;
esac

ABLETON_LINK_MODE="$desired_link"
export ABLETON_LINK_MODE
if [ "$command_name:$subcommand" != runtime:install ]; then
    config_post_token="$(ableton_expected_config_token)"
fi

case "$command_name:$subcommand" in
    runtime:install)
        "$here/install.sh" --runtime-only --transaction-dir "$transaction" "${install_args[@]}" ;;
    prefix:create)
        "$here/setup-prefix.sh" --transaction-dir "$transaction" ;;
    prefix:update)
        "$here/setup-prefix.sh" --refresh --transaction-dir "$transaction" ;;
    link:enable)
        "$here/install.sh" --link-assets-only --transaction-dir "$transaction" "${install_args[@]}"
        "$here/setup-link.sh" enable "--mode=$desired_link" ;;
    link:disable)
        if [ -n "${ABLETON_PR182_CUSTOM_LINKD:-}" ]; then
            "$here/install.sh" --link-assets-only --transaction-dir "$transaction" "${install_args[@]}"
        fi
        "$here/setup-link.sh" disable ;;
    install:|update:)
        "$here/install.sh" "${components[@]}" --transaction-dir "$transaction" "${install_args[@]}"
        if [ "$command_name" = update ]; then
            ABLETON_PREFIX_MANAGED=1 "$here/setup-prefix.sh" --refresh --transaction-dir "$transaction"
        else
            ABLETON_PREFIX_MANAGED=1 "$here/setup-prefix.sh" --transaction-dir "$transaction"
        fi ;;
esac

install_live_payload()
{
    [ -n "$live_payload" ] || return 0
    local installer="$live_payload" unpack="" lower flags=() timeout_secs extract_timeout status=0 tray seed_reg=""
    lower="$(basename "$installer" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower" = *.zip ]]; then
        unpack="$(mktemp -d "${TMPDIR:-/tmp}/ableton-live-installer.XXXXXX")"
        live_unpack="$unpack"
        extract_timeout="$(ableton_timeout_value "${ABLETON_PAYLOAD_EXTRACT_TIMEOUT:-900}" ABLETON_PAYLOAD_EXTRACT_TIMEOUT 60 7200)"
        echo "-- extracting Live installer payload (bounded to ${extract_timeout}s; extracted filenames show progress)"
        if command -v unzip >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" unzip "$installer" -d "$unpack"
        elif command -v bsdtar >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" bsdtar -xvf "$installer" -C "$unpack"
        elif command -v python3 >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" python3 -m zipfile -e "$installer" "$unpack"
        else echo "!! unzip, bsdtar, or python3 is required for a ZIP payload" >&2; return 1; fi
        mapfile -t payload_exes < <(find "$unpack" -type f -iname '*.exe' -print | sort -V)
        [ "${#payload_exes[@]}" -eq 1 ] || {
            echo "!! expected exactly one installer executable in the ZIP, found ${#payload_exes[@]}" >&2; return 1; }
        installer="${payload_exes[0]}"
    fi
    if grep -qaF '.wixburn' < <(head -c 4096 -- "$installer"); then
        flags=(/passive /norestart)
        if grep -qa 'wixtoolset' < <(head -c 4194304 -- "$installer"); then
            # WiX 4 Live 11 bundles expose no command-line switch for the
            # Windows-only Push USB audio driver. Register a high-version
            # placeholder so the bundle's own plan excludes that package.
            seed_reg="$(mktemp "$transaction/live11-driver.XXXXXX.reg")"
            cat > "$seed_reg" <<'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4]
"16A75B0B0E11E2A4A911BAE107021162"=""

[HKEY_LOCAL_MACHINE\Software\Classes\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4]
"16A75B0B0E11E2A4A911BAE107021162"=""

[HKEY_LOCAL_MACHINE\Software\Classes\Installer\Products\16A75B0B0E11E2A4A911BAE107021162]
"ProductName"="Ableton Push USB Audio Driver (ableton-linux placeholder)"
"Version"=dword:63000000

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\16A75B0B0E11E2A4A911BAE107021162\InstallProperties]
"DisplayName"="Ableton Push USB Audio Driver (ableton-linux placeholder)"
"DisplayVersion"="99.0.0"
"WindowsInstaller"=dword:00000001
EOF
            ableton_run_bounded 60 env WINEPREFIX="$ABLETON_WINEPREFIX" \
                "$ABLETON_WINE_ROOT/bin/wine" regedit /S "$seed_reg"
        fi
    elif grep -qa 'Inno Setup' < <(head -c 4194304 -- "$installer"); then
        flags=(/SILENT /SUPPRESSMSGBOXES /NORESTART '/MERGETASKS=!audiodriver')
    fi
    timeout_secs="$(ableton_timeout_value "${ABLETON_LIVE_INSTALL_TIMEOUT:-3600}" ABLETON_LIVE_INSTALL_TIMEOUT 60 14400)"
    echo "-- running the Live installer under a ${timeout_secs}s TERM→KILL watchdog"
    (
        cd "$(dirname "$installer")"
        ableton_run_bounded "$timeout_secs" env WINEPREFIX="$ABLETON_WINEPREFIX" \
            "$ABLETON_WINE_ROOT/bin/wine" "./$(basename "$installer")" "${flags[@]}"
    ) || status=$?
    if [ "$status" -ne 0 ]; then
        echo "!! Live installer failed or timed out (exit $status)" >&2
        return "$status"
    fi
    if [ -n "$seed_reg" ]; then
        for key in \
            'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4' \
            'HKLM\Software\Classes\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4'; do
            ableton_run_bounded 30 env WINEPREFIX="$ABLETON_WINEPREFIX" \
                "$ABLETON_WINE_ROOT/bin/wine" reg delete "$key" /v 16A75B0B0E11E2A4A911BAE107021162 /f >/dev/null 2>&1 || true
        done
        for key in \
            'HKLM\Software\Classes\Installer\Products\16A75B0B0E11E2A4A911BAE107021162' \
            'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\16A75B0B0E11E2A4A911BAE107021162'; do
            ableton_run_bounded 30 env WINEPREFIX="$ABLETON_WINEPREFIX" \
                "$ABLETON_WINE_ROOT/bin/wine" reg delete "$key" /f >/dev/null 2>&1 || true
        done
        rm -f -- "$seed_reg"
    fi
    for tray in AbletonPushCpl.exe tusbaudiocplapp.exe; do
        ableton_run_bounded 15 env WINEPREFIX="$ABLETON_WINEPREFIX" \
            "$ABLETON_WINE_ROOT/bin/wine" taskkill /f /im "$tray" >/dev/null 2>&1 || true
    done
    ableton_run_bounded 60 env WINEPREFIX="$ABLETON_WINEPREFIX" \
        "$ABLETON_WINE_ROOT/bin/wineserver" -w >/dev/null 2>&1 || {
            echo "!! post-installer prefix wait timed out" >&2; return 1; }
    [ -z "$unpack" ] || cleanup_live_unpack
}

if [ "$command_name" = install ]; then
    install_live_payload
fi

case "$command_name" in
    install|update)
        if [ "$desired_link" = off ]; then
            "$here/setup-link.sh" disable
        else
            "$here/setup-link.sh" enable "--mode=$desired_link"
        fi ;;
esac

if [ "$command_name:$subcommand" != runtime:install ]; then
    ableton_write_config
    [ "$(ableton_object_token "$ABLETON_CONFIG_FILE")" = "$config_post_token" ] || {
        echo "!! installed configuration does not match the resolved transaction" >&2
        exit 1
    }
fi

persist_runtime_rollback_metadata()
{
    local record="$transaction/runtime-rollback-path" rollback_path meta new_meta old_meta
    local marker marker_tmp parent base target installer_state=absent pipeasio_state=absent
    local old_moved=0
    [ -r "$record" ] || return 0
    rollback_path="$(sed -n '1p' "$record")" || return 1
    parent="$(ableton_realpath_m "$(dirname "$rollback_path")")" || return 1
    base="$(basename "$rollback_path")" || return 1
    [ "$parent" = "$(ableton_realpath_m "$(dirname "$ABLETON_WINE_ROOT")")" ] \
        && [[ "$base" = "$(basename "$ABLETON_WINE_ROOT")-rollback-"* ]] \
        && [ ! -L "$rollback_path" ] && [ -x "$rollback_path/bin/wine" ] || {
        echo "!! saved runtime rollback path is invalid" >&2
        return 1
    }
    target="$rollback_path/.ableton-linux-runtime"
    [ ! -L "$target" ] || {
        echo "!! saved runtime ownership marker is unsafe" >&2
        return 1
    }
    if [ -e "$target" ]; then
        ableton_runtime_marker_valid "$rollback_path" "$ABLETON_RUNTIME_NAME" || {
            echo "!! saved runtime ownership marker is invalid" >&2
            return 1
        }
    else
        marker_tmp="$(mktemp "$rollback_path/.runtime-marker.XXXXXX")" || return 1
        if ! printf 'format=1\nname=%s\n' "$ABLETON_RUNTIME_NAME" > "$marker_tmp" \
           || ! chmod 600 "$marker_tmp" \
           || ! mv -T -n -- "$marker_tmp" "$target" \
           || [ -e "$marker_tmp" ] \
           || ! ableton_runtime_marker_valid "$rollback_path" "$ABLETON_RUNTIME_NAME"; then
            rm -f -- "$marker_tmp"
            echo "!! could not mark the saved runtime rollback" >&2
            return 1
        fi
    fi
    meta="$rollback_path/.ableton-linux-rollback"
    if [ -e "$meta" ] || [ -L "$meta" ]; then
        [ ! -L "$meta" ] && [ -d "$meta" ] || {
            echo "!! saved runtime rollback metadata directory is unsafe" >&2
            return 1
        }
    fi
    new_meta="$(mktemp -d "$rollback_path/.ableton-linux-rollback.new.XXXXXX")" || return 1
    old_meta="$rollback_path/.ableton-linux-rollback.previous.$$"
    if [ -e "$old_meta" ] || [ -L "$old_meta" ]; then
        rmdir -- "$new_meta" 2>/dev/null || true
        echo "!! saved runtime has a conflicting rollback metadata path" >&2
        return 1
    fi
    if [ "$config_existed" -eq 1 ]; then
        if ! cp -a -- "$config_backup" "$new_meta/installer-config"; then
            rm -rf -- "$new_meta"
            echo "!! could not save the previous installer configuration" >&2
            return 1
        fi
        installer_state=present
    fi
    if [ "$pipeasio_config_existed" -eq 1 ]; then
        if ! cp -a -- "$pipeasio_config_backup" "$new_meta/pipeasio-config.ini"; then
            rm -rf -- "$new_meta"
            echo "!! could not save the previous PipeASIO configuration" >&2
            return 1
        fi
        pipeasio_state=present
    fi
    if ! {
        printf 'format=1\n'
        printf 'runtime_root=%s\n' "$ABLETON_WINE_ROOT"
        printf 'prefix=%s\n' "$ABLETON_WINEPREFIX"
        printf 'installer_config_path=%s\n' "$ABLETON_CONFIG_FILE"
        printf 'installer_config_state=%s\n' "$installer_state"
        printf 'pipeasio_config_path=%s\n' "$pipeasio_config"
        printf 'pipeasio_config_state=%s\n' "$pipeasio_state"
        printf 'panel_integration=%s\n' "$panel_integration_existed"
    } > "$new_meta/metadata" || ! chmod 600 "$new_meta/metadata"; then
        rm -rf -- "$new_meta"
        echo "!! could not write saved runtime rollback metadata" >&2
        return 1
    fi

    # Publish the complete directory as a unit.  Keep any prior generation in
    # place unless both short same-filesystem renames succeed.
    trap '' INT TERM
    if [ -d "$meta" ]; then
        if ! mv -T -n -- "$meta" "$old_meta" \
           || [ -e "$meta" ] || [ ! -d "$old_meta" ]; then
            trap 'exit 130' INT; trap 'exit 143' TERM
            rm -rf -- "$new_meta"
            echo "!! could not stage existing rollback metadata" >&2
            return 1
        fi
        old_moved=1
    fi
    if ! mv -T -n -- "$new_meta" "$meta" \
       || [ -e "$new_meta" ] || [ ! -d "$meta" ]; then
        if [ "$old_moved" -eq 1 ] && [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
            mv -T -n -- "$old_meta" "$meta" >/dev/null 2>&1 || true
        fi
        trap 'exit 130' INT; trap 'exit 143' TERM
        [ ! -e "$new_meta" ] || rm -rf -- "$new_meta"
        echo "!! could not publish saved runtime rollback metadata" >&2
        return 1
    fi
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$old_moved" -eq 1 ]; then
        rm -rf -- "$old_meta" || return 1
    fi
    marker="$rollback_path/.ableton-linux-rollback-incomplete"
    rm -f -- "$marker" || return 1
}

# Validate every cleanup domain before any one of them retires its rollback
# material.  A corrupt or concurrently changed later journal must leave all
# component, prefix, and Link snapshots available for the ordinary rollback.
if [ -n "$config_post_token" ] \
   && [ "$(ableton_object_token "$ABLETON_CONFIG_FILE" 2>/dev/null || true)" != "$config_post_token" ]; then
    echo "!! installer configuration changed while the transaction was open" >&2
    exit 1
fi
"$here/install.sh" --preflight-commit "$transaction"
"$here/setup-prefix.sh" --preflight-commit "$transaction"
if [ "$link_transaction" -eq 1 ]; then
    "$here/setup-link.sh" preflight-commit "$transaction"
fi

# Every requested component is valid and the persistent configuration is now
# coherent.  This is the transaction commit point.  The calls below only retire
# rollback snapshots/backups; a cleanup failure must not attempt restoration
# from pre-state that another cleanup call may already have discarded.
transaction_complete=1
cleanup_status=0
committed_cleanup_step="versioning the previous runtime"
"$here/install.sh" --commit "$transaction"
committed_cleanup_step="sealing runtime rollback metadata"
persist_runtime_rollback_metadata
committed_cleanup_step="retiring transaction snapshots"
if [ "$link_transaction" -eq 1 ]; then
    "$here/setup-link.sh" commit "$transaction" || cleanup_status=1
fi
"$here/setup-prefix.sh" --commit "$transaction" || cleanup_status=1
rm -f -- "$transaction/active"
trap - EXIT
if [ "$cleanup_status" -ne 0 ]; then
    printf 'command=%s %s\nstatus=committed-cleanup-incomplete\n' "$command_name" "$subcommand" \
        > "$transaction/COMMITTED_CLEANUP_FAILURE"
    echo "!! installation committed, but rollback-snapshot cleanup was incomplete: $transaction/COMMITTED_CLEANUP_FAILURE" >&2
    exit 1
fi
if ! rm -rf -- "$transaction"; then
    printf 'command=%s %s\nstatus=committed-cleanup-incomplete\nstep=retiring transaction directory\n' \
        "$command_name" "$subcommand" > "$transaction/COMMITTED_CLEANUP_FAILURE" 2>/dev/null || true
    echo "!! installation committed, but the transaction directory could not be removed: $transaction" >&2
    exit 1
fi

echo "OK: $command_name${subcommand:+ $subcommand} completed"
# runtime install writes no configuration, so it reports only what it touched.
if [ "$command_name:$subcommand" = runtime:install ]; then
    printf '  runtime: %s\n' "$ABLETON_WINE_ROOT"
else
    printf '  runtime: %s\n  prefix: %s\n  Link: %s\n' "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" "$ABLETON_LINK_MODE"
fi
