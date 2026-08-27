# Display scale calibration and stable window sizing

The launcher recalibrates the prefix before each Live start. Patches 0040 and
0042 then keep Live's main window stable across moves, tiles, and interactive
resizes on the measured GNOME/Xwayland fractional-scale setup.

## Keep Wine and Xwayland at the same scale

GNOME with `xwayland-native-scaling` uses an integer-scaled Xwayland
framebuffer. These values must describe the same mode:

| Setting | 125% GNOME scale | 100% scale |
|---|---:|---:|
| `HKCU\Control Panel\Desktop\LogPixels` | 192 | 96 |
| Live IFEO `dpiAwareness` | `2` | absent |
| Mutter `xwayland-native-scaling` | enabled | disabled |

Stale values can magnify Live, double the cursor, or make the main window move
by one or two pixels per configure cycle. An incoherent live Wine session can
also shrink the window in both dimensions while it is moved and remove Live's
application menu. `scripts/detect-scale.sh` detects GNOME, KDE, sway,
Hyprland, COSMIC, and an Xft DPI fallback. The launcher updates the registry
values but does not change the desktop setting.

On mixed-scale GNOME, Xwayland uses one shared framebuffer derived from the
highest active logical monitor scale. The detector therefore chooses the
highest scale, even when the 100% monitor is primary. Automatic fractional
configuration is applied only when Mutter's `xwayland-native-scaling` feature
can be confirmed.

## Change the complete DPI block before booting Wine

`reg.exe` itself starts Wine and caches the X11 monitor source from the current
`LogPixels`. Writing a new `LogPixels` or Live IFEO value after `wineboot` can
therefore combine an old volatile monitor scale with new persistent registry
values. Both mismatch directions were observed to resize Live continuously.

For a cold DPI change, the launcher now writes a pending-reseed marker, writes
`LogPixels` and every installed Live IFEO key, stops and waits for the Wine
session created by those writes, and only then runs `wineboot`. The marker is
removed after that coherent boot. If another program is already using the
prefix—or enters during the transaction—the launcher leaves it running and
refuses Live until the prefix is idle.

For one comparison launch:

```bash
env ABLETON_DPI_MODE=100 ableton-live
env ABLETON_DPI_MODE=fractional ableton-live
```

`ABLETON_DPI_MODE=preserve` leaves the prefix values unchanged. Non-GNOME
modes use names such as `dpi120` for 125 per cent.

## Stop resize growth

Live derives its outer rectangle from the client size, the DPI-adjusted frame,
and an extra menu band. Patch 0040 scales that band with the menu DPI. At a 2x
Xwayland framebuffer, Live and the window manager could still round the same
odd offset in opposite directions and add two pixels per cycle.

[Patch 0042](../patches/0042-winex11-alias-sub-scale-WM-config-rounding-instead-o.patch)
records each configure request. When the granted rectangle differs only by
sub-scale rounding, Wine reports the requested rectangle to Live and avoids a
second X request for the equivalent size.

Live 12.4.3 was exercised at 125 per cent with interactive resizing, tiling,
and moving. Each action settled once in that test. See
[the resize findings](FINDINGS-RESIZE-GROWTH-2026-07-21.md) for the trace.

The relevant tools are `metricprobe.c`, `metricprobe2.c`, `wmresize.c`,
`wmresize2.c`, `menumeasure.c`, `showrestore.c`, and `xsettle.c` under
`tools/`.
