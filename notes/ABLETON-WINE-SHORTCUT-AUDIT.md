# Live shortcut audit, 2026-08-06

The audit compared Live 11 and 12 shortcut references with Wine 11.13 input
handling and common GNOME bindings. It found one Wine menu-state defect and
three GNOME shortcuts that can pre-empt Live. Current user guidance is in
[ABLETON-WINE-SHORTCUT-PARITY.md](ABLETON-WINE-SHORTCUT-PARITY.md).

## Wine treated handled Alt chords as bare Alt

Wine armed its menu bar in `DefWindowProc`, then cleared that state only when
another key also reached `DefWindowProc`. Live consumes its own Alt shortcuts.
For Alt+4, Wine saw Alt down and Alt up but did not see the consumed 4, so it
entered menu mode. The next letter could open a menu.

Patch 0070 clears pending Alt or F10 menu state in the input retrieval path
when any other key or mouse button is removed from the queue. This runs before
the application handles the input.

`tools/altnum-menu-repro.c` checks:

- a swallowed Alt+4 in both release orders
- a swallowed Alt-click
- Alt plus a menu mnemonic
- bare Alt
- normal pass-through handling

The patched Wine build passed those checks. Alt menu mnemonics, bare Alt, and
pass-through behaviour remained intact. The change had not yet been exercised
inside Live when this audit was recorded.

Live shortcuts affected by the old state included the Alt+0 to Alt+8 focus
family, Alt+Shift view actions, arrangement actions using Alt, Live 11's
Alt+1 to Alt+3 tabs, and Alt with mouse gestures.

## Desktop shortcuts Wine never receives

GNOME commonly owns:

| Live shortcut | Live action | GNOME action |
|---|---|---|
| Ctrl+Alt+Up/Down | adjust note selection chance | switch workspace |
| Ctrl+Alt+Delete, Live 11 | delete fades | logout or power dialogue |

Other desktop collisions depend on user configuration, including Alt+digits
for workspaces and Alt+drag for moving windows. Alt+Tab is also owned by the
desktop on Windows, so it is not a Live parity issue.

The default launcher policy strips only the exact GNOME entries above. It
preserves other accelerators stored in the same setting, saves a private
recovery file, coordinates multiple Live processes, restores after the last
process exits, and keeps a user change made during the session.

## Checks still open

- exercise patch 0070 in Live 11 and 12
- check Alt with mouse gestures
- check F1 for an unwanted `WM_HELP` side effect
- compare AltGr chords on a non-US layout
- exercise the GNOME hold in a real session and after a forced Live exit

Do not infer results for KDE, sway, Hyprland, or another desktop from the GNOME
implementation.
