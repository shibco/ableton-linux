# Wine file dialogs instead of native desktop dialogs

## Symptoms

All of Live's open/save/browse dialogs are Wine's built-in chooser rather
than the desktop's native file dialog.

## Research

Wine has no XDG Desktop Portal backend for comdlg32; a draft series exists
upstream (MR10060).
[../patches/0031-comdlg32-add-XDG-file-dialog-portal.patch](../patches/0031-comdlg32-add-XDG-file-dialog-portal.patch)
is the Wine 11.11-compatible delta of MR10060 v5 (patches 1, 2, 3, 5) plus
its responsiveness follow-up, consolidated into one integration boundary.
MR10060's patch 4 only adds a test case whose Wine 11.0 context no longer
applies; excluded.

Architecture: a 64-bit `GetOpenFileNameW` test program takes the portal path
(`WINE_UNIX_CALL`) and returns `STATUS_CANCELLED` directly on cancel; Wine's
fallback dialog is never created. The same PE32 test reaches the eligibility
check but cannot load the portal Unix library under new-WoW64, so 32-bit
callers fall back to Wine's chooser.

## Mitigations

Patch 0031 routes compatible calls (`GetOpenFileName`, `GetSaveFileName`,
`IFileDialog`, `SHBrowseForFolder`) through XDG Desktop Portal. Prefix policy
via `bin/set-file-portal-policy` (applied by `setup-prefix.sh`):

- `auto` (default): portal for compatible Explorer-style calls; Wine dialogs
  for hooks, custom templates, and unsupported options.
- `always`: bypasses some compatibility checks; can break app-specific
  dialogs. One-launch equivalent: `ABLETON_PORTAL_FORCE=1`.
- `never`: off.

`bin/ableton-live-portal` / `bin/ableton-wine-portal` pin or test portal
behavior explicitly.

Patch 0043 reuses this portal plumbing to reveal explorer `/select`
targets (Live's Show in Explorer) in the host file browser; see
[ABLETON-WINE-SHOW-IN-EXPLORER.md](ABLETON-WINE-SHOW-IN-EXPLORER.md).

## Caveats

- 32-bit applications always fall back to Wine's chooser: irrelevant to Live
  (64-bit), relevant to 32-bit helpers/installers in the shared prefix.
- The policy value is inert on a pre-portal Wine build.
- Needs the desktop's `xdg-desktop-portal` backend on the host; without it,
  dialogs fall back to Wine's chooser.
