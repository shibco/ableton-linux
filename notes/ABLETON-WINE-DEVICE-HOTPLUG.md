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

- the [Wine MIDI patch 0100](../patches/0100-winealsa-make-MIDI-topology-dynamic-and-recover-hotplug.patch) keeps the Windows MIDI list current.
- the [PipeASIO patch 0012](../patches/pipeasio/0012-recover-selected-routes-after-hotplug.patch) restores selected audio connections.
- the [MIDI issue 46](https://github.com/shibco/ableton-linux/issues/46) tracks devices connected after Live starts.
- the [performance plan PR 118](https://github.com/shibco/ableton-linux/pull/118) records the original work plan.
- the [audio hardening PR 121](https://github.com/shibco/ableton-linux/pull/121) supplies earlier clock and buffer fixes.
- the [MIDI identity PR 152](https://github.com/shibco/ableton-linux/pull/152) supplies related device identity work.
- the [PipeASIO 1.5 PR 170](https://github.com/shibco/ableton-linux/pull/170) supplies the current audio base.
- the [PipeASIO issue 29](https://github.com/shibco/ableton-linux/issues/29) records earlier launch and performance work.

The candidate branch is `fix/reliable-device-hotplug-candidate`. It starts from
release commit `ee464eb`.
