#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-low-fi-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# shellcheck source=scripts/lib/live-components.sh
. "$here/lib/live-components.sh"

prefix="$work/prefix"
live="$prefix/drive_c/ProgramData/Ableton/Live 12 Suite"
mkdir -p -- \
    "$live/Program" "$live/Redist" "$live/Resources/Max" \
    "$live/Resources/Core Library/Devices" \
    "$prefix/drive_c/Program Files (x86)/Microsoft/EdgeWebView" \
    "$prefix/drive_c/Program Files (x86)/Microsoft/EdgeUpdate" \
    "$prefix/drive_c/Program Files/Cycling '74/Max 9" \
    "$prefix/drive_c/users/test/Documents/Ableton/User Library" \
    "$prefix/drive_c/ProgramData/Arturia/webview2"
printf x > "$live/Resources/Max/MaxRT.exe"
printf x > "$live/Resources/Core Library/Devices/Factory.amxd"
printf x > "$live/Program/WebView2Loader.dll"
printf x > "$live/Redist/MicrosoftEdgeWebview2Setup.exe"
printf x > "$prefix/drive_c/Program Files/Cycling '74/Max 9/Max.exe"
printf x > "$prefix/drive_c/users/test/Documents/Ableton/User Library/Keep.amxd"
printf x > "$prefix/drive_c/ProgramData/Arturia/webview2/msedgewebview2.exe"

ableton_low_fi_remove "$prefix"
ableton_low_fi_remove "$prefix"
[ ! -e "$live/Resources/Max" ]
[ ! -e "$live/Program/WebView2Loader.dll" ]
[ ! -e "$prefix/drive_c/Program Files (x86)/Microsoft/EdgeWebView" ]
if find "$live/Resources" -type f -iname '*.amxd' -print -quit | grep -q .; then
    exit 1
fi
[ -f "$prefix/drive_c/Program Files/Cycling '74/Max 9/Max.exe" ]
[ -f "$prefix/drive_c/users/test/Documents/Ableton/User Library/Keep.amxd" ]
[ -f "$prefix/drive_c/ProgramData/Arturia/webview2/msedgewebview2.exe" ]
echo 'ok - removes bundled Max/WebView2 and preserves user and third-party files'

config_home="$work/config-home"
mkdir -p -- "$config_home"
# $1 belongs to the child shell.
# shellcheck disable=SC2016
env HOME="$config_home" XDG_CONFIG_HOME="$work/config" \
    XDG_DATA_HOME="$work/data" XDG_STATE_HOME="$work/state" \
    XDG_CACHE_HOME="$work/cache" ABLETON_LOW_FI_ABLETON=1 \
    bash -c '. "$1"; ableton_config_init; ableton_write_config' \
    _ "$here/lib/config.sh"
grep -qxF 'low_fi_ableton=1' "$work/config/ableton-wine/config"
grep -qF -- '--low-fi-ableton' < <(bash "$here/installer.sh" --help)
echo 'ok - flag is public and sticky'

echo '1..2'
