#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ABLETON_PROTOCOL_DESKTOP_ID=io.github.shibco.ableton-linux.protocol.desktop
ABLETON_AUZ_DESKTOP_ID=io.github.shibco.ableton-linux.auz.desktop
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-uninstall-boundary-test.XXXXXX")"
cleanup()
{
    case "${work:-}" in
        "${TMPDIR:-/tmp}"/ableton-uninstall-boundary-test.*) rm -rf -- "$work" ;;
    esac
}
trap cleanup EXIT

fail()
{
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

pass=0
ok()
{
    pass=$((pass + 1))
    printf 'ok - %s\n' "$1"
}

kit="$work/kit/scripts"
mkdir -p -- "$kit/lib"
cp -- "$here/installer.sh" "$here/uninstall.sh" "$kit/"
cp -- "$here/detect-scale.sh" "$here/detect-theme.sh" \
    "$here/shortcut-hold.sh" "$here/check-ntsync.sh" \
    "$here/ableton-linkctl" "$here/ableton-linkd.service" "$kit/"
mkdir -p -- "$kit/../tools"
cp -- "$here/../tools/setsyscolors.exe" "$here/../tools/learnheal.exe" \
    "$kit/../tools/"
cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" \
    "$here/lib/manifest.sh" "$here/lib/pipeasio.sh" "$kit/lib/"
cat > "$kit/setup-link.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    plan-disable) exit "${TEST_LINK_PLAN_RC:-0}" ;;
    disable) exit "${TEST_LINK_DISABLE_RC:-0}" ;;
    *) exit 2 ;;
esac
EOF
cat > "$kit/install.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$kit/setup-link.sh" "$kit/install.sh"

new_fixture()
{
    local base="$work/$1"
    mkdir -p -- "$base/home" "$base/tmp" "$base/xdg/config" \
        "$base/xdg/data" "$base/xdg/state/ableton-wine" \
        "$base/xdg/cache" "$base/xdg/run" "$base/runtime" "$base/fakebin"
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' \
        > "$base/runtime/.ableton-linux-runtime"
    printf 'format=1\nowner=ableton-linux\n' \
        > "$base/xdg/state/ableton-wine/.ableton-linux-state"
    cat > "$base/fakebin/rm" <<'EOF'
#!/usr/bin/env bash
set -u
for argument in "$@"; do
    if [ "${FAIL_ADOPTION_CLEANUP:-0}" -eq 1 ]; then
        case "$argument" in
            */transactions/uninstall-adopt.*) exit 75 ;;
        esac
    fi
    if [ -n "${CORRUPT_STATE_AFTER_TARGET:-}" ] \
       && [ "$argument" = "$CORRUPT_STATE_AFTER_TARGET" ]; then
        /bin/rm "$@" || exit $?
        printf 'changed during uninstall\n' > "${CORRUPT_STATE_FILE:?}"
        exit 0
    fi
    if [ -n "${FAIL_RM_TARGET:-}" ] && [ "$argument" = "$FAIL_RM_TARGET" ]; then
        if [ "${FAIL_RM_REMOVE_FIRST:-0}" -eq 1 ]; then
            /bin/rm "$@" || exit $?
        fi
        exit "${FAIL_RM_RC:-73}"
    fi
done
exec /bin/rm "$@"
EOF
    cat > "$base/fakebin/find" <<'EOF'
#!/usr/bin/env bash
set -u
for argument in "$@"; do
    if [ -n "${FAIL_FIND_TARGET:-}" ] && [ "$argument" = "$FAIL_FIND_TARGET" ]; then
        exit "${FAIL_FIND_RC:-74}"
    fi
done
exec /usr/bin/find "$@"
EOF
    cat > "$base/fakebin/xdg-mime" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = query ] && [ "${2:-}" = default ]; then
    rc="${TEST_XDG_QUERY_RC:-0}"
    [ "$rc" -eq 0 ] || exit "$rc"
    printf '%s\n' "${TEST_XDG_DEFAULT:-foreign.desktop}"
    exit 0
fi
if [ "${1:-}" = default ]; then
    exit "${TEST_XDG_SET_RC:-0}"
fi
exit 2
EOF
    cat > "$base/fakebin/update-mime-database" <<'EOF'
#!/usr/bin/env bash
exit "${TEST_MIME_CACHE_RC:-0}"
EOF
    cat > "$base/fakebin/update-desktop-database" <<'EOF'
#!/usr/bin/env bash
exit "${TEST_DESKTOP_CACHE_RC:-0}"
EOF
    cat > "$base/fakebin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "$base/fakebin/"*
    printf '%s\n' "$base"
}

run_uninstall()
{
    local base="$1" mode="$2"
    shift 2
    env HOME="$base/home" \
        XDG_CONFIG_HOME="$base/xdg/config" \
        XDG_DATA_HOME="$base/xdg/data" \
        XDG_STATE_HOME="$base/xdg/state" \
        XDG_CACHE_HOME="$base/xdg/cache" \
        XDG_RUNTIME_DIR="$base/xdg/run" \
        TMPDIR="$base/tmp" \
        PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_LINK_MODE=off \
        ABLETON_SHORTCUTS=preserve \
        "$@" bash "$kit/uninstall.sh" "$mode" --yes
}

run_integration_install()
{
    local base="$1"
    env HOME="$base/home" \
        XDG_CONFIG_HOME="$base/xdg/config" \
        XDG_DATA_HOME="$base/xdg/data" \
        XDG_STATE_HOME="$base/xdg/state" \
        XDG_CACHE_HOME="$base/xdg/cache" \
        XDG_RUNTIME_DIR="$base/xdg/run" \
        TMPDIR="$base/tmp" \
        PATH="$base/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$base/runtime" \
        ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_LINK_MODE=off \
        ABLETON_SHORTCUTS=preserve \
        bash "$here/install.sh" --integration-only
}

assert_warning_contract()
{
    local error_file="$1" retry_expected="${2:-yes}" retry_count
    grep -q '^!! warning:' "$error_file" \
        || fail "optional failure did not produce a warning"
    retry_count="$(grep -c '^   Retry:' "$error_file" || true)"
    if [ "$retry_expected" = yes ]; then
        [ "$retry_count" -eq 1 ] \
            || fail "retained retry support did not print exactly one final retry command"
    elif [ "$retry_count" -ne 0 ]; then
        fail "advisory cleanup warning printed a retry command without retained support"
    fi
    if grep -Eiw 'gate|journal|generation|CAS' "$error_file" >/dev/null; then
        fail "warning exposed internal lifecycle terminology"
    fi
}

run_public_uninstall()
{
    local base="$1"
    env HOME="$base/home" \
        XDG_CONFIG_HOME="$base/xdg/config" \
        XDG_DATA_HOME="$base/xdg/data" \
        XDG_STATE_HOME="$base/xdg/state" \
        XDG_CACHE_HOME="$base/xdg/cache" \
        XDG_RUNTIME_DIR="$base/xdg/run" \
        TMPDIR="$base/tmp" \
        PATH="$base/fakebin:$PATH" \
        ABLETON_LINK_MODE=off ABLETON_SHORTCUTS=preserve \
        bash "$kit/installer.sh" uninstall \
            --runtime-root "$base/runtime" --prefix "$base/prefix" \
            --keep-prefix --yes
}

state_path()
{
    printf '%s/xdg/state/ableton-wine\n' "$1"
}

make_legacy_runtime_without_state()
{
    local base="$1" runtime pe_hash unix_hash
    runtime="$base/home/.local/opt/wine-d2d1-nspa-11.13"
    rm -f -- "$base/xdg/state/ableton-wine/.ableton-linux-state"
    rmdir -- "$base/xdg/state/ableton-wine"
    mkdir -p -- "$base/home/.local/share/ableton-wine" \
        "$base/home/.local/bin" "$runtime/bin" \
        "$runtime/lib/wine/x86_64-windows" \
        "$runtime/lib/wine/x86_64-unix"
    printf '2025.01.01.1\n' > "$base/home/.local/share/ableton-wine/VERSION"
    printf '#!/bin/sh\n# Ableton Live launcher for the patched Wine stack\n' \
        > "$base/home/.local/bin/ableton-live"
    printf '#!/bin/sh\nexit 0\n' > "$runtime/bin/wine"
    printf '#!/bin/sh\nexit 0\n' > "$runtime/bin/wineserver"
    chmod 755 "$base/home/.local/bin/ableton-live" \
        "$runtime/bin/wine" "$runtime/bin/wineserver"
    printf 'legacy PE fixture\n' \
        > "$runtime/lib/wine/x86_64-windows/pipeasio64.dll"
    printf 'legacy Unix fixture\n' \
        > "$runtime/lib/wine/x86_64-unix/pipeasio64.dll.so"
    pe_hash="$(sha256sum -- "$runtime/lib/wine/x86_64-windows/pipeasio64.dll")"
    pe_hash="${pe_hash%% *}"
    unix_hash="$(sha256sum -- "$runtime/lib/wine/x86_64-unix/pipeasio64.dll.so")"
    unix_hash="${unix_hash%% *}"
    printf 'dist-version: 2025.01.01.1\npipeasio-pe: %s\npipeasio-unix: %s\n' \
        "$pe_hash" "$unix_hash" > "$runtime/ABLETON-WINE-BUILD-INFO.txt"
    printf '%s\n' "$runtime"
}

prepare_optional_inventory_fixture()
{
    local base="$1" digest state
    state="$(state_path "$base")"
    TEST_INVENTORY_DESKTOP="$base/xdg/data/applications/ableton-live.desktop"
    TEST_EXTRA_RUNTIME="$base/older-recorded-runtime"
    mkdir -p -- "$(dirname "$TEST_INVENTORY_DESKTOP")" "$TEST_EXTRA_RUNTIME" \
        "$base/xdg/config"
    printf 'generated desktop fixture\n' > "$TEST_INVENTORY_DESKTOP"
    printf '[Default Applications]\nx-scheme-handler/ableton=%s\n' \
        "$ABLETON_PROTOCOL_DESKTOP_ID" > "$base/xdg/config/mimeapps.list"
    printf 'format=1\nname=wine-d2d1-nspa-11.13\n' \
        > "$TEST_EXTRA_RUNTIME/.ableton-linux-runtime"
    digest="$(sha256sum -- "$TEST_INVENTORY_DESKTOP")"
    digest="${digest%% *}"
    printf 'file\t%s\t%s\nruntime\t%s\twine-d2d1-nspa-11.13\n' \
        "$TEST_INVENTORY_DESKTOP" "$digest" "$TEST_EXTRA_RUNTIME" \
        > "$state/install-manifest.tsv"
}

# Optional installer settings cannot veto removal when the public dispatcher
# has already supplied exact runtime/prefix paths. Runtime ownership remains
# the deletion authority; the malformed settings are preserved for inspection.
base="$(new_fixture malformed-installer-settings)"
config="$base/xdg/config/ableton-wine/config"
mkdir -p -- "$(dirname "$config")"
printf '# ableton-linux installer configuration; managed by the installer\nformat=1\nobsolete_key=value\n' \
    > "$config"
cp -- "$config" "$base/config.before"
run_public_uninstall "$base" > "$base/out" 2> "$base/err" \
    || fail "malformed optional settings blocked public uninstall with exact targets"
[ ! -e "$base/runtime" ] \
    && cmp -s -- "$config" "$base/config.before" \
    && [ -f "$(state_path "$base")/.ableton-linux-state" ] \
    || fail "public uninstall changed malformed settings or retained the exact runtime"
grep -qF "installer settings at $config" "$base/err" \
    || fail "preserved malformed installer settings were not reported"
assert_warning_contract "$base/err"
ok "malformed optional settings cannot veto public uninstall with exact core targets"

# Cache cleanup is best effort and is not used by runtime installation. A
# non-directory cache object must therefore survive without blocking even a
# public runtime plan.
base="$(new_fixture cache-object-runtime-plan)"
printf 'foreign cache object\n' > "$base/xdg/cache/ableton-wine"
env HOME="$base/home" \
    XDG_CONFIG_HOME="$base/xdg/config" \
    XDG_DATA_HOME="$base/xdg/data" \
    XDG_STATE_HOME="$base/xdg/state" \
    XDG_CACHE_HOME="$base/xdg/cache" \
    XDG_RUNTIME_DIR="$base/xdg/run" \
    TMPDIR="$base/tmp" PATH="$base/fakebin:$PATH" \
    ABLETON_WINEPREFIX="$base/prefix" ABLETON_LINK_MODE=off \
    ABLETON_SHORTCUTS=preserve \
    bash "$kit/installer.sh" runtime install \
        --runtime-root "$base/runtime" --yes --dry-run \
        > "$base/out" 2> "$base/err" \
    || fail "foreign cache object blocked a public runtime plan"
grep -qxF 'foreign cache object' "$base/xdg/cache/ableton-wine" \
    || fail "public runtime plan changed the unrelated cache object"
ok "unrelated cache objects cannot gate public runtime work"

# Current installs no longer save the desktop default they replaced. Their
# dry-run must say that only Ableton Linux defaults will be cleared, rather
# than claiming every file-opening default will be left unchanged.
base="$(new_fixture snapshot-free-mime-plan)"
printf 'runtime\t%s\twine-d2d1-nspa-11.13\n' "$base/runtime" \
    > "$(state_path "$base")/install-manifest.tsv"
env HOME="$base/home" \
    XDG_CONFIG_HOME="$base/xdg/config" \
    XDG_DATA_HOME="$base/xdg/data" \
    XDG_STATE_HOME="$base/xdg/state" \
    XDG_CACHE_HOME="$base/xdg/cache" \
    XDG_RUNTIME_DIR="$base/xdg/run" \
    TMPDIR="$base/tmp" PATH="$base/fakebin:$PATH" \
    ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINK_MODE=off ABLETON_SHORTCUTS=preserve \
    bash "$kit/uninstall.sh" --keep-prefix --yes --dry-run \
    > "$base/out" 2> "$base/err" \
    || fail "snapshot-free current uninstall plan failed"
grep -qxF '  clear only file-opening defaults that name Ableton Linux' "$base/out" \
    || fail "snapshot-free current uninstall plan misdescribed MIME cleanup"
if grep -qxF '  leave file-opening defaults unchanged' "$base/out"; then
    fail "snapshot-free current uninstall plan claimed its own defaults were untouched"
fi
ok "snapshot-free current uninstall plans describe their narrow MIME cleanup truthfully"

# Exercise the real integration manifest so an ordinary clean uninstall does
# not acquire a warning merely because a generated support path is present.
base="$(new_fixture clean-integration)"
run_integration_install "$base" > "$base/install.out" 2> "$base/install.err" \
    || fail "could not create a full integration fixture"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "clean full integration uninstall failed"
[ ! -e "$base/runtime" ] \
    && [ ! -e "$(state_path "$base")" ] \
    && [ ! -e "$base/xdg/config/ableton-wine/config" ] \
    || fail "clean full integration uninstall retained managed state"
if grep -q '^!! warning:' "$base/err"; then
    fail "clean full integration uninstall emitted an optional-failure warning"
fi
grep -qxF 'OK: uninstall complete' "$base/out" \
    || fail "clean full integration uninstall did not report complete success"
ok "clean full integration uninstall removes all managed state without warnings"

# Legacy marker adoption creates a short-lived transaction under state. The
# uninstall must mark that directory before using it, so its own transaction
# cannot later be mistaken for foreign state after core removal succeeds.
base="$(new_fixture legacy-adoption-state)"
legacy_runtime="$(make_legacy_runtime_without_state "$base")"
run_uninstall "$base" --keep-prefix "ABLETON_WINE_ROOT=$legacy_runtime" \
    > "$base/out" 2> "$base/err" \
    || fail "legacy adoption's own support state made uninstall fail"
[ ! -e "$legacy_runtime" ] \
    || fail "legacy adoption support-state handling retained the runtime"
legacy_state="$(state_path "$base")"
if [ -e "$legacy_state" ] || [ -L "$legacy_state" ]; then
    if [ ! -d "$legacy_state" ] || [ -L "$legacy_state" ]; then
        fail "legacy adoption retained unsafe support state"
    fi
    grep -qxF 'owner=ableton-linux' "$legacy_state/.ableton-linux-state" \
        || fail "legacy adoption retained unmarked support state"
fi
ok "legacy adoption never rejects support state created by the uninstall itself"

# Pre-manifest installers left their generated support bundle at the historical
# HOME path, independent of XDG_DATA_HOME. Exact packaged copies and the
# VERSION record corroborated by the legacy launcher are safe to retire.
base="$(new_fixture clean-legacy-support)"
legacy_runtime="$(make_legacy_runtime_without_state "$base")"
legacy_data="$base/home/.local/share/ableton-wine"
for legacy_helper in \
    detect-scale.sh detect-theme.sh shortcut-hold.sh check-ntsync.sh \
    setup-link.sh ableton-linkctl ableton-linkd.service; do
    cp -- "$kit/$legacy_helper" "$legacy_data/$legacy_helper"
done
cp -- "$kit/../tools/setsyscolors.exe" "$legacy_data/setsyscolors.exe"
cp -- "$kit/../tools/learnheal.exe" "$legacy_data/learnheal.exe"
cat > "$legacy_data/wine-protocol-ableton.desktop" <<EOF
[Desktop Entry]
Type=Application
Exec=$base/home/.local/bin/ableton-live %u
MimeType=x-scheme-handler/ableton;
NoDisplay=true
EOF
run_uninstall "$base" --keep-prefix "ABLETON_WINE_ROOT=$legacy_runtime" \
    > "$base/out" 2> "$base/err" \
    || fail "clean legacy support-file removal failed"
[ ! -e "$legacy_runtime" ] && [ ! -L "$legacy_runtime" ] \
    && [ ! -e "$legacy_data" ] && [ ! -L "$legacy_data" ] \
    && [ ! -e "$base/home/.local/bin/ableton-live" ] \
    || fail "clean legacy uninstall retained recognised project support files"
if grep -q '^!! warning:' "$base/err"; then
    fail "clean legacy support-file removal emitted a warning"
fi
grep -qxF 'OK: uninstall complete' "$base/out" \
    || fail "clean legacy support-file removal did not report complete success"
ok "clean legacy uninstall retires exactly recognised historical support files"

# A same-path helper that differs from the packaged generation may contain
# local work. Legacy evidence authorises inspection, never deletion by name.
base="$(new_fixture modified-legacy-support)"
legacy_runtime="$(make_legacy_runtime_without_state "$base")"
legacy_data="$base/home/.local/share/ableton-wine"
cp -- "$kit/detect-scale.sh" "$legacy_data/detect-scale.sh"
printf '\n# local modification\n' >> "$legacy_data/detect-scale.sh"
cp -- "$legacy_data/detect-scale.sh" "$base/modified-helper.before"
run_uninstall "$base" --keep-prefix "ABLETON_WINE_ROOT=$legacy_runtime" \
    > "$base/out" 2> "$base/err" \
    || fail "modified legacy support file made core uninstall fail"
cmp -s -- "$base/modified-helper.before" "$legacy_data/detect-scale.sh" \
    || fail "legacy uninstall deleted or changed a modified support file"
[ ! -e "$legacy_runtime" ] \
    || fail "modified legacy support file retained the recognised runtime"
grep -qF "kept a modified or unrecognised older support file at $legacy_data/detect-scale.sh" \
    "$base/err" || fail "modified legacy support-file preservation was not reported"
assert_warning_contract "$base/err"
ok "legacy uninstall preserves modified historical support files"

# Publishing the adopted ownership marker is the legacy migration commit. If
# its disposable transaction directory cannot be removed afterward, the exact
# core-complete record must make the residue non-blocking on the next run.
base="$(new_fixture legacy-adoption-cleanup-retry)"
legacy_runtime="$(make_legacy_runtime_without_state "$base")"
legacy_foreign_desktop="$base/xdg/data/applications/ableton-live.desktop"
mkdir -p -- "$(dirname "$legacy_foreign_desktop")"
printf 'foreign desktop fixture\n' > "$legacy_foreign_desktop"
run_uninstall "$base" --keep-prefix \
    "ABLETON_WINE_ROOT=$legacy_runtime" FAIL_ADOPTION_CLEANUP=1 \
    > "$base/first.out" 2> "$base/first.err" \
    || fail "legacy adoption cleanup residue made completed runtime removal fail"
[ ! -e "$legacy_runtime" ] \
    || fail "legacy adoption cleanup residue retained the adopted runtime"
legacy_state="$(state_path "$base")"
legacy_adoption_txn="$(find "$legacy_state/transactions" -mindepth 1 -maxdepth 1 \
    -type d -name 'uninstall-adopt.*' -print -quit)"
[ -n "$legacy_adoption_txn" ] \
    && [ -f "$legacy_adoption_txn/active" ] \
    && cmp -s -- "$legacy_adoption_txn/core-complete" \
        <(printf 'format=1\ncore=complete\n') \
    || fail "legacy adoption cleanup residue lacked its completed-core proof"
/bin/rm -f -- "$legacy_foreign_desktop"
run_uninstall "$base" --keep-prefix "ABLETON_WINE_ROOT=$legacy_runtime" \
    > "$base/retry.out" 2> "$base/retry.err" \
    || fail "completed legacy adoption cleanup residue blocked a direct retry"
[ ! -e "$legacy_state" ] && [ ! -L "$legacy_state" ] \
    || fail "legacy adoption retry retained disposable support state"
ok "completed legacy adoption cleanup residue cannot block a direct retry"

# Installed-file lists authorize only optional cleanup. Malformed text and
# binary/unreadable content must preserve every listed object while independently
# validated configured runtime/prefix removal continues.
for inventory_case in \
    manifest-malformed manifest-binary manifest-unreadable \
    manifest-unmarked-extra \
    prestate-malformed prestate-binary prestate-unreadable; do
    base="$(new_fixture "optional-$inventory_case")"
    state="$(state_path "$base")"
    prepare_optional_inventory_fixture "$base"
    mode=--keep-prefix
    case "$inventory_case" in
        manifest-malformed)
            printf 'file\t/\t%064d\n' 0 >> "$state/install-manifest.tsv"
            mkdir -p -- "$base/prefix"
            printf 'format=1\nprefix=%s\n' "$base/prefix" \
                > "$base/prefix/.ableton-linux-prefix"
            printf 'registry fixture\n' > "$base/prefix/system.reg"
            mode=--delete-prefix
            ;;
        manifest-binary)
            printf '\0binary installed-file data\n' >> "$state/install-manifest.tsv"
            ;;
        manifest-unreadable)
            rm -f -- "$state/install-manifest.tsv"
            ln -s -- /dev/null "$state/install-manifest.tsv"
            ;;
        manifest-unmarked-extra)
            rm -f -- "$TEST_EXTRA_RUNTIME/.ableton-linux-runtime"
            printf 'foreign runtime bytes\n' > "$TEST_EXTRA_RUNTIME/sentinel"
            ;;
        prestate-malformed)
            printf 'present\t%s\t%s/not-a-saved-copy\n' \
                "$TEST_INVENTORY_DESKTOP" "$state" > "$state/install-prestate.tsv"
            ;;
        prestate-binary)
            printf '\0binary saved-file data\n' > "$state/install-prestate.tsv"
            ;;
        prestate-unreadable)
            ln -s -- /dev/null "$state/install-prestate.tsv"
            ;;
    esac
    run_uninstall "$base" "$mode" TEST_LINK_DISABLE_RC=73 \
        > "$base/out" 2> "$base/err" \
        || fail "$inventory_case vetoed independently validated core removal"
    [ ! -e "$base/runtime" ] \
        || fail "$inventory_case retained the configured runtime"
    if [ "$mode" = --delete-prefix ] && [ -e "$base/prefix" ]; then
        fail "$inventory_case retained the requested validated prefix"
    fi
    [ -e "$TEST_INVENTORY_DESKTOP" ] && [ -e "$TEST_EXTRA_RUNTIME" ] \
        || fail "$inventory_case removed an object from untrusted optional information"
    grep -qxF "x-scheme-handler/ableton=$ABLETON_PROTOCOL_DESKTOP_ID" \
        "$base/xdg/config/mimeapps.list" \
        || fail "$inventory_case changed a desktop default from untrusted optional information"
    grep -q "installer's file list could not be trusted" "$base/err" \
        || fail "$inventory_case warning did not identify why optional files remain"
    if grep -q 'Link integration may still be enabled' "$base/err"; then
        fail "$inventory_case attempted Link cleanup from untrusted optional information"
    fi
    assert_warning_contract "$base/err"
done
ok "malformed optional file lists never veto configured runtime or requested-prefix removal"

# An unfinished core operation remains a real stop condition.
base="$(new_fixture active-core-recovery)"
mkdir -p -- "$(state_path "$base")/transactions/install.active"
: > "$(state_path "$base")/transactions/install.active/active"
if run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err"; then
    fail "uninstall ignored unfinished installer recovery"
fi
[ -e "$base/runtime/.ableton-linux-runtime" ] \
    || fail "active recovery refusal happened after runtime deletion"
grep -q 'earlier installation stopped before recovery finished' "$base/err" \
    || fail "active recovery refusal was not explicit"
ok "unfinished core recovery remains fatal before removal"

# Unrecognised optional support state cannot invalidate an exact runtime target.
base="$(new_fixture malformed-support-state)"
printf 'foreign support state\n' > "$(state_path "$base")/.ableton-linux-state"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "unrecognised optional support state made core removal fail"
[ ! -e "$base/runtime" ] || fail "unrecognised support state retained the runtime"
[ -e "$(state_path "$base")/.ableton-linux-state" ] \
    || fail "unrecognised support state was deleted"
grep -q 'support files were left unchanged' "$base/err" \
    || fail "unrecognised support state warning did not identify what remains"
assert_warning_contract "$base/err"
ok "unrecognised support state is warning-only"

# The support path itself is optional cleanup. A regular file there is neither
# owned directory state nor a reason to retain an independently proven runtime.
base="$(new_fixture regular-support-state-root)"
state="$(state_path "$base")"
rm -rf -- "$state"
printf 'foreign support-state root\n' > "$state"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "regular optional support-state root made core removal fail"
[ ! -e "$base/runtime" ] \
    || fail "regular optional support-state root retained the runtime"
grep -qxF 'foreign support-state root' "$state" \
    || fail "regular optional support-state root was changed"
grep -q 'support files were left unchanged' "$base/err" \
    || fail "regular optional support-state root was not reported"
assert_warning_contract "$base/err"
ok "a non-directory optional support path cannot veto runtime removal"

# A configured support root may overlap a kept core tree after manual settings
# edits. Do not inspect its transaction-looking children as installer recovery,
# and never recursively clean the overlapping tree as optional state.
base="$(new_fixture overlapping-support-prefix)"
mkdir -p -- "$base/prefix/transactions/foreign-run"
printf 'format=1\nowner=ableton-linux\n' \
    > "$base/prefix/.ableton-linux-state"
printf 'kept prefix sentinel\n' > "$base/prefix/user-data"
: > "$base/prefix/transactions/foreign-run/active"
run_uninstall "$base" --keep-prefix "ABLETON_STATE_HOME=$base/prefix" \
    > "$base/out" 2> "$base/err" \
    || fail "overlapping optional support state made runtime removal fail"
[ ! -e "$base/runtime" ] \
    || fail "overlapping optional support state retained the runtime"
grep -qxF 'kept prefix sentinel' "$base/prefix/user-data" \
    && [ -e "$base/prefix/transactions/foreign-run/active" ] \
    || fail "optional state cleanup changed the overlapping kept prefix"
grep -q 'path overlaps the Wine runtime or prefix' "$base/err" \
    || fail "overlapping optional support state was not reported"
assert_warning_contract "$base/err"
ok "overlapping optional support state is skipped without gating core removal"

# Current installs do not retain the default an authoritative project ID
# replaced. Uninstall still removes only those exact IDs and preserves every
# unrelated mimeapps.list entry.
base="$(new_fixture snapshot-free-mime)"
rm -f -- "$base/fakebin/xdg-mime" "$base/fakebin/update-mime-database" \
    "$base/fakebin/update-desktop-database"
mkdir -p -- "$base/xdg/data/applications" "$base/xdg/config"
cat > "$base/xdg/data/applications/third-party.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Third Party
Exec=/usr/bin/true %f
EOF
cat > "$base/xdg/config/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/ableton=third-party.desktop
text/plain=third-party.desktop
EOF
run_integration_install "$base" > "$base/install.out" 2> "$base/install.err" \
    || fail "could not create a snapshot-free MIME fixture"
grep -qxF "x-scheme-handler/ableton=$ABLETON_PROTOCOL_DESKTOP_ID" \
    "$base/xdg/config/mimeapps.list" \
    || fail "integration fixture did not install its scheme-handler default"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "snapshot-free MIME cleanup made uninstall fail"
if grep -Eq "=($ABLETON_PROTOCOL_DESKTOP_ID|$ABLETON_AUZ_DESKTOP_ID|ableton-live[.]desktop|max9[.]desktop|wine-protocol-c74max[.]desktop)$" \
    "$base/xdg/config/mimeapps.list"; then
    fail "snapshot-free uninstall left a default naming a removed project entry"
fi
grep -qxF 'text/plain=third-party.desktop' "$base/xdg/config/mimeapps.list" \
    || fail "snapshot-free MIME cleanup changed an unrelated default"
! grep -q '^x-scheme-handler/ableton=third-party.desktop$' \
    "$base/xdg/config/mimeapps.list" \
    || fail "snapshot-free MIME cleanup invented restoration data it did not retain"
ok "snapshot-free uninstall clears exact project defaults and preserves unrelated MIME entries"

# Link shutdown is helpful cleanup, not authority to remove a proven runtime.
base="$(new_fixture optional-link)"
run_uninstall "$base" --keep-prefix TEST_LINK_DISABLE_RC=73 \
    > "$base/out" 2> "$base/err" \
    || fail "Link cleanup failure made uninstall fail"
[ ! -e "$base/runtime" ] || fail "Link cleanup failure retained the runtime"
[ -e "$(state_path "$base")" ] \
    || fail "Link cleanup failure discarded the support files needed to retry"
grep -q 'Ableton Link integration may still be enabled' "$base/err" \
    || fail "Link cleanup warning did not identify what remains"
assert_warning_contract "$base/err"
ok "Link cleanup failure is warning-only and retains retry support"

# Generated desktop helpers are optional. A readable helper with broken shell
# syntax must be reported without letting a bare source command abort uninstall.
base="$(new_fixture shortcut-helper-source)"
mkdir -p -- "$base/xdg/data/ableton-wine"
cat > "$base/xdg/data/ableton-wine/shortcut-hold.sh" <<'EOF'
# GNOME shortcut hold
if this helper is incomplete
EOF
: > "$(state_path "$base")/hold-v2"
cat > "$base/fakebin/gsettings" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$base/fakebin/gsettings"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "broken optional shortcut helper made uninstall fail"
[ ! -e "$base/runtime" ] || fail "broken shortcut helper retained the runtime"
grep -q 'shortcut restoration was skipped' "$base/err" \
    || fail "broken shortcut helper warning did not identify what remains"
assert_warning_contract "$base/err"
ok "broken generated shortcut helper is warning-only"

# Failure to inspect a legacy panel shortcut is optional and must leave the
# shortcut untouched while core removal proceeds.
base="$(new_fixture panel-ownership-query)"
state="$(state_path "$base")"
panel="$base/home/.local/bin/pipeasio-settings"
mkdir -p -- "$(dirname "$panel")" "$base/xdg/data/ableton-wine"
ln -s -- "$base/runtime/bin/pipeasio-settings" "$panel"
printf '2026.01.01.1\n' > "$base/xdg/data/ableton-wine/VERSION"
printf 'runtime\t%s\twine-d2d1-nspa-11.13\n' "$base/runtime" \
    > "$state/install-manifest.tsv"
cat > "$base/fakebin/awk" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *'$2==p && ($1=="file" || $1=="config" || $1=="symlink")'*) exit 77 ;;
esac
exec /usr/bin/awk "$@"
EOF
chmod 755 "$base/fakebin/awk"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "panel ownership-query failure made uninstall fail"
[ ! -e "$base/runtime" ] || fail "panel ownership-query failure retained the runtime"
[ -L "$panel" ] || fail "panel ownership-query failure removed its optional shortcut"
grep -q 'PipeASIO Settings shortcuts were left unchanged' "$base/err" \
    || fail "panel ownership-query warning did not identify what remains"
assert_warning_contract "$base/err"
ok "legacy panel ownership-query failure is warning-only"

# A corrupt optional MIME snapshot cannot veto removal of the runtime.
base="$(new_fixture invalid-mime-state)"
printf 'application/x-not-owned\tforeign.desktop\n' \
    > "$(state_path "$base")/mime-prestate.tsv"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "invalid MIME state made uninstall fail"
[ ! -e "$base/runtime" ] || fail "invalid MIME state retained the runtime"
[ -e "$(state_path "$base")/mime-prestate.tsv" ] \
    || fail "invalid MIME state was discarded before it could be reviewed"
grep -q 'File-opening defaults were left unchanged because the saved settings' "$base/err" \
    || fail "invalid MIME state warning was not explicit"
assert_warning_contract "$base/err"
ok "invalid MIME restoration state is warning-only"

# Backend query failure is also optional and must retain the exact saved value.
base="$(new_fixture mime-query)"
printf 'application/x-ableton-live-set\tforeign.desktop\n' \
    > "$(state_path "$base")/mime-prestate.tsv"
run_uninstall "$base" --keep-prefix TEST_XDG_QUERY_RC=77 \
    > "$base/out" 2> "$base/err" \
    || fail "MIME query failure made uninstall fail"
[ ! -e "$base/runtime" ] || fail "MIME query failure retained the runtime"
grep -qx $'application/x-ableton-live-set\tforeign.desktop' \
    "$(state_path "$base")/mime-prestate.tsv" \
    || fail "MIME query failure discarded the saved default"
grep -q 'could not be checked' "$base/err" \
    || fail "MIME query warning did not identify the failed operation"
assert_warning_contract "$base/err"
ok "MIME backend failure is warning-only"

# A recognisable project file is removed authoritatively; an opaque changed
# file at another managed path is preserved without blocking core removal.
base="$(new_fixture authoritative-and-foreign)"
desktop="$base/xdg/data/applications/ableton-live.desktop"
opaque="$base/xdg/data/ableton-wine/ntsyncprobe.exe"
mkdir -p -- "$(dirname "$desktop")" "$(dirname "$opaque")"
cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Locally renamed Ableton Live
Comment=Music production and performance
Exec=$base/home/.local/bin/ableton-live %f
MimeType=application/x-ableton-live-set;application/x-ableton-live-clip;application/x-ableton-live-pack;
EOF
printf 'foreign opaque bytes\n' > "$opaque"
zero_digest="$(printf '%064d' 0)"
printf 'file\t%s\t%s\nfile\t%s\t%s\n' \
    "$desktop" "$zero_digest" "$opaque" "$zero_digest" \
    > "$(state_path "$base")/install-manifest.tsv"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "preserved foreign integration file made uninstall fail"
[ ! -e "$desktop" ] \
    || fail "recognisable project desktop file was not removed authoritatively"
grep -qxF 'foreign opaque bytes' "$opaque" \
    || fail "unrecognised opaque file was removed"
[ ! -e "$base/runtime" ] \
    || fail "preserved foreign integration file retained the runtime"
grep -qF "kept an unrecognised or user-modified file at $opaque" "$base/err" \
    || fail "preserved foreign integration file was not reported"
assert_warning_contract "$base/err"
ok "recognisable project files are removed while foreign data is preserved"

# Snapshot-free launcher replacement has one two-path ownership relation: the
# canonical path is generated, while its adjacent .bak contains the displaced
# user object. A failed cleanup must remain retryable without deleting either
# copy, and the retry must recognise an already-restored launcher.
base="$(new_fixture adjacent-launcher-retry)"
state="$(state_path "$base")"
panel_command="$base/home/.local/bin/pipeasio-settings"
panel_desktop="$base/xdg/data/applications/pipeasio-settings.desktop"
mkdir -p -- "$base/runtime/bin" "$(dirname "$panel_command")" \
    "$(dirname "$panel_desktop")"
printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/pipeasio-settings"
chmod 755 "$base/runtime/bin/pipeasio-settings"
ln -s -- "$base/runtime/bin/pipeasio-settings" "$panel_command"
printf '[Desktop Entry]\nName=PipeASIO Settings\n' > "$panel_desktop"
printf '#!/bin/sh\necho displaced-user-command\n' > "${panel_command}.bak"
chmod 755 "${panel_command}.bak"
printf '[Desktop Entry]\nName=Displaced user desktop\n' > "${panel_desktop}.bak"
cp -- "${panel_command}.bak" "$base/command.before"
cp -- "${panel_desktop}.bak" "$base/desktop.before"
command_digest="$({ printf 'symlink\0'; readlink -n -- "$panel_command"; } \
    | sha256sum | awk '{print $1}')"
desktop_digest="$(sha256sum -- "$panel_desktop")"
desktop_digest="${desktop_digest%% *}"
command_backup_digest="$(sha256sum -- "${panel_command}.bak")"
command_backup_digest="${command_backup_digest%% *}"
desktop_backup_digest="$(sha256sum -- "${panel_desktop}.bak")"
desktop_backup_digest="${desktop_backup_digest%% *}"
# Put each backup row first to prove record order cannot delete the recovery
# copy before the canonical launcher is considered.
printf 'file\t%s\t%s\nsymlink\t%s\t%s\nfile\t%s\t%s\nfile\t%s\t%s\nruntime\t%s\twine-d2d1-nspa-11.13\n' \
    "${panel_command}.bak" "$command_backup_digest" \
    "$panel_command" "$command_digest" \
    "${panel_desktop}.bak" "$desktop_backup_digest" \
    "$panel_desktop" "$desktop_digest" "$base/runtime" \
    > "$state/install-manifest.tsv"
run_uninstall "$base" --keep-prefix FAIL_RM_TARGET="${panel_command}.bak" \
    > "$base/first.out" 2> "$base/first.err" \
    || fail "saved-launcher cleanup failure made uninstall fail"
cmp -s -- "$base/command.before" "$panel_command" \
    || fail "saved command was not restored before its cleanup failure"
cmp -s -- "$base/desktop.before" "$panel_desktop" \
    || fail "saved desktop was not restored"
[ -f "${panel_command}.bak" ] \
    || fail "failed saved-command cleanup did not retain its retry copy"
[ ! -e "${panel_desktop}.bak" ] && [ ! -L "${panel_desktop}.bak" ] \
    || fail "successful saved-desktop cleanup retained its extra copy"
[ ! -e "$base/runtime" ] \
    || fail "saved-launcher cleanup failure retained the configured runtime"
assert_warning_contract "$base/first.err"
run_uninstall "$base" --keep-prefix > "$base/retry.out" 2> "$base/retry.err" \
    || fail "saved-launcher cleanup retry failed"
if ! cmp -s -- "$base/command.before" "$panel_command" \
   || ! cmp -s -- "$base/desktop.before" "$panel_desktop"; then
    fail "saved-launcher cleanup retry changed a restored user launcher"
fi
[ ! -e "${panel_command}.bak" ] && [ ! -L "${panel_command}.bak" ] \
    || fail "saved-launcher cleanup retry retained the extra command copy"
if grep -q '^!! warning:' "$base/retry.err"; then
    fail "idempotent saved-launcher cleanup retry emitted a warning"
fi
ok "adjacent launcher backups restore user objects and retry idempotently"

# If the canonical launcher changed after installation, neither it nor its exact
# saved earlier launcher is disposable project state.
base="$(new_fixture modified-adjacent-launcher)"
state="$(state_path "$base")"
panel_desktop="$base/xdg/data/applications/pipeasio-settings.desktop"
mkdir -p -- "$(dirname "$panel_desktop")"
printf '[Desktop Entry]\nName=Generated panel\n' > "$panel_desktop"
generated_digest="$(sha256sum -- "$panel_desktop")"
generated_digest="${generated_digest%% *}"
printf '[Desktop Entry]\nName=Saved foreign panel\n' > "${panel_desktop}.bak"
saved_digest="$(sha256sum -- "${panel_desktop}.bak")"
saved_digest="${saved_digest%% *}"
printf 'file\t%s\t%s\nfile\t%s\t%s\n' \
    "$panel_desktop" "$generated_digest" \
    "${panel_desktop}.bak" "$saved_digest" \
    > "$state/install-manifest.tsv"
printf '[Desktop Entry]\nName=User modified after install\n' > "$panel_desktop"
cp -- "$panel_desktop" "$base/modified.before"
cp -- "${panel_desktop}.bak" "$base/saved.before"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "modified canonical launcher made uninstall fail"
if ! cmp -s -- "$base/modified.before" "$panel_desktop" \
   || ! cmp -s -- "$base/saved.before" "${panel_desktop}.bak"; then
    fail "modified launcher cleanup deleted or changed foreign data"
fi
[ ! -e "$base/runtime" ] \
    || fail "modified launcher retained the configured runtime"
[ "$(grep -cF "kept the user-modified launcher at $panel_desktop" "$base/err")" -eq 1 ] \
    || fail "modified launcher pair did not produce exactly one preservation warning"
assert_warning_contract "$base/err"
ok "modified canonical and saved launchers are both preserved with one warning"

# Older installations may have a persistent pre-install copy for both the
# canonical launcher and a foreign object that already occupied <name>.bak.
# Those explicit records take precedence over the snapshot-free pair fallback.
base="$(new_fixture persistent-launcher-prestate)"
state="$(state_path "$base")"
panel_desktop="$base/xdg/data/applications/pipeasio-settings.desktop"
mkdir -p -- "$(dirname "$panel_desktop")" "$state/install-prestate"
printf '[Desktop Entry]\nName=Generated panel\n' > "$panel_desktop"
printf '[Desktop Entry]\nName=Displaced canonical\n' > "${panel_desktop}.bak"
canonical_digest="$(sha256sum -- "$panel_desktop")"
canonical_digest="${canonical_digest%% *}"
adjacent_digest="$(sha256sum -- "${panel_desktop}.bak")"
adjacent_digest="${adjacent_digest%% *}"
canonical_id="$(printf '%s' "$panel_desktop" | sha256sum | awk '{print $1}')"
adjacent_id="$(printf '%s' "${panel_desktop}.bak" | sha256sum | awk '{print $1}')"
printf '[Desktop Entry]\nName=Original canonical\n' \
    > "$state/install-prestate/$canonical_id"
printf '[Desktop Entry]\nName=Original foreign backup\n' \
    > "$state/install-prestate/$adjacent_id"
printf 'present\t%s\t%s\npresent\t%s\t%s\n' \
    "$panel_desktop" "$state/install-prestate/$canonical_id" \
    "${panel_desktop}.bak" "$state/install-prestate/$adjacent_id" \
    > "$state/install-prestate.tsv"
printf 'file\t%s\t%s\nfile\t%s\t%s\n' \
    "$panel_desktop" "$canonical_digest" \
    "${panel_desktop}.bak" "$adjacent_digest" \
    > "$state/install-manifest.tsv"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "persistent launcher prestate made uninstall fail"
grep -qxF 'Name=Original canonical' "$panel_desktop" \
    || fail "persistent prestate did not restore the original canonical launcher"
grep -qxF 'Name=Original foreign backup' "${panel_desktop}.bak" \
    || fail "persistent prestate did not restore a pre-existing foreign .bak"
[ ! -e "$base/runtime" ] \
    || fail "persistent launcher prestate retained the configured runtime"
ok "persistent launcher prestate preserves a pre-existing foreign backup"

# A failed optional file removal is judged by its postcondition and reported;
# it must not be reclassified as a runtime failure.
base="$(new_fixture integration-removal)"
desktop="$base/xdg/data/applications/ableton-live.desktop"
mkdir -p -- "$(dirname "$desktop")"
printf 'managed desktop bytes\n' > "$desktop"
desktop_digest="$(sha256sum -- "$desktop")"
desktop_digest="${desktop_digest%% *}"
printf 'file\t%s\t%s\n' "$desktop" "$desktop_digest" \
    > "$(state_path "$base")/install-manifest.tsv"
run_uninstall "$base" --keep-prefix FAIL_RM_TARGET="$desktop" \
    > "$base/out" 2> "$base/err" \
    || fail "project file removal failure made uninstall fail"
[ -f "$desktop" ] || fail "file-removal failure fixture unexpectedly disappeared"
[ ! -e "$base/runtime" ] || fail "project file removal failure retained the runtime"
grep -qF "an Ableton Linux file remains at $desktop" "$base/err" \
    || fail "remaining project file was not identified"
assert_warning_contract "$base/err"
ok "project integration removal failure is warning-only"

# Cache rebuild tools are advisory after the desktop files have been handled.
base="$(new_fixture desktop-cache)"
mkdir -p -- "$base/xdg/data/applications"
run_uninstall "$base" --keep-prefix TEST_DESKTOP_CACHE_RC=71 \
    > "$base/out" 2> "$base/err" \
    || fail "desktop cache failure made uninstall fail"
[ ! -e "$base/runtime" ] || fail "desktop cache failure retained the runtime"
grep -q 'desktop application cache could not be refreshed' "$base/err" \
    || fail "desktop cache warning did not identify what remains stale"
assert_warning_contract "$base/err" no
ok "desktop cache refresh failure is warning-only"

# Cleanup of the manifest, state tree, and managed config is optional after the
# runtime has gone. Each injected command failure must leave a retryable object.
for cleanup_kind in manifest state config; do
    base="$(new_fixture "cleanup-$cleanup_kind")"
    state="$(state_path "$base")"
    target=""
    failure_setting=""
    case "$cleanup_kind" in
        manifest)
            printf 'runtime\t%s\twine-d2d1-nspa-11.13\n' "$base/runtime" \
                > "$state/install-manifest.tsv"
            target="$state/install-manifest.tsv"
            ;;
        state)
            target="$state"
            failure_setting="FAIL_FIND_TARGET=$target"
            ;;
        config)
            mkdir -p -- "$base/xdg/config/ableton-wine"
            cat > "$base/xdg/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=
link_mode=off
linkd=$base/xdg/data/ableton-wine/ableton-linkd
EOF
            target="$base/xdg/config/ableton-wine/config"
            ;;
    esac
    [ -n "$failure_setting" ] || failure_setting="FAIL_RM_TARGET=$target"
    run_uninstall "$base" --keep-prefix "$failure_setting" \
        > "$base/out" 2> "$base/err" \
        || fail "$cleanup_kind cleanup failure made uninstall fail"
    [ ! -e "$base/runtime" ] \
        || fail "$cleanup_kind cleanup failure retained the runtime"
    [ -e "$target" ] || [ -L "$target" ] \
        || fail "$cleanup_kind cleanup fixture did not remain for retry"
    if [ "$cleanup_kind" = state ]; then
        grep -qxF 'owner=ableton-linux' "$state/.ableton-linux-state" \
            || fail "partial state cleanup removed its retry ownership marker"
    fi
    assert_warning_contract "$base/err"
done
ok "manifest, state, and configuration cleanup failures are warning-only"

# Optional support-state ownership may change after core removal. That skips
# recursive support cleanup and reports residue without changing the core result.
base="$(new_fixture post-core-state-change)"
state="$(state_path "$base")"
run_uninstall "$base" --keep-prefix \
    CORRUPT_STATE_AFTER_TARGET="$base/runtime" \
    CORRUPT_STATE_FILE="$state/.ableton-linux-state" \
    > "$base/out" 2> "$base/err" \
    || fail "post-core support-state ownership change made uninstall fail"
[ ! -e "$base/runtime" ] || fail "post-core support-state change retained the runtime"
grep -qxF 'changed during uninstall' "$state/.ableton-linux-state" \
    || fail "post-core support-state fixture was not retained"
grep -q 'installer could not confirm that it created their directory' "$base/err" \
    || fail "post-core support-state warning did not identify why cleanup was skipped"
assert_warning_contract "$base/err"
ok "post-core support-state safety failures are warning-only"

# An older runtime from valid optional information is best-effort. Its removal
# failure cannot displace successful removal of the configured runtime.
base="$(new_fixture extra-runtime-removal)"
state="$(state_path "$base")"
extra_runtime="$base/extra-runtime"
mkdir -p -- "$extra_runtime"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' \
    > "$extra_runtime/.ableton-linux-runtime"
printf 'runtime\t%s\twine-d2d1-nspa-11.13\nruntime\t%s\twine-d2d1-nspa-11.13\n' \
    "$base/runtime" "$extra_runtime" > "$state/install-manifest.tsv"
run_uninstall "$base" --keep-prefix FAIL_RM_TARGET="$extra_runtime" \
    > "$base/out" 2> "$base/err" \
    || fail "older recorded runtime removal failure made uninstall fail"
[ ! -e "$base/runtime" ] || fail "older runtime failure retained the configured runtime"
[ -e "$extra_runtime/.ableton-linux-runtime" ] \
    || fail "older runtime failure fixture unexpectedly disappeared"
grep -q 'older Wine runtime remains' "$base/err" \
    || fail "older runtime residue was not identified"
assert_warning_contract "$base/err"
ok "older recorded runtime removal failure is warning-only"

# A command can report failure after reaching the requested end state (for
# example, a wrapper's bookkeeping error). The verified outcome is authoritative.
base="$(new_fixture runtime-status-only-failure)"
run_uninstall "$base" --keep-prefix \
    FAIL_RM_TARGET="$base/runtime" FAIL_RM_REMOVE_FIRST=1 \
    > "$base/out" 2> "$base/err" \
    || fail "runtime command status overrode a successful deletion outcome"
[ ! -e "$base/runtime" ] \
    || fail "status-only runtime failure fixture did not reach the deletion outcome"
grep -qxF 'OK: uninstall complete' "$base/out" \
    || fail "successful runtime deletion outcome was not reported as complete"
ok "runtime deletion is classified by postcondition, not command status alone"

# Output is presentation, not a removal gate.  A broken stdout consumer must
# not interrupt the already-authorised runtime/prefix sequence or make its
# verified completion report failure.
base="$(new_fixture presentation-output-failure)"
extra_runtime="$base/extra-runtime"
mkdir -p -- "$extra_runtime" "$base/prefix"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' \
    > "$extra_runtime/.ableton-linux-runtime"
printf 'format=1\nprefix=%s\n' "$base/prefix" \
    > "$base/prefix/.ableton-linux-prefix"
printf 'registry fixture\n' > "$base/prefix/system.reg"
printf 'runtime\t%s\twine-d2d1-nspa-11.13\nruntime\t%s\twine-d2d1-nspa-11.13\n' \
    "$base/runtime" "$extra_runtime" \
    > "$(state_path "$base")/install-manifest.tsv"
run_uninstall "$base" --delete-prefix > /dev/full 2> "$base/err" \
    || fail "presentation output failure made verified removals fail"
[ ! -e "$base/runtime" ] && [ ! -L "$base/runtime" ] \
    && [ ! -e "$extra_runtime" ] && [ ! -L "$extra_runtime" ] \
    && [ ! -e "$base/prefix" ] && [ ! -L "$base/prefix" ] \
    || fail "presentation output failure interrupted verified removals"
ok "presentation output cannot interrupt or fail verified removals"

# Ignoring presentation writes must not hide a core deletion failure.
base="$(new_fixture presentation-output-with-runtime-failure)"
if run_uninstall "$base" --keep-prefix FAIL_RM_TARGET="$base/runtime" \
    > /dev/full 2> "$base/err"; then
    fail "presentation output handling hid a runtime deletion failure"
fi
[ -e "$base/runtime" ] \
    || fail "runtime failure fixture unexpectedly disappeared with broken output"
grep -q 'runtime removal is incomplete' "$base/err" \
    || fail "broken output obscured the real runtime deletion failure"
ok "presentation output handling preserves core deletion failures"

# Runtime and requested-prefix deletion are the core operation and stay fatal.
base="$(new_fixture runtime-removal)"
if run_uninstall "$base" --keep-prefix FAIL_RM_TARGET="$base/runtime" \
    > "$base/out" 2> "$base/err"; then
    fail "uninstall succeeded while the runtime remained"
fi
[ -e "$base/runtime" ] || fail "runtime failure fixture unexpectedly disappeared"
[ -e "$(state_path "$base")" ] \
    || fail "runtime failure discarded support files needed to retry"
grep -q 'runtime removal is incomplete' "$base/err" \
    || fail "runtime removal failure was not explicit"
grep -q '^   Retry:' "$base/err" \
    || fail "runtime removal failure did not print a retry command"
ok "runtime deletion failure remains fatal"

base="$(new_fixture prefix-removal)"
mkdir -p -- "$base/prefix"
printf 'format=1\nprefix=%s\n' "$base/prefix" \
    > "$base/prefix/.ableton-linux-prefix"
printf 'registry fixture\n' > "$base/prefix/system.reg"
if run_uninstall "$base" --delete-prefix FAIL_RM_TARGET="$base/prefix" \
    > "$base/out" 2> "$base/err"; then
    fail "uninstall succeeded while the requested prefix remained"
fi
[ -e "$base/prefix" ] || fail "prefix failure fixture unexpectedly disappeared"
[ ! -e "$base/runtime" ] || fail "prefix failure occurred before runtime removal"
[ -e "$(state_path "$base")" ] \
    || fail "prefix failure discarded support files needed to retry"
grep -q 'prefix removal is incomplete' "$base/err" \
    || fail "prefix removal failure was not explicit"
grep -q '^   Retry:' "$base/err" \
    || fail "prefix removal failure did not print a retry command"
ok "requested-prefix deletion failure remains fatal"

# A suggestive sibling name is never delete authority, but the foreign sibling
# is optional and cannot veto removal of the exact configured runtime.
base="$(new_fixture rollback-ownership)"
mkdir -p -- "$base/runtime-rollback-unrecognised"
printf 'foreign saved runtime\n' > "$base/runtime-rollback-unrecognised/sentinel"
run_uninstall "$base" --keep-prefix > "$base/out" 2> "$base/err" \
    || fail "unmarked saved-runtime sibling made uninstall fail"
[ ! -e "$base/runtime" ] \
    || fail "unmarked saved-runtime sibling retained the configured runtime"
grep -qxF 'foreign saved runtime' "$base/runtime-rollback-unrecognised/sentinel" \
    || fail "unmarked saved-runtime sibling was removed"
grep -q 'unrecognised saved Wine runtime was left unchanged' "$base/err" \
    || fail "saved-runtime preservation warning was not explicit"
assert_warning_contract "$base/err"
ok "unrecognised saved-runtime siblings are preserved without vetoing core removal"

printf '1..%d\n' "$pass"
