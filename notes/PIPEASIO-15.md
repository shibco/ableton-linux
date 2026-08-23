# PipeASIO 1.5 behaviour

Ableton Linux ships the 64-bit PipeASIO 1.5.0 driver.

## Required PipeWire version

This project requires PipeWire 1.4.2 or newer. The installer replaces the
runtime after the host library and service checks report version 1.4.2 or
newer. Ubuntu 24.04 and Linux Mint 22 need a distribution upgrade for this
release.

## Buffers and graph changes

Live can select every whole buffer from 32 to 8192 frames:

```bash
env PIPEASIO_PREFERRED_BUFFERSIZE=512 ableton-live
```

PipeWire shares one graph quantum between applications. If another application
changes it, PipeASIO asks Live to rebuild at that size and sends silence while
the sizes differ. It retries after five seconds and limits requests to three
per minute. When the foreign request ends, it asks Live to return to the saved
size.

For diagnosis, `PIPEASIO_ALLOW_QUANTUM_MISMATCH=on` lets audio continue during
a size difference. The playback speed can differ.

## Sample rate and devices

PipeASIO asks PipeWire for Live's selected rate. It reports the active rate
after every request. It saves the selected rate after PipeWire accepts it.

Explicit input and output choices take priority. With automatic input, the
driver first uses the selected output device. It then uses the default input or
the first input. It reports separate clock domains when input and output use
different devices. Two-device audio remains supported. PipeWire resamples to
keep the streams aligned.

PipeASIO remembers selected interfaces and channel routes while Live runs. It
sends silence while an interface is away and restores the full route set when
the same interface returns. It also rebuilds the audio connection after a
PipeWire restart.

## Scheduling

PipeASIO uses standard scheduling by default. This setting is separate from
the launcher's `ABLETON_RT` setting. Use this command for real-time scheduling:

```bash
env PIPEASIO_REALTIME=on ableton-live
```

## Settings window

Open PipeASIO Settings from the application menu or Live's Hardware Setup
button. It changes devices, channel counts, buffer, rate, and scheduling.
PipeASIO applies device, buffer, rate and scheduling changes while Live runs.
Channel count and node name changes apply after you reselect PipeASIO. Live can
use the driver by itself. The Qt 6 window provides optional settings.

The configuration is `$XDG_CONFIG_HOME/pipeasio/config.ini`. The default
location is `~/.config/pipeasio/config.ini`.

## Timing and limits

MIDI timestamps use the Wine clock and continue forwards across the 32-bit
millisecond wrap after about 49.7 days.

PipeASIO 1.5 keeps the existing CPU needs of Live and its plug-ins. Smaller
buffers give the engine less processing time. PipeASIO sends silence during
device and service recovery. Release approval includes a supported Ableton
Live build and real USB audio hardware.
