# Audio device enumeration can crash or hang

Two faults can stop Live after `Audio In Out: Constructor finished`. Check
WirePlumber first. A stopped session manager and a corrupt Wine endpoint
registry leave the same final log line.

## Check WirePlumber

Run:

```bash
systemctl --user is-active wireplumber.service
pactl list short cards
```

If WirePlumber is inactive or no cards appear, restart it:

```bash
systemctl --user restart wireplumber.service
```

With WirePlumber stopped, PipeWire can expose only `auto_null`. winepulse may
then block while Live enumerates endpoints.

## Repair a corrupt endpoint registry

Wine used to wrap the stored `FriendlyName` again each time it loaded an
absent endpoint. Names such as `Speakers (Speakers (...))` gained one level
per launch; more than 70 levels were observed. Present devices received a
fresh driver name, while disconnected Bluetooth, USB, and monitor endpoints
kept growing until enumeration failed.

[Patch 0021](../patches/0021-mmdevapi-stop-re-wrapping-reloaded-endpoint-Friendly.patch)
adds an `init_props` flag to `MMDevice_Create()`. Wine now generates name
properties only from a raw driver name and preserves properties loaded from
the registry.

The patch stops further growth but cannot repair names already stored in a
prefix. Clear the endpoint registry once, using this project's Wine and
prefix:

```bash
WINEPREFIX="$HOME/works/plugs/studio" \
  "$(works runtime path)/bin/wine" reg delete \
  'HKLM\Software\Microsoft\Windows\CurrentVersion\MMDevices\Audio' /f
```

Set the paths to your `WORKS_PLUG` and `WORKS_RUNTIME` values if
you use launcher overrides. Active endpoints return with flat names on the
next launch. Disconnected endpoints return only after the device reconnects.
