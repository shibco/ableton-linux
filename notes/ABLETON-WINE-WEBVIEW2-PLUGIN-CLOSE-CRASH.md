# WebView2 plugin editor close crash

Patch 0045 fixes the Live crash reported in issue 52. Closing a WebView2-based
VST3 editor could show Live's serious program error dialog. Splice INSTRUMENT
was the first reported plugin.

## Cause

The WebView2 helper process registers an OLE drop target on its own
`Chrome_WidgetWin_1` child window. That window sits inside the host's window
tree. `RegisterDragDrop` stores the `IDropTarget` as a raw pointer in the
`OleDropTargetInterface` window property. The pointer is valid only in the
registering process, but other processes can read the property.

When the editor closes, its host-side teardown can call `RevokeDragDrop` on
every child window. Live therefore calls it on the helper-owned window.
Wine reads the foreign pointer and calls `Release` in Live's process. The
vtable dereference raises an access violation in `ole32`.

## Fix

`RegisterDragDrop` already rejects windows owned by another process. Patch
0045 adds the same process check to `RevokeDragDrop`, which now returns
`DRAGDROP_E_INVALIDHWND`. The helper process can revoke its own registration.

Giang Nguyen wrote the fix in `giang17/wine` commit `fafb443f85e0` after a
JUCE 8 WebView2 failure under yabridge. This project ported it to Wine 11.11.
On 2026-07-24, neither that base nor upstream Wine contained the change.
Recheck patch 0045 during the issue 53 base update.

## Verification

[`tools/webviewclose.c`](../tools/webviewclose.c) hosts a real WebView2
controller inside a test plugin-editor window. The build requires Clang, LLD,
and a Wine source tree containing its built `build-wow64` directory. When the
SDK header is absent, it also requires `curl`, Python 3, `sha256sum`, and
network access. It downloads SDK 1.0.2903.40 into `tools/webview2-sdk/`.
Build the tool from the repository root:

```bash
WORKS_RUNTIME_SOURCE=/path/to/wine-d2d1-nspa-src \
  ./tools/build_webviewclose.sh
```

The script writes `tools/webviewclose.exe`. Run variant `e` with the project's
Wine runtime and prefix:

```bash
WINEPREFIX="$HOME/works/plugs/studio" \
  "$(works runtime path)/bin/wine" \
  ./tools/webviewclose.exe e \
  'C:\ProgramData\Ableton\Live 12 Suite\Program\WebView2Loader.dll'
```

Replace `Live 12 Suite` with the installed Live directory. When the second
argument is omitted, the tool uses
`C:\ProgramData\Ableton\Live 12 Beta\Program\WebView2Loader.dll`.

The test variants are:

- `a`, `b`, and `c`: other teardown orders. They exited without a fault on the
  unpatched runtime.
- `e`: call `RevokeDragDrop` on each descendant before closing. This reproduced
  issue 52 on the unpatched runtime and completed on the patched runtime.
- `d`: park the editor under a hidden top-level window for the related issue 57
  investigation.

The tool writes `webviewclose-report.txt`. Exit status 0 means the run was
clean, 2 means setup or teardown failed, and 3 means the exception handler
caught a fault.

## Scope

The bug can affect any WebView2 plugin editor whose host revokes drag and drop
on enumerated child windows. The fix is in Wine's OLE code and does not depend
on this project's DirectComposition patches.
