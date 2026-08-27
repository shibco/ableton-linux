#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-config-boundary-test.XXXXXX")"
cleanup()
{
    case "${work:-}" in
        "${TMPDIR:-/tmp}"/ableton-config-boundary-test.*) rm -rf -- "$work" ;;
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

new_env()
{
    local base="$work/$1"
    mkdir -p -- "$base/home" "$base/tmp"
    printf '%s\n' "$base"
}

run_isolated()
{
    local base="$1"
    shift
    env -u ABLETON_WINE_ROOT -u ABLETON_WINEPREFIX \
        -u ABLETON_DATA_HOME -u ABLETON_CONFIG_HOME \
        -u ABLETON_CONFIG_FILE -u ABLETON_STATE_HOME \
        -u ABLETON_CACHE_HOME -u ABLETON_BIN_HOME \
        -u ABLETON_LINKD -u ABLETON_LINK_MODE \
        -u ABLETON_CONFIG_LAYOUT_ROOTS -u ABLETON_CONFIG_REPAIR_MODE \
        -u ABLETON_CONFIG_REPAIR_NEEDED \
        -u ABLETON_CONFIG_SNAPSHOT_PATH -u ABLETON_CONFIG_SNAPSHOT_TOKEN \
        -u ABLETON_CONFIG_SNAPSHOT_VALUES \
        HOME="$base/home" XDG_CONFIG_HOME="$base/config" \
        XDG_DATA_HOME="$base/data" XDG_STATE_HOME="$base/state" \
        XDG_CACHE_HOME="$base/cache" XDG_RUNTIME_DIR="$base/run" \
        TMPDIR="$base/tmp" PATH=/usr/bin:/bin "$@"
}

# The three exported snapshot fields are one record. A partial inherited record
# must be replaced, and verification must remain safe under set -u when any
# individual field is later missing.
base="$(new_env partial-snapshot)"
run_isolated "$base" env \
    ABLETON_CONFIG_SNAPSHOT_PATH="$base/config/ableton-wine/config" \
    bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ABLETON_CONFIG_LAYOUT_ROOTS=none
        export ABLETON_CONFIG_LAYOUT_ROOTS
        ableton_config_init repair
        [ -n "$ABLETON_CONFIG_SNAPSHOT_PATH" ]
        [ -n "$ABLETON_CONFIG_SNAPSHOT_TOKEN" ]
        [ -n "$ABLETON_CONFIG_SNAPSHOT_VALUES" ]
        ableton_config_snapshot_verify

        saved_path="$ABLETON_CONFIG_SNAPSHOT_PATH"
        saved_token="$ABLETON_CONFIG_SNAPSHOT_TOKEN"
        saved_values="$ABLETON_CONFIG_SNAPSHOT_VALUES"
        unset ABLETON_CONFIG_SNAPSHOT_PATH
        ! ableton_config_snapshot_verify
        ABLETON_CONFIG_SNAPSHOT_PATH="$saved_path"
        export ABLETON_CONFIG_SNAPSHOT_PATH
        unset ABLETON_CONFIG_SNAPSHOT_TOKEN
        ! ableton_config_snapshot_verify
        ABLETON_CONFIG_SNAPSHOT_TOKEN="$saved_token"
        export ABLETON_CONFIG_SNAPSHOT_TOKEN
        unset ABLETON_CONFIG_SNAPSHOT_VALUES
        ! ableton_config_snapshot_verify
        ABLETON_CONFIG_SNAPSHOT_VALUES="$saved_values"
        export ABLETON_CONFIG_SNAPSHOT_VALUES
        ableton_config_snapshot_verify

        ableton_config_object_token() { return 1; }
        ! ableton_config_snapshot_capture
        [ "$ABLETON_CONFIG_SNAPSHOT_PATH" = "$saved_path" ]
        [ "$ABLETON_CONFIG_SNAPSHOT_TOKEN" = "$saved_token" ]
        [ "$ABLETON_CONFIG_SNAPSHOT_VALUES" = "$saved_values" ]
    ' _ "$here" || fail "partial installer-settings snapshot was accepted or caused an unbound-variable exit"
ok "installer-settings snapshots are complete records under set -u"

# Once a caller intentionally enters repair mode, the state marker and settings
# writer must not re-enter strict mode and reject the same repairable generation.
base="$(new_env repair-reentry)"
config="$base/config/ableton-wine/config"
mkdir -p -- "$(dirname "$config")"
printf '# ableton-linux installer configuration; managed by the installer\nformat=1\nruntime_root=%s\nprefix=%s\nlive_major=12\nlink_mode=off\nlinkd=%s\nobsolete_field=remove-me\n' \
    "$base/runtime" "$base/prefix" "$base/data/ableton-wine/ableton-linkd" \
    > "$config"
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ABLETON_CONFIG_LAYOUT_ROOTS=none
    export ABLETON_CONFIG_LAYOUT_ROOTS
    ableton_config_init repair
    [ "$ABLETON_CONFIG_REPAIR_NEEDED" -eq 1 ]
    ableton_mark_state_home
    ableton_write_config
    [ "$ABLETON_CONFIG_REPAIR_NEEDED" -eq 0 ]
    ableton_managed_config_valid "$ABLETON_CONFIG_FILE"
    [ -f "$ABLETON_STATE_HOME/.ableton-linux-state" ]
' _ "$here" || fail "repair mode was re-gated by a generated malformed settings file"
if grep -q '^obsolete_field=' "$config"; then
    fail "repair-mode settings rewrite retained an obsolete generated field"
fi
ok "state and settings writers preserve an established repair mode"

# Initial command scopes may deliberately omit settings. The writer itself must
# still reject both its temporary directory and a custom final file under Wine.
for overlap_kind in config-home custom-file; do
    base="$(new_env "settings-overlap-$overlap_kind")"
    mkdir -p -- "$base/runtime" "$base/settings"
    case "$overlap_kind" in
        config-home)
            config_home="$base/runtime"
            config_file="$base/runtime/config" ;;
        custom-file)
            config_home="$base/settings"
            config_file="$base/runtime/installer-config" ;;
    esac
    if run_isolated "$base" env \
        ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_CONFIG_HOME="$config_home" \
        ABLETON_CONFIG_FILE="$config_file" \
        bash -c '
            set -euo pipefail
            . "$1/lib/config.sh"
            ABLETON_CONFIG_LAYOUT_ROOTS=none
            export ABLETON_CONFIG_LAYOUT_ROOTS
            ableton_config_init repair
            ableton_write_config
        ' _ "$here" > "$base/out" 2> "$base/err"; then
        fail "$overlap_kind settings destination was written under the Wine runtime"
    fi
    [ ! -e "$config_file" ] && [ ! -L "$config_file" ] \
        || fail "$overlap_kind settings refusal changed the Wine runtime"
done
ok "settings writes enforce their concrete layout at point of use"

# A stale regular transactions child is project-owned after the exact state
# marker is verified. Replace it, while refusing a child symlink or unmarked
# state without touching either foreign object.
base="$(new_env transaction-child)"
state="$base/state/ableton-wine"
mkdir -p -- "$state"
printf 'format=1\nowner=ableton-linux\n' > "$state/.ableton-linux-state"
printf 'stale project work file\n' > "$state/transactions"
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ABLETON_CONFIG_LAYOUT_ROOTS=none
    export ABLETON_CONFIG_LAYOUT_ROOTS
    ableton_config_init repair
    ableton_prepare_transactions_dir
    [ -d "$ABLETON_STATE_HOME/transactions" ]
    [ ! -L "$ABLETON_STATE_HOME/transactions" ]
' _ "$here" || fail "owned stale transaction file was not repaired"

rmdir -- "$state/transactions"
printf 'foreign transaction target\n' > "$base/foreign-transactions"
ln -s -- "$base/foreign-transactions" "$state/transactions"
if run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ABLETON_CONFIG_LAYOUT_ROOTS=none
    export ABLETON_CONFIG_LAYOUT_ROOTS
    ableton_config_init repair
    ableton_prepare_transactions_dir
' _ "$here" > "$base/symlink.out" 2> "$base/symlink.err"; then
    fail "transaction-directory repair followed or replaced a symlink"
fi
[ -L "$state/transactions" ] \
    && grep -qxF 'foreign transaction target' "$base/foreign-transactions" \
    || fail "transaction-directory refusal changed a symlink or its target"

base="$(new_env unowned-transaction-child)"
state="$base/state/ableton-wine"
mkdir -p -- "$state"
printf 'foreign transaction file\n' > "$state/transactions"
if run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    ABLETON_CONFIG_LAYOUT_ROOTS=none
    export ABLETON_CONFIG_LAYOUT_ROOTS
    ableton_config_init repair
    ableton_prepare_transactions_dir
' _ "$here" > "$base/out" 2> "$base/err"; then
    fail "transaction-directory repair claimed unmarked state"
fi
grep -qxF 'foreign transaction file' "$state/transactions" \
    || fail "transaction-directory refusal changed unmarked state"
ok "stale transaction files are repaired only beneath exactly owned state"

# Link-only installation writes data and state. Foreign objects at the runtime,
# prefix, installer-settings, and command roots are unrelated and must survive.
base="$(new_env link-destination-scope)"
for root_name in runtime prefix config bin; do
    printf 'foreign %s root\n' "$root_name" > "$base/foreign-$root_name"
done
run_isolated "$base" env \
    ABLETON_WINE_ROOT="$base/foreign-runtime" \
    ABLETON_WINEPREFIX="$base/foreign-prefix" \
    ABLETON_CONFIG_HOME="$base/foreign-config" \
    ABLETON_BIN_HOME="$base/foreign-bin" \
    bash "$here/install.sh" --link-assets-only \
    > "$base/out" 2> "$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "unrelated roots blocked Link-file installation"; }
for root_name in runtime prefix config bin; do
    grep -qxF "foreign $root_name root" "$base/foreign-$root_name" \
        || fail "Link-file installation changed the unrelated $root_name root"
done
[ -x "$base/data/ableton-wine/ableton-linkctl" ] \
    && [ -x "$base/data/ableton-wine/setup-link.sh" ] \
    || fail "Link-file installation did not publish its selected destinations"
ok "Link-only installation validates only its data and state destinations"

printf '1..%d\n' "$pass"
