#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../scripts/opengl-policy.sh"

failures=0
check() {
    local description="$1" expected="$2"
    shift 2
    local actual
    if actual="$("$@")" && [ "$actual" = "$expected" ]; then
        printf 'ok - %s\n' "$description"
    else
        printf 'not ok - %s (expected %s, got %s)\n' "$description" "$expected" "${actual:-<failure>}" >&2
        failures=$((failures + 1))
    fi
}
check_fails() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'not ok - %s (unexpected success)\n' "$description" >&2
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$description"
    fi
}

check 'auto uses GLX for active NVIDIA display' glx ableton_resolve_opengl_backend auto 1
check 'auto preserves non-NVIDIA backend' preserve ableton_resolve_opengl_backend auto 0
check 'auto honors the NVIDIA GLX vendor hint' glx env __GLX_VENDOR_LIBRARY_NAME=nvidia bash -c \
    '. "$1"; ableton_resolve_opengl_backend auto' _ "$here/../scripts/opengl-policy.sh"
check 'auto honors NVIDIA PRIME offload' glx env __NV_PRIME_RENDER_OFFLOAD=1 bash -c \
    '. "$1"; ableton_resolve_opengl_backend auto' _ "$here/../scripts/opengl-policy.sh"
check 'explicit EGL override' egl ableton_resolve_opengl_backend egl 1
check 'explicit GLX override' glx ableton_resolve_opengl_backend glx 0
check 'explicit preserve override' preserve ableton_resolve_opengl_backend preserve 1
check_fails 'invalid backend is rejected' ableton_resolve_opengl_backend invalid 1

[ "$failures" -eq 0 ]
printf 'PASS: OpenGL backend policy tests\n'
