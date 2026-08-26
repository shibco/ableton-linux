#!/usr/bin/env python3
"""Deterministic parser and report tests; no Live or PipeWire session needed."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest


HERE = Path(__file__).resolve().parent


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


report = load("bench_report", "bench-report.py")
osc = load("bench_osc", "bench-osc.py")


class ParserTests(unittest.TestCase):
    def test_pw_top_xruns_reset_and_quantum_transition(self):
        fixture = """\
0.000000\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
0.100000\tR 42 256 48000 0.1 0.2 0.0 0.0 2 S16LE Ableton Live
1.000000\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
1.100000\tR 42 256 48000 0.1 0.2 0.0 0.0 4 S16LE Ableton Live
2.000000\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
2.100000\tR 42 128 48000 0.1 0.2 0.0 0.0 5 S16LE Ableton Live
2.100000\tR 99 128 48000 0.1 0.2 0.0 0.0 99 S16LE Firefox
"""
        parsed = report.parse_pw_top(fixture)
        self.assertTrue(parsed["instrumented"])
        self.assertEqual(parsed["err_delta"], 3)
        self.assertEqual(parsed["nodes"][0]["quantums"], [256, 128])
        self.assertEqual(parsed["quantum_transitions"][0]["to"], 128)

    def test_pw_top_splits_node_generations_on_reset_gap_and_name_change(self):
        fixture = """\
0.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
0.1\tR 42 256 48000 0.1 0.2 0.0 0.0 5 S16LE Ableton Live
1.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
1.1\tR 42 256 48000 0.1 0.2 0.0 0.0 1 S16LE Ableton Live
2.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
2.1\tR 99 256 48000 0.1 0.2 0.0 0.0 0 S16LE Firefox
3.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
3.1\tR 42 128 48000 0.1 0.2 0.0 0.0 2 S16LE Ableton Live
4.0\tS ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
4.1\tR 42 128 48000 0.1 0.2 0.0 0.0 2 S16LE PipeASIO
"""
        parsed = report.parse_pw_top(fixture)
        self.assertEqual([node["generation"] for node in parsed["nodes"]], [1, 2, 3, 4])
        self.assertEqual([event["reason"] for event in parsed["node_lifecycle_events"]], [
            "error-counter-reset-or-id-reuse",
            "disappeared-and-reappeared",
            "name-change-or-id-reuse",
        ])
        self.assertTrue(parsed["identity_confounded"])
        self.assertEqual(parsed["err_delta"], 1)

    def test_osc_average_and_peak_are_distinct(self):
        fixture = """\
0.1\t1700000000.000 /abl/bench/cpu 10 14
0.2\t1700000000.500 /abl/bench/cpu -1 -1
0.3\t1700000001.000 /abl/bench/cpu 20 31
"""
        parsed = report.parse_osc(fixture)
        self.assertEqual(parsed["sample_count"], 2)
        self.assertEqual(parsed["average_percent"], 15.0)
        self.assertEqual(parsed["peak_percent"], 31.0)

    def test_metadata_transition_parser(self):
        fixture = """\
0.0\tupdate: id:0 key:'clock.quantum' value:'256' type:''
1.0\tremove: id:0 key:'clock.quantum'
2.0\tupdate: id:0 key:'clock.quantum' value:'128' type:''
3.0\tupdate: id:0 key:'clock.rate' value:'48000' type:''
4.0\tremove: id:0 all keys
"""
        parsed = report.parse_metadata(fixture)
        self.assertEqual(parsed["values"], {})
        self.assertEqual(
            [(item["key"], item["from"], item["to"]) for item in parsed["transitions"]],
            [
                ("clock.quantum", "256", None),
                ("clock.quantum", None, "128"),
                ("clock.quantum", "128", None),
                ("clock.rate", "48000", None),
            ],
        )
        self.assertEqual([item["operation"] for item in parsed["events"]], [
            "update", "remove", "update", "update", "remove-all",
        ])

    def test_metadata_literal_null_is_a_delete_readd_transition(self):
        fixture = """\
0.0\tupdate: id:0 key:'clock.force-rate' value:'48000' type:''
1.0\tupdate: id:0 key:'clock.force-rate' value:(null) type:''
2.0\tupdate: id:0 key:'clock.force-rate' value:'44100' type:''
"""
        parsed = report.parse_metadata(fixture)
        self.assertEqual(parsed["values"]["clock.force-rate"], "44100")
        self.assertEqual(
            [(item["from"], item["to"]) for item in parsed["transitions"]],
            [("48000", None), (None, "44100")],
        )

    def test_endpoint_task_lifecycle_is_explicitly_confounded(self):
        def task(pid, start, comm, cpu, threads=()):
            return {
                "pid": pid, "starttime_ticks": start, "comm": comm,
                "utime_ticks": cpu, "stime_ticks": 0, "status": {
                    "voluntary_ctxt_switches": cpu, "nonvoluntary_ctxt_switches": 0,
                },
                "schedstat": {"runtime_ns": cpu, "run_delay_ns": 0, "timeslices": cpu},
                "threads": list(threads), "cmdline": [comm], "exe": f"/runtime/{comm}",
            }

        before = {
            "monotonic_ns": 1_000_000_000, "clock_ticks_per_second": 100, "host_cpu": {},
            "processes": [
                task(10, 100, "Live", 10, [task(10, 100, "Main", 5), task(11, 101, "Old", 1)]),
                task(20, 200, "Helper", 3, [task(20, 200, "Helper", 3)]),
            ],
        }
        after = {
            "monotonic_ns": 31_000_000_000, "clock_ticks_per_second": 100, "host_cpu": {},
            "processes": [
                task(10, 100, "Live", 40, [task(10, 100, "Main", 20), task(12, 102, "New", 2)]),
                task(30, 300, "Born", 2, [task(30, 300, "Born", 2)]),
            ],
        }
        parsed = report.snapshots_delta(before, after)
        accounting = parsed["accounting"]
        self.assertEqual([item["pid"] for item in parsed["processes"]], [10])
        self.assertTrue(accounting["confounded_by_task_churn"])
        self.assertEqual(accounting["confounder"], "task-churn-detected")
        self.assertEqual([item["pid"] for item in accounting["processes"]["born"]], [30])
        self.assertEqual([item["pid"] for item in accounting["processes"]["exited"]], [20])
        self.assertEqual([item["pid"] for item in accounting["threads"]["born"]], [12, 30])
        self.assertEqual([item["pid"] for item in accounting["threads"]["exited"]], [11, 20])
        self.assertEqual(parsed["elapsed_seconds"], 30.0)
        self.assertEqual(parsed["elapsed_lower_bound_seconds"], 30.0)
        self.assertEqual(parsed["elapsed_upper_bound_seconds"], 30.0)

    def test_timed_command_reports_observed_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            command = report.TimedCommand(
                "fixture", [sys.executable, "-c", "print('one'); print('two')"],
                Path(temporary), time.monotonic_ns(),
            )
            command.start()
            assert command.process is not None
            command.process.wait(timeout=2)
            command.terminate_at_deadline()
            result = command.stop()
            timing = result["timing"]
            self.assertEqual(timing["output_line_count"], 2)
            self.assertIsNotNone(timing["spawned_offset_seconds"])
            self.assertIsNotNone(timing["deadline_observed_offset_seconds"])
            self.assertGreaterEqual(timing["output_span_seconds"], 0)

    def test_effective_pipeasio_config_follows_xdg_then_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            xdg_path = root / "xdg/pipeasio/config.ini"
            xdg_path.parent.mkdir(parents=True)
            xdg_path.write_text("[pipeasio]\n")
            xdg = report.effective_pipeasio_config({"XDG_CONFIG_HOME": str(root / "xdg"), "HOME": "/ignored"})
            self.assertEqual(xdg["path"], str(xdg_path))
            self.assertEqual(xdg["resolution"], "XDG_CONFIG_HOME")
            home = report.effective_pipeasio_config({"HOME": str(root / "home")})
            self.assertEqual(home["path"], str(root / "home/.config/pipeasio/config.ini"))
            self.assertEqual(report.effective_pipeasio_config({})["path"], None)

    def test_live_log_identity_includes_runtime_visible_core_topology(self):
        fixture = """\
2026-08-20: info: Started: Live 12.4.3 Build: test-build
2026-08-20: info: Options: -MaxAudioThreads=16
2026-08-20: info: Init: CPU Count: 32
2026-08-20: info: Init: Logical High-Performance Core Count: 24
2026-08-20: info: Init: Logical Power-Efficient Core Count: 8
2026-08-20: info: Init: CPU Count For Real-Time Threads: 24
2026-08-20: info: Audio In Out: Sample Rate: 48000
2026-08-20: info: Audio In Out: Output Buffer Size: 64 Samples
"""
        parsed = report.parse_live_log_identity(fixture)
        self.assertEqual(parsed["version"], "12.4.3")
        self.assertEqual(parsed["max_audio_threads_option"], 16)
        self.assertEqual(parsed["reported_performance_cpus"], 24)
        self.assertEqual(parsed["reported_efficiency_cpus"], 8)
        self.assertEqual(parsed["output_buffer_frames"], 64)

    def test_proc_stat_handles_spaces_and_parentheses(self):
        # Fields 3 onward from proc_pid_stat(5); pad through policy (field 41).
        fields = ["S", "1"] + ["0"] * 9 + ["100", "50"] + ["0"] * 4 + ["7", "0", "999"] + ["0"] * 16 + ["3", "10", "2"]
        parsed = report.parse_proc_stat("123 (Audio Worker (7)) " + " ".join(fields))
        self.assertIsNotNone(parsed)
        assert parsed
        self.assertEqual(parsed["comm"], "Audio Worker (7)")
        self.assertEqual(parsed["utime_ticks"], 100)
        self.assertEqual(parsed["stime_ticks"], 50)

    def test_crackle_status_precedence_and_semantics(self):
        self.assertEqual(report.crackle_status(True, 1, 0, "heard")["status"], "detected")
        self.assertEqual(report.crackle_status(True, 0, 0, "heard")["status"], "manual")
        self.assertEqual(report.crackle_status(True, 0, 0, "not-provided")["status"], "no-instrumented-evidence")
        self.assertEqual(report.crackle_status(False, 0, 0, "not-heard")["status"], "unknown")

    def test_live_worker_count_uses_observed_audiocalc_threads(self):
        delta = {"processes": [{
            "pid": 12,
            "comm": "Ableton Live 12",
            "cmdline": [r"C:\\ProgramData\\Ableton Live 12 Suite.exe"],
            "exe": "/runtime/bin/wine64",
            "cpu_percent_of_one_core": 25.0,
            "context_switches": 4,
            "threads": [
                {"pid": 13, "comm": "AudioCalc"},
                {"pid": 14, "comm": "AudioCalc"},
                {"pid": 15, "comm": "MainThread"},
            ],
        }]}
        groups = report.process_groups(delta, Path("/prefix"), Path("/runtime"))
        self.assertEqual(groups["live"]["audio_worker_count"], 2)
        self.assertEqual(groups["live"]["thread_count"], 3)

    def test_osc_string_padding_round_trip(self):
        # Four-character strings are the edge case: OSC still needs four NULs.
        packet = osc.encode("/abc", ["test", "7", "1.5"])
        address, arguments = osc.decode(packet)
        self.assertEqual(address, "/abc")
        self.assertEqual(arguments, ["test", 7, 1.5])

    def test_live_inventory_reports_options_and_worker_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            prefs = prefix / "drive_c/users/bench/AppData/Roaming/Ableton/Live 12.4.3/Preferences"
            prefs.mkdir(parents=True)
            (prefs / "Options.txt").write_text("-DisablePythonOptimize\n-MaxAudioThreads=6\n")
            inventory = report.live_inventory(prefix)
            self.assertEqual(inventory["preferences"][0]["version"], "12.4.3")
            self.assertEqual(inventory["preferences"][0]["max_audio_threads"], 6)
            self.assertIn("-DisablePythonOptimize", inventory["preferences"][0]["options"])

    def test_renderer_keeps_canonical_set_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            order = ["Benchmark_Zero", "Benchmark_Empty"]
            (run_dir / "sets").mkdir()
            (run_dir / "profile").mkdir()
            (run_dir / "run.json").write_text(json.dumps({
                "tag": "fixture", "status": "complete", "duration_seconds_per_set": 30,
                "set_order": order,
            }))
            (run_dir / "profile/profile.json").write_text("{}")
            for index, name in enumerate(reversed(order), 1):
                directory = run_dir / "sets" / f"{index:02d}-{name}"
                directory.mkdir()
                (directory / "measurement.json").write_text(json.dumps({"set": name, "mode": "playback"}))
            args = type("Args", (), {"run_dir": str(run_dir)})()
            self.assertEqual(report.render(args), 0)
            rendered = json.loads((run_dir / "report.json").read_text())
            self.assertEqual([item["set"] for item in rendered["sets"]], order)
            self.assertIn("Crackle status semantics", (run_dir / "report.md").read_text())
            annotate_args = type("Args", (), {
                "run_dir": str(run_dir), "set_name": "Benchmark_Zero", "manual_crackle": "heard",
            })()
            self.assertEqual(report.annotate(annotate_args), 0)
            updated = json.loads(next((run_dir / "sets").glob("*-Benchmark_Zero/measurement.json")).read_text())
            self.assertEqual(updated["crackle"]["status"], "manual")


if __name__ == "__main__":
    unittest.main(verbosity=2)
