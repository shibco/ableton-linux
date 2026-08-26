# Hybrid CPU topology evidence

This work adds observation, not an affinity policy. The audio report records
the CPUs available to its own process and the kernel topology fields needed to
evaluate a future P-core/E-core policy. It never writes sysfs, changes a CPU
mask, changes scheduling, or starts Wine merely to collect topology.

## What the report proves

For every allowed logical CPU that sysfs exposes, the report records package
and core IDs, the complete SMT sibling list, `cpu_capacity`, `topology/core_type`
when the kernel exports it, maximum and current frequency, ACPI CPPC highest and
nominal performance, and the `amd_pstate` driver's performance scale, maximum
frequency, hardware-prefcore state, and current preferred-core ranking. The
global `amd_pstate` mode, preferred-core switch, and dynamic-EPP state are also
preserved. Current frequency is explicitly a single snapshot. Neither it nor a
preferred-core rank is treated as a stable P/E core class.

In Linux 7.1.8, `amd-pstate` passes `amd_pstate_prefcore_ranking` to
`sched_set_itmt_core_prio()` and updates the scheduler topology if the firmware
rank changes (`drivers/cpufreq/amd-pstate.c:904-945`). The kernel documentation
also says the rank can change at runtime
(`Documentation/admin-guide/pm/amd-pstate.rst:269-280`). The report therefore
records the driver field directly instead of reconstructing a permanent mask
from a one-time CPPC value.

The effective CPU set comes from `Cpus_allowed_list` in `/proc/self/status`.
The online list and Wine-related sysfs inputs remain separate, so a sparse
cpuset does not disappear from the evidence. Missing and malformed fields are
reported as `unavailable` or `invalid`; the probe does not infer a core type
from a model name or clock rate.

The packaged Wine 11.x topology path consumes the kernel's online topology and,
when present, `/sys/devices/cpu_core/cpus` to populate processor efficiency-class
information. The report therefore preserves that P-core list and the kernel's
companion `/sys/devices/cpu_atom/cpus` list. This is input evidence, not proof of
what a particular Windows process received. The line
`wine_win32_efficiency_class_probe=not_run_read_only` makes that boundary
explicit: obtaining a fresh Win32 API result would require starting Wine and
could modify or contend for the prefix.

## Why this host does not enable E-core pinning

The 2026-08-26 development host is an AMD Ryzen AI MAX+ 395 with 16 physical
cores and 32 SMT threads. Its allowed and online sets are both `0-31`; each
physical core has two siblings, every reported `cpu_capacity` is 1024, and the
kernel exposes neither `topology/core_type`, `cpu_core/cpus`, nor
`cpu_atom/cpus`. The probe consequently reports no heterogeneous-core evidence.

The host does expose a separate preferred-core signal: both ACPI CPPC
`highest_perf` and `amd_pstate_prefcore_ranking` span 166 through 236 across
physical cores, hardware prefcore is enabled, and the global `amd_pstate` mode
is `active` with `prefcore=enabled`. That is a firmware ranking among otherwise
equal-capacity cores, not an efficiency-core class. It also means Linux already
has a dynamic preference signal for movable work; a static application mask
could override that scheduler choice and retain a worse core after power,
thermal, or firmware conditions change.

That machine cannot answer which Windows and Wine threads benefit from an
efficiency core, whether PipeASIO and Live agree on Windows-to-Linux CPU
numbering, or whether restricting a background thread steals capacity needed by
a synchronous audio dependency. Enabling automatic pinning from this host would
therefore be an untested scheduling policy, not an optimisation. It could also
override a user's cpuset, collide with IRQ placement, or strand work after CPU
hotplug or suspend. Preferred-core ranking is therefore reported as evidence,
not converted into affinity.

## Gate for any future automatic policy

Automatic classification or affinity remains off until all of the following
are recorded:

1. On at least two Intel hybrid generations and one capacity-tiered non-Intel
   system, the sysfs report must map every allowed CPU consistently to
   `GetLogicalProcessorInformationEx` and `GetSystemCpuSetInformation`, including
   their `EfficiencyClass` results. A symmetric SMT host remains the control.
2. Full, sparse and externally restricted cpusets must retain their exact mask.
   Missing or contradictory class fields must select the unchanged, unpinned
   path. The mapping must survive a cold boot, suspend/resume and CPU
   offline/online cycle.
3. Each machine must run matched unpinned, proposed-affinity and reversal runs
   for a loaded Set at 32, 64 and 128 frames. Use at least five 30-second windows
   per condition and record audible discontinuities, PipeWire xruns, Live's
   deadline meter, process and per-thread CPU, context switches, CPU migrations,
   frequency, temperature and package power.
4. The proposed policy must add no dropout or xrun, show no repeatable deadline
   regression, and produce a repeatable CPU or power benefit. It must also prove
   that callback dependencies such as wineserver work are not placed behind
   unrelated real-time work on a slower class.
5. An explicit off switch, the original affinity mask and an automatic fallback
   for incomplete evidence must be tested before any default-on review.

Until that gate passes, the topology data is suitable for reports and manual
experiments only.
