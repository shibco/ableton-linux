#!/usr/bin/env bash
ableton_cpu_is_allowed()
{
    local cpu="$1" allowed="$2" part first last
    local IFS=,

    [[ "$cpu" =~ ^[0-9]+$ ]] || return 1
    for part in $allowed; do
        case "$part" in
            *-*) first="${part%%-*}"; last="${part#*-}" ;;
            *)   first="$part"; last="$part" ;;
        esac
        [[ "$first" =~ ^[0-9]+$ ]] && [[ "$last" =~ ^[0-9]+$ ]] || continue
        first=$((10#$first)); last=$((10#$last))
        if [ "$cpu" -ge "$first" ] && [ "$cpu" -le "$last" ]; then
            return 0
        fi
    done
    return 1
}

ableton_available_physical_cores()
(
    local topology_root="${1:-/sys/devices/system/cpu}" allowed="${2:-}"
    local cpu_dir cpu core package count
    local -a cpu_dirs
    local -A physical_cores=()

    if [ -z "$allowed" ]; then
        allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/self/status 2>/dev/null)"
    fi
    allowed="${allowed//[[:space:]]/}"
    [ -n "$allowed" ] || return 1

    shopt -s nullglob
    cpu_dirs=("$topology_root"/cpu[0-9]*)
    shopt -u nullglob
    for cpu_dir in "${cpu_dirs[@]}"; do
        cpu="${cpu_dir##*/cpu}"
        ableton_cpu_is_allowed "$cpu" "$allowed" || continue
        [ -r "$cpu_dir/topology/core_id" ] \
            && [ -r "$cpu_dir/topology/physical_package_id" ] || continue
        IFS= read -r core < "$cpu_dir/topology/core_id" || continue
        IFS= read -r package < "$cpu_dir/topology/physical_package_id" || continue
        [[ "$core" =~ ^-?[0-9]+$ ]] && [[ "$package" =~ ^-?[0-9]+$ ]] || continue
        physical_cores["$package:$core"]=1
    done

    count="${#physical_cores[@]}"
    [ "$count" -ge 1 ] || return 1
    [ "$count" -le 63 ] || count=63
    printf '%s\n' "$count"
)

ableton_cpu_list_valid()
{
    local list="${1:-}" part first last previous=-1
    local IFS=,

    [[ "$list" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 1
    for part in $list; do
        case "$part" in
            *-*) first="${part%%-*}"; last="${part#*-}" ;;
            *)   first="$part"; last="$part" ;;
        esac
        [ "${#first}" -le 6 ] && [ "${#last}" -le 6 ] || return 1
        first=$((10#$first)); last=$((10#$last))
        [ "$first" -le "$last" ] && [ "$first" -gt "$previous" ] || return 1
        previous="$last"
    done
}

ableton_cpu_list_count()
{
    local list="${1:-}" part first last count=0
    local IFS=,

    ableton_cpu_list_valid "$list" || return 1
    for part in $list; do
        case "$part" in
            *-*) first="${part%%-*}"; last="${part#*-}" ;;
            *)   first="$part"; last="$part" ;;
        esac
        first=$((10#$first)); last=$((10#$last))
        count=$((count + last - first + 1))
    done
    printf '%s\n' "$count"
}

ableton_cpu_report_token()
{
    local path="$1" value

    if [ ! -r "$path" ] || ! IFS= read -r value < "$path"; then
        printf 'unavailable\n'
        return 0
    fi
    value="${value//[[:space:]]/}"
    case "$value" in
        ''|*[!A-Za-z0-9_,.+=:-]*) printf 'invalid\n' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

ableton_cpu_report_integer()
{
    local value

    value="$(ableton_cpu_report_token "$1")"
    [[ "$value" =~ ^-?[0-9]+$ ]] || {
        printf '%s\n' "$value"
        return 0
    }
    [ "${#value}" -le 12 ] || value=invalid
    printf '%s\n' "$value"
}

ableton_cpu_report_frequency()
{
    local path value

    for path in "$@"; do
        value="$(ableton_cpu_report_token "$path")"
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        [ "${#value}" -le 12 ] || continue
        printf '%s\n' "$value"
        return 0
    done
    printf 'unavailable\n'
}

ableton_cpu_report_list()
{
    local value

    value="$(ableton_cpu_report_token "$1")"
    ableton_cpu_list_valid "$value" || {
        [ "$value" = unavailable ] || value=invalid
        printf '%s\n' "$value"
        return 0
    }
    printf '%s\n' "$value"
}

# Report CPU facts that help compare Live and Wine runs.
# Tests can supply alternate input roots. Normal runs read Linux system files
# and the processor set available to the report.
ableton_cpu_topology_report()
(
    local cpu_root="${1:-/sys/devices/system/cpu}"
    local proc_status="${2:-/proc/self/status}"
    local devices_root="${3:-/sys/devices}"
    local allowed="" allowed_source="" online possible discovered=""
    local cpu_dir cpu package core siblings capacity core_type max_khz current_khz
    local cppc_highest cppc_nominal amd_pstate_highest amd_pstate_ranking
    local amd_pstate_hw_prefcore amd_pstate_max_khz
    local allowed_count=0 reported=0 topology_complete=1 smt_seen=0 smt_unknown=0
    local smt_evidence heterogeneous_evidence=not_observed preferred_core_evidence=unavailable
    local wine_performance_cpus kernel_efficiency_cpus wine_class_source=unavailable
    local physical_count capacity_count type_count cppc_highest_count driver_ranking_count
    local amd_pstate_status amd_pstate_prefcore amd_pstate_dynamic_epp
    local -a cpu_dirs cpus rows=()
    local -A physical_cores=() capacities=() core_types=() cppc_highest_values=()
    local -A driver_ranking_values=()

    shopt -s nullglob
    cpu_dirs=("$cpu_root"/cpu[0-9]*)
    shopt -u nullglob
    for cpu_dir in "${cpu_dirs[@]}"; do
        cpu="${cpu_dir##*/cpu}"
        [[ "$cpu" =~ ^[0-9]+$ ]] && [ "${#cpu}" -le 6 ] || continue
        cpus+=("$((10#$cpu))")
    done
    if [ "${#cpus[@]}" -gt 0 ]; then
        mapfile -t cpus < <(printf '%s\n' "${cpus[@]}" | LC_ALL=C sort -n -u)
        for cpu in "${cpus[@]}"; do
            [ -z "$discovered" ] && discovered="$cpu" || discovered="$discovered,$cpu"
        done
    fi

    if [ -r "$proc_status" ]; then
        allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "$proc_status" 2>/dev/null | sed -n '1p')"
        allowed="${allowed//[[:space:]]/}"
    fi
    if ableton_cpu_list_valid "$allowed"; then
        allowed_source=proc_status
    else
        allowed="$(ableton_cpu_report_list "$cpu_root/online")"
        if ableton_cpu_list_valid "$allowed"; then
            allowed_source=sysfs_online_fallback
        elif ableton_cpu_list_valid "$discovered"; then
            allowed="$discovered"
            allowed_source=cpu_directory_fallback
        else
            allowed=unavailable
            allowed_source=unavailable
        fi
    fi
    online="$(ableton_cpu_report_list "$cpu_root/online")"
    possible="$(ableton_cpu_report_list "$cpu_root/possible")"
    if ableton_cpu_list_valid "$allowed"; then
        allowed_count="$(ableton_cpu_list_count "$allowed")"
    fi

    for cpu in "${cpus[@]}"; do
        ableton_cpu_is_allowed "$cpu" "$allowed" || continue
        cpu_dir="$cpu_root/cpu$cpu"
        package="$(ableton_cpu_report_integer "$cpu_dir/topology/physical_package_id")"
        core="$(ableton_cpu_report_integer "$cpu_dir/topology/core_id")"
        siblings="$(ableton_cpu_report_list "$cpu_dir/topology/thread_siblings_list")"
        capacity="$(ableton_cpu_report_integer "$cpu_dir/cpu_capacity")"
        core_type="$(ableton_cpu_report_token "$cpu_dir/topology/core_type")"
        max_khz="$(ableton_cpu_report_frequency \
            "$cpu_dir/cpufreq/cpuinfo_max_freq" "$cpu_dir/cpufreq/scaling_max_freq")"
        current_khz="$(ableton_cpu_report_frequency \
            "$cpu_dir/cpufreq/scaling_cur_freq" "$cpu_dir/cpufreq/cpuinfo_cur_freq")"
        cppc_highest="$(ableton_cpu_report_integer "$cpu_dir/acpi_cppc/highest_perf")"
        cppc_nominal="$(ableton_cpu_report_integer "$cpu_dir/acpi_cppc/nominal_perf")"
        amd_pstate_highest="$(ableton_cpu_report_integer \
            "$cpu_dir/cpufreq/amd_pstate_highest_perf")"
        amd_pstate_ranking="$(ableton_cpu_report_integer \
            "$cpu_dir/cpufreq/amd_pstate_prefcore_ranking")"
        amd_pstate_hw_prefcore="$(ableton_cpu_report_token \
            "$cpu_dir/cpufreq/amd_pstate_hw_prefcore")"
        amd_pstate_max_khz="$(ableton_cpu_report_integer \
            "$cpu_dir/cpufreq/amd_pstate_max_freq")"

        if [[ "$package" =~ ^[0-9]+$ ]] && [[ "$core" =~ ^[0-9]+$ ]]; then
            physical_cores["$package:$core"]=1
        else
            topology_complete=0
        fi
        if ableton_cpu_list_valid "$siblings"; then
            [ "$(ableton_cpu_list_count "$siblings")" -le 1 ] || smt_seen=1
        else
            smt_unknown=1
            topology_complete=0
        fi
        [[ "$capacity" =~ ^[0-9]+$ ]] && capacities["$capacity"]=1
        case "$core_type" in unavailable|invalid) ;; *) core_types["$core_type"]=1 ;; esac
        [[ "$cppc_highest" =~ ^[0-9]+$ ]] && cppc_highest_values["$cppc_highest"]=1
        [[ "$amd_pstate_ranking" =~ ^[0-9]+$ ]] \
            && driver_ranking_values["$amd_pstate_ranking"]=1
        rows+=("cpu=$cpu package=$package core=$core siblings=$siblings cpu_capacity=$capacity core_type=$core_type max_khz=$max_khz current_khz=$current_khz cppc_highest_perf=$cppc_highest cppc_nominal_perf=$cppc_nominal amd_pstate_highest_perf=$amd_pstate_highest amd_pstate_prefcore_ranking=$amd_pstate_ranking amd_pstate_hw_prefcore=$amd_pstate_hw_prefcore amd_pstate_max_khz=$amd_pstate_max_khz")
        reported=$((reported + 1))
    done

    physical_count="${#physical_cores[@]}"
    capacity_count="${#capacities[@]}"
    type_count="${#core_types[@]}"
    cppc_highest_count="${#cppc_highest_values[@]}"
    driver_ranking_count="${#driver_ranking_values[@]}"
    if [ "$smt_seen" -eq 1 ]; then
        smt_evidence=present
    elif [ "$reported" -eq 0 ] || [ "$smt_unknown" -eq 1 ]; then
        smt_evidence=unknown
    else
        smt_evidence=not_observed
    fi
    [ "$reported" -gt 0 ] || topology_complete=0

    wine_performance_cpus="$(ableton_cpu_report_list "$devices_root/cpu_core/cpus")"
    kernel_efficiency_cpus="$(ableton_cpu_report_list "$devices_root/cpu_atom/cpus")"
    if ableton_cpu_list_valid "$wine_performance_cpus"; then
        wine_class_source=cpu_core/cpus
        heterogeneous_evidence=present
    fi
    ableton_cpu_list_valid "$kernel_efficiency_cpus" && heterogeneous_evidence=present
    [ "$capacity_count" -le 1 ] || heterogeneous_evidence=present
    [ "$type_count" -le 1 ] || heterogeneous_evidence=present

    amd_pstate_status="$(ableton_cpu_report_token "$cpu_root/amd_pstate/status")"
    amd_pstate_prefcore="$(ableton_cpu_report_token "$cpu_root/amd_pstate/prefcore")"
    amd_pstate_dynamic_epp="$(ableton_cpu_report_token "$cpu_root/amd_pstate/dynamic_epp")"
    if [ "$cppc_highest_count" -gt 1 ] || [ "$driver_ranking_count" -gt 1 ]; then
        preferred_core_evidence=present
    elif [ "$cppc_highest_count" -eq 1 ] || [ "$driver_ranking_count" -eq 1 ]; then
        preferred_core_evidence=not_observed
    fi

    printf 'cpu_topology_format=2\n'
    printf 'allowed_cpus=%s\n' "$allowed"
    printf 'allowed_source=%s\n' "$allowed_source"
    printf 'online_cpus=%s\n' "$online"
    printf 'possible_cpus=%s\n' "$possible"
    printf 'allowed_logical_cpus=%s\n' "$allowed_count"
    printf 'reported_logical_cpus=%s\n' "$reported"
    printf 'reported_physical_cores=%s\n' "$physical_count"
    printf 'smt_evidence=%s\n' "$smt_evidence"
    printf 'heterogeneous_evidence=%s\n' "$heterogeneous_evidence"
    printf 'preferred_core_evidence=%s\n' "$preferred_core_evidence"
    printf 'amd_pstate_status=%s\n' "$amd_pstate_status"
    printf 'amd_pstate_prefcore=%s\n' "$amd_pstate_prefcore"
    printf 'amd_pstate_dynamic_epp=%s\n' "$amd_pstate_dynamic_epp"
    printf 'topology_fields_complete=%s\n' "$([ "$topology_complete" -eq 1 ] && printf yes || printf no)"
    # Wine 11 reads the online CPU list and /sys/devices/cpu_core/cpus.
    # The report includes both inputs. A launched Windows probe is a separate
    # test.
    printf 'wine_topology_online_cpus=%s\n' "$online"
    printf 'wine_efficiency_class_source=%s\n' "$wine_class_source"
    printf 'wine_performance_cpus=%s\n' "$wine_performance_cpus"
    printf 'kernel_efficiency_cpus=%s\n' "$kernel_efficiency_cpus"
    printf 'wine_win32_efficiency_class_probe=not_run_read_only\n'
    printf 'frequency_note=current_khz_is_a_single_snapshot\n'
    printf '%s\n' "${rows[@]}"
)

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

# Replace a line the launcher wrote itself, so a second opt-in launch can change
# the count. Refuses unless the marker is valid, records a different count, and
# Options.txt holds exactly one -MaxAudioThreads line that is still the one the
# marker names: every other state is a user edit and is left alone.
#
# Both files are opened and inode-checked before use, and every read and write
# goes through the resulting descriptor. A name checked here is a different file
# by the time anything is written to it: replacing Options.txt with a symlink
# between the check and the write redirects the write outside the Wine prefix.
#
# Options.txt and the marker must never disagree. A marker recording a count the
# file does not contain matches nothing on the next launch, so the directory is
# declined for good. The old bytes go back if the marker cannot be replaced, and
# any failure returns 1 so the launcher reports it.
ableton_max_audio_rewrite_seeded()
{
    local prefs_io="$1" option="$2"
    local marker="$prefs_io/.ableton-linux-max-audio-threads-v1"
    local options="$prefs_io/Options.txt"
    local seeded line total=0 matched=0
    local marker_token marker_fd marker_io
    local options_token options_fd options_io saved staged staged_marker

    [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
    marker_token="$(stat -c '%d:%i' -- "$marker")" || return 0
    exec {marker_fd}<"$marker" || return 0
    marker_io="/proc/$BASHPID/fd/$marker_fd"
    if [ ! -f "$marker_io" ] \
       || [ "$(stat -Lc '%d:%i' -- "$marker_io")" != "$marker_token" ]; then
        exec {marker_fd}<&-
        return 0
    fi
    if ableton_max_audio_marker_valid "$marker_io"; then
        seeded="$(sed -n '2s/^default=//p' "$marker_io")"
    fi
    exec {marker_fd}<&-
    [ -n "$seeded" ] && [ "$seeded" != "$option" ] || return 0

    [ -f "$options" ] && [ ! -L "$options" ] || return 0
    options_token="$(stat -c '%d:%i' -- "$options")" || return 0
    exec {options_fd}<>"$options" || return 0
    options_io="/proc/$BASHPID/fd/$options_fd"
    if [ ! -f "$options_io" ] \
       || [ "$(stat -Lc '%d:%i' -- "$options_io")" != "$options_token" ]; then
        exec {options_fd}>&-
        return 0
    fi

    # Count every -MaxAudioThreads line, not just the seeded one: a second value
    # the user added is an edit, and rewriting around it would leave two.
    # CR stripped so a CRLF-edited copy is caught too.
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            -MaxAudioThreads|-MaxAudioThreads[=[:space:]]*)
                total=$((total + 1))
                [ "$line" = "$seeded" ] && matched=$((matched + 1)) ;;
        esac
    done < "$options_io"
    if [ "$total" -ne 1 ] || [ "$matched" -ne 1 ]; then
        exec {options_fd}>&-
        return 0
    fi

    saved="$(mktemp "$prefs_io/.Options.txt.XXXXXX")" || {
        exec {options_fd}>&-; return 0; }
    staged="$(mktemp "$prefs_io/.Options.txt.XXXXXX")" || {
        rm -f -- "$saved"; exec {options_fd}>&-; return 0; }
    staged_marker="$(mktemp "$prefs_io/.max-audio-threads-marker.XXXXXX")" || {
        rm -f -- "$saved" "$staged"; exec {options_fd}>&-; return 0; }

    # Stage everything before touching the file, so a failure costs nothing.
    if ! cat "$options_io" > "$saved" \
       || ! awk -v old="$seeded" -v new="$option" \
              '{ l = $0; sub(/\r$/, "", l) } l == old { print new; next } { print }' \
              "$options_io" > "$staged" \
       || ! printf 'format=1\ndefault=%s\n' "$option" > "$staged_marker" \
       || ! chmod 600 "$staged_marker"; then
        rm -f -- "$saved" "$staged" "$staged_marker"
        exec {options_fd}>&-
        return 1
    fi

    # Write through the pinned descriptor: keeps the file's permissions, and a
    # swapped pathname cannot redirect it.
    if ! cat "$staged" > "$options_io"; then
        rm -f -- "$saved" "$staged" "$staged_marker"
        exec {options_fd}>&-
        return 1
    fi
    if ! mv -T -f -- "$staged_marker" "$marker"; then
        cat "$saved" > "$options_io"
        rm -f -- "$saved" "$staged" "$staged_marker"
        exec {options_fd}>&-
        return 1
    fi
    rm -f -- "$saved" "$staged"
    exec {options_fd}>&-
    echo "   The launcher changed Live to use ${option#*=} audio threads."
}

# Remove only the line that an intact launcher marker still describes. The
# marker is removed with it, so ABLETON_MAX_AUDIO_THREADS=off restores Live's
# calculated count for this and later launches where the override remains set.
# A missing, malformed, replaced, or user-diverged pair is left untouched.
ableton_max_audio_remove_seeded()
{
    local prefs_io="$1"
    local marker="$prefs_io/.ableton-linux-max-audio-threads-v1"
    local options="$prefs_io/Options.txt"
    local seeded line total=0 matched=0
    local marker_token marker_fd marker_io
    local options_token options_fd options_io saved staged

    [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
    marker_token="$(stat -c '%d:%i' -- "$marker")" || return 0
    exec {marker_fd}<"$marker" || return 0
    marker_io="/proc/$BASHPID/fd/$marker_fd"
    if [ ! -f "$marker_io" ] \
       || [ "$(stat -Lc '%d:%i' -- "$marker_io")" != "$marker_token" ]; then
        exec {marker_fd}<&-
        return 0
    fi
    if ableton_max_audio_marker_valid "$marker_io"; then
        seeded="$(sed -n '2s/^default=//p' "$marker_io")"
    fi
    [ -n "$seeded" ] || { exec {marker_fd}<&-; return 0; }

    [ -f "$options" ] && [ ! -L "$options" ] \
        || { exec {marker_fd}<&-; return 0; }
    options_token="$(stat -c '%d:%i' -- "$options")" \
        || { exec {marker_fd}<&-; return 0; }
    exec {options_fd}<>"$options" || { exec {marker_fd}<&-; return 0; }
    options_io="/proc/$BASHPID/fd/$options_fd"
    if [ ! -f "$options_io" ] \
       || [ "$(stat -Lc '%d:%i' -- "$options_io")" != "$options_token" ]; then
        exec {options_fd}>&-
        exec {marker_fd}<&-
        return 0
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            -MaxAudioThreads|-MaxAudioThreads[=[:space:]]*)
                total=$((total + 1))
                [ "$line" = "$seeded" ] && matched=$((matched + 1)) ;;
        esac
    done < "$options_io"
    if [ "$total" -ne 1 ] || [ "$matched" -ne 1 ]; then
        exec {options_fd}>&-
        exec {marker_fd}<&-
        return 0
    fi

    saved="$(mktemp "$prefs_io/.Options.txt.XXXXXX")" || {
        exec {options_fd}>&-; exec {marker_fd}<&-; return 0; }
    staged="$(mktemp "$prefs_io/.Options.txt.XXXXXX")" || {
        rm -f -- "$saved"; exec {options_fd}>&-; exec {marker_fd}<&-; return 0; }
    if ! cat "$options_io" > "$saved" \
       || ! awk -v old="$seeded" \
              '{ l = $0; sub(/\r$/, "", l) } l == old { next } { print }' \
              "$options_io" > "$staged"; then
        rm -f -- "$saved" "$staged"
        exec {options_fd}>&-
        exec {marker_fd}<&-
        return 1
    fi

    if ! cat "$staged" > "$options_io"; then
        rm -f -- "$saved" "$staged"
        exec {options_fd}>&-
        exec {marker_fd}<&-
        return 1
    fi
    if [ -L "$options" ] || [ ! "$options" -ef "$options_io" ] \
       || [ -L "$marker" ] || [ ! "$marker" -ef "$marker_io" ] \
       || ! rm -f -- "$marker"; then
        cat "$saved" > "$options_io"
        rm -f -- "$saved" "$staged"
        exec {options_fd}>&-
        exec {marker_fd}<&-
        return 1
    fi
    rm -f -- "$saved" "$staged"
    exec {options_fd}>&-
    exec {marker_fd}<&-
    echo "   The launcher restored Live's calculated audio thread count."
}

ableton_seed_max_audio_threads_in_dir()
(
    local users_root="$1" prefs="$2" option="$3" replace_seeded="${4:-1}"
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

    # The marker preserves later user edits. While it still describes the file,
    # nothing has touched the line since the launcher wrote it, so a changed
    # explicit request may replace that one line. The implicit automatic policy
    # keeps a prior launcher choice, including a value requested by the user.
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        if [ "$replace_seeded" -eq 1 ]; then
            if [ "$option" = off ]; then
                ableton_max_audio_remove_seeded "$prefs_io" || return 1
            else
                ableton_max_audio_rewrite_seeded "$prefs_io" "$option" || return 1
            fi
        fi
        return 0
    fi
    [ "$option" != off ] || return 0
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
    local replace_seeded="${5:-1}"
    local restore_at_default="${6:-0}"
    local prefix_real users_root prefs online available live_default option=""
    local -a preference_dirs

    case "$count" in
        off|[1-9]|[1-5][0-9]|6[0-3]) ;;
        *)
            echo "ableton-live: Set the audio thread count to off or a number from one to 63. The launcher received '$count'." >&2
            return 2 ;;
    esac
    case "$replace_seeded" in
        0|1) ;;
        *)
            echo "ableton-live: The internal audio thread replacement policy is invalid." >&2
            return 2 ;;
    esac
    case "$restore_at_default" in
        0|1) ;;
        *)
            echo "ableton-live: The internal audio thread restoration policy is invalid." >&2
            return 2 ;;
    esac

    if [ "$count" = off ]; then
        option=off
    else
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
        if [ "$count" -ge "$live_default" ]; then
            [ "$restore_at_default" -eq 1 ] || return 0
            option=off
        fi

        if [ "$option" != off ]; then
            available="$(nproc 2>/dev/null)" || return 0
            case "$available" in ''|*[!0-9]*) return 0 ;; esac
            if [ "${#available}" -le 6 ]; then
                [ "$available" -ge 1 ] || return 0
                live_default=$((2 * available - 2))
                [ "$live_default" -ge 1 ] || live_default=1
                [ "$live_default" -le 31 ] || live_default=31
                if [ "$count" -ge "$live_default" ]; then
                    [ "$restore_at_default" -eq 1 ] || return 0
                    option=off
                fi
            fi
        fi
        [ -n "$option" ] || option="-MaxAudioThreads=$count"
    fi

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
        ableton_seed_max_audio_threads_in_dir "$users_root" "$prefs" "$option" \
            "$replace_seeded" || return 1
    done
)
