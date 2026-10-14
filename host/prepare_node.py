#!/usr/bin/env python3
"""Prepare one fixed official Linux ARM64 Node binary; no install scripts."""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent / 'images'
BASE = 'https://nodejs.org/dist/v26.7.0/'
NAME = 'node-v26.7.0-linux-arm64.tar.xz'
EXPECTED = 'afc7a004018485092ac8985b817b0d5684472bd9472e0b57d2ab88737e50090d'


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    ROOT.mkdir(exist_ok=True)
    with urllib.request.urlopen(BASE + 'SHASUMS256.txt', timeout=30) as response:
        sums = {line.split()[1]: line.split()[0] for line in response.read().decode().splitlines() if len(line.split()) == 2}
    if sums.get(NAME) != EXPECTED:
        raise RuntimeError('fixed Node checksum differs from official HTTPS manifest')
    archive = ROOT / NAME
    if not archive.exists() or sha(archive) != EXPECTED:
        partial = ROOT / (NAME + '.partial')
        with urllib.request.urlopen(BASE + NAME, timeout=30) as source, partial.open('wb') as out:
            size = 0
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                size += len(chunk)
                if size > 150 * 1024**2:
                    raise RuntimeError('Node download exceeds fixture size bound')
                out.write(chunk)
        if sha(partial) != EXPECTED:
            raise RuntimeError('Node archive SHA256 mismatch')
        partial.replace(archive)
    node = ROOT / 'node-linux-arm64'
    with tarfile.open(archive, 'r:xz') as tar:
        member = tar.getmember('node-v26.7.0-linux-arm64/bin/node')
        if not member.isfile() or member.size > 200 * 1024**2:
            raise RuntimeError('Node member is not a bounded regular file')
        source = tar.extractfile(member)
        if source is None:
            raise RuntimeError('Node member missing')
        with node.open('wb') as out:
            shutil.copyfileobj(source, out)
    evidence = {'archive_url': BASE + NAME, 'archive_sha256': EXPECTED,
                'node_sha256': sha(node), 'node_bytes': node.stat().st_size,
                'verification': 'fixed hash and official HTTPS SHASUMS; GPG signature not verified'}
    (ROOT / 'node-provenance.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps({'kind': 'node_prepared', **evidence}))


if __name__ == '__main__':
    main()
