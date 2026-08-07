#!/usr/bin/env bash
# Audit a runtime artifact against the frozen patch stack (patches/SERIES.sha256): patch file hashes,
# build stamp, per-patch binary fingerprints. Arg: tarball, tree, or --freeze; defaults to newest dist/*.tar.zst.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
NAME="wine-d2d1-nspa-11.13"
SERIES="$root/patches/SERIES.sha256"

say()  { printf '%s\n' "$*"; }
fail() { printf '!! %s\n' "$*" >&2; exit 1; }

# --- --freeze: (re)generate the frozen series manifest ------------------------
if [ "${1:-}" = --freeze ]; then
    new="$(cd "$root/patches" && sha256sum 00*.patch pipeasio/*.patch)"
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
extras="$(cd "$root/patches" && ls 00*.patch pipeasio/*.patch 2>/dev/null | grep -vxF -f <(awk '{print $2}' "$SERIES") || true)"
[ -z "$extras" ] && ok "no unlisted patches" "" || bad "unlisted patches present" "$extras"
# Retired numbers stay retired (renumbering would break cross-references in patch
# titles and notes/); a gap is fine if documented here, a dropped patch is not.
declare -A SERIES_GAPS=(
    [0027]="retired 2026-07-14 — gitignore housekeeping, no artifact effect"
    [0044]="reserved 2026-07-24 for the issue 57 parked-pane reblit gate; shipped as 0056 instead"
    [0066]="reserved 2026-08-02 for PR 124's GPU denylist hardening series"
    [0067]="reserved 2026-08-02 for PR 124's GPU denylist hardening series"
    [0068]="reserved 2026-08-02 for PR 124's GPU denylist hardening series"
)
seq_expect=1
for f in $(awk '{print $2}' "$SERIES" | grep -v '^pipeasio/' | sort); do
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
# The pipeasio series is numbered independently of the Wine one, and the loop
# above skips it. Check it the same way, or a dropped or misnumbered pipeasio
# patch passes with only its checksum looked at.
declare -A PIPEASIO_GAPS=(
    [0000]="no retired pipeasio numbers yet; entries take the same form as SERIES_GAPS"
)
asio_expect=1
for f in $(awk '{print $2}' "$SERIES" | grep '^pipeasio/' | sort); do
    base="${f#pipeasio/}"
    num="${base%%-*}"
    printf -v want '%04d' "$asio_expect"
    while [ "$num" != "$want" ] && [ -n "${PIPEASIO_GAPS[$want]:-}" ]; do
        ok "pipeasio numbering" "$want gap documented (${PIPEASIO_GAPS[$want]})"
        asio_expect=$((asio_expect+1))
        printf -v want '%04d' "$asio_expect"
    done
    [ "$num" = "$want" ] || bad "pipeasio numbering" "expected $want, found $num"
    asio_expect=$((asio_expect+1))
done
n_wine="$(awk '{print $2}' "$SERIES" | grep -vc '^pipeasio/' || true)"
n_asio="$(awk '{print $2}' "$SERIES" | grep -c '^pipeasio/' || true)"
say "   series: $n_wine wine patches (0001..$(printf '%04d' "$((seq_expect-1))"), documented gaps ok) + $n_asio pipeasio patches (0001..$(printf '%04d' "$((asio_expect-1))"))"

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
0031|ascii|lib/wine/x86_64-unix/comdlg32.so|org.freedesktop.portal.FileChooser
0031|wide|lib/wine/x86_64-windows/comdlg32.dll|FileDialogPortal
0032|ascii|lib/wine/x86_64-windows/libusb-1.0.dll|libusb_submit_transfer
0033|ascii|lib/wine/x86_64-unix/ntdll.so|WINE_DISABLE_UNIX_MOUNT_REPARSE
0035|ascii|lib/wine/x86_64-windows/wined3d.dll|Arc(tm) B580
0036|wide|lib/wine/x86_64-windows/dxgi.dll|__wine_dcomp_null_device
0041|wide|lib/wine/x86_64-windows/dxgi.dll|__wine_dcomp_reblit_tries
0038|ascii|lib/wine/x86_64-unix/winex11.so|Ignoring FocusOut on %p during menu tracking
0039|ascii|lib/wine/x86_64-unix/winex11.so|is mapped, refusing to make it managed
0043|ascii|lib/wine/x86_64-unix/comdlg32.so|org.freedesktop.portal.OpenURI
0043|ascii|lib/wine/x86_64-windows/shell32.dll|__wine_portal_show_item
0045|ascii|lib/wine/x86_64-windows/ole32.dll|revoke for another process windows is disabled
0055|wide|lib/wine/x86_64-windows/dxgi.dll|WINE_DISABLE_GL_PRESENT
0056|ascii|lib/wine/x86_64-windows/dxgi.dll|Re-blit skipped (hidden ancestry)
0057|ascii|lib/wine/x86_64-windows/wined3d.dll|Arc(tm) Graphics (MTL)
0058|ascii|lib/wine/x86_64-windows/wined3d.dll|Present-time client rect disagrees
0059|ascii|lib/wine/x86_64-windows/wined3d.dll|Flip client rect queried in the window DPI context
0060|ascii|lib/wine/x86_64-windows/shell32.dll|IFileOperation DeleteItem via SHFileOperation
0061|ascii|lib/wine/x86_64-windows/wined3d.dll|is not in the description table
0062|ascii|lib/wine/x86_64-unix/winex11.so|WINE_X11_FORCE_OFFSCREEN_CLASS
0063|ascii|lib/wine/x86_64-unix/comdlg32.so|org.freedesktop.FileManager1
0064|ascii|lib/wine/x86_64-unix/comdlg32.so|ShowFolders
0064|ascii|lib/wine/x86_64-windows/shell32.dll|__wine_portal_open_folder
0065|ascii|lib/wine/x86_64-unix/win32u.so|WINE_WIN32_FULLSCREEN_CLASS
0065|ascii|lib/wine/x86_64-unix/winex11.so|WINE_WIN32_FULLSCREEN_CLASS
0069|ascii|lib/wine/x86_64-unix/win32u.so|WINE_WIN32_RESIZABLE_CLASS
pipeasio/0001|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-clamp-sample-rate
pipeasio/0002|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-midi-timebase
pipeasio/0003|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-quantum-arbitration
pipeasio/0004|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-any-buffer-size
pipeasio/0005|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-quantum-converge
pipeasio/0006|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-clock-domains
pipeasio/0007|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-follower-headroom
'
# pipeasio's code is in the unix .so; the PE pipeasio64.dll is a codeless fake module.
# Wine loads the unix half under the spec-file name pipeasio.dll.so, so the
# fingerprints (and the readelf checks below) aim at that file.
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
0025|idle-abandonment mechanism removed by 0041 — its fingerprint string is intentionally gone
0026|logic-only (DC drawable visual; literals not compiled in)
0028|logic-only (MIDI announce-port re-subscribe)
0029|logic-only (menu bar +4px arithmetic)
0030|literal __wine_dcomp_swapchain pre-exists in base — not distinctive
0034|logic-only (XdndStatus reply flush; adds no string literal)
0037|logic-only (MWM_FUNC_CLOSE advertised unconditionally; adds no string literal)
0040|logic-only (DPI-scaled menu-bar band; amends 0029 arithmetic)
0042|logic-only (sub-scale WM config-rounding alias; literals are TRACE-only)
0046|logic-only (frame-latency-as-semaphore fix; no new string literal)
0047|logic-only (round_dpi() wrap; no new string literal)
0048|configure/build-gate fix only; effect verified structurally (libusb-1.0.dll presence) and by 0032 fingerprint, not by a literal of its own
0049|logic-only (grayed-menu-item bevel dropped entirely; no new string literal)
0050|logic-only (per-process sys-color cache reset on WM_SYSCOLORCHANGE; no new string literal)
0051|logic-only (RDW_FRAME added to the SetSysColors redraw flags; no new string literal)
0052|logic-only (DT_HIDEPREFIX on the menu bar DrawTextW call; no new string literal)
0053|logic-only (WM_GETMINMAXINFO minimum exported as PMinSize hints; no new string literal)
0054|logic-only (per-string SystemLink font fallback in draw_menu_item, plus the calc_menu_item_size CJK-measurement fix; no new string literal)
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
        # || true: under pipefail an unlisted patch would kill the script here
        # instead of reaching the UNLISTED failure line below
        reason="$(printf '%s\n' "$STAMP_ONLY" | grep "^$num|" | cut -d'|' -f2- || true)"
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
must lib/wine/x86_64-unix/winegstreamer.so
must lib/wine/x86_64-windows/winegstreamer.dll
must lib/wine/x86_64-unix/comdlg32.so
must lib/wine/x86_64-windows/pipeasio64.dll
must lib/wine/x86_64-unix/pipeasio64.dll.so
must lib/wine/x86_64-windows/pipeasio.dll
must lib/wine/x86_64-unix/pipeasio.dll.so
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
    readelf -d "$tree/lib/wine/x86_64-unix/pipeasio.dll.so" 2>/dev/null \
        | grep -qF 'Shared library: [libpipewire-0.3.so.0]' \
        && ok "pipeasio.dll.so DT_NEEDED" "host libpipewire-0.3.so.0" \
        || bad "pipeasio.dll.so DT_NEEDED" "host libpipewire-0.3.so.0 not linked"
    if readelf -d "$tree/lib/wine/x86_64-unix/pipeasio.dll.so" 2>/dev/null | grep -qE 'RPATH|RUNPATH'; then
        bad "pipeasio.dll.so rpath" "carries a build-container rpath"
    else
        ok "pipeasio.dll.so rpath" "none (resolves via host loader)"
    fi
    readelf -d "$tree/lib/wine/x86_64-unix/winegstreamer.so" 2>/dev/null \
        | grep -qF 'Shared library: [libgstreamer-1.0.so.0]' \
        && ok "winegstreamer.so DT_NEEDED" "host libgstreamer-1.0.so.0" \
        || bad "winegstreamer.so DT_NEEDED" "host libgstreamer-1.0.so.0 not linked"
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
