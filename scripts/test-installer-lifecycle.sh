#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-installer-test.XXXXXX")"
# Checks that expect an installer run to succeed redirect its diagnostics into
# the per-case log, so set -e ends the suite on an unexpected non-zero exit
# with no failure line, leaving make's exit code as the only evidence.  Report
# the case and replay what the run wrote.  The shell can exit while the failing
# command's redirections are still applied, so this reports on a saved copy of
# the suite's own stderr rather than into the log it is replaying.
exec {suite_stderr}>&2
reported=0
cleanup()
{
    local code=$?
    if [ "$code" -ne 0 ] && [ "$reported" -eq 0 ]; then
        [ -z "${base:-}" ] || [ ! -s "$base/err" ] \
            || sed -n '1,40p' "$base/err" >&"$suite_stderr"
        printf 'not ok - a command exited %d unexpectedly in %s\n' \
            "$code" "$(basename "${base:-unknown-case}")" >&"$suite_stderr"
    fi
    [ "${ABLETON_KEEP_TEST_WORK:-0}" -eq 0 ] || { printf 'kept test work: %s\n' "$work" >&2; return; }
    rm -rf -- "$work"
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
    reported=1
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

# The suite installs real build artifacts: the exact VERSION runtime from the
# runtime-plan check onwards and dist/ableton-linkd from the link-prestate
# check.  A checkout can update the tracked runtime checksum while retaining
# an ignored, now-stale tarball.  Validate the pair here because its first use
# redirects the diagnostic to a temporary log and set -e would otherwise end
# the suite without a failure line or summary.
. "$here/lib/config.sh"
prerequisite_failed=0
version="$(sed -n '1p' "$root/VERSION")"
runtime="$root/dist/$ABLETON_RUNTIME_NAME-$version.tar.zst"
runtime_checksum="$runtime.sha256"
if [ ! -f "$runtime" ]; then
    echo "!! missing build artifact: dist/$(basename "$runtime")" >&2
    prerequisite_failed=1
elif [ ! -s "$runtime_checksum" ]; then
    echo "!! missing build artifact: dist/$(basename "$runtime_checksum")" >&2
    prerequisite_failed=1
elif ! ( cd "$root/dist" && sha256sum -c --quiet "$(basename "$runtime_checksum")" ) \
        >/dev/null 2>&1; then
    echo "!! invalid build artifact: dist/$(basename "$runtime") does not match its checksum" >&2
    prerequisite_failed=1
fi
[ -f "$root/dist/ableton-linkd" ] || [ -f "$root/bin/ableton-linkd" ] || {
    echo "!! missing build artifact: dist/ableton-linkd" >&2
    prerequisite_failed=1
}
if [ "$prerequisite_failed" -eq 1 ]; then
    echo "!! run ./build.sh first" >&2
    fail "prerequisite build artifacts are valid"
fi
# The sudo password-path checks drive a PTY from Python.  Name the missing
# dependency here; without this the first case fails as a sudo behaviour bug.
command -v python3 >/dev/null 2>&1 \
    || fail "python3 is available for the sudo password-path checks"

new_env()
{
    local name="$1"
    local base="$work/$name"
    mkdir -p -- "$base/home" "$base/tmp"
    printf '%s\n' "$base"
}

run_isolated()
{
    local base="$1"; shift
    env HOME="$base/home" XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data" \
        XDG_STATE_HOME="$base/state" XDG_CACHE_HOME="$base/cache" \
        XDG_RUNTIME_DIR="$base/run" TMPDIR="$base/tmp" \
        ABLETON_SHORTCUTS=preserve ABLETON_MAX_AUDIO_THREADS=off "$@"
}

base="$(new_env sudo-password-paths)"
mkdir -p "$base/fakebin"
cat > "$base/fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    -n)
        shift
        [ "${1:-}" != -- ] || shift
        printf 'probe:%s\n' "$*" >> "${ABLETON_TEST_SUDO_LOG:?}"
        case "${ABLETON_TEST_SUDO_MODE:?}" in
            password) echo 'sudo: a password is required' >&2; exit 1 ;;
            nopasswd) exec "$@" ;;
            denied) exit 7 ;;
            *) exit 2 ;;
        esac ;;
    -S)
        shift
        if [ "${1:-}" = -p ]; then shift 2; fi
        [ "${1:-}" != -- ] || shift
        IFS= read -r password || exit 1
        printf 'password-submitted\n' >> "${ABLETON_TEST_SUDO_LOG:?}"
        [ "$password" = secret ] || exit 1
        exec "$@" ;;
    *) exit 2 ;;
esac
EOF
cat > "$base/run-sudo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$here/lib/config.sh"
status=0
case "\${ABLETON_TEST_SUDO_COMMAND:?}" in
    success) ableton_sudo_run_bounded "\${ABLETON_TEST_SUDO_SECONDS:?}" sh -c \
        'printf "command-ran\\n" >> "\${ABLETON_TEST_SUDO_LOG:?}"' || status=\$? ;;
    sleep) ableton_sudo_run_bounded "\${ABLETON_TEST_SUDO_SECONDS:?}" sleep 10 || status=\$? ;;
    failure) ableton_sudo_run_bounded "\${ABLETON_TEST_SUDO_SECONDS:?}" sh -c 'exit 7' || status=\$? ;;
esac
exit "\$status"
EOF
cat > "$base/pty-check.py" <<'PY'
import errno
import os
import pty
import select
import sys
import termios
import time

expected = int(os.environ["ABLETON_TEST_EXPECT_STATUS"])
expect_prompt = os.environ["ABLETON_TEST_EXPECT_PROMPT"] == "1"
input_text = os.environ.get("ABLETON_TEST_PTY_INPUT", "")
pid, fd = pty.fork()
if pid == 0:
    os.execvpe(sys.argv[1], sys.argv[1:], os.environ)

output = bytearray()
prompt = b"[sudo] password (input hidden, "
sent = False
hidden = False
status = None
deadline = time.monotonic() + 15
while status is None:
    if time.monotonic() > deadline:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        raise SystemExit("PTY check exceeded its deadline")
    ready, _, _ = select.select([fd], [], [], 0.05)
    if ready:
        try:
            chunk = os.read(fd, 4096)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            chunk = b""
        output.extend(chunk)
    if prompt in output and not sent:
        time.sleep(0.05)
        hidden = not bool(termios.tcgetattr(fd)[3] & termios.ECHO)
        if input_text:
            os.write(fd, input_text.encode())
        sent = True
    waited, raw_status = os.waitpid(pid, os.WNOHANG)
    if waited == pid:
        status = os.waitstatus_to_exitcode(raw_status)

echo_restored = bool(termios.tcgetattr(fd)[3] & termios.ECHO)
sys.stdout.buffer.write(output)
if status != expected:
    raise SystemExit(f"expected exit {expected}, got {status}")
if expect_prompt != (prompt in output):
    raise SystemExit("sudo prompt presence did not match the expected path")
if expect_prompt and not hidden:
    raise SystemExit("terminal echo remained enabled at the password prompt")
if not echo_restored:
    raise SystemExit("terminal echo was not restored after sudo returned")
if input_text and input_text.strip().encode() in output:
    raise SystemExit("sudo password was echoed to the terminal")
PY
chmod +x "$base/fakebin/sudo" "$base/run-sudo"

run_sudo_pty()
{
    local mode="$1" command="$2" seconds="$3" input="$4" expected="$5" prompt="$6"
    : > "$base/sudo.log"
    env HOME="$base/home" PATH="$base/fakebin:$PATH" \
        ABLETON_TEST_SUDO_LOG="$base/sudo.log" ABLETON_TEST_SUDO_MODE="$mode" \
        ABLETON_TEST_SUDO_COMMAND="$command" ABLETON_TEST_SUDO_SECONDS="$seconds" \
        ABLETON_TEST_PTY_INPUT="$input" ABLETON_TEST_EXPECT_STATUS="$expected" \
        ABLETON_TEST_EXPECT_PROMPT="$prompt" \
        python3 "$base/pty-check.py" "$base/run-sudo" > "$base/out" 2> "$base/err"
}

run_sudo_pty password success 5 $'secret\n' 0 1 \
    || fail "sudo accepts one hidden password and runs the exact command"
if ! grep -qxF 'password-submitted' "$base/sudo.log" \
   || ! grep -qxF 'command-ran' "$base/sudo.log"; then
    fail "password authentication did not execute the command in the same sudo invocation"
fi
ok "sudo accepts a hidden password without relying on a credential timestamp"

run_sudo_pty nopasswd success 5 '' 0 0 \
    || fail "command-specific NOPASSWD runs without a generic authentication prompt"
! grep -q '^password-submitted$' "$base/sudo.log" \
    || fail "the NOPASSWD path submitted a password"
grep -qxF 'command-ran' "$base/sudo.log" || fail "the NOPASSWD path did not run the command"
ok "command-specific NOPASSWD runs without prompting"

run_sudo_pty denied failure 5 '' 7 0 \
    || fail "a policy or command failure returns without an authentication retry"
[ "$(grep -c '^probe:' "$base/sudo.log")" -eq 1 ] \
    || fail "a non-authentication failure retried the sudo command"
ok "sudo policy and command failures are not retried as password failures"

if ! run_sudo_pty password success 1 '' 124 1; then
    sed -n '1,80p' "$base/out" >&2
    sed -n '1,80p' "$base/err" >&2
    fail "sudo password input has a bounded timeout and restores terminal echo"
fi
! grep -q '^password-submitted$' "$base/sudo.log" \
    || fail "a timed-out prompt started the privileged command"
ok "sudo password input times out without starting the command"

run_sudo_pty password sleep 1 $'secret\n' 124 1 \
    || fail "the privileged command keeps its own timeout after password input"
grep -qxF 'password-submitted' "$base/sudo.log" \
    || fail "the command-timeout path did not complete password input"
ok "sudo password input and the privileged command have separate bounds"

base="$(new_env realtime-destdir)"
mkdir -p "$base/fakebin"
cat > "$base/fakebin/sudo" <<'EOF'
#!/bin/sh
: > "${ABLETON_TEST_SUDO_CALLED:?}"
exit 99
EOF
chmod +x "$base/fakebin/sudo"
run_isolated "$base" env PATH="$base/fakebin:$PATH" DESTDIR="$base/stage" \
    ABLETON_TEST_SUDO_CALLED="$base/sudo-called" \
    bash "$here/setup-realtime.sh" > "$base/out" 2> "$base/err" \
    || fail "realtime staging works without host privileges"
[ -f "$base/stage/etc/security/limits.d/90-ableton-rt.conf" ] \
    && [ -f "$base/stage/etc/sysctl.d/90-ableton-rt.conf" ] \
    || fail "realtime staging did not write both drop-ins"
[ ! -e "$base/sudo-called" ] || fail "realtime staging requested sudo"
ok "realtime staging changes only DESTDIR and never requests sudo"

base="$(new_env help)"
run_isolated "$base" bash "$here/installer.sh" --help > "$base/out"
grep -q 'runtime install' "$base/out" || fail "help exposes subcommands"
ok "help exposes subcommands"

base="$(new_env live11-repair)"
max_settings="$base/prefix/drive_c/users/test/AppData/Roaming/Cycling '74/Max 8/Settings"
mkdir -p -- "$max_settings"
printf 'WINE REGISTRY Version 2\n' > "$base/prefix/system.reg"
printf 'format=1\nprefix=%s\n' "$base/prefix" > "$base/prefix/.ableton-linux-prefix"
printf 'stale Max preferences\n' > "$max_settings/maxpreferences.maxpref"
run_isolated "$base" bash "$here/installer.sh" prefix repair-live11 \
    --prefix "$base/prefix" >"$base/out" 2>"$base/err" \
    || fail "public Live 11 repair command failed"
if [ -e "$max_settings/maxpreferences.maxpref" ] \
   || ! compgen -G "$max_settings/maxpreferences.maxpref.bak-*" >/dev/null; then
    fail "public Live 11 repair did not move stale preferences aside"
fi
grep -qF 'Max preferences moved aside' "$base/out" \
    || fail "public Live 11 repair did not report its result"
[ ! -e "$base/state" ] \
    || fail "public Live 11 repair created persistent state solely to lock"
ok "public Live 11 repair honors the selected prefix without Wine or PipeWire"

base="$(new_env maintenance-architecture)"
mkdir -p "$base/fakebin"
cat > "$base/fakebin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
    -m) echo aarch64 ;;
    *) exec /usr/bin/uname "$@" ;;
esac
EOF
chmod +x "$base/fakebin/uname"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/installer.sh" link status >"$base/status.out" 2>"$base/status.err" \
    || fail "read-only Link status inherits an install-only architecture refusal"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/installer.sh" prefix repair-live11 --dry-run \
    >"$base/repair.out" 2>"$base/repair.err" \
    || fail "Live 11 repair plan inherits an install-only architecture refusal"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/installer.sh" link enable --dry-run \
    >"$base/enable.out" 2>"$base/enable.err"; then
    fail "Link installation accepts an incompatible architecture"
fi
grep -qF 'this command requires x86_64' "$base/enable.err" \
    || fail "architecture refusal does not identify the failing requirement"
ok "maintenance commands remain available off x86_64 while install commands refuse"

base="$(new_env link-status-read-only)"
mkdir -p "$base/data/ableton-wine" "$base/state/ableton-wine"
printf 'format=1\nowner=ableton-linux\n' > "$base/state/ableton-wine/.ableton-linux-state"
printf 'none\n' > "$base/state/ableton-wine/link-firewall"
cat > "$base/data/ableton-wine/ableton-linkctl" <<'EOF'
#!/bin/sh
: > "${ABLETON_TEST_LINKCTL_RAN:?}"
EOF
chmod +x "$base/data/ableton-wine/ableton-linkctl"
run_isolated "$base" env ABLETON_TEST_LINKCTL_RAN="$base/linkctl-ran" \
    bash "$here/installer.sh" link status >"$base/out" 2>"$base/err" \
    || fail "Link status failed while ignoring a modified controller"
[ ! -e "$base/linkctl-ran" ] \
    || fail "read-only Link status executed the installed controller"
grep -qF 'state: not installed' "$base/out" \
    || fail "Link status did not report missing daemon state directly"
ok "Link status reads state without executing an installed controller"

base="$(new_env xdg-parent-symlinks)"
mkdir -p -- "$base/real-config" "$base/real-state"
ln -s -- "$base/real-config" "$base/config-link"
ln -s -- "$base/real-state" "$base/state-link"
# shellcheck disable=SC2016
env HOME="$base/home" XDG_CONFIG_HOME="$base/config-link" \
    XDG_STATE_HOME="$base/state-link" XDG_DATA_HOME="$base/data" \
    XDG_CACHE_HOME="$base/cache" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        ableton_config_init
        ableton_write_config
        ableton_mark_state_home
    ' _ "$here"
[ -L "$base/config-link" ] && [ -L "$base/state-link" ] \
    && [ -f "$base/real-config/ableton-wine/config" ] \
    && [ -f "$base/real-state/ableton-wine/.ableton-linux-state" ] \
    || fail "resolved XDG roots changed their user-owned symlink projections"
ok "resolved XDG roots use real target directories without replacing parent symlinks"

# make-installer's own [5/5] self-check runs --help, which returns before the
# delegation, so only this case guards the header's exit path.
base="$(new_env run-header)"
kit="$base/kit"
mkdir -p "$kit/scripts"
printf '#!/bin/sh\nexit "${STUB_EXIT:-0}"\n' > "$kit/scripts/installer.sh"
tar -cf "$base/payload.tar" -C "$kit" .
sed -e 's/@VERSION@/suite-check/g' \
    -e "s/@PAYLOAD_SHA@/$(sha256sum "$base/payload.tar" | awk '{print $1}')/g" \
    "$here/setup-run-header.sh" > "$base/kit.run"
cat "$base/payload.tar" >> "$base/kit.run"
run_isolated "$base" env STUB_EXIT=0 sh "$base/kit.run" >"$base/out" 2>"$base/err" \
    || fail "a successful delegated install exits zero through the .run header"
status=0
run_isolated "$base" env STUB_EXIT=42 sh "$base/kit.run" >>"$base/out" 2>>"$base/err" || status=$?
[ "$status" -eq 42 ] || fail "a delegated install failure code passes through the .run header"
! find "$base/tmp" -mindepth 1 -maxdepth 1 -name 'ableton-installer.*' 2>/dev/null | grep -q . \
    || fail "the .run header removes its work directory"
ok "the .run header propagates the delegated installer exit code"

base="$(new_env noninteractive)"
if run_isolated "$base" bash "$here/installer.sh" >"$base/out" 2>"$base/err"; then
    fail "noninteractive install requires an explicit payload"
fi
grep -q -- '--live-installer FILE or --skip-live-install' "$base/err" || fail "noninteractive failure explains payload policy"
[ ! -e "$base/config" ] && [ ! -e "$base/data" ] && [ ! -e "$base/state" ] || fail "failed parse is mutation-free"
ok "noninteractive payload failure is mutation-free"

base="$(new_env conflict)"
if run_isolated "$base" bash "$here/installer.sh" install --no-link --link=off --skip-live-install >"$base/out" 2>"$base/err"; then
    fail "conflicting Link options fail"
fi
grep -q 'conflicts' "$base/err" || fail "conflict is reported"
ok "conflicting compatibility and current options fail during parsing"

base="$(new_env parser-model)"
if run_isolated "$base" bash "$here/installer.sh" install --skip-live-install \
    --live-installer "$base/payload.exe" --prefix "$base/one" --prefix "$base/two" \
    >"$base/out" 2>"$base/err"; then
    fail "duplicate immutable options are accepted"
fi
[ ! -e "$base/config" ] && [ ! -e "$base/state" ] || fail "duplicate-option failure mutates state"
run_isolated "$base" bash "$here/installer.sh" --prefix --uninstall --dry-run \
    >"$base/legacy.out" 2>"$base/legacy.err"
grep -q 'delete validated prefix' "$base/legacy.out" \
    || fail "legacy uninstall prefix alias depends on argument order"
ok "immutable options reject duplicates and legacy parsing is order-independent"

base="$(new_env early-transaction-cleanup)"
mkdir -p "$base/config/pipeasio/config.ini"
if run_isolated "$base" bash "$here/installer.sh" link disable \
    >"$base/out" 2>"$base/err"; then
    fail "unsafe pre-transaction configuration is accepted"
fi
if find "$base/state/ableton-wine/transactions" -mindepth 1 -maxdepth 1 \
    -name 'installer.*' -print -quit 2>/dev/null | grep -q .; then
    fail "a failure before transaction handlers are installed leaks its directory"
fi
grep -qF 'current PipeASIO configuration is unsafe' "$base/err" \
    || fail "early transaction refusal does not name the unsafe configuration"
ok "failures during initial snapshots retire the unstarted transaction"

base="$(new_env link-snapshot-cleanup)"
mkdir -p "$base/data/ableton-wine" "$base/state/ableton-wine" \
    "$base/fakebin" "$base/txn"
printf 'format=1\nowner=ableton-linux\n' > "$base/state/ableton-wine/.ableton-linux-state"
printf 'none\n' > "$base/state/ableton-wine/link-firewall"
printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkctl"
printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkd"
cat > "$base/fakebin/cp" <<'EOF'
#!/bin/sh
for argument do
    case "$argument" in
        */.link-snapshot.*/firewall|*/.link-enable.*/firewall) exit 9 ;;
    esac
done
exec /usr/bin/cp "$@"
EOF
chmod +x "$base/data/ableton-wine/ableton-linkctl" \
    "$base/data/ableton-wine/ableton-linkd" "$base/fakebin/cp"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/setup-link.sh" snapshot "$base/txn" \
    >"$base/snapshot.out" 2>"$base/snapshot.err"; then
    fail "Link transaction snapshot succeeds after a copy failure"
fi
[ ! -e "$base/txn/link" ] \
    || fail "failed Link transaction snapshot publishes incomplete rollback state"
! find "$base/txn" -mindepth 1 -maxdepth 1 -name '.link-snapshot.*' \
    -print -quit | grep -q . \
    || fail "failed Link transaction snapshot leaks its staging directory"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/setup-link.sh" enable --mode=session \
    >"$base/enable.out" 2>"$base/enable.err"; then
    fail "Link enable succeeds after its recovery snapshot copy fails"
fi
! find "$base/state/ableton-wine" -mindepth 1 -maxdepth 1 \
    -name '.link-enable.*' -print -quit | grep -q . \
    || fail "failed Link enable leaks an unstarted recovery snapshot"
ok "failed Link snapshots never publish or retain incomplete recovery state"

base="$(new_env runtime-plan)"
run_isolated "$base" bash "$here/installer.sh" --runtime-only --runtime-root "$base/runtime" --dry-run >"$base/out" 2>"$base/err"
grep -q 'replace runtime tree atomically' "$base/out" || fail "runtime plan contains runtime"
! grep -q 'write launcher:' "$base/out" || fail "runtime plan excludes integration"
! grep -q 'write Link binary:' "$base/out" || fail "runtime plan excludes Link"
grep -q 'apply the runtime PipeASIO panel record to existing launchers' "$base/out" \
    || fail "runtime plan describes PipeASIO launcher reconciliation"
[ ! -e "$base/runtime" ] && [ ! -e "$base/config" ] && [ ! -e "$base/state" ] || fail "runtime plan mutates no target"
ok "runtime-only plan contains only the runtime component"

base="$(new_env runtime-install)"
if run_isolated "$base" bash "$here/installer.sh" runtime install \
    --runtime-root "$base/runtime" --yes >"$base/out" 2>"$base/err"; then
    [ -x "$base/runtime/bin/wine" ] && [ -f "$base/runtime/.ableton-linux-runtime" ] \
        || fail "runtime install promotes a marked runtime"
    [ ! -e "$base/config" ] && [ ! -e "$base/data" ] && [ ! -e "$base/state" ] \
        && [ ! -e "$base/cache" ] && [ ! -e "$base/prefix" ] \
        || fail "runtime install writes outside the selected runtime root"
    ok "runtime install writes only the runtime tree"
elif grep -Eq 'PipeWire is unavailable|PipeWire compatibility cannot be checked' "$base/err"; then
    [ ! -e "$base/runtime" ] && [ ! -e "$base/config" ] && [ ! -e "$base/state" ] \
        || fail "failed PipeWire gate mutated runtime-install targets"
    ok "runtime install refuses safely when its native PipeWire probe cannot connect"
else
    sed -n '1,80p' "$base/err" >&2
    fail "runtime install failed for an unrelated reason"
fi

base="$(new_env runtime-conflict)"
if run_isolated "$base" bash "$here/installer.sh" --runtime-only --no-link \
    --runtime-root "$base/runtime" --dry-run >"$base/out" 2>"$base/err"; then
    fail "runtime mode rejects a Link policy"
fi
[ ! -e "$base/runtime" ] && [ ! -e "$base/config" ] && [ ! -e "$base/state" ] \
    || fail "runtime option conflict mutates no state"
ok "runtime-only rejects unrelated Link options before mutation"

base="$(new_env compat-plan)"
run_isolated "$base" bash "$here/installer.sh" --no-launch --dry-run >"$base/out" 2>"$base/err"
grep -q 'write launcher:' "$base/out" || fail "no-launch still means skip Live payload only"
grep -q 'final Link policy: off' "$base/out" || fail "no-launch defaults Link off"
! grep -Eq 'write Link binary:|write Link controller/setup/unit assets:' "$base/out" \
    || fail "no-launch unexpectedly stages Link assets"
! grep -Eq 'write ownership-marked user unit|launchers start session daemon|enable/start the owned user unit' "$base/out" \
    || fail "no-launch plans a Link service action"
grep -q 'deprecated' "$base/err" || fail "compatibility warning is printed"
ok "no-launch compatibility excludes Link assets and service enablement"

base="$(new_env update-policy)"
mkdir -p "$base/config/ableton-wine" "$base/prefix"
printf 'registry\n' > "$base/prefix/system.reg"
cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=off
linkd=$base/data/ableton-wine/ableton-linkd
EOF
run_isolated "$base" env ABLETON_DPI_MODE=preserve bash "$here/installer.sh" update --dry-run >"$base/out" 2>"$base/err"
grep -q 'final Link policy: off' "$base/out" || fail "update preserves Link opt-out"
! grep -q 'write Link binary:' "$base/out" || fail "opted-out update excludes Link assets"
ok "update preserves the persistent Link opt-out"

base="$(new_env update-no-prefix)"
if run_isolated "$base" bash "$here/installer.sh" update --dry-run >"$base/out" 2>"$base/err"; then
    fail "update without an existing prefix fails"
fi
grep -q 'update needs an existing prefix' "$base/err" || fail "update without a prefix names the remedy"
! grep -q -- '--refresh' "$base/err" || fail "update failure avoids the component --refresh flag"
[ ! -e "$base/config" ] && [ ! -e "$base/state" ] || fail "update without a prefix mutates state"
ok "update without a prefix fails fast in installer vocabulary"

base="$(new_env mismatch)"
printf 'Ableton Live 11 installer\n' > "$base/Ableton_Live_11_Installer.exe"
if run_isolated "$base" bash "$here/installer.sh" install --live-installer "$base/Ableton_Live_11_Installer.exe" \
    --live-major 12 --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" >"$base/out" 2>"$base/err"; then
    fail "payload-major mismatch fails"
fi
grep -q 'appears to be Live 11' "$base/err" || fail "payload mismatch is explicit"
[ ! -e "$base/runtime" ] && [ ! -e "$base/prefix" ] && [ ! -e "$base/config" ] || fail "payload mismatch mutates no installation state"
ok "Live payload major is validated before installation"

base="$(new_env prefix-quiesce)"
mkdir -p "$base/runtime/bin" "$base/prefix"
# 124 is timeout's TERM verdict, so the stub reports an expired wait without the
# suite spending the wait's wall clock on it.
cat > "$base/runtime/bin/wineserver" <<'EOF'
#!/usr/bin/env bash
printf '%s prefix=%s\n' "$1" "${WINEPREFIX-unset}" >> "${ABLETON_TEST_LOG:?}"
case "$1" in
    -w)
        [ "${ABLETON_TEST_WAIT_EXIT:-0}" -eq 0 ] || exit "${ABLETON_TEST_WAIT_EXIT}"
        [ ! -e "${ABLETON_TEST_BUSY:?}" ] || exit 124
        exit 0 ;;
    -k)
        [ "${ABLETON_TEST_UNKILLABLE:-0}" -eq 1 ] || rm -f -- "${ABLETON_TEST_BUSY:?}"
        exit 0 ;;
esac
exit 2
EOF
cat > "$base/run-quiesce" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$here/lib/lifecycle.sh"
ableton_config_init
status=0
ableton_prefix_quiesce "\$@" || status=\$?
printf 'rc=%s\n' "\$status"
EOF
chmod +x "$base/runtime/bin/wineserver" "$base/run-quiesce"
quiesce_calls()
{
    awk '{print $1}' "$base/log" | tr '\n' ' '
}
run_quiesce()
{
    local assignments=()
    while [ "$#" -gt 0 ] && [[ "$1" = *=* ]]; do assignments+=("$1"); shift; done
    : > "$base/log"
    run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_TEST_LOG="$base/log" ABLETON_TEST_BUSY="$base/busy" "${assignments[@]}" \
        bash "$base/run-quiesce" "$@" >"$base/out" 2>"$base/err"
}

rm -f "$base/busy"
run_quiesce
grep -qx 'rc=0' "$base/out" || fail "a quiet prefix reports success"
[ "$(quiesce_calls)" = "-w " ] || fail "a quiet prefix is waited for exactly once"
grep -qx -- "-w prefix=$base/prefix" "$base/log" || fail "the wait names the configured prefix"
ok "a quiet prefix is waited for once and never stopped"

: > "$base/busy"
run_quiesce
grep -qx 'rc=0' "$base/out" || fail "a stopped straggler reports success"
[ "$(quiesce_calls)" = "-w -k -w " ] || fail "a held prefix is stopped and waited for again"
grep -q 'holding the prefix open' "$base/out" || fail "stopping the prefix is reported"
ok "a straggler holding the prefix open is stopped, not made fatal"

: > "$base/busy"
run_quiesce ABLETON_TEST_UNKILLABLE=1
grep -qx 'rc=3' "$base/out" || fail "a surviving straggler is reported as still busy"
[ "$(quiesce_calls)" = "-w -k -w " ] || fail "a surviving straggler is not waited for a third time"
ok "a straggler that survives the stop is reported, and the wait stays bounded"

# setup-prefix.sh continues past a straggler and must stop on a wait that could not
# run, so the two cannot share an exit code.
rm -f "$base/busy"
run_quiesce ABLETON_TEST_WAIT_EXIT=1
grep -qx 'rc=1' "$base/out" || fail "a wait that failed keeps its own exit code"
[ "$(quiesce_calls)" = "-w " ] || fail "a failed wait does not stop the prefix"
ok "a failed wait is distinguishable from a straggler that survived the stop"

rm -f "$base/busy"
run_quiesce ABLETON_TEST_WAIT_EXIT=127
grep -qx 'rc=127' "$base/out" || fail "a wait that cannot run keeps its exit code"
[ "$(quiesce_calls)" = "-w " ] || fail "a wait that cannot run does not stop the prefix"
ok "only an expired wait stops the prefix; any other failure is passed back"

# setup-prefix.sh waits on its staging prefix, which is not the configured one.
: > "$base/busy"
run_quiesce "$base/runtime" "$base/staging-prefix"
grep -qx 'rc=0' "$base/out" || fail "an explicitly named prefix is quiesced"
grep -qx -- "-k prefix=$base/staging-prefix" "$base/log" || fail "the stop names the prefix it was given"
! grep -q -- "prefix=$base/prefix\$" "$base/log" || fail "a named prefix displaces the configured one"
ok "the runtime and prefix a caller names override the configured pair"

# The payload step's own wait, on the promoted prefix.  Every sub-script is stubbed
# so install_live_payload is reached with a wineserver whose -w never returns.
base="$(new_env payload-wait)"
kit="$base/kit"
mkdir -p "$kit/scripts/lib" "$kit/bin" "$base/runtime/bin"
cp -- "$here/installer.sh" "$kit/scripts/"
cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" "$here/lib/live-options.sh" \
    "$here/lib/manifest.sh" "$here/lib/pipeasio.sh" "$kit/scripts/lib/"
cat > "$kit/bin/pipewire-version-probe" <<'EOF'
#!/bin/sh
printf 'client=1.4.2\ndaemon=1.4.2\n'
EOF
cat > "$kit/scripts/install.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'component %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
exit 0
EOF
cat > "$kit/scripts/setup-prefix.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'prefix %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
case " $* " in
    *' --preflight-commit '*|*' --commit '*|*' --preflight-rollback '*|*' --rollback '*) exit 0 ;;
esac
mkdir -p -- "${ABLETON_WINEPREFIX:?}"
printf 'registry\n' > "${ABLETON_WINEPREFIX}/system.reg"
EOF
cat > "$kit/scripts/setup-link.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'link %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
EOF
cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
printf 'wine %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
EOF
cat > "$base/runtime/bin/wineserver" <<'EOF'
#!/bin/sh
printf 'wineserver %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
case "${1:-}" in
    -w) exit "${ABLETON_TEST_WAIT_EXIT:-0}" ;;
esac
EOF
chmod 755 "$kit/scripts/"*.sh "$kit/bin/pipewire-version-probe" "$base/runtime/bin/"*
printf 'Ableton Live 12 Suite Installer\n' > "$base/Ableton Live 12 Suite Installer.exe"

run_payload_install()
{
    : > "$base/calls.log"
    rm -rf -- "$base/prefix" "$base/config" "$base/state" "$base/data"
    run_isolated "$base" env ABLETON_TEST_CALL_LOG="$base/calls.log" "$@" \
        bash "$kit/scripts/installer.sh" install \
            --live-installer "$base/Ableton Live 12 Suite Installer.exe" \
            --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
        >"$base/out" 2>"$base/err"
}

# 124 is timeout's TERM verdict: the wait ran out with a process still in the prefix.
run_payload_install ABLETON_TEST_WAIT_EXIT=124 || fail "an expired payload wait fails the install"
grep -q 'OK: install completed' "$base/out" || fail "an expired payload wait leaves the install incomplete"
! grep -q 'wineserver -k' "$base/calls.log" || fail "the payload step stops the promoted prefix"
grep -q 'the install is complete' "$base/out" || fail "an expired payload wait goes unreported"
grep -qF -- "$base/runtime/bin/wineserver -k" "$base/out" \
    || fail "the report withholds the command that ends the prefix"
! grep -q 'End every program' "$base/out" "$base/err" \
    || fail "a non-interactive install offers to end the prefix"
ok "an expired payload wait reports the straggler, stops nothing, and still completes"

for image in AbletonPushCpl.exe tusbaudiocplapp.exe AbletonAudioCpl.exe MicrosoftEdgeUpdate.exe; do
    grep -qF "/im $image" "$base/calls.log" \
        || fail "the payload step does not end $image by name"
done
ok "the payload step ends the images it starts, each named exactly"

# A program the user is running in the promoted prefix: named, never ended, and
# never ended by --yes either.  --yes answers for the installer's own files, and
# a Max sharing this prefix is not one of them.
cp /bin/sleep "$base/runtime/bin/wine-client"
env WINEPREFIX="$base/prefix" bash -c \
    'exec -a "C:\\some-daw.exe" "$1" 600' _ "$base/runtime/bin/wine-client" &
payload_holder=$!
sleep 0.2
run_payload_install ABLETON_TEST_WAIT_EXIT=124 \
    || fail "an expired payload wait fails the install with a holder present"
kill -0 "$payload_holder" 2>/dev/null || fail "the payload step ended a program in the prefix"
kill "$payload_holder" 2>/dev/null || true
wait "$payload_holder" 2>/dev/null || true
grep -q 'some-daw.exe (pid' "$base/out" || fail "the payload step does not name what holds the prefix"
! grep -q 'wineserver -k' "$base/calls.log" \
    || fail "--yes ends a program the user is running in the prefix"
! grep -q 'End every program' "$base/out" "$base/err" \
    || fail "--yes is treated as an answer about the prefix"
ok "a program in the prefix is named at the end of an install, and --yes does not end it"

run_payload_install || fail "a quiet payload wait fails the install"
! grep -q 'the install is complete\.' "$base/out" || fail "a quiet prefix is reported as busy"
ok "a quiet prefix after the payload reports nothing"

# Link setup runs after the Live payload. An expired sudo prompt stops the
# firewall step. The installer must preserve Live. It must show the command that
# resumes Link setup. Ctrl-C sends SIGINT while the installer waits. The Link
# process then exits with status 130.
cat > "$kit/scripts/setup-link.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'link %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
[ "${1:-}" = enable ] || exit 0
case "${ABLETON_TEST_LINK_ENABLE_EXIT:-0}" in
    int) kill -INT "$PPID"; exit 130 ;;
    *) exit "${ABLETON_TEST_LINK_ENABLE_EXIT:-0}" ;;
esac
EOF
run_failed_link_install()
{
    : > "$base/calls.log"
    rm -rf -- "$base/prefix" "$base/config" "$base/state" "$base/data"
    run_isolated "$base" env ABLETON_TEST_CALL_LOG="$base/calls.log" ABLETON_TEST_LINK_ENABLE_EXIT="$1" \
        bash "$kit/scripts/installer.sh" install \
            --live-installer "$base/Ableton Live 12 Suite Installer.exe" \
            --link=always --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
        >"$base/out" 2>"$base/err"
}
run_failed_link_install 1 || fail "the install must finish after Link setup failure"
grep -q 'OK: install completed' "$base/out" || fail "the output must confirm install completion"
! grep -q 'prefix --rollback' "$base/calls.log" || fail "the installer must preserve the prefix"
grep -qF 'Run this command to complete Link setup: installer link enable --mode=always' "$base/err" \
    || fail "the output must include the Link recovery command and mode"
grep -qF 'Link: setup stopped (run: installer link enable --mode=always)' "$base/out" \
    || fail "the summary must report the stopped Link setup"
ok "Link setup failure reports the resume command and preserves the install"

run_failed_link_install int || fail "the install must finish after Ctrl-C stops Link setup"
grep -q 'OK: install completed' "$base/out" || fail "the output must confirm install completion after Ctrl-C"
! grep -q 'prefix --rollback' "$base/calls.log" || fail "the installer must preserve the prefix after Ctrl-C"
grep -qF 'Run this command to complete Link setup: installer link enable --mode=always' "$base/err" \
    || fail "the output must include the Link recovery command after Ctrl-C"
ok "Ctrl-C stops Link setup and preserves the install"

# An update preserves the prefix and commits the new runtime after the same
# Link setup failure.
: > "$base/calls.log"
run_isolated "$base" env ABLETON_TEST_CALL_LOG="$base/calls.log" ABLETON_TEST_LINK_ENABLE_EXIT=1 \
    bash "$kit/scripts/installer.sh" update --yes >"$base/out" 2>"$base/err" \
    || fail "the update must finish after Link setup failure"
grep -q 'OK: update completed' "$base/out" || fail "the output must confirm update completion"
! grep -q -- '--rollback' "$base/calls.log" || fail "the installer must preserve the update"
grep -q 'Link setup stopped; the update continues' "$base/err" \
    || fail "the output must report the stopped Link setup"
grep -qF 'Link: setup stopped (run: installer link enable --mode=always)' "$base/out" \
    || fail "the update summary must report the stopped Link setup"
ok "Link setup failure reports the resume action and preserves the update"

base="$(new_env launcher-preflight)"
mkdir -p "$base/runtime/bin" "$base/prefix"
cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
printf 'wine %s\n' "$*" >> "${ABLETON_TEST_LOG:?}"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/wineserver"
chmod +x "$base/runtime/bin/wine" "$base/runtime/bin/wineserver"
printf 'registry\n' > "$base/prefix/system.reg"
: > "$base/wine.log"
if run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_TEST_LOG="$base/wine.log" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "launcher without Live fails"
fi
# taskkill is a wine process: on an empty prefix it would start a server and a
# pair of services, which the teardown would then report as the holder.
! grep -q 'taskkill' "$base/wine.log" || fail "teardown starts wine on a prefix with nothing in it"
grep -q 'no Ableton Live installation' "$base/err" || fail "launcher reports missing Live"
[ ! -e "$base/state" ] && [ ! -e "$base/data" ] && [ ! -e "$base/config" ] && [ ! -e "$base/run" ] \
    || fail "launcher preflight mutates no machine state"
ok "launcher validates runtime, prefix, and Live before mutation"

# The teardown runs on every exit, including the ones that gave up because the
# prefix was not there.  wine builds a prefix at whatever path it is handed, so
# a refusal must not leave one behind.
base="$(new_env launcher-missing-prefix)"
mkdir -p "$base/runtime/bin"
cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
mkdir -p -- "${WINEPREFIX:?}/drive_c"
printf 'registry\n' > "${WINEPREFIX:?}/system.reg"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/wineserver"
chmod +x "$base/runtime/bin/wine" "$base/runtime/bin/wineserver"
if run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/absent-prefix" bash "$here/ableton-live" \
    >"$base/out" 2>"$base/err"; then
    fail "launcher accepts a missing prefix"
fi
[ ! -e "$base/absent-prefix" ] || fail "teardown builds a prefix the launcher refused to use"
ok "a launcher that refuses a missing prefix creates nothing on its way out"

base="$(new_env max-coexist)"
mkdir -p "$base/runtime/bin" "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program" "$base/run"
cp /bin/sleep "$base/runtime/bin/wine-client"
cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
printf 'wine %s\n' "$*" >> "${ABLETON_TEST_LOG:?}"
exit 0
EOF
cat > "$base/runtime/bin/wineserver" <<'EOF'
#!/bin/sh
printf 'wineserver %s\n' "$*" >> "${ABLETON_TEST_LOG:?}"
exit 0
EOF
cat > "$base/runtime/bin/wineboot" <<'EOF'
#!/bin/sh
printf 'wineboot %s\n' "$*" >> "${ABLETON_TEST_LOG:?}"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/winepath"
chmod +x "$base/runtime/bin/"*
printf 'registry\n' > "$base/prefix/system.reg"
printf 'registry\n' > "$base/prefix/user.reg"
printf 'exe\n' > "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe"
: > "$base/wine.log"
# 600s, not 60: the launcher waits out its observability timeout before the
# teardown even runs, so a short-lived stand-in expires mid-case and the
# coexistence it is meant to prove goes untested.
env WINEPREFIX="$base/prefix" bash -c 'exec -a "C:\\Program Files\\Cycling '\''74\\Max 9\\Max.exe" "$1" 600' _ "$base/runtime/bin/wine-client" &
max_pid=$!
sleep 0.1
run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINK_MODE=off ABLETON_POWER=off ABLETON_RT=off ABLETON_THEME_MODE=preserve \
    ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    ABLETON_TEST_LOG="$base/wine.log" bash "$here/ableton-live" >"$base/out" 2>"$base/err" || true
kill -0 "$max_pid" 2>/dev/null || fail "cold Live launch preserves Max"
kill "$max_pid" 2>/dev/null || true
wait "$max_pid" 2>/dev/null || true
! grep -Eq 'wineserver -k|wineboot' "$base/wine.log" || fail "busy prefix avoids kill and boot"
ok "cold Live launch neither kills Max nor boots its busy prefix"

# The teardown: a session ends the agents it leaves behind, by name, so the
# wineserver can exit on its own - and never by ending the prefix, which would
# take a Max or a second Live with it.
for image in AbletonPushCpl.exe tusbaudiocplapp.exe AbletonAudioCpl.exe MicrosoftEdgeUpdate.exe; do
    grep -qF "/im $image" "$base/wine.log" \
        || fail "the launcher leaves $image running after the session"
done
ok "the launcher ends the agents a session leaves behind, and stops the prefix for none of them"

# Teardown confirms the outcome instead of assuming it: with another program
# still in the prefix, it reports why the wineserver stays rather than ending it.
grep -q 'Other unknown processes were left running' "$base/err" \
    || fail "teardown does not report a prefix left in use"
grep -q 'Max\.exe (pid' "$base/err" \
    || fail "teardown names the holder by something other than its Windows image"
grep -qF "wineserver -k" "$base/err" \
    || fail "teardown names a holder without saying how to end it"
ok "teardown verifies the prefix came down, and names the holder and the remedy"

# An agent the teardown just ended is not a program the user is running.
# taskkill returns before its targets exit, so a fixed pause classifies one that
# is still on its way out as an unknown holder and tells the user to end their
# own prefix.  The stand-in holds one of the agent names and outlives the stop.
base="$(new_env teardown-agent-settle)"
mkdir -p "$base/runtime/bin" "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program" "$base/run"
cp /bin/sleep "$base/runtime/bin/wine-client"
cat > "$base/runtime/bin/wine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$base/wine.log"
exit 0
EOF
for tool in wineserver wineboot winepath; do
    printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/$tool"
done
chmod +x "$base/runtime/bin/"*
printf 'registry\n' > "$base/prefix/system.reg"
: > "$base/wine.log"
env WINEPREFIX="$base/prefix" bash -c \
    'exec -a "C:\\Program Files\\Ableton\\USB Audio Driver\\x64\\AbletonAudioCpl.exe" "$1" 20' \
    _ "$base/runtime/bin/wine-client" &
agent_pid=$!
sleep 0.1
run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    bash -c ". \"$here/lib/config.sh\"; ableton_config_init; . \"$here/lib/lifecycle.sh\"; \
        ableton_session_teardown \"$base/runtime\" \"$base/prefix\" 1" \
    >"$base/out" 2>"$base/err" || true
kill "$agent_pid" 2>/dev/null || true
wait "$agent_pid" 2>/dev/null || true
# The stub wine ends nothing, so the grace runs out with the agent still there.
# That is the failure this teardown exists to prevent, so it must be named as an
# agent that did not stop - never as the user's own program, and never excused as
# a helper that "will quit on its own", which is the one thing it does not do.
! grep -q 'Other unknown processes' "$base/err" \
    || fail "an agent the teardown just ended is reported as the user's own program"
! grep -q 'will quit on its own' "$base/err" \
    || fail "an agent that outlived the stop is excused as a helper that leaves"
grep -q 'did not stop and is holding the prefix' "$base/err" \
    || fail "an agent that outlived the stop goes unreported"
grep -q 'AbletonAudioCpl.exe (pid' "$base/err" \
    || fail "the stuck agent is not named"
grep -qF -- "$base/runtime/bin/wineserver -k" "$base/err" \
    || fail "the stuck agent is named without saying how to end it"
ok "an agent that outlived the stop is named as stuck, not excused and not blamed on the user"

# A helper this project installed outlives the window on purpose - learnheal.exe
# heals the Learn View pane after Live has gone - so the launcher must hand the
# terminal back rather than wait on one, and must not report it as a holder.
base="$(new_env vendored-helper-holder)"
mkdir -p "$base/runtime/bin" "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program" \
    "$base/data/ableton-wine" "$base/run"
cp /bin/sleep "$base/runtime/bin/wine-client"
for tool in wine wineserver wineboot; do
    printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/$tool"
done
printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/winepath"
chmod +x "$base/runtime/bin/"*
printf 'registry\n' > "$base/prefix/system.reg"
printf 'registry\n' > "$base/prefix/user.reg"
printf 'exe\n' > "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe"
# The data home is what makes it ours: the image name resolves to a file we installed.
printf 'helper\n' > "$base/data/ableton-wine/learnheal.exe"
env WINEPREFIX="$base/prefix" \
    bash -c 'exec -a "C:\\learnheal.exe" "$1" 600' _ "$base/runtime/bin/wine-client" &
helper_pid=$!
sleep 0.3
start_s=$SECONDS
run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
    ABLETON_LINK_MODE=off ABLETON_POWER=off ABLETON_RT=off ABLETON_THEME_MODE=preserve \
    ABLETON_DPI_MODE=preserve ABLETON_UI_FONT=preserve ABLETON_TEXT_SMOOTHING=preserve \
    bash "$here/ableton-live" >"$base/out" 2>"$base/err" || true
kill -0 "$helper_pid" 2>/dev/null || fail "the launcher ended a helper it installed"
! grep -q 'unknown processes' "$base/err" \
    || fail "teardown reports this project's own helper as a holder"
grep -q 'Ableton Live closed; a background helper' "$base/err" \
    || fail "teardown leaves a wineserver up without naming the app or saying why"
ok "a helper we installed keeps running through a session, is not reported, and is explained"

# Timed against the teardown itself, not the launcher around it: the launcher's
# own observability wait dwarfs the grace period, so a lost early return would
# not move the total.
cat > "$base/time-teardown" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$here/lib/config.sh"
ableton_config_init
. "$here/lib/lifecycle.sh"
start=\$SECONDS
ableton_session_teardown >/dev/null 2>&1 || true
printf '%s\n' "\$((SECONDS - start))"
EOF
chmod +x "$base/time-teardown"
helper_only_s="$(run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" bash "$base/time-teardown")"
env WINEPREFIX="$base/prefix" \
    bash -c 'exec -a "C:\\some-daw.exe" "$1" 600' _ "$base/runtime/bin/wine-client" &
unknown_pid=$!
sleep 0.3
unknown_s="$(run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" bash "$base/time-teardown")"
kill "$helper_pid" "$unknown_pid" 2>/dev/null || true
wait "$helper_pid" "$unknown_pid" 2>/dev/null || true
# Neither case may poll: a look costs a walk of every pid on the machine, so the
# difference between them is the report, not the wall clock.
[ "$helper_only_s" -le 10 ] && [ "$unknown_s" -le 10 ] \
    || fail "teardown polls instead of looking once (${helper_only_s}s, ${unknown_s}s)"
ok "teardown looks once whoever holds the prefix (${helper_only_s}s, ${unknown_s}s)"

# Every walker takes the prefix, so setup-prefix.sh inside its staging window
# reports on the prefix it named rather than on the user's.  The wait itself was
# always right; the /proc walk behind the progress tick was not.
base="$(new_env named-prefix-walk)"
mkdir -p "$base/runtime/bin" "$base/prefix" "$base/staging-prefix" "$base/data/ableton-wine" "$base/run"
cp /bin/sleep "$base/runtime/bin/wine-client"
chmod +x "$base/runtime/bin/"*
cat > "$base/name-holders" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$here/lib/config.sh"
ableton_config_init
. "$here/lib/lifecycle.sh"
ableton_prefix_unknown_holders "\$@" | cut -f2 | sort | paste -sd, -
EOF
chmod +x "$base/name-holders"
env WINEPREFIX="$base/prefix" \
    bash -c 'exec -a "C:\\configured-app.exe" "$1" 600' _ "$base/runtime/bin/wine-client" &
configured_pid=$!
env WINEPREFIX="$base/staging-prefix" \
    bash -c 'exec -a "C:\\staging-app.exe" "$1" 600' _ "$base/runtime/bin/wine-client" &
staging_pid=$!
sleep 0.3
named_walk="$(run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" bash "$base/name-holders" \
    "$base/runtime" "$base/staging-prefix")"
default_walk="$(run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" \
    ABLETON_WINEPREFIX="$base/prefix" bash "$base/name-holders")"
kill "$configured_pid" "$staging_pid" 2>/dev/null || true
wait "$configured_pid" "$staging_pid" 2>/dev/null || true
[ "$named_walk" = 'staging-app.exe' ] \
    || fail "a named prefix is walked as the configured one (got '$named_walk')"
[ "$default_walk" = 'configured-app.exe' ] \
    || fail "the configured prefix is not walked by default (got '$default_walk')"
ok "the /proc walk follows the prefix a caller names, not the configured one"

# A refusal must not reach into the prefix: with another session's client still
# running, a launcher that declines to start ends nothing and reports nothing.  The
# refusals are checked one per launcher stage, because they are spread through the
# launcher - the held bring-up lock is among the last, well below every guard.
# The holder image matters: ableton-live only takes the bring-up lock on a cold
# start, so a Live-shaped holder sends it down the warm path and past the refusal
# under test.  Each case names the holder that reaches the stage it means to check.
refusal_leaves_busy_prefix_alone()
{
    local case_name="$1" launcher="$2" expect="$3" holder_image="$4"
    local install="${5:-}" hold_lock="${6:-0}"
    local base holder_pid coordinator lock_fd
    base="$(new_env "$case_name")"
    mkdir -p "$base/runtime/bin" "$base/prefix"
    cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
printf 'wine %s\n' "$*" >> "${ABLETON_TEST_LOG:?}"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/wineserver"
    chmod +x "$base/runtime/bin/wine" "$base/runtime/bin/wineserver"
    printf 'registry\n' > "$base/prefix/system.reg"
    case "$install" in
        max)
            mkdir -p "$base/prefix/drive_c/Program Files/Cycling '74/Max 9"
            printf 'exe\n' > "$base/prefix/drive_c/Program Files/Cycling '74/Max 9/Max.exe" ;;
        live)
            mkdir -p "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program"
            printf 'exe\n' > "$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe" ;;
    esac
    cp /bin/sleep "$base/runtime/bin/wine-client"
    env WINEPREFIX="$base/prefix" bash -c \
        'exec -a "$2" "$1" 600' _ "$base/runtime/bin/wine-client" "$holder_image" &
    holder_pid=$!
    sleep 0.1
    if [ "$hold_lock" -eq 1 ]; then
        coordinator="$(run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" \
            ABLETON_WINEPREFIX="$base/prefix" bash -c \
            ". \"$here/lib/config.sh\"; ableton_config_init; . \"$here/lib/lifecycle.sh\"; ableton_lifecycle_runtime_dir")"
        mkdir -p -- "$coordinator"
        exec {lock_fd}>"$coordinator/bring-up.lock"
        flock -n "$lock_fd" || fail "$case_name could not hold the bring-up lock"
    fi
    : > "$base/wine.log"
    if run_isolated "$base" env ABLETON_WINE_ROOT="$base/runtime" ABLETON_WINEPREFIX="$base/prefix" \
        ABLETON_TEST_LOG="$base/wine.log" bash "$here/$launcher" >"$base/out" 2>"$base/err"; then
        fail "$case_name refuses to start"
    fi
    if [ "$hold_lock" -eq 1 ]; then
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&-
    fi
    kill -0 "$holder_pid" 2>/dev/null || fail "$case_name ended a process in the prefix"
    kill "$holder_pid" 2>/dev/null
    wait "$holder_pid" 2>/dev/null || true
    grep -q "$expect" "$base/err" || fail "$case_name does not say why it refused"
    ! grep -q 'taskkill' "$base/wine.log" \
        || fail "$case_name ends agents in a prefix another session is using"
    ! grep -q 'unknown processes' "$base/err" \
        || fail "$case_name reports a teardown it never performed"
}

live_holder='C:\\ProgramData\\Ableton\\Live 12 Suite\\Program\\Ableton Live 12 Suite.exe'
other_holder='C:\\some-daw.exe'
refusal_leaves_busy_prefix_alone refusal-max-absent  max9         'no Max 9 installation'      "$live_holder"
refusal_leaves_busy_prefix_alone refusal-live-absent ableton-live 'no Ableton Live installation' "$other_holder"
refusal_leaves_busy_prefix_alone refusal-max-lock    max9         'bringing this prefix up'    "$live_holder" max  1
refusal_leaves_busy_prefix_alone refusal-live-lock   ableton-live 'bringing this prefix up'    "$other_holder" live 1
ok "a launcher that refuses to start leaves a busy prefix alone, at every stage"

base="$(new_env foreign-runtime)"
mkdir -p "$base/runtime/bin"
cp /bin/sleep "$base/runtime/bin/wine-client"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
env WINEPREFIX="$base/foreign-prefix" "$base/runtime/bin/wine-client" 60 &
foreign_pid=$!
sleep 0.1
if run_isolated "$base" bash "$here/installer.sh" runtime install \
    --runtime-root "$base/runtime" --yes >"$base/out" 2>"$base/err"; then
    fail "runtime update proceeds while a foreign prefix uses it"
fi
kill -0 "$foreign_pid" 2>/dev/null || fail "runtime update killed a foreign prefix client"
kill "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
if grep -q 'used by another Wine prefix' "$base/err"; then
    ok "runtime lifecycle refuses, and never signals, a foreign prefix client"
elif grep -Eq 'PipeWire is unavailable|PipeWire compatibility cannot be checked' "$base/err"; then
    ok "PipeWire preflight refuses before a foreign runtime client can be signalled"
else
    fail "runtime refusal did not explain either lifecycle or PipeWire preflight"
fi

base="$(new_env transaction)"
mkdir -p "$base/txn" "$base/data/ableton-wine"
printf 'before\n' > "$base/data/ableton-wine/detect-theme.sh"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$base/txn" bash -c '
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_txn_snapshot "$2/detect-theme.sh"
    ableton_txn_snapshot "$2/detect-scale.sh"
    after="$(mktemp)"; printf "after\n" > "$after"
    new="$(mktemp)"; printf "new\n" > "$new"
    ableton_txn_expect "$2/detect-theme.sh" "$(ableton_regular_source_token "$after")"
    ableton_txn_expect "$2/detect-scale.sh" "$(ableton_regular_source_token "$new")"
    printf "after\n" > "$2/detect-theme.sh"
    printf "new\n" > "$2/detect-scale.sh"
    ableton_txn_rollback_files "$3"
' _ "$here" "$base/data/ableton-wine" "$base/txn"
[ "$(cat "$base/data/ableton-wine/detect-theme.sh")" = before ] \
    && [ ! -e "$base/data/ableton-wine/detect-scale.sh" ] || fail "file transaction rolls back"
ok "file transaction restores overwritten files and removes new files"

base="$(new_env prefix-host-transaction)"
mkdir -p "$base/txn/prefix-host" "$base/config/pipeasio"
printf 'before\n' > "$base/config/pipeasio/config.ini"
run_isolated "$base" env ABLETON_TRANSACTION_DIR="$base/txn/prefix-host" bash -c '
    . "$1/lib/config.sh"
    ableton_config_init
    . "$1/lib/manifest.sh"
    ableton_txn_init
    ableton_txn_snapshot "$2/config.ini"
    after="$(mktemp)"; printf "after\n" > "$after"
    ableton_txn_expect "$2/config.ini" "$(ableton_regular_source_token "$after")"
' _ "$here" "$base/config/pipeasio"
printf 'after\n' > "$base/config/pipeasio/config.ini"
run_isolated "$base" bash "$here/setup-prefix.sh" --rollback "$base/txn"
[ "$(cat "$base/config/pipeasio/config.ini")" = before ] \
    || fail "prefix rollback leaves a pre-promotion host mutation behind"
ok "prefix rollback restores host files even before prefix promotion"

base="$(new_env uninstall-prestate)"
foreign_icon="$base/data/icons/hicolor/scalable/apps/live-suite.svg"
mkdir -p "$(dirname "$foreign_icon")" "$base/fakebin"
printf 'foreign icon\n' > "$foreign_icon"
cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$base/fakebin/systemctl"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/install.sh" --integration-only >"$base/install.out" 2>"$base/install.err"
grep -q '<svg' "$foreign_icon" || fail "integration did not replace the collision fixture"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" --keep-prefix --yes >"$base/out" 2>"$base/err"
[ "$(cat "$foreign_icon")" = 'foreign icon' ] || fail "uninstall did not restore overwritten pre-install file"
ok "uninstall restores a pre-existing file overwritten by integration"

base="$(new_env user-config)"
user_config="$base/config/pipeasio/config.ini"
mkdir -p "$(dirname "$user_config")" "$base/state/ableton-wine" "$base/fakebin"
printf 'format=1\nowner=ableton-linux\n' > "$base/state/ableton-wine/.ableton-linux-state"
printf 'seeded\n' > "$user_config"
printf 'config\t%s\t%s\n' "$user_config" "$(sha256sum "$user_config" | awk '{print $1}')" \
    > "$base/state/ableton-wine/install-manifest.tsv"
printf 'user buffer setting\n' > "$user_config"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
chmod +x "$base/fakebin/systemctl"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" \
    --keep-prefix --yes >"$base/out" 2>"$base/err"
[ "$(cat "$user_config")" = 'user buffer setting' ] \
    || fail "uninstall removes user-modified seeded configuration"
grep -q 'kept user-modified configuration' "$base/out" \
    || fail "preserved user configuration is not reported"
ok "uninstall preserves and de-owns user-modified seeded configuration"

base="$(new_env modified-owned)"
run_isolated "$base" bash "$here/install.sh" --integration-only >"$base/first.out" 2>"$base/first.err"
printf '\n# user change\n' >> "$base/data/ableton-wine/detect-scale.sh"
if run_isolated "$base" bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err"; then
    fail "integration overwrites a modified managed file"
fi
grep -qF '# user change' "$base/data/ableton-wine/detect-scale.sh" || fail "failed update lost managed-file modification"
grep -q 'The installer kept the managed path because its saved checksum differs' "$base/err" \
    || fail "changed managed file refusal gives the reason"
ok "update refuses to overwrite a locally modified managed file"

# install.sh installs the version stamp inside an "if !" condition, which
# suppresses set -e, so ableton_install_file must return non-zero for the
# refusal to stop the run.
base="$(new_env modified-version-stamp)"
run_isolated "$base" bash "$here/install.sh" --integration-only >"$base/first.out" 2>"$base/first.err"
printf 'tampered\n' > "$base/data/ableton-wine/VERSION"
if run_isolated "$base" bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err"; then
    fail "integration overwrites a modified version stamp"
fi
grep -qxF tampered "$base/data/ableton-wine/VERSION" \
    || fail "failed update lost the version stamp modification"
grep -q 'The installer kept the managed path because its saved checksum differs' "$base/err" \
    || fail "changed version stamp refusal gives the reason"
ok "update refuses to overwrite a locally modified version stamp"

# Issues #211 and #251 showed that launcher checksum drift triggered rollback.
# Cover every primary launcher, including Max and the handler copies used by
# runtime repair. At update time, each launcher may be a regular file or a
# symlink. The update replaces either form and records the installed checksum.
base="$(new_env stale-launchers)"
mkdir -p "$base/home/.wine-ableton/drive_c/Program Files/Cycling '74/Max 9"
printf 'exe\n' > "$base/home/.wine-ableton/drive_c/Program Files/Cycling '74/Max 9/Max.exe"
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/first.out" 2>"$base/first.err"
manifest="$base/state/ableton-wine/install-manifest.tsv"
launcher_paths=(
    "$base/home/.local/bin/ableton-live"
    "$base/data/applications/ableton-live.desktop"
    "$base/data/ableton-wine/$ABLETON_PROTOCOL_DESKTOP_ID"
    "$base/data/applications/$ABLETON_PROTOCOL_DESKTOP_ID"
    "$base/data/ableton-wine/$ABLETON_AUZ_DESKTOP_ID"
    "$base/data/applications/$ABLETON_AUZ_DESKTOP_ID"
    "$base/home/.local/bin/max9"
    "$base/data/applications/max9.desktop"
    "$base/data/applications/wine-protocol-c74max.desktop"
)
launcher_copy="$base/home/ableton-live-before-update"
mv "${launcher_paths[0]}" "$launcher_copy"
ln -s "$launcher_copy" "${launcher_paths[0]}"
for launcher in "${launcher_paths[@]:1}"; do
    printf '\n# local launcher drift\n' >> "$launcher"
done
for launcher in "${launcher_paths[@]}"; do
    recorded="$(awk -F '\t' -v p="$launcher" '$2==p { print $3 }' "$manifest")"
    current="$(
        if [ -L "$launcher" ]; then
            { printf 'symlink\0'; readlink -n -- "$launcher"; } | sha256sum | awk '{print $1}'
        else
            sha256sum "$launcher" | awk '{print $1}'
        fi
    )"
    [ -n "$recorded" ] && [ "$recorded" != "$current" ] \
        || fail "launcher fixture requires different saved and current checksums: $launcher"
done
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err" \
    || { sed -n '1,80p' "$base/err" >&2; fail "launcher checksum drift aborted integration"; }
for launcher in "${launcher_paths[@]}"; do
    [ -f "$launcher" ] && [ ! -L "$launcher" ] \
        || fail "update did not install a regular launcher at $launcher"
    ! grep -qF '# local launcher drift' "$launcher" \
        || fail "update left launcher drift in $launcher"
    recorded="$(awk -F '\t' -v p="$launcher" '$1=="file" && $2==p { print $3 }' "$manifest")"
    current="$(sha256sum "$launcher" | awk '{print $1}')"
    [ "$recorded" = "$current" ] \
        || fail "update saved an incorrect launcher checksum for $launcher"
    grep -qF "The installer replaced a launcher because its saved checksum differed: $launcher" "$base/out" \
        || fail "update omitted the launcher replacement message for $launcher"
done
[ -L "${launcher_paths[0]}.bak" ] \
    && [ "$(readlink -- "${launcher_paths[0]}.bak")" = "$launcher_copy" ] \
    || fail "Live launcher backup is not the exact displaced symlink"
for launcher in "${launcher_paths[@]:1}"; do
    grep -qF '# local launcher drift' "${launcher}.bak" \
        || fail "launcher backup does not contain the displaced file: ${launcher}.bak"
done
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/noop.out" 2>"$base/noop.err" \
    || fail "no-op launcher update failed"
[ -L "${launcher_paths[0]}.bak" ] \
    && [ "$(readlink -- "${launcher_paths[0]}.bak")" = "$launcher_copy" ] \
    || fail "no-op update replaced the prior Live launcher backup"
for launcher in "${launcher_paths[@]:1}"; do
    grep -qF '# local launcher drift' "${launcher}.bak" \
        || fail "no-op update replaced the prior launcher backup: ${launcher}.bak"
done
cmp -s -- "$here/ableton-live" "${launcher_paths[0]}" \
    || fail "update did not install the current Live launcher"
cmp -s -- "$here/max9" "$base/home/.local/bin/max9" \
    || fail "update did not install the current Max launcher"
grep -qF 'Ableton Live launcher for the patched Wine stack' "$launcher_copy" \
    || fail "replacing the launcher symlink changed its referent"
ok "update replaces every primary launcher after checksum drift"

rollback_launcher="$base/data/applications/max9.desktop"
printf '\n# launcher before genuine failure\n' >> "$rollback_launcher"
printf 'previous adjacent backup\n' > "${rollback_launcher}.bak"
mkdir -p "$base/fakebin"
cat > "$base/fakebin/update-desktop-database" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$base/fakebin/update-desktop-database"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/install.sh" --integration-only >"$base/failure.out" 2>"$base/failure.err"; then
    fail "desktop database failure unexpectedly succeeded"
fi
grep -qF '# launcher before genuine failure' "$rollback_launcher" \
    || fail "genuine failure did not restore the displaced launcher"
grep -qxF 'previous adjacent backup' "${rollback_launcher}.bak" \
    || fail "genuine failure did not restore the previous launcher backup"
grep -qF 'failed to update the desktop application database' "$base/failure.err" \
    || fail "genuine failure did not report its actual cause"
ok "genuine failure restores both the launcher and its previous adjacent backup"

# When the custom data root matches the XDG applications root, one invocation
# reaches the handler twice. The second projection recognises the installed
# launcher from the first projection and preserves the original adjacent backup.
base="$(new_env overlapping-launcher-roots)"
overlap_apps="$base/data/applications"
overlap_launcher="$overlap_apps/$ABLETON_PROTOCOL_DESKTOP_ID"
mkdir -p "$overlap_apps"
printf '[Desktop Entry]\nName=Original overlapping handler\n' > "$overlap_launcher"
cp -- "$overlap_launcher" "$base/original-handler"
run_isolated "$base" env ABLETON_DATA_HOME="$overlap_apps" \
    bash "$here/install.sh" --integration-only >"$base/out" 2>"$base/err" \
    || { sed -n '1,80p' "$base/err" >&2; fail "overlapping launcher roots aborted integration"; }
cmp -s -- "$base/original-handler" "${overlap_launcher}.bak" \
    || fail "the second handler projection replaced the original adjacent backup"
grep -q '^Exec=.*/ableton-live %u$' "$overlap_launcher" \
    || fail "overlapping launcher roots did not install the canonical handler"
ok "duplicate launcher projections preserve the original adjacent backup"

# A fresh install writes the desktop entry before Live exists. The first Live
# start adds the edition name, icon, and window class. The saved checksum still
# describes the original entry. The next update must replace the entry.
base="$(new_env stale-live-desktop)"
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/first.out" 2>"$base/first.err"
live_desktop="$base/data/applications/ableton-live.desktop"
manifest="$base/state/ableton-wine/install-manifest.tsv"
! grep -q '^StartupWMClass=' "$live_desktop" \
    || fail "fresh integration guessed a Live window class before Live existed"
mkdir -p "$base/home/.wine-ableton/drive_c/ProgramData/Ableton/Live 12 Suite/Program"
printf 'exe\n' \
    > "$base/home/.wine-ableton/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe"
sed -i 's/^Name=.*/Name=Ableton Live 12 Suite/' "$live_desktop"
printf 'StartupWMClass=ableton live 12 suite.exe\n' >> "$live_desktop"
recorded="$(awk -F '\t' -v p="$live_desktop" '$1=="file" && $2==p { print $3 }' "$manifest")"
current="$(sha256sum "$live_desktop" | awk '{print $1}')"
[ -n "$recorded" ] && [ "$recorded" != "$current" ] \
    || fail "launcher-updated desktop fixture requires different saved and current checksums"
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "update rejected the launcher-updated managed desktop entry"; }
grep -qxF 'Name=Ableton Live 12 Suite' "$live_desktop" \
    || fail "update left the old Live desktop name"
grep -qxF 'StartupWMClass=ableton live 12 suite.exe' "$live_desktop" \
    || fail "update left the old Live desktop window class"
[ "$(grep -c '^StartupWMClass=' "$live_desktop")" -eq 1 ] \
    || fail "updated Live desktop entry contains duplicate window classes"
wmclass_line="$(grep -n '^StartupWMClass=' "$live_desktop" | cut -d: -f1)"
mime_line="$(grep -n '^MimeType=' "$live_desktop" | cut -d: -f1)"
[ "$wmclass_line" -lt "$mime_line" ] \
    || fail "updated Live desktop entry does not use canonical template order"
recorded="$(awk -F '\t' -v p="$live_desktop" '$1=="file" && $2==p { print $3 }' "$manifest")"
current="$(sha256sum "$live_desktop" | awk '{print $1}')"
[ "$recorded" = "$current" ] \
    || fail "update did not refresh the Live desktop ownership digest"
grep -qF "The installer replaced a launcher because its saved checksum differed: $live_desktop" "$base/out" \
    || fail "update omitted the desktop entry refresh message"
grep -qF 'StartupWMClass=ableton live 12 suite.exe' "${live_desktop}.bak" \
    || fail "Live desktop backup does not contain the displaced entry"
ok "update refreshes a launcher-updated Live desktop entry"

# Uninstall must accept the same launcher-updated entry. The entry still uses
# the project launcher.
base="$(new_env uninstall-launcher-updated-desktop)"
mkdir -p "$base/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
chmod +x "$base/fakebin/systemctl"
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/first.out" 2>"$base/first.err"
live_desktop="$base/data/applications/ableton-live.desktop"
sed -i 's/^Name=.*/Name=Ableton Live 12 Suite/' "$live_desktop"
printf 'StartupWMClass=ableton live 12 suite.exe\n' >> "$live_desktop"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" \
    --keep-prefix --yes >"$base/out" 2>"$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "uninstall rejected the launcher-updated managed desktop entry"; }
[ ! -e "$live_desktop" ] || fail "uninstall kept the launcher-updated desktop entry"
grep -qF "removed $live_desktop" "$base/out" \
    || fail "uninstall omitted the desktop entry removal message"
ok "uninstall removes a launcher-updated managed Live desktop entry"

# The allowance holds only while the Exec line routes through this project's
# launcher; one re-pointed at another program is hand-made and stays kept,
# even when a leftover comment still mentions the launcher path.
base="$(new_env uninstall-repointed-desktop)"
mkdir -p "$base/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
chmod +x "$base/fakebin/systemctl"
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/first.out" 2>"$base/first.err"
live_desktop="$base/data/applications/ableton-live.desktop"
orig_exec="$(grep '^Exec=' "$live_desktop")"
sed -i 's|^Exec=.*|Exec=/usr/bin/other-app %f|' "$live_desktop"
printf '# was: %s\n' "$orig_exec" >> "$live_desktop"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" \
    --keep-prefix --yes >"$base/out" 2>"$base/err"; then
    fail "uninstall removed a desktop entry re-pointed away from the launcher"
fi
[ -e "$live_desktop" ] || fail "uninstall removed the re-pointed desktop entry"
grep -qF "kept modified file $live_desktop" "$base/err" \
    || fail "kept re-pointed desktop entry is not reported"
ok "uninstall keeps a desktop entry re-pointed away from the launcher"

# The transaction snapshots a launcher symlink before replacement and leaves
# its referent unchanged.
base="$(new_env symlinked-live-desktop)"
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/first.out" 2>"$base/first.err"
live_desktop="$base/data/applications/ableton-live.desktop"
mv "$live_desktop" "$base/home/live-entry-copy.desktop"
ln -s "$base/home/live-entry-copy.desktop" "$live_desktop"
run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err" \
    || fail "symlinked Live desktop entry aborted integration"
[ -f "$live_desktop" ] && [ ! -L "$live_desktop" ] \
    || fail "update did not replace the symlinked Live desktop entry"
[ -f "$base/home/live-entry-copy.desktop" ] \
    || fail "replacing the desktop symlink changed its referent"
[ -L "${live_desktop}.bak" ] \
    && [ "$(readlink -- "${live_desktop}.bak")" = "$base/home/live-entry-copy.desktop" ] \
    || fail "Live desktop backup is not the displaced symlink"
grep -qF "The installer replaced a launcher because its saved checksum differed: $live_desktop" "$base/out" \
    || fail "symlinked desktop entry replacement was not reported"
ok "update replaces a symlinked managed Live desktop entry"

base="$(new_env link-prestate)"
foreign_linkd="$base/data/ableton-wine/ableton-linkd"
mkdir -p "$(dirname "$foreign_linkd")" "$base/fakebin"
printf '#!/bin/sh\necho foreign\n' > "$foreign_linkd"
chmod +x "$foreign_linkd"
cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$base/fakebin/systemctl"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/install.sh" --link-assets-only >"$base/install.out" 2>"$base/install.err"
grep -qF 'native Ableton Link session anchor' < <(strings "$foreign_linkd") \
    || fail "Link asset install did not replace the collision fixture"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/setup-link.sh" disable >"$base/out" 2>"$base/err"
grep -qF 'echo foreign' "$foreign_linkd" || fail "Link disable did not restore overwritten pre-install binary"
ok "Link disable restores a pre-existing binary overwritten by Link assets"

base="$(new_env uninstall-safety)"
if run_isolated "$base" env ABLETON_WINEPREFIX=/ ABLETON_WINE_ROOT="$base/runtime" \
    bash "$here/uninstall.sh" --delete-prefix --yes --dry-run >"$base/out" 2>"$base/err"; then
    fail "unsafe prefix target is rejected"
fi
grep -q 'unsafe prefix target' "$base/err" || fail "unsafe target reason is reported"
ok "uninstall rejects root as a prefix target before mutation"

base="$(new_env uninstall-symlink)"
mkdir -p "$base/victim" "$base/runtime"
printf 'registry\n' > "$base/victim/system.reg"
printf 'format=1\n' > "$base/victim/.ableton-linux-prefix"
ln -s "$base/victim" "$base/prefix-link"
if run_isolated "$base" env ABLETON_WINEPREFIX="$base/prefix-link" ABLETON_WINE_ROOT="$base/runtime" \
    bash "$here/uninstall.sh" --delete-prefix --yes --dry-run >"$base/out" 2>"$base/err"; then
    fail "symlink prefix target is accepted"
fi
[ -f "$base/victim/system.reg" ] || fail "symlink rejection changed its target"
ok "uninstall rejects a symlinked custom prefix before mutation"

base="$(new_env uninstall-link)"
mkdir -p "$base/data/ableton-wine/lib" "$base/config/ableton-wine" \
    "$base/state/ableton-wine" "$base/run/ableton-wine" "$base/runtime/bin" "$base/prefix" "$base/fakebin"
printf 'format=1\nowner=ableton-linux\n' > "$base/state/ableton-wine/.ableton-linux-state"
cp "$here/lib/config.sh" "$base/data/ableton-wine/lib/config.sh"
cp "$here/lib/lifecycle.sh" "$base/data/ableton-wine/lib/lifecycle.sh"
cp "$here/lib/live-options.sh" "$base/data/ableton-wine/lib/live-options.sh"
cp "$here/lib/manifest.sh" "$base/data/ableton-wine/lib/manifest.sh"
cp "$here/lib/pipeasio.sh" "$base/data/ableton-wine/lib/pipeasio.sh"
cp "$here/ableton-linkctl" "$base/data/ableton-wine/ableton-linkctl"
cp "$here/setup-link.sh" "$base/data/ableton-wine/setup-link.sh"
cp /bin/sleep "$base/data/ableton-wine/ableton-linkd"
chmod +x "$base/data/ableton-wine/ableton-linkctl" "$base/data/ableton-wine/setup-link.sh" \
    "$base/data/ableton-wine/ableton-linkd"
printf 'format=1\nname=wine-d2d1-nspa-11.13\n' > "$base/runtime/.ableton-linux-runtime"
cat > "$base/runtime/bin/wine" <<'EOF'
#!/bin/sh
case "$*" in
    *'reg query HKCU\Software'*) exit 0 ;;
    *'reg query'*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$base/runtime/bin/wineserver"
chmod +x "$base/runtime/bin/wine" "$base/runtime/bin/wineserver"
printf 'registry\n' > "$base/prefix/system.reg"
printf 'format=1\nprefix=%s\n' "$base/prefix" > "$base/prefix/.ableton-linux-prefix"
cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/runtime
prefix=$base/prefix
live_major=12
link_mode=session
linkd=$base/data/ableton-wine/ableton-linkd
EOF
cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$base/fakebin/systemctl"
for owned in "$base/data/ableton-wine/lib/config.sh" "$base/data/ableton-wine/lib/lifecycle.sh" \
    "$base/data/ableton-wine/lib/live-options.sh" "$base/data/ableton-wine/lib/manifest.sh" \
    "$base/data/ableton-wine/lib/pipeasio.sh" \
    "$base/data/ableton-wine/ableton-linkctl" "$base/data/ableton-wine/setup-link.sh" \
    "$base/data/ableton-wine/ableton-linkd"; do
    printf 'file\t%s\t%s\n' "$owned" "$(sha256sum "$owned" | awk '{print $1}')" \
        >> "$base/state/ableton-wine/install-manifest.tsv"
done
"$base/data/ableton-wine/ableton-linkd" 60 &
link_pid=$!
printf '%s\n' "$link_pid" > "$base/run/ableton-wine/linkd.pid"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/installer.sh" uninstall \
    --runtime-root "$base/runtime" --prefix "$base/prefix" --keep-prefix --yes >"$base/out" 2>"$base/err"
wait "$link_pid" 2>/dev/null || true
kill -0 "$link_pid" 2>/dev/null && fail "uninstall leaves detached Link running"
[ ! -e "$base/runtime" ] && [ ! -e "$base/data/ableton-wine/ableton-linkd" ] \
    && [ -e "$base/prefix/system.reg" ] || fail "uninstall removes owned runtime/Link and keeps requested prefix"
ok "uninstall stops an exact-owned detached Link daemon before removing it"

base="$(new_env link-firewall-rollback)"
mkdir -p "$base/data/ableton-wine" "$base/state/ableton-wine" "$base/fakebin"
printf 'format=1\nowner=ableton-linux\n' > "$base/state/ableton-wine/.ableton-linux-state"
printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkctl"
printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkd"
chmod +x "$base/data/ableton-wine/ableton-linkctl" "$base/data/ableton-wine/ableton-linkd"
printf 'none\n' > "$base/state/ableton-wine/link-firewall"
cat > "$base/fakebin/grep" <<'EOF'
#!/bin/sh
for argument do
    [ "$argument" != /etc/ufw/ufw.conf ] || exit 0
done
exec /usr/bin/grep "$@"
EOF
cat > "$base/fakebin/ufw" <<'EOF'
#!/bin/sh
case "$1" in
    status)
        [ "${ABLETON_TEST_UFW_STATUS_FAIL:-0}" -ne 1 ] || exit 9
        [ ! -e "${ABLETON_TEST_UFW:?}" ] || echo '20808/udp ALLOW Anywhere' ;;
    allow) : > "${ABLETON_TEST_UFW:?}" ;;
    delete) rm -f -- "${ABLETON_TEST_UFW:?}" ;;
    *) exit 2 ;;
esac
EOF
cat > "$base/fakebin/sudo" <<'EOF'
#!/bin/sh
case "${1:-}" in
    -n)
        shift
        [ "${1:-}" != -- ] || shift ;;
    -S)
        shift
        if [ "${1:-}" = -p ]; then shift 2; fi
        [ "${1:-}" != -- ] || shift
        IFS= read -r password || exit 1 ;;
esac
exec "$@"
EOF
cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
    *daemon-reload*) exit "${ABLETON_TEST_SYSTEMCTL_RELOAD_STATUS:-1}" ;;
    *show*) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$base/fakebin/grep" "$base/fakebin/ufw" "$base/fakebin/sudo" "$base/fakebin/systemctl"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_TEST_UFW="$base/ufw-rule" \
    ABLETON_TEST_UFW_STATUS_FAIL=1 bash "$here/setup-link.sh" enable --mode=session \
    >"$base/query.out" 2>"$base/query.err"; then
    fail "Link enable treats a failed privileged ufw query as an absent rule"
fi
[ ! -e "$base/ufw-rule" ] || fail "failed ufw inspection changed the firewall"
[ "$(cat "$base/state/ableton-wine/link-firewall")" = none ] \
    || fail "failed ufw inspection changed the ownership record"
if ! grep -qF 'could not inspect the active ufw rules' "$base/query.err"; then
    sed -n '1,100p' "$base/query.err" >&2
    fail "failed ufw inspection does not explain the refusal"
fi
ok "Link enable refuses when it cannot inspect the active ufw rules"

if run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_TEST_UFW="$base/ufw-rule" \
    bash "$here/setup-link.sh" enable --mode=session >"$base/out" 2>"$base/err"; then
    fail "Link enable succeeds after its systemd registration fails"
fi
[ ! -e "$base/ufw-rule" ] || fail "failed Link enable leaves its new firewall rule"
[ "$(cat "$base/state/ableton-wine/link-firewall")" = none ] \
    || fail "failed Link enable does not restore the prior firewall record"
ok "Link enable failure restores firewall ownership and host state"

printf 'ufw-added\n' > "$base/state/ableton-wine/link-firewall"
rm -f -- "$base/ufw-rule"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_TEST_UFW="$base/ufw-rule" ABLETON_TEST_SYSTEMCTL_RELOAD_STATUS=0 \
    bash "$here/setup-link.sh" enable --mode=session \
    >"$base/reconcile.out" 2>"$base/reconcile.err" \
    || fail "Link enable does not repair a missing recorded ufw rule"
[ -e "$base/ufw-rule" ] \
    || fail "Link enable trusts stale ufw ownership without restoring the rule"
[ "$(cat "$base/state/ableton-wine/link-firewall")" = ufw-added ] \
    || fail "Link enable loses ownership while repairing its ufw rule"
grep -qF 'restoring the recorded ufw allowance' "$base/reconcile.out" \
    || fail "Link enable does not report stale firewall reconciliation"
ok "Link enable verifies and repairs its recorded firewall rule"

for legacy_args in '' ' --linger 0'; do
    case "$legacy_args" in
        '') legacy_name=initial ;;
        *) legacy_name=session ;;
    esac
    base="$(new_env "link-legacy-unit-$legacy_name")"
    unit="$base/config/systemd/user/ableton-linkd.service"
    mkdir -p "$(dirname "$unit")" "$base/data/ableton-wine" "$base/fakebin"
    printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkctl"
    printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkd"
    chmod +x "$base/data/ableton-wine/ableton-linkctl" "$base/data/ableton-wine/ableton-linkd"
    cat > "$unit" <<EOF
[Unit]
Description=Ableton Link session anchor (ableton-linkd)
After=default.target

[Service]
ExecStart=%h/.local/share/ableton-wine/ableton-linkd${legacy_args}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
    printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/sudo"
    chmod +x "$base/fakebin/systemctl" "$base/fakebin/sudo"
    if ! run_isolated "$base" env PATH="$base/fakebin:$PATH" \
        bash "$here/setup-link.sh" enable --mode=session >"$base/out" 2>"$base/err"; then
        sed -n '1,80p' "$base/err" >&2
        fail "Link setup cannot adopt the $legacy_name legacy unit"
    fi
    grep -qxF 'X-AbletonLinuxOwned=true' "$unit" \
        || fail "Link setup does not adopt the $legacy_name legacy unit"
    grep -qxF "ExecStart=\"$base/data/ableton-wine/ableton-linkd\" --linger 0" "$unit" \
        || fail "Link setup does not replace the $legacy_name legacy unit"
done
ok "Link setup adopts both exact legacy unit definitions"

base="$(new_env link-modified-legacy-unit)"
unit="$base/config/systemd/user/ableton-linkd.service"
mkdir -p "$(dirname "$unit")" "$base/data/ableton-wine" "$base/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkctl"
printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkd"
chmod +x "$base/data/ableton-wine/ableton-linkctl" "$base/data/ableton-wine/ableton-linkd"
cat > "$unit" <<'EOF'
[Unit]
Description=Ableton Link session anchor (ableton-linkd)
After=default.target

[Service]
ExecStart=%h/.local/share/ableton-wine/ableton-linkd
Environment=FOREIGN_SETTING=1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
cp "$unit" "$base/unit.before"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/sudo"
chmod +x "$base/fakebin/systemctl" "$base/fakebin/sudo"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/setup-link.sh" enable --mode=session >"$base/out" 2>"$base/err"; then
    fail "Link setup replaces a modified legacy-shaped unit"
fi
cmp -s "$base/unit.before" "$unit" || fail "Link setup changes a refused unit"
grep -q 'refusing to replace foreign systemd unit' "$base/err" \
    || fail "Link setup does not explain the modified unit refusal"
ok "Link setup keeps modified legacy-shaped units"

base="$(new_env link-unit-ownership)"
unit="$base/config/systemd/user/ableton-linkd.service"
link_binary="$base/data/ableton-wine/link%d"
mkdir -p "$(dirname "$unit")" "$(dirname "$link_binary")" "$base/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$link_binary"
chmod +x "$link_binary"
printf '[Service]\nExecStart=/usr/bin/foreign-linkd\n' > "$unit"
cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${ABLETON_TEST_SYSTEMCTL:?}"
exit 0
EOF
chmod +x "$base/fakebin/systemctl"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_LINK_MODE=always \
    ABLETON_LINKD="$link_binary" ABLETON_TEST_SYSTEMCTL="$base/systemctl.log" \
    bash "$here/ableton-linkctl" start >"$base/out" 2>"$base/err"; then
    fail "Link controller starts a foreign canonical systemd unit"
fi
[ ! -e "$base/systemctl.log" ] || fail "foreign Link unit reaches systemctl"
cat > "$unit" <<EOF
[Unit]
X-AbletonLinuxOwned=true
[Service]
ExecStart="$base/data/ableton-wine/link%%d" --linger 0
EOF
run_isolated "$base" env PATH="$base/fakebin:$PATH" ABLETON_LINK_MODE=always \
    ABLETON_LINKD="$link_binary" ABLETON_TEST_SYSTEMCTL="$base/systemctl.log" \
    bash "$here/ableton-linkctl" start >"$base/owned.out" 2>"$base/owned.err"
grep -q -- '--user start ableton-linkd.service' "$base/systemctl.log" \
    || fail "exact owned Link unit is not started"
ok "Link controller starts only the exact ownership-marked unit"

base="$(new_env legacy-ownership)"
foreign_desktop="$base/data/applications/ableton-live.desktop"
mkdir -p "$(dirname "$foreign_desktop")" "$base/fakebin"
printf '[Desktop Entry]\nName=Foreign application\n' > "$foreign_desktop"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
chmod +x "$base/fakebin/systemctl"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" \
    --keep-prefix --yes >"$base/out" 2>"$base/err"; then
    fail "manifest-free uninstall reports full success with a foreign canonical file"
fi
[ -f "$foreign_desktop" ] || fail "legacy uninstall removes an unrecognised canonical desktop file"
grep -q 'kept unrecognised or modified legacy file' "$base/err" \
    || fail "legacy ownership refusal is not reported"
[ -f "$base/config/ableton-wine/config" ] \
    || fail "partial legacy uninstall discards the configuration needed to retry"
grep -q 'run uninstall' "$base/err" \
    || fail "legacy ownership rejection does not say how to finish the uninstall"
ok "legacy uninstall retains unrecognised canonical files"

# Uninstall used to restore the MIME defaults after deleting its own desktop
# entries.  xdg-mime reports no default once the entry file is gone, so the
# check that clears the line never matched, and the line stayed behind naming a
# file that no longer existed.
base="$(new_env mime-restore)"
mkdir -p "$base/data/applications" "$base/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
chmod +x "$base/fakebin/systemctl"
# This entry advertises the type, so its default resolves without a list entry.
cat > "$base/data/applications/foreign-auz.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Foreign AUZ
Exec=/usr/bin/true %f
MimeType=application/x-wine-extension-auz;
EOF
# This one advertises nothing, so only an explicit list entry can select it.
printf '[Desktop Entry]\nType=Application\nName=Third Party\nExec=/usr/bin/true %%f\n' \
    > "$base/data/applications/third-party.desktop"
run_isolated "$base" update-desktop-database "$base/data/applications" >/dev/null 2>&1 || true
# xdg-mime writes nothing and still exits 0 when its config directory is absent.
mkdir -p "$base/config"
run_isolated "$base" xdg-mime default third-party.desktop x-scheme-handler/ableton \
    || fail "test fixture could not set an explicit pre-install default"
grep -qxF 'x-scheme-handler/ableton=third-party.desktop' "$base/config/mimeapps.list" \
    || fail "test fixture did not record an explicit pre-install default"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/install.sh" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || { sed -n '1,40p' "$base/install.err" >&2; fail "integration install failed before MIME restoration"; }
grep -qxF "x-scheme-handler/ableton=$ABLETON_PROTOCOL_DESKTOP_ID" "$base/config/mimeapps.list" \
    || fail "integration did not take over the scheme handler it registers"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" \
    --keep-prefix --yes >"$base/out" 2>"$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "uninstall failed after integration"; }
if grep -Eq "=($ABLETON_PROTOCOL_DESKTOP_ID|$ABLETON_AUZ_DESKTOP_ID|ableton-live\.desktop|max9\.desktop|wine-protocol-c74max\.desktop)\$" \
    "$base/config/mimeapps.list"; then
    fail "uninstall leaves a MIME default naming an entry it removed"
fi
grep -qxF 'x-scheme-handler/ableton=third-party.desktop' "$base/config/mimeapps.list" \
    || fail "uninstall does not restore an explicit pre-install default"
! grep -q '^application/x-wine-extension-auz=' "$base/config/mimeapps.list" \
    || fail "uninstall writes out a default the user never set explicitly"
ok "uninstall clears its own MIME defaults and restores exactly what it found"

# The installer saves a pre-existing launcher before writing the canonical
# launcher. Uninstall restores the exact pre-install object.
base="$(new_env foreign-live-entry)"
mkdir -p "$base/data/applications" "$base/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
chmod +x "$base/fakebin/systemctl"
printf '[Desktop Entry]\nType=Application\nName=Foreign Live\nExec=/usr/bin/true %%f\n' \
    > "$base/data/applications/ableton-live.desktop"
cp "$base/data/applications/ableton-live.desktop" "$base/foreign-live.before"
printf 'personal adjacent backup\n' > "$base/data/applications/ableton-live.desktop.bak"
chmod 600 "$base/data/applications/ableton-live.desktop.bak"
cp -a "$base/data/applications/ableton-live.desktop.bak" "$base/foreign-live-backup.before"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "integration install failed with a foreign Live entry"; }
grep -qxF 'Name=Ableton Live' "$base/data/applications/ableton-live.desktop" \
    || fail "integration did not replace a foreign Live desktop entry"
grep -Eq '^application/x-ableton-live-(set|clip|pack)=ableton-live\.desktop$' \
    "$base/config/mimeapps.list" \
    || fail "integration did not assign Live file types to its installed entry"
prestate_id="$(printf '%s' "$base/data/applications/ableton-live.desktop" | sha256sum | awk '{print $1}')"
backup_prestate_id="$(printf '%s' "$base/data/applications/ableton-live.desktop.bak" | sha256sum | awk '{print $1}')"
cmp -s "$base/foreign-live.before" "$base/data/applications/ableton-live.desktop.bak" \
    || fail "integration did not create ableton-live.desktop.bak"
cmp -s "$base/foreign-live.before" "$base/state/ableton-wine/install-prestate/$prestate_id" \
    || fail "integration did not back up the foreign Live desktop entry"
cmp -s "$base/foreign-live-backup.before" "$base/state/ableton-wine/install-prestate/$backup_prestate_id" \
    || fail "integration did not preserve the pre-existing adjacent backup"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" \
    --keep-prefix --yes >"$base/uninstall.out" 2>"$base/uninstall.err" \
    || { sed -n '1,40p' "$base/uninstall.err" >&2; fail "uninstall failed after replacing a foreign Live entry"; }
cmp -s "$base/foreign-live.before" "$base/data/applications/ableton-live.desktop" \
    || fail "uninstall did not restore the foreign Live desktop entry"
cmp -s "$base/foreign-live-backup.before" "$base/data/applications/ableton-live.desktop.bak" \
    && [ "$(stat -c '%a' "$base/data/applications/ableton-live.desktop.bak")" = 600 ] \
    || fail "uninstall did not restore the pre-existing adjacent backup"
ok "integration restores a foreign launcher and its pre-existing adjacent backup"

base="$(new_env identical-foreign-launcher)"
identical_launcher="$base/home/.local/bin/ableton-live"
mkdir -p "$(dirname "$identical_launcher")" "$base/fakebin"
install -m 700 "$here/ableton-live" "$identical_launcher"
printf '#!/bin/sh\nexit 0\n' > "$base/fakebin/systemctl"
chmod +x "$base/fakebin/systemctl"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/install.sh" --integration-only \
    >"$base/install.out" 2>"$base/install.err" \
    || fail "byte-identical pre-existing launcher blocked integration"
cmp -s "$here/ableton-live" "${identical_launcher}.bak" \
    && [ "$(stat -c '%a' "${identical_launcher}.bak")" = 700 ] \
    || fail "byte-identical pre-existing launcher was not backed up with its metadata"
[ "$(stat -c '%a' "$identical_launcher")" = 755 ] \
    || fail "integration did not install the canonical launcher mode"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" \
    --keep-prefix --yes >"$base/uninstall.out" 2>"$base/uninstall.err" \
    || fail "uninstall failed after replacing a byte-identical launcher"
[ ! -e "$identical_launcher" ] && [ ! -L "$identical_launcher" ] \
    || fail "uninstall retained the legacy-shaped installed launcher"
[ ! -e "${identical_launcher}.bak" ] && [ ! -L "${identical_launcher}.bak" ] \
    || fail "uninstall retained an installer-created adjacent backup"
ok "byte-identical pre-existing launchers receive managed adjacent backups"

base="$(new_env launcher-directory-collision)"
directory_launcher="$base/data/applications/ableton-live.desktop"
mkdir -p "$directory_launcher"
if run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err"; then
    fail "integration replaced a directory at a launcher path"
fi
[ -d "$directory_launcher" ] && [ ! -L "$directory_launcher" ] \
    || fail "launcher directory refusal changed the collision"
[ ! -e "${directory_launcher}.bak" ] && [ ! -L "${directory_launcher}.bak" ] \
    || fail "launcher directory refusal created an adjacent backup"
grep -qF "launcher path points to a directory: $directory_launcher" "$base/err" \
    || fail "launcher directory refusal did not report the actual cause"
ok "launcher directory collisions fail with an explicit reason"

base="$(new_env launcher-fifo-collision)"
fifo_launcher="$base/home/.local/bin/ableton-live"
mkdir -p "$(dirname "$fifo_launcher")"
mkfifo "$fifo_launcher"
if run_isolated "$base" bash "$here/install.sh" --integration-only \
    >"$base/out" 2>"$base/err"; then
    fail "integration replaced a FIFO at a launcher path"
fi
[ -p "$fifo_launcher" ] \
    || fail "launcher FIFO refusal changed the collision"
[ ! -e "${fifo_launcher}.bak" ] && [ ! -L "${fifo_launcher}.bak" ] \
    || fail "launcher FIFO refusal created an adjacent backup"
grep -qF "launcher path is not a regular file or symlink: $fifo_launcher" "$base/err" \
    || fail "launcher FIFO refusal did not report the actual path"
ok "launcher special-file collisions fail with an explicit reason"

# Session Link policy writes the unit for later but never runs it, so it must
# not need a user manager that answers.  Only always-on policy does.
base="$(new_env link-no-user-manager)"
mkdir -p "$base/data/ableton-wine" "$base/state/ableton-wine" "$base/fakebin"
printf 'format=1\nowner=ableton-linux\n' > "$base/state/ableton-wine/.ableton-linux-state"
printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkctl"
printf '#!/bin/sh\nexit 0\n' > "$base/data/ableton-wine/ableton-linkd"
chmod +x "$base/data/ableton-wine/ableton-linkctl" "$base/data/ableton-wine/ableton-linkd"
cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
echo 'Failed to connect to user scope bus via local transport: Connection refused' >&2
exit 1
EOF
# Keep every firewall out of this check: no ufw.conf match and no firewalld
# means no rule to add and nothing to raise privileges for.
cat > "$base/fakebin/grep" <<'EOF'
#!/bin/sh
for argument do
    [ "$argument" != /etc/ufw/ufw.conf ] || exit 1
done
exec /usr/bin/grep "$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$base/fakebin/firewall-cmd"
printf '#!/bin/sh\nexit 1\n' > "$base/fakebin/sudo"
chmod +x "$base/fakebin/systemctl" "$base/fakebin/grep" \
    "$base/fakebin/firewall-cmd" "$base/fakebin/sudo"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/setup-link.sh" enable --mode=session >"$base/out" 2>"$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "session Link enable needs a reachable user manager"; }
[ -f "$base/config/systemd/user/ableton-linkd.service" ] \
    || fail "session Link enable skipped the unit it writes for a later session"
if run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    bash "$here/setup-link.sh" enable --mode=always >"$base/always.out" 2>"$base/always.err"; then
    fail "always-on Link enable succeeded with no systemd user manager"
fi
ok "session Link policy does not depend on a reachable systemd user manager"

# setup-link.sh sources the ownership helper, so a Link-only install has to ship
# it: TROUBLESHOOTING tells people to run the installed copy.
base="$(new_env link-assets-runnable)"
run_isolated "$base" bash "$here/install.sh" --link-assets-only \
    >"$base/out" 2>"$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "link-only install failed"; }
run_isolated "$base" bash "$base/data/ableton-wine/setup-link.sh" status \
    >"$base/status.out" 2>"$base/status.err" \
    || { sed -n '1,20p' "$base/status.err" >&2; fail "the installed setup-link.sh cannot run"; }
grep -q '^policy:' "$base/status.out" || fail "installed Link status reported no policy"
ok "a link-only install ships every library its setup-link.sh needs"

# Status only reads.  It has to answer while a lifecycle command holds the
# lock, which is exactly when someone asks.
base="$(new_env link-status-under-lock)"
mkdir -p "$base/state/ableton-wine"
printf 'format=1\nowner=ableton-linux\n' > "$base/state/ableton-wine/.ableton-linux-state"
run_isolated "$base" bash -c '
    exec {held}< "$HOME"
    flock -n "$held" || exit 9
    bash "$1" status' locked "$here/setup-link.sh" >"$base/out" 2>"$base/err" \
    || { sed -n '1,20p' "$base/err" >&2; fail "Link status fails while the installation lock is held"; }
grep -q '^policy:' "$base/out" || fail "locked Link status reported no policy"
ok "Link status answers while the installation lock is held"

# A missing prefix or runtime names itself.  Both used to arrive as an audio
# failure, because the PipeWire gate ran first.
base="$(new_env precondition-order)"
if run_isolated "$base" bash "$here/installer.sh" update >"$base/out" 2>"$base/err"; then
    fail "update without a prefix succeeded"
fi
grep -q 'update needs an existing prefix' "$base/err" \
    || fail "update without a prefix reports something other than the missing prefix"
! grep -qi pipewire "$base/err" \
    || fail "update without a prefix leads with an audio failure"
mkdir -p "$base/prefix"
printf 'WINE REGISTRY Version 2\n' > "$base/prefix/system.reg"
if run_isolated "$base" env ABLETON_WINEPREFIX="$base/prefix" \
    bash "$here/installer.sh" prefix update >"$base/prefix.out" 2>"$base/prefix.err"; then
    fail "prefix update without a runtime succeeded"
fi
grep -q 'no runtime at' "$base/prefix.err" \
    || fail "prefix update without a runtime does not name the missing runtime"
! grep -q 'Reinstall from a complete installer kit' "$base/prefix.err" \
    || fail "prefix update blames the installer kit for a runtime that was never installed"
ok "missing prefixes and runtimes are named before the PipeWire check runs"

printf 'PASS: %s installer lifecycle checks\n' "$pass"
