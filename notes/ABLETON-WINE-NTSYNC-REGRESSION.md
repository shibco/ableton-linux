# ntsync build regression

Status: fixed in 2026.07.17.1. Runtimes built from 2026-07-12 through
2026-07-14 omitted ntsync because the build environment lacked
`linux/ntsync.h`. The build now vendors that header and fails if either
runtime half is missing.

## Effect

In the affected build, every NT synchronization wait crossed the wineserver.
With Live idle and its ASIO device open at 256 frames, the sampled wineserver
used about 45% of one core and handled about 9,000 context switches per
second. The probe measured 4 to 50 times more synchronization throughput
after ntsync was restored.

## Root cause

Wine needs `linux/ntsync.h` at configure time. Configure omits ntsync when
the header is absent. `wineserver` opens `/dev/ntsync`; `ntdll` falls back to
server round trips when the server half is unavailable.

Two releases exposed the gap:

1. The 2026-07-12 runtime shipped `ntdll.so` support but a `wineserver`
   without ntsync. The origin of that wineserver remains unknown.
2. The 2026.07.14.2 container build omitted both halves because Ubuntu
   22.04's `linux-libc-dev` package did not provide the header.

Builds through 2026-07-10 contained both halves.

## Evidence

`beta/tester-kit/probes/src/ntsyncprobe.c` checks semaphore, mutex, event,
wait, APC, cross-process, and timeout semantics. It also measures event
ping-pong and semaphore churn as proxies for Live's worker wakeups. Each run
used a reflink clone of `~/works/plugs/studio` with its own wineserver.

| run | runtime | ntsync | assertions | pingpong rt/s | sem pairs/s |
|-----|---------|--------|-----------|---------------|-------------|
| A | 2026.07.14.2 (deployed) | no | 27/27 | 75,187 | 64,267 |
| B | rollback-20260714 (07-12 build) | no (server half missing) | 27/27 | 80,645 | 67,567 |
| C | build-wow64 tree (both halves, debug) | yes | 27/27 | 222,222 | 1,351,351 |
| D | 2026.07.17.1 artifact (stripped) | yes | 27/27 | 327k-392k | 3.3-3.6M |

Runs A and B show that `ntdll` support alone is insufficient. A kernel
without `/dev/ntsync` uses Wine's supported fallback path.

## Fix

- `vendor/ntsync-uapi/linux/ntsync.h` is pinned by
  `vendor/ntsync-uapi.sha256`. `build.sh` verifies its SHA-256 digest.
- `Containerfile` copies the header to `/opt/ntsync-uapi`, and
  `scripts/container-build.sh` passes `CPPFLAGS=-I/opt/ntsync-uapi` to
  configure.
- The container build checks `HAVE_LINUX_NTSYNC_H`, both unstripped runtime
  halves, and the `BUILD-INFO` record.
- `scripts/check-ntsync.sh` checks the installed wineserver, runs the
  semantics probe, and confirms that the server opens `/dev/ntsync` when the
  device exists.

## Build notes

- Do not use `strings | grep -q` under `pipefail`. `grep` exits after the
  first match, `strings` receives `SIGPIPE`, and the pipeline reports a
  failure. Count matches with `grep -c`.
- Stripping removes the ntsync strings from `ntdll.so`. The installed-runtime
  check uses the `/dev/ntsync` string in `wineserver` and proves the client
  half by running the probe.

## Run the check

Use a clone of the Live prefix:

```bash
cp -a --reflink=auto "$HOME/works/plugs/studio" "$HOME/works/plugs/studio-ntsync-test"
WORKS_PLUG="$HOME/works/plugs/studio-ntsync-test" \
  WORKS_RUNTIME="/path/to/runtime" \
  ./scripts/check-ntsync.sh
rm -rf -- "$HOME/works/plugs/studio-ntsync-test"
```

Do not run the probe against a prefix that Live is using. The script refuses
a prefix with an active wineserver.
