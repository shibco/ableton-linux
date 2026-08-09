#!/usr/bin/env bash
# Regression tests for the Max for Live font fallback fix:
#   scripts/check-m4l-fonts.sh
#
# Guards that the vendored Bitstream Vera faces are present and licensed, that
# setup-prefix.sh and make-installer.sh still install and ship them, and that
# MaxPlug.dll still terminates its font fallback chain at those families - the
# assumption the whole fix rests on. See
# notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md.
#
# Offline checks run anywhere, CI included; prefix checks are skipped rather
# than failed when no prefix is available. Exit 0 all passed, 1 a check failed.

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FONTDIR="$ROOT/vendor/fonts/bitstream-vera"

# The three families MaxPlug falls back to. Hardcoded in MaxPlug.dll; these
# exact names are the whole point of the fix, so they are asserted, not derived.
FALLBACKS=("Bitstream Vera Sans" "Bitstream Vera Serif" "Bitstream Vera Sans Mono")

VERA_FILES=(Vera.ttf VeraBd.ttf VeraIt.ttf VeraBI.ttf VeraMono.ttf VeraMoBd.ttf
            VeraMoIt.ttf VeraMoBI.ttf VeraSe.ttf VeraSeBd.ttf)

pass=0 fail=0 skip=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }
skipt(){ printf '  skip  %s (%s)\n' "$1" "$2"; skip=$((skip+1)); }

echo "== offline checks =="

# 1. The fonts are vendored, so a prefix never depends on a host package -
#    depending on one reproduces this very bug for anyone who lacks it.
missing=()
for f in "${VERA_FILES[@]}"; do
    [ -s "$FONTDIR/$f" ] || missing+=("$f")
done
if [ ${#missing[@]} -eq 0 ]; then
    ok "all ${#VERA_FILES[@]} Vera faces vendored"
else
    bad "vendored faces missing: ${missing[*]}"
fi

# 2. Manifest integrity - make-installer.sh verifies this too, so a silent
#    corruption would otherwise only surface at release time.
if [ -f "$ROOT/vendor/bitstream-vera.sha256" ]; then
    if ( cd "$ROOT/vendor" && sha256sum -c --quiet bitstream-vera.sha256 ) 2>/dev/null; then
        ok "vendor/bitstream-vera.sha256 verifies"
    else
        bad "vendor/bitstream-vera.sha256 does NOT verify"
    fi
else
    bad "vendor/bitstream-vera.sha256 is missing"
fi

# 3. The Bitstream license permits redistribution only if the notices travel
#    with the files, so shipping the fonts without this would be a violation.
#    Whitespace-normalised before matching: upstream wraps the trademark notice
#    across two lines, which a line-based grep misses.
if [ -s "$FONTDIR/COPYRIGHT.TXT" ] &&
   tr -s '[:space:]' ' ' < "$FONTDIR/COPYRIGHT.TXT" |
   grep -q "Bitstream Vera is a trademark of Bitstream, Inc."; then
    ok "license notice present alongside the fonts"
else
    bad "COPYRIGHT.TXT missing or not the Bitstream license"
fi

# 4. The files must really BE the Bitstream Vera families. Wine reads the family
#    name from inside the file, so substituting DejaVu here - which looks like a
#    tempting dependency-free shortcut - silently breaks the fix.
if command -v fc-scan >/dev/null 2>&1; then
    fams="$(fc-scan --format '%{family}\n' "$FONTDIR"/*.ttf 2>/dev/null | tr ',' '\n' | sort -u)"
    absent=()
    # Herestring, not a pipe: under `pipefail`, `... | grep -q` exits 141 because
    # grep -q closes the pipe on first match and the writer takes SIGPIPE, so a
    # successful match reads as a failed pipeline.
    for want in "${FALLBACKS[@]}"; do
        grep -qxF "$want" <<<"$fams" || absent+=("$want")
    done
    if [ ${#absent[@]} -eq 0 ]; then
        ok "vendored files report all three fallback family names"
    else
        bad "vendored files do not provide: ${absent[*]}"
    fi
else
    skipt "vendored font family names" "fc-scan not installed"
fi

# 5. The kit must actually ship them. make-installer.sh copies only *named*
#    vendor items, so vendor/fonts/ was dropped from the .run until wired in -
#    the failure would be invisible until a user hit the hang.
MI="$ROOT/scripts/make-installer.sh"
if grep -q 'vendor/fonts/bitstream-vera' "$MI" && grep -q 'bitstream-vera-COPYRIGHT' "$MI"; then
    ok "make-installer.sh stages the fonts and the license"
else
    bad "make-installer.sh does not stage vendor/fonts/bitstream-vera + license"
fi

# 6. setup-prefix.sh must both copy AND register. Copying alone leaves the files
#    invisible: Wine's font list is registry-driven and ignores late arrivals.
SP="$ROOT/scripts/setup-prefix.sh"
if grep -q 'install_maxplug_fallback_fonts' "$SP" \
   && grep -qF 'CurrentVersion\Fonts' "$SP"; then
    ok "setup-prefix.sh installs and registers the fallback fonts"
else
    bad "setup-prefix.sh does not install+register the fallback fonts"
fi

echo "== MaxPlug assumption check =="

# 7. The fix is only correct while MaxPlug's chain still ends at these names. A
#    Max update could change them, silently un-fixing every device. Assert the
#    strings are still in the binary when one is available to inspect.
MAXPLUG="$(ls -1 "$(ableton_wine_prefix)"/drive_c/ProgramData/Ableton/*/Resources/Max/resources/support/MaxPlug.dll 2>/dev/null | head -1 || true)"
if [ -n "$MAXPLUG" ] && [ -r "$MAXPLUG" ] && command -v strings >/dev/null 2>&1; then
    # One pass over a 31 MB binary, and deliberately not `| grep -q`: that exits
    # 141 under pipefail (grep closes the pipe, strings takes SIGPIPE), which
    # reads as "string absent" when it is in fact present.
    mp_hits="$(strings -a "$MAXPLUG" 2>/dev/null | grep -F 'Bitstream Vera' || true)"
    absent=()
    for want in "${FALLBACKS[@]}"; do
        grep -qF "$want" <<<"$mp_hits" || absent+=("$want")
    done
    if [ ${#absent[@]} -eq 0 ]; then
        ok "MaxPlug.dll still references all three fallback families"
    else
        bad "MaxPlug.dll no longer references: ${absent[*]} - the fallback chain may have changed, re-verify the fix"
    fi
else
    skipt "MaxPlug.dll fallback strings" "no readable MaxPlug.dll found"
fi

echo "== prefix checks =="

# Runtime and prefix paths resolve in one place; see scripts/runtime-env.sh.
for _l in "$(dirname "$0")/runtime-env.sh" "$HOME/.local/share/ableton-wine/runtime-env.sh"; do
    [ -r "$_l" ] && . "$_l" && break
done
command -v ableton_wine_root >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found next to $0 or in ~/.local/share/ableton-wine" >&2; exit 1; }
PREFIX="$(ableton_wine_prefix)"
WINE_ROOT="$(ableton_wine_root)"
WINE="$WINE_ROOT/bin/wine"
[ -x "$WINE" ] || WINE="$(command -v wine 2>/dev/null || true)"
PROBE="$ROOT/tools/fontprobe.exe"

if [ ! -d "$PREFIX" ]; then
    skipt "prefix font resolution" "no prefix at $PREFIX"
elif [ -z "$WINE" ]; then
    skipt "prefix font resolution" "no wine binary"
else
    # 8. Every face registered? Files present but unregistered is the exact
    #    half-applied state that still hangs.
    reg="$(WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" reg query \
           'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' 2>/dev/null \
           | grep -ci 'Bitstream Vera' || true)"
    if [ "${reg:-0}" -ge "${#VERA_FILES[@]}" ]; then
        ok "all ${#VERA_FILES[@]} faces registered in the prefix ($reg entries)"
    else
        bad "only ${reg:-0}/${#VERA_FILES[@]} Vera faces registered - run scripts/setup-prefix.sh"
    fi

    # Wine's font list is built once per wineserver session and then held in
    # memory (plus a Software\Wine\Fonts\External Fonts cache), so while Live is
    # up the probe reports the list as of that session's start. Removing the
    # files or their registration mid-session does NOT show up. Say so, rather
    # than let a stale pass look like a fresh one.
    if pgrep -x wineserver >/dev/null 2>&1; then
        printf '  note  wineserver is running; the probe below reflects the font\n'
        printf '        list from when it started, not the current on-disk state.\n'
        printf '        Close Live and re-run for an authoritative answer.\n'
    fi

    # 9. The invariant that actually matters: can Max's chain land? Asked through
    #    the same EnumFontFamiliesEx Max uses, because inferring this from
    #    fc-list cannot see registration state and has given wrong answers.
    if [ ! -x "$PROBE" ] && [ ! -f "$PROBE" ]; then
        skipt "fallback chain resolves (authoritative)" \
              "build it: x86_64-w64-mingw32-gcc -O2 -o tools/fontprobe.exe tools/fontprobe.c -lgdi32"
    else
        if WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE" "$PROBE" \
             "${FALLBACKS[@]}" >/dev/null 2>&1; then
            ok "MaxPlug fallback chain resolves in the prefix (fontprobe)"
        else
            bad "fallback chain does NOT resolve - M4L devices requesting a missing font WILL hang Live"
        fi
    fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
