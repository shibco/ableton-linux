#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shortcut-hold-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export XDG_RUNTIME_DIR="$work/runtime"
export XDG_STATE_HOME="$work/state-home"
mkdir -m 700 -- "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME"
. "$here/shortcut-hold.sh"

declare -A values writable fail_set
gsettings()
{
    # Two 'local's on purpose: assignments in one 'local' are not visible to
    # the later words in the same statement, so an id built there reads the
    # CALLER's schema/key instead of this stub's arguments. It only looked
    # right because shortcut-hold.sh happens to name its loop variables the
    # same; rename them and every key collapses onto one bucket.
    local op="$1" schema="$2" key="$3" value
    local id="$schema|$key"
    case "$op" in
        get) printf '%s\n' "${values[$id]:-@as []}" ;;
        writable) printf '%s\n' "${writable[$id]:-true}" ;;
        set)
            value="$4"
            [ "${fail_set[$id]:-0}" -eq 0 ] || return 1
            values[$id]="$value"
            ;;
        *) return 2 ;;
    esac
}
ableton_shortcuts_live_running() { return 1; }

pass=0
check()
{
    local label="$1" got="$2" want="$3"
    if [ "$got" != "$want" ]; then
        printf 'not ok - %s\n  got:  %s\n  want: %s\n' "$label" "$got" "$want" >&2
        exit 1
    fi
    pass=$((pass + 1))
    printf 'ok - %s\n' "$label"
}

check "strip exact Ctrl+Alt+Up and preserve Super" \
    "$(ableton_shortcuts_strip_ctrl_alt "['<Control><Alt>Up', '<Super>Up']" Up)" "['<Super>Up']"
check "strip exact key with accepted modifier names and order" \
    "$(ableton_shortcuts_strip_ctrl_alt "['<mod1><ctl>Down', '<Shift><Alt>Down']" Down)" "['<Shift><Alt>Down']"
check "preserve a Ctrl+Alt binding for another key" \
    "$(ableton_shortcuts_strip_ctrl_alt "['<Control><Alt>Page_Up', '<Control><Alt>Up']" Up)" \
    "['<Control><Alt>Page_Up']"
check "preserve Ctrl+Alt+Shift for the same key" \
    "$(ableton_shortcuts_strip_ctrl_alt "['<Control><Alt><Shift>Up', '<Alt><Control>Up']" Up)" \
    "['<Control><Alt><Shift>Up']"
check "normalize empty string array" "$(ableton_shortcuts_strip_ctrl_alt '@as []' Up)" "[]"
check "Live 12 only holds actual arrow conflicts" \
    "$(ableton_shortcuts_keys 'Ableton Live 12 Suite.exe')" \
    $'org.gnome.desktop.wm.keybindings switch-to-workspace-up Up\norg.gnome.desktop.wm.keybindings switch-to-workspace-down Down'
check "Live 11 also holds logout" \
    "$(ableton_shortcuts_keys 'Ableton Live 11 Suite.exe' | tail -1)" \
    "org.gnome.settings-daemon.plugins.media-keys logout Delete"
check "parse start time after a complex process name" \
    "$(ableton_shortcuts_stat_start_time '314 (Wine worker ) name) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242')" \
    "4242"

up='org.gnome.desktop.wm.keybindings|switch-to-workspace-up'
down='org.gnome.desktop.wm.keybindings|switch-to-workspace-down'
logout='org.gnome.settings-daemon.plugins.media-keys|logout'
values[$up]="['<Control><Alt>Up', '<Super>Up']"
values[$down]="['<Primary><Alt>Down']"
values[$logout]="['<Control><Alt>Delete']"
export ABLETON_SHORTCUTS=take XDG_CURRENT_DESKTOP='ubuntu:GNOME'
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
check "hold strips only conflicting Up entry" "${values[$up]}" "['<Super>Up']"
check "hold disables conflicting Down entry" "${values[$down]}" "[]"
check "Live 12 leaves logout alone" "${values[$logout]}" "['<Control><Alt>Delete']"
check "state format is versioned" "$(head -1 "$ableton_shortcuts_state")" "ABLETON_SHORTCUT_HOLD_V2"
check "state contains each key once" "$(tail -n +2 "$ableton_shortcuts_state" | wc -l)" "2"
check "state is private" "$(stat -c %a "$ableton_shortcuts_state")" "600"
check "recovery snapshot uses persistent state" "$ableton_shortcuts_state" "$XDG_STATE_HOME/ableton-wine/hold-v2"
check "leases and locks use runtime state" "$ableton_shortcuts_state_dir" "$XDG_RUNTIME_DIR/ableton-wine-shortcuts"
check "launcher lease is private" "$(stat -c %a "$ableton_shortcuts_state_dir/lease.$$")" "600"

ableton_shortcuts_hold_locked 'Ableton Live 12 Suite.exe'
check "repeat hold is idempotent" "$(tail -n +2 "$ableton_shortcuts_state" | wc -l)" "2"

# A concurrent Live 11 launch extends the same global transaction with logout.
ableton_shortcuts_hold_locked 'Ableton Live 11 Suite.exe'
check "Live 11 extends active hold with logout" "${values[$logout]}" "[]"
check "cross-version hold has no duplicate records" "$(tail -n +2 "$ableton_shortcuts_state" | wc -l)" "3"
if ableton_shortcuts_restore_if_idle; then
    echo "not ok - idle restore ignored a live launcher lease" >&2
    exit 1
fi
check "watcher-side restore respects live lease" "${values[$up]}" "['<Super>Up']"
ableton_shortcuts_restore
check "restore returns exact Up value" "${values[$up]}" "['<Control><Alt>Up', '<Super>Up']"
check "restore returns exact Down value" "${values[$down]}" "['<Primary><Alt>Down']"
check "restore returns exact logout value" "${values[$logout]}" "['<Control><Alt>Delete']"
check "successful restore removes state" "$([ ! -e "$ableton_shortcuts_state" ]; echo $?)" "0"

# A logout removes XDG_RUNTIME_DIR but not dconf.  A later launch must recover
# the held bindings from persistent state once the new session has no lease.
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
[ "$XDG_RUNTIME_DIR" = "$work/runtime" ] || exit 1
rm -rf -- "$XDG_RUNTIME_DIR"
mkdir -m 700 -- "$XDG_RUNTIME_DIR"
ableton_shortcuts_prepare '' '' 0
check "relaunch after runtime loss restores Up" "${values[$up]}" "['<Control><Alt>Up', '<Super>Up']"
check "relaunch after runtime loss restores Down" "${values[$down]}" "['<Primary><Alt>Down']"
check "runtime-loss recovery removes snapshot" "$([ ! -e "$ableton_shortcuts_state" ]; echo $?)" "0"

# A user edit while Live runs wins over the stale snapshot.
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
values[$up]="['<Super>Page_Up']"
ableton_shortcuts_restore
check "restore preserves concurrent user edit" "${values[$up]}" "['<Super>Page_Up']"

# Failed restoration is durable and succeeds on retry.
values[$up]="['<Control><Alt>Up', '<Super>Up']"
values[$down]="['<Primary><Alt>Down']"
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
fail_set[$down]=1
if ableton_shortcuts_restore; then
    echo "not ok - failed restore unexpectedly succeeded" >&2
    exit 1
fi
check "failed restore retains state" "$([ -f "$ableton_shortcuts_state" ]; echo $?)" "0"
check "failed key remains held" "${values[$down]}" "[]"
fail_set[$down]=0
ableton_shortcuts_restore
check "retry restores failed key" "${values[$down]}" "['<Primary><Alt>Down']"

# The detached watcher restores once neither a Live process nor launcher lease
# remains.  This is the crash/relaunch path used by the real launcher.
values[$up]="['<Control><Alt>Up']"
values[$down]="['<Primary><Alt>Down']"
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
rm -f -- "$ableton_shortcuts_state_dir"/lease.*
export ABLETON_SHORTCUTS_POLL_SECONDS=0.01
ableton_shortcuts_watch_loop
check "watcher restores after last lease exits" "${values[$up]}" "['<Control><Alt>Up']"
check "watcher removes completed recovery state" "$([ ! -e "$ableton_shortcuts_state" ]; echo $?)" "0"

# Recovery still runs when discovery did not find a Live executable. It must
# not start a new hold in this path, even when the opt-in variable is present.
values[$up]="['<Control><Alt>Up']"
values[$down]="['<Primary><Alt>Down']"
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
rm -f -- "$ableton_shortcuts_state_dir"/lease.*
ableton_shortcuts_prepare '' '' 0
check "missing Live still restores stale state" "${values[$down]}" "['<Primary><Alt>Down']"
check "missing Live does not take a new hold" "$([ ! -e "$ableton_shortcuts_state" ]; echo $?)" "0"

# Migrate the feature branch's per-prefix V1 snapshot before taking V2 state.
legacy="$work/legacy-v1"
printf '%s|%s|%s\n' \
    'org.gnome.desktop.wm.keybindings' 'switch-to-workspace-up' "['<Control><Alt>Up']" \
    > "$legacy"
chmod 600 "$legacy"
values[$up]='[]'
values[$down]='@as []'
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe' "$legacy"
check "legacy state is removed after migration" "$([ ! -e "$legacy" ]; echo $?)" "0"
check "legacy value is restored before V2 hold" "$(sed -n '2p' "$ableton_shortcuts_state" | cut -d'|' -f3)" "['<Control><Alt>Up']"
ableton_shortcuts_restore
check "migrated state restores normally" "${values[$up]}" "['<Control><Alt>Up']"

# Malformed legacy state cannot turn the launcher into an arbitrary GSettings
# writer. The file is retained for inspection and no unknown key is touched.
legacy_bad="$work/legacy-v1-bad"
printf '%s\n' "org.example.foreign|danger|['<Control><Alt>Up']" > "$legacy_bad"
chmod 600 "$legacy_bad"
values['org.example.foreign|danger']='SAFE'
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe' "$legacy_bad"
check "malformed V1 state is retained" "$([ -e "$legacy_bad" ]; echo $?)" "0"
check "malformed V1 state cannot write another setting" "${values['org.example.foreign|danger']}" "SAFE"
ableton_shortcuts_restore

# A locked key is skipped rather than creating misleading recovery state.
writable[$up]=false
values[$up]="['<Control><Alt>Up']"
values[$down]="@as []"
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
check "locked key stays untouched" "${values[$up]}" "['<Control><Alt>Up']"
check "no-op hold creates no state" "$([ ! -e "$ableton_shortcuts_state" ]; echo $?)" "0"

# Unknown state is never appended to or deleted.
printf '%s\n' 'FUTURE_SHORTCUT_STATE' > "$ableton_shortcuts_state"
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
check "unknown state is preserved" "$(cat "$ableton_shortcuts_state")" "FUTURE_SHORTCUT_STATE"

# Only the bare first line is a header. A fielded or repeated pseudo-header
# must never become GSettings restore authority.
printf '%s\n%s\n%s\n' \
    ABLETON_SHORTCUT_HOLD_V2 \
    "org.gnome.desktop.wm.keybindings|switch-to-workspace-up|['<Control><Alt>Up']|[]" \
    'ABLETON_SHORTCUT_HOLD_V2|junk|junk|junk' > "$ableton_shortcuts_state"
chmod 600 "$ableton_shortcuts_state"
ableton_shortcuts_prepare 'Ableton Live 12 Suite.exe'
check "fielded pseudo-header is rejected and retained" \
    "$(tail -n 1 "$ableton_shortcuts_state")" 'ABLETON_SHORTCUT_HOLD_V2|junk|junk|junk'

printf 'PASS: %d shortcut hold checks\n' "$pass"
