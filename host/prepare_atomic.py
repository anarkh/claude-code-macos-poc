#!/usr/bin/env python3
"""Prepare a pinned Ubuntu libatomic runtime for the offline Node 26 fixture."""
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parent / 'images'
URL = 'https://ports.ubuntu.com/ubuntu-ports/pool/main/g/gcc-14/libatomic1_14.2.0-4ubuntu2~24.04.1_arm64.deb'
SHA256 = 'fdeab74e7ad8572cf69c7024e8040c7ac851f6e667d35f0d429e7a0352840f73'


def main():
    ROOT.mkdir(exist_ok=True)
    path = ROOT / 'atomic.deb'
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != SHA256:
        with urllib.request.urlopen(URL, timeout=30) as response:
            content = response.read(1024 * 1024 + 1)
        if len(content) != 11604 or hashlib.sha256(content).hexdigest() != SHA256:
            raise RuntimeError('fixed official libatomic ARM64 package size/SHA256 mismatch')
        path.write_bytes(content)
    evidence = {'package': 'libatomic1', 'version': '14.2.0-4ubuntu2~24.04.1', 'architecture': 'arm64',
                'url': URL, 'sha256': SHA256, 'size': path.stat().st_size,
                'metadata_source': 'https://ports.ubuntu.com/ubuntu-ports/dists/noble-updates/main/binary-arm64/Packages.xz',
                'verification': 'fixed SHA256 from official HTTPS Packages; GPG signature not verified',
                'use': 'extract into private guest runtime, install only .so.1; no dpkg registration or maintainer scripts'}
    (ROOT / 'atomic-provenance.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps({'kind': 'atomic_prepared', **evidence}))


if __name__ == '__main__':
    main()
