#!/usr/bin/env python3
"""App-owned offline installation recipe; no downloaded code runs on the host."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import threading
import time
import uuid

MAX_ARCHIVE = 160 * 1024**2
MAX_UNPACKED = 320 * 1024**2
MAX_DISK = 8 * 1024**3
MAX_FILES = 4096
VERSION = re.compile(r'^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$')
DIGEST = re.compile(r'^[a-f0-9]{64}$')


class BuildError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def fail(code='UPDATE_BUILD_ARCHIVE_INVALID'):
    raise BuildError(code)


def emit(value):
    print(json.dumps(value, separators=(',', ':')), flush=True)


def physical(path, directory=False):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts or any(ord(char) < 32 for char in str(path)):
        fail('UPDATE_BUILD_INVALID_REQUEST')
    current = Path(path.anchor)
    for index, component in enumerate(path.parts[1:]):
        current /= component
        metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode) or ((index < len(path.parts) - 2 or directory) and not stat.S_ISDIR(metadata.st_mode)):
            fail('UPDATE_BUILD_INVALID_REQUEST')
    return path


def regular(path, maximum):
    path = physical(path)
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum:
        fail()
    return metadata


def digest_file(path, check):
    value = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            check()
            value.update(chunk)
    check()
    return value.hexdigest()


def read_json(path):
    regular(path, 64 * 1024)
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (ValueError, UnicodeError):
        fail()


def octal(field):
    value = field.rstrip(b'\0 ').lstrip(b' ')
    if not value or re.fullmatch(b'[0-7]+', value) is None:
        fail()
    return int(value, 8)


def tar_name(header):
    def text(field):
        # USTAR names are NUL-terminated; hidden bytes after NUL are refused.
        parts = field.split(b'\0', 1)
        if len(parts) == 2 and any(parts[1]):
            fail()
        try:
            return parts[0].decode('ascii')
        except UnicodeError:
            fail()
    name, prefix = text(header[:100]), text(header[345:500])
    value = (prefix + '/' if prefix else '') + name
    value = value.rstrip('/') if header[156:157] == b'5' else value
    if len(value) > 512 or re.fullmatch(r'package(?:/[A-Za-z0-9_.+@-]+)*', value) is None or any(part in ('.', '..') or len(part) > 128 for part in value.split('/')):
        fail()
    return value


def extract_archive(archive_path, destination, expected_bytes, budget, check):
    """Read only bounded USTAR headers, before processing metadata or payloads.

    tarfile's PAX/GNU extension parser may allocate from an attacker-controlled
    length before yielding a member. Official npm paths need no extensions, so
    links, long-name/PAX headers, devices and sparse files are refused directly.
    """
    regular(archive_path, MAX_ARCHIVE)
    destination.mkdir(mode=0o700)
    seen, canonical_paths, files, total = set(), {}, [], 0
    descriptor = os.open(archive_path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as compressed, gzip.GzipFile(fileobj=compressed) as source:
        def read(size):
            check()
            value = source.read(size)
            budget['decoded'] += len(value)
            if budget['decoded'] > MAX_UNPACKED + 8 * 1024**2 or len(value) != size:
                fail()
            return value
        while True:
            header = read(512)
            if header == bytes(512):
                if read(512) != bytes(512):
                    fail()
                padding = 0
                while True:
                    check()
                    tail = source.read(65536)
                    if not tail:
                        break
                    padding += len(tail)
                    budget['decoded'] += len(tail)
                    if padding > 1024 * 1024 or budget['decoded'] > MAX_UNPACKED + 8 * 1024**2 or any(tail):
                        fail()
                break
            budget['members'] += 1
            if budget['members'] > MAX_FILES or header[257:265] not in (b'ustar\x0000', b'ustar  \x00') or octal(header[148:156]) != sum(header[:148]) + 8 * 32 + sum(header[156:]):
                fail()
            kind = header[156:157]
            if kind not in (b'0', b'\0', b'5'):
                fail()
            name = tar_name(header)
            folded = name.lower()
            if folded in seen:
                fail()
            seen.add(folded)
            components = name.split('/')
            for index in range(1, len(components) + 1):
                prefix = '/'.join(components[:index])
                previous = canonical_paths.setdefault(prefix.lower(), prefix)
                if previous != prefix:
                    fail()
            size = octal(header[124:136])
            if size > MAX_UNPACKED or (kind == b'5' and size != 0):
                fail()
            total += size
            budget['bytes'] += size
            if total > expected_bytes or budget['bytes'] > MAX_UNPACKED:
                fail()
            relative = name[len('package'):].lstrip('/')
            if not relative:
                if kind != b'5':
                    fail()
                continue
            target = destination / relative
            # An earlier regular file cannot become a parent; no symlinks or
            # outside directories have ever been materialized in this tree.
            for parent in reversed(target.parents):
                if parent == destination:
                    continue
                if destination in parent.parents:
                    if parent.exists():
                        if not parent.is_dir() or parent.is_symlink():
                            fail()
                    else:
                        parent.mkdir(mode=0o700)
            if kind == b'5':
                if target.exists():
                    if not target.is_dir():
                        fail()
                else:
                    target.mkdir(mode=0o700)
                continue
            if target.exists():
                fail()
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as output:
                remaining = size
                while remaining:
                    chunk = read(min(1024 * 1024, remaining))
                    output.write(chunk)
                    remaining -= len(chunk)
            if size % 512:
                if any(read(512 - size % 512)):
                    fail()
            files.append(relative)
    if total != expected_bytes or 'package.json' not in files:
        fail()
    return files


def validate_packages(sdk, native, configuration, check):
    sdk_info, native_info = read_json(sdk / 'package.json'), read_json(native / 'package.json')
    if not isinstance(sdk_info, dict) or not isinstance(native_info, dict) or not isinstance(sdk_info.get('engines'), dict) or not isinstance(sdk_info.get('optionalDependencies'), dict):
        fail()
    if sdk_info.get('name') != '@anthropic-ai/claude-agent-sdk' or sdk_info.get('version') != configuration['sdkVersion'] or sdk_info.get('claudeCodeVersion') != configuration['cliVersion'] or sdk_info['engines'].get('node') != '>=' + configuration['nodeMinimum'] or sdk_info['optionalDependencies'].get('@anthropic-ai/claude-agent-sdk-linux-arm64') != configuration['sdkVersion']:
        fail()
    if native_info.get('name') != '@anthropic-ai/claude-agent-sdk-linux-arm64' or native_info.get('version') != configuration['sdkVersion'] or native_info.get('os') != ['linux'] or native_info.get('cpu') != ['arm64'] or native_info.get('libc') != ['glibc']:
        fail()
    regular(sdk / 'sdk.mjs', MAX_UNPACKED)
    cli = native / 'claude'
    if regular(cli, MAX_UNPACKED).st_size != configuration['cliBytes'] or digest_file(cli, check) != configuration['cliSHA256']:
        fail()


def public_tar(target, sdk, native, check):
    # Create a new archive from validated regular files, with App-owned paths,
    # modes and ownership. Original tar metadata never reaches guest tar.
    with tarfile.open(target, 'w', format=tarfile.USTAR_FORMAT) as output:
        for source in (sdk, native):
            prefix = 'node_modules/@anthropic-ai/' + source.name
            for filename in sorted(source.rglob('*')):
                check()
                if not filename.is_file():
                    continue
                regular(filename, MAX_UNPACKED)
                member = tarfile.TarInfo(prefix + '/' + str(filename.relative_to(source)))
                member.size = filename.stat().st_size
                member.mode = 0o755 if filename.name == 'claude' and source == native else 0o644
                member.mtime = 0
                with filename.open('rb') as payload:
                    output.addfile(member, payload)
    target.chmod(0o600)


def make_seed(directory, configuration):
    seed = directory / 'seed'
    seed.mkdir(mode=0o700)
    verify = """import {readFile} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {createHash} from 'node:crypto';
const expected=EXPECTED;
const root='/opt/claude-text/sdk/node_modules/@anthropic-ai/';
const sdk=JSON.parse(await readFile(root+'claude-agent-sdk/package.json','utf8'));
const native=JSON.parse(await readFile(root+'claude-agent-sdk-linux-arm64/package.json','utf8'));
if(sdk.name!=='@anthropic-ai/claude-agent-sdk'||sdk.version!==expected.sdkVersion||sdk.claudeCodeVersion!==expected.cliVersion||native.name!=='@anthropic-ai/claude-agent-sdk-linux-arm64'||native.version!==expected.sdkVersion||process.version!=='v'+expected.nodeVersion)throw Error('installed_metadata');
const hash=createHash('sha256');for await(const chunk of createReadStream(root+'claude-agent-sdk-linux-arm64/claude'))hash.update(chunk);
if(hash.digest('hex')!==expected.cliSHA256)throw Error('installed_binary');
console.log('TEXT_LOCAL_BUILD_NODE='+process.version);
""".replace('EXPECTED', json.dumps({key: configuration[key] for key in ('sdkVersion', 'cliVersion', 'nodeVersion', 'cliSHA256')}, separators=(',', ':')))
    (seed / 'verify.mjs').write_text(verify, encoding='utf-8')
    command = (
        'mkdir -p /mnt/claude-text-seed; '
        'mount -o ro /dev/vdb /mnt/claude-text-seed; '
        'rm -rf /opt/claude-text/sdk/node_modules; mkdir -p /opt/claude-text/sdk; '
        'tar -xf /mnt/claude-text-seed/sdk.tar -C /opt/claude-text/sdk; '
        'printf "{\\\"type\\\":\\\"module\\\"}\\n" > /opt/claude-text/sdk/package.json; '
        '/usr/bin/node /mnt/claude-text-seed/verify.mjs > /dev/hvc0; '
        'chmod -R go-w /opt/claude-text; '
        'umount /mnt/claude-text-seed; '
        'rm -f /etc/claude-text/probe-enabled; '
        'if [ -d /home/claude ]; then find /home/claude -mindepth 1 -maxdepth 1 -exec rm -rf {} +; fi; '
        'rm -rf /root/.claude /root/.claude.json /root/.cache; '
        'cloud-init clean --logs --seed; '
        'rm -rf /var/lib/cloud/* /var/log/journal/* /var/lib/systemd/random-seed; '
        'find /var/log -type f -exec truncate -s 0 {} +; '
        'find /tmp /var/tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} +; '
        'truncate -s 0 /etc/machine-id; rm -f /var/lib/dbus/machine-id; '
        'echo TEXT_LOCAL_BUILD_READY > /dev/hvc0'
    )
    config = {'hostname': 'claude-text-guest', 'manage_etc_hosts': False, 'ssh_deletekeys': True,
              'ssh_genkeytypes': [], 'disable_root': True, 'users': [], 'write_files': [],
              'runcmd': [['sh', '-eu', '-c', command]],
              'power_state': {'mode': 'poweroff', 'timeout': 5, 'condition': True}}
    (seed / 'user-data').write_text('#cloud-config\n' + json.dumps(config) + '\n', encoding='utf-8')
    (seed / 'meta-data').write_text('instance-id: claude-text-local-build-' + str(uuid.uuid4()) + '\nlocal-hostname: claude-text-guest\n', encoding='utf-8')
    for filename in seed.iterdir():
        filename.chmod(0o600)
    return seed


def validate_configuration(value):
    keys = {'schema', 'imageDirectory', 'runner', 'artifactDirectory', 'scratchRoot', 'sdkVersion', 'cliVersion', 'cliSHA256', 'cliBytes', 'nodeVersion', 'nodeMinimum', 'sdkUnpackedBytes', 'nativeUnpackedBytes', 'sdkArchiveSHA256', 'nativeArchiveSHA256'}
    if not isinstance(value, dict) or set(value) != keys or value['schema'] != 'official-runtime-prepare/v1' or any(not isinstance(value[key], str) or not VERSION.fullmatch(value[key]) for key in ('sdkVersion', 'cliVersion', 'nodeVersion', 'nodeMinimum')) or any(not isinstance(value[key], str) or not DIGEST.fullmatch(value[key]) for key in ('cliSHA256', 'sdkArchiveSHA256', 'nativeArchiveSHA256')) or any(not isinstance(value[key], int) or isinstance(value[key], bool) or not 0 < value[key] <= MAX_UNPACKED for key in ('cliBytes', 'sdkUnpackedBytes', 'nativeUnpackedBytes')) or value['sdkUnpackedBytes'] + value['nativeUnpackedBytes'] > MAX_UNPACKED:
        fail('UPDATE_BUILD_INVALID_REQUEST')
    if any(not isinstance(value[key], str) or len(value[key]) > 4096 for key in ('imageDirectory', 'runner', 'artifactDirectory', 'scratchRoot')):
        fail('UPDATE_BUILD_INVALID_REQUEST')
    return value


def main():
    parent_pid = os.getppid()
    state = {'cancelled': False, 'orphan': False, 'stop_at': None}
    process = None
    scratch = None
    work = None
    watchdog_done = threading.Event()
    started = time.monotonic()

    def stop(number=signal.SIGTERM, _frame=None):
        state['cancelled'] = True
        state['stop_at'] = state['stop_at'] or time.monotonic()
        if process is not None and process.poll() is None:
            process.send_signal(number)

    def check():
        if state['cancelled']:
            fail('UPDATE_CANCELLED')
        if time.monotonic() - started > 330:
            fail('UPDATE_BUILD_PREPARE_FAILED')

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def monitor():
        while not watchdog_done.wait(0.25):
            if os.getppid() != parent_pid:
                state['orphan'] = True
                stop()
                return
    threading.Thread(target=monitor, daemon=True).start()
    try:
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536:
            fail('UPDATE_BUILD_INVALID_REQUEST')
        configuration = validate_configuration(json.loads(raw))
        scratch = physical(configuration['scratchRoot'], directory=True)
        scratch_meta = scratch.lstat()
        if not scratch.name.startswith('.runtime-build-') or scratch_meta.st_uid != os.getuid() or stat.S_IMODE(scratch_meta.st_mode) != 0o700 or read_json(scratch / '.owner.json') != {'schema': 'runtime-build-scratch/v1', 'parentPID': parent_pid}:
            fail('UPDATE_BUILD_INVALID_REQUEST')
        images = physical(configuration['imageDirectory'], directory=True)
        if scratch not in images.parents:
            fail('UPDATE_BUILD_INVALID_REQUEST')
        runner = physical(configuration['runner'])
        if scratch not in runner.parents or not regular(runner, 128 * 1024**2).st_mode & 0o111:
            fail('UPDATE_BUILD_INVALID_REQUEST')
        artifacts = physical(configuration['artifactDirectory'], directory=True)
        disk = regular(images / 'guest.raw', MAX_DISK)
        if disk.st_size != MAX_DISK or not disk.st_mode & 0o200:
            fail('UPDATE_BUILD_TEMPLATE_INVALID')
        work = scratch / 'prepare'
        work.mkdir(mode=0o700)
        packages = work / 'packages'
        packages.mkdir(mode=0o700)
        sdk = packages / 'claude-agent-sdk'
        native = packages / 'claude-agent-sdk-linux-arm64'
        budget = {'bytes': 0, 'decoded': 0, 'members': 0}
        emit({'type': 'progress', 'phase': 'extract', 'fraction': 0.2})
        for name, expected_hash, directory, size in (
            ('root-sdk.tgz', configuration['sdkArchiveSHA256'], sdk, configuration['sdkUnpackedBytes']),
            ('native-cli.tgz', configuration['nativeArchiveSHA256'], native, configuration['nativeUnpackedBytes'])):
            archive = artifacts / name
            if digest_file(archive, check) != expected_hash:
                fail()
            files = extract_archive(archive, directory, size, budget, check)
            if directory == native and set(files) != {'package.json', 'claude', 'README.md', 'LICENSE.md'}:
                fail()
        validate_packages(sdk, native, configuration, check)
        seed = make_seed(work, configuration)
        public_tar(seed / 'sdk.tar', sdk, native, check)
        check()
        iso = work / 'seed.iso'
        process = subprocess.Popen(['/usr/bin/hdiutil', 'makehybrid', '-iso', '-joliet', '-default-volume-name', 'cidata', '-o', str(iso), str(seed)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
        while process.poll() is None:
            if state['cancelled']:
                stop()
                break
            check()
            time.sleep(0.1)
        if process.wait(timeout=10) != 0:
            fail('UPDATE_BUILD_PREPARE_FAILED')
        iso.chmod(0o400)
        check()
        emit({'type': 'progress', 'phase': 'prepare', 'fraction': 0.4})
        serial = work / 'prepare.serial.log'
        process = subprocess.Popen([str(runner), 'boot', str(images), str(iso), str(serial), '300', 'prepare'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True)
        diagnostics = {'bytes': 0, 'config': 0, 'stopped': False, 'invalid': False}

        def read_diagnostics():
            while True:
                line = process.stderr.readline(8193)
                if not line:
                    return
                diagnostics['bytes'] += len(line)
                if len(line) > 8192 or diagnostics['bytes'] > 65536:
                    diagnostics['invalid'] = True
                    stop()
                    return
                try:
                    value = json.loads(line)
                    if value.get('kind') == 'vm_config':
                        diagnostics['config'] += 1
                        if any(value.get(key) != 0 for key in ('network_devices', 'directory_shares', 'host_directory_shares', 'socket_devices', 'vsock_port')):
                            diagnostics['invalid'] = True
                            stop()
                    elif value.get('kind') == 'vm_stopped':
                        diagnostics['stopped'] = value.get('exit_code') == 0 and value.get('reason') == 'guest_poweroff'
                except (ValueError, UnicodeError):
                    diagnostics['invalid'] = True
                    stop()
        diagnostics_thread = threading.Thread(target=read_diagnostics, daemon=True)
        diagnostics_thread.start()
        # Prepare emits no stdout. Drain it with a hard bound to avoid a pipe
        # stall if a changed helper violates that invariant.
        stdout_state = {'bytes': 0}
        def drain_stdout():
            for chunk in iter(lambda: process.stdout.read(4096), b''):
                stdout_state['bytes'] += len(chunk)
                if stdout_state['bytes'] > 0:
                    diagnostics['invalid'] = True
                    stop()
                    return
        stdout_thread = threading.Thread(target=drain_stdout, daemon=True)
        stdout_thread.start()
        while process.poll() is None:
            if state['cancelled']:
                if state['stop_at'] and time.monotonic() - state['stop_at'] > 10:
                    process.kill()
                else:
                    process.terminate()
            elif time.monotonic() - started > 330:
                stop()
            time.sleep(0.1)
        code = process.wait(timeout=5)
        diagnostics_thread.join(timeout=2)
        stdout_thread.join(timeout=2)
        check()
        if regular(serial, 2 * 1024**2).st_size == 0:
            fail('UPDATE_BUILD_PREPARE_FAILED')
        log = serial.read_bytes()
        node_marker = ('TEXT_LOCAL_BUILD_NODE=v' + configuration['nodeVersion']).encode('ascii')
        if code != 0 or diagnostics['invalid'] or diagnostics['config'] != 1 or not diagnostics['stopped'] or b'TEXT_LOCAL_BUILD_READY' not in log or node_marker not in log:
            fail('UPDATE_BUILD_PREPARE_FAILED')
        emit({'type': 'prepared', 'nodeVersion': configuration['nodeVersion'], 'preparationSeconds': round(time.monotonic() - started, 2),
              'isolation': {'networkDevices': 0, 'directoryShares': 0, 'socketDevices': 0, 'noUserData': True}})
        return 0
    except BuildError as error:
        emit({'type': 'error', 'code': error.code})
        return 2
    except (ValueError, OSError, subprocess.SubprocessError, EOFError, tarfile.TarError):
        emit({'type': 'error', 'code': 'UPDATE_BUILD_FAILED'})
        return 2
    finally:
        watchdog_done.set()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if work is not None and work.exists():
            shutil.rmtree(work)
        if state['orphan'] and scratch is not None and scratch.exists():
            shutil.rmtree(scratch)


if __name__ == '__main__':
    sys.exit(main())
