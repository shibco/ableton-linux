# Prove NTSync during each benchmark

Date: 26 August 2026

A useful NTSync result records three separate facts:

- the Wine build includes NTSync support
- the host provides `/dev/ntsync`
- the matching wineserver opens `/dev/ntsync` while Live runs

The branch records each fact directly. The launcher prints a warning for an
`unavailable` host device and continues. `audio-report.sh` links each wineserver
to its exact `WINEPREFIX`. It counts that process's open `/dev/ntsync` files.

`check-ntsync.sh` requires the host device by default. A host device result of
`unavailable` makes the check exit with status 3 before Wine starts. Set
`ABLETON_REQUIRE_NTSYNC=off` for a planned regular-route test. The result then
labels NTSync as inactive.

The checker also runs 27 timing and wake tests through `ntsyncprobe.exe`. Use
the device state, build support and wineserver file count together in every
benchmark report.
