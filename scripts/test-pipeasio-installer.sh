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
grep -qF 'Install PipeWire 1.4.2 or newer.' "$here/setup-prefix.sh" \
    || fail "prefix setup does not report the enforced PipeWire floor"
if grep -qF '0.3.56 or newer' "$here/setup-prefix.sh"; then
    fail "prefix setup still reports the obsolete PipeWire floor"
fi
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
        TMPDIR="$base/tmp" ABLETON_SHORTCUTS=preserve \
        ABLETON_MAX_AUDIO_THREADS=off "$@"
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

# Once the native probe and version comparison have succeeded, their terminal
# report is presentation only. Optional-tool advice is presentation from the
# outset. A closed stdout must not turn either into a component/rollback error.
if ! env PATH="$probe_base/core-path" \
    PROBE_CLIENT=1.6.8 PROBE_DAEMON=1.6.8 PROBE_EXIT=0 \
    /bin/bash -c '
        set -euo pipefail
        . "$1"
        ableton_pipewire_preflight "$2" >&-
        ABLETON_PIPEASIO_DIAGNOSTIC_NOTICE_SHOWN=0
        ableton_pipeasio_optional_tools_advice >&-
    ' _ "$here/lib/pipeasio.sh" "$probe" 2>/dev/null; then
    fail "successful PipeWire proof or optional-tool advice inherited terminal output status"
fi
ok "successful compatibility proof and optional-tool advice ignore presentation failures"

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
grep -qF 'Another Ableton Linux install, repair, or removal is already running. Wait for it to finish and try again.' \
    "$base/setup-link.err" || fail "setup-link lock refusal was not explicit"
[ ! -e "$base/link-transaction" ] \
    || fail "refused setup-link mutator created a transaction snapshot"
[ "$(sha256sum -- "$base/xdg/state/ableton-wine/.ableton-linux-state" | awk '{print $1}')" \
    = "$state_marker_digest" ] || fail "refused setup-link mutator changed installer state"
exec {held_lock_fd}<&-
ok "one non-persistent lock serializes installer helpers and direct setup-link mutators"

# A forked Bash child shares the parent's open file description. It may close
# its duplicate, but must never issue LOCK_UN against the parent's lock. The
# opener may still release it explicitly, including when the opener itself is a
# subshell (BASHPID, rather than $$, identifies that owner).
base="$(new_env mutation-lock-owner)"
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    ableton_install_lock_acquire
    parent_fd="$ABLETON_INSTALL_LOCK_FD"
    ( ableton_install_lock_release >/dev/null 2>&1 || true )
    if (
        inherited="$parent_fd"
        exec {inherited}<&-
        unset ABLETON_INSTALL_LOCK_FD ABLETON_INSTALL_LOCK_OWNER_BASHPID
        ableton_install_lock_acquire >/dev/null 2>&1
    ); then
        echo "forked child unlocked its parent" >&2
        exit 1
    fi
    ableton_install_lock_release
    (
        unset ABLETON_INSTALL_LOCK_FD ABLETON_INSTALL_LOCK_OWNER_BASHPID
        ableton_install_lock_acquire
        ableton_install_lock_release
    )
' _ "$here" || fail "installation lock ownership is not confined to the opening Bash process"
ok "forked children cannot unlock their parent, while each real lock owner can release"

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
    ableton_pipeasio_validate_runtime "$1" "$2" >/dev/null 2>&1 \
        && ableton_pipeasio_validate_panel "$1" "$2" >/dev/null 2>&1
}

runtime_fails_validation()
{
    if ableton_pipeasio_validate_runtime "$1" "$2" >/dev/null 2>&1 \
       && ableton_pipeasio_validate_panel "$1" "$2" >/dev/null 2>&1; then
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
ableton_pipeasio_validate_runtime "$base/runtime" "$base/BUILD-INFO.txt" >/dev/null 2>&1 \
    || fail "partial optional panel invalidated the core PipeASIO runtime"
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

# The Nix package links whatever Qt 6 its nixpkgs carries, so on a runtime that
# identifies itself as nix the panel record names the version actually built
# against.  The release pin above is unchanged; only "dist-version: nix"
# reaches the relaxed grammar, and the record must still be a version.
base="$(new_env nix-panel-grammar)"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
# Rewrites both records outright, so repeated calls do not depend on what the
# previous one left behind.
nixify()   # <panel record tail>
{
    awk -v tail="$1" '
        /^dist-version: / { print "dist-version: nix"; next }
        /^pipeasio-settings: / { print $1, $2, tail; next }
        { print }
    ' "$base/runtime/ABLETON-WINE-BUILD-INFO.txt" > "$base/info.rewritten"
    mv -- "$base/info.rewritten" "$base/runtime/ABLETON-WINE-BUILD-INFO.txt"
    cp -- "$base/runtime/ABLETON-WINE-BUILD-INFO.txt" "$base/BUILD-INFO.txt"
}
nixify '(Qt 6.9 link)'
ableton_pipeasio_validate_panel "$base/runtime" >/dev/null 2>&1 \
    || fail "a nix runtime's own Qt version was refused by the panel record"
# The bug this grammar exists to catch: a builder that writes the link name
# instead of the version passes its own build and then breaks setup-prefix.
nixify '(Qt6 Widgets link)'
if ableton_pipeasio_validate_panel "$base/runtime" >/dev/null 2>&1; then
    fail "a panel record naming the Qt library instead of its version was accepted"
fi
nixify '(Qt 6.9 link)'
ok "the nix panel record takes any Qt 6 version but still has to be a version"

# "nix" is not a release version, and the store path is what corroborates it:
# a runtime outside the store may not use the name to skip the version check.
runtime_fails_validation "$base/runtime" "$base/BUILD-INFO.txt" \
    || fail "dist-version nix was accepted for a runtime outside the nix store"
ok "dist-version nix is refused for a runtime that is not in the store"

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
    || fail "direct runtime-only reconcile created previously absent panel shortcuts"
runtime_only_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
if [ -r "$runtime_only_manifest" ] && awk -F '\t' \
    -v command="$base/home/.local/bin/pipeasio-settings" \
    -v desktop="$base/xdg/data/applications/pipeasio-settings.desktop" \
    -v icon="$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg" \
    '$2 == command || $2 == desktop || $2 == icon { found=1 } END { exit !found }' \
    "$runtime_only_manifest"; then
    fail "direct runtime-only reconcile claimed absent panel shortcuts"
fi
grep -qxF 'OK: Installation complete.' "$base/out" \
    || fail "direct runtime-only install did not print its simple outcome"
ok "direct runtime-only install completes before reconciling optional panel shortcuts"

# Repair-mode parsing keeps safe, unambiguous values from this project's file
# even when an obsolete field makes the whole generation invalid. CLI values
# still win, and the malformed regular file is not replaced until Wine is
# validated and committed.
base="$(new_env managed-config-repair)"
make_runtime_only_kit "$base"
config_path="$base/xdg/config/ableton-wine/config"
custom_prefix="$base/custom-prefix"
mkdir -p -- "$(dirname "$config_path")"
cat > "$config_path" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/old-runtime
prefix=$custom_prefix
live_major=12
link_mode=off
obsolete_field=written-by-an-older-installer
EOF
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$base/kit/scripts/installer.sh" update --dry-run \
    >"$base/update.out" 2>"$base/update.err"; then
    fail "update fixture unexpectedly passed without an existing custom prefix"
fi
grep -qF "update needs an existing prefix at $custom_prefix" "$base/update.err" \
    || fail "repair mode dropped an unambiguous custom prefix and checked the default instead"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/installer.sh" runtime install \
        --runtime-root "$base/runtime" --yes >"$base/install.out" 2>"$base/install.err" \
    || fail "runtime install could not repair a project-owned malformed config"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    || fail "managed-config repair did not retain the committed runtime"
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init strict
    ableton_managed_config_valid "$ABLETON_CONFIG_FILE"
' _ "$here" || fail "managed-config repair did not publish a strict valid generation"
grep -qxF "runtime_root=$base/runtime" "$config_path" \
    && grep -qxF "prefix=$custom_prefix" "$config_path" \
    && ! grep -q '^obsolete_field=' "$config_path" \
    || fail "managed-config repair lost salvaged paths or retained obsolete data"
ok "coordinator repair salvages custom paths and rewrites malformed project settings only after core success"

for config_kind in foreign-regular symlink directory; do
    base="$(new_env "config-repair-${config_kind}")"
    make_runtime_only_kit "$base"
    config_path="$base/xdg/config/ableton-wine/config"
    mkdir -p -- "$(dirname "$config_path")"
    case "$config_kind" in
        foreign-regular)
            printf 'foreign arbitrary settings\n' > "$config_path" ;;
        symlink)
            printf 'foreign symlink referent\n' > "$base/foreign-config"
            ln -s -- "$base/foreign-config" "$config_path" ;;
        directory)
            mkdir -- "$config_path"
            printf 'foreign directory sentinel\n' > "$config_path/sentinel" ;;
    esac
    run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
        bash "$base/kit/scripts/installer.sh" runtime install \
            --runtime-root "$base/runtime" --yes >"$base/out" 2>"$base/err" \
        || fail "$config_kind installer settings invalidated a runtime install"
    [ -f "$base/runtime/.ableton-linux-runtime" ] \
        || fail "$config_kind installer settings displaced the committed runtime"
    case "$config_kind" in
        foreign-regular)
            run_isolated "$base" bash -c '
                set -euo pipefail
                . "$1/lib/config.sh"
                ableton_config_init strict
                ableton_managed_config_valid "$ABLETON_CONFIG_FILE"
            ' _ "$here" || fail "arbitrary regular settings were not rebuilt"
            grep -qxF "runtime_root=$base/runtime" "$config_path" \
                || fail "arbitrary settings repair did not keep the CLI runtime" ;;
        symlink)
            [ -L "$config_path" ] \
                && [ "$(readlink -- "$config_path")" = "$base/foreign-config" ] \
                && grep -qxF 'foreign symlink referent' "$base/foreign-config" \
                || fail "config repair replaced a symlink or changed its referent"
            grep -qF 'Wine is ready, but installer settings could not be saved.' "$base/err" \
                || fail "symlink config retention was not a saved-settings warning" ;;
        directory)
            [ -d "$config_path" ] && [ ! -L "$config_path" ] \
                && grep -qxF 'foreign directory sentinel' "$config_path/sentinel" \
                || fail "config repair replaced a foreign settings directory"
            grep -qF 'Wine is ready, but installer settings could not be saved.' "$base/err" \
                || fail "directory config retention was not a saved-settings warning" ;;
    esac
done
ok "arbitrary settings cannot gate Wine, while symlink and directory objects stay unchanged"

# Runtime-only work does not use prefix, desktop-data, installer-settings,
# persistent-state, or launcher roots for its core promotion. Foreign objects
# at any of those optional paths must survive while Wine still commits; the
# post-core panel/config repair may warn and skip them.
for optional_root in prefix data config state bin; do
    base="$(new_env "runtime-unrelated-${optional_root}-root")"
    make_runtime_only_kit "$base"
    foreign_root="$base/foreign-$optional_root-root"
    printf 'foreign optional root\n' > "$foreign_root"
    case "$optional_root" in
        prefix) root_var=ABLETON_WINEPREFIX ;;
        data) root_var=ABLETON_DATA_HOME ;;
        config) root_var=ABLETON_CONFIG_HOME ;;
        state) root_var=ABLETON_STATE_HOME ;;
        bin) root_var=ABLETON_BIN_HOME ;;
    esac
    run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        "$root_var=$foreign_root" PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
        bash "$base/kit/scripts/installer.sh" runtime install \
            --runtime-root "$base/runtime" --yes >"$base/out" 2>"$base/err" \
        || fail "unrelated $optional_root root blocked runtime-only installation"
    [ -f "$base/runtime/.ableton-linux-runtime" ] \
        && grep -qxF 'foreign optional root' "$foreign_root" \
        || fail "runtime-only installation changed the unrelated $optional_root root"
done
ok "unrelated optional root objects cannot gate runtime-only installation"

base="$(new_env coordinator-postcore-output)"
make_runtime_only_kit "$base"
cat > "$base/postcore-failure.bash" <<'EOF'
echo()
{
    if [ "$*" = 'OK: the Wine runtime is installed' ]; then
        return 74
    fi
    builtin echo "$@"
}
EOF
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    BASH_ENV="$base/postcore-failure.bash" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/installer.sh" runtime install \
        --runtime-root "$base/runtime" --yes >"$base/out" 2>"$base/err" \
    || fail "final output failure reported a committed runtime as failed"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    || fail "final output failure rolled back the committed runtime"
grep -qxF "  runtime: $base/runtime" "$base/out" \
    || fail "one failed success line stopped the remaining final presentation"
ok "coordinator continues final presentation after one output fails"

base="$(new_env child-runtime-only-core)"
make_runtime_only_kit "$base"
txn="$base/core-transaction"
mkdir -p -- "$txn"
run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --transaction-dir "$txn" --yes \
    >"$base/out" 2>"$base/err" || fail "parent-owned runtime core phase failed"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    || fail "parent-owned runtime core phase did not promote Wine"
[ -s "$txn/runtime.tsv" ] \
    || fail "parent-owned runtime core phase omitted its directory rollback record"
[ -f "$txn/files.tsv" ] && [ ! -s "$txn/files.tsv" ] \
    || fail "parent-owned runtime core phase journalled ancillary files"
[ ! -e "$base/home/.local/bin/pipeasio-settings" ] \
    && [ ! -e "$base/xdg/data/applications/pipeasio-settings.desktop" ] \
    && [ ! -e "$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg" ] \
    || fail "parent-owned runtime core phase changed panel shortcuts"
if grep -q '^OK:' "$base/out"; then
    fail "parent-owned runtime core phase printed a child success line"
fi
ok "parent-owned runtime core phase records only Wine and leaves panel repair to the parent"

base="$(new_env direct-runtime-panel-warning)"
make_runtime_only_kit "$base"
mkdir -p -- "$base/home/.local/bin/pipeasio-settings"
printf 'foreign directory sentinel\n' > "$base/home/.local/bin/pipeasio-settings/sentinel"
run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err" \
    || fail "postcommit panel repair failure invalidated a runtime install"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    || fail "panel repair warning displaced the committed runtime"
grep -qxF 'foreign directory sentinel' "$base/home/.local/bin/pipeasio-settings/sentinel" \
    || fail "panel repair warning corrupted a foreign directory"
grep -qF 'Wine was installed, but the PipeASIO settings shortcut could not be updated.' \
    "$base/err" || fail "postcommit panel repair failure was not a plain warning"
ok "direct runtime panel repair is postcommit and warning-only"

base="$(new_env optional-panel-payload-warning)"
make_runtime_only_kit "$base"
runtime_name=wine-d2d1-nspa-11.13
version=2026.08.12.999
rm -f -- "$base/payload/$runtime_name/share/icons/hicolor/scalable/apps/pipeasio.svg"
tar -C "$base/payload" -I zstd -cf \
    "$base/kit/dist/$runtime_name-$version.tar.zst" "$runtime_name"
(
    cd "$base/kit/dist"
    sha256sum "$runtime_name-$version.tar.zst" > "$runtime_name-$version.tar.zst.sha256"
)
mkdir -p -- "$base/home/.local/bin"
printf 'foreign panel command\n' > "$base/home/.local/bin/pipeasio-settings"
run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err" \
    || fail "incomplete optional panel payload invalidated a core runtime install"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    && [ -f "$base/runtime/lib/wine/x86_64-windows/pipeasio64.dll" ] \
    && [ -f "$base/runtime/lib/wine/x86_64-unix/pipeasio64.dll.so" ] \
    || fail "optional panel warning did not preserve the promoted core runtime and driver"
grep -qxF 'foreign panel command' "$base/home/.local/bin/pipeasio-settings" \
    || fail "invalid optional panel payload changed an existing panel command"
grep -qF 'Wine and PipeASIO passed their checks, but PipeASIO Settings is incomplete.' \
    "$base/err" || fail "invalid optional panel payload did not produce its plain warning"
ok "invalid optional panel payload warns without invalidating Wine or changing panel shortcuts"

base="$(new_env runtime-validator-command-failure)"
make_runtime_only_kit "$base"
cat > "$base/fakebin/readelf" <<'EOF'
#!/bin/sh
cat <<'OUT'
  Shared library: [libusb-1.0.so.0]
  Shared library: [libpipewire-0.3.so.0]
  Shared library: [libgstreamer-1.0.so.0]
OUT
exit 93
EOF
chmod 755 "$base/fakebin/readelf"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err"; then
    fail "runtime install ignored a failed payload validator"
fi
[ ! -e "$base/runtime" ] \
    || fail "failed payload validation promoted a runtime"
grep -qF 'runtime Push bridge dependency validation failed' "$base/err" \
    || fail "failed payload validator was replaced by a later misleading error"
ok "runtime payload validator failures stop before promotion with their original cause"

base="$(new_env runtime-foreign-client-stop)"
make_runtime_only_kit "$base"
mkdir -p -- "$base/runtime/bin"
cp -- /bin/sleep "$base/runtime/bin/wine-client"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
printf 'old runtime generation\n' > "$base/runtime/old-generation"
env WINEPREFIX="$base/foreign-prefix" "$base/runtime/bin/wine-client" 60 &
foreign_runtime_pid=$!
sleep 0.1
runtime_update_succeeded=0
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err"; then
    runtime_update_succeeded=1
fi
kill -0 "$foreign_runtime_pid" 2>/dev/null \
    || fail "runtime refusal killed a foreign-prefix process"
kill "$foreign_runtime_pid" 2>/dev/null || true
wait "$foreign_runtime_pid" 2>/dev/null || true
[ "$runtime_update_succeeded" -eq 0 ] \
    || fail "runtime promotion continued after refusing a foreign-prefix client"
[ -f "$base/runtime/old-generation" ] \
    || fail "foreign-prefix refusal replaced the live runtime anyway"
grep -qF 'runtime is used by another Wine prefix' "$base/err" \
    || fail "foreign-prefix runtime refusal lost its original cause"
ok "runtime-client refusal cannot be ignored by a later promotion"

base="$(new_env runtime-scratch-cleanup-warning)"
make_runtime_only_kit "$base"
real_rm="$(command -v rm)"
cat > "$base/fakebin/rm" <<EOF
#!/bin/sh
for argument do
    case "\$argument" in */.ableton-runtime-stage.*) exit 94 ;; esac
done
exec "$real_rm" "\$@"
EOF
chmod 755 "$base/fakebin/rm"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err" \
    || fail "runtime scratch cleanup failure rolled back a valid installation"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    || fail "scratch cleanup warning displaced the promoted runtime"
grep -qF 'Wine was installed, but temporary files remain at' "$base/err" \
    || fail "retained runtime scratch was not reported"
find "$base" -mindepth 1 -maxdepth 1 -type d -name '.ableton-runtime-stage.*' \
    -print -quit | grep -q . \
    || fail "runtime scratch failure fixture did not retain its target"
ok "post-success scratch cleanup cannot manufacture an installation rollback"

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

prepare_mixed_component_kit()
{
    local base="$1" repo_root
    repo_root="$(cd "$here/.." && pwd)"
    cp -- "$here/ableton-live" "$here/max9" "$here/detect-scale.sh" \
        "$here/detect-theme.sh" "$here/shortcut-hold.sh" \
        "$here/setup-realtime.sh" "$here/audio-report.sh" \
        "$here/check-ntsync.sh" "$here/rollback.sh" "$base/kit/scripts/"
    mkdir -p -- "$base/kit/desktop/icons" \
        "$base/kit/beta/tester-kit/probes/windows"
    cp -- "$repo_root/desktop/ableton-live.desktop.in" \
        "$repo_root/desktop/ableton-linux-protocol.desktop.in" \
        "$repo_root/desktop/ableton-linux-auz.desktop.in" \
        "$repo_root/desktop/x-wine-extension-auz.xml" \
        "$repo_root/desktop/max9.desktop.in" \
        "$repo_root/desktop/wine-protocol-c74max.desktop.in" \
        "$base/kit/desktop/"
    cp -- "$repo_root/desktop/icons/application-ableton-live.xml" \
        "$base/kit/desktop/icons/"
    cp -- "$repo_root/beta/tester-kit/probes/windows/ntsyncprobe.exe" \
        "$base/kit/beta/tester-kit/probes/windows/"
}

# Exercise the EXIT trap itself by injecting an otherwise unhandled command
# failure immediately after the direct runtime's private transaction has been
# retired. The promoted tree is authoritative and no active recovery marker may
# remain for a launcher to mistake for an incomplete core install.
base="$(new_env direct-runtime-core-ready-exit)"
prepare_runtime_metadata_fixture "$base"
sed -i "/        finish_direct_runtime_transaction/a\\
        : > \"$base/core-tail-failure-fired\"\\
        false # injected verified-core tail failure" "$base/kit/scripts/install.sh"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err" \
    || fail "verified-core EXIT catch-all reported the promoted runtime as failed"
[ -e "$base/core-tail-failure-fired" ] \
    || fail "verified-core EXIT fixture did not reach the injected tail failure"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    && [ ! -e "$base/runtime/.ableton-linux-rollback/old-sentinel" ] \
    || fail "verified-core EXIT catch-all restored the previous runtime"
catchall_saved=""
for candidate in "$base"/runtime-rollback-*; do
    [ -d "$candidate" ] || continue
    catchall_saved="$candidate"
    break
done
[ -n "$catchall_saved" ] \
    && grep -qxF 'old metadata generation' \
        "$catchall_saved/.ableton-linux-rollback/old-sentinel" \
    || fail "verified-core EXIT catch-all lost the saved previous runtime"
if find "$base/tmp" "$base/xdg/state/ableton-wine/transactions" \
    -type f -name active -print -quit 2>/dev/null | grep -q .; then
    fail "verified-core EXIT catch-all left a launcher-blocking active transaction"
fi
grep -qF 'Wine is ready. Run the installer again to retry shortcuts or Ableton Link files.' \
    "$base/err" || fail "verified-core EXIT catch-all did not report optional retry"
grep -qxF 'OK: Installation complete.' "$base/out" \
    || fail "verified-core EXIT catch-all omitted the direct success outcome"
ok "the EXIT catch-all cannot fail or roll back a finally validated runtime"

# A direct mixed invocation must close its runtime transaction before generated
# desktop work starts. Inject a failure in the first optional file publication:
# Wine stays live, the previous generation stays available for rollback, and no
# active core marker is left for launchers to reject.
base="$(new_env direct-mixed-optional-failure)"
prepare_runtime_metadata_fixture "$base"
prepare_mixed_component_kit "$base"
foreign_optional="$base/xdg/data/ableton-wine/lib/config.sh"
mkdir -p -- "$(dirname "$foreign_optional")"
printf 'foreign optional config helper\n' > "$foreign_optional"
cp -a -- "$foreign_optional" "$base/foreign-optional.before"
real_install="$(command -v install)"
cat > "$base/fakebin/install" <<EOF
#!/bin/sh
for argument do
    case "\$argument" in
        */.ableton-install.*)
            if [ -f "$base/runtime/.ableton-linux-runtime" ] \
               && [ ! -e "$base/mixed-optional-failure-fired" ]; then
                : > "$base/mixed-optional-failure-fired"
                exit 74
            fi ;;
    esac
done
exec "$real_install" "\$@"
EOF
chmod 755 "$base/fakebin/install"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --integration-only --yes \
    >"$base/out" 2>"$base/err" \
    || fail "optional mixed-mode failure invalidated a committed runtime"
[ -e "$base/mixed-optional-failure-fired" ] \
    || fail "mixed-mode fixture did not reach optional file publication"
cmp -s -- "$base/foreign-optional.before" "$foreign_optional" \
    || fail "failed optional publication changed the existing support file"
cmp -s -- "$base/kit/scripts/lib/lifecycle.sh" \
    "$base/xdg/data/ableton-wine/lib/lifecycle.sh" \
    || fail "one failed support file blocked a later independent repair"
prestate_index="$base/xdg/state/ableton-wine/install-prestate.tsv"
prestate_dir="$base/xdg/state/ableton-wine/install-prestate"
[ ! -e "$prestate_index" ] && [ ! -L "$prestate_index" ] \
    || fail "mixed-mode optional rollback left an unindexed prestate inventory"
if [ -d "$prestate_dir" ] \
   && find "$prestate_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    fail "mixed-mode optional rollback stranded a saved foreign object"
fi
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    && [ ! -e "$base/runtime/.ableton-linux-rollback/old-sentinel" ] \
    || fail "mixed-mode optional failure restored the previous runtime"
mixed_saved=""
for candidate in "$base"/runtime-rollback-*; do
    [ -d "$candidate" ] || continue
    mixed_saved="$candidate"
    break
done
[ -n "$mixed_saved" ] \
    && grep -qxF 'old metadata generation' \
        "$mixed_saved/.ableton-linux-rollback/old-sentinel" \
    || fail "mixed-mode optional failure lost the saved previous runtime"
if find "$base/tmp" "$base/xdg/state/ableton-wine/transactions" \
    -type f -name active -print -quit 2>/dev/null | grep -q .; then
    fail "mixed-mode optional failure left an active core transaction"
fi
run_isolated "$base" env \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ! ableton_install_state_has_active_transaction
    ' _ "$here" || fail "mixed-mode optional failure left the launcher recovery gate closed"
[ "$(grep -cF 'Some shortcuts or support files could not be updated. Run the installer again to retry them.' \
        "$base/err")" -eq 1 ] \
    || fail "mixed-mode optional failure did not produce one plain retry warning"
grep -qxF 'OK: Installation complete.' "$base/out" \
    || fail "mixed-mode optional failure omitted the direct success outcome"
ok "direct mixed mode commits Wine before warning-only generated-file work"

# The public wrapper needs an internal advisory result so its final summary can
# say that desktop repair needs a retry without treating the installed core as
# failed. Direct component use above still exits successfully.
rm -f -- "$base/mixed-optional-failure-fired"
advisory_status=0
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_INTERNAL_OPTIONAL_STATUS=1 \
    bash "$base/kit/scripts/install.sh" --integration-only \
    >"$base/advisory.out" 2>"$base/advisory.err" \
    || advisory_status=$?
[ "$advisory_status" -eq 3 ] \
    || fail "internal desktop repair result did not distinguish a retry warning"
[ -e "$base/mixed-optional-failure-fired" ] \
    || fail "internal desktop repair fixture did not reach its injected warning"
! grep -qF 'OK: Installation complete.' "$base/advisory.out" \
    || fail "internal retry result also printed a complete result"
ok "desktop repair warnings have an internal advisory result for the final summary"

# Each completed generated-file repair is final. Break stderr and fail after
# the first repair; later failure handling must leave that valid repair in
# place and must not strand obsolete recovery data.
base="$(new_env component-recovery-broken-stderr)"
make_runtime_only_kit "$base"
prepare_mixed_component_kit "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
foreign_optional="$base/xdg/data/ableton-wine/lib/config.sh"
mkdir -p -- "$(dirname "$foreign_optional")"
printf 'foreign helper before failed component\n' > "$foreign_optional"
cp -a -- "$foreign_optional" "$base/foreign-helper.before"
sed -i '/ableton_try_publish_file 644 "$here\/lib\/$tool" "$data\/lib\/$tool" file replace-generated/a\
        if [ "$tool" = config.sh ]; then exec 2>/dev/full; false; fi' \
    "$base/kit/scripts/install.sh"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash "$base/kit/scripts/install.sh" --integration-only \
    >"$base/out" 2>"$base/err"; then
    fail "injected component failure unexpectedly reported success"
fi
cmp -s -- "$base/kit/scripts/lib/config.sh" "$foreign_optional" \
    || fail "a later optional failure undid an earlier generated-file repair"
prestate_index="$base/xdg/state/ableton-wine/install-prestate.tsv"
prestate_dir="$base/xdg/state/ableton-wine/install-prestate"
[ ! -e "$prestate_index" ] && [ ! -L "$prestate_index" ] \
    || fail "broken recovery diagnostics left a prestate index behind"
if [ -d "$prestate_dir" ] \
   && find "$prestate_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    fail "broken recovery diagnostics left an unindexed foreign backup"
fi
if find "$base/tmp" -type f -name active -print -quit 2>/dev/null | grep -q .; then
    fail "broken component diagnostics left its private transaction active"
fi
ok "later optional failures retain earlier generated-file repairs even when stderr is broken"

# The coordinator has the same requirement across its runtime and prefix
# domains. Its first rollback message is deliberately sent to /dev/full; both
# child restorations must still run before the trap returns the original error.
base="$(new_env coordinator-recovery-broken-stderr)"
mkdir -p -- "$base/kit/scripts/lib" "$base/kit/bin"
cp -- "$here/installer.sh" "$base/kit/scripts/"
cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" \
    "$here/lib/live-options.sh" "$here/lib/manifest.sh" \
    "$here/lib/pipeasio.sh" "$base/kit/scripts/lib/"
cp -- "$here/../VERSION" "$base/kit/VERSION"
cat > "$base/kit/bin/pipewire-version-probe" <<'EOF'
#!/bin/sh
printf 'client=1.6.8\ndaemon=1.6.8\n'
EOF
cat > "$base/kit/scripts/install.sh" <<'EOF'
#!/bin/sh
set -eu
case " $* " in
    *' --preflight-rollback '*) exit 0 ;;
    *' --rollback '*)
        printf 'old runtime state\n' > "${TEST_RUNTIME_STATE:?}"
        : > "${TEST_RUNTIME_ROLLBACK_CALLED:?}"
        exit 0 ;;
    *' --preflight-commit '*|*' --commit '*) exit 0 ;;
esac
txn=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --transaction-dir ]; then txn="$2"; shift; fi
    shift
done
[ -z "$txn" ] || : > "$txn/active"
printf 'new runtime state\n' > "${TEST_RUNTIME_STATE:?}"
EOF
cat > "$base/kit/scripts/setup-prefix.sh" <<'EOF'
#!/bin/sh
set -eu
case " $* " in
    *' --validate '*) exit 0 ;;
    *' --preflight-rollback '*) exit 0 ;;
    *' --rollback '*)
        printf 'old prefix state\n' > "${TEST_PREFIX_STATE:?}"
        : > "${TEST_PREFIX_ROLLBACK_CALLED:?}"
        exit 0 ;;
    *' --preflight-commit '*|*' --commit '*) exit 0 ;;
esac
printf 'new prefix state\n' > "${TEST_PREFIX_STATE:?}"
exit 71
EOF
chmod 755 "$base/kit/bin/pipewire-version-probe" \
    "$base/kit/scripts/install.sh" "$base/kit/scripts/setup-prefix.sh"
printf 'old runtime state\n' > "$base/runtime.state"
printf 'old prefix state\n' > "$base/prefix.state"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    TEST_RUNTIME_STATE="$base/runtime.state" \
    TEST_PREFIX_STATE="$base/prefix.state" \
    TEST_RUNTIME_ROLLBACK_CALLED="$base/runtime.rollback-called" \
    TEST_PREFIX_ROLLBACK_CALLED="$base/prefix.rollback-called" \
    bash "$base/kit/scripts/installer.sh" install --skip-live-install --yes \
        --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" \
        >"$base/out" 2>/dev/full; then
    fail "coordinator failure fixture unexpectedly reported success"
fi
grep -qxF 'old runtime state' "$base/runtime.state" \
    && grep -qxF 'old prefix state' "$base/prefix.state" \
    && [ -e "$base/runtime.rollback-called" ] \
    && [ -e "$base/prefix.rollback-called" ] \
    || fail "broken coordinator diagnostics skipped runtime or prefix restoration"
ok "coordinator recovery restores every core domain even when stderr is broken"

# Once the Live executable has been found in the selected prefix, every
# terminal message, helper-stop narrative, and timeout explanation is
# presentation only. Break both output streams at that exact boundary and make
# wineserver report a timeout: the coordinator must still commit both core
# domains and must never call either rollback child.
base="$(new_env live-valid-postcore-broken-output)"
mkdir -p -- "$base/kit/scripts/lib" "$base/kit/bin" "$base/runtime/bin"
cp -- "$here/installer.sh" "$base/kit/scripts/"
cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" \
    "$here/lib/live-options.sh" "$here/lib/manifest.sh" \
    "$here/lib/pipeasio.sh" "$base/kit/scripts/lib/"
cp -- "$here/../VERSION" "$base/kit/VERSION"
cat > "$base/kit/bin/pipewire-version-probe" <<'EOF'
#!/bin/sh
printf 'client=1.6.8\ndaemon=1.6.8\n'
EOF
cat > "$base/kit/scripts/install.sh" <<'EOF'
#!/bin/sh
set -eu
case " $* " in
    *' --preflight-rollback '*) exit 0 ;;
    *' --rollback '*) : > "${TEST_RUNTIME_ROLLBACK_CALLED:?}"; exit 0 ;;
    *' --preflight-commit '*) exit 0 ;;
    *' --commit '*) : > "${TEST_RUNTIME_COMMIT_CALLED:?}"; exit 0 ;;
esac
txn=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --transaction-dir ]; then txn="$2"; shift; fi
    shift
done
[ -z "$txn" ] || : > "$txn/active"
exit 0
EOF
cat > "$base/kit/scripts/setup-prefix.sh" <<'EOF'
#!/bin/sh
set -eu
case " $* " in
    *' --validate '*) exit 0 ;;
    *' --preflight-rollback '*) exit 0 ;;
    *' --rollback '*) : > "${TEST_PREFIX_ROLLBACK_CALLED:?}"; exit 0 ;;
    *' --preflight-commit '*) exit 0 ;;
    *' --commit '*) : > "${TEST_PREFIX_COMMIT_CALLED:?}"; exit 0 ;;
esac
mkdir -p -- "${ABLETON_WINEPREFIX:?}"
: > "$ABLETON_WINEPREFIX/system.reg"
exit 0
EOF
cat > "$base/kit/scripts/setup-link.sh" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
case " $* " in
    *' ./Ableton Live 12 Installer.exe '*)
        target="${WINEPREFIX:?}/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe"
        mkdir -p -- "$(dirname "$target")"
        printf 'installed Live fixture\n' > "$target" ;;
esac
exit 0
EOF
cat > "$base/runtime/bin/wineserver" <<'EOF'
#!/bin/sh
[ "${1:-}" != -w ] || exit 124
exit 0
EOF
chmod 755 "$base/kit/bin/pipewire-version-probe" \
    "$base/kit/scripts/install.sh" "$base/kit/scripts/setup-prefix.sh" \
    "$base/kit/scripts/setup-link.sh" "$base/runtime/bin/wine" \
    "$base/runtime/bin/wineserver"
printf 'Inno Setup fixture\n' > "$base/Ableton Live 12 Installer.exe"
sed -i '/live_install_result_valid "$ABLETON_LIVE_VERSION" || return 1/a\
    exec 1>/dev/full 2>/dev/full # injected post-Live output failure' \
    "$base/kit/scripts/installer.sh"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    TEST_RUNTIME_ROLLBACK_CALLED="$base/runtime.rollback-called" \
    TEST_PREFIX_ROLLBACK_CALLED="$base/prefix.rollback-called" \
    TEST_RUNTIME_COMMIT_CALLED="$base/runtime.commit-called" \
    TEST_PREFIX_COMMIT_CALLED="$base/prefix.commit-called" \
    bash "$base/kit/scripts/installer.sh" install --yes --link=off \
        --live-installer "$base/Ableton Live 12 Installer.exe" \
        --runtime-root "$base/runtime" --prefix "$base/prefix" \
        >"$base/out" 2>"$base/err" \
    || fail "closed post-Live output reported a valid core installation as failed"
[ -f "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe" ] \
    || fail "post-Live output fixture did not cross the Live executable postcondition"
[ -e "$base/runtime.commit-called" ] && [ -e "$base/prefix.commit-called" ] \
    || fail "closed post-Live output stopped a core commit"
[ ! -e "$base/runtime.rollback-called" ] && [ ! -e "$base/prefix.rollback-called" ] \
    || fail "closed post-Live output invoked core rollback"
if find "$base/xdg/state/ableton-wine/transactions" -type f -name active \
    -print -quit 2>/dev/null | grep -q .; then
    fail "closed post-Live output left a launcher-blocking core transaction"
fi
ok "valid Live and registry state commit even when every later output fails"

# Direct runtime installation is complete once the promoted tree passes its
# final validation. Failure to publish the old tree under a public rollback
# name may retain that private generation, but must not restore it over Wine.
base="$(new_env direct-runtime-rollback-publication-warning)"
prepare_runtime_metadata_fixture "$base"
real_mv="$(command -v mv)"
cat > "$base/fakebin/mv" <<EOF
#!/bin/sh
last=""
for argument do last="\$argument"; done
case "\$last" in
    */runtime-rollback-path)
        : > "$base/rollback-publication-failed"
        exit 95
        ;;
esac
exec "$real_mv" "\$@"
EOF
chmod 755 "$base/fakebin/mv"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/out" 2>"$base/err" \
    || fail "rollback-name publication failure invalidated a verified runtime"
[ -e "$base/rollback-publication-failed" ] \
    || fail "rollback-name publication failure fixture did not reach its boundary"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    && [ ! -e "$base/runtime/.ableton-linux-rollback/old-sentinel" ] \
    || fail "rollback-name publication warning restored the previous runtime"
private_saved=""
for candidate in "$base"/runtime.transaction-*; do
    [ -d "$candidate" ] || continue
    private_saved="$candidate"
    break
done
[ -n "$private_saved" ] \
    && grep -qxF 'old metadata generation' \
        "$private_saved/.ableton-linux-rollback/old-sentinel" \
    || fail "rollback-name publication warning lost the private previous runtime"
if find "$base" -mindepth 1 -maxdepth 1 -type d -name 'runtime-rollback-*' \
    -print -quit | grep -q .; then
    fail "failed rollback-name publication exposed a partial public candidate"
fi
grep -qF 'Wine is ready, but the installer may not be able to restore the previous Wine version automatically. Temporary recovery files may remain.' \
    "$base/err" || fail "rollback-name publication failure was not a plain warning"
grep -qxF 'OK: Installation complete.' "$base/out" \
    || fail "runtime with a rollback-name warning omitted its simple outcome"
ok "direct runtime rollback publication is warning-only after final validation"

runtime_cleanup_real_rm="$(command -v rm)"
for cleanup_failure in active directory; do
    base="$(new_env "direct-runtime-cleanup-$cleanup_failure")"
    make_runtime_only_kit "$base"
    cat > "$base/fakebin/rm" <<EOF
#!/bin/sh
for argument do
    case "\${ABLETON_TEST_CLEANUP_FAILURE:-}:\$argument" in
        active:*/tmp/ableton-install-plan.*/active) exit 96 ;;
        directory:*/tmp/ableton-install-plan.*) exit 97 ;;
    esac
done
exec "$runtime_cleanup_real_rm" "\$@"
EOF
    chmod 755 "$base/fakebin/rm"
    run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        ABLETON_TEST_CLEANUP_FAILURE="$cleanup_failure" \
        ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
        PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
        bash "$base/kit/scripts/install.sh" --runtime-only --yes \
        >"$base/out" 2>"$base/err" \
        || fail "$cleanup_failure cleanup failure invalidated a verified runtime"
    [ -f "$base/runtime/.ableton-linux-runtime" ] \
        || fail "$cleanup_failure cleanup warning removed the promoted runtime"
    case "$cleanup_failure" in
        active)
            grep -qF 'Wine is ready, but the installer may not be able to restore the previous Wine version automatically. Temporary recovery files may remain.' \
                "$base/err" || fail "runtime active cleanup failure was not a plain warning" ;;
        directory)
            grep -qF 'Wine is ready, but temporary installer data remains at ' \
                "$base/err" || fail "runtime directory cleanup failure was not a plain warning" ;;
    esac
    grep -qxF 'OK: Installation complete.' "$base/out" \
        || fail "runtime $cleanup_failure cleanup warning omitted the simple outcome"
done
ok "direct runtime activity/directory cleanup is warning-only after final validation"

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
[ "$(grep -c '^== Check the Wine package:' "$base/out")" -eq 1 ] \
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
run_runtime_installer_fixture "$base" >"$base/out" 2>"$base/err" \
    || fail "optional rollback snapshot-copy failure invalidated the installed runtime"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    && [ ! -e "$base/runtime/.ableton-linux-rollback/old-sentinel" ] \
    || fail "rollback snapshot-copy warning restored the previous runtime"
grep -qF 'The install is ready, but old recovery files could not be removed.' "$base/err" \
    || fail "rollback snapshot-copy failure was not reported as a cleanup warning"
saved_runtime="$(find_saved_runtime "$base")" \
    || fail "runtime update lost its saved runtime after optional metadata failure"
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
grep -qF 'There is no previous Wine version to restore.' "$base/rollback.err" \
    || fail "incomplete metadata candidate refusal was not explicit"
ok "snapshot-copy warning keeps the new runtime and leaves the old candidate safely unselectable"

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
# Most fixtures need a reachable user manager but do not create a Link service.
# Mutating and reload commands succeed; status checks accurately report that
# the service is neither enabled nor active.
case " $* " in
    *' is-enabled '*|*' is-active '*) exit 1 ;;
esac
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

# A top-level coordinator owns an explicitly supplied transaction directory.
# Component success, commit, and rollback may finish their own domain, but may
# not make unfinished sibling domains look inactive. A standalone invocation,
# on the other hand, must retire the transaction it created for itself.
base="$(new_env component-outer-active-owner)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
outer="$base/coordinator-transaction"
mkdir -p -- "$outer"
run_component_install "$base" "$base/runtime" --integration-only \
    --transaction-dir "$outer" >"$base/install.out" 2>"$base/install.err" \
    || fail "external component transaction could not complete"
[ -f "$outer/active" ] && [ ! -L "$outer/active" ] \
    || fail "external component completion retired the coordinator active marker"
run_component_install "$base" "$base/runtime" --commit "$outer" \
    >"$base/commit.out" 2>"$base/commit.err" \
    || fail "external component transaction could not commit"
[ -f "$outer/active" ] && [ ! -L "$outer/active" ] \
    || fail "component --commit retired the coordinator active marker"
run_component_install "$base" "$base/runtime" --rollback "$outer" \
    >"$base/rollback.out" 2>"$base/rollback.err" \
    || fail "external component transaction could not roll back"
[ -f "$outer/active" ] && [ ! -L "$outer/active" ] \
    || fail "component --rollback retired the coordinator active marker"

base="$(new_env component-own-active-owner)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "standalone component transaction could not complete"
transactions="$base/xdg/state/ableton-wine/transactions"
if [ -d "$transactions" ] \
   && find "$transactions" -mindepth 1 -print -quit | grep -q .; then
    fail "standalone component completion retained its own transaction or active marker"
fi
ok "only the coordinator retires external active markers; standalone components retire their own transaction"

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

user_panel_target="$base/user-retargeted-pipeasio-settings"
rm -f -- "$panel_command"
ln -s -- "$user_panel_target" "$panel_command"
printf '\n# local panel launcher drift\n' >> "$panel_desktop"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-drift.out" 2>"$base/install-drift.err" \
    || { sed -n '1,80p' "$base/install-drift.err" >&2; fail "panel launcher drift aborted integration"; }
[ -L "$panel_command" ] \
    && [ "$(readlink -- "$panel_command")" = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "integration did not replace the retargeted panel command"
[ -L "${panel_command}.bak" ] \
    && [ "$(readlink -- "${panel_command}.bak")" = "$user_panel_target" ] \
    || fail "panel command backup is not the displaced symlink"
! grep -qF '# local panel launcher drift' "$panel_desktop" \
    || fail "integration left drift in the panel desktop entry"
grep -qF '# local panel launcher drift' "${panel_desktop}.bak" \
    || fail "panel desktop backup does not contain the displaced entry"
! grep -qF 'saved checksum differed' "$base/install-drift.out" \
    || fail "ordinary panel repair printed internal checksum details"
for launcher in "$panel_command" "$panel_desktop"; do
    recorded="$(awk -F '\t' -v wanted="$launcher" '$2 == wanted { print $3; exit }' "$manifest")"
    current="$(
        if [ -L "$launcher" ]; then
            { printf 'symlink\0'; readlink -n -- "$launcher"; } | sha256sum | awk '{print $1}'
        else
            sha256sum -- "$launcher" | awk '{print $1}'
        fi
    )"
    [ "$recorded" = "$current" ] \
        || fail "panel launcher manifest digest was not refreshed for $launcher"
done
ok "PipeASIO launcher drift is backed up and replaced"

for durable_tool in audio-report.sh setup-realtime.sh rollback.sh; do
    [ -x "$base/xdg/data/ableton-wine/$durable_tool" ] \
        || fail "integration did not persist executable $durable_tool"
done
grep -qF "Audio report: $base/xdg/data/ableton-wine/audio-report.sh" "$base/install-built.out" \
    || fail "install did not print the durable audio-report path"
grep -qF "Realtime setup: $base/xdg/data/ableton-wine/setup-realtime.sh" "$base/install-built.out" \
    || fail "install did not print the durable realtime-setup path"
grep -qF "Restore previous Wine version: $base/xdg/data/ableton-wine/rollback.sh" "$base/install-built.out" \
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
[ -L "$panel_command" ] && [ "$(readlink -- "$panel_command")" = "$user_panel_target" ] \
    && grep -qF '# local panel launcher drift' "$panel_desktop" \
    && [ ! -e "${panel_command}.bak" ] && [ ! -L "${panel_command}.bak" ] \
    && [ ! -e "${panel_desktop}.bak" ] && [ ! -L "${panel_desktop}.bak" ] \
    && [ ! -e "$panel_icon" ] \
    || fail "skipped panel did not restore and consume displaced foreign launchers"
! manifest_has_path "$manifest" "$panel_command" || fail "skipped panel retained command ownership"

# Put the runtime payload back before restoring its host projections. Runtime
# payload changes belong to the runtime transaction, not this integration one.
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" built
run_component_install "$base" "$base/runtime" --rollback "$txn" \
    >"$base/rollback.out" 2>"$base/rollback.err" \
    || fail "panel integration rollback failed"
[ -L "$panel_command" ] && [ "$(readlink -- "$panel_command")" = "$base/runtime/bin/pipeasio-settings" ] \
    && [ -f "$panel_desktop" ] && [ -f "$panel_icon" ] \
    && [ -L "${panel_command}.bak" ] \
    && [ "$(readlink -- "${panel_command}.bak")" = "$user_panel_target" ] \
    && grep -qF '# local panel launcher drift' "${panel_desktop}.bak" \
    || fail "rollback did not restore panel host projections"
! manifest_has_path "$manifest" "$panel_command" \
    || fail "component rollback rewound disposable installed-file inventory"
ok "panel files participate in component rollback without rewinding uninstall inventory"

write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install-skipped.out" 2>"$base/install-skipped.err" \
    || fail "committed built-to-skipped transition failed"
[ ! -e "$panel_command" ] && [ ! -L "$panel_command" ] \
    && [ ! -e "$panel_desktop" ] && [ -f "$panel_icon" ] \
    || fail "committed skipped panel did not remove recognised launchers and preserve its unverified icon"
grep -qF "preserved your existing $panel_icon" "$base/install-skipped.out" \
    || fail "unverified panel icon preservation was not reported"
! manifest_has_path "$manifest" "$panel_command" || fail "built-to-skipped transition left stale command ownership"
! manifest_has_path "$manifest" "$panel_desktop" || fail "built-to-skipped transition left stale desktop ownership"
! manifest_has_path "$manifest" "$panel_icon" || fail "built-to-skipped transition left stale icon ownership"
ok "built-to-skipped transition removes recognised launchers and preserves an unverified icon"

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

# A runtime-only installation replaces existing PipeASIO command and desktop
# launchers. Ownership records preserve each prior object for uninstall.
base="$(new_env foreign-panel-runtime-only)"
make_runtime_only_kit "$base"
install_fake_host_tools "$base"
runtime_command="$base/home/.local/bin/pipeasio-settings"
runtime_desktop="$base/xdg/data/applications/pipeasio-settings.desktop"
mkdir -p -- "$(dirname "$runtime_command")" "$(dirname "$runtime_desktop")"
printf '#!/bin/sh\necho runtime-only-foreign-command\n' > "$runtime_command"
chmod 755 "$runtime_command"
printf '[Desktop Entry]\nName=Runtime-only foreign panel\n' > "$runtime_desktop"
cp -- "$runtime_command" "$base/foreign-command.before"
cp -- "$runtime_desktop" "$base/foreign-desktop.before"
if ! run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --yes \
    >"$base/install.out" 2>"$base/install.err"; then
    sed -n '1,120p' "$base/install.err" >&2
    fail "runtime-only installation failed for foreign panel launchers"
fi
[ -L "$runtime_command" ] \
    && [ "$(readlink -- "$runtime_command")" = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "runtime-only installation wrote the wrong panel command"
cmp -s -- "$base/foreign-command.before" "${runtime_command}.bak" \
    || fail "runtime-only installation saved the wrong panel command backup"
grep -qxF 'Name=PipeASIO Settings' "$runtime_desktop" \
    || fail "runtime-only installation wrote the wrong panel entry"
cmp -s -- "$base/foreign-desktop.before" "${runtime_desktop}.bak" \
    || fail "runtime-only installation saved the wrong panel entry backup"
runtime_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
manifest_has_path "$runtime_manifest" "$runtime_command" \
    || fail "runtime-only installation omitted panel command ownership"
manifest_has_path "$runtime_manifest" "$runtime_desktop" \
    || fail "runtime-only installation omitted panel entry ownership"
manifest_has_path "$runtime_manifest" "${runtime_command}.bak" \
    || fail "runtime-only installation omitted panel command backup ownership"
manifest_has_path "$runtime_manifest" "${runtime_desktop}.bak" \
    || fail "runtime-only installation omitted panel entry backup ownership"
run_isolated "$base" env \
    PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes \
    >"$base/uninstall.out" 2>"$base/uninstall.err" \
    || { sed -n '1,120p' "$base/uninstall.err" >&2; fail "uninstall failed after runtime-only launcher replacement"; }
cmp -s -- "$base/foreign-command.before" "$runtime_command" \
    || fail "uninstall restored the wrong foreign panel command"
cmp -s -- "$base/foreign-desktop.before" "$runtime_desktop" \
    || fail "uninstall restored the wrong foreign panel entry"
[ ! -e "${runtime_command}.bak" ] && [ ! -L "${runtime_command}.bak" ] \
    || fail "uninstall retained the runtime-only panel command backup"
[ ! -e "${runtime_desktop}.bak" ] && [ ! -L "${runtime_desktop}.bak" ] \
    || fail "uninstall retained the runtime-only panel entry backup"
ok "runtime-only launcher replacement records ownership for uninstall"

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
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "foreign panel command prevented otherwise safe integration"
[ -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ "$(readlink -- "$base/home/.local/bin/pipeasio-settings")" = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "foreign pipeasio-settings command was not replaced"
grep -qxF 'echo foreign-settings-command' "$base/home/.local/bin/pipeasio-settings.bak" \
    || fail "foreign panel command was not saved as pipeasio-settings.bak"
foreign_manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
manifest_has_path "$foreign_manifest" "$base/home/.local/bin/pipeasio-settings" \
    || fail "installed pipeasio-settings command was not claimed in the manifest"
foreign_id="$(printf '%s' "$base/home/.local/bin/pipeasio-settings" | sha256sum | awk '{print $1}')"
[ ! -e "$base/xdg/state/ableton-wine/install-prestate/$foreign_id" ] \
    && { [ ! -r "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
         || ! awk -F '\t' -v p="$base/home/.local/bin/pipeasio-settings" \
                '$2==p { found=1 } END { exit !found }' \
                "$base/xdg/state/ableton-wine/install-prestate.tsv"; } \
    || fail "fresh panel repair duplicated its adjacent backup in legacy prestate"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/skipped.out" 2>"$base/skipped.err" \
    || fail "skipped-panel update failed while restoring the displaced command"
[ ! -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ "$(sha256sum -- "$base/home/.local/bin/pipeasio-settings" | awk '{print $1}')" = "$foreign_digest" ] \
    || fail "skipped-panel transition did not restore the displaced command"
! manifest_has_path "$foreign_manifest" "$base/home/.local/bin/pipeasio-settings" \
    || fail "restored panel command remained claimed in the manifest"
! manifest_has_path "$foreign_manifest" "$base/home/.local/bin/pipeasio-settings.bak" \
    || fail "consumed adjacent panel backup remained claimed in the manifest"
[ ! -e "$base/home/.local/bin/pipeasio-settings.bak" ] \
    && [ ! -L "$base/home/.local/bin/pipeasio-settings.bak" ] \
    || fail "skipped-panel transition retained its consumed adjacent backup"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/retry.out" 2>"$base/retry.err" \
    || fail "repeated skipped-panel repair rejected the already-restored command"
[ ! -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ "$(sha256sum -- "$base/home/.local/bin/pipeasio-settings" | awk '{print $1}')" = "$foreign_digest" ] \
    && [ ! -e "$base/home/.local/bin/pipeasio-settings.bak" ] \
    || fail "repeated skipped-panel repair changed the restored foreign command"
ok "foreign pipeasio-settings command is backed up, restored once, and remains stable on retry"

base="$(new_env modified-panel-command-with-backup)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
panel_command="$base/home/.local/bin/pipeasio-settings"
mkdir -p -- "$(dirname "$panel_command")"
printf 'foreign panel bytes\n' > "$panel_command"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "modified-panel fixture could not install its managed projection"
rm -f -- "$panel_command"
printf 'user modified panel bytes\n' > "$panel_command"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/skipped.out" 2>"$base/skipped.err" \
    || fail "modified panel command made skipped-panel repair fatal"
grep -qxF 'user modified panel bytes' "$panel_command" \
    && grep -qxF 'foreign panel bytes' "$panel_command.bak" \
    || fail "skipped-panel repair changed a modified command or its saved foreign copy"
[ "$(grep -cF "Kept both $panel_command and $panel_command.bak because the current shortcut was changed." \
        "$base/skipped.err")" -eq 1 ] \
    || fail "modified command and saved copy did not produce exactly one plain warning"
ok "skipped-panel repair preserves a modified command and its saved foreign copy with one warning"

base="$(new_env panel-command-missing-backup)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
panel_command="$base/home/.local/bin/pipeasio-settings"
mkdir -p -- "$(dirname "$panel_command")"
printf 'foreign panel bytes\n' > "$panel_command"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "missing-backup fixture could not install its managed projection"
rm -f -- "$panel_command.bak"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/skipped.out" 2>"$base/skipped.err" \
    || fail "missing saved panel command made skipped-panel repair fatal"
[ -L "$panel_command" ] \
    && [ "$(readlink -- "$panel_command")" = "$base/runtime/bin/pipeasio-settings" ] \
    && [ ! -e "$panel_command.bak" ] && [ ! -L "$panel_command.bak" ] \
    || fail "skipped-panel repair changed the live command after its saved copy disappeared"
[ "$(grep -cF "Kept $panel_command because its saved earlier shortcut is missing." \
        "$base/skipped.err")" -eq 1 ] \
    || fail "missing saved panel command did not produce one accurate warning"
if manifest_has_path "$base/xdg/state/ableton-wine/install-manifest.tsv" "$panel_command" \
   || manifest_has_path "$base/xdg/state/ableton-wine/install-manifest.tsv" "$panel_command.bak"; then
    fail "missing saved panel command left an unsafe adjacent ownership claim"
fi
ok "skipped-panel repair keeps the live command and accurately reports a missing saved copy"

base="$(new_env panel-adjacent-stale-prestate)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
panel_command="$base/home/.local/bin/pipeasio-settings"
mkdir -p -- "$(dirname "$panel_command")"
printf 'foreign panel bytes\n' > "$panel_command"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "stale-prestate fixture could not install its managed projection"
cp -a -- "$panel_command" "$base/current.before"
cp -a -- "$panel_command.bak" "$base/saved.before"
printf 'present\t%s\t/tmp/untrusted-panel-backup\n' "$base/unrelated-path" \
    > "$base/xdg/state/ableton-wine/install-prestate.tsv"
if ! run_isolated "$base" env \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        . "$1/lib/pipeasio.sh"
        rc=0
        ableton_pipeasio_restore_adjacent_backup "$2" || rc=$?
        [ "$rc" -eq 2 ]
    ' _ "$here" "$panel_command"; then
    fail "adjacent panel recovery trusted a pair while legacy prestate was unverifiable"
fi
cmp -s -- "$base/current.before" "$panel_command" \
    && cmp -s -- "$base/saved.before" "$panel_command.bak" \
    && grep -qxF $'present\t'"$base/unrelated-path"$'\t/tmp/untrusted-panel-backup' \
        "$base/xdg/state/ableton-wine/install-prestate.tsv" \
    || fail "refusing ambiguous adjacent recovery changed live or legacy recovery data"
ok "adjacent panel recovery defers when any legacy prestate inventory is unverifiable"

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

install_managed_file()
{
    local base="$1" source="$2" target="$3" txn="$4"
    mkdir -p -- "$txn"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_init
        ableton_install_file 755 "$2" "$3"
        ableton_write_ownership_manifest
        rm -f -- "$ABLETON_TRANSACTION_DIR/active"
    ' _ "$here" "$source" "$target"
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

base="$(new_env relative-symlink-prestate)"
managed_link="$base/home/.local/bin/pipeasio-settings"
mkdir -p -- "$(dirname "$managed_link")"
printf '#!/bin/sh\necho original\n' > "$(dirname "$managed_link")/original-foreign-command"
chmod 755 "$(dirname "$managed_link")/original-foreign-command"
ln -s -- original-foreign-command "$managed_link"
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
    && [ -e "$managed_link" ] \
    && [ "$(readlink -- "$managed_link")" = original-foreign-command ] \
    || fail "uninstall did not restore the original relative foreign symlink"
ok "two managed symlink updates retain and restore relative foreign prestate"

base="$(new_env regular-file-prestate)"
managed_file="$base/home/.local/bin/pipeasio-settings"
mkdir -p -- "$(dirname "$managed_file")"
printf '#!/bin/sh\necho original-foreign-file\n' > "$managed_file"
printf '#!/bin/sh\necho managed-v1\n' > "$base/managed-file-v1"
printf '#!/bin/sh\necho managed-v2\n' > "$base/managed-file-v2"
chmod 755 "$managed_file" "$base/managed-file-v1" "$base/managed-file-v2"
cp -a -- "$managed_file" "$base/original-foreign-file.before"
install_managed_file "$base" "$base/managed-file-v1" "$managed_file" "$base/file-txn-v1" \
    || fail "first managed regular-file update failed"
cmp -s -- "$base/managed-file-v1" "$managed_file" \
    || fail "first managed regular-file update did not take effect"
install_managed_file "$base" "$base/managed-file-v2" "$managed_file" "$base/file-txn-v2" \
    || fail "second managed regular-file update failed"
cmp -s -- "$base/managed-file-v2" "$managed_file" \
    || fail "second managed regular-file update did not take effect"
run_minimal_uninstall "$base" >"$base/uninstall.out" 2>"$base/uninstall.err" \
    || fail "uninstall failed while restoring regular-file prestate"
cmp -s -- "$base/original-foreign-file.before" "$managed_file" \
    || fail "uninstall did not restore the original foreign regular file"
ok "two managed regular-file updates retain and restore foreign prestate"

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
grep -qF "kept a link at $managed_link because it was changed or points somewhere else" "$base/uninstall.err" \
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
grep -qF 'removed a PipeASIO Settings file from an older release:' "$base/out" \
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
grep -qF "kept an independently installed PipeASIO panel file at $base/home/.local/bin/pipeasio-settings" \
    "$base/err" || fail "foreign legacy panel symlink preservation was not reported"
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
grep -qF 'The Wine runtime was not deleted because the installer could not confirm that it created it:' "$base/err" \
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

base="$(new_env launcher-backup-target-exit)"
launcher_backup="$base/xdg/data/applications/max9.desktop.bak"
transaction_target_authorised_on_exit "$base" "$launcher_backup" \
    || fail "exact adjacent launcher backup was refused during failure recovery"
if transaction_target_authorised_on_exit \
    "$base" "$base/xdg/data/applications/not-a-launcher.desktop.bak"; then
    fail "arbitrary adjacent backup target was authorised during failure recovery"
fi
if transaction_target_authorised_on_exit "$base" "${launcher_backup}.bak"; then
    fail "nested launcher backup target was authorised during failure recovery"
fi
ok "failure recovery authorises only exact adjacent launcher backup names"

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

base="$(new_env rollback-stale-host-probe)"
make_rollback_fixture "$base"
mkdir -p -- "$base/xdg/data/ableton-wine"
cat > "$base/xdg/data/ableton-wine/pipewire-version-probe" <<'EOF'
#!/bin/sh
echo 'stale generated host probe must not run' >&2
exit 99
EOF
chmod 755 "$base/xdg/data/ableton-wine/pipewire-version-probe"
run_user_rollback "$base" env ABLETON_TEST_REGISTRY_STICKY=0 \
    >"$base/out" 2>"$base/err" \
    || fail "stale generated host probe rejected valid current and restored runtimes"
[ -f "$base/runtime/previous-generation" ] \
    || fail "stale generated host probe prevented runtime rollback"
! grep -qF 'stale generated host probe must not run' "$base/err" \
    || fail "rollback executed the stale generated host probe"
ok "rollback uses each sealed runtime probe instead of stale generated host copies"

base="$(new_env rollback-postcore-output)"
make_rollback_fixture "$base"
cat > "$base/postcore-failure.bash" <<'EOF'
echo()
{
    if [ "$*" = '== Restore saved settings ==' ]; then
        return 74
    fi
    builtin echo "$@"
}
EOF
run_user_rollback "$base" env BASH_ENV="$base/postcore-failure.bash" \
    ABLETON_TEST_REGISTRY_STICKY=0 >"$base/out" 2>"$base/err" \
    || fail "post-core output failure reported a committed rollback as failed"
[ -f "$base/runtime/previous-generation" ] \
    || fail "post-core output failure reversed a committed runtime rollback"
grep -qxF 'live_major=11' "$ROLLBACK_INSTALLER_CONFIG" \
    && grep -qxF 'buffer_size = 883' "$ROLLBACK_PIPEASIO_CONFIG" \
    || fail "post-core output failure stopped recorded settings restoration"
[ -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ "$(readlink -- "$base/home/.local/bin/pipeasio-settings")" \
        = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "post-core output failure stopped panel repair"
if find "$base/xdg/state/ableton-wine/transactions" -type f -name active \
    -print -quit 2>/dev/null | grep -q .; then
    fail "post-core output failure stopped rollback cleanup"
fi
ok "runtime rollback continues optional repair and cleanup after output fails"

# The runtime swap has no host-file mutations to put in manifest.sh's file
# journal. Neither that empty journal nor a failed progress write may become a
# prerequisite for restoring the previous Wine version.
base="$(new_env rollback-no-empty-file-journal)"
make_rollback_fixture "$base"
real_mkdir="$(command -v mkdir)"
cat > "$base/fakebin/mkdir" <<EOF
#!/bin/bash
for argument do
    case "\$argument" in
        */transactions/rollback.*/files)
            : > "\${ABLETON_TEST_EMPTY_JOURNAL_ATTEMPT:?}"
            exit 79
            ;;
    esac
done
exec "$real_mkdir" "\$@"
EOF
chmod 755 "$base/fakebin/mkdir"
cat > "$base/precore-output-failure.bash" <<'EOF'
echo()
{
    if [ "$*" = '== Restore the previous Wine version ==' ]; then
        return 74
    fi
    builtin echo "$@"
}
EOF
run_user_rollback "$base" env BASH_ENV="$base/precore-output-failure.bash" \
    ABLETON_TEST_EMPTY_JOURNAL_ATTEMPT="$base/empty-journal-attempt" \
    ABLETON_TEST_REGISTRY_STICKY=0 >"$base/out" 2>"$base/err" \
    || fail "progress output or an unused file journal blocked runtime restore"
[ -f "$base/runtime/previous-generation" ] \
    || fail "progress output failure prevented the runtime swap"
[ ! -e "$base/empty-journal-attempt" ] \
    || fail "runtime restore initialized an unused host-file journal"
if find "$base/xdg/state/ableton-wine/transactions" -type f \
    \( -name active -o -name files.tsv \) -print -quit 2>/dev/null | grep -q .; then
    fail "runtime restore left an empty host-file transaction"
fi
ok "runtime restore has no empty file-journal or progress-output gate"

# Persistent recovery metadata is optional to the runtime/registry operation.
# If its state directory cannot be created, rollback uses private scratch and
# still completes the validated swap.
base="$(new_env rollback-state-scratch-unavailable)"
make_rollback_fixture "$base"
real_mkdir="$(command -v mkdir)"
real_mktemp="$(command -v mktemp)"
cat > "$base/fakebin/mkdir" <<EOF
#!/bin/bash
for argument do
    if [ "\$argument" = "\${XDG_STATE_HOME:?}/ableton-wine/transactions" ]; then
        : > "\${ABLETON_TEST_STATE_SCRATCH_REFUSED:?}"
        exit 80
    fi
done
exec "$real_mkdir" "\$@"
EOF
cat > "$base/fakebin/mktemp" <<EOF
#!/bin/bash
for argument do
    case "\$argument" in
        */ableton-runtime-restore.XXXXXX)
            : > "\${ABLETON_TEST_TEMP_SCRATCH_USED:?}"
            ;;
    esac
done
exec "$real_mktemp" "\$@"
EOF
chmod 755 "$base/fakebin/mkdir" "$base/fakebin/mktemp"
run_user_rollback "$base" env \
    ABLETON_TEST_STATE_SCRATCH_REFUSED="$base/state-scratch-refused" \
    ABLETON_TEST_TEMP_SCRATCH_USED="$base/temp-scratch-used" \
    ABLETON_TEST_REGISTRY_STICKY=0 >"$base/out" 2>"$base/err" \
    || fail "unavailable persistent recovery scratch blocked runtime restore"
[ -e "$base/state-scratch-refused" ] && [ -e "$base/temp-scratch-used" ] \
    || fail "unavailable persistent recovery scratch did not exercise the temporary fallback"
[ -f "$base/runtime/previous-generation" ] \
    || fail "unavailable persistent recovery scratch prevented the runtime swap"
ok "persistent failure-record scratch is not a runtime restore gate"

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
grep -Eq 'Close Live, Max|Close the listed program using this Wine runtime' "$base/err" \
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
probe_hash="$(sha256sum -- "$base/runtime/bin/pipewire-version-probe" | awk '{print $1}')"
sed -i "s/^pipewire-version-probe: .*/pipewire-version-probe: $probe_hash/" \
    "$base/runtime/ABLETON-WINE-BUILD-INFO.txt"
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
grep -Eq 'Close Live, Max|Close the listed program using this Wine runtime' "$base/err" \
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
! grep -qF 'rerun the installer to finish optional setup' "$base/rollback.err" \
    || fail "successful rollback printed a false optional-setup warning"
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
failed_txn="$(dirname "$failed_record")"
[ ! -e "$failed_txn/files.tsv" ] && [ ! -e "$failed_txn/active" ] \
    || fail "pre-commit registration failure created an empty host-file transaction"
grep -qxF 'runtime_restored=yes' "$failed_record" \
    || fail "failed original registration obscured the restored runtime layout"
if ! grep -qxF 'restoration_complete=no' "$failed_record"; then
    cat "$failed_record" >&2
    sed -n '1,120p' "$base/failed-rollback.err" >&2
    fail "failed original registration was not recorded as incomplete restoration"
fi
grep -qF 'The previous Wine version could not be restored automatically: original PipeASIO registration could not be restored' \
    "$base/failed-rollback.err" \
    || fail "failed original registration was not reported as incomplete restoration"
! grep -qF 'Wine version from before this attempt is back in place' "$base/failed-rollback.err" \
    || fail "failed original registration printed a false restored claim"
ok "post-swap failure restores the runtime layout and records failed re-registration"

# Change optional installer settings during the final desktop refresh, after
# the runtime swap and PipeASIO registration have committed. The concurrent
# settings generation must be preserved and must not turn a valid runtime
# rollback into a failure or start a second restoration pass.
base="$(new_env rollback-post-core-config-drift)"
make_rollback_fixture "$base"
cp -- "$ROLLBACK_INSTALLER_CONFIG" "$base/installer-config.before"
cp -- "$ROLLBACK_PIPEASIO_CONFIG" "$base/pipeasio-config.before"
printf '0\n' > "$base/update-desktop-count"
cat > "$base/fakebin/update-desktop-database" <<'EOF'
#!/bin/bash
set -euo pipefail
count="$(cat "${ABLETON_TEST_UPDATE_COUNT:?}")"
count=$((count + 1))
printf '%s\n' "$count" > "$ABLETON_TEST_UPDATE_COUNT"
if [ "$count" -ge 2 ] && [ ! -e "${ABLETON_TEST_COMMIT_DRIFT_FIRED:?}" ]; then
    cp -- "${ABLETON_TEST_COMMIT_DRIFT_SOURCE:?}" \
        "${ABLETON_TEST_COMMIT_DRIFT_TARGET:?}"
    : > "$ABLETON_TEST_COMMIT_DRIFT_FIRED"
fi
exit 0
EOF
chmod 755 "$base/fakebin/update-desktop-database"
run_user_rollback "$base" env \
    ABLETON_TEST_REGISTRY_STICKY=0 \
    ABLETON_TEST_UPDATE_COUNT="$base/update-desktop-count" \
    ABLETON_TEST_COMMIT_DRIFT_FIRED="$base/commit-drift-fired" \
    ABLETON_TEST_COMMIT_DRIFT_SOURCE="$base/installer-config.before" \
    ABLETON_TEST_COMMIT_DRIFT_TARGET="$ROLLBACK_INSTALLER_CONFIG" \
    >"$base/out" 2>"$base/err" \
    || fail "post-core installer-settings drift invalidated a restored runtime"
[ -e "$base/commit-drift-fired" ] \
    || fail "post-core installer-settings drift fixture did not mutate its destination"
[ -f "$base/runtime/previous-generation" ] \
    && [ ! -e "$ROLLBACK_SAVED" ] && [ ! -L "$ROLLBACK_SAVED" ] \
    && [ -e "$base/registry-present" ] \
    && cmp -s -- "$ROLLBACK_INSTALLER_CONFIG" "$base/installer-config.before" \
    && grep -qF 'buffer_size = 883' "$ROLLBACK_PIPEASIO_CONFIG" \
    || fail "post-core installer-settings drift reversed Wine or changed the concurrent settings generation"
! find "$base/xdg/state/ableton-wine/transactions" -mindepth 2 \
    -maxdepth 2 -type f -name FAILURE -print -quit | grep -q . \
    || fail "post-core installer-settings drift invented a rollback failure"
! find "$base/xdg/state/ableton-wine/transactions" -mindepth 2 \
    -maxdepth 2 -type f -name active -print -quit | grep -q . \
    || fail "post-core installer-settings drift retained an active rollback"
grep -qxF 'OK: The previous Wine version is restored.' "$base/out" \
    || fail "post-core installer-settings drift hid the restored runtime outcome"
ok "post-core installer-settings drift is preserved without invalidating the restored runtime"

# Once the runtime swap and PipeASIO registration have committed, cleanup
# errors are not rollback errors.
# Fail each cleanup boundary independently: the restored runtime/configuration
# must stay committed and the command must remain successful. The retained
# transaction preserves the cleanup evidence; no extra failure record or
# restoration pass should be invented after the core result commits.
real_rm="$(command -v rm)"
for cleanup_failure in directory; do
    base="$(new_env "rollback-committed-cleanup-$cleanup_failure")"
    make_rollback_fixture "$base"
    cat > "$base/fakebin/rm" <<EOF
#!/bin/bash
set -euo pipefail
transaction_root="\${XDG_STATE_HOME:?}/ableton-wine/transactions"
for argument do
    if [ "\${ABLETON_TEST_CLEANUP_FAILURE:?}" = directory ]; then
        case "\$argument" in
            "\$transaction_root"/rollback.*)
                if [ "\${argument%/*}" = "\$transaction_root" ]; then
                    printf 'directory\n' > "\${ABLETON_TEST_CLEANUP_ATTEMPT:?}"
                    exit 89
                fi
                ;;
        esac
    fi
done
exec "$real_rm" "\$@"
EOF
    chmod 755 "$base/fakebin/rm"
    run_user_rollback "$base" env \
        ABLETON_TEST_REGISTRY_STICKY=0 \
        ABLETON_TEST_CLEANUP_FAILURE="$cleanup_failure" \
        ABLETON_TEST_CLEANUP_ATTEMPT="$base/cleanup-attempt" \
        >"$base/out" 2>"$base/err" \
        || fail "committed $cleanup_failure cleanup failure invalidated the restored runtime"
    grep -qxF "$cleanup_failure" "$base/cleanup-attempt" \
        || fail "committed $cleanup_failure cleanup fixture did not reach its boundary"
    cleanup_txn="$(find "$base/xdg/state/ableton-wine/transactions" -mindepth 1 \
        -maxdepth 1 -type d -name 'rollback.*' -print | head -n 1)"
    [ -n "$cleanup_txn" ] \
        || fail "committed $cleanup_failure cleanup did not retain its recovery directory"
    [ ! -e "$cleanup_txn/COMMITTED_CLEANUP_FAILURE" ] \
        || fail "committed $cleanup_failure cleanup invented a failure record"
    [ ! -e "$cleanup_txn/active" ] && [ ! -e "$cleanup_txn/files.tsv" ] \
        || fail "cleanup-only directory contains an unused host-file transaction"
    [ ! -e "$cleanup_txn/FAILURE" ] \
        || fail "committed $cleanup_failure cleanup incorrectly entered restoration recovery"
    [ -f "$base/runtime/previous-generation" ] \
        && [ ! -e "$ROLLBACK_SAVED" ] && [ ! -L "$ROLLBACK_SAVED" ] \
        && grep -qF 'live_major=11' "$ROLLBACK_INSTALLER_CONFIG" \
        && grep -qF 'buffer_size = 883' "$ROLLBACK_PIPEASIO_CONFIG" \
        || fail "committed $cleanup_failure cleanup failure reversed successful state"
    grep -qF "The previous Wine version is restored, but temporary files remain at $cleanup_txn." "$base/err" \
        || fail "committed $cleanup_failure cleanup was not reported as cleanup-only"
    ! grep -Eq 'could not be restored automatically|Wine version from before this attempt is back in place' "$base/err" \
        || fail "committed $cleanup_failure cleanup printed a restoration claim"
done
ok "postcommit recovery-directory cleanup failures preserve committed state and never claim restoration"

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
run_minimal_uninstall "$base" >"$base/out" 2>"$base/err" \
    || fail "a missing optional pre-install backup made uninstall fail"
[ -L "$managed_link" ] && [ "$(readlink -- "$managed_link")" = "$base/managed-panel" ] \
    || fail "missing optional prestate did not preserve the managed target"
[ -r "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ -r "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "missing optional prestate discarded the records needed for inspection"
grep -qF "Desktop shortcuts, file-opening settings, and older Wine runtimes were left unchanged because the installer's file list could not be trusted" \
    "$base/err" || fail "missing optional prestate warning was not explicit"
ok "missing optional prestate preserves integration records without failing uninstall"

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
    local base="$1" txn="$2" target="$3" policy="${4:-preserve-local}"
    mkdir -p -- "$txn"
    mkdir -p -- "$txn"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_init
        ableton_install_file 600 "$2" "$3" file "$4"
    ' _ "$here" "$base/replacement" "$target" "$policy"
}

for journal in manifest prestate; do
    for corrupt_kind in symlink unreadable malformed nul; do
        base="$(new_env "install-$journal-$corrupt_kind")"
        state="$base/xdg/state/ableton-wine"
        txn="$base/txn"
        target="$base/xdg/data/ableton-wine/setup-realtime.sh"
        mkdir -p -- "$state" "$(dirname "$target")"
        printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
        printf 'foreign live bytes\n' > "$target"
        printf 'replacement bytes\n' > "$base/replacement"
        printf 'external journal bytes\n' > "$base/external-journal"
        if [ "$journal" = prestate ]; then
            printf 'file\t%s\t%s\n' "$target" \
                "$(sha256sum -- "$target" | awk '{print $1}')" \
                > "$state/install-manifest.tsv"
        fi
        path="$state/install-$journal.tsv"
        case "$corrupt_kind" in
            symlink) ln -s -- "$base/external-journal" "$path" ;;
            unreadable) printf 'unreadable journal\n' > "$path"; chmod 000 "$path" ;;
            malformed) printf 'not-a-valid-record\n' > "$path" ;;
            nul) printf '\0' > "$path" ;;
        esac
        run_guarded_file_install "$base" "$txn" "$target" \
            >"$base/out" 2>"$base/err" \
            || { chmod 600 "$path" 2>/dev/null || true; \
                 fail "repair install consulted a $corrupt_kind legacy $journal journal"; }
        chmod 600 "$path" 2>/dev/null || true
        grep -qxF 'replacement bytes' "$target" \
            || fail "$corrupt_kind legacy $journal journal blocked canonical repair"
        grep -qxF 'external journal bytes' "$base/external-journal" \
            || fail "$corrupt_kind legacy $journal journal changed a symlink referent"
    done
done
ok "repair installs ignore malformed legacy inventory and prestate without touching external data"

# Both optional bookkeeping files can be damaged at once. Files published from
# the current installer payload are still authoritative; their immediate
# transaction copy is sufficient to restore this attempt if a later step fails.
base="$(new_env generated-repair-both-journals-damaged)"
state="$base/xdg/state/ableton-wine"
txn="$base/txn"
target="$base/xdg/data/ableton-wine/setup-realtime.sh"
mkdir -p -- "$state/install-prestate" "$(dirname "$target")"
printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
printf 'older generated bytes\n' > "$target"
printf 'replacement bytes\n' > "$base/replacement"
printf 'not-a-valid-installed-file-list\n' > "$state/install-manifest.tsv"
printf 'not-a-valid-saved-copy-list\n' > "$state/install-prestate.tsv"
printf 'stale saved-copy sentinel\n' > "$state/install-prestate/not-a-valid-slot"
cp -a -- "$state/install-manifest.tsv" "$base/manifest.before"
cp -a -- "$state/install-prestate.tsv" "$base/prestate.before"
run_guarded_file_install "$base" "$txn" "$target" replace-generated \
    >"$base/out" 2>"$base/err" \
    || fail "damaged optional bookkeeping blocked generated-file repair"
grep -qxF 'replacement bytes' "$target" \
    || fail "generated-file repair retained its old bytes"
cmp -s -- "$state/install-manifest.tsv" "$base/manifest.before" \
    && cmp -s -- "$state/install-prestate.tsv" "$base/prestate.before" \
    && grep -qxF 'stale saved-copy sentinel' \
        "$state/install-prestate/not-a-valid-slot" \
    || fail "generated-file repair consumed damaged optional bookkeeping"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_rollback_files "$2"
' _ "$here" "$txn" \
    || fail "generated-file repair lost same-run rollback"
grep -qxF 'older generated bytes' "$target" \
    || fail "same-run rollback did not restore the replaced generated file"
ok "generated files ignore damaged optional bookkeeping and keep same-run rollback"

# The authoritative overwrite policy is deliberately narrow. Shared desktop
# names still preserve unrelated local files and cannot opt into private-file
# replacement through a future call-site mistake.
base="$(new_env replace-generated-shared-path)"
target="$base/xdg/data/icons/hicolor/scalable/apps/live-suite.svg"
mkdir -p -- "$(dirname "$target")"
printf 'foreign shared icon\n' > "$target"
printf 'replacement bytes\n' > "$base/replacement"
if run_guarded_file_install "$base" "$base/txn" "$target" replace-generated \
    >"$base/out" 2>"$base/err"; then
    fail "private-file overwrite policy accepted a shared desktop path"
fi
grep -qxF 'foreign shared icon' "$target" \
    || fail "rejected private-file policy changed a shared desktop path"
[ -f "$base/txn/files.tsv" ] && [ ! -s "$base/txn/files.tsv" ] \
    || fail "rejected private-file policy changed transaction recovery data"
ok "private generated-file replacement is enforced by an exact path allowlist"

# Once a generated file has reached its final path, optional recovery metadata
# cannot turn that valid repair into a failure or block the next independent
# repair. Force the post-publication check to fail after the first atomic move.
base="$(new_env publication-checkpoint-warning)"
mkdir -p -- "$base/txn" "$base/xdg/data/ableton-wine/lib"
printf 'first replacement\n' > "$base/first"
printf 'second replacement\n' > "$base/second"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$base/txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_txn_preflight_commit_files() { return 1; }
    ableton_publish_file 644 "$2" "$4/lib/config.sh" file replace-generated
    [ "$ABLETON_PUBLICATION_JOURNAL_BROKEN" -eq 1 ]
    ableton_publish_file 644 "$3" "$4/lib/lifecycle.sh" file replace-generated
' _ "$here" "$base/first" "$base/second" "$base/xdg/data/ableton-wine" \
    >"$base/out" 2>"$base/err" \
    || fail "recovery bookkeeping failure became a generated-file gate"
grep -qxF 'first replacement' "$base/xdg/data/ableton-wine/lib/config.sh" \
    && grep -qxF 'second replacement' "$base/xdg/data/ableton-wine/lib/lifecycle.sh" \
    || fail "recovery bookkeeping failure blocked an independent repair"
grep -qF 'Continuing with the installed file.' "$base/err" \
    || fail "post-publication recovery warning was not plain"
ok "post-publication bookkeeping cannot invalidate or block generated-file repairs"

base="$(new_env manifest-external-path)"
state="$base/xdg/state/ableton-wine"
mkdir -p -- "$state"
external_target="$base/external-valid-digest"
printf 'external valid digest bytes\n' > "$external_target"
printf 'file\t%s\t%s\n' "$external_target" \
    "$(sha256sum -- "$external_target" | awk '{print $1}')" > "$state/install-manifest.tsv"
repair_target="$base/xdg/data/ableton-wine/setup-realtime.sh"
printf 'replacement bytes\n' > "$base/replacement"
run_guarded_file_install "$base" "$base/txn" "$repair_target" \
    >"$base/out" 2>"$base/err" \
    || fail "arbitrary legacy inventory row vetoed canonical generated-file repair"
grep -qxF 'replacement bytes' "$repair_target" \
    || fail "arbitrary legacy inventory row blocked canonical repair"
grep -qxF 'external valid digest bytes' "$external_target" \
    || fail "repair followed an arbitrary path from legacy inventory"
ok "legacy inventory never authorizes or vetoes generated-file repair targets"

run_direct_uninstall()
{
    local base="$1" mode="${2:---keep-prefix}"
    if [ ! -x "$base/fakebin/systemctl" ] || [ ! -x "$base/fakebin/xdg-mime" ]; then
        install_fake_host_tools "$base"
    fi
    run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_LINK_MODE=off \
        ABLETON_TEST_REGISTRY_LOG="$base/registry.log" \
        ABLETON_TEST_REGISTRY_STATE="$base/registry-present" \
        bash "$here/uninstall.sh" "$mode" --yes
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
    if [ "$marker_kind" = state ]; then
        run_direct_uninstall "$base" "$mode" >"$base/out" 2>"$base/err" \
            || fail "damaged optional state marker blocked exact runtime removal"
        [ ! -e "$base/runtime" ] && [ ! -L "$base/runtime" ] \
            || fail "damaged optional state marker retained the configured runtime"
        grep -qxF 'prefix sentinel' "$base/prefix/sentinel" \
            && grep -qxF 'state sentinel' "$base/xdg/state/ableton-wine/sentinel" \
            || fail "damaged optional state marker changed retained prefix or support data"
        grep -qF 'Ableton Linux support files were left unchanged because their directory is not recognised:' \
            "$base/err" || fail "damaged optional state marker did not produce its warning"
    else
        if run_direct_uninstall "$base" "$mode" >"$base/out" 2>"$base/err"; then
            fail "uninstall accepted a $marker_kind marker with trailing NUL"
        fi
        if ! grep -qxF 'runtime sentinel' "$base/runtime/sentinel" \
           || ! grep -qxF 'prefix sentinel' "$base/prefix/sentinel" \
           || ! grep -qxF 'state sentinel' "$base/xdg/state/ableton-wine/sentinel"; then
            fail "$marker_kind marker refusal changed an owned tree"
        fi
    fi
done
ok "runtime and prefix markers remain fatal while damaged optional state is retained with a warning"

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
        run_direct_uninstall "$base" >"$base/out" 2>"$base/err" \
            || { chmod 600 "$path" 2>/dev/null || true; \
                 fail "$corrupt_kind optional $journal journal blocked runtime removal"; }
        chmod 600 "$path" 2>/dev/null || true
        [ ! -e "$base/runtime" ] && [ ! -L "$base/runtime" ] \
            && grep -qxF 'prefix sentinel' "$base/prefix/sentinel" \
            || fail "$corrupt_kind $journal state blocked runtime removal or changed the kept prefix"
        grep -qxF 'external uninstall journal' "$base/external-journal" \
            || fail "$corrupt_kind $journal warning changed an external referent"
        grep -qF '!! warning:' "$base/err" \
            || fail "$corrupt_kind $journal state did not produce an optional-cleanup warning"
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
run_direct_uninstall "$base" >"$base/out" 2>"$base/err" \
    || fail "invalid optional prestate attached to a runtime blocked runtime removal"
[ ! -e "$base/runtime" ] && [ ! -L "$base/runtime" ] \
    && [ -f "$state/install-prestate/$runtime_id" ] \
    && [ -f "$state/install-prestate.tsv" ] \
    || fail "runtime removal did not preserve the invalid optional prestate for inspection"
grep -qF '!! warning:' "$base/err" \
    || fail "invalid runtime prestate did not produce an optional-cleanup warning"
ok "uninstall leaves unsafe optional journals untouched while removing the exact configured runtime"

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
run_direct_uninstall "$base" >"$base/out" 2>"$base/err" \
    || fail "later missing optional prestate blocked runtime removal"
if ! grep -qxF 'first managed bytes' "$first" \
   || ! grep -qxF 'second managed bytes' "$second" \
   || { [ -e "$base/runtime" ] || [ -L "$base/runtime" ]; }; then
    fail "late missing prestate changed optional files or retained the configured runtime"
fi
grep -qF '!! warning:' "$base/err" \
    || fail "late missing prestate did not produce an optional-cleanup warning"
ok "late missing prestate leaves optional files untouched without blocking runtime removal"

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
run_direct_uninstall "$base" >"$base/out" 2>"$base/err" \
    || fail "MIME default restoration failure blocked runtime removal"
[ ! -e "$base/runtime" ] && [ ! -L "$base/runtime" ] \
    || fail "MIME default restoration failure retained the configured runtime"
[ -r "$base/xdg/state/ableton-wine/mime-prestate.tsv" ] \
    && [ -r "$base/xdg/state/ableton-wine/.ableton-linux-state" ] \
    || fail "MIME default restoration failure discarded retry state"
grep -qF '!! warning:' "$base/err" \
    || fail "MIME default restoration failure did not produce a retry warning"

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
run_direct_uninstall "$base" >"$base/out" 2>"$base/err" \
    || fail "MIME clear failure blocked runtime removal"
[ ! -e "$base/runtime" ] && [ ! -L "$base/runtime" ] \
    || fail "MIME clear failure retained the configured runtime"
[ -r "$base/xdg/state/ableton-wine/mime-prestate.tsv" ] \
    && [ -r "$base/xdg/state/ableton-wine/.ableton-linux-state" ] \
    || fail "MIME clear failure discarded retry state"
grep -qF '!! warning:' "$base/err" \
    || fail "MIME clear failure did not produce a retry warning"
ok "MIME command and mimeapps restoration failures warn while runtime removal succeeds"

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
run_direct_uninstall "$base" >"$base/out" 2>"$base/err" \
    || fail "post-lock MIME mutation blocked runtime removal"
[ -e "$base/mime-mutated" ] && [ ! -e "$base/runtime" ] \
    && [ -f "$state/.ableton-linux-state" ] \
    || fail "post-lock MIME mutation did not preserve support state while removing runtime"
grep -qF 'File-opening defaults were left unchanged because their saved settings changed while uninstall was starting' \
    "$base/err" || fail "post-lock MIME mutation warning was not explicit"
ok "uninstall revalidates changed MIME state, retains it, and still removes the runtime"

base="$(new_env partial-uninstall-retry)"
mkdir -p -- "$base/runtime" "$base/xdg/state/ableton-wine/install-prestate"
install_fake_host_tools "$base"
mkdir -p -- "$base/xdg/config/ableton-wine"
printf 'unrelated user settings\n' > "$base/xdg/config/ableton-wine/user-notes"
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
run_direct_uninstall "$base" >"$base/first.out" 2>"$base/first.err" \
    || fail "optional file conflict blocked configured runtime removal"
grep -qxF 'first previous bytes' "$first" \
    && grep -qxF 'user conflict bytes' "$second" \
    && [ ! -e "$base/runtime" ] && [ ! -L "$base/runtime" ] \
    && [ -d "$base/xdg/state/ableton-wine" ] \
    || fail "partial uninstall did not remove Wine while retaining the file conflict and retry state"
grep -qF 'kept an unrecognised or user-modified file at' "$base/first.err" \
    || fail "optional file conflict was not reported"
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
    && grep -qxF 'unrelated user settings' \
        "$base/xdg/config/ableton-wine/user-notes" \
    || fail "successful partial-uninstall retry retained runtime or ownership state"
grep -qF "kept your already-restored earlier file at $first" "$base/retry.out" \
    || fail "partial uninstall retry did not recognize its already-restored file"
ok "optional uninstall conflicts preserve retry state without retaining the runtime"

for snapshot in installer-config pipeasio-config.ini; do
    base="$(new_env "rollback-directory-${snapshot//./-}")"
    make_rollback_fixture "$base"
    rm -f -- "$ROLLBACK_SAVED/.ableton-linux-rollback/$snapshot"
    mkdir -p -- "$ROLLBACK_SAVED/.ableton-linux-rollback/$snapshot"
    printf 'directory snapshot sentinel\n' \
        > "$ROLLBACK_SAVED/.ableton-linux-rollback/$snapshot/sentinel"
    run_user_rollback "$base" env ABLETON_TEST_REGISTRY_STICKY=0 \
        >"$base/out" 2>"$base/err" \
        || fail "unavailable saved $snapshot settings blocked runtime rollback"
    [ -f "$base/runtime/previous-generation" ] \
        && [ ! -e "$ROLLBACK_SAVED" ] && [ ! -L "$ROLLBACK_SAVED" ] \
        && [ -f "$base/runtime/.ableton-linux-rollback/$snapshot/sentinel" ] \
        && grep -qF 'live_major=12' "$ROLLBACK_INSTALLER_CONFIG" \
        && grep -qF 'buffer_size = 512' "$ROLLBACK_PIPEASIO_CONFIG" \
        || fail "unavailable saved $snapshot settings changed current settings or blocked Wine"
    grep -qF 'The saved runtime is usable, but its saved settings are unavailable. Current settings will stay in place.' \
        "$base/err" || fail "unavailable saved $snapshot settings warning was not explicit"
done
ok "unavailable saved settings warn without blocking runtime rollback"

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
grep -qF "A file update stopped before it finished: $target" "$base/err" \
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
grep -qF "A file changed while the installer was updating it: $target" "$base/err" \
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
grep -qF "A file changed while the installer was updating it: $target" "$base/err" \
    || fail "absent changed commit refusal was not explicit"
grep -qxF 'third-party appeared' "$target" \
    || fail "absent changed commit refusal rewrote the recreated target"
ok "commit preflight requires exact committed post-operation objects and rejects pending or third-party rows"

# A journal row can be rebound more than once before the outer transaction
# closes.  The immediately preceding installer generation is rollback-safe
# while a new atomic publication is pending; only the last token may commit.
base="$(new_env txn-generation-chain)"
txn="$base/txn"
target="$base/xdg/data/ableton-wine/detect-theme.sh"
mkdir -p -- "$txn" "$(dirname "$target")"
printf 'original generation\n' > "$target"
printf 'installer generation A\n' > "$base/generation-a"
printf 'installer generation B\n' > "$base/generation-b"
printf 'installer generation C\n' > "$base/generation-c"
printf 'third-party generation\n' > "$base/third-party"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    target="$2"
    token_a="$(ableton_regular_source_token "$3")"
    token_b="$(ableton_regular_source_token "$4")"
    token_c="$(ableton_regular_source_token "$5")"
    ableton_txn_snapshot "$target"
    ableton_txn_expect "$target" "$token_a"
    ableton_atomic_restore_object "$3" "$target"
    ableton_txn_expect "$target" "$token_b"
    [ "$(cut -f4 "$6/files.tsv")" = "$token_a,$token_b" ]
    ableton_txn_preflight_rollback_files "$6"
    if ableton_txn_preflight_commit_files "$6" >/dev/null 2>&1; then exit 81; fi
    ableton_atomic_restore_object "$4" "$target"
    ableton_txn_preflight_commit_files "$6"
    ableton_txn_expect "$target" "$token_c"
    [ "$(cut -f4 "$6/files.tsv")" = "$token_b,$token_c" ]
    ableton_txn_preflight_rollback_files "$6"
    if ableton_txn_preflight_commit_files "$6" >/dev/null 2>&1; then exit 82; fi
    ableton_atomic_restore_object "$5" "$target"
    ableton_txn_preflight_commit_files "$6"
    ableton_atomic_restore_object "$7" "$target"
    if ableton_txn_preflight_commit_files "$6" >/dev/null 2>&1; then exit 83; fi
    if ableton_txn_preflight_rollback_files "$6" >/dev/null 2>&1; then exit 84; fi
    ableton_atomic_restore_object "$5" "$target"
    ableton_txn_rollback_files "$6"
' _ "$here" "$target" "$base/generation-a" "$base/generation-b" \
    "$base/generation-c" "$txn" "$base/third-party" \
    || fail "two-generation transaction chain rejected an installer-owned transition"
grep -qxF 'original generation' "$target" \
    || fail "two-generation transaction rollback did not restore the original object"

base="$(new_env txn-generation-schema)"
txn="$base/txn"
target="$base/xdg/data/ableton-wine/detect-scale.sh"
mkdir -p -- "$txn" "$(dirname "$target")"
token_a="file:$(printf 'schema A\n' | sha256sum | awk '{print $1}')"
token_b="file:$(printf 'schema B\n' | sha256sum | awk '{print $1}')"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    target="$2"
    token_a="$3"
    token_b="$4"
    good=(pending absent "$token_a" "absent,$token_a" "$token_a,$token_b")
    bad=(",$token_a" "$token_a," "$token_a,,$token_b" \
        "$token_a,$token_a" "$token_a,$token_b,absent" \
        "pending,$token_a" file:abc arbitrary)
    for post in "${good[@]}"; do
        printf "absent\\t%s\\t-\\t%s\\n" "$target" "$post" > "$5/files.tsv"
        ableton_txn_validate_files "$5"
    done
    for post in "${bad[@]}"; do
        printf "absent\\t%s\\t-\\t%s\\n" "$target" "$post" > "$5/files.tsv"
        if ableton_txn_validate_files "$5" >/dev/null 2>&1; then exit 85; fi
    done
' _ "$here" "$target" "$token_a" "$token_b" "$txn" \
    || fail "transaction generation-token schema accepted an ambiguous chain"
ok "transaction generations keep one rollback-safe predecessor, commit only the final token, and reject ambiguous chains"

# The in-process snapshot cache must include the journal identity.  Component
# and prefix phases can switch transaction directories without starting a new
# shell; the same target still needs an independent prestate row in each one.
base="$(new_env txn-snapshot-cache-journal-scope)"
first_txn="$base/first-transaction"
second_txn="$base/second-transaction"
target="$base/xdg/data/ableton-wine/detect-theme.sh"
mkdir -p -- "$first_txn" "$second_txn" "$(dirname "$target")"
printf 'shared original bytes\n' > "$target"
# shellcheck disable=SC2016
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ABLETON_TRANSACTION_DIR="$3"
    export ABLETON_TRANSACTION_DIR
    ableton_txn_init
    ableton_txn_snapshot "$2"
    ABLETON_TRANSACTION_DIR="$4"
    export ABLETON_TRANSACTION_DIR
    ableton_txn_init
    ableton_txn_snapshot "$2"
' _ "$here" "$target" "$first_txn" "$second_txn" \
    || fail "same-shell snapshot could not switch transaction journals"
for txn in "$first_txn" "$second_txn"; do
    [ "$(wc -l < "$txn/files.tsv")" -eq 1 ] \
        || fail "same-shell snapshot omitted or duplicated the target in $txn"
    backup="$(awk -F '\t' -v p="$target" '$2==p { print $3 }' "$txn/files.tsv")"
    if [ -z "$backup" ] || ! cmp -s -- "$backup" "$target"; then
        fail "same-shell snapshot did not preserve exact prestate in $txn"
    fi
done
ok "snapshot caching is scoped by transaction directory as well as target path"

# The installed-file list is disposable uninstall inventory, not integrity
# state. Component and prefix phases may rewrite it sequentially, but neither
# the outer core journal nor the prefix-host journal may claim it (issue #280).
base="$(new_env shared-ownership-manifest)"
outer="$base/outer-transaction"
prefix_host="$outer/prefix-host"
version_source="$base/version-source"
pipeasio_source="$base/pipeasio-source"
mkdir -p -- "$outer" "$prefix_host"
printf 'component version\n' > "$version_source"
printf '[pipeasio]\nbuffer_size = 256\n' > "$pipeasio_source"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$outer" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_mark_state_home
    ableton_txn_init
    ableton_install_file 644 "$2" "$ABLETON_DATA_HOME/VERSION"
    ableton_write_ownership_manifest
' _ "$here" "$version_source" \
    || fail "component phase could not create the shared-manifest fixture"
manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
manifest_before="file:$(sha256sum -- "$manifest" | awk '{print $1}')"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$prefix_host" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_install_file 600 "$2" "$XDG_CONFIG_HOME/pipeasio/config.ini" config
    ableton_write_ownership_manifest "$3"
' _ "$here" "$pipeasio_source" "$outer" \
    || fail "prefix phase could not extend the shared ownership manifest"
manifest_after="file:$(sha256sum -- "$manifest" | awk '{print $1}')"
[ "$manifest_before" != "$manifest_after" ] \
    || fail "prefix fixture did not exercise a real installed-file-list rewrite"
version_target="$base/xdg/data/ableton-wine/VERSION"
pipeasio_target="$base/xdg/config/pipeasio/config.ini"
version_digest="$(sha256sum -- "$version_target" | awk '{print $1}')"
pipeasio_digest="$(sha256sum -- "$pipeasio_target" | awk '{print $1}')"
awk -F '\t' -v p="$version_target" -v d="$version_digest" \
    '$1=="file" && $2==p && $3==d { n++ } END { exit n != 1 }' "$manifest" \
    || fail "installed-file list lost the component VERSION row"
awk -F '\t' -v p="$pipeasio_target" -v d="$pipeasio_digest" \
    '$1=="config" && $2==p && $3==d { n++ } END { exit n != 1 }' "$manifest" \
    || fail "installed-file list lost the prefix PipeASIO row"
for journal in "$outer/files.tsv" "$prefix_host/files.tsv"; do
    ! awk -F '\t' -v p="$manifest" '$2==p { found=1 } END { exit !found }' "$journal" \
        || fail "installed-file list was recorded in $journal"
done
run_txn_commit_preflight_only "$base" "$prefix_host" \
    || fail "prefix-host preflight rejected its own completed work"
run_txn_commit_preflight_only "$base" "$outer" \
    || fail "outer preflight inspected the installed-file list"
for txn in "$prefix_host" "$outer"; do
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_preflight_rollback_files "$2"
    ' _ "$here" "$txn" \
        || fail "rollback preflight inspected installed-file inventory in $txn"
done
run_isolated "$base" bash "$here/setup-prefix.sh" --rollback "$outer" \
    || fail "prefix rollback rejected the independent-inventory fixture"
run_isolated "$base" bash "$here/install.sh" --rollback "$outer" \
    || fail "component rollback rejected the independent-inventory fixture"
[ ! -e "$pipeasio_target" ] && [ ! -e "$version_target" ] \
    || fail "ordered prefix/component rollback did not restore generated-file prestate"
[ "file:$(sha256sum -- "$manifest" | awk '{print $1}')" = "$manifest_after" ] \
    || fail "core rollback rewound disposable installed-file inventory"
ok "component and prefix phases share current uninstall inventory outside both journals"

# A failed second inventory publication leaves the prior inventory generation
# intact. Because neither journal owns it, that warning cannot poison core
# commit or rollback checks.
base="$(new_env shared-manifest-publish-failure)"
outer="$base/outer-transaction"
prefix_host="$outer/prefix-host"
version_source="$base/version-source"
pipeasio_source="$base/pipeasio-source"
mkdir -p -- "$outer" "$prefix_host"
printf 'component version\n' > "$version_source"
printf '[pipeasio]\nbuffer_size = 256\n' > "$pipeasio_source"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$outer" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_mark_state_home
    ableton_txn_init
    ableton_install_file 644 "$2" "$ABLETON_DATA_HOME/VERSION"
    ableton_write_ownership_manifest
' _ "$here" "$version_source" \
    || fail "component phase could not create the failed-manifest fixture"
manifest="$base/xdg/state/ableton-wine/install-manifest.tsv"
manifest_before="file:$(sha256sum -- "$manifest" | awk '{print $1}')"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$prefix_host" \
    INJECT_MANIFEST="$manifest" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_install_file 600 "$2" "$XDG_CONFIG_HOME/pipeasio/config.ini" config
    mv()
    {
        [ "${@: -1}" != "$INJECT_MANIFEST" ] || return 88
        command mv "$@"
    }
    set +e
    ableton_write_ownership_manifest "$3"
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
' _ "$here" "$pipeasio_source" "$outer" \
    || fail "manifest publication failure fixture did not stop at the injected rename"
[ "file:$(sha256sum -- "$manifest" | awk '{print $1}')" = "$manifest_before" ] \
    || fail "failed second manifest publication changed the first generation"
for journal in "$outer/files.tsv" "$prefix_host/files.tsv"; do
    ! awk -F '\t' -v p="$manifest" '$2==p { found=1 } END { exit !found }' "$journal" \
        || fail "failed inventory publication added the list to $journal"
done
run_txn_commit_preflight_only "$base" "$prefix_host" \
    || fail "prefix-host commit preflight rejected work completed before manifest failure"
run_txn_commit_preflight_only "$base" "$outer" \
    || fail "outer commit preflight was poisoned by optional inventory failure"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$prefix_host" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_preflight_rollback_files "$2"
' _ "$here" "$prefix_host" \
    || fail "prefix-host rollback preflight rejected completed config work"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$outer" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_preflight_rollback_files "$2"
' _ "$here" "$outer" \
    || fail "outer rollback preflight was poisoned by optional inventory failure"
run_isolated "$base" bash "$here/setup-prefix.sh" --rollback "$outer" \
    || fail "prefix rollback failed after interrupted manifest publication"
run_isolated "$base" bash "$here/install.sh" --rollback "$outer" \
    || fail "component rollback failed after interrupted manifest publication"
[ ! -e "$base/xdg/config/pipeasio/config.ini" ] \
    && [ ! -e "$base/xdg/data/ableton-wine/VERSION" ] \
    || fail "inventory warning prevented exact generated-file rollback"
[ "file:$(sha256sum -- "$manifest" | awk '{print $1}')" = "$manifest_before" ] \
    || fail "rollback changed the prior installed-file inventory generation"
ok "failed installed-file-list publication leaves prior inventory and cannot poison core checks"

for corrupt_kind in symlink-dir orphan-slot; do
    base="$(new_env "persistent-prestate-$corrupt_kind")"
    state="$base/xdg/state/ableton-wine"
    txn="$base/txn"
    target="$base/xdg/data/ableton-wine/detect-scale.sh"
    mkdir -p -- "$state" "$txn" "$(dirname "$target")"
    printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
    cp -- "$here/detect-scale.sh" "$target"
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
    run_guarded_file_install "$base" "$txn" "$target" \
        >"$base/out" 2>"$base/err" \
        || fail "repair install consulted stale persistent prestate $corrupt_kind"
    grep -qxF 'replacement bytes' "$target" \
        || fail "stale persistent prestate $corrupt_kind blocked the canonical replacement"
    run_txn_commit_preflight_only "$base" "$txn" \
        || fail "stale persistent prestate $corrupt_kind poisoned commit preflight"
    if [ "$corrupt_kind" = symlink-dir ]; then
        grep -qxF 'external prestate directory sentinel' \
            "$base/external-prestate-dir/sentinel" \
            || fail "repair install changed a stale prestate symlink referent"
    else
        grep -qxF 'external orphan sentinel' "$base/external-orphan" \
            || fail "repair install changed a stale orphan backup referent"
    fi
done
ok "repair installs ignore stale persistent prestate while leaving legacy recovery objects untouched"

base="$(new_env atomic-install-failure)"
txn="$base/txn"
state="$base/xdg/state/ableton-wine"
target="$base/xdg/data/ableton-wine/detect-scale.sh"
mkdir -p -- "$txn" "$base/fakebin" "$state" "$(dirname "$target")"
printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
printf 'stable original bytes\n' > "$base/source"
cp -- "$base/source" "$target"
printf 'file\t%s\t%s\n' "$target" \
    "$(sha256sum -- "$target" | awk '{print $1}')" \
    > "$state/install-manifest.tsv"
cat > "$base/fakebin/install" <<'EOF'
#!/bin/bash
target="${@: -1}"
: > "${ABLETON_TEST_INSTALL_CALLED:?}"
printf 'partial replacement\n' > "$target"
exit 99
EOF
chmod 755 "$base/fakebin/"*
# shellcheck disable=SC2016
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_TRANSACTION_DIR="$txn" \
    ABLETON_TEST_INSTALL_CALLED="$base/install-called" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_install_file 600 "$2" "$3"
' _ "$here" "$base/source" "$target" >"$base/out" 2>"$base/err"; then
    fail "install helper unexpectedly succeeded after its staged writer failed"
fi
[ -e "$base/install-called" ] \
    || fail "atomic install failure fixture never reached the staged writer"
grep -qxF 'stable original bytes' "$target" \
    || fail "install helper destroyed the original target after a staged write failure"
ok "atomic file installers keep the original target when a staged write fails"

# Refreshing already-owned generated files does not create new persistent
# prestate. Faults aimed at that legacy path therefore never fire, and ordinary
# transaction rollback still restores both prior managed generations.
for failure in backup-copy index-publish; do
    base="$(new_env "prestate-second-generation-$failure")"
    txn="$base/txn"
    state="$base/xdg/state/ableton-wine"
    prestate_dir="$state/install-prestate"
    first="$base/xdg/data/ableton-wine/detect-theme.sh"
    second="$base/xdg/data/ableton-wine/detect-scale.sh"
    mkdir -p -- "$txn" "$state" "$(dirname "$first")"
    printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
    printf 'first user original\n' > "$first"
    printf 'second user original\n' > "$second"
    cp -- "$first" "$base/first.original"
    cp -- "$second" "$base/second.original"
    printf 'file\t%s\t%s\nfile\t%s\t%s\n' \
        "$first" "$(sha256sum -- "$first" | awk '{print $1}')" \
        "$second" "$(sha256sum -- "$second" | awk '{print $1}')" \
        > "$state/install-manifest.tsv"
    printf 'first installer replacement\n' > "$base/first.replacement"
    printf 'second installer replacement\n' > "$base/second.replacement"
    # shellcheck disable=SC2016
    run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" \
        INJECT_PRESTATE_FAILURE="$failure" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        . "$1/lib/manifest.sh"
        ableton_txn_init
        ableton_install_file 644 "$4" "$2"
        injection_marker="$7"
        cp()
        {
            if [ "$INJECT_PRESTATE_FAILURE" = backup-copy ]; then
                case "${@: -1}" in
                    "$ABLETON_STATE_HOME/install-prestate/.ableton-restore."*)
                        : > "$injection_marker"
                        return 88 ;;
                esac
            fi
            command cp "$@"
        }
        mv()
        {
            if [ "$INJECT_PRESTATE_FAILURE" = index-publish ] \
               && [ "${@: -1}" = "$ABLETON_STATE_HOME/install-prestate.tsv" ]; then
                : > "$injection_marker"
                return 88
            fi
            command mv "$@"
        }
        ableton_install_file 644 "$5" "$3"
        [ ! -e "$injection_marker" ]
        ableton_txn_preflight_commit_files "$6"
        ableton_txn_preflight_rollback_files "$6"
    ' _ "$here" "$first" "$second" "$base/first.replacement" \
        "$base/second.replacement" "$txn" "$base/prestate-injection-fired" \
        || fail "repair install reached obsolete prestate $failure publication"
    index="$state/install-prestate.tsv"
    [ ! -e "$index" ] && [ ! -L "$index" ] \
        || fail "repair install created a legacy prestate index during $failure fixture"
    [ ! -e "$prestate_dir" ] && [ ! -L "$prestate_dir" ] \
        || fail "repair install created a legacy prestate directory during $failure fixture"
    grep -qxF 'first installer replacement' "$first" \
        && grep -qxF 'second installer replacement' "$second" \
        || fail "repair install did not publish both canonical generations during $failure fixture"
    run_txn_file_rollback "$base" "$txn" \
        || fail "full rollback failed after ignored prestate $failure injection"
    if ! cmp -s -- "$first" "$base/first.original" \
       || ! cmp -s -- "$second" "$base/second.original"; then
        fail "full rollback after ignored prestate $failure injection changed an original target"
    fi
done
ok "repair installs bypass obsolete prestate publication and remain transaction-rollback-safe"

# Restoring a user's saved object must be one atomic replacement. A failed
# restore may not delete the managed live object and thereby invalidate the
# rollback token recorded immediately beforehand.
base="$(new_env managed-removal-restore-failure)"
txn="$base/txn"
state="$base/xdg/state/ableton-wine"
target="$base/xdg/data/ableton-wine/detect-theme.sh"
id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
backup="$state/install-prestate/$id"
index="$state/install-prestate.tsv"
mkdir -p -- "$txn" "$(dirname "$target")" "$(dirname "$backup")"
printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
printf 'managed live generation\n' > "$target"
printf 'saved user generation\n' > "$backup"
printf 'present\t%s\t%s\n' "$target" "$backup" > "$index"
cp -- "$target" "$base/target.before"
cp -- "$backup" "$base/backup.before"
cp -- "$index" "$base/index.before"
# shellcheck disable=SC2016
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$txn" \
    INJECT_RESTORE_SOURCE="$backup" INJECT_RESTORE_TARGET="$target" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    eval "$(declare -f ableton_atomic_restore_object \
        | sed "1s/^ableton_atomic_restore_object/ableton_atomic_restore_object_real/")"
    ableton_atomic_restore_object()
    {
        if [ "$1" = "$INJECT_RESTORE_SOURCE" ] \
           && [ "$2" = "$INJECT_RESTORE_TARGET" ]; then
            return 88
        fi
        ableton_atomic_restore_object_real "$@"
    }
    ableton_txn_init
    set +e
    ableton_remove_managed_file "$2"
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    cmp -s -- "$2" "$3"
    ableton_txn_preflight_rollback_files "$4"
' _ "$here" "$target" "$base/target.before" "$txn" \
    || fail "failed managed restore deleted its live object or poisoned rollback"
run_txn_file_rollback "$base" "$txn" \
    || fail "full rollback failed after the managed restore injection"
if ! cmp -s -- "$target" "$base/target.before" \
   || ! cmp -s -- "$backup" "$base/backup.before" \
   || ! cmp -s -- "$index" "$base/index.before"; then
    fail "managed restore failure rollback did not restore exact target and prestate"
fi
ok "failed managed-file restoration leaves the live object intact and fully rollback-safe"

base="$(new_env rollback-current-config-directory)"
make_rollback_fixture "$base"
rm -f -- "$ROLLBACK_INSTALLER_CONFIG"
mkdir -p -- "$ROLLBACK_INSTALLER_CONFIG"
printf 'current config directory sentinel\n' > "$ROLLBACK_INSTALLER_CONFIG/sentinel"
run_user_rollback "$base" env ABLETON_TEST_REGISTRY_STICKY=0 \
    >"$base/out" 2>"$base/err" \
    || fail "current installer-settings directory blocked runtime rollback"
[ -f "$base/runtime/previous-generation" ] \
    && [ ! -e "$ROLLBACK_SAVED" ] && [ ! -L "$ROLLBACK_SAVED" ] \
    && [ -f "$ROLLBACK_INSTALLER_CONFIG/sentinel" ] \
    && grep -qF 'buffer_size = 883' "$ROLLBACK_PIPEASIO_CONFIG" \
    || fail "current installer-settings directory was changed or blocked the restored runtime"
grep -qF 'The previous Wine version is restored, but its installer settings could not be restored.' \
    "$base/err" || fail "current installer-settings directory warning was not explicit"
ok "current installer-settings conflicts warn without blocking runtime rollback"

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

# Canonical legacy-runtime adoption is a committed safety migration, not an
# ancillary host-file mutation. Runtime-only promotion therefore keeps its file
# journal empty; rollback restores every original runtime object and retains the
# newly valid ownership marker.
base="$(new_env legacy-runtime-promotion-rollback)"
make_legacy_default_runtime "$base"
make_runtime_only_kit "$base"
legacy_runtime="$base/home/.local/opt/wine-d2d1-nspa-11.13"
cp -a -- "$legacy_runtime" "$base/legacy-runtime.before"
txn="$base/runtime-transaction"
private_backup="$legacy_runtime.transaction-${txn##*/}"
mkdir -p -- "$txn"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$legacy_runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only \
        --transaction-dir "$txn" --yes >"$base/install.out" 2>"$base/install.err" \
    || fail "external legacy runtime promotion fixture failed"
[ ! -e "$legacy_runtime/legacy-sentinel" ] \
    && [ -f "$private_backup/legacy-sentinel" ] \
    && [ -f "$private_backup/.ableton-linux-runtime" ] \
    && [ -f "$txn/runtime.tsv" ] && [ -f "$txn/files.tsv" ] \
    && [ ! -s "$txn/files.tsv" ] && [ -f "$txn/active" ] \
    || fail "legacy runtime promotion did not preserve its adopted private generation"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$legacy_runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash "$base/kit/scripts/install.sh" --preflight-rollback "$txn" \
    >"$base/preflight.out" 2>"$base/preflight.err" \
    || fail "legacy runtime promotion was rejected by aggregate rollback preflight"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$legacy_runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash "$base/kit/scripts/install.sh" --rollback "$txn" \
    >"$base/rollback.out" 2>"$base/rollback.err" \
    || fail "legacy runtime promotion could not fully roll back"
cmp -s -- "$legacy_runtime/.ableton-linux-runtime" \
    <(printf 'format=1\nname=wine-d2d1-nspa-11.13\n') \
    || fail "legacy runtime rollback lost its committed ownership migration"
diff -qr --no-dereference --exclude=.ableton-linux-runtime \
    "$base/legacy-runtime.before" "$legacy_runtime" \
    >"$base/runtime.diff" \
    || fail "runtime rollback changed legacy content beyond the committed marker migration"
[ ! -e "$private_backup" ] && [ ! -L "$private_backup" ] \
    && [ ! -e "$txn/runtime.tsv" ] && [ -f "$txn/active" ] \
    || fail "legacy runtime rollback retained promotion state or retired the outer marker"
ok "runtime promotion rollback preserves committed legacy adoption and restores every other runtime object"

base="$(new_env legacy-runtime-uninstall)"
make_legacy_default_runtime "$base"
install_fake_host_tools "$base"
run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes >"$base/out" 2>"$base/err" \
    || fail "optional support-state cleanup reported failure after removing a canonical legacy runtime"
[ ! -e "$base/home/.local/opt/wine-d2d1-nspa-11.13" ] \
    || fail "uninstall retained the adopted canonical legacy runtime"
legacy_uninstall_state="$base/xdg/state/ableton-wine"
if [ -e "$legacy_uninstall_state" ] || [ -L "$legacy_uninstall_state" ]; then
    [ -d "$legacy_uninstall_state" ] && [ ! -L "$legacy_uninstall_state" ] \
        && cmp -s -- "$legacy_uninstall_state/.ableton-linux-state" \
            <(printf 'format=1\nowner=ableton-linux\n') \
        || fail "optional legacy-uninstall cleanup retained unsafe unmarked state"
    grep -Eq 'Ableton Linux support (files|state).*(remain|retained)|support directory changed.*retained' \
        "$base/out" "$base/err" \
        || fail "retained optional legacy-uninstall state was not reported"
fi
ok "canonical legacy-runtime removal succeeds even when optional support-state cleanup remains"

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
run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes >"$base/first.out" 2>"$base/first.err" \
    || fail "a preserved modified integration file made core legacy uninstall report failure"
if [ -e "$legacy_runtime" ] || [ -L "$legacy_runtime" ] \
   || ! grep -qxF 'user conflict bytes' "$conflict" \
   || ! cmp -s -- "$state/.ableton-linux-state" \
        <(printf 'format=1\nowner=ableton-linux\n') \
   || [ ! -f "$state/install-manifest.tsv" ]; then
    sed -n '1,160p' "$base/first.out" >&2
    sed -n '1,160p' "$base/first.err" >&2
    find "$base" -maxdepth 6 -printf '%y %p -> %l\n' >&2
    fail "core legacy uninstall did not remove Wine while preserving the conflict and safe retry state"
fi
grep -qF "kept an unrecognised or user-modified file at $conflict" "$base/first.err" \
    || fail "preserved modified integration file was not reported"
cp -- "$base/managed-reference" "$conflict"
run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_LINK_MODE=off \
    bash "$here/uninstall.sh" --keep-prefix --yes >"$base/retry.out" 2>"$base/retry.err" \
    || fail "legacy partial uninstall did not complete on retry without legacy evidence"
[ ! -e "$conflict" ] && [ ! -e "$legacy_runtime" ] && [ ! -e "$state" ] \
    || fail "legacy partial-uninstall retry retained the resolved conflict or ownership state"
ok "legacy uninstall removes core Wine, preserves modified integration, and supports optional cleanup retry"

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
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINKD="$external_linkd" ABLETON_LINK_MODE=off \
    ABLETON_TEST_REGISTRY_LOG="$base/registry.log" \
    ABLETON_TEST_REGISTRY_STATE="$base/registry-present" \
    bash "$here/uninstall.sh" --keep-prefix --yes >"$base/out" 2>"$base/err" \
    || fail "forged optional inventory blocked configured runtime removal"
grep -qxF 'external Link daemon' "$external_linkd" \
    || fail "forged optional inventory changed the external Link daemon"
[ ! -e "$base/runtime" ] && [ ! -L "$base/runtime" ] \
    && [ -f "$base/prefix/system.reg" ] && [ ! -e "$base/registry-present" ] \
    && [ -r "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    || fail "forged optional inventory retained Wine or discarded its inspection record"
grep -qF "Desktop shortcuts, file-opening settings, and older Wine runtimes were left unchanged because the installer's file list could not be trusted" \
    "$base/err" || fail "forged optional inventory warning was not explicit"
ok "external Link helpers are never claimed, while invalid inventory cannot retain Wine"

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
data="$base/xdg/data/ableton-wine"
state="$base/xdg/state/ableton-wine"
mkdir -p -- "$txn" "$base/runtime" "$base/prefix" "$data" "$state" "$base/fakebin"
# A manager that is unavailable both before and during rollback is exact state:
# no service command can have changed it. This keeps this fixture focused on
# policy-file ownership rather than service-manager behavior.
printf '#!/bin/sh\nexit 1\n' > "$base/fakebin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/xdg-mime"
chmod 755 "$base/fakebin/systemctl" "$base/fakebin/xdg-mime"
printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
printf 'configured\n' > "$data/link-configured"
printf 'component asset before\n' > "$data/setup-link.sh"
printf 'file\t%s\t%s\n' "$data/setup-link.sh" \
    "$(sha256sum -- "$data/setup-link.sh" | awk '{print $1}')" \
    > "$state/install-manifest.tsv"
run_link_transaction_action "$base" snapshot "$txn" >"$base/snapshot.out" 2>"$base/snapshot.err" \
    || fail "valid Link snapshot fixture could not capture a complete snapshot"
run_link_transaction_action "$base" preflight-rollback "$txn" >"$base/preflight.out" 2>"$base/preflight.err" \
    || fail "valid complete Link snapshot was rejected by preflight"
find "$txn/link" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort > "$base/link.members"
[ "$(wc -l < "$base/link.members")" -eq 10 ] \
    || fail "valid Link snapshot did not record the full inventory"
! grep -Eq '^(asset-|manifest|prestate)' "$base/link.members" \
    || fail "Link policy snapshot duplicated component transaction state"
! grep -Eq '^link-configured([.]absent)?$' "$base/link.members" \
    || fail "Link policy snapshot turned disposable legacy metadata into a rollback gate"
# Component files may advance after the policy snapshot. Link preflight must not
# reject or later restore those generic-transaction-owned objects.
printf 'component asset after\n' > "$data/setup-link.sh"
printf 'file\t%s\t%s\n' "$data/setup-link.sh" \
    "$(sha256sum -- "$data/setup-link.sh" | awk '{print $1}')" \
    > "$state/install-manifest.tsv"
rm -f -- "$data/link-configured"
run_link_transaction_action "$base" preflight-rollback "$txn" \
    >"$base/changed-preflight.out" 2>"$base/changed-preflight.err" \
    || fail "Link policy preflight inspected component-owned files"
run_link_transaction_action "$base" rollback "$txn" >"$base/rollback.out" 2>"$base/rollback.err" \
    || { sed -n '1,80p' "$base/rollback.err" >&2; fail "Link policy rollback failed"; }
[ ! -e "$data/link-configured" ] && [ ! -L "$data/link-configured" ] \
    || fail "Link rollback recreated disposable legacy policy metadata"
grep -qxF 'component asset after' "$data/setup-link.sh" \
    && grep -qF "$(sha256sum -- "$data/setup-link.sh" | awk '{print $1}')" \
        "$state/install-manifest.tsv" \
    || fail "Link rollback rewound generic component state"
ok "Link snapshot owns external system state without gating on disposable legacy metadata"

base="$(new_env link-snapshot-inventory-tamper)"
txn="$base/txn"
mkdir -p -- "$txn" "$base/runtime" "$base/prefix" "$base/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$base/fakebin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/xdg-mime"
chmod 755 "$base/fakebin/systemctl" "$base/fakebin/xdg-mime"
run_link_transaction_action "$base" snapshot "$txn" >"$base/snapshot.out" 2>"$base/snapshot.err" \
    || fail "Link inventory-tamper fixture could not capture its snapshot"
: > "$txn/link/asset-0.path"
if run_link_transaction_action "$base" preflight-rollback "$txn" >"$base/out" 2>"$base/err"; then
    fail "Link preflight accepted a component-asset member in its policy snapshot"
fi
grep -qF 'Link transaction snapshot has an unknown member: asset-0.path' "$base/err" \
    || fail "Link policy inventory tamper refusal was not explicit"
ok "Link policy snapshot inventory rejects component-owned members"

for corrupt_kind in symlink multiline valid-unmarked; do
    base="$(new_env "link-firewall-${corrupt_kind}")"
    txn="$base/txn"
    mkdir -p -- "$txn" "$base/runtime" "$base/prefix" "$base/xdg/state/ableton-wine"
    case "$corrupt_kind" in
        symlink)
            printf 'format=1\nowner=ableton-linux\n' \
                > "$base/xdg/state/ableton-wine/.ableton-linux-state"
            printf 'external firewall sentinel\n' > "$base/external-firewall"
            ln -s -- "$base/external-firewall" "$base/xdg/state/ableton-wine/link-firewall"
            ;;
        multiline)
            printf 'format=1\nowner=ableton-linux\n' \
                > "$base/xdg/state/ableton-wine/.ableton-linux-state"
            printf 'ufw-added\nextra\n' > "$base/xdg/state/ableton-wine/link-firewall"
            ;;
        valid-unmarked)
            printf 'ufw-added\n' > "$base/xdg/state/ableton-wine/link-firewall" ;;
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
run_link_transaction_action "$base" snapshot "$txn" >"$base/out" 2>"$base/err" \
    || fail "a generated user-service collision became a Link snapshot gate"
grep -qxF 'external unit sentinel' "$base/external-unit" \
    || fail "Link snapshot followed or changed a generated-path symlink"
ok "Link snapshot rejects unsafe firewall authority without gating on generated unit files"

base="$(new_env mime-postpublish-query-not-used)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
mkdir -p -- "$base/xdg/config"
printf '[Default Applications]\nx-scheme-handler/ableton=foreign.desktop\napplication/x-unrelated=foreign-other.desktop\n' \
    > "$base/xdg/config/mimeapps.list"
cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/bin/sh
set -eu
state="${XDG_CONFIG_HOME:?}/mimeapps.list"
case "${1:-}" in
    query) : > "$state.query-called"; exit 91 ;;
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
chmod 755 "$base/fakebin/xdg-mime"
run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/out" 2>"$base/err" \
    || fail "MIME default publication aborted generated integration"
[ ! -e "$base/xdg/config/mimeapps.list.query-called" ] \
    || fail "MIME defaults were redundantly queried after publication"
[ -x "$base/home/.local/bin/ableton-live" ] \
    || fail "MIME default publication did not keep the generated launcher"
grep -qxF 'application/x-unrelated=foreign-other.desktop' \
    "$base/xdg/config/mimeapps.list" \
    || fail "MIME default publication corrupted an unrelated live default"
grep -qxF 'x-scheme-handler/ableton=io.github.shibco.ableton-linux.protocol.desktop' \
    "$base/xdg/config/mimeapps.list" \
    || fail "MIME default publication discarded the staged Ableton default"
ok "MIME defaults are published once without a redundant live query"

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
run_component_install "$base" "$base/runtime" --integration-only >"$base/out" 2>"$base/err" \
    || fail "staged MIME failure aborted generated integration"
grep -qF 'Could not set Ableton as the default app for Live files. Ableton itself can still be used normally.' \
    "$base/err" || fail "staged MIME failure did not produce its plain warning"
cmp -s -- "$base/xdg/config/mimeapps.list" <(printf '[Default Applications]\nx-scheme-handler/ableton=foreign.desktop\n') \
    || fail "staged MIME failure mutated the live mimeapps file"
[ -x "$base/home/.local/bin/ableton-live" ] \
    || fail "staged MIME failure rolled back the generated launcher"
ok "MIME staging failure warns, preserves live associations, and keeps generated integration"

# Model an xdg-mime backend with process-external side effects: every default
# command consumes a global serial and records it in the selected mimeapps
# file. Defaults are prepared against one temporary copy and published once as
# optional live state, outside the generated-file transaction journal.
base="$(new_env mime-single-publication)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
mkdir -p -- "$base/xdg/config"
printf '[Default Applications]\nx-scheme-handler/ableton=foreign.desktop\napplication/x-unrelated=foreign-other.desktop\n' \
    > "$base/xdg/config/mimeapps.list"
cp -- "$base/xdg/config/mimeapps.list" "$base/mimeapps.before"
printf '0\n' > "$base/mime-backend-count"
: > "$base/mime-call-log"
cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/bin/sh
set -eu
state="${XDG_CONFIG_HOME:?}/mimeapps.list"
global="${MIME_GLOBAL_STATE:?}"
log="${MIME_CALL_LOG:?}"
case "${1:-}" in
    query)
        [ "${2:-}" = default ] && [ "$#" -eq 3 ]
        printf 'query\t%s\t%s\n' "$XDG_CONFIG_HOME" "$3" >> "$log"
        awk -F '=' -v type="$3" '$1 == type { value=$2 } END { print value }' \
            "$state" 2>/dev/null || true
        ;;
    default)
        [ "$#" -ge 3 ]
        application="$2"
        shift 2
        serial="$(cat "$global")"
        serial=$((serial + 1))
        printf '%s\n' "$serial" > "$global"
        printf 'default\t%s\t%s\n' "$XDG_CONFIG_HOME" "$application" >> "$log"
        mkdir -p -- "$(dirname "$state")"
        touch "$state"
        awk '$0 !~ /^# backend-serial=/' "$state" > "$state.clean"
        mv -- "$state.clean" "$state"
        for type in "$@"; do
            awk -F '=' -v type="$type" '$1 != type' "$state" > "$state.tmp"
            printf '%s=%s\n' "$type" "$application" >> "$state.tmp"
            mv -- "$state.tmp" "$state"
        done
        printf '# backend-serial=%s\n' "$serial" >> "$state"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$base/fakebin/xdg-mime"
txn="$base/mime-transaction"
mkdir -p -- "$txn"
export MIME_GLOBAL_STATE="$base/mime-backend-count"
export MIME_CALL_LOG="$base/mime-call-log"
run_component_install "$base" "$base/runtime" --integration-only \
    --transaction-dir "$txn" >"$base/install.out" 2>"$base/install.err" \
    || fail "transactional MIME integration failed with a serializing backend"
unset MIME_GLOBAL_STATE MIME_CALL_LOG
[ "$(cat "$base/mime-backend-count")" -eq 3 ] \
    || fail "MIME integration replayed default mutations after staged publication"
[ "$(awk -F '\t' '$1=="default" { n++ } END { print n+0 }' "$base/mime-call-log")" -eq 3 ] \
    || fail "MIME backend saw an unexpected number of default mutations"
awk -F '\t' -v prefix="$base/tmp/ableton-mimeapps." '
    $1=="default" && index($2, prefix) != 1 { bad=1 }
    END { exit bad }
' "$base/mime-call-log" \
    || fail "a MIME default mutation targeted the live configuration home"
grep -qxF '# backend-serial=3' "$base/xdg/config/mimeapps.list" \
    || fail "the staged MIME generation was not the single published live object"
! awk -F '\t' -v p="$base/xdg/config/mimeapps.list" \
    '$2==p { found=1 } END { exit !found }' "$txn/files.tsv" \
    || fail "optional MIME defaults were recorded in the generated-file journal"
run_component_install "$base" "$base/runtime" --preflight-commit "$txn" \
    >"$base/commit-preflight.out" 2>"$base/commit-preflight.err" \
    || fail "MIME integration rejected its own final generation at commit preflight"
run_component_install "$base" "$base/runtime" --preflight-rollback "$txn" \
    >"$base/rollback-preflight.out" 2>"$base/rollback-preflight.err" \
    || fail "MIME integration rejected its own final generation at rollback preflight"
run_component_install "$base" "$base/runtime" --rollback "$txn" \
    >"$base/rollback.out" 2>"$base/rollback.err" \
    || fail "generated integration could not roll back with optional MIME state present"
grep -qxF 'application/x-unrelated=foreign-other.desktop' \
    "$base/xdg/config/mimeapps.list" \
    || fail "optional MIME publication or generated-file rollback corrupted an unrelated default"
grep -qxF 'x-scheme-handler/ableton=io.github.shibco.ableton-linux.protocol.desktop' \
    "$base/xdg/config/mimeapps.list" \
    || fail "generated-file rollback rewound the independently published Ableton default"
grep -qxF '# backend-serial=3' "$base/xdg/config/mimeapps.list" \
    || fail "generated-file rollback changed the optional MIME generation"
[ -x "$base/home/.local/bin/ableton-live" ] \
    || fail "component rollback removed an independently completed launcher repair"
[ -f "$txn/active" ] \
    || fail "MIME component rollback retired its coordinator-owned active marker"
ok "MIME defaults and completed generated files stay published across later component recovery"

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

base="$(new_env config-mid-read-race)"
config_path="$base/xdg/config/ableton-wine/config"
replacement="$base/config.replacement"
write_valid_managed_config "$config_path" "$base/runtime-a" "$base/prefix-a" \
    "$base/xdg/data/ableton-wine/linkd-a"
write_valid_managed_config "$replacement" "$base/runtime-b" "$base/prefix-b" \
    "$base/xdg/data/ableton-wine/linkd-b"
if run_isolated "$base" env \
    ABLETON_TEST_CONFIG_TARGET="$config_path" \
    ABLETON_TEST_CONFIG_REPLACEMENT="$replacement" \
    ABLETON_TEST_CONFIG_TRIGGER="$base/config-replaced" \
    bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        original_definition="$(declare -f ableton_config_file_value)"
        eval "${original_definition/ableton_config_file_value/ableton_config_file_value_original}"
        ableton_config_file_value()
        {
            local wanted="$1" value status=0
            value="$(ableton_config_file_value_original "$wanted")" || status=$?
            if [ "$wanted" = runtime_root ] && [ ! -e "${ABLETON_TEST_CONFIG_TRIGGER:?}" ]; then
                mv -T -- "${ABLETON_TEST_CONFIG_REPLACEMENT:?}" \
                    "${ABLETON_TEST_CONFIG_TARGET:?}"
                : > "${ABLETON_TEST_CONFIG_TRIGGER:?}"
            fi
            printf "%s\n" "$value"
            return "$status"
        }
        ableton_config_init
    ' _ "$here" >"$base/out" 2>"$base/err"; then
    fail "config init accepted values mixed across two atomic file generations"
fi
[ -e "$base/config-replaced" ] \
    || fail "mid-read configuration replacement fixture did not fire"
grep -qF 'installation configuration changed while it was being read; retry the command' \
    "$base/err" || fail "mid-read configuration race refusal was not explicit"
ok "config parsing binds every resolved field to one file generation"

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

base="$(new_env link-defaultable-config-repair)"
install_fake_host_tools "$base"
config_path="$base/xdg/config/ableton-wine/config"
mkdir -p -- "$(dirname "$config_path")"
cat > "$config_path" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
link_mode=session
EOF
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/setup-link.sh" disable >"$base/out" 2>"$base/err" \
    || fail "missing defaultable installer settings blocked Link disable"
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ableton_config_init strict
    ableton_managed_config_valid "$ABLETON_CONFIG_FILE"
' _ "$here" || fail "Link disable did not rebuild a valid installer configuration"
grep -qxF 'link_mode=off' "$config_path" \
    && grep -qxF "linkd=$base/xdg/data/ableton-wine/ableton-linkd" "$config_path" \
    || fail "Link disable did not default and save the missing installer settings"
ok "missing defaultable settings cannot gate a direct Link change"

base="$(new_env prefix-defaultable-config-repair)"
config_path="$base/xdg/config/ableton-wine/config"
mkdir -p -- "$(dirname "$config_path")" "$base/prefix"
cat > "$config_path" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
link_mode=off
EOF
printf 'WINE REGISTRY Version 2\n' > "$base/prefix/system.reg"
cat > "$base/hide-cabextract.bash" <<'EOF'
command()
{
    if [ "${1:-}" = -v ] && [ "${2:-}" = cabextract ]; then return 1; fi
    builtin command "$@"
}
EOF
run_isolated "$base" env BASH_ENV="$base/hide-cabextract.bash" \
    ABLETON_RUNTIME_PENDING=1 \
    bash "$here/setup-prefix.sh" --refresh --validate >"$base/out" 2>"$base/err" \
    || fail "unused cabextract or missing default settings blocked prefix refresh validation"
grep -qF -- '-- Wine prefix settings are valid' "$base/out" \
    || fail "direct prefix validation did not reach its successful result"
grep -qxF "runtime_root=$base/runtime" "$config_path" \
    || fail "prefix validation changed the project settings it only needed to read"
ok "unused cabextract and missing default settings cannot gate prefix refresh validation"

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
[ "$(grep -c '^== Check the Wine package:' "$base/out")" -eq 1 ] \
    || fail "public runtime plan validates and extracts its payload more than once"
if find "$base/tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'ableton-install-plan.*' -o -name 'ableton-runtime-validate.*' \) \
    -print -quit | grep -q .; then
    fail "public runtime plan leaked a component transaction or extracted runtime"
fi
[ ! -e "$base/xdg/state" ] \
    || fail "public runtime plan created persistent installer state"
ok "public runtime plans retire validation transactions and extracted payloads"

base="$(new_env plan-temp-cleanup-warning)"
make_runtime_only_kit "$base"
cat > "$base/refuse-preview-cleanup.bash" <<'EOF'
rm()
{
    local argument
    for argument in "$@"; do
        case "$argument" in
            */ableton-install-plan.*|*/ableton-runtime-validate.*) return 73 ;;
        esac
    done
    command rm "$@"
}
EOF
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    BASH_ENV="$base/refuse-preview-cleanup.bash" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/installer.sh" plan runtime install \
        --runtime-root "$base/runtime" --yes >"$base/out" 2>"$base/err" \
    || fail "private scratch cleanup failure changed a successful runtime plan"
grep -qF 'Checks finished, but temporary files remain at' "$base/err" \
    || fail "runtime plan scratch residue was not reported"
if ! find "$base/tmp" -mindepth 1 -maxdepth 1 \
    \( -name 'ableton-install-plan.*' -o -name 'ableton-runtime-validate.*' \) \
    -print -quit | grep -q .; then
    fail "runtime plan cleanup failure fixture did not retain its injected scratch path"
fi
ok "runtime plan success is independent of private scratch cleanup"

# A failed check is still only a check: it has no installed files to restore
# and must not manufacture a recovery record or rollback report.
for preview_kind in public-plan direct-validate; do
    base="$(new_env "failed-preview-${preview_kind}")"
    make_runtime_only_kit "$base"
    cat > "$base/fakebin/readelf" <<'EOF'
#!/bin/sh
cat <<'OUT'
  Shared library: [libusb-1.0.so.0]
  Shared library: [libpipewire-0.3.so.0]
  Shared library: [libgstreamer-1.0.so.0]
OUT
exit 93
EOF
    chmod 755 "$base/fakebin/readelf"
    if [ "$preview_kind" = public-plan ]; then
        preview_command=(bash "$base/kit/scripts/installer.sh" plan runtime install
            --runtime-root "$base/runtime" --yes)
    else
        preview_command=(bash "$base/kit/scripts/install.sh" --runtime-only --validate)
    fi
    if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
        PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
        "${preview_command[@]}" > "$base/out" 2> "$base/err"; then
        fail "$preview_kind ignored a failed runtime check"
    fi
    grep -qF 'runtime Push bridge dependency validation failed' "$base/err" \
        || fail "$preview_kind replaced the failed check's original cause"
    if grep -qF 'Earlier files were restored' "$base/err" \
       || grep -qF 'Restoring the files from before this attempt' "$base/err"; then
        fail "$preview_kind reported rollback for a check that changed no installed files"
    fi
    if find "$base" -name FAILURE -print -quit | grep -q .; then
        fail "$preview_kind wrote an installation failure record for a check"
    fi
    if find "$base/tmp" -mindepth 1 -maxdepth 1 \
        \( -name 'ableton-install-plan.*' -o -name 'ableton-runtime-validate.*' \) \
        -print -quit | grep -q .; then
        fail "$preview_kind leaked its failed-check scratch files"
    fi
done
ok "failed runtime checks preserve their cause without fake rollback or recovery state"

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

base="$(new_env config-repair-race)"
config_path="$base/xdg/config/ableton-wine/config"
mkdir -p -- "$(dirname "$config_path")"
cat > "$config_path" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/old-runtime
prefix=$base/custom-prefix
obsolete=first-generation
EOF
replacement="$base/config.replacement"
cat > "$replacement" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/replaced-runtime
prefix=$base/replaced-prefix
obsolete=second-generation
EOF
install_config_race_flock "$base"
make_runtime_only_kit "$base"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    ABLETON_TEST_FLOCK_MUTATED="$base/flock-mutated" \
    ABLETON_TEST_CONFIG_REPLACEMENT="$replacement" \
    ABLETON_TEST_CONFIG_TARGET="$config_path" \
    bash "$base/kit/scripts/installer.sh" runtime install \
        --runtime-root "$base/runtime" --yes >"$base/out" 2>"$base/err"; then
    fail "repair mode accepted a malformed config replaced before lock acquisition"
fi
[ -e "$base/flock-mutated" ] \
    || fail "malformed-config lock-race fixture did not replace its generation"
grep -qF 'installation configuration changed; retry the command' "$base/err" \
    || fail "malformed-config generation race did not report an exact retry"
[ ! -e "$base/runtime" ] \
    || fail "malformed-config generation race reached runtime promotion"
ok "repair mode binds salvaged values to one generation before any core mutation"

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
    enable)
        if [ "${ABLETON_TEST_WRITE_LINK_CONFIG:-0}" -eq 1 ]; then
            mkdir -p -- "$(dirname "${ABLETON_CONFIG_FILE:?}")"
            printf '# ableton-linux installer configuration; managed by the installer\nformat=1\nruntime_root=%s\nprefix=%s\nlive_major=%s\nlink_mode=%s\nlinkd=%s\n' \
                "${ABLETON_WINE_ROOT:?}" "${ABLETON_WINEPREFIX:?}" \
                "${ABLETON_LIVE_VERSION:-}" "${ABLETON_LINK_MODE:?}" \
                "${ABLETON_LINKD:?}" > "$ABLETON_CONFIG_FILE"
            : > "${ABLETON_TEST_CONFIG_RECHECK_MARKER:?}"
        fi
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

# The Link helper owns the write and postcondition for its saved setting. The
# parent must not add another checksum/read gate after the requested Link action
# has already succeeded.
base="$(new_env link-parent-config-recheck)"
make_commit_preflight_kit "$base"
call_log="$base/calls.log"
: > "$call_log"
mkdir -p -- "$base/fakebin"
real_sha256sum="$(command -v sha256sum)"
cat > "$base/fakebin/sha256sum" <<EOF
#!/bin/sh
if [ -e "\${ABLETON_TEST_CONFIG_RECHECK_MARKER:-}" ]; then
    case "\${1:-}" in
        --) checked="\${2:-}" ;;
        *) checked="\${1:-}" ;;
    esac
    if [ "\$checked" = "\${ABLETON_CONFIG_FILE:-}" ]; then
        /bin/rm -f -- "\$ABLETON_TEST_CONFIG_RECHECK_MARKER"
        exit 73
    fi
fi
exec "$real_sha256sum" "\$@"
EOF
chmod 755 "$base/fakebin/sha256sum"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_TEST_CALL_LOG="$call_log" \
    ABLETON_TEST_WRITE_LINK_CONFIG=1 \
    ABLETON_TEST_CONFIG_RECHECK_MARKER="$base/recheck-ready" \
    bash "$base/commit-kit/scripts/installer.sh" link enable --mode=session \
    > "$base/out" 2> "$base/err" \
    || fail "parent settings handling invented a failure after Link succeeded"
grep -qxF 'link_mode=session' "$base/xdg/config/ableton-wine/config" \
    || fail "Link helper did not publish the selected saved setting"
[ -e "$base/recheck-ready" ] \
    || fail "parent redundantly re-read the Link helper's generated setting"
! grep -qF 'saved setting could not be rechecked' "$base/err" \
    || fail "parent printed a redundant saved-setting diagnostic"
grep -qxF 'OK: Ableton Link is enabled (session)' "$base/out" \
    || fail "parent settings handling hid the successful Link outcome"
if grep -Eq -- '--rollback |^link rollback ' "$call_log"; then
    fail "parent settings handling rolled back a successful Link action"
fi
ok "the parent adds no generated-setting gate after successful Link setup"

make_pr182_custom_link_fixture()
{
    local base="$1" mode="$2" data state config custom digest id backup
    make_runtime_only_kit "$base"
    install_fake_host_tools "$base"
    # Model an unavailable user manager; Link disable must still complete from
    # its file/config state.
    printf '#!/bin/sh\nexit 1\n' > "$base/fakebin/systemctl"
    chmod 755 "$base/fakebin/systemctl"
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
        owned-stale-prestate)
            # Recognition is still backed by the exact PR182 release evidence,
            # but the old restoration journal is deliberately unusable. The
            # helper must stay live while canonical Link support is repaired.
            printf 'file\t%s\t%s\n' "$custom" "$digest" > "$state/install-manifest.tsv"
            mkdir -p -- "$state/install-prestate"
            printf 'stale recovery sentinel\n' > "$state/install-prestate/not-a-valid-slot"
            printf 'present\t%s\t/tmp/untrusted-pr182-backup\n' "$custom" \
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

# Publishing generated Link support files does not need to stop or restart a
# running daemon. The following controller deliberately fails if invoked: the
# file update must still succeed, leaving lifecycle changes to setup-link.sh.
base="$(new_env link-assets-ignore-running-state)"
make_pr182_custom_link_fixture "$base" unowned-off
canonical="$base/xdg/data/ableton-wine/ableton-linkd"
cp -- "$base/kit/bin/ableton-linkd" "$canonical"
chmod 755 "$canonical"
cat > "$base/kit/scripts/ableton-linkctl" <<'EOF'
#!/bin/sh
: > "${ABLETON_TEST_LINKCTL_CALLED:?}"
exit 73
EOF
chmod 755 "$base/kit/scripts/ableton-linkctl"
txn="$base/link-assets-transaction"
mkdir -p -- "$txn"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_LINKD="$canonical" \
    ABLETON_TEST_LINKCTL_CALLED="$base/link-controller-called" \
    bash "$base/kit/scripts/install.sh" --link-assets-only \
        --transaction-dir "$txn" >"$base/out" 2>"$base/err" \
    || fail "running Link state became a generated-file update gate"
[ ! -e "$base/link-controller-called" ] \
    || fail "Link asset publication invoked the lifecycle controller"
[ -x "$canonical" ] \
    && [ -x "$base/xdg/data/ableton-wine/ableton-linkctl" ] \
    && [ -x "$base/xdg/data/ableton-wine/setup-link.sh" ] \
    && [ -f "$base/xdg/data/ableton-wine/ableton-linkd.service" ] \
    || fail "Link asset publication did not replace its generated files"
ok "Link support files are replaced without a lifecycle failure gate"

# A repair that still needs Link support enters install.sh with the narrowly
# proven historical custom path already canonicalized by the coordinator. Bad
# legacy restoration data may prevent retirement, but must not block canonical
# support or mutate the custom helper.
base="$(new_env pr182-custom-link-stale-repair)"
make_pr182_custom_link_fixture "$base" owned-stale-prestate
custom="$PR182_CUSTOM_LINK"
canonical="$base/xdg/data/ableton-wine/ableton-linkd"
txn="$base/link-repair-transaction"
mkdir -p -- "$txn"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_PR182_CUSTOM_LINKD="$custom" ABLETON_LINKD="$canonical" \
    bash "$base/kit/scripts/install.sh" --link-assets-only \
        --transaction-dir "$txn" >"$base/out" 2>"$base/err" \
    || fail "stale PR182 recovery data aborted canonical Link repair"
grep -qxF 'historical PR182 Link binary' "$custom" \
    || fail "stale PR182 recovery data changed the custom helper"
grep -qF 'Kept the older custom Link helper because its saved recovery data could not be used safely.' \
    "$base/err" || fail "stale PR182 recovery data did not produce its plain warning"
grep -qxF 'stale recovery sentinel' \
    "$(dirname "$PR182_PRESTATE_INDEX")/install-prestate/not-a-valid-slot" \
    || fail "PR182 repair consumed an unverifiable recovery object"
[ -x "$canonical" ] \
    && [ -x "$base/xdg/data/ableton-wine/ableton-linkctl" ] \
    && [ -x "$base/xdg/data/ableton-wine/setup-link.sh" ] \
    && [ -f "$base/xdg/data/ableton-wine/ableton-linkd.service" ] \
    || fail "stale PR182 recovery data prevented canonical Link support repair"
if awk -F '\t' -v p="$custom" '$2==p { found=1 } END { exit !found }' \
    "$PR182_MANIFEST"; then
    fail "stale PR182 helper retained an obsolete ownership row after repair"
fi
run_component_install "$base" "$base/runtime" --preflight-commit "$txn" \
    >"$base/preflight.out" 2>"$base/preflight.err" \
    || fail "stale PR182 recovery data poisoned canonical Link commit preflight"
ok "stale PR182 recovery data keeps the custom helper while canonical Link support is repaired"

# Disabling Link no longer stages support files just to delete them. It keeps
# every external custom helper and its historical recovery object untouched,
# while pruning obsolete ownership rows and saving the canonical disabled
# configuration for a proven PR182 release.
for migration_mode in owned-prestate owned-stale-prestate modified unowned-off; do
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
            grep -qxF 'historical PR182 Link binary' "$custom" \
                || fail "Link disable changed the historical custom helper"
            awk -F '\t' -v p="$custom" '$2==p { found=1 } END { exit !found }' \
                "$PR182_PRESTATE_INDEX" \
                || fail "Link disable consumed the custom helper's historical recovery row"
            ;;
        owned-stale-prestate)
            grep -qxF 'historical PR182 Link binary' "$custom" \
                || fail "Link disable changed the helper with stale PR182 recovery data"
            grep -qxF 'stale recovery sentinel' \
                "$(dirname "$PR182_PRESTATE_INDEX")/install-prestate/not-a-valid-slot" \
                || fail "Link disable consumed an unverifiable custom recovery object"
            ;;
        modified)
            grep -qxF 'user modified former PR182 Link binary' "$custom" \
                || fail "Link disable overwrote a user-modified PR182 helper"
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
    for generated_link_file in ableton-linkd ableton-linkctl setup-link.sh ableton-linkd.service; do
        [ ! -e "$base/xdg/data/ableton-wine/$generated_link_file" ] \
            && [ ! -L "$base/xdg/data/ableton-wine/$generated_link_file" ] \
            || fail "Link disable retained canonical support file $generated_link_file"
    done
    if [ "$migration_mode" != unowned-off ]; then
        grep -qxF "linkd=$base/xdg/data/ableton-wine/ableton-linkd" "$PR182_CONFIG" \
            || fail "verified PR182 custom-Link ownership was not migrated to the canonical path"
    fi
done
ok "Link disable preserves PR182 custom helpers while removing canonical support and stale ownership rows"

printf 'PASS: %s focused PipeASIO installer checks\n' "$pass"
