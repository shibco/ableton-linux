# Installer commands

This document describes the various functions of the Ableton-Linux installer.

Use the [installation instructions](README.md#installation) for your first
setup. Most people only need `install`, `update`, and one of the two `uninstall`
commands.

Run each command after `sh ~/Downloads/install-ableton-latest.run`. For example:

```bash
sh ~/Downloads/install-ableton-latest.run update
```

| Command | Explanation |
| --- | --- |
| `install --live-installer FILE` | Installs Ableton Live and the Linux support files. Replace `FILE` with the path to your Ableton installation ZIP. |
| `update` | Updates the software that runs Live on Linux, its launchers, and compatibility fixes. It keeps Live, your authorization, your projects, and your current Link choice. |
| `runtime install` | Replaces only the software that runs Live on Linux. |
| `prefix create` | Creates the private Windows-style folder that holds Live and its settings. |
| `prefix update` | Updates the audio support and settings in an existing Live folder. |
| `prefix repair-live11` | Moves incompatible Live 11 Max preferences aside so Max can create clean ones. |
| `link enable --mode=session` | Enables Link while Live or Max is running. |
| `link enable --mode=always` | Starts Link after login and keeps it running. |
| `link disable` | Turns off Link and removes only the Link files and firewall rule this project added. |
| `link status` | Shows whether Link is running and whether this project added a firewall rule. |
| `uninstall --keep-prefix` | Removes recorded Linux files and the Wine runtime. It keeps the Wine prefix, Live, authorization, installer settings, and shared records. |
| `uninstall --delete-prefix` | Removes recorded Linux files, the runtime, prefix, Live, authorization, and valid installer settings. It keeps Live Sets stored outside the prefix. |
| `plan COMMAND` | Validates another command while preserving current files. Install and update plans list their actions. Uninstall plans validate selected paths and report component status. |
| `extract DIR` | Unpacks the installer files without installing them. Replace `DIR` with the folder you want to use. |
| `help` | Shows the main command list. |

If a recorded Linux file or link changed after installation, uninstall asks
whether to remove it. Keep is the default answer.

## Pre-flight choices

Interactive Install, Update, and Reinstall runs ask these questions one at a time.
Press `Esc` to go back one question. Press Enter to accept the shown default
or current value. The launcher preferences are persistent. A nonempty
environment variable takes priority for one launch.

You can pass the same choices to `install` and `update`:

| Option | Values and explanation |
| --- | --- |
| `--audio-buffer=VALUE` | `64`, `128`, `256`, `512`, or `1024` frames. The default is `128`; larger buffers improve stability and add latency. |
| `--shortcuts=VALUE` | `take` assigns conflicting GNOME shortcuts to Live; `preserve` keeps the desktop assignments. The default is `take`. |
| `--dpi=VALUE` | `auto`, `100`, `fractional`, or `preserve`. The default `auto` matches the detected display scale. |
| `--audio-threads=VALUE` | `auto`, `off`, or `1` to `63`. The default `auto` selects a worker count; `off` lets Live decide. |
| `--rt=VALUE` | `auto` uses real-time scheduling when available; `off` uses normal scheduling. The default is `auto`. |
| `--power=VALUE` | `performance`, `balanced`, or `off`. The default `performance` holds that profile during each Live or Max session. |

## Logs and backups

Everything the scripts print outside the installer display, including every
`!!` error, goes to the log named at the end of the run. The log sits next to
the `.run` file, or in your temporary directory when that folder is read-only.

When an ordinary support file already exists, the installer asks whether to
overwrite all files, keep the originals, or abort. The installer selects
Overwrite all after five seconds. It moves each replaced file to a dated folder
under `~/.local/state/ableton-wine/backups/`.

Shared configuration files use saved earlier copies under
`~/.local/state/ableton-wine/install-prestate/`. Uninstall restores these copies
after it removes the installer version.
