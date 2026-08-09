#!/usr/bin/env bash
# Does a real machine in the shipped layout end up correct in ~/works?
#
# Runs on a guest with two kits beside it: the published release (flat layout,
# what every user has today) and the candidate. Installs the first, asserts the
# old world exists, installs the second over it, then asserts the new one -
# including that the prefix arrived with its contents intact, which is the part
# no amount of reading proves.
set -uo pipefail
cd "$(dirname "$0")"

OLD=install-ableton-latest.run
NEW=$(ls -1 ableton-wine-setup-*.run | head -1)
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

echo "== [1/4] install the published release (the layout every user has) =="
sh "$OLD" --runtime-only >/tmp/old-install.log 2>&1 || {
    echo "!! the released kit failed to install"; tail -20 /tmp/old-install.log; exit 1; }

# A prefix, made the way the old world made it. Kept small on purpose: this
# test is about relocation, and a full winetricks prefix would take twenty
# minutes to prove the same rename. The marker file is what must survive.
mkdir -p "$HOME/.wine-ableton/drive_c/users/$USER/Documents" "$HOME/.wine-ableton/dosdevices"
: > "$HOME/.wine-ableton/system.reg"
ln -sfn ../drive_c "$HOME/.wine-ableton/dosdevices/c:"
ln -sfn "$HOME/Documents" "$HOME/.wine-ableton/drive_c/users/$USER/Documents-host"
printf 'the user work that must not be lost\n' > "$HOME/.wine-ableton/drive_c/users/$USER/my-set.als"

echo "-- the old world, before migrating:"
check "flat runtime at the legacy path"      '[ -d "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]'
check "prefix at the legacy path"            '[ -d "$HOME/.wine-ableton" ]'
check "no ~/works yet"                       '[ ! -e "$HOME/works" ]'

echo
echo "== [2/4] install the candidate over it =="
sh "$NEW" --runtime-only >/tmp/new-install.log 2>&1 || {
    echo "!! the candidate failed to install"; tail -30 /tmp/new-install.log; exit 1; }
grep -E '^   (layout|plug):' /tmp/new-install.log | sed 's/^/  /'

echo
echo "== [3/4] the new world =="
store="$HOME/works/runtimes"
# Two builds is the right answer, not one: the release migrated in and the one
# just installed are different builds of the same version, and keeping the old
# one is exactly what makes rollback possible.
entry="$store/$(readlink "$store/stable")"
count=$(find "$store" -maxdepth 1 -mindepth 1 -type d | wc -l)
check "the store exists"                     '[ -d "$store" ]'
check "the migrated build was kept beside the new one" '[ "$count" = 2 ]' 
check "the build is named <version>+<commit>" '[[ "$(basename "$entry")" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+\+ ]]'
check "stable points at the build just installed" '[ -d "$entry" ] && grep -q "$(basename "$entry")" /tmp/new-install.log' 
check "the runtime executes"                 '"$entry/bin/wine" --version'
check "the legacy runtime path is gone"      '[ ! -e "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]'

plug="$HOME/works/plugs/studio"
check "the prefix became a Plug"             '[ -d "$plug" ]'
check "the legacy prefix path is gone"       '[ ! -e "$HOME/.wine-ableton" ]'
check "the user's work survived"             '[ "$(cat "$plug/drive_c/users/$USER/my-set.als")" = "the user work that must not be lost" ]'
check "dosdevices/c: still resolves"         '[ "$(readlink "$plug/dosdevices/c:")" = "../drive_c" ]'
check "the outward symlink still resolves"   '[ -d "$plug/drive_c/users/$USER/Documents-host" ]'

check "the shared toolkit is in lib/"        '[ -r "$HOME/works/lib/runtime-env.sh" ]'
check "Ableton's payload is in apps/"        '[ -x "$HOME/works/apps/ableton-live/ableton-linkd" ]'
check "the launcher is on PATH"              '[ -x "$HOME/.local/bin/ableton-live" ]'
check "the launcher resolves the new store"  'grep -q works "$HOME/.local/bin/ableton-live"'

echo
echo "== [4/4] re-running the installer is a no-op, not a second migration =="
sh "$NEW" --runtime-only >/tmp/rerun.log 2>&1
check "no third entry appeared"              '[ "$(find "$store" -maxdepth 1 -mindepth 1 -type d | wc -l)" = "$count" ]' 
check "the Plug is untouched"                '[ "$(cat "$plug/drive_c/users/$USER/my-set.als")" = "the user work that must not be lost" ]'
check "no stray prefix reappeared"           '[ ! -e "$HOME/.wine-ableton" ]'

echo
echo "== $pass passed, $fail failed on $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}") =="
[ "$fail" -eq 0 ]
