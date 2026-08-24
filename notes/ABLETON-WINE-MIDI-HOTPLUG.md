# MIDI device hotplug

Wine now watches the Linux MIDI list for the full Ableton Live session.

A controller connected after Live starts appears in the Windows MIDI list.
Returning controllers keep their open input and output connections when their
device details identify one controller. Wine also ends held notes and sustain
when an input leaves. It ends long messages in progress.

Use `aconnect -l` to inspect the Linux MIDI graph. The automated check is:

```bash
./tools/test-midi-hotplug.sh
```

The check covers new devices, removal, repeated return, changed Linux device
numbers, duplicate names and Windows device-change messages. Release approval
adds real USB hardware and a supported Ableton Live build.

[Issue 46](https://github.com/shibco/ableton-linux/issues/46) tracks this work.
