#!/usr/bin/env bash
# End-user step 2: create or refresh the Ableton Wine prefix. Idempotent.
# Does not install Ableton Live itself and carries no license.
# --refresh: maintenance pass on an EXISTING prefix (used by the .run's update
# mode) — re-applies registry policy and heals runtime DLLs, but skips the slow
# winetricks pass; the fonts/runtimes it installs are already in the prefix.
# --post-first-run: standalone fixup to run after Live's first launch — moves
# Max for Live 8's preferences aside (never deletes) so its second start stops
# crashing. Needs no wine and skips every other step.
# ABLETON_LIVE_VERSION=11|12 selects the winetricks recipe (default 12).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# The kit root holds vendor/. Layouts that must work:
#   <kit>/scripts/setup-prefix.sh        -> vendor at $here/../vendor (repo, extracted .run kit)
#   <dir>/setup-prefix.sh + <dir>/vendor -> vendor at $here/vendor
# Resolved lazily so --refresh (which skips the winetricks pass) never trips this;
# install.sh deliberately does not install vendor/ into ~/.local/share/ableton-wine.
root=""
kit_root() {
    [ -n "$root" ] && return 0
    local cand
    for cand in "$here/.." "$here"; do
        if [ -f "$cand/vendor/winetricks" ]; then
            root="$(cd "$cand" && pwd)"
            return 0
        fi
    done
    return 1
}
kit_root_or_die() {
    kit_root && return 0
    echo "!! cannot locate vendor/winetricks (looked in $here/.. and $here)" >&2
    echo "!! prefix maintenance must run from the installer kit — either:" >&2
    echo "!!     sh install-ableton-latest.run --update" >&2
    echo "!!   or extract the kit and run it from there:" >&2
    echo "!!     sh install-ableton-latest.run --extract /tmp/ableton-kit" >&2
    echo "!!     bash /tmp/ableton-kit/scripts/setup-prefix.sh" >&2
    exit 1
}

refresh=0
post_first_run=0
case "${1:-}" in
    --refresh) refresh=1 ;;
    --post-first-run) post_first_run=1 ;;
    "") ;;
    *) echo "!! unknown option: $1 (supported: --refresh, --post-first-run)" >&2; exit 2 ;;
esac

case "${ABLETON_LIVE_VERSION:-12}" in
    11|12) ;;
    *) echo "!! ABLETON_LIVE_VERSION must be 11 or 12 (got '$ABLETON_LIVE_VERSION')" >&2; exit 2 ;;
esac

unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH WINEESYNC WINEFSYNC
WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.11}"
export WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
export PATH="$WINE_ROOT/bin:$PATH"
export WINEDEBUG=-all
export WINESERVER="$WINE_ROOT/bin/wineserver"

# --post-first-run: Max for Live 8 (ships with Live 11) crashes on its SECOND start
# with a stale preferences file. Move it aside — never delete — so Max regenerates
# it; idempotent, and a missing file only means Max has not run yet. Needs no wine,
# so it runs before the runtime checks above matter.
if [ "$post_first_run" -eq 1 ]; then
    [ -f "$WINEPREFIX/system.reg" ] || { echo "!! no prefix at $WINEPREFIX — nothing to run --post-first-run against" >&2; exit 2; }
    moved=0
    for maxpref in "$WINEPREFIX"/drive_c/users/*/"AppData/Roaming/Cycling '74/Max 8/Settings/maxpreferences.maxpref"; do
        [ -f "$maxpref" ] || continue
        bak="$maxpref.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        [ -e "$bak" ] && bak="$bak.$$"      # same-second re-run: keep both backups
        mv -v "$maxpref" "$bak"
        moved=1
    done
    if [ "$moved" -eq 1 ]; then
        echo "OK: Max preferences moved aside — Max regenerates them on next start"
    else
        echo "OK: no maxpreferences.maxpref under $WINEPREFIX — nothing to do (Max not run yet?)"
    fi
    exit 0
fi

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

# DPI blocks: a detected scale maps to a calibrated set by compositor family (see
# detect-scale.sh): GNOME gets the upscaled-framebuffer matched set (LogPixels =
# 96 x ceil(scale) + IFEO dpiAwareness=2), other compositors get plain
# LogPixels = round(96 x scale) with no IFEO. auto applies the detected block on a
# fresh prefix, preserves an existing one, refuses scales outside 100-250%.
# The dpiAwareness IFEO is keyed on the exe name, so it is applied per installed Live (any edition);
# on a fresh prefix Live isn't installed yet — the launcher applies it on every start.
ifeo_root='HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
live_exe_names() {   # basenames of every Live exe installed in this prefix
    ls "$WINEPREFIX"/drive_c/ProgramData/Ableton/*/Program/"Ableton Live"*.exe 2>/dev/null \
        | while IFS= read -r f; do basename "$f"; done
}

# Shared display-scale detection and scale -> DPI block mapping (see detect-scale.sh).
. "$here/detect-scale.sh"

# Shared host light/dark-scheme detection (see detect-theme.sh).
. "$here/detect-theme.sh"

block_for_scale() {  # scale family -> calibrated block token, fails outside 100-250%
    ableton_dpi_block_for_scale "$1" "${2:-}"
}

current_dpi_block() {  # what an EXISTING prefix holds: 100 | fractional | dpi<N> | fractional<N> | custom
    local lp n ifeo=absent name installs=0
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
    n=$((lp)) 2>/dev/null || n=0
    if [ "$ifeo" = present ]; then
        # an IFEO set is only calibrated as half of the matched set (96 x k framebuffer)
        if [ $((n % 96)) -eq 0 ] && [ "$n" -ge 192 ]; then
            if [ "$n" -eq 192 ]; then echo fractional; else echo "fractional$n"; fi
        else
            echo custom
        fi
    elif [ "$n" -eq 96 ]; then
        echo 100
    elif [ "$n" -eq 192 ] && [ "$installs" -eq 0 ]; then
        echo fractional    # no Live installed yet: LogPixels alone decides; the launcher adds the IFEO
    elif [ "$n" -gt 96 ] && [ "$n" -le 240 ]; then
        echo "dpi$n"
    else
        echo custom
    fi
}

check_mutter_knob() {  # warn when mutter's xwayland-native-scaling disagrees with the block
    local feats
    # The knob only exists under mutter; off-GNOME (a known non-gnome family) it is irrelevant.
    [ -z "${2:-}" ] || [ "$2" = gnome ] || return 0
    command -v gsettings >/dev/null 2>&1 || return 0
    feats="$(gsettings get org.gnome.mutter experimental-features 2>/dev/null)" || return 0
    case "$1" in
        fractional*)   # upscaled-framebuffer sets need the knob
            if ! printf '%s' "$feats" | grep -q xwayland-native-scaling; then
                echo "!! mutter experimental-features lacks xwayland-native-scaling —"
                echo "!! the '$1' DPI block expects it present; add it to"
                echo "!!   org.gnome.mutter experimental-features (gsettings)"
            fi ;;
        *)
            if printf '%s' "$feats" | grep -q xwayland-native-scaling; then
                echo "!! mutter experimental-features lists xwayland-native-scaling —"
                echo "!! the '$1' DPI block expects it absent; remove it from"
                echo "!!   org.gnome.mutter experimental-features (gsettings)"
            fi ;;
    esac
    return 0
}

# 2026.07.18.1 seeded -DontCombineAPCs into Options.txt to cut a 30-40% idle CPU
# thread. Under playback the uncoalesced APCs flood the wineserver and starve the
# PipeASIO callback: choppy, slowed-down audio (issue #29). Strip the line from
# every prefs copy — including hand-added ones, since the old changelog entry
# advertised it. The idle CPU cost is back until the Wine-side fix lands; see
# notes/ABLETON-WINE-APC-COALESCING.md.
strip_options_txt() {
    local line="-DontCombineAPCs" prefs f tmp
    shopt -s nullglob
    for prefs in "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/Ableton/Live*/Preferences; do
        f="$prefs/Options.txt"
        [ -f "$f" ] || continue
        # Match with CR stripped so a CRLF-edited copy is caught too.
        tr -d '\r' < "$f" | grep -qxF -- "$line" || continue
        tmp="$(mktemp)"
        awk -v opt="$line" '{ l = $0; sub(/\r$/, "", l) } l != opt { print }' "$f" > "$tmp"
        if [ -s "$tmp" ]; then
            # Write through the existing inode: keeps the file's permissions.
            cat "$tmp" > "$f"
            rm -f "$tmp"
            echo "   removed $line from $f"
        else
            # The seed's touch created the file; nothing else in it — undo fully.
            rm -f "$tmp" "$f"
            echo "   removed $f (held only $line)"
        fi
    done
    shopt -u nullglob
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
dpi_family=""
case "$dpi_mode" in
  100|fractional)
    dpi_block="$dpi_mode"
    ;;
  dpi[0-9]*|fractional[0-9]*)
    if ableton_dpi_block_values "$dpi_mode" >/dev/null; then
        dpi_block="$dpi_mode"
    else
        echo "!! ABLETON_DPI_MODE '$dpi_mode' is not a usable DPI block (want dpi<N> / fractional<N> with LogPixels N in 72..384)" >&2
        exit 2
    fi
    ;;
  preserve)
    ;;
  auto)
    if detected="$(ableton_detect_scale_ex)"; then
        scale="${detected% *}"
        dpi_family="${detected#* }"
        if block="$(block_for_scale "$scale" "$dpi_family")"; then
            if [ "$fresh_prefix" -eq 1 ]; then
                echo "   display scale $scale ($dpi_family) detected -> will apply the '$block' DPI block"
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
            echo "!! display scale $scale is outside the calibrated 100-250% range" >&2
            echo "!! rerun with an explicit ABLETON_DPI_MODE=100 or =dpi<N> (LogPixels N in 72..384)" >&2
            exit 2
        else
            echo "!! display scale $scale is outside the calibrated 100-250% range — preserving existing prefix values"
        fi
    elif [ "$fresh_prefix" -eq 1 ]; then
        echo "!! cannot detect the display scale (non-GNOME desktop or headless session?)" >&2
        echo "!! a fresh prefix needs an explicit ABLETON_DPI_MODE=100 or =dpi<N>" >&2
        exit 2
    else
        echo "   cannot detect display scale; preserving existing prefix values"
    fi
    ;;
  *)
    echo "!! ABLETON_DPI_MODE must be auto, preserve, 100, fractional, or dpi<N>" >&2
    exit 2
    ;;
esac

echo "== [1/5] initialize prefix at $WINEPREFIX =="
wineboot -u
"$WINESERVER" -w

if [ "$refresh" -eq 1 ]; then
    echo "== [2/5] winetricks: skipped (--refresh keeps the installed fonts/runtimes) =="
else
    # Verb set per Live major: Live 12 needs vcrun2022 + mfc42; Live 11 needs
    # vcrun2019 + gdiplus (the Ableton forum Live-on-Linux guide). vcrun2019/gdiplus
    # payloads are not vendored yet — Live 11 setup downloads them on first run.
    live_major="${ABLETON_LIVE_VERSION:-12}"
    case "$live_major" in
        11) verbs="corefonts vcrun2019 gdiplus" ;;
        12) verbs="corefonts vcrun2022 mfc42" ;;
        *)  echo "!! ABLETON_LIVE_VERSION must be 11 or 12 (got '$live_major')" >&2; exit 2 ;;
    esac
    echo "== [2/5] winetricks (Live $live_major): $verbs =="
    kit_root_or_die
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
    WINE="$WINE_ROOT/bin/wine" bash "$root/vendor/winetricks" -q -f $verbs
    if [ "$live_major" = 11 ]; then
        # Live 11 targets Windows 10 explicitly. Live 12 stays unpinned: nothing in
        # this script ever sets a Windows version, and a fresh wineboot prefix
        # already defaults to win10 (winetricks assumes the same), so the Live 12
        # recipe keeps its historical effective mode.
        WINE="$WINE_ROOT/bin/wine" bash "$root/vendor/winetricks" -q win10
    fi
    [ -n "$tmpc" ] && rm -rf "$tmpc"
    "$WINESERVER" -w
fi

# Live bundles the exact VC++ redistributable it was built against in its own
# Redist folder (<Live folder>/Redist, next to Program/) — present only after
# Live's installer has run, so fresh prefixes never match here.
find_live_redist() {  # -> path of the VC++ redist installer bundled with an installed Live
    local d name
    for d in "$WINEPREFIX"/drive_c/ProgramData/Ableton/*/Redist; do
        [ -d "$d" ] || continue
        for name in vc_redist.exe VC_redist.x64.exe vc_redist.x64.exe vcredist.exe vcredist_x64.exe; do
            if [ -s "$d/$name" ] && [ ! -L "$d/$name" ]; then
                printf '%s\n' "$d/$name"
                return 0
            fi
        done
    done
    return 1
}

# Cheap probe for a working runtime: the four DLLs Live links against are present
# in system32 and none is one of wine's placeholder stubs (they carry the marker
# string). Needs no payload, unlike the byte-comparison gate below.
vc_runtime_ready() {
    local dll path
    for dll in vcruntime140.dll vcruntime140_1.dll msvcp140.dll msvcp140_1.dll; do
        path="$WINEPREFIX/drive_c/windows/system32/$dll"
        [ -s "$path" ] || return 1
        grep -aFq 'Wine placeholder DLL' "$path" && return 1
    done
    return 0
}

# vc_redist reports success as exit 0, 102 or 194 (reboot-required states are
# notional under Wine); the DLL probe above is the real verdict.
install_live_redist() {
    local status=0
    wine "$1" /install /quiet /norestart || status=$?
    "$WINESERVER" -w
    case "$status" in
        0|102|194) ;;
        *) echo "!! Live's bundled VC++ redist failed (exit $status)" >&2; return 1 ;;
    esac
    vc_runtime_ready || { echo "!! bundled redist ran, but system32 still holds placeholder/missing runtime DLLs" >&2; return 1; }
}

# wineboot -u replaces redist natives (msvcp140 etc.) with wine's higher-versioned stubs, which
# Live aborts on. Prefer the redist bundled in Live's own Redist folder; the vendored payload
# stays as the fallback and as the final gate (it also covers syswow64, which vc_redist.x64
# doesn't touch). The redist comes from the same source winetricks used: vcrun2022 (Live 12)
# or vcrun2019 (Live 11) — both ship the vc_redist.x64/x86.exe pair with the same cab layout.
redist_verb=vcrun2022
[ "${ABLETON_LIVE_VERSION:-12}" = 11 ] && redist_verb=vcrun2019
echo "== [2b/5] force native VC++ runtime over wine's builtin stubs ($redist_verb) =="
kit_root || true   # vendored cache is only a candidate; absence is not fatal here
if ! vc_runtime_ready; then
    live_redist="$(find_live_redist || true)"
    if [ -n "$live_redist" ]; then
        echo "   installing VC++ redist from Live's own Redist: ${live_redist#"$WINEPREFIX"/}"
        install_live_redist "$live_redist" || \
            echo "!! falling back to the vendored vc_redist payload" >&2
    fi
fi
redist_dir=""
for d in "$root/vendor/winetricks-cache/$redist_verb" \
         "${XDG_CACHE_HOME:-$HOME/.cache}/winetricks/$redist_verb"; do
    [ -s "$d/vc_redist.x64.exe" ] && { redist_dir="$d"; break; }
done
if [ -z "$redist_dir" ]; then
    if vc_runtime_ready; then
        echo "   no vendored vc_redist.x64.exe — relying on the runtime verified above"
    else
        echo "!! vc_redist.x64.exe not found (vendor or winetricks cache) — cannot assert a native VC runtime" >&2; exit 1
    fi
else
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
fi

echo "== [3/5] DPI policy ($dpi_mode -> $dpi_block) =="
case "$dpi_block" in
  preserve)
    echo "   preserving current LogPixels and dpiAwareness values"
    # Still sanity-check the mutter knob against what the prefix holds.
    have="$(current_dpi_block)"
    if [ "$have" != custom ]; then
        check_mutter_knob "$have"
    fi
    ;;
  *)
    lp_ifeo="$(ableton_dpi_block_values "$dpi_block")"
    dpi_lp="${lp_ifeo% *}"
    dpi_ifeo="${lp_ifeo#* }"
    wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi_lp" /f
    ifeo_set=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        ifeo_set=1
        if [ "$dpi_ifeo" = 2 ]; then
            wine reg add "$ifeo_root\\$name" /v dpiAwareness /t REG_DWORD /d 2 /f
        else
            wine reg delete "$ifeo_root\\$name" /v dpiAwareness /f >/dev/null 2>&1 || true  # reg.exe errors land on stdout
        fi
    done < <(live_exe_names)
    if [ "$ifeo_set" -eq 0 ] && [ "$dpi_ifeo" = 2 ]; then
        echo "   (Live not installed yet — the launcher sets its per-app DPI flag on first start)"
    fi
    check_mutter_knob "$dpi_block" "$dpi_family"
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

echo "== [5b/5] remove the 2026.07.18.1 Options.txt seed (issue #29) =="
strip_options_txt

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
