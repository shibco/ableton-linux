#!/usr/bin/env bash
# Publish the current VERSION as a GitHub release.
#
#   GH_TOKEN=<fine-grained PAT, contents read/write> ./scripts/release.sh
#
# Verifies the locally built dist/ artifacts, pushes the v<VERSION> tag (the
# release workflow then drafts the release with notes from BUILD-INFO),
# uploads the assets, and publishes. Alongside the versioned installer it
# uploads a stable-named copy, install-ableton-latest.run, so
#   https://github.com/<repo>/releases/latest/download/install-ableton-latest.run
# always serves the newest build. CI never rebuilds Wine; the bits released
# are the bits verified here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

NAME="wine-d2d1-nspa-11.13"
VERSION="$(cat VERSION)"
TAG="v$VERSION"
run="dist/ableton-wine-setup-${VERSION}.run"
tarball="dist/${NAME}-${VERSION}.tar.zst"
info="dist/BUILD-INFO-${VERSION}.txt"

command -v jq >/dev/null || { echo "!! jq is required" >&2; exit 1; }
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$token" ] || { echo "!! set GH_TOKEN (fine-grained PAT with contents read/write)" >&2; exit 1; }
repo="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
api="https://api.github.com/repos/$repo"
gh_api() { curl -fsS -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "$@"; }

echo "== [0/4] verify the $VERSION artifacts =="
for f in "$run" "$run.sha256" "$tarball" "$tarball.sha256" "$info"; do
    [ -f "$f" ] || { echo "!! missing $f — run ./build.sh and ./scripts/make-installer.sh first" >&2; exit 1; }
done
( cd dist && sha256sum -c "$(basename "$run").sha256" "$(basename "$tarball").sha256" )
sh "$run" --help >/dev/null
git ls-files --error-unmatch "$info" >/dev/null 2>&1 \
    || { echo "!! $info is not committed — the release workflow needs it at the tag" >&2; exit 1; }
git diff --quiet HEAD -- VERSION "$info" \
    || { echo "!! VERSION or $info has uncommitted changes — commit them first" >&2; exit 1; }

echo "== [1/4] push tag $TAG =="
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "$VERSION"
git push origin "$TAG"

echo "== [2/4] wait for the draft release (created by the release workflow) =="
rid=""
for _ in $(seq 1 30); do
    rid="$(gh_api "$api/releases?per_page=30" \
        | jq -r --arg t "$TAG" '.[] | select(.tag_name == $t) | .id' | head -1)"
    [ -n "$rid" ] && break
    sleep 5
done
[ -n "$rid" ] || { echo "!! no release for $TAG after 150s — check the repo's Actions tab, then rerun" >&2; exit 1; }

echo "== [3/4] upload assets =="
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$run" "$stage/install-ableton-latest.run"
( cd "$stage" && sha256sum install-ableton-latest.run > install-ableton-latest.run.sha256 )

upload() {
    local f="$1" name old
    name="$(basename "$f")"
    # replace a leftover asset of the same name from an earlier attempt
    old="$(gh_api "$api/releases/$rid/assets?per_page=100" \
        | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1)"
    [ -z "$old" ] || gh_api -X DELETE "$api/releases/assets/$old"
    echo "   $name"
    gh_api -X POST -H "Content-Type: application/octet-stream" --data-binary "@$f" \
        "https://uploads.github.com/repos/$repo/releases/$rid/assets?name=$name" >/dev/null
}
for f in "$run" "$run.sha256" "$tarball" "$tarball.sha256" "$info" \
         "$stage/install-ableton-latest.run" "$stage/install-ableton-latest.run.sha256"; do
    upload "$f"
done

echo "== [4/4] publish =="
gh_api -X PATCH "$api/releases/$rid" -d '{"draft": false}' >/dev/null
echo
echo "OK: https://github.com/$repo/releases/tag/$TAG"
echo "Latest installer: https://github.com/$repo/releases/latest/download/install-ableton-latest.run"
