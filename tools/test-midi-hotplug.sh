#!/usr/bin/env bash
# Exercise dynamic Wine MIDI add/remove/replug behavior with virtual ALSA ports.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
wine_bin="${WINE_BIN:-wine}"
midiwatch_exe="${MIDIWATCH_EXE:-$here/midiwatch.exe}"
stage_timeout_ms="${HOTPLUG_TIMEOUT_MS:-10000}"
cycles="${HOTPLUG_CYCLES:-3}"
created_work_dir=0
case_number=0
declare -a background_pids=()
declare -a reserve_blocker_pids=()
reserved_blocker_pid=

if [[ -n ${HOTPLUG_LOG_DIR:-} ]]; then
    work_dir="$HOTPLUG_LOG_DIR"
    mkdir -p -- "$work_dir"
else
    work_dir="$(mktemp -d /tmp/ableton-midi-hotplug.XXXXXX)"
    created_work_dir=1
fi

cleanup() {
    local status="$1" pid

    for pid in "${background_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${background_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    if [[ $status -eq 0 && $created_work_dir -eq 1 ]]; then
        case "$work_dir" in
            /tmp/ableton-midi-hotplug.*) rm -rf -- "$work_dir" ;;
        esac
    else
        printf 'Hotplug logs: %s\n' "$work_dir" >&2
    fi
}

finish() {
    local status=$?
    trap - EXIT INT TERM
    cleanup "$status"
    exit "$status"
}
trap finish EXIT INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

wait_for_text() {
    local file="$1" pattern="$2" timeout_ms="$3"
    local elapsed=0

    while (( elapsed < timeout_ms )); do
        if grep -Eq "$pattern" "$file" 2>/dev/null; then
            return 0
        fi
        sleep 0.02
        elapsed=$((elapsed + 20))
    done
    return 1
}

stop_process() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    forget_pid "$pid"
}

forget_pid() {
    local forgotten="$1" pid
    local -a kept=()

    for pid in "${background_pids[@]}"; do
        [[ $pid == "$forgotten" ]] || kept+=("$pid")
    done
    background_pids=("${kept[@]}")
}

wait_process() {
    local pid="$1" status

    wait "$pid"
    status=$?
    forget_pid "$pid"
    return "$status"
}

read_client_id() {
    sed -n 's/^READY client=\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1
}

start_fake() {
    local log="$1" name="$2"
    shift 2

    "$fake_bin" --name "$name" --port-name "$name" "$@" >"$log" 2>&1 &
    STARTED_PID=$!
    background_pids+=("$STARTED_PID")
}

start_watcher() {
    local log="$1" outer_seconds="$2"
    shift 2

    WINEDEBUG="${WINEDEBUG:--all}" timeout --foreground "$outer_seconds" \
        "$wine_bin" "$midiwatch_exe" "$@" >"$log" 2>&1 &
    STARTED_PID=$!
    background_pids+=("$STARTED_PID")
}

run_add_case() {
    local label="$1" added_inputs="$2" added_outputs="$3"
    shift 3
    local name="AH${$}A${case_number}" dir="$work_dir/$label"
    local watcher_log="$dir/midiwatch.txt" fake_log="$dir/fakectl.txt"
    local watcher_pid fake_pid watcher_rc outer_seconds

    case_number=$((case_number + 1))
    mkdir -p -- "$dir"
    outer_seconds=$((3 * stage_timeout_ms / 1000 + 10))
    start_watcher "$watcher_log" "$outer_seconds" --assert-add "$name" \
        "$added_inputs" "$added_outputs" "$stage_timeout_ms"
    watcher_pid=$STARTED_PID
    wait_for_text "$watcher_log" '^ASSERT BASELINE ' "$stage_timeout_ms" ||
        { fail "$label did not establish a WinMM baseline"; return 1; }

    start_fake "$fake_log" "$name" "$@" --interval-ms 100
    fake_pid=$STARTED_PID
    wait_for_text "$fake_log" '^READY client=' "$stage_timeout_ms" ||
        { fail "$label controller did not start"; return 1; }

    wait_process "$watcher_pid"
    watcher_rc=$?
    if [[ $watcher_rc -ne 0 ]] || ! grep -q '^ASSERT PASS mode=add ' "$watcher_log"; then
        fail "$label WinMM assertion failed (exit $watcher_rc)"
        return 1
    fi
    if (( added_outputs > 0 )) &&
       ! wait_for_text "$fake_log" '^RX port=' 2000; then
        fail "$label opened the WinMM output but the ALSA device received no data"
        return 1
    fi

    stop_process "$fake_pid"
    printf 'PASS: %s\n' "$label"
}

reserve_client_id() {
    local wanted="$1" dir="$2" cycle="$3"
    local attempt log blocker_id

    reserve_blocker_pids=()
    reserved_blocker_pid=

    for ((attempt = 1; attempt <= 64; attempt++)); do
        log="$dir/blocker-${cycle}-${attempt}.txt"
        start_fake "$log" "AH${$}Block${cycle}${attempt}" --ports 0
        reserve_blocker_pids+=("$STARTED_PID")
        wait_for_text "$log" '^READY client=' "$stage_timeout_ms" || return 1
        blocker_id="$(read_client_id "$log")"
        if [[ $blocker_id == "$wanted" ]]; then
            reserved_blocker_pid=$STARTED_PID
            return 0
        fi
    done
    return 1
}

run_cycle_case() {
    local name="AH${$}Cycle" dir="$work_dir/rapid-cycle"
    local watcher_log="$dir/midiwatch.txt" target_log target_pid watcher_pid
    local previous_id current_id cycle watcher_rc outer_seconds
    local retained_blocker_pid="" pid

    mkdir -p -- "$dir"
    outer_seconds=$(((3 + 5 * cycles) * (stage_timeout_ms / 1000 + 1) + 10))
    start_watcher "$watcher_log" "$outer_seconds" --assert-cycle "$name" 1 1 \
        "$stage_timeout_ms" "$cycles"
    watcher_pid=$STARTED_PID
    wait_for_text "$watcher_log" '^ASSERT BASELINE ' "$stage_timeout_ms" ||
        { fail "rapid-cycle did not establish a WinMM baseline"; return 1; }

    target_log="$dir/target-0.txt"
    start_fake "$target_log" "$name" --duplex --ports 1 --interval-ms 50
    target_pid=$STARTED_PID
    wait_for_text "$target_log" '^READY client=' "$stage_timeout_ms" ||
        { fail "rapid-cycle controller did not start"; return 1; }
    previous_id="$(read_client_id "$target_log")"

    for ((cycle = 1; cycle <= cycles; cycle++)); do
        wait_for_text "$watcher_log" "^ASSERT READY_FOR_REMOVE cycle=$cycle$" \
            "$stage_timeout_ms" ||
            { fail "cycle $cycle never became ready for removal"; return 1; }
        stop_process "$target_pid"
        wait_for_text "$watcher_log" "^ASSERT READY_FOR_READD cycle=$cycle$" \
            "$stage_timeout_ms" ||
            { fail "cycle $cycle removal was not published"; return 1; }
        reserve_client_id "$previous_id" "$dir" "$cycle" ||
            { fail "could not reserve old ALSA client id $previous_id"; return 1; }

        if [[ -n $retained_blocker_pid ]]; then
            stop_process "$retained_blocker_pid"
        fi
        for pid in "${reserve_blocker_pids[@]}"; do
            if [[ $pid != "$reserved_blocker_pid" ]]; then
                stop_process "$pid"
            fi
        done
        retained_blocker_pid=$reserved_blocker_pid

        target_log="$dir/target-$cycle.txt"
        start_fake "$target_log" "$name" --duplex --ports 1 --interval-ms 50
        target_pid=$STARTED_PID
        wait_for_text "$target_log" '^READY client=' "$stage_timeout_ms" ||
            { fail "cycle $cycle replacement did not start"; return 1; }
        current_id="$(read_client_id "$target_log")"
        if [[ -z $current_id || $current_id == "$previous_id" ]]; then
            fail "cycle $cycle did not change ALSA client id ($previous_id)"
            return 1
        fi
        wait_for_text "$watcher_log" "^ASSERT CYCLE_PASS cycle=$cycle " \
            "$stage_timeout_ms" ||
            { fail "cycle $cycle did not restore the open WinMM handles"; return 1; }
        wait_for_text "$target_log" '^RX port=' 2000 ||
            { fail "cycle $cycle replacement received no WinMM output"; return 1; }
        previous_id=$current_id
    done

    wait_process "$watcher_pid"
    watcher_rc=$?
    if [[ $watcher_rc -ne 0 ]] ||
       ! grep -q "^ASSERT PASS mode=cycle cycles=$cycles " "$watcher_log"; then
        fail "rapid-cycle assertion failed (exit $watcher_rc)"
        return 1
    fi
    stop_process "$target_pid"
    if [[ -n $retained_blocker_pid ]]; then
        stop_process "$retained_blocker_pid"
    fi
    printf 'PASS: rapid replug with changed ALSA client ids (%s cycles)\n' "$cycles"
}

if [[ ! $stage_timeout_ms =~ ^[0-9]+$ || $stage_timeout_ms -lt 100 ]]; then
    fail "HOTPLUG_TIMEOUT_MS must be an integer of at least 100"; exit 2
fi
if [[ ! $cycles =~ ^[0-9]+$ || $cycles -lt 1 || $cycles -gt 100 ]]; then
    fail "HOTPLUG_CYCLES must be between 1 and 100"; exit 2
fi
if [[ ! -e /dev/snd/seq ]]; then
    printf 'SKIP: /dev/snd/seq is unavailable\n'
    exit 77
fi
if [[ ! -f $midiwatch_exe ]]; then
    fail "missing $midiwatch_exe; build it with tools/build_midiwatch.sh"
    exit 77
fi
if ! command -v "$wine_bin" >/dev/null 2>&1 && [[ ! -x $wine_bin ]]; then
    fail "Wine executable is unavailable: $wine_bin"
    exit 77
fi
if ! command -v cc >/dev/null 2>&1; then
    fail "a C compiler is required"
    exit 77
fi

fake_bin="$work_dir/fakectl"
if ! cc -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror \
        -o "$fake_bin" "$here/fakectl.c" -lasound >"$work_dir/fakectl-build.txt" 2>&1; then
    fail "fakectl build failed; see $work_dir/fakectl-build.txt"
    exit 77
fi

run_add_case duplex-add 1 1 --duplex --ports 1 || exit 1
run_add_case input-only-add 1 0 --input-only --ports 1 || exit 1
run_add_case output-only-add 0 1 --output-only --ports 1 || exit 1
run_add_case duplicate-multiport-add 2 2 --duplex --ports 2 --duplicate-names || exit 1
run_cycle_case || exit 1

printf 'PASS: all MIDI hotplug cases completed\n'
