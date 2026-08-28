#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-launcher-transaction-test.XXXXXX")"
declare -a cleanup_pids=()

cleanup()
{
    local pid
    for pid in "${cleanup_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf -- "$work"
}
trap cleanup EXIT

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
    local base="$work/$1"
    mkdir -p -- "$base/home" "$base/tmp" "$base/fakebin"
    printf '%s\n' "$base"
}

run_isolated()
{
    local base="$1"; shift
    env HOME="$base/home" XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data" \
        XDG_STATE_HOME="$base/state" XDG_CACHE_HOME="$base/cache" \
        XDG_RUNTIME_DIR="$base/run" TMPDIR="$base/tmp" \
        ABLETON_SHORTCUTS=preserve ABLETON_MAX_AUDIO_THREADS=off \
        PATH="$base/fakebin:/usr/bin:/bin" "$@"
}

protocol_id=io.github.shibco.ableton-linux.protocol.desktop
auz_id=io.github.shibco.ableton-linux.auz.desktop

prepare_fixture()
{
    local base="$1" live_exe
    mkdir -p -- "$base/runtime/bin" \
        "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program" \
        "$base/prefix/drive_c/Program Files/Cycling '74/Max 9" \
        "$base/data/ableton-wine" "$base/data/applications" \
        "$base/config/ableton-wine" "$base/state/ableton-wine" "$base/run"
    cp -- /bin/sleep "$base/runtime/bin/wine-client"
    cat > "$base/runtime/bin/wine" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' taskkill '*)
        [ -z "${ABLETON_TEST_TASKKILL_LOG:-}" ] \
            || printf 'taskkill %s\n' "$*" >> "$ABLETON_TEST_TASKKILL_LOG"
        exit 0 ;;
esac
printf 'wine %s\n' "$*" >> "${ABLETON_TEST_WINE_LOG:?}"
if [ "${1:-}" = reg ]; then
    # Real reg.exe brings up a wineserver which inherits the transaction token
    # and remains observable until wineserver -k. Model that ownership contract
    # so successful tests exercise the launcher's tagged-process allowlist.
    if [ -n "${ABLETON_DPI_TRANSACTION:-}" ]; then
        tagged_pid_file="${ABLETON_TEST_WINE_LOG}.tagged-pid"
        tagged_pid="$(cat "$tagged_pid_file" 2>/dev/null || true)"
        if [ -z "$tagged_pid" ] || ! kill -0 "$tagged_pid" 2>/dev/null; then
            env WINEPREFIX="${WINEPREFIX:?}" \
                ABLETON_DPI_TRANSACTION="$ABLETON_DPI_TRANSACTION" \
                "${0%/*}/wine-client" 60 &
            printf '%s\n' "$!" > "$tagged_pid_file"
        fi
    fi
    case " $* " in
        *' dpiAwareness '*)
            if [ -n "${ABLETON_TEST_REG_FOREIGN_PID_FILE:-}" ]; then
                env -u ABLETON_DPI_TRANSACTION WINEPREFIX="${WINEPREFIX:?}" \
                    "${0%/*}/wine-client" 60 &
                printf '%s\n' "$!" > "$ABLETON_TEST_REG_FOREIGN_PID_FILE"
            fi ;;
    esac
    [ "${ABLETON_TEST_REG_FAIL:-0}" -ne 1 ] || exit 77
    exit 0
fi
if [ -n "${ABLETON_TEST_APP_IMAGE:-}" ]; then
    printf '%s\n' "$$" > "${ABLETON_TEST_APP_PID_FILE:?}"
    exec -a "$ABLETON_TEST_APP_IMAGE" "${0%/*}/wine-client" 60
fi
if [ "${ABLETON_TEST_UNOBSERVABLE_WINE:-0}" -eq 1 ]; then
    exec /bin/sleep 60
fi
exit 0
EOF
cat > "$base/runtime/bin/wineserver" <<'EOF'
#!/usr/bin/env bash
printf 'wineserver %s\n' "$*" >> "${ABLETON_TEST_WINE_LOG:?}"
tagged_pid_file="${ABLETON_TEST_WINE_LOG}.tagged-pid"
tagged_pid="$(cat "$tagged_pid_file" 2>/dev/null || true)"
if [ "${1:-}" = -k ] && [ -n "$tagged_pid" ]; then
    kill "$tagged_pid" 2>/dev/null || true
    : > "$tagged_pid_file"
fi
[ "${1:-}" != -w ] || [ "${ABLETON_TEST_WINESERVER_WAIT_FAIL:-0}" -ne 1 ] || exit 78
exit 0
EOF
    cat > "$base/runtime/bin/wineboot" <<'EOF'
#!/bin/sh
printf 'wineboot %s\n' "$*" >> "${ABLETON_TEST_WINE_LOG:?}"
[ "${ABLETON_TEST_WINEBOOT_FAIL:-0}" -ne 1 ] || exit 79
exit 0
EOF
    printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/winepath"
    cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${XDG_CONFIG_HOME:?}/mimeapps.list"
case "${1:-}" in
    query)
        [ "${2:-}" = default ] && [ "$#" -eq 3 ]
        awk -F '=' -v type="$3" '$1 == type { value=$2 } END { print value }' \
            "$state" 2>/dev/null || true ;;
    default)
        [ "$#" -ge 3 ]
        [ -z "${ABLETON_TEST_MIME_DEFAULT_LOG:-}" ] \
            || printf '%s\n' "$XDG_CONFIG_HOME" >> "$ABLETON_TEST_MIME_DEFAULT_LOG"
        [ "${ABLETON_TEST_MIME_DEFAULT_FAIL:-0}" -ne 1 ] || exit 77
        application="$2"
        shift 2
        mkdir -p -- "$(dirname "$state")"
        touch "$state"
        for type in "$@"; do
            awk -F '=' -v type="$type" '$1 != type' "$state" > "$state.tmp"
            printf '%s=%s\n' "$type" "$application" >> "$state.tmp"
            mv -f -- "$state.tmp" "$state"
        done
        ;;
    *) exit 2 ;;
esac
EOF
    cat > "$base/fakebin/update-desktop-database" <<'EOF'
#!/bin/sh
[ "${ABLETON_TEST_DESKTOP_DATABASE_FAIL:-0}" -ne 1 ]
EOF
    for tool in update-mime-database gtk-update-icon-cache; do
        printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/$tool"
    done
    chmod +x "$base/runtime/bin/"* "$base/fakebin/"*
    printf 'registry\n' > "$base/prefix/system.reg"
    printf 'registry\n' > "$base/prefix/user.reg"
    live_exe="$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe"
    printf 'exe\n' > "$live_exe"
    printf 'exe\n' > "$base/prefix/drive_c/Program Files/Cycling '74/Max 9/Max.exe"
    cp -- "$here/detect-scale.sh" "$base/data/ableton-wine/detect-scale.sh"
    sed "s#@BIN@#$base/home/.local/bin#g" "$here/../desktop/ableton-linux-protocol.desktop.in" \
        > "$base/data/ableton-wine/$protocol_id"
    sed "s#@BIN@#$base/home/.local/bin#g" "$here/../desktop/ableton-linux-auz.desktop.in" \
        > "$base/data/ableton-wine/$auz_id"
    cp -- "$base/data/ableton-wine/$protocol_id" "$base/data/applications/$protocol_id"
    cp -- "$base/data/ableton-wine/$auz_id" "$base/data/applications/$auz_id"
    cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
linkd=$base/data/ableton-wine/ableton-linkd
EOF
    printf 'format=1\nowner=ableton-linux\n' > "$base/state/ableton-wine/.ableton-linux-state"
    cat > "$base/config/mimeapps.list" <<EOF
x-scheme-handler/ableton=$protocol_id
application/x-wine-extension-auz=$auz_id
EOF
}

run_live()
{
    local base="$1"; shift
    run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
        ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve \
        ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
        ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
        ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" "$@"
}

# Mutter exposes mixed logical monitors to Xwayland through one framebuffer at
# the highest active integer scale. The GNOME detector must therefore not
# follow a 100% primary while a fractional secondary has doubled X11 space.
base="$(new_env mixed-gnome-dpi)"
cat > "$base/fakebin/gdbus" <<'EOF'
#!/bin/sh
printf '%s\n' "${ABLETON_TEST_GNOME_STATE:?}"
EOF
chmod +x "$base/fakebin/gdbus"
gnome_state='([(0, 0, 1.0, uint32 0, true, "DP-1"), (-1920, 480, 1.3333333333333333, 0, false, "eDP-1")],)'
detected="$(run_isolated "$base" env ABLETON_TEST_GNOME_STATE="$gnome_state" \
    bash -c '. "$1"; ableton_detect_scale_ex' _ "$here/detect-scale.sh" \
    2>"$base/detect.err")"
[ "$detected" = '1.33333 gnome' ] \
    || fail "GNOME mixed-scale detection followed the primary instead of Xwayland's shared framebuffer"
block="$(run_isolated "$base" bash -c \
    '. "$1"; ableton_dpi_block_for_scale 1.33333 gnome' _ "$here/detect-scale.sh")"
[ "$block" = fractional ] \
    || fail "GNOME mixed-scale detection did not select the doubled-framebuffer DPI block"
grep -qxF 'note: monitors run mixed scales (1.0 1.3333333333333333).' \
    "$base/detect.err" || fail "GNOME mixed-scale detection did not list the active scales cleanly"
grep -qxF "note: using GNOME/Xwayland's shared framebuffer scale: 1.3333333333333333." \
    "$base/detect.err" || fail "GNOME mixed-scale detection did not explain its global choice"
awk 'length > 80 { exit 1 }' "$base/detect.err" \
    || fail "GNOME mixed-scale diagnostics exceed the terminal-friendly line width"
ok "GNOME mixed scales follow Xwayland's shared framebuffer"

# Changing LogPixels through reg.exe starts Wine under the old value. A cold
# launcher must stop that owned session, wait, and only then wineboot and Live.
base="$(new_env coherent-dpi-transaction)"
prepare_fixture "$base"
: > "$base/wine.log"
cat > "$base/fakebin/gdbus" <<'EOF'
#!/bin/sh
printf '%s\n' "${ABLETON_TEST_GNOME_STATE:?}"
EOF
cat > "$base/fakebin/gsettings" <<'EOF'
#!/bin/sh
printf '%s\n' "['scale-monitor-framebuffer', 'xwayland-native-scaling']"
EOF
chmod +x "$base/fakebin/gdbus" "$base/fakebin/gsettings"
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=auto \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_GNOME_STATE="$gnome_state" \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' \
    ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err" &
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
[ -s "$base/app.pid" ] || fail "coherent DPI transaction did not reach Live"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
reg_lp_line="$(grep -nF 'wine reg add HKCU\Control Panel\Desktop /v LogPixels /t REG_DWORD /d 192 /f' "$base/wine.log" | cut -d: -f1 || true)"
reg_ifeo_line="$(grep -nF 'wine reg add HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 12 Suite.exe /v dpiAwareness /t REG_DWORD /d 2 /f' "$base/wine.log" | cut -d: -f1 || true)"
stop_line="$(grep -nF 'wineserver -k' "$base/wine.log" | cut -d: -f1 || true)"
wait_line="$(grep -nF 'wineserver -w' "$base/wine.log" | cut -d: -f1 || true)"
boot_line="$(grep -nF 'wineboot -u' "$base/wine.log" | cut -d: -f1 || true)"
live_line="$(grep -nF 'wine C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe' "$base/wine.log" | cut -d: -f1 || true)"
if [ -z "$reg_lp_line" ] || [ -z "$reg_ifeo_line" ] || [ -z "$stop_line" ] \
   || [ -z "$wait_line" ] || [ -z "$boot_line" ] || [ -z "$live_line" ] \
   || [ "$reg_lp_line" -ge "$reg_ifeo_line" ] || [ "$reg_ifeo_line" -ge "$stop_line" ] \
   || [ "$stop_line" -ge "$wait_line" ] || [ "$wait_line" -ge "$boot_line" ] \
   || [ "$boot_line" -ge "$live_line" ]; then
    fail "DPI registry writes, Wine restart, boot, and Live launch were not coherently ordered"
fi
kill "$app_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
ok "a changed DPI block restarts the owned Wine session before Live"

# Every failure after the first registry write must leave the reseed marker in
# place. A later launch may then finish a coherent boot; it must never mistake
# partial registry, failed wait, or failed boot state for a completed transition.
for dpi_failure in registry wait boot; do
    base="$(new_env "dpi-$dpi_failure-failure")"
    prepare_fixture "$base"
    : > "$base/wine.log"
    case "$dpi_failure" in
        registry) failure_env=ABLETON_TEST_REG_FAIL=1 ;;
        wait)     failure_env=ABLETON_TEST_WINESERVER_WAIT_FAIL=1 ;;
        boot)     failure_env=ABLETON_TEST_WINEBOOT_FAIL=1 ;;
    esac
    if run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
        ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
        ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
        ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
        "$failure_env" ABLETON_TEST_WINE_LOG="$base/wine.log" \
        bash "$here/ableton-live" >"$base/out" 2>"$base/err"; then
        fail "$dpi_failure failure allowed Live to launch"
    fi
    reseed_marker="$base/prefix/.ableton-linux-dpi-reseed-required"
    [ -n "$reseed_marker" ] && [ -f "$reseed_marker" ] \
        || fail "$dpi_failure failure discarded the pending DPI reseed marker"
    grep -qF 'wine reg add HKCU\Control Panel\Desktop' "$base/wine.log" \
        || fail "$dpi_failure failure fixture never entered the DPI transaction"
    if grep -qF 'wine C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe' \
        "$base/wine.log"; then
        fail "$dpi_failure failure continued into Live"
    fi
    case "$dpi_failure" in
        registry|wait)
            if grep -qF 'wineboot -u' "$base/wine.log"; then
                fail "$dpi_failure failure continued into wineboot"
            fi ;;
        boot)
            grep -qF 'wineboot -u' "$base/wine.log" \
                || fail "wineboot failure fixture did not reach wineboot" ;;
    esac
done
ok "DPI write, wait, and boot failures retain the coherent-reseed fence"

# Auto-detection is not permission to keep the GNOME fractional block when
# Mutter says native Xwayland scaling is off. Select the coherent 100% block
# and apply it through the same atomic restart transaction.
base="$(new_env gnome-auto-native-scaling-off)"
prepare_fixture "$base"
cat > "$base/prefix/user.reg" <<'EOF'
[Control Panel\\Desktop]
"LogPixels"=dword:000000c0
EOF
cat > "$base/prefix/system.reg" <<'EOF'
[Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Ableton Live 12 Suite.exe]
"dpiAwareness"=dword:00000002
EOF
cat > "$base/fakebin/gdbus" <<'EOF'
#!/bin/sh
printf '%s\n' "${ABLETON_TEST_GNOME_STATE:?}"
EOF
cat > "$base/fakebin/gsettings" <<'EOF'
#!/bin/sh
printf '%s\n' "['scale-monitor-framebuffer']"
EOF
chmod +x "$base/fakebin/gdbus" "$base/fakebin/gsettings"
: > "$base/wine.log"
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=auto \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_GNOME_STATE="$gnome_state" \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' \
    ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err" &
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
[ -s "$base/app.pid" ] || fail "GNOME feature-off auto mode did not reach Live"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
grep -qF 'wine reg add HKCU\Control Panel\Desktop /v LogPixels /t REG_DWORD /d 96 /f' \
    "$base/wine.log" || fail "GNOME feature-off auto mode did not select 96 DPI"
grep -qF 'wine reg delete HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 12 Suite.exe /v dpiAwareness /f' \
    "$base/wine.log" || fail "GNOME feature-off auto mode retained the fractional IFEO"
grep -qF 'wineserver -k' "$base/wine.log" \
    || fail "GNOME feature-off transition did not restart Wine"
grep -qF 'wineboot -u' "$base/wine.log" \
    || fail "GNOME feature-off transition did not coherently boot Wine"
grep -qF 'GNOME xwayland-native-scaling is OFF; selecting the coherent 100% DPI block.' "$base/err" \
    || fail "GNOME feature-off auto mode did not explain its coherent fallback"
kill "$app_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
ok "GNOME auto mode selects a coherent DPI block when native scaling is off"

# A missing settings client is not evidence that Mutter's required feature is
# enabled. With no provably coherent automatic block, refuse before Wine and
# require an explicit user policy.
base="$(new_env gnome-auto-no-gsettings)"
prepare_fixture "$base"
cat > "$base/fakebin/gdbus" <<'EOF'
#!/bin/sh
printf '%s\n' "${ABLETON_TEST_GNOME_STATE:?}"
EOF
cat > "$base/no-gsettings.bash" <<'EOF'
command()
{
    if [ "${1:-}" = -v ] && [ "${2:-}" = gsettings ]; then return 1; fi
    builtin command "$@"
}
EOF
chmod +x "$base/fakebin/gdbus"
: > "$base/wine.log"
: > "$base/taskkill.log"
if run_isolated "$base" env USER=test BASH_ENV="$base/no-gsettings.bash" \
    ABLETON_POWER=off ABLETON_RT=off ABLETON_THEME_MODE=preserve \
    ABLETON_DPI_MODE=auto ABLETON_UI_FONT=preserve \
    ABLETON_TEXT_SMOOTHING=preserve ABLETON_TOPBAR_MODE=preserve \
    ABLETON_LAUNCH_TIMEOUT=5 ABLETON_TEST_GNOME_STATE="$gnome_state" \
    ABLETON_TEST_TASKKILL_LOG="$base/taskkill.log" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "GNOME auto mode launched without verifying native Xwayland scaling"
fi
[ ! -s "$base/wine.log" ] \
    || fail "GNOME unverifiable-feature refusal started Wine"
[ ! -s "$base/taskkill.log" ] \
    || fail "GNOME unverifiable-feature refusal ran prefix teardown"
[ ! -e "$base/prefix/.ableton-linux-dpi-reseed-required" ] \
    || fail "GNOME unverifiable-feature refusal created a DPI transaction marker"
grep -qF 'GNOME xwayland-native-scaling could not be verified, so Live was not started.' "$base/err" \
    || fail "GNOME auto mode did not report its unverifiable-feature refusal"
ok "GNOME auto mode refuses when native scaling cannot be verified"

# Exercise the production regression direction too: a persisted fractional
# block returning to 100% must delete the IFEO value before the same restart.
base="$(new_env coherent-dpi-reverse-transaction)"
prepare_fixture "$base"
cat > "$base/prefix/user.reg" <<'EOF'
[Control Panel\\Desktop]
"LogPixels"=dword:000000c0
EOF
cat > "$base/prefix/system.reg" <<'EOF'
[Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Ableton Live 12 Suite.exe]
"dpiAwareness"=dword:00000002
EOF
: > "$base/wine.log"
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=100 \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' \
    ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err" &
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
[ -s "$base/app.pid" ] || fail "reverse DPI transaction did not reach Live"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
reg_lp_line="$(grep -nF 'wine reg add HKCU\Control Panel\Desktop /v LogPixels /t REG_DWORD /d 96 /f' "$base/wine.log" | cut -d: -f1 || true)"
reg_ifeo_line="$(grep -nF 'wine reg delete HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 12 Suite.exe /v dpiAwareness /f' "$base/wine.log" | cut -d: -f1 || true)"
stop_line="$(grep -nF 'wineserver -k' "$base/wine.log" | cut -d: -f1 || true)"
wait_line="$(grep -nF 'wineserver -w' "$base/wine.log" | cut -d: -f1 || true)"
boot_line="$(grep -nF 'wineboot -u' "$base/wine.log" | cut -d: -f1 || true)"
live_line="$(grep -nF 'wine C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe' "$base/wine.log" | cut -d: -f1 || true)"
if [ -z "$reg_lp_line" ] || [ -z "$reg_ifeo_line" ] || [ -z "$stop_line" ] \
   || [ -z "$wait_line" ] || [ -z "$boot_line" ] || [ -z "$live_line" ] \
   || [ "$reg_lp_line" -ge "$reg_ifeo_line" ] || [ "$reg_ifeo_line" -ge "$stop_line" ] \
   || [ "$stop_line" -ge "$wait_line" ] || [ "$wait_line" -ge "$boot_line" ] \
   || [ "$boot_line" -ge "$live_line" ]; then
    fail "reverse DPI registry writes, restart, boot, and Live launch were not coherently ordered"
fi
kill "$app_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
ok "the 192-to-96 DPI transition restarts before Live"

# A cold callback has no selected edition, but its prefix association can start
# any installed Live. An IFEO-only drift must therefore transact every target.
base="$(new_env cold-callback-adds-ifeo)"
prepare_fixture "$base"
mkdir -p -- "$base/prefix/drive_c/ProgramData/Ableton/Live 11 Standard/Program"
printf 'exe\n' > "$base/prefix/drive_c/ProgramData/Ableton/Live 11 Standard/Program/Ableton Live 11 Standard.exe"
cat > "$base/prefix/user.reg" <<'EOF'
[Control Panel\\Desktop]
"LogPixels"=dword:000000c0
EOF
cat > "$base/prefix/system.reg" <<'EOF'
[Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Ableton Live 12 Suite.exe]
"dpiAwareness"=dword:00000002
EOF
: > "$base/wine.log"
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_LIVE_VERSION=12 \
    ABLETON_LIVE_EXE="$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe" \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' \
    ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    'ableton://dpi-transition' >"$base/out" 2>"$base/err" &
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
[ -s "$base/app.pid" ] || fail "cold callback did not repair its missing Live IFEO"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
grep -qF 'wine reg add HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 12 Suite.exe /v dpiAwareness /t REG_DWORD /d 2 /f' \
    "$base/wine.log" || fail "cold callback left the Live IFEO half-configured"
grep -qF 'wine reg add HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 11 Standard.exe /v dpiAwareness /t REG_DWORD /d 2 /f' \
    "$base/wine.log" || fail "cold callback obeyed edition selectors instead of repairing every possible callback target"
grep -qF 'wineserver -k' "$base/wine.log" \
    || fail "cold callback IFEO repair did not restart Wine"
grep -qF 'wineboot -u' "$base/wine.log" \
    || fail "cold callback IFEO repair did not boot the coherent block"
grep -qF 'wine start /w ableton://dpi-transition' "$base/wine.log" \
    || fail "cold callback did not continue after coherent DPI repair"
kill "$app_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
ok "cold callbacks repair missing Live IFEO state before dispatch"

# The inverse callback half-state is equally dangerous: a 96-DPI prefix with a
# stale PMv2 IFEO override must delete it before dispatching the callback.
base="$(new_env cold-callback-removes-ifeo)"
prepare_fixture "$base"
cat > "$base/prefix/user.reg" <<'EOF'
[Control Panel\\Desktop]
"LogPixels"=dword:00000060
EOF
cat > "$base/prefix/system.reg" <<'EOF'
[Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Ableton Live 12 Suite.exe]
"dpiAwareness"=dword:00000002
EOF
: > "$base/wine.log"
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=100 \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' \
    ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    'ableton://dpi-transition-back' >"$base/out" 2>"$base/err" &
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
[ -s "$base/app.pid" ] || fail "cold callback did not remove its stale Live IFEO"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
grep -qF 'wine reg delete HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 12 Suite.exe /v dpiAwareness /f' \
    "$base/wine.log" || fail "cold callback retained its stale Live IFEO"
grep -qF 'wineserver -k' "$base/wine.log" \
    || fail "cold callback stale-IFEO repair did not restart Wine"
grep -qF 'wineboot -u' "$base/wine.log" \
    || fail "cold callback stale-IFEO repair did not boot the coherent block"
grep -qF 'wine start /w ableton://dpi-transition-back' "$base/wine.log" \
    || fail "cold callback did not continue after stale-IFEO repair"
kill "$app_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
ok "cold callbacks remove stale Live IFEO state before dispatch"

# A shared prefix cannot be restarted merely to apply a new DPI block. Refuse
# without writing registry state or ending the existing client.
base="$(new_env busy-dpi-refusal)"
prepare_fixture "$base"
: > "$base/wine.log"
: > "$base/taskkill.log"
mkdir -p -- "$base/foreign-runtime/bin"
cp -- /bin/sleep "$base/foreign-runtime/bin/wine"
env WINEPREFIX="$base/prefix" "$base/foreign-runtime/bin/wine" 60 &
holder_pid=$!
cleanup_pids+=("$holder_pid")
sleep 0.2
if run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" \
    ABLETON_TEST_TASKKILL_LOG="$base/taskkill.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "launcher changed DPI while another prefix client was running"
fi
kill -0 "$holder_pid" 2>/dev/null \
    || fail "DPI refusal ended the pre-existing prefix client"
[ ! -s "$base/wine.log" ] \
    || fail "DPI refusal started Wine or wrote registry state in the busy prefix"
[ ! -s "$base/taskkill.log" ] \
    || fail "DPI refusal ran session teardown against the busy prefix"
grep -qF 'close Max or the other prefix program' "$base/err" \
    || fail "busy DPI refusal did not explain how to retry safely"
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
ok "a changed DPI block never restarts a shared Wine prefix"

# If an uncoordinated Wine client appears after the registry writes, do not
# kill it. Persist the pending reseed, refuse Live, and complete only after the
# prefix becomes idle—even though the persistent values then look matched.
base="$(new_env interrupted-dpi-reseed)"
prepare_fixture "$base"
: > "$base/wine.log"
: > "$base/taskkill.log"
if run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_REG_FOREIGN_PID_FILE="$base/foreign.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" \
    ABLETON_TEST_TASKKILL_LOG="$base/taskkill.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "DPI transaction launched after an uncoordinated prefix client entered"
fi
[ -s "$base/foreign.pid" ] || fail "DPI race fixture did not create its foreign holder"
holder_pid="$(cat "$base/foreign.pid")"
cleanup_pids+=("$holder_pid")
kill -0 "$holder_pid" 2>/dev/null \
    || fail "DPI transaction killed the uncoordinated prefix client"
if grep -Eq 'wineserver |wineboot |wine C:\\ProgramData' "$base/wine.log"; then
    fail "interrupted DPI transaction stopped, booted, or launched into the contested prefix"
fi
[ ! -s "$base/taskkill.log" ] \
    || fail "interrupted DPI transaction ran EXIT teardown against the contested prefix"
reseed_marker="$base/prefix/.ableton-linux-dpi-reseed-required"
[ -n "$reseed_marker" ] && [ -f "$reseed_marker" ] \
    || fail "interrupted DPI transaction did not preserve its required-reseed marker"
cat > "$base/prefix/user.reg" <<'EOF'
[Control Panel\\Desktop]
"LogPixels"=dword:000000c0
EOF
cat > "$base/prefix/system.reg" <<'EOF'
[Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Ableton Live 12 Suite.exe]
"dpiAwareness"=dword:00000002
EOF
: > "$base/wine.log"
: > "$base/taskkill.log"
if run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" \
    ABLETON_TEST_TASKKILL_LOG="$base/taskkill.log" bash "$here/ableton-live" \
    >"$base/busy-retry.out" 2>"$base/busy-retry.err"; then
    fail "pending matched DPI state launched while its stale Wine session was still busy"
fi
kill -0 "$holder_pid" 2>/dev/null \
    || fail "pending DPI retry ended the client keeping its stale session alive"
[ ! -s "$base/wine.log" ] \
    || fail "pending matched DPI retry touched Wine before the prefix became idle"
[ ! -s "$base/taskkill.log" ] \
    || fail "pending matched DPI retry ran EXIT teardown against the busy prefix"
[ -f "$reseed_marker" ] \
    || fail "busy retry discarded the pending DPI reseed marker"
grep -qF 'waiting for a safe prefix restart' "$base/busy-retry.err" \
    || fail "busy pending-DPI retry did not explain the required restart"
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
tagged_pid="$(cat "$base/wine.log.tagged-pid" 2>/dev/null || true)"
if [ -n "$tagged_pid" ]; then
    kill "$tagged_pid" 2>/dev/null || true
fi
: > "$base/wine.log"
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' \
    ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/retry.out" 2>"$base/retry.err" &
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
[ -s "$base/app.pid" ] || fail "idle retry did not finish the pending DPI reseed"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
grep -qF 'wineboot -u' "$base/wine.log" \
    || fail "pending matched DPI state did not reseed Wine before Live"
if grep -Eq 'wine reg |wineserver -k' "$base/wine.log"; then
    fail "pending matched DPI retry rewrote registry state or killed an idle prefix"
fi
[ ! -e "$reseed_marker" ] \
    || fail "successful coherent boot retained the pending DPI marker"
kill "$app_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
ok "interrupted DPI changes stay pending until an idle coherent boot"

# A pending reseed belongs to the prefix across Wine upgrades. A holder from an
# older runtime must not become invisible merely because the current launcher's
# bring-up lock uses a new runtime generation.
base="$(new_env cross-runtime-pending-dpi-reseed)"
prepare_fixture "$base"
cat > "$base/prefix/user.reg" <<'EOF'
[Control Panel\\Desktop]
"LogPixels"=dword:000000c0
EOF
cat > "$base/prefix/system.reg" <<'EOF'
[Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Ableton Live 12 Suite.exe]
"dpiAwareness"=dword:00000002
EOF
reseed_marker="$base/prefix/.ableton-linux-dpi-reseed-required"
: > "$reseed_marker"
: > "$base/wine.log"
: > "$base/taskkill.log"
mkdir -p -- "$base/old-runtime/bin"
cp -- /bin/sleep "$base/old-runtime/bin/wine"
env WINEPREFIX="$base/prefix" "$base/old-runtime/bin/wine" 60 &
holder_pid=$!
cleanup_pids+=("$holder_pid")
sleep 0.2
if run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" \
    ABLETON_TEST_TASKKILL_LOG="$base/taskkill.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "runtime upgrade hid the prefix's pending DPI reseed"
fi
kill -0 "$holder_pid" 2>/dev/null \
    || fail "cross-runtime pending-DPI refusal ended the old runtime holder"
[ ! -s "$base/wine.log" ] \
    || fail "cross-runtime pending-DPI refusal started the new Wine runtime"
[ ! -s "$base/taskkill.log" ] \
    || fail "cross-runtime pending-DPI refusal ran teardown against the old runtime"
[ -f "$reseed_marker" ] \
    || fail "cross-runtime pending-DPI refusal discarded the prefix fence"
grep -qF 'waiting for a safe prefix restart' "$base/err" \
    || fail "cross-runtime pending-DPI refusal did not explain the required restart"
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
ok "pending DPI reseeds survive Wine runtime changes"

# The prefix fence is never allowed to follow a symlink. Refuse both a dangling
# link and a link to an existing file before Wine, and leave the target intact.
for marker_shape in dangling existing-target; do
    base="$(new_env "unsafe-dpi-marker-$marker_shape")"
    prepare_fixture "$base"
    : > "$base/wine.log"
    : > "$base/taskkill.log"
    marker="$base/prefix/.ableton-linux-dpi-reseed-required"
    if [ "$marker_shape" = dangling ]; then
        ln -s -- "$base/missing-marker-target" "$marker"
    else
        printf 'do not overwrite\n' > "$base/marker-target"
        ln -s -- "$base/marker-target" "$marker"
    fi
    if run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
        ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
        ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
        ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
        ABLETON_TEST_WINE_LOG="$base/wine.log" \
        ABLETON_TEST_TASKKILL_LOG="$base/taskkill.log" bash "$here/ableton-live" \
        >"$base/out" 2>"$base/err"; then
        fail "$marker_shape DPI marker symlink was accepted"
    fi
    [ ! -s "$base/wine.log" ] \
        || fail "$marker_shape DPI marker refusal started Wine"
    [ ! -s "$base/taskkill.log" ] \
        || fail "$marker_shape DPI marker refusal ran prefix teardown"
    grep -qF 'DPI reseed marker is not a regular file' "$base/err" \
        || fail "$marker_shape DPI marker refusal did not identify the unsafe path"
    if [ "$marker_shape" = existing-target ]; then
        grep -qxF 'do not overwrite' "$base/marker-target" \
            || fail "DPI marker symlink target was overwritten"
    fi
done
ok "DPI reseed fences never follow symlinks"

# Exercise the creation-failure branch after its initial path validation. The
# launcher still owns no Wine session, so failure must not invoke EXIT teardown.
base="$(new_env dpi-marker-publication-failure)"
prepare_fixture "$base"
cat > "$base/fakebin/gdbus" <<'EOF'
#!/bin/sh
mkdir -p -- "${WINEPREFIX:?}/.ableton-linux-dpi-reseed-required"
printf '%s\n' "${ABLETON_TEST_GNOME_STATE:?}"
EOF
cat > "$base/fakebin/gsettings" <<'EOF'
#!/bin/sh
printf '%s\n' "['scale-monitor-framebuffer', 'xwayland-native-scaling']"
EOF
chmod +x "$base/fakebin/gdbus" "$base/fakebin/gsettings"
: > "$base/wine.log"
: > "$base/taskkill.log"
if run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=auto \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_GNOME_STATE="$gnome_state" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" \
    ABLETON_TEST_TASKKILL_LOG="$base/taskkill.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "DPI marker publication failure was accepted"
fi
[ ! -s "$base/wine.log" ] \
    || fail "DPI marker publication failure started Wine"
[ ! -s "$base/taskkill.log" ] \
    || fail "DPI marker publication failure ran prefix teardown"
grep -qF 'safe restart marker could not be written' "$base/err" \
    || fail "DPI marker publication failure was not explained"
ok "DPI marker publication failure disarms pre-Wine teardown"

# Sharing remains supported when registry state already matches: do not turn
# the destructive-restart guard into a blanket ban on Live beside Max.
base="$(new_env busy-matching-dpi)"
prepare_fixture "$base"
: > "$base/wine.log"
env WINEPREFIX="$base/prefix" "$base/runtime/bin/wine-client" 60 &
holder_pid=$!
cleanup_pids+=("$holder_pid")
sleep 0.2
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=100 \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' \
    ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err" &
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
[ -s "$base/app.pid" ] || fail "matching DPI state blocked Live in a shared prefix"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
kill -0 "$holder_pid" 2>/dev/null \
    || fail "matching DPI launch disturbed the pre-existing prefix client"
if grep -Eq 'wine reg |wineserver |wineboot ' "$base/wine.log"; then
    fail "matching DPI launch rewrote or restarted the shared prefix"
fi
grep -qF 'wine C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe' \
    "$base/wine.log" || fail "matching DPI launch did not reach Live"
kill "$app_pid" "$holder_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
ok "matching DPI state leaves a shared Wine prefix running"

# The same sharing contract applies to a coherent fractional block. Its PMv2
# IFEO must not be mistaken for drift merely because Wine is already active.
base="$(new_env busy-matching-fractional-dpi)"
prepare_fixture "$base"
cat > "$base/prefix/user.reg" <<'EOF'
[Control Panel\\Desktop]
"LogPixels"=dword:000000c0
EOF
cat > "$base/prefix/system.reg" <<'EOF'
[Software\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\Ableton Live 12 Suite.exe]
"dpiAwareness"=dword:00000002
EOF
: > "$base/wine.log"
env WINEPREFIX="$base/prefix" "$base/runtime/bin/wine-client" 60 &
holder_pid=$!
cleanup_pids+=("$holder_pid")
sleep 0.2
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=fractional \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' \
    ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err" &
launcher_pid=$!
cleanup_pids+=("$launcher_pid")
for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
[ -s "$base/app.pid" ] || fail "matching fractional DPI state blocked Live in a shared prefix"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
kill -0 "$holder_pid" 2>/dev/null \
    || fail "matching fractional launch disturbed the pre-existing prefix client"
if grep -Eq 'wine reg |wineserver |wineboot ' "$base/wine.log"; then
    fail "matching fractional launch rewrote or restarted the shared prefix"
fi
grep -qF 'wine C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe' \
    "$base/wine.log" || fail "matching fractional launch did not reach Live"
kill "$app_pid" "$holder_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
ok "matching fractional DPI leaves a shared Wine prefix running"

# Correct MIME defaults remain query-only. Drift in any project-generated
# handler, desktop entry, or callback default is overwritten authoritatively
# under the global launcher lock.
base="$(new_env authoritative-integration-repair)"
prepare_fixture "$base"
live_desktop="$base/data/applications/ableton-live.desktop"
printf '[Desktop Entry]\nName=My Local Live\nExec=/usr/bin/foreign %%f\nX-Foreign=true\n' \
    > "$live_desktop"
printf '[Desktop Entry]\nExec=/usr/bin/foreign %%u\n' \
    > "$base/data/applications/$protocol_id"
: > "$base/wine.log"
: > "$base/mime-default.log"
mime_before="$(sha256sum -- "$base/config/mimeapps.list" | awk '{print $1}')"
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve \
    ABLETON_TEXT_SMOOTHING=preserve ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_MIME_DEFAULT_LOG="$base/mime-default.log" ABLETON_TEST_WINE_LOG="$base/wine.log" \
    bash "$here/ableton-live" >"$base/out" 2>"$base/err" || true
[ ! -s "$base/mime-default.log" ] \
    || fail "launcher rewrites MIME defaults that already resolve correctly"
[ "$(sha256sum -- "$base/config/mimeapps.list" | awk '{print $1}')" = "$mime_before" ] \
    || fail "query-only MIME verification changed mimeapps.list"
cmp -s -- "$base/data/ableton-wine/$protocol_id" "$base/data/applications/$protocol_id" \
    || fail "launcher retained drift in its generated protocol handler"
if ! grep -qxF 'Name=Ableton Live 12 Suite' "$live_desktop" \
   || ! grep -qxF "Exec=$base/home/.local/bin/ableton-live %f" "$live_desktop" \
   || ! grep -qxF "Path=$base/prefix" "$live_desktop" \
   || ! grep -qxF 'StartupWMClass=ableton live 12 suite.exe' "$live_desktop" \
   || grep -q '^X-Foreign=' "$live_desktop"; then
    fail "launcher did not completely rebuild its drifted generated desktop entry"
fi
sed -i "s#^x-scheme-handler/ableton=.*#x-scheme-handler/ableton=foreign.desktop#" \
    "$base/config/mimeapps.list"
: > "$base/mime-default.log"
run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve \
    ABLETON_TEXT_SMOOTHING=preserve ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_MIME_DEFAULT_LOG="$base/mime-default.log" ABLETON_TEST_WINE_LOG="$base/wine.log" \
    bash "$here/ableton-live" 'ableton://authoritative-repair' >"$base/out" 2>"$base/err" || true
grep -qxF "x-scheme-handler/ableton=$protocol_id" "$base/config/mimeapps.list" \
    || fail "launcher retained drift in its generated protocol default"
grep -qxF "application/x-wine-extension-auz=$auz_id" "$base/config/mimeapps.list" \
    || fail "launcher MIME repair lost the AUZ default"
grep -qxF "$base/config" "$base/mime-default.log" \
    || fail "launcher did not repair MIME drift against the live configuration"
ok "launcher authoritatively overwrites generated desktop, handler, and MIME drift"

# Damaged installer settings must stop both launchers before they use any
# partially initialised path, with one actionable explanation rather than a
# secondary set -u/unbound-variable error.
base="$(new_env unreadable-installer-settings)"
prepare_fixture "$base"
printf 'not recognised\n' > "$base/config/ableton-wine/config"
: > "$base/wine.log"
if run_live "$base" >"$base/live.out" 2>"$base/live.err"; then
    fail "Live accepted unreadable installer settings"
fi
if run_isolated "$base" env ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/max9" \
    >"$base/max.out" 2>"$base/max.err"; then
    fail "Max accepted unreadable installer settings"
fi
grep -qxF 'ableton-live: installer settings could not be read. Run the latest installer to repair them, then try again.' \
    "$base/live.err" || fail "Live did not give one actionable settings error"
grep -qxF 'max9: installer settings could not be read. Run the latest installer to repair them, then try again.' \
    "$base/max.err" || fail "Max did not give one actionable settings error"
[ ! -s "$base/wine.log" ] || fail "a launcher started Wine with unreadable installer settings"
ok "Live and Max stop cleanly when installer settings cannot be read"

# Desktop integration remains ancillary. Exercise independent handler publish,
# MIME backend, desktop publish, and cache-refresh failures together; a healthy
# runtime and prefix must still reach an observable Wine child.
base="$(new_env ancillary-repair-failures)"
prepare_fixture "$base"
rm -f -- "$base/data/applications/$protocol_id" "$base/data/applications/$auz_id"
mkdir -p -- "$base/data/applications/$protocol_id" "$base/data/applications/ableton-live.desktop"
printf '[Desktop Entry]\nExec=/usr/bin/foreign %%f\n' > "$base/data/applications/$auz_id"
sed -i "s#^x-scheme-handler/ableton=.*#x-scheme-handler/ableton=foreign.desktop#" \
    "$base/config/mimeapps.list"
: > "$base/wine.log"
if ! run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve \
    ABLETON_TEXT_SMOOTHING=preserve ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_MIME_DEFAULT_FAIL=1 ABLETON_TEST_DESKTOP_DATABASE_FAIL=1 \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "ancillary integration repair failure blocked an otherwise healthy Live launch"
fi
[ -s "$base/app.pid" ] && [ -s "$base/wine.log" ] \
    || fail "ancillary integration repair failure prevented Wine from starting"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
grep -qF 'Live will start, but browser activation, file opening, or the application menu may need repair.' \
    "$base/err" || fail "ancillary integration failures were not reported in user-level language"
[ "$(grep -cF 'Live will start, but browser activation, file opening, or the application menu may need repair.' "$base/err")" -eq 1 ] \
    || fail "ancillary integration failures produced repeated warnings"
kill "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true
ok "ancillary integration repair failures warn and continue to Wine"

# Refusal is nonblocking and happens before the first diagnostic/state/handler
# write. Max observes the same user-wide lock.
base="$(new_env global-refusal)"
prepare_fixture "$base"
printf '[Desktop Entry]\nExec=/usr/bin/foreign %%u\n' > "$base/data/applications/$protocol_id"
rm -rf -- "$base/state"
: > "$base/wine.log"
exec {install_lock_fd}< "$base/home"
flock -n "$install_lock_fd" || fail "could not hold global launcher lock fixture"
if run_live "$base" 'ableton://locked' >"$base/live.out" 2>"$base/live.err"; then
    fail "Live waited for or bypassed an active installer"
fi
if run_isolated "$base" env ABLETON_POWER=off ABLETON_RT=off ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/max9" >"$base/max.out" 2>"$base/max.err"; then
    fail "Max waited for or bypassed an active installer"
fi
flock -u "$install_lock_fd"
exec {install_lock_fd}<&-
if ! grep -q 'installation work is in progress' "$base/live.err" \
   || ! grep -q 'installation work is in progress' "$base/max.err"; then
    fail "global-lock refusals did not explain the retry"
fi
[ ! -e "$base/state" ] || fail "refused Live launch created its diagnostic state before locking"
grep -qF 'Exec=/usr/bin/foreign %u' "$base/data/applications/$protocol_id" \
    || fail "refused Live launch repaired a handler"
[ ! -s "$base/wine.log" ] || fail "refused launcher started Wine"
ok "Live and Max refuse an installer before every managed launcher-side write"

# A crashed installer no longer owns the flock, but its active journal still
# binds exact host and prefix generations. Both launchers must refuse before
# self-heal or diagnostics can mutate that retained recovery state.
base="$(new_env active-recovery-refusal)"
prepare_fixture "$base"
retained_transaction="$base/state/ableton-wine/transactions/installer.retained"
mkdir -p -- "$retained_transaction"
: > "$retained_transaction/active"
printf '[Desktop Entry]\nExec=/usr/bin/foreign %%u\n' \
    > "$base/data/applications/$protocol_id"
sed -i 's#^x-scheme-handler/ableton=.*#x-scheme-handler/ableton=foreign.desktop#' \
    "$base/config/mimeapps.list"
: > "$base/wine.log"
if run_live "$base" 'ableton://retained-recovery' >"$base/live.out" 2>"$base/live.err"; then
    fail "Live launched while an unfinished installation transaction was retained"
fi
if run_isolated "$base" env ABLETON_POWER=off ABLETON_RT=off ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/max9" \
    >"$base/max.out" 2>"$base/max.err"; then
    fail "Max launched while an unfinished installation transaction was retained"
fi
if ! grep -qF "$retained_transaction" "$base/live.err" \
   || ! grep -qF "$retained_transaction" "$base/max.err"; then
    fail "retained-transaction refusals did not name the recovery directory"
fi
[ ! -e "$base/state/ableton-wine/logs/live.log" ] \
    || fail "retained-transaction refusal wrote a Live diagnostic log"
grep -qF 'Exec=/usr/bin/foreign %u' "$base/data/applications/$protocol_id" \
    || fail "retained-transaction refusal repaired a handler"
grep -qxF 'x-scheme-handler/ableton=foreign.desktop' "$base/config/mimeapps.list" \
    || fail "retained-transaction refusal rewrote MIME defaults"
[ ! -s "$base/wine.log" ] || fail "retained-transaction refusal started Wine"
ok "Live and Max refuse retained recovery before diagnostics, self-heal, or Wine"

# A completed core can leave its own cleanup directory behind. Its completion
# marker makes that stale active file informational, so cleanup failure cannot
# become a later launch failure.
base="$(new_env committed-cleanup-launch)"
prepare_fixture "$base"
retained_transaction="$base/state/ableton-wine/transactions/installer.committed"
mkdir -p -- "$retained_transaction/prefix-host"
: > "$retained_transaction/active"
: > "$retained_transaction/prefix-host/active"
printf 'format=1\ncore=complete\n' > "$retained_transaction/core-complete"
retained_prefix_transaction="$base/state/ableton-wine/transactions/installer.prefix-cleanup/prefix-host"
mkdir -p -- "$retained_prefix_transaction"
: > "$retained_prefix_transaction/active"
printf 'format=1\ncore=complete\n' > "$retained_prefix_transaction/core-complete"
: > "$base/wine.log"
if ! run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
    ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve \
    ABLETON_TEXT_SMOOTHING=preserve ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_APP_IMAGE='Ableton Live 12 Suite.exe' ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "committed cleanup files blocked Live"
fi
[ -s "$base/app.pid" ] && [ -s "$base/wine.log" ] \
    || fail "committed cleanup files prevented Wine from starting"
app_pid="$(cat "$base/app.pid")"
cleanup_pids+=("$app_pid")
kill "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true
ok "committed cleanup files never become a later launch gate"

# A pre-existing Max is not readiness evidence for this invocation. The new
# launch must expose the exact handoff token, and failure remains bounded.
base="$(new_env max-warm-spoof)"
prepare_fixture "$base"
: > "$base/wine.log"
max_holder="C:\\Program Files\\Cycling '74\\Max 9\\Max.exe"
# shellcheck disable=SC2016
env WINEPREFIX="$base/prefix" bash -c 'exec -a "$2" "$1" 60' \
    _ "$base/runtime/bin/wine-client" "$max_holder" &
max_holder_pid=$!
cleanup_pids+=("$max_holder_pid")
sleep 0.2
if run_isolated "$base" env ABLETON_POWER=off ABLETON_RT=off ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_UNOBSERVABLE_WINE=1 ABLETON_TEST_WINE_LOG="$base/wine.log" \
    bash "$here/max9" >"$base/out" 2>"$base/err"; then
    fail "pre-existing Max spoofed readiness for an unobservable new launch"
fi
kill -0 "$max_holder_pid" 2>/dev/null \
    || fail "failed Max handoff ended the pre-existing Max session"
grep -q 'Max did not start within 5s' "$base/err" \
    || fail "Max handoff failure was not bounded and explicit"
kill "$max_holder_pid" 2>/dev/null || true
wait "$max_holder_pid" 2>/dev/null || true
ok "Max readiness requires this launch's exact handoff and fails boundedly"

# Configuration validation must happen before a supervised child exists. An
# invalid bound is a user error, not permission to leave an untracked Wine
# process behind while the launcher exits.
base="$(new_env max-timeout-preflight)"
prepare_fixture "$base"
: > "$base/wine.log"
if run_isolated "$base" env ABLETON_POWER=off ABLETON_RT=off ABLETON_LAUNCH_TIMEOUT=invalid \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/max9" \
    >"$base/out" 2>"$base/err"; then
    fail "Max accepted an invalid launch handoff timeout"
fi
[ ! -s "$base/wine.log" ] || fail "Max spawned Wine before validating its launch timeout"
grep -qF 'ABLETON_LAUNCH_TIMEOUT must be a whole number of seconds' "$base/err" \
    || fail "Max timeout preflight failure was not explicit"
ok "Max validates the handoff bound before spawning Wine"

launcher_releases_fds()
{
    local launcher="$1" image="$2" base app_pid launcher_pid coordinator probe_ok=0
    base="$(new_env "${launcher}-fd-handoff")"
    prepare_fixture "$base"
    : > "$base/wine.log"
    run_isolated "$base" env USER=test ABLETON_POWER=off ABLETON_RT=off \
        ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve \
        ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
        ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
        ABLETON_TEST_APP_IMAGE="$image" ABLETON_TEST_APP_PID_FILE="$base/app.pid" \
        ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/$launcher" \
        >"$base/out" 2>"$base/err" &
    launcher_pid=$!
    cleanup_pids+=("$launcher_pid")
    for _ in {1..100}; do [ -s "$base/app.pid" ] && break; sleep 0.1; done
    [ -s "$base/app.pid" ] || fail "$launcher did not start its observable handoff fixture"
    app_pid="$(cat "$base/app.pid")"
    cleanup_pids+=("$app_pid")
    for _ in {1..100}; do
        # shellcheck disable=SC2016
        if run_isolated "$base" env -u ABLETON_INSTALL_LOCK_FD -u ABLETON_INSTALL_LOCK_OWNER_BASHPID \
            bash -c '. "$1/lib/config.sh"; ableton_config_init; ableton_install_lock_acquire || exit 1; ableton_install_lock_release' \
            _ "$here" >/dev/null 2>&1; then
            probe_ok=1
            break
        fi
        sleep 0.1
    done
    [ "$probe_ok" -eq 1 ] || fail "$launcher Wine child retained the installation lock"
    # shellcheck disable=SC2016
    coordinator="$(run_isolated "$base" bash -c \
        '. "$1/lib/config.sh"; ableton_config_init; . "$1/lib/lifecycle.sh"; ableton_lifecycle_runtime_dir' \
        _ "$here")"
    exec {bringup_probe_fd}> "$coordinator/bring-up.lock"
    flock -n "$bringup_probe_fd" || fail "$launcher Wine child retained the bring-up lock"
    flock -u "$bringup_probe_fd"
    exec {bringup_probe_fd}>&-
    kill "$app_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
}

launcher_releases_fds ableton-live \
    'C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'
launcher_releases_fds max9 "C:\\Program Files\\Cycling '74\\Max 9\\Max.exe"
ok "Wine children retain neither global nor per-prefix launcher locks"

# The detached shortcut watcher is an independent launcher process by the time
# it restores GNOME state. It must leave both dconf and its recovery snapshot
# untouched while an installer owns the global lock, then retry and complete
# after that exact owner releases it.
base="$(new_env shortcut-watcher-global-lock)"
prepare_fixture "$base"
shortcut_state="$base/state/ableton-wine/hold-v2"
mkdir -p -- "$base/run/ableton-wine-shortcuts"
cat > "$shortcut_state" <<'EOF'
ABLETON_SHORTCUT_HOLD_V2
org.gnome.desktop.wm.keybindings|switch-to-workspace-up|['<Control><Alt>Up']|[]
EOF
chmod 600 "$shortcut_state"
printf '[]\n' > "$base/shortcut.value"
: > "$base/shortcut-set.log"
: > "$base/install-lock-attempt.log"
cat > "$base/fakebin/gsettings" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
    get) cat "${ABLETON_TEST_SHORTCUT_VALUE:?}" ;;
    set)
        printf '%s\n' "$4" > "${ABLETON_TEST_SHORTCUT_VALUE:?}.tmp"
        mv -f -- "${ABLETON_TEST_SHORTCUT_VALUE}.tmp" "$ABLETON_TEST_SHORTCUT_VALUE"
        printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "${ABLETON_TEST_SHORTCUT_SET_LOG:?}"
        ;;
    writable) printf '%s\n' true ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$base/fakebin/gsettings"
mkfifo "$base/release-install-lock"
(
    exec 7< "$base/home"
    flock -n 7 || exit 1
    : > "$base/install-lock-ready"
    IFS= read -r _ < "$base/release-install-lock"
) &
install_holder_pid=$!
cleanup_pids+=("$install_holder_pid")
for _ in {1..100}; do
    [ -e "$base/install-lock-ready" ] && break
    kill -0 "$install_holder_pid" 2>/dev/null || break
    sleep 0.02
done
[ -e "$base/install-lock-ready" ] || fail "independent installation-lock holder did not start"
# shellcheck disable=SC2016
run_isolated "$base" env -u ABLETON_INSTALL_LOCK_FD -u ABLETON_INSTALL_LOCK_OWNER_BASHPID \
    ABLETON_SHORTCUTS_POLL_SECONDS=0.02 \
    ABLETON_TEST_SHORTCUT_VALUE="$base/shortcut.value" \
    ABLETON_TEST_SHORTCUT_SET_LOG="$base/shortcut-set.log" \
    ABLETON_TEST_INSTALL_LOCK_ATTEMPT_LOG="$base/install-lock-attempt.log" \
    bash -c '
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/shortcut-hold.sh"
        ableton_shortcuts_init_state
        ableton_shortcuts_live_running() { return 1; }
        eval "$(declare -f ableton_install_lock_acquire \
            | sed "1s/^ableton_install_lock_acquire/ableton_install_lock_acquire_real/")"
        ableton_install_lock_acquire()
        {
            printf "attempt\n" >> "$ABLETON_TEST_INSTALL_LOCK_ATTEMPT_LOG"
            ableton_install_lock_acquire_real
        }
        ableton_shortcuts_watch_loop
    ' _ "$here" >"$base/watcher.out" 2>"$base/watcher.err" &
watcher_pid=$!
cleanup_pids+=("$watcher_pid")
for _ in {1..100}; do
    [ -s "$base/install-lock-attempt.log" ] && break
    kill -0 "$watcher_pid" 2>/dev/null || break
    sleep 0.02
done
[ -s "$base/install-lock-attempt.log" ] \
    || fail "shortcut watcher did not attempt the held installation lock"
[ -f "$shortcut_state" ] \
    || fail "held installation lock allowed shortcut recovery state deletion"
[ ! -s "$base/shortcut-set.log" ] \
    || fail "held installation lock allowed a GNOME shortcut restoration"
printf 'release\n' > "$base/release-install-lock"
wait "$install_holder_pid" || fail "independent installation-lock holder failed"
wait "$watcher_pid" || fail "shortcut watcher did not finish after the installer released"
[ ! -e "$shortcut_state" ] \
    || fail "shortcut watcher retained recovery state after the installer released"
grep -qxF "['<Control><Alt>Up']" "$base/shortcut.value" \
    && [ -s "$base/shortcut-set.log" ] \
    || fail "shortcut watcher did not restore GNOME state after the installer released"
ok "shortcut watcher defers restoration under an independent installer lock and retries afterward"

# Prefix promotion must see stock/legacy Wine even though ordinary lifecycle
# operations intentionally remain scoped to the selected runtime. Model the old
# runtime with a separately rooted, Wine-named executable and the exact final
# WINEPREFIX environment value.
base="$(new_env any-runtime-prefix-holder)"
prepare_fixture "$base"
mkdir -p -- "$base/legacy-runtime/bin"
cp -- /bin/sleep "$base/legacy-runtime/bin/wine64"
env WINEPREFIX="$base/prefix" "$base/legacy-runtime/bin/wine64" 60 &
legacy_wine_pid=$!
cleanup_pids+=("$legacy_wine_pid")
env WINEPREFIX="$base/prefix" /bin/sleep 60 &
non_wine_pid=$!
cleanup_pids+=("$non_wine_pid")
env WINEPREFIX="$base/prefix-sibling" "$base/legacy-runtime/bin/wine64" 60 &
sibling_prefix_wine_pid=$!
cleanup_pids+=("$sibling_prefix_wine_pid")
sleep 0.1
# shellcheck disable=SC2016
legacy_holder="$(run_isolated "$base" bash -c '
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/lifecycle.sh"
    if ableton_prefix_busy "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX"; then
        echo "selected-runtime scan unexpectedly matched the legacy fixture" >&2
        exit 1
    fi
    ableton_prefix_wine_processes_any_runtime "$ABLETON_WINEPREFIX"
' _ "$here")" || fail "any-runtime prefix scan could not inspect the legacy Wine fixture"
[ "$legacy_holder" = "$legacy_wine_pid"$'\t'"$base/legacy-runtime/bin/wine64" ] \
    || fail "any-runtime prefix scan did not narrowly report the exact-prefix legacy PID and executable"
kill "$legacy_wine_pid" 2>/dev/null || true
wait "$legacy_wine_pid" 2>/dev/null || true
kill "$non_wine_pid" "$sibling_prefix_wine_pid" 2>/dev/null || true
wait "$non_wine_pid" 2>/dev/null || true
wait "$sibling_prefix_wine_pid" 2>/dev/null || true
ok "prefix promotion recognizes an exact-prefix Wine process from another runtime"

# Keep the two easy-to-regress close sites and promotion barrier explicit. The
# behavioural handoff checks above cover fd 9 and the global fd; these source
# gates cover the watcher's private fd 8 and both rename inputs.
# shellcheck disable=SC2016
grep -qF '"$apply" "$@" 8>&-' "$here/ableton-live" \
    || fail "theme watcher Wine invocation no longer closes its private lock"
# shellcheck disable=SC2016
if ! grep -qF 'ableton_prefix_wine_processes_any_runtime "$final_prefix"' "$here/setup-prefix.sh" \
   || ! grep -qF 'ableton_prefix_wine_processes_any_runtime "$WINEPREFIX"' "$here/setup-prefix.sh"; then
    fail "prefix promotion no longer rechecks both final and staging paths"
fi
ok "theme children close fd 8 and promotion rechecks both prefix names"

printf 'PASS: %s launcher transaction checks\n' "$pass"
