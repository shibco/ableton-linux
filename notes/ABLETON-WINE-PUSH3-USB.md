# Push 3 USB bridge

[Patch 0065](../patches/0065-libusb-1.0-extend-the-host-bridge-for-Push-3.patch)
extends the [patch 0032](../patches/0032-libusb-1.0-add-host-USB-bridge-for-Push-2.patch)
libusb bridge so `Push3.exe` can reach Push 3's vendor USB interfaces through
host libusb. The extension follows the same design as the Push 2 bridge,
described in [ABLETON-WINE-PUSH2-DISPLAY.md](ABLETON-WINE-PUSH2-DISPLAY.md).

Status: the host USB path is verified on Push 3 hardware. In the first
contributor test, Live did not detect the Push 3 and did not start
`Push3.exe`; the Detection section gives the cause and the correction.
Runtime tests of detection and of `Push3.exe` with Live have not happened
yet. Do not describe Push 3 as supported until they pass.

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

Live starts `Push3.exe` only after it finds Push 3 hardware on USB.
Push 3 has no control surface entry in Live's MIDI preferences. The
Live 12 executable imports libusb and scans USB in its own process
(import lists from `winedump -j import`):

```text
Live 12.4.3:   libusb_init, libusb_exit, libusb_get_device_list,
               libusb_get_device_descriptor, libusb_free_device_list,
               libusb_open, libusb_close, libusb_claim_interface,
               libusb_release_interface, libusb_bulk_transfer,
               libusb_strerror
Live 12.4.5b7: the same list without libusb_bulk_transfer
```

Without an override, Live loads its application-local libusb DLL, which
needs Windows USB drivers that do not exist in a Wine prefix. The scan
finds no devices and Live never starts `Push3.exe`. A contributor trace
from 2026-08-05 shows this state: all three MIDI ports visible in Live's
MIDI preferences, no `Push3.exe` process.

`setup-prefix.sh` therefore selects the builtin for the Live 12
executables. Every Live 12 libusb import is a bridge export: nine from
patch 0032, `libusb_bulk_transfer` and `libusb_strerror` from patch 0065.

Do not set the Live override on a runtime without patch 0065: the loader
cannot resolve `libusb_bulk_transfer` and `libusb_strerror` against the
0032 bridge, and Live does not start. No released runtime contains patch
0065.

## Bridge changes

Patch 0065 changes the builtin `libusb-1.0.dll`:

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

This hasn't been tested yet.

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
0065.

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
