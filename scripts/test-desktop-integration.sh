#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-desktop-test.XXXXXX")"
warm_pid=""
cleanup()
{
    if [ -n "$warm_pid" ]; then
        kill "$warm_pid" 2>/dev/null || true
        wait "$warm_pid" 2>/dev/null || true
    fi
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
    local name="$1" base
    base="$work/$name"
    mkdir -p -- "$base/home" "$base/tmp" "$base/fakebin"
    printf '%s\n' "$base"
}

install_fake_desktop_tools()
{
    local base="$1" probe
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
        if [ "${ABLETON_TEST_XDG_QUERY_FAIL:-0}" -eq 1 ]; then
            printf 'fake MIME default query failure\n' >&2
            exit 93
        fi
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
    probe="$base/home/.local/opt/wine-d2d1-nspa-11.13/bin/pipewire-version-probe"
    mkdir -p -- "$(dirname "$probe")"
    cat > "$probe" <<'EOF'
#!/bin/sh
printf 'client=1.4.2\ndaemon=1.4.2\n'
EOF
    chmod +x "$base/fakebin/"* "$probe"
}

run_isolated()
{
    local base="$1"; shift
    env HOME="$base/home" XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data" \
        XDG_STATE_HOME="$base/state" XDG_CACHE_HOME="$base/cache" \
        XDG_RUNTIME_DIR="$base/run" TMPDIR="$base/tmp" \
        ABLETON_SHORTCUTS=preserve ABLETON_MAX_AUDIO_THREADS=off \
        ABLETON_TEST_MIME_STATE="$base/mime-defaults.tsv" \
        PATH="$base/fakebin:/usr/bin:/bin" "$@"
}

protocol_id=io.github.shibco.ableton-linux.protocol.desktop
auz_id=io.github.shibco.ableton-linux.auz.desktop

base="$(new_env config-help)"
config_help="$(run_isolated "$base" bash "$here/ableton-live" --config)"
printf '%s\n' "$config_help" | grep -q 'ABLETON_MAX_AUDIO_THREADS=auto|off|<number>' \
    || fail "launcher help omits the automatic audio thread policy"
printf '%s\n' "$config_help" | grep -q 'greater of the physical core count' \
    || fail "launcher help needs the automatic audio thread basis"
printf '%s\n' "$config_help" | grep -q "half of Live's own count" \
    || fail "launcher help needs the automatic audio thread floor"
printf '%s\n' "$config_help" | grep -q "remove the launcher's saved count" \
    || fail "launcher help needs the saved audio thread removal"
printf '%s\n' "$config_help" | grep -q 'Check auto after you move the prefix to another computer' \
    || fail "launcher help needs the computer-change reminder"
printf '%s\n' "$config_help" | grep -q 'ABLETON_SHORTCUTS=take|preserve' \
    || fail "launcher help omits the GNOME shortcut policy"
printf '%s\n' "$config_help" | grep -q 'preserve leaves the desktop shortcuts unchanged' \
    || fail "launcher help omits the shortcut opt-out"
ok "launcher help reports the default-on worker and GNOME shortcut policies"

for missing_live_options_function in ableton_live_calculated_audio_threads \
                                     ableton_reliable_audio_threads; do
    base="$(new_env "incomplete-live-options-$missing_live_options_function")"
    mkdir -p -- "$base/launcher/lib"
    cp -- "$here/ableton-live" "$base/launcher/ableton-live"
    cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" "$base/launcher/lib/"
    cat > "$base/launcher/lib/live-options.sh" <<'EOF'
ableton_available_physical_cores() { printf '4\n'; }
ableton_live_product_version() { return 1; }
ableton_seed_max_audio_threads() { return 0; }
EOF
    if [ "$missing_live_options_function" != ableton_live_calculated_audio_threads ]; then
        printf '%s\n' 'ableton_live_calculated_audio_threads() { printf '\''7\n'\''; }' \
            >> "$base/launcher/lib/live-options.sh"
    fi
    if [ "$missing_live_options_function" != ableton_reliable_audio_threads ]; then
        printf '%s\n' 'ableton_reliable_audio_threads() { printf '\''4\n'\''; }' \
            >> "$base/launcher/lib/live-options.sh"
    fi
    if run_isolated "$base" bash "$base/launcher/ableton-live" \
        >"$base/out" 2>"$base/err"; then
        fail "launcher accepts live-options.sh without $missing_live_options_function"
    fi
    grep -q 'support files are incomplete. Run the latest installer again.' "$base/err" \
        || fail "launcher does not explain how to repair incomplete support files"
done
ok "launcher gives one repair instruction for incomplete support files"

base="$(new_env unique-handlers)"
install_fake_desktop_tools "$base"
state="$base/state/ableton-wine"
private_support="$base/data/ableton-wine/setup-realtime.sh"
mkdir -p -- "$base/data/applications" "$(dirname "$private_support")"
printf 'older generated support bytes\n' > "$private_support"
cat > "$base/data/applications/wine-protocol-ableton.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Ableton URL Handler
Exec=$base/home/.local/bin/ableton-live %u
NoDisplay=true
MimeType=x-scheme-handler/ableton;
EOF
cat > "$base/data/applications/wine-extension-auz.desktop" <<'EOF'
[Desktop Entry]
Exec=env WINEPREFIX=/tmp/foreign wine start %f
EOF
if ! printf 'o\n' | run_isolated "$base" \
    bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err"; then
    cat "$base/err" >&2
    fail "installer cannot install desktop integration in an isolated home"
fi
[ -f "$base/data/applications/$protocol_id" ] || fail "installer omits the project protocol handler"
[ -f "$base/data/applications/$auz_id" ] || fail "installer omits the project AUZ handler"
[ -f "$base/data/ableton-wine/$protocol_id" ] || fail "installer omits the staged protocol handler"
[ -f "$base/data/ableton-wine/$auz_id" ] || fail "installer omits the staged AUZ handler"
cmp -s -- "$here/setup-realtime.sh" "$private_support" \
    || fail "Overwrite did not replace the selected support file"
[ -f "$base/data/applications/wine-protocol-ableton.desktop" ] \
    || fail "installer removed an unrelated legacy protocol handler"
[ -f "$base/data/applications/wine-extension-auz.desktop" ] \
    || fail "installer removes a foreign globally named handler"
grep -qxF "$private_support exists." "$base/err" \
    || fail "existing support file prompt did not name its destination"
grep -qF '│  ├─ QUESTION: Some files from an earlier installation already exist.' "$base/out" \
    || fail "existing support file did not ask for an overwrite choice"
mapfile -t support_backups < <(find "$state/backups" -type f \
    -name 'setup-realtime.sh.bak-*')
[ "${#support_backups[@]}" -eq 1 ] \
    || fail "Overwrite did not create exactly one dated backup"
grep -qxF 'older generated support bytes' "${support_backups[0]}" \
    || fail "Overwrite backup does not contain the displaced file"
[ ! -e "$state/install-manifest.tsv" ] && [ ! -e "$state/install-prestate.tsv" ] \
    || fail "simple integration created ownership or prestate records"
[ "$(awk -F '\t' '$1 == "x-scheme-handler/ableton" { print $2 }' "$base/mime-defaults.tsv")" = "$protocol_id" ] \
    || fail "installer does not pin the project protocol handler"
[ "$(awk -F '\t' '$1 == "application/x-wine-extension-auz" { print $2 }' "$base/mime-defaults.tsv")" = "$auz_id" ] \
    || fail "installer does not pin the project AUZ handler"
installed_ntsync_check="$base/data/ableton-wine/check-ntsync.sh"
installed_ntsync_probe="$base/data/ableton-wine/ntsyncprobe.exe"
[ -x "$installed_ntsync_check" ] \
    || fail "installer omits the executable NTSync diagnostic"
[ -f "$installed_ntsync_probe" ] && [ ! -x "$installed_ntsync_probe" ] \
    || fail "installer omits the data-only NTSync semantics probe"
cmp -s "$here/../beta/tester-kit/probes/windows/ntsyncprobe.exe" "$installed_ntsync_probe" \
    || fail "installer changes the NTSync semantics probe"
grep -qF "$installed_ntsync_check" "$base/out" \
    || fail "installer does not report the installed NTSync diagnostic"
for diagnostic_tool in pw-metadata pw-dump pw-top journalctl; do
    printf '#!/bin/sh\nexit 1\n' > "$base/fakebin/$diagnostic_tool"
    chmod +x "$base/fakebin/$diagnostic_tool"
done
run_isolated "$base" bash "$base/data/ableton-wine/audio-report.sh" \
    >"$base/audio-report.out" 2>"$base/audio-report.err"
grep -q '^== CPU layout evidence for Wine$' "$base/audio-report.out" \
    || fail "installed audio report omits the CPU topology section"
grep -q '^cpu_topology_format=2$' "$base/audio-report.out" \
    || fail "installed audio report cannot run its CPU topology probe"
grep -q '^wine_win32_efficiency_class_probe=not_run_read_only$' "$base/audio-report.out" \
    || fail "installed audio report overstates Wine efficiency-class evidence"
grep -qF "close Live, then run $installed_ntsync_check for the dynamic proof" \
    "$base/audio-report.out" \
    || fail "installed audio report does not name the installed NTSync diagnostic"
mkdir -p -- "$base/fake-wine/bin"
for runtime_tool in wine wineserver; do
    printf '#!/bin/sh\nexit 0\n' > "$base/fake-wine/bin/$runtime_tool"
    chmod +x "$base/fake-wine/bin/$runtime_tool"
done
if run_isolated "$base" env ABLETON_WINE_ROOT="$base/fake-wine" \
    bash "$installed_ntsync_check" >"$base/ntsync.out" 2>"$base/ntsync.err"; then
    fail "NTSync diagnostic accepts a runtime without NTSync"
fi
! grep -q 'Provide the NTSync probe at' "$base/ntsync.err" \
    || fail "installed NTSync diagnostic cannot find its packaged sibling probe"
grep -q 'FAIL: rebuild Wine with linux/ntsync.h' "$base/ntsync.err" \
    || fail "installed NTSync diagnostic does not reach its runtime check"
ok "installer uses unique handlers and backs up only selected fixed destinations"

base="$(new_env mime-query-ignored)"
install_fake_desktop_tools "$base"
printf 'application/x-unrelated\tforeign.desktop\n' > "$base/mime-defaults.tsv"
query_status=0
run_isolated "$base" env ABLETON_TEST_XDG_QUERY_FAIL=1 \
    ABLETON_INTERNAL_OPTIONAL_STATUS=1 \
    bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err" \
    || query_status=$?
[ "$query_status" -eq 0 ] \
    || fail "MIME default query failure produced an internal retry status"
! grep -qF 'fake MIME default query failure' "$base/err" \
    || fail "installer queried MIME defaults after publishing them"
! grep -qF 'Some shortcuts or support files could not be updated.' "$base/err" \
    || fail "MIME default query failure produced an alarming retry warning"
[ -f "$base/data/applications/$protocol_id" ] \
    || fail "MIME default query failure blocked the protocol handler"
[ -x "$base/home/.local/bin/ableton-live" ] \
    || fail "MIME default query failure blocked the generated launcher"
grep -qxF $'application/x-unrelated\tforeign.desktop' "$base/mime-defaults.tsv" \
    || fail "MIME default publication corrupted an unrelated default"
grep -qxF $'x-scheme-handler/ableton\tio.github.shibco.ableton-linux.protocol.desktop' \
    "$base/mime-defaults.tsv" || fail "MIME default was not published before verification was skipped"
ok "MIME defaults are published without a redundant query failure gate"

optional_real_cp="$(command -v cp)"

base="$(new_env optional-version-warning)"
install_fake_desktop_tools "$base"
cat > "$base/fakebin/cp" <<EOF
#!/bin/sh
last=""
for argument do last="\$argument"; done
[ "\$last" != "\${ABLETON_TEST_FAIL_TARGET:-}" ] || exit 88
exec "$optional_real_cp" "\$@"
EOF
chmod 755 "$base/fakebin/cp"
run_isolated "$base" env \
    ABLETON_TEST_FAIL_TARGET="$base/data/ableton-wine/VERSION" \
    bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err" \
    || fail "optional version failure aborted integration"
[ -x "$base/home/.local/bin/ableton-live" ] \
    || fail "optional version failure rolled back the generated launcher"
grep -qF -- "-> $base/data/ableton-wine/VERSION" "$base/err" \
    || fail "optional version failure did not report the actual failed path"
grep -qF '⚠ Some shortcuts or support files could not be updated.' "$base/out" \
    || fail "optional version failure hid the partial integration result"
ok "optional version copy failure reports its path and keeps completed files"

base="$(new_env overwrite-keep-continues)"
install_fake_desktop_tools "$base"
kept_config="$base/data/ableton-wine/lib/config.sh"
mkdir -p -- "$(dirname "$kept_config")"
printf 'keep this config\n' > "$kept_config"
printf 'Keep\n' | run_isolated "$base" \
    bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err" \
    || fail "Keep stopped the integration mapping loop"
grep -qxF 'keep this config' "$kept_config" \
    || fail "Keep changed the selected destination"
[ -f "$base/data/ableton-wine/lib/lifecycle.sh" ] \
    || fail "Keep prevented the next project file from being installed"
[ -x "$base/home/.local/bin/ableton-live" ] \
    || fail "Keep prevented later project files from being installed"
if [ -d "$base/state/ableton-wine/backups" ] \
   && find "$base/state/ableton-wine/backups" -type f -name 'config.sh.bak-*' \
        -print -quit | grep -q .; then
    fail "Keep created a backup for an untouched destination"
fi
grep -qF 'Kept existing file unchanged:' "$base/out" \
    && grep -qF '⚠ Kept 1 existing files unchanged.' "$base/out" \
    || fail "Keep was not reported as an unchanged result"
! grep -qF 'Launchers, shortcuts, and file support are ready.' "$base/out" \
    || fail "Keep was falsely reported as a fully applied update"
grep -qF '│  ├─ QUESTION: Some files from an earlier installation already exist.' "$base/out" \
    || fail "the overwrite question is rendered inside the tree"
ok "Keep leaves one destination unchanged and continues the fixed mapping loop"

base="$(new_env optional-cache-ignored)"
install_fake_desktop_tools "$base"
for tool in update-desktop-database update-mime-database; do
    printf '#!/bin/sh\nprintf "fake cache refresh failure\\n" >&2\nexit 90\n' \
        > "$base/fakebin/$tool"
done
cat > "$base/fakebin/gtk-update-icon-cache" <<'EOF'
#!/bin/sh
: > "${ABLETON_TEST_GTK_CALLED:?}"
exit 90
EOF
chmod 755 "$base/fakebin/"*
cache_status=0
run_isolated "$base" env ABLETON_INTERNAL_OPTIONAL_STATUS=1 \
    ABLETON_TEST_GTK_CALLED="$base/gtk-called" \
    bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err" \
    || cache_status=$?
[ "$cache_status" -eq 0 ] \
    || fail "desktop refresh failure produced an internal retry status"
[ -x "$base/home/.local/bin/ableton-live" ] \
    || fail "desktop refresh failure blocked the generated launcher"
! grep -qF 'fake cache refresh failure' "$base/err" \
    || fail "desktop refresh tool leaked alarming output"
[ ! -e "$base/gtk-called" ] \
    || fail "desktop integration invoked gtk-update-icon-cache"
! grep -qF 'Some shortcuts or support files could not be updated.' "$base/err" \
    || fail "desktop refresh failure produced an alarming retry warning"
! grep -q 'Step [0-9]* Complete' "$base/out" \
    || fail "coordinated desktop refresh closed a step that belongs to the installer"
ok "desktop database refresh is silent best-effort work and GTK cache generation is skipped"

base="$(new_env generated-file-publication-status)"
install_fake_desktop_tools "$base"
cat > "$base/fakebin/cp" <<EOF
#!/bin/sh
last=""
for argument do last="\$argument"; done
[ "\$last" != "\${ABLETON_TEST_FAIL_TARGET:-}" ] || exit 94
exec "$optional_real_cp" "\$@"
EOF
chmod 755 "$base/fakebin/cp"
publication_status=0
run_isolated "$base" env \
    ABLETON_TEST_FAIL_TARGET="$base/home/.local/bin/ableton-live" \
    ABLETON_INTERNAL_OPTIONAL_STATUS=1 \
    bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err" \
    || publication_status=$?
[ "$publication_status" -eq 3 ] \
    || fail "generated launcher publication failure lost its internal retry status"
[ ! -e "$base/home/.local/bin/ableton-live" ] \
    || fail "failed generated launcher publication reported a usable launcher"
[ -f "$base/data/ableton-wine/detect-scale.sh" ] \
    || fail "failed launcher copy prevented a later mapping"
grep -qF -- "-> $base/home/.local/bin/ableton-live" "$base/err" \
    || fail "generated launcher failure did not report the actual failed path"
grep -qF 'Some shortcuts or support files could not be updated. Run the installer again to retry them.' \
    "$base/err" || fail "generated launcher publication failure omitted its retry warning"
ok "generated-file publication failures still request a repair run"

base="$(new_env overwrite-cancel-stops)"
install_fake_desktop_tools "$base"
cancel_target="$base/data/ableton-wine/lib/lifecycle.sh"
mkdir -p -- "$(dirname "$cancel_target")"
printf 'keep on cancel\n' > "$cancel_target"
cancel_status=0
printf 'a\n' | run_isolated "$base" \
    bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err" \
    || cancel_status=$?
[ "$cancel_status" -eq 4 ] || fail "Cancel did not return the cancellation status"
[ -f "$base/data/ableton-wine/lib/config.sh" ] \
    || fail "Cancel unwound an earlier completed mapping"
grep -qxF 'keep on cancel' "$cancel_target" \
    || fail "Cancel changed its selected destination"
[ ! -e "$base/data/ableton-wine/lib/live-options.sh" ] \
    && [ ! -e "$base/home/.local/bin/ableton-live" ] \
    || fail "Cancel did not stop later project-file mappings"
ok "Cancel stops later mappings without unwinding completed files"

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
mkdir -p -- "$base/nix/libexec/lib" "$base/runtime/share/ableton-wine/scripts"
cp -- "$here/ableton-live" "$base/nix/libexec/ableton-live"
cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" "$here/lib/live-options.sh" \
    "$here/lib/manifest.sh" \
    "$base/nix/libexec/lib/"
cat > "$base/runtime/share/ableton-wine/scripts/audio-report.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$base/runtime/share/ableton-wine/scripts/audio-report.sh"
cat > "$base/fakebin/nproc" <<'EOF'
#!/bin/sh
printf 'unavailable\n'
EOF
run_isolated "$base" env USER=test ABLETON_MAX_AUDIO_THREADS=auto ABLETON_POWER=off \
    ABLETON_RT=off ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$base/nix/libexec/ableton-live" \
    'ableton://invalid-ableton-linux-probe' >"$base/nix.out" 2>"$base/nix.err" || true
grep -qF "Run $base/runtime/share/ableton-wine/scripts/audio-report.sh to review the CPU details" \
    "$base/nix.err" || {
        sed -n '1,80p' "$base/nix.err" >&2
        fail "The Nix launcher fallback does not name its packaged audio report."
    }
cat > "$base/fakebin/nproc" <<'EOF'
#!/bin/sh
[ "$#" -eq 0 ] || exit 2
printf '32\n'
EOF
ok "automatic worker fallback names the packaged Nix audio report"

: > "$base/wine.log"
if run_isolated "$base" env USER=test ABLETON_MAX_AUDIO_THREADS=64 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    'ableton://invalid-ableton-linux-probe' >"$base/invalid.out" 2>"$base/invalid.err"; then
    fail "The audio thread range check runs before Wine starts."
fi
grep -q 'Set ABLETON_MAX_AUDIO_THREADS to auto, off, or a number from one to 63' "$base/invalid.err" \
    || fail "The launcher reports the accepted audio thread values."
[ ! -s "$base/wine.log" ] || fail "The audio thread range check runs before Wine starts."

if run_isolated "$base" env USER=test ABLETON_SHORTCUTS=invalid \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    'ableton://invalid-ableton-linux-probe' >"$base/shortcut-invalid.out" 2>"$base/shortcut-invalid.err"; then
    fail "The shortcut policy check accepts an unknown value."
fi
grep -q 'Set ABLETON_SHORTCUTS to take or preserve' "$base/shortcut-invalid.err" \
    || fail "The launcher reports the accepted shortcut policies."
[ ! -s "$base/wine.log" ] || fail "The shortcut policy check runs before Wine starts."

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
    || fail "A callback with ABLETON_MAX_AUDIO_THREADS=off changes Live's current audio thread count."

: > "$base/wine.log"
physical_cores="$(bash -c '. "$1"; ableton_available_physical_cores' _ "$here/lib/live-options.sh")" \
    || fail "The launcher cannot count the physical CPU cores available to the test."
available_processors="$("$base/fakebin/nproc")" \
    || fail "The fake processor probe is unavailable."
auto_threads="$(bash -c '. "$1"; ableton_reliable_audio_threads "$2" "$3"' \
    _ "$here/lib/live-options.sh" "$physical_cores" "$available_processors")" \
    || fail "The launcher cannot calculate the reliable automatic audio thread count."
live_threads="$(bash -c '. "$1"; ableton_live_calculated_audio_threads "$2"' \
    _ "$here/lib/live-options.sh" "$available_processors")" \
    || fail "The launcher cannot calculate Live's default audio thread count."
run_isolated "$base" env -u ABLETON_MAX_AUDIO_THREADS USER=test ABLETON_POWER=off \
    ABLETON_RT=off ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve \
    ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TOPBAR_MODE=preserve ABLETON_LAUNCH_TIMEOUT=5 \
    ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
    'ableton://invalid-ableton-linux-probe' >"$base/auto.out" 2>"$base/auto.err" || true
if [ "$auto_threads" -lt "$live_threads" ]; then
    grep -qx -- "-MaxAudioThreads=$auto_threads" "$callback_prefs/Options.txt" \
        || fail "The default launcher policy does not use the reliability-hardened automatic count."
else
    [ ! -e "$callback_prefs/Options.txt" ] \
        || fail "The default launcher policy adds a limit above Live's calculated count."
fi

cp /bin/sleep "$base/runtime/bin/wine-client"
warm_holder='C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'
env WINEPREFIX="$base/prefix" bash -c \
    'exec -a "$2" "$1" 600' _ "$base/runtime/bin/wine-client" "$warm_holder" \
    </dev/null >/dev/null 2>&1 &
warm_pid=$!
sleep 0.2
warm_auz="$base/Warm.auz"
warm_als="$base/Warm.als"
: > "$warm_auz"
: > "$warm_als"
warm_index=0
for warm_arg in 'ableton://warm-ableton-linux-probe' "$warm_auz" "$warm_als"; do
    warm_index=$((warm_index + 1))
    run_isolated "$base" env -u ABLETON_MAX_AUDIO_THREADS USER=test ABLETON_POWER=off \
        ABLETON_RT=off ABLETON_THEME_MODE=preserve ABLETON_DPI_MODE=preserve \
        ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
        ABLETON_TOPBAR_MODE=preserve ABLETON_TEST_WINE_LOG="$base/wine.log" \
        bash "$here/ableton-live" "$warm_arg" \
        >"$base/warm-$warm_index.out" 2>"$base/warm-$warm_index.err" || true
    ! grep -q 'Exit Live. Run the command again to apply the audio thread setting' \
        "$base/warm-$warm_index.err" \
        || fail "An implicit automatic warm handoff reports an action the user did not request."
done
for warm_request in 8 off; do
    run_isolated "$base" env USER=test ABLETON_MAX_AUDIO_THREADS="$warm_request" \
        ABLETON_POWER=off ABLETON_RT=off ABLETON_THEME_MODE=preserve \
        ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve \
        ABLETON_TEXT_SMOOTHING=preserve ABLETON_TOPBAR_MODE=preserve \
        ABLETON_TEST_WINE_LOG="$base/wine.log" bash "$here/ableton-live" \
        'ableton://warm-explicit-ableton-linux-probe' \
        >"$base/warm-$warm_request.out" 2>"$base/warm-$warm_request.err" || true
    grep -q 'Exit Live. Run the command again to apply the audio thread setting' \
        "$base/warm-$warm_request.err" \
        || fail "An explicit warm audio setting does not ask for a cold launch."
done
kill "$warm_pid" 2>/dev/null || true
wait "$warm_pid" 2>/dev/null || true
warm_pid=""
ok "implicit URL, AUZ, and ALS warm handoffs stay quiet; explicit warm settings request a cold launch"

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
ok "Callback launches use the selected Wine prefix. They preserve the Ableton protocol handlers. The off policy preserves settings without a launcher marker. The default uses the reliability-hardened automatic count. A requested count reaches shared-version settings. Mixed-version callbacks leave edition selection and settings unchanged."

printf 'PASS: %s desktop integration checks\n' "$pass"
