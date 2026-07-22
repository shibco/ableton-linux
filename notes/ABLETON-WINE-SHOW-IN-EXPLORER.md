# Show in Explorer opens Wine's explorer instead of the host file manager

2026-07-21.

## Symptoms

Right-clicking a file in Live and choosing Show in Explorer opens Wine's
built-in explorer.exe file listing instead of the desktop's file manager
(issue #41).

## Research

Live's exe imports ShellExecuteW/ShellExecuteExW, does not import
SHOpenFolderAndSelectItems, and carries the wide string `,/select,"`: Show
in Explorer is `ShellExecute(Ex)W` of `explorer.exe /select,"<path>"`.
Under Wine that command line reaches shell32's SHELL_execute, which finds
Wine's explorer.exe and spawns it.

The XDG Desktop Portal already offers the right primitive:
`org.freedesktop.portal.OpenURI.OpenDirectory` takes a file descriptor and
opens the containing folder in the host file browser; backends that talk
`org.freedesktop.FileManager1` (Nautilus, Dolphin, Nemo and others) select
the item too. The portal plumbing (dlopened libdbus, session bus
connection, request tokens) exists since patch 0031 in comdlg32's unix
library.

## Mitigations

Patch 0043 routes it through that plumbing:

- comdlg32's unix library gains `portal_open_directory`, an OpenDirectory
  call that waits only for the method reply, not the Response signal, so
  the caller's UI thread does not sit behind the file manager launch.
- comdlg32 exports `__wine_portal_show_item(path)`: policy check, DOS to
  Unix path conversion, unix call.
- shell32's SHELL_execute recognizes explorer `/select,` command lines
  whose target exists and calls that export; comdlg32 imports shell32, so
  the export is resolved with LoadLibrary/GetProcAddress to avoid an
  import cycle.

Verified 2026-07-21 with tools/showexp.c (mimics Live's exact call) on
GNOME/Nemo: ShellExecuteExW and ShellExecuteW, file and directory targets
all open the host file manager with the item selected, and dbus-monitor
shows the OpenDirectory call. No Wine explorer process is spawned.

## Policy and fallback

The reveal obeys the same `FileDialogPortal` prefix policy as the file
dialogs (`bin/set-file-portal-policy`): `never` turns it off. On any
refusal (policy, missing target, no portal on the bus, 32-bit caller,
portal call failure) the old explorer.exe spawn runs unchanged; verified
for the policy and missing-target cases.

## Caveats

- 32-bit callers cannot load the portal unix library under new WoW64 and
  always fall back to Wine's explorer, same as the 0031 dialogs.
- Whether the item is selected or only its folder opened depends on the
  desktop's portal backend; the folder always opens.
- A plain `explorer.exe <folder>` (no `/select`) still opens Wine's
  explorer; Live does not issue that form.
