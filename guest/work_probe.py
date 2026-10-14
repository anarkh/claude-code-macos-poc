"""Linux ctypes attacks against the harness-created fake controller only."""
import ctypes
import errno
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import time

sys.path.insert(0, '/opt/claude-code-poc/guest')
from common import (CONTROL_BYTES, FAKE_MESSAGE, INSTALL, RUN, TAMPER_BYTES,
                    WORK_UID, capabilities, emit, identity, label, no_ptrace_cap,
                    owned, read, syscall_result)


class IOVec(ctypes.Structure):
    _fields_ = [('base', ctypes.c_void_p), ('length', ctypes.c_size_t)]


def own_state():
    lib = ctypes.CDLL(None, use_errno=True)
    if lib.prctl(38, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'worker no_new_privs failed')
    caps = capabilities()
    value = {**identity(os.getpid()), 'uid': os.getuid(), 'label': label(),
             'caps': caps, 'no_cap_sys_ptrace': no_ptrace_cap(caps)}
    if value['uid'] != WORK_UID or value['label'] != 'claude-poc-work (enforce)' or not value['no_cap_sys_ptrace']:
        raise RuntimeError('actual work UID/profile/capabilities mismatch')
    return value


def target():
    # No arbitrary PID, memory address, file, command or destination parameters.
    owned(RUN / 'target.json', mode=0o644)
    value = json.loads(read(RUN / 'target.json'))
    now = identity(value['pid'])
    if now['starttime'] != value['starttime'] or now['state'] in ('Z', 'X'):
        raise RuntimeError('harness controller is dead/replaced')
    if value['uid'] != WORK_UID or value['label'] != 'claude-poc-control (enforce)':
        raise RuntimeError('manifest target identity mismatch')
    return value


def call(lib, name, *args):
    ctypes.set_errno(0)
    result = getattr(lib, name)(*args)
    return result, ctypes.get_errno()


def attack():
    worker = own_state()
    t = target()
    lib = ctypes.CDLL(None, use_errno=True)
    lib.ptrace.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
    lib.ptrace.restype = ctypes.c_long
    results = []
    rv, err = call(lib, 'ptrace', 16, t['pid'], None, None)  # PTRACE_ATTACH
    results.append(syscall_result('ptrace_attach', rv, err))
    if rv == 0:
        os.waitpid(t['pid'], os.WUNTRACED)
        peek, peek_err = call(lib, 'ptrace', 2, t['pid'], t['memory_address'], None)
        results.append(syscall_result('ptrace_peekdata', peek, peek_err,
                                      sentinel_prefix_observed=peek_err == 0 and
                                      peek & ((1 << 64) - 1) == int.from_bytes(CONTROL_BYTES[:8], sys.byteorder)))
        call(lib, 'ptrace', 17, t['pid'], None, None)
    for operation, data in [('readv', CONTROL_BYTES), ('writev', TAMPER_BYTES)]:
        name = f'process_vm_{operation}'
        if not hasattr(lib, name):
            results.append({'name': name, 'outcome': 'unsupported', 'reason': 'libc symbol absent'})
            continue
        buf = ctypes.create_string_buffer(data if operation == 'writev' else b'\0' * len(CONTROL_BYTES))
        local = IOVec(ctypes.addressof(buf), len(CONTROL_BYTES))
        remote = IOVec(t['memory_address'], len(CONTROL_BYTES))
        fn = getattr(lib, name)
        fn.argtypes = [ctypes.c_int, ctypes.POINTER(IOVec), ctypes.c_ulong,
                       ctypes.POINTER(IOVec), ctypes.c_ulong, ctypes.c_ulong]
        fn.restype = ctypes.c_ssize_t
        rv, err = call(lib, name, t['pid'], ctypes.byref(local), 1, ctypes.byref(remote), 1, 0)
        results.append(syscall_result(name, rv, err,
                                     sentinel_observed=operation == 'readv' and buf.raw[:len(CONTROL_BYTES)] == CONTROL_BYTES))
    if platform.machine() not in ('aarch64', 'arm64', 'x86_64'):
        results.append({'name': 'pidfd_getfd', 'outcome': 'unsupported', 'reason': 'unpinned syscall ABI'})
    else:
        lib.syscall.restype = ctypes.c_long
        fd, err = call(lib, 'syscall', ctypes.c_long(434), ctypes.c_int(t['pid']), ctypes.c_uint(0))
        if fd < 0:
            results.append(syscall_result('pidfd_getfd', fd, err, stage='pidfd_open'))
        else:
            try:
                for remote_fd in (t['sentinel_fd'], *t['control_fds']):
                    copied, err = call(lib, 'syscall', ctypes.c_long(438), ctypes.c_int(fd), ctypes.c_int(remote_fd), ctypes.c_uint(0))
                    item = syscall_result('pidfd_getfd', copied, err, target_fd=remote_fd)
                    if copied >= 0:
                        try:
                            if remote_fd == t['sentinel_fd']:
                                item['sentinel_observed'] = os.pread(copied, len(CONTROL_BYTES), 0) == CONTROL_BYTES
                            else:
                                item['fake_message_write'] = os.write(copied, FAKE_MESSAGE)
                        except OSError as ex:
                            item['followup_errno'] = ex.errno
                        finally:
                            os.close(copied)
                    results.append(item)
            finally:
                os.close(fd)
    for fd_number in (t['sentinel_fd'], *t['control_fds']):
        try:
            fd = os.open(f"/proc/{t['pid']}/fd/{fd_number}", os.O_RDWR | os.O_CLOEXEC)
        except OSError as ex:
            results.append(syscall_result('proc_fd_reopen', -1, ex.errno, target_fd=fd_number))
        else:
            item = syscall_result('proc_fd_reopen', fd, target_fd=fd_number)
            try:
                if fd_number == t['sentinel_fd']:
                    item['sentinel_observed'] = os.pread(fd, len(CONTROL_BYTES), 0) == CONTROL_BYTES
                else:
                    item['fake_message_write'] = os.write(fd, FAKE_MESSAGE)
            except OSError as ex:
                item['followup_errno'] = ex.errno
            finally:
                os.close(fd)
            results.append(item)
    # Test only this disposable probe's own PID against fixed non-delegated roots.
    scope_path = t['cgroup'].removeprefix('0::')
    if not scope_path.startswith('/claude-code-poc/scope-') or '/' in scope_path[len('/claude-code-poc/'):]:
        raise RuntimeError('invalid fixed target cgroup binding')
    for relative in ('/cgroup.procs', '/claude-code-poc/cgroup.procs', scope_path + '/cgroup.procs'):
        destination = Path('/sys/fs/cgroup' + relative)
        try:
            fd = os.open(destination, os.O_WRONLY | os.O_CLOEXEC)
        except OSError as ex:
            results.append(syscall_result('cgroup_migration', -1, ex.errno, destination=str(destination), stage='open'))
        else:
            try:
                count = os.write(fd, str(os.getpid()).encode())
                results.append(syscall_result('cgroup_migration', count, destination=str(destination), stage='write'))
            except OSError as ex:
                results.append(syscall_result('cgroup_migration', -1, ex.errno, destination=str(destination), stage='write'))
            finally:
                os.close(fd)
    emit({'kind': 'attack_result', 'worker': worker, 'target_pid': t['pid'],
          'target_starttime': t['starttime'], 'probes': results})


def inheritance(grandchild=False):
    worker = own_state()
    t = target()
    numbers = set([0, 1, 2, t['sentinel_fd'], *t['control_fds']])
    numbers.update(int(p.name) for p in Path('/proc/self/fd').iterdir())
    results = []
    for fd in sorted(numbers):
        item = {'fd': fd, 'is_stdio': fd in (0, 1, 2)}
        try:
            info = os.fstat(fd)
            item['matches_control_identity'] = any(
                info.st_dev == known['device'] and info.st_ino == known['inode'] and
                info.st_mode == known['mode'] for known in t['control_fd_identities'])
            item['path'] = os.readlink(f'/proc/self/fd/{fd}')
            # Test actual usable inherited pipe/socket and /dev/fd aliases, not only enumeration.
            item['write_count'] = os.write(fd, FAKE_MESSAGE)
        except OSError as ex:
            item['write_errno'] = ex.errno
        try:
            alias = os.open(f'/dev/fd/{fd}', os.O_WRONLY | os.O_CLOEXEC)
            try:
                item['dev_fd_write_count'] = os.write(alias, FAKE_MESSAGE)
            finally:
                os.close(alias)
        except OSError as ex:
            item['dev_fd_errno'] = ex.errno
        results.append(item)
    report = {'kind': 'inheritance_probe', 'generation': 'grandchild' if grandchild else 'child',
              'worker': worker, 'fds': results}
    if not grandchild:
        child = subprocess.run(['/usr/bin/python3', '-I', '-S', str(INSTALL / 'work_probe.py'), 'inheritance-grandchild'],
                               stdin=subprocess.DEVNULL, capture_output=True, close_fds=True,
                               env={'PATH': '/usr/bin:/bin'}, timeout=5)
        report['grandchild'] = {'returncode': child.returncode, 'stdout': child.stdout.decode(errors='replace'),
                                'stderr': child.stderr.decode(errors='replace')}
    emit(report)


def toy_cli():
    own_state()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        daemon = os.fork()
        if daemon:
            os._exit(0)
        role = 'daemonized-grandchild'
    else:
        os.waitpid(pid, 0)
        role = 'toy-cli'
    with open(RUN / 'work-identities.jsonl', 'a', buffering=1) as output:
        output.write(json.dumps({'role': role, **own_state(), 'cgroup': read('/proc/self/cgroup')}) + '\n')
    started = time.monotonic()
    delayed = False
    with open(RUN / 'work-writes.jsonl', 'a', buffering=1) as output:
        while True:
            now = time.monotonic()
            output.write(json.dumps({'role': role, 'pid': os.getpid(), 'kind': 'heartbeat'}) + '\n')
            if not delayed and now - started >= 2:
                output.write(json.dumps({'role': role, 'pid': os.getpid(), 'kind': 'delayed-write'}) + '\n')
                delayed = True
            time.sleep(0.1)


if __name__ == '__main__':
    if sys.platform != 'linux':
        emit({'status': 'unavailable', 'reason': 'Linux guest required'})
        sys.exit(2)
    mode = sys.argv[1] if len(sys.argv) == 2 else ''
    if mode == 'attack':
        attack()
    elif mode in ('inheritance', 'inheritance-grandchild'):
        inheritance(mode == 'inheritance-grandchild')
    elif mode == 'toy-cli':
        toy_cli()
    else:
        raise ValueError('unknown fixed probe mode')
