#!/usr/bin/env bash
# Runs inside the Ubuntu 22.04 container (invoked by build.sh); /src = repo (ro), /out = dist/ (rw).
# Produces a relocatable patched-Wine tarball with PipeASIO baked in.
set -euo pipefail

SRC=/src
OUT=/out
WORK=/work
JOBS="${JOBS:-$(nproc)}"
VERSION="$(cat "$SRC/VERSION")"
NAME="wine-d2d1-nspa-11.13"
CONFIGURE_PREFIX="${INSTALL_PREFIX:?build.sh must pass INSTALL_PREFIX}"
[ "$(basename "$CONFIGURE_PREFIX")" = "$NAME" ] || {
    echo "!! INSTALL_PREFIX must end in /$NAME" >&2
    exit 2
}
DESTDIR="$WORK/stage"
PREFIX_ROOT="$DESTDIR$CONFIGURE_PREFIX"
npatch="$(ls "$SRC"/patches/00*.patch | wc -l)"

echo "== [1/8] unpack pristine Wine base (giang17 d2d1-dcomp-11.13 @ 5c23dd1c) =="
mkdir -p "$WORK/wine-src"
zstd -dc --long=27 "$SRC/vendor/wine-base-5c23dd1c.tar.zst" | tar -x -C "$WORK/wine-src"

echo "== [2/8] git init + apply the $npatch-patch fix series =="
cd "$WORK/wine-src"
# Rootless podman can bind-mount /work owned by a UID outside the container's
# user namespace; git (>=2.35.2) refuses to operate on a tree it doesn't own.
# Scoped to this exact path, not a global opt-out.
git config --global --add safe.directory "$WORK/wine-src"
git init -q
git -c user.email=build@localhost -c user.name=dist add -A
git -c user.email=build@localhost -c user.name=dist commit -q -m "base 5c23dd1c"
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
# CPPFLAGS: the vendored ntsync UAPI header (Containerfile), nothing else in
# that dir, so the 5.15 system headers stay authoritative for everything else.
CPPFLAGS="-I/opt/ntsync-uapi" ../wine-src/configure \
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

# configure also silently drops ntsync without linux/ntsync.h; every NT sync
# wait then becomes a wineserver round trip (~1.3 cores with Live running).
# Shipped unnoticed twice in 2026-07. Check BOTH halves: the 07-12 build lost
# only the wineserver one. notes/ABLETON-WINE-NTSYNC-REGRESSION.md
if ! grep -q '^#define HAVE_LINUX_NTSYNC_H 1' "$WORK/build/include/config.h"; then
    echo "!! HAVE_LINUX_NTSYNC_H not set; linux/ntsync.h not seen at configure time" >&2
    exit 1
fi
# grep -c, not grep -q: -q exits on first match, strings dies of SIGPIPE and
# pipefail turns the success into a false "missing" (this killed a good build).
ntsync_srv="$(strings "$PREFIX_ROOT/bin/wineserver" | grep -c ntsync || true)"
ntsync_ntd="$(strings "$PREFIX_ROOT/lib/wine/x86_64-unix/ntdll.so" | grep -c ntsync || true)"
if [ "${ntsync_srv:-0}" -eq 0 ]; then
    echo "!! no ntsync in wineserver; waits would fall back to server round trips" >&2
    exit 1
fi
if [ "${ntsync_ntd:-0}" -eq 0 ]; then
    echo "!! no ntsync in ntdll.so; waits would fall back to server round trips" >&2
    exit 1
fi
ntsync_hdr_sha="$(sha256sum /opt/ntsync-uapi/linux/ntsync.h | awk '{print $1}')"
echo "   ntsync: compiled in (header $ntsync_hdr_sha)"
bridge_pe_sha="$(sha256sum "$bridge_pe" | awk '{print $1}')"
bridge_unix_sha="$(sha256sum "$bridge_unix" | awk '{print $1}')"
portal_unix_sha="$(sha256sum "$portal_unix" | awk '{print $1}')"
echo "   libusb bridge: PE $bridge_pe_sha / Unix $bridge_unix_sha"

echo "== [4/8] build PipeASIO 1.2.2 against THIS Wine (ABI-matched) =="
mkdir -p "$WORK/pipeasio"
tar xzf "$SRC/vendor/pipeasio-1.2.2.tar.gz" -C "$WORK/pipeasio" --strip-components=1
cd "$WORK/pipeasio"
# Apply the pipeasio patch series (patches/pipeasio/).
nasio="$(ls "$SRC"/patches/pipeasio/*.patch 2>/dev/null | wc -l)"
[ "$nasio" -gt 0 ] || { echo "!! no pipeasio patches found in $SRC/patches/pipeasio" >&2; exit 1; }
for p in "$SRC"/patches/pipeasio/*.patch; do
    echo "   applying $(basename "$p")"
    patch -p1 --no-backup-if-mismatch -i "$p"
done
export PATH="$PREFIX_ROOT/bin:$PATH"          # this Wine's winegcc/winebuild take PATH priority
# 64-bit only (Live 12 is 64-bit). Upstream builds with CMake; this drives the
# same five-object build directly, against this Wine's headers and the vendored
# PipeWire SDK (Containerfile). The SDK is link-time only: the .so records
# DT_NEEDED libpipewire-0.3.so.0 and resolves against the host PipeWire at
# runtime (floor 0.3.56 for the thread-utils API).
PW_SDK=/opt/pipewire-sdk
mkdir -p build64
for f in asio audio config main regsvr; do
    gcc -c -o "build64/$f.o" "src/$f.c" \
        -Iinclude \
        -I"$PW_SDK/usr/include/pipewire-0.3" -I"$PW_SDK/usr/include/spa-0.2" \
        -I"$PREFIX_ROOT/include" -I"$PREFIX_ROOT/include/wine" \
        -I"$PREFIX_ROOT/include/wine/windows" \
        -D_REENTRANT -Wall -pipe -fno-strict-aliasing -Wwrite-strings \
        -Wpointer-arith -Werror=implicit-function-declaration \
        -fPIC -O2 -DNDEBUG -fvisibility=hidden
done
winebuild -m64 --dll --fake-module -E pipeasio.dll.spec build64/*.o -o build64/pipeasio64.dll
winegcc -shared pipeasio.dll.spec build64/*.o \
    -L"$PW_SDK/usr/lib/x86_64-linux-gnu" \
    -lodbc32 -lole32 -luuid -lwinmm -luser32 -lpipewire-0.3 \
    -o build64/pipeasio64.dll.so
# Must link the host's PipeWire by soname, no SDK path baked in.
readelf -d build64/pipeasio64.dll.so | grep -F 'Shared library: [libpipewire-0.3.so.0]' >/dev/null
if readelf -d build64/pipeasio64.dll.so | grep -qE 'RPATH|RUNPATH'; then
    echo "!! pipeasio64.dll.so carries an rpath into the build container" >&2
    exit 1
fi
install -m644 build64/pipeasio64.dll    "$PREFIX_ROOT/lib/wine/x86_64-windows/pipeasio64.dll"
install -m644 build64/pipeasio64.dll.so "$PREFIX_ROOT/lib/wine/x86_64-unix/pipeasio64.dll.so"
# Wine resolves pipeasio64.dll to builtin name "pipeasio.dll" (from its spec file) and looks for the
# unix half under that name — install both names or LoadLibrary fails with STATUS_DLL_NOT_FOUND.
install -m644 build64/pipeasio64.dll    "$PREFIX_ROOT/lib/wine/x86_64-windows/pipeasio.dll"
install -m644 build64/pipeasio64.dll.so "$PREFIX_ROOT/lib/wine/x86_64-unix/pipeasio.dll.so"

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

pipeasio_pe="$PREFIX_ROOT/lib/wine/x86_64-windows/pipeasio64.dll"
pipeasio_unix="$PREFIX_ROOT/lib/wine/x86_64-unix/pipeasio64.dll.so"
test -s "$pipeasio_pe"
test -s "$pipeasio_unix"
pipeasio_pe_sha="$(sha256sum "$pipeasio_pe" | awk '{print $1}')"
pipeasio_unix_sha="$(sha256sum "$pipeasio_unix" | awk '{print $1}')"
echo "   PipeASIO: PE $pipeasio_pe_sha / Unix $pipeasio_unix_sha"

echo "== [6/8] package =="
# Stamp per-patch sha256s into the tree; build-audit.sh diffs this against patches/SERIES.sha256.
stack_stamp="$PREFIX_ROOT/ABLETON-WINE-PATCH-STACK.txt"
( cd "$SRC/patches" && sha256sum 00*.patch pipeasio/*.patch ) > "$stack_stamp"
stack_sha="$(sha256sum "$stack_stamp" | awk '{print $1}')"
build_info="$PREFIX_ROOT/ABLETON-WINE-BUILD-INFO.txt"
{
    echo "dist-version: $VERSION"
    echo "wine:         $("$PREFIX_ROOT/bin/wine" --version)"
    echo "base:         giang17/wine d2d1-dcomp-11.13 @ 5c23dd1c"
    echo "prefix:       $CONFIGURE_PREFIX (configure-time only; tarball is relocatable, see relocation gate)"
    echo "patches:      $((npatch + nasio))"     # wine series + pipeasio series
    echo "wine-patches: $npatch"
    echo "pipeasio-patches: $nasio"
    echo "patch-head:   $patch_head"
    echo "patch-stack:  $stack_sha"
    echo "pipeasio:     1.2.2"
    echo "pipewire-floor: 0.3.56 (pw_context_get_data_loop, pw_data_loop_set_thread_utils)"
    echo "ntsync:       yes (vendored linux/ntsync.h $ntsync_hdr_sha)"
    echo "libusb-pe:    $bridge_pe_sha"
    echo "libusb-unix:  $bridge_unix_sha"
    echo "portal-unix:  $portal_unix_sha"
    echo "pipeasio-pe:  $pipeasio_pe_sha"
    echo "pipeasio-unix: $pipeasio_unix_sha"
    echo "built-on:     Ubuntu 22.04 (glibc 2.35)"
} > "$build_info"
cp "$build_info" "$OUT/BUILD-INFO-${VERSION}.txt"
cp "$build_info" "$OUT/BUILD-INFO.txt"
tarball="$OUT/${NAME}-${VERSION}.tar.zst"
# --long=27 (128 MiB window, zstd's default decode limit — no flags needed to unpack)
# lets the i386/x86_64 builtin pairs dedup against each other.
tar -C "$(dirname "$PREFIX_ROOT")" -c "$NAME" | zstd -T0 -19 --long=27 -q -f -o "$tarball"
( cd "$OUT" && sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256" )

echo "== [7/8] relocation + registration gate: run the packaged tree from a random path =="
# Remove the configure-path symlink so Wine's compiled-in fallback can't mask a broken relative lookup.
rm -f "$CONFIGURE_PREFIX"
reloc="$(mktemp -d /tmp/reloc-gate.XXXXXX)"
tar -C "$reloc" -I zstd -xf "$tarball"
WINEPREFIX="$reloc/prefix" WINEDEBUG=-all \
    "$reloc/$NAME/bin/wine" cmd /c "echo relocation-ok" 2>/dev/null | grep -q relocation-ok
# Register PipeASIO through Live's load path; catches builtin-name mismatches presence checks miss.
# Registration only loads the DLL and writes registry keys, but dlopen of the
# unix half still needs libpipewire-0.3.so.0 to resolve. The SDK's .so targets
# a newer glibc than this container, so satisfy the loader with a stub that
# exports exactly the pw_ symbols the driver references.
pwstub="$(mktemp -d)"
nm -D "$reloc/$NAME/lib/wine/x86_64-unix/pipeasio64.dll.so" \
    | awk '$1 == "U" && $2 ~ /^pw_/ { print "void " $2 "(void) {}" }' > "$pwstub/stub.c"
gcc -shared -fPIC -Wl,-soname,libpipewire-0.3.so.0 -o "$pwstub/libpipewire-0.3.so.0" "$pwstub/stub.c"
WINEPREFIX="$reloc/prefix" WINEDEBUG=-all \
    LD_LIBRARY_PATH="$pwstub" \
    "$reloc/$NAME/bin/wine" regsvr32 pipeasio64.dll >/dev/null 2>&1
WINEPREFIX="$reloc/prefix" WINEDEBUG=-all \
    "$reloc/$NAME/bin/wine" reg query \
    'HKCR\CLSID\{2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}\InprocServer32' >/dev/null 2>&1
WINEPREFIX="$reloc/prefix" "$reloc/$NAME/bin/wineserver" -k 2>/dev/null || true
WINEPREFIX="$reloc/prefix" "$reloc/$NAME/bin/wineserver" -w 2>/dev/null || true
rm -rf "$reloc"
echo "   relocation + registration gate passed (cmd.exe ran, PipeASIO registered)"

echo "== [8/8] build audit: every patch verified against the shipped tarball =="
bash "$SRC/scripts/build-audit.sh" "$tarball"

echo
echo "OK: $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"
