#!/usr/bin/env bash
# Public installer command dispatcher.  The self-extracting .run is only a
# payload transport; all policy and component selection lives here so it can be
# tested from a repository checkout or an extracted kit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/ui.sh"
export LC_ALL=C.UTF-8
if [ -d "$here/../bin" ]; then
    kit_bin="$(cd "$here/../bin" && pwd)"
    export PATH="$kit_bin:$PATH"
fi
. "$here/lib/config.sh"
. "$here/lib/lifecycle.sh"
. "$here/lib/pipeasio.sh"
. "$here/lib/manifest.sh"
. "$here/lib/preferences.sh"
unset ABLETON_PROJECT_BACKUP_DIR ABLETON_PROJECT_BACKUP_STAMP

usage()
{
    cat <<'EOF'
Usage:
  installer install [--live-installer FILE] [--prefix PATH] [--runtime-root PATH]
                    [--live-major 11|12] [--link=off|session|always]
                    [--audio-buffer=64|128|256|512|1024]
                    [--shortcuts=take|preserve]
                    [--dpi=auto|100|fractional|preserve]
                    [--audio-threads=auto|off|1..63] [--rt=auto|off]
                    [--power=performance|balanced|off]
                    [--skip-live-install] [--yes] [--dry-run]
  installer update [--prefix PATH] [--runtime-root PATH]
                   [--link=keep|off|session|always] [--yes] [--dry-run]
                   [--audio-buffer=64|128|256|512|1024]
                   [--shortcuts=take|preserve]
                   [--dpi=auto|100|fractional|preserve]
                   [--audio-threads=auto|off|1..63] [--rt=auto|off]
                   [--power=performance|balanced|off]
  installer runtime install [--runtime-root PATH] [--yes] [--dry-run]
  installer prefix create|update [--prefix PATH] [--live-major 11|12] [--dry-run]
  installer prefix repair-live11 [--prefix PATH] [--dry-run]
  installer link enable [--mode=session|always] | disable | status
  installer uninstall [--keep-prefix|--prefix-only|--delete-prefix] [--yes] [--dry-run]
  installer plan COMMAND ...

Compatibility aliases (deprecated, conflicts are errors):
  --runtime-only, --update, --no-launch, --no-link, --link, --uninstall,
  --prefix (only as the legacy uninstall/delete-prefix pair)

Precedence: command-line paths and values override ABLETON_* environment
variables, which override the persistent XDG config and compatibility defaults.
Noninteractive installs require --live-installer or --skip-live-install.
EOF
}

deprecated_option()
{
    ui_note d_deprecated_option "$1" "$2"
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
prefix_only=0
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
cli_audio_buffer=""
cli_shortcuts=""
cli_dpi=""
cli_audio_threads=""
cli_rt=""
cli_power=""
audio_buffer_seen=0
shortcuts_seen=0
dpi_seen=0
audio_threads_seen=0
rt_seen=0
power_seen=0

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
        --audio-buffer=*)
            [ "$audio_buffer_seen" -eq 0 ] || { echo "!! --audio-buffer was specified more than once" >&2; exit 2; }
            audio_buffer_seen=1; cli_audio_buffer="${1#*=}" ;;
        --shortcuts=*)
            [ "$shortcuts_seen" -eq 0 ] || { echo "!! --shortcuts was specified more than once" >&2; exit 2; }
            shortcuts_seen=1; cli_shortcuts="${1#*=}" ;;
        --dpi=*)
            [ "$dpi_seen" -eq 0 ] || { echo "!! --dpi was specified more than once" >&2; exit 2; }
            dpi_seen=1; cli_dpi="${1#*=}" ;;
        --audio-threads=*)
            [ "$audio_threads_seen" -eq 0 ] || { echo "!! --audio-threads was specified more than once" >&2; exit 2; }
            audio_threads_seen=1; cli_audio_threads="${1#*=}" ;;
        --rt=*)
            [ "$rt_seen" -eq 0 ] || { echo "!! --rt was specified more than once" >&2; exit 2; }
            rt_seen=1; cli_rt="${1#*=}" ;;
        --power=*)
            [ "$power_seen" -eq 0 ] || { echo "!! --power was specified more than once" >&2; exit 2; }
            power_seen=1; cli_power="${1#*=}" ;;
        --skip-live-install) skip_live=1 ;;
        --yes|-y) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        --keep-prefix) keep_prefix=1 ;;
        --prefix-only) prefix_only=1 ;;
        --delete-prefix) delete_prefix=1 ;;
        --runtime-only)
            [ -z "$compat_mode" ] || { echo "!! conflicting compatibility mode flags" >&2; exit 2; }
            compat_mode=runtime
            deprecated_option --runtime-only "runtime install" ;;
        --update)
            [ -z "$compat_mode" ] || { echo "!! conflicting compatibility mode flags" >&2; exit 2; }
            compat_mode=update
            deprecated_option --update update ;;
        --no-launch)
            skip_live=1
            compat_no_launch=1
            deprecated_option --no-launch "--skip-live-install --link=off" ;;
        --no-link)
            [ -z "$compat_link" ] || { echo "!! --no-link conflicts with --link" >&2; exit 2; }
            compat_link=off
            deprecated_option --no-link --link=off ;;
        --link)
            [ -z "$compat_link" ] || { echo "!! --link conflicts with --no-link" >&2; exit 2; }
            compat_link=session
            deprecated_option --link "link enable --mode=session" ;;
        --uninstall)
            [ -z "$compat_mode" ] || { echo "!! conflicting compatibility mode flags" >&2; exit 2; }
            compat_mode=uninstall
            deprecated_option --uninstall uninstall ;;
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
    deprecated_option "--uninstall --prefix" "uninstall --delete-prefix"
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
uninstall_scope_count=$((delete_prefix + keep_prefix + prefix_only))
[ "$uninstall_scope_count" -le 1 ] || {
    echo "!! --keep-prefix, --prefix-only, and --delete-prefix conflict" >&2
    exit 2
}
if [ "$command_name" = uninstall ] && [ "$uninstall_scope_count" -eq 0 ]; then
    keep_prefix=1
fi
case "$cli_major" in ''|11|12) ;; *) echo "!! --live-major must be 11 or 12" >&2; exit 2 ;; esac
case "$cli_link" in ''|off|session|always|keep) ;; *) echo "!! --link must be off, session, always, or keep" >&2; exit 2 ;; esac
case "$link_mode_option" in ''|session|always) ;; *) echo "!! --mode must be session or always" >&2; exit 2 ;; esac
[ "$audio_buffer_seen" -eq 0 ] || [ -n "$cli_audio_buffer" ] \
    || { echo "!! --audio-buffer needs a value" >&2; exit 2; }
[ "$shortcuts_seen" -eq 0 ] || [ -n "$cli_shortcuts" ] \
    || { echo "!! --shortcuts needs a value" >&2; exit 2; }
[ "$dpi_seen" -eq 0 ] || [ -n "$cli_dpi" ] \
    || { echo "!! --dpi needs a value" >&2; exit 2; }
[ "$audio_threads_seen" -eq 0 ] || [ -n "$cli_audio_threads" ] \
    || { echo "!! --audio-threads needs a value" >&2; exit 2; }
[ "$rt_seen" -eq 0 ] || [ -n "$cli_rt" ] \
    || { echo "!! --rt needs a value" >&2; exit 2; }
[ "$power_seen" -eq 0 ] || [ -n "$cli_power" ] \
    || { echo "!! --power needs a value" >&2; exit 2; }
case "$cli_audio_buffer" in ''|64|128|256|512|1024) ;;
    *) echo "!! --audio-buffer must be 64, 128, 256, 512, or 1024" >&2; exit 2 ;;
esac
case "$cli_shortcuts" in ''|take|preserve) ;;
    *) echo "!! --shortcuts must be take or preserve" >&2; exit 2 ;;
esac
case "$cli_dpi" in ''|auto|100|fractional|preserve) ;;
    *) echo "!! --dpi must be auto, 100, fractional, or preserve" >&2; exit 2 ;;
esac
case "$cli_audio_threads" in
    ''|auto|off) ;;
    *) [[ "$cli_audio_threads" =~ ^([1-9]|[1-5][0-9]|6[0-3])$ ]] \
        || { echo "!! --audio-threads must be auto, off, or 1 through 63" >&2; exit 2; } ;;
esac
case "$cli_rt" in ''|auto|off) ;;
    *) echo "!! --rt must be auto or off" >&2; exit 2 ;;
esac
case "$cli_power" in ''|performance|balanced|off) ;;
    *) echo "!! --power must be performance, balanced, or off" >&2; exit 2 ;;
esac
[ "$skip_live" -eq 0 ] || [ -z "$live_payload" ] || {
    echo "!! --skip-live-install conflicts with --live-installer" >&2; exit 2; }
[ "$cli_link" != keep ] || [ "$command_name" = update ] || {
    echo "!! --link=keep is valid only for update" >&2; exit 2; }

invalid_option()
{
    echo "!! $1 cannot be used with $command_name${subcommand:+ $subcommand}" >&2
    exit 2
}

if [ "$command_name" != install ] && [ "$command_name" != update ]; then
    [ "$audio_buffer_seen" -eq 0 ] || invalid_option --audio-buffer
    [ "$shortcuts_seen" -eq 0 ] || invalid_option --shortcuts
    [ "$dpi_seen" -eq 0 ] || invalid_option --dpi
    [ "$audio_threads_seen" -eq 0 ] || invalid_option --audio-threads
    [ "$rt_seen" -eq 0 ] || invalid_option --rt
    [ "$power_seen" -eq 0 ] || invalid_option --power
fi

# A selected command has one fixed option schema.  Irrelevant values are
# rejected here instead of becoming order-dependent or silent no-ops.
case "$command_name:$subcommand" in
    install:)
        [ "$delete_prefix$keep_prefix$prefix_only" = 000 ] || invalid_option "prefix-retention options"
        [ -z "$link_mode_option" ] || invalid_option --mode ;;
    update:)
        [ -z "$live_payload" ] || invalid_option --live-installer
        [ "$skip_live" -eq 0 ] || invalid_option --skip-live-install
        [ "$delete_prefix$keep_prefix$prefix_only" = 000 ] || invalid_option "prefix-retention options"
        [ -z "$link_mode_option" ] || invalid_option --mode ;;
    runtime:install)
        [ -z "$live_payload$cli_prefix$cli_major$cli_link$link_mode_option" ] || invalid_option "non-runtime options"
        [ "$skip_live$delete_prefix$keep_prefix$prefix_only" = 0000 ] || invalid_option "non-runtime options" ;;
    prefix:create|prefix:update)
        [ -z "$live_payload$cli_link$link_mode_option" ] || invalid_option "non-prefix options"
        [ "$skip_live$delete_prefix$keep_prefix$prefix_only$assume_yes" = 00000 ] || invalid_option "non-prefix options" ;;
    prefix:repair-live11)
        [ -z "$live_payload$cli_runtime$cli_major$cli_link$link_mode_option" ] \
            || invalid_option "non-repair options"
        [ "$skip_live$delete_prefix$keep_prefix$prefix_only$assume_yes" = 00000 ] \
            || invalid_option "non-repair options" ;;
    link:enable)
        if [ -n "$cli_link" ] && { [ "$explicit_command" -eq 1 ] || [ "$compat_link" != session ]; }; then
            invalid_option --link
        fi
        [ -z "$live_payload$cli_prefix$cli_runtime$cli_major" ] || invalid_option "non-Link options"
        [ "$skip_live$delete_prefix$keep_prefix$prefix_only$assume_yes" = 00000 ] || invalid_option "non-Link options" ;;
    link:disable|link:status)
        [ -z "$live_payload$cli_prefix$cli_runtime$cli_major$cli_link$link_mode_option" ] || invalid_option options
        [ "$skip_live$delete_prefix$keep_prefix$prefix_only$assume_yes" = 00000 ] || invalid_option options ;;
    uninstall:)
        [ -z "$live_payload$cli_major$cli_link$link_mode_option" ] || invalid_option "non-uninstall options"
        [ "$skip_live" -eq 0 ] || invalid_option --skip-live-install ;;
esac

# The step list is the renderer's: the action key selects it and the .run
# header, when present, has already drawn the first step.
case "$command_name:$subcommand" in
    install:) ui_action=install ;;
    update:) ui_action=update ;;
    runtime:install) ui_action=runtime ;;
    prefix:create) ui_action=prefix_create ;;
    prefix:update) ui_action=prefix_update ;;
    prefix:repair-live11) ui_action=prefix_repair ;;
    link:enable) ui_action=link_enable ;;
    link:disable) ui_action=link_disable ;;
    link:status) ui_action=link_status ;;
    uninstall:) ui_action=uninstall ;;
    *) ui_action=install ;;
esac
[ "$dry_run" -eq 0 ] || ui_action=plan
ABLETON_UI_ACTION="$ui_action"
export ABLETON_UI_ACTION

if [ -n "$cli_prefix" ]; then ABLETON_WINEPREFIX="$cli_prefix"; export ABLETON_WINEPREFIX; fi
if [ -n "$cli_runtime" ]; then ABLETON_WINE_ROOT="$cli_runtime"; export ABLETON_WINE_ROOT; fi
if [ -n "$cli_major" ]; then ABLETON_LIVE_VERSION="$cli_major"; export ABLETON_LIVE_VERSION; fi
case "$command_name:$subcommand" in
    install:|update:|runtime:install|prefix:create|prefix:update|prefix:repair-live11|\
    link:enable|link:disable)
        ABLETON_SIMPLE_PROJECT_FILES=1
        export ABLETON_SIMPLE_PROJECT_FILES ;;
esac
if [ "$dry_run" -eq 1 ]; then
    ABLETON_CONFIG_LAYOUT_ROOTS=none
else
    case "$command_name:$subcommand" in
        runtime:install) ABLETON_CONFIG_LAYOUT_ROOTS=runtime ;;
        install:|update:|prefix:create|prefix:update)
            ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix state' ;;
        prefix:repair-live11) ABLETON_CONFIG_LAYOUT_ROOTS='prefix state' ;;
        link:enable|link:disable) ABLETON_CONFIG_LAYOUT_ROOTS=none ;;
        link:status) ABLETON_CONFIG_LAYOUT_ROOTS=none ;;
        uninstall:) ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix' ;;
        *) ABLETON_CONFIG_LAYOUT_ROOTS='runtime prefix state' ;;
    esac
fi
export ABLETON_CONFIG_LAYOUT_ROOTS

# The Live installer file is chosen on the trunk, before the first step, as
# the template shows. One candidate is used as it is; several are listed
# newest first with the first as the timed default.
resolve_payload()
{
    [ "$command_name" = install ] || return 0
    [ "$skip_live" -eq 0 ] || return 0
    if [ -n "$live_payload" ]; then
        [ -f "$live_payload" ] || { echo "!! Live installer payload not found: $live_payload" >&2; return 1; }
        live_payload="$(readlink -f -- "$live_payload")"
        return 0
    fi
    local media="${ABLETON_INSTALLER_MEDIA_DIR:-$PWD}" shown f base i=1 answer seconds
    local -a found=()
    for f in "$media"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
        case "$base" in ableton_live*.zip|*ableton*.exe|*live*.exe) found+=("$f") ;; esac
    done
    [ "${#found[@]}" -gt 0 ] || {
        echo "!! $(ui_text c_none "$media") Rerun with --live-installer FILE or --skip-live-install." >&2
        return 2
    }
    mapfile -t found < <(printf '%s\n' "${found[@]}" | sort -rV)
    shown="$media"
    # shellcheck disable=SC2088 # display form, not a shell expansion
    case "$shown" in "$HOME"/*) shown="~/${shown#"$HOME"/}" ;; "$HOME") shown='~' ;; esac
    ui_blank
    if [ "${#found[@]}" -eq 1 ]; then
        ui_heading h_found_at
        ui_note c_dir "$shown"
        ui_menu_option c_item 1 "$(basename "${found[0]}")"
        live_payload="${found[0]}"
    else
        ui_heading h_found_at
        ui_note c_dir "$shown"
        ui_blank
        ui_heading h_candidates
        ui_blank
        for f in "${found[@]}"; do ui_menu_option c_item "$i" "$(basename "$f")"; i=$((i + 1)); done
        ui_blank
        ui__timeout; seconds="$UI_R"
        ui_ask c_prompt c_hint "$seconds"
        answer="${UI_ANSWER:-1}"
        case "$answer" in *[!0-9]*) echo "!! $(ui_text c_invalid)" >&2; return 2 ;; esac
        [ "$answer" -ge 1 ] && [ "$answer" -le "${#found[@]}" ] || { echo "!! $(ui_text c_invalid)" >&2; return 2; }
        live_payload="${found[$((answer-1))]}"
    fi
    ui_blank
    live_payload="$(readlink -f -- "$live_payload")"
}
resolve_payload

ui_step_begin s_validate
# Until the transaction handlers take over, an early exit still closes the
# open step as Failed.
trap 'ui_cleanup $?' EXIT
if [ "$command_name" = uninstall ]; then
    ableton_require_home
    uninstall_config_home="${ABLETON_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine}"
    uninstall_config_file="${ABLETON_CONFIG_FILE:-$uninstall_config_home/config}"
    if ! ableton_managed_config_valid "$uninstall_config_file" >/dev/null 2>&1; then
        : "${ABLETON_WINE_ROOT:=$HOME/.local/opt/$ABLETON_RUNTIME_NAME}"
        : "${ABLETON_WINEPREFIX:=$HOME/.wine-ableton}"
        export ABLETON_WINE_ROOT ABLETON_WINEPREFIX
    fi
fi
ableton_config_init repair

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

preferences_path="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/preferences"
pipeasio_config_path="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
preferences_requested=0
[ "$shortcuts_seen$dpi_seen$audio_threads_seen$rt_seen$power_seen" = 00000 ] \
    || preferences_requested=1
preferences_token=absent
pipeasio_token=absent
merged_shortcuts=take
merged_dpi=auto
merged_audio_threads=auto
merged_rt=auto
merged_power=performance
if [ "$command_name" = install ] || [ "$command_name" = update ]; then
    preferences_token="$(ableton_preferences_object_token "$preferences_path")"
    pipeasio_token="$(ableton_preferences_object_token "$pipeasio_config_path")"
    merged_preferences="$(ableton_preferences_merge "$preferences_path" \
        "$cli_shortcuts" "$cli_dpi" "$cli_audio_threads" "$cli_rt" "$cli_power")" \
        || { echo "!! persistent pre-flight settings are invalid" >&2; exit 2; }
    IFS='|' read -r merged_shortcuts merged_dpi merged_audio_threads merged_rt merged_power \
        <<< "$merged_preferences"
fi

# A coordinated first seed is part of prefix construction. Existing PipeASIO
# topology is never touched until after the core generation is known stable.
if [ "$command_name" = install ] || [ "$command_name" = update ]; then
    if [ "$pipeasio_token" = absent ]; then
        ABLETON_PIPEASIO_BUFFER_SEED="${cli_audio_buffer:-128}"
        export ABLETON_PIPEASIO_BUFFER_SEED
    fi
    if [ "$dpi_seen" -eq 1 ]; then
        ABLETON_DPI_MODE="$cli_dpi"
        export ABLETON_DPI_MODE
    fi
fi

describe_preflight_plan()
{
    [ "$audio_buffer_seen" -eq 0 ] \
        || printf 'Audio buffer: %s frames\n' "$cli_audio_buffer"
    case "$cli_shortcuts" in
        take) printf 'Keyboard shortcuts: Assign to Live\n' ;;
        preserve) printf 'Keyboard shortcuts: Preserve desktop shortcuts\n' ;;
    esac
    case "$cli_dpi" in
        auto) printf 'Display scaling: Automatic\n' ;;
        100) printf 'Display scaling: 100%%\n' ;;
        fractional) printf 'Display scaling: Fractional\n' ;;
        preserve) printf 'Display scaling: Preserve\n' ;;
    esac
    case "$cli_audio_threads" in
        auto) printf 'Audio workers: Automatic\n' ;;
        off) printf 'Audio workers: Let Live decide\n' ;;
        '') ;;
        *) printf 'Audio workers: %s\n' "$cli_audio_threads" ;;
    esac
    case "$cli_rt" in
        auto) printf 'Real-time scheduling: Automatic\n' ;;
        off) printf 'Real-time scheduling: Normal\n' ;;
    esac
    case "$cli_power" in
        performance) printf 'Power profile: Performance\n' ;;
        balanced) printf 'Power profile: Balanced\n' ;;
        off) printf "Power profile: Don't change\n" ;;
    esac
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
    ABLETON_PIPEWIRE_PREFLIGHT_CACHE=1
    ABLETON_PIPEWIRE_PREFLIGHT_DONE=0
    export ABLETON_PIPEWIRE_PREFLIGHT_CACHE ABLETON_PIPEWIRE_PREFLIGHT_DONE
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
            pipewire_probe="$ABLETON_WINE_ROOT/bin/pipewire-version-probe"
            for pipewire_probe_candidate in \
                "$ABLETON_WINE_ROOT/bin/pipewire-version-probe" \
                "$root/bin/pipewire-version-probe"; do
                [ -x "$pipewire_probe_candidate" ] || continue
                pipewire_probe="$pipewire_probe_candidate"
                break
            done ;;
    esac
    if [ -n "$pipewire_probe" ]; then
        ableton_pipewire_preflight "$pipewire_probe" "changing PipeASIO"
    fi
fi

install_args=()
[ "$assume_yes" -eq 0 ] || install_args+=(--yes)
[ "$dry_run" -eq 0 ] || install_args+=(--dry-run)
ABLETON_PROJECT_ASSUME_YES="$assume_yes"
export ABLETON_PROJECT_ASSUME_YES
components=()
if [ "$command_name" = install ] || [ "$command_name" = update ]; then
    # Runtime and prefix/registry state are the core transaction. Desktop and
    # Link integration are repaired only after that core has committed.
    components=(--runtime-only)
fi

ABLETON_INSTALLER_CONFIG_KEPT=0
write_installer_config()
{
    local tmp="" failures_before="$ABLETON_OPTIONAL_FILE_FAILURES"
    local kept_before="$ABLETON_OPTIONAL_FILES_KEPT"
    tmp="$(mktemp "${TMPDIR:-/tmp}/ableton-config.XXXXXX")" || return 1
    if ! ableton_render_config > "$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    ableton_install_project_file 600 "$tmp" "$ABLETON_CONFIG_FILE"
    rm -f -- "$tmp" 2>/dev/null || true
    [ "$ABLETON_OPTIONAL_FILES_KEPT" -eq "$kept_before" ] \
        || ABLETON_INSTALLER_CONFIG_KEPT=1
    [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] \
        && [ "$ABLETON_OPTIONAL_FILE_FAILURES" -eq "$failures_before" ]
}

case "$command_name:$subcommand" in
    uninstall:)
        args=()
        [ "$delete_prefix" -eq 0 ] || args+=(--delete-prefix)
        [ "$keep_prefix" -eq 0 ] || args+=(--keep-prefix)
        [ "$prefix_only" -eq 0 ] || args+=(--prefix-only)
        [ "$assume_yes" -eq 0 ] || args+=(--yes)
        [ "$dry_run" -eq 0 ] || args+=(--dry-run)
        ui_step_end ok
        exec "$here/uninstall.sh" "${args[@]}" ;;
    link:status)
        ui_step_end ok
        ui_step_begin s_link_status
        "$here/setup-link.sh" status
        ui_step_end ok
        exit ;;
    runtime:install)
        if [ "$dry_run" -eq 1 ]; then
            ui_step_end ok
            ui_step_begin s_plan
            "$here/install.sh" --runtime-only --dry-run
            ui_step_end ok
            exit
        fi ;;
    prefix:create)
        "$here/setup-prefix.sh" --validate
        if [ "$dry_run" -eq 1 ]; then
            ui_step_end ok
            ui_step_begin s_plan
            ui_status d_plan_prefix_create "$ABLETON_WINEPREFIX" "$ABLETON_WINE_ROOT"
            ui_step_end ok
            exit
        fi ;;
    prefix:update)
        "$here/setup-prefix.sh" --refresh --validate
        if [ "$dry_run" -eq 1 ]; then
            ui_step_end ok
            ui_step_begin s_plan
            ui_status d_plan_prefix_update "$ABLETON_WINEPREFIX"
            ui_step_end ok
            exit
        fi ;;
    prefix:repair-live11)
        if [ "$dry_run" -eq 1 ]; then
            ui_step_end ok
            ui_step_begin s_plan
            ui_status d_plan_repair_live11 "$ABLETON_WINEPREFIX"
            ui_step_end ok
            exit
        fi
        # setup-prefix owns the lock and performs only the idempotent preference
        # move for this mode.  It deliberately needs neither Wine nor PipeWire.
        ui_step_end ok
        ui_step_begin s_prefix_repair
        "$here/setup-prefix.sh" --post-first-run
        ui_step_end ok
        exit ;;
    link:enable)
        if [ "$dry_run" -eq 1 ]; then
            ui_step_end ok
            ui_step_begin s_plan
            "$here/install.sh" --link-assets-only --dry-run
            "$here/setup-link.sh" plan-enable "--mode=$desired_link"
            ui_step_end ok
            exit
        fi ;;
    link:disable)
        if [ "$dry_run" -eq 1 ]; then
            ui_step_end ok
            ui_step_begin s_plan
            "$here/setup-link.sh" plan-disable
            ui_step_end ok
            exit
        fi ;;
    install:|update:)
        prefix_validate=()
        [ "$command_name" != update ] || prefix_validate+=(--refresh)
        ABLETON_RUNTIME_PENDING=1 "$here/setup-prefix.sh" "${prefix_validate[@]}" --validate
        if [ "$dry_run" -eq 1 ]; then
            ui_step_end ok
            ui_step_begin s_plan
            "$here/install.sh" "${components[@]}" --dry-run
            "$here/install.sh" --integration-only --dry-run
            if [ "$desired_link" != off ]; then
                "$here/install.sh" --link-assets-only --dry-run
            fi
            if [ "$command_name" = update ]; then
                ui_status d_plan_prefix_update_line "$ABLETON_WINEPREFIX"
            else
                ui_status d_plan_prefix_create_line "$ABLETON_WINEPREFIX"
            fi
            describe_preflight_plan
            ui_status d_plan_pipeasio_config "${XDG_CONFIG_HOME:-$HOME/.config}"
            [ -z "$live_payload" ] || ui_status d_plan_run_live_installer "$ABLETON_LIVE_VERSION" "$live_payload"
            ui_status d_plan_save_settings "$ABLETON_CONFIG_FILE"
            if [ "$desired_link" = off ]; then
                "$here/setup-link.sh" plan-disable
            else
                "$here/setup-link.sh" plan-enable "--mode=$desired_link"
            fi
            ui_status d_plan_link_mode "$desired_link"
            ui_step_end ok
            exit
        fi ;;
esac

# Every path reaching this point performs a component, prefix, or Link
# mutation.  Child scripts inherit the locked directory descriptor.
ableton_install_lock_acquire

run_direct_link_command()
{
    local action_status=0 asset_status=0 files_ready=1 settings_ready=1
    ABLETON_SIMPLE_PROJECT_FILES=1
    export ABLETON_SIMPLE_PROJECT_FILES
    unset ABLETON_CONFIG_SNAPSHOT_PATH ABLETON_CONFIG_SNAPSHOT_TOKEN \
        ABLETON_CONFIG_SNAPSHOT_VALUES ABLETON_TRANSACTION_DIR
    ableton_prepare_project_backup_dir || true

    if [ "$subcommand" = enable ]; then
        ABLETON_INTERNAL_OPTIONAL_STATUS=1 \
            "$here/install.sh" --link-assets-only "${install_args[@]}" \
            || asset_status=$?
        case "$asset_status" in
            0) ;;
            3)
                files_ready=0
                echo "!! Some Ableton Link files could not be updated; continuing with the files that are available." >&2 \
                    || true ;;
            4)
                echo "!! Ableton Link setup was cancelled; completed file copies were kept." >&2 || true
                return 4 ;;
            *)
                files_ready=0
                echo "!! Ableton Link support files could not be fully updated; continuing with the files that are available." >&2 \
                    || true ;;
        esac
        ABLETON_LINK_MODE="$desired_link"
        export ABLETON_LINK_MODE
        ABLETON_LINK_COORDINATED=1 ABLETON_LINK_FILES_MAPPED=1 \
            "$here/setup-link.sh" enable "--mode=$desired_link" \
            || action_status=$?
        if [ "$action_status" -ne 0 ]; then
            ABLETON_LINK_MODE="$prior_link"
            export ABLETON_LINK_MODE
            echo "!! Ableton Link could not be enabled; the completed file copies were kept." >&2 \
                || true
        fi
    else
        ABLETON_LINK_COORDINATED=1 "$here/setup-link.sh" disable \
            || action_status=$?
        if [ "$action_status" -ne 0 ]; then
            ABLETON_LINK_MODE="$prior_link"
            export ABLETON_LINK_MODE
            echo "!! Ableton Link could not be disabled." >&2 || true
        else
            ABLETON_LINK_MODE=off
            export ABLETON_LINK_MODE
        fi
    fi

    if ! write_installer_config; then
        settings_ready=0
        echo "!! Ableton Link changed, but the installer could not save that setting. Run the same command again to retry." >&2 \
            || true
    fi
    [ "$action_status" -eq 0 ] || return "$action_status"
    case "$subcommand" in
        enable) ui_item_begin d_link_enabled "$ABLETON_LINK_MODE" ;;
        disable) ui_item_begin d_link_off ;;
    esac
    [ "$files_ready" -eq 1 ] || ui_warn d_link_files_retry
    [ "$ABLETON_INSTALLER_CONFIG_KEPT" -eq 0 ] || ui_warn d_settings_kept
    [ "$settings_ready" -eq 1 ] || ui_warn d_settings_retry
    ui_item_end ok
}

case "$command_name:$subcommand" in
    link:enable|link:disable)
        ui_step_end ok
        ui_step_begin s_link
        run_direct_link_command
        ui_step_end ok
        ui_step_begin s_finish_link
        ui_item_begin d_sum_command_completed "$command_name" " $subcommand"
        ui_item_end ok
        ui_step_end ok
        exit ;;
esac

if [ "$command_name:$subcommand" = runtime:install ]; then
    transaction="$(mktemp -d "${TMPDIR:-/tmp}/ableton-runtime-install.XXXXXX")" || {
        echo "!! The installer could not create temporary runtime recovery files under ${TMPDIR:-/tmp}." >&2
        exit 1
    }
else
    ableton_prepare_transactions_dir
    transaction="$(mktemp -d "$ABLETON_STATE_HOME/transactions/installer.XXXXXX")" || {
        echo "!! The installer could not create recovery files under $ABLETON_STATE_HOME/transactions." >&2
        exit 1
    }
fi
# ShellCheck does not follow function names stored in traps.
# shellcheck disable=SC2329
cleanup_unstarted_transaction()
{
    local rc=$?
    trap - EXIT
    ui_cleanup "$rc"
    if [ "$rc" -ne 0 ] && ! rm -rf -- "$transaction"; then
        echo "!! The installer stopped before making changes, and temporary files remain at $transaction." >&2
    fi
    exit "$rc"
}
trap cleanup_unstarted_transaction EXIT
ABLETON_TRANSACTION_DIR="$transaction"
export ABLETON_TRANSACTION_DIR
transaction_complete=0
rollback_log="$transaction/rollback.log"
rollback_sink="$rollback_log"
cleanup_log="$transaction/cleanup.log"
integration_ready=1
link_ready=1
settings_ready=1
cleanup_ready=1
optional_cancelled=0
link_resume_command=""
live_unpack=""

commit_preflight_settings()
{
    local current_buffer=""
    if [ "$preferences_requested" -eq 1 ]; then
        if ! ableton_preferences_write "$preferences_path" "$preferences_token" \
            "$merged_shortcuts" "$merged_dpi" "$merged_audio_threads" \
            "$merged_rt" "$merged_power"; then
            settings_ready=0
            if ! _ableton_token_matches "$preferences_path" "$preferences_token"; then
                echo "!! Launcher preferences changed while Ableton was being prepared; the newer settings were kept." >&2 || true
            elif [ -f "$preferences_path" ] && [ ! -L "$preferences_path" ] \
                 && ! ableton_preferences_valid "$preferences_path"; then
                echo "!! Launcher preferences are malformed and were not saved; repair or remove the file, then retry." >&2 || true
            else
                echo "!! Launcher preferences could not be saved; Ableton itself is ready, so rerun the installer to retry settings." >&2 || true
            fi
        fi
    fi

    if [ "$audio_buffer_seen" -eq 1 ]; then
        if [ "$pipeasio_token" = absent ]; then
            current_buffer="$(ableton_pipeasio_buffer_read "$pipeasio_config_path" 2>/dev/null || true)"
            if [ "$current_buffer" != "$cli_audio_buffer" ]; then
                settings_ready=0
                echo "!! The audio buffer configuration changed while Ableton was being prepared; the newer file was kept." >&2 || true
            fi
        elif ! ableton_pipeasio_buffer_write "$pipeasio_config_path" \
                "$pipeasio_token" "$cli_audio_buffer"; then
            settings_ready=0
            echo "!! The audio buffer configuration changed while Ableton was being prepared; the newer file was kept." >&2 || true
        fi
    fi
    return 0
}

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
    ui_cleanup "$rc"
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
        rollback_log_step "Checking ableton-linux prefix recovery"
        if ! "$here/setup-prefix.sh" --preflight-rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="ableton-linux prefix recovery could not be checked"
            rollback_preflight_ok=0
        fi
        rollback_log_step "Checking Wine runtime recovery"
        if ! "$here/install.sh" --preflight-rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="${restore_error}${restore_error:+; }Wine runtime recovery could not be checked"
            rollback_preflight_ok=0
        fi
        [ "$rollback_preflight_ok" -ne 1 ] || rollback_log_step "Restoring ableton-linux prefix"
        if [ "$rollback_preflight_ok" -eq 1 ] \
           && ! "$here/setup-prefix.sh" --rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="ableton-linux prefix could not be restored"
        fi
        [ "$rollback_preflight_ok" -ne 1 ] || rollback_log_step "Restoring Wine runtime"
        if [ "$rollback_preflight_ok" -eq 1 ] \
           && ! "$here/install.sh" --rollback "$transaction" >> "$rollback_sink" 2>&1; then
            restore_error="${restore_error}${restore_error:+; }Wine runtime could not be restored"
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

ABLETON_LINK_MODE="$desired_link"
export ABLETON_LINK_MODE

ui_step_end ok
case "$command_name:$subcommand" in
    runtime:install)
        ui_step_begin s_runtime_install
        "$here/install.sh" --runtime-only --transaction-dir "$transaction" "${install_args[@]}" ;;
    prefix:create)
        ui_step_begin s_prefix_create
        "$here/setup-prefix.sh" --transaction-dir "$transaction" ;;
    prefix:update)
        ui_step_begin s_prefix_update
        "$here/setup-prefix.sh" --refresh --transaction-dir "$transaction" ;;
    install:|update:)
        if [ "$command_name" = update ]; then
            ui_step_begin s_runtime_update
        else
            ui_step_begin s_runtime_install
        fi
        "$here/install.sh" "${components[@]}" --transaction-dir "$transaction" "${install_args[@]}"
        ui_step_end ok
        if [ "$command_name" = update ]; then
            ui_step_begin s_prefix_update
            ABLETON_PREFIX_MANAGED=1 "$here/setup-prefix.sh" --refresh --transaction-dir "$transaction"
        else
            ui_step_begin s_prefix_create
            ABLETON_PREFIX_MANAGED=1 "$here/setup-prefix.sh" --transaction-dir "$transaction"
        fi ;;
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
            ui_status d_reusing_extracted_installer "$unpack"
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
            # -o + </dev/null stop unzip hanging on a "replace? (y/n)" prompt.
            extract_live_zip()
            {
                if command -v unzip >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" unzip -oq "$installer" -d "$unpack" </dev/null
                elif command -v bsdtar >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" bsdtar -xf "$installer" -C "$unpack" </dev/null
                elif command -v python3 >/dev/null 2>&1; then ableton_run_bounded "$extract_timeout" python3 -m zipfile -e "$installer" "$unpack" </dev/null
                else echo "!! unzip, bsdtar, or python3 is required for a ZIP payload" >&2; return 1; fi
            }
            ui_run d_extract_live_installer "$extract_timeout" -- extract_live_zip || return 1
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
    run_live_installer()
    (
        if ! cd "$(dirname "$installer")"; then
            echo "!! The Live installer directory is no longer available." >&2
            exit 1
        fi
        ableton_run_bounded "$timeout_secs" env WINEPREFIX="$ABLETON_WINEPREFIX" \
            "$ABLETON_WINE_ROOT/bin/wine" "./$(basename "$installer")" "${flags[@]}"
    )
    ui_run d_run_live_installer "$timeout_secs" -- run_live_installer || status=$?
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
            ui_item_begin d_prefix_held_unknown
            while IFS="$(printf '\t')" read -r holder holder_image; do
                [ -n "$holder" ] || continue
                ui_status d_prefix_holder_entry "$holder_image" "$holder"
            done <<< "$unknown"
        else
            ui_item_begin d_prefix_held_background
        fi
        # The question is asked only when a program this project did not install is
        # holding the prefix.  A helper this project installed exits once the prefix
        # is free, and an expired wait that named nothing has no process to end.
        # --yes covers the install, not the prefix: it answers for what the
        # installer does to its own files, and a program the user is running is not
        # one of those.  A prefix a Max may be sharing is not ended without an
        # answer, so with nobody to ask the install completes and prints the command.
        if [ -z "$unknown" ] || [ "$assume_yes" -eq 1 ] || [ ! -t 0 ]; then
            ui_info d_prefix_held_hint
            ui_status d_prefix_held_command "$ABLETON_WINEPREFIX" "$ABLETON_WINE_ROOT"
            ui_item_end ok
        else
            # Leaving the programs running is the default: pressing return or
            # walking away leaves the prefix as it is.
            ui_item_end ok
            ui_question q_stop_prefix_title l q_stop_prefix_end q_stop_prefix_leave
            stop_answer="$UI_ANSWER"
            case "$stop_answer" in
                e)
                    if ableton_run_bounded 20 env WINEPREFIX="$ABLETON_WINEPREFIX" \
                        "$ABLETON_WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1; then
                        ui_info d_prefix_programs_stopped
                    else
                        echo "!! Live is installed, but the programs in its ableton-linux prefix could not be stopped." >&2 \
                            || true
                    fi ;;
                *) ui_info d_prefix_programs_left ;;
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
    ui_step_end ok
    ui_step_begin s_live
    install_live_payload
fi

finish_runtime_rollback()
{
    local record="$transaction/runtime-rollback-path" rollback_path parent base marker
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
    ableton_runtime_marker_valid "$rollback_path" "$ABLETON_RUNTIME_NAME" || {
        echo "!! saved runtime rollback has an invalid ownership marker" >&2
        return 1
    }
    marker="$rollback_path/.ableton-linux-rollback-incomplete"
    rm -f -- "$marker" || return 1
}

# Validate the core rollback records before discarding any of them.  These
# records cover only the runtime and prefix; generated desktop and Link files
# are repaired after this point and cannot invalidate the core install.
"$here/install.sh" --preflight-commit "$transaction"
"$here/setup-prefix.sh" --preflight-commit "$transaction"

# The runtime, prefix, Live installation, and registry are valid.  Nothing
# below is allowed to roll them back: the remaining work either retires old
# recovery data or rebuilds optional host integration.
transaction_complete=1
# The runtime, prefix, Live payload, and registry have crossed their final
# postconditions. Keep attempting every optional repair and cleanup step even
# when a terminal write or another advisory operation fails; the EXIT guard
# still reports one retry warning for any uncaught final status.
set +e
commit_preflight_settings
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
   && ! finish_runtime_rollback >> "$cleanup_log" 2>&1; then
    cleanup_status=1
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
unset ABLETON_TRANSACTION_DIR

# Desktop integration and Link files are deliberately outside the core
# transaction. Each fixed destination is handled once; failures never remove
# Ableton.
if [ "$command_name" = install ] || [ "$command_name" = update ]; then
    if [ "$command_name" = update ]; then
        core_outcome="Ableton is updated"
    elif [ -n "$live_payload" ]; then
        core_outcome="Ableton Live $ABLETON_LIVE_VERSION is installed"
    else
        core_outcome="The Ableton runtime and ableton-linux prefix are ready"
    fi
    ABLETON_LINK_MODE="$desired_link"
    ABLETON_SIMPLE_PROJECT_FILES=1
    export ABLETON_LINK_MODE ABLETON_SIMPLE_PROJECT_FILES
    ableton_prepare_project_backup_dir || true
    ui_step_end ok
    ui_step_begin s_launchers
    integration_status=0
    integration_components=(--integration-only)
    [ "$desired_link" = off ] || integration_components+=(--link-assets-only)
    ABLETON_INTERNAL_OPTIONAL_STATUS=1 \
        "$here/install.sh" "${integration_components[@]}" "${install_args[@]}" \
        || integration_status=$?
    case "$integration_status" in
        0) ;;
        3)
            integration_ready=0
            echo "!! $core_outcome, but some desktop files need another update. Run the installer again to retry them." >&2 \
                || true ;;
        4)
            optional_cancelled=1
            integration_ready=0
            link_ready=0
            settings_ready=0
            echo "!! $core_outcome; the remaining desktop and Link work was cancelled." >&2 \
                || true ;;
        *)
            integration_ready=0
            echo "!! $core_outcome, but its desktop shortcuts could not be updated. Run the installer again to repair them." >&2 \
                || true ;;
    esac

    ui_step_end ok
    ui_step_begin s_link_settings
    link_resume_command="$(format_link_resume_command "$desired_link")"
    if [ "$optional_cancelled" -eq 1 ]; then
        ABLETON_LINK_MODE="$prior_link"
    elif [ "$desired_link" = off ]; then
        if ABLETON_LINK_COORDINATED=1 "$here/setup-link.sh" disable; then
            ABLETON_LINK_MODE=off
            ui_item_begin d_link_off
            ui_item_end ok
        else
            link_ready=0
            ABLETON_LINK_MODE="$prior_link"
            echo "!! $core_outcome, but Link could not be turned off completely. Run the installer again to retry." >&2 \
                || true
        fi
    elif ABLETON_LINK_COORDINATED=1 ABLETON_LINK_FILES_MAPPED=1 \
         "$here/setup-link.sh" enable "--mode=$desired_link"; then
        ABLETON_LINK_MODE="$desired_link"
        ui_item_begin d_link_configured_mode "$desired_link"
        ui_item_end ok
    else
        link_ready=0
        ABLETON_LINK_MODE="$prior_link"
        echo "!! $core_outcome, but Link could not be set up. Retry with: $link_resume_command" >&2 \
            || true
    fi
    export ABLETON_LINK_MODE
    if [ "$optional_cancelled" -eq 0 ]; then
        # Link owns its requested system change. Reload its saved preference
        # before writing the final installer settings.
        unset ABLETON_CONFIG_SNAPSHOT_PATH ABLETON_CONFIG_SNAPSHOT_TOKEN \
            ABLETON_CONFIG_SNAPSHOT_VALUES
        ui_item_begin d_settings_ready
        if ! write_installer_config; then
            settings_ready=0
            echo "!! $core_outcome, but the installer could not save these settings. Run the installer again to retry." >&2 \
                || true
            ui_warn d_settings_retry
            ui_item_end fail
        elif [ "$ABLETON_INSTALLER_CONFIG_KEPT" -eq 1 ]; then
            ui_warn d_settings_kept
            ui_item_end ok
        else
            ui_item_end ok
        fi
    fi
elif [ "$command_name:$subcommand" = runtime:install ] \
     && [ "${ABLETON_CONFIG_REPAIR_NEEDED:-0}" = 1 ]; then
    if ! write_installer_config; then
        settings_ready=0
        echo "!! Wine is ready, but installer settings could not be saved. Run the same command again to retry." >&2 \
            || true
    fi
elif [ "$command_name:$subcommand" = prefix:create ] \
     || [ "$command_name:$subcommand" = prefix:update ]; then
    if ! write_installer_config; then
        settings_ready=0
        echo "!! The ableton-linux prefix is ready, but the installer could not save its location. Run the same command again to retry." >&2 \
            || true
    fi
fi

ui_step_end ok
case "$command_name:$subcommand" in
    runtime:install)
        ui_step_begin s_finish_runtime
        ui_item_begin d_sum_runtime_installed
        ui_status d_sum_runtime_path "$ABLETON_WINE_ROOT"
        ui_item_end ok ;;
    install:|update:)
        if [ "$command_name" = update ]; then
            ui_step_begin s_finish_update
            ui_item_begin d_sum_updated
        else
            ui_step_begin s_finish_install
            if [ -n "$live_payload" ]; then
                ui_item_begin d_sum_live_installed "$ABLETON_LIVE_VERSION"
            else
                ui_item_begin d_sum_runtime_prefix_ready
            fi
        fi
        ui_status d_sum_runtime_path "$ABLETON_WINE_ROOT"
        ui_status d_sum_prefix_path "$ABLETON_WINEPREFIX"
        [ "$integration_ready" -eq 1 ] || ui_warn d_sum_shortcuts_retry
        [ "$link_ready" -eq 1 ] || ui_warn d_sum_link_retry
        [ "$settings_ready" -eq 1 ] || ui_warn d_settings_retry
        [ "$cleanup_ready" -eq 1 ] || ui_warn d_sum_recovery_files_remain "$transaction"
        ui_item_end ok ;;
    prefix:create|prefix:update)
        ui_step_begin s_finish_prefix
        if [ "$subcommand" = create ]; then ui_item_begin d_sum_prefix_ready; else ui_item_begin d_sum_prefix_updated; fi
        ui_status d_sum_runtime_path "$ABLETON_WINE_ROOT"
        ui_status d_sum_prefix_path "$ABLETON_WINEPREFIX"
        [ "$settings_ready" -eq 1 ] || ui_warn d_settings_retry
        ui_item_end ok ;;
    *)
        ui_step_begin s_finish_install
        ui_item_begin d_sum_command_completed "$command_name" "${subcommand:+ $subcommand}"
        ui_status d_sum_runtime_path "$ABLETON_WINE_ROOT"
        ui_status d_sum_prefix_path "$ABLETON_WINEPREFIX"
        ui_item_end ok ;;
esac
ui_step_end ok
