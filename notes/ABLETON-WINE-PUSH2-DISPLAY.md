# Push 2 display support

[Patch 0032](../patches/0032-libusb-1.0-add-host-USB-bridge-for-Push-2.patch)
lets `Push2DisplayProcess.exe` reach Push 2's display interface through host
libusb. [Patch 0100](../patches/0100-libusb-1.0-extend-the-host-bridge-for-Push-3.patch)
extends the same 64-bit bridge for the Push 3 helper.

## Configure Live once

Use one control-surface row:

- control surface: `Push2`
- input: `Ableton Push 2 Live Port`
- output: `Ableton Push 2 Live Port`

Enable both Remote switches. Keep the Live Port as the single Push2 row. A
second row starts a second display helper, while USB interface 0 serves one
helper at a time.

## USB path

Push 2 uses USB ID `2982:1967`. Interface 0 carries display bulk endpoints
`0x01` and `0x81`; interfaces 1 and 2 carry audio control and MIDI. The builtin
`libusb-1.0.dll` implements 20 Win64 ABI calls. Push 2 uses its original 16
calls. The bridge passes fixed-width requests to host `libusb-1.0.so.0`.

Prefix setup selects the builtin for `Push2DisplayProcess.exe` and
`Push3.exe`. Live keeps its packaged DLL. ALSA manages the MIDI interfaces.

## Check the bridge

`tools/push2usb.c` uses the shared host probe for Push 2. The PE probe in
`tools/push2usb-pe.c` verifies exports, ordinals, enumeration, repeated claims,
and cancellation. A physical check confirms display streaming, Live controls,
MIDI service, and helper exit.

Use `aconnect -l` for Wine's ALSA sequencer path and `amidi -l` for raw MIDI.
The display helper reports `Shutting down because live didn't ack in time`
when you run it by itself.

To remove the per-application override for a comparison:

```bash
env WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" reg delete \
  'HKCU\Software\Wine\AppDefaults\Push2DisplayProcess.exe\DllOverrides' \
  /v libusb-1.0 /f
```

Run a prefix refresh to restore the override. Extended hardware coverage
remains useful for disconnect and `NO_DEVICE` recovery. Raw USB traces can
include the controller serial number. Replace it with `[redacted]` before you
share a trace.
