# Helpers for testing scripts/ableton-live.
#
# The launcher is a script, not a library: it runs discovery, registry sync and
# a single-instance lock at top level and ends in `exec wine ...`. So there are
# two ways in, and the tests use both.
#
#   launcher_sandbox / run_launcher — run the whole thing for real against a
#     throwaway $HOME and prefix, with a fake runtime tree at ABLETON_WINE_ROOT.
#     Every wine call (wineboot, reg add, and the final exec) lands in a log
#     instead of touching a real prefix, so a test can assert on what the
#     launcher *would* have run. This is the contract users actually see.
#
#   launcher_fn — pull named function bodies out of the file and eval them, for
#     the pure ones (colour blending, LOGFONT packing, CPU topology) where a
#     full launch would say nothing about the arithmetic.

# Extract one or more functions from the launcher and define them here.
# The file formats every function as `name() {` ... `}` at column 0.
launcher_fn() {
    local fn body
    for fn in "$@"; do
        body="$(sed -n "/^$fn() {/,/^}/p" "$REPO/scripts/ableton-live")"
        [ -n "$body" ] || { echo "no such function in scripts/ableton-live: $fn" >&2; return 1; }
        eval "$body" || return 1
    done
}

# Build a throwaway HOME + prefix + fake wine runtime in $BATS_TEST_TMPDIR.
launcher_sandbox() {
    SB="$BATS_TEST_TMPDIR/sb"
    FAKE_HOME="$SB/home"
    PREFIX="$SB/prefix"
    WINEROOT="$SB/wineroot"
    WINE_LOG="$SB/wine.log"
    mkdir -p "$FAKE_HOME/.local/share" "$PREFIX/drive_c/ProgramData/Ableton" "$WINEROOT/bin"
    : > "$WINE_LOG"

    # One fake binary stands in for the whole runtime. It records every
    # invocation and succeeds, so bring-up proceeds to the launch it would
    # otherwise exec — which is the line the tests assert on.
    cat > "$WINEROOT/bin/wine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WINE_LOG"
case "\$1 \$2" in "reg query"*) exit 1 ;; esac
exit 0
EOF
    cp "$WINEROOT/bin/wine" "$WINEROOT/bin/wineserver"
    # winepath -w turns a unix path into a windows one for .als documents.
    cat > "$WINEROOT/bin/winepath" <<'EOF'
#!/bin/sh
printf 'Z:%s\n' "$(printf '%s' "$2" | tr '/' '\\')"
EOF
    chmod +x "$WINEROOT/bin/wine" "$WINEROOT/bin/wineserver" "$WINEROOT/bin/winepath"

    export HOME="$FAKE_HOME"
    unset XDG_DATA_HOME XDG_CONFIG_HOME
    export ABLETON_WINE_ROOT="$WINEROOT"
    export ABLETON_WINEPREFIX="$PREFIX"
    # Off by default so the exec line is deterministic; the one test that cares
    # about realtime scheduling turns it back on with a stubbed chrt.
    export ABLETON_RT=off
    # Keep the theme watcher and the Live-theme probe out of the way unless a
    # test opts in: neither changes which executable gets launched.
    export ABLETON_TOPBAR_MODE=system
    export ABLETON_DPI_MODE=preserve
    export ABLETON_THEME_MODE=preserve
    # The launcher asks the kernel whether Live is already up, at six places
    # (the launch lock, the wineserver kill, the registry re-sync, the theme
    # watcher's two polls, the light/dark mirror). pgrep reads the host process
    # table and no sandbox variable redirects it, so with a real Live open —
    # the normal state of a machine someone is developing this on — every one
    # of those takes the "already running" branch and the code under test never
    # runs. On a CI runner, with no Live, they all take the other one. Stub it
    # closed so both agree; a test wanting the running-Live branch re-stubs
    # with a fixture (stub pgrep 0 "$FIXTURES/pgrep/live-running.txt").
    stub pgrep 1
}

# install_live <major> <edition> — plant a fake Live install in the prefix.
install_live() {
    local major="$1" edition="$2"
    local dir="$PREFIX/drive_c/ProgramData/Ableton/Live $major $edition/Program"
    mkdir -p "$dir"
    : > "$dir/Ableton Live $major $edition.exe"
    printf '%s\n' "$dir/Ableton Live $major $edition.exe"
}

# Run the launcher. Output and status come back through bats' $output/$status.
run_launcher() {
    run --separate-stderr env "PATH=$PATH" bash "$REPO/scripts/ableton-live" "$@"
}

# The command line the launcher would have exec'd (the last thing wine saw).
launched() { tail -n 1 "$WINE_LOG"; }
