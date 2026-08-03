# M4L devices make Live's sliders erratic (issue 122)

This note explains why loading a Max for Live device can corrupt mouse
dragging in Live's own interface, what patch 0066 changes, and how to
verify the fix. Written 2026-08-03 from the diagnosis in issue 122.

## Status

Patch 0066 (`winex11: release stale cursor clipping state when X focus
leaves the process`) is committed on this branch. The series applies,
the build passes the full audit, and `winex11.so` compiles without
warnings. Runtime verification is still open: the bug does not
reproduce on the development machine, so the patch is validated against
the traced mechanism, not against the live symptom.

## How to verify the fix

Verification needs a machine that shows the bug (the Fedora report, or
trendwhore's setup).

1. Install a build that contains patch 0066.
2. Start Live with `WINEDEBUG=-all,+event` and a fresh session.
3. Load any Max for Live device onto a track. Do not click the device
   panel at any point.
4. Drag the track volume fader in session view.

Expected results: the fader follows the pointer normally, and when the
fix has actually fired the log contains the line

    lost X focus to another client while clipping

That string is also the patch's build-audit fingerprint. A report that
shows normal dragging plus that line confirms both the bug and the fix
on that machine.

## Symptom

After an M4L device is added to a track, dragging Live's sliders makes
the value jump wildly while the mouse pointer itself moves smoothly.
Frame analysis of trendwhore's recording shows the track volume moving
from -23 dB to 0.0 dB to -inf dB to -50 dB to -33 dB within about
270 ms of one smooth downward drag. Hovering over the device changes
nothing. Giving the embedded device window focus once restores normal
behaviour for the rest of the session. trendwhore proved the focus part
in isolation: a programmatic focus transfer with no mouse or capture
events heals the session permanently.

The affected device UI is a JUCE window owned by a separate process
and embedded into Live's window. In the traced session the bundled DS
devices run in `Ableton AddOns.exe`; `.amxd` devices load the Max
runtime. The mechanism below only needs "a second process embedded
into Live's window tree", so it applies to both.

## Background: the three pieces of Wine state involved

Three Wine mechanisms interact here. Each is healthy on its own.

- **Cursor clipping.** When a Windows program calls `ClipCursor`, Wine
  confines the pointer to a rectangle. In winex11 the process that owns
  the foreground window takes an X11 pointer grab (an exclusive claim
  on all pointer input) on a hidden helper window, the clip window.
  Live calls `ClipCursor` routinely during normal interaction: in a
  short healthy session the clip-release helper
  `ungrab_clipping_window` ran 49 times in the desktop process and 14
  times in Live.
- **Raw motion.** While a process clips the cursor, it stops using
  ordinary X11 motion events for positions. It selects XInput2 raw
  motion events (unscaled hardware deltas delivered for every physical
  mouse movement, screen-wide) and turns those deltas into pointer
  positions itself, in `map_raw_event_coords`. The per-thread flag
  `data->clipping_cursor` switches this conversion on. The conversion
  is only correct while the process actually holds the pointer grab.
- **Shared input state.** Live and the device host are separate
  processes, but embedding the device window calls `SetParent` across
  processes, and the wineserver then attaches both threads to one
  input state (`set_parent_window` in `server/window.c`). Focus,
  active window, and capture become shared between Live and the host.

## The fault

The clip-release notification is targeted, not broadcast. When the
clip rectangle changes, the wineserver sends `WM_WINE_CLIPCURSOR` to
the current foreground thread and, on reset, to the desktop thread
(`set_clip_rectangle` in `server/queue.c`). No other process is told.

That targeting creates a trap during device embedding:

1. Live loads the M4L device. The host process creates its window and
   the cross-process reparent begins.
2. The window manager briefly treats the host's not-yet-embedded
   window as the active one. The wineserver's foreground input flips
   to the host.
3. A clip change arrives in that window. The wineserver addresses
   `WM_WINE_CLIPCURSOR` at the host, and the host's thread takes the
   pointer grab and sets `data->clipping_cursor`.
4. Focus returns to Live. The release notification now goes to Live
   and the desktop thread. The host is never told.
5. The host's own X11 FocusOut events could still clean this up, but
   winex11 dismisses FocusOut during reparenting and during WM_STATE
   changes, which is exactly the state the embed dance is in. The
   grab itself dies soon after (for example when the clip window is
   unmapped), but the flags survive.

The host process now believes it is clipping. It has no grab, yet
`data->clipping_cursor` is set and raw motion stays selected from the
transient focus. From this point on, every physical mouse movement
anywhere on screen delivers a raw delta to the host, and the host
converts it into an absolute pointer position accumulated from a
zeroed origin and feeds it into the wineserver's cursor stream through
`send_mouse_input`.

Live and the host now write the cursor position in turns: Live reports
correct positions from its own motion events, the host injects
positions computed from garbage. Live's controls read the merged
stream, so a fader drag jumps between the real position and nonsense.
The on-screen pointer is driven by the hardware and the X server, not
by this stream, so it keeps moving smoothly. That split, corrupt
values under a smooth pointer, is the recorded symptom.

Wine offered the stranded host three repair opportunities and each one
declined it before the patch:

| Repair opportunity | Why it did not fire |
|---|---|
| Later clip attempt in the host (`grab_clipping_window`) | The unfocused early-out reports success and touches nothing |
| Clip-window FocusOut handler | Unmapped the clip window but kept the flags set |
| Regular FocusOut on the host's windows | Dismissed by the reparenting and WM_STATE guards; the processed path only releases the grab for virtual desktops and keyboard grabs |

## Why focusing the device heals a session

A focus pass through the embedded JUCE child makes the host thread the
target of the clip bookkeeping once. Processing that traffic releases
the stale state. The leftover raw-motion selection is harmless on its
own, because raw frames carry no pointer movement while the clipping
flag is clear. This matches trendwhore's observation exactly: one
focus transfer, no mouse events, permanent recovery.

## Why many machines never see the bug

Arming requires the window manager to hand the host's window focus
during the embed. On the development machine (GNOME on Wayland) that
never happens: a `WINEDEBUG=+event,+cursor` trace of a full load-and-
drag session shows the device host processes receiving zero FocusIn,
FocusOut, raw motion, or clipping events. Environments whose window
managers focus new windows during the embed, and X11 sessions in
general, are exposed. High CPU load widens the timing window, which
matches the 25% DSP note in the original report.

## What patch 0066 changes

The patch enforces one invariant in winex11: local clipping state must
not outlive the X focus that justified it. It releases the grab and
clears the flags at each point where the process can observe the loss:

- `grab_clipping_window`: the "focus is in another process" early-out
  now releases local clipping state before reporting success.
- The clip-window FocusOut handler calls `ungrab_clipping_window`
  instead of only unmapping the window, so the flags follow the grab.
- Every FocusOut whose display shows another client's window holding
  the X input focus releases local clipping state, checked before the
  reparenting and WM_STATE guards can dismiss the event. When this
  actually releases a grab it logs the warning quoted above.

The XInput2 selection reference counts stay untouched on purpose. Once
the clipping flag is correct, a stale raw-motion selection only costs
wakeups.

The changed code is byte-identical between the vendor base and
upstream wine-11.13, so the patch is an upstream candidate once an
affected environment confirms it.
