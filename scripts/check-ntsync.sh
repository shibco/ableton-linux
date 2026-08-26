#!/usr/bin/env bash
# Verify Wine support, host device use and wait results with ntsyncprobe.exe.
# Exit 0 records passing assertions for active NTSync or a selected regular route.
# Exit 3 means the host must provide the NTSync device in required mode.
# Close Live first, then use a separate test prefix.
set -uo pipefail

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"
export WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
export WINEDEBUG=-all
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -n "${ABLETON_NTSYNC_PROBE:-}" ]; then
    PROBE="$ABLETON_NTSYNC_PROBE"
elif [ -f "$here/ntsyncprobe.exe" ]; then
    PROBE="$here/ntsyncprobe.exe"
else
    PROBE="$here/../beta/tester-kit/probes/windows/ntsyncprobe.exe"
fi
TIMEOUT="${ABLETON_CHECK_TIMEOUT:-120}"
ntsync_device=/dev/ntsync
if [ -n "${ABLETON_TEST_NTSYNC_DEVICE:-}" ]; then
    if [ "${ABLETON_NTSYNC_TEST_MODE:-}" != 1 ]; then
        echo "!! ABLETON_TEST_NTSYNC_DEVICE is reserved for the hermetic test suite" >&2
        exit 2
    fi
    ntsync_device="$ABLETON_TEST_NTSYNC_DEVICE"
fi
require_ntsync="${ABLETON_REQUIRE_NTSYNC:-on}"
case "${require_ntsync,,}" in
    1|on|true|yes) require_ntsync=1 ;;
    0|off|false|no) require_ntsync=0 ;;
    *)
        echo "!! ABLETON_REQUIRE_NTSYNC must be on or off (got '$require_ntsync')" >&2
        exit 2
        ;;
esac

work=""
server_started=0
cleanup()
{
    local old_status=$?
    if [ "$server_started" -eq 1 ]; then
        "$WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1 || true
    fi
    if [ -n "$work" ] && [ -d "$work" ]; then
        case "$work" in
            /tmp/check-ntsync.*) rm -rf -- "$work" ;;
            *) echo "!! refusing to remove unexpected temporary path: $work" >&2 ;;
        esac
    fi
    return "$old_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

[ -x "$WINE_ROOT/bin/wine" ] || { echo "!! no wine at $WINE_ROOT" >&2; exit 1; }
[ -x "$WINE_ROOT/bin/wineserver" ] || { echo "!! no wineserver at $WINE_ROOT" >&2; exit 1; }
[ -f "$PROBE" ]              || { echo "!! ntsync semantics probe not found at $PROBE" >&2; exit 1; }

for pid in $(pgrep -x wineserver); do
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qxF "WINEPREFIX=$WINEPREFIX"; then
        echo "!! wineserver $pid already serves $WINEPREFIX; close Live or set ABLETON_WINEPREFIX to a clone" >&2
        exit 1
    fi
done

# Static gate on the wineserver half only: /dev/ntsync is its rodata string
# and survives stripping. ntdll's ntsync strings are debug info, so a good
# stripped ntdll has zero; the dynamic check below proves the client half
# (the server only opens the device when a client uses in-process syncs).
srv=$(strings "$WINE_ROOT/bin/wineserver" 2>/dev/null | grep -c ntsync)
ntd=$(strings "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" 2>/dev/null | grep -c ntsync)
echo "== static: wineserver ntsync refs: $srv (ntdll.so: $ntd, informational; 0 on stripped builds)"
if [ "$srv" -eq 0 ]; then
    echo "!! FAIL: ntsync not compiled in (no linux/ntsync.h at build time); every wait is a wineserver round trip" >&2
    exit 1
fi
if [ ! -c "$ntsync_device" ]; then
    echo "!! INACTIVE: no $ntsync_device (kernel < 6.14, or module unloaded; try sudo modprobe ntsync)" >&2
    if [ "$require_ntsync" -eq 1 ]; then
        echo "!! rerun with ABLETON_REQUIRE_NTSYNC=off only when deliberately testing Wine's slower fallback" >&2
        exit 3
    fi
    echo "-- ABLETON_REQUIRE_NTSYNC=off: checking fallback semantics only"
fi

mkdir -p "$WINEPREFIX"
work="$(mktemp -d /tmp/check-ntsync.XXXXXX)"
cd "$work" || exit 1

"$WINE_ROOT/bin/wineserver" -p || { echo "!! could not start wineserver" >&2; exit 1; }
server_started=1
sleep 1
sp=""
for pid in $(pgrep -x wineserver); do
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qxF "WINEPREFIX=$WINEPREFIX"; then sp=$pid; fi
done
[ -n "$sp" ] || { echo "!! lost track of the eval wineserver" >&2; exit 1; }

c0=$(awk '/ctxt/{s+=$2}END{print s}' "/proc/$sp/status")
t0=$(date +%s%N)
timeout "$TIMEOUT" "$WINE_ROOT/bin/wine" "$PROBE"
rc=$?
t1=$(date +%s%N)
c1=$(awk '/ctxt/{s+=$2}END{print s}' "/proc/$sp/status" 2>/dev/null || echo "$c0")
fds=0
for fd_path in "/proc/$sp/fd/"*; do
    [ "$(readlink -- "$fd_path" 2>/dev/null || true)" = "$ntsync_device" ] \
        && fds=$((fds + 1))
done

echo "-- probe results:"
sed 's/^/   /' ntsyncprobe.txt 2>/dev/null || echo "   (no ntsyncprobe.txt written)"
echo "-- probe rc=$rc wall_ms=$(( (t1-t0)/1000000 )) server_ctx_delta=$((c1-c0)) server_dev_ntsync_fds=$fds"

[ "$rc" -eq 0 ] || { echo "!! FAIL: $rc sync semantics assertion(s) failed" >&2; exit 1; }
if [ -c "$ntsync_device" ] && [ "$fds" -eq 0 ]; then
    echo "!! FAIL: runtime never opened $ntsync_device despite the device existing" >&2
    exit 1
fi
if [ "$fds" -gt 0 ]; then
    echo "OK: NTSync active; sync semantics pass; wineserver opens $ntsync_device"
else
    echo "OK: regular Wine route selected; sync semantics pass"
fi
exit 0
