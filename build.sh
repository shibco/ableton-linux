#!/usr/bin/env bash
#
#   ./build.sh                # build the relocatable tarball with podman
#   ENGINE=docker ./build.sh  # or docker
#   JOBS=8 ./build.sh         # limit parallelism
#   INSTALL_PREFIX=/target/path/wine-d2d1-nspa-11.13 ./build.sh
#                             # strict path-identity build; normally unnecessary —
#                             # the tarball self-locates (relocation gate proves it)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ableton-wine-build:22.04}"
JOBS="${JOBS:-$(nproc)}"
# Wine locates bin/ -> lib/wine -> share/wine relative to the running binary.
# One tarball can serve any user and any $HOME. 
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/wine-d2d1-nspa-11.13}"

command -v "$ENGINE" >/dev/null || { echo "!! '$ENGINE' not found (set ENGINE=docker?)"; exit 1; }

echo "== [0/3] verify vendored inputs against pinned checksums =="
( cd vendor && sha256sum -c wine-base.sha256 pipeasio.sha256 pipewire-sdk.sha256 ntsync-uapi.sha256 )

echo "== [1/3] build container image ($IMAGE) =="
$ENGINE build -t "$IMAGE" -f Containerfile .

echo "== [2/3] build Wine + PipeASIO in the container (JOBS=$JOBS) =="
mkdir -p dist
relabel=""
if [ -f /sys/fs/selinux/enforce ]; then relabel=",Z"; fi
$ENGINE run --rm \
    -v "$here:/src:ro$relabel" \
    -v "$here/dist:/out:rw$relabel" \
    -e JOBS="$JOBS" \
    -e "INSTALL_PREFIX=$INSTALL_PREFIX" \
    "$IMAGE" \
    /src/scripts/container-build.sh

echo "== [3/3] done — artifacts in dist/ =="
ls -lh dist/
echo
echo "Next:  ./scripts/install.sh   then   ./scripts/setup-prefix.sh"
