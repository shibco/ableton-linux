# shellcheck shell=bash
# A HOME the installer can be pointed at without touching the real one.
#
# install.sh writes only under $HOME - BIN, APPS, the icon and mime trees, the
# shared-lib directory and, unless ABLETON_WINE_ROOT says otherwise, the runtime
# itself. So overriding HOME contains all of it, and is what these tests use
# instead of overriding each path separately: a path this forgets would write to
# the developer's real install, which is exactly the accident being guarded
# against.
#
# Two things reach outside $HOME regardless and are neutralised here.
install_sandbox() {
    HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
    export HOME

    # systemctl --user talks to the caller's session bus, not to $HOME. Left
    # alone, an install run under test stops the developer's actually-running
    # ableton-linkd. Point the bus at nothing so `is-active` fails and the whole
    # block is skipped; it is already guarded with || true beyond that.
    export DBUS_SESSION_BUS_ADDRESS=/dev/null
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg-runtime"
    mkdir -p "$XDG_RUNTIME_DIR"

    # /proc is real and read-only, but the scan is scoped to the runtime root,
    # which is inside the sandbox, so nothing on this machine can match.
    unset ABLETON_WINE_ROOT ABLETON_WINEPREFIX ABLETON_RUNTIME_TARBALL
}

# A runtime tarball to install, or nothing. Prefers an explicit pin so a
# developer can point these at a real build; otherwise takes whatever the
# checkout has already produced. Returns empty rather than failing - the caller
# skips, because the deep binary checks in install.sh need real ELF files with
# real DT_NEEDED entries and no fixture can honestly stand in for them.
sandbox_tarball() {
    # install.sh also refuses a package with no ableton-linkd, and a fresh
    # checkout has none - it is built by the container build, or stubbed by CI
    # into its disposable checkout. Returning empty here makes the callers skip
    # rather than fail; a stub is NOT created locally, because a leftover stub
    # in dist/ would be staged into the next real kit make-installer packs.
    { [ -f "$REPO/dist/ableton-linkd" ] || [ -f "$REPO/bin/ableton-linkd" ]; } || return 0
    if [ -n "${ABLETON_TEST_TARBALL:-}" ] && [ -f "$ABLETON_TEST_TARBALL" ]; then
        printf '%s\n' "$ABLETON_TEST_TARBALL"
        return 0
    fi
    ableton_pick_tarball "$REPO/dist"
}
