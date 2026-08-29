#!/usr/bin/env bash
# Renderer checks for scripts/lib/ui.sh: the installer's nested tree, its
# dictionary, the live └─/├─ flip, wrapping, prompts, footer, and the lints
# that keep every other script out of the rendering business.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ui_lib="$here/lib/ui.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/ableton-ui-test.XXXXXX")"
trap 'if [ "${ABLETON_KEEP_TEST_WORK:-0}" -eq 0 ]; then rm -rf -- "$work"; else printf "kept test work: %s\n" "$work" >&2; fi' EXIT
pass=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

command -v script >/dev/null 2>&1 || fail "script(1) from util-linux is available for the terminal checks"
[ -r "$ui_lib" ] || fail "scripts/lib/ui.sh exists"
mkdir -p "$work/home"
wrapper_bin="$work/wrapper-bin"
mkdir -p -- "$wrapper_bin"
cat > "$wrapper_bin/pgrep" <<'EOF'
#!/bin/sh
[ "$*" = '-x wineserver' ] || exit 2
exit 1
EOF
cat > "$wrapper_bin/pkill" <<'EOF'
#!/bin/sh
printf 'unexpected pkill from installer-ui wrapper test\n' >&2
exit 97
EOF
chmod +x "$wrapper_bin/pgrep" "$wrapper_bin/pkill"

# A fixed environment: no inherited terminal, width, charset, or timeout.
run_static()
{
    env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm \
        COLUMNS=80 ABLETON_UI_ACTION=install ABLETON_UI_KIT=1 \
        ABLETON_UI_PROMPT_TIMEOUT=5 UI_LIB="$ui_lib" "$@"
}

# A real pseudo-terminal. script(1) keeps running until its stdin closes, so
# the feed stays open and silent until the fixture's last line ($marker)
# appears in $out, then closes; keys, when given, are typed first.
# $out receives the raw byte stream the terminal received, escapes included.
done_marker='@@DONE@@'
feed()
{
    local out="$1" marker="$2" keys="${3:-}" i=0
    [ -z "$keys" ] || printf '%s' "$keys"
    until grep -aq "$marker" "$out" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ "$i" -lt 900 ] || break
    done
}
run_pty_raw()
{
    local rows="$1" cols="$2" out="$3"; shift 3
    : > "$out"
    env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work" LANG=C.UTF-8 TERM="${PTY_TERM:-xterm}" \
        SHELL=/bin/bash ABLETON_UI_ACTION=install ABLETON_UI_KIT=1 ABLETON_UI_PROMPT_TIMEOUT=1 \
        FIXTURE_TTY=1 FIXTURE_SLEEP="${FIXTURE_SLEEP:-0}" \
        FIXTURE_ITEM_SLEEP="${FIXTURE_ITEM_SLEEP:-0}" \
        FIXTURE_DETAIL_SLEEP="${FIXTURE_DETAIL_SLEEP:-0}" UI_LIB="$ui_lib" \
        script -qfec "stty rows $rows cols $cols; $*; echo $done_marker" /dev/null \
        < <(feed "$out" "$done_marker") > "$out" 2>&1 || true
}

# Terminal simulator: replays the few sequences emitted by ui.sh and counts
# cursor columns as Unicode code points without relying on host awk behavior.
cat > "$work/vt.py" <<'PY'
import re
import sys

data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
visibility = re.compile(r"\x1b\[\?[0-9]+[hl]")
sgr = re.compile(r"\x1b\[[0-9;]*m")
cursor = re.compile(r"\x1b\[([0-9]*)([ABCK])")
screen = {}
row = column = 0
rows = 1
i = 0

while i < len(data):
    char = data[i]
    if char == "\r":
        column = 0
        i += 1
        continue
    if char == "\n":
        row += 1
        column = 0
        rows = max(rows, row + 1)
        i += 1
        continue
    if char == "\x1b":
        match = visibility.match(data, i) or sgr.match(data, i)
        if match:
            i = match.end()
            continue
        if data.startswith("\x1b]", i):
            stop = data.find("\x1b\\", i + 2)
            if stop >= 0:
                i = stop + 2
                continue
        match = cursor.match(data, i)
        if match:
            count = int(match.group(1) or 1)
            command = match.group(2)
            if command == "A":
                row = max(0, row - count)
            elif command == "B":
                row += count
                rows = max(rows, row + 1)
            elif command == "C":
                column += count
            else:
                line = screen.setdefault(row, [])
                if match.group(1) == "2":
                    line.clear()
                else:
                    del line[column:]
            i = match.end()
            continue
        i += 1
        continue
    line = screen.setdefault(row, [])
    line.extend(" " for _ in range(column - len(line)))
    if column == len(line):
        line.append(char)
    else:
        line[column] = char
    column += 1
    i += 1

for row in range(rows):
    print("".join(screen.get(row, [])))
PY
vt() { LC_ALL=C.UTF-8 python3 "$work/vt.py" "$1" | grep -v "^$done_marker" | sed -e 's/[[:space:]]*$//' -e '${/^$/d}'; }

# Cursor columns count Unicode code points, not UTF-8 bytes. This regression
# catches byte-oriented replay before the full PTY checks.
printf '│  X\r\033[3C│\n' > "$work/vt-unicode.raw"
vt "$work/vt-unicode.raw" > "$work/vt-unicode.screen"
grep -qxF '│  │' "$work/vt-unicode.screen" \
    || fail "the terminal simulator moves across Unicode code points"
ok "the terminal simulator counts Unicode glyphs as one column"

frames="$(bash -c '. "$1"; printf "%s" "${UI_TEXT[g_spinner]}"' _ "$ui_lib" | tr -d ' ')"
[ -n "$frames" ] || fail "the dictionary defines the spinner frames"
has_frame() { grep -q "[$frames]" "$1"; }

cat > "$work/fixture-golden.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${FIXTURE_TTY:-}" ] || { exec 7>&1; export ABLETON_UI_TTY_FD=7; }
. "${UI_LIB:?}"
ui_banner '2026.08.28.1'
ui_blank; ui_heading h_system; ui_blank
ui_row r_date '28/08/2026, 11:42:56 CEST'
ui_row r_deps "$(ui_text v_deps_ready 'bash timeout tar zstd sha256sum')"
ui_blank; ui_heading h_warnings; ui_blank
if [ -n "${FIXTURE_WARN:-}" ]; then ui_host_warning w_missing_command tar; else ui_note w_none; fi
ui_blank; ui_heading h_action; ui_blank
ui_menu_option m_update default
ui_menu_option m_reinstall
ui_menu_option m_remove
ui_menu_option m_quit
ui_blank
ui_step_begin s_validate
ui_item_begin i_copy
sleep "${FIXTURE_ITEM_SLEEP:-0}"
ui_status i_copy_done 482
sleep "${FIXTURE_DETAIL_SLEEP:-0}"
ui_item_end ok
ui_item_begin i_check
ui_status i_check_done
ui_info w_home_small
ui_warn w_not_x86_64
ui_item_end fail
ui_step_end fail
ui_step_begin s_runtime_install
ui_run i_extract -- sleep "${FIXTURE_SLEEP:-0}"
ui_question q_overwrite_title o q_overwrite_all q_keep q_abort
ui_step_end ok
ui_footer "$(ui_text label_update)" '2026.08.28.1' complete 109 0 0 \
    /home/theo/.local/opt/wine-d2d1-nspa-11.13 /home/theo/.wine-ableton
ui_tail complete '~/Downloads/ableton-linux-installer-x.log'
EOF
chmod +x "$work/fixture-golden.sh"

# The golden is the template rendered for one fixed run. It is literal on
# purpose: a dictionary or layout edit must change this text deliberately.
# The live cursor leaves one space between the question prompt and input.
cat > "$work/golden-static.txt" <<'EOF'
╒══════════════════════════╤═════════════════╕
│  ABLETON-LINUX INSTALLER ┊ v 2026.08.28.1  │
├┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┴┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┤
│  https://github.com/shibco/ableton-linux/  │
╞════════════════════════════════════════════╛
│
│ System Check
│
│  Date and time  28/08/2026, 11:42:56 CEST
│  Dependencies   bash timeout tar zstd sha256sum (ready)
│
│ Warnings
│
│  No host warnings found.
│
│ Ableton-Linux Installer Choice:
│
│  > [U]pdate (or press Enter)
│  > [R]einstall
│  > Remo[v]e Ableton Linux
│  > [Q]uit
│
├──┲━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
│  ┃ 2/8 ╏ CHECK THE HOST AND THE REQUEST ┃
│  ┡━━━━━┻━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
│  │
│  ├─ Copy the embedded kit
│  │  > Copied 482 MiB.
│  │  ✓ Done.
│  │
│  ├─ Check the embedded kit
│  │  > The kit is intact.
│  │
│  │  🛈 Less than 10 GiB is free for the Wine runtime, the ableton-linux
│  │    prefix, and Live.
│  │
│  │  ⚠ Ableton Linux currently requires an x86_64 host.
│  │  𐄂 Failed.
│  │
│  └─ Step 2 Failed! 𐄂
│
├──┲━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━┓
│  ┃ 3/8 ╏ INSTALL THE WINE RUNTIME ┃
│  ┡━━━━━┻━━━━━━━━━━━━━━━━━━━━━━━━━━┛
│  │
│  ├─ Extract the embedded kit ✓
│  │
│  ├─ FILES FROM AN EARLIER INSTALLATION ALREADY EXIST
│  │
│  │  > [O]verwrite all (Default)
│  │  > [K]eep originals
│  │  > [A]bort
│  │
│  │  (Press Enter for default or wait 5 seconds)
│  │  Please choose [O/K/A]:
│  │
│  └─ Step 3 Complete! ✓
│
╞══════════════════════════════════════════╤══════════╕
│ Ableton-Linux Update v. 2026.08.28.1     │ Complete │
├──────────────────────────────────────────┼──────────┤
│ Time taken:                              │  109 sec │
├┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┼┈┈┈┈┈┈┈┈┈┈┤
│ Warnings:                                │        0 │
├┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┼┈┈┈┈┈┈┈┈┈┈┤
│ Errors:                                  │        0 │
├┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┴┈┈┈┈┈┈┈┈┈┈┤
│ runtime: /home/theo/.local/opt/wine-d2d1-nspa-11.13 │
│ ableton-linux prefix: /home/theo/.wine-ableton      │
╘═════════════════════════════════════════════════════╛

Launch Ableton Live via your desktop applications launcher or in the terminal:

  > $ ableton-live

Stay up to date:
  https://bsky.app/profile/wires.sh

Ableton on Linux Discord:
  https://discord.gg/XD5EeZyP3

Need help?
  https://github.com/shibco/ableton-linux

Saved a log of this operation at
  ~/Downloads/ableton-linux-installer-x.log
EOF
grep -q '^│  │  Please choose \[O/K/A\]:$' "$work/golden-static.txt" \
    || fail "the golden keeps the question prompt"

# T1: static rendering is byte for byte the template.
run_static bash "$work/fixture-golden.sh" < /dev/null > "$work/static.out" 2> "$work/static.err" \
    || fail "the static golden fixture ran (stderr: $(head -c 300 "$work/static.err"))"
if ! cmp -s "$work/static.out" "$work/golden-static.txt"; then
    diff -u "$work/golden-static.txt" "$work/static.out" | head -40 >&2 || true
    fail "static rendering matches the template golden"
fi
FIXTURE_WARN=1 run_static env FIXTURE_WARN=1 bash "$work/fixture-golden.sh" < /dev/null > "$work/static-warn.out" 2>&1 \
    || fail "the host-warning fixture ran"
grep -qxF '│  ⚠ Required command is missing: tar.' "$work/static-warn.out" \
    || fail "a host warning is rendered on the trunk"
ok "static rendering matches the template golden byte for byte"

# Every pair of adjacent box-drawing glyphs must agree about both the
# direction and weight of their shared stroke. This covers the light nested
# tree, the light/heavy step junctions, and the single/double banner and
# footer junctions. It catches a visually broken line even if the same wrong
# glyph was copied into the literal golden transcript.
python3 - "$work/static.out" <<'PY' || fail "every box-drawing junction connects with the matching weight"
import sys

paths = {
    "╒": {"R": 3, "D": 1}, "═": {"L": 3, "R": 3}, "╤": {"L": 3, "R": 3, "D": 1},
    "╕": {"L": 3, "D": 1}, "│": {"U": 1, "D": 1}, "┊": {"U": 1, "D": 1},
    "├": {"U": 1, "D": 1, "R": 1}, "┈": {"L": 1, "R": 1},
    "┴": {"U": 1, "L": 1, "R": 1}, "┤": {"U": 1, "D": 1, "L": 1},
    "╞": {"U": 1, "D": 1, "R": 3}, "╛": {"U": 1, "L": 3},
    "─": {"L": 1, "R": 1}, "┲": {"L": 1, "R": 2, "D": 2},
    "━": {"L": 2, "R": 2}, "┳": {"L": 2, "R": 2, "D": 2},
    "┓": {"L": 2, "D": 2}, "┃": {"U": 2, "D": 2}, "╏": {"U": 2, "D": 2},
    "┡": {"U": 2, "R": 2, "D": 1}, "┻": {"U": 2, "L": 2, "R": 2},
    "┛": {"U": 2, "L": 2}, "└": {"U": 1, "R": 1},
    "┼": {"U": 1, "D": 1, "L": 1, "R": 1}, "╘": {"U": 1, "R": 3},
}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
used = {char for line in lines for char in line if 0x2500 <= ord(char) <= 0x257F}
if unknown := used - paths.keys():
    raise SystemExit(f"unmapped box-drawing glyphs: {''.join(sorted(unknown))}")
for row, line in enumerate(lines):
    for col, char in enumerate(line):
        if char not in paths:
            continue
        for dx, dy, outgoing, incoming in ((1, 0, "R", "L"), (0, 1, "D", "U")):
            if row + dy >= len(lines) or col + dx >= len(lines[row + dy]):
                continue
            neighbour = lines[row + dy][col + dx]
            if neighbour not in paths:
                continue
            left = paths[char].get(outgoing)
            right = paths[neighbour].get(incoming)
            if left != right:
                raise SystemExit(
                    f"broken junction at {row + 1}:{col + 1}: {char}{neighbour} ({left} != {right})"
                )
PY
ok "every adjacent box-drawing stroke has matching direction and weight"

# T4: static output never animates or moves the cursor.
! LC_ALL=C grep -q $'\033\\[' "$work/static.out" || fail "static output contains no cursor sequences"
! LC_ALL=C grep -q $'\r' "$work/static.out" || fail "static output contains no carriage returns"
! has_frame "$work/static.out" || fail "static output contains no spinner frames"
run_static bash -c 'before="$(trap -p)"; . "$UI_LIB"; after="$(trap -p)"; [ "$before" = "$after" ]' \
    < /dev/null > "$work/traps.out" 2>&1 || fail "ui.sh preserves the inherited trap state"
[ ! -s "$work/traps.out" ] || fail "ui.sh installs no traps of its own"
! grep -qw 'tput\|flock' "$ui_lib" || fail "ui.sh uses neither tput nor flock"
ok "static output has no escapes, no frames, and ui.sh sets no traps"

# T3: on a terminal the same fixture ends on the same screen, every settled
# item as ├─ with its mark on the title, and the raw stream proves the item
# was └─ first and its details were rewritten with it. The settled rewrite is
# immediate: no completed title or detail remains in the temporary last-child
# form while the caller moves on to the rest of the step.
FIXTURE_SLEEP=1.5 FIXTURE_ITEM_SLEEP=1.5 FIXTURE_DETAIL_SLEEP=1.5 \
    run_pty_raw 40 80 "$work/live.raw" bash "$work/fixture-golden.sh"
vt "$work/live.raw" > "$work/live.screen"
sed -e '/^│  │  ✓ Done\.$/d' -e '/^│  │  𐄂 Failed\.$/d' \
    -e 's/^│  ├─ Copy the embedded kit$/│  ├─ Copy the embedded kit ✓/' \
    -e 's/^│  ├─ Check the embedded kit$/│  ├─ Check the embedded kit 𐄂/' \
    -e 's/wait 5 seconds/wait 1 seconds/' \
    "$work/golden-static.txt" | sed -e 's/[[:space:]]*$//' > "$work/golden-live.txt"
if ! cmp -s "$work/live.screen" "$work/golden-live.txt"; then
    diff -u "$work/golden-live.txt" "$work/live.screen" | head -40 >&2 || true
    fail "the live screen ends as the template golden"
fi
first_last="$(LC_ALL=C grep -abo $'└─ \033\[96mCopy the embedded kit' "$work/live.raw" | head -1 | cut -d: -f1)"
first_settled="$(LC_ALL=C grep -abo $'├─ \033\[36mCopy the embedded kit ✓' "$work/live.raw" | head -1 | cut -d: -f1)"
[ -n "$first_last" ] && [ -n "$first_settled" ] && [ "$first_last" -lt "$first_settled" ] \
    || fail "an item is drawn └─ first and rewritten to ├─ when it completes"
LC_ALL=C grep -q $'│     \033\[96m> Copied 482 MiB\.' "$work/live.raw" \
    || fail "details under the last item use a blank sub-trunk before the flip"
LC_ALL=C grep -q $'\033\\[2K│  ├─ \033\\[36mCopy the embedded kit ✓\033\\[0m' "$work/live.raw" \
    || fail "a completed title settles immediately and only its text is coloured"
LC_ALL=C grep -q $'\033\\[3C│' "$work/live.raw" \
    || fail "a completed detail gains its missing sub-trunk immediately"
has_frame "$work/live.raw" || fail "a running ui_run shows spinner frames"
[ "$(LC_ALL=C grep -o $'\r\033\\[2K│  └─ \033\\[96mCopy the embedded kit' "$work/live.raw" | wc -l)" -ge 2 ] \
    || fail "an ordinary active item shows spinner frames"
[ "$(LC_ALL=C grep -o $'\r\033\\[2K│     \033\\[96m' "$work/live.raw" | wc -l)" -ge 2 ] \
    || fail "the spinner remains active after an item prints status text"
[ "$(LC_ALL=C grep -o $'\r\033\\[2K│  └─ \033\\[96mExtract the embedded kit' "$work/live.raw" | wc -l)" -ge 2 ] \
    || fail "the spinner redraws the running title in place"
LC_ALL=C grep -q $'\033\\[96m' "$work/live.raw" || fail "active work uses the bright primary colour"
LC_ALL=C grep -q $'\033\\[36m' "$work/live.raw" || fail "completed work uses the darker history colour"
LC_ALL=C grep -q $'\033\\[91m' "$work/live.raw" || fail "failed work stays bright red"
LC_ALL=C grep -q $'\033\\[93m' "$work/live.raw" || fail "warnings and prompts stay bright yellow"
LC_ALL=C grep -Fq $'\033]8;;https://github.com/shibco/ableton-linux/\033\\https://github.com/shibco/ableton-linux/\033]8;;\033\\' \
    "$work/live.raw" || fail "displayed web addresses use terminal hyperlinks"
! LC_ALL=C grep -q $'\033\\[s\\|\0337\\|\033\\[u\\|\0338' "$work/live.raw" \
    || fail "the renderer never uses cursor save or restore"
LC_ALL=C grep -q $'\033\\[?25h' "$work/live.raw" || fail "the cursor is shown again after the spinner"
# Inspect every SGR span, including transient spinner and rewrite frames. A
# Unicode box-drawing code point inside a non-default foreground span means a
# structural line was coloured along with its text.
python3 - "$work/live.raw" <<'PY' || fail "box-drawing glyphs keep the terminal's default colour"
import re
import sys

data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
colour = None
for token in re.split(r"(\x1b\[[0-9;]*m)", data):
    match = re.fullmatch(r"\x1b\[([0-9;]*)m", token)
    if match:
        params = match.group(1).split(";") if match.group(1) else ["0"]
        if "0" in params or "39" in params:
            colour = None
        for param in params:
            if param in {"36", "91", "93", "96"}:
                colour = param
        continue
    if colour and any(0x2500 <= ord(char) <= 0x257F for char in token):
        raise SystemExit(1)
PY
PTY_TERM=dumb run_pty_raw 40 80 "$work/dumb.raw" bash "$work/fixture-golden.sh"
! LC_ALL=C grep -q $'\033\\[' "$work/dumb.raw" && ! has_frame "$work/dumb.raw" \
    || fail "TERM=dumb renders static even on a terminal"
ok "live rendering settles every branch and colours text without colouring its lines"

# Regression for the reported prefix/scaling pair. Once the operation gets
# its check mark, the title becomes a branch and the detail gets the matching
# vertical sub-trunk.
cat > "$work/fixture-settled-detail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec 7>&1
export ABLETON_UI_TTY_FD=7
. "${UI_LIB:?}"
ui_step_begin s_prefix_create
ui_item_begin p_copy_existing_prefix
ui_status p_scale_already_configured 1.33333
ui_item_end ok
ui_step_end ok
EOF
run_pty_raw 40 80 "$work/settled-detail.raw" bash "$work/fixture-settled-detail.sh"
vt "$work/settled-detail.raw" > "$work/settled-detail.screen"
if ! grep -q '^│  ├─ Copy the existing ableton-linux prefix ✓$' "$work/settled-detail.screen" \
   || ! grep -q '^│  │  > Display scaling is already set for scale 1.33333$' "$work/settled-detail.screen"; then
    fail "a completed prefix copy keeps the vertical line beside its scaling detail"
fi
ok "the reported prefix scaling detail keeps its box-drawing line"

# T2 and C5: long lines wrap on a space at width-2 and continuation lines
# keep the tree; a long token is cut hard; a long title is cut to one line.
cat > "$work/fixture-wrap.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${FIXTURE_TTY:-}" ] || { exec 7>&1; export ABLETON_UI_TTY_FD=7; }
. "${UI_LIB:?}"
UI_TEXT[i_wrap_test]='%s'
ui_step_begin s_validate
ui_item_begin i_copy
ui_status i_wrap_test "$(printf 'word%02d ' $(seq 1 40))"
ui_status i_wrap_test "$(printf 'x%.0s' $(seq 1 120))"
ui_item_end ok
ui_item_begin i_wrap_test "$(printf 'title%02d ' $(seq 1 30))"
ui_item_end ok
ui_step_end ok
EOF
run_static bash "$work/fixture-wrap.sh" < /dev/null > "$work/wrap.out" 2>&1 || fail "the wrap fixture ran"
while IFS= read -r line; do
    [ "${#line}" -le 78 ] || fail "every rendered line is at most 78 columns (got ${#line}: $line)"
done < "$work/wrap.out"
[ "$(grep -c '^│  │    word' "$work/wrap.out")" -ge 2 ] \
    || fail "wrapped status continuation lines keep the tree prefix and indent"
! grep -q '^│  │  > word.*word40' "$work/wrap.out" || fail "a long status is wrapped, not printed whole"
grep -q '^│  │  > x\{70\}' "$work/wrap.out" && grep -q '^│  │    x\{40,\}' "$work/wrap.out" \
    || fail "a token longer than the room is cut hard across lines"
grep -q '^│  ├─ title01 .*…$' "$work/wrap.out" || fail "a long title is cut to one line with an ellipsis"
[ "$(grep -c '^│  ├─ title01' "$work/wrap.out")" -eq 1 ] || fail "a cut title occupies one line"
run_pty_raw 40 50 "$work/narrow.raw" bash "$work/fixture-wrap.sh"
while IFS= read -r line; do
    [ "${#line}" -le 58 ] || fail "a terminal narrower than 60 columns wraps at 58 (got ${#line})"
done < <(vt "$work/narrow.raw" | grep '^│  │')
ok "long lines wrap inside the tree at width-2"

# T5: a timed question waits for its timeout on a silent terminal and not at
# all on a closed stdin; both return the default; piped keys and whole words
# are read even when stdin is not a terminal.
cat > "$work/fixture-question.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${FIXTURE_TTY:-}" ] || { exec 7>&1; export ABLETON_UI_TTY_FD=7; }
. "${UI_LIB:?}"
ui_step_begin s_validate
ui_question q_overwrite_title o q_overwrite_all q_keep q_abort
printf 'answer=%s\n' "$UI_ANSWER" > "${ANSWER_FILE:?}"
ui_step_end ok
EOF
start="$EPOCHREALTIME"
run_pty_raw 40 80 "$work/question.raw" env ANSWER_FILE="$work/answer-tty" bash "$work/fixture-question.sh"
awk -v a="$start" -v b="$EPOCHREALTIME" 'BEGIN { exit !(b - a >= 0.9 && b - a <= 6) }' \
    || fail "a silent terminal waits for the timeout"
grep -qx 'answer=o' "$work/answer-tty" || fail "the timeout returns the default answer"
question_hint_line="$(vt "$work/question.raw" | grep -n '^│  │  (Press Enter for default or wait 1 seconds)' | cut -d: -f1)"
question_prompt_line="$(vt "$work/question.raw" | grep -n '^│  │  Please choose \[O/K/A\]:' | cut -d: -f1)"
[ "$question_prompt_line" -eq $((question_hint_line + 1)) ] \
    || fail "the question hint is immediately above its prompt"
! has_frame "$work/question.raw" || fail "a question shows no spinner while it waits for input"
start="$EPOCHREALTIME"
run_static env ANSWER_FILE="$work/answer-eof" bash "$work/fixture-question.sh" < /dev/null > /dev/null 2>&1 \
    || fail "a question with closed stdin completes"
awk -v a="$start" -v b="$EPOCHREALTIME" 'BEGIN { exit !(b - a < 1) }' || fail "a closed stdin returns the default at once"
grep -qx 'answer=o' "$work/answer-eof" || fail "closed stdin returns the default answer"
printf 'k\n' | run_static env ANSWER_FILE="$work/answer-pipe" bash "$work/fixture-question.sh" > /dev/null 2>&1 \
    || fail "a piped answer is accepted"
grep -qx 'answer=k' "$work/answer-pipe" || fail "a piped answer is read even when stdin is not a terminal"
printf 'Keep\n' | run_static env ANSWER_FILE="$work/answer-word" bash "$work/fixture-question.sh" > /dev/null 2>&1 \
    || fail "a whole-word answer is accepted"
grep -qx 'answer=k' "$work/answer-word" || fail "a whole-word answer maps to its key letter"
printf 'maybe\nA\n' | run_static env ANSWER_FILE="$work/answer-retry" bash "$work/fixture-question.sh" > "$work/retry.out" 2>&1 \
    || fail "an unknown answer is asked again"
grep -qx 'answer=a' "$work/answer-retry" || fail "the answer after a retry is honoured"
[ "$(grep -c 'Please choose \[O/K/A\]:' "$work/retry.out")" -eq 2 ] \
    || fail "an unknown answer repeats the prompt once"
ok "timed questions honour the timeout, EOF, piped keys, whole words, and retries"

# T9: step numbers and names come from the table, in table order, for
# every action in the table.
cat > "$work/fixture-steps.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "${UI_LIB:?}"
for key in ${UI_STEPS[$ABLETON_UI_ACTION]}; do
    # The .run header owns the prepare step; a checkout run starts after it.
    [ "${ABLETON_UI_KIT:-0}" = 1 ] || [ "$key" != s_prepare ] || continue
    printf 'expect %s\n' "$(ui_text "$key" | tr '[:lower:]' '[:upper:]')" >&2
    ui_step_begin "$key"
    ui_step_end ok
done
EOF
mapfile -t actions < <(bash -c '. "$1"; printf "%s\n" "${!UI_STEPS[@]}"' _ "$ui_lib" | sort)
[ "${#actions[@]}" -ge 10 ] || fail "the step table covers every action (found ${#actions[@]})"
for action in "${actions[@]}"; do
    run_static env ABLETON_UI_ACTION="$action" bash "$work/fixture-steps.sh" \
        < /dev/null > "$work/steps-$action.out" 2> "$work/steps-$action.names" \
        || fail "step fixture ran for $action"
    mapfile -t names < <(sed -n 's/^expect //p' "$work/steps-$action.names")
    total="${#names[@]}"
    n=0
    while IFS= read -r line; do
        case "$line" in
            '│  ┃ '*)
                n=$((n + 1))
                [ "$line" = "│  ┃ $n/$total ╏ ${names[n-1]} ┃" ] \
                    || fail "$action step $n reads $n/$total with its table name (got: $line)" ;;
            '│  └─ Step '*)
                [ "$line" = "│  └─ Step $n Complete! ✓" ] || fail "$action closing $n matches its box (got: $line)" ;;
        esac
    done < "$work/steps-$action.out"
    [ "$n" -eq "$total" ] || fail "$action renders every step in its table"
done
ABLETON_UI_KIT= run_static env -u ABLETON_UI_KIT ABLETON_UI_ACTION=install bash "$work/fixture-steps.sh" \
    < /dev/null > "$work/steps-checkout.out" 2>/dev/null || fail "step fixture ran from a checkout"
grep -q '^│  ┃ 1/7 ╏ CHECK THE HOST AND THE REQUEST ┃$' "$work/steps-checkout.out" \
    || fail "without the .run header the list starts at the validate step"
cat > "$work/fixture-wide.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "${UI_LIB:?}"
UI_STEPS[wide]=''
for i in $(seq 1 12); do UI_TEXT[s_w$i]="Step number $i"; UI_STEPS[wide]="${UI_STEPS[wide]} s_w$i"; done
export ABLETON_UI_ACTION=wide
for key in ${UI_STEPS[wide]}; do ui_step_begin "$key"; ui_step_end ok; done
EOF
run_static bash "$work/fixture-wide.sh" < /dev/null > "$work/steps-wide.out" 2>&1 || fail "wide step fixture ran"
top="$(grep -B1 '^│  ┃ 10/12 ╏' "$work/steps-wide.out" | head -1)"
mid="$(grep '^│  ┃ 10/12 ╏' "$work/steps-wide.out")"
bottom="$(grep -A1 '^│  ┃ 10/12 ╏' "$work/steps-wide.out" | tail -1)"
[ "${#top}" -eq "${#mid}" ] && [ "${#mid}" -eq "${#bottom}" ] \
    || fail "a two-digit step counter keeps the three box lines aligned"
[[ "$top" == '├──┲━━━━━━━┳'* ]] || fail "the counter cell widens with its text"
status=0
run_static bash -c '. "$UI_LIB"; ui_step_begin s_no_such_step' < /dev/null > /dev/null 2>&1 || status=$?
[ "$status" -eq 70 ] || fail "a step key outside the table exits 70 (got $status)"
ok "step numbering follows the table for every action"

# T10: footer variants and the width guard.
cat > "$work/fixture-footer.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "${UI_LIB:?}"
case "${1:?}" in
    failed)
        ui_footer "$(ui_text label_reinstall)" 2026.08.28.1 failed 7 2 1 '' ''
        ui_tail failed '~/x.log' 'The Live installer failed or timed out (exit 1)' ;;
    interrupted) ui_footer Update 2026.08.28.1 interrupted 3 0 0 /r /p; ui_tail interrupted '' ;;
    cancelled) ui_footer Update 2026.08.28.1 cancelled 0 0 0 '' ''; ui_tail cancelled '~/x.log' ;;
    long)
        ui_footer Update 2026.08.28.1 complete 9 0 0 \
            /home/someone/with/a/very/long/path/to/.local/opt/wine-d2d1-nspa-11.13-rebuilt-2026 \
            /home/someone/.wine-ableton
        ui_tail complete '~/x.log' ;;
esac
EOF
run_static bash "$work/fixture-footer.sh" failed < /dev/null > "$work/footer-failed.out" 2>&1 || fail "footer fixture ran"
grep -q '^│ Ableton-Linux Reinstall v. 2026.08.28.1 *│   Failed │$' "$work/footer-failed.out" \
    || fail "a failed run shows Failed in the status cell"
grep -q '^│ Warnings: *│        2 │$' "$work/footer-failed.out" && grep -q '^│ Errors: *│        1 │$' "$work/footer-failed.out" \
    || fail "the footer shows the warning and error counts"
! grep -q '^│ runtime:' "$work/footer-failed.out" || fail "unknown runtime and prefix rows are omitted"
grep -q '^Errors:$' "$work/footer-failed.out" \
    && grep -q '^  > The Live installer failed or timed out (exit 1)$' "$work/footer-failed.out" \
    || fail "a failed run lists its errors one per line"
grep -q 'https://github.com/shibco/ableton-linux/issues' "$work/footer-failed.out" \
    || fail "a failed run offers the issues link"
! grep -q 'ableton-live$' "$work/footer-failed.out" || fail "a failed run has no launch hint"
run_static bash "$work/fixture-footer.sh" interrupted < /dev/null > "$work/footer-int.out" 2>&1 || fail "footer fixture ran"
grep -q '│ Interrupted │$' "$work/footer-int.out" || fail "an interrupted run says Interrupted"
grep -q '^The installer could not save its log\.$' "$work/footer-int.out" || fail "a missing log is reported"
run_static bash "$work/fixture-footer.sh" cancelled < /dev/null > "$work/footer-cancel.out" 2>&1 || fail "footer fixture ran"
grep -q '│ Cancelled │$' "$work/footer-cancel.out" || fail "a cancelled run says Cancelled"
! grep -q 'ableton-live$' "$work/footer-cancel.out" || fail "a cancelled run has no launch hint"
run_static bash "$work/fixture-footer.sh" long < /dev/null > "$work/footer-long.out" 2>&1 || fail "footer fixture ran"
while IFS= read -r line; do
    [ "${#line}" -eq 78 ] || fail "a widened footer never exceeds width-2 (got ${#line}: $line)"
done < <(grep '^[╞├│╘]' "$work/footer-long.out")
grep -q '^│ runtime: …[^ ]*wine-d2d1-nspa-11.13-rebuilt-2026 *│$' "$work/footer-long.out" \
    || fail "an overlong path is shortened from the left so its tail survives"
grep -q '^│ ableton-linux prefix: /home/someone/.wine-ableton *│$' "$work/footer-long.out" \
    || fail "a short row in a widened footer keeps its border"
ok "the footer renders every status, widens to the terminal, and shortens long paths"

# T12: a non-UTF-8 locale gets the ASCII glyph set with the same structure,
# and the charset captured by the .run header wins over the current locale.
env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work" LANG=C TERM=xterm COLUMNS=80 \
    ABLETON_UI_ACTION=install ABLETON_UI_KIT=1 ABLETON_UI_PROMPT_TIMEOUT=5 UI_LIB="$ui_lib" \
    bash "$work/fixture-golden.sh" < /dev/null > "$work/ascii.out" 2>&1 || fail "the ASCII fixture ran"
! LC_ALL=C grep -q $'[\x80-\xff]' "$work/ascii.out" || fail "a C locale never receives a byte above 127"
[ "$(wc -l < "$work/ascii.out")" -eq "$(wc -l < "$work/golden-static.txt")" ] \
    || fail "the ASCII rendering has the same line structure as the UTF-8 one"
env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work" LANG=C ABLETON_UI_CHARSET=utf8 TERM=xterm COLUMNS=80 \
    ABLETON_UI_ACTION=install ABLETON_UI_KIT=1 ABLETON_UI_PROMPT_TIMEOUT=5 UI_LIB="$ui_lib" \
    bash "$work/fixture-golden.sh" < /dev/null > "$work/charset-env.out" 2>&1 || fail "the charset override fixture ran"
cmp -s "$work/charset-env.out" "$work/golden-static.txt" \
    || fail "ABLETON_UI_CHARSET captured by the .run header wins over the current locale"
ok "the ASCII glyph set is used when the inherited locale is not UTF-8"

# T13: a full or closed screen never changes an exit status or leaks noise,
# and the log still receives the lines.
cat > "$work/fixture-closed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:?}" in
    full) exec 7> /dev/full ;;
    closed) exec 7> /dev/null; exec 7>&- ;;
esac
export ABLETON_UI_TTY_FD=7
. "${UI_LIB:?}"
ui_step_begin s_validate
ui_item_begin i_copy
ui_status i_copy_done 1
ui_item_end ok
ui_run i_extract -- true
ui_step_end ok
exit 0
EOF
for mode in full closed; do
    run_static env ABLETON_INSTALLER_LOG="$work/closed-$mode.log" bash "$work/fixture-closed.sh" "$mode" \
        < /dev/null > "$work/closed-$mode.out" 2> "$work/closed-$mode.err" \
        || fail "a $mode screen keeps the exit status"
    ! grep -qi 'bad file descriptor\|no space' "$work/closed-$mode.err" \
        || fail "a $mode screen produces no error noise"
    grep -q 'Copied 1 MiB' "$work/closed-$mode.log" || fail "a $mode screen still logs the rendered lines"
done
ok "a full or closed screen is silent and harmless"

# D2: from a checkout, raw output between two rendered lines stays in order.
run_static bash -c '. "$UI_LIB"; ui_step_begin s_validate; ui_item_begin i_copy; ui_status i_copy_done 1; echo raw-line; ui_status i_copy_done 2; ui_item_end ok; ui_step_end ok' \
    < /dev/null > "$work/order.out" 2>&1 || fail "the ordering fixture ran"
[ "$(grep -n 'Copied 1 MiB\|raw-line\|Copied 2 MiB' "$work/order.out" | cut -d: -f2- | paste -sd'|')" = \
  '│  │  > Copied 1 MiB.|raw-line|│  │  > Copied 2 MiB.' ] || fail "checkout output keeps raw lines in order"
ok "checkout rendering interleaves raw output in order"

# T19: a block taller than the terminal is left as drawn; a short one flips.
cat > "$work/fixture-tall.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${FIXTURE_TTY:-}" ] || { exec 7>&1; export ABLETON_UI_TTY_FD=7; }
. "${UI_LIB:?}"
UI_TEXT[i_tall_test]='Tall item'
UI_TEXT[i_short_test]='Short item'
UI_TEXT[i_line_test]='line %s'
ui_step_begin s_validate
ui_item_begin i_short_test
ui_item_end ok
ui_item_begin i_tall_test
for i in 1 2 3 4 5 6 7; do ui_status i_line_test "$i"; done
ui_item_end ok
ui_item_begin i_short_test
ui_item_end ok
ui_step_end ok
EOF
run_pty_raw 6 80 "$work/tall.raw" bash "$work/fixture-tall.sh"
LC_ALL=C grep -q $'├─ \033\[36mShort item ✓' "$work/tall.raw" || fail "a short block still flips on a small terminal"
! LC_ALL=C grep -q $'├─ \033\[[0-9;]*mTall item' "$work/tall.raw" || fail "a block taller than the terminal is not rewritten"
LC_ALL=C grep -q $'└─ \033\[96mTall item' "$work/tall.raw" || fail "the tall block was drawn"
! LC_ALL=C grep -qE $'\033\\[([5-9]|[1-9][0-9]+)A' "$work/tall.raw" \
    || fail "no cursor movement reaches beyond the terminal height"
ok "rewrites are skipped when the block does not fit the terminal"

# C3: a ui_run with a progress file shows the running size on its title.
cat > "$work/fixture-progress.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${FIXTURE_TTY:-}" ] || { exec 7>&1; export ABLETON_UI_TTY_FD=7; }
. "${UI_LIB:?}"
ui_step_begin s_validate
: > "${PROGRESS_FILE:?}"
ui_run i_copy --progress "$PROGRESS_FILE" 2097152 -- \
    sh -c 'head -c 1048576 /dev/zero >> "$1"; sleep 0.6' _ "$PROGRESS_FILE"
ui_step_end ok
EOF
PROGRESS_FILE="$work/progress" run_pty_raw 40 80 "$work/progress.raw" env PROGRESS_FILE="$work/progress" bash "$work/fixture-progress.sh"
LC_ALL=C grep -q '(1 / 2 MiB)' "$work/progress.raw" || fail "the spinner line shows the copied size"
vt "$work/progress.raw" | grep '^│  ├─ Copy the embedded kit ✓$' >/dev/null || fail "the progress title settles without the counter"
ok "a ui_run with a progress file shows its running size"

# T22: ending twice, or ending with nothing open, changes nothing on screen
# and leaves one log line each.
cat > "$work/fixture-double.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "${UI_LIB:?}"
ui_step_begin s_validate
ui_item_begin i_copy
ui_item_end ok
[ "${DOUBLE:-0}" -eq 0 ] || ui_item_end ok
ui_step_end ok
[ "${DOUBLE:-0}" -eq 0 ] || ui_step_end ok
EOF
run_static env ABLETON_INSTALLER_LOG="$work/single.log" bash "$work/fixture-double.sh" < /dev/null > "$work/single.out" 2>&1 \
    || fail "the single-end fixture ran"
run_static env DOUBLE=1 ABLETON_INSTALLER_LOG="$work/double.log" bash "$work/fixture-double.sh" \
    < /dev/null > "$work/double.out" 2>&1 || fail "a double end does not fail the script"
cmp -s "$work/single.out" "$work/double.out" || fail "a double item or step end prints nothing extra"
[ "$(wc -l < "$work/double.log")" -eq $(( $(wc -l < "$work/single.log") + 2 )) ] \
    || fail "each stray end leaves exactly one log line"
ok "double ends are harmless no-ops with a log line"

# T15: every screen string lives in the dictionary, and every entry is used.
grep -q '^declare -A UI_TEXT=' "$ui_lib" && grep -q '^declare -A UI_STEPS=' "$ui_lib" \
    || fail "ui.sh declares UI_TEXT and UI_STEPS"
tail_start="$(grep -n '^# END UI_TEXT' "$ui_lib" | head -1 | cut -d: -f1)"
[ -n "$tail_start" ] || fail "ui.sh marks the end of its dictionary with '# END UI_TEXT'"
[ "$(grep -n '^declare -A UI_TEXT=' "$ui_lib" | cut -d: -f1)" -lt "$tail_start" ] || fail "the dictionary opens ui.sh"
leaks="$(tail -n +"$tail_start" "$ui_lib" | grep -v '^[[:space:]]*#' \
    | grep -E '^[[:space:]]*(\{ )?(printf|echo)' \
    | grep -v '>> *"\$UI_LOG"\|>>"\$UI_LOG"\|>&2' \
    | sed -E 's/%[-0-9.*]*[sdc]//g; s/\\[nrte]//g; s/\\e\[[0-9;?]*[A-Za-z]//g; s/\\033\[[0-9;?]*[A-Za-z]//g; s/\$\{[^}]*\}//g; s/\$[A-Za-z_0-9]+//g' \
    | grep -E "'[^']*[A-Za-z][^']*'|\"[^\"]*[A-Za-z][^\"]*\"" \
    | grep -v 'UI_TEXT\[' || true)"
[ -z "$leaks" ] || { printf '%s\n' "$leaks" | head -5 >&2; fail "no screen text is printed from outside the dictionary"; }
mapfile -t keys < <(sed -n 's/^[[:space:]]*\[\([a-z0-9_]*\)\]=.*/\1/p' "$ui_lib" | sort -u)
# Explicit file list: some grep builds ignore --exclude on named files.
users=()
for f in "$here"/*.sh "$here"/lib/*.sh; do
    case "$f" in */test-*.sh|*/lib/ui.sh) continue ;; esac
    users+=("$f")
done
unused=()
for key in "${keys[@]}"; do
    case "$key" in g_*|a_*) continue ;; esac
    if ! grep -qw -- "$key" "${users[@]}" \
       && ! grep -Ev "^[[:space:]]*\[$key\]=" "$ui_lib" | grep -w -- "$key" > /dev/null; then
        unused+=("$key")
    fi
done
[ "${#unused[@]}" -eq 0 ] || fail "every dictionary entry is referenced (unused: ${unused[*]})"
for g in $(sed -n 's/^[[:space:]]*\[g_\([a-z0-9_]*\)\]=.*/\1/p' "$ui_lib"); do
    grep -q "^[[:space:]]*\[a_$g\]=" "$ui_lib" || fail "glyph $g has an ASCII twin"
done
for key in $(bash -c '. "$1"; printf "%s\n" ${UI_STEPS[@]}' _ "$ui_lib" | sort -u); do
    grep -q "^[[:space:]]*\[$key\]=" "$ui_lib" || fail "step key $key has a name entry"
done
ok "the dictionary is the only source of screen text and has no dead entries"

# T16: ui.sh draws the installer tree.
installer_scripts=("$here"/installer.sh "$here"/install.sh "$here"/setup-prefix.sh "$here"/setup-link.sh \
    "$here"/uninstall.sh "$here"/setup-run-header.sh "$here"/make-installer.sh "$here"/detect-scale.sh \
    "$here"/detect-theme.sh "$here"/lib/config.sh "$here"/lib/lifecycle.sh "$here"/lib/manifest.sh \
    "$here"/lib/pipeasio.sh "$here"/lib/live-options.sh)
if grep -l '[├└│┃┏┓┡┲╒╞╘═┈✓𐄂⚠🛈]' "${installer_scripts[@]}" | grep -q .; then
    grep -l '[├└│┃┏┓┡┲╒╞╘═┈✓𐄂⚠🛈]' "${installer_scripts[@]}" >&2
    fail "no installer script other than ui.sh contains a tree glyph"
fi
ok "ui.sh is the installer tree renderer"

# T17: the .run header is assembled from the same renderer.
"$here/make-installer.sh" --render-header --version suite-check --payload-sha 0 > "$work/header.sh" \
    || fail "make-installer.sh renders the .run header on its own"
grep -q '^declare -A UI_TEXT=' "$work/header.sh" || fail "the rendered header inlines the dictionary"
! grep -q '@UI_LIB@\|@VERSION@\|@PAYLOAD_SHA@' "$work/header.sh" || fail "the rendered header has no markers left"
grep -q '^__PAYLOAD_BELOW__$' "$work/header.sh" || fail "the rendered header keeps its payload marker"
sh "$work/header.sh" --help > "$work/header-help.out" 2>&1 || fail "the rendered header answers --help"
grep -q 'install, update, runtime install' "$work/header-help.out" || fail "--help lists the commands"
bash -n "$work/header.sh" || fail "the rendered header is valid bash"
"$here/make-installer.sh" --help 2>&1 | grep -q -- '--dev' || fail "make-installer.sh documents its dev pack switch"
ok "the .run header is rendered from ui.sh by make-installer.sh"

# T6: the action menu through a stub .run on a terminal. Keys are sent only
# once the prompt is on screen, so the echo lands where a person's would.
kit="$work/kit"
mkdir -p "$kit/scripts/lib"
cp "$ui_lib" "$kit/scripts/lib/ui.sh"
cat > "$kit/scripts/installer.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STUB_ARGS_FILE:?}"
exit 0
EOF
build_stub_run()
{
    tar -cf "$work/payload.tar" -C "$kit" .
    "$here/make-installer.sh" --render-header --version suite-check \
        --payload-sha "$(sha256sum "$work/payload.tar" | awk '{print $1}')" > "$1"
    cat "$work/payload.tar" >> "$1"
}
build_stub_run "$work/kit.run"
menu_case()
{
    local keys="$1" out="$2"; shift 2
    rm -f "$work/stub-args"
    : > "$out"
    env -i PATH="$wrapper_bin:$PATH" HOME="$work/home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm SHELL=/bin/bash \
        STUB_ARGS_FILE="$work/stub-args" "$@" \
        script -qfec "stty rows 40 cols 100; sh $work/kit.run; echo exit=\$?" /dev/null \
        < <(for _ in $(seq 300); do grep -aq 'Choose an action:' "$out" 2>/dev/null && break; sleep 0.05; done
            feed "$out" 'exit=[0-9]' "$keys") > "$out" 2>&1 || true
}
menu_case $'q\n' "$work/menu-q.out"
[ ! -e "$work/stub-args" ] || fail "[Q]uit never reaches the installer"
grep -q 'exit=0' "$work/menu-q.out" || fail "[Q]uit exits 0"
vt "$work/menu-q.out" > "$work/menu-q.screen"
grep -q '│ Cancelled │' "$work/menu-q.screen" || fail "[Q]uit ends with a Cancelled footer"
grep -q '^│  > \[Q\]uit$' "$work/menu-q.screen" || fail "the fresh menu offers [Q]uit"
! grep -q 'Remo\[v\]e Ableton Linux' "$work/menu-q.screen" \
    || fail "the fresh menu does not claim an owned install can be removed"
grep -q '^│ Ableton-Linux Installer Choice:$' "$work/menu-q.screen" || fail "the menu heading follows the template"
grep -q '^│  Choose an action: q$' "$work/menu-q.screen" || fail "the answer is echoed on the prompt line"
! grep -q 'Selected:' "$work/menu-q.screen" || fail "the menu no longer prints a Selected line"
menu_case $'\n\n\n\n\n\n\n' "$work/menu-enter.out"
grep -qx 'install' "$work/stub-args" || fail "Enter picks the default action (no prefix means install)"
vt "$work/menu-enter.out" | grep '^│  > \[I\]nstall (or press Enter)$' >/dev/null \
    || fail "the default option carries the Enter hint"
mkdir -p "$work/home/.wine-ableton" "$work/home/.config/ableton-wine"
printf 'WINE REGISTRY Version 2\n' > "$work/home/.wine-ableton/system.reg"
printf 'format=1\nprefix=%s\n' "$work/home/.wine-ableton" \
    > "$work/home/.wine-ableton/.ableton-linux-prefix"
cat > "$work/home/.config/ableton-wine/config" <<EOF
# ableton-linux installer configuration; managed by the installer
format=1
runtime_root=$work/home/.local/opt/wine-d2d1-nspa-11.13
prefix=$work/home/.wine-ableton
live_major=12
link_mode=session
linkd=$work/home/.local/share/ableton-wine/ableton-linkd
EOF
chmod 600 "$work/home/.config/ableton-wine/config"
menu_case $'\n\n\n\n\n\n\n' "$work/menu-update.out"
grep -qx 'update' "$work/stub-args" || fail "Enter picks update when a prefix exists"
vt "$work/menu-update.out" | grep '^│  > \[U\]pdate (or press Enter)$' >/dev/null || fail "update is the default with a prefix"
for key in u U update; do
    menu_case "$key"$'\n\n\n\n\n\n\n' "$work/menu-$key.out"
    grep -qx 'update' "$work/stub-args" || fail "$key picks update"
done
for key in r reinstall; do
    menu_case "$key"$'\n\n\n\n\n\n\n' "$work/menu-$key.out"
    grep -qx 'install' "$work/stub-args" || fail "$key picks reinstall"
done
menu_case $'V\n' "$work/menu-v.out"
grep -qx 'uninstall' "$work/stub-args" || fail "V picks remove regardless of case"
menu_case $'?\n' "$work/menu-bad.out"
[ ! -e "$work/stub-args" ] || fail "an unknown key never reaches the installer"
grep -q 'exit=2' "$work/menu-bad.out" || fail "an unknown key exits 2"
vt "$work/menu-bad.out" | grep 'Unknown action: ?' >/dev/null || fail "an unknown key is named"
vt "$work/menu-bad.out" | grep '│   Failed │' >/dev/null || fail "an unknown key ends as a failed run"
rm -f "$work/stub-args"
env -i PATH="$wrapper_bin:$PATH" HOME="$work/home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm STUB_ARGS_FILE="$work/stub-args" \
    sh "$work/kit.run" < /dev/null > "$work/menu-notty.out" 2>&1 || fail "a run without a terminal takes the default"
grep -qx 'update' "$work/stub-args" || fail "stdin off a terminal takes the default action without reading"
! grep -q 'Choose an action' "$work/menu-notty.out" || fail "stdin off a terminal never prompts"
: > "$work/menu-ascii.out"
env -i PATH="$wrapper_bin:$PATH" HOME="$work/home" TMPDIR="$work" LANG=C TERM=xterm SHELL=/bin/bash STUB_ARGS_FILE="$work/stub-args" \
    script -qfec "stty rows 40 cols 100; sh $work/kit.run update; echo $done_marker" /dev/null \
    < <(feed "$work/menu-ascii.out" "$done_marker") > "$work/menu-ascii.out" 2>&1 || true
! LC_ALL=C grep -q $'[\x80-\xff]' "$work/menu-ascii.out" \
    || fail "the .run header captures a C locale before it exports its own"
env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm \
    sh "$work/kit.run" extract "$work/extracted" < /dev/null > "$work/extract.out" 2>&1 \
    || fail "extract mode completes"
[ -f "$work/extracted/scripts/installer.sh" ] || fail "extract mode writes the kit"
grep -q '│  ┃ 1/1 ╏ ' "$work/extract.out" && grep -q '│  └─ Step 1 Complete! ✓' "$work/extract.out" \
    && grep -q '│ Complete │' "$work/extract.out" || fail "extract mode is one step of one"
ok "the action menu follows the template and routes every key"

# T11 and T18 through the same stub: a child that fails mid-step, whose raw
# error reaches the log and the footer but not the screen. The stub's EXIT
# handler stands in for installer.sh's, which calls ui_cleanup first (E2).
cat > "$kit/scripts/installer.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/ui.sh"
trap 'ui_cleanup $?' EXIT
ui_step_begin s_validate
ui_item_begin i_copy
echo '!! boom from the child' >&2
exit 3
EOF
build_stub_run "$work/kit-fail.run"
rm -f "$work"/ableton-linux-installer-*.log
: > "$work/fail.raw"
env -i PATH="$wrapper_bin:$PATH" HOME="$work/home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm SHELL=/bin/bash \
    script -qfec "stty rows 40 cols 100; sh $work/kit-fail.run update; echo exit=\$?" /dev/null \
    < <(feed "$work/fail.raw" 'exit=[0-9]') > "$work/fail.raw" 2>&1 || true
grep -q 'exit=3' "$work/fail.raw" || fail "the child's exit status passes through"
vt "$work/fail.raw" > "$work/fail.screen"
grep -q '^│  ├─ Copy the embedded kit 𐄂$' "$work/fail.screen" || fail "an item open at a child's failure shows 𐄂"
[ "$(grep -c '^│  └─ Step 2 Failed! 𐄂$' "$work/fail.screen")" -eq 1 ] || fail "the step is closed as Failed exactly once"
grep -q '│   Failed │' "$work/fail.screen" || fail "the footer says Failed"
grep -q '^│ Errors: *│        [1-9] │$' "$work/fail.screen" || fail "the footer counts the error"
grep -q '^  > boom from the child$' "$work/fail.screen" || fail "the child's error is listed in the footer"
! grep -q '^!! boom' "$work/fail.screen" || fail "raw child output does not reach the screen mid-tree"
log="$(ls -t "$work"/ableton-linux-installer-*.log 2>/dev/null | head -1)"
[ -n "$log" ] || fail "the .run wrote its log beside itself"
grep -q '^\[ERR\] .*boom from the child' "$log" || fail "the child's error is in the log as ERR"
grep -q '├─ Copy the embedded kit' "$log" && grep -q 'Step 2 Failed!' "$log" \
    || fail "the log holds the rendered tree without escapes"
! LC_ALL=C grep -q $'\033' "$log" || fail "the log has no escape sequences"
ok "a failing child closes its item and step, and its error reaches the log and footer"

# T14: Ctrl-C during a running item, and a parent that vanishes under its
# spinner.
hold="30.$$"
cat > "$kit/scripts/installer.sh" <<EOF
#!/usr/bin/env bash
. "\$(dirname "\$0")/lib/ui.sh"
trap 'ui_cleanup \$?' EXIT
trap 'exit 130' INT
ui_step_begin s_validate
printf '%s\n' "\$\$" > "\${STUB_MARKER:?}"
ui_run i_copy -- sleep $hold
ui_step_end ok
EOF
build_stub_run "$work/kit-int.run"
rm -f "$work/marker"
: > "$work/int.raw"
env -i PATH="$wrapper_bin:$PATH" HOME="$work/home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm SHELL=/bin/bash STUB_MARKER="$work/marker" \
    script -qfec "stty rows 40 cols 100; sh $work/kit-int.run update; echo exit=\$?" /dev/null \
    < <(for _ in $(seq 300); do [ -e "$work/marker" ] && break; sleep 0.1; done; sleep 0.5
        feed "$work/int.raw" 'exit=[0-9]' $'\003') > "$work/int.raw" 2>&1 || true
grep -q 'exit=130' "$work/int.raw" || fail "Ctrl-C exits 130 through the .run header"
vt "$work/int.raw" | grep '│ Interrupted │' >/dev/null || fail "Ctrl-C ends with an Interrupted footer"
last_escape="$(LC_ALL=C grep -ao $'\033\\[?25[hl]' "$work/int.raw" | tail -1)"
[ "$last_escape" = $'\033[?25h' ] || fail "the cursor is visible after an interrupt"
sleep 1
! pgrep -f "sleep $hold" > /dev/null 2>&1 || fail "no task is left behind after an interrupt"
rm -f "$work/marker"
: > "$work/orphan.raw"
env -i PATH="$wrapper_bin:$PATH" HOME="$work/home" TMPDIR="$work" LANG=C.UTF-8 TERM=xterm SHELL=/bin/bash STUB_MARKER="$work/marker" \
    script -qfec "stty rows 40 cols 100; sh $work/kit-int.run update; echo $done_marker" /dev/null \
    < <(for _ in $(seq 300); do [ -e "$work/marker" ] && break; sleep 0.1; done; sleep 0.5
        kill -9 "$(cat "$work/marker")" 2>/dev/null; feed "$work/orphan.raw" "$done_marker") > "$work/orphan.raw" 2>&1 &
orphan_pid=$!
for _ in $(seq 100); do [ -e "$work/marker" ] && break; sleep 0.1; done
sleep 2
size_a="$(stat -c %s "$work/orphan.raw")"; sleep 1; size_b="$(stat -c %s "$work/orphan.raw")"
[ "$size_a" -eq "$size_b" ] || fail "a spinner whose parent vanished keeps drawing"
pkill -f "sleep $hold" > /dev/null 2>&1 || true
wait "$orphan_pid" 2>/dev/null || true
ok "an interrupt cleans up the spinner, restores the cursor, and reports Interrupted"

printf 'PASS: %d installer UI checks\n' "$pass"
