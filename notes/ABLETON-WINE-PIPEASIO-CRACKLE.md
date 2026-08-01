# PipeASIO crackle: causes and fix plan

Status: plan, 2026-07-26. Nothing implemented.

This note identifies the faults behind the crackle reports, the fix for each,
the order the dependencies force, and the four questions that decide what to
build first.

It extends `notes/ABLETON-WINE-PIPEASIO-RTKIT.md`, the issue #49
investigation log on the `investigate/issue-49-pipeasio-crackle` branch. It
also answers `ASIO-DIAGNOSIS.md`, an outside review of #49 written the same
day and held outside this repository.

Source paths point at three trees. `src/` means the vendored PipeASIO 1.2.2
source in `vendor/pipeasio-1.2.2.tar.gz`. `server/` and `dlls/` mean the Wine
11.13 base. `context.c` and `impl-node.c` mean PipeWire 1.6.8. Every other
path is this repository.

## Which report maps to which fault

The two reporters in #49 have different faults. Two further reports
corroborate the third and fourth causes.

| Reporter | Signature | Cause |
|---|---|---|
| yioannides, #49 | `quantum 192 != host buffer_size 256`, clean after a reboot, garbled after suspends, clean in Bitwig at 192 | C1 with C2 |
| Rob-goblin, #49 | Spread-out crackle, 30 to 50 percent CPU on an empty set, cured by installing CachyOS | C6, untested |
| phoneticalb, upstream #4 | Xruns after other audio plays, CPU meter above 200 percent, quantum correct throughout | C3 |
| ClickSentinel, #49 | Crackle stops when all tracks freeze | C3 |

The build machine runs CachyOS with rtprio 99 and a kernel that provides
`/dev/ntsync`. It cannot reproduce C3, C4, C5, or C6. Treat "works here" as
no evidence.

## How PipeWire decides the quantum

A forced quantum wins by recency. No clamp takes part. Both the driver's
warning text and the outside review assume clamping, and both send readers to
settings that cannot produce the fault.

Read against PipeWire 1.6.8 `pw_context_recalc_graph` (`context.c:1586`):

- A global `clock.force-quantum` in the settings metadata wins absolutely.
  `get_quantums` sets `global_force_quantum` (`context.c:1236`, `1468`), and
  the per-node loop then skips every `node.force-quantum` in the graph.
- Otherwise the last node whose `node.force-quantum` changed value wins,
  ranked by a monotonic stamp. Upstream documents this as "the last node to
  be activated with this property wins".
- The stamp advances only on a value change (`impl-node.c:1293`). Writing the
  same value again changes nothing.
- `clock.min-quantum` and `clock.max-quantum` bound the quantum only when no
  node forces one. `clock.quantum-floor` and `clock.quantum-limit` bound it
  always.
- PipeWire skips its own power-of-two rounding whenever a node forces a
  quantum, which is how 192 exists on that machine.

Two consequences drive the fix. Advice to relax `clock.min-quantum` or
`clock.max-quantum` cannot help, so withdraw it. A global
`clock.force-quantum` belongs to subject `PW_ID_CORE`, which never goes away,
so the pin outlives the application that set it and persists until the daemon
restarts. That produces the exact pattern in #49: a reboot clears it, a
suspend preserves it, and it appears after another audio application runs.
`pipewire-jack` writes that key when `jack.global-buffer-size` is set.

## Causes

| id | Fault | Location |
|---|---|---|
| C1 | The driver keeps playing after losing the quantum negotiation | `src/audio.c:1411`, `:1438` |
| C2 | The driver discards buffer sizes that are not powers of two, in silence | `src/asio.c:1951`, `src/config.c:130` |
| C3 | Live's DSP workers get no realtime priority while the thread driving them does | `server/thread.c:265` |
| C4 | The launcher puts the whole Wine process on SCHED_RR 10 | `scripts/ableton-live:647` |
| C5 | The driver falls back to no realtime instead of RTKit | `src/audio.c:208` |
| C6 | A kernel without `/dev/ntsync` sends every Live worker wakeup through wineserver | host kernel |
| C7 | Third-party realtime threads outrank the graph driver | user's machine |
| C8 | USB devices resync without enough headroom | user's machine |
| C9 | The seeded duplex default puts two clock domains in one graph | `scripts/setup-prefix.sh:482`, `src/audio.c:1014` |
| C10 | Nothing captures the driver's output, so users cannot see any of this | `scripts/ableton-live:686` |

### C1: playing on after losing the negotiation

`audio_activate` requests `node.force-quantum = buffer_size`
(`src/audio.c:657`). When the request loses, `audio_on_process` still calls
Live's `bufferSwitch` with `buffer_size` frames every cycle, warns once
behind a `static bool`, and continues.

At a graph quantum of 192 against a host buffer of 256, the graph takes 192
of every 256 rendered frames. A quarter of the audio never reaches the
device, the truncation point moves each cycle, and the result steps the
waveform 250 times a second at 48 kHz while the transport runs 1.333 times
fast. The 1024 case gives 5.33 times, which matches the reported 35-second
clip playing in 8 seconds. The capture path zero-fills the same quarter.

Buffer-size changes only change the ratio, and `fixed_buffer_size = true`
leaves Live one size to choose from.

### C2: the driver never offered 192

`configure_driver` and the INI loader both reject any size outside
`[16, 8192]` or off a power of two, then substitute the compile-time 1024
without a message. `PIPEASIO_PREFERRED_BUFFERSIZE=192` therefore becomes
1024 and makes the mismatch four times worse.

Live accepts non-power-of-two sizes. It creates 882-sample and 960-sample
buffers against FlexASIO, and it retries with the driver's preferred size
when its own stored size fails. Ableton's guidance names powers of two as a
recommendation. The driver's own check causes the whole failure.

### C3: one realtime thread waiting on threads that have none

Wine 11.13 maps NT thread priorities to niceness only, caps realtime-class
requests into the application band first, and applies nothing at all unless
`RLIMIT_NICE` allows negative nice. `server/thread.c:265` still reads
`FIXME: handle realtime priorities using SCHED_RR if possible`.

PipeASIO's data loop holds SCHED_FIFO 15. That thread calls `bufferSwitch`
and waits inside Live for a worker pool that any desktop thread preempts,
which inverts priority for as long as desktop scheduling latency lasts.
Upstream #4 bisects to the commit that first made that thread realtime, and
freezing tracks removes the workers it waits on.

### C6: wineserver round trips

[ABLETON-WINE-NTSYNC-REGRESSION.md](ABLETON-WINE-NTSYNC-REGRESSION.md)
measures the cost: without ntsync,
Live idle with its ASIO device open at 256 frames leaves wineserver using
about 45 percent of one core at about 9000 context switches per second, with
synchronization throughput 4 to 50 times lower.

The device needs kernel 6.14 or newer with the driver present.
`scripts/check-ntsync.sh` tests for it. The word `ntsync` appears nowhere in
the README, the launcher, or the installer, so an affected user sees only the
symptom.

### C9: two clock domains

The capture side connects to the PipeWire default source and the playback
side to the default sink, resolved independently
(`audio_preferred_default_node`, `src/audio.c:1014`). When neither resolves,
the driver takes the first device it discovered (`src/audio.c:1068`).

A default source on different hardware from the default sink puts two clocks
in one graph. One becomes a follower, PipeWire resamples it, and it resyncs
whenever it drifts past its target window. That produces periodic crackle
across every stream in the graph, which no buffer size corrects. The
`spa.alsa: hw:M2p: follower ... resync` line in #49 is that event. C8 governs
whether the follower copes.

### Working baseline

Taken on the build machine on 2026-07-26 with Live open:

```
settings: clock.quantum 512, min 64, max 2048, force-quantum 0, rate 48000
node:     Ableton Live 12 Suite, node.force-quantum 256, node.latency 256/48000
pw-top:   R 74  256 48000  alsa_input...analog-stereo   (driver)
          R 73    0     0   + alsa_output...analog-stereo
          R 106 256 48000   = Ableton Live 12 Suite   BUSY 270us  B/Q 0.05
```

Note two things even here. The capture device drives the graph, which is C9
in its harmless form because both devices are the same card. And
`clock.quantum` reads 512 while the graph runs at 256, so the settings
metadata reports the configured default rather than the running quantum.

## Fixes

| id | Fix | Lands in |
|---|---|---|
| F0 | Capture the driver's output, add `scripts/audio-report.sh`, warn in preflight, correct the misleading warning text | launcher, driver |
| F1 | Converge the quantum or go silent | pipeasio patch 0003 |
| F2 | Accept any size the graph runs, and log every adjustment | pipeasio patch 0004 |
| F3 | Map Windows realtime thread priorities to SCHED_FIFO per thread | new wine patch |
| F4 | Default `ABLETON_RT` to off | launcher |
| F5 | Add an RTKit fallback to `audio_rt_acquire` | pipeasio patch 0005 |
| F6 | Document the `/dev/ntsync` requirement and the quantum-pin symptom | README |
| F7 | Offer C1, C2, C5 upstream | pipeasio |
| F8 | Prefer one device for both directions, and report when two appear | driver, seeded config |

### F1 in detail

Four layers. Each one helps on its own.

**Predict.** Bind the `settings` metadata over the registry exactly as
`audio_cache_metadata` already binds `default` (`src/audio.c:1738`), read
`clock.force-quantum`, and report a non-zero value from `GetBufferSize`
before Live calls `CreateBuffers`. No node beats a global force, so this
settles that case with no host cooperation.

Prediction reaches no further. `clock.quantum` gives the configured default,
not the running quantum. Other nodes' `node.force-quantum` values do appear
over the registry, but the arbitration stamp does not, so the winner stays
uncomputable. Observation carries the rest.

**Adopt.** Store the observed quantum every cycle, not only in follow-device
mode (`src/audio.c:1405`). When it differs from the host buffer size across
two consecutive watcher polls, write `node.force-quantum` to 0, take the
observed value as the host buffer size, and request `kAsioResetRequest`
through the existing config-watcher path (`src/asio.c:605`), which already
carries the 1.2.0 deadlock fix and the 1.2.1 use-after-free fix. Send the
latency-changed notification, because `GetLatencies` reports one buffer each
way.

Drop the force rather than re-assert it. Re-writing the same value wins
nothing, because the stamp advances only on a change. Re-asserting means
writing 0 and then the value again, and a forced quantum change suspends
every follower in the graph through `reconfigure_driver`
(`context.c:1267`). Keep that sequence available for an explicit "take the
graph" option, and leave it out of the default.

**Fail safe.** While the sizes disagree, publish silence and zero the input.
A user recovers from silence and a log line. `PIPEASIO_ALLOW_QUANTUM_MISMATCH=on`
restores the old behaviour.

**Size buffers for the limit.** The driver replaces `pw_filter`'s default
buffer parameter with one sized to a single ASIO period
(`src/audio.c:699`). The default it overrides uses `clock.quantum-limit` so
that a larger quantum always has somewhere to go. Restore that.

## Order

1. F0. Zero risk, and every later step needs the measurements it produces.
2. F2, then F1. Fixes yioannides, closes the worst artifact class, touches no
   scheduling.
3. F8. Cheap, and removes a cause that only stays unreported because nobody
   can see it.
4. F6, and the reply to #49.
5. Stand up the test matrix and take a bench-run.sh baseline.
6. G2, then F3 if the gate passes.
7. F4, measured on a low-core machine.
8. F5.
9. F7, continuously.

Three constraints bind the order. F3 precedes F4, because whole-process RR is
today the only realtime Live's workers receive. F4 precedes F5, because RTKit
requires a finite `RLIMIT_RTTIME` and a GUI thread at RR 10 that overruns it
kills the process. The test matrix precedes every scheduling change.

Steps 1 to 4 are ready to start.

## Regressions

Hold these across the whole effort:

- The driver publishes no audio while the negotiated sizes disagree.
- Threads change scheduling policy only when they ask.
- Nothing ships on build-machine validation alone.
- Every new patch gets a FINGERPRINTS or STAMP_ONLY entry in
  `scripts/build-audit.sh`, or the build fails at step 8/8.
- Patch numbers get checked across every unmerged branch before use.

| Fix | Risk | Mitigation |
|---|---|---|
| F0 | Log growth, home paths in a public paste | Rotate and cap, keep paths out of the report |
| F1 | Live ignores the reset (G1) | Predict still settles a global pin; fail-safe covers the rest |
| F1 | Reset storms | Two-poll confirmation, `last_reset_quantum`, a cap per minute |
| F1 | Disturbing other applications | Adopt instead of re-asserting, which avoids suspending followers |
| F1 | Silence where users heard something | Make it loud, keep the escape hatch |
| F1 | Larger buffer allocations | 32 kB a port at the default limit; check at the maximum channel count |
| F2 | A probe that assumes powers of two | Keep powers of two as the default; re-run `asio_probe`, `asio_loopback`, VBASIOTest32 |
| F3 | A runaway thread at FIFO, RT throttling, other prefixes | Opt-in gate, ceiling below the driver loop, require rtprio, check `ps -eLo cls,rtprio` and the kernel log |
| F4 | Regressing high-core machines | A/B on both a high-core desktop and a four-core machine |
| F5 | `RLIMIT_RTTIME` killing the process | Order after F4, generous budget, verify with plugins open |
| F8 | Picking the wrong shared device | Change the preference order and the reporting first, decide the seeded input count separately |

## Verification

Test on three environments, because ours is the least representative:

| Environment | rtprio | Realtime path | `/dev/ntsync` |
|---|---|---|---|
| CachyOS, build machine | 99 | direct | yes |
| Fedora Workstation, stock | 0 | rtkit | kernel dependent |
| Ubuntu LTS, stock | 0 | rtkit | often absent |

Extend the vendored `tests/asio_loopback` runner, which already asserts
bit-exactness, dropped and duplicated buffers, and measured latency against
`GetLatencies`:

- a pinned graph at 192, 384, and 1024, plus a second client holding
  `node.force-quantum`, asserting convergence, bit-exactness, and wall-clock
  duration matching the sample count
- a mid-run pin change, asserting renegotiation or silence
- a device disappearing, standing in for suspend and resume
- `SIZES` extended with 192 once F2 lands

Run it in the release gate beside the build-audit fingerprint checks, where
it catches the #49 fault before a release ships. Scratch builds carry no
PipeASIO, so driver work needs a container build or the upstream runner
against an installed tree.

## Open questions

| id | Question | How to answer |
|---|---|---|
| G1 | Does Live service `kAsioResetRequest` while running? | Log the return of `sendNotification(3, 0, 0, 0)` and record whether `DisposeBuffers` and `CreateBuffers` re-enter, by editing `config.ini` while Live plays |
| G2 | Does Live raise its audio worker threads' priorities? | Trace the wineserver priority path, or compare `ps -eLo pid,tid,cls,rtprio,ni,comm` with and without the nice drop-in |
| G3 | What pins yioannides's graph to 192? | `pw-metadata -n settings` for a global pin, and `pw-dump` node properties for a per-node pin, before and after launching Bitwig and across a suspend |
| G4 | Does Rob-goblin's kernel provide `/dev/ntsync`? | `ls -l /dev/ntsync` and `uname -r` |

G1 needs the instrumented test because Live answers 1 to every
`kAsioSelectorSupported` query from 1 to 15, including selectors the SDK
leaves undefined. The driver's existing capability check therefore proves
nothing, and only the observed call sequence answers the question.

G4 gives the most information per question and nobody has asked it.

## Reply to #49

Tell yioannides that `PIPEASIO_PREFERRED_BUFFERSIZE=192` becomes 1024,
because the driver rejects sizes that are not powers of two, and that this
explains playback going from mildly wrong to five times fast. Give him
`PIPEASIO_FOLLOW_DEVICE_CLOCK=on` as the interim workaround and the G3
commands. Withdraw the earlier advice about `clock.min-quantum` and
`clock.max-quantum`.

Ask Rob-goblin for `ls -l /dev/ntsync` and `uname -r`.

State plainly that Live creates non-power-of-two buffers when a driver offers
them, and that this driver never offered.

## Status addendum, 2026-08-02 (moonshot P3)

This note moved onto the working branch from `fixes/audio-hardening`, where
it was written 2026-07-26. State of the plan as of this addendum:

- F0 landed: the launcher writes a rotated session log
  (`~/.local/state/ableton-wine/session.log`) and keeps PipeASIO warnings
  visible (`WINEDEBUG=-all,warn+asio,err+asio`); `scripts/audio-report.sh`
  collects the snapshot; the launcher warns at startup about a global
  quantum pin; pipeasio patch 0003 corrects the mismatch warning text (the
  clamp explanation and the min/max-quantum advice were wrong, per this note).
  C10 is closed.
- F6 is closed: moonshot P1 documented ntsync (README, TROUBLESHOOTING,
  launcher warning, setup-realtime drop-in), and the wrong-speed symptom
  section landed in TROUBLESHOOTING with F0.
- F4 as written is rejected by measurement:
  [FINDINGS-RT-AB-2026-08-02.md](FINDINGS-RT-AB-2026-08-02.md) recorded 242
  xruns idle and 228 playing with `ABLETON_RT=off` on a four-CPU cpuset,
  against zero with the RR default. F4 becomes: retire whole-process RR
  only when F3's per-thread realtime beats those rows (moonshot P4).
- Next per the Order section: F2 (pipeasio patch 0004), then F1 (patch
  0005), then F8. G1 through G4 stay open.
