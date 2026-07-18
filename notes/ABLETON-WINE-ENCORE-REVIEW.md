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
