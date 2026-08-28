#!/usr/bin/env bash
# Minimal public boundary for the manifest-driven uninstaller.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d /tmp/ableton-uninstall-test.XXXXXX)"
failures=0
cases=0
reported_failures=0
children=()
TEST_FAIL_TOOL=
TEST_LEAVE_TOOL=

cleanup()
{
    local pid exe
    for pid in "${children[@]}"; do
        exe="$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)"
        case "$exe" in "$work"/*) kill "$pid" 2>/dev/null || true ;; esac
        wait "$pid" 2>/dev/null || true
    done
    case "$work" in /tmp/ableton-uninstall-test.*) /bin/rm -rf -- "$work" ;; esac
}
trap cleanup EXIT HUP INT TERM

check()
{
    local message="$1"
    shift
    if ! "$@"; then
        printf 'not ok - %s: %s\n' "$CASE" "$message" >&2
        failures=$((failures + 1))
    fi
}

done_case()
{
    cases=$((cases + 1))
    if [ "$failures" -eq "$reported_failures" ]; then
        printf 'ok - %s\n' "$CASE"
    fi
    reported_failures="$failures"
}

contains() { grep -qiF -- "$2" "$1/out" || grep -qiF -- "$2" "$1/err"; }
not_in_log() { ! grep -qF -- "$2" "$1"; }

mkdir -p -- "$work/corebin"
for tool in awk basename bash cat chmod cmp cp cut dirname env find flock grep \
            head id ln mkdir mktemp mv od readlink realpath rm sed sha256sum sleep \
            sort stat tail tput tr wc; do
    path="$(type -P "$tool" 2>/dev/null || true)"
    [ -z "$path" ] || ln -s -- "$path" "$work/corebin/$tool"
done

digest()
{
    if [ -L "$1" ]; then
        { printf 'symlink\0'; readlink -n -- "$1"; } | sha256sum | awk '{print $1}'
    else
        sha256sum -- "$1" | awk '{print $1}'
    fi
}

fixture()
{
    local base="$work/$1" state="$work/$1/xdg/state/ableton-wine"
    mkdir -p -- "$base/home/.local/bin" "$base/xdg/config/ableton-wine" \
        "$base/xdg/data/ableton-wine" "$state" "$base/xdg/cache" \
        "$base/xdg/run" "$base/tmp" "$base/runtime/bin" \
        "$base/prefix/drive_c" "$base/fakebin" "$base/trash"
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' \
        > "$base/runtime/.ableton-linux-runtime"
    printf 'runtime\n' > "$base/runtime/bin/payload"
    printf 'format=1\nprefix=%s\n' "$base/prefix" \
        > "$base/prefix/.ableton-linux-prefix"
    printf 'prefix\n' > "$base/prefix/drive_c/payload"
    printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
    cat > "$base/xdg/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
linkd=$base/xdg/data/ableton-wine/ableton-linkd
EOF
    cat > "$base/xdg/config/ableton-wine/preferences" <<'EOF'
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=preserve
dpi=preserve
audio_threads=off
rt=off
power=balanced
EOF
    printf '#!/bin/sh\n# Ableton Live launcher for the patched Wine stack\n' \
        > "$base/home/.local/bin/ableton-live"
    chmod 755 "$base/home/.local/bin/ableton-live"
    printf '2026.08.28.1\n' > "$base/xdg/data/ableton-wine/VERSION"
    printf 'leave me\n' > "$base/home/.local/bin/user-tool"
    ln -s -- "$base/runtime/bin/pipeasio-settings" \
        "$base/home/.local/bin/pipeasio-settings"
    {
        printf 'file\t%s\t%s\n' "$base/home/.local/bin/ableton-live" \
            "$(digest "$base/home/.local/bin/ableton-live")"
        printf 'file\t%s\t%s\n' "$base/xdg/data/ableton-wine/VERSION" \
            "$(digest "$base/xdg/data/ableton-wine/VERSION")"
        printf 'symlink\t%s\t%s\n' "$base/home/.local/bin/pipeasio-settings" \
            "$(digest "$base/home/.local/bin/pipeasio-settings")"
        printf 'runtime\t%s\twine-d2d1-nspa-11.13\n' "$base/runtime"
    } > "$state/install-manifest.tsv"
    chmod 600 "$base/xdg/config/ableton-wine/"* "$state/"*
    : > "$base/trash.log"
    : > "$base/rm.log"
    printf '%s\n' "$base"
}

trash_tool()
{
    local base="$1" name="$2"
    cat > "$base/fakebin/$name" <<'EOF'
#!/usr/bin/env bash
set -u
tool="$(basename "$0")"
target=""
for arg in "$@"; do
    case "$arg" in "$TEST_ROOT"|"$TEST_ROOT"/*) target="$arg"; break ;; esac
done
[ -n "$target" ] || exit 98
case "$tool" in
    gio) [ "$1" = trash ] || exit 96 ;;
    trash-put) [ "$#" -eq 1 ] || exit 96 ;;
    kioclient) [ "$1" = move ] && [ "$3" = trash:/ ] || exit 96 ;;
    *) exit 96 ;;
esac
printf '%s\t%s\n' "$tool" "$target" >> "$TEST_TRASH_LOG"
if [ "$TEST_FAIL_TOOL" = "$tool" ]; then exit 73; fi
if [ "$TEST_LEAVE_TOOL" = "$tool" ]; then exit 0; fi
count="$(wc -l < "$TEST_TRASH_LOG")"
/bin/mv -- "$target" "$TEST_TRASH_SINK/$count"
EOF
    chmod 755 "$base/fakebin/$name"
}

guarded_rm()
{
    local base="$1"
    cat > "$base/fakebin/rm" <<'EOF'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
    case "$arg" in
        -*) ;;
        "$TEST_ROOT"|"$TEST_ROOT"/*) ;;
        *) printf 'rm escaped fixture: %s\n' "$arg" >&2; exit 97 ;;
    esac
done
printf '%s\n' "$*" >> "$TEST_RM_LOG"
exec /bin/rm "$@"
EOF
    chmod 755 "$base/fakebin/rm"
}

run_uninstall()
{
    local base="$1"
    shift
    RUN_RC=0
    env -i HOME="$base/home" USER=test LOGNAME=test \
        XDG_CONFIG_HOME="$base/xdg/config" XDG_DATA_HOME="$base/xdg/data" \
        XDG_STATE_HOME="$base/xdg/state" XDG_CACHE_HOME="$base/xdg/cache" \
        XDG_RUNTIME_DIR="$base/xdg/run" TMPDIR="$base/tmp" \
        PATH="$base/fakebin:$work/corebin" LANG=C.UTF-8 TERM=dumb SHELL=/bin/bash \
        ABLETON_UI_ACTION=uninstall ABLETON_UI_PROMPT_TIMEOUT=1 \
        TEST_ROOT="$base" TEST_TRASH_LOG="$base/trash.log" \
        TEST_TRASH_SINK="$base/trash" TEST_RM_LOG="$base/rm.log" \
        TEST_FAIL_TOOL="$TEST_FAIL_TOOL" TEST_LEAVE_TOOL="$TEST_LEAVE_TOOL" \
        /bin/bash "$here/uninstall.sh" "$@" > "$base/out" 2> "$base/err" \
        || RUN_RC=$?
}

report_present()
{
    local label
    check "report has its own heading" contains "$1" "What remains"
    for label in Runtime Prefix "Linux integration" "Installer settings" "Shared state"; do
        check "report includes $label status" contains "$1" "$label:"
    done
}

report_says() { check "$2 status is $3" contains "$1" "$2: $3"; }

before_in_log()
{
    local log="$1" first="$2" second="$3" a b
    a="$(awk -F '\t' -v p="$first" '$2==p { print NR; exit }' "$log")"
    b="$(awk -F '\t' -v p="$second" '$2==p { print NR; exit }' "$log")"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

CASE="Runtime only removes integration and runtime"
base="$(fixture runtime)"
trash_tool "$base" gio
TEST_FAIL_TOOL=
run_uninstall "$base" --keep-prefix --yes
check "succeeds" test "$RUN_RC" -eq 0
check "runtime removed" test ! -e "$base/runtime"
check "launcher removed" test ! -e "$base/home/.local/bin/ableton-live"
check "prefix remains" test -d "$base/prefix"
check "settings remain" test -f "$base/xdg/config/ableton-wine/config"
check "state remains for partial scope" test -f \
    "$base/xdg/state/ableton-wine/install-manifest.tsv"
check "integration precedes runtime" before_in_log "$base/trash.log" \
    "$base/home/.local/bin/ableton-live" "$base/runtime"
check "manifest version removed" test ! -e "$base/xdg/data/ableton-wine/VERSION"
check "manifest symlink removed" test ! -L "$base/home/.local/bin/pipeasio-settings"
check "unmanifested file remains" test -f "$base/home/.local/bin/user-tool"
check "preferences remain" test -f "$base/xdg/config/ableton-wine/preferences"
report_present "$base"
report_says "$base" Runtime Removed
report_says "$base" Prefix Remains
report_says "$base" "Linux integration" Removed
report_says "$base" "Installer settings" Remains
report_says "$base" "Shared state" Remains
done_case

CASE="Prefix only removes only the prefix"
base="$(fixture prefix)"
trash_tool "$base" gio
run_uninstall "$base" --prefix-only --yes
check "succeeds" test "$RUN_RC" -eq 0
check "prefix removed" test ! -e "$base/prefix"
check "runtime remains" test -d "$base/runtime"
check "integration remains" test -e "$base/home/.local/bin/ableton-live"
check "preferences remain" test -f "$base/xdg/config/ableton-wine/preferences"
check "state remains" test -f "$base/xdg/state/ableton-wine/install-manifest.tsv"
report_present "$base"
report_says "$base" Runtime Remains
report_says "$base" Prefix Removed
report_says "$base" "Linux integration" Remains
done_case

CASE="All removes state last"
base="$(fixture all)"
trash_tool "$base" gio
run_uninstall "$base" --delete-prefix --yes
check "succeeds" test "$RUN_RC" -eq 0
check "runtime removed" test ! -e "$base/runtime"
check "prefix removed" test ! -e "$base/prefix"
check "integration removed" test ! -e "$base/home/.local/bin/ableton-live"
check "settings removed" test ! -e "$base/xdg/config/ableton-wine/config"
check "preferences removed" test ! -e "$base/xdg/config/ableton-wine/preferences"
check "state removed" test ! -e "$base/xdg/state/ableton-wine"
check "integration precedes runtime" before_in_log "$base/trash.log" \
    "$base/home/.local/bin/ableton-live" "$base/runtime"
check "runtime precedes prefix" before_in_log "$base/trash.log" \
    "$base/runtime" "$base/prefix"
check "settings precede shared state" before_in_log "$base/trash.log" \
    "$base/xdg/config/ableton-wine/config" "$base/xdg/state/ableton-wine"
check "prefix precedes shared state" before_in_log "$base/trash.log" \
    "$base/prefix" "$base/xdg/state/ableton-wine"
check "unmanifested file remains" test -f "$base/home/.local/bin/user-tool"
report_present "$base"
report_says "$base" Runtime Removed
report_says "$base" Prefix Removed
report_says "$base" "Linux integration" Removed
report_says "$base" "Installer settings" Removed
report_says "$base" "Shared state" Removed
done_case

for bad in missing-manifest unrelated-path runtime-mismatch runtime-marker \
           prefix-marker state-marker unsafe-runtime; do
    CASE="Unsafe ownership data is refused: $bad"
    base="$(fixture "bad-$bad")"
    trash_tool "$base" gio
    args=(--keep-prefix --yes)
    case "$bad" in
        missing-manifest)
            rm -- "$base/xdg/state/ableton-wine/install-manifest.tsv" ;;
        unrelated-path)
            printf 'file\t%s\t%s\n' "$base/unrelated" \
                0000000000000000000000000000000000000000000000000000000000000000 \
                >> "$base/xdg/state/ableton-wine/install-manifest.tsv" ;;
        runtime-mismatch)
            sed -i "s|^runtime\t$base/runtime\t|runtime\t$base/elsewhere\t|" \
                "$base/xdg/state/ableton-wine/install-manifest.tsv" ;;
        runtime-marker)
            printf 'format=1\nname=foreign\n' \
                > "$base/runtime/.ableton-linux-runtime" ;;
        prefix-marker)
            printf 'format=1\nprefix=/foreign\n' \
                > "$base/prefix/.ableton-linux-prefix"
            args=(--prefix-only --yes) ;;
        state-marker)
            printf 'format=1\nowner=foreign\n' \
                > "$base/xdg/state/ableton-wine/.ableton-linux-state" ;;
        unsafe-runtime)
            sed -i 's|^runtime_root=.*|runtime_root=/|' \
                "$base/xdg/config/ableton-wine/config"
            sed -i 's|^runtime\t[^\t]*\t|runtime\t/\t|' \
                "$base/xdg/state/ableton-wine/install-manifest.tsv" ;;
    esac
    run_uninstall "$base" "${args[@]}"
    check "fails" test "$RUN_RC" -ne 0
    check "nothing was sent to Trash" test ! -s "$base/trash.log"
    check "runtime remains" test -d "$base/runtime"
    check "prefix remains" test -d "$base/prefix"
    done_case
done

CASE="Changed manifest file is preserved and reported"
base="$(fixture changed)"
trash_tool "$base" gio
printf 'user replacement\n' > "$base/home/.local/bin/ableton-live"
run_uninstall "$base" --keep-prefix --yes
check "safe preservation succeeds" test "$RUN_RC" -eq 0
check "replacement remains" grep -qxF "user replacement" \
    "$base/home/.local/bin/ableton-live"
check "replacement was not offered to Trash" not_in_log "$base/trash.log" \
    "$base/home/.local/bin/ableton-live"
check "change is reported" contains "$base" "changed"
check "state remains to describe it" test -d "$base/xdg/state/ableton-wine"
done_case

start_process()
{
    local image="$1" prefix="$2"
    mkdir -p -- "$(dirname "$image")"
    cp -- "$(type -P sleep)" "$image"
    chmod 755 "$image"
    WINEPREFIX="$prefix" "$image" 30 >/dev/null 2>&1 &
    PROCESS_PID=$!
    children+=("$PROCESS_PID")
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(readlink -f -- "/proc/$PROCESS_PID/exe" 2>/dev/null || true)" = "$image" ] \
            && tr '\0' '\n' < "/proc/$PROCESS_PID/environ" 2>/dev/null \
                | grep -qxF "WINEPREFIX=$prefix" && return 0
        sleep 0.02
    done
    return 1
}

CASE="Relevant runtime process refuses removal"
base="$(fixture busy-runtime)"
trash_tool "$base" gio
start_process "$base/runtime/bin/wine" "$base/other-prefix"
run_uninstall "$base" --keep-prefix --yes
check "fails" test "$RUN_RC" -ne 0
check "nothing was trashed" test ! -s "$base/trash.log"
check "runtime remains" test -d "$base/runtime"
kill "$PROCESS_PID" 2>/dev/null || true
wait "$PROCESS_PID" 2>/dev/null || true
done_case

CASE="Unrelated Wine prefix process does not block removal"
base="$(fixture unrelated-process)"
trash_tool "$base" gio
start_process "$base/foreign/wine" "$base/other-prefix"
run_uninstall "$base" --prefix-only --yes
check "succeeds" test "$RUN_RC" -eq 0
check "selected prefix removed" test ! -e "$base/prefix"
kill "$PROCESS_PID" 2>/dev/null || true
wait "$PROCESS_PID" 2>/dev/null || true
done_case

CASE="Relevant prefix process refuses removal"
base="$(fixture busy-prefix)"
trash_tool "$base" gio
start_process "$base/foreign/wine" "$base/prefix"
run_uninstall "$base" --prefix-only --yes
check "fails" test "$RUN_RC" -ne 0
check "nothing was trashed" test ! -s "$base/trash.log"
check "prefix remains" test -d "$base/prefix"
kill "$PROCESS_PID" 2>/dev/null || true
wait "$PROCESS_PID" 2>/dev/null || true
done_case

for available in all trash-put kde; do
    CASE="Trash selection: $available"
    base="$(fixture "trash-$available")"
    case "$available" in
        all)
            trash_tool "$base" gio
            trash_tool "$base" trash-put
            trash_tool "$base" kioclient
            expected=gio ;;
        trash-put)
            trash_tool "$base" trash-put
            trash_tool "$base" kioclient
            expected=trash-put ;;
        kde)
            trash_tool "$base" kioclient
            expected=kioclient ;;
    esac
    run_uninstall "$base" --prefix-only --yes
    check "succeeds" test "$RUN_RC" -eq 0
    check "selects expected tool" test "$(cut -f1 "$base/trash.log" | head -n 1)" = "$expected"
    check "uses only the selected tool" test "$(wc -l < "$base/trash.log")" -eq 1
    done_case
done

CASE="Detected Trash failure stops without fallback"
base="$(fixture trash-failure)"
trash_tool "$base" gio
trash_tool "$base" trash-put
TEST_FAIL_TOOL=gio
run_uninstall "$base" --keep-prefix --yes
TEST_FAIL_TOOL=
check "fails" test "$RUN_RC" -ne 0
check "failed target remains" test -e "$base/home/.local/bin/ableton-live"
check "later runtime remains" test -d "$base/runtime"
check "prefix remains" test -d "$base/prefix"
check "fallback was not attempted" not_in_log "$base/trash.log" "trash-put"
check "state remains for retry" test -d "$base/xdg/state/ableton-wine"
report_present "$base"
done_case

CASE="Trash success must actually remove the target"
base="$(fixture trash-left-target)"
trash_tool "$base" gio
trash_tool "$base" trash-put
TEST_LEAVE_TOOL=gio
run_uninstall "$base" --prefix-only --yes
TEST_LEAVE_TOOL=
check "fails" test "$RUN_RC" -ne 0
check "prefix remains" test -d "$base/prefix"
check "fallback was not attempted" not_in_log "$base/trash.log" "trash-put"
check "state remains for retry" test -d "$base/xdg/state/ableton-wine"
done_case

CASE="No Trash tool warns before permanent deletion"
base="$(fixture permanent)"
guarded_rm "$base"
run_uninstall "$base" --keep-prefix --yes
check "approved deletion succeeds" test "$RUN_RC" -eq 0
check "runtime removed" test ! -e "$base/runtime"
check "warning says permanent" contains "$base" "permanent"
check "no Trash command ran" test ! -s "$base/trash.log"
done_case

CASE="Permanent deletion can be declined"
base="$(fixture permanent-decline)"
guarded_rm "$base"
run_uninstall "$base" --keep-prefix < /dev/null
check "decline exits without an error" test "$RUN_RC" -eq 0
check "runtime remains" test -d "$base/runtime"
check "warning says permanent" contains "$base" "permanent"
check "runtime was not passed to rm" not_in_log "$base/rm.log" "$base/runtime"
done_case

CASE="Prefix deletion has a separate confirmation"
base="$(fixture prefix-confirm)"
trash_tool "$base" gio
run_uninstall "$base" --prefix-only < /dev/null
check "decline exits without an error" test "$RUN_RC" -eq 0
check "prefix remains" test -d "$base/prefix"
check "a separate prefix question is shown" contains "$base" \
    "QUESTION: Delete the Wine prefix"
check "nothing was trashed" test ! -s "$base/trash.log"
done_case

if [ "$failures" -ne 0 ]; then
    printf 'FAIL: %d failed assertions across %d cases\n' "$failures" "$cases" >&2
    exit 1
fi
printf 'PASS: %d minimal uninstall boundary cases\n' "$cases"
