# Sourceable Wine OpenGL-backend policy. NVIDIA's EGL X11 configs expose
# RGBA8 on a 32-bit ARGB visual, which Wine intentionally does not advertise
# for ordinary windows. Its GLX backend exposes compatible RGBA8/sRGB formats.

ableton_nvidia_display_active() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    local state
    state="$(timeout 5 nvidia-smi --query-gpu=display_active --format=csv,noheader,nounits 2>/dev/null)" || return 1
    printf '%s\n' "$state" | grep -Eiq '^[[:space:]]*(enabled|active|yes|1)([[:space:]]|$)'
}

# Print egl, glx, or preserve. The optional second argument (0/1) makes auto
# resolution deterministic in tests; when omitted, inspect the live system.
ableton_resolve_opengl_backend() {
    local mode="${1:-auto}" nvidia_active="${2:-}"
    case "$mode" in
        egl|glx|preserve) printf '%s\n' "$mode"; return 0 ;;
        auto) ;;
        *) return 2 ;;
    esac

    if [ -z "$nvidia_active" ]; then
        case "${__GLX_VENDOR_LIBRARY_NAME:-}" in
            nvidia) nvidia_active=1 ;;
        esac
    fi
    if [ -z "$nvidia_active" ] && [ "${__NV_PRIME_RENDER_OFFLOAD:-0}" = 1 ]; then
        nvidia_active=1
    fi
    if [ -z "$nvidia_active" ]; then
        if ableton_nvidia_display_active; then nvidia_active=1; else nvidia_active=0; fi
    fi

    if [ "$nvidia_active" = 1 ]; then echo glx; else echo preserve; fi
}
