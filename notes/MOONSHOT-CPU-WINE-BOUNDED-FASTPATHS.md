# Wine CPU wait trial

The release setting uses Wine's regular wait route. Set
`WINE_APC_FASTPATH=1` for an isolated test of the NTSync route. Keep release
launch rules at the regular setting through the test gate in this document.

## Release decision

The branch contains one reviewed performance patch:

| Patch | Release setting | Test setting |
|---|---|---|
| `performance/0001` | regular Wine wait | `WINE_APC_FASTPATH=1` selects the NTSync wait |

An alertable wait lets another thread wake it with an APC. An APC asks a thread
to run a small task. The patch moves a zero-object alertable delay from
wineserver to the calling thread's existing NTSync alert event.

Both build routes use the same one-patch list. Their checks count and identify
that patch. Wine reads the setting once per process. The read stays safe when
several threads start together.

The values `1`, `on`, `true` and `yes` select the trial route. They accept any
letter case. An unset, empty or unrecognised value selects the regular route.
The values `0`, `off`, `false` and `no` also select the regular route.

Wine selects the trial after its device and alert checks succeed. Every other
check or wait result uses the regular route. Linux 7.1.8 accepts a zero-object
wait with an alert event (`drivers/misc/ntsync.c:866-900`). The kernel wait uses
a fixed deadline and permits signal handling.

The trial needs a measured result from loaded Live Sets. The Live 12.4.3 idle
trace from 5 August 2026 recorded 0 user APC requests. Loaded playback and
plug-in tests provide the relevant cases. Use matched 30-second runs for the
CPU decision.

## Host suspend timing

The 2 routes measure suspended time differently. Wine's regular route uses
`CLOCK_BOOTTIME`, which advances during host suspend
(`dlls/ntdll/unix/server.c:795-810` and
`dlls/ntdll/unix/sync.c:114-130`). The NTSync trial uses `CLOCK_MONOTONIC`,
which pauses during host suspend (`dlls/ntdll/unix/sync.c:425-445`).

The host measurement on 26 August 2026 found a 17,302,527,783,051 ns difference
between those clocks. The difference confirms separate timing rules on this
host.

NTSync v7.1.8 provides monotonic and real-time deadlines
(`Documentation/userspace-api/ntsync.rst:276-310`). Real-time deadlines respond
to manual and network clock corrections. Each NTSync choice therefore differs
from Wine's current boottime rule.

Microsoft states that relative alertable waits pause during low-power states on
Windows 8 and later. See the Microsoft guides for
[single-object waits](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobjectex)
and
[multiple-object waits](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitformultipleobjectsex).
That rule resembles the trial's monotonic timing. Live and plug-in tests decide
release safety.

Complete this suspend test before a release review:

1. Run the regular route and the trial route from identical prefix snapshots.
2. Test finite relative, finite absolute and infinite waits.
3. Queue an APC before suspend, during suspend and immediately after resume.
4. Record elapsed time and APC count for every case.
5. Use a separate process with a fixed end time.
6. Repeat each case after a cold start.

Keep every release candidate at an unset value or an explicit regular-route
value through this test.

## Ideas reserved for future tests

The earlier `performance/0002` idea changes how an APC reaches another thread in
the same process. A future test must cover APC order, special APCs, access
rights, target exit and handle reuse. It must also cover movement between
client and server routes.

The earlier `performance/0003` idea saves a list of Windows message hooks. A
future test must cover self-removal and hook changes from another thread. It
must also prove the life of each saved hook object.

The earlier `performance/0004` idea saves a queue mask. Source review found
consistent mask writers. A paired upstream `user32:msg` run produced 185
flagged assertions with the idea enabled and 186 with its rollback setting. The
one differing IME assertion appeared in the rollback run. An earlier pair
produced 206 and 186 flagged assertions.

A future `performance/0004` test must use a nested send, a callback and a
3-second heartbeat. It must also prove every required wake. These tests cover
the message wait while callbacks run.

The earlier `performance/0005` idea uses a saved window-state result. Repeated
`updateprobe` runs produced the same flagged result with the idea active and
with `WINE_MSG_FASTPATH=off`. Affected runs reported zero paint queue state
after window invalidation. The X driver treated the test window as effectively
invisible. Use a stable visible-window test before another review.

The branch keeps whole-process CPU placement and priority at their base
settings.

## Test programmes

`tools/apcprobe.c` builds a small Windows test programme. Its 45 checks cover
zero-delay, finite relative, finite absolute and infinite alertable waits. The
infinite case wakes through a user APC.

Additional checks cover APC order, input and output completion, special APCs,
access, handle reuse and suspend. Run the exact Wine build with
`WINE_APC_FASTPATH=1`, with `WINE_APC_FASTPATH` unset and with
`WINE_APC_FASTPATH=off`.

`tools/ntsync-alert-wait-probe.c` provides an isolated observer. `LD_PRELOAD`
loads the observer before Wine starts. A trial run records
`MOONSHOT_NTSYNC_ALERT_WAIT`. The unset and explicit off runs record zero
matching lines.

Set `MOONSHOT_NTSYNC_ALERT_WAIT_FAULT=1` to return `EIO` for the trial wait. The
same 45 checks must pass. This result proves the immediate return to Wine's
regular wait.

Use the observer with the exact x86-64 `apcprobe` process and its small test
prefix. The observer expects the 3-part kernel request used by this process.
Other Wine paths can use a 2-part request. Use source tracing for a wider Wine
test.

Case 11 signals readiness before its infinite wait and uses a 50 ms parent
delay. The case proves the infinite wait and queued APC result. The observer
proves that the trial route ran. Add an external signal after kernel wait entry
to prove exact event order during the suspend test.

## Release checks

Build the exact patched Wine target with Wine's warning rules. Record these
results from matched loaded Sets:

- combined Live and wineserver CPU use or request traffic falls
- PipeWire `ERR` and xrun issue counts match or improve the regular route
- all 45 `apcprobe` checks give the same result in each setting
- runtime, prefix snapshot, Set, buffer size, sample rate and launch policy match
- the host suspend test passes every case

The opt-in result proves route selection and wait behaviour. The loaded Set
result measures the CPU benefit.

After a partial finite wait, the regular route uses the remaining time. The
fault observer proves the immediate error case. Future fault tests must cover
alert event cancellation between kernel wake and server processing. They must
also cover a delayed kernel error.
