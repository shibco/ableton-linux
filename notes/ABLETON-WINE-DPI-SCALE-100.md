# Display scale and the DPI matched set

## Symptoms

Changing the desktop display scale (GNOME, 125% to 100%) invalidates the
prefix's DPI calibration: a magnified Live UI, a 2× mouse cursor over Live's
window, a ~100/sec Y-position creep loop, and a resize/tiling fight.
Separately, at 100%: the main window grows +56px vertically over ~2 s after
every interactive resize or WM-forced tile.

## Research

Under GNOME/mutter with `xwayland-native-scaling`, the XWayland framebuffer
scale is `ceil(fractional_scale)`. Three knobs must track it as a matched
set:

| knob | 125% (2× framebuffer) | 100% (1× framebuffer) |
|---|---|---|
| `HKCU\Control Panel\Desktop\LogPixels` | `0xC0` (192) | `0x60` (96) |
| IFEO `…\Ableton Live 12 Suite.exe\dpiAwareness` | `2` (per-monitor) | absent |
| `org.gnome.mutter experimental-features` | incl. `xwayland-native-scaling` | removed |

Rule: `LogPixels = 96 × ceil(display_scale)`; the IFEO key and
`xwayland-native-scaling` belong only to upscaled framebuffers. At an
integer 1× scale they force a 2× surface on a 1× app and cause the symptoms.

Per knob (each verified from a `+timestamp,+win` trace):

- Stale `LogPixels` 192 at 1× causes the magnification: Live renders for
  192 DPI on a 1× screen.
- The stale IFEO key causes the creep loop: it advertises the window as
  per-monitor-aware, XWayland hands it a native 2× buffer, and the
  2×-surface-vs-1×-app mismatch moves the window top +1-2px per cycle.
  Removing it drops main-window SetWindowPos to 0/sec.
- `xwayland-native-scaling` causes the 2× cursor: Wine's winex11 is a plain
  X11 client with no native-scaling awareness; the 2× comes entirely from
  mutter/XWayland.

+56px growth root cause: on every WM-initiated ConfigureNotify (one per
pointer motion during a drag), Live's `WM_WINDOWPOSCHANGED` handler
recomputes its outer rect as `GetClientRect +
AdjustWindowRectExForDpi(menu=TRUE) + 4px` and calls SetWindowPos. The +4 is
Live's own arithmetic (its `WM_GETMINMAXINFO` output tracks `adjust+4` across
different metric configurations); +56 per drag ≈ 14 configure events × 4px.
Wine is self-consistent: `AdjustWindowRectExForDpi` = `NCCALCSIZE` = the
measured menu bar, and a WM-managed mimic window running Live's exact handler
arithmetic drifts 0. Convergence needs Wine's menu bar to measure
`SM_CYMENU + 4`, plausibly Live's model of real Windows.

Dead ends: frame-extents reconstruction for the main window (strobing white
frame; same family as patches
[0008](../patches/0008-re-enable-frame-extents-round-trip-revert-patch-06-d.patch)/[0009](../patches/0009-revert-frame-extents-re-enable-a5ab9f00-reintroduced.patch);
confirmed dead end); `WindowMetrics` recalibration (the artifact is WM frame
37px + Live's own 19px menu, which is app-internal; no Wine metric cancels
it); `PaddedBorderWidth=-60` (still +4); `MenuHeight=-330` (Live's model
tracks adjust; the mismatch just moves).

## Mitigations

- `scripts/detect-scale.sh` + `setup-prefix.sh` + the launcher apply the
  calibrated DPI set for the detected scale on every start (the matched set
  on GNOME; plain `LogPixels = round(96 × scale)` elsewhere).
- [../patches/0029-win32u-lay-out-the-menu-bar-4px-taller-than-SM_CYMEN.patch](../patches/0029-win32u-lay-out-the-menu-bar-4px-taller-than-SM_CYMEN.patch):
  raises the menu-bar item floor in `win32u/menu.c calc_menu_item_size` from
  `SM_CYMENU - 1` to `SM_CYMENU + 3` (both branches), so the bar measures
  `SM_CYMENU + 4` and NCCALCSIZE matches Live's expectation. WM-forced
  resizes land pixel-exact and hold; adjust/metrics unchanged; popup menus
  unaffected (font-driven).
- Manual recalibration (what the scripts automate):

```bash
export WINEPREFIX=$HOME/.wine-ableton
WINE=~/.local/opt/wine-d2d1-nspa-11.11/bin/wine

# 100% (1× framebuffer)
$WINE reg add "HKCU\Control Panel\Desktop" /v LogPixels /t REG_DWORD /d 96 /f
$WINE reg delete "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 12 Suite.exe" /v dpiAwareness /f
gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
pkill -x Xwayland     # mutter respawns it; relaunch Live after

# 125% (2× framebuffer)
$WINE reg add "HKCU\Control Panel\Desktop" /v LogPixels /t REG_DWORD /d 192 /f
$WINE reg add "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Ableton Live 12 Suite.exe" /v dpiAwareness /t REG_DWORD /d 2 /f
gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer', 'xwayland-native-scaling']"
pkill -x Xwayland
```

## Caveats

- Off GNOME (KDE, Hyprland, sway, Xft), scales 100-250% calibrate as plain
  `LogPixels = round(96 × scale)` with no IFEO key (96/120/144/168/192/240 at
  100/125/150/175/200/250%); GNOME keeps the matched set above. Scales
  outside that range preserve the prefix's current values.
- `wineserver -k` without `WINEPREFIX` exported kills the default prefix's
  server; "killed" Lives survive and the single-instance guard then aborts
  new launches.
- A boot freeze at "initialising the application" can be
  `MicrosoftEdgeUpdate.exe` hanging (WebView2 updater): kill the process; do
  not rename the exe away (the loader's COM wait wedges worse).
- A crash-recovery prompt can sit behind the splash after hard kills and
  look like a freeze; clearing `Preferences/CrashRecoveryInfo.cfg` skips it.
- Probes in [../tools/](../tools/): `metricprobe.c`, `wmresize.c`,
  `menumeasure.c`, `showrestore.c`, `xsettle.c`.
