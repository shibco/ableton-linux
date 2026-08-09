#!/usr/bin/env bash
# Run a PE tool inside the LIVE Ableton prefix/wineserver session (patched Wine).
# Usage: run_in_prefix.sh <exe> [args...]     (cwd = this dir, so swamprobe.txt lands here)
set -u
WINE_ROOT="$HOME/.local/opt/wine-d2d1-nspa-11.13"
export WINEPREFIX="$HOME/.wine-ableton"
export PATH="$WINE_ROOT/bin:$PATH"
export WINESERVER="$WINE_ROOT/bin/wineserver"
export WINEDEBUG="${WINEDEBUG:--all}"
# The probe writes its report to the cwd (see above), so a failed cd would
# silently scatter output into whatever directory the caller happened to be in.
cd "$(dirname "$0")" || { echo "!! cannot enter $(dirname "$0")" >&2; exit 1; }
exec "$WINE_ROOT/bin/wine" "$@"
