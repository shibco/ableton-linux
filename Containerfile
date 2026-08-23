# Build environment for Ableton Live 12 Wine.
#
# Every input is pinned: base image by digest, the Ubuntu archive by snapshot
# date, the LLVM toolchain by exact package version, the PipeWire SDK and
# ntsync header as sha256-checked vendored files. Rebuilding from the same
# git tree must not pick up drifted toolchains or libraries — between
# 2026.07.17.3 and 2026.07.18.1 an unpinned rebuild changed pipeasio-unix and
# libusb-pe with no source change (see BUILD-INFO hashes). Bumping any pin is
# a deliberate commit, and PE/unix artifact hashes in BUILD-INFO move with it.
FROM docker.io/library/ubuntu:22.04@sha256:0e0a0fc6d18feda9db1590da249ac93e8d5abfea8f4c3c0c849ce512b5ef8982

ENV DEBIAN_FRONTEND=noninteractive
ARG LLVM_VERSION=21
# apt.llvm.org is a moving snapshot repo with no archive service, so the exact
# package version is pinned. When it ages out of the repo the install fails
# loudly: bump the pin, rebuild, expect PE hashes in BUILD-INFO to change.
ARG LLVM_PKG_VERSION=1:21.1.8~++20251221032842+2078da43e25a-1~exp1~20251221153008.77
# Ubuntu archive state used for every jammy package below (snapshot.ubuntu.com).
ARG UBUNTU_SNAPSHOT=20260718T000000Z
ARG CA_CERTIFICATES_VERSION=20260601~22.04.1
ARG ARCH

# 1. Establish every package source before the first apt operation. The pinned
# base image carries Ubuntu's archive key but not a CA bundle. The one bootstrap
# transaction therefore relies on apt's signed InRelease metadata while TLS
# peer checking is temporarily unavailable; it can install only the
# ca-certificates bytes named by the dated Ubuntu snapshot. Every later fetch
# uses normal TLS verification. The LLVM repository key is vendored and
# sha256-pinned rather than fetched from a moving URL during the build.
COPY vendor/llvm-apt-key.asc vendor/llvm-apt-key.sha256 /tmp/llvm-key/
RUN cd /tmp/llvm-key \
 && sha256sum -c llvm-apt-key.sha256 \
 && install -d -m0755 /etc/apt/keyrings \
 && install -m0644 llvm-apt-key.asc /etc/apt/keyrings/llvm.asc \
 && for suite in jammy jammy-updates jammy-security; do \
        echo "deb https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT} $suite main restricted universe multiverse"; \
    done > /etc/apt/sources.list \
 && rm -f /etc/apt/sources.list.d/* \
 && apt-get -o Acquire::https::Verify-Peer=false update \
 && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
      ca-certificates=${CA_CERTIFICATES_VERSION} \
 && apt-get update \
 && echo "deb [signed-by=/etc/apt/keyrings/llvm.asc] https://apt.llvm.org/jammy/ llvm-toolchain-jammy-${LLVM_VERSION} main" \
      > /etc/apt/sources.list.d/llvm.list \
 && rm -rf /tmp/llvm-key /var/lib/apt/lists/*

# 2. toolchain + Wine build dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
      # toolchain: gcc for the Unix side, clang/lld (exact-pinned) for the PE side
      build-essential \
      clang-${LLVM_VERSION}=${LLVM_PKG_VERSION} \
      lld-${LLVM_VERSION}=${LLVM_PKG_VERSION} \
      llvm-${LLVM_VERSION}=${LLVM_PKG_VERSION} \
      ccache \
      flex bison perl gettext pkg-config \
      git xz-utils zstd python3 \
      # PipeASIO builds and installs through upstream CMake (drives
      # winebuild/winegcc, the optional Qt AUTOMOC panel, CTest, and the
      # ASan+UBSan/TSan gates). GCC's sanitizer runtimes come with this
      # toolchain/build-essential closure.
      cmake ninja-build \
      # X11 / GL / Vulkan (the d2d1-dcomp + winex11 stack the fixes live in)
      libx11-dev libxext-dev libxrandr-dev libxrender-dev libxi-dev \
      libxfixes-dev libxcursor-dev libxcomposite-dev libxinerama-dev \
      libxxf86vm-dev libxkbcommon-dev \
      libgl-dev libglu1-mesa-dev libegl-dev libvulkan-dev \
      # fonts (plugin editors, Live UI)
      libfreetype-dev libfontconfig-dev \
      # audio: ALSA is REQUIRED — winealsa.drv (Wine's ALSA MIDI + audio backend)
      # is silently dropped by configure without libasound2-dev, which leaves Live
      # with no hardware MIDI (only "Computer Keyboard"); pulse for wine's own
      # driver. PipeASIO builds against the vendored PipeWire SDK below, not a
      # jammy package (jammy's 0.3.48 is far below upstream's 1.4.2 floor).
      libasound2-dev libpulse-dev \
      # pipeasio-settings (the native Qt panel shipped in the official
      # runtime, issue #60). Built against jammy's Qt 6.2 so the binary runs on any host
      # Qt >= 6.2. Discovery is CMake-only: jammy's Qt 6.2.4 packaging ships
      # CMake config files but no pkg-config .pc files (Qt gained those in
      # 6.3 — probing with pkg-config here fails silently, CI run
      # 31287663024). qt6-base-dev-tools carries moc for AUTOMOC;
      # qt6-qpa-plugins carries the offscreen platform plugin the headless
      # test_panel run needs. The packaging gate also configures with Qt
      # discovery forcibly disabled and proves that a driver-only CMake
      # build/install remains valid.
      qt6-base-dev qt6-base-dev-tools qt6-qpa-plugins \
      # media import: without these, configure silently drops winegstreamer
      # and mp3/mp4/wma import just fails (issue #44). Actual codec plugins
      # still come from the user's host GStreamer install at runtime.
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      # TLS (Live online auth / pack downloads), USB display bridge, XDG portal
      libgnutls28-dev libusb-1.0-0-dev libudev-dev libdbus-1-dev \
      # python3 packaging module for FEX
      python3-packaging \
 && rm -rf /var/lib/apt/lists/* \
 # Wine's configure looks for unversioned clang/lld; make ours the default.
 && for t in clang clang++ lld ld.lld llvm-dlltool llvm-ar llvm-strip llvm-ranlib llvm-readobj; do \
        ln -sf "$t-${LLVM_VERSION}" "/usr/bin/$t"; \
    done \
 && clang --version | head -1 \
 # ccache masquerade: CI wants a warm build cache across runs (see build.sh's
 # /ccache mount). Ubuntu's ccache package only ships gcc/g++ shims in
 # /usr/lib/ccache/; configure finds both gcc and clang by plain PATH lookup
 # (see above), so a symlink-per-compiler-name directory ahead of /usr/bin on
 # PATH (below) covers clang/clang++ too. ccache itself resolves the *real*
 # compiler by searching PATH past its own directory — no wrapper scripts or
 # --cc-cmd changes needed. A local build with nothing mounted at /ccache
 # just gets an empty, container-local cache: harmless, no behaviour change.
 && mkdir -p /usr/lib/ccache-shims \
 && for t in gcc g++ clang clang++; do \
        ln -sf "$(command -v ccache)" "/usr/lib/ccache-shims/$t"; \
    done \
 # Record the full build-environment package set for BUILD-INFO / drift diffing.
 && dpkg-query -W -f '${Package} ${Version}\n' | sort > /opt/build-env-packages.txt

# ccache's shim directory must come before the real compilers on PATH.
# CCACHE_DIR is a fixed mountpoint build.sh binds a persistent host directory
# onto — /ccache with nothing mounted (a plain local `podman build`, not CI)
# just means an empty, container-local cache each run.
ENV PATH="/usr/lib/ccache-shims:${PATH}:/opt/llvm-mingw-ucrt-aarch64/bin"
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=5G

# 3. ntsync UAPI header: jammy's linux-libc-dev is 5.15, but Wine needs
# linux/ntsync.h (kernel >= 6.14) or configure silently drops ntsync and every
# NT sync wait becomes a wineserver round trip. Vendored and sha256-pinned.
COPY vendor/ntsync-uapi/linux/ntsync.h /opt/ntsync-uapi/linux/ntsync.h

# 4. PipeWire SDK for PipeASIO: headers, .pc files + link-time .so, vendored
# as Ubuntu's 1.6.2 debs and sha256-pinned (build.sh verifies). Link-time
# only — the produced pipeasio64.dll.so records DT_NEEDED
# libpipewire-0.3.so.0 and resolves against the user's PipeWire at runtime
# (floor: 1.4.2, upstream's build-time pkg-config minimum; container-build.sh
# points cmake at the SDK's .pc files via PKG_CONFIG_SYSROOT_DIR). jammy's
# own 0.3.48 is too old to compile it.
COPY vendor/pipewire-sdk/*.deb /tmp/pipewire-sdk/
RUN for d in /tmp/pipewire-sdk/*.deb; do dpkg-deb -x "$d" /opt/pipewire-sdk; done \
 && ln -sf libpipewire-0.3.so.0 /opt/pipewire-sdk/usr/lib/$ARCH-linux-gnu/libpipewire-0.3.so \
 && rm -rf /tmp/pipewire-sdk \
 && test -e /opt/pipewire-sdk/usr/include/pipewire-0.3/pipewire/pipewire.h

# 5 FEX ARM64EC Stuff
COPY vendor/llvm-mingw-arm64ec-aarch64.tar.xz /tmp/llvm-mingw-ucrt-aarch64.tar.xz
RUN if [ "$ARCH" = "aarch64" ]; then \
    mkdir -p /opt/llvm-mingw-ucrt-aarch64 \
    && tar -xf /tmp/llvm-mingw-ucrt-aarch64.tar.xz --directory /opt/llvm-mingw-ucrt-aarch64 \
    && mv /opt/llvm-mingw-ucrt-aarch64/llvm-mingw-20250920-ucrt-ubuntu-22.04-aarch64/* /opt/llvm-mingw-ucrt-aarch64 \
    && rm -rf /opt/llvm-mingw-ucrt-aarch64/llvm-mingw-20250920-ucrt-ubuntu-22.04-aarch64 \
    && rm -rf /tmp/llvm-mingw-ucrt-aarch64.tar.xz \
    && test -e /opt/llvm-mingw-ucrt-aarch64/bin/arm64ec-w64-mingw32-clang \
;fi

# 6 x86_64 compilation target on aarch64 for pipeasio
RUN if [ "ARCH" = "aarch64" ]; then \ 
    dpkg --add-architecture amd64 \
    && apt update \
    && apt install -y  --no-install-recommends clang lld libc6-dev-amd64-cross libstdc++-11-dev-amd64-cross \
    && rm -rf /var/lib/apt/lists/* \
;fi

WORKDIR /work


