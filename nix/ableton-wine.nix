{
  stdenv,
  lib,
  removeReferencesTo,
  wine,
  pipeasio,
  cabextract,
  unzip,
  # Pin PipeASIO config.ini keys, e.g.
  #   ableton-wine.override { pipeasioSettings = { buffer_size = 256; inputs = 8; }; }
  # The launch shim re-asserts exactly these keys in ~/.config/pipeasio/config.ini
  # on every start (so they win over hand/panel edits) and leaves other keys alone.
  # Keys and limits are the driver's own (src/config.c):
  #   inputs, outputs        int, 0..256
  #   buffer_size            int, power of two, 16..8192 frames
  #   sample_rate            int Hz, 0 = follow the PipeWire graph
  #   fixed_buffer_size, auto_connect, follow_device_clock   bool
  #   output_device, input_device, node_name                 string
  pipeasioSettings ? { },
}:

let
  s = pipeasioSettings;
  validKeys = [
    "inputs"
    "outputs"
    "buffer_size"
    "fixed_buffer_size"
    "sample_rate"
    "auto_connect"
    "follow_device_clock"
    "output_device"
    "input_device"
    "node_name"
  ];
  unknownKeys = lib.filter (k: !(lib.elem k validKeys)) (lib.attrNames s);
  intIn = k: lo: hi: !(s ? ${k}) || (lib.isInt s.${k} && lo <= s.${k} && s.${k} <= hi);
  isPow2 = n: lib.isInt n && n > 0 && builtins.bitAnd n (n - 1) == 0;

  renderValue = v: if lib.isBool v then lib.boolToString v else toString v;

  # Fresh-file seed: setup-prefix.sh's defaults plus the pins.
  seed = {
    inputs = 2;
    outputs = 2;
    buffer_size = 256;
    fixed_buffer_size = true;
    auto_connect = true;
  }
  // s;
  seedLines = [ "[pipeasio]" ] ++ lib.mapAttrsToList (k: v: "${k} = ${renderValue v}") seed;
in

assert lib.assertMsg (unknownKeys == [ ]) ''
  ableton-wine: unknown pipeasioSettings key(s): ${toString unknownKeys}
  valid keys: ${toString validKeys}'';
assert lib.assertMsg (intIn "inputs" 0 256 && intIn "outputs" 0 256)
  "ableton-wine: pipeasioSettings.inputs/outputs must be integers in 0..256";
assert lib.assertMsg (!(s ? buffer_size) || (isPow2 s.buffer_size && 16 <= s.buffer_size && s.buffer_size <= 8192))
  "ableton-wine: pipeasioSettings.buffer_size must be a power of two in 16..8192";
assert lib.assertMsg (!(s ? sample_rate) || (lib.isInt s.sample_rate && s.sample_rate >= 0))
  "ableton-wine: pipeasioSettings.sample_rate must be an integer >= 0 (0 = follow the graph)";
assert lib.assertMsg
  (lib.all (k: !(s ? ${k}) || lib.isBool s.${k}) [ "fixed_buffer_size" "auto_connect" "follow_device_clock" ])
  "ableton-wine: pipeasioSettings.fixed_buffer_size/auto_connect/follow_device_clock must be booleans";
assert lib.assertMsg
  (lib.all (k: !(s ? ${k}) || (lib.isString s.${k} && !lib.hasInfix "\n" s.${k})) [
    "output_device"
    "input_device"
    "node_name"
  ])
  "ableton-wine: pipeasioSettings.output_device/input_device/node_name must be single-line strings";

stdenv.mkDerivation {
  pname = "ableton-wine";
  inherit (wine) version;

  dontUnpack = true;

  nativeBuildInputs = [
    removeReferencesTo
  ];

  installPhase = ''
        runHook preInstall

        # -- Wine tree + PipeASIO --
        cp -a ${wine} $out
        chmod -R u+w $out
        # Both names: Wine resolves pipeasio64.dll to builtin "pipeasio.dll"
        # (from its spec) and looks for the unix half under that name.
        for pair in \
          pipeasio64.dll:x86_64-windows \
          pipeasio64.dll.so:x86_64-unix \
          pipeasio.dll:x86_64-windows \
          pipeasio.dll.so:x86_64-unix; do
          file=''${pair%%:*}
          dir=''${pair##*:}
          cp -f ${pipeasio}/lib/wine/$dir/$file $out/lib/wine/$dir/
        done
        # Build-time-only files pipeasio consumed: headers and winegcc/winebuild
        # drove its compile, the import libs (*.a) its link.
        rm -rf $out/include $out/share/man
        rm -f $out/bin/winegcc $out/bin/wineg++ $out/bin/winebuild
        rm -f $out/lib/wine/*-windows/*.a

        # Copied binaries embed the donor wine's --prefix path (dormant: runtime
        # self-locates via /proc/self/exe); scrub so the donor tree stays out of
        # this closure. disallowedReferences below enforces it.
        remove-references-to -t ${wine} \
          $out/bin/.wine-wrapped $out/bin/wineserver \
          $out/lib/wine/x86_64-unix/ntdll.so

        # cp -a preserved a bin/wine that execs the ORIGINAL wine store path;
        # wine self-locates its builtin dll dir from /proc/self/exe, so the
        # pipeasio builtins above would never be found. Regenerate for THIS tree.
        cat > $out/bin/wine <<WRAPWRP
    #!/bin/sh
    export LD_LIBRARY_PATH="${wine.libPath}\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    # -a "\$0": apploader symlinks (wineboot, regsvr32, ...) need argv[0] intact.
    exec -a "\$0" $out/bin/.wine-wrapped "\$@"
    WRAPWRP
        chmod +x $out/bin/wine

        # -- Launcher --
        mkdir -p $out/bin $out/libexec
        install -m755 ${../scripts/ableton-live} $out/libexec/ableton-live
        # Quoted heredocs ('SHIM'): nothing shell-expands at build; @out@ is
        # substituted after. Runtime shell ''${...} is written with the '''' escape.
        cat > $out/bin/ableton-live <<'SHIM'
    #!/bin/sh
    # Generated by nix/ableton-wine.nix. pipeasioSettings pins are appended
    # below when configured: ableton-wine.override { pipeasioSettings = { ... }; }
    export ABLETON_WINE_ROOT="''${ABLETON_WINE_ROOT:-@out@}"
    export PATH="@out@/bin:$PATH"
    SHIM
        ${lib.optionalString (s != { }) ''
              cat >> $out/bin/ableton-live <<'SHIM'
          # Pin exactly the configured keys in config.ini, leave the rest alone;
          # PIPEASIO_* environment variables still override per launch.
          ini="''${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
          if [ ! -s "$ini" ]; then
              mkdir -p "''${ini%/*}"
              printf '%s\n' ${lib.escapeShellArgs seedLines} > "$ini"
          fi
          SHIM
              cat >> $out/bin/ableton-live <<'SHIM'
          ${lib.concatStrings (
            lib.mapAttrsToList (
              k: v:
              let
                val = renderValue v;
              in
              # Keys come from the validKeys whitelist (no regex metacharacters);
              # values only ever appear shell-quoted, never in a sed replacement.
              # The driver honors the LAST occurrence of a key — the probe reads
              # that one, and the pin is delete + append.
              ''
                if [ "$(sed -n 's/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*//p' "$ini" | tail -n 1)" != ${lib.escapeShellArg val} ]; then
                    echo "ableton-live: pinning PipeASIO ${k} (nix pipeasioSettings)" >&2
                    sed -i '/^[[:space:]]*${k}[[:space:]]*=/d' "$ini"
                    printf '%s\n' ${lib.escapeShellArg "${k} = ${val}"} >> "$ini"
                fi
              ''
            ) s
          )}SHIM
        ''}
        cat >> $out/bin/ableton-live <<'SHIM'
    exec "@out@/libexec/ableton-live" "$@"
    SHIM
        chmod +x $out/bin/ableton-live
        substituteInPlace $out/bin/ableton-live --replace-fail '@out@' "$out"

        # -- Max 9 launcher (same runtime and prefix) --
        install -m755 ${../scripts/max9} $out/libexec/max9
        cat > $out/bin/max9 <<'SHIM'
    #!/bin/sh
    # Generated by nix/ableton-wine.nix.
    export ABLETON_WINE_ROOT="''${ABLETON_WINE_ROOT:-@out@}"
    export PATH="@out@/bin:$PATH"
    exec "@out@/libexec/max9" "$@"
    SHIM
        chmod +x $out/bin/max9
        substituteInPlace $out/bin/max9 --replace-fail '@out@' "$out"

        # -- Supporting scripts (original repo layout: scripts/ + vendor/) --
        mkdir -p $out/share/ableton-wine/scripts
        mkdir -p $out/share/ableton-wine/vendor
        install -m755 ${../scripts/detect-scale.sh}      $out/share/ableton-wine/scripts/detect-scale.sh
        install -m755 ${../scripts/detect-theme.sh}      $out/share/ableton-wine/scripts/detect-theme.sh
        install -m755 ${../scripts/setup-prefix.sh}      $out/share/ableton-wine/scripts/setup-prefix.sh
        install -m755 ${../scripts/check-live-audio.sh}  $out/share/ableton-wine/scripts/check-live-audio.sh
        install -m755 ${../scripts/check-ntsync.sh}      $out/share/ableton-wine/scripts/check-ntsync.sh
        # check-ntsync.sh looks for its probe at ../beta/tester-kit/probes/windows/
        install -Dm644 ${../beta/tester-kit/probes/windows/ntsyncprobe.exe} \
          $out/share/ableton-wine/beta/tester-kit/probes/windows/ntsyncprobe.exe
        install -m644 ${../tools/setsyscolors.exe}       $out/share/ableton-wine/scripts/setsyscolors.exe
        # The launcher starts the Learn View heal helper when staged here.
        install -m644 ${../tools/learnheal.exe}          $out/share/ableton-wine/learnheal.exe
        install -m755 ${../scripts/setup-realtime.sh}    $out/share/ableton-wine/scripts/setup-realtime.sh
        install -m755 ${../scripts/setup-link.sh}        $out/share/ableton-wine/scripts/setup-link.sh
        # setup-link.sh points at this note; ship it so the pointer resolves.
        mkdir -p $out/share/ableton-wine/notes
        install -m644 ${../notes/ABLETON-WINE-LINK.md}   $out/share/ableton-wine/notes/ABLETON-WINE-LINK.md
        # install.sh / uninstall.sh are tarball tools — not shipped.

        # Point default WINE_ROOT (and the launcher path) at the store.
        for script in setup-prefix.sh check-live-audio.sh check-ntsync.sh; do
          substituteInPlace $out/share/ableton-wine/scripts/$script \
            --replace-fail '$HOME/.local/opt/wine-d2d1-nspa-11.11' "$out"
        done
        substituteInPlace $out/share/ableton-wine/scripts/check-live-audio.sh \
          --replace-fail '$HOME/.local/bin/ableton-live' "$out/bin/ableton-live"

        # The vendored (pinned) winetricks + payload cache, not nixpkgs' — same
        # setup path as the tarball install; the Live 12 verbs need no network.
        install -m755 ${../vendor/winetricks}       $out/share/ableton-wine/vendor/winetricks
        cp -a ${../vendor/winetricks-cache}         $out/share/ableton-wine/vendor/winetricks-cache
        # cabextract: winetricks corefonts; unzip: setup-prefix's Live installer step.
        ln -s ${cabextract}/bin/cabextract   $out/bin/cabextract
        ln -s ${lib.getBin unzip}/bin/unzip  $out/bin/unzip

        # -- Desktop entries --
        # Rendered into share/applications so profiles surface them; Path= is
        # unknowable at build time and the launchers are cwd-agnostic. Edition
        # name/icon/WM class use install.sh's no-install defaults — the store
        # cannot see the user's prefix.
        # wine.desktop (from the wine tree copy) is Wine's .exe/.msi MIME
        # handler — not this package's job.
        rm -f $out/share/applications/wine.desktop
        mkdir -p $out/share/applications $out/share/ableton-wine/desktop
        render_desktop() {
          sed -e "s#@HOME@/.local/bin/#$out/bin/#" \
              -e 's#@NAME@#Ableton Live#' \
              -e 's#@ICON@#live-suite#' \
              -e 's#@WMCLASS@#ableton live 12 suite.exe#' \
              -e '/^Path=/d' "$1" > "$2"
          if grep -qE '@[A-Z]+@' "$2"; then
            echo "!! unsubstituted token in $2:" >&2; grep -E '@[A-Z]+@' "$2" >&2; exit 1
          fi
        }
        for f in ableton-live wine-protocol-ableton wine-extension-auz; do
          render_desktop ${../desktop}/$f.desktop.in $out/share/applications/$f.desktop
        done
        # The launcher's repair_handler_entries reads staged copies; without
        # ~/.local/share ones (install.sh) it falls back to this root.
        for f in wine-protocol-ableton wine-extension-auz; do
          cp $out/share/applications/$f.desktop $out/share/ableton-wine/$f.desktop
        done
        # Staged, not active: install.sh gates the Max 9 entries on a Max
        # install, which the store cannot see. Copy them in if you use Max.
        for f in max9 wine-protocol-c74max; do
          render_desktop ${../desktop}/$f.desktop.in $out/share/ableton-wine/desktop/$f.desktop
        done

        # -- Icons + MIME types (the set install.sh registers) --
        mkdir -p $out/share/icons/hicolor $out/share/mime/packages
        cp -a ${../desktop/icons}/scalable $out/share/icons/hicolor/scalable
        cp -a ${../desktop/icons}/symbolic $out/share/icons/hicolor/symbolic
        install -m644 ${../desktop/x-wine-extension-auz.xml} \
          $out/share/mime/packages/x-wine-extension-auz.xml
        install -m644 ${../desktop/icons/application-ableton-live.xml} \
          $out/share/mime/packages/application-ableton-live.xml

        runHook postInstall
  '';

  disallowedReferences = [ wine ];

  # regsvr32 dlopens the unix half (exercising the libpipewire RUNPATH); the
  # CLSID query catches builtin-name mismatches that presence checks miss.
  doInstallCheck = true;
  installCheckPhase = ''
    grep -qF "$out/bin/.wine-wrapped" $out/bin/wine \
      || { echo "bin/wine wrapper does not exec this tree"; exit 1; }
    ${stdenv.shell} -n $out/bin/ableton-live || { echo "launch shim has a syntax error"; exit 1; }
    if grep -qF '@out@' $out/bin/ableton-live; then echo "launch shim has unsubstituted @out@ tokens"; exit 1; fi
    grep -qF "exec \"$out/libexec/ableton-live\"" $out/bin/ableton-live \
      || { echo "launch shim does not exec the launcher"; exit 1; }
    echo "PipeASIO registration gate"
    gate=$(mktemp -d)
    export WINEPREFIX=$gate/prefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
    # Bare symlink invocations on purpose: they exercise the apploader argv[0]
    # path that setup-prefix.sh's PATH calls rely on.
    $out/bin/wineboot -u || { echo "wineboot failed"; exit 1; }
    $out/bin/wineserver -w
    $out/bin/regsvr32 /s pipeasio64.dll \
      || { echo "regsvr32 /s pipeasio64.dll failed"; exit 1; }
    $out/bin/wine reg query 'HKCR\CLSID\{2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}\InprocServer32' >/dev/null \
      || { echo "PipeASIO CLSID not registered"; exit 1; }
    $out/bin/wineserver -k 2>/dev/null || true
    echo "  pipeasio registration gate passed"
  '';

  meta = {
    description = "Ableton Live runtime — patched Wine 11.11 + PipeASIO + launcher";
    mainProgram = "ableton-live"; # lets `nix run` work on .override variants too
    platforms = [ "x86_64-linux" ];
    license = with lib.licenses; [ lgpl21Plus gpl3Plus ]; # wine LGPL-2.1+, pipeasio GPL-3.0+
  };
}
