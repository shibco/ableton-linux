#!/bin/sh
# shellcheck shell=bash
# Ableton Linux self-extracting installer transport. The wrapper reports the
# host, records the complete run, and unpacks the embedded kit. Installation
# policy remains in the packaged scripts/installer.sh. Everything on screen is
# drawn by the renderer inlined below at build time (scripts/lib/ui.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
@UI_LIB@
export LC_ALL=C.UTF-8
started_at=$SECONDS
footer_enabled=1
cancelled=0

VERSION="@VERSION@"
PAYLOAD_SHA="@PAYLOAD_SHA@"
self="$(readlink -f -- "$0")"
media_dir="$(dirname -- "$self")"

short_help()
{
    printf '%s\n\n%s\n  %s\n\n%s\n' "${UI_TEXT[help_title]}" 'Commands:' \
        "${UI_TEXT[help_commands]}" "${UI_TEXT[help_menu]}"
}

# The log lives beside the .run so it exists even when setup stops before the
# Wine runtime is created. A read-only installer directory falls back to the
# temporary directory, and the exact path is always printed at exit.
run_id="$(date '+%Y%m%dT%H%M%S')-$$"
log_name="ableton-linux-installer-$run_id.log"
log_path="$media_dir/$log_name"
if ! (umask 077; : > "$log_path") 2>/dev/null; then
    log_path="${TMPDIR:-/tmp}/$log_name"
    if ! (umask 077; : > "$log_path") 2>/dev/null; then
        log_path=/dev/null
    fi
fi
export ABLETON_INSTALLER_LOG="$log_path"

log_event()
{
    local level="$1" context="$2" message="$3" stamp
    printf -v stamp '%(%d/%m/%Y, %H:%M:%S)T' -1
    printf '%-7s%s [ableton-linux][installer][%s] %s\n' \
        "[$level]" "$stamp" "$context" "$message" >> "$log_path" 2>/dev/null || true
    return 0
}

# Everything the scripts print raw goes to the log only, one timestamped
# record per line. The screen belongs to the renderer, which writes to the
# terminal directly and logs its own lines.
mirror_stream()
{
    local stream="$1" line level stamp
    trap '' PIPE
    while IFS= read -r line || [ -n "$line" ]; do
        level=INFO
        case "$line" in
            '!! '*) level=ERR ;;
            WARNING:*|Warning:*|warning:*) level=WARN ;;
        esac
        printf -v stamp '%(%d/%m/%Y, %H:%M:%S)T' -1
        line="${line//$'\r'/}"
        printf '%-7s%s [ableton-linux][installer][%s] %s\n' \
            "[$level]" "$stamp" "$stream" "$line" >> "$log_path" 2>/dev/null || true
    done
    return 0
}

exec 7>&1 8>&2
export ABLETON_UI_TTY_FD=7
exec > >(mirror_stream stdout)
stdout_mirror_pid=$!
exec 2> >(mirror_stream stderr)
stderr_mirror_pid=$!
log_event INFO run "starting installer $VERSION from $self"

# The footer reads the paths the installer saved, when it saved them.
saved_setting()
{
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/config"
    [ -r "$file" ] || return 0
    sed -n "s/^$1=//p" "$file" 2>/dev/null | head -n 1
}

workdir=""
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup()
{
    local rc=$? elapsed outcome warn_count logged_errors display_log="$log_path"
    local runtime="" prefix="" error
    local -a errors=()
    trap - EXIT
    ui_cleanup "$rc"
    if [ -n "$workdir" ]; then
        rm -rf -- "$workdir" 2>/dev/null || true
        if [ -e "$workdir" ] || [ -L "$workdir" ]; then
            printf '!! %s\n' "$(ui_text e_temp_left "$workdir")" >&2 || true
        fi
    fi
    exec 1>&7 2>&8
    # A stray Wine process can hold the pipes open; the log is complete once
    # the readers drain what the scripts wrote, so give them a moment only.
    for _ in $(seq 30); do
        kill -0 "$stdout_mirror_pid" 2>/dev/null || kill -0 "$stderr_mirror_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill "$stdout_mirror_pid" "$stderr_mirror_pid" 2>/dev/null || true
    wait "$stdout_mirror_pid" 2>/dev/null || true
    wait "$stderr_mirror_pid" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
        log_event OK run "${selected_label:-Installer} completed"
    else
        log_event ERR run "${selected_label:-Installer} failed with exit status $rc"
    fi
    [ "$footer_enabled" -eq 1 ] || exit "$rc"

    trap '' PIPE
    elapsed=$((SECONDS - started_at))
    warn_count="$(grep -Ec \
        '^\[WARN\] +.*\[ableton-linux\]\[installer\]\[(stdout|stderr|ui)\] ' \
        "$log_path" 2>/dev/null || true)"
    case "$warn_count" in ''|*[!0-9]*) warn_count=0 ;; esac
    if [ "$rc" -eq 0 ]; then
        outcome=complete
        [ "$cancelled" -eq 0 ] || outcome=cancelled
        logged_errors="$(grep -Ec \
            '^\[ERR\] +.*\[ableton-linux\]\[installer\]\[(stdout|stderr|ui)\] ' \
            "$log_path" 2>/dev/null || true)"
        case "$logged_errors" in ''|*[!0-9]*) logged_errors=0 ;; esac
        warn_count=$((warn_count + logged_errors))
        # A run that succeeded had no errors: what the scripts flagged on the
        # way is kept as warnings (rule D3), in the log as in the footer.
        sed -i 's/^\[ERR\]  /[WARN] /' "$log_path" 2>/dev/null || true
    else
        outcome=failed
        case "$rc" in 130|143) outcome=interrupted ;; esac
        while IFS= read -r error; do
            error="${error#"!! "}"
            [ -n "$error" ] || continue
            case " ${errors[*]-} " in *" $error "*) continue ;; esac
            errors+=("$error")
        done < <(sed -n \
            's/^\[ERR\]  [^[]*\[ableton-linux\]\[installer\]\[\(stdout\|stderr\|ui\)\] //p' \
            "$log_path" 2>/dev/null)
        [ "${#errors[@]}" -gt 0 ] || errors=("Installer exited with status $rc.")
    fi
    if [ "$outcome" = complete ]; then
        runtime="$(saved_setting runtime_root)"
        prefix="$(saved_setting prefix)"
    fi
    # shellcheck disable=SC2088 # display form, not a shell expansion
    case "$display_log" in
        "$HOME"/*) display_log="~/${display_log#"$HOME"/}" ;;
    esac
    [ "$log_path" != /dev/null ] || display_log=""
    ui_footer "${selected_label:-Installer}" "$VERSION" "$outcome" "$elapsed" \
        "$warn_count" "${#errors[@]}" "$runtime" "$prefix"
    if [ "$outcome" = complete ] && [ "${launch_hint:-1}" -eq 0 ]; then
        ui_tail cancelled "$display_log"
    else
        ui_tail "$outcome" "$display_log" "${errors[@]}"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "${1:-}" in
    --help|-h|help) footer_enabled=0; short_help >&7; exit 0 ;;
esac

io_timeout="${ABLETON_PAYLOAD_IO_TIMEOUT:-3600}"
case "$io_timeout" in
    ''|*[!0-9]*) printf '!! ABLETON_PAYLOAD_IO_TIMEOUT must be whole seconds.\n' >&2; exit 2 ;;
esac
[ "$io_timeout" -ge 60 ] && [ "$io_timeout" -le 14400 ] || {
    printf '!! ABLETON_PAYLOAD_IO_TIMEOUT must be between 60 and 14400 seconds.\n' >&2
    exit 2
}

bounded()
{
    timeout --signal=TERM --kill-after=5s "${io_timeout}s" "$@"
}

payload_line="$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$self")"
[ -n "$payload_line" ] || {
    printf '!! %s\n' "$(ui_text e_damaged)" >&2
    exit 1
}
header_bytes="$(head -n "$((payload_line-1))" "$self" | wc -c)"
total_bytes="$(stat -c %s "$self" 2>/dev/null || wc -c < "$self")"
payload_bytes=$((total_bytes - header_bytes))

format_kib()
{
    awk -v kib="${1:-0}" 'BEGIN {
        if (kib >= 1073741824) printf "%.1f TiB", kib / 1073741824;
        else if (kib >= 1048576 / 2) printf "%.1f GiB", kib / 1048576;
        else printf "%.0f MiB", kib / 1024;
    }'
}

distro=Linux
if [ -r /etc/os-release ]; then
    distro="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")"
fi
cpu="$(awk -F: '/model name/{sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
[ -n "$cpu" ] || cpu="$(uname -m 2>/dev/null || printf unknown)"
gpu=""
if command -v lspci >/dev/null 2>&1; then
    gpu="$(lspci -mm 2>/dev/null \
        | awk -F\" 'tolower($2) ~ /(vga|3d|display)/ && !found {print $6 " " $8; found=1}' \
        | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//' || true)"
fi
[ -n "$gpu" ] || gpu="$(ui_text v_unavailable)"
memory="$(awk '/MemTotal:/{printf "%.1f GiB", $2 / 1048576; exit}' /proc/meminfo 2>/dev/null || true)"
[ -n "$memory" ] || memory="$(ui_text v_unavailable)"
pipewire_version=""
if command -v pw-cli >/dev/null 2>&1; then
    pipewire_version="$(pw-cli --version 2>/dev/null \
        | awk '/Linked with libpipewire/ && !found {print $NF; found=1}' || true)"
fi
[ -n "$pipewire_version" ] || pipewire_version="$(ui_text v_unavailable)"
export ABLETON_PIPEWIRE_REPORT_SHOWN=1
missing_dependencies=()
for required in bash timeout tar zstd sha256sum; do
    command -v "$required" >/dev/null 2>&1 || missing_dependencies+=("$required")
done
dependencies="$(ui_text v_deps_ready 'bash timeout tar zstd sha256sum')"
[ "${#missing_dependencies[@]}" -eq 0 ] \
    || dependencies="$(ui_text v_deps_missing "${missing_dependencies[*]}")"

temp_root="${TMPDIR:-/tmp}"
temp_free_kib="$(df -Pk -- "$temp_root" 2>/dev/null | awk 'NR==2 {print $4}')"
home_free_kib="$(df -Pk -- "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
case "$temp_free_kib" in ''|*[!0-9]*) temp_free_kib=0 ;; esac
case "$home_free_kib" in ''|*[!0-9]*) home_free_kib=0 ;; esac
temp_need_kib=$((payload_bytes * 2 / 1024 + 262144))

ui_banner "$VERSION"
ui_blank; ui_heading h_system; ui_blank
ui_row r_date "$(date '+%d/%m/%Y, %H:%M:%S %Z')"
ui_row r_distro "$distro"
ui_row r_kernel "$(uname -sr 2>/dev/null || ui_text v_unavailable)"
ui_row r_cpu "$cpu"
ui_row r_gpu "$gpu"
ui_row r_memory "$memory"
ui_row r_desktop "$(ui_text v_desktop "${XDG_CURRENT_DESKTOP:-$(ui_text v_unavailable)}" "${XDG_SESSION_TYPE:-unknown}")"
ui_row r_pipewire "$pipewire_version"
ui_row r_deps "$dependencies"
ui_blank; ui_heading h_disk; ui_blank
ui_row r_temp "$(ui_text v_free_at "$(format_kib "$temp_free_kib")" "$temp_root")"
ui_row r_install "$(ui_text v_free_under "$(format_kib "$home_free_kib")" "$HOME")"
ui_row r_kit "$(ui_text v_required "$(format_kib "$temp_need_kib")")"

ui_blank; ui_heading h_warnings; ui_blank
host_warnings=0
[ "$(uname -s 2>/dev/null || true)" = Linux ] \
    || { ui_host_warning w_not_linux; host_warnings=1; }
[ "$(uname -m 2>/dev/null || true)" = x86_64 ] \
    || { ui_host_warning w_not_x86_64; host_warnings=1; }
for required in "${missing_dependencies[@]}"; do
    ui_host_warning w_missing_command "$required"; host_warnings=1
done
[ "$temp_free_kib" -ge "$temp_need_kib" ] \
    || { ui_host_warning w_temp_small; host_warnings=1; }
[ "$home_free_kib" -ge 10485760 ] \
    || { ui_host_warning w_home_small; host_warnings=1; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] \
    || { ui_host_warning w_no_display; host_warnings=1; }
if [ "$pipewire_version" = "$(ui_text v_unavailable)" ]; then
    ui_host_warning w_pipewire_unknown; host_warnings=1
elif ! printf '1.4.2\n%s\n' "$pipewire_version" | sort -V -C 2>/dev/null; then
    ui_host_warning w_pipewire_old "$pipewire_version" 1.4.2; host_warnings=1
fi
[ "$host_warnings" -eq 1 ] || ui_note w_none

original_args=("$@")
launch_hint=1
for argument in "${original_args[@]}"; do
    case "$argument" in
        --skip-live-install|--no-launch) launch_hint=0 ;;
    esac
done
selected_action=""
selected_label=""
explicit_action=0
case "${1:-}" in
    install) selected_action=install; selected_label="$(ui_text label_reinstall)"; explicit_action=1 ;;
    update|--update) selected_action=update; selected_label="$(ui_text label_update)"; explicit_action=1 ;;
    uninstall|--uninstall) selected_action=uninstall; selected_label="$(ui_text label_remove)"; explicit_action=1 ;;
    runtime|--runtime-only) selected_action=runtime; selected_label="$(ui_text label_runtime)"; explicit_action=1 ;;
    prefix) selected_action=prefix; selected_label="$(ui_text label_prefix "${2:-command}")"; explicit_action=1 ;;
    link) selected_action='link'; selected_label="$(ui_text label_link "${2:-command}")"; explicit_action=1 ;;
    extract|--extract) selected_action=extract; selected_label="$(ui_text label_extract)"; explicit_action=1 ;;
    plan) selected_action=plan; selected_label="$(ui_text label_plan)"; explicit_action=1 ;;
esac

if [ -f "$HOME/.wine-ableton/system.reg" ]; then
    default_action=update
else
    default_action=install
fi

if [ "$explicit_action" -eq 0 ]; then
    ui_blank; ui_heading h_action; ui_blank
    if [ "$default_action" = update ]; then ui_menu_option m_update default; else ui_menu_option m_update; fi
    if [ "$default_action" = install ]; then ui_menu_option m_reinstall default; else ui_menu_option m_reinstall; fi
    ui_menu_option m_remove
    ui_menu_option m_exit
    ui_blank
    answer=""
    if [ -t 0 ]; then
        ui_prompt m_prompt
        IFS= read -r answer || answer=""
        log_event INFO menu "answer: ${answer:-(default)}"
    fi
    case "${answer,,}" in
        '') selected_action="$default_action" ;;
        u|update) selected_action=update ;;
        r|reinstall|install) selected_action=install ;;
        v|remove|uninstall) selected_action=uninstall ;;
        x|exit|q|quit) cancelled=1; launch_hint=0; exit 0 ;;
        *) ui_note m_unknown "$answer"; printf '!! %s\n' "$(ui_text m_unknown "$answer")" >&2; exit 2 ;;
    esac
    case "$selected_action" in
        update) selected_label="$(ui_text label_update)" ;;
        install) selected_label="$(ui_text label_reinstall)" ;;
        uninstall) selected_label="$(ui_text label_remove)" ;;
    esac
    original_args=("$selected_action" "${original_args[@]}")
fi

case "$selected_action" in
    prefix)
        case "${original_args[1]:-}" in
            create) ui_action=prefix_create ;;
            update) ui_action=prefix_update ;;
            repair-live11) ui_action=prefix_repair ;;
            *) ui_action=prefix_create ;;
        esac ;;
    link)
        case "${original_args[1]:-}" in
            disable) ui_action=link_disable ;;
            status) ui_action=link_status ;;
            *) ui_action=link_enable ;;
        esac ;;
    *) ui_action="$selected_action" ;;
esac
export ABLETON_UI_ACTION="$ui_action"
export ABLETON_UI_KIT=1

if [ "$selected_action" = extract ]; then
    ui_step_begin s_extract
else
    ui_step_begin s_prepare
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/ableton-installer.XXXXXX")" || {
    printf '!! %s\n' "$(ui_text e_workspace "${TMPDIR:-/tmp}")" >&2
    exit 1
}
payload="$workdir/payload.tar"

copy_payload()
{
    if dd --help 2>&1 | grep -q iflag; then
        bounded dd if="$self" of="$payload" iflag=skip_bytes skip="$header_bytes" \
            bs=4M status=none
    else
        bounded tail -n +"$payload_line" "$self" > "$payload"
    fi
}
: > "$payload"
ui_run i_copy --progress "$payload" "$payload_bytes" -- copy_payload || {
    printf '!! %s\n' "$(ui_text e_copy)" >&2
    exit 1
}
ui_status i_copy_done "$((payload_bytes / 1024 / 1024))"

hash_payload()
{
    bounded sha256sum "$payload" > "$workdir/payload.sha256"
}
ui_run i_check -- hash_payload || {
    printf '!! %s\n' "$(ui_text e_check)" >&2
    exit 1
}
read -r actual _ < "$workdir/payload.sha256"
[ "$actual" = "$PAYLOAD_SHA" ] || {
    printf '!! %s\n' "$(ui_text e_integrity)" >&2
    exit 1
}
ui_status i_check_done

kit="$workdir/kit"
mkdir -p -- "$kit"
extract_payload()
{
    bounded tar -xf "$payload" -C "$kit"
}
ui_run i_extract -- extract_payload || {
    printf '!! %s\n' "$(ui_text e_extract)" >&2
    exit 1
}
rm -f -- "$payload" "$workdir/payload.sha256" 2>/dev/null || true

if [ "$selected_action" = extract ]; then
    [ "${#original_args[@]}" -eq 2 ] \
        || { printf '!! %s\n' "$(ui_text e_extract_args)" >&2; exit 2; }
    extract_dir="${original_args[1]}"
    mkdir -p -- "$extract_dir"
    cp -a -- "$kit/." "$extract_dir/"
    ui_status i_extract_to "$extract_dir"
    ui_step_end ok
    launch_hint=0
    exit 0
fi
ui_step_end ok

export ABLETON_INSTALLER_MEDIA_DIR="$media_dir"
export ABLETON_INSTALLER_PATH="$self"
export ABLETON_INSTALLER_VERSION="$VERSION"
bash "$kit/scripts/installer.sh" "${original_args[@]}"
exit $?
# shellcheck disable=SC2317 # payload marker, not a command
__PAYLOAD_BELOW__
