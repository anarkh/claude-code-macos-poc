#!/usr/bin/env python3
"""Validate and package the separate browser image; never reads user profiles."""
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def package(source, destination):
    if destination.exists():
        raise RuntimeError('browser_package_destination_exists')
    for name in ('browser.json', 'kernel', 'initrd', 'guest.raw'):
        path = source / name
        if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o222:
            raise RuntimeError('browser_readonly_artifact_required:' + name)
    if (source / 'browser.json').stat().st_size > 32768:
        raise RuntimeError('browser_manifest_too_large')
    manifest = json.loads((source / 'browser.json').read_text())
    if (manifest.get('schema') != 'browser-vm-base/v1'
            or re.fullmatch(r'[0-9][0-9.]{0,63}', manifest.get('firefox_version', '')) is None
            or type(manifest.get('disk_bytes')) is not int
            or manifest['disk_bytes'] != (source / 'guest.raw').stat().st_size
            or set(manifest.get('sha256', {})) != {'kernel', 'initrd', 'guest.raw'}):
        raise RuntimeError('browser_manifest_invalid')
    for name, expected in manifest['sha256'].items():
        if not isinstance(expected, str) or re.fullmatch('[a-f0-9]{64}', expected) is None or digest(source / name) != expected:
            raise RuntimeError('browser_artifact_integrity_failed:' + name)
    destination.mkdir(parents=True)
    for name in ('kernel', 'initrd', 'browser.json'):
        shutil.copy2(source / name, destination / name)
    subprocess.run(['/bin/cp', '-c', str(source / 'guest.raw'), str(destination / 'guest.raw')], check=True)
    for path in destination.iterdir():
        path.chmod(0o444)
    provenance = source.parent / 'source-provenance.json'
    if provenance.is_file() and not provenance.is_symlink():
        shutil.copy2(provenance, destination.parent / 'source-provenance.json')
    print(json.dumps({'browser_packaged': True, 'firefox_version': manifest['firefox_version']}))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: package_browser_runtime.py source-images destination-images')
    package(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
