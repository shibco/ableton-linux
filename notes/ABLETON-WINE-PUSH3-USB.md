# Push 3 controller support

Push 3 controller mode works with Live 12. The release-candidate implementation
reached `Push is go` in three hardware validation sessions. The later Ubuntu
and Arch-based sessions exercised the physical surface.

The current Wine series has two patches that target  Push 3:

- [patch 0106](../patches/0106-libusb-1.0-extend-the-host-bridge-for-Push-3.patch)
  extends the USB bridge for the Push 3 helper
- [patch 0105](../patches/0105-winealsa-make-MIDI-topology-dynamic-and-recover-hotplug.patch)
  supplies the USB MIDI identity and Live-port name that start the helper

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

Patch 0106 adds the 4 exports that `Push3.exe` imports:

- `libusb_bulk_transfer`
- `libusb_strerror`
- `libusb_hotplug_register_callback`
- `libusb_hotplug_deregister_callback`

The synchronous bulk transfer passes a request to host libusb. A timeout
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

Patch 0105 reports `DRV_QUERYDEVICEINTERFACE` for ALSA MIDI inputs and
outputs. The path contains the real USB vendor and product IDs. Serial numbers,
hardware paths, interface numbers, and port numbers keep the identity stable
where Linux provides them.

Live searches that path for `vid_2982&pid_1969`. The helper then searches for
its Live MIDI port by name.

Wine's usual Push 3 Live-port name gains an RtMidi index. Ableton's helper
accepts the shorter Windows name, `Ableton Push 3`. Patch 0105 gives that name
to the Push 3 Live port.

Patch 0105 gives every USB MIDI port a Windows-style name. Existing Live MIDI
device and control-surface assignments may need to be selected again.

## Live and Push3.exe share one MIDI driver

Live and `Push3.exe` are separate Wine processes. Each loads winealsa and
opens its own ALSA sequencer client named `WINE midi driver`. Each client
creates application ports: `WINE ALSA Input` for the open WinMM inputs and
`WINE ALSA Output #N` for every open WinMM output. Wine subscribes these
ports to the device ports.

Until 26 August 2026 the driver hid only the sequencer clients of its own
process from the device list. The other process's application ports passed
the filter and appeared as WinMM devices, for example `WINE ALSA Output #7`
as a MIDI input. The client and port names together overflow `MAXPNAMELEN`,
so WinMM shows the port name alone. One process opened
the other's output as an input. The `aconnect` output from the report shows
the result: the `WINE ALSA Output #7` port of one client subscribed to port 0,
`WINE ALSA Input`, of the other. Push pad lights are note-on messages on
channel 1, so every pad light arrived in Live as a new note. A pad press lit
the pad, the light came back as a press, and the note repeated.

Two testers reported this on
[issue 26](https://github.com/shibco/ableton-linux/issues/26) on 25 August
2026. `aconnect -d 131:1 129:0` removed the subscription and stopped the
notes until the next Live start.

Patch 0105 now skips every user client named `WINE midi driver` or
`WINE MIDI topology`, not only the client ids the current process owns.
Upstream Wine uses the first name too, so plug-in bridges that run on plain
Wine stay hidden as well. The topology monitor port also contains
`SND_SEQ_PORT_CAP_NO_EXPORT`, so routing tools no longer offer it as a
device. The data ports keep their export capability: PipeWire drops
`NO_EXPORT` ports from its graph, and users route PipeWire MIDI into Live
through those ports.

The `monitor-leak` case in `tools/test-midi-hotplug.sh` covers this. A second
Wine process must list none of the first process's ports. The
[hidden Wine clients section](ABLETON-WINE-DEVICE-HOTPLUG.md#hidden-wine-clients)
of the device hotplug note covers the routing consequences.

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

Patch 0106 keeps the hardware-tested USB bridge body. Patch 0105 replaces the
branch's overlapping MIDI implementation and retains the Live-visible Push 3
identity. A physical acceptance run remains open for this integrated patch
stack.

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

Both tests ran before the driver hid the other process's ports. The MIDI loop
described above may explain the queue failures. A run after the fix can
confirm that.

## USB probe

The host probe shares its implementation between Push 2 and Push 3. The
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

General MIDI hotplug is implemented by patch 0105. See
[MIDI hotplug issue 46](https://github.com/shibco/ableton-linux/issues/46) and
[hotplug pull request 245](https://github.com/shibco/ableton-linux/pull/245).
The integrated series keeps that single MIDI path implementation and preserves
`Ableton Push 3` for port 0.
