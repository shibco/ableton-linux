#!/usr/bin/env bash
# Build the persistent native Ableton Link peer in the Podman build image.
# Relative output paths resolve from the repository root.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ableton-wine-build:22.04}"
output="${1:-$root/dist/ableton-linkd}"
case "$output" in
    /*) ;;
    *) output="$root/$output" ;;
esac
out_dir="$(dirname "$output")"
out_name="$(basename "$output")"

command -v "$ENGINE" >/dev/null || {
    echo "!! need $ENGINE to build ableton-linkd" >&2
    exit 1
}
( cd vendor && sha256sum -c link.sha256 )
mkdir -p "$out_dir"
"$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "!! build image $IMAGE is missing: run ./build.sh first" >&2
    exit 1
}

# The container writes into a disposable directory. The wrapper validates the
# candidate and copies it into a host-owned temporary file. It then renames the
# file atomically.
# Failed builds preserve the existing output. The final file belongs to the
# user who runs this wrapper.
build_dir="$(mktemp -d "$out_dir/.ableton-linkd.build.XXXXXX")"
install_tmp=""
cleanup()
{
    rm -rf "$build_dir"
    [ -z "$install_tmp" ] || rm -f "$install_tmp"
}
trap cleanup EXIT
install_tmp="$(mktemp "$out_dir/.${out_name}.install.XXXXXX")"

relabel=""
if [ -f /sys/fs/selinux/enforce ]; then relabel=",Z"; fi
"$ENGINE" run --rm \
    -v "$root:/src:ro$relabel" \
    -v "$build_dir:/out:rw$relabel" \
    "$IMAGE" \
    /src/tools/build_ableton-linkd.sh /out/ableton-linkd

[ -x "$build_dir/ableton-linkd" ] || {
    echo "!! ableton-linkd build did not produce a candidate" >&2
    exit 1
}
"$build_dir/ableton-linkd" --help >/dev/null 2>&1 || {
    echo "!! built ableton-linkd does not run on this host" >&2
    exit 1
}
install -m755 "$build_dir/ableton-linkd" "$install_tmp"
mv -fT -- "$install_tmp" "$output"
install_tmp=""
echo "built $output"
