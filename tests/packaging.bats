#!/usr/bin/env bats
#
# Kit completeness: does the single-file installer actually carry everything the
# scripts inside it reach for at runtime?
#
# This is the blind spot behind the `installer`-labelled issues. A developer
# runs scripts/ from a full checkout, where every path resolves. Users run the
# staged kit, where only what make-installer.sh copied exists. Add a
# `. "$here/detect-something.sh"` to setup-prefix.sh, forget the matching line
# in make-installer.sh, and it works perfectly for the person who wrote it and
# fails on every machine that installs from a release.
#
# Nothing here builds or runs the installer — it reads make-installer.sh's
# staging list and checks it against what the kit's own scripts reference.

bats_require_minimum_version 1.5.0

load helpers/common

MK="scripts/make-installer.sh"

# The set of basenames make-installer.sh places in the kit's scripts/ directory:
# the multi-line `cp -a scripts/... "$kit/scripts/"` block plus the individual
# `install -m644 ... "$kit/scripts/NAME"` lines.
kit_script_names() {
    cd "$REPO"
    sed -n '/^cp -a scripts\//,/"\$kit\/scripts\/"/p' "$MK" \
        | grep -oE '(scripts|tools)/[A-Za-z0-9_.-]+' | sed 's#.*/##'
    grep -oE 'install -m[0-9]+ [^ ]+ "\$kit/scripts/[A-Za-z0-9_.-]+"' "$MK" \
        | sed 's#.*/##; s#"$##'
}

# guards: the staging list is recovered by anchored sed, so a reformat of
# make-installer.sh shrinks it silently and every test below keeps passing over
# whatever is left — indenting the cp block by two spaces takes it from 12 names
# to 3, with the suite still green
@test "the kit staging list is still parseable out of make-installer.sh" {
    n="$(kit_script_names | wc -l)"
    [ "$n" -ge 10 ] || {
        echo "kit_script_names recovered only $n entries (expected at least 10)." >&2
        echo "make-installer.sh's staging block has moved or been reformatted, so the" >&2
        echo "packaging tests are now checking a fraction of the kit and reporting pass." >&2
        echo "Re-anchor the sed range in kit_script_names to match the new shape." >&2
        false; }
}

@test "every file make-installer.sh stages into the kit exists in the repo" {
    cd "$REPO"
    missing=""
    # Sources of the staged scripts, as written in the copy list.
    for p in $(sed -n '/^cp -a scripts\//,/"\$kit\/scripts\/"/p' "$MK" \
                 | grep -oE '(scripts|tools)/[A-Za-z0-9_.-]+'); do
        [ -e "$p" ] || missing="$missing $p"
    done
    for p in $(grep -oE '^install -m[0-9]+ ((scripts|tools|desktop|vendor)/[A-Za-z0-9_.-]+)' "$MK" \
                 | awk '{print $3}'); do
        [ -e "$p" ] || missing="$missing $p"
    done
    [ -z "$missing" ] || { echo "staged but absent from the repo:$missing" >&2; false; }
}

# guards: issue label 'installer' — scripts resolve every path in a checkout, only some in the kit
@test "every script a kit script sources is itself staged into the kit" {
    cd "$REPO"
    staged="$(kit_script_names | sort -u)"
    missing=""
    while read -r name; do
        [ -n "$name" ] || continue
        f="scripts/$name"
        [ -f "$f" ] || continue
        # `. "$here/X"` — X must travel with the kit or the source fails at runtime.
        for ref in $(grep -oE '\. "\$here/[A-Za-z0-9_.-]+"' "$f" | sed 's#.*/##; s#"##'); do
            printf '%s\n' "$staged" | grep -qxF "$ref" || missing="$missing $name->$ref"
        done
    done < <(kit_script_names)
    [ -z "$missing" ] || {
        echo "sourced from a kit script but not staged into the kit:$missing" >&2
        echo "add it to the cp -a list in $MK." >&2
        false; }
}

@test "every sibling file a kit script executes or installs is staged too" {
    cd "$REPO"
    staged="$(kit_script_names | sort -u)"
    missing=""
    while read -r name; do
        [ -n "$name" ] || continue
        f="scripts/$name"
        [ -f "$f" ] || continue
        for ref in $(grep -oE '"\$here/[A-Za-z0-9_.-]+"' "$f" | sed 's#.*/##; s#"##'); do
            case "$ref" in ..|.) continue ;; esac
            printf '%s\n' "$staged" | grep -qxF "$ref" || missing="$missing $name->$ref"
        done
    done < <(kit_script_names)
    [ -z "$missing" ] || {
        echo "referenced as a kit sibling but not staged:$missing" >&2; false; }
}

# guards: licence GPLv2+ — Ableton Link has no linking exception, so the source must travel with the binary
@test "the kit ships the GPL source and licence Ableton Link requires" {
    cd "$REPO"
    # ableton-linkd links Link, which is GPLv2+ with no linking exception, so
    # the complete corresponding source has to travel with the binary. Dropping
    # this from the staging list is a licence violation, not a packaging nit.
    [ -f vendor/link-4.0.tar.zst ]
    grep -qF 'install -m644 vendor/link-4.0.tar.zst "$kit/vendor/link-4.0.tar.zst"' "$MK"
    grep -qF 'licenses/link-LICENSE.md' "$MK"
    grep -qF 'licenses/SOURCE.txt' "$MK"
}

@test "release.yml's asset list matches what make-installer.sh actually produces" {
    cd "$REPO"
    # The verify job hard-codes asset filenames. A rename in make-installer.sh
    # that misses release.yml fails only after the release is published.
    #
    # Assert on the name a release run *produces*, not on how the script spells
    # it. The installer's name is built from a label that defaults to VERSION,
    # so grepping for a source literal fails on a refactor that changed nothing
    # about the output — which is a test reporting on itself, not on the code.
    unset ABLETON_DIST_LABEL
    eval "$(grep -m1 '^VERSION=' "$MK")"
    eval "$(grep -m1 '^LABEL=' "$MK")"
    eval "produced=$(grep -m1 '^out=' "$MK" | cut -d= -f2-)"
    [ "$produced" = "dist/ableton-wine-setup-$(cat VERSION).run" ] || {
        echo "a release build would produce '$produced'" >&2; false; }
    grep -qF 'ableton-wine-setup-$ver.run' .github/workflows/release.yml
    grep -qF 'install-ableton-latest.run' .github/workflows/release.yml
    grep -qF 'install-ableton-latest.run' scripts/release.sh
}

# guards: lifting runtime_pids into the lib renamed it, and a replace that only
# matched the $(...) form left three pipeline calls pointing at a function that
# no longer existed — silently killing nothing before swapping the runtime
@test "every shell function a script calls is actually defined" {
    cd "$REPO"
    # Underscores are the tell: shell functions here use them, external commands
    # do not (update-desktop-database, sha256sum, readelf). So an underscore word
    # in command position is a function call, and it has to resolve somewhere —
    # in the file itself or in a lib the file sources.
    defined="$(grep -hoE '^[a-z][a-z0-9_]*\(\)' scripts/* 2>/dev/null | tr -d '()' | sort -u)"
    missing=""
    while read -r f; do
        # Drop comments, glob forms, and anything shaped like an assignment —
        # shell variables and the `key = value` lines of the heredoc configs
        # both sit at line start and would otherwise read as calls.
        body="$(grep -vE '^[[:space:]]*#|^[[:space:]]*[a-z][a-z0-9_]*[[:space:]]*=' "$f" \
                | sed 's/[a-z0-9_]*\*//g')"
        calls="$( { printf '%s\n' "$body" | grep -oE '^[[:space:]]*[a-z][a-z0-9_]*_[a-z0-9_]*[[:space:]]*[|)]?[[:space:]]*$|^[[:space:]]*[a-z][a-z0-9_]*_[a-z0-9_]*[[:space:]]+' 
                   printf '%s\n' "$body" | grep -oE '\$\([a-z][a-z0-9_]*_[a-z0-9_]*' ; } \
                 | sed 's/^[[:space:]]*//; s/[[:space:]|)]*$//; s/^\$(//' | sort -u)"
        for fn in $calls; do
            printf '%s\n' "$defined" | grep -qx "$fn" && continue
            command -v "$fn" >/dev/null 2>&1 && continue   # a real external command
            missing="$missing$f: $fn"$'\n'
        done
    done < <(git ls-files 'scripts/*')
    [ -z "$missing" ] || {
        echo "calls that resolve to no function or command:" >&2
        printf '%s' "$missing" >&2; false; }
}

# guards: make-installer accepted ABLETON_RUNTIME_TARBALL with only an -f check,
# packed a 1.6G kit, and the kit's own install.sh then selected nothing from its
# own payload — observed 2026-08-05
@test "make-installer refuses a tarball the kit's installer cannot select" {
    cd "$REPO"
    grep -qF 'ableton_is_runtime_tarball "$tarball"' "$MK" || {
        echo "make-installer.sh no longer checks the tarball it packs against the selector" >&2
        false; }
}

@test "kit-relative desktop and vendor paths are staged wholesale" {
    cd "$REPO"
    # In the kit, \$root is the kit root, so a "\$root/desktop/..." or
    # "\$root/vendor/..." reference resolves only because make-installer.sh
    # copies those trees entire. Assert those copies are still there.
    grep -qE '^cp -a desktop "\$kit/desktop"' "$MK" || {
        echo "make-installer.sh no longer stages desktop/ — install.sh reads \$root/desktop/*" >&2
        false; }
    grep -qE '^cp -a vendor/winetricks "' "$MK" || {
        echo "make-installer.sh no longer stages winetricks itself — setup-prefix.sh needs it" >&2
        false; }
    grep -qF 'ls-files vendor/winetricks-cache' "$MK" || {
        echo "make-installer.sh no longer stages the winetricks cache by tracked path" >&2
        false; }
    # guards: staging the cache directory wholesale ships whatever the build
    # machine downloaded — 1.6G against CI's 112M, measured 2026-08-05
    ! grep -qE '^cp -a vendor/winetricks-cache|winetricks vendor/winetricks-cache' "$MK" || {
        echo "make-installer.sh stages the whole winetricks cache again" >&2
        false; }
}
