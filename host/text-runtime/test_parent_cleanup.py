#!/usr/bin/env python3
"""Real VM parent-death fixture; persist only bounded, anonymous evidence.

The standin directly launches launch.py.  The harness holds its stdin writer
open after killing only that standin, so EOF cannot stand in for the launcher's
parent watchdog.  Orphan exit status is reported by the launcher frame; process
absence is checked separately rather than claiming a waitpid observation.
"""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

from common import ROOT


_LIMIT = 64 * 1024
_STANDIN = """import os, signal, subprocess, sys
child = subprocess.Popen(sys.argv[2:], stdin=None, stdout=None, stderr=None, close_fds=True)
descriptor = int(sys.argv[1])
os.write(descriptor, (str(child.pid) + '\\n').encode('ascii'))
os.close(descriptor)
while True:
    signal.pause()
"""


class _Failure(Exception):
    def __init__(self, classification):
        self.classification = classification
        super().__init__(classification)


def _process_rows():
    result = subprocess.run(
        ['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat='], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2,
        env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'},
    )
    rows = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 4:
            raise _Failure('process_snapshot_invalid')
        rows.append((int(fields[0]), int(fields[1]), int(fields[2]), fields[3].startswith(b'Z')))
    return rows


def _running(pid, rows):
    return any(value == pid and not zombie for value, _, _, zombie in rows)


def _group_running(group):
    return any(pgid == group and not zombie for _, _, pgid, zombie in _process_rows())


def _stop_owned_group(group):
    """Fallback targets only the new session created by this test."""
    for number, grace in ((signal.SIGTERM, 1.0), (signal.SIGKILL, 0.5)):
        if not _group_running(group):
            return True
        try:
            os.killpg(group, number)
        except ProcessLookupError:
            return True
        until = time.monotonic() + grace
        while time.monotonic() < until:
            if not _group_running(group):
                return True
            time.sleep(0.05)
    return not _group_running(group)


def _frames(path):
    with path.open('rb') as handle:
        contents = handle.read(_LIMIT + 1)
    if len(contents) > _LIMIT:
        raise _Failure('fixture_log_bound_exceeded')
    complete = contents.split(b'\n')[:-1]
    values = []
    for line in complete:
        if len(line) > 8192:
            raise _Failure('fixture_frame_bound_exceeded')
        try:
            value = json.loads(line)
        except (ValueError, UnicodeError):
            raise _Failure('invalid_fixture_frame') from None
        if not isinstance(value, dict):
            raise _Failure('invalid_fixture_frame')
        values.append(value)
    return values


def _launcher_pid(descriptor, deadline):
    contents = b''
    while time.monotonic() < deadline:
        if not select.select([descriptor], [], [], 0.05)[0]:
            continue
        part = os.read(descriptor, 33)
        contents += part
        if len(contents) > 32 or not part:
            raise _Failure('launcher_pid_handshake_invalid')
        if contents.endswith(b'\n'):
            if not contents[:-1].isdigit():
                raise _Failure('launcher_pid_handshake_invalid')
            return int(contents[:-1])
    raise _Failure('launcher_pid_handshake_timeout')


def run():
    begin = time.monotonic()
    deadline = begin + 24
    evidence = {
        'schema': 'text-vm-parent-cleanup/v1',
        'status': 'failed_real_vm_parent_death',
        'classification': 'test_not_completed',
        'checks': {
            'signed_helper_verified': False,
            'private_run_root_mode_verified': False,
            'vm_config_observed': False,
            'actual_vm_started_observed': False,
            'zero_network_devices': False,
            'zero_directory_shares': False,
            'only_standin_parent_killed': False,
            'stdin_kept_open_after_parent_death': False,
            'helper_stopped_for_host_signal': False,
            'launcher_stdout_vm_stopped_observed': False,
            'launcher_reported_nonzero_exit': False,
            'launcher_reported_cleanup_complete': False,
            'owned_clone_directory_removed': False,
            'launcher_process_absent': False,
            'helper_process_absent': False,
            'standin_process_reaped': False,
            'fallback_group_cleanup_needed': False,
            'fallback_owned_group_stopped': False,
            'temporary_fixture_removed': False,
            'completed_under_30_seconds': False,
            'real_credentials_or_hardware_identifiers_read': False,
        },
        'reported_exit': 'unobserved',
        'process_exit_observation': 'process_absence_separate_from_reported_exit',
        'duration_seconds': None,
        'cleanup_after_parent_death_seconds': None,
    }
    checks = evidence['checks']
    fixture = None
    standin = None
    descriptors = []
    killed_at = None
    try:
        if sys.platform != 'darwin':
            raise _Failure('macos_required')
        runner = ROOT / 'host/.build/release/vm-text-runtime'
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(runner)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        checks['signed_helper_verified'] = True
        fixture = Path(tempfile.mkdtemp(prefix='claude-text-parent-cleanup-', dir='/private/tmp'))
        fixture.chmod(0o700)
        run_root = fixture / 'run-root'
        run_root.mkdir(mode=0o700)
        checks['private_run_root_mode_verified'] = stat.S_IMODE(run_root.stat().st_mode) == 0o700
        stdout_path, stderr_path = fixture / 'stdout.ndjson', fixture / 'stderr.ndjson'
        command = [sys.executable, str(ROOT / 'host/text-runtime/launch.py'),
                   '--image-dir', str(ROOT / 'host/text-runtime/images'),
                   '--runner', str(runner),
                   '--guest-runtime-dir', str(ROOT / 'guest/text-runtime'),
                   '--fixture', '--run-root', str(run_root), '--timeout', '90']
        input_read, input_write = os.pipe()
        report_read, report_write = os.pipe()
        descriptors += [input_read, input_write, report_read, report_write]
        with stdout_path.open('xb') as stdout, stderr_path.open('xb') as stderr:
            stdout_path.chmod(0o600)
            stderr_path.chmod(0o600)
            standin = subprocess.Popen(
                [sys.executable, '-B', '-c', _STANDIN, str(report_write), *command],
                stdin=input_read, stdout=stdout, stderr=stderr,
                pass_fds=(report_write,), start_new_session=True, close_fds=True,
                env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C',
                     'PYTHONUNBUFFERED': '1', 'PYTHONDONTWRITEBYTECODE': '1'},
            )
            for descriptor in (input_read, report_write):
                os.close(descriptor)
                descriptors.remove(descriptor)
            launcher = _launcher_pid(report_read, deadline)
            helper = None
            while time.monotonic() < deadline:
                events = _frames(stdout_path)
                config = next((item for item in events if item.get('kind') == 'vm_config'), None)
                if config is not None:
                    checks['vm_config_observed'] = True
                    checks['zero_network_devices'] = config.get('network_devices') == 0
                    checks['zero_directory_shares'] = config.get('directory_shares') == 0
                    children = [pid for pid, ppid, pgid, zombie in _process_rows()
                                if ppid == launcher and pgid == standin.pid and not zombie]
                    if len(children) != 1:
                        raise _Failure('actual_helper_not_uniquely_observed')
                    helper = children[0]
                    if not list(run_root.iterdir()):
                        raise _Failure('owned_clone_not_observed_before_parent_death')
                    killed_at = time.monotonic()
                    standin.kill()  # Only this test's standin, never the launcher/helper.
                    standin.wait(timeout=1)
                    checks['only_standin_parent_killed'] = standin.returncode == -signal.SIGKILL
                    checks['standin_process_reaped'] = True
                    # Retain input_write until after launcher/helper cleanup.
                    checks['stdin_kept_open_after_parent_death'] = input_write in descriptors
                    break
                if standin.poll() is not None:
                    raise _Failure('standin_exited_before_vm_config')
                time.sleep(0.05)
            if helper is None:
                raise _Failure('vm_config_timeout')
            while time.monotonic() < deadline:
                events = _frames(stdout_path)
                diagnostics = _frames(stderr_path)
                stopped = next((item for item in events if item.get('kind') == 'vm_stopped'), None)
                rows = _process_rows()
                if stopped is not None and not _running(launcher, rows) and not _running(helper, rows):
                    checks['launcher_stdout_vm_stopped_observed'] = True
                    checks['launcher_reported_cleanup_complete'] = stopped.get('cleanup_complete') is True
                    exit_code = stopped.get('exit_code')
                    checks['launcher_reported_nonzero_exit'] = type(exit_code) is int and exit_code != 0
                    evidence['reported_exit'] = 'nonzero' if checks['launcher_reported_nonzero_exit'] else 'zero_or_invalid'
                    checks['actual_vm_started_observed'] = any(item.get('kind') == 'vm_started' for item in diagnostics)
                    checks['helper_stopped_for_host_signal'] = any(
                        item.get('kind') == 'vm_stopped' and item.get('reason') == 'host_signal'
                        for item in diagnostics)
                    checks['launcher_process_absent'] = True
                    checks['helper_process_absent'] = True
                    checks['owned_clone_directory_removed'] = not list(run_root.iterdir())
                    evidence['cleanup_after_parent_death_seconds'] = round(time.monotonic() - killed_at, 3)
                    break
                time.sleep(0.05)
            required = [name for name in checks if name not in {
                'fallback_group_cleanup_needed', 'fallback_owned_group_stopped',
                'temporary_fixture_removed', 'completed_under_30_seconds',
                'real_credentials_or_hardware_identifiers_read',
            }]
            if not all(checks[name] is True for name in required):
                raise _Failure('parent_watchdog_cleanup_incomplete')
            evidence['status'] = 'passed_real_vm_parent_death'
            evidence['classification'] = 'parent_watchdog_stopped_vm_and_removed_owned_clone'
    except _Failure as error:
        evidence['classification'] = error.classification
    except subprocess.TimeoutExpired:
        evidence['classification'] = 'bounded_subprocess_timeout'
    except subprocess.CalledProcessError:
        evidence['classification'] = 'required_subprocess_failed'
    except (OSError, ValueError):
        evidence['classification'] = 'fixture_execution_failed'
    finally:
        if standin is not None:
            try:
                remaining = _group_running(standin.pid)
                checks['fallback_group_cleanup_needed'] = remaining
                checks['fallback_owned_group_stopped'] = not remaining or _stop_owned_group(standin.pid)
                if not checks['fallback_owned_group_stopped']:
                    evidence['status'] = 'failed_real_vm_parent_death'
                    evidence['classification'] = 'owned_process_group_cleanup_failed'
                if standin.poll() is None:
                    standin.wait(timeout=1)
                checks['standin_process_reaped'] = standin.poll() is not None
            except (OSError, ValueError, subprocess.SubprocessError, _Failure):
                evidence['status'] = 'failed_real_vm_parent_death'
                evidence['classification'] = 'owned_process_group_cleanup_failed'
        for descriptor in descriptors:
            os.close(descriptor)
        if fixture is not None:
            try:
                shutil.rmtree(fixture)
                checks['temporary_fixture_removed'] = not fixture.exists()
            except OSError:
                evidence['status'] = 'failed_real_vm_parent_death'
                evidence['classification'] = 'temporary_fixture_cleanup_failed'
        evidence['duration_seconds'] = round(time.monotonic() - begin, 3)
        checks['completed_under_30_seconds'] = time.monotonic() - begin < 30
        if not checks['completed_under_30_seconds']:
            evidence['status'] = 'failed_real_vm_parent_death'
            evidence['classification'] = 'test_time_bound_exceeded'
    return evidence


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'host/evidence/text-vm-parent-cleanup-2026-10-12.json')
    args = parser.parse_args()
    if args.output.exists():
        print(json.dumps({'kind': 'parent_cleanup_test_complete', 'status': 'failed',
                          'classification': 'evidence_already_exists'}))
        return 2
    value = run()
    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open('x') as destination:
            json.dump(value, destination, indent=2, sort_keys=True)
            destination.write('\n')
    except OSError:
        print(json.dumps({'kind': 'parent_cleanup_test_complete', 'status': 'failed',
                          'classification': 'evidence_write_failed'}))
        return 2
    print(json.dumps({'kind': 'parent_cleanup_test_complete', 'status': value['status'],
                      'classification': value['classification'],
                      'duration_seconds': value['duration_seconds'],
                      'cleanup_after_parent_death_seconds': value['cleanup_after_parent_death_seconds']}))
    return 0 if value['status'] == 'passed_real_vm_parent_death' else 1


if __name__ == '__main__':
    sys.exit(main())
