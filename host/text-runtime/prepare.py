#!/usr/bin/env python3
"""Offline preparation from verified public artifacts. Never resets fixture disks."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time

from common import ROOT, PINS, CLI_SHA256, RAW_SHA256, MAX_IMAGE_BYTES, build_seed, digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', type=Path, default=Path(__file__).resolve().parent / 'images')
    parser.add_argument('--public-image-dir', type=Path, default=ROOT / 'host/images')
    parser.add_argument('--sdk-dir', type=Path, default=ROOT / 'sdk')
    parser.add_argument('--runner', type=Path, default=ROOT / 'host/.build/release/vm-text-runtime')
    args = parser.parse_args()
    output = args.output_dir.absolute()
    if output.exists():
        raise RuntimeError('output_directory_already_exists')
    for name, expected in PINS.items():
        if digest(args.public_image_dir / name) != expected:
            raise RuntimeError('public_artifact_pin_mismatch:' + name)
    sdk = args.sdk_dir / 'node_modules/@anthropic-ai/claude-agent-sdk'
    cli = args.sdk_dir / 'node_modules/@anthropic-ai/claude-agent-sdk-linux-arm64'
    if json.loads((sdk / 'package.json').read_text()).get('version') != '0.3.295':
        raise RuntimeError('sdk_version_pin_mismatch')
    if digest(cli / 'claude') != CLI_SHA256:
        raise RuntimeError('linux_cli_pin_mismatch')
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.text-base-', dir=output.parent))
    began = time.monotonic()
    try:
        for name in ('kernel', 'initrd'):
            shutil.copyfile(args.public_image_dir / name, staging / name)
        with tarfile.open(args.public_image_dir / 'disk.tar.gz', 'r:gz') as archive:
            members = [member for member in archive.getmembers() if member.isfile() and member.name.endswith('.img')]
            if len(members) != 1 or members[0].size > MAX_IMAGE_BYTES:
                raise RuntimeError('pristine_raw_archive_invalid')
            with archive.extractfile(members[0]) as source, (staging / 'guest.raw').open('xb') as target:
                shutil.copyfileobj(source, target)
        if digest(staging / 'guest.raw') != RAW_SHA256:
            raise RuntimeError('pristine_raw_pin_mismatch')
        with (staging / 'guest.raw').open('r+b') as disk:
            disk.truncate(MAX_IMAGE_BYTES)
        seed_files = staging / 'seed-files'
        seed_files.mkdir(mode=0o700)
        shutil.copyfile(args.public_image_dir / 'node-linux-arm64', seed_files / 'node')
        shutil.copyfile(args.public_image_dir / 'atomic.deb', seed_files / 'atomic.deb')
        with tarfile.open(seed_files / 'sdk.tgz', 'w:gz', compresslevel=1) as archive:
            for package in (sdk, cli):
                for file in sorted(package.rglob('*')):
                    if file.is_symlink() or not (file.is_dir() or file.is_file()):
                        raise RuntimeError('public_package_has_special_file')
                archive.add(package, arcname='node_modules/@anthropic-ai/' + package.name)
        # Build one cloud seed with immutable public payloads. No external paths
        # or inherited environment strings are serialized into guest config.
        from common import public_file
        commands = [['sh', '-eu', '-c',
            'mkdir -p /mnt/claude-text-seed /opt/claude-text/sdk /opt/claude-text/atomic; '
            'mount -o ro /dev/vdb /mnt/claude-text-seed; '
            'resize2fs /dev/vda; '
            'install -m 0755 /mnt/claude-text-seed/node /usr/bin/node; '
            'dpkg-deb -x /mnt/claude-text-seed/atomic.deb /opt/claude-text/atomic; '
            'install -m 0644 /opt/claude-text/atomic/usr/lib/aarch64-linux-gnu/libatomic.so.1.2.0 /usr/lib/aarch64-linux-gnu/libatomic.so.1; '
            'tar -xzf /mnt/claude-text-seed/sdk.tgz -C /opt/claude-text/sdk; '
            'printf "{\\\"type\\\":\\\"module\\\"}\\n" > /opt/claude-text/sdk/package.json; '
            'groupadd -g 59999 claude; useradd -u 59999 -g 59999 -d /home/claude -M -s /usr/sbin/nologin claude; '
            '/usr/bin/node --version; '
            'chmod -R go-w /opt/claude-text; '
            'umount /mnt/claude-text-seed; '
            'cloud-init clean --logs --seed; '
            'truncate -s 0 /etc/machine-id; rm -f /var/lib/dbus/machine-id /var/lib/systemd/random-seed; '
            'echo TEXT_BASE_READY > /dev/hvc0']]
        seed = build_seed(staging, [], commands, preparation=True)
        # ISO root payload files have to sit beside NoCloud metadata.
        for name in ('node', 'atomic.deb', 'sdk.tgz'):
            shutil.move(seed_files / name, staging / 'seed' / name)
        seed.unlink()
        subprocess.run(['/usr/bin/hdiutil', 'makehybrid', '-iso', '-joliet', '-default-volume-name', 'cidata',
                        '-o', str(seed), str(staging / 'seed')], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        seed.chmod(0o600)
        completed = subprocess.run([str(args.runner.absolute()), 'boot', str(staging), str(seed),
                                    str(staging / 'prepare.serial.log'), '300', 'prepare'],
                                   stdin=subprocess.DEVNULL, capture_output=True, timeout=330)
        serial = (staging / 'prepare.serial.log').read_bytes()
        if completed.returncode != 0 or b'TEXT_BASE_READY' not in serial:
            raise RuntimeError('golden_guest_preparation_failed')
        base = {'schema': 'claude-text-vm-base/v1', 'prepared': True,
                'ubuntu_release': 'noble/release-20260926', 'node_version': '26.7.0',
                'sdk_version': '0.3.295', 'linux_cli_sha256': CLI_SHA256,
                'disk_sha256': digest(staging / 'guest.raw'), 'disk_bytes': MAX_IMAGE_BYTES,
                'kernel_sha256': PINS['kernel'], 'initrd_sha256': PINS['initrd'],
                'preparation_seconds': round(time.monotonic() - began, 2),
                'no_user_data': True, 'network_devices': 0, 'directory_shares': 0}
        (staging / 'base.json').write_text(json.dumps(base, indent=2) + '\n')
        for name in ('seed', 'seed-files'):
            shutil.rmtree(staging / name)
        seed.unlink()
        (staging / 'guest.raw').chmod(0o400)
        (staging / 'kernel').chmod(0o400)
        (staging / 'initrd').chmod(0o400)
        staging.rename(output)
        print(json.dumps({'kind': 'vm_base_prepared', 'preparation_seconds': base['preparation_seconds'],
                          'disk_bytes': MAX_IMAGE_BYTES, 'sdk_version': base['sdk_version']}))
    finally:
        if staging.exists():
            shutil.rmtree(staging)


if __name__ == '__main__':
    main()
