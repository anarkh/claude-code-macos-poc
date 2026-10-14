#!/usr/bin/python3
"""Preparation-only export of two fixed boot artifacts, never profile files."""
import hashlib
import json
from pathlib import Path
import socket
import sys

root = Path(sys.argv[1])
version = sys.argv[2]
for name, source in (("kernel", root / "boot" / ("vmlinuz-" + version)), ("initrd", root / "boot" / ("initrd.img-" + version))):
    digest = hashlib.sha256()
    with source.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(data)
    header = {"schema": "browser-public-artifact/v1", "name": name, "bytes": source.stat().st_size, "sha256": digest.hexdigest()}
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as channel:
        channel.settimeout(120)
        channel.connect((2, 40126))
        channel.sendall(json.dumps(header).encode() + b"\n")
        with source.open("rb") as stream:
            for data in iter(lambda: stream.read(1024 * 1024), b""):
                channel.sendall(data)
        if channel.recv(3) != b"OK\n":
            raise RuntimeError("public_artifact_export_not_acknowledged")
