# Live shortcuts under Wine and GNOME

Wine and the desktop can interfere at different points. Both fixes are active
by default. The GNOME hold temporarily affects the whole desktop session, so
`ABLETON_SHORTCUTS=preserve` remains available as an opt-out.

## Alt shortcuts inside Wine

Earlier Wine builds could treat a Live-handled Alt chord as bare Alt and arm
the menu bar. Patch 0070 clears that pending action as soon as another key or
mouse button arrives. Alt shortcuts handled by Live should then perform only
their Live action. Alt plus a menu letter and bare Alt keep their normal menu
behaviour.

The standalone reproducer passes on the patched build. Real Live coverage was
still pending when this record was written.

## Let Live receive GNOME Ctrl+Alt shortcuts

GNOME takes Ctrl+Alt+Up and Ctrl+Alt+Down for workspace movement. It can also
take Ctrl+Alt+Delete, which Live 11 uses for Delete Fades.

A normal Live launch removes only the exact conflicting accelerators. It retains
other entries, including Super-based workspace shortcuts. It restores the
saved values after all Live sessions exit and can recover them on a later
launch after a crash or logout. If the user changes a held setting while Live
runs, that new value is preserved.

Set `ABLETON_SHORTCUTS=preserve` to leave GNOME's bindings unchanged. The hold
applies only to GNOME. Other desktops need their own shortcut configuration.

Run `scripts/test-shortcut-hold.sh` for the settings, recovery, concurrency,
and user-change checks. Build and run `tools/altnum-menu-repro.c` on a working
Wine display for the Wine input path.
