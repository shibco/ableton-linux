#!/usr/bin/env bash
# Reverse of scripts/setup-powershell-shim.sh: restore the original
# Wine powershell.exe stubs from the .wine-stub.bak backups.
#
# Safe to run if setup-powershell-shim.sh was never applied: the
# .wine-stub.bak files won't exist and the script is a no-op for
# those paths.
#
# After this script, Wine's `powershell.exe` once again ignores its
# -C argument and always exits 0. Run setup-powershell-shim.sh again
# to re-apply.
#
# Overrides: ABLETON_WINE_ROOT=    Wine install path
#                                (default ~/.local/opt/wine-d2d1-nspa-11.13)
#           ABLETON_WINEPREFIX=   Wine prefix path
#                                (default ~/.wine-ableton)
set -euo pipefail

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"
WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"

restore_one() {
    local f="$1" desc="$2"
    if [[ ! -f "$f.wine-stub.bak" ]]; then
        echo "   - $desc: no backup at $f.wine-stub.bak, skipping"
        return
    fi
    cp -p "$f.wine-stub.bak" "$f"
    rm -f "$f.wine-stub.bak"
    echo "   - $desc: restored"
}

echo "Restoring original Wine powershell.exe stubs:"
restore_one "$WINE_ROOT/lib/wine/x86_64-windows/powershell.exe" "wine-loader-64"
restore_one "$WINEPREFIX/drive_c/windows/system32/WindowsPowerShell/v1.0/powershell.exe" "prefix-system32"
restore_one "$WINEPREFIX/drive_c/windows/syswow64/WindowsPowerShell/v1.0/powershell.exe" "prefix-syswow64"

echo
echo "Done. Wine's powershell.exe once again ignores -C and always exits 0."
echo "Re-apply the shim with: scripts/setup-powershell-shim.sh"