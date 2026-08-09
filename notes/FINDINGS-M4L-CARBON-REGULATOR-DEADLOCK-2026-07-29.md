# Max for Live devices hang Live on load (2026-07-29)

Dragging certain Max for Live devices into a set freezes Live permanently:
window black and unresponsive, audio still playing, process alive. It is 100%
reproducible, needs no project content, and reproduces on an unrelated Wine
build, so nothing in this fork's patch stack causes it.

The device is not the variable. Two racks that share no Max device whatsoever
hang on the identical MaxPlug wait. What they have in common is that each
contains a device requesting a typeface the prefix cannot resolve.

## Cause

Max devices are authored on macOS and name faces that do not exist here —
Geneva, Menlo, Lucida Grande, Helvetica Neue — plus Consolas. On Windows this
never surfaces, because GDI's font mapper never fails: `CreateFontIndirect`
always returns *some* face, silently substituting, and Max never learns the
font was missing.

Under Wine the lookup honestly reports failure, so Max walks its own hardcoded
fallback chain. `strings MaxPlug.dll` shows where that chain ends:

```text
Bitstream Vera Serif
Bitstream Vera Sans Mono
Bitstream Vera Sans
```

Bitstream Vera is a 2003-era family shipped by neither Wine nor Live, and
modern distros carry its successor DejaVu instead — so the last resort is
absent on essentially every current Linux system. With the chain exhausted,
MaxPlug's font resolution parks Live's UI thread on a condition variable and
never signals it.

The deadlock needs **both** the requested face and the terminal fallback to be
missing. That is why installing Bitstream Vera fixes it while Geneva stays
missing: the primary lookup still fails, but the chain now lands.

So the defect is Max's. Wine's only contribution is reporting the failure
accurately where Windows papers over it — which is why no Wine patch was ever
going to fix it, and why it reproduced identically on an unrelated build.

## Evidence

The UI thread is parked, not spinning. Offsets resolved against the matching
build's PE exports under
`$(works runtime path)/lib/wine/x86_64-windows/`; every hit landed
at `+0x14` into a syscall stub or within a few hundred bytes of an export, so
resolution is exact:

```text
0  ntdll       ZwWaitForAlertByThreadId +0x14
1  ntdll       RtlWaitOnAddress +0x16d
2  ntdll       RtlSleepConditionVariableCS +0x36
3  kernelbase  SleepConditionVariableCS +0x2c
4  maxplug     +0x14b619a
```

Two samples ten seconds apart: 89 of Live's 92 threads had byte-identical
stacks, the UI thread among them, and the process's real main thread burned
4585 -> 4585 jiffies, exactly zero. The audio pool keeps working — one thread
sits mid-`cartopol~` under `pfft~` — which is why sound continues while the
window is dead.

Both racks converge on the same wait. Carbon Regulator (Color Limiter, Poli,
Spectral Blur) and Stabbed Bass (Bass, Pitch Hack, Re-Enveloper) share no
device, yet frames 0-18 are byte-identical:

```text
0-3   the SleepConditionVariableCS chain above
4     maxplug +0x14b619a          <- identical offset in both
5-18  maxplug +0x730fd0, +0x700174, +0x71ccb1, +0x7314de, +0x72d37e,
      +0x730ff1, +0x700174, +0x71ccb1, +0x7314de, +0x8508f3,
      +0x1142d6, +0x85093e, +0x72d744, +0x733a2b
```

Above frame 18 they diverge — Carbon Regulator exits through
`jsui`/`mozjs185`/`js.mxe64` and a `WM_NCPAINT` nested inside
`NtUserMoveWindow`; Stabbed Bass exits through `patcher+0xc295` under
`NtUserGetMessage`. Two routes into one deadlock.

It is bit-for-bit deterministic. Captures a week apart, different processes
and load addresses, produced identical module offsets, identical frame depth
and identical frame-pointer values. Both entered from `WM_USER+1` (0x401) on
the UI thread, both with a partner thread blocked in `SendMessageW` ->
`NtUserMessageCall` at the same Ableton call site, and both with Max's
renderer sitting in `dxgi_output_WaitForVBlank`, a Wine semi-stub that only
calls `Sleep(16)` (`dlls/dxgi/output.c:371`).

Before the fix a hung session ends on two errors and then silence; after it,
only the first remains and the session continues:

```text
ERROR: typeface name Geneva with style Regular not found!
NOTE: system has 292 typefaces          <- was 289
```

Carbon Regulator's devices request Consolas and its log showed only the
`Bitstream Vera Sans` error; Stabbed Bass's request Geneva and its log showed
Geneva then `Bitstream Vera Sans`. Different primary face, same terminal
failure.

## Fix

`install_maxplug_fallback_fonts()` in `setup-prefix.sh` installs the vendored
fonts from `vendor/fonts/bitstream-vera/` into the prefix and registers each
face under `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts`. It falls
back to a host install if the kit was trimmed, warns loudly if neither is
available, and is non-fatal throughout so a late failure cannot abort prefix
setup. `make-installer.sh` stages the fonts into the `.run` kit and ships the
licence.

Vendored rather than depending on a host package, deliberately: relying on
`ttf-bitstream-vera` being present recreates this exact bug for anyone who
lacks it. The Bitstream Vera licence permits redistribution of unmodified
files, restricting only reuse of the name on modified versions; the notices
ship alongside.

Repairing the terminal fallback fixes the whole class — any unresolvable font
now degrades to a substituted typeface — rather than chasing individual Mac
fonts that cannot legally be shipped.

Both halves are required, and each was established by testing. Copying the
files in is not enough: Wine's font list is registry-driven, `HKLM\...\Fonts`
already held 733 entries from a scan that had happened, and files added
afterwards were never picked up. With the ten files present but unregistered,
Max still reported 289 typefaces and still hung; after registering, 292 and
Live stayed alive.

## Verification

`scripts/check-m4l-fonts.sh` runs 9 checks: fonts vendored, manifest verifies,
licence present, the vendored files really report the three fallback family
names, `make-installer.sh` stages them, `setup-prefix.sh` installs and
registers, `MaxPlug.dll` still references the same chain, all faces registered
in the prefix, and the chain actually resolves. It skips the prefix-dependent
checks cleanly when there is no prefix.

`tools/fontprobe.c` enumerates families through the same `EnumFontFamiliesEx`
Max uses, so it answers "would Max find this face?" without launching Live:

```text
$ wine tools/fontprobe.exe "Bitstream Vera Sans" Geneva Arial
398 families enumerated
  Bitstream Vera Sans              FOUND
  Geneva                           MISSING
  Arial                            FOUND
```

`tools/m4l-font-audit.py` scans every `.amxd` on the system and reports hang
risk, resolving against fontprobe's output unioned with Max's private bundle.
That union matters: Max loads its own faces (Ableton Sans, Lato) with
`AddFontResourceEx`, so they are visible to Max but to no other process.
Without it the ~60 devices using `Ableton Sans Medium` look broken when they
are fine.

The fix was confirmed end to end by stripping the prefix to zero font files
and zero registry entries, running the shipped function, and getting 10/10
installed, 10/10 registered, all three families `FOUND`, idempotent on re-run
— with the host package removed, so only the vendored path was in play.

## Scope

Seven requested faces are genuinely unresolvable: Geneva, Menlo, Consolas,
Lucida Grande, Helvetica, Helvetica Neue Bold and Helvetica Neue UltraLight.
Across 235 distinct devices on this install, 13 are affected, and at rack
level 57 of 365.

`Lato` and `Ableton Sans Medium`/`Book` look alarming in the patch files but
are red herrings: Max bundles 18 Lato files and Live ships 28 Ableton Sans
files, all loaded at runtime.

Within Creative Extensions, three of the eight devices are affected — `Poli`
(Consolas), `Bass` and `Re-Enveloper` (Geneva) — giving 40 of 61 racks
affected, 21 safe. `Color Limiter`, `Spectral Blur`, `Gated Delay`, `Pitch
Hack` and `Melodic Steps` request nothing missing.

The trigger is not these particular fonts but any face a device requests that
the prefix cannot resolve, so other installs show different numbers and the
same failure.

## Rejected approaches

`FontSubstitutes` registry aliases. The obvious fix, needing no new files
since DejaVu is Bitstream Vera's metric-compatible successor. Six aliases were
written and confirmed live, then the host package removed so they had to carry
the load. Live hung identically — 67 frames, stack byte-identical across ten
seconds, main thread 886 -> 886 jiffies — and Max still logged both names
missing, including `Geneva`, which had a direct alias. Substitutes only
redirect `CreateFontIndirect`; they never enter `EnumFontFamilies` output,
which is what Max matches against. This also explains why `Helvetica` counts
as missing for Max despite Wine's stock `Helvetica -> Arial` substitute.

Pointing a registry entry at a different file. Naming an entry `"Bitstream
Vera Sans (TrueType)"` but aiming it at DejaVu does not work: Wine reads the
family name from inside the file. Verified with a throwaway `"ZZTestFamily"`
entry aimed at `arial.ttf`, which never enumerated.

A runaway loop. An earlier reading had ~30 AudioCalc threads spinning and a
3-address cycle repeating eight times. Both were wrong. The AudioCalc CPU is
audio still playing; the repeating frames are a bounded recursive descent
whose stack addresses step by a constant `0x180`, ordinary for a nested
patcher walk. Killed by measuring per-thread CPU.

Color Limiter's `jsui` meter. The device-to-module mapping is real —
`jsui.mxe64` comes only from Color Limiter, `js.mxe64` only from Poli,
`pfft~`/`cartopol~` only from Spectral Blur — and `grmeter.js` does drive
`mgraphics.redraw()` continuously into the paint path. But Stabbed Bass shares
none of those and hangs identically, with zero `jsui`/`mozjs`/`pfft~` frames
on its stack. Killed by a differential test, not by more analysis of the same
capture.

## Limits

Typography for the affected devices is now approximate rather than intended:
the primary lookup still fails and Max renders in the fallback. Fixing that
properly needs the real macOS faces, which are not ours to distribute.

Max's underlying defect is untouched. A fallback chain that dead-ends into a
deadlock instead of degrading is Cycling '74's bug; this removes the trigger,
not the flaw. That is what `check-m4l-fonts.sh` guards — it exits 1 if the
chain is ever broken again, including if a future Max release changes the
hardcoded fallback names.

Identifying the UI thread by name does not work here: Ableton names 46
separate threads `MainThread`, and the busy one is a background worker. Use
the lowest Linux tid, or the deepest stack. Reading it by name is what
produced the wrong runaway-loop conclusion.

`setup-prefix.sh` calls `wineserver -w`, which blocks while any wine process
is alive, so it must not run with Live open.

## Artifacts

Captures are gitignored and not committed. Regenerate with
`tools/m4l-hang-capture.sh`, which takes the paired stack and per-thread CPU
samples that distinguish parked from spinning.
