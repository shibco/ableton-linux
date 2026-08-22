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
  # Media: winegstreamer (mp3/mp4/wma import)
  gst_all_1,
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

let
  # winegstreamer needs gstreamer-1.0 plus gst-plugins-base's audio, video and
  # tag libraries to build at all (configure.ac: WINE_PACKAGE_FLAGS(GSTREAMER,
  # [gstreamer-1.0 gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0])).
  # The decoders themselves are plugins it loads through
  # GST_PLUGIN_SYSTEM_PATH_1_0, so the plugin sets ship with the runtime rather
  # than being borrowed from the host the way the .run installer does it:
  #   good   mpg123 (mp3), isomp4/qtdemux (mp4), audioparsers
  #   ugly   asf (wma/asf container)
  #   libav  aac, h.264 and wmav1/2 decoders
  #   bad    the remaining containers and codecs Live's browser can meet
  gstPlugins = with gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
  ];
in

stdenv.mkDerivation rec {
  pname = "wine-d2d1-nspa";
  version = "11.13";

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
  ]
  ++ gstPlugins;

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
    # --fuzz=0: container-build.sh applies the same series with `git am
    # --3way`, which never places a hunk it cannot match. patch(1) defaults to
    # fuzz 2 and would apply a drifted hunk at exit 0, producing a tree that
    # differs from the released one with no gate on the difference (the [3/4]
    # fingerprints only grep for strings). -N and --no-backup-if-mismatch keep
    # a reversed hunk and a .orig file out of the build.
    n=0
    for p in $series; do
      echo "  $p"
      patch -p1 --fuzz=0 -N --no-backup-if-mismatch < ${patchesDir}/$p
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
    # Explicit, not implied: with --with-gstreamer a missing gstreamer-1.0 or
    # base-plugins dev tree is a configure ERROR (aclocal.m4 WINE_NOTICE_WITH),
    # instead of a notice that quietly drops winegstreamer — and mp3, mp4 and
    # wma import with it (issue #44).
    "--with-gstreamer"
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

        # Same failure mode, same verdict for media: no winegstreamer means
        # Live's mp3/mp4/wma import has no decoder and fails without a message.
        # --with-gstreamer above already makes that a configure error; this also
        # covers a build that configured it and then produced no artifact.
        for f in lib/wine/x86_64-unix/winegstreamer.so \
                 lib/wine/x86_64-windows/winegstreamer.dll; do
          [ -s $out/$f ] \
            || { echo "!! $f missing — no mp3/mp4/wma import" >&2; exit 1; }
        done
        ${stdenv.cc.bintools.targetPrefix}readelf -d $out/lib/wine/x86_64-unix/winegstreamer.so \
          | grep -qF 'Shared library: [libgstreamer-1.0.so.0]' \
          || { echo "!! winegstreamer.so does not link libgstreamer-1.0.so.0" >&2; exit 1; }
        # A winegstreamer with no plugins on its path imports nothing, so gate
        # the plugins that carry the three formats, not just the bridge.
        for p in libgstmpg123.so libgstisomp4.so libgstasf.so libgstlibav.so; do
          hit=""
          for d in $(printf '%s\n' '${passthru.gstPluginPath}' | tr ':' ' '); do
            if [ -e "$d/$p" ]; then hit=1; break; fi
          done
          [ -n "$hit" ] \
            || { echo "!! $p is not on GST_PLUGIN_SYSTEM_PATH_1_0" >&2; exit 1; }
        done
        # winegstreamer resolves the GStreamer libraries through its own
        # RUNPATH, which is why they stay OFF the LD_LIBRARY_PATH bin/wine
        # exports (passthru.libPath below): that variable is for the libraries
        # wine dlopens by soname, and every entry added to it perturbs the
        # environment of every wine process. ntdll.so is wine's own builtin,
        # resolved by its loader and never by ld.so.
        ldd_out=$(env -u LD_LIBRARY_PATH ldd $out/lib/wine/x86_64-unix/winegstreamer.so 2>&1 || true)
        unresolved=$(printf '%s\n' "$ldd_out" | grep 'not found' | grep -v 'ntdll\.so' || true)
        [ -z "$unresolved" ] || {
          echo "!! winegstreamer.so cannot resolve its libraries from its RUNPATH:" >&2
          printf '%s\n' "$unresolved" >&2; exit 1; }
        echo "winegstreamer gate passed (bridge + mp3/mp4/wma plugins)"

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
    # winegstreamer loads its decoders as GStreamer plugins, not as linked
    # libraries, so the bridge alone still imports nothing without this path.
    export GST_PLUGIN_SYSTEM_PATH_1_0="${passthru.gstPluginPath}\''${GST_PLUGIN_SYSTEM_PATH_1_0:+:\$GST_PLUGIN_SYSTEM_PATH_1_0}"
    # -a "\$0": the apploader symlinks (wineboot, regsvr32, ...) point here and
    # the loader picks the app from argv[0].
    exec -a "\$0" $out/bin/.wine-wrapped "\$@"
    WRAPWRP
        chmod +x $out/bin/wine
  '';

  passthru = {
    # dlopen path, reused by ableton-wine's regenerated wrapper. The GStreamer
    # packages are deliberately excluded although they are buildInputs: they are
    # needed to COMPILE winegstreamer, which then finds them through its own
    # RUNPATH (gated in postInstall). Listing them here would only lengthen the
    # environment of every wine process for nothing.
    libPath = lib.makeLibraryPath (lib.subtractLists gstPlugins buildInputs);
    # The plugin search path bin/wine exports above; reused by that same wrapper.
    gstPluginPath = lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" gstPlugins;
  };

  # Smoke gate: the installed tree must boot a prefix and run a builtin.
  # No copy-and-relocate: bin/wine hardcodes this store path anyway, so a
  # copied tree would exec the original binary and prove nothing extra.
  doInstallCheck = true;
  installCheckPhase = ''
    echo "Smoke gate: verify wine runs from its installed path"
    smoke=$(mktemp -d)
    mkdir -p $smoke/home
    # Captured, not piped into grep -q: piping raced wine's exit against grep's
    # early exit, and 2>/dev/null left a failing gate saying only "it failed".
    #
    # env -i is load-bearing, not tidiness. Nix runs builders with address-space
    # randomisation disabled, so the layout of a process is a deterministic
    # function of its environment, and wine's preloader reserves fixed low
    # ranges before ntdll can report anything. Inheriting the builder's
    # environment therefore made this gate a function of unrelated things: after
    # gstreamer joined buildInputs the environment grew, the layout shifted into
    # a collision, and wine SIGSEGV'd here 100% of the time while the very same
    # tree ran fine on a host and in any other sandbox. A fixed, explicit
    # environment keeps the gate testing wine rather than the build environment.
    # HOME must be writable: the builder's /homeless-shelter is not, and
    # GStreamer would rescan every plugin for each process wine spawns.
    rc=0
    timeout 600 env -i \
      PATH=$out/bin \
      HOME=$smoke/home \
      WINEPREFIX=$smoke/prefix \
      WINEDEBUG=-all \
      $out/bin/wine cmd /c "echo smoke-ok" >$smoke/out 2>$smoke/err || rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q smoke-ok $smoke/out; then
      [ "$rc" -eq 124 ] && echo "!! wine did not finish within 600s" >&2
      echo "!! wine did not run from its installed path (exit $rc); its stderr:" >&2
      cat $smoke/err >&2
      exit 1
    fi
    echo "  smoke gate passed"
  '';

  meta = with lib; {
    description = "Wine 11.13 with D2D1-DCOMP + NSPA fixes for Ableton Live 12";
    platforms = [ "x86_64-linux" ];
    license = licenses.lgpl21Plus;
  };
}
