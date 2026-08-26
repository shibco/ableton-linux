#!/usr/bin/env bash
# Build the x86-64 Windows APC test for the selected Wine source and build.
# Run it from the repository root: tools/run_in_prefix.sh apcprobe.exe
set -e
cd "$(dirname "$0")"
SRC="${ABLETON_WINE_SOURCE:-}"
[ -n "$SRC" ] || { echo "!! Set ABLETON_WINE_SOURCE to the Wine source tree. ABLETON_WINE_BUILD selects another build tree." >&2; exit 1; }
BLD=${ABLETON_WINE_BUILD:-$SRC/build-wow64}
INC=$SRC/include
K=$BLD/dlls/kernel32/x86_64-windows
U=$BLD/dlls/user32/x86_64-windows
N=$BLD/dlls/ntdll/x86_64-windows

for dir in "$INC" "$K" "$U" "$N"; do
  [ -d "$dir" ] || { echo "!! Provide the Wine source or build directory: $dir" >&2; exit 1; }
done

RES=$(clang -print-resource-dir)
clang -target x86_64-windows-gnu -fuse-ld=lld --no-default-config \
  -fno-stack-protector -mno-stack-arg-probe -nostdlib -nostdinc \
  -Wall -O2 \
  -isystem "$RES/include" -I "$INC" -I "$INC/msvcrt" \
  -D__WINESRC__ \
  -Wl,--subsystem,console -Wl,-e,mainCRTStartup \
  -o apcprobe.exe apcprobe.c \
  -L "$K" -L "$U" -L "$N" \
  -lkernel32 -luser32 -lntdll
echo "Built apcprobe.exe"
