#!/usr/bin/env bats
#
# The patch stack, verified without building Wine.
#
# Today a patch that no longer applies is caught only by the full container
# build in ci-pr-build.yml — tens of minutes, and only on PRs that touch the
# paths in that workflow's filter. Everything here reproduces the apply half of
# scripts/container-build.sh against the vendored base and finishes in seconds,
# so a bad rebase fails in the first minute of CI instead of the fortieth.
#
# This does NOT replace the build: it cannot catch a patch that applies but
# fails to compile. It catches the far more common case — a patch that has
# rotted against the base, was renumbered, or was added without being frozen.

bats_require_minimum_version 1.5.0

load helpers/common

setup_file() {
    export SRC="$BATS_FILE_TMPDIR/wine-src"
    mkdir -p "$SRC"
    # The pinned base moves at every bump; read it from vendor/ rather than
    # naming a commit that would silently go stale here.
    base="$(awk '{print $2}' "$REPO/vendor/wine-base.sha256")"
    zstd -dc --long=27 "$REPO/vendor/$base" | tar -x -C "$SRC"
    cd "$SRC" || return 1
    git init -q
    git -c user.email=build@localhost -c user.name=dist add -A
    git -c user.email=build@localhost -c user.name=dist commit -q -m "base 5c23dd1c"
    git tag pristine-base
}

# Tests below mutate $SRC; each one that does starts from the pinned base so
# they stay order-independent.
reset_to_base() {
    cd "$SRC" || return 1
    git am --abort >/dev/null 2>&1 || true
    git reset -q --hard pristine-base
    git clean -qfd
}

# --- the freeze manifest -----------------------------------------------------

@test "series: every frozen patch still hashes to its recorded sha256" {
    cd "$REPO/patches"
    run sha256sum -c --quiet SERIES.sha256
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "series: no patch on disk is missing from the freeze manifest" {
    cd "$REPO/patches"
    ondisk="$(ls 00*.patch pipeasio/*.patch)"
    frozen="$(awk '{print $2}' SERIES.sha256 | sort)"
    unlisted="$(printf '%s\n' "$ondisk" | sort | comm -23 - <(printf '%s\n' "$frozen"))"
    [ -z "$unlisted" ] || {
        echo "unfrozen patches (run ./scripts/build-audit.sh --freeze):" >&2
        printf '  %s\n' $unlisted >&2; false; }
}

@test "series: no frozen patch has vanished from disk" {
    cd "$REPO/patches"
    missing=""
    while read -r _ f; do [ -e "$f" ] || missing="$missing $f"; done < SERIES.sha256
    [ -z "$missing" ] || { echo "frozen but absent:$missing" >&2; false; }
}

# --- the apply itself --------------------------------------------------------

@test "wine series applies cleanly to the pinned base, in order" {
    reset_to_base
    n=0
    for p in "$REPO"/patches/00*.patch; do
        n=$((n + 1))
        if head -8 "$p" | grep -q '^From: '; then
            out="$(git -c user.email=build@localhost -c user.name=dist am --3way "$p" 2>&1)" || {
                git am --abort >/dev/null 2>&1
                echo "!! $(basename "$p") does not apply to the base:" >&2
                printf '%s\n' "$out" >&2
                false
            }
        else
            out="$({ printf 'From: dist <build@localhost>\nDate: Thu, 01 Jan 2026 00:00:00 +0000\n'
                     cat "$p"
                   } | git -c user.email=build@localhost -c user.name=dist am --3way 2>&1)" || {
                git am --abort >/dev/null 2>&1
                echo "!! $(basename "$p") does not apply to the base:" >&2
                printf '%s\n' "$out" >&2
                false
            }
        fi
    done
    # base commit + one per patch
    [ "$(git rev-list --count HEAD)" -eq "$((n + 1))" ]
}

@test "pipeasio series applies cleanly to the pinned pipeasio tarball" {
    work="$BATS_TEST_TMPDIR/pipeasio"
    mkdir -p "$work"
    tar xzf "$REPO/vendor/pipeasio-1.2.2.tar.gz" -C "$work" --strip-components=1
    cd "$work"
    for p in "$REPO"/patches/pipeasio/*.patch; do
        run patch -p1 --no-backup-if-mismatch --forward -i "$p"
        [ "$status" -eq 0 ] || {
            echo "!! $(basename "$p") does not apply:" >&2; echo "$output" >&2; false; }
    done
}

# guards: scripts/container-build.sh — git am --3way silently rescues drifted context, and that rescue is what breaks at the next base bump
@test "no patch needs the 3-way fallback — context drift is worth acting on" {
    # The build applies with `git am --3way`, which silently rescues a patch
    # whose context has drifted from the base. That rescue is exactly what
    # stops working at the next base bump. Assert every patch still applies
    # exactly, so drift surfaces while rebasing it is a five-minute job.
    reset_to_base
    fuzzy=""
    for p in "$REPO"/patches/00*.patch; do
        if ! git apply --check "$p" >/dev/null 2>&1; then
            fuzzy="$fuzzy $(basename "$p")"
        fi
        git apply --3way "$p" >/dev/null 2>&1 || true
    done
    [ -z "$fuzzy" ] || { echo "patches that no longer apply exactly:$fuzzy" >&2; false; }
}

# --- registration in the audit ------------------------------------------------
# scripts/build-audit.sh proves each patch is present in the shipped artifact,
# by fingerprint or by the stack stamp. A patch registered in neither is one
# nobody is checking — the audit already errors on it, but only at package
# time, on a machine with a built tarball. Catch it at PR time instead.

# guards: scripts/build-audit.sh — an unregistered patch is one nobody verifies in the shipped artifact
@test "audit: every wine patch is registered in FINGERPRINTS or STAMP_ONLY" {
    unreg=""
    for p in "$REPO"/patches/00*.patch; do
        b="$(basename "$p")"; num="${b%%-*}"
        grep -qE "^ *$num\|" "$REPO/scripts/build-audit.sh" || unreg="$unreg $num"
    done
    [ -z "$unreg" ] || {
        echo "patches with no entry in build-audit.sh:$unreg" >&2
        echo "add a FINGERPRINTS line (a string literal the patch introduces)" >&2
        echo "or a STAMP_ONLY line (why it has no distinctive literal)." >&2
        false; }
}

@test "audit: no FINGERPRINTS or STAMP_ONLY entry refers to a deleted patch" {
    stale=""
    while read -r num; do
        [ -n "$num" ] || continue
        ls "$REPO"/patches/"$num"-*.patch >/dev/null 2>&1 || stale="$stale $num"
    done < <(grep -oE '^0[0-9]{3}\|' "$REPO/scripts/build-audit.sh" | tr -d '|' | sort -u)
    [ -z "$stale" ] || { echo "audit entries for patches that no longer exist:$stale" >&2; false; }
}

# --- numbering ----------------------------------------------------------------
# Retired numbers stay retired: renumbering breaks cross-references in patch
# titles, notes/ and issue threads. A gap is fine when documented in
# build-audit.sh's SERIES_GAPS; an undocumented one means a patch was dropped.

@test "numbering: every gap in the series is documented in SERIES_GAPS" {
    mapfile -t nums < <(cd "$REPO/patches" && ls 00*.patch | sed 's/-.*//' | sort)
    undocumented=""
    expect=1
    for num in "${nums[@]}"; do
        printf -v want '%04d' "$expect"
        while [ "$num" != "$want" ]; do
            grep -qE "^ *\[$want\]=" "$REPO/scripts/build-audit.sh" || undocumented="$undocumented $want"
            expect=$((expect + 1))
            printf -v want '%04d' "$expect"
            [ "$expect" -le 9999 ] || break
        done
        expect=$((expect + 1))
    done
    [ -z "$undocumented" ] || {
        echo "undocumented gaps in the patch series:$undocumented" >&2
        echo "add a SERIES_GAPS entry in scripts/build-audit.sh saying why." >&2
        false; }
}

@test "numbering: no two patches share a number" {
    cd "$REPO/patches"
    dupes="$(ls 00*.patch | sed 's/-.*//' | sort | uniq -d)"
    [ -z "$dupes" ] || { echo "duplicate patch numbers: $dupes" >&2; false; }
}

# --- patch file hygiene -------------------------------------------------------

@test "patches: every wine patch carries a Subject and a diff" {
    # The wine series goes through `git am`, so each file must be a valid
    # mailbox entry: no Subject means no commit message in the applied tree,
    # which is what `git log` in the build container is read from when a
    # bisect goes looking for which patch introduced something.
    bad=""
    for p in "$REPO"/patches/00*.patch; do
        grep -q '^Subject: ' "$p" || bad="$bad $(basename "$p"):no-subject"
        grep -q '^--- ' "$p"      || bad="$bad $(basename "$p"):no-diff"
    done
    [ -z "$bad" ] || { echo "malformed patch files:$bad" >&2; false; }
}

@test "patches: pipeasio patches are plain diffs, as patch -p1 expects" {
    # Deliberately NOT mailbox format: container-build.sh applies these with
    # `patch -p1`, not `git am`. A mail header here would be applied as
    # context and corrupt the file.
    for p in "$REPO"/patches/pipeasio/*.patch; do
        grep -q '^--- ' "$p" || { echo "$(basename "$p") has no diff" >&2; false; }
    done
}
