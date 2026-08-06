# Push 2 display bridge

[Patch 0032](../patches/0032-libusb-1.0-add-host-USB-bridge-for-Push-2.patch)
lets `Push2DisplayProcess.exe` use Push 2's display interface through host
libusb. The bridge is limited to this 64-bit helper and is not a general Wine
libusb implementation.

## Live setup

Use exactly one control-surface row:

- **Control Surface:** `Push2`
- **Input:** `Ableton Push 2`
- **Output:** `Ableton Push 2`

[Patch 0074](../patches/0074-winealsa-report-a-device-interface-and-Windows-names.patch)
gives USB MIDI ports the names that Windows uses. The Live port is
`Ableton Push 2`. The User port is `MIDIIN2 (Ableton Push 2)` and
`MIDIOUT2 (Ableton Push 2)`. Before patch 0074, the names were
`Ableton Push 2 Live Port` and `Ableton Push 2 User Port`. Set a row that uses
an old name again. We did not test these names on Push 2 hardware.

The User Port may remain a normal MIDI device. Do not configure it as another
`Push2` row. Two rows launch two display helpers, and only one can claim USB
interface 0.

After a stale claim, save one row, close Live normally, and start it again.

## Cause

Push 2 is one composite USB device:

```text
2982:1967
interface 0: display, bulk OUT 0x01 and IN 0x81
interfaces 1 and 2: USB audio control and MIDI streaming
```

Linux and ALSA expose the MIDI interfaces, so Live identifies the controller.
The display helper uses Ableton's Windows libusb 1.0.23 backend, which expects
WinUSB functions that Wine 11.11 does not provide for this path. The helper
therefore found the USB device but could not open interface 0.

[`tools/push2usb.c`](../tools/push2usb.c) confirmed that host libusb could
enumerate, claim, release, and cancel an asynchronous transfer on interface 0
while `snd-usb-audio` retained interfaces 1 and 2.

## Bridge design

Patch 0032 adds a Wine builtin `libusb-1.0.dll`:

```text
Push2DisplayProcess.exe
  -> 16-function Win64 libusb 1.0.23 ABI
  -> Wine PE builtin
  -> fixed-width Wine Unix calls
  -> host libusb-1.0.so.0
  -> USB interface 0
```

`setup-prefix.sh` selects the builtin only for the display helper:

```text
HKCU\Software\Wine\AppDefaults\Push2DisplayProcess.exe\DllOverrides
    libusb-1.0 = builtin
```

`setup-prefix.sh` also selects the builtin for the Live 12 executables
([ABLETON-WINE-PUSH3-USB.md](ABLETON-WINE-PUSH3-USB.md)). No Ableton file
is replaced.

The bridge:

- builds only an x86-64 PE and Unix pair
- exports the 16 names and ordinals used by the helper
- checks the observed descriptor and transfer layouts at compile time
- converts the Win64 event timeout to the host `timeval` layout
- copies status and transferred length before calling the Windows callback
- permits resubmission from that callback
- drains cancellation through `libusb_handle_events_timeout`
- uses internal `wrap_*` Unix symbols to avoid binding back to itself

## Verification

[`tools/push2usb-pe.c`](../tools/push2usb-pe.c) resolves the exports, checks
their ordinals, and tests enumeration, repeated claims, and cancellation. It
does not send an OUT transfer.

Expected output includes:

```text
push2-abi=ok exports=16 name-ordinal-pairs=16
push2-enumeration=ok 2982:1967
push2-claim=ok repetitions=2
push2-cancel=ok callbacks=1 status=cancelled actual_length=0
```

In the recorded Live test, the helper loaded the builtin, opened the display
on its first attempt, streamed, and exited cleanly. Live loaded its vendor DLL.
One helper ran with no `LIBUSB_ERROR_BUSY`, and ALSA MIDI bindings did not
change.

The original hardware test used WineASIO. Current Podman builds gate the bridge,
PipeASIO, and `winealsa.so` separately. A clean Wine build once omitted its
external audio driver, so the build now checks those files before packaging.
It also fails if Wine configure omits `winealsa.so`.

## Diagnosis

- `Shutting down because live didn't ack in time` is normal when the helper
  runs without Live. It opens the display, retries for about eight seconds,
  and exits with status 0.
- A second helper should receive `LIBUSB_ERROR_BUSY` while the first owns
  interface 0.
- If PipeWire rejects clients during Live startup, Wine can omit MIDI for that
  process. Audio may recover while Live's MIDI list remains empty. Restart Live
  after the audio stack recovers.
- `amidi -l` checks raw MIDI. Wine reads the ALSA sequencer graph, so use
  `aconnect -l` for MIDI and `pactl info` for audio readiness.
- An idle Wine prefix may keep `/dev/bus/usb` file descriptors open.
  `wineusb.sys` does not claim an interface or detach its kernel driver in this
  path, so the open descriptor alone does not block the bridge.
- `loadAsioDriver failed` with empty MIDI can indicate a corrupt Live audio
  preferences block, a missing `winealsa.so`, or a transient PipeWire outage.
  Check all three before changing the prefix.

## Rollback

Close Live and `Push2DisplayProcess.exe`, then remove the helper override with
this project's Wine:

```bash
WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" reg delete \
  'HKCU\Software\Wine\AppDefaults\Push2DisplayProcess.exe\DllOverrides' \
  /v libusb-1.0 /f
```

Do not leave the override enabled when using a Wine runtime without patch
0032.

## Limits

- The bridge supports PE32+ x86-64, USB interface 0, and bulk transfers only.
  It requires `flags == 0` and no isochronous packets.
- It relies on the per-application override and the helper's own device and
  interface selection. The bridge does not filter VID, PID, or endpoints.
- `libusb_set_option` accepts only `LIBUSB_OPTION_LOG_LEVEL`.
- `libusb_free_device_list(list, 1)` is supported. Retaining proxy devices
  with `(list, 0)` is not.
- Outstanding transfers must be cancelled and drained before free or exit.
- Callback dispatch failure is logged but cannot be returned to the PE event
  loop.
- Disconnect and `NO_DEVICE` recovery inside the bridge remain untested.
- `Push3.exe` uses a different libusb surface and is outside this patch.
  [Patch 0073](../patches/0073-libusb-1.0-extend-the-host-bridge-for-Push-3.patch)
  extends the bridge for it; see
  [ABLETON-WINE-PUSH3-USB.md](ABLETON-WINE-PUSH3-USB.md).
- A Live process that started without MIDI ports does not discover them later.
- Raw traces can contain the controller serial number. Do not publish them.

Full physical-panel acceptance with the current PipeASIO release, a rollback
exercise, and hotplug recovery still need recorded tests.
