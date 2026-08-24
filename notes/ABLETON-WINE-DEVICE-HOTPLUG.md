# Reliable MIDI and audio hotplug

This candidate restores MIDI and audio devices while Ableton Live stays open.
Recovery begins when Linux publishes a usable device.

## What changes

Wine keeps its MIDI list current for the full Live session. A new controller
can appear after Live starts. An open MIDI connection returns to the same
controller after reconnection.

PipeASIO remembers the selected audio interface and channel routes. Audio stays
silent while that interface is away. The existing Live session resumes when
the same interface returns.

Wine retries when the Linux MIDI service returns. PipeASIO rebuilds its audio
connection after PipeWire restarts. Live and wineserver stay open throughout.

## Safety rules

Device matching uses serial numbers, hardware paths and channel details where
Linux provides them. Displayed names act as a final fallback.

A connection returns after the device details identify one device. This rule
protects performers with two identical controllers or interfaces.

Wine ends held notes and sustain when a MIDI input leaves. It also ends long
messages in progress. PipeASIO sends silence while an audio interface is away.

The selected audio interface keeps priority. Automatic routing follows the
PipeWire default after the musician selects automatic routing.

## Test coverage

The automated MIDI probe covers:

- devices added after the first Windows MIDI scan
- input, output, combined and multi-port controllers
- duplicate port names
- removal and return under a changed Linux device number
- open input and output connections across repeated reconnects
- Windows device-change messages

The PipeASIO tests cover stable identity, duplicate channel names, delayed
PipeWire startup and PipeWire restart. Existing audio, buffer, clock and
two-device tests remain part of the build gate.

Release approval also requires 100 USB reconnect cycles, a full performance
session and a supported Ableton Live build. These tests confirm Live's own
device-list refresh and real hardware timing.

## Recovery targets

The candidate uses these targets:

- a published device appears in the runtime within 2 seconds
- a selected returning device becomes usable within 5 seconds
- each physical port appears once
- open connections return after a clear device match
- each audio direction resumes after its full channel set returns

## Related work

The work links to these records:

- the [Wine MIDI patch 0105](../patches/0105-winealsa-make-MIDI-topology-dynamic-and-recover-hotplug.patch) keeps the Windows MIDI list current.
- the [PipeASIO patch 0012](../patches/pipeasio/0012-recover-selected-routes-after-hotplug.patch) restores selected audio connections.
- the [MIDI issue 46](https://github.com/shibco/ableton-linux/issues/46) tracks devices connected after Live starts.
- the [performance plan PR 118](https://github.com/shibco/ableton-linux/pull/118) records the original work plan.
- the [audio hardening PR 121](https://github.com/shibco/ableton-linux/pull/121) supplies earlier clock and buffer fixes.
- the [MIDI identity PR 152](https://github.com/shibco/ableton-linux/pull/152) supplies related device identity work.
- the [PipeASIO 1.5 PR 170](https://github.com/shibco/ableton-linux/pull/170) supplies the current audio base.
- the [PipeASIO issue 29](https://github.com/shibco/ableton-linux/issues/29) records earlier launch and performance work.

The candidate branch is `fix/reliable-device-hotplug-candidate`. It starts from
release commit `ee464eb`.

## Reliability fixes, 2026-08-24

A review of the merged candidate found four correctness faults and one test
fault: a topology monitor that leaked into other Wine processes, a busy
reconnection read as success, a reconnect window that expired too early, an
audio route that could pick the wrong interface, and a rapid-replug test that
never removed its controller. All five are now fixed and covered. Wine also
asks ALSA for a larger monitor input pool as related hardening.

The topology monitor leaked into other Wine processes. Wine creates one hidden
ALSA client to watch the sequencer. That client's port had no `NO_EXPORT`
capability, so a second Wine process enumerated it as a real MIDI output named
`WINE MIDI topology`. A plugin host or Live helper starting beside Live could
therefore add a phantom endpoint and shift every device number. The monitor
port now carries `SND_SEQ_PORT_CAP_NO_EXPORT`. A two-process check in
`tools/test-midi-hotplug.sh` starts one Wine process, then a second, and fails
if either lists the monitor.

A busy reconnection read as success. Linux returns `-EBUSY` from
`snd_seq_connect_*` both when Wine's own subscription already exists and when
another client's exclusive lock blocks it. The old code treated either case as
connected, so a device could appear while its open Live route stayed dead.
Wine now queries the exact sender-to-destination subscription and accepts
`-EBUSY` only when its own link is the one in place.

Reconnect retries expired after about two seconds. Eight attempts at 250 ms
gave up before a slow rawmidi stream, late udev permissions or device firmware
were ready. The window is now about ten seconds, past the five-second
readiness target with margin, and it rearms whenever the port reappears.

The monitor could drop an unplug signal. A composite device plugs and unplugs
as a burst of sequencer events. The default ALSA input pool is small enough
that the kernel drops the tail of the burst for a subscriber, which could
include the port-exit. The monitor now asks for a larger input pool.

PipeASIO could route to the wrong physical interface. When a selected device
had no serial number, a candidate that matched only on its displayed name
still ranked as usable, even when its known bus path differed. A performer
running two identical serial-less interfaces could therefore get audio on the
sibling. The route ranking now treats a different known bus path, bus id or
ALSA path as a conflict and refuses the candidate, so a serial-less device
that moves must be selected again. See
[PipeASIO patch 0012](../patches/pipeasio/0012-recover-selected-routes-after-hotplug.patch)
and its `test_hotplug` unit test.

The rapid-replug test never removed its controller. `midiwatch.exe` writes
CRLF lines. `run_cycle_case` waited on `$`-anchored patterns, and the system
`grep` here (ugrep) does not match `$` across a trailing carriage return. The
wait timed out, the virtual controller was never unplugged, and the cycle
reported a removal failure that the driver had not caused. `wait_for_text`
now strips the carriage return before matching, so the removal and return path
runs for the first time.
