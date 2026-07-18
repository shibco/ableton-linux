# Advanced test tools

These tools are for investigating a specific failure. The normal tester command
never runs them. Some tools send input, close Live or change audio connections.

Save the project before using them. Record the exact command in the issue.

## Build the Linux tools

From the root of this repository:

```bash
./tester-kit/probes/build-native-tools
```

The script writes the programs and `build-results.txt` under
`tester-kit/probes/advanced/native/`. It stops if no C compiler is installed.
A missing development library marks the affected program `SKIP`. The script
does not install packages or use `sudo`.

## Live input trace

This is the only advanced tool started by `run-session`:

```bash
./tester-kit/run-session --live-only \
  --advanced-input-trace \
  --wine "$HOME/.local/opt/wine-d2d1-nspa-11.11/bin/wine"
```

The command asks you to type `TRACE`. It then watches Wine mouse input and JUCE
plug-in windows for 15 seconds. Use the affected window during those 15
seconds.

The trace can remain loaded in Live until Live exits. Save first and quit Live
after the trace.

## Windows tools

| Tool | What it does |
| --- | --- |
| `liveinject.exe` | Sends keyboard or pointer input to Live. It can also ask Live to close. |
| `showrestore.exe` | Restores a minimised Live window, then asks Live to close. |
| `wmresize.exe` | Opens a test window and measures whether resizing stops. |
| `spyhost.exe` and `mousespy.dll` | Install a Wine-wide mouse hook and inspect JUCE plug-in windows. |

Run these files with the same Wine executable and Wine folder used by Live.

## Linux tools

| Tool | What it does |
| --- | --- |
| `fakectl` | Creates a temporary ALSA MIDI controller. |
| `jacklinkd` | Restores selected JACK or PipeWire audio connections. |
| `uclick` | Sends keyboard or pointer input through Linux `uinput`. |
| `xact` | Changes X11 window activation and focus. |
| `xmon` | Records focus, properties and size for one X11 window. |
| `xrec` | Records focus and input events across X11 programs. |
| `xtool` | Sends pointer or keyboard input through XTEST. |
| `xsettle` | Finds, resizes and measures the Live XWayland window. |
| `xdmg` | Records redraw events for one X11 window. |
| `xgrid` and `xsamp` | Measure pixel changes in Learn View and plug-in windows. |

`liveinject.exe`, `showrestore.exe`, `jacklinkd`, `uclick`, `xact` and `xtool`
change Live, audio connections or input. Use them only for the test named in an
issue.
