#!/usr/bin/env bash
ableton_live_product_version()
{
    local exe="$1" key pattern key_bytes offset candidate

    [ -f "$exe" ] || return 1
    # Read the Live version from its embedded Windows version text.
    for key in ProductVersion FileVersion; do
        case "$key" in
            ProductVersion)
                pattern='P.r.o.d.u.c.t.V.e.r.s.i.o.n'
                key_bytes=30 ;;
            FileVersion)
                pattern='F.i.l.e.V.e.r.s.i.o.n'
                key_bytes=24 ;;
        esac
        while IFS= read -r offset; do
            case "$offset" in ''|*[!0-9]*) continue ;; esac
            candidate="$(dd if="$exe" bs=1 skip="$((offset + key_bytes))" count=64 \
                status=none 2>/dev/null | tr -d '\000')" || continue
            if [[ "$candidate" =~ ^([0-9]+\.){2}[0-9]+(\.[0-9]+)? ]]; then
                printf '%s\n' "${BASH_REMATCH[0]}"
                return 0
            fi
        done < <(LC_ALL=C grep -aob -- "$pattern" "$exe" 2>/dev/null | cut -d: -f1)
    done
    return 1
}

ableton_max_audio_marker_valid()
{
    local marker="$1"
    local -a rows

    [ -f "$marker" ] || return 1
    mapfile -t rows < "$marker"
    [ "${#rows[@]}" -eq 2 ] && [ "${rows[0]}" = format=1 ] \
        && [[ "${rows[1]}" =~ ^default=-MaxAudioThreads=([1-9]|[1-5][0-9]|6[0-3])$ ]]
}

ableton_live_preferences_path_allowed()
{
    local users_root="$1" path="$2" live_dir ableton_dir roaming_dir appdata_dir user_dir

    [ "${path##*/}" = Preferences ] || return 1
    live_dir="${path%/*}"
    [[ "${live_dir##*/}" =~ ^Live\ 12(\.[0-9]+){1,3}$ ]] || return 1
    ableton_dir="${live_dir%/*}"
    [ "${ableton_dir##*/}" = Ableton ] || return 1
    roaming_dir="${ableton_dir%/*}"
    [ "${roaming_dir##*/}" = Roaming ] || return 1
    appdata_dir="${roaming_dir%/*}"
    [ "${appdata_dir##*/}" = AppData ] || return 1
    user_dir="${appdata_dir%/*}"
    [ -n "${user_dir##*/}" ] && [ "${user_dir%/*}" = "$users_root" ]
}

ableton_prepare_live_preferences()
(
    local prefix="$1" version="$2" wine_user="$3"
    local prefix_real users_root users_token users_io user_path user_token user_io
    local appdata_path appdata_token appdata_io roaming_path roaming_token roaming_io
    local ableton_path ableton_token ableton_io live_path live_token live_io prefs_path profile
    local users_fd user_fd appdata_fd roaming_fd ableton_fd live_fd
    local -a profiles

    case "$version" in 12.*) ;; *) return 0 ;; esac
    case "$wine_user" in ''|.|..|*/*) return 0 ;; esac

    prefix_real="$(realpath -e -- "$prefix")" || return 1
    [ ! -L "$prefix/drive_c/users" ] || return 0
    users_root="$(realpath -e -- "$prefix/drive_c/users")" || return 1
    [ "$users_root" = "$prefix_real/drive_c/users" ] || return 0
    users_token="$(stat -c '%d:%i' -- "$users_root")" || return 1
    exec {users_fd}<"$users_root" || return 1
    users_io="/proc/$BASHPID/fd/$users_fd"
    [ -d "$users_io" ] \
        && [ "$(stat -Lc '%d:%i' -- "$users_io")" = "$users_token" ] || return 0

    user_path="$users_io/$wine_user"
    [ -d "$user_path" ] && [ ! -L "$user_path" ] || return 0
    user_token="$(stat -c '%d:%i' -- "$user_path")" || return 1
    exec {user_fd}<"$user_path" || return 1
    user_io="/proc/$BASHPID/fd/$user_fd"
    [ -d "$user_io" ] \
        && [ "$(stat -Lc '%d:%i' -- "$user_io")" = "$user_token" ] || return 0

    appdata_path="$user_io/AppData"
    [ -d "$appdata_path" ] && [ ! -L "$appdata_path" ] || return 0
    appdata_token="$(stat -c '%d:%i' -- "$appdata_path")" || return 1
    exec {appdata_fd}<"$appdata_path" || return 1
    appdata_io="/proc/$BASHPID/fd/$appdata_fd"
    [ -d "$appdata_io" ] \
        && [ "$(stat -Lc '%d:%i' -- "$appdata_io")" = "$appdata_token" ] || return 0

    roaming_path="$appdata_io/Roaming"
    [ -d "$roaming_path" ] && [ ! -L "$roaming_path" ] || return 0
    roaming_token="$(stat -c '%d:%i' -- "$roaming_path")" || return 1
    exec {roaming_fd}<"$roaming_path" || return 1
    roaming_io="/proc/$BASHPID/fd/$roaming_fd"
    [ -d "$roaming_io" ] \
        && [ "$(stat -Lc '%d:%i' -- "$roaming_io")" = "$roaming_token" ] || return 0

    ableton_path="$roaming_io/Ableton"
    if [ -L "$ableton_path" ] || { [ -e "$ableton_path" ] && [ ! -d "$ableton_path" ]; }; then
        echo "ableton-live: Use a directory inside the Wine prefix for Ableton settings." >&2
        return 0
    fi
    [ -d "$ableton_path" ] || mkdir -- "$ableton_path" || return 1
    ableton_token="$(stat -c '%d:%i' -- "$ableton_path")" || return 1
    exec {ableton_fd}<"$ableton_path" || return 1
    ableton_io="/proc/$BASHPID/fd/$ableton_fd"
    [ -d "$ableton_io" ] \
        && [ "$(stat -Lc '%d:%i' -- "$ableton_io")" = "$ableton_token" ] || return 0

    # Let Live transfer settings from an older version before the launcher creates the new directory.
    live_path="$ableton_io/Live $version"
    if [ ! -e "$live_path" ] && [ ! -L "$live_path" ]; then
        shopt -s nullglob
        profiles=("$ableton_io"/Live\ [0-9]*)
        shopt -u nullglob
        for profile in "${profiles[@]}"; do
            [ -e "$profile" ] || [ -L "$profile" ] || continue
            return 0
        done
    fi
    if [ -L "$live_path" ] || { [ -e "$live_path" ] && [ ! -d "$live_path" ]; }; then
        echo "ableton-live: Use a directory inside the Wine prefix for the Live version." >&2
        return 0
    fi
    [ -d "$live_path" ] || mkdir -- "$live_path" || return 1
    live_token="$(stat -c '%d:%i' -- "$live_path")" || return 1
    exec {live_fd}<"$live_path" || return 1
    live_io="/proc/$BASHPID/fd/$live_fd"
    [ -d "$live_io" ] \
        && [ "$(stat -Lc '%d:%i' -- "$live_io")" = "$live_token" ] || return 0

    prefs_path="$live_io/Preferences"
    # Let Live create its settings directory when another version already has settings.
    if [ ! -e "$prefs_path" ] && [ ! -L "$prefs_path" ]; then
        shopt -s nullglob
        profiles=("$ableton_io"/Live\ [0-9]*)
        shopt -u nullglob
        for profile in "${profiles[@]}"; do
            [ "$profile" = "$live_path" ] && continue
            [ -e "$profile" ] || [ -L "$profile" ] || continue
            return 0
        done
    fi
    if [ -L "$prefs_path" ] || { [ -e "$prefs_path" ] && [ ! -d "$prefs_path" ]; }; then
        echo "ableton-live: Use a directory inside the Wine prefix for Live settings." >&2
        return 0
    fi
    [ -d "$prefs_path" ] || mkdir -- "$prefs_path" || return 1
)

ableton_seed_max_audio_threads_in_dir()
(
    local users_root="$1" prefs="$2" option="$3"
    local prefs_real prefs_token prefs_fd prefs_io options marker options_tmp marker_tmp
    local options_token options_fd options_io="" options_write_fd options_write_io options_existing=0
    local live_dir ableton_dir candidate candidate_real candidate_token candidate_fd candidate_io
    local candidate_marker marker_token marker_fd marker_io candidate_options candidate_options_token
    local candidate_options_fd candidate_options_io marker_valid
    local line inherited_count="" inherit_policy=0 option_to_write
    local -a policy_dirs

    [ -d "$prefs" ] && [ ! -L "$prefs" ] || return 0
    prefs_real="$(realpath -e -- "$prefs")" || return 0
    if ! ableton_live_preferences_path_allowed "$users_root" "$prefs_real"; then
        echo "ableton-live: Keep the Live settings directory inside the Wine prefix: '$prefs'." >&2
        return 0
    fi

    # Use the checked directory for each later read and write.
    prefs_token="$(stat -c '%d:%i' -- "$prefs_real")" || return 1
    exec {prefs_fd}<"$prefs_real" || return 1
    prefs_io="/proc/$BASHPID/fd/$prefs_fd"
    [ -d "$prefs_io" ] \
        && [ "$(stat -Lc '%d:%i' -- "$prefs_io")" = "$prefs_token" ] || return 0
    options="$prefs_io/Options.txt"
    marker="$prefs_io/.ableton-linux-max-audio-threads-v1"

    # The marker preserves later user edits.
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 0
    if [ -L "$options" ] || { [ -e "$options" ] && [ ! -f "$options" ]; }; then
        echo "ableton-live: Use a regular file inside the Wine prefix for Live settings: '$prefs/Options.txt'." >&2
        return 0
    fi
    if [ -f "$options" ]; then
        options_token="$(stat -c '%d:%i' -- "$options")" || return 1
        exec {options_fd}<"$options" || return 1
        options_io="/proc/$BASHPID/fd/$options_fd"
        [ -f "$options_io" ] \
            && [ "$(stat -Lc '%d:%i' -- "$options_io")" = "$options_token" ] || return 0
        options_existing=1
    fi

    # Use the newest saved choice from another version of Live 12.
    live_dir="$prefs_io/.."
    ableton_dir="$live_dir/.."
    shopt -s nullglob
    policy_dirs=("$ableton_dir"/Live\ 12*/Preferences)
    shopt -u nullglob
    if [ "${#policy_dirs[@]}" -gt 0 ]; then
        mapfile -d '' -t policy_dirs < <(printf '%s\0' "${policy_dirs[@]}" | sort -zV)
    fi
    for candidate in "${policy_dirs[@]}"; do
        [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
        candidate_real="$(realpath -e -- "$candidate")" || continue
        ableton_live_preferences_path_allowed "$users_root" "$candidate_real" || continue
        candidate_token="$(stat -c '%d:%i' -- "$candidate_real")" || continue
        [ "$candidate_token" != "$prefs_token" ] || continue
        exec {candidate_fd}<"$candidate_real" || continue
        candidate_io="/proc/$BASHPID/fd/$candidate_fd"
        marker_valid=0
        candidate_marker="$candidate_io/.ableton-linux-max-audio-threads-v1"
        if [ -d "$candidate_io" ] \
           && [ "$(stat -Lc '%d:%i' -- "$candidate_io")" = "$candidate_token" ] \
           && [ -f "$candidate_marker" ] && [ ! -L "$candidate_marker" ]; then
            marker_token="$(stat -c '%d:%i' -- "$candidate_marker")" || marker_token=""
            if [ -n "$marker_token" ] && exec {marker_fd}<"$candidate_marker"; then
                marker_io="/proc/$BASHPID/fd/$marker_fd"
                if [ "$(stat -Lc '%d:%i' -- "$marker_io" 2>/dev/null || true)" = "$marker_token" ] \
                   && ableton_max_audio_marker_valid "$marker_io"; then
                    marker_valid=1
                fi
                exec {marker_fd}<&-
            fi
        fi
        if [ "$marker_valid" -eq 1 ]; then
            inherit_policy=1
            inherited_count=""
            candidate_options="$candidate_io/Options.txt"
            if [ -f "$candidate_options" ] && [ ! -L "$candidate_options" ]; then
                candidate_options_token="$(stat -c '%d:%i' -- "$candidate_options")" \
                    || candidate_options_token=""
                if [ -n "$candidate_options_token" ] \
                   && exec {candidate_options_fd}<"$candidate_options"; then
                    candidate_options_io="/proc/$BASHPID/fd/$candidate_options_fd"
                    if [ "$(stat -Lc '%d:%i' -- "$candidate_options_io" 2>/dev/null || true)" \
                         = "$candidate_options_token" ]; then
                        while IFS= read -r line || [ -n "$line" ]; do
                            line="${line%$'\r'}"
                            if [[ "$line" =~ ^-MaxAudioThreads(=|[[:space:]]+)([1-9]|[1-5][0-9]|6[0-3])[[:space:]]*$ ]]; then
                                inherited_count="${BASH_REMATCH[2]}"
                                break
                            fi
                        done < "$candidate_options_io"
                    fi
                    exec {candidate_options_fd}<&-
                fi
            fi
        fi
        exec {candidate_fd}<&-
    done

    if [ "$options_existing" -eq 1 ] \
       && tr -d '\r' < "$options_io" | grep -Eq '^-MaxAudioThreads([=[:space:]]|$)'; then
        echo "   The launcher found your audio thread setting."
    elif [ "$inherit_policy" -eq 1 ] && [ -z "$inherited_count" ]; then
        echo "   Live continues to select the audio thread count."
    else
        option_to_write="$option"
        [ -z "$inherited_count" ] || option_to_write="-MaxAudioThreads=$inherited_count"
        if [ "$options_existing" -eq 1 ]; then
            exec {options_write_fd}<>"$options" || return 0
            options_write_io="/proc/$BASHPID/fd/$options_write_fd"
            [ "$(stat -Lc '%d:%i' -- "$options_write_io" 2>/dev/null || true)" = "$options_token" ] \
                || return 0
            printf '\n%s\n' "$option_to_write" >> "$options_write_io" || return 1
            [ ! -L "$options" ] && [ "$options" -ef "$options_io" ] || return 0
        else
            options_tmp="$(mktemp "$prefs_io/.Options.txt.XXXXXX")" || return 1
            if ! printf '%s\n' "$option_to_write" > "$options_tmp" \
               || ! chmod 600 "$options_tmp"; then
                rm -f -- "$options_tmp"
                return 1
            fi
            if ! ln -- "$options_tmp" "$options"; then
                rm -f -- "$options_tmp"
                return 0
            fi
            rm -f -- "$options_tmp"
        fi
        echo "   The launcher set Live to use ${option_to_write#*=} audio threads."
    fi

    if [ "$options_existing" -eq 1 ]; then
        [ ! -L "$options" ] && [ "$options" -ef "$options_io" ] || return 0
    fi
    marker_tmp="$(mktemp "$prefs_io/.max-audio-threads-marker.XXXXXX")" || return 1
    if ! printf 'format=1\ndefault=%s\n' "$option" > "$marker_tmp" \
       || ! chmod 600 "$marker_tmp"; then
        rm -f -- "$marker_tmp"
        return 1
    fi
    if ! ln -- "$marker_tmp" "$marker"; then
        rm -f -- "$marker_tmp"
        return 0
    fi
    rm -f -- "$marker_tmp"
)

ableton_seed_max_audio_threads()
(
    local prefix="${1:?Provide a Wine prefix}"
    local count="${2:-16}"
    local live_exe="${3:-}" wine_user="${4:-${USER:-}}" live_version=""
    local prefix_real users_root prefs online available live_default option
    local -a preference_dirs

    case "$count" in
        [1-9]|[1-5][0-9]|6[0-3]) ;;
        *)
            echo "ableton-live: Set the audio thread count to a number from one to 63. The launcher received '$count'." >&2
            return 2 ;;
    esac

    online="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || return 0
    case "$online" in ''|*[!0-9]*) return 0 ;; esac
    if [ "${#online}" -gt 6 ]; then
        live_default=31
    else
        [ "$online" -ge 1 ] || return 0
        live_default=$((2 * online - 2))
        [ "$live_default" -ge 1 ] || live_default=1
        [ "$live_default" -le 31 ] || live_default=31
    fi
    [ "$count" -lt "$live_default" ] || return 0

    available="$(nproc 2>/dev/null)" || return 0
    case "$available" in ''|*[!0-9]*) return 0 ;; esac
    if [ "${#available}" -le 6 ]; then
        [ "$available" -ge 1 ] || return 0
        live_default=$((2 * available - 2))
        [ "$live_default" -ge 1 ] || live_default=1
        [ "$live_default" -le 31 ] || live_default=31
        [ "$count" -lt "$live_default" ] || return 0
    fi
    option="-MaxAudioThreads=$count"

    [ -d "$prefix/drive_c/users" ] || return 0
    prefix_real="$(realpath -e -- "$prefix")" || return 1
    if [ -L "$prefix/drive_c/users" ]; then
        echo "ableton-live: Use a directory inside the Wine prefix for user data." >&2
        return 0
    fi
    users_root="$(realpath -e -- "$prefix/drive_c/users")" || return 1
    if [ "$users_root" != "$prefix_real/drive_c/users" ]; then
        echo "ableton-live: Keep the user data directory inside the Wine prefix." >&2
        return 0
    fi
    live_version="$(ableton_live_product_version "$live_exe")" || live_version=""
    # A Live 11 version ends the settings search.
    # An empty version result selects the existing settings for Live 12.
    [ -z "$live_version" ] || [[ "$live_version" == 12.* ]] || return 0
    if [[ "$live_version" == 12.* ]]; then
        ableton_prepare_live_preferences "$prefix" "$live_version" "$wine_user" || return 1
        shopt -s nullglob
        preference_dirs=(
            "$prefix"/drive_c/users/*/AppData/Roaming/Ableton/Live\ "$live_version"/Preferences
        )
    else
        shopt -s nullglob
        preference_dirs=(
            "$prefix"/drive_c/users/*/AppData/Roaming/Ableton/Live\ 12*/Preferences
        )
    fi
    shopt -u nullglob

    for prefs in "${preference_dirs[@]}"; do
        ableton_seed_max_audio_threads_in_dir "$users_root" "$prefs" "$option" || return 1
    done
)
