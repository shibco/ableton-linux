# Push 3 USB bridge

[Patch 0073](../patches/0073-libusb-1.0-extend-the-host-bridge-for-Push-3.patch)
extends the [patch 0032](../patches/0032-libusb-1.0-add-host-USB-bridge-for-Push-2.patch)
libusb bridge so `Push3.exe` can reach Push 3's vendor USB interfaces through
host libusb. The extension follows the same design as the Push 2 bridge,
described in [ABLETON-WINE-PUSH2-DISPLAY.md](ABLETON-WINE-PUSH2-DISPLAY.md).

Status: Live starts `Push3.exe`. The helper connects to its MIDI ports, opens
the display through the host bridge, and reports "Push is go". The surface then
works on the hardware. This needs
[patch 0074](../patches/0074-winealsa-report-a-device-interface-and-Windows-names.patch)
together with patch 0073. Patch 0074 gives each MIDI port a device interface
path and the Windows port names.

The first run also installed a firmware update in the device. The Push then
needed a power cycle before the handshake was complete.

We verified this one time, on one unit, on 2026-08-05. Refer to Detection,
Push3.exe MIDI port names, and Verification. We did not test how the surface
plays.

## Device

Push 3 is one composite USB device:

```text
2982:1969
interface 0: display, bulk OUT 0x01 and IN 0x81, 512 bytes
interfaces 1 to 4: USB audio (16 channels, internal and ADAT clock)
interface 5: MIDI, three ports (Live, User, External)
interface 6: "xPort", vendor specific, bulk OUT 0x04 and IN 0x84, 512 bytes
```

Linux exposes the audio and MIDI interfaces through `snd-usb-audio`, and
Wine shows the three MIDI ports to Live. The display interface matches
the Push 2 layout. Interface 6 has no Push 2 equivalent and its protocol
is unknown.

## Cause

`Push3.exe` links against the same vendor libusb 1.0.23 DLL that ships with
the Push 2 display helper, but imports four functions the patch 0032 bridge
does not export: `libusb_bulk_transfer`, `libusb_strerror`,
`libusb_hotplug_register_callback`, and `libusb_hotplug_deregister_callback`.
The 0032 bridge also rejects claims on any interface other than 0, which
blocks the xPort interface.

## Detection

Live does not search the USB bus for a Push 3. Live reads the Windows device
interface path of each winmm MIDI device, and it looks for USB ids in that path.
The ALSA MIDI driver in Wine gave no path.

Live 12.4.3 calls `midiInMessage` and `midiOutMessage` for each MIDI in device
and each MIDI out device. It sends the message `DRV_QUERYDEVICEINTERFACE`
(0x080c) with a buffer of 1024 bytes, and it writes a terminator in the buffer
first. Live then looks in the result for `vid_2982&pid_1967` (Push 2) or
`vid_2982&pid_1969` (Push 3). Both texts are in the MidiDeviceManager block of
the binary, together with `Ableton Push `, `MIDIIN2`, `MIDIOUT2`, `Port 2`,
`Port 3`, and `External`. Two small functions hold the message number and the
buffer size. In the 12.4.3 build, they are at 0x1437182b0 for out and at
0x1437182e0 for in. A third position in the code uses the same pair of values.

`winmm` sends the message to the MIDI driver in `MMDRV_PhysicalFeatures`
(`dlls/winmm/lolvldrv.c`). `dlls/winealsa.drv/alsamidi.c` had no branch for the
message in `alsa_midi_out_message` or in `alsa_midi_in_message`. The default
branch wrote `Unsupported message` and returned `MMSYSERR_NOTSUPPORTED`. The
wave devices answer the message in `dlls/winmm/waveform.c`, but the MIDI devices
did not. Live read an empty text for each device, and no device agreed with the
two texts. Live did not use its `push-app-launching` code, and `Push3.exe` did
not start. This is the trace with `WINEDEBUG=+winmm,+midi` before patch 0074. It
repeats for all six out devices and all six in devices:

```text
trace:winmm:midiOutMessage (0000000000000000, 080C, 0010D028, 00000400)
trace:winmm:MMDRV_PhysicalFeatures (00000000060C15B0, 080c, 0010d028, 00000400)
trace:winmm:MMDRV_Message (MidiOut 0 2060 0x00000000 0x0010d028 0x00000400)
trace:midi:alsa_midi_out_message Unsupported message
trace:winmm:MMDRV_Message => MMSYSERR_NOTSUPPORTED
```

`midiInMessage` did not send the message to the driver at all. It returned
`MMSYSERR_INVALHANDLE` for a device ID, but `midiOutMessage` calls
`MMDRV_PhysicalFeatures` in this condition. Patch 0074 corrects both parts. It
adds the same fallback in `winmm`, and it answers the message in
`winealsa.drv`. The driver makes the path from the USB device that is behind the
sound card of the port:

```text
trace:midi:set_interface_name 32:0 interface
  '\\?\usb#vid_2982&pid_1969&mi_05#alsa&card4&port0#{6994ad04-93ef-11d0-a3cc-00a0c9223196}'
```

`&mi_05` is the USB audio class MIDI streaming interface of the device. The
driver finds this interface when it reads the interfaces of the USB device and
selects class 0x01 with subclass 0x03. The field `alsa&card<n>&port<n>` replaces
the Windows instance id, because Linux has no equal value. A port that has no
USB card behind it gets no path and keeps `MMSYSERR_NOTSUPPORTED`.

The libusb override for Live has no effect on detection. With the override, Live
loads the builtin bridge (`loaddll: ... libusb-1.0.dll ...: builtin`), and then
Live does not call it. Two complete sessions on 2026-08-05 with `+libusb` gave
no `trace:libusb` line. Live imports libusb, but libusb is not the detection
path:

```text
Live 12.4.3:   libusb_init, libusb_exit, libusb_get_device_list,
               libusb_get_device_descriptor, libusb_free_device_list,
               libusb_open, libusb_close, libusb_claim_interface,
               libusb_release_interface, libusb_bulk_transfer,
               libusb_strerror
Live 12.4.5b7: the same list without libusb_bulk_transfer
```

`setup-prefix.sh` keeps the override for the Live 12 executables, so the libusb
calls go to the bridge if Live makes them. Each import in the list is a bridge
export: nine come from patch 0032, and `libusb_bulk_transfer` and
`libusb_strerror` come from patch 0073. Do not set the Live override on a
runtime without patch 0073. The loader cannot find `libusb_bulk_transfer` and
`libusb_strerror` in the 0032 bridge, and Live does not start. No released
runtime contains patch 0073.

## Push3.exe MIDI port names

Before patch 0074, `Push3.exe` stopped before its USB work. This occurred on
2026-08-02, and again on 2026-08-05 at 19:16 with the same prefix:

```text
error { "message": "Couldn't find MIDI in port" }
info  { "message": "Candidates were:" }
info  { "message": "Ableton Push 3 Live Port 3" }
error { "message": "Can't create MIDI IO: No Push hardware found" }
info  { "message": "Push 3 - terminated with -1" }
```

`Push3.exe` reads the MIDI devices with the WinMM backend of RtMidi. The binary
contains `RtMidi Input Client` and `RtMidi Output Client`. Its only winmm device
imports are `midiInGetDevCapsA` and `midiOutGetDevCapsA`, and these functions
give names. The binary has no `midiInMessage` and no USB id text. The RtMidi
function `MidiInWinMM::getPortName` adds " <index>" to each name. That index is
the number at the end of each candidate in the log above. The binary has one
pattern for each Push generation, and the pattern must match the complete name:

```text
Ableton Push 2 (\d*|Live Port(\s\d+)?|[0-9][0-9]:0)
Ableton Push 3 (\d*|Live Port|MIDI [0-9]+|MIDI Live Port(\s\d+)?|[0-9][0-9]:0)
```

The Push 2 pattern accepts the index after `Live Port`, but the Push 3 pattern
does not accept it. Wine used the ALSA name "Ableton Push 3 Live Port", so
RtMidi gave "Ableton Push 3 Live Port 3", and the pattern did not match. On
Windows, the first port has the name "Ableton Push 3". RtMidi then gives
"Ableton Push 3 <index>", and the `\d*` part of the pattern matches. For this
reason, the fault occurs only on Wine.

Patch 0074 gives a port on a USB card the Windows name and the interface path.
The first seq port of the device gets the device name. The other ports get the
names `MIDIIN<n> (device)` and `MIDIOUT<n> (device)`, and n comes from the seq
port number. RtMidi then gives "Ableton Push 3 <index>", and the pattern
matches.

This changes the name of each USB MIDI port in the prefix, and not only a Push
port. A name in the form "Ableton Push 2 - Ableton Push 2 MIDI 1" becomes the
Windows name. Live keeps the old names in `Preferences.cfg`. Set the MIDI input
switch and the MIDI output switch for your USB devices again after the first
start with the new runtime. A port that is not on a USB card keeps the name
"client - port". A PipeWire port, a Midi Through port, and a virmidi port are
examples of such a port.

## Bridge changes

Patch 0073 changes the builtin `libusb-1.0.dll`:

- exports `libusb_bulk_transfer` and forwards it to the host as one blocking
  call on the calling thread
- exports `libusb_strerror` with the standard libusb message strings
- exports the two hotplug functions as stubs; registration returns
  `LIBUSB_ERROR_NOT_SUPPORTED`. The vendor's Windows libusb build reports no
  hotplug support either, so the helper already handles this result and polls
  the device list instead
- accepts claim and release for interface numbers 0 through 255 in both the
  PE and Unix layers, instead of interface 0 only

Per-application overrides select the builtin for the helper and for Live.
`setup-prefix.sh` sets:

```text
HKCU\Software\Wine\AppDefaults\Push3.exe\DllOverrides
    libusb-1.0 = builtin
HKCU\Software\Wine\AppDefaults\<Live 12 executable>\DllOverrides
    libusb-1.0 = builtin
```

The Live keys cover the Suite, Standard, Intro, Lite, Trial, and Beta
executables.

## MIDI driver changes

Patch 0074 changes `dlls/winealsa.drv/alsamidi.c` and `dlls/winmm/winmm.c`:

- The driver answers `DRV_QUERYDEVICEINTERFACE` and
  `DRV_QUERYDEVICEINTERFACESIZE` for MIDI in devices and MIDI out devices. The
  byte counts are the same as for the wave devices in winmm. The size includes
  the terminator. A buffer that is too small gives `MMSYSERR_INVALPARAM`.
- The driver makes the interface path of a port one time, at enumeration and
  after a hotplug re-attach. It uses the USB device that is behind the sound
  card of the port. It reads `/sys/class/sound/card<n>/device` and goes up in
  the tree to the directory that has `idVendor` and `idProduct`.
- The driver gives a port on a USB card the name that the Windows USB MIDI class
  driver gives. It does this in `port_add` and in the hotplug code from patch
  0028, so a replug finds the port again by name.
- `midiInMessage` accepts a device ID for the physical-feature messages.
  `midiOutMessage` accepted a device ID before this patch.

## Verification

[`tools/push3usb.c`](../tools/push3usb.c) is the host-side probe, adapted from
`push2usb.c`. It validates the descriptor layout of interfaces 0 and 6, claims
and releases both, and runs a submit-and-cancel test on a bulk IN endpoint.
The xPort transfer test runs only with `--cancel-in-xport`.

A contributor ran the probe on Push 3 hardware on 2026-08-02:

- enumeration, repeated claims, and releases succeeded on interfaces 0 and 6
- the display cancel test returned `count=1 status=cancelled actual_length=0`
- all three MIDI ports remained in the ALSA sequencer graph afterwards

The xPort cancel test returned `status=cancelled` with `actual_length=512`:
the device delivered a full packet before the cancel completed. The xPort IN
endpoint always has data queued for the host. This is a property of the
device, not a fault. Expect `Push3.exe` to consume this stream continuously;
if the bridge's event handling stalls anywhere, this endpoint will show it
first.

The runtime with patches 0073 and 0074 gave a complete session on 2026-08-05.
The setup was Live 12.4.3, a Push 3 controller, engineering run ER3b, and no
compute module:

- Live started `Push3.exe --parent-process-id=<pid> --log-level=info
  --dont-log-to-console --language=EN` without help.
- The helper wrote "Found Push USB device (rev B)" and "Push display USB device
  opened". It read the system info and each component firmware version through
  the bridge. It loaded its Python script and wrote "Push is go".
- Live then showed `FromPush` and `ToPush` in its MIDI device list, and
  connected `MidiRemoteScript 7` to `FromPush`. The first hardware port was no
  longer in the list, because the helper holds that port. Windows does the same.
  The two other ports are `MIDIIN2/MIDIOUT2 (Ableton Push 3)` and
  `MIDIIN3/MIDIOUT3`.
- The surface came up on the hardware. We did not test how it plays.

Two effects can occur on a first run. First, the helper compares the device
firmware with `hardware-updates.ableton.com`. On this unit it installed build 91
in place of build 85. The helper then started again every five seconds until the
device was switched off and on. After that power cycle, the handshake was
complete at the first try. Second, the message `MidiHub: Failed to push MIDI
message to outgoing queue` occurs three times in each session, in the group of
messages near "Received song" and "Push hardware identified". It has no visible
effect after the helper is ready. We did not examine these two effects.

## Rollback

Close Live and `Push3.exe`, then remove the overrides with this
project's Wine:

```bash
WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" reg delete \
  'HKCU\Software\Wine\AppDefaults\Push3.exe\DllOverrides' \
  /v libusb-1.0 /f
WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" reg delete \
  'HKCU\Software\Wine\AppDefaults\Ableton Live 12 Suite.exe\DllOverrides' \
  /v libusb-1.0 /f
```

Repeat the second command for each installed Live 12 edition. Do not
leave the overrides enabled when using a Wine runtime without patch
0073.

## Limits

- All patch 0032 limits apply: PE32+ x86-64 only, bulk transfers only,
  `flags == 0`, no isochronous packets, no hotplug delivery.
- `libusb_bulk_transfer` blocks the calling thread for up to the caller's
  timeout, matching libusb's documented behaviour.
- The interface guard accepts 0 through 255; the helper's own device and
  interface selection remains the only filter.
- Push 3's audio and MIDI interfaces stay with `snd-usb-audio` and are not
  bridged.
- The xPort protocol is undocumented. The bridge moves its bytes and nothing
  more.
- Live 11 executables are not covered: their libusb imports are unverified.
- Move is a different device and is not covered.
- The interface path from patch 0074 is not a Windows path. Only the vendor id,
  the product id, and the MIDI interface number are real. The instance field is
  `alsa&card<n>&port<n>`, and it changes if the card number changes.
- Only a port on a USB sound card gets a path and the Windows names. A PCI card
  or a virtual client keeps its name and gets no path.
- The Windows port index is the seq port number. For a USB MIDI card, this
  number starts at 0 for each device. If the seq ports of a device start above
  0, no port gets the short device name. All ports then get a `MIDIIN<n>` name
  or a `MIDIOUT<n>` name.
- Wine holds the MIDI device data for each process. Live and `Push3.exe` can
  both open the same port. On Windows, the second open fails with
  `MMSYSERR_ALLOCATED`. Nothing that we saw depends on this difference.
