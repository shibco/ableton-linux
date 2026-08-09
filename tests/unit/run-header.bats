#!/usr/bin/env bats
#
# scripts/setup-run-header.sh — which mode the .run picks before it does anything.
#
# This file exists because nothing tested the header at all. 402 tests, twelve
# unit files, and the one script every user actually executes had coverage only
# for "does it exist and may it carry a version literal". Four of the ten defects
# found on 2026-08-09 were in here, and the worst of them — that no unmigrated
# machine was ever offered an update, because the existing-install test looked
# only at ~/works/plugs/studio — would have been caught by the third test below.
#
# The header is a template with a payload appended, so testing it means building
# one: substitute the placeholders, tar a stub kit, concatenate. The stubs echo
# instead of installing, which is the point — what is under test is the decision,
# not what the decision runs.
#
#   ./tests/run.sh tests/unit/run-header.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export HOME
    mkdir -p "$HOME"
    unset WORKS_PLUG WORKS_RUNTIME WORKS_HOME
    RUN="$BATS_TEST_TMPDIR/fake.run"
    a_run
}

# A .run whose kit says what it was asked to do rather than doing it. Every
# script the header reaches for has to be here: a missing one fails the test for
# the wrong reason, which is how a stub suite starts lying.
a_run() {
    local kit="$BATS_TEST_TMPDIR/kit"
    mkdir -p "$kit/scripts" "$kit/bin"
    printf '#!/bin/sh\necho "KIT install.sh"\n'                 > "$kit/scripts/install.sh"
    printf '#!/bin/sh\necho "KIT setup-prefix.sh $*"\n'         > "$kit/scripts/setup-prefix.sh"
    printf '#!/bin/sh\nLINK_SETUP_VERSION=9\necho "KIT setup-link.sh"\n' \
                                                                > "$kit/scripts/setup-link.sh"
    printf '#!/bin/sh\necho "KIT uninstall.sh $*"\n'            > "$kit/scripts/uninstall.sh"
    # The header sources these two, so they define rather than echo.
    cat > "$kit/scripts/runtime-env.sh" <<'EOF'
works_runtime_path() { printf '%s\n' "$HOME/works/runtimes/stub"; }
works_plug_path()    { printf '%s\n' "${WORKS_PLUG:-$HOME/works/plugs/studio}"; }
EOF
    cat > "$kit/scripts/detect-scale.sh" <<'EOF'
ableton_detect_scale_ex() { printf '1.0 stub\n'; }
ableton_dpi_block_for_scale() { printf '100\n'; }
EOF
    chmod +x "$kit/scripts/"*.sh
    ( cd "$kit" && tar -cf "$BATS_TEST_TMPDIR/payload.tar" . )
    local sha; sha="$(sha256sum "$BATS_TEST_TMPDIR/payload.tar" | cut -d' ' -f1)"
    sed -e "s/@VERSION@/9.9.9/g" -e "s/@PAYLOAD_SHA@/$sha/g" \
        "$REPO/scripts/setup-run-header.sh" > "$RUN"
    cat "$BATS_TEST_TMPDIR/payload.tar" >> "$RUN"
}

# An installation as an older kit left one: flat runtime, prefix at the legacy
# path, and the version marker where install.sh used to write it.
a_legacy_install() {
    mkdir -p "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin" \
             "$HOME/.wine-ableton/drive_c" \
             "$HOME/.local/share/ableton-wine"
    printf '#!/bin/sh\n' > "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine"
    chmod +x "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine"
    : > "$HOME/.wine-ableton/system.reg"
    printf '2026.07.01.1\n' > "$HOME/.local/share/ableton-wine/VERSION"
}

# An installation on the ~/works layout, as this kit leaves one.
a_works_install() {
    mkdir -p "$HOME/works/runtimes/stub/bin" "$HOME/works/plugs/studio/drive_c" \
             "$HOME/works/apps/ableton-live"
    ln -sfn stub "$HOME/works/runtimes/stable"
    : > "$HOME/works/plugs/studio/system.reg"
    printf '2026.08.01.1\n' > "$HOME/works/apps/ableton-live/VERSION"
}

# --- the pre-extraction decision ---------------------------------------------

@test "a genuinely fresh machine is a full install" {
    run sh "$RUN" --no-launch --no-link
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" != *"existing installation was found"* ]] \
        || { echo "offered an update on a machine with nothing installed" >&2; false; }
}

@test "a machine on the ~/works layout is offered an update" {
    a_works_install
    run sh "$RUN" --no-launch --no-link
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"existing installation was found"* ]]
    [[ "$output" == *"2026.08.01.1"* ]]
    [[ "$output" == *"KIT setup-prefix.sh --refresh"* ]]
}

# guards: THE defect. Every existing user is on the legacy layout on the day the
# ~/works kit ships, and the header tested only ~/works/plugs/studio/system.reg
# for the prefix — a path that by definition does not exist yet on such a
# machine. So the update offer never fired, and the one population it was written
# for walked the full-install path: asked for an Ableton download it did not
# need, given setup-prefix.sh in full rather than --refresh, and Live's installer
# run over an existing Live. Upstream tested the legacy prefix and got it right;
# this was a regression against it.
@test "an unmigrated machine is offered an update, not a fresh install" {
    a_legacy_install
    run sh "$RUN" --no-launch --no-link
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"existing installation was found"* ]] \
        || { echo "a legacy install was treated as a fresh machine" >&2; false; }
    [[ "$output" == *"2026.07.01.1"* ]]
    [[ "$output" == *"KIT setup-prefix.sh --refresh"* ]] \
        || { echo "the prefix was rebuilt rather than refreshed" >&2; false; }
}

# guards: with no terminal nobody can answer, and the header takes the update
# branch by itself. That is the right default — but it means the test above is
# also what stands between a scripted run and a silent reinstall.
@test "with no terminal the update is taken, not the install" {
    a_legacy_install
    run sh "$RUN" --no-launch --no-link
    [[ "$output" == *"updating it to 9.9.9"* ]]
}

# guards: the marker says an application has been installed here. It does NOT say
# there is a prefix, and `--runtime-only` writes the marker while creating none.
# Keying the update offer on the marker alone sent exactly that machine into
# update mode, which ends in setup-prefix.sh --refresh — and that exits 2 on a
# prefix that is not there rather than creating one. The install would fail where
# the full path would have worked. Two questions, asked separately.
@test "a runtime with no prefix takes the full install, not the update" {
    mkdir -p "$HOME/works/runtimes/stub/bin" "$HOME/works/apps/ableton-live"
    ln -sfn stub "$HOME/works/runtimes/stable"
    printf '2026.08.01.1\n' > "$HOME/works/apps/ableton-live/VERSION"
    # deliberately no prefix, at either path
    run sh "$RUN" --no-launch --no-link
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" != *"existing installation was found"* ]] \
        || { echo "offered an update with no prefix to refresh" >&2; false; }
    [[ "$output" != *"--refresh"* ]] \
        || { echo "reached the refresh path with no prefix" >&2; false; }
}

# --- modes that must not consult the machine at all --------------------------

@test "--runtime-only stops before the prefix, on any machine" {
    a_works_install
    run sh "$RUN" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"KIT install.sh"* ]]
    [[ "$output" != *"KIT setup-prefix.sh"* ]] \
        || { echo "--runtime-only touched the prefix" >&2; false; }
}

@test "--update goes to the prefix refresh without asking" {
    a_works_install
    run sh "$RUN" --update
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"KIT setup-prefix.sh --refresh"* ]]
    [[ "$output" != *"existing installation was found"* ]]
}

@test "--extract writes the kit and does nothing else" {
    run sh "$RUN" --extract "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ -f "$BATS_TEST_TMPDIR/out/scripts/install.sh" ]
    [[ "$output" != *"KIT install.sh"* ]]
}

@test "--uninstall runs the kit's uninstaller and stops" {
    a_works_install
    run sh "$RUN" --uninstall
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"KIT uninstall.sh"* ]]
    [[ "$output" != *"KIT install.sh"* ]]
}

# --- the payload's own integrity ----------------------------------------------

@test "a damaged payload is refused before anything runs" {
    printf 'trailing damage\n' >> "$RUN"
    run sh "$RUN" --runtime-only
    [ "$status" -ne 0 ]
    [[ "$output" == *"integrity check"* ]]
    [[ "$output" != *"KIT install.sh"* ]]
}

# --- help ---------------------------------------------------------------------

# guards: --help sliced lines 2-18 of this file's own header comment, and line 18
# is a note about the payload marker — so the options list ended with a sentence
# of internal prose. The same line-range rot the works verbs were rewritten to
# remove, in the one script they did not cover.
@test "help ends on an option, not on prose about the payload" {
    run sh "$RUN" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--runtime-only"* ]]
    [[ "$output" != *"marker line"* ]] \
        || { echo "--help printed the note about the payload marker" >&2; false; }
}

@test "help names every mode the argument parser accepts" {
    run sh "$RUN" --help
    for flag in --runtime-only --update --no-launch --no-link --link \
                --extract --uninstall --prefix; do
        [[ "$output" == *"$flag"* ]] || { echo "--help omits $flag" >&2; false; }
    done
}
