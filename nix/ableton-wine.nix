{
  stdenv,
  lib,
  gnused,
  removeReferencesTo,
  wine,
  pipeasio,
  cabextract,
  unzip,
  # Per-machine knobs — set via override:
  #   ableton-wine.override { dpi = 112; pipeasioBufferSize = 128;
  #                           pipeasioInputs = 8; pipeasioOutputs = 4; }
  # dpi: prefix LogPixels (96 = 100%, 112 ≈ 117%, 120 = 125%, 144 = 150%).
  #   Handed to the launcher as its native ABLETON_DPI_MODE=dpi<N> block, so
  #   the prefix is recalibrated idempotently on every launch (LogPixels = N,
  #   IFEO dpiAwareness removed — the plain application-side set). Valid N is
  #   72..384. Setting ABLETON_DPI_MODE in the environment
  #   (auto|preserve|100|fractional|dpi<N>|fractional<N>) overrides the pin;
  #   ABLETON_DPI_MODE=auto regains scale detection.
  # pipeasio*: PipeASIO settings. The driver's only config surface is
  #   ~/.config/pipeasio/config.ini (no env support in 1.2.2), so the shim
  #   pins exactly the configured keys and leaves the rest to the user.
  #   bufferSize (frames) should match the host's PipeWire quantum;
  #   inputs/outputs are hardware channel counts.
  dpi ? null,
  pipeasioBufferSize ? null,
  pipeasioInputs ? null,
  pipeasioOutputs ? null,
}:

# Out-of-range pins fail here instead of being refused at launch time
# (the launcher validates dpi<N> against the same 72..384 window).
assert lib.assertMsg (dpi == null || (builtins.isInt dpi && dpi >= 72 && dpi <= 384))
  "ableton-wine: dpi must be an integer LogPixels value in 72..384 (96 = 100%)";

let
  # The original launcher — we patch it to add Nix-store fallbacks for the
  # detect-scale/detect-theme libs, then wrap it so ABLETON_WINE_ROOT points
  # at the store.
  launcherSrc = ../scripts/ableton-live;

  # config.ini keys pinned by the launch shim (null = leave untouched).
  pipeasioPins = lib.filterAttrs (_: v: v != null) {
    inputs = pipeasioInputs;
    outputs = pipeasioOutputs;
    buffer_size = pipeasioBufferSize;
  };
  seed = {
    inputs = 2;
    outputs = 2;
    buffer_size = 256;
  }
  // pipeasioPins;
in
stdenv.mkDerivation {
  pname = "ableton-wine";
  inherit (wine) version;

  dontUnpack = true;

  nativeBuildInputs = [
    gnused
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
        # Prune the winegcc toolchain and headers now that pipeasio has used
        # them (wine.nix already dropped the other dev tools).
        rm -rf $out/include $out/share/man
        rm -f $out/bin/winegcc $out/bin/wineg++ $out/bin/winebuild

        # The copied binaries embed the donor wine's store path (configure
        # --prefix) as dormant self-location fallbacks — runtime resolution goes
        # through /proc/self/exe (see the wrapper below). Left in place they drag
        # the full donor tree into this closure (~2x size); scrub them.
        # disallowedReferences below turns any new embedding into a build failure.
        remove-references-to -t ${wine} \
          $out/bin/.wine-wrapped $out/bin/wineserver \
          $out/lib/wine/x86_64-unix/ntdll.so

        # cp -a preserved bin/wine, which execs the ORIGINAL wine store path;
        # wine self-locates its builtin dll dir from /proc/self/exe, so the
        # pipeasio builtins copied above would never be found (regsvr32 fails
        # with STATUS_DLL_NOT_FOUND). Regenerate the wrapper to exec THIS tree.
        # PipeASIO needs no library path help: its unix half carries a RUNPATH
        # to nixpkgs' libpipewire (see nix/pipeasio.nix).
        cat > $out/bin/wine <<WRAPWRP
    #!/bin/sh
    export LD_LIBRARY_PATH="${wine.libPath}\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    # -a "\$0": apploader symlinks (wineboot, regsvr32, ...) need argv[0] intact.
    exec -a "\$0" $out/bin/.wine-wrapped "\$@"
    WRAPWRP
        chmod +x $out/bin/wine

        # -- Launcher script --
        mkdir -p $out/bin $out/libexec
        # Start from the original, then patch Nix-store fallbacks in right after
        # the launcher's dpi_lib=/theme_lib=$HOME/... assignments.
        cp ${launcherSrc} $out/libexec/ableton-live.in
        chmod +w $out/libexec/ableton-live.in
        ${gnused}/bin/sed -i \
          -e '/^[[:space:]]*dpi_lib="\$HOME\/.local\/share\/ableton-wine\/detect-scale\.sh"$/a\
            [ -r "$dpi_lib" ] || dpi_lib="'"$out"'/share/ableton-wine/scripts/detect-scale.sh"' \
          -e '/^[[:space:]]*theme_lib="\$HOME\/.local\/share\/ableton-wine\/detect-theme\.sh"$/a\
            [ -r "$theme_lib" ] || theme_lib="'"$out"'/share/ableton-wine/scripts/detect-theme.sh"' \
          $out/libexec/ableton-live.in
        for lib in detect-scale detect-theme; do
          grep -qF "$out/share/ableton-wine/scripts/$lib.sh" $out/libexec/ableton-live.in \
            || { echo "$lib fallback insertion failed — launcher lib line changed?"; exit 1; }
        done

        install -m755 $out/libexec/ableton-live.in $out/libexec/ableton-live
        rm $out/libexec/ableton-live.in

        # bin/ableton-live: thin shim over the stock launcher. Applies the
        # flake's per-machine knobs idempotently, then execs the launcher.
        # Quoted heredocs ('SHIM'): no build-time shell expansion, but Nix
        # interpolation still applies inside this string; dollar-braces meant
        # for the shim's runtime are escaped with a doubled single quote below.
        # @tokens@ are substituted afterwards.
        cat > $out/bin/ableton-live <<'SHIM'
    #!/bin/sh
    # Generated by nix/ableton-wine.nix. Knobs: ableton-wine.override
    # { dpi, pipeasioBufferSize, pipeasioInputs, pipeasioOutputs }.
    export ABLETON_WINE_ROOT="''${ABLETON_WINE_ROOT:-@out@}"
    export PATH="@out@/bin:$PATH"
    SHIM
        ${lib.optionalString (dpi != null) ''
              cat >> $out/bin/ableton-live <<'SHIM'
          # Flake-pinned prefix DPI: hand the launcher its native 'dpi<N>' DPI block
          # (LogPixels @dpi@, no IFEO) — it recalibrates the prefix idempotently
          # before each start, exactly as it would for a detected scale. A user-set
          # ABLETON_DPI_MODE (auto|preserve|100|fractional|dpi<N>) wins per launch.
          export ABLETON_DPI_MODE="''${ABLETON_DPI_MODE:-dpi@dpi@}"
          SHIM
        ''}
        ${lib.optionalString (pipeasioPins != { }) ''
              cat >> $out/bin/ableton-live <<'SHIM'
          # Flake-pinned PipeASIO settings: config.ini is the driver's only config
          # surface (no env support in 1.2.2); pin exactly the configured keys.
          ini="''${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
          if [ ! -f "$ini" ]; then
              mkdir -p "''${ini%/*}"
              printf '[pipeasio]\ninputs = ${toString seed.inputs}\noutputs = ${toString seed.outputs}\nbuffer_size = ${toString seed.buffer_size}\nfixed_buffer_size = true\nauto_connect = true\n' > "$ini"
          fi
          ${
            lib.concatStrings (
              lib.mapAttrsToList (k: v: ''
                if ! grep -q '^${k}[[:space:]]*= ${toString v}$' "$ini"; then
                    echo "ableton-live: pinning PipeASIO ${k} = ${toString v} (flake)" >&2
                    if grep -q '^${k}[[:space:]]*=' "$ini"; then
                        sed -i 's/^${k}[[:space:]]*=.*/${k} = ${toString v}/' "$ini"
                    else
                        # key dropped from a hand-edited config — append it (the
                        # only section is [pipeasio], so EOF is still inside it)
                        printf '%s\n' '${k} = ${toString v}' >> "$ini"
                    fi
                fi
              '') pipeasioPins
            )
          }SHIM
        ''}
        cat >> $out/bin/ableton-live <<'SHIM'
    exec "@out@/libexec/ableton-live" "$@"
    SHIM
        chmod +x $out/bin/ableton-live
        substituteInPlace $out/bin/ableton-live --replace-fail '@out@' "$out"
        ${lib.optionalString (dpi != null) ''
          substituteInPlace $out/bin/ableton-live --replace-fail '@dpi@' '${toString dpi}'
        ''}

        # -- Supporting scripts (match original repo layout: scripts/ + vendor/) --
        mkdir -p $out/share/ableton-wine/scripts
        mkdir -p $out/share/ableton-wine/vendor
        install -m755 ${../scripts/detect-scale.sh}      $out/share/ableton-wine/scripts/detect-scale.sh
        install -m755 ${../scripts/detect-theme.sh}      $out/share/ableton-wine/scripts/detect-theme.sh
        install -m755 ${../scripts/setup-prefix.sh}      $out/share/ableton-wine/scripts/setup-prefix.sh
        install -m755 ${../scripts/check-live-audio.sh}  $out/share/ableton-wine/scripts/check-live-audio.sh
        install -m755 ${../scripts/check-ntsync.sh}      $out/share/ableton-wine/scripts/check-ntsync.sh
        # Host-policy helpers (both standalone: no wine, no repo paths beyond
        # the Link note installed below).
        install -m755 ${../scripts/setup-realtime.sh}    $out/share/ableton-wine/scripts/setup-realtime.sh
        install -m755 ${../scripts/setup-link.sh}        $out/share/ableton-wine/scripts/setup-link.sh
        # setup-link.sh points at the jack_link build/unit instructions in
        # notes/ — ship that one note so the pointer resolves from the store.
        mkdir -p $out/share/ableton-wine/notes
        install -m644 ${../notes/ABLETON-WINE-LINK.md}   $out/share/ableton-wine/notes/ABLETON-WINE-LINK.md
        # install.sh / uninstall.sh are tarball-install tools; under Nix the
        # store path is immutable and GC'd by nix, so they are not shipped.

        # Patch default WINE_ROOT (and the launcher path) in scripts that use them.
        for script in setup-prefix.sh check-live-audio.sh check-ntsync.sh; do
          substituteInPlace $out/share/ableton-wine/scripts/$script \
            --replace-fail '$HOME/.local/opt/wine-d2d1-nspa-11.11' "$out"
        done
        substituteInPlace $out/share/ableton-wine/scripts/check-live-audio.sh \
          --replace-fail '$HOME/.local/bin/ableton-live' "$out/bin/ableton-live"

        # Vendored winetricks (pinned, tested with this patch series) — not
        # nixpkgs' — so the nix package exercises the same setup path as the
        # tarball install. The winetricks download cache stays out of the store:
        # winetricks writes into its cache dir, and the store is read-only.
        install -m755 ${../vendor/winetricks}       $out/share/ableton-wine/vendor/winetricks
        # cabextract: winetricks corefonts; unzip: setup-prefix's Ableton Live
        # step (unpacks the user's ableton_live*.zip from ~/Proprietary).
        # Symlinks — the closure is identical either way, no need to copy.
        ln -s ${cabextract}/bin/cabextract   $out/bin/cabextract
        ln -s ${lib.getBin unzip}/bin/unzip  $out/bin/unzip

        # -- Desktop entries (manual install; see README) --
        mkdir -p $out/share/ableton-wine/desktop
        cp ${../desktop/ableton-live.desktop.in} \
           $out/share/ableton-wine/desktop/ableton-live.desktop.in
        cp ${../desktop/wine-protocol-ableton.desktop.in} \
           $out/share/ableton-wine/desktop/wine-protocol-ableton.desktop.in

        runHook postInstall
  '';

  # Closure gate: the donor wine tree must not leak into this output's
  # references (see the remove-references-to scrub in installPhase).
  disallowedReferences = [ wine ];

  # Gate: the packaged wine must find, load and register its builtin PipeASIO
  # through Live's load path (regsvr32 dlopens the unix half, so the
  # libpipewire RUNPATH is exercised too). The wrapper-exec failure mode
  # (wine self-locating in the original wine store path) shipped once — the
  # CLSID query catches builtin-name mismatches that presence checks miss.
  doInstallCheck = true;
  installCheckPhase = ''
    grep -qF "$out/bin/.wine-wrapped" $out/bin/wine \
      || { echo "bin/wine wrapper does not exec this tree"; exit 1; }
    # Shim gate: valid shell, no unsubstituted tokens, execs the launcher.
    ${stdenv.shell} -n $out/bin/ableton-live || { echo "launch shim has a syntax error"; exit 1; }
    if grep -Eq '@(out|dpi)@' $out/bin/ableton-live; then echo "launch shim has unsubstituted @tokens@"; exit 1; fi
    grep -qF "exec \"$out/libexec/ableton-live\"" $out/bin/ableton-live \
      || { echo "launch shim does not exec the launcher"; exit 1; }
    echo "PipeASIO registration gate"
    gate=$(mktemp -d)
    export WINEPREFIX=$gate/prefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
    # Bare symlink invocations on purpose: setup-prefix.sh calls "wineboot -u"
    # through PATH, which exercises the apploader argv[0] path (a plain
    # "exec" wrapper without -a "$0" breaks exactly this).
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
