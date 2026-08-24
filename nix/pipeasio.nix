{
  stdenv,
  lib,
  wine,
  pipewire,
  pipeasioSrc,
  patchesDir,
  cmake,
  ninja,
  pkg-config,
  qt6,
}:

let
  # Same directory the wine half is pinned from: SERIES.sha256 covers both
  # series, the pipeasio one under a pipeasio/ prefix.
  pipeasioPatches = patchesDir + "/pipeasio";
  seriesRe = "^[0-9a-f]{64}  pipeasio/[0-9]{4}-.*\\.patch$";
in

stdenv.mkDerivation {
  pname = "pipeasio";
  version = "1.5.0";

  src = pipeasioSrc;

  # attrNames is sorted, so the NNNN- prefixes give the series order; filter
  # to *.patch so a stray note/manifest in the dir can never enter the series.
  patches = builtins.map (f: pipeasioPatches + "/${f}") (
    builtins.filter (lib.hasSuffix ".patch") (builtins.attrNames (builtins.readDir pipeasioPatches))
  );

  # The same gate the wine half gets, on the same manifest: checksum
  # mismatches, unlisted on-disk patches, and an empty series all fail loud.
  # Runs at the head of patchPhase, before the list above is applied.
  prePatch = ''
    echo "Verifying pipeasio patch series from ${pipeasioPatches} (pinned by SERIES.sha256)"
    series=$(grep -E '${seriesRe}' ${patchesDir}/SERIES.sha256 | awk '{print $2}')
    [ -n "$series" ] || { echo "!! SERIES.sha256 lists no pipeasio patches" >&2; exit 1; }
    (cd ${patchesDir} && grep -E '${seriesRe}' SERIES.sha256 | sha256sum -c --quiet) \
      || { echo "!! pipeasio patch series does not match SERIES.sha256" >&2; exit 1; }
    for f in ${pipeasioPatches}/[0-9]*.patch; do
      echo "$series" | grep -qx "pipeasio/$(basename $f)" \
        || { echo "!! $(basename $f) on disk but not in SERIES.sha256 — update the manifest" >&2; exit 1; }
    done
    echo "Verified $(echo "$series" | wc -l) pipeasio patches"
  '';

  # 1.5.0 builds with CMake (cmake/WineDLL.cmake drives winebuild/winegcc from
  # the patched Wine); libpipewire backs the unix half. Same production
  # configuration as scripts/container-build.sh, minus the test rig (the
  # container runs the CTest scope; nothing here would).
  #
  # The Qt settings panel is built. Live's Hardware Setup button reaches it
  # through the driver: patch pipeasio/0011 looks up pipeasio-settings on PATH
  # and posix_spawns it, and without the binary the driver falls through to the
  # dialog telling the user to edit config.ini by hand.
  #
  # No wrapQtAppsHook: nixpkgs' Qt6 resolves its platform plugin from the store
  # without environment injection (checked by running the panel under env -i
  # with only DISPLAY and XAUTHORITY set), and a wrapper would put a libc-only
  # binary under the plain name, where build-audit.sh reads the Qt6 link.
  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    wine
  ];
  buildInputs = [
    pipewire
    qt6.qtbase
  ];

  # nixpkgs requires an explicit choice from anything depending on qtbase. The
  # panel needs no wrapping: see the nativeBuildInputs note above.
  dontWrapQtApps = true;

  cmakeFlags = [
    "-DWINEBUILD=${wine}/bin/winebuild"
    "-DWINEGCC=${wine}/bin/winegcc"
    "-DBUILD_SETTINGS_PANEL=ON"
    "-DBUILD_TESTS=OFF"
  ];

  # Unlike the tarball (which must resolve the HOST's PipeWire, so no rpath),
  # this pins nixpkgs' libpipewire via RUNPATH; the client<->daemon protocol
  # is stable across daemon versions. The CMake install owns the layout:
  # lib/wine/{x86_64-windows,x86_64-unix}/pipeasio64.* plus the RELATIVE
  # pipeasio.* alias symlinks Wine resolves the builtin through (and which
  # build-audit.sh requires to be links), and bin/pipeasio-register (unused
  # here — setup-prefix.sh registers through its own bounded wine calls — but
  # part of upstream's install contract).
  doInstallCheck = true;
  installCheckPhase = ''
    test -s $out/lib/wine/x86_64-windows/pipeasio64.dll
    test -s $out/lib/wine/x86_64-unix/pipeasio64.dll.so
    for alias in lib/wine/x86_64-windows/pipeasio.dll lib/wine/x86_64-unix/pipeasio.dll.so; do
      [ -L $out/$alias ] || { echo "$alias is not the upstream install's alias symlink"; exit 1; }
      [ -s $out/$alias ] || { echo "$alias dangles"; exit 1; }
    done
    readelf -d $out/lib/wine/x86_64-unix/pipeasio64.dll.so \
      | grep -F 'Shared library: [libpipewire-0.3.so.0]' \
      || { echo "unix half does not link libpipewire-0.3.so.0"; exit 1; }
    readelf -d $out/lib/wine/x86_64-unix/pipeasio64.dll.so \
      | grep -E 'RUNPATH|RPATH' | grep -F '${lib.getLib pipewire}/lib' \
      || { echo "unix half lacks the nixpkgs pipewire RUNPATH"; exit 1; }
    # The panel is what Live's Hardware Setup button spawns; a silent Qt
    # detection failure would leave BUILD_SETTINGS_PANEL=ON building nothing.
    [ -x $out/bin/pipeasio-settings ] \
      || { echo "settings panel missing — Qt was not detected at configure time"; exit 1; }
    readelf -d $out/bin/pipeasio-settings | grep -qF 'libQt6Widgets.so.6' \
      || { echo "settings panel does not link Qt6 Widgets"; exit 1; }
    echo "PipeASIO files present, libpipewire linked and rpath'd, settings panel built"
  '';

  meta = with lib; {
    description = "PipeASIO 1.5.0 — native PipeWire ASIO driver, compiled against patched Wine";
    platforms = [ "x86_64-linux" ];
    license = licenses.gpl3Plus; # SPDX GPL-3.0-or-later in src/*.c
  };
}
