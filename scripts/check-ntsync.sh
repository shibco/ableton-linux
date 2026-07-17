#!/usr/bin/env bash
# Check that a runtime has ntsync compiled in and actually uses it, and that
# NT sync semantics hold, by running ntsyncprobe.exe against a prefix.
# Exit 0 = compiled in, active (when /dev/ntsync exists), all assertions pass.
# Refuses a prefix that already has a wineserver. Never point it at the live
# prefix while Live is running.
set -uo pipefail

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.11}"
export WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
export WINEDEBUG=-all
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROBE="${ABLETON_NTSYNC_PROBE:-$here/../beta/tester-kit/probes/windows/ntsyncprobe.exe}"
TIMEOUT="${ABLETON_CHECK_TIMEOUT:-120}"

[ -x "$WINE_ROOT/bin/wine" ] || { echo "!! no wine at $WINE_ROOT" >&2; exit 1; }
[ -f "$PROBE" ]              || { echo "!! probe not found at $PROBE (run beta/tester-kit/probes/build-maintainer-probes.sh)" >&2; exit 1; }

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
# See notes/ABLETON-WINE-NTSYNC-REGRESSION.md.
srv=$(strings "$WINE_ROOT/bin/wineserver" 2>/dev/null | grep -c ntsync)
ntd=$(strings "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" 2>/dev/null | grep -c ntsync)
echo "== static: wineserver ntsync refs: $srv (ntdll.so: $ntd, informational; 0 on stripped builds)"
if [ "$srv" -eq 0 ]; then
    echo "!! FAIL: ntsync not compiled in (no linux/ntsync.h at build time); every wait is a wineserver round trip" >&2
    exit 1
fi
[ -c /dev/ntsync ] || echo "-- note: no /dev/ntsync (kernel < 6.14?); checking fallback semantics only"

mkdir -p "$WINEPREFIX"
work="$(mktemp -d /tmp/check-ntsync.XXXXXX)"
cd "$work" || exit 1

"$WINE_ROOT/bin/wineserver" -p || { echo "!! could not start wineserver" >&2; exit 1; }
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
fds=$(ls -l "/proc/$sp/fd" 2>/dev/null | grep -c '/dev/ntsync')

echo "-- probe results:"
sed 's/^/   /' ntsyncprobe.txt 2>/dev/null || echo "   (no ntsyncprobe.txt written)"
echo "-- probe rc=$rc wall_ms=$(( (t1-t0)/1000000 )) server_ctx_delta=$((c1-c0)) server_dev_ntsync_fds=$fds"

"$WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1
cd / && rm -rf "$work"

[ "$rc" -eq 0 ] || { echo "!! FAIL: $rc sync semantics assertion(s) failed" >&2; exit 1; }
if [ -c /dev/ntsync ] && [ "$fds" -eq 0 ]; then
    echo "!! FAIL: runtime never opened /dev/ntsync despite the device existing" >&2
    exit 1
fi
if [ "$fds" -gt 0 ]; then
    echo "OK: sync semantics hold, ntsync active (server holds /dev/ntsync)"
else
    echo "OK: sync semantics hold (fallback path, no /dev/ntsync)"
fi
exit 0
