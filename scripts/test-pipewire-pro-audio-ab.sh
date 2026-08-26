#!/usr/bin/env bash
set -euo pipefail

fake_dispatch()
{
    local command="${0##*/}" current_index current_name profiles index new_name leg device_name
    local node_state="suspended" link_state="paused"
    IFS=' ' read -r current_index current_name < "$FAKE_PW_DIR/current-profile"
    case "$command" in
        pw-dump)
            device_name="alsa_card.test_interface"
            if [ -e "$FAKE_PW_DIR/device-name-with-newline" ]; then
                device_name=$'alsa_card.test_interface\nprintf "injected"'
            fi
            if [ -e "$FAKE_PW_DIR/target-node-running" ]; then node_state="running"; fi
            if [ -e "$FAKE_PW_DIR/target-link-active" ]; then link_state="active"; fi
            profiles='[
              {"index":0,"name":"off","description":"Off","available":"yes"},
              {"index":1,"name":"analog-stereo-duplex","description":"Analog Stereo Duplex","available":"yes"},
              {"index":9,"name":"pro-audio","description":"Pro Audio","available":"yes"}
            ]'
            if [ -e "$FAKE_PW_DIR/profiles-missing" ]; then
                profiles='[
                  {"index":0,"name":"off","description":"Off","available":"yes"},
                  {"index":1,"name":"analog-stereo-duplex","description":"Analog Stereo Duplex","available":"yes"}
                ]'
            elif [ -e "$FAKE_PW_DIR/profiles-ambiguous" ]; then
                profiles='[
                  {"index":0,"name":"off","description":"Off","available":"yes"},
                  {"index":1,"name":"analog-stereo-duplex","description":"Analog Stereo Duplex","available":"yes"},
                  {"index":9,"name":"pro-audio","description":"Pro Audio","available":"yes"},
                  {"index":10,"name":"pro-audio","description":"Duplicate Pro Audio","available":"yes"}
                ]'
            elif [ -e "$FAKE_PW_DIR/profiles-unavailable" ]; then
                profiles='[
                  {"index":0,"name":"off","description":"Off","available":"yes"},
                  {"index":1,"name":"analog-stereo-duplex","description":"Analog Stereo Duplex","available":"yes"},
                  {"index":9,"name":"pro-audio","description":"Pro Audio","available":"no"}
                ]'
            fi
            jq -n --argjson id "$FAKE_DEVICE_ID" --argjson index "$current_index" \
                --arg name "$current_name" --arg device_name "$device_name" \
                --arg node_state "$node_state" --arg link_state "$link_state" \
                --argjson profiles "$profiles" '[
              {
                id: $id,
                type: "PipeWire:Interface:Device",
                info: {
                  props: {
                    "device.api": "alsa",
                    "device.name": $device_name,
                    "device.bus-id": "usb-test-1",
                    "device.bus-path": "pci-test-usb-test",
                    "object.path": "alsa:acp:test",
                    "object.serial": 4242,
                    "device.profile.name": $name
                  },
                  params: {
                    EnumProfile: $profiles,
                    Profile: [{index: $index, name: $name, save: false}],
                    Route: [{index: 3, name: "test-output", available: "yes"}]
                  }
                }
              },
              {
                id: 100,
                type: "PipeWire:Interface:Node",
                info: {state: $node_state, props: {
                  "device.id": ($id | tostring),
                  "media.class": "Audio/Sink",
                  "node.name": (if $name == "pro-audio" then "alsa_output.test.pro" else "alsa_output.test.stereo" end),
                  "node.description": "Test Output",
                  "device.profile.name": $name,
                  "api.alsa.path": "hw:Test,0",
                  "audio.channels": (if $name == "pro-audio" then 8 else 2 end),
                  "audio.position": (if $name == "pro-audio" then "AUX0,AUX1,AUX2,AUX3,AUX4,AUX5,AUX6,AUX7" else "FL,FR" end)
                }}
              },
              {
                id: 101,
                type: "PipeWire:Interface:Node",
                info: {state: "suspended", props: {
                  "device.id": ($id | tostring),
                  "media.class": "Audio/Source",
                  "node.name": (if $name == "pro-audio" then "alsa_input.test.pro" else "alsa_input.test.stereo" end),
                  "node.description": "Test Input",
                  "device.profile.name": $name,
                  "api.alsa.path": "hw:Test,0",
                  "audio.channels": (if $name == "pro-audio" then 8 else 2 end),
                  "audio.position": (if $name == "pro-audio" then "AUX0,AUX1,AUX2,AUX3,AUX4,AUX5,AUX6,AUX7" else "FL,FR" end)
                }}
              },
              {
                id: 200,
                type: "PipeWire:Interface:Node",
                info: {state: "running", props: {
                  "media.class": "Stream/Output/Audio",
                  "node.name": "Firefox",
                  "application.name": "Firefox"
                }}
              },
              {
                id: 102,
                type: "PipeWire:Interface:Link",
                info: {
                  state: $link_state,
                  "input-node-id": 100,
                  "output-node-id": 200,
                  props: {
                    "link.input.node": 100,
                    "link.output.node": 200,
                    "link.passive": true
                  }
                }
              }
            ]'
            ;;
        pw-cli)
            printf '%s\n' "$*" >> "$FAKE_PW_DIR/pw-cli.log"
            [ "${1:-}" = set-param ] && [ "${2:-}" = "$FAKE_DEVICE_ID" ] \
                && [ "${3:-}" = Profile ] || exit 91
            case "${4:-}" in
                *'"save":false'*) ;;
                *) exit 92 ;;
            esac
            index="$(printf '%s\n' "$4" | sed -n 's/.*"index":\([0-9][0-9]*\).*/\1/p')"
            [ -n "$index" ] || exit 93
            if [ "$index" = 9 ] && [ -e "$FAKE_PW_DIR/switch-fails-before-mutation" ]; then exit 17; fi
            if [ "$index" = 1 ] && [ -e "$FAKE_PW_DIR/restore-fails" ]; then exit 18; fi
            case "$index" in
                1) new_name="analog-stereo-duplex" ;;
                9) new_name="pro-audio" ;;
                *) exit 94 ;;
            esac
            printf '%s %s\n' "$index" "$new_name" > "$FAKE_PW_DIR/current-profile"
            if [ "$index" = 1 ] && [ -e "$FAKE_PW_DIR/activity-after-restore" ]; then
                mkdir -p -- "$PIPEWIRE_PRO_AUDIO_PROC_ROOT/704"
                printf '%s\0' '/opt/wine/bin/wine64-preloader' \
                    > "$PIPEWIRE_PRO_AUDIO_PROC_ROOT/704/cmdline"
                printf '%s\0' "WINEPREFIX=$FAKE_TARGET_PREFIX" \
                    > "$PIPEWIRE_PRO_AUDIO_PROC_ROOT/704/environ"
            fi
            if [ "$index" = 9 ] && [ -e "$FAKE_PW_DIR/switch-fails-after-mutation" ]; then exit 17; fi
            printf 'set transient profile %s\n' "$index"
            ;;
        wpctl)
            case "${1:-}" in
                status) printf 'Audio\n  Devices:\n   %s. Test Interface [%s]\n' "$FAKE_DEVICE_ID" "$current_name" ;;
                inspect) printf 'id %s, device.name = alsa_card.test_interface, device.profile.name = %s\n' \
                    "$FAKE_DEVICE_ID" "$current_name" ;;
                set-profile) exit 95 ;;
                *) exit 96 ;;
            esac
            ;;
        pw-metadata)
            [ "${1:-}" = -n ] || exit 97
            case "${2:-}" in
                default)
                    printf 'Found "default" metadata 50\n'
                    if [ -e "$FAKE_PW_DIR/metadata-drift" ]; then
                        printf "update: id:0 key:'default.configured.audio.sink' value:'{\"name\":\"alsa_output.other\"}' type:'Spa:String:JSON'\n"
                    else
                        printf "update: id:0 key:'default.configured.audio.sink' value:'{\"name\":\"alsa_output.test.stereo\"}' type:'Spa:String:JSON'\n"
                    fi
                    ;;
                default-profile)
                    printf 'Found "default-profile" metadata 51\n'
                    printf "update: id:0 key:'alsa_card.test_interface' value:'analog-stereo-duplex' type:'Spa:String'\n"
                    ;;
                settings)
                    printf 'Found "settings" metadata 52\n'
                    printf "update: id:0 key:'clock.quantum' value:'64' type:'Spa:Int'\n"
                    ;;
                *) exit 98 ;;
            esac
            ;;
        benchmark)
            leg="${ABLETON_PRO_AUDIO_LEG:-missing}"
            printf '%s\n' "$leg" >> "$FAKE_PW_DIR/benchmark.log"
            printf '%s\t%s\n' "$leg" "${ABLETON_PRO_AUDIO_LEG_DIR:-missing}" \
                >> "$FAKE_PW_DIR/benchmark-dirs.log"
            printf 'benchmark %s\n' "$leg"
            if [ "$leg" = baseline ] && [ -e "$FAKE_PW_DIR/benchmark-drifts-state" ]; then
                : > "$FAKE_PW_DIR/metadata-drift"
            fi
            if [ "$leg" = pro-audio ] && [ -e "$FAKE_PW_DIR/benchmark-leaves-active-link" ]; then
                : > "$FAKE_PW_DIR/target-link-active"
            fi
            if [ -r "$FAKE_PW_DIR/benchmark-sleep-leg" ] \
                && [ "$leg" = "$(< "$FAKE_PW_DIR/benchmark-sleep-leg")" ]; then
                exec sleep 30
            fi
            if [ -r "$FAKE_PW_DIR/benchmark-ignore-signal-leg" ] \
                && [ "$leg" = "$(< "$FAKE_PW_DIR/benchmark-ignore-signal-leg")" ]; then
                printf '%s\n' "$BASHPID" > "$FAKE_PW_DIR/benchmark-child.pid"
                trap '' HUP INT TERM
                exec sleep 2
            fi
            if [ -r "$FAKE_PW_DIR/benchmark-fail-leg" ] \
                && [ "$leg" = "$(< "$FAKE_PW_DIR/benchmark-fail-leg")" ]; then
                exit 23
            fi
            ;;
        *)
            printf 'Unexpected fake command: %s\n' "$command" >&2
            exit 99
            ;;
    esac
}

if [ "${PIPEWIRE_PRO_AUDIO_FAKE_DISPATCH:-0}" = 1 ]; then
    fake_dispatch "$@"
    exit
fi

here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/pipewire-pro-audio-ab.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/pipewire-pro-audio-ab-test.XXXXXX")"
cleanup()
{
    case "$work" in
        "${TMPDIR:-/tmp}"/pipewire-pro-audio-ab-test.*) rm -rf -- "${work:?}" ;;
        *) printf 'Refusing to clean unexpected test path: %s\n' "$work" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

pass=0
fail()
{
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok()
{
    pass=$((pass + 1))
    printf 'ok - %s\n' "$*"
}
assert_eq()
{
    [ "$1" = "$2" ] || fail "$3 (got '$1', expected '$2')"
}
assert_status()
{
    local output="$1" filter="$2" expected="$3" label="$4" actual
    actual="$(jq -r "$filter" "$output/status.json")"
    assert_eq "$actual" "$expected" "$label"
}

case_dir=""
new_case()
{
    local name="$1" command
    case_dir="$work/$name"
    mkdir -p -- "$case_dir/bin" "$case_dir/prefix" "$case_dir/proc" \
        "$case_dir/runtime" "$case_dir/state" "$case_dir/xdg-state/wireplumber"
    printf '1 analog-stereo-duplex\n' > "$case_dir/state/current-profile"
    printf 'alsa_card.test_interface=analog-stereo-duplex\n' \
        > "$case_dir/xdg-state/wireplumber/default-profile"
    for command in pw-dump pw-cli wpctl pw-metadata benchmark; do
        ln -s -- "$here/test-pipewire-pro-audio-ab.sh" "$case_dir/bin/$command"
    done
}

start_tool()
{
    local mode="${1:-run}" output="$case_dir/output"
    local args=(--device 42 --wine-prefix "$case_dir/prefix" --output "$output")
    case "$mode" in
        discover) args+=(--discover) ;;
        dry-run) args+=(--dry-run) ;;
        *) args+=(-- "$case_dir/bin/benchmark") ;;
    esac
    (
        exec env \
            PATH="$case_dir/bin:$PATH" \
            XDG_RUNTIME_DIR="$case_dir/runtime" \
            XDG_STATE_HOME="$case_dir/xdg-state" \
            PIPEWIRE_PRO_AUDIO_FAKE_DISPATCH=1 \
            PIPEWIRE_PRO_AUDIO_PROC_ROOT="$case_dir/proc" \
            PIPEWIRE_PRO_AUDIO_VERIFY_ATTEMPTS=3 \
            PIPEWIRE_PRO_AUDIO_VERIFY_DELAY=0 \
            PIPEWIRE_PRO_AUDIO_PROBE_TIMEOUT=2 \
            PIPEWIRE_PRO_AUDIO_SETTLE_SECONDS=0 \
            PIPEWIRE_PRO_AUDIO_SIGNAL_WAIT_TIMEOUT=1 \
            FAKE_PW_DIR="$case_dir/state" \
            FAKE_DEVICE_ID=42 \
            FAKE_TARGET_PREFIX="$case_dir/prefix" \
            "$tool" "${args[@]}"
    ) > "$case_dir/run.stdout" 2> "$case_dir/run.stderr" &
    TOOL_PID=$!
}

run_tool()
{
    local mode="${1:-run}"
    start_tool "$mode"
    set +e
    wait "$TOOL_PID"
    TOOL_RC=$?
    set -e
}

new_case success
run_tool
assert_eq "$TOOL_RC" 0 'A successful matched run exits zero.'
assert_eq "$(cat "$case_dir/state/current-profile")" '1 analog-stereo-duplex' \
    'A successful run restores the exact original profile.'
assert_eq "$(tr '\n' ' ' < "$case_dir/state/benchmark.log")" 'baseline pro-audio ' \
    'The identical command runs once under A and once under B.'
assert_eq "$(wc -l < "$case_dir/state/pw-cli.log")" 2 \
    'A successful run performs one transient switch and one restoration.'
[ "$(grep -c '"save":false' "$case_dir/state/pw-cli.log")" -eq 2 ] \
    || fail 'Every profile mutation explicitly disables persistence.'
[ -f "$case_dir/output/A-original/timing.json" ] \
    && [ -f "$case_dir/output/A-original/before-state/device.json" ] \
    && [ -f "$case_dir/output/B-pro-audio/timing.json" ] \
    && [ -f "$case_dir/output/B-pro-audio/before-state/device.json" ] \
    && [ -f "$case_dir/output/B-pro-audio/after-state/associated-links.json" ] \
    && [ -f "$case_dir/output/events/immediately-before-switch/target-device-activity.json" ] \
    && [ -f "$case_dir/output/after-restoration/device.json" ] \
    || fail 'Both leg directories and restoration evidence are retained.'
assert_status "$case_dir/output" '.result' 'ab-complete' 'The success report classifies the complete A/B.'
assert_status "$case_dir/output" '.restoration' 'verified' 'The success report proves restoration.'
assert_status "$case_dir/output" '.settle_seconds' '0' 'The report records the equal per-leg settle interval.'
assert_status "$case_dir/output" '.restored_evidence.wireplumber_profile_state' 'verified' \
    'The WirePlumber profile state remains byte-identical.'
assert_status "$case_dir/output" '.restored_evidence.associated_node_fingerprint' 'verified' \
    'The stable associated-node fingerprint is explicitly named and restored.'
assert_status "$case_dir/output" '.target_device_graph.immediately_before_switch' 'clear' \
    'The exact target graph is clear at the last bounded pre-switch check.'
assert_status "$case_dir/output" '.target_device_graph.after_pro_audio' 'clear' \
    'The target graph is clear after the Pro Audio command.'
assert_status "$case_dir/output" '.order | join(" ")' 'baseline pro-audio' \
    'The report records the baseline-first order.'
if ! grep -q "$case_dir/output/A-original" "$case_dir/state/benchmark-dirs.log" \
    || ! grep -q "$case_dir/output/B-pro-audio" "$case_dir/state/benchmark-dirs.log"; then
    fail 'Each command receives its own explicit artifact directory.'
fi
ok 'Success runs a true matched A/B, uses save:false, separates artifacts, and proves restoration.'

new_case pro-audio-first
printf '9 pro-audio\n' > "$case_dir/state/current-profile"
run_tool
assert_eq "$TOOL_RC" 0 'A device already on Pro Audio can run a matched pair.'
assert_eq "$(cat "$case_dir/state/current-profile")" '9 pro-audio' \
    'A Pro-Audio-first pair restores the exact original Pro Audio profile.'
assert_eq "$(tr '\n' ' ' < "$case_dir/state/benchmark.log")" 'pro-audio baseline ' \
    'A Pro-Audio-first pair runs the saved baseline second.'
[ -f "$case_dir/output/A-original/timing.json" ] \
    && [ -f "$case_dir/output/B-baseline/timing.json" ] \
    || fail 'The reverse-order pair retains separate A and B artifacts.'
assert_status "$case_dir/output" '.order | join(" ")' 'pro-audio baseline' \
    'The report records the Pro-Audio-first order.'
assert_status "$case_dir/output" '.device.baseline_profile.name' 'analog-stereo-duplex' \
    'The report names the saved regular profile used as the baseline.'
assert_status "$case_dir/output" '.device.baseline_profile.source' 'wireplumber-saved' \
    'The report identifies WirePlumber as the reverse-order baseline source.'
assert_status "$case_dir/output" '.legs.A_original.profile' 'pro-audio' \
    'The A leg identifies its Pro Audio profile.'
assert_status "$case_dir/output" '.legs.B_baseline.profile' 'baseline' \
    'The B leg identifies its regular baseline profile.'
assert_status "$case_dir/output" '.restoration' 'verified' \
    'The reverse-order pair proves restoration.'
ok 'A saved regular profile enables a recorded Pro-Audio-first pair.'

new_case baseline-failure
printf 'baseline\n' > "$case_dir/state/benchmark-fail-leg"
run_tool
assert_eq "$TOOL_RC" 23 'A baseline command failure is returned unchanged.'
[ ! -e "$case_dir/state/pw-cli.log" ] || fail 'A failed baseline must not mutate the PipeWire profile.'
assert_status "$case_dir/output" '.result' 'baseline-benchmark-failed' \
    'A baseline failure is classified before mutation.'
assert_status "$case_dir/output" '.legs.B_pro_audio.state' 'not-run' \
    'The B leg does not run after an A failure.'
ok 'A baseline failure stops before any profile mutation.'

new_case baseline-state-drift
: > "$case_dir/state/benchmark-drifts-state"
run_tool
assert_eq "$TOOL_RC" 65 'Baseline state drift is rejected before profile mutation.'
[ ! -e "$case_dir/state/pw-cli.log" ] || fail 'Baseline state drift must not be followed by a profile switch.'
assert_status "$case_dir/output" '.result' 'baseline-state-changed' \
    'The changed baseline defaults are classified before B.'
assert_status "$case_dir/output" '.restored_evidence.defaults' 'changed' \
    'The final evidence retains the observed default-node drift.'
ok 'A changed baseline environment invalidates the pair before Pro Audio is selected.'

new_case pro-failure
printf 'pro-audio\n' > "$case_dir/state/benchmark-fail-leg"
run_tool
assert_eq "$TOOL_RC" 23 'A Pro Audio command failure is returned after restoration.'
assert_eq "$(cat "$case_dir/state/current-profile")" '1 analog-stereo-duplex' \
    'A failed B leg restores the original profile.'
assert_status "$case_dir/output" '.result' 'pro-audio-benchmark-failed' \
    'A B-leg failure is classified.'
assert_status "$case_dir/output" '.restoration' 'verified' \
    'A failed B leg records verified restoration.'
ok 'A Pro Audio benchmark failure preserves its status and still restores the device.'

new_case switch-failure
: > "$case_dir/state/switch-fails-after-mutation"
run_tool
assert_eq "$TOOL_RC" 74 'A profile switch command failure has a distinct exit code.'
assert_eq "$(cat "$case_dir/state/current-profile")" '1 analog-stereo-duplex' \
    'A failed switch is defensively restored to the original profile.'
assert_status "$case_dir/output" '.switch' 'failed' 'The switch failure is explicit in status.'
assert_status "$case_dir/output" '.restoration' 'verified' \
    'Restoration is verified even after the switch command fails.'
ok 'A switch failure after partial mutation never runs B and defensively restores the original profile.'

new_case missing-profile
: > "$case_dir/state/profiles-missing"
run_tool
assert_eq "$TOOL_RC" 65 'A missing Pro Audio profile fails discovery.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'Missing-profile discovery is read-only.'
assert_status "$case_dir/output" '.result' 'pro-audio-missing' 'Missing Pro Audio is classified exactly.'
ok 'A missing Pro Audio profile is rejected without a command or mutation.'

new_case ambiguous-profile
: > "$case_dir/state/profiles-ambiguous"
run_tool
assert_eq "$TOOL_RC" 65 'Duplicate Pro Audio profiles fail exact discovery.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'Ambiguous-profile discovery is read-only.'
assert_status "$case_dir/output" '.result' 'pro-audio-ambiguous' 'Ambiguous Pro Audio is classified exactly.'
ok 'Ambiguous profile enumeration is rejected without guessing an index.'

new_case running-target-node
: > "$case_dir/state/target-node-running"
run_tool
assert_eq "$TOOL_RC" 73 'A running node on the exact device blocks the experiment.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'A running target node must be refused before command execution or mutation.'
assert_status "$case_dir/output" '.result' 'target-device-active' \
    'Running target-node activity is classified exactly.'
assert_eq "$(jq '.blockers.running_nodes | length' \
    "$case_dir/output/before/target-device-activity.json")" 1 \
    'The focused graph evidence retains the running target node.'
ok 'A running target node is an evidence-backed pre-mutation refusal.'

new_case active-target-link
: > "$case_dir/state/target-link-active"
run_tool
assert_eq "$TOOL_RC" 73 'An active link connected to the exact device blocks the experiment.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'An active target link must be refused before command execution or mutation.'
assert_eq "$(jq '.blockers.active_links | length' \
    "$case_dir/output/before/target-device-activity.json")" 1 \
    'The focused graph evidence retains the active target link.'
assert_eq "$(jq -r '.blockers.active_links[0].peer.node_name' \
    "$case_dir/output/before/target-device-activity.json")" 'Firefox' \
    'The active-link blocker names the peer node.'
assert_eq "$(jq -r '.blockers.active_links[0].peer.application_name' \
    "$case_dir/output/before/target-device-activity.json")" 'Firefox' \
    'The active-link blocker names the peer application.'
ok 'An active target link is refused while the default paused passive link remains allowed.'

new_case restoration-failure
: > "$case_dir/state/restore-fails"
run_tool
assert_eq "$TOOL_RC" 70 'A restoration failure overrides a successful B exit.'
assert_eq "$(cat "$case_dir/state/current-profile")" '9 pro-audio' \
    'The fixture proves the device remains changed when restoration fails.'
assert_status "$case_dir/output" '.result' 'restoration-failed' 'Restoration failure dominates the report.'
assert_status "$case_dir/output" '.restoration' 'failed' 'Failed restoration is explicit.'
grep -Fq '\"save\":false' "$case_dir/output/recovery-command.txt" \
    || fail 'A bounded manual recovery command was recorded before mutation.'
bash -n "$case_dir/output/recovery-command.txt" \
    || fail 'The recovery artifact is valid shell syntax.'
ok 'A restoration failure is loud, nonzero, and leaves an exact recovery record.'

new_case recovery-comment-safety
: > "$case_dir/state/device-name-with-newline"
run_tool
assert_eq "$TOOL_RC" 0 'A device name containing a newline remains data, not recovery shell.'
assert_eq "$(wc -l < "$case_dir/output/recovery-command.txt")" 2 \
    'The recovery artifact remains exactly one command and one fixed comment.'
if grep -Fq 'injected' "$case_dir/output/recovery-command.txt"; then
    fail 'A PipeWire device name must never be embedded in executable recovery shell.'
fi
bash -n "$case_dir/output/recovery-command.txt" \
    || fail 'The recovery artifact remains valid shell syntax for hostile device names.'
ok 'Untrusted device identity cannot inject lines into the recovery shell artifact.'

new_case prefix-activity
mkdir -- "$case_dir/proc/700"
printf '%s\0' '/opt/wine/bin/wineserver' > "$case_dir/proc/700/cmdline"
printf '%s\0' "WINEPREFIX=$case_dir/prefix" > "$case_dir/proc/700/environ"
run_tool
assert_eq "$TOOL_RC" 73 'Existing exact-prefix Wine activity blocks the experiment.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'The active-process refusal runs no benchmark and changes no profile.'
assert_status "$case_dir/output" '.activity.preflight' 'detected' 'Activity evidence is retained.'
grep -q $'700\tprefix' "$case_dir/output/before/activity.tsv" \
    || fail 'The process guard records the blocking PID and reasons.'
ok 'Exact-prefix Wine activity is a hard refusal with no override.'

new_case live-activity
mkdir -- "$case_dir/proc/701"
printf '%s\0' 'C:\\ProgramData\\Ableton Live 12 Suite.exe' > "$case_dir/proc/701/cmdline"
: > "$case_dir/proc/701/environ"
run_tool
assert_eq "$TOOL_RC" 73 'An existing Live process blocks regardless of prefix evidence.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'The global Live refusal runs no benchmark and changes no profile.'
grep -q $'701\tLive' "$case_dir/output/before/activity.tsv" \
    || fail 'The activity artifact records global Live evidence.'
ok 'Live activity is independently refused even when its prefix cannot be read.'

new_case unresolved-wine-activity
mkdir -- "$case_dir/proc/702" "$case_dir/proc/702/environ"
printf '%s\0' '/opt/wine/bin/wine64-preloader' > "$case_dir/proc/702/cmdline"
run_tool
assert_eq "$TOOL_RC" 73 'Wine activity with an unreadable prefix environment blocks the experiment.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'Unresolved Wine activity runs no benchmark and changes no profile.'
grep -q $'702\tprefix-unresolved' "$case_dir/output/before/activity.tsv" \
    || fail 'The activity artifact records that the Wine prefix could not be resolved.'
if grep -Eq 'Permission denied|Is a directory' "$case_dir/run.stderr"; then
    fail 'An unreadable Wine environment must be classified without shell redirection noise.'
fi
ok 'Unreadable Wine prefix evidence is a conservative, quiet refusal.'

new_case unrelated-unreadable-environ
mkdir -- "$case_dir/proc/703" "$case_dir/proc/703/environ"
printf '%s\0' '/usr/bin/sleep' '30' > "$case_dir/proc/703/cmdline"
run_tool discover
assert_eq "$TOOL_RC" 0 'An unrelated process with unreadable environment data does not block discovery.'
if grep -Eq 'Permission denied|Is a directory' "$case_dir/run.stderr"; then
    fail 'The process guard must not open unrelated process environments.'
fi
ok 'Unrelated unreadable process environments are neither opened nor reported.'

new_case discovery
run_tool discover
assert_eq "$TOOL_RC" 0 'Read-only discovery succeeds on an eligible idle device.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'Discovery neither runs the command nor changes a profile.'
assert_status "$case_dir/output" '.result' 'discovery-ok' 'Discovery status is explicit.'
ok 'Discovery captures evidence without executing or mutating anything.'

new_case stale-lock
lock_path="$case_dir/runtime/ableton-pw-pro-audio-${UID}-42.lock"
mkdir -m 700 -- "$lock_path"
run_tool
assert_eq "$TOOL_RC" 73 'An existing per-device lock blocks the comparison.'
assert_status "$case_dir/output" '.result' 'concurrent-run' \
    'The lock refusal is classified exactly.'
assert_status "$case_dir/output" '.lock_path' "$lock_path" \
    'The report names the exact lock path.'
grep -Fq "$lock_path" "$case_dir/run.stderr" \
    || fail 'The lock refusal message must name the exact lock path.'
[ ! -e "$case_dir/state/benchmark.log" ] && [ ! -e "$case_dir/state/pw-cli.log" ] \
    || fail 'A lock refusal runs no benchmark and changes no profile.'
ok 'A concurrent or stale lock reports its exact recovery path.'

new_case dry-run-unsupported
run_tool dry-run
assert_eq "$TOOL_RC" 2 'The removed --dry-run alias is rejected as unsupported.'
[ ! -e "$case_dir/output" ] \
    || fail 'An unsupported --dry-run option must not create a report directory.'
grep -Fq 'Received: --dry-run' "$case_dir/run.stderr" \
    || fail 'The unsupported alias is identified in the usage error.'
ok 'Discovery has one explicit, non-mutatingly-named CLI option.'

new_case final-activity
: > "$case_dir/state/activity-after-restore"
run_tool
assert_eq "$TOOL_RC" 73 'Activity first observed after restoration invalidates an otherwise successful pair.'
assert_eq "$(cat "$case_dir/state/current-profile")" '1 analog-stereo-duplex' \
    'Final activity detection does not prevent verified profile restoration.'
assert_status "$case_dir/output" '.result' 'post-restoration-activity' \
    'The final activity race cannot be reported as a complete A/B.'
assert_status "$case_dir/output" '.activity.after_restoration' 'detected' \
    'The late exact-prefix process remains explicit in status.'
ok 'Late activity makes a restored pair fail loud instead of returning a false clean result.'

new_case pro-leaves-active-link
: > "$case_dir/state/benchmark-leaves-active-link"
run_tool
assert_eq "$TOOL_RC" 73 'A target link left active after B invalidates the pair.'
assert_eq "$(cat "$case_dir/state/current-profile")" '1 analog-stereo-duplex' \
    'Post-B target activity still triggers exact profile restoration.'
assert_status "$case_dir/output" '.result' 'pro-audio-target-active' \
    'Post-B target graph activity is classified before restoration.'
assert_status "$case_dir/output" '.target_device_graph.after_pro_audio' 'active' \
    'The report records target graph activity observed after B.'
ok 'Post-B active-link evidence fails loud and restoration still wins.'

new_case signal
printf 'pro-audio\n' > "$case_dir/state/benchmark-sleep-leg"
start_tool
reached_pro=0
for _ in $(seq 1 100); do
    if [ "$(cat "$case_dir/state/current-profile")" = '9 pro-audio' ] \
        && grep -qx 'pro-audio' "$case_dir/state/benchmark.log" 2>/dev/null; then
        reached_pro=1
        break
    fi
    sleep 0.05
done
[ "$reached_pro" -eq 1 ] || fail 'The signal fixture did not reach the Pro Audio benchmark.'
kill -TERM "$TOOL_PID"
set +e
wait "$TOOL_PID"
TOOL_RC=$?
set -e
assert_eq "$TOOL_RC" 143 'TERM is reflected in the process exit status.'
assert_eq "$(cat "$case_dir/state/current-profile")" '1 analog-stereo-duplex' \
    'TERM during B restores the original profile.'
assert_status "$case_dir/output" '.result' 'signal-term' 'The report identifies the signal.'
assert_status "$case_dir/output" '.restoration' 'verified' 'Signal cleanup verifies restoration.'
assert_status "$case_dir/output" '.legs.B_pro_audio.state' 'signalled' 'The interrupted B leg is explicit.'
ok 'TERM during B stops the child, restores the profile, and retains timing/status.'

new_case signal-ignored
printf 'pro-audio\n' > "$case_dir/state/benchmark-ignore-signal-leg"
start_tool
reached_pro=0
for _ in $(seq 1 100); do
    if [ "$(cat "$case_dir/state/current-profile")" = '9 pro-audio' ] \
        && grep -qx 'pro-audio' "$case_dir/state/benchmark.log" 2>/dev/null; then
        reached_pro=1
        break
    fi
    sleep 0.05
done
[ "$reached_pro" -eq 1 ] || fail 'The ignored-signal fixture did not reach the Pro Audio benchmark.'
kill -TERM "$TOOL_PID"
signal_started="$SECONDS"
set +e
wait "$TOOL_PID"
TOOL_RC=$?
set -e
[ "$((SECONDS - signal_started))" -le 3 ] \
    || fail 'An uncooperative benchmark child delayed restoration beyond the bounded wait.'
assert_eq "$TOOL_RC" 143 'TERM remains the wrapper status when the exact child ignores it.'
assert_eq "$(cat "$case_dir/state/current-profile")" '1 analog-stereo-duplex' \
    'An uncooperative child cannot indefinitely postpone profile restoration.'
assert_status "$case_dir/output" '.legs.B_pro_audio.state' 'signal-child-active' \
    'The report does not claim that the uncooperative direct child stopped.'
[ -f "$case_dir/output/B-pro-audio/signal-child-active.pid" ] \
    || fail 'The exact still-active child PID is retained as evidence.'
child_pid="$(cat "$case_dir/state/benchmark-child.pid")"
child_gone=0
for _ in $(seq 1 60); do
    if ! kill -0 "$child_pid" 2>/dev/null; then child_gone=1; break; fi
    sleep 0.05
done
[ "$child_gone" -eq 1 ] || fail 'The bounded ignored-signal fixture did not end naturally.'
ok 'Signal teardown is bounded to the exact direct child and restores without broad killing.'

printf '1..%s\n' "$pass"
