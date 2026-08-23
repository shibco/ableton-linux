# Push 3 controller support

Push 3 controller mode works with Live 12. The release-candidate implementation
reached `Push is go` in three hardware validation sessions. The later Ubuntu
and Arch-based sessions exercised the physical surface.

The final branch carries two Wine patches:

- [patch 0100](../patches/0100-libusb-1.0-extend-the-host-bridge-for-Push-3.patch)
  extends the USB bridge for the Push 3 helper
- [patch 0101](../patches/0101-winealsa-report-USB-MIDI-paths-and-identify-Push-3.patch)
  supplies the MIDI identity that starts the helper

[Push 3 support issue 26](https://github.com/shibco/ableton-linux/issues/26)
records user reports. [Pull request 152](https://github.com/shibco/ableton-linux/pull/152)
contains the release-candidate history and hardware evidence.

## User setup

Follow the [Push 3 setup steps](../README.md#ableton-push-3-setup). The USB
device rule gives the active desktop session access to `2982:1969`.

Connect Push 3 before Live starts. Select control mode on standalone hardware.
Live creates its Push control surface during startup.

Use the
[Push 3 connection steps](../TROUBLESHOOTING.md#push-3-stays-on-the-connection-screen)
for a device that keeps showing its connection screen.

## Device layout

Push 3 presents one composite USB device:

| interface | Linux use | endpoints |
| --- | --- | --- |
| 0 | Push display | bulk IN `0x81`, bulk OUT `0x01` |
| 1 to 4 | audio | managed by `snd-usb-audio` |
| 5 | Live, User, and External MIDI ports | managed by `snd-usb-audio` |
| 6 | xPort vendor stream | bulk IN `0x84`, bulk OUT `0x04` |

Both vendor interfaces use 512-byte packets. Push 2 uses interface 0 with the
same display endpoints. Push 3 adds interface 6.

## Startup sequence

Push 3 startup follows this sequence:

1. Live asks each MIDI input and output for its Windows device path.
2. Wine reports a path that contains USB identity `2982:1969`.
3. Live starts `Push3.exe`.
4. The prefix selects the built-in USB bridge for `Push3.exe`.
5. The helper claims interfaces 0 and 6 through host libusb.
6. The helper opens the display and connects its Live MIDI port.
7. The Push script completes its handshake with Live.

A successful helper log ends with this sequence:

```text
Found Push USB device (rev B)
Push display USB device opened
Push script loaded
Push sends greeting to Live
Push hardware identified
Push script initialized
Push is go
```

## USB bridge changes

Patch 0100 adds the 4 exports that `Push3.exe` imports:

- `libusb_bulk_transfer`
- `libusb_strerror`
- `libusb_hotplug_register_callback`
- `libusb_hotplug_deregister_callback`

The synchronous bulk transfer passes one request to host libusb. A timeout
value of zero waits indefinitely, following libusb rules.

The hotplug registration export returns `LIBUSB_ERROR_NOT_SUPPORTED`.
Ableton's helper then polls its device list. The interface guard accepts USB
interface numbers from 0 to 255.

Prefix setup selects this bridge for these helpers:

```text
Push2DisplayProcess.exe
Push3.exe
```

Each Live executable keeps Ableton's packaged libusb DLL. Live uses the MIDI
device path for Push detection.

## MIDI detection changes

Patch 0101 reports `DRV_QUERYDEVICEINTERFACE` for ALSA MIDI inputs and
outputs. The path contains the real USB vendor and product IDs. Its instance
part uses the current ALSA client and port numbers.

Live searches that path for `vid_2982&pid_1969`. The helper then searches for
its Live MIDI port by name.

Wine's usual Push 3 Live-port name gains an RtMidi index. Ableton's helper
accepts the shorter Windows name, `Ableton Push 3`. Patch 0101 gives that name
to the Push 3 Live port.

The name change applies to the Push 3 Live port. Push 2 and other USB MIDI
devices retain their existing names and saved Live settings.

## Report history

The reports explain the earlier mixed results:

- [pull request 117](https://github.com/shibco/ableton-linux/pull/117)
  supplied the USB bridge and helper override on 2 August 2026
- [the 5 August 2026 branch validation](https://github.com/shibco/ableton-linux/blob/71894e1c7c17b30a685c6f8d4b817d12d0faf902/notes/ABLETON-WINE-PUSH3-USB.md#verification)
  reached the handshake on a controller-only model
- [the 7 August 2026 report](https://github.com/shibco/ableton-linux/issues/26#issuecomment-5210810477)
  tested pull request 117 and kept showing the connection screen
- [pull request 152](https://github.com/shibco/ableton-linux/pull/152)
  added the MIDI device path and Push 3 port identity
- [the 14 August 2026 Ubuntu report](https://github.com/shibco/ableton-linux/pull/152#issuecomment-5290573455)
  confirmed the display, pads, MIDI ports, audio nodes, and full handshake
- [the 17 August 2026 Arch report](https://github.com/shibco/ableton-linux/pull/152#issuecomment-5311436349)
  confirmed pads, encoders, display, MIDI routing, and steady-state operation

The Ubuntu test used Live 12.4.3 Trial on GNOME and Wayland. The Arch test used
Live 12.4.3 Suite on niri, Wayland, and XWayland.

The 5 August session used controller hardware. The Ubuntu report describes its
unit simply as Push 3. The Arch session used standalone-capable hardware in
control mode with its compute module installed.

Patch 0100 keeps the hardware-tested USB bridge body. Patch 0101 keeps the
same Live-visible identity with a smaller implementation and a scoped name
change. A physical acceptance run forms the final gate for the refactored MIDI
path.

## Firmware behaviour

The Ubuntu unit started with firmware build 85. Live installed build 91 and
asked for a power cycle. The next start completed the handshake.

The Arch unit already used build 91. Its first start completed the handshake.

Follow the Push power prompt when Live installs firmware. Start Live again
after Push restarts.

## Repeated MidiHub messages

Both hardware tests recorded repeated summaries for this Ableton message:

```text
MidiHub: Failed to push MIDI message to outgoing queue
```

The Ubuntu report recorded roll-ups of 817 and 1,627 attempts. The Arch report
counted 14,735 attempts during 16 minutes. Pads, encoders, display, and MIDI
continued to work.

The longer test measured `Push3.exe` at 0.0% of one CPU core during an idle
10-second sample. Ableton's `Push3.exe` contains the message text. The project
uses Ableton's packaged executable. A Windows or macOS comparison can establish
the platform baseline for the message rate.

## USB probe

The host probe shares one implementation between Push 2 and Push 3. The
`push2usb.c` and `push3usb.c` files select their device model.

Compile and run the Push 3 probe:

```bash
cc -std=c11 -O2 -Wall -Wextra tools/push3usb.c \
  $(pkg-config --cflags --libs libusb-1.0) -o /tmp/push3usb
/tmp/push3usb --enumerate
/tmp/push3usb --claim
/tmp/push3usb --cancel-in
```

Use the xPort cancellation test for bridge diagnosis:

```bash
/tmp/push3usb --cancel-in-xport
```

The probe reads descriptors and IN endpoints. It preserves USB configuration,
kernel drivers, and OUT endpoints.

xPort can supply a complete 512-byte packet before cancellation finishes. The
probe accepts that result when the callback reports `cancelled`.

## Test scope

The current evidence covers:

- Live 12.4.3 on Ubuntu 24.04.3 and an Arch-based system
- GNOME and niri Wayland sessions through XWayland
- Push 3 controller hardware
- Push 3 standalone hardware in control mode
- display, pads, encoders, MIDI ports, PipeWire audio nodes, and the Live handshake
- the x86-64 Wine bridge
- helper polling after the hotplug registration result
- blocking bulk transfers with finite and zero timeouts

USB traces can contain the controller serial number. Replace it with
`[redacted]` before you share a trace.

General MIDI reconnection has its own release candidate. Follow
[MIDI hotplug issue 46](https://github.com/shibco/ableton-linux/issues/46) and
[hotplug pull request 245](https://github.com/shibco/ableton-linux/pull/245).
That candidate also supplies USB MIDI paths and changes every USB MIDI display
name. During branch integration, retain one path implementation and preserve
`Ableton Push 3` for port 0.
