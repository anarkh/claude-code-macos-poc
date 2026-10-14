"""Shared, offline-testable parsing; no live probes on import."""
from __future__ import annotations

import errno
import hashlib
import json
import os
from pathlib import Path
import stat

INSTALL = Path('/opt/claude-code-poc/guest')
STATE = Path('/var/lib/claude-code-poc')
RUN = STATE / 'current'
CGROOT = Path('/sys/fs/cgroup/claude-code-poc')
MARKER = Path('/etc/claude-code-poc/isolated-test-vm.json')
PROFILES = ('claude-poc-manager', 'claude-poc-control', 'claude-poc-work')
WORK_UID = 29999
CONTROL_BYTES = b'FAKE_CONTROLLER_SENTINEL_00000000'
TAMPER_BYTES = b'FAKE_WORKER_TAMPER_SENTINEL_00000'
FAKE_MESSAGE = b'FAKE_APPROVAL_TEST_ONLY\n'
CAP_SYS_PTRACE = 19


def read(path):
    return Path(path).read_text().strip()


def parse_events(text):
    values = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2 or parts[0] in values:
            raise ValueError('invalid or duplicate cgroup.events line')
        values[parts[0]] = int(parts[1])
    if values.get('populated') not in (0, 1):
        raise ValueError('missing/invalid populated field')
    return values


def parse_proc_stat(text):
    # comm can contain spaces and closing parentheses; split at its last ')'.
    left, right = text.rsplit(')', 1)
    pid = int(left.split('(', 1)[0].strip())
    fields = right.split()
    if len(fields) < 20:
        raise ValueError('short proc stat')
    return {'pid': pid, 'state': fields[0], 'starttime': int(fields[19])}


def identity(pid):
    return parse_proc_stat(read(f'/proc/{int(pid)}/stat'))


def label():
    return read('/proc/self/attr/current')


def capabilities():
    status = dict(line.split(':', 1) for line in read('/proc/self/status').splitlines() if ':' in line)
    return {key: int(status[key].strip(), 16) for key in ('CapInh', 'CapPrm', 'CapEff', 'CapBnd', 'CapAmb')}


def no_ptrace_cap(caps):
    return all(not caps[k] & (1 << CAP_SYS_PTRACE) for k in ('CapInh', 'CapPrm', 'CapEff', 'CapAmb'))


def owned(path, *, uid=0, mode=None):
    """Require a regular root-owned file and trusted, non-writable ancestors."""
    path = Path(path)
    for item in [path, *path.parents]:
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022:
            raise ValueError(f'untrusted owner/mode/link: {item}')
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError(f'not a singly linked regular file: {path}')
    if mode is not None and stat.S_IMODE(info.st_mode) != mode:
        raise ValueError(f'wrong mode: {path}')
    return info


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def syscall_result(name, result, err=0, **extra):
    if result >= 0:
        outcome = 'allowed'
    elif err in (errno.EPERM, errno.EACCES):
        outcome = 'denied'
    elif err in (errno.ENOSYS, errno.EOPNOTSUPP):
        outcome = 'unsupported'
    else:
        outcome = 'inconclusive'
    return {'name': name, 'outcome': outcome, 'return_value': result,
            'errno': err, 'errno_name': errno.errorcode.get(err), **extra}


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)
