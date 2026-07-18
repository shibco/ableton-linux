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
#   /etc/systemd/system/ableton-cpufreq-performance.service
# The limits grant the rtprio rights the launcher's opportunistic
# `chrt -r 10` probes for (scripts/ableton-live), so installing this profile is
# what turns that probe on.
#
# Host state changed besides the drop-ins: the invoking user is added to the RT
# group, the running kernel's swappiness/governor are applied immediately, and
# the governor unit (plus rtirq.service when installed) is enabled.
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
GOV_UNIT="$DESTDIR/etc/systemd/system/ableton-cpufreq-performance.service"

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

echo "== [1/5] RT privileges: $RT_GROUP group + PAM limits =="
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

echo "== [2/5] sysctl: vm.swappiness = 10 =="
install_dropin "$SYSCTL" <<EOF
vm.swappiness = 10
EOF
echo "   wrote $SYSCTL"
if [ -z "$DESTDIR" ]; then
    "${sudo[@]}" sysctl --system >/dev/null
    echo "   applied to the running kernel (sysctl --system)"
fi

echo "== [3/5] CPU governor: performance =="
write_unit=1
if [ -z "$DESTDIR" ]; then
    applied=0
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$g" ] || continue
        echo performance | "${sudo[@]}" tee "$g" >/dev/null
        applied=$((applied + 1))
    done
    if [ "$applied" -gt 0 ]; then
        echo "   set performance on $applied cpufreq governor(s)"
    else
        echo "-- no cpufreq scaling_governor on this host — skipping the governor unit"
        write_unit=0
    fi
fi
if [ "$write_unit" -eq 1 ]; then
    install_dropin "$GOV_UNIT" <<'EOF'
[Unit]
Description=ableton-linux: performance CPU governor
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
[Install]
WantedBy=multi-user.target
EOF
    echo "   wrote $GOV_UNIT"
    if [ -z "$DESTDIR" ]; then
        "${sudo[@]}" systemctl daemon-reload
        "${sudo[@]}" systemctl enable "$(basename "$GOV_UNIT")" >/dev/null
        echo "   enabled $(basename "$GOV_UNIT")"
    fi
fi

echo "== [4/5] IRQ threading (verify and advise — the bootloader is never touched) =="
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

echo "== [5/5] report =="
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
