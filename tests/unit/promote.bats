#!/usr/bin/env bats
#
# scripts/promote-nightly.sh — a nightly becomes a release without a rebuild.
#
# The promise under test: the Wine bits survive verbatim, the identity fields
# that tie the release back to the soaked build survive verbatim, and only the
# naming changes. Every refusal is a state where that promise cannot hold.
#
#   ./tests/run.sh tests/unit/promote.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    setup_stubs
    HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    . "$REPO/scripts/runtime-env.sh"
    NAME="$(works_runtime_name)"
    export WORKS_PROMOTE_DEST="$BATS_TEST_TMPDIR/out"
}

# A miniature runtime tarball: the real one is 60M of Wine, but promotion only
# reads BUILD-INFO and repacks, so a tree with identity and one payload file
# exercises every path. install.sh's deep ELF checks are not in play here.
mk_nightly() {   # mk_nightly [field-to-omit]
    local omit="${1:-}" d="$BATS_TEST_TMPDIR/tree"
    rm -rf "$d"; mkdir -p "$d/$NAME/bin"
    printf 'wine bits stand-in\n' > "$d/$NAME/bin/wine"
    {
        echo "dist-version:  2026.08.06.1"
        [ "$omit" = source-commit ] || echo "source-commit: 79d8960aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        [ "$omit" = built-at ]      || echo "built-at:      2026-08-06T04:12:00Z"
        [ "$omit" = build-kind ]    || echo "build-kind:    nightly"
        echo "wine:          11.13"
    } > "$d/$NAME/ABLETON-WINE-BUILD-INFO.txt"
    TARBALL="$BATS_TEST_TMPDIR/$NAME-2026.08.06.1+nightly.79d8960.tar.zst"
    tar -C "$d" -c "$NAME" | zstd -q -f -o "$TARBALL"
}

@test "a nightly promotes: plain name, checksum, and both BUILD-INFO copies" {
    mk_nightly
    run bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" 2026.08.09.1
    [ "$status" -eq 0 ]
    [ -f "$WORKS_PROMOTE_DEST/$NAME-2026.08.09.1.tar.zst" ]
    [ -f "$WORKS_PROMOTE_DEST/$NAME-2026.08.09.1.tar.zst.sha256" ]
    [ -f "$WORKS_PROMOTE_DEST/BUILD-INFO-2026.08.09.1.txt" ]
    [ -f "$WORKS_PROMOTE_DEST/BUILD-INFO.txt" ]
    ( cd "$WORKS_PROMOTE_DEST" && sha256sum -c "$NAME-2026.08.09.1.tar.zst.sha256" )
}

@test "the output is a tarball the selector accepts as a release" {
    mk_nightly
    bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" 2026.08.09.1 >/dev/null
    works_is_runtime_tarball "$WORKS_PROMOTE_DEST/$NAME-2026.08.09.1.tar.zst"
    [ "$(basename "$(works_pick_tarball "$WORKS_PROMOTE_DEST")")" = "$NAME-2026.08.09.1.tar.zst" ]
}

@test "dist-version is the release, build-kind is gone, promoted-from records the origin" {
    mk_nightly
    bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" 2026.08.09.1 >/dev/null
    info="$WORKS_PROMOTE_DEST/BUILD-INFO-2026.08.09.1.txt"
    [ "$(works_buildinfo_field "$info" dist-version)" = "2026.08.09.1" ]
    [ -z "$(works_buildinfo_field "$info" build-kind)" ]
    [ "$(works_buildinfo_field "$info" promoted-from)" = "2026.08.06.1+nightly.79d8960" ]
}

# guards: the updater compares source-commit and retention orders by built-at —
# rewriting either would sever the release from the build that soaked
@test "source-commit and built-at survive the restamp unchanged" {
    mk_nightly
    bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" 2026.08.09.1 >/dev/null
    info="$WORKS_PROMOTE_DEST/BUILD-INFO-2026.08.09.1.txt"
    [ "$(works_buildinfo_field "$info" source-commit)" = "79d8960aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]
    [ "$(works_buildinfo_field "$info" built-at)" = "2026-08-06T04:12:00Z" ]
}

@test "the payload bits survive verbatim" {
    mk_nightly
    before="$(zstd -dc "$TARBALL" | tar -xO "$NAME/bin/wine" | sha256sum)"
    bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" 2026.08.09.1 >/dev/null
    after="$(zstd -dc "$WORKS_PROMOTE_DEST/$NAME-2026.08.09.1.tar.zst" | tar -xO "$NAME/bin/wine" | sha256sum)"
    [ "$before" = "$after" ]
}

@test "the unpacked result names itself <version>+<short-commit> in the store" {
    mk_nightly
    bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" 2026.08.09.1 >/dev/null
    d="$BATS_TEST_TMPDIR/unpacked"; mkdir -p "$d"
    zstd -dc "$WORKS_PROMOTE_DEST/$NAME-2026.08.09.1.tar.zst" | tar -x -C "$d"
    [ "$(works_runtime_id "$d/$NAME")" = "2026.08.09.1+79d8960" ]
}

@test "a plain release tarball is refused: nothing to promote" {
    mk_nightly
    plain="$BATS_TEST_TMPDIR/$NAME-2026.08.06.1.tar.zst"
    cp "$TARBALL" "$plain"
    run bash "$REPO/scripts/promote-nightly.sh" "$plain" 2026.08.09.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"already a release"* ]]
}

@test "a tarball with no source-commit is refused, because identity is the point" {
    mk_nightly source-commit
    run bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" 2026.08.09.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"source-commit"* ]]
}

@test "a labelled tarball whose BUILD-INFO says release is refused" {
    mk_nightly build-kind
    run bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" 2026.08.09.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"already a release build"* ]]
}

@test "a malformed target version is refused before anything is unpacked" {
    mk_nightly
    run bash "$REPO/scripts/promote-nightly.sh" "$TARBALL" v13-final
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a dated release version"* ]]
}

# The honest fixture, when one is on disk: promote the real published nightly
# and prove the Wine binary inside is bit-identical. Mirrors the
# WORKS_TEST_TARBALL convention in install-runs.bats.
@test "a real nightly tarball promotes losslessly" {
    [ -n "${WORKS_TEST_NIGHTLY_TARBALL:-}" ] && [ -f "$WORKS_TEST_NIGHTLY_TARBALL" ] \
        || skip "no nightly tarball; set WORKS_TEST_NIGHTLY_TARBALL to run this"
    before="$(zstd -dc --long=27 "$WORKS_TEST_NIGHTLY_TARBALL" | tar -xO "$NAME/bin/wine" | sha256sum)"
    bash "$REPO/scripts/promote-nightly.sh" "$WORKS_TEST_NIGHTLY_TARBALL" 2026.08.09.1 >/dev/null
    out="$WORKS_PROMOTE_DEST/$NAME-2026.08.09.1.tar.zst"
    after="$(zstd -dc --long=27 "$out" | tar -xO "$NAME/bin/wine" | sha256sum)"
    [ "$before" = "$after" ]
}
