#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
checker="$here/check-ntsync.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-ntsync-test.XXXXXX")"
pass=0

cleanup()
{
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        [ "$(readlink -- "/proc/$pid/exe" 2>/dev/null || true)" \
            = "$work/runtime/holder/wineserver" ] || continue
        kill "$pid" 2>/dev/null || true
    done < <(pgrep -x wineserver 2>/dev/null || true)
    rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM

ok()
{
    pass=$((pass + 1))
    printf 'ok - %s\n' "$1"
}

fail()
{
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

mkdir -p -- "$work/runtime/bin" "$work/runtime/holder"
cp -- "$(command -v sleep)" "$work/runtime/holder/wineserver"
chmod 755 "$work/runtime/holder/wineserver"

cat > "$work/runtime/bin/wineserver" <<'EOF'
#!/usr/bin/env bash
# The literal keeps the checker's stripped-binary NTSync marker gate honest.
ntsync_marker=ntsync
case "${1:-}" in
    -p)
        if [ "${ABLETON_TEST_HOLD_DEVICE:-1}" = 1 ] \
            && [ -c "${ABLETON_TEST_NTSYNC_DEVICE:-/dev/ntsync}" ]; then
            "$ABLETON_TEST_WINESERVER_HOLDER" 120 \
                9< "${ABLETON_TEST_NTSYNC_DEVICE:-/dev/ntsync}" &
        else
            "$ABLETON_TEST_WINESERVER_HOLDER" 120 &
        fi
        ;;
    -k)
        while IFS= read -r pid; do
            [ -n "$pid" ] && [ "$pid" != "$$" ] || continue
            if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                | grep -qxF "WINEPREFIX=$WINEPREFIX"; then
                kill "$pid" 2>/dev/null || true
            fi
        done < <(pgrep -x wineserver 2>/dev/null || true)
        ;;
    *) exit 2 ;;
esac
: "$ntsync_marker"
EOF

cat > "$work/runtime/bin/wine" <<'EOF'
#!/usr/bin/env bash
printf 'PASS fake-ntsync-semantics\nSUMMARY pass=1 fail=0\n' > ntsyncprobe.txt
exit 0
EOF
chmod 755 "$work/runtime/bin/wineserver" "$work/runtime/bin/wine"
: > "$work/ntsyncprobe.exe"

run_case()
{
    local name="$1" device="$2" require="$3" hold="${4:-1}"
    env ABLETON_NTSYNC_TEST_MODE=1 ABLETON_TEST_NTSYNC_DEVICE="$device" \
        ABLETON_TEST_HOLD_DEVICE="$hold" \
        ABLETON_TEST_WINESERVER_HOLDER="$work/runtime/holder/wineserver" \
        ABLETON_WINE_ROOT="$work/runtime" \
        ABLETON_WINEPREFIX="$work/prefix-$name" \
        ABLETON_NTSYNC_PROBE="$work/ntsyncprobe.exe" \
        ABLETON_REQUIRE_NTSYNC="$require" ABLETON_CHECK_TIMEOUT=5 \
        bash "$checker" >"$work/$name.out" 2>"$work/$name.err"
}

set +e
env ABLETON_REQUIRE_NTSYNC=invalid bash "$checker" \
    >"$work/invalid.out" 2>"$work/invalid.err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid strictness token does not exit 2"
grep -q 'ABLETON_REQUIRE_NTSYNC must be on or off' "$work/invalid.err" \
    || fail "invalid strictness token is not diagnosed"
ok "invalid ABLETON_REQUIRE_NTSYNC fails closed"

set +e
run_case strict-missing "$work/no-such-device" on
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "strict missing-device check does not exit 3"
grep -q 'rerun with ABLETON_REQUIRE_NTSYNC=off' "$work/strict-missing.err" \
    || fail "strict missing-device check omits its explicit fallback guidance"
ok "strict mode rejects an unavailable NTSync device"

run_case fallback "$work/no-such-device" off \
    || fail "explicit fallback semantics run failed"
grep -q 'regular Wine route selected; sync semantics pass' "$work/fallback.out" \
    || fail "fallback success is not labelled inactive"
ok "explicit fallback runs semantics without claiming active NTSync"

set +e
run_case inactive-fd /dev/full on 0
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "active-device proof accepts a wineserver with no device fd"
grep -q 'runtime never opened /dev/full' "$work/inactive-fd.err" \
    || fail "active-device fd failure is not diagnosed"
ok "device presence without a wineserver fd fails proof"

run_case active-fd /dev/full on \
    || fail "active-device proof rejected a matching wineserver fd"
grep -q 'NTSync active; sync semantics pass; wineserver opens /dev/full' "$work/active-fd.out" \
    || fail "active-device success is not reported"
ok "matching wineserver device fd proves the active path"

printf 'PASS: %d NTSync checker policy tests\n' "$pass"
