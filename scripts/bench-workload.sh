#!/usr/bin/env bash
# scripts/bench-workload.sh — scripted workload benchmark: launch Live, watch
# its Log.txt, and record per-phase load times derived from the log's own
# microsecond timestamps.
#
# Usage: scripts/bench-workload.sh <change-tag> [options]
#   e.g. scripts/bench-workload.sh before/apc-fastpath --set bench/sets/30-m4l.als -n 3
#
# Options:
#   --set FILE.als    open this set (scenario = file basename); default is a
#                     bare startup (scenario = startup)
#   -n, --iterations N   full launch/quit cycles (default 1)
#   --timeout S       per-iteration ceiling (default 300)
#   --quiet-s S       log silence that ends an iteration (default 10)
#   --keep-open       leave Live running after the last iteration (no quit)
#   --parse-log FILE  parser-only mode: extract metrics from an existing log
#                     slice and print them; no launch, nothing appended.
#                     --set-name NAME scopes the set_load metric.
#
# What lands in bench/workload.csv (long format, one row per metric):
#   startup_to_audio_open   Started -> ASIO "Open: finished"
#   startup_to_first_doc    Started -> first "End ExchangeDocument"
#   set_load                "Loading document <set>" -> next "End ExchangeDocument"
#   plugin_scan             "Scan start" -> "scanner process stopped"
#   max_boot                Started -> "Max: Version" (M4L runtime up)
#   vst3_create:<name>      per plugin: "successfully loaded" -> "Created: <name>"
#   wall_to_quiet           launch -> last log growth, runner's own clock
# All deltas except wall_to_quiet come from Live's log timestamps, so polling
# cadence does not blur them.
#
# The script refuses to run while Live is already up: it must never touch a
# working session. Each iteration ends with wineserver -k, so every launch
# boots a fresh wineserver; warm_start records whether one was already
# running when the iteration launched. Live's DSP meter is not read here;
# steady-state metrics belong to bench-run.sh.
#
# Overrides: ABLETON_WINE_ROOT, ABLETON_WINEPREFIX, ABLETON_LAUNCHER,
# BENCH_WORKLOAD_CSV (output file).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

warn() { echo "!! $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
csvsan() { printf '%s' "$1" | tr ',' ';' | tr -d '\n'; }
now() { echo "${EPOCHREALTIME:-$(date +%s.%N)}"; }

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"
export WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
LAUNCH="${ABLETON_LAUNCHER:-$HOME/.local/bin/ableton-live}"

# ---- the parser ---------------------------------------------------------
# stdin: a Log.txt slice. Prints "metric value" lines (values in seconds,
# except live_version/live_build which are strings). POSIX awk: timestamps
# reduce to seconds-of-day; deltas repair a midnight wrap.
parse_slice() {  # $1 = set basename or empty
    awk -v setbase="${1:-}" '
    function ts(line,    s, t2) {
        if (match(line, /^[0-9]+-[0-9]+-[0-9]+T[0-9]+:[0-9]+:[0-9]+\.[0-9]+/) == 0) return -1
        s = substr(line, RSTART, RLENGTH)
        sub(/^[^T]*T/, "", s)
        split(s, t2, ":")
        return t2[1] * 3600 + t2[2] * 60 + t2[3]
    }
    function delta(t, t0,    d) { d = t - t0; if (d < -1) d += 86400; return d }
    function emit(m, v) { printf "%s %.3f\n", m, v }

    t0 < 0 || t0 == "" { t0 = -1 }   # first record only
    /Started: Live/ && t0 == -1 {
        t0 = ts($0)
        if (match($0, /Started: Live [0-9.]+/)) {
            v = substr($0, RSTART + 14, RLENGTH - 14)
            print "live_version " v
        }
        if (match($0, /Build: [^ ]+/))
            print "live_build " substr($0, RSTART + 7, RLENGTH - 7)
        next
    }
    t0 == -1 { next }
    /Open: finished/ && !audio_open   { audio_open = 1; emit("startup_to_audio_open", delta(ts($0), t0)) }
    /End ExchangeDocument/ && !first_doc { first_doc = 1; emit("startup_to_first_doc", delta(ts($0), t0)) }
    /PluginManager: Scan start/ && !scan0 { scan0 = ts($0) }
    /Plugins: scanner process stopped/ && scan0 && !scan_done {
        scan_done = 1; emit("plugin_scan", delta(ts($0), scan0))
    }
    /Max: Version/ && !max_seen { max_seen = 1; emit("max_boot", delta(ts($0), t0)) }
    /Loading document/ && setbase != "" && index($0, setbase) && !setload0 { setload0 = ts($0) }
    /End ExchangeDocument/ && setload0 && !setload_done {
        setload_done = 1; emit("set_load", delta(ts($0), setload0))
    }
    /VST3: plugin processor successfully loaded:/ { vst_loaded = ts($0) }
    /VST3: Created: / && vst_loaded {
        name = $NF; gsub(/,/, "", name)
        emit("vst3_create:" name, delta(ts($0), vst_loaded))
        vst_loaded = 0
    }
    END { if (t0 == -1) { print "no Started: line in slice" > "/dev/stderr"; exit 3 } }
    '
}

# ---- argument parsing ---------------------------------------------------
tag="" set_file="" iterations=1 timeout=300 quiet_s=10 keep_open=no
parse_log="" set_name=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --set)        shift; set_file="${1:-}" ;;
        -n|--iterations) shift; iterations="${1:-}" ;;
        --timeout)    shift; timeout="${1:-}" ;;
        --quiet-s)    shift; quiet_s="${1:-}" ;;
        --keep-open)  keep_open=yes ;;
        --parse-log)  shift; parse_log="${1:-}" ;;
        --set-name)   shift; set_name="${1:-}" ;;
        --*)          warn "unknown option $1"; exit 2 ;;
        *)            [ -z "$tag" ] && tag="$1" || { warn "unexpected argument $1"; exit 2; } ;;
    esac
    shift
done

if [ -n "$parse_log" ]; then
    [ -r "$parse_log" ] || { warn "cannot read $parse_log"; exit 2; }
    parse_slice "$set_name" < "$parse_log"
    exit $?
fi

[ -n "$tag" ] || { warn "usage: bench-workload.sh <change-tag> [--set FILE.als] [-n N]"; exit 2; }
case "$tag" in *,*) warn "change-tag must not contain a comma (rows are CSV)"; exit 2 ;; esac
case "$iterations$timeout$quiet_s" in *[!0-9]*) warn "iterations/timeout/quiet-s must be integers"; exit 2 ;; esac
scenario=startup set_base=""
if [ -n "$set_file" ]; then
    [ -f "$set_file" ] || { warn "set not found: $set_file"; exit 2; }
    set_file="$(cd "$(dirname "$set_file")" && pwd)/$(basename "$set_file")"
    set_base="$(basename "$set_file")"
    scenario="$(csvsan "$set_base")"
fi
[ -x "$LAUNCH" ] || { warn "launcher not found at $LAUNCH"; exit 2; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { warn "needs a desktop session (DISPLAY unset)"; exit 2; }
if pgrep -f "Ableton Liv[e].*\.exe" >/dev/null 2>&1; then
    warn "Ableton Live is already running; this benchmark launches and quits Live and must not touch a working session"
    exit 1
fi

log_dir="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/Ableton"
live_log="$(ls -d "$log_dir"/Live\ [0-9]*/Preferences/Log.txt 2>/dev/null | sort -V | tail -n 1 || true)"
[ -n "$live_log" ] || { warn "no Live Log.txt under $log_dir: is Live installed?"; exit 2; }

runtime_ver=NA
if [ -r "$WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt" ]; then
    runtime_ver="$(awk '/^dist-version:/ {print $2; exit}' "$WINE_ROOT/ABLETON-WINE-BUILD-INFO.txt")"
elif [ -r "$HOME/.local/share/ableton-wine/VERSION" ]; then
    runtime_ver="$(cat "$HOME/.local/share/ableton-wine/VERSION")"
fi

csv="${BENCH_WORKLOAD_CSV:-$root/bench/workload.csv}"
mkdir -p "$(dirname "$csv")"
header="timestamp,tag,scenario,iteration,warm_start,metric,seconds,live_version,live_build,runtime_version"
if [ ! -s "$csv" ]; then
    echo "$header" > "$csv"
elif [ "$(head -n 1 "$csv")" != "$header" ]; then
    warn "existing $csv has a different header — appending anyway; migrate or set BENCH_WORKLOAD_CSV"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

quit_live() {
    "$WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        pgrep -f "Ableton Liv[e].*\.exe" >/dev/null 2>&1 || return 0
        sleep 2
    done
    warn "Live still running 30 s after wineserver -k"
}

for it in $(seq 1 "$iterations"); do
    warm=no
    pgrep -f "$WINE_ROOT.*bin/wineserver" >/dev/null 2>&1 && warm=yes
    base="$(wc -l < "$live_log")"
    t_launch="$(now)"
    if [ -n "$set_file" ]; then
        setsid nohup "$LAUNCH" "$set_file" > "$tmp/launch-$it.log" 2>&1 &
    else
        setsid nohup "$LAUNCH" > "$tmp/launch-$it.log" 2>&1 &
    fi
    echo "== iteration $it/$iterations: launched (scenario=$scenario warm_start=$warm log baseline: line $base) =="

    last_n="$base" t_growth="$t_launch" outcome=timeout
    deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        sleep 2
        n="$(wc -l < "$live_log" 2>/dev/null || echo "$last_n")"
        t="$(now)"
        if [ "$n" -gt "$last_n" ]; then last_n="$n"; t_growth="$t"; fi
        if [ "$last_n" -gt "$base" ] && awk -v a="$t" -v b="$t_growth" -v q="$quiet_s" 'BEGIN{exit !(a-b>=q)}'; then
            outcome=quiet; break
        fi
        if ! pgrep -f "Ableton Liv[e].*\.exe" >/dev/null 2>&1 && [ "$last_n" -gt "$base" ]; then
            outcome=died; break
        fi
    done
    [ "$outcome" = timeout ] && warn "iteration $it hit the ${timeout}s ceiling; parsing what was logged"
    [ "$outcome" = died ] && warn "iteration $it: Live exited on its own; parsing what was logged"

    tail -n +"$((base + 1))" "$live_log" > "$tmp/slice-$it" 2>/dev/null || true
    wall="$(awk -v a="$t_growth" -v b="$t_launch" 'BEGIN{printf "%.1f", a-b}')"

    live_ver=NA live_build=NA rows=0
    stamp="$(date -u +%FT%TZ)"
    if parse_slice "$set_base" < "$tmp/slice-$it" > "$tmp/metrics-$it"; then
        while read -r metric value; do
            case "$metric" in
                live_version) live_ver="$value"; continue ;;
                live_build)   live_build="$value"; continue ;;
            esac
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$stamp" "$tag" "$scenario" "$it" "$warm" \
                "$(csvsan "$metric")" "$value" "$(csvsan "$live_ver")" "$(csvsan "$live_build")" \
                "$(csvsan "$runtime_ver")" >> "$csv"
            rows=$((rows + 1))
        done < "$tmp/metrics-$it"
    else
        warn "iteration $it: no parsable startup in the log slice (outcome=$outcome)"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$stamp" "$tag" "$scenario" "$it" "$warm" \
        "wall_to_quiet" "$wall" "$(csvsan "$live_ver")" "$(csvsan "$live_build")" \
        "$(csvsan "$runtime_ver")" >> "$csv"
    rows=$((rows + 1))
    echo "   $rows rows appended (outcome=$outcome, wall_to_quiet=${wall}s)"
    sed 's/^/   /' "$tmp/metrics-$it" 2>/dev/null || true

    if [ "$keep_open" = yes ] && [ "$it" -eq "$iterations" ]; then
        echo "   leaving Live open (--keep-open)"
    else
        quit_live
    fi
done
echo "done: $csv"
