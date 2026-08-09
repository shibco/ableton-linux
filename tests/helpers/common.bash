# Shared bats helpers. Every .bats file starts with:  load ../helpers/common
#
# Two things matter here:
#   REPO   - the checkout root, so tests never depend on the caller's cwd
#   stub   - put a fake command first on PATH, so a probe's *parser* is tested
#            against a recorded fixture instead of whatever compositor happens
#            to be running on the machine (or the CI runner, which has none).

# Walk up from the test file until the checkout root turns up, so tests can sit
# at any depth under tests/ without the helper caring.
REPO="$BATS_TEST_DIRNAME"
while [ "$REPO" != / ] && { [ ! -e "$REPO/VERSION" ] || [ ! -d "$REPO/patches" ]; }; do
    REPO="$(dirname "$REPO")"
done
[ -d "$REPO/patches" ] || { echo "cannot locate the checkout root from $BATS_TEST_DIRNAME" >&2; exit 1; }
export REPO
FIXTURES="$REPO/tests/fixtures"
export FIXTURES

setup_stubs() {
    STUB_DIR="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUB_DIR"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

# stub <name> <exit-code> [stdout-file]
# Later calls replace earlier ones, so a test can re-stub mid-run.
stub() {
    local name="$1" rc="${2:-0}" out="${3:-/dev/null}"
    cat > "$STUB_DIR/$name" <<EOF
#!/bin/sh
[ -r "$out" ] && cat "$out"
exit $rc
EOF
    chmod +x "$STUB_DIR/$name"
}

# Remove a command from PATH entirely, so the "tool is not installed" branch of
# a probe is exercised. Uses a shim that fails the way `command -v` cares about.
unstub() {
    rm -f "$STUB_DIR/$1"
}

# The probes gate on both the binary existing *and* a session env var. Tests that
# want a clean slate call this first: no probe should answer by accident.
clear_session_env() {
    unset SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP DISPLAY
    unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
}
