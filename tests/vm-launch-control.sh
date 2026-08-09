#!/usr/bin/env bash
# Control for the migration launch test: the same prefix and the same VM, with
# the published release only and nothing migrated. If Live crashes here too,
# the crash is not ours.
set -uo pipefail
cd "$(dirname "$0")"
SRC=$HOME/.wine-regression-prefix-test
LEGACY=$HOME/.wine-ableton
restore() { [ -d "$LEGACY" ] && [ ! -e "$SRC" ] && mv "$LEGACY" "$SRC" && echo "-- restored $SRC"; return 0; }
trap restore EXIT

pkill -f 'Ableton Live' 2>/dev/null; pkill -f wineserver 2>/dev/null; sleep 2
rm -rf "$HOME/works" "$HOME/.local/opt/wine-d2d1-nspa-"* "$HOME/.local/opt/ableton-wine" 2>/dev/null
[ -e "$LEGACY" ] && rm -rf "$LEGACY"
mv "$SRC" "$LEGACY"

echo "== released kit only, prefix at the legacy path, no migration =="
sh install-ableton-latest.run --runtime-only >/tmp/ctl.log 2>&1 || { echo "!! failed"; tail -5 /tmp/ctl.log; exit 1; }
echo "   runtime: $(ls -d "$HOME"/.local/opt/wine-d2d1-nspa-* 2>/dev/null | head -1)"
echo "   prefix:  $LEGACY"

export DISPLAY=:0
LOGF=$(find "$LEGACY"/drive_c/users/*/AppData/Roaming/Ableton/Live*/Preferences/Log.txt -type f 2>/dev/null | head -1)
before=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
setsid ~/.local/bin/ableton-live >/tmp/ctl-launch.log 2>&1 &
for i in $(seq 1 18); do sleep 5; pgrep -f 'Ableton Live.*\.exe' >/dev/null && { echo "   process up after $((i*5))s"; break; }; done

after=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
echo "-- new log lines this run: $((after - before))"
[ "$after" -gt "$before" ] && tail -n "$((after - before))" "$LOGF" | grep -E 'Started: Live|Exception|error' | head -4 | sed 's/^/   /'
echo
bash verify-live.sh "$LEGACY" 2>&1 | head -3 | sed 's/^/   /'
pkill -f 'Ableton Live' 2>/dev/null; sleep 2; pkill -f wineserver 2>/dev/null
