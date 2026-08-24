# MIDI and audio device reconnection

Pull request 245 added device reconnection on 23 August 2026. Wine refreshes
MIDI devices while Ableton Live stays open. PipeASIO restores selected audio
routes after an interface returns.

## Runtime behaviour

Wine keeps its MIDI list current for each Live session. A controller can appear
after Live starts. An open MIDI connection returns after Wine identifies the
same controller.

PipeASIO remembers the selected audio interface and channel routes. PipeASIO
sends silence while the interface is away. The existing Live session resumes
when the same interface returns.

Wine retries after the ALSA sequencer becomes available again. PipeASIO rebuilds
its connection after PipeWire restarts. Live and wineserver remain open.

## Device matching rules

Wine and PipeASIO compare serial numbers, physical bus paths, and channel
details. They use displayed names as the final match field.

Each connection returns after the device details identify one device. A route
waits in silence when the details identify several devices.

Wine ends held notes, sustain, and long messages when a MIDI input leaves.
PipeASIO sends silence while an audio interface is away.

The selected audio interface keeps priority. Automatic routing follows the
PipeWire default after you select automatic routing.

## Automated checks

The automated MIDI probe checks these cases:

- a device appears after the first Windows MIDI scan.
- single-direction, duplex, and multi-port controllers publish each port.
- duplicate port names keep separate device records.
- an exclusive test link reserves both MIDI directions for 3 seconds during reconnection.
- a repeated cycle removes and restores open connections under a changed ALSA client ID.
- 2 Wine processes keep their internal monitor ports private.
- each published device list sends a Windows device change message.

The PipeASIO checks cover device identity, duplicate channel names, delayed
PipeWire startup, and PipeWire restart. The build gate also checks audio
buffers, clocks, and 2-device sessions.

## Release checks

Release approval requires these checks:

- the tester completes 100 USB reconnection cycles.
- the tester completes a full performance session.
- the tester uses a supported Ableton Live build.
- the tester confirms Live's device list refresh and real hardware timing.

The implementation uses these time targets:

- a published device appears in the runtime within 2 seconds.
- a selected returning device becomes usable within 5 seconds.
- each physical port appears once.
- an open connection returns after one device matches.
- each audio direction resumes after its full channel set returns.

## Fixes from 24 August 2026

The review corrected the MIDI monitor, MIDI links, retry period, audio matching,
and shell probe. The review also increased the ALSA monitor input pool.

### Private MIDI monitor ports

Wine creates one ALSA monitor port in each process. The port now uses ALSA's
private-port capability. Wine excludes private ports from Windows MIDI lists.
The 2-process MIDI case inspects both lists.

### Busy MIDI links

ALSA uses one busy result for 2 states. Wine can own the exact subscription.
Another client can reserve the port exclusively. Wine now queries the exact
subscription after a busy result. Wine reports a connection after the query
finds its subscription.

### MIDI retry period

Wine makes up to 40 retries at 250 ms intervals. The period lasts about 10
seconds and extends beyond the 5-second device target. The period gives raw
MIDI streams, udev permissions, and device firmware time to become ready.

### MIDI event pool

A multi-port device publishes several ALSA events together. Wine requests an
input pool of 1,000 events. Wine reports rejected pool requests in its debug
log. The larger pool gives the monitor room for the complete event group.

### PipeASIO location fields

PipeASIO first checks known vendor and product IDs. It then compares a serial
number. For serial-less devices, it compares the physical bus path, bus ID, and
ALSA path in that order.

PipeASIO compares the first location field that both records provide. A matching
physical path identifies the saved device when ALSA assigns another card path.
A different physical path leaves the route silent until you select a device.

### Windows line endings

The Windows probe writes CRLF. The shell helper removes carriage returns before
it checks a line-end anchor. The conversion lets the rapid cycle reach device
removal and reconnection.

## Source records

The implementation links to these records:

- the [device reconnection pull request 245](https://github.com/shibco/ableton-linux/pull/245)
  merged the original candidate.
- the [Wine MIDI patch 0105](../patches/0105-winealsa-make-MIDI-topology-dynamic-and-recover-hotplug.patch)
  keeps the Windows MIDI list current.
- the [PipeASIO patch 0012](../patches/pipeasio/0012-recover-selected-routes-after-hotplug.patch)
  restores selected audio routes.
- the [MIDI issue 46](https://github.com/shibco/ableton-linux/issues/46)
  tracks devices that appear after Live starts.
- the [performance plan pull request 118](https://github.com/shibco/ableton-linux/pull/118)
  records the original work plan.
- the [audio fixes pull request 121](https://github.com/shibco/ableton-linux/pull/121)
  supplies earlier clock and buffer fixes.
- the [MIDI identity pull request 152](https://github.com/shibco/ableton-linux/pull/152)
  supplies related device identity work.
- the [PipeASIO 1.5 pull request 170](https://github.com/shibco/ableton-linux/pull/170)
  supplies the audio base.
- the [PipeASIO issue 29](https://github.com/shibco/ableton-linux/issues/29)
  records earlier launch and performance work.

The original candidate branch was `fix/reliable-device-hotplug-candidate`. It
began at release commit `ee464eb` and merged on 23 August 2026.
