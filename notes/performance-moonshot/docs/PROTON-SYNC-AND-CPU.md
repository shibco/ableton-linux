# Proton synchronization and CPU techniques for the performance moonshot

This document helps the reader decide which of Valve Proton's synchronization
and CPU-side techniques are worth porting into ableton-wine, and which the
project already ships. Each technique gets: what it does, upstream status as
of August 2026, whether this repo has it, and how it applies to Ableton Live.

Terms used below: *wineserver* is Wine's single-threaded user-space process
that emulates the Windows kernel's object store; every classic NT
synchronization wait (mutex, semaphore, event) used to be a remote procedure
call (RPC) to it over a Unix socket. A *futex* is Linux's fast user-space
locking primitive; *eventfd* is a Linux kernel notification object exposed as
a file descriptor. *SCHED_FIFO* and *SCHED_RR* are Linux realtime scheduling
policies; *rtkit* (RealtimeKit) is a D-Bus service that grants realtime
priority to unprivileged processes.

## Wineserver architecture and its cost

Wine emulates Windows kernel objects in a separate process, `wineserver`.
It is single-threaded and event-driven. Every `WaitForSingleObject`,
`ReleaseMutex`, or `SetEvent` on a non-cached object crosses a socket
boundary twice (request and reply), serializing all clients through one
thread. For a game making thousands of synchronization calls per second this
was a long-standing CPU bottleneck
(https://www.xda-developers.com/wine-11-rewrites-linux-runs-windows-games-speed-gains/).

This repo measured the cost directly. With ntsync missing and Live idle at a
256-frame ASIO buffer, wineserver used about 45% of one core and handled
about 9,000 context switches per second; restoring ntsync raised
synchronization throughput 4 to 50 times
(notes/ABLETON-WINE-NTSYNC-REGRESSION.md:10-14).

ntsync removes *handle waits* from wineserver, but not everything:
alertable sleeps and APC (asynchronous procedure call — a callback Windows
queues onto a specific thread) delivery still go through the server
(notes/ABLETON-WINE-APC-COALESCING.md:14-18). Live's APC coalescing thread
idles at 30 to 40% of one core, and the single-threaded wineserver
serializing per-APC wakeups is the current hypothesis for a playback fault
(notes/ABLETON-WINE-APC-COALESCING.md:24-28). The registry, window
management, and cross-process handle bookkeeping also stay in wineserver.

## esync

*What it does:* a Wine patch set by Elizabeth Figura (CodeWeavers, 2018)
that replaces wineserver round trips for events/semaphores/mutexes with
per-object `eventfd` descriptors handled in-process
(https://www.xda-developers.com/wine-translating-windows-games-linux-proton-effortless/).

*Upstream status:* never merged into upstream Wine; shipped in
wine-staging through version 10.15 (not enabled by default) and in Proton,
where it is the fallback when fsync is unavailable
(https://wiki.archlinux.org/title/Wine). Known downside: one file descriptor
per synchronization object, so descriptor-hungry apps hit `ulimit -n`.

*In this repo:* no. `scripts/setup-prefix.sh:56` explicitly unsets
`WINEESYNC`/`WINEFSYNC`, and the base is plain upstream Wine
(patches/BASE.txt:1-5). Superseded by ntsync; no reason to add it.

*Ableton applicability:* none beyond historical. ntsync is strictly better:
no fd pressure, correct "wait-all" semantics, already shipped here.

## fsync and futex2 / futex_waitv

*What it does:* fsync is Figura's follow-up patch set that emulates NT waits
with futexes in shared memory, faster than esync and without the fd cost. It
originally needed an out-of-tree kernel op (`FUTEX_WAIT_MULTIPLE`). The
upstream substitute, `futex_waitv()` from the "futex2" series by André
Almeida (Collabora), landed in Linux 5.16 in 2022
(https://lwn.net/Articles/1056417/,
https://docs.kernel.org/userspace-api/futex2.html). Proton's fsync uses
`futex_waitv` on kernels 5.16+; fsync remains Proton-only, never merged into
upstream Wine (https://wiki.archlinux.org/title/Wine).

*In this repo:* no, same evidence as esync (scripts/setup-prefix.sh:56).
Also superseded: ntsync achieves the same in-kernel waits with exact NT
semantics, which futexes cannot express for wait-for-all
(https://www.techtimes.com/articles/321677/20260727/freebsd-builds-bsd-native-ntsync-driver-launches-amd-rocm-compute-port.htm).

*Ableton applicability:* none. Skip.

## ntsync

*What it does:* a Linux kernel driver (also by Figura) exposing `/dev/ntsync`
with ioctls that implement NT semaphores, mutexes, events, and
any/all-waits in the kernel, with exact Windows semantics including
alertable waits via an alert event
(https://docs.kernel.org/userspace-api/ntsync.html). Wine's `ntdll` performs
waits in-process through the device instead of calling wineserver.

*Upstream status (verified, August 2026):*

- Kernel: an incomplete first cut merged in Linux 6.10, marked broken
  (https://www.phoronix.com/news/Linux-6.10-Merging-NTSYNC); the completed,
  usable driver shipped in Linux 6.14 (released 2025-03-24)
  (https://www.phoronix.com/news/Linux-6.14-NTSYNC-Driver-Ready,
  https://kernelnewbies.org/Linux_6.14). This repo's own check script says
  the same in shorthand: "no /dev/ntsync (kernel < 6.14?)"
  (scripts/check-ntsync.sh:38).
- Wine: initial ntsync support merged upstream in Wine 10.15
  (https://www.phoronix.com/news/Wine-10.15-With-NTSYNC); first stable
  release with it is Wine 11.0, January 2026
  (https://news.tuxmachines.org/n/2026/01/13/Wine_11_Officially_Released_with_NTSync_Support_Vulkan_H_264_De.shtml).
  This repo's base is Wine 11.13 (patches/BASE.txt:4-5), so ntsync is
  upstream code here, not a Proton port.
- Proton: GE-Proton enabled ntsync by default in release 10-10, July 2025
  (https://www.gamingonlinux.com/2025/07/ge-proton-10-10-brings-tweaks-for-warframe-darksiders-mortal-kombat-1-and-ntsync-enabled-by-default/).
  Valve's official Proton 11.0 beta (April 2026) rebased on Wine 11 and
  added ntsync
  (https://wccftech.com/valve-quietly-rebased-proton-on-wine-11-and-linux-gaming-just-got-windows-level-frame-pacing/);
  Proton 11.0-1 stable followed on 2026-07-08
  (https://www.gamingonlinux.com/2026/07/proton-11-0-1-officially-released-to-expand-windows-games-on-steamos-linux/,
  https://github.com/ValveSoftware/Proton/wiki/Changelog).
- Unverified: community guides claim upstream Wine ≥ 10.15 also gained an
  eventfd-based in-process fallback for kernels without `/dev/ntsync`
  (https://github.com/AdelKS/LinuxGamingGuide). This repo's own measurements
  show its fallback build still crossed wineserver for every wait
  (notes/ABLETON-WINE-NTSYNC-REGRESSION.md:38-46), but that build lacked
  the ntsync header at configure time, which may gate the fallback too.
  Not confirmed either way.

*In this repo:* yes, fully shipped and regression-guarded.

| Layer | Evidence |
|---|---|
| Vendored UAPI header (kernels ≥ 6.14) | vendor/ntsync-uapi/linux/ntsync.h:43-57; SHA-256 pinned, checked in build.sh:25 |
| Container build injects header | Containerfile:94-98 |
| Build fails if configure misses it | scripts/container-build.sh:104-125 (`HAVE_LINUX_NTSYNC_H`, both runtime halves) |
| Installed-runtime verification | scripts/check-ntsync.sh:31-38 (static gate), :68-71 (server must open `/dev/ntsync` when it exists) |
| Semantics + throughput probe | beta/tester-kit/probes/src/ntsyncprobe.c:1-10; runs A–D table in notes/ABLETON-WINE-NTSYNC-REGRESSION.md:38-43 |
| Regression history | builds 2026-07-12/14 silently lost ntsync; fixed 2026.07.17.1 (notes/ABLETON-WINE-NTSYNC-REGRESSION.md:1-6) |

One host-side gap remains: the driver needs `/dev/ntsync` to exist, which
requires kernel ≥ 6.14 *and* the module loaded. Distributions are moving to
load it by default (Fedora 44 change proposal:
https://discussion.fedoraproject.org/t/f44-change-proposal-enable-ntsync-kernel-module-for-all-users-system-wide/161786),
but this repo only checks for the device; nothing helps a user whose kernel
has the module unloaded.

*Ableton applicability:* this is the single most valuable technique on this
list, and it is already in. Live runs many worker threads with many short
waits at audio-period rates (a 256-frame buffer at 48 kHz is a 5.3 ms
cycle). The repo's probe measured event ping-pong rising from ~75k to
327–392k round trips/s and semaphore churn from ~64k to 3.3–3.6M pairs/s
with ntsync active (notes/ABLETON-WINE-NTSYNC-REGRESSION.md:38-43). Lower
per-wait latency and lower wineserver load directly protect audio
deadlines. Remaining limit: alertable sleeps/APC delivery still use
wineserver (notes/ABLETON-WINE-APC-COALESCING.md:14-18).

## WINE_CPU_TOPOLOGY and core parking

*What it does:* `WINE_CPU_TOPOLOGY=N:cpu,cpu,...` is a Proton-side Wine
patch that caps and remaps the logical processors reported to the Windows
app — used to fix games that break on high core counts and to pin games
onto specific cores (e.g. the V-Cache CCD on Ryzen X3D parts)
(https://github.com/ValveSoftware/Proton/issues/7719,
https://github.com/CachyOS/proton-cachyos/issues/178). Proton ships
per-game default CPU limits driven by this variable. It is not upstream
Wine. "Core parking" in this context is not a Wine feature at all: it is
Feral GameMode parking non-cache cores on hybrid CPUs so the game stays on
the fast ones (https://github.com/ValveSoftware/Proton/issues/8075;
GameMode project: https://github.com/FeralInteractive/gamemode).

*In this repo:* groundwork only. The launcher computes a sensible value —
cap 8 CPUs, honor `taskset`/cgroup restrictions, user override wins — and
exports it (scripts/ableton-live:75-108), but the code is explicit: "Inert
on this runtime until the patched ntdll/wineserver consumer lands; exported
as groundwork only" (scripts/ableton-live:78-79). The consumer patch is
missing.

*Ableton applicability:* medium. Live scales its audio worker pool to the
reported CPU count; capping at 8 avoids diminishing-returns contention on
many-core hosts, and an affinity-aware variant could keep Live off E-cores
or the non-V-Cache CCD. Unlike a game, Live under PipeWire can also be
constrained correctly from the host side with `taskset`, so this is a
convenience and correctness-of-reported-count play, not the only lever.

## Scheduler, realtime priority, and rtkit

*What Proton does:* very little itself. Proton relies on the host: Feral
GameMode (governor switching, renicing, core parking) and, increasingly,
sched_ext schedulers (Linux 6.12+, https://docs.kernel.org/scheduler/sched-ext.html)
in gaming distributions. Wine and wineserver have no rtkit integration;
rtkit is how PipeWire, not Wine, gets realtime priority for its data
threads without PAM limits (https://docs.pipewire.org/page_module_rt.html).

*In this repo:* a deliberate, different design. The launcher starts Wine
under `SCHED_RR` priority 10 when `chrt -r 10 true` succeeds
(scripts/ableton-live:780-783); PAM limits grant rtprio 95
(scripts/setup-realtime.sh:74); PipeASIO separately requests SCHED_FIFO 15
for its data loop (notes/ABLETON-WINE-RT-SCHEDULING.md:1-7). Boosting
wineserver itself with `chrt -f -p 95` was considered and deliberately left
out — it needs root per launch, and raising a single-threaded server above
its callers can invert the contention it means to fix
(scripts/setup-realtime.sh:23-25). The known open risk: Live's realtime
threads make synchronous calls into a `SCHED_OTHER` wineserver, a classic
priority-inversion shape (notes/ABLETON-WINE-RT-SCHEDULING.md:39-41), and
launcher-wide RR on low-core machines is unmeasured
(notes/ABLETON-WINE-RT-SCHEDULING.md:29-42).

*Ableton applicability:* high, and already partially exploited. ntsync
shrinks the wineserver traffic that made the inversion frequent, but the
APC path keeps it alive. The untested A/B (wineserver priority and CPU
affinity) is the cheapest remaining scheduler experiment; the repo already
has the A/B harness (`ABLETON_RT=off`, scripts/bench-run.sh,
notes/ABLETON-WINE-RT-SCHEDULING.md:43-81).

## Per-app environment variables that matter for CPU

| Variable | What it does | Where it stands here |
|---|---|---|
| `WINE_CPU_TOPOLOGY` | Cap/remap CPUs reported to the app (Proton patch) | Exported by launcher, consumer missing (scripts/ableton-live:75-108) |
| `WINEDEBUG=-all` | Cuts logging overhead; fixme spam stalled Live's UI thread | Already set (scripts/ableton-live:16-17) |
| `WINEESYNC` / `WINEFSYNC` | Toggle esync/fsync in builds that have them | Deliberately unset; N/A on this runtime (scripts/setup-prefix.sh:56) |
| `PROTON_NO_ESYNC` / `PROTON_NO_FSYNC` | Proton launch-time sync overrides | Proton-only; irrelevant outside Steam (https://github.com/ValveSoftware/Proton) |
| `WINE_D3D_CONFIG=csmt=0x1` | WineD3D command-stream threading | Already set (scripts/ableton-live:18); GPU-side, not CPU-sync |

No Proton CPU variable other than `WINE_CPU_TOPOLOGY` has meaning for this
repo; the rest of Proton's per-game env surface is GPU/DXVK territory.

## Wineserver replacement or rewrite efforts

No credible full wineserver replacement or rewrite exists as of August
2026; this is a search-based negative finding, not a certainty. What exists
is a decade-long strategy of *shrinking* wineserver's role: the 2008
shared-memory mutex discussion on wine-devel never landed
(https://list.winehq.org/hyperkitty/list/wine-devel@list.winehq.org/thread/UYWGMILMVYVQKUREZ4Q7ATYVRFC2YIZU/);
wine-tkg's "fastsync" (shared-memory sync via the out-of-tree "winesync"
module) was the direct predecessor of ntsync
(https://github.com/Frogging-Family/wine-tkg-git/issues/936) and is now
obsolete; community build sets are dropping their esync/fsync patches in
favor of upstream ntsync (https://github.com/NelloKudo/WineBuilder/releases).
Valve's and CodeWeavers' engineering goes into ntsync and into moving
functionality into per-process libraries (win32u, ntdll), not into a new
server. For this project, "replace wineserver" is not an option; "make the
remaining wineserver traffic cheaper or rarer" is.

## What transfers to a real-time audio DAW

Games and DAWs differ in one way that matters: a game can drop a frame; a
DAW cannot miss a buffer. The sync techniques transfer directly because
Live's thread pattern — many workers, many short waits, hard periodic
deadlines — is the pattern ntsync was benchmarked on, and this repo already
has the wins and the guards. The remaining moonshot surface is the traffic
ntsync does not cover (alertable waits, APC delivery), the priority
relationship between Live's RT threads and wineserver, and CPU-count/affinity
reporting. Proton's esync/fsync era is closed for this project; nothing
there is worth resurrecting.

## Key opportunities

1. **Close the `/dev/ntsync` host gap** — detect a kernel ≥ 6.14 with the
   ntsync module unloaded and tell the user exactly how to load it (or ship
   a `modprobe.d`/udev drop-in via setup scripts). Impact: high (users on
   qualifying kernels silently lose 4–50x sync throughput otherwise).
   Effort: low. Evidence: scripts/check-ntsync.sh:38,68-71 checks but does
   not remediate; notes/ABLETON-WINE-NTSYNC-REGRESSION.md:38-43 quantifies
   the loss.
2. **Port Proton's `WINE_CPU_TOPOLOGY` consumer patch into the runtime** —
   the launcher already computes and exports the value; the ntdll/wineserver
   consumer is the missing half. Impact: medium (fixes worker-pool
   oversizing on >8-core hosts; enables V-Cache/P-core pinning). Effort:
   medium. Evidence: scripts/ableton-live:75-108, explicit "Inert …
   groundwork only" at scripts/ableton-live:78-79.
3. **Run the deferred wineserver priority/affinity A/B** — test
   `chrt -f` boost and/or CPU affinity for wineserver under playback load
   using the existing `bench-run.sh` harness; the boost is documented as
   deliberately excluded pending measurement, not as rejected. Impact:
   medium (targets the Live-RT-thread vs SCHED_OTHER-wineserver inversion).
   Effort: low. Evidence: scripts/setup-realtime.sh:23-25,
   notes/ABLETON-WINE-RT-SCHEDULING.md:39-41,43-81.
4. **Attack the alertable-wait/APC wineserver path** — ntsync does not
   cover alertable sleeps or APC delivery; Live's APC coalescing thread
   burns 30–40% of a core idle, and per-APC wineserver serialization is the
   current fault hypothesis under load. Impact: high. Effort: high.
   Evidence: notes/ABLETON-WINE-APC-COALESCING.md:1-6,14-28.
5. **Verify the upstream non-ntsync in-process fallback and, if real,
   enable it in builds** — Unverified: community sources say upstream
   Wine ≥ 10.15 has an eventfd in-process fallback when `/dev/ntsync` is
   absent; this repo's header-less fallback builds paid full wineserver
   round trips. If the fallback is compile-gated on the same header, no
   action; if not, users on kernels < 6.14 get a free win. Impact: medium.
   Effort: low. Evidence: https://github.com/AdelKS/LinuxGamingGuide vs
   notes/ABLETON-WINE-NTSYNC-REGRESSION.md:38-46.
6. **Publish hybrid-CPU affinity guidance** — document `taskset` /
   GameMode-style core selection for Intel P/E and Ryzen X3D hosts running
   Live, matching what Proton users already do per game. Impact: low to
   medium. Effort: low. Evidence:
   https://github.com/ValveSoftware/Proton/issues/8075; launcher already
   honors cgroup cpusets (scripts/ableton-live:85-97).
