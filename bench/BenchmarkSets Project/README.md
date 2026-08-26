# BenchmarkSets

The Live sets for benchmarking Ableton Live on this runtime. The
measurement protocol, tools, and report schema are in
[bench/README.md](../README.md). A first run, from the repository root
with Live closed:

```bash
scripts/bench-suite.sh --dry-run --tag baseline
scripts/bench-suite.sh --tag baseline
```

| Set | Contents | Measures |
|---|---|---|
| `Benchmark_Zero.als` | nothing at all, not even the control device | Live on its own, with the Max runtime never booting |
| `Benchmark_Empty.als` | nothing but the control device | startup, audio open, and set load with no content |
| `Benchmark_Inbuilts.als` | stock instruments and effects | Live's own engine, with no outside code |
| `Benchmark_Max4Live.als` | stock devices plus Max for Live devices | the Max runtime on top of the stock engine |
| `Benchmark_VSTs.als` | one Dexed and three Nils' K1v instances | third-party VST3 hosting on top of everything above |

Benchmark in table order. Each set adds one layer to the set before it,
so the first set that misbehaves names the layer that broke: Live
itself, the Max runtime, or VST3 hosting.

Every set except `Benchmark_Zero.als` carries the `abl-bench-m4l`
control device on a track, which lets the bench tools drive the
transport and read Live's CPU meter with no operator input. Confirm it
from this folder before a run:

```bash
for f in *.als; do echo "$f: $(zcat "$f" | grep -c abl-bench)"; done
```

A count of 0 means the device is missing from that set; add it back from
[bench/m4l](../m4l/README.md) and save the set. `Benchmark_Zero.als` is
the exception and must stay at 0: it exists to measure Live with no Max
for Live device loaded, so the runtime never boots. The automated suite
therefore records Zero as an idle/no-controller window with DSP values
unavailable; it never pretends to have started transport or received OSC.
Everything else in the folder is the same set as `Benchmark_Empty.als`.

Before benchmarking the VSTs set, install these two synths and rescan
or restart Live. Both installation methods are described in
[Instruments and Effects](../../README.md#instruments-and-effects):

- Dexed (https://asb2m10.github.io/dexed/): the Windows-installer
  method; it installs `Dexed.vst3`.
- Nils' K1v (https://www.nilsschneider.de/wp/nils-k1v/): the VST3-file
  method; copy `K1v_x64.vst3` from its download.
