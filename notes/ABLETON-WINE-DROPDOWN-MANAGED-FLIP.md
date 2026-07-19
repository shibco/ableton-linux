# Preferences dropdowns flash, eat the first click, grow WM decorations (issue #3 root cause)

Status 2026-07-19: root cause found by tracing a live repro on GNOME;
fix is patch 0039, compile-verified and applies on base; runtime
verification in progress. Supersedes the root-cause hypothesis in
[ABLETON-WINE-MENU-FOCUSOUT.md](ABLETON-WINE-MENU-FOCUSOUT.md) (patch
0038): that gate is correct but covers a path Live's dropdowns never
hit, which is why 2026.07.19.1 did not resolve the issue.

## Symptoms

Same set as issue #3 on all desktops: dropdown flashes or vanishes on
select (Cinnamon), needs a second click and wobbles on open (GNOME,
Dash appears over fullscreen), grows a shadow frame that reads as a
"second popup" (KDE). Whitelisting the Live window in Rounded Window
Corners does not help.

## Research

Traced with `WINEDEBUG=warn+event,trace+event,trace+x11drv,trace+menu`
against a live repro (log excerpts in the patch 0039 commit message):

- Live's menu bar dropdowns are win32u menus (#32768). Their tracking
  completes normally; patch 0038's FocusOut path never fires. They are
  not the problem.
- The Preferences dropdown lists are Live's own WS_POPUP windows. They
  are shown with SWP_NOACTIVATE, mapped override-redirect, and work
  until Live pokes the open list with an activating no-op SetWindowPos
  (NOSIZE|NOMOVE|NOZORDER, no NOACTIVATE). On Windows that call changes
  nothing.
- Under this Wine, `is_window_managed` treats any SetWindowPos without
  SWP_NOACTIVATE/SWP_HIDEWINDOW as "activated windows are managed", and
  `X11DRV_WindowPosChanged` then calls `window_set_managed(TRUE)` on the
  mapped popup. The flip can only happen through a WM_STATE unmap/remap
  round-trip. Trace of the open dropdown, right after
  EnterNotify/MotionNotify from mousing over it:

  ```
  window_set_wm_state  0x30156 WM_STATE 0x1 -> 0     (unmapped in use)
  window_set_managed   0x30156 override-redirect 1 -> 0
  window_set_wm_state  0x30156 WM_STATE 0 -> 0x1     (remapped, managed)
  ```

- Everything DE-visible follows from that one flip: the unmap/remap is
  the flash and the eaten click, and the popup is now a WM-managed
  dialog-typed toplevel, so mutter animates it, GNOME reacts over
  fullscreen, KWin decorates it, and compositor extensions style it.
  The popup is also typed `_NET_WM_WINDOW_TYPE_DIALOG` (owned WS_POPUP
  rule in `set_wm_hints`), which makes the WM treatment worse.

## Mitigation

[../patches/0039-winex11-never-flip-a-mapped-window-to-managed.patch](../patches/0039-winex11-never-flip-a-mapped-window-to-managed.patch)
(`dlls/winex11.drv/window.c`): `window_set_managed` refuses the
unmanaged-to-managed flip while the window's desired WM_STATE is not
Withdrawn. The managed decision is made at map time; a mapped window
keeps its mode until withdrawn and the next map re-evaluates. Legitimate
flips are unaffected: a hidden window shown activated passes because its
desired WM_STATE is still Withdrawn when the flip runs (the map request
comes later in the same SetWindowPos), `make_window_embedded` withdraws
explicitly first, and the desktop window is created withdrawn. The
reverse direction was already refused outright.

## Verification

- Compile: full series 0001-0039 applies on base 7ea0c8b7; winex11
  builds clean.
- Runtime: open Preferences on GNOME/Cinnamon/KDE, work every dropdown
  including under fullscreen. With the patch the trace must show no
  `window_set_managed ... override-redirect 1 -> 0` on any popup while
  it is mapped, and the canary `WINEDEBUG=warn+x11drv` logs
  "is mapped, refusing to make it managed" each time the gate declines
  a flip.
- The build-audit fingerprint for 0039 greps that canary string in
  `winex11.so`.

## Known limits

Patch 0038 (FocusOut gate) stays: it covers the win32u menu path, which
is a real, separate cancellation route even though Live's dropdowns do
not use it. If Live one day stops poking its popups, the 0039 gate
simply never fires.
