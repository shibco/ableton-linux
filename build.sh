#!/usr/bin/env bash
#
#   ./build.sh                # build the runtime and Link helper with Podman
#   JOBS=8 ./build.sh         # limit parallelism
#   INSTALL_PREFIX=/target/path/wine-d2d1-nspa-11.13 ./build.sh
#                             # strict path-identity build; normally unnecessary
#                             # the tarball self-locates (relocation gate proves it)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ableton-wine-build:22.04}"
JOBS="${JOBS:-$(nproc)}"
# Default auto; see scripts/container-build.sh for why releases stay fail-closed
# without it. CI sets require explicitly.
PIPEASIO_TSAN_MODE="${PIPEASIO_TSAN_MODE:-skip}"
# shellcheck source=scripts/lib/tsan.sh
source "$here/scripts/lib/tsan.sh"
pipeasio_tsan_mode_valid "$PIPEASIO_TSAN_MODE" || {
    echo "!! PIPEASIO_TSAN_MODE must be require, auto, or skip" >&2
    exit 2
}
# Wine locates bin/ -> lib/wine -> share/wine relative to the running binary.
# One tarball can serve any user and any $HOME. 
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/wine-d2d1-nspa-11.13}"
VERSION="$(cat VERSION)"

command -v "$ENGINE" >/dev/null || {
    echo "!! Podman command '$ENGINE' not found; install Podman or set ENGINE" >&2
    exit 1
}

source_paths="$(mktemp /tmp/ableton-source-paths.XXXXXX)"
source_snapshot="$(mktemp -d /tmp/ableton-source-snapshot.XXXXXX)"
output_stage="$(mktemp -d /tmp/ableton-build-output.XXXXXX)"
promotion_stage=""
cleanup_build_stages()
{
    if [ -n "$promotion_stage" ]; then
        case "$promotion_stage" in
            "$here"/dist/.promote.*)
                rm -rf -- "${promotion_stage:?}"
                ;;
            *) echo "!! refusing to remove unexpected promotion path: $promotion_stage" >&2 ;;
        esac
    fi
    case "$source_snapshot" in
        /tmp/ableton-source-snapshot.*)
            chmod -R u+w -- "$source_snapshot" 2>/dev/null || true
            rm -rf -- "${source_snapshot:?}"
            ;;
        *) echo "!! refusing to remove unexpected source snapshot: $source_snapshot" >&2 ;;
    esac
    case "$output_stage" in
        /tmp/ableton-build-output.*) rm -rf -- "${output_stage:?}" ;;
        *) echo "!! refusing to remove unexpected output stage: $output_stage" >&2 ;;
    esac
    case "$source_paths" in
        /tmp/ableton-source-paths.*) rm -f -- "${source_paths:?}" ;;
        *) echo "!! refusing to remove unexpected source path list: $source_paths" >&2 ;;
    esac
}
trap cleanup_build_stages EXIT

echo "== [0/7] freeze the current source candidate =="
git ls-files -z --cached --others --exclude-standard -- . ':(exclude)dist' \
    | sort -z > "$source_paths"
while IFS= read -r -d '' path; do
    case "$path" in
        ''|.|/*|../*|*/../*|*/..)
            echo "!! unsafe source path: $path" >&2
            exit 1
            ;;
    esac
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] || [ -L "$path" ] || {
        echo "!! unsupported source file type: $path" >&2
        exit 1
    }
    destination="$source_snapshot/$path"
    case "$path" in
        */*) mkdir -p -- "$source_snapshot/${path%/*}" ;;
    esac
    if [ -L "$path" ]; then
        cp -P -- "$path" "$destination"
    else
        source_mode=644
        [ -x "$path" ] && source_mode=755
        install -m "$source_mode" "$path" "$destination"
    fi
done < "$source_paths"

SOURCE_TREE_SHA="$(
    bash "$source_snapshot/scripts/source-tree-digest.sh" \
        --root "$source_snapshot" --paths-from "$source_paths"
)"
SOURCE_TREE_SHA_LIVE="$(
    bash "$source_snapshot/scripts/source-tree-digest.sh" --root "$here"
)"
[[ "$SOURCE_TREE_SHA" =~ ^[0-9a-f]{64}$ ]] \
    && [ "$SOURCE_TREE_SHA_LIVE" = "$SOURCE_TREE_SHA" ] || {
    echo "!! source changed while its immutable snapshot was being made; run the build again" >&2
    echo "!! snapshot=$SOURCE_TREE_SHA current=$SOURCE_TREE_SHA_LIVE" >&2
    exit 1
}
chmod -R a-w -- "$source_snapshot"
echo "   source-tree: $SOURCE_TREE_SHA"

echo "== [1/7] verify vendored inputs against pinned checksums =="
( cd "$source_snapshot/vendor" && sha256sum -c wine-base.sha256 pipeasio.sha256 \
    pipewire-sdk.sha256 ntsync-uapi.sha256 link.sha256 cabextract.sha256 \
    bitstream-vera.sha256 llvm-apt-key.sha256 )

echo "== [2/7] build container image ($IMAGE) =="
"$ENGINE" build -t "$IMAGE" -f "$source_snapshot/Containerfile" "$source_snapshot" --platform linux/arm64

mkdir -p dist "$here/.ccache"
echo "== [3/7] build installer helpers in the configured image =="
ENGINE="$ENGINE" IMAGE="$IMAGE" \
    "$source_snapshot/scripts/build-cabextract-static.sh" \
    "$output_stage/cabextract-static"
ENGINE="$ENGINE" IMAGE="$IMAGE" \
    "$source_snapshot/scripts/build-ableton-linkd.sh" \
    "$output_stage/ableton-linkd"
CABEXTRACT_STATIC_SHA="$(sha256sum "$output_stage/cabextract-static" | awk '{print $1}')"
ABLETON_LINKD_SHA="$(sha256sum "$output_stage/ableton-linkd" | awk '{print $1}')"

echo "== [4/7] build Wine + PipeASIO in the container (JOBS=$JOBS) =="
relabel=""
if [ -f /sys/fs/selinux/enforce ]; then relabel=",Z"; fi
"$ENGINE" run --rm \
    -v "$source_snapshot:/src:ro$relabel" \
    -v "$output_stage:/out:rw$relabel" \
    -v "$here/.ccache:/ccache:rw$relabel" \
    -e JOBS="$JOBS" \
    -e PIPEASIO_TSAN_MODE="$PIPEASIO_TSAN_MODE" \
    -e SOURCE_TREE_SHA="$SOURCE_TREE_SHA" \
    -e CABEXTRACT_STATIC_SHA="$CABEXTRACT_STATIC_SHA" \
    -e ABLETON_LINKD_SHA="$ABLETON_LINKD_SHA" \
    -e "INSTALL_PREFIX=$INSTALL_PREFIX" \
    "$IMAGE" \
    /src/scripts/container-build.sh

SOURCE_TREE_SHA_AFTER="$(
    bash "$source_snapshot/scripts/source-tree-digest.sh" --root "$here"
)"
[ "$SOURCE_TREE_SHA_AFTER" = "$SOURCE_TREE_SHA" ] || {
    echo "!! source tree changed during the build; discard these artifacts and build again" >&2
    echo "!! before=$SOURCE_TREE_SHA after=$SOURCE_TREE_SHA_AFTER" >&2
    exit 1
}

echo "== [5/7] independently audit staged output =="
runtime_name="wine-d2d1-nspa-11.13-${VERSION}.tar.zst"
expected_outputs="$(printf '%s\n' \
    "BUILD-INFO-${VERSION}.txt" \
    BUILD-INFO.txt \
    ableton-linkd \
    cabextract-static \
    pipewire-version-probe \
    "$runtime_name" \
    "$runtime_name.sha256" | sort)"
actual_outputs="$(find "$output_stage" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)"
[ "$actual_outputs" = "$expected_outputs" ] || {
    echo "!! staged build output differs from the exact expected set" >&2
    diff -u <(printf '%s\n' "$expected_outputs") \
        <(printf '%s\n' "$actual_outputs") >&2 || true
    exit 1
}
for staged_output in $expected_outputs; do
    [ -f "$output_stage/$staged_output" ] \
        && [ ! -L "$output_stage/$staged_output" ] \
        && [ -r "$output_stage/$staged_output" ] || {
        echo "!! staged output is not a readable regular file: $staged_output" >&2
        exit 1
    }
done
cmp -s -- "$output_stage/BUILD-INFO-${VERSION}.txt" "$output_stage/BUILD-INFO.txt" || {
    echo "!! staged BUILD-INFO aliases differ" >&2
    exit 1
}
( cd "$output_stage" && sha256sum -c --strict --status "$runtime_name.sha256" ) || {
    echo "!! staged runtime checksum is invalid" >&2
    exit 1
}
bash "$source_snapshot/scripts/build-audit.sh" --source-tree-sha "$SOURCE_TREE_SHA" \
    "$output_stage/$runtime_name"

SOURCE_TREE_SHA_FINAL="$(
    bash "$source_snapshot/scripts/source-tree-digest.sh" --root "$here"
)"
[ "$SOURCE_TREE_SHA_FINAL" = "$SOURCE_TREE_SHA" ] || {
    echo "!! source tree changed during the host audit; discard these artifacts and build again" >&2
    echo "!! snapshot=$SOURCE_TREE_SHA current=$SOURCE_TREE_SHA_FINAL" >&2
    exit 1
}

echo "== [6/7] promote the verified output set into dist/ =="
promotion_stage="$(mktemp -d "$here/dist/.promote.${VERSION}.XXXXXX")"
for staged_output in $expected_outputs; do
    mode=644
    case "$staged_output" in
        ableton-linkd|cabextract-static|pipewire-version-probe) mode=755 ;;
    esac
    install -m "$mode" "$output_stage/$staged_output" "$promotion_stage/$staged_output"
    cmp -s -- "$output_stage/$staged_output" "$promotion_stage/$staged_output" || {
        echo "!! promoted copy changed: $staged_output" >&2
        exit 1
    }
done
for staged_output in $expected_outputs; do
    mv -fT -- "$promotion_stage/$staged_output" "$here/dist/$staged_output"
done
rmdir -- "$promotion_stage"
promotion_stage=""

echo "== [7/7] done: verified artifacts in dist/ =="
for staged_output in $expected_outputs; do
    ls -lh -- "$here/dist/$staged_output"
done
echo
echo "Next:  ./scripts/installer.sh install --skip-live-install"
