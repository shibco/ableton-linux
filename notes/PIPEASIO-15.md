# PipeASIO 1.5 behaviour

Ableton Linux ships the 64-bit PipeASIO 1.5.0 driver.

## Required PipeWire version

This project requires PipeWire 1.4.2 or newer. Before replacing the runtime,
the installer checks the host library and the running service. It leaves the
current installation in place when either version is too old or unreadable.
Ubuntu 24.04 and Linux Mint 22 ship older PipeWire and need a distribution
upgrade for this release.

## Buffers and graph changes

Live can select any whole buffer from 32 to 8192 frames, including values that
are not powers of two:

```bash
env PIPEASIO_PREFERRED_BUFFERSIZE=512 ableton-live
```

PipeWire shares one graph quantum between applications. If another application
changes it, PipeASIO asks Live to rebuild at that size and sends silence while
the sizes differ. It retries after five seconds and limits requests to three
per minute. When the foreign request ends, it asks Live to return to the saved
size.

For diagnosis only, `PIPEASIO_ALLOW_QUANTUM_MISMATCH=on` disables the pause and
request. Audio may then run at the wrong speed.

## Sample rate and devices

PipeASIO asks PipeWire for Live's selected rate and keeps the accepted value
across an audio-engine restart. If the device rejects the request, it reports
the rate PipeWire kept and does not save the rejected value.

Explicit input and output choices take priority. With only an output selected,
the driver looks for an input on the same device, then the default input, then
the first input. It reports separate clock domains when input and output use
different devices. Two-device audio remains supported; PipeWire resamples to
keep the streams aligned.

## Scheduling

PipeASIO real-time scheduling is off by default and is separate from the
launcher's `ABLETON_RT` setting:

```bash
env PIPEASIO_REALTIME=on ableton-live
env PIPEASIO_REALTIME=off ableton-live
```

## Settings window

Open PipeASIO Settings from the application menu or Live's Hardware Setup
button. It changes devices, channel counts, buffer, rate, and scheduling. Live
can use the driver without this Qt 6 window.

After saving, select None and then PipeASIO again in Live. The configuration is
`$XDG_CONFIG_HOME/pipeasio/config.ini`, or `~/.config/pipeasio/config.ini` when
`XDG_CONFIG_HOME` is unset.

## Timing and limits

MIDI timestamps use the Wine clock and continue forwards across the 32-bit
millisecond wrap after about 49.7 days.

During stable periods with matching block sizes, PipeASIO calls Live's audio
engine once per PipeWire graph period. A 48 kHz rate with 64 frames produces
750 calls each second. Smaller buffers make Live wake and wait for its workers
more often.

Ableton Linux provides a Live 12 limit for audio workers. Users select the
value. The tested value was 16. Wine reported 32 logical CPUs. Live had access
to 32 Linux CPUs. The worker count changed from 31 to 16. The
[CPU troubleshooting guide](../TROUBLESHOOTING.md#live-uses-high-cpu-on-small-sets)
explains how to apply and test the value.

Audio continuity depends on available processor time, an attached device, and
a running PipeWire service. The CPU tests used PipeASIO 1.5 with Live 12.4.3.
