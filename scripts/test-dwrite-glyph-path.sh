#!/usr/bin/env bash
# Assert the DirectWrite glyph path of a built runtime: patches 0100, 0101 and
# 0103.
#
#     scripts/test-dwrite-glyph-path.sh [runtime-root]
#
# runtime-root defaults to the tree an extracted dist tarball leaves behind. It
# must contain bin/wine. Unlike the other suites this one needs a built runtime,
# so it is not part of `make test`; run it after a build, or against any
# extracted runtime.
#
# The prefix is a throwaway created under /tmp and removed on exit. It is seeded
# with FontSmoothingType=2, without which can_draw_cleartype()'s pixel geometry
# test fails on its own and the greyscale checks read as failures for a reason
# unrelated to these patches.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
runtime="${1:-}"
probe_src="$root/tools/dwrite-glyph-path-probe.c"

fail()
{
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

# preconditions are reported, never allowed to abort silently: a set -e exit
# with no output reads as a short passing run.
#
# The runtime is never guessed. dist/ holds a tarball rather than an extracted
# tree, so a search finds the installed runtime instead of the one just built,
# and a run against the wrong build reports failures that say nothing about the
# tree under test.
[ -n "$runtime" ] || fail "no runtime given. Extract one and pass its root:
    mkdir -p /tmp/rt && tar --zstd -xf dist/wine-*.tar.zst -C /tmp/rt
    make test-glyph-path RUNTIME=/tmp/rt/wine-d2d1-nspa-11.13"
[ -x "$runtime/bin/wine" ] || fail "no bin/wine under $runtime"
[ -r "$probe_src" ] || fail "probe source missing at $probe_src"
command -v x86_64-w64-mingw32-gcc >/dev/null \
    || fail "x86_64-w64-mingw32-gcc is missing; install the mingw-w64 cross compiler"

tmp="$(mktemp -d /tmp/ableton-dwrite-glyph-test.XXXXXX)"
cleanup()
{
    case "$tmp" in
        /tmp/ableton-dwrite-glyph-test.*)
            "$runtime/bin/wineserver" -k >/dev/null 2>&1 || true
            rm -rf -- "${tmp:?}"
            ;;
        *) printf 'refusing to remove unexpected test path: %s\n' "$tmp" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

x86_64-w64-mingw32-gcc -Wall -O1 "$probe_src" -o "$tmp/probe.exe" -ldwrite -lole32 \
    || fail "probe did not build"

export WINEPREFIX="$tmp/prefix"
export WINEDEBUG=-all
mkdir -p "$WINEPREFIX"
"$runtime/bin/wine" wineboot -u >/dev/null 2>&1 || fail "wineboot failed in the test prefix"
"$runtime/bin/wine" reg add 'HKCU\Control Panel\Desktop' \
    /v FontSmoothingType /t REG_DWORD /d 2 /f >/dev/null 2>&1 \
    || fail "could not seed FontSmoothingType"
"$runtime/bin/wineserver" -k >/dev/null 2>&1 || true

printf 'runtime: %s\n' "$runtime"
[ -r "$runtime/ABLETON-WINE-BUILD-INFO.txt" ] &&
    grep -E 'dist-version|wine-patches|patch-stack' "$runtime/ABLETON-WINE-BUILD-INFO.txt" || true

out="$tmp/out.txt"
if "$runtime/bin/wine" "$tmp/probe.exe" --check >"$out" 2>/dev/null; then
    cat "$out"
    printf 'ok - dwrite glyph path: form and sub-pixel positioning as expected\n'
else
    status=$?
    cat "$out"
    [ "$status" = 2 ] && fail "probe could not run; see the line above"
    fail "dwrite glyph path regressed; see the not ok lines above"
fi
