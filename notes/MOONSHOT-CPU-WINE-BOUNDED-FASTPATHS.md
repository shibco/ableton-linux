# Bounded Wine CPU fast path

## Decision

This branch carries exactly one reviewed performance patch:

| Patch | Default | Bounded intervention |
|---|---|---|
| `performance/0001` | on; `WINE_APC_FASTPATH=off` rolls back | Replaces an alertable, zero-handle `NtDelayExecution` wineserver wait with the calling thread's existing NTSync alert event. |

The build container and Nix derivation apply, count, stamp, and audit that same
one-member performance series. A missing NTSync device or alert fd, or an
NTSync error, returns to Wine's ordinary `server_wait` path. The environment
gate is read once with `pthread_once`; this fixes the data race in the older
experiment's unsynchronised first-call cache.

Linux v7.1.8's `drivers/misc/ntsync.c:866-900` count bound rejects values above
`NTSYNC_MAX_WAIT_COUNT` but does not reject zero; when `alert` is present it
appends that event as the sole queued object for a count-zero wait.
`ntsync_schedule()` uses an absolute
hrtimer and `TASK_INTERRUPTIBLE`, which matches Wine's existing absolute NTSync
deadline conversion and EINTR retry.

This is not yet a measured Live CPU win. The 2026-08-05 Live 12.4.3 idle trace
recorded no user-APC requests, so 0001 is not an explanation for that trace's
idle wineserver traffic. Its plausible benefit is limited to playback or
plug-in workloads that repeatedly enter alertable delays. A matched 30-second
Set matrix remains the performance gate.

## Deferred and rejected experiments

- The old `performance/0002` same-process APC queue remains excluded. APC FIFO,
  special APCs, access rights, target exit, handle reuse, and transitions
  between client and server routing make it materially broader than an
  alert-only wait.
- The old `performance/0003` hook snapshot remains excluded. A snapshot can
  outlive self-unhook and cross-thread hook mutations; request-count reduction
  does not establish hook-object lifetime safety.
- The old `performance/0004` queue-mask memo is deferred, not proven broken.
  Static review found no concrete data race or missing mask writer, and a paired
  upstream `user32:msg` run found 185 failures with the gate on and 186 with it
  off; the exact multiset difference was one off-only IME assertion. An earlier
  206/186 pair was therefore test/environment variability, not attribution.
  The patch still changes the reentrant `SendMessage` wait loop without a
  deterministic nested-send, callback-reentrancy, 3-second heartbeat, or
  no-lost-wakeup probe. That is insufficient evidence for a default-on change.
- The old `performance/0005` known-clean `GetUpdateRect` shortcut is excluded,
  but the earlier claim of proven Win32 corruption is withdrawn. Repetition
  showed the companion `updateprobe` failing both with the shortcut enabled and
  with `WINE_MSG_FASTPATH=off`. On failed runs `GetQueueStatus(QS_PAINT)` was
  zero after `InvalidateRect`; wineserver deliberately ignores redraws for an
  effectively invisible window. The current `ShowWindow`/`UpdateWindow`
  top-level fixture does not deterministically establish visibility under the
  X driver, so it neither convicts nor clears 0005.
- No whole-process affinity or priority change is part of this branch.

## Probes and acceptance

`tools/apcprobe.c` is the retained CRT-free PE acceptance probe. Its focused
cases cover no-APC zero, relative finite, and absolute finite delays plus an
infinite alertable delay woken by a user APC. The older FIFO, I/O completion,
special-APC, access, handle-reuse, and suspend cases remain defense-in-depth
around the ordinary APC drain; they are not evidence for the rejected APC
queue experiment. Run the probe against the exact build with the default and
with `WINE_APC_FASTPATH=off`.

`tools/ntsync-alert-wait-probe.c` is a test-only `LD_PRELOAD` observer. Enabled
runs must emit `MOONSHOT_NTSYNC_ALERT_WAIT`; rollback runs must emit none. With
`MOONSHOT_NTSYNC_ALERT_WAIT_FAULT=1`, it returns `EIO` only for count-zero
`NTSYNC_IOC_WAIT_ANY` calls carrying an alert fd. The same 45-check `apcprobe`
result then proves the immediate generic-error fallback without disturbing
handle-bearing NTSync waits. This shim is never installed or launched by the
product.

The exact patched Wine target must compile with Wine's warning policy. A
release report must also show:

- lower process-plus-wineserver CPU or request traffic on a loaded Set;
- no regression in PipeWire ERR/xrun deltas;
- identical `apcprobe` results with the fast path enabled and disabled;
- the same runtime, prefix snapshot, Set, quantum, sample rate, and launch
  policy on both sides.

`WINE_APC_FASTPATH=off` is a rollback control, not a tuning knob. Probe success
proves bounded semantics and, when paired with the ioctl observer, reachability;
it does not by itself prove a Live CPU reduction. A generic ioctl error after
part of a finite relative wait uses the same remaining-time calculation as a
spurious alert, so it cannot silently restart the full delay; the injector
proves the immediate arm. Forced cancellation of the alert event between kernel
wake and wineserver drain and a deliberately delayed ioctl failure remain
fault-injection gaps; neither is claimed as tested here.
