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

ableton_seed_max_audio_threads "$prefix" 16 >/dev/null
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

ableton_seed_max_audio_threads "$work/missing-prefix" 16 >/dev/null
ok 'The settings script accepts a partial Wine prefix.'

printf 'PASS: %d audio thread setting checks\n' "$pass"
