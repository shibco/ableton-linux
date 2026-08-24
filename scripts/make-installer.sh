#!/usr/bin/env bash
# Assemble dist/ableton-wine-setup-<VERSION>.run: setup-run-header.sh + a tar of the end-user kit
# (runtime tarball, scripts, winetricks payloads, static cabextract, ableton-linkd).
# Repackaging only; Wine is not rebuilt.
set -euo pipefail
umask 022
# ldd and sha256sum output is parsed below; localised output breaks the checks.
# C.UTF-8, never plain C: wine cannot create non-ASCII filenames under a
# non-UTF-8 locale (issues #51, #55).
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"

cd "$root"

NAME="wine-d2d1-nspa-11.13"
VERSION="$(cat VERSION)"
[[ "$VERSION" =~ ^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] \
    && [ "$(wc -l < VERSION)" -eq 1 ] || {
    echo "!! VERSION must contain exactly one release version" >&2; exit 1; }
tarball="dist/${NAME}-${VERSION}.tar.zst"
build_info="dist/BUILD-INFO-${VERSION}.txt"
probe="dist/pipewire-version-probe"
ntsync_probe="beta/tester-kit/probes/windows/ntsyncprobe.exe"
cabextract_static="dist/cabextract-static"
linkd="dist/ableton-linkd"

[ -f "$tarball" ] || { echo "!! exact runtime $(basename "$tarball") is missing: run ./build.sh first" >&2; exit 1; }
[ -f "$tarball.sha256" ] || { echo "!! $tarball.sha256 missing" >&2; exit 1; }
[ -s "$build_info" ] || { echo "!! exact BUILD-INFO-${VERSION}.txt is missing" >&2; exit 1; }
[ -x "$probe" ] || { echo "!! dist/pipewire-version-probe is missing" >&2; exit 1; }
[ -f "$ntsync_probe" ] || { echo "!! $ntsync_probe is missing" >&2; exit 1; }
[ -x "$cabextract_static" ] || { echo "!! dist/cabextract-static is missing: run ./build.sh first" >&2; exit 1; }
[ -x "$linkd" ] || { echo "!! dist/ableton-linkd is missing: run ./build.sh first" >&2; exit 1; }
if [ "$(grep -c '^dist-version:' "$build_info" || true)" -ne 1 ] \
   || ! grep -qxF "dist-version: $VERSION" "$build_info"; then
    echo "!! BUILD-INFO does not match VERSION $VERSION" >&2
    exit 1
fi
bash scripts/check-release-build-info.sh "$build_info" \
    --version "$VERSION" --runtime "$tarball"
probe_record="$(sed -n 's/^pipewire-version-probe: *//p' "$build_info")"
[[ "$probe_record" =~ ^[0-9a-f]{64}$ ]] \
    && [ "$probe_record" = "$(sha256sum "$probe" | awk '{print $1}')" ] || {
    echo "!! PipeWire probe does not match BUILD-INFO" >&2; exit 1; }
for helper_spec in \
    "cabextract-static|$cabextract_static" \
    "ableton-linkd|$linkd"; do
    helper_key="${helper_spec%%|*}"
    helper_path="${helper_spec#*|}"
    helper_record="$(sed -n "s/^${helper_key}: *//p" "$build_info")"
    [ "$(grep -c "^${helper_key}:" "$build_info" || true)" -eq 1 ] \
        && [[ "$helper_record" =~ ^[0-9a-f]{64}$ ]] \
        && [ "$helper_record" = "$(sha256sum "$helper_path" | awk '{print $1}')" ] || {
        echo "!! $helper_path does not match BUILD-INFO" >&2
        exit 1
    }
done
[ "$(wc -l < "$tarball.sha256")" -eq 1 ] || {
    echo "!! exact runtime checksum record is invalid" >&2; exit 1; }
read -r runtime_sha runtime_checksum_name runtime_checksum_extra < "$tarball.sha256"
runtime_checksum_name="${runtime_checksum_name#\*}"
[[ "$runtime_sha" =~ ^[0-9a-f]{64}$ ]] && [ -z "$runtime_checksum_extra" ] \
    && [ "$runtime_checksum_name" = "$(basename "$tarball")" ] \
    && [ "$runtime_sha" = "$(sha256sum "$tarball" | awk '{print $1}')" ] || {
    echo "!! exact runtime checksum record is invalid" >&2; exit 1; }
echo "   runtime: $(basename "$tarball")"

echo "== [0/5] build audit (no unaudited runtime gets packed) ==" # except arm64 lol
if [ "$ARCH" = "x86_64" ]; then
bash scripts/build-audit.sh "$tarball"
fi

echo "== [1/5] verify attested installer helpers =="
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
"$cabextract_static" --version >/dev/null 2>&1 || \
    { echo "!! attested cabextract-static does not run on this host" >&2; exit 1; }
"$linkd" --help >/dev/null 2>&1 || \
    { echo "!! attested ableton-linkd does not run on this host" >&2; exit 1; }
echo "   cabextract-static: $($cabextract_static --version 2>&1 | head -1)"
echo "   ableton-linkd: $(du -h "$linkd" | cut -f1)"

echo "== [2/5] stage the kit =="
kit="$stage/kit"
mkdir -p "$kit/bin" "$kit/dist" "$kit/vendor" "$kit/scripts/lib"
install -m644 "$tarball" "$tarball.sha256" "$kit/dist/"
install -m644 "$build_info" "$kit/"
mkdir -p "$kit/scripts"
cp -- scripts/installer.sh scripts/install.sh scripts/setup-prefix.sh scripts/uninstall.sh \
      scripts/ableton-live scripts/max9 scripts/detect-scale.sh \
      scripts/detect-theme.sh scripts/shortcut-hold.sh \
      scripts/check-live-audio.sh scripts/check-ntsync.sh \
      scripts/setup-link.sh scripts/ableton-linkctl \
      "$kit/scripts/"
chmod 755 "$kit/scripts/installer.sh" "$kit/scripts/install.sh" \
    "$kit/scripts/setup-prefix.sh" "$kit/scripts/uninstall.sh" \
    "$kit/scripts/ableton-live" "$kit/scripts/max9" \
    "$kit/scripts/detect-scale.sh" "$kit/scripts/detect-theme.sh" \
    "$kit/scripts/shortcut-hold.sh" "$kit/scripts/check-live-audio.sh" \
    "$kit/scripts/check-ntsync.sh" "$kit/scripts/setup-link.sh" \
    "$kit/scripts/ableton-linkctl"
install -m755 scripts/setup-realtime.sh scripts/audio-report.sh scripts/rollback.sh \
      "$kit/scripts/"
install -m644 "$ntsync_probe" "$kit/scripts/ntsyncprobe.exe"
cp -- scripts/lib/config.sh scripts/lib/lifecycle.sh scripts/lib/live-options.sh \
      scripts/lib/manifest.sh scripts/lib/pipeasio.sh \
      "$kit/scripts/lib/"
chmod 644 "$kit/scripts/lib/config.sh" "$kit/scripts/lib/lifecycle.sh" \
    "$kit/scripts/lib/live-options.sh" "$kit/scripts/lib/manifest.sh" \
    "$kit/scripts/lib/pipeasio.sh"
install -m644 scripts/ableton-linkd.service "$kit/scripts/ableton-linkd.service"
install -m644 tools/setsyscolors.exe "$kit/scripts/setsyscolors.exe"
install -m644 tools/learnheal.exe "$kit/scripts/learnheal.exe"
copy_tracked_kit_paths()
{
    local source destination mode
    while IFS= read -r -d '' source; do
        [ -e "$source" ] || [ -L "$source" ] || {
            echo "!! tracked installer input is missing: $source" >&2
            return 1
        }
        destination="$kit/$source"
        mkdir -p -- "$(dirname "$destination")"
        if [ -L "$source" ]; then
            cp -P -- "$source" "$destination"
        elif [ -f "$source" ]; then
            mode=644
            [ -x "$source" ] && mode=755
            install -m "$mode" "$source" "$destination"
        else
            echo "!! tracked installer input has an unsupported type: $source" >&2
            return 1
        fi
    done < <(git ls-files -z -- desktop vendor/winetricks vendor/winetricks-cache)
}
copy_tracked_kit_paths
# Bitstream Vera must ship: it is the terminal entry of Max for Live's font
# fallback chain, and without it any M4L device that requests a typeface the
# prefix lacks hangs Live outright (frozen window, audio still playing). Not a
# nice-to-have; install_maxplug_fallback_fonts() in setup-prefix.sh installs it.
( cd vendor && sha256sum -c bitstream-vera.sha256 )
mkdir -p "$kit/vendor/fonts/bitstream-vera"
# The notice ships beside the fonts as well as in licenses/, so the directory
# stays self-describing if it is copied out of an extracted kit on its own.
install -m644 vendor/fonts/bitstream-vera/*.ttf \
              vendor/fonts/bitstream-vera/COPYRIGHT.TXT \
              "$kit/vendor/fonts/bitstream-vera/"
install -m644 VERSION README.md TROUBLESHOOTING.md LICENCE "$kit/"
install -m755 "$cabextract_static" "$kit/bin/cabextract"
install -m755 "$linkd" "$kit/bin/ableton-linkd"
install -m755 "$probe" "$kit/bin/pipewire-version-probe"
# Ableton Link is GPLv2+ with no linking exception, so the built daemon's
# complete corresponding source travels with the kit: the pinned tarball in
# vendor/ plus the license text and a pointer note in licenses/.
install -m644 vendor/link-4.0.tar.zst "$kit/vendor/link-4.0.tar.zst"
mkdir -p "$kit/licenses"
tar -I zstd -xOf vendor/link-4.0.tar.zst ./LICENSE.md > "$kit/licenses/link-LICENSE.md"
cat > "$kit/licenses/SOURCE.txt" <<'EOF'
ableton-linkd is built from Ableton Link 4.0, GPLv2+; complete corresponding
source is in vendor/link-4.0.tar.zst in this kit and at https://github.com/Ableton/link
EOF
# The Bitstream Vera license permits redistribution of the unmodified fonts, but
# requires the copyright, trademark and permission notices travel with every
# copy. The fonts here are byte-identical upstream 1.10 files.
install -m644 vendor/fonts/bitstream-vera/COPYRIGHT.TXT \
              "$kit/licenses/bitstream-vera-COPYRIGHT.txt"

for staged_executable in \
    "$kit/scripts/setup-realtime.sh" "$kit/scripts/audio-report.sh" \
    "$kit/scripts/check-ntsync.sh" \
    "$kit/scripts/rollback.sh" "$kit/bin/pipewire-version-probe"; do
    [ -x "$staged_executable" ] || {
        echo "!! staged installer helper is not executable: $staged_executable" >&2
        exit 1
    }
done
cmp -s -- "$probe" "$kit/bin/pipewire-version-probe" || {
    echo "!! staged PipeWire compatibility check changed while packing" >&2; exit 1; }
cmp -s -- "$ntsync_probe" "$kit/scripts/ntsyncprobe.exe" || {
    echo "!! staged NTSync semantics probe changed while packing" >&2; exit 1; }
cmp -s -- "$build_info" "$kit/BUILD-INFO-${VERSION}.txt" || {
    echo "!! staged BUILD-INFO changed while packing" >&2; exit 1; }

echo "== [3/5] pack + seal =="
payload="$stage/payload.tar"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "$payload" -C "$kit" .
payload_sha="$(sha256sum "$payload" | awk '{print $1}')"
out="dist/ableton-wine-setup-${VERSION}.run"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@PAYLOAD_SHA@/$payload_sha/g" \
    scripts/setup-run-header.sh > "$out"
cat "$payload" >> "$out"
chmod +x "$out"
( cd dist && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )

echo "== [4/5] wrapper self-check =="
bash scripts/check-release-build-info.sh "$build_info" \
    --version "$VERSION" --runtime "$tarball" --installer "$out"
echo
echo "== [5/5] done =="
echo "OK: $out ($(du -h "$out" | cut -f1))"
echo "Copy it (plus your Ableton installer file) to a USB stick and run:"
echo "  sh /run/media/*/*/ableton-wine-setup-${VERSION}.run install"
