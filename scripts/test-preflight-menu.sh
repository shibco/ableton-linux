#!/usr/bin/env bash
# PTY coverage for the state-aware action menu and six sequential pre-flight
# questions. Behaviour IDs map to notes/PREFLIGHT-SETTINGS-TEST-MATRIX.md.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-preflight-menu-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

pass=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
command -v script >/dev/null 2>&1 || fail "script(1) is available"

snapshot_helper="$work/snapshot-home"
cat > "$snapshot_helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
home="${1:?home is required}"
output="${2:?snapshot output is required}"
: > "$output"
while IFS= read -r -d '' object; do
    relative="${object#"$home"}"
    [ -n "$relative" ] || relative=/
    digest=-
    target=-
    if [ -f "$object" ] && [ ! -L "$object" ]; then
        digest="$(sha256sum -- "$object" | awk '{print $1}')"
    elif [ -L "$object" ]; then
        target="$(readlink -z -- "$object" | base64 -w0)"
    fi
    # Capture identity and nanosecond timestamps after reading the object, so
    # the snapshot's own reads cannot hide a same-byte in-place rewrite.
    metadata="$(stat -c \
        'type=%F|mode=%a|uid=%u|gid=%g|size=%s|dev=%d|ino=%i|links=%h|mtime=%y|ctime=%z|birth=%w' \
        -- "$object")"
    printf '%q|%s|%s|%s\n' "$relative" "$metadata" "$digest" "$target" \
        >> "$output"
done < <(find -P "$home" -xdev -print0 | sort -z)
EOF
chmod +x "$snapshot_helper"

kit="$work/kit"
mkdir -p -- "$kit/scripts/lib"
cp -- "$here/lib/ui.sh" "$kit/scripts/lib/ui.sh"
cat > "$kit/scripts/installer.sh" <<'EOF'
#!/usr/bin/env bash
"${STUB_SNAPSHOT_HELPER:?}" "${HOME:?}" "${STUB_HOME_SNAPSHOT_AT_DELEGATION:?}"
if ! cmp -s -- "${STUB_HOME_SNAPSHOT_BEFORE:?}" \
        "${STUB_HOME_SNAPSHOT_AT_DELEGATION:?}"; then
    printf 'HOME changed before installer.sh received the request\n' >&2
    diff -u -- "${STUB_HOME_SNAPSHOT_BEFORE:?}" \
        "${STUB_HOME_SNAPSHOT_AT_DELEGATION:?}" >&2 || true
    exit 97
fi
printf '%s\n' "$*" > "${STUB_ARGS_FILE:?}"
printf '@@DELEGATED@@\n' >&"${ABLETON_UI_TTY_FD:-1}"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$kit/scripts/installer.sh"
tar -cf "$work/payload.tar" -C "$kit" .
"$here/make-installer.sh" --render-header --version preflight-test \
    --payload-sha "$(sha256sum "$work/payload.tar" | awk '{print $1}')" \
    > "$work/installer.run"
cat "$work/payload.tar" >> "$work/installer.run"
chmod +x "$work/installer.run"

# A cancelled uninstall scope must return before the self-extracting wrapper
# asks tar to unpack anything. Delegated cases still use the real tar.
mkdir -p -- "$work/fakebin"
real_tar="$(type -P tar)"
cat > "$work/fakebin/tar" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_TAR_LOG:?}"
exec "${STUB_REAL_TAR:?}" "$@"
EOF
cat > "$work/fakebin/pgrep" <<'EOF'
#!/bin/sh
[ ! -s "${STUB_PKILL_LOG:?}" ] || exit 1
case "$*" in
    '-x wineserver') exit "${STUB_PGREP_RC:-1}" ;;
    '-x wineserver64') exit "${STUB_PGREP64_RC:-1}" ;;
    *) exit 2 ;;
esac
EOF
cat > "$work/fakebin/pkill" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_PKILL_LOG:?unexpected pkill from wrapper test}"
exit "${STUB_PKILL_RC:-0}"
EOF
chmod +x "$work/fakebin/tar" "$work/fakebin/pgrep" "$work/fakebin/pkill"

wait_for()   # output literal [minimum count]
{
    local out="$1" literal="$2" minimum="${3:-1}" i=0 count=0
    while [ "$i" -lt 200 ]; do
        count="$(grep -aoF "$literal" "$out" 2>/dev/null | wc -l || true)"
        [ "$count" -lt "$minimum" ] || return 0
        sleep 0.05
        i=$((i + 1))
    done
    printf 'timed out waiting for %s occurrence(s) of: %s\n' "$minimum" "$literal" >&2
    return 1
}

assert_straight_frontier()   # raw-output current-index headings...
{
    local out="$1" current="$2" heading count expected i
    shift 2
    local -a headings=("$@")
    for i in "${!headings[@]}"; do
        heading="${headings[$i]}"
        count="$(grep -aoF "$heading" "$out" 2>/dev/null | wc -l || true)"
        expected=0
        [ "$i" -gt "$current" ] || expected=1
        [ "$count" -eq "$expected" ] || fail \
            "before answering question $((current + 1)), $heading is visible $count time(s), expected $expected"
    done
    count="$(grep -aoF '@@DELEGATED@@' "$out" 2>/dev/null | wc -l || true)"
    [ "$count" -eq 0 ] || fail \
        "installer.sh is delegated before question $((current + 1)) is answered"
}

snapshot_home()   # home output
{
    "$snapshot_helper" "$1" "$2"
}

assert_home_unchanged()   # name home before after
{
    local name="$1" home="$2" before="$3" after="$4"
    snapshot_home "$home" "$after"
    if ! cmp -s -- "$before" "$after"; then
        diff -u -- "$before" "$after" >&2 || true
        fail "$name changed HOME before installer.sh received the request"
    fi
}

normalize_terminal()   # raw output normalized output
{
    LC_ALL=C sed -E \
        -e $'s/\033\\][^\a]*(\a|\033\\\\)//g' \
        -e $'s/\033\\[[0-?]*[ -\\/]*[@-~]//g' \
        -e $'s/\r//g' \
        -e 's/[[:space:]]+$//' "$1" > "$2"
}

run_tty()   # name home driver-function
{
    local name="$1" home="$2" driver="$3" command="${4:-}" scope="${5:-}"
    local out before after delegation tar_log pkill_log
    out="$work/$name.raw"
    before="$work/$name.home.before"
    after="$work/$name.home.after"
    delegation="$work/$name.home.delegation"
    tar_log="$work/$name.tar"
    pkill_log="$work/$name.pkill"
    rm -f -- "$work/$name.args" "$delegation" "$tar_log" "$pkill_log"
    : > "$out"
    snapshot_home "$home" "$before"
    # shellcheck disable=SC2094,SC2016 # child expands path; driver polls transcript
    env -i PATH="$work/fakebin:$PATH" HOME="$home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm \
        SHELL=/bin/bash NO_COLOR=1 \
        ABLETON_UI_PROMPT_TIMEOUT="${PREFLIGHT_PROMPT_TIMEOUT:-30}" \
        STUB_ARGS_FILE="$work/$name.args" PREFLIGHT_INSTALLER="$work/installer.run" \
        PREFLIGHT_COMMAND="$command" PREFLIGHT_SCOPE="$scope" \
        STUB_TAR_LOG="$tar_log" STUB_REAL_TAR="$real_tar" \
        STUB_PGREP_RC="${STUB_PGREP_RC:-1}" \
        STUB_PGREP64_RC="${STUB_PGREP64_RC:-1}" STUB_PKILL_LOG="$pkill_log" \
        STUB_SNAPSHOT_HELPER="$snapshot_helper" \
        STUB_HOME_SNAPSHOT_BEFORE="$before" \
        STUB_HOME_SNAPSHOT_AT_DELEGATION="$delegation" \
        script -qfec 'stty rows 80 cols 120; set --; [ -z "$PREFLIGHT_COMMAND" ] || set -- "$PREFLIGHT_COMMAND"; [ -z "$PREFLIGHT_SCOPE" ] || set -- "$@" "$PREFLIGHT_SCOPE"; status=0; sh "$PREFLIGHT_INSTALLER" "$@" || status=$?; echo @@DONE@@:$status; exit "$status"' /dev/null \
        < <("$driver" "$out") > "$out" 2>&1 || true
    assert_home_unchanged "$name" "$home" "$before" "$after"
    normalize_terminal "$out" "$work/$name.txt"
    grep -qF '@@DONE@@:0' "$out" \
        || fail "$name did not finish through the expected successful/cancelled wrapper path"
}

wait_for_uninstall_scope()   # raw-output; stop quickly if an old wrapper delegates
{
    local out="$1" i=0
    while [ "$i" -lt 200 ]; do
        grep -aqF '(Default)' "$out" 2>/dev/null && return 0
        if grep -aqF '@@DELEGATED@@' "$out" 2>/dev/null \
           || grep -aqF '@@DONE@@' "$out" 2>/dev/null; then
            return 1
        fi
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}

assert_uninstall_scope_set()   # run-name
{
    local name="$1" start="${2:-after-action}" actual="$work/$1.uninstall-scopes"
    local expected="$work/$1.uninstall-scopes.expected"
    awk -v start="$start" '
        BEGIN { after_action=(start == "direct") }
        /Choose an action:/ { after_action=1; next }
        after_action && /@@(DELEGATED|DONE)@@/ { exit }
        after_action && /> / && /\[[[:alpha:]]\]/ {
            line=$0
            sub(/^.*> /, "", line)
            print line
        }
    ' "$work/$name.txt" > "$actual"
    printf '%s\n' '[R]untime only (Default)' '[P]refix only' '[A]ll' '[E]xit' > "$expected"
    if ! cmp -s -- "$expected" "$actual"; then
        diff -u -- "$expected" "$actual" >&2 || true
        fail "$name does not expose exactly the four uninstall scopes in order"
    fi
}

run_notty()   # name home [installer arguments...]
{
    local name="$1" home="$2" before after delegation tar_log pkill_log status=0
    shift 2
    before="$work/$name.home.before"
    after="$work/$name.home.after"
    delegation="$work/$name.home.delegation"
    tar_log="$work/$name.tar"
    pkill_log="$work/$name.pkill"
    rm -f -- "$work/$name.args" "$delegation" "$tar_log" "$pkill_log"
    snapshot_home "$home" "$before"
    env -i PATH="$work/fakebin:$PATH" HOME="$home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm \
        STUB_ARGS_FILE="$work/$name.args" \
        STUB_SNAPSHOT_HELPER="$snapshot_helper" \
        STUB_HOME_SNAPSHOT_BEFORE="$before" \
        STUB_HOME_SNAPSHOT_AT_DELEGATION="$delegation" \
        STUB_TAR_LOG="$tar_log" STUB_REAL_TAR="$real_tar" \
        STUB_PGREP_RC="${STUB_PGREP_RC:-1}" \
        STUB_PGREP64_RC="${STUB_PGREP64_RC:-1}" STUB_PKILL_LOG="$pkill_log" \
        sh "$work/installer.run" "$@" \
        </dev/null > "$work/$name.out" 2>&1 || status=$?
    assert_home_unchanged "$name" "$home" "$before" "$after"
    [ "$status" -eq "${NOTTY_EXPECT_STATUS:-0}" ] \
        || fail "$name exited with status $status"
}

answer_default_questions()   # output; assumes action was already selected
{
    local out="$1" i
    local -a questions=(
        '1/6 SET DEFAULT AUDIO BUFFER' '2/6 ENABLE KEYBOARD SHORTCUTS' '3/6 SET LIVE DISPLAY SCALING' \
        '4/6 SET AUDIO WORKER LIMIT' '5/6 TOGGLE REAL-TIME SCHEDULING' '6/6 SET POWER MANAGEMENT'
    )
    for i in "${!questions[@]}"; do
        wait_for "$out" "${questions[$i]}"
        # Wait for the complete current menu before inspecting the frontier or
        # sending input. No later heading or delegation may already be visible.
        wait_for "$out" '(Press Esc for previous setting)' "$((i + 1))"
        assert_straight_frontier "$out" "$i" "${questions[@]}"
        printf '\n'
    done
}

answer_defaults()   # output; assumes action was already selected
{
    local out="$1"
    answer_default_questions "$out"
    wait_for "$out" '@@DELEGATED@@'
    wait_for "$out" '@@DONE@@'
}

drive_fresh_defaults()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf '\n'
    answer_defaults "$out"
}

drive_wine_cancel()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf '\n'
    answer_default_questions "$out"
    wait_for "$out" 'STOP ALL RUNNING WINE PROCESSES'
    [ ! -s "$work/wine-cancel.pkill" ] \
        || fail 'the wrapper killed wineserver before the user answered'
    printf '\n'
    wait_for "$out" '@@DONE@@'
}

drive_wine_stop()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf '\n'
    answer_default_questions "$out"
    wait_for "$out" 'STOP ALL RUNNING WINE PROCESSES'
    [ ! -s "$work/wine-stop.pkill" ] \
        || fail 'the wrapper killed wineserver before the user answered'
    printf 'y\n'
    wait_for "$out" '@@DELEGATED@@'
    wait_for "$out" '@@DONE@@'
}

make_preferences()   # home shortcuts dpi threads rt power
{
    local home="$1" shortcuts="$2" dpi="$3" threads="$4" rt="$5" power="$6"
    mkdir -p -- "$home/.config/ableton-wine"
    cat > "$home/.config/ableton-wine/preferences" <<EOF
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=$shortcuts
dpi=$dpi
audio_threads=$threads
rt=$rt
power=$power
EOF
    chmod 600 "$home/.config/ableton-wine/preferences"
}

make_managed_install()   # home complete|incomplete [custom-prefix]
{
    local home="$1" state="$2" prefix
    prefix="${3:-$home/.wine-ableton}"
    local config="$home/.config/ableton-wine/config"
    mkdir -p -- "$prefix" "$(dirname "$config")" "$home/.local/share/ableton-wine"
    printf 'format=1\nprefix=%s\n' "$prefix" > "$prefix/.ableton-linux-prefix"
    [ "$state" != complete ] || printf 'WINE REGISTRY Version 2\n' > "$prefix/system.reg"
    cat > "$config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$home/.local/opt/wine-d2d1-nspa-11.13
prefix=$prefix
live_major=12
link_mode=session
linkd=$home/.local/share/ableton-wine/ableton-linkd
EOF
    chmod 600 "$config"
}

write_valid_config()   # home destination prefix
{
    local home="$1" destination="$2" prefix="$3"
    mkdir -p -- "$(dirname "$destination")"
    cat > "$destination" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$home/.local/opt/wine-d2d1-nspa-11.13
prefix=$prefix
live_major=12
link_mode=session
linkd=$home/.local/share/ableton-wine/ableton-linkd
EOF
    chmod 600 "$destination"
}

assert_action_set()   # run-name exact menu entries...
{
    local name="$1" actual="$work/$1.actions" expected="$work/$1.actions.expected" entry
    shift
    awk '
        /Ableton-Linux Installer Choice:/ { in_actions=1; next }
        in_actions && /Choose an action:/ { exit }
        in_actions && /> / {
            line=$0
            sub(/^.*> /, "> ", line)
            print line
        }
    ' "$work/$name.txt" > "$actual"
    : > "$expected"
    for entry in "$@"; do printf '%s\n' "$entry" >> "$expected"; done
    if ! cmp -s -- "$expected" "$actual"; then
        diff -u -- "$expected" "$actual" >&2 || true
        fail "$name does not expose exactly the expected action set"
    fi
}

assert_expected_state()   # run-name healthy|incomplete|fresh
{
    local name="$1" expected="$2"
    case "$expected" in
        healthy)
            assert_action_set "$name" \
                '> [U]pdate (or press Enter)' '> [R]einstall' \
                '> Remo[v]e Ableton Linux' '> [Q]uit' ;;
        incomplete)
            assert_action_set "$name" \
                '> [R]einstall (or press Enter)' \
                '> Remo[v]e Ableton Linux' '> [Q]uit' ;;
        fresh)
            assert_action_set "$name" \
                '> [I]nstall (or press Enter)' '> [Q]uit' ;;
        *) fail "test requested unknown expected state: $expected" ;;
    esac
}

assert_adjacent_question()   # normalized-output heading explanation option... hint
{
    local transcript="$1" heading="$2" line expected index=-1 count=0 i
    shift 2
    local -a lines=()
    mapfile -t lines < <(sed -e '/^[[:space:]]*$/d' -e '/^│$/d' "$transcript")
    for i in "${!lines[@]}"; do
        case "${lines[$i]}" in
            *"$heading") index="$i"; count=$((count + 1)) ;;
        esac
    done
    [ "$count" -eq 1 ] || fail "$heading is not rendered exactly once on the straight path"
    for expected in "$@"; do
        index=$((index + 1))
        line="${lines[$index]:-}"
        case "$line" in
            *"$expected") ;;
            *) fail "$heading is not immediately followed by: $expected" ;;
        esac
    done
}

assert_semantic_count()   # normalized-output semantic-line-suffix expected-count
{
    local transcript="$1" expected="$2" wanted="$3" line found=0
    while IFS= read -r line; do
        case "$line" in *"$expected") found=$((found + 1)) ;; esac
    done < "$transcript"
    [ "$found" -eq "$wanted" ] \
        || fail "$expected is rendered $found time(s), expected $wanted"
}

assert_strict_heading_order()   # normalized-output
{
    local transcript="$1" heading line previous=0 delegated_line
    local -a matches=()
    local -a headings=(
        '1/6 SET DEFAULT AUDIO BUFFER' '2/6 ENABLE KEYBOARD SHORTCUTS' '3/6 SET LIVE DISPLAY SCALING'
        '4/6 SET AUDIO WORKER LIMIT' '5/6 TOGGLE REAL-TIME SCHEDULING' '6/6 SET POWER MANAGEMENT'
    )
    for heading in "${headings[@]}"; do
        mapfile -t matches < <(grep -nF -- "$heading" "$transcript" || true)
        [ "${#matches[@]}" -eq 1 ] \
            || fail "$heading is not the sole straight-path heading at its position"
        line="${matches[0]%%:*}"
        [ "$line" -gt "$previous" ] \
            || fail "straight-path question headings are not in strict 1-to-6 line order"
        previous="$line"
    done
    mapfile -t matches < <(grep -nF -- '@@DELEGATED@@' "$transcript" || true)
    [ "${#matches[@]}" -eq 1 ] \
        || fail "straight-path delegation is not rendered exactly once"
    delegated_line="${matches[0]%%:*}"
    [ "$delegated_line" -gt "$previous" ] \
        || fail "straight-path delegation does not follow question six"
}

assert_immediate_back_transition()   # run-name target-index
{
    local name="$1" target="$2"
    local transcript="$work/$name.txt"
    local hint_occurrence=$((target + 1)) start end segment
    local expected="${matrix_questions[$((target - 1))]}"
    segment="$work/$name.back-transition"
    start="$(grep -nF '(Press Esc for previous setting)' "$transcript" \
        | sed -n "${hint_occurrence}p" | cut -d: -f1 || true)"
    end="$(grep -nF "$expected" "$transcript" \
        | sed -n '2p' | cut -d: -f1 || true)"
    [ -n "$start" ] && [ -n "$end" ] && [ "$end" -gt "$start" ] \
        || fail "Escape from question $((target + 1)) does not reach question $target after its completed menu"
    : > "$segment"
    if [ "$end" -gt $((start + 1)) ]; then
        sed -n "$((start + 1)),$((end - 1))p" "$transcript" > "$segment"
    fi
    if grep -Eqi \
        'Ableton-Linux Installer Choice:|Choose an action:|Choose (a )?setting|[1-6]/6 |settings (submenu|menu|summary|review)|review (your )?settings|confirm (your )?settings|apply these settings' \
        "$segment"; then
        fail "Escape from question $((target + 1)) shows an action, submenu, summary, or other question before question $target"
    fi
}

# ACT-FRESH + NAV-ORDER + NAV-EXPLANATIONS + DEFAULTS: a fresh action is named
# Install, then every setting is asked exactly once in the confirmed order.
fresh="$work/home-fresh"
mkdir -p -- "$fresh"
run_tty fresh-defaults "$fresh" drive_fresh_defaults
assert_action_set fresh-defaults \
    '> [I]nstall (or press Enter)' '> [Q]uit'
assert_strict_heading_order "$work/fresh-defaults.txt"
[ "$(cat "$work/fresh-defaults.args")" = install ] \
    || fail "fresh defaults do not route to installer install without synthetic overrides"
fresh_transcript="$work/fresh-defaults.txt"
assert_adjacent_question "$fresh_transcript" '1/6 SET DEFAULT AUDIO BUFFER' \
    'A lower default audio buffer reduces audio latency but can cause distortion during playback.' \
    'You can change this default later using pipeasio-settings.' \
    '[1] 64 frames' '[2] 128 frames (Default)' '[3] 256 frames' \
    '[4] 512 frames' '[5] 1024 frames' \
    '(Press Esc for previous setting)'

# A typed choice must appear before Enter is pressed. Silent input makes some
# terminals display a padlock and gives no visible response to the key.
drive_visible_choice()
{
    local out="$1" i
    local -a remaining=(
        '2/6 ENABLE KEYBOARD SHORTCUTS' '3/6 SET LIVE DISPLAY SCALING' '4/6 SET AUDIO WORKER LIMIT'
        '5/6 TOGGLE REAL-TIME SCHEDULING' '6/6 SET POWER MANAGEMENT'
    )
    wait_for "$out" 'Choose an action:'; printf '\n'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER'
    wait_for "$out" '(Press Esc for previous setting)'
    printf '2'
    wait_for "$out" 'Please choose [1-5]: 2'
    : > "$work/visible-choice.seen"
    printf '\n'
    for i in "${!remaining[@]}"; do
        wait_for "$out" "${remaining[$i]}"
        wait_for "$out" '(Press Esc for previous setting)' "$((i + 2))"
        printf '\n'
    done
    wait_for "$out" '@@DELEGATED@@'
    wait_for "$out" '@@DONE@@'
}
run_tty visible-choice "$fresh" drive_visible_choice
[ -e "$work/visible-choice.seen" ] \
    || fail "a typed pre-flight choice stays hidden until Enter"
ok "pre-flight choices appear while the user types"
assert_adjacent_question "$fresh_transcript" '2/6 ENABLE KEYBOARD SHORTCUTS' \
    'Determine whether Live can take over system shortcuts,' \
    'to remain faithful to your Live keyboard shortcut muscle memory.' \
    '[A]ssign to Live (Default)' '[P]reserve desktop shortcuts' \
    '(Press Esc for previous setting)'
assert_adjacent_question "$fresh_transcript" '3/6 SET LIVE DISPLAY SCALING' \
    'Changes how Live will be displayed on your montior.' \
    "You almost always want 'Automatic,' unless your system has a particular quirk." \
    '[A]utomatic (Default)' '[N]ormal (100%)' '[F]ractional' \
    "[P]reserve (Don't change under any circumstance)" \
    '(Press Esc for previous setting)'
assert_adjacent_question "$fresh_transcript" '4/6 SET AUDIO WORKER LIMIT' \
    'Balances the available amount of computational power set aside for Live.' \
    'Automatic is our optimisation work. Live is optimised for Windows.' \
    'Depending on your CPU, more may not always be better!' \
    '[A]utomatic (Default)' '[L]et Live decide (Not recommended)' \
    '[1-63] Specify a custom limit (1 to 63)' \
    '(Press Esc for previous setting)'
assert_adjacent_question "$fresh_transcript" '5/6 TOGGLE REAL-TIME SCHEDULING' \
    'Another optimisation that prioritises Live and audio on your system.' \
    'Change this to normal if you are struggling with performance or issues with' \
    'your system.' \
    '[A]utomatic (Default)' '[N]ormal scheduling' \
    '(Press Esc for previous setting)'
assert_adjacent_question "$fresh_transcript" '6/6 SET POWER MANAGEMENT' \
    "For convenience, this project can automatically manage your linux machine's power profile" \
    'while Live is open and running.' \
    '[P]erformance (Default)' '[B]alanced' "[D]on't change" \
    '(Press Esc for previous setting)'
for semantic in \
    '1/6 SET DEFAULT AUDIO BUFFER' '2/6 ENABLE KEYBOARD SHORTCUTS' '3/6 SET LIVE DISPLAY SCALING' \
    '4/6 SET AUDIO WORKER LIMIT' '5/6 TOGGLE REAL-TIME SCHEDULING' '6/6 SET POWER MANAGEMENT' \
    'A lower default audio buffer reduces audio latency but can cause distortion during playback.' \
    'You can change this default later using pipeasio-settings.' \
    'Determine whether Live can take over system shortcuts,' \
    'to remain faithful to your Live keyboard shortcut muscle memory.' \
    'Changes how Live will be displayed on your montior.' \
    "You almost always want 'Automatic,' unless your system has a particular quirk." \
    'Balances the available amount of computational power set aside for Live.' \
    'Automatic is our optimisation work. Live is optimised for Windows.' \
    'Depending on your CPU, more may not always be better!' \
    'Another optimisation that prioritises Live and audio on your system.' \
    'Change this to normal if you are struggling with performance or issues with' \
    "For convenience, this project can automatically manage your linux machine's power profile" \
    'while Live is open and running.' \
    '[1] 64 frames' '[2] 128 frames (Default)' '[3] 256 frames' \
    '[4] 512 frames' '[5] 1024 frames' \
    '[A]ssign to Live (Default)' '[P]reserve desktop shortcuts' \
    '[N]ormal (100%)' '[F]ractional' \
    "[P]reserve (Don't change under any circumstance)" \
    '[L]et Live decide (Not recommended)' '[1-63] Specify a custom limit (1 to 63)' \
    '[N]ormal scheduling' '[P]erformance (Default)' '[B]alanced' "[D]on't change"; do
    assert_semantic_count "$fresh_transcript" "$semantic" 1
done
assert_semantic_count "$fresh_transcript" '[A]utomatic (Default)' 3
assert_semantic_count "$fresh_transcript" '(Press Esc for previous setting)' 6
[ "$(grep -Ec '[[:digit:]]+/6 ' "$fresh_transcript")" -eq 6 ] \
    || fail "the straight path renders a missing or seventh numbered question"
[ "$(grep -cF '@@DELEGATED@@' "$fresh_transcript")" -eq 1 ] \
    || fail "the straight path does not delegate exactly once after question six"
delegated_line="$(grep -nF '@@DELEGATED@@' "$fresh_transcript" | cut -d: -f1)"
if sed -n "1,${delegated_line}p" "$fresh_transcript" \
    | grep -Eqi '7/6|settings (summary|review)|review (your )?settings|confirm (your )?settings|apply these settings'; then
    fail "a seventh prompt or settings summary appears before delegation"
fi
ok "ACT-FRESH/NAV-ORDER/DEFAULTS: fresh Install asks six explained questions with 128 default"

STUB_PGREP_RC=0 run_tty wine-cancel "$fresh" drive_wine_cancel
[ ! -e "$work/wine-cancel.args" ] \
    || fail 'declining the Wine-process question started installer.sh'
[ ! -s "$work/wine-cancel.pkill" ] \
    || fail 'declining the Wine-process question killed wineserver'

STUB_PGREP64_RC=0 run_tty wine-stop "$fresh" drive_wine_stop
[ "$(cat "$work/wine-stop.pkill")" = $'-x wineserver\n-x wineserver64' ] \
    || fail 'approval did not stop both Wine server names'
[ "$(cat "$work/wine-stop.args")" = install ] \
    || fail 'approval stopped before the install began'
ok "WINE QUESTION: approval stops both Wine server names"

drive_delayed_choice()
{
    local out="$1" i
    local -a questions=(
        '2/6 ENABLE KEYBOARD SHORTCUTS' '3/6 SET LIVE DISPLAY SCALING' '4/6 SET AUDIO WORKER LIMIT'
        '5/6 TOGGLE REAL-TIME SCHEDULING' '6/6 SET POWER MANAGEMENT'
    )
    wait_for "$out" 'Choose an action:'; printf '\n'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER'
    wait_for "$out" '(Press Esc for previous setting)'
    sleep 2
    if grep -aqF '2/6 ENABLE KEYBOARD SHORTCUTS' "$out"; then
        : > "$work/preflight-timed-out"
        return
    fi
    printf '3\n'
    for i in "${!questions[@]}"; do
        wait_for "$out" "${questions[$i]}"
        wait_for "$out" '(Press Esc for previous setting)' "$((i + 2))"
        printf '\n'
    done
    wait_for "$out" '@@DONE@@'
}
rm -f -- "$work/preflight-timed-out"
PREFLIGHT_PROMPT_TIMEOUT=1 run_tty delayed-choice "$fresh" drive_delayed_choice
[ ! -e "$work/preflight-timed-out" ] \
    || fail "a pre-flight question advances when its old timer expires"
[ "$(cat "$work/delayed-choice.args")" = 'install --audio-buffer=256' ] \
    || fail "a pre-flight question does not accept an answer after its old timer expires"
ok "NAV-NO-TIMEOUT: pre-flight questions wait until the user answers"

# ACT-HEALTHY: custom configured prefixes count; a healthy install offers
# Update/Reinstall/Remove/Quit, with Update as the default and no fresh Install.
healthy="$work/home-healthy"
custom_prefix="$work/custom-prefix"
mkdir -p -- "$healthy"
make_managed_install "$healthy" complete "$custom_prefix"
drive_healthy_quit()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf 'q\n'
    wait_for "$out" '@@DONE@@'
}
run_tty healthy "$healthy" drive_healthy_quit
assert_action_set healthy \
    '> [U]pdate (or press Enter)' '> [R]einstall' \
    '> Remo[v]e Ableton Linux' '> [Q]uit'
ok "ACT-HEALTHY: a configured custom-prefix install offers Update, Reinstall, Remove and Quit"

# installer.run uninstall presents exactly the requested four choices.
drive_direct_uninstall()
{
    local out="$1"
    wait_for_uninstall_scope "$out" || return 0
    case "$uninstall_scope_answer" in
        runtime) printf '\n' ;;
        prefix) printf 'Prefix only\n' ;;
        all) printf 'All\n' ;;
        exit) printf 'Exit\n' ;;
    esac
    if [ "$uninstall_scope_answer" = exit ]; then
        wait_for "$out" '@@DONE@@'
    else
        wait_for "$out" '@@DELEGATED@@'
        wait_for "$out" '@@DONE@@'
    fi
}

for uninstall_scope_answer in runtime prefix all exit; do
    name="uninstall-scope-$uninstall_scope_answer"
    run_tty "$name" "$healthy" drive_direct_uninstall uninstall
    assert_uninstall_scope_set "$name" direct
    case "$uninstall_scope_answer" in
        runtime) expected='uninstall --keep-prefix' ;;
        prefix) expected='uninstall --prefix-only' ;;
        all) expected='uninstall --delete-prefix' ;;
        exit)
            [ ! -e "$work/$name.args" ] \
                || fail "Exit from uninstall scopes invokes the embedded installer"
            [ ! -e "$work/$name.tar" ] \
                || fail "Exit from uninstall scopes extracts the embedded payload"
            continue ;;
    esac
    [ "$(cat "$work/$name.args")" = "$expected" ] \
        || fail "$uninstall_scope_answer did not delegate $expected"
done
ok "REMOVE-SCOPES: installer.run uninstall routes Runtime, Prefix, All and Exit"

# ACT-INCOMPLETE: recognised ownership without a complete registry can be
# reinstalled or removed, but cannot be updated as though healthy.
incomplete="$work/home-incomplete"
mkdir -p -- "$incomplete"
make_managed_install "$incomplete" incomplete
run_tty incomplete "$incomplete" drive_healthy_quit
assert_action_set incomplete \
    '> [R]einstall (or press Enter)' '> Remo[v]e Ableton Linux' '> [Q]uit'
ok "ACT-INCOMPLETE: incomplete managed state offers Reinstall, Remove and Quit only"

# ACT-FOREIGN: a foreign default Wine prefix is not misclassified as managed.
foreign="$work/home-foreign"
mkdir -p -- "$foreign/.wine-ableton"
printf 'foreign registry\n' > "$foreign/.wine-ableton/system.reg"
run_tty foreign "$foreign" drive_healthy_quit
assert_action_set foreign '> [I]nstall (or press Enter)' '> [Q]uit'
ok "ACT-FOREIGN: unrelated Wine state is never treated as project ownership"

# NAV-CHOICES + CLI-ROUTING: each question accepts its non-default directly;
# there are no nested submenus, and only deliberate changes reach installer.sh.
drive_all_choices()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf 'i\n'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER'; printf '4\n'
    wait_for "$out" '2/6 ENABLE KEYBOARD SHORTCUTS'; printf 'p\n'
    wait_for "$out" '3/6 SET LIVE DISPLAY SCALING'; printf 'n\n'
    wait_for "$out" '4/6 SET AUDIO WORKER LIMIT'; printf '16\n'
    wait_for "$out" '5/6 TOGGLE REAL-TIME SCHEDULING'; printf 'n\n'
    wait_for "$out" '6/6 SET POWER MANAGEMENT'; printf 'b\n'
    wait_for "$out" '@@DONE@@'
}
run_tty all-choices "$fresh" drive_all_choices
[ "$(cat "$work/all-choices.args")" = \
  'install --audio-buffer=512 --shortcuts=preserve --dpi=100 --audio-threads=16 --rt=off --power=balanced' ] \
    || fail "sequential choices do not reach the installer as exact validated intent"
! grep -qF 'Choose a setting' "$work/all-choices.raw" \
    || fail "the sequential questionnaire contains a summary/settings submenu"
ok "NAV-CHOICES/CLI-ROUTING: six direct answers become six exact installer flags"

# NAV-OPTION-MATRIX: every selectable row is exercised through the PTY, not
# inferred from its label. Five paths cover all buffer, shortcut, display,
# worker, RT and power mappings, including Don't change and Let Live decide.
drive_option_matrix()
{
    local out="$1" i
    wait_for "$out" 'Choose an action:'; printf 'i\n'
    for ((i=0; i<6; i++)); do
        wait_for "$out" "${matrix_questions[$i]}"
        printf '%s\n' "${matrix_answers[$i]}"
    done
    wait_for "$out" '@@DONE@@'
}
matrix_questions=('1/6 SET DEFAULT AUDIO BUFFER' '2/6 ENABLE KEYBOARD SHORTCUTS' \
                  '3/6 SET LIVE DISPLAY SCALING' '4/6 SET AUDIO WORKER LIMIT' \
                  '5/6 TOGGLE REAL-TIME SCHEDULING' '6/6 SET POWER MANAGEMENT')
matrix_rows=(
    '1 a a a a p|install --audio-buffer=64'
    '2 p n l n b|install --shortcuts=preserve --dpi=100 --audio-threads=off --rt=off --power=balanced'
    '3 a f 1 a d|install --audio-buffer=256 --dpi=fractional --audio-threads=1 --power=off'
    '4 p p 63 n p|install --audio-buffer=512 --shortcuts=preserve --dpi=preserve --audio-threads=63 --rt=off'
    '5 a a 16 a b|install --audio-buffer=1024 --audio-threads=16 --power=balanced'
)
matrix_index=0
for matrix_row in "${matrix_rows[@]}"; do
    matrix_index=$((matrix_index + 1))
    answers="${matrix_row%%|*}"
    expected="${matrix_row#*|}"
    read -r -a matrix_answers <<< "$answers"
    run_tty "option-matrix-$matrix_index" "$fresh" drive_option_matrix
    [ "$(cat "$work/option-matrix-$matrix_index.args")" = "$expected" ] \
        || fail "option matrix row $matrix_index maps to the wrong persistent intent"
done
ok "NAV-OPTION-MATRIX: every direct setting choice maps to its exact flag"

# NAV-BACK: Escape goes back exactly one question and retains earlier answers.
# A replacement answer changes the final intent; later answers retain their
# prior selection as the default when revisited.
drive_back_one()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf 'i\n'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER'; printf '4\n'
    wait_for "$out" '2/6 ENABLE KEYBOARD SHORTCUTS'; printf 'p\n'
    wait_for "$out" '3/6 SET LIVE DISPLAY SCALING'; printf '\033'
    wait_for "$out" '2/6 ENABLE KEYBOARD SHORTCUTS' 2; printf 'a\n'
    wait_for "$out" '3/6 SET LIVE DISPLAY SCALING' 2; printf 'f\n'
    wait_for "$out" '4/6 SET AUDIO WORKER LIMIT'; printf '12\n'
    wait_for "$out" '5/6 TOGGLE REAL-TIME SCHEDULING'; printf 'n\n'
    wait_for "$out" '6/6 SET POWER MANAGEMENT'; printf 'b\n'
    wait_for "$out" '@@DONE@@'
}
run_tty back-one "$fresh" drive_back_one
[ "$(grep -aoF '2/6 ENABLE KEYBOARD SHORTCUTS' "$work/back-one.raw" | wc -l)" -eq 2 ] \
    || fail "Escape does not return from question 3 to question 2 exactly once"
[ "$(cat "$work/back-one.args")" = \
  'install --audio-buffer=512 --dpi=fractional --audio-threads=12 --rt=off --power=balanced' ] \
    || fail "back navigation loses retained answers or keeps the replaced shortcut answer"
ok "NAV-BACK: Escape moves back one question while retaining and revising answers"

# NAV-BACK-MATRIX: Escape from every question after the first returns exactly
# to the immediately preceding question, never to a submenu or action menu.
drive_back_matrix()
{
    local out="$1" i minimum
    wait_for "$out" 'Choose an action:'; printf 'i\n'
    for ((i=0; i<back_target; i++)); do
        wait_for "$out" "${matrix_questions[$i]}"; printf '\n'
    done
    wait_for "$out" "${matrix_questions[$back_target]}"
    wait_for "$out" '(Press Esc for previous setting)' "$((back_target + 1))"
    printf '\033'
    wait_for "$out" "${matrix_questions[$((back_target-1))]}" 2; printf '\n'
    for ((i=back_target; i<6; i++)); do
        minimum=1
        [ "$i" -ne "$back_target" ] || minimum=2
        wait_for "$out" "${matrix_questions[$i]}" "$minimum"; printf '\n'
    done
    wait_for "$out" '@@DONE@@'
}
for back_target in 1 2 3 4 5; do
    run_tty "back-matrix-$back_target" "$fresh" drive_back_matrix
    assert_immediate_back_transition "back-matrix-$back_target" "$back_target"
    previous=$((back_target - 1))
    [ "$(grep -aoF "${matrix_questions[$previous]}" "$work/back-matrix-$back_target.raw" | wc -l)" -eq 2 ] \
        || fail "Escape from question $((back_target+1)) does not return exactly to question $back_target"
    [ "$(cat "$work/back-matrix-$back_target.args")" = install ] \
        || fail "Escape-only navigation synthesises persistent intent"
done
ok "NAV-BACK-MATRIX: Escape returns one question at all five boundaries"

# NAV-FIRST-BACK + NAV-ACTION-RESET: Escape from question one returns to the
# action menu. Choosing Quit never extracts/delegates or persists the draft.
drive_back_to_actions()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf 'i\n'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER'; printf '\033'
    wait_for "$out" 'Choose an action:' 2; printf 'q\n'
    wait_for "$out" '@@DONE@@'
}
run_tty back-actions "$fresh" drive_back_to_actions
[ ! -e "$work/back-actions.args" ] || fail "a cancelled draft reaches installer.sh"
[ "$(grep -aoF 'Choose an action:' "$work/back-actions.raw" | wc -l)" -eq 2 ] \
    || fail "Escape from question one does not return exactly to the action menu"
grep -qF 'Cancelled' "$work/back-actions.raw" || fail "Quit after backing out is not reported Cancelled"
ok "NAV-FIRST-BACK: Escape returns to actions and Quit discards every draft setting"

# NAV-ACTION-RESET: returning from a draft to the action menu and choosing a
# different operation reloads persisted/current values. The abandoned draft
# must not follow the replacement action as a synthetic flag.
drive_change_action()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf 'u\n'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER'; printf '4\n'
    wait_for "$out" '2/6 ENABLE KEYBOARD SHORTCUTS'; printf '\033'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER' 2; printf '\033'
    wait_for "$out" 'Choose an action:' 2; printf 'r\n'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER' 3; printf '\n'
    wait_for "$out" '2/6 ENABLE KEYBOARD SHORTCUTS' 2; printf '\n'
    wait_for "$out" '3/6 SET LIVE DISPLAY SCALING'; printf '\n'
    wait_for "$out" '4/6 SET AUDIO WORKER LIMIT'; printf '\n'
    wait_for "$out" '5/6 TOGGLE REAL-TIME SCHEDULING'; printf '\n'
    wait_for "$out" '6/6 SET POWER MANAGEMENT'; printf '\n'
    wait_for "$out" '@@DONE@@'
}
action_reset_home="$work/home-action-reset"
mkdir -p -- "$action_reset_home/.config/pipeasio"
make_managed_install "$action_reset_home" complete
make_preferences "$action_reset_home" preserve preserve off off balanced
printf '[pipeasio]\nbuffer_size = 2048\n' \
    > "$action_reset_home/.config/pipeasio/config.ini"
run_tty changed-action "$action_reset_home" drive_change_action
[ "$(cat "$work/changed-action.args")" = install ] \
    || fail "an abandoned Update draft follows the replacement Reinstall action"
if [ "$(grep -aoF '2048 frames (Current)' "$work/changed-action.raw" | wc -l)" -ne 2 ] \
   || [ "$(grep -aoF '512 frames (Current)' "$work/changed-action.raw" | wc -l)" -ne 1 ]; then
    fail "replacement action does not reload the persisted/current buffer"
fi
ok "NAV-ACTION-RESET: changing action discards draft intent and reloads saved/current values"

# NAV-EXPLICIT-DEFAULTS: choosing defaults is real reset intent when the saved
# current values differ. Enter retains; a typed default emits the exact flags.
drive_explicit_defaults()
{
    local out="$1" answer i=0
    wait_for "$out" 'Choose an action:'; printf 'u\n'
    for answer in 2 a a a a p; do
        wait_for "$out" "${matrix_questions[$i]}"; printf '%s\n' "$answer"
        i=$((i + 1))
    done
    wait_for "$out" '@@DONE@@'
}
run_tty explicit-defaults "$action_reset_home" drive_explicit_defaults
[ "$(cat "$work/explicit-defaults.args")" = \
  'update --audio-buffer=128 --shortcuts=take --dpi=auto --audio-threads=auto --rt=auto --power=performance' ] \
    || fail "typed defaults do not reset differing saved/current settings"
ok "NAV-EXPLICIT-DEFAULTS: typed defaults reset non-default saved values"

# NAV-VALIDATION: invalid worker values remain on the same question; one valid
# custom value proceeds without a secondary custom-value menu.
drive_worker_validation()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf 'i\n'
    wait_for "$out" '1/6 SET DEFAULT AUDIO BUFFER'; printf '\n'
    wait_for "$out" '2/6 ENABLE KEYBOARD SHORTCUTS'; printf '\n'
    wait_for "$out" '3/6 SET LIVE DISPLAY SCALING'; printf '\n'
    wait_for "$out" '4/6 SET AUDIO WORKER LIMIT'; printf '0\n'
    wait_for "$out" 'Choose Automatic, Let Live decide, or a number from 1 to 63.'; printf '64\n'
    wait_for "$out" 'Choose Automatic, Let Live decide, or a number from 1 to 63.' 2; printf 'word\n'
    wait_for "$out" 'Choose Automatic, Let Live decide, or a number from 1 to 63.' 3; printf '63\n'
    wait_for "$out" '5/6 TOGGLE REAL-TIME SCHEDULING'; printf '\n'
    wait_for "$out" '6/6 SET POWER MANAGEMENT'; printf '\n'
    wait_for "$out" '@@DONE@@'
}
run_tty worker-validation "$fresh" drive_worker_validation
[ "$(cat "$work/worker-validation.args")" = 'install --audio-threads=63' ] \
    || fail "custom worker validation does not retain the eventual valid value"
ok "NAV-VALIDATION: invalid direct worker input reprompts without opening a submenu"

# NAV-CURRENT: saved values and a valid custom PipeASIO value become the Enter
# defaults on Update. Continuing makes no synthetic preference arguments.
current="$work/home-current"
mkdir -p -- "$current/.config/pipeasio"
make_managed_install "$current" complete
make_preferences "$current" preserve preserve off off balanced
printf '[pipeasio]\ninputs = 2\nbuffer_size = 2048\noutputs = 2\n' \
    > "$current/.config/pipeasio/config.ini"
drive_update_defaults()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf 'u\n'
    answer_defaults "$out"
}
run_tty current "$current" drive_update_defaults
for expected in '2048 frames (Current)' '[P]reserve desktop shortcuts (Current)' \
                "[P]reserve (Don't change under any circumstance) (Current)" \
                '[L]et Live decide (Not recommended) (Current)' \
                '[N]ormal scheduling (Current)' '[B]alanced (Current)'; do
    grep -qF "$expected" "$work/current.raw" || fail "saved/default menu omits $expected"
done
[ "$(cat "$work/current.args")" = update ] \
    || fail "accepting current values turns them into overwrite intent"
ok "NAV-CURRENT: current and custom values are displayed and retained without writes"

# ACT-EVIDENCE: classifier ownership is based on strict project evidence, not
# one hard-coded prefix. Marker-only and config-only installs are recognised;
# an unsafe/malformed config plus foreign Wine files is not.
marker_only="$work/home-marker-only"
mkdir -p -- "$marker_only/.wine-ableton"
printf 'format=1\nprefix=%s\n' "$marker_only/.wine-ableton" \
    > "$marker_only/.wine-ableton/.ableton-linux-prefix"
printf 'WINE REGISTRY Version 2\n' > "$marker_only/.wine-ableton/system.reg"
run_tty marker-only "$marker_only" drive_healthy_quit
assert_action_set marker-only \
    '> [U]pdate (or press Enter)' '> [R]einstall' \
    '> Remo[v]e Ableton Linux' '> [Q]uit'

config_only="$work/home-config-only"
config_only_prefix="$work/config-only-prefix"
mkdir -p -- "$config_only"
make_managed_install "$config_only" complete "$config_only_prefix"
rm -f -- "$config_only_prefix/.ableton-linux-prefix"
run_tty config-only "$config_only" drive_healthy_quit
assert_action_set config-only \
    '> [U]pdate (or press Enter)' '> [R]einstall' \
    '> Remo[v]e Ableton Linux' '> [Q]uit'

marker_incomplete="$work/home-marker-incomplete"
mkdir -p -- "$marker_incomplete/.wine-ableton"
printf 'format=1\nprefix=%s\n' "$marker_incomplete/.wine-ableton" \
    > "$marker_incomplete/.wine-ableton/.ableton-linux-prefix"
run_tty marker-incomplete "$marker_incomplete" drive_healthy_quit
assert_action_set marker-incomplete \
    '> [R]einstall (or press Enter)' '> Remo[v]e Ableton Linux' '> [Q]uit'

config_incomplete="$work/home-config-incomplete"
config_incomplete_prefix="$work/config-incomplete-prefix"
mkdir -p -- "$config_incomplete"
make_managed_install "$config_incomplete" incomplete "$config_incomplete_prefix"
rm -f -- "$config_incomplete_prefix/.ableton-linux-prefix"
run_tty config-incomplete "$config_incomplete" drive_healthy_quit
assert_action_set config-incomplete \
    '> [R]einstall (or press Enter)' '> Remo[v]e Ableton Linux' '> [Q]uit'

missing_target="$work/home-missing-target"
mkdir -p -- "$missing_target"
make_managed_install "$missing_target" incomplete "$work/now-missing-prefix"
rm -rf -- "$work/now-missing-prefix"
run_tty missing-target "$missing_target" drive_healthy_quit
assert_action_set missing-target \
    '> [R]einstall (or press Enter)' '> Remo[v]e Ableton Linux' '> [Q]uit'

for unsafe_kind in malformed symlink; do
    unsafe="$work/home-unsafe-$unsafe_kind"
    mkdir -p -- "$unsafe/.config/ableton-wine" "$unsafe/.wine-ableton"
    printf 'foreign registry\n' > "$unsafe/.wine-ableton/system.reg"
    if [ "$unsafe_kind" = malformed ]; then
        printf 'format=1\nunknown=value\n' > "$unsafe/.config/ableton-wine/config"
    else
        write_valid_config "$unsafe" "$unsafe/external-config" "$unsafe/.wine-ableton"
        ln -s -- "$unsafe/external-config" "$unsafe/.config/ableton-wine/config"
    fi
    run_tty "unsafe-$unsafe_kind" "$unsafe" drive_healthy_quit
    assert_action_set "unsafe-$unsafe_kind" \
        '> [I]nstall (or press Enter)' '> [Q]uit'
done

for unsafe_kind in malformed symlink; do
    unsafe="$work/home-unsafe-marker-$unsafe_kind"
    mkdir -p -- "$unsafe/.wine-ableton"
    printf 'WINE REGISTRY Version 2\n' > "$unsafe/.wine-ableton/system.reg"
    if [ "$unsafe_kind" = malformed ]; then
        printf 'format=1\nunknown=value\n' \
            > "$unsafe/.wine-ableton/.ableton-linux-prefix"
    else
        printf 'format=1\nprefix=%s\n' "$unsafe/.wine-ableton" \
            > "$unsafe/external-marker"
        ln -s -- "$unsafe/external-marker" \
            "$unsafe/.wine-ableton/.ableton-linux-prefix"
    fi
    run_tty "unsafe-marker-$unsafe_kind" "$unsafe" drive_healthy_quit
    assert_action_set "unsafe-marker-$unsafe_kind" \
        '> [I]nstall (or press Enter)' '> [Q]uit'
done

marker_precedence="$work/home-marker-precedence"
mkdir -p -- "$marker_precedence/.config/ableton-wine" \
    "$marker_precedence/.wine-ableton"
printf 'format=1\nprefix=%s\n' "$marker_precedence/.wine-ableton" \
    > "$marker_precedence/.wine-ableton/.ableton-linux-prefix"
printf 'WINE REGISTRY Version 2\n' > "$marker_precedence/.wine-ableton/system.reg"
printf 'format=1\nunknown=value\n' \
    > "$marker_precedence/.config/ableton-wine/config"
run_tty marker-precedence "$marker_precedence" drive_healthy_quit
assert_action_set marker-precedence \
    '> [U]pdate (or press Enter)' '> [R]einstall' \
    '> Remo[v]e Ableton Linux' '> [Q]uit'

# A valid configuration is authoritative when the default-prefix marker points
# at a different valid state. Exercise both directions so source ordering cannot
# accidentally collapse to "any complete evidence wins".
config_complete_marker_incomplete="$work/home-config-complete-marker-incomplete"
config_complete_prefix="$work/config-complete-marker-incomplete-prefix"
mkdir -p -- "$config_complete_marker_incomplete/.wine-ableton" \
    "$config_complete_prefix"
write_valid_config "$config_complete_marker_incomplete" \
    "$config_complete_marker_incomplete/.config/ableton-wine/config" \
    "$config_complete_prefix"
printf 'WINE REGISTRY Version 2\n' > "$config_complete_prefix/system.reg"
printf 'format=1\nprefix=%s\n' "$config_complete_marker_incomplete/.wine-ableton" \
    > "$config_complete_marker_incomplete/.wine-ableton/.ableton-linux-prefix"
run_tty config-complete-marker-incomplete \
    "$config_complete_marker_incomplete" drive_healthy_quit
assert_expected_state config-complete-marker-incomplete healthy

config_incomplete_marker_complete="$work/home-config-incomplete-marker-complete"
config_incomplete_winning_prefix="$work/config-incomplete-marker-complete-prefix"
mkdir -p -- "$config_incomplete_marker_complete/.wine-ableton" \
    "$config_incomplete_winning_prefix"
write_valid_config "$config_incomplete_marker_complete" \
    "$config_incomplete_marker_complete/.config/ableton-wine/config" \
    "$config_incomplete_winning_prefix"
printf 'format=1\nprefix=%s\n' "$config_incomplete_marker_complete/.wine-ableton" \
    > "$config_incomplete_marker_complete/.wine-ableton/.ableton-linux-prefix"
printf 'WINE REGISTRY Version 2\n' \
    > "$config_incomplete_marker_complete/.wine-ableton/system.reg"
run_tty config-incomplete-marker-complete \
    "$config_incomplete_marker_complete" drive_healthy_quit
assert_expected_state config-incomplete-marker-complete incomplete

# Malformed marker evidence is ignored when a valid configuration selects the
# configured prefix; the configured prefix here is explicitly incomplete.
config_valid_marker_malformed="$work/home-config-valid-marker-malformed"
config_valid_marker_malformed_prefix="$work/config-valid-marker-malformed-prefix"
mkdir -p -- "$config_valid_marker_malformed/.wine-ableton" \
    "$config_valid_marker_malformed_prefix"
write_valid_config "$config_valid_marker_malformed" \
    "$config_valid_marker_malformed/.config/ableton-wine/config" \
    "$config_valid_marker_malformed_prefix"
printf 'format=1\nunknown=value\n' \
    > "$config_valid_marker_malformed/.wine-ableton/.ableton-linux-prefix"
printf 'WINE REGISTRY Version 2\n' \
    > "$config_valid_marker_malformed/.wine-ableton/system.reg"
run_tty config-valid-marker-malformed \
    "$config_valid_marker_malformed" drive_healthy_quit
assert_expected_state config-valid-marker-malformed incomplete

preferences_only="$work/home-preferences-only"
mkdir -p -- "$preferences_only"
make_preferences "$preferences_only" take auto auto auto performance
run_tty preferences-only "$preferences_only" drive_healthy_quit
assert_action_set preferences-only '> [I]nstall (or press Enter)' '> [Q]uit'

support_only="$work/home-support-only"
mkdir -p -- "$support_only/.local/bin" \
    "$support_only/.local/share/ableton-wine" \
    "$support_only/.local/share/applications"
printf '#!/bin/sh\n' > "$support_only/.local/bin/ableton-live"
chmod 755 "$support_only/.local/bin/ableton-live"
printf '[Desktop Entry]\nName=Ableton Live\n' \
    > "$support_only/.local/share/applications/ableton-live.desktop"
printf 'optional support only\n' \
    > "$support_only/.local/share/ableton-wine/preferences.sh"
run_tty support-only "$support_only" drive_healthy_quit
assert_action_set support-only '> [I]nstall (or press Enter)' '> [Q]uit'

ok "ACT-EVIDENCE: exact action sets cover strict evidence and config-first state precedence"

# ACT-DEFAULT-ROUTING: Enter and non-TTY use the state-specific default. Remove
# remains directly routable and never enters the settings questionnaire.
drive_default_action()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf '\n'
    answer_defaults "$out"
}
run_tty healthy-default "$healthy" drive_default_action
[ "$(cat "$work/healthy-default.args")" = update ] \
    || fail "Enter on a healthy install does not route to Update"
run_tty incomplete-default "$incomplete" drive_default_action
[ "$(cat "$work/incomplete-default.args")" = install ] \
    || fail "Enter on an incomplete install does not route to Reinstall"
drive_remove()
{
    local out="$1"
    wait_for "$out" 'Choose an action:'; printf 'v\n'
    wait_for "$out" '@@DONE@@'
}
run_tty remove-route "$healthy" drive_remove
[ "$(cat "$work/remove-route.args")" = uninstall ] \
    || fail "Remove does not route directly to uninstall"
! grep -qF '1/6 SET DEFAULT AUDIO BUFFER' "$work/remove-route.raw" \
    || fail "Remove enters the pre-flight settings questions"

for state_name in healthy incomplete; do
    state_home="$healthy"
    expected_action=update
    [ "$state_name" != incomplete ] \
        || { state_home="$incomplete"; expected_action=install; }
    run_notty "notty-$state_name" "$state_home"
    [ "$(cat "$work/notty-$state_name.args")" = "$expected_action" ] \
        || fail "non-TTY $state_name state does not route to $expected_action"
done
ok "ACT-DEFAULT-ROUTING: Enter/non-TTY defaults and Remove route by installation state"

# ROUTE-EXPLICIT/NONTTY: an explicit command and a non-terminal invocation do
# not ask pre-flight questions. The installer remains the authoritative parser.
run_notty explicit "$current" update
[ "$(cat "$work/explicit.args")" = update ] || fail "explicit Update changes arguments"
! grep -qF '1/6 SET DEFAULT AUDIO BUFFER' "$work/explicit.out" \
    || fail "an explicit command enters the interactive pre-flight"
run_notty notty "$fresh"
[ "$(cat "$work/notty.args")" = install ] || fail "fresh non-TTY does not select Install"
if grep -qF 'Choose an action:' "$work/notty.out" \
   || grep -qF '1/6 SET DEFAULT AUDIO BUFFER' "$work/notty.out"; then
    fail "non-TTY invocation prompts"
fi
NOTTY_EXPECT_STATUS=1 STUB_PGREP_RC=0 run_notty wine-notty "$fresh"
[ ! -e "$work/wine-notty.args" ] \
    || fail "a non-terminal Wine question started installer.sh"
[ ! -s "$work/wine-notty.pkill" ] \
    || fail "a non-terminal Wine question killed wineserver"
preferences="$current/.config/ableton-wine/preferences"
before_preferences="$(sha256sum "$preferences")"
run_notty notty-saved "$current"
[ "$(cat "$work/notty-saved.args")" = update ] \
    || fail "saved-preference non-TTY invocation does not select Update"
[ "$(sha256sum "$preferences")" = "$before_preferences" ] \
    || fail "non-TTY routing rewrites saved preferences without explicit intent"
if grep -qF 'Choose an action:' "$work/notty-saved.out" \
   || grep -qF '1/6 SET DEFAULT AUDIO BUFFER' "$work/notty-saved.out"; then
    fail "saved-preference non-TTY invocation prompts"
fi
ok "ROUTE-EXPLICIT/NONTTY: explicit and non-terminal runs never enter pre-flight UI"

printf '%s pre-flight menu checks passed\n' "$pass"
