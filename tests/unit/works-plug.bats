#!/usr/bin/env bats
#
# scripts/works-plug — the prefixes applications are installed into.
#
# A Plug is a directory and one symlink: the name is the directory's name, the
# tenants are whatever is in drive_c, and `.works-runtime` is the only recorded
# state. So most of this is about the filesystem being the list — that a Plug
# nobody made is not offered, that a binding survives being walked, and that the
# destructive verbs refuse before they act rather than after.
#
#   ./tests/run.sh tests/unit/works-plug.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

PLUG() { bash "$REPO/scripts/works-plug" "$@"; }

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export HOME
    export WORKS_HOME="$BATS_TEST_TMPDIR/opt"
    unset WORKS_RUNTIME WORKS_PLUG WORKS_CHANNEL
    mkdir -p "$HOME" "$WORKS_HOME"
    . "$REPO/scripts/runtime-env.sh"
    C="$(works_runtime_store)"
    P="$(works_plugs_dir)"
}

a_build() {   # name, commit, built-at
    mkdir -p "$C/$1/bin"
    printf '#!/bin/sh\necho wine-11.13\n' > "$C/$1/bin/wine"; chmod +x "$C/$1/bin/wine"
    printf 'dist-version: %s\nsource-commit: %s\nwine:         wine-11.13\nbuilt-at:     %s\n' \
        "${1%%+*}" "$2" "$3" > "$C/$1/ABLETON-WINE-BUILD-INFO.txt"
}

# A prefix the way Wine leaves one: system.reg is the marker, dosdevices holds a
# relative link back into the Plug, and Live lives where the launcher looks.
a_plug() {   # name, [live major]
    mkdir -p "$P/$1/drive_c" "$P/$1/dosdevices"
    touch "$P/$1/system.reg"
    ln -sfn ../drive_c "$P/$1/dosdevices/c:"
    [ -z "${2:-}" ] || {
        mkdir -p "$P/$1/drive_c/ProgramData/Ableton/Live $2 Suite/Program"
        touch "$P/$1/drive_c/ProgramData/Ableton/Live $2 Suite/Program/Ableton Live $2 Suite.exe"; }
}

store() {
    a_build 2026.06.01.1+bbbbbbb bbbbbbb 2026-06-01T00:00:00Z
    ln -sfn 2026.06.01.1+bbbbbbb "$C/stable"
}

# --- list ---------------------------------------------------------------------

@test "list says so when there are no Plugs yet" {
    store
    run PLUG list
    [ "$status" -eq 0 ]
    [[ "$output" == *"predates them"* ]]
}

@test "list names each Plug and what is installed in it" {
    store; a_plug studio 12; a_plug work 11
    run PLUG list
    [ "$status" -eq 0 ]
    [[ "$output" == *"studio"* ]] && [[ "$output" == *"Live 12"* ]]
    [[ "$output" == *"work"* ]] && [[ "$output" == *"Live 11"* ]]
}

# guards: the selection is a symlink, and a list that does not say which one is
# selected leaves the only piece of state invisible
@test "list marks the selected Plug, and use moves the mark" {
    store; a_plug studio 12; a_plug work 12
    run PLUG list
    [[ "$output" == *"* studio"* ]]      # studio is the fallback with no default
    PLUG use work
    run PLUG list
    [[ "$output" == *"* work"* ]]
    [[ "$output" != *"* studio"* ]]
}

# guards: a Plug bound to the channel link and a Plug pinned to a build resolve
# to the same directory today, and reporting them identically hides the one
# difference that matters -- whether `works runtime use` will move it
@test "list separates following a channel from being pinned to a build" {
    store; a_plug follow 12; a_plug pinned 12
    ln -sfn ../../runtimes/stable "$P/follow/.works-runtime"
    ln -sfn ../../runtimes/2026.06.01.1+bbbbbbb "$P/pinned/.works-runtime"
    run PLUG list
    [[ "$output" == *"2026.06.01.1+bbbbbbb (stable)"* ]]
    [[ "$output" == *"2026.06.01.1+bbbbbbb (pinned)"* ]]
}

@test "an unbound Plug is reported as following the channel" {
    store; a_plug studio 12
    run PLUG list
    [[ "$output" == *"(stable)"* ]]
}

# guards: found by hand. With no store there is no channel for a Plug to follow,
# and labelling the flat legacy runtime "(stable)" invents one.
@test "a pre-store install is not reported as following a channel" {
    a_plug studio 12                      # deliberately no store
    run PLUG list
    [ "$status" -eq 0 ]
    [[ "$output" == *"(legacy)"* ]]
    [[ "$output" != *"(stable)"* ]] || { echo "invented a channel: $output" >&2; false; }
}

# guards: a directory someone dropped under plugs/ is not a prefix, and offering
# it as one would send a launch at something with no drive_c
@test "list does not offer a directory that is not a prefix" {
    store; a_plug studio 12
    mkdir -p "$P/notaplug"
    run PLUG list
    [[ "$output" != *"notaplug"* ]]
}

# guards: a default pointing at a removed Plug silently falls back to studio, so
# every launch goes somewhere the user did not choose
@test "a dangling default is called out rather than left to look deliberate" {
    store; a_plug studio 12
    ln -sfn gone "$P/default"
    run PLUG list
    [[ "$output" == *"which is not there"* ]]
}

# --- use ----------------------------------------------------------------------

@test "use retargets the default, relatively" {
    store; a_plug studio 12; a_plug work 12
    run PLUG use work
    [ "$status" -eq 0 ]
    [ "$(readlink "$P/default")" = "work" ]
    [ "$(works_plug_path)" = "$P/work" ]
}

# guards: the path is what people copy into a script or a bug report, and it is
# shown for builds already — a Plug is no different, and the two commands
# disagreeing about that is the surprise
@test "list shows each Plug's path, abbreviated under home" {
    store; a_plug studio 12
    run PLUG list
    [ "$status" -eq 0 ]
    [[ "$output" == *"PATH"* ]]
    [[ "$output" == *"/plugs/studio"* ]]
    [[ "$output" != *"$HOME/works"* ]] || { echo "home was not abbreviated" >&2; false; }
}

# guards: `works runtime use` with no argument offers a numbered list, so this
# must too. Anything one of them offers the other should — a person who learned
# the behaviour on one should not find the other refuses.
@test "use with no argument refuses when there is no terminal, naming the Plugs" {
    store; a_plug studio 12; a_plug work 12
    run setsid bash "$REPO/scripts/works-plug" use
    [ "$status" -ne 0 ]
    [[ "$output" == *"no terminal"* ]]
    [[ "$output" == *"works plug use studio"* ]]
    [[ "$output" == *"works plug use work"* ]]
}

@test "use with no argument leaves the default alone" {
    store; a_plug studio 12; a_plug work 12
    PLUG use work
    setsid bash "$REPO/scripts/works-plug" use || true
    [ "$(readlink "$P/default")" = "work" ]
}

@test "use refuses a Plug that is not there, and lists what is" {
    store; a_plug studio 12
    run PLUG use nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such Plug"* ]]
    [[ "$output" == *"studio"* ]]
}

# guards: `default` is the selection link itself, so a Plug by that name could
# never be selected and would be shadowed the moment one was
@test "default is refused as a Plug name" {
    store; a_plug studio 12
    run PLUG use default
    [ "$status" -ne 0 ]
    [[ "$output" == *"selection link"* ]]
    run PLUG new default
    [ "$status" -ne 0 ]
}

@test "a name that is not a plain directory name is refused" {
    store
    run PLUG new ../escape
    [ "$status" -ne 0 ]
    run PLUG new "with space"
    [ "$status" -ne 0 ]
    [ ! -e "$P/../escape" ]
}

# --- new ----------------------------------------------------------------------

@test "new creates a Plug that follows the channel" {
    store
    run PLUG new fresh
    [ "$status" -eq 0 ]
    [ -d "$P/fresh" ]
    [ "$(readlink "$P/fresh/.works-runtime")" = "../../runtimes/stable" ]
}

# guards: a Plug with no prefix in it yet still has to appear, or `new` produces
# something `list` denies exists
@test "a Plug created but never booted is still listed" {
    store
    PLUG new fresh
    run PLUG list
    [[ "$output" == *"fresh"* ]]
}

@test "new refuses a name already taken" {
    store; a_plug studio 12
    run PLUG new studio
    [ "$status" -ne 0 ]
    [[ "$output" == *"already something"* ]]
}

@test "new --runtime pins the Plug to one build" {
    store
    run PLUG new held --runtime 2026.06.01.1+bbbbbbb
    [ "$status" -eq 0 ]
    [ "$(readlink "$P/held/.works-runtime")" = "../../runtimes/2026.06.01.1+bbbbbbb" ]
}

@test "new --runtime refuses a build that is not in the store" {
    store
    run PLUG new held --runtime 2026.99.99.9+zzzzzzz
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing in the store"* ]]
}

# --- cloning ------------------------------------------------------------------

@test "new --from clones the prefix and what is installed in it" {
    store; a_plug studio 12
    run PLUG new work --from studio
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ -e "$P/work/system.reg" ]
    [ -e "$P/work/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe" ]
}

# guards: dosdevices holds relative links back into the Plug and outward ones to
# the real home. Dereferencing either turns a clone into a copy of the user's
# documents, or points the new Plug's c: at the old Plug's drive_c.
@test "cloning keeps the prefix's symlinks as symlinks" {
    store; a_plug studio 12
    ln -sfn "$HOME" "$P/studio/dosdevices/z:"
    PLUG new work --from studio
    [ -L "$P/work/dosdevices/c:" ]
    [ "$(readlink "$P/work/dosdevices/c:")" = "../drive_c" ]
    [ -L "$P/work/dosdevices/z:" ]
}

@test "a clone inherits the binding the source had" {
    store; a_plug studio 12
    ln -sfn ../../runtimes/2026.06.01.1+bbbbbbb "$P/studio/.works-runtime"
    PLUG new work --from studio
    [ "$(readlink "$P/work/.works-runtime")" = "../../runtimes/2026.06.01.1+bbbbbbb" ]
}

@test "new --from refuses a source that is not a Plug" {
    store; a_plug studio 12
    run PLUG new work --from nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such Plug to clone"* ]]
    [ ! -e "$P/work" ]
}

@test "new says which kind of copy it is about to make" {
    store; a_plug studio 12
    run PLUG new work --from studio
    [[ "$output" == *"copy-on-write"* ]] || [[ "$output" == *"full copy"* ]] \
        || [[ "$output" == *"shares extents"* ]] \
        || { echo "said neither: $output" >&2; false; }
}

# guards: `stat -f` reads statfs.f_type, and ext2, ext3 and ext4 all share magic
# 0xef53 - so the first version of this announced "ext2/ext3" on every ext4
# machine there is. The mount table is the only thing that knows the real name.
@test "the clone names the filesystem the mount table reports" {
    store; a_plug studio 12
    local want
    want="$(df -PT "$P" 2>/dev/null | awk 'NR==2 {print $2}')"
    [ -n "$want" ] || skip "df -T unavailable here"
    run PLUG new work --from studio
    [ "$status" -eq 0 ]
    [[ "$output" == *"$want"* ]] || { echo "expected '$want' in: $output" >&2; false; }
}

# guards: found by hand on a pre-store machine. The clone landed, the *default*
# binding then failed because no channel exists to bind to, and new reported an
# error for a Plug it had created correctly.
@test "new --from succeeds on a machine with no version store" {
    a_plug studio 12                      # deliberately no store
    run PLUG new work --from studio
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ -d "$P/work" ]
    [[ "$output" == *"no version store yet"* ]]
}

# guards: an explicit --runtime is a different case from the default binding, and
# must still refuse - but before it copies, not after
@test "an explicit --runtime is refused before anything is cloned" {
    a_plug studio 12
    run PLUG new work --from studio --runtime 2026.99.99.9+zzzzzzz
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing in the store"* ]]
    [ ! -e "$P/work" ] || { echo "it cloned before checking the binding" >&2; false; }
}

# --- rm -----------------------------------------------------------------------

@test "rm -y removes the Plug and everything in it" {
    store; a_plug studio 12; a_plug work 12
    run PLUG rm work -y
    [ "$status" -eq 0 ]
    [ ! -e "$P/work" ]
    [ -e "$P/studio" ]
}

# guards: removing what default points at leaves the selection dangling and
# every launch quietly falling back to studio
@test "rm refuses the default Plug while others exist, and names the successors" {
    store; a_plug studio 12; a_plug work 12
    PLUG use work
    run PLUG rm work -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"is the default Plug"* ]]
    [[ "$output" == *"works plug use studio"* ]]
    [ -e "$P/work" ]
}

# guards: the guard above cannot fire for the last Plug, and leaving the link
# behind would point it at a name that no longer exists
@test "removing the last Plug takes the default link with it" {
    store; a_plug only 12
    PLUG use only
    run PLUG rm only -y
    [ "$status" -eq 0 ]
    [ ! -e "$P/only" ]
    [ ! -L "$P/default" ]
}

# guards: this deletes a prefix that can hold a licensed Live and tens of GB of
# content, so it must not proceed where nobody can answer for it
@test "rm without -y and with no terminal refuses rather than assuming" {
    store; a_plug studio 12; a_plug work 12
    run setsid bash "$REPO/scripts/works-plug" rm work
    [ "$status" -ne 0 ]
    [[ "$output" == *"pass -y"* ]]
    [ -e "$P/work" ]
}

@test "rm refuses a Plug that is not there" {
    store; a_plug studio 12
    run PLUG rm nope -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such Plug"* ]]
}

# --- the binding ---------------------------------------------------------------

# guards: two Plugs running different builds is the whole point of the binding,
# and it is read at launch rather than by the resolver -- install.sh resolves the
# runtime it is installing *into* through works_runtime_path, and a Plug must
# not move that
@test "a Plug's binding decides the runtime a launch binds to" {
    store
    a_build 2026.01.01.1+aaaaaaa aaaaaaa 2026-01-01T00:00:00Z
    a_plug studio 12
    ln -sfn ../../runtimes/2026.01.01.1+aaaaaaa "$P/studio/.works-runtime"
    ( works_bind_runtime; [ "$WINE_ROOT" = "$C/2026.01.01.1+aaaaaaa" ] ) \
        || { echo "bound to the channel, not the Plug" >&2; false; }
}

@test "an unbound Plug binds to whatever the channel resolves to" {
    store; a_plug studio 12
    ( works_bind_runtime; [ "$WINE_ROOT" = "$C/2026.06.01.1+bbbbbbb" ] )
}

# guards: the VMs and anyone bisecting a build rely on WORKS_RUNTIME being the
# outermost say, and a Plug binding must not have quietly taken that over
@test "WORKS_RUNTIME still overrides a Plug's binding" {
    store
    a_build 2026.01.01.1+aaaaaaa aaaaaaa 2026-01-01T00:00:00Z
    a_plug studio 12
    ln -sfn ../../runtimes/2026.01.01.1+aaaaaaa "$P/studio/.works-runtime"
    ( WORKS_RUNTIME=/somewhere/else works_bind_runtime
      [ "$WINE_ROOT" = "/somewhere/else" ] )
}

# --- retention ------------------------------------------------------------------

# guards: a Plug held deliberately on an older build is exactly what the count
# prunes first, and removing it breaks that Plug rather than tidying anything
@test "retention keeps a build a Plug is bound to" {
    store
    a_build 2026.01.01.1+aaaaaaa aaaaaaa 2026-01-01T00:00:00Z
    a_plug studio 12
    ln -sfn ../../runtimes/2026.01.01.1+aaaaaaa "$P/studio/.works-runtime"
    WORKS_RUNTIME_KEEP=1 works_prune_runtimes
    [ -d "$C/2026.01.01.1+aaaaaaa" ] || { echo "the bound build was pruned" >&2; false; }
}

# The control for the test above: without the binding the same build in the same
# store on the same count is pruned, so the one above is measuring the binding
# and not an entry that was never a candidate.
@test "retention prunes that same build when no Plug is bound to it" {
    store
    a_build 2026.01.01.1+aaaaaaa aaaaaaa 2026-01-01T00:00:00Z
    a_plug studio 12
    WORKS_RUNTIME_KEEP=1 works_prune_runtimes
    [ ! -d "$C/2026.01.01.1+aaaaaaa" ] || { echo "nothing was prunable to begin with" >&2; false; }
}

# --- help -----------------------------------------------------------------------

@test "help ends on a command, not on prose" {
    run PLUG --help
    [ "$status" -eq 0 ]
    last="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -1)"
    [[ "$last" == "  works plug"* ]] || { echo "help trails into prose: $last" >&2; false; }
}

@test "plug is reachable through the dispatcher" {
    store; a_plug studio 12
    run bash "$REPO/scripts/works" plug list
    [ "$status" -eq 0 ]
    [[ "$output" == *"studio"* ]]
}
