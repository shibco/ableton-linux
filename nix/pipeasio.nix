{
  stdenv,
  lib,
  wine,
  pipewire,
  pipeasioSrc,
  pipeasioPatches,
}:

stdenv.mkDerivation {
  pname = "pipeasio";
  version = "1.2.2";

  src = pipeasioSrc;

  # attrNames is sorted, so the NNNN- prefixes give the series order; filter
  # to *.patch so a stray note/manifest in the dir can never enter the series.
  patches = builtins.map (f: pipeasioPatches + "/${f}") (
    builtins.filter (lib.hasSuffix ".patch") (builtins.attrNames (builtins.readDir pipeasioPatches))
  );

  # winegcc/winebuild come from the patched Wine; libpipewire backs the unix half.
  nativeBuildInputs = [ wine ];
  buildInputs = [ pipewire ];

  # Same five-object build as scripts/container-build.sh, against this Wine's
  # headers and nixpkgs' PipeWire. 64-bit only — Live 12 is 64-bit.
  buildPhase = ''
    runHook preBuild
    mkdir -p build64
    for f in asio audio config main regsvr; do
      gcc -c -o build64/$f.o src/$f.c \
        -Iinclude \
        -I${lib.getDev pipewire}/include/pipewire-0.3 \
        -I${lib.getDev pipewire}/include/spa-0.2 \
        -I${wine}/include -I${wine}/include/wine \
        -I${wine}/include/wine/windows \
        -D_REENTRANT -Wall -pipe -fno-strict-aliasing -Wwrite-strings \
        -Wpointer-arith -Werror=implicit-function-declaration \
        -fPIC -O2 -DNDEBUG -fvisibility=hidden
    done
    winebuild -m64 --dll --fake-module -E pipeasio.dll.spec build64/*.o -o build64/pipeasio64.dll
    winegcc -shared pipeasio.dll.spec build64/*.o \
      -L${lib.getLib pipewire}/lib \
      -lodbc32 -lole32 -luuid -lwinmm -luser32 -lpipewire-0.3 \
      -o build64/pipeasio64.dll.so
    runHook postBuild
  '';

  # Both names: Wine resolves pipeasio64.dll to builtin "pipeasio.dll" (from
  # its spec) and looks for the unix half under that name; without both,
  # LoadLibrary fails with STATUS_DLL_NOT_FOUND.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/wine/x86_64-windows $out/lib/wine/x86_64-unix
    install -m644 build64/pipeasio64.dll    $out/lib/wine/x86_64-windows/pipeasio64.dll
    install -m644 build64/pipeasio64.dll.so $out/lib/wine/x86_64-unix/pipeasio64.dll.so
    install -m644 build64/pipeasio64.dll    $out/lib/wine/x86_64-windows/pipeasio.dll
    install -m644 build64/pipeasio64.dll.so $out/lib/wine/x86_64-unix/pipeasio.dll.so
    runHook postInstall
  '';

  # Unlike the tarball (which must resolve the HOST's PipeWire, so no rpath),
  # this pins nixpkgs' libpipewire via RUNPATH; the client<->daemon protocol
  # is stable across daemon versions.
  doInstallCheck = true;
  installCheckPhase = ''
    test -s $out/lib/wine/x86_64-windows/pipeasio64.dll
    test -s $out/lib/wine/x86_64-unix/pipeasio64.dll.so
    test -s $out/lib/wine/x86_64-windows/pipeasio.dll
    test -s $out/lib/wine/x86_64-unix/pipeasio.dll.so
    readelf -d $out/lib/wine/x86_64-unix/pipeasio64.dll.so \
      | grep -F 'Shared library: [libpipewire-0.3.so.0]' \
      || { echo "unix half does not link libpipewire-0.3.so.0"; exit 1; }
    readelf -d $out/lib/wine/x86_64-unix/pipeasio64.dll.so \
      | grep -E 'RUNPATH|RPATH' | grep -F '${lib.getLib pipewire}/lib' \
      || { echo "unix half lacks the nixpkgs pipewire RUNPATH"; exit 1; }
    echo "PipeASIO files present, libpipewire linked and rpath'd"
  '';

  meta = with lib; {
    description = "PipeASIO 1.2.2 — native PipeWire ASIO driver, compiled against patched Wine";
    platforms = [ "x86_64-linux" ];
    license = licenses.gpl3Plus; # SPDX GPL-3.0-or-later in src/*.c
  };
}
