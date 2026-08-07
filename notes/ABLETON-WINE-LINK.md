# Ableton Link support

The installer ships the native Link peer `ableton-linkd` and configures
Link during installation. The installer flag `--no-link` skips the setup and
is remembered on later runs; `--link` opts back in. The setup requests `sudo`
to open UDP port 20808 when UFW or firewalld is active, and to remove the
NetworkManager hook that earlier setup versions installed. If the step was
skipped or could not complete, close Live and retry it as your normal user:

```bash
"$HOME/.local/share/ableton-wine/setup-link.sh"
```

From a repository checkout, run:

```bash
./scripts/setup-link.sh
```

## What the setup changes

The script:

1. Opens UDP port 20808 through `ufw` when UFW is enabled, or through
   `firewall-cmd` when firewalld is running. Without an active firewall it
   changes nothing and, if you run another firewall, tells you to allow
   UDP 20808 manually.
2. Removes the NetworkManager dispatcher hook that setup versions 1 and 2
   installed, using `sudo`, and drops the old `224.0.0.0/4` route with it.
   If the removal fails, the script prints the removal command and exits
   without recording the setup as complete, so the next update retries. A
   stale route without the hook is only reported: it is harmless to Link
   and clears on reboot.
3. Copies the user unit to
   `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ableton-linkd.service`
   without enabling it. The launchers start `ableton-linkd` when Live or Max
   starts, and the daemon exits on its own after 15 minutes with no peers,
   so nothing runs while Live is closed. Setup versions 1 to 3 enabled the
   unit, which kept the daemon running from login; the version 5 setup
   disables that once. Enable the unit yourself if you want an always-on
   anchor:

   ```bash
   systemctl --user enable --now ableton-linkd.service
   ```

The script can be repeated and refuses to run while Live is open. If the
daemon or unit file is missing, it keeps the firewall change and reports
that the daemon setup was skipped. It records the setup version only when
the service step completed, so a skipped or unchecked service step is
retried on the next update.

Setup versions 1 and 2 added a `224.0.0.0/4` route on the LAN interface and
a NetworkManager hook to maintain it. Version 3 removed both. The Link SDK
sets `IP_MULTICAST_IF` on every discovery socket, which selects the outgoing
interface directly instead of through a routing-table lookup, so the route
was never consulted for Link traffic. Live under Wine and `ableton-linkd`
both set that option per interface; see the recorded trace in
[ABLETON-WINE-LINK-FIRSTCLASS.md](ABLETON-WINE-LINK-FIRSTCLASS.md).
Version 4 stopped enabling the user unit and made the daemon exit on its
own after a session ends, as described above.

## Components

### `ableton-linkd`

The installer ships `ableton-linkd`, built from the vendored Ableton Link 4.0
SDK, and installs it at:

```text
~/.local/share/ableton-wine/ableton-linkd
```

It joins the Link session as a native peer and holds the shared tempo and
timeline while Live restarts, so a restarted Live rejoins the same beat. It
enables Start Stop Sync but never calls the SDK methods that set tempo or
beat position after construction.

The daemon runs only around a session. After 15 minutes with no peers it
exits on its own. Live counts as a peer while Link is enabled in its
preferences, so the daemon stays up through a Live restart or crash and
stops soon after you finish working. `--linger` changes the wait.

Its modes are:

- No arguments: run in the foreground and log to stderr on peer count,
  tempo, and transport changes. It writes its startup lines and one status
  line, then a quiet session writes nothing more.
- `--daemon`: run in the background and write
  `~/.log/ableton-linkd/ableton-linkd.log`. The launchers use this mode.
- `--probe [seconds]`: join, wait up to ten seconds by default, print
  `peers: N` and `tempo: T.T`, and exit zero after seeing at least one other
  peer.
- `--tempo BPM`: set only the construction tempo used when this process
  creates a new session.
- `--linger SECONDS`: exit after this long with no peers. Whole seconds
  only. The default is 900. `--linger 0` never exits; the systemd unit uses
  it. The `ABLETON_LINKD_LINGER` environment variable sets the same value.
- `--verbose` (or `ABLETON_LINKD_VERBOSE=1`): also write a status line
  every ten seconds. Before 2026.08 this was unconditional. Under the
  systemd unit it wrote 8640 identical journal lines a day. That read as a
  stuck process and invited force quits.

The Live and Max launchers start `ableton-linkd --daemon` when the binary
exists and no process with that name is running. `ABLETON_LINKD` overrides
its path. The user unit runs `--linger 0`; it is installed but stays
disabled unless you enable it for an always-on anchor.

### `linkprobe.exe`

The repository contains `tools/linkprobe.exe`; the `.run` installer does not
install it. The program runs under this Wine and tests `SO_REUSEADDR`, a bind
to `0.0.0.0:20808`, per-interface `IP_ADD_MEMBERSHIP`, multicast transmit,
and receive.

Its exact verdict lines are:

```text
LINKPROBE TX OK
LINKPROBE RX-LOOPBACK OK
LINKPROBE RX-NETWORK OK
LINKPROBE PEERS: N
```

The process exits zero when transmit and loopback receive succeed.
`RX-NETWORK OK` requires a datagram whose source is not one of the local
machine's addresses. The daemon on the same machine is not enough for that
line, even though it can appear in `PEERS`.

`linkprobe.exe` sends discovery datagrams without a session payload. It tests
Wine's multicast socket behavior, not full Ableton Link session membership.

`tools/jacklinkd.c` is unrelated. It restores JACK port links and happens to
register the JACK client name `ableton-linkd`. Current launchers do not start
it.

## Verification

Check the host setup while Live is open, or within 15 minutes of closing
it:

```bash
pgrep -a ableton-linkd
```

With Live closed for longer, an empty result is the expected state: the
daemon has exited. `systemctl --user status ableton-linkd.service` reports
the unit as inactive and disabled unless you enabled the always-on anchor
yourself.

For `ufw`, run `sudo ufw status` and look for `20808/udp`. For firewalld, run
`firewall-cmd --list-ports`.

The setup runs once per version and does not notice a firewall enabled after
it. In that case, allow UDP 20808 yourself or re-run the setup script.

To check that native peers can join each other, start the daemon, then run
the probe against it:

```bash
"$HOME/.local/share/ableton-wine/ableton-linkd" --daemon
"$HOME/.local/share/ableton-wine/ableton-linkd" --probe 10
```

The probe prints `peers: 1` or more and exits zero. The started daemon
exits on its own 15 minutes after the probe finishes. This confirms that
two native SDK instances can join. It does not identify Live as the peer.

From a checkout, test Wine's local multicast socket behavior:

```bash
env WINEPREFIX="$HOME/.wine-ableton" \
  "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" tools/linkprobe.exe
```

Require `LINKPROBE TX OK` and `LINKPROBE RX-LOOPBACK OK`. To require
`LINKPROBE RX-NETWORK OK`, run another Link peer on a second LAN host during
the test.

In Live, open Preferences, select Link, Tempo & MIDI, enable Show Link
Toggle, then enable Link in the control bar. Confirm that its peer count is
at least one. Change tempo from each peer in turn, check beat and phase
alignment, and restart Live. Confirm that the restarted Live instance rejoins
the same tempo and phase.

For packet-level checks:

```bash
sudo tcpdump -i <interface> -n udp port 20808
```

Discovery uses `224.76.78.75:20808`. The Wireshark filter
`ip.dst == 224.76.78.75 || ip.dst == 224.0.0.22` also includes IGMPv3
membership reports.

If a known remote peer is active but neither the native probe nor tcpdump
sees it, check the firewall, the access point (many block or filter
multicast), and that both hosts sit on the same LAN segment. If native tools
see the remote peer but Live does not, compare the linkprobe verdicts and
packet capture before treating the result as a Wine socket fault.

## Protocol and scope

Ableton Link discovers peers with UDP multicast on
`224.76.78.75:20808`. Pairwise timeline measurements use unicast UDP on
ephemeral ports. Host connection tracking covers replies to those outbound
exchanges, so the setup opens only UDP 20808.

Peers must share a LAN that carries multicast. Native Linux applications
with Ableton Link support join the session directly. JACK-only applications
may use the separate upstream
[`jack_link`](https://github.com/rncbc/jack_link) project.

PipeASIO has no JACK transport layer. The native peer therefore
cannot synchronize Live through JACK. Live joins the Link session as its own
Wine peer and follows the shared timeline itself.

Ableton Link is Ableton's technology. This project follows its naming and
enablement guidelines and is not affiliated with or endorsed by Ableton.
