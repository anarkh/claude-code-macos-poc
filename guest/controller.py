"""Toy controller only. Every byte is fake; never loads SDK/CLI or real keys."""
import ctypes
import json
import os
import selectors
import socket
import subprocess
import sys
import time

sys.path.insert(0, '/opt/claude-code-poc/guest')
from common import (CONTROL_BYTES, FAKE_MESSAGE, INSTALL, RUN, WORK_UID,
                    capabilities, emit, identity, label, read)


def main():
    if os.getuid() != WORK_UID or label() != 'claude-poc-control (enforce)':
        raise RuntimeError('actual control identity/profile mismatch')
    memory = ctypes.create_string_buffer(CONTROL_BYTES)
    sentinel = open(RUN / 'control-sentinel', 'r+b', buffering=0)
    receiver, sender = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    # Real control input is fd 0; all extra control FDs are CLOEXEC.
    os.set_inheritable(sentinel.fileno(), False)
    os.set_inheritable(receiver.fileno(), False)
    os.set_inheritable(sender.fileno(), False)
    target = {**identity(os.getpid()), 'uid': os.getuid(), 'label': label(),
              'caps': capabilities(), 'cgroup': read('/proc/self/cgroup'),
              'memory_address': ctypes.addressof(memory),
              'memory_size': len(CONTROL_BYTES), 'sentinel_fd': sentinel.fileno(),
              'control_fds': [0, receiver.fileno(), sender.fileno()],
              'control_fd_identities': [
                  {'fd': fd, 'device': os.fstat(fd).st_dev, 'inode': os.fstat(fd).st_ino,
                   'mode': os.fstat(fd).st_mode}
                  for fd in (0, receiver.fileno(), sender.fileno())]}
    emit({'kind': 'ready', 'target': target})
    poll = selectors.DefaultSelector()
    poll.register(receiver, selectors.EVENT_READ)
    poll.register(sys.stdin, selectors.EVENT_READ)
    approvals = 0
    while True:
        for key, _ in poll.select(0.05):
            if key.fileobj is receiver:
                data = receiver.recv(4096)
                approvals += data.count(FAKE_MESSAGE)
            else:
                line = sys.stdin.readline()
                if not line:
                    return
                if line.encode() == FAKE_MESSAGE:
                    approvals += 1
                    continue
                command = json.loads(line)
                if command['kind'] == 'spawn_inheritance_probe':
                    worker = subprocess.run(
                        ['/usr/bin/aa-exec', '-p', 'claude-poc-work', '--',
                         '/usr/bin/python3', '-I', '-S', str(INSTALL / 'work_probe.py'), 'inheritance'],
                        cwd=INSTALL, stdin=subprocess.DEVNULL, capture_output=True,
                        close_fds=True, env={'PATH': '/usr/bin:/bin', 'PYTHONPATH': ''}, timeout=10)
                    emit({'kind': 'inheritance_result', 'returncode': worker.returncode,
                          'stdout': worker.stdout.decode(errors='replace'),
                          'stderr': worker.stderr.decode(errors='replace')})
                elif command['kind'] == 'snapshot':
                    emit({'kind': 'snapshot', 'memory_unchanged': memory.raw[:len(CONTROL_BYTES)] == CONTROL_BYTES,
                          'file_unchanged': os.pread(sentinel.fileno(), len(CONTROL_BYTES), 0) == CONTROL_BYTES,
                          'fake_approvals_received': approvals})
                elif command['kind'] == 'positive_control':
                    # Establish that this is a live fake endpoint, then reset its counter.
                    sender.sendall(FAKE_MESSAGE)
                    data = receiver.recv(4096)
                    emit({'kind': 'positive_control', 'message_received': data == FAKE_MESSAGE,
                          'memory_matches': memory.raw[:len(CONTROL_BYTES)] == CONTROL_BYTES,
                          'file_matches': os.pread(sentinel.fileno(), len(CONTROL_BYTES), 0) == CONTROL_BYTES})
                elif command['kind'] == 'exit':
                    return
                else:
                    raise ValueError('unknown fixed control message')


if __name__ == '__main__':
    # -I disables cwd import; this root-owned fixed directory is the sole source.
    main()
