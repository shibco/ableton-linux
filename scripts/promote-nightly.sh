#!/usr/bin/env bash
# Promote a nightly runtime tarball into release form, without rebuilding.
#
#   ./scripts/promote-nightly.sh dist/wine-…-2026.08.06.1+nightly.79d8960.tar.zst [2026.08.09.1]
#
# The version defaults to the committed VERSION. What comes out, in dist/:
#   <name>-<version>.tar.zst (+ .sha256)   the same bits under the release name
#   BUILD-INFO-<version>.txt               the restamped identity, ready to commit
#   BUILD-INFO.txt                         same content, where make-installer reads it
#
# A nightly and the release promoted from it are the same build in every sense
# the store cares about: source-commit and built-at are carried through
# unchanged, so the updater still recognises it and the audit still fingerprints
# it. What changes is the name: dist-version becomes the release version,
# build-kind is dropped (that is what makes it a release), and promoted-from
# records the identity it shipped under first. Only Wine bits survive verbatim -
# rewriting BUILD-INFO changes the tarball's checksum, which is why the .sha256
# is regenerated rather than copied.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

# Runtime naming and the tarball predicate resolve in one place; see
# scripts/runtime-env.sh.
# shellcheck source=scripts/runtime-env.sh
. "$here/runtime-env.sh"

src="${1:?usage: promote-nightly.sh <nightly-tarball> [version]}"
VERSION="${2:-$(cat "$root/VERSION")}"
NAME="$(works_runtime_name)"

[ -f "$src" ] || { echo "!! no such tarball: $src" >&2; exit 1; }
works_is_runtime_tarball "$src" \
    || { echo "!! not a runtime tarball this repo would select: ${src##*/}" >&2; exit 1; }
case "${src##*/}" in
    *+*) ;;
    *) echo "!! ${src##*/} carries no +<label>: it is already a release, nothing to promote" >&2; exit 1 ;;
esac
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] \
    || { echo "!! not a dated release version: $VERSION" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== unpack ${src##*/} =="
zstd -dc --long=27 "$src" | tar -x -C "$work"
[ -d "$work/$NAME" ] || { echo "!! tarball does not unpack to a single $NAME/ tree" >&2; exit 1; }
info="$work/$NAME/ABLETON-WINE-BUILD-INFO.txt"
[ -f "$info" ] || { echo "!! no ABLETON-WINE-BUILD-INFO.txt inside the tarball" >&2; exit 1; }

# The fields promotion depends on. A tarball without identity cannot be
# promoted - there would be nothing tying the release back to the build that
# soaked, which is the entire point of promoting instead of rebuilding.
commit="$(works_buildinfo_field "$info" source-commit)"
built="$(works_buildinfo_field "$info" built-at)"
kind="$(works_buildinfo_field "$info" build-kind)"
olddist="$(works_buildinfo_field "$info" dist-version)"
[ -n "$commit" ] && [ "$commit" != unknown ] \
    || { echo "!! BUILD-INFO carries no source-commit; promote needs the identity" >&2; exit 1; }
[ -n "$built" ] || { echo "!! BUILD-INFO carries no built-at" >&2; exit 1; }
[ -n "$kind" ] \
    || { echo "!! BUILD-INFO carries no build-kind: this is already a release build" >&2; exit 1; }

echo "== restamp $olddist ($kind, ${commit:0:7}) -> $VERSION =="
sed -i \
    -e "s/^dist-version:.*/dist-version:  $VERSION/" \
    -e "/^build-kind:/d" \
    "$info"
printf 'promoted-from: %s+%s.%s\n' "$olddist" "$kind" "${commit:0:7}" >> "$info"

# A seam for the tests: a fake tarball left behind in the real dist/ would win
# a later selector pick. Everything else writes where a release expects it.
dest="${WORKS_PROMOTE_DEST:-dist}"
out="$dest/$NAME-$VERSION.tar.zst"
mkdir -p "$dest"
echo "== repack -> $out =="
# Same invocation as container-build.sh: --long=27 stays inside zstd's default
# decode window, so nothing special is needed to unpack it.
tar -C "$work" -c "$NAME" | zstd -T0 -19 --long=27 -q -f -o "$out"
( cd "$dest" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
cp "$info" "$dest/BUILD-INFO-$VERSION.txt"
cp "$info" "$dest/BUILD-INFO.txt"

echo "== promoted =="
echo "   $olddist+$kind.${commit:0:7}  ->  $VERSION+${commit:0:7}"
echo "   next: WORKS_RUNTIME_TARBALL=$out ./scripts/make-installer.sh"
