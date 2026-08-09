# Live 11 media playback crash in `wmvcore`

Status: Live 11 support remains experimental. Previewing or importing a WMA
or video file can crash Live 11 because Wine raises
`EXCEPTION_WINE_STUB` from `wmvcore.dll`. Live 12 does not use this path.
Avoid these files until the missing export is identified and patched.

## Evidence

Every sampled dump has exception code `0x80000100`
(`EXCEPTION_WINE_STUB`). `kernelbase.dll` raises the exception, and both
exception strings identify `wmvcore.dll`.

Live 11 loads the Windows Media Format runtime for media import and browser
preview. Wine compiles each `@ stub` entry in `dlls/wmvcore/wmvcore.spec`
into a thunk that logs `fixme:wmvcore:<function> stub!` and raises
`0x80000100`. This matches the dumps. The dumps do not identify which export
Live called.

## Capture the missing export

Set `WINEDEBUG` before using the launcher, then trigger the crash by
previewing a WMA or video file:

```bash
ABLETON_LIVE_VERSION=11 WINEDEBUG=-all,fixme+wmvcore ableton-live \
  2>&1 | tee "$HOME/live11-wmvcore.log"
grep -E 'fixme:wmvcore:[A-Za-z0-9_]+ stub' "$HOME/live11-wmvcore.log" | sort -u
```

## Planned fix

No patch exists yet. The trace must identify the stub before implementation.
Match the confirmed export's SDK signature and documented failure behavior. A
wrong argument count can corrupt a 32-bit caller's stack in this WoW64 build.

Add the patch to `patches/SERIES.sha256` with
`./scripts/build-audit.sh --freeze`, then add an artifact fingerprint to the
build audit. Retest Live 11 and Live 12. Live 11 should report an import
failure and continue running, with no new `0x80000100` dump.

## Install Live 11 manually

These notes were tested with Live 11.2.11. Create the prefix with the Live 11
support files:

```bash
ABLETON_LIVE_VERSION=11 ./scripts/setup-prefix.sh
```

The `vcrun2019` and `gdiplus` payloads are not vendored, so this step needs
network access on its first run.

Install Live with the packaged Wine:

```bash
WINEPREFIX="$HOME/works/plugs/studio" \
  "$(works runtime path)/bin/wine" \
  "/path/to/Ableton Live 11 Suite Installer.exe"
```

Live 11.3.3 and later installers include `tlsetupfx.exe`, Ableton's USB
driver installer. It can fault under Wine and open a debugger dialog. This is
a known limitation documented in `scripts/setup-prefix.sh`.

When Live 11 and Live 12 share a prefix, select Live 11 explicitly:

```bash
ABLETON_LIVE_VERSION=11 ableton-live
```

Authorize with your own account. For an offline response file, pass its Unix
path to the launcher:

```bash
ableton-live "$HOME/Downloads/ableton_live_11.auz"
```

The launcher uses `wine start /unix` for an existing `.auz` file. Online
authorization uses the `ableton:` handler installed from
`desktop/wine-protocol-ableton.desktop.in`. Authorization is bound to the
prefix's `MachineGuid`, so keep the prefix.

After Live's first run, move Max for Live 8's incompatible preferences aside:

```bash
./scripts/setup-prefix.sh --post-first-run
```

The command keeps a timestamped backup. Max creates a new preferences file on
its next start.

PipeASIO opens in the tested Live 11 setup at 48 kHz with a fixed 256-frame
buffer. Issue #14 reports distorted output while MME/DirectX works; the cause
is unknown. If audio crackles, try
`PIPEASIO_PREFERRED_BUFFERSIZE=512 ABLETON_LIVE_VERSION=11 ableton-live` and
run `./scripts/check-live-audio.sh`.

## Limits

- The issue #14 dumps confirm the crash signature, not the exact export.
- Live's in-app network access can fail under Wine. An offline `.auz` file
  avoids the online authorization path.
