#!/usr/bin/env bash
# Deterministic dry-run/preflight tests. No Wine command or Live set is run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base="$(mktemp -d)"
cleanup()
{
    rm -rf -- "$base"
}
trap cleanup EXIT

home="$base/home"
runtime="$base/runtime"
prefix="$base/prefix"
data="$base/data"
config="$base/config"
state="$base/state"
cache="$base/cache"
bin="$base/bin"
proc_fixture="$base/proc"
mkdir -p -- \
    "$home" "$runtime/bin" "$prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program" \
    "$prefix/drive_c/Program Files/Common Files/VST3/Dexed.vst3" \
    "$prefix/drive_c/Program Files/Common Files/VST3/K1v_x64.vst3" \
    "$data" "$config" "$state" "$cache" "$bin" "$proc_fixture"
true_binary="$(type -P true)"
cp -- "$true_binary" "$runtime/bin/wine"
cp -- "$true_binary" "$runtime/bin/wineserver"
touch -- "$prefix/system.reg"
touch -- "$prefix/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe"

fixture_env=(
    env -i
    "PATH=$PATH"
    "HOME=$home"
    USER=bench
    DISPLAY=:fixture
    ABLETON_BENCH_TESTING=1
    "ABLETON_BENCH_PROC_ROOT=$proc_fixture"
    "ABLETON_WINE_ROOT=$runtime"
    "ABLETON_WINEPREFIX=$prefix"
    "ABLETON_DATA_HOME=$data"
    "ABLETON_CONFIG_HOME=$config"
    "ABLETON_STATE_HOME=$state"
    "ABLETON_CACHE_HOME=$cache"
    "ABLETON_BIN_HOME=$bin"
    "ABLETON_CONFIG_FILE=$config/config"
)

fail()
{
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

ok()
{
    printf 'ok - %s\n' "$*"
}

dry_output="$base/dry-report"
"${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --tag fixture --output "$dry_output" \
    > "$base/default.out" 2> "$base/default.err" \
    || fail "valid dry-run preflight failed: $(cat "$base/default.err")"
[ ! -e "$dry_output" ] || fail "dry-run created its report directory"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ && $4 == "30s" {count++} END {print count+0}' "$base/default.out")" -eq 5 ] \
    || fail "the default 30-second duration did not reach all five sets"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ {print $2}' "$base/default.out" | paste -sd, -)" \
    = "Benchmark_Zero,Benchmark_Empty,Benchmark_Inbuilts,Benchmark_Max4Live,Benchmark_VSTs" ] \
    || fail "the dry-run order is not canonical"
grep -q $'^1\tBenchmark_Zero\tidle-no-controller\t30s$' "$base/default.out" \
    || fail "Benchmark_Zero is not explicitly an idle/no-controller run"
ok "dry-run is mutation-free and fixes every set to the default 30-second window"

"${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --duration 7 --tag fixture \
    --output "$base/custom-report" > "$base/custom.out" 2> "$base/custom.err" \
    || fail "custom-duration dry-run failed"
[ "$(awk -F '\t' '$1 ~ /^[1-5]$/ && $4 == "7s" {count++} END {print count+0}' "$base/custom.out")" -eq 5 ] \
    || fail "a custom common duration did not reach all five sets"
ok "one duration value governs every planned set"

if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --tag fixture \
    --output "$prefix/benchmark-output" > "$base/overlap.out" 2> "$base/overlap.err"; then
    fail "preflight accepted report output inside the Wine prefix"
fi
grep -q 'output must not overlap the runtime, prefix, or immutable set project' "$base/overlap.err" \
    || fail "unsafe output overlap refusal was not precise"
ok "preflight keeps reports outside the runtime, prefix, and immutable sets"

mkdir -p -- "$proc_fixture/4242"
printf 'C:\\ProgramData\\Ableton\\Live 12 Suite\\Program\\Ableton Live 12 Suite.exe\000fixture\000' \
    > "$proc_fixture/4242/cmdline"
if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --tag fixture \
    --output "$base/existing-live-report" > "$base/existing.out" 2> "$base/existing.err"; then
    fail "preflight accepted an existing Live session"
fi
grep -q 'session already exists (pid(s): 4242' "$base/existing.err" \
    || fail "existing-session refusal did not identify the pid"
ok "preflight refuses an existing Live session before creating output"

if "${fixture_env[@]}" "$here/bench-suite.sh" --dry-run --duration 0 --tag fixture \
    --output "$base/zero-report" > "$base/zero.out" 2> "$base/zero.err"; then
    fail "preflight accepted a zero duration"
fi
grep -q 'duration must be between 1 and 3600 seconds' "$base/zero.err" \
    || fail "invalid-duration refusal was not precise"
ok "duration validation is bounded and deterministic"
