# PipeASIO implementation record

PipeASIO 1.2.2 replaced WineASIO in release 2026.07.17.2. It exposes Live as a
native PipeWire client and removes JACK from Live's audio path.

This ignored note records the evaluation performed on 2026-07-17. The 1.2.2
sections below stand as written; the 2026-08-09 update at the end supersedes
them where they disagree.

## Update 2026-08-09: 1.5.0

Branch `moonshot-pipeasio-15` moves the vendored source to the v1.5.0 tag
(no upstream release asset yet). What the update carries, from upstream's
changelog and verified here:

- 1.4.3 schedules the driver synchronously (clears `node.async` after
  `pw_filter_connect`). Round trip drops from two buffer periods to one.
- 1.4.1 makes the graph rate authoritative for `GetSampleRate`, and 1.5.0
  lets the host set a rate (`CanSampleRate` offers the standard set,
  `SetSampleRate` pins the graph through `node.force-rate`). Live's
  sample-rate menu works.
- 1.5.0 reports the connected device chain's delay in `GetLatencies`
  (`PW_FILTER_FLAG_CUSTOM_LATENCY`), relays `kAsioLatenciesChanged`, and
  counts missed cycles in the log.
- The PipeWire floor is 1.4.2 (upstream builds against nothing older;
  `spa_json_str_object_find` is from 1.4.0). Ubuntu 24.04 / Mint 22.x
  (1.0.5) are below it; issue #150 shows that population already failing
  on 1.2.2 for a different reason.

The patch series was re-ported: 0001 narrowed to the config-pinned rate
path (Live still dies on ASE_NoClock), 0002/0006/0007 carried over, 0003
retired into 0005's diagnostic texts, 0004 extended to the CreateBuffers
gate 1.5 added (host-controlled non-power-of-two requests returned -997),
0005 rebuilt on the 1.5 settings-metadata handler and diagnostic relay,
with WoW64 proxy entries added. `pipeasio-settings` (Qt 6 Widgets, talks
to PipeWire via `pw-dump`) builds in the container and ships in the
runtime (issue #60).

Driver-level verification, 2026-08-09, CachyOS host, system wine, upstream
`asio_loopback`/`asio_probe` against the session daemon and a null sink:

- Round trip exactly 1.00 buffer periods at 128/192/256/512/883 frames
  (1.2.2 built the same way measures 2.00 at 256: 10.67 ms vs 5.33 ms).
- Zero discontinuities, bit errors, and sign errors in every window.
- CPU within noise of 1.2.2 (loopback process 0.4% vs 0.3% of one core,
  pipewire 1.8% both).
- Predict path: with a global `clock.force-quantum 192` set, the driver
  offers 192 from `GetBufferSize` and the run is clean at one period.
- `asio_probe` passes lifecycle, cadence, position, latency-settle, and
  measured-rate checks.

Open: container build + audit run, a production-prefix run of
`check-live-audio.sh`, the Live-level listening pass, and the two-device
hardware run for 0007. "Works here" on this machine says nothing about the
C3/C6 crackle causes.

## Why it replaced WineASIO

Issue #4 reported summed mono inputs and high latency under load. Issue #5
requested access to local PipeWire sources that were not exposed through
PipeWire's JACK layer.

PipeASIO provides:

- native PipeWire input and output ports
- configurable channel counts and device selection
- graph-rate following or a forced sample rate
- optional automatic connections
- a graph quantum matched to the ASIO buffer on PipeWire 1.6 or newer

Live 12 is 64-bit, so this project ships both PipeASIO PE names for
compatibility but only needs the 64-bit driver path.

## Integration

The build uses the pinned `vendor/pipeasio-1.2.2.tar.gz` source and applies the
two-patch [`patches/pipeasio`](../patches/pipeasio/) series. Patch 0001 clamps
unsupported sample-rate requests. Patch 0002 reports the clock Live uses for
MIDI timestamps.

PipeASIO is compiled against the exact Wine tree in the Podman build. The
runtime contains:

```text
lib/wine/x86_64-windows/pipeasio64.dll
lib/wine/x86_64-windows/pipeasio.dll
lib/wine/x86_64-unix/pipeasio64.dll.so
lib/wine/x86_64-unix/pipeasio.dll.so
```

`container-build.sh` verifies the four files and their registration. It also
checks for the sample-rate clamp marker and the host
`libpipewire-0.3.so.0` dependency.

The build image carries a pinned PipeWire 1.6.2 SDK because Ubuntu 22.04's
PipeWire headers are too old for the functions used by PipeASIO. The shipped
runtime accepts host PipeWire 0.3.56 or newer.

Prefix setup removes the old WineASIO registration, registers
`pipeasio64.dll`, and creates this file when it is absent:

```text
~/.config/pipeasio/config.ini
```

The default is two inputs, two outputs, a fixed 256-frame buffer, and automatic
connection. `PIPEASIO_*` environment variables override INI values for one
launch. For example, `PIPEASIO_PREFERRED_BUFFERSIZE=512` raises the buffer.

The Hardware Setup button displays a message that points to the native
`pipeasio-settings` program. This project does not ship the Qt application.

## Validation from 2026-07-17

PipeASIO was tested in a separate copy of the Live 12.4.3 prefix:

- `regsvr32 pipeasio64.dll` created the PipeASIO ASIO registration.
- The upstream `asio_probe` opened two inputs and two outputs, adopted the
  graph rate, maintained callback cadence, and stopped cleanly.
- Live opened at 48 kHz without `FatalError`.
- A 256-frame configuration produced a PipeWire `force-quantum` value of 256.
- PipeWire linked `capture_FL` to `in_1` and `capture_FR` to `in_2`, with one
  link per channel.
- With the graph at 44.1 kHz and Live set to 48 kHz, PipeWire resampled and
  Live opened at 48 kHz.
- With PipeASIO fixed at 44.1 kHz, Live adopted 44.1 kHz.
- A fresh Live preferences directory selected the only ASIO device and adopted
  its rate.
- A prefix that still named WineASIO fell back to PipeASIO after WineASIO was
  removed.

The test recorded about 8% Live DSP load at 48 kHz and 256 frames. PipeWire's
error counter increased from 24 to 26 during a short run on a loaded machine.
That snapshot is not a controlled latency comparison.

## Remaining evidence gaps

- Reproduce issue #4 under WineASIO on the same interface. The PipeWire graph
  showed separate PipeASIO channels, but the original WineASIO fault was not
  reproduced during this evaluation.
- Compare WineASIO and PipeASIO xruns under the same load.
- Test a sample-rate change from Live while the driver is open.
- Test hardware that supports only one sample rate.
- Complete Steam Deck and installer round-trip tests.

Audio reconnect behavior is documented separately in
[ABLETON-WINE-AUDIO-HOTPLUG.md](ABLETON-WINE-AUDIO-HOTPLUG.md).
