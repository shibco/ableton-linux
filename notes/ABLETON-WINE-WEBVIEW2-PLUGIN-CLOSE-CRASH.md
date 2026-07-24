# WebView2 plugin editors crash Live on close (issue 52, FIXED, patch 0045)

## Symptom

Closing a WebView2-based VST3 editor (reported with Splice INSTRUMENT,
issue 52) takes Live down with its "serious program error" dialog. The
editor itself renders and plays fine; only the close crashes.

## Root cause

A use-after-free in Wine-core ole32, not in this stack's dcomp/dxgi
patches.

- The WebView2 helper process (msedgewebview2) registers an OLE drop
  target on its own `Chrome_WidgetWin_1` child window, which is
  parented into the host's window tree. `RegisterDragDrop` stores the
  `IDropTarget` as a raw pointer in the `OleDropTargetInterface`
  window property — valid only in the registering process, but window
  properties are visible system-wide.
- On editor close, the host-side teardown revokes drag-and-drop on
  every child window it can enumerate (JUCE's `HWNDComponentPeer`
  does exactly this, and Splice INSTRUMENT behaves like a JUCE 8
  host). That calls `RevokeDragDrop` on the helper-owned window from
  Live's process.
- Wine's `RevokeDragDrop` fetched the foreign raw pointer and called
  `Release` on it in Live's address space: access violation on the
  vtable dereference, in ole32, in Live's process. Live's crash
  handler turns that into the "serious program error" dialog.

`RegisterDragDrop` already rejects windows owned by other processes;
`RevokeDragDrop` did not. Patch 0045 adds the same rejection
(`DRAGDROP_E_INVALIDHWND`), after which teardown completes and the
helper process revokes its own registration itself. Fix by Giang
Nguyen (giang17/wine commit `fafb443f85e0`, found 2026-07-23 with a
JUCE 8 WebView2 editor under yabridge, their issue 8); ported here.
Not in the `d2d1-dcomp-11.11` base and not in upstream Wine as of
2026-07-24 — re-check both on the issue 53 base bump to
`d2d1-dcomp-11.13`, and drop 0045 once the base carries it.

## Reproduction and verification, without Splice

`tools/webviewclose.c` (build: `tools/build_webviewclose.sh`, needs
`ABLETON_WINE_SOURCE` like the other PE tools) hosts a real WebView2
controller in a fake Live-anatomy editor window (per-monitor-v2 main
window, editor created in an UNAWARE thread DPI context, per
fakeplugin.c) and tears it down in selectable orders:

- `a` polite (IsVisible off, Close, Release, DestroyWindow),
  `b` DestroyWindow with a live controller, `c` release without Close:
  all complete clean on the unpatched runtime — plain teardown order
  is not the trigger.
- `e` JUCE-style: `RevokeDragDrop` over every enumerated descendant
  before Close. On the unpatched runtime this reproduces issue 52
  deterministically: `Chrome_WidgetWin_1` (owned by the helper
  process) carries `OleDropTargetInterface`, and the revoke faults in
  ole32 reading exactly that foreign pointer — the tool's exception
  handler prints the faulting module and address.
- `d` parks the editor under a hidden toplevel (Live's Learn View
  close path, issue 57 companion).

The report lands in `webviewclose-report.txt`; exit 3 means the
exception handler fired.

## Scope

Any plugin whose editor embeds WebView2 and whose host-side teardown
revokes drag-and-drop on enumerated children is affected the same way;
Splice INSTRUMENT is just the first report. The guard is generic
Wine-core hardening with no dcomp involvement, so it also covers
plugin editors under other hosts on this runtime.
