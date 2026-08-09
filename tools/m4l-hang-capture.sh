#!/usr/bin/env bash
# Capture evidence from a hung Ableton Live process:
#   tools/m4l-hang-capture.sh [outdir]
#
# Answers what a single backtrace cannot - whether the UI thread is parked or
# spinning through a timed wait - by diffing two winedbg stack samples against
# two per-thread CPU samples. Run it WHILE Live is hung; the hang need not be
# reproducible. See notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md

set -uo pipefail

OUT="${1:-$PWD/m4l-hang-$(date +%Y%m%dT%H%M%S)}"
GAP="${GAP:-10}"
for _l in "$(dirname "$0")/runtime-env.sh" "$HOME/.local/share/ableton-wine/runtime-env.sh"; do
    # shellcheck source=scripts/runtime-env.sh
    [ -r "$_l" ] && . "$_l" && break
done
command -v ableton_wine_root >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found next to $0 or in ~/.local/share/ableton-wine" >&2; exit 1; }
WINE_ROOT="$(ableton_wine_root)"
export WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
WINEDBG="$WINE_ROOT/bin/winedbg"

mkdir -p "$OUT" || exit 1
echo "==> output: $OUT"

[ -x "$WINEDBG" ] || { echo "!! no winedbg at $WINEDBG (set ABLETON_WINE_ROOT)"; exit 1; }

# --- locate the hung process ------------------------------------------------
PID="$(pgrep -f 'Ableton Live [0-9]+ .*\.exe' | head -1)"
if [ -z "$PID" ]; then
    echo "!! no running 'Ableton Live *.exe' found"
    exit 1
fi
echo "==> unix pid $PID"

# Wine pid (hex) for the same exe, from winedbg's own process list.
WPID="$("$WINEDBG" --command 'info process' 2>/dev/null \
        | awk '/Ableton Live/ && $1 ~ /^[0-9a-f]+$/ {print $1; exit}')"
[ -n "$WPID" ] && echo "==> wine pid 0x$WPID" || echo "!! could not map to a wine pid; stacks will be skipped"

# --- per-thread CPU sampler -------------------------------------------------
# Fields 14/15 of /proc/<tid>/stat are utime/stime in jiffies.
sample_cpu() {
    local tag="$1" t
    for t in /proc/"$PID"/task/*; do
        [ -r "$t/stat" ] || continue
        awk -v tid="${t##*/}" -v comm="$(cat "$t/comm" 2>/dev/null)" \
            '{ n=split($0,f," "); print tid, comm, f[14]+f[15] }' "$t/stat"
    done > "$OUT/cpu-$tag.txt" 2>/dev/null
    echo "==> cpu sample '$tag': $(wc -l < "$OUT/cpu-$tag.txt") threads"
}

sample_bt() {
    local tag="$1"
    [ -n "$WPID" ] || return 0
    "$WINEDBG" --command "attach 0x$WPID
bt all
detach" > "$OUT/bt-$tag.log" 2>&1
    echo "==> stack sample '$tag': $(grep -c 'Backtracing for thread' "$OUT/bt-$tag.log" 2>/dev/null || echo 0) threads"
}

# --- two samples, GAP seconds apart ----------------------------------------
sample_cpu a; sample_bt a
echo "==> waiting ${GAP}s ..."; sleep "$GAP"
sample_cpu b; sample_bt b

# --- CPU delta --------------------------------------------------------------
join -j1 <(sort -k1,1 "$OUT/cpu-a.txt") <(sort -k1,1 "$OUT/cpu-b.txt") 2>/dev/null \
  | awk '{ d=$5-$3; if (d>0) printf "%-8s %-20s +%s jiffies\n", $1, $2, d }' \
  | sort -k3 -rn > "$OUT/cpu-delta.txt"

echo
echo "=== threads that burned CPU over ${GAP}s (top 15) ==="
head -15 "$OUT/cpu-delta.txt"
[ -s "$OUT/cpu-delta.txt" ] || echo "  (none — every thread was idle)"

# --- did the UI thread's stack move? ---------------------------------------
# NOTE: winedbg's "bt all" dumps EVERY wine process, not just the one attached
# to, so the Live process must be selected explicitly. Picking the first
# backtrace in the file yields services.exe and a meaningless verdict.
if [ -s "$OUT/bt-a.log" ] && [ -s "$OUT/bt-b.log" ]; then
    LPROC="$(grep -oE 'in process [0-9a-f]+ \(C:\\ProgramData\\Ableton\\[^)]*Live[^)]*\.exe\)' \
             "$OUT/bt-a.log" | head -1 | awk '{print $3}')"
    echo
    if [ -z "$LPROC" ]; then
        echo "!! could not find the Live process in the dump; skipping stack diff"
    else
        echo "==> Live wine process: $LPROC"
        # The UI thread is the deepest stack in that process.
        for f in a b; do
            awk -v proc="$LPROC" '
                /^Backtracing for thread/ { keep = ($7 == proc); tid = $4; next }
                keep && NF { print tid "\t" $0 }
            ' "$OUT/bt-$f.log" | sed 's/(0x[0-9a-f]*)[[:space:]]*$//' > "$OUT/live-$f.txt"
            awk -F'\t' '{c[$1]++} END {for (t in c) print c[t], t}' "$OUT/live-$f.txt" \
                | sort -rn | head -1 | awk '{print $2}' > "$OUT/uitid-$f.txt"
            awk -F'\t' -v t="$(cat "$OUT/uitid-$f.txt")" '$1==t {print $2}' \
                "$OUT/live-$f.txt" > "$OUT/main-$f.txt"
        done
        UITID="$(cat "$OUT/uitid-a.txt")"
        echo "==> UI thread (deepest stack): wine tid $UITID, $(wc -l < "$OUT/main-a.txt") frames"
        if diff -q "$OUT/main-a.txt" "$OUT/main-b.txt" >/dev/null 2>&1; then
            echo "=== VERDICT: UI thread stack IDENTICAL across ${GAP}s -> parked/blocked ==="
        else
            echo "=== VERDICT: UI thread stack CHANGED -> progressing or spinning ==="
            diff "$OUT/main-a.txt" "$OUT/main-b.txt" | head -30
        fi
    fi

    # The process's own main thread is the lowest Linux tid (tid == pid).
    # Ableton names dozens of threads "MainThread", so never identify it by name.
    UA="$(sort -n "$OUT/cpu-a.txt" | head -1)"; UB="$(sort -n "$OUT/cpu-b.txt" | head -1)"
    echo "==> main linux thread CPU: $(echo "$UA" | awk '{print $1, $3}') -> $(echo "$UB" | awk '{print $3}') jiffies"
    [ "$(echo "$UA" | awk '{print $3}')" = "$(echo "$UB" | awk '{print $3}')" ] \
        && echo "=== VERDICT: main thread burned ZERO CPU over ${GAP}s -> genuinely blocked ==="
fi

# --- supporting logs --------------------------------------------------------
MAXLOG="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/Cycling '74/Max 9/Logs"
[ -d "$MAXLOG" ] && cp -f "$MAXLOG"/MaxPlug*.log "$OUT/" 2>/dev/null

LIVELOG="$(ls -t "$WINEPREFIX"/drive_c/users/"$USER"/AppData/Roaming/Ableton/Live*/Preferences/Log.txt 2>/dev/null | head -1)"
[ -n "$LIVELOG" ] && tail -400 "$LIVELOG" > "$OUT/live-log-tail.txt" 2>/dev/null

echo
echo "==> collected in $OUT"
ls -la "$OUT"
