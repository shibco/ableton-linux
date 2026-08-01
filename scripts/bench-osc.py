#!/usr/bin/env python3
"""bench-osc.py — talk to the abl-bench-osc device from the shell.

The device (bench/m4l/) lives in every benchmark set. It listens for
commands on UDP 19001 and reports on UDP 19002; addresses are listed in
bench/m4l/README.md.

Usage:
  scripts/bench-osc.py send <address> [args...]   one OSC message to the device
  scripts/bench-osc.py dump                       print device reports, one per line

Examples:
  scripts/bench-osc.py dump &
  scripts/bench-osc.py send /abl/bench/ping 1
  scripts/bench-osc.py send /abl/bench/play

Arguments that parse as integers are sent as OSC int32, as floats become
float32, anything else becomes a string. dump prints "unix-time address
args..." rows, awk-friendly. Environment: ABL_BENCH_OSC_SEND (default
19001), ABL_BENCH_OSC_RECV (default 19002).
"""
import os
import socket
import struct
import sys
import time

SEND_PORT = int(os.environ.get("ABL_BENCH_OSC_SEND", 19001))
RECV_PORT = int(os.environ.get("ABL_BENCH_OSC_RECV", 19002))


def pad(b):
    return b + b"\x00" * (4 - len(b) % 4)


def encode(addr, args):
    tags, data = ",", b""
    for a in args:
        try:
            if str(int(a)) == a:
                tags += "i"
                data += struct.pack(">i", int(a))
                continue
        except ValueError:
            pass
        try:
            tags += "f"
            data += struct.pack(">f", float(a))
            continue
        except ValueError:
            pass
        tags = tags[:-1] + "s"
        data += pad(a.encode())
    return pad(addr.encode()) + pad(tags.encode()) + data


def decode(b):
    n = b.index(0)
    addr = b[:n].decode()
    b = b[(n // 4 + 1) * 4:]
    args = []
    if b[:1] == b",":
        n = b.index(0)
        tags = b[1:n].decode()
        b = b[(n // 4 + 1) * 4:]
        for t in tags:
            if t == "i":
                args.append(struct.unpack(">i", b[:4])[0])
                b = b[4:]
            elif t == "f":
                args.append(round(struct.unpack(">f", b[:4])[0], 6))
                b = b[4:]
            elif t == "s":
                n = b.index(0)
                args.append(b[:n].decode())
                b = b[(n // 4 + 1) * 4:]
    return addr, args


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "send":
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.sendto(encode(sys.argv[2], sys.argv[3:]), ("127.0.0.1", SEND_PORT))
        return 0
    if len(sys.argv) == 2 and sys.argv[1] == "dump":
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", RECV_PORT))
        while True:
            data, _ = s.recvfrom(4096)
            try:
                addr, args = decode(data)
            except (ValueError, struct.error):
                print("%.3f undecodable %r" % (time.time(), data), flush=True)
                continue
            print("%.3f %s %s" % (time.time(), addr,
                                  " ".join(str(a) for a in args)), flush=True)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
