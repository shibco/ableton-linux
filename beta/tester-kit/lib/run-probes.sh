#!/usr/bin/env bash

run_pe_probe() {
    local id="$1"
    local executable="$2"
    local output_name="$3"
    local seconds="$4"
    shift 4

    PROBE_STDOUT="$WORK_DIR/$id-wine-output.txt"
    PROBE_OUTPUT="$WORK_DIR/$output_name"
    rm -f "$PROBE_STDOUT" "$PROBE_OUTPUT"

    (
        cd "$WORK_DIR" || exit 1
        timeout --foreground "$seconds" "$WINE_BIN" "$WINDOWS_PROBES/$executable" "$@"
    ) >"$PROBE_STDOUT" 2>&1
    PROBE_RC=$?
}

show_probe_evidence() {
    local id="$1"
    append_redacted_file "$id Wine output" "$PROBE_STDOUT"
    append_redacted_file "$id probe output" "$PROBE_OUTPUT"
}

test_wineboot() {
    local output="$WORK_DIR/wineboot.txt"
    local version

    section "RUNTIME AND PREFIX"
    version="$("$WINE_BIN" --version 2>&1 || true)"
    printf 'Wine binary: %s\n' "$WINE_BIN"
    printf 'Wine version: %s\n' "$version"
    printf 'Wineserver: %s\n' "$WINESERVER_BIN"
    printf 'Prefix: %s\n' "$PREFIX"
    printf 'Wine SHA-256: %s\n' "$(sha256sum "$WINE_BIN" | awk '{print $1}')"

    timeout --foreground 120 "$WINEBOOT_BIN" -u >"$output" 2>&1
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        local attempt
        for ((attempt = 0; attempt < 50; attempt++)); do
            [[ -f "$PREFIX/system.reg" && -f "$PREFIX/user.reg" ]] && break
            sleep 0.2
        done
    fi
    append_redacted_file "wineboot output" "$output"
    if [[ $rc -eq 0 && -f "$PREFIX/system.reg" && -f "$PREFIX/user.reg" ]]; then
        record_result W00 PASS "Runtime starts and initialises the prefix" "$version"
    else
        record_result W00 FAIL "Runtime starts and initialises the prefix" "exit $rc"
    fi
}

test_audio_readiness() {
    local service_state=""
    local pulse_output="$WORK_DIR/pactl-info.txt"

    section "HOST READINESS CHECKS"
    if have systemctl; then
        service_state="$(systemctl --user is-active wireplumber.service 2>/dev/null || true)"
    fi
    if [[ "$service_state" == active ]]; then
        record_result H01 PASS "WirePlumber is active" "audio enumeration should have a session manager"
    else
        record_result H01 WARN "WirePlumber is not confirmed active" "state: ${service_state:-unknown}"
    fi

    if have pactl; then
        pactl info >"$pulse_output" 2>&1
        local rc=$?
        if [[ $rc -eq 0 ]] && ! grep -qi 'auto_null' "$pulse_output"; then
            record_result H02 PASS "PipeWire-Pulse responds" "real default graph reported"
        elif [[ $rc -eq 0 ]]; then
            record_result H02 WARN "PipeWire-Pulse responds with a dummy graph" "check WirePlumber and hardware"
        else
            record_result H02 WARN "PipeWire-Pulse did not respond" "pactl exit $rc"
        fi
        append_redacted_file "Host audio readiness" "$pulse_output"
    else
        record_result H02 SKIP "PipeWire-Pulse readiness" "pactl is not installed"
    fi
}

test_shared_session() {
    local iterations=30000
    [[ ${QUICK:-0} == 1 ]] && iterations=5000

    section "SHARED SESSION ALLOCATOR"
    printf 'Purpose: detect the stale shared-session mapping that caused NULL window procedures, menu failures and intermittent plug-in-window creation failures.\n'
    run_pe_probe T01 stresstest.exe stresstest.txt 180 "$iterations"
    if [[ $PROBE_RC -eq 0 ]] &&
       grep -Eq 'DONE: iters=[0-9]+ reg_fail=0 win_fail=0 veh=0' "$PROBE_OUTPUT"; then
        record_result T01 PASS "Shared-session class and window stress" "$iterations iterations"
    else
        record_result T01 FAIL "Shared-session class and window stress" "exit $PROBE_RC"
    fi
    show_probe_evidence T01
}

test_popup_menu() {
    section "POP-UP MENU CREATION"
    printf 'Purpose: detect the menu-window creation failure associated with stale window classes and swallowed access violations.\n'
    run_pe_probe T02 menutest.exe menutest.txt 30
    if [[ $PROBE_RC -eq 0 ]] &&
       grep -q 'WM_ENTERMENULOOP' "$PROBE_OUTPUT" &&
       grep -q 'WM_EXITMENULOOP' "$PROBE_OUTPUT" &&
       grep -Eq 'menu_windows_seen=[1-9][0-9]*' "$PROBE_OUTPUT" &&
       ! grep -q 'VEH:' "$PROBE_OUTPUT"; then
        record_result T02 PASS "Pop-up menu window creation" "menu entered and closed cleanly"
    else
        record_result T02 FAIL "Pop-up menu window creation" "exit $PROBE_RC or missing menu evidence"
    fi
    show_probe_evidence T02
}

test_resize_settle() {
    section "ABLETON MENU AND RESIZE SETTLE"
    printf 'Purpose: model Live\x27s client-plus-frame-plus-four-pixel calculation and detect the repeated vertical growth fault.\n'
    run_pe_probe T03 resizeprobe.exe resizeprobe.txt 30
    if [[ $PROBE_RC -eq 0 ]] && grep -q 'RESULT PASS' "$PROBE_OUTPUT"; then
        record_result T03 PASS "Live-style resize calculation settles" "all measured drift was zero"
    else
        record_result T03 FAIL "Live-style resize calculation settles" "exit $PROBE_RC or non-zero drift"
    fi
    show_probe_evidence T03

    run_pe_probe T03M metricprobe.exe metricprobe.txt 30
    if [[ $PROBE_RC -eq 0 ]] && ! grep -qi 'CreateWindowExW failed' "$PROBE_OUTPUT"; then
        record_result T03M INFO "Raw DPI and non-client metrics captured" "useful alongside T03"
    else
        record_result T03M WARN "Raw DPI and non-client metrics captured" "probe exit $PROBE_RC"
    fi
    show_probe_evidence T03M
}

test_opengl_child() {
    section "OPENGL CHILD-WINDOW CONTEXT"
    printf 'Purpose: detect the JUCE/baseview child-window GL failures, including missing sRGB-capable pixel formats.\n'
    run_pe_probe T04 glchild.exe glchild.txt 45
    if [[ $PROBE_RC -eq 0 ]] &&
       grep -Eq 'child wglChoosePixelFormatARB -> 1 count=[1-9][0-9]*' "$PROBE_OUTPUT" &&
       grep -Eq 'wglMakeCurrent -> 1' "$PROBE_OUTPUT" &&
       grep -Eq 'baseview-attribs choose -> ok=1 count=[1-9][0-9]*' "$PROBE_OUTPUT" &&
       ! grep -q 'FATAL:' "$PROBE_OUTPUT"; then
        record_result T04 PASS "OpenGL child context and baseview pixel format" "context and sRGB-capable format available"
    else
        record_result T04 FAIL "OpenGL child context and baseview pixel format" "exit $PROBE_RC or missing GL capability"
    fi
    show_probe_evidence T04
}

test_plugin_windows() {
    local observation

    section "PLUGIN WINDOW, TITLE BAR AND LAYERED SHADOW"
    printf '%s\n' 'A small fake Live window will appear with two fake plug-in editors and translucent shadow samples.' 'Look for one usable title bar per editor, no doubled or oversized Win32 title bar, and no opaque black shadow rectangle.' 'The window closes itself after about ten seconds.'
    run_pe_probe T05 pluginwindowprobe.exe pluginwindowprobe.txt 30
    if [[ $PROBE_RC -ne 0 ]]; then
        record_result T05 FAIL "Plug-in editor decorations and layered shadows" "probe exit $PROBE_RC"
    else
        observation="$(ask_result 'Did the plug-in windows have single usable title bars and shadows without black boxes?')"
        record_result T05 "$observation" "Plug-in editor decorations and layered shadows" "visual observation"
    fi
    show_probe_evidence T05
}

test_file_portal() {
    local observation

    section "FILE DIALOGUE PORTAL"
    if [[ ${NON_INTERACTIVE:-0} == 1 || ! -t 0 ]]; then
        record_result T06 SKIP "64-bit GetOpenFileName portal route" "requires a person to identify and cancel the dialogue"
        return
    fi

    printf '%s\n' 'A file-open dialogue will appear. Confirm that it is your normal desktop portal dialogue, then press Cancel.' 'Do not choose a private project. The probe records only whether a file was chosen, never its path.'

    PROBE_STDOUT="$WORK_DIR/T06-wine-output.txt"
    PROBE_OUTPUT="$WORK_DIR/portalprobe.txt"
    rm -f "$PROBE_STDOUT" "$PROBE_OUTPUT"
    (
        cd "$WORK_DIR" || exit 1
        WINE_FORCE_PORTAL=1 WINEDEBUG=+commdlg timeout --foreground 90 "$WINE_BIN" "$WINDOWS_PROBES/portalprobe.exe"
    ) >"$PROBE_STDOUT" 2>&1
    PROBE_RC=$?

    if [[ $PROBE_RC -ne 0 ]] || grep -q 'extended_error=[1-9]' "$PROBE_OUTPUT" 2>/dev/null; then
        record_result T06 FAIL "64-bit GetOpenFileName portal route" "exit $PROBE_RC or common-dialogue error"
    else
        observation="$(ask_result 'Was it the native desktop portal dialogue, and did Cancel return promptly?')"
        record_result T06 "$observation" "64-bit GetOpenFileName portal route" "forced portal policy"
    fi
    show_probe_evidence T06
}

wait_for_text() {
    local file="$1"
    local text="$2"
    local attempts="${3:-30}"
    local i

    for ((i = 0; i < attempts; i++)); do
        if grep -q "$text" "$file" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

forget_background_pid() {
    local forgotten="$1" pid
    local -a kept=()

    for pid in "${BACKGROUND_PIDS[@]}"; do
        [[ $pid == "$forgotten" ]] || kept+=("$pid")
    done
    BACKGROUND_PIDS=("${kept[@]}")
}

stop_background_pid() {
    local pid="${1:-}"

    [[ -n $pid ]] || return
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    forget_background_pid "$pid"
}

stop_background_pids() {
    local pid

    for pid in "$@"; do
        stop_background_pid "$pid"
    done
}

test_midi_hotplug() {
    local fake_bin="$WORK_DIR/fakectl"
    local build_log="$WORK_DIR/fakectl-build.txt"
    local fake1_log="$WORK_DIR/fakectl-before.txt"
    local fake2_log="$WORK_DIR/fakectl-after.txt"
    local midi_log="$WORK_DIR/midihot.txt"
    local fake1_pid fake2_pid midi_pid before after

    section "VIRTUAL MIDI HOTPLUG"
    printf 'Purpose: create a temporary ALSA sequencer controller, remove it, recreate it at a new client number and check that the same WinMM input resumes.\n'

    if ! have cc || [[ ! -e /dev/snd/seq ]]; then
        record_result T07 SKIP "MIDI reconnect after controller replug" "C compiler or /dev/snd/seq is unavailable"
        return
    fi

    if ! cc -O2 -Wall -o "$fake_bin" "$NATIVE_SOURCES/fakectl.c" -lasound \
            >"$build_log" 2>&1; then
        record_result T07 SKIP "MIDI reconnect after controller replug" "ALSA development headers or library unavailable"
        append_redacted_file "fakectl build output" "$build_log"
        return
    fi

    "$fake_bin" >"$fake1_log" 2>&1 &
    fake1_pid=$!
    BACKGROUND_PIDS+=("$fake1_pid")
    if ! wait_for_text "$fake1_log" 'READY client='; then
        record_result T07 SKIP "MIDI reconnect after controller replug" "virtual controller could not start"
        kill "$fake1_pid" 2>/dev/null || true
        wait "$fake1_pid" 2>/dev/null || true
        forget_background_pid "$fake1_pid"
        append_redacted_file "fakectl output" "$fake1_log"
        return
    fi

    (
        cd "$WORK_DIR" || exit 1
        timeout --foreground 14 "$WINE_BIN" "$WINDOWS_PROBES/midihot.exe" FakeCtl
    ) >"$midi_log" 2>&1 &
    midi_pid=$!
    BACKGROUND_PIDS+=("$midi_pid")

    sleep 3
    before="$(grep -c 'MIM_DATA' "$midi_log" 2>/dev/null || true)"
    kill "$fake1_pid" 2>/dev/null || true
    wait "$fake1_pid" 2>/dev/null || true
    forget_background_pid "$fake1_pid"
    sleep 2

    "$fake_bin" >"$fake2_log" 2>&1 &
    fake2_pid=$!
    BACKGROUND_PIDS+=("$fake2_pid")
    wait_for_text "$fake2_log" 'READY client=' || true
    sleep 4
    after="$(grep -c 'MIM_DATA' "$midi_log" 2>/dev/null || true)"

    kill "$fake2_pid" 2>/dev/null || true
    wait "$fake2_pid" 2>/dev/null || true
    forget_background_pid "$fake2_pid"
    wait "$midi_pid" 2>/dev/null || true
    forget_background_pid "$midi_pid"

    if (( before >= 2 && after >= before + 2 )); then
        record_result T07 PASS "MIDI reconnect after controller replug" "events before=$before after=$after"
    elif (( before < 2 )); then
        record_result T07 SKIP "MIDI reconnect after controller replug" "initial virtual MIDI stream was not visible"
    else
        record_result T07 FAIL "MIDI reconnect after controller replug" "events stopped after replug: before=$before after=$after"
    fi
    append_redacted_file "Virtual MIDI listener" "$midi_log"
    append_redacted_file "Virtual controller before replug" "$fake1_log"
    append_redacted_file "Virtual controller after replug" "$fake2_log"
}

test_midi_dynamic_hotplug() {
    local fake_bin="$WORK_DIR/fakectl-dynamic"
    local build_log="$WORK_DIR/fakectl-dynamic-build.txt"
    local watcher_log="$WORK_DIR/midiwatch-dynamic.txt"
    local first_log="$WORK_DIR/fakectl-dynamic-first.txt"
    local second_log="$WORK_DIR/fakectl-dynamic-second.txt"
    local blocker_log="$WORK_DIR/fakectl-dynamic-blocker.txt"
    local name="BetaHotplug$$"
    local watcher_pid first_pid second_pid blocker_pid watcher_rc
    local first_id second_id blocker_id attempt
    local -a blocker_pids=()

    section "DYNAMIC VIRTUAL MIDI HOTPLUG"
    printf 'Purpose: initialise WinMM before a MIDI device exists, open its new input and output, remove it, then restore both open handles under a different ALSA client number.\n'

    if [[ ! -f "$WINDOWS_PROBES/midiwatch.exe" ]]; then
        record_result T07D SKIP "Dynamic MIDI add, remove and replug" "midiwatch.exe is not included in this tester kit"
        return
    fi
    if ! have cc || [[ ! -e /dev/snd/seq ]]; then
        record_result T07D SKIP "Dynamic MIDI add, remove and replug" "C compiler or /dev/snd/seq is unavailable"
        return
    fi
    if ! cc -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -o "$fake_bin" \
            "$NATIVE_SOURCES/fakectl.c" -lasound >"$build_log" 2>&1; then
        record_result T07D SKIP "Dynamic MIDI add, remove and replug" "ALSA development headers or library unavailable"
        append_redacted_file "dynamic fakectl build output" "$build_log"
        return
    fi

    (
        cd "$WORK_DIR" || exit 1
        timeout --foreground 90 "$WINE_BIN" "$WINDOWS_PROBES/midiwatch.exe" \
            --assert-cycle "$name" 1 1 10000 1
    ) >"$watcher_log" 2>&1 &
    watcher_pid=$!
    BACKGROUND_PIDS+=("$watcher_pid")
    if ! wait_for_text "$watcher_log" 'ASSERT BASELINE' 100; then
        record_result T07D FAIL "Dynamic MIDI add, remove and replug" "WinMM baseline timed out"
        stop_background_pid "$watcher_pid"
        return
    fi

    "$fake_bin" --name "$name" --port-name "$name" --duplex --interval-ms 100 \
        >"$first_log" 2>&1 &
    first_pid=$!
    BACKGROUND_PIDS+=("$first_pid")
    if ! wait_for_text "$watcher_log" 'ASSERT READY_FOR_REMOVE cycle=1' 100; then
        record_result T07D FAIL "Dynamic MIDI add, remove and replug" "new device did not publish and open"
        stop_background_pids "$first_pid" "$watcher_pid"
        return
    fi
    first_id="$(sed -n 's/^READY client=\([0-9][0-9]*\).*/\1/p' "$first_log" | head -n 1)"
    if [[ -z $first_id ]]; then
        record_result T07D FAIL "Dynamic MIDI add, remove and replug" "initial ALSA client id was not reported"
        stop_background_pids "$first_pid" "$watcher_pid"
        return
    fi
    stop_background_pid "$first_pid"
    if ! wait_for_text "$watcher_log" 'ASSERT READY_FOR_READD cycle=1' 100; then
        record_result T07D FAIL "Dynamic MIDI add, remove and replug" "device removal did not shrink the WinMM list"
        stop_background_pid "$watcher_pid"
        return
    fi

    blocker_id=
    for ((attempt = 1; attempt <= 64; attempt++)); do
        blocker_log="$WORK_DIR/fakectl-dynamic-blocker-$attempt.txt"
        "$fake_bin" --name "${name}Block${attempt}" --ports 0 >"$blocker_log" 2>&1 &
        blocker_pid=$!
        blocker_pids+=("$blocker_pid")
        BACKGROUND_PIDS+=("$blocker_pid")
        if ! wait_for_text "$blocker_log" 'READY client=' 100; then
            record_result T07D FAIL "Dynamic MIDI add, remove and replug" "ALSA client-id blocker did not start"
            stop_background_pids "${blocker_pids[@]}" "$watcher_pid"
            return
        fi
        blocker_id="$(sed -n 's/^READY client=\([0-9][0-9]*\).*/\1/p' "$blocker_log" | head -n 1)"
        [[ $blocker_id == "$first_id" ]] && break
    done
    if [[ $blocker_id != "$first_id" ]]; then
        record_result T07D FAIL "Dynamic MIDI add, remove and replug" "could not reserve old ALSA client id $first_id"
        stop_background_pids "${blocker_pids[@]}" "$watcher_pid"
        return
    fi
    "$fake_bin" --name "$name" --port-name "$name" --duplex --interval-ms 100 \
        >"$second_log" 2>&1 &
    second_pid=$!
    BACKGROUND_PIDS+=("$second_pid")

    wait "$watcher_pid" 2>/dev/null
    watcher_rc=$?
    forget_background_pid "$watcher_pid"
    second_id="$(sed -n 's/^READY client=\([0-9][0-9]*\).*/\1/p' "$second_log" | head -n 1)"
    stop_background_pids "$second_pid" "${blocker_pids[@]}"

    if [[ $watcher_rc -eq 0 && -n $first_id && -n $second_id &&
          $first_id != "$second_id" ]] &&
       grep -q 'ASSERT PASS mode=cycle cycles=1' "$watcher_log" &&
       grep -q '^RX port=' "$second_log"; then
        record_result T07D PASS "Dynamic MIDI add, remove and replug" "WinMM input/output recovered across ALSA clients $first_id and $second_id"
    else
        record_result T07D FAIL "Dynamic MIDI add, remove and replug" "exit $watcher_rc, ALSA clients ${first_id:-unknown}/${second_id:-unknown}, or missing I/O evidence"
    fi
    append_redacted_file "Dynamic WinMM watcher" "$watcher_log"
    append_redacted_file "Dynamic controller before replug" "$first_log"
    append_redacted_file "Dynamic controller after replug" "$second_log"
}

test_prefix_configuration() {
    local registry_log="$WORK_DIR/prefix-configuration.txt"
    local audio_registry="$WORK_DIR/mmdevices-audio.txt"

    section "PREFIX CONFIGURATION SNAPSHOT"
    {
        printf '[Wine DPI]\n'
        timeout --foreground 30 "$WINE_BIN" reg query 'HKCU\Control Panel\Desktop' /v LogPixels 2>&1 || true
        printf '\n[Live IFEO DPI]\n'
        timeout --foreground 30 "$WINE_BIN" reg query 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 12 Suite.exe' /v dpiAwareness 2>&1 || true
        printf '\n[File dialogue portal policy]\n'
        timeout --foreground 30 "$WINE_BIN" reg query 'HKCU\Software\Wine\X11 Driver' /v FileDialogPortal 2>&1 || true
        printf '\n[Pointer settings]\n'
        for v in SmoothScrolling TouchpadInertia PinchZoom MiddleDrag MiddleDragThrow WheelWhileButtonHeld InertiaCurve InertiaRate WarpEmulation; do
            timeout --foreground 30 "$WINE_BIN" reg query 'HKCU\Software\Wine\X11 Driver' /v "$v" 2>&1 || true
        done
        printf '\n[Wine drivers]\n'
        timeout --foreground 30 "$WINE_BIN" reg query 'HKCU\Software\Wine\Drivers' 2>&1 || true
    } >"$registry_log"
    append_redacted_file "Safe prefix policy values" "$registry_log"
    record_result C01 INFO "DPI, portal and driver policy captured" "values require comparison with the assigned display profile"

    timeout --foreground 45 "$WINE_BIN" reg query 'HKLM\Software\Microsoft\Windows\CurrentVersion\MMDevices\Audio' /s >"$audio_registry" 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        record_result C02 INFO "Audio endpoint FriendlyName guard" "no MMDevices audio tree was available yet"
    elif grep -Eqi '(Speakers|Microphone|Headphones)[[:space:]]*\([^\r\n]*(Speakers|Microphone|Headphones)[[:space:]]*\(' "$audio_registry"; then
        record_result C02 FAIL "Audio endpoint FriendlyName guard" "nested endpoint names detected"
    else
        record_result C02 PASS "Audio endpoint FriendlyName guard" "no nested endpoint names detected"
    fi
    subsection "MMDevices audio FriendlyName shape"
    if [[ -s "$audio_registry" ]]; then
        printf '(FriendlyName values inspected locally and omitted from the report)\n'
    else
        printf '(no output)\n'
    fi
}

run_passive_probe() {
    local id="$1"
    local executable="$2"
    local output="$3"
    local label="$4"

    run_pe_probe "$id" "$executable" "$output" 45
    if [[ $PROBE_RC -eq 0 && -s "$PROBE_OUTPUT" ]]; then
        record_result "$id" INFO "$label" "captured"
    else
        record_result "$id" WARN "$label" "exit $PROBE_RC or empty output"
    fi
    show_probe_evidence "$id"
}

run_live_probes() {
    local result

    section "OPTIONAL LIVE SESSION PROBES"
    if ! pgrep -f 'Ableton Live 12.*[.]exe' >/dev/null 2>&1; then
        record_result L00 SKIP "Passive Ableton Live inspection" "Live 12 is not running"
        return
    fi

    printf '%s\n' 'These probes do not inject input or change Live.' 'Before continuing, make the main window visible, open Learn View, and open one representative Direct2D or JUCE plug-in editor.' 'Use a disposable or already-saved set because this is beta software.'
    if [[ ${NON_INTERACTIVE:-0} != 1 && -t 0 ]]; then
        printf 'Press Enter when those windows are ready: ' >/dev/tty
        IFS= read -r _ </dev/tty || true
    fi

    run_passive_probe L01 dpispy.exe dpispy.txt "Window DPI and geometry"
    run_passive_probe L02 hwndspy.exe hwndspy.txt "Live, WebView and plug-in HWND tree"
    run_passive_probe L03 dcompspy.exe dcompspy.txt "DirectComposition target state"
    run_passive_probe L04 menumeasure.exe menumeasure.txt "Live main-menu geometry"
    run_passive_probe L05 swamprobe.exe swamprobe.txt "Live focus, hit-test and window state"

    result="$(ask_result 'Is the main Live window stable at idle, without growth, border strobing or high idle CPU?')"
    record_result L10 "$result" "Live main-window settle" "manual observation"
    result="$(ask_result 'Do Live menus, keyboard shortcuts and the open plug-in editor accept input normally?')"
    record_result L11 "$result" "Live and Direct2D plug-in input" "manual observation"
    result="$(ask_result 'Does Learn View render stable, correctly sized content without a stale or mangled band?')"
    record_result L12 "$result" "Learn View rendering" "manual observation; this is the known open fault"
}

run_advanced_input_trace() {
    local confirmation
    local trace_path=/tmp/mousespy.txt
    local captured="$WORK_DIR/mousespy.txt"
    local previous="$WORK_DIR/mousespy.pre-existing.txt"
    local stdout="$WORK_DIR/advanced-input-wine.txt"

    section "ADVANCED LIVE INPUT TRACE"
    if [[ ${NON_INTERACTIVE:-0} == 1 || ! -t 0 ]]; then
        record_result A01 SKIP "Global Wine mouse and JUCE input trace" "requires explicit interactive confirmation"
        return
    fi
    if ! pgrep -f 'Ableton Live 12.*[.]exe' >/dev/null 2>&1; then
        record_result A01 SKIP "Global Wine mouse and JUCE input trace" "Live 12 is not running"
        return
    fi

    printf '%s\n' 'This diagnostic installs a Wine-wide mouse hook for 15 seconds and may subclass JUCE windows.' 'The DLL can remain pinned inside Live until Live exits. Save the set first, interact with the affected editor and menus during the trace, then quit Live afterwards.' 'Type TRACE to continue, or press Enter to skip.'
    printf 'Confirmation: ' >/dev/tty
    IFS= read -r confirmation </dev/tty || confirmation=
    if [[ "$confirmation" != TRACE ]]; then
        record_result A01 SKIP "Global Wine mouse and JUCE input trace" "tester declined"
        return
    fi

    if [[ -e "$trace_path" ]]; then
        mv -- "$trace_path" "$previous"
        MOUSESPY_BACKUP="$previous"
    fi

    printf 'Trace running for 15 seconds. Use the affected plug-in editor and Live menus now.\n'
    (
        cd "$ADVANCED_WINDOWS" || exit 1
        timeout --foreground 30 "$WINE_BIN" "$ADVANCED_WINDOWS/spyhost.exe" 15
    ) >"$stdout" 2>&1
    local rc=$?

    if [[ -s "$trace_path" ]]; then
        mv -- "$trace_path" "$captured"
    fi
    if [[ -n ${MOUSESPY_BACKUP:-} && -f ${MOUSESPY_BACKUP:-} ]]; then
        mv -- "$MOUSESPY_BACKUP" "$trace_path"
        MOUSESPY_BACKUP=
    fi

    if [[ $rc -eq 0 && -s "$captured" ]]; then
        record_result A01 INFO "Global Wine mouse and JUCE input trace" "captured; quit Live after reviewing"
    else
        record_result A01 WARN "Global Wine mouse and JUCE input trace" "exit $rc or empty trace"
    fi
    append_redacted_file "Advanced input trace Wine output" "$stdout"
    append_redacted_file "Advanced input trace" "$captured"
}

run_probe_suite() {
    test_wineboot
    test_audio_readiness
    test_shared_session
    test_popup_menu
    test_resize_settle
    test_opengl_child
    test_plugin_windows
    test_file_portal
    test_midi_hotplug
    test_midi_dynamic_hotplug
    test_prefix_configuration
    if [[ ${LIVE_PROBES:-0} == 1 ]]; then
        run_live_probes
    fi
    if [[ ${ADVANCED_INPUT:-0} == 1 ]]; then
        run_advanced_input_trace
    fi
}
