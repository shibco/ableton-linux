#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MACOS="$ROOT/scripts/ableton-macos-profiler.sh"
LINUX="$ROOT/scripts/ableton-linux-profiler.sh"
WINDOWS="$ROOT/scripts/ableton-windows-profiler.ps1"
COMMON="$ROOT/tester-kit/lib/common.sh"
COLLECT_LINUX="$ROOT/tester-kit/lib/collect-linux.sh"

fail() {
    printf 'privacy check failed: %s\n' "$1" >&2
    exit 1
}

assert_absent() {
    local pattern="$1"
    shift
    if grep -En "$pattern" "$@" >/dev/null; then
        fail "forbidden source pattern: $pattern"
    fi
}

assert_present() {
    local pattern="$1"
    local file="$2"
    grep -Eq "$pattern" "$file" || fail "required source pattern missing: $pattern"
}

assert_absent 'LOGIN_NAME|loginName|host_re|login_re|ABLETON_BETA_HOSTNAME' \
    "$MACOS" "$LINUX" "$WINDOWS" "$COMMON"
assert_absent 'tester[-_]id|machine[-_]id|TESTER_ID|MACHINE_ID|testerId|machineId' \
    "$MACOS" "$LINUX" "$WINDOWS"
assert_absent 'product_serial|product_uuid|board_serial|chassis_asset_tag|chassis_serial|SERIAL,WWN|manufacturer product serial|collect lshw|Full hardware inventory' \
    "$LINUX" "$COLLECT_LINUX"
assert_absent 'Select-Object[^|]*(ProcessorId|IdentifyingNumber|UUID|SerialNumber|PNPDeviceID|InstanceId|FriendlyName)' \
    "$WINDOWS"
assert_absent 'collect auval|diskutil list|ABLETON_LOG_ERRORS|tail -n 400' \
    "$MACOS"
assert_absent 'Header "ABLETON_LOG_ERRORS"|Get-Content[^|]*-Tail 400' \
    "$WINDOWS"
assert_present 'omit_unique_identifiers' "$MACOS"
assert_present 'return ""' "$WINDOWS"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/Users/b"

printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in' \
    '  *SPAudioDataType*)' \
    '    printf "%s\n" "Audio:" "    Devices:" "        Owners Private Interface:" "          Manufacturer: Example Audio" "          Output Channels: 8" "          Serial Number: PRIVATE-AUDIO-SERIAL" "          Address: AA:BB:CC:DD:EE:FF" "          Transport: USB"' \
    '    ;;' \
    '  *)' \
    '    printf "%s\n" "Serial Number: PRIVATE-SERIAL" "Hardware UUID: PRIVATE-UUID"' \
    '    ;;' \
    'esac' > "$tmp/bin/system_profiler"
chmod 700 "$tmp/bin/system_profiler"

report="$(
    HOME="$tmp/Users/b" \
    USER=b \
    PATH="$tmp/bin:$PATH" \
        bash "$MACOS" 2>/dev/null
)"

[[ -n "$report" ]] || fail 'mock macOS report was empty'
grep -Fq '        Audio Device:' <<< "$report" || fail 'audio label was not generalized'
grep -Fq 'Output Channels: 8' <<< "$report" || fail 'audio details were corrupted'
if grep -Eq 'PRIVATE-|Owners|Serial Number|UUID:|Address:|Location ID:|Mount Point:|BSD Name:' <<< "$report"; then
    fail 'mock macOS report retained a unique identifier or personal device label'
fi
if grep -Eq '[[:alnum:]]<USER>|<USER>[[:alnum:]]' <<< "$report"; then
    fail 'username placeholder was inserted inside ordinary data'
fi

source "$COMMON"
redacted="$(
    printf '%s\n' \
        'tester_id=BETA-B9EC8ABA471A4BE9FA30' \
        'BuildVersion: 24F74' \
        'Model Name: MacBook Air' \
        'Memory: 16 GB' \
        '/home/b/Music' \
        'device.serial = PRIVATE-SERIAL' \
        'title="Private Project"' \
        "cls='Ableton Live Window Class' 'Private Project'" |
        HOME=/home/b USER=b redact_stream
)"

grep -Fq 'tester_id=BETA-B9EC8ABA471A4BE9FA30' <<< "$redacted" ||
    fail 'shared redactor corrupted the Tester-ID'
grep -Fq 'BuildVersion: 24F74' <<< "$redacted" || fail 'shared redactor corrupted BuildVersion'
grep -Fq '<HOME>/Music' <<< "$redacted" || fail 'shared redactor did not hide the home path'
grep -Fq 'title="<WINDOW-TITLE>"' <<< "$redacted" || fail 'shared redactor retained a window title'
grep -Fq "cls='Ableton Live Window Class' '<WINDOW-TITLE>'" <<< "$redacted" ||
    fail 'shared redactor retained a SWAM window title'
if grep -Fq 'PRIVATE-SERIAL' <<< "$redacted"; then
    fail 'shared redactor retained a serial value'
fi

printf 'Profiler privacy checks passed.\n'
