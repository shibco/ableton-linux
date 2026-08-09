#!/usr/bin/env bash
# Does Ableton Live still start after its prefix has been migrated?
#
# The migration test before this one proved a synthetic prefix arrives intact.
# This uses the real thing: the 7 GB prefix the regression suite built, with
# Live 12 Suite genuinely installed, moved to the legacy path so the migration
# has something real to move, then launched through the repo's own launcher.
#
# The oracle is verify-live.sh, which reports RUNNING / EXITED CLEANLY / FAIL /
# UNKNOWN rather than a boolean - a log with nothing after "Started: Live" is
# not proof of a window, and this test would rather say UNKNOWN than lie.
set -uo pipefail
cd "$(dirname "$0")"

SRC=$HOME/.wine-regression-prefix-test
LEGACY=$HOME/.wine-ableton
PLUG=$HOME/works/plugs/studio
NEW=$(ls -1 ableton-wine-setup-*.run | head -1)

restore() {
    # Put the suite's prefix back where the suite expects it, whatever happened.
    [ -d "$PLUG" ] && [ ! -e "$SRC" ] && mv "$PLUG" "$SRC" && echo "-- restored $SRC"
    [ -d "$LEGACY" ] && [ ! -e "$SRC" ] && mv "$LEGACY" "$SRC" && echo "-- restored $SRC"
    return 0
}
trap restore EXIT

echo "== [1/5] put the real Live prefix at the legacy path =="
pkill -f 'Ableton Live' 2>/dev/null; sleep 2
rm -rf "$HOME/works" "$HOME/.local/opt/wine-d2d1-nspa-"* 2>/dev/null
[ -d "$SRC" ] || { echo "!! no regression prefix at $SRC"; exit 1; }
[ -e "$LEGACY" ] && rm -rf "$LEGACY"
mv "$SRC" "$LEGACY"
live_exe=$(find "$LEGACY/drive_c/ProgramData/Ableton" -name 'Ableton Live*.exe' 2>/dev/null | head -1)
echo "   $(du -sh "$LEGACY" | cut -f1) prefix holding $(basename "$live_exe")"

echo
echo "== [2/5] the old runtime layout beside it =="
sh install-ableton-latest.run --runtime-only >/tmp/old.log 2>&1 || { echo "!! released kit failed"; tail -5 /tmp/old.log; exit 1; }
echo "   flat runtime at ~/.local/opt/$(ls ~/.local/opt | head -1)"

echo
echo "== [3/5] migrate =="
sh "$NEW" --runtime-only >/tmp/new.log 2>&1 || { echo "!! candidate failed"; tail -20 /tmp/new.log; exit 1; }
grep -E '^   (layout|plug):' /tmp/new.log | sed 's/^/  /'
[ -d "$PLUG" ] || { echo "!! the prefix did not arrive at $PLUG"; exit 1; }
echo "   Live is now at: $(find "$PLUG/drive_c/ProgramData/Ableton" -name 'Ableton Live*.exe' | head -1)"

echo
echo "== [4/5] launch Live through the installed launcher =="
export DISPLAY=:0
# Remember what the log said BEFORE this run. verify-live.sh reports the last
# "Started" line whether or not this run wrote it, and a four-day-old line
# beside a live process reads exactly like a fresh success.
LOGF=$(find "$PLUG"/drive_c/users/*/AppData/Roaming/Ableton/Live*/Preferences/Log.txt -type f 2>/dev/null | head -1)
before=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
setsid ~/.local/bin/ableton-live >/tmp/launch.log 2>&1 &
for i in $(seq 1 18); do
    sleep 5
    pgrep -f 'Ableton Live.*\.exe' >/dev/null && { echo "   Live process up after $((i*5))s"; break; }
done

echo
echo "== [5/5] verdict =="
echo "-- is the running Live executing out of the Plug?"
for p in $(pgrep -f 'Ableton Live.*\.exe' 2>/dev/null | head -3); do
    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null)
    printf '   pid %-7s %s\n' "$p" "${exe:-<gone>}"
done
echo "-- runtime the processes came from:"
readlink -f "$(pgrep -f wineserver | head -1 | xargs -I{} readlink -f /proc/{}/exe 2>/dev/null)" 2>/dev/null | sed 's/^/   /'
echo
echo "-- did Live write its own start line during THIS run?"
after=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
if [ "$after" -gt "$before" ]; then
    echo "   yes: $((after - before)) new log lines"
    tail -n "$((after - before))" "$LOGF" | grep -m1 'Started: Live' | sed 's/^/   /' || true
else
    echo "   NO NEW LOG LINES - the process is up but Live has not logged a start"
fi
echo
WINEPREFIX="$PLUG" bash verify-live.sh "$PLUG" 2>&1 | sed 's/^/   /'
echo
pkill -f 'Ableton Live' 2>/dev/null; sleep 3; pkill -f wineserver 2>/dev/null
echo "== done on $(. /etc/os-release; echo "$PRETTY_NAME") =="
