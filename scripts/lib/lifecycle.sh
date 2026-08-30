#!/usr/bin/env bash
# Prefix- and runtime-scoped Wine lifecycle inspection.  No process is selected
# by a global image-name match: both /proc/PID/exe and WINEPREFIX must match.

# Definitions only: callers resolve the configuration themselves, because the
# command line reaches some of them after this file is sourced.
_ableton_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ableton_config_init >/dev/null 2>&1; then
    . "$_ableton_lib_dir/config.sh"
fi

ableton_pid_has_env()
{
    local pid="$1" expected="$2"
    [ -r "/proc/$pid/environ" ] || return 1
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -Fx -- "$expected" >/dev/null 2>&1
}

ableton_pid_uses_runtime()
{
    local pid="$1" root="${2:-$ABLETON_WINE_ROOT}" exe
    exe="$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)"
    root="$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")"
    case "$root" in
        /usr|/usr/local)
            case "$exe" in
                "$root"/bin/wine*|"$root"/bin/wineserver|"$root"/lib*/wine/*) return 0 ;;
                *) return 1 ;;
            esac ;;
        *) case "$exe" in "$root"/*) return 0 ;; *) return 1 ;; esac ;;
    esac
}

# The prefix and runtime default to the configured pair, but every walker below
# takes them, so a caller working on a prefix that is not the configured one -
# setup-prefix.sh, inside its staging window - inspects the prefix it named
# rather than the user's.
ableton_pid_uses_prefix()
{
    ableton_pid_has_env "$1" "WINEPREFIX=${2:-$ABLETON_WINEPREFIX}"
}

# The prefix match runs first, and as one grep over every environ at once, because
# the runtime match costs a readlink fork per process: on a host with 850 running
# processes the per-process form takes three seconds a pass, and the callers below
# run it behind a sleep that assumes the check is free.  -z splits environ on its
# NUL boundaries and -x anchors the match, so a prefix whose path is a prefix of
# another prefix's path does not match it.
ableton_prefix_pids()
{
    local root="${1:-$ABLETON_WINE_ROOT}" prefix="${2:-$ABLETON_WINEPREFIX}" proc pid
    while IFS= read -r -d '' proc; do
        pid="${proc#/proc/}"
        pid="${pid%/environ}"
        ableton_pid_uses_runtime "$pid" "$root" || continue
        printf '%s\n' "$pid"
    done < <(grep -rzlFx --null "WINEPREFIX=$prefix" /proc/[0-9]*/environ 2>/dev/null)
    return 0
}

# Prefix promotion is different from ordinary session management: moving the
# directory is unsafe even when the process using it came from stock Wine or a
# runtime generation that has just been replaced. Match the exact WINEPREFIX
# environment value first, then accept only resolved Wine executable names.
# The normal lifecycle walkers remain runtime-scoped so stop/report operations
# never act on a foreign Wine installation.
ableton_prefix_wine_processes_any_runtime()
{
    local prefix="${1:-$ABLETON_WINEPREFIX}" selected_runtime="${2:-$ABLETON_WINE_ROOT}"
    local proc pid exe image
    while IFS= read -r -d '' proc; do
        pid="${proc#/proc/}"
        pid="${pid%/environ}"
        exe="$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)"
        [ -n "$exe" ] || continue
        image="${exe##*/}"
        if ableton_pid_uses_runtime "$pid" "$selected_runtime"; then
            printf '%s\t%q\n' "$pid" "$exe"
            continue
        fi
        case "$image" in
            wine|wine64|wine-preloader|wine64-preloader|wineserver|wineserver64|.wine-wrapped)
                printf '%s\t%q\n' "$pid" "$exe"
                ;;
        esac
    done < <(grep -rzlFx --null "WINEPREFIX=$prefix" /proc/[0-9]*/environ 2>/dev/null)
    return 0
}

ableton_runtime_pids()
{
    local root="${1:-$ABLETON_WINE_ROOT}" proc pid
    for proc in /proc/[0-9]*; do
        pid="${proc#/proc/}"
        ableton_pid_uses_runtime "$pid" "$root" || continue
        printf '%s\n' "$pid"
    done
    return 0
}

ableton_stop_runtime_clients()
{
    local runtime="${1:-$ABLETON_WINE_ROOT}" pids pid deadline
    pids="$(ableton_runtime_pids "$runtime")"
    [ -n "$pids" ] || return 0
    if [ ! -t 0 ]; then
        echo "!! Wine is running. Run the installer in a terminal so it can ask before stopping Wine." >&2
        return 1
    fi
    ui_question q_stop_wine_title n q_stop_wine_yes q_stop_wine_no
    [ "$UI_ANSWER" = y ] || return 1

    pids="$(ableton_runtime_pids "$runtime")"
    for pid in $pids; do
        ableton_pid_uses_runtime "$pid" "$runtime" && kill "$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ]; do
        pids="$(ableton_runtime_pids "$runtime")"
        [ -n "$pids" ] || return 0
        sleep 0.1
    done
    for pid in $pids; do
        ableton_pid_uses_runtime "$pid" "$runtime" && kill -KILL "$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 5))
    while [ "$SECONDS" -lt "$deadline" ]; do
        pids="$(ableton_runtime_pids "$runtime")"
        [ -n "$pids" ] || return 0
        sleep 0.1
    done
    echo "!! Wine did not stop within 35 seconds." >&2
    return 1
}

ableton_pid_cmdline()
{
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true
}

ableton_live_pids()
{
    local pid cmd
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        cmd="$(ableton_pid_cmdline "$pid")"
        case "$cmd" in *"Ableton Live"*.exe*) printf '%s\n' "$pid" ;; esac
    done < <(ableton_prefix_pids)
    return 0
}

ableton_max_pids()
{
    local pid cmd
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        cmd="$(ableton_pid_cmdline "$pid")"
        case "$cmd" in *"Max 9"*Max.exe*|*"Cycling '74"*Max.exe*) printf '%s\n' "$pid" ;; esac
    done < <(ableton_prefix_pids)
    return 0
}

ableton_live_running()
{
    local pids
    # Consume the walker completely. `head -n 1` can return while the producer
    # still owns inherited launcher descriptors, briefly retaining the global or
    # bring-up lock after the parent has released its copies.
    pids="$(ableton_live_pids)"
    [ -n "$pids" ]
}

ableton_prefix_busy()
{
    local pids
    pids="$(ableton_prefix_pids "${1:-}" "${2:-}")"
    [ -n "$pids" ]
}

ableton_lifecycle_runtime_dir()
{
    local base="${XDG_RUNTIME_DIR:-$ABLETON_STATE_HOME/run}" key
    key="$(printf '%s\0%s' "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" | sha256sum | awk '{print substr($1,1,16)}')"
    printf '%s/ableton-wine/%s\n' "$base" "$key"
}

ableton_wait_for_pid_exit()
{
    local pid="$1" seconds="${2:-10}" i
    seconds="$(ableton_timeout_value "$seconds" process-timeout 1 120)" || return 2
    for ((i=0; i<seconds*10; i++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    return 1
}

# Windowless agents Live and Max leave behind, ended by exact name so no
# application is touched.  A name that is not running is a no-op.
# AbletonAudioCpl.exe is the USB Audio Driver's applet, started from a Startup
# shortcut when the installer's "Install USB Audio Driver" task is left checked,
# which is its default.
ABLETON_LEFTOVER_AGENTS="AbletonPushCpl.exe tusbaudiocplapp.exe AbletonAudioCpl.exe MicrosoftEdgeUpdate.exe"

ableton_agent_image()
{
    case " $ABLETON_LEFTOVER_AGENTS " in *" $1 "*) return 0 ;; esac
    return 1
}

# Holders whose image this teardown ends by name.  Kept separate from the unknown
# set because the two need opposite handling: one is on its way out, the other did
# not go when it was told to.
ableton_agent_holders()
{
    local pid image
    while IFS="$(printf '\t')" read -r pid image; do
        [ -n "$pid" ] || continue
        ableton_agent_image "$image" || continue
        printf '%s\t%s\n' "$pid" "$image"
    done
    return 0
}

# True while a holder list still names an agent this teardown ends by name.
ableton_holders_include_agent()
{
    local pid image
    while IFS="$(printf '\t')" read -r pid image; do
        [ -n "$image" ] || continue
        ableton_agent_image "$image" && return 0
    done <<< "$1"
    return 1
}

ableton_stop_leftover_agents()
{
    local runtime="${1:-$ABLETON_WINE_ROOT}" prefix="${2:-$ABLETON_WINEPREFIX}" image
    local args=()
    # wine builds a prefix at any path it is handed; a refusal must not create one.
    [ -x "$runtime/bin/wine" ] || return 0
    [ -f "$prefix/system.reg" ] || return 0
    for image in $ABLETON_LEFTOVER_AGENTS; do args+=(/im "$image"); done
    # One invocation: taskkill takes a list, and each wine start costs exit latency.
    # 9>&- as every other launcher-side wine invocation does: this runs from the
    # EXIT trap, where the flock'd bring-up lock can still be open, and wine would
    # inherit it and hold it for as long as it lives.
    ableton_run_bounded 15 env WINEPREFIX="$prefix" "$runtime/bin/wine" taskkill /f \
        "${args[@]}" >/dev/null 2>&1 9>&- || true
    return 0
}

# Wine's own processes, alive only while a client is.  Naming them in a report
# buries the one process that is actually holding the prefix.
ableton_wine_own_image()
{
    case "$1" in
        services.exe|winedevice.exe|plugplay.exe|svchost.exe|rpcss.exe|explorer.exe|\
        winemenubuilder.exe|start.exe|conhost.exe|wineboot.exe|rundll32.exe|wineserver)
            return 0 ;;
    esac
    return 1
}

# The prefix's processes worth reporting: everything Wine did not start itself.
ableton_prefix_holders()
{
    local pid image
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        image="$(ableton_pid_image "$pid")"
        ableton_wine_own_image "$image" && continue
        printf '%s\t%s\n' "$pid" "$image"
    done < <(ableton_prefix_pids "${1:-}" "${2:-}")
    return 0
}

# A helper this project installed and started, asked by the data home rather than
# by name so it stays right as helpers come and go.  Each has its own exit
# contract - learnheal.exe outlives Live deliberately, to heal the Learn View
# pane - so one still running does not mean the session is unfinished.
ableton_vendored_helper_image()
{
    [ -n "${ABLETON_DATA_HOME:-}" ] || return 1
    [ -f "$ABLETON_DATA_HOME/$1" ]
}

# Holders that are somebody else's: a Max, a second Live, a program the user
# started.  These are the ones worth naming.  Reads a holder list so a caller
# that already walked /proc need not walk it again.
# An image the teardown ends by name is never one of these, however long it
# takes to go: taskkill returns before its targets exit, and naming one here
# would tell a user to end their own prefix over a process we ended ourselves.
ableton_unknown_holders()
{
    local pid image
    while IFS="$(printf '\t')" read -r pid image; do
        [ -n "$pid" ] || continue
        ableton_agent_image "$image" && continue
        ableton_vendored_helper_image "$image" && continue
        printf '%s\t%s\n' "$pid" "$image"
    done
    return 0
}

ableton_prefix_unknown_holders()
{
    ableton_prefix_holders "${1:-}" "${2:-}" | ableton_unknown_holders
}

# Windows image name.  comm truncates at 15 characters, and argv[0] must be read
# on its NUL boundary: split on whitespace and every C:\Program Files path is "Program".
ableton_pid_image()
{
    local image
    # 2>/dev/null first: redirections are applied left to right, so with the input
    # last the open failure is reported before stderr has been silenced.
    image="$(tr '\0' '\n' 2>/dev/null < "/proc/$1/cmdline" | sed -n '1p')"
    image="${image##*\\}"
    image="${image##*/}"
    # A process that exits while it is being reported leaves nothing to read.
    [ -n "$image" ] || image="$(cat "/proc/$1/comm" 2>/dev/null || true)"
    printf '%s\n' "${image:-unknown}"
}

# End a session's agents, then confirm the prefix came down.  Whatever still holds
# it is a Max, a second Live or the user's own program - reported, never ended,
# since none of them is distinguishable from a leftover here.  Non-zero if held.
# Callers name themselves through ABLETON_SESSION_LABEL, which each launcher sets
# on the call; unset reads as "the session".
ableton_session_teardown()
{
    local runtime="${1:-$ABLETON_WINE_ROOT}" prefix="${2:-$ABLETON_WINEPREFIX}"
    local seconds="${3:-5}" pid image holders unknown="" deadline stuck="" stuck_agents=""
    seconds="$(ableton_timeout_value "$seconds" teardown-settle 1 60)" || return 2
    # First: taskkill is itself a wine process, so on an empty prefix it would start
    # a server and services that outlive the grace period and be reported as holders.
    ableton_prefix_busy "$runtime" "$prefix" || return 0
    ableton_stop_leftover_agents "$runtime" "$prefix" || true
    # taskkill returns before the processes it signalled have exited, so a flat
    # pause misreports one of them as a program the user is running.  Wait only
    # while an agent this teardown just ended is still there: applications are
    # not waited for, since none of them leaves within a grace period, and each
    # look walks every pid on the machine.
    deadline=$((SECONDS + seconds))
    stuck=""
    while :; do
        holders="$(ableton_prefix_holders "$runtime" "$prefix")"
        ableton_holders_include_agent "$holders" || break
        # The grace ran out with one still there, so the stop did not take.
        [ "$SECONDS" -lt "$deadline" ] || { stuck=1; break; }
        sleep 0.2
    done
    [ -n "$holders" ] || return 0
    unknown="$(printf '%s\n' "$holders" | ableton_unknown_holders)"
    [ -z "$stuck" ] || stuck_agents="$(printf '%s\n' "$holders" | ableton_agent_holders)"
    # An agent that outlived the stop is the exact failure this teardown exists to
    # prevent: MicrosoftEdgeUpdate.exe holds the wineserver for the rest of the
    # login session.  It is named, never folded into the helpers below, because
    # "it will quit on its own" is the one thing that is not true of it.
    if [ -n "$stuck_agents" ]; then
        printf -- '-- %s closed, but a background program did not stop and is holding the prefix:\n' \
            "${ABLETON_SESSION_LABEL:-the session}" >&2
        while IFS="$(printf '\t')" read -r pid image; do
            [ -n "$pid" ] || continue
            printf '   %s (pid %s)\n' "$image" "$pid" >&2
        done <<< "$stuck_agents"
        printf -- '   it will not leave on its own.  To end the prefix:\n' >&2
        printf -- '   WINEPREFIX=%s %s/bin/wineserver -k\n' "$prefix" "$runtime" >&2
    fi
    # Ours alone: the session is over, the helper finishes on its own, and the
    # server goes with it.  Said out loud because a wineserver outliving the
    # window looks like the bug this teardown exists to prevent.
    if [ -z "$unknown" ]; then
        [ -z "$stuck_agents" ] || return 1
        printf -- '-- %s closed; a background helper is still finishing and will quit on its own\n' \
            "${ABLETON_SESSION_LABEL:-the session}" >&2
        return 0
    fi
    printf -- '-- %s closed. Other unknown processes were left running:\n' \
        "${ABLETON_SESSION_LABEL:-the session}" >&2
    # Here-string, not a pipe from printf '%s': command substitution stripped the
    # trailing newline above, and read drops an unterminated final line.
    while IFS="$(printf '\t')" read -r pid image; do
        [ -n "$pid" ] || continue
        printf '   %s (pid %s)\n' "$image" "$pid" >&2
    done <<< "$unknown"
    # Naming them is half an answer: someone who wants them gone needs the means,
    # and the paths are the ones this session actually used.  Printed rather than
    # run, because whether they should go is the user's call.
    printf -- '-- Ableton-Linux helpers close themselves once the prefix is free. To kill the prefix forcefully instead:\n' >&2
    printf -- '   WINEPREFIX=%s %s/bin/wineserver -k\n' "$prefix" "$runtime" >&2
    return 1
}

# Wait for every process in the prefix to exit.  Bounded: a resident that outlives
# the command that started it holds the server open indefinitely.
ableton_prefix_wait()
{
    local runtime="${1:-$ABLETON_WINE_ROOT}" prefix="${2:-$ABLETON_WINEPREFIX}"
    ableton_run_bounded 60 env WINEPREFIX="$prefix" \
        "$runtime/bin/wineserver" -w >/dev/null 2>&1
}

# The same wait, naming what it waits on every 15s: a silent minute in front of an
# installer reads as a hang.  It is the wait above, run in the background and
# watched, so the bound and the exit code cannot drift from it.  Ticks go to
# stdout, where the rest of the install narrative goes; the teardown's messages
# go to stderr, being diagnostics after an application has closed.
ableton_prefix_wait_progress()
{
    local runtime="${1:-$ABLETON_WINE_ROOT}" prefix="${2:-$ABLETON_WINEPREFIX}"
    local waiter rc=0 elapsed=0 names
    ableton_prefix_wait "$runtime" "$prefix" &
    waiter=$!
    while kill -0 "$waiter" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        [ "$((elapsed % 15))" -eq 0 ] || continue
        names="$(ableton_prefix_unknown_holders "$runtime" "$prefix" \
            | cut -f2 | sort -u | tr '\n' ' ')"
        [ -z "${names// /}" ] \
            || printf -- '   still waiting for the prefix to settle (%ss): %s\n' \
                "$elapsed" "$names" \
            || true
    done
    wait "$waiter" || rc=$?
    return "$rc"
}

# Ask as soon as a background application is visible. Otherwise wait for Wine's
# own processes to finish, and ask before stopping them if the wait expires.
ableton_prefix_quiesce()
{
    local runtime="${1:-$ABLETON_WINE_ROOT}" prefix="${2:-$ABLETON_WINEPREFIX}" rc=0 holders
    holders="$(ableton_prefix_unknown_holders "$runtime" "$prefix")"
    if [ -n "$holders" ]; then
        ableton_stop_runtime_clients "$runtime"
        return
    fi
    ableton_prefix_wait_progress "$runtime" "$prefix" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ]; then
        return "$rc"
    fi
    ableton_stop_runtime_clients "$runtime" || return 1
    ableton_prefix_wait "$runtime" "$prefix" || return 3
}

ableton_stop_prefix()
{
    local runtime="${1:-$ABLETON_WINE_ROOT}" prefix="${2:-$ABLETON_WINEPREFIX}" pid pids
    pids="$(ableton_prefix_pids "$runtime" "$prefix")"
    [ -n "$pids" ] || return 0
    ableton_run_bounded 15 env WINEPREFIX="$prefix" \
        "$runtime/bin/wineserver" -k >/dev/null 2>&1 || true
    # Both signals re-check identity: the list was taken before the stop, and a pid
    # that exited in between can have been reissued to an unrelated process.
    for pid in $pids; do
        ableton_pid_uses_runtime "$pid" "$runtime" || continue
        ableton_pid_uses_prefix "$pid" "$prefix" || continue
        kill "$pid" 2>/dev/null || true
    done
    for pid in $pids; do
        ableton_wait_for_pid_exit "$pid" 5 || {
            ableton_pid_uses_runtime "$pid" "$runtime" \
                && ableton_pid_uses_prefix "$pid" "$prefix" \
                && kill -KILL "$pid" 2>/dev/null || true
        }
    done
    ! ableton_prefix_busy "$runtime" "$prefix"
}
