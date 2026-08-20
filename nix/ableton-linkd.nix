{
  stdenv,
  lib,
  zstd,
  # Source inputs
  daemonSrc, # tools/ableton-linkd.cpp
  linkSrc, # vendor/link-4.0.tar.zst (Ableton Link SDK, header-only)
  linkSha256, # vendor/link.sha256 — the pin `make verify` checks
}:

stdenv.mkDerivation {
  pname = "ableton-linkd";
  version = "4.0"; # tracks the vendored Link SDK; the daemon carries no version

  src = linkSrc;

  nativeBuildInputs = [ zstd ];

  # The tarball ships the Link repo files at its root (./include, ./modules).
  unpackPhase = ''
    runHook preUnpack
    # Checksum gate: nix already hashes the store path, but this proves the
    # tarball is the one vendor/link.sha256 pins — the drift the container
    # build's `sha256sum -c link.sha256` catches.
    expected=$(awk '$2 == "link-4.0.tar.zst" { print $1 }' ${linkSha256})
    [ -n "$expected" ] || { echo "!! vendor/link.sha256 does not pin link-4.0.tar.zst" >&2; exit 1; }
    actual=$(sha256sum < $src | awk '{ print $1 }')
    [ "$actual" = "$expected" ] \
      || { echo "!! link-4.0.tar.zst does not match vendor/link.sha256" >&2; exit 1; }
    zstd -dc $src | tar -x
    runHook postUnpack
  '';
  sourceRoot = ".";

  # Same compile as tools/build_ableton-linkd.sh: header-only C++17 against the
  # vendored SDK and its bundled asio, nothing else. The static libstdc++/libgcc
  # keep the binary's DT_NEEDED down to C-runtime sonames — parity with the
  # shipped binary, and what the installCheckPhase gate below asserts.
  buildPhase = ''
    runHook preBuild
    $CXX -std=c++17 -O2 -Wall -Wno-multichar \
      -DLINK_PLATFORM_UNIX=1 -DLINK_PLATFORM_LINUX=1 \
      -I include -I modules/asio-standalone/asio/include \
      -static-libstdc++ -static-libgcc \
      -o ableton-linkd ${daemonSrc} \
      -lpthread -latomic
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ableton-linkd $out/bin/ableton-linkd
    runHook postInstall
  '';

  # scripts/install.sh's gate, applied here instead: anything beyond the host
  # C runtime — above all a shared libstdc++ — means the static-link flags were
  # lost. --help also proves the binary constructs and runs.
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/ableton-linkd --help >/dev/null \
      || { echo "!! ableton-linkd does not run" >&2; exit 1; }
    needed=$(readelf -d $out/bin/ableton-linkd | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
    for so in $needed; do
      case "$so" in
        linux-vdso.so*|libm.so*|libc.so*|libpthread.so*|libatomic.so*|ld-linux*.so*) ;;
        *) echo "!! ableton-linkd links an unexpected library: $so" >&2; exit 1 ;;
      esac
    done
    echo "ableton-linkd gate passed (runs; links host C runtime only)"
  '';

  meta = with lib; {
    description = "Ableton Link session anchor — persistent native Link peer";
    mainProgram = "ableton-linkd";
    platforms = [ "x86_64-linux" ];
    license = with licenses; [
      gpl2Plus # Link SDK (vendor/link-4.0.tar.zst)
      boost # its bundled standalone asio
    ];
  };
}
