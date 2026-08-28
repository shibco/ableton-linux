#!/usr/bin/env bash
# Strict, data-only launcher preferences and the narrow PipeASIO buffer editor.
# Sourcing this file is intentionally side-effect free.

_ableton_preferences_path()
{
    printf '%s/ableton-wine/preferences\n' \
        "${XDG_CONFIG_HOME:-$HOME/.config}"
}

_ableton_no_nul()
{
    local path="$1"
    ! LC_ALL=C od -An -v -tu1 -- "$path" 2>/dev/null | grep -qw 0
}

_ableton_audio_threads_valid()
{
    case "$1" in
        auto|off) return 0 ;;
    esac
    [[ "$1" =~ ^([1-9]|[1-5][0-9]|6[0-3])$ ]]
}

_ableton_dpi_stored_valid()
{
    case "$1" in auto|100|fractional|preserve) return 0 ;; esac
    return 1
}

_ableton_dpi_environment_valid()
{
    local value="$1" number
    _ableton_dpi_stored_valid "$value" && return 0
    case "$value" in
        dpi*) number="${value#dpi}" ;;
        fractional*) number="${value#fractional}" ;;
        *) return 1 ;;
    esac
    [[ "$number" =~ ^[0-9]+$ ]] \
        && [ "$number" -ge 72 ] && [ "$number" -le 384 ]
}

_ableton_preferences_values_valid()
{
    local shortcuts="$1" dpi="$2" threads="$3" rt="$4" power="$5"
    case "$shortcuts" in take|preserve) ;; *) return 1 ;; esac
    _ableton_dpi_stored_valid "$dpi" || return 1
    _ableton_audio_threads_valid "$threads" || return 1
    case "$rt" in auto|off) ;; *) return 1 ;; esac
    case "$power" in performance|balanced|off) ;; *) return 1 ;; esac
}

_ableton_preferences_parse()
{
    local path="$1"
    local -a lines=()
    [ -f "$path" ] && [ ! -L "$path" ] && _ableton_no_nul "$path" \
        || return 1
    mapfile -t lines < "$path" || return 1
    [ "${#lines[@]}" -eq 7 ] || return 1
    [ "$(tail -c 1 -- "$path" | od -An -tu1 | tr -d '[:space:]')" = 10 ] \
        || return 1
    [ "${lines[0]}" = '# ableton-linux launcher preferences; managed by the installer' ] \
        && [ "${lines[1]}" = format=1 ] \
        && [[ "${lines[2]}" == shortcuts=* ]] \
        && [[ "${lines[3]}" == dpi=* ]] \
        && [[ "${lines[4]}" == audio_threads=* ]] \
        && [[ "${lines[5]}" == rt=* ]] \
        && [[ "${lines[6]}" == power=* ]] || return 1
    ABLETON_PREFERENCES_SHORTCUTS="${lines[2]#*=}"
    ABLETON_PREFERENCES_DPI="${lines[3]#*=}"
    ABLETON_PREFERENCES_AUDIO_THREADS="${lines[4]#*=}"
    ABLETON_PREFERENCES_RT="${lines[5]#*=}"
    ABLETON_PREFERENCES_POWER="${lines[6]#*=}"
    _ableton_preferences_values_valid \
        "$ABLETON_PREFERENCES_SHORTCUTS" "$ABLETON_PREFERENCES_DPI" \
        "$ABLETON_PREFERENCES_AUDIO_THREADS" "$ABLETON_PREFERENCES_RT" \
        "$ABLETON_PREFERENCES_POWER"
}

ableton_preferences_valid()
{
    _ableton_preferences_parse "${1:?preference path is required}"
}

# The token deliberately includes identity, metadata, and bytes. Unsafe direct
# objects still receive a token so a caller can snapshot them without guessing
# their type, but writers below refuse them regardless of token equality.
ableton_preferences_object_token()
{
    local path="${1:?object path is required}" metadata digest target
    if [ -L "$path" ]; then
        metadata="$(stat -c '%d|%i|%f|%a|%u|%g|%s|%h|%w|%y|%z' -- "$path")" \
            || return 1
        target="$(readlink -- "$path")" || return 1
        printf 'symlink|%s|%s\n' "$metadata" "$target"
    elif [ -f "$path" ]; then
        metadata="$(stat -c '%d|%i|%f|%a|%u|%g|%s|%h|%w|%y|%z' -- "$path")" \
            || return 1
        digest="$(sha256sum -- "$path" | awk '{print $1}')" || return 1
        printf 'file|%s|%s\n' "$metadata" "$digest"
    elif [ -e "$path" ]; then
        metadata="$(stat -c '%d|%i|%f|%a|%u|%g|%s|%h|%w|%y|%z' -- "$path")" \
            || return 1
        printf 'other|%s\n' "$metadata"
    else
        printf 'absent\n'
    fi
}

_ableton_preferences_load_or_defaults()
{
    local path="$1"
    ABLETON_PREFERENCES_SHORTCUTS=take
    ABLETON_PREFERENCES_DPI=auto
    ABLETON_PREFERENCES_AUDIO_THREADS=auto
    ABLETON_PREFERENCES_RT=auto
    ABLETON_PREFERENCES_POWER=performance
    if [ -e "$path" ] || [ -L "$path" ]; then
        if ! _ableton_preferences_parse "$path"; then
            printf '!! launcher preferences are malformed; using defaults: %s\n' \
                "$path" >&2
            ABLETON_PREFERENCES_SHORTCUTS=take
            ABLETON_PREFERENCES_DPI=auto
            ABLETON_PREFERENCES_AUDIO_THREADS=auto
            ABLETON_PREFERENCES_RT=auto
            ABLETON_PREFERENCES_POWER=performance
            return 1
        fi
    fi
    return 0
}

ableton_preferences_apply()
{
    local path="${1:-$(_ableton_preferences_path)}"
    local env_shortcuts="${ABLETON_SHORTCUTS-}" env_dpi="${ABLETON_DPI_MODE-}"
    local env_threads="${ABLETON_MAX_AUDIO_THREADS-}" env_rt="${ABLETON_RT-}"
    local env_power="${ABLETON_POWER-}"
    _ableton_preferences_load_or_defaults "$path" || true

    [ -z "$env_shortcuts" ] || ABLETON_PREFERENCES_SHORTCUTS="$env_shortcuts"
    [ -z "$env_dpi" ] || ABLETON_PREFERENCES_DPI="$env_dpi"
    [ -z "$env_threads" ] || ABLETON_PREFERENCES_AUDIO_THREADS="$env_threads"
    [ -z "$env_rt" ] || ABLETON_PREFERENCES_RT="$env_rt"
    if [ -n "$env_power" ]; then
        case "$env_power" in
            on|auto) ABLETON_PREFERENCES_POWER=performance ;;
            *) ABLETON_PREFERENCES_POWER="$env_power" ;;
        esac
    fi

    case "$ABLETON_PREFERENCES_SHORTCUTS" in take|preserve) ;; *)
        printf '!! ABLETON_SHORTCUTS must be take or preserve\n' >&2; return 2 ;;
    esac
    _ableton_dpi_environment_valid "$ABLETON_PREFERENCES_DPI" || {
        printf '!! ABLETON_DPI_MODE must be auto, 100, fractional, preserve, dpi<N>, or fractional<N>\n' >&2
        return 2
    }
    _ableton_audio_threads_valid "$ABLETON_PREFERENCES_AUDIO_THREADS" || {
        printf '!! ABLETON_MAX_AUDIO_THREADS must be auto, off, or 1 through 63\n' >&2
        return 2
    }
    case "$ABLETON_PREFERENCES_RT" in auto|off) ;; *)
        printf '!! ABLETON_RT must be auto or off\n' >&2; return 2 ;;
    esac
    case "$ABLETON_PREFERENCES_POWER" in performance|balanced|off) ;; *)
        printf '!! ABLETON_POWER must be performance, balanced, or off\n' >&2; return 2 ;;
    esac

    ABLETON_SHORTCUTS="$ABLETON_PREFERENCES_SHORTCUTS"
    ABLETON_DPI_MODE="$ABLETON_PREFERENCES_DPI"
    ABLETON_MAX_AUDIO_THREADS="$ABLETON_PREFERENCES_AUDIO_THREADS"
    ABLETON_RT="$ABLETON_PREFERENCES_RT"
    ABLETON_POWER="$ABLETON_PREFERENCES_POWER"
    export ABLETON_SHORTCUTS ABLETON_DPI_MODE ABLETON_MAX_AUDIO_THREADS \
        ABLETON_RT ABLETON_POWER
}

ableton_preferences_merge()
{
    local path="${1:?preference path is required}"
    local shortcuts="${2-}" dpi="${3-}" threads="${4-}" rt="${5-}" power="${6-}"
    _ableton_preferences_load_or_defaults "$path" || true
    [ -z "$shortcuts" ] || ABLETON_PREFERENCES_SHORTCUTS="$shortcuts"
    [ -z "$dpi" ] || ABLETON_PREFERENCES_DPI="$dpi"
    [ -z "$threads" ] || ABLETON_PREFERENCES_AUDIO_THREADS="$threads"
    [ -z "$rt" ] || ABLETON_PREFERENCES_RT="$rt"
    [ -z "$power" ] || ABLETON_PREFERENCES_POWER="$power"
    _ableton_preferences_values_valid \
        "$ABLETON_PREFERENCES_SHORTCUTS" "$ABLETON_PREFERENCES_DPI" \
        "$ABLETON_PREFERENCES_AUDIO_THREADS" "$ABLETON_PREFERENCES_RT" \
        "$ABLETON_PREFERENCES_POWER" || return 2
    printf '%s|%s|%s|%s|%s\n' \
        "$ABLETON_PREFERENCES_SHORTCUTS" "$ABLETON_PREFERENCES_DPI" \
        "$ABLETON_PREFERENCES_AUDIO_THREADS" "$ABLETON_PREFERENCES_RT" \
        "$ABLETON_PREFERENCES_POWER"
}

_ableton_token_matches()
{
    local path="$1" expected="$2" current
    current="$(ableton_preferences_object_token "$path")" || return 1
    [ "$current" = "$expected" ]
}

_ableton_pipeasio_seed_encode()
{
    printf '%s' "$1" | base64 | tr -d '\n'
}

_ableton_pipeasio_seed_decode()
{
    local encoded="$1" decoded canonical
    [ -n "$encoded" ] && [[ "$encoded" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
    decoded="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)" || return 1
    canonical="$(_ableton_pipeasio_seed_encode "$decoded")" || return 1
    [ "$canonical" = "$encoded" ] || return 1
    printf '%s' "$decoded"
}

_ableton_pipeasio_full_token_valid()
{
    local token="$1" timestamp number pattern
    timestamp='[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{9} [+-][0-9]{4}'
    number='[0-9]+'
    pattern="^file[|]${number}[|]${number}[|][0-9a-f]+[|][0-7]+[|]${number}[|]${number}[|]${number}[|]${number}[|](-|${timestamp})[|]${timestamp}[|]${timestamp}[|][0-9a-f]{64}$"
    [[ "$token" =~ $pattern ]]
}

_ableton_pipeasio_seed_identity_valid()
{
    local token="$1" timestamp number pattern
    timestamp='[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{9} [+-][0-9]{4}'
    number='[0-9]+'
    pattern="^seed-file[|]${number}[|]${number}[|][0-9a-f]+[|][0-7]+[|]${number}[|]${number}[|]${number}[|](-|${timestamp})[|]${timestamp}[|][0-9a-f]{64}$"
    [[ "$token" =~ $pattern ]]
}

# Producer identity deliberately omits ctime, the one inode field changed by
# the no-clobber rename itself. Device, inode, birth/mtime, metadata and bytes
# remain stable across that rename and distinguish a same-value replacement.
ableton_pipeasio_seed_identity_token()
{
    local path="${1:?PipeASIO seed path is required}" metadata digest
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    metadata="$(stat -c '%d|%i|%f|%a|%u|%g|%s|%w|%y' -- "$path")" \
        || return 1
    digest="$(sha256sum -- "$path" | awk '{print $1}')" || return 1
    printf 'seed-file|%s|%s\n' "$metadata" "$digest"
}

_ableton_pipeasio_seed_temp_valid()
{
    local final_path="$1" temp_path="$2" temp_name
    [ "$(dirname -- "$temp_path")" = "$(dirname -- "$final_path")" ] || return 1
    temp_name="$(basename -- "$temp_path")"
    [[ "$temp_name" =~ ^[.]config[.]ini[.][A-Za-z0-9]{6}$ ]]
}

# A fresh PipeASIO file belongs to prefix setup only while this exact object
# generation remains in place.  The durable record lets both an in-process
# failure and the outer installer roll it back without guessing from content.
ableton_pipeasio_seed_record_load()
{
    local txn="${1:?transaction directory is required}"
    local record="$txn/pipeasio-seed.v1" path_encoded token_encoded temp_encoded
    local expected_path="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
    local -a lines=()
    ABLETON_PIPEASIO_SEED_PRESENT=0
    ABLETON_PIPEASIO_SEED_PATH=""
    ABLETON_PIPEASIO_SEED_TOKEN=""
    ABLETON_PIPEASIO_SEED_TEMP=""
    if [ ! -e "$record" ] && [ ! -L "$record" ]; then
        return 0
    fi
    [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] \
        && _ableton_no_nul "$record" || return 1
    mapfile -t lines < "$record" || return 1
    [ "${#lines[@]}" -eq 4 ] \
        && [ "$(tail -c 1 -- "$record" | od -An -tu1 | tr -d '[:space:]')" = 10 ] \
        && [ "${lines[0]}" = format=1 ] \
        && [[ "${lines[1]}" == path_b64=* ]] \
        && [[ "${lines[2]}" == token_b64=* ]] \
        && [[ "${lines[3]}" == temp_b64=* ]] || return 1
    path_encoded="${lines[1]#*=}"
    token_encoded="${lines[2]#*=}"
    temp_encoded="${lines[3]#*=}"
    ABLETON_PIPEASIO_SEED_PATH="$(_ableton_pipeasio_seed_decode "$path_encoded")" \
        || return 1
    ABLETON_PIPEASIO_SEED_TOKEN="$(_ableton_pipeasio_seed_decode "$token_encoded")" \
        || return 1
    [ "$ABLETON_PIPEASIO_SEED_PATH" = "$expected_path" ] || return 1
    if _ableton_pipeasio_full_token_valid "$ABLETON_PIPEASIO_SEED_TOKEN"; then
        [ -z "$temp_encoded" ] || return 1
    elif _ableton_pipeasio_seed_identity_valid "$ABLETON_PIPEASIO_SEED_TOKEN"; then
        ABLETON_PIPEASIO_SEED_TEMP="$(_ableton_pipeasio_seed_decode "$temp_encoded")" \
            || return 1
        _ableton_pipeasio_seed_temp_valid "$ABLETON_PIPEASIO_SEED_PATH" \
            "$ABLETON_PIPEASIO_SEED_TEMP" || return 1
    else
        return 1
    fi
    ABLETON_PIPEASIO_SEED_PRESENT=1
}

ableton_pipeasio_seed_record_preflight()
{
    ableton_pipeasio_seed_record_load "${1:?transaction directory is required}"
}

ableton_pipeasio_seed_record_commit_preflight()
{
    ableton_pipeasio_seed_record_load "${1:?transaction directory is required}" \
        || return 1
    [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 0 ] \
        || { _ableton_pipeasio_full_token_valid "$ABLETON_PIPEASIO_SEED_TOKEN" \
             && [ -z "$ABLETON_PIPEASIO_SEED_TEMP" ]; }
}

_ableton_pipeasio_seed_record_write()
{
    local txn="${1:?transaction directory is required}"
    local path="${2:?PipeASIO path is required}" token="${3:?generation token is required}"
    local temp_path="${4-}" expected="${5:?expected record generation is required}"
    local expected_temp="${6-}"
    local record="$txn/pipeasio-seed.v1" tmp="" path_encoded token_encoded temp_encoded=""
    local expected_path="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
    [ "$path" = "$expected_path" ] || return 1
    if _ableton_pipeasio_full_token_valid "$token"; then
        [ -z "$temp_path" ] || return 1
    elif _ableton_pipeasio_seed_identity_valid "$token"; then
        _ableton_pipeasio_seed_temp_valid "$path" "$temp_path" || return 1
        temp_encoded="$(_ableton_pipeasio_seed_encode "$temp_path")" || return 1
    else
        return 1
    fi
    path_encoded="$(_ableton_pipeasio_seed_encode "$path")" || return 1
    token_encoded="$(_ableton_pipeasio_seed_encode "$token")" || return 1
    (
        cleanup_pipeasio_seed_record_tmp()
        {
            [ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
        }
        trap cleanup_pipeasio_seed_record_tmp EXIT HUP INT TERM XFSZ
        umask 077
        tmp="$(mktemp "$txn/.pipeasio-seed.XXXXXX")" || exit 1
        printf 'format=1\npath_b64=%s\ntoken_b64=%s\ntemp_b64=%s\n' \
            "$path_encoded" "$token_encoded" "$temp_encoded" > "$tmp" || exit 1
        chmod 600 "$tmp" || exit 1
        ableton_pipeasio_seed_record_load "$txn" || exit 1
        if [ "$expected" = absent ]; then
            [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 0 ] || exit 1
            mv -T -n -- "$tmp" "$record" || exit 1
        else
            [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ] \
                && [ "$ABLETON_PIPEASIO_SEED_PATH" = "$path" ] \
                && [ "$ABLETON_PIPEASIO_SEED_TOKEN" = "$expected" ] \
                && [ "$ABLETON_PIPEASIO_SEED_TEMP" = "$expected_temp" ] || exit 1
            mv -T -f -- "$tmp" "$record" || exit 1
        fi
        [ ! -e "$tmp" ] && [ -f "$record" ] && [ ! -L "$record" ] || exit 1
        tmp=""
    ) || return 1
    ableton_pipeasio_seed_record_load "$txn" \
        && [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ] \
        && [ "$ABLETON_PIPEASIO_SEED_PATH" = "$path" ] \
        && [ "$ABLETON_PIPEASIO_SEED_TOKEN" = "$token" ] \
        && [ "$ABLETON_PIPEASIO_SEED_TEMP" = "$temp_path" ]
}

ableton_pipeasio_seed_record_publish()
{
    _ableton_pipeasio_seed_record_write \
        "${1:?transaction directory is required}" \
        "${2:?PipeASIO path is required}" \
        "${3:?generation token is required}" "${4-}" absent ""
}

ableton_pipeasio_seed_record_promote()
{
    local txn="${1:?transaction directory is required}"
    local path="${2:?PipeASIO path is required}"
    local provisional="${3:?provisional producer token is required}"
    local identity_before full_token identity_after provisional_temp
    _ableton_pipeasio_seed_identity_valid "$provisional" || return 1
    ableton_pipeasio_seed_record_load "$txn" || return 1
    [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ] \
        && [ "$ABLETON_PIPEASIO_SEED_PATH" = "$path" ] \
        && [ "$ABLETON_PIPEASIO_SEED_TOKEN" = "$provisional" ] || return 1
    provisional_temp="$ABLETON_PIPEASIO_SEED_TEMP"
    [ -n "$provisional_temp" ] \
        && [ ! -e "$provisional_temp" ] && [ ! -L "$provisional_temp" ] || return 1
    identity_before="$(ableton_pipeasio_seed_identity_token "$path")" || return 1
    [ "$identity_before" = "$provisional" ] || return 1
    full_token="$(ableton_preferences_object_token "$path")" || return 1
    _ableton_pipeasio_full_token_valid "$full_token" || return 1
    identity_after="$(ableton_pipeasio_seed_identity_token "$path")" || return 1
    [ "$identity_after" = "$provisional" ] \
        && _ableton_token_matches "$path" "$full_token" || return 1
    _ableton_pipeasio_seed_record_write "$txn" "$path" "$full_token" "" \
        "$provisional" "$provisional_temp"
}

ableton_pipeasio_seed_record_rollback()
{
    local txn="${1:?transaction directory is required}"
    local record="$txn/pipeasio-seed.v1"
    ableton_pipeasio_seed_record_load "$txn" || return 1
    [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ] || return 0
    if _ableton_pipeasio_full_token_valid "$ABLETON_PIPEASIO_SEED_TOKEN"; then
        if _ableton_token_matches "$ABLETON_PIPEASIO_SEED_PATH" \
                "$ABLETON_PIPEASIO_SEED_TOKEN"; then
            rm -f -- "$ABLETON_PIPEASIO_SEED_PATH" || return 1
            [ ! -e "$ABLETON_PIPEASIO_SEED_PATH" ] \
                && [ ! -L "$ABLETON_PIPEASIO_SEED_PATH" ] || return 1
        fi
    else
        local candidate current_identity
        for candidate in "$ABLETON_PIPEASIO_SEED_PATH" "$ABLETON_PIPEASIO_SEED_TEMP"; do
            current_identity="$(ableton_pipeasio_seed_identity_token \
                "$candidate" 2>/dev/null || true)"
            [ "$current_identity" = "$ABLETON_PIPEASIO_SEED_TOKEN" ] || continue
            rm -f -- "$candidate" || return 1
            [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
        done
    fi
    rm -f -- "$record"
}

ableton_pipeasio_seed_record_commit()
{
    local txn="${1:?transaction directory is required}"
    local record="$txn/pipeasio-seed.v1"
    ableton_pipeasio_seed_record_commit_preflight "$txn" || return 1
    [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ] || return 0
    rm -f -- "$record"
}

ableton_preferences_write()
{
    local path="${1:?preference path is required}" expected="${2:?generation token is required}"
    local shortcuts="${3-}" dpi="${4-}" threads="${5-}" rt="${6-}" power="${7-}"
    local parent current
    _ableton_preferences_values_valid "$shortcuts" "$dpi" "$threads" "$rt" "$power" \
        || return 2
    current="$(ableton_preferences_object_token "$path")" || return 1
    [ "$current" = "$expected" ] || return 1
    case "$current" in
        absent) ;;
        file\|*) ableton_preferences_valid "$path" || return 1 ;;
        *) return 1 ;;
    esac
    parent="$(dirname -- "$path")"
    mkdir -p -- "$parent" || return 1
    [ -d "$parent" ] && [ ! -L "$path" ] || return 1
    (
        local tmp=""
        cleanup_preference_tmp()
        {
            [ -z "$tmp" ] || rm -f -- "$tmp" 2>/dev/null || true
        }
        trap cleanup_preference_tmp EXIT HUP INT TERM XFSZ
        tmp="$(mktemp "$parent/.preferences.XXXXXX")" || exit 1
        umask 077
        printf '%s\n' \
            '# ableton-linux launcher preferences; managed by the installer' \
            'format=1' "shortcuts=$shortcuts" "dpi=$dpi" \
            "audio_threads=$threads" "rt=$rt" "power=$power" > "$tmp" \
            || exit 1
        chmod 600 "$tmp" || exit 1
        _ableton_token_matches "$path" "$expected" || exit 1
        case "$expected" in
            absent)
                mv -T -n -- "$tmp" "$path" || exit 1
                [ ! -e "$tmp" ] || exit 1 ;;
            *) mv -T -f -- "$tmp" "$path" || exit 1 ;;
        esac
        tmp=""
    )
}

ableton_preferences_remove()
{
    local path="${1:?preference path is required}" expected="${2:?generation token is required}"
    ableton_preferences_valid "$path" || return 1
    _ableton_token_matches "$path" "$expected" || return 1
    rm -f -- "$path"
}

_ableton_pipeasio_analyse()
{
    local path="$1" line section="" index=0 value="" section_count=0 key_count=0
    ABLETON_PIPEASIO_LINES=()
    ABLETON_PIPEASIO_SECTION_END=-1
    ABLETON_PIPEASIO_KEY_INDEX=-1
    ABLETON_PIPEASIO_VALUE=""
    ABLETON_PIPEASIO_FINAL_NEWLINE=0
    [ -f "$path" ] && [ ! -L "$path" ] && _ableton_no_nul "$path" \
        || return 1
    mapfile -t ABLETON_PIPEASIO_LINES < "$path" || return 1
    if [ -s "$path" ] \
       && [ "$(tail -c 1 -- "$path" | od -An -tu1 | tr -d '[:space:]')" = 10 ]; then
        ABLETON_PIPEASIO_FINAL_NEWLINE=1
    fi
    for index in "${!ABLETON_PIPEASIO_LINES[@]}"; do
        line="${ABLETON_PIPEASIO_LINES[$index]}"
        if [[ "$line" =~ ^\[([^]]+)\][[:space:]]*$ ]]; then
            if [ "$section" = pipeasio ] && [ "$ABLETON_PIPEASIO_SECTION_END" -lt 0 ]; then
                ABLETON_PIPEASIO_SECTION_END="$index"
            fi
            section="${BASH_REMATCH[1]}"
            if [ "$section" = pipeasio ]; then
                section_count=$((section_count + 1))
            fi
            continue
        fi
        if [ "$section" = pipeasio ] \
           && [[ "$line" =~ ^[[:space:]]*buffer_size[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
            key_count=$((key_count + 1))
            value="${BASH_REMATCH[1]}"
            ABLETON_PIPEASIO_KEY_INDEX="$index"
        fi
    done
    [ "$section" != pipeasio ] || [ "$ABLETON_PIPEASIO_SECTION_END" -ge 0 ] \
        || ABLETON_PIPEASIO_SECTION_END="${#ABLETON_PIPEASIO_LINES[@]}"
    [ "$section_count" -eq 1 ] && [ "$key_count" -le 1 ] || return 1
    if [ "$key_count" -eq 1 ]; then
        [[ "$value" =~ ^[0-9]+$ ]] \
            && [ "$value" -ge 32 ] && [ "$value" -le 8192 ] || return 1
        ABLETON_PIPEASIO_VALUE="$value"
    fi
}

ableton_pipeasio_buffer_read()
{
    local path="${1:?PipeASIO path is required}"
    _ableton_pipeasio_analyse "$path" || return 1
    [ "$ABLETON_PIPEASIO_KEY_INDEX" -ge 0 ] || return 1
    printf '%s\n' "$ABLETON_PIPEASIO_VALUE"
}

ableton_pipeasio_buffer_write()
{
    local path="${1:?PipeASIO path is required}" expected="${2:?generation token is required}"
    local wanted="${3:?buffer value is required}" parent tmp index line inserted=0
    case "$wanted" in 64|128|256|512|1024) ;; *) return 2 ;; esac
    _ableton_token_matches "$path" "$expected" || return 1
    _ableton_pipeasio_analyse "$path" || return 1
    parent="$(dirname -- "$path")"
    tmp="$(mktemp "$parent/.config.ini.XXXXXX")" || return 1
    if ! (
        for index in "${!ABLETON_PIPEASIO_LINES[@]}"; do
            line="${ABLETON_PIPEASIO_LINES[$index]}"
            if [ "$ABLETON_PIPEASIO_KEY_INDEX" -eq "$index" ]; then
                if [[ "$line" =~ ^([[:space:]]*buffer_size[[:space:]]*=[[:space:]]*)[^[:space:]]+([[:space:]]*)$ ]]; then
                    printf '%s%s%s\n' "${BASH_REMATCH[1]}" "$wanted" "${BASH_REMATCH[2]}"
                else
                    exit 1
                fi
            else
                if [ "$ABLETON_PIPEASIO_KEY_INDEX" -lt 0 ] \
                   && [ "$inserted" -eq 0 ] \
                   && [ "$index" -eq "$ABLETON_PIPEASIO_SECTION_END" ]; then
                    printf 'buffer_size = %s\n' "$wanted"
                    inserted=1
                fi
                printf '%s\n' "$line"
            fi
        done
        if [ "$ABLETON_PIPEASIO_KEY_INDEX" -lt 0 ] && [ "$inserted" -eq 0 ]; then
            printf 'buffer_size = %s\n' "$wanted"
        fi
    ) > "$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    if [ "$ABLETON_PIPEASIO_FINAL_NEWLINE" -eq 0 ] && [ -s "$tmp" ]; then
        truncate -s -1 -- "$tmp" || {
            rm -f -- "$tmp" 2>/dev/null || true
            return 1
        }
    fi
    if ! chmod 600 "$tmp" || ! _ableton_token_matches "$path" "$expected"; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv -T -f -- "$tmp" "$path"; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
}
