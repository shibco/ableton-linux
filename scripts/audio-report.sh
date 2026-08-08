#!/usr/bin/env bash
# scripts/audio-report.sh — one-shot snapshot of everything that decides audio
# behaviour under this stack: PipeWire settings and forced quanta, default
# devices, realtime threads, ntsync, the PipeASIO configuration, and the tail
# of the launcher session log. Paste the output into an issue report; home
# paths are shortened to ~ before printing.
set -u

redact() { sed "s|$HOME|~|g"; }
sec() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"

sec "versions"
echo "kernel: $(uname -r)"
have pw-cli && pw-cli --version 2>/dev/null | sed -n 's/^Linked with /pipewire: /p'
[ -r "$WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt" ] \
    && sed -n 's/^dist-version: /runtime: /p' "$WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt"

sec "ntsync"
ls -l /dev/ntsync 2>/dev/null || echo "no /dev/ntsync"

sec "realtime limits"
echo "ulimit -r: $(ulimit -r 2>/dev/null)"

sec "PipeWire settings metadata"
have pw-metadata && timeout 5 pw-metadata -n settings 2>/dev/null | sed 's/^update: //'

sec "default devices"
have pw-metadata && timeout 5 pw-metadata -n default 2>/dev/null \
    | sed 's/^update: //' | grep -E "default\." | redact

sec "forced quanta per node"
if have pw-dump; then
    forced="$(timeout 5 pw-dump 2>/dev/null | awk -F'"' '
        /"node\.name"/ { name = $4 }
        /"node\.force-quantum"/ {
            v = $0; gsub(/[^0-9]/, "", v)
            printf "  %s: node.force-quantum %s\n", name, v
        }')"
    if [ -n "$forced" ]; then printf '%s\n' "$forced" | redact; else echo "  none: no node forces a quantum"; fi
fi

sec "graph, 3 s"
have pw-top && LC_ALL=C timeout 3 pw-top -b 2>/dev/null | tail -n 25 | redact

sec "realtime threads"
ps -eLo pid,tid,cls,rtprio,comm 2>/dev/null | awk '$3 == "RR" || $3 == "FF"' | head -n 20 | redact

sec "PipeASIO configuration"
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
[ -r "$cfg" ] && redact < "$cfg" || echo "no config.ini (driver defaults apply)"
env | grep -E '^(PIPEASIO|ABLETON)_' | redact

sec "launcher session log tail"
slog="${XDG_STATE_HOME:-$HOME/.local/state}/ableton-wine/session.log"
[ -r "$slog" ] && tail -n 40 "$slog" | redact || echo "no session log yet (launch Live once)"
