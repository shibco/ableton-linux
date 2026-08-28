#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ableton-link-boundary.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
tests=0

fail()
{
    echo "not ok - $*" >&2
    exit 1
}

ok()
{
    tests=$((tests + 1))
    echo "ok - $*"
}

linkd_artifact="$root/dist/ableton-linkd"
if [ ! -f "$linkd_artifact" ]; then
    echo "!! missing build artifact: dist/ableton-linkd" >&2
    echo "!! run ./build.sh first" >&2
    fail "prerequisite build artifacts are valid"
fi

new_env()
{
    local name="$1"
    base="$scratch/$name"
    mkdir -p -- "$base/home" "$base/data/ableton-wine" \
        "$base/state/ableton-wine" "$base/config" "$base/cache" \
        "$base/run" "$base/fakebin"
    printf 'format=1\nowner=ableton-linux\n' \
        > "$base/state/ableton-wine/.ableton-linux-state"
    printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkd"
    chmod 755 "$base/data/ableton-wine/ableton-linkd"
    cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
# These cases model a login without a reachable systemd user manager.
exit 1
EOF
    cat > "$base/fakebin/grep" <<'EOF'
#!/bin/sh
for argument do
    [ "$argument" != /etc/ufw/ufw.conf ] || exit 1
done
exec /usr/bin/grep "$@"
EOF
    printf '#!/bin/sh\nexit 1\n' > "$base/fakebin/firewall-cmd"
    chmod 755 "$base/fakebin/systemctl" "$base/fakebin/grep" \
        "$base/fakebin/firewall-cmd"
}

run_link()
{
    env HOME="$base/home" XDG_DATA_HOME="$base/data" \
        XDG_CONFIG_HOME="$base/config" XDG_STATE_HOME="$base/state" \
        XDG_CACHE_HOME="$base/cache" XDG_RUNTIME_DIR="$base/run" \
        PATH="$base/fakebin:/usr/bin:/bin" "$@"
}

# A completed installer may leave the old transaction path exported after it
# has removed that directory. Link's own generated state must not try to append
# to that dead journal.
new_env deleted-transaction
run_link env ABLETON_TRANSACTION_DIR="$base/deleted-transaction" \
    bash "$here/setup-link.sh" enable --mode=session \
    > "$base/out" 2> "$base/err" \
    || { sed -n '1,100p' "$base/err" >&2; fail "a deleted installer work directory blocks session Link"; }
[ ! -e "$base/deleted-transaction" ] \
    || fail "Link recreated a completed installer's work directory"
grep -qxF 'link_mode=session' "$base/config/ableton-wine/config" \
    || fail "session Link was not saved after the deleted-directory case"
ok "a deleted installer work directory cannot gate Link setup"

# The public installer owns the final success line because it still has
# coordinator checks to finish after the Link child returns.
new_env coordinated-output
run_link env ABLETON_LINK_COORDINATED=1 \
    bash "$here/setup-link.sh" enable --mode=session \
    > "$base/out" 2> "$base/err" \
    || { sed -n '1,100p' "$base/err" >&2; fail "coordinated Link setup failed"; }
! grep -q 'Step [0-9]* Complete' "$base/out" \
    || fail "Link child closed a step that belongs to its coordinator"
[ ! -e "$base/config/ableton-wine/config" ] \
    || fail "coordinated Link child wrote the installer's final config mapping"
grep -qF '│  │  > No active ufw or firewalld; the firewall is unchanged' "$base/out" \
    || fail "coordinated Link progress bypassed the installer tree"
ok "coordinated Link leaves final config and success reporting to the installer"

# The canonical service file belongs to this project. Re-running setup repairs
# arbitrary bytes at that path instead of demanding an old checksum.
new_env authoritative-unit
mkdir -p -- "$base/config/systemd/user"
printf 'foreign bytes at a generated path\n' \
    > "$base/config/systemd/user/ableton-linkd.service"
printf 'o\n' | run_link bash "$here/setup-link.sh" enable --mode=session \
    > "$base/out" 2> "$base/err" \
    || { sed -n '1,100p' "$base/err" >&2; fail "a modified generated unit blocks Link repair"; }
grep -qxF 'X-AbletonLinuxOwned=true' \
    "$base/config/systemd/user/ableton-linkd.service" \
    || fail "Link did not overwrite its canonical unit"
! grep -qF 'foreign bytes' "$base/config/systemd/user/ableton-linkd.service" \
    || fail "Link retained the modified canonical unit"
ok "Link overwrites its generated user service authoritatively"

# Session mode is launched by ableton-linkctl with Live. Its systemd file is
# only preparation for a possible future background mode, so a local collision
# there is reported but cannot reject an otherwise complete session setup.
new_env optional-session-unit
mkdir -p -- "$base/config/systemd/user/ableton-linkd.service"
printf 'Keep\n' | run_link bash "$here/setup-link.sh" enable --mode=session \
    > "$base/out" 2> "$base/err" \
    || { sed -n '1,100p' "$base/err" >&2; fail "optional systemd preparation blocks session Link"; }
grep -qxF 'link_mode=session' "$base/config/ableton-wine/config" \
    || fail "session Link was not saved after optional systemd preparation failed"
grep -qF 'Link will still run with Ableton Live' "$base/err" \
    || fail "optional systemd warning did not state the user-visible outcome"
ok "session Link does not depend on optional systemd preparation"

# Installed-file inventories and legacy restoration data describe generated
# local files only. Damage there cannot stop a fresh Link repair.
new_env malformed-local-records
printf 'not a valid installed-file record\n' \
    > "$base/state/ableton-wine/install-manifest.tsv"
printf 'ambiguous\tlegacy\tdata\textra\n' \
    > "$base/state/ableton-wine/install-prestate.tsv"
mkdir -p -- "$base/state/ableton-wine/install-prestate"
printf 'orphan\n' > "$base/state/ableton-wine/install-prestate/orphan"
run_link bash "$here/setup-link.sh" enable --mode=session \
    > "$base/out" 2> "$base/err" \
    || { sed -n '1,100p' "$base/err" >&2; fail "optional local records block Link repair"; }
grep -qF 'Ableton Link is enabled' "$base/out" \
    || fail "Link did not report the successful repair"
ok "malformed optional local records do not gate Link setup"

# Status is read-only. An interrupted project settings generation can be
# salvaged for reporting without publishing repaired bytes behind the user's
# back or hiding all observable Link state.
new_env status-salvages-project-config
mkdir -p -- "$base/config/ableton-wine"
cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
link_mode=session
linkd=$base/data/ableton-wine/ableton-linkd
interrupted_tail
EOF
cp -- "$base/config/ableton-wine/config" "$base/config.before"
run_link bash "$here/setup-link.sh" status > "$base/out" 2> "$base/err" \
    || fail "an interrupted project settings file hid read-only Link status"
grep -qF 'mode: session (while Ableton Live is running)' "$base/out" \
    || fail "Link status did not use the unambiguous saved mode"
grep -qF 'Installer settings need repair; showing Link status' "$base/err" \
    || fail "Link status did not explain its salvaged settings"
cmp -s -- "$base/config.before" "$base/config/ableton-wine/config" \
    || fail "read-only Link status rewrote interrupted project settings"
ok "Link status salvages interrupted project settings without writing them"

# A valid-looking firewall record is authority only below an exactly marked
# project state root. Canonical paths and familiar bytes in a foreign directory
# cannot authorize host firewall changes or deletion.
new_env foreign-firewall-enable
rm -f -- "$base/state/ableton-wine/.ableton-linux-state"
printf 'ufw-added\n' > "$base/state/ableton-wine/link-firewall"
if run_link bash "$here/setup-link.sh" enable --mode=session \
        > "$base/out" 2> "$base/err"; then
    fail "Link enable claimed a foreign state directory before firewall preparation"
fi
if ! grep -qxF 'ufw-added' "$base/state/ableton-wine/link-firewall" \
   || [ -e "$base/state/ableton-wine/.ableton-linux-state" ]; then
    fail "Link enable changed a foreign firewall record or claimed its directory"
fi

new_env foreign-firewall-disable
rm -f -- "$base/state/ableton-wine/.ableton-linux-state"
printf 'ufw-added\n' > "$base/state/ableton-wine/link-firewall"
cat > "$base/fakebin/ufw" <<'EOF'
#!/bin/sh
: > "${ABLETON_TEST_UFW_RAN:?}"
exit 0
EOF
chmod 755 "$base/fakebin/ufw"
run_link env ABLETON_TEST_UFW_RAN="$base/ufw-ran" \
    bash "$here/setup-link.sh" disable > "$base/out" 2> "$base/err" \
    || fail "a foreign firewall record became a Link-disable gate"
if ! grep -qxF 'ufw-added' "$base/state/ableton-wine/link-firewall" \
   || [ -e "$base/ufw-ran" ]; then
    fail "Link disable trusted or deleted a foreign firewall record"
fi
ok "firewall changes require an exactly marked Ableton Linux state root"

# The installer owns its config bytes. If the six path/policy values are still
# unambiguous, Link rebuilds a malformed generation and preserves those values.
new_env repairable-config
mkdir -p -- "$base/config/ableton-wine" "$base/custom"
printf '#!/bin/sh\nexit 0\n' > "$base/custom/ableton-linkd"
chmod 755 "$base/custom/ableton-linkd"
cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/custom/runtime
prefix=$base/custom/prefix
live_major=12
link_mode=session
linkd=$base/custom/ableton-linkd
unexpected=old-generated-line
EOF
printf 'o\n' | run_link bash "$here/setup-link.sh" disable > /dev/full 2> "$base/err" \
    || { sed -n '1,100p' "$base/err" >&2; fail "closed repair output blocks Link disable"; }
grep -qxF '# ableton-linux installer configuration; managed by the installer' \
    "$base/config/ableton-wine/config" \
    || fail "Link did not rebuild the malformed generated settings"
if ! grep -qxF "linkd=$base/custom/ableton-linkd" "$base/config/ableton-wine/config" \
   || ! grep -qxF 'link_mode=off' "$base/config/ableton-wine/config"; then
    fail "Link rebuild lost safe existing settings or the requested off mode"
fi
grep -qxF '#!/bin/sh' "$base/custom/ableton-linkd" \
    || fail "Link disable changed an external configured helper"
ok "repairable generated settings are rebuilt without losing safe values"

# A Link system failure before the settings mapping leaves that destination
# untouched. There is no config preflight or automatic repair transaction.
new_env repair-before-system-failure
mkdir -p -- "$base/config/ableton-wine" "$base/custom"
printf '#!/bin/sh\nexit 0\n' > "$base/custom/ableton-linkd"
chmod 755 "$base/custom/ableton-linkd"
cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/custom/runtime
prefix=$base/custom/prefix
live_major=12
link_mode=session
linkd=$base/custom/ableton-linkd
obsolete_generated_key=remove-me
EOF
cp -- "$base/config/ableton-wine/config" "$base/config.before"
cat > "$base/fakebin/grep" <<'EOF'
#!/bin/sh
for argument do
    [ "$argument" != /etc/ufw/ufw.conf ] || exit 0
done
exec /usr/bin/grep "$@"
EOF
cat > "$base/fakebin/ufw" <<'EOF'
#!/bin/sh
[ "$1" != status ] || exit 9
exit 0
EOF
printf '#!/bin/sh\nexec "$@"\n' > "$base/fakebin/sudo"
chmod 755 "$base/fakebin/grep" "$base/fakebin/ufw" "$base/fakebin/sudo"
if run_link bash "$here/setup-link.sh" enable --mode=session \
    > "$base/out" 2> "$base/err"; then
    fail "an unreadable active firewall was accepted"
fi
cmp -s -- "$base/config.before" "$base/config/ableton-wine/config" \
    || fail "a Link system failure changed project settings before their mapping"
ok "a Link system failure leaves project settings untouched"

# Settings are generated local integration. If their atomic publication is
# unavailable, the requested firewall/service change remains authoritative and
# the user gets a concrete retry instruction instead of a fake Link failure.
# The settings file is a project file now: when it already exists the run asks
# [O]verwrite all / [K]eep originals / [A]bort once (rule F3), and EOF on stdin
# takes the default, Overwrite all (rule F4), instead of cancelling. Under
# Overwrite all the first mv that touches the file is the backup move (settings
# file -> backup directory), so the mv stub below fails whenever the settings
# path is any operand, not only the destination. A failed backup leaves the
# file untouched and counts as a preference failure; Link must still finish.
new_env optional-link-preference-write
mkdir -p -- "$base/config/ableton-wine"
cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
link_mode=off
linkd=$base/data/ableton-wine/ableton-linkd
interrupted_tail
EOF
cp -- "$base/config/ableton-wine/config" "$base/config.before"
cat > "$base/fakebin/mv" <<'EOF'
#!/bin/sh
for argument do
    [ "$argument" != "${ABLETON_TEST_CONFIG_TARGET:?}" ] || exit 73
done
exec /usr/bin/mv "$@"
EOF
chmod 755 "$base/fakebin/mv"
run_link env ABLETON_TEST_CONFIG_TARGET="$base/config/ableton-wine/config" \
    bash "$here/setup-link.sh" enable --mode=session > "$base/out" 2> "$base/err" \
    < /dev/null \
    || { sed -n '1,100p' "$base/err" >&2; fail "optional Link preference publication became an enable gate"; }
cmp -s -- "$base/config.before" "$base/config/ableton-wine/config" \
    || fail "failed optional preference publication damaged the prior config"
grep -qxF 'none' "$base/state/ableton-wine/link-firewall" \
    || fail "optional preference failure prevented the requested Link system change"
grep -qF 'run the installer again to save the preference' "$base/out" \
    || fail "Link preference warning did not give the user a direct next step"
ok "Link preference persistence is warning-only after the requested system change"

# Keep preserves any existing settings object and lets Link continue.
new_env foreign-config-preservation
mkdir -p -- "$base/config/ableton-wine"
cat > "$base/config/ableton-wine/config" <<EOF
foreign settings
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=session
linkd=$base/data/ableton-wine/ableton-linkd
EOF
cp -- "$base/config/ableton-wine/config" "$base/foreign.before"
printf 'Keep\n' | run_link bash "$here/setup-link.sh" disable \
    > "$base/out" 2> "$base/err" \
    || fail "Keep at a foreign settings file blocked Link disable"
cmp -s -- "$base/foreign.before" "$base/config/ableton-wine/config" \
    || fail "direct Link changed a foreign settings file"
ok "Keep preserves a foreign settings file and continues"

new_env symlink-config-preservation
mkdir -p -- "$base/config/ableton-wine" "$base/personal"
cat > "$base/personal/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=session
linkd=$base/data/ableton-wine/ableton-linkd
obsolete_generated_key=remove-me
EOF
cp -- "$base/personal/config" "$base/symlink-target.before"
ln -s -- "$base/personal/config" "$base/config/ableton-wine/config"
printf 'Keep\n' | run_link bash "$here/setup-link.sh" disable \
    > "$base/out" 2> "$base/err" \
    || fail "Keep at a settings symlink blocked Link disable"
if [ ! -L "$base/config/ableton-wine/config" ] \
   || [ "$(readlink -- "$base/config/ableton-wine/config")" != "$base/personal/config" ] \
   || ! cmp -s -- "$base/symlink-target.before" "$base/personal/config"; then
    fail "direct Link changed a settings symlink or its target"
fi
ok "Keep preserves settings symlinks and their targets"

# Disabling Link changes the mode but leaves the installed support files in
# place for the next enable or installer run.
new_env disable-keeps-support-files
run_link bash "$here/setup-link.sh" enable --mode=session \
    > "$base/enable.out" 2> "$base/enable.err" \
    || fail "Link disable fixture could not first enable Link"
cp -- "$base/data/ableton-wine/ableton-linkd" "$base/linkd.before"
printf 'o\n' | run_link bash "$here/setup-link.sh" disable \
    > "$base/out" 2> "$base/err" \
    || { sed -n '1,100p' "$base/err" >&2; fail "Link disable failed"; }
grep -qxF 'link_mode=off' "$base/config/ableton-wine/config" \
    || fail "Link disable lost the saved off mode"
cmp -s -- "$base/linkd.before" "$base/data/ableton-wine/ableton-linkd" \
    || fail "Link disable changed or removed its installed support helper"
ok "Link disable keeps installed support files while saving the off mode"

# Old Link-setting files are outside the fixed installer mappings. Their
# contents are not interpreted and they are never removed automatically.
new_env exact-legacy-policy-preservation
printf 'configured\n' > "$base/data/ableton-wine/link-configured"
run_link bash "$here/setup-link.sh" enable --mode=session \
    > "$base/enable.out" 2> "$base/enable.err" \
    || fail "an exact old Link setting blocked Link enable"
grep -qxF 'configured' "$base/data/ableton-wine/link-configured" \
    || fail "Link enable changed an old Link-setting file"
printf 'declined\n' > "$base/data/ableton-wine/link-configured"
printf 'o\n' | run_link bash "$here/setup-link.sh" disable \
    > "$base/disable.out" 2> "$base/disable.err" \
    || fail "an exact old Link setting blocked Link disable"
grep -qxF 'declined' "$base/data/ableton-wine/link-configured" \
    || fail "Link disable changed an old Link-setting file"
ok "old Link-setting files are not interpreted or removed"

for foreign_policy_kind in multiline symlink directory; do
    new_env "foreign-legacy-policy-$foreign_policy_kind"
    marker="$base/data/ableton-wine/link-configured"
    case "$foreign_policy_kind" in
        multiline) printf 'configured\npersonal note\n' > "$marker" ;;
        symlink)
            printf 'personal Link note\n' > "$base/personal-link-note"
            ln -s -- "$base/personal-link-note" "$marker" ;;
        directory) mkdir -p -- "$marker"; printf 'personal Link note\n' > "$marker/note" ;;
    esac
    run_link bash "$here/setup-link.sh" disable > "$base/out" 2> "$base/err" \
        || fail "a foreign $foreign_policy_kind Link marker became a disable gate"
    case "$foreign_policy_kind" in
        multiline) grep -qxF 'personal note' "$marker" \
            || fail "Link disable removed a foreign multiline marker" ;;
        symlink)
            if [ ! -L "$marker" ] \
               || ! grep -qxF 'personal Link note' "$base/personal-link-note"; then
                fail "Link disable removed or followed a foreign marker symlink"
            fi ;;
        directory) grep -qxF 'personal Link note' "$marker/note" \
            || fail "Link disable removed a foreign marker directory" ;;
    esac
done
ok "all objects at the old Link-setting path are preserved without gating disable"

# Disabling Link may remove only assets proven by their saved digest or an exact
# historical signature. Canonical-looking paths alone are not ownership proof.
new_env foreign-link-assets
unit="$base/config/systemd/user/ableton-linkd.service"
wants="$base/config/systemd/user/default.target.wants/ableton-linkd.service"
mkdir -p -- "$(dirname -- "$wants")"
printf 'foreign unit\n' > "$unit"
ln -s -- "$unit" "$wants"
printf 'foreign binary\n' > "$base/data/ableton-wine/ableton-linkd"
printf 'original controller\n' > "$base/data/ableton-wine/ableton-linkctl"
printf 'file\t%s\t%s\n' "$base/data/ableton-wine/ableton-linkctl" \
    "$(sha256sum -- "$base/data/ableton-wine/ableton-linkctl" | awk '{print $1}')" \
    > "$base/state/ableton-wine/install-manifest.tsv"
printf 'locally modified controller\n' >> "$base/data/ableton-wine/ableton-linkctl"
printf 'foreign setup helper\n' > "$base/data/ableton-wine/setup-link.sh"
printf 'foreign unit template\n' > "$base/data/ableton-wine/ableton-linkd.service"
run_link bash "$here/setup-link.sh" disable > "$base/out" 2> "$base/err" \
    || { sed -n '1,100p' "$base/err" >&2; fail "foreign Link assets became a disable gate"; }
if ! grep -qxF 'foreign unit' "$unit" || [ ! -L "$wants" ] \
   || ! grep -qxF 'foreign binary' "$base/data/ableton-wine/ableton-linkd" \
   || ! grep -qxF 'locally modified controller' "$base/data/ableton-wine/ableton-linkctl" \
   || ! grep -qxF 'foreign setup helper' "$base/data/ableton-wine/setup-link.sh" \
   || ! grep -qxF 'foreign unit template' "$base/data/ableton-wine/ableton-linkd.service"; then
    fail "Link disable deleted a foreign or modified object from a canonical path"
fi
grep -qxF 'link_mode=off' "$base/config/ableton-wine/config" \
    || fail "preserving foreign Link assets prevented the requested off mode"
ok "Link disable preserves foreign and modified assets while saving the requested mode"

# A caller may stop reading progress output (for example, piping it through
# head). Broken output after the saved result is reporting failure, not an
# installation failure.
new_env post-success-broken-output
if ! run_link bash "$here/setup-link.sh" enable --mode=session 2> "$base/enable.err" \
        | head -n 2 > /dev/null; then
    fail "closed progress output reversed completed Link enable"
fi
grep -qxF 'link_mode=session' "$base/config/ableton-wine/config" \
    || fail "closed progress output lost the enabled mode"
if ! printf 'o\n' | run_link bash "$here/setup-link.sh" disable 2> "$base/disable.err" \
        | head -n 1 > /dev/null; then
    fail "closed progress output reversed completed Link disable"
fi
grep -qxF 'link_mode=off' "$base/config/ableton-wine/config" \
    || fail "closed progress output lost the off mode"
ok "closed progress output cannot reverse completed Link changes"

# The PID record is generated cache, not the Link outcome. A canonical helper
# can be found again by its exact executable when that cache cannot be written;
# stopping it also succeeds even when the stale cache object cannot be removed.
new_env controller-managed-pid-cache
cp -- "$linkd_artifact" "$base/data/ableton-wine/ableton-linkd"
chmod 755 "$base/data/ableton-wine/ableton-linkd"
printf 'file\t%s\t%s\n' "$base/data/ableton-wine/ableton-linkd" \
    "$(sha256sum -- "$base/data/ableton-wine/ableton-linkd" | awk '{print $1}')" \
    > "$base/state/ableton-wine/install-manifest.tsv"
mkdir -p -- "$base/run/ableton-wine/linkd.pid"
run_link env ABLETON_LINK_MODE=session ABLETON_LINKD_LINGER=30 \
    bash "$here/ableton-linkctl" start > "$base/start.out" 2> "$base/start.err" \
    || { sed -n '1,100p' "$base/start.err" >&2; fail "a PID-cache write failure misreported a managed Link start"; }
run_link env ABLETON_LINK_MODE=session bash "$here/ableton-linkctl" status \
    > "$base/status.out" 2> "$base/status.err" \
    || fail "managed Link could not be found without its PID cache"
managed_link_pid="$(sed -n 's/^state: running (process \([0-9][0-9]*\))$/\1/p' "$base/status.out")"
[ -n "$managed_link_pid" ] && kill -0 "$managed_link_pid" 2>/dev/null \
    || fail "managed Link start did not leave the requested process running"
run_link env ABLETON_LINK_MODE=session ABLETON_LINKD_LINGER=30 \
    bash "$here/ableton-linkctl" start > "$base/restart.out" 2> "$base/restart.err" \
    || fail "an already-running managed Link was misreported after PID-cache failure"
run_link env ABLETON_LINK_MODE=session bash "$here/ableton-linkctl" stop \
    > "$base/stop.out" 2> "$base/stop.err" \
    || fail "PID-cache removal failure misreported a successful Link stop"
for _ in {1..50}; do
    kill -0 "$managed_link_pid" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$managed_link_pid" 2>/dev/null \
    && fail "managed Link remained running after the cache-independent stop"
[ -d "$base/run/ableton-wine/linkd.pid" ] \
    || fail "PID-cache failure fixture did not remain in place"
ok "managed Link start and stop follow the process outcome when PID cache writes fail"

# An arbitrary configured helper cannot be rediscovered without the recorded
# PID. If that record cannot be published, reap only the new child and report
# the genuine safety failure instead of leaving an untracked process running.
new_env controller-external-pid-record
external_linkd="$base/external/ableton-linkd"
mkdir -p -- "$(dirname "$external_linkd")" "$base/run/ableton-wine/linkd.pid"
cp -- "$linkd_artifact" "$external_linkd"
chmod 755 "$external_linkd"
if run_link env ABLETON_LINK_MODE=session ABLETON_LINKD="$external_linkd" \
    ABLETON_LINKD_LINGER=30 bash "$here/ableton-linkctl" start \
    > "$base/out" 2> "$base/err"; then
    fail "external Link start succeeded without a safe process record"
fi
grep -qF 'was stopped because its process could not be tracked safely' "$base/err" \
    || fail "external Link PID-record failure did not explain the outcome"
external_link_running=0
for proc in /proc/[0-9]*; do
    [ "$(readlink -f "$proc/exe" 2>/dev/null || true)" != \
        "$(readlink -f "$external_linkd")" ] || external_link_running=1
done
[ "$external_link_running" -eq 0 ] \
    || fail "external Link PID-record failure left its new process running"
ok "external Link is reaped when its only safe process record cannot be written"

# A recognisable helper may contain far more printable data after its marker
# than a pipe buffer can hold. The controller must consume that output before
# matching it, then select a PID from a complete process list.
new_env controller-large-helper
cp -- /bin/sleep "$base/data/ableton-wine/ableton-linkd"
printf '\nableton-linkd: native Ableton Link session anchor and probe\n' \
    >> "$base/data/ableton-wine/ableton-linkd"
awk 'BEGIN { for (i = 0; i < 200000; i++) printf "printable-tail-%06d\\n", i }' \
    >> "$base/data/ableton-wine/ableton-linkd"
chmod 755 "$base/data/ableton-wine/ableton-linkd"
"$base/data/ableton-wine/ableton-linkd" 60 &
large_helper_pid=$!
run_link env ABLETON_LINK_MODE=session bash "$here/ableton-linkctl" status \
    > "$base/out" 2> "$base/err" \
    || { kill "$large_helper_pid" 2>/dev/null || true; fail "large helper output caused a false controller failure"; }
grep -qxF "state: running (process $large_helper_pid)" "$base/out" \
    || { kill "$large_helper_pid" 2>/dev/null || true; fail "controller did not select the owned helper PID"; }
kill "$large_helper_pid" 2>/dev/null || true
wait "$large_helper_pid" 2>/dev/null || true
ok "Link controller fully consumes ownership and PID discovery output"

printf '1..%s\n' "$tests"
