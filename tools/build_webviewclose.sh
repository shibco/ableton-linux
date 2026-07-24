#!/usr/bin/env bash
# Build webviewclose.exe like build_learnheal.sh: real PE via clang, Wine
# headers + import libs, no CRT. Needs ole32 for COM init and the WebView2
# SDK header (Microsoft license — fetched into a cache dir, not committed).
set -e
cd "$(dirname "$0")"
SRC="${ABLETON_WINE_SOURCE:-}"
[ -n "$SRC" ] || { echo "!! set ABLETON_WINE_SOURCE to the wine-d2d1-nspa source tree (with build-wow64/)" >&2; exit 1; }
BLD=$SRC/build-wow64
INC=$SRC/include
U=$BLD/dlls/user32/x86_64-windows
K=$BLD/dlls/kernel32/x86_64-windows
N=$BLD/dlls/ntdll/x86_64-windows
O=$BLD/dlls/ole32/x86_64-windows

# WebView2 SDK header: fetch once into ./webview2-sdk/ (2.6 MB, from the
# public Microsoft.Web.WebView2 nupkg; EventToken.h is our 3-line stub).
SDK=./webview2-sdk
if [ ! -f "$SDK/WebView2.h" ]; then
    mkdir -p "$SDK"
    V=1.0.2903.40
    curl -sL -o "$SDK/wv2.nupkg" \
      "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$V/microsoft.web.webview2.$V.nupkg"
    python3 -c "import zipfile; z=zipfile.ZipFile('$SDK/wv2.nupkg'); \
open('$SDK/WebView2.h','wb').write(z.read('build/native/include/WebView2.h'))"
    rm "$SDK/wv2.nupkg"
    printf '#pragma once\ntypedef struct EventRegistrationToken { __int64 value; } EventRegistrationToken;\n' \
      > "$SDK/EventToken.h"
    echo "fetched WebView2.h $V"
fi

RES=$(clang -print-resource-dir)
clang -target x86_64-windows-gnu -fuse-ld=lld --no-default-config \
  -fno-stack-protector -mno-stack-arg-probe -nostdlib -nostdinc \
  -Wall -O2 \
  -isystem "$RES/include" -I "$INC" -I "$BLD/include" -I "$INC/msvcrt" -I "$SDK" \
  -D__WINESRC__ \
  -Wl,--subsystem,console -Wl,-e,mainCRTStartup \
  -o webviewclose.exe webviewclose.c \
  -L "$U" -L "$K" -L "$N" -L "$O" \
  -luser32 -lkernel32 -lntdll -lole32
echo "built webviewclose.exe"
