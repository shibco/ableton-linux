#!/usr/bin/env bash
# Run a PE tool inside the LIVE Ableton prefix/wineserver session (patched Wine).
# Usage: run_in_prefix.sh <exe> [args...]     (cwd = this dir, so swamprobe.txt lands here)
set -u
for _l in "$(dirname "$0")/runtime-env.sh" "$HOME/.local/share/ableton-wine/runtime-env.sh"; do
    # shellcheck source=scripts/runtime-env.sh
    [ -r "$_l" ] && . "$_l" && break
done
command -v ableton_wine_root >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found next to $0 or in ~/.local/share/ableton-wine" >&2; exit 1; }
WINE_ROOT="$(ableton_wine_root)"
export WINEPREFIX="$HOME/.wine-ableton"
export PATH="$WINE_ROOT/bin:$PATH"
export WINESERVER="$WINE_ROOT/bin/wineserver"
export WINEDEBUG="${WINEDEBUG:--all}"
cd "$(dirname "$0")"
exec "$WINE_ROOT/bin/wine" "$@"
