#!/usr/bin/env bash
# Run a PE tool inside the LIVE Ableton prefix/wineserver session (patched Wine).
# Usage: run_in_prefix.sh <exe> [args...]     (cwd = this dir, so swamprobe.txt lands here)
set -u
for _l in "$(dirname "$0")/runtime-env.sh" "$HOME/works/lib/runtime-env.sh"; do
    # shellcheck source=scripts/runtime-env.sh
    [ -r "$_l" ] && . "$_l" && break
done
command -v works_runtime_path >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found next to $0 or in ~/works/apps/ableton-live" >&2; exit 1; }
WINE_ROOT="$(works_runtime_path)"
export WINEPREFIX="$HOME/works/plugs/studio"
export PATH="$WINE_ROOT/bin:$PATH"
export WINESERVER="$WINE_ROOT/bin/wineserver"
export WINEDEBUG="${WINEDEBUG:--all}"
cd "$(dirname "$0")"
exec "$WINE_ROOT/bin/wine" "$@"
