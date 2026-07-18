#!/usr/bin/env bash
# End-user step 2: create or refresh the Ableton Wine prefix. Idempotent.
# Does not install Ableton Live itself and carries no license.
# --refresh: maintenance pass on an EXISTING prefix (used by the .run's update
# mode) — re-applies registry policy and heals runtime DLLs, but skips the slow
# winetricks pass; the fonts/runtimes it installs are already in the prefix.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

refresh=0
case "${1:-}" in
    --refresh) refresh=1 ;;
    "") ;;
    *) echo "!! unknown option: $1 (only --refresh is supported)" >&2; exit 2 ;;
esac

unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH WINEESYNC WINEFSYNC
WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.11}"
export WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
export PATH="$WINE_ROOT/bin:$PATH"
export WINEDEBUG=-all
export WINESERVER="$WINE_ROOT/bin/wineserver"

[ -x "$WINE_ROOT/bin/wine" ] || { echo "!! patched wine not at $WINE_ROOT — run ./scripts/install.sh first"; exit 1; }
for required in \
    lib/wine/x86_64-unix/comdlg32.so \
    lib/wine/x86_64-windows/libusb-1.0.dll \
    lib/wine/x86_64-unix/libusb-1.0.so \
    lib/wine/x86_64-windows/pipeasio64.dll \
    lib/wine/x86_64-windows/pipeasio.dll \
    lib/wine/x86_64-unix/pipeasio64.dll.so \
    lib/wine/x86_64-unix/pipeasio.dll.so; do
    [ -s "$WINE_ROOT/$required" ] || { echo "!! packaged runtime is missing $required"; exit 1; }
done

# Host tools winetricks needs to unpack the redistributables.
for t in cabextract; do
    command -v "$t" >/dev/null || echo "!! missing host tool '$t' (needed by winetricks) — install it (e.g. 'pacman -S cabextract' / 'apt install cabextract')"
done

# DPI blocks: 100% -> LogPixels=96 + no IFEO dpiAwareness; 125% -> LogPixels=192 + IFEO=2. auto applies
# the detected block on a fresh prefix, preserves an existing one, refuses uncalibrated/undetectable scales.
# The dpiAwareness IFEO is keyed on the exe name, so it is applied per installed Live (any edition);
# on a fresh prefix Live isn't installed yet — the launcher applies it on every start.
ifeo_root='HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
live_exe_names() {   # basenames of every Live exe installed in this prefix
    ls "$WINEPREFIX"/drive_c/ProgramData/Ableton/*/Program/"Ableton Live"*.exe 2>/dev/null \
        | while IFS= read -r f; do basename "$f"; done
}

# Shared display-scale detection (see detect-scale.sh).
. "$here/detect-scale.sh"
detect_display_scale() { ableton_detect_scale; }

# Shared host light/dark-scheme detection (see detect-theme.sh).
. "$here/detect-theme.sh"

# Shared Wine OpenGL-backend policy (see opengl-policy.sh).
. "$here/opengl-policy.sh"

block_for_scale() {  # scale -> calibrated block name, fails on uncalibrated
    case "$1" in
        1|1.0)  echo 100 ;;
        1.25)   echo fractional ;;
        *)      return 1 ;;
    esac
}

current_dpi_block() {  # what an EXISTING prefix holds: 100 | fractional | custom
    local lp ifeo=absent name installs=0
    lp="$(wine reg query 'HKCU\Control Panel\Desktop' /v LogPixels 2>/dev/null \
          | awk '$1=="LogPixels"{gsub(/\r/,"",$3); print tolower($3)}')"   # reg output is CRLF
    [ -n "$lp" ] || lp=0x60          # wineboot default is 96
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        installs=1
        if wine reg query "$ifeo_root\\$name" /v dpiAwareness >/dev/null 2>&1; then
            ifeo=present
        fi
    done < <(live_exe_names)
    if [ "$lp" = 0x60 ] && [ "$ifeo" = absent ]; then
        echo 100
    elif [ "$lp" = 0xc0 ] && { [ "$ifeo" = present ] || [ "$installs" -eq 0 ]; }; then
        echo fractional    # no Live installed yet: LogPixels alone decides; the launcher adds the IFEO
    else
        echo custom
    fi
}

check_mutter_knob() {  # warn when mutter's xwayland-native-scaling disagrees
    local feats
    command -v gsettings >/dev/null 2>&1 || return 0
    feats="$(gsettings get org.gnome.mutter experimental-features 2>/dev/null)" || return 0
    case "$1" in
        100)
            if printf '%s' "$feats" | grep -q xwayland-native-scaling; then
                echo "!! mutter experimental-features lists xwayland-native-scaling —"
                echo "!! the 100% DPI block expects it absent; remove it from"
                echo "!!   org.gnome.mutter experimental-features (gsettings)"
            fi ;;
        fractional)
            if ! printf '%s' "$feats" | grep -q xwayland-native-scaling; then
                echo "!! mutter experimental-features lacks xwayland-native-scaling —"
                echo "!! the fractional DPI block expects it present; add it to"
                echo "!!   org.gnome.mutter experimental-features (gsettings)"
            fi ;;
    esac
    return 0
}

fresh_prefix=0
[ -f "$WINEPREFIX/system.reg" ] || fresh_prefix=1
if [ "$refresh" -eq 1 ] && [ "$fresh_prefix" -eq 1 ]; then
    echo "!! --refresh needs an existing prefix at $WINEPREFIX — run without it to create one" >&2
    exit 2
fi

# Resolve the mode now so a fresh prefix fails fast, before wineboot/winetricks run.
dpi_mode="${ABLETON_DPI_MODE:-auto}"
dpi_block=preserve
case "$dpi_mode" in
  100|fractional)
    dpi_block="$dpi_mode"
    ;;
  preserve)
    ;;
  auto)
    if scale="$(detect_display_scale)"; then
        if block="$(block_for_scale "$scale")"; then
            if [ "$fresh_prefix" -eq 1 ]; then
                echo "   display scale $scale detected -> will apply the '$block' DPI block"
                dpi_block="$block"
            else
                have="$(current_dpi_block)"
                if [ "$have" = "$block" ]; then
                    echo "   display scale $scale detected; existing prefix already holds the '$block' block"
                else
                    echo "!! display scale $scale wants the '$block' DPI block, but this existing prefix holds '$have'"
                    echo "!! preserving it — rerun with ABLETON_DPI_MODE=$block to recalibrate deliberately"
                fi
            fi
        elif [ "$fresh_prefix" -eq 1 ]; then
            echo "!! display scale $scale has no calibrated DPI block (only 100% and 125% are)" >&2
            echo "!! rerun with an explicit ABLETON_DPI_MODE=100 or ABLETON_DPI_MODE=fractional" >&2
            exit 2
        else
            echo "!! display scale $scale has no calibrated DPI block — preserving existing prefix values"
        fi
    elif [ "$fresh_prefix" -eq 1 ]; then
        echo "!! cannot detect the display scale (non-GNOME desktop or headless session?)" >&2
        echo "!! a fresh prefix needs an explicit ABLETON_DPI_MODE=100 or ABLETON_DPI_MODE=fractional" >&2
        exit 2
    else
        echo "   cannot detect display scale; preserving existing prefix values"
    fi
    ;;
  *)
    echo "!! ABLETON_DPI_MODE must be auto, preserve, 100, or fractional" >&2
    exit 2
    ;;
esac

echo "== [1/5] initialize prefix at $WINEPREFIX =="
wineboot -u
"$WINESERVER" -w

if [ "$refresh" -eq 1 ]; then
    echo "== [2/5] winetricks: skipped (--refresh keeps the installed fonts/runtimes) =="
else
    echo "== [2/5] winetricks: corefonts vcrun2022 mfc42 =="
    export W_CACHE_OVERRIDE=""            # unused
    export WINETRICKS_LATEST_VERSION_CHECK=disabled
    export WINETRICKS_SUPER_QUIET=1
    # Use the bundled payload cache if present (mfc42 downloads if not vendored).
    tmpc=""
    if [ -d "$root/vendor/winetricks-cache" ]; then
        tmpc="$(mktemp -d)"
        ln -s "$root/vendor/winetricks-cache" "$tmpc/winetricks"
        export XDG_CACHE_HOME="$tmpc"
        echo "   using bundled winetricks cache ($root/vendor/winetricks-cache)"
    fi
    WINE="$WINE_ROOT/bin/wine" bash "$root/vendor/winetricks" -q -f corefonts vcrun2022 mfc42
    [ -n "$tmpc" ] && rm -rf "$tmpc"
    "$WINESERVER" -w
fi

# wineboot -u replaces redist natives (msvcp140 etc.) with wine's higher-versioned stubs, which
# Live aborts on. Re-copy every builtin-identical or missing redist DLL, then gate: none may remain.
echo "== [2b/5] force native VC++ runtime over wine's builtin stubs =="
redist_dir=""
for d in "$root/vendor/winetricks-cache/vcrun2022" \
         "${XDG_CACHE_HOME:-$HOME/.cache}/winetricks/vcrun2022"; do
    [ -s "$d/vc_redist.x64.exe" ] && { redist_dir="$d"; break; }
done
[ -n "$redist_dir" ] || { echo "!! vc_redist.x64.exe not found (vendor or winetricks cache) — cannot assert a native VC runtime" >&2; exit 1; }
vc_tmp="$(mktemp -d)"
for arch in x64 x86; do
    cabextract -q -d "$vc_tmp/$arch/burst" "$redist_dir/vc_redist.$arch.exe"
    for cab in "$vc_tmp/$arch/burst"/a*; do
        cabextract -q -d "$vc_tmp/$arch" "$cab" 2>/dev/null || true
    done
done
vc_bad=0
for f in "$vc_tmp"/*/*.dll_amd64 "$vc_tmp"/*/*.dll_x86; do
    [ -e "$f" ] || continue
    case "$f" in
        *_amd64) name="$(basename "$f" _amd64)"; wdir=system32; barch=x86_64-windows ;;
        *)       name="$(basename "$f" _x86)";   wdir=syswow64; barch=i386-windows ;;
    esac
    dest="$WINEPREFIX/drive_c/windows/$wdir/$name"
    builtin="$WINE_ROOT/lib/wine/$barch/$name"
    if [ ! -s "$dest" ] || { [ -s "$builtin" ] && cmp -s "$dest" "$builtin"; }; then
        echo "   restoring native $wdir/$name (was wine builtin or missing)"
        install -m 644 "$f" "$dest"
    fi
    # gate: a file still identical to wine's builtin means the heal failed
    if [ -s "$builtin" ] && cmp -s "$dest" "$builtin"; then
        echo "!! $wdir/$name is still wine's builtin stub" >&2; vc_bad=1
    fi
done
rm -rf "$vc_tmp"
[ "$vc_bad" -eq 0 ] || { echo "!! native VC++ runtime gate FAILED" >&2; exit 1; }

echo "== [3/5] DPI policy ($dpi_mode -> $dpi_block) =="
case "$dpi_block" in
  100)
    wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 96 /f
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        wine reg delete "$ifeo_root\\$name" /v dpiAwareness /f >/dev/null 2>&1 || true  # reg.exe errors land on stdout
    done < <(live_exe_names)
    check_mutter_knob 100
    ;;
  fractional)
    wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 192 /f
    ifeo_set=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        ifeo_set=1
        wine reg add "$ifeo_root\\$name" /v dpiAwareness /t REG_DWORD /d 2 /f
    done < <(live_exe_names)
    [ "$ifeo_set" -eq 1 ] || echo "   (Live not installed yet — the launcher sets its per-app DPI flag on first start)"
    check_mutter_knob fractional
    ;;
  preserve)
    echo "   preserving current LogPixels and dpiAwareness values"
    # Still sanity-check the mutter knob against what the prefix holds.
    have="$(current_dpi_block)"
    if [ "$have" != custom ]; then
        check_mutter_knob "$have"
    fi
    ;;
esac
"$WINESERVER" -w

echo "== [3b/5] theme: mirror the host light/dark scheme =="
# Live's "Follow system" theme reads AppsUseLightTheme; without the key it always renders
# light. Seed it from the host scheme (the launcher re-syncs on every start), plus the
# EnableTransparency=0 the known-good prefixes carry.
if host_scheme="$(ableton_detect_theme)"; then
    case "$host_scheme" in dark) light_val=0 ;; *) light_val=1 ;; esac
    echo "   host scheme: $host_scheme"
    wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d "$light_val" /f
else
    echo "   host scheme not detectable — leaving the theme key as-is (the launcher retries on every start)"
fi
wine reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v EnableTransparency /t REG_DWORD /d 0 /f
"$WINESERVER" -w

echo "== [3c/5] OpenGL backend policy =="
opengl_mode="${ABLETON_OPENGL_BACKEND:-auto}"
if ! opengl_backend="$(ableton_resolve_opengl_backend "$opengl_mode")"; then
    echo "!! ABLETON_OPENGL_BACKEND must be auto, preserve, egl, or glx" >&2
    exit 2
fi
case "$opengl_backend" in
  glx)
    if [ "$opengl_mode" = glx ]; then
      echo "   selecting Wine's GLX backend (explicit override)"
    else
      echo "   active NVIDIA display detected — selecting Wine's GLX backend"
    fi
    wine reg add 'HKCU\Software\Wine\X11 Driver' /v UseEGL /t REG_SZ /d N /f
    ;;
  egl)
    echo "   selecting Wine's EGL backend (explicit override)"
    wine reg add 'HKCU\Software\Wine\X11 Driver' /v UseEGL /t REG_SZ /d Y /f
    ;;
  preserve)
    echo "   preserving Wine's current OpenGL backend"
    ;;
esac
"$WINESERVER" -w

echo "== [4/5] register packaged PipeASIO =="
ldconfig -p 2>/dev/null | grep -F 'libpipewire-0.3.so.0' >/dev/null || \
  echo "!! host libpipewire-0.3.so.0 not found; install pipewire (0.3.56 or newer, 1.6+ recommended)"
# Pre-2026-07 runtimes shipped WineASIO; drop its registration and the stale
# system32 placeholders so nothing references the removed driver. Harmless on
# fresh prefixes.
wine reg delete 'HKLM\Software\ASIO\WineASIO' /f >/dev/null 2>&1 || true
wine reg delete 'HKCR\CLSID\{48D0C522-BFCC-45CC-8B84-17F25F33E6E8}' /f >/dev/null 2>&1 || true
rm -f "$WINEPREFIX"/drive_c/windows/system32/wineasio64.dll \
      "$WINEPREFIX"/drive_c/windows/system32/wineasio.dll
wine regsvr32 pipeasio64.dll
"$WINESERVER" -w

# Seed the driver defaults once; the file is the config surface (PIPEASIO_*
# environment variables override it per launch, see the README).
pipeasio_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
if [ ! -s "$pipeasio_cfg" ]; then
    mkdir -p "$(dirname "$pipeasio_cfg")"
    cat > "$pipeasio_cfg" <<'EOF'
[pipeasio]
inputs = 2
outputs = 2
buffer_size = 256
fixed_buffer_size = true
auto_connect = true
EOF
    echo "   seeded $pipeasio_cfg (2 in / 2 out, fixed 256-frame buffer)"
fi

echo "== [5/5] set portal policy and scope Push 2 bridge to its helper =="
# Default only — a policy the user set with set-file-portal-policy survives re-runs.
if ! wine reg query 'HKCU\Software\Wine\X11 Driver' /v FileDialogPortal >/dev/null 2>&1; then
  wine reg add 'HKCU\Software\Wine\X11 Driver' \
    /v FileDialogPortal /t REG_SZ /d auto /f
fi
push2_key='HKCU\Software\Wine\AppDefaults\Push2DisplayProcess.exe\DllOverrides'
wine reg add "$push2_key" /v libusb-1.0 /t REG_SZ /d builtin /f
wine reg query "$push2_key" /v libusb-1.0

# Ableton's tlsetupfx.exe (kernel USB driver installer) faults under Wine and pops a winedbg
# dialog mid-install; this runtime has no IFEO Debugger hook to neuter it, so nothing is set here.

# winemenubuilder's entries assume `wine` on PATH (never true here) and are dead buttons: disable
# it and delete entries it already wrote for this prefix (matched by WINEPREFIX=; install.sh's entries can't match).
wine reg add 'HKCU\Software\Wine\DllOverrides' /v winemenubuilder.exe /t REG_SZ /d '' /f
for entry_dir in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" "$HOME/Desktop"; do
    [ -d "$entry_dir" ] || continue
    find "$entry_dir" -maxdepth 3 -name '*.desktop' -type f 2>/dev/null | while IFS= read -r f; do
        if grep -qF "WINEPREFIX=\"$WINEPREFIX\"" "$f" 2>/dev/null; then
            echo "   removing dead winemenubuilder entry: $f"
            rm -f "$f"
        fi
    done
done
update-desktop-database "${XDG_DATA_HOME:-$HOME/.local/share}/applications" 2>/dev/null || true
"$WINESERVER" -w

echo
echo "OK: prefix ready at $WINEPREFIX"
cat <<EOF

────────────────────────────────────────────────────────────────────────
Remaining steps (you supply Ableton + your own license):

  1. Install Live (any edition) through THIS wine (plain wine reads
     WINEPREFIX, not the ABLETON_* launcher variables):
       WINEPREFIX=$WINEPREFIX \\
       $WINE_ROOT/bin/wine "/path/to/Ableton Live NN Edition Installer.exe"

  2. Launch:            ableton-live
  3. Authorize Live with your own account (binds to this prefix's MachineGuid).
  4. In Live: Options > uncheck "Auto-Scale Plugin Window"
     (prevents a plugin-window resize loop with DPI-unaware plugin UIs).
  5. Audio: Preferences > Audio > Driver Type: ASIO > Device: PipeASIO.
     PipeASIO is a native PipeWire client — no JACK layer involved.
────────────────────────────────────────────────────────────────────────
EOF
