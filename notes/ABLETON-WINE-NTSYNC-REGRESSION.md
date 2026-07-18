# ntsync missing from shipped runtimes (2026-07-17)

Every runtime shipped since 2026-07-12 had ntsync compiled out, so every NT
sync wait was a wineserver round trip: about 1.3 cores with Live running
(Live threads plus wineserver at ~45% of a core, ~9,000 context
switches/s). Fixed in 2026.07.17.1 by vendoring one kernel header into the
build container and gating the build. Sync semantics unchanged (27/27 probe
assertions against a clone of the real prefix); sync throughput up 4-50x;
wineserver out of the wake path.

## Symptom

Live idling with the ASIO device open at 256 samples: main thread and lead
audio thread ~15% each, ~10 AudioCall workers ~5% each, wineserver ~45%.
Workers wake per buffer (~187/s); each wake and wait is a wineserver round
trip.

## Root cause

ntsync needs linux/ntsync.h (kernel headers >= 6.14) at configure time.
configure drops it silently when the header is missing. wineserver opens
/dev/ntsync (server/inproc_sync.c); ntdll falls back to round trips when
the server half is absent. Two breakages:

1. The 2026-07-12 runtime (snapshot rollback-20260714T123328Z) shipped a
   wineserver without ntsync; its ntdll.so still had it. The wineserver
   hash matches neither the host build tree nor the later container
   output, so it was built somewhere without the header (probably the old
   wineasio container image; unconfirmed). The host tree's wineserver
   (build-wow64, 2026-07-04) was correct but did not ship.
2. The 2026-07-14 container build (dist 2026.07.14.2, Ubuntu 22.04) lost
   both halves: jammy's linux-libc-dev is 5.15, no ntsync.h. The GitHub
   release artifacts are the same build, so installer users are affected.

Builds through 2026-07-10 have ntsync in both binaries.

## Evidence

beta/tester-kit/probes/src/ntsyncprobe.c asserts the semantics that change
under ntsync (semaphore max and over-release, mutex recursion and
abandonment, auto-reset single wake, manual-reset broadcast, PulseEvent,
WFMO lowest-index and wait-all atomicity, APC in alertable waits,
cross-process named-object handoff, timeout accuracy) and measures event
ping-pong and semaphore churn, which proxy Live's per-buffer worker
wakeups. All runs used a reflink clone of ~/.wine-ableton (own inode, own
wineserver; Live untouched).

| run | runtime | ntsync | assertions | pingpong rt/s | sem pairs/s |
|-----|---------|--------|-----------|---------------|-------------|
| A | 2026.07.14.2 (deployed) | no | 27/27 | 75,187 | 64,267 |
| B | rollback-20260714 (07-12 build) | no (server half missing) | 27/27 | 80,645 | 67,567 |
| C | build-wow64 tree (both halves, debug) | yes | 27/27 | 222,222 | 1,351,351 |
| D | 2026.07.17.1 artifact (stripped) | yes | 27/27 | 327k-392k | 3.3-3.6M |

A vs B identical: the 07-12 build was already broken; the ntdll half alone
does nothing. Kernels without /dev/ntsync behave like run A; that fallback
is upstream-supported.

## Fix (2026.07.17.1)

- vendor/ntsync-uapi/linux/ntsync.h, copied from linux-api-headers 1:7.1-1
  (sha256 006437ee52a3e04f921df77081eb5c21c44c71f598b10ac534c6ef9e78296262,
  pinned in vendor/ntsync-uapi.sha256, verified by build.sh). The
  Containerfile copies it to /opt/ntsync-uapi; container-build.sh passes
  CPPFLAGS="-I/opt/ntsync-uapi" to configure. All 14 NTSYNC_IOC_* ioctls
  Wine 11.11 uses resolve under gcc 11 / glibc 2.35. The glibc 2.35
  baseline is untouched.
- Gates in container-build.sh next to the winealsa gate:
  HAVE_LINUX_NTSYNC_H in config.h, ntsync strings in wineserver and
  ntdll.so (pre-strip), "ntsync: yes" plus the header sha in BUILD-INFO.
- scripts/check-ntsync.sh verifies installed runtimes: static wineserver
  check plus the probe, requiring the server to hold /dev/ntsync while the
  probe runs.

Gate lessons:

- No `strings | grep -q` under pipefail: grep exits on the first match,
  strings dies of SIGPIPE, and the match reads as a failure. Count with
  grep -c.
- ntdll's ntsync strings are debug info and vanish on strip. Post-strip
  checks gate on wineserver alone ("/dev/ntsync" is rodata) and prove the
  client half dynamically.

## Open

- Install here and measure Live: wineserver expected near idle (under
  1,000 ctx/s) instead of ~45% and ~9,000/s.
- tester-kit suite, check-live-audio.sh, beta soak, tag. Release notes:
  tell 2026.07.14.2 users to upgrade. Artifacts are in dist/.
- Provenance of the 07-12 wineserver is unresolved; the gate blocks mixed
  runtimes either way.
- The 11.12/11.13 rebase baseline (ABLETON-WINE-REBASE-11.13.md) must
  include check-ntsync.sh.

## Rerun

    cp -a --reflink=always ~/.wine-ableton ~/.wine-ableton-eval
    ABLETON_WINEPREFIX=~/.wine-ableton-eval \
    ABLETON_WINE_ROOT=<runtime> scripts/check-ntsync.sh
    rm -rf ~/.wine-ableton-eval

Never run against ~/.wine-ableton while Live is up. The probe rebuilds via
beta/tester-kit/probes/build-maintainer-probes.sh (regenerates every hash
in SHA256SUMS).
