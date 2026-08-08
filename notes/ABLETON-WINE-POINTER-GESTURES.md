# Pointer gestures under Wine

Patches 0070 through 0072 translate three pointer inputs into wheel messages
that Live already handles:

- Issue 64: a touchpad pinch does not zoom. Ctrl+scroll is the only way in.
- Issue 50: the middle button does nothing. Other DAWs navigate with it.
- PR 157 feedback: two-finger touchpad panning arrives in whole wheel steps
  rather than following the fingers.

## What Live reacts to

Live zooms on Ctrl+wheel, scrolls vertically on the wheel, and scrolls
sideways on the horizontal wheel. It has no gesture API or middle-button
action. The Wine X11 driver translates each pointer input into one of these
wheel messages.

A Windows precision touchpad translates a pinch into wheel input with Ctrl
held when the application does not handle the gesture. This is why pinch zoom
works in Live on Windows without Live implementing a gesture API. Patch 0071
reports the same input.

The middle-button drag follows Bitwig's navigation control and has no Windows
equivalent. It remains off by default.

## A notch is a unit, not a minimum

`WHEEL_DELTA` is 120 because a wheel notch was once the smallest movement a
mouse could report. A precision touchpad can report part of one. A pinch
reports its scale many times a second, and a middle drag moves a few pixels
at a time. Sending only whole notches made the first pinch implementation
and Wine's existing two-finger panning move in visible steps.

Live follows the amount rather than counting messages, so reporting each
fraction as it arrives zooms and scrolls continuously. An application that
divides by `WHEEL_DELTA` and discards the rest would see nothing instead, so
the translated features take `notch` as a value (`WINE_X11_PINCH_ZOOM=notch`,
`WINE_X11_MIDDLE_DRAG=notch`), which rounds down to whole notches and
carries the remainder into the next report. A plugin editor that discards
fractional wheel units can use this whole-notch mode. Patch 0072 instead
accepts `WINE_X11_SMOOTH_SCROLL=off` to restore Wine's original whole-notch
path.

## Ctrl state comes from a key event

The server fills the `MK_CONTROL` bit in `WM_MOUSEWHEEL` from the desktop key
state in `server/queue.c`. `GetKeyState` and `GetAsyncKeyState` read the same
state. The pinch path therefore presses and releases a Ctrl key around the
wheel input. It preserves a Ctrl key that the user is already holding.

The middle drag adds no modifier. Ctrl held during the drag reaches the
message through the same key state, so Live zooms instead of scrolling.

## 0070: middle-button drag

`WINE_X11_MIDDLE_DRAG=navigate` holds the middle-button press back from the
application. It reports vertical movement as wheel input and horizontal
movement as horizontal-wheel input at the press position. One whole notch
represents 24 px in the window's coordinates, so display scale does not
change the distance per notch. Live sees the pointer at the press position
during the drag.

The driver measures the 3 px drag threshold from the press position. Motion
inside that threshold produces no wheel input. A press that stays inside the
threshold is replayed as `WM_MBUTTONDOWN` followed by `WM_MBUTTONUP` on
release. A completed drag sends one final pointer move that updates Wine's
cursor position to the X11 release coordinates.

A drag that starts while another button is down uses Wine's normal button
path. The drag ends on the middle-button release. If another window receives
the release, the next motion event without `Button2Mask` ends the drag.

## 0071: pinch gestures

A touchpad pinch reaches the X server as an XInput2 gesture. Wine 11.13
selects touch events but omits the pinch gesture events, so the X server does
not deliver them.

The gesture masks are selected on each top-level window, next to the touch
events already selected there in `x11drv_xinput2_enable`. Selecting on the
root window instead would also catch pinches over other applications'
windows.

`XIGesturePinchEvent.scale` contains the scale since the gesture began. The
handler stores the scale already reported and sends the difference as wheel
movement. One whole notch represents 1.1x. Two pinches with the same start
and end scale produce the same total wheel movement, regardless of their
event rate. A 2.5x spread arrives as roughly thirty reports of 12 to 60 units
each.

Gesture events need XInput2 2.4. Wine asks the server for 2.2, and the
server refuses gesture selection for a client that asked for less, so
`x11drv_xinput2_init` raises the request to 2.4 only when the feature is
wanted. `WINE_X11_PINCH_ZOOM=off` keeps it at 2.2 and changes nothing else.
An older X server (before Xorg 21.1) logs a warning and behaves as before.

Requirements for the gesture to arrive at all:

- Xorg 21.1 or later with `xf86-input-libinput`, or XWayland 22.1 or later
  under a compositor that implements `wp_pointer_gestures` (Mutter and KWin
  both do).
- libXi 1.8 or later at build time. The build container ships 1.8.

## 0072: smooth two-finger panning

XInput2 2.1 exposes a touchpad or high-resolution wheel as scroll-valuator
classes. Scrolling then arrives in `XI_Motion` as a cumulative axis position,
and the class's `increment` says how much movement equals one wheel notch.
Wine previously consumed only the legacy button 4-7 events the X server
synthesizes when the cumulative movement crosses a whole scroll increment.
Live therefore received only whole `WHEEL_DELTA` reports.

The handler selects `XI_Motion`, `XI_ButtonPress`, and `XI_ButtonRelease` on
each Wine window, tracks the source device's preferred vertical and horizontal
scroll axes, and reports each change as `WHEEL_DELTA * change / increment`.
Rounding only to a single Win32 wheel unit and carrying the remainder preserves
small movements instead of waiting for a notch. Vertical XInput2 scroll has the
opposite sign from Win32 wheel input; horizontal scroll has the same sign.

Selecting a master-device XI event prevents the X server from delivering its
core equivalent. The handler therefore reconstructs a core event for every
non-scroll XI motion or button press/release and feeds it through Wine's
existing handlers. This preserves pointer motion, left/right/middle clicks,
extra buttons, activation timestamps, button state, and the optional middle
drag. Handling release symmetrically is required because an XI button press
starts an implicit grab; selecting only the press loses its matching release.

X servers mark the legacy XI button event synthesized from a native scroll
valuator with `XIPointerEmulated`. The handler consumes that duplicate while
still translating original XI wheel buttons from an ordinary physical wheel.
The first event establishes its cumulative baseline. Device-change events
replace the stored axis metadata. A single report cannot exceed sixteen
notches.

Smooth scrolling defaults to on when the build headers and X server support
XInput2 2.1 scroll classes. `WINE_X11_SMOOTH_SCROLL=off` restores the original
core button-to-wheel route for comparison.

## What was measured

Patches 0070 and 0071 were measured from X11 input through the messages
received by the application. Patch 0072 has the following build results:

- All 67 Wine patches apply in order with `git am`.
- `dlls/winex11.drv/mouse.c` compiles and `winex11.so` links against the pinned
  Wine source.
- The rebuilt release artifact passes the relocation and PipeASIO registration
  gate plus all 95 build-audit checks, including patch 0072's
  `WINE_X11_SMOOTH_SCROLL` fingerprint.
- With smooth scrolling enabled in an isolated XWayland runtime, ordinary
  motion reached `WM_MOUSEMOVE`, and injected left, middle, right, XBUTTON1,
  and XBUTTON2 input produced exactly five presses and five releases in Wine's
  existing button handlers. The application log showed paired Win32 down/up
  dispatch rather than the press-only behaviour from the broken patch.

Two-finger panning through patch 0072 has not been run in Live. Behaviour on
physical touchpads under Xorg and XWayland is not verified.

The input path was driven end to end on GNOME Shell 50.3 under Wayland,
through XWayland, against Notepad running under the built runtime, reading
the messages the application received with `WINEDEBUG=+cursor,+message`.
`tools/pinchgen.c` supplied the pinches through a virtual uinput touchpad;
`xdotool` supplied the middle-button drags. Messages seen there, in the
first, whole-notch version of both patches:

- XInput2 negotiates 2.4 on every thread display, and no X error follows the
  gesture selection.
- Spreading to 2.5x produced 9 `WM_MOUSEWHEEL` messages, each `wParam`
  `0x00780008`: one notch forward with `MK_CONTROL` set. Pinching back in
  produced 10 of `0xff880008`, one notch back.
- `WINE_X11_PINCH_ZOOM=off` held XInput2 at 2.2, and the same pinch produced
  no gesture events and no messages.
- A middle drag produced `WM_MOUSEWHEEL` and `WM_MOUSEHWHEEL` with
  `MK_MBUTTON` clear, confirming the press was held back; a press without
  movement produced the replayed `WM_MBUTTONDOWN` (`wParam` `0x0010`) and
  `WM_MBUTTONUP`; with the variable unset, only those two and no wheel.

Then Live itself, on the same machine, driving a real project:

- Sideways middle-drag scrolls the Arrangement. This confirms that Live acts
  on `WM_MOUSEHWHEEL` and uses the horizontal mapping.
- Vertical middle-drag first reported Ctrl+wheel, which zoomed. Zoom on the
  vertical axis was wrong for the gesture, so it is plain wheel now and both
  axes scroll (Theo, 2026-08-08).
- Whole notches made the pinch zoom arrive in visible steps. Reporting each
  gesture update as its fraction of a notch made it continuous, confirming
  that Live follows the amount rather than counting messages (Theo,
  2026-08-08). A 2.5x spread reports as roughly thirty updates of 12 to 60
  units.

## Still open

1. Plugin editors and Max for Live windows. All three features apply to every
   window in the process, not only Live's main window. A plugin with its own
   middle-button behaviour or one that discards part of a notch needs testing
   before the middle drag is offered by default.
   `WINE_X11_PINCH_ZOOM=notch` and `WINE_X11_MIDDLE_DRAG=notch` exist for the
   second case.
2. Whether the middle drag should default to on. It is off because nothing on
   Windows behaves this way; the pinch is on because a Windows precision
   touchpad sends exactly this.
3. Whether 24 px per notch and 1.1x per notch are the right sensitivities on
   other hardware. Both are single constants in `mouse.c`.
4. Compare 0072 on physical touchpads under Xorg and XWayland. The virtual
   device test covers the same libinput route but does not expose
   hardware-specific scroll increments.

## Repeating the checks

```bash
gcc -O2 -o /tmp/pinchgen tools/pinchgen.c
env WINEDEBUG=+cursor,+message ableton-live 2> /tmp/live-input.log
```

Put the pointer over Live's Arrangement, then run this in another terminal:

```bash
/tmp/pinchgen out 24
grep -E "GesturePinchEvent|MOUSEWHEEL dispatched" /tmp/live-input.log
```

For the middle drag, add `WINE_X11_MIDDLE_DRAG=navigate` to the launch and
grep for `middle_drag` and `MOUSEHWHEEL` in the same log.

For two-finger panning, run `/tmp/pinchgen up 60` and
`/tmp/pinchgen left 60`, then grep for `smooth scroll` and `MOUSEWHEEL` or
`MOUSEHWHEEL`. Repeat once with `WINE_X11_SMOOTH_SCROLL=off`; the smooth path
should produce smaller deltas at the higher event rate, while the fallback
returns whole notches.
