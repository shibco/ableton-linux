# Reliable MIDI and audio hotplug

The project will restore MIDI and audio devices while Ableton Live stays open.
The guarantee starts when Linux publishes a usable device.

The review finished on 22 August 2026.
The branch starts from commit `ee464eb`.
The plan lives on branch `fix/reliable-device-hotplug`.
Commit `dc40518` records the detailed design.

## Agreed solution

Wine finds and reconnects MIDI devices. PipeASIO reconnects audio devices.
Each component manages its own devices and connections.

The work has 3 parts:

- the Wine layer watches the Linux MIDI service throughout the Live session.
- the Wine layer refreshes the Windows MIDI list that Live reads.
- the PipeASIO driver restores the selected audio interface and its channel links.

ALSA and PipeWire provide device details. Linux logs show each device step.
A real Live test decides whether the project also needs fixed MIDI ports that
stay visible for the full session.

## Expected musician experience

The completed work provides these results:

- a new MIDI device appears after Live starts.
- a selected MIDI device returns after reconnection.
- a selected audio interface returns after reconnection.
- Live and wineserver stay open during recovery.
- audio stays silent while an interface is away.
- held notes and sustain end when a MIDI input disappears.
- the runtime names the last service that saw the device.

## Current work

[MIDI hotplug issue 46](https://github.com/shibco/ableton-linux/issues/46) tracks MIDI
devices connected after Live starts.

[MIDI reconnect patch 0028](../patches/0028-winealsa-re-subscribe-MIDI-devices-when-they-reappea.patch)
restores a MIDI device that Wine found during its first scan. Its device
watcher starts when Live opens a MIDI input.

The 2 August prototype expanded Wine's MIDI list during a session. A software
test changed the Windows MIDI count from 3 to 4 in about 450 milliseconds.
Release tests will cover Live and USB hardware.

[The prototype archive](hotplug-prototypes/README.md) records that experiment.
The original worktree remains in its 2 August state.

Related GitHub work includes:

- the closed [MIDI input issue 19](https://github.com/shibco/ableton-linux/issues/19) records earlier MIDI input fixes.
- the closed [PipeASIO performance issue 29](https://github.com/shibco/ableton-linux/issues/29) records earlier audio fixes.
- the [performance plan PR 118](https://github.com/shibco/ableton-linux/pull/118) records the same MIDI and audio tasks.
- the [separate audio hardening PR 121](https://github.com/shibco/ableton-linux/pull/121) improves clocks and buffers on the performance branch.
- the open [MIDI identity PR 152](https://github.com/shibco/ableton-linux/pull/152) proposes hardware identity work.
- the [PipeASIO 1.5 PR 170](https://github.com/shibco/ableton-linux/pull/170) supplies the current audio base.
- the [audio launch PR 236](https://github.com/shibco/ableton-linux/pull/236) changes launch options and tests.

## MIDI recovery

ALSA is the Linux MIDI system that publishes MIDI ports. Wine will watch ALSA from
the first MIDI request until the Wine process ends.

The MIDI recovery sequence is:

1. Wine starts its device watcher.
2. ALSA reports a device change.
3. Wine scans the full MIDI list after the change settles.
4. Wine matches each port with the best available hardware, card and port details.
5. Wine publishes the refreshed device list.
6. Wine tells Live to read the list again.
7. An open connection returns to the same identified device.

Wine will keep a permanent record for each discovered device. The visible list will
contain the devices that ALSA currently publishes.

Wine will also clear incomplete MIDI messages, held notes and sustain during a
disconnect. The same open connection will resume after an exact device match.

Two identical devices can share the same hardware details. Wine will list both
devices. During an ambiguous return, Wine will wait for an exact match before
it restores an open connection.

## Audio recovery

PipeWire is the Linux audio system that publishes interfaces and channels.
PipeASIO will remember the selected interface and its channel layout.

The audio recovery sequence is:

1. PipeWire reports an interface or channel change.
2. PipeASIO pauses the affected audio input or output.
3. PipeASIO waits for the complete channel set.
4. PipeASIO matches the interface with the best available system name, serial number and hardware path.
5. PipeASIO rebuilds every channel link as one group.
6. PipeASIO resumes the existing Live audio session.

PipeASIO will send silence to Live during capture loss. It will discard Live's
output safely during playback loss.

PipeASIO will use the existing Live buffers when the channel, rate and buffer
values stay the same. A change will cause one Live reset after the interface
becomes ready.

A PipeWire restart will cause PipeASIO to rebuild its PipeWire connection.
PipeASIO will first try to keep Live's selected interface, channels and
buffers. A Live test will decide whether one reset follows the rebuild.

The PipeASIO settings window will refresh its device list once each second.
An explicit device choice will wait for that device. Automatic playback will
use PipeWire's current default device. Automatic capture will first use the
playback device's audio card.

## Options reviewed

ALSA provides the best MIDI event source because it covers USB and virtual
MIDI ports. Linux device events will add hardware details and logs.

PipeASIO creates its own audio connections. PipeASIO will therefore restore
them. WirePlumber will continue to manage regular desktop audio.

An external helper would choose devices and channels a second time. External
tools will record tests, device status and the last successful step.

Fixed MIDI ports can keep one list for the full Live session. The real Live
test will decide whether fixed ports are required.

## Patch scope

The planned code work stays in 3 focused patches:

1. Add continuous MIDI discovery and hardware-based matching to Wine.
2. Refresh Wine's Windows MIDI list while Live runs.
3. Add audio route recovery and PipeWire restart recovery to PipeASIO.

The first Wine patch will include the useful work from patch 0028. It will also
share device identity work with PR 152.

The repository test work uses these tools:

- the [MIDI list watcher](../tools/midiwatch.c) records Windows MIDI lists and device messages.
- the [device message probe](../tools/devpoke.c) tests Live's response to a device change alert.
- the [software MIDI controller](../tools/fakectl.c) creates repeatable test devices.
- the [MIDI reconnect probe](../tools/midihot.c) tests MIDI input and reconnect behaviour.

## Release tests

The release tests cover these cases:

- connect devices before Wine, before Live MIDI starts and after Live starts.
- test MIDI input, output, combined and multi-port devices.
- test duplicate names, hardware-path identity and changed USB ports.
- disconnect during notes, sustain, clock and long MIDI messages.
- test audio input, output, combined and separate interfaces.
- test audio channel changes and separate audio clocks.
- start and restart PipeWire and WirePlumber during a Live session.
- run 100 connect and disconnect cycles.
- run one full performance session.
- complete the final tests with real USB hardware and a supported Live build.

The release targets are:

- the runtime detects a published device within 2 seconds.
- a selected device returns within 5 seconds.
- each physical port appears once.
- each clearly identified open connection returns to the same device.
- all audio channels return together.
- all held MIDI notes end during a disconnect.
- logs identify the last service that saw the device.

## Sources

The design uses these primary sources:

- the [Linux USB hotplug guidance](https://docs.kernel.org/driver-api/usb/hotplug.html) explains device removal and return.
- the [ALSA MIDI sequencer guidance](https://www.alsa-project.org/alsa-doc/alsa-lib/seq.html) explains MIDI device events.
- the [Wine 11.16 source](https://github.com/wine-mirror/wine/commit/8da89f8493b21ebfbe344a54dbef0cde23c7ea59) shows the current MIDI list behaviour.
- the [PipeWire device list guidance](https://docs.pipewire.org/group__pw__registry.html) explains audio device events.
- the [WirePlumber audio link policy](https://pipewire.pages.freedesktop.org/wireplumber/policies/linking.html) explains desktop audio links.
- the [Windows MIDI count guidance](https://learn.microsoft.com/en-us/windows/win32/api/mmeapi/nf-mmeapi-midiingetnumdevs) defines the visible device count.
- the [Ableton Live MIDI settings guidance](https://help.ableton.com/hc/en-us/articles/209774205-Live-s-MIDI-Settings) describes automatic device detection.
