# Benchmark sets

Use these Live sets to compare CPU use and audio performance. The
[benchmark guide](../README.md) explains the full process.

Run these commands from the repository root. Start with Live closed.

```bash
scripts/bench-suite.sh --dry-run --tag baseline
scripts/bench-suite.sh --tag baseline
```

Run the sets in the table order:

| Set | Contents | Purpose |
|---|---|---|
| `Benchmark_Zero.als` | the Live idle state | measures the base Live process |
| `Benchmark_Empty.als` | the control device | measures set loading and audio start-up |
| `Benchmark_Inbuilts.als` | Live instruments and effects | measures Live devices |
| `Benchmark_Max4Live.als` | Live devices and Max for Live devices | measures the added Max runtime |
| `Benchmark_VSTs.als` | one Dexed and 3 Nils' K1v instances | measures Windows VST3 plug-ins |

Each set adds one part to the previous set. The first set with a problem
helps you find the affected part.

Every set after `Benchmark_Zero.als` includes the `abl-bench-m4l` control
device. The device controls playback and reports Live's CPU value.

Check each set before a run:

```bash
for f in *.als; do echo "$f: $(zcat "$f" | grep -c abl-bench)"; done
```

`Benchmark_Zero.als` reports `0`. Each other set reports a value of `1` or
more. Add the device from the [control device guide](../m4l/README.md) when a
controlled set reports `0`.

`Benchmark_Zero.als` provides an idle measurement. The control device stays
closed and produces zero DSP samples. Use the host and process CPU values for
this set. The other files in this folder belong to `Benchmark_Empty.als`.

## VST3 plug-ins

Install both plug-ins before you run `Benchmark_VSTs.als`. Then restart Live
or scan the plug-in folder again.

Use these Windows VST3 files:

- [Dexed](https://asb2m10.github.io/dexed/), installed as `Dexed.vst3`
- [Nils' K1v](https://www.nilsschneider.de/wp/nils-k1v/), copied as `K1v_x64.vst3`

The main [instrument and effect guide](../../README.md#instruments-and-effects)
explains both installation methods.
