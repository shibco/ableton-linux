# WebView2 Learn View flicker: diagnosis and fix plan

2026-07-27. Covers the open-pane Learn View artifact reported on the
production prefix: a grey cutout box over the pane, alternating with the
rendered page at about 5 switches per second while the pane is open.

## Status

Resolved 2026-07-27, by a different route than the plan below: enabling
Live's GPU renderer (removing `-_ForceGdiBackend` from `Options.txt`)
eliminates the visible flicker on both the production 11.11 runtime and
the 11.13 build of main. Measured: the 5 Hz reblit still fires but all
30 of 30 pane frame captures hash identical, on both panes, at 200%
scale, under WebView2 149. The WebView2 browser flags turned out to be
bystanders: Live hardcodes `--disable-gpu --disable-gpu-compositing
--disable-direct-composition` into its browser processes, verified from
`/proc/<pid>/cmdline`. The maintainer confirmed the result in use, with
idle CPU at 1-2%. Shipped on branch `fix/interface-drawing-on-gpu`
together with Wine patch 0053 for the below-minimum resize fight the
GPU renderer exposed. See `ABLETON-WINE-GPU-RENDERER.md` (this directory).

The diagnosis and plan below are preserved as written; steps 1 and 2 of
the plan were executed and produced the finding above. The remaining
steps did not run.

## Production state

- Launcher: `~/.local/bin/ableton-live`, prefix `~/works/plugs/studio`.
- Runtime: `~/works/wine-d2d1-nspa-11.11`, dist 2026.07.22.1,
  wine 11.11 base, patches 0001 through 0043 plus pipeasio.
- `learnheal.exe` is staged and launched. It does not resolve the
  artifact on this setup.
- WebView2 Evergreen runtime in the prefix: 149.0.4022.80, installed by
  Microsoft's updater on 2026-07-24, after the runtime above was built
  and after all Learn View testing. Chromium 149 uses delegated
  compositing, a presentation path this stack was never tested against.

## Why the artifact exists

Patch 0041 made WebView2's DirectComposition frames visible by adding a
keep-alive reblit into the target window. Chromium also paints its own
stale software frame into the same window. Two writers, one window: the
correct frame and the stale grey frame alternate at the reblit cadence,
which is the 5 Hz flicker. `learnheal.exe` masks the race by forcing one
re-render so both writers hold identical content. On the production
setup (2x scale, WebView2 149) the frames never converge, so the mask
fails and the race stays visible.

`ABLETON-WINE-LEARNVIEW-FLICKER.md` records the mechanism.
`ABLETON-WINE-WEBVIEW2-COMPOSITOR.md` states the conclusion: no
timer or gate tuning escapes a two-writer conflict on one window.

## History of prior claims

- Patch 0041 plus learnheal shipped in 2026.07.21.2. The open-pane race
  was negotiated, not fixed, and the notes of the time say so.
- The issue 57 close-path work (the 0044 gate draft, then the win32u
  dce.c cross-process visible-region fix) was verified on a test copy on
  2026-07-25 and never shipped. It sits on the unpushed branch
  `fixes/issue-57-crossproc-visrgn` (commit ccd0975). Production never
  changed.
- Patch 0041 also removed the old 3 second reblit suspension, which
  turned a transient close-path artifact into a permanent one (issue 57).
- A compositor backport, patches 0049 through 0051, was committed
  2026-07-26 on branch `fix/d2d1-dcomp-giang17-webview2-compositor`
  (commit 1da6b59), build-verified and audit-verified only. Set aside
  on 2026-07-27: the plan below starts from `main` and does not use
  that branch. The proper form of the same fix is a future base bump,
  taken when the fork rolls the work into a `d2d1-dcomp-11.13`
  refresh.

## Upstream research (2026-07-27)

giang17/wine, the base fork:

- Every WebView2 cross-process compositing fix (2026-07-23 through
  07-25) lives only on the `d2d1-dcomp-11.0` branch (head `324a7babe0`).
  The `d2d1-dcomp-11.13` branch this project's base comes from was
  snapshotted 2026-07-22, one day earlier, and contains none of it
  (verified at file level in `dlls/dcomp/device.c`).
- The fork documented and fixed three fight mechanisms that match this
  artifact: a keep-alive timer reblit overwriting the host's painting
  (`324a7babe010`, adds an unchanged-content hash gate,
  `WINE_DCOMP_SKIP_UNCHANGED` and `WINE_DCOMP_HOST_RESTORE` opt-outs), a
  ping-pong between root-swapchain presents and tree composites
  described as visible flicker (`92847a5169be`, later simplified by
  `5a3091953446`), and a comp child window z-fight producing a grey box
  over the UI (`396042c48bb4`, the closest literal match to the cutout).
  Patch 0041's reblit is the primitive analog of the fork's tree timer
  and predates all three fixes. Patches 0049 through 0051 backport this
  work onto the 11.13 base.
- Fork issue 8 is the open risk: WebView2 149/150 promotes page content
  into delegated compositing after 2 to 3 frames. The root swapchain
  then carries only opaque punch frames; real content must travel as
  IDCompositionTexture gated on D3D11 monitored fences. A reporter
  running the fork's full fix series on 2026-07-25 still saw a grey
  placeholder on runtimes 149.0.4022.98 and 150.0.4078.83, while runtime
  109 rendered correctly. The production prefix runs 149.0.4022.80. The
  compositor backport alone may therefore not fix the Learn View here.
  https://github.com/giang17/wine/issues/8

Wine upstream: no commits to `dlls/dcomp` since 2026-06-15, and nothing
after wine-11.13 touching cross-process child rendering or DCE visible
region caching. No help expected from a base bump alone.

WebView2 on real Windows: the same failure class exists there
(MicrosoftEdge/WebView2Feedback issue 5574, content painted but never
presented to the host HWND). `--disable-gpu-compositing` via
`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` consistently eliminates it by
bypassing the DirectComposition presentation route. Chromium never
detects that its dcomp calls succeed without actual composition, so it
never falls back on its own.

## Fix plan

Rewritten 2026-07-27. Supersedes the first plan of the same date, which
built on the set-aside compositor backport branch. This plan starts
from `main` (11.13 base, patches 0001 through 0048).

Step 1, build the control and baseline it. `main` has never been
built; the 11.13 bump exists only as patch metadata. Container build of
`main` as-is, no new WebView2 patches, audit passing, installed to a
test location only. Then two baselines with the same instruments:

- Production 11.11 runtime, production launcher, production prefix:
  xdmg damage signature over 30 seconds on the open Learn View
  (expected: pane-rect stamps at about 5 Hz), frame captures hashed to
  prove alternating content, dcompspy and hwndspy output, WebView2
  version recorded.
- The new 11.13 build on a reflink copy of the prefix, same scale,
  same WebView2 149, same captures.

Expected: the base bump alone does not move the artifact, since the
two-writer race is in patch 0041, which is unchanged. The 11.13
baseline is the control every later change is measured against, and
the build is the base every later change ships on.

Step 2, no-build experiments, in parallel on reflink copies:

1. WebView2 version pin. Install a pre-149 fixed-version WebView2
   runtime into a copy prefix and point Live at it with
   `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER`. If the flicker collapses to
   the pre-149 behavior (fossil for a few seconds, then heals) or
   better, the 2026-07-24 Evergreen update is confirmed as the
   trigger and the pin is a shippable stopgap. Tradeoff to decide
   before shipping: a pin freezes an old Chromium, which matters if
   Learn View content ever loads remote pages.
2. Browser-argument retest under 149. The recorded flag results
   predate the 149 update, so their verdict is stale. One systematic
   pass through `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` targeting
   delegated compositing: `--disable-features=RemoveRedirectionBitmap`,
   the delegated compositing feature disable, and
   `--disable-gpu-compositing`. Low expectation (Live's browser
   process sets its own flags), cheap to run, honest to retest.

Step 3, close-path fixes rebased onto `main`, smallest first. Port the
win32u dce.c cross-process visible-region fix from
`fixes/issue-57-crossproc-visrgn` (xdmg-verified on 11.11; the code is
identical on 11.13) and decide the 0044 parked-pane gate draft. Add
build-audit fingerprint entries, renumber as needed. This closes
issue 57 on the new base regardless of the open-pane outcome.

Step 4, decision gate for the open-pane race, driven by Step 2
measurements:

- If the pin or the flags produce xdmg-zero and frame-stable captures
  at the production scale: ship that, with the Evergreen guardrail
  below. The compositing-model fix then arrives later as a clean base
  bump when the fork rolls its 2026-07-23 through 07-25 WebView2 work
  into a `d2d1-dcomp-11.13` refresh; asking the fork author for that
  refresh is worth doing now, since it matches their stated branch
  policy.
- If neither works: stop and present the evidence before touching the
  compositing layer. No local compositing work starts without an
  explicit decision on it.

Step 5, production verification. Install the chosen build to the
production runtime directory with a rollback snapshot. Run the full
regression protocol at the production scale: Learn View and
documentation sidebar open, scroll, hover, close, reopen; both panes
at once; Splice editor close (issue 52 regression check); resize
stress; JUCE and SWAM regression checks. The evidence pack (xdmg logs,
frame hashes, screenshots, WebView2 version) lands in the repository.
The user confirms by eye last.

Step 6, guardrails. The launcher records the prefix's WebView2 version
at every start and warns when Evergreen changes it. Decide whether to
pin WebView2 or let it float. Update issue 57 and open a public issue
for the open-pane artifact with accurate status.

## Verification standard

The word fixed requires all of the following, with evidence files
attached to the claim:

- the change installed in the runtime the production launcher uses,
- xdmg reports zero anomalous pane-rect damage stamps, open and closed,
- frame captures hash-stable over the observation window,
- on the production prefix, production launcher, production scale,
- the prefix's WebView2 version recorded at test time.

Anything less is reported as exactly what it is: patch written, patch
built, verification pending, or verification failed. Interim reports
name the exact paths exercised.

## References

- `ABLETON-WINE-LEARNVIEW-FLICKER.md` (0041 mechanism and cause)
- `ABLETON-WINE-WEBVIEW2-COMPOSITOR.md` (backport and protocol,
  in the `fix/d2d1-dcomp-giang17-webview2-compositor` worktree)
- Issue 57 (close-path flicker, still open, accurate)
- https://github.com/giang17/wine/issues/8
- https://github.com/MicrosoftEdge/WebView2Feedback/issues/5574
