# Resize growth findings, 2026-07-21 (RESOLVED, same day; resolution corrected later the same day)

**Correction (2026-07-21, evening, patch 0042, release 2026.07.21.2).**
The resolution below held only for the paths it checked (programmatic
`_NET_MOVERESIZE_WINDOW` tiles). Any interactive resize (WM grab op)
still ratcheted +2 px per cycle, reproduced on demand with real-input
keyboard resize grabs while Live held focus. Fresh traces
(`live-trace-interactive-20260721.log`, `live-trace-band8-20260721.log`
in `~/Projects/Code/ableton/`) show the real mechanism is parity: the
WM grants only even physical sizes (xwayland-native-scaling, 2x
framebuffer), Live's per-monitor layout emits only even sizes, and
Wine's window-to-visible frame offset is odd, so each round trip flips
parity; Live re-requests +1 over every grant regardless of the menu
band (bands 7 and 8 both ratchet), and no constant yields a fixed
point. Fix: patch 0042 aliases sub-scale WM config rounding to the
requested Win32 rect at the winex11 layer (adapted from ENCORE's
config-rounding machine, whose earlier decline in
ABLETON-WINE-ENCORE-REVIEW.md assumed an exact frame model is
possible; it is not, through an odd offset). Verified on real Live
12.4.3: interactive resizes, tiles and moves settle within 2 px once
and hold with zero creep, repeated across sessions. The band-law
"resolution" below is kept as the historical record; 0040 itself stays
shipped for one-shot accuracy.

**Resolution (2026-07-21, patch 0040 revised, shipped in 2026.07.21.1).**
The trace named below was fully analyzed: the growth is a +1px-per-WM-
configure-ack, vertical-only, self-sustaining ratchet driven by a
constant 1px disagreement over the menu-bar band — Live 12.4.3's model
is `SM_CYMENU + 4` at 96 dpi and `SM_CYMENU + 7` at 192, so with the
draft 0040 band (`+ muldiv(4,dpi,96)` = +8 at 192) Wine's NCCALCSIZE
carved 1px more than Live's model and Live re-requested window+1
forever. The band law is now `max(4, muldiv(4,dpi,96)-1)`; verified on
Live 12.4.3 and 12.4.2: WM resizes land pixel-exact and hold, zero
creep over 30s idle polls, normal idle CPU. The "probable mechanism"
in the addendum below (ENCORE's message.c DPI-context hunk) was
DISPROVEN before adoption: the trace contains zero `map_dpi_winpos`
remappings, i.e. no WM geometry was ever rounded through a wrong DPI
context in the failing sessions. ENCORE's winex11 config-rounding
machine was evaluated and not ported (it would mask the symptom; the
frame-model term is now correct). The rest of this file is the
historical record.

---

# Resize growth findings, 2026-07-21 (original, superseded above)

Live 12.4.3's main window grows on every interactive resize or WM tile at
125% display scale. Two candidate fixes were tried this session; the bug
is still present. This file records what is proven, what was ruled out,
what was changed on disk, and where the evidence for the next attempt is.

## Timeline of environment changes

- 2026-07-16 21:30: Live self-updated 12.4.2 to 12.4.3 (exe mtime; new
  `Live 12.4.3` Preferences dir).
- 2026-07-17 to 07-18: sessions ran with `Effective process DPI
  awareness: 0` (Log.txt); the IFEO dpiAwareness key was missing until
  re-applied 2026-07-19. Sessions from 07-19 on log awareness 2.
- 2026-07-18 12:11: xorg-xwayland 24.1.12 to 24.1.13 (pacman); first
  active after the 07-19 23:50 reboot.
- 2026-07-19: releases 2026.07.19.1/.2 (patches 0037-0039, unified top
  bar); top bar rewrote the prefix WindowMetrics fonts.

## Proven, with evidence

1. The failing sessions run per-monitor aware. Live logs `Effective
   process DPI awareness: 2` in every session since 07-19, including the
   sessions where growth was observed (Log.txt, `Live 12.4.3/Preferences`).
2. The 2024-era unaware doubling loop is NOT the active mechanism. The
   final failing session was traced (`+timestamp,trace+win,trace+x11drv`,
   95 MB); it contains zero `map_dpi_winpos` remappings.
3. Wine's internal frame arithmetic is self-consistent at 192 for an
   unmapped window: `tools/metricprobe` measures NC v 102 against
   `AdjustWindowRectEx(menu=1)` 98, i.e. adjust + 4 exactly (run of
   2026-07-21; compare the committed 100%-era `tools/metricprobe.txt`).
4. A mimic that models the outer rect as `client + adjust + 4*dpi/96`
   drifts +4 per WM configure on the release runtime and 0 on a runtime
   with the patch 0040 scaled band (`tools/wmresize2.c`, differential:
   run plain vs `flat` argument, drive with `xsettle moveresize`).
5. Real 12.4.3 Live still grows on the patch 0040 runtime (user
   verified twice, 2026-07-21). Therefore the mimic does not model real
   12.4.3 and the actual growth mechanism is distinct and UNIDENTIFIED.
   Patch 0040 fixed the mimic, not Live.
6. Ruled out:
   - Wine runtime regressions: rollbacks to 2026.07.11 behave
     identically under the probes. Caution: all raw (non-IFEO) probe
     runs at 125% collapse into the documented unaware loop; the
     committed drift-0 probe logs are from the 100% era. Raw-probe
     results at 125% are noise, not signal. This confounded one bisect
     this session.
   - xorg-xwayland 24.1.13 upstream content: the 24.1.12..24.1.13 diff
     is fonts/glyphs/colormap CVE fixes; no hw/xwayland changes. CachyOS
     distro patches were NOT checked.
   - The top bar font swap: Ableton Sans Small and Tahoma have equal
     vertical metrics (winAscent+winDescent over upem 1.200 vs 1.207);
     the menu bar measures the same with either.

## Primary artifact for the next attempt

`~/Projects/Code/ableton/live-resize-trace-20260721-0024.log` (95 MB,
moved from /var/tmp). Full `trace+win,trace+x11drv` of the final failing
session, 2026-07-21 00:24 to 00:28, patch 0040 runtime, and it includes
the user-performed interactive resize that showed the growth.

Suggested reading order:
1. Identify the main toplevel hwnd (search the create window trace for
   the Live window class or title, or cross-check with `tools/hwndspy`).
2. Extract its cycle around the resize: WM-side ConfigureNotify in,
   winex11 window rect mapping, NCCALCSIZE, Live's NtUserSetWindowPos
   re-request out. Attribute the inflation to the side that adds it.
3. Dump 12.4.3's real main-window style/exstyle. Every probe this
   session assumed the 12.4.2-era `0x16cf0000/0x100`; 12.4.3 may differ,
   and the whole mimic approach hinges on it.
4. Only then decide whether patch 0040's premise (Live derives
   `adjust + 4*dpi/96`) holds for 12.4.3.

## Changed on disk this session (all uncommitted)

- `patches/0040-win32u-scale-the-menu-bar-band-with-the-menu-dpi.patch`,
  plus its `patches/SERIES.sha256` line and a `scripts/build-audit.sh`
  STAMP_ONLY entry. Verified against the mimic only; did not fix Live.
  Keep or drop is an open decision.
- `tools/wmresize2.c` (differential probe, this file is the reusable
  part regardless of 0040's fate).
- `notes/ABLETON-WINE-DPI-SCALE-100.md` addendum (amended 2026-07-21 to
  record that 0040 did not resolve the user-visible growth).
- Source tree `~/Projects/Code/ableton/wine-d2d1-nspa-src`:
  `dlls/win32u/menu.c` carries the 0040 change, uncommitted.
- `~/.local/opt/wine-fixtest-menuband/`: reflink copy of the 2026.07.19.2
  runtime with the locally built win32u.so. Disposable.
- A temporary IFEO key for wmresize.exe was added to the prefix and
  removed again. The prefix is otherwise unchanged by this session.

## Addendum, later the same night: probable mechanism identified

Prompted by the report that ENCORE holds size with the same Live 12.4.3,
ENCORE's Wine delta was reviewed (github.com/wowitsjack/ENCORE,
`patches/encore-wine.patch`). It contains a `dlls/win32u/message.c` hunk
that targets the exact path this stack never fixed:

- In `handle_internal_message`, `WM_WINE_WINDOW_STATE_CHANGED` applies
  window-manager geometry (one per WM configure during interactive
  resize). Stock code, our tree line 2237: the raw physical rect is
  converted with `map_rect_raw_to_virt(rect, get_thread_dpi())` and then
  applied by `NtUserSetWindowPos`, both through the DPI context the
  window's thread happens to be in at that instant.
- Live's main thread does not hold one context (ALF per-thread contexts,
  CEF, and Wine only re-syncs on hardware-message dispatch, see
  notes/ABLETON-WINE-RESIZE-BUG.md). When the thread's context DPI
  differs from the window's at that moment, the granted rect is rounded
  through the wrong space once per configure. Live re-requests, the WM
  reconfigures, repeat: per-configure creep on WM-driven geometry only.
- This explains why every probe passed while Live failed: probes hold
  one thread in one context and never hit the mismatch. This defeated
  the wmresize2 validation of patch 0040.
- ENCORE's fix: perform the conversion and the SetWindowPos inside the
  window's own DPI awareness context
  (`set_thread_dpi_awareness_context(get_window_dpi_awareness_context(hwnd))`,
  restore after). Event-layer, app-agnostic, matches the issue #31
  doctrine. Both helpers exist in our base (win32u_private.h).
- ENCORE's patch also carries a `calc_menu_bar_size` hunk adding
  `map_user_dpi(4, window_dpi)` below framed menu bars, the same band
  patch 0040 implements via the item floor, plus an unrelated
  menu-bar theme-sampling feature relevant to the top bar work.

Status: NOT verified. The port was drafted but not staged, pending the
user's go. Falsifiable test before any fix claim: a context-flapping
probe (pm-v2 window, message loop thread switched to an unaware context)
must drift on stock and hold on a patched build; then a real-Live resize
must hold on screen. The preserved trace can independently confirm by
comparing granted vs applied rects on the main hwnd per configure.
Caution: two agent sessions were working this machine concurrently at
the time of writing; the build tree and prefix are single-occupancy.

## Related open issue

The Learn View flicker is OPEN by record, not a regression: patch 0030
is a partial mitigation and the full display-path fix is designed but
unimplemented. See `notes/ABLETON-WINE-LEARNVIEW-FLICKER.md`.
