# Tiling WM / tiled layout — focus and cursor behaviour

## Background

Ableton Live's `SetCursorPos` calls (used during automation editing, clip
nudging, and other UI gestures) are harmless on conventional desktop
environments. On **tiling compositors** (Hyprland, i3, sway, river, dwm, etc.)
they manifest as an apparent focus-steal: the cursor jumps to the centre of
Live's window, the compositor tracks the activation event that triggered the
warp, and the user is yanked back to Live's workspace when they were trying to
switch away.

## Registry fix — `MouseWarpOverride = disable`

Applied at prefix setup (see `setup-prefix.sh` step 5/6):

```
wine reg add 'HKCU\Software\Wine\X11 Driver' \
  /v MouseWarpOverride /t REG_SZ /d disable /f
```

This tells Wine to ignore `SetCursorPos` calls from the application. Live
never depends on absolute cursor position for critical functionality, so the
override is safe.

## Compositor-side: `focus_on_activate = false`

On top of the Wine-level warp disable, users of **Wayland compositors** that
respect the `focus_on_activate` property (Hyprland, niri, river) may further
benefit from setting:

```ini
# Hyprland (hyprland.lua):
hl.config({
    misc = {
        focus_on_activate = false,
    },
})
```

This prevents the compositor from switching focus (and workspaces) when Live
fires an X11 activation event during background processing (audio rendering,
Link sync, plugin scans). Without it, the activation can pull the user from
their current workspace back to Live even when the mouse warp is disabled.

## Impact

- **GNOME / KDE / standard DEs**: no change — `MouseWarpOverride` has no
  observable effect in these environments.
- **Tiling WMs / Wayland compositors**: eliminates the "cursor grabbed at
  window edge", "workspace switch broken", and "forced focus to Live"
  symptoms entirely.

Tested on Hyprland 0.55.4 (PikaOS 4 / Debian trixie) with Ableton Live 12
Suite running under the project's patched Wine stack.
