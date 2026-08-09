#!/usr/bin/env bats
#
# Repo-wide invariants that cost seconds and have all been broken at least once.
#
# Nothing here needs a build, a prefix, Wine, or a display. This is the tier
# that should run on *every* push, unfiltered by paths.

bats_require_minimum_version 1.5.0

load helpers/common

# Files that are sourced, not executed, so they have no shebang of their own.
SOURCED="scripts/detect-scale.sh scripts/detect-theme.sh scripts/ableton-profile.sh scripts/runtime-env.sh scripts/shortcut-hold.sh"
# The single-file installer header declares #!/bin/sh and then re-execs itself
# into bash on line 19; shellcheck reads the shebang and not the re-exec.
BASH_DIALECT="scripts/setup-run-header.sh"

all_shell_files() {
    (cd "$REPO" && git ls-files \
        'build.sh' 'scripts/*.sh' 'scripts/ableton-live' 'scripts/max9' \
        'bin/ableton-live-beta' 'bin/ableton-live-portal' \
        'bin/ableton-wine-portal' 'bin/set-file-portal-policy' \
        'tests/run.sh' 'tests/catalogue.sh')
}

# --- shellcheck ---------------------------------------------------------------

@test "shellcheck: no warnings or errors in any shipped shell script" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    cd "$REPO"
    findings=""
    while read -r f; do
        [ -n "$f" ] || continue
        case " $SOURCED $BASH_DIALECT " in
            *" $f "*) out="$(shellcheck -s bash -S warning -f gcc "$f" 2>&1)" || true ;;
            *)        out="$(shellcheck -S warning -f gcc "$f" 2>&1)" || true ;;
        esac
        [ -z "$out" ] || findings="$findings$out"$'\n'
    done < <(all_shell_files)
    [ -z "$findings" ] || { printf '%s' "$findings" >&2; false; }
}

@test "every shell script parses under its effective interpreter" {
    cd "$REPO"
    bad=""
    while read -r f; do
        [ -n "$f" ] || continue
        case " $SOURCED $BASH_DIALECT " in
            # Sourced by bash callers; the installer header re-execs into bash.
            *" $f "*) bash -n "$f" 2>/dev/null || bad="$bad $f" ;;
            *) case "$(head -1 "$f")" in
                   *bash*) bash -n "$f" 2>/dev/null || bad="$bad $f" ;;
                   *sh*)   sh   -n "$f" 2>/dev/null || bad="$bad $f" ;;
               esac ;;
        esac
    done < <(all_shell_files)
    [ -z "$bad" ] || { echo "syntax errors in:$bad" >&2; false; }
}

# guards: scripts/setup-run-header.sh line 19 — the bash re-exec must precede every bash-ism
@test "the installer header survives being run by a real POSIX sh" {
    # README and every release note tell users to run `sh install-ableton-latest.run`,
    # and on Debian/Ubuntu/SteamOS that sh is dash or busybox — not bash. The
    # header opens #!/bin/sh and re-execs into bash on line 19, BEFORE the
    # parser reaches the arrays and process substitution further down. That
    # ordering is load-bearing and invisible: move a bash-ism above the exec
    # line and the installer dies on the exact systems it targets, while still
    # working perfectly for anyone whose /bin/sh is bash.
    hdr="$BATS_TEST_TMPDIR/header.run"
    sed -e 's/@VERSION@/0.0.0-test/g' -e 's/@PAYLOAD_SHA@/deadbeef/g' \
        "$REPO/scripts/setup-run-header.sh" > "$hdr"
    grep -qn 'exec bash' "$hdr" || { echo "the bash re-exec is gone" >&2; false; }

    for shell in sh dash "busybox sh"; do
        command -v "${shell%% *}" >/dev/null || continue
        run $shell "$hdr" --help
        [ "$status" -eq 0 ] || {
            echo "'$shell header.run --help' failed:" >&2; echo "$output" >&2; false; }
        [[ "$output" == *"single-file installer"* ]]
    done
}

@test "the installer header rejects unknown options instead of proceeding" {
    hdr="$BATS_TEST_TMPDIR/header.run"
    sed -e 's/@VERSION@/0.0.0-test/g' -e 's/@PAYLOAD_SHA@/deadbeef/g' \
        "$REPO/scripts/setup-run-header.sh" > "$hdr"
    run sh "$hdr" --not-a-real-option
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown option"* ]]

    # --prefix is destructive (it deletes the Wine prefix and the Live install);
    # it must never be accepted outside --uninstall.
    run sh "$hdr" --prefix
    [ "$status" -ne 0 ]
    [[ "$output" == *"only applies with --uninstall"* ]]
}

@test "file modes: launchers are executable, sourced and templated files are not" {
    cd "$REPO"
    # setup-run-header.sh is concatenated into the .run by make-installer.sh and
    # never executed from the tree; max9 is installed with `install -m755`.
    NOT_RUN_IN_PLACE="$SOURCED scripts/setup-run-header.sh scripts/max9"
    wrong=""
    while read -r f; do
        [ -n "$f" ] || continue
        case " $NOT_RUN_IN_PLACE " in
            *" $f "*) [ ! -x "$f" ] || wrong="$wrong $f(unexpectedly-exec)" ;;
            *)        [ -x "$f" ]   || wrong="$wrong $f(not-exec)" ;;
        esac
    done < <(all_shell_files)
    [ -z "$wrong" ] || { echo "mode mismatches:$wrong" >&2; false; }
}

# --- version / naming drift ---------------------------------------------------
# The runtime directory name carries the Wine base version and is a bare literal
# in ~20 live files. The 11.11 -> 11.13 bump missed some of them and needed a
# follow-up commit (f84eaa4) to finish the rename. This is that commit as a test.

# guards: commit f84eaa4 — the 11.11 to 11.13 rename needed a follow-up pass
@test "runtime name: every live file agrees on one wine-d2d1-nspa version" {
    cd "$REPO"
    # dist/ holds archived BUILD-INFO for past releases and notes/ is a written
    # record — both legitimately name older runtimes. Everything else is live.
    versions="$(git grep -hoE 'wine-d2d1-nspa-[0-9]+\.[0-9]+' -- \
        ':!dist' ':!notes' ':!CHANGELOG.md' ':!beta' | sort -u)"
    [ "$(printf '%s\n' "$versions" | wc -l)" -eq 1 ] || {
        echo "live files disagree on the runtime name:" >&2
        printf '  %s\n' $versions >&2
        echo "offending files:" >&2
        git grep -lE 'wine-d2d1-nspa-[0-9]+\.[0-9]+' -- ':!dist' ':!notes' ':!CHANGELOG.md' ':!beta' >&2
        false; }
}

@test "the wine base container-build.sh unpacks is the one vendor/ pins" {
    cd "$REPO"
    # Derived, never hardcoded: the pinned filename lives in vendor/wine-base.sha256
    # and moves at every base bump. Naming a specific commit here would make this
    # test a second thing to remember to update — which is the class of bug it
    # exists to catch.
    pinned="$(awk '{print $2}' vendor/wine-base.sha256)"
    [ -n "$pinned" ] || { echo "vendor/wine-base.sha256 names no file" >&2; false; }
    [ -f "vendor/$pinned" ] || { echo "vendor/$pinned is pinned but absent" >&2; false; }
    grep -qF "vendor/$pinned" scripts/container-build.sh || {
        echo "container-build.sh does not unpack the pinned base ($pinned):" >&2
        grep -n 'wine-base' scripts/container-build.sh >&2
        false; }
}

@test "VERSION is a well-formed dated release string" {
    run cat "$REPO/VERSION"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] || {
        echo "VERSION '$output' is not YYYY.MM.DD.N" >&2; false; }
}

# VERSION-vs-CHANGELOG and VERSION-vs-BUILD-INFO deliberately live in
# tests/release.bats, not here: this repo lands the changelog entry before the
# VERSION bump (e221cc4 did exactly that), so as a per-PR gate they would fail
# on a legitimate commit. They are release-time invariants, not PR ones.

@test "the test catalogue is current" {
    # tests/CATALOGUE.md is generated from the test files. Same freeze-and-check
    # shape as patches/SERIES.sha256: a stale catalogue is worse than none,
    # because it reads as authoritative.
    run "$REPO/tests/catalogue.sh" --check
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

# --- vendored inputs ----------------------------------------------------------

@test "vendored inputs match their pinned checksums" {
    # Same check `make verify` and build.sh step 0 run, hoisted to every push:
    # a corrupted or silently-swapped vendor blob is otherwise found only by
    # someone starting a 40-minute build.
    cd "$REPO/vendor"
    run sha256sum -c --quiet wine-base.sha256 pipeasio.sha256 pipewire-sdk.sha256 \
                             ntsync-uapi.sha256 link.sha256 cabextract.sha256
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

# --- desktop integration ------------------------------------------------------
# Issue #106 ("stuck on registering MIME types") lives in this area. The
# templates are only ever seen substituted, so validate them substituted.

# guards: issue #106 — stuck on registering MIME types
@test "desktop entries validate after substitution" {
    command -v desktop-file-validate >/dev/null || skip "desktop-file-validate not installed"
    out="$BATS_TEST_TMPDIR/apps"; mkdir -p "$out"
    for f in "$REPO"/desktop/*.desktop.in; do
        b="$(basename "$f" .in)"
        sed -e "s#@HOME@#/home/tester#g" \
            -e "s#@NAME@#Ableton Live 12 Suite#g" \
            -e "s#@ICON@#live-suite#g" \
            -e "s#@WMCLASS@#ableton live 12 suite.exe#g" "$f" > "$out/$b"
        run desktop-file-validate "$out/$b"
        [ "$status" -eq 0 ] || { echo "$b: $output" >&2; false; }
    done
}

@test "desktop templates leave no unsubstituted @PLACEHOLDER@ behind" {
    # install.sh substitutes a fixed set of keys per template. A new @KEY@ added
    # to a template without a matching sed in install.sh ships a literal
    # "@KEY@" into the user's application menu.
    leftover=""
    for f in "$REPO"/desktop/*.desktop.in; do
        b="$(basename "$f" .in)"
        for key in $(grep -oE '@[A-Z_]+@' "$f" | sort -u); do
            grep -qF "s#$key#" "$REPO/scripts/install.sh" || leftover="$leftover $b:$key"
        done
    done
    [ -z "$leftover" ] || {
        echo "template keys with no substitution in install.sh:$leftover" >&2; false; }
}

@test "MIME package XML and icon SVGs are well-formed" {
    command -v xmllint >/dev/null || skip "xmllint not installed"
    for x in "$REPO"/desktop/x-wine-extension-auz.xml \
             "$REPO"/desktop/icons/application-ableton-live.xml; do
        run xmllint --noout "$x"
        [ "$status" -eq 0 ] || { echo "$x: $output" >&2; false; }
    done
    while read -r svg; do
        run xmllint --noout "$svg"
        [ "$status" -eq 0 ] || { echo "$svg: $output" >&2; false; }
    done < <(find "$REPO/desktop/icons" -name '*.svg')
}

@test "every icon an installed desktop entry names is actually shipped" {
    # install.sh picks Icon=live-<edition>; a missing SVG is a blank tile in
    # the application menu, which nobody notices until a user reports it.
    missing=""
    for ed in intro lite standard suite beta; do
        [ -f "$REPO/desktop/icons/scalable/apps/live-$ed.svg" ] || missing="$missing live-$ed"
    done
    [ -z "$missing" ] || { echo "missing edition icons:$missing" >&2; false; }
}

# guards: a bats on PATH used to beat the pin, so a checkout ran whatever the
# distribution packaged while CI ran whatever apt carried -- two runners
# reporting the same number. The pin lives in one place and CI reads it.
@test "CI runs the bats tests/run.sh pins, not one of its own" {
    run grep -c 'apt-get install.*[^-]bats' "$REPO/.github/workflows/ci-checks.yml"
    [ "$output" = "0" ] || { echo "ci-checks installs bats from apt" >&2; false; }
    grep -q 'BATS_VERSION' "$REPO/.github/workflows/ci-checks.yml" \
        || { echo "ci-checks does not read the pin from tests/run.sh" >&2; false; }
}

# guards: .bats-core is a full clone of another project; run.sh's comment said it
# was ignored when it was not, so one `git add -A` would have committed it
@test "the vendored bats clone is ignored" {
    run git -C "$REPO" check-ignore -q .bats-core
    [ "$status" -eq 0 ] || { echo ".bats-core is not gitignored" >&2; false; }
}

# guards: the container sees only what build.sh passes with -e, and an unset
# variable there is not an error - container-build.sh falls back to VERSION and
# stamps every nightly with the release's number instead of its own date. The
# rename broke this and a clean merge restored the broken form; nothing failed,
# which is the whole problem.
@test "build.sh forwards every variable container-build.sh reads from its environment" {
    cd "$REPO"
    missing=""
    while read -r var; do
        [ -n "$var" ] || continue
        grep -q -- "-e \"$var=" build.sh || missing="$missing $var"
    done < <(grep -oE '\$\{(WORKS|ABLETON)_[A-Z_]+:-' scripts/container-build.sh | sed 's/^\${//; s/:-$//' | sort -u)
    [ -z "$missing" ] || { echo "container-build.sh reads these; build.sh passes none of them:$missing" >&2; false; }
}
