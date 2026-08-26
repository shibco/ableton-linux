# NTSync is a measured prerequisite, not a build label

Date: 26 August 2026

The runtime build record says whether Wine was compiled with NTSync. That is not
enough to attribute a benchmark: the kernel device must exist and the matching
wineserver must hold it while Live runs.

This branch makes the distinction explicit:

- the launcher warns when the host device is unavailable but remains usable;
- audio-report.sh associates each wineserver with its exact WINEPREFIX and
  counts that process's /dev/ntsync descriptors;
- check-ntsync.sh defaults to strict proof and exits 3 before starting Wine
  when the device is unavailable;
- deliberate fallback testing requires ABLETON_REQUIRE_NTSYNC=off, and its
  success message still labels NTSync inactive.

The checker continues to verify 27 synchronization semantics with
ntsyncprobe.exe. Device presence alone is never called proof. The benchmark
report should record all three facts independently: runtime compiled support,
host device availability, and live wineserver fd use.
