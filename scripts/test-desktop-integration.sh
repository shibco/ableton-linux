#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-desktop-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
pass=0

ok()
{
    pass=$((pass + 1))
    printf 'ok - %s\n' "$1"
}

fail()
{
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

new_env()
{
    local name="$1" base
    base="$work/$name"
    mkdir -p -- "$base/home" "$base/tmp" "$base/fakebin"
    printf '%s\n' "$base"
}

install_fake_desktop_tools()
{
    local base="$1"
    cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${ABLETON_TEST_MIME_STATE:?}"
case "${1:-}" in
    default)
        [ "$#" -ge 3 ]
        application="$2"
        shift 2
        mkdir -p -- "$(dirname "$state")"
        touch "$state"
        for type in "$@"; do
            awk -F '\t' -v type="$type" '$1 != type' "$state" > "$state.tmp"
            printf '%s\t%s\n' "$type" "$application" >> "$state.tmp"
            mv -- "$state.tmp" "$state"
        done ;;
    query)
        [ "${2:-}" = default ] && [ "$#" -eq 3 ]
        if [ "${ABLETON_TEST_XDG_STICKY:-0}" -eq 1 ]; then
            printf 'foreign.desktop\n'
        else
            awk -F '\t' -v type="$3" '$1 == type { value=$2 } END { print value }' "$state" 2>/dev/null
        fi ;;
    *) exit 2 ;;
esac
EOF
    for tool in update-desktop-database update-mime-database gtk-update-icon-cache; do
        cat > "$base/fakebin/$tool" <<'EOF'
#!/bin/sh
exit 0
EOF
    done
    chmod +x "$base/fakebin/"*
}

run_isolated()
{
    local base="$1"; shift
    env HOME="$base/home" XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data" \
        XDG_STATE_HOME="$base/state" XDG_CACHE_HOME="$base/cache" \
        XDG_RUNTIME_DIR="$base/run" TMPDIR="$base/tmp" \
        ABLETON_TEST_MIME_STATE="$base/mime-defaults.tsv" \
        PATH="$base/fakebin:/usr/bin:/bin" "$@"
}

protocol_id=io.github.shibco.ableton-linux.protocol.desktop
auz_id=io.github.shibco.ableton-linux.auz.desktop

base="$(new_env unique-handlers)"
install_fake_desktop_tools "$base"
mkdir -p -- "$base/data/applications"
cat > "$base/data/applications/wine-protocol-ableton.desktop" <<EOF
[Desktop Entry]
Exec=$base/home/.local/bin/ableton-live %u
EOF
cat > "$base/data/applications/wine-extension-auz.desktop" <<'EOF'
[Desktop Entry]
Exec=env WINEPREFIX=/tmp/foreign wine start %f
EOF
if ! run_isolated "$base" bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err"; then
    cat "$base/err" >&2
    fail "installer cannot install desktop integration in an isolated home"
fi
[ -f "$base/data/applications/$protocol_id" ] || fail "installer omits the project protocol handler"
[ -f "$base/data/applications/$auz_id" ] || fail "installer omits the project AUZ handler"
[ -f "$base/data/ableton-wine/$protocol_id" ] || fail "installer omits the staged protocol handler"
[ -f "$base/data/ableton-wine/$auz_id" ] || fail "installer omits the staged AUZ handler"
[ ! -e "$base/data/applications/wine-protocol-ableton.desktop" ] \
    || fail "installer keeps its globally named legacy protocol handler"
[ -f "$base/data/applications/wine-extension-auz.desktop" ] \
    || fail "installer removes a foreign globally named handler"
[ "$(awk -F '\t' '$1 == "x-scheme-handler/ableton" { print $2 }' "$base/mime-defaults.tsv")" = "$protocol_id" ] \
    || fail "installer does not pin the project protocol handler"
[ "$(awk -F '\t' '$1 == "application/x-wine-extension-auz" { print $2 }' "$base/mime-defaults.tsv")" = "$auz_id" ] \
    || fail "installer does not pin the project AUZ handler"
ok "installer uses unique callback handlers and retires only its legacy entry"

base="$(new_env registration-failure)"
install_fake_desktop_tools "$base"
if run_isolated "$base" env ABLETON_TEST_XDG_STICKY=1 \
    bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err"; then
    fail "installer accepts a handler default that did not stick"
fi
grep -q "resolves to 'foreign.desktop'" "$base/err" \
    || fail "installer does not report the handler that defeated registration"
[ ! -e "$base/data/applications/$protocol_id" ] \
    || fail "failed registration leaves the new protocol handler installed"
ok "installer reports and rolls back a failed MIME default"

base="$(new_env callback-discovery)"
install_fake_desktop_tools "$base"
cat > "$base/fakebin/getconf" <<'EOF'
#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = _NPROCESSORS_ONLN ] || exit 2
printf '32\n'
EOF
cat > "$base/fakebin/nproc" <<'EOF'
#!/bin/sh
[ "$#" -eq 0 ] || exit 2
printf '32\n'
EOF
chmod +x "$base/fakebin/getconf" "$base/fakebin/nproc"
mkdir -p -- "$base/runtime/bin" "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program" \
    "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Standard/Program" \
    "$base/prefix/drive_c/users/test/AppData/Roaming" \
    "$base/data/ableton-wine" "$base/data/applications" "$base/run"
cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
printf 'prefix=%s wine %s\n' "${WINEPREFIX:-}" "$*" >> "${ABLETON_TEST_WINE_LOG:?}"
exit 0
EOF
for tool in wineserver wineboot winepath; do
    cat > "$base/runtime/bin/$tool" <<'EOF'
#!/bin/sh
exit 0
EOF
done
chmod +x "$base/runtime/bin/"*
printf 'registry\n' > "$base/prefix/system.reg"
printf 'registry\n' > "$base/prefix/user.reg"
for edition in Suite Standard; do
    live_fixture="$base/prefix/drive_c/ProgramData/Ableton/Live 12 $edition/Program/Ableton Live 12 $edition.exe"
    printf 'P\0r\0o\0d\0u\0c\0t\0V\0e\0r\0s\0i\0o\0n\0\0\0' > "$live_fixture"
    printf '1\0002\000.\0004\000.\0003\000\000\000' >> "$live_fixture"
done
sed "s#@BIN@#$base/home/.local/bin#g" "$here/../desktop/ableton-linux-protocol.desktop.in" \
    > "$base/data/ableton-wine/$protocol_id"
sed "s#@BIN@#$base/home/.local/bin#g" "$here/../desktop/ableton-linux-auz.desktop.in" \
    > "$base/data/ableton-wine/$auz_id"
cp "$base/data/ableton-wine/$protocol_id" "$base/data/applications/$protocol_id"
cp "$base/data/ableton-wine/$auz_id" "$base/data/applications/$auz_id"
printf '[Desktop Entry]\nExec=/usr/bin/foreign %%u\n' > "$base/data/applications/$protocol_id"
mkdir -p -- "$base/config/ableton-wine"
cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
linkd=$base/data/ableton-wine/ableton-linkd
EOF
: > "$base/wine.log"
if run_isolated "$base" env USER=test ABLETON_MAX_AUDIO_THREADS=64 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    'ableton://invalid-ableton-linux-probe' >"$base/invalid.out" 2>"$base/invalid.err"; then
    fail "The audio thread range check runs before Wine starts."
fi
grep -q 'Set ABLETON_MAX_AUDIO_THREADS to off or a number from one to 63' "$base/invalid.err" \
    || fail "The launcher reports the accepted audio thread values."
[ ! -s "$base/wine.log" ] || fail "The audio thread range check runs before Wine starts."

run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off ABLETON_THEME_MODE=preserve \
    ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 ABLETON_TEST_WINE_LOG="$base/wine.log" \
    bash "$here/ableton-live" 'ableton://invalid-ableton-linux-probe' >"$base/out" 2>"$base/err" || true
grep -qF "prefix=$base/prefix wine start /w ableton://invalid-ableton-linux-probe" "$base/wine.log" \
    || fail "protocol callback does not reach the prefix registry"
cmp -s "$base/data/ableton-wine/$protocol_id" "$base/data/applications/$protocol_id" \
    || fail "launcher does not repair its changed project handler"
! grep -q 'multiple Live 12 editions' "$base/err" \
    || fail "same-major Live discovery blocks the protocol callback"
callback_prefs="$base/prefix/drive_c/users/test/AppData/Roaming/Ableton/Live 12.4.3/Preferences"
[ ! -e "$callback_prefs/Options.txt" ] \
    || fail "A callback with the default launcher setting preserves Live's current audio thread count."

: > "$base/wine.log"
run_isolated "$base" env USER=test ABLETON_MAX_AUDIO_THREADS=16 ABLETON_POWER=off \
    ABLETON_RT=off ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    'ableton://invalid-ableton-linux-probe' >"$base/seed.out" 2>"$base/seed.err" || true
grep -qx -- '-MaxAudioThreads=16' "$callback_prefs/Options.txt" \
    || fail "A protocol callback that starts Live writes the requested count to the Live 12.4.3 settings."

rm -f -- "$callback_prefs/Options.txt" "$callback_prefs/.ableton-linux-max-audio-threads-v1"
rmdir -- "$callback_prefs" "${callback_prefs%/Preferences}" \
    "$base/prefix/drive_c/users/test/AppData/Roaming/Ableton"
license="$base/Authorize.auz"
: > "$license"
: > "$base/wine.log"
run_isolated "$base" env USER=test ABLETON_MAX_AUDIO_THREADS=16 ABLETON_POWER=off \
    ABLETON_RT=off ABLETON_THEME_MODE=preserve \
    ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 ABLETON_TEST_WINE_LOG="$base/wine.log" \
    bash "$here/ableton-live" "$license" >"$base/auz.out" 2>"$base/auz.err" || true
grep -qF "prefix=$base/prefix wine start /w /unix $license" "$base/wine.log" \
    || fail "The licence callback uses the selected Wine prefix."
grep -qx -- '-MaxAudioThreads=16' "$callback_prefs/Options.txt" \
    || fail "A licence callback that starts Live writes the requested count to the Live 12.4.3 settings."

rm -f -- "$callback_prefs/Options.txt" "$callback_prefs/.ableton-linux-max-audio-threads-v1"
rmdir -- "$callback_prefs" "${callback_prefs%/Preferences}" \
    "$base/prefix/drive_c/users/test/AppData/Roaming/Ableton"
mixed_fixture="$base/prefix/drive_c/ProgramData/Ableton/Live 12 Standard/Program/Ableton Live 12 Standard.exe"
printf 'P\0r\0o\0d\0u\0c\0t\0V\0e\0r\0s\0i\0o\0n\0\0\0' > "$mixed_fixture"
printf '1\0002\000.\0005\000.\0000\000\000\000' >> "$mixed_fixture"
: > "$base/wine.log"
run_isolated "$base" env USER=test ABLETON_LIVE_EXE="$mixed_fixture" \
    ABLETON_MAX_AUDIO_THREADS=16 ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve \
    ABLETON_TEXT_SMOOTHING=preserve ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    'ableton://invalid-ableton-linux-probe' >"$base/mixed.out" 2>"$base/mixed.err" || true
grep -qF "prefix=$base/prefix wine start /w ableton://invalid-ableton-linux-probe" "$base/wine.log" \
    || fail "An ambiguous callback no longer reaches the prefix registry."
grep -q 'callback does not identify one Live 12 version' "$base/mixed.err" \
    || fail "An ambiguous callback does not explain how to apply the requested audio thread count."
[ ! -e "$callback_prefs/Options.txt" ] \
    && [ ! -e "$base/prefix/drive_c/users/test/AppData/Roaming/Ableton/Live 12.5.0/Preferences/Options.txt" ] \
    || fail "An ambiguous callback writes audio thread settings for an edition the registry may not launch."
ok "Callback launches use the selected Wine prefix. They preserve the Ableton protocol handlers. The default launcher setting preserves Live's current audio thread count. A requested count reaches shared-version settings. Mixed-version callbacks leave edition selection and settings unchanged."

printf 'PASS: %s desktop integration checks\n' "$pass"
