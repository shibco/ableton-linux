#!/usr/bin/env bash
# scripts/audio-report.sh — one-shot snapshot of everything that decides audio
# behaviour under this stack: PipeWire settings and forced quanta, default
# devices, realtime threads, ntsync, the PipeASIO configuration, the tail of
# the launcher live log, and a follower-resync check for two-device setups.
# Read-only: the script reports and changes nothing. Paste the output into an
# issue report; home paths are shortened to ~ before printing.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
for config_lib in "$here/lib/config.sh" "$here/config.sh" \
                  "${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine/lib/config.sh"; do
    # shellcheck disable=SC1090
    if [ -r "$config_lib" ]; then . "$config_lib"; break; fi
done
declare -F ableton_config_init >/dev/null 2>&1 || {
    echo "!! audio report cannot find its installation configuration" >&2; exit 1; }
ableton_config_init

redact() { sed "s|$HOME|~|g"; }
sec() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

WINE_ROOT="$ABLETON_WINE_ROOT"

sec "versions"
echo "kernel: $(uname -r)"
version_probe="$WINE_ROOT/bin/pipewire-version-probe"
[ -x "$version_probe" ] || version_probe="$ABLETON_DATA_HOME/pipewire-version-probe"
if [ -x "$version_probe" ] && probe_output="$("$version_probe" 2>/dev/null)"; then
    printf '%s\n' "$probe_output" \
        | sed -e 's/^client=/pipewire client: /' -e 's/^daemon=/pipewire daemon: /'
else
    echo "pipewire client/daemon: unavailable (audio service stopped or compatibility check missing)"
fi
[ -r "$WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt" ] \
    && sed -n 's/^dist-version: /runtime: /p' "$WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt"

sec "ntsync device availability"
if ls -l /dev/ntsync 2>/dev/null; then
    echo "device presence does not prove that this Wine runtime uses ntsync"
else
    echo "no /dev/ntsync"
fi

matching_server=0
if have pgrep; then
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        prefix="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
            | sed -n 's/^WINEPREFIX=//p' | head -n 1)"
        [ "$prefix" = "$ABLETON_WINEPREFIX" ] || continue
        matching_server=1
        ntsync_fds=0
        for fd_path in "/proc/$pid/fd/"*; do
            [ "$(readlink -- "$fd_path" 2>/dev/null || true)" = /dev/ntsync ] \
                && ntsync_fds=$((ntsync_fds + 1))
        done
        if [ "$ntsync_fds" -gt 0 ]; then
            echo "wineserver $pid: NTSync active ($ntsync_fds /dev/ntsync fd(s))"
        else
            echo "wineserver $pid: NTSync NOT proven (no /dev/ntsync fd)"
        fi
    done < <(pgrep -x wineserver 2>/dev/null)
fi
[ "$matching_server" -eq 1 ] || echo "no running wineserver for the configured Live prefix"

ntsync_check="$ABLETON_DATA_HOME/check-ntsync.sh"
[ -x "$ntsync_check" ] || ntsync_check="$here/check-ntsync.sh"
if [ -x "$ntsync_check" ]; then
    printf 'close Live, then run %s for the dynamic proof\n' "$ntsync_check" | redact
else
    echo "dynamic proof unavailable: reinstall desktop integration to restore check-ntsync.sh"
fi

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
else
    echo "  unavailable: pw-dump is not installed"
fi

sec "graph, 3 s"
if have pw-top; then
    LC_ALL=C timeout 3 pw-top -b 2>/dev/null | tail -n 25 | redact
else
    echo "unavailable: pw-top is not installed"
fi

sec "realtime threads"
ps -eLo pid,tid,cls,rtprio,comm 2>/dev/null | awk '$3 == "RR" || $3 == "FF"' | head -n 20 | redact

sec "PipeASIO configuration"
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
[ -r "$cfg" ] && redact < "$cfg" || echo "no config.ini (driver defaults apply)"
env | grep -E '^(PIPEASIO|ABLETON)_' | redact

sec "Live audio worker setting"
options_found=0
if [ -d "$ABLETON_WINEPREFIX/drive_c/users" ]; then
    while IFS= read -r options_file; do
        case "$options_file" in
            */AppData/Roaming/Ableton/Live\ 12*/Preferences/Options.txt) ;;
            *) continue ;;
        esac
        options_found=1
        printf '%s: ' "$options_file" | redact
        if ! sed -n '/^-MaxAudioThreads=/{p;q;}' "$options_file"; then
            echo "(unreadable)"
        elif ! grep -q '^-MaxAudioThreads=' "$options_file"; then
            echo "(no explicit -MaxAudioThreads; Live calculates it)"
        fi
    done < <(
        if have rg; then
            rg --files "$ABLETON_WINEPREFIX/drive_c/users" -g Options.txt 2>/dev/null
        else
            find "$ABLETON_WINEPREFIX/drive_c/users" -name Options.txt -type f 2>/dev/null
        fi
    )
fi
[ "$options_found" -eq 1 ] || echo "no Live 12 Options.txt found"

sec "launcher live log tail"
slog="$ABLETON_STATE_HOME/logs/live.log"
[ -r "$slog" ] && tail -n 40 "$slog" | redact || echo "no live log yet (launch Live once)"

sec "follower resync (two-device setups)"
# api.alsa.headroom is specifically compensation for inaccurate ALSA hardware
# pointers.  It is not generic clock-drift compensation, so a rule is printed
# only when a bounded PipeWire/WirePlumber journal query contains spa.alsa
# pointer/resync evidence.  Launcher lines remain useful context but cannot
# enable the experiment on their own.
live_resync_lines=""
[ -r "$slog" ] && live_resync_lines="$(grep -iE 'resync|xrun' "$slog" 2>/dev/null | tail -n 8)"
journal_resync_lines=""
if have journalctl; then
    journal_resync_lines="$({
        timeout 6 journalctl --user --since '-30 minutes' -n 500 --no-pager -o cat \
            _COMM=pipewire 2>/dev/null || true
        timeout 6 journalctl --user --since '-30 minutes' -n 500 --no-pager -o cat \
            _COMM=wireplumber 2>/dev/null || true
    } | grep -iE 'spa\.alsa.*(resync|xrun|pointer)|(resync|xrun|pointer).*spa\.alsa' | tail -n 8)"
fi
if [ -n "$live_resync_lines" ]; then
    echo "resync/xrun lines in $slog:"
    printf '%s\n' "$live_resync_lines" | sed 's/^/  /' | redact
else
    echo "no resync or xrun lines in $slog"
fi
if [ -n "$journal_resync_lines" ]; then
    echo "spa.alsa pointer/resync evidence in the last 30 minutes of the user journal:"
    printf '%s\n' "$journal_resync_lines" | sed 's/^/  /' | redact
else
    echo "no recent spa.alsa pointer/resync evidence (or user journal unavailable)"
fi

# Graph shape from a short pw-top sample: two iterations, keep the last one.
# Follower rows carry a "+" before the node name; ALSA device nodes are the
# ones named alsa_output.* / alsa_input.*.
top_sample=""
have pw-top && top_sample="$(LC_ALL=C timeout 10 pw-top -b -n 2 2>/dev/null | awk '
    /^S +ID/ { buf = "" ; next }
    { buf = buf $0 "\n" }
    END { printf "%s", buf }')"
driver_nodes=""
follower_nodes=""
if [ -n "$top_sample" ]; then
    driver_nodes="$(printf '%s\n' "$top_sample" | awk '
        $0 !~ /\+/ && / alsa_(output|input)\./ { print $NF }' | sort -u)"
    follower_nodes="$(printf '%s\n' "$top_sample" | awk '
        /\+ +alsa_(output|input)\./ { print $NF }' | sort -u)"
fi
if [ -n "$follower_nodes" ]; then
    echo "graph driver device(s): $(printf '%s' "${driver_nodes:-none visible}" | tr '\n' ' ')" | redact
    echo "follower device(s):     $(printf '%s' "$follower_nodes" | tr '\n' ' ')" | redact
else
    echo "no follower audio device in the graph right now (single-clock setup, or Live not running)"
fi

# Map an ALSA path named in a resync line (e.g. hw:M2p) to its node.name.
node_for_alsa_path() {
    have pw-dump || return 0
    timeout 5 pw-dump 2>/dev/null | awk -v want="$1" -F'"' '
        /^  \{/ { name = "" ; path = "" }
        $2 == "node.name"     { name = $4 }
        $2 == "api.alsa.path" { path = $4 }
        /^  \},?$/ { if (path == want && name != "") { print name; exit } }'
}

target_node=""
if [ -n "$journal_resync_lines" ]; then
    for dev in $(printf '%s\n' "$journal_resync_lines" | grep -oE '(plug)?hw:[A-Za-z0-9_,+-]+' | sort -u); do
        n="$(node_for_alsa_path "$dev")"
        if [ -n "$n" ] \
           && printf '%s\n' "$follower_nodes" | grep -Fx -- "$n" >/dev/null 2>&1; then
            target_node="$n"
            break
        fi
    done
fi

if [ -n "$target_node" ]; then
    echo
    echo "device $target_node is a follower and the journal shows spa.alsa pointer/resync evidence." | redact
    echo "The following api.alsa.headroom rule is a reversible experiment for an"
    echo "inaccurate ALSA hardware pointer; it is not a clock-drift fix. 512 frames"
    echo "adds about 10.7 ms at 48 kHz if applied. No improvement is assumed."
    echo "Copy this block to a file in ~/.config/wireplumber/wireplumber.conf.d/,"
    echo "then log out and back in, or run: systemctl --user restart wireplumber"
    echo
    cat <<EOF
# ~/.config/wireplumber/wireplumber.conf.d/99-ableton-follower-headroom.conf
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "$target_node" }
    ]
    actions = {
      update-props = {
        api.alsa.headroom = 512
      }
    }
  }
]
EOF
    echo
    echo "After testing, remove the file if it does not clearly help; the report does not claim success."
elif [ -n "$journal_resync_lines" ]; then
    echo "spa.alsa evidence recorded, but no follower device identified: attach this report to an issue"
elif [ -n "$live_resync_lines" ]; then
    echo "launcher resync/xrun lines alone do not justify changing api.alsa.headroom"
fi
