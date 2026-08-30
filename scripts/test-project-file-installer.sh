#!/usr/bin/env bash
# The project-file copy loop: fixed destinations, one dated backup directory
# per run, and one question per run when a destination already exists.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ableton-project-files-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fail()
{
    echo "not ok - $*" >&2
    exit 1
}

ok()
{
    echo "ok - $*"
}

mkdir -p -- "$tmp/work"
mkdir -p -- "$tmp/home" "$tmp/config" "$tmp/data" "$tmp/cache" "$tmp/run"
cp -- "$here/lib/config.sh" "$tmp/work/new-a"
cp -- "$here/lib/pipeasio.sh" "$tmp/work/new-b"
cp -- "$here/lib/lifecycle.sh" "$tmp/work/old"
question='│  ├─ FILES FROM AN EARLIER INSTALLATION ALREADY EXIST'

# Every case runs the copy loop the way install.sh does: the renderer and the
# file helpers are sourced, a step is open, and the answers arrive on stdin.
run_loop()
{
    env -i PATH="$PATH" HOME="$tmp/home" TMPDIR="$tmp" \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
        XDG_CACHE_HOME="$tmp/cache" XDG_RUNTIME_DIR="$tmp/run" \
        ABLETON_UI_ACTION=install ABLETON_UI_KIT=1 TERM=xterm \
        ABLETON_SIMPLE_PROJECT_FILES=1 \
        ABLETON_UI_PROMPT_TIMEOUT="${PROMPT_TIMEOUT:-30}" "$@" bash -c '
        . "$1/lib/ui.sh"
        . "$1/lib/manifest.sh"
        ui_step_begin s_launchers
        shift 2
        eval "$@"
    ' _ "$here" "$tmp" "${LOOP_BODY:?}"
}

# --yes overwrites every existing destination into one run directory and
# never asks.
cp -- "$tmp/work/old" "$tmp/work/a"
cp -- "$tmp/work/old" "$tmp/work/b"
LOOP_BODY='
    ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/a"
    ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/b"
    test "$ABLETON_OPTIONAL_FILE_FAILURES" -eq 0
' run_loop ABLETON_STATE_HOME="$tmp/state-overwrite" ABLETON_PROJECT_ASSUME_YES=1 tmp="$tmp" \
    > "$tmp/yes.out" 2>&1 || fail "--yes did not complete both copies"
cmp -s -- "$tmp/work/new-a" "$tmp/work/a" || fail "first overwrite was not installed"
cmp -s -- "$tmp/work/new-b" "$tmp/work/b" || fail "second overwrite was not installed"
! grep -qF "$question" "$tmp/yes.out" || fail "--yes asked the overwrite question"
mapfile -t overwrite_runs < <(find "$tmp/state-overwrite/backups" -mindepth 1 -maxdepth 1 -type d)
[ "${#overwrite_runs[@]}" -eq 1 ] || fail "overwrites did not share one run backup directory"
backup_a="$(find "${overwrite_runs[0]}" -type f -name 'a.bak-*' -print -quit)"
backup_b="$(find "${overwrite_runs[0]}" -type f -name 'b.bak-*' -print -quit)"
[ -n "$backup_a" ] && [ -n "$backup_b" ] || fail "dated overwrite backups are missing"
cmp -s -- "$tmp/work/old" "$backup_a" || fail "first backup changed"
cmp -s -- "$tmp/work/old" "$backup_b" || fail "second backup changed"
[ ! -e "$tmp/state-overwrite/install-manifest.tsv" ] \
    && [ ! -e "$tmp/state-overwrite/install-prestate.tsv" ] \
    || fail "simple overwrites created manifest or prestate records"
ok "overwrites use one inert per-run backup directory"

# The question is asked once, as a QUESTION block in the open step, with
# Overwrite all as the default. Enter, EOF, and a timeout all pick it.
overwrite_case()
{
    local name="$1" feed="$2"
    cp -- "$tmp/work/old" "$tmp/work/$name-a"
    cp -- "$tmp/work/old" "$tmp/work/$name-b"
    LOOP_BODY='
        ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/'"$name"'-a"
        ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/'"$name"'-b"
        test "$ABLETON_OPTIONAL_FILE_FAILURES" -eq 0
        test "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0
    ' run_loop ABLETON_STATE_HOME="$tmp/state-$name" tmp="$tmp" \
        < <(eval "$feed") > "$tmp/$name.out" 2>&1 || fail "$name did not complete both copies"
    cmp -s -- "$tmp/work/new-a" "$tmp/work/$name-a" || fail "$name did not replace its first destination"
    cmp -s -- "$tmp/work/new-b" "$tmp/work/$name-b" || fail "$name did not replace a remaining destination"
    [ "$(grep -cF "$question" "$tmp/$name.out")" -eq 1 ] || fail "$name asked more or less than one question"
    grep -qF '│  │  > [O]verwrite all (Default)' "$tmp/$name.out" \
        && grep -qF '│  │  > [K]eep originals' "$tmp/$name.out" \
        && grep -qF '│  │  > [A]bort' "$tmp/$name.out" \
        || fail "$name did not offer the three answers"
    grep -q '^│  │  🛈 Existing files will be moved to .*backups/.* before they are replaced\.$' "$tmp/$name.out" \
        || fail "$name did not name the backup directory after the answer"
    [ "$(find "$tmp/state-$name/backups" -type f -name "$name-*.bak-*" | wc -l)" -eq 2 ] \
        || fail "$name did not preserve both displaced files"
}
overwrite_case enter "printf '\n'"
overwrite_case letter "printf 'o\n'"
overwrite_case word "printf 'Overwrite all\n'"
overwrite_case eof ":"
PROMPT_TIMEOUT=1 overwrite_case timeout "sleep 4"
grep -qF '(Press Enter for default or wait 1 seconds)' "$tmp/timeout.out" \
    || fail "the question names its timeout"
ok "one Overwrite all question covers the run; Enter, EOF, and the timeout choose it"

# Overwrite all remains selected when the coordinator moves to its next child.
mkdir -p -- "$tmp/state-cross/backups/run"
cp -- "$tmp/work/old" "$tmp/work/cross-a"
cp -- "$tmp/work/old" "$tmp/work/cross-b"
LOOP_BODY='ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/cross-a"' \
    run_loop ABLETON_STATE_HOME="$tmp/state-cross" \
        ABLETON_PROJECT_BACKUP_DIR="$tmp/state-cross/backups/run" \
        ABLETON_PROJECT_BACKUP_STAMP=20260828 tmp="$tmp" \
    < <(printf 'o\n') > "$tmp/cross.out" 2>&1 || fail "Overwrite all was not recorded for the installer run"
LOOP_BODY='ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/cross-b"' \
    run_loop ABLETON_STATE_HOME="$tmp/state-cross" \
        ABLETON_PROJECT_BACKUP_DIR="$tmp/state-cross/backups/run" \
        ABLETON_PROJECT_BACKUP_STAMP=20260828 tmp="$tmp" \
    < /dev/null >> "$tmp/cross.out" 2>&1 || fail "Overwrite all did not reach the next installer process"
[ "$(grep -cF "$question" "$tmp/cross.out")" -eq 1 ] \
    || fail "Overwrite all prompted again after an installer process boundary"
cmp -s -- "$tmp/work/new-a" "$tmp/work/cross-a" \
    && cmp -s -- "$tmp/work/new-b" "$tmp/work/cross-b" \
    || fail "cross-process Overwrite all did not replace both destinations"
ok "Overwrite all applies to the whole installer run"

# A failed cross-process marker is an installer error, not a user cancellation.
printf 'not a directory\n' > "$tmp/bad-overwrite-state"
cp -- "$tmp/work/old" "$tmp/work/all-state-fail"
rm -f -- "$tmp/work/after-all-state-fail"
LOOP_BODY='
    ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/all-state-fail"
    ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/after-all-state-fail"
    test "$ABLETON_OPTIONAL_FILE_FAILURES" -eq 1
    test "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0
' run_loop ABLETON_STATE_HOME="$tmp/state-all-state-fail" \
    ABLETON_PROJECT_BACKUP_DIR="$tmp/bad-overwrite-state" \
    ABLETON_PROJECT_BACKUP_STAMP=20260828 tmp="$tmp" \
    < <(printf 'o\n') > "$tmp/all-state-fail.out" 2>&1 \
    || fail "Overwrite all state failure was not reported as a file error"
cmp -s -- "$tmp/work/old" "$tmp/work/all-state-fail" \
    || fail "Overwrite all state failure changed its destination"
cmp -s -- "$tmp/work/new-b" "$tmp/work/after-all-state-fail" \
    || fail "Overwrite all state failure stopped later independent copies"
grep -qF 'This file was left unchanged.' "$tmp/all-state-fail.out" \
    || fail "Overwrite all state failure omitted its exact outcome"
ok "Overwrite all state failures are errors, not cancellation"

# Keep originals keeps every existing destination for the rest of the run,
# across processes, and still writes where nothing exists.
cp -- "$tmp/work/old" "$tmp/work/keep-a"
cp -- "$tmp/work/old" "$tmp/work/keep-b"
rm -f -- "$tmp/work/keep-new"
mkdir -p -- "$tmp/state-keep/backups/run"
LOOP_BODY='
    ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/keep-a"
    ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/keep-b"
    ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/keep-new"
    test "$ABLETON_OPTIONAL_FILES_KEPT" -eq 2
' run_loop ABLETON_STATE_HOME="$tmp/state-keep" \
    ABLETON_PROJECT_BACKUP_DIR="$tmp/state-keep/backups/run" \
    ABLETON_PROJECT_BACKUP_STAMP=20260828 tmp="$tmp" \
    < <(printf 'Keep\n') > "$tmp/keep.out" 2>&1 || fail "Keep stopped the mapping loop"
[ "$(grep -cF "$question" "$tmp/keep.out")" -eq 1 ] || fail "Keep asked more than once"
grep -qF '│  │  🛈 Existing files are kept unchanged; new files are written only where nothing exists.' "$tmp/keep.out" \
    || fail "Keep did not explain itself"
cmp -s -- "$tmp/work/old" "$tmp/work/keep-a" && cmp -s -- "$tmp/work/old" "$tmp/work/keep-b" \
    || fail "Keep changed an existing destination"
cmp -s -- "$tmp/work/new-b" "$tmp/work/keep-new" || fail "Keep prevented a copy to an empty destination"
grep -qF 'Kept existing file unchanged' "$tmp/keep.out" || fail "kept files are reported"
cp -- "$tmp/work/old" "$tmp/work/keep-c"
LOOP_BODY='
    ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/keep-c"
    test "$ABLETON_OPTIONAL_FILES_KEPT" -eq 1
' run_loop ABLETON_STATE_HOME="$tmp/state-keep" \
    ABLETON_PROJECT_BACKUP_DIR="$tmp/state-keep/backups/run" \
    ABLETON_PROJECT_BACKUP_STAMP=20260828 tmp="$tmp" \
    < /dev/null > "$tmp/keep-cross.out" 2>&1 || fail "Keep did not reach the next installer process"
! grep -qF "$question" "$tmp/keep-cross.out" || fail "Keep prompted again after a process boundary"
cmp -s -- "$tmp/work/old" "$tmp/work/keep-c" || fail "cross-process Keep changed a destination"
ok "Keep originals applies to the whole installer run"

# Abort keeps the current destination and stops all later mappings without
# unwinding what was already copied.
rm -f -- "$tmp/work/before-abort" "$tmp/work/after-abort"
cp -- "$tmp/work/old" "$tmp/work/abort-target"
LOOP_BODY='
    ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/before-abort"
    ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/abort-target"
    ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/after-abort"
    test "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 1
' run_loop ABLETON_STATE_HOME="$tmp/state-abort" tmp="$tmp" \
    < <(printf 'a\n') > "$tmp/abort.out" 2>&1 || fail "Abort state was not retained"
grep -qF '│  │  🛈 Stopping before any existing file is replaced.' "$tmp/abort.out" \
    || fail "Abort did not explain itself"
cmp -s -- "$tmp/work/new-a" "$tmp/work/before-abort" || fail "Abort unwound an earlier completed copy"
cmp -s -- "$tmp/work/old" "$tmp/work/abort-target" || fail "Abort changed its current destination"
[ ! -e "$tmp/work/after-abort" ] || fail "Abort did not stop later mappings"
ok "Abort stops later mappings without unwinding completed copies"

# An unknown answer is asked again; a whole word maps to its key letter.
cp -- "$tmp/work/old" "$tmp/work/retry-target"
LOOP_BODY='
    ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/retry-target"
    test "$ABLETON_OPTIONAL_FILES_KEPT" -eq 1
' run_loop ABLETON_STATE_HOME="$tmp/state-retry" tmp="$tmp" \
    < <(printf 'maybe\nkeep originals\n') > "$tmp/retry.out" 2>&1 || fail "an invalid answer stopped the loop"
cmp -s -- "$tmp/work/old" "$tmp/work/retry-target" || fail "the retried answer was not honoured"
[ "$(grep -c 'Please choose \[O/K/A\]:' "$tmp/retry.out")" -eq 2 ] \
    || fail "an unknown answer repeats the prompt once"
ok "an unknown answer is asked again"

# A backup failure leaves its destination untouched and later copies continue.
cp -- "$tmp/work/old" "$tmp/work/backup-fail"
rm -f -- "$tmp/work/after-backup-fail"
LOOP_BODY='
    ableton_install_project_file 644 "$tmp/work/new-a" "$tmp/work/backup-fail"
    ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/after-backup-fail"
    test "$ABLETON_OPTIONAL_FILE_FAILURES" -eq 1
' run_loop ABLETON_STATE_HOME="$tmp/state-backup-fail" \
    ABLETON_PROJECT_BACKUP_DIR=/proc/ableton-project-file-test \
    ABLETON_PROJECT_BACKUP_STAMP=20260827 ABLETON_PROJECT_ASSUME_YES=1 tmp="$tmp" \
    > "$tmp/backup-fail.out" 2>&1 || fail "a backup failure was not counted as one failure"
cmp -s -- "$tmp/work/old" "$tmp/work/backup-fail" || fail "backup failure changed its destination"
cmp -s -- "$tmp/work/new-b" "$tmp/work/after-backup-fail" || fail "backup failure prevented a later copy"
grep -qF "$tmp/work/backup-fail" "$tmp/backup-fail.out" || fail "backup failure did not report its destination"
ok "backup failure leaves the destination untouched and continues"

# Make the source and destination the same to force cp to fail only after mv.
cp -- "$tmp/work/old" "$tmp/work/copy-fail"
rm -f -- "$tmp/work/after-copy-fail"
LOOP_BODY='
    ableton_install_project_file 644 "$tmp/work/copy-fail" "$tmp/work/copy-fail"
    ableton_install_project_file 644 "$tmp/work/new-b" "$tmp/work/after-copy-fail"
    test "$ABLETON_OPTIONAL_FILE_FAILURES" -eq 1
' run_loop ABLETON_STATE_HOME="$tmp/state-copy-fail" ABLETON_PROJECT_ASSUME_YES=1 tmp="$tmp" \
    > "$tmp/copy-fail.out" 2>&1 || fail "a copy failure was not counted as one failure"
[ ! -e "$tmp/work/copy-fail" ] || fail "copy failure restored its destination"
copy_backup="$(find "$tmp/state-copy-fail/backups" -type f -name 'copy-fail.bak-*' -print -quit)"
[ -n "$copy_backup" ] || fail "copy failure lost the inert backup"
cmp -s -- "$tmp/work/old" "$copy_backup" || fail "copy failure backup changed"
cmp -s -- "$tmp/work/new-b" "$tmp/work/after-copy-fail" || fail "copy failure prevented a later copy"
grep -qF "$tmp/work/copy-fail" "$tmp/copy-fail.out" || fail "copy failure did not report the actual path"
ok "copy failure is reported, left for manual recovery, and continues"

# Publication replaces every historical runtime row with the configured
# runtime while preserving valid non-runtime rows this invocation did not touch.
publication="$tmp/publication"
mkdir -p -- "$publication/home" "$publication/config" "$publication/data" \
    "$publication/state" "$publication/cache" "$publication/run" \
    "$publication/runtime-current"
env -i PATH="$PATH" HOME="$publication/home" TMPDIR="$tmp" \
    XDG_CONFIG_HOME="$publication/config" XDG_DATA_HOME="$publication/data" \
    XDG_STATE_HOME="$publication/state" \
    XDG_CACHE_HOME="$publication/cache" XDG_RUNTIME_DIR="$publication/run" \
    ABLETON_WINE_ROOT="$publication/runtime-current" \
    bash -c '
        set -euo pipefail
        . "$1/lib/config.sh"
        . "$1/lib/manifest.sh"
        ableton_config_init repair
        ableton_mark_state_home

        untouched="$ABLETON_DATA_HOME/detect-scale.sh"
        changed_path="$ABLETON_DATA_HOME/check-ntsync.sh"
        added="$ABLETON_DATA_HOME/lib/config.sh"
        outside="$HOME/not-an-ableton-output"
        mkdir -p -- "$(dirname "$added")"
        printf "untouched generation\n" > "$untouched"
        printf "changed after an earlier installed-file list\n" > "$changed_path"
        printf "new generation\n" > "$added"
        printf "foreign\n" > "$outside"
        untouched_digest="$(sha256sum -- "$untouched")"
        untouched_digest="${untouched_digest%% *}"
        cat > "$ABLETON_STATE_HOME/install-manifest.tsv" <<EOF
file	$untouched	$untouched_digest
file	$changed_path	0000000000000000000000000000000000000000000000000000000000000000
runtime	$HOME/stale-runtime-one	$ABLETON_RUNTIME_NAME
runtime	$HOME/stale-runtime-two	$ABLETON_RUNTIME_NAME
EOF
        chmod 600 "$ABLETON_STATE_HOME/install-manifest.tsv"
        ableton_validate_ownership_manifest
        if ableton_record_owned "$outside" file; then
            echo "outside path was accepted" >&2
            exit 91
        fi
        ableton_record_owned "$added" file
        ABLETON_RUNTIME_INSTALLED=1
        ableton_write_ownership_manifest
        ableton_validate_ownership_manifest
    ' _ "$here" > "$publication/out" 2> "$publication/err" \
    || { sed -n '1,40p' "$publication/err" >&2; fail "ownership manifest publication failed"; }
publication_manifest="$publication/state/ableton-wine/install-manifest.tsv"
[ -f "$publication_manifest" ] || fail "ownership manifest was not published"
untouched="$publication/data/ableton-wine/detect-scale.sh"
added="$publication/data/ableton-wine/lib/config.sh"
changed_path="$publication/data/ableton-wine/check-ntsync.sh"
untouched_digest="$(sha256sum -- "$untouched" | awk '{print $1}')"
added_digest="$(sha256sum -- "$added" | awk '{print $1}')"
grep -qxF "$(printf 'file\t%s\t%s' "$untouched" "$untouched_digest")" \
    "$publication_manifest" \
    || fail "publication dropped an untouched allowed non-runtime row"
grep -qxF "$(printf 'file\t%s\t%s' "$changed_path" \
    0000000000000000000000000000000000000000000000000000000000000000)" \
    "$publication_manifest" \
    || fail "publication replaced the recorded digest for a file left untouched by the current install"
grep -qxF "$(printf 'file\t%s\t%s' "$added" "$added_digest")" \
    "$publication_manifest" \
    || fail "publication omitted the newly owned file"
[ "$(awk -F '\t' '$1=="runtime" { n++ } END { print n+0 }' \
        "$publication_manifest")" -eq 1 ] \
    || fail "publication did not reduce runtime ownership to one row"
awk -F '\t' -v p="$publication/runtime-current" \
    '$1=="runtime" && $2==p && NF==3 { found=1 } END { exit !found }' \
    "$publication_manifest" \
    || fail "publication did not record the configured runtime"
! grep -qF "$publication/home/stale-runtime-" "$publication_manifest" \
    || fail "publication retained a stale runtime row"
ok "publication keeps recorded digests for untouched files and replaces old runtime rows"

echo "All project-file installer tests passed."
