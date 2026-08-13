#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$root/scripts/check-release-build-info.sh"
tmp="$(mktemp -d /tmp/ableton-release-policy-test.XXXXXX)"
cleanup()
{
    case "$tmp" in
        /tmp/ableton-release-policy-test.*) rm -rf -- "${tmp:?}" ;;
        *) printf 'refusing to remove unexpected test path: %s\n' "$tmp" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

official='pipeasio-sanitizers: ASan+UBSan unit+panel passed (driver imports verified); TSan unit passed'
skipped='pipeasio-sanitizers: ASan+UBSan unit+panel passed (driver imports verified); TSan unit skipped (explicit mode; non-release build)'
source_sha="$(bash "$root/scripts/source-tree-digest.sh")"
cab_hash='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
link_hash='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

fail()
{
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

accepts()
{
    bash "$checker" "$1" >/dev/null 2>&1
}

rejects()
{
    if accepts "$1"; then
        fail "release checker accepted $2"
    fi
}

printf 'dist-version: 2026.08.12.1\nsource-tree: %s\ncabextract-static: %s\nableton-linkd: %s\n%s\n' \
    "$source_sha" "$cab_hash" "$link_hash" "$official" > "$tmp/official"
accepts "$tmp/official" || fail 'exact official sanitizer record was rejected'
if bash "$checker" "$tmp/official" --version 2026.08.12.2 >/dev/null 2>&1; then
    fail 'release checker accepted a BUILD-INFO for a different version'
fi
printf 'ok - exact official sanitizer record is release eligible\n'

printf 'source-tree: %s\ncabextract-static: %s\nableton-linkd: %s\n%s\n' \
    "$source_sha" "$cab_hash" "$link_hash" "$skipped" > "$tmp/skipped"
rejects "$tmp/skipped" 'an explicit non-release TSan skip'

printf 'source-tree: %s\ncabextract-static: %s\nableton-linkd: %s\n%s\n' \
    "$source_sha" "$cab_hash" "$link_hash" \
    'pipeasio-sanitizers: ASan+UBSan unit+panel passed (driver imports verified); TSan unit skipped (host ASLR/seccomp incompatibility; auto mode; non-release build)' \
    > "$tmp/auto"
rejects "$tmp/auto" 'an automatic non-release TSan skip'

printf 'source-tree: %s\ncabextract-static: %s\nableton-linkd: %s\n%s\n%s\n' \
    "$source_sha" "$cab_hash" "$link_hash" "$official" "$official" > "$tmp/duplicate"
rejects "$tmp/duplicate" 'duplicate sanitizer records'

printf 'source-tree: %s\ncabextract-static: %s\nableton-linkd: %s\n%s\n%s\n' \
    "$source_sha" "$cab_hash" "$link_hash" "$official" "$skipped" > "$tmp/mixed"
rejects "$tmp/mixed" 'mixed official and non-release sanitizer records'

printf 'source-tree: %s\ncabextract-static: %s\nableton-linkd: %s\n%s trailing text\n' \
    "$source_sha" "$cab_hash" "$link_hash" "$official" > "$tmp/inexact"
rejects "$tmp/inexact" 'a non-exact official sanitizer record'

: > "$tmp/missing"
rejects "$tmp/missing" 'a missing sanitizer record'
if accepts "$tmp/does-not-exist"; then
    fail 'release checker accepted a missing BUILD-INFO file'
fi
printf 'ok - skipped, duplicate, mixed, malformed, and missing records fail closed\n'

runtime_root="$tmp/runtime/wine-d2d1-nspa-11.13"
mkdir -p -- "$runtime_root"
cp -- "$tmp/official" "$runtime_root/ABLETON-WINE-BUILD-INFO.txt"
tar -C "$tmp/runtime" -I zstd -cf "$tmp/runtime.tar.zst" \
    wine-d2d1-nspa-11.13/ABLETON-WINE-BUILD-INFO.txt
( cd "$tmp" && sha256sum runtime.tar.zst > runtime.tar.zst.sha256 )
bash "$checker" "$tmp/official" --runtime "$tmp/runtime.tar.zst" >/dev/null 2>&1 \
    || fail 'matching official embedded BUILD-INFO was rejected'
cp -- "$tmp/runtime.tar.zst" "$tmp/wrong-name-runtime.tar.zst"
printf '%s  %s\n' "$(sha256sum "$tmp/wrong-name-runtime.tar.zst" | awk '{print $1}')" \
    different-name.tar.zst > "$tmp/wrong-name-runtime.tar.zst.sha256"
if bash "$checker" "$tmp/official" --runtime "$tmp/wrong-name-runtime.tar.zst" \
    >/dev/null 2>&1; then
    fail 'release checker accepted a checksum naming a different artifact'
fi
printf 'dist-version: 2026.08.12.1\nsource-tree: %s\ncabextract-static: %s\nableton-linkd: %s\n%s\n' \
    "$source_sha" "$cab_hash" "$link_hash" "$skipped" \
    > "$runtime_root/ABLETON-WINE-BUILD-INFO.txt"
tar -C "$tmp/runtime" -I zstd -cf "$tmp/skipped-runtime.tar.zst" \
    wine-d2d1-nspa-11.13/ABLETON-WINE-BUILD-INFO.txt
( cd "$tmp" && sha256sum skipped-runtime.tar.zst > skipped-runtime.tar.zst.sha256 )
if bash "$checker" "$tmp/official" --runtime "$tmp/skipped-runtime.tar.zst" >/dev/null 2>&1; then
    fail 'official external BUILD-INFO authorised a runtime with TSan skipped'
fi
printf 'ok - release record must byte-match the runtime-embedded BUILD-INFO\n'

mkdir -p -- "$tmp/kit/dist" "$tmp/kit/scripts"
cp -- "$tmp/official" "$tmp/kit/official"
cp -- "$tmp/runtime.tar.zst" "$tmp/kit/dist/runtime.tar.zst"
cp -- "$tmp/runtime.tar.zst.sha256" "$tmp/kit/dist/runtime.tar.zst.sha256"
cp -- "$root/scripts/installer.sh" "$root/scripts/install.sh" "$tmp/kit/scripts/"
seal_kit()
{
    local source_kit="$1" wrapper="$2" payload digest
    payload="${wrapper%.run}.tar"
    tar --sort=name --owner=0 --group=0 --numeric-owner \
        -cf "$payload" -C "$source_kit" .
    digest="$(sha256sum "$payload" | awk '{print $1}')"
    sed -e 's/@VERSION@/2026.08.12.1/g' -e "s/@PAYLOAD_SHA@/$digest/g" \
        "$root/scripts/setup-run-header.sh" > "$wrapper"
    cat "$payload" >> "$wrapper"
    chmod +x "$wrapper"
}
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "$tmp/payload.tar" -C "$tmp/kit" .
payload_sha="$(sha256sum "$tmp/payload.tar" | awk '{print $1}')"
sed -e 's/@VERSION@/2026.08.12.1/g' -e "s/@PAYLOAD_SHA@/$payload_sha/g" \
    "$root/scripts/setup-run-header.sh" > "$tmp/installer.run"
cat "$tmp/payload.tar" >> "$tmp/installer.run"
chmod +x "$tmp/installer.run"
bash "$checker" "$tmp/official" --version 2026.08.12.1 \
    --runtime "$tmp/runtime.tar.zst" --installer "$tmp/installer.run" \
    --expected-kit "$tmp/kit" \
    >/dev/null 2>&1 || fail 'matching installer payload was rejected'

cp -- "$tmp/payload.tar" "$tmp/nonzero-tail.tar"
payload_size="$(wc -c < "$tmp/nonzero-tail.tar")"
printf X | dd of="$tmp/nonzero-tail.tar" bs=1 seek="$((payload_size - 1))" \
    conv=notrunc status=none
nonzero_tail_sha="$(sha256sum "$tmp/nonzero-tail.tar" | awk '{print $1}')"
sed -e 's/@VERSION@/2026.08.12.1/g' -e "s/@PAYLOAD_SHA@/$nonzero_tail_sha/g" \
    "$root/scripts/setup-run-header.sh" > "$tmp/nonzero-tail.run"
cat "$tmp/nonzero-tail.tar" >> "$tmp/nonzero-tail.run"
if bash "$checker" "$tmp/official" --version 2026.08.12.1 \
    --runtime "$tmp/runtime.tar.zst" --installer "$tmp/nonzero-tail.run" \
    --expected-kit "$tmp/kit" >/dev/null 2>&1; then
    fail 'release checker accepted non-zero data after the canonical tar EOF'
fi

cp -a -- "$tmp/kit" "$tmp/tampered-kit"
printf '\n# changed after the tag\n' >> "$tmp/tampered-kit/scripts/install.sh"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "$tmp/tampered-payload.tar" -C "$tmp/tampered-kit" .
tampered_sha="$(sha256sum "$tmp/tampered-payload.tar" | awk '{print $1}')"
sed -e 's/@VERSION@/2026.08.12.1/g' -e "s/@PAYLOAD_SHA@/$tampered_sha/g" \
    "$root/scripts/setup-run-header.sh" > "$tmp/tampered-installer.run"
cat "$tmp/tampered-payload.tar" >> "$tmp/tampered-installer.run"
if bash "$checker" "$tmp/official" --version 2026.08.12.1 \
    --runtime "$tmp/runtime.tar.zst" --installer "$tmp/tampered-installer.run" \
    --expected-kit "$tmp/kit" >/dev/null 2>&1; then
    fail 'release checker accepted a stale packaged install script'
fi

executed="$tmp/candidate-was-executed"
{
    printf '#!/bin/sh\ntouch %q\n' "$executed"
    tail -n +2 "$tmp/installer.run"
} > "$tmp/hostile-header.run"
if bash "$checker" "$tmp/official" --version 2026.08.12.1 \
    --runtime "$tmp/runtime.tar.zst" --installer "$tmp/hostile-header.run" \
    --expected-kit "$tmp/kit" >/dev/null 2>&1; then
    fail 'release checker accepted a modified installer transport'
fi
[ ! -e "$executed" ] || fail 'release checker executed an installer candidate'

cp -a -- "$tmp/kit" "$tmp/extra-kit"
printf 'not part of the release kit\n' > "$tmp/extra-kit/unexpected.txt"
seal_kit "$tmp/extra-kit" "$tmp/extra-installer.run"
if bash "$checker" "$tmp/official" --version 2026.08.12.1 \
    --runtime "$tmp/runtime.tar.zst" --installer "$tmp/extra-installer.run" \
    --expected-kit "$tmp/kit" >/dev/null 2>&1; then
    fail 'release checker accepted an extra payload member'
fi

cp -a -- "$tmp/kit" "$tmp/symlink-kit"
rm -- "$tmp/symlink-kit/official"
ln -s -- "$tmp/official" "$tmp/symlink-kit/official"
seal_kit "$tmp/symlink-kit" "$tmp/symlink-installer.run"
if bash "$checker" "$tmp/official" --version 2026.08.12.1 \
    --runtime "$tmp/runtime.tar.zst" --installer "$tmp/symlink-installer.run" \
    --expected-kit "$tmp/kit" >/dev/null 2>&1; then
    fail 'release checker accepted an external symlink in the payload'
fi
printf 'ok - installer verification binds staged source and never executes the candidate\n'

cp -- "$tmp/skipped-runtime.tar.zst" "$tmp/kit/dist/runtime.tar.zst"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "$tmp/mixed-payload.tar" -C "$tmp/kit" .
mixed_payload_sha="$(sha256sum "$tmp/mixed-payload.tar" | awk '{print $1}')"
sed -e 's/@VERSION@/2026.08.12.1/g' -e "s/@PAYLOAD_SHA@/$mixed_payload_sha/g" \
    "$root/scripts/setup-run-header.sh" > "$tmp/mixed-installer.run"
cat "$tmp/mixed-payload.tar" >> "$tmp/mixed-installer.run"
chmod +x "$tmp/mixed-installer.run"
if bash "$checker" "$tmp/official" --version 2026.08.12.1 \
    --runtime "$tmp/runtime.tar.zst" --installer "$tmp/mixed-installer.run" \
    --expected-kit "$tmp/kit" \
    >/dev/null 2>&1; then
    fail 'release checker accepted an installer carrying a different runtime'
fi
printf 'ok - installer payload must carry the exact release record and runtime\n'

grep -qF '    --version "$VERSION" --runtime "$tarball" --installer "$out"' \
    "$root/scripts/make-installer.sh" \
    || fail 'make-installer.sh does not bind the wrapper to its release inputs'
grep -qF '    --version "$VERSION" --runtime "$tarball" --installer "$run"' \
    "$root/scripts/release.sh" \
    || fail 'release.sh does not bind the wrapper to its release inputs'
grep -qF 'bash scripts/check-release-build-info.sh "dist/BUILD-INFO-$ver.txt" \' \
    "$root/.github/workflows/release.yml" \
    || fail 'release workflow does not enforce the release BUILD-INFO gate'
grep -qF 'bash "$GITHUB_WORKSPACE/scripts/check-release-build-info.sh" "BUILD-INFO-$ver.txt" \' \
    "$root/.github/workflows/release.yml" \
    || fail 'published-asset verification does not bind BUILD-INFO to the runtime'
grep -qF -- '--runtime "wine-d2d1-nspa-11.13-$ver.tar.zst" \' \
    "$root/.github/workflows/release.yml" \
    || fail 'published-asset verification omits the standalone runtime'
grep -qF -- '--installer "ableton-wine-setup-$ver.run"' \
    "$root/.github/workflows/release.yml" \
    || fail 'published-asset verification omits the installer wrapper'
if grep -qE 'sh .*ableton-wine-setup.*\.run.*extract' "$root/.github/workflows/release.yml"; then
    fail 'published-asset verification executes the untrusted installer candidate'
fi
grep -qF './scripts/make-installer.sh' "$root/scripts/release.sh" \
    || fail 'release.sh does not regenerate the installer from the tagged candidate'
grep -qF 'require_exact_assets' "$root/scripts/release.sh" \
    || fail 'release.sh does not require the exact draft asset set'
grep -qF 'download_asset "$asset_name"' "$root/scripts/release.sh" \
    || fail 'release.sh does not compare the uploaded draft assets before publication'
grep -qF 'bash scripts/build-audit.sh "$tarball"' "$root/scripts/release.sh" \
    || fail 'release.sh does not rerun the runtime patch audit before tagging'
grep -qF 'git ls-files --error-unmatch "$info" "$tarball.sha256"' \
    "$root/scripts/release.sh" \
    || fail 'release.sh does not require the runtime checksum in the tagged source'
grep -qF '"$GITHUB_WORKSPACE/dist/wine-d2d1-nspa-11.13-$ver.tar.zst.sha256"' \
    "$root/.github/workflows/release.yml" \
    || fail 'published verification does not compare the checksum with the tagged record'
grep -qF "git status --porcelain --untracked-files=all -- . ':(exclude)dist'" \
    "$root/scripts/release.sh" \
    || fail 'release.sh does not reject source changes outside dist/'
grep -qF 'release_commit="$(git rev-parse --verify HEAD)"' \
    "$root/scripts/release.sh" \
    || fail 'release.sh does not capture the commit before preflight'
grep -qF '[ "$(git rev-parse --verify HEAD)" = "$release_commit" ]' \
    "$root/scripts/release.sh" \
    || fail 'release.sh does not reject HEAD changes during preflight'
grep -qF 'git tag -a "$TAG" -m "$VERSION" "$release_commit"' \
    "$root/scripts/release.sh" \
    || fail 'release.sh does not tag the captured commit explicitly'
grep -qF '[ "$release_commit" = "$(git rev-list -n 1 "$TAG")" ]' \
    "$root/scripts/release.sh" \
    || fail 'release.sh does not require the version tag to point at the verified commit'
[ "$(grep -c '^require_draft_release$' "$root/scripts/release.sh")" -eq 2 ] \
    || fail 'release.sh does not require a draft before upload and publication'
printf 'ok - installer packing, tagging, and release drafting share the gate\n'

series_checker="$root/scripts/build-audit.sh"
series="$root/patches/SERIES.sha256"
removals() { bash "$series_checker" --check-series-removals "$1" "$2" >/dev/null 2>&1; }

wine_tail="$(awk '$2 !~ /^pipeasio\// { print $2 }' "$series" | sort | tail -1)"
wine_tail_hash="$(awk -v f="$wine_tail" '$2 == f { print $1 }' "$series")"
wine_tail_suffix="${wine_tail#[0-9][0-9][0-9][0-9]-}"

removals "$series" "$series" \
    || fail 'series policy reported a removal between a manifest and itself'

# An added patch is not a removal, and each way of altering an existing entry
# leaves one of the three links back to it: name, sha256, or the suffix.
{ cat "$series"; echo "$wine_tail_hash  0999-a-patch-that-was-added.patch"; } > "$tmp/added"
removals "$series" "$tmp/added" || fail 'series policy rejected an added patch'

sed "s|^$wine_tail_hash |0000000000000000000000000000000000000000000000000000000000000000 |" \
    "$series" > "$tmp/edited"
removals "$series" "$tmp/edited" || fail 'series policy rejected an edited patch'

sed "s|  $wine_tail\$|  0098-$wine_tail_suffix|" "$series" > "$tmp/renumbered"
removals "$series" "$tmp/renumbered" || fail 'series policy rejected a renumbered patch'

sed -e "s|^$wine_tail_hash |0000000000000000000000000000000000000000000000000000000000000000 |" \
    -e "s|  $wine_tail\$|  0098-$wine_tail_suffix|" "$series" > "$tmp/renumbered-edited"
removals "$series" "$tmp/renumbered-edited" \
    || fail 'series policy rejected a patch renumbered and edited at once'

# The number sits after the directory in a pipeasio/ entry, so the suffix has to
# be taken from the basename or this series loses the renumbered-and-edited case.
pipeasio_tail="$(awk '$2 ~ /^pipeasio\// { print $2 }' "$series" | sort | tail -1)"
pipeasio_tail_hash="$(awk -v f="$pipeasio_tail" '$2 == f { print $1 }' "$series")"
sed -e "s|^$pipeasio_tail_hash |0000000000000000000000000000000000000000000000000000000000000000 |" \
    -e "s|  $pipeasio_tail\$|  pipeasio/0099-${pipeasio_tail#pipeasio/[0-9][0-9][0-9][0-9]-}|" \
    "$series" > "$tmp/pipeasio-renumbered-edited"
removals "$series" "$tmp/pipeasio-renumbered-edited" \
    || fail 'series policy rejected a PipeASIO patch renumbered and edited at once'

grep -v "  $wine_tail\$" "$series" > "$tmp/dropped"
if removals "$series" "$tmp/dropped"; then
    fail 'series policy accepted a patch that left the series'
fi

# An empty new manifest must report every patch, and an unreadable one must stop
# the run — both are cases where a naive reader reports nothing and passes.
: > "$tmp/empty-manifest"
if removals "$series" "$tmp/empty-manifest"; then
    fail 'series policy accepted a manifest that lost every patch'
fi
if removals "$series" "$tmp"; then
    fail 'series policy passed on a manifest it could not read'
fi

grep -v '  pipeasio/' "$series" > "$tmp/no-pipeasio-series"
if removals "$series" "$tmp/no-pipeasio-series"; then
    fail 'series policy accepted an emptied PipeASIO series'
fi

# Each series has its own gap table: 0027 is documented in one, pipeasio/0003
# in the other, so removing either needs no further reason.
{ echo "$wine_tail_hash  0027-a-retired-patch.patch"; cat "$series"; } > "$tmp/with-gap"
removals "$tmp/with-gap" "$series" \
    || fail 'series policy rejected the removal of a documented gap number'

{ echo "$wine_tail_hash  pipeasio/0003-a-retired-patch.patch"; cat "$series"; } \
    > "$tmp/with-pipeasio-gap"
removals "$tmp/with-pipeasio-gap" "$series" \
    || fail 'series policy rejected the removal of a documented PipeASIO gap number'
printf 'ok - patch series cannot lose a patch without a documented reason\n'

# --freeze writes patches/SERIES.sha256 next to the script it runs from, so it is
# exercised against a copy of patches/ and never rewrites the repo's manifest.
mkdir -p "$tmp/freeze/scripts"
cp -a "$root/patches" "$tmp/freeze/patches"
cp -a "$series_checker" "$tmp/freeze/scripts/build-audit.sh"
freeze_checker="$tmp/freeze/scripts/build-audit.sh"
bash "$freeze_checker" --freeze >/dev/null \
    || fail '--freeze cannot regenerate the series manifest'
cmp -s "$tmp/freeze/patches/SERIES.sha256" "$series" \
    || fail '--freeze regenerated a manifest that differs from the committed one'
printf 'ok - --freeze regenerates the committed manifest\n'

# A renumbered patch freezes without comment; a deleted one needs the reason flag.
mv "$tmp/freeze/patches/$wine_tail" "$tmp/freeze/patches/0098-$wine_tail_suffix"
bash "$freeze_checker" --freeze >/dev/null \
    || fail '--freeze refused to record a renumbered patch'

rm -f "$tmp/freeze/patches/0098-$wine_tail_suffix"
if bash "$freeze_checker" --freeze >/dev/null 2>&1; then
    fail '--freeze recorded a deleted patch without a reason'
fi
bash "$freeze_checker" --freeze --allow-series-removals 'test fixture' >/dev/null \
    || fail '--allow-series-removals did not permit a documented removal'
if grep -qF "  $wine_tail" "$tmp/freeze/patches/SERIES.sha256"; then
    fail '--freeze kept a deleted patch in the manifest'
fi
printf 'ok - --freeze records a renumber and stops on an undocumented deletion\n'
