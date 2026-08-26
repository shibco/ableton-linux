#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-live-options-test.XXXXXX")"
cleanup()
{
    case "$work" in
        "${TMPDIR:-/tmp}"/ableton-live-options-test.*) rm -rf -- "${work:?}" ;;
        *) printf 'Use a path within the temporary test directory. The cleanup path is %s.\n' "$work" >&2; return 1 ;;
    esac
}
trap cleanup EXIT
. "$here/lib/live-options.sh"

# General tests use 32 processors. Specific tests change the processor count.
getconf()
{
    printf '32\n'
}
nproc()
{
    printf '32\n'
}

pass=0
fail()
{
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
ok()
{
    pass=$((pass + 1))
    printf 'ok - %s\n' "$*"
}
make_prefs()
{
    local prefix="$1" version="${2:-Live 12.4.3}"
    mkdir -p -- "$prefix/drive_c/users/test/AppData/Roaming/Ableton/$version/Preferences"
    printf '%s\n' "$prefix/drive_c/users/test/AppData/Roaming/Ableton/$version/Preferences"
}

topology="$work/topology"
for cpu in 0 1 2 3 4 5 6 7; do
    mkdir -p -- "$topology/cpu$cpu/topology"
    printf '%s\n' "$((cpu / 4))" > "$topology/cpu$cpu/topology/physical_package_id"
    printf '%s\n' "$(((cpu % 4) / 2))" > "$topology/cpu$cpu/topology/core_id"
done
[ "$(ableton_available_physical_cores "$topology" 0-7)" -eq 4 ] \
    || fail 'The topology reader counts each physical core once.'
[ "$(ableton_available_physical_cores "$topology" 0-1,4-5)" -eq 2 ] \
    || fail 'The topology reader includes only CPUs available to the launcher.'
if ableton_available_physical_cores "$topology" 20-21 >/dev/null 2>&1; then
    fail 'The topology reader accepts an affinity list without an available CPU.'
fi
ok 'The topology reader counts available physical cores across processor packages.'

smt_topology="$work/topology-smt32"
no_smt_topology="$work/topology-no-smt32"
for cpu in {0..31}; do
    mkdir -p -- "$smt_topology/cpu$cpu/topology" "$no_smt_topology/cpu$cpu/topology"
    printf '0\n' > "$smt_topology/cpu$cpu/topology/physical_package_id"
    printf '%s\n' "$((cpu % 16))" > "$smt_topology/cpu$cpu/topology/core_id"
    printf '%s\n' "$((cpu / 16))" > "$no_smt_topology/cpu$cpu/topology/physical_package_id"
    printf '%s\n' "$((cpu % 16))" > "$no_smt_topology/cpu$cpu/topology/core_id"
done
[ "$(ableton_available_physical_cores "$smt_topology" 0-31)" -eq 16 ] \
    && [ "$(ableton_available_physical_cores "$smt_topology" 0-3,16-19)" -eq 4 ] \
    || fail 'The topology reader counts SMT siblings once and honours a sparse affinity subset.'
[ "$(ableton_available_physical_cores "$no_smt_topology" 0-31)" -eq 32 ] \
    && [ "$(ableton_available_physical_cores "$no_smt_topology" 0-7,16-23)" -eq 16 ] \
    || fail 'The topology reader retains every no-SMT core and honours affinity across packages.'
ok 'The topology reader covers 32 logical CPUs with SMT, no SMT, sparse affinity and two packages.'

for logical in {1..32}; do
    expected_live=$((2 * logical - 2))
    [ "$expected_live" -ge 1 ] || expected_live=1
    [ "$expected_live" -le 31 ] || expected_live=31
    live_count="$(ableton_live_calculated_audio_threads "$logical")" \
        || fail "Live's calculated worker count rejects $logical available logical processors."
    [ "$live_count" -eq "$expected_live" ] \
        || fail "Live's calculated worker count is $live_count for $logical processors, expected $expected_live."

    no_smt_expected="$logical"
    [ "$no_smt_expected" -le "$expected_live" ] || no_smt_expected="$expected_live"
    no_smt_count="$(ableton_reliable_audio_threads "$logical" "$logical")" \
        || fail "The no-SMT automatic policy rejects $logical processors."
    [ "$no_smt_count" -eq "$no_smt_expected" ] \
        || fail "The no-SMT automatic count is $no_smt_count for $logical processors, expected $no_smt_expected."

    smt_physical=$(((logical + 1) / 2))
    reliability_floor=$(((expected_live + 1) / 2))
    smt_expected="$smt_physical"
    [ "$smt_expected" -ge "$reliability_floor" ] || smt_expected="$reliability_floor"
    [ "$smt_expected" -le "$expected_live" ] || smt_expected="$expected_live"
    smt_count="$(ableton_reliable_audio_threads "$smt_physical" "$logical")" \
        || fail "The SMT automatic policy rejects $logical logical and $smt_physical physical processors."
    [ "$smt_count" -eq "$smt_expected" ] \
        || fail "The SMT automatic count is $smt_count for $logical/$smt_physical processors, expected $smt_expected."
    [ "$smt_count" -ge "$smt_physical" ] || [ "$smt_count" -eq "$expected_live" ] \
        || fail 'The automatic count falls below the usable physical cores.'
    [ "$((2 * smt_count))" -ge "$expected_live" ] \
        || fail "The automatic count cuts more than half of Live's calculated workers."
done
[ "$(ableton_reliable_audio_threads 16 32)" -eq 16 ] \
    || fail 'The reliability floor changes the measured 16-of-31 worker result.'
[ "$(ableton_reliable_audio_threads 4 8)" -eq 7 ] \
    && [ "$(ableton_reliable_audio_threads 8 16)" -eq 15 ] \
    || fail 'The reliability floor does not protect smaller SMT systems.'
for large_physical_count in 64 96 999999999999999999999999999999999999; do
    [ "$(ableton_reliable_audio_threads "$large_physical_count" 32)" -eq 31 ] \
        || fail "The automatic policy rejects positive physical core count $large_physical_count."
done
for invalid in 0 00 nope; do
    if ableton_reliable_audio_threads "$invalid" 32 >/dev/null 2>&1; then
        fail "The automatic policy accepts invalid physical core count $invalid."
    fi
done
ok 'The automatic formula covers every logical count from 1 to 32, accepts larger physical counts, preserves 16/31 and never cuts Live by more than half.'

prefix="$work/new"
prefs="$(make_prefs "$prefix")"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
[ "$(cat "$prefs/Options.txt")" = '-MaxAudioThreads=16' ] \
    || fail 'The new settings contain the requested count for audio threads.'
[ "$(stat -c '%a' "$prefs/Options.txt")" = 600 ] \
    || fail 'The new settings file uses mode 600.'
[ -f "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'The new settings directory contains the marker.'
ok 'A new settings directory receives the requested count for audio threads. The settings file uses mode 600. The directory contains the marker.'

ableton_seed_max_audio_threads "$prefix" 8 '' '' 0 >/dev/null
grep -qx -- '-MaxAudioThreads=16' "$prefs/Options.txt" \
    || fail 'The implicit automatic policy must keep an earlier launcher choice.'
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null
grep -qx -- '-MaxAudioThreads=8' "$prefs/Options.txt" \
    || fail 'An explicit request must replace an earlier launcher choice.'
ok 'The implicit automatic policy keeps an earlier choice. An explicit request replaces it.'

prefix="$work/off-owned"
prefs="$(make_prefs "$prefix")"
printf '%s\n' '-ExistingOption=yes' > "$prefs/Options.txt"
chmod 640 "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
ableton_seed_max_audio_threads "$prefix" off >/dev/null
! grep -q '^-MaxAudioThreads' "$prefs/Options.txt" \
    || fail 'The off policy removes the launcher-owned audio thread count.'
grep -qx -- '-ExistingOption=yes' "$prefs/Options.txt" \
    || fail 'The off policy preserves other Live options.'
[ ! -e "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'The off policy removes the ownership marker with its line.'
[ "$(stat -c '%a' "$prefs/Options.txt")" = 640 ] \
    || fail 'The off policy preserves the settings file mode.'
ok 'The off policy removes an owned count and marker while preserving other settings and the file mode.'

ableton_seed_max_audio_threads "$prefix" 8 >/dev/null
grep -qx -- '-MaxAudioThreads=8' "$prefs/Options.txt" \
    || fail 'A later explicit count applies after the off policy removed the old choice.'
getconf() { printf '64\n'; }
nproc() { printf '64\n'; }
ableton_seed_max_audio_threads "$prefix" 32 '' '' 1 1 >/dev/null
getconf() { printf '32\n'; }
nproc() { printf '32\n'; }
! grep -q '^-MaxAudioThreads' "$prefs/Options.txt" \
    && [ ! -e "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'An explicit automatic count at Live default restores Live selection.'
ok 'A later value can replace off, and explicit auto restores Live selection when no lower limit applies.'

prefix="$work/off-user-edit"
prefs="$(make_prefs "$prefix")"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
printf '%s\n' '-MaxAudioThreads=24' > "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" off >/dev/null
grep -qx -- '-MaxAudioThreads=24' "$prefs/Options.txt" \
    && [ -f "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail "The off policy preserves a user's later audio thread edit."
ok "The off policy preserves a user's later audio thread edit."

prefix="$work/off-record-fails"
prefs="$(make_prefs "$prefix")"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
rm()
{
    local target="${!#}"
    case "$target" in
        */.ableton-linux-max-audio-threads-v1) return 1 ;;
        *) command rm "$@" ;;
    esac
}
off_rc=0
ableton_seed_max_audio_threads "$prefix" off >/dev/null 2>&1 || off_rc=$?
unset -f rm
[ "$off_rc" -ne 0 ] \
    && grep -qx -- '-MaxAudioThreads=16' "$prefs/Options.txt" \
    && [ -f "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'A failed marker removal restores the owned audio thread line.'
ok 'A failed marker removal reports failure and restores the owned line.'

prefix="$work/new"
prefs="$(make_prefs "$prefix")"
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null
[ "$(grep -c '^-MaxAudioThreads=' "$prefs/Options.txt")" -eq 1 ] \
    || fail 'The settings file contains one entry for audio threads after repeated launches.'
printf '%s\n' '-UserChoice=keep' > "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
[ "$(cat "$prefs/Options.txt")" = '-UserChoice=keep' ] \
    || fail "The settings file retains the user's later edit."
ok "The settings file contains one entry for audio threads after repeated launches. The file retains the user's later edit."

prefix="$work/existing"
prefs="$(make_prefs "$prefix")"
printf '%s\r\n%s\r\n' '-MaxAudioThreads=24' '-AnotherOption=yes' > "$prefs/Options.txt"
chmod 640 "$prefs/Options.txt"
before="$(sha256sum "$prefs/Options.txt")"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
[ "$(sha256sum "$prefs/Options.txt")" = "$before" ] \
    || fail 'The custom settings file retains its original bytes.'
[ "$(stat -c '%a' "$prefs/Options.txt")" = 640 ] \
    || fail 'The custom settings file retains mode 640.'
ok 'The custom settings file retains its original bytes. The file retains mode 640.'

prefix="$work/append"
prefs="$(make_prefs "$prefix")"
printf '%s' '-ExistingOption=yes' > "$prefs/Options.txt"
chmod 644 "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null
grep -qx -- '-ExistingOption=yes' "$prefs/Options.txt" \
    || fail 'The existing setting retains its original text after the settings script adds a value.'
grep -qx -- '-MaxAudioThreads=8' "$prefs/Options.txt" \
    || fail 'The settings file contains the requested count for audio threads.'
[ "$(stat -c '%a' "$prefs/Options.txt")" = 644 ] \
    || fail 'The settings file retains mode 644 after the settings script adds a value.'
ok 'The settings script adds the requested count for audio threads. The existing text remains. The file retains mode 644.'

prefix="$work/multiple"
prefs_old="$(make_prefs "$prefix" 'Live 12.4.2')"
prefs_new="$(make_prefs "$prefix" 'Live 12.4.3')"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
grep -qx -- '-MaxAudioThreads=16' "$prefs_old/Options.txt" \
    && grep -qx -- '-MaxAudioThreads=16' "$prefs_new/Options.txt" \
    || fail 'Each Live version receives the requested count for audio threads.'
ok 'Each Live version receives the requested count for audio threads.'

prefix="$work/first-launch"
mkdir -p -- "$prefix/drive_c/users/test/AppData/Roaming"
live_exe="$work/Ableton Live 12 Suite.exe"
printf 'noiseP\0r\0o\0d\0u\0c\0t\0V\0e\0r\0s\0i\0o\0n\0\0\0' > "$live_exe"
printf 'noiseP\0r\0o\0d\0u\0c\0t\0V\0e\0r\0s\0i\0o\0n\0\0\0' >> "$live_exe"
printf '1\0002\000.\0005\000.\0001\000\000\000' >> "$live_exe"
ableton_seed_max_audio_threads "$prefix" 16 "$live_exe" test >/dev/null
prefs="$prefix/drive_c/users/test/AppData/Roaming/Ableton/Live 12.5.1/Preferences"
grep -qx -- '-MaxAudioThreads=16' "$prefs/Options.txt" \
    || fail 'The settings script reads the executable version. It creates the matching settings directory.'
ok 'The settings script reads the executable version. It creates the matching settings directory before Live starts.'

prefix="$work/low-cpu"
prefs="$(make_prefs "$prefix")"
getconf()
{
    printf '4\n'
}
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
[ ! -e "$prefs/Options.txt" ] && [ ! -e "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail "A computer with 4 processors retains the count that Live selects for audio threads."
getconf()
{
    printf '32\n'
}
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
unset -f getconf
getconf() { printf '32\n'; }
grep -qx -- '-MaxAudioThreads=16' "$prefs/Options.txt" \
    || fail 'A later launch with 32 processors applies the requested count for audio threads.'
ok 'A computer with 4 processors retains the count that Live selects for audio threads. A later launch with 32 processors applies the requested count.'

prefix="$work/temporary-affinity"
prefs="$(make_prefs "$prefix")"
getconf() { printf '32\n'; }
nproc() { printf '4\n'; }
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
[ ! -e "$prefs/Options.txt" ] && [ ! -e "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'A temporary limit of 4 processors retains the count that Live selects for audio threads.'
nproc() { printf '32\n'; }
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
getconf() { printf '32\n'; }
nproc() { printf '32\n'; }
grep -qx -- '-MaxAudioThreads=16' "$prefs/Options.txt" \
    || fail 'A later launch with 32 processors applies the requested count for audio threads.'
ok 'A temporary limit of 4 processors retains the count that Live selects for audio threads. A later launch with 32 processors applies the requested count.'

prefix="$work/point-update"
old_prefs="$(make_prefs "$prefix" 'Live 12.4.3')"
live_exe="$work/Ableton Live 12 Updated.exe"
printf 'P\0r\0o\0d\0u\0c\0t\0V\0e\0r\0s\0i\0o\0n\0\0\0' > "$live_exe"
printf '1\0002\000.\0005\000.\0002\000\000\000' >> "$live_exe"
ableton_seed_max_audio_threads "$prefix" 16 "$live_exe" test >/dev/null
[ ! -e "$prefix/drive_c/users/test/AppData/Roaming/Ableton/Live 12.5.2" ] \
    || fail 'The settings script waits for Live to create the updated version directory.'
[ ! -e "$old_prefs/Options.txt" ] || fail 'The previous Live version retains its existing settings.'
mkdir -p -- "$prefix/drive_c/users/test/AppData/Roaming/Ableton/Live 12.5.2"
ableton_seed_max_audio_threads "$prefix" 16 "$live_exe" test >/dev/null
[ ! -e "$prefix/drive_c/users/test/AppData/Roaming/Ableton/Live 12.5.2/Preferences" ] \
    || fail 'The settings script waits for Live to create the settings directory.'
new_prefs="$(make_prefs "$prefix" 'Live 12.5.2')"
ableton_seed_max_audio_threads "$prefix" 16 "$live_exe" test >/dev/null
grep -qx -- '-MaxAudioThreads=16' "$new_prefs/Options.txt" \
    || fail 'The next launch adds the requested count to the settings directory that Live created.'
[ ! -e "$old_prefs/Options.txt" ] || fail 'The previous Live version retains its existing settings.'
ok 'Live creates the updated version directory. The next launch adds the requested count for audio threads.'

prefix="$work/live-11"
prefs="$(make_prefs "$prefix")"
live_exe="$work/Ableton Live 11 Suite.exe"
printf 'P\0r\0o\0d\0u\0c\0t\0V\0e\0r\0s\0i\0o\0n\0\0\0' > "$live_exe"
printf '1\0001\000.\0003\000.\0004\000\000\000' >> "$live_exe"
ableton_seed_max_audio_threads "$prefix" 16 "$live_exe" test >/dev/null
[ ! -e "$prefs/Options.txt" ] && [ ! -e "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'A Live 11 launch preserves the settings for Live 12.'
! shopt -q nullglob || fail "A Live 11 launch preserves the launcher's shell settings."
ok "A Live 11 launch preserves the settings for Live 12. It preserves the launcher's shell settings."

prefix="$work/update-opt-out"
old_prefs="$(make_prefs "$prefix" 'Live 12.4.3')"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
printf '%s\n' '-UserChoice=keep' > "$old_prefs/Options.txt"
new_prefs="$(make_prefs "$prefix" 'Live 12.5.0')"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
[ "$(cat "$new_prefs/Options.txt" 2>/dev/null || true)" != '-MaxAudioThreads=16' ] \
    || fail "A version update preserves the user's choice to let Live select the audio thread count."
[ -f "$new_prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail "The updated settings record the user's choice to let Live select the audio thread count."
ok "The user's choice to let Live select the audio thread count continues across version updates."

prefix="$work/update-custom"
old_prefs="$(make_prefs "$prefix" 'Live 12.4.3')"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
printf '%s\n' '-MaxAudioThreads=8' > "$old_prefs/Options.txt"
new_prefs="$(make_prefs "$prefix" 'Live 12.5.0')"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
grep -qx -- '-MaxAudioThreads=8' "$new_prefs/Options.txt" \
    || fail "A version update preserves the user's count of 8 audio threads."
ok "The user's count of 8 audio threads continues across version updates."

prefix="$work/unsafe-option"
prefs="$(make_prefs "$prefix")"
outside="$work/outside-options"
printf '%s\n' 'original text' > "$outside"
ln -s -- "$outside" "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null 2>&1
[ "$(cat "$outside")" = 'original text' ] \
    || fail 'The linked settings file retains its original text.'
[ ! -e "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'The settings directory contains one entry. The entry is the original symbolic link.'
ok 'The linked settings file retains its original text. The settings directory contains one entry. The entry is the original symbolic link.'

prefix="$work/unsafe-parent"
mkdir -p -- "$prefix/drive_c/users/test/AppData/Roaming/Ableton" "$work/outside-prefs/Preferences"
ln -s -- "$work/outside-prefs" \
    "$prefix/drive_c/users/test/AppData/Roaming/Ableton/Live 12.4.3"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null 2>&1
[ ! -e "$work/outside-prefs/Preferences/Options.txt" ] \
    || fail 'Every settings write stays within the Wine prefix.'
ok 'Every settings write stays within the Wine prefix.'

prefix="$work/unsafe-users"
mkdir -p -- "$prefix/drive_c" "$work/outside-users/test/AppData/Roaming/Ableton/Live 12.4.3/Preferences"
ln -s -- "$work/outside-users" "$prefix/drive_c/users"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null 2>&1
[ ! -e "$work/outside-users/test/AppData/Roaming/Ableton/Live 12.4.3/Preferences/Options.txt" ] \
    || fail 'Every user settings write stays within the Wine prefix.'
ok 'Every user settings write stays within the Wine prefix.'

prefix="$work/race-write"
prefs="$(make_prefs "$prefix")"
race_saved="$work/race-write-saved"
race_outside="$work/race-write-outside"
mkdir -p -- "$race_outside"
printf '%s\n' untouched > "$race_outside/sentinel"
race_flag="$work/race-write-triggered"
mktemp()
{
    if [[ "${1:-}" == /proc/*/fd/*/.Options.txt.* ]] && [ ! -e "$race_flag" ]; then
        : > "$race_flag"
        command mv -- "$prefs" "$race_saved"
        command ln -s -- "$race_outside" "$prefs"
    fi
    command mktemp "$@"
}
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
unset -f mktemp
[ -L "$prefs" ] && [ -d "$race_saved" ] \
    || fail 'The test replaces the settings directory during file creation.'
[ "$(cat "$race_outside/sentinel")" = untouched ] \
    && [ ! -e "$race_outside/Options.txt" ] \
    && [ ! -e "$race_outside/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'The external directory contains one file. The file retains its original text.'
grep -qx -- '-MaxAudioThreads=16' "$race_saved/Options.txt" \
    && [ -f "$race_saved/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'The original settings directory receives the audio thread entry and marker.'
ok 'The settings script writes both files to the original settings directory during directory replacement.'

prefix="$work/race-create"
mkdir -p -- "$prefix/drive_c/users/test/AppData/Roaming"
live_exe="$work/Ableton Live 12 Fresh Race.exe"
printf 'P\0r\0o\0d\0u\0c\0t\0V\0e\0r\0s\0i\0o\0n\0\0\0' > "$live_exe"
printf '1\0002\000.\0006\000.\0000\000\000\000' >> "$live_exe"
race_roaming="$prefix/drive_c/users/test/AppData/Roaming"
race_saved="$work/race-create-saved"
race_outside="$work/race-create-outside"
mkdir -p -- "$race_outside"
race_triggered=0
mkdir()
{
    mkdir_target="${!#}"
    if [[ "$mkdir_target" == /proc/*/fd/*/Ableton ]] && [ "$race_triggered" -eq 0 ]; then
        race_triggered=1
        command mv -- "$race_roaming" "$race_saved"
        command ln -s -- "$race_outside" "$race_roaming"
    fi
    command mkdir "$@"
}
ableton_seed_max_audio_threads "$prefix" 16 "$live_exe" test >/dev/null
unset -f mkdir
[ -L "$race_roaming" ] && [ -d "$race_saved" ] \
    || fail 'The test replaces the parent directory while the script creates Live settings.'
[ ! -e "$race_outside/Ableton" ] \
    || fail 'The original parent remains the destination for new Live settings.'
[ -d "$race_saved/Ableton/Live 12.6.0/Preferences" ] \
    || fail 'The original parent directory receives the new settings for Live.'
ok 'The settings script writes new Live settings to the original parent during directory replacement.'

prefix="$work/invalid"
prefs="$(make_prefs "$prefix")"
for value in 0 00 064 64 nope 999999999999999999999999999999999999; do
    if ableton_seed_max_audio_threads "$prefix" "$value" >/dev/null 2>&1; then
        fail "Use a number from one to 63 for the audio thread count. The test received $value."
    fi
done
[ ! -e "$prefs/Options.txt" ] && [ ! -e "$prefs/.ableton-linux-max-audio-threads-v1" ] \
    || fail 'The tested values outside one to 63 preserve the initial Live settings.'
ok 'The tested values outside one to 63 preserve the initial Live settings.'

prefix="$work/change-count"
prefs="$(make_prefs "$prefix")"
printf '%s\n' '-ExistingOption=yes' > "$prefs/Options.txt"
chmod 644 "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null
grep -qx -- '-MaxAudioThreads=8' "$prefs/Options.txt" \
    || fail 'A later launch applies a different count for audio threads.'
[ "$(grep -c '^-MaxAudioThreads=' "$prefs/Options.txt")" -eq 1 ] \
    || fail 'The settings file contains one entry for audio threads after a changed count.'
grep -qx -- '-ExistingOption=yes' "$prefs/Options.txt" \
    || fail 'A changed count retains the other settings in the file.'
[ "$(stat -c '%a' "$prefs/Options.txt")" = 644 ] \
    || fail 'A changed count retains the mode of the settings file.'
ok 'A later launch applies a different count for audio threads. It retains the other settings and the file mode.'

printf '%s\n' '-MaxAudioThreads=24' > "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null
[ "$(cat "$prefs/Options.txt")" = '-MaxAudioThreads=24' ] \
    || fail "A later launch retains the user's own count for audio threads."
printf '\n' > "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null
[ -z "$(tr -d '[:space:]' < "$prefs/Options.txt")" ] \
    || fail "A later launch retains the user's choice to let Live select the count."
ok "A later launch retains the user's own count. It retains the user's choice to let Live select the count."

prefix="$work/rewrite-swap"
prefs="$(make_prefs "$prefix")"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
outside="$work/rewrite-swap-outside"
printf '%s\n' '-MaxAudioThreads=16' > "$outside"
outside_before="$(stat -c '%i:%s' "$outside")"
swap_flag="$work/rewrite-swap-fired"
mktemp()
{
    if [[ "${1:-}" == /proc/*/fd/*/.Options.txt.* ]] && [ ! -e "$swap_flag" ]; then
        : > "$swap_flag"
        command rm -f -- "$prefs/Options.txt"
        command ln -s -- "$outside" "$prefs/Options.txt"
    fi
    command mktemp "$@"
}
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null 2>&1 || true
unset -f mktemp
[ -e "$swap_flag" ] || fail 'The test replaces the settings file during the rewrite.'
# Content alone cannot show this: the replacement holds no line the rewrite
# matches, so a write that followed the name would copy the same bytes back.
[ "$(stat -c '%i:%s' "$outside")" = "$outside_before" ] \
    && [ "$(cat "$outside")" = '-MaxAudioThreads=16' ] \
    || fail 'A settings file replaced during the rewrite keeps every write inside the Wine prefix.'
ok 'A settings file replaced during the rewrite keeps every write inside the Wine prefix.'

prefix="$work/rewrite-record-fails"
prefs="$(make_prefs "$prefix")"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
mv() { return 1; }
record_rc=0
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null 2>&1 || record_rc=$?
unset -f mv
[ "$record_rc" -ne 0 ] \
    || fail 'A settings script that cannot record the choice reports the failure.'
[ "$(tr -d '\n' < "$prefs/Options.txt")" \
    = "$(sed -n '2s/^default=//p' "$prefs/.ableton-linux-max-audio-threads-v1")" ] \
    || fail 'The settings file and the recorded choice hold the same count.'
ableton_seed_max_audio_threads "$prefix" 4 >/dev/null
grep -qx -- '-MaxAudioThreads=4' "$prefs/Options.txt" \
    || fail 'A later launch applies a count after a failed record.'
ok 'A failed record reports the failure, leaves one count in both files, and a later launch still applies.'

prefix="$work/rewrite-duplicate"
prefs="$(make_prefs "$prefix")"
ableton_seed_max_audio_threads "$prefix" 8 >/dev/null
printf '%s\n%s\n' '-MaxAudioThreads=8' '-MaxAudioThreads=24' > "$prefs/Options.txt"
ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
[ "$(grep -c '^-MaxAudioThreads=' "$prefs/Options.txt")" -eq 2 ] \
    && grep -qx -- '-MaxAudioThreads=8' "$prefs/Options.txt" \
    && grep -qx -- '-MaxAudioThreads=24' "$prefs/Options.txt" \
    || fail "A second count the user added declines the rewrite."
ok "A second count the user added declines the rewrite and leaves the file unchanged."

ableton_seed_max_audio_threads "$work/missing-prefix" 16 >/dev/null
ok 'The settings script accepts a partial Wine prefix.'

printf 'PASS: %d audio thread setting checks\n' "$pass"
