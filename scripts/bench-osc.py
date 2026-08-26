#!/usr/bin/env python3
"""Small OSC client for the abl-bench-m4l benchmark device.

Usage:
  bench-osc.py send ADDRESS [ARG ...]
  bench-osc.py dump [--duration SECONDS]
  bench-osc.py probe [--timeout SECONDS]

The device receives on UDP 19001 and reports on 19002.  Environment
ABL_BENCH_OSC_SEND/ABL_BENCH_OSC_RECV override those ports.
"""

from __future__ import annotations

import argparse
import os
import secrets
import select
import signal
import socket
import struct
import sys
import time


signal.signal(signal.SIGPIPE, signal.SIG_DFL)
SEND_PORT = int(os.environ.get("ABL_BENCH_OSC_SEND", 19001))
RECV_PORT = int(os.environ.get("ABL_BENCH_OSC_RECV", 19002))


def pad(value: bytes) -> bytes:
    # OSC strings are NUL terminated even when their text length is already a
    # multiple of four, then padded to the next four-byte boundary.
    return value + b"\x00" * (4 - len(value) % 4)


def encode(address: str, arguments: list[str]) -> bytes:
    tags, data = ",", b""
    for argument in arguments:
        try:
            if str(int(argument)) == argument:
                tags += "i"
                data += struct.pack(">i", int(argument))
                continue
        except ValueError:
            pass
        try:
            number = float(argument)
        except ValueError:
            tags += "s"
            data += pad(argument.encode())
        else:
            tags += "f"
            data += struct.pack(">f", number)
    return pad(address.encode()) + pad(tags.encode()) + data


def decode(packet: bytes) -> tuple[str, list[object]]:
    end = packet.index(0)
    address = packet[:end].decode()
    packet = packet[(end // 4 + 1) * 4 :]
    arguments: list[object] = []
    if packet[:1] != b",":
        return address, arguments
    end = packet.index(0)
    tags = packet[1:end].decode()
    packet = packet[(end // 4 + 1) * 4 :]
    for tag in tags:
        if tag == "i":
            arguments.append(struct.unpack(">i", packet[:4])[0])
            packet = packet[4:]
        elif tag == "f":
            arguments.append(round(struct.unpack(">f", packet[:4])[0], 6))
            packet = packet[4:]
        elif tag == "s":
            end = packet.index(0)
            arguments.append(packet[:end].decode())
            packet = packet[(end // 4 + 1) * 4 :]
    return address, arguments


def output(address: str, arguments: list[object]) -> None:
    print(
        "%.3f %s %s" % (time.time(), address, " ".join(str(value) for value in arguments)),
        flush=True,
    )


def send(address: str, arguments: list[str]) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.sendto(encode(address, arguments), ("127.0.0.1", SEND_PORT))
    return 0


def dump(duration: float | None) -> int:
    deadline = time.monotonic() + duration if duration is not None else None
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
        listener.bind(("127.0.0.1", RECV_PORT))
        while deadline is None or time.monotonic() < deadline:
            timeout = None if deadline is None else max(0.0, deadline - time.monotonic())
            readable, _, _ = select.select([listener], [], [], timeout)
            if not readable:
                break
            packet, _ = listener.recvfrom(4096)
            try:
                address, arguments = decode(packet)
            except (UnicodeDecodeError, ValueError, struct.error):
                print("%.3f undecodable %r" % (time.time(), packet), flush=True)
                continue
            output(address, arguments)
    return 0


def probe(timeout: float) -> int:
    """Prove that this benchmark device owns the two UDP endpoints.

    Ready is a one-shot report and can race the runner.  A nonce pong is an
    active, unambiguous readiness proof, so retransmit ping until it arrives.
    """
    deadline = time.monotonic() + timeout
    nonce = secrets.token_hex(8)
    next_ping = 0.0
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
        listener.bind(("127.0.0.1", RECV_PORT))
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            while time.monotonic() < deadline:
                now = time.monotonic()
                if now >= next_ping:
                    client.sendto(encode("/abl/bench/ping", [nonce]), ("127.0.0.1", SEND_PORT))
                    next_ping = now + 0.25
                readable, _, _ = select.select([listener], [], [], min(0.25, max(0.0, deadline - now)))
                if not readable:
                    continue
                packet, _ = listener.recvfrom(4096)
                try:
                    address, arguments = decode(packet)
                except (UnicodeDecodeError, ValueError, struct.error):
                    continue
                if address == "/abl/bench/pong" and arguments == [nonce]:
                    output(address, arguments)
                    return 0
    print(f"no benchmark-device pong on UDP {RECV_PORT} within {timeout:g}s", file=sys.stderr)
    return 1


def positive(value: str) -> float:
    try:
        result = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive number") from error
    if result <= 0:
        raise argparse.ArgumentTypeError("must be a positive number")
    return result


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    send_parser = commands.add_parser("send")
    send_parser.add_argument("address")
    send_parser.add_argument("arguments", nargs="*")
    dump_parser = commands.add_parser("dump")
    dump_parser.add_argument("--duration", type=positive)
    probe_parser = commands.add_parser("probe")
    probe_parser.add_argument("--timeout", type=positive, default=120.0)
    return root


def main() -> int:
    args = parser().parse_args()
    if args.command == "send":
        return send(args.address, args.arguments)
    if args.command == "dump":
        return dump(args.duration)
    return probe(args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
