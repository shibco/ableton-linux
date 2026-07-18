# Live 11: media playback crash (wmvcore EXCEPTION_WINE_STUB)

## Symptoms

Live 11 (any edition) dies ~0.5 s into playing or browser-previewing a WMA or
video file; VSTs loaded from the browser can crash the same way via preview.
Every sampled crash dump shares one signature: exception code `0x80000100`
(Wine's `EXCEPTION_WINE_STUB`), raised from `kernelbase.dll`
(`RaiseException`) with both exception strings pointing into `wmvcore.dll`.
Live 12 is unaffected — it never reaches these exports.

## Research

`wmvcore.dll` is the Windows Media Format (WMF) runtime Live 11 loads for
media import and browser preview (`VideoExportMMF.dll` is loaded too). The
`@ stub` entries in `dlls/wmvcore/wmvcore.spec` compile to thunks that print a
`fixme:wmvcore:<function> stub!` line and then raise `0x80000100` with the
module and function names as exception strings — exactly the dump signature.
Live 11 decodes WMA and video soundtracks through WMF; Live 12 uses a
different decode path.

Name the missing export before writing any patch. The launcher forces
`WINEDEBUG=-all` (fixme spam stalls Live's UI thread), so the capture must
invoke the runtime directly; trigger the crash by previewing a WMA or video
file:

```bash
export WINEPREFIX="$HOME/.wine-ableton"
WINE="$HOME/.local/opt/wine-d2d1-nspa-11.11/bin/wine"
WINEDEBUG=-all,+fixme "$WINE" \
  "C:\ProgramData\Ableton\Live 11 Suite\Program\Ableton Live 11 Suite.exe" \
  2>&1 | tee "$HOME/live11-wmvcore.log"
grep -E 'fixme:wmvcore:[A-Za-z0-9_]+ stub' "$HOME/live11-wmvcore.log" | sort -u
```

## Mitigations

Until a Wine patch ships, Live 11 is **installable but unsupported**: avoid
browser preview and import of WMA/video files. The planned fix is
`patches/0035-wmvcore-fail-gracefully-when-wmf-reader-unavailable.patch` (the
series runs 0001–0034, 0027 retired): convert the called stub(s) — expected at
the `WMCreateReader`/`WMCreateSyncReader` level, confirmed by the capture
above — from fatal stubs into real exports that return a decoder-unavailable
`HRESULT` (`*reader = NULL; return NS_E_INVALID_REQUEST;`), so media import
degrades to "file not decodable" instead of raising. The contract is "return,
don't raise"; spec arities must match the SDK prototypes exactly (a wrong
count corrupts the stack for 32-bit callers in this WoW64 build). Rebuild
through the normal gate (`scripts/build-audit.sh --freeze` extends
`patches/SERIES.sha256`; add a fingerprint row for the FIXME literal), then
retest: expect a logged import failure, continued operation, and zero
`0x80000100` in fresh dumps; regression-check Live 12.

## Installing Live 11 manually

- Pin **Live 11.2.11** as the supported target. 11.3.3+ installers add a Push 3
  driver component (`tlsetupfx.exe`, Ableton's kernel USB-driver installer)
  that faults under Wine — expect exactly two such errors; they are cosmetic,
  the installer completes anyway (the same fault appears on Live 12; see the
  `tlsetupfx.exe` comment in `scripts/setup-prefix.sh`).
- Create the prefix with the Live 11 recipe (selects
  `corefonts vcrun2019 gdiplus` + `win10` instead of the Live 12 verbs):

  ```bash
  ABLETON_LIVE_MAJOR=11 ./scripts/setup-prefix.sh
  ```

  The `vcrun2019`/`gdiplus` payloads are not vendored yet, so this first run
  needs network access.
- Install through this Wine (plain wine reads `WINEPREFIX`, not the `ABLETON_*`
  launcher variables):

  ```bash
  WINEPREFIX="$HOME/.wine-ableton" \
    "$HOME/.local/opt/wine-d2d1-nspa-11.11/bin/wine" \
    "/path/to/Ableton Live 11 Suite Installer.exe"
  ```

- With both majors installed, the launcher picks the newest; pin the major (or
  an exact install) explicitly:

  ```bash
  ABLETON_LIVE_MAJOR=11 ableton-live
  ```

- Authorize with your own account. Offline `.auz` activation works as-is —
  the launcher passes file arguments through `wine start "$@"`:
  `ableton-live 'C:\path\to\ableton_live_11.auz'`. Online activation rides the
  `ableton://authorize?...` URI (`desktop/wine-protocol-ableton.desktop.in`);
  if the association is lost:
  `xdg-mime default wine-protocol-ableton.desktop x-scheme-handler/ableton`.
  Never regenerate the prefix casually — authorization binds to its
  `MachineGuid`.
- Max for Live 8 ships with Live 11 and crashes on its *second* start unless
  its preferences file is removed. After Live's first run:

  ```bash
  ./scripts/setup-prefix.sh --post-first-run
  ```

  This moves `maxpreferences.maxpref` aside (timestamped backup, never a
  delete); Max regenerates it on the next start.
- Audio: PipeASIO opens on Live 11 (48 kHz, fixed 256-frame buffers) but issue
  #14 reports distorted output while MME/DirectX works — mechanism unproven.
  If it crackles, raise `PIPEASIO_PREFERRED_BUFFERSIZE=512` per the launcher
  comments and check `scripts/check-live-audio.sh`.

## Caveats

- The crash signature is confirmed from the issue #14 dumps; which exact
  export Live 11 calls is not — run the capture before touching the spec file.
- The two `tlsetupfx.exe` installer errors are expected, not a regression.
- Live's in-app networking can fail under Wine, causing repeated
  re-authorization prompts and failing pack downloads; offline `.auz`
  activation sidesteps it.
