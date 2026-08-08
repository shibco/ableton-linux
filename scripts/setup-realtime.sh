#!/usr/bin/env bash
# Host realtime profile for Ableton Live under Wine: the user-space half of the
# distribution-canon pro-audio setup (Arch Wiki professional-audio guide,
# linuxaudio.org system-configuration wiki). Idempotent; safe to re-run.
# Needs root (uses sudo when not root; run it via sudo or as root).
#
# Writes exactly these drop-ins, nothing else:
#   /etc/security/limits.d/90-ableton-rt.conf   rtprio 95, memlock unlimited,
#                                               nice -19 for the RT group
#   /etc/sysctl.d/90-ableton-rt.conf            vm.swappiness = 10
#   /etc/modules-load.d/90-ableton-ntsync.conf  loads the ntsync module at boot
#                                               (kernels that provide it)
# The limits grant the rtprio rights the launcher's opportunistic
# `chrt -r 10` probes for (scripts/ableton-live), so installing this profile is
# what turns that probe on.
#
# Host state changed besides the drop-ins: the invoking user is added to the RT
# group, the running kernel's swappiness is applied immediately, the ntsync
# module is loaded when the kernel provides it, and rtirq.service is enabled
# when installed. Earlier versions also set the
# performance CPU governor here and enabled a boot-time unit reapplying it;
# that is now session-scoped (the launcher holds the "performance" power
# profile while Live runs), and this script removes the old unit when found.
#
# Reported, NEVER performed (host policy — do these by hand):
#   - threadirqs kernel parameter (bootloader edit) — advised when missing
#   - lowlatency / PREEMPT_RT kernel — advised from `uname -r`
#   - wineserver `chrt -f -p 95` boost — deliberately left out: it needs root on
#     every launch, and raising a single-threaded server above its callers can
#     invert the contention it is meant to fix; keep it a manual A/B experiment.
#
# Overrides: ABLETON_RT_GROUP=audio  RT group to create/grant
#            DESTDIR=path           stage the drop-ins under path only; no live
#                                   host changes (packaging/testing)
set -euo pipefail

case "${1:-}" in
    "") ;;
    *) echo "!! unknown option: $1 (no options are supported)" >&2; exit 2 ;;
esac

RT_GROUP="${ABLETON_RT_GROUP:-audio}"
DESTDIR="${DESTDIR:-}"
LIMITS="$DESTDIR/etc/security/limits.d/90-ableton-rt.conf"
SYSCTL="$DESTDIR/etc/sysctl.d/90-ableton-rt.conf"
NTSYNC_CONF="$DESTDIR/etc/modules-load.d/90-ableton-ntsync.conf"
# Installed by versions of this script before 2026-08; removed in step 3.
OLD_GOV_UNIT=/etc/systemd/system/ableton-cpufreq-performance.service

sudo=()
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { echo "!! setup-realtime.sh needs root and sudo is not installed — rerun as root" >&2; exit 1; }
    sudo true 2>/dev/null || { echo "!! setup-realtime.sh needs root: sudo authentication failed (rerun via sudo or as root)" >&2; exit 1; }
    sudo=(sudo)
fi

install_dropin() {  # $1 = destination path; file content on stdin
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    "${sudo[@]}" install -D -m 644 "$tmp" "$1"
    rm -f "$tmp"
}

echo "== [1/6] RT privileges: $RT_GROUP group + PAM limits =="
if [ -n "$DESTDIR" ]; then
    echo "   staged mode (DESTDIR=$DESTDIR) — skipping groupadd/usermod"
else
    getent group "$RT_GROUP" >/dev/null || "${sudo[@]}" groupadd -r "$RT_GROUP"
    # Under sudo $USER is root; the invoking user is in SUDO_USER.
    rt_user="${SUDO_USER:-${USER:-$(id -un)}}"
    if id -nG "$rt_user" | grep -qw "$RT_GROUP"; then
        echo "   $rt_user is already in the $RT_GROUP group"
    else
        "${sudo[@]}" usermod -aG "$RT_GROUP" "$rt_user"
        echo "   added $rt_user to the $RT_GROUP group (takes effect on re-login)"
    fi
fi
install_dropin "$LIMITS" <<EOF
# ableton-linux realtime profile
@$RT_GROUP   -   rtprio    95
@$RT_GROUP   -   memlock   unlimited
@$RT_GROUP   -   nice      -19
EOF
echo "   wrote $LIMITS"

echo "== [2/6] sysctl: vm.swappiness = 10 =="
install_dropin "$SYSCTL" <<EOF
vm.swappiness = 10
EOF
echo "   wrote $SYSCTL"
if [ -z "$DESTDIR" ]; then
    "${sudo[@]}" sysctl --system >/dev/null
    echo "   applied to the running kernel (sysctl --system)"
fi

echo "== [3/6] CPU speed: session-scoped, not boot policy =="
# Earlier versions set the performance governor here and enabled a unit that
# reapplied it at every boot: a permanent battery cost for hosts that run
# Live occasionally. The launcher now holds the "performance" power profile
# through power-profiles-daemon only while Live runs (ABLETON_POWER=off skips
# the hold for one launch). This step only removes what earlier versions
# installed.
if [ -n "$DESTDIR" ]; then
    echo "   staged mode — nothing to stage (the launcher holds the profile per session)"
else
    if [ -f "$OLD_GOV_UNIT" ]; then
        "${sudo[@]}" systemctl disable "$(basename "$OLD_GOV_UNIT")" >/dev/null 2>&1 || true
        "${sudo[@]}" rm -f "$OLD_GOV_UNIT"
        "${sudo[@]}" systemctl daemon-reload
        echo "   removed the boot-time performance-governor unit an earlier version installed"
        echo "   (the governor keeps today's setting until reboot; from now on your"
        echo "    desktop's power settings own it outside Live sessions)"
    else
        echo "   nothing to remove"
    fi
    if command -v powerprofilesctl >/dev/null 2>&1; then
        echo "   powerprofilesctl found: the launcher raises CPU speed while Live runs"
    else
        cat <<'EOF'
-- NOTE: powerprofilesctl not found — the launcher cannot raise CPU speed for
   Live sessions. Install power-profiles-daemon (or tuned-ppd), or manage the
   governor yourself through your desktop's power settings.
   On Pop!_OS and other System76 computers, do not install
   power-profiles-daemon: the package manager removes the System76 power
   management tools to install it. The power settings in your desktop
   already control CPU speed there.
EOF
    fi
fi

echo "== [4/6] ntsync: kernel NT synchronization =="
# Without /dev/ntsync every Windows wait is a wineserver round trip; the
# launcher warns at startup. ntsync ships in Linux 6.14+ (CONFIG_NTSYNC).
if modinfo -n ntsync >/dev/null 2>&1; then
    install_dropin "$NTSYNC_CONF" <<'EOF'
# ableton-linux: load the NT synchronization driver (/dev/ntsync) at boot
ntsync
EOF
    echo "   wrote $NTSYNC_CONF"
    if [ -z "$DESTDIR" ]; then
        "${sudo[@]}" modprobe ntsync 2>/dev/null || true
        if [ -c /dev/ntsync ]; then
            echo "   /dev/ntsync is available"
        else
            echo "-- modprobe ntsync did not produce /dev/ntsync — check 'dmesg | tail'"
        fi
    fi
elif [ -c /dev/ntsync ]; then
    echo "   /dev/ntsync present (built into this kernel; nothing to load)"
else
    cat <<'EOF'
-- NOTE: this kernel provides no ntsync module; without /dev/ntsync every
   Windows wait becomes a wineserver round trip and Live runs much slower.
   Use a Linux 6.14+ kernel with CONFIG_NTSYNC. See TROUBLESHOOTING.md.
EOF
fi

echo "== [5/6] IRQ threading (verify and advise — the bootloader is never touched) =="
if grep -qw threadirqs /proc/cmdline; then
    echo "   threadirqs present on the kernel command line"
else
    cat <<'EOF'
-- NOTE: 'threadirqs' is missing from the kernel command line. Add it via your
   bootloader (GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then
   update-grub or grub2-mkconfig -o /boot/grub2/grub.cfg) and reboot.
EOF
fi
if [ -z "$DESTDIR" ]; then
    if systemctl cat rtirq.service >/dev/null 2>&1; then
        if "${sudo[@]}" systemctl enable rtirq.service >/dev/null 2>&1; then
            echo "   rtirq.service enabled"
        else
            echo "-- rtirq.service is installed but could not be enabled — enable it by hand"
        fi
    else
        echo "-- rtirq not installed — optional; it keeps sound IRQ threads above the default priority"
    fi
fi

echo "== [6/6] report =="
echo "   kernel: $(uname -r)"
case "$(uname -r)" in
    *rt*|*lowlatency*) ;;
    *) echo "-- NOTE: consider a lowlatency or PREEMPT_RT kernel for sub-256-frame buffers" ;;
esac
echo "   (On Fedora, 'dnf install realtime-setup' + the realtime group is a maintained alternative to steps 1-2.)"
echo
if [ -n "$DESTDIR" ]; then
    echo "OK: realtime drop-ins staged under $DESTDIR (no live host changes made)"
else
    echo "OK: realtime profile installed. Re-login, then verify:"
    echo "    'ulimit -r' prints 95 and 'chrt -r 10 true' succeeds — the exact probe the launcher runs"
fi
