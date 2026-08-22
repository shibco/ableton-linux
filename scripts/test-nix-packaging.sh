#!/usr/bin/env bash
# Covers the shell the Nix packaging added and nothing else tests: the runtime
# indirection link, the pre-marker prefix evidence a packaged install leaves
# inside the prefix rather than under $HOME, setup-prefix.sh's Live installer
# selection, and the audit's rpath rule. Pure functions and fixtures only: no
# wine, no nix, no
# network, no prefix. What a real `nix build` proves is not repeated here.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/nix-packaging-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

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
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

# Two of the functions under test live in scripts that run work on import, so
# they are lifted out by name instead of sourced. An extraction that stops
# matching the source is a test failure, not a silent skip.
lift()   # <file> <function name>
{
    local body
    body="$(sed -n "/^$2() {/,/^}/p" "$1")"
    [ -n "$body" ] || fail "cannot lift $2() out of $1 — has its definition changed shape?"
    printf '%s\n' "$body"
}

# --- runtime-link.sh: the stable name user configuration records -------------
. "$here/runtime-link.sh"
declare -F ableton_runtime_link >/dev/null || fail "runtime-link.sh defines no ableton_runtime_link"

export ABLETON_DATA_HOME="$work/data"
link="$ABLETON_DATA_HOME/runtime"
runtime_a="$work/runtime-a"
runtime_b="$work/runtime-b"
mkdir -p "$runtime_a" "$runtime_b"

check "a missing root is refused" \
    "$(ableton_runtime_link "$work/absent" 2>/dev/null || echo REFUSED)" REFUSED
check "an empty root is refused" \
    "$(ableton_runtime_link "" 2>/dev/null || echo REFUSED)" REFUSED

# The launcher writes what this prints into .desktop files, so it must be the
# stable name and never the runtime it resolves to.
check "first call prints the link, not the runtime" \
    "$(ableton_runtime_link "$runtime_a")" "$link"
check "first call points the link at the runtime" "$(readlink "$link")" "$runtime_a"

check "an already-current link is reported unchanged" \
    "$(ableton_runtime_link "$runtime_a")" "$link"
check "an already-current link still resolves" "$(readlink "$link")" "$runtime_a"

check "an upgrade re-points the link without a setup step" \
    "$(ableton_runtime_link "$runtime_b")" "$link"
check "the re-pointed link names the new runtime" "$(readlink "$link")" "$runtime_b"

# Whatever holds the name must be a link this project maintains.
rm -f "$link"
printf 'someone else owns this name\n' > "$link"
check "a real file at the link name is refused" \
    "$(ableton_runtime_link "$runtime_a" 2>/dev/null || echo REFUSED)" REFUSED
check "the refused file is left untouched" "$(cat "$link")" "someone else owns this name"
rm -f "$link"

mkdir -p "$link"
check "a directory at the link name is refused" \
    "$(ableton_runtime_link "$runtime_a" 2>/dev/null || echo REFUSED)" REFUSED
rmdir "$link"

# Two runtimes can launch at once, so the swap is a rename and never an
# unlink-then-link: no reader window, and no temp name left behind.
ableton_runtime_link "$runtime_a" >/dev/null
ableton_runtime_link "$runtime_b" >/dev/null
check "the swap leaves no temporary link behind" \
    "$(find "$ABLETON_DATA_HOME" -maxdepth 1 -name 'runtime.tmp.*' | wc -l)" 0

# --- config.sh: recognising a prefix set up before the marker existed --------
. "$here/lib/config.sh"
declare -F ableton_legacy_nix_evidence >/dev/null \
    || fail "config.sh defines no ableton_legacy_nix_evidence"

PIPEASIO_CLSID='2D3CA9E2-1193-4C5D-B5FD-38798F3DC074'

make_prefix()   # <prefix> <with-clsid 0|1>
{
    local prefix="$1" with_clsid="$2" registry
    mkdir -p "$prefix/drive_c/windows/system32"
    for registry in system.reg user.reg userdef.reg; do
        printf 'WINE REGISTRY Version 2\n' > "$prefix/$registry"
    done
    [ "$with_clsid" -eq 0 ] || printf '[Software\\\\Classes\\\\CLSID\\\\{%s}]\n' \
        "$PIPEASIO_CLSID" >> "$prefix/system.reg"
}

make_tarball_footprint()   # <home>
{
    mkdir -p "$1/.local/share/ableton-wine" "$1/.local/bin"
    printf '2026.08.19.1\n' > "$1/.local/share/ableton-wine/VERSION"
    printf '# Ableton Live launcher for the patched Wine stack\n' > "$1/.local/bin/ableton-live"
}

evidence_home="$work/home-nix"
mkdir -p "$evidence_home"
HOME="$evidence_home" make_prefix "$evidence_home/.wine-ableton" 1
check "a prefix carrying the PipeASIO CLSID is recognised" \
    "$(ableton_legacy_nix_evidence "$evidence_home/.wine-ableton" && echo YES || echo NO)" YES

# A nix install stages no VERSION and no launcher under $HOME, so the tarball
# evidence cannot see it; the registration inside the prefix is what does.
check "a packaged prefix with no \$HOME footprint is adoptable" \
    "$(HOME="$evidence_home" ableton_legacy_default_prefix_valid \
        "$evidence_home/.wine-ableton" && echo YES || echo NO)" YES

bare_home="$work/home-bare"
mkdir -p "$bare_home"
make_prefix "$bare_home/.wine-ableton" 0
check "a prefix with neither footprint nor CLSID stays refused" \
    "$(HOME="$bare_home" ableton_legacy_default_prefix_valid \
        "$bare_home/.wine-ableton" && echo YES || echo NO)" NO

tarball_home="$work/home-tarball"
mkdir -p "$tarball_home"
make_prefix "$tarball_home/.wine-ableton" 0
make_tarball_footprint "$tarball_home"
check "the tarball footprint still adopts without a CLSID" \
    "$(HOME="$tarball_home" ableton_legacy_default_prefix_valid \
        "$tarball_home/.wine-ableton" && echo YES || echo NO)" YES

# A registry that is a symlink is not evidence: the file it names is outside
# the prefix this project is being asked to take ownership of.
link_home="$work/home-link"
mkdir -p "$link_home"
make_prefix "$link_home/.wine-ableton" 1
mv "$link_home/.wine-ableton/system.reg" "$link_home/elsewhere.reg"
ln -s "$link_home/elsewhere.reg" "$link_home/.wine-ableton/system.reg"
check "a symlinked system.reg is not evidence" \
    "$(ableton_legacy_nix_evidence "$link_home/.wine-ableton" && echo YES || echo NO)" NO

# Adoption writes this marker. Once one exists the legacy path must stand down
# — an invalid marker is a state for the marker check to report, not for the
# legacy recogniser to route around.
marked_home="$work/home-marked"
mkdir -p "$marked_home"
make_prefix "$marked_home/.wine-ableton" 1
printf 'format=1\nprefix=%s\n' "$marked_home/.wine-ableton" \
    > "$marked_home/.wine-ableton/.ableton-linux-prefix"
check "a prefix that already carries a marker is not re-adopted" \
    "$(HOME="$marked_home" ableton_legacy_default_prefix_valid \
        "$marked_home/.wine-ableton" && echo YES || echo NO)" NO

# --- setup-prefix.sh: choosing the Live installer ---------------------------
eval "$(lift "$here/setup-prefix.sh" newest_live_zip)"
declare -F newest_live_zip >/dev/null || fail "newest_live_zip did not survive extraction"

zips="$work/zips"
mkdir -p "$zips"
touch "$zips/ableton_live_trial_11.3.35_64.zip" \
      "$zips/ableton_live_suite_12.4.3_64.zip" \
      "$zips/ableton_live_suite_12.10.0_64.zip"

# The edition sorts before the version in these names, so a plain sort -V ranks
# "suite" over "trial" and 12.4.3 over 12.10.0. Both must key on the version.
check "the newest version wins over the edition name" \
    "$(basename "$(newest_live_zip "$zips" 'ableton_live*.zip')")" \
    ableton_live_suite_12.10.0_64.zip
check "12.10.0 outranks 12.4.3" \
    "$(basename "$(newest_live_zip "$zips" 'ableton_live*_12.*.zip')")" \
    ableton_live_suite_12.10.0_64.zip
check "a major pin selects only that major" \
    "$(basename "$(newest_live_zip "$zips" 'ableton_live*_11.*.zip')")" \
    ableton_live_trial_11.3.35_64.zip
check "no candidate is an empty answer" \
    "$(newest_live_zip "$zips" 'ableton_live*_13.*.zip')" ""

# A directory whose name matches is not an installer.
mkdir -p "$zips/ableton_live_suite_99.0.0_64.zip"
check "a directory matching the glob is not selected" \
    "$(basename "$(newest_live_zip "$zips" 'ableton_live*.zip')")" \
    ableton_live_suite_12.10.0_64.zip
rmdir "$zips/ableton_live_suite_99.0.0_64.zip"

# A search directory find cannot read must answer "no candidate", not abort the
# caller: under set -e and pipefail a find that exits 1 would end the whole
# prefix setup with no message at all. Provoked with a path that is not there
# rather than a chmod 000 one, because root bypasses the mode bits: under a
# root CI container the permission version passes whether or not the guard is
# present, which is a green test covering nothing. Both produce the same find
# exit 1 that the guard exists to absorb.
unreadable_rc=0
unreadable_answer="$(newest_live_zip "$work/not-there" 'ableton_live*.zip')" || unreadable_rc=$?
check "a search directory find cannot read answers empty" "$unreadable_answer" ""
check "a search directory find cannot read does not fail the caller" "$unreadable_rc" 0

# --- build-audit.sh: the rpath rule -----------------------------------------
# A build-container rpath resolves on no user's machine; a store-only one is
# the nix package pinning its closure. Driven through a stub readelf, so the
# verdict is a function of the recorded rpath alone -- no compiler, no ELF
# fixtures, same answer on every host.
rpath_verdict()   # <file> <RPATH/RUNPATH line readelf prints> [readelf exit]
(
    fixture="$2" rc="${3:-0}"
    ok()      { printf 'PASS|%s\n' "$2"; }
    bad()     { printf 'FAIL|%s\n' "$2"; }
    readelf() { printf '%s\n' "$fixture"; return "$rc"; }
    eval "$(lift "$here/build-audit.sh" rpath_check)"
    rpath_check label "$1" none
)
elf="$work/binary"; : > "$elf"
# An absent binary and a clean one both leave the rpath empty, and only one of
# them is a pass. Reported, never waved through and never an aborted audit.
check "a missing binary is a failure, not an absent rpath" \
    "$(rpath_verdict "$work/gone" '')" "FAIL|missing: $work/gone"
check "a build-container rpath is refused" \
    "$(rpath_verdict "$elf" ' 0x1d (RUNPATH)  Library runpath: [/build/stage/lib]')" \
    'FAIL|carries a build-container rpath: /build/stage/lib'
check "a store-only rpath is the nix package's pin" \
    "$(rpath_verdict "$elf" ' 0x1d (RUNPATH)  Library runpath: [/nix/store/aaa/lib]')" \
    'PASS|nix store pin (/nix/store/aaa/lib)'
# readelf exits 1 on a file that exists but is not an ELF; pipefail turns that
# into a failed assignment and set -e would end the audit with no summary line.
# errexit is not in force inside a command substitution, so rpath_verdict above
# could never show this -- provoke it in a script that calls the function the
# way build-audit.sh does, at top level with its status untested.
cat > "$work/abort-probe.sh" <<PROBE
set -euo pipefail
ok()  { :; }
bad() { :; }
readelf() { printf '\n'; return 1; }
$(lift "$here/build-audit.sh" rpath_check)
rpath_check label "$elf" none
echo SURVIVED
PROBE
check "a binary readelf cannot parse does not abort the audit" \
    "$(bash "$work/abort-probe.sh" 2>/dev/null)" SURVIVED

printf 'PASS: %d nix packaging checks\n' "$pass"
