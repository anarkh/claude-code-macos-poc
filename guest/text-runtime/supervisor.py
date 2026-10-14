#!/usr/bin/env python3
"""Single-run guest process supervisor; bounded JSON is the sole VZ interface."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time

MAX_FRAME = 1024 * 1024
MAX_STREAM = 32 * 1024 * 1024
UID = 59999
PORT = 40124
GUEST_INPUT = frozenset(('start', 'provider_response', 'provider_chunk', 'provider_end', 'cancel'))
GUEST_OUTPUT = frozenset(('ready', 'native_init', 'provider_request', 'result', 'runtime_error'))
ENV = {'PATH': '/usr/bin:/bin', 'HOME': '/home/claude', 'USER': 'claude',
       'LOGNAME': 'claude', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8',
       'TMPDIR': '/home/claude/tmp', 'CLAUDE_CONFIG_DIR': '/home/claude/.claude'}


def drop_privileges():
    os.setgroups([])
    os.setgid(UID)
    os.setuid(UID)
    os.umask(0o077)


def frame(raw, allowed):
    if not raw.endswith(b'\n') or len(raw) > MAX_FRAME + 1:
        raise ValueError('frame_bound')
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get('kind') not in allowed:
        raise ValueError('frame_kind')
    return value


def main():
    if sys.platform != 'linux' or os.getuid() != 0 or not hasattr(socket, 'AF_VSOCK'):
        raise RuntimeError('guest_preflight')
    if sorted(p.name for p in Path('/sys/class/net').iterdir()) != ['lo']:
        raise RuntimeError('guest_network_devices')
    channel = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    channel.settimeout(10)
    channel.connect((2, PORT))
    channel.settimeout(None)
    writer = channel.makefile('wb', buffering=0)
    reader = channel.makefile('rb')
    if Path('/etc/claude-text/probe-enabled').is_file():
        probe_env = {key: value for key, value in ENV.items() if key != 'CLAUDE_CONFIG_DIR'}
        probe_env['PYTHONUNBUFFERED'] = '1'
        probe = subprocess.run(['/usr/bin/python3', '/opt/claude-text/privacy_probe.py'],
                               cwd='/home/claude/work', env=probe_env,
                               preexec_fn=drop_privileges, close_fds=True,
                               capture_output=True, timeout=15)
        if probe.returncode != 0 or len(probe.stdout) > 32 * 1024:
            raise RuntimeError('privacy_probe_failed')
        frame(probe.stdout, {'privacy'})
        writer.write(probe.stdout)
    child = subprocess.Popen(['/usr/bin/node', '/opt/claude-text/sdk/runtime.mjs'],
                             cwd='/home/claude/work', env=ENV, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             preexec_fn=drop_privileges, start_new_session=True,
                             close_fds=True)
    state = {'stopped': False, 'result': False, 'input_failed': False, 'stderr_bytes': 0}
    lock = threading.Lock()

    def terminate():
        with lock:
            if state['stopped']:
                return
            state['stopped'] = True
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                return
            child.wait(timeout=2)

    def inputs():
        total = 0
        try:
            while True:
                raw = reader.readline(MAX_FRAME + 2)
                if not raw:
                    terminate()
                    return
                total += len(raw)
                if total > MAX_STREAM:
                    raise ValueError('stream_bound')
                value = frame(raw, GUEST_INPUT)
                child.stdin.write(raw)
                child.stdin.flush()
                if value['kind'] == 'cancel':
                    terminate()
                    return
        except (OSError, ValueError, BrokenPipeError):
            state['input_failed'] = True
            terminate()

    def drain_errors():
        # SDK diagnostics can contain guest paths/provider body; do not publish them.
        while True:
            chunk = child.stderr.read(8192)
            if not chunk:
                return
            state['stderr_bytes'] += len(chunk)
            if state['stderr_bytes'] > 1024 * 1024:
                terminate()
                return

    threads = [threading.Thread(target=inputs, daemon=True), threading.Thread(target=drain_errors, daemon=True)]
    for thread in threads:
        thread.start()
    total = 0
    try:
        while True:
            raw = child.stdout.readline(MAX_FRAME + 2)
            if not raw:
                break
            total += len(raw)
            if total > MAX_STREAM:
                raise ValueError('stream_bound')
            value = frame(raw, GUEST_OUTPUT)
            writer.write(raw)
            if value['kind'] == 'result':
                state['result'] = True
        code = child.wait(timeout=3)
        if code != 0 or not state['result']:
            writer.write(b'{"kind":"runtime_error","error_code":"guest_runtime_failed"}\n')
            return 2
        return 0
    finally:
        terminate()
        channel.shutdown(socket.SHUT_RDWR)
        writer.close()
        reader.close()
        channel.close()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        # Error type is enough for serial boot diagnosis; never print raw values.
        print('TEXT_GUEST_FAILURE=' + type(error).__name__, flush=True)
        sys.exit(2)
