# Ableton Wine beta test plan

## Goal

Test one Ableton Wine build across x86-64 Linux systems and record the result.

A build passes on a system only when a tester can:

1. start with an empty Wine prefix at `~/works/plugs/studio`;
2. follow the published instructions without extra commands;
3. install, authorise, and use Ableton Live 12;
4. complete the tests assigned to that machine;
5. produce a complete test report.

An undocumented workaround fails the affected step. Add the fix to the package
or instructions, publish another build, and retest it.

## Systems needed

Cover these system categories:

- Ubuntu or Mint, Fedora, Arch and Debian;
- GNOME and KDE;
- X11 and Wayland with XWayland;
- AMD, Intel and NVIDIA graphics;
- 100%, 125%, 150% and 200% display scaling;
- built-in and external audio devices; and
- at least one MIDI controller.

One machine can cover several categories. Record its distribution, kernel,
desktop, session type, graphics driver, display scale, audio device, and MIDI
devices. A pass applies only to the tested system.

Report NixOS, Sway, Hyprland, COSMIC, and unusual audio setups separately until
each completes the same test set.

## Test rounds

| Round | Description | Done |
| - | - | - |
| Initialisation | Test a numbered build with an empty Wine prefix. | Done |
| Multi-user pilot | Two other people install that build and run the basic tests. | In progress |
| Compatibility test | Cover the systems and devices listed above. | Not started |
| Pre-release test | Repeat the full test set on new and existing Linux systems. | Not started |

Record the value in `VERSION` for every run. Update it before publishing a
changed build.

## Pre-test preparation

- Back up Ableton projects and any existing Wine prefix.
- Use a physical x86-64 Linux machine.
- Use an empty Wine prefix or a new user account.
- Connect the audio, MIDI and display hardware being tested.
- Record `VERSION` before changing anything.
- Keep the system configuration unchanged until the report is saved.

Stop if a result could damage a project, produce unsafe audio output, or expose
private data.

## Tests

Run the automated tests in the [quick start](README.md), then complete the
checks below. Skip a check only when its required software or hardware is
unavailable.

| ID | Check | Pass result |
| --- | --- | --- |
| 01 | Install | Patched Wine and Live install using the published commands. Live opens again after authorisation. |
| 02 | Launch | Live starts from the launcher five times and closes cleanly each time. |
| 03 | Projects | The demo set and a copy of an older set open and play. Edit, undo, redo, save, close and reopen the copy. |
| 04 | Recovery | Force-close Live while using a disposable set. Live recovers the set and the next normal launch works. |
| 05 | Windows | Resize, maximise, restore and use full screen. Menus, text input and plug-in windows remain usable. |
| 06 | Files | Open, Save As, folder selection, Cancel and audio export all work. Reopen the exported file. |
| 07 | Plug-ins | Scan the agreed VST3 plug-ins, open their windows, save a set containing them and reopen it. |
| 08 | Max for Live | Open the agreed devices, change settings, save the set and reopen it. |
| 09 | Audio | Select PipeASIO, play for ten minutes at 48 kHz and 256 frames, then record and play audio. |
| 10 | MIDI | Test notes, controls and output. Unplug and reconnect the controller while Live is open. |
| 11 | Stability | Use the demo set, plug-ins and controls for 30 minutes without a crash, hang or lost device. |
| 12 | Update | Install a newer build, restore the previous build with its installer, then remove and reinstall the newer package. The Wine prefix and Live settings remain. |
| 13 | Report | The session report names the build and system, records the results, and contains none of the data excluded by the privacy rules. |

### Update test

Keep the previous and newer installer files. Replace `OLD.run` and `NEW.run`
with their paths:

```bash
sh NEW.run --update --no-link
sh OLD.run --update --no-link
sh NEW.run --uninstall
sh NEW.run --no-launch --no-link
```

The first two commands install the newer package and restore the previous one.
The uninstaller keeps the Wine prefix. The final command reinstalls the newer
package without starting Ableton's installer.

The installer remembers `--no-link`. To configure Ableton Link after this
sequence, run the installer again with `--link`.

### Audio tests

Run every audio test at 48 kHz and 256 frames. On suitable machines, also cover
44.1, 48, and 96 kHz at 128, 256, and 512 frames.

The collector takes one host-audio snapshot before installation. It includes
device and channel data, the PipeWire rate and quantum, and current `pw-top`
counters. During test 09, record Live's selected rate, buffer, PipeASIO
channels, and the change in `pw-top` ERR.

Where available, test at least one external interface with eight or more
channels. Keep monitoring at a safe level during reconnection tests.

Slow hardware may glitch at demanding settings. A crash, hang, lost device, or
wrong channel order is a failure.

## Results and issues

The test runner records these results:

| Term | Meaning |
| --- | --- |
| `PASS` | The check passed. |
| `FAIL` | The check failed. |
| `WARN` | The check needs attention but did not fail. |
| `REVIEW` | A person must decide the result. |
| `SKIP` | A requirement or confirmation was missing, so the check did not run. |
| `INFO` | The check recorded data without a pass or fail result. |

The script saves reports locally. Review each report, then file issues by hand.
See the [tester kit reference](tester-kit/README.md).

Include these details in each issue:

- `VERSION`;
- test ID;
- tested system details;
- steps that reproduce the problem;
- expected and actual result;
- whether it happens every time;
- the reviewed session report or the smallest useful log.

Review every report before sharing it. Do not post Ableton installers,
authorisation files, projects, samples, recordings, account details, or plugin
credentials.

## Release check

A build is ready when:

- a fresh install passes on each system listed in the release notes;
- install, launch, save, audio, reporting, update and removal all pass;
- each reported failure is fixed and retested, or stated plainly in the release notes;
- the release notes list the exact tested systems and devices; and
- the published files are the same files that were tested.

Questions: [cade@parare.al](mailto:cade@parare.al)
