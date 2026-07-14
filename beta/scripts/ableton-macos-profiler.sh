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
        -e 's#(/Users/)[^/[:space:]]+#\1<USER>#g'
        -e 's#([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}#<MAC>#g'
        -e 's#[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}#<EMAIL>#g'
        -e '/^[[:space:]]*([^:=]*([Ss]erial|UUID|UDID|WWN|GUID|[Uu]nique [Ii][Dd]|[Aa]sset[ _-]?[Tt]ag|[Pp]rocessor[Ii][Dd]|[Ii]dentifying[Nn]umber|[Ii]nstance[Ii][Dd]|PNPDeviceID|[Aa]ddress|Location ID|Mount Point|BSD Name|Device Identifier)[^:=]*)[:=]/d'
        -e 's#(password|passwd|token|secret|api[ _-]?key|machineguid|unlock\.json|ableton[ _-]?(serial|licen[cs]e)|licen[cs]e[ _-]?key)[^[:cntrl:]]*#\1=<REDACTED>#Ig'
    )
    sed "${sed_args[@]}"
}

omit_unique_identifiers() {
    sed -E \
        -e '/^[[:space:]]*([^:]*[Ss]erial[^:]*|[^:]*UUID[^:]*|[^:]*UDID[^:]*|[^:]*GUID[^:]*|[^:]*[Uu]nique [Ii][Dd][^:]*|UID|WWN|[^:]*[Aa]ddress[^:]*|Location ID|Mount Point|BSD Name|Device Identifier):/d'
}

collect_profile() {
    collect system_profiler -detailLevel full "$@" | omit_unique_identifiers
}

collect_audio_profile() {
    collect_profile SPAudioDataType |
        sed -E 's#^        [^:]+:$#        Audio Device:#'
}

report="$(
    {
        printf 'ableton-linux system summary (macOS)\n'

        header SYSTEM
        collect sw_vers
        collect uname -rm
        for key in hw.model machdep.cpu.brand_string hw.memsize hw.logicalcpu; do
            value="$(sysctl -n "$key" 2>/dev/null || true)"
            [ -n "$value" ] && printf '%s=%s\n' "$key" "$value"
        done

        header AUDIO
        collect_audio_profile

        header ABLETON
        for root in /Applications "$HOME/Applications"; do
            [ -d "$root" ] || continue
            find "$root" -type d -name 'Ableton Live*.app' -prune -exec basename {} \; 2>/dev/null
        done | sort -u
    } 2>&1 | redact
)"

fence='```'
printf '%s\n' "$report"
echo >&2
if command -v pbcopy >/dev/null 2>&1 &&
    printf '%s\n%s\n%s\n' "$fence" "$report" "$fence" | pbcopy; then
    printf 'Copied to your clipboard. Review the summary above, then paste it into your GitHub issue.\n' >&2
else
    printf 'pbcopy is unavailable. Copy the summary above into your GitHub issue.\n' >&2
fi
