# Live's GPU renderer: enablement and effects

This note explains why the stack now runs Live's own GPU renderer, what
that fixes, and how to verify it. Change date: 2026-07-27.

## The change

Remove the line `-_ForceGdiBackend` from every
`drive_c/users/*/AppData/Roaming/Ableton/Live*/Preferences/Options.txt`
in the prefix. `scripts/setup-prefix.sh` step 5c does this
automatically. Live then uses its Direct2D/Direct3D 11 renderer instead
of the GDI fallback.

Wine patch 0053 accompanies the change: winex11 exports the app's
`WM_GETMINMAXINFO` minimum tracking size as the X11 `PMinSize` hint, so
the window manager clamps interactive resizes at Live's minimum.

Patch 0069 corrects the selected Live window's resizability classification.
If captioned startup or restored geometry covers the monitor, Wine keeps the
window resizable while `WS_CAPTION` and `WS_THICKFRAME` remain set. The window
therefore stays on patch 0053's existing resizable size-hint path, publishing
Live's DPI-dependent `PMinSize` without a `PMaxSize`; borderless fullscreen
remains fixed-size. `WINE_WIN32_RESIZABLE_CLASS=off` disables only patch 0069
for a one-launch A/B comparison.

## What it fixes

- The WebView2 pane flicker (Learn View, Splice view): with the GDI
  renderer, Wine's DirectComposition keep-alive reblit (patch 0041) and
  Chromium's stale software frame alternated in the pane at 5 Hz. With
  the GPU renderer both painters hold identical content and the pane is
  stable. Measured 2026-07-27 with xdmg and frame hashing: the 5 Hz
  damage stamps still fire but 30 of 30 pane captures hash identical,
  on both the wine-11.11 production runtime and the wine-11.13 build of
  main.
- Idle CPU drops to 1-2% (reported by the maintainer on the production
  setup). The GDI renderer measured about 59% of one core mid-session.
- Below-minimum interactive resize (patch 0053): without the PMinSize
  hint, shrinking a window below Live's minimum (1610x1346 physical at
  200% scale) made Live counter the grant mid-drag; the window grew at
  the opposite edge and the configure storm could end in a spurious
  maximize. With the hint the window manager stops the drag at the
  minimum.

## Why -_ForceGdiBackend existed

Early setups (before the giang17 d2d1-dcomp base fork and before the
file-dialog portal, patch 0031) hit blank file dialogs when Live's GPU
renderer was on, and the flag was carried into the prefix as a
requirement. Both reasons are gone: the base fork exists to make
Direct2D rendering work, and file dialogs go through the XDG portal.
The old machine-local docs that mark the flag as required are
superseded by this note.

## Verification

1. `grep -r ForceGdiBackend "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/Ableton/*/Preferences/Options.txt`
   returns nothing.
2. Open the Learn View and the Splice view. Both render their content
   and stay stable.
3. `xprop -id <live-x-window> WM_NORMAL_HINTS` shows
   `program specified minimum size` and no `program specified maximum size`.
4. Drag a window edge below Live's minimum. The drag stops at the
   minimum and the window does not fight the drag.

Checks that still need a pass after longer real-world use: file dialogs
under sustained work, plugin editor open/close (JUCE, SWAM), and both
panes across scale factors other than 200%.

## Present path (added 2026-07-29, issue 91)

A present is the step where Live hands a finished frame to Wine for
display. With the GPU renderer on, Wine handled every present of Live's
main window on its GDI path: it copied the finished frame from the
graphics card into main memory and sent it to the display server as a
full-window image, about 14 MB per frame at 2560x1350. An idle window
presents nothing, so the idle figures above stay correct. Continuous UI
activity, including mouse movement over the window, produced about
650 MB per second of display-server traffic and used more than one CPU
core. Lucas Gillingham (ClickSentinel) reported and measured this in
issue 91.

Wine patch 0055 marks the main window's frame buffers at creation with
`WINED3D_SWAPCHAIN_PREFER_GL_PRESENT`. Wine then shows each finished
frame directly from the graphics card with `glXSwapBuffers` and skips
the copy. The patch applies this to top-level windows only. Windows
with the `WS_CHILD` style (composition targets, embedded plugin
editors) keep the GDI path because they have no X11 window of their
own. Windows with the `WS_POPUP` style (Settings, the authorisation
dialog, context menus) also keep the GDI path because they show black
content on the direct path until the first click or keypress. Set
`WINE_DISABLE_GL_PRESENT=1` in the environment to restore the GDI path
for every window; a rebuild is unnecessary. The value `0` is ignored
and keeps the direct path.

To confirm which path a build uses, start Live with
`WINEDEBUG=fixme+all,err+all` and count the message `Using GDI present`
in the log. One occurrence means the copy path. Zero means the direct
path. The launcher sets `WINEDEBUG=-all` by default, so pass
`WINEDEBUG` explicitly. Turn tracing off when measuring bandwidth,
because the log's own writes count toward `/proc/<pid>/io`.

These measurements come from one machine (AMD Navi 31, COSMIC/Wayland
via XWayland). Confirmation on Intel or NVIDIA hardware and on a
non-Wayland session is still open.

### The direct path can land the frame low; patch 0058 gates it (2026-07-30)

Two reports show the direct path drawing Live's frame too low, a black
band on top and the bottom rows clipped, while input hit-testing stays
on the real layout: niri/XWayland at 125% (reported on PR 98, about
476 px low) and KDE Plasma with NVIDIA when Live's Enable HiDPI Mode
setting is on (issue 100). KDE floats its windows, so a tiling-only
explanation does not cover both.

The candidate mechanism both share sits in the present path. The
destination rect is captured on Live's thread in the window's DPI
context (patch 0023). The blit's y-flip re-queries the client rect
later, on wined3d's CS thread, in that thread's DPI context
(`wined3d_texture_translate_drawable_coords`). Nothing forces the two
queries to agree: the threads can hold different DPI awareness, and
the window can be resized between capture and execution. On a
disagreement, GL's bottom-left origin lands the frame low by the
difference.

Patch 0058 gates the direct path on agreement, per frame: it re-queries
the client rect on the CS thread and compares it with the captured
destination rect. Matching frames keep the direct path. Disagreeing
frames take the GDI path, which anchors top-left and renders correctly
under the same mismatch. On an affected setup every frame disagrees,
so the swapchain behaves as if `WINE_DISABLE_GL_PRESENT=1` without
anyone setting it, and healthy setups keep the direct path. The
fire-once FIXME `Present-time client rect disagrees` plus a
rate-limited TRACE record both rects and the backbuffer size, so an
affected machine can show which side lies, toward a root fix in
`translate_drawable_coords` itself.

Runtime verification is below: the gate is correct, and the
disagreement it detects has a root cause worth fixing.

### The disagreement is a DPI-context gap; patch 0059 closes it (2026-07-30)

The trigger is fractional display scaling, not a compositor, a driver
or a window manager. It reproduces on AMD Navi 31 under COSMIC/Wayland
— a setup with no symptom at 100% — by putting the prefix at 125%
(`ABLETON_DPI_MODE=dpi120`, LogPixels 120). That covers both reports:
niri at 125%, and issue 100's KDE/NVIDIA machine, where the trigger is
Live's Enable HiDPI Mode.

Patch 0023 brackets the present-time client-rect queries with the
window's own DPI awareness context, in `wined3d_swapchain_present`,
`wined3d_swapchain_resize_buffers`, `wined3d_swapchain_state_init` and
`d3d12_swapchain_resize_buffers`. It does not cover
`wined3d_texture_translate_drawable_coords`, the one that runs on the
CS thread. The flip subtracts a height resolved in that thread's
inherited context from a destination rect resolved in the window's,
and under scaling those are two different numbers for the same window.

Patch 0059 brackets that query the same way, and 0058's gate with it.
The second half is not optional: the gate runs before the blit and
sends mismatched frames to `swapchain_blit_gdi()`, which never reaches
the flip, so an unbracketed gate diverts every scaled frame and the
corrected flip never runs. The first build of 0059 showed no bar and a
healthy frame rate while its own FIXME had fired zero times.

Measured at 125% on one machine, mouse moving over the window, Live's
CPU sampled with `top -b`, 15 readings at 2s (one core = 100%):

| Series | Black bar | Live CPU | Present path |
|---|---|---|---|
| 0055, no 0058 | yes | 29.8% | direct |
| + 0058 | no | 98.9% | copy |
| + 0058 + 0059 | no | 25.2% | direct |

0058 on its own trades the bar for the copy path's cost on every
scaled setup, and that cost is not noticeable by feel — only by
measurement. With 0059 there is nothing to trade: the bar is gone and
the direct path survives. 0058 stays in as the safety net, silent, and
as the assertion that the two contexts now agree.

## Device identification (added 2026-07-30, updated 2026-08-01, issue 84)

Live checks the graphics card before it enables the GPU renderer. It
reads the device name and PCI ID that wined3d reports, and wined3d
takes both from a device table. A card missing from that table is
reported as "Intel(R) HD Graphics 4000", a 2012 device that Live
rejects. On such a machine Preferences > Display & Input greys out
"Enable GPU Renderer" with the reason text "Intel(R) HD Graphics
4000: Unexplained slow UI at zoom-level 100% and/or crashes", and
nothing else in this note applies.

The table ended at 2018's Coffee Lake, plus one Battlemage entry from
patch 0035. Wine patch 0057 adds the families from Ice Lake through
Lunar Lake and the Arc A-series cards, so Live sees a current device
name and its own check passes. Confirmed on issue 84's Meteor Lake
laptop 2026-07-30: stickyfran built this branch and the GPU renderer
enabled (issue 84 comments).

Patch 0061 covers devices missing from the table by synthesising the
description from the driver's own renderer string. That is not enough
for Meteor Lake: the synthesised name, "Intel(R) Arc(tm) Graphics", is
the device's real Windows name, and a build with 0061 alone stayed
greyed out on the same laptop (PR 105 comments, 2026-07-31). A table
entry takes precedence over 0061, and the "(MTL)" suffix in 0057's
entry is what passes Live's check. A traced launch from that machine
confirming the exact rejected name is still open.

To check a machine: open Preferences > Display & Input. "Enable GPU
Renderer" must be a switch, not greyed out with the HD 4000 reason
text.

## Related

- [Diagnosis narrative](ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md)
- [Learn View flicker mechanism](ABLETON-WINE-LEARNVIEW-FLICKER.md)
- [Patch 0053](../patches/0053-winex11-export-the-app-minimum-tracking-size-as-PMin.patch)
- [Patch 0055](../patches/0055-dxgi-prefer-GL-present-for-top-level-swapchain-devic.patch)
- [Patch 0057](../patches/0057-wined3d-add-Intel-graphics-devices-from-Ice-Lake-to-.patch)
- Resize trace from the diagnosis session:
  `~/Projects/Code/ableton/live-resize-trace-gpu-20260727.log`
  (machine-local)
