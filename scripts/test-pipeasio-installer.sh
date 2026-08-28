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
. "$here/lib/ui.sh"
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
[ -z "${PROBE_COUNT_FILE:-}" ] || printf 'probe\n' >> "$PROBE_COUNT_FILE"
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
        /bin/bash -c '. "$1/lib/ui.sh"; . "$1/lib/pipeasio.sh"; ableton_pipewire_preflight "$2"' \
        _ "$here" "$probe"
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

probe_count="$probe_base/count"
env PATH="$probe_base/core-path" PROBE_CLIENT=1.6.8 PROBE_DAEMON=1.6.8 \
    PROBE_COUNT_FILE="$probe_count" ABLETON_PIPEWIRE_PREFLIGHT_CACHE=1 \
    /bin/bash -c '. "$1/lib/ui.sh"; . "$1/lib/pipeasio.sh"; ableton_pipewire_preflight "$2"; ableton_pipewire_preflight "$2"' \
    _ "$here" "$probe" >/dev/null
[ "$(wc -l < "$probe_count")" -eq 1 ] || fail "one installer run repeated its PipeWire check"
ok "one installer run checks PipeWire once"

# Once the native probe and version comparison have succeeded, their terminal
# report is presentation only. Optional-tool advice is presentation from the
# outset. A closed stdout must not turn either into a component/rollback error.
if ! env PATH="$probe_base/core-path" \
    PROBE_CLIENT=1.6.8 PROBE_DAEMON=1.6.8 PROBE_EXIT=0 \
    /bin/bash -c '
        set -euo pipefail
        . "$1/lib/ui.sh"
        . "$1/lib/pipeasio.sh"
        ableton_pipewire_preflight "$2" >&-
        ABLETON_PIPEASIO_DIAGNOSTIC_NOTICE_SHOWN=0
        ableton_pipeasio_optional_tools_advice >&-
    ' _ "$here" "$probe" 2>/dev/null; then
    fail "successful PipeWire proof or optional-tool advice inherited terminal output status"
fi
ok "successful compatibility proof and optional-tool advice ignore presentation failures"

base="$(new_env mutation-lock)"
mkdir -p -- "$base/xdg/state/ableton-wine"
printf 'format=1\nowner=ableton-linux\n' \
    > "$base/xdg/state/ableton-wine/.ableton-linux-state"
exec {held_lock_fd}< "$base/home"
flock -n "$held_lock_fd" || fail "could not create mutation-lock fixture"
# A child in the same installer command inherits the descriptor and may
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
    bash "$here/setup-link.sh" disable \
    >"$base/setup-link.out" 2>"$base/setup-link.err"; then
    fail "direct setup-link mutator bypassed the held installation lock"
fi
grep -qF 'Another Ableton Linux install, repair, or removal is already running. Wait for it to finish and try again.' \
    "$base/setup-link.err" || fail "setup-link lock refusal was not explicit"
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
        "$here/lib/manifest.sh" "$here/lib/pipeasio.sh" "$here/lib/ui.sh" \
        "$kit/scripts/lib/"
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
[ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "direct runtime-only reconcile created obsolete ownership records"
grep -qF 'The Wine runtime is ready.' "$base/out" \
    || fail "direct runtime-only install did not print its simple outcome"
ok "direct runtime-only install leaves previously absent panel paths alone without ownership records"

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
    run_isolated "$base" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init strict
        ableton_managed_config_valid "$ABLETON_CONFIG_FILE"
    ' _ "$here" || fail "$config_kind settings were not replaced by a valid generation"
    grep -qxF "runtime_root=$base/runtime" "$config_path" \
        || fail "$config_kind settings replacement did not keep the CLI runtime"
    config_backup="$(find "$base/xdg/state/ableton-wine/backups" \
        -name 'config.bak-*' -print -quit 2>/dev/null || true)"
    [ -n "$config_backup" ] \
        || fail "$config_kind settings replacement did not retain an inert backup"
    case "$config_kind" in
        foreign-regular)
            grep -qxF 'foreign arbitrary settings' "$config_backup" \
                || fail "regular settings backup changed the displaced bytes" ;;
        symlink)
            [ -L "$config_backup" ] \
                && [ "$(readlink -- "$config_backup")" = "$base/foreign-config" ] \
                && grep -qxF 'foreign symlink referent' "$base/foreign-config" \
                || fail "symlink settings backup changed the link or its referent" ;;
        directory)
            [ -d "$config_backup" ] && [ ! -L "$config_backup" ] \
                && grep -qxF 'foreign directory sentinel' "$config_backup/sentinel" \
                || fail "directory settings backup changed the displaced tree" ;;
    esac
    [ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
        && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
        || fail "$config_kind settings replacement created obsolete ownership records"
done
ok "settings objects cannot gate Wine and are moved to inert backups before replacement"

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
printf()
{
    if [ "${1:-}" = '%s        %s\n' ] \
       && [ "${2:-}" = ' ' ] \
       && [ "${3:-}" = 'the Wine runtime is installed ✓' ]; then
        return 74
    fi
    builtin printf "$@"
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
grep -qF "Runtime: $base/runtime" "$base/out" \
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
    || fail "postcommit panel replacement invalidated a runtime install"
[ -f "$base/runtime/.ableton-linux-runtime" ] \
    || fail "panel replacement displaced the committed runtime"
[ -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ "$(readlink -- "$base/home/.local/bin/pipeasio-settings")" \
        = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "panel replacement did not install the fixed command link"
panel_backup="$(find "$base/xdg/state/ableton-wine/backups" \
    -type d -name 'pipeasio-settings.bak-*' -print -quit)"
[ -n "$panel_backup" ] \
    && grep -qxF 'foreign directory sentinel' "$panel_backup/sentinel" \
    || fail "panel replacement did not preserve the displaced directory as an inert backup"
[ -f "$base/xdg/data/applications/pipeasio-settings.desktop" ] \
    && [ -f "$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg" ] \
    || fail "panel replacement did not continue through the remaining fixed paths"
[ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "panel replacement created obsolete ownership records"
ok "direct runtime panel repair runs postcommit with one inert backup"

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
[ -L "$base/home/.local/bin/pipeasio-settings" ] \
    && [ "$(readlink -- "$base/home/.local/bin/pipeasio-settings")" \
        = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "incomplete panel payload did not install its available command mapping"
panel_backup="$(find "$base/xdg/state/ableton-wine/backups" \
    -type f -name 'pipeasio-settings.bak-*' -print -quit)"
[ -n "$panel_backup" ] \
    && grep -qxF 'foreign panel command' "$panel_backup" \
    || fail "incomplete panel payload lost the inert command backup"
[ -f "$base/xdg/data/applications/pipeasio-settings.desktop" ] \
    && [ ! -e "$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg" ] \
    || fail "incomplete panel payload did not continue its independent mappings"
grep -qF "copy failed: $base/runtime/share/icons/hicolor/scalable/apps/pipeasio.svg -> $base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg" \
    "$base/err" || fail "incomplete panel payload did not report the actual failed path"
grep -qF 'Wine was installed, but the PipeASIO settings shortcut could not be updated.' \
    "$base/err" || fail "incomplete panel payload did not produce its postcommit warning"
ok "incomplete panel mappings report their path without invalidating Wine or earlier copies"

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
grep -qF 'The Wine runtime is ready.' "$base/out" \
    || fail "verified-core EXIT catch-all omitted the direct success outcome"
ok "the EXIT catch-all cannot fail or roll back a finally validated runtime"

# A direct mixed invocation must close its runtime transaction before generated
# desktop work starts. Inject a copy failure in the first fixed destination:
# Wine stays live, the displaced file remains as an inert backup, later copies
# continue, and no active core marker is left for launchers to reject.
base="$(new_env direct-mixed-optional-failure)"
prepare_runtime_metadata_fixture "$base"
prepare_mixed_component_kit "$base"
foreign_optional="$base/xdg/data/ableton-wine/lib/config.sh"
mkdir -p -- "$(dirname "$foreign_optional")"
printf 'foreign optional config helper\n' > "$foreign_optional"
cp -a -- "$foreign_optional" "$base/foreign-optional.before"
real_cp="$(command -v cp)"
cat > "$base/fakebin/cp" <<EOF
#!/bin/sh
last=""
for argument do last="\$argument"; done
if [ "\$last" = "$foreign_optional" ] \
   && [ -f "$base/runtime/.ableton-linux-runtime" ] \
   && [ ! -e "$base/mixed-optional-failure-fired" ]; then
    : > "$base/mixed-optional-failure-fired"
    exit 74
fi
exec "$real_cp" "\$@"
EOF
chmod 755 "$base/fakebin/cp"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    PROBE_CLIENT=1.4.2 PROBE_DAEMON=1.4.2 \
    bash "$base/kit/scripts/install.sh" --runtime-only --integration-only --yes \
    >"$base/out" 2>"$base/err" \
    || fail "optional mixed-mode failure invalidated a committed runtime"
[ -e "$base/mixed-optional-failure-fired" ] \
    || fail "mixed-mode fixture did not reach optional file publication"
[ ! -e "$foreign_optional" ] && [ ! -L "$foreign_optional" ] \
    || fail "failed optional copy restored or partially published its destination"
foreign_backup="$(find "$base/xdg/state/ableton-wine/backups" \
    -type f -name 'config.sh.bak-*' -print -quit)"
[ -n "$foreign_backup" ] \
    && cmp -s -- "$base/foreign-optional.before" "$foreign_backup" \
    || fail "failed optional copy lost the inert displaced-file backup"
cmp -s -- "$base/kit/scripts/lib/lifecycle.sh" \
    "$base/xdg/data/ableton-wine/lib/lifecycle.sh" \
    || fail "one failed support file blocked a later independent repair"
[ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "mixed-mode optional copy created obsolete ownership records"
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
grep -qF "copy failed: $base/kit/scripts/lib/config.sh -> $foreign_optional" \
    "$base/err" || fail "mixed-mode optional failure did not report the actual path"
grep -qF 'The Wine runtime is ready.' "$base/out" \
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
    bash "$base/kit/scripts/install.sh" --integration-only --yes \
    >"$base/advisory.out" 2>"$base/advisory.err" \
    || advisory_status=$?
[ "$advisory_status" -eq 3 ] \
    || fail "internal desktop repair result did not distinguish a retry warning"
[ -e "$base/mixed-optional-failure-fired" ] \
    || fail "internal desktop repair fixture did not reach its injected warning"
! grep -q 'are ready\.' "$base/advisory.out" \
    || fail "internal retry result also printed a complete result"
ok "desktop repair warnings have an internal advisory result for the final summary"

# Each completed generated-file repair is final. Break stderr and fail after
# the first repair; later failure handling must leave that valid repair in
# place and must leave its displaced input only in the inert backup tree.
base="$(new_env component-recovery-broken-stderr)"
make_runtime_only_kit "$base"
prepare_mixed_component_kit "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
foreign_optional="$base/xdg/data/ableton-wine/lib/config.sh"
mkdir -p -- "$(dirname "$foreign_optional")"
printf 'foreign helper before failed component\n' > "$foreign_optional"
cp -a -- "$foreign_optional" "$base/foreign-helper.before"
sed -i '/ableton_install_project_file 644 "$here\/lib\/$tool" "$data\/lib\/$tool"/a\
        if [ "$tool" = config.sh ]; then exec 2>/dev/full; false; fi' \
    "$base/kit/scripts/install.sh"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash "$base/kit/scripts/install.sh" --integration-only --yes \
    >"$base/out" 2>"$base/err"; then
    fail "injected component failure unexpectedly reported success"
fi
cmp -s -- "$base/kit/scripts/lib/config.sh" "$foreign_optional" \
    || fail "a later optional failure undid an earlier generated-file repair"
foreign_backup="$(find "$base/xdg/state/ableton-wine/backups" \
    -type f -name 'config.sh.bak-*' -print -quit)"
[ -n "$foreign_backup" ] \
    && cmp -s -- "$base/foreign-helper.before" "$foreign_backup" \
    || fail "broken diagnostics lost the inert displaced-file backup"
[ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "broken diagnostics created obsolete ownership records"
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
    "$here/lib/pipeasio.sh" "$here/lib/ui.sh" "$base/kit/scripts/lib/"
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
    "$here/lib/pipeasio.sh" "$here/lib/ui.sh" "$base/kit/scripts/lib/"
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
grep -qF 'The Wine runtime is ready.' "$base/out" \
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
    grep -qF 'The Wine runtime is ready.' "$base/out" \
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
[ "$(grep -c 'Check the Wine package' "$base/out")" -eq 1 ] \
    || fail "runtime install validates and extracts its payload more than once"
grep -qF '│  ├─ Check the Wine package ' "$base/out" \
    || fail "runtime operation omitted its nested tree branch"
grep -Eq '^│  │  > .* is valid$' "$base/out" \
    || fail "runtime result was not shown beneath its operation"
saved_runtime="$(find_saved_runtime "$base")" \
    || fail "runtime update did not retain a saved runtime"
saved_meta="$saved_runtime/.ableton-linux-rollback"
[ ! -e "$saved_runtime/.ableton-linux-rollback-incomplete" ] \
    || fail "saved runtime remained sealed after core commit"
grep -qxF 'old metadata generation' "$saved_meta/old-sentinel" \
    && grep -qxF 'format=0' "$saved_meta/metadata" \
    || fail "runtime update rewrote files inside the saved Wine tree"
[ ! -e "$saved_meta/installer-config" ] \
    && [ ! -e "$saved_meta/pipeasio-config.ini" ] \
    || fail "runtime update created automatic settings-restoration snapshots"
if find "$saved_runtime" -maxdepth 1 -name '.ableton-linux-rollback.new.*' -print -quit \
    | grep -q .; then
    fail "runtime update left an obsolete settings-snapshot staging directory"
fi
ok "runtime update publishes the saved Wine tree without optional settings snapshots"

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
[ -L "$panel_command" ] || fail "panel command was not installed as a managed symlink"
[ "$(readlink -- "$panel_command")" = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "panel command points outside the selected runtime"
[ -f "$panel_desktop" ] && [ -f "$panel_icon" ] || fail "panel desktop/icon ignored custom XDG data home"
[ ! -e "$base/home/.local/share/applications/pipeasio-settings.desktop" ] \
    || fail "panel desktop escaped custom XDG data home"
live_options="$base/xdg/data/ableton-wine/lib/live-options.sh"
[ -f "$live_options" ] && [ "$(stat -c '%a' "$live_options")" = 644 ] \
    || fail "The installer writes the audio thread settings script with mode 644."
cmp -s -- "$here/lib/live-options.sh" "$live_options" \
    || fail "The installed audio thread settings script matches its source file."
[ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "built panel created obsolete ownership records"
ok "built panel installs its fixed paths under custom XDG roots"

user_panel_target="$base/user-retargeted-pipeasio-settings"
rm -f -- "$panel_command"
ln -s -- "$user_panel_target" "$panel_command"
printf '\n# local panel launcher drift\n' >> "$panel_desktop"
run_component_install "$base" "$base/runtime" --integration-only --yes \
    >"$base/install-drift.out" 2>"$base/install-drift.err" \
    || { sed -n '1,80p' "$base/install-drift.err" >&2; fail "panel launcher drift aborted integration"; }
[ -L "$panel_command" ] \
    && [ "$(readlink -- "$panel_command")" = "$base/runtime/bin/pipeasio-settings" ] \
    || fail "integration did not replace the retargeted panel command"
panel_command_backup="$(find "$base/xdg/state/ableton-wine/backups" \
    -type l -name 'pipeasio-settings.bak-*' -print -quit)"
[ -n "$panel_command_backup" ] \
    && [ "$(readlink -- "$panel_command_backup")" = "$user_panel_target" ] \
    || fail "panel command backup is not the displaced symlink"
! grep -qF '# local panel launcher drift' "$panel_desktop" \
    || fail "integration left drift in the panel desktop entry"
panel_desktop_backup="$(find "$base/xdg/state/ableton-wine/backups" \
    -type f -name 'pipeasio-settings.desktop.bak-*' -print -quit)"
grep -qF '# local panel launcher drift' "$panel_desktop_backup" \
    || fail "panel desktop backup does not contain the displaced entry"
mapfile -t panel_backup_runs < <(find "$base/xdg/state/ableton-wine/backups" \
    -mindepth 1 -maxdepth 1 -type d)
[ "${#panel_backup_runs[@]}" -eq 1 ] \
    || fail "panel replacements did not use one per-run backup directory"
case "$panel_command_backup:$panel_desktop_backup" in
    "${panel_backup_runs[0]}"/*:"${panel_backup_runs[0]}"/*) ;;
    *) fail "panel replacements escaped their per-run backup directory" ;;
esac
[ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "panel replacement created obsolete ownership records"
ok "PipeASIO panel paths are moved to the central backup tree and replaced"

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

# A skipped panel payload does not remove, restore, or reinterpret existing host
# files. Earlier overwrite backups remain inert manual recovery objects.
panel_command_target_before="$(readlink -- "$panel_command")"
panel_desktop_digest_before="$(sha256sum -- "$panel_desktop" | awk '{print $1}')"
panel_icon_digest_before="$(sha256sum -- "$panel_icon" | awk '{print $1}')"
panel_backup_digest_before="$(sha256sum -- "$panel_desktop_backup" | awk '{print $1}')"
write_build_info "$base/runtime" "$base/BUILD-INFO.txt" skipped
run_component_install "$base" "$base/runtime" --integration-only --yes \
    >"$base/install-skipped.out" 2>"$base/install-skipped.err" \
    || fail "skipped-panel integration failed"
[ -L "$panel_command" ] \
    && [ "$(readlink -- "$panel_command")" = "$panel_command_target_before" ] \
    && [ "$(sha256sum -- "$panel_desktop" | awk '{print $1}')" = "$panel_desktop_digest_before" ] \
    && [ "$(sha256sum -- "$panel_icon" | awk '{print $1}')" = "$panel_icon_digest_before" ] \
    || fail "skipped panel payload changed existing panel paths"
[ "$(sha256sum -- "$panel_desktop_backup" | awk '{print $1}')" = "$panel_backup_digest_before" ] \
    || fail "skipped panel payload changed an inert backup"
grep -qF 'PipeASIO Settings was not packaged; existing shortcut files were left unchanged' \
    "$base/install-skipped.out" \
    || fail "skipped panel payload did not report that existing paths were kept"
ok "skipped panel payload leaves panel paths and inert backups unchanged"

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

# Keep leaves the current panel command unchanged and continues through later panel paths.
base="$(new_env panel-choice-keep)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
panel_command="$base/home/.local/bin/pipeasio-settings"
panel_desktop="$base/xdg/data/applications/pipeasio-settings.desktop"
panel_icon="$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg"
mkdir -p -- "$(dirname "$panel_command")"
printf 'keep this panel command\n' > "$panel_command"
if ! printf 'Keep\n' | run_component_install "$base" "$base/runtime" --integration-only \
        >"$base/out" 2>"$base/err"; then
    fail "Keep stopped the panel mapping loop"
fi
grep -qxF "$panel_command exists." "$base/err" \
    || fail "panel Keep prompt did not name its destination"
grep -qF '│  ├─ QUESTION: Some files from an earlier installation already exist.' "$base/out" \
    || fail "panel Keep choice did not show the required prompt"
grep -qxF 'keep this panel command' "$panel_command" \
    || fail "panel Keep choice changed its destination"
[ -f "$panel_desktop" ] && [ -f "$panel_icon" ] \
    || fail "panel Keep choice prevented later panel mappings"
if [ -d "$base/xdg/state/ableton-wine/backups" ] \
   && find "$base/xdg/state/ableton-wine/backups" -name 'pipeasio-settings.bak-*' \
        -print -quit | grep -q .; then
    fail "panel Keep choice created a backup for an unchanged destination"
fi
ok "Keep leaves the panel command unchanged and continues through later panel mappings"

# Cancel keeps the current panel command, retains earlier integration copies,
# and prevents every later panel mapping.
base="$(new_env panel-choice-cancel)"
install_fake_host_tools "$base"
make_runtime "$base/runtime" "$base/BUILD-INFO.txt" built
panel_command="$base/home/.local/bin/pipeasio-settings"
panel_desktop="$base/xdg/data/applications/pipeasio-settings.desktop"
panel_icon="$base/xdg/data/icons/hicolor/scalable/apps/pipeasio.svg"
mkdir -p -- "$(dirname "$panel_command")"
printf 'cancel before replacing this command\n' > "$panel_command"
cancel_status=0
printf 'a\n' | run_component_install "$base" "$base/runtime" --integration-only \
    >"$base/out" 2>"$base/err" || cancel_status=$?
[ "$cancel_status" -eq 4 ] || fail "panel Cancel did not return the cancellation status"
grep -qxF "$panel_command exists." "$base/err" \
    || fail "panel Cancel prompt did not name its destination"
grep -qF '│  ├─ QUESTION: Some files from an earlier installation already exist.' "$base/out" \
    || fail "panel Cancel choice did not show the required prompt"
grep -qxF 'cancel before replacing this command' "$panel_command" \
    || fail "panel Cancel choice changed its destination"
[ -f "$base/xdg/data/ableton-wine/lib/live-options.sh" ] \
    || fail "panel Cancel unwound an earlier completed integration copy"
[ ! -e "$panel_desktop" ] && [ ! -e "$panel_icon" ] \
    || fail "panel Cancel did not stop later panel mappings"
[ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "panel choices created obsolete ownership records"
ok "Cancel stops later panel mappings without unwinding earlier copies"

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
        "$(dirname "$ROLLBACK_PIPEASIO_CONFIG")"
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
    "$saved"
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
cp -- "$installer_config" "$base/installer-config.before-rollback"
cp -- "$pipeasio_config" "$base/pipeasio-config.before-rollback"

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
cmp -s -- "$installer_config" "$base/installer-config.before-rollback" \
    && cmp -s -- "$pipeasio_config" "$base/pipeasio-config.before-rollback" \
    || fail "user-facing runtime rollback changed current settings"
reverse=""
for candidate in "$base"/runtime-rollback-*; do
    [ -f "$candidate/current-generation" ] || continue
    reverse="$candidate"
    break
done
[ -n "$reverse" ] \
    || fail "user-facing rollback did not leave a reversible runtime sibling"
grep -Fq "$base/prefix"$'\tregsvr32 /s pipeasio64.dll' "$base/registry.log" \
    || fail "user-facing rollback did not register the restored driver in its prefix"
ok "user-facing rollback restores the marked runtime and PipeASIO registration without changing settings"

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
    fail "failed runtime rollback changed active configuration"
fi
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
        && grep -qF 'live_major=12' "$ROLLBACK_INSTALLER_CONFIG" \
        && grep -qF 'buffer_size = 512' "$ROLLBACK_PIPEASIO_CONFIG" \
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
run_component_install "$base" "$base/runtime" --integration-only --yes \
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
run_component_install "$base" "$base/runtime" --integration-only --yes >"$base/out" 2>"$base/err" \
    || fail "staged MIME failure aborted generated integration"
grep -qF 'Could not set Ableton as the default app for Live files. Ableton itself can still be used normally.' \
    "$base/err" || fail "staged MIME failure did not produce its plain warning"
cmp -s -- "$base/xdg/config/mimeapps.list" <(printf '[Default Applications]\nx-scheme-handler/ableton=foreign.desktop\n') \
    || fail "staged MIME failure mutated the live mimeapps file"
[ -x "$base/home/.local/bin/ableton-live" ] \
    || fail "staged MIME failure rolled back the generated launcher"
ok "MIME staging failure warns, preserves live associations, and keeps generated integration"


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
run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_PROJECT_ASSUME_YES=1 \
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
grep -qF -- 'Wine prefix settings are valid' "$base/out" \
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
[ "$(grep -c 'Check the Wine package' "$base/out")" -eq 1 ] \
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


# Link support is another fixed mapping set. Replacing one existing path moves
# that object into the per-run inert backup tree; it never invokes the Link
# lifecycle controller and never creates ownership or recovery journals.
base="$(new_env link-assets-fixed-paths)"
make_runtime_only_kit "$base"
cp -- "$here/setup-link.sh" "$here/ableton-linkctl" \
    "$here/ableton-linkd.service" "$base/kit/scripts/"
cat > "$base/kit/bin/ableton-linkd" <<'EOF'
#!/bin/sh
echo 'fixture Link daemon'
EOF
chmod 755 "$base/kit/bin/ableton-linkd"
canonical="$base/xdg/data/ableton-wine/ableton-linkd"
mkdir -p -- "$(dirname "$canonical")"
printf 'foreign Link helper\n' > "$canonical"
chmod 755 "$canonical"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINKD="$canonical" \
    bash "$base/kit/scripts/install.sh" --link-assets-only --yes \
    >"$base/out" 2>"$base/err" \
    || fail "fixed Link support mappings failed"
[ -x "$canonical" ] \
    && [ -x "$base/xdg/data/ableton-wine/ableton-linkctl" ] \
    && [ -x "$base/xdg/data/ableton-wine/setup-link.sh" ] \
    && [ -f "$base/xdg/data/ableton-wine/ableton-linkd.service" ] \
    && [ -f "$base/xdg/config/systemd/user/ableton-linkd.service" ] \
    || fail "Link support did not install every fixed destination"
link_backup="$(find "$base/xdg/state/ableton-wine/backups" \
    -type f -name 'ableton-linkd.bak-*' -print -quit)"
[ -n "$link_backup" ] && grep -qxF 'foreign Link helper' "$link_backup" \
    || fail "Link support did not retain the displaced helper as an inert backup"
[ ! -e "$base/xdg/state/ableton-wine/install-manifest.tsv" ] \
    && [ ! -e "$base/xdg/state/ableton-wine/install-prestate.tsv" ] \
    || fail "Link support created obsolete ownership records"
ok "Link support uses fixed destinations and inert central backups"

printf 'PASS: %s focused PipeASIO installer checks\n' "$pass"
