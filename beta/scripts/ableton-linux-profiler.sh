#!/usr/bin/env bash
# Collects a short, redacted system summary and copies it to the clipboard
# for pasting into a GitHub issue.
set -u

header() {
    printf '\n[%s]\n' "$1"
}

collect() {
    command -v "$1" >/dev/null 2>&1 || return 0
    "$@" 2>&1 || true
}

escape_ere() {
    printf '%s' "$1" | sed 's/[][\\.^$*+?{}()|\/#]/\\&/g'
}

redact() {
    local home_re
    home_re="$(escape_ere "$HOME")"

    sed_args=( -E )
    case "$HOME" in
        /*) sed_args+=( -e "s#${home_re}#<HOME>#g" ) ;;
    esac
    sed_args+=(
        -e 's#(/home/)[^/[:space:]]+#\1<USER>#g'
        -e 's#(/run/user/)[0-9]+#\1<UID>#g'
        -e 's#luks-[0-9a-f-]{16,}#luks-<REDACTED>#Ig'
        -e 's#([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}#<MAC>#g'
        -e 's#[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}#<EMAIL>#g'
        -e '/^[[:space:]]*([^:=]*([Ss]erial|UUID|UDID|WWN|GUID|[Uu]nique [Ii][Dd]|[Aa]sset[ _-]?[Tt]ag|[Pp]rocessor[Ii][Dd]|[Ii]dentifying[Nn]umber|[Ii]nstance[Ii][Dd]|PNPDeviceID|[Aa]ddress|Location ID|Mount Point|Device Identifier)[^:=]*)[:=]/d'
        -e 's#(password|passwd|token|secret|api[ _-]?key|machineguid|unlock\.json|ableton[ _-]?(serial|licen[cs]e)|licen[cs]e[ _-]?key)[^[:cntrl:]]*#\1=<REDACTED>#Ig'
    )
    sed "${sed_args[@]}"
}

report="$(
    {
        printf 'ableton-linux system summary (Linux)\n'

        header SYSTEM
        sed -n -E '/^(PRETTY_NAME|VERSION_ID)=/p' /etc/os-release 2>/dev/null || true
        collect uname -srm
        if command -v lscpu >/dev/null 2>&1; then
            lscpu 2>&1 | sed -n -E '/^(Model name|CPU\(s\)):/p'
        fi
        if command -v free >/dev/null 2>&1; then
            free -h 2>&1 | sed -n '1,2p'
        fi
        for field in sys_vendor product_name; do
            path="/sys/class/dmi/id/$field"
            if [ -r "$path" ]; then
                value="$(tr -d '\000\n' < "$path")"
                [ -n "$value" ] && printf '%s=%s\n' "$field" "$value"
            fi
        done

        header GRAPHICS
        if command -v glxinfo >/dev/null 2>&1; then
            glxinfo -B 2>&1 | sed -n -E '/^OpenGL (vendor|renderer|version|core profile version)/p'
        fi
        printf 'desktop=%s\nsession=%s\n' \
            "${XDG_CURRENT_DESKTOP:-}" "${XDG_SESSION_TYPE:-}"

        header AUDIO
        if command -v systemctl >/dev/null 2>&1; then
            for unit in pipewire pipewire-pulse wireplumber; do
                state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
                printf '%s=%s\n' "$unit" "${state:-unavailable}"
            done
        fi
        collect pipewire --version
        collect wireplumber --version
        collect pw-metadata -n settings
        collect aplay -l

        header MIDI
        if command -v amidi >/dev/null 2>&1; then
            amidi -l 2>/dev/null || true
        fi
    } 2>&1 | redact
)"

copy_to_clipboard() {
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
        wl-copy
    elif command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard
    elif command -v xsel >/dev/null 2>&1; then
        xsel --clipboard --input
    else
        return 1
    fi
}

fence='```'
printf '%s\n' "$report"
echo >&2
if printf '%s\n%s\n%s\n' "$fence" "$report" "$fence" | copy_to_clipboard 2>/dev/null; then
    printf 'Copied to your clipboard. Review the summary above, then paste it into your GitHub issue.\n' >&2
else
    printf 'No clipboard tool found (wl-copy, xclip or xsel). Copy the summary above into your GitHub issue.\n' >&2
fi
