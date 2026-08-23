#!/usr/bin/env bash
# Build midiwatch.exe (WinMM topology watcher) the same way as
# build_swamprobe.sh: real PE via clang, Wine headers + import libs, no CRT.
set -e
cd "$(dirname "$0")"
SRC="${ABLETON_WINE_SOURCE:-}"
[ -n "$SRC" ] || { echo "!! set ABLETON_WINE_SOURCE to the Wine source tree; ABLETON_WINE_BUILD can select its build tree" >&2; exit 1; }
BLD=${ABLETON_WINE_BUILD:-$SRC/build-wow64}
INC=$SRC/include
U=$BLD/dlls/user32/x86_64-windows
K=$BLD/dlls/kernel32/x86_64-windows
N=$BLD/dlls/ntdll/x86_64-windows
M=$BLD/dlls/winmm/x86_64-windows

RES=$(clang -print-resource-dir)
clang -target x86_64-windows-gnu -fuse-ld=lld --no-default-config \
  -fno-stack-protector -mno-stack-arg-probe -nostdlib -nostdinc \
  -Wall -Wextra -O2 \
  -isystem "$RES/include" -I "$INC" -I "$INC/msvcrt" \
  -D__WINESRC__ \
  -Wl,--subsystem,console -Wl,-e,mainCRTStartup \
  -o midiwatch.exe midiwatch.c \
  -L "$U" -L "$K" -L "$N" -L "$M" \
  -luser32 -lkernel32 -lntdll -lwinmm
echo "built midiwatch.exe"
