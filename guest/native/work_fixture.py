"""Fixed work-domain fixtures; no control-channel I/O or arbitrary targets."""
from __future__ import annotations

import errno
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import time


INSTALL = Path('/opt/claude-code-poc/native/work_fixture.py')
RUN = Path('/var/lib/claude-code-native-poc/current')
TARGETS = RUN / 'targets.json'
RESULTS = RUN / 'work/fixture-results.jsonl'
DAEMON_WRITES = RUN / 'work/daemon-writes.jsonl'
WORK_UID = 29998
WORK_LABEL = 'claude-native-work (enforce)'
MODES = ('identity', 'inheritance', 'inheritance-grandchild', 'daemon', 'boundaries')
CAP_FIELDS = ('CapInh', 'CapPrm', 'CapEff', 'CapBnd', 'CapAmb')


def own_identity():
    """Read only this process's proc metadata; never accept a target PID."""
    raw_stat = Path('/proc/self/stat').read_text()
    pid_text, fields_text = raw_stat.rsplit(')', 1)
    fields = fields_text.split()
    if len(fields) < 20:
        raise ValueError('short /proc/self/stat')
    pid = int(pid_text.split('(', 1)[0].strip())
    if pid != os.getpid():
        raise ValueError('/proc/self/stat PID mismatch')
    status = dict(line.split(':', 1)
                  for line in Path('/proc/self/status').read_text().splitlines()
                  if ':' in line)
    caps = {name: int(status[name].strip(), 16) for name in CAP_FIELDS}
    label = Path('/proc/self/attr/current').read_text().strip()
    cgroup = Path('/proc/self/cgroup').read_text().strip()
    identity = {
        'pid': pid, 'ppid': os.getppid(), 'starttime': int(fields[19]),
        'state': fields[0], 'uid': os.getuid(), 'euid': os.geteuid(),
        'gid': os.getgid(), 'egid': os.getegid(), 'label': label,
        'caps': caps, 'cgroup': cgroup,
        'environment_names': sorted(os.environ),
        'ANTHROPIC_API_KEY_present': 'ANTHROPIC_API_KEY' in os.environ,
        'ANTHROPIC_API_KEY_sha256': hashlib.sha256(os.environ['ANTHROPIC_API_KEY'].encode()).hexdigest() if 'ANTHROPIC_API_KEY' in os.environ else None,
    }
    if identity['uid'] != WORK_UID or identity['euid'] != WORK_UID:
        raise RuntimeError('fixture requires real/effective UID 29998')
    if label != WORK_LABEL:
        raise RuntimeError('fixture requires claude-native-work (enforce)')
    return identity


def append_record(path, value):
    """Only open one of the two fixed evidence files; never write inherited FDs."""
    if path not in (RESULTS, DAEMON_WRITES):
        raise ValueError('unexpected fixture output path')
    payload = (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT |
                 os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != WORK_UID or info.st_nlink != 1:
            raise ValueError('fixture output must be singly linked, work-owned regular file')
        offset = 0
        while offset < len(payload):
            count = os.write(fd, payload[offset:])
            if count <= 0:
                raise OSError(errno.EIO, 'fixture evidence write made no progress')
            offset += count
    finally:
        os.close(fd)


def targets():
    """Read the root-owned fixed manifest, without opening any target FD."""
    fd = os.open(TARGETS, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r', encoding='utf-8') as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                info.st_mode & 0o022 or info.st_nlink != 1):
            raise ValueError('targets.json must be singly linked, root-owned and non-writable')
        manifest = json.load(source)
    known = manifest.get('control_fd_identities')
    if not isinstance(known, list) or not known:
        raise ValueError('missing nonempty control_fd_identities')
    owners = set()
    for item in known:
        if not isinstance(item, dict) or item.get('owner') not in ('node', 'cli'):
            raise ValueError('control FD owner must be node or cli')
        owners.add(item['owner'])
        for field in ('fd', 'device', 'inode', 'type'):
            if type(item.get(field)) is not int or item[field] < 0:
                raise ValueError('invalid control FD identity field: ' + field)
        if item['type'] not in (stat.S_IFIFO, stat.S_IFSOCK, stat.S_IFREG,
                                stat.S_IFCHR, stat.S_IFBLK, stat.S_IFDIR):
            raise ValueError('invalid control FD file type')
    if owners != {'node', 'cli'}:
        raise ValueError('manifest must identify both node and cli control FDs')
    return manifest


def inherited_fds(manifest):
    """Enumerate self FDs using fstat/readlink only; never read, write or reopen."""
    numbers = {0, 1, 2}
    numbers.update(int(name) for name in os.listdir('/proc/self/fd') if name.isdigit())
    results = []
    known = manifest['control_fd_identities']
    for number in sorted(numbers):
        item = {'fd': number, 'is_stdio': number in (0, 1, 2)}
        try:
            info = os.fstat(number)
        except OSError as error:
            # listdir's already-closed enumeration FD can appear in its own listing.
            item['fstat_errno'] = error.errno
            item['closed'] = error.errno == errno.EBADF
        else:
            item.update(device=info.st_dev, inode=info.st_ino,
                        type=stat.S_IFMT(info.st_mode))
            item['control_matches'] = [
                {'owner': target['owner'], 'fd': target['fd']}
                for target in known
                if (info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode)) ==
                   (target['device'], target['inode'], target['type'])
            ]
            item['matches_control_identity'] = bool(item['control_matches'])
            try:
                item['path'] = os.readlink('/proc/self/fd/' + str(number))
            except OSError as error:
                item['readlink_errno'] = error.errno
        results.append(item)
    return results


def inheritance(grandchild=False):
    worker = own_identity()
    manifest = targets()
    fds = inherited_fds(manifest)
    report = {
        'kind': 'inheritance_fixture',
        'generation': 'grandchild' if grandchild else 'child',
        'worker': worker, 'fds': fds,
        'leaked_control_fd_identities': [item for item in fds
                                        if item.get('matches_control_identity')],
        'method': 'passive-self-fstat-and-readlink',
    }
    if 'run_id' in manifest:
        report['run_id'] = manifest['run_id']
    append_record(RESULTS, report)
    if not grandchild:
        # Keep the child's actual stdio and inheritable extra FDs intact. Python's
        # close-on-exec flags still apply; no stdio replacement or capture pipes.
        child = subprocess.run(
            ['/usr/bin/python3', '-I', '-S', str(INSTALL), 'inheritance-grandchild'],
            close_fds=False, timeout=10, check=False,
        )
        append_record(RESULTS, {
            'kind': 'inheritance_grandchild_exit', 'parent_pid': worker['pid'],
            'parent_starttime': worker['starttime'], 'returncode': child.returncode,
        })
        if child.returncode != 0:
            raise RuntimeError('inheritance-grandchild fixture failed')


def boundary_error(name, destination, stage, error, *, missing_unsupported=False):
    if error.errno in (errno.EACCES, errno.EPERM):
        outcome = 'denied'
    elif missing_unsupported and error.errno == errno.ENOENT:
        outcome = 'unsupported'
    else:
        outcome = 'inconclusive'
    return {
        'name': name, 'destination': destination, 'stage': stage,
        'outcome': outcome, 'errno': error.errno,
        'errno_name': errno.errorcode.get(error.errno),
        'error_type': type(error).__name__,
    }


def boundaries():
    """Test only fixed fake-file/local-socket boundaries and self cgroup membership."""
    worker = own_identity()
    probes = []
    protected_file = RUN / 'controller/protected-fake.json'
    for name, flags in (('protected_file_read', os.O_RDONLY),
                        ('protected_file_write_open', os.O_WRONLY)):
        destination = str(protected_file)
        try:
            fd = os.open(protected_file, flags | os.O_CLOEXEC | os.O_NOFOLLOW)
        except OSError as error:
            probes.append(boundary_error(name, destination, 'open', error))
            continue
        try:
            result = {'name': name, 'destination': destination,
                      'stage': 'open', 'outcome': 'failed', 'opened': True}
            if flags == os.O_RDONLY:
                try:
                    data = os.read(fd, 4096)
                except OSError as error:
                    result = boundary_error(name, destination, 'read', error)
                    result['opened'] = True
                else:
                    result.update(stage='read', read_count=len(data))
            else:
                result['write_attempted'] = False
            probes.append(result)
        finally:
            os.close(fd)

    for name, family, address, destination, missing_unsupported in (
        ('loopback_tcp_connect', socket.AF_INET, ('127.0.0.1', 41417),
         '127.0.0.1:41417', False),
        ('dbus_unix_connect', socket.AF_UNIX, '/run/dbus/system_bus_socket',
         '/run/dbus/system_bus_socket', True),
    ):
        stage = 'socket'
        try:
            with socket.socket(family, socket.SOCK_STREAM) as client:
                client.settimeout(1.0)
                stage = 'connect'
                client.connect(address)
        except OSError as error:
            probes.append(boundary_error(name, destination, stage, error,
                                          missing_unsupported=missing_unsupported))
        else:
            probes.append({'name': name, 'destination': destination,
                           'stage': 'connect', 'outcome': 'failed',
                           'connected': True, 'application_bytes_sent': 0})

    for destination in (
        '/sys/fs/cgroup/cgroup.procs',
        '/sys/fs/cgroup/claude-code-native-poc/cgroup.procs',
        '/sys/fs/cgroup/claude-code-native-poc/current/cgroup.procs',
    ):
        name = 'self_cgroup_membership_write'
        try:
            fd = os.open(destination, os.O_WRONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        except OSError as error:
            probes.append(boundary_error(name, destination, 'open', error))
            continue
        try:
            payload = str(os.getpid()).encode('ascii')
            try:
                count = os.write(fd, payload)
            except OSError as error:
                result = boundary_error(name, destination, 'write', error)
                result['opened'] = True
            else:
                result = {'name': name, 'destination': destination,
                          'stage': 'write', 'outcome': 'failed', 'opened': True,
                          'written_pid': os.getpid(), 'write_count': count}
            probes.append(result)
        finally:
            os.close(fd)

    outcomes = {probe['outcome'] for probe in probes}
    status = ('failed' if 'failed' in outcomes else
              'inconclusive' if 'inconclusive' in outcomes else
              'unsupported' if 'unsupported' in outcomes else 'passed')
    append_record(RESULTS, {'kind': 'boundaries_fixture', 'worker': worker,
                           'probes': probes, 'status': status})


def close_inherited_fds():
    numbers = [int(name) for name in os.listdir('/proc/self/fd') if name.isdigit()]
    for number in numbers:
        try:
            os.close(number)
        except OSError as error:
            if error.errno != errno.EBADF:
                raise


def daemon():
    worker = own_identity()
    child = os.fork()
    if child:
        waited_pid, status = os.waitpid(child, 0)
        if waited_pid != child or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise RuntimeError('first daemon fork failed')
        append_record(RESULTS, {
            'kind': 'daemon_spawned', 'worker': worker, 'first_child_pid': child,
        })
        return
    os.setsid()
    daemon_pid = os.fork()
    if daemon_pid:
        os._exit(0)
    # The detached process never retains a writable stdout/control descriptor.
    close_inherited_fds()
    daemon_worker = own_identity()
    append_record(RESULTS, {
        'kind': 'daemon_identity', 'role': 'daemonized-grandchild',
        'worker': daemon_worker, 'session_id': os.getsid(0),
    })
    started = time.monotonic()
    sequence = 0
    while True:
        now = time.monotonic()
        append_record(DAEMON_WRITES, {
            'kind': 'daemon_write', 'sequence': sequence,
            'pid': daemon_worker['pid'], 'starttime': daemon_worker['starttime'],
            'uid': daemon_worker['uid'], 'label': daemon_worker['label'],
            'cgroup': daemon_worker['cgroup'], 'monotonic_ns': time.monotonic_ns(),
            'elapsed_seconds': now - started,
            'phase': 'delayed-write' if now - started >= 2.0 else 'initial-write',
        })
        sequence += 1
        time.sleep(0.1)


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else None
    try:
        if mode not in MODES:
            raise ValueError('expected one fixed mode: ' + ', '.join(MODES))
        if mode == 'identity':
            append_record(RESULTS, {'kind': 'fixture_identity', 'worker': own_identity()})
        elif mode == 'inheritance':
            inheritance()
        elif mode == 'inheritance-grandchild':
            inheritance(grandchild=True)
        elif mode == 'boundaries':
            boundaries()
        else:
            daemon()
        return 0
    except Exception as error:
        # Error evidence also uses the fixed file, so inherited stdio is untouched.
        try:
            append_record(RESULTS, {
                'kind': 'fixture_error', 'mode': mode, 'pid': os.getpid(),
                'error_type': type(error).__name__, 'error': str(error),
            })
        except (OSError, ValueError):
            return 2  # Evidence unavailable; the harness must retain failure status.
        return 1


if __name__ == '__main__':
    os._exit(main())
