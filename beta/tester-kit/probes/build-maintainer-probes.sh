#!/usr/bin/env bash
# Rebuild the tester-kit-specific PE probes against a Wine build tree.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source_dir="$here/src"
output_dir="$here/windows"
advanced_source="$here/advanced/src"
advanced_output="$here/advanced/windows"
wine_source="${ABLETON_WINE_SOURCE:-$HOME/Projects/Code/ableton/wine-d2d1-nspa-src}"
wine_build="${ABLETON_WINE_BUILD:-$wine_source/build-wow64}"
include_dir="$wine_source/include"
resource_dir="$(clang -print-resource-dir)"

user32="$wine_build/dlls/user32/x86_64-windows"
kernel32="$wine_build/dlls/kernel32/x86_64-windows"
gdi32="$wine_build/dlls/gdi32/x86_64-windows"
ntdll="$wine_build/dlls/ntdll/x86_64-windows"
comdlg32="$wine_build/dlls/comdlg32/x86_64-windows"

common=(
    -target x86_64-windows-gnu -fuse-ld=lld --no-default-config
    -fno-stack-protector -mno-stack-arg-probe -nostdlib -nostdinc
    -Wall -Wextra -O2
    -isystem "$resource_dir/include" -I "$include_dir" -I "$include_dir/msvcrt"
    -D__WINESRC__
    -Wl,--subsystem,windows -Wl,-e,mainCRTStartup
)

mkdir -p "$output_dir" "$advanced_output"

clang "${common[@]}" -o "$output_dir/resizeprobe.exe" "$source_dir/resizeprobe.c" -L "$user32" -L "$kernel32" -L "$gdi32" -L "$ntdll" -luser32 -lkernel32 -lgdi32 -lntdll
clang "${common[@]}" -o "$output_dir/pluginwindowprobe.exe" "$source_dir/pluginwindowprobe.c" -L "$user32" -L "$kernel32" -L "$gdi32" -L "$ntdll" -luser32 -lkernel32 -lgdi32 -lntdll
clang "${common[@]}" -o "$output_dir/portalprobe.exe" "$source_dir/portalprobe.c" -L "$user32" -L "$kernel32" -L "$gdi32" -L "$ntdll" -L "$comdlg32" -lcomdlg32 -luser32 -lkernel32 -lgdi32 -lntdll
clang "${common[@]}" -o "$advanced_output/spyhost.exe" "$advanced_source/spyhost-portable.c" -L "$user32" -L "$kernel32" -L "$ntdll" -luser32 -lkernel32 -lntdll
clang -target x86_64-windows-gnu -fuse-ld=lld --no-default-config -fno-stack-protector -mno-stack-arg-probe -nostdlib -nostdinc -Wall -Wextra -O2 -isystem "$resource_dir/include" -I "$include_dir" -I "$include_dir/msvcrt" -D__WINESRC__ -shared -Wl,-e,DllMain -Wl,--export-all-symbols -o "$advanced_output/mousespy.dll" "$advanced_source/mousespy.c" -L "$user32" -L "$kernel32" -L "$ntdll" -luser32 -lkernel32 -lntdll
clang "${common[@]}" -o "$output_dir/ntsyncprobe.exe" "$source_dir/ntsyncprobe.c" -L "$user32" -L "$kernel32" -L "$ntdll" -luser32 -lkernel32 -lntdll

(
    cd "$here"
    sha256sum windows/*.exe > SHA256SUMS
    cd advanced
    sha256sum windows/* > SHA256SUMS
)

printf 'Built tester-kit probes in %s\n' "$output_dir"
