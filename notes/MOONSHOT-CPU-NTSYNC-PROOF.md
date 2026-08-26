# Prove NTSync during each benchmark

Date: 26 August 2026

A useful NTSync result records three separate facts:

- the Wine build includes NTSync support
- the host provides `/dev/ntsync`
- the matching wineserver opens `/dev/ntsync` while Live runs

The branch records each fact directly. The launcher prints a warning while host
device evidence remains pending. It then continues. `audio-report.sh` links each
wineserver to its exact `WINEPREFIX`. It counts that process's open
`/dev/ntsync` files.

`check-ntsync.sh` requires host device evidence by default. Pending device
evidence makes the check exit with status 3 before Wine starts. Set
`ABLETON_REQUIRE_NTSYNC=off` for a planned regular-route test. The result then
identifies Wine's regular route.

The checker also runs 27 timing and wake tests through `ntsyncprobe.exe`. Use
the device state, build support and wineserver file count together in every
benchmark report.
