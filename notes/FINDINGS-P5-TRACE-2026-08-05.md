# Why Live used much CPU when it was idle, and what changed

This document explains what we measured on 2026-08-05, why Live used much
CPU on an empty project, and what the new runtime changes. It keeps the
numbers and the decisions. Each patch file contains its own technical
description. The section "Where to look" lists the files.

## What we measured

We let Live 12.4.3 run on an empty project with nothing playing, and we
counted the requests that Live sends to the wineserver. The wineserver is a
helper program that Wine uses to share information between programs. Every
request uses CPU on both sides.

Result: about 5,700 requests each second while Live did nothing.

Three groups caused most of these requests:

| Request group | Each second | Cause |
|---|---|---|
| Hook bookkeeping | about 2,400 | Live installs one Windows hook (a filter for window messages) on its own main thread. Wine asked the wineserver about this hook three times for every message. |
| Queue updates | about 800 | Wine sent the same message-queue settings to the wineserver again and again, with no change. |
| Window checks | about 400 | Live asks "did this window change?" about 200 times each second. The answer was always "no", but each check still made two requests. |

The rest, about 2,100 requests each second, is real message traffic between
Live's audio engine and its interface. Live sends these messages on Windows
too. We cannot remove them. We can only make each one cheaper, and only
some of that work is done (see "What is not done").

We also measured which thread does this work: Live's main interface thread
is the busiest thread in the process. This matches the request data: the
requests above all come from that thread.

## What we did not find

The earlier theory said that APCs caused the idle CPU use. APCs are small
callbacks that Windows programs send between threads. The measurement
showed zero APC requests while Live is idle. The theory was wrong for idle
CPU. The fix for APCs is still useful, because Live uses APCs when it
plays.

## What we changed

The runtime has five new patches. Each patch removes one kind of request.
All five are on by default.

| Patch | What it removes | Traffic removed |
|---|---|---|
| 0001 | Short waits that made one request each time | Small when idle, larger when Live plays |
| 0002 | Callbacks between threads of the same program, which used two requests each | Small when idle, larger when Live plays |
| 0003 | Hook bookkeeping for hooks inside one thread. Wine now remembers the hook list and only asks again when the list changes | About 2,400 requests each second |
| 0004 | Repeated queue settings. Wine now sends them only when they change | About 800 requests each second |
| 0005 | Window checks that must answer "no". Wine now answers directly when nothing changed | About 400 requests each second |

Two switches turn the new code off for a test:

```bash
WINE_APC_FASTPATH=off WINE_MSG_FASTPATH=off ableton-live
```

## How we checked it

- A test program (`tools/apcprobe.c`) checks the callback rules that Live
  depends on. All 14 checks pass on the old runtime. All 14 pass on the new
  runtime, with the new code on and with it off.
- The three request groups in the table fell by more than 99% in the
  measured window: hook bookkeeping from 84,878 requests to 2, queue
  updates from 84,614 to 412, window checks from 42,702 to 86.
- Live was started and used many times on the new runtime, with no new
  warnings and no errors.
- The build passes the full audit: 95 checks, 72 patches verified.

## One deliberate difference

Windows delivers thread callbacks in a strict order. The old runtime kept
that order. The new runtime delivers same-program callbacks first, before
callbacks that come from the wineserver (file operations and special
callbacks). The order inside each group is unchanged. We know no program
that depends on the mixed order, and the test program checks both orders.
If a program misbehaves, turn the new code off with the switches above and
open an issue.

## What is not done

- One measurement is still open: the CPU difference on an active desktop,
  where Live's interface updates often and the message rate is high. The
  request reduction is largest in that state. During this work, the screen
  of the test computer was locked, so we could not take this measurement.
- A measurement of Live while it plays is still open. It will show how much
  the two callback patches (0001, 0002) help during playback.
- On a Linux kernel older than 6.14, every wait still goes through the
  wineserver, and idle CPU stays high. The Debian 13 kernel is older than
  6.14. The lasting fix for these kernels (the fsync fallback, item P7 in
  the roadmap) is not started. The current fix is a newer kernel.

## Where to look

- `patches/performance/0001-*.patch` to `0005-*.patch`: the changes. Each
  patch message has the full technical description, with source references.
- `tools/apcprobe.c`: the test program for callback rules.
- `notes/performance-moonshot/MOONSHOT-ROADMAP-TRACKER.md`: items P5 and
  P13 track this work.
