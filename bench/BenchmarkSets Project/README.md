# BenchmarkSets

The Live sets for benchmarking Ableton Live on this runtime. The
measurement protocol, the tools, and the rules for recording rows are in
[bench/README.md](../README.md). A first run, from the repository root
with Live closed:

```bash
scripts/bench-workload.sh baseline --set "bench/BenchmarkSets Project/LinuxDemoEmpty.als" -n 3
```

| Set | Contents | Measures |
|---|---|---|
| `LinuxDemoEmpty.als` | nothing but the control device | startup, audio open, and set load with no content |
| `LinuxDemoInbuilt.als` | stock instruments and effects | Live's own engine, with no outside code |
| `LinuxDemoInbuiltMax4Live.als` | stock devices plus Max for Live devices | the Max runtime on top of the stock engine |
| `LinuxDemoVSTs.als` | one Dexed and three Nils' K1v instances | third-party VST3 hosting on top of everything above |

Benchmark in table order. Each set adds one layer to the set before it,
so the first set that misbehaves names the layer that broke: Live
itself, the Max runtime, or VST3 hosting.

Every set carries the `abl-bench-m4l` control device on a track, which
lets the bench tools drive the transport and read Live's CPU meter with
no operator input. Confirm it from this folder before a run:

```bash
for f in *.als; do echo "$f: $(zcat "$f" | grep -c abl-bench)"; done
```

A count of 0 means the device is missing from that set; add it back from
[bench/m4l](../m4l/README.md) and save the set.

Before benchmarking the VSTs set, install these two synths and rescan
or restart Live. Both installation methods are described in
[Instruments and Effects](../../README.md#instruments-and-effects):

- Dexed (https://asb2m10.github.io/dexed/): the Windows-installer
  method; it installs `Dexed.vst3`.
- Nils' K1v (https://www.nilsschneider.de/wp/nils-k1v/): the VST3-file
  method; copy `K1v_x64.vst3` from its download.
