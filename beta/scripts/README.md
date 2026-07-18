# Environment profilers

One-command system summaries for bug reports:

- `ableton-linux-profiler.sh`
- `ableton-macos-profiler.sh`
- `ableton-windows-profiler.ps1`

Each prints a short system summary and copies it to the clipboard, fenced
for pasting straight into a GitHub issue. Review the printed summary
before pasting it. They collect only what a reviewer needs to place a
report:

- **Linux:** distribution and kernel, CPU model and count, memory, board
  vendor/product, OpenGL vendor/renderer/version, desktop and session
  type, PipeWire/WirePlumber state and versions, audio devices, MIDI
  devices.
- **macOS:** OS version, hardware model, CPU, memory, audio devices
  (device names generalised), installed Ableton Live versions.
- **Windows:** the equivalent system, graphics and audio summary.

## Redaction scope

All three profilers filter their output through the same rules:

- the user's home directory becomes `<HOME>`, other account paths become
  `<USER>` (`/home/<name>`, `/Users/<name>`, and `/run/user/<uid>` on
  Linux);
- MAC addresses become `<MAC>`, email addresses become `<EMAIL>`, LUKS
  volume UUIDs become `luks-<REDACTED>`;
- any line keyed by a unique identifier is dropped: serial numbers,
  UUID/UDID/WWN/GUID, unique or processor IDs, asset tags, instance or
  PNP device IDs, addresses, location IDs, mount points, BSD names,
  device identifiers;
- credential and licence values are blanked in place (`password`,
  `token`, `secret`, API keys, `MachineGuid`, `Unlock.json`, Ableton
  serial/licence fields) as `<key>=<REDACTED>`;
- redaction replaces whole path components only, so a placeholder never
  lands inside ordinary data (the word-boundary rule; captures older
  than 2026-07-11 predate it).

The tester-kit session collector applies the same rules plus captured
window titles, and additionally replaces credential-like lines outright.

## Privacy gate

`check-profiler-privacy.sh` enforces the scope: it fails if a forbidden
collection pattern (login names, hardware serials, full inventories)
appears in any profiler or in the tester-kit collector, if a required
redaction step goes missing, or if a mock profiler run against a stubbed
`system_profiler` retains a private value. Run it after editing any
profiler or collector — a report that contains excluded data is a
collector failure, not something to clean by hand.

```bash
./scripts/check-profiler-privacy.sh
```
