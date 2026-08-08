#!/usr/bin/env bash
# Build the GetUpdateRect probe (updateprobe.exe) as a real PE (no mingw, no
# msvcrt) the same way the patched Wine builds its own PE modules:
# clang -target x86_64-windows + Wine's headers and x86_64-windows import
# libs. Mirrors build_apcprobe.sh; updateprobe also needs user32 (window,
# GetUpdateRect). Run it with: run_in_prefix.sh updateprobe.exe
set -e
cd "$(dirname "$0")"
SRC="${ABLETON_WINE_SOURCE:-}"
[ -n "$SRC" ] || { echo "!! set ABLETON_WINE_SOURCE to the wine-d2d1-nspa source tree (with build-wow64/)" >&2; exit 1; }
BLD=$SRC/build-wow64
INC=$SRC/include
K=$BLD/dlls/kernel32/x86_64-windows
U=$BLD/dlls/user32/x86_64-windows
N=$BLD/dlls/ntdll/x86_64-windows

RES=$(clang -print-resource-dir)
clang -target x86_64-windows-gnu -fuse-ld=lld --no-default-config \
  -fno-stack-protector -mno-stack-arg-probe -nostdlib -nostdinc \
  -Wall -O2 \
  -isystem "$RES/include" -I "$INC" -I "$INC/msvcrt" \
  -D__WINESRC__ \
  -Wl,--subsystem,console -Wl,-e,mainCRTStartup \
  -o updateprobe.exe updateprobe.c \
  -L "$K" -L "$U" -L "$N" \
  -lkernel32 -luser32 -lntdll
echo "built updateprobe.exe"
