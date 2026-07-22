# Learn View flicker / mangled rendering (FIXED 2026-07-21, with a documented residual)

## Symptoms (original)

Live's Learn View (the WebView2 lesson panel, `Chrome_WidgetWin_1`
"Learn View 12") showed a band of stale, horizontally clipped content
laid out for a much wider viewport, mixed with correct regions,
flickering between states on activity. Everything else rendered fine.

## Resolution (2026-07-21, patch 0041)

Three interlocked fixes, all in `dlls/dxgi`:

1. **The display path (root cause #3 below).** At
   `WM_WINE_DCOMP_SET_TARGET` time, a target with
   `WS_EX_NOREDIRECTIONBITMAP`, or `WS_EX_LAYERED` that never received
   attributes, is normalized with
   `SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)`. On Windows
   this call is a no-op for a NOREDIRECTIONBITMAP window (there is no
   redirection bitmap for the attributes to affect); in Wine it makes
   the window an ordinary opaque surface, so the dcomp comp-buffer
   blits actually land on screen. Attributed layered windows (JUCE
   DropShadower, UpdateLayeredWindow users) are never touched — the
   guard fires exactly once per WebView2 bind and never for plugin
   editors.
2. **The resize race (caveat under patch 0030).** A stale-skip now arms
   a one-shot 120 ms timer (`DCOMP_RESIZE_REBLIT_TIMER_ID`); the reblit
   re-gates on currency, capped at 5 retries, cleaned up in both
   NCDESTROYs and in `d3d11_swapchain_Release`.
3. **The 3 s heal-revert.** Patch 0025's idle-abandonment
   (`DCOMP_STALE_TICKS`) is removed: with the target now visible,
   suspending reblits after 3 s idle handed the window back to
   Chromium's fossil GDI paints, reverting every healed pane. Always-
   reblit holds the last good frame indefinitely.

Verified on Live 12.4.3 at 125% scale: the pane heals fully on a
splitter nudge / reopen / `tools/posteresize.exe` and now STAYS healed
(previously correct content either never appeared, or reverted ~3 s
after any heal).

## Residual (documented, not a regression)

- **Fossil-on-open.** The pane can still open showing the wide-layout
  fossil band: Chromium lays the page out once at the transient
  creation size, and no Wine-side trigger reliably forces the
  re-render (an auto-heal poke firing timed `SetWindowPos` +1/-1 nudges
  was implemented and rejected: it never healed and left Chromium
  resize-deaf afterwards). A single splitter nudge heals it for the
  session. `tools/posteresize.exe` performs the nudge programmatically
  from inside the prefix.
  - Automated 2026-07-21 (release 2026.07.21.2): `learnheal.exe`
    (tools/learnheal.c), a resident watcher the launcher starts, applies
    the nudge automatically once per pane. The rejected in-Wine poke
    failed because it fired at bind time; the watcher instead requires a
    pane to hold a stable rect across scans (about 3 s) before its
    single nudge, re-arms only on a material later size change, and
    exits when Live is gone. Gating verified against an instrumented
    stand-in pane (tools/fakepane.c): one nudge, after settle, none
    afterwards. The user-visible residual shrinks to a few seconds of
    fossil band right after opening the pane.
- **Shimmer while fossilized.** With 0025's suspension gone, the two
  painters (our reblit, Chromium's own GDI paints into the same window)
  alternate at ~10 Hz until the pane is healed; pre-0041 the fossil was
  static. Healed panes are stable (both painters carry the same current
  content).
- Doc sidebar: same WebView2 pattern, same behavior, same heal.

## Root cause (as established by the original research)

From `+dxgi` traces, dcompspy/hwndspy, and X pixel sampling:

1. Creation-size mismatch: Chromium creates the composition swapchain at
   the pane's transient initial size (`CreateSwapChainForComposition
   (1273x1552)`), then calls `ResizeBuffers(299x804)`, the real pane,
   ~400 ms later.
2. Stale-size paints: between creation and resize, WM_PAINT /
   `dcomp_reblit_comp_buffer` blit the old 1273-wide snapshot into the
   already-299-wide window; that crop of wide-layout content is the
   mangled band. (Fixed by patch 0030.)
3. Correct paints never reached the screen. After the resize the comp
   buffer was correct and full-frame BitBlts executed, yet X-side pixels
   never changed. The Intermediate D3D Window has `WS_EX_LAYERED |
   WS_EX_NOREDIRECTIONBITMAP | WS_EX_TRANSPARENT` and never calls
   SetLayeredWindowAttributes; winex11 delays mapping layered windows
   until attributes arrive (`dlls/winex11.drv/window.c` "layered windows
   are mapped only once their attributes are set") and the server
   suppresses their redraws, so GDI blits to it were invisible. What
   showed instead was the sibling below, `Chrome_RenderWidgetHostHWND`:
   Chromium's software fallback frame, drawn once at the old geometry.
   (Fixed by patch 0041 item 1.)
4. Window chain: `AbletonWebViewHelperWindow` (hidden) →
   `Chrome_WidgetWin_0` → `Chrome_WidgetWin_1` → siblings
   `Chrome_RenderWidgetHostHWND` (visible) + `Intermediate D3D Window`
   (visible, layered), all the same rect.

## Approaches tried 2026-07-21 and rejected (do not retry blindly)

- **dce.c discard of GDI draws to NOREDIRECTIONBITMAP windows**
  (Windows parity: no redirection bitmap). Kills the two-painter
  flicker dead (xgrid 0/30 s), but it also discards OUR reblit into the
  same window — no delivery path remains. Only viable together with a
  working non-GDI delivery, which does not exist for child windows.
- **UpdateLayeredWindow delivery.** Structurally dead for the
  Intermediate window: `win32u get_window_surface` never gives CHILD
  windows their own surface (`window.c:2114`), so ULW takes the
  driver-only branch and blits nothing.
- **Sibling-DC delivery** (blit into `Chrome_RenderWidgetHostHWND`'s DC
  instead). Invisible: the sibling's own X child window shows its own
  stale frame above the shared toplevel surface (proven by posteresize
  healing the attributed-Intermediate runtime but not the
  sibling-delivery runtime).
- **Hiding the sibling or the Intermediate.** Both break Chromium's
  occlusion tracking; presenting stops entirely.
- **`ABLETON_DCOMP=off` (dcomp disabled).** WebView2 shows its error
  page; no lesson content at all. (ENCORE ships dcomp-off by default;
  it does not transfer to this stack.)
- **WebView2 flag matrix** (`--disable-gpu-compositing` dropped, SW-DComp
  forced, `--disable-gpu`, real-GPU angle): no set produces a stable
  correct pane. Ableton itself hardcodes `--disable-gpu
  --disable-gpu-compositing --disable-direct-composition
  --disable-accelerated-2d-canvas` for its embedded WebView2 (seen on
  the browser process cmdline); launcher flags only affect the
  gpu-process GL backend. Dropping `--disable-gpu-compositing` DID
  route full content through the swapchain (proof that a single
  presentation path can carry the whole pane) but the two-painter
  alternation remained.
- **Auto-heal poke** (timed programmatic +1/-1 SetWindowPos on the
  widget, once per bind): fired correctly, healed never (6/6 boots),
  and correlated with the manual heal failing afterwards (Chromium
  resize-deaf). Not shipped; code preserved uncommitted in the dev
  tree.

## Regression watch

- JUCE DropShadower layered windows
  ([../patches/0015-win32u-sync-layered-attributes-to-the-scaled-surface.patch](../patches/0015-win32u-sync-layered-attributes-to-the-scaled-surface.patch)),
  SWAM plugin GUIs: structurally unaffected (never
  NOREDIRECTIONBITMAP, never unattributed-layered dcomp targets);
  spot-check visually anyway.
- Doc sidebar: same WebView2 pattern — it receives the same
  normalization (intended); watch for the shimmer-on-fossil there too.
- Test at 100% and 125% display scale.
- Tools: [../tools/dcompspy.c](../tools/dcompspy.c) (dumps layered
  attributes since 2026-07-21), [../tools/hwndspy.c](../tools/hwndspy.c),
  [../tools/xdmg.c](../tools/xdmg.c), [../tools/xsamp.c](../tools/xsamp.c),
  [../tools/xgrid.c](../tools/xgrid.c),
  [../tools/xsettle.c](../tools/xsettle.c),
  [../tools/posteresize.c](../tools/posteresize.c) (scriptable heal).
