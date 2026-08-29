#!/usr/bin/env bash
# Frozen contract for the installer pre-flight preference store and PipeASIO
# buffer editor.  Behaviour IDs map to notes/PREFLIGHT-SETTINGS-TEST-MATRIX.md.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
preferences_lib="$here/lib/preferences.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-preferences-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

pass=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

[ -r "$preferences_lib" ] || fail "scripts/lib/preferences.sh exists"

preferences_api()   # base function [arguments...]
{
    local base="$1" function="$2"
    shift 2
    # Source and invoke the library only in a clean child context. This catches
    # accidental source-time dependence on the caller's shell or environment.
    # shellcheck disable=SC2016 # this is the isolated child shell program
    env -i PATH="$PATH" LC_ALL=C HOME="$base/home" \
        XDG_CONFIG_HOME="$base/config" \
        bash -c '
            set -euo pipefail
            cd "$HOME"
            . "$1"
            function="$2"
            shift 2
            "$function" "$@"
        ' _ "$preferences_lib" "$function" "$@"
}

required_api=(
    ableton_preferences_valid
    ableton_preferences_object_token
    ableton_preferences_apply
    ableton_preferences_merge
    ableton_preferences_write
    ableton_preferences_remove
    ableton_pipeasio_seed_identity_token
    ableton_pipeasio_seed_record_preflight
    ableton_pipeasio_seed_record_commit_preflight
    ableton_pipeasio_seed_record_publish
    ableton_pipeasio_seed_record_promote
    ableton_pipeasio_seed_record_rollback
    ableton_pipeasio_seed_record_commit
    ableton_pipeasio_buffer_read
    ableton_pipeasio_buffer_write
)
mkdir -p -- "$work/api/home" "$work/api/config"
# shellcheck disable=SC2016 # this is the isolated child shell program
env -i PATH="$PATH" LC_ALL=C HOME="$work/api/home" \
    XDG_CONFIG_HOME="$work/api/config" \
    bash -c '
        set -euo pipefail
        cd "$HOME"
        . "$1"
        shift
        for function; do
            declare -F "$function" >/dev/null || exit 1
        done
    ' _ "$preferences_lib" "${required_api[@]}" \
    || fail "preferences.sh does not define its complete isolated API"
! find "$work/api/home" "$work/api/config" -mindepth 1 -print -quit | grep -q . \
    || fail "sourcing preferences.sh changes its isolated home or config context"
ok "PREF-API: the side-effect-free preference library exposes its tested API"

# Test-facing proxies keep every library load and invocation in that isolated
# child without obscuring the public function names used by the contract.
ableton_preferences_valid() { preferences_api "$base" ableton_preferences_valid "$@"; }
ableton_preferences_object_token() { preferences_api "$base" ableton_preferences_object_token "$@"; }
ableton_preferences_merge() { preferences_api "$base" ableton_preferences_merge "$@"; }
ableton_preferences_write() { preferences_api "$base" ableton_preferences_write "$@"; }
ableton_preferences_remove() { preferences_api "$base" ableton_preferences_remove "$@"; }
ableton_pipeasio_seed_identity_token() { preferences_api "$base" ableton_pipeasio_seed_identity_token "$@"; }
ableton_pipeasio_seed_record_preflight() { preferences_api "$base" ableton_pipeasio_seed_record_preflight "$@"; }
ableton_pipeasio_seed_record_commit_preflight() { preferences_api "$base" ableton_pipeasio_seed_record_commit_preflight "$@"; }
ableton_pipeasio_seed_record_publish() { preferences_api "$base" ableton_pipeasio_seed_record_publish "$@"; }
ableton_pipeasio_seed_record_promote() { preferences_api "$base" ableton_pipeasio_seed_record_promote "$@"; }
ableton_pipeasio_seed_record_rollback() { preferences_api "$base" ableton_pipeasio_seed_record_rollback "$@"; }
ableton_pipeasio_seed_record_commit() { preferences_api "$base" ableton_pipeasio_seed_record_commit "$@"; }
ableton_pipeasio_buffer_read() { preferences_api "$base" ableton_pipeasio_buffer_read "$@"; }
ableton_pipeasio_buffer_write() { preferences_api "$base" ableton_pipeasio_buffer_write "$@"; }

new_home()   # name -> path
{
    local base="$work/$1"
    mkdir -p -- "$base/home" "$base/config"
    printf '%s\n' "$base"
}

apply_preferences()   # base [environment assignments...]
{
    local base="$1"; shift
    # shellcheck disable=SC2016 # this is the child shell program, not parent expansion
    env -i PATH="$PATH" LC_ALL=C HOME="$base/home" \
        XDG_CONFIG_HOME="$base/config" \
        "$@" bash -c '
            set -euo pipefail
            cd "$HOME"
            . "$1"
            ableton_preferences_apply
            printf "%s|%s|%s|%s|%s\n" "$ABLETON_SHORTCUTS" "$ABLETON_DPI_MODE" \
                "$ABLETON_MAX_AUDIO_THREADS" "$ABLETON_RT" "$ABLETON_POWER"
        ' _ "$preferences_lib"
}

write_fixture()   # base shortcuts dpi threads rt power
{
    local base="$1" shortcuts="$2" dpi="$3" threads="$4" rt="$5" power="$6"
    local file="$base/config/ableton-wine/preferences"
    mkdir -p -- "$(dirname "$file")"
    cat > "$file" <<EOF
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=$shortcuts
dpi=$dpi
audio_threads=$threads
rt=$rt
power=$power
EOF
    chmod 600 "$file"
}

object_snapshot()   # path -> stable description of object type/link/mode/bytes
{
    local path="$1"
    if [ -L "$path" ]; then
        printf 'type=symlink\nidentity=%s\nmode=%s\nlink=%s\n' \
            "$(stat -c '%d:%i|%w|%y|%z' -- "$path")" \
            "$(stat -c '%a' -- "$path")" "$(readlink -- "$path")"
        if [ -f "$path" ]; then
            printf 'target-identity=%s\ntarget-mode=%s\ntarget-bytes=%s\n' \
                "$(stat -Lc '%d:%i|%w|%y|%z' -- "$path")" \
                "$(stat -Lc '%a' -- "$path")" "$(sha256sum -- "$path" | awk '{print $1}')"
        fi
    elif [ -f "$path" ]; then
        printf 'type=file\nidentity=%s\nmode=%s\nbytes=%s\n' \
            "$(stat -c '%d:%i|%w|%y|%z' -- "$path")" \
            "$(stat -c '%a' -- "$path")" "$(sha256sum -- "$path" | awk '{print $1}')"
    elif [ -d "$path" ]; then
        printf 'type=directory\nidentity=%s\nmode=%s\nentries=' \
            "$(stat -c '%d:%i|%w|%y|%z' -- "$path")" "$(stat -c '%a' -- "$path")"
        find "$path" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort
    elif [ -e "$path" ]; then
        printf 'type=other\nmode=%s\n' "$(stat -c '%a' -- "$path")"
    else
        printf 'type=absent\n'
    fi
}

# PREF-DEFAULTS: these are the compatibility defaults when no file exists.
base="$(new_home defaults)"
[ "$(apply_preferences "$base")" = 'take|auto|auto|auto|performance' ] \
    || fail "absent preferences use the confirmed launcher defaults"
[ ! -e "$base/config/ableton-wine/preferences" ] \
    || fail "reading absent preferences does not create them"
ok "PREF-DEFAULTS: absent preferences are read-only and use confirmed defaults"

# PREF-LOAD: every persisted value is applied, including Live's existing
# audio-thread 'off' representation for the user-facing 'Let Live decide'.
base="$(new_home load)"
write_fixture "$base" preserve preserve off off balanced
[ "$(apply_preferences "$base")" = 'preserve|preserve|off|off|balanced' ] \
    || fail "valid preferences are not applied exactly"
ableton_preferences_valid "$base/config/ableton-wine/preferences" \
    || fail "the exact generated preferences schema is not valid"
ok "PREF-LOAD: all five saved launcher preferences load from strict data"

# PREF-MERGE: the dispatcher asks the same parser to merge explicit CLI intent.
# Empty fields mean retain saved/default; environment is deliberately absent
# from this API so it cannot become persistent by accident.
base="$(new_home merge-api)"
missing="$base/config/ableton-wine/preferences"
[ "$(ableton_preferences_merge "$missing" '' '' '' off '')" = \
  'take|auto|auto|off|performance' ] \
    || fail "absent-store merge does not overlay one explicit value on defaults"
write_fixture "$base" preserve preserve off off balanced
[ "$(ableton_preferences_merge "$missing" '' auto '' '' performance)" = \
  'preserve|auto|off|off|performance' ] \
    || fail "saved-store merge resets retained fields or ignores explicit values"
before="$(object_snapshot "$missing")"
if ableton_preferences_merge "$missing" '' '' 64 '' '' \
    >"$base/merge-invalid.out" 2>"$base/merge-invalid.err"; then
    fail "merge API accepts an invalid explicit value"
fi
[ "$(object_snapshot "$missing")" = "$before" ] \
    || fail "refusing an invalid merge changes stored preferences"
ok "PREF-MERGE: one strict API combines saved/default values with explicit intent"

# PREF-ENV: non-empty launch environment wins; an empty variable retains the
# launchers' historical ${VAR:-default} meaning and therefore does not mask a
# saved preference.
base="$(new_home precedence)"
write_fixture "$base" preserve 100 12 off balanced
got="$(apply_preferences "$base" env \
    ABLETON_SHORTCUTS=take ABLETON_DPI_MODE= ABLETON_MAX_AUDIO_THREADS=8 \
    ABLETON_RT=auto ABLETON_POWER=off)"
[ "$got" = 'take|100|8|auto|off' ] \
    || fail "nonempty environment does not override saved values, or empty environment masks one"
ok "PREF-ENV: nonempty environment overrides saved values and empty means unset"

# PREF-COMPAT: the historical power spellings remain one-run aliases for the
# explicit performance policy. Unknown values stop at validation instead of
# accidentally selecting a profile.
base="$(new_home compatibility)"
write_fixture "$base" take auto auto auto balanced
for legacy in on auto; do
    [ "$(apply_preferences "$base" env ABLETON_POWER="$legacy")" = \
      'take|auto|auto|auto|performance' ] \
        || fail "legacy ABLETON_POWER=$legacy is not mapped to performance"
done
if apply_preferences "$base" env ABLETON_POWER=fast \
    >"$base/out" 2>"$base/err"; then
    fail "unknown ABLETON_POWER value is accepted"
fi
grep -qF 'ABLETON_POWER must be performance, balanced, or off' "$base/err" \
    || fail "unknown power policy has no actionable validation message"
ok "PREF-COMPAT: legacy power aliases map explicitly and unknown values fail validation"

# PREF-MALFORMED: optional preferences can never make Live or Max unlaunchable.
# A malformed format-1 file is ignored with an actionable warning and is not
# rewritten by a launcher.
base="$(new_home malformed)"
write_fixture "$base" preserve auto auto auto performance
printf 'shortcuts=take\n' >> "$base/config/ableton-wine/preferences"
before="$(object_snapshot "$base/config/ableton-wine/preferences")"
got="$(apply_preferences "$base" 2>"$base/err")"
[ "$got" = 'take|auto|auto|auto|performance' ] \
    || fail "malformed preferences do not fall back to compatibility defaults"
grep -qF 'launcher preferences are malformed; using defaults' "$base/err" \
    || fail "malformed preferences do not name their safe fallback"
[ "$(object_snapshot "$base/config/ableton-wine/preferences")" = "$before" ] \
    || fail "a launcher rewrites malformed preferences"
ok "PREF-MALFORMED: malformed optional preferences warn, fall back, and remain untouched"

# PREF-FUTURE: a future format is data owned by a newer installer. It is never
# accepted as current and never overwritten by a format-1 writer.
base="$(new_home future)"
file="$base/config/ableton-wine/preferences"
mkdir -p -- "$(dirname "$file")"
printf '# ableton-linux launcher preferences; managed by the installer\nformat=2\n' > "$file"
chmod 600 "$file"
before="$(object_snapshot "$file")"
! ableton_preferences_valid "$file" || fail "a future preference format is accepted as format 1"
token="$(ableton_preferences_object_token "$file")"
! ableton_preferences_write "$file" "$token" take auto auto auto performance \
    >"$base/out" 2>"$base/err" \
    || fail "the writer replaces an unknown future preference format"
[ "$(object_snapshot "$file")" = "$before" ] \
    || fail "the refused future preference file changed"
ok "PREF-FUTURE: unknown formats are preserved for a newer installer"

# PREF-VALIDATION: the header and every schema key are present exactly once;
# unknown, binary and indirect objects also fail the strict validator.
base="$(new_home validation)"
write_fixture "$base" take auto auto auto performance
cp -- "$base/config/ableton-wine/preferences" "$base/valid-preferences"
valid="$base/valid-preferences"
for key in format shortcuts dpi audio_threads rt power; do
    candidate="$base/missing-$key"
    sed "/^$key=/d" "$valid" > "$candidate"
    chmod --reference="$valid" "$candidate"
    before="$(object_snapshot "$candidate")"
    ! ableton_preferences_valid "$candidate" \
        || fail "preferences missing required key $key pass validation"
    [ "$(object_snapshot "$candidate")" = "$before" ] \
        || fail "validating missing $key mutates the candidate"
    candidate="$base/duplicate-$key"
    cp -- "$valid" "$candidate"
    grep -m1 "^$key=" "$valid" >> "$candidate"
    chmod --reference="$valid" "$candidate"
    before="$(object_snapshot "$candidate")"
    ! ableton_preferences_valid "$candidate" \
        || fail "preferences duplicating required key $key pass validation"
    [ "$(object_snapshot "$candidate")" = "$before" ] \
        || fail "validating duplicate $key mutates the candidate"
done
for kind in missing-header wrong-header duplicate-header unknown nul symlink directory; do
    candidate="$base/$kind"
    case "$kind" in
        missing-header) sed '1d' "$valid" > "$candidate" ;;
        wrong-header)
            sed '1c# similar but unmanaged launcher preferences' "$valid" > "$candidate"
            ;;
        duplicate-header)
            cp -- "$valid" "$candidate"
            sed -n '1p' "$valid" >> "$candidate"
            ;;
        unknown) cp -- "$valid" "$candidate"; printf 'other=value\n' >> "$candidate" ;;
        nul) cp -- "$valid" "$candidate"; printf '\0' >> "$candidate" ;;
        symlink) ln -s -- "$valid" "$candidate" ;;
        directory) mkdir -- "$candidate" ;;
    esac
    if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
        chmod --reference="$valid" "$candidate"
        [ "$(stat -c '%a' "$candidate")" = "$(stat -c '%a' "$valid")" ] \
            || fail "$kind validation candidate does not isolate schema from mode"
    fi
    before="$(object_snapshot "$candidate")"
    ! ableton_preferences_valid "$candidate" \
        || fail "$kind preferences pass the strict validator"
    [ "$(object_snapshot "$candidate")" = "$before" ] \
        || fail "validating $kind preferences mutates the candidate"
done
for kind in extra-comment reordered whitespace crlf displaced-header; do
    candidate="$base/$kind"
    case "$kind" in
        extra-comment) cp -- "$valid" "$candidate"; printf '# user note\n' >> "$candidate" ;;
        reordered)
            {
                sed -n '1,2p' "$valid"
                sed -n '4p' "$valid"
                sed -n '3p' "$valid"
                sed -n '5,$p' "$valid"
            } > "$candidate" ;;
        whitespace) sed 's/^format=1$/format = 1/' "$valid" > "$candidate" ;;
        crlf) sed 's/$/\r/' "$valid" > "$candidate" ;;
        displaced-header)
            { printf 'foreign text\n'; cat "$valid"; } > "$candidate" ;;
    esac
    chmod --reference="$valid" "$candidate"
    [ "$(stat -c '%a' "$candidate")" = "$(stat -c '%a' "$valid")" ] \
        || fail "$kind exact-record candidate does not isolate layout from mode"
    if [ "$kind" = reordered ]; then
        ! cmp -s -- "$valid" "$candidate" \
            || fail "reordered fixture does not actually change record order"
        LC_ALL=C sort "$valid" > "$base/valid.sorted"
        LC_ALL=C sort "$candidate" > "$base/reordered.sorted"
        cmp -s -- "$base/valid.sorted" "$base/reordered.sorted" \
            || fail "reordered fixture changes semantic records, not only order"
    fi
    before="$(object_snapshot "$candidate")"
    ! ableton_preferences_valid "$candidate" \
        || fail "$kind preferences pass exact-record validation"
    [ "$(object_snapshot "$candidate")" = "$before" ] \
        || fail "validating $kind preferences mutates the candidate"
done
ok "PREF-VALIDATION: the exact header/key schema and direct safe object are mandatory"

# PREF-APPLY-UNSAFE: each unsafe optional-store shape warns, leaves the entire
# object unchanged, uses compatibility defaults, and still honours valid
# nonempty one-run environment overrides.
for kind in future nul symlink directory incomplete; do
    base="$(new_home "apply-$kind")"
    write_fixture "$base" preserve 100 12 off balanced
    file="$base/config/ableton-wine/preferences"
    case "$kind" in
        future) sed -i 's/^format=1$/format=2/' "$file" ;;
        nul) printf '\0' >> "$file" ;;
        symlink)
            mv -- "$file" "$base/preferences-target"
            ln -s -- "$base/preferences-target" "$file"
            ;;
        directory) rm -f -- "$file"; mkdir -- "$file" ;;
        incomplete) sed -i '/^audio_threads=/d' "$file" ;;
    esac
    before="$(object_snapshot "$file")"
    got="$(apply_preferences "$base" env ABLETON_SHORTCUTS=preserve \
        ABLETON_RT=off ABLETON_POWER=balanced 2>"$base/apply.err")"
    [ "$got" = 'preserve|auto|auto|off|balanced' ] \
        || fail "$kind optional preferences do not combine safe defaults with environment intent"
    grep -qF 'launcher preferences are malformed; using defaults' "$base/apply.err" \
        || fail "$kind optional preferences do not issue the fallback warning"
    [ "$(object_snapshot "$file")" = "$before" ] \
        || fail "applying $kind optional preferences changed its type, link, mode, or bytes"
done
ok "PREF-APPLY-UNSAFE: unsafe optional stores warn, remain exact, and cannot block environment intent"

# PREF-HOSTILE: values are parsed as inert data, never sourced as shell. Every
# field rejects values outside its documented grammar; launcher application
# falls back safely without changing or executing the record.
base="$(new_home hostile)"
write_fixture "$base" take auto auto auto performance
cp -- "$base/config/ableton-wine/preferences" "$base/valid-preferences"
valid="$base/valid-preferences"
sentinel="$base/should-not-exist"
for field_value in \
    'shortcuts=other' 'dpi=125' 'audio_threads=64' 'rt=on' 'power=fast' \
    "shortcuts=\$(touch $sentinel)"; do
    candidate="$base/hostile-preferences"
    cp -- "$valid" "$candidate"
    field="${field_value%%=*}"
    sed -i "s#^$field=.*#$field_value#" "$candidate"
    ! ableton_preferences_valid "$candidate" \
        || fail "invalid stored $field_value passes validation"
    mkdir -p -- "$base/config/ableton-wine"
    cp -- "$candidate" "$base/config/ableton-wine/preferences"
    before="$(object_snapshot "$base/config/ableton-wine/preferences")"
    [ "$(apply_preferences "$base" 2>"$base/hostile.err")" = \
      'take|auto|auto|auto|performance' ] \
        || fail "invalid stored $field_value does not fall back safely"
    [ "$(object_snapshot "$base/config/ableton-wine/preferences")" = "$before" ] \
        || fail "validating hostile $field changed its bytes"
    [ ! -e "$sentinel" ] || fail "preferences were executed as shell code"
done
environment_sentinel="$base/environment-should-not-exist"
for assignment in ABLETON_SHORTCUTS=other ABLETON_DPI_MODE=125 \
                  ABLETON_MAX_AUDIO_THREADS=64 ABLETON_RT=on \
                  ABLETON_POWER=fast \
                  "ABLETON_SHORTCUTS=\$(touch $environment_sentinel)"; do
    before="$(object_snapshot "$base/config/ableton-wine/preferences")"
    if apply_preferences "$base" env "$assignment" \
        >"$base/env-invalid.out" 2>"$base/env-invalid.err"; then
        fail "invalid environment override succeeds: $assignment"
    fi
    [ "$(object_snapshot "$base/config/ableton-wine/preferences")" = "$before" ] \
        || fail "refusing environment override $assignment mutates preferences"
done
[ ! -e "$environment_sentinel" ] \
    || fail "an environment preference value was executed as shell code"
ok "PREF-HOSTILE: invalid stored/environment values are inert and fail closed"

# PREF-WRITE: an absent target is written atomically with exact bytes and mode.
base="$(new_home write)"
file="$base/config/ableton-wine/preferences"
token="$(ableton_preferences_object_token "$file")"
[ "$token" = absent ] || fail "an absent preference target has the wrong token"
ableton_preferences_write "$file" "$token" preserve fractional 16 off balanced \
    || fail "the preference writer cannot create a new record"
cat > "$base/expected" <<'EOF'
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=preserve
dpi=fractional
audio_threads=16
rt=off
power=balanced
EOF
cmp -s -- "$base/expected" "$file" || fail "the preference writer emitted unexpected bytes"
[ "$(stat -c '%a' "$file")" = 600 ] || fail "preferences are not private mode 0600"
! find "$(dirname "$file")" -maxdepth 1 -name '.preferences.*' | grep -q . \
    || fail "an atomic preference temporary file remains"

# Rewriting an existing valid record normalises a permissive mode to 0600.
chmod 644 "$file"
token="$(ableton_preferences_object_token "$file")"
old_inode="$(stat -c '%d:%i' "$file")"
ableton_preferences_write "$file" "$token" take 100 4 auto performance \
    || fail "an existing valid preference record cannot be rewritten"
cat > "$base/rewrite-expected" <<'EOF'
# ableton-linux launcher preferences; managed by the installer
format=1
shortcuts=take
dpi=100
audio_threads=4
rt=auto
power=performance
EOF
cmp -s -- "$base/rewrite-expected" "$file" \
    || fail "rewriting existing preferences emitted unexpected bytes"
[ "$(stat -c '%a' "$file")" = 600 ] \
    || fail "rewriting mode-0644 preferences does not normalise them to 0600"
[ "$(stat -c '%d:%i' "$file")" != "$old_inode" ] \
    || fail "successful preference publication rewrites the old inode in place"
ok "PREF-WRITE: preferences are exact, private, and atomically published"

# PREF-PUBLISH-FAIL: a failure while creating the replacement must leave the
# previously published target exact. A zero file-size limit is inherited by
# the isolated writer and deterministically interrupts any nonempty publish.
base="$(new_home publish-failure)"
write_fixture "$base" preserve auto off auto balanced
file="$base/config/ableton-wine/preferences"
token="$(ableton_preferences_object_token "$file")"
before="$(object_snapshot "$file")"
if (ulimit -f 0; ableton_preferences_write "$file" "$token" \
        take fractional 16 off performance) \
        >"$base/publish.out" 2>"$base/publish.err"; then
    fail "preference publication succeeds despite a forced write failure"
fi
[ "$(object_snapshot "$file")" = "$before" ] \
    || fail "failed publication changed the old target's type, mode, or bytes"
! find "$(dirname "$file")" -maxdepth 1 -name '.preferences.*' | grep -q . \
    || fail "failed publication leaves its private temporary object behind"
ok "PREF-PUBLISH-FAIL: interrupted publication preserves the exact old target"

# PREF-RACE: a stale token and a symlink target both preserve the newer object.
base="$(new_home race)"
write_fixture "$base" take auto auto auto performance
file="$base/config/ableton-wine/preferences"
token="$(ableton_preferences_object_token "$file")"
sed -i 's/power=performance/power=off/' "$file"
before="$(object_snapshot "$file")"
! ableton_preferences_write "$file" "$token" preserve 100 4 auto balanced \
    || fail "a stale preference generation is overwritten"
[ "$(object_snapshot "$file")" = "$before" ] \
    || fail "a race refusal changed the preference type, mode, or bytes"
mv -- "$file" "$base/real-preferences"
ln -s -- "$base/real-preferences" "$file"
token="$(ableton_preferences_object_token "$file")"
before="$(object_snapshot "$file")"
! ableton_preferences_write "$file" "$token" take auto auto auto performance \
    || fail "the preference writer follows a symlink"
[ "$(object_snapshot "$file")" = "$before" ] \
    || fail "a symlink refusal changed its type, link, mode, or target bytes"
ok "PREF-RACE: generation changes and symlinks are preserved"

# PREF-ABA: tokens bind the inspected object generation, not merely its final
# bytes or size. Same-byte inode replacement and an in-place change restored to
# identical bytes must both refuse later writer/remover operations.
base="$(new_home aba)"
write_fixture "$base" take auto auto auto performance
file="$base/config/ableton-wine/preferences"
token="$(ableton_preferences_object_token "$file")"
cp -p -- "$file" "$base/same-bytes"
mv -f -- "$base/same-bytes" "$file"
before="$(object_snapshot "$file")"
! ableton_preferences_write "$file" "$token" preserve 100 4 off balanced \
    || fail "same-byte inode replacement is accepted as the inspected generation"
[ "$(object_snapshot "$file")" = "$before" ] \
    || fail "refusing same-byte inode replacement changes the newer object"

token="$(ableton_preferences_object_token "$file")"
original_inode="$(stat -c '%d:%i' "$file")"
original_mtime="$(stat -c '%y' "$file")"
cp -p -- "$file" "$base/aba-bytes"
printf 'temporarily different\n' > "$file"
cp -- "$base/aba-bytes" "$file"
touch -r "$base/aba-bytes" "$file"
[ "$(stat -c '%d:%i' "$file")" = "$original_inode" ] \
    || fail "same-inode ABA fixture replaced the inspected inode"
[ "$(stat -c '%y' "$file")" = "$original_mtime" ] \
    || fail "same-inode ABA fixture did not restore the inspected mtime"
cmp -s -- "$base/aba-bytes" "$file" \
    || fail "same-inode ABA fixture did not restore the inspected bytes"
before="$(object_snapshot "$file")"
! ableton_preferences_remove "$file" "$token" \
    || fail "same-inode ABA restoration is accepted as the inspected generation"
[ "$(object_snapshot "$file")" = "$before" ] \
    || fail "refusing same-inode ABA restoration changes the restored object"
ok "PREF-ABA: same-byte replacement and restored-byte ABA generations are rejected"

# PREF-REMOVE: the removal helper uses the inspected format-1 record. It leaves
# a malformed or changed file in place for review.
base="$(new_home remove)"
write_fixture "$base" preserve auto off auto balanced
file="$base/config/ableton-wine/preferences"
token="$(ableton_preferences_object_token "$file")"
ableton_preferences_remove "$file" "$token" \
    || fail "the exact valid preferences record cannot be removed"
[ ! -e "$file" ] || fail "valid unchanged preferences survive their requested removal"
write_fixture "$base" preserve auto off auto balanced
token="$(ableton_preferences_object_token "$file")"
sed -i 's/power=balanced/power=off/' "$file"
before="$(object_snapshot "$file")"
! ableton_preferences_remove "$file" "$token" \
    || fail "a changed preferences record is removed"
[ "$(object_snapshot "$file")" = "$before" ] || fail "changed preferences were modified"
printf 'unknown=value\n' >> "$file"
token="$(ableton_preferences_object_token "$file")"
before="$(object_snapshot "$file")"
! ableton_preferences_remove "$file" "$token" \
    || fail "malformed preferences are removed"
[ "$(object_snapshot "$file")" = "$before" ] \
    || fail "malformed preferences do not remain byte-for-byte for inspection"
ok "PREF-REMOVE: the helper removes a valid unchanged preferences record"

# BUFFER-READ: PipeASIO accepts any unique integer from 32 through 8192. The
# menu may offer fewer presets, but must retain an existing custom value.
base="$(new_home buffer-read)"
pipeasio="$base/config/pipeasio/config.ini"
mkdir -p -- "$(dirname "$pipeasio")"
for value in 32 64 128 883 1024 2048 8192; do
    printf '[pipeasio]\ninputs = 2\nbuffer_size = %s\noutputs = 2\n' "$value" > "$pipeasio"
    [ "$(ableton_pipeasio_buffer_read "$pipeasio")" = "$value" ] \
        || fail "PipeASIO buffer $value is not read exactly"
done
for value in 0 31 8193 text; do
    printf '[pipeasio]\nbuffer_size = %s\n' "$value" > "$pipeasio"
    before="$(object_snapshot "$pipeasio")"
    ! ableton_pipeasio_buffer_read "$pipeasio" >/dev/null \
        || fail "invalid PipeASIO buffer $value is accepted"
    [ "$(object_snapshot "$pipeasio")" = "$before" ] \
        || fail "reading invalid PipeASIO buffer $value mutates its object"
done
ok "BUFFER-READ: every valid existing PipeASIO buffer is retained, including custom values"

# BUFFER-SECTIONS: buffer_size keys in unrelated sections neither compete with
# nor get rewritten in place of the unique key owned by [pipeasio].
base="$(new_home buffer-sections)"
pipeasio="$base/config/pipeasio/config.ini"
mkdir -p -- "$(dirname "$pipeasio")"
cat > "$pipeasio" <<'EOF'
[other]
buffer_size = 4096

[pipeasio]
inputs = 4
buffer_size = 256

[next]
buffer_size = 1024
EOF
[ "$(ableton_pipeasio_buffer_read "$pipeasio")" = 256 ] \
    || fail "buffer keys in other sections make the unique PipeASIO key unreadable"
token="$(ableton_preferences_object_token "$pipeasio")"
ableton_pipeasio_buffer_write "$pipeasio" "$token" 512 \
    || fail "buffer keys in other sections make the unique PipeASIO key unwritable"
cat > "$base/sections-expected" <<'EOF'
[other]
buffer_size = 4096

[pipeasio]
inputs = 4
buffer_size = 512

[next]
buffer_size = 1024
EOF
cmp -s -- "$base/sections-expected" "$pipeasio" \
    || fail "the PipeASIO editor rewrites a competing key in another section"
ok "BUFFER-SECTIONS: only the buffer key inside the unique PipeASIO section is authoritative"

# BUFFER-WRITE: only confirmed menu presets can be requested. Updating one key
# preserves all unrelated sections, comments, order and values.
base="$(new_home buffer-write)"
pipeasio="$base/config/pipeasio/config.ini"
mkdir -p -- "$(dirname "$pipeasio")"
cat > "$pipeasio" <<'EOF'
; user comment
[other]
value = untouched

[pipeasio]
inputs = 8
buffer_size = 2048
outputs = 10
auto_connect = false
EOF
chmod 644 "$pipeasio"
token="$(ableton_preferences_object_token "$pipeasio")"
ableton_pipeasio_buffer_write "$pipeasio" "$token" 512 \
    || fail "a uniquely parseable PipeASIO buffer cannot be updated"
cat > "$base/pipeasio-expected" <<'EOF'
; user comment
[other]
value = untouched

[pipeasio]
inputs = 8
buffer_size = 512
outputs = 10
auto_connect = false
EOF
cmp -s -- "$base/pipeasio-expected" "$pipeasio" \
    || fail "the buffer editor changed unrelated PipeASIO bytes"
[ "$(stat -c '%a' "$pipeasio")" = 600 ] || fail "the updated PipeASIO file is not mode 0600"
for value in 64 128 256 512 1024; do
    token="$(ableton_preferences_object_token "$pipeasio")"
    ableton_pipeasio_buffer_write "$pipeasio" "$token" "$value" \
        || fail "confirmed buffer preset $value is rejected"
    [ "$(ableton_pipeasio_buffer_read "$pipeasio")" = "$value" ] \
        || fail "confirmed buffer preset $value is not actually written"
done
token="$(ableton_preferences_object_token "$pipeasio")"
before="$(object_snapshot "$pipeasio")"
! ableton_pipeasio_buffer_write "$pipeasio" "$token" 883 \
    || fail "a non-menu buffer can be newly requested"
[ "$(object_snapshot "$pipeasio")" = "$before" ] \
    || fail "refusing a non-menu buffer changed its type, mode, or bytes"
ok "BUFFER-WRITE: buffer presets update one key without disturbing the user's configuration"

# A final line without LF is unrelated topology and remains byte-exact apart
# from the selected number.
base="$(new_home buffer-no-final-newline)"
pipeasio="$base/config/pipeasio/config.ini"
mkdir -p -- "$(dirname "$pipeasio")"
printf '[pipeasio]\nbuffer_size = 256' > "$pipeasio"
token="$(ableton_preferences_object_token "$pipeasio")"
ableton_pipeasio_buffer_write "$pipeasio" "$token" 512 \
    || fail "a PipeASIO file without final LF cannot be updated"
printf '[pipeasio]\nbuffer_size = 512' > "$base/no-final-newline.expected"
cmp -s -- "$base/no-final-newline.expected" "$pipeasio" \
    || fail "the buffer editor changes a missing final newline"
ok "BUFFER-EOF: buffer updates preserve the original final-newline state"

# PIPEASIO-SEED-PROVENANCE: provisional producer identity is durable before
# publication, then upgraded to the exact destination generation. Failure in
# either phase removes only the producer; same-byte replacements are kept.
base="$(new_home pipeasio-seed-provenance)"
pipeasio="$base/config/pipeasio/config.ini"
txn="$base/txn"
mkdir -p -- "$(dirname "$pipeasio")" "$txn"
seed_tmp="$base/config/pipeasio/.config.ini.ABC123"
printf '[pipeasio]\nbuffer_size = 128\n' > "$seed_tmp"
chmod 600 "$seed_tmp"
producer_token="$(ableton_pipeasio_seed_identity_token "$seed_tmp")"
ableton_pipeasio_seed_record_publish "$txn" "$pipeasio" "$producer_token" "$seed_tmp" \
    || fail "producer identity cannot be journalled before publication"
[ ! -e "$pipeasio" ] && [ -f "$txn/pipeasio-seed.v1" ] \
    || fail "provisional provenance is not durable before destination publication"
provisional_journal_before="$(object_snapshot "$txn/pipeasio-seed.v1")"
provisional_temp_before="$(object_snapshot "$seed_tmp")"
! ableton_pipeasio_seed_record_commit_preflight "$txn" \
    || fail "commit preflight accepts rollback-only provisional provenance"
! ableton_pipeasio_seed_record_commit "$txn" \
    || fail "commit retires rollback-only provisional provenance"
[ "$(object_snapshot "$txn/pipeasio-seed.v1")" = "$provisional_journal_before" ] \
    && [ "$(object_snapshot "$seed_tmp")" = "$provisional_temp_before" ] \
    || fail "refused provisional commit changes its journal or producer temp"
ableton_pipeasio_seed_record_rollback "$txn" \
    || fail "a crash before destination rename cannot recover its producer temp"
[ ! -e "$pipeasio" ] && [ ! -e "$txn/pipeasio-seed.v1" ] \
    && [ ! -e "$seed_tmp" ] && [ ! -L "$seed_tmp" ] \
    || fail "before-rename rollback leaves destination, journal, or producer temp"

printf '[pipeasio]\nbuffer_size = 128\n' > "$seed_tmp"
chmod 600 "$seed_tmp"
producer_token="$(ableton_pipeasio_seed_identity_token "$seed_tmp")"
ableton_pipeasio_seed_record_publish "$txn" "$pipeasio" "$producer_token" "$seed_tmp" \
    || fail "post-rename crash fixture cannot publish provisional provenance"
mv -T -n -- "$seed_tmp" "$pipeasio"
ableton_pipeasio_seed_record_rollback "$txn" \
    || fail "a crash after rename but before token promotion cannot recover"
[ ! -e "$pipeasio" ] && [ ! -e "$txn/pipeasio-seed.v1" ] \
    || fail "pre-token failure retains the producer generation or journal"

# A same-value file that wins the destination before the producer rename has
# a different producer identity and must survive provisional rollback.
printf '[pipeasio]\nbuffer_size = 128\n' > "$seed_tmp"
chmod 600 "$seed_tmp"
producer_token="$(ableton_pipeasio_seed_identity_token "$seed_tmp")"
ableton_pipeasio_seed_record_publish "$txn" "$pipeasio" "$producer_token" "$seed_tmp" \
    || fail "pre-token replacement fixture cannot publish provisional provenance"
printf '[pipeasio]\nbuffer_size = 128\n' > "$pipeasio"
replacement_token="$(ableton_preferences_object_token "$pipeasio")"
ableton_pipeasio_seed_record_rollback "$txn" \
    || fail "provisional rollback rejects a raced destination"
[ -f "$pipeasio" ] && [ ! -e "$txn/pipeasio-seed.v1" ] \
    && [ ! -e "$seed_tmp" ] && [ ! -L "$seed_tmp" ] \
    && grep -qxF 'buffer_size = 128' "$pipeasio" \
    || fail "provisional rollback deletes a same-value destination it did not publish"
rm -f -- "$pipeasio"

printf '[pipeasio]\nbuffer_size = 128\n' > "$seed_tmp"
chmod 600 "$seed_tmp"
producer_token="$(ableton_pipeasio_seed_identity_token "$seed_tmp")"
ableton_pipeasio_seed_record_publish "$txn" "$pipeasio" "$producer_token" "$seed_tmp" \
    || fail "normal promotion fixture cannot publish provisional provenance"
mv -T -n -- "$seed_tmp" "$pipeasio"
ableton_pipeasio_seed_record_promote "$txn" "$pipeasio" "$producer_token" \
    || fail "producer identity cannot be promoted to the full destination token"
ableton_pipeasio_seed_record_preflight "$txn" \
    || fail "a promoted production seed journal fails strict preflight"
seed_token="$(ableton_preferences_object_token "$pipeasio")"
recorded_token="$(sed -n 's/^token_b64=//p' "$txn/pipeasio-seed.v1" | base64 --decode)"
[ "$recorded_token" = "$seed_token" ] \
    || fail "promotion does not journal the full destination generation"
ableton_pipeasio_seed_record_rollback "$txn" \
    || fail "an unchanged fresh PipeASIO generation cannot be rolled back"
[ ! -e "$pipeasio" ] && [ ! -L "$pipeasio" ] \
    && [ ! -e "$txn/pipeasio-seed.v1" ] \
    || fail "after-seed failure retains the installer-created generation or journal"

printf '[pipeasio]\nbuffer_size = 128\n' > "$pipeasio"
seed_token="$(ableton_preferences_object_token "$pipeasio")"
ableton_pipeasio_seed_record_publish "$txn" "$pipeasio" "$seed_token" \
    || fail "same-value replacement fixture cannot journal its initial generation"
printf '[pipeasio]\nbuffer_size = 128\n' > "$base/replacement"
mv -T -f -- "$base/replacement" "$pipeasio"
replacement_token="$(ableton_preferences_object_token "$pipeasio")"
[ "$replacement_token" != "$seed_token" ] \
    || fail "same-value replacement fixture did not change the full object token"
ableton_pipeasio_seed_record_rollback "$txn" \
    || fail "rollback rejects a user replacement of a seeded file"
[ -f "$pipeasio" ] && [ ! -L "$pipeasio" ] \
    && grep -qxF 'buffer_size = 128' "$pipeasio" \
    && [ ! -e "$txn/pipeasio-seed.v1" ] \
    || fail "rollback deletes a byte-identical replacement it does not own"

rm -f -- "$pipeasio"
printf '[pipeasio]\nbuffer_size = 128\n' > "$pipeasio"
seed_token="$(ableton_preferences_object_token "$pipeasio")"
ableton_pipeasio_seed_record_publish "$txn" "$pipeasio" "$seed_token" \
    || fail "commit fixture cannot journal its fresh generation"
printf '[pipeasio]\nbuffer_size = 128\n' > "$base/commit-replacement"
mv -T -f -- "$base/commit-replacement" "$pipeasio"
replacement_token="$(ableton_preferences_object_token "$pipeasio")"
[ "$replacement_token" != "$seed_token" ] \
    || fail "commit replacement fixture did not change the full object token"
commit_replacement_before="$(object_snapshot "$pipeasio")"
ableton_pipeasio_seed_record_commit "$txn" \
    || fail "successful prefix commit cannot retire its seed journal"
[ "$(object_snapshot "$pipeasio")" = "$commit_replacement_before" ] \
    && [ ! -e "$txn/pipeasio-seed.v1" ] \
    || fail "successful commit changes settings or retains seed ownership"

ln -s -- "$base/foreign-record" "$txn/pipeasio-seed.v1"
before="$(object_snapshot "$pipeasio")"
! ableton_pipeasio_seed_record_preflight "$txn" \
    || fail "a symlinked seed journal passes recovery preflight"
! ableton_pipeasio_seed_record_rollback "$txn" \
    || fail "rollback acts through an unsafe seed journal"
! ableton_pipeasio_seed_record_commit "$txn" \
    || fail "commit acts through an unsafe seed journal"
[ "$(object_snapshot "$pipeasio")" = "$before" ] \
    || fail "unsafe seed recovery data changes the current PipeASIO object"
rm -f -- "$txn/pipeasio-seed.v1"

# Canonically encoded but structurally malformed records are as unsafe as
# links. Every recovery entry point must refuse them without retiring evidence.
path_b64="$(printf '%s' "$pipeasio" | base64 | tr -d '\n')"
full_token="$(ableton_preferences_object_token "$pipeasio")"
token_b64="$(printf '%s' "$full_token" | base64 | tr -d '\n')"
wrong_path_b64="$(printf '%s' "$base/config/elsewhere.ini" | base64 | tr -d '\n')"
garbage_token_b64="$(printf '%s' 'file|garbage' | base64 | tr -d '\n')"
producer_for_malformed="$(ableton_pipeasio_seed_identity_token "$pipeasio")"
producer_b64="$(printf '%s' "$producer_for_malformed" | base64 | tr -d '\n')"
valid_temp_b64="$(printf '%s' "$base/config/pipeasio/.config.ini.XYZ789" | base64 | tr -d '\n')"
wrong_temp_b64="$(printf '%s' "$base/config/pipeasio/not-a-seed" | base64 | tr -d '\n')"
foreign_temp="$base/config/foreign/.config.ini.QWE456"
mkdir -p -- "$(dirname "$foreign_temp")"
printf 'foreign temp sentinel\n' > "$foreign_temp"
foreign_temp_b64="$(printf '%s' "$foreign_temp" | base64 | tr -d '\n')"
malformed_records=(
    $'format=2\npath_b64='"$path_b64"$'\ntoken_b64='"$token_b64"$'\ntemp_b64='
    $'format=1\npath64='"$path_b64"$'\ntoken_b64='"$token_b64"$'\ntemp_b64='
    $'format=1\npath_b64='"$path_b64"$'\ntoken_b64='"$token_b64"
    $'format=1\npath_b64=%%%\ntoken_b64='"$token_b64"$'\ntemp_b64='
    $'format=1\npath_b64=Zg\ntoken_b64='"$token_b64"$'\ntemp_b64='
    $'format=1\npath_b64='"$wrong_path_b64"$'\ntoken_b64='"$token_b64"$'\ntemp_b64='
    $'format=1\npath_b64='"$path_b64"$'\ntoken_b64='"$garbage_token_b64"$'\ntemp_b64='
    $'format=1\npath_b64='"$path_b64"$'\ntoken_b64=ZmlsZXwx\ntemp_b64='
    $'format=1\npath_b64='"$path_b64"$'\ntoken_b64='"$token_b64"$'\ntemp_b64='"$valid_temp_b64"
    $'format=1\npath_b64='"$path_b64"$'\ntoken_b64='"$producer_b64"$'\ntemp_b64='
    $'format=1\npath_b64='"$path_b64"$'\ntoken_b64='"$producer_b64"$'\ntemp_b64='"$wrong_temp_b64"
    $'format=1\npath_b64='"$path_b64"$'\ntoken_b64='"$producer_b64"$'\ntemp_b64='"$foreign_temp_b64"
)
assert_malformed_seed_record_preserved()
{
    local label="$1" journal_before config_before foreign_temp_before
    journal_before="$(object_snapshot "$txn/pipeasio-seed.v1")"
    config_before="$(object_snapshot "$pipeasio")"
    foreign_temp_before="$(object_snapshot "$foreign_temp")"
    ! ableton_pipeasio_seed_record_preflight "$txn" \
        || fail "$label passes preflight"
    ! ableton_pipeasio_seed_record_commit_preflight "$txn" \
        || fail "$label passes commit preflight"
    ! ableton_pipeasio_seed_record_rollback "$txn" \
        || fail "$label passes rollback"
    ! ableton_pipeasio_seed_record_commit "$txn" \
        || fail "$label passes commit"
    [ "$(object_snapshot "$txn/pipeasio-seed.v1")" = "$journal_before" ] \
        && [ "$(object_snapshot "$pipeasio")" = "$config_before" ] \
        && [ "$(object_snapshot "$foreign_temp")" = "$foreign_temp_before" ] \
        || fail "$label changes evidence or settings"
}
malformed_index=0
for malformed_record in "${malformed_records[@]}"; do
    malformed_index=$((malformed_index + 1))
    printf '%s\n' "$malformed_record" > "$txn/pipeasio-seed.v1"
    assert_malformed_seed_record_preserved \
        "malformed regular journal $malformed_index"
done

rm -f -- "$txn/pipeasio-seed.v1"
full_token="$(ableton_preferences_object_token "$pipeasio")"
ableton_pipeasio_seed_record_publish "$txn" "$pipeasio" "$full_token" \
    || fail "missing-terminal-LF fixture cannot publish a canonical journal"
truncate -s -1 -- "$txn/pipeasio-seed.v1"
assert_malformed_seed_record_preserved \
    "otherwise canonical journal without a terminal LF"

rm -f -- "$txn/pipeasio-seed.v1"
ableton_pipeasio_seed_record_publish "$txn" "$pipeasio" "$full_token" \
    || fail "fifth-line fixture cannot publish a canonical journal"
printf 'extra=1\n' >> "$txn/pipeasio-seed.v1"
assert_malformed_seed_record_preserved "canonical journal with a fifth line"
ok "PIPEASIO-SEED-PROVENANCE: rollback uses durable full-generation ownership"

# BUFFER-MISSING: a unique [pipeasio] section without a buffer gains one at the
# end of that section, before the following section.
base="$(new_home buffer-missing)"
pipeasio="$base/config/pipeasio/config.ini"
mkdir -p -- "$(dirname "$pipeasio")"
printf '[other]\nbuffer_size = 2048\n\n[pipeasio]\ninputs = 2\n\n[next]\nbuffer_size = 4096\n' > "$pipeasio"
! ableton_pipeasio_buffer_read "$pipeasio" >/dev/null \
    || fail "a buffer outside the PipeASIO section masks its missing key"
token="$(ableton_preferences_object_token "$pipeasio")"
ableton_pipeasio_buffer_write "$pipeasio" "$token" 128 \
    || fail "a unique PipeASIO section cannot gain a missing buffer"
cat > "$base/missing-expected" <<'EOF'
[other]
buffer_size = 2048

[pipeasio]
inputs = 2

buffer_size = 128
[next]
buffer_size = 4096
EOF
cmp -s -- "$base/missing-expected" "$pipeasio" \
    || fail "missing buffer insertion changes unrelated bytes or leaves its section"
[ "$(ableton_pipeasio_buffer_read "$pipeasio")" = 128 ] \
    || fail "the newly inserted PipeASIO buffer is not authoritative"
ok "BUFFER-MISSING: a unique section gains its own buffer despite unrelated keys elsewhere"

# BUFFER-NO-SECTION: a config with no [pipeasio] section is foreign topology;
# the editor must not create, guess at, or change it.
base="$(new_home buffer-no-section)"
pipeasio="$base/config/pipeasio/config.ini"
mkdir -p -- "$(dirname "$pipeasio")"
printf '; user topology\n[other]\nbuffer_size = 2048\n' > "$pipeasio"
chmod 640 "$pipeasio"
token="$(ableton_preferences_object_token "$pipeasio")"
before="$(object_snapshot "$pipeasio")"
! ableton_pipeasio_buffer_read "$pipeasio" >/dev/null \
    || fail "a buffer outside any PipeASIO section is accepted by the reader"
! ableton_pipeasio_buffer_write "$pipeasio" "$token" 128 \
    || fail "the editor invents an absent PipeASIO section"
[ "$(object_snapshot "$pipeasio")" = "$before" ] \
    || fail "refusing an absent PipeASIO section changed its type, mode, or bytes"
ok "BUFFER-NO-SECTION: configurations without PipeASIO topology remain exact"

# BUFFER-AMBIGUOUS: duplicate keys/sections, binary data, symlinks, directories,
# stale generations and files that change during the operation are untouched.
base="$(new_home buffer-ambiguous)"
mkdir -p -- "$base/config/pipeasio"
for kind in duplicate-key duplicate-section nul symlink directory stale; do
    pipeasio="$base/config/pipeasio/$kind.ini"
    printf '[pipeasio]\nbuffer_size = 256\n' > "$pipeasio"
    case "$kind" in
        duplicate-key) printf 'buffer_size = 512\n' >> "$pipeasio" ;;
        duplicate-section) printf '[pipeasio]\ninputs = 4\n' >> "$pipeasio" ;;
        nul) printf '\0' >> "$pipeasio" ;;
        symlink) mv -- "$pipeasio" "$pipeasio.real"; ln -s -- "$pipeasio.real" "$pipeasio" ;;
        directory) rm -f -- "$pipeasio"; mkdir -- "$pipeasio" ;;
    esac
    token="$(ableton_preferences_object_token "$pipeasio")"
    if [ "$kind" = stale ]; then printf 'outputs = 4\n' >> "$pipeasio"; fi
    before="$(object_snapshot "$pipeasio")"
    if [ "$kind" = stale ]; then
        [ "$(ableton_pipeasio_buffer_read "$pipeasio")" = 256 ] \
            || fail "a valid file changed after token capture is unreadable"
    else
        ! ableton_pipeasio_buffer_read "$pipeasio" >/dev/null \
            || fail "$kind PipeASIO configuration is accepted by the reader"
    fi
    ! ableton_pipeasio_buffer_write "$pipeasio" "$token" 128 \
        || fail "$kind PipeASIO configuration is overwritten"
    [ "$(object_snapshot "$pipeasio")" = "$before" ] \
        || fail "$kind refusal changed PipeASIO type, link, mode, or bytes"
done
pipeasio="$base/config/pipeasio/hostile.ini"
sentinel="$base/pipeasio-should-not-exist"
# shellcheck disable=SC2016 # literal hostile data must not be expanded by this shell
printf '[pipeasio]\nbuffer_size = $(touch %s)\n' "$sentinel" > "$pipeasio"
before="$(object_snapshot "$pipeasio")"
! ableton_pipeasio_buffer_read "$pipeasio" >/dev/null \
    || fail "hostile PipeASIO buffer text is accepted"
[ "$(object_snapshot "$pipeasio")" = "$before" ] \
    || fail "reading hostile PipeASIO data changed its type, mode, or bytes"
[ ! -e "$sentinel" ] || fail "PipeASIO configuration was executed as shell code"
ok "BUFFER-AMBIGUOUS: unsafe, ambiguous and raced PipeASIO objects fail closed"

printf '%s preference checks passed\n' "$pass"
