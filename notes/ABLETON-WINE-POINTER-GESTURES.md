# Touchpad pinch zoom and middle-button drag navigation

Two requests for pointer navigation Live does not receive under Wine:

- Issue 64: a touchpad pinch does not zoom. Ctrl+scroll is the only way in.
- Issue 50: the middle button does nothing. Other DAWs navigate with it.

Both are answered in `winex11.drv` by patches 0070 and 0071, because both
need input that Live already understands: the wheel.

## What Live reacts to

Live zooms on Ctrl+wheel, scrolls on the wheel, and scrolls sideways on the
horizontal wheel. It has no gesture API of its own, and it has no
middle-button action. So the question for both requests is not what Live
should learn, but what input the driver should report for a gesture or a
drag.

Windows answers the same way for pinch. A precision touchpad translates a
pinch into wheel input with Ctrl held for any application that does not
handle the gesture itself, which is why pinch zoom works in Live on Windows
without Live implementing anything. Reporting the same input here is
therefore parity, not an invention.

The middle-button drag has no Windows equivalent. It comes from Bitwig, and
it stays off unless it is asked for.

## A notch is a unit, not a minimum

`WHEEL_DELTA` is 120 because a wheel notch was once the smallest movement a
mouse could report. A precision touchpad reports part of one, and so do
these two features: a pinch reports its scale many times a second, and a
drag moves a few pixels at a time. Sending only whole notches is what made
the first version of the pinch zoom arrive in visible steps.

Live follows the amount rather than counting messages, so reporting each
fraction as it arrives zooms and scrolls continuously. An application that
divides by `WHEEL_DELTA` and discards the rest would see nothing instead, so
both features take `notch` as a value (`WINE_X11_PINCH_ZOOM=notch`,
`WINE_X11_MIDDLE_DRAG=notch`), which rounds down to whole notches and
carries the remainder into the next report. Plugin editors, which these
patches also cover, are the reason to keep that fallback.

## Ctrl has to be a key event

The `MK_CONTROL` bit in `WM_MOUSEWHEEL` is not a flag winex11 can set. The
server fills it from the desktop key state (`server/queue.c`), the same
state `GetKeyState` and `GetAsyncKeyState` read. An application may consult
either one, so the pinch path presses and releases a real Ctrl key around
the wheel input, and leaves a Ctrl the user is already holding alone.

The middle drag adds no modifier at all, which gives it zoom for free: a
Ctrl the user holds during a drag reaches the message through that same key
state, so the drag then does whatever the application does for Ctrl+wheel.

## 0071: pinch gestures

A touchpad pinch reaches the X server as an XInput2 gesture. winex11 never
selected those events, so the X server dropped them.

The gesture masks are selected on each top-level window, next to the touch
events already selected there in `x11drv_xinput2_enable`. Selecting on the
root window instead would also catch pinches over other applications'
windows.

`XIGesturePinchEvent.scale` is the scale since the gesture began, so the
handler keeps the scale it has already reported and sends the difference as
wheel movement, a whole notch standing for 1.1x. Tracking the running scale
rather than each event's delta keeps a slow pinch and a fast pinch of the
same size worth the same amount of wheel, and reporting the fraction each
update is worth is what makes the zoom continuous rather than stepped: a
2.5x spread arrives as roughly thirty reports of 12 to 60 units each.

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

## 0070: middle-button drag

`WINE_X11_MIDDLE_DRAG=navigate` holds the middle-button press back from the
application and reports what follows as wheel input at the position the press
landed on: vertical movement as wheel, horizontal movement as horizontal
wheel, a whole notch standing for 24 px. Both axes scroll, which is what the
gesture is for; zoom stays on Ctrl, held by the user rather than added here.
The movement is measured in the window's own coordinates rather than X root
pixels, so display scale does not change how far a notch is. Reporting at the
press position keeps the scroll anchored where the drag started, and the
movement itself is not forwarded, so the pointer Live sees stays there for
the duration.

A press that never moves more than 3 px is replayed as `WM_MBUTTONDOWN`
followed by `WM_MBUTTONUP` on release, so a plain middle click still
reaches the application. A drag that starts while another button is down is
left alone entirely.

The drag ends on the middle-button release. If that release is delivered
somewhere else, the next motion event without `Button2Mask` ends it.

## What was measured

Both patches are in the runtime and pass the build audit (94 checks, both
fingerprint strings present in `winex11.so`).

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

- Sideways middle-drag scrolls the Arrangement, so Live does act on
  `WM_MOUSEHWHEEL`. This is what settled the horizontal mapping.
- Vertical middle-drag first reported Ctrl+wheel, which zoomed. Zoom on the
  vertical axis was wrong for the gesture, so it is plain wheel now and both
  axes scroll (Theo, 2026-08-08).
- Whole notches made the pinch zoom arrive in visible steps. Reporting each
  gesture update as its fraction of a notch made it continuous, confirming
  that Live follows the amount rather than counting messages (Theo,
  2026-08-08). A 2.5x spread reports as roughly thirty updates of 12 to 60
  units.

## Still open

1. Plugin editors and Max for Live windows. Both features apply to every
   window in the process, not only Live's main window. A plugin with its own
   middle-button behaviour, or one that discards part of a notch, is worth
   checking before the middle drag is offered by default;
   `WINE_X11_PINCH_ZOOM=notch` and `WINE_X11_MIDDLE_DRAG=notch` exist for the
   second case.
2. Whether the middle drag should default to on. It is off because nothing on
   Windows behaves this way; the pinch is on because a Windows precision
   touchpad sends exactly this.
3. Whether 24 px per notch and 1.1x per notch are the right sensitivities on
   other hardware. Both are single constants in `mouse.c`.

## Repeating the checks

```bash
gcc -O2 -o /tmp/pinchgen tools/pinchgen.c
WINEDEBUG=+cursor,+message ableton-live 2> /tmp/live-input.log
# put the pointer over Live's arrangement, then:
/tmp/pinchgen out 24
grep -E "GesturePinchEvent|MOUSEWHEEL dispatched" /tmp/live-input.log
```

For the middle drag, add `WINE_X11_MIDDLE_DRAG=navigate` to the launch and
grep for `middle_drag` and `MOUSEHWHEEL` in the same log.
