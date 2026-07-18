#!/usr/bin/env bash
# scripts/bench-run.sh — append one measurement row under fixed reference conditions.
#
# Usage: scripts/bench-run.sh <change-tag> <xruns-5min> <dsp-load-pct>
#   e.g. scripts/bench-run.sh before/ntsync-on 3 42
#
# Reference conditions (identical for both rows of a pair): the committed
# reference set, 48 kHz / 256 frames, fixed window geometry, one machine per
# comparison. The unit of evidence is the pair — two rows tagged before/<change>
# and after/<change>, committed with the change; no performance claim without one.
#
# Two metrics are automated: wined3d_cs %CPU (60 s of per-thread top samples
# against the running Live) and the wineserver context-switch delta (60 s). Two
# are operator-entered at fixed playback points: xruns per 5 minutes (the pw-top
# ERR delta) and Live's DSP load reading at the marker bar. Anything that cannot
# be measured — Live not running, wineserver or tools absent — is recorded as NA
# with a warning; the row is always appended and the script never fails mid-run.
#
# Rows land in bench/results.csv (created with a header on first use).
# Overrides: ABLETON_WINE_ROOT (wineserver location), BENCH_RESULTS_CSV (output
# file), BENCH_WS_STATUS (wineserver /proc status file — testing only).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

warn() { echo "!! $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$#" -ne 3 ]; then
    warn "usage: bench-run.sh <change-tag> <xruns-5min> <dsp-load-pct> (e.g. before/ntsync-on 3 42)"
    exit 2
fi
tag="$1"
xruns="$2"   # pw-top ERR delta over a 5-minute reference playback
dsp="$3"     # Live DSP load meter reading at the marker bar

case "$tag" in
    *,*) warn "change-tag must not contain a comma (rows are CSV)"; exit 2 ;;
esac
for v in "$xruns" "$dsp"; do
    case "$v" in
        ''|*[!0-9.]*) warn "xruns-5min and dsp-load-pct must be numbers (got '$v')"; exit 2 ;;
    esac
done

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.11}"

# The xruns figure is operator-entered from pw-top's ERR delta over the reference
# playback; without pw-top there is no sanctioned way to have measured it.
have pw-top || warn "pw-top not found — the xruns-5min figure cannot have come from the pw-top ERR delta"

# wined3d_cs %CPU: average over 60 s of per-thread top samples of the Live process.
cs_pct=NA
if ! have pgrep || ! have top; then
    warn "pgrep/top not available — recording wined3d_cs_pct=NA"
elif pid="$(pgrep -f 'Ableton Live.*\.exe' | head -n 1)" && [ -n "$pid" ]; then
    if cs="$(top -b -H -p "$pid" -d 5 -n 12 \
              | awk '$NF=="wined3d_cs" {s+=$9; n++} END {if (n) printf "%.1f", s/n; else exit 1}')"; then
        cs_pct="$cs"
    else
        warn "collected no wined3d_cs thread samples from pid $pid — recording wined3d_cs_pct=NA"
    fi
else
    warn "Ableton Live is not running — recording wined3d_cs_pct=NA"
fi

# wineserver context-switch delta over 60 s (voluntary + nonvoluntary counters).
ws_ctxt_switches() {  # status-file -> summed ctxt switches of that process
    awk '/ctxt_switches/ {s+=$2} END {print s+0}' "$1"
}
ws_delta=NA
ws_status="${BENCH_WS_STATUS:-}"
if [ -z "$ws_status" ]; then
    if ! have pgrep; then
        warn "pgrep not available — recording wineserver_ctxt_delta=NA"
    # wine re-execs wineserver with argv0 lib/wine/../../bin/wineserver, so a
    # literal "$WINE_ROOT/bin/wineserver" pattern misses the running server.
    elif ws="$(pgrep -f "$WINE_ROOT.*bin/wineserver" | head -n 1)" && [ -n "$ws" ]; then
        ws_status="/proc/$ws/status"
    else
        warn "no wineserver from $WINE_ROOT is running — recording wineserver_ctxt_delta=NA"
    fi
fi
if [ -n "$ws_status" ]; then
    if c0="$(ws_ctxt_switches "$ws_status" 2>/dev/null)"; then
        sleep 60
        if c1="$(ws_ctxt_switches "$ws_status" 2>/dev/null)"; then
            ws_delta=$((c1 - c0))
        else
            warn "wineserver status went away mid-sample — recording wineserver_ctxt_delta=NA"
        fi
    else
        warn "cannot read $ws_status — recording wineserver_ctxt_delta=NA"
    fi
fi

csv="${BENCH_RESULTS_CSV:-$root/bench/results.csv}"
mkdir -p "$(dirname "$csv")"
if [ ! -s "$csv" ]; then
    echo "timestamp,tag,wined3d_cs_pct,wineserver_ctxt_delta,xruns_5min,dsp_load_pct" > "$csv"
fi
printf '%s,%s,%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$tag" "$cs_pct" "$ws_delta" "$xruns" "$dsp" >> "$csv"
echo "appended to $csv: tag=$tag wined3d_cs_pct=$cs_pct wineserver_ctxt_delta=$ws_delta xruns_5min=$xruns dsp_load_pct=$dsp"
