#!/usr/bin/env python3
"""Measure Ableton and PipeASIO CPU use and create benchmark reports.

The shell suite starts and closes Live. The program records system details,
measures one timed set, and creates JSON and Markdown reports. The shell suite
also manages the Wine session.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Iterable
import uuid


SCHEMA = "ableton-linux-benchmark/v1"
CSV_SCHEMA = "ableton-linux-cpu-benchmark-csv/v1"
RESOURCE_SAMPLE_INTERVAL_SECONDS = 1
MACHINE_ID_FILENAME = "cpu-benchmark-machine-id-v1"
MACHINE_ID_RE = re.compile(r"[0-9a-f]{32}")
DEFAULT_NODE_RE = r"Ableton|Live|[Pp]ipe[Aa][Ss][Ii][Oo]"
CANONICAL_SETS = (
    "Benchmark_Zero", "Benchmark_Empty", "Benchmark_Inbuilts", "Benchmark_Max4Live", "Benchmark_VSTs",
)
CANONICAL_MODES = {
    "Benchmark_Zero": "idle-no-controller",
    "Benchmark_Empty": "playback",
    "Benchmark_Inbuilts": "playback",
    "Benchmark_Max4Live": "playback",
    "Benchmark_VSTs": "playback",
}
# The report records the Wine CPU and audio settings used by the project.
# Paths and other WINE_* values stay outside the report.
BENCHMARK_WINE_ENV_KEYS = (
    "WINE_APC_FASTPATH",
    "WINE_MSG_FASTPATH",
    "WINE_USER_APC_FASTPATH",
    "WINE_HOOK_FASTPATH",
    "WINEESYNC",
    "WINEFSYNC",
    "WINEFSYNC_FUTEX2",
    "WINE_NTSYNC",
    "STAGING_RT_PRIORITY_BASE",
    "STAGING_RT_PRIORITY_SERVER",
)
BENCHMARK_ABLETON_ENV_KEYS = (
    "ABLETON_DCOMP", "ABLETON_DPI_MODE", "ABLETON_LINKD", "ABLETON_LINKD_LINGER",
    "ABLETON_LINK_MODE", "ABLETON_MAX_AUDIO_THREADS", "ABLETON_POWER", "ABLETON_RT",
    "ABLETON_TEXT_SMOOTHING", "ABLETON_THEME_MODE", "ABLETON_TOPBAR_MODE", "ABLETON_UI_FONT",
    "ABLETON_VDESK",
)
PROFILE_ENV_EXACT_KEYS = (
    *BENCHMARK_WINE_ENV_KEYS,
    "WINEDEBUG",
)
PROFILE_ENV_PREFIXES = ("ABLETON_", "PIPEASIO_", "WINED3D_")
XRUN_RE = re.compile(
    r"\b(?:xrun|underrun|overrun)s?\b|missed.{0,24}(?:deadline|cycle)|"
    r"buffer.{0,16}(?:under|over)run",
    re.IGNORECASE,
)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def filename_timestamp(value: str) -> str:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"UTC run timestamp must use an ISO-8601 value: {value!r}") from error
    if parsed.tzinfo is None:
        raise ValueError(f"run timestamp must include a UTC offset: {value!r}")
    return parsed.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def benchmark_machine_id_path(environment: dict[str, str] | None = None) -> Path:
    values = os.environ if environment is None else environment
    config_home = values.get("ABLETON_CONFIG_HOME")
    if not config_home:
        xdg_home, home = values.get("XDG_CONFIG_HOME"), values.get("HOME")
        if xdg_home:
            config_home = str(Path(xdg_home) / "ableton-wine")
        elif home:
            config_home = str(Path(home) / ".config/ableton-wine")
    if not config_home:
        raise ValueError("set HOME, XDG_CONFIG_HOME, or ABLETON_CONFIG_HOME to store the benchmark report source ID")
    return Path(config_home) / MACHINE_ID_FILENAME


def read_benchmark_machine_id(path: Path) -> str:
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode):
            raise ValueError(f"benchmark report source ID must be a regular file: {path}")
        if details.st_uid != os.geteuid():
            raise ValueError(f"benchmark report source ID must belong to the current user: {path}")
        if stat.S_IMODE(details.st_mode) != 0o600:
            raise ValueError(f"benchmark report source ID must use mode 0600: {path}")
        with os.fdopen(descriptor) as source:
            descriptor = -1
            value = source.read(65).strip()
    except OSError as error:
        raise ValueError(f"check access to benchmark report source ID file {path}: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not MACHINE_ID_RE.fullmatch(value):
        raise ValueError(f"benchmark report source ID must contain 32 lowercase hexadecimal characters: {path}")
    return value


def load_benchmark_machine_id(
    environment: dict[str, str] | None = None,
    *,
    path: Path | None = None,
    token: str | None = None,
) -> str:
    target = path or benchmark_machine_id_path(environment)
    if target.exists() or target.is_symlink():
        return read_benchmark_machine_id(target)
    candidate = token or uuid.uuid4().hex
    if not MACHINE_ID_RE.fullmatch(candidate):
        raise ValueError("generated benchmark report source ID must contain 32 lowercase hexadecimal characters")
    descriptor = -1
    temporary: Path | None = None
    try:
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{MACHINE_ID_FILENAME}.", dir=target.parent,
        )
        temporary = Path(temporary_name)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as output:
            descriptor = -1
            output.write(candidate + "\n")
            output.flush()
            os.fsync(output.fileno())
        try:
            os.link(temporary, target, follow_symlinks=False)
        except FileExistsError:
            pass
    except OSError as error:
        raise ValueError(f"check access to benchmark report source ID location {target}: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
    return read_benchmark_machine_id(target)


def cpu_benchmark_csv_filename(machine_id: str, created_at: str) -> str:
    if not MACHINE_ID_RE.fullmatch(machine_id):
        raise ValueError("run benchmark report source ID must contain 32 lowercase hexadecimal characters")
    return f"{machine_id}-{filename_timestamp(created_at)}_cpu-benchmark.csv"


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


def benchmark_environment(environment: dict[str, str] | None = None) -> dict[str, str]:
    values = os.environ if environment is None else environment
    return {
        key: value for key, value in sorted(values.items())
        if key in PROFILE_ENV_EXACT_KEYS or key.startswith(PROFILE_ENV_PREFIXES)
    }


def benchmark_gate_environment(environment: dict[str, str] | None = None) -> dict[str, str]:
    """Return settings that can change CPU or audio results."""
    values = benchmark_environment(environment)
    return {
        key: value for key, value in values.items()
        if key in BENCHMARK_WINE_ENV_KEYS
        or key.startswith("PIPEASIO_")
        or key in BENCHMARK_ABLETON_ENV_KEYS
    }


def cpu_sysfs_inventory(root: Path = Path("/sys/devices/system/cpu")) -> dict[str, Any]:
    attributes = (
        "topology/physical_package_id", "topology/die_id", "topology/core_id",
        "topology/core_type", "topology/thread_siblings_list", "topology/core_cpus_list",
        "cpu_capacity", "online", "cpufreq/scaling_driver", "cpufreq/scaling_governor",
        "cpufreq/energy_performance_preference", "cpufreq/scaling_min_freq",
        "cpufreq/scaling_max_freq", "cpufreq/cpuinfo_max_freq",
        "acpi_cppc/highest_perf", "acpi_cppc/nominal_perf",
        "cpufreq/amd_pstate_prefcore_ranking", "cpufreq/amd_pstate_hw_prefcore",
        "cpufreq/amd_pstate_max_freq", "cpufreq/amd_pstate_highest_perf",
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
    amd_pstate = {}
    for attribute in ("status", "prefcore", "dynamic_epp"):
        value = read_text(root / "amd_pstate" / attribute).strip()
        if value:
            amd_pstate[attribute] = value
    return {
        "cpus": cpus,
        "online": read_text(root / "online").strip(),
        "offline": read_text(root / "offline").strip(),
        "isolated": read_text(root / "isolated").strip(),
        "nohz_full": read_text(root / "nohz_full").strip(),
        "amd_pstate": amd_pstate,
    }


def audio_kernel_parameters(
    root: Path = Path("/sys/module/snd_usb_audio/parameters"),
) -> dict[str, Any]:
    parameters = {}
    for name in ("lowlatency", "autoclock", "implicit_fb", "quirk_flags"):
        path = root / name
        record: dict[str, Any] = {"path": str(path), "available": False, "value": None}
        try:
            record.update(available=True, value=path.read_text(errors="replace").strip())
        except OSError as error:
            record["reason"] = str(error)
        parameters[name] = record
    return {
        "module": "snd_usb_audio",
        "available": any(item["available"] for item in parameters.values()),
        "parameters": parameters,
        "scope": "Records snd_usb_audio parameter values at the start of the run.",
    }


def cpu_policy_snapshot(
    root: Path = Path("/sys/devices/system/cpu/cpufreq"),
) -> dict[str, Any]:
    begin_ns = time.monotonic_ns()
    fields = (
        "affected_cpus", "related_cpus", "scaling_driver", "scaling_governor",
        "scaling_min_freq", "scaling_max_freq", "cpuinfo_max_freq",
        "energy_performance_preference", "energy_performance_available_preferences",
        "amd_pstate_prefcore_ranking", "amd_pstate_hw_prefcore",
        "amd_pstate_max_freq", "amd_pstate_highest_perf",
    )
    try:
        paths = sorted(
            (path for path in root.glob("policy*") if re.fullmatch(r"policy\d+", path.name)),
            key=lambda path: int(path.name.removeprefix("policy")),
        )
        error = None
    except OSError as caught:
        paths, error = [], str(caught)
    policies = []
    for path in paths:
        record: dict[str, Any] = {"policy": path.name}
        for field in fields:
            value = read_text(path / field).strip()
            if value:
                record[field] = value
        policies.append(record)
    end_ns = time.monotonic_ns()
    return {
        "available": bool(policies),
        "reason": error or (None if policies else "no-readable-cpufreq-policies"),
        "policies": policies,
        "monotonic_begin_ns": begin_ns,
        "monotonic_end_ns": end_ns,
        "monotonic_ns": (begin_ns + end_ns) // 2,
        "collection_seconds": round((end_ns - begin_ns) / 1_000_000_000, 6),
        "scope": "Records CPU policy values at each CPU sample. Use another tool for momentary frequency.",
    }


def power_endpoint_snapshot(raw_dir: Path, endpoint: str) -> dict[str, Any]:
    begin_ns = time.monotonic_ns()
    commands = {
        name: command_capture(f"power-{endpoint}-{name}", argv, raw_dir, 5)
        for name, argv in (
            ("profile", ["powerprofilesctl", "get"]),
            ("holds", ["powerprofilesctl", "list-holds"]),
        )
    }
    end_ns = time.monotonic_ns()
    successful = {name: item.get("available") and item.get("returncode") == 0 for name, item in commands.items()}
    return {
        "available": successful["profile"],
        "profile": read_text(raw_dir / f"power-{endpoint}-profile.stdout.txt").strip() or None,
        "holds_available": successful["holds"],
        "holds": read_text(raw_dir / f"power-{endpoint}-holds.stdout.txt").strip() or None,
        "commands": commands,
        "monotonic_begin_ns": begin_ns,
        "monotonic_end_ns": end_ns,
        "monotonic_ns": (begin_ns + end_ns) // 2,
        "collection_seconds": round((end_ns - begin_ns) / 1_000_000_000, 6),
        "scope": "Records the power profile and active power requests at each CPU sample.",
    }


def audio_endpoint_snapshot(raw_dir: Path, endpoint: str) -> dict[str, Any]:
    """Record default audio devices, PipeWire settings, and active links."""
    begin_ns = time.monotonic_ns()
    commands = {
        name: command_capture(f"audio-{endpoint}-{name}", argv, raw_dir, 5)
        for name, argv in (
            ("sink", ["wpctl", "inspect", "-a", "@DEFAULT_AUDIO_SINK@"]),
            ("source", ["wpctl", "inspect", "-a", "@DEFAULT_AUDIO_SOURCE@"]),
            # -l records active ports and their peers. -iol adds every input
            # and output port, which changes the meaning of the result.
            ("links", ["pw-link", "-l"]),
            ("settings", ["pw-metadata", "-n", "settings"]),
        )
    }
    end_ns = time.monotonic_ns()
    successful = {
        name: item.get("available") and item.get("returncode") == 0
        for name, item in commands.items()
    }
    property_pattern = re.compile(
        r"\b(?:api[.]alsa[.]|device[.](?:name|description|nick|serial|profile)|"
        r"node[.](?:name|description|nick)|object[.]path|media[.]class|profile[.]|route[.])",
        re.IGNORECASE,
    )

    def stable_lines(name: str, pattern: re.Pattern[str] | None = None) -> list[str]:
        text = read_text(raw_dir / f"audio-{endpoint}-{name}.stdout.txt")
        lines = (line.strip() for line in text.splitlines())
        return sorted(set(line for line in lines if line and (pattern is None or pattern.search(line))))

    settings_text = read_text(raw_dir / f"audio-{endpoint}-settings.stdout.txt")
    graph_settings = parse_metadata(settings_text).get("values", {})
    return {
        "available": all(successful.values()) and all(
            key in graph_settings for key in ("clock.rate", "clock.quantum")
        ),
        "component_availability": successful,
        "default_sink": stable_lines("sink", property_pattern),
        "default_source": stable_lines("source", property_pattern),
        # pw-link's batch output is port-name based. Sorting removes discovery
        # order while retaining the exact active graph and hardware link names.
        "links": stable_lines("links"),
        "graph_settings": graph_settings,
        "commands": commands,
        "monotonic_begin_ns": begin_ns,
        "monotonic_end_ns": end_ns,
        "monotonic_ns": (begin_ns + end_ns) // 2,
        "collection_seconds": round((end_ns - begin_ns) / 1_000_000_000, 6),
        "scope": "Records default devices, audio profile values, PipeWire settings, and active links.",
    }


def audio_endpoint_value(value: dict[str, Any]) -> dict[str, Any]:
    """Return the audio fields used to compare runs."""
    return {
        "available": value.get("available"),
        "component_availability": value.get("component_availability"),
        "default_sink": value.get("default_sink"),
        "default_source": value.get("default_source"),
        "links": value.get("links"),
        "graph_settings": value.get("graph_settings"),
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
        # PipeWire settings use subject 0. Keep a short values map and the full
        # subject and key maps.
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
    allowed_prefixes = ("ABLETON_", "PIPEASIO_", "WINED3D_", "WEBVIEW2_", "PIPEWIRE_")
    allowed_exact = set(PROFILE_ENV_EXACT_KEYS) | {
        "WINEPREFIX", "WINESERVER", "WINEDLLOVERRIDES", "WINE_D3D_CONFIG",
        "WINE_X11_FORCE_OFFSCREEN_CLASS", "WINE_WIN32_FULLSCREEN_CLASS",
        "WINE_WIN32_RESIZABLE_CLASS", "WINE_DISABLE_UNIX_MOUNT_REPARSE",
    }
    result: dict[str, str] = {}
    try:
        for item in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"):
            if b"=" not in item:
                continue
            key, value = item.split(b"=", 1)
            name = key.decode(errors="replace")
            if name in allowed_exact or name.startswith(allowed_prefixes):
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


def host_cpu_snapshot(root: Path = Path("/proc")) -> dict[str, list[int]]:
    values: dict[str, list[int]] = {}
    for line in read_text(root / "stat").splitlines():
        fields = line.split()
        if not fields or not re.fullmatch(r"cpu\d*", fields[0]):
            continue
        try:
            values[fields[0]] = [int(value) for value in fields[1:]]
        except ValueError:
            continue
    return values


def parse_meminfo(text: str) -> dict[str, int]:
    wanted = {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree"}
    values: dict[str, int] = {}
    for line in text.splitlines():
        fields = line.replace(":", " ", 1).split()
        if len(fields) < 2 or fields[0] not in wanted:
            continue
        try:
            value = int(fields[1])
        except ValueError:
            continue
        if len(fields) >= 3 and fields[2].lower() == "kb":
            value *= 1024
        values[fields[0]] = value
    return values


def parse_loadavg(text: str) -> dict[str, Any]:
    fields = text.split()
    if len(fields) < 4 or "/" not in fields[3]:
        return {}
    runnable, tasks = fields[3].split("/", 1)
    try:
        return {
            "load_1m": float(fields[0]),
            "load_5m": float(fields[1]),
            "load_15m": float(fields[2]),
            "runnable_tasks": int(runnable),
            "total_tasks": int(tasks),
        }
    except ValueError:
        return {}


def parse_pressure(text: str) -> dict[str, dict[str, float | int]]:
    values: dict[str, dict[str, float | int]] = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[0] not in {"some", "full"}:
            continue
        row: dict[str, float | int] = {}
        for field in fields[1:]:
            if "=" not in field:
                continue
            key, raw_value = field.split("=", 1)
            try:
                row[key] = int(raw_value) if key == "total" else float(raw_value)
            except ValueError:
                continue
        if "total" in row:
            values[fields[0]] = row
    return values


def filesystem_capacity(path: Path) -> dict[str, int]:
    try:
        details = os.statvfs(path)
    except OSError:
        return {}
    return {
        "total_bytes": details.f_blocks * details.f_frsize,
        "available_bytes": details.f_bavail * details.f_frsize,
    }


def system_resource_snapshot(proc_root: Path = Path("/proc")) -> dict[str, Any]:
    begin_ns = time.monotonic_ns()
    cpu = host_cpu_snapshot(proc_root)
    memory = parse_meminfo(read_text(proc_root / "meminfo"))
    load = parse_loadavg(read_text(proc_root / "loadavg"))
    pressure = {
        name: parse_pressure(read_text(proc_root / "pressure" / name))
        for name in ("cpu", "memory", "io")
    }
    end_ns = time.monotonic_ns()
    return {
        "captured_at": utc_now(),
        "monotonic_begin_ns": begin_ns,
        "monotonic_end_ns": end_ns,
        "monotonic_ns": (begin_ns + end_ns) // 2,
        "collection_seconds": round((end_ns - begin_ns) / 1_000_000_000, 6),
        "cpu": cpu,
        "memory": memory,
        "load": load,
        "pressure": pressure,
    }


def aggregate_cpu_interval(before: list[int] | None, after: list[int] | None) -> dict[str, float | None]:
    fields = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal")
    if before is None or after is None or len(before) < 4 or len(after) < 4:
        return {name: None for name in ("busy_percent", "idle_percent", "iowait_percent", "steal_percent")}
    length = min(len(fields), len(before), len(after))
    if any(after[index] < before[index] for index in range(length)):
        return {name: None for name in ("busy_percent", "idle_percent", "iowait_percent", "steal_percent")}
    deltas = dict(zip(fields[:length], (after[index] - before[index] for index in range(length))))
    total = sum(deltas.values())
    if total <= 0:
        return {name: None for name in ("busy_percent", "idle_percent", "iowait_percent", "steal_percent")}
    percent = lambda value: round(value / total * 100, 6)  # noqa: E731
    idle, iowait = deltas.get("idle", 0), deltas.get("iowait", 0)
    return {
        "busy_percent": percent(total - idle - iowait),
        "idle_percent": percent(idle),
        "iowait_percent": percent(iowait),
        "steal_percent": percent(deltas.get("steal", 0)),
    }


def pressure_interval(
    before: dict[str, dict[str, float | int]],
    after: dict[str, dict[str, float | int]],
    elapsed: float,
) -> dict[str, float | None]:
    values: dict[str, float | None] = {}
    for kind in ("some", "full"):
        first = before.get(kind, {}).get("total")
        last = after.get(kind, {}).get("total")
        delta = counter_delta(
            first if isinstance(first, int) else None,
            last if isinstance(last, int) else None,
        )
        values[f"{kind}_percent"] = round(delta / 1_000_000 / elapsed * 100, 6) if delta is not None else None
    return values


def system_resource_interval(
    before: dict[str, Any],
    after: dict[str, Any],
    *,
    start_ns: int,
    scheduled_ns: int,
    index: int,
) -> dict[str, Any]:
    elapsed = max(0.000001, (after["monotonic_ns"] - before["monotonic_ns"]) / 1_000_000_000)
    memory = after.get("memory", {})
    load = after.get("load", {})
    pressure = {
        name: pressure_interval(
            before.get("pressure", {}).get(name, {}),
            after.get("pressure", {}).get(name, {}),
            elapsed,
        )
        for name in ("cpu", "memory", "io")
    }
    availability = {
        "cpu": bool(before.get("cpu", {}).get("cpu") and after.get("cpu", {}).get("cpu")),
        "memory": all(key in memory for key in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree")),
        "load": all(key in load for key in ("load_1m", "load_5m", "load_15m", "runnable_tasks", "total_tasks")),
        **{
            f"pressure_{name}": bool(
                before.get("pressure", {}).get(name) and after.get("pressure", {}).get(name)
            )
            for name in ("cpu", "memory", "io")
        },
    }
    cpu = aggregate_cpu_interval(before.get("cpu", {}).get("cpu"), after.get("cpu", {}).get("cpu"))
    if cpu["busy_percent"] is None:
        availability["cpu"] = False
    observed_ns = after["monotonic_ns"]
    return {
        "index": index,
        "captured_at": after["captured_at"],
        "scheduled_elapsed_seconds": round((scheduled_ns - start_ns) / 1_000_000_000, 6),
        "elapsed_seconds": round((observed_ns - start_ns) / 1_000_000_000, 6),
        "schedule_lateness_seconds": round(max(0, observed_ns - scheduled_ns) / 1_000_000_000, 6),
        "interval_seconds": round(elapsed, 6),
        "collection_seconds": after["collection_seconds"],
        "availability": availability,
        "cpu": cpu,
        "memory": {
            "total_bytes": memory.get("MemTotal"),
            "available_bytes": memory.get("MemAvailable"),
            "swap_total_bytes": memory.get("SwapTotal"),
            "swap_free_bytes": memory.get("SwapFree"),
        },
        "load": load,
        "pressure": pressure,
    }


def advance_resource_deadline(scheduled_ns: int, observed_end_ns: int, interval_ns: int) -> int:
    while scheduled_ns <= observed_end_ns:
        scheduled_ns += interval_ns
    return scheduled_ns


def system_resource_report(samples: list[dict[str, Any]], duration: int) -> dict[str, Any]:
    unavailable = sorted({
        name for sample in samples for name, available in sample.get("availability", {}).items() if not available
    })
    expected = duration // RESOURCE_SAMPLE_INTERVAL_SECONDS
    missed = max(0, expected - len(samples))
    last_scheduled = samples[-1]["scheduled_elapsed_seconds"] if samples else None
    return {
        "collector": "in-process-procfs-v1",
        "requested_interval_seconds": RESOURCE_SAMPLE_INTERVAL_SECONDS,
        "expected_sample_count": expected,
        "sample_count": len(samples),
        "missed_sample_count": missed,
        "coverage_complete": missed == 0 and last_scheduled == duration,
        "first_sample_elapsed_seconds": samples[0]["elapsed_seconds"] if samples else None,
        "last_sample_elapsed_seconds": samples[-1]["elapsed_seconds"] if samples else None,
        "last_sample_scheduled_seconds": last_scheduled,
        "maximum_schedule_lateness_seconds": max(
            (sample["schedule_lateness_seconds"] for sample in samples), default=None,
        ),
        "total_collection_seconds": round(sum(sample["collection_seconds"] for sample in samples), 6),
        "unavailable_components": unavailable,
        "samples": samples,
        "scope": "Resource samples provide system context. Set CPU totals remain the benchmark result.",
    }


def parse_kernel_counters(text: str) -> dict[str, Any]:
    """Parse /proc/interrupts or /proc/softirqs with any label names."""
    lines = text.splitlines()
    if not lines:
        return {"available": False, "reason": "empty-or-unreadable", "cpus": [], "labels": {}, "skipped_rows": []}
    cpus = lines[0].split()
    if not cpus or not all(re.fullmatch(r"CPU\d+", cpu) for cpu in cpus):
        return {"available": False, "reason": "missing-cpu-header", "cpus": [], "labels": {}, "skipped_rows": lines[:1]}
    labels: dict[str, Any] = {}
    skipped = []
    for raw_line in lines[1:]:
        if not raw_line.strip():
            continue
        if ":" not in raw_line:
            skipped.append(raw_line)
            continue
        raw_label, remainder = raw_line.split(":", 1)
        label = raw_label.strip()
        fields = remainder.split()
        count_fields = []
        while len(count_fields) < len(fields) and fields[len(count_fields)].isdigit():
            count_fields.append(fields[len(count_fields)])
        counts = [int(value) for value in count_fields]
        if len(counts) == 1 and label in {"ERR", "MIS"}:
            labels[label] = {
                "scope": "global", "per_cpu": {}, "total": counts[0], "description": " ".join(fields[1:]),
            }
        elif len(counts) == len(cpus):
            labels[label] = {
                "scope": "per-cpu", "per_cpu": dict(zip(cpus, counts)), "total": sum(counts),
                "description": " ".join(fields[len(cpus):]),
            }
        else:
            skipped.append(raw_line)
    return {"available": True, "reason": None, "cpus": cpus, "labels": labels, "skipped_rows": skipped}


def kernel_counter_snapshot(paths: dict[str, Path] | None = None) -> dict[str, Any]:
    sources = paths or {"interrupts": Path("/proc/interrupts"), "softirqs": Path("/proc/softirqs")}
    result = {}
    for name, path in sources.items():
        begin_ns = time.monotonic_ns()
        error = None
        try:
            raw = path.read_text(errors="replace")
        except OSError as caught:
            raw, error = "", str(caught)
        end_ns = time.monotonic_ns()
        parsed = parse_kernel_counters(raw)
        if error:
            parsed.update(available=False, reason=f"read-error: {error}")
        parsed.update({
            "source": str(path), "raw": raw, "captured_at": utc_now(),
            "monotonic_begin_ns": begin_ns, "monotonic_end_ns": end_ns,
            "monotonic_ns": (begin_ns + end_ns) // 2,
            "collection_seconds": round((end_ns - begin_ns) / 1_000_000_000, 6),
        })
        result[name] = parsed
    return result


def kernel_counter_delta(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    if not before.get("available") or not after.get("available"):
        unavailable = [f"{side}: {item.get('reason', 'unavailable')}" for side, item in (
            ("before", before), ("after", after),
        ) if not item.get("available")]
        return {
            "available": False, "reason": "; ".join(unavailable), "total_delta": None,
            "total_rate_per_second": None, "labels": {},
        }
    elapsed = max(0.000001, (after["monotonic_ns"] - before["monotonic_ns"]) / 1_000_000_000)
    before_labels, after_labels = before.get("labels", {}), after.get("labels", {})
    rows, comparable_total = {}, 0
    for label in sorted(set(before_labels) | set(after_labels)):
        first, last = before_labels.get(label), after_labels.get(label)
        status, delta, per_cpu = "comparable", None, {}
        if first is None:
            status = "missing-before"
        elif last is None:
            status = "missing-after"
        elif first.get("scope") != last.get("scope"):
            status = "scope-changed"
        else:
            delta = counter_delta(first.get("total"), last.get("total"))
            if delta is None:
                status = "counter-reset"
            else:
                comparable_total += delta
            per_cpu = {cpu: counter_delta(first.get("per_cpu", {}).get(cpu), last.get("per_cpu", {}).get(cpu))
                       for cpu in sorted(set(first.get("per_cpu", {})) | set(last.get("per_cpu", {})))}
            if status == "comparable" and any(value is None for value in per_cpu.values()):
                status = "per-cpu-counter-reset-or-column-change"
        rows[label] = {
            "status": status, "scope": (last or first or {}).get("scope"),
            "before": None if first is None else first.get("total"),
            "after": None if last is None else last.get("total"), "delta": delta,
            "rate_per_second": round(delta / elapsed, 6) if delta is not None else None,
            "per_cpu_delta": per_cpu,
            "description_before": None if first is None else first.get("description"),
            "description_after": None if last is None else last.get("description"),
        }
    confounders = []
    if before.get("cpus") != after.get("cpus"):
        confounders.append("cpu-column-set-changed")
    if before.get("skipped_rows") or after.get("skipped_rows") or any(row["status"] != "comparable" for row in rows.values()):
        confounders.append("label-set-or-counter-discontinuity")
    complete = not confounders
    before_begin = before.get("monotonic_begin_ns", before["monotonic_ns"])
    before_end = before.get("monotonic_end_ns", before["monotonic_ns"])
    after_begin = after.get("monotonic_begin_ns", after["monotonic_ns"])
    after_end = after.get("monotonic_end_ns", after["monotonic_ns"])
    per_cpu = {cpu: sum(
        row["per_cpu_delta"].get(cpu, 0) for row in rows.values()
        if row["per_cpu_delta"].get(cpu) is not None
    ) for cpu in after.get("cpus", [])}
    return {
        "available": True, "reason": None, "complete": complete, "confounders": confounders,
        "cpus_before": before.get("cpus", []), "cpus_after": after.get("cpus", []), "elapsed_seconds": round(elapsed, 6),
        "elapsed_lower_bound_seconds": round(max(0, after_begin - before_end) / 1_000_000_000, 6),
        "elapsed_upper_bound_seconds": round(max(0, after_end - before_begin) / 1_000_000_000, 6),
        "total_delta": comparable_total if complete else None, "comparable_label_delta": comparable_total,
        "total_rate_per_second": round(comparable_total / elapsed, 6) if complete else None,
        "per_cpu_delta": per_cpu if complete else None,
        "per_cpu_rate_per_second": (
            {cpu: round(value / elapsed, 6) for cpu, value in per_cpu.items()} if complete else None
        ),
        "labels": rows,
    }


def endpoint_collection_offsets(before: dict[str, Any], after: dict[str, Any], start_ns: int) -> dict[str, Any]:
    offsets = lambda item: [  # noqa: E731
        round((item[key] - start_ns) / 1_000_000_000, 6)
        for key in ("monotonic_begin_ns", "monotonic_end_ns")
    ]
    return {"before_collection_offsets_seconds": offsets(before),
            "after_collection_offsets_seconds": offsets(after)}


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
        "elapsed_scope": "Elapsed time uses a midpoint estimate and bounds from 2 process samples.",
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
                "Per-task CPU, context switches, and Linux scheduler values cover tasks present in both "
                "process samples. Host CPU covers the full period. The raw lists show started and ended tasks."
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
        self.exit_observed_ns: int | None = None
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
            # EOF records the first observed output close. Keep that time
            # separate from the later process wait.
            self.process.wait()
            self.exit_observed_ns = time.monotonic_ns()

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
            if self.exit_observed_ns is None and self.process.poll() is not None:
                self.exit_observed_ns = self.reaped_ns
        possible_ends = [value for value in (
            self.exit_observed_ns, self.termination_requested_ns, self.deadline_observed_ns,
        ) if value is not None]
        observed_end_ns = min(possible_ends) if possible_ends else self.reaped_ns
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
                "exit_observed_offset_seconds": self.offset_seconds(self.exit_observed_ns),
                "reaped_offset_seconds": self.offset_seconds(self.reaped_ns),
                "supervision_interval_seconds": supervision_seconds,
                "exited_before_deadline": bool(
                    self.exit_observed_ns is not None and self.deadline_observed_ns is not None
                    and self.exit_observed_ns < self.deadline_observed_ns
                ),
                "first_output_offset_seconds": self.offset_seconds(self.first_output_ns),
                "last_output_offset_seconds": self.offset_seconds(self.last_output_ns),
                "output_span_seconds": output_span_seconds,
                "output_line_count": self.output_line_count,
                "reader_alive_after_join": bool(self.thread and self.thread.is_alive()),
                "scope": (
                    "Times use a steady clock. First and last output mark the observed data range."
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
            "manual": "The listener heard crackle. The report contains zero matching tool events.",
            "no-instrumented-evidence": "All usable tools completed and recorded zero matching events.",
            "unknown": "The report needs more tool or listener evidence.",
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
        schedstat = {}
        for key in ("runtime_ns", "run_delay_ns", "timeslices"):
            sched_values = [item.get("schedstat", {}).get(key) for item in values]
            schedstat[key] = (
                sum(sched_values) if sched_values and all(value is not None for value in sched_values) else None
            )
        summary[name] = {
            "cpu_percent_of_one_core": (
                round(sum(cpu_values), 4) if cpu_values and len(cpu_values) == len(values) else None
            ),
            "context_switches": (
                sum(context_values) if context_values and len(context_values) == len(values) else None
            ),
            "schedstat": schedstat,
            "pids": [item["pid"] for item in values],
        }
        if name == "live":
            threads = [thread for process in values for thread in process.get("threads", [])]
            summary[name]["thread_count"] = len(threads) if values else None
            summary[name]["audio_worker_count"] = (
                sum(thread.get("comm") == "AudioCalc" for thread in threads) if values else None
            )
    return summary


def capture(args: argparse.Namespace) -> int:
    output = Path(args.output).resolve()
    raw = output / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    prefix, wine_root = Path(args.prefix).resolve(), Path(args.wine_root).resolve()
    explicit = [int(value) for value in args.live_pid]
    log_paths = find_live_logs(prefix)
    log_paths.extend(Path(value).resolve() for value in args.log)
    # Keep the first instance of each log path so file names stay stable.
    log_paths = list(dict.fromkeys(log_paths))
    baselines = log_baselines(log_paths)
    dump_json(raw / "log-baselines.json", baselines)
    log_contexts = capture_log_context(baselines, raw)
    live_identity = parse_live_log_identity(log_contexts[0] if log_contexts else "")

    power_before = power_endpoint_snapshot(raw, "before")
    policy_before = cpu_policy_snapshot()
    audio_before = audio_endpoint_snapshot(raw, "before")
    before = proc_snapshot(prefix, wine_root, explicit)
    kernel_before = kernel_counter_snapshot()
    dump_json(raw / "power-before.json", power_before)
    dump_json(raw / "cpu-policy-before.json", policy_before)
    dump_json(raw / "audio-before.json", audio_before)
    dump_json(raw / "proc-before.json", before)
    for name, snapshot in kernel_before.items():
        (raw / f"proc-{name}-before.txt").write_text(snapshot.pop("raw"))
    resource_previous = system_resource_snapshot()
    started_at = utc_now()
    start_ns = time.monotonic_ns()
    resource_samples: list[dict[str, Any]] = []
    resource_interval_ns = RESOURCE_SAMPLE_INTERVAL_SECONDS * 1_000_000_000
    next_resource_ns = start_ns + resource_interval_ns
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
        (raw / "osc.stderr.txt").write_text("OSC mode: controller-free measurement\n")
    for command in commands:
        command.start()
    deadline_ns = start_ns + int(args.duration * 1_000_000_000)
    while True:
        now_ns = time.monotonic_ns()
        remaining = (deadline_ns - now_ns) / 1_000_000_000
        if remaining <= 0:
            break
        until_sample = max(0, (next_resource_ns - now_ns) / 1_000_000_000)
        time.sleep(min(remaining, until_sample, 0.25))
        observed_ns = time.monotonic_ns()
        if observed_ns >= deadline_ns:
            break
        if observed_ns >= next_resource_ns and next_resource_ns < deadline_ns:
            scheduled_ns = next_resource_ns
            resource_current = system_resource_snapshot()
            resource_samples.append(system_resource_interval(
                resource_previous,
                resource_current,
                start_ns=start_ns,
                scheduled_ns=scheduled_ns,
                index=len(resource_samples) + 1,
            ))
            resource_previous = resource_current
            next_resource_ns = advance_resource_deadline(
                next_resource_ns, resource_current["monotonic_end_ns"], resource_interval_ns,
            )
    # Stop every external tool at the shared end time. The later stop call waits
    # for each process to exit.
    for command in commands:
        command.terminate_at_deadline()
    after = proc_snapshot(prefix, wine_root, explicit)
    kernel_after = kernel_counter_snapshot()
    resource_current = system_resource_snapshot()
    resource_samples.append(system_resource_interval(
        resource_previous,
        resource_current,
        start_ns=start_ns,
        scheduled_ns=deadline_ns,
        index=len(resource_samples) + 1,
    ))
    resources = system_resource_report(resource_samples, args.duration)
    audio_after = audio_endpoint_snapshot(raw, "after")
    policy_after = cpu_policy_snapshot()
    power_after = power_endpoint_snapshot(raw, "after")
    ended_at = utc_now()
    dump_json(raw / "system-resources.json", resources)
    command_results = {command.name: command.stop() for command in commands}
    if args.osc == "off":
        command_results["osc"] = {"available": False, "reason": "set-has-no-controller"}
    dump_json(raw / "proc-after.json", after)
    dump_json(raw / "cpu-policy-after.json", policy_after)
    dump_json(raw / "power-after.json", power_after)
    dump_json(raw / "audio-after.json", audio_after)
    for name, snapshot in kernel_after.items():
        (raw / f"proc-{name}-after.txt").write_text(snapshot.pop("raw"))
    delta = snapshots_delta(before, after)
    dump_json(raw / "proc-delta.json", delta)
    kernel_deltas = {
        name: kernel_counter_delta(kernel_before[name], kernel_after[name])
        for name in ("interrupts", "softirqs")
    }
    dump_json(raw / "proc-kernel-counters-delta.json", kernel_deltas)

    pw_top = parse_pw_top(read_text(raw / "pw-top.tsv"), args.node_pattern)
    metadata = parse_metadata(read_text(raw / "pw-metadata.tsv"))
    osc = parse_osc(read_text(raw / "osc.tsv"))
    logs = capture_log_slices(baselines, raw)
    pw_top_usable = collector_command_usable(command_results.get("pw-top", {}), args.duration, "pw-top")
    crackle = crackle_status(
        pw_top_usable and pw_top["instrumented"] and not pw_top["identity_confounded"],
        pw_top["err_delta"], logs["xrun_line_count"], args.manual_crackle,
    )
    confounders = []
    for name in ("pw-top", "pw-metadata", "osc"):
        intentionally_off = name == "osc" and args.osc == "off"
        if not intentionally_off and not collector_command_usable(
            command_results.get(name, {}), args.duration, name,
        ):
            confounders.append({
                "kind": f"{name}-collector-unusable",
                "effect": "The tool produced data for less than the required measurement time.",
            })
    accounting = delta["accounting"]
    if accounting["confounded_by_task_churn"]:
        confounders.append({
            "kind": "task-churn",
            "effect": "Per-process and thread CPU totals cover tasks present in both process samples.",
        })
    if pw_top["identity_confounded"]:
        confounders.append({
            "kind": "pipewire-node-identity-churn",
            "effect": "Error and buffer histories use separate PipeWire node generations. Review each generation.",
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
            "kernel_counter_intervals": {
                name: endpoint_collection_offsets(kernel_before[name], kernel_after[name], start_ns) | {
                    "interval_midpoint_estimate_seconds": kernel_deltas[name].get("elapsed_seconds"),
                    "interval_bounds_seconds": [
                        kernel_deltas[name].get("elapsed_lower_bound_seconds"),
                        kernel_deltas[name].get("elapsed_upper_bound_seconds"),
                    ],
                    "available": kernel_deltas[name].get("available", False),
                }
                for name in ("interrupts", "softirqs")
            },
            "endpoint_identity_intervals": {
                name: endpoint_collection_offsets(first, last, start_ns)
                for name, first, last in (
                    ("cpu_policy", policy_before, policy_after),
                    ("power", power_before, power_after),
                    ("audio", audio_before, audio_after),
                )
            },
            "scope": (
                "All timed tools use one end time. CPU, interrupt, and soft interrupt fields include their "
                "sample bounds. Each tool records its run time and data coverage."
            ),
        },
        "process": {"summary": process_groups(delta, prefix, wine_root), "details": delta},
        "system_resources": resources,
        "kernel_counters": kernel_deltas,
        "endpoint_identity": {
            "cpu_policy": {
                "before": policy_before,
                "after": policy_after,
                "changed_within_window": policy_before.get("policies") != policy_after.get("policies"),
            },
            "power": {
                "before": power_before,
                "after": power_after,
                "changed_within_window": (
                    power_before.get("profile") != power_after.get("profile")
                    or power_before.get("holds") != power_after.get("holds")
                ),
            },
            "audio": {
                "before": audio_before,
                "after": audio_after,
                "changed_within_window": audio_endpoint_value(audio_before) != audio_endpoint_value(audio_after),
            },
        },
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
            "proc_interrupts_before": "raw/proc-interrupts-before.txt",
            "proc_interrupts_after": "raw/proc-interrupts-after.txt",
            "proc_softirqs_before": "raw/proc-softirqs-before.txt",
            "proc_softirqs_after": "raw/proc-softirqs-after.txt",
            "proc_kernel_counters_delta": "raw/proc-kernel-counters-delta.json",
            "cpu_policy_before": "raw/cpu-policy-before.json",
            "cpu_policy_after": "raw/cpu-policy-after.json",
            "power_before": "raw/power-before.json",
            "power_after": "raw/power-after.json",
            "audio_before": "raw/audio-before.json",
            "audio_after": "raw/audio-after.json",
            "system_resources": "raw/system-resources.json",
            "pw_top": "raw/pw-top.tsv",
            "pw_metadata": "raw/pw-metadata.tsv",
            "osc": "raw/osc.tsv",
        },
    }
    dump_json(output / "measurement.json", measurement)
    return 0


def embedded_product_version(path: Path) -> str | None:
    try:
        with path.open("rb") as source:
            if source.read(2) != b"MZ":
                return None
    except OSError:
        return None
    helper = Path(__file__).resolve().parent / "lib/live-options.sh"
    try:
        completed = subprocess.run(
            ["bash", "-c", '. "$1"; ableton_live_product_version "$2"',
             "bench-version", str(helper), str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return completed.stdout.strip() if completed.returncode == 0 else None


def fixture_plugin_inventory(prefix: Path) -> list[dict[str, Any]]:
    roots = (
        prefix / "drive_c/Program Files/Common Files/VST3",
        prefix / "drive_c/Program Files/VSTPlugins",
    )
    result = []
    for name in ("Dexed.vst3", "K1v_x64.vst3"):
        candidates = [root / name for root in roots]
        selected = next((path for path in candidates if path.exists()), None)
        record: dict[str, Any] = {"name": name, "path": str(selected) if selected else None, "exists": selected is not None}
        if selected is not None:
            files = [selected] if selected.is_file() else sorted(
                path for path in selected.rglob("*") if path.is_file()
            )
            file_records = [sha256_file(path) | {"product_version": embedded_product_version(path)} for path in files]
            record.update(
                kind="file" if selected.is_file() else "bundle",
                files=file_records,
                identity_hash=manifest_hash(file_records, selected if selected.is_dir() else selected.parent),
            )
        result.append(record)
    return result


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
        record["product_version"] = embedded_product_version(path)
        executables.append(record)
    return {"preferences": preferences, "executables": executables}


def profile(args: argparse.Namespace) -> int:
    try:
        run_file = getattr(args, "run_file", None)
        if run_file:
            run_value = load_json_object(Path(run_file))
            machine_id = nested(run_value, "machine", "id")
            if not isinstance(machine_id, str) or not MACHINE_ID_RE.fullmatch(machine_id):
                raise ValueError("run file benchmark report source ID must contain 32 lowercase hexadecimal characters")
        else:
            machine_id = load_benchmark_machine_id()
    except (ValueError, OSError) as error:
        print(f"system profile: {error}", file=sys.stderr)
        return 2
    output = Path(args.output).resolve()
    raw = output / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    prefix, wine_root = Path(args.prefix).resolve(), Path(args.wine_root).resolve()
    capture_started_at = utc_now()
    commands: dict[str, list[str]] = {
        "uname": ["uname", "-a"],
        "lscpu-json": ["lscpu", "-J"],
        "lscpu-topology": ["lscpu", "-e=CPU,NODE,SOCKET,CORE,ONLINE,MAXMHZ,MINMHZ"],
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
        "proc-meminfo": Path("/proc/meminfo"),
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
    kernel_audio = audio_kernel_parameters()
    kernel_audio["raw"] = "raw/snd-usb-audio-parameters.json"
    dump_json(raw / "snd-usb-audio-parameters.json", kernel_audio)
    profile_value = {
        "schema": SCHEMA,
        "kind": "system-profile",
        "capture_started_at": capture_started_at,
        "captured_at": utc_now(),
        "machine": {
            "id": machine_id,
            "scope": "stable report source ID for this user",
            "source": "persistent-random-v1",
        },
        "system": {
            "uname": read_text(raw / "uname.stdout.txt").strip(),
            "os_release": parse_os_release(read_text(raw / "os-release.txt")),
            "cpu": parse_lscpu_json(lscpu_text),
            "cpu_topology": parse_topology_table(topology_text),
            "cpu_sysfs": cpu_sysfs_inventory(),
            "cpu_topology_raw": "raw/lscpu-topology.stdout.txt",
            "cpu_description_raw": "raw/lscpu-json.stdout.txt",
            "memory": parse_meminfo(read_text(raw / "proc-meminfo.txt")),
            "memory_raw": "raw/proc-meminfo.txt",
            "report_filesystem": filesystem_capacity(output),
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
            "power_profile_scope": (
                "Records the power profile before Live starts. Each set records the profile and active power "
                "requests at both CPU samples."
            ),
            "audio_kernel": kernel_audio,
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
                "phase": "audio profile recorded before the first Live launch",
                "profiles": "default input and output devices; pw-dump records the full graph",
                "settings": "PipeWire settings recorded once; each set tracks changes throughout its run",
                "limitation": (
                    "Each set records devices, profiles, and links at the start and end. A change can reverse "
                    "between samples and appear equal at both samples."
                ),
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
            "identity_scope": "hash of build details, the Wine launcher, and both PipeASIO files",
        },
        "prefix": {
            "path": str(prefix),
            "files": prefix_records,
            "identity_hash": manifest_hash(prefix_records, prefix),
            "identity_scope": "hash of the managed prefix marker and Wine registry files",
        },
        "configuration": {
            "files": config_records,
            "identity_hash": manifest_hash(config_records),
            "launcher_config": launcher_config_record,
            "pipeasio_effective_config": pipeasio_config_record,
            "environment": benchmark_environment(),
            "benchmark_gates": benchmark_gate_environment(),
        },
        "live": live_inventory(prefix),
        "fixture_plugins": fixture_plugin_inventory(prefix),
        "commands": results,
    }
    dump_json(output / "profile.json", profile_value)
    return 0


def init_run(args: argparse.Namespace) -> int:
    try:
        machine_id = load_benchmark_machine_id()
    except (ValueError, OSError) as error:
        print(f"benchmark run: {error}", file=sys.stderr)
        return 2
    created_at = utc_now()
    csv_filename = cpu_benchmark_csv_filename(machine_id, created_at)
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
        "created_at": created_at,
        "tag": args.tag,
        "duration_seconds_per_set": args.duration,
        "set_order": args.set,
        "suite_log": "suite.log",
        "harness": {
            "files": harness_records,
            "identity_hash": manifest_hash(harness_records, repository),
        },
        "machine": {
            "id": machine_id,
            "scope": "stable report source ID for this user",
            "source": "persistent-random-v1",
        },
        "csv": {
            "schema": CSV_SCHEMA,
            "filename": csv_filename,
            "timestamp": filename_timestamp(created_at),
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
        "# Ableton Linux CPU and audio benchmark",
        "",
        f"- Tag: `{run.get('tag', 'pending')}`",
        f"- Status: `{run.get('status', 'pending')}`",
        f"- Measurement time: {run.get('duration_seconds_per_set', 'pending')} seconds per set",
        f"- Benchmark files SHA-256: `{run.get('harness', {}).get('identity_hash', 'pending')}`",
        f"- Generated: {report['generated_at']}",
    ]
    if report.get("csv"):
        lines.extend([
            f"- Report source ID: `{report['csv'].get('machine_id', 'pending')}`",
            f"- CSV file: `{report['csv'].get('filename', 'pending')}`",
        ])
    lines.extend([
        "",
        "## Results",
        "",
        "| Set | Mode | Audio workers | Host CPU | Live CPU per core | Wine CPU per core | Hardware interrupts per second | Software interrupts per second | Power profile | Sample rate and buffer size | Audio settings | CPU policy | Process changes | PipeWire errors | DSP average and peak | Buffer changes | Crackle |",
        "|---|---|---:|---:|---:|---:|---:|---:|---|---|---|---|---|---:|---:|---:|---|",
    ])
    for item in report["sets"]:
        process = item.get("process", {}).get("summary", {})
        host = item.get("process", {}).get("details", {}).get("host_cpu_percent", {}).get("cpu")
        live = process.get("live", {}).get("cpu_percent_of_one_core")
        wine = process.get("wine_prefix", {}).get("cpu_percent_of_one_core")
        pw = item.get("pipewire", {}).get("pw_top", {})
        dsp = item.get("osc_dsp", {})
        accounting = item.get("process", {}).get("details", {}).get("accounting", {})
        counters = item.get("kernel_counters", {})
        endpoint = item.get("endpoint_identity", {})
        power = endpoint.get("power", {})
        audio = endpoint.get("audio", {})
        audio_before = nested(audio, "before", "graph_settings") or {}
        audio_after = nested(audio, "after", "graph_settings") or {}
        audio_available = bool(
            nested(audio, "before", "available") and nested(audio, "after", "available")
        )
        audio_changed = (
            "pending" if "changed_within_window" not in audio
            else (
                "review" if not audio_available
                else ("changed" if audio["changed_within_window"] else "same")
            )
        )
        cpu_policy = endpoint.get("cpu_policy", {})
        cpu_policy_available = bool(
            nested(cpu_policy, "before", "available") and nested(cpu_policy, "after", "available")
        )
        cpu_policy_changed = (
            "pending" if "changed_within_window" not in cpu_policy
            else (
                "review" if not cpu_policy_available
                else ("changed" if cpu_policy["changed_within_window"] else "same")
            )
        )
        power_label = (
            f"{power.get('before', {}).get('profile') or 'pending'} → "
            f"{power.get('after', {}).get('profile') or 'pending'}"
        )
        process_changes = accounting.get("processes", {})
        thread_changes = accounting.get("threads", {})
        change_label = (
            f"processes started {len(process_changes.get('born', []))}, "
            f"ended {len(process_changes.get('exited', []))}; "
            f"threads started {len(thread_changes.get('born', []))}, "
            f"ended {len(thread_changes.get('exited', []))}"
        )
        transitions = quantum_transition_count(item)
        number = lambda value: "pending" if value is None else f"{value:.2f}"  # noqa: E731
        percent = lambda value: "pending" if value is None else f"{value:.2f}%"  # noqa: E731
        transition_label = transitions if transitions is not None else "pending"
        lines.append(
            f"| {item.get('set')} | {item.get('mode')} | {process.get('live', {}).get('audio_worker_count', 'pending')} | "
            f"{percent(host)} | {percent(live)} | "
            f"{percent(wine)} | {number(counters.get('interrupts', {}).get('total_rate_per_second'))} | "
            f"{number(counters.get('softirqs', {}).get('total_rate_per_second'))} | {power_label} | "
            f"{audio_before.get('clock.rate', 'pending')}/{audio_before.get('clock.quantum', 'pending')} → "
            f"{audio_after.get('clock.rate', 'pending')}/{audio_after.get('clock.quantum', 'pending')} | "
            f"{audio_changed} | "
            f"{cpu_policy_changed} | {change_label} | "
            f"{pw.get('err_delta', 'pending')} | {number(dsp.get('average_percent'))} / "
            f"{number(dsp.get('peak_percent'))} | {transition_label} | {item.get('crackle', {}).get('status', 'unknown')} |"
        )
    runtime = profile_value.get("runtime", {})
    prefix = profile_value.get("prefix", {})
    live_inventory_value = profile_value.get("live", {})
    fixture_plugins = profile_value.get("fixture_plugins", [])
    system = profile_value.get("system", {})
    cpu = system.get("cpu", {})
    pipewire = profile_value.get("pipewire", {})
    configuration = profile_value.get("configuration", {})
    settings = pipewire.get("settings", {}).get("values", {})
    pipewire_availability = pipewire.get("availability", {})
    pipewire_unavailable = (
        [name for name, status in pipewire_availability.items() if not status.get("successful")]
        if pipewire_availability else ["command results pending"]
    )
    runtime_dist = "pending"
    for line in runtime.get("build_info", "").splitlines():
        if line.startswith("dist-version:"):
            runtime_dist = line.split(":", 1)[1].strip()
            break
    lines.extend([
        "",
        "## Run details",
        "",
        f"- System: `{profile_value.get('system', {}).get('uname', 'pending')}`",
        f"- CPU: `{cpu.get('Model name', 'pending')}`; logical CPUs `{cpu.get('CPU(s)', 'pending')}`, "
        f"cores per socket `{cpu.get('Core(s) per socket', 'pending')}`, sockets `{cpu.get('Socket(s)', 'pending')}`",
        f"- GPU: `{'; '.join(system.get('gpu_lines', [])) or 'pending'}`",
        f"- ALSA cards: `{' '.join(system.get('audio_devices', {}).get('alsa_cards', '').split()) or 'pending'}`",
        f"- Power profile before Live starts: `{system.get('power_profile') or 'pending'}`",
        f"- snd_usb_audio parameters: `"
        f"{json.dumps(system.get('audio_kernel', {}).get('parameters', {}), sort_keys=True)}`",
        f"- PipeWire: `{pipewire.get('versions', {}).get('pipewire') or 'pending'}`; "
        f"WirePlumber `{pipewire.get('versions', {}).get('wireplumber') or 'pending'}`",
        f"- PipeWire at start: sample rate `{settings.get('clock.rate', 'pending')}`, buffer size "
        f"`{settings.get('clock.quantum', 'pending')}`, fixed buffer size "
        f"`{settings.get('clock.force-quantum', 'pending')}`",
        f"- Audio profile details: `{'; '.join(pipewire.get('active_profile_lines', [])) or 'pending'}`",
        f"- Audio profile sample: `{pipewire.get('capture_scope', {}).get('phase', 'pending')}`",
        f"- PipeWire checks: `{'complete' if not pipewire_unavailable else 'review: ' + ', '.join(pipewire_unavailable)}`",
        f"- Runtime: build `{runtime_dist}`, Wine `{runtime.get('wine_version', 'pending')}` at `{runtime.get('root', 'pending')}`",
        f"- Runtime files SHA-256: `{runtime.get('identity_hash', 'pending')}`",
        f"- Wine prefix: `{prefix.get('path', 'pending')}`",
        f"- Prefix files SHA-256: `{prefix.get('identity_hash', 'pending')}`",
        f"- Settings files SHA-256: `{profile_value.get('configuration', {}).get('identity_hash', 'pending')}`",
        f"- PipeASIO settings file: `{configuration.get('pipeasio_effective_config', {}).get('path') or 'pending'}` "
        f"(source `{configuration.get('pipeasio_effective_config', {}).get('resolution', 'pending')}`)",
        "",
        "### Live options",
        "",
    ])
    preferences = live_inventory_value.get("preferences", [])
    executables = live_inventory_value.get("executables", [])
    if not preferences and not executables:
        lines.append("Live details await an installed executable or preferences folder.")
    for executable in executables:
        lines.append(
            f"- `{Path(executable.get('path', 'pending')).name}`: product version "
            f"`{executable.get('product_version') or 'pending'}`, executable SHA-256 "
            f"`{executable.get('sha256', 'pending')}`"
        )
    for preference in preferences:
        workers = preference.get("max_audio_threads")
        lines.append(
            f"- Live {preference.get('version')}: MaxAudioThreads="
            f"{workers if workers is not None else 'Live default'}; Options.txt SHA-256 "
            f"`{preference.get('options_hash', {}).get('sha256', 'pending')}`"
        )
    lines.extend(["", "### VST3 plug-ins", ""])
    for plugin in fixture_plugins:
        versions = sorted(set(
            item.get("product_version") for item in plugin.get("files", []) if item.get("product_version")
        ))
        lines.append(
            f"- {plugin.get('name')}: `{plugin.get('path') or 'pending'}`; files SHA-256 "
            f"`{plugin.get('identity_hash', 'pending')}`; product versions "
            f"`{', '.join(versions) if versions else 'pending'}`"
        )
    lines.extend([
        "",
        "## Crackle evidence",
        "",
        "- `detected`: a tool reported a PipeWire error or xrun",
        "- `manual`: the listener heard crackle while the tools recorded zero matching events",
        "- complete tool evidence means all usable tools recorded zero matching events",
        "- pending evidence means the report needs more tool or listener evidence",
        "",
        "Detailed JSON and source files contain process and thread counts, scheduler data, tool timing, logs, control messages, and buffer changes.",
        "",
    ])
    return "\n".join(lines)


def load_json_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot load {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return value


def load_completed_run(path: Path) -> dict[str, Any]:
    """Load run details and measurements from a finished run."""
    run_dir = path.resolve()
    run = load_json_object(run_dir / "run.json")
    if (run.get("schema"), run.get("kind")) != (SCHEMA, "benchmark-run"):
        raise ValueError(f"{run_dir}: incompatible run schema/kind")
    if run.get("status") != "complete":
        raise ValueError(f"{run_dir}: run status is {run.get('status')!r}, expected 'complete'")
    if run.get("set_order") != list(CANONICAL_SETS):
        raise ValueError(f"{run_dir}: set_order is not the canonical five-set order")
    duration = run.get("duration_seconds_per_set")
    if not isinstance(duration, (int, float)) or isinstance(duration, bool) or duration <= 0:
        raise ValueError(f"{run_dir}: invalid duration_seconds_per_set")
    if duration != 30:
        raise ValueError(f"{run_dir}: comparison requires the canonical 30-second protocol")
    profile_path = run_dir / "profile/profile.json"
    profile_value = load_json_object(profile_path)
    if (profile_value.get("schema"), profile_value.get("kind")) != (SCHEMA, "system-profile"):
        raise ValueError(f"{profile_path}: incompatible profile schema/kind")
    csv_contract = benchmark_csv_contract(run)
    if csv_contract and nested(profile_value, "machine", "id") != csv_contract[0]:
        raise ValueError(f"{profile_path}: report source ID must match run.json")
    sets = []
    for name in CANONICAL_SETS:
        matches = sorted((run_dir / "sets").glob(f"*-{name}/measurement.json"))
        if len(matches) != 1:
            raise ValueError(f"{run_dir}: expected one {name} measurement, found {len(matches)}")
        measurement = load_json_object(matches[0])
        if (measurement.get("schema"), measurement.get("kind")) != (SCHEMA, "set-measurement"):
            raise ValueError(f"{matches[0]}: incompatible measurement schema/kind")
        if measurement.get("set") != name:
            raise ValueError(f"{matches[0]}: embedded set name does not match directory")
        if measurement.get("mode") != CANONICAL_MODES[name]:
            raise ValueError(f"{matches[0]}: unexpected mode {measurement.get('mode')!r}")
        if measurement.get("duration_seconds") != duration:
            raise ValueError(f"{matches[0]}: measurement duration differs from run duration")
        window = measurement.get("window")
        if not isinstance(window, dict):
            raise ValueError(f"{matches[0]}: missing monotonic window evidence")
        start_ns, deadline_ns = window.get("monotonic_start_ns"), window.get("monotonic_deadline_ns")
        before_offsets = window.get("cpu_before_collection_offsets_seconds")
        after_offsets = window.get("cpu_after_collection_offsets_seconds")
        elapsed = nested(measurement, "process", "details", "elapsed_seconds")
        numbers = lambda values: (  # noqa: E731
            isinstance(values, list) and len(values) == 2
            and all(isinstance(value, (int, float)) and not isinstance(value, bool) for value in values)
        )
        if (
            not isinstance(start_ns, int) or isinstance(start_ns, bool)
            or not isinstance(deadline_ns, int) or isinstance(deadline_ns, bool)
            or deadline_ns - start_ns != int(duration * 1_000_000_000)
            or window.get("requested_duration_seconds") != duration
            or not numbers(before_offsets) or not numbers(after_offsets)
            or before_offsets[1] > 0 or after_offsets[0] < duration
            or not isinstance(elapsed, (int, float)) or isinstance(elapsed, bool) or elapsed < duration
        ):
            raise ValueError(f"{matches[0]}: invalid or incomplete monotonic {duration}-second window evidence")
        sets.append(measurement)
    return {"directory": str(run_dir), "run": run, "profile": profile_value, "sets": sets}


def nested(value: dict[str, Any], *keys: str) -> Any:
    current: Any = value
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def canonical_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def value_present(value: Any, allow_empty: bool = False) -> bool:
    return value is not None if allow_empty else value not in (None, "", [], {})


def identity_comparison(
    identifier: str, label: str, before: Any, after: Any, *, allow_empty: bool = False,
) -> dict[str, Any]:
    before_present = value_present(before, allow_empty)
    after_present = value_present(after, allow_empty)
    if not before_present and not after_present:
        status = "match" if allow_empty else "missing-both"
    elif not before_present or not after_present:
        status = f"missing-{'before' if not before_present else 'after'}"
    else:
        status = "match" if before == after else "different"
    return {
        "id": identifier, "label": label, "status": status, "confounder": status != "match",
        "before": before, "after": after,
    }


IDENTITY_SPECS = (
    ("benchmark_machine", "Report source ID", ("machine", "id"), True),
    ("runtime_identity", "Runtime build, Wine version, and folder", ("runtime",), False),
    ("prefix_identity", "Wine prefix folder and files", ("prefix",), False),
    ("live_install", "Live version, options, and worker setting", ("live",), False),
    ("vst_fixtures", "Dexed and K1v files and versions", ("fixture_plugins",), False),
    ("cpu_description", "CPU description", ("system", "cpu"), False),
    ("cpu_topology", "CPU core layout", ("system", "cpu_topology"), False),
    ("cpu_policy_profile", "CPU policy before Live starts", ("system", "cpu_sysfs"), False),
    ("memory_total", "Installed memory", ("system", "memory", "MemTotal"), True),
    ("swap_total", "Configured swap", ("system", "memory", "SwapTotal"), True),
    ("system_software", "Kernel", ("system", "uname"), False),
    ("os_release", "Operating system", ("system", "os_release"), False),
    ("gpu", "GPU devices", ("system", "gpu_lines"), False),
    ("gpu_renderer", "GPU renderer", ("system", "gpu_renderer_lines"), False),
    ("audio_devices", "ALSA and USB audio devices", ("system", "audio_devices"), False),
    ("audio_kernel", "snd_usb_audio parameters", ("system", "audio_kernel"), False),
    ("audio_profile", "Active audio profiles and routes", ("pipewire", "active_profile_lines"), False),
    ("audio_profile_scope", "Audio profile measurement details", ("pipewire", "capture_scope"), False),
    ("audio_profile_availability", "Audio profile command results", ("pipewire", "availability"), False),
    ("pipewire_versions", "PipeWire and WirePlumber versions", ("pipewire", "versions"), False),
    ("sample_rate", "PipeWire graph sample rate", ("pipewire", "settings", "values", "clock.rate"), False),
    ("forced_sample_rate", "PipeWire selected sample rate", ("pipewire", "settings", "values", "clock.force-rate"), True),
    ("quantum", "PipeWire buffer size", ("pipewire", "settings", "values", "clock.quantum"), False),
    ("minimum_quantum", "PipeWire minimum buffer size", ("pipewire", "settings", "values", "clock.min-quantum"), True),
    ("maximum_quantum", "PipeWire maximum buffer size", ("pipewire", "settings", "values", "clock.max-quantum"), True),
    ("forced_quantum", "PipeWire selected buffer size", ("pipewire", "settings", "values", "clock.force-quantum"), True),
    ("configuration", "Launcher and PipeASIO settings hash", ("configuration", "identity_hash"), False),
    ("pipeasio_config", "PipeASIO settings path and hash", ("configuration", "pipeasio_effective_config"), False),
    ("benchmark_gates", "Wine, PipeASIO, and launcher CPU settings", ("configuration", "benchmark_gates"), True),
    ("power_profile", "Power profile before Live starts", ("system", "power_profile"), False),
)


def profile_identity_checks(before: dict[str, Any], after: dict[str, Any]) -> list[dict[str, Any]]:
    first, last = before["profile"], after["profile"]
    return [identity_comparison(identifier, label, nested(first, *path), nested(last, *path), allow_empty=allow_empty)
            for identifier, label, path, allow_empty in IDENTITY_SPECS]


def metric_comparison(
    label: str, unit: str, before: Any, after: Any, confounders: list[str], *, numeric: bool = True,
) -> dict[str, Any]:
    valid = lambda value: (  # noqa: E731
        isinstance(value, (int, float)) and not isinstance(value, bool) if numeric else value_present(value)
    )
    before_valid, after_valid = valid(before), valid(after)
    if not before_valid or not after_valid:
        status = "missing-both" if not before_valid and not after_valid else f"missing-{'before' if not before_valid else 'after'}"
    else:
        status = "comparable" if numeric else ("match" if before == after else "changed")
    raw_delta = after - before if numeric and status == "comparable" else None
    delta = round(raw_delta, 6) if raw_delta is not None else None
    if not numeric:
        percent, percent_status = None, "not-applicable"
    elif status != "comparable":
        percent, percent_status = None, status
    elif before == 0:
        percent, percent_status = None, "zero-baseline"
    else:
        percent, percent_status = round(raw_delta / before * 100, 6), "comparable"
    metric_confounders = list(confounders)
    if status.startswith("missing"):
        metric_confounders.append(status)
    return {
        "label": label, "unit": unit, "before": before if before_valid else None,
        "after": after if after_valid else None, "delta": delta, "percent_change": percent,
        "comparison_status": status, "percent_status": percent_status,
        "confounded": bool(metric_confounders),
        "confounders": list(dict.fromkeys(metric_confounders)),
    }


def collector_command_usable(
    command: dict[str, Any], duration: float, name: str | None = None,
) -> bool:
    timing = command.get("timing") if isinstance(command, dict) else None
    if not command.get("available") or not isinstance(timing, dict):
        return False
    coverage = timing.get("supervision_interval_seconds")
    lines = timing.get("output_line_count")
    # Tools start inside the common period. Accept up to one second and 10% for
    # process start and end. Periodic tools also need data near both ends.
    duration = float(duration)
    minimum = max(0.0, duration - min(1.0, duration * 0.1))
    usable = (
        isinstance(coverage, (int, float)) and not isinstance(coverage, bool)
        and coverage >= minimum and isinstance(lines, int) and not isinstance(lines, bool) and lines > 0
        and not timing.get("reader_alive_after_join", False)
    )
    if not usable or name not in {"pw-top", "osc"}:
        return usable
    first, last = timing.get("first_output_offset_seconds"), timing.get("last_output_offset_seconds")
    edge_tolerance = min(1.0, duration * 0.1)
    return (
        isinstance(first, (int, float)) and not isinstance(first, bool) and first <= edge_tolerance
        and isinstance(last, (int, float)) and not isinstance(last, bool) and last >= duration - edge_tolerance
    )


def collector_observed(measurement: dict[str, Any], name: str) -> bool:
    command = nested(measurement, "capture_commands", name) or {}
    duration = measurement.get("duration_seconds")
    return bool(
        isinstance(duration, (int, float)) and not isinstance(duration, bool)
        and collector_command_usable(command, duration, name)
    )


def quantum_transition_count(measurement: dict[str, Any]) -> int | None:
    pw_top = nested(measurement, "pipewire", "pw_top")
    settings = nested(measurement, "pipewire", "settings")
    top_available = collector_observed(measurement, "pw-top")
    metadata_available = collector_observed(measurement, "pw-metadata")
    if not top_available and not metadata_available:
        return None
    pw_top = pw_top or {}
    settings = settings or {}
    return len(pw_top.get("quantum_transitions", [])) + sum(
        "quantum" in str(item.get("key", "")) for item in settings.get("transitions", [])
    )


def task_churn_counts(measurement: dict[str, Any]) -> dict[str, int | None]:
    accounting = nested(measurement, "process", "details", "accounting")
    if not isinstance(accounting, dict):
        return {key: None for key in (
            "processes_born", "processes_exited", "threads_born", "threads_exited", "total",
        )}
    processes, threads = accounting.get("processes", {}), accounting.get("threads", {})
    counts = {
        "processes_born": len(processes.get("born", [])),
        "processes_exited": len(processes.get("exited", [])),
        "threads_born": len(threads.get("born", [])),
        "threads_exited": len(threads.get("exited", [])),
    }
    counts["total"] = sum(counts.values())
    return counts


def measurement_confounders(measurement: dict[str, Any], side: str) -> list[str]:
    values = [f"{side}:{item.get('kind', 'unspecified')}" for item in measurement.get("confounders", [])]
    accounting = nested(measurement, "process", "details", "accounting") or {}
    if accounting.get("confounded_by_task_churn"):
        values.append(f"{side}:task-churn")
    if nested(measurement, "pipewire", "pw_top", "identity_confounded"):
        values.append(f"{side}:pipewire-node-identity-churn")
    if not nested(measurement, "pipewire", "pw_top", "instrumented"):
        values.append(f"{side}:pipewire-err-instrumentation-unavailable")
    settings = nested(measurement, "pipewire", "settings", "transitions") or []
    if settings:
        values.append(f"{side}:pipewire-settings-transition")
    if quantum_transition_count(measurement):
        values.append(f"{side}:quantum-transition")
    for name in ("pw-top", "pw-metadata", "osc"):
        intentionally_off = name == "osc" and measurement.get("set") == "Benchmark_Zero"
        if not intentionally_off and not collector_observed(measurement, name):
            values.append(f"{side}:{name}-collector-unusable")
    if measurement.get("set") != "Benchmark_Zero" and not nested(measurement, "osc_dsp", "sample_count"):
        values.append(f"{side}:osc-dsp-no-valid-samples")
    if nested(measurement, "crackle", "status") in ("detected", "manual"):
        values.append(f"{side}:crackle-{nested(measurement, 'crackle', 'status')}")
    for name in ("interrupts", "softirqs"):
        counter = nested(measurement, "kernel_counters", name)
        if not isinstance(counter, dict) or not counter.get("available") or not counter.get("complete"):
            values.append(f"{side}:{name}-endpoint-accounting-incomplete")
    for name in ("cpu_policy", "power", "audio"):
        identity = nested(measurement, "endpoint_identity", name)
        if not isinstance(identity, dict):
            values.append(f"{side}:{name}-endpoint-identity-unavailable")
            continue
        if identity.get("changed_within_window"):
            values.append(f"{side}:{name}-changed-within-window")
        for endpoint in ("before", "after"):
            if not nested(identity, endpoint, "available"):
                values.append(f"{side}:{name}-{endpoint}-unavailable")
            if name == "power" and not nested(identity, endpoint, "holds_available"):
                values.append(f"{side}:power-holds-{endpoint}-unavailable")
    return list(dict.fromkeys(values))


def endpoint_identity_value(measurement: dict[str, Any], name: str, endpoint: str) -> Any:
    value = nested(measurement, "endpoint_identity", name, endpoint)
    if not isinstance(value, dict):
        return None
    if name == "cpu_policy":
        return {"available": value.get("available"), "policies": value.get("policies")}
    if name == "audio":
        return audio_endpoint_value(value)
    return {
        "available": value.get("available"), "profile": value.get("profile"),
        "holds_available": value.get("holds_available"), "holds": value.get("holds"),
    }


METRIC_SPECS = (
    ("host_cpu_percent", "Host CPU", "% total capacity", ("process", "details", "host_cpu_percent", "cpu")),
    ("wine_prefix_cpu_percent", "Wine prefix CPU for tasks in both samples", "% one core", ("process", "summary", "wine_prefix", "cpu_percent_of_one_core")),
    ("live_cpu_percent", "Live CPU", "% one core", ("process", "summary", "live", "cpu_percent_of_one_core")),
    ("pipewire_cpu_percent", "PipeWire and WirePlumber CPU", "% one core", ("process", "summary", "pipewire", "cpu_percent_of_one_core")),
    ("pipewire_err", "PipeWire error increase", "events", ("pipewire", "pw_top", "err_delta")),
    ("osc_average_percent", "Reported DSP average", "%", ("osc_dsp", "average_percent")),
    ("osc_peak_percent", "Reported DSP peak", "%", ("osc_dsp", "peak_percent")),
    ("audio_worker_count", "AudioCalc worker count", "threads", ("process", "summary", "live", "audio_worker_count")),
    ("cpu_interval_seconds", "Time between CPU samples", "seconds", ("process", "details", "elapsed_seconds")),
    ("interrupt_rate", "Hardware interrupts", "events/second", ("kernel_counters", "interrupts", "total_rate_per_second")),
    ("softirq_rate", "Software interrupts", "events/second", ("kernel_counters", "softirqs", "total_rate_per_second")),
)


def set_metric_values(measurement: dict[str, Any]) -> dict[str, tuple[str, str, Any]]:
    values = {identifier: (label, unit, nested(measurement, *path)) for identifier, label, unit, path in METRIC_SPECS}
    for endpoint in ("before", "after"):
        for key, label, unit in (
            ("clock.rate", "Sample rate", "frames per second"),
            ("clock.quantum", "Buffer size", "frames"),
        ):
            raw_value = nested(
                measurement, "endpoint_identity", "audio", endpoint, "graph_settings", key,
            )
            try:
                parsed_value = int(raw_value)
            except (TypeError, ValueError):
                parsed_value = None
            values[f"graph_{key.removeprefix('clock.')}_{endpoint}"] = (
                f"{label} at {endpoint} sample", unit, parsed_value,
            )
    values["quantum_transitions"] = ("Buffer size changes", "changes", quantum_transition_count(measurement))
    for group, label in (("live", "Live"), ("wine_prefix", "Wine prefix"), ("pipewire", "PipeWire")):
        values[f"{group}_context_switches"] = (
            f"{label} context switches", "switches", nested(measurement, "process", "summary", group, "context_switches"),
        )
        for key, suffix, unit in (
            ("runtime_ns", "CPU run time", "nanoseconds"),
            ("run_delay_ns", "CPU wait time", "nanoseconds"),
            ("timeslices", "CPU time slices", "time slices"),
        ):
            values[f"{group}_schedstat_{key}"] = (
                f"{label} {suffix}", unit, nested(measurement, "process", "summary", group, "schedstat", key),
            )
    churn = task_churn_counts(measurement)
    for key, label in (
        ("processes_born", "Processes started between samples"),
        ("processes_exited", "Processes ended between samples"),
        ("threads_born", "Threads started between samples"),
        ("threads_exited", "Threads ended between samples"),
        ("total", "Process and thread changes"),
    ):
        values[f"task_churn_{key}"] = (label, "tasks", churn[key])
    for collector in ("pw-top", "pw-metadata", "osc"):
        timing = nested(measurement, "capture_commands", collector, "timing") or {}
        safe = collector.replace("-", "_")
        values[f"{safe}_coverage_seconds"] = (
            f"{collector} run time", "seconds", timing.get("supervision_interval_seconds"),
        )
        values[f"{safe}_output_span_seconds"] = (
            f"{collector} data span", "seconds", timing.get("output_span_seconds"),
        )
        values[f"{safe}_output_lines"] = (
            f"{collector} output lines", "lines", timing.get("output_line_count"),
        )
    return values


def comparison_report(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    before_duration = before["run"]["duration_seconds_per_set"]
    after_duration = after["run"]["duration_seconds_per_set"]
    if before_duration != after_duration:
        raise ValueError(
            f"duration mismatch: before={before_duration}, after={after_duration}; rerun with one common duration"
        )
    identities = [identity_comparison(
        "harness", "Benchmark tool files",
        nested(before["run"], "harness", "identity_hash"),
        nested(after["run"], "harness", "identity_hash"),
    ), *profile_identity_checks(before, after)]
    global_confounders = [
        f"identity:{item['id']}:{item['status']}" for item in identities if item["confounder"]
    ]
    sets = []
    for first, last in zip(before["sets"], after["sets"]):
        confounders = global_confounders + measurement_confounders(first, "before") + measurement_confounders(last, "after")
        if first.get("live") != last.get("live"):
            confounders.append("set-identity:Live-log-runtime/audio-identity")
        if nested(first, "process", "summary", "live", "audio_worker_count") != nested(
            last, "process", "summary", "live", "audio_worker_count"
        ):
            confounders.append("set-identity:observed-worker-count")
        for name, label in (
            ("cpu_policy", "CPU policy"), ("power", "power profile/holds"),
            ("audio", "audio defaults/profile/graph"),
        ):
            for endpoint in ("before", "after"):
                if endpoint_identity_value(first, name, endpoint) != endpoint_identity_value(last, name, endpoint):
                    confounders.append(f"set-identity:{label}-{endpoint}")
        confounders = list(dict.fromkeys(confounders))
        first_values, last_values = set_metric_values(first), set_metric_values(last)
        metrics = {}
        for identifier, (label, unit, first_value) in first_values.items():
            metrics[identifier] = metric_comparison(
                label, unit, first_value, last_values.get(identifier, (label, unit, None))[2], confounders,
            )
        metrics["crackle_status"] = metric_comparison(
            "Crackle status", "category", nested(first, "crackle", "status"),
            nested(last, "crackle", "status"), confounders, numeric=False,
        )
        for name, label in (
            ("cpu_policy", "CPU policy"), ("power", "Power profile and active requests"),
            ("audio", "Audio defaults/profile/graph"),
        ):
            for endpoint in ("before", "after"):
                metrics[f"{name}_{endpoint}"] = metric_comparison(
                    f"{label} at {endpoint} sample", "category",
                    endpoint_identity_value(first, name, endpoint),
                    endpoint_identity_value(last, name, endpoint),
                    confounders, numeric=False,
                )
        sets.append({
            "set": first["set"], "mode": first["mode"], "confounded": bool(confounders),
            "confounders": confounders, "metrics": metrics,
            "kernel_counters": {"before": first.get("kernel_counters"), "after": last.get("kernel_counters")},
        })
    return {
        "schema": SCHEMA,
        "kind": "benchmark-comparison",
        "generated_at": utc_now(),
        "interpretation": (
            "One before and one after run describe one pair. Repeat pairs to measure normal variation. "
            "Use tool and listener reports for audio results."
        ),
        "structure": {"compatible": True, "canonical_set_order": list(CANONICAL_SETS),
                      "duration_seconds_per_set": before_duration},
        "before": {"directory": before["directory"], "tag": before["run"].get("tag")},
        "after": {"directory": after["directory"], "tag": after["run"].get("tag")},
        "identity": identities,
        "identity_confounders": global_confounders,
        "sets": sets,
    }


def markdown_value(value: Any) -> str:
    if value is None:
        return "pending"
    if isinstance(value, float):
        return f"{value:.4f}"
    if isinstance(value, (str, int, bool)):
        rendered = str(value).replace("|", "\\|").replace("\n", " ")
        return rendered if len(rendered) <= 64 else rendered[:61] + "..."
    rendered = json.dumps(value, sort_keys=True, separators=(",", ":"))
    if len(rendered) <= 64:
        return rendered.replace("|", "\\|")
    return f"sha256:{canonical_digest(value)[:16]}"


def markdown_metric(metric: dict[str, Any]) -> str:
    before, after = markdown_value(metric["before"]), markdown_value(metric["after"])
    if metric["unit"] == "category":
        return f"{before} → {after}"
    change = (
        f"{metric['percent_change']:.2f}%" if metric["percent_change"] is not None
        else metric["percent_status"]
    )
    return f"{before} → {after} ({change})"


def comparison_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Ableton Linux benchmark comparison",
        "",
        f"- Before: `{report['before'].get('tag') or 'pending'}` at `{report['before']['directory']}`",
        f"- After: `{report['after'].get('tag') or 'pending'}` at `{report['after']['directory']}`",
        f"- Measurement time: {report['structure']['duration_seconds_per_set']} seconds per set",
        f"- Run detail differences: {len(report['identity_confounders'])}",
        "",
        "> One pair describes one result. Repeat pairs to measure normal variation. Use tool and listener reports for audio results.",
        "",
        "## Run detail differences",
        "",
    ]
    changed = [item for item in report["identity"] if item["confounder"]]
    if changed:
        for item in changed:
            lines.append(
                f"- {item['label']}: {item['status']}; before `{markdown_value(item['before'])}`, "
                f"after `{markdown_value(item['after'])}`"
            )
    else:
        lines.append("All run details match.")
    summary_metrics = (
        "host_cpu_percent", "wine_prefix_cpu_percent", "live_cpu_percent", "pipewire_cpu_percent",
        "interrupt_rate", "softirq_rate", "pipewire_err", "osc_average_percent", "osc_peak_percent",
        "graph_rate_before", "graph_quantum_before", "audio_worker_count", "crackle_status",
    )
    lines.extend(["", "## Set summary", "", "| Set | " + " | ".join(
        report["sets"][0]["metrics"][name]["label"] for name in summary_metrics
    ) + " | Review items |", "|---|" + "---:|" * len(summary_metrics) + "---:|"])
    for item in report["sets"]:
        lines.append(f"| {item['set']} | " + " | ".join(
            markdown_metric(item["metrics"][name]) for name in summary_metrics
        ) + f" | {len(item['confounders'])} |")
    lines.extend([
        "",
        "`comparison.json` contains context switches, scheduler values, process changes, tool timing, power settings, CPU policy, interrupts, and zero starting values.",
        "",
    ])
    return "\n".join(lines)


CPU_BENCHMARK_CSV_FIELDS = (
    "csv_schema", "machine_id", "machine_id_scope", "run_created_at_utc",
    "report_generated_at_utc", "run_status", "tag", "duration_seconds_per_set",
    "row_kind", "set", "mode", "set_started_at_utc", "set_ended_at_utc",
    "resource_expected_sample_count", "resource_sample_count", "resource_missed_sample_count",
    "resource_coverage_complete", "resource_maximum_lateness_seconds",
    "resource_sample_index", "resource_sample_timestamp_utc",
    "resource_sample_scheduled_seconds", "resource_sample_elapsed_seconds",
    "resource_sample_lateness_seconds", "resource_sample_interval_seconds",
    "resource_collection_seconds", "resource_sample_complete", "resource_unavailable",
    "host_cpu_busy_percent", "host_cpu_idle_percent", "host_cpu_iowait_percent",
    "host_cpu_steal_percent", "load_1m", "load_5m", "load_15m", "runnable_tasks",
    "total_tasks", "memory_total_bytes", "memory_available_bytes", "swap_total_bytes",
    "swap_free_bytes", "filesystem_total_bytes", "filesystem_available_bytes",
    "cpu_pressure_some_percent", "cpu_pressure_full_percent",
    "memory_pressure_some_percent", "memory_pressure_full_percent",
    "io_pressure_some_percent", "io_pressure_full_percent",
    "window_host_cpu_percent", "live_cpu_percent_of_one_core",
    "wine_cpu_percent_of_one_core", "pipewire_cpu_percent_of_one_core",
    "audio_worker_count", "hardware_interrupts_per_second",
    "software_interrupts_per_second", "pipewire_error_delta", "dsp_average_percent",
    "dsp_peak_percent", "sample_rate_hz", "buffer_frames", "crackle_status",
    "machine_profile_sha256", "operating_system", "kernel", "cpu_model", "logical_cpus",
    "gpu", "audio_card_count", "power_profile_before_live", "pipewire_version",
    "wireplumber_version", "wine_version", "runtime_identity_sha256",
    "prefix_identity_sha256", "configuration_identity_sha256", "live_version",
    "live_executable_sha256",
)


def spreadsheet_cell(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    stripped = value.lstrip()
    if stripped.startswith(("=", "+", "-", "@")) or value.startswith(("\t", "\r", "\n")):
        return "'" + value
    return value


def benchmark_csv_contract(run: dict[str, Any]) -> tuple[str, str] | None:
    machine_id = nested(run, "machine", "id")
    csv_value = run.get("csv")
    if machine_id is None and csv_value is None:
        return None
    if not isinstance(csv_value, dict):
        raise ValueError("run CSV details must be an object")
    if csv_value.get("schema") != CSV_SCHEMA:
        raise ValueError(f"run CSV schema must be {CSV_SCHEMA}")
    created_at = run.get("created_at")
    if not isinstance(machine_id, str) or not isinstance(created_at, str):
        raise ValueError("run must provide a 32-character report source ID and creation time")
    expected = cpu_benchmark_csv_filename(machine_id, created_at)
    filename = csv_value.get("filename")
    if filename != expected or Path(expected).name != expected:
        raise ValueError("run CSV filename must match its report source ID and creation time")
    if csv_value.get("timestamp") != filename_timestamp(created_at):
        raise ValueError("run CSV timestamp must match its creation time")
    return machine_id, filename


def csv_profile_values(profile_value: dict[str, Any], profile_sha256: str | None) -> dict[str, Any]:
    system = profile_value.get("system", {})
    uname_fields = str(system.get("uname", "")).split()
    os_release = system.get("os_release", {})
    cpu = system.get("cpu", {})
    audio = system.get("audio_devices", {})
    alsa_cards = str(audio.get("alsa_cards", ""))
    filesystem = system.get("report_filesystem", {})
    runtime = profile_value.get("runtime", {})
    prefix = profile_value.get("prefix", {})
    configuration = profile_value.get("configuration", {})
    pipewire = profile_value.get("pipewire", {})
    executables = profile_value.get("live", {}).get("executables", [])
    return {
        "machine_profile_sha256": profile_sha256,
        "operating_system": os_release.get("PRETTY_NAME") or os_release.get("NAME") or os_release.get("ID"),
        "kernel": uname_fields[2] if len(uname_fields) >= 3 else None,
        "cpu_model": cpu.get("Model name"),
        "logical_cpus": cpu.get("CPU(s)"),
        "memory_total_bytes": nested(system, "memory", "MemTotal"),
        "filesystem_total_bytes": filesystem.get("total_bytes"),
        "filesystem_available_bytes": filesystem.get("available_bytes"),
        "gpu": "; ".join(system.get("gpu_lines", [])),
        "audio_card_count": sum(bool(re.match(r"^\s*\d+\s+\[", line)) for line in alsa_cards.splitlines()),
        "power_profile_before_live": system.get("power_profile"),
        "pipewire_version": nested(pipewire, "versions", "pipewire"),
        "wireplumber_version": nested(pipewire, "versions", "wireplumber"),
        "wine_version": runtime.get("wine_version"),
        "runtime_identity_sha256": runtime.get("identity_hash"),
        "prefix_identity_sha256": prefix.get("identity_hash"),
        "configuration_identity_sha256": configuration.get("identity_hash"),
        "live_version": ";".join(sorted({
            str(item["product_version"]) for item in executables if item.get("product_version")
        })),
        "live_executable_sha256": ";".join(sorted({
            str(item["sha256"]) for item in executables if item.get("sha256")
        })),
    }


def csv_set_values(measurement: dict[str, Any]) -> dict[str, Any]:
    summary = nested(measurement, "process", "summary") or {}
    details = nested(measurement, "process", "details") or {}
    counters = measurement.get("kernel_counters", {})
    pw_top = nested(measurement, "pipewire", "pw_top") or {}
    dsp = measurement.get("osc_dsp", {})
    live = measurement.get("live", {})
    audio_settings = nested(measurement, "endpoint_identity", "audio", "before", "graph_settings") or {}
    resources = measurement.get("system_resources", {})
    return {
        "set": measurement.get("set"),
        "mode": measurement.get("mode"),
        "set_started_at_utc": measurement.get("started_at"),
        "set_ended_at_utc": measurement.get("ended_at"),
        "resource_expected_sample_count": resources.get("expected_sample_count"),
        "resource_sample_count": resources.get("sample_count"),
        "resource_missed_sample_count": resources.get("missed_sample_count"),
        "resource_coverage_complete": resources.get("coverage_complete"),
        "resource_maximum_lateness_seconds": resources.get("maximum_schedule_lateness_seconds"),
        "window_host_cpu_percent": nested(details, "host_cpu_percent", "cpu"),
        "live_cpu_percent_of_one_core": nested(summary, "live", "cpu_percent_of_one_core"),
        "wine_cpu_percent_of_one_core": nested(summary, "wine_prefix", "cpu_percent_of_one_core"),
        "pipewire_cpu_percent_of_one_core": nested(summary, "pipewire", "cpu_percent_of_one_core"),
        "audio_worker_count": nested(summary, "live", "audio_worker_count"),
        "hardware_interrupts_per_second": nested(counters, "interrupts", "total_rate_per_second"),
        "software_interrupts_per_second": nested(counters, "softirqs", "total_rate_per_second"),
        "pipewire_error_delta": pw_top.get("err_delta"),
        "dsp_average_percent": dsp.get("average_percent"),
        "dsp_peak_percent": dsp.get("peak_percent"),
        "sample_rate_hz": live.get("sample_rate") or audio_settings.get("clock.rate"),
        "buffer_frames": live.get("output_buffer_frames") or audio_settings.get("clock.quantum"),
        "crackle_status": nested(measurement, "crackle", "status"),
    }


def csv_resource_values(sample: dict[str, Any] | None) -> dict[str, Any]:
    if sample is None:
        return {"row_kind": "set-summary"}
    availability = sample.get("availability", {})
    unavailable = sorted(name for name, available in availability.items() if not available)
    return {
        "row_kind": "resource-sample",
        "resource_sample_index": sample.get("index"),
        "resource_sample_timestamp_utc": sample.get("captured_at"),
        "resource_sample_scheduled_seconds": sample.get("scheduled_elapsed_seconds"),
        "resource_sample_elapsed_seconds": sample.get("elapsed_seconds"),
        "resource_sample_lateness_seconds": sample.get("schedule_lateness_seconds"),
        "resource_sample_interval_seconds": sample.get("interval_seconds"),
        "resource_collection_seconds": sample.get("collection_seconds"),
        "resource_sample_complete": bool(availability) and all(availability.values()),
        "resource_unavailable": ";".join(unavailable),
        "host_cpu_busy_percent": nested(sample, "cpu", "busy_percent"),
        "host_cpu_idle_percent": nested(sample, "cpu", "idle_percent"),
        "host_cpu_iowait_percent": nested(sample, "cpu", "iowait_percent"),
        "host_cpu_steal_percent": nested(sample, "cpu", "steal_percent"),
        "load_1m": nested(sample, "load", "load_1m"),
        "load_5m": nested(sample, "load", "load_5m"),
        "load_15m": nested(sample, "load", "load_15m"),
        "runnable_tasks": nested(sample, "load", "runnable_tasks"),
        "total_tasks": nested(sample, "load", "total_tasks"),
        "memory_total_bytes": nested(sample, "memory", "total_bytes"),
        "memory_available_bytes": nested(sample, "memory", "available_bytes"),
        "swap_total_bytes": nested(sample, "memory", "swap_total_bytes"),
        "swap_free_bytes": nested(sample, "memory", "swap_free_bytes"),
        **{
            f"{name}_pressure_{kind}_percent": nested(sample, "pressure", name, f"{kind}_percent")
            for name in ("cpu", "memory", "io") for kind in ("some", "full")
        },
    }


def benchmark_csv_rows(report: dict[str, Any], profile_sha256: str | None) -> list[dict[str, Any]]:
    run = report["run"]
    profile_value = report.get("profile", {})
    common = {
        "csv_schema": CSV_SCHEMA,
        "machine_id": nested(run, "machine", "id"),
        "machine_id_scope": nested(run, "machine", "scope"),
        "run_created_at_utc": run.get("created_at"),
        "report_generated_at_utc": report.get("generated_at"),
        "run_status": run.get("status"),
        "tag": run.get("tag"),
        "duration_seconds_per_set": run.get("duration_seconds_per_set"),
        **csv_profile_values(profile_value, profile_sha256),
    }
    rows = []
    for measurement in report.get("sets", []):
        set_values = csv_set_values(measurement)
        samples = nested(measurement, "system_resources", "samples")
        sample_values = samples if isinstance(samples, list) and samples else [None]
        for sample in sample_values:
            rows.append({**common, **set_values, **csv_resource_values(sample)})
    if not rows:
        rows.append({**common, "row_kind": "profile"})
    return rows


def write_benchmark_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    descriptor = -1
    temporary: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as output:
            descriptor = -1
            writer = csv.DictWriter(output, fieldnames=CPU_BENCHMARK_CSV_FIELDS, extrasaction="raise", lineterminator="\n")
            writer.writeheader()
            for row in rows:
                writer.writerow({name: spreadsheet_cell(row.get(name)) for name in CPU_BENCHMARK_CSV_FIELDS})
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def compare(args: argparse.Namespace) -> int:
    try:
        before = load_completed_run(Path(args.before))
        after = load_completed_run(Path(args.after))
        result = comparison_report(before, after)
        output = Path(args.output).resolve()
        if output.exists():
            raise ValueError(f"output already exists: {output}")
        before_path, after_path = Path(before["directory"]), Path(after["directory"])
        if output in (before_path, after_path) or before_path in output.parents or after_path in output.parents:
            raise ValueError("comparison output must be outside both source run directories")
        output.mkdir(parents=True)
        dump_json(output / "comparison.json", result)
        (output / "comparison.md").write_text(comparison_markdown(result))
        return 0
    except (ValueError, OSError) as error:
        print(f"comparison refused: {error}", file=sys.stderr)
        return 2


def render(args: argparse.Namespace) -> int:
    try:
        run_dir = Path(args.run_dir).resolve()
        run_path = run_dir / "run.json"
        if not run_path.is_file():
            raise ValueError(f"report needs {run_path}")
        run = load_json_object(run_path)
        csv_contract = benchmark_csv_contract(run)
        profile_path = run_dir / "profile/profile.json"
        profile_value = load_json_object(profile_path) if profile_path.is_file() else {}
        if csv_contract and profile_path.is_file() and nested(profile_value, "machine", "id") != csv_contract[0]:
            raise ValueError("run and profile must use the same benchmark report source ID")
        sets = []
        for name in run.get("set_order", []):
            matches = list((run_dir / "sets").glob(f"*-{name}/measurement.json"))
            if matches:
                sets.append(load_json_object(matches[0]))
        profile_sha256 = sha256_file(profile_path).get("sha256") if profile_path.is_file() else None
        report = {
            "schema": SCHEMA,
            "kind": "benchmark-report",
            "generated_at": utc_now(),
            "run": run,
            "profile": profile_value,
            "profile_file": {"path": "profile/profile.json", "sha256": profile_sha256},
            "sets": sets,
        }
        if csv_contract:
            machine_id, filename = csv_contract
            rows = benchmark_csv_rows(report, profile_sha256)
            report["csv"] = {
                "schema": CSV_SCHEMA,
                "filename": filename,
                "machine_id": machine_id,
                "row_count": len(rows),
                "resource_sample_count": sum(row.get("row_kind") == "resource-sample" for row in rows),
            }
            csv_path = run_dir / filename
            write_benchmark_csv(csv_path, rows)
            report["csv"]["sha256"] = sha256_file(csv_path).get("sha256")
        dump_json(run_dir / "report.json", report)
        (run_dir / "report.md").write_text(markdown_report(report))
        return 0
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"report: {error}", file=sys.stderr)
        return 2


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
        collector_observed(measurement, "pw-top")
        and bool(pw_top.get("instrumented")) and not bool(pw_top.get("identity_confounded")),
        int(pw_top.get("err_delta", 0)),
        int(logs.get("xrun_line_count", 0)), args.manual_crackle,
    )
    measurement["crackle"]["annotated_at"] = utc_now()
    dump_json(matches[0], measurement)
    return render(argparse.Namespace(run_dir=str(run_dir)))


def udp_available(args: argparse.Namespace) -> int:
    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", args.port))
    except OSError as error:
        print(f"UDP 127.0.0.1:{args.port} unavailable: {error}", file=sys.stderr)
        return 1
    finally:
        if sock is not None:
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
    capture_parser = commands.add_parser("capture", help="measure one set for the selected time")
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

    profile_parser = commands.add_parser("profile", help="record system and software details")
    profile_parser.add_argument("--output", required=True)
    profile_parser.add_argument("--prefix", required=True)
    profile_parser.add_argument("--wine-root", required=True)
    profile_parser.add_argument("--config-file", required=True)
    profile_parser.add_argument("--run-file", help="reuse the report source ID from this run record")
    profile_parser.set_defaults(func=profile)

    init_parser = commands.add_parser("init-run", help="create the run record")
    init_parser.add_argument("--output", required=True)
    init_parser.add_argument("--tag", required=True)
    init_parser.add_argument("--duration", type=positive_duration, default=30)
    init_parser.add_argument("--set", action="append", required=True)
    init_parser.set_defaults(func=init_run)

    update_parser = commands.add_parser("update-run", help="record the final run status")
    update_parser.add_argument("--output", required=True)
    update_parser.add_argument("--status", choices=("complete", "failed", "interrupted"), required=True)
    update_parser.set_defaults(func=update_run)

    render_parser = commands.add_parser("render", help="create the JSON and Markdown report")
    render_parser.add_argument("--run-dir", required=True)
    render_parser.set_defaults(func=render)

    compare_parser = commands.add_parser(
        "compare", help="compare two completed runs"
    )
    compare_parser.add_argument("--before", required=True, help="before run folder")
    compare_parser.add_argument("--after", required=True, help="after run folder")
    compare_parser.add_argument("--output", required=True, help="new comparison folder")
    compare_parser.set_defaults(func=compare)

    annotate_parser = commands.add_parser("annotate", help="add a listener crackle report")
    annotate_parser.add_argument("--run-dir", required=True)
    annotate_parser.add_argument("--set-name", choices=CANONICAL_SETS, required=True)
    annotate_parser.add_argument("--manual-crackle", choices=("heard", "not-heard", "unknown"), required=True)
    annotate_parser.set_defaults(func=annotate)

    udp_parser = commands.add_parser("check-udp", help="check the OSC report port")
    udp_parser.add_argument("--port", type=int, default=19002)
    udp_parser.set_defaults(func=udp_available)
    return root


def main() -> int:
    args = parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
