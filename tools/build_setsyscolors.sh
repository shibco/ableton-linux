#!/usr/bin/env bash
# Build setsyscolors.exe (unified-top-bar color broadcaster) the same way as
# build_midihot.sh: real PE via clang, Wine headers + import libs, no CRT.
set -e
cd "$(dirname "$0")"
SRC="${ABLETON_WINE_SOURCE:-}"
[ -n "$SRC" ] || { echo "!! set ABLETON_WINE_SOURCE to the wine-d2d1-nspa source tree (with build-wow64/)" >&2; exit 1; }
BLD=$SRC/build-wow64
INC=$SRC/include
U=$BLD/dlls/user32/x86_64-windows
K=$BLD/dlls/kernel32/x86_64-windows
N=$BLD/dlls/ntdll/x86_64-windows

RES=$(clang -print-resource-dir)
clang -target x86_64-windows-gnu -fuse-ld=lld --no-default-config \
  -fno-stack-protector -mno-stack-arg-probe -nostdlib -nostdinc \
  -Wall -O2 \
  -isystem "$RES/include" -I "$INC" -I "$INC/msvcrt" \
  -D__WINESRC__ \
  -Wl,--subsystem,console -Wl,-e,mainCRTStartup \
  -o setsyscolors.exe setsyscolors.c \
  -L "$U" -L "$K" -L "$N" \
  -luser32 -lkernel32 -lntdll
echo "built setsyscolors.exe"
