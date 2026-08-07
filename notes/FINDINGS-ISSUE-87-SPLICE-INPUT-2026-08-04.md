# Issue 87: Splice panel ignores input after collapse and reopen

This note records what we know about issue 87, what we changed on the
fix/webview-splice branch, and what test decides the rest.

Written 2026-08-04, revised 2026-08-05. Branch: fix/webview-splice
(worktree webview-splice, started from origin/main bac1bb0).

## Current state and what to do next

Three changes sit on this branch. None is verified against the bug yet.

1. tools/learnheal.c. learnheal is a small helper that our launcher starts
   with Live. It nudges Live's Learn View pane once so the pane draws
   correctly. Before this change it also nudged webview windows that belong
   to plugins, including the Splice panel, every time Splice rebuilt its
   panel. Now it only touches windows whose parents are Live's own pane
   windows. The rebuilt learnheal.exe is committed.
2. patches/0070. Fixes three defects in our dxgi patch stack. dxgi is the
   Wine library that manages swapchains, the buffers a program draws frames
   into. Our stack attaches a helper to some plugin windows there, and that
   helper could end up eating all input for a window while the window kept
   drawing. The exact conditions are in the patch and in the "Theory 3"
   section below. The patch compiles clean but has not run against Live.
3. tools/issue87-routing-trace.patch. A logging patch for wineserver, the
   Wine process that decides which window receives each mouse event. It is
   not part of the shipped patch series. Build a test runtime with it, record
   one hover over the panel while it works and one after it breaks, and the
   log names the exact check that fails. Usage steps are in the patch header.

Next step: build a runtime from this branch and ask a reporter to repeat the
collapse/reopen test. If the panel still breaks, run the trace and read the
log. The reporters reproduce the bug reliably, so one session answers it.

## What the bug looks like

Reported by ClickSentinel. Their report labels the runtime "2026.07.23.1"
but describes the 11.13 Wine base with patches 0001 through 0054. That
combination is newer than our v2026.07.23.1 tag, so ask for the exact build
commit. The facts from the report:

- Collapse the Splice panel in Live's browser, then reopen it. The panel
  still draws and still resizes, but clicks, hover and keys stop reaching
  it. It stays broken until the plugin reloads or Live restarts.
- The rebuild is real: Splice destroys its webview window and creates a new
  one with a new window class name and a new window handle. Of the WebView2
  helper programs, only the renderer process restarts. The browser, GPU and
  utility processes keep running.
- During a 10 second hover inside the panel, a message monitor inside Live
  counted mouse messages only at Live's main window: 28730 while healthy,
  710 while broken, zero at the panel's windows in both states.
- While broken, every standard check still passes: the window-under-point
  query resolves the panel's window, the window answers messages, focus and
  capture are clean, window styles and the window tree match the healthy
  state, and our patch 0016 instrumentation never fires.
- Clicking Live's back and forward browser arrows repairs the panel. Found
  by amenohi2 in issue 34, confirmed by ClickSentinel.

## What the report gets wrong

The report concludes that the failure lives inside WebView2's closed-source
input forwarding and cannot be observed from our side. The source code of
CHOC, the library Splice uses to embed its webview, shows otherwise. CHOC is
public at github.com/Tracktion/choc, file choc/gui/choc_WebView.h.

- CHOC creates one plain window and hands it to WebView2 in windowed mode
  (choc_WebView.h lines 1368, 1038, 1452). Windowed mode means WebView2
  creates its own child windows inside that window and receives input
  through them. The forwarding API the report describes belongs to a
  different mode that CHOC does not use.
- CHOC forwards no input itself. Its window procedure, the function that
  receives a window's messages, handles only resize and show messages and
  passes everything else to the default handler (lines 1561-1572).

This changes the whole picture. Nothing in the plugin forwards input, so
while the panel works, mouse events must arrive directly at the child
windows that WebView2 created. Those child windows belong to the
msedgewebview2 browser process, a separate program. The bug is therefore
that this direct delivery stops after the rebuild, and Wine makes that
decision, so Wine can log it.

Two of the report's measurements do not show what they appear to show:

- "Zero messages at the panel's windows" came from a monitor inside Live's
  process. A monitor in one process cannot see messages delivered to
  another process's windows. The zero is expected in both states and rules
  nothing out.
- The drop from 28730 to 710 messages at Live's main window is a real
  signal. A likely explanation: while the panel works, the browser process
  reflects extra messages toward Live's window, and that reflection stops
  when delivery stops. The trace patch settles this.

The report's "reparented into a new host window" reading also falls away.
CHOC builds a complete new webview. The surviving browser and GPU processes
are the shared WebView2 installation reusing one browser per profile, which
is its normal behaviour.

## How Wine decides who gets a mouse event

Two different code paths answer "which window is under the pointer", and
they can disagree. That disagreement is why the report's checks passed while
input stayed dead.

- Delivery. wineserver picks the receiving thread in
  window_thread_from_point (server/window.c:1069). It walks down the window
  tree and tests each window with is_point_in_window (server/window.c:933):
  the window must be visible, not a disabled child, not marked transparent
  to input, the point must fall inside the window's visible rectangle after
  scaling it by the window's DPI (its display scale factor), and inside the
  window's shape region if one is set.
- Queries. The WindowFromPoint function that the report used runs a
  different walk with the calling program's own scale factor
  (win32u/window.c:2846).

A window chain can pass the query and still lose delivery. The state that
decides delivery does not appear in any style or tree dump: the visible
rectangle, the shape region, the per-window scale factor, the stacking
order between siblings, and the owning thread. The report compared styles,
rectangles and tree structure, which is exactly the state that both paths
share.

Keyboard input needs no separate explanation. In windowed mode the keyboard
follows focus, and focus follows a successful click. Dead mouse means dead
keyboard.

## Theories, strongest first

### Theory 1: wineserver rejects the rebuilt windows during delivery

The new child windows fail one of the delivery checks, so every mouse event
lands in Live's own queue and stops at Live's main window. Drawing survives
because our composition path copies frames into the window regardless, and
resizing survives because it travels through COM calls, not through input.

Why only the rebuild breaks: at first launch the browser takes seconds to
start, so WebView2 attaches its windows into a settled layout. On reopen
the browser is already running, attachment completes in milliseconds, and
the windows are created while the panel is still mid-collapse. Windows the
operating system tolerates that order. Several of our patches record window
state at creation time and could freeze the bad moment.

Why the arrow buttons repair it: navigation makes the browser rebuild its
input window inside a settled layout, which recreates the state cleanly.

Test: build with tools/issue87-routing-trace.patch, capture one healthy and
one broken hover, and read which check rejects which window. This is the
one measurement nobody has taken.

### Theory 2: learnheal nudged the rebuilt panel

learnheal matched any large titled Chrome_WidgetWin_1 window on the
desktop. WebView2 titles that window after the page, so Splice's panel
matched, and every rebuild produced a fresh window that earned a new nudge
a few seconds later. learnheal's own header records that a badly timed
nudge leaves a webview permanently degraded.

Weaknesses: learnheal waits for the window's size to settle before it
nudges, and its known damage is resizing, not input. The bug also
reproduces too reliably for a one-second scanner to be the whole story.

Test: the fix is committed. Reporters can also test the old runtime by
killing learnheal.exe before the repro.

### Theory 3: our dxgi helper swallowed input after a rebind

Our dxgi patches attach a helper window procedure to some plugin windows.
Patch 0016 fixed a family of bugs in the equivalent dcomp helper: rebinding
the same window recorded our own helper as the "original" handler, and
losing the recorded original turned the window into one that draws but
ignores every message. The dxgi copy never received those guards, and its
release path could remove the recorded original while the helper stayed
installed. That produces exactly "draws, resizes, ignores input".

Two details fit issue 87. The reporter's zero readings came from counters
on our full-mode timer path, and a misassigned rebind runs on a different
timer, so their zeros are consistent with this theory rather than evidence
against it. One detail does not fit: the panel appears to draw fresh
frames, and this failure should degrade drawing too.

Test: patch 0070 is committed. The mode decision already logs a FIXME line,
now including a rebind flag; capture it during a repro.

### Theory 4: patch 0045 changed how the old panel tears down

Patch 0045 makes RevokeDragDrop refuse windows of other processes and
return a hard error. If the plugin's cleanup loop stops at the first hard
error, part of the old panel's teardown never runs. That could feed
theory 3's overlap or leave other state behind. This path also touches
issue 34, the Splice drag-and-drop bug, reported by the same people.

Test: log RevokeDragDrop calls and returns during a collapse.

## Environment facts specific to Splice

- Our launcher exports browser flags (software rendering, composition
  disabled, sandbox off) for WebView2. Live's own panes override them with
  Ableton's flags, but a plugin-created webview inherits ours. Splice
  therefore runs a browser configuration nothing else on this stack runs.
  The reporter still sees composition windows on the Splice chain, so check
  whether the flags reach Splice's browser at all.
- WebView2 version 150 composites pages through a path this stack never
  tested (notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md, fork
  issue 8). Record the prefix's WebView2 version in any repro.

## Rules for changes in this area

Land no behaviour change here before a probe confirms its mechanism. Every
candidate touches machinery shared with the Learn View pane, Max for Live
and JUCE plugin editors. Each change needs the regression list from
notes/ABLETON-WINE-GPU-RENDERER-WEBVIEW2-DIAGNOSIS.md step 5 (Learn View
open, scroll, close, reopen; both panes at once; Splice editor close) plus
this issue's collapse/reopen cycle. Scratch builds carry no PipeASIO, so a
test runtime has no audio; that does not affect this repro.

## Data to request from reporters

- The exact commit their runtime was built from.
- Their desktop scale factor.
- A dump of Live's main window's child windows that preserves sibling
  order, taken healthy and broken.
