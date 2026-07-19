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

# 1. Bootstrap tools + LLVM apt repo. This step alone installs from the live
# archive: apt needs ca-certificates before it can reach the https snapshot
# service. Tools only (ca-certificates/curl/gnupg) — nothing here is linked
# into shipped artifacts.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
 && install -d -m0755 /etc/apt/keyrings \
 && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/llvm.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/llvm.asc] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-${LLVM_VERSION} main" \
      > /etc/apt/sources.list.d/llvm.list \
 # From here on, jammy resolves against the pinned snapshot only.
 && for suite in jammy jammy-updates jammy-security; do \
        echo "deb https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT} $suite main restricted universe multiverse"; \
    done > /etc/apt/sources.list

# 2. toolchain + Wine build dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
      # toolchain: gcc for the Unix side, clang/lld (exact-pinned) for the PE side
      build-essential \
      clang-${LLVM_VERSION}=${LLVM_PKG_VERSION} \
      lld-${LLVM_VERSION}=${LLVM_PKG_VERSION} \
      llvm-${LLVM_VERSION}=${LLVM_PKG_VERSION} \
      flex bison perl gettext pkg-config \
      git xz-utils zstd python3 \
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
      # jammy package (jammy's 0.3.48 predates the thread-utils API it needs).
      libasound2-dev libpulse-dev \
      # TLS (Live online auth / pack downloads), USB display bridge, XDG portal
      libgnutls28-dev libusb-1.0-0-dev libudev-dev libdbus-1-dev \
 && rm -rf /var/lib/apt/lists/* \
 # Wine's configure looks for unversioned clang/lld; make ours the default.
 && for t in clang clang++ lld ld.lld llvm-dlltool llvm-ar llvm-strip llvm-ranlib llvm-readobj; do \
        ln -sf "$t-${LLVM_VERSION}" "/usr/bin/$t"; \
    done \
 && clang --version | head -1 \
 # Record the full build-environment package set for BUILD-INFO / drift diffing.
 && dpkg-query -W -f '${Package} ${Version}\n' | sort > /opt/build-env-packages.txt

# 3. ntsync UAPI header: jammy's linux-libc-dev is 5.15, but Wine needs
# linux/ntsync.h (kernel >= 6.14) or configure silently drops ntsync and every
# NT sync wait becomes a wineserver round trip. Vendored and sha256-pinned;
# see notes/ABLETON-WINE-NTSYNC-REGRESSION.md.
COPY vendor/ntsync-uapi/linux/ntsync.h /opt/ntsync-uapi/linux/ntsync.h

# 4. PipeWire SDK for PipeASIO: headers + link-time .so, vendored as Ubuntu's
# 1.6.2 debs and sha256-pinned (build.sh verifies). Link-time only — the
# produced pipeasio64.dll.so records DT_NEEDED libpipewire-0.3.so.0 and
# resolves against the user's PipeWire at runtime (floor: 0.3.56, the first
# release with pw_context_get_data_loop + pw_data_loop_set_thread_utils;
# container-build.sh gates both). jammy's own 0.3.48 is too old to compile it.
COPY vendor/pipewire-sdk/*.deb /tmp/pipewire-sdk/
RUN for d in /tmp/pipewire-sdk/*.deb; do dpkg-deb -x "$d" /opt/pipewire-sdk; done \
 && ln -sf libpipewire-0.3.so.0 /opt/pipewire-sdk/usr/lib/x86_64-linux-gnu/libpipewire-0.3.so \
 && rm -rf /tmp/pipewire-sdk \
 && test -e /opt/pipewire-sdk/usr/include/pipewire-0.3/pipewire/pipewire.h

WORKDIR /work
