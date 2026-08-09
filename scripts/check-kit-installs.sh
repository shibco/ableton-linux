#!/usr/bin/env bash
# Prove a packed kit installs before anyone else gets it.
#
#   ./scripts/check-kit-installs.sh dist/ableton-wine-setup-<label>.run <channel>
#
# Runs the kit's own installer, runtime-only, against a throwaway HOME, then
# asserts the store the migration promises: one build directory, the channel
# symlink pointing at it, the channel recorded, and the installed wine able to
# execute. Runtime-only on purpose: the prefix phase runs winetricks under
# wine and belongs to a machine with a display; what CI can honestly verify is
# that the artifact it is about to publish installs and runs at all - which no
# test did until a published kit failed to. The suite executes the checkout's
# install.sh; this executes the kit's.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

run="${1:?usage: check-kit-installs.sh <kit.run> <channel>}"
channel="${2:?usage: check-kit-installs.sh <kit.run> <channel>}"
[ -f "$run" ] || { echo "!! no such kit: $run" >&2; exit 1; }

sb="$(mktemp -d)"
trap 'rm -rf "$sb"' EXIT
mkdir -p "$sb/home" "$sb/xdg"

# The same neutralisation the install-runs suite uses: HOME contains every
# path install.sh writes, and the dead session bus keeps `systemctl --user`
# from reaching the machine's real ableton-linkd.
echo "== install $(basename "$run") (runtime-only, sandboxed HOME) =="
env -i PATH="$PATH" HOME="$sb/home" \
    XDG_RUNTIME_DIR="$sb/xdg" DBUS_SESSION_BUS_ADDRESS=/dev/null \
    sh "$run" --runtime-only

# The store, as the kit's own resolver sees it under the sandbox HOME.
container="$(env HOME="$sb/home" bash -c '. "'"$here"'/runtime-env.sh"; works_runtime_store')"
entries=()
for d in "$container"/*/; do
    [ -L "${d%/}" ] && continue
    [ -d "$d" ] && entries+=("${d%/}")
done
[ "${#entries[@]}" -eq 1 ] \
    || { echo "!! expected exactly one build in the store, found: ${entries[*]:-none}" >&2; exit 1; }
build="${entries[0]}"

[ -L "$container/$channel" ] \
    || { echo "!! no $channel channel symlink in $container" >&2; ls -l "$container" >&2; exit 1; }
[ "$(readlink "$container/$channel")" = "$(basename "$build")" ] \
    || { echo "!! $channel points at $(readlink "$container/$channel"), not $(basename "$build")" >&2; exit 1; }

recorded="$sb/home/works/runtimes/.channel"
[ "$(cat "$recorded" 2>/dev/null)" = "$channel" ] \
    || { echo "!! the recorded channel is '$(cat "$recorded" 2>/dev/null)', kit says '$channel'" >&2; exit 1; }

# The one check that killed the -debug tree defect: the installed wine execs.
ver="$(env -i HOME="$sb/home" "$build/bin/wine" --version)"
echo "== installed and running: $ver as $(basename "$build") [$channel] =="
