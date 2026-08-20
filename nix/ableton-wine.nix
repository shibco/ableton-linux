{
  stdenv,
  lib,
  removeReferencesTo,
  wine,
  pipeasio,
  ableton-linkd,
  cabextract,
  unzip,
  desktop-file-utils,
  xdg-utils,
  pipewire,
  pkg-config,
  # The frozen patch manifest (patches/): stamped into the tree and diffed
  # against it by the build audit below.
  patchesDir,
  # Pin PipeASIO settings, e.g.
  #   ableton-wine.override { pipeasioSettings = { buffer_size = 256; inputs = 8; }; }
  # The launch shim exports each pin as the driver's matching PIPEASIO_*
  # variable — the driver reads those over config.ini (src/asio.c:1875,
  # "Environment variables override INI values") — so pins win over hand/panel
  # edits without ever rewriting the user's file. A PIPEASIO_* variable already
  # set in the environment still wins per launch; unpinned keys keep following
  # config.ini. Keys and limits are the driver's own (src/config.c, src/asio.c):
  #   inputs, outputs        int, 0..256
  #   buffer_size            int, power of two, 16..8192 frames
  #   sample_rate            int Hz, 0 = follow the PipeWire graph
  #   fixed_buffer_size, auto_connect, follow_device_clock   bool
  #   output_device, input_device  string, <= 255 chars
  #   node_name              string, <= 31 chars (the driver's client-name cap)
  pipeasioSettings ? { },
}:

let
  s = pipeasioSettings;
  # config.ini key -> the driver's env override name (src/asio.c:1875-1950).
  envName = {
    inputs = "PIPEASIO_NUMBER_INPUTS";
    outputs = "PIPEASIO_NUMBER_OUTPUTS";
    buffer_size = "PIPEASIO_PREFERRED_BUFFERSIZE";
    fixed_buffer_size = "PIPEASIO_FIXED_BUFFERSIZE";
    sample_rate = "PIPEASIO_SAMPLE_RATE";
    auto_connect = "PIPEASIO_CONNECT_TO_HARDWARE";
    follow_device_clock = "PIPEASIO_FOLLOW_DEVICE_CLOCK";
    output_device = "PIPEASIO_OUTPUT_DEVICE";
    input_device = "PIPEASIO_INPUT_DEVICE";
    node_name = "PIPEASIO_CLIENT_NAME";
  };
  validKeys = lib.attrNames envName;
  unknownKeys = lib.filter (k: !(lib.elem k validKeys)) (lib.attrNames s);
  intIn = k: lo: hi: !(s ? ${k}) || (lib.isInt s.${k} && lo <= s.${k} && s.${k} <= hi);
  isPow2 = n: lib.isInt n && n > 0 && builtins.bitAnd n (n - 1) == 0;
  strOk = k: max: !(s ? ${k}) || (lib.isString s.${k} && !lib.hasInfix "\n" s.${k} && lib.stringLength s.${k} <= max);

  # The env path parses booleans as on/off only (config.ini also takes true/1).
  renderValue = v: if lib.isBool v then (if v then "on" else "off") else toString v;

  # One guarded export per pinned key; interpolated into the launch shim below.
  pinBlock = lib.optionalString (s != { }) (
    "# pipeasioSettings pins (nix). Guarded: your own PIPEASIO_* wins per launch.\n"
    + lib.concatStrings (
      lib.mapAttrsToList (
        k: v: "[ -n \"\${${envName.${k}}:-}\" ] || export ${envName.${k}}=${lib.escapeShellArg (renderValue v)}\n"
      ) s
    )
  );
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
assert lib.assertMsg (strOk "output_device" 255 && strOk "input_device" 255)
  "ableton-wine: pipeasioSettings.output_device/input_device must be single-line strings of at most 255 chars (the driver ignores longer env overrides)";
assert lib.assertMsg (strOk "node_name" 31)
  "ableton-wine: pipeasioSettings.node_name must be a single-line string of at most 31 chars (the driver's client-name cap)";

stdenv.mkDerivation {
  pname = "ableton-wine";
  inherit (wine) version;

  dontUnpack = true;

  nativeBuildInputs = [
    removeReferencesTo
    pkg-config
  ];
  buildInputs = [ pipewire ];

  installPhase = ''
        runHook preInstall

        # -- Wine tree + PipeASIO --
        cp -a ${wine} $out
        chmod -R u+w $out
        # Both names: Wine resolves pipeasio64.dll to builtin "pipeasio.dll"
        # (from its spec) and looks for the unix half under that name. The
        # aliases stay RELATIVE symlinks — upstream's CMake install contract,
        # which build-audit.sh verifies.
        for pair in \
          pipeasio64.dll:x86_64-windows \
          pipeasio64.dll.so:x86_64-unix; do
          file=''${pair%%:*}
          dir=''${pair##*:}
          cp -f ${pipeasio}/lib/wine/$dir/$file $out/lib/wine/$dir/
          ln -sfn $file $out/lib/wine/$dir/''${file/pipeasio64/pipeasio}
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
    # Same reason bin/wine in the wine tree exports it: winegstreamer finds its
    # mp3/mp4/wma decoders through this path, not through the linker.
    export GST_PLUGIN_SYSTEM_PATH_1_0="${wine.gstPluginPath}\''${GST_PLUGIN_SYSTEM_PATH_1_0:+:\$GST_PLUGIN_SYSTEM_PATH_1_0}"
    # -a "\$0": apploader symlinks (wineboot, regsvr32, ...) need argv[0] intact.
    exec -a "\$0" $out/bin/.wine-wrapped "\$@"
    WRAPWRP
        chmod +x $out/bin/wine

        # -- Launcher --
        mkdir -p $out/bin $out/libexec
        install -m755 ${../scripts/ableton-live} $out/libexec/ableton-live
        # The launcher sources this for ABLETON_SHORTCUTS=take (holding the GNOME
        # shortcuts that shadow Live's own). Unlike the detection libs it looks
        # for it beside itself, not under share/ableton-wine/scripts, so it is
        # staged next to the launcher; without it that feature silently does
        # nothing here while it works from the .run install.
        install -m644 ${../scripts/shortcut-hold.sh} $out/libexec/shortcut-hold.sh
        # The launcher and max9 resolve their config/lifecycle helpers beside
        # themselves first ($launcher_here/lib), then under the user's
        # ~/.local/share/ableton-wine (which only installer.sh populates).
        mkdir -p $out/libexec/lib
        for helper in config.sh lifecycle.sh manifest.sh pipeasio.sh; do
          install -m644 ${../scripts/lib}/$helper $out/libexec/lib/$helper
        done
        # Quoted heredoc ('SHIM'): nothing shell-expands at build; @out@ is
        # substituted after. Runtime shell ''${...} is written with the '''' escape;
        # the pinBlock lines (nix-interpolated) are already literal shell.
        cat > $out/bin/ableton-live <<'SHIM'
    #!/bin/sh
    # Generated by nix/ableton-wine.nix. PipeASIO pins come from
    # ableton-wine.override { pipeasioSettings = { ... }; }
    export ABLETON_WINE_ROOT="''${ABLETON_WINE_ROOT:-@out@}"
    # Kit bin last: the host's own update-desktop-database and xdg-mime are
    # preferred when it has them, and these stand in when it does not.
    export PATH="@out@/bin:$PATH:@out@/share/ableton-wine/bin"
    ${pinBlock}exec "@out@/libexec/ableton-live" "$@"
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

        # -- Windows-executable runner (same runtime and prefix) --
        # Plugin installers, updaters and copy-protection tools need a wine
        # pointed at the Ableton prefix. Bare `wine` uses ~/.wine, so a Nix
        # user following the README would install the plugin into a prefix
        # Live never opens. Inherited loader/prefix variables are dropped so
        # this always drives THIS tree; WINEDLLOVERRIDES stays, installers
        # legitimately need it.
        cat > $out/bin/ableton-wine <<'SHIM'
    #!/bin/sh
    # Generated by nix/ableton-wine.nix.
    unset WINELOADER WINEDLLPATH WINEARCH WINESERVER
    export ABLETON_WINE_ROOT="''${ABLETON_WINE_ROOT:-@out@}"
    export WINEPREFIX="''${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
    export PATH="@out@/bin:$PATH"
    export WINEDEBUG="''${WINEDEBUG:--all}"
    exec "@out@/bin/wine" "$@"
    SHIM
        chmod +x $out/bin/ableton-wine
        substituteInPlace $out/bin/ableton-wine --replace-fail '@out@' "$out"

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
        # setup-prefix.sh, setup-link.sh and ableton-linkctl source these from
        # $here/lib before falling back to the user's staging.
        mkdir -p $out/share/ableton-wine/scripts/lib
        for helper in config.sh lifecycle.sh manifest.sh pipeasio.sh; do
          install -m644 ${../scripts/lib}/$helper $out/share/ableton-wine/scripts/lib/$helper
        done
        # The Link lifecycle controller both launchers call; installer.sh
        # stages it under ~/.local/share, the launchers fall back to this copy.
        install -m755 ${../scripts/ableton-linkctl}      $out/share/ableton-wine/scripts/ableton-linkctl
        # Sourced by the launcher: every path it writes into user configuration
        # goes through the stable link it maintains, never this store path
        # (which a garbage collection can delete and an upgrade renames). Same
        # $HOME-then-$WINE_ROOT lookup as the detection libs.
        install -m755 ${../scripts/runtime-link.sh}      $out/share/ableton-wine/scripts/runtime-link.sh
        # install.sh / uninstall.sh / installer.sh are tarball tools — not shipped.

        # -- PipeWire compatibility probe --
        # setup-prefix.sh refuses to touch a prefix before
        # ableton_pipewire_preflight has run $WINE_ROOT/bin/pipewire-version-probe.
        # The .run kit ships a host-resolving build; this one pins the closure's
        # libpipewire through its RUNPATH (build-audit.sh allows the store pin).
        $CC -std=c11 -O2 -Wall -Wextra -Werror \
          $(pkg-config --cflags libpipewire-0.3) \
          ${../tools/pipewire-version-probe.c} \
          -lpipewire-0.3 -o $out/bin/pipewire-version-probe

        # -- Ableton Link session anchor --
        # config.sh defaults ABLETON_LINKD to ~/.local/share/ableton-wine/ableton-linkd,
        # which only installer.sh populates; the staged config.sh copies below
        # default to this store copy instead. ABLETON_LINKD still overrides.
        # The unit template stays verbatim: setup-link.sh renders @ABLETON_LINKD@
        # itself from the resolved daemon path.
        install -m755 ${ableton-linkd}/bin/ableton-linkd \
          $out/share/ableton-wine/ableton-linkd
        install -m644 ${../scripts/ableton-linkd.service} \
          $out/share/ableton-wine/ableton-linkd.service

        # Point the shipped defaults at the store. The launchers and setup
        # scripts now read their runtime root and daemon path from lib/config.sh,
        # so the compatibility defaults are substituted there (both staged
        # copies); check-live-audio.sh and check-ntsync.sh keep their own.
        for config_copy in libexec/lib/config.sh share/ableton-wine/scripts/lib/config.sh; do
          substituteInPlace $out/$config_copy \
            --replace-fail '$HOME/.local/opt/$ABLETON_RUNTIME_NAME' "$out" \
            --replace-fail '"''${configured:-$ABLETON_DATA_HOME/ableton-linkd}"' \
                           "\"\''${configured:-$out/share/ableton-wine/ableton-linkd}\""
        done
        for script in check-live-audio.sh check-ntsync.sh; do
          substituteInPlace $out/share/ableton-wine/scripts/$script \
            --replace-fail '$HOME/.local/opt/wine-d2d1-nspa-11.13' "$out"
        done
        substituteInPlace $out/share/ableton-wine/scripts/check-live-audio.sh \
          --replace-fail '$HOME/.local/bin/ableton-live' "$out/bin/ableton-live"

        # The vendored (pinned) winetricks + payload cache, not nixpkgs' — same
        # setup path as the tarball install; the Live 12 verbs need no network.
        install -m755 ${../vendor/winetricks}       $out/share/ableton-wine/vendor/winetricks
        cp -a ${../vendor/winetricks-cache}         $out/share/ableton-wine/vendor/winetricks-cache
        # cabextract: winetricks corefonts; unzip: setup-prefix's Live installer
        # step; update-desktop-database and xdg-mime: the launcher's handler
        # repair, which otherwise reports them missing on a NixOS that carries
        # neither, leaving the ableton:// callback unregistered. Kit bin, not
        # $out/bin — setup-prefix.sh resolves these via its kit-bin PATH
        # prepend; $out/bin is merged onto user PATHs by profile installs.
        mkdir -p $out/share/ableton-wine/bin
        ln -s ${cabextract}/bin/cabextract   $out/share/ableton-wine/bin/cabextract
        ln -s ${lib.getBin unzip}/bin/unzip  $out/share/ableton-wine/bin/unzip
        ln -s ${lib.getBin desktop-file-utils}/bin/update-desktop-database \
              $out/share/ableton-wine/bin/update-desktop-database
        ln -s ${lib.getBin xdg-utils}/bin/xdg-mime $out/share/ableton-wine/bin/xdg-mime

        # -- Max for Live font fallback (Bitstream Vera) --
        # MaxPlug's fallback chain terminates at the three Vera families, so a
        # device that asks for a typeface the prefix lacks hangs Live outright —
        # frozen window, audio still playing (see
        # notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md). A
        # Windows or macOS host always has them; a minimal NixOS has no host
        # font package to fall back on, so they must ship here.
        # setup-prefix.sh's install_maxplug_fallback_fonts() takes them from
        # <kit>/vendor/fonts, which for this package is share/ableton-wine.
        # Checked against the manifest make-installer.sh uses: it pins content
        # AND completeness, so a missing or substituted face fails the build
        # instead of shipping a runtime that can freeze Live's UI.
        install -m644 ${../vendor/bitstream-vera.sha256} \
          $out/share/ableton-wine/vendor/bitstream-vera.sha256
        mkdir -p $out/share/ableton-wine/vendor/fonts/bitstream-vera
        # COPYRIGHT.TXT travels beside the faces: the Bitstream license permits
        # redistribution only while its notices come along.
        install -m644 ${../vendor/fonts/bitstream-vera}/*.ttf \
                      ${../vendor/fonts/bitstream-vera}/COPYRIGHT.TXT \
                      $out/share/ableton-wine/vendor/fonts/bitstream-vera/
        ( cd $out/share/ableton-wine/vendor && sha256sum -c --quiet bitstream-vera.sha256 ) \
          || { echo "!! vendored Bitstream Vera faces do not match vendor/bitstream-vera.sha256 — Max for Live devices with a missing typeface would freeze Live" >&2; exit 1; }

        # -- Desktop entries --
        # Rendered into share/applications so profiles surface them; Path= is
        # unknowable at build time and the launchers are cwd-agnostic.
        # wine.desktop (from the wine tree copy) is Wine's .exe/.msi MIME
        # handler — not this package's job.
        #
        # Name/icon are install.sh's generic pre-install values, and
        # StartupWMClass is dropped for install.sh's own reason: the class is
        # the Live executable's filename, it differs per edition, and the store
        # cannot see the user's prefix. A guess only matches Suite; for
        # everyone else it associates the window with nothing, which is worse
        # than the desktop's own fallback matching. install.sh can fill it in
        # later from an installed prefix, and the launcher heals the entry it
        # writes; neither applies to a read-only store entry, so it stays out.
        rm -f $out/share/applications/wine.desktop
        mkdir -p $out/share/applications $out/share/ableton-wine/desktop
        render_desktop() {
          sed -e "s#@BIN@#$out/bin#" \
              -e 's#@NAME@#Ableton Live#' \
              -e 's#@ICON@#live-suite#' \
              -e '/^StartupWMClass=@WMCLASS@$/d' \
              -e '/^Path=@PREFIX@/d' "$1" > "$2"
          if grep -qE '@[A-Z]+@' "$2"; then
            echo "!! unsubstituted token in $2:" >&2; grep -E '@[A-Z]+@' "$2" >&2; exit 1
          fi
        }
        render_desktop ${../desktop/ableton-live.desktop.in} \
          $out/share/applications/ableton-live.desktop
        # The authorisation handlers carry the project's reverse-DNS desktop
        # IDs (lib/config.sh); the launcher's repair_handler_entries reads
        # staged copies at $ABLETON_DATA_HOME/<id> (install.sh) and falls back
        # to this root.
        render_desktop ${../desktop/ableton-linux-protocol.desktop.in} \
          "$out/share/ableton-wine/io.github.shibco.ableton-linux.protocol.desktop"
        render_desktop ${../desktop/ableton-linux-auz.desktop.in} \
          "$out/share/ableton-wine/io.github.shibco.ableton-linux.auz.desktop"
        for id in io.github.shibco.ableton-linux.protocol.desktop \
                  io.github.shibco.ableton-linux.auz.desktop; do
          cp "$out/share/ableton-wine/$id" "$out/share/applications/$id"
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

  # Stamped after fixup: strip/patchelf rewrite the recorded binaries, so
  # hashing them any earlier writes records the audit's byte-match rejects.
  postFixup = ''
        # -- Builder manifest --
        # The container records its apt package set here; this build's inputs
        # are the pinned nix closure, so record those versions instead. Same
        # contract build-audit.sh checks: sorted, unique, two fields per line.
        printf '%s\n' \
          "ableton-linkd ${ableton-linkd.version or "4.0"}" \
          "cabextract ${cabextract.version}" \
          "pipeasio 1.5.0" \
          "pipewire ${pipewire.version}" \
          "unzip ${unzip.version}" \
          "wine-d2d1-nspa ${wine.version}" \
          | LC_ALL=C sort -u > $out/ABLETON-WINE-BUILD-PACKAGES.txt

        # -- Provenance --
        # The two files the tarball carries (scripts/container-build.sh), for
        # the same two reasons: build-audit.sh diffs the stack against
        # patches/SERIES.sha256 and reads the patch count out of the stamp, and
        # a bug report can name the runtime it came from. Regenerated from the
        # patches this build applied, never copied from the manifest — a copy
        # would only agree with itself.
        ( cd ${patchesDir} && sha256sum 00*.patch pipeasio/*.patch ) \
          > $out/ABLETON-WINE-PATCH-STACK.txt
        n_wine=$(ls ${patchesDir}/00*.patch | wc -l)
        n_asio=$(ls ${patchesDir}/pipeasio/*.patch | wc -l)
        stack_sha=$(sha256sum $out/ABLETON-WINE-PATCH-STACK.txt | awk '{print $1}')
        sha_of() { sha256sum "$out/$1" | awk '{print $1}'; }
        # $out is the whole identity here: it is content-addressed over every
        # input, including the Wine and PipeASIO derivations this tree was
        # assembled from. Their store paths cannot be named in this file —
        # disallowedReferences keeps the donor Wine out of the closure.
        cat > $out/ABLETON-WINE-BUILD-INFO.txt <<INFO
    dist-version: nix
    package:      $out
    wine:         wine-${wine.version}
    base:         giang17/wine d2d1-dcomp-11.13 @ 5c23dd1c
    patches:      $((n_wine + n_asio))
    wine-patches: $n_wine
    pipeasio-patches: $n_asio
    patch-stack:  $stack_sha
    pipeasio:     1.5.0
    pipeasio-panel: skipped
    pipeasio-settings: skipped (disabled)
    pipewire:     pinned in the closure via RUNPATH (the .run resolves the host's)
    gst-decoders: base/good/bad/ugly/libav pinned in the closure (the .run uses the host's)
    ntsync:       yes (vendored linux/ntsync.h, gated in nix/wine.nix)
    libusb-pe:    $(sha_of lib/wine/x86_64-windows/libusb-1.0.dll)
    libusb-unix:  $(sha_of lib/wine/x86_64-unix/libusb-1.0.so)
    portal-unix:  $(sha_of lib/wine/x86_64-unix/comdlg32.so)
    pipeasio-pe:  $(sha_of lib/wine/x86_64-windows/pipeasio64.dll)
    pipeasio-unix: $(sha_of lib/wine/x86_64-unix/pipeasio64.dll.so)
    pipewire-version-probe: $(sha_of bin/pipewire-version-probe)
    builder-packages: $(sha_of ABLETON-WINE-BUILD-PACKAGES.txt)
    built-by:     nix
    INFO
  '';

  disallowedReferences = [ wine ];

  # regsvr32 dlopens the unix half (exercising the libpipewire RUNPATH); the
  # CLSID query catches builtin-name mismatches that presence checks miss.
  doInstallCheck = true;
  installCheckPhase = ''
    grep -qF "$out/bin/.wine-wrapped" $out/bin/wine \
      || { echo "bin/wine wrapper does not exec this tree"; exit 1; }
    # The media bridge and its plugin path have to survive the copy: the tree
    # ships winegstreamer, and the regenerated wrapper above must still point at
    # the plugins, or mp3/mp4/wma import fails with no message (issue #44).
    [ -s $out/lib/wine/x86_64-unix/winegstreamer.so ] \
      || { echo "winegstreamer.so is missing from the shipped tree"; exit 1; }
    grep -qF 'export GST_PLUGIN_SYSTEM_PATH_1_0="${wine.gstPluginPath}' $out/bin/wine \
      || { echo "bin/wine does not export the GStreamer plugin path"; exit 1; }
    ${stdenv.shell} -n $out/bin/ableton-live || { echo "launch shim has a syntax error"; exit 1; }
    if grep -qF '@out@' $out/bin/ableton-live; then echo "launch shim has unsubstituted @out@ tokens"; exit 1; fi
    grep -qF "exec \"$out/libexec/ableton-live\"" $out/bin/ableton-live \
      || { echo "launch shim does not exec the launcher"; exit 1; }
    # The Wine runner: a Nix user's plugin installers must land in the Ableton
    # prefix, not in a fresh ~/.wine that Live never opens.
    ${stdenv.shell} -n $out/bin/ableton-wine || { echo "ableton-wine shim has a syntax error"; exit 1; }
    if grep -qF '@out@' $out/bin/ableton-wine; then echo "ableton-wine shim has unsubstituted @out@ tokens"; exit 1; fi
    grep -qF 'WINEPREFIX="''${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"' $out/bin/ableton-wine \
      || { echo "ableton-wine shim does not default WINEPREFIX to the Ableton prefix"; exit 1; }
    # The shipped scripts must default to THIS runtime. The tarball's
    # ~/.local/opt path does not exist on Nix, and a script that keeps it
    # aborts with "no wine at ..." for every Nix user who runs it. The setup
    # scripts and launchers read theirs from the staged lib/config.sh copies.
    for f in scripts/check-live-audio.sh scripts/check-ntsync.sh \
             scripts/lib/config.sh; do
      if grep -qF '.local/opt/wine-d2d1-nspa' $out/share/ableton-wine/$f; then
        echo "$f still defaults to the tarball wine root"; exit 1
      fi
    done
    if grep -qF '.local/opt/wine-d2d1-nspa' $out/libexec/lib/config.sh; then
      echo "libexec/lib/config.sh still defaults to the tarball wine root"; exit 1
    fi
    # The launchers and setup scripts hard-fail without their config and
    # lifecycle helpers; they resolve them beside themselves first.
    for d in libexec/lib share/ableton-wine/scripts/lib; do
      for helper in config.sh lifecycle.sh manifest.sh pipeasio.sh; do
        [ -r $out/$d/$helper ] || { echo "$helper is not staged in $d"; exit 1; }
      done
    done
    # setup-prefix.sh refuses to run before the PipeWire preflight probe passes.
    [ -x $out/bin/pipewire-version-probe ] \
      || { echo "pipewire-version-probe is not staged"; exit 1; }
    LC_ALL=C $out/bin/pipewire-version-probe >/dev/null 2>&1 || [ $? -ne 127 ] \
      || { echo "pipewire-version-probe cannot resolve its libraries"; exit 1; }
    # Both launchers fall back to this Link controller when installer.sh has
    # staged nothing under ~/.local/share.
    [ -x $out/share/ableton-wine/scripts/ableton-linkctl ] \
      || { echo "ableton-linkctl is not staged"; exit 1; }
    for f in libexec/ableton-live libexec/max9; do
      grep -qF 'share/ableton-wine/scripts/ableton-linkctl' $out/$f \
        || { echo "$f does not fall back to the staged ableton-linkctl"; exit 1; }
    done
    # check-ntsync.sh resolves its probe relative to its own directory.
    [ -f $out/share/ableton-wine/beta/tester-kit/probes/windows/ntsyncprobe.exe ] \
      || { echo "the ntsync probe is not staged where check-ntsync.sh looks for it"; exit 1; }
    # The Vera faces must sit where setup-prefix.sh's kit_root() finds them:
    # vendor/ beside the scripts directory, the same place vendor/winetricks is
    # resolved from. Anywhere else and it silently falls through to host font
    # directories that do not exist here, leaving Max for Live able to freeze
    # Live's UI on a missing typeface.
    [ -f $out/share/ableton-wine/vendor/winetricks ] \
      || { echo "vendor/winetricks moved — setup-prefix.sh's kit root no longer resolves here"; exit 1; }
    for tool in cabextract unzip update-desktop-database xdg-mime; do
      [ -x $out/share/ableton-wine/bin/$tool ] \
        || { echo "$tool is not staged in the kit bin — the prefix setup or the launcher would depend on a host install"; exit 1; }
      [ ! -e $out/bin/$tool ] \
        || { echo "bin/$tool would collide with the $tool package in a profile install"; exit 1; }
    done
    for f in Vera VeraBd VeraIt VeraBI VeraMono VeraMoBd VeraMoIt VeraMoBI VeraSe VeraSeBd; do
      [ -s $out/share/ableton-wine/vendor/fonts/bitstream-vera/$f.ttf ] \
        || { echo "$f.ttf is not staged where setup-prefix.sh looks for the M4L fallback fonts"; exit 1; }
    done
    [ -s $out/share/ableton-wine/vendor/fonts/bitstream-vera/COPYRIGHT.TXT ] \
      || { echo "the Bitstream Vera notice does not ship beside the faces"; exit 1; }
    # The staged config.sh copies must default the Link daemon to the staged
    # store copy: the compatibility default under ~/.local/share is only
    # populated by installer.sh, which never runs on Nix.
    [ -x $out/share/ableton-wine/ableton-linkd ] \
      || { echo "ableton-linkd is not staged"; exit 1; }
    for f in libexec/lib/config.sh share/ableton-wine/scripts/lib/config.sh; do
      grep -qF "$out/share/ableton-wine/ableton-linkd" $out/$f \
        || { echo "$f does not default ABLETON_LINKD to the staged daemon"; exit 1; }
    done
    # setup-link.sh renders the user unit from the template itself.
    grep -qF '@ABLETON_LINKD@' $out/share/ableton-wine/ableton-linkd.service \
      || { echo "the staged unit template lost its @ABLETON_LINKD@ token"; exit 1; }
    # Nothing this package installs may write THIS store path into user
    # configuration: it is deleted by a garbage collection of an unrooted
    # `nix run` closure and superseded by every upgrade. The launcher's handler
    # entries route through the runtime link, so its library has to be staged
    # where the $HOME-then-$WINE_ROOT lookup finds it, and the launcher must
    # still call it. (setup-link.sh's unit deliberately names the exact
    # resolved daemon — its ownership digests require it — and the launcher's
    # per-launch GC root keeps that path alive; re-run setup-link after an
    # upgrade to re-point an always-on unit.)
    [ -r $out/share/ableton-wine/scripts/runtime-link.sh ] \
      || { echo "runtime-link.sh is not staged for the launcher and setup-link.sh"; exit 1; }
    # Same failure mode as the fonts: the launcher resolves this one beside
    # itself, so a miss is silent — ABLETON_SHORTCUTS=take would just do nothing.
    [ -r $out/libexec/shortcut-hold.sh ] \
      || { echo "shortcut-hold.sh is not staged beside the launcher"; exit 1; }
    grep -qF '}/shortcut-hold.sh' $out/libexec/ableton-live \
      || { echo "the launcher no longer resolves shortcut-hold.sh beside itself"; exit 1; }
    ${stdenv.shell} -n $out/share/ableton-wine/scripts/runtime-link.sh \
      || { echo "runtime-link.sh has a syntax error"; exit 1; }
    grep -qF 'ableton_runtime_link' $out/libexec/ableton-live \
      || { echo "the launcher does not route user configuration through the runtime link"; exit 1; }
    # The handler entries the launcher repairs from this root must carry the
    # project's reverse-DNS IDs and exec this package's launcher.
    for id in io.github.shibco.ableton-linux.protocol.desktop \
              io.github.shibco.ableton-linux.auz.desktop; do
      [ -f "$out/share/ableton-wine/$id" ] \
        || { echo "$id is not staged for the launcher's handler repair"; exit 1; }
      grep -qF "Exec=$out/bin/ableton-live" "$out/share/ableton-wine/$id" \
        || { echo "$id does not exec this package's launcher"; exit 1; }
    done
    # No guessed window class: it is per edition, the store cannot see the
    # prefix, and a wrong one associates the window with nothing at all.
    if grep -q '^StartupWMClass=' $out/share/applications/ableton-live.desktop; then
      echo "the menu entry ships a guessed StartupWMClass"; exit 1
    fi
    echo "PipeASIO registration gate"
    # No env -i here, unlike wine.nix's smoke gate. That one needs a fixed,
    # explicit environment because Nix disables address-space randomisation,
    # which makes wine's preloader reservations a function of the builder's
    # environment size; the smoke gate is the one that got bitten. This gate
    # runs against the assembled tree and has never shown it, and env -i would
    # cost it the loader variables the PipeASIO half needs. If it ever does
    # start SIGSEGV'ing on an unrelated input change, the comment in
    # nix/wine.nix's installCheckPhase is the reason and env -i is the fix.
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
    # Full build audit, the same one make-installer.sh runs against the
    # tarball: every patch verified against the tree that shipped it, the
    # provenance stamps matched to the frozen manifest, and the structural
    # invariants (winealsa, winegstreamer, the 64-bit-only libusb bridge, the
    # PipeASIO pair, DT_NEEDED and RUNPATH) checked. Those invariants are the
    # must list this package used to reimplement one gate at a time.
    # It resolves the manifest as ../patches beside itself, so give it a kit.
    # The nix profile relaxes ONLY the container-pipeline provenance records
    # (sanitizer runs, git source-tree digest, installer helper hashes) this
    # build does not produce; everything structural still fails hard.
    echo "Build audit"
    auditkit=$(mktemp -d)
    mkdir -p $auditkit/scripts
    cp ${../scripts/build-audit.sh} $auditkit/scripts/build-audit.sh
    cp -r ${patchesDir} $auditkit/patches
    ABLETON_AUDIT_PROFILE=nix bash $auditkit/scripts/build-audit.sh $out
  '';

  meta = {
    description = "Ableton Live runtime — patched Wine 11.13 + PipeASIO + Link anchor + launcher";
    mainProgram = "ableton-live"; # lets `nix run` work on .override variants too
    platforms = [ "x86_64-linux" ];
    # wine LGPL-2.1+, pipeasio GPL-3.0+, ableton-linkd GPL-2.0+ (Link SDK)
    license = with lib.licenses; [ lgpl21Plus gpl3Plus gpl2Plus ];
  };
}
