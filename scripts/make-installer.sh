#!/usr/bin/env bash
# Assemble dist/ableton-wine-setup-<VERSION>.run: setup-run-header.sh + a tar of the end-user kit
# (runtime tarball, scripts, winetricks payloads, static cabextract). Repackaging only; Wine is not rebuilt.
set -euo pipefail
# ldd and sha256sum output is parsed below; localised output breaks the checks.
export LC_ALL=C
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ableton-wine-build:22.04}"
NAME="wine-d2d1-nspa-11.11"
VERSION="$(cat VERSION)"
# exact-version runtime if present, else the newest built one
tarball="dist/${NAME}-${VERSION}.tar.zst"
[ -f "$tarball" ] || tarball="$(ls dist/${NAME}-*.tar.zst 2>/dev/null | sort -V | tail -1 || true)"

[ -n "$tarball" ] && [ -f "$tarball" ] || { echo "!! no ${NAME}-*.tar.zst in dist/ — run ./build.sh first" >&2; exit 1; }
[ -f "$tarball.sha256" ] || { echo "!! $tarball.sha256 missing" >&2; exit 1; }
echo "   runtime: $(basename "$tarball")"

echo "== [0/4] build audit (no unaudited runtime gets packed) =="
bash scripts/build-audit.sh "$tarball"

echo "== [1/4] static cabextract (bundled so SteamOS needs no extra package) =="
( cd vendor && sha256sum -c cabextract.sha256 )
if [ ! -x dist/cabextract-static ]; then
    command -v "$ENGINE" >/dev/null || { echo "!! need $ENGINE to build cabextract" >&2; exit 1; }
    relabel=""
    if [ -f /sys/fs/selinux/enforce ]; then relabel=",Z"; fi
    $ENGINE run --rm \
        -v "$root:/src:ro$relabel" \
        -v "$root/dist:/out:rw$relabel" \
        "$IMAGE" bash -ec '
            mkdir -p /work/cab && cd /work/cab
            tar xzf /src/vendor/cabextract-1.11.tar.gz --strip-components=1
            ./configure LDFLAGS="-static" >/dev/null
            make -s
            ldd cabextract 2>&1 | grep -q "not a dynamic executable" || {
                echo "!! cabextract did not link statically" >&2; exit 1; }
            ./cabextract --version
            strip cabextract
            install -m755 cabextract /out/cabextract-static'
fi
dist/cabextract-static --version >/dev/null 2>&1 || \
    { echo "!! dist/cabextract-static does not run on this host" >&2; exit 1; }
echo "   cabextract-static: $(dist/cabextract-static --version 2>&1 | head -1)"

echo "== [2/4] stage the kit =="
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
kit="$stage/kit"
mkdir -p "$kit/bin" "$kit/dist" "$kit/vendor"
cp -a "$tarball" "$tarball.sha256" "$kit/dist/"
cp -a "dist/BUILD-INFO-${VERSION}.txt" "$kit/" 2>/dev/null || true
mkdir -p "$kit/scripts"
cp -a scripts/install.sh scripts/setup-prefix.sh scripts/uninstall.sh \
      scripts/ableton-live scripts/max9 scripts/detect-scale.sh \
      scripts/detect-theme.sh scripts/check-live-audio.sh "$kit/scripts/"
install -m644 tools/setsyscolors.exe "$kit/scripts/setsyscolors.exe"
install -m644 tools/learnheal.exe "$kit/scripts/learnheal.exe"
cp -a desktop "$kit/desktop"
cp -a vendor/winetricks vendor/winetricks-cache "$kit/vendor/"
cp -a VERSION README.md "$kit/"
install -m755 dist/cabextract-static "$kit/bin/cabextract"

echo "== [3/4] pack + seal =="
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

echo "== [4/4] wrapper self-check =="
sh "$out" --help >/dev/null
echo
echo "OK: $out ($(du -h "$out" | cut -f1))"
echo "Copy it (plus your Ableton installer .exe) to a USB stick and run:"
echo "  sh /run/media/*/*/ableton-wine-setup-${VERSION}.run"
