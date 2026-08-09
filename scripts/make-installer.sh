#!/usr/bin/env bash
# Assemble dist/ableton-wine-setup-<LABEL>.run: setup-run-header.sh + a tar of the end-user kit
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
# Runtime naming and tarball selection resolve in one place; see
# scripts/runtime-env.sh.
for _l in "$(dirname "$0")/runtime-env.sh" "$here/runtime-env.sh"; do
    # shellcheck source=scripts/runtime-env.sh
    [ -r "$_l" ] && . "$_l" && break
done
command -v works_pick_tarball >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found next to $0" >&2; exit 1; }
NAME="$(works_runtime_name)"
VERSION="$(cat VERSION)"
# What the finished installer is called, as opposed to which runtime goes in it.
# They are the same for a release and differ for a nightly, which must not bump
# VERSION: that file is committed, and repo-hygiene and release.bats both assert
# its format and its pairing with CHANGELOG and BUILD-INFO. Everything that
# locates a build input keeps using VERSION; only the artifact's name, the
# header stamp and the version recorded into the installed kit use LABEL.
LABEL="${WORKS_DIST_LABEL:-$VERSION}"
# WORKS_RUNTIME_TARBALL pins one outright; otherwise the exact-version
# runtime if present, else the newest properly-named one. Never a bare glob.
if [ -n "${WORKS_RUNTIME_TARBALL:-}" ]; then
    tarball="$WORKS_RUNTIME_TARBALL"
    [ -f "$tarball" ] || { echo "!! WORKS_RUNTIME_TARBALL is not a file: $tarball" >&2; exit 1; }
else
    tarball="dist/${NAME}-${VERSION}.tar.zst"
    [ -f "$tarball" ] || tarball="$(works_pick_tarball dist)"
fi

[ -n "$tarball" ] && [ -f "$tarball" ] || { echo "!! no ${NAME}-*.tar.zst in dist/: run ./build.sh first" >&2; exit 1; }
# The kit carries this tarball and the kit's own install.sh selects it by name,
# so a name the selector rejects builds a kit that packs cleanly and then dies
# on the user's machine with "no tarball found". Only the pin reaches here with
# an unchecked name — the branch above already filters — but the pin is exactly
# how a published nightly gets packed, and those are named
# <name>-<version>+nightly.<sha>.tar.zst.
#
# install.sh honours its own pin whatever the name, deliberately: there the
# consequence lands on whoever set the variable. Here it lands on whoever is
# handed the .run, so this refuses instead.
works_is_runtime_tarball "$tarball" || {
    echo "!! not a name the kit's install.sh will select: $(basename "$tarball")" >&2
    echo "   expected ${NAME}-<YYYY.MM.DD.N>.tar.zst — rename it, or drop it in dist/ under that name" >&2
    exit 1; }
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
if [ ! -x dist/ableton-linkd ]; then
    ENGINE="$ENGINE" IMAGE="$IMAGE" ./scripts/build-ableton-linkd.sh
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
cp -a scripts/runtime-env.sh scripts/works scripts/works-runtime scripts/works-update scripts/works-plug scripts/install.sh scripts/setup-prefix.sh scripts/uninstall.sh \
      scripts/ableton-live scripts/max9 scripts/detect-scale.sh \
      scripts/detect-theme.sh scripts/shortcut-hold.sh \
      scripts/check-live-audio.sh scripts/setup-link.sh \
      "$kit/scripts/"
install -m644 scripts/ableton-linkd.service "$kit/scripts/ableton-linkd.service"
install -m644 tools/setsyscolors.exe "$kit/scripts/setsyscolors.exe"
install -m644 tools/learnheal.exe "$kit/scripts/learnheal.exe"
cp -a desktop "$kit/desktop"
cp -a vendor/winetricks "$kit/vendor/"
# The cache is staged by tracked path, not wholesale. Copying the directory as
# it stands ships whatever the build machine has downloaded: on the development
# machine an untracked win7sp1 entry made the kit 1.6G against CI's 112M, so the
# installer's size depended on who built it. What the repository tracks is its
# own statement of what it ships; anything else in there is a local download.
mkdir -p "$kit/vendor/winetricks-cache"
if git -C . rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        install -Dm644 "$f" "$kit/${f#vendor/}" 2>/dev/null || install -Dm644 "$f" "$kit/$f"
    done < <(git -C . ls-files vendor/winetricks-cache)
else
    # Not a checkout (an exported tarball): nothing says which entries are ours,
    # so take them all rather than ship an incomplete cache.
    echo "   (not a git checkout: staging the whole winetricks cache)"
    cp -a vendor/winetricks-cache "$kit/vendor/"
fi
# Bitstream Vera must ship: it is the terminal entry of Max for Live's font
# fallback chain, and without it any M4L device that requests a typeface the
# prefix lacks hangs Live outright (frozen window, audio still playing). Not a
# nice-to-have - see notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md
# and install_maxplug_fallback_fonts() in setup-prefix.sh.
( cd vendor && sha256sum -c bitstream-vera.sha256 )
mkdir -p "$kit/vendor/fonts/bitstream-vera"
# The notice ships beside the fonts as well as in licenses/, so the directory
# stays self-describing if it is copied out of an extracted kit on its own.
install -m644 vendor/fonts/bitstream-vera/*.ttf \
              vendor/fonts/bitstream-vera/COPYRIGHT.TXT \
              "$kit/vendor/fonts/bitstream-vera/"
cp -a README.md TROUBLESHOOTING.md BUILDING.md "$kit/"
# The kit records LABEL, not VERSION: a nightly and the release it was built
# after share a VERSION, and the installed tree has to be able to say which of
# the two it is.
printf '%s\n' "$LABEL" > "$kit/VERSION"
# The kit says which channel it belongs to. Without it install.sh promotes into
# whatever channel the machine already followed, so installing a nightly while
# configured for stable would point `stable` at a nightly build.
#
# One word rather than the manifest: the manifest carries the sealed kit's own
# checksum and so cannot exist until after this is packed. They answer different
# questions anyway - the manifest says what a channel currently points at, for
# the updater; this says what this kit is, for the installer holding it.
printf '%s\n' "${WORKS_CHANNEL_PUBLISH:-stable}" > "$kit/channel"
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
# The Bitstream Vera license permits redistribution of the unmodified fonts, but
# requires the copyright, trademark and permission notices travel with every
# copy. The fonts here are byte-identical upstream 1.10 files.
install -m644 vendor/fonts/bitstream-vera/COPYRIGHT.TXT \
              "$kit/licenses/bitstream-vera-COPYRIGHT.txt"

echo "== [4/5] pack + seal =="
payload="$stage/payload.tar"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "$payload" -C "$kit" .
payload_sha="$(sha256sum "$payload" | awk '{print $1}')"
out="dist/ableton-wine-setup-${LABEL}.run"
sed -e "s/@VERSION@/$LABEL/g" -e "s/@PAYLOAD_SHA@/$payload_sha/g" \
    scripts/setup-run-header.sh > "$out"
cat "$payload" >> "$out"
chmod +x "$out"
( cd dist && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )

# The channel manifest, beside the kit. Written from the runtime's own
# BUILD-INFO by the same function that reads it, so a manifest this repo
# publishes is one its updater accepts - the round trip is tested. The publish
# step uploads it; nothing here decides which channel a build is for, so it
# takes one, defaulting to stable.
#
# The installer is named as *published*, which is not what it is called here:
# both channels upload a second copy under a fixed name (install-ableton-latest
# .run, install-ableton-nightly.run) so the download URL survives a release. The
# updater resolves that name against the manifest's own URL, so naming the
# versioned artifact would send it to a URL that stops existing next release.
# Same bytes either way, so the checksum is the built file's.
# Read from the runtime being packed, not from dist/BUILD-INFO-<version>.txt:
# the tarball's copy is the one that lands on the user's machine and the one the
# updater compares against. See works_tarball_buildinfo.
info="$stage/runtime-BUILD-INFO.txt"
if works_tarball_buildinfo "$tarball" > "$info" && [ -s "$info" ]; then
    works_manifest_write "${WORKS_CHANNEL_PUBLISH:-stable}" "$info" \
        "${WORKS_PUBLISH_AS:-$(basename "$out")}" \
        "$(awk '{print $1}' "$out.sha256")" > dist/manifest.txt
    works_manifest_valid dist/manifest.txt || {
        echo "!! the manifest this build would publish is incomplete:" >&2
        sed 's/^/   /' dist/manifest.txt >&2
        echo "   the runtime's BUILD-INFO is missing a field -- rebuild it" >&2
        exit 1; }
    echo "   manifest: dist/manifest.txt -> ${WORKS_PUBLISH_AS:-$(basename "$out")}"
else
    echo "!! could not read BUILD-INFO out of $(basename "$tarball")" >&2
    exit 1
fi

echo "== [5/5] wrapper self-check =="
sh "$out" --help >/dev/null
echo
echo "OK: $out ($(du -h "$out" | cut -f1))"
echo "Copy it (plus your Ableton installer .exe) to a USB stick and run:"
echo "  sh /run/media/*/*/ableton-wine-setup-${LABEL}.run"
