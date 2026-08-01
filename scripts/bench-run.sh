#!/usr/bin/env bash
# scripts/bench-run.sh — append one steady-state measurement row under fixed
# reference conditions.
#
# Usage: scripts/bench-run.sh <change-tag> [dsp-load-pct] [options]
#   e.g. scripts/bench-run.sh before/ntsync-on 42
#        scripts/bench-run.sh before/ntsync-on --quick
# Legacy form (kept for older notes): scripts/bench-run.sh <tag> <xruns> <dsp>
#   Three positional numbers mean operator-entered xruns over the 5-minute
#   protocol; the pw-top capture is skipped.
#
# Options:
#   --window S   xrun capture window in seconds (default 300)
#   --quick      shorthand for --window 60 (iteration runs, not evidence pairs)
#   --xruns N    operator-entered xrun count; skips the pw-top capture
#   --dsp N      Live DSP load meter reading (same as the positional argument)
#
# Reference conditions (identical for both rows of a pair): the committed
# reference set, 48 kHz / 256 frames, fixed window geometry, one machine per
# comparison. The unit of evidence is the pair — two rows tagged before/<change>
# and after/<change>, committed with the change; no performance claim without one.
#
# Automated metrics: wined3d_cs %CPU, Live whole-process %CPU, and the busiest
# non-CS Live thread (60 s of per-thread top samples, first frame discarded);
# the wineserver context-switch delta (60 s); the pw-top ERR delta for nodes
# matching BENCH_PW_NODE_RE over the xrun window; pw-metadata rate/quantum; and
# a version column set (Live, WebView2, GPU, PipeWire, kernel, runtime), since
# self-updating components are uncontrolled variables. The DSP column fills
# itself from the abl-bench-m4l device's /abl/bench/cpu reports (bench/m4l/)
# when the set carries the device; a value given on the command line wins.
# Anything that cannot be measured is recorded as NA with a warning; the
# row is always appended and the script never fails mid-run.
#
# Rows land in bench/results.csv (created with a header on first use).
# Overrides: ABLETON_WINE_ROOT (wineserver location), ABLETON_WINEPREFIX,
# BENCH_RESULTS_CSV (output file), BENCH_PW_NODE_RE (node match, extended
# regex), BENCH_WS_STATUS (wineserver /proc status file — testing only).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

warn() { echo "!! $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
csvsan() { printf '%s' "$1" | tr ',' ';' | tr -d '\n'; }
is_num() { case "$1" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }

tag="" dsp=NA xruns=NA window=300 capture_xruns=yes
pos=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --window) shift; is_num "${1:-}" || { warn "--window needs a number"; exit 2; }; window="$1" ;;
        --quick)  window=60 ;;
        --xruns)  shift; is_num "${1:-}" || { warn "--xruns needs a number"; exit 2; }; xruns="$1"; capture_xruns=no ;;
        --dsp)    shift; is_num "${1:-}" || { warn "--dsp needs a number"; exit 2; }; dsp="$1" ;;
        --*)      warn "unknown option $1"; exit 2 ;;
        *)        pos+=("$1") ;;
    esac
    shift
done
case "${#pos[@]}" in
    1) tag="${pos[0]}" ;;
    2) tag="${pos[0]}"; is_num "${pos[1]}" || { warn "dsp-load-pct must be a number (got '${pos[1]}')"; exit 2; }
       dsp="${pos[1]}" ;;
    3) # legacy: <tag> <xruns> <dsp>, operator-entered over the 5-minute protocol
       tag="${pos[0]}"
       is_num "${pos[1]}" && is_num "${pos[2]}" || { warn "legacy form needs numbers: <tag> <xruns> <dsp>"; exit 2; }
       xruns="${pos[1]}"; dsp="${pos[2]}"; capture_xruns=no; window=300 ;;
    *) warn "usage: bench-run.sh <change-tag> [dsp-load-pct] [--window S|--quick] [--xruns N]"; exit 2 ;;
esac
case "$tag" in
    ''|*,*) warn "change-tag must be non-empty and contain no comma (rows are CSV)"; exit 2 ;;
esac

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"
WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ---- background captures ------------------------------------------------
# pw-top ERR delta over the xrun window, for nodes matching the regex.
pw_re="${BENCH_PW_NODE_RE:-Ableton|Live|[Pp]ipe[Aa][Ss][Ii][Oo]}"
pw_pid=""
if [ "$capture_xruns" = yes ]; then
    if have pw-top; then
        ( LC_ALL=C timeout "$window" pw-top -b > "$tmp/pwtop" 2>/dev/null || true ) &
        pw_pid=$!
    else
        warn "pw-top not found — recording xruns=NA"
        capture_xruns=no
    fi
fi

# DSP load over OSC: when no operator value was given and the set carries the
# abl-bench-m4l device (bench/m4l/), listen for its /abl/bench/cpu reports
# during the sampling window and average them. An operator value always wins.
osc_pid=""
if [ "$dsp" = NA ] && [ -x "$here/bench-osc.py" ] && have python3; then
    ( exec timeout 60 "$here/bench-osc.py" dump > "$tmp/osc" 2>/dev/null || true ) &
    osc_pid=$!
fi

# Per-thread top samples of the Live process: 12 frames, 5 s apart; the first
# frame reports since-start averages and is discarded by the parser.
live_pid="" top_pid=""
if ! have pgrep || ! have top; then
    warn "pgrep/top not available — recording CPU columns as NA"
elif live_pid="$(pgrep -f 'Ableton Liv[e].*\.exe' | head -n 1)" && [ -n "$live_pid" ]; then
    ( LC_ALL=C COLUMNS=512 top -b -H -p "$live_pid" -d 5 -n 12 > "$tmp/top" 2>/dev/null || true ) &
    top_pid=$!
else
    warn "Ableton Live is not running — recording CPU columns as NA"
fi

# ---- wineserver context-switch delta over 60 s (concurrent with top) ----
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

# ---- collect the top capture -------------------------------------------
cs_pct=NA proc_pct=NA busy_pct=NA busy_comm=NA
if [ -n "$top_pid" ]; then
    wait "$top_pid" || true
    # One pass: frames delimited by "top -" headers; thread lines start with a
    # TID. Per frame, sum %CPU for the process total; per TID, average %CPU
    # across frames 2+, then pick the busiest thread that is not wined3d_cs.
    if out="$(awk '
        /^top -/ { frame++; next }
        frame >= 2 && $1 ~ /^[0-9]+$/ {
            ftot[frame] += $9
            tsum[$1] += $9; tcnt[$1]++; tcomm[$1] = $NF
            if ($NF == "wined3d_cs") { cssum += $9; cscnt++ }
        }
        END {
            frames = 0; ptot = 0
            for (f in ftot) { ptot += ftot[f]; frames++ }
            if (!frames) exit 1
            best = -1; bestid = ""
            for (t in tsum) {
                if (tcomm[t] == "wined3d_cs") continue
                a = tsum[t] / tcnt[t]
                if (a > best) { best = a; bestid = t }
            }
            printf "%.1f %.1f %.1f %s", (cscnt ? cssum / cscnt : 0), ptot / frames, \
                   (bestid != "" ? best : 0), (bestid != "" ? tcomm[bestid] : "NA")
        }' "$tmp/top")"; then
        read -r cs_pct proc_pct busy_pct busy_comm <<< "$out"
    else
        warn "collected no thread samples from pid $live_pid — recording CPU columns as NA"
    fi
fi

# ---- collect the pw-top capture ----------------------------------------
node_quant=NA
if [ "$capture_xruns" = yes ] && [ -n "$pw_pid" ]; then
    wait "$pw_pid" || true
    # Columns: S ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME; ERR is $9.
    # Delta per node ID between its first and last sample, summed over nodes
    # matching the regex; a counter that went backwards (node restart) counts
    # from zero. Only live samples count (RATE > 0): pw-top also prints a
    # zeroed state row per node, which would fake a delta from zero.
    if x="$(awk -v re="$pw_re" '
        $9 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $4 > 0 && $0 ~ re {
            id = $2
            if (!(id in first)) first[id] = $9
            last[id] = $9; seen = 1
            if ($3 ~ /^[0-9]+$/ && $3 > 0) quant = $3
        }
        END {
            if (!seen) exit 1
            s = 0
            for (id in first) { d = last[id] - first[id]; s += (d > 0 ? d : 0) }
            print s, (quant ? quant : "NA")
        }' "$tmp/pwtop")"; then
        read -r xruns node_quant <<< "$x"
    else
        warn "no PipeWire node matched /$pw_re/ in pw-top output — recording xruns=NA"
        xruns=NA
    fi
fi

# ---- collect the OSC dsp capture ---------------------------------------
if [ -n "$osc_pid" ]; then
    wait "$osc_pid" || true
    if d="$(awk '$2 == "/abl/bench/cpu" && $3 >= 0 {s += $3; n++}
                 END {if (!n) exit 1; printf "%.1f", s / n}' "$tmp/osc")"; then
        dsp="$d"
    else
        warn "no /abl/bench/cpu reports on UDP 19002 — is the abl-bench-m4l device in the set? recording dsp_load_pct=NA"
    fi
fi

# ---- graph settings and versions ---------------------------------------
pw_rate=NA pw_quantum=NA pw_force_quantum=NA
if have pw-metadata; then
    meta="$(timeout 10 pw-metadata -n settings 2>/dev/null || true)"
    v() { printf '%s\n' "$meta" | sed -n "s/.*key:'$1' value:'\([^']*\)'.*/\1/p" | head -n 1; }
    r="$(v clock.rate)";          [ -n "$r" ] && pw_rate="$r"
    q="$(v clock.quantum)";       [ -n "$q" ] && pw_quantum="$q"
    fq="$(v clock.force-quantum)"; [ -n "$fq" ] && pw_force_quantum="$fq"
else
    warn "pw-metadata not found — recording graph settings as NA"
fi

live_ver=NA
lv="$(ls -d "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/Ableton/Live\ [0-9]* 2>/dev/null | sort -V | tail -n 1 || true)"
[ -n "$lv" ] && live_ver="$(basename "$lv" | sed 's/^Live //')"

wv2_ver=NA
wv="$(ls -d "$WINEPREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"/[0-9]* 2>/dev/null | sort -V | tail -n 1 || true)"
[ -n "$wv" ] && wv2_ver="$(basename "$wv")"

gpu=NA
if have glxinfo; then
    g="$(glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: //p' | head -n 1)"
    [ -n "$g" ] && gpu="$(csvsan "$g")"
fi

pw_ver=NA
if have pw-cli; then
    p="$(pw-cli --version 2>/dev/null | awk '/Linked with/ {print $NF}')"
    [ -n "$p" ] && pw_ver="$p"
fi

kernel="$(uname -r)"

runtime_ver=NA
if [ -r "$WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt" ]; then
    runtime_ver="$(awk '/^dist-version:/ {print $2; exit}' "$WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt")"
elif [ -r "$HOME/.local/share/ableton-wine/VERSION" ]; then
    runtime_ver="$(cat "$HOME/.local/share/ableton-wine/VERSION")"
else
    runtime_ver="$(basename "$WINE_ROOT")"
fi

# ---- append the row ------------------------------------------------------
csv="${BENCH_RESULTS_CSV:-$root/bench/results.csv}"
mkdir -p "$(dirname "$csv")"
header="timestamp,tag,wined3d_cs_pct,live_proc_pct,busy_thread_pct,busy_thread_comm,wineserver_ctxt_delta,xruns,xrun_window_s,dsp_load_pct,pw_rate,pw_quantum,pw_force_quantum,pw_node_quantum,live_version,webview2_version,gpu_renderer,pipewire_version,kernel,runtime_version"
if [ ! -s "$csv" ]; then
    echo "$header" > "$csv"
elif [ "$(head -n 1 "$csv")" != "$header" ]; then
    warn "existing $csv has a different header — appending anyway; migrate or set BENCH_RESULTS_CSV"
fi
printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%FT%TZ)" "$tag" "$cs_pct" "$proc_pct" "$busy_pct" "$(csvsan "$busy_comm")" \
    "$ws_delta" "$xruns" "$window" "$dsp" \
    "$pw_rate" "$pw_quantum" "$pw_force_quantum" "$node_quant" \
    "$(csvsan "$live_ver")" "$wv2_ver" "$gpu" "$pw_ver" "$(csvsan "$kernel")" "$(csvsan "$runtime_ver")" >> "$csv"
echo "appended to $csv:"
echo "   tag=$tag cs=$cs_pct proc=$proc_pct busy=$busy_pct($busy_comm) ws_ctxt=$ws_delta xruns=$xruns/${window}s dsp=$dsp"
echo "   graph rate=$pw_rate quantum=$pw_quantum forced=$pw_force_quantum node=$node_quant live=$live_ver wv2=$wv2_ver runtime=$runtime_ver"
