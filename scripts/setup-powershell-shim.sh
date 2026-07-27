#!/usr/bin/env bash
# End-user helper: install a smart `powershell.exe` shim into the Ableton Wine
# prefix. Needed for any Windows installer that uses PowerShell as a
# preflight process check (e.g. Native Instruments Native Access 2 loops
# on "Native Access is running" forever because Wine's powershell.exe
# builtin stub ignores its -C argument and always exits 0).
#
# Background: Wine's `powershell.exe` is a builtin command. The loader stub
# at $ABLETON_WINE_ROOT/lib/wine/x86_64-windows/powershell.exe and the
# on-disk fallback at $WINEPREFIX/drive_c/windows/.../powershell.exe are
# 28 KB stubs that IGNORE their -C argument and always exit 0. Windows
# installers that ask "is <my app> already running?" via
#   powershell.exe -C "if ((Get-CimInstance Win32_Process |
#                          Where-Object Name -StartsWith '<app>').Count
#                       -gt 0) { exit 0 } else { exit 1 }"
# loop forever in Wine: the stub exits 0 (interpreted as "yes, app is
# running") and the installer re-spawns itself.
#
# This shim inspects argv and returns 1 (pretend the app is NOT running)
# only when it sees the three substrings "Get-CimInstance",
# "Win32_Process", "StartsWith". For every other invocation it mimics
# the original stub's behaviour: do nothing, return 0. A dumb
# `return 1;` shim breaks the loop but then breaks the installer's own
# first-run dep check (Native Access uses powershell to look up the
# NTKDaemon version, expecting exit 0 and a value on stdout). The
# selective shim is what unblocks both.
#
# Originals are backed up next to the patched files as
# <file>.wine-stub.bak the first time this script runs. Re-runs are
# a no-op (idempotent) as long as the shim is in place. After any
# $ABLETON_WINE_ROOT update that re-installs the loader stub,
# re-run this script to re-apply the patch.
#
# Revert with: scripts/restore-powershell-shim.sh
#
# Requirements:
#   - x86_64-w64-mingw32-gcc (apt: gcc-mingw-w64-x86-64-win32)
#   - Wine prefix already initialised (setup-prefix.sh)
#
# Overrides: ABLETON_WINE_ROOT=    Wine install path
#                                (default ~/.local/opt/wine-d2d1-nspa-11.13)
#           ABLETON_WINEPREFIX=   Wine prefix path
#                                (default ~/.wine-ableton)
set -euo pipefail

WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"
WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"

if [[ ! -x "$WINE_ROOT/bin/wine" ]]; then
    echo "!! wine binary not found at $WINE_ROOT/bin/wine" >&2
    echo "!! set ABLETON_WINE_ROOT=/path/to/wine" >&2
    exit 1
fi
if [[ ! -d "$WINEPREFIX/drive_c" ]]; then
    echo "!! WINEPREFIX does not look like a wine prefix: $WINEPREFIX" >&2
    exit 1
fi
if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    echo "!! x86_64-w64-mingw32-gcc not found" >&2
    echo "!! install with: sudo apt install -y gcc-mingw-w64-x86-64-win32" >&2
    exit 1
fi

# 1) Build the shim (heredoc, no /tmp scratch file needed).
#    The shim's whole logic: look for the three NA-style check substrings;
#    if all three are present, return 1 (NA is not running); else return 0
#    (behave like the original Wine stub).
shim_src=$(mktemp)
shim_bin=$(mktemp)
trap 'rm -f "$shim_src" "$shim_bin"' EXIT
cat > "$shim_src" <<'EOF'
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    int i, found_cim = 0, found_proc = 0, found_starts = 0;
    for (i = 0; i < argc; i++) {
        if (!argv[i]) continue;
        if (strstr(argv[i], "Get-CimInstance")) found_cim = 1;
        if (strstr(argv[i], "Win32_Process"))  found_proc = 1;
        if (strstr(argv[i], "StartsWith"))      found_starts = 1;
    }
    /* Standard NA-style process-already-running check.
     * We deliberately don't gate on the app name (e.g. "Native Access")
     * so the same shim works for any installer that uses the same
     * Get-CimInstance + Win32_Process + StartsWith pattern. */
    if (found_cim && found_proc && found_starts) return 1;
    return 0;  /* everything else: behave like the original Wine stub */
}
EOF
x86_64-w64-mingw32-gcc -O2 -s -o "$shim_bin" "$shim_src"

# 2) Patch every powershell.exe that could be invoked. Wine's loader
#    dispatches builtin commands via the loader stub (a), but installers
#    that explicitly call `powershell.exe` from a CMD shell hit the
#    on-disk copy in drive_c/.../system32 (b) first. The 32-bit copy
#    in syswow64 (c) is rarely needed today but costs nothing to cover.
patch_one() {
    local f="$1" desc="$2"
    if [[ ! -f "$f" ]]; then
        echo "   - $desc: missing, skipping"
        return
    fi
    if cmp -s "$f" "$shim_bin"; then
        echo "   - $desc: already patched"
        return
    fi
    if [[ -f "$f.wine-stub.bak" ]]; then
        cp -f "$shim_bin" "$f"
        echo "   - $desc: re-patched (backup at .wine-stub.bak)"
    else
        cp -p "$f" "$f.wine-stub.bak"
        cp -f "$shim_bin" "$f"
        echo "   - $desc: patched (backup at .wine-stub.bak)"
    fi
}

echo "Patching powershell.exe shims (WINE_ROOT=$WINE_ROOT, WINEPREFIX=$WINEPREFIX):"
patch_one "$WINE_ROOT/lib/wine/x86_64-windows/powershell.exe" "wine-loader-64"
patch_one "$WINEPREFIX/drive_c/windows/system32/WindowsPowerShell/v1.0/powershell.exe" "prefix-system32"
patch_one "$WINEPREFIX/drive_c/windows/syswow64/WindowsPowerShell/v1.0/powershell.exe" "prefix-syswow64"

# 3) Functional sanity check. The shim's matching logic returns 1 only when
#    argv contains all three substrings: Get-CimInstance, Win32_Process,
#    StartsWith. We feed it a script that contains those substrings (mimics
#    the Native Access 2 preflight), so the shim should match and exit 1.
#    If it exits 0 instead, the matching code path didn't fire — the patch
#    did not apply, or a stale shim from a previous Wine tree is still in
#    place. This catches both failure modes; an unrelated script (like
#    'exit 7') would only test "the shim runs at all", not "the matching
#    logic works", which is what we actually want to verify.
echo
echo "Sanity: $WINE_ROOT/bin/wine powershell.exe -C '<Get-CimInstance ... StartsWith script>'"
NA_SCRIPT='if ((Get-CimInstance Win32_Process | Where-Object { $_.Name -StartsWith Test }).Count -gt 0) { exit 0 } else { exit 1 }'
if WINEPREFIX="$WINEPREFIX" "$WINE_ROOT/bin/wine" powershell.exe -C "$NA_SCRIPT" >/dev/null 2>&1; then
    echo "   WARNING: shim returned 0 for the NA-style check (expected 1)."
    echo "            The matching code path did not fire. Patch may not have applied,"
    echo "            or a stale shim from a previous Wine tree is still in place."
    echo "            Re-run after: scripts/restore-powershell-shim.sh"
    exit 2
fi
echo "   OK: shim returned 1 for the NA-style preflight (matching logic fired)."

cat <<EOF

Done. The patched files (with backups at <file>.wine-stub.bak):
  - $WINE_ROOT/lib/wine/x86_64-windows/powershell.exe
  - $WINEPREFIX/drive_c/windows/system32/WindowsPowerShell/v1.0/powershell.exe
  - $WINEPREFIX/drive_c/windows/syswow64/WindowsPowerShell/v1.0/powershell.exe

To revert (restore the original Wine stubs):
  scripts/restore-powershell-shim.sh

Known installers that benefit from this shim:
  - Native Instruments Native Access 2 (NSIS installer, "Native Access
    is running" dialog loop on every fresh install).
  - Any other NSIS / InstallAware installer that uses the same
    Get-CimInstance Win32_Process | Where-Object Name -StartsWith
    pattern as a process-already-running preflight.

This shim does NOT execute PowerShell scripts. It only intercepts the
specific three-substring argv pattern. For real PowerShell support in
Wine, use a separate PowerShell binary (powershell-core or pwsh) and
add it to PATH; do NOT replace this shim with one, since the
patched stub is wired into Wine's loader-stub dispatcher and a
full implementation would change how every other installer behaves.
EOF