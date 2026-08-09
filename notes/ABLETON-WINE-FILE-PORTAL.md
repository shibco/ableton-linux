# Native desktop file dialogs

Patch 0031 sends compatible 64-bit Wine file-dialog calls through XDG Desktop
Portal. `setup-prefix.sh` sets the policy to `auto` when the prefix has no
existing choice.

## Implementation

Stock Wine 11.11 has no comdlg32 portal backend.
[Patch 0031](../patches/0031-comdlg32-add-XDG-file-dialog-portal.patch)
ports Wine merge request 10060 v5 to this runtime and adds its responsiveness
follow-up. It includes merge-request patches 1, 2, 3, and 5. Patch 4 contained
only a test with Wine 11.0-specific context and was not included.

The patch covers `GetOpenFileName`, `GetSaveFileName`, `IFileDialog`, and
`SHBrowseForFolder`. In a tested 64-bit `GetOpenFileNameW` cancellation, the
portal backend reported `STATUS_CANCELLED`, the API returned `FALSE`, and Wine
did not open its fallback dialog.

Under new WoW64, a 32-bit caller cannot load this 64-bit portal Unix library.
It therefore uses Wine's chooser.

## Policy

The registry value is:

```text
HKCU\Software\Wine\X11 Driver\FileDialogPortal
```

Accepted values are:

- `auto`: use the portal for supported calls, and keep Wine dialogs for hooks,
  custom templates, and unsupported options.
- `always`: skip some compatibility checks. Application-specific dialogs may
  fail.
- `never`: disable portal dialogs.

Set a policy with this project's Wine:

```bash
WINEPREFIX="$HOME/works/plugs/studio" \
  "$(works runtime path)/bin/wine" reg add \
  'HKCU\Software\Wine\X11 Driver' \
  /v FileDialogPortal /t REG_SZ /d auto /f
```

Replace `auto` with `always` or `never` as needed. Use your
`WORKS_PLUG` and `WORKS_RUNTIME` paths if they differ from the
defaults.

For one Live launch, `WINE_FORCE_PORTAL=1 "$HOME/.local/bin/ableton-live"`
requests the `always` behavior. The repository's older `bin/*-portal`
wrappers target a separate development runtime and are not installed by the
`.run` package.

Patch 0043 reuses the portal connection to reveal Explorer `/select` targets
in the host file browser. See
[ABLETON-WINE-SHOW-IN-EXPLORER.md](ABLETON-WINE-SHOW-IN-EXPLORER.md).

## Requirements

The host must provide `xdg-desktop-portal` and a desktop backend. If the
portal is unavailable, the patched calls fall back to Wine's chooser.
Thirty-two-bit applications always use that fallback. The registry policy has
no effect on a Wine build without patch 0031.
