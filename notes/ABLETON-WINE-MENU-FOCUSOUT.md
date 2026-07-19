# Dropdown menus flash, close, or need repeat clicks (GNOME / Cinnamon / KDE)

Issue #3. Status 2026-07-19: fix authored as patch 0038, compile-verified;
runtime verification per desktop still pending.

Update, later 2026-07-19: shipped in 2026.07.19.1 and the issue still
reproduced. A live trace showed Live's Preferences dropdowns are not
win32u menus and never hit this path; the actual root cause is the
mapped-window managed flip, fixed by patch 0039, see
[ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md](ABLETON-WINE-DROPDOWN-MANAGED-FLIP.md).
The 0038 gate below stays: it is a real cancellation route for the menu
bar dropdowns, just not the one issue #3's reporters were hitting.

## Symptoms

Live's Preferences dropdowns misbehave, differently per desktop:

- GNOME (mutter): the menu opens but needs a couple of clicks before it
  reacts, the pointer has to be dead center, and opening one in fullscreen
  brings up the Dash.
- Cinnamon (muffin): the menu opens fine but disappears or flashes the
  moment an item is selected.
- KDE (KWin): intermittent glitches.

Whitelisting the Rounded Window Corners GNOME extension does not fix it;
the extension amplifies the wobble but is not the cause.

## Research

Live's dropdowns are standard win32u popup menus, which winex11 maps as
override-redirect X11 windows. Mapping or clicking one makes mutter and
muffin shuffle the X input focus, and once the shuffle resolves a
NotifyNormal FocusOut is delivered to Live's foreground window.

`focus_out()` in `dlls/winex11.drv/event.c` answers any such FocusOut on
the foreground window with WM_CANCELMODE, and WM_CANCELMODE terminates
win32u menu tracking: the dropdown closes. The per-WM timing of the
shuffle explains the different symptoms: muffin delivers it around the
item click (flash and close on select), mutter around map (the menu is
wedged until re-clicked), KWin only occasionally.

Grab-mode FocusOut events (NotifyGrab/NotifyUngrab) were already filtered
in `X11DRV_FocusOut`; the killer is the NotifyNormal event after the
shuffle. Virtual desktop mode never hits the path (`focus_out()` returns
early there), consistent with the bug not reproducing in it. That is not a
mitigation we ship: Live stays a first-class native window.

## Mitigation

[../patches/0038-winex11-don-t-cancel-menu-tracking-while-the-focus-s.patch](../patches/0038-winex11-don-t-cancel-menu-tracking-while-the-focus-s.patch)
(`dlls/winex11.drv/event.c`): while the foreground thread reports
GUI_INMENUMODE, `focus_out()` only sends WM_CANCELMODE when XGetInputFocus
shows another client's window actually holding the focus. None/PointerRoot
(the shuffle still in flight) and windows of the Live process (the popup
itself, another Live window) no longer cancel. A real switch to another
application still cancels the menu, and clicking outside the menu still
closes it through the capture path, which never reaches `focus_out()`.

## Verification

- Compile: `winex11.so` and `winex11.drv.so` build clean with the full
  series (0001-0036 plus 0038) on base 7ea0c8b7.
- Runtime (pending): on a GNOME, a Cinnamon, and a KDE session, open every
  Preferences dropdown, select items, repeat in fullscreen. Old behaviour:
  flash/close on select (Cinnamon), repeat clicks needed (GNOME).
  [../tools/menutest.c](../tools/menutest.c) is the standalone menu repro.
- Canary: `WINEDEBUG=warn+event` logs "Ignoring FocusOut on ... during
  menu tracking" each time the gate fires.

## Known limits

The patch keeps the menu alive and clickable; it does not stop the shell
from reacting to the focus shuffle itself. The Dash appearing over a
fullscreen Live and the extension-driven wobble are shell-side and may
persist visually. If they stay annoying, the follow-up is map-time focus
handling for the popup, not more WM_CANCELMODE gating.
