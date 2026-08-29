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

lifecycle_object_snapshot()
{
    local path="$1" metadata digest target
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

# The suite installs real build artifacts: the exact VERSION runtime from the
# runtime-plan check onwards and dist/ableton-linkd from the Link checks. A
# checkout can update the tracked runtime checksum while retaining
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

# A ui_run task runs exactly once and keeps its exit status; the rendering
# itself is covered by test-installer-ui.sh.
cat > "$base/ui-worker" <<'EOF'
#!/bin/sh
printf 'run\n' >> "${ABLETON_TEST_UI_LOG:?}"
exit "${1:-0}"
EOF
chmod +x "$base/ui-worker"
: > "$base/ui.log"
status=0
env ABLETON_TEST_UI_LOG="$base/ui.log" ABLETON_UI_ACTION=install bash -c '
    . "$1/lib/ui.sh"
    ui_step_begin s_validate
    ui_run i_copy -- "$2" 23
' _ "$here" "$base/ui-worker" > "$base/ui-plain.out" 2>&1 || status=$?
[ "$status" -eq 23 ] || fail "ui_run keeps its task's exit status (got $status)"
[ "$(wc -l < "$base/ui.log")" -eq 1 ] || fail "ui_run ran its task more than once"
grep -qF '│  ├─ Copy the embedded kit 𐄂' "$base/ui-plain.out" \
    || fail "a failed ui_run task is marked on its title"
ok "ui_run runs one task and preserves its status"

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

# Progress output is presentation, not part of the repair. GNU mv -v reports to
# stdout after each successful move; a closed consumer used to turn that into a
# false failure and stop before repairing the next user's preference file.
base="$(new_env live11-repair-closed-output)"
for repair_user in one two; do
    max_settings="$base/prefix/drive_c/users/$repair_user/AppData/Roaming/Cycling '74/Max 8/Settings"
    mkdir -p -- "$max_settings"
    printf 'stale preferences for %s\n' "$repair_user" \
        > "$max_settings/maxpreferences.maxpref"
done
printf 'WINE REGISTRY Version 2\n' > "$base/prefix/system.reg"
printf 'format=1\nprefix=%s\n' "$base/prefix" > "$base/prefix/.ableton-linux-prefix"
run_isolated "$base" bash "$here/installer.sh" prefix repair-live11 \
    --prefix "$base/prefix" > /dev/full 2> "$base/err" \
    || fail "closed progress output changed a completed Live 11 repair into failure"
for repair_user in one two; do
    max_settings="$base/prefix/drive_c/users/$repair_user/AppData/Roaming/Cycling '74/Max 8/Settings"
    [ ! -e "$max_settings/maxpreferences.maxpref" ] \
        && compgen -G "$max_settings/maxpreferences.maxpref.bak-*" >/dev/null \
        || fail "closed output stopped Live 11 repair before every preference file was moved"
done
ok "Live 11 repair completes every safe move when progress output is closed"

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

# make-installer's own self-check runs --help, which returns before the
# delegation, so only this case guards the header's exit path. The stub
# renders through ui.sh exactly as the real installer does.
base="$(new_env run-header)"
kit="$base/kit"
mkdir -p "$kit/scripts/lib"
cp "$here/lib/ui.sh" "$kit/scripts/lib/ui.sh"
cat > "$kit/scripts/installer.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${ABLETON_INSTALLER_PATH:-}" > "${STUB_PATH_FILE:?}"
. "$(dirname "$0")/lib/ui.sh"
ui_step_begin s_validate
ui_item_begin i_copy
printf '   backup: /known/recovery/path\n'
if [ "${STUB_EXIT:-0}" -eq 0 ]; then
    ui_item_end ok
    printf '!! recoverable stub warning\n' >&2
    ui_step_end ok
else
    ui_item_end fail
    printf '🛈 ordinary stderr context.\n!! delegated installer failed with status %s.\n' \
        "${STUB_EXIT:-0}" >&2
    ui_step_end fail
fi
exit "${STUB_EXIT:-0}"
EOF
tar -cf "$base/payload.tar" -C "$kit" .
"$here/make-installer.sh" --render-header --version suite-check \
    --payload-sha "$(sha256sum "$base/payload.tar" | awk '{print $1}')" > "$base/kit.run" \
    || fail "make-installer.sh renders the .run header for the suite"
cat "$base/payload.tar" >> "$base/kit.run"
run_isolated "$base" env PATH="$PATH" STUB_EXIT=0 STUB_PATH_FILE="$base/installer-path" \
    sh "$base/kit.run" >"$base/out" 2>"$base/err" \
    || fail "a successful delegated install exits zero through the .run header"
grep -qF '│  ┃ 2/8 ╏ CHECK THE HOST AND THE REQUEST ┃' "$base/out" \
    || fail "the delegated installer continues the header's step numbering"
grep -qF '│  └─ Step 1 Complete! ✓' "$base/out" \
    && grep -qF '│  └─ Step 2 Complete! ✓' "$base/out" \
    || fail "the header and the delegated installer each close their step"
grep -qF 'Launch Ableton Live via your desktop applications launcher' "$base/out" \
    || fail "a successful install ends with the launch hint"
status=0
run_isolated "$base" env PATH="$PATH" STUB_EXIT=42 STUB_PATH_FILE="$base/installer-path" \
    sh "$base/kit.run" >>"$base/out" 2>>"$base/err" || status=$?
[ "$status" -eq 42 ] || fail "a delegated install failure code passes through the .run header"
grep -q '^│ Ableton-Linux Install v. suite-check *│ Complete │$' "$base/out" \
    || fail "successful .run output omitted its completion footer"
grep -q '^│ Ableton-Linux Install v. suite-check *│   Failed │$' "$base/out" \
    || fail "failed .run output omitted its failure footer"
grep -qF '  > delegated installer failed with status 42.' "$base/out" \
    || fail "failed .run output omitted its line-by-line error"
! grep -qF '  > ordinary stderr context.' "$base/out" \
    || fail "failed .run output mislabeled informational stderr as an error"
! grep -q '^!! \|^🛈 ' "$base/out" \
    || fail "raw child output reached the terminal instead of the log"
grep -qF 'https://discord.gg/XD5EeZyP3' "$base/out" \
    && grep -qF 'https://github.com/shibco/ableton-linux/issues' "$base/out" \
    || fail "failed .run output omitted its support links"
grep -qF 'Saved a log of this operation at' "$base/out" \
    || fail "the .run footer omitted its log location"
! grep -qF 'backup: /known/recovery/path' "$base/out" \
    || fail "successful backup paths flooded the .run terminal"
grep -qF '[ableton-linux][installer][stdout]    backup: /known/recovery/path' \
    "$base"/ableton-linux-installer-*.log \
    || fail "the .run log omitted a successful backup path"
! grep -qF '[ableton-linux][installer][ui]' "$base"/ableton-linux-installer-*.log \
    || fail "the .run log repeats the rendered installer tree"
grep -qF '[WARN] ' "$base"/ableton-linux-installer-*.log \
    && grep -qF 'recoverable stub warning' "$base"/ableton-linux-installer-*.log \
    || fail "a recoverable successful-run warning remained an error in the log"
! LC_ALL=C grep -q $'\033' "$base"/ableton-linux-installer-*.log \
    || fail "the .run log contains terminal escapes"
[ "$(cat "$base/installer-path")" = "$(readlink -f -- "$base/kit.run")" ] \
    || fail "the .run header does not pass its reusable path to the installer"
! find "$base/tmp" -mindepth 1 -maxdepth 1 -name 'ableton-installer.*' 2>/dev/null | grep -q . \
    || fail "the .run header removes its work directory"
ok "the .run header propagates the delegated installer exit code"

# Host-report commands can keep writing after their first useful line. The
# wrapper must drain them instead of turning that normal SIGPIPE into exit 141.
base="$(new_env run-header-host-report)"
mkdir -p "$base/fakebin"
cat > "$base/fakebin/lspci" <<'EOF'
#!/bin/sh
printf '%s\n' '00:00.0 "VGA compatible controller" "Test Vendor" "Test GPU" -r00 "Test Subvendor" "Test Subdevice"'
exec /usr/bin/seq 1 100000
EOF
cat > "$base/fakebin/pw-cli" <<'EOF'
#!/bin/sh
printf '%s\n' 'pw-cli' 'Linked with libpipewire 1.6.8'
exec /usr/bin/seq 1 100000
EOF
chmod +x "$base/fakebin/lspci" "$base/fakebin/pw-cli"
run_isolated "$base" env PATH="$base/fakebin:$PATH" STUB_EXIT=0 \
    STUB_PATH_FILE="$base/installer-path" sh "$work/run-header/kit.run" \
    > "$base/out" 2> "$base/err" \
    || fail "large host-report output stopped the .run wrapper"
grep -qF 'Test GPU Test Subvendor' "$base/out" \
    && grep -qF '│  PipeWire       1.6.8' "$base/out" \
    || fail "the .run wrapper did not report the first GPU and PipeWire results"
ok "host reporting drains first-match commands without an exit 141"

# Extraction has completed once the files are copied. A closed output stream
# must not reverse that result or prevent any of the transport work that precedes
# the final success line.
base="$(new_env run-header-extract-output)"
run_isolated "$base" sh "$work/run-header/kit.run" extract "$base/extracted" \
    > /dev/full 2> "$base/err" \
    || fail "closed output changed a completed .run extraction into failure"
[ -f "$base/extracted/scripts/installer.sh" ] \
    || fail "closed output prevented the .run kit from being extracted"
ok "the .run header preserves a successful extraction when output is closed"

# GNU tar's progress dots go to stderr. Once tar has succeeded, even the
# separating newline is presentation: a broken diagnostic consumer must not
# stop extract before the verified kit is copied to its destination.
base="$(new_env run-header-extract-stderr)"
mkdir -p "$base/fakebin"
cat > "$base/fakebin/dd" <<'EOF'
#!/bin/sh
[ "${1:-}" != --help ] || exit 0
exec /usr/bin/dd "$@"
EOF
cat > "$base/fakebin/tar" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --help ]; then
    echo --checkpoint
    exit 0
fi
[ "${1:-}" != --checkpoint=200 ] || shift
[ "${1:-}" != --checkpoint-action=dot ] || shift
exec /usr/bin/tar "$@"
EOF
chmod +x "$base/fakebin/dd" "$base/fakebin/tar"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    sh "$work/run-header/kit.run" extract "$base/extracted" \
    > "$base/out" 2> /dev/full \
    || fail "closed diagnostic output changed a completed .run extraction into failure"
[ -f "$base/extracted/scripts/installer.sh" ] \
    || fail "closed diagnostic output stopped the .run kit before its destination copy"
ok "the .run header preserves extraction after checkpoint output closes"

# A completed install stays successful even when temporary-file cleanup cannot
# remove its work directory and the warning cannot be written.  Keep the
# transport quiet until that cleanup path so /dev/full tests the final warning,
# not extraction progress from dd or tar.
base="$(new_env run-header-cleanup-output)"
mkdir -p "$base/fakebin"
cat > "$base/fakebin/dd" <<'EOF'
#!/bin/sh
[ "${1:-}" != --help ] || exit 0
exec /usr/bin/dd "$@"
EOF
cat > "$base/fakebin/tar" <<'EOF'
#!/bin/sh
[ "${1:-}" != --help ] || exit 0
exec /usr/bin/tar "$@"
EOF
cat > "$base/fakebin/rm" <<'EOF'
#!/bin/sh
[ "${1:-}" != -rf ] || exit 1
exec /usr/bin/rm "$@"
EOF
chmod +x "$base/fakebin/dd" "$base/fakebin/tar" "$base/fakebin/rm"
run_isolated "$base" env PATH="$base/fakebin:$PATH" STUB_EXIT=0 \
    STUB_PATH_FILE="$base/installer-path" sh "$work/run-header/kit.run" \
    >"$base/out" 2>/dev/full \
    || fail "cleanup output failure changed a successful .run result"
find "$base/tmp" -mindepth 1 -maxdepth 1 -name 'ableton-installer.*' \
    -type d -print -quit | grep -q . \
    || fail "the cleanup-output fixture did not leave its temporary directory"
ok "the .run header preserves success when cleanup output fails"

base="$(new_env noninteractive)"
if run_isolated "$base" bash "$here/installer.sh" >"$base/out" 2>"$base/err"; then
    fail "noninteractive install requires an explicit payload"
fi
grep -q -- '--live-installer FILE or --skip-live-install' "$base/err" || fail "noninteractive failure explains payload policy"
[ ! -e "$base/config" ] && [ ! -e "$base/data" ] && [ ! -e "$base/state" ] || fail "failed parse is mutation-free"
ok "noninteractive payload failure is mutation-free"

# Live installer candidates come from the installer's own directory, newest
# first; [1] is the default on Enter, EOF, or the timeout.
base="$(new_env candidates)"
mkdir -p "$base/media"
for spec in 'ableton_live_11.3.35_64.zip:Ableton Live 11 Suite Installer.exe' \
            'ableton_live_12.0_64.zip:Ableton Live 12 Suite Installer.exe' \
            'ableton_live_12.3.1_64.zip:Ableton Live 12 Suite Installer.exe'; do
    python3 - "$base/media/${spec%%:*}" "${spec#*:}" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1], 'w').writestr(sys.argv[2], 'x')
PY
done
run_candidates()
{
    run_isolated "$base" env ABLETON_INSTALLER_MEDIA_DIR="$base/media" \
        ABLETON_UI_PROMPT_TIMEOUT=1 bash "$here/installer.sh" plan install
}
run_candidates < /dev/null > "$base/out" 2> "$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "EOF picks the first candidate"; }
grep -qF '│ Found multiple Ableton Live install candidates:' "$base/out" \
    || fail "several candidates are announced"
[ "$(grep '│  > \[[0-9]\] ableton_live' "$base/out" | sed 's/.*\] //' | paste -sd,)" = \
  'ableton_live_12.3.1_64.zip,ableton_live_12.0_64.zip,ableton_live_11.3.35_64.zip' ] \
    || fail "candidates are listed newest first"
grep -qF '(Press Enter for [1] or wait 1 seconds)' "$base/out" \
    || fail "the candidate hint names the default and the timeout"
grep -qiF "run the Live 12 installer: $base/media/ableton_live_12.3.1_64.zip" "$base/out" \
    || fail "EOF selected the first candidate"
printf '2\n' | run_candidates > "$base/out" 2> "$base/err" || fail "a number picks its candidate"
grep -qiF "run the Live 12 installer: $base/media/ableton_live_12.0_64.zip" "$base/out" \
    || fail "2 picks the second candidate"
run_candidates < <(sleep 3) > "$base/out" 2> "$base/err" || fail "the timeout picks the first candidate"
grep -qiF "run the Live 12 installer: $base/media/ableton_live_12.3.1_64.zip" "$base/out" \
    || fail "the timeout selected [1]"
status=0
printf '9\n' | run_candidates > "$base/out" 2> "$base/err" || status=$?
[ "$status" -eq 2 ] || fail "a number out of range fails the run (got $status)"
rm -f "$base/media/ableton_live_12.0_64.zip" "$base/media/ableton_live_11.3.35_64.zip"
run_candidates < /dev/null > "$base/out" 2> "$base/err" \
    || fail "a single candidate is used without a question"
grep -qF '│ Found Ableton Live install files at' "$base/out" \
    && grep -qF '│  > [1] ableton_live_12.3.1_64.zip' "$base/out" \
    || fail "a single candidate is shown"
! grep -qF 'Which one?' "$base/out" || fail "a single candidate asks no question"
rm -f "$base/media"/*.zip
status=0
run_candidates < /dev/null > "$base/out" 2> "$base/err" || status=$?
[ "$status" -eq 2 ] || fail "no candidate at all fails the run (got $status)"
grep -q -- '--live-installer FILE or --skip-live-install' "$base/err" || fail "no candidate names the remedy"
mkdir -p "$base/home/Downloads"
python3 - "$base/home/Downloads/ableton_live_12.3.1_64.zip" 'Ableton Live 12 Suite Installer.exe' <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1], 'w').writestr(sys.argv[2], 'x')
PY
run_isolated "$base" env ABLETON_INSTALLER_MEDIA_DIR="$base/home/Downloads" ABLETON_UI_PROMPT_TIMEOUT=1 \
    bash "$here/installer.sh" plan install < /dev/null > "$base/out" 2> "$base/err" \
    || fail "a candidate under the home directory is found"
grep -qxF '│  ~/Downloads' "$base/out" || fail "the candidate directory is shown with a tilde"
ok "Live installer candidates are listed newest first with a timed default"

# The uninstall command hands over to uninstall.sh with exec: the validate
# step is closed first and uninstall.sh draws its own step exactly once.
base="$(new_env uninstall-exec)"
status=0
run_isolated "$base" bash "$here/installer.sh" uninstall --yes > "$base/out" 2> "$base/err" || status=$?
[ "$(grep -c '^│  └─ Step 1 Complete! ✓$' "$base/out")" -eq 1 ] \
    || fail "the validate step closes before the handover to uninstall.sh"
[ "$(grep -c '^│  ┃ 2/2 ╏ REMOVE ABLETON LINUX ┃$' "$base/out")" -eq 1 ] \
    || fail "uninstall.sh draws its own step after the handover"
[ "$(grep -c '^│  └─ Step 2 ' "$base/out")" -eq 1 ] \
    || fail "uninstall.sh closes its step exactly once (exit $status)"
ok "the uninstall handover keeps one step open at a time"

# The dispatcher normalizes every uninstall request to exactly one scope flag.
# All three pairwise conflicts are rejected before uninstall.sh can run.
base="$(new_env uninstall-scope-dispatch)"
dispatcher="$base/dispatcher"
mkdir -p -- "$dispatcher"
cp -- "$here/installer.sh" "$dispatcher/installer.sh"
cp -R -- "$here/lib" "$dispatcher/lib"
cat > "$dispatcher/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "${ABLETON_TEST_UNINSTALL_HANDOFF:?}"
for argument do
    printf '%s\n' "$argument" >> "$ABLETON_TEST_UNINSTALL_HANDOFF"
done
EOF
chmod +x "$dispatcher/uninstall.sh"

assert_uninstall_scope_handoff()
{
    local name="$1" expected="$2"
    shift 2
    rm -f -- "$base/handoff"
    run_isolated "$base" env ABLETON_TEST_UNINSTALL_HANDOFF="$base/handoff" \
        bash "$dispatcher/installer.sh" uninstall "$@" \
        >"$base/$name.out" 2>"$base/$name.err" \
        || fail "$name was rejected before the uninstall handoff"
    mapfile -t handed_off < "$base/handoff"
    [ "${#handed_off[@]}" -eq 1 ] && [ "${handed_off[0]}" = "$expected" ] \
        || fail "$name did not hand off exactly one normalized scope flag"
}

assert_uninstall_scope_handoff no-flag --keep-prefix
assert_uninstall_scope_handoff keep-prefix --keep-prefix --keep-prefix
assert_uninstall_scope_handoff prefix-only --prefix-only --prefix-only
assert_uninstall_scope_handoff delete-prefix --delete-prefix --delete-prefix

assert_uninstall_scope_conflict()
{
    local name="$1"
    shift
    local status=0
    rm -f -- "$base/handoff"
    run_isolated "$base" env ABLETON_TEST_UNINSTALL_HANDOFF="$base/handoff" \
        bash "$dispatcher/installer.sh" uninstall "$@" \
        >"$base/$name.out" 2>"$base/$name.err" || status=$?
    [ "$status" -eq 2 ] || fail "$name did not return the parse-error status"
    grep -qi 'conflict' "$base/$name.err" \
        || fail "$name was not identified as a scope conflict"
    [ ! -e "$base/handoff" ] \
        || fail "$name reached uninstall.sh before its conflict was rejected"
}

assert_uninstall_scope_conflict keep-prefix-prefix-only \
    --keep-prefix --prefix-only
assert_uninstall_scope_conflict keep-prefix-delete-prefix \
    --keep-prefix --delete-prefix
assert_uninstall_scope_conflict prefix-only-delete-prefix \
    --prefix-only --delete-prefix
ok "uninstall dispatch normalizes three exclusive scopes and rejects every pair"

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
legacy_status=0
run_isolated "$base" bash "$here/installer.sh" --prefix --uninstall --dry-run \
    >"$base/legacy.out" 2>"$base/legacy.err" || legacy_status=$?
[ "$legacy_status" -ne 2 ] \
    && ! grep -qi 'specified more than once' "$base/legacy.err" \
    || fail "legacy uninstall prefix alias depends on argument order"
ok "immutable options reject duplicates and legacy parsing is order-independent"

base="$(new_env unrelated-config-path)"
mkdir -p "$base/config/pipeasio/config.ini"
run_isolated "$base" bash "$here/installer.sh" link disable \
    >"$base/out" 2>"$base/err" \
    || fail "an unrelated PipeASIO configuration path blocks Link disable"
if find "$base/state/ableton-wine/transactions" -mindepth 1 -maxdepth 1 \
    -name 'installer.*' -print -quit 2>/dev/null | grep -q .; then
    fail "Link disable created an optional transaction journal"
fi
[ -d "$base/config/pipeasio/config.ini" ] \
    || fail "Link disable changed an unrelated PipeASIO configuration path"
grep -q '^│  ├─ Ableton Link is off\.' "$base/out" \
    || fail "successful Link disable does not report its outcome"
ok "Link disable preserves unrelated configuration without an optional transaction"

base="$(new_env runtime-plan)"
run_isolated "$base" bash "$here/installer.sh" --runtime-only --runtime-root "$base/runtime" --dry-run >"$base/out" 2>"$base/err"
grep -q 'Install or update Wine' "$base/out" || fail "runtime plan contains runtime"
! grep -q 'Install or update launchers' "$base/out" || fail "runtime plan excludes integration"
! grep -q 'Ableton Link support' "$base/out" || fail "runtime plan excludes Link"
grep -q 'Update the PipeASIO Settings shortcuts to match this Wine build' "$base/out" \
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
grep -q 'Install or update launchers' "$base/out" || fail "no-launch still means skip Live payload only"
grep -q 'Set Ableton Link mode to off' "$base/out" || fail "no-launch defaults Link off"
! grep -Eq 'Install or update Ableton Link support|Use the configured Ableton Link helper' "$base/out" \
    || fail "no-launch unexpectedly stages Link assets"
! grep -Eq 'Write ownership-marked user unit|Launchers start session daemon|Enable/start the owned user unit' "$base/out" \
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
grep -q 'Set Ableton Link mode to off' "$base/out" || fail "update preserves Link opt-out"
! grep -q 'Ableton Link support' "$base/out" || fail "opted-out update excludes Link assets"
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
if [ "\${ABLETON_TEST_BACKGROUND:-0}" -eq 1 ]; then
    ableton_prefix_unknown_holders() { printf '123\tBackground.exe\n'; }
fi
if [ "\${ABLETON_TEST_APPROVED_STOP:-0}" -eq 1 ]; then
    ableton_stop_runtime_clients()
    {
        printf 'stop\n' >> "\${ABLETON_TEST_LOG:?}"
        [ "\${ABLETON_TEST_UNKILLABLE:-0}" -eq 1 ] || rm -f -- "\${ABLETON_TEST_BUSY:?}"
    }
fi
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
run_quiesce ABLETON_TEST_BACKGROUND=1 ABLETON_TEST_APPROVED_STOP=1
grep -qx 'rc=0' "$base/out" || fail "an approved background-process stop reports success"
[ "$(quiesce_calls)" = "stop " ] || fail "background process detection waited before requesting a stop"
ok "a detected background program requests approval before waiting"

: > "$base/busy"
run_quiesce ABLETON_TEST_APPROVED_STOP=1 ABLETON_TEST_UNKILLABLE=1
grep -qx 'rc=3' "$base/out" || fail "a surviving straggler is reported as still busy"
[ "$(quiesce_calls)" = "-w stop -w " ] || fail "a surviving straggler is not waited for a third time"
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
run_quiesce ABLETON_TEST_APPROVED_STOP=1 "$base/runtime" "$base/staging-prefix"
grep -qx 'rc=0' "$base/out" || fail "an explicitly named prefix is quiesced"
[ "$(quiesce_calls)" = "-w stop -w " ] || fail "the named prefix is stopped after its wait expires"
! grep -q -- "prefix=$base/prefix\$" "$base/log" || fail "a named prefix displaces the configured one"
ok "the runtime and prefix a caller names override the configured pair"

# The payload step's own wait, on the promoted prefix.  Every sub-script is stubbed
# so install_live_payload is reached with a wineserver whose -w never returns.
base="$(new_env payload-wait)"
kit="$base/kit"
mkdir -p "$kit/scripts/lib" "$kit/bin" "$base/runtime/bin"
cp -- "$here/installer.sh" "$kit/scripts/"
cp -- "$here/lib/config.sh" "$here/lib/lifecycle.sh" "$here/lib/live-options.sh" \
    "$here/lib/manifest.sh" "$here/lib/pipeasio.sh" "$here/lib/preferences.sh" \
    "$here/lib/ui.sh" \
    "$kit/scripts/lib/"
cat > "$kit/bin/pipewire-version-probe" <<'EOF'
#!/bin/sh
printf 'client=1.4.2\ndaemon=1.4.2\n'
EOF
cat > "$kit/scripts/install.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'component %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
case " $* " in
    *' --integration-only '*)
        [ "${ABLETON_TEST_CONFIG_DIRECTORY:-0}" -eq 0 ] \
            || mkdir -p -- "${ABLETON_CONFIG_FILE:?}"
        exit "${ABLETON_TEST_INTEGRATION_EXIT:-0}" ;;
    *' --commit '*) exit "${ABLETON_TEST_COMPONENT_COMMIT_EXIT:-0}" ;;
esac
exit 0
EOF
cat > "$kit/scripts/setup-prefix.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'prefix %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
case " $* " in
    *' --preflight-commit '*|*' --preflight-rollback '*) exit 0 ;;
    *' --commit '*) exit "${ABLETON_TEST_PREFIX_COMMIT_EXIT:-0}" ;;
    *' --rollback '*) rm -rf -- "${ABLETON_WINEPREFIX:?}"; exit 0 ;;
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
case "$*" in
    *'Ableton Live 12 Suite Installer.exe'*)
        if [ "${ABLETON_TEST_SKIP_LIVE_EXE:-0}" -eq 0 ]; then
            live_dir="${WINEPREFIX:?}/drive_c/ProgramData/Ableton/Live 12 Suite/Program"
            mkdir -p -- "$live_dir"
            printf 'exe\n' > "$live_dir/Ableton Live 12 Suite.exe"
        fi ;;
esac
exit 0
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
    local payload="$base/Ableton Live 12 Suite Installer.exe"
    if [ "${1:-}" = --payload ]; then
        payload="$2"
        shift 2
    fi
    : > "$base/calls.log"
    rm -rf -- "$base/prefix" "$base/config" "$base/state" "$base/data"
    run_isolated "$base" env ABLETON_TEST_CALL_LOG="$base/calls.log" "$@" \
        bash "$kit/scripts/installer.sh" install \
            --live-installer "$payload" \
            --link=off --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
        >"$base/out" 2>"$base/err"
}

# 124 is timeout's TERM verdict: the wait ran out with a process still in the prefix.
run_payload_install ABLETON_TEST_WAIT_EXIT=124 || fail "an expired payload wait fails the install"
grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
    || fail "an expired payload wait leaves the install incomplete"
! grep -q 'wineserver -k' "$base/calls.log" || fail "the payload step stops the promoted prefix"
grep -q 'The Live installer finished; a background program is still using its ableton-linux prefix' "$base/out" \
    || fail "an expired payload wait goes unreported"
grep -qF -- "$base/runtime/bin/wineserver -k" "$base/out" \
    || fail "the report withholds the command that ends the prefix"
! grep -q 'End every program' "$base/out" "$base/err" \
    || fail "a non-interactive install offers to end the prefix"
[ "$(grep -c '^│  ┃ [1-7]/7 ╏ ' "$base/out")" -eq 7 ] \
    || fail "a checkout install renders its seven numbered steps"
grep -qF '│  ┃ 7/7 ╏ FINISH THE INSTALLATION ┃' "$base/out" \
    || fail "the final step is the finish step"
[ "$(grep -c '^│  └─ Step [1-7] Complete! ✓$' "$base/out")" -eq 7 ] \
    || fail "every step closes with its own number"
! grep -q '^│  ├─ .* 𐄂$\|^│  │  𐄂 ' "$base/out" \
    || fail "a completed install shows a failed item"
ok "an expired payload wait reports the straggler, stops nothing, and still completes"

run_payload_install ABLETON_TEST_WAIT_EXIT=127 \
    || fail "an unavailable post-install Wine check fails a validated Live install"
grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
    || fail "an unavailable post-install Wine check hides the completed install"
grep -q 'Live is installed, but Wine could not be checked afterward (exit 127)' "$base/err" \
    || fail "an unavailable post-install Wine check was not reported as advisory"
if grep -Eq -- '--rollback |^component --rollback |^prefix --rollback ' "$base/calls.log"; then
    fail "an unavailable post-install Wine check rolled back validated Live files"
fi
ok "every post-install Wine wait failure is advisory after Live validation"

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
! grep -q 'The Live installer finished' "$base/out" || fail "a quiet prefix is reported as busy"
ok "a quiet prefix after the payload reports nothing"

# The coordinator does not extract Visual C++ cabinets itself. The prefix path
# that actually needs cabextract owns that dependency check; another selected
# prefix implementation must not be rejected by a redundant parent preflight.
cat > "$base/no-cabextract.bash" <<'EOF'
command()
{
    if [ "${1:-}" = -v ] && [ "${2:-}" = cabextract ]; then
        return 1
    fi
    builtin command "$@"
}
EOF
run_payload_install BASH_ENV="$base/no-cabextract.bash" \
    || fail "the coordinator required cabextract before reaching the selected prefix path"
grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
    || fail "the redundant cabextract preflight hid the completed install"
ok "cabextract is checked only by the prefix extraction path that uses it"

# Progress text and archive member listings are presentation, not install
# postconditions. A failed progress write must not roll back the extracted and
# validated Live payload.
(
    cd "$base"
    python3 -m zipfile -c 'Ableton Live 12 Suite.zip' \
        'Ableton Live 12 Suite Installer.exe'
)
cat > "$base/payload-progress-failure.bash" <<'EOF'
echo()
{
    case "$*" in
        --\ Extracting\ the\ Live\ installer\ \(*|--\ Running\ the\ Live\ installer\ \(*) return 74 ;;
    esac
    builtin echo "$@"
}
EOF
run_payload_install --payload "$base/Ableton Live 12 Suite.zip" \
    BASH_ENV="$base/payload-progress-failure.bash" \
    || fail "failed Live progress output rolled back a valid ZIP installation"
grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
    || fail "failed Live progress output hid the completed installation"
if grep -Eq '(^|[[:space:]])(inflating:|extracting:|creating:)' "$base/out"; then
    fail "Live ZIP extraction printed its archive member list"
fi
if grep -Eq -- '--rollback |^component --rollback |^prefix --rollback ' "$base/calls.log"; then
    fail "failed Live progress output started core rollback"
fi
ok "Live ZIP extraction is quiet and progress output cannot gate valid work"

# A successful Wine process is not proof that Live was installed. The selected
# major must leave a regular executable in the promoted prefix before the core
# work can commit.
if run_payload_install ABLETON_TEST_SKIP_LIVE_EXE=1; then
    fail "Wine exit 0 without a Live executable succeeds"
fi
grep -q 'exited without installing Ableton Live 12 in the selected prefix' "$base/err" \
    || fail "missing Live executable failure does not name the unmet postcondition"
if ! grep -q 'prefix --preflight-rollback ' "$base/calls.log" \
   || ! grep -q 'component --preflight-rollback ' "$base/calls.log" \
   || ! grep -q 'prefix --rollback ' "$base/calls.log" \
   || ! grep -q 'component --rollback ' "$base/calls.log"; then
    fail "missing Live executable does not roll back the core install"
fi
[ ! -e "$base/prefix" ] || fail "missing Live executable leaves the fresh prefix promoted"
! grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
    || fail "missing Live executable reports success"
ok "Wine exit 0 without the selected Live executable fails and rolls back"

# Desktop integration status 3 is a repair request after the core install has
# committed. The final warning and summary must preserve that distinction.
live_exe="$base/prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe"
run_payload_install ABLETON_TEST_INTEGRATION_EXIT=3 \
    || fail "desktop integration retry status rejects a completed install"
grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
    || fail "desktop integration retry status hides the completed install"
[ -x "$base/runtime/bin/wine" ] && [ -f "$base/prefix/system.reg" ] \
    && [ -f "$live_exe" ] \
    || fail "desktop integration retry status discards the committed core"
! grep -q -- '--rollback' "$base/calls.log" \
    || fail "desktop integration retry status rolls back the committed core"
grep -qF 'Ableton Live 12 is installed, but some desktop files need another update. Run the installer again to retry them.' \
    "$base/err" || fail "desktop integration retry status omits its repair warning"
grep -qF 'Desktop shortcuts need another try' "$base/out" \
    || fail "desktop integration retry status is missing from the final summary"
ok "desktop integration retry status preserves the core and names the remaining repair"

# A settings-path collision can appear after the core commit. Project settings
# use the same simple rule as every other optional destination: move the old
# object into this run's inert backup directory, then install the new file.
mkdir -p -- "$base/stale-backup/.overwrite-all"
run_payload_install ABLETON_TEST_CONFIG_DIRECTORY=1 \
    ABLETON_PROJECT_BACKUP_DIR="$base/stale-backup" \
    ABLETON_PROJECT_BACKUP_STAMP=old \
    || fail "saved-settings overwrite rejects a completed install"
grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
    || fail "saved-settings overwrite hides the completed install"
[ -x "$base/runtime/bin/wine" ] && [ -f "$base/prefix/system.reg" ] \
    && [ -f "$live_exe" ] \
    || fail "saved-settings overwrite discards the committed core"
! grep -q -- '--rollback' "$base/calls.log" \
    || fail "saved-settings overwrite rolls back the committed core"
[ -f "$base/config/ableton-wine/config" ] \
    || fail "saved-settings overwrite did not install the settings file"
grep -qF 'Saved settings are ready' "$base/out" \
    || fail "saved-settings overwrite is missing from the final summary"
settings_backup="$(find "$base/state/ableton-wine/backups" -type d \
    -name 'config.bak-*' -print -quit 2>/dev/null || true)"
[ -n "$settings_backup" ] \
    || fail "saved-settings overwrite did not retain the displaced directory"
! find "$base/stale-backup" -type f -print -quit | grep -q . \
    || fail "an old Overwrite all marker leaked into a new installer run"
ok "saved-settings collisions are backed up after the core commit"

# Link setup runs after the core runtime, prefix, and Live installation commit.
# Any Link failure keeps that usable core and reports a concrete retry command.
cat > "$kit/scripts/setup-link.sh" <<'EOF'
#!/bin/sh
set -eu
printf 'link %s\n' "$*" >> "${ABLETON_TEST_CALL_LOG:?}"
[ "${1:-}" = enable ] || exit 0
exit "${ABLETON_TEST_LINK_ENABLE_EXIT:-0}"
EOF
run_failed_link_install()
{
    : > "$base/calls.log"
    rm -rf -- "$base/prefix" "$base/config" "$base/state" "$base/data"
    run_isolated "$base" env ABLETON_INSTALLER_PATH="$link_installer" \
        ABLETON_TEST_CALL_LOG="$base/calls.log" ABLETON_TEST_LINK_ENABLE_EXIT="$1" \
        bash "$kit/scripts/installer.sh" install \
            --live-installer "$base/Ableton Live 12 Suite Installer.exe" \
            --link=always --runtime-root "$base/runtime" --prefix "$base/prefix" --yes \
        >"$base/out" 2>"$base/err"
}
link_installer="$base/Downloads/Ableton Installer.run"
printf -v quoted_link_installer '%q' "$link_installer"
link_resume_command="sh $quoted_link_installer link enable --mode=always"
for link_failure in 1 70 75; do
    run_failed_link_install "$link_failure" \
        || fail "full install fails when Link exits $link_failure"
    grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
        || fail "Link failure $link_failure hides the completed Live install"
    [ -x "$base/runtime/bin/wine" ] && [ -f "$base/prefix/system.reg" ] \
        && [ -f "$live_exe" ] \
        || fail "Link failure $link_failure discards the runtime, prefix, or Live executable"
    ! grep -q -- '--rollback' "$base/calls.log" \
        || fail "Link failure $link_failure rolls back the completed core install"
    grep -qF "Ableton Live 12 is installed, but Link could not be set up. Retry with: $link_resume_command" "$base/err" \
        || fail "Link failure $link_failure omits the retry command and completed outcome"
    grep -qF 'Link is unchanged; you can retry its setup' "$base/out" \
        || fail "Link failure $link_failure summary does not report retryable Link state"
done
ok "all Link failure statuses preserve a completed install with retry wording"

# Updates use the same boundary: Link remains retryable after the updated core
# has committed, regardless of the helper's failure classification.
for link_failure in 1 70 75; do
    : > "$base/calls.log"
    run_isolated "$base" env ABLETON_INSTALLER_PATH="$link_installer" \
        ABLETON_TEST_CALL_LOG="$base/calls.log" ABLETON_TEST_LINK_ENABLE_EXIT="$link_failure" \
        bash "$kit/scripts/installer.sh" update --link=always --yes \
        >"$base/out" 2>"$base/err" \
        || fail "full update fails when Link exits $link_failure"
    grep -q '^│  ├─ Ableton is updated' "$base/out" \
        || fail "Link failure $link_failure hides the completed update"
    [ -x "$base/runtime/bin/wine" ] && [ -f "$base/prefix/system.reg" ] \
        && [ -f "$live_exe" ] \
        || fail "Link failure $link_failure discards the updated runtime, prefix, or Live executable"
    ! grep -q -- '--rollback' "$base/calls.log" \
        || fail "Link failure $link_failure rolls back the completed update"
    grep -qF "Ableton is updated, but Link could not be set up. Retry with: $link_resume_command" "$base/err" \
        || fail "update Link failure $link_failure omits the retry command and outcome"
    grep -qF 'Link is unchanged; you can retry its setup' "$base/out" \
        || fail "update Link failure $link_failure summary does not report retryable Link state"
done
ok "all Link failure statuses preserve a completed update with retry wording"

# Cleanup happens only after the usable core is committed. A cleanup failure
# retains recovery files and warns, but must not turn that install into failure.
for cleanup_failure in component prefix; do
    cleanup_env=()
    case "$cleanup_failure" in
        component) cleanup_env+=(ABLETON_TEST_COMPONENT_COMMIT_EXIT=9) ;;
        prefix) cleanup_env+=(ABLETON_TEST_PREFIX_COMMIT_EXIT=9) ;;
    esac
    run_payload_install "${cleanup_env[@]}" \
        || fail "$cleanup_failure cleanup failure rejects a completed install"
    grep -q '^│  ├─ Ableton Live 12 is installed' "$base/out" \
        || fail "$cleanup_failure cleanup failure hides the completed install"
    grep -q 'old recovery files could not be removed' "$base/err" \
        || fail "$cleanup_failure cleanup failure omits its warning"
    [ -x "$base/runtime/bin/wine" ] && [ -f "$base/prefix/system.reg" ] \
        && [ -f "$live_exe" ] \
        || fail "$cleanup_failure cleanup failure discards the committed core"
    ! grep -q -- '--rollback' "$base/calls.log" \
        || fail "$cleanup_failure cleanup failure rolls back the committed core"
done
ok "cleanup failures warn and preserve a successful install"

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
refusal_leaves_busy_prefix_alone refusal-max-lock    max9         'another Live or Max launch is starting' "$live_holder" max  1
refusal_leaves_busy_prefix_alone refusal-live-lock   ableton-live 'another Live or Max launch is starting' "$other_holder" live 1
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

# Retained transactions from older releases can still contain a host-file
# journal. Recovery keeps understanding that format even though new prefix
# setup runs no longer create an empty one.
base="$(new_env legacy-prefix-host-transaction)"
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

# A current prefix transaction contains only the prefix layout record. It must
# not need a fabricated empty host-file journal in order to recover.
base="$(new_env prefix-layout-only-transaction)"
prefix="$base/prefix"
txn="$base/txn"
backup="$prefix.transaction-${txn##*/}"
mkdir -p -- "$prefix" "$backup" "$txn"
printf 'format=1\nprefix=%s\n' "$prefix" > "$prefix/.ableton-linux-prefix"
printf 'format=1\nprefix=%s\n' "$prefix" > "$backup/.ableton-linux-prefix"
printf 'new prefix\n' > "$prefix/generation"
printf 'old prefix\n' > "$backup/generation"
printf '%s\t%s\n' "$prefix" "$backup" > "$txn/prefix.tsv"
run_isolated "$base" env ABLETON_WINEPREFIX="$prefix" \
    bash "$here/setup-prefix.sh" --preflight-rollback "$txn" \
    || fail "prefix recovery required an empty host-file journal"
run_isolated "$base" env ABLETON_WINEPREFIX="$prefix" \
    bash "$here/setup-prefix.sh" --rollback "$txn" \
    || fail "prefix-only recovery failed without a host-file journal"
grep -qxF 'old prefix' "$prefix/generation" \
    && [ ! -e "$backup" ] && [ ! -e "$txn/prefix.tsv" ] \
    || fail "prefix-only recovery did not restore the saved prefix"
ok "prefix recovery needs no empty host-file journal"

# Canonical encoding cannot make malformed seed ownership trustworthy. Every
# production recovery entry point must reject it before touching the current
# settings, the journal, or the coordinator's active marker.
base="$(new_env malformed-pipeasio-seed-recovery)"
prefix="$base/prefix"
txn="$base/txn"
pipeasio="$base/config/pipeasio/config.ini"
active="$txn/active"
journal="$txn/pipeasio-seed.v1"
mkdir -p -- "$txn" "$(dirname "$pipeasio")"
printf '[pipeasio]\nbuffer_size = 512\n' > "$pipeasio"
printf 'active recovery evidence\n' > "$active"
path_b64="$(printf '%s' "$pipeasio" | base64 | tr -d '\n')"
token_b64="$(printf '%s' 'file|garbage' | base64 | tr -d '\n')"
printf 'format=1\npath_b64=%s\ntoken_b64=%s\ntemp_b64=\n' \
    "$path_b64" "$token_b64" > "$journal"
journal_before="$(lifecycle_object_snapshot "$journal")"
pipeasio_before="$(lifecycle_object_snapshot "$pipeasio")"
active_before="$(lifecycle_object_snapshot "$active")"
for recovery_operation in --preflight-rollback --rollback --preflight-commit --commit; do
    if run_isolated "$base" env ABLETON_WINEPREFIX="$prefix" \
        bash "$here/setup-prefix.sh" "$recovery_operation" "$txn" \
        >"$base/${recovery_operation#--}.out" \
        2>"$base/${recovery_operation#--}.err"; then
        fail "setup-prefix accepts malformed PipeASIO evidence for $recovery_operation"
    fi
    [ "$(lifecycle_object_snapshot "$journal")" = "$journal_before" ] \
        && [ "$(lifecycle_object_snapshot "$pipeasio")" = "$pipeasio_before" ] \
        && [ "$(lifecycle_object_snapshot "$active")" = "$active_before" ] \
        || fail "setup-prefix $recovery_operation changes malformed recovery evidence or settings"
done
ok "every prefix recovery entry point preserves malformed PipeASIO evidence"

# The EXIT handler has enough state to decide whether a late failure happened
# before or after the prefix became usable. Diagnostic output is not part of
# that decision, and a ready prefix must not also be reported as rolled back.
base="$(new_env prefix-cleanup-output)"
extract_setup_prefix_function()
{
    awk -v signature="$1()" \
        '$0 == signature { copy=1 } copy { print } copy && /^}$/ { exit }' \
        "$here/setup-prefix.sh" > "$2"
}
extract_setup_prefix_function prefix_cleanup "$base/prefix-cleanup.function"
grep -q '^prefix_cleanup()$' "$base/prefix-cleanup.function" \
    || fail "prefix cleanup test could not load the production handler"
mkdir -p "$base/core-txn" "$base/commit-txn"
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1"
    prefix_core_ready=1
    prefix_commit_started=0
    prefix_promoted=1
    transaction_dir="$2"
    final_prefix="$3"
    stage_prefix="$4"
    ui_cleanup() { :; }
    prefix_transaction_rollback() { return 0; }
    trap prefix_cleanup EXIT
    false
' cleanup "$base/prefix-cleanup.function" "$base/core-txn" \
    "$base/prefix" "$base/stage" > "$base/core.out" 2> /dev/full \
    || fail "closed diagnostics changed a ready prefix into failure"
[ ! -e "$base/core-txn/prefix-failure" ] \
    || fail "a ready prefix was also recorded as a rolled-back failure"
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1"
    prefix_core_ready=0
    prefix_commit_started=1
    prefix_promoted=1
    transaction_dir="$2"
    final_prefix="$3"
    stage_prefix="$4"
    ui_cleanup() { :; }
    prefix_transaction_rollback() { return 0; }
    trap prefix_cleanup EXIT
    false
' cleanup "$base/prefix-cleanup.function" "$base/commit-txn" \
    "$base/prefix" "$base/stage" > "$base/commit.out" 2> /dev/full \
    || fail "closed diagnostics changed a committed prefix into failure"
[ -f "$base/commit-txn/COMMITTED_CLEANUP_FAILURE" ] \
    || fail "committed prefix cleanup did not retain its recovery record"
ok "prefix cleanup follows the prefix state when diagnostic output is closed"

# These helpers run after their durable outcome is known: writing defaults is
# optional, an extracted Live payload is disposable, and the legacy prefix
# marker has already been published before its informational report.
extract_setup_prefix_function write_default_pipeasio_settings \
    "$base/pipeasio-defaults.function"
extract_setup_prefix_function remove_extracted_live_installer \
    "$base/live-cleanup.function"
mkdir -p -- "$base/defaults-txn" "$base/selected-defaults-txn" \
    "$base/raced-defaults-txn"
run_isolated "$base" env XDG_CONFIG_HOME="$base/defaults" \
    ABLETON_TEST_SEED_ORDER_LOG="$base/defaults-order.log" bash -c '
    set -euo pipefail
    . "$1"
    . "$2"
    . "$3"

    eval "$(declare -f ableton_pipeasio_seed_record_publish \
        | sed "1s/^ableton_pipeasio_seed_record_publish/production_seed_record_publish/")"
    eval "$(declare -f ableton_pipeasio_seed_record_promote \
        | sed "1s/^ableton_pipeasio_seed_record_promote/production_seed_record_promote/")"
    seed_case=normal
    inject_destination_race=0
    ableton_pipeasio_seed_record_publish()
    {
        local txn="$1" final="$2" token="$3" temp="$4"
        [ ! -e "$final" ] && [ ! -L "$final" ] \
            && [ -f "$temp" ] && [ ! -L "$temp" ] \
            || return 81
        printf "%s-publish-before\n" "$seed_case" \
            >> "${ABLETON_TEST_SEED_ORDER_LOG:?}"
        production_seed_record_publish "$@" || return
        ableton_pipeasio_seed_record_load "$txn" \
            && [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ] \
            && [ "$ABLETON_PIPEASIO_SEED_PATH" = "$final" ] \
            && [ "$ABLETON_PIPEASIO_SEED_TOKEN" = "$token" ] \
            && [ "$ABLETON_PIPEASIO_SEED_TEMP" = "$temp" ] \
            && [ ! -e "$final" ] && [ -f "$temp" ] && [ ! -L "$temp" ] \
            || return 82
        printf "%s-publish-after\n" "$seed_case" \
            >> "${ABLETON_TEST_SEED_ORDER_LOG:?}"
        if [ "$inject_destination_race" -eq 1 ]; then
            cp -- "$temp" "$final.race"
            mv -T -n -- "$final.race" "$final"
            [ -f "$final" ] && [ ! -L "$final" ] \
                && [ "$(ableton_pipeasio_seed_identity_token "$final")" != "$token" ] \
                || return 83
            printf "%s-race-injected\n" "$seed_case" \
                >> "${ABLETON_TEST_SEED_ORDER_LOG:?}"
        fi
    }
    ableton_pipeasio_seed_record_promote()
    {
        local txn="$1" final="$2" token="$3"
        [ "$inject_destination_race" -eq 0 ] || return 84
        ableton_pipeasio_seed_record_load "$txn" \
            && [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ] \
            && [ "$ABLETON_PIPEASIO_SEED_TOKEN" = "$token" ] \
            && [ -n "$ABLETON_PIPEASIO_SEED_TEMP" ] \
            && [ ! -e "$ABLETON_PIPEASIO_SEED_TEMP" ] \
            && [ ! -L "$ABLETON_PIPEASIO_SEED_TEMP" ] \
            && [ -f "$final" ] && [ ! -L "$final" ] \
            && [ "$(ableton_pipeasio_seed_identity_token "$final")" = "$token" ] \
            || return 85
        printf "%s-promote-before\n" "$seed_case" \
            >> "${ABLETON_TEST_SEED_ORDER_LOG:?}"
        production_seed_record_promote "$@" || return
        ableton_pipeasio_seed_record_load "$txn" \
            && [ "$ABLETON_PIPEASIO_SEED_PRESENT" -eq 1 ] \
            && _ableton_pipeasio_full_token_valid "$ABLETON_PIPEASIO_SEED_TOKEN" \
            && [ -z "$ABLETON_PIPEASIO_SEED_TEMP" ] \
            && [ "$ABLETON_PIPEASIO_SEED_TOKEN" \
                 = "$(ableton_preferences_object_token "$final")" ] \
            || return 86
        printf "%s-promote-after\n" "$seed_case" \
            >> "${ABLETON_TEST_SEED_ORDER_LOG:?}"
    }

    transaction_dir="$4"
    write_default_pipeasio_settings > /dev/full
    [ -f "$XDG_CONFIG_HOME/pipeasio/config.ini" ] \
        && grep -qxF "buffer_size = 256" \
            "$XDG_CONFIG_HOME/pipeasio/config.ini" \
        && [ -f "$transaction_dir/pipeasio-seed.v1" ]
    ableton_pipeasio_seed_record_commit "$transaction_dir"

    for selected_seed in 64 128 256 512 1024; do
        seed_case="selected-$selected_seed"
        inject_destination_race=0
        XDG_CONFIG_HOME="$5/$selected_seed"
        export XDG_CONFIG_HOME
        transaction_dir="$6/$selected_seed"
        mkdir -p -- "$transaction_dir"
        ABLETON_PIPEASIO_BUFFER_SEED="$selected_seed"
        export ABLETON_PIPEASIO_BUFFER_SEED
        write_default_pipeasio_settings > /dev/full
        grep -qxF "buffer_size = $selected_seed" \
            "$XDG_CONFIG_HOME/pipeasio/config.ini"
        ableton_pipeasio_seed_record_commit "$transaction_dir"
    done
    unset ABLETON_PIPEASIO_BUFFER_SEED

    seed_case=raced
    inject_destination_race=1
    XDG_CONFIG_HOME="$7"
    export XDG_CONFIG_HOME
    transaction_dir="$8"
    write_default_pipeasio_settings > /dev/full
    raced_cfg="$XDG_CONFIG_HOME/pipeasio/config.ini"
    [ -f "$raced_cfg" ] && [ ! -L "$raced_cfg" ] \
        && [ ! -e "$transaction_dir/pipeasio-seed.v1" ] \
        && ! find "$(dirname "$raced_cfg")" -maxdepth 1 \
            -name ".config.ini.*" -print -quit | grep -q .
    cmp -s -- "$9/pipeasio/config.ini" "$raced_cfg"

    mapfile -t observed_order < "${ABLETON_TEST_SEED_ORDER_LOG:?}"
    expected_order=(normal-publish-before normal-publish-after
        normal-promote-before normal-promote-after)
    for selected_seed in 64 128 256 512 1024; do
        expected_order+=("selected-$selected_seed-publish-before"
            "selected-$selected_seed-publish-after"
            "selected-$selected_seed-promote-before"
            "selected-$selected_seed-promote-after")
    done
    expected_order+=(raced-publish-before raced-publish-after
        raced-race-injected)
    [ "${observed_order[*]}" = "${expected_order[*]}" ]
' defaults "$base/pipeasio-defaults.function" "$here/lib/ui.sh" \
    "$here/lib/preferences.sh" "$base/defaults-txn" \
    "$base/selected-defaults" "$base/selected-defaults-txn" \
    "$base/raced-defaults" "$base/raced-defaults-txn" "$base/defaults" \
    || fail "production PipeASIO writer violated publication ordering or no-clobber recovery"
[ -f "$base/defaults/pipeasio/config.ini" ] \
    || fail "closed output stopped default PipeASIO settings from being written"
[ ! -e "$base/defaults-txn/pipeasio-seed.v1" ] \
    || fail "successful default-settings fixture did not retire seed provenance"
for selected_seed in 64 128 256 512 1024; do
    grep -qxF "buffer_size = $selected_seed" \
        "$base/selected-defaults/$selected_seed/pipeasio/config.ini" \
        || fail "production PipeASIO writer ignored selected seed $selected_seed"
    [ ! -e "$base/selected-defaults-txn/$selected_seed/pipeasio-seed.v1" ] \
        || fail "selected seed $selected_seed retained committed provenance"
done
[ -f "$base/raced-defaults/pipeasio/config.ini" ] \
    && [ ! -e "$base/raced-defaults-txn/pipeasio-seed.v1" ] \
    || fail "real writer no-clobber recovery removed a raced destination or retained provenance"
mkdir -p "$base/blocked"
printf 'not a directory\n' > "$base/blocked/pipeasio"
run_isolated "$base" env XDG_CONFIG_HOME="$base/blocked" bash -c '
    set -euo pipefail
    . "$1"
    . "$2"
    . "$3"
    transaction_dir="$4"
    write_default_pipeasio_settings
' defaults "$base/pipeasio-defaults.function" "$here/lib/ui.sh" \
    "$here/lib/preferences.sh" "$base/blocked-txn" \
    > "$base/defaults.out" 2> /dev/full \
    || fail "an unwritable optional PipeASIO settings path failed prefix setup"
mkdir -p "$base/unpack" "$base/fakebin"
printf 'payload\n' > "$base/unpack/file"
cat > "$base/fakebin/rm" <<'EOF'
#!/bin/sh
exit "${TEST_RM_RC:-1}"
EOF
chmod +x "$base/fakebin/rm"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash -c '
    set -euo pipefail
    . "$1"
    remove_extracted_live_installer "$2"
' cleanup "$base/live-cleanup.function" "$base/unpack" \
    > "$base/cleanup.out" 2> /dev/full \
    || fail "an extracted Live payload cleanup warning failed prefix setup"
[ -f "$base/unpack/file" ] \
    || fail "the cleanup warning fixture did not preserve its failed target"
ln -s -- "$base/missing-live-installer" "$base/unpack-link"
run_isolated "$base" env PATH="$base/fakebin:$PATH" TEST_RM_RC=0 bash -c '
    set -euo pipefail
    . "$1"
    remove_extracted_live_installer "$2"
' cleanup "$base/live-cleanup.function" "$base/unpack-link" \
    > "$base/cleanup-link.out" 2> "$base/cleanup-link.err" \
    || fail "a disposable Live installer cleanup report failed prefix setup"
[ -L "$base/unpack-link" ] \
    || fail "the successful-rm residue fixture did not retain its dangling link"
grep -qF 'Temporary Ableton Live installer files remain at' "$base/cleanup-link.err" \
    || fail "Live installer cleanup trusted rm status instead of its postcondition"
if grep -qF 'Live is installed' "$base/cleanup-link.err"; then
    fail "temporary Live installer cleanup claimed that Live was installed"
fi
run_isolated "$base" bash -c '
    set -euo pipefail
    . "$1"
    ui_status p_using_existing_prefix "$2" > /dev/full
' report "$here/lib/ui.sh" "$base/prefix" \
    || fail "closed output failed after a legacy prefix was adopted"
ok "optional prefix reports cannot reverse completed or nonessential work"

# Automatic display detection is advisory. A missing detector, a scale outside
# the calibrated range, or an unverifiable GNOME native-scaling feature must
# choose a safe fresh-prefix default instead of refusing Wine setup; explicitly
# invalid input remains an input error.
base="$(new_env automatic-dpi-fallback)"
sed -n '/^case "$dpi_mode" in$/,/^esac$/p' "$here/setup-prefix.sh" \
    > "$base/dpi-selection.bash"
grep -q '^case "$dpi_mode" in$' "$base/dpi-selection.bash" \
    || fail "DPI fallback test could not load the production selection logic"
for detector in unavailable out-of-range; do
    run_isolated "$base" bash -c '
        set -euo pipefail
        fresh_prefix=1
        dpi_mode=auto
        dpi_block=preserve
        dpi_family=""
        ui_item_begin() { :; }; ui_item_end() { :; }; ui_run() { shift; while [ "$1" != -- ]; do shift; done; shift; "$@"; }
        ui_status() { :; }; ui_info() { :; }; ui_warn() { :; }
        current_dpi_block() { printf "custom\n"; }
        if [ "$2" = unavailable ]; then
            ableton_detect_scale_ex() { return 1; }
        else
            ableton_detect_scale_ex() { printf "3.00 gnome\n"; }
        fi
        block_for_scale() { return 1; }
        ableton_dpi_block_values() { return 1; }
        . "$1"
        [ "$dpi_block" = 100 ]
    ' dpi "$base/dpi-selection.bash" "$detector" \
        || fail "$detector automatic display detection refused a fresh prefix"
done
for native_state in active unavailable; do
    run_isolated "$base" bash -c '
        set -euo pipefail
        fresh_prefix=1
        dpi_mode=auto
        dpi_block=preserve
        dpi_family=""
        ui_item_begin() { :; }; ui_item_end() { :; }; ui_run() { shift; while [ "$1" != -- ]; do shift; done; shift; "$@"; }
        ui_status() { :; }; ui_info() { :; }; ui_warn() { :; }
        current_dpi_block() { printf "custom\n"; }
        ableton_detect_scale_ex() { printf "1.33333 gnome\n"; }
        block_for_scale() { printf "fractional\n"; }
        ableton_dpi_block_values() { return 1; }
        if [ "$2" = active ]; then
            gnome_native_scaling_active() { return 0; }
        else
            gnome_native_scaling_active() { return 1; }
        fi
        . "$1"
        if [ "$2" = active ]; then
            [ "$dpi_block" = fractional ]
        else
            [ "$dpi_block" = 100 ]
        fi
    ' dpi "$base/dpi-selection.bash" "$native_state" \
        || fail "$native_state GNOME native-scaling state selected an unsafe fresh-prefix DPI block"
done
if run_isolated "$base" bash -c '
    set -euo pipefail
    fresh_prefix=1
    dpi_mode=not-a-mode
    dpi_block=preserve
    dpi_family=""
    ui_item_begin() { :; }; ui_item_end() { :; }; ui_run() { shift; while [ "$1" != -- ]; do shift; done; shift; "$@"; }
    ui_status() { :; }; ui_info() { :; }; ui_warn() { :; }
    . "$1"
' dpi "$base/dpi-selection.bash"; then
    fail "an explicitly invalid display mode was accepted"
fi
ok "fresh Wine setup falls back to 100% only for automatic display detection"

# Public integration publishes the exact successful outputs it owns. The
# low-level manual-backup path has its separate focused helper suite.
prepare_manifest_integration_fixture()
{
    local fixture="$1"
    mkdir -p -- "$fixture/runtime/bin" \
        "$fixture/runtime/share/applications" \
        "$fixture/runtime/share/icons/hicolor/scalable/apps" \
        "$fixture/fakebin"
    cat > "$fixture/runtime/bin/pipeasio-settings" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$fixture/runtime/bin/pipeasio-settings"
    cat > "$fixture/runtime/share/applications/pipeasio-settings.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PipeASIO Settings
Exec=pipeasio-settings
Icon=pipeasio
EOF
    printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' \
        > "$fixture/runtime/share/icons/hicolor/scalable/apps/pipeasio.svg"
    printf 'pipeasio-panel: built\n' \
        > "$fixture/runtime/ABLETON-WINE-BUILD-INFO.txt"
    printf '#!/bin/sh\nexit 0\n' > "$fixture/external-linkd"
    chmod +x "$fixture/external-linkd"
    cat > "$fixture/fakebin/xdg-mime" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = default ] && [ "$#" -ge 3 ] || exit 2
desktop="$2"
shift 2
file="${XDG_CONFIG_HOME:?}/mimeapps.list"
mkdir -p -- "$(dirname "$file")"
[ -e "$file" ] || printf '[Default Applications]\n' > "$file"
for type do
    grep -qF "$type=" "$file" || printf '%s=%s\n' "$type" "$desktop" >> "$file"
done
EOF
    printf '#!/bin/sh\nexit 0\n' > "$fixture/fakebin/update-mime-database"
    printf '#!/bin/sh\nexit 0\n' > "$fixture/fakebin/update-desktop-database"
    chmod +x "$fixture/fakebin/xdg-mime" \
        "$fixture/fakebin/update-mime-database" \
        "$fixture/fakebin/update-desktop-database"
}

run_manifest_integration()
{
    local fixture="$1"
    shift
    run_isolated "$fixture" env PATH="$fixture/fakebin:$PATH" \
        ABLETON_WINE_ROOT="$fixture/runtime" \
        ABLETON_LINKD="$fixture/external-linkd" "$@" \
        bash "$here/install.sh" --integration-only --link-assets-only --yes
}

validate_manifest_integration_state()
{
    local fixture="$1"
    run_isolated "$fixture" env ABLETON_WINE_ROOT="$fixture/runtime" \
        ABLETON_LINKD="$fixture/external-linkd" bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        . "$1/lib/manifest.sh"
        ableton_config_init repair
        ableton_validate_ownership_manifest
        ableton_validate_prestate_store
    ' _ "$here"
}

assert_published_object()
{
    local manifest="$1" kind="$2" path="$3" digest="$4" description="$5"
    local row
    row="$(printf '%s\t%s\t%s' "$kind" "$path" "$digest")"
    [ "$(grep -cFx -- "$row" "$manifest")" -eq 1 ] \
        || fail "$description is not published once with its exact digest"
}

base="$(new_env manifest-integration)"
prepare_manifest_integration_fixture "$base"
unit="$base/config/systemd/user/ableton-linkd.service"
mimeapps="$base/config/mimeapps.list"
mkdir -p -- "$(dirname "$unit")"
printf 'foreign generated-unit destination\n' > "$unit"
cp -- "$unit" "$base/foreign-unit.before"
printf '[Default Applications]\ntext/plain=foreign.desktop\n' > "$mimeapps"
run_manifest_integration "$base" >"$base/out" 2>"$base/err" \
    || { sed -n '1,60p' "$base/err" >&2; fail "integration inventory was not published"; }
manifest="$base/state/ableton-wine/install-manifest.tsv"
prestate="$base/state/ableton-wine/install-prestate.tsv"
[ -f "$manifest" ] && [ ! -L "$manifest" ] \
    || fail "integration did not publish a regular ownership manifest"
validate_manifest_integration_state "$base" \
    || fail "integration published invalid manifest or prestate data"
[ "$(awk -F '\t' -v p="$base/runtime" -v n="$ABLETON_RUNTIME_NAME" \
        '$1=="runtime" { count++; if ($2==p && $3==n && NF==3) matching++ } \
        END { print count ":" matching+0 }' "$manifest")" = 1:1 ] \
    || fail "the installed-file list needs one runtime row for the selected runtime"

project_file="$base/data/ableton-wine/lib/config.sh"
project_digest="$(sha256sum -- "$project_file" | awk '{print $1}')"
assert_published_object "$manifest" file "$project_file" "$project_digest" \
    "a successful project file"

panel_link="$base/home/.local/bin/pipeasio-settings"
panel_target="$base/runtime/bin/pipeasio-settings"
panel_digest="$({ printf 'symlink\0'; printf '%s' "$panel_target"; } \
    | sha256sum | awk '{print $1}')"
[ -L "$panel_link" ] && [ "$(readlink -- "$panel_link")" = "$panel_target" ] \
    || fail "integration did not create the PipeASIO symlink fixture"
assert_published_object "$manifest" symlink "$panel_link" "$panel_digest" \
    "a successful project symlink"

mime_digest="$(sha256sum -- "$mimeapps" | awk '{print $1}')"
unit_digest="$(sha256sum -- "$unit" | awk '{print $1}')"
assert_published_object "$manifest" config "$mimeapps" "$mime_digest" \
    "the MIME application configuration"
assert_published_object "$manifest" config "$unit" "$unit_digest" \
    "the generated systemd unit"

unit_id="$(printf '%s' "$unit" | sha256sum | awk '{print $1}')"
unit_backup="$base/state/ableton-wine/install-prestate/$unit_id"
grep -qxF "$(printf 'present\t%s\t%s' "$unit" "$unit_backup")" "$prestate" \
    || fail "the first foreign systemd unit is not indexed as pre-install state"
cmp -s -- "$base/foreign-unit.before" "$unit_backup" \
    || fail "the saved first foreign systemd unit changed"
cp -- "$prestate" "$base/prestate.before"
cp -a -- "$unit_backup" "$base/unit-backup.before"
printf 'user edit after the first managed generation\n' > "$unit"
run_manifest_integration "$base" >"$base/update.out" 2>"$base/update.err" \
    || fail "a second integration publication failed"
if ! cmp -s -- "$base/prestate.before" "$prestate" \
   || ! cmp -s -- "$base/unit-backup.before" "$unit_backup"; then
    fail "a later integration replaced the first saved foreign object"
fi
validate_manifest_integration_state "$base" \
    || fail "updated integration state is invalid"
ok "integration publishes exact file, config and symlink outputs and keeps first prestate"

# One failed output is omitted while independent successes are still published;
# the public optional-status path makes that partial failure observable.
base="$(new_env manifest-output-failure)"
prepare_manifest_integration_fixture "$base"
cat > "$base/fakebin/cp" <<'EOF'
#!/bin/sh
for argument do
    [ "$argument" != "${ABLETON_TEST_FAIL_SOURCE:?}" ] || exit 74
done
exec /usr/bin/cp "$@"
EOF
cat > "$base/fakebin/install" <<'EOF'
#!/bin/sh
for argument do
    [ "$argument" != "${ABLETON_TEST_FAIL_SOURCE:?}" ] || exit 74
done
exec /usr/bin/install "$@"
EOF
chmod +x "$base/fakebin/cp" "$base/fakebin/install"
partial_status=0
run_manifest_integration "$base" \
    ABLETON_TEST_FAIL_SOURCE="$here/lib/lifecycle.sh" \
    ABLETON_INTERNAL_OPTIONAL_STATUS=1 \
    >"$base/out" 2>"$base/err" || partial_status=$?
[ "$partial_status" -eq 3 ] \
    || fail "a failed project output did not return the optional retry status"
manifest="$base/state/ableton-wine/install-manifest.tsv"
validate_manifest_integration_state "$base" \
    || fail "a partial integration published invalid state"
successful_target="$base/data/ableton-wine/lib/config.sh"
failed_target="$base/data/ableton-wine/lib/lifecycle.sh"
grep -qF "$(printf 'file\t%s\t' "$successful_target")" "$manifest" \
    || fail "a successful output was lost after another output failed"
! grep -qF "$(printf '\t%s\t' "$failed_target")" "$manifest" \
    || fail "a failed output was recorded as installed"
ok "partial integration records only successful outputs and returns nonzero"

# Publication itself is atomic: a failed final rename is nonzero and leaves the
# last validated generation byte-for-byte intact.
base="$(new_env manifest-publication-failure)"
prepare_manifest_integration_fixture "$base"
run_manifest_integration "$base" >"$base/first.out" 2>"$base/first.err" \
    || fail "manifest publication fixture did not complete its first generation"
manifest="$base/state/ableton-wine/install-manifest.tsv"
cp -- "$manifest" "$base/manifest.before"
cat > "$base/fakebin/mv" <<'EOF'
#!/bin/sh
last=""
for argument do last="$argument"; done
[ "$last" != "${ABLETON_TEST_FAIL_MANIFEST:?}" ] || exit 73
exec /usr/bin/mv "$@"
EOF
chmod +x "$base/fakebin/mv"
publication_status=0
run_manifest_integration "$base" ABLETON_TEST_FAIL_MANIFEST="$manifest" \
    >"$base/out" 2>"$base/err" || publication_status=$?
[ "$publication_status" -ne 0 ] \
    || fail "a failed manifest publication was reported as success"
cmp -s -- "$base/manifest.before" "$manifest" \
    || fail "a failed manifest publication changed the live generation"
validate_manifest_integration_state "$base" \
    || fail "a failed publication left invalid live state"
ok "manifest publication failure is nonzero and preserves the prior valid generation"

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

base="$(new_env link-unit-overwrite)"
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
cat > "$base/fakebin/systemctl" <<'EOF'
#!/bin/sh
unit="${XDG_CONFIG_HOME:?}/systemd/user/ableton-linkd.service"
case "$*" in
    *'show -p Version --value'*) echo 255 ;;
    *'show -p FragmentPath --value ableton-linkd.service'*) printf '%s\n' "$unit" ;;
    *'is-enabled --quiet ableton-linkd.service'*) exit 1 ;;
    *'is-active --quiet ableton-linkd.service'*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
cat > "$base/fakebin/grep" <<'EOF'
#!/bin/sh
for argument do
    [ "$argument" != /etc/ufw/ufw.conf ] || exit 1
done
exec /usr/bin/grep "$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$base/fakebin/firewall-cmd"
printf '#!/bin/sh\nexec "$@"\n' > "$base/fakebin/sudo"
chmod +x "$base/fakebin/systemctl" "$base/fakebin/grep" \
    "$base/fakebin/firewall-cmd" "$base/fakebin/sudo"
run_isolated "$base" env PATH="$base/fakebin:$PATH" \
    ABLETON_PROJECT_ASSUME_YES=1 \
    bash "$here/setup-link.sh" enable --mode=session >"$base/out" 2>"$base/err" \
    || fail "Overwrite did not replace the existing Link unit"
grep -qxF 'X-AbletonLinuxOwned=true' "$unit" \
    || fail "Link setup did not install its fixed unit destination"
! grep -qF 'Environment=FOREIGN_SETTING=1' "$unit" \
    || fail "Link setup retained the overwritten unit bytes"
ok "Link setup overwrites its fixed unit destination after approval"

# Direct controller mutations participate in the same lifecycle lock as the
# installer. A child already inside that transaction may reuse the descriptor,
# but the detached daemon must close it before exec so the next command is not
# locked out for the daemon's whole linger period.
base="$(new_env link-controller-global-lock)"
managed_linkd="$base/data/ableton-wine/ableton-linkd"
mkdir -p -- "$(dirname "$managed_linkd")" "$base/run/ableton-wine"
if [ -f "$root/dist/ableton-linkd" ]; then
    cp -- "$root/dist/ableton-linkd" "$managed_linkd"
else
    cp -- "$root/bin/ableton-linkd" "$managed_linkd"
fi
chmod 755 "$managed_linkd"
printf '999999\n' > "$base/run/ableton-wine/linkd.pid"
exec {controller_lock}< "$base/home"
flock -n "$controller_lock" || fail "could not create Link controller lock fixture"
for controller_action in start stop; do
    if run_isolated "$base" env -u ABLETON_INSTALL_LOCK_FD \
        ABLETON_LINKD="$managed_linkd" ABLETON_LINK_MODE=session \
        bash "$here/ableton-linkctl" "$controller_action" \
        >"$base/$controller_action.out" 2>"$base/$controller_action.err"; then
        fail "direct Link $controller_action bypassed an independent installer lock"
    fi
    grep -qF 'installation work is in progress' "$base/$controller_action.err" \
        || fail "locked Link $controller_action refusal did not identify lifecycle work"
    [ "$(cat "$base/run/ableton-wine/linkd.pid")" = 999999 ] \
        || fail "locked Link $controller_action mutated the PID record"
done
[ ! -e "$base/state" ] && [ ! -e "$base/data/ableton-wine/logs" ] \
    || fail "locked Link controller mutated persistent state before refusal"
run_isolated "$base" env ABLETON_INSTALL_LOCK_FD="$controller_lock" \
    ABLETON_LINKD="$managed_linkd" ABLETON_LINK_MODE=session ABLETON_LINKD_LINGER=5 \
    bash "$here/ableton-linkctl" start >"$base/inherited.out" 2>"$base/inherited.err" \
    || { sed -n '1,40p' "$base/inherited.err" >&2; fail "inherited installer Link start did not reuse its lock"; }
link_controller_pid="$(cat "$base/run/ableton-wine/linkd.pid")"
kill -0 "$link_controller_pid" 2>/dev/null \
    || fail "inherited Link start did not leave its detached daemon running"
exec {controller_lock}<&-
run_isolated "$base" env -u ABLETON_INSTALL_LOCK_FD \
    ABLETON_LINKD="$managed_linkd" ABLETON_LINK_MODE=session \
    bash "$here/ableton-linkctl" stop >"$base/stop-after.out" 2>"$base/stop-after.err" \
    || { sed -n '1,40p' "$base/stop-after.err" >&2; fail "detached Link daemon retained the global lock"; }
kill -0 "$link_controller_pid" 2>/dev/null \
    && fail "unlocked Link stop left the detached daemon running"
[ ! -e "$base/run/ableton-wine/linkd.pid" ] \
    || fail "unlocked Link stop retained its PID record"
ok "Link controller serializes direct mutations without leaking the installer lock to its daemon"

# Current installs save the complete MIME settings file before replacement.
# Uninstall restores that file after it removes the project desktop entries.
base="$(new_env mime-cleanup)"
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
run_isolated "$base" xdg-mime default third-party.desktop text/plain \
    || fail "test fixture could not set an unrelated MIME default"
grep -qxF 'x-scheme-handler/ableton=third-party.desktop' "$base/config/mimeapps.list" \
    || fail "test fixture did not record an explicit pre-install default"
grep -qxF 'text/plain=third-party.desktop' "$base/config/mimeapps.list" \
    || fail "test fixture did not record its unrelated MIME default"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/install.sh" --integration-only --yes \
    >"$base/install.out" 2>"$base/install.err" \
    || { sed -n '1,40p' "$base/install.err" >&2; fail "integration install failed before MIME restoration"; }
grep -qxF "x-scheme-handler/ableton=$ABLETON_PROTOCOL_DESKTOP_ID" "$base/config/mimeapps.list" \
    || fail "integration did not take over the scheme handler it registers"
mkdir -p -- "$base/config/ableton-wine"
cat > "$base/config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$base/home/.local/opt/wine-d2d1-nspa-11.13
prefix=$base/home/.wine-ableton
live_major=12
link_mode=off
linkd=$base/data/ableton-wine/ableton-linkd
EOF
chmod 600 "$base/config/ableton-wine/config"
run_isolated "$base" env PATH="$base/fakebin:$PATH" bash "$here/uninstall.sh" \
    --keep-prefix --yes >"$base/out" 2>"$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "uninstall failed after integration"; }
[ ! -e "$base/data/applications/$ABLETON_PROTOCOL_DESKTOP_ID" ] \
    && [ ! -e "$base/data/applications/$ABLETON_AUZ_DESKTOP_ID" ] \
    || fail "uninstall retained a fixed project desktop entry"
if grep -Eq "=($ABLETON_PROTOCOL_DESKTOP_ID|$ABLETON_AUZ_DESKTOP_ID|ableton-live\.desktop|max9\.desktop|wine-protocol-c74max\.desktop)\$" \
    "$base/config/mimeapps.list"; then
    fail "uninstall leaves a MIME default naming an entry it removed"
fi
grep -qxF 'x-scheme-handler/ableton=third-party.desktop' "$base/config/mimeapps.list" \
    || fail "uninstall did not restore the pre-install scheme default"
! grep -q '^application/x-wine-extension-auz=' "$base/config/mimeapps.list" \
    || fail "uninstall writes out a default the user never set explicitly"
grep -qxF 'text/plain=third-party.desktop' "$base/config/mimeapps.list" \
    || fail "uninstall changed an unrelated MIME default"
ok "uninstall restores pre-install MIME defaults and preserves unrelated entries"

# Session Link mode writes the unit for later but never runs it, so it must
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
    ABLETON_PROJECT_ASSUME_YES=1 \
    bash "$here/setup-link.sh" enable --mode=always >"$base/always.out" 2>"$base/always.err"; then
    fail "always-on Link enable succeeded with no systemd user manager"
fi
ok "session Link mode does not depend on a reachable systemd user manager"

# setup-link.sh sources the shared project-file helper, so a Link-only install
# has to ship it: TROUBLESHOOTING tells people to run the installed copy.
base="$(new_env link-assets-runnable)"
run_isolated "$base" bash "$here/install.sh" --link-assets-only \
    >"$base/out" 2>"$base/err" \
    || { sed -n '1,40p' "$base/err" >&2; fail "link-only install failed"; }
run_isolated "$base" bash "$base/data/ableton-wine/setup-link.sh" status \
    >"$base/status.out" 2>"$base/status.err" \
    || { sed -n '1,20p' "$base/status.err" >&2; fail "the installed setup-link.sh cannot run"; }
grep -q 'mode:' "$base/status.out" || fail "installed Link status reported no mode"
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
grep -q 'mode:' "$base/out" || fail "locked Link status reported no mode"
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
