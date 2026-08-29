#!/bin/sh
# shellcheck shell=bash
# Ableton Linux self-extracting installer transport. The wrapper reports the
# host, records the complete run, and unpacks the embedded kit. Installation
# policy remains in the packaged scripts/installer.sh. Everything on screen is
# drawn by the renderer inlined below at build time (scripts/lib/ui.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
@UI_LIB@
@PREFERENCES_LIB@
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
    install) selected_action=install; selected_label="$(ui_text label_install)"; explicit_action=1 ;;
    update|--update) selected_action=update; selected_label="$(ui_text label_update)"; explicit_action=1 ;;
    uninstall|--uninstall) selected_action=uninstall; selected_label="$(ui_text label_remove)"; explicit_action=1 ;;
    runtime|--runtime-only) selected_action=runtime; selected_label="$(ui_text label_runtime)"; explicit_action=1 ;;
    prefix) selected_action=prefix; selected_label="$(ui_text label_prefix "${2:-command}")"; explicit_action=1 ;;
    link) selected_action='link'; selected_label="$(ui_text label_link "${2:-command}")"; explicit_action=1 ;;
    extract|--extract) selected_action=extract; selected_label="$(ui_text label_extract)"; explicit_action=1 ;;
    plan) selected_action=plan; selected_label="$(ui_text label_plan)"; explicit_action=1 ;;
esac

# Return the configured prefix only for the exact format-1 configuration.  It
# is parsed as inert data: the pre-extraction wrapper must never source HOME.
configured_prefix()
{
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/config"
    local line="" key value header=0
    local -A seen=() values=()
    [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
    [ "$(LC_ALL=C tr -cd '\000' < "$file" 2>/dev/null | wc -c)" -eq 0 ] \
        || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$header" -eq 0 ]; then
            [ "$line" = '# ableton-linux installer configuration; managed by the installer' ] \
                || return 1
            header=1
            continue
        fi
        case "$line" in *=*) ;; *) return 1 ;; esac
        key="${line%%=*}"; value="${line#*=}"
        [ -z "${seen[$key]+x}" ] || return 1
        seen["$key"]=1; values["$key"]="$value"
        case "$key" in
            format) [ "$value" = 1 ] || return 1 ;;
            runtime_root|prefix|linkd)
                [ -n "$value" ] && [[ "$value" = /* ]] || return 1
                case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac ;;
            live_major) case "$value" in ''|11|12) ;; *) return 1 ;; esac ;;
            link_mode) case "$value" in off|session|always) ;; *) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    done < "$file"
    [ "$header" -eq 1 ] && [ "${#seen[@]}" -eq 6 ] \
        && [ -n "${seen[format]+x}" ] \
        && [ -n "${seen[runtime_root]+x}" ] \
        && [ -n "${seen[prefix]+x}" ] \
        && [ -n "${seen[live_major]+x}" ] \
        && [ -n "${seen[link_mode]+x}" ] \
        && [ -n "${seen[linkd]+x}" ] || return 1
    printf '%s\n' "${values[prefix]}"
}

marked_default_prefix()
{
    local prefix="$HOME/.wine-ableton" file="$HOME/.wine-ableton/.ableton-linux-prefix"
    local -a line=()
    [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
    [ "$(LC_ALL=C tr -cd '\000' < "$file" 2>/dev/null | wc -c)" -eq 0 ] \
        || return 1
    mapfile -t line < "$file" || return 1
    [ "${#line[@]}" -eq 2 ] && [ "${line[0]}" = format=1 ] \
        && [ "${line[1]}" = "prefix=$prefix" ] || return 1
    printf '%s\n' "$prefix"
}

classify_installation()
{
    local prefix=""
    if prefix="$(configured_prefix)"; then
        :
    elif prefix="$(marked_default_prefix)"; then
        :
    else
        printf '%s\n' fresh
        return 0
    fi
    if [ -d "$prefix" ] && [ ! -L "$prefix" ] \
       && [ -f "$prefix/system.reg" ] && [ ! -L "$prefix/system.reg" ]; then
        printf '%s\n' healthy
    else
        printf '%s\n' incomplete
    fi
}

install_state="$(classify_installation)"
case "$install_state" in
    healthy) default_action=update ;;
    *) default_action=install ;;
esac

render_action_options()
{
    case "$install_state" in
        healthy)
            ui_menu_option m_update default
            ui_menu_option m_reinstall
            ui_menu_option m_remove
            ui_menu_option m_quit ;;
        incomplete)
            ui_menu_option m_reinstall default
            ui_menu_option m_remove
            ui_menu_option m_quit ;;
        *)
            ui_menu_option m_install default
            ui_menu_option m_quit ;;
    esac
}

choose_uninstall_scope()
{
    local answer
    while :; do
        ui_blank; ui_heading m_uninstall_scope; ui_blank
        ui_preflight_option m_uninstall_runtime default
        ui_preflight_option m_uninstall_prefix plain
        ui_preflight_option m_uninstall_all plain
        ui_preflight_option m_uninstall_exit plain
        ui_blank
        ui_prompt m_uninstall_prompt
        IFS= read -r answer || answer=""
        log_event INFO menu "uninstall scope: ${answer:-(default)}"
        answer="${answer,,}"
        answer="${answer#"${answer%%[![:space:]]*}"}"
        answer="${answer%"${answer##*[![:space:]]}"}"
        case "$answer" in
            ''|r|runtime|runtime\ only)
                uninstall_scope=--keep-prefix; return 0 ;;
            p|prefix|prefix\ only)
                uninstall_scope=--prefix-only; return 0 ;;
            a|all)
                uninstall_scope=--delete-prefix; return 0 ;;
            e|exit|q|quit|x)
                return 10 ;;
            *)
                ui_note m_uninstall_unknown "$answer" ;;
        esac
    done
}

load_preflight_values()
{
    local loaded buffer_file
    loaded="$(
        unset ABLETON_SHORTCUTS ABLETON_DPI_MODE ABLETON_MAX_AUDIO_THREADS \
            ABLETON_RT ABLETON_POWER
        ableton_preferences_apply
        printf '%s|%s|%s|%s|%s' "$ABLETON_SHORTCUTS" "$ABLETON_DPI_MODE" \
            "$ABLETON_MAX_AUDIO_THREADS" "$ABLETON_RT" "$ABLETON_POWER"
    )" || loaded='take|auto|auto|auto|performance'
    IFS='|' read -r initial_shortcuts initial_dpi initial_threads initial_rt \
        initial_power <<< "$loaded"
    buffer_file="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
    initial_buffer="$(ableton_pipeasio_buffer_read "$buffer_file" 2>/dev/null)" \
        || initial_buffer=128
}

preflight_option()   # value compatibility-default dictionary-key [args]
{
    local value="$1" compatibility="$2" key="$3" tag=plain
    shift 3
    if [ "$value" = "${draft[q_index]}" ]; then
        if [ "${touched[q_index]}" -eq 1 ] \
           || [ "${initial[q_index]}" != "$compatibility" ]; then
            tag=current
        else
            tag=default
        fi
    fi
    ui_preflight_option "$key" "$tag" "$@"
}

render_preflight_question()
{
    local selected="${draft[q_index]}"
    ui_blank
    case "$q_index" in
        0)
            ui_heading q_buffer_title
            ui_note q_buffer_explanation
            ui_note q_buffer_explanation_2
            case "$selected" in 64|128|256|512|1024) ;; *)
                preflight_option "$selected" 128 q_buffer_custom "$selected" ;;
            esac
            preflight_option 64 128 q_buffer_64
            preflight_option 128 128 q_buffer_128
            preflight_option 256 128 q_buffer_256
            preflight_option 512 128 q_buffer_512
            preflight_option 1024 128 q_buffer_1024 ;;
        1)
            ui_heading q_shortcuts_title
            ui_note q_shortcuts_explanation
            ui_note q_shortcuts_explanation_2
            preflight_option take take q_shortcuts_take
            preflight_option preserve take q_shortcuts_preserve ;;
        2)
            ui_heading q_dpi_title
            ui_note q_dpi_explanation
            ui_note q_dpi_explanation_2
            preflight_option auto auto q_dpi_auto
            preflight_option 100 auto q_dpi_100
            preflight_option fractional auto q_dpi_fractional
            preflight_option preserve auto q_dpi_preserve ;;
        3)
            ui_heading q_threads_title
            ui_note q_threads_explanation
            ui_note q_threads_explanation_2
            ui_note q_threads_explanation_3
            preflight_option auto auto q_threads_auto
            preflight_option off auto q_threads_off
            case "$selected" in auto|off)
                ui_preflight_option q_threads_custom plain ;;
                *) preflight_option "$selected" auto q_threads_value "$selected" ;;
            esac ;;
        4)
            ui_heading q_rt_title
            ui_note q_rt_explanation
            ui_note q_rt_explanation_2
            ui_note q_rt_explanation_3
            preflight_option auto auto q_rt_auto
            preflight_option off auto q_rt_off ;;
        5)
            ui_heading q_power_title
            ui_note q_power_explanation
            ui_note q_power_explanation_2
            preflight_option performance performance q_power_performance
            preflight_option balanced performance q_power_balanced
            preflight_option off performance q_power_off ;;
    esac
}

trim_answer()
{
    answer="${UI_ANSWER,,}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
}

collect_preflight()
{
    local answer value
    local -a prompt_choices=('1-5' 'A/P' 'A/N/F/P' 'A/L/1-63' 'A/N' 'P/B/D')
    load_preflight_values
    initial=("$initial_buffer" "$initial_shortcuts" "$initial_dpi" \
        "$initial_threads" "$initial_rt" "$initial_power")
    draft=("${initial[@]}")
    touched=(0 0 0 0 0 0)
    q_index=0
    while [ "$q_index" -lt 6 ]; do
        render_preflight_question
        ui_preflight_read "${prompt_choices[q_index]}"
        if [ "$UI_ANSWER" = $'\033' ]; then
            if [ "$q_index" -eq 0 ]; then return 10; fi
            q_index=$((q_index - 1))
            continue
        fi
        trim_answer
        if [ -z "$answer" ]; then
            q_index=$((q_index + 1))
            continue
        fi
        value=""
        case "$q_index:$answer" in
            0:1|0:64) value=64 ;; 0:2|0:128) value=128 ;;
            0:3|0:256) value=256 ;; 0:4|0:512) value=512 ;;
            0:5|0:1024) value=1024 ;;
            1:a|1:assign|1:take) value=take ;; 1:p|1:preserve) value=preserve ;;
            2:a|2:auto|2:automatic) value=auto ;; 2:n|2:normal|2:1|2:100|2:100%) value=100 ;;
            2:f|2:fractional) value=fractional ;; 2:p|2:preserve) value=preserve ;;
            3:a|3:auto|3:automatic) value=auto ;; 3:l|3:off) value=off ;;
            3:*)
                if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] \
                   && [ "$answer" -le 63 ]; then
                    value="$answer"
                fi ;;
            4:a|4:auto|4:automatic) value=auto ;; 4:n|4:normal|4:off) value=off ;;
            5:p|5:performance) value=performance ;; 5:b|5:balanced) value=balanced ;;
            5:d|5:don\'t\ change|5:dont\ change|5:o|5:off|5:none) value=off ;;
        esac
        if [ -z "$value" ]; then
            if [ "$q_index" -eq 3 ]; then ui_note q_threads_invalid; else ui_note q_choice_invalid; fi
            continue
        fi
        draft[q_index]="$value"
        touched[q_index]=1
        q_index=$((q_index + 1))
    done
    setting_flags=()
    [ "${draft[0]}" = "${initial[0]}" ] || setting_flags+=("--audio-buffer=${draft[0]}")
    [ "${draft[1]}" = "${initial[1]}" ] || setting_flags+=("--shortcuts=${draft[1]}")
    [ "${draft[2]}" = "${initial[2]}" ] || setting_flags+=("--dpi=${draft[2]}")
    [ "${draft[3]}" = "${initial[3]}" ] || setting_flags+=("--audio-threads=${draft[3]}")
    [ "${draft[4]}" = "${initial[4]}" ] || setting_flags+=("--rt=${draft[4]}")
    [ "${draft[5]}" = "${initial[5]}" ] || setting_flags+=("--power=${draft[5]}")
    return 0
}

if [ "$explicit_action" -eq 0 ]; then
    while :; do
        selected_action=""
        if [ -t 0 ]; then
            ui_blank; ui_heading h_action; ui_blank
            render_action_options
            ui_blank
            ui_prompt m_prompt
            IFS= read -r answer || answer=""
            log_event INFO menu "answer: ${answer:-(default)}"
        else
            answer=""
        fi
        case "${answer,,}" in
            '') selected_action="$default_action" ;;
            i|install) selected_action=install ;;
            u|update) [ "$install_state" = healthy ] && selected_action=update ;;
            r|reinstall) [ "$install_state" != fresh ] && selected_action=install ;;
            v|remove|uninstall) [ "$install_state" != fresh ] && selected_action=uninstall ;;
            x|exit|q|quit) cancelled=1; launch_hint=0; exit 0 ;;
        esac
        if [ -z "$selected_action" ]; then
            ui_note m_unknown "$answer"
            printf '!! %s\n' "$(ui_text m_unknown "$answer")" >&2
            exit 2
        fi
        case "$selected_action" in
            update) selected_label="$(ui_text label_update)" ;;
            install)
                if [ "$install_state" = fresh ]; then
                    selected_label="$(ui_text label_install)"
                else
                    selected_label="$(ui_text label_reinstall)"
                fi ;;
            uninstall) selected_label="$(ui_text label_remove)" ;;
        esac
        if [ -t 0 ] && { [ "$selected_action" = install ] || [ "$selected_action" = update ]; }; then
            if collect_preflight; then
                original_args=("$selected_action" "${setting_flags[@]}")
                break
            else
                collect_rc=$?
            fi
            [ "$collect_rc" -eq 10 ] || exit "$collect_rc"
            continue
        fi
        original_args=("$selected_action")
        break
    done
fi

# Uninstall scope is chosen while the self-extracting payload is still sealed.
# An explicit scope remains untouched so the dispatcher can reject conflicts.
if [ "$selected_action" = uninstall ]; then
    launch_hint=0
fi
if [ "$selected_action" = uninstall ] && [ "$explicit_action" -eq 1 ]; then
    uninstall_scope=""
    uninstall_scope_present=0
    for ((argument_index=1; argument_index < ${#original_args[@]}; argument_index++)); do
        argument="${original_args[argument_index]}"
        case "$argument" in
            --keep-prefix|--prefix-only|--delete-prefix)
                uninstall_scope_present=1 ;;
            --prefix)
                # Preserve the value-less legacy delete-prefix spelling. A
                # following non-option is instead the configured prefix path.
                next_argument="${original_args[argument_index + 1]:-}"
                if [ -z "$next_argument" ] || [[ "$next_argument" = --* ]]; then
                    uninstall_scope_present=1
                fi ;;
        esac
    done
    if [ "$uninstall_scope_present" -eq 0 ]; then
        if [ -t 0 ]; then
            choose_uninstall_scope || {
                choose_rc=$?
                [ "$choose_rc" -eq 10 ] || exit "$choose_rc"
                cancelled=1
                exit 0
            }
        else
            uninstall_scope=--keep-prefix
        fi
        original_args=("${original_args[0]}" "$uninstall_scope" "${original_args[@]:1}")
    fi
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

if { [ "$selected_action" = install ] || [ "$selected_action" = update ]; } \
   && { pgrep -x wineserver >/dev/null 2>&1 \
        || pgrep -x wineserver64 >/dev/null 2>&1; }; then
    if [ ! -t 0 ]; then
        printf '!! Wine is running. Run the installer in a terminal so it can ask before stopping Wine.\n' >&2
        exit 1
    fi
    ui_question q_stop_wine_title n q_stop_wine_yes q_stop_wine_no
    if [ "$UI_ANSWER" != y ]; then
        cancelled=1; launch_hint=0; exit 0
    fi
    pkill -x wineserver >/dev/null 2>&1 || true
    pkill -x wineserver64 >/dev/null 2>&1 || true
    if ! timeout 30 sh -c '
        while pgrep -x wineserver >/dev/null 2>&1 \
           || pgrep -x wineserver64 >/dev/null 2>&1; do
            sleep 0.1
        done
    '; then
        printf '!! Wine did not stop within 30 seconds.\n' >&2
        exit 1
    fi
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
