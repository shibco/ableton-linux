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
| `uninstall --keep-prefix` | Removes this project's Linux support while keeping Live and its authorization. |
| `uninstall --delete-prefix` | Removes this project, Live, and its authorization. It keeps your Live Sets. |
| `plan COMMAND` | Checks and shows what another command will do without applying the changes. Replace `COMMAND` with a command such as `update`. |
| `extract DIR` | Unpacks the installer files without installing them. Replace `DIR` with the folder you want to use. |
| `help` | Shows the main command list. |

