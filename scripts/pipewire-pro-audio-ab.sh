#!/usr/bin/env bash
# Run one matched benchmark under an exact device's current ALSA profile and
# once under its transient Pro Audio profile. No WirePlumber/PipeWire config is
# installed and profile changes use save:false.
set -uo pipefail

umask 077

readonly EX_USAGE=2
readonly EX_DATAERR=65
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_ACTIVITY=73
readonly EX_SWITCH=74

usage()
{
    cat <<'EOF'
Usage:
  scripts/pipewire-pro-audio-ab.sh --device ID --wine-prefix DIR --output DIR -- COMMAND [ARG...]
  scripts/pipewire-pro-audio-ab.sh --device ID --wine-prefix DIR --output DIR --discover

Runs COMMAND first under the exact device's current profile (A), confirms Live
and the Wine prefix are idle, then runs the same command under a transient
pro-audio profile (B). The exact original profile is restored and verified on
success, failure, HUP, INT, and TERM.

Options:
  --device ID       Exact numeric PipeWire Device global ID; aliases are refused.
  --wine-prefix DIR Existing prefix whose Wine/Live processes must be stopped.
  --output DIR      New artifact directory; existing paths are never overwritten.
  --discover        Read-only discovery. Snapshot and validate without benchmarking.
  --dry-run         Alias for --discover.
  -h, --help        Show this help.

The benchmark command must stop every process it starts. There is deliberately
no active-process override and no automatic or persistent Pro Audio selection.
Pro Audio can expose extra channels and increase IRQ or idle CPU cost; it is not
a CPU optimization by definition. See notes/PIPEWIRE-PRO-AUDIO-AB.md.
EOF
}

device_id=""
wine_prefix=""
output_dir=""
mode="run"
benchmark_command=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --device)
            [ "$#" -ge 2 ] || { printf 'Missing value for --device.\n' >&2; exit "$EX_USAGE"; }
            device_id="$2"
            shift 2
            ;;
        --wine-prefix)
            [ "$#" -ge 2 ] || { printf 'Missing value for --wine-prefix.\n' >&2; exit "$EX_USAGE"; }
            wine_prefix="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { printf 'Missing value for --output.\n' >&2; exit "$EX_USAGE"; }
            output_dir="$2"
            shift 2
            ;;
        --discover|--dry-run)
            mode="discover"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            benchmark_command=("$@")
            break
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit "$EX_USAGE"
            ;;
    esac
done

[ -n "$device_id" ] || { printf 'An exact --device ID is required.\n' >&2; exit "$EX_USAGE"; }
[[ "$device_id" =~ ^(0|[1-9][0-9]*)$ ]] \
    || { printf 'The PipeWire device ID must be an unsigned decimal integer.\n' >&2; exit "$EX_USAGE"; }
[ "${#device_id}" -lt 11 ] || { printf 'The PipeWire device ID is out of range.\n' >&2; exit "$EX_USAGE"; }
[ "$device_id" -le 4294967294 ] || { printf 'The PipeWire device ID is out of range.\n' >&2; exit "$EX_USAGE"; }
[ -n "$wine_prefix" ] || { printf 'An explicit --wine-prefix is required for the activity guard.\n' >&2; exit "$EX_USAGE"; }
[ -d "$wine_prefix" ] || { printf 'The Wine prefix is not an existing directory: %s\n' "$wine_prefix" >&2; exit "$EX_USAGE"; }
[ -n "$output_dir" ] || { printf 'A new --output directory is required.\n' >&2; exit "$EX_USAGE"; }
if [ "$mode" = run ] && [ "${#benchmark_command[@]}" -eq 0 ]; then
    printf 'A benchmark command is required after --.\n' >&2
    exit "$EX_USAGE"
fi

probe_timeout="${PIPEWIRE_PRO_AUDIO_PROBE_TIMEOUT:-8}"
verify_attempts="${PIPEWIRE_PRO_AUDIO_VERIFY_ATTEMPTS:-20}"
verify_delay="${PIPEWIRE_PRO_AUDIO_VERIFY_DELAY:-0.1}"
proc_root="${PIPEWIRE_PRO_AUDIO_PROC_ROOT:-/proc}"

[[ "$probe_timeout" =~ ^[1-9][0-9]*$ ]] && [ "$probe_timeout" -le 60 ] \
    || { printf 'PIPEWIRE_PRO_AUDIO_PROBE_TIMEOUT must be an integer from 1 to 60.\n' >&2; exit "$EX_USAGE"; }
[[ "$verify_attempts" =~ ^[1-9][0-9]*$ ]] && [ "$verify_attempts" -le 100 ] \
    || { printf 'PIPEWIRE_PRO_AUDIO_VERIFY_ATTEMPTS must be an integer from 1 to 100.\n' >&2; exit "$EX_USAGE"; }
[[ "$verify_delay" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || { printf 'PIPEWIRE_PRO_AUDIO_VERIFY_DELAY must be a non-negative number.\n' >&2; exit "$EX_USAGE"; }
[ -d "$proc_root" ] || { printf 'Process information root is unavailable: %s\n' "$proc_root" >&2; exit "$EX_UNAVAILABLE"; }

for dependency in cmp date jq pw-cli pw-dump pw-metadata readlink realpath sed sha256sum sort timeout tr wpctl; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'Required command is unavailable: %s\n' "$dependency" >&2
        exit "$EX_UNAVAILABLE"
    }
done

wine_prefix="$(realpath -e -- "$wine_prefix")" || exit "$EX_USAGE"
if ! mkdir -m 700 -- "$output_dir"; then
    printf 'The artifact path must not already exist: %s\n' "$output_dir" >&2
    exit "$EX_USAGE"
fi
output_dir="$(realpath -e -- "$output_dir")" || exit "$EX_SOFTWARE"
mkdir -- "$output_dir/events"

if [ "${#benchmark_command[@]}" -gt 0 ]; then
    {
        printf 'Command (shell escaped; executed directly, without eval):\n'
        printf '%q ' "${benchmark_command[@]}"
        printf '\n'
    } > "$output_dir/command.txt"
else
    printf 'No command: read-only discovery.\n' > "$output_dir/command.txt"
fi

result="initializing"
message=""
switch_state="not-attempted"
restoration_state="not-needed"
baseline_state="not-run"
pro_state="not-run"
baseline_exit=""
pro_exit=""
baseline_elapsed_ms=""
pro_elapsed_ms=""
preflight_activity="unknown"
post_baseline_activity="not-checked"
post_pro_activity="not-checked"
post_restore_activity="not-checked"
defaults_restored="not-checked"
profile_state_restored="not-checked"
nodes_restored="not-checked"
routes_restored="not-checked"
settings_restored="not-checked"
identity_restored="not-checked"
original_profile_index=""
original_profile_name=""
pro_profile_index=""
pro_profile_available=""
device_name=""
profile_mutation_started=0
preflight_complete=0
benchmark_pid=""
benchmark_phase=""
benchmark_start_ns=""
lock_dir=""

write_status()
{
    local exit_code="$1" temporary="$output_dir/.status.json.tmp"
    jq -n \
        --arg result "$result" \
        --arg message "$message" \
        --arg mode "$mode" \
        --arg device_id "$device_id" \
        --arg device_name "$device_name" \
        --arg wine_prefix "$wine_prefix" \
        --arg original_index "$original_profile_index" \
        --arg original_name "$original_profile_name" \
        --arg pro_index "$pro_profile_index" \
        --arg pro_available "$pro_profile_available" \
        --arg switch "$switch_state" \
        --arg restoration "$restoration_state" \
        --arg baseline_state "$baseline_state" \
        --arg baseline_exit "$baseline_exit" \
        --arg baseline_elapsed "$baseline_elapsed_ms" \
        --arg pro_state "$pro_state" \
        --arg pro_exit "$pro_exit" \
        --arg pro_elapsed "$pro_elapsed_ms" \
        --arg preflight_activity "$preflight_activity" \
        --arg post_baseline_activity "$post_baseline_activity" \
        --arg post_pro_activity "$post_pro_activity" \
        --arg post_restore_activity "$post_restore_activity" \
        --arg defaults_restored "$defaults_restored" \
        --arg profile_state_restored "$profile_state_restored" \
        --arg nodes_restored "$nodes_restored" \
        --arg routes_restored "$routes_restored" \
        --arg settings_restored "$settings_restored" \
        --arg identity_restored "$identity_restored" \
        --arg exit_code "$exit_code" \
        --arg artifacts "$output_dir" '
        def number_or_null: if . == "" then null else tonumber end;
        {
          result: $result,
          message: $message,
          mode: $mode,
          exit_code: ($exit_code | tonumber),
          device: {
            id: ($device_id | tonumber), name: $device_name,
            original_profile: {index: ($original_index | number_or_null), name: $original_name},
            pro_audio_profile: {index: ($pro_index | number_or_null), available: $pro_available}
          },
          wine_prefix: $wine_prefix,
          switch: $switch,
          restoration: $restoration,
          activity: {
            preflight: $preflight_activity,
            after_baseline: $post_baseline_activity,
            after_pro_audio: $post_pro_activity,
            after_restoration: $post_restore_activity
          },
          legs: {
            A_original: {
              state: $baseline_state,
              exit_code: ($baseline_exit | number_or_null),
              elapsed_ms: ($baseline_elapsed | number_or_null),
              artifacts: ($artifacts + "/A-original")
            },
            B_pro_audio: {
              state: $pro_state,
              exit_code: ($pro_exit | number_or_null),
              elapsed_ms: ($pro_elapsed | number_or_null),
              artifacts: ($artifacts + "/B-pro-audio")
            }
          },
          restored_evidence: {
            defaults: $defaults_restored,
            wireplumber_profile_state: $profile_state_restored,
            associated_nodes: $nodes_restored,
            routes: $routes_restored,
            settings: $settings_restored,
            device_identity: $identity_restored
          },
          artifacts: $artifacts
        }' > "$temporary" && mv -- "$temporary" "$output_dir/status.json"
}

fail()
{
    local code="$1"
    result="$2"
    message="$3"
    printf '!! %s\n' "$message" >&2
    exit "$code"
}

probe()
{
    local destination="$1" rc
    shift
    timeout --foreground "$probe_timeout" "$@" \
        > "$destination" 2> "$destination.stderr"
    rc=$?
    printf '%s\n' "$rc" > "$destination.exit-code"
    return "$rc"
}

canonicalize_metadata()
{
    local source="$1" destination="$2"
    sed -e '/^Found .* metadata [0-9][0-9]*$/d' -e 's/^update: //' "$source" \
        | LC_ALL=C sort > "$destination"
}

capture_profile_state_hash()
{
    local destination="$1"
    local state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
    local state_file="$state_home/wireplumber/default-profile"
    if [ -r "$state_file" ]; then
        sha256sum -- "$state_file" | sed "s|  $state_file$|  default-profile|" > "$destination"
    elif [ -e "$state_file" ]; then
        printf 'unreadable  default-profile\n' > "$destination"
    else
        printf 'missing  default-profile\n' > "$destination"
    fi
}

filter_exact_device()
{
    local graph="$1" destination="$2"
    jq -e --argjson id "$device_id" '
      [.[] | select(.id == $id)] as $objects
      | if ($objects | length) != 1 then empty
        elif $objects[0].type != "PipeWire:Interface:Device" then empty
        else $objects[0] end
    ' "$graph" > "$destination"
}

write_device_derived_evidence()
{
    local stage="$1"
    jq -S '{
      id, type,
      identity: {
        device_name: .info.props["device.name"],
        device_api: .info.props["device.api"],
        device_bus_id: .info.props["device.bus-id"],
        device_bus_path: .info.props["device.bus-path"],
        object_path: .info.props["object.path"],
        object_serial: .info.props["object.serial"]
      }
    }' "$stage/device.json" > "$stage/device-identity.json"
    jq -S '.info.params.Route // [] | sort_by(.index // -1)' \
        "$stage/device.json" > "$stage/routes.json"
    jq -S --arg id "$device_id" '[.[] | select(
      .type == "PipeWire:Interface:Node"
      and ((.info.props["device.id"] // "") | tostring) == $id
    )]' "$stage/graph.json" > "$stage/associated-nodes.json"
    jq -S '[.[] | {
      media_class: .info.props["media.class"],
      node_name: .info.props["node.name"],
      node_description: .info.props["node.description"],
      profile_name: .info.props["device.profile.name"],
      alsa_path: .info.props["api.alsa.path"],
      channels: .info.props["audio.channels"],
      position: .info.props["audio.position"]
    }] | sort_by(.media_class, .node_name, .alsa_path)' \
        "$stage/associated-nodes.json" > "$stage/associated-nodes.semantic.json"
}

snapshot()
{
    local stage="$1" failed=0
    mkdir -- "$stage" || return 1

    probe "$stage/graph.json" pw-dump || failed=1
    if [ "$failed" -eq 0 ]; then
        filter_exact_device "$stage/graph.json" "$stage/device.json" || failed=1
    fi
    if [ "$failed" -eq 0 ]; then
        write_device_derived_evidence "$stage" || failed=1
    fi

    probe "$stage/wpctl-status.txt" wpctl status --name || failed=1
    probe "$stage/device-inspect.txt" wpctl inspect "$device_id" || failed=1
    probe "$stage/default-nodes.txt" pw-metadata -n default || failed=1
    probe "$stage/default-profiles.txt" pw-metadata -n default-profile || failed=1
    probe "$stage/settings.txt" pw-metadata -n settings || failed=1
    canonicalize_metadata "$stage/default-nodes.txt" "$stage/default-nodes.canonical.txt"
    canonicalize_metadata "$stage/default-profiles.txt" "$stage/default-profiles.canonical.txt"
    canonicalize_metadata "$stage/settings.txt" "$stage/settings.canonical.txt"
    capture_profile_state_hash "$stage/wireplumber-default-profile.sha256"

    return "$failed"
}

profile_index()
{
    jq -er '.info.params.Profile
      | select(type == "array" and length == 1)
      | .[0].index
      | select(type == "number" and floor == . and . >= 0 and . <= 2147483647)' "$1"
}

profile_name()
{
    jq -er '.info.params.Profile
      | select(type == "array" and length == 1)
      | .[0].name | select(type == "string" and length > 0)' "$1"
}

validate_alsa_device()
{
    jq -e '
      .type == "PipeWire:Interface:Device"
      and (.info.props["device.api"] == "alsa")
      and (.info.props["device.name"] | type == "string" and length > 0)
    ' "$1" >/dev/null
}

capture_exact_device()
{
    local destination="$1" raw="$1.raw.json"
    probe "$raw" pw-dump "$device_id" || return 1
    filter_exact_device "$raw" "$destination"
}

identity_matches_original()
{
    local device="$1" normalized="$2"
    jq -S '{
      id, type,
      identity: {
        device_name: .info.props["device.name"],
        device_api: .info.props["device.api"],
        device_bus_id: .info.props["device.bus-id"],
        device_bus_path: .info.props["device.bus-path"],
        object_path: .info.props["object.path"],
        object_serial: .info.props["object.serial"]
      }
    }' "$device" > "$normalized"
    cmp -s "$output_dir/before/device-identity.json" "$normalized"
}

verify_profile()
{
    local expected_index="$1" expected_name="$2" label="$3"
    local attempt device current_index current_name
    for ((attempt = 1; attempt <= verify_attempts; attempt++)); do
        device="$output_dir/events/${label}-attempt-${attempt}.device.json"
        if capture_exact_device "$device" \
            && identity_matches_original "$device" "$device.identity.json"; then
            current_index="$(profile_index "$device" 2>/dev/null || true)"
            current_name="$(profile_name "$device" 2>/dev/null || true)"
            if [ "$current_index" = "$expected_index" ] && [ "$current_name" = "$expected_name" ]; then
                printf '%s\n' "$attempt" > "$output_dir/events/${label}.verified-attempt"
                return 0
            fi
        fi
        [ "$attempt" -eq "$verify_attempts" ] || sleep "$verify_delay"
    done
    return 1
}

set_profile_transient()
{
    local index="$1" label="$2"
    # wpctl set-profile sends save=true; this direct Profile pod must stay false.
    probe "$output_dir/events/${label}.pw-cli.stdout" \
        pw-cli set-param "$device_id" Profile "{\"index\":$index,\"save\":false}"
}

scan_activity()
{
    local destination="$1" proc_dir pid cmdline item process_prefix process_prefix_real process_cwd reason
    local default_prefix=""
    local count=0 wine_like=0
    if [ -n "${HOME:-}" ] && [ -d "$HOME/.wine" ]; then
        default_prefix="$(realpath -e -- "$HOME/.wine" 2>/dev/null || true)"
    fi
    printf 'pid\treason\tcommand\n' > "$destination"
    shopt -s nullglob nocasematch
    for proc_dir in "$proc_root"/[0-9]*; do
        pid="${proc_dir##*/}"
        [ "$pid" = "$$" ] && continue
        [ -r "$proc_dir/cmdline" ] || continue
        cmdline="$(tr '\000\t\r\n' '    ' < "$proc_dir/cmdline" 2>/dev/null)"
        [ -n "$cmdline" ] || continue
        reason=""
        if [[ "$cmdline" =~ Ableton[[:space:]]+Live.*\.exe ]]; then
            reason="Live"
        fi

        process_prefix=""
        if [ -r "$proc_dir/environ" ]; then
            while IFS= read -r -d '' item; do
                case "$item" in
                    WINEPREFIX=*) process_prefix="${item#WINEPREFIX=}" ;;
                esac
            done < "$proc_dir/environ"
        fi
        wine_like=0
        if [[ "$cmdline" =~ (^|[[:space:]/])(wine|wine64|wine-preloader|wineserver)([[:space:]/]|$) \
            || "$cmdline" =~ \.exe([[:space:]]|$) ]]; then
            wine_like=1
        fi
        if [ -n "$process_prefix" ] && [ "$wine_like" -eq 1 ]; then
            if [[ "$process_prefix" != /* ]]; then
                process_cwd="$(readlink -e -- "$proc_dir/cwd" 2>/dev/null || true)"
                if [ -n "$process_cwd" ]; then process_prefix="$process_cwd/$process_prefix"; fi
            fi
            process_prefix_real="$(realpath -m -- "$process_prefix" 2>/dev/null || true)"
            if [ "$process_prefix_real" = "$wine_prefix" ]; then
                if [ -n "$reason" ]; then reason="$reason+prefix"; else reason="prefix"; fi
            fi
        elif [ "$wine_like" -eq 1 ] && [ -n "$default_prefix" ] \
            && [ "$default_prefix" = "$wine_prefix" ]; then
            if [ -n "$reason" ]; then reason="$reason+prefix"; else reason="prefix"; fi
        fi
        if [ -n "$reason" ]; then
            printf '%s\t%s\t%s\n' "$pid" "$reason" "$cmdline" >> "$destination"
            count=$((count + 1))
        fi
    done
    shopt -u nullglob nocasematch
    [ "$count" -eq 0 ]
}

now_ns()
{
    local value
    value="$(date +%s%N)"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    else
        printf '%s000000000\n' "$(date +%s)"
    fi
}

write_timing()
{
    local stage="$1" start="$2" finish="$3" exit_code="$4" signal_name="${5:-}"
    local elapsed_ms=$(( (finish - start) / 1000000 ))
    jq -n --arg start "$start" --arg finish "$finish" --arg elapsed "$elapsed_ms" \
        --arg exit "$exit_code" --arg signal "$signal_name" '{
          start_realtime_ns: ($start | tonumber),
          finish_realtime_ns: ($finish | tonumber),
          elapsed_ms: ($elapsed | tonumber),
          exit_code: ($exit | tonumber),
          signal: (if $signal == "" then null else $signal end)
        }' > "$stage/timing.json"
    printf '%s\n' "$exit_code" > "$stage/exit-code"
    if [ "$stage" = "$output_dir/A-original" ]; then
        baseline_elapsed_ms="$elapsed_ms"
    else
        pro_elapsed_ms="$elapsed_ms"
    fi
}

run_benchmark_leg()
{
    local phase="$1" stage="$2" finish rc
    [ -d "$stage" ] || mkdir -- "$stage" || return "$EX_SOFTWARE"
    benchmark_phase="$phase"
    benchmark_start_ns="$(now_ns)"
    ABLETON_PRO_AUDIO_LEG="$phase" \
    ABLETON_PRO_AUDIO_LEG_DIR="$stage" \
        "${benchmark_command[@]}" > "$stage/benchmark.stdout" 2> "$stage/benchmark.stderr" &
    benchmark_pid=$!
    wait "$benchmark_pid"
    rc=$?
    benchmark_pid=""
    finish="$(now_ns)"
    write_timing "$stage" "$benchmark_start_ns" "$finish" "$rc"
    benchmark_phase=""
    benchmark_start_ns=""
    return "$rc"
}

# shellcheck disable=SC2329 # Called from the EXIT-trap finalizer.
compare_restored_state()
{
    local before="$output_dir/before" after="$output_dir/after-restoration" failed=0
    if [ "$(profile_index "$after/device.json" 2>/dev/null || true)" != "$original_profile_index" ] \
        || [ "$(profile_name "$after/device.json" 2>/dev/null || true)" != "$original_profile_name" ]; then
        if [ "$restoration_state" = verified ]; then restoration_state="changed-after-verify"; fi
        failed=1
    fi
    if cmp -s "$before/default-nodes.canonical.txt" "$after/default-nodes.canonical.txt"; then
        defaults_restored="verified"
    else
        defaults_restored="changed"
        failed=1
    fi
    if cmp -s "$before/default-profiles.canonical.txt" "$after/default-profiles.canonical.txt" \
        && cmp -s "$before/wireplumber-default-profile.sha256" "$after/wireplumber-default-profile.sha256"; then
        profile_state_restored="verified"
    else
        profile_state_restored="changed"
        failed=1
    fi
    if cmp -s "$before/associated-nodes.semantic.json" "$after/associated-nodes.semantic.json"; then
        nodes_restored="verified"
    else
        nodes_restored="changed"
        failed=1
    fi
    if cmp -s "$before/routes.json" "$after/routes.json"; then
        routes_restored="verified"
    else
        routes_restored="changed"
        failed=1
    fi
    if cmp -s "$before/settings.canonical.txt" "$after/settings.canonical.txt"; then
        settings_restored="verified"
    else
        settings_restored="changed"
        failed=1
    fi
    if cmp -s "$before/device-identity.json" "$after/device-identity.json"; then
        identity_restored="verified"
    else
        identity_restored="changed"
        failed=1
    fi
    return "$failed"
}

stage_matches_before()
{
    local stage="$1" before="$output_dir/before"
    cmp -s "$before/default-nodes.canonical.txt" "$stage/default-nodes.canonical.txt" \
        && cmp -s "$before/default-profiles.canonical.txt" "$stage/default-profiles.canonical.txt" \
        && cmp -s "$before/wireplumber-default-profile.sha256" "$stage/wireplumber-default-profile.sha256" \
        && cmp -s "$before/associated-nodes.semantic.json" "$stage/associated-nodes.semantic.json" \
        && cmp -s "$before/routes.json" "$stage/routes.json" \
        && cmp -s "$before/settings.canonical.txt" "$stage/settings.canonical.txt" \
        && cmp -s "$before/device-identity.json" "$stage/device-identity.json"
}

# shellcheck disable=SC2329 # Called by signal traps.
handle_signal()
{
    local signal_name="$1" signal_code="$2" finish
    trap - HUP INT TERM
    result="signal-${signal_name,,}"
    message="Received $signal_name; restoring the exact original profile."
    if [ -n "$benchmark_pid" ]; then
        kill -s "$signal_name" "$benchmark_pid" 2>/dev/null || true
        wait "$benchmark_pid" 2>/dev/null || true
        benchmark_pid=""
        finish="$(now_ns)"
        if [ "$benchmark_phase" = baseline ]; then
            baseline_state="signalled"
            baseline_exit="$signal_code"
            write_timing "$output_dir/A-original" "$benchmark_start_ns" "$finish" "$signal_code" "$signal_name"
        elif [ "$benchmark_phase" = pro-audio ]; then
            pro_state="signalled"
            pro_exit="$signal_code"
            write_timing "$output_dir/B-pro-audio" "$benchmark_start_ns" "$finish" "$signal_code" "$signal_name"
        fi
    fi
    exit "$signal_code"
}

# shellcheck disable=SC2329 # Called by the EXIT trap.
finish()
{
    local requested_exit="$?" final_exit="$?" snapshot_failed=0 restore_failed=0 drift_failed=0
    trap - EXIT
    trap '' HUP INT TERM
    final_exit="$requested_exit"

    if [ "$profile_mutation_started" -eq 1 ]; then
        if set_profile_transient "$original_profile_index" restore-original \
            && verify_profile "$original_profile_index" "$original_profile_name" restore-original; then
            restoration_state="verified"
        else
            restoration_state="failed"
            restore_failed=1
        fi
    fi

    if [ "$preflight_complete" -eq 1 ]; then
        snapshot "$output_dir/after-restoration" || snapshot_failed=1
        if [ "$snapshot_failed" -eq 0 ]; then
            compare_restored_state || drift_failed=1
        fi
        if scan_activity "$output_dir/after-restoration/activity.tsv"; then
            post_restore_activity="clear"
        else
            post_restore_activity="detected"
        fi
    fi

    if [ "$restore_failed" -eq 1 ]; then
        result="restoration-failed"
        message="Failed to restore and verify the original profile; use recovery-command.txt after checking the device ID."
        final_exit="$EX_SOFTWARE"
    elif [ "$snapshot_failed" -eq 1 ] \
        && { [ "$requested_exit" -eq 0 ] || [ "$profile_mutation_started" -eq 1 ]; }; then
        result="restoration-evidence-failed"
        message="The original profile was restored, but the final evidence snapshot failed."
        final_exit="$EX_SOFTWARE"
    elif [ "$drift_failed" -eq 1 ] \
        && { [ "$requested_exit" -eq 0 ] || [ "$profile_mutation_started" -eq 1 ]; }; then
        result="restored-state-drift"
        message="The profile was restored, but defaults, state, routes, nodes, settings, or identity drifted."
        final_exit="$EX_SOFTWARE"
    fi

    write_status "$final_exit" || true
    if [ -n "$lock_dir" ]; then rmdir -- "$lock_dir" 2>/dev/null || true; fi
    printf 'result=%s exit=%s restoration=%s artifacts=%s\n' \
        "$result" "$final_exit" "$restoration_state" "$output_dir"
    exit "$final_exit"
}

runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
[ -d "$runtime_dir" ] || fail "$EX_UNAVAILABLE" runtime-unavailable "Runtime directory is unavailable: $runtime_dir"
lock_dir="$runtime_dir/ableton-pw-pro-audio-${UID}-${device_id}.lock"
if ! mkdir -m 700 -- "$lock_dir"; then
    result="concurrent-run"
    message="Another Pro Audio A/B owns device $device_id."
    write_status "$EX_ACTIVITY" || true
    printf '!! %s\n' "$message" >&2
    exit "$EX_ACTIVITY"
fi

trap finish EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

if ! snapshot "$output_dir/before"; then
    fail "$EX_DATAERR" snapshot-failed 'Could not capture the complete preflight PipeWire snapshot.'
fi
validate_alsa_device "$output_dir/before/device.json" \
    || fail "$EX_DATAERR" invalid-device 'The exact ID is not a single named ALSA PipeWire Device.'

device_name="$(jq -r '.info.props["device.name"]' "$output_dir/before/device.json")"
original_profile_index="$(profile_index "$output_dir/before/device.json" 2>/dev/null || true)"
original_profile_name="$(profile_name "$output_dir/before/device.json" 2>/dev/null || true)"
[ -n "$original_profile_index" ] && [ -n "$original_profile_name" ] \
    || fail "$EX_DATAERR" invalid-current-profile 'The device does not expose exactly one valid current profile.'
[ "$original_profile_name" != off ] \
    || fail "$EX_DATAERR" inactive-current-profile 'The current profile is off; it cannot be a valid baseline.'

pro_count="$(jq '[.info.params.EnumProfile[]? | select(.name == "pro-audio")] | length' \
    "$output_dir/before/device.json")"
case "$pro_count" in
    0) fail "$EX_DATAERR" pro-audio-missing 'The exact device does not expose a pro-audio profile.' ;;
    1) ;;
    *) fail "$EX_DATAERR" pro-audio-ambiguous 'The exact device exposes more than one pro-audio profile.' ;;
esac
pro_profile_index="$(jq -er '.info.params.EnumProfile[] | select(.name == "pro-audio")
    | .index
    | select(type == "number" and floor == . and . >= 0 and . <= 2147483647)' \
    "$output_dir/before/device.json" 2>/dev/null || true)"
pro_profile_available="$(jq -r '.info.params.EnumProfile[] | select(.name == "pro-audio")
    | (.available // "unknown")' "$output_dir/before/device.json")"
[ -n "$pro_profile_index" ] \
    || fail "$EX_DATAERR" pro-audio-invalid 'The pro-audio profile has no valid numeric index.'
[ "$(jq --arg name "$original_profile_name" --argjson index "$original_profile_index" \
    '[.info.params.EnumProfile[]? | select(.name == $name and .index == $index)] | length' \
    "$output_dir/before/device.json")" -eq 1 ] \
    || fail "$EX_DATAERR" invalid-current-profile 'The current profile is not one exact enumerated profile.'
[ "$pro_profile_available" != no ] \
    || fail "$EX_DATAERR" pro-audio-unavailable 'The pro-audio profile is currently unavailable.'
[ "$original_profile_index" != "$pro_profile_index" ] \
    || fail "$EX_DATAERR" already-pro-audio 'The device already uses Pro Audio; there is no original-profile A/B.'

preflight_complete=1
if scan_activity "$output_dir/before/activity.tsv"; then
    preflight_activity="clear"
else
    preflight_activity="detected"
    fail "$EX_ACTIVITY" active-processes 'Live or Wine activity for the supplied prefix is already running.'
fi

if [ "$mode" = discover ]; then
    result="discovery-ok"
    message="The exact device and one available Pro Audio profile were discovered; nothing was changed or run."
    exit 0
fi

printf 'pw-cli set-param %q Profile %q\n' "$device_id" \
    "{\"index\":$original_profile_index,\"save\":false}" > "$output_dir/recovery-command.txt"
printf '# PipeWire global IDs are session-scoped. Verify that ID %s is still device %s before recovery.\n' \
    "$device_id" "$device_name" >> "$output_dir/recovery-command.txt"

if run_benchmark_leg baseline "$output_dir/A-original"; then
    baseline_exit=0
    baseline_state="passed"
else
    baseline_exit=$?
    baseline_state="failed"
    result="baseline-benchmark-failed"
    message="The original-profile benchmark failed; Pro Audio was not selected."
    exit "$baseline_exit"
fi

if scan_activity "$output_dir/A-original/activity-after.tsv"; then
    post_baseline_activity="clear"
else
    post_baseline_activity="detected"
    fail "$EX_ACTIVITY" baseline-left-activity 'The baseline command left Live or prefix activity running; Pro Audio was not selected.'
fi
if ! snapshot "$output_dir/A-original/after-state"; then
    fail "$EX_DATAERR" baseline-snapshot-failed 'Could not snapshot the state after the baseline command.'
fi
if ! identity_matches_original "$output_dir/A-original/after-state/device.json" \
        "$output_dir/events/pre-switch.device-identity.json" \
    || [ "$(profile_index "$output_dir/A-original/after-state/device.json" 2>/dev/null || true)" != "$original_profile_index" ] \
    || [ "$(profile_name "$output_dir/A-original/after-state/device.json" 2>/dev/null || true)" != "$original_profile_name" ] \
    || ! stage_matches_before "$output_dir/A-original/after-state"; then
    fail "$EX_DATAERR" baseline-state-changed 'The baseline command changed the target, profile, routes, defaults, nodes, settings, or saved state.'
fi

profile_mutation_started=1
if ! set_profile_transient "$pro_profile_index" switch-pro-audio; then
    switch_state="failed"
    fail "$EX_SWITCH" profile-switch-failed 'The transient Pro Audio profile switch command failed.'
fi
if ! verify_profile "$pro_profile_index" pro-audio switch-pro-audio; then
    switch_state="unverified"
    fail "$EX_SWITCH" profile-switch-unverified 'The exact target did not enter its discovered Pro Audio profile.'
fi
switch_state="verified"

mkdir -- "$output_dir/B-pro-audio" \
    || fail "$EX_SOFTWARE" artifact-failed 'Could not create the Pro Audio leg artifact directory.'
if ! snapshot "$output_dir/B-pro-audio/before-state"; then
    fail "$EX_SWITCH" pro-audio-snapshot-failed 'Could not capture the Pro Audio node/device evidence before the B leg.'
fi
if [ "$(profile_index "$output_dir/B-pro-audio/before-state/device.json" 2>/dev/null || true)" != "$pro_profile_index" ] \
    || [ "$(profile_name "$output_dir/B-pro-audio/before-state/device.json" 2>/dev/null || true)" != pro-audio ]; then
    fail "$EX_SWITCH" pro-audio-state-changed 'The target left Pro Audio before the B command started.'
fi

if run_benchmark_leg pro-audio "$output_dir/B-pro-audio"; then
    pro_exit=0
    pro_state="passed"
else
    pro_exit=$?
    pro_state="failed"
fi

if scan_activity "$output_dir/B-pro-audio/activity-after.tsv"; then
    post_pro_activity="clear"
else
    post_pro_activity="detected"
fi

if [ "$pro_state" = failed ]; then
    result="pro-audio-benchmark-failed"
    message="The Pro Audio benchmark failed; the exact original profile will be restored."
    exit "$pro_exit"
fi
if [ "$post_pro_activity" = detected ]; then
    fail "$EX_ACTIVITY" pro-audio-left-activity 'The Pro Audio command left Live or prefix activity running; restoring despite this contract violation.'
fi

result="ab-complete"
message="Both matched legs passed; the exact original profile was restored and verified."
exit 0
