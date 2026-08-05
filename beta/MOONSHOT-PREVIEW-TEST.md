# Test the performance-moonshot-combined build

This procedure builds, installs, and tests the
`performance-moonshot-combined` branch, which contains the open
performance-moonshot pull requests in one build.

## Requirements

- Debian 13, or a similar Linux, with `podman` and `cabextract` installed.
- 10 GB of free disk space.
- One hour. The build takes most of this time.
- The Ableton Live installer.

## Check for ntsync

If your kernel is older than 6.14, you do not have ntsync, and you will
not get the full performance fixes. Upgrade the kernel to get them. The
Debian 13 kernel is older than 6.14; its backports repository has a newer
one.

1. Check for the feature:

   ```bash
   ls /dev/ntsync
   ```

2. If the answer is "No such file or directory", install the newer kernel:

   ```bash
   sudo apt install -t trixie-backports linux-image-amd64
   sudo reboot
   ```

3. After the restart, load ntsync and make the load permanent:

   ```bash
   sudo modprobe ntsync
   echo ntsync | sudo tee /etc/modules-load.d/90-ableton-ntsync.conf
   ```

Without ntsync, Live works, but the CPU fixes do not show their full
effect.

## Get the code

For a new clone:

```bash
git clone https://github.com/shibco/ableton-linux.git
cd ableton-linux
git checkout performance-moonshot-combined
```

For an existing clone:

```bash
cd ableton-linux
git fetch origin
git checkout performance-moonshot-combined
```

## Build the runtime

```bash
./build.sh
```

The build checks itself. Wait for "build audit passed".

## Install the runtime

```bash
./scripts/install.sh
```

The installer replaces only the Wine runtime. Your Live installation and
your files do not change.

On a new machine, also give the system realtime permissions:

```bash
./scripts/setup-realtime.sh
```

Log out and log in after this script completes.

## Test Live

1. Start Live:

   ```bash
   ableton-live
   ```

2. Measure the idle CPU. Open an empty project. Wait two minutes. Watch
   Live's CPU use in the system monitor. Before this work, Live used about
   30% of one CPU core while idle. Expect much less.
3. Compare with the old code. Close Live, then start it once with the new
   code off:

   ```bash
   WINE_APC_FASTPATH=off WINE_MSG_FASTPATH=off ableton-live
   ```

   Note the idle CPU. Start Live normally. Compare the two numbers.
4. Play a set you know well. Use a small audio buffer (64 to 256 frames).
   Listen for glitches or crackles.
5. If you have two USB audio devices, use them together. Listen for
   crackles over a long session.
6. Add a Max for Live device to a track. The first opening should take
   about two seconds.

## Send the results

Open an issue at https://github.com/shibco/ableton-linux/issues. Include:

- The kernel version (`uname -r`) and the distribution.
- The two idle CPU numbers from step 3 (new code on, new code off).
- What you played and what you heard.
- The session log: `~/.local/state/ableton-wine/session.log`.
- For audio problems: the output of `./scripts/audio-report.sh`.

## Return to the old runtime

```bash
./scripts/uninstall.sh
sh ~/Downloads/install-ableton-latest.run --update
```

The changes and the measurements are in `CHANGELOG.md` and
`notes/FINDINGS-P5-TRACE-2026-08-05.md`.
