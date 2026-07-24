{
  stdenv,
  lib,
  zstd,
  llvmPackages,
  # Build tools
  flex,
  bison,
  perl,
  gettext,
  pkg-config,
  git,
  python3,
  # X11 / GL / Vulkan
  libx11,
  libxext,
  libxrandr,
  libxrender,
  libxi,
  libxfixes,
  libxcursor,
  libxcomposite,
  libxinerama,
  libxxf86vm,
  libxkbcommon,
  libGL,
  libGLU,
  vulkan-loader,
  # Fonts
  freetype,
  fontconfig,
  # Audio
  alsa-lib,
  libpulseaudio,
  # Network / USB / system
  gnutls,
  libusb1,
  udev,
  dbus,
  # Source inputs
  wineSrc,
  patchesDir,
  ntsyncUapi,
  clangUnwrapped ? llvmPackages.clang-unwrapped, # PE cross-compiler: Nix wrapper breaks -target
}:

stdenv.mkDerivation rec {
  pname = "wine-d2d1-nspa";
  version = "11.11";

  src = wineSrc;

  nativeBuildInputs = [
    zstd
    # LLVM for PE (Windows) cross-compilation: WoW64 needs clang/lld
    llvmPackages.llvm
    llvmPackages.clang
    llvmPackages.lld
    flex
    bison
    perl
    gettext
    pkg-config
    git
    python3
  ];

  buildInputs = [
    # X11 + GL
    libx11
    libxext
    libxrandr
    libxrender
    libxi
    libxfixes
    libxcursor
    libxcomposite
    libxinerama
    libxxf86vm
    libxkbcommon
    libGL
    libGLU
    vulkan-loader
    # Fonts
    freetype
    fontconfig
    # Audio
    alsa-lib
    libpulseaudio
    # Network / USB / system
    gnutls
    libusb1
    udev
    dbus
  ];

  # The tarball is zstd-compressed with no top-level directory.
  unpackPhase = ''
    runHook preUnpack
    ${zstd}/bin/zstd -dc --long=27 $src | tar -x
    runHook postUnpack
  '';
  sourceRoot = ".";

  # Verify and apply the patch series pinned by SERIES.sha256: checksum
  # mismatches, unlisted on-disk patches, and an empty series all fail loud.
  postUnpack = ''
    echo "Applying patch series from ${patchesDir} (pinned by SERIES.sha256)"
    series=$(grep -E '^[0-9a-f]{64}  [0-9]{4}-.*\.patch$' ${patchesDir}/SERIES.sha256 | awk '{print $2}')
    [ -n "$series" ] || { echo "!! SERIES.sha256 lists no wine patches" >&2; exit 1; }
    (cd ${patchesDir} && grep -E '^[0-9a-f]{64}  [0-9]{4}-.*\.patch$' SERIES.sha256 | sha256sum -c --quiet) \
      || { echo "!! patch series does not match SERIES.sha256" >&2; exit 1; }
    for f in ${patchesDir}/[0-9]*.patch; do
      echo "$series" | grep -qx "$(basename $f)" \
        || { echo "!! $(basename $f) on disk but not in SERIES.sha256 — update the manifest" >&2; exit 1; }
    done
    n=0
    for p in $series; do
      echo "  $p"
      patch -p1 < ${patchesDir}/$p
      n=$((n+1))
    done
    echo "Applied $n wine patches"
  '';

  # The Nix clang wrapper breaks `clang -target i686-windows`; configure
  # probes <target>-clang before bare clang, so expose clang-unwrapped
  # under the target-prefixed names.
  preConfigure = ''
        mkdir -p "$TMPDIR/wine-pe-tools"
        for target in i686-w64-mingw32 x86_64-w64-mingw32; do
          cat > "$TMPDIR/wine-pe-tools/$target-clang" <<'WRAPPER'
    #!/bin/sh
    exec ${clangUnwrapped}/bin/clang "$@"
    WRAPPER
          chmod +x "$TMPDIR/wine-pe-tools/$target-clang"
        done
        export PATH="$TMPDIR/wine-pe-tools:$PATH"
  '';

  # WoW64 (both PE arches); --disable-tests saves ~40% build time.
  configureFlags = [
    "--prefix=${placeholder "out"}"
    "--enable-archs=i386,x86_64"
    "--disable-tests"
  ];

  # configure silently drops ntsync without linux/ntsync.h (every NT wait then
  # costs a wineserver round trip). The vendored dir holds ONLY that header,
  # so system headers stay authoritative for everything else.
  CPPFLAGS = "-I${ntsyncUapi}";
  postConfigure = ''
    grep -q '^#define HAVE_LINUX_NTSYNC_H 1' include/config.h \
      || { echo "!! HAVE_LINUX_NTSYNC_H not set; linux/ntsync.h not seen at configure time" >&2; exit 1; }
  '';

  enableParallelBuilding = true;
  # PE files need llvm-strip (standard strip can't touch COFF) — done in postInstall.
  dontStrip = true;
  # Wine dlopen's many system libs at runtime; Nix's shrink-rpath would drop
  # everything not in DT_NEEDED.
  dontPatchELF = true;

  postInstall = ''
        # ntsync gate — BEFORE stripping (only symbol names carry "ntsync").
        # Check both halves; each can lose it independently.
        for f in bin/wineserver lib/wine/x86_64-unix/ntdll.so; do
          n=$(strings $out/$f | grep -c ntsync || true)
          [ "$n" -gt 0 ] || { echo "!! no ntsync in $f; waits would fall back to server round trips" >&2; exit 1; }
        done
        echo "ntsync gate passed (wineserver + ntdll)"

        # configure silently drops winealsa (ALSA MIDI) when alsa-lib is absent —
        # fail, don't ship without it.
        [ -s $out/lib/wine/x86_64-unix/winealsa.so ] \
          || { echo "!! winealsa.so missing — alsa-lib not seen at configure time; no ALSA MIDI" >&2; exit 1; }
        echo "winealsa gate passed"

        echo "Stripping PE builtins"
        find $out/lib/wine \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' \
          -o -name '*.drv' -o -name '*.cpl' -o -name '*.ocx' \) \
          -exec ${llvmPackages.llvm}/bin/llvm-strip --strip-all {} + 2>/dev/null || true

        echo "Stripping Unix .so files"
        find $out/lib/wine/*-unix -name '*.so' -exec ${stdenv.cc.bintools.targetPrefix}strip --strip-unneeded {} + 2>/dev/null || true
        for f in $out/bin/*; do
          ${stdenv.cc.bintools.targetPrefix}strip --strip-unneeded "$f" 2>/dev/null || true
        done

        echo "Pruning dev-only files"
        # Import libs (*.a) stay: nix/pipeasio.nix links against this output;
        # ableton-wine.nix prunes them afterwards (container-build.sh order).
        rm -f $out/bin/widl $out/bin/winecpp \
              $out/bin/winedump $out/bin/winemaker $out/bin/wmc $out/bin/wrc \
              $out/bin/function_grep.pl

        # dlopen needs LD_LIBRARY_PATH; RPATH only covers DT_NEEDED.
        mv $out/bin/wine $out/bin/.wine-wrapped
        cat > $out/bin/wine <<WRAPWRP
    #!/bin/sh
    export LD_LIBRARY_PATH="${passthru.libPath}\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    # -a "\$0": the apploader symlinks (wineboot, regsvr32, ...) point here and
    # the loader picks the app from argv[0].
    exec -a "\$0" $out/bin/.wine-wrapped "\$@"
    WRAPWRP
        chmod +x $out/bin/wine
  '';

  # dlopen path, reused by ableton-wine's regenerated wrapper.
  passthru.libPath = lib.makeLibraryPath buildInputs;

  # Smoke gate: the installed tree must boot a prefix and run a builtin.
  # No copy-and-relocate: bin/wine hardcodes this store path anyway, so a
  # copied tree would exec the original binary and prove nothing extra.
  doInstallCheck = true;
  installCheckPhase = ''
    echo "Smoke gate: verify wine runs from its installed path"
    WINEPREFIX=$(mktemp -d)/prefix WINEDEBUG=-all \
      $out/bin/wine cmd /c "echo smoke-ok" 2>/dev/null | grep -q smoke-ok
    echo "  smoke gate passed"
  '';

  meta = with lib; {
    description = "Wine 11.11 with D2D1-DCOMP + NSPA fixes for Ableton Live 12";
    platforms = [ "x86_64-linux" ];
    license = licenses.lgpl21Plus;
  };
}
