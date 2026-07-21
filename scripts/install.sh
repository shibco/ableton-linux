#!/usr/bin/env bash
# End-user step 1: install the Wine runtime, launcher, and desktop entries (reverse with uninstall.sh).
# Does not touch the Wine prefix — that is setup-prefix.sh.
set -euo pipefail
# readelf and sha256sum output is parsed below; localised output breaks the
# checks (issue #36).
export LC_ALL=C
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

OPT="$HOME/.local/opt"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
NAME="wine-d2d1-nspa-11.13"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
stage=""
backup=""
launcher_backup=""
promoted=0

cleanup()
{
    rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
        failed="$OPT/${NAME}.failed-$stamp"
        if [ "$promoted" -eq 1 ] && [ -e "$OPT/$NAME" ]; then
            mv "$OPT/$NAME" "$failed" || true
        fi
        if [ -n "$backup" ] && [ -e "$backup" ] && [ ! -e "$OPT/$NAME" ]; then
            mv "$backup" "$OPT/$NAME" || true
        elif [ -n "$backup" ] && [ -e "$backup" ]; then
            echo "!! $OPT/$NAME still present; backup left at $backup" >&2
        fi
        if [ -n "$launcher_backup" ] && [ -e "$launcher_backup" ]; then
            cp -a "$launcher_backup" "$BIN/ableton-live" || true
        fi
        echo "!! install failed; previous runtime restored" >&2
    fi
    [ -z "$stage" ] || rm -rf "$stage"
    exit "$rc"
}
trap cleanup EXIT

# tarball: prefer dist/ (freshly built), else a release tarball dropped in root
tarball="$(ls "$root"/dist/${NAME}-*.tar.zst 2>/dev/null | sort -V | tail -1 || true)"
[ -z "$tarball" ] && tarball="$(ls "$root"/${NAME}-*.tar.zst 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$tarball" ] || { echo "!! no ${NAME}-*.tar.zst found — run ./build.sh first, or drop a release tarball in $root/dist/"; exit 1; }

echo "== verify checksum =="
if [ -f "$tarball.sha256" ]; then
    ( cd "$(dirname "$tarball")" && sha256sum -c "$(basename "$tarball").sha256" )
else
    echo "   (no .sha256 next to tarball — skipping)"
fi

if pgrep -af '[A]bleton Live.*\.exe|[P]ush2DisplayProcess.exe' >/dev/null 2>&1 || \
   pgrep -af "$OPT/$NAME" >/dev/null 2>&1; then
    echo "!! the installed Ableton Wine is still running — close Live, wait a few seconds, and rerun" >&2
    exit 1
fi

echo "== stage and validate patched Wine =="
mkdir -p "$OPT"
stage="$(mktemp -d "$OPT/.${NAME}.install.XXXXXX")"
tar -C "$stage" -I zstd -xf "$tarball"
candidate="$stage/$NAME"
for required in \
    bin/wine bin/wineserver \
    lib/wine/x86_64-windows/libusb-1.0.dll \
    lib/wine/x86_64-unix/libusb-1.0.so \
    lib/wine/x86_64-unix/comdlg32.so \
    lib/wine/x86_64-unix/winealsa.so \
    lib/wine/x86_64-windows/pipeasio64.dll \
    lib/wine/x86_64-windows/pipeasio.dll \
    lib/wine/x86_64-unix/pipeasio64.dll.so \
    lib/wine/x86_64-unix/pipeasio.dll.so; do
    [ -s "$candidate/$required" ] || { echo "!! package is missing $required" >&2; exit 1; }
done
if [ -e "$candidate/lib/wine/i386-windows/libusb-1.0.dll" ] || \
   [ -e "$candidate/lib/wine/i386-unix/libusb-1.0.so" ]; then
    echo "!! package unexpectedly contains a 32-bit Push 2 bridge" >&2
    exit 1
fi
if command -v readelf >/dev/null && command -v strings >/dev/null; then
    readelf -d "$candidate/lib/wine/x86_64-unix/libusb-1.0.so" | \
        grep -F 'Shared library: [libusb-1.0.so.0]' >/dev/null || {
            echo "!! Push 2 bridge is not linked to host libusb-1.0.so.0" >&2
            exit 1
        }
    strings "$candidate/lib/wine/x86_64-unix/comdlg32.so" | \
        grep -F 'org.freedesktop.portal.FileChooser' >/dev/null || {
            echo "!! package comdlg32 lacks the XDG portal backend" >&2
            exit 1
        }
    readelf -d "$candidate/lib/wine/x86_64-unix/pipeasio64.dll.so" | \
        grep -F 'Shared library: [libpipewire-0.3.so.0]' >/dev/null || {
            echo "!! PipeASIO is not linked to host libpipewire-0.3.so.0" >&2
            exit 1
        }
else
    # binutils absent (e.g. stock SteamOS); the checksum above already covers content integrity.
    echo "   (binutils not found — skipping deep binary checks)"
fi

echo "== promote runtime with dated rollback =="
if [ -e "$OPT/$NAME" ]; then
    backup="$OPT/${NAME}-rollback-$stamp"
    [ ! -e "$backup" ] || { echo "!! rollback path already exists: $backup" >&2; exit 1; }
    mv "$OPT/$NAME" "$backup"
fi
mv "$candidate" "$OPT/$NAME"
promoted=1
"$OPT/$NAME/bin/wine" --version

echo "== install launcher -> $BIN/ableton-live =="
mkdir -p "$BIN"
if [ -e "$BIN/ableton-live" ]; then
    launcher_backup="$BIN/ableton-live.rollback-$stamp"
    cp -a "$BIN/ableton-live" "$launcher_backup"
fi
install -m755 "$here/ableton-live" "$BIN/ableton-live"

echo "== install detection libs -> ~/.local/share/ableton-wine =="
# The launcher sources these on every start (DPI auto-calibration, light/dark theme sync).
mkdir -p "$HOME/.local/share/ableton-wine"
install -m644 "$here/detect-scale.sh" "$HOME/.local/share/ableton-wine/detect-scale.sh"
install -m644 "$here/detect-theme.sh" "$HOME/.local/share/ableton-wine/detect-theme.sh"
# setsyscolors.exe repaints the top bar mid-session when the Live theme changes;
# without it the colors still apply on the next launch. Kit stages it next to
# these scripts; a repo checkout carries it in tools/.
for f in "$here/setsyscolors.exe" "$root/tools/setsyscolors.exe"; do
    if [ -f "$f" ]; then
        install -m644 "$f" "$HOME/.local/share/ableton-wine/setsyscolors.exe"
        break
    fi
done
# learnheal.exe auto-heals the Learn View / doc sidebar fossil-on-open
# (notes/ABLETON-WINE-LEARNVIEW-FLICKER.md); without it the pane needs a
# manual splitter nudge once per session.
for f in "$here/learnheal.exe" "$root/tools/learnheal.exe"; do
    if [ -f "$f" ]; then
        install -m644 "$f" "$HOME/.local/share/ableton-wine/learnheal.exe"
        break
    fi
done

# Record the kit version so a later installer can tell what it is updating
# (the kit and the repo both carry VERSION at the root).
printf '%s\n' "$(cat "$root/VERSION" 2>/dev/null || echo unknown)" \
    > "$HOME/.local/share/ableton-wine/VERSION"

echo "== install desktop entries -> $APPS =="
mkdir -p "$APPS"
# Detect the installed Live edition for the menu entry (issue #39): the
# newest Program exe under the prefix wins, matching the launcher's
# discovery. Without an install yet, generic values apply; rerunning the
# installer after Live is installed refreshes the entry.
live_name="Ableton Live"
live_icon="live-suite"
live_wmclass="ableton live 12 suite.exe"
live_prefix="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
newest=""
for exe in "$live_prefix"/drive_c/ProgramData/Ableton/Live*/Program/Ableton\ Live*.exe; do
    [ -e "$exe" ] || continue
    if [ -z "$newest" ] || [ "$exe" -nt "$newest" ]; then newest="$exe"; fi
done
if [ -n "$newest" ]; then
    live_name="$(basename "$newest" .exe)"
    live_wmclass="$(basename "$newest" | tr '[:upper:]' '[:lower:]')"
    edition="$(printf '%s' "$live_name" | awk '{print tolower($NF)}')"
    if [ -f "$root/desktop/icons/scalable/apps/live-$edition.svg" ]; then
        live_icon="live-$edition"
    fi
fi
# The visible launcher entry: an entry whose Exec does not route through the
# launcher is treated as hand-made and preserved; ours is refreshed so the
# name, icon and WM class track the installed edition.
if [ -e "$APPS/ableton-live.desktop" ] && ! grep -qF "$BIN/ableton-live" "$APPS/ableton-live.desktop"; then
    echo "   preserving existing $APPS/ableton-live.desktop (it does not route through the launcher)"
else
    sed -e "s#@HOME@#$HOME#g" -e "s#@NAME@#$live_name#g" \
        -e "s#@ICON@#$live_icon#g" -e "s#@WMCLASS@#$live_wmclass#g" \
        "$root/desktop/ableton-live.desktop.in" > "$APPS/ableton-live.desktop"
    echo "   installed $APPS/ableton-live.desktop ($live_name)"
fi
# The authorization handlers (ableton: URLs, .auz response files). They take
# winemenubuilder's canonical names on purpose: a prefix where winemenubuilder
# still runs (a Live beta in a scratch prefix, say) exports its own handler
# over ours, pointing at stock wine and the wrong prefix. An entry that does
# not route through the launcher is replaced, not preserved, and canonical
# copies are staged for the launcher's start-time repair.
# See notes/ABLETON-WINE-ONLINE-AUTH.md.
for d in wine-protocol-ableton wine-extension-auz; do
    sed "s#@HOME@#$HOME#g" "$root/desktop/$d.desktop.in" > "$HOME/.local/share/ableton-wine/$d.desktop"
    if [ -e "$APPS/$d.desktop" ] && grep -qF "$BIN/ableton-live" "$APPS/$d.desktop"; then
        echo "   preserving existing $APPS/$d.desktop"
    else
        [ ! -e "$APPS/$d.desktop" ] || echo "   replacing $APPS/$d.desktop (it does not route through the launcher)"
        cp "$HOME/.local/share/ableton-wine/$d.desktop" "$APPS/$d.desktop"
    fi
done
update-desktop-database "$APPS" 2>/dev/null || true

echo "== install icons =="
# App and MIME icons (issue #39, PR #25). User-local hicolor is the fallback
# theme on every desktop; scalable SVGs need no cache.
ICONS="$HOME/.local/share/icons/hicolor"
install -d "$ICONS/scalable/apps" "$ICONS/scalable/mimetypes" "$ICONS/symbolic/apps"
install -m644 "$root"/desktop/icons/scalable/apps/*.svg "$ICONS/scalable/apps/"
install -m644 "$root"/desktop/icons/scalable/mimetypes/*.svg "$ICONS/scalable/mimetypes/"
install -m644 "$root"/desktop/icons/symbolic/apps/*.svg "$ICONS/symbolic/apps/"
gtk-update-icon-cache -q "$ICONS" 2>/dev/null || true

echo "== register the authorization MIME types =="
# .auz is the response file ableton.com serves for offline authorization. The
# prefix side is registered by Live's installer; the host side is ours, since
# winemenubuilder (which would export it) is disabled by setup-prefix.sh.
mkdir -p "$HOME/.local/share/mime/packages"
install -m644 "$root/desktop/x-wine-extension-auz.xml" "$HOME/.local/share/mime/packages/x-wine-extension-auz.xml"
# Live document types: sets, clips, packs and the rest (issue #40, PR #25).
install -m644 "$root/desktop/icons/application-ableton-live.xml" "$HOME/.local/share/mime/packages/application-ableton-live.xml"
update-mime-database "$HOME/.local/share/mime" >/dev/null 2>&1 || true
# Pin the defaults: with a second claimant present, cache order decides, and
# Chromium consults only the mimeapps.list default.
if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default wine-protocol-ableton.desktop x-scheme-handler/ableton 2>/dev/null || true
    xdg-mime default wine-extension-auz.desktop application/x-wine-extension-auz 2>/dev/null || true
    xdg-mime default ableton-live.desktop application/x-ableton-live-set \
        application/x-ableton-live-clip application/x-ableton-live-pack 2>/dev/null || true
fi

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "!! note: $BIN is not on your PATH — add it or call ~/.local/bin/ableton-live directly" ;;
esac

promoted=0
trap - EXIT
rm -rf "$stage"

echo
echo "OK. Runtime rollback: ${backup:-none (fresh install)}"
echo "Next: ./scripts/setup-prefix.sh"
