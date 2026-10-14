#!/usr/bin/env python3
"""Clone one immutable guest, transport fixed frames, stop VM, remove owned data."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

from common import ROOT, build_seed, public_file, validate_base


def private_run_root(path):
    if not path.is_absolute() or '\x00' in str(path) or '..' in path.parts:
        raise RuntimeError('private_run_root_path')
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise RuntimeError('private_run_root_metadata')
    finally:
        os.close(descriptor)
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image-dir', type=Path, required=True)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--guest-runtime-dir', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--probe', action='store_true')
    parser.add_argument('--fixture', action='store_true')
    parser.add_argument('--evidence-dir', type=Path)
    parser.add_argument('--run-root', type=Path)
    args = parser.parse_args()
    if not 30 <= args.timeout <= 600:
        raise RuntimeError('timeout_bound')
    helper = None
    state = {'stopped': False, 'stderr_bytes': 0, 'signal': None, 'stop_requested_at': None}
    owned = None
    began = time.monotonic()
    cleanup_complete = False
    code = 2
    parent_pid = os.getppid()
    watchdog_done = threading.Event()
    def forward_signal(number, _frame):
        state['signal'] = number
        if state['stop_requested_at'] is None:
            state['stop_requested_at'] = time.monotonic()
        if helper and helper.poll() is None:
            helper.send_signal(number)

    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)

    def monitor_parent():
        while not watchdog_done.wait(0.25):
            if os.getppid() != parent_pid:
                forward_signal(signal.SIGTERM, None)
                return

    watchdog = threading.Thread(target=monitor_parent, daemon=True)
    watchdog.start()

    def check_cancelled():
        if state['signal'] is not None:
            raise InterruptedError('launch_cancelled')

    try:
        validate_base(args.image_dir)
        check_cancelled()
        run_root = private_run_root(args.run_root) if args.run_root else Path('/private/tmp')
        owned = Path(tempfile.mkdtemp(prefix='claude-text-vm-', dir=run_root))
        owned.chmod(0o700)
        # clonefile guarantees independent blocks on write; no base disk mutation.
        subprocess.run(['/bin/cp', '-c', str(args.image_dir / 'guest.raw'), str(owned / 'guest.raw')], check=True)
        (owned / 'guest.raw').chmod(0o600)
        for name in ('kernel', 'initrd'):
            shutil.copyfile(args.image_dir / name, owned / name)
        guest = args.guest_runtime_dir
        files = [public_file(guest / 'bootstrap.sh', '/opt/claude-text/bootstrap.sh', '0700'),
                 public_file(guest / 'supervisor.py', '/opt/claude-text/supervisor.py', '0700'),
                 public_file(guest / ('fixture.mjs' if args.fixture else 'runtime.mjs'), '/opt/claude-text/sdk/runtime.mjs', '0644')]
        if args.probe:
            files += [public_file(guest / 'privacy_probe.py', '/opt/claude-text/privacy_probe.py', '0644'),
                      {'path': '/etc/claude-text/probe-enabled', 'owner': 'root:root', 'permissions': '0600', 'content': 'synthetic-probe-only\n'}]
        seed = build_seed(owned, files, [['sh', '-c',
            'bash /opt/claude-text/bootstrap.sh > /dev/hvc0 2>&1; code=$?; echo TEXT_GUEST_EXIT=$code > /dev/hvc0']])
        check_cancelled()
        helper = subprocess.Popen([str(args.runner.absolute()), 'boot', str(owned), str(seed),
                                   str(owned / 'serial.log'), str(args.timeout)],
                                  stdin=None, stdout=None, stderr=subprocess.PIPE, close_fds=True)

        def read_diagnostics():
            while True:
                line = helper.stderr.readline(8193)
                if not line:
                    return
                state['stderr_bytes'] += len(line)
                if state['stderr_bytes'] > 64 * 1024 or len(line) > 8192:
                    helper.terminate()
                    return
                try:
                    value = json.loads(line)
                except (ValueError, UnicodeError):
                    helper.terminate()
                    return
                if value.get('kind') == 'vm_stopped':
                    state['stopped'] = True
                sys.stderr.buffer.write(line)
                sys.stderr.buffer.flush()

        thread = threading.Thread(target=read_diagnostics, daemon=True)
        thread.start()

        if state['signal'] is not None:
            helper.send_signal(state['signal'])
        # Fixed VZ timeout bounds the only guest process. Parent signals enter
        # helper's synchronous stop path; no owned VM survives this launcher.
        while True:
            try:
                code = helper.wait(timeout=0.25)
                break
            except subprocess.TimeoutExpired:
                if state['stop_requested_at'] is not None and time.monotonic() - state['stop_requested_at'] > 10:
                    helper.kill()
                    code = helper.wait(timeout=5)
                    state['stopped'] = False
                    break
                if time.monotonic() - began > args.timeout + 20:
                    raise
        thread.join(timeout=2)
        if args.evidence_dir:
            args.evidence_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
            shutil.copyfile(owned / 'serial.log', args.evidence_dir / 'serial.log')
            (args.evidence_dir / 'summary.json').write_text(json.dumps({
                'schema': 'text-vm-launch-evidence/v1', 'helper_exit_code': code,
                'vm_stopped_observed': state['stopped'], 'duration_seconds': round(time.monotonic() - began, 2),
                'fixture': args.fixture, 'probe': args.probe}) + '\n')
    finally:
        watchdog_done.set()
        if helper and helper.poll() is None:
            helper.terminate()
            try:
                helper.wait(timeout=10)
            except subprocess.TimeoutExpired:
                helper.kill()
                helper.wait(timeout=5)
                state['stopped'] = False
        if owned:
            shutil.rmtree(owned)
        cleanup_complete = owned is None or not owned.exists()
    if not state['stopped'] or not cleanup_complete:
        code = 2
    print(json.dumps({'kind': 'vm_stopped', 'cleanup_complete': state['stopped'] and cleanup_complete,
                      'exit_code': code}), flush=True)
    return code


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'kind': 'vm_launch_error', 'error_code': 'launch_failed',
                          'error_type': type(error).__name__}), file=sys.stderr, flush=True)
        sys.exit(2)
