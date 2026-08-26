# CPU layout evidence for audio reports

The audio report records the CPU layout available to its own process. Linux
controls CPU placement. The report performs read operations.

## Recorded CPU data

The report defines and records the following values for each available
processor:

- the effective CPU set lists the processors that the report can use
- package and core identifiers describe the physical layout
- simultaneous multithreading siblings share one physical core
- `cpu_capacity` and `topology/core_type` describe Linux CPU classes
- maximum frequency gives a limit and current frequency gives one sample
- CPPC and `amd_pstate` values show firmware and Linux scheduler preferences

The report also records the global `amd_pstate` mode, preferred-core setting
and dynamic EPP state. CPPC gives the firmware performance scale for each
processor. EPP means energy performance preference. It describes a balance
between power use and speed.

Linux 7.1.8 passes `amd_pstate_prefcore_ranking` to its scheduler. Linux updates
the scheduler when firmware changes that rank
(`drivers/cpufreq/amd-pstate.c:904-945`). The Linux guide confirms that the rank
can change during use
(`Documentation/admin-guide/pm/amd-pstate.rst:269-280`). A rank describes a
current preference. `core_type` supplies a separate CPU class.

`Cpus_allowed_list` in `/proc/self/status` supplies the effective CPU set. The
report records the online set and Wine input files as separate values.
Machine-readable states mark system-omitted fields and unexpected field
content.

Wine 11 reads the online CPU layout and `/sys/devices/cpu_core/cpus` for its
Windows efficiency class. The report also records
`/sys/devices/cpu_atom/cpus`. The report identifies Linux files as its collection
source. A separate Wine test supplies the result visible to a Windows process.

## Development host result

The host on 26 August 2026 used an AMD Ryzen AI MAX+ 395. It provided 16
physical cores and 32 simultaneous multithreading threads. Its available and
online CPU sets both contained `0-31`. Each physical core had two siblings.

Every reported `cpu_capacity` value was 1024. The `topology/core_type`,
`cpu_core/cpus` and `cpu_atom/cpus` files produced the system-omitted state. The
results describe a symmetric reported capacity. A complete core-class decision
also needs a supplied class field.

ACPI CPPC `highest_perf` and `amd_pstate_prefcore_ranking` ranged from 166 to
236. Hardware preferred cores used `enabled`. The global `amd_pstate` mode used
`active` with `prefcore=enabled`.

Linux already receives changes to the preferred-core ranks. A fixed
application CPU set could keep work on an earlier preferred core after power,
temperature or firmware changes. Linux therefore controls CPU placement on the
development host.

Tests on hybrid CPUs must show how Wine and PipeASIO number each processor.
They must also show where each Live thread runs. A future rule must preserve the
user CPU set, account for audio interrupts and update after CPU state changes.
It must also give prompt CPU access to every audio dependency.

## Test gate for automatic CPU placement

Follow the steps before a default placement rule enters release review.

1. Test 2 Intel hybrid generations, one tiered non-Intel system and one symmetric simultaneous multithreading control.
2. Map every available Linux processor to the Windows `EfficiencyClass` result.
3. Test full, sparse and externally limited CPU sets. Repeat after cold boot, suspend and resume, and CPU offline and online cycles.
4. Run original placement, proposed placement and reversal tests at 32, 64 and 128 frames.
5. Collect at least five 30-second windows for each condition.
6. Record audible gaps, PipeWire xruns and Live deadline use. Record process and thread CPU use.
7. Record context switches, moves between processors, frequency, temperature and package power.
8. Require dropout and xrun counts at or below the original result. Require deadline results that match or improve it.
9. Require a repeated CPU or power benefit. Confirm prompt CPU access for every audio dependency.
10. Test a control setting, original CPU set restoration and automatic original placement for partial evidence.

Use the report for manual experiments. Keep Linux in control of CPU placement
through the test gate.
