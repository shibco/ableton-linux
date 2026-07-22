# Upstream issue draft: interactive-resize feedback loop at 2x Xwayland scaling (2026-07-21)

Ready-to-file material for the resize-growth root cause. File against
mutter (primary) and optionally Wine (secondary). Not Xwayland: the
24.1.12 to 24.1.13 source diff was reviewed in full for this
investigation and contains only dix/fb/glamor font and glyph fixes,
colormap fixes, GLX vendor dispatch and Xi cursor changes, and an xkb
maprules fix. There is no geometry, hw/xwayland, or input-transform
change in that release. Tarballs and the diff are preserved under
`~/Projects/Code/ableton/xw-diff/`. The apparent correlation with the
24.1.13 upgrade was timing coincidence; the regime that exposes the bug
was re-enabled by the IFEO dpiAwareness re-application on 2026-07-19.

## Where to file

- mutter: https://gitlab.gnome.org/GNOME/mutter/-/issues
- Wine (optional, for the client-side half): https://bugs.winehq.org
- Not xorg/xserver; a report there will be bounced to the compositor.

## Suggested title (mutter)

X11 configure requests with odd physical geometry are rounded up under
xwayland-native-scaling; clients with snapped internal layout can enter
an endless resize feedback loop

## Body (mutter)

Environment: GNOME Shell 50.3, mutter 50.3, xorg-xwayland 24.1.13,
Wayland session, single 2x-framebuffer monitor (experimental-features
scale-monitor-framebuffer + xwayland-native-scaling, 125% fractional
scale), CachyOS (Arch-based).

With xwayland-native-scaling, X11 windows live on a physical-pixel
coordinate grid but mutter constrains their geometry to the logical
grid: a client XConfigureWindow request whose width or height is an odd
number of physical pixels is granted rounded up by one pixel. Observed
directly (Wine debug trace of the X11 client):

    requested config (1182,132)-(3210,2613)  ; height 2481, odd
    granted ConfigureNotify height 2482      ; rounded up, every time

For most clients that is a harmless one-time adjustment. It becomes an
endless loop for a client whose own internal layout also snaps to a
grid. Concrete case: Ableton Live 12 under Wine, per-monitor-DPI-aware
at 2x, lays out in logical units, so every window height it can accept
is even in physical pixels; Wine's window frame model adds an odd
offset between the client area and the outer frame. After any
interactive resize (grab op), each round of the negotiation flips
parity: the app re-requests grant+1, mutter grants request+1, forever.
The window grows 2 physical px per cycle, roughly 20 to 40 px/s,
without bound (reproduced growing from 2390 px to over 6600 px tall
until stopped externally).

Reproduction sketch (no Wine required in principle): an X11 client that,
on every ConfigureNotify with an even height H, requests H+1. Under
xwayland-native-scaling at 2x it will grow monotonically; on a 1x
session it converges after one round.

Expected behavior: some fixed point for clients whose requests the
compositor cannot represent exactly. Options: grant unrepresentable
sizes verbatim on the X11 side (letting the surface viewport handle the
fraction), or clamp the granted size to never exceed the request, so a
snapping client converges from above.

Impact: any per-monitor-aware application under Wine on a fractional-
scale GNOME session is affected when its frame arithmetic produces odd
physical sizes. Worked around in our Wine build by aliasing sub-scale
rounding at the winex11 layer (the app never sees the rounded grant);
patch: shibco/ableton-linux, patches/0042.

## Body (Wine, optional)

winex11 feeds window-manager configure grants that differ from the
request by sub-scale rounding straight back to the Win32 window state,
where per-monitor-aware applications with snapped layout re-round and
re-request endlessly (see the mutter issue above for the compositor
half). Suggested behavior: treat a grant within one scale unit of the
request as acknowledging the request. Reference implementation: this
project's patch 0042.

## Evidence bundle (this machine)

- `~/Projects/Code/ableton/live-trace-interactive-20260721.log`: full
  +win,+x11drv trace of a ratcheting session (band 7); the extracted
  cycle is in `~/Projects/Code/ableton/ratchet-segment.log`.
- `~/Projects/Code/ableton/live-trace-band8-20260721.log`: the same with
  a +1 frame-constant change proving the loop is constant-independent
  (excerpt: `~/Projects/Code/ableton/band8-segment.log`).
- `~/Projects/Code/ableton/xw-diff/`: xwayland 24.1.12 and 24.1.13 trees
  and their diff, showing no geometry changes.
