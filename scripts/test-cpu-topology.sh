#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/live-options.sh
. "$here/lib/live-options.sh"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
pass=0

fail()
{
    echo "not ok - $*" >&2
    exit 1
}

ok()
{
    pass=$((pass + 1))
    echo "ok - $*"
}

has_line()
{
    printf '%s\n' "$1" | grep -qxF -- "$2" || fail "missing report line: $2"
}

make_fixture()
{
    local name="$1"
    fixture="$work/$name"
    cpu_root="$fixture/sys/devices/system/cpu"
    devices_root="$fixture/sys/devices"
    proc_status="$fixture/proc-self-status"
    mkdir -p -- "$cpu_root"
}

make_cpu()
{
    local cpu="$1" package="$2" core="$3" siblings="$4"
    local capacity="$5" core_type="$6" max_khz="$7" current_khz="$8"
    local dir="$cpu_root/cpu$cpu"

    mkdir -p -- "$dir/topology"
    [ "$package" = missing ] || printf '%s\n' "$package" > "$dir/topology/physical_package_id"
    [ "$core" = missing ] || printf '%s\n' "$core" > "$dir/topology/core_id"
    [ "$siblings" = missing ] || printf '%s\n' "$siblings" > "$dir/topology/thread_siblings_list"
    [ "$capacity" = missing ] || printf '%s\n' "$capacity" > "$dir/cpu_capacity"
    [ "$core_type" = missing ] || printf '%s\n' "$core_type" > "$dir/topology/core_type"
    if [ "$max_khz" != missing ] || [ "$current_khz" != missing ]; then
        mkdir -p -- "$dir/cpufreq"
        [ "$max_khz" = missing ] || printf '%s\n' "$max_khz" > "$dir/cpufreq/cpuinfo_max_freq"
        [ "$current_khz" = missing ] || printf '%s\n' "$current_khz" > "$dir/cpufreq/scaling_cur_freq"
    fi
}

make_fixture homogeneous-smt
printf '0-3\n' > "$cpu_root/online"
printf '0-3\n' > "$cpu_root/possible"
printf 'Name:\ttopology-test\nCpus_allowed_list:\t0-3\n' > "$proc_status"
make_cpu 0 0 0 0,2 1024 missing 4200000 3100000
make_cpu 1 0 1 1,3 1024 missing 4200000 3000000
make_cpu 2 0 0 0,2 1024 missing 4200000 2900000
make_cpu 3 0 1 1,3 1024 missing 4200000 2800000
report="$(ableton_cpu_topology_report "$cpu_root" "$proc_status" "$devices_root")"
has_line "$report" 'allowed_cpus=0-3'
has_line "$report" 'allowed_source=proc_status'
has_line "$report" 'reported_logical_cpus=4'
has_line "$report" 'reported_physical_cores=2'
has_line "$report" 'smt_evidence=present'
has_line "$report" 'heterogeneous_evidence=not_observed'
has_line "$report" 'topology_fields_complete=yes'
has_line "$report" 'cpu=0 package=0 core=0 siblings=0,2 cpu_capacity=1024 core_type=unavailable max_khz=4200000 current_khz=3100000'
ok 'A homogeneous SMT fixture reports physical cores, sibling pairs and frequency snapshots without inventing core classes.'

make_fixture hybrid-pe
printf '0-3\n' > "$cpu_root/online"
printf '0-3\n' > "$cpu_root/possible"
printf 'Cpus_allowed_list:\t0-3\n' > "$proc_status"
make_cpu 0 0 0 0 1024 performance 5200000 5100000
make_cpu 1 0 1 1 1024 performance 5200000 5000000
make_cpu 2 0 2 2 640 efficiency 3800000 2700000
make_cpu 3 0 3 3 640 efficiency 3800000 2600000
mkdir -p -- "$devices_root/cpu_core" "$devices_root/cpu_atom"
printf '0-1\n' > "$devices_root/cpu_core/cpus"
printf '2-3\n' > "$devices_root/cpu_atom/cpus"
report="$(ableton_cpu_topology_report "$cpu_root" "$proc_status" "$devices_root")"
has_line "$report" 'heterogeneous_evidence=present'
has_line "$report" 'wine_efficiency_class_source=cpu_core/cpus'
has_line "$report" 'wine_performance_cpus=0-1'
has_line "$report" 'kernel_efficiency_cpus=2-3'
has_line "$report" 'wine_win32_efficiency_class_probe=not_run_read_only'
has_line "$report" 'cpu=2 package=0 core=2 siblings=2 cpu_capacity=640 core_type=efficiency max_khz=3800000 current_khz=2700000'
ok 'A P/E fixture preserves kernel class evidence and labels Wine input separately from an unrun Win32 proof.'

printf 'Cpus_allowed_list:\t0,2\n' > "$proc_status"
report="$(ableton_cpu_topology_report "$cpu_root" "$proc_status" "$devices_root")"
has_line "$report" 'allowed_cpus=0,2'
has_line "$report" 'allowed_logical_cpus=2'
has_line "$report" 'reported_logical_cpus=2'
has_line "$report" 'reported_physical_cores=2'
printf '%s\n' "$report" | grep -q '^cpu=0 ' || fail 'the sparse cpuset omits its first allowed CPU'
printf '%s\n' "$report" | grep -q '^cpu=2 ' || fail 'the sparse cpuset omits its second allowed CPU'
! printf '%s\n' "$report" | grep -qE '^cpu=(1|3) ' \
    || fail 'the sparse cpuset reports a CPU outside the effective affinity'
ok 'A sparse cpuset limits per-CPU rows without hiding the raw Wine and kernel topology inputs.'

make_fixture missing-fields
printf '0\n' > "$cpu_root/online"
printf 'Cpus_allowed_list:\tbroken\n' > "$proc_status"
make_cpu 0 missing missing missing missing missing missing missing
report="$(ableton_cpu_topology_report "$cpu_root" "$proc_status" "$devices_root")"
has_line "$report" 'allowed_cpus=0'
has_line "$report" 'allowed_source=sysfs_online_fallback'
has_line "$report" 'possible_cpus=unavailable'
has_line "$report" 'reported_physical_cores=0'
has_line "$report" 'smt_evidence=unknown'
has_line "$report" 'topology_fields_complete=no'
has_line "$report" 'cpu=0 package=unavailable core=unavailable siblings=unavailable cpu_capacity=unavailable core_type=unavailable max_khz=unavailable current_khz=unavailable'
ok 'Missing and malformed sysfs fields remain explicit while a valid online list provides a bounded fallback.'

make_fixture no-smt
printf '0-2\n' > "$cpu_root/online"
printf '0-2\n' > "$cpu_root/possible"
printf 'Cpus_allowed_list:\t0-2\n' > "$proc_status"
make_cpu 0 0 0 0 1024 missing 4400000 3400000
make_cpu 1 0 1 1 1024 missing 4400000 3300000
make_cpu 2 1 0 2 1024 missing 4400000 3200000
report="$(ableton_cpu_topology_report "$cpu_root" "$proc_status" "$devices_root")"
has_line "$report" 'reported_logical_cpus=3'
has_line "$report" 'reported_physical_cores=3'
has_line "$report" 'smt_evidence=not_observed'
has_line "$report" 'heterogeneous_evidence=not_observed'
has_line "$report" 'topology_fields_complete=yes'
ok 'A multi-package no-SMT fixture counts every core and does not infer heterogeneity from package IDs.'

printf 'PASS: %s CPU topology report checks\n' "$pass"
