# README

(note: in progress work)

Use this test kit to check Ableton Live 12 with Ableton Wine on Linux.


## Getting started

Use a physical x64 Linux machine. VMs are not supported.

From the root of this repository:

```bash
./tester-kit/run-session
```

The command records your system, downloads and checks the Wine installer, prepares `~/.wine-ableton`, runs the tests and writes:

```text
session-YYYY-MM-DD-HHMMSS.txt
```

The collector omits unique hardware identifiers, account paths, MAC addresses, credential-like values and captured window titles. A report containing excluded data is a collector failure: keep it local and report the failure instead of cleaning and sharing it manually. The environment-profiler scope is documented in [scripts/README.md](scripts/README.md).

After installing Live in `~/.wine-ableton`, start Live and run the checks. They inspect its open windows without clicking or typing in Live.

```bash
./tester-kit/run-session --live-only \
  --wine "$HOME/.local/opt/ableton-wine/current/bin/wine"
```

For every option and test, read [tester-kit/README.md](tester-kit/README.md).
