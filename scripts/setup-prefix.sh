#!/usr/bin/env bash
# End-user step 2: create or refresh the Ableton Wine prefix. Idempotent.
# Ships no Ableton Live payload and no license; step [6/6] can run the user's
# own ableton_live*.zip download (~/Proprietary by default) — strictly opt-in
# via ABLETON_LIVE_AUTOINSTALL=1, otherwise the manual steps are printed.
# --refresh: maintenance pass on an EXISTING prefix (used by the .run's update
# mode) — re-applies registry policy and heals runtime DLLs, but skips the slow
# winetricks pass; the fonts/runtimes it installs are already in the prefix.
# --post-first-run: standalone fixup to run after Live's first launch — moves
# Max for Live 8's preferences aside (never deletes) so its second start stops
# crashing. Needs no wine and skips every other step.
# ABLETON_LIVE_VERSION=11|12 pins the winetricks recipe; unpinned, an opted-in
# auto-install derives it from the chosen zip's filename (default 12).
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
# Mesa prints "radv is not a conformant Vulkan implementation" once per wine
# process spawn; winetricks spawns dozens — pure noise that drowns progress.
export MESA_VK_IGNORE_CONFORMANCE_WARNING=1

# "$WINESERVER" -w with narration: name the processes still holding the
# session open instead of blocking silently — a stray autostart like
# MicrosoftEdgeUpdate.exe can pin the session for minutes.
settle_procs() {   # basenames of windows processes still running under this runtime
    local p cmd out=""
    for p in $(pgrep -f '\.exe' 2>/dev/null || true); do
        case "$(readlink "/proc/$p/exe" 2>/dev/null)" in
            "$WINE_ROOT"/*) ;;
            *) continue ;;
        esac
        cmd=""
        IFS= read -rd "" cmd <"/proc/$p/cmdline" 2>/dev/null || true
        cmd="${cmd##*[\\/]}"
        [ -n "$cmd" ] && out="$out $cmd"
    done
    printf '%s\n' "${out# }"
}
settle() {
    "$WINESERVER" -w &
    local w=$! t=0 now last="(unset)"   # sentinel: the first tick past 15s always narrates
    while kill -0 "$w" 2>/dev/null; do
        sleep 5
        t=$((t + 5))
        [ "$t" -lt 15 ] && continue   # fast settles stay quiet
        now="$(settle_procs)"
        if [ "$now" != "$last" ] || [ $((t % 30)) -eq 0 ]; then
            echo "   ...waiting for the prefix session to settle (${t}s): ${now:-device/driver hosts}"
            last="$now"
        fi
    done
    wait "$w" 2>/dev/null || true
}

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

# Ableton Live auto-install candidate (run by step [6/6]) and the Live major
# the winetricks/redist recipes target — resolved together, up front, so an
# opted-in auto-install can never put a Live 11 zip into a prefix prepared
# with the Live 12 recipe. Major precedence: ABLETON_LIVE_VERSION pin >
# the major parsed from the chosen zip > 12.
live_installed() { ls "$WINEPREFIX"/drive_c/ProgramData/Ableton/*/Program/"Ableton Live"*.exe >/dev/null 2>&1; }
installer_dir="${ABLETON_INSTALLER_DIR:-$HOME/Proprietary}"
live_zip=""
if [ -d "$installer_dir" ]; then
    if [ -n "${ABLETON_LIVE_VERSION:-}" ]; then
        # An explicit major pin only accepts a matching installer — never
        # silently install another major into a prefix prepared for this one.
        live_zip="$(find "$installer_dir" -maxdepth 1 -iname "ableton_live*_${ABLETON_LIVE_VERSION}.*.zip" | sort -V | tail -n 1)"
    else
        # Newest by version-sort when several editions/versions are present.
        live_zip="$(find "$installer_dir" -maxdepth 1 -iname 'ableton_live*.zip' | sort -V | tail -n 1)"
    fi
fi
live_major="${ABLETON_LIVE_VERSION:-12}"
if [ -z "${ABLETON_LIVE_VERSION:-}" ] && [ "${ABLETON_LIVE_AUTOINSTALL:-0}" = 1 ] \
    && [ -n "$live_zip" ] && ! live_installed; then
    # ableton_live_<edition>_<major>.<minor>.<patch>_64.zip; sed -n exits 0
    # whether or not it matches, so set -e/pipefail stay happy.
    zip_major="$(basename "$live_zip" | sed -nE 's/^[^0-9]*_([0-9]+)\.[0-9]+.*$/\1/p')"
    case "$zip_major" in
        11|12)
            live_major="$zip_major"
            if [ "$live_major" != 12 ]; then
                echo ":: $(basename "$live_zip") is Live $live_major — using the Live $live_major recipe (ABLETON_LIVE_VERSION overrides)"
            fi
            ;;
        "")
            echo ":: cannot read a Live version from $(basename "$live_zip") — using the Live 12 recipe (set ABLETON_LIVE_VERSION if that is wrong)"
            ;;
        *)
            echo "!! $(basename "$live_zip") looks like Live $zip_major — no recipe for that major (11|12); set ABLETON_LIVE_VERSION or remove the zip" >&2
            exit 2
            ;;
    esac
fi

echo "== [1/6] initialize prefix at $WINEPREFIX =="
# Live's Learn View brings in WebView2; its MicrosoftEdgeUpdate.exe autostart
# is useless under Wine and holds the boot session open for minutes (the
# settle below waits on it). Disable it up front, like winemenubuilder (step 5).
# On a fresh prefix this reg add also performs the initial prefix creation.
# Headless (no DISPLAY/WAYLAND): prefix creation needs no display and the
# wineboot update banner is the only UI it produces — the nix build gate
# creates prefixes with no display at all, so this is a proven-safe path.
DISPLAY='' WAYLAND_DISPLAY='' wine reg add 'HKCU\Software\Wine\DllOverrides' /v MicrosoftEdgeUpdate.exe /t REG_SZ /d '' /f >/dev/null
DISPLAY='' WAYLAND_DISPLAY='' wineboot -u
settle

if [ "$refresh" -eq 1 ]; then
    echo "== [2/6] winetricks: skipped (--refresh keeps the installed fonts/runtimes) =="
else
    # Verb set per Live major: Live 12 needs vcrun2022 + mfc42; Live 11 needs
    # vcrun2019 + gdiplus (the Ableton forum Live-on-Linux guide). vcrun2019/gdiplus
    # payloads are not vendored yet — Live 11 setup downloads them on first run.
    case "$live_major" in
        11) verbs="corefonts vcrun2019 gdiplus" ;;
        12) verbs="corefonts vcrun2022 mfc42" ;;
        *)  echo "!! internal: live_major '$live_major' has no winetricks recipe" >&2; exit 2 ;;
    esac
    echo "== [2/6] winetricks (Live $live_major): $verbs =="
    kit_root_or_die
    export W_CACHE_OVERRIDE=""            # unused
    export WINETRICKS_LATEST_VERSION_CHECK=disabled
    # Use the bundled payload cache if present (mfc42 downloads if not vendored).
    tmpc=""
    if [ -d "$root/vendor/winetricks-cache" ]; then
        tmpc="$(mktemp -d)"
        ln -s "$root/vendor/winetricks-cache" "$tmpc/winetricks"
        export XDG_CACHE_HOME="$tmpc"
        echo "   using bundled winetricks cache ($root/vendor/winetricks-cache)"
    fi
    # WINE64 preset: this is a new-style WoW64 tree (single wine binary, no
    # wine64). winetricks' arch autodetection reads the ELF header of $WINE,
    # which fails when bin/wine is a wrapper script (nix) — preset both.
    WINE="$WINE_ROOT/bin/wine" WINE64="$WINE_ROOT/bin/wine" \
        bash "$root/vendor/winetricks" -q -f $verbs
    if [ "$live_major" = 11 ]; then
        # Live 11 targets Windows 10 explicitly. Live 12 stays unpinned: nothing in
        # this script ever sets a Windows version, and a fresh wineboot prefix
        # already defaults to win10 (winetricks assumes the same), so the Live 12
        # recipe keeps its historical effective mode.
        WINE="$WINE_ROOT/bin/wine" WINE64="$WINE_ROOT/bin/wine" \
            bash "$root/vendor/winetricks" -q win10
    fi
    [ -n "$tmpc" ] && rm -rf "$tmpc"
    settle
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
    settle
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
[ "$live_major" = 11 ] && redist_verb=vcrun2019
echo "== [2b/6] force native VC++ runtime over wine's builtin stubs ($redist_verb) =="
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

echo "== [3/6] DPI policy ($dpi_mode -> $dpi_block) =="
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
settle

echo "== [3b/6] theme: mirror the host light/dark scheme =="
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
settle

echo "== [4/6] register packaged PipeASIO =="
# The driver's unix half must resolve libpipewire-0.3.so.0 — the tarball build
# from the host's libs (it carries no rpath on purpose), the nix build from its
# nixpkgs RUNPATH. ldd follows both; ldconfig -p sees neither on NixOS.
if ldd "$WINE_ROOT/lib/wine/x86_64-unix/pipeasio64.dll.so" 2>/dev/null \
    | grep -F 'libpipewire-0.3.so.0' | grep -q 'not found'; then
    echo "!! the PipeASIO driver cannot resolve libpipewire-0.3.so.0; install pipewire (0.3.56 or newer, 1.6+ recommended)"
fi
[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0" ] || \
    echo "!! no PipeWire socket at ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0 — Live will list no PipeASIO device until the PipeWire daemon runs"
# Pre-2026-07 runtimes shipped WineASIO; drop its registration and the stale
# system32 placeholders so nothing references the removed driver. Harmless on
# fresh prefixes.
wine reg delete 'HKLM\Software\ASIO\WineASIO' /f >/dev/null 2>&1 || true
wine reg delete 'HKCR\CLSID\{48D0C522-BFCC-45CC-8B84-17F25F33E6E8}' /f >/dev/null 2>&1 || true
rm -f "$WINEPREFIX"/drive_c/windows/system32/wineasio64.dll \
      "$WINEPREFIX"/drive_c/windows/system32/wineasio.dll
# Direct apploader call (not "wine regsvr32"): skips start.exe /exec + conhost,
# whose exit path stalled a live session for minutes once (2026-07-17); the nix
# build gate exercises this exact invocation. /s: without it regsvr32 reports
# success as a MessageBox (Windows semantics) and blocks until it's clicked.
regsvr32 /s pipeasio64.dll
settle

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

echo "== [5/6] set portal policy and scope Push 2 bridge to its helper =="
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
settle

echo "== [5b/6] remove the 2026.07.18.1 Options.txt seed (issue #29) =="
strip_options_txt

echo "== [6/6] Ableton Live =="
# Runs the USER'S OWN Ableton download — this repo ships no Live payload and
# no license. OPT-IN ONLY (ABLETON_LIVE_AUTOINSTALL=1): the automatic run is
# silent, which defers Ableton's EULA to first launch, and a prefix refresh
# must never execute an installer the user didn't explicitly ask it to.
# Search dir: ~/Proprietary (the official ableton_live*.zip from ableton.com);
# ABLETON_INSTALLER_DIR overrides. The zip candidate — and the recipe major it
# implies — was resolved up front, before step [2/6]. The .run pins
# ABLETON_LIVE_AUTOINSTALL=0: it drives the Ableton installer itself.
live_ready=0
if live_installed; then
    live_ready=1
    echo "   Live is already installed in this prefix — not touching it"
elif [ "${ABLETON_LIVE_AUTOINSTALL:-}" = 0 ]; then
    echo "   skipped (ABLETON_LIVE_AUTOINSTALL=0)"
elif [ "${ABLETON_LIVE_AUTOINSTALL:-0}" != 1 ]; then
    if [ -n "$live_zip" ]; then
        echo "   found $(basename "$live_zip") — rerun with ABLETON_LIVE_AUTOINSTALL=1 to install it"
        echo "   (silent install: Ableton's EULA is then shown on Live's first launch, not before)"
    else
        echo "   skipped — ABLETON_LIVE_AUTOINSTALL=1 (opt-in) installs your ableton_live*.zip from $installer_dir"
    fi
else
    if [ -z "$live_zip" ]; then
        if [ -n "${ABLETON_LIVE_VERSION:-}" ]; then
            echo "   no Live $ABLETON_LIVE_VERSION installer (ableton_live*_${ABLETON_LIVE_VERSION}.*.zip) in $installer_dir — manual install steps are printed below"
        else
            echo "   no ableton_live*.zip in $installer_dir — manual install steps are printed below"
        fi
        echo "   (drop the official ableton.com zip there, or point ABLETON_INSTALLER_DIR at it)"
    else
        echo "   unpacking $(basename "$live_zip")"
        unpack_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ableton-wine-setup/live-installer"
        rm -rf "$unpack_dir"
        mkdir -p "$unpack_dir"
        unpack_ok=1
        if command -v unzip >/dev/null; then
            unzip -q "$live_zip" -d "$unpack_dir" || unpack_ok=0
        elif command -v bsdtar >/dev/null; then
            bsdtar -xf "$live_zip" -C "$unpack_dir" || unpack_ok=0
        elif command -v python3 >/dev/null; then
            python3 -m zipfile -e "$live_zip" "$unpack_dir" || unpack_ok=0
        else
            unpack_ok=0
            echo "!! nothing available to unpack the zip (looked for unzip, bsdtar, python3)"
        fi
        live_exe=""
        if [ "$unpack_ok" -eq 1 ]; then
            live_exe="$(find "$unpack_dir" -iname '*.exe' -print -quit)"
        fi
        if [ "$unpack_ok" -eq 0 ]; then
            echo "!! could not unpack $(basename "$live_zip") — manual install steps are printed below"
        elif [ -z "$live_exe" ]; then
            echo "!! no installer (.exe) inside that zip — is it the official ableton.com download?"
        else
            # Live's installer is Inno Setup (6.x, verified from the stub), so
            # the engine's built-in silent flags always exist. Default: silent
            # install, with an interactive-window fallback if no install lands.
            # ABLETON_INSTALLER_UI=1 forces the window (shows Ableton's EULA
            # page); a silent run defers EULA acceptance to first launch/auth.
            run_installer() {   # extra installer arguments in "$@"
                # Run from the installer's own directory so its relative
                # payload lookups (Installer-N.bin) resolve.
                (cd "$(dirname -- "$live_exe")" && wine "./$(basename -- "$live_exe")" "$@")
            }
            # Lingering session infra (services.exe, explorer.exe) can hold a
            # finished session open for minutes; the prefix work is done once
            # the installer returns, so end the session instead of waiting it
            # out — same wineserver -k the launcher and nix build gate use.
            end_session() {
                "$WINESERVER" -k 2>/dev/null || true
                settle
            }
            if [ "${ABLETON_INSTALLER_UI:-0}" = 1 ]; then
                echo "   starting the Ableton installer — from here just click through its window"
                run_installer || echo "!! the Ableton installer exited with an error — manual install steps are printed below"
                end_session
            else
                echo "   installing Ableton Live silently — takes a few minutes (ABLETON_INSTALLER_UI=1 for the installer window)"
                # Keep the display attached: Inno's engine needs a window
                # connection even under /VERYSILENT — a headless run installs
                # NOTHING (tested 2026-07-17); with the display it installs
                # silently, verified end to end with Live 12 Suite 12.4.3.
                run_installer /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- || true
                end_session
                if ! live_installed; then
                    echo "!! the silent install produced no installation — starting the installer window"
                    run_installer || echo "!! the Ableton installer exited with an error — manual install steps are printed below"
                    end_session
                fi
            fi
            if live_installed; then live_ready=1; fi
        fi
        rm -rf "$unpack_dir"
    fi
fi

echo
echo "OK: prefix ready at $WINEPREFIX"
if [ "$live_ready" -eq 1 ]; then
    step1="  1. Live is installed — nothing more to supply here."
else
    step1="  1. Install Live (any edition) through THIS wine (plain wine reads
     WINEPREFIX, not the ABLETON_* launcher variables):
       WINEPREFIX=$WINEPREFIX \\
       $WINE_ROOT/bin/wine \"/path/to/Ableton Live NN Edition Installer.exe\"
     Or: drop the official ableton_live*.zip into $installer_dir and rerun this script."
fi
cat <<EOF

────────────────────────────────────────────────────────────────────────
Remaining steps (you supply Ableton + your own license):

$step1

  2. Launch:            ableton-live
  3. Authorize Live with your own account (binds to this prefix's MachineGuid).
  4. In Live: Options > uncheck "Auto-Scale Plugin Window"
     (prevents a plugin-window resize loop with DPI-unaware plugin UIs).
  5. Audio: Preferences > Audio > Driver Type: ASIO > Device: PipeASIO.
     PipeASIO is a native PipeWire client — no JACK layer involved.
────────────────────────────────────────────────────────────────────────
EOF
