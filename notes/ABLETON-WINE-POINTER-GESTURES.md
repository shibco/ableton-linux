# Pointer behaviour and checks

Wine uses 120 units for one wheel step.

## Defaults

By default, Live provides:

- smooth vertical and horizontal scrolling;
- pinch zoom;
- middle-button drag navigation;
- scrolling inertia after a quick release;
- continued movement after releasing a moving middle-button drag; and
- normal mouse-wheel clicks while another button is held, except during
  middle-button navigation.

Left-button fader, slider and knob drags use a separate control-motion path.
Wine keeps the desktop's processed pointer delta, carries fractional pixels,
and forwards each physical delta once. It adds no smoothing, acceleration,
sensitivity multiplier or gesture continuation. This path is the same for a
mouse, a clickpad with one finger, and a clickpad with another finger present.

`TouchpadInertia` affects scrolling after release. `MiddleDragThrow` affects
middle-button movement after release. Turning either one off leaves direct
scrolling and direct middle-button navigation unchanged.

The older optional XWayland correction still defaults to `disabled`. Held LMB
control drags bypass its warp classifier and reanchor directly when the
application calls `SetCursorPos`. KDE/XWayland, GNOME/XWayland and Xorg
hands-on checks remain open.

## Settings

| Setting | Launch variable | Default | Choices |
| --- | --- | --- | --- |
| `SmoothScrolling` | `WINE_X11_SMOOTH_SCROLLING` | `precise` | `disabled`, `precise`, `notched` |
| `TouchpadInertia` | `WINE_X11_TOUCHPAD_INERTIA` | `enabled` | `disabled`, `auto`, `enabled` |
| `PinchZoom` | `WINE_X11_PINCH_ZOOM` | `legacy-wheel` | `disabled`, `legacy-wheel` |
| `MiddleDrag` | `WINE_X11_MIDDLE_DRAG` | `navigate` | `disabled`, `navigate`, `navigate-notched` |
| `MiddleDragThrow` | `WINE_X11_MIDDLE_DRAG_THROW` | `enabled` | `disabled`, `enabled` |
| `WheelWhileButtonHeld` | `WINE_X11_WHEEL_WHILE_BUTTON_HELD` | `enabled` | `disabled`, `enabled` |
| `InertiaCurve` | `WINE_X11_INERTIA_CURVE` | `exponential` | `exponential`, `linear` |
| `InertiaRate` | `WINE_X11_INERTIA_RATE` | `4.0` | 0.5 to 16.0 |
| `WarpEmulation` | `WINE_X11_WARP_EMULATION` | `disabled` | `disabled`, `auto`, `enabled` |

The launcher sets none of these variables. A launch variable overrides a saved
choice for that launch. Named values ignore letter case. `off` and `0` mean
`disabled` where supported. Wine reports an invalid value in the normal launch
log, then tries the saved choice or default.

`TouchpadInertia=auto` currently behaves like `disabled` on X11.
Lower `InertiaRate` values keep continued movement going for longer. Higher
values stop it sooner.

## Safety rules

- A mouse-button press stops older scrolling inertia or middle-drag throw.
- While LMB is held, Wine forwards only processed pointer displacement. It
  applies unit gain, carries subpixel remainder, and rejects duplicate core,
  XI2 and clipped-motion copies. Scroll valuators, physical wheel input, pinch
  and inertia cannot enter that control drag or appear after release.
- A physical mouse wheel still works while a non-LMB button is held, except
  during middle-button navigation. It is always blocked during an LMB control
  drag, regardless of `WheelWhileButtonHeld`.
- Middle-button navigation works only while its own middle button remains held.
  Another button press stops it.
- Continued movement stays at the window and point where it began. It cannot
  follow the pointer to another control.
- New pointer or key input stops continued movement. Focus or window changes
  and removed devices also stop it.
- Wine keeps at most one continued update waiting. Movement does not build up or
  replay after a pause.

## Limits

| Behaviour | Limit |
| --- | --- |
| Direct smooth scroll | 120 units per axis for one update |
| Direct middle-button drag | 120 units per axis for one update |
| Pinch update | 120 units |
| Largest accepted scroll jump | 240 units |
| Normal inertia start speed | 240 units per second |
| Start speed after 100 ms without more scrolling | 480 units per second |
| Maximum starting speed | 19,200 units per second |
| Largest continued update | 300 units per axis |
| Maximum continued travel | 4,800 units per axis, 7,200 units in total |
| Maximum continued updates sent to Live | 384 |
| Maximum continued time | 4 seconds |
| Movement used to judge a middle-drag throw | Latest 100 ms |
| Longest gap between movements or before release | 80 ms |
| Minimum timed movement span | 10 ms |
| Time assigned when movement updates share one time | 24 ms |
| Minimum movement when updates share one time | 4 pixels |

If Wine receives no clear end report, `TouchpadInertia=enabled` may begin
inertia after 100 ms without more scrolling. This requires the higher start
speed shown above.

Middle-drag throw uses all movement in the final 100 ms when it spans at least
10 ms. A gap longer than 80 ms starts a new final movement, and a pause longer
than 80 ms before release prevents the throw. When the desktop sends one
movement update, or several updates with the same time, Wine assigns a 24 ms
span and requires four pixels of movement. A cancelled drag or extra button
press stops the throw.

## Source checks

Run these commands from the repository root:

```bash
make check
make verify
```

`make check` reads the pointer patches and tests their maths. `make verify`
also checks the saved source files. Neither command starts Wine or Live. The
hands-on checks below remain required.

## Hands-on checks

Mute or disconnect monitoring before a check that can change volume. Start
with Live's Master fader low.

1. Drag faders and knobs with LMB using a mouse and a touchpad. Repeat at slow
   and fast speeds. One physical pixel of vertical travel must produce the same
   control travel; no Wine acceleration, smoothing or sensitivity transition
   may appear after press, during movement or at release.
2. Load an affected Max for Live device without clicking its panel. A Live
   fader must still follow the pointer. Repeat after clicking the device once.
3. Hold a fader with LMB. Drag with one touchpad finger, add a stationary second
   finger, then move either finger and try two-finger scrolling and pinch. The
   fader must follow only pointer displacement at the same rate as step 1.
   Gesture reports must not change it during the drag or after release.
4. Hold LMB and turn a physical mouse wheel; the wheel must not reach the held
   control. Hold RMB and repeat: the wheel works by default and stops with
   `WheelWhileButtonHeld=disabled`.
5. Make a fast smooth scroll. The view must keep moving, slow gradually and stay
   within the limits above. New input must stop it. Repeat with
   `TouchpadInertia=disabled`; direct scrolling must feel the same but stop with
   the touchpad or wheel.
6. Release a moving middle-button drag. Repeat with a short drag and a gentle
   curve. The view must keep moving only after release. A click, a drag held
   still for more than 80 ms, a cancelled drag or an extra button press must
   not start a throw. Repeat with `MiddleDragThrow=disabled`; direct navigation
   must remain unchanged and stop at release.
7. Pinch in and out, including while holding Ctrl. Live must zoom and leave the
   physical Ctrl state unchanged. A cancelled pinch must stop zooming.
8. If Live pauses while loading a plug-in or browser folder during a fast
   scroll, it must not replay missed movement when it responds.
9. Repeat the held-control, inertia and throw checks in Live's main window and
   in a separate plug-in window.
10. Run the fader and knob checks on KDE/XWayland, GNOME/XWayland and Xorg. On
    XWayland, compare `WarpEmulation=disabled`, `auto` and `enabled` with the
    pointer shown and hidden. No setting may double the control's movement.

Record the pointing device, Linux distribution, desktop, Xorg or XWayland,
Live version, setting and result for each check.

## Known limits

- Wine cannot tell whether smooth scrolling came from a touchpad, a precision
  mouse wheel or a free-spinning wheel. All three may keep moving after input
  stops. Set `TouchpadInertia=disabled` to turn this off.
- On KDE/XWayland, inertia may start 100 ms after scrolling stops because the
  desktop may omit the end report.
- This work applies when Live runs through Xorg or XWayland. It does not apply
  when Live runs directly through Wayland.
- Hands-on held-LMB comparison across KDE/XWayland, GNOME/XWayland and Xorg,
  including the affected Fedora computer, remains open.
