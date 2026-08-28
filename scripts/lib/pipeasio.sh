#!/usr/bin/env bash
# Shared PipeASIO release policy, payload validation, panel integration, and
# exact registry lifecycle.  Callers source config.sh and manifest.sh first.

# This is a release support boundary, not a compatibility knob.  Assignment is
# intentional: an exported variable cannot weaken the gate.
readonly ABLETON_PIPEWIRE_FLOOR=1.4.2
readonly ABLETON_PIPEASIO_CLSID='{2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}'
readonly ABLETON_PIPEASIO_ASIO_KEY='HKLM\Software\ASIO\PipeASIO'
readonly ABLETON_PIPEASIO_CLASS_KEY="HKCR\\CLSID\\$ABLETON_PIPEASIO_CLSID"

: "${ABLETON_PIPEWIRE_CLIENT_VERSION:=}"
: "${ABLETON_PIPEWIRE_DAEMON_VERSION:=}"
ABLETON_PIPEASIO_DIAGNOSTIC_NOTICE_SHOWN=0

ableton_pipewire_version_core()
{
    local value="${1:-}"
    if [[ "$value" =~ ^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})([-+~][0-9A-Za-z._~-]+)?$ ]]; then
        printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        return 1
    fi
}

ableton_pipewire_version_ge()
{
    local actual_text="${1:-}" actual required amaj amin apat rmaj rmin rpat
    actual="$(ableton_pipewire_version_core "$actual_text")" || return 1
    required="$(ableton_pipewire_version_core "${2:-}")" || return 1
    IFS=. read -r amaj amin apat <<< "$actual"
    IFS=. read -r rmaj rmin rpat <<< "$required"
    if (( 10#$amaj != 10#$rmaj )); then (( 10#$amaj > 10#$rmaj )); return; fi
    if (( 10#$amin != 10#$rmin )); then (( 10#$amin > 10#$rmin )); return; fi
    if (( 10#$apat != 10#$rpat )); then (( 10#$apat > 10#$rpat )); return; fi
    # PipeWire uses upstream-style versions, while distro package versions may
    # append packaging/build metadata.  A leading '~' suffix denotes a
    # prerelease of this numeric triplet and is therefore below its final
    # release; '-' and '+' suffixes describe the final release and remain valid.
    [[ "$actual_text" != "${actual}~"* ]]
}

# PROBE is the bundled native helper.  It calls pw_get_library_version() in the
# process that loaded libpipewire and obtains pw_core_info.version from the
# connected daemon; command-line PipeWire utilities are deliberately irrelevant.
ableton_pipewire_preflight()
{
    local probe="${1:?PipeWire probe path required}" purpose="${2:-using PipeASIO}"
    local output client daemon client_count daemon_count
    if [ "${ABLETON_PIPEWIRE_PREFLIGHT_CACHE:-0}" = 1 ] \
       && [ "${ABLETON_PIPEWIRE_PREFLIGHT_DONE:-0}" = 1 ] \
       && ableton_pipewire_version_ge "$ABLETON_PIPEWIRE_CLIENT_VERSION" "$ABLETON_PIPEWIRE_FLOOR" \
       && ableton_pipewire_version_ge "$ABLETON_PIPEWIRE_DAEMON_VERSION" "$ABLETON_PIPEWIRE_FLOOR"; then
        return 0
    fi
    ABLETON_PIPEWIRE_CLIENT_VERSION=""
    ABLETON_PIPEWIRE_DAEMON_VERSION=""

    [ -x "$probe" ] || {
        printf '!! PipeWire compatibility cannot be checked before %s.\n' "$purpose" >&2
        printf '!! Reinstall from a complete installer kit and try again.\n' >&2
        return 1
    }
    if ! output="$(LC_ALL=C "$probe" 2>/dev/null)"; then
        printf '!! PipeWire is unavailable; start the desktop audio service and try again.\n' >&2
        return 1
    fi
    client_count="$(printf '%s\n' "$output" | grep -c '^client=' || true)"
    daemon_count="$(printf '%s\n' "$output" | grep -c '^daemon=' || true)"
    [ "$client_count" -eq 1 ] && [ "$daemon_count" -eq 1 ] \
        && [ "$(printf '%s\n' "$output" | sed '/^client=/d;/^daemon=/d;/^$/d' | wc -l)" -eq 0 ] || {
        printf '!! PipeWire returned an unreadable version result; nothing was changed.\n' >&2
        return 1
    }
    client="${output#*client=}"
    client="${client%%$'\n'*}"
    daemon="${output#*daemon=}"
    daemon="${daemon%%$'\n'*}"
    ableton_pipewire_version_core "$client" >/dev/null || {
        printf '!! PipeWire returned an unreadable client version; nothing was changed.\n' >&2
        return 1
    }
    ableton_pipewire_version_core "$daemon" >/dev/null || {
        printf '!! PipeWire reported an unreadable version; nothing was changed.\n' >&2
        return 1
    }
    # The observations are intentionally available to callers and tests.
    # shellcheck disable=SC2034
    ABLETON_PIPEWIRE_CLIENT_VERSION="$client"
    # shellcheck disable=SC2034
    ABLETON_PIPEWIRE_DAEMON_VERSION="$daemon"

    if ! ableton_pipewire_version_ge "$client" "$ABLETON_PIPEWIRE_FLOOR"; then
        printf '!! PipeWire client %s is unsupported; version %s or newer is required.\n' \
            "$client" "$ABLETON_PIPEWIRE_FLOOR" >&2
        printf '!! Upgrade the complete PipeWire stack, then retry. Nothing was changed.\n' >&2
        return 1
    fi
    if ! ableton_pipewire_version_ge "$daemon" "$ABLETON_PIPEWIRE_FLOOR"; then
        printf '!! PipeWire service %s is unsupported; version %s or newer is required.\n' \
            "$daemon" "$ABLETON_PIPEWIRE_FLOOR" >&2
        printf '!! Upgrade the complete PipeWire stack, then retry. Nothing was changed.\n' >&2
        return 1
    fi
    if [ "${ABLETON_PIPEWIRE_PREFLIGHT_CACHE:-0}" = 1 ]; then
        ABLETON_PIPEWIRE_PREFLIGHT_DONE=1
        export ABLETON_PIPEWIRE_PREFLIGHT_DONE
        export ABLETON_PIPEWIRE_CLIENT_VERSION ABLETON_PIPEWIRE_DAEMON_VERSION
    fi
    # Reporting comes after the compatibility gate has succeeded. The .run
    # system report already names PipeWire, so a coordinated run records one
    # compatibility proof without printing the same version at every child.
    if [ "${ABLETON_PIPEWIRE_REPORT_SHOWN:-0}" != 1 ]; then
        ui_status pa_pipewire_supported "$daemon" "$client"
    fi
    return 0
}

ableton_pipeasio_build_info_value()
{
    local file="$1" key="$2" line count
    count="$(grep -c "^${key}:" "$file" 2>/dev/null || true)"
    [ "$count" -eq 1 ] || return 1
    line="$(sed -n "s/^${key}:[[:space:]]*//p" "$file")"
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
}

ableton_pipeasio_validate_panel()
{
    local runtime="${1:?runtime root required}" info="${2:-$1/ABLETON-WINE-BUILD-INFO.txt}"
    local mode record expected actual count=0 part panel_re
    [ -s "$info" ] || { echo "!! runtime build information is missing" >&2; return 1; }
    mode="$(ableton_pipeasio_build_info_value "$info" pipeasio-panel)" || {
        echo "!! The Wine build has invalid PipeASIO Settings information." >&2; return 1; }
    record="$(ableton_pipeasio_build_info_value "$info" pipeasio-settings)" || {
        echo "!! The Wine build has invalid PipeASIO Settings version information." >&2; return 1; }
    for part in bin/pipeasio-settings \
        share/applications/pipeasio-settings.desktop \
        share/icons/hicolor/scalable/apps/pipeasio.svg; do
        if [ -e "$runtime/$part" ] || [ -L "$runtime/$part" ]; then count=$((count + 1)); fi
    done

    case "$mode" in
        built)
            # The release build links jammy's Qt 6.2 and records exactly that,
            # so the canonical form is pinned and any other version is refused.
            # The Nix package links whatever Qt 6 its nixpkgs carries, so on a
            # runtime that identifies itself as nix the record names the version
            # actually built against instead.
            if [ "$(ableton_pipeasio_build_info_value "$info" dist-version)" = nix ]; then
                panel_re='^([0-9a-f]{64}) \(Qt [0-9]+\.[0-9]+ link\)$'
            else
                panel_re='^([0-9a-f]{64}) \(Qt 6\.2 link\)$'
            fi
            [[ "$record" =~ $panel_re ]] || {
                echo "!! The Wine build's PipeASIO Settings information is malformed." >&2; return 1; }
            expected="${BASH_REMATCH[1]}"
            [ "$count" -eq 3 ] && [ -x "$runtime/bin/pipeasio-settings" ] \
                && [ -s "$runtime/share/applications/pipeasio-settings.desktop" ] \
                && [ -s "$runtime/share/icons/hicolor/scalable/apps/pipeasio.svg" ] || {
                echo "!! runtime has an incomplete PipeASIO Settings panel" >&2; return 1; }
            actual="$(sha256sum -- "$runtime/bin/pipeasio-settings" | awk '{print $1}')"
            [ "$actual" = "$expected" ] || {
                echo "!! PipeASIO Settings does not match runtime build information" >&2; return 1; }
            grep -qxF 'Exec=pipeasio-settings' \
                "$runtime/share/applications/pipeasio-settings.desktop" || {
                echo "!! PipeASIO Settings launcher is malformed" >&2; return 1; }
            grep -qxF 'Icon=pipeasio' \
                "$runtime/share/applications/pipeasio-settings.desktop" || {
                echo "!! PipeASIO Settings icon reference is malformed" >&2; return 1; }
            grep -q '<svg' "$runtime/share/icons/hicolor/scalable/apps/pipeasio.svg" || {
                echo "!! PipeASIO Settings icon is malformed" >&2; return 1; }
            ;;
        skipped)
            case "$record" in
                'skipped (disabled)'|'skipped (Qt6 Widgets unavailable)') ;;
                *) echo "!! The Wine build's PipeASIO Settings information is malformed." >&2; return 1 ;;
            esac
            [ "$count" -eq 0 ] || {
                echo "!! runtime says the settings panel was skipped, but panel files are present" >&2
                return 1
            }
            ;;
        *) echo "!! runtime has an unknown PipeASIO panel state" >&2; return 1 ;;
    esac
}

# Validate the sealed core PipeASIO portion of a runtime. The optional settings
# panel has its own validator above: a broken GUI must never make the Wine
# runtime or ASIO driver unusable. When EXTERNAL_INFO is supplied (the kit's
# versioned BUILD-INFO), it must be byte-identical to the copy inside the
# tarball.
ableton_pipeasio_validate_runtime()
{
    local runtime="${1:?runtime root required}" external_info="${2:-}" expected_version="${3:-}"
    local info="$runtime/ABLETON-WINE-BUILD-INFO.txt" dist_version
    local probe_record probe_hash pe_record pe_hash unix_record unix_hash
    local canonical alias
    [ -s "$info" ] || { echo "!! runtime build information is missing" >&2; return 1; }
    if [ -n "$external_info" ]; then
        if [ ! -s "$external_info" ] || ! cmp -s -- "$external_info" "$info"; then
            echo "!! runtime build information does not match the installer kit" >&2
            return 1
        fi
    fi
    dist_version="$(ableton_pipeasio_build_info_value "$info" dist-version)" || {
        echo "!! runtime has no unique distribution version" >&2; return 1; }
    # "nix" is the Nix package's distribution identity: the store hash, not a
    # release date, identifies that build, and setup-prefix.sh validates the
    # runtime it was started from. Accepted only for a runtime that is actually
    # in the store, so a tarball runtime cannot use the name to skip the version
    # check. Where a caller names the version it expects - install.sh matching a
    # runtime against its payload - the comparison below rejects "nix" anyway,
    # it equalling no release version.
    [[ "$dist_version" =~ ^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] \
        || { [ "$dist_version" = nix ] && [ "${runtime#/nix/store/}" != "$runtime" ]; } || {
        echo "!! runtime has an invalid distribution version" >&2; return 1; }
    if [ -n "$expected_version" ] && [ "$dist_version" != "$expected_version" ]; then
        echo "!! runtime build information belongs to version $dist_version, not $expected_version" >&2
        return 1
    fi
    for canonical in \
        lib/wine/x86_64-windows/pipeasio64.dll \
        lib/wine/x86_64-unix/pipeasio64.dll.so; do
        [ -s "$runtime/$canonical" ] || { echo "!! runtime is missing $canonical" >&2; return 1; }
    done
    pe_record="$(ableton_pipeasio_build_info_value "$info" pipeasio-pe)" || {
        echo "!! runtime has no unique PipeASIO PE digest" >&2; return 1; }
    unix_record="$(ableton_pipeasio_build_info_value "$info" pipeasio-unix)" || {
        echo "!! runtime has no unique PipeASIO Unix digest" >&2; return 1; }
    [[ "$pe_record" =~ ^[0-9a-f]{64}$ ]] && [[ "$unix_record" =~ ^[0-9a-f]{64}$ ]] || {
        echo "!! runtime has a malformed PipeASIO digest" >&2; return 1; }
    pe_hash="$(sha256sum -- "$runtime/lib/wine/x86_64-windows/pipeasio64.dll" | awk '{print $1}')"
    unix_hash="$(sha256sum -- "$runtime/lib/wine/x86_64-unix/pipeasio64.dll.so" | awk '{print $1}')"
    [ "$pe_hash" = "$pe_record" ] && [ "$unix_hash" = "$unix_record" ] || {
        echo "!! PipeASIO binaries do not match runtime build information" >&2
        return 1
    }
    while IFS='|' read -r canonical alias; do
        if [ ! -L "$runtime/$alias" ] \
            || [ "$(readlink -- "$runtime/$alias")" != "$(basename "$canonical")" ] \
            || ! cmp -s -- "$runtime/$canonical" "$runtime/$alias"; then
            echo "!! runtime PipeASIO aliases are inconsistent" >&2
            return 1
        fi
    done <<'EOF'
lib/wine/x86_64-windows/pipeasio64.dll|lib/wine/x86_64-windows/pipeasio.dll
lib/wine/x86_64-unix/pipeasio64.dll.so|lib/wine/x86_64-unix/pipeasio.dll.so
EOF
    [ -x "$runtime/bin/pipewire-version-probe" ] || {
        echo "!! runtime is missing its PipeWire compatibility check" >&2; return 1; }
    probe_record="$(ableton_pipeasio_build_info_value "$info" pipewire-version-probe)" || {
        echo "!! runtime has no PipeWire compatibility-check digest" >&2; return 1; }
    [[ "$probe_record" =~ ^[0-9a-f]{64}$ ]] || {
        echo "!! runtime has an invalid PipeWire compatibility-check digest" >&2; return 1; }
    probe_hash="$(sha256sum -- "$runtime/bin/pipewire-version-probe" | awk '{print $1}')"
    [ "$probe_hash" = "$probe_record" ] || {
        echo "!! PipeWire compatibility check does not match runtime build information" >&2
        return 1
    }
}

# Quote one executable pathname for a Desktop Entry Exec key.  The Desktop
# Entry grammar still expands percent field codes inside quotes, so literal
# percent signs must be doubled in addition to the quoted-string escapes.
ableton_pipeasio_desktop_exec_arg()
{
    # The backtick is a literal Desktop Entry quoted-string character here.
    # shellcheck disable=SC2016
    printf '%s' "${1:?desktop executable path required}" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/`/\\`/g' \
        -e 's/\$/\\$/g' \
        -e 's/%/%%/g'
}

ableton_pipeasio_icon_may_replace()
{
    local path="$1"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then return 0; fi
    if ableton_manifest_path_matches "$path" || ableton_legacy_owned_path "$path"; then return 0; fi
    ableton_record_deowned "$path"
    ui_status pa_preserved_existing "$path"
    return 1
}

ableton_pipeasio_restore_adjacent_backup()
{
    local path="$1" saved="$1.bak" path_record saved_record path_kind path_digest
    local saved_kind saved_digest current saved_current index status=0
    ableton_manifest_path_claimed "$path" \
        && ableton_manifest_path_claimed "$saved" || return 2
    path_record="$(ableton_manifest_object_record "$path")" || return 2
    saved_record="$(ableton_manifest_object_record "$saved")" || return 2
    IFS=$'\t' read -r path_kind path_digest <<< "$path_record"
    IFS=$'\t' read -r saved_kind saved_digest <<< "$saved_record"
    case "$path_kind:$saved_kind" in
        file:file|file:symlink|symlink:file|symlink:symlink) ;;
        *) return 2 ;;
    esac

    # Older releases may have a durable pre-install copy for either member.
    # That remains authoritative; the adjacent-pair rule is only for current,
    # snapshot-free launcher replacements.
    index="$ABLETON_STATE_HOME/install-prestate.tsv"
    if [ -e "$index" ] || [ -L "$index" ]; then
        ableton_validate_install_state_journals >/dev/null 2>&1 || return 2
        if [ -r "$index" ] \
           && awk -F '\t' -v p="$path" -v s="$saved" \
                '$1=="present" && ($2==p || $2==s) { found=1 } END { exit !found }' \
                "$index"; then
            return 2
        fi
    fi

    current="$(ableton_object_token "$path" 2>/dev/null || true)"
    saved_current="$(ableton_object_token "$saved" 2>/dev/null || true)"
    if [ "$current" != "$path_kind:$path_digest" ] \
       && [ "$current" != "$saved_kind:$saved_digest" ] \
       && [ "$current" != absent ]; then
        ableton_record_deowned "$path" >/dev/null 2>&1 || true
        ableton_record_deowned "$saved" >/dev/null 2>&1 || true
        if [ "$saved_current" = absent ]; then
            echo "!! Kept $path because its saved earlier shortcut is missing." >&2
        else
            echo "!! Kept both $path and $saved because the current shortcut was changed." >&2
        fi
        return 0
    fi
    if [ "$saved_current" != "$saved_kind:$saved_digest" ]; then
        ableton_record_deowned "$path" >/dev/null 2>&1 || true
        ableton_record_deowned "$saved" >/dev/null 2>&1 || true
        if [ "$saved_current" = absent ]; then
            echo "!! Kept $path because its saved earlier shortcut is missing." >&2
        else
            echo "!! Kept both $path and $saved because the saved earlier shortcut was changed." >&2
        fi
        return 0
    fi

    ableton_txn_snapshot "$path" || return 1
    ableton_txn_snapshot "$saved" || return 1
    ableton_txn_expect "$path" "$saved_kind:$saved_digest" || return 1
    ableton_txn_expect "$saved" absent || return 1
    if [ "$current" != "$saved_kind:$saved_digest" ]; then
        if ! ableton_atomic_restore_object "$saved" "$path" \
           || [ "$(ableton_object_token "$path" 2>/dev/null || true)" \
                != "$saved_kind:$saved_digest" ]; then
            ableton_txn_expect "$path" "$current" || return 1
            ableton_txn_expect "$saved" "$saved_current" || return 1
            ableton_record_deowned "$path" >/dev/null 2>&1 || true
            ableton_record_deowned "$saved" >/dev/null 2>&1 || true
            echo "!! Could not restore $saved to $path; both files were kept." >&2 \
                || true
            return 0
        fi
    fi
    if ! rm -f -- "$saved" || [ -e "$saved" ] || [ -L "$saved" ]; then
        ableton_txn_expect "$saved" "$saved_current" || status=1
        ableton_record_deowned "$path" >/dev/null 2>&1 || true
        ableton_record_deowned "$saved" >/dev/null 2>&1 || true
        echo "!! Restored the earlier shortcut at $path, but its extra saved copy remains at $saved." >&2 \
            || true
        return "$status"
    fi
    ableton_record_deowned "$path" || return 1
    ableton_record_deowned "$saved" || return 1
    ui_status pa_restored_previous "$path"
    return 0
}

ableton_pipeasio_remove_panel_path()
{
    local path="$1" adjacent_status=0
    if ableton_pipeasio_restore_adjacent_backup "$path"; then
        return 0
    else
        adjacent_status=$?
        [ "$adjacent_status" -eq 2 ] || return "$adjacent_status"
    fi
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        if ableton_manifest_path_claimed "$path"; then
            ableton_remove_managed_file "$path"
        else
            ableton_record_deowned "$path"
        fi
    elif ableton_manifest_path_matches "$path" || ableton_legacy_owned_path "$path"; then
        ableton_remove_managed_file "$path"
    else
        ableton_record_deowned "$path"
        ui_status pa_preserved_existing "$path"
    fi
}

ableton_pipeasio_refresh_panel_caches()
{
    update-desktop-database \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications" >/dev/null 2>&1 || true
}

ableton_pipeasio_remove_panel_integration()
{
    local rc=0
    ableton_pipeasio_remove_panel_path "$ABLETON_BIN_HOME/pipeasio-settings" || rc=1
    ableton_pipeasio_remove_panel_path \
        "${XDG_DATA_HOME:-$HOME/.local/share}/applications/pipeasio-settings.desktop" || rc=1
    ableton_pipeasio_remove_panel_path \
        "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/pipeasio.svg" || rc=1
    return "$rc"
}

ableton_pipeasio_qt_package_hint()
{
    local qpa="${1:-xcb}" id="" id_like="" version_id="" ubuntu_codename="" wayland=""
    local ID="" ID_LIKE="" VERSION_ID="" UBUNTU_CODENAME="" VERSION_CODENAME=""
    [ "$qpa" != wayland ] || wayland=1
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"; id_like="${ID_LIKE:-}"; version_id="${VERSION_ID:-}"
        ubuntu_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    fi
    case " $id $id_like " in
        *' ubuntu '*|*' linuxmint '*)
            if [ "$ubuntu_codename" = noble ] || [[ "$version_id" =~ ^24\.04 ]]; then
                printf 'sudo apt install libqt6widgets6t64 qt6-qpa-plugins%s\n' \
                    "$([ -z "$wayland" ] || printf ' qt6-wayland')"
            else
                printf 'sudo apt install libqt6widgets6 qt6-qpa-plugins%s\n' \
                    "$([ -z "$wayland" ] || printf ' qt6-wayland')"
            fi ;;
        *' debian '*) printf 'sudo apt install libqt6widgets6 qt6-qpa-plugins%s\n' \
            "$([ -z "$wayland" ] || printf ' qt6-wayland')" ;;
        *' fedora '*) printf 'sudo dnf install qt6-qtbase-gui%s\n' \
            "$([ -z "$wayland" ] || printf ' qt6-qtwayland')" ;;
        *' arch '*) printf 'sudo pacman -S qt6-base%s\n' \
            "$([ -z "$wayland" ] || printf ' qt6-wayland')" ;;
        *) printf '%s\n' 'install Qt 6 Widgets and its xcb/Wayland platform plugins' ;;
    esac
}

ableton_pipeasio_optional_tools_advice()
{
    local tool missing=""
    [ "$ABLETON_PIPEASIO_DIAGNOSTIC_NOTICE_SHOWN" -eq 0 ] || return 0
    ABLETON_PIPEASIO_DIAGNOSTIC_NOTICE_SHOWN=1
    for tool in pw-dump pw-top; do
        command -v "$tool" >/dev/null 2>&1 || missing="${missing}${missing:+, }$tool"
    done
    if [ -n "$missing" ]; then
        ui_info pa_optional_tools_missing "$missing"
        ui_info pa_optional_tools_hint
    fi
    return 0
}

# The driver remains usable without Qt.  This is advice for the optional panel,
# and checks both its linked libraries and the platform plugin selected for the
# current session.  QT_PLUGIN_PATH is a colon-separated list.
ableton_pipeasio_qt_advice()
{
    local panel="$1" qpa="${QT_QPA_PLATFORM:-}" path plugin="" missing="" entry base
    local -a roots=()
    [ -x "$panel" ] || return 0
    if command -v ldd >/dev/null 2>&1; then
        missing="$(ldd "$panel" 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]]*\)[[:space:]]*=>[[:space:]]*not found.*/\1/p')"
    fi
    qpa="${qpa%%:*}"
    if [ -z "$qpa" ]; then
        case "${XDG_SESSION_TYPE:-}" in wayland) qpa=wayland ;; *) qpa=xcb ;; esac
    fi
    case "$qpa" in wayland*) qpa=wayland ;; xcb|*) qpa=xcb ;; esac

    IFS=: read -r -a roots <<< "${QT_PLUGIN_PATH:-}"
    if command -v qtpaths6 >/dev/null 2>&1; then
        path="$(qtpaths6 --plugin-dir 2>/dev/null || true)"
        [ -z "$path" ] || roots+=("$path")
    fi
    roots+=(/usr/lib/x86_64-linux-gnu/qt6/plugins /usr/lib64/qt6/plugins /usr/lib/qt6/plugins)
    for entry in "${roots[@]}"; do
        [ -n "$entry" ] || continue
        case "$entry" in */platforms) base="$entry" ;; *) base="$entry/platforms" ;; esac
        if [ "$qpa" = wayland ]; then
            for path in "$base/libqwayland-generic.so" "$base/libqwayland-egl.so"; do
                [ -f "$path" ] && { plugin="$path"; break 2; }
            done
        elif [ -f "$base/libqxcb.so" ]; then
            plugin="$base/libqxcb.so"; break
        fi
    done
    if [ -n "$plugin" ] && command -v ldd >/dev/null 2>&1; then
        path="$(ldd "$plugin" 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]]*\)[[:space:]]*=>[[:space:]]*not found.*/\1/p')"
        [ -z "$path" ] || missing="${missing}${missing:+$'\n'}$path"
    elif [ -z "$plugin" ]; then
        missing="${missing}${missing:+$'\n'}Qt $qpa platform plugin"
    fi
    if [ -n "$missing" ]; then
        ui_info pa_qt_advice "$(ableton_pipeasio_qt_package_hint "$qpa")"
    fi
    return 0
}

ableton_pipeasio_sync_panel()
{
    local runtime="${1:?runtime root required}" policy="${2:-install}" state
    local command="$ABLETON_BIN_HOME/pipeasio-settings"
    local desktop="${XDG_DATA_HOME:-$HOME/.local/share}/applications/pipeasio-settings.desktop"
    local icon="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/pipeasio.svg"
    local source_desktop="$runtime/share/applications/pipeasio-settings.desktop"
    local source_icon="$runtime/share/icons/hicolor/scalable/apps/pipeasio.svg"
    local tmp="" failures_before="$ABLETON_OPTIONAL_FILE_FAILURES"
    [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] || return 0
    case "$policy" in install|reconcile) ;; *) return 2 ;; esac
    if [ "$policy" = reconcile ] \
       && [ ! -e "$command" ] && [ ! -L "$command" ] \
       && [ ! -e "$desktop" ] && [ ! -L "$desktop" ] \
       && [ ! -e "$icon" ] && [ ! -L "$icon" ]; then
        return 0
    fi
    state="$(ableton_pipeasio_build_info_value \
        "$runtime/ABLETON-WINE-BUILD-INFO.txt" pipeasio-panel 2>/dev/null || true)"
    case "$state" in
        built|skipped) ;;
        *)
            echo "!! copy failed: PipeASIO Settings files from $runtime" >&2 || true
            ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
            return 1 ;;
    esac
    if [ "$state" = skipped ]; then
        ui_status pa_panel_not_packaged
        return 0
    fi

    ableton_install_project_symlink "$runtime/bin/pipeasio-settings" "$command"
    if tmp="$(mktemp "${TMPDIR:-/tmp}/pipeasio-settings.desktop.XXXXXX")" \
       && { while IFS= read -r line || [ -n "$line" ]; do
                if [ "$line" = 'Exec=pipeasio-settings' ]; then
                    printf 'Exec="%s"\n' \
                        "$(ableton_pipeasio_desktop_exec_arg "$runtime/bin/pipeasio-settings")"
                else
                    printf '%s\n' "$line"
                fi
            done < "$source_desktop"
            printf '%s\n' 'X-Ableton-Wine-Managed=true';
          } > "$tmp"; then
        ableton_install_project_file 644 "$tmp" "$desktop"
    else
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    fi
    [ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
    ableton_install_project_file 644 "$source_icon" "$icon"
    [ "$policy" != install ] || ableton_pipeasio_qt_advice "$runtime/bin/pipeasio-settings"
    ableton_pipeasio_refresh_panel_caches
    [ "$ABLETON_OPTIONAL_FILE_FAILURES" -eq "$failures_before" ]
}

ableton_pipeasio_wait_command()
{
    local wait_command="$1"
    [ -z "$wait_command" ] || "$wait_command"
}

# WINE_COMMAND and WAIT_COMMAND may name shell functions or executables.  The
# caller exports the staged/retained WINEPREFIX.  Only PipeASIO's one CLSID and
# one ASIO entry are touched.
ableton_pipeasio_unregister()
{
    local wine_command="${1:?wine command required}" wait_command="${2:-}"
    "$wine_command" reg delete "$ABLETON_PIPEASIO_ASIO_KEY" /f >/dev/null 2>&1 || true
    "$wine_command" reg delete "$ABLETON_PIPEASIO_CLASS_KEY" /f >/dev/null 2>&1 || true
    ableton_pipeasio_wait_command "$wait_command" || {
        echo "!! Wine did not finish removing PipeASIO" >&2
        return 1
    }
    # A failed query is only evidence of absence when reg.exe itself is known
    # to be working against this prefix.  HKCU\Software is a stable control key
    # created by Wine; without it, retain the runtime rather than orphan a CLSID.
    if ! "$wine_command" reg query 'HKCU\Software' >/dev/null 2>&1; then
        echo "!! PipeASIO removal could not be verified in the selected Wine prefix" >&2
        return 1
    fi
    if "$wine_command" reg query "$ABLETON_PIPEASIO_ASIO_KEY" >/dev/null 2>&1 \
       || "$wine_command" reg query "$ABLETON_PIPEASIO_CLASS_KEY" >/dev/null 2>&1; then
        echo "!! PipeASIO could not be removed from the selected Wine prefix" >&2
        return 1
    fi
}

ableton_pipeasio_register()
{
    local wine_command="${1:?wine command required}" wait_command="${2:-}"
    local result
    ableton_pipeasio_unregister "$wine_command" "$wait_command" || return 1
    "$wine_command" regsvr32 /s pipeasio64.dll >/dev/null 2>&1 || {
        echo "!! PipeASIO registration command failed" >&2
        return 1
    }
    ableton_pipeasio_wait_command "$wait_command" || {
        echo "!! Wine did not finish registering PipeASIO" >&2
        return 1
    }
    result="$("$wine_command" reg query "$ABLETON_PIPEASIO_ASIO_KEY" /v CLSID 2>/dev/null)" || {
        echo "!! PipeASIO registration was not found in the selected Wine prefix" >&2
        return 1
    }
    printf '%s\n' "$result" | awk -v wanted="$ABLETON_PIPEASIO_CLSID" '
        { gsub(/\r/, "") }   # reg output is CRLF
        toupper($1)=="CLSID" && toupper($2)=="REG_SZ" \
            && toupper($3)==toupper(wanted) && NF==3 { found=1 }
        END { exit !found }
    ' || {
        echo "!! PipeASIO registration points to an unexpected driver" >&2
        return 1
    }
    "$wine_command" reg query "$ABLETON_PIPEASIO_CLASS_KEY" >/dev/null 2>&1 || {
        echo "!! PipeASIO class registration is incomplete" >&2
        return 1
    }
    ui_status pa_registered
}
