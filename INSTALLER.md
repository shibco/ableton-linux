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

## What you see

The installer draws one tree. The top box names the version. The system check lists your machine, the free disk space, and any host warnings. The action menu offers `[U]pdate`, `[R]einstall`, `Remo[v]e Ableton Linux`, and `E[x]it`. The default option shows `(or press Enter)`.

Each step is a numbered box such as `3/8 INSTALL THE WINE RUNTIME`. Its operations hang below it. The running operation shows a spinner and reads `└─`. When the next operation starts, the previous one changes to `├─` with a `✓`, or with a `𐄂` after a failure. Questions appear in the same place. Each question marks its default and takes it after 5 seconds. The footer box shows the time taken, the warning and error counts, and the runtime and prefix paths. The launch command and the support links follow the footer.

Every sentence on screen comes from the dictionary at the top of `scripts/lib/ui.sh`. Change the text there.

Everything the scripts print outside the tree, including every `!!` error, goes to the log named at the end of the run. The log sits next to the `.run` file. When that folder is read-only, the log goes to your temporary directory instead. After a failure the footer lists the errors from that log.

When the installer finds files from an earlier installation it asks once: `[O]verwrite all` (the default, also after 5 seconds), `[K]eep originals`, or `[A]bort`. The installer moves each overwritten file to a dated folder under `~/.local/state/ableton-wine/backups/` before it writes the new file.
