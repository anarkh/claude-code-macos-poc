"""Fixed public artifacts and cloud-init seed building; never reads user HOME."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
MAX_IMAGE_BYTES = 8 * 1024**3
PINS = {
    'disk.tar.gz': '1800eb56b6b839a08c020551e16fbd8c95b2772452ecce3737a9ad25fe594126',
    'kernel': 'e989ab36e015f982493402632ec2b01031e70fad892e182797a82b442a301914',
    'initrd': 'f77f65eccd619be537e44a7bb2664048e27f20fc8c8e7d4eeb5cf63d0c8cd213',
    'node-linux-arm64': '9507fea66ea788dfb2bbef1380ef6ef8940697ef1de15bee62b279e6cfef035c',
    'atomic.deb': 'fdeab74e7ad8572cf69c7024e8040c7ac851f6e667d35f0d429e7a0352840f73',
}
CLI_SHA256 = 'cfb9dc1332fb6f92a683f835823e91b3179a803398ca7852cd2381a3cb1dea3b'
RAW_SHA256 = '90fc6dbda4a628c1293f5f00bad88d5cd578f818279f62b4215d4452a6f91c94'


def digest(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise RuntimeError('regular_public_artifact_required')
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def public_file(path, guest_path, permissions='0644'):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        raise RuntimeError('guest_code_artifact_invalid')
    return {'path': guest_path, 'owner': 'root:root', 'permissions': permissions,
            'encoding': 'b64', 'content': base64.b64encode(path.read_bytes()).decode('ascii')}


def build_seed(directory, files, commands, *, preparation=False):
    directory = Path(directory)
    seed = directory / 'seed'
    seed.mkdir(mode=0o700)
    config = {
        'hostname': 'claude-text-guest', 'manage_etc_hosts': False,
        'ssh_deletekeys': True, 'ssh_genkeytypes': [], 'disable_root': True,
        'users': [], 'write_files': files,
        'runcmd': commands,
        'power_state': {'mode': 'poweroff', 'timeout': 5, 'condition': True},
    }
    (seed / 'user-data').write_text('#cloud-config\n' + json.dumps(config) + '\n')
    (seed / 'user-data').chmod(0o600)
    (seed / 'meta-data').write_text('instance-id: claude-text-' + str(uuid.uuid4()) + '\nlocal-hostname: claude-text-guest\n')
    iso = directory / 'seed.iso'
    subprocess.run(['/usr/bin/hdiutil', 'makehybrid', '-iso', '-joliet', '-default-volume-name',
                    'cidata', '-o', str(iso), str(seed)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    iso.chmod(0o600)
    return iso


def validate_base(directory):
    directory = Path(directory)
    metadata = json.loads((directory / 'base.json').read_text())
    if metadata.get('schema') != 'claude-text-vm-base/v1' or metadata.get('prepared') is not True:
        raise RuntimeError('vm_base_unprepared')
    for name in ('kernel', 'initrd'):
        if digest(directory / name) != PINS[name]:
            raise RuntimeError('vm_boot_artifact_changed')
    disk = directory / 'guest.raw'
    if disk.is_symlink() or not disk.is_file() or disk.stat().st_size != MAX_IMAGE_BYTES:
        raise RuntimeError('vm_base_disk_invalid')
    if disk.stat().st_mode & 0o222:
        raise RuntimeError('vm_base_disk_must_be_readonly')
    if digest(disk) != metadata.get('disk_sha256'):
        raise RuntimeError('vm_base_disk_changed')
    # No SDK imports or native host execution are involved in validating this
    # public golden disk against its preparation/packaging receipt.
    return metadata
