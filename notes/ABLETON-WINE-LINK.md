# Configure and test Ableton Link

The installer stores one Link mode for installation, launch, update, and the
`link disable` command.

## Select a mode

```bash
sh install-ableton-latest.run link enable --mode=session
sh install-ableton-latest.run link enable --mode=always
sh install-ableton-latest.run link disable
sh install-ableton-latest.run link status
```

- `off` disables the project peer and removes only Link state added here.
- `session` starts the peer with Live or Max. It exits after the session ends
  and the idle period expires.
- `always` enables the systemd user service and starts the peer after login.

`install` and `update` also accept `--link=off|session|always`. An update keeps
the saved mode unless another is supplied. From a checkout, replace the `.run`
path with `./scripts/installer.sh`.

## Host changes

Enabling Link can remove the obsolete NetworkManager hook and multicast route
from early releases, open UDP 20808 in UFW or firewalld, and write a marked
systemd user unit. The installer records its own firewall change. The
`link disable` command removes that change. Run `link disable` before uninstall
when Link opened a firewall port or enabled the user service.

Session mode keeps the user unit disabled. Always mode enables and starts it.
Installer transactions save the previous firewall, unit, process, file, and
mode state so a later failure can restore it.

## Native peer commands

The installed files are under `~/.local/share/ableton-wine/`. The daemon
supports:

- no arguments: foreground operation
- `--probe [seconds]`: wait for another peer and report peer count and tempo
- `--tempo BPM`: choose the starting tempo for a new session
- `--linger SECONDS`: exit after an idle period; `0` stays running
- `--verbose`: print periodic state as well as changes

The launchers use `ableton-linkctl` to start the daemon. Session mode defaults
to a 900-second idle period. Always mode runs `--linger 0` through the user
service.

## Verify discovery

Check the saved mode and process state:

```bash
sh install-ableton-latest.run link status
```

Start a native peer and probe it:

```bash
"$HOME/.local/share/ableton-wine/ableton-linkctl" start
"$HOME/.local/share/ableton-wine/ableton-linkd" --probe 10
```

A peer count of one or more confirms that two native SDK instances joined. It
does not confirm that Live joined.

From a checkout, test Wine's multicast path:

```bash
env WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" tools/linkprobe.exe
```

`LINKPROBE TX OK` and `LINKPROBE RX-LOOPBACK OK` cover the local path.
`LINKPROBE RX-NETWORK OK` requires another computer on the LAN.

In Live, enable Show Link Toggle and then Link. Confirm peer count, tempo and
transport changes from both peers, beat and phase, and rejoining after a Live
restart.

Discovery uses UDP multicast at `224.76.78.75:20808`; peers then exchange
unicast UDP on temporary ports. Guest Wi-Fi, public networks, and access-point
client isolation often block discovery. A VPN does not extend Link to another
LAN.
