# Findings: no external signal during Live's live theme preview (issue 35 point 4)

## Question

Patches 0050/0051 plus `theme_watch_loop` (`scripts/ableton-live`) already fix
the "takes two restarts" bug: the watcher reacts to `Preferences.cfg` as soon
as it's written, no restart needed. But the win32u-drawn menu bar doesn't
follow Live's own (Skia) UI while the Preferences dialog is still open with
the theme toggle live-previewed - only once the dialog closes and
`Preferences.cfg` is written. Is there some other signal - a different file,
a registry write, anything - emitted during that live-preview window that a
watcher could react to instead?

## Method

With Live running normally against the real daily-use prefix, traced all
file activity during a live theme-preview window (Preferences open, theme
toggled back and forth repeatedly, dialog left open):

```
inotifywait -m -r --timefmt '%H:%M:%S' --format '%T %w%f %e' \
  ".../AppData/Roaming/Ableton/Live 12.4.3"
```

covering the whole per-version AppData tree, not just `Preferences.cfg`.
Also checked `~/works/plugs/studio/{system,user}.reg` mtimes before/after, in case
a registry write wasn't reflected in a file event.

## Result

- One file event fired: a `Log.txt` write, which was Ableton Link's own
  periodic network-discovery heartbeat - unrelated to the theme toggle,
  just coincidentally timed.
- `Preferences.cfg`: untouched for the whole window, confirming it only
  commits on dialog close.
- `user.reg`: untouched. `system.reg`: touched, but a full minute after the
  window closed with no correlation to any action taken - consistent with
  Wine's own periodic registry flush, not the toggle.

## Conclusion

Live's Settings UI repaints its own widgets in-process during live preview
and touches neither the filesystem, the registry, nor any other observable
channel until the dialog closes. `Preferences.cfg` isn't just the easiest
signal to watch - it's the only one that exists.

`theme_watch_loop` is already at the ceiling of what's reachable this way.
The remaining delay (while the dialog is open) can't be closed by a smarter
watcher - it would need Live itself (closed-source) to expose a live signal.
Issue 35 point 4 should be considered addressed within that constraint.
