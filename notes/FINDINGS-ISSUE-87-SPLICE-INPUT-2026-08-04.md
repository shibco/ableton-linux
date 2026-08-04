# Issue 87: Splice panel input-dead after collapse/reopen. Theory review, 2026-08-04

Status 2026-08-05: fix attempt implemented on this branch, runtime verification
pending. Three changes:

1. tools/learnheal.c: the resident healer now only pokes webviews whose whole
   ancestry is Live's own pane hosts (Ableton Live Window Class,
   AbletonWebViewHelperWindow, Chrome_WidgetWin_0). Plugin webviews (CHOC,
   JUCE) are never touched. Rebuilt learnheal.exe and posteresize.exe are
   committed. Addresses T2 below.
2. patches/0070: dxgi twins of the patch 0016 subclass guards (re-bind records
   its own wndproc as original; popup-mode self-demotion on re-bind; Release
   stranding an installed subclass without its forwarding prop, which is the
   exact painted-but-input-dead shape). Addresses T3's fixable half. Applies
   cleanly on the series; dxgi.dll and wineserver compiled warning-free in a
   scratch tree; NOT run against Live yet.
3. tools/issue87-routing-trace.patch: log-only wineserver trace for the T1
   probe (not in the shipped series). One healthy-vs-broken hover capture
   decides T1; usage in the patch header.

None of this is verified against the repro. If the reporters still reproduce
with 1+2, the trace capture from 3 is the next step and pins T1.

Branch: fix/webview-splice (worktree webview-splice, off origin/main bac1bb0).

## 1. The reported facts

From ClickSentinel's report (runtime label "2026.07.23.1", but the stated base is
d2d1-dcomp-11.13 / 5c23dd1c with patches 0001-0053 plus 0054, which is later than
our v2026.07.23.1 tag; go by the stated patch list, and ask for the exact commit):

- Collapse and reopen the Splice panel. The panel keeps rendering and keeps
  responding to resize, but no mouse or keyboard input reaches it, permanently.
- The whole CHOC webview host is destroyed and recreated: new unique window class
  (CHOCWebView117967303 to CHOCWebView118003504), new HWND. Only the WebView2
  renderer process respawns; browser, GPU and utility processes survive.
- During a 10 s in-panel hover, mouse messages observed from Live's process go
  only to Live's main window in both states: 28730 healthy, 710 broken, 0 to the
  child chain either way.
- In the broken state: WindowFromPoint resolves 20/20 in-panel points to the
  webview child; WM_NCHITTEST replies HTCLIENT; capture, focus, styles, tree all
  measure identical to healthy; dcomp props balanced; patch 0016 instrumentation
  never fires; reblit timer counters read 0.
- Clicking Live's back/forward browser-navigation arrows restores input
  (found by amenohi2 on issue 34, confirmed by ClickSentinel).

## 2. The report's framing is wrong about the input path

The issue concludes the failure sits in WebView2/CHOC's composition-hosting input
forwarding (SendMouseInput re-wiring), closed-source and unobservable. CHOC's
source says otherwise (github.com/Tracktion/choc, choc/gui/choc_WebView.h):

- CHOC creates a plain WS_POPUP window ("CHOCWebView" class plus unique suffix)
  and calls CreateCoreWebView2Controller(hwnd, ...) on it: windowed hosting
  (choc_WebView.h lines 1368, 1038, 1452). Its vendored WebView2 header contains
  no ICoreWebView2CompositionController and no SendMouseInput at all.
- CHOC's wndproc handles only WM_SIZE and WM_SHOWWINDOW; everything else goes to
  DefWindowProcW (lines 1561-1572). CHOC forwards no input, ever.
- WS_EX_NOREDIRECTIONBITMAP on Chrome_WidgetWin_1 does not imply composition
  hosting: our own Learn View panes are windowed-hosted and carry the same
  styles (tools/dpispy.txt, tools/swamprobe.txt).

Consequence, and this is the load-bearing deduction: since CHOC forwards nothing
and windowed hosting has no host-side input API, the only way input can work at
all is direct Win32 delivery to Chromium's own windows (Chrome_WidgetWin_1 /
Chrome_RenderWidgetHostHWND), which are owned by the msedgewebview2 browser
process, cross-process children inside Live's tree. Healthy input works, so that
delivery works. The bug is therefore that this delivery stops for the recreated
chain. That is a Wine-observable, Wine-instrumentable failure, not a
closed-source one.

Two measurement blind spots follow:

- "0 messages to the child chain" was measured from Live's process. Message
  hooks are per-process; deliveries to the browser process's windows are
  invisible from Live. The 0 proves nothing about the real input path.
- The healthy 28730-vs-broken 710 rate at Live's main window (a 40x drop for the
  same physical hover) is unexplained under the report's model. Under ours, a
  plausible reading is that the healthy stream is reflected traffic from
  Chromium's legacy-window forwarding (LegacyRenderWidgetHostHWND passes mouse
  messages up the parent chain), which disappears exactly when direct delivery
  stops, leaving only the raw ~70/s motion rate. Unproven; the wineserver trace
  below decides it.

The "reparented into a new host window, put_ParentWindow unsupported" reading is
also unsupported: CHOC recreates the whole webview from scratch. The surviving
browser/GPU processes are the shared Evergreen browser cluster for Splice's
user-data folder, and a renderer respawn for a new CoreWebView2 in a shared
cluster is the normal pattern, not evidence of reparenting.

## 3. How input actually routes, and why the reporter's checks do not cover it

In the 11.13 base, hardware mouse routing and WindowFromPoint are different code
paths that consult the same server data differently:

- Routing: winex11 in Live's process posts the event against Live's top-level;
  the server picks the destination thread via window_thread_from_point
  (server/window.c:1069), which maps raw to virtual coordinates, then descends
  with child_window_from_point using is_point_in_window (server/window.c:933) at
  each step: WS_VISIBLE, disabled-child skip, LAYERED+TRANSPARENT skip,
  per-window DPI point mapping, visible_rect containment, win_region
  containment. The deepest window's thread gets the message; the receiving
  process then re-resolves the final HWND client-side (win32u/message.c:2625).
- WindowFromPoint: a get_window_children_from_point server request with the
  caller's thread DPI, then a client-side walk (win32u/window.c:2846) that stops
  at the first cross-thread window without consulting its wndproc.

So a window chain can pass WindowFromPoint from a prober's context and still
lose hardware routing. The state that can differ is exactly the state absent
from the reporter's dumps: visible_rect (driver-adjusted at SetWindowPos time;
the NSPA base patches 0002/0003 gate it), win_region, per-window DPI (Live
creates VST3 editor windows under a DPI-UNAWARE thread context, see
tools/webviewclose.c header; a re-attach that latches a different per-window DPI
than the first attach shifts the descent's point mapping), sibling z-order, and
the owning thread. Styles, rects and tree dumps show none of these.

Keyboard death needs no separate mechanism: windowed-hosting keyboard input
follows focus, focus follows a successful click, so mouse death implies
keyboard death.

## 4. Theories, ranked

### T1. Server-side routing state on the recreated chain (primary frame)

The recreated Chromium windows fail some is_point_in_window check server-side,
so window_thread_from_point resolves to Live's thread; Live's client-side
re-resolution can only land on Live-owned windows; input pools at Live's main
window and dies. Rendering is unaffected because presentation is the dcomp/GDI
blit path, and resize is unaffected because it flows through COM (put_Bounds),
neither touching input routing.

Why recreate differs from first create: at first launch the browser cluster
takes seconds to spawn, so the controller attaches into a settled window tree.
On reopen the cluster already runs and CreateCoreWebView2Controller completes in
milliseconds, so Chromium's SetParent/SetWindowPos sequence lands mid-collapse
layout (panel width animating, CHOC host possibly still an unmapped WS_POPUP).
Windows tolerates that ordering; our stack has several places that latch
attach-time state (NSPA visible-rect gates, layered-map delay noted in patch
0041's message, per-window DPI at creation).

Heal fit: back/forward navigation makes Chromium rebuild its
RenderWidgetHostView and legacy HWND inside a settled tree, recreating the
server-side state cleanly.

Deciding probe: a log-only wineserver patch in window_thread_from_point /
is_point_in_window printing, for each descent step during a broken-state hover,
which window was rejected by which check (visibility, transparency, DPI-mapped
point vs visible_rect, region), plus a server-eye dump of visible_rect,
win_region, per-window DPI and owning thread for the chain, healthy vs broken.
Nobody has looked at this layer; all prior instrumentation was client-side or
dcomp-side.

### T2. learnheal.exe pokes the rebuilt webview at bind time

Present and active in the reporter's environment (launcher starts it
unconditionally since 2026.07.21.2). Its matcher is any Chrome_WidgetWin_1,
anywhere, with a non-empty title and rect at least 200x200 (tools/learnheal.c:99-112);
WebView2 mirrors the page title onto Chrome_WidgetWin_1, so Splice's webview
qualifies once its page loads. A recreated webview is a new HWND, so it gets a
fresh tracked slot and a cross-process SetWindowPos nudge roughly 1-3 s after it
appears, which on a reopen is exactly bind time. learnheal's own header records
that bind-time nudges leave Chromium permanently degraded ("Nudging at bind
time leaves Chromium unable to handle later resizes", tools/learnheal.c:5-7).
The documented degradation is resize handling, not input, so the symptom match
is imperfect; but this is a resident cross-process actor firing during the
exact failure window, entirely under our control.

Deciding probe: suppress learnheal, repeat the repro. Cheapest test available;
zero build. If implicated, the low-risk fix is scoping its matcher (title or
ancestor restricted to Live's own panes), not removing the heal.

### T3. dxgi popup-mode misassignment via the process-global subclass count

The base dxgi carries a deliberate process-global heuristic
(dcomp_subclassed_target_count, factory.c:440,844-921): if any target is still
subclassed when a new WM_WINE_DCOMP_SET_TARGET bind arrives, the new target is
permanently classified as a popup. The count's increment is unconditional but
its decrement is conditional (only on the window's own thread, only from paths
that may not run in a Release-first teardown), so both a teardown overlap
(Chromium's GPU thread releasing the old swapchain lazily while the new panel
binds) and a genuine leak put the rebuilt Splice target into popup mode.

Popup mode installs a different wndproc with a different timer id and no
frame-latency signalling. Two observations make this attractive:

- The reporter's "reblit counters read 0" was measured on the full-mode timer
  path. A popup-mode target produces that reading by construction, so the
  negative result is consistent with this theory rather than evidence against
  dxgi involvement.
- The base's own comment warns a misclassified main window "loses its present
  timer".

Points against: the frame-latency stall arm predicts degraded or frozen frame
production, while the report describes correct rendering and live resize. It
needs the probe to decide whether the panel's apparent liveness is real frames
or GDI re-blits of the last comp buffer.

Deciding probes: the base already logs the mode decision
(FIXME "DComp popup-detect: target %p ... count=%ld", factory.c:865-867);
capture it across the repro with WINEDEBUG active (mind the launcher's
WINEDEBUG=-all default, issue 87's own gotcha). Also dump
GetProp(desktop, "__wine_dcomp_active"), and which of DCOMP_REBLIT_TIMER_ID /
DCOMP_POPUP_REBLIT_TIMER_ID is armed on the new target.

Related latent defect found during this review, independent of issue 87: the
dxgi subclass never received patch 0016's re-entry guards. A second SET_TARGET
on the same HWND records dxgi's own wndproc as "original"
(factory.c:902-907), and a missing __wine_dcomp_orig_wndproc prop sends every
message to DefWindowProcW (factory.c:748-749): the exact input-dead black hole
0016 fixed in dcomp.dll, still open in dxgi. The usual target (Intermediate D3D
Window) is input-transparent by design, so this is probably not issue 87, but
it should be fixed on its own merits, with regression runs for the Learn View
park/reopen cycle, M4L and JUCE/SWAM editors.

### T4. Patch 0045's return-code change steering host teardown

RevokeDragDrop on a foreign window now returns DRAGDROP_E_INVALIDHWND, a hard
error, including for foreign windows that were never registered (previously
DRAGDROP_E_NOTREGISTERED). If the JUCE-style teardown sweep in Live's process
treats a hard error as fatal and aborts its per-window loop, the old editor's
teardown completes only partially, which could feed the T3 overlap or leave
other per-window teardown undone. Also the marshalled drop-target data in the
helper process now leaks on every close. Directly relevant to issue 34
(Splice drag-and-drop, closed but reportedly still broken, same commenter).
Probe: log RevokeDragDrop calls and returns during a collapse.

## 5. Environment factors specific to Splice

- Our launcher's WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS (SwiftShader ANGLE,
  --disable-gpu-compositing, --disable-direct-composition, --no-sandbox) are
  overridden by Ableton's own flags for Live's panes, but a plugin-created
  environment inherits them for real. Splice therefore runs a browser
  configuration nothing else on this stack runs. Yet the reporter still
  observes dcomp props and an Intermediate D3D Window on the Splice chain, so
  the flag set deserves its own check (does --disable-direct-composition reach
  Splice's cluster at all, and what does the stack look like with the flags
  cleared).
- WebView2 Evergreen 150 uses delegated compositing, a path this stack was
  never tested against (notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md,
  fork issue 8). Record the prefix's WebView2 version in any repro.

## 6. Diagnostic plan, cheap first

1. learnheal off, repro on. No build. (T2)
2. Repro with WINEDEBUG explicitly set, capture the existing popup-detect FIXME
   and RevokeDragDrop returns across a collapse/reopen. Validate the capture is
   non-empty before trusting it. No build. (T3, T4)
3. Prop/timer spy on the rebuilt chain: desktop __wine_dcomp_active, wndproc vs
   __wine_dcomp_orig_wndproc, armed timer ids. Small tool, no runtime change. (T3)
4. Log-only wineserver + win32u tracing of the routing descent during a broken
   hover, plus server-eye state dump of the chain (visible_rect, win_region,
   per-window DPI, owning thread, z-order) healthy vs broken. Scratch build,
   no behavior change; note scratch builds lack PipeASIO for hand-over runs. (T1)
5. Ask the reporter for the exact build commit, desktop scale factor, and a
   z-order-preserving sibling dump of Live's main window children in both
   states.

No fix should land before one of these probes confirms a mechanism. Every
candidate change (learnheal matcher scoping, dxgi 0016-parity guards, popup-mode
re-evaluation, routing-state fix) touches machinery shared with the Learn View
park/reopen path, M4L and JUCE editors, so each needs the regression set from
notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md step 5 (Learn View open,
scroll, close, reopen; both panes at once; Splice editor close) plus this
issue's collapse/reopen cycle.
