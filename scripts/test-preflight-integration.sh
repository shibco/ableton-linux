#!/usr/bin/env bash
# Cross-boundary contract for pre-flight CLI intent, transaction timing,
# launcher consumption, uninstall ownership, packaging, and documentation.
# Behaviour IDs map to notes/PREFLIGHT-SETTINGS-TEST-MATRIX.md.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-preflight-integration-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

pass=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

preferences_lib="$here/lib/preferences.sh"
[ -r "$preferences_lib" ] || fail "scripts/lib/preferences.sh exists before integration tests run"
. "$preferences_lib"

# A complete but side-effect-light coordinator kit. The real dispatcher and
# lifecycle libraries run; only the expensive runtime/prefix/Link components
# are replaced. The prefix stub exposes values inherited at the core boundary.
kit="$work/kit"
mkdir -p -- "$kit/scripts/lib" "$kit/bin"
cp -- "$here/installer.sh" "$kit/scripts/"
cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" "$here/lib/live-options.sh" \
    "$here/lib/manifest.sh" "$here/lib/pipeasio.sh" "$here/lib/preferences.sh" \
    "$here/lib/ui.sh" "$kit/scripts/lib/"
cat > "$kit/bin/pipewire-version-probe" <<'EOF'
#!/bin/sh
printf 'client=1.4.2\ndaemon=1.4.2\n'
EOF
cat > "$kit/scripts/install.sh" <<'EOF'
#!/bin/sh
set -eu
assert_settings_unchanged()
{
    preferences="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/preferences"
    buffer="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
    [ -z "${ABLETON_TEST_EXPECT_PREFERENCES_SHA:-}" ] \
        || [ "$(sha256sum "$preferences" | awk '{print $1}')" \
             = "$ABLETON_TEST_EXPECT_PREFERENCES_SHA" ] || exit 93
    [ -z "${ABLETON_TEST_EXPECT_BUFFER_SHA:-}" ] \
        || [ "$(sha256sum "$buffer" | awk '{print $1}')" \
             = "$ABLETON_TEST_EXPECT_BUFFER_SHA" ] || exit 94
}
printf 'component args=%s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
case " $* " in
    *' --integration-only '*) exit "${ABLETON_TEST_INTEGRATION_EXIT:-0}" ;;
    *' --commit '*) exit "${ABLETON_TEST_COMPONENT_COMMIT_EXIT:-0}" ;;
    *' --preflight-commit '*)
        assert_settings_unchanged
        if [ "${ABLETON_TEST_ASSERT_SETTINGS_BEFORE_CORE:-0}" -eq 1 ] \
           && [ -e "${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/preferences" ]; then
            exit 91
        fi
        exit "${ABLETON_TEST_COMPONENT_PREFLIGHT_EXIT:-0}" ;;
    *' --preflight-rollback '*)
        assert_settings_unchanged
        exit "${ABLETON_TEST_COMPONENT_ROLLBACK_PREFLIGHT_EXIT:-0}" ;;
    *' --rollback '*) exit "${ABLETON_TEST_COMPONENT_ROLLBACK_EXIT:-0}" ;;
    *' --transaction-dir '*)
        assert_settings_unchanged
        exit "${ABLETON_TEST_COMPONENT_CORE_EXIT:-0}" ;;
esac
exit 0
EOF
cat > "$kit/scripts/setup-prefix.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/preferences.sh"
printf 'prefix args=%s seed=%s dpi=%s\n' "$*" \
    "${ABLETON_PIPEASIO_BUFFER_SEED:-unset}" "${ABLETON_DPI_MODE:-unset}" \
    >> "${ABLETON_TEST_CALL_LOG:?}"
preferences="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/preferences"
buffer="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
transaction=""
previous=""
for argument; do
    if [ "$previous" = --transaction-dir ] \
       || [ "$previous" = --rollback ] \
       || [ "$previous" = --preflight-rollback ] \
       || [ "$previous" = --preflight-commit ] \
       || [ "$previous" = --commit ]; then
        transaction="$argument"
    fi
    previous="$argument"
done
assert_settings_unchanged()
{
    allow_core_seed="${1:-0}"
    [ -z "${ABLETON_TEST_EXPECT_PREFERENCES_SHA:-}" ] \
        || [ "$(sha256sum "$preferences" | awk '{print $1}')" \
             = "$ABLETON_TEST_EXPECT_PREFERENCES_SHA" ] || exit 93
    [ -z "${ABLETON_TEST_EXPECT_BUFFER_SHA:-}" ] \
        || [ "$(sha256sum "$buffer" | awk '{print $1}')" \
             = "$ABLETON_TEST_EXPECT_BUFFER_SHA" ] || exit 94
    if [ "${ABLETON_TEST_ASSERT_SETTINGS_BEFORE_CORE:-0}" -eq 1 ]; then
        [ ! -e "$preferences" ] || exit 91
        [ "$allow_core_seed" -eq 1 ] || [ ! -e "$buffer" ] || exit 92
    fi
}
case " $* " in
    *' --validate '*) assert_settings_unchanged; exit 0 ;;
    *' --commit '*) ableton_pipeasio_seed_record_commit "$transaction"; exit 0 ;;
    *' --preflight-commit '*)
        # Prefix construction owns a fresh PipeASIO seed, so it may exist at
        # this boundary. Launcher preferences and any pre-core write remain
        # forbidden; existing buffers are still hash-checked above.
        assert_settings_unchanged 1
        ableton_pipeasio_seed_record_commit_preflight "$transaction"
        ableton_pipeasio_seed_record_load "$transaction"
        if [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ]; then
            recorded_token="$ABLETON_PIPEASIO_SEED_TOKEN"
            current_token="$(ableton_preferences_object_token "$buffer")"
            printf 'prefix preflight recorded-token=%s\n' "$recorded_token" \
                >> "${ABLETON_TEST_CALL_LOG:?}"
            printf 'prefix preflight current-token=%s\n' "$current_token" \
                >> "${ABLETON_TEST_CALL_LOG:?}"
            [ "$recorded_token" = "$current_token" ] \
                || [ "${ABLETON_TEST_REPLACE_SEED_SAME_VALUE:-0}" -eq 1 ] \
                || exit 95
        fi
        exit "${ABLETON_TEST_PREFIX_PREFLIGHT_EXIT:-0}" ;;
    *' --preflight-rollback '*) ableton_pipeasio_seed_record_preflight "$transaction"; exit 0 ;;
    *' --rollback '*)
        ableton_pipeasio_seed_record_rollback "$transaction"
        rm -rf -- "${ABLETON_WINEPREFIX:?}"
        exit 0 ;;
esac
assert_settings_unchanged
[ "${ABLETON_TEST_PREFIX_CORE_EXIT:-0}" -eq 0 ] \
    || exit "${ABLETON_TEST_PREFIX_CORE_EXIT}"
mkdir -p -- "${ABLETON_WINEPREFIX:?}"
printf 'WINE REGISTRY Version 2\n' > "$ABLETON_WINEPREFIX/system.reg"
pipeasio="${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini"
if [ ! -e "$pipeasio" ]; then
    mkdir -p -- "$(dirname "$pipeasio")"
    pipeasio_tmp="$(dirname "$pipeasio")/.config.ini.ABC123"
    printf '[pipeasio]\nbuffer_size = %s\n' \
        "${ABLETON_PIPEASIO_BUFFER_SEED:-256}" > "$pipeasio_tmp"
    chmod 600 "$pipeasio_tmp"
    producer_token="$(ableton_pipeasio_seed_identity_token "$pipeasio_tmp")"
    ableton_pipeasio_seed_record_publish "$transaction" "$pipeasio" \
        "$producer_token" "$pipeasio_tmp"
    mv -T -n -- "$pipeasio_tmp" "$pipeasio"
    if [ "${ABLETON_TEST_REPLACE_SEED_BEFORE_TOKEN:-0}" -eq 1 ]; then
        replacement="$pipeasio.replacement"
        cp -- "$pipeasio" "$replacement"
        mv -T -f -- "$replacement" "$pipeasio"
        replacement_token="$(ableton_preferences_object_token "$pipeasio")"
        printf 'prefix pre-token-replacement-token=%s\n' "$replacement_token" \
            >> "${ABLETON_TEST_CALL_LOG:?}"
    fi
    if [ "${ABLETON_TEST_SKIP_SEED_PROMOTION:-0}" -eq 1 ]; then
        printf 'prefix provisional-seed=%s\n' "$producer_token" \
            >> "${ABLETON_TEST_CALL_LOG:?}"
    else
        if ! ableton_pipeasio_seed_record_promote "$transaction" "$pipeasio" \
                "$producer_token"; then
            ableton_pipeasio_seed_record_rollback "$transaction"
            exit 79
        fi
        seed_token="$(ableton_preferences_object_token "$pipeasio")"
        printf 'prefix seed-token=%s\n' "$seed_token" >> "${ABLETON_TEST_CALL_LOG:?}"
    fi
fi
if [ "${ABLETON_TEST_CAPTURE_RECOVERY_OBJECTS:-0}" -eq 1 ]; then
    printf 'active recovery evidence\n' > "$transaction/active"
    printf 'prefix captured-buffer-object=%s\n' \
        "$(ableton_preferences_object_token "$pipeasio")" \
        >> "${ABLETON_TEST_CALL_LOG:?}"
    printf 'prefix captured-journal-object=%s\n' \
        "$(ableton_preferences_object_token "$transaction/pipeasio-seed.v1")" \
        >> "${ABLETON_TEST_CALL_LOG:?}"
    printf 'prefix captured-active-object=%s\n' \
        "$(ableton_preferences_object_token "$transaction/active")" \
        >> "${ABLETON_TEST_CALL_LOG:?}"
    printf 'prefix captured-prefix-object=%s\n' \
        "$(ableton_preferences_object_token "$ABLETON_WINEPREFIX/system.reg")" \
        >> "${ABLETON_TEST_CALL_LOG:?}"
fi
if [ "${ABLETON_TEST_PREFIX_FAIL_AFTER_SEED:-0}" -ne 0 ]; then
    exit "$ABLETON_TEST_PREFIX_FAIL_AFTER_SEED"
fi
if [ "${ABLETON_TEST_REPLACE_SEED_SAME_VALUE:-0}" -eq 1 ]; then
    replacement="$pipeasio.replacement"
    cp -- "$pipeasio" "$replacement"
    mv -T -f -- "$replacement" "$pipeasio"
    replacement_token="$(ableton_preferences_object_token "$pipeasio")"
    printf 'prefix replacement-token=%s\n' "$replacement_token" \
        >> "${ABLETON_TEST_CALL_LOG:?}"
fi
if [ "${ABLETON_TEST_MALFORMED_SEED_JOURNAL:-0}" -eq 1 ]; then
    path_b64="$(printf '%s' "$pipeasio" | base64 | tr -d '\n')"
    token_b64="$(printf '%s' 'file|garbage' | base64 | tr -d '\n')"
    printf 'format=1\npath_b64=%s\ntoken_b64=%s\ntemp_b64=\n' \
        "$path_b64" "$token_b64" > "$transaction/pipeasio-seed.v1"
    printf 'active recovery evidence\n' > "$transaction/active"
    printf 'prefix malformed-buffer-object=%s\n' \
        "$(ableton_preferences_object_token "$pipeasio")" \
        >> "${ABLETON_TEST_CALL_LOG:?}"
    printf 'prefix malformed-journal-object=%s\n' \
        "$(ableton_preferences_object_token "$transaction/pipeasio-seed.v1")" \
        >> "${ABLETON_TEST_CALL_LOG:?}"
    printf 'prefix malformed-active-object=%s\n' \
        "$(ableton_preferences_object_token "$transaction/active")" \
        >> "${ABLETON_TEST_CALL_LOG:?}"
fi
if [ "${ABLETON_TEST_RACE_BUFFER:-0}" -eq 1 ]; then
    printf 'outputs = 7\n' >> "$pipeasio"
fi
case "${ABLETON_TEST_RACE_PREFERENCES:-off}" in
    replace|create)
        preferences="${XDG_CONFIG_HOME:-$HOME/.config}/ableton-wine/preferences"
        mkdir -p -- "$(dirname "$preferences")"
        cat > "$preferences" <<'PREFERENCES'
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=preserve
dpi=100
audio_threads=8
rt=auto
power=off
PREFERENCES
        chmod 600 "$preferences" ;;
esac
EOF
cat > "$kit/scripts/setup-link.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'link args=%s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
exit "${ABLETON_TEST_LINK_EXIT:-0}"
EOF
cat > "$kit/scripts/uninstall.sh" <<'EOF'
#!/bin/sh
printf 'uninstall args=%s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
exit 0
EOF
chmod 755 "$kit/scripts/"*.sh "$kit/bin/pipewire-version-probe"

new_case()   # name -> base
{
    local base="$work/$1"
    mkdir -p -- "$base/home" "$base/config" "$base/data" "$base/state" \
        "$base/cache" "$base/run" "$base/tmp" "$base/runtime/bin"
    printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/wine"
    printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/wineserver"
    chmod 755 "$base/runtime/bin/"*
    : > "$base/calls.log"
    printf '%s\n' "$base"
}

run_public()   # base [ENV=VALUE ...] -- installer arguments...
{
    local base="$1"; shift
    local -a extra=()
    while [ "${1:-}" != -- ]; do extra+=("$1"); shift; done
    shift
    env -i PATH="$PATH" HOME="$base/home" USER=test \
        XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data" \
        XDG_STATE_HOME="$base/state" XDG_CACHE_HOME="$base/cache" \
        XDG_RUNTIME_DIR="$base/run" TMPDIR="$base/tmp" LANG=C.UTF-8 \
        ABLETON_TEST_CALL_LOG="$base/calls.log" "${extra[@]}" \
        bash "$kit/scripts/installer.sh" "$@"
}

write_preferences()   # base shortcuts dpi threads rt power
{
    local base="$1" shortcuts="$2" dpi="$3" threads="$4" rt="$5" power="$6"
    mkdir -p -- "$base/config/ableton-wine"
    printf '%s\n' \
        '# ableton-linux launcher preferences; managed by the installer' \
        'format=1' "shortcuts=$shortcuts" "dpi=$dpi" \
        "audio_threads=$threads" "rt=$rt" "power=$power" \
        > "$base/config/ableton-wine/preferences"
    chmod 600 "$base/config/ableton-wine/preferences"
}

make_update_state()   # base
{
    local base="$1"
    mkdir -p -- "$base/prefix" "$base/config/ableton-wine"
    printf 'WINE REGISTRY Version 2\n' > "$base/prefix/system.reg"
    printf 'format=1\nprefix=%s\n' "$base/prefix" \
        > "$base/prefix/.ableton-linux-prefix"
}

mutable_token()   # base: all user-mutated roots, excluding test logs
{
    local base="$1"
    local -a entries=(home config data state cache run runtime)
    [ ! -e "$base/prefix" ] || entries+=(prefix)
    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
        -cf - -C "$base" "${entries[@]}" 2>/dev/null \
        | sha256sum
}

# CLI-SCHEMA: the six flags have exact grammars, reject duplicates, and are
# valid only for the coordinated install/update commands.
base="$(new_case cli-schema)"
valid=(--audio-buffer=1024 --shortcuts=preserve --dpi=fractional \
       --audio-threads=63 --rt=off --power=balanced)
run_public "$base" -- plan install --skip-live-install --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" "${valid[@]}" \
    >"$base/out" 2>"$base/err" \
    || fail "the six valid persistent flags are rejected by plan install"
make_update_state "$base"
run_public "$base" -- plan update --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" "${valid[@]}" >"$base/update.out" 2>"$base/update.err" \
    || fail "the six valid persistent flags are rejected by plan update"
allowed_flags=(
    --audio-buffer=64 --audio-buffer=128 --audio-buffer=256
    --audio-buffer=512 --audio-buffer=1024
    --shortcuts=take --shortcuts=preserve
    --dpi=auto --dpi=100 --dpi=fractional --dpi=preserve
    --audio-threads=auto --audio-threads=off
    --audio-threads=1 --audio-threads=63
    --rt=auto --rt=off
    --power=performance --power=balanced --power=off
)
for worker in $(seq 2 62); do
    allowed_flags+=("--audio-threads=$worker")
done
allowed_index=0
for allowed in "${allowed_flags[@]}"; do
    allowed_index=$((allowed_index + 1))
    allowed_base="$(new_case "allowed-$allowed_index")"
    run_public "$allowed_base" -- plan install --skip-live-install --link=off \
        --runtime-root "$allowed_base/runtime" --prefix "$allowed_base/prefix" \
        "$allowed" >"$allowed_base/install.out" 2>"$allowed_base/install.err" \
        || fail "allowed persistent value is rejected by plan install: $allowed"
    make_update_state "$allowed_base"
    run_public "$allowed_base" -- plan update --link=off \
        --runtime-root "$allowed_base/runtime" --prefix "$allowed_base/prefix" \
        "$allowed" >"$allowed_base/update.out" 2>"$allowed_base/update.err" \
        || fail "allowed persistent value is rejected by plan update: $allowed"
done
for invalid in --audio-buffer=32 --audio-buffer=2048 --audio-buffer=064 \
               --audio-buffer=128x --shortcuts=other --shortcuts=take-now \
               --dpi=125 --dpi=Auto --dpi=dpi100 \
               --audio-threads=0 --audio-threads=64 --audio-threads=01 \
               --audio-threads=1x --rt=on --rt=automatic \
               --power=auto --power=fast --power=performance-mode; do
    for invalid_command in install update; do
        invalid_status=0
        invalid_extra=()
        [ "$invalid_command" != install ] || invalid_extra=(--skip-live-install)
        run_public "$base" -- plan "$invalid_command" "${invalid_extra[@]}" \
            --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" \
            "$invalid" >"$base/invalid.out" 2>"$base/invalid.err" \
            || invalid_status=$?
        [ "$invalid_status" -eq 2 ] \
            || fail "invalid $invalid_command flag has status $invalid_status, not parser status 2: $invalid"
        grep -qF -- "${invalid%%=*}" "$base/invalid.err" \
            || fail "invalid $invalid_command flag diagnostic does not name ${invalid%%=*}"
    done
done
invalid_forms=(
    '--audio-buffer' '--audio-buffer=' '--audio-buffer 128'
    '--shortcuts' '--shortcuts=' '--shortcuts take'
    '--dpi' '--dpi=' '--dpi auto'
    '--audio-threads' '--audio-threads=' '--audio-threads 8'
    '--rt' '--rt=' '--rt auto'
    '--power' '--power=' '--power balanced'
)
for invalid_form in "${invalid_forms[@]}"; do
    read -r -a invalid_words <<< "$invalid_form"
    invalid_name="${invalid_words[0]%%=*}"
    for invalid_command in install update; do
        invalid_status=0
        invalid_extra=()
        [ "$invalid_command" != install ] || invalid_extra=(--skip-live-install)
        run_public "$base" -- plan "$invalid_command" "${invalid_extra[@]}" \
            --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" \
            "${invalid_words[@]}" >"$base/form.out" 2>"$base/form.err" \
            || invalid_status=$?
        [ "$invalid_status" -eq 2 ] \
            || fail "$invalid_command accepts invalid flag form: $invalid_form"
        grep -qF -- "$invalid_name" "$base/form.err" \
            || fail "invalid flag-form diagnostic does not name $invalid_name"
    done
done
scoped_flags=(--audio-buffer=128 --shortcuts=take --dpi=auto \
              --audio-threads=auto --rt=auto --power=performance)
for duplicate in "${scoped_flags[@]}"; do
    for duplicate_command in install update; do
        duplicate_status=0
        duplicate_extra=()
        [ "$duplicate_command" != install ] || duplicate_extra=(--skip-live-install)
        run_public "$base" -- plan "$duplicate_command" "${duplicate_extra[@]}" \
            --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" \
            "$duplicate" "$duplicate" >"$base/dup.out" 2>"$base/dup.err" \
            || duplicate_status=$?
        [ "$duplicate_status" -eq 2 ] \
            || fail "repeated ${duplicate%%=*} with $duplicate_command has status $duplicate_status, not 2"
        grep -qi "more than once\|specified twice\|duplicate" "$base/dup.err" \
            || fail "repeated ${duplicate%%=*} with $duplicate_command has no duplication diagnostic"
    done
done
conflicting_duplicates=(
    '--audio-buffer=64|--audio-buffer=128'
    '--shortcuts=take|--shortcuts=preserve'
    '--dpi=auto|--dpi=100'
    '--audio-threads=1|--audio-threads=63'
    '--rt=auto|--rt=off'
    '--power=performance|--power=balanced'
)
for pair in "${conflicting_duplicates[@]}"; do
    first="${pair%%|*}"
    second="${pair#*|}"
    for duplicate_command in install update; do
        duplicate_status=0
        duplicate_extra=()
        [ "$duplicate_command" != install ] || duplicate_extra=(--skip-live-install)
        run_public "$base" -- plan "$duplicate_command" "${duplicate_extra[@]}" \
            --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" \
            "$first" "$second" >"$base/conflict.out" 2>"$base/conflict.err" \
            || duplicate_status=$?
        [ "$duplicate_status" -eq 2 ] \
            || fail "conflicting ${first%%=*} values with $duplicate_command do not fail as duplicates"
        grep -qi "more than once\|specified twice\|duplicate" "$base/conflict.err" \
            || fail "conflicting ${first%%=*} values have no duplicate diagnostic"
    done
done
for unrelated in 'runtime install' 'prefix create' 'link enable' 'uninstall'; do
    read -r -a command_words <<< "$unrelated"
    for scoped in "${scoped_flags[@]}"; do
        unrelated_status=0
        run_public "$base" -- "${command_words[@]}" "$scoped" --dry-run \
            >"$base/unrelated.out" 2>"$base/unrelated.err" \
            || unrelated_status=$?
        [ "$unrelated_status" -eq 2 ] \
            || fail "$scoped with $unrelated has status $unrelated_status, not parser status 2"
        grep -qF -- "${scoped%%=*}" "$base/unrelated.err" \
            || fail "$unrelated rejection does not name ${scoped%%=*}: $unrelated"
    done
done
ok "CLI-SCHEMA: exact setting grammars, duplication, and command scope are enforced"

# CLI-COMMIT-MATRIX: every user-selectable equivalence class reaches its exact
# persistent representation through both coordinated Install and Update.
commit_rows=(
    'audio-buffer|64|buffer_size|64' 'audio-buffer|128|buffer_size|128'
    'audio-buffer|256|buffer_size|256' 'audio-buffer|512|buffer_size|512'
    'audio-buffer|1024|buffer_size|1024'
    'shortcuts|take|shortcuts|take' 'shortcuts|preserve|shortcuts|preserve'
    'dpi|auto|dpi|auto' 'dpi|100|dpi|100' 'dpi|fractional|dpi|fractional'
    'dpi|preserve|dpi|preserve'
    'audio-threads|auto|audio_threads|auto' 'audio-threads|off|audio_threads|off'
    'audio-threads|1|audio_threads|1' 'audio-threads|16|audio_threads|16'
    'audio-threads|63|audio_threads|63'
    'rt|auto|rt|auto' 'rt|off|rt|off'
    'power|performance|power|performance' 'power|balanced|power|balanced'
    'power|off|power|off'
)
commit_index=0
for row in "${commit_rows[@]}"; do
    IFS='|' read -r option value key expected <<< "$row"
    for commit_command in install update; do
        commit_index=$((commit_index + 1))
        commit_base="$(new_case "commit-$commit_index")"
        commit_extra=()
        if [ "$commit_command" = install ]; then
            commit_extra=(--skip-live-install)
        else
            make_update_state "$commit_base"
            mkdir -p -- "$commit_base/config/pipeasio"
            printf '[pipeasio]\nbuffer_size = 2048\n' \
                > "$commit_base/config/pipeasio/config.ini"
            case "$key:$expected" in
                shortcuts:take) write_preferences "$commit_base" preserve auto auto auto performance ;;
                shortcuts:preserve) write_preferences "$commit_base" take auto auto auto performance ;;
                dpi:auto) write_preferences "$commit_base" take preserve auto auto performance ;;
                dpi:*) write_preferences "$commit_base" take auto auto auto performance ;;
                audio_threads:auto) write_preferences "$commit_base" take auto off auto performance ;;
                audio_threads:*) write_preferences "$commit_base" take auto auto auto performance ;;
                rt:auto) write_preferences "$commit_base" take auto auto off performance ;;
                rt:off) write_preferences "$commit_base" take auto auto auto performance ;;
                power:performance) write_preferences "$commit_base" take auto auto auto off ;;
                power:*) write_preferences "$commit_base" take auto auto auto performance ;;
            esac
        fi
        run_public "$commit_base" -- "$commit_command" "${commit_extra[@]}" \
            --link=off --runtime-root "$commit_base/runtime" \
            --prefix "$commit_base/prefix" --yes "--$option=$value" \
            >"$commit_base/out" 2>"$commit_base/err" \
            || fail "$commit_command rejects or cannot commit --$option=$value"
        if [ "$key" = buffer_size ]; then
            grep -qxF "buffer_size = $expected" \
                "$commit_base/config/pipeasio/config.ini" \
                || fail "$commit_command mis-commits --$option=$value"
            [ "$(grep -Ec '^[[:space:]]*buffer_size[[:space:]]*=' \
                "$commit_base/config/pipeasio/config.ini")" -eq 1 ] \
                || fail "$commit_command duplicates --$option=$value"
        else
            preferences="$commit_base/config/ableton-wine/preferences"
            grep -qxF "$key=$expected" "$preferences" \
                || fail "$commit_command mis-commits --$option=$value"
            [ "$(grep -c "^$key=" "$preferences")" -eq 1 ] \
                || fail "$commit_command duplicates --$option=$value"
            # shellcheck disable=SC2016 # child shell receives library/data as positional arguments
            env -i PATH="$PATH" HOME="$commit_base/home" \
                XDG_CONFIG_HOME="$commit_base/config" bash -c \
                '. "$1"; ableton_preferences_valid "$2"' \
                _ "$preferences_lib" "$preferences" \
                || fail "$commit_command produces a non-exact preference record for --$option=$value"
        fi
    done
done
ok "CLI-COMMIT-MATRIX: every selectable value commits exactly through Install and Update"

# DRY-RUN: planning validates and describes intent but does not create either
# mutable settings file or run a core mutation.
base="$(new_case dry-run)"
before="$(mutable_token "$base")"
run_public "$base" -- plan install --skip-live-install --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" \
    --audio-buffer=512 --shortcuts=preserve --dpi=fractional \
    --audio-threads=16 --rt=off --power=balanced \
    >"$base/out" 2>"$base/err" || fail "valid pre-flight plan fails"
[ ! -e "$base/config/ableton-wine/preferences" ] \
    && [ ! -e "$base/config/pipeasio/config.ini" ] \
    || fail "dry-run writes preferences or PipeASIO configuration"
[ "$(mutable_token "$base")" = "$before" ] \
    || fail "dry-run changes a mutable user root"
for planned in 'Audio buffer: 512 frames' \
               'Keyboard shortcuts: Preserve desktop shortcuts' \
               'Display scaling: Fractional' 'Audio workers: 16' \
               'Real-time scheduling: Normal' 'Power profile: Balanced'; do
    grep -qF "$planned" "$base/out" \
        || fail "dry-run does not describe: $planned"
done
! grep -q 'transaction-dir' "$base/calls.log" \
    || fail "dry-run reached a core mutation"
grep -q 'dpi=fractional' "$base/calls.log" \
    || fail "selected DPI is not present during prefix validation"

base="$(new_case dry-run-option)"
before="$(mutable_token "$base")"
run_public "$base" -- install --skip-live-install --link=off --dry-run \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --audio-buffer=64 \
    >"$base/out" 2>"$base/err" || fail "--dry-run setting plan fails"
[ "$(mutable_token "$base")" = "$before" ] \
    || fail "--dry-run option changes a mutable user root"
grep -qF 'Audio buffer: 64 frames' "$base/out" \
    || fail "--dry-run option does not describe its selected audio buffer"
! grep -q 'transaction-dir' "$base/calls.log" \
    || fail "--dry-run option reached a core mutation"

base="$(new_case dry-run-update)"
make_update_state "$base"
mkdir -p -- "$base/config/pipeasio"
printf '[pipeasio]\nbuffer_size = 2048\n' > "$base/config/pipeasio/config.ini"
write_preferences "$base" preserve preserve off off balanced
before="$(mutable_token "$base")"
run_public "$base" -- plan update --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --audio-buffer=256 --power=performance \
    >"$base/out" 2>"$base/err" || fail "existing Update plan fails"
[ "$(mutable_token "$base")" = "$before" ] \
    || fail "Update plan changes existing preferences or PipeASIO data"
grep -qF 'Audio buffer: 256 frames' "$base/out" \
    || fail "Update plan does not describe its selected audio buffer"
grep -qF 'Power profile: Performance' "$base/out" \
    || fail "Update plan does not describe its selected power profile"
! grep -q 'transaction-dir' "$base/calls.log" \
    || fail "Update plan reached a core mutation"
ok "DRY-RUN: selected settings are validated and planned without mutation"

# FRESH-SEED/NO-IMPLICIT-PREFS: the coordinated install seeds 128 when the
# PipeASIO file is absent. Launcher environment is per-run and is never saved
# without an explicit persistent flag.
base="$(new_case fresh-default)"
run_public "$base" ABLETON_POWER=balanced ABLETON_SHORTCUTS=preserve -- \
    install --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes >"$base/out" 2>"$base/err" \
    || fail "fresh coordinated install fails"
grep -qxF 'buffer_size = 128' "$base/config/pipeasio/config.ini" \
    || fail "fresh coordinated install does not seed the confirmed 128 default"
[ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "launcher environment is silently persisted"
grep -Eq 'prefix args=.*--transaction-dir.* seed=128 dpi=' "$base/calls.log" \
    || fail "the 128 seed was not passed into the core prefix transaction"
seed_token="$(sed -n 's/^prefix seed-token=//p' "$base/calls.log" | tail -n 1)"
recorded_token="$(sed -n 's/^prefix preflight recorded-token=//p' "$base/calls.log" | tail -n 1)"
current_token="$(sed -n 's/^prefix preflight current-token=//p' "$base/calls.log" | tail -n 1)"
[ -n "$seed_token" ] && [ "$recorded_token" = "$seed_token" ] \
    && [ "$current_token" = "$seed_token" ] \
    || fail "prefix preflight does not verify the exact generation recorded by core"
ok "FRESH-SEED/NO-IMPLICIT-PREFS: install seeds 128 and does not persist environment"

# EXPLICIT-COMMIT/DPI-CORE: every explicit choice is committed after a
# successful core; DPI is also available to prefix setup immediately.
base="$(new_case explicit-commit)"
run_public "$base" ABLETON_TEST_ASSERT_SETTINGS_BEFORE_CORE=1 -- \
    install --skip-live-install --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
    --audio-buffer=512 --shortcuts=preserve --dpi=fractional \
    --audio-threads=16 --rt=off --power=balanced \
    >"$base/out" 2>"$base/err" || fail "explicit setting install fails"
grep -qxF 'buffer_size = 512' "$base/config/pipeasio/config.ini" \
    || fail "explicit fresh buffer is not seeded transactionally"
cat > "$base/preferences.expected" <<'EOF'
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=preserve
dpi=fractional
audio_threads=16
rt=off
power=balanced
EOF
cmp -s -- "$base/preferences.expected" "$base/config/ableton-wine/preferences" \
    || fail "explicit launcher choices are not saved exactly"
[ "$(stat -c '%a' "$base/config/ableton-wine/preferences")" = 600 ] \
    || fail "committed launcher preferences are not private"
if ! grep -Eq 'prefix args=.*--validate.* seed=512 dpi=fractional' "$base/calls.log" \
   || ! grep -Eq 'prefix args=.*--transaction-dir.* seed=512 dpi=fractional' "$base/calls.log"; then
    fail "buffer and DPI choices do not reach validation and core prefix setup"
fi
ok "EXPLICIT-COMMIT/DPI-CORE: successful core commits exact choices and applies DPI immediately"

# INTENT-ORIGIN: environment values are one-run launcher overrides, not write
# intent. With no prior store, one CLI choice overlays compatibility defaults;
# unrelated environment values never leak into the new persistent record.
base="$(new_case intent-origin-absent)"
run_public "$base" ABLETON_SHORTCUTS=preserve ABLETON_DPI_MODE=preserve \
    ABLETON_MAX_AUDIO_THREADS=off ABLETON_RT=auto ABLETON_POWER=balanced -- \
    install --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --rt=off >"$base/out" 2>"$base/err" \
    || fail "one explicit choice with environment overrides fails"
cat > "$base/intent.expected" <<'EOF'
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=take
dpi=auto
audio_threads=auto
rt=off
power=performance
EOF
cmp -s -- "$base/intent.expected" "$base/config/ableton-wine/preferences" \
    || fail "environment overrides leak into an absent-store CLI merge"
ok "INTENT-ORIGIN: only explicit CLI intent overlays persistent defaults"

# MERGE: one explicit choice updates only that field and preserves all saved
# values that the user did not edit.
base="$(new_case merge)"
make_update_state "$base"
mkdir -p -- "$base/config/pipeasio"
printf '[pipeasio]\nbuffer_size = 2048\n' > "$base/config/pipeasio/config.ini"
write_preferences "$base" preserve preserve off off balanced
expected_preferences_sha="$(sha256sum "$base/config/ableton-wine/preferences" | awk '{print $1}')"
expected_buffer_sha="$(sha256sum "$base/config/pipeasio/config.ini" | awk '{print $1}')"
run_public "$base" ABLETON_SHORTCUTS=take ABLETON_DPI_MODE=auto \
    ABLETON_MAX_AUDIO_THREADS=12 ABLETON_RT=auto ABLETON_POWER=off \
    "ABLETON_TEST_EXPECT_PREFERENCES_SHA=$expected_preferences_sha" \
    "ABLETON_TEST_EXPECT_BUFFER_SHA=$expected_buffer_sha" -- \
    update --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --power=performance \
    >"$base/out" 2>"$base/err" || fail "single-field preference update fails"
cat > "$base/merge.expected" <<'EOF'
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=preserve
dpi=preserve
audio_threads=off
rt=off
power=performance
EOF
cmp -s -- "$base/merge.expected" "$base/config/ableton-wine/preferences" \
    || fail "saved merge resets fields, adds data, or persists environment overrides"
grep -qxF 'buffer_size = 2048' "$base/config/pipeasio/config.ini" \
    || fail "a preference-only update rewrites a custom audio buffer"
before="$(sha256sum "$base/config/ableton-wine/preferences")"
run_public "$base" ABLETON_SHORTCUTS=take ABLETON_DPI_MODE=auto \
    ABLETON_MAX_AUDIO_THREADS=12 ABLETON_RT=auto ABLETON_POWER=off -- \
    update --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" \
    --yes >"$base/no-intent.out" 2>"$base/no-intent.err" \
    || fail "no-intent update with environment overrides fails"
[ "$(sha256sum "$base/config/ableton-wine/preferences")" = "$before" ] \
    || fail "no-flag update rewrites existing preferences from the environment"
ok "MERGE: explicit intent changes one field without synthesising unrelated writes"

# EXISTING-BUFFER/RACE: an explicit update patches a stable unique object only
# after core commit; a concurrent change is retained and reported.
base="$(new_case existing-buffer)"
make_update_state "$base"
mkdir -p -- "$base/config/pipeasio"
printf '; keep\n[pipeasio]\nbuffer_size = 2048\noutputs = 4\n' \
    > "$base/config/pipeasio/config.ini"
run_public "$base" -- update --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --audio-buffer=256 \
    >"$base/out" 2>"$base/err" || fail "stable existing buffer update fails"
printf '; keep\n[pipeasio]\nbuffer_size = 256\noutputs = 4\n' \
    > "$base/existing-buffer.expected"
cmp -s -- "$base/existing-buffer.expected" "$base/config/pipeasio/config.ini" \
    || fail "post-core buffer patch changes bytes beyond the selected value"

base="$(new_case raced-buffer)"
make_update_state "$base"
mkdir -p -- "$base/config/pipeasio"
printf '[pipeasio]\nbuffer_size = 2048\n' > "$base/config/pipeasio/config.ini"
run_public "$base" ABLETON_TEST_RACE_BUFFER=1 -- update --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
    --audio-buffer=128 --power=balanced >"$base/out" 2>"$base/err" \
    || fail "a raced optional buffer turns a committed update into failure"
if ! grep -qxF 'buffer_size = 2048' "$base/config/pipeasio/config.ini" \
   || ! grep -qxF 'outputs = 7' "$base/config/pipeasio/config.ini"; then
    fail "concurrent PipeASIO change is overwritten"
fi
grep -qi 'audio buffer.*changed' "$base/err" \
    || fail "retained concurrent buffer change is not explained"
grep -qxF 'power=balanced' "$base/config/ableton-wine/preferences" \
    || fail "a raced audio buffer blocks independent launcher preferences"

base="$(new_case raced-valid-preferences)"
make_update_state "$base"
write_preferences "$base" take auto auto auto performance
run_public "$base" ABLETON_TEST_RACE_PREFERENCES=replace -- update --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
    --power=balanced >"$base/out" 2>"$base/err" \
    || fail "a valid preference race turns a committed update into failure"
if ! grep -qxF 'dpi=100' "$base/config/ableton-wine/preferences" \
   || ! grep -qxF 'power=off' "$base/config/ableton-wine/preferences"; then
    fail "a valid preference record changed during core is overwritten"
fi
grep -qi 'preferences.*changed\|settings.*changed' "$base/err" \
    || fail "retained valid preference race is not explained"

base="$(new_case raced-absent-preferences)"
run_public "$base" ABLETON_TEST_RACE_PREFERENCES=create -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --power=balanced \
    >"$base/out" 2>"$base/err" \
    || fail "a preference created during core turns install into failure"
if ! grep -qxF 'dpi=100' "$base/config/ableton-wine/preferences" \
   || ! grep -qxF 'power=off' "$base/config/ableton-wine/preferences"; then
    fail "a preference created during core is overwritten"
fi
grep -qi 'preferences.*changed\|settings.*changed' "$base/err" \
    || fail "retained absent-to-present preference race is not explained"
ok "EXISTING-BUFFER/RACE: stable data patches post-core and concurrent edits are retained"

# CORE-FAIL/POSTCORE-FAIL: no mutable setting commits before core success.
# Conversely a preference publication failure after core never rolls Ableton
# back and produces one actionable warning.
base="$(new_case core-failure)"
make_update_state "$base"
mkdir -p -- "$base/config/pipeasio"
printf '[pipeasio]\nbuffer_size = 2048\n' > "$base/config/pipeasio/config.ini"
write_preferences "$base" take auto auto auto performance
before_buffer="$(sha256sum "$base/config/pipeasio/config.ini")"
before_preferences="$(sha256sum "$base/config/ableton-wine/preferences")"
if run_public "$base" ABLETON_TEST_PREFIX_CORE_EXIT=79 -- update --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
    --audio-buffer=512 --power=balanced >"$base/out" 2>"$base/err"; then
    fail "a failed core update succeeds"
fi
[ "$(sha256sum "$base/config/pipeasio/config.ini")" = "$before_buffer" ] \
    && [ "$(sha256sum "$base/config/ableton-wine/preferences")" = "$before_preferences" ] \
    || fail "core failure commits pre-flight settings"

base="$(new_case component-core-failure)"
make_update_state "$base"
mkdir -p -- "$base/config/pipeasio"
printf '[pipeasio]\nbuffer_size = 2048\n' > "$base/config/pipeasio/config.ini"
write_preferences "$base" take auto auto auto performance
before_buffer="$(sha256sum "$base/config/pipeasio/config.ini")"
before_preferences="$(sha256sum "$base/config/ableton-wine/preferences")"
if run_public "$base" ABLETON_TEST_COMPONENT_CORE_EXIT=78 -- update --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
    --audio-buffer=512 --power=balanced >"$base/out" 2>"$base/err"; then
    fail "a failed runtime component update succeeds"
fi
[ "$(sha256sum "$base/config/pipeasio/config.ini")" = "$before_buffer" ] \
    && [ "$(sha256sum "$base/config/ableton-wine/preferences")" = "$before_preferences" ] \
    || fail "runtime component failure commits pre-flight settings"

base="$(new_case fresh-core-failure)"
if run_public "$base" ABLETON_TEST_PREFIX_CORE_EXIT=79 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --audio-buffer=512 --power=balanced \
    >"$base/out" 2>"$base/err"; then
    fail "a failed fresh core install succeeds"
fi
[ ! -e "$base/config/pipeasio/config.ini" ] \
    && [ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "fresh core failure creates pre-flight settings"

base="$(new_case failure-after-fresh-seed)"
if run_public "$base" ABLETON_TEST_PREFIX_FAIL_AFTER_SEED=79 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --audio-buffer=512 --power=balanced \
    >"$base/out" 2>"$base/err"; then
    fail "a prefix failure after publishing its fresh seed succeeds"
fi
[ ! -e "$base/config/pipeasio/config.ini" ] \
    && [ ! -L "$base/config/pipeasio/config.ini" ] \
    && [ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "failure after seed publication retains uncommitted settings"

base="$(new_case provisional-commit-boundary)"
if run_public "$base" ABLETON_TEST_SKIP_SEED_PROMOTION=1 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --audio-buffer=512 --power=balanced \
    >"$base/out" 2>"$base/err"; then
    fail "coordinator commit accepts rollback-only provisional seed provenance"
fi
[ ! -e "$base/config/pipeasio/config.ini" ] \
    && [ ! -L "$base/config/pipeasio/config.ini" ] \
    && ! find "$base/config/pipeasio" -maxdepth 1 -name '.config.ini.*' \
        -print -quit 2>/dev/null | grep -q . \
    && [ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "provisional commit rejection leaves seed, temp, or launcher settings"
grep -q 'component args=--preflight-commit ' "$base/calls.log" \
    && grep -q 'prefix args=--preflight-commit ' "$base/calls.log" \
    && grep -q 'prefix args=--preflight-rollback ' "$base/calls.log" \
    && grep -q 'component args=--preflight-rollback ' "$base/calls.log" \
    && grep -q 'prefix args=--rollback ' "$base/calls.log" \
    && grep -q 'component args=--rollback ' "$base/calls.log" \
    || fail "provisional commit rejection does not preflight and roll back both domains"
! grep -Eq '^(prefix|component) args=--commit ' "$base/calls.log" \
    || fail "a domain commit ran after provisional seed rejection"

base="$(new_case malformed-seed-outer-rollback)"
if run_public "$base" ABLETON_TEST_MALFORMED_SEED_JOURNAL=1 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --audio-buffer=512 --power=balanced \
    >"$base/out" 2>"$base/err"; then
    fail "coordinator accepts malformed canonical seed recovery evidence"
fi
journal="$(find "$base/state" -type f -name pipeasio-seed.v1 -print -quit)"
active="$(find "$base/state" -type f -name active -print -quit)"
recorded_buffer_object="$(sed -n 's/^prefix malformed-buffer-object=//p' \
    "$base/calls.log" | tail -n 1)"
recorded_journal_object="$(sed -n 's/^prefix malformed-journal-object=//p' \
    "$base/calls.log" | tail -n 1)"
recorded_active_object="$(sed -n 's/^prefix malformed-active-object=//p' \
    "$base/calls.log" | tail -n 1)"
[ -n "$journal" ] && [ -n "$active" ] \
    && grep -qxF 'buffer_size = 512' "$base/config/pipeasio/config.ini" \
    && grep -qxF 'active recovery evidence' "$active" \
    && [ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "malformed recovery preflight discards journal, active evidence, or settings"
[ "$(ableton_preferences_object_token "$base/config/pipeasio/config.ini")" \
      = "$recorded_buffer_object" ] \
    && [ "$(ableton_preferences_object_token "$journal")" \
         = "$recorded_journal_object" ] \
    && [ "$(ableton_preferences_object_token "$active")" \
         = "$recorded_active_object" ] \
    || fail "malformed outer rollback changes recovery evidence or settings in place"
[ "$(sed -n 's/^token_b64=//p' "$journal" | base64 --decode)" = 'file|garbage' ] \
    || fail "malformed recovery evidence was rewritten"
grep -q 'prefix args=--preflight-rollback ' "$base/calls.log" \
    && grep -q 'component args=--preflight-rollback ' "$base/calls.log" \
    || fail "one malformed domain prevents the other rollback preflight"
! grep -Eq '^(prefix|component) args=--rollback ' "$base/calls.log" \
    || fail "a rollback domain mutated after malformed recovery preflight"
! grep -Eq '^(prefix|component) args=--commit ' "$base/calls.log" \
    || fail "a domain commit ran with malformed recovery evidence"

base="$(new_case second-domain-rollback-preflight-failure)"
if run_public "$base" ABLETON_TEST_CAPTURE_RECOVERY_OBJECTS=1 \
    ABLETON_TEST_PREFIX_FAIL_AFTER_SEED=79 \
    ABLETON_TEST_COMPONENT_ROLLBACK_PREFLIGHT_EXIT=88 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --audio-buffer=512 --power=balanced \
    >"$base/out" 2>"$base/err"; then
    fail "coordinator accepts a second-domain rollback-preflight failure"
fi
journal="$(find "$base/state" -type f -name pipeasio-seed.v1 -print -quit)"
active="$(find "$base/state" -type f -name active -print -quit)"
recorded_buffer_object="$(sed -n 's/^prefix captured-buffer-object=//p' \
    "$base/calls.log" | tail -n 1)"
recorded_journal_object="$(sed -n 's/^prefix captured-journal-object=//p' \
    "$base/calls.log" | tail -n 1)"
recorded_active_object="$(sed -n 's/^prefix captured-active-object=//p' \
    "$base/calls.log" | tail -n 1)"
recorded_prefix_object="$(sed -n 's/^prefix captured-prefix-object=//p' \
    "$base/calls.log" | tail -n 1)"
[ -n "$journal" ] && [ -n "$active" ] \
    && [ "$(ableton_preferences_object_token "$base/config/pipeasio/config.ini")" \
         = "$recorded_buffer_object" ] \
    && [ "$(ableton_preferences_object_token "$journal")" \
         = "$recorded_journal_object" ] \
    && [ "$(ableton_preferences_object_token "$active")" \
         = "$recorded_active_object" ] \
    && [ "$(ableton_preferences_object_token "$base/prefix/system.reg")" \
         = "$recorded_prefix_object" ] \
    && [ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "second-domain preflight failure changes prefix or settings recovery evidence"
prefix_preflight_line="$(grep -n 'prefix args=--preflight-rollback ' \
    "$base/calls.log" | tail -n 1 | cut -d: -f1)"
component_preflight_line="$(grep -n 'component args=--preflight-rollback ' \
    "$base/calls.log" | tail -n 1 | cut -d: -f1)"
[ -n "$prefix_preflight_line" ] && [ -n "$component_preflight_line" ] \
    && [ "$prefix_preflight_line" -lt "$component_preflight_line" ] \
    || fail "rollback domains are not fully preflighted in order"
! grep -Eq '^(prefix|component) args=--rollback ' "$base/calls.log" \
    || fail "a rollback domain mutated before every preflight succeeded"
! grep -Eq '^(prefix|component) args=--commit ' "$base/calls.log" \
    || fail "a domain commit ran after a rollback-preflight failure"

base="$(new_case replacement-before-seed-token)"
if run_public "$base" ABLETON_TEST_REPLACE_SEED_BEFORE_TOKEN=1 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --audio-buffer=512 --power=balanced \
    >"$base/out" 2>"$base/err"; then
    fail "a seed replaced before full-token capture succeeds as installer-owned"
fi
replacement_token="$(sed -n 's/^prefix pre-token-replacement-token=//p' \
    "$base/calls.log" | tail -n 1)"
[ -n "$replacement_token" ] \
    && grep -qxF 'buffer_size = 512' "$base/config/pipeasio/config.ini" \
    && [ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "pre-token same-value replacement is deleted or settings are committed"

base="$(new_case same-value-seed-replacement)"
if run_public "$base" ABLETON_TEST_REPLACE_SEED_SAME_VALUE=1 \
    ABLETON_TEST_PREFIX_PREFLIGHT_EXIT=76 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --audio-buffer=512 --power=balanced \
    >"$base/out" 2>"$base/err"; then
    fail "a forced preflight failure after same-value replacement succeeds"
fi
seed_token="$(sed -n 's/^prefix seed-token=//p' "$base/calls.log" | tail -n 1)"
replacement_token="$(sed -n 's/^prefix replacement-token=//p' "$base/calls.log" | tail -n 1)"
recorded_token="$(sed -n 's/^prefix preflight recorded-token=//p' "$base/calls.log" | tail -n 1)"
current_token="$(sed -n 's/^prefix preflight current-token=//p' "$base/calls.log" | tail -n 1)"
[ -n "$seed_token" ] && [ -n "$replacement_token" ] \
    && [ "$seed_token" != "$replacement_token" ] \
    && [ "$recorded_token" = "$seed_token" ] \
    && [ "$current_token" = "$replacement_token" ] \
    || fail "same-value fixture does not prove distinct recorded/current generations"
grep -qxF 'buffer_size = 512' "$base/config/pipeasio/config.ini" \
    || fail "rollback deletes a byte-identical user replacement"
[ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "failed same-value replacement case commits launcher preferences"

for preflight_owner in component prefix; do
    base="$(new_case "$preflight_owner-preflight-failure")"
    preflight_env=()
    case "$preflight_owner" in
        component) preflight_env=(ABLETON_TEST_COMPONENT_PREFLIGHT_EXIT=77) ;;
        prefix) preflight_env=(ABLETON_TEST_PREFIX_PREFLIGHT_EXIT=76) ;;
    esac
    if run_public "$base" "${preflight_env[@]}" -- install \
        --skip-live-install --link=off --runtime-root "$base/runtime" \
        --prefix "$base/prefix" --yes --audio-buffer=512 --power=balanced \
        >"$base/out" 2>"$base/err"; then
        fail "$preflight_owner preflight-commit failure succeeds"
    fi
    [ ! -e "$base/config/pipeasio/config.ini" ] \
        && [ ! -e "$base/config/ableton-wine/preferences" ] \
        || fail "$preflight_owner preflight-commit failure retains uncommitted settings"
done

base="$(new_case preference-publication-failure)"
mkdir -p -- "$base/config/ableton-wine/preferences"
run_public "$base" -- install --skip-live-install --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
    --audio-buffer=512 --power=balanced >"$base/out" 2>"$base/err" \
    || fail "optional preference publication failure rejects a committed core"
[ -f "$base/prefix/system.reg" ] \
    || fail "preference publication failure rolls back the usable prefix"
[ -d "$base/config/ableton-wine/preferences" ] \
    || fail "unsafe preference destination is replaced"
grep -qi 'preferences.*could not be saved\|settings.*could not be saved' "$base/err" \
    || fail "preference publication failure has no repair warning"
grep -qxF 'buffer_size = 512' "$base/config/pipeasio/config.ini" \
    || fail "preference publication failure blocks an independent audio-buffer commit"

base="$(new_case component-commit-failure)"
run_public "$base" ABLETON_TEST_COMPONENT_COMMIT_EXIT=77 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --power=balanced \
    >"$base/out" 2>"$base/err" \
    || fail "component cleanup/commit failure rejects an already committed core"
if [ ! -f "$base/prefix/system.reg" ] \
   || ! grep -qxF 'power=balanced' "$base/config/ableton-wine/preferences"; then
    fail "component cleanup/commit failure prevents post-core settings"
fi
ok "CORE-FAIL/POSTCORE-FAIL: writes wait for core and later failures keep usable Ableton"

# MALFORMED-PRESERVE/INTEGRATION-FAIL: foreign or malformed mutable data is
# never guessed at. Optional launcher-support failure also cannot roll core.
base="$(new_case malformed-preferences)"
mkdir -p -- "$base/config/ableton-wine"
printf 'format=1\npower=balanced\nunknown=value\n' \
    > "$base/config/ableton-wine/preferences"
before="$(sha256sum "$base/config/ableton-wine/preferences")"
run_public "$base" -- install --skip-live-install --link=off \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
    --audio-buffer=512 --power=performance >"$base/out" 2>"$base/err" \
    || fail "malformed optional preferences reject a committed install"
[ "$(sha256sum "$base/config/ableton-wine/preferences")" = "$before" ] \
    || fail "malformed preferences are overwritten"
grep -qi 'preferences.*malformed\|preferences.*not.*saved' "$base/err" \
    || fail "preserved malformed preferences are not explained"
grep -qxF 'buffer_size = 512' "$base/config/pipeasio/config.ini" \
    || fail "malformed preferences block an independent audio-buffer commit"

base="$(new_case integration-failure)"
run_public "$base" ABLETON_TEST_INTEGRATION_EXIT=3 -- install \
    --skip-live-install --link=off --runtime-root "$base/runtime" \
    --prefix "$base/prefix" --yes --rt=off >"$base/out" 2>"$base/err" \
    || fail "optional launcher support failure rejects a committed install"
if [ ! -f "$base/prefix/system.reg" ] \
   || grep -q -- '--rollback' "$base/calls.log"; then
    fail "optional support failure rolls back core"
fi
grep -qxF 'rt=off' "$base/config/ableton-wine/preferences" \
    || fail "optional support failure blocks independent RT preference publication"
base="$(new_case link-failure)"
run_public "$base" ABLETON_TEST_LINK_EXIT=76 -- install --skip-live-install \
    --link=session --runtime-root "$base/runtime" --prefix "$base/prefix" \
    --yes --power=balanced >"$base/out" 2>"$base/err" \
    || fail "optional Link failure rejects a committed install"
if [ ! -f "$base/prefix/system.reg" ] \
   || ! grep -qxF 'power=balanced' "$base/config/ableton-wine/preferences" \
   || grep -q -- '--rollback' "$base/calls.log"; then
    fail "optional Link failure rolls back core or blocks independent preferences"
fi
ok "MALFORMED-PRESERVE/INTEGRATION-FAIL: unsafe data is kept and optional support cannot roll back core"

# STANDALONE-SEED: direct prefix creation is not silently redesigned by the
# coordinator questionnaire. Its historical 256 seed remains in force.
base="$(new_case standalone-prefix)"
run_public "$base" -- prefix create --runtime-root "$base/runtime" \
    --prefix "$base/prefix" >"$base/out" 2>"$base/err" \
    || fail "standalone prefix create fails"
grep -qxF 'buffer_size = 256' "$base/config/pipeasio/config.ini" \
    || fail "standalone prefix creation no longer retains its 256 default"
grep -q 'seed=unset' "$base/calls.log" \
    || fail "coordinator-only buffer seed leaked into prefix create"
ok "STANDALONE-SEED: direct prefix creation remains 256 unless coordinated"

# LAUNCHER-CONSUMERS: both launchers load the optional store before consuming
# the five settings, but do not turn absence of that optional library into a
# hard support-file failure. Profile selection must use the validated value.
for launcher in ableton-live max9; do
    file="$here/$launcher"
    if ! grep -qF 'preferences.sh' "$file" \
       || ! grep -qF 'ableton_preferences_apply' "$file"; then
        fail "$launcher does not consume saved pre-flight preferences"
    fi
    ! grep -E 'declare -F ableton_preferences_apply.*exit|preferences.*incomplete.*exit' "$file" \
        >/dev/null || fail "$launcher makes the optional preference library mandatory"
    apply_line="$(grep -n -m1 'ableton_preferences_apply' "$file" | cut -d: -f1)"
    consume_line="$(grep -n -m1 'ABLETON_MAX_AUDIO_THREADS:-\|ABLETON_RT:-\|ABLETON_POWER:-' "$file" | cut -d: -f1)"
    [ "$apply_line" -lt "$consume_line" ] \
        || fail "$launcher applies saved preferences after consuming launcher settings"
    grep -q 'powerprofilesctl launch -p .*power' "$file" \
        || fail "$launcher hard-codes performance instead of using the validated profile"
done
ok "LAUNCHER-CONSUMERS: Live and Max apply optional preferences early and use selected power profiles"

# UNINSTALL/PACKAGING: mutable preferences use their own checked removal, while
# preferences.sh is ordinary authoritative support everywhere the kit/runtime
# can be assembled or audited. Exercise the packer's project-file stage rather
# than accepting a filename in a comment or dead allowlist.
grep -qF 'ableton_preferences_remove' "$here/uninstall.sh" \
    || fail "uninstall does not generation-check mutable preferences"
for file in "$here/install.sh" "$here/uninstall.sh" "$here/lib/manifest.sh"; do
    grep -qF 'preferences.sh' "$file" \
        || fail "packaging/ownership surface omits preferences.sh: ${file#"$root"/}"
done
project_stage="$work/project-stage"
"$here/make-installer.sh" --stage-project-files "$project_stage" \
    >"$work/project-stage.out" 2>"$work/project-stage.err" \
    || fail "the packer's isolated project-file stage fails"
staged_preferences="$project_stage/scripts/lib/preferences.sh"
if [ ! -f "$staged_preferences" ] || [ -x "$staged_preferences" ] \
   || ! cmp -s -- "$here/lib/preferences.sh" "$staged_preferences"; then
    fail "the .run project stage omits or changes preferences.sh"
fi
[ "$(stat -c '%a' "$staged_preferences")" = 644 ] \
    || fail "the .run project stage gives preferences.sh the wrong mode"
"$here/make-installer.sh" --audit-project-files "$project_stage" \
    >"$work/project-audit.out" 2>"$work/project-audit.err" \
    || fail "the packer's normal project-file audit rejects its own stage"
cp -- "$staged_preferences" "$work/staged-preferences.before"
printf 'corrupt staged preference helper\n' > "$staged_preferences"
if "$here/make-installer.sh" --audit-project-files "$project_stage" \
    >"$work/corrupt-audit.out" 2>"$work/corrupt-audit.err"; then
    fail "the packer's project-file audit accepts a corrupted preferences.sh"
fi
cp -- "$work/staged-preferences.before" "$staged_preferences"
python3 - "$here/make-installer.sh" <<'PY' \
    || fail "normal .run packing does not share its exercised project stage and audit"
from pathlib import Path
import re
import sys

text = "\n".join(
    line for line in Path(sys.argv[1]).read_text().splitlines()
    if not line.lstrip().startswith("#")
)
assert len(re.findall(r"^stage_project_files\(\)$", text, re.M)) == 1
assert len(re.findall(r"^audit_project_files\(\)$", text, re.M)) == 1
assert re.search(r'^stage_project_files "\$kit"$', text, re.M)
assert re.search(r'^audit_project_files "\$kit"$', text, re.M)
PY
python3 - "$root" <<'PY' \
    || fail "payload verifier does not include preferences.sh as mode 0644"
from pathlib import Path
from types import SimpleNamespace
import runpy
import sys

root = Path(sys.argv[1])
module = runpy.run_path(str(root / "scripts/verify-installer-payload.py"))
globals_ = module["expected_from_source"].__globals__
real_add_source = globals_["add_source"]
globals_["add_source"] = lambda expected, source, destination, mode: (
    real_add_source(expected, source, destination, mode)
    if destination == "scripts/lib/preferences.sh"
    else None
)
globals_["tracked_paths"] = lambda *args: []
globals_["subprocess"].run = lambda *args, **kwargs: SimpleNamespace(stdout=b"")
expected = module["expected_from_source"](root, root / "BUILD-INFO", root / "runtime.tar.zst")
entry = expected["scripts/lib/preferences.sh"]
assert entry.kind == "file"
assert entry.mode == 0o644
assert entry.data == (root / "scripts/lib/preferences.sh").read_bytes()
PY
python3 - "$root/nix/ableton-wine.nix" <<'PY' \
    || fail "Nix does not source-stage and exact-audit every helper in both launcher locations"
from pathlib import Path
import re
import sys

text = "\n".join(
    line for line in Path(sys.argv[1]).read_text().splitlines()
    if not line.lstrip().startswith("#")
)
stage_loops = re.findall(
    r"for helper in \$\{\.\./scripts/lib\}/\*\.sh; do\s+"
    r"install -m644 \$helper \$out/(libexec/lib|share/ableton-wine/scripts/lib)/\$\(basename \$helper\)\s+done",
    text,
)
assert sorted(stage_loops) == ["libexec/lib", "share/ableton-wine/scripts/lib"]
audit = re.search(
    r"for helper in \$\{\.\./scripts/lib\}/\*\.sh; do\s+"
    r"for d in libexec/lib share/ableton-wine/scripts/lib; do(?P<body>.*?)done\s+done",
    text,
    re.S,
)
assert audit is not None
body = audit.group("body")
assert "cmp -s -- \"$helper\" \"$out/$d/$(basename \"$helper\")\"" in body
PY
ok "UNINSTALL/PACKAGING: mutable data is checked separately and support ships on every path"

# DOCS: user-facing command documentation names every flag, its values, the
# confirmed 128 default, persistence, and Escape navigation.
for flag in audio-buffer shortcuts dpi audio-threads rt power; do
    rg -q -- "--$flag" "$root/INSTALLER.md" "$root/README.md" \
        || fail "documentation omits --$flag"
done
for allowed_values in \
    '64.*128.*256.*512.*1024' \
    'take.*preserve|Assign to Live.*Preserve' \
    'auto.*100.*fractional.*preserve|Automatic.*100%.*Fractional.*Preserve' \
    'auto.*off.*1.*63|Automatic.*Let Live decide.*1.*63' \
    'rt.*auto.*off|Real-time.*Automatic.*Normal' \
    'power.*performance.*balanced.*off|Power.*Performance.*Balanced.*change'; do
    rg -qi "$allowed_values" "$root/INSTALLER.md" "$root/README.md" \
        || fail "documentation omits allowed values matching: $allowed_values"
done
rg -qi '128.*default|default.*128' "$root/INSTALLER.md" "$root/README.md" \
    || fail "documentation omits the 128-frame default"
rg -qi 'Esc.*back|back.*Esc' "$root/INSTALLER.md" "$root/README.md" \
    || fail "documentation omits one-question Escape navigation"
rg -qi 'preferences.*persistent|persistent.*preferences' \
    "$root/INSTALLER.md" "$root/README.md" \
    || fail "documentation omits launcher preference persistence"
ok "DOCS: installer flags, defaults, navigation and persistence are documented"

printf '%s pre-flight integration checks passed\n' "$pass"
