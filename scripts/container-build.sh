#!/usr/bin/env bash
# Runs inside the Ubuntu 22.04 container (invoked by build.sh); /src = repo (ro), /out = dist/ (rw).
# Produces a relocatable patched-Wine tarball with WineASIO baked in.
set -euo pipefail

SRC=/src
OUT=/out
WORK=/work
JOBS="${JOBS:-$(nproc)}"
VERSION="$(cat "$SRC/VERSION")"
NAME="wine-d2d1-nspa-11.11"
CONFIGURE_PREFIX="${INSTALL_PREFIX:?build.sh must pass INSTALL_PREFIX}"
[ "$(basename "$CONFIGURE_PREFIX")" = "$NAME" ] || {
    echo "!! INSTALL_PREFIX must end in /$NAME" >&2
    exit 2
}
DESTDIR="$WORK/stage"
PREFIX_ROOT="$DESTDIR$CONFIGURE_PREFIX"
npatch="$(ls "$SRC"/patches/00*.patch | wc -l)"

echo "== [1/8] unpack pristine Wine base (giang17 d2d1-dcomp-11.11 @ 7ea0c8b7) =="
mkdir -p "$WORK/wine-src"
zstd -dc --long=27 "$SRC/vendor/wine-base-7ea0c8b7.tar.zst" | tar -x -C "$WORK/wine-src"

echo "== [2/8] git init + apply the $npatch-patch fix series =="
cd "$WORK/wine-src"
git init -q
git -c user.email=build@localhost -c user.name=dist add -A
git -c user.email=build@localhost -c user.name=dist commit -q -m "base 7ea0c8b7"
# The series ships without From:/Date: mail headers; git am refuses to commit
# with an empty author, so supply a fixed neutral ident (fixed date keeps the
# apply reproducible). Patches that still carry headers keep their own.
for p in "$SRC"/patches/00*.patch; do
    if head -8 "$p" | grep -q '^From: '; then
        git -c user.email=build@localhost -c user.name=dist am --3way "$p"
    else
        { printf 'From: dist <build@localhost>\nDate: Thu, 01 Jan 2026 00:00:00 +0000\n'
          cat "$p"
        } | git -c user.email=build@localhost -c user.name=dist am --3way
    fi
done
patch_head="$(git rev-parse HEAD)"
echo "   HEAD: $(git log --oneline -1)"

echo "== [3/8] configure + build Wine (WoW64: clang/lld PE, gcc Unix) =="
mkdir -p "$WORK/build" && cd "$WORK/build"
../wine-src/configure \
    --prefix="$CONFIGURE_PREFIX" \
    --enable-archs=i386,x86_64 \
    --disable-tests
make -j"$JOBS"
make install DESTDIR="$DESTDIR"
mkdir -p "$(dirname "$CONFIGURE_PREFIX")"
ln -s "$PREFIX_ROOT" "$CONFIGURE_PREFIX"
"$PREFIX_ROOT/bin/wine" --version

bridge_pe="$PREFIX_ROOT/lib/wine/x86_64-windows/libusb-1.0.dll"
bridge_unix="$PREFIX_ROOT/lib/wine/x86_64-unix/libusb-1.0.so"
portal_unix="$PREFIX_ROOT/lib/wine/x86_64-unix/comdlg32.so"
test -f "$bridge_pe"
test -f "$bridge_unix"
test -f "$portal_unix"
test ! -e "$PREFIX_ROOT/lib/wine/i386-windows/libusb-1.0.dll"
test ! -e "$PREFIX_ROOT/lib/wine/i386-unix/libusb-1.0.so"

expected_exports=$'4 libusb_alloc_transfer\n10 libusb_cancel_transfer\n12 libusb_claim_interface\n16 libusb_close\n26 libusb_error_name\n32 libusb_exit\n40 libusb_free_device_list\n50 libusb_free_transfer\n72 libusb_get_device_descriptor\n74 libusb_get_device_list\n110 libusb_handle_events_timeout\n120 libusb_init\n132 libusb_open\n140 libusb_release_interface\n154 libusb_set_option\n161 libusb_submit_transfer'
actual_exports="$(llvm-readobj --coff-exports "$bridge_pe" | awk '
    /^Export / { ordinal = ""; name = "" }
    /Ordinal:/ { ordinal = $2 }
    /Name: libusb_/ { name = $2 }
    /^}/ && name != "" { print ordinal, name }
')"
if [ "$actual_exports" != "$expected_exports" ]; then
    echo "!! Push 2 bridge export/ordinal mismatch" >&2
    diff -u <(printf '%s\n' "$expected_exports") <(printf '%s\n' "$actual_exports") || true
    exit 1
fi
readelf -d "$bridge_unix" | grep -F 'Shared library: [libusb-1.0.so.0]' >/dev/null
strings "$portal_unix" | grep -F 'org.freedesktop.portal.FileChooser' >/dev/null

# configure silently drops winealsa (ALSA MIDI) when libasound2-dev is absent — fail, don't ship without it.
winealsa_unix="$PREFIX_ROOT/lib/wine/x86_64-unix/winealsa.so"
if [ ! -s "$winealsa_unix" ]; then
    echo "!! winealsa.so missing — libasound2-dev not present at configure time; no ALSA MIDI" >&2
    exit 1
fi
bridge_pe_sha="$(sha256sum "$bridge_pe" | awk '{print $1}')"
bridge_unix_sha="$(sha256sum "$bridge_unix" | awk '{print $1}')"
portal_unix_sha="$(sha256sum "$portal_unix" | awk '{print $1}')"
echo "   libusb bridge: PE $bridge_pe_sha / Unix $bridge_unix_sha"

echo "== [4/8] build WineASIO 1.3.0 against THIS Wine (ABI-matched) =="
mkdir -p "$WORK/wineasio"
tar xzf "$SRC/vendor/wineasio-1.3.0.tar.gz" -C "$WORK/wineasio" --strip-components=1
cd "$WORK/wineasio"
# Apply the wineasio patch series (patches/wineasio/).
nasio="$(ls "$SRC"/patches/wineasio/*.patch 2>/dev/null | wc -l)"
[ "$nasio" -gt 0 ] || { echo "!! no wineasio patches found in $SRC/patches/wineasio" >&2; exit 1; }
for p in "$SRC"/patches/wineasio/*.patch; do
    echo "   applying $(basename "$p")"
    patch -p1 --no-backup-if-mismatch -i "$p"
done
export PATH="$PREFIX_ROOT/bin:$PATH"          # this Wine's winegcc/winebuild take PATH priority
# 64-bit only (Live 12 is 64-bit): compile against this Wine's headers, link with its winegcc/winebuild.
make 64 \
    WINEBUILD_INCLUDEDIR="$PREFIX_ROOT/include/wine" \
    WINEBUILD_LIBDIR="$PREFIX_ROOT/lib/wine/x86_64-unix" \
    CFLAGS="-I$PREFIX_ROOT/include/wine/windows"
install -m644 build64/wineasio64.dll    "$PREFIX_ROOT/lib/wine/x86_64-windows/wineasio64.dll"
install -m644 build64/wineasio64.dll.so "$PREFIX_ROOT/lib/wine/x86_64-unix/wineasio64.dll.so"
# Wine resolves wineasio64.dll to builtin name "wineasio.dll" (from its spec file) and looks for the
# unix half under that name — install both names or LoadLibrary fails with STATUS_DLL_NOT_FOUND.
install -m644 build64/wineasio64.dll    "$PREFIX_ROOT/lib/wine/x86_64-windows/wineasio.dll"
install -m644 build64/wineasio64.dll.so "$PREFIX_ROOT/lib/wine/x86_64-unix/wineasio.dll.so"

echo "== [5/8] strip + prune (dev files served their purpose in [4/8]; nothing below runs on user machines) =="
# Debug info is ~3/4 of every PE builtin and ~5/6 of the unix halves. Exports,
# resources, .rodata literals (the audit fingerprints) and the builtin signature
# all live outside the symtab; the relocation gate re-runs the stripped tree.
# .dll16/.tlb/.vxd etc. are not COFF and stay untouched.
find "$PREFIX_ROOT/lib/wine" \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' \
    -o -name '*.drv' -o -name '*.cpl' -o -name '*.ocx' \) -exec llvm-strip --strip-all {} +
strip --strip-unneeded "$PREFIX_ROOT"/lib/wine/*-unix/*.so
for f in "$PREFIX_ROOT"/bin/*; do strip --strip-unneeded "$f" 2>/dev/null || true; done  # sh wrappers in bin/ are not ELF
rm -f "$PREFIX_ROOT"/lib/wine/*-windows/*.a
rm -rf "$PREFIX_ROOT/include" "$PREFIX_ROOT/share/man"
rm -f "$PREFIX_ROOT"/bin/widl "$PREFIX_ROOT"/bin/winebuild "$PREFIX_ROOT"/bin/winecpp \
      "$PREFIX_ROOT"/bin/winedump "$PREFIX_ROOT"/bin/wineg++ "$PREFIX_ROOT"/bin/winegcc \
      "$PREFIX_ROOT"/bin/winemaker "$PREFIX_ROOT"/bin/wmc "$PREFIX_ROOT"/bin/wrc \
      "$PREFIX_ROOT"/bin/function_grep.pl
# BUILD-INFO must hash the files as shipped, i.e. post-strip
bridge_pe_sha="$(sha256sum "$bridge_pe" | awk '{print $1}')"
bridge_unix_sha="$(sha256sum "$bridge_unix" | awk '{print $1}')"
portal_unix_sha="$(sha256sum "$portal_unix" | awk '{print $1}')"

wineasio_pe="$PREFIX_ROOT/lib/wine/x86_64-windows/wineasio64.dll"
wineasio_unix="$PREFIX_ROOT/lib/wine/x86_64-unix/wineasio64.dll.so"
test -s "$wineasio_pe"
test -s "$wineasio_unix"
wineasio_pe_sha="$(sha256sum "$wineasio_pe" | awk '{print $1}')"
wineasio_unix_sha="$(sha256sum "$wineasio_unix" | awk '{print $1}')"
echo "   WineASIO: PE $wineasio_pe_sha / Unix $wineasio_unix_sha"

echo "== [6/8] package =="
# Stamp per-patch sha256s into the tree; build-audit.sh diffs this against patches/SERIES.sha256.
stack_stamp="$PREFIX_ROOT/ABLETON-WINE-PATCH-STACK.txt"
( cd "$SRC/patches" && sha256sum 00*.patch wineasio/*.patch ) > "$stack_stamp"
stack_sha="$(sha256sum "$stack_stamp" | awk '{print $1}')"
build_info="$PREFIX_ROOT/ABLETON-WINE-BUILD-INFO.txt"
{
    echo "dist-version: $VERSION"
    echo "wine:         $("$PREFIX_ROOT/bin/wine" --version)"
    echo "base:         giang17/wine d2d1-dcomp-11.11 @ 7ea0c8b7"
    echo "prefix:       $CONFIGURE_PREFIX (configure-time only; tarball is relocatable, see relocation gate)"
    echo "patches:      $((npatch + nasio))"     # wine series + wineasio series
    echo "wine-patches: $npatch"
    echo "wineasio-patches: $nasio"
    echo "patch-head:   $patch_head"
    echo "patch-stack:  $stack_sha"
    echo "wineasio:     1.3.0"
    echo "libusb-pe:    $bridge_pe_sha"
    echo "libusb-unix:  $bridge_unix_sha"
    echo "portal-unix:  $portal_unix_sha"
    echo "wineasio-pe:  $wineasio_pe_sha"
    echo "wineasio-unix: $wineasio_unix_sha"
    echo "built-on:     Ubuntu 22.04 (glibc 2.35)"
} > "$build_info"
cp "$build_info" "$OUT/BUILD-INFO-${VERSION}.txt"
cp "$build_info" "$OUT/BUILD-INFO.txt"
tarball="$OUT/${NAME}-${VERSION}.tar.zst"
# --long=27 (128 MiB window, zstd's default decode limit — no flags needed to unpack)
# lets the i386/x86_64 builtin pairs dedup against each other.
tar -C "$(dirname "$PREFIX_ROOT")" -c "$NAME" | zstd -T0 -19 --long=27 -q -o "$tarball"
( cd "$OUT" && sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256" )

echo "== [7/8] relocation + registration gate: run the packaged tree from a random path =="
# Remove the configure-path symlink so Wine's compiled-in fallback can't mask a broken relative lookup.
rm -f "$CONFIGURE_PREFIX"
reloc="$(mktemp -d /tmp/reloc-gate.XXXXXX)"
tar -C "$reloc" -I zstd -xf "$tarball"
WINEPREFIX="$reloc/prefix" WINEDEBUG=-all \
    "$reloc/$NAME/bin/wine" cmd /c "echo relocation-ok" 2>/dev/null | grep -q relocation-ok
# Register WineASIO through Live's load path; catches builtin-name mismatches presence checks miss.
WINEPREFIX="$reloc/prefix" WINEDEBUG=-all \
    "$reloc/$NAME/bin/wine" regsvr32 wineasio64.dll >/dev/null 2>&1
WINEPREFIX="$reloc/prefix" WINEDEBUG=-all \
    "$reloc/$NAME/bin/wine" reg query \
    'HKCR\CLSID\{48D0C522-BFCC-45CC-8B84-17F25F33E6E8}\InprocServer32' >/dev/null 2>&1
WINEPREFIX="$reloc/prefix" "$reloc/$NAME/bin/wineserver" -k 2>/dev/null || true
WINEPREFIX="$reloc/prefix" "$reloc/$NAME/bin/wineserver" -w 2>/dev/null || true
rm -rf "$reloc"
echo "   relocation + registration gate passed (cmd.exe ran, WineASIO registered)"

echo "== [8/8] build audit: every patch verified against the shipped tarball =="
bash "$SRC/scripts/build-audit.sh" "$tarball"

echo
echo "OK: $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"
