#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-pipeasio-installer-test.XXXXXX")"
cleanup()
{
    [ "${ABLETON_KEEP_TEST_WORK:-0}" -eq 0 ] || { printf 'kept test work: %s\n' "$work" >&2; return; }
    case "${work:-}" in
        "${TMPDIR:-/tmp}"/ableton-pipeasio-installer-test.*) rm -rf -- "$work" ;;
    esac
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

[ -r "$here/lib/pipeasio.sh" ] || fail "shared PipeASIO installer library is missing"

# This is deliberately set before sourcing the library: release policy must
# replace an inherited value rather than allowing the environment to lower it.
ABLETON_PIPEWIRE_FLOOR=0.3.56
# shellcheck disable=SC1091
. "$here/lib/pipeasio.sh"
[ "$ABLETON_PIPEWIRE_FLOOR" = 1.4.2 ] || fail "environment overrode the hard PipeWire floor"
declare -F ableton_pipewire_preflight >/dev/null || fail "PipeWire preflight API is missing"
declare -F ableton_pipeasio_validate_runtime >/dev/null || fail "runtime validation API is missing"
ok "PipeWire 1.4.2 is a hard release floor"

new_env()
{
    local base="$work/$1"
    mkdir -p -- "$base/home" "$base/tmp" "$base/empty-path"
    printf '%s\n' "$base"
}

run_isolated()
{
    local base="$1"
    shift
    env HOME="$base/home" \
        XDG_CONFIG_HOME="$base/xdg/config" \
        XDG_DATA_HOME="$base/xdg/data" \
        XDG_STATE_HOME="$base/xdg/state" \
        XDG_CACHE_HOME="$base/xdg/cache" \
        XDG_RUNTIME_DIR="$base/xdg/run" \
        TMPDIR="$base/tmp" "$@"
}

write_probe()
{
    local target="$1"
    mkdir -p -- "$(dirname "$target")"
    cat > "$target" <<'EOF'
#!/bin/bash
case "${1:-}" in
    --client)
        [ "${PROBE_EXIT:-0}" -eq 0 ] || exit "$PROBE_EXIT"
        printf 'client=%s\n' "${PROBE_CLIENT:-}"
        ;;
    '')
        [ "${PROBE_EXIT:-0}" -eq 0 ] || exit "$PROBE_EXIT"
        printf 'client=%s\ndaemon=%s\n' "${PROBE_CLIENT:-}" "${PROBE_DAEMON:-}"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod 755 "$target"
}

probe_base="$(new_env probe)"
probe="$probe_base/pipewire-version-probe"
write_probe "$probe"
mkdir -p -- "$probe_base/core-path"
for tool in awk basename dirname grep head sed sort timeout tr wc; do
    tool_path="$(command -v "$tool")"
    ln -s -- "$tool_path" "$probe_base/core-path/$tool"
done

invoke_preflight()
{
    local client="$1" daemon="$2" probe_exit="${3:-0}"
    # shellcheck disable=SC2016
    env PATH="$probe_base/core-path" \
        PROBE_CLIENT="$client" PROBE_DAEMON="$daemon" PROBE_EXIT="$probe_exit" \
        ABLETON_PIPEWIRE_FLOOR=0.3.56 \
        /bin/bash -c '. "$1"; ableton_pipewire_preflight "$2"' \
        _ "$here/lib/pipeasio.sh" "$probe"
}

preflight_ok()
{
    local client="$1" daemon="$2"
    # core-path deliberately has no pw-cli, pw-dump, or pw-top. The native
    # probe has an absolute path and shebang.
    invoke_preflight "$client" "$daemon" >/dev/null 2>&1
}

preflight_fails()
{
    local client="$1" daemon="$2"
    if invoke_preflight "$client" "$daemon" >/dev/null 2>&1; then
        return 1
    fi
}

preflight_ok 1.4.2 1.4.2 || fail "exact PipeWire floor was refused"
preflight_ok 1.4.2-1 1.4.2+distribution || fail "valid PipeWire version suffix was refused"
preflight_ok 1.4.2-1~ubuntu 1.4.2+distribution || fail "distro suffix at the PipeWire floor was refused"
preflight_ok 1.4.3~rc1 1.5.0~beta1 || fail "prerelease above the PipeWire floor was refused"
preflight_ok 1.4.11 1.6.8 || fail "supported PipeWire versions were refused"
preflight_ok 2.0.0 2.1.3 || fail "later PipeWire major versions were refused"
preflight_fails 1.4.2~rc1 1.6.8 || fail "loaded-client prerelease at the final floor was accepted"
preflight_fails 1.6.8 1.4.2~rc1 || fail "daemon prerelease at the final floor was accepted"
preflight_fails 1.4.1 1.6.8 || fail "old loaded client was accepted"
preflight_fails 1.6.8 1.4.1 || fail "old daemon was accepted"
preflight_fails 1.0.5 1.0.5 || fail "Ubuntu/Mint PipeWire 1.0.5 was accepted"
preflight_fails garbage 1.6.8 || fail "malformed loaded-client version was accepted"
preflight_fails 1.4 1.6.8 || fail "incomplete loaded-client version was accepted"
preflight_fails 9999999999.4.2 1.6.8 || fail "oversized version component was accepted"
preflight_fails 1.6.8 '' || fail "missing daemon version was accepted"
if invoke_preflight 1.6.8 1.6.8 9 >/dev/null 2>&1; then
    fail "failing native probe was accepted"
fi
ok "native probe gates loaded client and daemon without PipeWire CLI utilities"

base="$(new_env mutation-lock)"
mkdir -p -- "$base/xdg/state/ableton-wine"
printf 'format=1\nowner=ableton-linux\n' \
    > "$base/xdg/state/ableton-wine/.ableton-linux-state"
exec {held_lock_fd}< "$base/home"
flock -n "$held_lock_fd" || fail "could not create mutation-lock fixture"
# A child in the same installer transaction inherits the descriptor and may
# continue; an independent process must be refused while it is held.
# shellcheck disable=SC2016
run_isolated "$base" env ABLETON_INSTALL_LOCK_FD="$held_lock_fd" bash -c '
    . "$1/lib/config.sh"
    ableton_config_init
    ableton_install_lock_acquire
' _ "$here" || fail "nested installer helper did not inherit the mutation lock"
# shellcheck disable=SC2016
if run_isolated "$base" env -u ABLETON_INSTALL_LOCK_FD bash -c '
    . "$1/lib/config.sh"
    ableton_config_init
    ableton_install_lock_acquire
' _ "$here" >/dev/null 2>&1; then
    fail "concurrent independent installer acquired the mutation lock"
fi
state_marker_digest="$(sha256sum -- "$base/xdg/state/ableton-wine/.ableton-linux-state" | awk '{print $1}')"
if run_isolated "$base" env -u ABLETON_INSTALL_LOCK_FD \
    bash "$here/setup-link.sh" snapshot "$base/link-transaction" \
    >"$base/setup-link.out" 2>"$base/setup-link.err"; then
    fail "direct setup-link mutator bypassed the held installation lock"
fi
grep -qF 'another installer, rollback, or uninstall is already running' \
    "$base/setup-link.err" || fail "setup-link lock refusal was not explicit"
[ ! -e "$base/link-transaction" ] \
    || fail "refused setup-link mutator created a transaction snapshot"
[ "$(sha256sum -- "$base/xdg/state/ableton-wine/.ableton-linux-state" | awk '{print $1}')" \
    = "$state_marker_digest" ] || fail "refused setup-link mutator changed installer state"
exec {held_lock_fd}<&-
ok "one non-persistent lock serializes installer helpers and direct setup-link mutators"

write_build_info()
{
    local runtime="$1" external="$2" mode="$3" panel_hash=""
    case "$mode" in
        built)
            mkdir -p -- "$runtime/bin" \
                "$runtime/share/applications" \
                "$runtime/share/icons/hicolor/scalable/apps"
            cp -- /bin/true "$runtime/bin/pipeasio-settings"
            chmod 755 "$runtime/bin/pipeasio-settings"
            cat > "$runtime/share/applications/pipeasio-settings.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PipeASIO Settings
Exec=pipeasio-settings
Icon=pipeasio
EOF
            cat > "$runtime/share/icons/hicolor/scalable/apps/pipeasio.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path d="M0 0h16v16H0z"/></svg>
EOF
            panel_hash="$(sha256sum -- "$runtime/bin/pipeasio-settings" | awk '{print $1}')"
            ;;
        skipped)
            rm -f -- "$runtime/bin/pipeasio-settings" \
                "$runtime/share/applications/pipeasio-settings.desktop" \
                "$runtime/share/icons/hicolor/scalable/apps/pipeasio.svg"
            ;;
        *) fail "test requested unknown panel mode $mode" ;;
    esac

    {
        printf 'dist-version: 2026.08.12.999\n'
        printf 'pipeasio: 1.5.0\n'
        printf 'pipewire-floor: 1.4.2\n'
        printf 'pipeasio-pe: %s\n' "$(sha256sum -- "$runtime/lib/wine/x86_64-windows/pipeasio64.dll" | awk '{print $1}')"
        printf 'pipeasio-unix: %s\n' "$(sha256sum -- "$runtime/lib/wine/x86_64-unix/pipeasio64.dll.so" | awk '{print $1}')"
        printf 'pipewire-version-probe: %s\n' "$(sha256sum -- "$runtime/bin/pipewire-version-probe" | awk '{print $1}')"
        printf 'pipeasio-panel: %s\n' "$mode"
        if [ "$mode" = built ]; then
            printf 'pipeasio-settings: %s (Qt 6.2 link)\n' "$panel_hash"
        else
            printf 'pipeasio-settings: skipped (Qt6 Widgets unavailable)\n'
        fi
    } > "$runtime/ABLETON-WINE-BUILD-INFO.txt"
    cp -- "$runtime/ABLETON-WINE-BUILD-INFO.txt" "$external"
}

make_runtime()
{
    local runtime="$1" external="$2" mode="$3"
    mkdir -p -- "$runtime/bin" \
        "$runtime/lib/wine/x86_64-windows" \
        "$runtime/lib/wine/x86_64-unix"
    printf 'PE PipeASIO fixture\n' > "$runtime/lib/wine/x86_64-windows/pipeasio64.dll"
    ln -s -- pipeasio64.dll "$runtime/lib/wine/x86_64-windows/pipeasio.dll"
    printf 'Unix PipeASIO fixture\n' > "$runtime/lib/wine/x86_64-unix/pipeasio64.dll.so"
    ln -s -- pipeasio64.dll.so "$runtime/lib/wine/x86_64-unix/pipeasio.dll.so"
    write_probe "$runtime/bin/pipewire-version-probe"
    write_build_info "$runtime" "$external" "$mode"
}

runtime_validates()
{
    ableton_pipeasio_validate_runtime "$1" "$2" >/dev/null 2>&1
}

runtime_fails_validation()
{
    if ableton_pipeasio_validate_runtime "$1" "$2" >/dev/null 2>&1; then
        return 1
    fi
}

base="$(new_env artifacts-built)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
runtime_validates "$base/runtime" "$base/BUILD-INFO.txt" || fail "complete built-panel payload was refused"
ok "built-panel BUILD-INFO grammar and sealed artifacts validate"

base="$(new_env artifacts-skipped)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" skipped
runtime_validates "$base/runtime" "$base/BUILD-INFO.txt" || fail "complete skipped-panel payload was refused"
ok "skipped-panel BUILD-INFO grammar validates with zero panel artifacts"

base="$(new_env artifacts-skipped-disabled)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" skipped
sed -i 's/skipped (Qt6 Widgets unavailable)/skipped (disabled)/' \
    "$base/runtime/ABLETON-WINE-BUILD-INFO.txt" "$base/BUILD-INFO.txt"
runtime_validates "$base/runtime" "$base/BUILD-INFO.txt" \
    || fail "explicitly disabled panel build output was refused"
ok "both exact builder-emitted skipped-panel reasons validate"

base="$(new_env artifact-partial)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
rm -f -- "$base/runtime/share/icons/hicolor/scalable/apps/pipeasio.svg"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" || fail "partial built-panel payload was accepted"
ok "partial panel payload is refused"

base="$(new_env artifact-polluted-skip)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" skipped
cp -- /bin/true "$base/runtime/bin/pipeasio-settings"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" || fail "skipped panel with a stray artifact was accepted"
ok "skipped panel requires an empty artifact set"

base="$(new_env alias-mismatch)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
rm -f -- "$base/runtime/lib/wine/x86_64-windows/pipeasio.dll"
printf 'different alias\n' > "$base/runtime/lib/wine/x86_64-windows/pipeasio.dll"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" || fail "mismatched PipeASIO PE aliases were accepted"
ok "PipeASIO aliases must be byte-identical"

base="$(new_env alias-partial)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
rm -f -- "$base/runtime/lib/wine/x86_64-unix/pipeasio.dll.so"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" || fail "partial PipeASIO alias set was accepted"
ok "PipeASIO aliases are all-or-none"

base="$(new_env driver-digest-mismatch)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
printf 'post-build mutation\n' >> "$base/runtime/lib/wine/x86_64-unix/pipeasio64.dll.so"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" \
    || fail "modified canonical PipeASIO binary was accepted with a stale BUILD-INFO digest"
ok "PipeASIO PE and Unix binaries must match their unique BUILD-INFO digests"

base="$(new_env dist-version-contract)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
if ableton_pipeasio_validate_runtime "$base/runtime" "$base/BUILD-INFO.txt" \
    2026.08.12.998 >/dev/null 2>&1; then
    fail "runtime BUILD-INFO version was accepted for a different kit VERSION"
fi
printf 'dist-version: 2026.08.12.999\n' \
    >> "$base/runtime/ABLETON-WINE-BUILD-INFO.txt"
cp -- "$base/runtime/ABLETON-WINE-BUILD-INFO.txt" "$base/BUILD-INFO.txt"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" \
    || fail "duplicate dist-version records were accepted"
ok "runtime BUILD-INFO has one distribution version and must match the kit VERSION"

base="$(new_env build-info-mismatch)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
printf 'unexpected: external mutation\n' >> "$base/BUILD-INFO.txt"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" || fail "nonidentical packaged and runtime BUILD-INFO was accepted"
ok "runtime BUILD-INFO must exactly match the packaged record"

base="$(new_env build-info-grammar)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
sed -i 's/(Qt 6[.]2 link)/(Qt 6.3 link)/' "$base/runtime/ABLETON-WINE-BUILD-INFO.txt" "$base/BUILD-INFO.txt"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" || fail "noncanonical built-panel grammar was accepted"
make_runtime "$base/runtime-2" "$base/BUILD-INFO-2.txt" skipped
sed -i 's/skipped (Qt6 Widgets unavailable)/skipped (arbitrary reason)/' \
    "$base/runtime-2/ABLETON-WINE-BUILD-INFO.txt" "$base/BUILD-INFO-2.txt"
runtime_fails_validation "$base/runtime-2" "$base/BUILD-INFO-2.txt" \
    || fail "arbitrary skipped-panel reason was accepted"
ok "panel BUILD-INFO accepts only the declared built/skipped grammar"

base="$(new_env probe-seal)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" skipped
printf '# mutation\n' >> "$base/runtime/bin/pipewire-version-probe"
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" || fail "modified native compatibility probe was accepted"
ok "native compatibility probe is sealed by BUILD-INFO"

make_runtime_only_kit()
{
    local base="$1" version=2026.08.12.999
    local kit="$base/kit" runtime_name=wine-d2d1-nspa-11.13
    local payload="$base/payload"
    mkdir -p -- "$kit/scripts/lib" "$kit/dist" "$kit/bin" \
        "$payload/$runtime_name/lib/wine/x86_64-windows" \
        "$payload/$runtime_name/lib/wine/x86_64-unix"
    cp -- "$here/install.sh" "$here/installer.sh" "$here/setup-prefix.sh" \
        "$kit/scripts/"
    cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" "$here/lib/live-options.sh" \
        "$here/lib/manifest.sh" "$here/lib/pipeasio.sh" "$kit/scripts/lib/"
    printf '%s\n' "$version" > "$kit/VERSION"
    make_runtime "$payload/$runtime_name" "$base/BUILD-INFO.txt" built
    cat > "$payload/$runtime_name/bin/wine" <<'EOF'
#!/bin/sh
case "${1:-}" in
    --version) echo 'wine fixture' ;;
esac
exit 0
EOF
    cat > "$payload/$runtime_name/bin/wineserver" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 755 "$payload/$runtime_name/bin/wine" "$payload/$runtime_name/bin/wineserver"
    for required in \
        lib/wine/x86_64-windows/libusb-1.0.dll \
        lib/wine/x86_64-unix/libusb-1.0.so \
        lib/wine/x86_64-unix/comdlg32.so \
        lib/wine/x86_64-unix/winealsa.so \
        lib/wine/x86_64-unix/winegstreamer.so; do
        printf 'runtime fixture: %s\n' "$required" > "$payload/$runtime_name/$required"
    done
    cp -- "$base/BUILD-INFO.txt" "$kit/dist/BUILD-INFO-$version.txt"
    cp -- "$payload/$runtime_name/bin/pipewire-version-probe" "$kit/bin/pipewire-version-probe"
    tar -C "$payload" -I zstd -cf "$kit/dist/$runtime_name-$version.tar.zst" "$runtime_name"
    (
        cd "$kit/dist"
        sha256sum "$runtime_name-$version.tar.zst" > "$runtime_name-$version.tar.zst.sha256"
    )
    mkdir -p -- "$base/fakebin"
    cat > "$base/fakebin/readelf" <<'EOF'
#!/bin/sh
cat <<'OUT'
  Shared library: [libusb-1.0.so.0]
  Shared library: [libpipewire-0.3.so.0]
  Shared library: [libgstreamer-1.0.so.0]
OUT
EOF
    cat > "$base/fakebin/strings" <<'EOF'
#!/bin/sh
echo org.freedesktop.portal.FileChooser
EOF
    chmod 755 "$base/fakebin/readelf" "$base/fakebin/strings"
}

base="$(new_env fresh-runtime-only)"
make_runtime_only_kit "$base"
run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err" || fail "fresh runtime-only install failed"
[ -f "$base/runtime/.ableton-linux-runtime" ] || fail "runtime-only install did not promote its runtime"
[ ! -e "$base/home/.local/bin/pipeasio-settings" ] \
    && [ ! -e "$base/xdg/data/applications/pipeasio-settings.desktop" ] \
    && [ ! -e "$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg" ] \
    || fail "fresh runtime-only install created panel integration"
runtime_only_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
if [ -r "$runtime_only_manifest" ] && awk -F '\t' \
    -v command="$base/home/.local/bin/pipeasio-settings" \
    -v desktop="$base/xdg/data/applications/pipeasio-settings.desktop" \
    -v icon="$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg" \
    '$2 == command || $2 == desktop || $2 == icon { found=1 } END { exit !found }' \
    "$runtime_only_manifest"; then
    fail "fresh runtime-only install claimed absent panel integration"
fi
ok "fresh runtime-only install leaves optional panel integration absent"

prepare_runtime_metadata_fixture()
{
    local base="$1"
    make_runtime_only_kit "$base"
    mkdir -p -- "$base/runtime/bin" \
        "$base/runtime/.ableton-linux-rollback" \
        "$base/xdg/config/ableton-wine" "$base/xdg/config/pipeasio"
    cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
[ "${1:-}" != --version ] || echo 'old wine fixture'
exit 0
EOF
    printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/wineserver"
    chmod 755 "$base/runtime/bin/wine" "$base/runtime/bin/wineserver"
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
    printf 'old metadata generation\n' \
        > "$base/runtime/.ableton-linux-rollback/old-sentinel"
    printf 'format=0\nold=mixed-metadata-must-not-survive-success\n' \
        > "$base/runtime/.ableton-linux-rollback/metadata"
    cat > "$base/xdg/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
linkd=$base/xdg/data/ableton-wine/ableton-linkd
EOF
    printf '[pipeasio]\nbuffer_size = 883\n' \
        > "$base/xdg/config/pipeasio/config.ini"
}

run_runtime_installer_fixture()
{
    local base="$1"
    shift
    run_isolated "$base" env \
        PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_WINEPREFIX="$base/prefix" \
        PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
        "$@" bash "$base/kit/scripts/installer.sh" runtime install \
        --runtime-root "$base/runtime" --yes
}

find_saved_runtime()
{
    local base="$1" candidate
    for candidate in "$base"/runtime-rollback-*; do
        [ -d "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

base="$(new_env rollback-metadata-success)"
prepare_runtime_metadata_fixture "$base"
if ! run_runtime_installer_fixture "$base" >"$base/out" 2>"$base/err"; then
    sed -n '1,120p' "$base/err" >&2
    fail "runtime update failed while replacing rollback metadata"
fi
[ "$(grep -c '^== validate runtime payload:' "$base/out")" -eq 1 ] \
    || fail "runtime install validates and extracts its payload more than once"
saved_runtime="$(find_saved_runtime "$base")" \
    || fail "runtime update did not retain a saved runtime"
saved_meta="$saved_runtime/.ableton-linux-rollback"
[ -r "$saved_meta/metadata" ] \
    && [ -r "$saved_meta/installer-config" ] \
    && [ -r "$saved_meta/pipeasio-config.ini" ] \
    || fail "published rollback metadata is incomplete"
[ ! -e "$saved_meta/old-sentinel" ] \
    && [ ! -e "$saved_runtime/.ableton-linux-rollback-incomplete" ] \
    || fail "published rollback metadata mixed old and new generations"
grep -qxF 'format=1' "$saved_meta/metadata" \
    || fail "published rollback metadata has the wrong format"
grep -qxF 'installer_config_state=present' "$saved_meta/metadata" \
    || fail "published rollback metadata omits its installer snapshot"
grep -qxF 'pipeasio_config_state=present' "$saved_meta/metadata" \
    || fail "published rollback metadata omits its PipeASIO snapshot"
if find "$saved_runtime" -maxdepth 1 -name '.ableton-linux-rollback.new.*' -print -quit \
    | grep -q .; then
    fail "successful metadata publication left a staging directory"
fi
ok "runtime update atomically replaces rollback metadata as one complete generation"

base="$(new_env rollback-metadata-copy-failure)"
prepare_runtime_metadata_fixture "$base"
real_cp="$(command -v cp)"
cat > "$base/fakebin/cp" <<EOF
#!/bin/bash
args=("\$@")
n=\${#args[@]}
target=\${args[\$((n-1))]}
case "\$target" in
    */.ableton-linux-rollback.new.*/installer-config) exit 91 ;;
esac
exec "$real_cp" "\$@"
EOF
chmod 755 "$base/fakebin/cp"
if run_runtime_installer_fixture "$base" >"$base/out" 2>"$base/err"; then
    fail "injected rollback snapshot-copy failure reported success"
fi
saved_runtime="$(find_saved_runtime "$base")" \
    || fail "committed runtime update lost its saved runtime after metadata failure"
saved_meta="$saved_runtime/.ableton-linux-rollback"
[ -e "$saved_runtime/.ableton-linux-rollback-incomplete" ] \
    || fail "metadata copy failure published a rollback candidate as complete"
grep -qxF 'old metadata generation' "$saved_meta/old-sentinel" \
    || fail "metadata copy failure removed the previous metadata sentinel"
grep -qxF 'format=0' "$saved_meta/metadata" \
    || fail "metadata copy failure replaced the previous metadata record"
[ ! -e "$saved_meta/installer-config" ] && [ ! -e "$saved_meta/pipeasio-config.ini" ] \
    || fail "metadata copy failure published mixed snapshot files"
if find "$saved_runtime" -maxdepth 1 -name '.ableton-linux-rollback.new.*' -print -quit \
    | grep -q .; then
    fail "metadata copy failure left a publishable staging directory"
fi
if run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$here/rollback.sh" >"$base/rollback.out" 2>"$base/rollback.err"; then
    fail "rollback selected a candidate with incomplete metadata"
fi
grep -qF 'no completed runtime rollback is available' "$base/rollback.err" \
    || fail "incomplete metadata candidate refusal was not explicit"
ok "snapshot-copy failure preserves old metadata and leaves an unselectable incomplete candidate"

base="$(new_env rollback-marker-permission-failure)"
prepare_runtime_metadata_fixture "$base"
marker_txn="$base/marker-commit"
private_backup="$base/runtime.transaction-${marker_txn##*/}"
mkdir -p -- "$marker_txn"
mv -- "$base/runtime" "$private_backup"
mkdir -p -- "$base/runtime"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
printf '%s\t%s\n' "$base/runtime" "$private_backup" > "$marker_txn/runtime.tsv"
chmod 0555 -- "$private_backup"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash "$base/kit/scripts/install.sh" --commit "$marker_txn" \
    >"$base/out" 2>"$base/err"; then
    fail "runtime update succeeded when its private incomplete marker could not be created"
fi
[ -n "$private_backup" ] && [ -f "$private_backup/.ableton-linux-runtime" ] \
    || fail "marker failure did not retain the old runtime under its private transaction name"
if find "$base" -maxdepth 1 -type d -name 'runtime-rollback-*' -print -quit | grep -q .; then
    fail "marker failure exposed a publicly selectable rollback candidate"
fi
[ -n "$marker_txn" ] && [ ! -e "$marker_txn/runtime-rollback-path" ] \
    || fail "marker failure published a rollback path record"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    || fail "marker failure displaced the newly selected runtime"
chmod 0755 -- "$private_backup"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash "$base/kit/scripts/install.sh" --commit "$marker_txn" \
    >"$base/retry.out" 2>"$base/retry.err" \
    || fail "runtime rollback finalization was not retryable after marker failure"
retry_saved="$(find_saved_runtime "$base")" \
    || fail "commit retry did not publish the saved runtime"
[ -f "$retry_saved/.ableton-linux-rollback-incomplete" ] \
    && [ "$(stat -c '%a' -- "$retry_saved/.ableton-linux-rollback-incomplete")" = 600 ] \
    || fail "commit retry did not publish a private-mode incomplete marker"
ok "incomplete marker is sealed before public rollback exposure and commit is retryable"

install_fake_host_tools()
{
    local base="$1"
    mkdir -p -- "$base/fakebin"
    cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/bin/sh
set -eu
state="${XDG_CONFIG_HOME:?}/mimeapps.list"
case "${1:-}" in
    query)
        [ "${2:-}" = default ] && [ "$#" -eq 3 ]
        awk -F '=' -v type="$3" '$1 == type { value=$2 } END { print value }' \
            "$state" 2>/dev/null || true ;;
    default)
        [ "$#" -ge 3 ]
        application="$2"
        shift 2
        mkdir -p -- "$(dirname "$state")"
        touch "$state"
        for type in "$@"; do
            awk -F '=' -v type="$type" '$1 != type' "$state" > "$state.tmp"
            printf '%s=%s\n' "$type" "$application" >> "$state.tmp"
            mv -- "$state.tmp" "$state"
        done ;;
    *) exit 2 ;;
esac
EOF
    chmod 755 "$base/fakebin/systemctl" "$base/fakebin/xdg-mime"
}

make_path_without_pipewire_tools()
{
    local base="$1" output dir entry name
    local old_ifs="$IFS"
    output="$base/no-pw-tools-path"
    mkdir -p -- "$output"
    IFS=:
    for dir in "$base/fakebin" $PATH; do
        [ -d "$dir" ] || continue
        for entry in "$dir"/*; do
            [ -f "$entry" ] && [ -x "$entry" ] || continue
            name="$(basename "$entry")"
            case "$name" in pw-dump|pw-top) continue ;; esac
            [ -e "$output/$name" ] || [ -L "$output/$name" ] \
                || ln -s -- "$entry" "$output/$name"
        done
    done
    IFS="$old_ifs"
    printf '%s\n' "$output"
}

run_component_install()
{
    local base="$1" runtime="$2"
    shift 2
    run_isolated "$base" env \
        PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$runtime" \
        ABLETON_WINEPREFIX="$base/prefix" \
        PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
        bash "$here/install.sh" "$@"
}

manifest_has_path()
{
    local manifest="$1" wanted="$2"
    awk -F '\t' -v wanted="$wanted" '$2 == wanted { found=1 } END { exit !found }' "$manifest"
}

base="$(new_env panel-lifecycle)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-built.out" 2>"$base/install-built.err" \
    || fail "built-panel integration failed"
panel_command="$base/home/.local/bin/pipeasio-settings"
panel_desktop="$base/xdg/data/applications/pipeasio-settings.desktop"
panel_icon="$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg"
manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
[ -L "$panel_command" ] || fail "panel command was not installed as a managed symlink"
[ "$(readlink -- "$panel_command")" = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "panel command points outside the selected runtime"
[ -f "$panel_desktop" ] && [ -f "$panel_icon" ] || fail "panel desktop/icon ignored custom XDG data home"
[ ! -e "$base/home/.local/share/applications/pipeasio-settings.desktop" ] \
    || fail "panel desktop escaped custom XDG data home"
grep -Fq $'symlink\t'"$panel_command"$'\t' "$manifest" \
    || fail "literal panel symlink ownership was not recorded"
recorded_link_digest="$(awk -F '\t' -v wanted="$panel_command" \
    '$1 == "symlink" && $2 == wanted { print $3; exit }' "$manifest")"
literal_link_digest="$({ printf 'symlink\0'; readlink -n -- "$panel_command"; } \
    | sha256sum | awk '{print $1}')"
[ "$recorded_link_digest" = "$literal_link_digest" ] \
    || fail "panel ownership hashed the symlink referent instead of its literal target"
manifest_has_path "$manifest" "$panel_desktop" || fail "panel desktop ownership was not recorded"
manifest_has_path "$manifest" "$panel_icon" || fail "panel icon ownership was not recorded"
live_options="$base/xdg/data/ableton-wine/lib/live-options.sh"
[ -f "$live_options" ] && [ "$(stat -c '%a' "$live_options")" = 644 ] \
    || fail "The installer writes the audio thread settings script with mode 644."
cmp -s -- "$here/lib/live-options.sh" "$live_options" \
    || fail "The installed audio thread settings script matches its source file."
manifest_has_path "$manifest" "$live_options" \
    || fail "The installation record lists the audio thread settings script."
ok "built panel installs transactionally under custom XDG paths"

for durable_tool in audio-report.sh setup-realtime.sh rollback.sh; do
    [ -x "$base/xdg/data/ableton-wine/$durable_tool" ] \
        || fail "integration did not persist executable $durable_tool"
done
grep -qF "Audio report: $base/xdg/data/ableton-wine/audio-report.sh" "$base/install-built.out" \
    || fail "install did not print the durable audio-report path"
grep -qF "Realtime setup: $base/xdg/data/ableton-wine/setup-realtime.sh" "$base/install-built.out" \
    || fail "install did not print the durable realtime-setup path"
grep -qF "Runtime rollback: $base/xdg/data/ableton-wine/rollback.sh" "$base/install-built.out" \
    || fail "install did not print the durable rollback path"
ok "integration persists and reports durable diagnostic and recovery tools"

panel_lifecycle_base="$base"
base="$(new_env missing-optional-pipewire-tools)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
no_pw_path="$(make_path_without_pipewire_tools "$base")"
run_isolated "$base" env \
    PATH="$no_pw_path" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    /bin/bash "$here/install.sh" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "missing optional PipeWire utilities blocked driver integration"
[ -L "$base/home/.local/bin/pipeasio-settings" ] \
    || fail "integration without PipeWire utilities omitted the packaged panel"
grep -qF 'Optional PipeWire tools missing: pw-dump, pw-top.' "$base/install.out" \
    || fail "integration did not name both missing optional PipeWire utilities"
grep -qF 'pw-dump enables panel device lists; pw-top enables Monitor; both enrich audio-report.sh.' \
    "$base/install.out" \
    || fail "missing optional PipeWire utilities did not produce accurate advice"
run_isolated "$base" env \
    PATH="$no_pw_path" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    /bin/bash "$here/audio-report.sh" >"$base/report.out" 2>"$base/report.err" \
    || fail "audio report failed without pw-dump and pw-top"
grep -qF 'unavailable: pw-dump is not installed' "$base/report.out" \
    || fail "audio report did not identify missing pw-dump"
grep -qF 'unavailable: pw-top is not installed' "$base/report.out" \
    || fail "audio report did not identify missing pw-top"
ok "missing pw-dump/pw-top remains installable and produces actionable diagnostic advice"
base="$panel_lifecycle_base"

# Remove the panel through an externally-owned component transaction, then
# exercise the same rollback entry point used by the top-level installer.
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
txn="$base/panel-transition-transaction"
mkdir -p -- "$txn"
run_component_install "$base" "$base/runtime" --integration-only --transaction-dir "$txn" \
    >"$base/install-skipped-txn.out" 2>"$base/install-skipped-txn.err" \
    || { sed -n '1,120p' "$base/install-skipped-txn.err" >&2; fail "built-to-skipped transactional transition failed"; }
[ ! -e "$panel_command" ] && [ ! -L "$panel_command" ] \
    && [ ! -e "$panel_desktop" ] && [ ! -e "$panel_icon" ] \
    || fail "skipped panel left managed host artifacts"
! manifest_has_path "$manifest" "$panel_command" || fail "skipped panel retained command ownership"

# Put the runtime payload back before restoring its host projections. Runtime
# payload changes belong to the runtime transaction, not this integration one.
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" built
run_component_install "$base" "$base/runtime" --rollback "$txn" \
    >"$base/rollback.out" 2>"$base/rollback.err" \
    || fail "panel integration rollback failed"
[ -L "$panel_command" ] && [ -f "$panel_desktop" ] && [ -f "$panel_icon" ] \
    || fail "rollback did not restore panel host projections"
manifest_has_path "$manifest" "$panel_command" || fail "rollback did not restore panel ownership"
ok "panel transition participates in component rollback lifecycle"

write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-skipped.out" 2>"$base/install-skipped.err" \
    || fail "committed built-to-skipped transition failed"
[ ! -e "$panel_command" ] && [ ! -L "$panel_command" ] \
    && [ ! -e "$panel_desktop" ] && [ ! -e "$panel_icon" ] \
    || fail "committed skipped panel left managed artifacts"
! manifest_has_path "$manifest" "$panel_command" || fail "built-to-skipped transition left stale command ownership"
! manifest_has_path "$manifest" "$panel_desktop" || fail "built-to-skipped transition left stale desktop ownership"
! manifest_has_path "$manifest" "$panel_icon" || fail "built-to-skipped transition left stale icon ownership"
ok "built-to-skipped transition removes and de-owns all panel projections"

base="$(new_env panel-desktop-escaping)"
install_fake_host_tools "$base"
runtime_with_metacharacters="$base/runtime with 25% space"
make_runtime "$runtime_with_metacharacters" "$base/BUILD-INFO.txt" built
run_component_install "$base" "$runtime_with_metacharacters" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "panel integration failed for a runtime path needing desktop Exec quoting"
escaped_runtime="${runtime_with_metacharacters//%/%%}"
grep -qxF "Exec=\"$escaped_runtime/bin/pipeasio-settings\"" \
    "$base/xdg/data/applications/pipeasio-settings.desktop" \
    || fail "panel desktop Exec did not quote spaces and escape literal percent signs"
ok "panel desktop Exec safely represents custom runtime paths"

base="$(new_env skipped-restores-prestate)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-built.out" 2>"$base/install-built.err" \
    || fail "prestate transition fixture install failed"
prestate_command="$base/home/.local/bin/pipeasio-settings"
prestate_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
prestate_index="$base/xdg/state/ableton-wine/install-prestate.tsv"
prestate_id="$(printf '%s' "$prestate_command" | sha256sum | awk '{print $1}')"
prestate_backup="$base/xdg/state/ableton-wine/install-prestate/$prestate_id"
printf '#!/bin/sh\necho original-prestate\n' > "$base/original-prestate-command"
chmod 755 "$base/original-prestate-command"
mkdir -p -- "$(dirname "$prestate_backup")"
ln -s -- "$base/original-prestate-command" "$prestate_backup"
printf 'present\t%s\t%s\n' "$prestate_command" "$prestate_backup" >> "$prestate_index"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-skipped.out" 2>"$base/install-skipped.err" \
    || fail "built-to-skipped transition with prestate failed"
[ -L "$prestate_command" ] \
    && [ "$(readlink -- "$prestate_command")" = "$base/original-prestate-command" ] \
    || fail "built-to-skipped transition did not immediately restore foreign prestate"
! manifest_has_path "$prestate_manifest" "$prestate_command" \
    || fail "restored foreign prestate remained claimed after built-to-skipped transition"
grep -qF "restored your previous $prestate_command" "$base/install-skipped.out" \
    || fail "immediate prestate restoration was not reported"
ok "built-to-skipped transition restores exact foreign prestate before de-ownership"

[ ! -e "$prestate_backup" ] && [ ! -L "$prestate_backup" ] \
    || fail "restored prestate backup was not consumed"
! awk -F '\t' -v p="$prestate_command" '$2 == p { found=1 } END { exit !found }' \
    "$prestate_index" || fail "restored prestate index record was not consumed"
rm -f -- "$prestate_command"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" built
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-built-again.out" 2>"$base/install-built-again.err" \
    || fail "second built-panel epoch failed"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-skipped-again.out" 2>"$base/install-skipped-again.err" \
    || fail "second skipped-panel epoch failed"
[ ! -e "$prestate_command" ] && [ ! -L "$prestate_command" ] \
    || fail "consumed foreign prestate was resurrected in a later panel epoch"
ok "restored panel prestate is consumed and cannot be resurrected"

base="$(new_env skipped-restores-absent-managed-prestate)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-built.out" 2>"$base/install-built.err" \
    || fail "absent-managed prestate fixture install failed"
absent_command="$base/home/.local/bin/pipeasio-settings"
absent_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
absent_index="$base/xdg/state/ableton-wine/install-prestate.tsv"
absent_id="$(printf '%s' "$absent_command" | sha256sum | awk '{print $1}')"
absent_backup="$base/xdg/state/ableton-wine/install-prestate/$absent_id"
printf '#!/bin/sh\necho original-absent-prestate\n' > "$base/original-absent-command"
chmod 755 "$base/original-absent-command"
mkdir -p -- "$(dirname "$absent_backup")"
ln -s -- "$base/original-absent-command" "$absent_backup"
printf 'present\t%s\t%s\n' "$absent_command" "$absent_backup" >> "$absent_index"
rm -f -- "$absent_command"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-skipped.out" 2>"$base/install-skipped.err" \
    || fail "skipped transition failed for an absent managed path"
[ -L "$absent_command" ] \
    && [ "$(readlink -- "$absent_command")" = "$base/original-absent-command" ] \
    || fail "absent managed panel path stranded its foreign prestate"
! manifest_has_path "$absent_manifest" "$absent_command" \
    || fail "restored absent-path prestate remained claimed"
ok "absent managed panel path restores prestate before de-ownership"

base="$(new_env runtime-reconcile-absent-claimed-panel)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-built.out" 2>"$base/install-built.err" \
    || fail "runtime reconcile panel fixture install failed"
reconcile_command="$base/home/.local/bin/pipeasio-settings"
reconcile_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
reconcile_index="$base/xdg/state/ableton-wine/install-prestate.tsv"
reconcile_id="$(printf '%s' "$reconcile_command" | sha256sum | awk '{print $1}')"
reconcile_backup="$base/xdg/state/ableton-wine/install-prestate/$reconcile_id"
printf '#!/bin/sh\necho original-reconcile-prestate\n' > "$base/original-reconcile-command"
chmod 755 "$base/original-reconcile-command"
mkdir -p -- "$(dirname "$reconcile_backup")"
ln -s -- "$base/original-reconcile-command" "$reconcile_backup"
printf 'present\t%s\t%s\n' "$reconcile_command" "$reconcile_backup" \
    >> "$reconcile_index"
rm -f -- "$reconcile_command"
make_runtime_only_kit "$base"
if ! run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/runtime-update.out" 2>"$base/runtime-update.err"; then
    sed -n '1,120p' "$base/runtime-update.err" >&2
    fail "built runtime-only reconcile failed for an absent claimed panel path"
fi
[ -L "$reconcile_command" ] \
    && [ "$(readlink -- "$reconcile_command")" = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "runtime-only reconcile did not reinstate the claimed panel command"
manifest_has_path "$reconcile_manifest" "$reconcile_command" \
    || fail "runtime-only reconcile de-owned the reinstated panel command"
[ -L "$reconcile_backup" ] \
    && [ "$(readlink -- "$reconcile_backup")" = "$base/original-reconcile-command" ] \
    || fail "runtime-only reconcile replaced the retained prestate backup"
grep -qF $'present\t'"$reconcile_command"$'\t'"$reconcile_backup" "$reconcile_index" \
    || fail "runtime-only reconcile discarded the retained prestate index"
if ! run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes \
    >"$base/uninstall.out" 2>"$base/uninstall.err"; then
    sed -n '1,120p' "$base/uninstall.err" >&2
    fail "uninstall failed after runtime-only panel reconcile"
fi
[ -L "$reconcile_command" ] \
    && [ "$(readlink -- "$reconcile_command")" = "$base/original-reconcile-command" ] \
    || fail "uninstall did not restore prestate retained across runtime-only reconcile"
ok "built runtime-only reconcile reinstates claimed paths and preserves their uninstall prestate"

base="$(new_env foreign-panel-command)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
mkdir -p -- "$base/home/.local/bin"
cat > "$base/home/.local/bin/pipeasio-settings" <<'EOF'
#!/bin/sh
echo foreign-settings-command
EOF
chmod 755 "$base/home/.local/bin/pipeasio-settings"
foreign_digest="$(sha256sum -- "$base/home/.local/bin/pipeasio-settings" | awk '{print $1}')"
mkdir -p -- "$base/xdg/state/ableton-wine"
printf 'format=1\nowner=ableton-linux\n' \
    > "$base/xdg/state/ableton-wine/.ableton-linux-state"
printf 'symlink\t%s\t%s\n' "$base/home/.local/bin/pipeasio-settings" \
    0000000000000000000000000000000000000000000000000000000000000000 \
    > "$base/xdg/state/ableton-wine/install-manifest.tsv"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "foreign panel command prevented otherwise safe integration"
[ ! -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ "$(sha256sum -- "$base/home/.local/bin/pipeasio-settings" | awk '{print $1}')" = "$foreign_digest" ] \
    || fail "foreign pipeasio-settings command was replaced"
foreign_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
! manifest_has_path "$foreign_manifest" "$base/home/.local/bin/pipeasio-settings" \
    || fail "foreign pipeasio-settings command was claimed in the manifest"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/skipped.out" 2>"$base/skipped.err" \
    || fail "skipped-panel update failed beside foreign command"
[ "$(sha256sum -- "$base/home/.local/bin/pipeasio-settings" | awk '{print $1}')" = "$foreign_digest" ] \
    || fail "skipped-panel cleanup removed a foreign command"
ok "foreign pipeasio-settings command is preserved and de-owned"

install_managed_link()
{
    local base="$1" link_text="$2" target="$3" txn="$4"
    mkdir -p -- "$txn"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_init
        ableton_install_symlink "$2" "$3"
        ableton_write_ownership_manifest
        rm -f -- "$ABLETON_TRANSACTION_DIR/active"
    ' _ "$here" "$link_text" "$target"
}

run_minimal_uninstall()
{
    local base="$1"
    install_fake_host_tools "$base"
    run_isolated "$base" env \
        PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_LINK_MODE=off \
        bash "$here/uninstall.sh" --keep-prefix --yes
}

base="$(new_env symlink-prestate)"
managed_link="$base/home/.local/bin/pipeasio-settings"
mkdir -p -- "$(dirname "$managed_link")"
printf '#!/bin/sh\necho original\n' > "$base/original-foreign-command"
chmod 755 "$base/original-foreign-command"
ln -s -- "$base/original-foreign-command" "$managed_link"
install_managed_link "$base" "$base/managed-panel-v1" "$managed_link" "$base/txn-v1" \
    || fail "first managed symlink update failed"
[ "$(readlink -- "$managed_link")" = "$base/managed-panel-v1" ] \
    || fail "first managed symlink update did not take effect"
install_managed_link "$base" "$base/managed-panel-v2" "$managed_link" "$base/txn-v2" \
    || fail "second managed symlink update failed"
[ "$(readlink -- "$managed_link")" = "$base/managed-panel-v2" ] \
    || fail "second managed symlink update did not take effect"
run_minimal_uninstall "$base" >"$base/uninstall.out" 2>"$base/uninstall.err" \
    || fail "uninstall failed while restoring symlink prestate"
[ -L "$managed_link" ] \
    && [ "$(readlink -- "$managed_link")" = "$base/original-foreign-command" ] \
    || fail "uninstall did not restore the original foreign symlink"
ok "two managed symlink updates retain and restore original foreign prestate"

base="$(new_env retargeted-managed-link)"
managed_link="$base/home/.local/bin/pipeasio-settings"
install_managed_link "$base" "$base/managed-panel" "$managed_link" "$base/txn" \
    || fail "managed symlink fixture install failed"
rm -f -- "$managed_link"
ln -s -- "$base/user-retargeted-panel" "$managed_link"
run_minimal_uninstall "$base" >"$base/uninstall.out" 2>"$base/uninstall.err" \
    || fail "uninstall treated a retargeted managed link as a fatal residual"
[ -L "$managed_link" ] \
    && [ "$(readlink -- "$managed_link")" = "$base/user-retargeted-panel" ] \
    || fail "uninstall removed a user-retargeted managed link"
grep -qF "kept user-owned link $managed_link" "$base/uninstall.out" \
    || fail "preserved retargeted link was not reported"
ok "uninstall preserves a user-retargeted managed symlink"

make_legacy_panel_fixture()
{
    local base="$1" command_mode="${2:-managed}"
    local command="$base/home/.local/bin/pipeasio-settings"
    local desktop="$base/xdg/data/applications/pipeasio-settings.desktop"
    local icon="$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg"
    make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
    mkdir -p -- "$base/home/.local/bin" "$(dirname "$desktop")" \
        "$(dirname "$icon")" "$base/xdg/data/ableton-wine"
    printf '2026.08.12.999\n' > "$base/xdg/data/ableton-wine/VERSION"
    case "$command_mode" in
        managed) ln -s -- "$base/runtime/bin/pipeasio-settings" "$command" ;;
        foreign)
            printf '#!/bin/sh\necho foreign-legacy-panel\n' > "$base/foreign-panel-command"
            chmod 755 "$base/foreign-panel-command"
            ln -s -- "$base/foreign-panel-command" "$command"
            ;;
        *) fail "unknown legacy panel fixture mode" ;;
    esac
    cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PipeASIO Settings
Exec=$command
Icon=pipeasio
EOF
    cp -- "$base/runtime/share/icons/hicolor/scalable/apps/pipeasio.svg" "$icon"
}

base="$(new_env legacy-panel-cleanup)"
make_legacy_panel_fixture "$base" managed
run_minimal_uninstall "$base" >"$base/out" 2>"$base/err" \
    || fail "uninstall failed while cleaning legacy panel projections"
[ ! -e "$base/home/.local/bin/pipeasio-settings" ] \
    && [ ! -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ ! -e "$base/xdg/data/applications/pipeasio-settings.desktop" ] \
    && [ ! -e "$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg" ] \
    || fail "uninstall left a recognisable legacy panel projection"
grep -qF 'removed legacy PipeASIO panel file' "$base/out" \
    || fail "legacy panel cleanup was not reported"
ok "uninstall removes exact pre-manifest PipeASIO panel projections"

base="$(new_env foreign-legacy-panel-symlink)"
make_legacy_panel_fixture "$base" foreign
run_minimal_uninstall "$base" >"$base/out" 2>"$base/err" \
    || fail "foreign legacy panel symlink made uninstall fail"
[ -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ "$(readlink -- "$base/home/.local/bin/pipeasio-settings")" \
        = "$base/foreign-panel-command" ] \
    || fail "uninstall removed a foreign panel symlink"
grep -qF "kept independently installed PipeASIO panel file $base/home/.local/bin/pipeasio-settings" \
    "$base/out" || fail "foreign legacy panel symlink preservation was not reported"
ok "legacy cleanup preserves an independently targeted panel symlink"

base="$(new_env unsafe-uninstall-no-state)"
mkdir -p -- "$base/unrecognised-runtime"
printf 'foreign runtime\n' > "$base/unrecognised-runtime/foreign"
if run_isolated "$base" env \
    ABLETON_WINE_ROOT="$base/unrecognised-runtime" \
    ABLETON_WINEPREFIX="$base/prefix" ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes \
    >"$base/out" 2>"$base/err"; then
    fail "unsafe uninstall accepted an unrecognised custom runtime"
fi
[ ! -e "$base/xdg/state/ableton-wine/.ableton-linux-state" ] \
    && [ ! -e "$base/xdg/state/ableton-wine" ] \
    || fail "unsafe uninstall refusal created an installer state marker"
[ -f "$base/unrecognised-runtime/foreign" ] \
    || fail "unsafe uninstall refusal changed the unrecognised runtime"
grep -qF 'refusing to delete unrecognised custom runtime' "$base/err" \
    || fail "unsafe uninstall refusal was not explicit"
ok "unsafe uninstall refuses before creating or claiming installer state"

make_registry_runtime()
{
    local base="$1"
    local runtime="$base/runtime"
    mkdir -p -- "$runtime/bin" "$base/prefix" "$base/fakebin" \
        "$base/xdg/state/ableton-wine"
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$runtime/.ableton-linux-runtime"
    printf 'registry\n' > "$base/prefix/system.reg"
    printf 'format=1\nprefix=%s\n' "$base/prefix" > "$base/prefix/.ableton-linux-prefix"
    printf 'format=1\nowner=ableton-linux\n' > "$base/xdg/state/ableton-wine/.ableton-linux-state"
    printf 'runtime\t%s\twine-d2d1-nspa-11.13\n' "$runtime" \
        > "$base/xdg/state/ableton-wine/install-manifest.tsv"
    : > "$base/registry-present"
    cat > "$runtime/bin/wine" <<'EOF'
#!/bin/bash
printf '%s\t%s\n' "${WINEPREFIX:-}" "$*" >> "${ABLETON_TEST_REGISTRY_LOG:?}"
corrupt_rollback_snapshots()
{
    local txn
    [ "${ABLETON_TEST_CORRUPT_ROLLBACK_SNAPSHOTS:-0}" -eq 1 ] || return 0
    [ ! -e "${ABLETON_TEST_CORRUPTION_MARKER:?}" ] || return 0
    for txn in "${XDG_STATE_HOME:?}"/ableton-wine/transactions/rollback.*; do
        [ -r "$txn/files.tsv" ] || continue
        /bin/rm -rf -- "$txn/files"
        : > "${ABLETON_TEST_CORRUPTION_MARKER:?}"
        return 0
    done
}
case "${1:-}" in
    reg)
        case "${2:-}" in
            query)
                [ "${ABLETON_TEST_REGISTRY_QUERY_BROKEN:-0}" -eq 0 ] || exit 1
                [ "${3:-}" != 'HKCU\Software' ] || exit 0
                [ -e "${ABLETON_TEST_REGISTRY_STATE:?}" ] || exit 1
                case " $* " in
                    *' /v CLSID '*)
                        printf '    CLSID    REG_SZ    {2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}\n'
                        ;;
                esac
                ;;
            delete)
                if [ "${ABLETON_TEST_REGISTRY_STICKY:-0}" -ne 0 ]; then
                    corrupt_rollback_snapshots
                    exit 1
                fi
                /bin/rm -f -- "${ABLETON_TEST_REGISTRY_STATE:?}"
                ;;
            *) exit 0 ;;
        esac
        ;;
    regsvr32)
        case " $* " in
            *' /u '*)
                [ "${ABLETON_TEST_REGISTRY_STICKY:-0}" -eq 0 ] || exit 1
                /bin/rm -f -- "${ABLETON_TEST_REGISTRY_STATE:?}"
                ;;
            *)
                [ "${ABLETON_TEST_REGISTRY_STICKY:-0}" -eq 0 ] || exit 1
                : > "${ABLETON_TEST_REGISTRY_STATE:?}"
                ;;
        esac
        ;;
esac
EOF
    cat > "$runtime/bin/wineserver" <<'EOF'
#!/bin/sh
printf 'wineserver %s\n' "$*" >> "${ABLETON_TEST_REGISTRY_LOG:?}"
exit 0
EOF
    cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 755 "$runtime/bin/wine" "$runtime/bin/wineserver" "$base/fakebin/systemctl"
}

run_registry_uninstall()
{
    local base="$1"
    shift
    run_isolated "$base" env \
        PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_LINK_MODE=off \
        ABLETON_TEST_REGISTRY_LOG="$base/registry.log" \
        ABLETON_TEST_REGISTRY_STATE="$base/registry-present" \
        "$@" bash "$here/uninstall.sh" --keep-prefix --yes
}

make_rollback_fixture()
{
    local base="$1" saved
    make_registry_runtime "$base"
    make_runtime "$base/runtime" "$base/current-BUILD-INFO.txt" skipped
    printf 'current generation\n' > "$base/runtime/current-generation"
    saved="$base/runtime-rollback-20260811T000000Z"
    make_runtime "$saved" "$base/saved-BUILD-INFO.txt" built
    cp -- "$base/runtime/bin/wine" "$base/runtime/bin/wineserver" "$saved/bin/"
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$saved/.ableton-linux-runtime"
    printf 'previous generation\n' > "$saved/previous-generation"

    ROLLBACK_INSTALLER_CONFIG="$base/xdg/config/ableton-wine/config"
    ROLLBACK_PIPEASIO_CONFIG="$base/xdg/config/pipeasio/config.ini"
    mkdir -p -- "$(dirname "$ROLLBACK_INSTALLER_CONFIG")" \
        "$(dirname "$ROLLBACK_PIPEASIO_CONFIG")" \
        "$saved/.ableton-linux-rollback"
    cat > "$ROLLBACK_INSTALLER_CONFIG" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
linkd=$base/xdg/data/ableton-wine/ableton-linkd
EOF
    printf '[pipeasio]\nbuffer_size = 512\n' > "$ROLLBACK_PIPEASIO_CONFIG"
    cat > "$saved/.ableton-linux-rollback/installer-config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=11
link_mode=off
linkd=$base/xdg/data/ableton-wine/ableton-linkd
EOF
    printf '[pipeasio]\nbuffer_size = 883\n' \
        > "$saved/.ableton-linux-rollback/pipeasio-config.ini"
    cat > "$saved/.ableton-linux-rollback/metadata" <<EOF
format=1
runtime_root=$base/runtime
prefix=$base/prefix
installer_config_path=$ROLLBACK_INSTALLER_CONFIG
installer_config_state=present
pipeasio_config_path=$ROLLBACK_PIPEASIO_CONFIG
pipeasio_config_state=present
panel_integration=1
EOF
    ROLLBACK_SAVED="$saved"
}

run_user_rollback()
{
    local base="$1"
    shift
    run_isolated "$base" env \
        PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_LINK_MODE=off \
        ABLETON_TEST_REGISTRY_LOG="$base/registry.log" \
        ABLETON_TEST_REGISTRY_STATE="$base/registry-present" \
        ABLETON_TEST_CORRUPTION_MARKER="$base/corruption-fired" \
        PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
        "$@" bash "$here/rollback.sh"
}

transaction_target_authorised_on_exit()
{
    local base="$1" target="$2"
    run_isolated "$base" env \
        ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_WINEPREFIX="$base/prefix" \
        TRANSACTION_TARGET="$target" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        check_on_exit()
        {
            trap - EXIT
            ableton_txn_target_allowed present "$TRANSACTION_TARGET" /unused || exit 1
            exit 0
        }
        trap check_on_exit EXIT
        exit 97
    ' _ "$here"
}

base="$(new_env reverse-target-exit)"
candidate="$base/runtime-rollback-check"
mkdir -p -- "$candidate/.ableton-linux-rollback"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$candidate/.ableton-linux-runtime"
transaction_target_authorised_on_exit \
    "$base" "$candidate/.ableton-linux-rollback/metadata" \
    || fail "valid reverse-runtime metadata target was refused during failure recovery"
printf 'format=1\nmalformed=yes\n' > "$candidate/.ableton-linux-runtime"
if transaction_target_authorised_on_exit \
    "$base" "$candidate/.ableton-linux-rollback/metadata"; then
    fail "malformed reverse-runtime marker authorised a recovery target"
fi
ok "failure recovery accepts only metadata inside an exactly marked reverse runtime"

base="$(new_env prestate-target-exit)"
prestate="$base/xdg/state/ableton-wine/install-prestate"
mkdir -p -- "$prestate"
valid_prestate="$prestate/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
transaction_target_authorised_on_exit "$base" "$valid_prestate" \
    || fail "valid pre-install backup target was refused during failure recovery"
if transaction_target_authorised_on_exit "$base" "$prestate/not-a-digest"; then
    fail "malformed pre-install backup target was authorised during failure recovery"
fi
ok "failure recovery accepts only exact pre-install backup slots from an EXIT trap"

base="$(new_env staged-prefix-register)"
make_registry_runtime "$base"
(
    export WINEPREFIX="$base/prefix"
    export ABLETON_TEST_REGISTRY_LOG="$base/registry.log"
    export ABLETON_TEST_REGISTRY_STATE="$base/registry-present"
    export ABLETON_TEST_REGISTRY_STICKY=0
    ableton_pipeasio_register "$base/runtime/bin/wine" "$base/runtime/bin/wineserver"
) >/dev/null 2>"$base/err" || fail "exact PipeASIO registration helper failed"
[ -e "$base/registry-present" ] || fail "PipeASIO registration helper did not leave a verified registration"
grep -Fq "$base/prefix"$'\tregsvr32 /s pipeasio64.dll' "$base/registry.log" \
    || fail "PipeASIO was not registered in the selected staged prefix"
registered_clsids="$(grep -Eo '\{[0-9A-Fa-f-]{36}\}' "$base/registry.log" | sort -u)"
[ "$registered_clsids" = '{2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}' ] \
    || fail "registration lifecycle touched an unexpected CLSID"
ok "registration deletes, registers, and queries only PipeASIO in the selected prefix"

base="$(new_env rollback-saved-runtime-busy)"
make_rollback_fixture "$base"
cp -- /bin/sleep "$ROLLBACK_SAVED/bin/rollback-busy-client"
"$ROLLBACK_SAVED/bin/rollback-busy-client" 60 &
saved_busy_pid=$!
sleep 0.1
if run_user_rollback "$base" env ABLETON_TEST_REGISTRY_STICKY=0 \
    >"$base/out" 2>"$base/err"; then
    kill "$saved_busy_pid" 2>/dev/null || true
    wait "$saved_busy_pid" 2>/dev/null || true
    fail "rollback promoted a saved runtime while a process executed from it"
fi
kill "$saved_busy_pid" 2>/dev/null || true
wait "$saved_busy_pid" 2>/dev/null || true
[ -f "$base/runtime/current-generation" ] && [ -f "$ROLLBACK_SAVED/previous-generation" ] \
    || fail "saved-runtime busy refusal changed the runtime layout"
grep -Eq 'Wine client is running|another Wine prefix is using this runtime' "$base/err" \
    || fail "saved-runtime busy refusal was not explicit"
# "close Live" is unactionable when the holder is a windowless agent, so the
# refusal names what it found rather than guessing at it.
grep -q 'rollback-busy-client (pid' "$base/err" \
    || fail "saved-runtime busy refusal does not name what holds the runtime"
ok "rollback refuses a process executing from the selected saved sibling, and names it"

base="$(new_env rollback-late-current-user)"
make_rollback_fixture "$base"
cp -- /bin/sleep "$base/runtime/bin/late-runtime-client"
cat > "$base/runtime/bin/pipewire-version-probe" <<'EOF'
#!/bin/bash
case "${1:-}" in
    --client) printf 'client=%s\n' "${PROBE_CLIENT:-}" ;;
    '')
        if [ ! -e "${ABLETON_TEST_LATE_PID_FILE:?}" ]; then
            "${ABLETON_TEST_LATE_CLIENT:?}" 60 >/dev/null 2>&1 &
            printf '%s\n' "$!" > "${ABLETON_TEST_LATE_PID_FILE:?}"
        fi
        printf 'client=%s\ndaemon=%s\n' "${PROBE_CLIENT:-}" "${PROBE_DAEMON:-}"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$base/runtime/bin/pipewire-version-probe"
if run_user_rollback "$base" env \
    ABLETON_TEST_REGISTRY_STICKY=0 \
    ABLETON_TEST_LATE_CLIENT="$base/runtime/bin/late-runtime-client" \
    ABLETON_TEST_LATE_PID_FILE="$base/late-runtime.pid" \
    >"$base/out" 2>"$base/err"; then
    fail "rollback missed a runtime client that started after preflight"
fi
[ -s "$base/late-runtime.pid" ] || fail "late-runtime recheck fixture did not start its client"
late_runtime_pid="$(cat "$base/late-runtime.pid")"
kill "$late_runtime_pid" 2>/dev/null || true
wait "$late_runtime_pid" 2>/dev/null || true
[ -f "$base/runtime/current-generation" ] && [ -f "$ROLLBACK_SAVED/previous-generation" ] \
    || fail "late-runtime recheck occurred after the runtime swap"
grep -Eq 'Wine client is running|another Wine prefix is using this runtime' "$base/err" \
    || fail "late-runtime recheck refusal was not explicit"
ok "rollback rechecks current and saved runtime users immediately before swap"

base="$(new_env rollback-signal-and-incomplete-candidate)"
make_rollback_fixture "$base"
blocked_saved="$base/runtime-rollback-20260812T000000Z"
cp -a -- "$ROLLBACK_SAVED" "$blocked_saved"
printf 'blocked incomplete generation\n' > "$blocked_saved/blocked-generation"
: > "$blocked_saved/.ableton-linux-rollback-incomplete"
real_mv="$(command -v mv)"
cat > "$base/fakebin/mv" <<EOF
#!/bin/bash
"$real_mv" "\$@" || exit \$?
args=("\$@")
n=\${#args[@]}
source=\${args[\$((n-2))]}
target=\${args[\$((n-1))]}
if [ "\$source" = "\${ABLETON_TEST_SIGNAL_SOURCE:-}" ] \
   && [[ "\$target" = "\$source-rollback-"* ]] \
   && [ ! -e "\${ABLETON_TEST_SIGNAL_MARKER:?}" ]; then
    : > "\${ABLETON_TEST_SIGNAL_MARKER:?}"
    kill -TERM "\$PPID"
fi
EOF
chmod 755 "$base/fakebin/mv"
run_user_rollback "$base" env \
    ABLETON_TEST_REGISTRY_STICKY=0 \
    ABLETON_TEST_SIGNAL_SOURCE="$base/runtime" \
    ABLETON_TEST_SIGNAL_MARKER="$base/signal-sent" \
    >"$base/out" 2>"$base/err" \
    || fail "signal in the runtime rename window interrupted safe rollback"
[ -e "$base/signal-sent" ] || fail "runtime-swap signal fixture did not fire"
[ -f "$base/runtime/previous-generation" ] \
    || fail "signal window left stale rename flags or an incomplete runtime layout"
[ -f "$blocked_saved/blocked-generation" ] \
    && [ -e "$blocked_saved/.ableton-linux-rollback-incomplete" ] \
    || fail "rollback selected or changed a sibling marked incomplete"
ok "runtime swap masks signals through flag updates and skips incomplete candidates"

base="$(new_env user-facing-rollback)"
make_registry_runtime "$base"
make_runtime "$base/runtime" "$base/current-BUILD-INFO.txt" skipped
printf 'current generation\n' > "$base/runtime/current-generation"
saved="$base/runtime-rollback-20260811T000000Z"
make_runtime "$saved" "$base/saved-BUILD-INFO.txt" built
cp -- "$base/runtime/bin/wine" "$base/runtime/bin/wineserver" "$saved/bin/"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$saved/.ableton-linux-runtime"
printf 'previous generation\n' > "$saved/previous-generation"

installer_config="$base/xdg/config/ableton-wine/config"
pipeasio_config="$base/xdg/config/pipeasio/config.ini"
mkdir -p -- "$(dirname "$installer_config")" "$(dirname "$pipeasio_config")" \
    "$saved/.ableton-linux-rollback"
cat > "$installer_config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
linkd=$base/xdg/data/ableton-wine/ableton-linkd
EOF
printf '[pipeasio]\nbuffer_size = 512\n' > "$pipeasio_config"
cat > "$saved/.ableton-linux-rollback/installer-config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=11
link_mode=off
linkd=$base/xdg/data/ableton-wine/ableton-linkd
EOF
printf '[pipeasio]\nbuffer_size = 883\n' \
    > "$saved/.ableton-linux-rollback/pipeasio-config.ini"
cat > "$saved/.ableton-linux-rollback/metadata" <<EOF
format=1
runtime_root=$base/runtime
prefix=$base/prefix
installer_config_path=$installer_config
installer_config_state=present
pipeasio_config_path=$pipeasio_config
pipeasio_config_state=present
panel_integration=1
EOF

run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINK_MODE=off \
    ABLETON_TEST_REGISTRY_LOG="$base/registry.log" \
    ABLETON_TEST_REGISTRY_STATE="$base/registry-present" \
    ABLETON_TEST_REGISTRY_STICKY=0 \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$here/rollback.sh" >"$base/rollback.out" 2>"$base/rollback.err" \
    || fail "user-facing rollback failed with a marked runtime sibling"
[ -f "$base/runtime/previous-generation" ] \
    || fail "user-facing rollback did not promote the saved runtime"
grep -qF 'live_major=11' "$installer_config" \
    || fail "user-facing rollback did not restore custom-XDG installer configuration"
grep -qF 'buffer_size = 883' "$pipeasio_config" \
    || fail "user-facing rollback did not restore custom-XDG PipeASIO configuration"
rollback_panel="$base/home/.local/bin/pipeasio-settings"
[ -L "$rollback_panel" ] \
    && [ "$(readlink -- "$rollback_panel")" = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "user-facing rollback did not restore recorded panel integration"
reverse=""
for candidate in "$base"/runtime-rollback-*; do
    [ -f "$candidate/current-generation" ] || continue
    reverse="$candidate"
    break
done
[ -n "$reverse" ] && [ -s "$reverse/.ableton-linux-rollback/metadata" ] \
    || fail "user-facing rollback did not leave a reversible marked sibling"
rollback_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
manifest_has_path "$rollback_manifest" "$rollback_panel" \
    || fail "user-facing rollback did not update panel ownership"
grep -Fq "$base/prefix"$'\tregsvr32 /s pipeasio64.dll' "$base/registry.log" \
    || fail "user-facing rollback did not register the restored driver in its prefix"
ok "user-facing rollback restores marked runtime, config, panel, and registration under custom XDG"

cp -a -- "$base/runtime/.ableton-linux-rollback" "$base/active-rollback-metadata.before"
cp -a -- "$installer_config" "$base/installer-config.before-failed-rollback"
cp -a -- "$pipeasio_config" "$base/pipeasio-config.before-failed-rollback"
if run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINK_MODE=off \
    ABLETON_TEST_REGISTRY_LOG="$base/registry.log" \
    ABLETON_TEST_REGISTRY_STATE="$base/registry-present" \
    ABLETON_TEST_REGISTRY_STICKY=1 \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$here/rollback.sh" >"$base/failed-rollback.out" 2>"$base/failed-rollback.err"; then
    fail "forced post-swap registration failure still committed rollback"
fi
[ -f "$base/runtime/previous-generation" ] \
    || fail "failed rollback did not restore the active runtime"
if ! cmp -s -- "$installer_config" "$base/installer-config.before-failed-rollback" \
   || ! cmp -s -- "$pipeasio_config" "$base/pipeasio-config.before-failed-rollback"; then
    fail "failed rollback did not restore active configuration"
fi
diff -qr -- "$base/runtime/.ableton-linux-rollback" \
    "$base/active-rollback-metadata.before" >/dev/null \
    || fail "failed rollback mutated active runtime rollback metadata"
failed_record="$(find "$base/xdg/state/ableton-wine/transactions" -mindepth 2 \
    -maxdepth 2 -type f -name FAILURE -print | head -n 1)"
[ -n "$failed_record" ] \
    || fail "failed original registration did not retain a failure record"
grep -qxF 'runtime_restored=yes' "$failed_record" \
    || fail "failed original registration obscured the restored runtime layout"
if ! grep -qxF 'restoration_complete=no' "$failed_record"; then
    cat "$failed_record" >&2
    sed -n '1,120p' "$base/failed-rollback.err" >&2
    fail "failed original registration was not recorded as incomplete restoration"
fi
grep -qF 'automatic runtime restoration is incomplete: original PipeASIO registration could not be restored' \
    "$base/failed-rollback.err" \
    || fail "failed original registration was not reported as incomplete restoration"
! grep -qF 'previous runtime and files were restored' "$base/failed-rollback.err" \
    || fail "failed original registration printed a false restored claim"
ok "post-swap failure restores files atomically and records failed re-registration"

base="$(new_env rollback-host-restore-failure)"
make_rollback_fixture "$base"
if run_user_rollback "$base" env \
    ABLETON_TEST_REGISTRY_STICKY=1 \
    ABLETON_TEST_CORRUPT_ROLLBACK_SNAPSHOTS=1 \
    >"$base/out" 2>"$base/err"; then
    fail "rollback succeeded after injected host-file restoration failure"
fi
[ -e "$base/corruption-fired" ] \
    || fail "host-file restoration failure fixture did not corrupt its snapshots"
failed_record="$(find "$base/xdg/state/ableton-wine/transactions" -mindepth 2 \
    -maxdepth 2 -type f -name FAILURE -print | head -n 1)"
[ -n "$failed_record" ] \
    || fail "host-file restoration failure did not retain a failure record"
grep -qxF 'runtime_restored=yes' "$failed_record" \
    || fail "host-file restoration failure obscured the restored runtime layout"
grep -qxF 'restoration_complete=no' "$failed_record" \
    || fail "host-file restoration failure was not recorded as incomplete"
grep -qF 'automatic runtime restoration is incomplete: host file restoration failed' "$base/err" \
    || fail "host-file restoration failure was not reported as incomplete"
! grep -qF 'previous runtime and files were restored' "$base/err" \
    || fail "host-file restoration failure printed a false restored claim"
ok "host-file rollback failure records incomplete restoration without a false success claim"

base="$(new_env retained-prefix-unregister)"
make_registry_runtime "$base"
run_registry_uninstall "$base" env ABLETON_TEST_REGISTRY_STICKY=0 \
    >"$base/out" 2>"$base/err" || fail "retained-prefix uninstall failed after successful unregistration"
[ -e "$base/prefix/system.reg" ] || fail "retained-prefix uninstall deleted the prefix"
[ ! -e "$base/runtime" ] || fail "successful retained-prefix uninstall kept the runtime"
[ ! -e "$base/registry-present" ] || fail "retained-prefix uninstall left PipeASIO registered"
grep -Fq '{2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}' "$base/registry.log" \
    || fail "retained-prefix uninstall did not query the PipeASIO CLSID"
! grep -Fq '{48D0C522-BFCC-45CC-8B84-17F25F33E6E8}' "$base/registry.log" \
    || fail "retained-prefix uninstall touched the legacy WineASIO CLSID"
ok "retained-prefix uninstall unregisters and verifies PipeASIO before deleting runtime"

base="$(new_env retained-prefix-refusal)"
make_registry_runtime "$base"
if run_registry_uninstall "$base" env ABLETON_TEST_REGISTRY_STICKY=1 \
    >"$base/out" 2>"$base/err"; then
    fail "uninstall succeeded while PipeASIO registration remained"
fi
[ -e "$base/runtime/.ableton-linux-runtime" ] \
    || fail "failed unregistration still deleted the runtime"
[ -e "$base/prefix/system.reg" ] && [ -e "$base/registry-present" ] \
    || fail "failed unregistration changed retained prefix state"
ok "failed PipeASIO unregistration preserves runtime and retained prefix"

base="$(new_env retained-prefix-query-failure)"
make_registry_runtime "$base"
if run_registry_uninstall "$base" env ABLETON_TEST_REGISTRY_STICKY=1 \
    ABLETON_TEST_REGISTRY_QUERY_BROKEN=1 >"$base/out" 2>"$base/err"; then
    fail "uninstall accepted failed registry queries as proof of PipeASIO absence"
fi
[ -e "$base/runtime/.ableton-linux-runtime" ] \
    && [ -e "$base/prefix/system.reg" ] && [ -e "$base/registry-present" ] \
    || fail "registry verification failure did not retain runtime and prefix state"
grep -qF 'removal could not be verified' "$base/err" \
    || fail "registry control-query failure was not reported"
ok "failed registry control query cannot authorize retained-prefix runtime deletion"

base="$(new_env uninstall-missing-prestate)"
managed_link="$base/home/.local/bin/pipeasio-settings"
mkdir -p -- "$(dirname "$managed_link")"
printf '#!/bin/sh\necho original-prestate\n' > "$base/original-prestate-command"
chmod 755 "$base/original-prestate-command"
ln -s -- "$base/original-prestate-command" "$managed_link"
install_managed_link "$base" "$base/managed-panel" "$managed_link" "$base/txn" \
    || fail "missing-prestate fixture install failed"
prestate_id="$(printf '%s' "$managed_link" | sha256sum | awk '{print $1}')"
prestate_backup="$base/xdg/state/ableton-wine/install-prestate/$prestate_id"
rm -f -- "$prestate_backup"
if run_minimal_uninstall "$base" >"$base/out" 2>"$base/err"; then
    fail "uninstall succeeded with a missing recorded pre-install backup"
fi
[ -L "$managed_link" ] && [ "$(readlink -- "$managed_link")" = "$base/managed-panel" ] \
    || fail "missing prestate validation occurred after managed target removal"
[ -r "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ -r "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "missing prestate failure discarded ownership or prestate records"
grep -Eq 'cannot safely restore the recorded pre-install file|pre-install backup is missing or misplaced' "$base/err" \
    || fail "missing prestate refusal was not explicit"
ok "uninstall validates recorded prestate before removing a managed path"

base="$(new_env literal-runtime-sibling)"
literal_runtime="$base/runtime[1]"
literal_rollback="$base/runtime[1]-rollback-owned"
glob_collision="$base/runtime1-rollback-foreign"
mkdir -p -- "$literal_runtime" "$literal_rollback" "$glob_collision" \
    "$base/xdg/state/ableton-wine" "$base/fakebin"
for candidate in "$literal_runtime" "$literal_rollback" "$glob_collision"; do
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$candidate/.ableton-linux-runtime"
done
printf 'foreign sibling must survive\n' > "$glob_collision/foreign"
printf 'runtime\t%s\twine-d2d1-nspa-11.13\n' "$literal_runtime" \
    > "$base/xdg/state/ableton-wine/install-manifest.tsv"
printf 'format=1\nowner=ableton-linux\n' \
    > "$base/xdg/state/ableton-wine/.ableton-linux-state"
install_fake_host_tools "$base"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$literal_runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINK_MODE=off bash "$here/uninstall.sh" --keep-prefix --yes \
    >"$base/out" 2>"$base/err" || fail "literal-runtime uninstall fixture failed"
[ ! -e "$literal_runtime" ] && [ ! -e "$literal_rollback" ] \
    || fail "uninstall did not remove the literal managed runtime family"
[ -f "$glob_collision/foreign" ] \
    || fail "runtime basename metacharacters selected an unrelated sibling"
ok "uninstall matches custom runtime rollback siblings by literal basename"

run_txn_file_rollback()
{
    local base="$1" txn="$2"
    # shellcheck disable=SC2016
    run_isolated "$base" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_rollback_files "$2"
    ' _ "$here" "$txn"
}

for corrupt_kind in missing external duplicate nul; do
    base="$(new_env "txn-preflight-$corrupt_kind")"
    txn="$base/txn"
    first="$base/live-first"
    second="$base/live-second"
    mkdir -p -- "$txn/files"
    printf 'new first\n' > "$first"
    printf 'new second\n' > "$second"
    printf 'old first\n' > "$txn/files/0"
    printf 'old second\n' > "$txn/files/1"
    printf 'external backup\n' > "$base/external-backup"
    case "$corrupt_kind" in
        missing)
            rm -f -- "$txn/files/1"
            printf 'present\t%s\t%s\npresent\t%s\t%s\n' \
                "$first" "$txn/files/0" "$second" "$txn/files/1" > "$txn/files.tsv"
            ;;
        external)
            printf 'present\t%s\t%s\npresent\t%s\t%s\n' \
                "$first" "$txn/files/0" "$second" "$base/external-backup" > "$txn/files.tsv"
            ;;
        duplicate)
            printf 'present\t%s\t%s\npresent\t%s\t%s\n' \
                "$first" "$txn/files/0" "$first" "$txn/files/1" > "$txn/files.tsv"
            ;;
        nul)
            printf 'present\t%s\t%s\npresent\t%s\t%s\n' \
                "$first" "$txn/files/0" "$second" "$txn/files/1" > "$txn/files.tsv"
            printf '\0' >> "$txn/files.tsv"
            ;;
    esac
    if run_txn_file_rollback "$base" "$txn" >"$base/out" 2>"$base/err"; then
        fail "file rollback accepted a $corrupt_kind transaction journal"
    fi
    if ! grep -qxF 'new first' "$first" || ! grep -qxF 'new second' "$second"; then
        fail "$corrupt_kind transaction preflight changed a live target"
    fi
    grep -qxF 'external backup' "$base/external-backup" \
        || fail "$corrupt_kind transaction preflight changed an external backup"
done
ok "file rollback fully preflights indexed, unique, NUL-free backups before mutation"

run_remove_managed_file()
{
    local base="$1" target="$2"
    # shellcheck disable=SC2016
    run_isolated "$base" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_remove_managed_file "$2"
    ' _ "$here" "$target"
}

for corrupt_kind in duplicate misplaced directory nul; do
    base="$(new_env "remove-prestate-$corrupt_kind")"
    state="$base/xdg/state/ableton-wine"
    target="$base/xdg/data/ableton-wine/detect-scale.sh"
    id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
    backup="$state/install-prestate/$id"
    mkdir -p -- "$state/install-prestate" "$(dirname "$target")"
    printf 'managed live bytes\n' > "$target"
    target_digest="$(sha256sum -- "$target" | awk '{print $1}')"
    printf 'file\t%s\t%s\n' "$target" "$target_digest" > "$state/install-manifest.tsv"
    printf 'external prestate bytes\n' > "$base/external-prestate"
    case "$corrupt_kind" in
        duplicate)
            cp -- "$base/external-prestate" "$backup"
            printf 'present\t%s\t%s\npresent\t%s\t%s\n' \
                "$target" "$backup" "$target" "$backup" > "$state/install-prestate.tsv"
            ;;
        misplaced)
            cp -- "$base/external-prestate" "$backup"
            printf 'present\t%s\t%s\n' "$target" "$base/external-prestate" \
                > "$state/install-prestate.tsv"
            ;;
        directory)
            mkdir -p -- "$backup"
            printf 'directory sentinel\n' > "$backup/sentinel"
            printf 'present\t%s\t%s\n' "$target" "$backup" > "$state/install-prestate.tsv"
            ;;
        nul)
            cp -- "$base/external-prestate" "$backup"
            printf 'present\t%s\t%s\n' "$target" "$backup" > "$state/install-prestate.tsv"
            printf '\0' >> "$state/install-prestate.tsv"
            ;;
    esac
    if run_remove_managed_file "$base" "$target" >"$base/out" 2>"$base/err"; then
        fail "managed-file removal accepted $corrupt_kind prestate"
    fi
    grep -qxF 'managed live bytes' "$target" \
        || fail "$corrupt_kind prestate was rejected after target removal"
    grep -qxF 'external prestate bytes' "$base/external-prestate" \
        || fail "$corrupt_kind prestate changed an external object"
done
ok "managed-file removal preflights unique, local, file-shaped, NUL-free prestate"

run_directory_target_guard()
{
    local base="$1" operation="$2" target="$3" txn="$4"
    mkdir -p -- "$txn"
    mkdir -p -- "$txn"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_init
        case "$2" in
            install) ableton_install_file 755 "$3" "$4" ;;
            symlink) ableton_install_symlink "$3" "$4" ;;
        esac
    ' _ "$here" "$operation" "$base/source" "$target"
}

for operation in install symlink; do
    base="$(new_env "directory-target-$operation")"
    target="$base/managed-target"
    txn="$base/txn"
    mkdir -p -- "$target"
    printf 'directory sentinel\n' > "$target/sentinel"
    printf 'replacement bytes\n' > "$base/source"
    if run_directory_target_guard "$base" "$operation" "$target" "$txn" \
        >"$base/out" 2>"$base/err"; then
        fail "$operation helper accepted a directory target"
    fi
    grep -qxF 'directory sentinel' "$target/sentinel" \
        || fail "$operation directory refusal changed the target"
    [ -f "$txn/files.tsv" ] && [ ! -s "$txn/files.tsv" ] \
        || fail "$operation directory refusal mutated its transaction journal"
    [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
        && [ ! -e "$base/xdg/state/ableton-wine/install-prestate" ] \
        || fail "$operation directory refusal persisted prestate"
done
ok "file and symlink directory refusals leave transaction and prestate journals untouched"

run_guarded_file_install()
{
    local base="$1" txn="$2" target="$3"
    mkdir -p -- "$txn"
    mkdir -p -- "$txn"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_init
        ableton_install_file 600 "$2" "$3"
    ' _ "$here" "$base/replacement" "$target"
}

for journal in manifest prestate; do
    for corrupt_kind in symlink unreadable malformed nul; do
        base="$(new_env "install-$journal-$corrupt_kind")"
        state="$base/xdg/state/ableton-wine"
        txn="$base/txn"
        target="$base/xdg/data/ableton-wine/setup-realtime.sh"
        mkdir -p -- "$state" "$(dirname "$target")"
        printf 'foreign live bytes\n' > "$target"
        printf 'replacement bytes\n' > "$base/replacement"
        printf 'external journal bytes\n' > "$base/external-journal"
        path="$state/install-$journal.tsv"
        case "$corrupt_kind" in
            symlink) ln -s -- "$base/external-journal" "$path" ;;
            unreadable) printf 'unreadable journal\n' > "$path"; chmod 000 "$path" ;;
            malformed) printf 'not-a-valid-record\n' > "$path" ;;
            nul) printf '\0' > "$path" ;;
        esac
        if run_guarded_file_install "$base" "$txn" "$target" \
            >"$base/out" 2>"$base/err"; then
            chmod 600 "$path" 2>/dev/null || true
            fail "install accepted a $corrupt_kind $journal journal"
        fi
        chmod 600 "$path" 2>/dev/null || true
        grep -qxF 'foreign live bytes' "$target" \
            || fail "$corrupt_kind $journal refusal overwrote a foreign target"
        grep -qxF 'external journal bytes' "$base/external-journal" \
            || fail "$corrupt_kind $journal refusal changed a symlink referent"
        [ -f "$txn/files.tsv" ] && [ ! -s "$txn/files.tsv" ] \
            || fail "$corrupt_kind $journal refusal mutated its transaction journal"
    done
done
ok "install refuses unsafe manifest and prestate journals without touching foreign data"

base="$(new_env manifest-external-path)"
state="$base/xdg/state/ableton-wine"
mkdir -p -- "$state"
external_target="$base/external-valid-digest"
printf 'external valid digest bytes\n' > "$external_target"
printf 'file\t%s\t%s\n' "$external_target" \
    "$(sha256sum -- "$external_target" | awk '{print $1}')" > "$state/install-manifest.tsv"
if run_guarded_file_install "$base" "$base/txn" \
    "$base/xdg/data/ableton-wine/setup-realtime.sh" >"$base/out" 2>"$base/err"; then
    fail "install accepted a valid-digest arbitrary external manifest path"
fi
grep -qxF 'external valid digest bytes' "$external_target" \
    || fail "external manifest-path refusal changed the external file"
ok "valid digest cannot authorize an arbitrary external manifest path"

run_direct_uninstall()
{
    local base="$1" mode="${2:---keep-prefix}"
    if [ ! -x "$base/fakebin/systemctl" ] || [ ! -x "$base/fakebin/xdg-mime" ]; then
        install_fake_host_tools "$base"
    fi
    run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_LINK_MODE=off bash "$here/uninstall.sh" "$mode" --yes
}

for marker_kind in runtime prefix state; do
    base="$(new_env "nul-$marker_kind-marker")"
    make_registry_runtime "$base"
    printf 'runtime sentinel\n' > "$base/runtime/sentinel"
    printf 'prefix sentinel\n' > "$base/prefix/sentinel"
    printf 'state sentinel\n' > "$base/xdg/state/ableton-wine/sentinel"
    mode=--keep-prefix
    case "$marker_kind" in
        runtime) printf '\0' >> "$base/runtime/.ableton-linux-runtime" ;;
        prefix) printf '\0' >> "$base/prefix/.ableton-linux-prefix"; mode=--delete-prefix ;;
        state) printf '\0' >> "$base/xdg/state/ableton-wine/.ableton-linux-state" ;;
    esac
    if run_direct_uninstall "$base" "$mode" >"$base/out" 2>"$base/err"; then
        fail "uninstall accepted a runtime/prefix/state $marker_kind marker with trailing NUL"
    fi
    if ! grep -qxF 'runtime sentinel' "$base/runtime/sentinel" \
       || ! grep -qxF 'prefix sentinel' "$base/prefix/sentinel" \
       || ! grep -qxF 'state sentinel' "$base/xdg/state/ableton-wine/sentinel"; then
        fail "$marker_kind marker refusal changed an owned tree"
    fi
done
ok "trailing NUL bytes invalidate every recursive-deletion ownership marker"

for journal in manifest prestate mime; do
    for corrupt_kind in symlink unreadable nul; do
        base="$(new_env "uninstall-$journal-$corrupt_kind")"
        make_registry_runtime "$base"
        printf 'runtime sentinel\n' > "$base/runtime/sentinel"
        printf 'prefix sentinel\n' > "$base/prefix/sentinel"
        state="$base/xdg/state/ableton-wine"
        case "$journal" in
            manifest) path="$state/install-manifest.tsv" ;;
            prestate) path="$state/install-prestate.tsv" ;;
            mime) path="$state/mime-prestate.tsv" ;;
        esac
        printf 'external uninstall journal\n' > "$base/external-journal"
        case "$corrupt_kind" in
            symlink)
                [ ! -e "$path" ] || mv -- "$path" "$base/original-journal"
                ln -s -- "$base/external-journal" "$path"
                ;;
            unreadable) printf 'unreadable\n' > "$path"; chmod 000 "$path" ;;
            nul) printf '\0' >> "$path" ;;
        esac
        if run_direct_uninstall "$base" >"$base/out" 2>"$base/err"; then
            chmod 600 "$path" 2>/dev/null || true
            fail "uninstall accepted a $corrupt_kind $journal journal"
        fi
        chmod 600 "$path" 2>/dev/null || true
        grep -qxF 'runtime sentinel' "$base/runtime/sentinel" \
            && grep -qxF 'prefix sentinel' "$base/prefix/sentinel" \
            && [ -e "$base/registry-present" ] \
            || fail "$corrupt_kind $journal refusal mutated runtime, prefix, or registry"
        grep -qxF 'external uninstall journal' "$base/external-journal" \
            || fail "$corrupt_kind $journal refusal changed an external referent"
    done
done

base="$(new_env uninstall-runtime-prestate-claim)"
make_registry_runtime "$base"
state="$base/xdg/state/ableton-wine"
runtime_id="$(printf '%s' "$base/runtime" | sha256sum | awk '{print $1}')"
mkdir -p -- "$state/install-prestate"
printf 'invalid runtime prestate\n' > "$state/install-prestate/$runtime_id"
printf 'present\t%s\t%s\n' "$base/runtime" "$state/install-prestate/$runtime_id" \
    > "$state/install-prestate.tsv"
printf 'runtime sentinel\n' > "$base/runtime/sentinel"
if run_direct_uninstall "$base" >"$base/out" 2>"$base/err"; then
    fail "uninstall accepted file prestate claimed for a runtime record"
fi
[ -f "$base/runtime/sentinel" ] && [ -e "$base/registry-present" ] \
    || fail "runtime prestate claim was rejected after mutation"
ok "uninstall preflights unsafe journals and rejects prestate attached to runtime ownership"

base="$(new_env uninstall-late-missing-prestate)"
make_registry_runtime "$base"
state="$base/xdg/state/ableton-wine"
first="$base/first-managed"
second="$base/second-managed"
printf 'first managed bytes\n' > "$first"
printf 'second managed bytes\n' > "$second"
first_digest="$(sha256sum -- "$first" | awk '{print $1}')"
second_digest="$(sha256sum -- "$second" | awk '{print $1}')"
printf 'file\t%s\t%s\nfile\t%s\t%s\nruntime\t%s\twine-d2d1-nspa-11.13\n' \
    "$first" "$first_digest" "$second" "$second_digest" "$base/runtime" \
    > "$state/install-manifest.tsv"
first_id="$(printf '%s' "$first" | sha256sum | awk '{print $1}')"
second_id="$(printf '%s' "$second" | sha256sum | awk '{print $1}')"
mkdir -p -- "$state/install-prestate"
printf 'first previous bytes\n' > "$state/install-prestate/$first_id"
printf 'present\t%s\t%s\npresent\t%s\t%s\n' \
    "$first" "$state/install-prestate/$first_id" \
    "$second" "$state/install-prestate/$second_id" > "$state/install-prestate.tsv"
printf 'runtime sentinel\n' > "$base/runtime/sentinel"
if run_direct_uninstall "$base" >"$base/out" 2>"$base/err"; then
    fail "uninstall accepted a later missing prestate backup"
fi
if ! grep -qxF 'first managed bytes' "$first" \
   || ! grep -qxF 'second managed bytes' "$second" \
   || ! grep -qxF 'runtime sentinel' "$base/runtime/sentinel"; then
    fail "late prestate failure occurred after an earlier managed target changed"
fi
ok "uninstall fully preflights later prestate failures before files or runtime change"

make_mime_failure_fixture()
{
    local base="$1" prior="$2"
    mkdir -p -- "$base/runtime" "$base/xdg/state/ableton-wine"
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
    printf 'runtime\t%s\twine-d2d1-nspa-11.13\n' "$base/runtime" \
        > "$base/xdg/state/ableton-wine/install-manifest.tsv"
    printf 'format=1\nowner=ableton-linux\n' \
        > "$base/xdg/state/ableton-wine/.ableton-linux-state"
    printf 'x-scheme-handler/ableton\t%s\n' "$prior" \
        > "$base/xdg/state/ableton-wine/mime-prestate.tsv"
    install_fake_host_tools "$base"
}

base="$(new_env mime-default-failure)"
make_mime_failure_fixture "$base" foreign.desktop
cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/bin/sh
case "${1:-}" in
    query) echo ableton-live.desktop ;;
    default) exit 77 ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$base/fakebin/xdg-mime"
if run_direct_uninstall "$base" >"$base/out" 2>"$base/err"; then
    fail "MIME default restoration failure reported uninstall success"
fi
[ -r "$base/xdg/state/ableton-wine/mime-prestate.tsv" ] \
    && [ -r "$base/xdg/state/ableton-wine/.ableton-linux-state" ] \
    || fail "MIME default restoration failure discarded retry state"

base="$(new_env mime-clear-failure)"
make_mime_failure_fixture "$base" ''
mkdir -p -- "$base/xdg/config"
printf '[Default Applications]\nx-scheme-handler/ableton=ableton-live.desktop\n' \
    > "$base/xdg/config/mimeapps.list"
real_awk="$(command -v awk)"
cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/bin/sh
case "${1:-}" in
    query) echo ableton-live.desktop ;;
    default) exit 0 ;;
    *) exit 2 ;;
esac
EOF
# Reading and clearing the defaults list are the only awk programs that name the
# group, so this breaks that step alone and leaves every other awk call working.
cat > "$base/fakebin/awk" <<EOF
#!/bin/sh
for argument do
    case "\$argument" in
        *'[Default Applications]'*) exit 78 ;;
    esac
done
exec "$real_awk" "\$@"
EOF
chmod 755 "$base/fakebin/xdg-mime" "$base/fakebin/awk"
if run_direct_uninstall "$base" >"$base/out" 2>"$base/err"; then
    fail "MIME clear failure reported uninstall success"
fi
[ -r "$base/xdg/state/ableton-wine/mime-prestate.tsv" ] \
    && [ -r "$base/xdg/state/ableton-wine/.ableton-linux-state" ] \
    || fail "MIME clear failure discarded retry state"
ok "MIME command and mimeapps restoration failures return nonzero with retry state retained"

base="$(new_env mime-post-lock-mutation)"
make_mime_failure_fixture "$base" foreign.desktop
state="$base/xdg/state/ableton-wine"
printf 'runtime sentinel\n' > "$base/runtime/sentinel"
real_flock="$(command -v flock)"
cat > "$base/fakebin/flock" <<EOF
#!/bin/sh
"$real_flock" "\$@" || exit \$?
if [ ! -e "$base/mime-mutated" ]; then
    printf 'x-scheme-handler/ableton\\tmutated.desktop\\n' \
        > "$state/mime-prestate.tsv"
    : > "$base/mime-mutated"
fi
EOF
chmod 755 "$base/fakebin/flock"
if run_direct_uninstall "$base" >"$base/out" 2>"$base/err"; then
    fail "uninstall accepted MIME restoration state changed while waiting for its lock"
fi
[ -e "$base/mime-mutated" ] && [ -f "$base/runtime/sentinel" ] \
    && [ -f "$state/.ableton-linux-state" ] \
    || fail "post-lock MIME mutation fixture did not fire before a no-mutation refusal"
grep -qF 'MIME restoration state changed; retry uninstall' "$base/err" \
    || fail "post-lock MIME mutation refusal was not explicit"
ok "uninstall hashes and fully revalidates MIME restoration state after locking"

base="$(new_env partial-uninstall-retry)"
mkdir -p -- "$base/runtime" "$base/xdg/state/ableton-wine/install-prestate"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
printf 'format=1\nowner=ableton-linux\n' \
    > "$base/xdg/state/ableton-wine/.ableton-linux-state"
mkdir -p -- "$base/xdg/data/ableton-wine"
first="$base/xdg/data/ableton-wine/VERSION"
second="$base/xdg/data/ableton-wine/setup-realtime.sh"
printf 'first previous bytes\n' > "$first"
printf 'user conflict bytes\n' > "$second"
first_id="$(printf '%s' "$first" | sha256sum | awk '{print $1}')"
second_id="$(printf '%s' "$second" | sha256sum | awk '{print $1}')"
printf 'first previous bytes\n' > "$base/xdg/state/ableton-wine/install-prestate/$first_id"
printf 'second previous bytes\n' > "$base/xdg/state/ableton-wine/install-prestate/$second_id"
first_managed="$base/first-managed-reference"
second_managed="$base/second-managed-reference"
printf 'first managed bytes\n' > "$first_managed"
printf 'second managed bytes\n' > "$second_managed"
printf 'file\t%s\t%s\nfile\t%s\t%s\nruntime\t%s\twine-d2d1-nspa-11.13\n' \
    "$first" "$(sha256sum -- "$first_managed" | awk '{print $1}')" \
    "$second" "$(sha256sum -- "$second_managed" | awk '{print $1}')" \
    "$base/runtime" > "$base/xdg/state/ableton-wine/install-manifest.tsv"
printf 'present\t%s\t%s\npresent\t%s\t%s\n' \
    "$first" "$base/xdg/state/ableton-wine/install-prestate/$first_id" \
    "$second" "$base/xdg/state/ableton-wine/install-prestate/$second_id" \
    > "$base/xdg/state/ableton-wine/install-prestate.tsv"
if run_direct_uninstall "$base" >"$base/first.out" 2>"$base/first.err"; then
    fail "partial uninstall fixture unexpectedly succeeded before conflict resolution"
fi
grep -qxF 'first previous bytes' "$first" \
    && grep -qxF 'user conflict bytes' "$second" \
    && [ -d "$base/runtime" ] && [ -d "$base/xdg/state/ableton-wine" ] \
    || fail "partial uninstall did not retain restored file, conflict, runtime, and state"
cp -- "$second_managed" "$second"
if ! run_direct_uninstall "$base" >"$base/retry.out" 2>"$base/retry.err"; then
    sed -n '1,120p' "$base/retry.err" >&2
    fail "partial uninstall did not complete after its remaining conflict was resolved"
fi
if ! grep -qxF 'first previous bytes' "$first" \
   || ! grep -qxF 'second previous bytes' "$second"; then
    fail "partial uninstall retry did not preserve/restore exact prestate"
fi
[ ! -e "$base/runtime" ] && [ ! -e "$base/xdg/state/ableton-wine" ] \
    || fail "successful partial-uninstall retry retained runtime or ownership state"
grep -qF "kept already-restored pre-install file $first" "$base/retry.out" \
    || fail "partial uninstall retry did not recognize its already-restored file"
ok "partial uninstall retry accepts exact already-restored prestate and completes"

for snapshot in installer-config pipeasio-config.ini; do
    base="$(new_env "rollback-directory-${snapshot//./-}")"
    make_rollback_fixture "$base"
    rm -f -- "$ROLLBACK_SAVED/.ableton-linux-rollback/$snapshot"
    mkdir -p -- "$ROLLBACK_SAVED/.ableton-linux-rollback/$snapshot"
    printf 'directory snapshot sentinel\n' \
        > "$ROLLBACK_SAVED/.ableton-linux-rollback/$snapshot/sentinel"
    if run_user_rollback "$base" env ABLETON_TEST_REGISTRY_STICKY=0 \
        >"$base/out" 2>"$base/err"; then
        fail "rollback accepted a directory $snapshot snapshot"
    fi
    [ -f "$base/runtime/current-generation" ] \
        && [ -f "$ROLLBACK_SAVED/previous-generation" ] \
        && [ -f "$ROLLBACK_SAVED/.ableton-linux-rollback/$snapshot/sentinel" ] \
        || fail "directory $snapshot refusal occurred after runtime mutation"
done
ok "rollback rejects directory configuration snapshots before the runtime swap"

run_txn_init_only()
{
    local base="$1" txn="$2"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_init
    ' _ "$here"
}

run_txn_commit_preflight_only()
{
    local base="$1" txn="$2"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_preflight_commit_files "$2"
    ' _ "$here" "$txn"
}

for entry in files active files.tsv; do
    base="$(new_env "txn-init-symlink-${entry//./-}")"
    txn="$base/txn"
    mkdir -p -- "$txn"
    if [ "$entry" = files ]; then
        mkdir -p -- "$base/external-transaction-object"
        printf 'external directory sentinel\n' > "$base/external-transaction-object/sentinel"
    else
        printf 'external file sentinel\n' > "$base/external-transaction-object"
    fi
    ln -s -- "$base/external-transaction-object" "$txn/$entry"
    if run_txn_init_only "$base" "$txn" >"$base/out" 2>"$base/err"; then
        fail "transaction init accepted symlink $entry"
    fi
    if [ "$entry" = files ]; then
        grep -qxF 'external directory sentinel' "$base/external-transaction-object/sentinel" \
            || fail "transaction init changed the symlinked $entry directory"
    else
        grep -qxF 'external file sentinel' "$base/external-transaction-object" \
            || fail "transaction init changed the symlinked $entry file"
    fi
    [ "$(find "$txn" -mindepth 1 -maxdepth 1 -printf x | wc -c)" -eq 1 ] \
        || fail "transaction init partially populated a rejected symlink fixture"
done

base="$(new_env txn-occupied-backup-slot)"
txn="$base/txn"
mkdir -p -- "$txn"
run_txn_init_only "$base" "$txn" || fail "occupied-slot transaction setup failed"
target="$base/xdg/data/ableton-wine/detect-theme.sh"
mkdir -p -- "$(dirname "$target")"
printf 'live target sentinel\n' > "$target"
printf 'external slot sentinel\n' > "$base/external-slot"
ln -s -- "$base/external-slot" "$txn/files/0"
# shellcheck disable=SC2016
if run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_txn_snapshot "$2"
' _ "$here" "$target" >"$base/out" 2>"$base/err"; then
    fail "transaction snapshot accepted an occupied exact backup slot"
fi
grep -qxF 'live target sentinel' "$target" \
    && grep -qxF 'external slot sentinel' "$base/external-slot" \
    && [ ! -s "$txn/files.tsv" ] \
    || fail "occupied transaction slot refusal changed target, referent, or journal"
ok "transaction init/snapshot reject symlink control objects and occupied slots without referent changes"

base="$(new_env txn-commit-preflight)"
txn="$base/txn"
target_present="$base/xdg/data/ableton-wine/detect-theme.sh"
target_absent="$base/xdg/data/ableton-wine/detect-scale.sh"
mkdir -p -- "$txn" "$(dirname "$target_present")"
printf 'live bytes\n' > "$target_present"
printf 'replacement bytes\n' > "$base/replacement"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_txn_snapshot "$2"
    ableton_txn_expect "$2" "$(ableton_regular_source_token "$3")"
    cp -- "$3" "$2"
    ableton_txn_snapshot "$4"
    ableton_txn_expect "$4" absent
' _ "$here" "$target_present" "$base/replacement" "$target_absent" \
    || fail "commit-preflight positive fixture could not bind exact expected objects"
run_txn_commit_preflight_only "$base" "$txn" >"$base/ok.out" 2>"$base/ok.err" \
    || fail "commit preflight rejected exact already-committed transaction objects"

base="$(new_env txn-commit-pending)"
txn="$base/txn"
target="$base/xdg/data/ableton-wine/detect-theme.sh"
mkdir -p -- "$txn" "$(dirname "$target")"
printf 'live pending bytes\n' > "$target"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_txn_snapshot "$2"
' _ "$here" "$target" || fail "pending-commit fixture could not snapshot its target"
if run_txn_commit_preflight_only "$base" "$txn" >"$base/out" 2>"$base/err"; then
    fail "commit preflight accepted a pending transaction row"
fi
grep -qF "file transaction has an unfinished mutation: $target" "$base/err" \
    || fail "pending commit refusal was not explicit"
grep -qxF 'live pending bytes' "$target" \
    || fail "pending commit refusal changed the live target"

base="$(new_env txn-commit-present-changed)"
txn="$base/txn"
target="$base/xdg/data/ableton-wine/detect-theme.sh"
mkdir -p -- "$txn" "$(dirname "$target")"
printf 'live old bytes\n' > "$target"
printf 'replacement bytes\n' > "$base/replacement"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_txn_snapshot "$2"
    ableton_txn_expect "$2" "$(ableton_regular_source_token "$3")"
' _ "$here" "$target" "$base/replacement" \
    || fail "present-changed fixture could not record its expected token"
printf 'third-party bytes\n' > "$target"
if run_txn_commit_preflight_only "$base" "$txn" >"$base/out" 2>"$base/err"; then
    fail "commit preflight accepted a present target replaced by a third party"
fi
grep -qF "file transaction destination no longer matches its committed object: $target" "$base/err" \
    || fail "present changed commit refusal was not explicit"
grep -qxF 'third-party bytes' "$target" \
    || fail "present changed commit refusal rewrote the live target"

base="$(new_env txn-commit-absent-changed)"
txn="$base/txn"
target="$base/xdg/data/ableton-wine/detect-scale.sh"
mkdir -p -- "$txn" "$(dirname "$target")"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_txn_snapshot "$2"
    ableton_txn_expect "$2" absent
' _ "$here" "$target" || fail "absent-changed fixture could not record its expected token"
printf 'third-party appeared\n' > "$target"
if run_txn_commit_preflight_only "$base" "$txn" >"$base/out" 2>"$base/err"; then
    fail "commit preflight accepted an absent target recreated by a third party"
fi
grep -qF "file transaction destination no longer matches its committed object: $target" "$base/err" \
    || fail "absent changed commit refusal was not explicit"
grep -qxF 'third-party appeared' "$target" \
    || fail "absent changed commit refusal rewrote the recreated target"
ok "commit preflight requires exact committed post-operation objects and rejects pending or third-party rows"

for corrupt_kind in symlink-dir orphan-slot; do
    base="$(new_env "persistent-prestate-$corrupt_kind")"
    state="$base/xdg/state/ableton-wine"
    txn="$base/txn"
    target="$base/xdg/data/ableton-wine/detect-scale.sh"
    mkdir -p -- "$state" "$txn" "$(dirname "$target")"
    printf 'foreign target sentinel\n' > "$target"
    printf 'replacement bytes\n' > "$base/replacement"
    if [ "$corrupt_kind" = symlink-dir ]; then
        mkdir -p -- "$base/external-prestate-dir"
        printf 'external prestate directory sentinel\n' \
            > "$base/external-prestate-dir/sentinel"
        ln -s -- "$base/external-prestate-dir" "$state/install-prestate"
    else
        mkdir -p -- "$state/install-prestate"
        id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
        printf 'external orphan sentinel\n' > "$base/external-orphan"
        ln -s -- "$base/external-orphan" "$state/install-prestate/$id"
    fi
    if run_guarded_file_install "$base" "$txn" "$target" \
        >"$base/out" 2>"$base/err"; then
        fail "file install accepted persistent prestate $corrupt_kind"
    fi
    grep -qxF 'foreign target sentinel' "$target" \
        || fail "persistent prestate $corrupt_kind refusal overwrote the live target"
    if [ "$corrupt_kind" = symlink-dir ]; then
        grep -qxF 'external prestate directory sentinel' \
            "$base/external-prestate-dir/sentinel" \
            || fail "persistent prestate symlink-directory refusal changed its referent"
    else
        grep -qxF 'external orphan sentinel' "$base/external-orphan" \
            || fail "persistent orphan-slot refusal changed its referent"
    fi
done
ok "persistent prestate rejects symlink directories and unindexed exact backup slots"

base="$(new_env atomic-install-failure)"
txn="$base/txn"
target="$base/xdg/data/ableton-wine/install-target"
mkdir -p -- "$txn" "$base/fakebin" "$(dirname "$target")"
printf 'stable original bytes\n' > "$base/source"
cp -- "$base/source" "$target"
cat > "$base/fakebin/install" <<'EOF'
#!/bin/bash
target="${@: -1}"
printf 'partial replacement\n' > "$target"
exit 99
EOF
chmod 755 "$base/fakebin/"*
# shellcheck disable=SC2016
if run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_install_file 600 "$2" "$3"
' _ "$here" "$base/source" "$target" >"$base/out" 2>"$base/err"; then
    fail "install helper unexpectedly succeeded after its staged writer failed"
fi
grep -qxF 'stable original bytes' "$target" \
    || fail "install helper destroyed the original target after a staged write failure"
ok "atomic file installers keep the original target when a staged write fails"

base="$(new_env rollback-current-config-directory)"
make_rollback_fixture "$base"
rm -f -- "$ROLLBACK_INSTALLER_CONFIG"
mkdir -p -- "$ROLLBACK_INSTALLER_CONFIG"
printf 'current config directory sentinel\n' > "$ROLLBACK_INSTALLER_CONFIG/sentinel"
if run_user_rollback "$base" env ABLETON_TEST_REGISTRY_STICKY=0 \
    >"$base/out" 2>"$base/err"; then
    fail "rollback accepted a directory current installer configuration target"
fi
[ -f "$base/runtime/current-generation" ] \
    && [ -f "$ROLLBACK_SAVED/previous-generation" ] \
    && [ -f "$ROLLBACK_INSTALLER_CONFIG/sentinel" ] \
    || fail "current configuration directory refusal occurred after mutation"
ok "rollback refuses a current configuration directory without swapping the runtime"

make_legacy_project_evidence()
{
    local base="$1"
    mkdir -p -- "$base/home/.local/share/ableton-wine" "$base/home/.local/bin"
    printf '2025.01.01.1\n' > "$base/home/.local/share/ableton-wine/VERSION"
    printf '#!/bin/sh\n# Ableton Live launcher for the patched Wine stack\n' \
        > "$base/home/.local/bin/ableton-live"
    chmod 755 "$base/home/.local/bin/ableton-live"
}

make_legacy_default_runtime()
{
    local base="$1" runtime
    runtime="$base/home/.local/opt/wine-d2d1-nspa-11.13"
    make_legacy_project_evidence "$base"
    make_runtime "$runtime" "$base/legacy-BUILD-INFO.txt" skipped
    printf '#!/bin/sh\nexit 0\n' > "$runtime/bin/wine"
    printf '#!/bin/sh\nexit 0\n' > "$runtime/bin/wineserver"
    chmod 755 "$runtime/bin/wine" "$runtime/bin/wineserver"
    printf 'legacy runtime sentinel\n' > "$runtime/legacy-sentinel"
}

make_legacy_default_prefix()
{
    local base="$1" prefix registry
    prefix="$base/home/.wine-ableton"
    make_legacy_project_evidence "$base"
    mkdir -p -- "$prefix/drive_c/windows/system32"
    for registry in system.reg user.reg userdef.reg; do
        printf 'WINE REGISTRY Version 2\nlegacy registry\n' > "$prefix/$registry"
    done
    printf 'legacy prefix sentinel\n' > "$prefix/legacy-sentinel"
}

run_adopt_marker()
{
    local base="$1" kind="$2" target="$3" txn
    txn="$base/adopt-transaction"
    mkdir -p -- "$txn"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_init
        case "$2" in
            runtime) ableton_adopt_runtime_marker "$3" "$ABLETON_RUNTIME_NAME" ;;
            prefix) ableton_adopt_prefix_marker "$3" "$3" ;;
        esac
    ' _ "$here" "$kind" "$target"
}

base="$(new_env legacy-runtime-update)"
make_legacy_default_runtime "$base"
make_runtime_only_kit "$base"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err" || fail "runtime update did not adopt a canonical legacy runtime"
legacy_runtime="$base/home/.local/opt/wine-d2d1-nspa-11.13"
cmp -s -- "$legacy_runtime/.ableton-linux-runtime" \
    <(printf 'format=1\nname=wine-d2d1-nspa-11.13\n') \
    || fail "runtime update did not leave an exact ownership marker"
legacy_saved=""
for candidate in "$base/home/.local/opt"/wine-d2d1-nspa-11.13-rollback-*; do
    [ -f "$candidate/legacy-sentinel" ] || continue
    legacy_saved="$candidate"
    break
done
if [ -z "$legacy_saved" ] || ! cmp -s -- "$legacy_saved/.ableton-linux-runtime" \
    <(printf 'format=1\nname=wine-d2d1-nspa-11.13\n'); then
    fail "runtime update did not retain its adopted legacy generation safely"
fi

base="$(new_env legacy-runtime-uninstall)"
make_legacy_default_runtime "$base"
install_fake_host_tools "$base"
run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes >"$base/out" 2>"$base/err" \
    || fail "uninstall did not adopt a canonical legacy runtime"
[ ! -e "$base/home/.local/opt/wine-d2d1-nspa-11.13" ] \
    || fail "uninstall retained the adopted canonical legacy runtime"

base="$(new_env legacy-partial-uninstall-retry)"
make_legacy_default_runtime "$base"
legacy_runtime="$base/home/.local/opt/wine-d2d1-nspa-11.13"
state="$base/xdg/state/ableton-wine"
mkdir -p -- "$state" "$base/xdg/data/ableton-wine"
printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
conflict="$base/xdg/data/ableton-wine/setup-realtime.sh"
printf 'user conflict bytes\n' > "$conflict"
printf 'managed reference bytes\n' > "$base/managed-reference"
printf 'file\t%s\t%s\n' "$conflict" \
    "$(sha256sum -- "$base/managed-reference" | awk '{print $1}')" \
    > "$state/install-manifest.tsv"
install_fake_host_tools "$base"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes >"$base/first.out" 2>"$base/first.err"; then
    fail "legacy partial-uninstall fixture unexpectedly succeeded with a conflict"
fi
if ! cmp -s -- "$legacy_runtime/.ableton-linux-runtime" \
        <(printf 'format=1\nname=wine-d2d1-nspa-11.13\n') \
   || [ ! -f "$legacy_runtime/legacy-sentinel" ] \
   || [ ! -f "$state/.ableton-linux-state" ]; then
    sed -n '1,160p' "$base/first.out" >&2
    sed -n '1,160p' "$base/first.err" >&2
    find "$base" -maxdepth 6 -printf '%y %p -> %l\n' >&2
    fail "partial legacy uninstall did not retain committed marker, runtime, and state"
fi
cp -- "$base/managed-reference" "$conflict"
run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes >"$base/retry.out" 2>"$base/retry.err" \
    || fail "legacy partial uninstall did not complete on retry without legacy evidence"
[ ! -e "$legacy_runtime" ] && [ ! -e "$state" ] \
    || fail "legacy partial-uninstall retry retained runtime or ownership state"

base="$(new_env legacy-prefix-adopt)"
make_legacy_default_prefix "$base"
legacy_prefix="$base/home/.wine-ableton"
run_adopt_marker "$base" prefix "$legacy_prefix" \
    || fail "prefix helper did not adopt a canonical legacy prefix"
cmp -s -- "$legacy_prefix/.ableton-linux-prefix" \
    <(printf 'format=1\nprefix=%s\n' "$legacy_prefix") \
    || fail "legacy prefix adoption did not create an exact marker"

for kind in runtime prefix; do
    base="$(new_env "legacy-custom-$kind")"
    if [ "$kind" = runtime ]; then
        make_legacy_default_runtime "$base"
        canonical="$base/home/.local/opt/wine-d2d1-nspa-11.13"
        target="$base/custom-runtime"
    else
        make_legacy_default_prefix "$base"
        canonical="$base/home/.wine-ableton"
        target="$base/custom-prefix"
    fi
    mv -- "$canonical" "$target"
    if run_adopt_marker "$base" "$kind" "$target" >"$base/out" 2>"$base/err"; then
        fail "legacy adoption accepted a custom $kind path"
    fi
    [ ! -e "$target/.ableton-linux-$kind" ] \
        || fail "custom $kind refusal wrote an ownership marker"

    base="$(new_env "legacy-malformed-$kind")"
    if [ "$kind" = runtime ]; then
        make_legacy_default_runtime "$base"
        target="$base/home/.local/opt/wine-d2d1-nspa-11.13"
    else
        make_legacy_default_prefix "$base"
        target="$base/home/.wine-ableton"
    fi
    printf 'format=1\nmalformed=yes\n' > "$target/.ableton-linux-$kind"
    marker_digest="$(sha256sum -- "$target/.ableton-linux-$kind" | awk '{print $1}')"
    if run_adopt_marker "$base" "$kind" "$target" >"$base/out" 2>"$base/err"; then
        fail "legacy adoption repaired a malformed existing $kind marker"
    fi
    [ "$(sha256sum -- "$target/.ableton-linux-$kind" | awk '{print $1}')" = "$marker_digest" ] \
        || fail "malformed $kind marker refusal changed the existing marker"
done
ok "legacy migration adopts only canonical proven runtime/prefix trees and refuses custom or malformed ones"

base="$(new_env external-linkd-manifest)"
make_registry_runtime "$base"
external_linkd="$base/external/linkd"
mkdir -p -- "$(dirname "$external_linkd")"
printf 'external Link daemon\n' > "$external_linkd"
external_digest="$(sha256sum -- "$external_linkd" | awk '{print $1}')"
printf 'file\t%s\t%s\nruntime\t%s\twine-d2d1-nspa-11.13\n' \
    "$external_linkd" "$external_digest" "$base/runtime" \
    > "$base/xdg/state/ableton-wine/install-manifest.tsv"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINKD="$external_linkd" ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes >"$base/out" 2>"$base/err"; then
    fail "forged manifest claimed an external configured Link daemon"
fi
grep -qxF 'external Link daemon' "$external_linkd" \
    || fail "external Link daemon refusal happened after deletion"
ok "configured external Link daemon can be executed but never claimed or removed"

base="$(new_env transaction-external-target)"
txn="$base/txn"
victim="$base/external/victim"
mkdir -p -- "$txn/files" "$(dirname "$victim")"
: > "$txn/active"
printf 'live external\n' > "$victim"
printf 'forged restore\n' > "$txn/files/0"
printf 'present\t%s\t%s\n' "$victim" "$txn/files/0" > "$txn/files.tsv"
if run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_rollback_files "$2"
' _ "$here" "$txn" >"$base/out" 2>"$base/err"; then
    fail "transaction rollback accepted an arbitrary external target"
fi
grep -qxF 'live external' "$victim" \
    || fail "external transaction target was changed before scope refusal"
ok "transaction rollback authorizes only exact lifecycle targets"

base="$(new_env aggregate-runtime-preflight)"
txn="$base/txn"
backup="$base/runtime.transaction-${txn##*/}"
mkdir -p -- "$base/runtime" "$backup" "$txn/files"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$backup/.ableton-linux-runtime"
printf 'new runtime\n' > "$base/runtime/generation"
printf 'old runtime\n' > "$backup/generation"
printf '%s\t%s\n' "$base/runtime" "$backup" > "$txn/runtime.tsv"
: > "$txn/active"
printf 'forged\n' > "$txn/files/0"
printf 'present\t%s\t%s/files/999\n' \
    "$base/xdg/data/ableton-wine/detect-theme.sh" "$txn" > "$txn/files.tsv"
if run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" \
    bash "$here/install.sh" --rollback "$txn" >"$base/out" 2>"$base/err"; then
    fail "component rollback accepted a malformed later file journal"
fi
grep -qxF 'new runtime' "$base/runtime/generation" \
    && grep -qxF 'old runtime' "$backup/generation" \
    && [ -f "$txn/runtime.tsv" ] \
    || fail "component rollback mutated runtime before full preflight"

base="$(new_env aggregate-prefix-preflight)"
txn="$base/txn"
backup="$base/prefix.transaction-${txn##*/}"
mkdir -p -- "$base/prefix" "$backup" "$txn/prefix-host/files"
printf 'format=1\nprefix=%s\n' "$base/prefix" > "$base/prefix/.ableton-linux-prefix"
printf 'format=1\nprefix=%s\n' "$base/prefix" > "$backup/.ableton-linux-prefix"
printf 'new prefix\n' > "$base/prefix/generation"
printf 'old prefix\n' > "$backup/generation"
printf '%s\t%s\n' "$base/prefix" "$backup" > "$txn/prefix.tsv"
: > "$txn/prefix-host/active"
printf 'forged\n' > "$txn/prefix-host/files/0"
printf 'present\t%s\t%s/files/999\n' \
    "$base/xdg/config/pipeasio/config.ini" "$txn/prefix-host" \
    > "$txn/prefix-host/files.tsv"
if run_isolated "$base" env ABLETON_WINEPREFIX="$base/prefix" \
    bash "$here/setup-prefix.sh" --rollback "$txn" >"$base/out" 2>"$base/err"; then
    fail "prefix rollback accepted a malformed later host-file journal"
fi
grep -qxF 'new prefix' "$base/prefix/generation" \
    && grep -qxF 'old prefix' "$backup/generation" \
    && [ -f "$txn/prefix.tsv" ] \
    || fail "prefix rollback mutated layout before full preflight"
ok "runtime and prefix rollback preflight every journal before layout mutation"

base="$(new_env link-external-snapshot)"
txn="$base/txn"
snap="$txn/link"
mkdir -p -- "$snap"
printf 'off\n' > "$snap/policy"
: > "$snap/ready"; : > "$snap/firewall.absent"; : > "$snap/unit.absent"
: > "$snap/prestate.absent"; : > "$snap/prestate-dir.absent"
for label in 0 1 2 3; do
    case "$label" in
        0) path="$base/xdg/data/ableton-wine/ableton-linkd" ;;
        1) path="$base/xdg/data/ableton-wine/ableton-linkd.service" ;;
        2) path="$base/xdg/data/ableton-wine/ableton-linkctl" ;;
        3) path="$base/external/victim" ;;
    esac
    printf '%s\n' "$path" > "$snap/asset-$label.path"
done
mkdir -p -- "$base/external"
printf 'external snapshot victim\n' > "$base/external/victim"
if run_isolated "$base" bash "$here/setup-link.sh" preflight-rollback "$txn" \
    >"$base/out" 2>"$base/err"; then
    fail "Link rollback accepted an external asset snapshot path"
fi
grep -qxF 'external snapshot victim' "$base/external/victim" \
    || fail "Link snapshot refusal changed its external target"
ok "Link rollback preflights the complete canonical asset snapshot set"

run_link_transaction_action()
{
    local base="$1" action="$2" txn="$3"
    if [ ! -x "$base/fakebin/systemctl" ] || [ ! -x "$base/fakebin/xdg-mime" ]; then
        install_fake_host_tools "$base"
    fi
    run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_LINK_MODE=session bash "$here/setup-link.sh" "$action" "$txn"
}

base="$(new_env link-valid-snapshot)"
txn="$base/txn"
mkdir -p -- "$txn" "$base/runtime" "$base/prefix" "$base/xdg/data/ableton-wine"
printf 'owned asset bytes\n' > "$base/xdg/data/ableton-wine/setup-link.sh"
run_link_transaction_action "$base" snapshot "$txn" >"$base/snapshot.out" 2>"$base/snapshot.err" \
    || fail "valid Link snapshot fixture could not capture a complete snapshot"
run_link_transaction_action "$base" preflight-rollback "$txn" >"$base/preflight.out" 2>"$base/preflight.err" \
    || fail "valid complete Link snapshot was rejected by preflight"
find "$txn/link" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort > "$base/link.members"
[ "$(wc -l < "$base/link.members")" -eq 20 ] \
    || fail "valid Link snapshot did not record the full inventory"
printf '%s\n' "$base/external/other" > "$txn/link/asset-3.path"
if run_link_transaction_action "$base" preflight-rollback "$txn" >"$base/path.out" 2>"$base/path.err"; then
    fail "Link preflight accepted a valid snapshot after an external asset path was forged"
fi
grep -qF 'Link asset snapshot path is invalid' "$base/path.err" \
    || fail "forged Link asset snapshot path refusal was not explicit"
ok "valid Link snapshots pass preflight and still reject forged external asset paths"

for kind in regular symlink directory; do
    base="$(new_env "link-live-${kind}-changed")"
    txn="$base/txn"
    asset="$base/xdg/data/ableton-wine/setup-link.sh"
    mkdir -p -- "$txn" "$base/runtime" "$base/prefix" "$(dirname "$asset")"
    printf 'owned asset bytes\n' > "$asset"
    run_link_transaction_action "$base" snapshot "$txn" >"$base/snapshot.out" 2>"$base/snapshot.err" \
        || fail "Link live-$kind fixture could not capture its snapshot"
    case "$kind" in
        regular) printf 'user edit bytes\n' > "$asset" ;;
        symlink)
            printf 'external asset bytes\n' > "$base/external-asset"
            rm -f -- "$asset"
            ln -s -- "$base/external-asset" "$asset"
            ;;
        directory)
            rm -f -- "$asset"
            mkdir -p -- "$asset"
            printf 'directory sentinel\n' > "$asset/sentinel"
            ;;
    esac
    if run_link_transaction_action "$base" preflight-rollback "$txn" >"$base/out" 2>"$base/err"; then
        fail "Link preflight accepted a $kind current asset change"
    fi
    case "$kind" in
        directory)
            grep -qF "Link rollback destination is unsafe: $asset" "$base/err" \
                || fail "directory Link asset refusal was not explicit"
            grep -qxF 'directory sentinel' "$asset/sentinel" \
                || fail "directory Link asset refusal changed the live directory"
            ;;
        *)
            grep -qF "Link asset changed while rollback was pending: $asset" "$base/err" \
                || fail "$kind Link asset refusal was not explicit"
            ;;
    esac
done
ok "Link rollback preflight rejects regular, symlink, and directory asset changes after a valid snapshot"

for corrupt_kind in symlink multiline; do
    base="$(new_env "link-firewall-${corrupt_kind}")"
    txn="$base/txn"
    mkdir -p -- "$txn" "$base/runtime" "$base/prefix" "$base/xdg/state/ableton-wine"
    case "$corrupt_kind" in
        symlink)
            printf 'external firewall sentinel\n' > "$base/external-firewall"
            ln -s -- "$base/external-firewall" "$base/xdg/state/ableton-wine/link-firewall"
            ;;
        multiline)
            printf 'ufw-added\nextra\n' > "$base/xdg/state/ableton-wine/link-firewall"
            ;;
    esac
    if run_link_transaction_action "$base" snapshot "$txn" >"$base/out" 2>"$base/err"; then
        fail "Link snapshot accepted a $corrupt_kind firewall state record"
    fi
    grep -qF "unsafe Link firewall ownership record: $base/xdg/state/ableton-wine/link-firewall" "$base/err" \
        || fail "$corrupt_kind firewall snapshot refusal was not explicit"
done

base="$(new_env link-unit-symlink)"
txn="$base/txn"
unit_file="$base/xdg/config/systemd/user/ableton-linkd.service"
mkdir -p -- "$txn" "$base/runtime" "$base/prefix" "$(dirname "$unit_file")"
printf 'external unit sentinel\n' > "$base/external-unit"
ln -s -- "$base/external-unit" "$unit_file"
if run_link_transaction_action "$base" snapshot "$txn" >"$base/out" 2>"$base/err"; then
    fail "Link snapshot accepted a symlinked unit file"
fi
grep -qF "unsafe or foreign Link unit cannot be snapshotted: $unit_file" "$base/err" \
    || fail "unit symlink snapshot refusal was not explicit"
grep -qxF 'external unit sentinel' "$base/external-unit" \
    || fail "unit symlink snapshot refusal changed the foreign referent"
ok "Link snapshot rejects unsafe firewall records and foreign unit symlinks"

base="$(new_env mime-stage-partial-failure)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
mkdir -p -- "$base/xdg/config"
printf '[Default Applications]\nx-scheme-handler/ableton=foreign.desktop\n' \
    > "$base/xdg/config/mimeapps.list"
cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/bin/sh
state="$XDG_CONFIG_HOME/.xdg-mime-count"
count=0
[ ! -f "$state" ] || count="$(cat "$state")"
case "${1:-}" in
    query) exit 0 ;;
    default)
        count=$((count + 1))
        printf '%s\n' "$count" > "$state"
        printf '[Default Applications]\npartial=%s\n' "$count" > "$XDG_CONFIG_HOME/mimeapps.list"
        [ "$count" -lt 2 ] || exit 88
        exit 0
        ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$base/fakebin/xdg-mime"
if run_component_install "$base" "$base/runtime" --integration-only >"$base/out" 2>"$base/err"; then
    fail "integration succeeded after staged MIME mutation failed"
fi
grep -qF 'MIME association staging failed; existing associations were unchanged' "$base/err" \
    || fail "staged MIME failure was not explicit"
cmp -s -- "$base/xdg/config/mimeapps.list" <(printf '[Default Applications]\nx-scheme-handler/ableton=foreign.desktop\n') \
    || fail "staged MIME failure mutated the live mimeapps file"
ok "MIME staging can mutate its temp copy and still leaves live associations unchanged on failure"

write_valid_managed_config()
{
    local path="$1" runtime_root="$2" prefix_root="$3" linkd_path="$4"
    mkdir -p -- "$(dirname "$path")"
    cat > "$path" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$runtime_root
prefix=$prefix_root
live_major=12
link_mode=off
linkd=$linkd_path
EOF
}

base="$(new_env config-race)"
config_path="$base/xdg/config/ableton-wine/config"
write_valid_managed_config "$config_path" "$base/runtime" "$base/prefix" \
    "$base/xdg/data/ableton-wine/ableton-linkd"
if run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    cat > "$ABLETON_CONFIG_FILE" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root='"$base"'/different-runtime
prefix='"$base"'/prefix
live_major=12
link_mode=off
linkd='"$base"'/xdg/data/ableton-wine/ableton-linkd
EOF
    ableton_install_lock_acquire
' _ "$here" >"$base/out" 2>"$base/err"; then
    fail "install lock accepted a configuration changed after snapshot capture"
fi
grep -qF 'installation configuration changed; retry the command' "$base/err" \
    || fail "configuration race refusal was not explicit"
ok "config lock revalidates the captured configuration token before mutating anything"

for corrupt_kind in truncated duplicate symlink; do
    base="$(new_env "config-${corrupt_kind}")"
    config_path="$base/xdg/config/ableton-wine/config"
    case "$corrupt_kind" in
        truncated)
            mkdir -p -- "$(dirname "$config_path")"
            cat > "$config_path" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
EOF
            ;;
        duplicate)
            mkdir -p -- "$(dirname "$config_path")"
            cat > "$config_path" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
linkd=$base/xdg/data/ableton-wine/ableton-linkd
linkd=$base/xdg/data/ableton-wine/other-linkd
EOF
            ;;
        symlink)
            printf 'foreign config sentinel\n' > "$base/foreign-config"
            mkdir -p -- "$(dirname "$config_path")"
            ln -s -- "$base/foreign-config" "$config_path"
            ;;
    esac
    if run_isolated "$base" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
    ' _ "$here" >"$base/out" 2>"$base/err"; then
        fail "config init accepted a $corrupt_kind managed configuration"
    fi
    grep -qF "refusing malformed installer configuration $config_path" "$base/err" \
        || fail "$corrupt_kind config refusal was not explicit"
    if [ "$corrupt_kind" = symlink ]; then
        grep -qxF 'foreign config sentinel' "$base/foreign-config" \
            || fail "symlink config refusal changed the external referent"
    fi
done
ok "strict managed-config validation rejects truncated, duplicate, and symlinked configs"

base="$(new_env legacy-shortcut-state)"
state="$base/xdg/state/ableton-wine"
mkdir -p -- "$state"
chmod 700 "$state"
printf '%s\n%s\n' \
    'ABLETON_SHORTCUT_HOLD_V2' \
    "org.gnome.desktop.wm.keybindings|switch-to-workspace-up|['<Control><Alt>Up', '<Super>Up']|['<Super>Up']" \
    > "$state/hold-v2"
chmod 600 "$state/hold-v2"
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; ableton_config_init; ableton_install_lock_acquire; ableton_mark_state_home
' _ "$here" || fail "known legacy shortcut state could not be marker-adopted"
cmp -s -- "$state/.ableton-linux-state" <(printf 'format=1\nowner=ableton-linux\n') \
    || fail "legacy shortcut state adoption did not create an exact marker"
printf 'foreign\n' > "$state/foreign"
rm -f -- "$state/.ableton-linux-state"
if run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; ableton_config_init; ableton_install_lock_acquire; ableton_mark_state_home
' _ "$here" >"$base/out" 2>"$base/err"; then
    fail "legacy shortcut-state adoption claimed unrelated state content"
fi
ok "legacy unmarked state adoption is restricted to a valid hold-v2 snapshot"

base="$(new_env plan-temp-cleanup)"
make_runtime_only_kit "$base"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/installer.sh" plan runtime install \
    --runtime-root "$base/runtime" --yes >"$base/out" 2>"$base/err" \
    || fail "public runtime plan failed"
[ "$(grep -c '^== validate runtime payload:' "$base/out")" -eq 1 ] \
    || fail "public runtime plan validates and extracts its payload more than once"
if find "$base/tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'ableton-install-plan.*' -o -name 'ableton-runtime-validate.*' \) \
    -print -quit | grep -q .; then
    fail "public runtime plan leaked a component transaction or extracted runtime"
fi
[ ! -e "$base/xdg/state" ] \
    || fail "public runtime plan created persistent installer state"
ok "public runtime plans retire validation transactions and extracted payloads"

base="$(new_env rollback-literal-pipeasio-symlink)"
make_rollback_fixture "$base"
foreign_pipeasio="$base/foreign-pipeasio.ini"
printf '[pipeasio]\nbuffer_size = 192\nforeign = keep\n' > "$foreign_pipeasio"
foreign_pipeasio_digest="$(sha256sum -- "$foreign_pipeasio" | awk '{print $1}')"
rm -f -- "$ROLLBACK_SAVED/.ableton-linux-rollback/pipeasio-config.ini"
ln -s -- "$foreign_pipeasio" \
    "$ROLLBACK_SAVED/.ableton-linux-rollback/pipeasio-config.ini"
run_user_rollback "$base" env ABLETON_TEST_REGISTRY_STICKY=0 \
    >"$base/out" 2>"$base/err" \
    || fail "rollback rejected a literal PipeASIO configuration symlink snapshot"
[ -L "$ROLLBACK_PIPEASIO_CONFIG" ] \
    && [ "$(readlink -- "$ROLLBACK_PIPEASIO_CONFIG")" = "$foreign_pipeasio" ] \
    || fail "rollback restored the PipeASIO symlink referent instead of the literal object"
[ "$(sha256sum -- "$foreign_pipeasio" | awk '{print $1}')" = "$foreign_pipeasio_digest" ] \
    || fail "literal PipeASIO symlink rollback changed the external referent"
ok "runtime rollback restores the literal PipeASIO config symlink object"

install_config_race_flock()
{
    local base="$1" real_flock
    real_flock="$(command -v flock)"
    mkdir -p -- "$base/fakebin"
    cat > "$base/fakebin/flock" <<EOF
#!/bin/sh
set -eu
if [ ! -e "\${ABLETON_TEST_FLOCK_MUTATED:?}" ]; then
    /bin/cp -- "\${ABLETON_TEST_CONFIG_REPLACEMENT:?}" "\${ABLETON_TEST_CONFIG_TARGET:?}"
    : > "\${ABLETON_TEST_FLOCK_MUTATED:?}"
fi
exec "$real_flock" "\$@"
EOF
    chmod 755 "$base/fakebin/flock"
}

for race_kind in public-runtime direct-link; do
    base="$(new_env "config-race-${race_kind}")"
    config_path="$base/xdg/config/ableton-wine/config"
    old_linkd="$base/home/old-linkd"
    new_linkd="$base/home/new-linkd"
    printf 'old Link sentinel\n' > "$old_linkd"
    printf 'new Link sentinel\n' > "$new_linkd"
    write_valid_managed_config "$config_path" "$base/runtime" "$base/prefix" "$old_linkd"
    replacement="$base/config.replacement"
    write_valid_managed_config "$replacement" "$base/changed-runtime" \
        "$base/changed-prefix" "$new_linkd"
    install_config_race_flock "$base"
    if [ "$race_kind" = public-runtime ]; then
        make_runtime_only_kit "$base"
        command=(bash "$base/kit/scripts/installer.sh" runtime install \
            --runtime-root "$base/runtime" --yes)
    else
        install_fake_host_tools "$base"
        command=(bash "$here/setup-link.sh" disable)
    fi
    if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
        ABLETON_TEST_FLOCK_MUTATED="$base/flock-mutated" \
        ABLETON_TEST_CONFIG_REPLACEMENT="$replacement" \
        ABLETON_TEST_CONFIG_TARGET="$config_path" \
        "${command[@]}" >"$base/out" 2>"$base/err"; then
        fail "$race_kind accepted an installer configuration changed while waiting for the lock"
    fi
    grep -qF 'installation configuration changed; retry the command' "$base/err" \
        || fail "$race_kind config-race refusal did not report the exact retry diagnostic"
    if ! grep -qxF 'old Link sentinel' "$old_linkd" \
       || ! grep -qxF 'new Link sentinel' "$new_linkd"; then
        fail "$race_kind config-race refusal changed a resolved Link target"
    fi
    [ ! -e "$base/runtime" ] && [ ! -e "$base/changed-runtime" ] \
        || fail "$race_kind config-race refusal changed a runtime path"
done
ok "public and direct mutators refuse a configuration changed before lock acquisition"

base="$(new_env inherited-lock-daemon)"
linkd="$base/xdg/data/ableton-wine/ableton-linkd"
mkdir -p -- "$(dirname "$linkd")"
cat > "$linkd" <<'EOF'
#!/bin/sh
# ableton-linkd: native Ableton Link session anchor and probe
exec sleep 30
EOF
chmod 755 "$linkd"
run_isolated "$base" env ABLETON_LINK_MODE=session bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    ableton_install_lock_acquire
    bash "$1/ableton-linkctl" start
' _ "$here" >"$base/start.out" 2>"$base/start.err" \
    || fail "Link controller could not start the lock-inheritance fixture"
link_pid_file="$base/xdg/run/ableton-wine/linkd.pid"
[ -s "$link_pid_file" ] || fail "Link controller did not record its detached daemon"
link_pid="$(sed -n '1p' "$link_pid_file")"
kill -0 "$link_pid" 2>/dev/null || fail "detached Link fixture exited before lock verification"
run_isolated "$base" env -u ABLETON_INSTALL_LOCK_FD bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    ableton_install_lock_acquire
' _ "$here" >"$base/lock.out" 2>"$base/lock.err" \
    || fail "detached Link daemon retained the inherited installer lock"
kill "$link_pid" 2>/dev/null || true
ok "detached Link daemons close the inherited installer lock descriptor"

make_commit_preflight_kit()
{
    local base="$1" kit="$1/commit-kit"
    mkdir -p -- "$kit/scripts/lib"
    cp -- "$here/installer.sh" "$kit/scripts/"
    cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" "$here/lib/live-options.sh" \
        "$here/lib/manifest.sh" "$here/lib/pipeasio.sh" "$kit/scripts/lib/"
    cat > "$kit/scripts/install.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'component %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
case " $* " in
    *' --preflight-commit '*) exit 0 ;;
    *' --commit '*) rm -f -- "$2/component-backup" ;;
esac
EOF
    cat > "$kit/scripts/setup-prefix.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'prefix %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
case " $* " in
    *' --preflight-commit '*)
        if [ "${ABLETON_TEST_FAIL_COMMIT_DOMAIN:-}" = prefix ]; then
            echo '!! injected prefix commit preflight failure' >&2
            exit 77
        fi ;;
    *' --commit '*) rm -f -- "$2/prefix-backup" ;;
esac
EOF
    cat > "$kit/scripts/setup-link.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'link %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
case "${1:-}" in
    snapshot)
        mkdir -p -- "$2/link"
        : > "$2/link/ready"
        : > "$2/component-backup"
        : > "$2/prefix-backup"
        ;;
    preflight-commit)
        if [ "${ABLETON_TEST_FAIL_COMMIT_DOMAIN:-}" = link ]; then
            echo '!! injected Link commit preflight failure' >&2
            exit 78
        fi ;;
    commit) rm -rf -- "$2/link" ;;
esac
EOF
    chmod 755 "$kit/scripts/install.sh" "$kit/scripts/setup-prefix.sh" \
        "$kit/scripts/setup-link.sh"
}

for fail_domain in prefix link; do
    base="$(new_env "aggregate-commit-${fail_domain}")"
    make_commit_preflight_kit "$base"
    call_log="$base/calls.log"
    : > "$call_log"
    if run_isolated "$base" env \
        ABLETON_TEST_CALL_LOG="$call_log" \
        ABLETON_TEST_FAIL_COMMIT_DOMAIN="$fail_domain" \
        bash "$base/commit-kit/scripts/installer.sh" link disable \
        >"$base/out" 2>"$base/err"; then
        fail "outer installer accepted an injected $fail_domain commit-preflight failure"
    fi
    if [ "$fail_domain" = prefix ]; then
        grep -qF 'injected prefix commit preflight failure' "$base/err" \
            || fail "prefix commit-preflight failure did not reach its intended validator"
    else
        grep -qF 'injected Link commit preflight failure' "$base/err" \
            || fail "Link commit-preflight failure did not reach its intended validator"
    fi
    if grep -Eq '^component --commit |^prefix --commit |^link commit ' "$call_log"; then
        fail "$fail_domain preflight failure retired an earlier component snapshot"
    fi
    failed_txn="$(find "$base/xdg/state/ableton-wine/transactions" \
        -mindepth 1 -maxdepth 1 -type d -name 'installer.*' -print -quit)"
    [ -n "$failed_txn" ] \
        && [ -f "$failed_txn/component-backup" ] \
        && [ -f "$failed_txn/prefix-backup" ] \
        || fail "$fail_domain preflight failure did not retain every rollback generation"
done
ok "outer commit preflights every domain before retiring any rollback material"

make_pr182_custom_link_fixture()
{
    local base="$1" mode="$2" data state config custom digest id backup
    make_runtime_only_kit "$base"
    install_fake_host_tools "$base"
    cp -- "$here/setup-link.sh" "$here/ableton-linkctl" \
        "$here/ableton-linkd.service" "$base/kit/scripts/"
    cat > "$base/kit/bin/ableton-linkd" <<'EOF'
#!/bin/sh
case "${1:-}" in
    --help) echo 'fixture Link daemon' ;;
esac
exit 0
EOF
    chmod 755 "$base/kit/bin/ableton-linkd"
    cat > "$base/fakebin/readelf" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 755 "$base/fakebin/readelf"

    data="$base/xdg/data/ableton-wine"
    state="$base/xdg/state/ableton-wine"
    config="$base/xdg/config/ableton-wine/config"
    custom="$base/home/custom/ableton-linkd"
    mkdir -p -- "$data" "$state" "$base/home/.local/bin" "$(dirname "$custom")"
    printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
    chmod 600 "$state/.ableton-linux-state"
    printf '2026.08.08.1\n' > "$data/VERSION"
    printf '#!/bin/sh\n# Ableton Live launcher for the patched Wine stack\n' \
        > "$base/home/.local/bin/ableton-live"
    chmod 755 "$base/home/.local/bin/ableton-live"
    write_valid_managed_config "$config" "$base/runtime" "$base/prefix" "$custom"
    printf 'historical PR182 Link binary\n' > "$custom"
    chmod 755 "$custom"
    digest="$(sha256sum -- "$custom" | awk '{print $1}')"
    case "$mode" in
        owned-prestate)
            printf 'file\t%s\t%s\n' "$custom" "$digest" > "$state/install-manifest.tsv"
            id="$(printf '%s' "$custom" | sha256sum | awk '{print $1}')"
            backup="$state/install-prestate/$id"
            mkdir -p -- "$state/install-prestate"
            printf 'foreign pre-PR182 Link binary\n' > "$backup"
            chmod 755 "$backup"
            printf 'present\t%s\t%s\n' "$custom" "$backup" \
                > "$state/install-prestate.tsv"
            ;;
        modified)
            printf 'file\t%s\t%s\n' "$custom" "$digest" > "$state/install-manifest.tsv"
            printf 'user modified former PR182 Link binary\n' > "$custom"
            chmod 755 "$custom"
            ;;
        unowned-off)
            # A genuine PR182 --link=off install had the surrounding release
            # evidence but no ownership row for the configured external path.
            : > "$state/install-manifest.tsv"
            printf 'external Link sentinel from --link=off\n' > "$custom"
            chmod 755 "$custom"
            ;;
        *) fail "unknown PR182 custom-Link fixture mode $mode" ;;
    esac
    PR182_CUSTOM_LINK="$custom"
    PR182_MANIFEST="$state/install-manifest.tsv"
    PR182_PRESTATE_INDEX="$state/install-prestate.tsv"
    PR182_CONFIG="$config"
}

for migration_mode in owned-prestate modified unowned-off; do
    base="$(new_env "pr182-custom-link-${migration_mode}")"
    make_pr182_custom_link_fixture "$base" "$migration_mode"
    custom="$PR182_CUSTOM_LINK"
    if ! run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        bash "$base/kit/scripts/installer.sh" link disable \
        >"$base/out" 2>"$base/err"; then
        sed -n '1,160p' "$base/out" >&2
        sed -n '1,200p' "$base/err" >&2
        fail "public Link disable could not migrate PR182 custom-Link mode $migration_mode"
    fi
    case "$migration_mode" in
        owned-prestate)
            grep -qxF 'foreign pre-PR182 Link binary' "$custom" \
                || fail "PR182 custom-Link migration did not restore the foreign prestate"
            if [ -e "$PR182_PRESTATE_INDEX" ] \
               && awk -F '\t' -v p="$custom" '$2==p { found=1 } END { exit !found }' \
                    "$PR182_PRESTATE_INDEX"; then
                fail "PR182 custom-Link migration retained consumed prestate authority"
            fi
            grep -qF 'retired the PR #182 custom Link binary ownership' "$base/out" \
                || fail "owned PR182 custom-Link path did not use the verified retirement path"
            ;;
        modified)
            grep -qxF 'user modified former PR182 Link binary' "$custom" \
                || fail "PR182 custom-Link migration overwrote a user-modified object"
            grep -qF 'kept and de-owned the modified former PR #182 Link binary' "$base/out" \
                || fail "modified PR182 custom-Link path did not use the de-ownership path"
            ;;
        unowned-off)
            grep -qxF 'external Link sentinel from --link=off' "$custom" \
                || fail "PR182 --link=off evidence falsely authorized external deletion"
            grep -qxF "linkd=$custom" "$PR182_CONFIG" \
                || fail "unowned external Link configuration was unexpectedly canonicalized"
            ;;
    esac
    if awk -F '\t' -v p="$custom" '$2==p { found=1 } END { exit !found }' \
        "$PR182_MANIFEST"; then
        fail "PR182 custom-Link mode $migration_mode retained an obsolete ownership row"
    fi
    grep -qxF 'link_mode=off' "$PR182_CONFIG" \
        || fail "PR182 custom-Link mode $migration_mode did not finish disabled"
    if [ "$migration_mode" != unowned-off ]; then
        grep -qxF "linkd=$base/xdg/data/ableton-wine/ableton-linkd" "$PR182_CONFIG" \
            || fail "verified PR182 custom-Link ownership was not migrated to the canonical path"
    fi
done
ok "PR182 custom-Link migration restores owned prestate, de-owns edits, and preserves --link=off paths"

printf 'PASS: %s focused PipeASIO installer checks\n' "$pass"
