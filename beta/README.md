# Ableton Wine beta test kit

This work-in-progress kit tests Ableton Live 12 with Ableton Wine on Linux.

## Getting started

Use a physical x86-64 Linux machine. The kit does not support virtual machines.

From the root of this repository:

```bash
./beta/tester-kit/run-session
```

The command collects a redacted system report, downloads and verifies the
configured Wine installer, prepares `~/works/plugs/studio`, runs the probes, and
writes:

```text
session-YYYY-MM-DD-HHMMSS.txt
```

The collector removes unique hardware identifiers. It redacts account paths,
MAC addresses, credential lines, and captured window titles. If excluded data
appears, keep the report local and report the collector failure. Do not share
that report, even after removing the data. See
[Environment profilers](scripts/README.md) for the full scope.

After installing Live in `~/works/plugs/studio`, start it and run the Live checks:

```bash
./beta/tester-kit/run-session --live-only \
  --wine "$(works runtime path)/bin/wine"
```

The command asks you to open Learn View and one representative Direct2D or
JUCE plugin editor. L01-L05 inspect those windows without injecting input.
L10-L12 ask you to check window stability, input, and Learn View rendering.
See the [tester kit reference](tester-kit/README.md) for all options and
probes.
