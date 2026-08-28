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

set +e
(
    set +o pipefail
    config_lib="$root/scripts/lib/config.sh"
    # shellcheck disable=SC1090
    . "$config_lib"
    export ABLETON_CONFIG_FILE="$tmp/missing-config" \
        ABLETON_WINE_ROOT="$tmp/runtime-root" ABLETON_WINEPREFIX="$tmp/prefix" \
        ABLETON_LINKD="$tmp/linkd" ABLETON_LINK_MODE=off \
        ABLETON_DATA_HOME="$tmp/data" ABLETON_CONFIG_HOME="$tmp/config" \
        ABLETON_STATE_HOME="$tmp/state" ABLETON_CACHE_HOME="$tmp/cache" \
        ABLETON_BIN_HOME="$tmp/bin"
    sha256sum() { return 91; }
    ableton_config_snapshot_capture absent
)
snapshot_rc=$?
set -e
[ "$snapshot_rc" -eq 1 ] \
    || fail "configuration snapshot capture returned $snapshot_rc for a value-hash failure without pipefail"
set +e
(
    set +o pipefail
    config_lib="$root/scripts/lib/config.sh"
    # shellcheck disable=SC1090
    . "$config_lib"
    export ABLETON_CONFIG_FILE="$tmp/missing-config" \
        ABLETON_WINE_ROOT="$tmp/runtime-root" ABLETON_WINEPREFIX="$tmp/prefix" \
        ABLETON_LINKD="$tmp/linkd" ABLETON_LINK_MODE=off \
        ABLETON_DATA_HOME="$tmp/data" ABLETON_CONFIG_HOME="$tmp/config" \
        ABLETON_STATE_HOME="$tmp/state" ABLETON_CACHE_HOME="$tmp/cache" \
        ABLETON_BIN_HOME="$tmp/bin"
    ableton_config_snapshot_capture absent || exit 90
    sha256sum() { return 91; }
    ableton_config_snapshot_verify
)
snapshot_rc=$?
set -e
[ "$snapshot_rc" -eq 1 ] \
    || fail "configuration snapshot verification returned $snapshot_rc for a value-hash failure without pipefail"
printf 'ok - configuration snapshot hash failures propagate without caller pipefail\n'

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
    "$root/scripts/make-installer.sh" --render-header --version 2026.08.12.1 --payload-sha $digest > "$wrapper"
    cat "$payload" >> "$wrapper"
    chmod +x "$wrapper"
}

cleanup_kit="$tmp/cleanup-kit"
mkdir -p -- "$cleanup_kit/scripts" "$tmp/failing-rm" "$tmp/wrapper-tmp"
cat > "$cleanup_kit/scripts/installer.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installer child reached status %s\n' "${WRAPPER_TEST_STATUS:-0}"
exit "${WRAPPER_TEST_STATUS:-0}"
EOF
chmod +x "$cleanup_kit/scripts/installer.sh"
seal_kit "$cleanup_kit" "$tmp/cleanup-status.run"
cat > "$tmp/failing-rm/rm" <<'EOF'
#!/usr/bin/env bash
target=""
for target in "$@"; do :; done
case "$target" in
    "$WRAPPER_TEST_TMP"/ableton-installer.*) exit 91 ;;
esac
exec /bin/rm "$@"
EOF
chmod +x "$tmp/failing-rm/rm"

set +e
PATH="$tmp/failing-rm:$PATH" TMPDIR="$tmp/wrapper-tmp" \
    WRAPPER_TEST_TMP="$tmp/wrapper-tmp" WRAPPER_TEST_STATUS=0 \
    bash "$tmp/cleanup-status.run" > "$tmp/cleanup-zero.out" 2>&1
cleanup_rc=$?
set -e
[ "$cleanup_rc" -eq 0 ] \
    || fail "installer wrapper changed child status 0 to $cleanup_rc after scratch cleanup failed"
# The wrapper keeps the screen for the renderer; what the child and the
# wrapper print raw goes to the log beside the .run (rule D1).
newest_log() { ls -t "$tmp"/ableton-linux-installer-*.log 2>/dev/null | head -n 1; }
grep -qF 'installer child reached status 0' "$(newest_log)" \
    || fail 'installer wrapper did not reach its child after early scratch cleanup failed'
grep -qF 'The installer finished, but temporary files remain at' "$(newest_log)" \
    || fail 'installer wrapper did not name retained scratch after cleanup failed'
grep -q '│ Complete │' "$tmp/cleanup-zero.out" \
    || fail 'installer wrapper did not report a completed run after cleanup failed'

set +e
PATH="$tmp/failing-rm:$PATH" TMPDIR="$tmp/wrapper-tmp" \
    WRAPPER_TEST_TMP="$tmp/wrapper-tmp" WRAPPER_TEST_STATUS=37 \
    bash "$tmp/cleanup-status.run" > "$tmp/cleanup-nonzero.out" 2>&1
cleanup_rc=$?
set -e
[ "$cleanup_rc" -eq 37 ] \
    || fail "installer wrapper changed child status 37 to $cleanup_rc after scratch cleanup failed"
grep -qF 'installer child reached status 37' "$(newest_log)" \
    || fail 'installer wrapper did not preserve the failing child execution path'
grep -q '│   Failed │' "$tmp/cleanup-nonzero.out" \
    || fail 'installer wrapper did not report the failed run'
printf 'ok - installer wrapper scratch cleanup is warning-only and preserves child status\n'

tar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "$tmp/payload.tar" -C "$tmp/kit" .
payload_sha="$(sha256sum "$tmp/payload.tar" | awk '{print $1}')"
"$root/scripts/make-installer.sh" --render-header --version 2026.08.12.1 --payload-sha $payload_sha > "$tmp/installer.run"
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
"$root/scripts/make-installer.sh" --render-header --version 2026.08.12.1 --payload-sha $nonzero_tail_sha > "$tmp/nonzero-tail.run"
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
"$root/scripts/make-installer.sh" --render-header --version 2026.08.12.1 --payload-sha $tampered_sha > "$tmp/tampered-installer.run"
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
"$root/scripts/make-installer.sh" --render-header --version 2026.08.12.1 --payload-sha $mixed_payload_sha > "$tmp/mixed-installer.run"
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
bash "$series_checker" --check-series-policy "$series" >/dev/null \
    || fail 'complete patch series failed its terminal-member policy'

# Read the terminal members off the manifest rather than naming them: the
# policy pins whichever patch currently ends each series, so a hardcoded name
# turns into a failing negative test the next time either series grows.
wine_tail="$(awk '$2 !~ /^(pipeasio|performance)\// { print $2 }' "$series" | sort | tail -1)"
pipeasio_tail="$(awk '$2 ~ /^pipeasio\// { print $2 }' "$series" | sort | tail -1)"

grep -v "  $wine_tail\$" \
    "$series" > "$tmp/no-wine-tail"
if bash "$series_checker" --check-series-policy "$tmp/no-wine-tail" >/dev/null 2>&1; then
    fail 'series policy accepted a missing final Wine patch'
fi

grep -v "  $pipeasio_tail\$" \
    "$series" > "$tmp/no-pipeasio-tail"
if bash "$series_checker" --check-series-policy "$tmp/no-pipeasio-tail" >/dev/null 2>&1; then
    fail 'series policy accepted a missing final PipeASIO patch'
fi

grep -v '  pipeasio/' "$series" > "$tmp/no-pipeasio-series"
if bash "$series_checker" --check-series-policy "$tmp/no-pipeasio-series" >/dev/null 2>&1; then
    fail 'series policy accepted an empty PipeASIO series'
fi

while read -r performance_member; do
    grep -v "  $performance_member\$" "$series" > "$tmp/no-performance-member"
    if bash "$series_checker" --check-series-policy "$tmp/no-performance-member" >/dev/null 2>&1; then
        fail "series policy accepted missing reviewed performance member $performance_member"
    fi
done < <(awk '$2 ~ /^performance\// { print $2 }' "$series")

grep -v '  performance/' "$series" > "$tmp/no-performance-series"
if bash "$series_checker" --check-series-policy "$tmp/no-performance-series" >/dev/null 2>&1; then
    fail 'series policy accepted an empty performance series'
fi

cp "$series" "$tmp/extra-performance-member"
printf '%064d  performance/0002-unreviewed.patch\n' 0 >> "$tmp/extra-performance-member"
if bash "$series_checker" --check-series-policy "$tmp/extra-performance-member" >/dev/null 2>&1; then
    fail 'series policy accepted an unreviewed performance member'
fi
printf 'ok - patch series pins required Wine/PipeASIO tails and the exact bounded-performance set\n'
