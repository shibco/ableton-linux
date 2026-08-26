#!/usr/bin/env bash
# Build the retained alertable-delay/APC probe (apcprobe.exe) as a real PE (no mingw, no
# msvcrt) the same way the patched Wine builds its own PE modules:
# clang -target x86_64-windows + Wine's headers and x86_64-windows import
# libs. Runs under the new-WoW64 patched Wine. Mirrors build_swamprobe.sh;
# apcprobe needs kernel32 (delays/APCs/pipes), user32 (wsprintfA), and ntdll
# (NtTestAlert, NtQueueApcThreadEx2). Run it with: run_in_prefix.sh apcprobe.exe
set -e
cd "$(dirname "$0")"
SRC="${ABLETON_WINE_SOURCE:-}"
[ -n "$SRC" ] || { echo "!! set ABLETON_WINE_SOURCE to the Wine source tree; ABLETON_WINE_BUILD can select its build tree" >&2; exit 1; }
BLD=${ABLETON_WINE_BUILD:-$SRC/build-wow64}
INC=$SRC/include
K=$BLD/dlls/kernel32/x86_64-windows
U=$BLD/dlls/user32/x86_64-windows
N=$BLD/dlls/ntdll/x86_64-windows

for dir in "$INC" "$K" "$U" "$N"; do
  [ -d "$dir" ] || { echo "!! Wine source/build input is missing: $dir" >&2; exit 1; }
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
echo "built apcprobe.exe"
