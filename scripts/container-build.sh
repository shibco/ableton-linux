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
SOURCE_TREE_SHA="${SOURCE_TREE_SHA:-}"
[[ "$SOURCE_TREE_SHA" =~ ^[0-9a-f]{64}$ ]] || {
    echo "!! SOURCE_TREE_SHA must be supplied by build.sh" >&2
    exit 1
}
CABEXTRACT_STATIC_SHA="${CABEXTRACT_STATIC_SHA:-}"
ABLETON_LINKD_SHA="${ABLETON_LINKD_SHA:-}"
[[ "$CABEXTRACT_STATIC_SHA" =~ ^[0-9a-f]{64}$ ]] || {
    echo "!! build.sh must supply the cabextract-static hash" >&2
    exit 1
}
[[ "$ABLETON_LINKD_SHA" =~ ^[0-9a-f]{64}$ ]] || {
    echo "!! build.sh must supply the ableton-linkd hash" >&2
    exit 1
}
[ "$(basename "$CONFIGURE_PREFIX")" = "$NAME" ] || {
    echo "!! INSTALL_PREFIX must end in /$NAME" >&2
    exit 2
}
DESTDIR="$WORK/stage"
PREFIX_ROOT="$DESTDIR$CONFIGURE_PREFIX"
npatch="$(ls "$SRC"/patches/[0-9][0-9][0-9][0-9]-*.patch | wc -l)"

# TSan reserves a fixed shadow address range. High-entropy ASLR can collide
# with that range, and newer runtimes may be unable to request process-local
# ADDR_NO_RANDOMIZE under a container's default seccomp policy. Probe this
# before the expensive Wine build.
#
# The default is auto: where the container cannot start TSan at all, require
# fails the whole build rather than just the sanitizer stage. Releases stay
# fail-closed without depending on this default -- auto records a non-release
# attestation, and check-release-build-info.sh refuses to pack, tag or publish
# a BUILD-INFO without the exact "TSan unit passed" record. CI sets require
# explicitly. skip is an explicit local, non-release mode.
PIPEASIO_TSAN_MODE="${PIPEASIO_TSAN_MODE:-auto}"
# shellcheck source=scripts/lib/tsan.sh
source "$SRC/scripts/lib/tsan.sh"
pipeasio_tsan_mode_valid "$PIPEASIO_TSAN_MODE" || {
    echo "!! PIPEASIO_TSAN_MODE must be require, auto, or skip" >&2
    exit 2
}

echo "== [preflight] compile the Push USB probes =="
read -r -a libusb_cflags <<< "$(pkg-config --cflags libusb-1.0)"
read -r -a libusb_libs <<< "$(pkg-config --libs libusb-1.0)"
for probe in pushusb push2usb push3usb; do
    gcc -std=c11 -O2 -Wall -Wextra -Werror "${libusb_cflags[@]}" \
        "$SRC/tools/$probe.c" "${libusb_libs[@]}" -o "$WORK/$probe-preflight"
done

tsan_enabled=1
tsan_record=""
if [ "$PIPEASIO_TSAN_MODE" = skip ]; then
    tsan_enabled=0
    tsan_record='TSan unit skipped (explicit mode; non-release build)'
    echo "== [preflight] TSan explicitly skipped; artifact will be marked non-release =="
else
    echo "== [preflight] verify TSan can start under this host/container policy =="
    tsan_canary_dir="$(mktemp -d /tmp/pipeasio-tsan-canary.XXXXXX)"
    tsan_canary_source="$tsan_canary_dir/canary.c"
    tsan_canary_binary="$tsan_canary_dir/canary"
    tsan_canary_log="$tsan_canary_dir/canary.log"
    printf '%s\n' \
        '#include <pthread.h>' \
        '#include <stdint.h>' \
        'static void *worker(void *arg) { return arg; }' \
        'int main(void) {' \
        '    pthread_t thread;' \
        '    void *result = 0;' \
        '    void *expected = (void *)(uintptr_t)0x1234;' \
        '    if (pthread_create(&thread, 0, worker, expected)) return 2;' \
        '    if (pthread_join(thread, &result)) return 3;' \
        '    return result != expected;' \
        '}' > "$tsan_canary_source"
    if ! gcc -std=c11 -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer \
            -fsanitize=thread -pthread "$tsan_canary_source" \
            -fsanitize=thread -pthread -o "$tsan_canary_binary"; then
        echo "!! failed to compile the mandatory TSan canary" >&2
        case "$tsan_canary_dir" in
            /tmp/pipeasio-tsan-canary.*) rm -rf -- "${tsan_canary_dir:?}" ;;
            *) echo "!! refusing to remove unexpected TSan canary path" >&2 ;;
        esac
        exit 1
    fi

    tsan_canary_failed=0
    for ((tsan_attempt = 1; tsan_attempt <= 3; ++tsan_attempt)); do
        if ! TSAN_OPTIONS=halt_on_error=1 "$tsan_canary_binary" >> "$tsan_canary_log" 2>&1; then
            tsan_canary_failed=1
            break
        fi
    done
    if [ "$tsan_canary_failed" -eq 1 ]; then
        cat "$tsan_canary_log" >&2
        if pipeasio_tsan_log_is_infrastructure_failure "$tsan_canary_log"; then
            if [ "$PIPEASIO_TSAN_MODE" = auto ]; then
                tsan_enabled=0
                tsan_record='TSan unit skipped (host ASLR/seccomp incompatibility; auto mode; non-release build)'
                echo "!! TSan cannot start under this host/container policy; auto mode marks this build non-release" >&2
            else
                echo "!! mandatory TSan cannot start under this host/container policy" >&2
                echo "!! use PIPEASIO_TSAN_MODE=auto only for a local non-release build" >&2
                case "$tsan_canary_dir" in
                    /tmp/pipeasio-tsan-canary.*) rm -rf -- "${tsan_canary_dir:?}" ;;
                    *) echo "!! refusing to remove unexpected TSan canary path" >&2 ;;
                esac
                exit 1
            fi
        else
            echo "!! TSan canary failed for an unknown reason; refusing to skip it" >&2
            case "$tsan_canary_dir" in
                /tmp/pipeasio-tsan-canary.*) rm -rf -- "${tsan_canary_dir:?}" ;;
                *) echo "!! refusing to remove unexpected TSan canary path" >&2 ;;
            esac
            exit 1
        fi
    else
        echo "   TSan startup canary passed three times"
    fi
    case "$tsan_canary_dir" in
        /tmp/pipeasio-tsan-canary.*) rm -rf -- "${tsan_canary_dir:?}" ;;
        *) echo "!! refusing to remove unexpected TSan canary path" >&2; exit 1 ;;
    esac
fi

if [ "$ARCH" == "aarch64" ]; then
    echo "== [0/8] FEX ARM64EC =="

    git clone --single-branch --branch=FEX-2608 --recursive --depth=1 https://github.com/FEX-Emu/FEX \
        && test -e /work/FEX/Source/Common/cpp-optparse/LICENSE

    cd /work/FEX
    mkdir build-arm64ec
    cd build-arm64ec
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../Data/CMake/toolchain_mingw.cmake -DCMAKE_INSTALL_LIBDIR=$PREFIX_ROOT/lib/wine/aarch64-windows -DENABLE_LTO=False -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DBUILD_TESTING=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DCMAKE_INSTALL_PREFIX=$PREFIX_ROOT ..
    ninja
    ninja install
    cd ..

    mkdir build-wow64
    cd build-wow64
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=../Data/CMake/toolchain_mingw.cmake -DCMAKE_INSTALL_LIBDIR=$PREFIX_ROOT/lib/wine/aarch64-windows -DENABLE_LTO=False -DMINGW_TRIPLE=aarch64-w64-mingw32 -DBUILD_TESTING=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DCMAKE_INSTALL_PREFIX=$PREFIX_ROOT ..
    ninja
    ninja install
    cd ..
    cd /work
fi

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
for p in "$SRC"/patches/[0-9][0-9][0-9][0-9]-*.patch; do
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

if [ "$ARCH" = "aarch64" ]; then
    CPPFLAGS="-I/opt/ntsync-uapi" ../wine-src/configure \
        --prefix="$CONFIGURE_PREFIX" \
        --enable-archs=arm64ec,aarch64,i386,x86_64 \
        --with-mingw=clang \
        --disable-tests
else
    CPPFLAGS="-I/opt/ntsync-uapi" ../wine-src/configure \
        --prefix="$CONFIGURE_PREFIX" \
        --enable-archs=i386,x86_64 \
        --disable-tests
fi
make -j"$JOBS"
make install DESTDIR="$DESTDIR"
mkdir -p "$(dirname "$CONFIGURE_PREFIX")"
ln -s "$PREFIX_ROOT" "$CONFIGURE_PREFIX"
"$PREFIX_ROOT/bin/wine" --version

bridge_pe="$PREFIX_ROOT/lib/wine/$ARCH-windows/libusb-1.0.dll"
bridge_unix="$PREFIX_ROOT/lib/wine/$ARCH-unix/libusb-1.0.so"
portal_unix="$PREFIX_ROOT/lib/wine/$ARCH-unix/comdlg32.so"
i386_bridge_pe="$PREFIX_ROOT/lib/wine/i386-windows/libusb-1.0.dll"
i386_bridge_unix="$PREFIX_ROOT/lib/wine/i386-unix/libusb-1.0.so"
[ -f "$bridge_pe" ] || { echo "!! Push USB bridge PE missing: $bridge_pe" >&2; exit 1; }
[ -f "$bridge_unix" ] || { echo "!! Push USB bridge Unix side missing: $bridge_unix" >&2; exit 1; }
[ -f "$portal_unix" ] || { echo "!! comdlg32 (XDG portal) missing: $portal_unix" >&2; exit 1; }
[ ! -e "$i386_bridge_pe" ] || { echo "!! Push USB bridge unexpectedly built for i386: $i386_bridge_pe" >&2; exit 1; }
[ ! -e "$i386_bridge_unix" ] || { echo "!! Push USB bridge unexpectedly built for i386: $i386_bridge_unix" >&2; exit 1; }

expected_exports=$'4 libusb_alloc_transfer\n8 libusb_bulk_transfer\n10 libusb_cancel_transfer\n12 libusb_claim_interface\n16 libusb_close\n26 libusb_error_name\n32 libusb_exit\n40 libusb_free_device_list\n50 libusb_free_transfer\n72 libusb_get_device_descriptor\n74 libusb_get_device_list\n110 libusb_handle_events_timeout\n116 libusb_hotplug_deregister_callback\n118 libusb_hotplug_register_callback\n120 libusb_init\n132 libusb_open\n140 libusb_release_interface\n154 libusb_set_option\n159 libusb_strerror\n161 libusb_submit_transfer'
actual_exports="$(llvm-readobj --coff-exports "$bridge_pe" | awk '
    /^Export / { ordinal = ""; name = "" }
    /Ordinal:/ { ordinal = $2 }
    /Name: libusb_/ { name = $2 }
    /^}/ && name != "" { print ordinal, name }
')"
if [ "$actual_exports" != "$expected_exports" ]; then
    echo "!! Push USB bridge export/ordinal mismatch" >&2
    diff -u <(printf '%s\n' "$expected_exports") <(printf '%s\n' "$actual_exports") || true
    exit 1
fi
readelf -d "$bridge_unix" | grep -F 'Shared library: [libusb-1.0.so.0]' >/dev/null
strings "$portal_unix" | grep -F 'org.freedesktop.portal.FileChooser' >/dev/null

# configure silently drops winealsa (ALSA MIDI) when libasound2-dev is absent: fail, don't ship without it.
winealsa_unix="$PREFIX_ROOT/lib/wine/$ARCH-unix/winealsa.so"
if [ ! -s "$winealsa_unix" ]; then
    echo "!! winealsa.so missing: libasound2-dev not present at configure time; no ALSA MIDI" >&2
    exit 1
fi

# configure also silently drops winegstreamer (mp3/mp4/wma import) without
# the gstreamer-1.0 dev packages — shipped unnoticed until issue #44.
winegstreamer_unix="$PREFIX_ROOT/lib/wine/$ARCH-unix/winegstreamer.so"
if [ ! -s "$winegstreamer_unix" ]; then
    echo "!! winegstreamer.so missing: libgstreamer1.0-dev/libgstreamer-plugins-base1.0-dev not present at configure time; no mp3/mp4/wma import" >&2
    exit 1
fi

# configure also silently drops ntsync without linux/ntsync.h; every NT sync
# wait then becomes a wineserver round trip (~1.3 cores with Live running).
# Shipped unnoticed twice in 2026-07. Check BOTH halves: the 07-12 build lost
# only the wineserver one.
if ! grep -q '^#define HAVE_LINUX_NTSYNC_H 1' "$WORK/build/include/config.h"; then
    echo "!! HAVE_LINUX_NTSYNC_H not set; linux/ntsync.h not seen at configure time" >&2
    exit 1
fi
# grep -c, not grep -q: -q exits on first match, strings dies of SIGPIPE and
# pipefail turns the success into a false "missing" (this killed a good build).
ntsync_srv="$(strings "$PREFIX_ROOT/bin/wineserver" | grep -c ntsync || true)"
ntsync_ntd="$(strings "$PREFIX_ROOT/lib/wine/$ARCH-unix/ntdll.so" | grep -c ntsync || true)"
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

echo "== [4/8] build PipeWire probe + PipeASIO 1.5.0 against THIS Wine (upstream CMake + CTest) =="
mkdir -p "$WORK/pipeasio"
tar xzf "$SRC/vendor/pipeasio-1.5.0.tar.gz" -C "$WORK/pipeasio" --strip-components=1
cd "$WORK/pipeasio"
# Apply the pipeasio patch series (patches/pipeasio/): every *.patch, sorted;
# the glob is the whole contract, no file list is hardcoded here.
nasio="$(ls "$SRC"/patches/pipeasio/*.patch 2>/dev/null | wc -l)"
[ "$nasio" -gt 0 ] || { echo "!! no pipeasio patches found in $SRC/patches/pipeasio" >&2; exit 1; }
for p in "$SRC"/patches/pipeasio/*.patch; do
    echo "   applying $(basename "$p")"
    patch -p1 --no-backup-if-mismatch -i "$p"
done
export PATH="$PREFIX_ROOT/bin:$PATH"          # this Wine's winegcc/winebuild take PATH priority
# 64-bit only (Live 12 is 64-bit). Built through upstream CMake, which drives
# the same winebuild/winegcc pipeline against this Wine's tools and headers
# (WINEBUILD/WINEGCC pinned below; the header probe follows winebuild to
# $PREFIX_ROOT/include). Hand-driving gcc/moc here is what broke PR #160 in
# CI: jammy's Qt 6.2.4 ships no pkg-config .pc files (Qt gained them in 6.3),
# so `pkg-config Qt6Widgets` expanded to nothing and g++ ran without Qt
# flags. Qt discovery must go through CMake, and jammy does ship Qt's CMake
# config files.
#   - PipeWire comes from the vendored SDK (Containerfile). Its .pc files say
#     prefix=/usr, so PKG_CONFIG_SYSROOT_DIR rewrites every -I/-L under
#     /opt/pipewire-sdk. Link-time only: the .so records DT_NEEDED
#     libpipewire-0.3.so.0 and resolves against the host PipeWire at runtime
#     (required client/daemon floor 1.4.2; the SDK is 1.6.2).
#   - --allow-shlib-undefined (native test executables only): the SDK's .so
#     wants glibc 2.38 (__isoc23_*) and this container has 2.35, so the
#     default no-allow-shlib-undefined check would fail the pw_probe and
#     test_pw_buffer_region links. Nothing in the ctest scope below calls
#     into libpipewire at runtime (stubbed there for the loader's sake).
#   - CC/CXX name the PATH-resolved compilers so the ccache shims keep
#     working; cmake's default /usr/bin/cc would bypass them.
PW_SDK=/opt/pipewire-sdk
PIPEASIO_BUILD_SETTINGS_PANEL="${PIPEASIO_BUILD_SETTINGS_PANEL:-ON}"
case "$PIPEASIO_BUILD_SETTINGS_PANEL" in
    ON|OFF) ;;
    *)
        echo "!! PIPEASIO_BUILD_SETTINGS_PANEL must be ON or OFF" >&2
        exit 2
        ;;
esac

# Install a tiny native preflight helper so setup can inspect both the loaded
# client library and pw_core_info.version without requiring pw-cli/pw-dump.
# It compiles on the oldest build host and records only PipeWire's stable
# soname, so the host's selected client closure remains authoritative.
pipewire_probe="$PREFIX_ROOT/bin/pipewire-version-probe"
pipewire_sdk_lib="$PW_SDK/usr/lib/$ARCH-linux-gnu/libpipewire-0.3.so"
test -s "$SRC/tools/pipewire-version-probe.c"
test -s "$pipewire_sdk_lib"
read -r -a pipewire_probe_cflags <<< "$(
    PKG_CONFIG_PATH="$PW_SDK/usr/lib/$ARCH-linux-gnu/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="$PW_SDK" \
        pkg-config --cflags libpipewire-0.3
)"
gcc -std=c11 -O2 -Wall -Wextra -Werror -fPIE -fstack-protector-strong \
    -D_FORTIFY_SOURCE=2 "${pipewire_probe_cflags[@]}" \
    "$SRC/tools/pipewire-version-probe.c" "$pipewire_sdk_lib" \
    -pie -Wl,--allow-shlib-undefined,-z,relro,-z,now \
    -o "$pipewire_probe"

pipewire_probe_needed="$(
    readelf -d "$pipewire_probe" \
        | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' \
        | sort
)"
if [ "$ARCH" = "aarch64" ]; then
    if [ "$pipewire_probe_needed" != $'ld-linux-aarch64.so.1\nlibc.so.6\nlibpipewire-0.3.so.0' ]; then
        echo "!! pipewire-version-probe has unexpected DT_NEEDED entries:" >&2
        printf '%s\n' "$pipewire_probe_needed" >&2
        exit 1
    fi
    if readelf -d "$pipewire_probe" | grep -qE 'RPATH|RUNPATH'; then
        echo "!! pipewire-version-probe carries an SDK/build rpath" >&2
        exit 1
    fi
else
    if [ "$pipewire_probe_needed" != $'libc.so.6\nlibpipewire-0.3.so.0' ]; then
        echo "!! pipewire-version-probe has unexpected DT_NEEDED entries:" >&2
        printf '%s\n' "$pipewire_probe_needed" >&2
        exit 1
    fi
    if readelf -d "$pipewire_probe" | grep -qE 'RPATH|RUNPATH'; then
        echo "!! pipewire-version-probe carries an SDK/build rpath" >&2
        exit 1
    fi

fi

# The vendored SDK library targets newer glibc than this floor container. Give
# --client a complete symbol stub whose version result is deterministic; this
# tests the helper's loader/API/output path without pretending to contact a
# daemon. Also run that path under ASan+UBSan. The no-argument daemon path is a
# release-machine integration test.
probe_stub_dir="$(mktemp -d /tmp/pipewire-probe-check.XXXXXX)"
printf '%s\n' \
    'const char *pw_get_library_version(void) { return "probe-check-1.0.5"; }' \
    > "$probe_stub_dir/stub.c"
nm -D "$pipewire_probe" \
    | awk '$1 == "U" && $2 ~ /^pw_/ && $2 != "pw_get_library_version" { print "void " $2 "(void) {}" }' \
    | sort -u >> "$probe_stub_dir/stub.c"
gcc -shared -fPIC -Wl,-soname,libpipewire-0.3.so.0 \
    -o "$probe_stub_dir/libpipewire-0.3.so.0" "$probe_stub_dir/stub.c"
test "$(LD_LIBRARY_PATH="$probe_stub_dir" "$pipewire_probe" --client)" = \
    'client=probe-check-1.0.5'

probe_sanitized="$probe_stub_dir/pipewire-version-probe-sanitized"
gcc -std=c11 -O1 -g -Wall -Wextra -Werror -fPIE -fno-omit-frame-pointer \
    -fsanitize=address,undefined "${pipewire_probe_cflags[@]}" \
    "$SRC/tools/pipewire-version-probe.c" "$pipewire_sdk_lib" \
    -pie -fsanitize=address,undefined \
    -Wl,--allow-shlib-undefined,-z,relro,-z,now \
    -o "$probe_sanitized"
test "$(
    LD_LIBRARY_PATH="$probe_stub_dir" \
    ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_leaks=0 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$probe_sanitized" --client
)" = 'client=probe-check-1.0.5'
case "$probe_stub_dir" in
    /tmp/pipewire-probe-check.*) rm -rf -- "${probe_stub_dir:?}" ;;
    *) echo "!! refusing to remove unexpected probe check path: $probe_stub_dir" >&2; exit 1 ;;
esac
echo "   pipewire-version-probe: client stub + ASan/UBSan verification passed"

pipeasio_cmake_configure() {
    local build_dir="$1"
    shift
    PKG_CONFIG_PATH="$PW_SDK/usr/lib/$ARCH-linux-gnu/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="$PW_SDK" \
    CC=gcc CXX=g++ \
    cmake -S . -B "$build_dir" -G Ninja \
        -DWINEBUILD="$PREFIX_ROOT/bin/winebuild" \
        -DWINEGCC="$PREFIX_ROOT/bin/winegcc" \
        "$@"
}

## The SDK's libpipewire was built against a newer glibc than this reproducible
## jammy container.  The selected unit tests use PipeWire types but make no
## runtime pw_* calls, so give their loader a tiny symbol-compatible stub.  The
## real driver is still linked by soname and the artifact gate below verifies it.
pipeasio_make_test_stub() {
    local build_dir="$1"
    local stub_dir="$2"
    printf '%s\n' 'void pipeasio_pw_test_stub(void) {}' > "$stub_dir/stub.c"
    for t in "$build_dir"/tests/unit/test_*; do
        [ -f "$t" ] && [ -x "$t" ] || continue
        # || true: a statically-satisfied binary makes nm -D return nonzero,
        # and pipefail must not turn that into a false build failure.
        nm -D "$t" 2>/dev/null \
            | awk '$1 == "U" && $2 ~ /^pw_/ { print "void " $2 "(void) {}" }' \
            || true
    done | sort -u >> "$stub_dir/stub.c"
    gcc -shared -fPIC -Wl,-soname,libpipewire-0.3.so.0 \
        -o "$stub_dir/libpipewire-0.3.so.0" "$stub_dir/stub.c"
}

pipeasio_ctest_units() {
    local build_dir="$1"
    shift
    local stub_dir
    stub_dir="$(mktemp -d /tmp/pipeasio-ctest.XXXXXX)"
    pipeasio_make_test_stub "$build_dir" "$stub_dir"
    local ctest_status=0
    env LD_LIBRARY_PATH="$stub_dir" "$@" \
        ctest --test-dir "$build_dir" -L '^unit$' \
            --no-tests=error --output-on-failure --stop-on-failure || ctest_status=$?
    case "$stub_dir" in
        /tmp/pipeasio-ctest.*) rm -rf -- "${stub_dir:?}" ;;
        *) echo "!! refusing to remove unexpected test stub path: $stub_dir" >&2; exit 1 ;;
    esac
    return "$ctest_status"
}

pipeasio_unit_targets() {
    local build_dir="$1"
    ctest --test-dir "$build_dir" -N -L '^unit$' 2>/dev/null \
        | sed -n 's/^ *Test *#[0-9][0-9]*: *//p'
}

pipeasio_ctest_nonintegration() {
    local build_dir="$1"
    shift
    local stub_dir
    stub_dir="$(mktemp -d /tmp/pipeasio-ctest.XXXXXX)"
    pipeasio_make_test_stub "$build_dir" "$stub_dir"
    env LD_LIBRARY_PATH="$stub_dir" "$@" \
        ctest --test-dir "$build_dir" -LE '^integration$' \
            --no-tests=error --output-on-failure
    case "$stub_dir" in
        /tmp/pipeasio-ctest.*) rm -rf -- "${stub_dir:?}" ;;
        *) echo "!! refusing to remove unexpected test stub path: $stub_dir" >&2; exit 1 ;;
    esac
}

# Production build. BUILD_SETTINGS_PANEL=ON means "build when Qt is present",
# matching upstream: Qt discovery is quiet and a missing toolkit does not stop
# the driver. The official container has Qt and CI separately requires the
# complete panel payload; a downstream/no-Qt build remains a valid driver-only
# artifact and is recorded as such in BUILD-INFO.
pipeasio_cmake_configure build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CONFIGURE_PREFIX" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \
    -DBUILD_SETTINGS_PANEL="$PIPEASIO_BUILD_SETTINGS_PANEL" \
    -DBUILD_TESTS=ON
cmake --build build -j "$JOBS"

panel_state="skipped (disabled)"
if [ -x build/gui/pipeasio-settings ]; then
    panel_state="built"
elif [ "$PIPEASIO_BUILD_SETTINGS_PANEL" = ON ]; then
    panel_state="skipped (Qt6 Widgets unavailable)"
fi
echo "   panel: $panel_state"

# Run upstream's complete non-integration CTest scope: registration/install
# layout tests, Linux-native unit tests, the WoW64 ABI check and the headless Qt
# panel test when available. Tests labelled integration need a live daemon,
# installed Wine registration and real audio nodes; those remain release-machine
# tests rather than being reported as exercised here.
pipeasio_ctest_nonintegration build

# Prove the actual missing-Qt contract, rather than inferring it from an option:
# force Qt discovery off, build and test the driver, then run upstream's staged
# install and require the driver aliases while forbidding a partial panel.
pipeasio_cmake_configure build-noqt \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CONFIGURE_PREFIX" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \
    -DCMAKE_DISABLE_FIND_PACKAGE_Qt6=TRUE \
    -DBUILD_SETTINGS_PANEL=ON \
    -DBUILD_TESTS=ON
mapfile -t noqt_unit_targets < <(pipeasio_unit_targets build-noqt)
[ "${#noqt_unit_targets[@]}" -gt 0 ] || {
    echo "!! no unit-labelled CTest targets found in the no-Qt build" >&2
    exit 1
}
cmake --build build-noqt -j "$JOBS" --target \
    pipeasio64 "${noqt_unit_targets[@]}"
pipeasio_ctest_nonintegration build-noqt
noqt_stage="$(mktemp -d /tmp/pipeasio-noqt-install.XXXXXX)"
DESTDIR="$noqt_stage" cmake --install build-noqt
noqt_root="$noqt_stage$CONFIGURE_PREFIX"
test -s "$noqt_root/lib/wine/$ARCH-windows/pipeasio64.dll"
test -s "$noqt_root/lib/wine/$ARCH-unix/pipeasio64.dll.so"
test "$(readlink "$noqt_root/lib/wine/$ARCH-windows/pipeasio.dll")" = pipeasio64.dll
test "$(readlink "$noqt_root/lib/wine/$ARCH-unix/pipeasio.dll.so")" = pipeasio64.dll.so
test ! -e "$noqt_root/bin/pipeasio-settings"
test ! -e "$noqt_root/share/applications/pipeasio-settings.desktop"
test ! -e "$noqt_root/share/icons/hicolor/scalable/apps/pipeasio.svg"
case "$noqt_stage" in
    /tmp/pipeasio-noqt-install.*) rm -rf -- "${noqt_stage:?}" ;;
    *) echo "!! refusing to remove unexpected no-Qt stage: $noqt_stage" >&2; exit 1 ;;
esac
echo "   no-Qt gate: CMake build, non-integration CTest and staged driver install passed"

# Sanitizer gates. Upstream's PIPEASIO_ASAN mode instruments both the driver
# and native targets with ASan+UBSan; CTest verifies the imports before running
# the unit/panel suites. TSan is applied to the native unit targets (including
# the threaded admission-gate and handle-table tests). Running the Wine driver
# under TSan still needs a live PipeWire integration environment and is not
# claimed by this build.
pipeasio_cmake_configure build-asan \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \
    -DBUILD_SETTINGS_PANEL="$PIPEASIO_BUILD_SETTINGS_PANEL" \
    -DBUILD_TESTS=ON \
    -DPIPEASIO_ASAN=ON 
cmake --build build-asan -j "$JOBS"
pipeasio_ctest_nonintegration build-asan \
    ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_leaks=0 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
asan_panel_state="unavailable"
if [ -x build-asan/gui/pipeasio-settings ]; then
    asan_panel_state="passed"
fi

if [ "$tsan_enabled" -eq 1 ]; then
    pipeasio_cmake_configure build-tsan \
        -DCMAKE_BUILD_TYPE=Debug \
        -DCMAKE_C_FLAGS="-fsanitize=thread -fno-omit-frame-pointer -g" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread -Wl,--allow-shlib-undefined" \
        -DBUILD_SETTINGS_PANEL=OFF \
        -DBUILD_TESTS=ON
    mapfile -t tsan_unit_targets < <(pipeasio_unit_targets build-tsan)
    [ "${#tsan_unit_targets[@]}" -gt 0 ] || {
        echo "!! no unit-labelled CTest targets found in the TSan build" >&2
        exit 1
    }
    cmake --build build-tsan -j "$JOBS" --target "${tsan_unit_targets[@]}"
    tsan_test_log="$(mktemp /tmp/pipeasio-tsan-ctest.XXXXXX)"
    if pipeasio_ctest_units build-tsan \
            TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1 \
            > "$tsan_test_log" 2>&1; then
        cat "$tsan_test_log"
        tsan_record='TSan unit passed'
    else
        tsan_test_status=$?
        cat "$tsan_test_log" >&2
        if [ "$PIPEASIO_TSAN_MODE" = auto ] \
           && pipeasio_tsan_log_is_infrastructure_failure "$tsan_test_log"; then
            tsan_record='TSan unit skipped (host ASLR/seccomp incompatibility; auto mode; non-release build)'
            echo "!! TSan CTest hit a recognized startup incompatibility; auto mode marks this build non-release" >&2
        else
            echo "!! TSan CTest failed; races, test failures, and unknown errors are never auto-skipped" >&2
            case "$tsan_test_log" in
                /tmp/pipeasio-tsan-ctest.*) rm -f -- "${tsan_test_log:?}" ;;
                *) echo "!! refusing to remove unexpected TSan log path" >&2 ;;
            esac
            exit "$tsan_test_status"
        fi
    fi
    case "$tsan_test_log" in
        /tmp/pipeasio-tsan-ctest.*) rm -f -- "${tsan_test_log:?}" ;;
        *) echo "!! refusing to remove unexpected TSan log path" >&2; exit 1 ;;
    esac
fi
[ -n "$tsan_record" ] || { echo "!! internal error: missing TSan result" >&2; exit 1; }
echo "   sanitizers: ASan+UBSan unit/panel=$asan_panel_state; $tsan_record"

# Install through upstream CMake so its layout, Qt data files and Wine alias
# contract are exercised. The project has its own atomic registration path, so
# discard upstream's generic helper after testing its install rule.
DESTDIR="$DESTDIR" cmake --install build
rm -f -- "$PREFIX_ROOT/bin/pipeasio-register"

# Must link the host's PipeWire by soname, with no SDK/build path baked in.
readelf -d "$PREFIX_ROOT/lib/wine/$ARCH-unix/pipeasio64.dll.so" \
    | grep -F 'Shared library: [libpipewire-0.3.so.0]' >/dev/null
if readelf -d "$PREFIX_ROOT/lib/wine/$ARCH-unix/pipeasio64.dll.so" | grep -qE 'RPATH|RUNPATH'; then
    echo "!! pipeasio64.dll.so carries an rpath into the build container" >&2
    exit 1
fi

# Panel deployment is all-or-nothing. A complete trio is optional for generic
# builds, but a binary without its desktop file/icon (or vice versa) is never a
# valid artifact.
panel_payload=(
    "$PREFIX_ROOT/bin/pipeasio-settings"
    "$PREFIX_ROOT/share/applications/pipeasio-settings.desktop"
    "$PREFIX_ROOT/share/icons/hicolor/scalable/apps/pipeasio.svg"
)
panel_payload_count=0
for f in "${panel_payload[@]}"; do
    [ -e "$f" ] && panel_payload_count=$((panel_payload_count+1))
done
if [ "$panel_state" = built ]; then
    [ "$panel_payload_count" -eq 3 ] || {
        echo "!! incomplete settings-panel payload after CMake install ($panel_payload_count/3)" >&2
        exit 1
    }
    test -x "$PREFIX_ROOT/bin/pipeasio-settings"
    test -s "$PREFIX_ROOT/share/applications/pipeasio-settings.desktop"
    test -s "$PREFIX_ROOT/share/icons/hicolor/scalable/apps/pipeasio.svg"
    if readelf -d "$PREFIX_ROOT/bin/pipeasio-settings" | grep -qE 'RPATH|RUNPATH'; then
        echo "!! pipeasio-settings carries an rpath into the build container" >&2
        exit 1
    fi
elif [ "$panel_payload_count" -ne 0 ]; then
    echo "!! panel was skipped but CMake installed a partial payload ($panel_payload_count/3)" >&2
    exit 1
fi

echo "== [5/8] strip + prune (dev files served their purpose in [4/8]; nothing below runs on user machines) =="
# Debug info is ~3/4 of every PE builtin and ~5/6 of the unix halves. Exports,
# resources, .rodata literals (the audit fingerprints) and the builtin signature
# all live outside the symtab; the relocation gate re-runs the stripped tree.
# .dll16/.tlb/.vxd etc. are not COFF and stay untouched.
find "$PREFIX_ROOT/lib/wine" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' \
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
pipewire_probe_sha="$(sha256sum "$pipewire_probe" | awk '{print $1}')"

pipeasio_pe="$PREFIX_ROOT/lib/wine/$ARCH-windows/pipeasio64.dll"
pipeasio_unix="$PREFIX_ROOT/lib/wine/$ARCH-unix/pipeasio64.dll.so"
test -s "$pipeasio_pe"
test -s "$pipeasio_unix"
pipeasio_pe_sha="$(sha256sum "$pipeasio_pe" | awk '{print $1}')"
pipeasio_unix_sha="$(sha256sum "$pipeasio_unix" | awk '{print $1}')"
echo "   PipeASIO: PE $pipeasio_pe_sha / Unix $pipeasio_unix_sha"

echo "== [6/8] package =="
# Keep the resolved package closure beside BUILD-INFO so its digest is useful
# for more than equality testing. This makes a toolchain change inspectable and
# prevents a same-source rebuild from silently claiming the same builder.
builder_packages="$PREFIX_ROOT/ABLETON-WINE-BUILD-PACKAGES.txt"
test -s /opt/build-env-packages.txt
install -m644 /opt/build-env-packages.txt "$builder_packages"
LC_ALL=C sort -c -u "$builder_packages"
builder_packages_sha="$(sha256sum "$builder_packages" | awk '{print $1}')"
# Stamp per-patch sha256s into the tree; build-audit.sh diffs this against patches/SERIES.sha256.
stack_stamp="$PREFIX_ROOT/ABLETON-WINE-PATCH-STACK.txt"
( cd "$SRC/patches" && sha256sum [0-9][0-9][0-9][0-9]-*.patch pipeasio/*.patch ) > "$stack_stamp"
stack_sha="$(sha256sum "$stack_stamp" | awk '{print $1}')"
build_info="$PREFIX_ROOT/ABLETON-WINE-BUILD-INFO.txt"
{
    echo "dist-version: $VERSION"
    echo "wine:         $("$PREFIX_ROOT/bin/wine" --version)"
    echo "base:         giang17/wine d2d1-dcomp-11.13 @ 5c23dd1c"
    echo "prefix:       $CONFIGURE_PREFIX (configure-time only; tarball is relocatable, see relocation gate)"
    #echo "patches:      $((npatch + nasio))"     # wine series + pipeasio series
    echo "wine-patches: $npatch"
    #echo "pipeasio-patches: $nasio"
    echo "patch-head:   $patch_head"
    echo "patch-stack:  $stack_sha"
    echo "source-tree:  $SOURCE_TREE_SHA"
    echo "builder-packages: $builder_packages_sha"
    echo "cabextract-static: $CABEXTRACT_STATIC_SHA"
    echo "ableton-linkd: $ABLETON_LINKD_SHA"
    echo "pipeasio:     1.5.0"
    echo "pipewire-floor: 1.4.2 (required for both client library and daemon at install and driver startup)"
    echo "pipewire-version-probe: $pipewire_probe_sha"
    echo "pipewire-version-probe-tests: client-stub+ASan+UBSan passed"
    if [ "$panel_state" = built ]; then
        echo "pipeasio-panel: built"
        echo "pipeasio-settings: $(sha256sum "$PREFIX_ROOT/bin/pipeasio-settings" | awk '{print $1}') (Qt 6.2 link)"
    else
        echo "pipeasio-panel: skipped"
        echo "pipeasio-settings: $panel_state"
    fi
    if [ "$panel_state" = built ]; then
        echo "pipeasio-tests: CTest non-integration scope passed (unit, registration/layout, ABI, panel)"
    else
        echo "pipeasio-tests: CTest non-integration scope passed (unit, registration/layout, ABI; panel skipped)"
    fi
    echo "pipeasio-no-qt: CMake driver build/install + non-integration CTest passed"
    if [ "$asan_panel_state" = passed ]; then
        echo "pipeasio-sanitizers: ASan+UBSan unit+panel passed (driver imports verified); $tsan_record"
    else
        echo "pipeasio-sanitizers: ASan+UBSan unit passed (driver imports verified; panel unavailable); $tsan_record"
    fi
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
install -m755 "$pipewire_probe" "$OUT/pipewire-version-probe"
test "$(sha256sum "$OUT/pipewire-version-probe" | awk '{print $1}')" = "$pipewire_probe_sha"
tarball="$OUT/${NAME}-${VERSION}.tar.zst"
# --long=27 (128 MiB window, zstd's default decode limit: no flags needed to unpack)
# lets the i386/$ARCH builtin pairs dedup against each other.
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
nm -D "$reloc/$NAME/lib/wine/$ARCH-unix/pipeasio64.dll.so" \
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
bash "$SRC/scripts/build-audit.sh" --source-tree-sha "$SOURCE_TREE_SHA" "$tarball"

# zstd deliberately creates output files with mode 0600.  Under rootful Docker
# that leaves the bind-mounted tarball readable only by root, while build.sh's
# independent audit and promotion run as the invoking host user.  Publish the
# completed, container-verified output set with explicit portable modes.
chmod 0644 -- \
    "$OUT/BUILD-INFO-${VERSION}.txt" \
    "$OUT/BUILD-INFO.txt" \
    "$tarball" \
    "$tarball.sha256"
chmod 0755 -- "$OUT/pipewire-version-probe"

echo
echo "OK: $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"
