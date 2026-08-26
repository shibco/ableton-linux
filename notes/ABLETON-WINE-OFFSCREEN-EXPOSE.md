# Dialogs keep their content after an X11 expose

Issue 263: Live's Separate Stems dialog opens with a black client area on KDE
Plasma (Wayland, NVIDIA). The content appears after a click inside the dialog.
Issue 262 reports black Max for Live menu windows on SwayFX. Both reports use
release 2026.08.24.1.

## How Live's windows reach the screen

The launcher sets `WINE_X11_FORCE_OFFSCREEN_CLASS` to Live's top-level window
class (patch 0062, shipped in release 2026.08.01.1). Every top-level window of
that class, which includes Live's dialogs, then renders on the offscreen client
surface path:

1. Direct3D renders into a client X11 window. winex11 reparents that window to
   its dummy parent and redirects it with XComposite, so the X server keeps the
   window's content in a composite pixmap while the window stays on this path.
2. On every present, `X11DRV_client_surface_present()` copies that content
   onto the toplevel X11 window with a direct blit.
3. The toplevel also keeps a window surface for GDI drawing. Wine flushes that
   surface with `XPutImage` when the X server reports an Expose.

Live's dialogs use flip-model swap chains, so wined3d presents them through
OpenGL. Patch 0055 only decides whether a swap chain prefers the OpenGL path;
it does not send these dialogs to the GDI path.

## Why a dialog opens black

Live presents the first frame of a dialog right after `ShowWindow`. The window
manager has not mapped the window yet, so the X server discards the copy. When
the window manager maps the window, the X server sends Expose. Wine's expose
path (`expose_window_surface()` in win32u) flushed the window surface. For a
dialog without child windows the surface region covers the whole client area,
and that surface never held the Direct3D frame, so the flush painted its
blank content over any copy that did land. Nothing asked Live to present
again, and Live does not present again until the next input event. The dialog
stays black until the user clicks inside it. The composite pixmap holds the
frame throughout.

On the GNOME test runtime Mutter mapped the dialog before Live's first
present, so Separate Stems did not show the failure there without a probe
that forces the timing.

## The change

[Patch 0107](../patches/0107-win32u-restore-offscreen-client-content-on-expose.patch)
adds one step to `expose_window_surface()`. After a whole-client expose, it
restores every retained X11 offscreen client surface of the toplevel. Partial
exposes do not trigger a full-window copy, so a small damaged rectangle cannot
add a full-frame blit or overwrite newer drawing outside that rectangle.

The restore uses a separate callback documented for the window owner thread;
it does not call the render-thread present callback from the X11 event path.
It refreshes each surface's geometry before checking its retained-pixel flag,
so a resize clears the flag before a replacement pixmap can be copied. A
surface that Wine has never presented offscreen at its current size is skipped
because its content is undefined.

## What was measured

The original D3D11 probe (`WINE_X11_FORCE_OFFSCREEN_CLASS` set to its own class,
owned captioned window, one present right after `ShowWindow`) captured black
after the map on the 2026.08.24.1 runtime and captured its frame when retained
content was restored. The same held for a present before `ShowWindow`. Live's
Separate Stems dialog rendered before and after an injected whole-window
Expose, and its composite pixmap held the rendered dialog. The main window and
the Max for Live device view were unchanged. Those measurements ran on GNOME
48 with Mutter, Xwayland, an AMD GPU and 200% scale.

The narrowed whole-client and owner-thread implementation has been compiled as
both `win32u` and `winex11`. It still needs the runtime cases below before
release.

## Open points

- Live's recovery prompt after an unexpected exit presents through wined3d's
  GDI path. Its window carries a pixel format, so `update_visible_region()`
  gives its DCs direct access to the X11 window, and the frame never reaches
  the composite pixmap or the window surface. The prompt opens black on GNOME
  with and without the patch. An injected Expose does not restore it either,
  because there is nothing retained to copy; asking for a repaint on that
  expose makes Live repaint it, but that change also turns winewayland's
  forced reflush into a no-op and stops restoring child GDI content, so it
  stays out of this patch. A 70 second event trace shows Wine processed no
  Expose or MapNotify for that window while the prompt was up, which needs a
  trace of Live's message loop around the prompt.
- Issue 262 is not covered. Max 9 draws its menus with JUCE. JUCE's
  `HWNDComponentPeer` creates a popup as `WS_POPUP | WS_SYSMENU` with
  `WS_EX_TOOLWINDOW`, and `is_window_managed()` in winex11 treats a popup with
  `WS_SYSMENU` as managed. A window manager that places managed floating
  windows at the screen centre would produce the centred box in the report;
  Sway's placement rules are not verified here. A JUCE popup is not on the
  offscreen path unless its DPI differs from the monitor, and its content
  reaches the window through the DirectComposition blit path, so this patch
  does not touch it. A `WINEDEBUG=+x11drv,+win,+dxgi` log from the reporter
  would show whether the popup renders offscreen, whether it has a pixel
  format, and which Expose and WM_STATE events it receives.
- Reporters can compare with `WINE_X11_FORCE_OFFSCREEN_CLASS=off`, which stops
  the launcher forcing Live's windows onto the offscreen path (a DPI mismatch
  or child windows can still select it), and with `ABLETON_VDESK`, which
  removes the window manager from the map sequence.

## Check the result

Open a Set with an audio clip, right-click the clip and choose Separate Stems
to New Audio Tracks. The dialog shows its controls at once. Then partially
cover and uncover both the dialog and Live's main window, and resize them;
neither window should flash, lose newer drawing or add stale pixels. Repeat on
KDE Plasma with NVIDIA and on GNOME.

For issue 262 on Sway, reproduce the LFO waveform menu separately and capture
`WINEDEBUG=+x11drv,+win,+dxgi`. Patch 0107 intentionally does not claim to fix
that DirectComposition popup path.
