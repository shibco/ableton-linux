#!/usr/bin/env bash
# Check that Live opens the packaged ASIO driver (PipeASIO) without crashing (e.g. on a sample-rate mismatch).
# Run on the target machine after Live is installed. Exit 0 = driver opened, no FatalError logged.
set -uo pipefail

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"
export WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
LAUNCH="${ABLETON_LAUNCHER:-$HOME/.local/bin/ableton-live}"
TIMEOUT="${ABLETON_CHECK_TIMEOUT:-180}"

log_dir="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/Ableton"
live_log="$(ls -d "$log_dir"/Live*/Preferences/Log.txt 2>/dev/null | sort | tail -1 || true)"
[ -n "$live_log" ] || { echo "!! no Live Log.txt under $log_dir — is Live installed?" >&2; exit 1; }
[ -x "$LAUNCH" ]   || { echo "!! launcher not found at $LAUNCH" >&2; exit 1; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "!! needs a desktop session (DISPLAY unset)" >&2; exit 1; }

base="$(wc -l < "$live_log")"
echo "== launching Live (log baseline: line $base) =="
setsid nohup "$LAUNCH" >/tmp/ableton-audio-check.log 2>&1 &

deadline=$((SECONDS + TIMEOUT))
verdict=""
while [ $SECONDS -lt $deadline ]; do
    sleep 5
    new="$(tail -n +"$((base+1))" "$live_log" 2>/dev/null || true)"
    if printf '%s' "$new" | grep -qaE "FatalError|Uncaught exception"; then
        verdict=fatal; break
    fi
    if printf '%s' "$new" | grep -qa "Open: finished"; then
        verdict=opened; break
    fi
    if ! pgrep -f "Ableton Live.*\.exe" >/dev/null 2>&1; then
        verdict=died; break
    fi
done

new="$(tail -n +"$((base+1))" "$live_log" 2>/dev/null || true)"
echo "-- audio driver lines Live logged:"
printf '%s\n' "$new" | grep -aiE "ASIO|SampleRate|FatalError|Uncaught" | tail -12 | sed 's/^/   /'

# shut down the wineserver this check started
WINEPREFIX="$WINEPREFIX" "$WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1 || true

case "$verdict" in
    opened)
        rate="$(printf '%s' "$new" | grep -ao "Used SampleRate: [0-9]*" | tail -1)"
        echo "OK: Live opened the audio driver cleanly (${rate:-rate unknown})"
        exit 0 ;;
    fatal)
        echo "!! FAIL: Live hit a FatalError while opening the audio driver" >&2
        echo "!! (ASE_NoClock on a sample-rate mismatch is the classic cause)" >&2
        exit 1 ;;
    died)
        echo "!! FAIL: Live exited before opening the audio driver" >&2
        exit 1 ;;
    *)
        echo "!! FAIL: Live never finished opening the driver within ${TIMEOUT}s" >&2
        echo "!! (a hung 'Open: started' means the PipeWire graph never came up —" >&2
        echo "!!  check 'pw-metadata -n settings' for a forced clock rate)" >&2
        exit 1 ;;
esac
