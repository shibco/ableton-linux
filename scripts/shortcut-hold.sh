#!/usr/bin/env bash
# Session-scoped GNOME shortcut hold for scripts/ableton-live.
#
# This file is sourced by the launcher and intentionally has no top-level side
# effects.  Coordination is session-global (under XDG_RUNTIME_DIR), because
# GSettings is session-global too: per-prefix state races as soon as two Wine
# prefixes run Live at the same time.  The recovery snapshot is persistent so
# it survives logout and reboot.

ableton_shortcuts_normalize_value()
{
    local value="$1"
    value="${value#@as }"
    printf '%s' "$value"
}

ableton_shortcuts_strip_ctrl_alt()
{
    local value="$1" terminal="${2,,}" inner entry accelerator modifier
    local have_ctrl have_alt valid out=""
    value="$(ableton_shortcuts_normalize_value "$value")"
    if [ "$value" = "[]" ]; then
        printf '[]'
        return
    fi

    # GSettings prints keybinding arrays as comma-separated quoted strings.
    # Accelerator names cannot contain commas, so a shell split is sufficient
    # here and avoids adding a Python dependency to the launcher.
    inner="${value#[}"
    inner="${inner%]}"
    local IFS=,
    for entry in $inner; do
        entry="${entry#${entry%%[![:space:]]*}}"
        accelerator="${entry#\'}"
        accelerator="${accelerator%\'}"
        accelerator="${accelerator,,}"
        have_ctrl=0
        have_alt=0
        valid=1
        while [[ "$accelerator" == \<*\>* ]]; do
            modifier="${accelerator#<}"
            modifier="${modifier%%>*}"
            accelerator="${accelerator#*>}"
            case "$modifier" in
                control|ctrl|ctl|primary)
                    [ "$have_ctrl" -eq 0 ] || valid=0
                    have_ctrl=1
                    ;;
                alt|mod1)
                    [ "$have_alt" -eq 0 ] || valid=0
                    have_alt=1
                    ;;
                *) valid=0 ;;
            esac
        done
        if [ "$valid" -eq 1 ] && [ "$have_ctrl" -eq 1 ] && [ "$have_alt" -eq 1 ] \
            && [ "$accelerator" = "$terminal" ]; then
            continue
        fi
        out="${out:+$out, }$entry"
    done
    printf '[%s]' "$out"
}

ableton_shortcuts_legacy_v1_valid()
{
    local state="$1" schema key original extra terminal
    local -A seen=()
    [ -f "$state" ] && [ ! -L "$state" ] && [ -O "$state" ] && [ -r "$state" ] \
        && [ "$(stat -c '%a' -- "$state" 2>/dev/null || true)" = 600 ] || return 1
    [ "$(LC_ALL=C tr -cd '\000' < "$state" 2>/dev/null | wc -c)" -eq 0 ] || return 1
    while IFS='|' read -r schema key original extra || [ -n "$schema$key$original$extra" ]; do
        [ -z "$extra" ] && [ -n "$original" ] || return 1
        case "$schema|$key" in
            org.gnome.desktop.wm.keybindings\|switch-to-workspace-up) terminal=Up ;;
            org.gnome.desktop.wm.keybindings\|switch-to-workspace-down) terminal=Down ;;
            org.gnome.settings-daemon.plugins.media-keys\|logout) terminal=Delete ;;
            *) return 1 ;;
        esac
        [ -z "${seen[$schema|$key]+x}" ] || return 1
        case "$original" in \[*\]|@as\ \[*\]) ;; *) return 1 ;; esac
        [ "$(ableton_shortcuts_strip_ctrl_alt "$original" "$terminal")" \
            != "$(ableton_shortcuts_normalize_value "$original")" ] || return 1
        seen["$schema|$key"]=1
    done < "$state"
    [ "${#seen[@]}" -ge 1 ]
}

ableton_shortcuts_keys()
{
    # Live only assigns Ctrl+Alt+Up/Down (note chance), not Left/Right.  Do not
    # disable unrelated workspace navigation in the name of future-proofing.
    printf '%s\n' \
        "org.gnome.desktop.wm.keybindings switch-to-workspace-up Up" \
        "org.gnome.desktop.wm.keybindings switch-to-workspace-down Down"
    case "$1" in
        *"Live 11 "*)
            printf '%s\n' "org.gnome.settings-daemon.plugins.media-keys logout Delete"
            ;;
    esac
}

ableton_shortcuts_live_running()
{
    pgrep -af '[P]rogramData.*Ableton Live.*\.exe|[A]bleton Live.*\.exe.*ProgramData' \
        >/dev/null 2>&1
}

ableton_shortcuts_init_state()
{
    local runtime state state_home
    runtime="${XDG_RUNTIME_DIR:-}"
    if [ -z "$runtime" ] || [ ! -d "$runtime" ] || [ ! -w "$runtime" ] \
        || [ -L "$runtime" ] || [ ! -O "$runtime" ]; then
        echo "ableton-live: cannot safely hold GNOME shortcuts without an owned, writable XDG_RUNTIME_DIR" >&2
        return 1
    fi
    runtime="$runtime/ableton-wine-shortcuts"

    if [ -n "${ABLETON_SHORTCUTS_STATE_DIR:-}" ]; then
        state="$ABLETON_SHORTCUTS_STATE_DIR"
    else
        state_home="${XDG_STATE_HOME:-}"
        if [ -z "$state_home" ]; then
            if [ -z "${HOME:-}" ]; then
                echo "ableton-live: cannot persist GNOME shortcut recovery state without HOME or XDG_STATE_HOME" >&2
                return 1
            fi
            state_home="$HOME/.local/state"
        fi
        state="$state_home/ableton-wine"
    fi

    if [ ! -e "$state" ]; then
        ( umask 077; mkdir -p -- "$state" ) || return 1
    fi
    if [ ! -d "$state" ] || [ -L "$state" ] || [ ! -O "$state" ] || [ ! -w "$state" ]; then
        echo "ableton-live: refusing unsafe shortcut recovery directory: $state" >&2
        return 1
    fi

    if [ -e "$runtime" ]; then
        if [ ! -d "$runtime" ] || [ -L "$runtime" ] || [ ! -O "$runtime" ] || [ ! -w "$runtime" ]; then
            echo "ableton-live: refusing unsafe shortcut state directory: $runtime" >&2
            return 1
        fi
    else
        ( umask 077; mkdir -m 700 -- "$runtime" ) || return 1
    fi

    ableton_shortcuts_state_dir="$runtime"
    ableton_shortcuts_snapshot_dir="$state"
    ableton_shortcuts_state="$state/hold-v2"
    ableton_shortcuts_op_lock="$runtime/operation.lock"
    ableton_shortcuts_watch_lock="$runtime/watcher.lock"
}

ableton_shortcuts_state_has_key()
{
    local want_schema="$1" want_key="$2" schema key original held
    [ -f "$ableton_shortcuts_state" ] || return 1
    while IFS='|' read -r schema key original held; do
        [ "$schema" = "$want_schema" ] && [ "$key" = "$want_key" ] && return 0
    done < "$ableton_shortcuts_state"
    return 1
}

ableton_shortcuts_state_valid()
{
    local header=""
    [ -f "$ableton_shortcuts_state" ] || return 0
    IFS= read -r header < "$ableton_shortcuts_state" || return 1
    [ "$header" = "ABLETON_SHORTCUT_HOLD_V2" ]
}

ableton_shortcuts_append_state()
{
    local schema="$1" key="$2" original="$3" held="$4" tmp
    case "$schema$key$original$held" in
        *'|'*|*$'\n'*) return 1 ;;
    esac
    tmp="$(mktemp "$ableton_shortcuts_snapshot_dir/.hold-v2.XXXXXX")" || return 1
    if [ -f "$ableton_shortcuts_state" ]; then
        cp -- "$ableton_shortcuts_state" "$tmp" || { rm -f -- "$tmp"; return 1; }
    else
        printf '%s\n' 'ABLETON_SHORTCUT_HOLD_V2' > "$tmp"
    fi
    printf '%s|%s|%s|%s\n' "$schema" "$key" "$original" "$held" >> "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$ableton_shortcuts_state"
}

ableton_shortcuts_restore_locked()
{
    local header schema key original held current tmp failures=0 changed=0 malformed=0
    [ -f "$ableton_shortcuts_state" ] || return 0
    IFS= read -r header < "$ableton_shortcuts_state" || header=""
    if [ "$header" != "ABLETON_SHORTCUT_HOLD_V2" ]; then
        echo "ableton-live: refusing unknown shortcut recovery state: $ableton_shortcuts_state" >&2
        return 1
    fi

    tmp="$(mktemp "$ableton_shortcuts_snapshot_dir/.hold-v2.pending.XXXXXX")" || return 1
    printf '%s\n' "$header" > "$tmp"
    while IFS='|' read -r schema key original held; do
        [ "$schema" = "ABLETON_SHORTCUT_HOLD_V2" ] && continue
        if [ -z "$schema" ] || [ -z "$key" ] || [ -z "$original" ] || [ -z "$held" ]; then
            printf '%s|%s|%s|%s\n' "$schema" "$key" "$original" "$held" >> "$tmp"
            malformed=1
            failures=$((failures + 1))
            continue
        fi
        current="$(gsettings get "$schema" "$key" 2>/dev/null)" || {
            printf '%s|%s|%s|%s\n' "$schema" "$key" "$original" "$held" >> "$tmp"
            failures=$((failures + 1))
            continue
        }
        if [ "$(ableton_shortcuts_normalize_value "$current")" = "$(ableton_shortcuts_normalize_value "$original")" ]; then
            continue
        fi
        if [ "$(ableton_shortcuts_normalize_value "$current")" != "$(ableton_shortcuts_normalize_value "$held")" ]; then
            echo "ableton-live: preserving a user change to GNOME shortcut $schema $key" >&2
            continue
        fi
        if gsettings set "$schema" "$key" "$original" 2>/dev/null; then
            current="$(gsettings get "$schema" "$key" 2>/dev/null)" || current=""
            if [ "$(ableton_shortcuts_normalize_value "$current")" = "$(ableton_shortcuts_normalize_value "$original")" ]; then
                changed=$((changed + 1))
                continue
            fi
        fi
        printf '%s|%s|%s|%s\n' "$schema" "$key" "$original" "$held" >> "$tmp"
        failures=$((failures + 1))
    done < "$ableton_shortcuts_state"

    if [ "$failures" -eq 0 ]; then
        rm -f -- "$tmp" "$ableton_shortcuts_state"
        [ "$changed" -eq 0 ] || echo "ableton-live: restored the GNOME shortcuts held for Live" >&2
        return 0
    fi
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$ableton_shortcuts_state"
    [ "$malformed" -eq 0 ] || echo "ableton-live: malformed shortcut recovery state was retained for inspection" >&2
    echo "ableton-live: some GNOME shortcuts could not be restored; recovery state retained at $ableton_shortcuts_state" >&2
    return 1
}

ableton_shortcuts_restore()
{
    local rc
    [ -f "${ableton_shortcuts_state:-}" ] || return 0
    exec 8>"$ableton_shortcuts_op_lock" || return 1
    flock 8 || { exec 8>&-; return 1; }
    ableton_shortcuts_restore_locked
    rc=$?
    flock -u 8
    exec 8>&-
    return "$rc"
}

ableton_shortcuts_restore_if_idle()
{
    local rc
    [ -f "${ableton_shortcuts_state:-}" ] || return 0
    exec 8>"$ableton_shortcuts_op_lock" || return 1
    flock 8 || { exec 8>&-; return 1; }
    if ableton_shortcuts_live_running || ableton_shortcuts_lease_alive; then
        rc=1
    else
        ableton_shortcuts_restore_locked
        rc=$?
    fi
    flock -u 8
    exec 8>&-
    return "$rc"
}

ableton_shortcuts_hold_locked()
{
    local exe_base="$1" schema key terminal current wanted verify held_count=0
    while read -r schema key terminal; do
        [ -n "$schema" ] || continue
        ableton_shortcuts_state_has_key "$schema" "$key" && continue
        [ "$(gsettings writable "$schema" "$key" 2>/dev/null)" = true ] || continue
        current="$(gsettings get "$schema" "$key" 2>/dev/null)" || continue
        wanted="$(ableton_shortcuts_strip_ctrl_alt "$current" "$terminal")"
        [ "$wanted" = "$(ableton_shortcuts_normalize_value "$current")" ] && continue

        # Persist recovery before changing the desktop.  A kill between these
        # operations therefore leaves an unnecessary record, never an
        # unrecoverable disabled binding.
        ableton_shortcuts_append_state "$schema" "$key" "$current" "$wanted" || continue
        if gsettings set "$schema" "$key" "$wanted" 2>/dev/null; then
            verify="$(gsettings get "$schema" "$key" 2>/dev/null)" || verify=""
            if [ "$(ableton_shortcuts_normalize_value "$verify")" = "$(ableton_shortcuts_normalize_value "$wanted")" ]; then
                held_count=$((held_count + 1))
            fi
        fi
    done <<< "$(ableton_shortcuts_keys "$exe_base")"
    [ "$held_count" -eq 0 ] || echo "ableton-live: holding the GNOME Ctrl+Alt shortcuts Live uses; they restore when all Live sessions exit" >&2
}

ableton_shortcuts_stat_start_time()
{
    local stat="$1" fields
    case "$stat" in
        *') '*) fields="${stat##*) }" ;;
        *) return 1 ;;
    esac
    set -- $fields
    [ "$#" -ge 20 ] || return 1
    shift 19
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$1"
}

ableton_shortcuts_proc_start_time()
{
    local pid="$1" stat
    [ -r "/proc/$pid/stat" ] || return 1
    stat="$(<"/proc/$pid/stat")" || return 1
    ableton_shortcuts_stat_start_time "$stat"
}

ableton_shortcuts_mark_lease()
{
    local pid="$1" start="" lease tmp
    [ "$pid" -gt 1 ] 2>/dev/null || return 1
    start="$(ableton_shortcuts_proc_start_time "$pid" 2>/dev/null)" || start=""
    [ -n "$start" ] || return 1
    lease="$ableton_shortcuts_state_dir/lease.$pid"
    tmp="$(mktemp "$ableton_shortcuts_state_dir/.lease.$pid.XXXXXX")" || return 1
    if ! ( umask 077; printf '%s %s\n' "$pid" "$start" > "$tmp" ); then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$lease"
}

ableton_shortcuts_lease_alive()
{
    local lease pid start current any=1
    for lease in "$ableton_shortcuts_state_dir"/lease.*; do
        [ -f "$lease" ] || continue
        read -r pid start < "$lease" || { rm -f -- "$lease"; continue; }
        case "$pid:$start" in *[!0-9:]*) rm -f -- "$lease"; continue ;; esac
        current="$(ableton_shortcuts_proc_start_time "$pid" 2>/dev/null)" || current=""
        if [ -n "$current" ] && [ "$current" = "$start" ]; then
            any=0
        else
            rm -f -- "$lease"
        fi
    done
    return "$any"
}

ableton_shortcuts_prepare()
{
    local exe_base="$1" legacy_state="${2:-}" allow_hold="${3:-1}"
    local desktop="${XDG_CURRENT_DESKTOP:-}" watch_needed=0 take_lease=0
    local schema key original failures
    ableton_shortcuts_active=0
    command -v gsettings >/dev/null 2>&1 || return 0
    command -v flock >/dev/null 2>&1 || {
        [ "${ABLETON_SHORTCUTS:-preserve}" != take ] || echo "ableton-live: cannot safely hold GNOME shortcuts without flock" >&2
        return 0
    }
    ableton_shortcuts_init_state || return 0

    exec 8>"$ableton_shortcuts_op_lock" || return 0
    flock 8 || { exec 8>&-; return 0; }

    # The old feature branch used per-prefix V1 state.  Heal it before a new
    # V2 hold so the old snapshot cannot immediately undo the new values.
    # V1 has no held-value field with which to detect concurrent user edits.
    if [ -n "$legacy_state" ] && [ -f "$legacy_state" ] && ! ableton_shortcuts_live_running; then
        if ableton_shortcuts_legacy_v1_valid "$legacy_state"; then
            failures=0
            while IFS='|' read -r schema key original; do
                gsettings set "$schema" "$key" "$original" 2>/dev/null || failures=$((failures + 1))
            done < "$legacy_state"
            if [ "$failures" -eq 0 ]; then
                rm -f -- "$legacy_state"
            else
                echo "ableton-live: legacy shortcut recovery state retained at $legacy_state" >&2
            fi
        else
            echo "ableton-live: refusing malformed legacy shortcut state: $legacy_state" >&2
        fi
    fi

    if ! ableton_shortcuts_state_valid; then
        echo "ableton-live: refusing unknown shortcut recovery state: $ableton_shortcuts_state" >&2
        flock -u 8
        exec 8>&-
        return 0
    fi
    if [ -f "$ableton_shortcuts_state" ] && ! ableton_shortcuts_live_running && ! ableton_shortcuts_lease_alive; then
        echo "ableton-live: restoring GNOME shortcuts left by a previous session" >&2
        ableton_shortcuts_restore_locked || true
    fi
    if [ "$allow_hold" = 1 ] && [ "${ABLETON_SHORTCUTS:-preserve}" = take ] \
        && [[ "${desktop,,}" == *gnome* ]]; then
        ableton_shortcuts_hold_locked "$exe_base"
        [ -f "$ableton_shortcuts_state" ] && take_lease=1
    fi
    # Adopt an existing valid hold even for a preserve launch.  This repairs a
    # crashed watcher without making that launch extend the hold via a lease.
    [ -f "$ableton_shortcuts_state" ] && watch_needed=1
    if [ "$take_lease" -eq 1 ] && ! ableton_shortcuts_mark_lease "$$"; then
        echo "ableton-live: could not create a shortcut hold lease; restoring immediately" >&2
        ableton_shortcuts_restore_locked || true
        watch_needed=0
    fi
    flock -u 8
    exec 8>&-

    if [ "$watch_needed" -eq 1 ]; then
        # Read by the sourcing launcher (scripts/ableton-live) to decide whether
        # to start the detached watcher; nothing in this file reads it.
        # shellcheck disable=SC2034
        ableton_shortcuts_active=1
    fi
}

ableton_shortcuts_watch_loop()
{
    local delay="${ABLETON_SHORTCUTS_POLL_SECONDS:-2}"
    exec 7>"$ableton_shortcuts_watch_lock" || return 1
    flock -n 7 || return 0
    while [ -f "$ableton_shortcuts_state" ]; do
        if ableton_shortcuts_live_running || ableton_shortcuts_lease_alive; then
            sleep "$delay"
            continue
        fi
        ableton_shortcuts_restore_if_idle && break
        sleep "$delay"
    done
}
