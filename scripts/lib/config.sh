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
    local unexpected=""
    local -A seen=()
    expected="$(ableton_realpath_m "${XDG_STATE_HOME:-$HOME/.local/state}/ableton-wine")" \
        || return 1
    [ "$state" = "$expected" ] && [ -d "$state" ] && [ ! -L "$state" ] \
        && [ -O "$state" ] \
        && [ "$(stat -c '%a' -- "$state" 2>/dev/null || true)" = 700 ] || return 1
    # The shortcut hold was the sole state object written before ownership
    # markers.  Do not turn a broad basename exception into delete authority.
    unexpected="$(find "$state" -mindepth 1 -maxdepth 1 ! -name hold-v2 -print -quit)" \
        || return 1
    [ -z "$unexpected" ] && [ -e "$state/hold-v2" ] || return 1
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
        && [ -f "$runtime/lib/wine/x86_64-windows/pipeasio64.dll" ] \
        && [ -f "$runtime/lib/wine/x86_64-unix/pipeasio64.dll.so" ] || return 1
    pe_count="$(grep -Ec '^pipeasio-pe:[[:space:]]+[0-9a-f]{64}([[:space:]]|$)' "$info" 2>/dev/null || true)"
    unix_count="$(grep -Ec '^pipeasio-unix:[[:space:]]+[0-9a-f]{64}([[:space:]]|$)' "$info" 2>/dev/null || true)"
    [ "$pe_count" -eq 1 ] && [ "$unix_count" -eq 1 ] \
        && [ "$(grep -c '^pipeasio-pe:' "$info" 2>/dev/null || true)" -eq 1 ] \
        && [ "$(grep -c '^pipeasio-unix:' "$info" 2>/dev/null || true)" -eq 1 ] \
        && [ "$(grep -c '^dist-version:' "$info" 2>/dev/null || true)" -eq 1 ] || return 1
    pe_hash="$(sed -n 's/^pipeasio-pe:[[:space:]]*\([0-9a-f]\{64\}\).*$/\1/p' "$info")"
    unix_hash="$(sed -n 's/^pipeasio-unix:[[:space:]]*\([0-9a-f]\{64\}\).*$/\1/p' "$info")"
    [ "$(sha256sum -- "$runtime/lib/wine/x86_64-windows/pipeasio64.dll" | awk '{print $1}')" = "$pe_hash" ] \
        && [ "$(sha256sum -- "$runtime/lib/wine/x86_64-unix/pipeasio64.dll.so" | awk '{print $1}')" = "$unix_hash" ]
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
    local path="$1" literal referent referent_token object_stat digest
    if [ -L "$path" ]; then
        literal="$(readlink -n -- "$path")" || return 1
        referent="$(readlink -f -- "$path" 2>/dev/null || true)"
        if [ -n "$referent" ] && [ -f "$referent" ] && [ ! -L "$referent" ]; then
            digest="$(sha256sum -- "$referent" 2>/dev/null)" || digest=""
            digest="${digest%% *}"
            if [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
                referent_token="file:$digest"
            else
                object_stat="$(LC_ALL=C stat -c '%d:%i:%f:%s:%Y:%Z' -- "$path")" \
                    || return 1
                referent_token="unreadable:$object_stat"
            fi
        elif [ -z "$referent" ]; then
            referent_token=dangling
        else
            object_stat="$(LC_ALL=C stat -c '%d:%i:%f:%s:%Y:%Z' -- "$path")" \
                || return 1
            referent_token="nonfile:$object_stat"
        fi
        { printf 'symlink\0%s\0%s\n' "$literal" "$referent_token"; } \
            | sha256sum | awk '{print "symlink:"$1}'
    elif [ -f "$path" ]; then
        digest="$(sha256sum -- "$path" 2>/dev/null)" || digest=""
        digest="${digest%% *}"
        if [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
            printf 'file:%s\n' "$digest"
        else
            object_stat="$(LC_ALL=C stat -c '%d:%i:%f:%s:%Y:%Z' -- "$path")" \
                || return 1
            printf 'unreadable-file:%s\n' "$object_stat"
        fi
    elif [ ! -e "$path" ]; then
        printf 'absent\n'
    else
        object_stat="$(LC_ALL=C stat -c '%d:%i:%f:%s:%Y:%Z' -- "$path")" \
            || return 1
        printf 'nonfile:%s\n' "$object_stat"
    fi
}

ableton_config_snapshot_capture()
{
    local bound_token="${1:-}" values_record snapshot_path snapshot_token snapshot_values
    snapshot_path="$ABLETON_CONFIG_FILE"
    if [ -n "$bound_token" ]; then
        snapshot_token="$bound_token"
    else
        snapshot_token="$(ableton_config_object_token "$ABLETON_CONFIG_FILE")" \
            || return 1
    fi
    values_record="$(printf '%s\n' \
        "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" "$ABLETON_LINKD" "$ABLETON_LINK_MODE" \
        "$ABLETON_DATA_HOME" "$ABLETON_CONFIG_HOME" "$ABLETON_STATE_HOME" \
        "$ABLETON_CACHE_HOME" "$ABLETON_BIN_HOME" | sha256sum)" || return 1
    snapshot_values="${values_record%% *}"
    [[ "$snapshot_values" =~ ^[0-9a-f]{64}$ ]] || return 1
    # Publish the snapshot only after every field is ready. A failed recapture
    # must leave the prior complete record intact, never a mixed partial one.
    ABLETON_CONFIG_SNAPSHOT_PATH="$snapshot_path"
    ABLETON_CONFIG_SNAPSHOT_TOKEN="$snapshot_token"
    ABLETON_CONFIG_SNAPSHOT_VALUES="$snapshot_values"
    export ABLETON_CONFIG_SNAPSHOT_PATH ABLETON_CONFIG_SNAPSHOT_TOKEN ABLETON_CONFIG_SNAPSHOT_VALUES
}

ableton_config_snapshot_verify()
{
    local token values values_record
    if [ -z "${ABLETON_CONFIG_SNAPSHOT_PATH:-}" ] \
       && [ -z "${ABLETON_CONFIG_SNAPSHOT_TOKEN:-}" ] \
       && [ -z "${ABLETON_CONFIG_SNAPSHOT_VALUES:-}" ]; then
        return 0
    fi
    [ -n "${ABLETON_CONFIG_SNAPSHOT_PATH:-}" ] \
        && [ -n "${ABLETON_CONFIG_SNAPSHOT_TOKEN:-}" ] \
        && [ -n "${ABLETON_CONFIG_SNAPSHOT_VALUES:-}" ] || return 1
    [ "$ABLETON_CONFIG_FILE" = "$ABLETON_CONFIG_SNAPSHOT_PATH" ] || return 1
    token="$(ableton_config_object_token "$ABLETON_CONFIG_FILE")" || return 1
    values_record="$(printf '%s\n' \
        "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" "$ABLETON_LINKD" "$ABLETON_LINK_MODE" \
        "$ABLETON_DATA_HOME" "$ABLETON_CONFIG_HOME" "$ABLETON_STATE_HOME" \
        "$ABLETON_CACHE_HOME" "$ABLETON_BIN_HOME" | sha256sum)" || return 1
    values="${values_record%% *}"
    [[ "$values" =~ ^[0-9a-f]{64}$ ]] || return 1
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

# A project-written config may become invalid when a newer installer removes a
# field or an interrupted older writer leaves the tail incomplete.  Repair mode
# can still recover each unambiguous, syntactically safe known value from a
# regular file that has this project's exact header and one format=1 field.
# Unknown, duplicate, or invalid values are ignored independently.
ableton_config_salvage_values()
{
    local file="$1" line key value header="" format_count=0 format_value=""
    local -A counts=() values=()
    ABLETON_CONFIG_REPAIR_RUNTIME_ROOT=""
    ABLETON_CONFIG_REPAIR_PREFIX=""
    ABLETON_CONFIG_REPAIR_LIVE_MAJOR=""
    ABLETON_CONFIG_REPAIR_LINK_MODE=""
    ABLETON_CONFIG_REPAIR_LINKD=""
    [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
    [ "$(LC_ALL=C tr -cd '\000' < "$file" 2>/dev/null | wc -c)" -eq 0 ] || return 1
    IFS= read -r header < "$file" || return 1
    [ "$header" = '# ableton-linux installer configuration; managed by the installer' ] \
        || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" != "$header" ] || continue
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            format)
                format_count=$((format_count + 1))
                format_value="$value" ;;
            runtime_root|prefix|live_major|link_mode|linkd)
                counts["$key"]=$(( ${counts[$key]:-0} + 1 ))
                values["$key"]="$value" ;;
        esac
    done < "$file"
    [ "$format_count" -eq 1 ] && [ "$format_value" = 1 ] || return 1

    if [ "${counts[runtime_root]:-0}" -eq 1 ]; then
        value="${values[runtime_root]}"
        case "$value" in /*) case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) ;; *) ABLETON_CONFIG_REPAIR_RUNTIME_ROOT="$value" ;; esac ;; esac
    fi
    if [ "${counts[prefix]:-0}" -eq 1 ]; then
        value="${values[prefix]}"
        case "$value" in /*) case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) ;; *) ABLETON_CONFIG_REPAIR_PREFIX="$value" ;; esac ;; esac
    fi
    if [ "${counts[live_major]:-0}" -eq 1 ]; then
        case "${values[live_major]}" in
            11|12) ABLETON_CONFIG_REPAIR_LIVE_MAJOR="${values[live_major]}" ;;
        esac
    fi
    if [ "${counts[link_mode]:-0}" -eq 1 ]; then
        case "${values[link_mode]}" in
            off|session|always) ABLETON_CONFIG_REPAIR_LINK_MODE="${values[link_mode]}" ;;
        esac
    fi
    if [ "${counts[linkd]:-0}" -eq 1 ]; then
        value="${values[linkd]}"
        case "$value" in /*) case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) ;; *) ABLETON_CONFIG_REPAIR_LINKD="$value" ;; esac ;; esac
    fi
}

ableton_config_validate_layout()
{
    local requested="${1:-runtime prefix data config state bin}"
    local name configured first second i j
    local -a checked_paths=() independent_paths=()
    local -A seen=()
    [ "$requested" != none ] || return 0
    for name in $requested; do
        [ -z "${seen[$name]+x}" ] || continue
        seen["$name"]=1
        case "$name" in
            runtime) configured="$ABLETON_WINE_ROOT" ;;
            prefix) configured="$ABLETON_WINEPREFIX" ;;
            data) configured="$ABLETON_DATA_HOME" ;;
            config) configured="$ABLETON_CONFIG_HOME" ;;
            state) configured="$ABLETON_STATE_HOME" ;;
            bin) configured="$ABLETON_BIN_HOME" ;;
            *) ableton_config_error "unknown installation layout root: $name"; return 1 ;;
        esac
        checked_paths+=("$configured")
        [ "$name" = bin ] || independent_paths+=("$configured")
    done
    for configured in "${checked_paths[@]}"; do
        if [ -e "$configured" ] || [ -L "$configured" ]; then
            [ -d "$configured" ] && [ ! -L "$configured" ] || {
                ableton_config_error "installation directory path is not a real directory: $configured"
                return 1
            }
        fi
    done
    for ((i=0; i<${#independent_paths[@]}; i++)); do
        first="$(ableton_realpath_m "${independent_paths[i]}")" || return 1
        for ((j=i+1; j<${#independent_paths[@]}; j++)); do
            second="$(ableton_realpath_m "${independent_paths[j]}")" || return 1
            if [ "$first" = "$second" ] || [[ "$first" = "$second/"* ]] \
               || [[ "$second" = "$first/"* ]]; then
                ableton_config_error "installation roots overlap: $first and $second"
                return 1
            fi
        done
    done
}

ableton_config_paths_overlap()
{
    local first="$1" second="$2"
    [ "$first" = "$second" ] || [[ "$first" = "$second/"* ]] \
        || [[ "$second" = "$first/"* ]]
}

ableton_config_validate_write_layout()
{
    local protected
    # The writer uses CONFIG_HOME for its temporary file even when callers
    # select a custom CONFIG_FILE elsewhere, so both concrete destinations must
    # stay separate from every independently managed tree. The other roots are
    # compared as paths only: an unrelated stale object there is not a reason to
    # withhold otherwise safe installer settings.
    ableton_config_validate_layout config || return 1
    for protected in "$ABLETON_WINE_ROOT" "$ABLETON_WINEPREFIX" \
                     "$ABLETON_DATA_HOME" "$ABLETON_STATE_HOME" \
                     "$ABLETON_CACHE_HOME"; do
        if ableton_config_paths_overlap "$ABLETON_CONFIG_HOME" "$protected" \
           || ableton_config_paths_overlap "$ABLETON_CONFIG_FILE" "$protected"; then
            ableton_config_error "installer configuration path overlaps another installation path: $protected"
            return 1
        fi
    done
}

ableton_config_init()
{
    local requested_mode="${1:-}" repair_mode=0 config_valid=1
    case "$requested_mode" in
        repair) repair_mode=1 ;;
        strict)
            unset ABLETON_CONFIG_REPAIR_MODE ABLETON_CONFIG_REPAIR_NEEDED ;;
        '') ;;
        *) ableton_config_error "unknown installer configuration mode: $requested_mode"; return 1 ;;
    esac
    if [ -z "$requested_mode" ] \
       && [ "${ABLETON_CONFIG_REPAIR_MODE:-0}" = 1 ] \
       && [ -n "${ABLETON_CONFIG_SNAPSHOT_PATH:-}" ] \
       && [ -n "${ABLETON_CONFIG_SNAPSHOT_TOKEN:-}" ] \
       && [ -n "${ABLETON_CONFIG_SNAPSHOT_VALUES:-}" ]; then
        repair_mode=1
    fi
    if [ "$repair_mode" -eq 1 ]; then
        ABLETON_CONFIG_REPAIR_NEEDED=0
    fi
    ableton_require_home || return 1

    : "${ABLETON_DATA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine}"
    : "${ABLETON_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine}"
    : "${ABLETON_STATE_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/ableton-wine}"
    : "${ABLETON_CACHE_HOME:=${XDG_CACHE_HOME:-$HOME/.cache}/ableton-wine}"
    : "${ABLETON_BIN_HOME:=$HOME/.local/bin}"
    : "${ABLETON_CONFIG_FILE:=$ABLETON_CONFIG_HOME/config}"
    local config_file_name config_file_parent config_generation_before config_generation_after
    config_file_name="$(basename -- "$ABLETON_CONFIG_FILE")" || return 1
    config_file_parent="$(dirname -- "$ABLETON_CONFIG_FILE")" || return 1
    config_generation_before="$(ableton_config_object_token "$ABLETON_CONFIG_FILE")" || {
        ableton_config_error "cannot read installer configuration $ABLETON_CONFIG_FILE"
        return 1
    }
    if [ -e "$ABLETON_CONFIG_FILE" ] || [ -L "$ABLETON_CONFIG_FILE" ]; then
        if ! ableton_managed_config_valid "$ABLETON_CONFIG_FILE"; then
            config_valid=0
            if [ "$repair_mode" -ne 1 ]; then
                ableton_config_error "refusing malformed installer configuration $ABLETON_CONFIG_FILE"
                return 1
            fi
            ABLETON_CONFIG_REPAIR_NEEDED=1
            ableton_config_salvage_values "$ABLETON_CONFIG_FILE" 2>/dev/null || true
        fi
    fi

    local configured
    if [ -z "${ABLETON_WINE_ROOT+x}" ]; then
        configured=""
        if [ "$config_valid" -eq 1 ]; then
            configured="$(ableton_config_file_value runtime_root 2>/dev/null || true)"
        elif [ "$repair_mode" -eq 1 ]; then
            configured="${ABLETON_CONFIG_REPAIR_RUNTIME_ROOT:-}"
        fi
        ABLETON_WINE_ROOT="${configured:-$HOME/.local/opt/$ABLETON_RUNTIME_NAME}"
    fi
    if [ -z "${ABLETON_WINEPREFIX+x}" ]; then
        configured=""
        if [ "$config_valid" -eq 1 ]; then
            configured="$(ableton_config_file_value prefix 2>/dev/null || true)"
        elif [ "$repair_mode" -eq 1 ]; then
            configured="${ABLETON_CONFIG_REPAIR_PREFIX:-}"
        fi
        ABLETON_WINEPREFIX="${configured:-$HOME/.wine-ableton}"
    fi
    if [ -z "${ABLETON_LINK_MODE+x}" ]; then
        configured=""
        if [ "$config_valid" -eq 1 ]; then
            configured="$(ableton_config_file_value link_mode 2>/dev/null || true)"
        elif [ "$repair_mode" -eq 1 ]; then
            configured="${ABLETON_CONFIG_REPAIR_LINK_MODE:-}"
        fi
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
        configured=""
        if [ "$config_valid" -eq 1 ]; then
            configured="$(ableton_config_file_value live_major 2>/dev/null || true)"
        elif [ "$repair_mode" -eq 1 ]; then
            configured="${ABLETON_CONFIG_REPAIR_LIVE_MAJOR:-}"
        fi
        [ -z "$configured" ] || ABLETON_LIVE_VERSION="$configured"
    fi
    if [ -z "${ABLETON_LINKD+x}" ]; then
        configured=""
        if [ "$config_valid" -eq 1 ]; then
            configured="$(ableton_config_file_value linkd 2>/dev/null || true)"
        elif [ "$repair_mode" -eq 1 ]; then
            configured="${ABLETON_CONFIG_REPAIR_LINKD:-}"
        fi
        ABLETON_LINKD="${configured:-$ABLETON_DATA_HOME/ableton-linkd}"
    fi

    # The managed file is replaced atomically by compliant writers. Bind every
    # field read above to the generation that was present before parsing; a
    # replacement between individual reads must not produce a mixed A/B
    # configuration whose final B token is then treated as authoritative.
    config_generation_after="$(ableton_config_object_token "$ABLETON_CONFIG_FILE")" || {
        ableton_config_error "cannot reread installer configuration $ABLETON_CONFIG_FILE"
        return 1
    }
    if [ "$config_generation_after" != "$config_generation_before" ]; then
        ableton_config_error "installation configuration changed while it was being read; retry the command"
        return 1
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

    # Callers select only the roots their current operation will actually use.
    # This keeps destructive-layout checks strict without letting an unrelated
    # desktop/config/cache location veto core runtime work.
    ableton_config_validate_layout \
        "${ABLETON_CONFIG_LAYOUT_ROOTS:-runtime prefix data config state bin}" || return 1

    export ABLETON_WINE_ROOT ABLETON_WINEPREFIX ABLETON_LINK_MODE ABLETON_LINKD
    export ABLETON_DATA_HOME ABLETON_CONFIG_HOME ABLETON_STATE_HOME ABLETON_CACHE_HOME
    export ABLETON_BIN_HOME ABLETON_CONFIG_FILE
    export ABLETON_CONFIG_LAYOUT_ROOTS
    export ABLETON_PROTOCOL_DESKTOP_ID ABLETON_AUZ_DESKTOP_ID
    if [ "$repair_mode" -eq 1 ]; then
        ABLETON_CONFIG_REPAIR_MODE=1
        : "${ABLETON_CONFIG_REPAIR_NEEDED:=0}"
        export ABLETON_CONFIG_REPAIR_MODE ABLETON_CONFIG_REPAIR_NEEDED
    fi
    if [ -z "${ABLETON_CONFIG_SNAPSHOT_PATH:-}" ] \
       || [ -z "${ABLETON_CONFIG_SNAPSHOT_TOKEN:-}" ] \
       || [ -z "${ABLETON_CONFIG_SNAPSHOT_VALUES:-}" ]; then
        # Treat the exported snapshot as one record. A partial inherited
        # environment must be replaced, never trusted or expanded under set -u.
        ableton_config_snapshot_capture "$config_generation_before"
    fi
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
    if [ "${ABLETON_CONFIG_REPAIR_MODE:-0}" = 1 ]; then
        ableton_config_init repair || return 1
    else
        ableton_config_init || return 1
    fi
    local tmp
    # Configuration is optional after the core operation commits, but writing
    # it must still stay outside every independently managed tree. Callers may
    # have selected a narrower core-only layout during initialisation.
    ableton_config_validate_write_layout || return 1
    if [ -d "$ABLETON_CONFIG_FILE" ] && [ ! -L "$ABLETON_CONFIG_FILE" ]; then
        ableton_config_error "refusing to replace configuration directory $ABLETON_CONFIG_FILE"
        return 1
    fi
    if [ -L "$ABLETON_CONFIG_FILE" ]; then
        ableton_config_error "refusing symlink installer configuration $ABLETON_CONFIG_FILE"
        return 1
    fi
    if [ -e "$ABLETON_CONFIG_FILE" ] && [ ! -f "$ABLETON_CONFIG_FILE" ]; then
        ableton_config_error "refusing to replace non-file installer configuration $ABLETON_CONFIG_FILE"
        return 1
    fi
    ableton_config_snapshot_verify || {
        ableton_config_error "installation configuration changed; retry the command"
        return 1
    }
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
    ABLETON_CONFIG_REPAIR_NEEDED=0
    export ABLETON_CONFIG_REPAIR_NEEDED
}

ableton_mark_state_home()
{
    local marker marker_tmp first_entry=""
    if [ "${ABLETON_CONFIG_REPAIR_MODE:-0}" = 1 ]; then
        ableton_config_init repair || return 1
    else
        ableton_config_init || return 1
    fi
    marker="$ABLETON_STATE_HOME/.ableton-linux-state"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        ableton_state_marker_valid "$ABLETON_STATE_HOME" || {
            ableton_config_error "refusing malformed installation state marker $marker"
            return 1
        }
        return 0
    fi
    if [ -d "$ABLETON_STATE_HOME" ]; then
        if ! first_entry="$(find "$ABLETON_STATE_HOME" -mindepth 1 -maxdepth 1 -print -quit)"; then
            ableton_config_error "cannot inspect the existing installation state directory $ABLETON_STATE_HOME"
            return 1
        fi
        if [ -n "$first_entry" ]; then
            ableton_legacy_shortcut_state_valid "$ABLETON_STATE_HOME" || {
                ableton_config_error "refusing to claim nonempty unmarked state directory $ABLETON_STATE_HOME"
                return 1
            }
        fi
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

ableton_prepare_transactions_dir()
{
    local transactions="$ABLETON_STATE_HOME/transactions"
    ableton_mark_state_home || return 1
    # The exact state marker proves this child belongs to the project. Repair a
    # stale non-directory left by our own older work, but never follow or replace
    # a symlink and never act beneath an unproven state root.
    ableton_state_marker_valid "$ABLETON_STATE_HOME" || return 1
    if [ -L "$transactions" ]; then
        ableton_config_error "refusing symlink installer work directory $transactions"
        return 1
    fi
    if [ -e "$transactions" ] && [ ! -d "$transactions" ]; then
        rm -f -- "$transactions" 2>/dev/null || true
        if [ -e "$transactions" ] || [ -L "$transactions" ]; then
            ableton_config_error "cannot replace stale installer work file $transactions"
            return 1
        fi
    fi
    mkdir -p -- "$transactions" 2>/dev/null || true
    [ -d "$transactions" ] && [ ! -L "$transactions" ] || {
        ableton_config_error "cannot prepare installer work directory $transactions"
        return 1
    }
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
    if [ "${ABLETON_CONFIG_REPAIR_MODE:-0}" != 1 ] \
       || [ -z "${ABLETON_CONFIG_SNAPSHOT_PATH:-}" ] \
       || [ -z "${ABLETON_CONFIG_SNAPSHOT_TOKEN:-}" ] \
       || [ -z "${ABLETON_CONFIG_SNAPSHOT_VALUES:-}" ]; then
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
    fi
    expected="$(ableton_realpath_m "$HOME")" || return 1
    [ -d "$expected" ] && [ ! -L "$expected" ] || {
        ableton_config_error "cannot use HOME as the installation lock"
        return 1
    }
    case "$inherited" in
        ''|*[!0-9]*) ;;
        *)
            observed="$(readlink -f -- "/proc/${BASHPID:-$$}/fd/$inherited" 2>/dev/null || true)"
            if [ "$observed" = "$expected" ] && flock -n "$inherited"; then
                ableton_config_snapshot_verify || {
                    ableton_config_error "installation configuration changed; retry the command"
                    return 1
                }
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
        ableton_config_error "Another Ableton Linux install, repair, or removal is already running. Wait for it to finish and try again."
        return 1
    fi
    ABLETON_INSTALL_LOCK_FD="$lock_fd"
    export ABLETON_INSTALL_LOCK_FD
    # Deliberately not exported. An exec'd child may validate and reuse the
    # inherited descriptor, but only the shell that opened it may issue
    # LOCK_UN. BASHPID also distinguishes a forked Bash subshell from its parent.
    ABLETON_INSTALL_LOCK_OWNER_BASHPID="${BASHPID:-$$}"
    ableton_config_snapshot_verify || {
        ableton_config_error "installation configuration changed; retry the command"
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}<&-
        unset ABLETON_INSTALL_LOCK_FD ABLETON_INSTALL_LOCK_OWNER_BASHPID
        return 1
    }
}

# Launchers briefly participate in the lifecycle lock while they repair host
# integration and bring a Wine prefix up.  A spawned Wine/background process
# must close its inherited copy while the launcher keeps the lock; otherwise it
# can retain the installation lock for the whole application session.
ableton_install_lock_close_in_child()
{
    local inherited="${ABLETON_INSTALL_LOCK_FD:-}" observed expected
    case "$inherited" in ''|*[!0-9]*) return 0 ;; esac
    observed="$(readlink -f -- "/proc/${BASHPID:-$$}/fd/$inherited" 2>/dev/null || true)"
    expected="$(ableton_realpath_m "$HOME" 2>/dev/null || true)"
    [ -n "$expected" ] && [ "$observed" = "$expected" ] || return 1
    exec {inherited}<&- || return 1
    unset ABLETON_INSTALL_LOCK_FD ABLETON_INSTALL_LOCK_OWNER_BASHPID
}

ableton_install_lock_release()
{
    local inherited="${ABLETON_INSTALL_LOCK_FD:-}" observed expected rc=0
    case "$inherited" in ''|*[!0-9]*) return 0 ;; esac
    [ "${ABLETON_INSTALL_LOCK_OWNER_BASHPID:-}" = "${BASHPID:-$$}" ] || return 1
    observed="$(readlink -f -- "/proc/${BASHPID:-$$}/fd/$inherited" 2>/dev/null || true)"
    expected="$(ableton_realpath_m "$HOME" 2>/dev/null || true)"
    [ -n "$expected" ] && [ "$observed" = "$expected" ] || return 1
    flock -u "$inherited" || rc=1
    exec {inherited}<&- || rc=1
    unset ABLETON_INSTALL_LOCK_FD ABLETON_INSTALL_LOCK_OWNER_BASHPID
    return "$rc"
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
    local seconds="$1"; shift
    seconds="$(ableton_timeout_value "$seconds" timeout 1 86400)" || return 2
    command -v timeout >/dev/null 2>&1 || {
        ableton_config_error "GNU timeout is required to supervise external processes"
        return 127
    }
    # The parent keeps the lifecycle lock. Close its descriptor before external
    # commands start. Wine helpers can start background processes that would
    # keep later lifecycle commands locked after this process exits.
    (
        ableton_install_lock_close_in_child || exit 125
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
