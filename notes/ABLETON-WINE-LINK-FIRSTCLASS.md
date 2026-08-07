# Ableton Link implementation record

This design shipped in release 2026.07.23.1. Current setup and verification
instructions are in [ABLETON-WINE-LINK.md](ABLETON-WINE-LINK.md). This file
records the implementation choices and remaining test coverage.

## Direct Wine networking

Live joins Ableton Link as its own Wine peer. Wine 11.11 passes the multicast
socket options used by the Link SDK, including `IP_ADD_MEMBERSHIP`,
`IP_MULTICAST_IF`, and `SO_REUSEADDR`. No patch in this project changes the
network stack.

`WSAJoinLeaf` remains a Wine stub, but the Link SDK does not use it. The
Wine-side probe confirmed bidirectional discovery traffic through Wine on
this machine.

An external `jack_link` process cannot synchronize Live with the current
PipeASIO configuration. PipeASIO is a native PipeWire client and has no JACK
transport layer.
JACK-only applications can still use upstream `jack_link` separately.

## Persistent native peer

`tools/ableton-linkd.cpp` builds against the vendored Ableton Link 4.0 SDK.
The daemon joins the session as a native peer. It is designed to retain the
shared timeline state while Live restarts. It enables Start Stop Sync.

After construction, the daemon does not call `setTempo`,
`forceBeatAtTime`, or `requestBeatAtTime`. Its `--tempo` value is only the
construction tempo for a new session. When it joins an existing session, it
adopts that session's state.

Supported modes are:

- No arguments: run in the foreground for the systemd user unit.
- `--daemon`: run in the background and log to
  `~/.log/ableton-linkd/ableton-linkd.log`.
- `--probe [seconds]`: print peer count and session tempo, then exit zero
  after seeing another peer.
- `--tempo BPM`: set the construction tempo, with a default of 120.

The daemon does not bridge JACK. Native applications with Ableton Link
support join the same network session directly.

## Wine multicast probe

`tools/linkprobe.c` builds a Windows PE program that exercises the socket
operations Live needs:

- bind `0.0.0.0:20808` with `SO_REUSEADDR`
- join `224.76.78.75` on each local IPv4 interface
- transmit through `IP_MULTICAST_IF`
- receive and distinguish local from non-local source addresses
- parse the `_asdp_v1` discovery header and node ID

Its verdicts are `LINKPROBE TX`, `LINKPROBE RX-LOOPBACK`,
`LINKPROBE RX-NETWORK`, and `LINKPROBE PEERS`. The process exits zero when
transmit and loopback receive succeed. Network receive requires a packet from
another host.

The probe's discovery packet has no session payload. It verifies Wine's
multicast socket behavior but does not become a full Link peer.

## Build and packaging

The repository vendors `vendor/link-4.0.tar.zst`, including the asio
submodule, and verifies it with `vendor/link.sha256`. `make verify` and
`build.sh` include that checksum.

`build.sh` calls `scripts/build-ableton-linkd.sh`. The installer packager
reuses an executable `dist/ableton-linkd`; if the file is absent or not
executable, the packager calls the same helper. It runs `--help` before
packaging. The helper uses the configured Podman build image, extracts the
vendored SDK, compiles `tools/ableton-linkd.cpp`, and writes
`dist/ableton-linkd`. It validates the new binary before replacing an existing
artifact. The packager copies that artifact to `kit/bin/ableton-linkd`.

The build uses `-static-libstdc++ -static-libgcc`. The tested binary had
`DT_NEEDED` entries for `libm.so.6`, `libc.so.6`, and
`ld-linux-x86-64.so.2`, with no RPATH. When `readelf` and `strings` are
available, `scripts/install.sh` rejects an unexpected shared library.
Otherwise it verifies the package checksum and skips the shared-library and
portal-backend checks.

The installer includes the vendored SDK archive and its GPLv2-or-later
license as corresponding source for `ableton-linkd`. It installs the daemon,
the systemd user unit, and `setup-link.sh` under
`~/.local/share/ableton-wine/`.

## Host and launcher integration

The `.run` installer calls `scripts/setup-link.sh` after installing the Link
files unless `--no-link` is set. Setup version 1, shipped in 2026.07.23.1,
configured the multicast route, added a UDP 20808 allowance when UFW or
firewalld was installed, and enabled the user unit when systemd was
available. It ran as the user because it called `systemctl --user`, and it
requested `sudo` only for host network changes. Its dispatcher hook re-pinned
the route to whichever interface came up, including VPN tunnels. Setup
version 2 (pull request 80, unreleased) made the hook resolve the current
default LAN interface instead and ignore `tun`, `wg`, and `tap` defaults.

Setup version 3 (2026-07-28, unreleased) removed the multicast route and the
NetworkManager hook. The Link SDK sets `IP_MULTICAST_IF` on every discovery
socket, so its multicast sends never consult the routing table; the recorded
system-call trace below showed that translation from both Live under Wine and
the native daemon. A check in a network namespace with an empty routing table
confirmed the kernel behavior: a multicast send without `IP_MULTICAST_IF`
fails with `ENETUNREACH`, and the same send with it succeeds. Version 3 also
removed the interface selection and the VPN default-route refusal: Link binds
each interface itself, so a VPN default route no longer affects LAN
discovery. `sudo` keeps two uses: the UDP 20808 firewall rule when UFW or
firewalld is active, and removing the hook that versions 1 and 2 installed.
Setup records version 3 as configured only after that hook is gone, so a
failed removal is retried on the next update. Installs that declined with
`--no-link` never run the setup; the installer prints the hook path and the
removal command on each run until the hook is removed.

Setup version 5 (2026-08-07, unreleased) scoped the anchor to sessions. The
daemon gained `--linger`: with no peer for that many seconds (default 900,
whole seconds only) it exits 0, and `--linger 0` keeps the always-on
behaviour. Live counts as a peer while Link is enabled in its preferences,
so the timer spans Live restarts but not an idle machine. The launchers
still start the daemon per session; the setup script registers the user
unit without enabling it, disables the enablement that versions 1 to 3
made (once, at migration), and stops a daemon started before the
migration. The unit runs `--linger 0` and remains the explicit opt-in for
an always-on anchor. An enablement made after the version 5 migration is
treated as that opt-in and left alone on re-runs.

The Live, Max, and beta launchers start `ableton-linkd --daemon` when the
binary is installed and no process with that name is running.
`ABLETON_LINKD` overrides the binary path.

`tools/jacklinkd.c` is an older JACK port-link restorer. Its JACK client name
is also `ableton-linkd`, but it is not part of Ableton Link and current
launchers do not start it.

## Recorded verification

Tests completed on 2026-07-22:

- The daemon built both with the host compiler and in the configured Podman
  image. `--daemon`, `--probe`, `--tempo`, `--help`, and signal handling ran
  successfully.
- The daemon joined an existing 133.0 BPM LAN session instead of applying its
  120 BPM construction value. A second probe joined the daemon's state.
- `linkprobe.exe` under the installed Wine reported `LINKPROBE TX OK`,
  `LINKPROBE RX-LOOPBACK OK`, and one peer from the same-host daemon.
- A system-call trace showed per-interface `IP_ADD_MEMBERSHIP` and
  `IP_MULTICAST_IF` translation. The daemon received Wine's discovery
  packets and answered with unicast responses.
- Packaging included the daemon, unit, setup script, SDK source archive, and
  license. Install and uninstall paths were exercised.

The `_asdp_v1` signature uses seven ASCII bytes followed by the byte `0x01`.
Treating the final byte as the character `1` produced an invalid packet and
was corrected during probe development.

## Tests still needed

- Confirm discovery with setup version 3's host state: no `224.0.0.0/4`
  route and no dispatcher hook. Run `linkprobe.exe` under the installed Wine
  and `ableton-linkd --probe` after `sudo ip route del 224.0.0.0/4`.
- Confirm `LINKPROBE RX-NETWORK OK` with a second LAN host.
- Verify Live's peer count and two-way tempo changes.
- Measure beat and phase alignment under audio load.
- Verify Start Stop Sync from Live and another peer.
- Confirm session continuity across a full Live restart.
- Confirm the idle exit: with Live closed and no other peer, a running
  `ableton-linkd` exits 0 within `--linger` seconds and logs the reason.
- Confirm the version 5 migration on a host upgraded from an enabled unit:
  the unit ends up disabled, no daemon remains, and the next Live launch
  starts a session-scoped one.
- Run the assembled `.run` installer and its integrated Link setup on a fresh
  machine.

LinkAudio and a bundled JACK transport bridge remain outside this
implementation.
