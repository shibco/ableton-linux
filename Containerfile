# Build environment for Ableton Live 12 Wine.
#
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ARG LLVM_VERSION=21

# 1. LLVM apt repo (pinned major version) for a modern clang/lld on glibc 2.35.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
 && install -d -m0755 /etc/apt/keyrings \
 && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/llvm.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/llvm.asc] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-${LLVM_VERSION} main" \
      > /etc/apt/sources.list.d/llvm.list

# 2. toolchain + Wine build dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
      # toolchain: gcc for the Unix side, clang/lld for the PE side
      build-essential clang-${LLVM_VERSION} lld-${LLVM_VERSION} llvm-${LLVM_VERSION} \
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
      # driver; jack dev for winejack.drv.
      # (WineASIO itself weak-links jack at runtime, needs no dev headers)
      libasound2-dev libpulse-dev libjack-jackd2-dev \
      # TLS (Live online auth / pack downloads), USB display bridge, XDG portal
      libgnutls28-dev libusb-1.0-0-dev libudev-dev libdbus-1-dev \
 && rm -rf /var/lib/apt/lists/* \
 # Wine's configure looks for unversioned clang/lld; make ours the default.
 && for t in clang clang++ lld ld.lld llvm-dlltool llvm-ar llvm-strip llvm-ranlib llvm-readobj; do \
        ln -sf "$t-${LLVM_VERSION}" "/usr/bin/$t"; \
    done \
 && clang --version | head -1

# 3. ntsync UAPI header: jammy's linux-libc-dev is 5.15, but Wine needs
# linux/ntsync.h (kernel >= 6.14) or configure silently drops ntsync and every
# NT sync wait becomes a wineserver round trip. Vendored and sha256-pinned;
# see notes/ABLETON-WINE-NTSYNC-REGRESSION.md.
COPY vendor/ntsync-uapi/linux/ntsync.h /opt/ntsync-uapi/linux/ntsync.h

WORKDIR /work
