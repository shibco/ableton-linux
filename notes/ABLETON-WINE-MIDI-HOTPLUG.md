# MIDI device hotplug

Wine now watches the Linux MIDI list for the full Ableton Live session.

A controller connected after Live starts appears in the Windows MIDI list.
Returning controllers keep their open input and output connections when their
device details identify one controller. Wine also ends held notes and sustain
when an input leaves. It ends long messages in progress.

We prevent port listing from other Wine processes. Live starts `Push3.exe` for
Push 3, and plug-in bridges run as their own processes. Each opens a sequencer
client named `WINE midi driver`, and its ports carry MIDI that Live already
sends or receives. Before 26 August 2026 those ports entered the device list,
and Live routed its own Push output back into its input. The
[hidden Wine clients section](ABLETON-WINE-DEVICE-HOTPLUG.md#hidden-wine-clients)
of the device hotplug note explains the filter. The
[Push 3 note](ABLETON-WINE-PUSH3-USB.md#live-and-push3exe-share-one-midi-driver)
records the report.

Use `aconnect -l` to inspect the Linux MIDI graph. The automated check is:

```bash
./tools/test-midi-hotplug.sh
```

The check covers new devices, removal, repeated return, changed Linux device
numbers, duplicate names, Windows device-change messages, and ports of other
Wine processes staying out of the device list. Release approval
adds real USB hardware and a supported Ableton Live build.

[Issue 46](https://github.com/shibco/ableton-linux/issues/46) tracks this work.
