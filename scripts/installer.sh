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
. "$here/lib/lifecycle.sh"
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
    printf 'WARNING: %s is deprecated; use %s\n' "$1" "$2" >&2 || true
    return 0
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
            [ "$link_seen" -eq 0 ] || { echo "!! The Ableton Link setting was specified more than once" >&2; exit 2; }
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
    echo "!! --link needs off, session, always, or keep" >&2; exit 2; }
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
if [ "$dry_run" -eq 1 ]; then
    ABLETON_CONFIG_LAYOUT_ROOTS=none
else
    case "$command_name:$subcommand" in
        runtime:install) ABLETON_CONFIG_LAYOUT_ROOTS=runtime ;;
        install:|update:|prefix:create|prefix:update)
            ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix state' ;;
        prefix:repair-live11) ABLETON_CONFIG_LAYOUT_ROOTS='prefix state' ;;
        link:enable|link:disable) ABLETON_CONFIG_LAYOUT_ROOTS='data config state' ;;
        link:status) ABLETON_CONFIG_LAYOUT_ROOTS=none ;;
        uninstall:) ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix' ;;
        *) ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix state' ;;
    esac
fi
export ABLETON_CONFIG_LAYOUT_ROOTS
ableton_config_init repair

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
case "$desired_link" in off|session|always|'') ;; *) echo "!! No saved Ableton Link setting is available; choose --link=off|session|always" >&2; exit 2 ;; esac

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
    local payload="$1" lower majors scan prefix=""
    lower="$(basename "$payload" | tr '[:upper:]' '[:lower:]')"
    majors=""
    case "$lower" in *live*11*) majors=11 ;; esac
    case "$lower" in *live*12*) majors="${majors:+$majors }12" ;; esac
    scan="$(mktemp "${TMPDIR:-/tmp}/ableton-payload-scan.XXXXXX")" || return 1
    case "$lower" in
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -Z1 "$payload" > "$scan" 2>/dev/null || { rm -f -- "$scan"; return 1; }
            elif command -v bsdtar >/dev/null 2>&1; then
                bsdtar -tf "$payload" > "$scan" 2>/dev/null || { rm -f -- "$scan"; return 1; }
            elif command -v python3 >/dev/null 2>&1; then
                python3 -m zipfile -l "$payload" > "$scan" 2>/dev/null \
                    || { rm -f -- "$scan"; return 1; }
            else
                rm -f -- "$scan"
                return 1
            fi ;;
        *)
            prefix="$(mktemp "${TMPDIR:-/tmp}/ableton-payload-prefix.XXXXXX")" \
                || { rm -f -- "$scan"; return 1; }
            if ! head -c 8388608 -- "$payload" > "$prefix" 2>/dev/null \
               || ! strings "$prefix" > "$scan" 2>/dev/null; then
                rm -f -- "$prefix" "$scan"
                return 1
            fi
            rm -f -- "$prefix" 2>/dev/null || true ;;
    esac
    if grep -Eqi 'Ableton[ _-]*Live[ _-]*11' "$scan"; then
        case " $majors " in *' 11 '*) ;; *) majors="${majors:+$majors }11" ;; esac
    fi
    if grep -Eqi 'Ableton[ _-]*Live[ _-]*12' "$scan"; then
        case " $majors " in *' 12 '*) ;; *) majors="${majors:+$majors }12" ;; esac
    fi
    rm -f -- "$scan" 2>/dev/null || true
    printf '%s\n' "$majors"
}

validate_payload_major()
{
    [ -n "$live_payload" ] || return 0
    local detected
    if ! detected="$(payload_major "$live_payload")"; then
        echo "!! cannot read $(basename "$live_payload") well enough to verify its Live version" >&2
        return 2
    fi
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
                || { echo "!! this command requires x86_64" >&2; return 1; } ;;
    esac
    # repair-live11 runs no bounded external command, so it does not need GNU
    # timeout.  This only helps an extracted kit: the .run header needs timeout
    # for its own payload extraction and refuses before delegating here.
    case "$command_name:$subcommand" in
        prefix:repair-live11) ;;
        *) command -v timeout >/dev/null \
            || { echo "!! Install GNU coreutils (the timeout command), then run the installer again." >&2; return 1; } ;;
    esac
    case "$command_name" in
        install|update|runtime)
            command -v tar >/dev/null || { echo "!! Install tar, then run the installer again." >&2; return 1; }
            command -v zstd >/dev/null || { echo "!! Install zstd, then run the installer again." >&2; return 1; } ;;
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
if [ "$dry_run" -eq 0 ]; then
    pipewire_probe=""
    case "$command_name:$subcommand" in
        install:|update:|runtime:install)
            pipewire_probe="$root/bin/pipewire-version-probe"
            for pipewire_probe_candidate in \
                "$root/bin/pipewire-version-probe" "$root/dist/pipewire-version-probe"; do
                [ -x "$pipewire_probe_candidate" ] || continue
                pipewire_probe="$pipewire_probe_candidate"
                break
            done ;;
        prefix:create|prefix:update)
            pipewire_probe="$ABLETON_WINE_ROOT/bin/pipewire-version-probe" ;;
    esac
    if [ -n "$pipewire_probe" ]; then
        ableton_pipewire_preflight "$pipewire_probe" "changing PipeASIO"
    fi
fi

install_args=()
[ "$assume_yes" -eq 0 ] || install_args+=(--yes)
[ "$dry_run" -eq 0 ] || install_args+=(--dry-run)
components=()
if [ "$command_name" = install ] || [ "$command_name" = update ]; then
    # Runtime and prefix/registry state are the core transaction. Desktop and
    # Link integration are repaired only after that core has committed.
    components=(--runtime-only)
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
        if [ "$dry_run" -eq 1 ]; then printf 'PLAN: update the Ableton Wine prefix at %s\n' "$ABLETON_WINEPREFIX"; exit; fi ;;
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
            "$here/install.sh" --integration-only --dry-run
            if [ "$desired_link" != off ]; then
                "$here/install.sh" --link-assets-only --dry-run
            fi
            printf '  %s the Ableton Wine prefix: %s\n' "$([ "$command_name" = update ] && echo Update || echo Create)" "$ABLETON_WINEPREFIX"
            printf '  configure PipeASIO: %s/pipeasio/config.ini\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
            [ -z "$live_payload" ] || printf '  run the Live %s installer: %s\n' "$ABLETON_LIVE_VERSION" "$live_payload"
            printf '  save installer settings: %s\n' "$ABLETON_CONFIG_FILE"
            if [ "$desired_link" = off ]; then
                "$here/setup-link.sh" plan-disable
            else
                "$here/setup-link.sh" plan-enable "--mode=$desired_link"
            fi
            printf '  set Ableton Link mode: %s\n' "$desired_link"
            exit
        fi ;;
esac

# Every path reaching this point performs a component, prefix, or Link
# mutation.  Child scripts inherit the locked directory descriptor.
ableton_install_lock_acquire

if [ "$command_name:$subcommand" = runtime:install ]; then
    transaction="$(mktemp -d "${TMPDIR:-/tmp}/ableton-runtime-install.XXXXXX")"
else
    ableton_prepare_transactions_dir
    transaction="$(mktemp -d "$ABLETON_STATE_HOME/transactions/installer.XXXXXX")"
fi
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_transaction()
{
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && ! rm -rf -- "$transaction"; then
        echo "!! The installer stopped before making changes, and temporary files remain at $transaction." >&2
    fi
    exit "$rc"
}
trap cleanup_unstarted_transaction EXIT
ABLETON_TRANSACTION_DIR="$transaction"
export ABLETON_TRANSACTION_DIR
config_backup="$transaction/config.before"
config_existed=0
config_rollback_state=absent
if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
    config_rollback_state=unchanged
    if [ -f "$ABLETON_CONFIG_FILE" ] && [ ! -L "$ABLETON_CONFIG_FILE" ] \
       && [ -n "$(ableton_manifest_digest "$ABLETON_CONFIG_FILE" 2>/dev/null || true)" ] \
       && cp -a -- "$ABLETON_CONFIG_FILE" "$config_backup"; then
        config_existed=1
        config_rollback_state=present
    fi
fi
pipeasio_config_parent="$(ableton_realpath_m \
    "${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio" 2>/dev/null || true)"
pipeasio_config="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
pipeasio_config_resolved=0
if [ -n "$pipeasio_config_parent" ]; then
    pipeasio_config="$pipeasio_config_parent/config.ini"
    pipeasio_config_resolved=1
fi
pipeasio_config_backup="$transaction/pipeasio-config.before"
pipeasio_config_existed=0
pipeasio_rollback_state=absent
if [ "$pipeasio_config_resolved" -ne 1 ]; then
    # Saved settings are an optional rollback convenience. A path that cannot
    # be resolved leaves the current PipeASIO settings untouched.
    pipeasio_rollback_state=unchanged
elif [ -e "$pipeasio_config" ] || [ -L "$pipeasio_config" ]; then
    pipeasio_rollback_state=unchanged
    if [ -f "$pipeasio_config" ] && [ ! -L "$pipeasio_config" ] \
       && [ -n "$(ableton_manifest_digest "$pipeasio_config" 2>/dev/null || true)" ] \
       && cp -a -- "$pipeasio_config" "$pipeasio_config_backup"; then
        pipeasio_config_existed=1
        pipeasio_rollback_state=present
    fi
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
cleanup_log="$transaction/cleanup.log"
link_transaction=0
integration_ready=1
link_ready=1
settings_ready=1
cleanup_ready=1
link_resume_command=""
live_unpack=""

format_link_resume_command()
{
    local installer_path
    if [ -n "${ABLETON_INSTALLER_PATH:-}" ]; then
        printf -v installer_path '%q' "$ABLETON_INSTALLER_PATH"
        printf 'sh %s link enable --mode=%q' "$installer_path" "$1"
    else
        printf -v installer_path '%q' "$here/installer.sh"
        printf 'bash %s link enable --mode=%q' "$installer_path" "$1"
    fi
}

cleanup_live_unpack()
{
    local safe
    [ -n "$live_unpack" ] || return 0
    safe="$(ableton_path_is_safe_delete_target "$live_unpack")" || return 1
    case "$(basename "$safe")" in ableton-live-installer.*) ;; *) return 1 ;; esac
    [ ! -L "$safe" ] || return 1
    rm -rf -- "$safe" || return 1
    [ ! -e "$safe" ] && [ ! -L "$safe" ] || return 1
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
    local rollback_preflight_ok=1 failure_record_written=0
    trap - EXIT
    # A closed terminal must not stop recovery from running. From this point
    # every recovery command and status write is checked explicitly.
    set +e
    if [ "$transaction_complete" -ne 1 ]; then
        echo "!! Installation did not finish. Restoring the changes from this attempt." >&2
        # A log the installer cannot open must not stop the restoration: a
        # child redirected to an unopenable path never runs at all.
        if ! : 2>/dev/null >> "$rollback_sink"; then
            echo "!! rollback diagnostics cannot be written to $rollback_log" >&2
            rollback_sink=/dev/null
            rollback_log=""
        fi
        rollback_log_step "Recovery started for $command_name${subcommand:+ $subcommand} (exit $rc)"
        rollback_log_step "Checking Wine prefix recovery"
        if ! "$here/setup-prefix.sh" --preflight-rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="Wine prefix recovery could not be checked"
            rollback_preflight_ok=0
        fi
        rollback_log_step "Checking Wine runtime recovery"
        if ! "$here/install.sh" --preflight-rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="${restore_error}${restore_error:+; }Wine runtime recovery could not be checked"
            rollback_preflight_ok=0
        fi
        [ "$link_transaction" -ne 1 ] || rollback_log_step "Checking Link recovery"
        if [ "$link_transaction" -eq 1 ] \
           && ! "$here/setup-link.sh" preflight-rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="${restore_error}${restore_error:+; }Link recovery could not be checked"
            rollback_preflight_ok=0
        fi
        [ "$rollback_preflight_ok" -ne 1 ] || rollback_log_step "Restoring Wine prefix"
        if [ "$rollback_preflight_ok" -eq 1 ] \
           && ! "$here/setup-prefix.sh" --rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="Wine prefix could not be restored"
        fi
        [ "$rollback_preflight_ok" -ne 1 ] || rollback_log_step "Restoring Wine runtime"
        if [ "$rollback_preflight_ok" -eq 1 ] \
           && ! "$here/install.sh" --rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="${restore_error}${restore_error:+; }Wine runtime could not be restored"
        fi
        if [ "$rollback_preflight_ok" -eq 1 ] && [ "$link_transaction" -eq 1 ]; then
            rollback_log_step "Restoring Link settings"
            if ! "$here/setup-link.sh" rollback "$transaction" >> "$rollback_sink" 2>&1; then
                restore_error="${restore_error}${restore_error:+; }Link settings could not be restored"
            fi
        fi
        if [ "$rollback_preflight_ok" -eq 1 ] && ! cleanup_live_unpack; then
            rollback_log_step "temporary Live installer files were retained at $live_unpack"
        fi
        # Domain helpers deliberately leave the coordinator marker alone.  It
        # is retired only after every rollback domain and temporary payload has
        # been restored.  If any recovery is incomplete, keep it so launchers
        # cannot self-heal managed files inside the retained evidence.
        if [ "$rollback_preflight_ok" -eq 1 ] && [ -z "$restore_error" ] \
           && ! rm -f -- "$transaction/active"; then
            restore_error="recovery status cleanup failed"
        fi
        [ -z "$restore_error" ] || restoration_complete=no
        if printf 'command=%s %s\nexit=%s\nrestoration_complete=%s\nrestoration_error=%s\nrollback_log=%s\n' \
            "$command_name" "$subcommand" "$rc" "$restoration_complete" "$restore_error" "$rollback_log" \
            > "$failure_record"; then
            failure_record_written=1
        fi
        if [ "$restoration_complete" = yes ]; then
            echo "!! Installation did not finish. The earlier installation state was restored." >&2
            [ "$failure_record_written" -eq 0 ] || echo "!! Details: $failure_record" >&2
        else
            echo "!! Installation failed, and recovery still needs attention: $restore_error" >&2
            if [ "$failure_record_written" -eq 1 ]; then
                echo "!! Save these recovery details before retrying: $failure_record${rollback_log:+ and $rollback_log}" >&2
            elif [ -n "$rollback_log" ]; then
                echo "!! Save this recovery log before retrying: $rollback_log" >&2
            fi
        fi
    elif [ "$rc" -ne 0 ]; then
        echo "!! Ableton is ready. Run the installer again to retry shortcuts, Link, or saved settings." >&2 || true
        rc=0
    fi
    exit "$rc"
}
trap rollback_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$command_name:$subcommand" in
    link:enable|link:disable)
        "$here/setup-link.sh" snapshot "$transaction"
        link_transaction=1 ;;
esac

ABLETON_LINK_MODE="$desired_link"
export ABLETON_LINK_MODE
# Child lifecycle helpers inherit both the lock and this snapshot. Refresh the
# resolved-value half after applying the requested policy; the file itself has
# not changed, so its original token remains the concurrency boundary.
ableton_config_snapshot_capture

case "$command_name:$subcommand" in
    runtime:install)
        "$here/install.sh" --runtime-only --transaction-dir "$transaction" "${install_args[@]}" ;;
    prefix:create)
        "$here/setup-prefix.sh" --transaction-dir "$transaction" ;;
    prefix:update)
        "$here/setup-prefix.sh" --refresh --transaction-dir "$transaction" ;;
    link:enable)
        "$here/install.sh" --link-assets-only --transaction-dir "$transaction" "${install_args[@]}"
        ABLETON_LINK_COORDINATED=1 "$here/setup-link.sh" enable "--mode=$desired_link" ;;
    link:disable)
        ABLETON_LINK_COORDINATED=1 "$here/setup-link.sh" disable ;;
    install:|update:)
        "$here/install.sh" "${components[@]}" --transaction-dir "$transaction" "${install_args[@]}"
        if [ "$command_name" = update ]; then
            ABLETON_PREFIX_MANAGED=1 "$here/setup-prefix.sh" --refresh --transaction-dir "$transaction"
        else
            ABLETON_PREFIX_MANAGED=1 "$here/setup-prefix.sh" --transaction-dir "$transaction"
        fi ;;
esac

# Direct Link commands save their selected mode themselves. Drop the parent's
# now-stale view of that generated file so later cleanup cannot mistake the
# child's successful write for an installation failure.
case "$command_name:$subcommand" in
    link:enable|link:disable)
        unset ABLETON_CONFIG_SNAPSHOT_PATH ABLETON_CONFIG_SNAPSHOT_TOKEN \
            ABLETON_CONFIG_SNAPSHOT_VALUES ;;
esac

live11_registry_ready()
{
    ableton_run_bounded 30 env WINEPREFIX="$ABLETON_WINEPREFIX" \
        "$ABLETON_WINE_ROOT/bin/wine" reg query 'HKLM\Software' >/dev/null 2>&1
}

live11_placeholder_present()
{
    local key
    for key in \
        'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4' \
        'HKLM\Software\Classes\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4'; do
        ableton_run_bounded 30 env WINEPREFIX="$ABLETON_WINEPREFIX" \
            "$ABLETON_WINE_ROOT/bin/wine" reg query "$key" \
            /v 16A75B0B0E11E2A4A911BAE107021162 >/dev/null 2>&1 || return 1
    done
    for key in \
        'HKLM\Software\Classes\Installer\Products\16A75B0B0E11E2A4A911BAE107021162' \
        'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\16A75B0B0E11E2A4A911BAE107021162'; do
        ableton_run_bounded 30 env WINEPREFIX="$ABLETON_WINEPREFIX" \
            "$ABLETON_WINE_ROOT/bin/wine" reg query "$key" >/dev/null 2>&1 || return 1
    done
}

live11_placeholder_absent()
{
    local key status
    live11_registry_ready || return 1
    for key in \
        'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4' \
        'HKLM\Software\Classes\Installer\UpgradeCodes\86C5CFEA462003E469588217A219FCE4'; do
        status=0
        ableton_run_bounded 30 env WINEPREFIX="$ABLETON_WINEPREFIX" \
            "$ABLETON_WINE_ROOT/bin/wine" reg query "$key" \
            /v 16A75B0B0E11E2A4A911BAE107021162 >/dev/null 2>&1 || status=$?
        [ "$status" -eq 1 ] || return 1
    done
    for key in \
        'HKLM\Software\Classes\Installer\Products\16A75B0B0E11E2A4A911BAE107021162' \
        'HKLM\Software\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\16A75B0B0E11E2A4A911BAE107021162'; do
        status=0
        ableton_run_bounded 30 env WINEPREFIX="$ABLETON_WINEPREFIX" \
            "$ABLETON_WINE_ROOT/bin/wine" reg query "$key" >/dev/null 2>&1 || status=$?
        [ "$status" -eq 1 ] || return 1
    done
}

live_install_result_valid()
{
    local major="$1" exe live_found=0 base="$ABLETON_WINEPREFIX/drive_c/ProgramData/Ableton"
    for exe in "$base"/"Live $major"*/Program/"Ableton Live $major"*.exe; do
        [ -e "$exe" ] || [ -L "$exe" ] || continue
        if [ ! -f "$exe" ] || [ -L "$exe" ]; then
            echo "!! Live created an unsafe executable path: $exe" >&2
            return 1
        fi
        live_found=1
    done
    [ "$live_found" -eq 1 ] || {
        echo "!! The Live installer exited without installing Ableton Live $major in the selected prefix." >&2
        return 1
    }
}

install_live_payload()
{
    [ -n "$live_payload" ] || return 0
    local installer="$live_payload" unpack="" stale_unpack="" lower flags=() timeout_secs extract_timeout status=0 seed_reg=""
    local zip_name zip_bytes zip_fingerprint zip_kb need_kb avail_kb
    local stop_answer="" holders="" unknown="" holder holder_image wait_status=0
    local exe_inventory="" exe_inventory_sorted="" signature="" key
    local -a payload_exes=()
    lower="$(basename "$installer" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower" = *.zip ]]; then
        unpack="${ABLETON_PAYLOAD_UNPACK_DIR:-$(dirname "$installer")}/ableton-live-installer.d"
        # Fingerprint the *source* zip (name + byte size) so a leftover payload
        # from a different zip can't be reused. Reusing a stale dir used to
        # resolve e.g. a Lite zip to "Ableton Live 12 Suite Installer.exe".
        zip_name="$(basename "$installer")"
        zip_bytes="$(stat -c %s -- "$installer" 2>/dev/null || wc -c < "$installer" 2>/dev/null || echo 0)"
        zip_fingerprint="$zip_name $zip_bytes"
        if [ -f "$unpack/.extracted" ] && [ "$(cat "$unpack/.extracted" 2>/dev/null)" = "$zip_fingerprint" ]; then
            echo "-- Reusing the extracted Live installer at $unpack" || true
        else
            live_unpack="$unpack"
            if cleanup_live_unpack; then
                mkdir -p -- "$unpack" || { echo "!! cannot create $unpack" >&2; return 1; }
            else
                # Old extraction data is disposable. If its permissions or
                # shape prevent removal, use a new private directory rather
                # than turning our own cache into an installation gate.
                stale_unpack="$unpack"
                unpack="$(mktemp -d "${TMPDIR:-/tmp}/ableton-live-installer.XXXXXX")" \
                    || { echo "!! cannot create a temporary directory for the Live installer" >&2; return 1; }
                live_unpack="$unpack"
            fi
            if [ ! -w "$unpack" ]; then
                echo "!! $unpack is not writable; set ABLETON_PAYLOAD_UNPACK_DIR to a writable location" >&2
                return 1
            fi
            # Need headroom: the unpacked payload can exceed the zip's own size.
            if command -v df >/dev/null 2>&1; then
                zip_kb=$(( zip_bytes / 1024 )); need_kb=$(( zip_kb * 3 / 2 ))
                if ! avail_kb="$(df -Pk -- "$unpack" 2>/dev/null | awk 'NR==2{print $4}')"; then
                    avail_kb=""
                fi
                case "$avail_kb" in
                    ''|*[!0-9]*) ;; # no usable df figure; skip the guard
                    *) [ "$avail_kb" -ge "$need_kb" ] || {
                        echo "!! only $((avail_kb/1024)) MB free at $unpack; unpacking a $((zip_kb/1024)) MB zip needs ~$((need_kb/1024)) MB" >&2
                        return 1; } ;;
                esac
            fi
            extract_timeout="$(ableton_timeout_value "${ABLETON_PAYLOAD_EXTRACT_TIMEOUT:-900}" ABLETON_PAYLOAD_EXTRACT_TIMEOUT 60 7200)"
            echo "-- Extracting the Live installer (up to ${extract_timeout}s)" || true
            # -o + </dev/null stop unzip hanging on a "replace? (y/n)" prompt.
            if command -v unzip >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" unzip -oq "$installer" -d "$unpack" </dev/null
            elif command -v bsdtar >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" bsdtar -xf "$installer" -C "$unpack" </dev/null
            elif command -v python3 >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" python3 -m zipfile -e "$installer" "$unpack" </dev/null
            else echo "!! unzip, bsdtar, or python3 is required for a ZIP payload" >&2; return 1; fi
            printf '%s\n' "$zip_fingerprint" > "$unpack/.extracted" 2>/dev/null || true
        fi
        live_unpack="$unpack"
        exe_inventory="$(mktemp "$transaction/live-exes.XXXXXX")" || return 1
        exe_inventory_sorted="$(mktemp "$transaction/live-exes-sorted.XXXXXX")" || return 1
        if ! find "$unpack" -type f -iname '*.exe' -print0 > "$exe_inventory" \
           || ! sort -zV "$exe_inventory" > "$exe_inventory_sorted"; then
            echo "!! The extracted Live installer could not be checked completely." >&2
            return 1
        fi
        mapfile -d '' -t payload_exes < "$exe_inventory_sorted"
        rm -f -- "$exe_inventory" "$exe_inventory_sorted" 2>/dev/null || true
        [ "${#payload_exes[@]}" -eq 1 ] || {
            echo "!! expected exactly one installer executable in the ZIP, found ${#payload_exes[@]}" >&2; return 1; }
        installer="${payload_exes[0]}"
    fi
    signature="$(mktemp "$transaction/live-installer-signature.XXXXXX")" || return 1
    if ! head -c 4194304 -- "$installer" > "$signature" 2>/dev/null; then
        echo "!! The Live installer could not be read completely." >&2
        return 1
    fi
    if grep -qaF '.wixburn' "$signature"; then
        flags=(/passive /norestart)
        if grep -qa 'wixtoolset' "$signature"; then
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
            if ! live11_registry_ready; then
                echo "!! The Wine registry could not be checked before installing Live." >&2
                return 1
            fi
            ableton_run_bounded 60 env WINEPREFIX="$ABLETON_WINEPREFIX" \
                "$ABLETON_WINE_ROOT/bin/wine" regedit /S "$seed_reg"
            if ! live11_placeholder_present; then
                echo "!! The temporary Live 11 driver block was not written to the Wine registry." >&2
                return 1
            fi
        fi
    elif grep -qa 'Inno Setup' "$signature"; then
        flags=(/SILENT /SUPPRESSMSGBOXES /NORESTART '/MERGETASKS=!audiodriver')
    fi
    rm -f -- "$signature" 2>/dev/null || true
    timeout_secs="$(ableton_timeout_value "${ABLETON_LIVE_INSTALL_TIMEOUT:-3600}" ABLETON_LIVE_INSTALL_TIMEOUT 60 14400)"
    echo "-- Running the Live installer (up to ${timeout_secs}s)" || true
    (
        if ! cd "$(dirname "$installer")"; then
            echo "!! The Live installer directory is no longer available." >&2
            exit 1
        fi
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
        if ! live11_placeholder_absent; then
            echo "!! The temporary Live 11 driver block is still present in the Wine registry." >&2
            return 1
        fi
        rm -f -- "$seed_reg" 2>/dev/null \
            || echo "!! Live is installed, but a temporary installer file could not be removed: $seed_reg" >&2 \
            || true
    fi
    live_install_result_valid "$ABLETON_LIVE_VERSION" || return 1

    # The agents an install leaves behind are ended by name first, because that is
    # what removes the cause: Live 12's WebView2 updater cannot validate its COM
    # registration under Wine, so it parks in Core::DoRun and holds the wineserver
    # for the rest of the login session, and Live 11 leaves the Push driver's tray
    # applet from a Startup shortcut.  Wine resolves a process to its long image
    # name, so the list matches the applet through its 8.3 path too.  Wine's own
    # processes exit once the last client goes, so the server needs no signal.
    ableton_stop_leftover_agents \
        || echo "!! Live is installed, but one of its background helpers could not be stopped." >&2 \
        || true
    ableton_prefix_wait_progress || wait_status=$?
    if [ "$wait_status" -eq 124 ] || [ "$wait_status" -eq 137 ]; then
        # Named before anything is decided: once the prefix is ended there is no
        # process left to read an image name from, and the image name is the only
        # part of this a bug report can carry.
        holders="$(ableton_prefix_holders 2>/dev/null)" || holders=""
        unknown="$(printf '%s\n' "$holders" | ableton_unknown_holders 2>/dev/null)" \
            || unknown=""
        # The unknown set, not every holder: naming an agent the step just ended
        # and then saying nothing needs to be done reads as a contradiction.
        if [ -n "$unknown" ]; then
            echo "-- The Live installer finished, but a program is still using its Wine prefix:" \
                || true
            while IFS="$(printf '\t')" read -r holder holder_image; do
                [ -n "$holder" ] || continue
                printf '   %s (pid %s)\n' "$holder_image" "$holder" || true
            done <<< "$unknown"
        else
            echo "-- The Live installer finished; a background program is still using its Wine prefix." \
                || true
        fi
        # The question is asked only when a program this project did not install is
        # holding the prefix.  A helper this project installed exits once the prefix
        # is free, and an expired wait that named nothing has no process to end.
        # --yes covers the install, not the prefix: it answers for what the
        # installer does to its own files, and a program the user is running is not
        # one of those.  A prefix a Max may be sharing is not ended without an
        # answer, so with nobody to ask the install completes and prints the command.
        if [ -z "$unknown" ] || [ "$assume_yes" -eq 1 ] || [ ! -t 0 ]; then
            echo "-- You can leave it running. To stop every program in the prefix instead, run:" \
                || true
            printf '   WINEPREFIX=%s %s/bin/wineserver -k\n' \
                "$ABLETON_WINEPREFIX" "$ABLETON_WINE_ROOT" || true
        else
            # Default no, and a timed read that falls back to it: pressing return or
            # walking away leaves the prefix as it is.
            printf 'End every program in the prefix now? [y/N] ' >&2 || true
            read -r -t 60 stop_answer || stop_answer=""
            case "$stop_answer" in
                [yY]*)
                    if ableton_run_bounded 20 env WINEPREFIX="$ABLETON_WINEPREFIX" \
                        "$ABLETON_WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1; then
                        echo "-- stopped the programs in the prefix" || true
                    else
                        echo "!! Live is installed, but the programs in its Wine prefix could not be stopped." >&2 \
                            || true
                    fi ;;
                *)
                    echo "-- left them running; the next update may ask you to close them" \
                        || true ;;
            esac
        fi
    elif [ "$wait_status" -ne 0 ]; then
        echo "!! Live is installed, but Wine could not be checked afterward (exit $wait_status)." >&2 \
            || true
    fi
    if [ -n "$unpack" ] && ! cleanup_live_unpack; then
        echo "!! Live is installed, but its extracted installer files could not be removed: $unpack" >&2 \
            || true
    fi
    if [ -n "$stale_unpack" ] \
       && { [ -e "$stale_unpack" ] || [ -L "$stale_unpack" ]; }; then
        echo "!! Live is installed. Older extracted installer files remain at $stale_unpack." >&2 \
            || true
    fi
}

if [ "$command_name" = install ]; then
    install_live_payload
fi

persist_runtime_rollback_metadata()
{
    local record="$transaction/runtime-rollback-path" rollback_path meta new_meta old_meta
    local marker marker_tmp parent base target installer_state="$config_rollback_state"
    local pipeasio_state="$pipeasio_rollback_state"
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

# Validate the core rollback records before discarding any of them.  These
# records cover only the runtime and prefix; generated desktop and Link files
# are repaired after this point and cannot invalidate the core install.
"$here/install.sh" --preflight-commit "$transaction"
"$here/setup-prefix.sh" --preflight-commit "$transaction"
if [ "$link_transaction" -eq 1 ]; then
    "$here/setup-link.sh" preflight-commit "$transaction"
fi

# The runtime, prefix, Live installation, and registry are valid.  Nothing
# below is allowed to roll them back: the remaining work either retires old
# recovery data or rebuilds optional host integration.
transaction_complete=1
# The runtime, prefix, Live payload, and registry have crossed their final
# postconditions. Keep attempting every optional repair and cleanup step even
# when a terminal write or another advisory operation fails; the EXIT guard
# still reports one retry warning for any uncaught final status.
set +e
cleanup_status=0
component_commit_ok=1
core_marker_ready=1
prefix_core_marker_ready=1
ableton_mark_transaction_core_complete "$transaction" || core_marker_ready=0
if [ -d "$transaction/prefix-host" ] && [ ! -L "$transaction/prefix-host" ]; then
    ableton_mark_transaction_core_complete "$transaction/prefix-host" \
        || prefix_core_marker_ready=0
fi
if ! : > "$cleanup_log"; then
    cleanup_log=/dev/null
fi
if ! "$here/install.sh" --commit "$transaction" >> "$cleanup_log" 2>&1; then
    component_commit_ok=0
    cleanup_status=1
fi
if [ "$component_commit_ok" -eq 1 ] \
   && ! persist_runtime_rollback_metadata >> "$cleanup_log" 2>&1; then
    cleanup_status=1
fi
if [ "$link_transaction" -eq 1 ]; then
    "$here/setup-link.sh" commit "$transaction" >> "$cleanup_log" 2>&1 || cleanup_status=1
fi
"$here/setup-prefix.sh" --commit "$transaction" >> "$cleanup_log" 2>&1 || cleanup_status=1
if ! rm -f -- "$transaction/active"; then
    cleanup_status=1
fi
if [ "$cleanup_status" -eq 0 ]; then
    if ! rm -rf -- "$transaction" || [ -e "$transaction" ] || [ -L "$transaction" ]; then
        cleanup_status=1
    fi
fi
if [ "$cleanup_status" -ne 0 ]; then
    cleanup_ready=0
    echo "!! The install is ready, but old recovery files could not be removed. They were kept at $transaction." >&2 \
        || true
    if { [ "$core_marker_ready" -eq 0 ] \
         && { [ -e "$transaction/active" ] || [ -L "$transaction/active" ]; }; } \
       || { [ "$core_marker_ready" -eq 0 ] \
            && [ "$prefix_core_marker_ready" -eq 0 ] \
            && { [ -e "$transaction/prefix-host/active" ] \
                 || [ -L "$transaction/prefix-host/active" ]; }; }; then
        echo "!! Keep those files and report this cleanup problem before launching Live." >&2 \
            || true
    fi
fi

# Desktop integration and Link are deliberately outside the core transaction.
# Their files belong to this project and are replaced authoritatively on every
# run, so a later run is the repair path; failure here never removes Ableton.
if [ "$command_name" = install ] || [ "$command_name" = update ]; then
    if [ "$command_name" = update ]; then
        core_outcome="Ableton is updated"
    elif [ -n "$live_payload" ]; then
        core_outcome="Ableton Live $ABLETON_LIVE_VERSION is installed"
    else
        core_outcome="The Ableton runtime and Wine prefix are ready"
    fi
    ABLETON_LINK_MODE="$desired_link"
    export ABLETON_LINK_MODE
    integration_status=0
    ABLETON_INTERNAL_OPTIONAL_STATUS=1 \
        "$here/install.sh" --integration-only "${install_args[@]}" \
        || integration_status=$?
    case "$integration_status" in
        0) ;;
        3)
            integration_ready=0
            echo "!! $core_outcome, but some desktop files need another update. Run the installer again to retry them." >&2 \
                || true ;;
        *)
            integration_ready=0
            echo "!! $core_outcome, but its desktop shortcuts could not be updated. Run the installer again to repair them." >&2 \
                || true ;;
    esac

    link_resume_command="$(format_link_resume_command "$desired_link")"
    if [ "$desired_link" = off ]; then
        if ABLETON_LINK_COORDINATED=1 "$here/setup-link.sh" disable; then
            ABLETON_LINK_MODE=off
        else
            link_ready=0
            ABLETON_LINK_MODE="$prior_link"
            echo "!! $core_outcome, but Link could not be turned off completely. Run the installer again to retry." >&2 \
                || true
        fi
    elif "$here/install.sh" --link-assets-only "${install_args[@]}" \
         && ABLETON_LINK_COORDINATED=1 "$here/setup-link.sh" enable "--mode=$desired_link"; then
        ABLETON_LINK_MODE="$desired_link"
    else
        link_ready=0
        ABLETON_LINK_MODE="$prior_link"
        echo "!! $core_outcome, but Link could not be set up. Retry with: $link_resume_command" >&2 \
            || true
    fi
    export ABLETON_LINK_MODE
    # Link owns its own requested system change. Its generated preference file
    # is safe to reload and replace; a stale parent checksum must not add a
    # second failure path after Link has already finished.
    unset ABLETON_CONFIG_SNAPSHOT_PATH ABLETON_CONFIG_SNAPSHOT_TOKEN \
        ABLETON_CONFIG_SNAPSHOT_VALUES
    if ! ableton_write_config; then
        settings_ready=0
        echo "!! $core_outcome, but the installer could not save these settings. Run the installer again to retry." >&2 \
            || true
    fi
elif [ "$command_name:$subcommand" = runtime:install ] \
     && [ "${ABLETON_CONFIG_REPAIR_NEEDED:-0}" = 1 ]; then
    if ! ableton_write_config; then
        settings_ready=0
        echo "!! Wine is ready, but installer settings could not be saved. Run the same command again to retry." >&2 \
            || true
    fi
elif [ "$command_name:$subcommand" = prefix:create ] \
     || [ "$command_name:$subcommand" = prefix:update ]; then
    if ! ableton_write_config; then
        settings_ready=0
        echo "!! The Wine prefix is ready, but the installer could not save its location. Run the same command again to retry." >&2 \
            || true
    fi
fi

case "$command_name:$subcommand" in
    runtime:install)
        echo "OK: the Wine runtime is installed"
        printf '  runtime: %s\n' "$ABLETON_WINE_ROOT" ;;
    install:|update:)
        printf 'OK: %s\n' "$core_outcome"
        printf '  runtime: %s\n  prefix: %s\n' "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX"
        if [ "$integration_ready" -eq 1 ]; then
            printf '  desktop shortcuts: ready\n'
        else
            printf '  desktop shortcuts: retry needed\n'
        fi
        if [ "$link_ready" -eq 1 ]; then
            printf '  Link: %s\n' "$ABLETON_LINK_MODE"
        else
            printf '  Link: unchanged; setup can be retried\n'
        fi
        if [ "$settings_ready" -eq 1 ]; then
            printf '  saved settings: ready\n'
        else
            printf '  saved settings: retry needed\n'
        fi
        if [ "$cleanup_ready" -eq 1 ]; then
            printf '  old recovery files: removed\n'
        else
            printf '  old recovery files: remain at %s\n' "$transaction"
        fi ;;
    prefix:create)
        echo "OK: the Wine prefix is ready"
        printf '  runtime: %s\n  prefix: %s\n' "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX"
        [ "$settings_ready" -eq 1 ] || printf '  saved settings: retry needed\n' ;;
    prefix:update)
        echo "OK: the Wine prefix is updated"
        printf '  runtime: %s\n  prefix: %s\n' "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX"
        [ "$settings_ready" -eq 1 ] || printf '  saved settings: retry needed\n' ;;
    link:enable)
        printf 'OK: Ableton Link is enabled (%s)\n' "$ABLETON_LINK_MODE" ;;
    link:disable)
        echo "OK: Ableton Link is off" ;;
    *)
        echo "OK: requested change completed"
        printf '  runtime: %s\n  prefix: %s\n' "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" ;;
esac
