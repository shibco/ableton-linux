#!/usr/bin/env bash
# Run a PE tool inside the LIVE Ableton prefix/wineserver session (patched Wine).
# Usage: run_in_prefix.sh <exe> [args...]     (cwd = this dir, so swamprobe.txt lands here)
set -u
WINE_ROOT="$HOME/.local/opt/wine-d2d1-nspa-11.13"
export WINEPREFIX="$HOME/.wine-ableton"
export PATH="$WINE_ROOT/bin:$PATH"
export WINESERVER="$WINE_ROOT/bin/wineserver"
export WINEDEBUG="${WINEDEBUG:--all}"
cd "$(dirname "$0")"
exec "$WINE_ROOT/bin/wine" "$@"
