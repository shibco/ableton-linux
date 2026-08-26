#!/usr/bin/env python3
"""Capture and render reproducible Ableton/PipeASIO benchmark evidence.

The shell suite owns Live's lifecycle.  This program owns read-only profiling,
one deadline-aligned measurement window, deterministic parsers, and reports.
It intentionally has no Wine termination code.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from typing import Any, Iterable


SCHEMA = "ableton-linux-benchmark/v1"
DEFAULT_NODE_RE = r"Ableton|Live|[Pp]ipe[Aa][Ss][Ii][Oo]"
CANONICAL_SETS = (
    "Benchmark_Zero", "Benchmark_Empty", "Benchmark_Inbuilts", "Benchmark_Max4Live", "Benchmark_VSTs",
)
XRUN_RE = re.compile(
    r"\b(?:xrun|underrun|overrun)s?\b|missed.{0,24}(?:deadline|cycle)|"
    r"buffer.{0,16}(?:under|over)run",
    re.IGNORECASE,
)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def dump_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def sha256_file(path: Path) -> dict[str, Any]:
    record: dict[str, Any] = {"path": str(path), "exists": False}
    try:
        stat = path.stat()
        if not path.is_file():
            record["kind"] = "not-a-regular-file"
            return record
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        record.update(exists=True, size=stat.st_size, sha256=digest.hexdigest())
    except OSError as error:
        record["error"] = str(error)
    return record


def manifest_hash(records: Iterable[dict[str, Any]], root: Path | None = None) -> str:
    digest = hashlib.sha256()
    for record in sorted(records, key=lambda item: item["path"]):
        path = Path(record["path"])
        try:
            label = str(path.relative_to(root)) if root else str(path)
        except ValueError:
            label = str(path)
        digest.update(label.encode())
        digest.update(b"\0")
        digest.update(str(record.get("sha256", "absent")).encode())
        digest.update(b"\0")
        digest.update(str(record.get("size", 0)).encode())
        digest.update(b"\n")
    return digest.hexdigest()


def effective_pipeasio_config(environment: dict[str, str] | None = None) -> dict[str, Any]:
    values = os.environ if environment is None else environment
    xdg_home = values.get("XDG_CONFIG_HOME", "")
    home = values.get("HOME", "")
    if xdg_home:
        path, source = Path(xdg_home) / "pipeasio/config.ini", "XDG_CONFIG_HOME"
    elif home:
        path, source = Path(home) / ".config/pipeasio/config.ini", "HOME"
    else:
        return {"path": None, "resolution": "unavailable-no-XDG_CONFIG_HOME-or-HOME", "exists": False}
    record = sha256_file(path.resolve())
    record["resolution"] = source
    return record


def command_capture(name: str, argv: list[str], raw_dir: Path, timeout: int = 15) -> dict[str, Any]:
    stdout_path = raw_dir / f"{name}.stdout.txt"
    stderr_path = raw_dir / f"{name}.stderr.txt"
    result: dict[str, Any] = {
        "argv": argv,
        "available": bool(argv and shutil.which(argv[0])),
        "stdout": str(stdout_path.relative_to(raw_dir.parent)),
        "stderr": str(stderr_path.relative_to(raw_dir.parent)),
    }
    if not result["available"]:
        stdout_path.write_text("")
        stderr_path.write_text(f"command not found: {argv[0]}\n")
        result["returncode"] = None
        return result
    try:
        completed = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        stdout_path.write_bytes(completed.stdout)
        stderr_path.write_bytes(completed.stderr)
        result["returncode"] = completed.returncode
    except subprocess.TimeoutExpired as error:
        stdout_path.write_bytes(error.stdout or b"")
        stderr_path.write_bytes((error.stderr or b"") + f"\ntimed out after {timeout}s\n".encode())
        result.update(returncode=124, timed_out=True)
    except OSError as error:
        stdout_path.write_text("")
        stderr_path.write_text(str(error) + "\n")
        result.update(returncode=None, error=str(error))
    return result


def parse_os_release(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"')
    return values


def parse_lscpu_json(text: str) -> dict[str, str]:
    try:
        payload = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return {}
    values: dict[str, str] = {}
    for item in payload.get("lscpu", []):
        field = str(item.get("field", "")).rstrip(":")
        if field:
            values[field] = str(item.get("data", ""))
    return values


def parse_topology_table(text: str) -> list[dict[str, str]]:
    lines = [line.split() for line in text.splitlines() if line.strip()]
    if len(lines) < 2:
        return []
    header = lines[0]
    return [dict(zip(header, row)) for row in lines[1:] if len(row) == len(header)]


def selected_lines(text: str, pattern: str) -> list[str]:
    wanted = re.compile(pattern, re.IGNORECASE)
    return [line.strip() for line in text.splitlines() if wanted.search(line)]


def cpu_sysfs_inventory(root: Path = Path("/sys/devices/system/cpu")) -> dict[str, Any]:
    attributes = (
        "topology/physical_package_id", "topology/die_id", "topology/core_id",
        "topology/core_type", "topology/thread_siblings_list", "topology/core_cpus_list",
        "cpu_capacity", "online", "cpufreq/scaling_driver", "cpufreq/scaling_governor",
        "cpufreq/energy_performance_preference", "cpufreq/scaling_min_freq",
        "cpufreq/scaling_max_freq", "cpufreq/cpuinfo_max_freq",
    )
    cpus = []
    try:
        paths = sorted(
            (path for path in root.iterdir() if re.fullmatch(r"cpu\d+", path.name)),
            key=lambda path: int(path.name[3:]),
        )
    except OSError:
        paths = []
    for path in paths:
        record: dict[str, Any] = {"cpu": int(path.name[3:])}
        for attribute in attributes:
            value = read_text(path / attribute).strip()
            if value:
                record[attribute.replace("/", ".")] = value
        cpus.append(record)
    return {
        "cpus": cpus,
        "online": read_text(root / "online").strip(),
        "offline": read_text(root / "offline").strip(),
        "isolated": read_text(root / "isolated").strip(),
        "nohz_full": read_text(root / "nohz_full").strip(),
    }


def parse_metadata(text: str) -> dict[str, Any]:
    state: dict[tuple[int, str], str] = {}
    seen: set[tuple[int, str]] = set()
    transitions: list[dict[str, Any]] = []
    events: list[dict[str, Any]] = []
    update_pattern = re.compile(r"update:\s+id:(\d+)\s+key:'([^']+)'\s+value:'([^']*)'")
    null_pattern = re.compile(r"update:\s+id:(\d+)\s+key:'([^']+)'\s+value:\(null\)")
    remove_pattern = re.compile(r"remove:\s+id:(\d+)\s+key:'([^']+)'")
    remove_all_pattern = re.compile(r"remove:\s+id:(\d+)\s+all keys")

    def offset_of(raw_line: str) -> float | None:
        if "\t" not in raw_line:
            return None
        try:
            return float(raw_line.split("\t", 1)[0])
        except ValueError:
            return None

    def transition(subject_id: int, key: str, value: str | None, operation: str,
                   offset: float | None) -> None:
        identity = (subject_id, key)
        previous = state.get(identity)
        if identity in seen and previous != value:
            item: dict[str, Any] = {
                "subject_id": subject_id, "key": key, "from": previous, "to": value,
                "operation": operation,
            }
            if offset is not None:
                item["offset_seconds"] = offset
            transitions.append(item)
        seen.add(identity)
        if value is None:
            state.pop(identity, None)
        else:
            state[identity] = value

    for raw_line in text.splitlines():
        line = raw_line.split("\t", 1)[-1]
        offset = offset_of(raw_line)
        match = update_pattern.search(line)
        if match:
            subject_text, key, value = match.groups()
            subject_id = int(subject_text)
            transition(subject_id, key, value, "update", offset)
            event: dict[str, Any] = {
                "subject_id": subject_id, "key": key, "value": value, "operation": "update",
            }
            if offset is not None:
                event["offset_seconds"] = offset
            events.append(event)
            continue
        match = null_pattern.search(line) or remove_pattern.search(line)
        if match:
            subject_text, key = match.groups()
            subject_id = int(subject_text)
            transition(subject_id, key, None, "remove", offset)
            event = {"subject_id": subject_id, "key": key, "value": None, "operation": "remove"}
            if offset is not None:
                event["offset_seconds"] = offset
            events.append(event)
            continue
        match = remove_all_pattern.search(line)
        if not match:
            continue
        subject_id = int(match.group(1))
        keys = sorted(key for candidate_id, key in state if candidate_id == subject_id)
        for key in keys:
            transition(subject_id, key, None, "remove-all", offset)
        event = {"subject_id": subject_id, "key": None, "value": None, "operation": "remove-all"}
        if offset is not None:
            event["offset_seconds"] = offset
        events.append(event)

    subjects: dict[str, dict[str, str]] = {}
    for (subject_id, key), value in sorted(state.items()):
        subjects.setdefault(str(subject_id), {})[key] = value
    return {
        # PipeWire's settings metadata uses subject 0. Keep this convenient
        # legacy view while preserving every subject in the structured form.
        "values": subjects.get("0", {}),
        "subjects": subjects,
        "transitions": transitions,
        "events": events,
    }


def parse_pw_top(text: str, node_pattern: str = DEFAULT_NODE_RE) -> dict[str, Any]:
    wanted = re.compile(node_pattern)
    nodes: list[dict[str, Any]] = []
    current: dict[int, dict[str, Any]] = {}
    generations: dict[int, int] = {}
    transitions: list[dict[str, Any]] = []
    lifecycle_events: list[dict[str, Any]] = []
    sample_rows = 0
    frame = -1
    for raw_line in text.splitlines():
        offset = None
        if "\t" in raw_line:
            try:
                offset = float(raw_line.split("\t", 1)[0])
            except ValueError:
                pass
        line = raw_line.split("\t", 1)[-1].strip()
        if re.match(r"^S\s+ID\s+QUANT\s+RATE\b", line):
            frame += 1
            continue
        fields = line.split(None, 10)
        if len(fields) < 10 or not fields[1].isdigit():
            continue
        node_id, quantum, rate, error = fields[1], fields[2], fields[3], fields[8]
        name = fields[10] if len(fields) > 10 else ""
        if not (rate.isdigit() and int(rate) > 0 and error.isdigit() and wanted.search(name)):
            continue
        if frame < 0:
            frame = 0
        sample_rows += 1
        numeric_id, current_err = int(node_id), int(error)
        state = current.get(numeric_id)
        split_reason = None
        if state is not None:
            if state["name"] != name:
                split_reason = "name-change-or-id-reuse"
            elif frame > state["last_frame"] + 1:
                split_reason = "disappeared-and-reappeared"
            elif current_err < state["last_err"]:
                split_reason = "error-counter-reset-or-id-reuse"
        if state is None or split_reason is not None:
            generation = generations.get(numeric_id, 0) + 1
            generations[numeric_id] = generation
            next_state: dict[str, Any] = {
                "id": numeric_id, "generation": generation, "name": name,
                "samples": 0, "first_err": current_err, "last_err": current_err,
                "err_delta": current_err if split_reason == "error-counter-reset-or-id-reuse" else 0,
                "quantums": [], "first_frame": frame, "last_frame": frame,
                "first_output_offset_seconds": offset, "last_output_offset_seconds": offset,
            }
            if split_reason is not None and state is not None:
                lifecycle_events.append({
                    "node_id": numeric_id,
                    "from_generation": state["generation"],
                    "to_generation": generation,
                    "from_name": state["name"],
                    "to_name": name,
                    "reason": split_reason,
                    "offset_seconds": offset,
                })
            nodes.append(next_state)
            current[numeric_id] = next_state
            state = next_state
        if state["samples"]:
            previous_err = state["last_err"]
            state["err_delta"] += current_err - previous_err
        state["last_err"] = current_err
        state["samples"] += 1
        state["last_frame"] = frame
        state["last_output_offset_seconds"] = offset
        if quantum.isdigit() and int(quantum) > 0:
            current_quantum = int(quantum)
            if not state["quantums"] or state["quantums"][-1] != current_quantum:
                if state["quantums"]:
                    transitions.append({
                        "node_id": numeric_id, "generation": state["generation"], "name": name,
                        "from": state["quantums"][-1], "to": current_quantum,
                    })
                state["quantums"].append(current_quantum)
    node_values = sorted(nodes, key=lambda item: (item["id"], item["generation"]))
    instrumented = any(item["samples"] >= 2 for item in node_values)
    return {
        "node_pattern": node_pattern,
        "sample_rows": sample_rows,
        "instrumented": instrumented,
        "err_delta": sum(max(0, item["err_delta"]) for item in node_values),
        "nodes": node_values,
        "quantum_transitions": transitions,
        "node_lifecycle_events": lifecycle_events,
        "identity_confounded": bool(lifecycle_events),
    }


def parse_osc(text: str) -> dict[str, Any]:
    averages: list[float] = []
    peaks: list[float] = []
    addresses: dict[str, int] = {}
    undecodable = 0
    for raw_line in text.splitlines():
        line = raw_line.split("\t", 1)[-1]
        fields = line.split()
        if len(fields) < 2:
            continue
        address = fields[1]
        addresses[address] = addresses.get(address, 0) + 1
        if address == "undecodable":
            undecodable += 1
        if address != "/abl/bench/cpu" or len(fields) < 4:
            continue
        try:
            average, peak = float(fields[2]), float(fields[3])
        except ValueError:
            continue
        if average >= 0:
            averages.append(average)
        if peak >= 0:
            peaks.append(peak)
    return {
        "instrumented": bool(averages),
        "sample_count": len(averages),
        "average_percent": round(sum(averages) / len(averages), 3) if averages else None,
        "peak_percent": max(peaks) if peaks else None,
        "addresses": addresses,
        "undecodable": undecodable,
    }


def parse_proc_stat(text: str) -> dict[str, Any] | None:
    right = text.rfind(")")
    left = text.find("(")
    if left < 0 or right < left:
        return None
    try:
        pid = int(text[:left].strip())
        fields = text[right + 2 :].split()
        return {
            "pid": pid,
            "comm": text[left + 1 : right],
            "state": fields[0],
            "ppid": int(fields[1]),
            "utime_ticks": int(fields[11]),
            "stime_ticks": int(fields[12]),
            "num_threads": int(fields[17]),
            "starttime_ticks": int(fields[19]),
            "processor": int(fields[36]) if len(fields) > 36 else None,
            "rt_priority": int(fields[37]) if len(fields) > 37 else None,
            "policy": int(fields[38]) if len(fields) > 38 else None,
        }
    except (IndexError, ValueError):
        return None


def status_values(text: str) -> dict[str, Any]:
    wanted = {
        "Name", "VmRSS", "voluntary_ctxt_switches", "nonvoluntary_ctxt_switches",
        "Cpus_allowed_list", "Mems_allowed_list",
    }
    values: dict[str, Any] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        if key not in wanted:
            continue
        value = value.strip()
        if key.endswith("ctxt_switches"):
            try:
                values[key] = int(value)
            except ValueError:
                values[key] = None
        else:
            values[key] = value
    return values


def schedstat_values(text: str) -> dict[str, int] | None:
    fields = text.split()
    if len(fields) < 3 or not all(field.isdigit() for field in fields[:3]):
        return None
    return {"runtime_ns": int(fields[0]), "run_delay_ns": int(fields[1]), "timeslices": int(fields[2])}


def selected_environment(pid: int) -> dict[str, str]:
    allowed_prefixes = (
        "ABLETON_", "PIPEASIO_", "WINE", "WINED3D_", "WEBVIEW2_", "PIPEWIRE_",
    )
    result: dict[str, str] = {}
    try:
        for item in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"):
            if b"=" not in item:
                continue
            key, value = item.split(b"=", 1)
            name = key.decode(errors="replace")
            if name.startswith(allowed_prefixes):
                result[name] = value.decode(errors="replace")
    except OSError:
        pass
    return result


def proc_record(pid: int, include_threads: bool = True) -> dict[str, Any] | None:
    base = Path(f"/proc/{pid}")
    stat = parse_proc_stat(read_text(base / "stat"))
    if not stat:
        return None
    record: dict[str, Any] = stat
    record["status"] = status_values(read_text(base / "status"))
    record["schedstat"] = schedstat_values(read_text(base / "schedstat"))
    try:
        record["exe"] = str((base / "exe").resolve(strict=True))
    except OSError:
        record["exe"] = None
    try:
        record["cmdline"] = [
            item.decode(errors="replace") for item in (base / "cmdline").read_bytes().split(b"\0") if item
        ]
    except OSError:
        record["cmdline"] = []
    record["environment"] = selected_environment(pid)
    record["threads"] = []
    if include_threads:
        try:
            tids = sorted(int(path.name) for path in (base / "task").iterdir() if path.name.isdigit())
        except OSError:
            tids = []
        for tid in tids:
            task = base / "task" / str(tid)
            thread_stat = parse_proc_stat(read_text(task / "stat"))
            if not thread_stat:
                continue
            thread_stat["status"] = status_values(read_text(task / "status"))
            thread_stat["schedstat"] = schedstat_values(read_text(task / "schedstat"))
            record["threads"].append(thread_stat)
    return record


def pid_uses_prefix_runtime(pid: int, prefix: Path, wine_root: Path) -> bool:
    env = selected_environment(pid)
    if env.get("WINEPREFIX") != str(prefix):
        return False
    try:
        executable = (Path(f"/proc/{pid}") / "exe").resolve(strict=True)
        executable.relative_to(wine_root)
        return True
    except (OSError, ValueError):
        return False


def relevant_pids(prefix: Path, wine_root: Path, explicit: Iterable[int]) -> list[int]:
    values = set(explicit)
    try:
        proc_paths = list(Path("/proc").iterdir())
    except OSError:
        proc_paths = []
    for path in proc_paths:
        if not path.name.isdigit():
            continue
        pid = int(path.name)
        if pid_uses_prefix_runtime(pid, prefix, wine_root):
            values.add(pid)
            continue
        comm = read_text(path / "comm").strip()
        if comm in {"pipewire", "pipewire-pulse", "wireplumber"}:
            values.add(pid)
    return sorted(values)


def host_cpu_snapshot() -> dict[str, list[int]]:
    values: dict[str, list[int]] = {}
    for line in read_text(Path("/proc/stat")).splitlines():
        fields = line.split()
        if not fields or not re.fullmatch(r"cpu\d*", fields[0]):
            continue
        try:
            values[fields[0]] = [int(value) for value in fields[1:]]
        except ValueError:
            continue
    return values


def proc_snapshot(prefix: Path, wine_root: Path, explicit: Iterable[int]) -> dict[str, Any]:
    begin_ns = time.monotonic_ns()
    capture_started_at = utc_now()
    processes = []
    for pid in relevant_pids(prefix, wine_root, explicit):
        record = proc_record(pid)
        if record:
            processes.append(record)
    host_cpu = host_cpu_snapshot()
    end_ns = time.monotonic_ns()
    return {
        "capture_started_at": capture_started_at,
        "captured_at": utc_now(),
        "monotonic_begin_ns": begin_ns,
        "monotonic_end_ns": end_ns,
        "monotonic_ns": (begin_ns + end_ns) // 2,
        "collection_seconds": round((end_ns - begin_ns) / 1_000_000_000, 6),
        "clock_ticks_per_second": os.sysconf("SC_CLK_TCK"),
        "host_cpu": host_cpu,
        "processes": processes,
    }


def counter_delta(before: int | None, after: int | None) -> int | None:
    if before is None or after is None or after < before:
        return None
    return after - before


def sched_delta(before: dict[str, int] | None, after: dict[str, int] | None) -> dict[str, int | None]:
    keys = ("runtime_ns", "run_delay_ns", "timeslices")
    return {key: counter_delta((before or {}).get(key), (after or {}).get(key)) for key in keys}


def one_record_delta(before: dict[str, Any], after: dict[str, Any], elapsed: float, ticks: int) -> dict[str, Any]:
    cpu_ticks = counter_delta(
        before["utime_ticks"] + before["stime_ticks"],
        after["utime_ticks"] + after["stime_ticks"],
    )
    status_before, status_after = before.get("status", {}), after.get("status", {})
    voluntary = counter_delta(status_before.get("voluntary_ctxt_switches"), status_after.get("voluntary_ctxt_switches"))
    involuntary = counter_delta(
        status_before.get("nonvoluntary_ctxt_switches"), status_after.get("nonvoluntary_ctxt_switches")
    )
    return {
        "pid": after["pid"],
        "comm": after["comm"],
        "cmdline": after.get("cmdline", []),
        "exe": after.get("exe"),
        "processor_at_end": after.get("processor"),
        "rt_priority_at_end": after.get("rt_priority"),
        "policy_at_end": after.get("policy"),
        "cpu_ticks": cpu_ticks,
        "cpu_percent_of_one_core": round(cpu_ticks / ticks / elapsed * 100, 4) if cpu_ticks is not None else None,
        "voluntary_context_switches": voluntary,
        "involuntary_context_switches": involuntary,
        "context_switches": voluntary + involuntary if voluntary is not None and involuntary is not None else None,
        "schedstat": sched_delta(before.get("schedstat"), after.get("schedstat")),
        "cpus_allowed_list": status_after.get("Cpus_allowed_list"),
    }


def host_cpu_delta(before: dict[str, list[int]], after: dict[str, list[int]]) -> dict[str, float | None]:
    result: dict[str, float | None] = {}
    for name, final in after.items():
        initial = before.get(name)
        if not initial:
            result[name] = None
            continue
        length = min(len(initial), len(final))
        deltas = [max(0, final[index] - initial[index]) for index in range(length)]
        total = sum(deltas)
        idle = sum(deltas[index] for index in (3, 4) if index < length)
        result[name] = round((total - idle) / total * 100, 4) if total else None
    return result


def task_identity(record: dict[str, Any]) -> tuple[int, int]:
    return int(record["pid"]), int(record["starttime_ticks"])


def lifecycle_record(record: dict[str, Any], process: dict[str, Any] | None = None) -> dict[str, Any]:
    result = {
        "pid": record["pid"],
        "starttime_ticks": record["starttime_ticks"],
        "comm": record.get("comm"),
    }
    if process is None:
        result.update({"exe": record.get("exe"), "cmdline": record.get("cmdline", [])})
    else:
        result.update({
            "process_pid": process["pid"],
            "process_starttime_ticks": process["starttime_ticks"],
            "process_comm": process.get("comm"),
        })
    return result


def thread_lifecycle(snapshot: dict[str, Any]) -> dict[tuple[int, int, int, int], tuple[dict[str, Any], dict[str, Any]]]:
    result = {}
    for process in snapshot.get("processes", []):
        for thread in process.get("threads", []):
            key = (*task_identity(process), *task_identity(thread))
            result[key] = (process, thread)
    return result


def snapshots_delta(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    elapsed = max(0.000001, (after["monotonic_ns"] - before["monotonic_ns"]) / 1_000_000_000)
    before_begin = before.get("monotonic_begin_ns", before["monotonic_ns"])
    before_end = before.get("monotonic_end_ns", before["monotonic_ns"])
    after_begin = after.get("monotonic_begin_ns", after["monotonic_ns"])
    after_end = after.get("monotonic_end_ns", after["monotonic_ns"])
    ticks = int(before["clock_ticks_per_second"])
    initial = {task_identity(item): item for item in before["processes"]}
    final = {task_identity(item): item for item in after["processes"]}
    survivor_keys = sorted(initial.keys() & final.keys())
    born_keys = sorted(final.keys() - initial.keys())
    exited_keys = sorted(initial.keys() - final.keys())
    thread_initial = thread_lifecycle(before)
    thread_final = thread_lifecycle(after)
    thread_survivor_keys = sorted(thread_initial.keys() & thread_final.keys())
    thread_born_keys = sorted(thread_final.keys() - thread_initial.keys())
    thread_exited_keys = sorted(thread_initial.keys() - thread_final.keys())
    processes = []
    for identity in survivor_keys:
        first, last = initial[identity], final[identity]
        result = one_record_delta(first, last, elapsed, ticks)
        first_threads = {task_identity(item): item for item in first.get("threads", [])}
        threads = []
        for thread_last in last.get("threads", []):
            thread_first = first_threads.get(task_identity(thread_last))
            if thread_first:
                threads.append(one_record_delta(thread_first, thread_last, elapsed, ticks))
        result["threads"] = threads
        processes.append(result)
    churn = bool(born_keys or exited_keys or thread_born_keys or thread_exited_keys)
    return {
        "elapsed_seconds": round(elapsed, 6),
        "elapsed_lower_bound_seconds": round(max(0, after_begin - before_end) / 1_000_000_000, 6),
        "elapsed_upper_bound_seconds": round(max(0, after_end - before_begin) / 1_000_000_000, 6),
        "elapsed_scope": "Midpoint estimate and bounds from the two endpoint snapshot collection intervals.",
        "host_cpu_percent": host_cpu_delta(before.get("host_cpu", {}), after.get("host_cpu", {})),
        "processes": processes,
        "accounting": {
            "mode": "endpoint-survivors-only",
            "confounder": "task-churn-detected" if churn else "no-endpoint-task-churn-observed",
            "confounded_by_task_churn": churn,
            "processes": {
                "survived": [lifecycle_record(final[key]) for key in survivor_keys],
                "born": [lifecycle_record(final[key]) for key in born_keys],
                "exited": [lifecycle_record(initial[key]) for key in exited_keys],
            },
            "threads": {
                "survived": [lifecycle_record(thread_final[key][1], thread_final[key][0])
                             for key in thread_survivor_keys],
                "born": [lifecycle_record(thread_final[key][1], thread_final[key][0])
                         for key in thread_born_keys],
                "exited": [lifecycle_record(thread_initial[key][1], thread_initial[key][0])
                           for key in thread_exited_keys],
            },
            "limitation": (
                "Per-task CPU, context-switch, and schedstat deltas cover only identities present at both "
                "endpoint snapshots. Tasks born and exited entirely between endpoints cannot be observed; "
                "host CPU still covers the full endpoint interval."
            ),
        },
    }


class TimedCommand:
    def __init__(self, name: str, argv: list[str], raw_dir: Path, start_ns: int):
        self.name = name
        self.argv = argv
        self.path = raw_dir / f"{name}.tsv"
        self.stderr_path = raw_dir / f"{name}.stderr.txt"
        self.start_ns = start_ns
        self.process: subprocess.Popen[str] | None = None
        self.thread: threading.Thread | None = None
        self.error: str | None = None
        self.start_attempt_ns: int | None = None
        self.spawned_ns: int | None = None
        self.first_output_ns: int | None = None
        self.last_output_ns: int | None = None
        self.deadline_observed_ns: int | None = None
        self.termination_requested_ns: int | None = None
        self.reaped_ns: int | None = None
        self.output_line_count = 0

    def offset_seconds(self, value: int | None) -> float | None:
        return round((value - self.start_ns) / 1_000_000_000, 6) if value is not None else None

    def start(self) -> None:
        self.start_attempt_ns = time.monotonic_ns()
        if not self.argv or not shutil.which(self.argv[0]):
            self.error = f"command not found: {self.argv[0] if self.argv else 'empty command'}"
            self.path.write_text("")
            self.stderr_path.write_text(self.error + "\n")
            return
        stderr = self.stderr_path.open("w")
        try:
            self.process = subprocess.Popen(
                self.argv,
                stdout=subprocess.PIPE,
                stderr=stderr,
                text=True,
                errors="replace",
                bufsize=1,
            )
            self.spawned_ns = time.monotonic_ns()
            stderr.close()
        except OSError as error:
            stderr.close()
            self.error = str(error)
            self.path.write_text("")
            self.stderr_path.write_text(self.error + "\n")
            return

        def reader() -> None:
            assert self.process is not None and self.process.stdout is not None
            with self.process.stdout, self.path.open("w") as output:
                for line in self.process.stdout:
                    observed_ns = time.monotonic_ns()
                    if self.first_output_ns is None:
                        self.first_output_ns = observed_ns
                    self.last_output_ns = observed_ns
                    self.output_line_count += 1
                    offset = (observed_ns - self.start_ns) / 1_000_000_000
                    output.write(f"{offset:.6f}\t{line}")
                    output.flush()

        self.thread = threading.Thread(target=reader, name=f"capture-{self.name}", daemon=True)
        self.thread.start()

    def stop(self) -> dict[str, Any]:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        if self.thread:
            self.thread.join(timeout=2)
        if self.process is not None:
            self.reaped_ns = time.monotonic_ns()
        observed_end_ns = self.termination_requested_ns or self.deadline_observed_ns or self.reaped_ns
        supervision_seconds = None
        if self.spawned_ns is not None and observed_end_ns is not None:
            supervision_seconds = round(max(0, observed_end_ns - self.spawned_ns) / 1_000_000_000, 6)
        output_span_seconds = None
        if self.first_output_ns is not None and self.last_output_ns is not None:
            output_span_seconds = round((self.last_output_ns - self.first_output_ns) / 1_000_000_000, 6)
        return {
            "argv": self.argv,
            "available": self.error is None,
            "error": self.error,
            "returncode": self.process.returncode if self.process else None,
            "raw": str(self.path),
            "stderr": str(self.stderr_path),
            "timing": {
                "start_attempt_offset_seconds": self.offset_seconds(self.start_attempt_ns),
                "spawned_offset_seconds": self.offset_seconds(self.spawned_ns),
                "deadline_observed_offset_seconds": self.offset_seconds(self.deadline_observed_ns),
                "termination_requested_offset_seconds": self.offset_seconds(self.termination_requested_ns),
                "reaped_offset_seconds": self.offset_seconds(self.reaped_ns),
                "supervision_interval_seconds": supervision_seconds,
                "first_output_offset_seconds": self.offset_seconds(self.first_output_ns),
                "last_output_offset_seconds": self.offset_seconds(self.last_output_ns),
                "output_span_seconds": output_span_seconds,
                "output_line_count": self.output_line_count,
                "scope": (
                    "Process supervision times are monotonic observations; first/last output bound emitted "
                    "evidence and are not claims about unobserved samples."
                ),
            },
        }

    def terminate_at_deadline(self) -> None:
        self.deadline_observed_ns = time.monotonic_ns()
        if self.process and self.process.poll() is None:
            self.termination_requested_ns = time.monotonic_ns()
            self.process.terminate()


def find_live_logs(prefix: Path) -> list[Path]:
    root = prefix / "drive_c/users"
    try:
        logs = list(root.glob("*/AppData/Roaming/Ableton/Live */Preferences/Log.txt"))
    except OSError:
        logs = []
    return sorted(logs, key=lambda item: item.stat().st_mtime if item.exists() else 0, reverse=True)[:3]


def log_baselines(paths: Iterable[Path]) -> list[dict[str, Any]]:
    values = []
    for path in paths:
        try:
            stat = path.stat()
            values.append({"path": str(path), "size": stat.st_size, "mtime_ns": stat.st_mtime_ns})
        except OSError:
            values.append({"path": str(path), "size": None, "mtime_ns": None})
    return values


def capture_log_context(baselines: list[dict[str, Any]], raw_dir: Path, limit: int = 512 * 1024) -> list[str]:
    contexts = []
    for index, baseline in enumerate(baselines, 1):
        path = Path(baseline["path"])
        output = raw_dir / f"log-{index}-pre-window-tail.txt"
        data = b""
        try:
            with path.open("rb") as source:
                size = baseline.get("size") or 0
                source.seek(max(0, size - limit))
                data = source.read(limit)
        except OSError as error:
            data = f"unable to read {path}: {error}\n".encode()
        output.write_bytes(data)
        contexts.append(data.decode(errors="replace"))
    return contexts


def parse_live_log_identity(text: str) -> dict[str, Any]:
    identity: dict[str, Any] = {"version": None, "build": None, "options": []}
    fields = {
        "Init: CPU Count:": "reported_logical_cpus",
        "Init: Logical High-Performance Core Count:": "reported_performance_cpus",
        "Init: Logical Power-Efficient Core Count:": "reported_efficiency_cpus",
        "Init: CPU Count For Real-Time Threads:": "reported_realtime_cpus",
        "Audio In Out: Sample Rate:": "sample_rate",
        "Audio In Out: Input Buffer Size:": "input_buffer_frames",
        "Audio In Out: Output Buffer Size:": "output_buffer_frames",
    }
    for line in text.splitlines():
        started = re.search(r"Started:\s+Live\s+([^\s]+)\s+Build:\s+(\S+)", line)
        if started:
            identity = {"version": started.group(1), "build": started.group(2), "options": []}
            continue
        option = re.search(r"\bOptions:\s+(.+)$", line)
        if option and option.group(1) != "initialization done":
            identity["options"].append(option.group(1))
        for marker, key in fields.items():
            if marker not in line:
                continue
            match = re.search(re.escape(marker) + r"\s*([0-9]+)", line)
            if match:
                identity[key] = int(match.group(1))
    worker = None
    for option in identity["options"]:
        match = re.fullmatch(r"-MaxAudioThreads(?:=|\s+)([1-9]|[1-5][0-9]|6[0-3])", option)
        if match:
            worker = int(match.group(1))
    identity["max_audio_threads_option"] = worker
    return identity


def capture_log_slices(baselines: list[dict[str, Any]], raw_dir: Path) -> dict[str, Any]:
    results = []
    hits: list[str] = []
    for index, baseline in enumerate(baselines, 1):
        path = Path(baseline["path"])
        output = raw_dir / f"log-{index}-window.txt"
        rotated = False
        data = b""
        try:
            current_size = path.stat().st_size
            offset = baseline["size"] if baseline["size"] is not None else 0
            if current_size < offset:
                offset, rotated = 0, True
            with path.open("rb") as source:
                source.seek(offset)
                data = source.read()
        except OSError as error:
            output.write_text(f"unable to read {path}: {error}\n")
            results.append({"path": str(path), "raw": str(output), "available": False, "error": str(error)})
            continue
        output.write_bytes(data)
        text = data.decode(errors="replace")
        current_hits = [line for line in text.splitlines() if XRUN_RE.search(line)]
        hits.extend(f"{path}: {line}" for line in current_hits)
        results.append({
            "path": str(path), "raw": str(output), "available": True,
            "bytes": len(data), "rotated": rotated, "xrun_lines": len(current_hits),
        })
    (raw_dir / "xrun-log-lines.txt").write_text("\n".join(hits) + ("\n" if hits else ""))
    return {"files": results, "xrun_line_count": len(hits), "xrun_lines_raw": str(raw_dir / "xrun-log-lines.txt")}


def crackle_status(instrumented: bool, err_delta: int, log_hits: int, manual: str) -> dict[str, Any]:
    bases = []
    if err_delta > 0:
        bases.append("pipewire-err-delta")
    if log_hits > 0:
        bases.append("xrun-log-lines")
    if bases:
        status = "detected"
    elif manual == "heard":
        status, bases = "manual", ["operator-heard-crackle"]
    elif instrumented:
        status, bases = "no-instrumented-evidence", ["instrumentation-clean"]
    else:
        status, bases = "unknown", ["instrumentation-unavailable"]
    return {
        "status": status,
        "basis": bases,
        "manual_observation": manual,
        "semantics": {
            "detected": "A PipeWire ERR counter increased or an xrun-like diagnostic was logged.",
            "manual": "The operator heard crackle without a corroborating instrumented event.",
            "no-instrumented-evidence": "Usable counters were clean; this does not prove inaudibility.",
            "unknown": "No usable instrumented evidence was captured and no positive manual observation exists.",
        },
    }


def process_groups(delta: dict[str, Any], prefix: Path, wine_root: Path) -> dict[str, Any]:
    groups: dict[str, list[dict[str, Any]]] = {"live": [], "wine_prefix": [], "pipewire": []}
    for process in delta["processes"]:
        command = " ".join(process.get("cmdline", []))
        executable = process.get("exe") or ""
        if "Ableton Live" in command and ".exe" in command:
            groups["live"].append(process)
        try:
            Path(executable).relative_to(wine_root)
            groups["wine_prefix"].append(process)
        except (TypeError, ValueError):
            pass
        if process["comm"] in {"pipewire", "pipewire-pulse", "wireplumber"}:
            groups["pipewire"].append(process)
    summary: dict[str, Any] = {}
    for name, values in groups.items():
        cpu_values = [item["cpu_percent_of_one_core"] for item in values if item["cpu_percent_of_one_core"] is not None]
        context_values = [item["context_switches"] for item in values if item["context_switches"] is not None]
        summary[name] = {
            "cpu_percent_of_one_core": round(sum(cpu_values), 4) if cpu_values else None,
            "context_switches": sum(context_values) if context_values else None,
            "pids": [item["pid"] for item in values],
        }
        if name == "live":
            threads = [thread for process in values for thread in process.get("threads", [])]
            summary[name]["thread_count"] = len(threads)
            summary[name]["audio_worker_count"] = sum(thread.get("comm") == "AudioCalc" for thread in threads)
    return summary


def capture(args: argparse.Namespace) -> int:
    output = Path(args.output).resolve()
    raw = output / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    prefix, wine_root = Path(args.prefix).resolve(), Path(args.wine_root).resolve()
    explicit = [int(value) for value in args.live_pid]
    log_paths = find_live_logs(prefix)
    log_paths.extend(Path(value).resolve() for value in args.log)
    # Stable de-duplication keeps the raw filenames deterministic.
    log_paths = list(dict.fromkeys(log_paths))
    baselines = log_baselines(log_paths)
    dump_json(raw / "log-baselines.json", baselines)
    log_contexts = capture_log_context(baselines, raw)
    live_identity = parse_live_log_identity(log_contexts[0] if log_contexts else "")

    before = proc_snapshot(prefix, wine_root, explicit)
    dump_json(raw / "proc-before.json", before)
    started_at = utc_now()
    start_ns = time.monotonic_ns()
    pw_top_argv = ["pw-top", "-b"]
    metadata_argv = ["pw-metadata", "-m", "-n", "settings"]
    if shutil.which("stdbuf"):
        if shutil.which("pw-top"):
            pw_top_argv = ["stdbuf", "-oL", *pw_top_argv]
        if shutil.which("pw-metadata"):
            metadata_argv = ["stdbuf", "-oL", *metadata_argv]
    commands = [
        TimedCommand("pw-top", pw_top_argv, raw, start_ns),
        TimedCommand("pw-metadata", metadata_argv, raw, start_ns),
    ]
    if args.osc == "on":
        commands.append(TimedCommand(
            "osc", [sys.executable, args.osc_tool, "dump", "--duration", str(args.duration)], raw, start_ns
        ))
    else:
        (raw / "osc.tsv").write_text("")
        (raw / "osc.stderr.txt").write_text("OSC disabled for this set\n")
    for command in commands:
        command.start()
    deadline_ns = start_ns + int(args.duration * 1_000_000_000)
    while True:
        remaining = (deadline_ns - time.monotonic_ns()) / 1_000_000_000
        if remaining <= 0:
            break
        time.sleep(min(remaining, 0.25))
    # Signal every external collector at the shared deadline before the more
    # expensive per-thread end snapshot. stop() below only reaps/escalates.
    for command in commands:
        command.terminate_at_deadline()
    after = proc_snapshot(prefix, wine_root, explicit)
    ended_at = utc_now()
    command_results = {command.name: command.stop() for command in commands}
    if args.osc == "off":
        command_results["osc"] = {"available": False, "reason": "set-has-no-controller"}
    dump_json(raw / "proc-after.json", after)
    delta = snapshots_delta(before, after)
    dump_json(raw / "proc-delta.json", delta)

    pw_top = parse_pw_top(read_text(raw / "pw-top.tsv"), args.node_pattern)
    metadata = parse_metadata(read_text(raw / "pw-metadata.tsv"))
    osc = parse_osc(read_text(raw / "osc.tsv"))
    logs = capture_log_slices(baselines, raw)
    crackle = crackle_status(
        pw_top["instrumented"] and not pw_top["identity_confounded"],
        pw_top["err_delta"], logs["xrun_line_count"], args.manual_crackle,
    )
    confounders = []
    accounting = delta["accounting"]
    if accounting["confounded_by_task_churn"]:
        confounders.append({
            "kind": "task-churn",
            "effect": "Per-process/thread CPU totals omit tasks without both endpoint snapshots.",
        })
    if pw_top["identity_confounded"]:
        confounders.append({
            "kind": "pipewire-node-identity-churn",
            "effect": "ERR and quantum histories are separated into generations; clean instrumentation is not claimed.",
        })
    measurement = {
        "schema": SCHEMA,
        "kind": "set-measurement",
        "set": args.set_name,
        "mode": args.mode,
        "run_id": args.run_id,
        "duration_seconds": args.duration,
        "started_at": started_at,
        "ended_at": ended_at,
        "cpu_interval_midpoint_estimate_seconds": delta["elapsed_seconds"],
        "window": {
            "requested_duration_seconds": args.duration,
            "monotonic_start_ns": start_ns,
            "monotonic_deadline_ns": deadline_ns,
            "cpu_before_offset_seconds": round((before["monotonic_ns"] - start_ns) / 1_000_000_000, 6),
            "cpu_after_offset_seconds": round((after["monotonic_ns"] - start_ns) / 1_000_000_000, 6),
            "cpu_before_collection_offsets_seconds": [
                round((before.get("monotonic_begin_ns", before["monotonic_ns"]) - start_ns) / 1_000_000_000, 6),
                round((before.get("monotonic_end_ns", before["monotonic_ns"]) - start_ns) / 1_000_000_000, 6),
            ],
            "cpu_after_collection_offsets_seconds": [
                round((after.get("monotonic_begin_ns", after["monotonic_ns"]) - start_ns) / 1_000_000_000, 6),
                round((after.get("monotonic_end_ns", after["monotonic_ns"]) - start_ns) / 1_000_000_000, 6),
            ],
            "cpu_interval_midpoint_estimate_seconds": delta["elapsed_seconds"],
            "cpu_interval_bounds_seconds": [
                delta["elapsed_lower_bound_seconds"], delta["elapsed_upper_bound_seconds"],
            ],
            "scope": (
                "The requested deadline is shared. Endpoint CPU accounting includes the explicitly reported "
                "snapshot skew; each external collector reports its own observed supervision/output coverage."
            ),
        },
        "process": {"summary": process_groups(delta, prefix, wine_root), "details": delta},
        "pipewire": {"pw_top": pw_top, "settings": metadata},
        "osc_dsp": osc,
        "logs": logs,
        "live": live_identity,
        "crackle": crackle,
        "confounders": confounders,
        "capture_commands": command_results,
        "evidence": {
            "directory": "raw",
            "proc_before": "raw/proc-before.json",
            "proc_after": "raw/proc-after.json",
            "proc_delta": "raw/proc-delta.json",
            "pw_top": "raw/pw-top.tsv",
            "pw_metadata": "raw/pw-metadata.tsv",
            "osc": "raw/osc.tsv",
        },
    }
    dump_json(output / "measurement.json", measurement)
    return 0


def live_inventory(prefix: Path) -> dict[str, Any]:
    base = prefix / "drive_c/users"
    preferences = []
    try:
        preference_dirs = list(base.glob("*/AppData/Roaming/Ableton/Live */Preferences"))
    except OSError:
        preference_dirs = []
    for directory in sorted(preference_dirs, key=lambda path: path.parent.name):
        options = directory / "Options.txt"
        option_lines = [line.rstrip("\r") for line in read_text(options).splitlines() if line.strip()]
        workers = None
        for line in option_lines:
            match = re.fullmatch(r"-MaxAudioThreads(?:=|\s+)([1-9]|[1-5][0-9]|6[0-3])\s*", line)
            if match:
                workers = int(match.group(1))
        preferences.append({
            "version": directory.parent.name.removeprefix("Live "),
            "directory": str(directory),
            "options": option_lines,
            "options_hash": sha256_file(options),
            "max_audio_threads": workers,
        })
    executables = []
    try:
        exe_paths = list((prefix / "drive_c/ProgramData/Ableton").glob("*/Program/Ableton Live*.exe"))
    except OSError:
        exe_paths = []
    for path in sorted(exe_paths):
        record = sha256_file(path)
        helper = Path(__file__).resolve().parent / "lib/live-options.sh"
        try:
            completed = subprocess.run(
                ["bash", "-c", '. "$1"; ableton_live_product_version "$2"', "bench-version", str(helper), str(path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=15,
                check=False,
            )
            record["product_version"] = completed.stdout.strip() if completed.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            record["product_version"] = None
        executables.append(record)
    return {"preferences": preferences, "executables": executables}


def profile(args: argparse.Namespace) -> int:
    output = Path(args.output).resolve()
    raw = output / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    prefix, wine_root = Path(args.prefix).resolve(), Path(args.wine_root).resolve()
    capture_started_at = utc_now()
    commands: dict[str, list[str]] = {
        "uname": ["uname", "-a"],
        "lscpu-json": ["lscpu", "-J"],
        "lscpu-topology": ["lscpu", "-e=CPU,NODE,SOCKET,CORE,ONLINE,MAXMHZ,MINMHZ,MHZ"],
        "lspci": ["lspci", "-nnk"],
        "lsusb": ["lsusb"],
        "glxinfo": ["glxinfo", "-B"],
        "vulkaninfo": ["vulkaninfo", "--summary"],
        "aplay": ["aplay", "-l"],
        "arecord": ["arecord", "-l"],
        "wpctl-status": ["wpctl", "status"],
        "wpctl-sink": ["wpctl", "inspect", "-a", "@DEFAULT_AUDIO_SINK@"],
        "wpctl-source": ["wpctl", "inspect", "-a", "@DEFAULT_AUDIO_SOURCE@"],
        "pw-metadata-settings": ["pw-metadata", "-n", "settings"],
        "pw-dump": ["pw-dump"],
        "pw-cli-version": ["pw-cli", "--version"],
        "pipewire-version": ["pipewire", "--version"],
        "wireplumber-version": ["wireplumber", "--version"],
        "power-profile": ["powerprofilesctl", "get"],
    }
    results = {name: command_capture(name, argv, raw, 20 if name == "pw-dump" else 10) for name, argv in commands.items()}
    static_files = {
        "os-release": Path("/etc/os-release"),
        "proc-cpuinfo": Path("/proc/cpuinfo"),
        "proc-cmdline": Path("/proc/cmdline"),
        "proc-asound-cards": Path("/proc/asound/cards"),
        "runtime-build-info": wine_root / "ABLETON-WINE-BUILD-INFO.txt",
    }
    for name, source in static_files.items():
        destination = raw / f"{name}.txt"
        destination.write_text(read_text(source))

    prefix_records = [sha256_file(prefix / name) for name in (".ableton-linux-prefix", "system.reg", "user.reg", "userdef.reg")]
    runtime_records = [sha256_file(wine_root / name) for name in (
        "ABLETON-WINE-BUILD-INFO.txt", "bin/wine",
        "lib/wine/x86_64-windows/pipeasio64.dll", "lib/wine/x86_64-unix/pipeasio64.dll.so",
    )]
    launcher_config_record = sha256_file(Path(args.config_file).resolve())
    pipeasio_config_record = effective_pipeasio_config()
    config_records = [launcher_config_record]
    if pipeasio_config_record.get("path"):
        config_records.append(pipeasio_config_record)
    dump_json(raw / "hash-manifest.json", {
        "prefix": prefix_records, "runtime": runtime_records, "configuration": config_records,
    })

    wine_version = command_capture("wine-version", [str(wine_root / "bin/wine"), "--version"], raw, 10)
    results["wine-version"] = wine_version
    metadata_text = read_text(raw / "pw-metadata-settings.stdout.txt")
    wpctl_status = read_text(raw / "wpctl-status.stdout.txt")
    wpctl_inspect = read_text(raw / "wpctl-sink.stdout.txt") + read_text(raw / "wpctl-source.stdout.txt")
    lscpu_text = read_text(raw / "lscpu-json.stdout.txt")
    topology_text = read_text(raw / "lscpu-topology.stdout.txt")
    lspci_text = read_text(raw / "lspci.stdout.txt")
    glxinfo_text = read_text(raw / "glxinfo.stdout.txt")
    alsa_cards = read_text(raw / "proc-asound-cards.txt")
    playback_devices = read_text(raw / "aplay.stdout.txt")
    capture_devices = read_text(raw / "arecord.stdout.txt")
    profile_value = {
        "schema": SCHEMA,
        "kind": "system-profile",
        "capture_started_at": capture_started_at,
        "captured_at": utc_now(),
        "system": {
            "uname": read_text(raw / "uname.stdout.txt").strip(),
            "os_release": parse_os_release(read_text(raw / "os-release.txt")),
            "cpu": parse_lscpu_json(lscpu_text),
            "cpu_topology": parse_topology_table(topology_text),
            "cpu_sysfs": cpu_sysfs_inventory(),
            "cpu_topology_raw": "raw/lscpu-topology.stdout.txt",
            "cpu_description_raw": "raw/lscpu-json.stdout.txt",
            "gpu_lines": selected_lines(lspci_text, r"VGA|3D|Display"),
            "gpu_renderer_lines": selected_lines(glxinfo_text, r"renderer|vendor|version"),
            "gpu_raw": ["raw/lspci.stdout.txt", "raw/glxinfo.stdout.txt", "raw/vulkaninfo.stdout.txt"],
            "audio_devices": {
                "alsa_cards": alsa_cards,
                "playback": playback_devices,
                "capture": capture_devices,
            },
            "audio_devices_raw": ["raw/proc-asound-cards.txt", "raw/aplay.stdout.txt", "raw/arecord.stdout.txt", "raw/lsusb.stdout.txt"],
            "power_profile": read_text(raw / "power-profile.stdout.txt").strip(),
        },
        "pipewire": {
            "versions": {
                "pipewire": read_text(raw / "pipewire-version.stdout.txt").strip(),
                "wireplumber": read_text(raw / "wireplumber-version.stdout.txt").strip(),
                "pw_cli": read_text(raw / "pw-cli-version.stdout.txt").strip(),
            },
            "settings": parse_metadata(metadata_text),
            "active_profile_lines": [
                line.strip() for line in wpctl_inspect.splitlines()
                if re.search(r"profile|route|device\.name|node\.name", line, re.I)
            ],
            "wpctl_status": wpctl_status,
            "capture_scope": {
                "phase": "single-profile-snapshot; bench-suite invokes this before its first Live launch",
                "profiles": "default sink/source and associated objects, with the complete graph retained by pw-dump",
                "settings": "settings metadata snapshot; every set separately monitors settings changes",
                "limitation": "WirePlumber profile changes during a set are not continuously monitored.",
            },
            "availability": {
                name: {
                    "installed": results[name].get("available", False),
                    "successful": (
                        results[name].get("available", False) and results[name].get("returncode") == 0
                    ),
                    "returncode": results[name].get("returncode"),
                    **({"timed_out": True} if results[name].get("timed_out") else {}),
                    **({"error": results[name]["error"]} if "error" in results[name] else {}),
                }
                for name in (
                    "wpctl-status", "wpctl-sink", "wpctl-source", "pw-metadata-settings", "pw-dump",
                    "pw-cli-version", "pipewire-version", "wireplumber-version",
                )
            },
            "raw": [
                "raw/wpctl-status.stdout.txt", "raw/wpctl-sink.stdout.txt",
                "raw/wpctl-source.stdout.txt", "raw/pw-metadata-settings.stdout.txt",
                "raw/pw-dump.stdout.txt",
            ],
        },
        "runtime": {
            "root": str(wine_root),
            "build_info": read_text(wine_root / "ABLETON-WINE-BUILD-INFO.txt"),
            "wine_version": read_text(raw / "wine-version.stdout.txt").strip(),
            "files": runtime_records,
            "identity_hash": manifest_hash(runtime_records, wine_root),
            "identity_scope": "build information, exact Wine launcher binary, and PE/Unix PipeASIO halves",
        },
        "prefix": {
            "path": str(prefix),
            "files": prefix_records,
            "identity_hash": manifest_hash(prefix_records, prefix),
            "identity_scope": "managed-prefix ownership marker and Wine registry files; not mutable cache content",
        },
        "configuration": {
            "files": config_records,
            "identity_hash": manifest_hash(config_records),
            "launcher_config": launcher_config_record,
            "pipeasio_effective_config": pipeasio_config_record,
            "environment": {
                key: value for key, value in sorted(os.environ.items())
                if key.startswith(("ABLETON_", "PIPEASIO_", "WINEDEBUG", "WINED3D_"))
            },
        },
        "live": live_inventory(prefix),
        "commands": results,
    }
    dump_json(output / "profile.json", profile_value)
    return 0


def init_run(args: argparse.Namespace) -> int:
    script_dir = Path(__file__).resolve().parent
    repository = script_dir.parent
    harness_records = [sha256_file(path) for path in (
        script_dir / "bench-report.py", script_dir / "bench-suite.sh",
        script_dir / "bench-run.sh", script_dir / "bench-osc.py",
        repository / "bench/SHA256SUMS",
    )]
    value = {
        "schema": SCHEMA,
        "kind": "benchmark-run",
        "created_at": utc_now(),
        "tag": args.tag,
        "duration_seconds_per_set": args.duration,
        "set_order": args.set,
        "suite_log": "suite.log",
        "harness": {
            "files": harness_records,
            "identity_hash": manifest_hash(harness_records, repository),
        },
        "status": "running",
    }
    dump_json(Path(args.output), value)
    return 0


def update_run(args: argparse.Namespace) -> int:
    path = Path(args.output)
    value = json.loads(path.read_text())
    value["status"] = args.status
    value["completed_at"] = utc_now()
    dump_json(path, value)
    return 0


def markdown_report(report: dict[str, Any]) -> str:
    run = report["run"]
    profile_value = report.get("profile", {})
    lines = [
        "# Ableton Linux CPU/audio benchmark",
        "",
        f"- Tag: `{run.get('tag', 'unknown')}`",
        f"- Status: `{run.get('status', 'unknown')}`",
        f"- Window: {run.get('duration_seconds_per_set', 'unknown')} seconds per set",
        f"- Harness identity SHA-256: `{run.get('harness', {}).get('identity_hash', 'unknown')}`",
        f"- Generated: {report['generated_at']}",
        "",
        "## Results",
        "",
        "| Set | Mode | Workers | Host CPU | Live CPU/core | Wine CPU/core | Task churn | PipeWire ERR | DSP avg / peak | Quantum changes | Crackle |",
        "|---|---|---:|---:|---:|---:|---|---:|---:|---:|---|",
    ]
    for item in report["sets"]:
        process = item.get("process", {}).get("summary", {})
        host = item.get("process", {}).get("details", {}).get("host_cpu_percent", {}).get("cpu")
        live = process.get("live", {}).get("cpu_percent_of_one_core")
        wine = process.get("wine_prefix", {}).get("cpu_percent_of_one_core")
        pw = item.get("pipewire", {}).get("pw_top", {})
        dsp = item.get("osc_dsp", {})
        accounting = item.get("process", {}).get("details", {}).get("accounting", {})
        process_churn = accounting.get("processes", {})
        thread_churn = accounting.get("threads", {})
        churn = (
            f"P+{len(process_churn.get('born', []))}/-{len(process_churn.get('exited', []))}; "
            f"T+{len(thread_churn.get('born', []))}/-{len(thread_churn.get('exited', []))}"
        )
        transitions = len(pw.get("quantum_transitions", [])) + len(item.get("pipewire", {}).get("settings", {}).get("transitions", []))
        number = lambda value: "NA" if value is None else f"{value:.2f}"  # noqa: E731
        lines.append(
            f"| {item.get('set')} | {item.get('mode')} | {process.get('live', {}).get('audio_worker_count', 'NA')} | "
            f"{number(host)}% | {number(live)}% | "
            f"{number(wine)}% | {churn} | {pw.get('err_delta', 'NA')} | {number(dsp.get('average_percent'))} / "
            f"{number(dsp.get('peak_percent'))} | {transitions} | {item.get('crackle', {}).get('status', 'unknown')} |"
        )
    runtime = profile_value.get("runtime", {})
    prefix = profile_value.get("prefix", {})
    live_inventory_value = profile_value.get("live", {})
    system = profile_value.get("system", {})
    cpu = system.get("cpu", {})
    pipewire = profile_value.get("pipewire", {})
    configuration = profile_value.get("configuration", {})
    settings = pipewire.get("settings", {}).get("values", {})
    pipewire_availability = pipewire.get("availability", {})
    pipewire_unavailable = (
        [name for name, status in pipewire_availability.items() if not status.get("successful")]
        if pipewire_availability else ["availability-not-recorded"]
    )
    runtime_dist = "unknown"
    for line in runtime.get("build_info", "").splitlines():
        if line.startswith("dist-version:"):
            runtime_dist = line.split(":", 1)[1].strip()
            break
    lines.extend([
        "",
        "## Reproduction identity",
        "",
        f"- System: `{profile_value.get('system', {}).get('uname', 'unknown')}`",
        f"- CPU: `{cpu.get('Model name', 'unknown')}`; logical CPUs `{cpu.get('CPU(s)', 'unknown')}`, "
        f"cores/socket `{cpu.get('Core(s) per socket', 'unknown')}`, sockets `{cpu.get('Socket(s)', 'unknown')}`",
        f"- GPU: `{'; '.join(system.get('gpu_lines', [])) or 'unknown'}`",
        f"- ALSA cards: `{' '.join(system.get('audio_devices', {}).get('alsa_cards', '').split()) or 'none reported'}`",
        f"- Power profile: `{system.get('power_profile') or 'unknown'}`",
        f"- PipeWire: `{pipewire.get('versions', {}).get('pipewire') or 'unknown'}`; "
        f"WirePlumber `{pipewire.get('versions', {}).get('wireplumber') or 'unknown'}`",
        f"- Initial graph: rate `{settings.get('clock.rate', 'unknown')}`, quantum "
        f"`{settings.get('clock.quantum', 'unknown')}`, forced quantum "
        f"`{settings.get('clock.force-quantum', 'unknown')}`",
        f"- Active audio profile evidence: `{'; '.join(pipewire.get('active_profile_lines', [])) or 'unavailable'}`",
        f"- PipeWire profile capture scope: `{pipewire.get('capture_scope', {}).get('phase', 'unknown')}`",
        f"- PipeWire snapshot command status: `{'complete' if not pipewire_unavailable else 'incomplete: ' + ', '.join(pipewire_unavailable)}`",
        f"- Runtime: build `{runtime_dist}`, Wine `{runtime.get('wine_version', 'unknown')}` at `{runtime.get('root', 'unknown')}`",
        f"- Runtime identity SHA-256: `{runtime.get('identity_hash', 'unknown')}`",
        f"- Prefix: `{prefix.get('path', 'unknown')}`",
        f"- Prefix identity SHA-256: `{prefix.get('identity_hash', 'unknown')}`",
        f"- Configuration identity SHA-256: `{profile_value.get('configuration', {}).get('identity_hash', 'unknown')}`",
        f"- Effective PipeASIO config: `{configuration.get('pipeasio_effective_config', {}).get('path') or 'unavailable'}` "
        f"(via `{configuration.get('pipeasio_effective_config', {}).get('resolution', 'unknown')}`)",
        "",
        "### Live options",
        "",
    ])
    preferences = live_inventory_value.get("preferences", [])
    executables = live_inventory_value.get("executables", [])
    if not preferences and not executables:
        lines.append("No Live executable or preferences directory was detected.")
    for executable in executables:
        lines.append(
            f"- `{Path(executable.get('path', 'unknown')).name}`: product version "
            f"`{executable.get('product_version') or 'unavailable'}`, executable SHA-256 "
            f"`{executable.get('sha256', 'absent')}`"
        )
    for preference in preferences:
        workers = preference.get("max_audio_threads")
        lines.append(
            f"- Live {preference.get('version')}: MaxAudioThreads="
            f"{workers if workers is not None else 'Live default'}; Options.txt SHA-256 "
            f"`{preference.get('options_hash', {}).get('sha256', 'absent')}`"
        )
    lines.extend([
        "",
        "## Crackle status semantics",
        "",
        "- `detected`: PipeWire ERR increased or an xrun-like diagnostic appeared.",
        "- `manual`: the operator heard crackle without a corroborating counter event.",
        "- `no-instrumented-evidence`: usable instrumentation was clean; this is not proof of inaudibility.",
        "- `unknown`: instrumentation was unavailable and no positive manual observation exists.",
        "",
        "Raw command output, endpoint task-lifecycle accounting, process/thread snapshots, schedstat deltas, context switches, collector timing, logs, OSC rows, and quantum events are retained beside this report.",
        "",
    ])
    return "\n".join(lines)


def render(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve()
    run_path = run_dir / "run.json"
    if not run_path.is_file():
        print(f"missing {run_path}", file=sys.stderr)
        return 2
    run = json.loads(run_path.read_text())
    profile_path = run_dir / "profile/profile.json"
    profile_value = json.loads(profile_path.read_text()) if profile_path.is_file() else {}
    sets = []
    for name in run.get("set_order", []):
        matches = list((run_dir / "sets").glob(f"*-{name}/measurement.json"))
        if matches:
            sets.append(json.loads(matches[0].read_text()))
    report = {
        "schema": SCHEMA,
        "kind": "benchmark-report",
        "generated_at": utc_now(),
        "run": run,
        "profile": profile_value,
        "sets": sets,
    }
    dump_json(run_dir / "report.json", report)
    (run_dir / "report.md").write_text(markdown_report(report))
    return 0


def annotate(args: argparse.Namespace) -> int:
    run_dir = Path(args.run_dir).resolve()
    matches = list((run_dir / "sets").glob(f"*-{args.set_name}/measurement.json"))
    if len(matches) != 1:
        print(f"expected one measurement for {args.set_name}, found {len(matches)}", file=sys.stderr)
        return 2
    measurement = json.loads(matches[0].read_text())
    pw_top = measurement.get("pipewire", {}).get("pw_top", {})
    logs = measurement.get("logs", {})
    measurement["crackle"] = crackle_status(
        bool(pw_top.get("instrumented")), int(pw_top.get("err_delta", 0)),
        int(logs.get("xrun_line_count", 0)), args.manual_crackle,
    )
    measurement["crackle"]["annotated_at"] = utc_now()
    dump_json(matches[0], measurement)
    return render(argparse.Namespace(run_dir=str(run_dir)))


def udp_available(args: argparse.Namespace) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("127.0.0.1", args.port))
    except OSError as error:
        print(f"UDP 127.0.0.1:{args.port} unavailable: {error}", file=sys.stderr)
        return 1
    finally:
        sock.close()
    return 0


def positive_duration(value: str) -> int:
    try:
        result = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("duration must be a whole number of seconds") from error
    if result < 1 or result > 3600:
        raise argparse.ArgumentTypeError("duration must be between 1 and 3600 seconds")
    return result


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("capture", help="capture one common measurement window")
    capture_parser.add_argument("--output", required=True)
    capture_parser.add_argument("--set-name", required=True)
    capture_parser.add_argument("--mode", choices=("idle-no-controller", "playback"), required=True)
    capture_parser.add_argument("--run-id", required=True)
    capture_parser.add_argument("--duration", type=positive_duration, default=30)
    capture_parser.add_argument("--prefix", required=True)
    capture_parser.add_argument("--wine-root", required=True)
    capture_parser.add_argument("--live-pid", action="append", default=[])
    capture_parser.add_argument("--log", action="append", default=[])
    capture_parser.add_argument("--osc", choices=("on", "off"), default="on")
    capture_parser.add_argument("--osc-tool", required=True)
    capture_parser.add_argument("--node-pattern", default=DEFAULT_NODE_RE)
    capture_parser.add_argument(
        "--manual-crackle", choices=("heard", "not-heard", "not-provided", "unknown"), default="not-provided"
    )
    capture_parser.set_defaults(func=capture)

    profile_parser = commands.add_parser("profile", help="capture the immutable run profile")
    profile_parser.add_argument("--output", required=True)
    profile_parser.add_argument("--prefix", required=True)
    profile_parser.add_argument("--wine-root", required=True)
    profile_parser.add_argument("--config-file", required=True)
    profile_parser.set_defaults(func=profile)

    init_parser = commands.add_parser("init-run")
    init_parser.add_argument("--output", required=True)
    init_parser.add_argument("--tag", required=True)
    init_parser.add_argument("--duration", type=positive_duration, default=30)
    init_parser.add_argument("--set", action="append", required=True)
    init_parser.set_defaults(func=init_run)

    update_parser = commands.add_parser("update-run")
    update_parser.add_argument("--output", required=True)
    update_parser.add_argument("--status", choices=("complete", "failed", "interrupted"), required=True)
    update_parser.set_defaults(func=update_run)

    render_parser = commands.add_parser("render")
    render_parser.add_argument("--run-dir", required=True)
    render_parser.set_defaults(func=render)

    annotate_parser = commands.add_parser("annotate", help="add a post-run manual crackle observation")
    annotate_parser.add_argument("--run-dir", required=True)
    annotate_parser.add_argument("--set-name", choices=CANONICAL_SETS, required=True)
    annotate_parser.add_argument("--manual-crackle", choices=("heard", "not-heard", "unknown"), required=True)
    annotate_parser.set_defaults(func=annotate)

    udp_parser = commands.add_parser("check-udp")
    udp_parser.add_argument("--port", type=int, default=19002)
    udp_parser.set_defaults(func=udp_available)
    return root


def main() -> int:
    args = parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
