#!/usr/bin/env bash
# Shared, side-effect-free configuration and bounded-process helpers.
# Source this file, then call ableton_config_init.  Values are resolved in this
# order: an already-exported environment variable, the persistent config, then
# the compatibility default.  The .run CLI exports its resolved arguments, so
# command-line values naturally outrank the environment.

ABLETON_RUNTIME_NAME="wine-d2d1-nspa-11.13"
# Desktop IDs belong to this project, not to the compatibility runtime.  Wine's
# generated wine-protocol-*.desktop names are global to a user session and can
# be overwritten by any prefix that registers the same scheme.
ABLETON_PROTOCOL_DESKTOP_ID="io.github.shibco.ableton-linux.protocol.desktop"
ABLETON_AUZ_DESKTOP_ID="io.github.shibco.ableton-linux.auz.desktop"
ARCH="${ARCH:-$(uname -m)}"

ableton_config_error()
{
    printf '!! %s\n' "$*" >&2
    return 1
}

# Ownership markers authorize recursive lifecycle operations.  Keep their
# grammar exact: a file with one familiar line plus unrelated content is not a
# project marker.
ableton_exact_two_line_marker()
{
    local marker="$1" first="$2" second="$3"
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    cmp -s -- "$marker" <(printf '%s\n%s\n' "$first" "$second")
}

ableton_runtime_marker_valid()
{
    local runtime="$1" runtime_name="${2:-$ABLETON_RUNTIME_NAME}"
    ableton_exact_two_line_marker "$runtime/.ableton-linux-runtime" \
        format=1 "name=$runtime_name"
}

ableton_prefix_marker_valid()
{
    local prefix="$1" expected_prefix="${2:-$1}"
    ableton_exact_two_line_marker "$prefix/.ableton-linux-prefix" \
        format=1 "prefix=$expected_prefix"
}

ableton_state_marker_valid()
{
    ableton_exact_two_line_marker "$1/.ableton-linux-state" \
        format=1 owner=ableton-linux
}

ableton_legacy_shortcut_state_valid()
{
    local state="$1" expected header schema key original held extra rows=0 nul_count terminal normalized saw_header=0
    local -A seen=()
    expected="$(ableton_realpath_m "${XDG_STATE_HOME:-$HOME/.local/state}/ableton-wine")" \
        || return 1
    [ "$state" = "$expected" ] && [ -d "$state" ] && [ ! -L "$state" ] \
        && [ -O "$state" ] \
        && [ "$(stat -c '%a' -- "$state" 2>/dev/null || true)" = 700 ] || return 1
    # The shortcut hold was the sole state object written before ownership
    # markers.  Do not turn a broad basename exception into delete authority.
    [ "$(find "$state" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" = hold-v2 ] \
        || return 1
    [ -f "$state/hold-v2" ] && [ ! -L "$state/hold-v2" ] \
        && [ -O "$state/hold-v2" ] && [ -r "$state/hold-v2" ] \
        && [ "$(stat -c '%a' -- "$state/hold-v2" 2>/dev/null || true)" = 600 ] || return 1
    nul_count="$(LC_ALL=C tr -cd '\000' < "$state/hold-v2" 2>/dev/null | wc -c)" \
        || return 1
    [ "$nul_count" -eq 0 ] || return 1
    IFS= read -r header < "$state/hold-v2" || return 1
    [ "$header" = ABLETON_SHORTCUT_HOLD_V2 ] || return 1
    while IFS='|' read -r schema key original held extra || [ -n "$schema$key$original$held$extra" ]; do
        if [ "$schema" = ABLETON_SHORTCUT_HOLD_V2 ]; then
            [ "$saw_header" -eq 0 ] && [ "$rows" -eq 0 ] \
                && [ -z "$key$original$held$extra" ] \
                && { saw_header=1; continue; }
            return 1
        fi
        [ "$saw_header" -eq 1 ] || return 1
        [ -z "$extra" ] && [ -n "$schema" ] && [ -n "$key" ] \
            && [ -n "$original" ] && [ -n "$held" ] || return 1
        case "$schema|$key" in
            org.gnome.desktop.wm.keybindings\|switch-to-workspace-up) terminal=Up ;;
            org.gnome.desktop.wm.keybindings\|switch-to-workspace-down) terminal=Down ;;
            org.gnome.settings-daemon.plugins.media-keys\|logout) terminal=Delete ;;
            *) return 1 ;;
        esac
        [ -z "${seen[$schema|$key]+x}" ] || return 1
        case "$original:$held" in *$'\n'*|*$'\r'*|*'|'*) return 1 ;; esac
        normalized="$(ableton_legacy_shortcut_strip_ctrl_alt "$original" "$terminal")" || return 1
        [ "$held" = "$normalized" ] \
            && [ "$held" != "$(ableton_legacy_shortcut_normalize "$original")" ] || return 1
        seen["$schema|$key"]=1
        rows=$((rows + 1))
    done < "$state/hold-v2"
    [ "$rows" -ge 1 ]
}

ableton_legacy_shortcut_normalize()
{
    local value="$1"
    value="${value#@as }"
    printf '%s' "$value"
}

ableton_legacy_shortcut_strip_ctrl_alt()
{
    local value="$1" terminal="${2,,}" inner entry accelerator modifier
    local have_ctrl have_alt valid out=""
    value="$(ableton_legacy_shortcut_normalize "$value")"
    [ "$value" != '[]' ] || { printf '[]'; return; }
    case "$value" in \[*\]) ;; *) return 1 ;; esac
    inner="${value#[}"; inner="${inner%]}"
    local IFS=,
    for entry in $inner; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        case "$entry" in \'*\') ;; *) return 1 ;; esac
        accelerator="${entry#\'}"; accelerator="${accelerator%\'}"; accelerator="${accelerator,,}"
        have_ctrl=0; have_alt=0; valid=1
        while [[ "$accelerator" == \<*\>* ]]; do
            modifier="${accelerator#<}"; modifier="${modifier%%>*}"; accelerator="${accelerator#*>}"
            case "$modifier" in
                control|ctrl|ctl|primary) [ "$have_ctrl" -eq 0 ] || valid=0; have_ctrl=1 ;;
                alt|mod1) [ "$have_alt" -eq 0 ] || valid=0; have_alt=1 ;;
                *) valid=0 ;;
            esac
        done
        if [ "$valid" -eq 1 ] && [ "$have_ctrl" -eq 1 ] && [ "$have_alt" -eq 1 ] \
           && [ "$accelerator" = "$terminal" ]; then
            continue
        fi
        out="${out:+$out, }$entry"
    done
    printf '[%s]' "$out"
}

# Releases through 0526500 predate ownership markers.  Only the historical
# default paths are eligible for adoption, and their project-specific runtime
# hashes or complete Wine-prefix shape must be intact.  A malformed marker is
# never treated as legacy.
ableton_legacy_project_evidence()
{
    local version="$HOME/.local/share/ableton-wine/VERSION"
    local launcher="$HOME/.local/bin/ableton-live"
    [ -f "$version" ] && [ ! -L "$version" ] \
        && grep -Eq '^20[0-9]{2}[.][0-9]{2}[.][0-9]{2}[.][0-9]+$' "$version" \
        && [ -f "$launcher" ] && [ ! -L "$launcher" ] \
        && grep -qF 'Ableton Live launcher for the patched Wine stack' "$launcher"
}

# A prefix this project configured before the ownership marker existed. The
# tarball evidence above cannot see a Nix install: that path stages no VERSION
# and no launcher under $HOME, so it has nothing to recognise. What a Nix setup
# does leave in the prefix is PipeASIO's CLSID, which only this project
# registers. The runtime link corroborates when it is there, but a prefix
# created before runtime-link.sh existed has none, so it cannot be required.
ableton_legacy_nix_evidence()
{
    local prefix="${1:?prefix required}"
    # -i: the registry's case for a CLSID is whatever wrote it, and the cost of
    # a miss here is a prefix this project made being refused as a stranger's.
    [ -f "$prefix/system.reg" ] && [ ! -L "$prefix/system.reg" ] \
        && grep -qiF '2D3CA9E2-1193-4C5D-B5FD-38798F3DC074' "$prefix/system.reg"
}

ableton_legacy_default_runtime_valid()
{
    local runtime="$1" expected info pe_count unix_count pe_hash unix_hash
    expected="$(ableton_realpath_m "$HOME/.local/opt/$ABLETON_RUNTIME_NAME")" || return 1
    [ "$runtime" = "$expected" ] && ableton_legacy_project_evidence \
        && [ -d "$runtime" ] && [ ! -L "$runtime" ] \
        && [ ! -e "$runtime/.ableton-linux-runtime" ] \
        && [ ! -L "$runtime/.ableton-linux-runtime" ] || return 1
    info="$runtime/ABLETON-WINE-BUILD-INFO.txt"
    [ -f "$info" ] && [ ! -L "$info" ] \
        && [ -x "$runtime/bin/wine" ] && [ -x "$runtime/bin/wineserver" ] \
        && [ -f "$runtime/lib/wine/$ARCH-windows/pipeasio64.dll" ] \
        && [ -f "$runtime/lib/wine/$ARCH-unix/pipeasio64.dll.so" ] || return 1
    pe_count="$(grep -Ec '^pipeasio-pe:[[:space:]]+[0-9a-f]{64}([[:space:]]|$)' "$info" 2>/dev/null || true)"
    unix_count="$(grep -Ec '^pipeasio-unix:[[:space:]]+[0-9a-f]{64}([[:space:]]|$)' "$info" 2>/dev/null || true)"
    [ "$pe_count" -eq 1 ] && [ "$unix_count" -eq 1 ] \
        && [ "$(grep -c '^pipeasio-pe:' "$info" 2>/dev/null || true)" -eq 1 ] \
        && [ "$(grep -c '^pipeasio-unix:' "$info" 2>/dev/null || true)" -eq 1 ] \
        && [ "$(grep -c '^dist-version:' "$info" 2>/dev/null || true)" -eq 1 ] || return 1
    pe_hash="$(sed -n 's/^pipeasio-pe:[[:space:]]*\([0-9a-f]\{64\}\).*$/\1/p' "$info")"
    unix_hash="$(sed -n 's/^pipeasio-unix:[[:space:]]*\([0-9a-f]\{64\}\).*$/\1/p' "$info")"
    [ "$(sha256sum -- "$runtime/lib/wine/$ARCH-windows/pipeasio64.dll" | awk '{print $1}')" = "$pe_hash" ] \
        && [ "$(sha256sum -- "$runtime/lib/wine/$ARCH-unix/pipeasio64.dll.so" | awk '{print $1}')" = "$unix_hash" ]
}

ableton_legacy_default_prefix_valid()
{
    local prefix="$1" expected registry
    expected="$(ableton_realpath_m "$HOME/.wine-ableton")" || return 1
    [ "$prefix" = "$expected" ] \
        && [ -d "$prefix" ] && [ ! -L "$prefix" ] \
        && [ ! -e "$prefix/.ableton-linux-prefix" ] \
        && [ ! -L "$prefix/.ableton-linux-prefix" ] \
        && [ -d "$prefix/drive_c/windows/system32" ] || return 1
    # Either the tarball footprint under $HOME, or, for a Nix setup that leaves
    # none, this project's own registration inside the prefix.
    ableton_legacy_project_evidence || ableton_legacy_nix_evidence "$prefix" || return 1
    for registry in system.reg user.reg userdef.reg; do
        [ -f "$prefix/$registry" ] && [ ! -L "$prefix/$registry" ] \
            && [ "$(sed -n '1p' "$prefix/$registry" 2>/dev/null)" = 'WINE REGISTRY Version 2' ] \
            || return 1
    done
}

ableton_require_home()
{
    [ -n "${HOME:-}" ] || ableton_config_error "HOME is not set"
}

ableton_config_object_token()
{
    local path="$1" literal referent referent_token
    if [ -L "$path" ]; then
        literal="$(readlink -n -- "$path")" || return 1
        referent="$(readlink -f -- "$path" 2>/dev/null || true)"
        if [ -n "$referent" ] && [ -f "$referent" ] && [ ! -L "$referent" ]; then
            referent_token="file:$(sha256sum -- "$referent" | awk '{print $1}')"
        elif [ -z "$referent" ]; then
            referent_token=dangling
        else
            return 1
        fi
        { printf 'symlink\0%s\0%s\n' "$literal" "$referent_token"; } \
            | sha256sum | awk '{print "symlink:"$1}'
    elif [ -f "$path" ]; then
        sha256sum -- "$path" | awk '{print "file:"$1}'
    elif [ ! -e "$path" ]; then
        printf 'absent\n'
    else
        return 1
    fi
}

ableton_config_snapshot_capture()
{
    ABLETON_CONFIG_SNAPSHOT_PATH="$ABLETON_CONFIG_FILE"
    ABLETON_CONFIG_SNAPSHOT_TOKEN="$(ableton_config_object_token "$ABLETON_CONFIG_FILE")" || return 1
    ABLETON_CONFIG_SNAPSHOT_VALUES="$(printf '%s\n' \
        "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" "$ABLETON_LINKD" "$ABLETON_LINK_MODE" \
        "$ABLETON_DATA_HOME" "$ABLETON_CONFIG_HOME" "$ABLETON_STATE_HOME" \
        "$ABLETON_CACHE_HOME" "$ABLETON_BIN_HOME" | sha256sum | awk '{print $1}')"
    export ABLETON_CONFIG_SNAPSHOT_PATH ABLETON_CONFIG_SNAPSHOT_TOKEN ABLETON_CONFIG_SNAPSHOT_VALUES
}

ableton_config_snapshot_verify()
{
    local token values
    [ -n "${ABLETON_CONFIG_SNAPSHOT_PATH:-}" ] || return 0
    [ "$ABLETON_CONFIG_FILE" = "$ABLETON_CONFIG_SNAPSHOT_PATH" ] || return 1
    token="$(ableton_config_object_token "$ABLETON_CONFIG_FILE")" || return 1
    values="$(printf '%s\n' \
        "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" "$ABLETON_LINKD" "$ABLETON_LINK_MODE" \
        "$ABLETON_DATA_HOME" "$ABLETON_CONFIG_HOME" "$ABLETON_STATE_HOME" \
        "$ABLETON_CACHE_HOME" "$ABLETON_BIN_HOME" | sha256sum | awk '{print $1}')"
    [ "$token" = "$ABLETON_CONFIG_SNAPSHOT_TOKEN" ] \
        && [ "$values" = "$ABLETON_CONFIG_SNAPSHOT_VALUES" ]
}

ableton_config_file_value()
{
    local wanted="$1" line key value
    [ -r "$ABLETON_CONFIG_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" = "$wanted" ] || continue
        printf '%s\n' "$value"
        return 0
    done < "$ABLETON_CONFIG_FILE"
    return 1
}

ableton_managed_config_valid()
{
    local file="${1:-$ABLETON_CONFIG_FILE}" line key value header=0
    local -A seen=()
    [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
    [ "$(LC_ALL=C tr -cd '\000' < "$file" 2>/dev/null | wc -c)" -eq 0 ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$header" -eq 0 ]; then
            [ "$line" = '# ableton-linux installer configuration; managed by the installer' ] || return 1
            header=1
            continue
        fi
        case "$line" in *=*) ;; *) return 1 ;; esac
        key="${line%%=*}"; value="${line#*=}"
        [ -z "${seen[$key]+x}" ] || return 1
        seen["$key"]=1
        case "$key" in
            format) [ "$value" = 1 ] || return 1 ;;
            runtime_root|prefix|linkd)
                [ -n "$value" ] && [[ "$value" = /* ]] || return 1
                case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac ;;
            live_major) case "$value" in ''|11|12) ;; *) return 1 ;; esac ;;
            link_mode) case "$value" in off|session|always) ;; *) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    done < "$file"
    [ "$header" -eq 1 ] \
        && [ "${#seen[@]}" -eq 6 ] \
        && [ -n "${seen[format]+x}" ] \
        && [ -n "${seen[runtime_root]+x}" ] \
        && [ -n "${seen[prefix]+x}" ] \
        && [ -n "${seen[live_major]+x}" ] \
        && [ -n "${seen[link_mode]+x}" ] \
        && [ -n "${seen[linkd]+x}" ]
}

ableton_config_init()
{
    ableton_require_home || return 1

    : "${ABLETON_DATA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine}"
    : "${ABLETON_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine}"
    : "${ABLETON_STATE_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/ableton-wine}"
    : "${ABLETON_CACHE_HOME:=${XDG_CACHE_HOME:-$HOME/.cache}/ableton-wine}"
    : "${ABLETON_BIN_HOME:=$HOME/.local/bin}"
    : "${ABLETON_CONFIG_FILE:=$ABLETON_CONFIG_HOME/config}"
    local config_file_name config_file_parent
    config_file_name="$(basename -- "$ABLETON_CONFIG_FILE")" || return 1
    config_file_parent="$(dirname -- "$ABLETON_CONFIG_FILE")" || return 1
    if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
        ableton_managed_config_valid "$ABLETON_CONFIG_FILE" || {
            ableton_config_error "refusing malformed installer configuration $ABLETON_CONFIG_FILE"
            return 1
        }
    fi

    local configured
    if [ -z "${ABLETON_WINE_ROOT+x}" ]; then
        configured="$(ableton_config_file_value runtime_root 2>/dev/null || true)"
        ABLETON_WINE_ROOT="${configured:-$HOME/.local/opt/$ABLETON_RUNTIME_NAME}"
    fi
    if [ -z "${ABLETON_WINEPREFIX+x}" ]; then
        configured="$(ableton_config_file_value prefix 2>/dev/null || true)"
        ABLETON_WINEPREFIX="${configured:-$HOME/.wine-ableton}"
    fi
    if [ -z "${ABLETON_LINK_MODE+x}" ]; then
        configured="$(ableton_config_file_value link_mode 2>/dev/null || true)"
        if [ -z "$configured" ]; then
            case "$(sed -n '1p' "$ABLETON_DATA_HOME/link-configured" 2>/dev/null || true)" in
                configured) configured=session ;;
                declined) configured=off ;;
            esac
            if [ -L "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/default.target.wants/ableton-linkd.service" ]; then
                configured=always
            fi
        fi
        ABLETON_LINK_MODE="${configured:-off}"
    fi
    if [ -z "${ABLETON_LIVE_VERSION+x}" ]; then
        configured="$(ableton_config_file_value live_major 2>/dev/null || true)"
        [ -z "$configured" ] || ABLETON_LIVE_VERSION="$configured"
    fi
    if [ -z "${ABLETON_LINKD+x}" ]; then
        configured="$(ableton_config_file_value linkd 2>/dev/null || true)"
        ABLETON_LINKD="${configured:-$ABLETON_DATA_HOME/ableton-linkd}"
    fi

    case "$ABLETON_LINK_MODE" in off|session|always) ;;
        *) ableton_config_error "link mode must be off, session, or always (got '$ABLETON_LINK_MODE')"; return 1 ;;
    esac
    case "${ABLETON_LIVE_VERSION:-}" in ''|11|12) ;;
        *) ableton_config_error "Live major must be 11 or 12 (got '$ABLETON_LIVE_VERSION')"; return 1 ;;
    esac
    for configured in "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" "$ABLETON_DATA_HOME" \
                      "$ABLETON_CONFIG_HOME" "$ABLETON_STATE_HOME" "$ABLETON_CACHE_HOME" \
                      "$ABLETON_BIN_HOME" "$ABLETON_LINKD"; do
        [ -n "$configured" ] || { ableton_config_error "a resolved installation path is empty"; return 1; }
        case "$configured" in *$'\n'*|*$'\r'*|*$'\t'*)
            ableton_config_error "installation paths may not contain newlines or tabs"; return 1 ;;
        esac
    done

    ABLETON_WINE_ROOT="$(ableton_realpath_m "$ABLETON_WINE_ROOT")" || return 1
    ABLETON_WINEPREFIX="$(ableton_realpath_m "$ABLETON_WINEPREFIX")" || return 1
    ABLETON_DATA_HOME="$(ableton_realpath_m "$ABLETON_DATA_HOME")" || return 1
    ABLETON_CONFIG_HOME="$(ableton_realpath_m "$ABLETON_CONFIG_HOME")" || return 1
    ABLETON_STATE_HOME="$(ableton_realpath_m "$ABLETON_STATE_HOME")" || return 1
    ABLETON_CACHE_HOME="$(ableton_realpath_m "$ABLETON_CACHE_HOME")" || return 1
    ABLETON_BIN_HOME="$(ableton_realpath_m "$ABLETON_BIN_HOME")" || return 1
    config_file_parent="$(ableton_realpath_m "$config_file_parent")" || return 1
    ABLETON_CONFIG_FILE="$config_file_parent/$config_file_name"
    ABLETON_LINKD="$(ableton_realpath_m "$ABLETON_LINKD")" || return 1

    # Paths are canonicalized first, so an intentional XDG/root symlink is a
    # projection to this resolved directory: lifecycle code mutates only the
    # resolved child and never removes the user's symlink.  At the concrete
    # target, however, every directory root must be absent or a real directory.
    for configured in "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" "$ABLETON_DATA_HOME" \
                      "$ABLETON_CONFIG_HOME" "$ABLETON_STATE_HOME" "$ABLETON_CACHE_HOME" \
                      "$ABLETON_BIN_HOME"; do
        if [ -e "$configured" ] || [ -L "$configured" ]; then
            [ -d "$configured" ] && [ ! -L "$configured" ] || {
                ableton_config_error "installation directory path is not a real directory: $configured"
                return 1
            }
        fi
    done

    local -a independent_paths=("$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" "$ABLETON_DATA_HOME" \
        "$ABLETON_CONFIG_HOME" "$ABLETON_STATE_HOME" "$ABLETON_CACHE_HOME")
    local i j first second
    for ((i=0; i<${#independent_paths[@]}; i++)); do
        first="$(ableton_realpath_m "${independent_paths[i]}")" || return 1
        for ((j=i+1; j<${#independent_paths[@]}; j++)); do
            second="$(ableton_realpath_m "${independent_paths[j]}")" || return 1
            if [ "$first" = "$second" ] || [[ "$first" = "$second/"* ]] || [[ "$second" = "$first/"* ]]; then
                ableton_config_error "installation roots overlap: $first and $second"
                return 1
            fi
        done
    done

    export ABLETON_WINE_ROOT ABLETON_WINEPREFIX ABLETON_LINK_MODE ABLETON_LINKD
    export ABLETON_DATA_HOME ABLETON_CONFIG_HOME ABLETON_STATE_HOME ABLETON_CACHE_HOME
    export ABLETON_BIN_HOME ABLETON_CONFIG_FILE
    export ABLETON_PROTOCOL_DESKTOP_ID ABLETON_AUZ_DESKTOP_ID
    [ -n "${ABLETON_CONFIG_SNAPSHOT_PATH:-}" ] || ableton_config_snapshot_capture
}

ableton_render_config()
{
    local major="${ABLETON_LIVE_VERSION:-}"
    printf '# ableton-linux installer configuration; managed by the installer\n'
    printf 'format=1\n'
    printf 'runtime_root=%s\n' "$ABLETON_WINE_ROOT"
    printf 'prefix=%s\n' "$ABLETON_WINEPREFIX"
    printf 'live_major=%s\n' "$major"
    printf 'link_mode=%s\n' "$ABLETON_LINK_MODE"
    printf 'linkd=%s\n' "$ABLETON_LINKD"
}

ableton_expected_config_token()
{
    ableton_render_config | sha256sum | awk '{print "file:"$1}'
}

ableton_write_config()
{
    ableton_config_init || return 1
    local tmp
    if [ -d "$ABLETON_CONFIG_FILE" ] && [ ! -L "$ABLETON_CONFIG_FILE" ]; then
        ableton_config_error "refusing to replace configuration directory $ABLETON_CONFIG_FILE"
        return 1
    fi
    if [ -L "$ABLETON_CONFIG_FILE" ]; then
        ableton_config_error "refusing symlink installer configuration $ABLETON_CONFIG_FILE"
        return 1
    fi
    mkdir -p -- "$ABLETON_CONFIG_HOME" || return 1
    tmp="$(mktemp "$ABLETON_CONFIG_HOME/.config.XXXXXX")" || return 1
    if ! chmod 600 "$tmp" \
       || ! ableton_render_config > "$tmp" \
       || ! ableton_managed_config_valid "$tmp" \
       || ! mv -T -f -- "$tmp" "$ABLETON_CONFIG_FILE" \
       || ! ableton_config_snapshot_capture; then
        rm -f -- "$tmp"
        return 1
    fi
}

ableton_mark_state_home()
{
    local marker marker_tmp
    ableton_config_init || return 1
    marker="$ABLETON_STATE_HOME/.ableton-linux-state"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        ableton_state_marker_valid "$ABLETON_STATE_HOME" || {
            ableton_config_error "refusing malformed installation state marker $marker"
            return 1
        }
        return 0
    fi
    if [ -d "$ABLETON_STATE_HOME" ] \
       && find "$ABLETON_STATE_HOME" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        ableton_legacy_shortcut_state_valid "$ABLETON_STATE_HOME" || {
            ableton_config_error "refusing to claim nonempty unmarked state directory $ABLETON_STATE_HOME"
            return 1
        }
    fi
    mkdir -p -- "$ABLETON_STATE_HOME"
    marker_tmp="$(mktemp "$ABLETON_STATE_HOME/.state-marker.XXXXXX")" || return 1
    if ! printf 'format=1\nowner=ableton-linux\n' > "$marker_tmp" \
       || ! chmod 600 "$marker_tmp" \
       || ! mv -T -n -- "$marker_tmp" "$marker" \
       || [ -e "$marker_tmp" ] || ! ableton_state_marker_valid "$ABLETON_STATE_HOME"; then
        rm -f -- "$marker_tmp"
        ableton_config_error "could not create the installation state marker"
        return 1
    fi
}

# Serialize every lifecycle mutation for this user on one existing directory.
# Runtime-only work therefore creates no state, yet cannot race a full install.
# Child helpers validate and reuse the inherited descriptor.
ableton_install_lock_acquire()
{
    local expected observed inherited="${ABLETON_INSTALL_LOCK_FD:-}" lock_fd
    command -v flock >/dev/null 2>&1 || {
        ableton_config_error "flock is required to change this installation"
        return 1
    }
    [ ! -L "$ABLETON_CONFIG_FILE" ] || {
        ableton_config_error "refusing symlink installer configuration $ABLETON_CONFIG_FILE"
        return 1
    }
    if [ -e "$ABLETON_CONFIG_FILE" ]; then
        ableton_managed_config_valid "$ABLETON_CONFIG_FILE" || {
            ableton_config_error "refusing malformed installer configuration $ABLETON_CONFIG_FILE"
            return 1
        }
    fi
    expected="$(ableton_realpath_m "$HOME")" || return 1
    [ -d "$expected" ] && [ ! -L "$expected" ] || {
        ableton_config_error "cannot use HOME as the installation lock"
        return 1
    }
    case "$inherited" in
        ''|*[!0-9]*) ;;
        *)
            observed="$(readlink -f -- "/proc/$$/fd/$inherited" 2>/dev/null || true)"
            if [ "$observed" = "$expected" ] && flock -n "$inherited"; then
                return 0
            fi
            ;;
    esac
    exec {lock_fd}< "$expected" || {
        ableton_config_error "cannot open the installation lock"
        return 1
    }
    if ! flock -n "$lock_fd"; then
        exec {lock_fd}<&-
        ableton_config_error "another installer, rollback, or uninstall is already running"
        return 1
    fi
    ABLETON_INSTALL_LOCK_FD="$lock_fd"
    export ABLETON_INSTALL_LOCK_FD
    ableton_config_snapshot_verify || {
        ableton_config_error "installation configuration changed; retry the command"
        return 1
    }
}

ableton_timeout_value()
{
    local value="$1" name="$2" min="${3:-1}" max="${4:-86400}"
    case "$value" in ''|*[!0-9]*) ableton_config_error "$name must be a whole number of seconds"; return 1 ;; esac
    [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || {
        ableton_config_error "$name must be between $min and $max seconds"
        return 1
    }
    printf '%s\n' "$value"
}

ableton_run_bounded()
{
    local seconds="$1" inherited observed expected; shift
    seconds="$(ableton_timeout_value "$seconds" timeout 1 86400)" || return 2
    command -v timeout >/dev/null 2>&1 || {
        ableton_config_error "GNU timeout is required to supervise external processes"
        return 127
    }
    # The parent keeps the lifecycle lock. Close its descriptor before external
    # commands start. Wine helpers can start background processes that would
    # keep later lifecycle commands locked after this process exits.
    (
        inherited="${ABLETON_INSTALL_LOCK_FD:-}"
        case "$inherited" in
            ''|*[!0-9]*) ;;
            *)
                observed="$(readlink -f -- "/proc/${BASHPID:-$$}/fd/$inherited" 2>/dev/null || true)"
                expected="$(ableton_realpath_m "$HOME" 2>/dev/null || true)"
                if [ -n "$expected" ] && [ "$observed" = "$expected" ]; then
                    exec {inherited}<&-
                    unset ABLETON_INSTALL_LOCK_FD
                fi
                ;;
        esac
        exec timeout --signal=TERM --kill-after=5s "${seconds}s" "$@"
    )
}

ableton_sudo_run_bounded()
{
    local seconds="$1"; shift
    (
        local probe_err probe_rc=0 password="" read_rc=0 tty_state=""
        local tty=/dev/tty
        seconds="$(ableton_timeout_value "$seconds" timeout 1 86400)" || return 2
        [ "$#" -gt 0 ] || {
            ableton_config_error "a command is required for sudo"
            return 2
        }

        # Root needs no authentication. Keep the command under the same watchdog
        # used for an authenticated invocation.
        if [ "${EUID:-$(id -u)}" -eq 0 ]; then
            ableton_run_bounded "$seconds" "$@"
            return
        fi
        command -v sudo >/dev/null 2>&1 || {
            ableton_config_error "sudo is required for this system change"
            return 127
        }

        umask 077
        probe_err="$(mktemp "${TMPDIR:-/tmp}/ableton-sudo-stderr.XXXXXX")" || return 1

        # ShellCheck does not follow function names stored in traps.
        # shellcheck disable=SC2329
        cleanup_sudo_prompt()
        {
            if [ -n "$tty_state" ]; then
                stty "$tty_state" < "$tty" >/dev/null 2>&1 || true
                printf '\n' > "$tty" 2>/dev/null || true
                tty_state=""
            fi
            password=""
            unset password
            rm -f -- "$probe_err"
        }
        trap cleanup_sudo_prompt EXIT
        trap 'exit 130' INT
        trap 'exit 129' HUP
        trap 'exit 143' TERM

        # Try the exact command once without prompting. A cached credential or a
        # command-specific NOPASSWD rule executes it here. The C locale gives the
        # password-required diagnostic one stable form; every other failure is a
        # command or policy result and must not be retried.
        LC_ALL=C ableton_run_bounded "$seconds" sudo -n -- "$@" 2> "$probe_err" \
            || probe_rc=$?
        if [ "$probe_rc" -ne 1 ] \
           || ! grep -qxF 'sudo: a password is required' "$probe_err"; then
            [ ! -s "$probe_err" ] || cat -- "$probe_err" >&2
            return "$probe_rc"
        fi

        command -v stty >/dev/null 2>&1 || {
            ableton_config_error "stty is required for hidden sudo password input"
            return 127
        }
        [ -r "$tty" ] && [ -w "$tty" ] || {
            ableton_config_error "sudo authentication needs an interactive terminal"
            return 1
        }
        tty_state="$(stty -g < "$tty")" || {
            ableton_config_error "could not read the terminal state for sudo authentication"
            return 1
        }
        printf '[sudo] password (input hidden, %ss timeout): ' "$seconds" > "$tty"
        if IFS= read -r -s -t "$seconds" password < "$tty"; then
            :
        else
            read_rc=$?
            stty "$tty_state" < "$tty" >/dev/null 2>&1 || true
            tty_state=""
            printf '\n' > "$tty" 2>/dev/null || true
            password=""
            unset password
            if [ "$read_rc" -gt 128 ]; then
                ableton_config_error "sudo password input timed out after $seconds seconds"
                return 124
            fi
            ableton_config_error "sudo password input was cancelled"
            return "$read_rc"
        fi
        stty "$tty_state" < "$tty" || return 1
        tty_state=""
        printf '\n' > "$tty"

        # Feed the password only to this sudo process. The command receives EOF
        # on standard input and remains under its own full watchdog interval.
        printf '%s\n' "$password" | ableton_run_bounded "$seconds" sudo -S -p '' -- "$@"
        probe_rc="${PIPESTATUS[1]}"
        password=""
        unset password
        return "$probe_rc"
    )
}

ableton_realpath_m()
{
    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$1"
    else
        readlink -m -- "$1"
    fi
}

ableton_path_is_safe_delete_target()
{
    local raw="$1" resolved home_resolved home_parent
    [ -n "$raw" ] || return 1
    resolved="$(ableton_realpath_m "$raw")" || return 1
    home_resolved="$(ableton_realpath_m "$HOME")" || return 1
    home_parent="$(dirname "$home_resolved")"
    case "$resolved" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|"$home_resolved"|"$home_parent") return 1 ;;
    esac
    [ "${#resolved}" -gt 4 ] || return 1
    printf '%s\n' "$resolved"
}
