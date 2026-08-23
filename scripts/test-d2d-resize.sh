#!/usr/bin/env bash
# Assert what an hwnd render target keeps across Resize: patch 0104.
#
#     scripts/test-d2d-resize.sh <runtime-root>
#
# Needs a built runtime and a display. When DISPLAY is unset a throwaway Xvfb is
# started, so this runs on a headless builder.
#
# The prefix is a throwaway under /tmp, seeded with FontSmoothingType=2. At 1 the
# pixel geometry test inside can_draw_cleartype() fails on its own and the
# ClearType control arm reports a failure unrelated to this patch.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
runtime="${1:-}"
probe_src="$root/tools/d2d-resize-probe.c"
xvfb_pid=""

fail()
{
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

# Preconditions are reported, never allowed to abort silently. The runtime is
# never guessed: dist/ holds a tarball rather than an extracted tree, so a search
# reaches the installed runtime and reports failures about the wrong build.
[ -n "$runtime" ] || fail "no runtime given. Extract one and pass its root:
    mkdir -p /tmp/rt && tar --zstd -xf dist/wine-*.tar.zst -C /tmp/rt
    make test-d2d-resize RUNTIME=/tmp/rt/wine-d2d1-nspa-11.13"
[ -x "$runtime/bin/wine" ] || fail "no bin/wine under $runtime"
[ -r "$probe_src" ] || fail "probe source missing at $probe_src"
command -v x86_64-w64-mingw32-gcc >/dev/null \
    || fail "x86_64-w64-mingw32-gcc is missing; install the mingw-w64 cross compiler"
command -v timeout >/dev/null || fail "timeout is missing; install GNU coreutils"

tmp="$(mktemp -d /tmp/ableton-d2d-resize-test.XXXXXX)"
export WINEPREFIX="$tmp/prefix"
export WINEDEBUG=-all
cleanup()
{
    case "$tmp" in
        /tmp/ableton-d2d-resize-test.*)
            if [ -d "$WINEPREFIX" ]; then
                timeout --kill-after=2s 10s "$runtime/bin/wineserver" -k >/dev/null 2>&1 || true
            fi
            if [ -n "$xvfb_pid" ]; then
                kill "$xvfb_pid" 2>/dev/null || true
                wait "$xvfb_pid" 2>/dev/null || true
            fi
            rm -rf -- "${tmp:?}"
            ;;
        *) printf 'refusing to remove unexpected test path: %s\n' "$tmp" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -O1 "$probe_src" -o "$tmp/probe.exe" \
    -ld2d1 -ldwrite -lole32 -lgdi32 -luser32 || fail "probe did not build"

mkdir -p "$WINEPREFIX"
timeout --kill-after=10s 60s "$runtime/bin/wine" wineboot -u >/dev/null 2>&1 \
    || fail "wineboot failed or timed out in the test prefix"
timeout --kill-after=5s 30s "$runtime/bin/wine" reg add 'HKCU\Control Panel\Desktop' \
    /v FontSmoothingType /t REG_DWORD /d 2 /f >/dev/null 2>&1 \
    || fail "could not seed FontSmoothingType before the timeout"
timeout --kill-after=2s 10s "$runtime/bin/wineserver" -k >/dev/null 2>&1 || true

# Initialise the prefix headlessly first. Starting Wine's desktop processes on
# Xvfb during wineboot can keep wineboot alive with the display session. The
# actual D2D probe is the only command that needs the display.
if [ -z "${DISPLAY:-}" ]; then
    command -v Xvfb >/dev/null || fail "no DISPLAY and Xvfb is missing; install xvfb"
    for n in 90 91 92 93 94; do
        if ! [ -e "/tmp/.X11-unix/X$n" ]; then
            Xvfb ":$n" -screen 0 1280x800x24 >/dev/null 2>&1 &
            xvfb_pid=$!
            export DISPLAY=":$n"
            break
        fi
    done
    [ -n "$xvfb_pid" ] || fail "could not find a free display for Xvfb"
    sleep 3
    kill -0 "$xvfb_pid" 2>/dev/null || fail "Xvfb did not start on $DISPLAY"
fi

printf 'runtime: %s\n' "$runtime"
[ -r "$runtime/ABLETON-WINE-BUILD-INFO.txt" ] &&
    grep -E 'dist-version|wine-patches|patch-stack' "$runtime/ABLETON-WINE-BUILD-INFO.txt" || true

out="$tmp/out.txt"
if timeout --kill-after=10s 90s "$runtime/bin/wine" "$tmp/probe.exe" --check >"$out" 2>/dev/null; then
    cat "$out"
    printf 'ok - hwnd render target keeps its pixel format and GDI compatibility across Resize\n'
else
    status=$?
    cat "$out"
    [ "$status" = 2 ] && fail "probe could not run; see the line above"
    [ "$status" = 124 ] && fail "probe timed out after 90 seconds"
    [ "$status" = 137 ] && fail "probe ignored the timeout and was killed"
    fail "hwnd render target regressed across Resize; see the not ok lines above"
fi
