#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/tsan.sh
source "$here/scripts/lib/tsan.sh"

tmp="$(mktemp -d /tmp/pipeasio-tsan-policy-test.XXXXXX)"
cleanup()
{
    case "$tmp" in
        /tmp/pipeasio-tsan-policy-test.*) rm -rf -- "${tmp:?}" ;;
        *) printf 'refusing to remove unexpected test path: %s\n' "$tmp" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

fail()
{
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

for mode in require auto skip; do
    pipeasio_tsan_mode_valid "$mode" || fail "valid mode rejected: $mode"
done
for mode in '' required AUTO yes; do
    if pipeasio_tsan_mode_valid "$mode"; then
        fail "invalid mode accepted: ${mode:-<empty>}"
    fi
done
printf 'ok - TSan modes are an exact require|auto|skip enum\n'

printf '%s\n' \
    'FATAL: ThreadSanitizer: unexpected memory mapping 0x123-0x456' \
    > "$tmp/old-mapping.log"
pipeasio_tsan_log_is_infrastructure_failure "$tmp/old-mapping.log" \
    || fail 'old TSan address-space collision was not classified as infrastructure'

printf '%s\n' \
    'WARNING: ThreadSanitizer: memory layout is incompatible, possibly due to high-entropy ASLR.' \
    'Re-execing with fixed virtual address space.' \
    'CHECK failed: tsan_platform_linux.cpp:281 "personality(old | ADDR_NO_RANDOMIZE) != -1"' \
    > "$tmp/reexec.log"
pipeasio_tsan_log_is_infrastructure_failure "$tmp/reexec.log" \
    || fail 'LLVM high-ASLR/personality failure was not classified as infrastructure'

printf '%s\n' \
    'setarch: failed to set personality to x86_64: Function not implemented' \
    > "$tmp/setarch.log"
pipeasio_tsan_log_is_infrastructure_failure "$tmp/setarch.log" \
    || fail 'container personality denial was not classified as infrastructure'

printf '%s\n' \
    'WARNING: ThreadSanitizer: data race (pid=42)' \
    'FATAL: ThreadSanitizer: unexpected memory mapping 0x123-0x456' \
    > "$tmp/race.log"
if pipeasio_tsan_log_is_infrastructure_failure "$tmp/race.log"; then
    fail 'race report was misclassified as skippable infrastructure'
fi

printf '%s\n' \
    'WARNING: ThreadSanitizer: heap-use-after-free (pid=42)' \
    'FATAL: ThreadSanitizer: unexpected memory mapping 0x123-0x456' \
    > "$tmp/heap-use-after-free.log"
if pipeasio_tsan_log_is_infrastructure_failure "$tmp/heap-use-after-free.log"; then
    fail 'heap-use-after-free was misclassified as skippable infrastructure'
fi

printf '%s\n' \
    'FAIL test_config.c:42 EXPECT_EQ(actual, expected)' \
    'FATAL: ThreadSanitizer: unexpected memory mapping 0x123-0x456' \
    > "$tmp/assertion.log"
if pipeasio_tsan_log_is_infrastructure_failure "$tmp/assertion.log"; then
    fail 'unit assertion was misclassified as skippable infrastructure'
fi

printf '%s\n' 'Segmentation fault (core dumped)' > "$tmp/unknown.log"
if pipeasio_tsan_log_is_infrastructure_failure "$tmp/unknown.log"; then
    fail 'unknown test failure was misclassified as skippable infrastructure'
fi
printf 'ok - races, assertions, and unknown failures are never auto-skipped\n'
