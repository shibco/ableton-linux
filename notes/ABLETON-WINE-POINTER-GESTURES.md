# Pointer behaviour and tests

Wine uses its X11 driver for Ableton Live sessions on Xorg and XWayland. The
driver provides precise scrolling, gestures, inertia, and drag recovery.

Wine assigns the `unknown` source class to each XI2 smooth scroll device. The
enabled inertia setting therefore applies to touchpads and high-resolution
wheels.

## Default behaviour

The default X11 configuration provides:

- precise vertical and horizontal scrolling
- pinch zoom through Ctrl-tagged wheel input
- middle-button navigation and release throw
- scrolling inertia after a quick gesture
- physical wheel input during another button press
- drag recovery across windows and focus changes
- XWayland pointer correction after 2 pointer warps leave the pointer at its
  source position
- cursor recovery after focus moves to another process

One wheel notch equals 120 Windows wheel units. Wine preserves partial units.
Wine divides large reports into signed packets whose total matches the source.

## Configuration

| Registry setting | Launch variable | Default | Accepted values |
| --- | --- | --- | --- |
| `SmoothScrolling` | `WINE_X11_SMOOTH_SCROLLING` | `precise` | `disabled`, `precise`, `notched` |
| `TouchpadInertia` | `WINE_X11_TOUCHPAD_INERTIA` | `enabled` | `disabled`, `auto`, `enabled` |
| `PinchZoom` | `WINE_X11_PINCH_ZOOM` | `legacy-wheel` | `disabled`, `legacy-wheel` |
| `MiddleDrag` | `WINE_X11_MIDDLE_DRAG` | `navigate` | `disabled`, `navigate`, `navigate-notched` |
| `MiddleDragThrow` | `WINE_X11_MIDDLE_DRAG_THROW` | `enabled` | `disabled`, `enabled` |
| `WheelWhileButtonHeld` | `WINE_X11_WHEEL_WHILE_BUTTON_HELD` | `enabled` | `disabled`, `enabled` |
| `InertiaCurve` | `WINE_X11_INERTIA_CURVE` | `exponential` | `exponential`, `linear` |
| `InertiaRate` | `WINE_X11_INERTIA_RATE` | `4.0` | 0.5 to 16.0 |
| `WarpEmulation` | `WINE_X11_WARP_EMULATION` | `auto` | `disabled`, `auto`, `enabled` |
| all pointer features | `WINE_X11_POINTER_FEATURES` | enabled | `disabled`, `off`, `0` |

Wine reads the registry settings when its X11 driver starts. A launch variable
overrides its registry setting for one launch. Wine accepts lower-case and
upper-case named values.

`TouchpadInertia=auto` selects direct scrolling for XI2.
`TouchpadInertia=enabled` uses a repeated cumulative value or a 90 ms pause as
an end signal. Lower `InertiaRate` values give a longer coast.

Set `WINE_X11_POINTER_FEATURES=disabled` to select Wine's standard pointer
handling for one launch.

## Smooth scrolling

XI2 reports a cumulative value and an increment for each scroll axis. Wine
converts each value change into Windows wheel units.

Wine stores one baseline for each XI2 source and axis. It preserves every
fractional remainder. Wine treats each finite value change as movement. Wine
splits large output at the signed Windows packet limit.

Wine drops duplicate core wheel events from the same XI2 scroll report. Wine
sends direct movement through its standard input path.

A 241-unit report produces 241 units. One 480-unit report produces the same
total as 4 120-unit reports.

## Drag recovery

During a drag, Wine routes pointer motion through core X11 for mouse buttons 1
to 3. Wine restores XI2 motion after these events:

- the matching button release
- a release on another window
- a focus or capture change
- window destruction
- a device hierarchy change
- later motion or wheel input that reports released buttons

Wine reads the physical X button state when the release differs from the saved
drag. Wine then restores XI2 motion and clears the saved drag state.

## Pinch zoom

Wine captures the target window at gesture start. Each update converts the
absolute XI2 scale into logarithmic Ctrl-tagged wheel movement.

Wine provides Ctrl state during the gesture for applications that query
keyboard state. Every gesture end and input reset restores that state. A
cancelled gesture keeps the zoom already applied.

## Middle button navigation

Wine delays the middle-button press until movement crosses the system drag
distance. Movement inside that distance produces one middle click.

A drag converts the complete horizontal and vertical pixel distance into
wheel movement. Wine stores each fractional remainder for the next event. One
48-pixel event therefore matches 2 24-pixel events.

A moving release starts middle-button throw when its speed meets the threshold.
`MiddleDragThrow=disabled` ends movement at release.

## Scrolling inertia

The process uses one timer for one active coast. The timer posts one update to
the owning window thread.

Wine uses up to 12 samples from the final 110 ms. It merges equal timestamps.
A backward timestamp starts a new sample history. A final direction reversal
selects the later samples.

Wine calculates each position from the complete elapsed time. Timer delay
changes update timing. The analytic calculation keeps final travel consistent.

Keyboard input, pointer input, focus changes, capture changes, window changes,
thread exit, and device changes end the coast.

| Coast limit | Value |
| --- | ---: |
| start speed | 180 wheel units per second |
| stop speed | 60 wheel units per second |
| maximum start speed | 19,200 wheel units per second |
| packet movement | 300 wheel units per axis |
| travel per axis | 4,800 wheel units |
| combined travel | 7,200 wheel units |
| message count | 384 |
| duration | 4 seconds |

## XWayland pointer correction

Live repeatedly moves the pointer during relative fader and knob drags.
`WarpEmulation=auto` starts correction after 2 pointer moves leave the pointer
at its source position.

Wine uses its standard path when Xorg or XWayland moves the pointer. Wine resets
correction after button, focus, capture, cursor, device, and thread changes. A
release uses the same coordinate model as its drag motion.

## Drag and drop

Patch 0101 uses a separate Windows drag transaction. It releases the target
after drag leave and every drop. The first X11 status uses the effect from the
initial target entry.

## Automated tests

Run these commands from the repository root:

```bash
make check
make verify
```

`make check` tests input calculations and conversion rules. Cases include
119, 120, 121, 239, 240, and 241-unit boundaries. The tests cover report
grouping, fractions, pinch scale, drag recovery, inertia, and timer delays.

`make verify` checks vendor files and stored hashes. Physical hardware
completes the XI2 scroll and pinch tests.

## Live tests

Mute or disconnect monitoring before a volume test. Set the Live Master fader
to a low value.

Run the tests in this order.

1. Scroll slowly and quickly in the Arrangement and Browser views.
   Confirm that faster input gives equal or greater direct movement.
2. Move the same distance with one fast gesture and several slower gestures.
   Confirm the same final content distance.
3. Start a drag in one child window and release over another child window.
   Confirm immediate smooth scrolling and middle-button navigation.
4. Open a dialogue during a drag. Confirm pointer recovery.
5. Close a plug-in window during a drag. Confirm pointer recovery.
6. Hold the left or right button and turn a physical wheel.
   Confirm standard wheel movement.
7. Pinch with physical Ctrl released, then repeat with physical Ctrl pressed.
   Confirm that Ctrl returns to its original state.
8. Compare one 48-pixel middle drag with 2 24-pixel movements.
   Confirm equal content travel and a release throw.
9. Make slow and fast 2-finger scrolls.
   Confirm immediate direct movement and a coast after a quick release.
10. Test faders and knobs with each `WarpEmulation` value.
   Confirm that control travel follows pointer travel.
11. Start Live with `WINE_X11_POINTER_FEATURES=disabled`.
    Confirm Wine's standard wheel, button, capture, and focus routing.
12. Repeat accepted and rejected external file drops 500 times.
    Confirm that each drop completes with the expected result.

Record the device, desktop, session type, scale, Live version, setting, trace
sequence, and result.

## Hardware coverage

Wine assigns `unknown` to every XI2 smooth source. The enabled inertia setting
therefore adds a coast to high-resolution and free-spinning wheels.

Middle-button navigation uses raw virtual-screen pixels. Display scale
determines content distance for the same raw pixel movement.

XTEST covers core-button cases. Physical devices provide XI2 scroll and pinch
coverage. The issue 122 test requires the affected Fedora computer.
