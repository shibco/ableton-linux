#!/usr/bin/env bash
# Exercise Wine MIDI device addition, removal, and reconnection with virtual ALSA ports.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
wine_bin="${WINE_BIN:-wine}"
midiwatch_exe="${MIDIWATCH_EXE:-$here/midiwatch.exe}"
stage_timeout_ms="${HOTPLUG_TIMEOUT_MS:-10000}"
cycles="${HOTPLUG_CYCLES:-3}"
busy_block_ms="${HOTPLUG_BLOCK_MS:-3000}"
# Patch 0105 retries a pending MIDI link every 250 ms for about 10 seconds,
# then every 2 seconds while the port stays online. A reserved link gets the
# whole 10-second period after its reservation ends. The long case reserves
# the link for 2 seconds past that period to reach the slow retries.
reconnect_retry_ms=10000
long_block_ms=$((reconnect_retry_ms + 2000))
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
        # The probe writes CRLF. Remove carriage returns so each end anchor
        # matches the visible line.
        if [ -r "$file" ] && grep -Eq "$pattern" < <(tr -d '\r' <"$file" 2>/dev/null); then
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

stop_extra_reserve_blockers() {
    local pid

    for pid in "${reserve_blocker_pids[@]}"; do
        if [[ $pid != "$reserved_blocker_pid" ]]; then
            stop_process "$pid"
        fi
    done
}

run_monitor_leak_case() {
    local dir="$work_dir/monitor-leak" name="AH${$}Leak" outer_seconds
    local first_log="$dir/watcher-1.txt" second_log="$dir/watcher-2.txt"
    local fake_log="$dir/fakectl.txt" first_pid second_pid

    mkdir -p -- "$dir"
    outer_seconds=$((5 * stage_timeout_ms / 1000 + 10))

    # The first Wine process creates its private MIDI monitor, then opens a
    # MIDI input and output on the test controller so its data ports exist.
    start_watcher "$first_log" "$outer_seconds" --assert-cycle "$name" 1 1 \
        "$stage_timeout_ms" 1
    first_pid=$STARTED_PID
    wait_for_text "$first_log" '^ASSERT BASELINE ' "$stage_timeout_ms" ||
        { fail "monitor-leak: first watcher reached the WinMM initialisation timeout"; return 1; }
    start_fake "$fake_log" "$name" --duplex --ports 1 --interval-ms 50
    wait_for_text "$first_log" '^ASSERT READY_FOR_REMOVE cycle=1$' "$stage_timeout_ms" ||
        {
            stop_process "$first_pid"
            fail "monitor-leak: first watcher reached the open-handle timeout"
            return 1
        }

    # The second process confirms that Wine excludes every private port of
    # the first process from its device list.
    start_watcher "$second_log" "$outer_seconds"
    second_pid=$STARTED_PID
    wait_for_text "$second_log" '^watching without open' "$stage_timeout_ms" ||
        {
            stop_process "$first_pid"
            fail "monitor-leak: second watcher reached the WinMM initialisation timeout"
            return 1
        }

    if grep -q 'WINE MIDI topology\|WINE midi driver\|WINE ALSA' "$first_log" "$second_log"; then
        stop_process "$first_pid"
        stop_process "$second_pid"
        fail "monitor-leak: a Wine MIDI list contains another Wine process's port"
        return 1
    fi

    stop_process "$first_pid"
    stop_process "$second_pid"
    printf 'PASS: Wine processes do not list each other\x27s MIDI ports\n'
}

run_cycle_case() {
    local label="$1" name_suffix="$2" test_cycles="$3" block_ms="$4"
    local debug="${5:-${WINEDEBUG:--all}}"
    local name="AH${$}${name_suffix}" dir="$work_dir/$label"
    local watcher_log="$dir/midiwatch.txt" target_log target_pid watcher_pid
    local previous_id current_id cycle watcher_rc outer_seconds
    local retained_blocker_pid=""
    local test_timeout_ms=$stage_timeout_ms
    local cycle_word=cycles
    local -a replacement_args

    mkdir -p -- "$dir"
    if (( block_ms && test_timeout_ms < block_ms + reconnect_retry_ms )); then
        test_timeout_ms=$((block_ms + reconnect_retry_ms))
    fi
    outer_seconds=$(((3 + 5 * test_cycles) * (test_timeout_ms / 1000 + 1) + 10))
    WINEDEBUG="$debug" start_watcher "$watcher_log" "$outer_seconds" --assert-cycle "$name" 1 1 \
        "$test_timeout_ms" "$test_cycles"
    watcher_pid=$STARTED_PID
    wait_for_text "$watcher_log" '^ASSERT BASELINE ' "$test_timeout_ms" ||
        { fail "$label reached the WinMM baseline timeout"; return 1; }

    target_log="$dir/target-0.txt"
    start_fake "$target_log" "$name" --duplex --ports 1 --interval-ms 50
    target_pid=$STARTED_PID
    wait_for_text "$target_log" '^READY client=' "$test_timeout_ms" ||
        { fail "$label reached the controller startup timeout"; return 1; }
    previous_id="$(read_client_id "$target_log")"

    for ((cycle = 1; cycle <= test_cycles; cycle++)); do
        wait_for_text "$watcher_log" "^ASSERT READY_FOR_REMOVE cycle=$cycle$" \
            "$test_timeout_ms" ||
            { fail "$label cycle $cycle reached the removal readiness timeout"; return 1; }
        stop_process "$target_pid"
        wait_for_text "$watcher_log" "^ASSERT READY_FOR_READD cycle=$cycle$" \
            "$test_timeout_ms" ||
            { fail "$label cycle $cycle reached the removal publication timeout"; return 1; }
        reserve_client_id "$previous_id" "$dir" "$cycle" ||
            { fail "$label exhausted ALSA client ID reservations for $previous_id"; return 1; }

        if [[ -n $retained_blocker_pid ]]; then
            stop_process "$retained_blocker_pid"
        fi
        stop_extra_reserve_blockers
        retained_blocker_pid=$reserved_blocker_pid

        target_log="$dir/target-$cycle.txt"
        replacement_args=(--duplex --ports 1 --interval-ms 50)
        if (( block_ms && cycle == 1 )); then
            replacement_args+=(--block-connections-ms "$block_ms")
        fi
        start_fake "$target_log" "$name" "${replacement_args[@]}"
        target_pid=$STARTED_PID
        wait_for_text "$target_log" '^READY client=' "$test_timeout_ms" ||
            { fail "$label cycle $cycle reached the replacement startup timeout"; return 1; }
        current_id="$(read_client_id "$target_log")"
        if [[ -z $current_id || $current_id == "$previous_id" ]]; then
            fail "$label cycle $cycle returned an empty or reused ALSA client ID ($previous_id)"
            return 1
        fi
        if (( block_ms && cycle == 1 )); then
            wait_for_text "$target_log" '^UNBLOCK elapsed_ms=' "$test_timeout_ms" ||
                { fail "$label timed out before link release"; return 1; }
        fi
        wait_for_text "$watcher_log" "^ASSERT CYCLE_PASS cycle=$cycle " \
            "$test_timeout_ms" ||
            { fail "$label cycle $cycle reached the open-handle recovery timeout"; return 1; }
        wait_for_text "$target_log" '^RX port=' 2000 ||
            { fail "$label cycle $cycle reached the WinMM output timeout"; return 1; }
        previous_id=$current_id
    done

    wait_process "$watcher_pid"
    watcher_rc=$?
    if [[ $watcher_rc -ne 0 ]] ||
       ! grep -q "^ASSERT PASS mode=cycle cycles=$test_cycles " "$watcher_log"; then
        fail "$label assertion failed (exit $watcher_rc)"
        return 1
    fi
    stop_process "$target_pid"
    if [[ -n $retained_blocker_pid ]]; then
        stop_process "$retained_blocker_pid"
    fi
    if (( test_cycles == 1 )); then cycle_word=cycle; fi
    printf 'PASS: %s with changed ALSA client IDs (%s %s)\n' \
        "$label" "$test_cycles" "$cycle_word"
}

if [[ ! $stage_timeout_ms =~ ^[0-9]+$ || $stage_timeout_ms -lt 100 ]]; then
    fail "HOTPLUG_TIMEOUT_MS must be an integer of at least 100"; exit 2
fi
if [[ ! $cycles =~ ^[0-9]+$ || $cycles -lt 1 || $cycles -gt 100 ]]; then
    fail "HOTPLUG_CYCLES must be between 1 and 100"; exit 2
fi
if [[ ! $busy_block_ms =~ ^[0-9]+$ || $busy_block_ms -lt 100 || $busy_block_ms -gt 60000 ]]; then
    fail "HOTPLUG_BLOCK_MS must be between 100 and 60000"; exit 2
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
run_cycle_case busy-link-retry Busy 1 "$busy_block_ms" || exit 1
# Wine's error log stays on here: the monitor thread reports the exhausted
# fast retries, and that report once faulted the process.
run_cycle_case long-reservation Long 1 "$long_block_ms" err+midi || exit 1
run_cycle_case rapid-cycle Cycle "$cycles" 0 || exit 1
run_monitor_leak_case || exit 1

printf 'PASS: all MIDI hotplug cases completed\n'
