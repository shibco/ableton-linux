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
from unittest import mock


HERE = Path(__file__).resolve().parent


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


report = load("bench_report", "bench-report.py")
osc = load("bench_osc", "bench-osc.py")


def benchmark_profile(gates=None):
    return {
        "schema": report.SCHEMA, "kind": "system-profile",
        "system": {
            "uname": "Linux fixture 1", "os_release": {"ID": "fixture"},
            "cpu": {"Architecture": "x86_64", "CPU(s)": "8", "Model name": "Fixture CPU"},
            "cpu_topology": [{"CPU": "0", "CORE": "0", "MHZ": "1234"}],
            "cpu_sysfs": {"cpus": [{"cpu": 0, "cpufreq.scaling_governor": "performance"}]},
            "gpu_lines": ["Fixture GPU"], "gpu_renderer_lines": ["Fixture renderer"],
            "audio_devices": {"alsa_cards": "Fixture audio", "playback": "P", "capture": "C"},
            "audio_kernel": {"available": True, "parameters": {"lowlatency": {"available": True, "value": "Y"}}},
            "power_profile": "performance",
        },
        "pipewire": {
            "versions": {"pipewire": "1.4", "wireplumber": "0.5", "pw_cli": "1.4"},
            "settings": {"values": {"clock.rate": "48000", "clock.quantum": "64"}},
            "active_profile_lines": ["profile = pro-audio"],
            "capture_scope": {"phase": "fixture"},
            "availability": {"pw-dump": {"successful": True}},
        },
        "runtime": {"root": "/runtime", "identity_hash": "runtime-a", "wine_version": "wine-11", "build_info": "build-a"},
        "prefix": {"path": "/prefix", "identity_hash": "prefix-a"},
        "configuration": {
            "identity_hash": "config-a", "benchmark_gates": gates or {},
            "pipeasio_effective_config": {"path": "/config/pipeasio/config.ini", "resolution": "XDG_CONFIG_HOME", "exists": True, "sha256": "asio-a"},
        },
        "live": {
            "executables": [{"product_version": "12.4.3", "sha256": "live-a"}],
            "preferences": [{"version": "12.4.3", "options": ["-MaxAudioThreads=4"], "options_hash": {"sha256": "options-a"}, "max_audio_threads": 4}],
        },
        "fixture_plugins": [
            {"name": "Dexed.vst3", "path": "/prefix/Dexed.vst3", "exists": True, "identity_hash": "dexed-a"},
            {"name": "K1v_x64.vst3", "path": "/prefix/K1v_x64.vst3", "exists": True, "identity_hash": "k1v-a"},
        ],
    }


def benchmark_measurement(name, live_cpu=10.0, missing=False, zero=False):
    value = 0 if zero else live_cpu
    timing = {
        "supervision_interval_seconds": 30.0, "output_span_seconds": 29.5, "output_line_count": 30,
        "first_output_offset_seconds": 0.1, "last_output_offset_seconds": 29.9,
    }
    summary = {
        group: {
            "cpu_percent_of_one_core": (value if group == "live" else 20.0),
            "context_switches": 100,
            "schedstat": {"runtime_ns": 1_000, "run_delay_ns": 20, "timeslices": 30},
            **({"audio_worker_count": 4} if group == "live" else {}),
        }
        for group in ("live", "wine_prefix", "pipewire")
    }
    measurement = {
        "schema": report.SCHEMA, "kind": "set-measurement",
        "set": name, "mode": report.CANONICAL_MODES[name], "duration_seconds": 30,
        "window": {
            "requested_duration_seconds": 30,
            "monotonic_start_ns": 1_000_000_000,
            "monotonic_deadline_ns": 31_000_000_000,
            "cpu_before_collection_offsets_seconds": [-0.02, -0.01],
            "cpu_after_collection_offsets_seconds": [30.0, 30.02],
        },
        "process": {
            "summary": summary,
            "details": {
                "elapsed_seconds": 30.0, "host_cpu_percent": {"cpu": 25.0},
                "accounting": {
                    "confounded_by_task_churn": False,
                    "processes": {"born": [], "exited": []}, "threads": {"born": [], "exited": []},
                },
            },
        },
        "pipewire": {
            "pw_top": {"instrumented": True, "identity_confounded": False, "err_delta": 0, "quantum_transitions": []},
            "settings": {"transitions": []},
        },
        "osc_dsp": {"sample_count": 30, "average_percent": 12.0, "peak_percent": 18.0},
        "kernel_counters": {
            name: {"available": True, "complete": True, "total_rate_per_second": rate, "labels": {}}
            for name, rate in (("interrupts", 100.0), ("softirqs", 200.0))
        },
        "endpoint_identity": {
            "cpu_policy": {
                "changed_within_window": False,
                "before": {"available": True, "policies": [{"policy": "policy0", "scaling_governor": "performance"}]},
                "after": {"available": True, "policies": [{"policy": "policy0", "scaling_governor": "performance"}]},
            },
            "power": {
                "changed_within_window": False,
                "before": {"available": True, "profile": "performance", "holds_available": True, "holds": "bench"},
                "after": {"available": True, "profile": "performance", "holds_available": True, "holds": "bench"},
            },
            "audio": {
                "changed_within_window": False,
                "before": {
                    "available": True, "component_availability": {"sink": True, "source": True, "links": True, "settings": True},
                    "default_sink": ["device.name = fixture"], "default_source": ["device.name = fixture"],
                    "links": ["PipeASIO:output_1 -> fixture:playback_FL"],
                    "graph_settings": {"clock.rate": "48000", "clock.quantum": "64"},
                },
                "after": {
                    "available": True, "component_availability": {"sink": True, "source": True, "links": True, "settings": True},
                    "default_sink": ["device.name = fixture"], "default_source": ["device.name = fixture"],
                    "links": ["PipeASIO:output_1 -> fixture:playback_FL"],
                    "graph_settings": {"clock.rate": "48000", "clock.quantum": "64"},
                },
            },
        },
        "capture_commands": {
            collector: {"available": True, "timing": timing}
            for collector in ("pw-top", "pw-metadata", "osc")
        },
        "live": {"version": "12.4.3", "build": "fixture", "sample_rate": 48000, "output_buffer_frames": 64},
        "crackle": {"status": "no-instrumented-evidence"}, "confounders": [],
    }
    if missing:
        measurement["process"]["summary"]["live"]["cpu_percent_of_one_core"] = None
    return measurement


def write_benchmark_run(root, *, status="complete", duration=30, profile=None, live_cpu=10.0, missing=False, zero=False):
    (root / "profile").mkdir(parents=True)
    (root / "sets").mkdir()
    (root / "run.json").write_text(json.dumps({
        "schema": report.SCHEMA, "kind": "benchmark-run", "harness": {"identity_hash": "harness-a"},
        "status": status, "tag": root.name, "duration_seconds_per_set": duration,
        "set_order": list(report.CANONICAL_SETS),
    }))
    (root / "profile/profile.json").write_text(json.dumps(profile or benchmark_profile()))
    for index, name in enumerate(report.CANONICAL_SETS, 1):
        directory = root / "sets" / f"{index:02d}-{name}"
        directory.mkdir()
        measurement = benchmark_measurement(name, live_cpu, missing, zero)
        measurement["duration_seconds"] = duration
        (directory / "measurement.json").write_text(json.dumps(measurement))


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
            time.sleep(0.05)
            command.terminate_at_deadline()
            result = command.stop()
            timing = result["timing"]
            self.assertEqual(timing["output_line_count"], 2)
            self.assertIsNotNone(timing["spawned_offset_seconds"])
            self.assertIsNotNone(timing["deadline_observed_offset_seconds"])
            self.assertGreaterEqual(timing["output_span_seconds"], 0)
            self.assertTrue(timing["exited_before_deadline"])
            self.assertLess(timing["supervision_interval_seconds"], timing["deadline_observed_offset_seconds"])
            self.assertFalse(report.collector_command_usable(result, 30))

    def test_periodic_collector_with_silent_tail_is_unusable_but_metadata_monitor_is_valid(self):
        command = {
            "available": True,
            "timing": {
                "supervision_interval_seconds": 30.0,
                "output_line_count": 2,
                "first_output_offset_seconds": 0.1,
                "last_output_offset_seconds": 1.1,
                "reader_alive_after_join": False,
            },
        }
        self.assertFalse(report.collector_command_usable(command, 30, "pw-top"))
        self.assertFalse(report.collector_command_usable(command, 30, "osc"))
        self.assertTrue(report.collector_command_usable(command, 30, "pw-metadata"))

    def test_udp_preflight_reports_socket_creation_failure(self):
        args = type("Args", (), {"port": 19002})()
        with mock.patch.object(report.socket, "socket", side_effect=OSError("denied")), mock.patch("builtins.print"):
            self.assertEqual(report.udp_available(args), 1)

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

    def test_kernel_counter_parser_and_delta_preserve_labels_and_cpus(self):
        before_text = """\
           CPU0       CPU1
  8:         10         20  IR-IO-APIC  8-edge rtc0
NMI:          1          2  Non-maskable interrupts
ERR:          4
"""
        after_text = """\
           CPU0       CPU1
  8:         13         25  IR-IO-APIC  8-edge rtc0
NMI:          2          4  Non-maskable interrupts
ERR:          5
"""
        before, after = report.parse_kernel_counters(before_text), report.parse_kernel_counters(after_text)
        before.update(monotonic_ns=1_000_000_000, monotonic_begin_ns=900_000_000, monotonic_end_ns=1_100_000_000)
        after.update(monotonic_ns=31_000_000_000, monotonic_begin_ns=30_900_000_000, monotonic_end_ns=31_100_000_000)
        parsed = report.kernel_counter_delta(before, after)
        self.assertTrue(parsed["available"])
        self.assertTrue(parsed["complete"])
        self.assertEqual(parsed["labels"]["8"]["per_cpu_delta"], {"CPU0": 3, "CPU1": 5})
        self.assertEqual(parsed["labels"]["ERR"]["delta"], 1)
        self.assertEqual(parsed["per_cpu_delta"], {"CPU0": 4, "CPU1": 7})
        self.assertEqual(parsed["total_delta"], 12)
        self.assertEqual(parsed["total_rate_per_second"], 0.4)

    def test_kernel_counter_unavailable_and_reset_are_explicit(self):
        self.assertFalse(report.parse_kernel_counters("")["available"])
        before = report.parse_kernel_counters("CPU0\nTIMER: 9\n")
        after = report.parse_kernel_counters("CPU0\nTIMER: 2\n")
        before.update(monotonic_ns=0)
        after.update(monotonic_ns=1_000_000_000)
        parsed = report.kernel_counter_delta(before, after)
        self.assertFalse(parsed["complete"])
        self.assertEqual(parsed["labels"]["TIMER"]["status"], "counter-reset")
        self.assertIsNone(parsed["total_rate_per_second"])

    def test_profile_environment_keeps_exact_cpu_gates_without_all_wine_values(self):
        environment = {
            "WINE_APC_FASTPATH": "1", "WINEFSYNC": "1", "STAGING_RT_PRIORITY_SERVER": "90",
            "WINE_UNRELATED_SECRET": "omit", "PIPEASIO_REALTIME": "1", "ABLETON_RT": "1",
            "ABLETON_DCOMP": "off", "ABLETON_POWER": "performance",
        }
        selected = report.benchmark_environment(environment)
        self.assertEqual(selected["WINE_APC_FASTPATH"], "1")
        self.assertNotIn("WINE_UNRELATED_SECRET", selected)
        self.assertEqual(report.benchmark_gate_environment(environment)["PIPEASIO_REALTIME"], "1")
        self.assertEqual(report.benchmark_gate_environment(environment)["ABLETON_POWER"], "performance")

    def test_audio_kernel_and_cpu_policy_snapshots_are_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            parameters = root / "parameters"
            parameters.mkdir()
            (parameters / "lowlatency").write_text("Y\n")
            audio = report.audio_kernel_parameters(parameters)
            self.assertEqual(audio["parameters"]["lowlatency"]["value"], "Y")
            self.assertFalse(audio["parameters"]["autoclock"]["available"])
            policy = root / "cpufreq/policy0"
            policy.mkdir(parents=True)
            (policy / "scaling_governor").write_text("performance\n")
            (policy / "scaling_min_freq").write_text("1000\n")
            snapshot = report.cpu_policy_snapshot(root / "cpufreq")
            self.assertTrue(snapshot["available"])
            self.assertEqual(snapshot["policies"][0]["scaling_governor"], "performance")

    def test_audio_endpoint_snapshot_keeps_stable_profile_links_and_graph_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary)
            payloads = {
                "sink": 'device.name = "usb-interface"\ndevice.profile.name = "pro-audio"\nobject.serial = 77\n',
                "source": 'node.name = "alsa_input.usb-interface"\napi.alsa.path = "hw:2"\n',
                "links": "PipeASIO:output_1\n  |-> alsa_output.usb-interface:playback_FL\n",
                "settings": (
                    "update: id:0 key:'clock.rate' value:'48000' type:''\n"
                    "update: id:0 key:'clock.quantum' value:'64' type:''\n"
                ),
            }
            seen = {}

            def fake_capture(name, argv, raw_dir, timeout=15):
                component = name.rsplit("-", 1)[1]
                seen[component] = argv
                (raw_dir / f"{name}.stdout.txt").write_text(payloads[component])
                (raw_dir / f"{name}.stderr.txt").write_text("")
                return {"argv": argv, "available": True, "returncode": 0}

            with mock.patch.object(report, "command_capture", side_effect=fake_capture):
                value = report.audio_endpoint_snapshot(raw, "before")
            self.assertTrue(value["available"])
            self.assertEqual(value["graph_settings"]["clock.quantum"], "64")
            self.assertIn('device.profile.name = "pro-audio"', value["default_sink"])
            self.assertNotIn("object.serial = 77", value["default_sink"])
            self.assertIn("PipeASIO:output_1", value["links"])
            self.assertEqual(seen["links"], ["pw-link", "-l"])

    def test_fixture_plugin_inventory_hashes_file_and_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            root = prefix / "drive_c/Program Files/Common Files/VST3"
            bundle = root / "Dexed.vst3/Contents/x86_64-win"
            bundle.mkdir(parents=True)
            (bundle / "Dexed.vst3").write_bytes(b"MZdexed")
            root.mkdir(parents=True, exist_ok=True)
            (root / "K1v_x64.vst3").write_bytes(b"MZk1v")
            with mock.patch.object(report, "embedded_product_version", return_value="1.2.3"):
                values = report.fixture_plugin_inventory(prefix)
            self.assertEqual([item["kind"] for item in values], ["bundle", "file"])
            self.assertTrue(all(item.get("identity_hash") for item in values))
            self.assertEqual(values[0]["files"][0]["product_version"], "1.2.3")

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

    def test_compare_completed_compatible_runs_and_writes_both_formats(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after, output = root / "before", root / "after", root / "comparison"
            write_benchmark_run(before, live_cpu=10.0)
            write_benchmark_run(after, live_cpu=8.0)
            args = type("Args", (), {"before": str(before), "after": str(after), "output": str(output)})()
            self.assertEqual(report.compare(args), 0)
            result = json.loads((output / "comparison.json").read_text())
            metric = result["sets"][1]["metrics"]["live_cpu_percent"]
            self.assertEqual((metric["delta"], metric["percent_change"]), (-2.0, -20.0))
            self.assertFalse(metric["confounded"])
            self.assertIn("interrupts", result["sets"][1]["kernel_counters"]["before"])
            self.assertIn("Repeat pairs to measure normal variation", (output / "comparison.md").read_text())

    def test_compare_reports_identity_and_exact_gate_confounders(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first_profile = benchmark_profile({"WINE_APC_FASTPATH": "0"})
            last_profile = benchmark_profile({"WINE_APC_FASTPATH": "1"})
            last_profile["runtime"]["identity_hash"] = "runtime-b"
            before, after = root / "before", root / "after"
            write_benchmark_run(before, profile=first_profile)
            write_benchmark_run(after, profile=last_profile)
            after_run = json.loads((after / "run.json").read_text())
            after_run["harness"]["identity_hash"] = "harness-b"
            (after / "run.json").write_text(json.dumps(after_run))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            statuses = {item["id"]: item["status"] for item in result["identity"]}
            self.assertEqual(statuses["runtime_identity"], "different")
            self.assertEqual(statuses["benchmark_gates"], "different")
            self.assertEqual(statuses["harness"], "different")
            self.assertTrue(result["sets"][0]["metrics"]["host_cpu_percent"]["confounded"])

    def test_compare_uses_normalized_harness_hash_not_worktree_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before)
            write_benchmark_run(after)
            for directory, path in ((before, "/worktree/a/bench-report.py"), (after, "/worktree/b/bench-report.py")):
                run = json.loads((directory / "run.json").read_text())
                run["harness"]["files"] = [{"path": path, "sha256": "same", "size": 1}]
                (directory / "run.json").write_text(json.dumps(run))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            harness = next(item for item in result["identity"] if item["id"] == "harness")
            self.assertEqual(harness["status"], "match")

    def test_compare_marks_missing_metrics_without_inventing_zero(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before)
            write_benchmark_run(after, missing=True)
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            metric = result["sets"][0]["metrics"]["live_cpu_percent"]
            self.assertEqual(metric["comparison_status"], "missing-after")
            self.assertIsNone(metric["delta"])
            self.assertIsNone(metric["percent_change"])

    def test_compare_zero_baseline_has_delta_but_undefined_percent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            write_benchmark_run(before, zero=True)
            write_benchmark_run(after, live_cpu=5.0)
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            metric = result["sets"][0]["metrics"]["live_cpu_percent"]
            self.assertEqual(metric["delta"], 5.0)
            self.assertEqual(metric["percent_status"], "zero-baseline")
            self.assertIsNone(metric["percent_change"])

    def test_compare_refuses_incomplete_or_different_duration_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incomplete, complete = root / "incomplete", root / "complete"
            write_benchmark_run(incomplete, status="failed")
            write_benchmark_run(complete)
            with self.assertRaisesRegex(ValueError, "expected 'complete'"):
                report.load_completed_run(incomplete)
            different = root / "different"
            write_benchmark_run(different, duration=31)
            with self.assertRaisesRegex(ValueError, "30-second protocol"):
                report.load_completed_run(different)
            bad_schema = root / "bad-schema"
            write_benchmark_run(bad_schema)
            value = json.loads((bad_schema / "run.json").read_text())
            value["schema"] = "fixture/v0"
            (bad_schema / "run.json").write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "schema/kind"):
                report.load_completed_run(bad_schema)
            bad_window = root / "bad-window"
            write_benchmark_run(bad_window)
            path = next((bad_window / "sets").glob("*-Benchmark_Empty/measurement.json"))
            value = json.loads(path.read_text())
            value.pop("window")
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "monotonic window evidence"):
                report.load_completed_run(bad_window)

    def test_compare_confounders_cover_audio_power_holds_and_fixture_plugins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before, after = root / "before", root / "after"
            first_profile, last_profile = benchmark_profile(), benchmark_profile()
            last_profile["fixture_plugins"][0]["identity_hash"] = "dexed-b"
            write_benchmark_run(before, profile=first_profile)
            write_benchmark_run(after, profile=last_profile)
            path = next((after / "sets").glob("*-Benchmark_Empty/measurement.json"))
            measurement = json.loads(path.read_text())
            measurement["endpoint_identity"]["power"]["before"]["holds_available"] = False
            measurement["endpoint_identity"]["audio"]["before"]["graph_settings"]["clock.quantum"] = "128"
            path.write_text(json.dumps(measurement))
            result = report.comparison_report(report.load_completed_run(before), report.load_completed_run(after))
            self.assertIn("identity:vst_fixtures:different", result["sets"][1]["confounders"])
            self.assertIn("after:power-holds-before-unavailable", result["sets"][1]["confounders"])
            self.assertIn("set-identity:audio defaults/profile/graph-before", result["sets"][1]["confounders"])
            self.assertEqual(result["sets"][1]["metrics"]["graph_quantum_before"]["after"], 128)

    def test_annotate_preserves_unusable_node_identity_as_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary) / "run"
            write_benchmark_run(run_dir)
            path = next((run_dir / "sets").glob("*-Benchmark_Empty/measurement.json"))
            measurement = json.loads(path.read_text())
            measurement["pipewire"]["pw_top"]["identity_confounded"] = True
            measurement["logs"] = {"xrun_line_count": 0}
            path.write_text(json.dumps(measurement))
            args = type("Args", (), {
                "run_dir": str(run_dir), "set_name": "Benchmark_Empty", "manual_crackle": "not-heard",
            })()
            self.assertEqual(report.annotate(args), 0)
            updated = json.loads(path.read_text())
            self.assertEqual(updated["crackle"]["status"], "unknown")

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
            self.assertIn("Crackle evidence", (run_dir / "report.md").read_text())
            annotate_args = type("Args", (), {
                "run_dir": str(run_dir), "set_name": "Benchmark_Zero", "manual_crackle": "heard",
            })()
            self.assertEqual(report.annotate(annotate_args), 0)
            updated = json.loads(next((run_dir / "sets").glob("*-Benchmark_Zero/measurement.json")).read_text())
            self.assertEqual(updated["crackle"]["status"], "manual")

    def test_renderer_marks_unavailable_endpoint_evidence_for_review(self):
        measurement = benchmark_measurement("Benchmark_Zero")
        measurement["endpoint_identity"]["audio"]["before"]["available"] = False
        measurement["endpoint_identity"]["audio"]["after"]["available"] = False
        measurement["endpoint_identity"]["cpu_policy"]["before"]["available"] = False
        measurement["endpoint_identity"]["cpu_policy"]["after"]["available"] = False
        rendered = report.markdown_report({
            "run": {"tag": "fixture", "status": "complete", "duration_seconds_per_set": 30},
            "profile": benchmark_profile(), "sets": [measurement], "generated_at": "fixture",
        })
        row = next(line for line in rendered.splitlines() if line.startswith("| Benchmark_Zero |"))
        cells = [cell.strip() for cell in row.strip("|").split("|")]
        self.assertEqual(cells[10:12], ["review", "review"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
