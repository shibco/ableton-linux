# Max 9 on our Wine stack: stability findings

Date: 2026-08-05. Status: first test day complete. Some tests wait for Theo, see "Next steps".

## What this document is

Max 9 is a music programming tool from Cycling '74. Theo has Max 9.1.4 installed in the same Wine prefix as Ableton Live. This document lists the results of our checks and tests. It also lists the fixes we made and the fixes we recommend. A short word list is at the end.

## Summary

The good news: Max 9 starts, shows its windows correctly, and makes sound. The text is sharp. The patcher editor draws correctly. 3D graphics, video playback, gen~ code generation, and Node for Max all work. Audio through PipeASIO works when you select it.

The problems: web content inside Max showed as an empty area. We found the cause and made a fix. Max starts with the slow audio path, not with PipeASIO. Max does not stop fully when you close it. Two known problems from other users still need a short manual test by Theo.

We updated the Max launcher in this work folder (worktree performance-moonshot-m4l-stability). The changes are listed below. They are not installed yet.

## Check 1: the desktop launcher is safe

Task: make sure that the Max 9 launcher does not change the Wine prefix when it does not need to.

Result: the launcher is safe. The launcher file on this machine is identical to the copy in the repository. It uses the same Wine build as the Ableton Live launcher. Because both launchers use one Wine build, a Max start does not cause a prefix update. The launcher also blocks the Wine components for .NET and web pages that Max does not need. The launcher only reads the prefix. It does not write to it.

We found one risk near the launcher, not in it. In July, Wine created four menu entries for Max file types. These entries open files with the system Wine, not with our patched Wine. The system Wine is a different version. If one of these entries runs, the system Wine writes version data into the shared prefix. One entry also claimed all files of the general binary type, and one claimed all .json files. A double click on the wrong file could start it by accident.

Fix, done today: we removed the four entries and refreshed the desktop database. A backup is in `~/.local/state/ableton-wine/removed-handlers-20260805/`. We also added a guard to the launcher in the worktree. The guard removes such entries again if they come back. The correct Max URL handler stays; it points at our launcher.

## Check 2: how we tested Max

We could not send mouse clicks or key presses to Max from the outside. The X test path does not reach Wine windows on this desktop. The Wine-internal mouse path also fails, because the Wayland display does not let a program move the pointer. Key presses from inside the prefix do work (the liveinject tool), but they go to the window that has focus. Theo used the computer during the tests, so we did not send key presses.

So we used a different method. Max can run commands from a patch file when the patch opens. We wrote small patch files that run one test each and write the result into the Max log file. We then read the log file and take screenshots. This method works well and needs no input. The test patches are saved in `tools/max-harness/` in the worktree, with a README.

## Check 3: what works

- Max 9.1.4 starts in about 12 seconds.
- The Max Console and the patcher windows draw correctly. Text is sharp.
- A second start of Max sends the file to the first Max. This is correct behavior.
- The audio engine starts on command.
- PipeASIO works. We switched Max to PipeASIO while it ran. The audio engine connected at buffer size 256 at 48000 Hz.
- 3D graphics work. The jit.world test drew a moving scene at full window size. The log reports OpenGL 4.6 with the Mesa driver.
- Video playback works. Two movie files played at the same time, mixed by a small GPU program. The video engine is VIDDLL. It is built on FFmpeg and does not need the Windows media system that Wine lacks.
- gen~ works. gen~ builds machine code inside Max when a patch loads. A torture patch with 64 gen~ objects loaded with no errors.
- Node for Max works. The bundled Windows Node.js starts, and a test message went to a script and came back correctly.
- Many-channel audio objects (mc) and a dense scope patch loaded with no errors.
- Max reaches the internet. It found the 9.1.5 update.

## Check 4: problems we found on this machine

### Problem 1: web content inside Max shows as an empty area. Fixed in the worktree.

Max uses a built-in web browser component (CEF) for several features: the welcome window, the documentation, the package manager, sign-in, and the jweb object in patches. In our test, a patch with a web view showed only an empty area. The browser processes ran, but the picture never reached the window.

The fix: start Max with two extra options:

    Max.exe --disable-gpu --disable-gpu-compositing

With these options, the web view draws correctly. We loaded a test web page and it was sharp and complete. The options tell the browser component to draw with the processor, not with the graphics card. This is the same type of fix that we use for the Learn View in Ableton Live. We also confirmed that the fix does not harm the 3D graphics or the video playback; they ran in the same session.

Status: the launcher in the worktree now adds these options at each start. The variable ABLETON_MAX_CEF=gpu turns the fix off for comparison tests.

### Problem 2: Max does not use PipeASIO when it starts

Fresh Max uses the old, slow Windows audio path (MME). Our fast path is PipeASIO. Max does not select it.

Cause: Max and the Max for Live editor share one audio settings file. When you use Max for Live, it writes the driver name "Live" into that file. That driver only exists inside Ableton Live. When Max starts alone, it cannot find a driver with that name. It then falls back to the slow path.

Result for the user: more delay between action and sound, and more processor load. The user can select "PipeASIO Driver" in the Audio Status window by hand. Our test shows that this works.

Open question: does a hand selection stay after a restart? Our test could not answer this, because we had to force Max to stop (Problem 3). The next clean session should select PipeASIO, quit Max normally, and check the settings file.

Recommendation: make standalone Max select PipeASIO without user action. The correct method needs a design decision, because the settings file is shared with Max for Live.

### Problem 3: Max does not stop fully. Seen two times.

We closed Max in the normal way, two times in this session. All windows closed. But the Max process stayed alive both times. The browser helper processes also stayed alive. We had to force them to stop.

A process that stays alive can block the next start of Max. It can also hold the audio device. The browser component is the first suspect, because this problem class is known for it. A useful next test: close Max with the browser fix active and with the browser component fully off (Max has a start option --nocef for that), and compare.

### Problem 4: an error message at each start. Cause found.

At each start, Max writes this error: "Thrift: TPipe::open ::CreateFile errored, errno = 2". We found the source. It is the copy-protection layer (PACE) inside Max. At start, it tries to reach a Windows license service. That service does not exist under Wine, so the connection fails. Max then continues with its stored license data. Max works normally.

Why this still matters: sign-in and license renewal are the top reported blockers for Max 9 on Wine (see Check 5). Our license data is valid now, but Max asks for a renewal at intervals (180 days for a normal license, 30 days for a subscription). When that day comes, this area is the risk point. The web view fix (Problem 1) helps, because the sign-in window is a web view.

### Problem 5: a warning from node.script at each start

At each start, the console shows: "Trying to set the process_id for a child process, but it already has one". Node for Max continues normally. Low priority.

### Problem 6: one font is missing

The log shows: "typeface name Lucida Sans with style Bold not found". Windows has this font, our prefix does not. Max uses a replacement font. We saw no bad text in our screenshots. Low priority.

### Problem 7: Max crashed before, causes unknown

Max wrote a crash dump file on July 3. The log from August 1 also shows that that session ended in a crash. In the August 1 session, an error repeated two times per second for minutes: "get: no valid object set". We do not know the causes yet. The dump file is kept: `AppData/Roaming/Cycling '74/Logs/Max-2026-07-03_13-33-44-6cc4519e5c9.dmp` in the prefix.

### Problem 8: MIDI input ports do not open

With no MIDI hardware connected, Max tried to open the two PipeWire system MIDI ports and failed both times: "midi_mme: error 3". These system ports are not normal instrument ports, so this failure alone proves little. We must repeat the test with a real controller connected before Max starts. Also, under Wine the MIDI port list is fixed at start: a device connected later stays invisible. That matches the moonshot device hotplug work (P12). Max is a good second test program for it.

### Problem 9: the Max log file lost its content one time

During the video test, the Max log file went to size zero while Max ran, and then filled again. Our test method reads this log, so we note it. Cause unknown. One time only. Low priority.

## Check 5: problems that other users report

We collected reports from other users who run Max on Wine. Sources and details are in MAX9-STABILITY-2026-08-05-RESEARCH-SOURCES.md. For each report, our local status:

- Sign-in and license activation fail. The most common Max 9 blocker. Related to our Problems 1 and 4. Our web view fix probably helps. A real test needs Theo's account and a quiet moment.
- Typing a new object name goes wrong. When the suggestion list opens, it takes the keyboard focus and accepts the wrong entry. Reported on many desktops. No known solution for the GNOME desktop. Not testable from the outside. A 30-second manual test by Theo settles it: press "n" in a patcher, type "cycle~" slowly, and check that the text stays correct.
- Clicks on menu objects (umenu) crashed Max 7 every time. One Max 9 report says the problem is back. Our click test patch is ready (tools/max-harness/t11-umenu-click.maxpat), but the click itself must come from a person or from a quiet automated session.
- The Max 9 installer stops for a long time at "calculating disk space". Known workarounds exist. Only matters for new installs.
- On some computers the whole Max window turns black or freezes. We did not see this on this machine.
- The camera object (jit.grab) freezes on the second open. Not tested, needs a camera.
- The hid object (game controllers) crashed Max in old reports. Not tested yet.
- A Max for Live device that contains a web view crashes Live while a set loads. Reported with full repeat rate on Windows and macOS. Our prefix runs both programs, so we must test this exact case in a quiet session.

## Test coverage

| Test | Area | Result |
|---|---|---|
| t01 | audio engine start, driver list | pass, slow path selected (Problem 2) |
| t02 | switch to PipeASIO while running | pass, 256 at 48000 |
| t03 | web view (CEF) | fail, then pass with the fix (Problem 1) |
| help patch | patcher drawing, fonts | pass |
| t04 | 3D graphics (jit.world, jit.mo) | pass, OpenGL 4.6 |
| t05 | video playback (VIDDLL, two movies) | pass |
| t06 | Node for Max round trip | pass |
| gen | gen~ code generation, 64 objects | pass, no errors |
| mc | many-channel objects | load pass, sound test open |
| ui | dense scope patch | load pass |
| t09 | MIDI port list | ports fail to open (Problem 8), needs hardware |
| t11 | menu object click | ready, needs a quiet session or Theo |
| manual | sign-in, typing test | needs Theo |

## What changed on the machine today

1. Four stale Wine menu entries removed, backup kept (Check 1).
2. Nothing else. The launcher changes are only in the worktree, not installed. The Wine prefix itself was not changed by us; Max wrote its normal settings and log files while it ran.

## Next steps

1. Install the updated launcher after review, or build it into the next release.
2. Theo, three short manual tests when convenient:
   - Sign-in: open Help, then User Account, and sign in. Report any error text.
   - Typing: press "n" in a patcher, type "cycle~" slowly, press enter. Wrong object = the known suggestion-list problem.
   - Menu click: open tools/max-harness/t11-umenu-click.maxpat, click the menu that shows "alpha", select "gamma". A crash = the known menu problem.
3. Quiet-session automated tests, in order: PipeASIO selection with a clean quit (Problem 2); stop behavior with and without --nocef (Problem 3); MIDI with a controller connected (Problem 8); the Max for Live web view set-load crash; H.264 video file decode; idle processor load measurement.
4. Design the PipeASIO default method (Problem 2 recommendation).
5. Analyze the July 3 crash dump (Problem 7).

## Word list

- Prefix: the folder where Wine keeps a Windows-like system for one program set.
- CEF: the built-in web browser component inside Max.
- PACE: the copy-protection and license layer inside Max.
- PipeASIO: our audio driver. It connects Windows programs to the Linux sound system with low delay.
- MME: the oldest Windows audio path. High delay.
- jweb: the Max object that shows a web page inside a patch.
- Node for Max: a part of Max that runs JavaScript programs.
- gen~: a Max feature that builds fast machine code from a patch.
- DSP: the audio engine of Max.
- Patch: a Max document.
- Worktree: a separate working copy of the repository for one line of work.
