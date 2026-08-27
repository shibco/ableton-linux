#!/bin/sh
# shellcheck shell=bash
# Ableton-on-Wine self-extracting installer transport.  Policy lives in the
# packaged scripts/installer.sh; this header only verifies and unpacks the kit.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
export LC_ALL=C.UTF-8

VERSION="@VERSION@"
PAYLOAD_SHA="@PAYLOAD_SHA@"
self="$(readlink -f -- "$0")"
media_dir="$(dirname -- "$self")"

short_help()
{
    cat <<'EOF'
Ableton-on-Wine installer

Commands:
  install, update, runtime install, prefix create|update|repair-live11,
  link enable|disable|status, uninstall, extract DIR, plan COMMAND ...

After extracting the kit, run `bash DIR/scripts/installer.sh --help`, replacing
DIR with the extraction directory, for the complete command and option list.
Compatibility flags remain temporarily
available with warnings.
EOF
}

case "${1:-}" in --help|-h|help) short_help; exit 0 ;; esac

io_timeout="${ABLETON_PAYLOAD_IO_TIMEOUT:-3600}"
case "$io_timeout" in ''|*[!0-9]*) echo "!! ABLETON_PAYLOAD_IO_TIMEOUT must be whole seconds" >&2; exit 2 ;; esac
[ "$io_timeout" -ge 60 ] && [ "$io_timeout" -le 14400 ] || {
    echo "!! ABLETON_PAYLOAD_IO_TIMEOUT must be between 60 and 14400 seconds" >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo "!! GNU timeout is required" >&2; exit 1; }
bounded()
{
    timeout --signal=TERM --kill-after=5s "${io_timeout}s" "$@"
}

extract_dir=""
if [ "${1:-}" = extract ] || [ "${1:-}" = --extract ]; then
    [ $# -eq 2 ] || { echo "!! extract needs exactly one destination directory" >&2; exit 2; }
    extract_dir="$2"
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/ableton-installer.XXXXXX")"
cleanup()
{
    local rc=$?
    trap - EXIT
    rm -rf -- "$workdir" 2>/dev/null || true
    if [ -e "$workdir" ] || [ -L "$workdir" ]; then
        echo "!! The installer finished, but temporary files remain at $workdir. You can remove that directory." >&2 || true
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

payload_line="$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$self")"
[ -n "$payload_line" ] || {
    echo "!! This installer file is incomplete or damaged. Download it again." >&2
    exit 1
}
header_bytes="$(head -n "$((payload_line-1))" "$self" | wc -c)"
total_bytes="$(stat -c %s "$self" 2>/dev/null || wc -c < "$self")"
payload_bytes=$((total_bytes - header_bytes))
printf '== Ableton-on-Wine installer %s ==\n' "$VERSION" || true
printf '%s\n' "-- copying embedded kit ($((payload_bytes / 1024 / 1024)) MiB; progress is bytes copied)" || true
payload="$workdir/payload.tar"
if dd --help 2>&1 | grep iflag >/dev/null; then
    bounded dd if="$self" of="$payload" iflag=skip_bytes skip="$header_bytes" bs=4M status=progress
else
    bounded tail -n +"$payload_line" "$self" > "$payload"
fi

printf '%s\n' "-- verifying embedded kit (progress is bytes hashed)" || true
if dd --help 2>&1 | grep status >/dev/null; then
    actual="$(bounded dd if="$payload" bs=4M status=progress | sha256sum | awk '{print $1}')"
else
    actual="$(bounded sha256sum "$payload" | awk '{print $1}')"
fi
[ "$actual" = "$PAYLOAD_SHA" ] || {
    echo "!! installer integrity check failed; download or copy it again" >&2
    exit 1
}

kit="$workdir/kit"
mkdir -p -- "$kit"
printf '%s\n' "-- extracting embedded kit" || true
if tar --help 2>&1 | grep -- '--checkpoint' >/dev/null; then
    bounded tar --checkpoint=200 --checkpoint-action=dot -xf "$payload" -C "$kit"
    printf '\n' >&2 || true
else
    bounded tar -xf "$payload" -C "$kit"
fi
rm -f -- "$payload" 2>/dev/null || true

if [ -n "$extract_dir" ]; then
    mkdir -p -- "$extract_dir"
    cp -a -- "$kit/." "$extract_dir/"
    printf 'OK: kit extracted to %s\n' "$extract_dir" || true
    exit 0
fi

export ABLETON_INSTALLER_MEDIA_DIR="$media_dir"
export ABLETON_INSTALLER_PATH="$self"
export ABLETON_INSTALLER_VERSION="$VERSION"
# Delegate without exec: the EXIT trap must still remove $workdir.  The exit
# keeps bash from reading past the payload marker after a successful install.
bash "$kit/scripts/installer.sh" "$@"; exit $?
__PAYLOAD_BELOW__
