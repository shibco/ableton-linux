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
`WINE_X11_MIDDLE_DRAG=notch`, `WINE_X11_SMOOTH_SCROLL=notch`), which rounds
down to whole notches and carries the remainder into the next report. A
plugin editor that discards fractional wheel units can use this whole-notch
mode. Patch 0072 also accepts `WINE_X11_SMOOTH_SCROLL=off` to restore Wine's
original core button path entirely.

## Ctrl state comes from a key event

The server fills the `MK_CONTROL` bit in `WM_MOUSEWHEEL` from the desktop key
state in `server/queue.c`. `GetKeyState` and `GetAsyncKeyState` read the same
state. The pinch path therefore holds a real Ctrl key for the whole gesture:
one left Ctrl down at gesture begin, one up at gesture end, with the wheel
updates between them carrying no modifier of their own. Pressing and
releasing around every update instead would cost a wineserver round trip per
event and show the application a Ctrl key down/up pair for every tick. The
synthesized key is a left Ctrl, so an application querying `VK_LCONTROL`
agrees with `MK_CONTROL`.

A Ctrl the user already holds is left alone: gesture begin presses nothing,
and gesture end releases the synthesized key only when `XQueryKeymap` shows
no physical Ctrl down, because `GetAsyncKeyState` cannot tell a synthesized
press from a physical one. A begin that arrives while a synthesized Ctrl is
still held (a lost end) reuses it instead of pressing twice.

The middle drag adds no modifier. Ctrl held during the drag reaches the
message through the same key state, so Live zooms instead of scrolling.

## 0070: middle-button drag

`WINE_X11_MIDDLE_DRAG=navigate` holds the middle-button press back from the
application. It reports vertical movement as wheel input and horizontal
movement as horizontal-wheel input at the press position. One whole notch
represents 24 raw virtual-screen pixels: `map_event_coords` reports
`MDT_RAW_DPI` coordinates with no DPI normalization, so a notch is a fixed
physical distance and covers less of a window's content the more the display
is scaled up. Live sees the pointer at the press position during the drag.

The driver measures the 3 raw-pixel drag threshold from the press position.
Motion inside that threshold produces no wheel input. A press that stays
inside the threshold is replayed as `WM_MBUTTONDOWN` followed by
`WM_MBUTTONUP` on release, the down stamped with the time and position of
the original press, so a held middle button keeps its hold duration. A
completed drag sends one final pointer move that updates Wine's cursor
position to the X11 release coordinates. Replay and the cursor sync use the
window and origin recorded at the press.

Pressing another button during a drag ends it instead of corrupting into a
phantom click: a drag that reported wheel movement syncs the cursor to the
real pointer position, a press that never moved is replayed as a click, and
the new press and the movement that follows it go through, so placing the
cursor with the left button while panning with the middle one works. A
pending click is flushed on every abort path, including a lost release and
a stale re-begin.

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
handler stores the scale already reported per XInput2 device and sends the
difference as wheel movement, so two concurrent pinch sources do not
interleave updates against one baseline. One whole notch represents 1.1x.
Two pinches with the same start and end scale produce the same total wheel
movement, regardless of their event rate. A 2.5x spread arrives as roughly
thirty reports of 12 to 60 units each. The wheel position is the pointer
position frozen at gesture begin, not the pinch focal point: a precision
touchpad pinch never moves the cursor, but the focal point wanders with the
fingers, and reporting it would drag the cursor across the screen.

Gesture events need XInput2 2.4. Wine asks the server for 2.2, and the
server refuses gesture selection for a client that asked for less, so
`x11drv_xinput2_init` raises the request to 2.4 only when the feature is
wanted. `WINE_X11_PINCH_ZOOM=off` keeps it at 2.2 and changes nothing else;
an unrecognized value warns once and disables the feature. An older X server
(before Xorg 21.1) logs a warning and behaves as before. Headers without the
gesture definitions compile the path out, with a warning when the feature is
asked for.

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
each Wine window, except windows whose core event mask has no pointer events:
`get_window_attributes` leaves those off `WS_EX_TRANSPARENT` windows so
clicks fall through, and an XI selection would make such a window a delivery
target again. It tracks the source device's preferred vertical and horizontal
scroll axes and reports each change as `WHEEL_DELTA * change / increment`.
Rounding only to a single Win32 wheel unit and carrying the remainder preserves
small movements instead of waiting for a notch. Vertical XInput2 scroll has the
opposite sign from Win32 wheel input; horizontal scroll has the same sign.
Both wheel paths update the window user time, so focus-stealing prevention
keeps tracking scrolling as user activity.

Selecting a master-device XI event prevents the X server from delivering its
core equivalent. The handler therefore reconstructs a core event for every
non-scroll XI motion or button press/release and feeds it through Wine's
existing handlers. A report that carries pointer motion next to the scroll
axes forwards the motion too. This preserves pointer motion, left/right/middle
clicks, extra buttons, activation timestamps, button state, and the optional
middle drag. Handling release symmetrically is required because an XI button
press starts an implicit grab; selecting only the press loses its matching
release.

Core wheel button events are left alone: outside a grab the server's
per-client suppression already keeps their emulated duplicates from arriving
twice, and during a core grab (popup menu tracking, interactive move/size,
`ClipCursor`) the server delivers only core events, so dropping them would
kill wheel scrolling entirely. X servers mark the legacy XI button event
synthesized from a native scroll valuator with `XIPointerEmulated`. The
handler consumes that duplicate while still translating original XI wheel
buttons from an ordinary physical wheel.

While any button is held, the valuator path reports nothing: a clickpad
thumb-hold with a moving finger is classified as two-finger scroll, and
fractional wheel input with `MK_LBUTTON` set would steer the control being
dragged (macOS delivers no scroll during a drag either). The cumulative
baselines still advance while the button is held, so the first scroll after
the release does not jump by the dragged distance. Physical wheel notches
(native XI scroll buttons) are deliberate input and are still delivered
while a button is held.

Each slave device's scroll axes and cumulative baselines are kept in a small
per-source cache, refreshed on `XI_DeviceChanged`. A device is queried once,
the first time it reports; alternating between a mouse and a touchpad then
costs no X round trip and does not discard the first movement after the
switch. A single report cannot exceed sixteen notches.

Smooth scrolling defaults to on when the build headers and X server support
XInput2 2.1 scroll classes. `WINE_X11_SMOOTH_SCROLL=off` restores the original
core button-to-wheel route for comparison; `=notch` keeps the smooth path but
reports only whole notches, carrying the remainder into the next report.

## 0072: scroll inertia

When a gesture's reports stop, its final velocity decays into further wheel
input, the way macOS keeps scrolling after a flick. Each report pushes what
the application was actually sent (post-remainder, post-clamp) into an
eight-sample ring; a lazily created thread wakes on the first report of a
gesture, polls every 16 ms, and once input has been quiet for 50 ms starts a
fling from the sum of the trailing 100 ms of samples. The fling ticks every
16 ms, emits at the last scroll position through the same wheel-input path
keeping a per-axis remainder, and ends below 30 wheel units a second, after
3 seconds, or when cancelled. A fling needs 60 wheel units a second (half a
notch) to start and never restarts: entering it consumes the samples, and
every cancellation bumps a generation counter the fling checks each tick.

Three environment variables control inertia, parsed once:

- `WINE_X11_SCROLL_INERTIA=on|off` (default on; unrecognized values warn
  once and fall back to on).
- `WINE_X11_SCROLL_INERTIA_FRICTION=<float>`, the exponential decay
  coefficient k in 1/s, the fraction of velocity lost per second (default
  3.0, which halves the velocity about every 230 ms; for the linear curve it
  scales the constant deceleration so both curves share their initial
  slope).
- `WINE_X11_SCROLL_INERTIA_CURVE=expo|linear` (default expo, `v *=
  exp(-k * dt)` per tick; unrecognized values warn once and fall back to
  expo).

Inertia applies only to the smooth valuator path: not to physical wheel
notches, and not in `WINE_X11_SMOOTH_SCROLL=notch` mode. Cancellation is
instant on any new native scroll report, on any button press (core or XI),
on a scroll report for another window, and on Ctrl held, which covers both a
pinch zoom and a manual Ctrl+wheel. No samples are gathered while a button
is held, so a fling can neither run nor start during a drag.

The thread only makes wineserver calls (the X display belongs to the event
thread), the shared state is a small static block under one pthread mutex,
and the wineserver event handle is signaled only on the idle-to-active
transition, once per gesture.

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
physical touchpads under Xorg and XWayland is not verified. Scroll inertia
was added after that build and has not been runtime-tested at all.

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
   `WINE_X11_PINCH_ZOOM=notch`, `WINE_X11_MIDDLE_DRAG=notch`, and
   `WINE_X11_SMOOTH_SCROLL=notch` exist for the second case.
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
grep -E "pinch|scale|MOUSEWHEEL" /tmp/live-input.log
```

For the middle drag, add `WINE_X11_MIDDLE_DRAG=navigate` to the launch and
grep for `begin at`, `wheel delta`, `hwheel delta`, and `end, moved` in the
same log.

For two-finger panning, run `/tmp/pinchgen up 60` and
`/tmp/pinchgen left 60`, then grep for `smooth scroll delta`; a flick fast
enough to start inertia also logs `fling start velocity`. Repeat once with
`WINE_X11_SMOOTH_SCROLL=off`; the smooth path should produce smaller deltas
at the higher event rate, while the fallback returns whole notches.
