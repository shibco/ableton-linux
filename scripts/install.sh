#!/usr/bin/env bash
# End-user step 1: install the Wine runtime, launcher, and desktop entries (reverse with uninstall.sh).
# Does not touch the Wine prefix — that is setup-prefix.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

OPT="$HOME/.local/opt"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
NAME="wine-d2d1-nspa-11.11"
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
install -m644 "$here/dpi-policy.sh" "$HOME/.local/share/ableton-wine/dpi-policy.sh"
install -m644 "$here/detect-theme.sh" "$HOME/.local/share/ableton-wine/detect-theme.sh"

# Record the kit version so a later installer can tell what it is updating
# (the kit and the repo both carry VERSION at the root).
printf '%s\n' "$(cat "$root/VERSION" 2>/dev/null || echo unknown)" \
    > "$HOME/.local/share/ableton-wine/VERSION"

echo "== install missing desktop entries -> $APPS =="
mkdir -p "$APPS"
for d in ableton-live wine-protocol-ableton; do
    if [ -e "$APPS/$d.desktop" ]; then
        echo "   preserving existing $APPS/$d.desktop"
    else
        sed "s#@HOME@#$HOME#g" "$root/desktop/$d.desktop.in" > "$APPS/$d.desktop"
    fi
done
update-desktop-database "$APPS" 2>/dev/null || true

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
