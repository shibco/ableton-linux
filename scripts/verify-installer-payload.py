#!/usr/bin/env python3
"""Inspect a release installer as data and compare it with trusted inputs."""

from __future__ import annotations

import argparse
import hashlib
import mmap
import os
from pathlib import Path, PurePosixPath
import posixpath
import stat
import subprocess
import sys
import tarfile
import tempfile


MAX_WRAPPER_BYTES = 768 * 1024 * 1024
MAX_MEMBER_BYTES = 512 * 1024 * 1024
MAX_LOGICAL_BYTES = 1024 * 1024 * 1024
MAX_MEMBERS = 1024
MARKER = b"__PAYLOAD_BELOW__\n"


class VerificationError(Exception):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def regular_file(path: Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if not stat.S_ISREG(mode):
        fail(f"{label} must be a regular, non-symlink file: {path}")


def archive_path(name: str) -> str:
    if name == ".":
        return ""
    if not name.startswith("./"):
        fail(f"archive member is not in canonical ./ form: {name!r}")
    relative = name[2:]
    pure = PurePosixPath(relative)
    if not relative or pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
        fail(f"archive member has an unsafe path: {name!r}")
    if str(pure) != relative:
        fail(f"archive member path is not normalised: {name!r}")
    return relative


def safe_link(path: str, target: str) -> None:
    if not target or target.startswith("/"):
        fail(f"archive symlink {path!r} has an unsafe target: {target!r}")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
    if resolved == ".." or resolved.startswith("../"):
        fail(f"archive symlink {path!r} escapes the kit: {target!r}")


class Expected:
    def __init__(self, kind: str, mode: int, data: bytes | None = None, target: str | None = None):
        self.kind = kind
        self.mode = mode
        self.data = data
        self.target = target


def add_parents(expected: dict[str, Expected], path: str) -> None:
    parent = PurePosixPath(path).parent
    while str(parent) not in ("", "."):
        expected.setdefault(str(parent), Expected("dir", 0o755))
        parent = parent.parent
    expected.setdefault("", Expected("dir", 0o755))


def add_source(expected: dict[str, Expected], source: Path, destination: str, mode: int) -> None:
    try:
        source_mode = source.lstat().st_mode
    except FileNotFoundError:
        fail(f"trusted kit source is missing: {source}")
    if stat.S_ISLNK(source_mode):
        target = os.readlink(source)
        safe_link(destination, target)
        expected[destination] = Expected("symlink", 0o777, target=target)
    elif stat.S_ISREG(source_mode):
        expected[destination] = Expected("file", mode, data=source.read_bytes())
    else:
        fail(f"trusted kit source has an unsupported type: {source}")
    add_parents(expected, destination)


def tracked_paths(root: Path, *paths: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", *paths],
        check=True,
        stdout=subprocess.PIPE,
    )
    return sorted(item.decode("utf-8", "surrogateescape") for item in result.stdout.split(b"\0") if item)


def expected_from_source(root: Path, info: Path, runtime: Path) -> dict[str, Expected]:
    expected: dict[str, Expected] = {"": Expected("dir", 0o755)}

    for name in ("VERSION", "README.md", "TROUBLESHOOTING.md", "LICENCE"):
        add_source(expected, root / name, name, 0o644)

    executable_scripts = {
        "installer.sh", "install.sh", "setup-prefix.sh", "uninstall.sh",
        "ableton-live", "max9", "detect-scale.sh", "detect-theme.sh",
        "shortcut-hold.sh", "check-live-audio.sh", "check-ntsync.sh", "setup-link.sh",
        "ableton-linkctl", "setup-realtime.sh", "audio-report.sh", "rollback.sh",
    }
    for name in sorted(executable_scripts):
        add_source(expected, root / "scripts" / name, f"scripts/{name}", 0o755)
    for name in ("ableton-linkd.service",):
        add_source(expected, root / "scripts" / name, f"scripts/{name}", 0o644)
    for name in ("config.sh", "lifecycle.sh", "live-options.sh", "manifest.sh", "pipeasio.sh", "ui.sh"):
        add_source(expected, root / "scripts/lib" / name, f"scripts/lib/{name}", 0o644)
    add_source(expected, root / "tools/setsyscolors.exe", "scripts/setsyscolors.exe", 0o644)
    add_source(expected, root / "tools/learnheal.exe", "scripts/learnheal.exe", 0o644)
    add_source(
        expected,
        root / "beta/tester-kit/probes/windows/ntsyncprobe.exe",
        "scripts/ntsyncprobe.exe",
        0o644,
    )

    for source_name in tracked_paths(root, "desktop", "vendor/winetricks", "vendor/winetricks-cache"):
        mode = 0o755 if os.access(root / source_name, os.X_OK, follow_symlinks=False) else 0o644
        add_source(expected, root / source_name, source_name, mode)
    for source_name in tracked_paths(root, "vendor/fonts/bitstream-vera"):
        add_source(expected, root / source_name, source_name, 0o644)
    add_source(expected, root / "vendor/link-4.0.tar.zst", "vendor/link-4.0.tar.zst", 0o644)

    add_source(expected, info, info.name, 0o644)
    add_source(expected, runtime, f"dist/{runtime.name}", 0o644)
    add_source(expected, Path(f"{runtime}.sha256"), f"dist/{runtime.name}.sha256", 0o644)
    add_source(
        expected,
        root / "vendor/fonts/bitstream-vera/COPYRIGHT.TXT",
        "licenses/bitstream-vera-COPYRIGHT.txt",
        0o644,
    )

    source_notice = (
        b"ableton-linkd is built from Ableton Link 4.0, GPLv2+; complete corresponding\n"
        b"source is in vendor/link-4.0.tar.zst in this kit and at https://github.com/Ableton/link\n"
    )
    expected["licenses/SOURCE.txt"] = Expected("file", 0o644, data=source_notice)
    add_parents(expected, "licenses/SOURCE.txt")
    license_result = subprocess.run(
        ["tar", "-I", "zstd", "-xOf", str(root / "vendor/link-4.0.tar.zst"), "./LICENSE.md"],
        check=True,
        stdout=subprocess.PIPE,
    )
    expected["licenses/link-LICENSE.md"] = Expected("file", 0o644, data=license_result.stdout)
    add_parents(expected, "licenses/link-LICENSE.md")

    for path in ("bin/cabextract", "bin/ableton-linkd", "bin/pipewire-version-probe"):
        expected[path] = Expected("file", 0o755)
        add_parents(expected, path)
    return expected


def expected_from_directory(directory: Path) -> dict[str, Expected]:
    expected: dict[str, Expected] = {}

    def visit(path: Path, relative: str) -> None:
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            expected[relative] = Expected("dir", stat.S_IMODE(mode))
            for child in sorted(path.iterdir(), key=lambda item: os.fsencode(item.name)):
                child_relative = child.name if not relative else f"{relative}/{child.name}"
                visit(child, child_relative)
        elif stat.S_ISLNK(mode):
            target = os.readlink(path)
            safe_link(relative, target)
            expected[relative] = Expected("symlink", stat.S_IMODE(mode), target=target)
        elif stat.S_ISREG(mode):
            expected[relative] = Expected("file", stat.S_IMODE(mode), data=path.read_bytes())
        else:
            fail(f"expected kit contains an unsupported file type: {path}")

    visit(directory, "")
    return expected


def member_digest(archive: tarfile.TarFile, member: tarfile.TarInfo) -> tuple[str, bytes | None]:
    handle = archive.extractfile(member)
    if handle is None:
        fail(f"could not read regular archive member: {member.name!r}")
    digest = hashlib.sha256()
    collected = bytearray() if member.size <= 4 * 1024 * 1024 else None
    for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
        digest.update(chunk)
        if collected is not None:
            collected.extend(chunk)
    return digest.hexdigest(), bytes(collected) if collected is not None else None


def build_info_hash(info: Path, key: bytes) -> str:
    prefix = key + b":"
    values = [line.split(b":", 1)[1].strip() for line in info.read_bytes().splitlines() if line.startswith(prefix)]
    if len(values) != 1:
        fail(f"BUILD-INFO must contain exactly one {key.decode('ascii')} record")
    try:
        value = values[0].decode("ascii")
    except UnicodeDecodeError:
        fail(f"BUILD-INFO {key.decode('ascii')} record is not ASCII")
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        fail(f"BUILD-INFO {key.decode('ascii')} record is not a SHA-256 digest")
    return value


def compare_payload(payload: Path, expected: dict[str, Expected], info: Path) -> None:
    seen: dict[str, tarfile.TarInfo] = {}
    logical_bytes = 0
    member_end = 0
    zero_ranges: list[tuple[int, int]] = []
    with tarfile.open(payload, mode="r:") as archive:
        for member in archive:
            if len(seen) >= MAX_MEMBERS:
                fail(f"installer payload has more than {MAX_MEMBERS} archive members")
            path = archive_path(member.name)
            if path in seen:
                fail(f"installer payload contains a duplicate member: {member.name!r}")
            seen[path] = member
            if member.pax_headers:
                fail(f"installer payload uses unsupported extended metadata: {member.name!r}")
            if member.offset_data != member.offset + tarfile.BLOCKSIZE:
                fail(f"installer payload uses a non-canonical member header: {member.name!r}")
            if member.uid != 0 or member.gid != 0:
                fail(f"installer payload member is not owned by numeric 0:0: {member.name!r}")
            if member.isfile():
                if member.size > MAX_MEMBER_BYTES:
                    fail(f"installer payload member is too large: {member.name!r}")
                if getattr(member, "sparse", None):
                    fail(f"installer payload contains a sparse file: {member.name!r}")
                logical_bytes += member.size
                data_end = member.offset_data + member.size
                padded_end = (
                    (data_end + tarfile.BLOCKSIZE - 1) // tarfile.BLOCKSIZE
                ) * tarfile.BLOCKSIZE
                if padded_end > data_end:
                    zero_ranges.append((data_end, padded_end))
            elif member.isdir():
                if member.size != 0:
                    fail(f"installer directory has non-canonical data: {member.name!r}")
                padded_end = member.offset_data
            elif member.issym():
                if member.size != 0:
                    fail(f"installer symlink has non-canonical data: {member.name!r}")
                safe_link(path, member.linkname)
                padded_end = member.offset_data
            else:
                fail(f"installer payload contains an unsupported member type: {member.name!r}")
            member_end = max(member_end, padded_end)
        if logical_bytes > MAX_LOGICAL_BYTES:
            fail(f"installer payload expands past the logical size limit: {logical_bytes} bytes")

        # make-installer.sh writes a GNU tar archive. Require that exact record
        # shape and treat every byte outside member content as format padding.
        # Python's tar reader otherwise stops at the first EOF record and would
        # silently accept arbitrary data hidden in the signed payload suffix.
        payload_size = payload.stat().st_size
        if payload_size % tarfile.RECORDSIZE != 0:
            fail("installer payload is not aligned to a complete GNU tar record")
        if payload_size < member_end + (2 * tarfile.BLOCKSIZE):
            fail("installer payload has no complete tar EOF record")
        zero_ranges.append((member_end, payload_size))
        with payload.open("rb") as raw:
            for start, end in zero_ranges:
                raw.seek(start)
                remaining = end - start
                while remaining:
                    chunk = raw.read(min(4 * 1024 * 1024, remaining))
                    if not chunk or chunk.strip(b"\0"):
                        fail("installer payload has non-zero tar padding or trailing data")
                    remaining -= len(chunk)

        actual_paths = set(seen)
        expected_paths = set(expected)
        missing = sorted(expected_paths - actual_paths)
        extra = sorted(actual_paths - expected_paths)
        if missing:
            fail(f"installer payload is missing expected member: {missing[0]}")
        if extra:
            fail(f"installer payload contains unexpected member: {extra[0]}")

        for path in sorted(expected):
            wanted = expected[path]
            member = seen[path]
            actual_kind = "file" if member.isfile() else "dir" if member.isdir() else "symlink"
            if actual_kind != wanted.kind:
                fail(f"installer payload member has the wrong type: {path or '.'}")
            if stat.S_IMODE(member.mode) != wanted.mode:
                fail(
                    f"installer payload member has mode {stat.S_IMODE(member.mode):04o}, "
                    f"expected {wanted.mode:04o}: {path or '.'}"
                )
            if wanted.kind == "symlink":
                if member.linkname != wanted.target:
                    fail(f"installer payload symlink target differs from source: {path}")
            elif wanted.kind == "file":
                actual_hash, small_data = member_digest(archive, member)
                if wanted.data is not None:
                    expected_hash = hashlib.sha256(wanted.data).hexdigest()
                    if member.size != len(wanted.data) or actual_hash != expected_hash:
                        fail(f"installer payload file differs from its trusted input: {path}")
                generated_records = {
                    "bin/pipewire-version-probe": b"pipewire-version-probe",
                    "bin/cabextract": b"cabextract-static",
                    "bin/ableton-linkd": b"ableton-linkd",
                }
                if path in generated_records:
                    if build_info_hash(info, generated_records[path]) != actual_hash:
                        fail(f"installer {path} does not match BUILD-INFO")


def verify(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    installer = args.installer.resolve()
    info = args.info.resolve()
    runtime = args.runtime.resolve()
    template = root / "scripts/setup-run-header.sh"
    renderer = root / "scripts/lib/ui.sh"
    for path, label in (
        (installer, "installer"), (info, "BUILD-INFO"), (runtime, "runtime"),
        (Path(f"{runtime}.sha256"), "runtime checksum"), (template, "trusted installer header"),
        (renderer, "trusted installer renderer"),
    ):
        regular_file(path, label)
    wrapper_size = installer.stat().st_size
    if wrapper_size > MAX_WRAPPER_BYTES:
        fail(f"installer is larger than the verification limit: {wrapper_size} bytes")

    with installer.open("rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
        first = mapped.find(MARKER)
        if first < 0 or mapped.find(MARKER, first + len(MARKER)) >= 0:
            fail("installer must contain exactly one payload marker")
        payload_offset = first + len(MARKER)

    digest = hashlib.sha256()
    with tempfile.NamedTemporaryFile(prefix="ableton-installer-payload.", suffix=".tar") as payload:
        with installer.open("rb") as source:
            source.seek(payload_offset)
            for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
                digest.update(chunk)
                payload.write(chunk)
        payload.flush()
        payload_sha = digest.hexdigest()
        # The packer inlines the renderer at the @UI_LIB@ line before it
        # fills the two markers (make-installer.sh render_header).
        trusted_header = template.read_bytes()
        if trusted_header.count(b"@UI_LIB@\n") != 1:
            fail("trusted installer header does not carry exactly one @UI_LIB@ line")
        trusted_header = trusted_header.replace(b"@UI_LIB@\n", renderer.read_bytes())
        trusted_header = trusted_header.replace(b"@VERSION@", args.version.encode("ascii"))
        trusted_header = trusted_header.replace(b"@PAYLOAD_SHA@", payload_sha.encode("ascii"))
        with installer.open("rb") as candidate:
            candidate_header = candidate.read(payload_offset)
        if candidate_header != trusted_header:
            fail("installer header does not byte-match the trusted release template")

        if args.expected_kit is not None:
            expected = expected_from_directory(args.expected_kit.resolve())
        else:
            expected = expected_from_source(root, info, runtime)
        required = {
            info.name,
            f"dist/{runtime.name}",
            f"dist/{runtime.name}.sha256",
            "scripts/installer.sh",
        }
        missing_required = sorted(required - set(expected))
        if missing_required:
            fail(f"trusted kit definition is incomplete: {missing_required[0]}")
        for required_path, source_path in (
            (info.name, info),
            (f"dist/{runtime.name}", runtime),
            (f"dist/{runtime.name}.sha256", Path(f"{runtime}.sha256")),
        ):
            wanted = expected[required_path]
            source_data = source_path.read_bytes()
            if wanted.kind != "file" or wanted.data != source_data:
                fail(f"trusted kit does not contain the selected release input: {required_path}")
        compare_payload(Path(payload.name), expected, info)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--installer", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--info", type=Path, required=True)
    parser.add_argument("--expected-kit", type=Path)
    args = parser.parse_args()
    try:
        verify(args)
    except (VerificationError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"!! {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
