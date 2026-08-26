#!/usr/bin/env bash
# Run the canonical five-set benchmark in a fixed order.  Live lifecycle is
# guarded by an exact runtime/prefix match and a per-launch environment token.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/config.sh"
ableton_config_init
. "$here/lib/lifecycle.sh"

sets=(Benchmark_Zero Benchmark_Empty Benchmark_Inbuilts Benchmark_Max4Live Benchmark_VSTs)
duration="${ABLETON_BENCH_DURATION:-30}"
launch_timeout="${ABLETON_BENCH_LAUNCH_TIMEOUT:-180}"
settle="${ABLETON_BENCH_SETTLE_SECONDS:-5}"
tag="manual"
output=""
launcher="${ABLETON_BENCH_LAUNCHER:-$here/ableton-live}"
dry_run=0
skip_vst_check=0
declare -A crackle=()

usage()
{
    cat <<'EOF'
usage: scripts/bench-suite.sh [options]

  --tag LABEL                 comparison/release label (default manual)
  --output DIR                new report directory (default bench/reports/<UTC>-LABEL)
  --duration SECONDS          every CPU/OSC/PipeWire window (default exactly 30)
  --launch-timeout SECONDS    set-load readiness ceiling (default 180)
  --settle SECONDS            quiet/stabilisation period outside the window (default 5)
  --crackle SET=STATE         manual observation: heard, not-heard, or unknown
  --launcher PATH             launcher to invoke (testing/installed override)
  --skip-vst-check            permit a deliberately incomplete VST fixture
  --dry-run                   run every preflight and print the immutable plan; launch nothing

Order is always Benchmark_Zero, Empty, Inbuilts, Max4Live, VSTs. Zero is an
idle/no-controller measurement; the remaining sets are rewound and played by
their committed Max for Live OSC device. Generated output includes raw evidence,
report.json, and report.md. The suite never invokes wineserver -k.
EOF
}

fail()
{
    printf 'bench-suite: %s\n' "$*" >&2
    exit 1
}

whole_seconds()
{
    local value="$1" name="$2" maximum="$3"
    case "$value" in ''|*[!0-9]*) fail "$name must be a whole number of seconds" ;; esac
    [ "$value" -ge 1 ] && [ "$value" -le "$maximum" ] \
        || fail "$name must be between 1 and $maximum seconds"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag) shift; tag="${1:-}" ;;
        --output) shift; output="${1:-}" ;;
        --duration) shift; duration="${1:-}" ;;
        --launch-timeout) shift; launch_timeout="${1:-}" ;;
        --settle) shift; settle="${1:-}" ;;
        --launcher) shift; launcher="${1:-}" ;;
        --crackle)
            shift
            observation="${1:-}"
            case "$observation" in *=*) ;;
                *) fail "--crackle wants SET=heard, SET=not-heard, or SET=unknown" ;;
            esac
            observation_set="${observation%%=*}"
            observation_state="${observation#*=}"
            case "$observation_set" in
                Zero|Empty|Inbuilts|Max4Live|VSTs) observation_set="Benchmark_$observation_set" ;;
            esac
            case " ${sets[*]} " in *" $observation_set "*) ;;
                *) fail "unknown crackle set: $observation_set" ;;
            esac
            case "$observation_state" in heard|not-heard|unknown) ;;
                *) fail "invalid crackle observation: $observation_state" ;;
            esac
            crackle["$observation_set"]="$observation_state"
            ;;
        --skip-vst-check) skip_vst_check=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

whole_seconds "$duration" duration 3600
whole_seconds "$launch_timeout" launch-timeout 3600
whole_seconds "$settle" settle 120
case "$tag" in ''|*$'\n'*|*$'\r'*) fail "tag must be one non-empty line" ;; esac
safe_tag="$(printf '%s' "$tag" | tr -cs '[:alnum:]_.-' '-')"
safe_tag="${safe_tag#-}"; safe_tag="${safe_tag%-}"
[ -n "$safe_tag" ] || safe_tag=run
[ -n "$output" ] || output="$root/bench/reports/$(date -u +%Y%m%dT%H%M%SZ)-$safe_tag"
output="$(ableton_realpath_m "$output")"
proc_root=/proc
if [ "$dry_run" -eq 1 ] && [ "${ABLETON_BENCH_TESTING:-0}" = 1 ]; then
    proc_root="${ABLETON_BENCH_PROC_ROOT:-/proc}"
fi

global_live_pids()
{
    local process pid cmd
    for process in "$proc_root"/[0-9]*; do
        [ -d "$process" ] || continue
        pid="${process##*/}"
        cmd="$(tr '\0' ' ' < "$process/cmdline" 2>/dev/null || true)"
        case "$cmd" in *"Ableton Live"*.exe*) printf '%s\n' "$pid" ;; esac
    done
    return 0
}

find_vst()
{
    local name="$1" candidate
    for candidate in \
        "$ABLETON_WINEPREFIX/drive_c/Program Files/Common Files/VST3/$name" \
        "$ABLETON_WINEPREFIX/drive_c/Program Files/VSTPlugins/$name"; do
        [ -e "$candidate" ] && return 0
    done
    return 1
}

preflight()
{
    local set_name set_file live_pids prefix_pids live_exes=()
    command -v python3 >/dev/null 2>&1 || fail "python3 is required"
    command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
    command -v setsid >/dev/null 2>&1 || fail "setsid is required for a supervised launcher"
    command -v tee >/dev/null 2>&1 || fail "tee is required to retain the suite log"
    [ -x "$launcher" ] || fail "launcher is not executable: $launcher"
    [ -x "$ABLETON_WINE_ROOT/bin/wine" ] || fail "Wine is missing at $ABLETON_WINE_ROOT/bin/wine"
    [ -x "$ABLETON_WINE_ROOT/bin/wineserver" ] || fail "wineserver is missing at $ABLETON_WINE_ROOT/bin/wineserver"
    [ -f "$ABLETON_WINEPREFIX/system.reg" ] || fail "prefix is incomplete: $ABLETON_WINEPREFIX"
    for set_name in "${sets[@]}"; do
        set_file="$root/bench/BenchmarkSets Project/$set_name.als"
        [ -s "$set_file" ] || fail "benchmark set is missing: $set_file"
    done
    ( cd "$root" && sha256sum -c bench/SHA256SUMS >/dev/null ) \
        || fail "a canonical benchmark asset differs from bench/SHA256SUMS"
    if find "$root/bench" -type d -name Backup -print -quit | grep -q .; then
        fail "a Live Backup directory is present under bench; canonical assets must remain clean"
    fi
    mapfile -t live_exes < <(find "$ABLETON_WINEPREFIX/drive_c/ProgramData/Ableton" \
        -path '*/Program/Ableton Live*.exe' -type f -print 2>/dev/null | sort -V)
    [ "${#live_exes[@]}" -gt 0 ] || fail "no Ableton Live executable was found in the configured prefix"
    if [ "$skip_vst_check" -ne 1 ]; then
        find_vst Dexed.vst3 || fail "Benchmark_VSTs requires Dexed.vst3 (use --skip-vst-check only for a deliberate fixture)"
        find_vst K1v_x64.vst3 || fail "Benchmark_VSTs requires K1v_x64.vst3 (use --skip-vst-check only for a deliberate fixture)"
    fi
    live_pids="$(global_live_pids)"
    [ -z "$live_pids" ] || fail "an Ableton Live session already exists (pid(s): $(printf '%s' "$live_pids" | tr '\n' ' ')); close it first"
    prefix_pids="$(ableton_prefix_pids)"
    [ -z "$prefix_pids" ] || fail "the configured Wine prefix is already active (pid(s): $(printf '%s' "$prefix_pids" | tr '\n' ' ')); close it first"
    if [ "$dry_run" -ne 1 ] || [ "${ABLETON_BENCH_TESTING:-0}" != 1 ]; then
        python3 "$here/bench-report.py" check-udp --port "${ABL_BENCH_OSC_RECV:-19002}" \
            || fail "the benchmark OSC receive port is already in use"
    fi
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || fail "a desktop session is required (DISPLAY and WAYLAND_DISPLAY are unset)"
    case "$output" in
        "$ABLETON_WINE_ROOT"|"$ABLETON_WINE_ROOT"/*|"$ABLETON_WINEPREFIX"|"$ABLETON_WINEPREFIX"/*|\
        "$root/bench/BenchmarkSets Project"|"$root/bench/BenchmarkSets Project"/*)
            fail "output must not overlap the runtime, prefix, or immutable set project: $output" ;;
    esac
    [ ! -e "$output" ] || fail "output already exists; refusing to overwrite: $output"
}

preflight

if [ "$dry_run" -eq 1 ]; then
    printf 'benchmark dry-run: duration=%ss output=%s\n' "$duration" "$output"
    for index in "${!sets[@]}"; do
        set_name="${sets[index]}"
        mode=playback
        [ "$set_name" != Benchmark_Zero ] || mode=idle-no-controller
        printf '%d\t%s\t%s\t%ss\n' "$((index + 1))" "$set_name" "$mode" "$duration"
    done
    exit 0
fi

mkdir -p -- "$output/sets"
exec > >(tee -a "$output/suite.log") 2>&1
run_id="bench-$(date -u +%Y%m%dT%H%M%SZ)-$$"
init_args=(init-run --output "$output/run.json" --tag "$tag" --duration "$duration")
for set_name in "${sets[@]}"; do init_args+=(--set "$set_name"); done
python3 "$here/bench-report.py" "${init_args[@]}"
python3 "$here/bench-report.py" profile \
    --output "$output/profile" \
    --prefix "$ABLETON_WINEPREFIX" \
    --wine-root "$ABLETON_WINE_ROOT" \
    --config-file "$ABLETON_CONFIG_FILE"

active_token=""
launcher_pid=""
finalized=0

owned_live_pids()
{
    local pid
    [ -n "$active_token" ] || return 0
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        ableton_pid_has_env "$pid" "ABLETON_BENCH_RUN_ID=$active_token" || continue
        printf '%s\n' "$pid"
    done < <(ableton_live_pids)
    return 0
}

wait_for_owned_live()
{
    local deadline=$((SECONDS + launch_timeout)) pids foreign pid
    while [ "$SECONDS" -lt "$deadline" ]; do
        pids="$(owned_live_pids)"
        [ -z "$pids" ] || { printf '%s\n' "$pids"; return 0; }
        foreign=""
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            ableton_pid_has_env "$pid" "ABLETON_BENCH_RUN_ID=$active_token" || foreign="${foreign:+$foreign }$pid"
        done < <(ableton_live_pids)
        [ -z "$foreign" ] || fail "a non-runner Live appeared in the benchmark prefix (pid(s): $foreign)"
        [ -z "$launcher_pid" ] || kill -0 "$launcher_pid" 2>/dev/null \
            || fail "launcher exited before runner-owned Live appeared"
        sleep 0.2
    done
    fail "runner-owned Live did not appear within ${launch_timeout}s"
}

latest_live_log()
{
    local path newest="" newest_time=0 stamp
    for path in "$ABLETON_WINEPREFIX"/drive_c/users/*/AppData/Roaming/Ableton/Live\ */Preferences/Log.txt; do
        [ -f "$path" ] || continue
        stamp="$(stat -c %Y -- "$path" 2>/dev/null || printf 0)"
        if [ "$stamp" -ge "$newest_time" ]; then newest="$path"; newest_time="$stamp"; fi
    done
    [ -n "$newest" ] && printf '%s\n' "$newest"
}

wait_log_quiet()
{
    local deadline=$((SECONDS + launch_timeout)) quiet_since=$SECONDS log signature="" previous=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        log="$(latest_live_log || true)"
        if [ -n "$log" ]; then
            signature="$(stat -c '%s:%Y' -- "$log" 2>/dev/null || true)"
            if [ "$signature" != "$previous" ]; then
                previous="$signature"
                quiet_since=$SECONDS
            elif [ $((SECONDS - quiet_since)) -ge "$settle" ]; then
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

stop_owned_session()
{
    local pids pid deadline remaining="" rc=0
    [ -n "$active_token" ] || return 0
    pids="$(owned_live_pids)"
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        ableton_pid_has_env "$pid" "ABLETON_BENCH_RUN_ID=$active_token" || continue
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids"
    deadline=$((SECONDS + 15))
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining="$(owned_live_pids)"
        [ -z "$remaining" ] && break
        sleep 0.2
    done
    # A crashed/blocked Live must not strand the automated suite. KILL remains
    # exact-pid and is repeated only after the run token is revalidated.
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        ableton_pid_has_env "$pid" "ABLETON_BENCH_RUN_ID=$active_token" || continue
        kill -KILL "$pid" 2>/dev/null || true
    done <<< "$remaining"
    if [ -n "$launcher_pid" ]; then
        deadline=$((SECONDS + 20))
        while kill -0 "$launcher_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
        if kill -0 "$launcher_pid" 2>/dev/null; then
            if ableton_pid_has_env "$launcher_pid" "ABLETON_BENCH_RUN_ID=$active_token"; then
                kill -TERM "$launcher_pid" 2>/dev/null || true
                deadline=$((SECONDS + 5))
                while kill -0 "$launcher_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
                if kill -0 "$launcher_pid" 2>/dev/null \
                   && ableton_pid_has_env "$launcher_pid" "ABLETON_BENCH_RUN_ID=$active_token"; then
                    kill -KILL "$launcher_pid" 2>/dev/null || true
                fi
            else
                printf 'bench-suite: refusing to signal reused/unowned launcher pid %s\n' "$launcher_pid" >&2
                rc=1
            fi
        fi
        wait "$launcher_pid" 2>/dev/null || true
    fi
    active_token=""
    launcher_pid=""
    return "$rc"
}

finish()
{
    local rc=$? status=failed
    trap - EXIT HUP INT TERM
    stop_owned_session || true
    if [ "$finalized" -ne 1 ]; then
        [ "$rc" -lt 128 ] || status=interrupted
        python3 "$here/bench-report.py" update-run --output "$output/run.json" --status "$status" 2>/dev/null || true
        python3 "$here/bench-report.py" render --run-dir "$output" 2>/dev/null || true
    fi
    exit "$rc"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for index in "${!sets[@]}"; do
    set_name="${sets[index]}"
    existing_live="$(global_live_pids)"
    [ -z "$existing_live" ] \
        || fail "another Live session appeared before $set_name (pid(s): $(printf '%s' "$existing_live" | tr '\n' ' '))"
    set_file="$root/bench/BenchmarkSets Project/$set_name.als"
    set_dir="$output/sets/$(printf '%02d' "$((index + 1))")-$set_name"
    mkdir -p -- "$set_dir/raw"
    mode=playback
    osc=on
    if [ "$set_name" = Benchmark_Zero ]; then mode=idle-no-controller; osc=off; fi
    active_token="$run_id:$set_name"
    printf '== %d/5 %s: launch ==\n' "$((index + 1))" "$set_name"
    ABLETON_BENCH_RUN_ID="$active_token" setsid -- "$launcher" "$set_file" \
        > "$set_dir/raw/launcher.log" 2>&1 &
    launcher_pid=$!
    mapfile -t current_live < <(wait_for_owned_live)
    [ "${#current_live[@]}" -gt 0 ] || fail "no owned Live pid was returned"

    if [ "$osc" = on ]; then
        python3 "$here/bench-osc.py" probe --timeout "$launch_timeout" \
            > "$set_dir/raw/osc-probe.txt" 2> "$set_dir/raw/osc-probe.stderr.txt" \
            || fail "$set_name control device did not answer"
        wait_log_quiet || fail "$set_name log did not settle within ${launch_timeout}s"
        python3 "$here/bench-osc.py" send /abl/bench/rewind
        python3 "$here/bench-osc.py" send /abl/bench/play
        sleep "$settle"
    else
        wait_log_quiet || fail "$set_name log did not settle within ${launch_timeout}s"
    fi

    printf '== %d/5 %s: measure %ss ==\n' "$((index + 1))" "$set_name" "$duration"
    capture_args=(
        --duration "$duration"
        --output-dir "$set_dir"
        --set-name "$set_name"
        --mode "$mode"
        --run-id "$active_token"
        --osc "$osc"
        --manual-crackle "${crackle[$set_name]:-not-provided}"
        --log "$set_dir/raw/launcher.log"
    )
    for pid in "${current_live[@]}"; do capture_args+=(--live-pid "$pid"); done
    "$here/bench-run.sh" "${capture_args[@]}"
    [ "$osc" = off ] || python3 "$here/bench-osc.py" send /abl/bench/stop || true
    stop_owned_session || fail "could not end only the runner-owned $set_name session"

    # The launcher performs its own safe agent teardown. Give Max/helpers a
    # bounded grace, then refuse to stack another set on an unknown client.
    deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ]; do
        holders="$(ableton_prefix_unknown_holders)"
        [ -z "$holders" ] && break
        sleep 0.5
    done
    [ -z "${holders:-}" ] || fail "unknown clients still hold the prefix after $set_name: $(printf '%s' "$holders" | tr '\n' ' ')"
done

python3 "$here/bench-report.py" update-run --output "$output/run.json" --status complete
python3 "$here/bench-report.py" render --run-dir "$output"
finalized=1
printf 'complete: %s\n' "$output/report.md"
