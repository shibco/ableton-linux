#!/usr/bin/env bash
# Audit a runtime artifact against the frozen patch stack (patches/SERIES.sha256): patch file hashes,
# build stamp, per-patch binary fingerprints. Arg: tarball, tree, or --freeze; defaults to newest dist/*.tar.zst.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
NAME="wine-d2d1-nspa-11.11"
SERIES="$root/patches/SERIES.sha256"

say()  { printf '%s\n' "$*"; }
fail() { printf '!! %s\n' "$*" >&2; exit 1; }

# --- --freeze: (re)generate the frozen series manifest ------------------------
if [ "${1:-}" = --freeze ]; then
    new="$(cd "$root/patches" && sha256sum 00*.patch wineasio/*.patch)"
    if [ -f "$SERIES" ]; then
        say "== freeze diff (old -> new) =="
        diff -u "$SERIES" <(printf '%s\n' "$new") && say "   (no changes)"
    else
        say "== creating $SERIES =="
    fi
    printf '%s\n' "$new" > "$SERIES"
    say "OK: $(grep -c . "$SERIES") patches frozen. Commit patches/SERIES.sha256."
    exit 0
fi

[ -f "$SERIES" ] || fail "patches/SERIES.sha256 missing — run: ./scripts/build-audit.sh --freeze (then commit it)"
grep -qP 'x' <<<'x' 2>/dev/null || fail "grep -P not supported on this system (needed for UTF-16 fingerprints)"

# --- resolve the artifact: tarball (unpack to tmp) or tree --------------------
target="${1:-}"
if [ -z "$target" ]; then
    target="$(ls "$root"/dist/${NAME}-*.tar.zst 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$target" ] || fail "no ${NAME}-*.tar.zst in dist/ and no argument given"
fi
cleanup_dir=""
trap '[ -n "$cleanup_dir" ] && rm -rf "$cleanup_dir"' EXIT
case "$target" in
    *.tar.zst)
        [ -f "$target" ] || fail "no such tarball: $target"
        say "== unpacking $(basename "$target") for audit =="
        cleanup_dir="$(mktemp -d "${TMPDIR:-/tmp}/build-audit.XXXXXX")"
        tar -C "$cleanup_dir" -I zstd -xf "$target"
        tree="$cleanup_dir/$NAME"
        ;;
    *)  tree="${target%/}" ;;
esac
[ -d "$tree/lib/wine" ] || fail "$tree does not look like a $NAME tree (no lib/wine)"
say "== auditing tree: $tree =="

pass=0; failed=0
ok()  { pass=$((pass+1));   printf '   %-42s PASS %s\n' "$1" "$2"; }
bad() { failed=$((failed+1)); printf '   %-42s FAIL %s\n' "$1" "$2"; }

# --- [1/4] frozen series vs patches/ on disk ----------------------------------
say "== [1/4] patch series vs frozen manifest =="
declare -A sha_ok
n_series="$(grep -c . "$SERIES")"
while read -r sum file; do
    [ -n "$file" ] || continue
    if ( cd "$root/patches" && printf '%s  %s\n' "$sum" "$file" | sha256sum -c --quiet - ) 2>/dev/null; then
        sha_ok["$file"]=1
    else
        sha_ok["$file"]=0
    fi
done < "$SERIES"
extras="$(cd "$root/patches" && ls 00*.patch wineasio/*.patch 2>/dev/null | grep -vxF -f <(awk '{print $2}' "$SERIES") || true)"
[ -z "$extras" ] && ok "no unlisted patches" "" || bad "unlisted patches present" "$extras"
# Retired numbers stay retired (renumbering would break cross-references in patch
# titles and notes/); a gap is fine if documented here, a dropped patch is not.
declare -A SERIES_GAPS=(
    [0027]="retired 2026-07-14 — gitignore housekeeping, no artifact effect"
)
seq_expect=1
for f in $(awk '{print $2}' "$SERIES" | grep -v '^wineasio/' | sort); do
    num="${f%%-*}"
    printf -v want '%04d' "$seq_expect"
    while [ "$num" != "$want" ] && [ -n "${SERIES_GAPS[$want]:-}" ]; do
        ok "series numbering" "$want gap documented (${SERIES_GAPS[$want]})"
        seq_expect=$((seq_expect+1))
        printf -v want '%04d' "$seq_expect"
    done
    [ "$num" = "$want" ] || bad "series numbering" "expected $want, found $num"
    seq_expect=$((seq_expect+1))
done
n_wine="$(awk '{print $2}' "$SERIES" | grep -vc '^wineasio/' || true)"
n_asio="$(awk '{print $2}' "$SERIES" | grep -c '^wineasio/' || true)"
say "   series: $n_wine wine patches (0001..$(printf '%04d' "$((seq_expect-1))"), documented gaps ok) + $n_asio wineasio patch(es)"

# --- [2/4] artifact provenance stamp ------------------------------------------
say "== [2/4] artifact provenance (patch stack stamped at build time) =="
stamp="$tree/ABLETON-WINE-PATCH-STACK.txt"
stamp_ok=0
if [ ! -f "$stamp" ]; then
    bad "ABLETON-WINE-PATCH-STACK.txt" "missing — artifact predates stack stamping; rebuild with ./build.sh"
elif diff -q "$stamp" "$SERIES" >/dev/null 2>&1; then
    stamp_ok=1
    ok "stack stamp == frozen series" "($n_series patches)"
else
    bad "stack stamp != frozen series" "artifact was built from a different patch stack:"
    diff -u "$SERIES" "$stamp" | sed 's/^/        /' || true
fi
binfo="$tree/ABLETON-WINE-BUILD-INFO.txt"
if [ -f "$binfo" ] && grep -q "^patches: *$n_series$" "$binfo"; then
    ok "BUILD-INFO patch count" "($n_series)"
else
    bad "BUILD-INFO patch count" "missing or != $n_series (see $binfo)"
fi

# --- [3/4] per-patch verification ----------------------------------------------
# FINGERPRINTS: patch|encoding(ascii|wide=UTF-16LE)|module|pattern. STAMP_ONLY: patch|reason.
FINGERPRINTS='
0001|ascii|lib/wine/x86_64-windows/wined3d.dll|WINED3D_DCOMP_FORCE_FULL_REDRAW
0003|ascii|lib/wine/x86_64-unix/winex11.so|_NET_FRAME_EXTENTS
0016|wide|lib/wine/x86_64-windows/dcomp.dll|__wine_dcomp_origproc
0022|wide|lib/wine/x86_64-windows/dxgi.dll|__wine_dcomp_last_present
0025|wide|lib/wine/x86_64-windows/dxgi.dll|__wine_dcomp_idle_ticks
0031|ascii|lib/wine/x86_64-unix/comdlg32.so|org.freedesktop.portal.FileChooser
0031|wide|lib/wine/x86_64-windows/comdlg32.dll|FileDialogPortal
0032|ascii|lib/wine/x86_64-windows/libusb-1.0.dll|libusb_submit_transfer
0033|ascii|lib/wine/x86_64-unix/ntdll.so|WINE_DISABLE_UNIX_MOUNT_REPARSE
wineasio/0001|ascii|lib/wine/x86_64-unix/wineasio64.dll.so|wineasio-clamp-sample-rate
'
# wineasio's code is in the unix .so; the PE wineasio64.dll is a codeless fake module.
STAMP_ONLY='
0002|logic-only (visible-rect gates; adds no string literal)
0004|logic-only (reentrant wpchanged state)
0005|logic-only (NC frame allowance)
0006|logic-only (frame-extents reconstruction disable)
0007|logic-only (monitor size clamp)
0008|experiment later reverted by 0009 — net effect intentionally void
0009|revert of 0008
0010|experiment later reverted by 0013 — net effect intentionally void
0011|experiment later reverted by 0012 — net effect intentionally void
0012|revert of 0011
0013|revert of 0010
0014|logic-only (captioned tool-window decoration)
0015|logic-only (layered-attr sync)
0017|logic-only (real activation timestamps)
0018|logic-only (pre-dirty shared session pages)
0019|logic-only (MAP_SHARED session views)
0020|literal EGL_KHR_gl_colorspace pre-exists in base — not distinctive
0021|logic-only (FriendlyName re-wrap guard; literals are comments)
0023|logic-only (client rects in present thread)
0024|logic-only (diagnostics severity change)
0026|logic-only (DC drawable visual; literals not compiled in)
0028|logic-only (MIDI announce-port re-subscribe)
0029|logic-only (menu bar +4px arithmetic)
0030|literal __wine_dcomp_swapchain pre-exists in base — not distinctive
0034|logic-only (XdndStatus reply flush; adds no string literal)
'
wide_pattern() {  # ascii string -> PCRE matching its UTF-16LE bytes
    printf '%s' "$1" | od -An -v -tx1 | tr -d '\n' | tr -s ' ' ' ' \
        | sed -e 's/^ //' -e 's/ $//' -e 's/ /\\x00\\x/g' -e 's/^/\\x/' -e 's/$/\\x00/'
}
say "== [3/4] per-patch verification ($n_series patches) =="
for f in $(awk '{print $2}' "$SERIES" | sort); do
    num="${f%%-*}"
    integrity="sha✓"
    [ "${sha_ok[$f]:-0}" = 1 ] || integrity="sha✗"
    stamp_note="stamp✓"
    [ "$stamp_ok" = 1 ] || stamp_note="stamp✗"
    fps="$(printf '%s\n' "$FINGERPRINTS" | grep "^$num|" || true)"
    if [ -n "$fps" ]; then
        fp_fail=""
        fp_desc=""
        while IFS='|' read -r _ enc module pattern; do
            [ -n "$module" ] || continue
            file="$tree/$module"
            found=0
            if [ -f "$file" ]; then
                case "$enc" in
                    ascii) grep -qaF "$pattern" "$file" && found=1 ;;
                    wide)  grep -qaP "$(wide_pattern "$pattern")" "$file" && found=1 ;;
                esac
            fi
            if [ "$found" = 1 ]; then
                fp_desc="$fp_desc${fp_desc:+; }$(basename "$module") has \"$pattern\""
            else
                fp_fail="$fp_fail${fp_fail:+; }$(basename "$module") MISSING \"$pattern\""
            fi
        done <<< "$fps"
        if [ -n "$fp_fail" ] || [ "$integrity" != "sha✓" ] || [ "$stamp_ok" != 1 ]; then
            bad "$f" "$integrity $stamp_note ${fp_fail:-fingerprint ok}"
        else
            ok "$f" "$integrity $stamp_note $fp_desc"
        fi
    else
        reason="$(printf '%s\n' "$STAMP_ONLY" | grep "^$num|" | cut -d'|' -f2-)"
        [ -n "$reason" ] || reason="UNLISTED — add to FINGERPRINTS or STAMP_ONLY in build-audit.sh"
        if [ "${sha_ok[$f]:-0}" = 1 ] && [ "$stamp_ok" = 1 ] && [ -n "${reason%%UNLISTED*}" ]; then
            ok "$f" "$integrity $stamp_note via stack stamp ($reason)"
        else
            bad "$f" "$integrity $stamp_note ($reason)"
        fi
    fi
done

# --- [4/4] structural invariants of the packaged tree --------------------------
say "== [4/4] structural invariants =="
must() { [ -s "$tree/$1" ] && ok "$1" "present" || bad "$1" "missing/empty"; }
must bin/wine
must bin/wineserver
must lib/wine/x86_64-unix/winealsa.so
must lib/wine/x86_64-unix/comdlg32.so
must lib/wine/x86_64-windows/wineasio64.dll
must lib/wine/x86_64-unix/wineasio64.dll.so
must lib/wine/x86_64-windows/wineasio.dll
must lib/wine/x86_64-unix/wineasio.dll.so
must lib/wine/x86_64-windows/libusb-1.0.dll
must lib/wine/x86_64-unix/libusb-1.0.so
for absent in lib/wine/i386-windows/libusb-1.0.dll lib/wine/i386-unix/libusb-1.0.so; do
    [ ! -e "$tree/$absent" ] && ok "$absent" "correctly absent (64-bit only)" \
                             || bad "$absent" "present — bridge must be 64-bit only"
done
if command -v readelf >/dev/null; then
    readelf -d "$tree/lib/wine/x86_64-unix/libusb-1.0.so" 2>/dev/null \
        | grep -qF 'Shared library: [libusb-1.0.so.0]' \
        && ok "libusb-1.0.so DT_NEEDED" "host libusb-1.0.so.0" \
        || bad "libusb-1.0.so DT_NEEDED" "host libusb-1.0.so.0 not linked"
else
    bad "readelf" "binutils missing — cannot verify bridge DT_NEEDED (install binutils)"
fi

say ""
if [ "$failed" -eq 0 ]; then
    say "OK: build audit passed — $pass checks, every patch verified."
else
    say "!! BUILD AUDIT FAILED — $failed of $((pass+failed)) checks failed. Do not ship this artifact." >&2
    exit 1
fi
