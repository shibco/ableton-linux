# ENCORE review: adopted hunks (2026-07-14)

[ENCORE](https://github.com/wowitsjack/ENCORE) is a sibling project: a
guided Wine loader for Ableton Live 11/12 built on a custom-patched vanilla
Wine, whose entire Wine delta ships as one `patches/encore-wine.patch` plus
a wizard shell-script stack. Reviewed 2026-07-14 for hunks worth adopting;
two stability fixes were ported as patches 0033 and 0034 (exported from a
disposable worktree on base 182ae79b, commits 21be973f and 283d8fa9 there —
see [../patches/BASE.txt](../patches/BASE.txt)).

## Adopted

- **0033 — ntdll `WINE_DISABLE_UNIX_MOUNT_REPARSE` opt-out.** From the
  `dlls/ntdll/unix/file.c` hunks, ported unchanged in behavior. Unix mount
  boundaries were reported as `IO_REPARSE_TAG_MOUNT_POINT` junctions that
  carry no `FSCTL_GET_REPARSE_POINT` data; Live's browser treats those as
  unresolvable and skips them. With the variable set, mount points report
  as plain directories. The launchers set it to 1.
- **0034 — winex11 XdndStatus flush.** From the
  `dlls/winex11.drv/event.c` hunk, ported unchanged: flush each XdndStatus
  reply so a queued XdndLeave from a fast source cannot overtake the
  acceptance. Symptom without it: intermittent refused drops when dragging
  from file managers under Xwayland.

## Not adopted

The rest of `encore-wine.patch` was left out:

- its comdlg32 XDG file-dialog portal backend overlaps patch 0031, which
  is upstream Wine MR !10060 v5 plus the MusicBee responsiveness follow-up
  — upstream provenance wins, and applying both would double-register the
  comdlg32 unixlib;
- the remaining hunks address behaviour not observed on this stack.

Re-review ENCORE before taking anything else from it: it moves fast, and
the overlap with 0031 is a hard dedupe, not a merge.

## Addendum 2026-07-21: the two growth candidates evaluated

For the 12.4.3 growth bug (FINDINGS-RESIZE-GROWTH-2026-07-21.md, now
RESOLVED), two more ENCORE hunks were evaluated:

- **win32u/message.c `WM_WINE_WINDOW_STATE_CHANGED` in the window's own
  DPI context.** Adoptable in principle (small, self-contained), but the
  preserved failing-session trace contains zero `map_dpi_winpos`
  remappings — the wrong-context rounding this hunk fixes never occurred
  in our failing regime. Not the mechanism; not ported.
- **winex11 config-rounding suppression machine.** Its suppression class
  (sub-scale deltas at integer Wine DPI) matches the observed +1px/ack,
  and it would have masked the symptom, but the real mechanism was a 1px
  menu-band frame-model error, fixed properly in the revised patch 0040.
  Not ported; keeps ENCORE's 400-line state machine out of the tree.
- Its `calc_menu_bar_size` `+ map_user_dpi(4, window_dpi)` band is the
  same model class as our 0040 (ENCORE's law gives +8 at 192; the trace
  proved Live's model is +7 — see FINDINGS). Equivalent, not adopted.

Also verified 2026-07-21: ENCORE's WebView2 flags are byte-identical to
our launcher's, and ENCORE disables dcomp.dll by default — on this stack
that posture makes Live's WebView2 show its error page (no lessons at
all), so it is not transferable. ENCORE's Wine delta has not moved since
2026-07-14 (later commits are packaging-only).
