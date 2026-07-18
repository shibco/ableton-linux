# Ableton Link support

## Background

Link is a peer-to-peer, masterless tempo/beat/phase sync protocol: peers
exchange UDP multicast on group 224.76.78.75 (".76.78.75" spells "LNK"),
port 20808, and converge on a shared timeline. Wine forwards WinSock2
multicast to host sockets, so whether Live joins a session is decided
entirely on the host: the kernel route for 224.0.0.0/4, the firewall, and
Wine's socket translation. No Wine patch or registry change is involved, and
no confirmed report exists of Link working directly from Wine — treat Live's
direct membership as plausible, not proven.

## Constraints

- Link does not work over VPN: the multicast route must point at the
  physical LAN interface, never a tunnel. setup-link.sh refuses VPN
  carriers.
- The router must forward multicast; many do not.
- UDP 20808 must pass the host firewall.
- Bluetooth links are unsupported (Ableton's own requirement).

## Setup

[../scripts/setup-link.sh](../scripts/setup-link.sh) — optional, idempotent,
refuses to run while Live is up:

1. detects the primary LAN interface (carrier of the default route),
   refusing VPN carriers (tun*/wg*/tap*);
2. Option A: `ip route append 224.0.0.0/4 dev <iface> metric 0`, then
   `ufw allow 20808/udp`, or `firewall-cmd --permanent
   --add-port=20808/udp` + reload on firewalld systems;
3. Option B: enables the `jack-link.service` user unit for the
   [jack_link](https://github.com/rncbc/jack_link) bridge. A missing binary
   or unit exits early with a pointer here — the script never builds
   software.

The route does not survive reconnects. Persist it with a NetworkManager
dispatcher hook, `/etc/NetworkManager/dispatcher.d/50-link-multicast`
(chmod 755):

    #!/bin/sh
    [ "$2" = "up" ] || exit 0
    ip route append 224.0.0.0/4 dev "$1" metric 0 2>/dev/null || true

Option B bridge install (deliberately not scripted): the distro's JACK
compatibility layer (`pipewire-jack`, or
`pipewire-jack-audio-connection-kit` on Fedora), then

    git clone --recurse-submodules https://github.com/rncbc/jack_link
    cd jack_link && make
    sudo install -m755 jack_link /usr/local/bin/

(the submodule checkout is required — it vendors Ableton's Link library),
and the user unit `~/.config/systemd/user/jack-link.service`:

    [Unit]
    Description=jack_link — Ableton Link to JACK transport bridge
    After=pipewire.service wireplumber.service

    [Service]
    ExecStart=/usr/bin/pw-jack /usr/local/bin/jack_link
    Restart=on-failure
    RestartSec=2

    [Install]
    WantedBy=default.target

The launcher also starts the bridge when jack_link is installed but not
already running (`pw-jack jack_link --daemon`, logs to `~/.log/jack_link/`),
so the session is anchored on every Live start even without the unit.

## Verification

- [ ] `ip route show 224.0.0.0/4` lists the route via the physical LAN
  interface, not a VPN device
- [ ] `sudo ufw status | grep 20808` or `firewall-cmd --list-ports` shows
  `20808/udp`
- [ ] `sudo tcpdump -i <iface> -n udp port 20808` shows datagrams to
  `224.76.78.75.20808` once any peer is active
- [ ] Wireshark filter `ip.dst == 224.76.78.75 || ip.dst == 224.0.0.22`
  shows timeline packets and IGMPv3 membership reports
- [ ] `pgrep -a jack_link` shows the bridge running, and `~/.log/jack_link/`
  records session activity
- [ ] [LinkCLIHost](https://github.com/mivertowski/LinkCLIHost)'s TUI lists
  the expected peers (bridge, Live, other LAN devices) and the shared tempo
- [ ] Live's Control-Bar Link indicator (Preferences → Link/Tempo/MIDI →
  "Show Link Toggle") is enabled and reports a peer count ≥ 1
- [ ] a tempo change on any peer propagates to all others; a peer leaving
  drops the count cleanly

Triage: no packets in step three means host networking (route, firewall, or
a non-multicast router). Packets present but a zero peer count in Live means
Wine's multicast receive path is failing; the bridge still anchors and
monitors the session while Live's direct membership stays an open question.

## Caveats

- Option A is unverified end-to-end under this Wine build; the bridge is
  the anchor, direct membership the experiment.
- The bridge cannot set Live's tempo by itself: PipeASIO is a native
  PipeWire client with no JACK layer, so there is no transport slaving
  (WineASIO had one; removed with the PipeASIO switch). Live must join the
  session as its own peer via the Option A networking.
- pw-jack clients run at the PipeWire graph quantum (48 kHz / 256 frames by
  default here), so bridge and Live already share a clock rate.
