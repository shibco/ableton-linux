#!/usr/bin/env bash
# Shared policy helpers for the optional local TSan infrastructure escape hatch.
# Sourcing this file does not change shell options or execute a probe.

pipeasio_tsan_mode_valid()
{
    case "${1:-}" in
        require|auto|skip) return 0 ;;
        *) return 1 ;;
    esac
}

# Return success only for known ThreadSanitizer startup failures caused by an
# incompatible Linux address-space layout or by a container refusing the
# runtime's process-local ADDR_NO_RANDOMIZE personality request.  A race report
# always wins over an infrastructure signature so auto mode cannot hide a real
# finding when several diagnostics are present in one CTest log.
pipeasio_tsan_log_is_infrastructure_failure()
{
    local log="${1:?TSan log path required}"

    # Reject every sanitizer warning except the two startup-layout messages
    # below. Enumerating known race classes is unsafe because newer runtimes
    # can add findings such as heap-use-after-free without changing this
    # policy code.
    if grep -E 'WARNING: ThreadSanitizer:' "$log" \
            | grep -Ev \
                'WARNING: ThreadSanitizer:.*(memory layout is incompatible|unexpectedly found incompatible memory layout|high-entropy ASLR|fixed virtual address space)' \
                >/dev/null; then
        return 1
    fi
    if grep -Eq \
            'SUMMARY: ThreadSanitizer:|^[[:space:]]*FAIL .*EXPECT_(EQ|TRUE)' \
            "$log"; then
        return 1
    fi
    if grep -E 'FATAL: ThreadSanitizer:' "$log" \
            | grep -Ev 'FATAL: ThreadSanitizer: unexpected memory mapping' \
                >/dev/null; then
        return 1
    fi
    if grep -E 'CHECK failed:' "$log" \
            | grep -Ev '(personality|ADDR_NO_RANDOMIZE)' \
                >/dev/null; then
        return 1
    fi

    if grep -Eq \
            'FATAL: ThreadSanitizer: unexpected memory mapping|ThreadSanitizer: (memory layout is incompatible|unexpectedly found incompatible memory layout)' \
            "$log"; then
        return 0
    fi

    # LLVM 18+ can detect high-entropy ASLR and re-exec itself without ASLR.
    # Default container seccomp profiles can reject personality(2), producing
    # the warning followed by a CHECK failure instead of the older mapping text.
    if grep -Eq \
            'ThreadSanitizer:.*(high-entropy ASLR|fixed virtual address space)' \
            "$log" \
       && grep -Eq \
            'CHECK failed:.*(personality|ADDR_NO_RANDOMIZE)|(personality|ADDR_NO_RANDOMIZE).*(Operation not permitted|Function not implemented)' \
            "$log"; then
        return 0
    fi

    # Also recognize the equivalent diagnostic when a caller deliberately
    # launches the canary through setarch --addr-no-randomize.
    grep -Eq \
        'setarch: failed to set personality to .*: (Operation not permitted|Function not implemented)' \
        "$log"
}
