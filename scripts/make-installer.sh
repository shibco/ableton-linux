#!/usr/bin/env bash
# Assemble dist/ableton-wine-setup-<VERSION>.run: setup-run-header.sh + a tar of the end-user kit
# (runtime tarball, scripts, winetricks payloads, static cabextract, ableton-linkd).
# Repackaging only; Wine is not rebuilt.
set -euo pipefail
# ldd and sha256sum output is parsed below; localised output breaks the checks.
# C.UTF-8, never plain C: wine cannot create non-ASCII filenames under a
# non-UTF-8 locale (issues #51, #55).
export LC_ALL=C.UTF-8
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

[ -n "$tarball" ] && [ -f "$tarball" ] || { echo "!! no ${NAME}-*.tar.zst in dist/: run ./build.sh first" >&2; exit 1; }
[ -f "$tarball.sha256" ] || { echo "!! $tarball.sha256 missing" >&2; exit 1; }
echo "   runtime: $(basename "$tarball")"

echo "== [0/5] build audit (no unaudited runtime gets packed) =="
bash scripts/build-audit.sh "$tarball"

echo "== [1/5] static cabextract (bundled so SteamOS needs no extra package) =="
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

echo "== [2/5] ableton-linkd (Ableton Link session anchor, from the vendored SDK) =="
( cd vendor && sha256sum -c link.sha256 )
if [ ! -x dist/ableton-linkd ]; then
    command -v "$ENGINE" >/dev/null || { echo "!! need $ENGINE to build ableton-linkd" >&2; exit 1; }
    relabel=""
    if [ -f /sys/fs/selinux/enforce ]; then relabel=",Z"; fi
    # Header-only SDK (include/ + asio-standalone); -static-libstdc++ -static-libgcc
    # keep DT_NEEDED to host C-runtime sonames: install.sh gates exactly that.
    $ENGINE run --rm \
        -v "$root:/src:ro$relabel" \
        -v "$root/dist:/out:rw$relabel" \
        "$IMAGE" bash -ec '
            mkdir -p /work/link && cd /work/link
            tar -I zstd -xf /src/vendor/link-4.0.tar.zst
            g++ -O2 -std=c++17 -Wall -Wno-multichar \
                -I include -I modules/asio-standalone/asio/include \
                -DLINK_PLATFORM_UNIX=1 -DLINK_PLATFORM_LINUX=1 \
                -static-libstdc++ -static-libgcc \
                /src/tools/ableton-linkd.cpp -o ableton-linkd \
                -lpthread -latomic
            strip ableton-linkd
            install -m755 ableton-linkd /out/ableton-linkd'
fi
dist/ableton-linkd --help >/dev/null 2>&1 || \
    { echo "!! dist/ableton-linkd does not run on this host" >&2; exit 1; }
echo "   ableton-linkd: $(du -h dist/ableton-linkd | cut -f1), statically carries libstdc++/libgcc"

echo "== [3/5] stage the kit =="
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
kit="$stage/kit"
mkdir -p "$kit/bin" "$kit/dist" "$kit/vendor"
cp -a "$tarball" "$tarball.sha256" "$kit/dist/"
cp -a "dist/BUILD-INFO-${VERSION}.txt" "$kit/" 2>/dev/null || true
mkdir -p "$kit/scripts"
cp -a scripts/install.sh scripts/setup-prefix.sh scripts/uninstall.sh \
      scripts/ableton-live scripts/max9 scripts/detect-scale.sh \
      scripts/detect-theme.sh scripts/check-live-audio.sh scripts/setup-link.sh \
      "$kit/scripts/"
install -m644 scripts/ableton-linkd.service "$kit/scripts/ableton-linkd.service"
install -m644 tools/setsyscolors.exe "$kit/scripts/setsyscolors.exe"
install -m644 tools/learnheal.exe "$kit/scripts/learnheal.exe"
cp -a desktop "$kit/desktop"
cp -a vendor/winetricks vendor/winetricks-cache "$kit/vendor/"
cp -a VERSION README.md "$kit/"
install -m755 dist/cabextract-static "$kit/bin/cabextract"
install -m755 dist/ableton-linkd "$kit/bin/ableton-linkd"
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

echo "== [4/5] pack + seal =="
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

echo "== [5/5] wrapper self-check =="
sh "$out" --help >/dev/null
echo
echo "OK: $out ($(du -h "$out" | cut -f1))"
echo "Copy it (plus your Ableton installer .exe) to a USB stick and run:"
echo "  sh /run/media/*/*/ableton-wine-setup-${VERSION}.run"
