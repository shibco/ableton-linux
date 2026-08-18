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

readonly REQUIRED_WINE_TAIL='0107-arm64ec.patch'
readonly REQUIRED_PIPEASIO_TAIL='pipeasio/0012-recover-selected-routes-after-hotplug.patch'

check_required_series_tails()
{
    local manifest="${1:?series manifest required}" body wine_tail pipeasio_tail
    [ -r "$manifest" ] || fail "series manifest is missing or unreadable: $manifest"
    # Read once. Callers may pass a process substitution, and a second open of
    # that FIFO returns EOF - which reported the PipeASIO tail as absent while
    # every patch was present.
    body="$(cat -- "$manifest")"
    wine_tail="$(printf '%s\n' "$body" | awk '$2 !~ /^pipeasio\// { print $2 }' | sort | tail -1)"
    pipeasio_tail="$(printf '%s\n' "$body" | awk '$2 ~ /^pipeasio\// { print $2 }' | sort | tail -1)"
    [ "$wine_tail" = "$REQUIRED_WINE_TAIL" ] ||
        fail "Wine series must end at $REQUIRED_WINE_TAIL (found ${wine_tail:-none})"
    [ "$pipeasio_tail" = "$REQUIRED_PIPEASIO_TAIL" ] ||
        fail "PipeASIO series must end at $REQUIRED_PIPEASIO_TAIL (found ${pipeasio_tail:-none})"
}

if [ "${1:-}" = --check-series-policy ]; then
    [ "$#" -eq 2 ] || fail "usage: $0 --check-series-policy MANIFEST"
    check_required_series_tails "$2"
    say "OK: required Wine and PipeASIO series tails are present."
    exit 0
fi

expected_source_tree=""
if [ "${1:-}" = --source-tree-sha ]; then
    [ "$#" -ge 2 ] || fail "usage: $0 --source-tree-sha SHA256 [TARBALL_OR_TREE]"
    expected_source_tree="$2"
    [[ "$expected_source_tree" =~ ^[0-9a-f]{64}$ ]] || \
        fail "--source-tree-sha must be one SHA-256 digest"
    shift 2
fi

# --- --freeze: (re)generate the frozen series manifest ------------------------
if [ "${1:-}" = --freeze ]; then
    new="$(cd "$root/patches" && sha256sum [0-9][0-9][0-9][0-9]-*.patch pipeasio/*.patch)"
    check_required_series_tails <(printf '%s\n' "$new")
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
check_required_series_tails "$SERIES"
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

pass=0; failed=0; skipped=0
ok()  { pass=$((pass+1));   printf '   %-42s PASS %s\n' "$1" "$2"; }
bad() { failed=$((failed+1)); printf '   %-42s FAIL %s\n' "$1" "$2"; }
# ABLETON_AUDIT_PROFILE=nix relaxes ONLY the container-pipeline provenance
# records (sanitizer runs, builder manifests, installer helper hashes, the git
# source-tree digest): the Nix build runs none of those pipelines and cannot
# stamp records it has not produced. Every structural, patch, fingerprint and
# binary-hash check still fails hard, and the release profile is unchanged.
# A relaxed record is reported and counted as skipped, never as passed.
AUDIT_PROFILE="${ABLETON_AUDIT_PROFILE:-release}"
case "$AUDIT_PROFILE" in release|nix) ;;
    *) fail "ABLETON_AUDIT_PROFILE must be release or nix (got '$AUDIT_PROFILE')" ;;
esac
# A build-container rpath resolves on no user's machine and must never ship.
# An empty one is the tarball's case, which resolves through the host loader;
# a store-only one is the Nix package pinning its own closure, and is accepted
# ONLY under that profile. A release tarball carrying a /nix/store rpath runs
# on the machine that built it and nowhere else, so on the release profile any
# rpath at all is a failure, exactly as it was before this helper existed.
rpath_check() {   # <label> <file> [empty-case detail]
    local label="$1" file="$2" empty="${3:-none}" value
    # A file that is not there is a failure to report, not an absent rpath to
    # wave through: an unreadable readelf and a clean binary both yield an
    # empty value, and only one of them is a pass.
    [ -f "$file" ] || { bad "$label" "missing: $file"; return 0; }
    # readelf exits non-zero on anything it cannot parse; pipefail turns that
    # into a failed assignment and set -e would end the audit mid-run, with no
    # summary line and no indication which check stopped it.
    value="$(readelf -d "$file" 2>/dev/null \
        | sed -n 's/.*R\(UN\)\?PATH).*\[\(.*\)\]/\2/p' || true)"
    if [ -z "$value" ]; then
        ok "$label" "$empty"
    elif [ "$AUDIT_PROFILE" != nix ]; then
        bad "$label" "carries an rpath: $value"
    elif printf '%s' "$value" | tr ':' '\n' | grep -qv '^/nix/store/'; then
        bad "$label" "carries a build-container rpath: $value"
    else
        ok "$label" "nix store pin ($value)"
    fi
}

pipeline_bad() {   # container-pipeline provenance: FAIL on release, skipped on nix
    if [ "$AUDIT_PROFILE" = release ]; then
        bad "$1" "$2"
    else
        skipped=$((skipped+1)); printf '   %-42s SKIP %s (nix profile)\n' "$1" "$2"
    fi
}

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
# Every .patch on disk, not just the numbered ones the series globs match: a file
# the series glob skips is applied by nothing and audited by nothing, so it has
# to surface here rather than pass as absent.
extras="$(cd "$root/patches" && printf '%s\n' *.patch pipeasio/*.patch \
    | grep -vxF -f <(awk '{print $2}' "$SERIES") || true)"
[ -z "$extras" ] && ok "no unlisted patches" "" || bad "unlisted patches present" "$extras"
# Retired numbers stay retired (renumbering would break cross-references in patch
# titles and release history); a gap is fine if documented here, a dropped patch is not.
declare -A SERIES_GAPS=(
    [0027]="retired 2026-07-14 — gitignore housekeeping, no artifact effect"
    [0044]="reserved 2026-07-24 for the issue 57 parked-pane reblit gate; shipped as 0056 instead"
)
for consolidated_gap in 0072 0074 0090 0091 0092 0093 0094 0095 0097 0098; do
    SERIES_GAPS[$consolidated_gap]="consolidated in 0100"
done
unset consolidated_gap
seq_expect=1
for f in $(awk '{print $2}' "$SERIES" | grep -v '^pipeasio/' | sort); do
    num="${f%%-*}"
    if [ -n "${SERIES_GAPS[$num]:-}" ]; then
        bad "series numbering" "$num is a declared gap but patch is present ($f)"
    fi
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
# above skips it. Check it the same way, or a dropped or misnumbered patch
# passes with only its checksum looked at.
declare -A PIPEASIO_GAPS=(
    [0003]="warning-text fix superseded by the 1.5.0 diagnostic relay; the corrected text lives in 0005's quantum diagnostic (both arbitration and converge wordings)"
    [0007]="follower headroom retired 2026-08-10, mechanism ineffective mid-stream (a live api.alsa.headroom write lands in default_headroom only and takes effect on the next renegotiation, not the running stream)"
)
asio_expect=1
for f in $(awk '{print $2}' "$SERIES" | grep '^pipeasio/' | sort); do
    base="${f#pipeasio/}"
    num="${base%%-*}"
    if [ -n "${PIPEASIO_GAPS[$num]:-}" ]; then
        bad "pipeasio numbering" "$num is a declared gap but patch is present ($f)"
    fi
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
source_tree_record="$(sed -n 's/^source-tree:  *//p' "$binfo" 2>/dev/null || true)"
source_tree_count="$(grep -c '^source-tree:' "$binfo" 2>/dev/null || true)"
if [ "$AUDIT_PROFILE" = nix ]; then
    # The git source-tree digest exists only in the container pipeline; the
    # nix builder sees a filtered store copy with no .git to digest.
    pipeline_bad "BUILD-INFO source tree" "git digest is a container-pipeline record"
else
    if [ -n "$expected_source_tree" ]; then
        source_tree_actual="$expected_source_tree"
    else
        source_tree_actual="$("$root/scripts/source-tree-digest.sh")"
    fi
    if [ "$source_tree_count" -eq 1 ] \
       && [[ "$source_tree_record" =~ ^[0-9a-f]{64}$ ]] \
       && [ "$source_tree_record" = "$source_tree_actual" ]; then
        ok "BUILD-INFO source tree" "matches current source candidate"
    else
        bad "BUILD-INFO source tree" \
            "recorded=${source_tree_record:-missing} current=$source_tree_actual"
    fi
fi

# The Qt panel is optional, but its provenance is not. A normal value starts
# with the shipped binary's sha256; a no-Qt/driver-only build says why it was
# skipped. Later structural checks enforce the corresponding complete trio or
# complete absence.
panel_built=-1
panel_hash=""
panel_record=""
panel_mode=""
pipewire_probe_hash=""
builder_packages_hash=""
declare -A recorded_binary_hashes=()
readonly RECORDED_BINARIES='libusb-pe|lib/wine/x86_64-windows/libusb-1.0.dll
libusb-unix|lib/wine/x86_64-unix/libusb-1.0.so
portal-unix|lib/wine/x86_64-unix/comdlg32.so
pipeasio-pe|lib/wine/x86_64-windows/pipeasio64.dll
pipeasio-unix|lib/wine/x86_64-unix/pipeasio64.dll.so'
if [ -f "$binfo" ]; then
    panel_mode="$(sed -n 's/^pipeasio-panel: *//p' "$binfo")"
    panel_record="$(sed -n 's/^pipeasio-settings: *//p' "$binfo")"
    panel_hash="${panel_record%% *}"
    if [[ "$panel_hash" =~ ^[0-9a-f]{64}$ ]] && [ "$panel_mode" = built ]; then
        panel_built=1
        ok "BUILD-INFO panel provenance" "state=built; binary hash recorded"
    elif { [ "$panel_record" = 'skipped (disabled)' ] \
            || [ "$panel_record" = 'skipped (Qt6 Widgets unavailable)' ]; } \
            && [ "$panel_mode" = skipped ]; then
        panel_built=0
        ok "BUILD-INFO panel provenance" "state=skipped; $panel_record"
    else
        bad "BUILD-INFO panel provenance" \
            "inconsistent/malformed state='$panel_mode' settings='$panel_record'"
    fi

    if grep -q '^pipeasio-no-qt: .*passed$' "$binfo"; then
        ok "no-Qt build/install gate" "recorded passed"
    else
        pipeline_bad "no-Qt build/install gate" "missing from BUILD-INFO"
    fi
    if grep -q '^pipeasio-sanitizers: ASan+UBSan .*; TSan unit passed$' "$binfo"; then
        ok "PipeASIO sanitizer gate" "ASan+UBSan and TSan recorded passed"
    elif grep -Eq \
            '^pipeasio-sanitizers: ASan\+UBSan .*; TSan unit skipped \((explicit mode|host ASLR/seccomp incompatibility; auto mode); non-release build\)$' \
            "$binfo"; then
        ok "PipeASIO sanitizer gate" \
            "ASan+UBSan passed; TSan explicitly skipped (non-release build)"
    else
        pipeline_bad "PipeASIO sanitizer gate" "missing/incomplete in BUILD-INFO"
    fi
    pipewire_probe_hash="$(sed -n 's/^pipewire-version-probe: *//p' "$binfo")"
    pipewire_probe_count="$(grep -c '^pipewire-version-probe:' "$binfo" || true)"
    if [ "$pipewire_probe_count" -eq 1 ] && [[ "$pipewire_probe_hash" =~ ^[0-9a-f]{64}$ ]]; then
        ok "PipeWire probe provenance" "binary hash recorded"
    else
        bad "PipeWire probe provenance" "missing/malformed hash in BUILD-INFO"
    fi
    if grep -qxF \
            'pipewire-version-probe-tests: client-stub+ASan+UBSan passed' \
            "$binfo"; then
        ok "PipeWire probe test gate" "client stub + ASan/UBSan recorded passed"
    else
        pipeline_bad "PipeWire probe test gate" "missing/incomplete in BUILD-INFO"
    fi
    builder_packages_count="$(grep -c '^builder-packages:' "$binfo" || true)"
    builder_packages_hash="$(sed -n 's/^builder-packages: *//p' "$binfo")"
    if [ "$builder_packages_count" -eq 1 ] \
       && [[ "$builder_packages_hash" =~ ^[0-9a-f]{64}$ ]]; then
        ok "BUILD-INFO builder packages" "manifest hash recorded"
    else
        pipeline_bad "BUILD-INFO builder packages" "missing, duplicate, or malformed hash"
    fi
    for helper_spec in cabextract-static ableton-linkd; do
        helper_count="$(grep -c "^${helper_spec}:" "$binfo" || true)"
        helper_hash="$(sed -n "s/^${helper_spec}: *//p" "$binfo")"
        if [ "$helper_count" -eq 1 ] && [[ "$helper_hash" =~ ^[0-9a-f]{64}$ ]]; then
            ok "BUILD-INFO $helper_spec" "installer helper hash recorded"
        else
            pipeline_bad "BUILD-INFO $helper_spec" "missing, duplicate, or malformed hash"
        fi
    done
    while IFS='|' read -r record_key artifact_path; do
        [ -n "$record_key" ] || continue
        record_count="$(grep -c "^${record_key}:" "$binfo" || true)"
        record_value="$(sed -n "s/^${record_key}: *//p" "$binfo")"
        if [ "$record_count" -eq 1 ] && [[ "$record_value" =~ ^[0-9a-f]{64}$ ]]; then
            recorded_binary_hashes["$record_key"]="$record_value"
            ok "BUILD-INFO $record_key" "binary hash recorded"
        else
            bad "BUILD-INFO $record_key" "missing, duplicate, or malformed hash"
        fi
    done <<< "$RECORDED_BINARIES"
else
    bad "BUILD-INFO PipeASIO gates" "missing $binfo"
fi

# --- [3/4] patch artifact fingerprints -----------------------------------------
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
0066|ascii|lib/wine/x86_64-windows/wined3d.dll|Intel(R) UHD Graphics P630
0068|ascii|lib/wine/x86_64-windows/wined3d.dll|WINE_D3D_FORCE_GPU_RENDERING
0069|ascii|lib/wine/x86_64-unix/win32u.so|WINE_WIN32_RESIZABLE_CLASS
0071|ascii|lib/wine/x86_64-windows/wined3d.dll|Sustained present-size mismatch
0075|ascii|lib/wine/x86_64-windows/kernel32.dll|UnregisterApplicationRecoveryCallback
0076|ascii|lib/wine/x86_64-windows/userenv.dll|DeriveAppContainerSidFromAppContainerName
0080|ascii|lib/wine/x86_64-windows/ninput.dll|pointer_count %u
0084|ascii|lib/wine/x86_64-unix/win32u.so|WINE_DISABLE_PREFIX_FONT_SMOOTHING
0088|ascii|lib/wine/x86_64-unix/win32u.so|DesktopUIFont
0096|ascii|lib/wine/x86_64-unix/win32u.so|WINE_DISABLE_HOST_FONT_CACHE
0100|ascii|lib/wine/x86_64-unix/winex11.so|ptr lease event=restore
0101|ascii|lib/wine/x86_64-windows/user32.dll|dnd target=%p event=release
0105|ascii|lib/wine/x86_64-unix/winealsa.so|WINE MIDI topology
0105|ascii|lib/wine/x86_64-windows/winmm.dll|Out of memory refreshing %s mappings
0106|ascii|lib/wine/x86_64-windows/libusb-1.0.dll|Operation not supported or unimplemented on this platform
pipeasio/0001|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-clamp-sample-rate
pipeasio/0002|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-midi-timebase
pipeasio/0004|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-any-buffer-size
pipeasio/0005|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-quantum-converge
pipeasio/0005|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-quantum-arbitration
pipeasio/0006|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-clock-domains
pipeasio/0008|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-daemon-version
pipeasio/0009|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-honest-realtime
pipeasio/0010|wide|bin/pipeasio-settings|pick a preset or type any value
pipeasio/0011|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-ableton-controlpanel
pipeasio/0012|ascii|lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio-reliable-hotplug
'
# 0010's source marker (pipeasio-any-buffer-size-panel) is a comment and does
# not reach the panel binary; its fingerprint is the tooltip literal above,
# stored as UTF-16 by QStringLiteral, hence the wide encoding.
# Patch 0105 supplies the MIDI device path used for Push 3 discovery. Its
# winealsa and winmm fingerprints above verify that implementation.
PIPEASIO_MARKER_TODO='
0012
'
# pipeasio's code is in the unix .so; the PE pipeasio64.dll is a codeless fake module.
# Wine loads the unix half under the spec-file name pipeasio.dll.so, so the
# fingerprints (and the readelf checks below) aim at that file.
STAMP_ONLY='
0081|logic-only (subpixel rasterisation for ClearType glyph textures; adds no string literal)
0082|logic-only (per-channel blend passes for ClearType runs; adds no string literal)
0083|logic-only (ClearType level and pixel geometry from system settings; adds no string literal)
0085|logic-only (filter tails retained in glyph bounds; adds no string literal)
0086|logic-only (pixel geometry and target policy for ClearType; adds no string literal)
0087|logic-only (smoothing resolved by source precedence; adds no string literal)
0089|logic-only (signed ClearType coverage interpolation; adds no string literal)
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
0049|logic-only (greyed-menu-item bevel dropped entirely; no new string literal)
0050|logic-only (per-process system-colour cache reset on WM_SYSCOLORCHANGE; no new string literal)
0051|logic-only (RDW_FRAME added to the SetSysColors redraw flags; no new string literal)
0052|logic-only (DT_HIDEPREFIX on the menu bar DrawTextW call; no new string literal)
0053|logic-only (WM_GETMINMAXINFO minimum exported as PMinSize hints; no new string literal)
0054|logic-only (per-string SystemLink font fallback in draw_menu_item, plus the calc_menu_item_size CJK-measurement fix; no new string literal)
0067|logic-only (drops the video-memory precondition on the 0061 synthesised description; reuses the 0061 string literal)
0070|logic-only (break Alt/F10 menu-bar arming when the app consumes the chord key; no new string literal)
0073|logic-only (both wheel messages preserve screen coordinates and skip non-client filter prediction; adds no string literal)
0077|logic-only (minimise/maximise Motif functions advertised unconditionally; extends 0037, no new string literal)
0078|logic-only (initial monitor DPI seeded in the create_window request; MR 11573 backport, no new string literal)
0079|logic-only (standalone-surface window search gated on a private-data marker; adds no string literal)
0099|logic-only (reserved pool grown with further arenas once map_reserved_area declines, keeping anonymous views ascending; new TRACE only, adds no string literal)
0102|logic-only (natural modes use outlines; GDI-compatible and aliased modes keep strikes; adds no string literal)
0103|logic-only (natural rendering quantised to 16 horizontal phases, glyph cache budget scaled with the phase count; adds no string literal)
0104|logic-only (resize derives target bitmap options from the DXGI surface and preserves its pixel format; adds no string literal)
'
wide_pattern() {  # ascii string -> PCRE matching its UTF-16LE bytes
    printf '%s' "$1" | od -An -v -tx1 | tr -d '\n' | tr -s ' ' ' ' \
        | sed -e 's/^ //' -e 's/ $//' -e 's/ /\\x00\\x/g' -e 's/^/\\x/' -e 's/$/\\x00/'
}
say "== [3/4] per-patch verification ($n_series patches) =="
todo_markers=0
for f in $(awk '{print $2}' "$SERIES" | sort); do
    num="${f%%-*}"
    integrity="sha✓"
    [ "${sha_ok[$f]:-0}" = 1 ] || integrity="sha✗"
    stamp_note="stamp✓"
    [ "$stamp_ok" = 1 ] || stamp_note="stamp✗"
    fps="$(printf '%s\n' "$FINGERPRINTS" | grep "^$num|" || true)"
    if [ "$num" = pipeasio/0010 ] && [ "$panel_built" = 0 ]; then
        # 0010 changes only the optional Qt GUI. With no panel there is no
        # honest binary fingerprint to inspect, so require source integrity,
        # the exact stack stamp and the explicit no-panel provenance above.
        if [ "${sha_ok[$f]:-0}" = 1 ] && [ "$stamp_ok" = 1 ]; then
            ok "$f" "$integrity $stamp_note (optional panel not built)"
        else
            bad "$f" "$integrity $stamp_note (optional panel not built)"
        fi
        continue
    fi
    if [ -z "$fps" ] && printf '%s\n' "$PIPEASIO_MARKER_TODO" | grep -qxF "$num"; then
        # Transitional: the series is being rewritten and the marker strings
        # are not final. Integrity and stamp still gate; the binary marker is
        # the only check deferred, and the NOTICE below keeps it loud.
        todo_markers=$((todo_markers+1))
        if [ "${sha_ok[$f]:-0}" = 1 ] && [ "$stamp_ok" = 1 ]; then
            ok "$f" "$integrity $stamp_note via stack stamp (marker TODO(reconcile-markers))"
        else
            bad "$f" "$integrity $stamp_note (marker TODO(reconcile-markers))"
        fi
        continue
    fi
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
must bin/pipewire-version-probe
must ABLETON-WINE-BUILD-PACKAGES.txt

builder_packages="$tree/ABLETON-WINE-BUILD-PACKAGES.txt"
actual_builder_packages_hash="$(
    sha256sum "$builder_packages" 2>/dev/null | awk '{print $1}' || true
)"
if [ -n "$builder_packages_hash" ] \
   && [ "$actual_builder_packages_hash" = "$builder_packages_hash" ]; then
    ok "builder package manifest sha256" "matches BUILD-INFO"
else
    bad "builder package manifest sha256" \
        "BUILD-INFO=${builder_packages_hash:-missing} artifact=${actual_builder_packages_hash:-missing}"
fi
if [ -s "$builder_packages" ] \
   && LC_ALL=C sort -c -u "$builder_packages" 2>/dev/null \
   && awk 'NF != 2 { malformed = 1 } END { exit malformed || NR == 0 }' \
        "$builder_packages"; then
    ok "builder package manifest format" "sorted unique package/version records"
else
    bad "builder package manifest format" "empty, unsorted, duplicate, or malformed"
fi

while IFS='|' read -r record_key artifact_path; do
    [ -n "$record_key" ] || continue
    actual_hash="$(sha256sum "$tree/$artifact_path" 2>/dev/null | awk '{print $1}' || true)"
    recorded_hash="${recorded_binary_hashes[$record_key]:-}"
    if [ -n "$recorded_hash" ] && [ "$actual_hash" = "$recorded_hash" ]; then
        ok "$record_key sha256" "matches BUILD-INFO"
    else
        bad "$record_key sha256" \
            "BUILD-INFO=${recorded_hash:-missing} artifact=${actual_hash:-missing}"
    fi
done <<< "$RECORDED_BINARIES"

if [ -x "$tree/bin/pipewire-version-probe" ]; then
    ok "pipewire-version-probe mode" "executable"
else
    bad "pipewire-version-probe mode" "not executable"
fi
actual_pipewire_probe_hash="$(
    sha256sum "$tree/bin/pipewire-version-probe" 2>/dev/null \
        | awk '{print $1}' \
        || true
)"
if [ -n "$pipewire_probe_hash" ] \
        && [ "$actual_pipewire_probe_hash" = "$pipewire_probe_hash" ]; then
    ok "pipewire-version-probe sha256" "matches BUILD-INFO"
else
    bad "pipewire-version-probe sha256" \
        "BUILD-INFO=$pipewire_probe_hash artifact=$actual_pipewire_probe_hash"
fi

# Upstream's CMake install owns the unified Wine aliases. Requiring relative
# links proves the packaging used that install contract and keeps relocation
# safe; a copied or absolute alias can silently diverge from the versioned DLL.
for alias_spec in \
    'lib/wine/x86_64-windows/pipeasio.dll|pipeasio64.dll' \
    'lib/wine/x86_64-unix/pipeasio.dll.so|pipeasio64.dll.so'; do
    alias_path="${alias_spec%%|*}"
    alias_target="${alias_spec#*|}"
    if [ -L "$tree/$alias_path" ] && [ "$(readlink "$tree/$alias_path")" = "$alias_target" ]; then
        ok "$alias_path alias" "relative -> $alias_target"
    else
        bad "$alias_path alias" "not the upstream relative symlink -> $alias_target"
    fi
done

panel_paths=(
    bin/pipeasio-settings
    share/applications/pipeasio-settings.desktop
    share/icons/hicolor/scalable/apps/pipeasio.svg
)
panel_count=0
for panel_path in "${panel_paths[@]}"; do
    [ -e "$tree/$panel_path" ] && panel_count=$((panel_count+1))
done
if [ "$panel_count" -ne 0 ] && [ "$panel_count" -ne 3 ]; then
    bad "settings panel payload" "partial deployment ($panel_count/3 files)"
elif [ "$panel_built" = 1 ] && [ "$panel_count" -eq 3 ]; then
    for panel_path in "${panel_paths[@]}"; do must "$panel_path"; done
    if [ -x "$tree/bin/pipeasio-settings" ]; then
        ok "pipeasio-settings mode" "executable"
    else
        bad "pipeasio-settings mode" "not executable"
    fi
    actual_panel_hash="$(sha256sum "$tree/bin/pipeasio-settings" | awk '{print $1}')"
    if [ "$actual_panel_hash" = "$panel_hash" ]; then
        ok "pipeasio-settings sha256" "matches BUILD-INFO"
    else
        bad "pipeasio-settings sha256" \
            "BUILD-INFO=$panel_hash artifact=$actual_panel_hash"
    fi
    if grep -qxF 'Exec=pipeasio-settings' \
            "$tree/share/applications/pipeasio-settings.desktop"; then
        ok "panel desktop Exec" "pipeasio-settings"
    else
        bad "panel desktop Exec" "missing/wrong"
    fi
    if grep -qxF 'Icon=pipeasio' \
            "$tree/share/applications/pipeasio-settings.desktop"; then
        ok "panel desktop Icon" "pipeasio"
    else
        bad "panel desktop Icon" "missing/wrong"
    fi
elif [ "$panel_built" = 0 ] && [ "$panel_count" -eq 0 ]; then
    ok "settings panel payload" "deliberately absent (driver-only build)"
elif [ "$panel_built" = 1 ]; then
    bad "settings panel payload" "BUILD-INFO records a panel but payload is absent"
elif [ "$panel_built" = 0 ]; then
    bad "settings panel payload" "BUILD-INFO records no panel but payload is present"
else
    bad "settings panel payload" "cannot reconcile malformed BUILD-INFO provenance"
fi
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
    rpath_check "pipeasio.dll.so rpath" \
        "$tree/lib/wine/x86_64-unix/pipeasio.dll.so" "none (resolves via host loader)"
    pipewire_probe_needed="$(
        readelf -d "$tree/bin/pipewire-version-probe" 2>/dev/null \
            | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' \
            | sort \
            || true
    )"
    if [ "$pipewire_probe_needed" = $'libc.so.6\nlibpipewire-0.3.so.0' ]; then
        ok "pipewire-version-probe DT_NEEDED" "host PipeWire soname + libc only"
    else
        bad "pipewire-version-probe DT_NEEDED" \
            "unexpected libraries: ${pipewire_probe_needed//$'\n'/, }"
    fi
    rpath_check "pipewire-version-probe rpath" "$tree/bin/pipewire-version-probe"
    if [ "$panel_built" = 1 ]; then
        if readelf -d "$tree/bin/pipeasio-settings" 2>/dev/null \
                | grep -qF 'Shared library: [libQt6Widgets.so.6]'; then
            ok "pipeasio-settings DT_NEEDED" "Qt6 Widgets"
        else
            bad "pipeasio-settings DT_NEEDED" "libQt6Widgets.so.6 not linked"
        fi
        rpath_check "pipeasio-settings rpath" "$tree/bin/pipeasio-settings"
    fi
    readelf -d "$tree/lib/wine/x86_64-unix/winegstreamer.so" 2>/dev/null \
        | grep -qF 'Shared library: [libgstreamer-1.0.so.0]' \
        && ok "winegstreamer.so DT_NEEDED" "host libgstreamer-1.0.so.0" \
        || bad "winegstreamer.so DT_NEEDED" "host libgstreamer-1.0.so.0 not linked"
else
    bad "readelf" "binutils missing — cannot verify bridge DT_NEEDED (install binutils)"
fi

if [ "$todo_markers" -gt 0 ]; then
    say ""
    say "*** NOTICE *********************************************************"
    say "*** $todo_markers pipeasio patch(es) passed on stack stamp alone: their binary"
    say "*** marker strings are pending reconciliation after the rewritten"
    say "*** series lands. Fill the TODO(reconcile-markers) entries in"
    say "*** FINGERPRINTS (scripts/build-audit.sh) and empty"
    say "*** PIPEASIO_MARKER_TODO before any release."
    say "********************************************************************"
fi

say ""
if [ "$failed" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
        say "OK: build audit passed — $pass checks, every patch verified; $skipped provenance records skipped ($AUDIT_PROFILE profile)."
    else
        say "OK: build audit passed — $pass checks, every patch verified."
    fi
else
    say "!! BUILD AUDIT FAILED — $failed of $((pass+failed)) checks failed. Do not ship this artifact." >&2
    exit 1
fi
