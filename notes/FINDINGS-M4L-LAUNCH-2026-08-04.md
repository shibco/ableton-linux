# FINDINGS: Max for Live load path and launch cost

This note records how Live 12 loads the Max for Live runtime under this fork,
measures where the launch time is spent, and lists the changes that would
reduce it.

Date: 2026-08-04. Branch: performance-moonshot-m4l (worktree, off main 0f47045).
Environment: Live 12.4.3, bundled Max 9.1.4 (6cc4519e5c9), runtime 2026.08.01.1
(wine-d2d1-nspa-11.13), production prefix ~/.wine-ableton, AMD host, 3482 host
font files (counted with fc-list). "Warm" below means the files were already in
the Linux page cache; "cold session" means a freshly started wineserver, the
single server process that holds a Wine session's shared state.

Evidence: four traced Live launches on this machine (WINEDEBUG
+timestamp,+process,+loaddll; one run additionally +font), the phase log that
MaxPlug writes with microsecond timestamps, Live's Log.txt, PE import and
string analysis of the bundled Max tree, and a cold/warm-session comparison
with a minimal font probe. The raw logs and the tooling are archived in
~/Projects/Code/ableton/m4l-trace-20260804/. External claims cite their source
inline.

## 1. Summary

1. Max for Live runs inside Live's process. Live loads
   `Resources/Max/resources/support/MaxPlug.dll` (33 MB; it has the same
   import table as Max.exe and exports the Max C API plus the host hooks
   mfl_init, mfl_idle, mfl_exit) into its own address space. Live starts
   `Max.exe` only for the "Edit in Max" command; Max.exe accepts an `--mfl`
   flag for that mode. Audio, MIDI, UI, and automation data stay inside
   Live's process. No inter-process channel exists between Live and a Max
   process, so there is no IPC layer to optimise.
2. Live boots the Max runtime on every launch, including launches of sets
   that contain no M4L device. Verified with such a set: `End
   InitApplication` 22:49:38.083, MaxPlug init 22:49:38.098 to 22:49:39.07,
   `Live App: End Init` 22:49:39.073. Live waits for MaxPlug init before it
   reports `End Init`. Live 10's release notes document this design: "Max for
   Live is now loaded at the startup of Live instead of when the first Max
   device is opened". Every Live launch on this fork therefore includes this
   cost, with or without M4L devices in the set.
3. The MaxPlug init window measured 0.96 to 0.99 s in three runs today and
   0.58 to 2.47 s across historical MaxPlug logs on the same hardware. One
   function, `patcherview_initjuce()` (initialisation of JUCE, the C++ UI
   framework Max uses for patcher views), takes about 60% of the window: 575,
   617, and 561 ms today. Max search-path and preferences work takes about
   200 ms, extension loading about 70 ms.
4. A separate cost, independent of MaxPlug: the launcher runs `wineserver -k`
   on every launch, so Live is always the first font-using process of a new
   session, and win32u rebuilds its font list inside Live's startup. A
   cold-session first process took about 1.48 s with host fonts visible and
   about 1.18 s with fontconfig emptied, so the host-font scan costs a
   repeatable ~300 ms on every Live launch on this machine. Processes started
   later in the same session pay no measurable extra. win32u stores its font
   list cache in a registry key created with REG_OPTION_VOLATILE, and Wine
   deletes volatile keys when the wineserver session ends, so the cache never
   survives from one launch to the next.
5. The `Thrift: TPipe::open ::CreateFile errored GLE=: errno = 2` line in
   max-firstboot.log comes from PACE/iLok licensing code inside the Max
   binaries. It probes for the PACE daemon's named pipe, which does not exist
   in the prefix, and logs one line per session. It is not Live-to-Max IPC
   and it adds no measurable startup cost.

## 2. Traced load path

Run 1 replicated the production launcher environment and ran `chrt -r 10 wine
"Ableton Live 12 Suite.exe" LinuxDemoInbuiltMax4Live.als` (a set with two
MxDeviceInstrument nodes, both DS Clap) in a fresh session. Wall-clock
timeline:

```
T+0.0   wine invoked (wineserver killed beforehand, as the launcher does)
T+1.5   Live application code runs ("Started: Live 12.4.3"); the first 1.5 s
        is session start-up
T+2.7   Live accepts the command-line document and loads its browser database
T+4.2   PipeASIO opens the audio device
T+4.6   document ExchangeDocument begins
T+4.75  MaxAPI.dll, MaxAudio.dll, patcher.dll, MaxPlug.dll map into Live
T+4.8   MaxPlug init starts (MaxPlug.log 22:29:05.213)
T+5.8   MaxPlug init ends ("Max: Version 9.1.4"), 964 ms
T+5.8-7.1  the set finishes loading; 85 Max external objects (.mxe64 files:
        live.gain~, ubutton, plugout~, ...) map into Live's process; the DS
        devices instantiate inside Live's process
T+7.1   "Live App: End Init"; the window accepts input
T+7.4   Live starts "Ableton AddOns.exe --cid=..." (Log.txt records the
        intent at T+2.7; CreateProcess runs after End Init); it connects at
        T+7.8
T+7.7   Live starts "Ableton Index.exe <temp>.txt"
```

Helper processes: AddOns.exe exited on its own five minutes later ("AddOns:
process stopped") while the DS set stayed open, so in this session the DS
instruments ran without it. The issue 122 note records DS devices hosted in
AddOns.exe during an X11 session. Both observations are recorded as made; the
sessions differ in display server and Live version, and the reason for the
difference is unknown. Index.exe is the browser indexer (250 MB RSS here).
Neither process is on the M4L load path.

MaxPlug phase durations in ms (MaxPlug logs entry and exit for each init
function; the table lists phases over 10 ms), for the three traced runs and
the 17:34 launch found in the standing prefix logs:

| phase | run 1 | +font run | no-M4L run | 17:34 launch |
|---|---|---|---|---|
| jpatcher_api_init total | 589 | 630 | 577 | 1002 |
| of which patcherview_initjuce | 575 | 617 | 561 | 971 |
| path_buildcache | 115 | 102 | 103 | 236 |
| path_initprefs | 98 | 103 | 101 | 156 |
| startup_load(extensions) | 55 | 55 | 53 | 14* |
| path_init | 36 | 31 | 33 | 54 |
| startup_load_one(maxclang.mxe64) | 15 | 15 | 14 | - |
| interface_init | 13 | 14 | 14 | 32 |
| total MaxPlug window | 964 | 995 | 972 | 1668 |

*The 17:34 launch logged startup_load_from_packages as a separate phase.

Standalone Max 9 runs additional startup phases that the in-Live instance
skips: audio driver init 250 ms, sysmidi 158 ms, maxdb_new 141 ms plus an
asynchronous 3 s database rebuild, package extensions 818 ms. In-Live, maxdb
work is near zero: the 95 MB SQLite search-path database
(`Roaming/Cycling '74/Max 9/Database/c--programdata-...-max.x64.maxdb`)
updates asynchronously, and the install ships a 93 MB prebuilt `c74.maxdb` in
`resources/support/`. The database adds no time to Live startup.

CEF (libcef.dll, 231 MB) is the only delay-load import of Max.exe and
MaxPlug.dll, and nothing loads it at startup. The choice between
MaxRT_nocef.exe and MaxRT.exe therefore has no effect on M4L launch. Node
(node.exe, 85 MB) is package content and also stays unloaded at startup.

## 3. Launch cost breakdown

### 3.1 patcherview_initjuce, 56-83% of MaxPlug init

MaxPlug logs no lines between the entry of `patcherview_initjuce()` and the
line "Adding custom fonts from folder ... 35 font files" at its end. Binary
analysis identifies its contents: JUCE initialisation with a GDI-only
typeface layer. MaxPlug imports EnumFontFamiliesExW, CreateFontIndirectW, and
GetTextMetricsW, and imports no dwrite functions. The +font run recorded 80k
get_gdi_font_glyph_metrics, 38k font_SelectFont, and 8k
freetype_set_outline_text_metrics calls across the session, concentrated in
this window: JUCE walks the font family list and queries metrics for each
face, and each query runs freetype code inside Live's process.

The phase is CPU-bound in Live's process, not wineserver-bound: the
wineserver used about 40 ms of CPU during the entire MaxPlug second (warm
run, sampled at 100 Hz).

The same phase takes 511-580 ms in standalone Max on this machine, but took
971 ms and 2030-2055 ms in historical in-Live runs: a 2-3.5x spread on
identical hardware with an identical font set. In-Live, the phase runs while
Live's other startup threads are busy and, under the launcher, while every
Live thread runs SCHED_RR 10 (the Linux round-robin realtime scheduling
class at priority 10; see 3.3). The measurements do not identify the cause of
the spread. Scheduling contention fits the evidence best; font list size does
not, because it is constant across those runs.

### 3.2 Per-launch font list rebuild in win32u, independent of MaxPlug

The mechanism, verified in dlls/win32u/font.c (upstream wine 11.13 contains
identical code; checked against the wine-mirror repository):

- `font_init()` runs once in every process that uses win32u font APIs. It
  always scans `C:\windows\Fonts`, the Wine data directory, and the whole
  host fontconfig set (`load_file_system_fonts()` plus
  `font_funcs->load_fonts()`), and only then consults the cache key
  `HKCU\Software\Wine\Fonts\Cache`. The key is created with
  REG_OPTION_VOLATILE, so it exists only for the lifetime of one wineserver
  session.
- The +font trace shows exactly 4460 fontconfig_add_font calls in each of the
  10+ font-using processes of one session, and 109k unix_face_create calls
  session-wide. The scan repeats in every process even when the session cache
  exists.
- The launcher runs `wineserver -k` on every launch, so Live is always the
  first process of a new session. Live therefore runs the full scan, creates
  the cache, and runs `update_external_font_keys()`, which writes persistent
  HKLM registry entries for 733+ external faces.

Measured with a minimal probe (minifont.exe: forces font_init, runs one
EnumFontFamiliesExA pass, exits; built without a C runtime):

| condition | wall time |
|---|---|
| warm session, host fonts | 335-384 ms |
| warm session, FONTCONFIG_FILE empty | 332-402 ms |
| cold session (first process), host fonts | 1475-1497 ms |
| cold session (first process), FONTCONFIG_FILE empty | 1101-1254 ms |

The ~300 ms cold-session difference is the host-font scan, and Live runs it
on every launch on this machine. The remaining ~1.1 s of the cold run is
session start-up (wineserver, services.exe, winedevice, plugplay, rpcss,
explorer) plus registry font loading. Externally registered fonts persist in
HKLM and reload from their file paths even with fontconfig empty; this is
the same registry mechanism that made the M4L Vera-font deadlock fix require
both the font files and their registry entries.

### 3.3 Scheduling

All 137 of Live's realtime threads, both helper processes, and, in a direct
launch without the launcher, the wineserver itself inherit SCHED_RR 10 from
the launcher's `chrt -r 10 wine`. In the production launcher, the plain
`wine wineboot` starts the wineserver, so the wineserver runs SCHED_OTHER
while every Live thread runs RR 10. FINDINGS-RT-AB-2026-08-02 hypothesises
exactly this inversion as the cause of the measured 6x startup slowdown on
CPU-constrained hosts. The MaxPlug window runs inside that startup phase,
and the 2-3.5x spread of patcherview_initjuce is consistent with the same
cause. This gives moonshot P4 (thread-priority chain, MMCSS/avrt) a
concrete, per-launch, directly measurable target.

### 3.4 Confirmed non-costs

- CEF and Node: delay-loaded or package-only; nothing loads them at startup.
- maxdb: updates asynchronously; a prebuilt copy ships in the install.
- PACE Thrift pipe probe: one failed CreateFile per session.
- Named-pipe IPC between Live and Max: absent in Live 12.

## 4. Proposed changes

The proposals are ordered by expected per-launch saving on this stack. Each
names the measurement that proves or disproves it. Two instruments already
exist and need no new tooling: `max_boot` (the interval from "Started" to
"Max: Version" in Log.txt, parsed by scripts/bench-workload.sh on the
moonshot branch) and the MaxPlug phase log.

### P-M1. Cache the host font list across processes and sessions (patch 0070, implemented)

Implemented 2026-08-04 as
`patches/0070-win32u-cache-the-enumerated-host-font-list-in-the-pr.patch`.

The problem, plainly: every time any program starts under this project's
Wine, Wine reads every font installed on the computer, one file at a
time, to build its font list. This computer has 3,482 font files. The
reading repeats for every program: Live itself, and each helper program
Live starts. Nothing remembered the result between starts.

What the patch does, plainly: Wine now saves the finished font list to
one file, `c:\windows\wine-host-font.cache` (seen from Linux:
`~/.wine-ableton/drive_c/windows/wine-host-font.cache`). At every program
start Wine first checks whether the computer's fonts have changed, using
a stamp: a short summary value computed from the font folders' names,
file sizes, and dates, so any font change changes the stamp. While the
stamp matches the saved file, Wine loads the list from the file and skips
the reading. When the fonts change, or the file is damaged or cut short,
Wine notices, reads everything once, and saves a fresh file. Setting
`WINE_DISABLE_HOST_FONT_CACHE=1` turns the saved list off and restores
the old behaviour; the same switch provided the "without" side of every
measurement below.

Fonts that belong to the Live installation itself (`c:\windows\Fonts` and
Wine's own font folder) never come from the saved list; Wine always reads
those directly, so fonts added by the installer or the launcher always
appear.

For the reader following the code: the save is `save_host_font_cache()`,
the load is `load_host_font_cache()`, the stamp is
`fontconfig_host_fonts_stamp()`, and `font_init()` in
`dlls/win32u/font.c` calls all three. Reading and writing happen under
Wine's existing font lock, so only one program writes at a time. One
save-side rule: a font whose name is too long for the file format stops
the file from being written at all, and every program then reads fonts
as before the patch, so the saved list can never silently miss a font.
Plain Wine behaves the same way this project did before the patch, so
the change is worth offering to the Wine project itself.

Checks on a locally built Wine with the patch, against a scratch copy of
the environment (nothing production was touched):

- The font list programs see is exactly the same with and without the
  saved list: 8,257 entries, compared line by line, no difference.
- With a valid saved file, a starting program does no font reading at
  all: zero calls into the system font reader.
- Changing the computer's fonts, cutting the file short, and overwriting
  the file with garbage were each noticed. Wine fell back to the full
  read and saved a fresh file every time.
- The first program of a fresh Wine session started in 2.7 s with the
  saved list and 3.6 s without (middle value of 7 runs each).
- Every further program started in about 0.15 s with the saved list and
  about 0.33 s without.

Production result, 2026-08-05. The full release build (`./build.sh`)
passed all 93 of its self-checks, including the check that confirms this
patch is present in the built files. The build is installed side by side
at `~/.local/opt/wine-d2d1-nspa-11.13-fontcache-0070`; the copy Live
normally uses is unchanged. We then timed real Live starts on this
machine, launched the normal way, with the saved list on and off. The
table shows the middle value of the repeated runs (5 with, 3 without;
the first run of each kind is left out because the computer was still
reading program files from disk for the first time):

| what is timed | with | without | saving |
|---|---|---|---|
| launch until Live's program is running ("Started: Live" in Live's log) | 1.24 s | 3.08 s | 1.85 s |
| launch until Live is ready to use ("Live App: End Init") | 5.10 s | 7.01 s | 1.91 s |
| the Max for Live loading step ("Started" to "Max: Version") | 3.55 s | 3.52 s | none |

Every Live start on this machine is about 1.9 seconds faster. That is
about six times the 300 ms estimated in section 3.2, for two reasons.
The estimate could only switch off one of the two ways Wine reads fonts,
and the saved list removes both. And a Live start runs several helper
programs besides Live itself; each of them now skips its own font
reading too. The Max for Live loading step did not change; making that
step faster is what proposals P-M3 and P-M4 are about.

The first start with the patch reads everything once and writes the
saved file (973 KB on this machine); every start after that reads it.

Before this ships: agree the merge order with the open branches that
reserved patch numbers 0066 to 0069, release, and a few days of normal
use on this machine first. The entry for users is in TROUBLESHOOTING.md
("A newly installed font does not show up inside Live").

### P-M2. Reuse the wine session across launches (launcher change, no wine patch)

The launcher kills the wineserver on every launch, so every launch repeats
session start-up (measured 1.1-1.5 s before the first process runs) and
deletes the volatile font cache. Keep the session alive when the installed
runtime version is unchanged: compare a runtime version stamp before
killing, or give each runtime its own server socket. This removes the
session start-up time from repeat launches and lets AddOns.exe, Index.exe,
and Max editor starts reuse the warm font cache. This is moonshot item S14;
the measurements above supply its expected saving. Effort: low, launcher
only. Risk: the current unconditional kill exists to prevent a stale server
from an older runtime binding the prefix; the version comparison must cover
that case before the kill is removed. Measurement: the interval from launch
to "Started: Live", plus the minifont probe from section 3.2 warm against
cold.

### P-M3. Attribute patcherview_initjuce, then reduce it (measurement first, then wine patch)

The largest MaxPlug phase (575-617 ms warm today, up to 2 s in historical
runs) logs no internal detail, and its 2-3.5x spread is unexplained. Run two
attribution tests before writing any patch:

a) Compare `ABLETON_RT=off` against the default on max_boot and the MaxPlug
   phase log. If realtime scheduling contention causes the spread, this
   comparison shows it directly, and P4 then also reduces per-launch time.
b) Count NtGdiGetOutlineTextMetrics and NtGdiGetGlyphIndicesW calls inside
   the window with `WINEDEBUG=+font` plus a relay count. The existing +font
   run already shows tens of thousands of per-face metric queries. If the
   JUCE family walk dominates, the wine-side change is a win32u cache of
   gdi_font metrics per font file realization, so that repeated
   CreateFontIndirect/GetTextMetrics cycles reuse computed metrics instead
   of repeating freetype work.

Effort: the attribution tests are one instrumented session; the metric cache
patch is moderate and a candidate for upstream submission. Measurement:
patcherview_initjuce duration in MaxPlug.log.

### P-M4. Narrow realtime scheduling at startup (existing moonshot P4, with new evidence)

P4 already covers the design: implement avrt/MMCSS thread priorities, then
retire whole-process `chrt -r 10 wine`. This note adds the evidence that
MaxPlug init runs inside the startup window that whole-process RR slows 6x
on constrained hosts, with the wineserver at SCHED_OTHER below every RR 10
thread. After P4 lands, re-run the max_boot baselines; the expectation is
that the MaxPlug window shrinks and its spread narrows. The numbers in this
note are the baseline for that comparison.

### P-M5. Read the Max runtime files into the page cache during launch (launcher change)

The first launch after boot reads MaxPlug.dll (33 MB), the MaxAPI, MaxAudio,
and patcher DLLs, 29 startup .mxe64 extensions (including maxclang, 69 MB),
and parts of the 95 MB maxdb, all synchronously inside Live's startup. The
launcher can read the `resources/support` and `resources/extensions/max`
trees in a background job while wineboot runs, so the reads complete before
Live needs the files. This changes nothing when the page cache is warm and
saves real time on hard disks and SD-card class storage; every Linux
computer is the target, including machines with slow storage. Effort:
trivial. Measurement: write to /proc/sys/vm/drop_caches, then compare
max_boot with and without the background read.

### P-M6. Measure the search-path walk before changing it (path_buildcache + path_initprefs, ~200 ms)

These two phases walk the 25k-file bundled Max tree through NT file APIs.
The known moonshot item on case-insensitive path lookup cost (performance
plan section 9) investigates the same cost. Count the file syscalls with a
`+file` trace during the two phases first: a large count points at Wine's
path handling, a small count means the 200 ms is Max-internal work that a
wine patch cannot reduce.

### Rejected directions

- Redirecting Live to MaxRT_nocef.exe or trimming CEF: nothing loads CEF at
  startup, so this changes nothing.
- Asynchronous or deferred MaxPlug boot: Live's own code (IceMax/MxDCore)
  controls the sequencing, a wine patch cannot reorder it, and no Options.txt
  switch for it exists. Checked: no preload or concurrent-device-loading
  option appears in any public source or in the binary's strings;
  `-MaxForLiveDeveloperMode` only restores the editor button.
- Suppressing the PACE pipe probe: it logs one line per session and retries
  were not observed.

## 5. Side observations from the runs

- Closing Live's X window (xdotool windowclose) destroyed all of Live's
  windows but left the 148-thread process running for minutes, and no
  shutdown lines reached Log.txt. SIGTERM was required to end it. A user
  whose window manager triggers the same path sees Live continue running
  with no window. Investigate separately at the event layer (standing rule:
  fix behaviour at the event layer, never hide the close affordance).
- Killing Live with SIGTERM leaves crash-recovery state: CrashDetection.cfg,
  CrashRecoveryInfo.cfg, and a copy of the open set in
  Preferences/BaseFiles. The next launch then loads that copy instead of the
  document given on the command line, without any dialog. This invalidated
  one control run in this session. Any verification recipe that kills Live
  must archive those three paths afterwards. This session archived them
  under `Preferences/_crashrecovery-backup-m4ltrace-20260804/`, following
  the existing `_crashrecovery-backup-*` pattern.
- Live writes "AddOns: start process" to Log.txt 4.7 s before it calls
  CreateProcess. Log.txt alone therefore cannot establish the order of
  process events; the +process trace can.
