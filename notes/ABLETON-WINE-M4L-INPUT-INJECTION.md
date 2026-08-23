# Max for Live fader jumps

The cursor repair in patch 0100 addresses
[Ableton Linux issue 122](https://github.com/shibco/ableton-linux/issues/122).

## Test status

Patch 0100 passes the build checks. Test patch 0100 on the affected Fedora
computer.

## Reported behaviour

Issue 122 reports fader jumps after a Max for Live device loads. The pointer
moves smoothly while the fader crosses its range.

During the reported fault, a Max for Live window briefly receives pointer
control. The repair addresses stale cursor state after control returns to Live.

## Cursor repair

Patch 0100 releases cursor clipping when another process receives X input
focus. It resets cursor state before a window confines the pointer again.

## Fedora test

Use a computer that shows the problem:

1. Install a build that contains patch 0100.
2. Start a fresh Live session with:

   ```bash
   env WINEDEBUG=-all,+event ableton-live
   ```

3. Load the affected Max for Live device. Leave its panel untouched.
4. Drag the track volume fader in Session View.

The fader follows the pointer smoothly. A clipping recovery writes this event
log message:

```text
lost X focus to another client while clipping
```

Report the device, Linux distribution, desktop, Live version, and result.

Use an Xorg or XWayland session. The repair uses X11 focus and cursor clipping.
