#!/usr/bin/env bats
#
# scripts/works-update — deciding whether to replace the runtime.
#
# Everything the updater does before it downloads is a refusal: same build,
# unknown channel, incomplete manifest, a Wine base it cannot take a Plug back
# across, a runtime something is still running from. Those refusals are the
# feature — the download is the easy part — so this file is mostly about them.
#
# Nothing here reaches the network. WORKS_MANIFEST_URL points curl at a
# file:// URL, which is the same code path a real channel takes.
#
#   ./tests/run.sh tests/unit/works-update.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

UPD="$REPO/scripts/works-update"

setup() {
    # works_runtime_busy falls back to pgrep when the /proc scan finds nothing,
    # and that fallback reads the whole host. Unstubbed, this file's verdict
    # depends on what else happens to be running — including the fake Live that
    # works-runtime.bats spawns, which is precisely what the pattern matches.
    setup_stubs
    stub pgrep 1
    HOME="$BATS_TEST_TMPDIR/home"
    export HOME XDG_CONFIG_HOME="$HOME/.config"
    export WORKS_HOME="$HOME/works"
    export WORKS_CHANNEL_FILE="$XDG_CONFIG_HOME/works/channel"
    mkdir -p "$XDG_CONFIG_HOME/works" "$WORKS_HOME/runtimes"
    unset WORKS_CHANNEL WORKS_RUNTIME
    PUB="$BATS_TEST_TMPDIR/pub"; mkdir -p "$PUB"
    export WORKS_MANIFEST_URL="file://$PUB/manifest.txt"
    STORE="$WORKS_HOME/runtimes"
}

# A build in the store: a directory with a BUILD-INFO the resolver can read.
# Only the fields the updater compares are set; a real one carries more.
#
# The Wine base is two separate facts and they are not interchangeable. The
# `wine:` label is what a manifest carries and what the early advisory compares;
# share/wine/wine.inf is what Wine itself reads, and its mtime is what
# works_base_move answers from. A fixture setting only the label would satisfy a
# test the real field could not.
a_build() {   # name, commit, built-at, wine, [base-stamp]
    local d="$STORE/$1"
    mkdir -p "$d/bin" "$d/share/wine"
    printf 'dist-version: %s\nsource-commit: %s\nbuilt-at:     %s\nwine:         %s\n' \
        "${1%%+*}" "$2" "$3" "$4" > "$d/ABLETON-WINE-BUILD-INFO.txt"
    : > "$d/share/wine/wine.inf"
    touch -d "@${5:-1700000000}" "$d/share/wine/wine.inf"
}

# A Plug that has been booted, and the base it was booted against. Unbound on
# purpose: an unbound Plug follows the channel, which is what makes it one of
# the Plugs a retarget actually moves.
a_plug() {   # name, base-stamp
    local d="$WORKS_HOME/plugs/$1"
    mkdir -p "$d/drive_c"
    : > "$d/system.reg"
    printf '%s\n' "$2" > "$d/.update-timestamp"
}

# What a channel is publishing. Written through the real writer so a change to
# the format cannot pass here and fail in the field.
a_manifest() {   # channel, commit, built-at, wine, installer, sha
    local info="$BATS_TEST_TMPDIR/pub-info.txt"
    printf 'dist-version: 2026.08.04.1\nsource-commit: %s\nbuilt-at:     %s\nwine:         %s\n' \
        "$2" "$3" "$4" > "$info"
    ( . "$REPO/scripts/runtime-env.sh"
      works_manifest_write "$1" "$info" "$5" "$6" ) > "$PUB/manifest.txt"
}

on_channel() { printf '%s\n' "$1" > "$WORKS_CHANNEL_FILE"; }
point_at()   { ln -sfn "$2" "$STORE/$1"; }

# --- nothing to do ------------------------------------------------------------

@test "the same build is recognised, and nothing happens" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable aaaaaaaa 2026-08-06T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"You already have this build"* ]]
}

# guards: the version string is identical across every nightly between releases,
# so comparing it would report "up to date" forever
@test "a new build with the same version is still an update" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"An update is available"* ]]
}

@test "--check installs nothing" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --check
    [ "$(readlink "$STORE/stable")" = "2026.08.04.1+aaaa" ]
}

# --- switching channel --------------------------------------------------------

@test "a channel switch to a build already in the store downloads nothing" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --channel nightly
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [ "$(readlink "$STORE/nightly")" = "2026.08.04.1+bbbb" ]
}

@test "switching channel records the choice" {
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.13
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --channel nightly
    [ "$(cat "$WORKS_CHANNEL_FILE")" = "nightly" ]
}

# guards: a switch must move the channel it names, and only that one
@test "switching channel leaves the other channel where it was" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --channel nightly
    [ "$(readlink "$STORE/stable")" = "2026.08.04.1+aaaa" ]
}

# guards: a retarget under a running Live is safe and must not refuse — the
# resolver hands back the build rather than the channel, so a started session
# keeps what it started with. `works runtime use` allows exactly this, and the
# two commands disagreeing about it would be the surprise.
@test "a channel switch is allowed while something is running, with a note" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    cp "$(command -v sleep)" "$STORE/2026.08.04.1+aaaa/bin/wineserver"
    "$STORE/2026.08.04.1+aaaa/bin/wineserver" 30 &
    local pid=$! i
    # The exe link is what the scan matches on, and it does not exist until
    # execve has finished. Starting the process and running the command in the
    # same breath races it.
    for i in $(seq 1 40); do [ -e "/proc/$pid/exe" ] && break; sleep 0.05; done

    run "$UPD" --channel nightly
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true

    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ "$(readlink "$STORE/nightly")" = "2026.08.04.1+bbbb" ]
    [[ "$output" == *"takes effect on the next launch"* ]]
}

# guards: --check is a question, and asking it must not answer it
@test "--check does not move a channel even when the build is present" {
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.13
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --channel nightly --check
    [ "$status" -eq 0 ]
    [ ! -e "$STORE/nightly" ]
    [ "$(cat "$WORKS_CHANNEL_FILE")" = "stable" ]
}

# --- what it refuses ----------------------------------------------------------

# guards: a channel names a symlink and selects a URL; it is user configuration
# and must never be able to choose either
@test "an unknown channel is refused before any fetch" {
    on_channel stable
    run "$UPD" --channel ../../evil
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a channel"* ]]
}

# guards: an empty value must not silently mean "the channel you are on" — a
# switch that quietly does not switch is worse than one that fails
@test "--channel with nothing after it is refused, and says so" {
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef
    run "$UPD" --channel
    [ "$status" -ne 0 ]
    [[ "$output" == *"--channel needs a name"* ]]
}

@test "an unknown option is refused" {
    run "$UPD" --demolish
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "a manifest that cannot be fetched is an error, not an update" {
    on_channel stable
    WORKS_MANIFEST_URL="file://$PUB/absent.txt" run "$UPD"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not fetch"* ]]
}

# guards: a half-read manifest cannot answer "is this newer" or "does this
# change the Wine base", so it must not be acted on at all
@test "an incomplete manifest is refused" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef
    grep -v '^sha256' "$PUB/manifest.txt" > "$PUB/m2" && mv "$PUB/m2" "$PUB/manifest.txt"

    run "$UPD" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"incomplete"* ]]
}

# guards: the manifest describes a build that is not on disk yet, so the base
# cannot be read from it the way Wine reads it — the label is all there is. That
# makes this an advisory and not a verdict: it exists so nobody spends 113 MB of
# download to be asked a question that could have been asked first. The verdict
# is install.sh's, where the tree is unpacked and every door passes through.
#
# It used to exit 1 here and say "install it deliberately with the full installer
# if you mean it", and the full installer had no base check at all — so the
# escape hatch it named was less careful than the refusal naming it.
@test "a Wine base change on the download path is announced, not refused" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 x.run deadbeef

    run "$UPD" --yes
    [[ "$output" == *"changes the Wine base"* ]]
    [[ "$output" == *"wine-11.13 -> wine-11.14"* ]]
    # It got past the advisory and went for the installer, rather than stopping
    # on the base. (The download itself fails: x.run is not published here.)
    [[ "$output" == *"downloading"* ]] || { echo "$output" >&2; false; }
}

# guards: found in review. The "already in the store, just retarget" branch ran
# *above* both refusals, so the one path that costs no download was also the one
# path that crossed a Wine base unchecked — and with Live running. It is also
# the one path install.sh never sees, so the guard has to be repeated here; the
# build being on disk is what makes it answerable properly.
@test "a base change that takes a Plug backward is refused from the store" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13 1700000000
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 1600000000
    a_plug studio 1700000000        # booted against the newer base
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 x.run deadbeef

    run "$UPD" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"OLDER Wine base"* ]]
    [ "$(readlink "$STORE/stable")" = "2026.08.04.1+aaaa" ] \
        || { echo "the channel was retargeted backward across a base" >&2; false; }
}

# guards: forward is supported and irreversible, so it takes consent rather than
# a refusal — but consent nobody can give is not consent. bats has no controlling
# terminal, which is the same position a cron job or a script is in.
@test "a base change that moves a Plug forward is refused with no terminal" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13 1600000000
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 1700000000
    a_plug studio 1600000000        # booted against the older base
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 x.run deadbeef

    run "$UPD"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no terminal to confirm a base change"* ]]
    [ "$(readlink "$STORE/stable")" = "2026.08.04.1+aaaa" ]
}

@test "--yes accepts a forward base change and retargets" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13 1600000000
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 1700000000
    a_plug studio 1600000000
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 x.run deadbeef

    run "$UPD" --yes
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ "$(readlink "$STORE/stable")" = "2026.08.04.1+bbbb" ]
}

# guards: the old guard compared two runtimes and applied the answer to a machine
# that might have no prefix at all. There is nothing to re-bootstrap here, so
# there is nothing to warn about — asking the Plug is what makes that visible.
@test "with no Plug, a base change from the store is not obstructed" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13 1600000000
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 1700000000
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 x.run deadbeef

    run "$UPD" --yes
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ "$(readlink "$STORE/stable")" = "2026.08.04.1+bbbb" ]
}

# guards: --check is a question, not an action, so it reports the base change
# rather than failing on it — and still changes nothing
@test "--check reports a base change instead of refusing" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.14
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.14 x.run deadbeef

    run "$UPD" --check
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"changes the Wine base"* ]]
    [ "$(readlink "$STORE/stable")" = "2026.08.04.1+aaaa" ]
}

# guards: replacing the tree under a running Live is how a session is lost
@test "it refuses while something is running from the runtime" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    # a real process whose /proc/PID/exe resolves inside the runtime
    cp "$(command -v sleep)" "$STORE/2026.08.04.1+aaaa/bin/wineserver"
    "$STORE/2026.08.04.1+aaaa/bin/wineserver" 30 &
    local pid=$!
    run "$UPD" --yes
    kill "$pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"Close Live first"* ]]
}

# guards: an unattended run must not hang waiting on a prompt nobody can answer
@test "with no terminal to ask on it stops rather than assuming yes" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    run -1 setsid --wait "$UPD"
    [[ "$output" == *"no terminal to confirm"* ]]
}

# --- the download it does do --------------------------------------------------

# guards: the checksum is the only thing making the manifest's URL trustworthy
@test "a checksum mismatch stops the install" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    printf 'not the real installer\n' > "$PUB/x.run"
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run notthesha

    run "$UPD" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
}

# guards: which door of the installer this opens, which is not a detail. Both
# --runtime-only and --update install the runtime, the launcher, the verbs and
# the toolkit; only --update goes on to configure Link and re-run the prefix
# setup, where a kit's registry policy and DLL healing live.
#
# This asserted --runtime-only until 2026-08-09, which is how the defect stayed
# invisible: updating by command and updating by installer left two different
# machines, and the test pinned the difference in place as if it were the
# contract. A user who only ever ran `works update` never received a
# prefix-policy change and had no way to find out.
@test "a matching checksum reaches the installer, through the update door" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    printf '#!/bin/sh\necho INSTALLER RAN "$@"\n' > "$PUB/x.run"
    local sha; sha="$(sha256sum "$PUB/x.run" | cut -d' ' -f1)"
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run "$sha"

    run "$UPD" --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALLER RAN --update"* ]]
    [[ "$output" != *"--runtime-only"* ]] \
        || { echo "the updater took the door that skips the prefix" >&2; false; }
}

# guards: releases move, and the manifest must stay the thing that locates the
# artifact rather than a second place a URL is hardcoded
@test "the installer is fetched from beside the manifest" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    mkdir -p "$PUB/moved"
    printf '#!/bin/sh\necho FROM MOVED\n' > "$PUB/moved/x.run"
    local sha; sha="$(sha256sum "$PUB/moved/x.run" | cut -d' ' -f1)"
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run "$sha"
    mv "$PUB/manifest.txt" "$PUB/moved/manifest.txt"

    WORKS_MANIFEST_URL="file://$PUB/moved/manifest.txt" run "$UPD" --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"FROM MOVED"* ]]
}

# --- reporting ----------------------------------------------------------------

@test "a downgrade is named as one" {
    a_build 2026.08.04.1+bbbb bbbbbbbb 2026-08-07T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+bbbb
    on_channel stable
    a_manifest stable aaaaaaaa 2026-08-06T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --check
    [[ "$output" == *"OLDER than what you have"* ]]
}

@test "a machine with nothing installed is offered the build" {
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-07T10:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"An update is available"* ]]
}

@test "--help says what it does without touching anything" {
    run "$UPD" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--check"* ]]
    [[ "$output" == *"--channel"* ]]
}

# --- what the demo turned up ---------------------------------------------------

# guards: two builds can share a timestamp -- the same build published on two
# channels, or a rebuild of one commit -- and sort's tail -1 returns the
# installed one when they are equal, so an equal build read as a downgrade
@test "a build with the same timestamp is not called older" {
    a_build 2026.08.06.1+aaaa aaaaaaaa 2026-08-06T16:11:28Z wine-11.13
    point_at stable 2026.08.06.1+aaaa
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-06T16:11:28Z wine-11.13 x.run deadbeef

    run "$UPD" --channel nightly --check
    [[ "$output" != *"OLDER"* ]]
}

@test "a genuinely older build is still called older" {
    a_build 2026.08.06.1+aaaa aaaaaaaa 2026-08-06T16:11:28Z wine-11.13
    point_at stable 2026.08.06.1+aaaa
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-04T09:00:00Z wine-11.13 x.run deadbeef

    run "$UPD" --channel nightly --check
    [[ "$output" == *"OLDER"* ]]
}

# guards: reporting the channel's bare version against the installed id put a
# version beside an identifier and invited comparing them
@test "both sides of the report are ids, not one id and one version" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-04T09:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-06T16:11:28Z wine-11.13 x.run deadbeef
    printf 'build-kind:    nightly\n' >> "$PUB/manifest.txt"

    run "$UPD" --channel nightly --check
    [[ "$output" == *"available: 2026.08.04.1+nightly.bbbbbbb"* ]] \
        || { echo "$output" >&2; false; }
}

# guards: a release has no kind, and must not grow one
@test "a release is reported without a kind" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-04T09:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest stable bbbbbbbb 2026-08-06T16:11:28Z wine-11.13 x.run deadbeef

    run "$UPD" --check
    [[ "$output" == *"available: 2026.08.04.1+bbbbbbb "* ]] || { echo "$output" >&2; false; }
}

# guards: the two ids differ in length by design -- a nightly carries its kind --
# so unpadded output left the dates and Wine versions unalignable between rows
@test "the report's columns line up between available and installed" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-04T09:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable
    a_manifest nightly bbbbbbbb 2026-08-06T16:11:28Z wine-11.13 x.run deadbeef
    printf 'build-kind:    nightly\n' >> "$PUB/manifest.txt"

    run "$UPD" --channel nightly --check
    local a i
    a="$(grep -o 'available:.*' <<< "$output")"
    i="$(grep -o 'installed:.*' <<< "$output")"
    # the Wine version starts at the same offset on both rows
    [ "$(awk -v s="$a" 'BEGIN{print index(s, "wine-11.13")}')" \
      = "$(awk -v s="$i" 'BEGIN{print index(s, "wine-11.13")}')" ] \
        || { printf '%s\n%s\n' "$a" "$i" >&2; false; }
}

# --- help ---------------------------------------------------------------------

# guards: the help is a fixed line range over the header comment, so editing that
# comment drags the prose beneath it into the output or drops a flag off the end
@test "update help ends on a command, not on prose" {
    run "$UPD" --help
    [ "$status" -eq 0 ]
    last="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -1)"
    [[ "$last" == "  works update"* ]] \
        || { echo "help trails into prose: $last" >&2; false; }
}

@test "update help names every flag it accepts" {
    run "$UPD" --help
    for f in --check --channel --yes; do
        [[ "$output" == *"$f"* ]] || { echo "help omits $f" >&2; false; }
    done
}

# guards: WORKS_RUNTIME is the outermost say in every resolver, and a pinned
# machine opts out of channels. This used to read the channel and the store as
# usual and then install flat to the pin with a dated rollback, never touching
# the channel — reporting a channel it had not changed. Refusing before any
# fetch is the honest answer, and the message says what a pinned machine that
# really means it should do instead.
@test "a pinned WORKS_RUNTIME is refused before any fetch" {
    a_build 2026.08.04.1+aaaa aaaaaaaa 2026-08-06T10:00:00Z wine-11.13
    point_at stable 2026.08.04.1+aaaa
    on_channel stable

    run env WORKS_RUNTIME="$STORE/2026.08.04.1+aaaa" "$UPD" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"pinned"* ]]
    [[ "$output" == *"WORKS_RUNTIME_TARBALL"* ]]
    [[ "$output" != *"== channel:"* ]] \
        || { echo "it went on to consult the channel anyway" >&2; false; }
}
