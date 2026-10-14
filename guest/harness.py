#!/usr/bin/env python3
"""Fail-closed toy Linux isolation / cgroup stop evidence runner."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import stat
import subprocess
import sys
import time
import uuid

sys.path.insert(0, '/opt/claude-code-poc/guest')
# Source-tree preflight/offline tests can import without an installed guest.
sys.path.append(str(Path(__file__).resolve().parent))
from common import (CGROOT, CONTROL_BYTES, INSTALL, MARKER, PROFILES, RUN, STATE,
                    WORK_UID, digest, identity, label, no_ptrace_cap, owned,
                    parse_events, read)

SCHEMA = 'claude-code-guest-poc/v1'
FILES = ('bootstrap.sh', 'harness.py', 'common.py', 'controller.py', 'work_probe.py', 'apparmor.profile')


def check(result, name, fn):
    try:
        evidence = fn()
        result.append({'name': name, 'status': 'passed', 'evidence': evidence})
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as ex:
        result.append({'name': name, 'status': 'blocked', 'reason': str(ex)})


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def vm_marker():
    owned(MARKER, mode=0o600)
    marker = json.loads(read(MARKER))
    require(set(marker) == {'isolated_test_vm', 'fake_data_only', 'no_host_mounts', 'vm_id'}, 'marker schema mismatch')
    require(all(marker[k] is True for k in ('isolated_test_vm', 'fake_data_only', 'no_host_mounts')), 'isolated VM declaration absent')
    require(isinstance(marker['vm_id'], str) and 1 <= len(marker['vm_id']) <= 80, 'invalid VM id')
    mounts = read('/proc/self/mountinfo')
    require(not any(f' - {kind} ' in mounts for kind in ('virtiofs', '9p', 'vboxsf', 'hgfs')), 'shared host filesystem present')
    return {'declaration': marker, 'host_shared_mount_types_observed': [],
            'boundary': 'root operator declaration + mount inspection; not a hypervisor attestation'}


def installed():
    for name in FILES:
        owned(INSTALL / name)
    for name in ('common.py', 'controller.py', 'work_probe.py'):
        owned(INSTALL / name, mode=0o644)
    owned(INSTALL / 'installed-manifest.json')
    pinned = json.loads(read(INSTALL / 'installed-manifest.json'))
    current = {name: digest(INSTALL / name) for name in FILES}
    require(pinned['files'] == current, 'installed source/profile digest differs from pinned manifest')
    require(pinned['kernel_release'] == platform.release(), 'kernel changed from pinned manifest')
    require(pinned['kernel_version'] == read('/proc/version'), 'kernel build fingerprint changed from pinned manifest')
    require(pinned['lsm'] == read('/sys/kernel/security/lsm'), 'LSM order changed from pinned manifest')
    parser = subprocess.check_output(['/usr/sbin/apparmor_parser', '--version'], text=True, stderr=subprocess.STDOUT).strip()
    require(pinned['apparmor_parser'] == parser, 'parser changed from pinned manifest')
    require(pinned['apparmor_abi'] == digest('/etc/apparmor.d/abi/4.0'), 'AppArmor ABI changed from pinned manifest')
    return pinned


def apparmor():
    require(read('/sys/module/apparmor/parameters/enabled') == 'Y', 'AppArmor not enabled')
    lsm = read('/sys/kernel/security/lsm').split(',')
    require('apparmor' in lsm and 'yama' in lsm, 'required AppArmor/Yama LSM not active')
    profiles = read('/sys/kernel/security/apparmor/profiles').splitlines()
    require(all(f'{name} (enforce)' in profiles for name in PROFILES), 'required enforcing profile absent')
    actual = label()
    require(actual == 'claude-poc-manager (enforce)', f'actual manager label {actual!r}')
    return {'enabled': True, 'active_lsm': lsm, 'required_loaded_profiles': [f'{name} (enforce)' for name in PROFILES], 'actual_manager_label': actual}


def cgroup_preflight():
    mounts = read('/proc/self/mountinfo')
    require(any(' /sys/fs/cgroup ' in line and ' - cgroup2 ' in line for line in mounts.splitlines()), 'unified cgroup v2 at fixed mount absent')
    require(os.stat('/sys/fs/cgroup').st_uid == 0, 'cgroup mount not root-owned')
    # Kernel documents cgroup.type only for non-root cgroups. The actual fixed
    # parent and newly created non-root scope MUST be domain in make_scope().
    controllers = read('/sys/fs/cgroup/cgroup.controllers').split()
    return {'mount': '/sys/fs/cgroup', 'root_type_file': 'not_applicable',
            'controllers': controllers, 'root_owned': True,
            'non_root_domain_validation': 'required_before_any_process_start'}


def no_existing_execution_uid():
    pids = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            lines = read(entry / 'status').splitlines()
            uid = next(line for line in lines if line.startswith('Uid:')).split()[1:]
            if str(WORK_UID) in uid:
                pids.append(int(entry.name))
        except FileNotFoundError:
            continue
    require(not pids, f'preexisting process uses reserved execution UID: {pids}')
    require(not Path(f'/run/user/{WORK_UID}').exists(), 'reserved UID user runtime directory exists')
    return {'reserved_uid': WORK_UID, 'preexisting_processes': [], 'user_runtime_directory': 'absent'}


def preflight():
    checks = []
    if sys.platform != 'linux':
        return {'status': 'unavailable', 'checks': [{'name': 'linux_guest', 'status': 'unavailable',
                 'reason': f'platform={sys.platform}; no Linux probes executed'}]}
    check(checks, 'isolated_test_vm', vm_marker)
    check(checks, 'root_manager', lambda: (require(os.geteuid() == 0, 'root broker required'), {'euid': os.geteuid()})[1])
    check(checks, 'root_owned_pinned_install', installed)
    check(checks, 'cgroup_v2', cgroup_preflight)
    check(checks, 'apparmor_enforcing_and_manager_label', apparmor)
    check(checks, 'yama_scope_2', lambda: (require(read('/proc/sys/kernel/yama/ptrace_scope') == '2', 'ptrace_scope must be exactly 2'), {'ptrace_scope': 2})[1])
    check(checks, 'reserved_uid_has_no_existing_processes', no_existing_execution_uid)
    return {'status': 'passed' if all(item['status'] == 'passed' for item in checks) else 'blocked', 'checks': checks}


def json_lines(text):
    # Inheritance probe deliberately writes fake data to stdio as a harmless tool channel.
    return [json.loads(line) for line in text.splitlines() if line.startswith('{')]


class ProcessDiagnosticError(RuntimeError):
    def __init__(self, process, expected, reason):
        self.diagnostics = {'role': 'controller', 'expected_message': expected,
                            'returncode': process.poll(), 'stderr_tail': ''}
        descriptor = process.stderr.fileno()
        previous = os.get_blocking(descriptor)
        os.set_blocking(descriptor, False)
        try:
            # Bounded and nonblocking even if a failed child left an inherited
            # stderr writer open. Only fake fixture diagnostics are captured.
            chunks = bytearray()
            for _ in range(16):
                try:
                    block = os.read(descriptor, 4096)
                except BlockingIOError:
                    break
                if not block:
                    break
                chunks.extend(block)
            self.diagnostics['stderr_tail'] = bytes(chunks[-4096:]).decode(errors='replace')
        finally:
            os.set_blocking(descriptor, previous)
        super().__init__(f'controller {reason} waiting for {expected}; returncode={self.diagnostics["returncode"]}')


def read_message(process, expected, timeout=10):
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout):
            raise ProcessDiagnosticError(process, expected, 'timed out')
        line = process.stdout.readline()
        if not line:
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired as ex:
                raise ProcessDiagnosticError(process, expected, 'closed stdout while still alive') from ex
            raise ProcessDiagnosticError(process, expected, 'exited')
        message = json.loads(line)
        require(message.get('kind') == expected, f'controller unexpected message {message.get("kind")}')
        return message
    finally:
        selector.close()


def command(process, kind, expected=None):
    process.stdin.write(json.dumps({'kind': kind}) + '\n')
    process.stdin.flush()
    if expected:
        return read_message(process, expected)


def safe_root_dir(path):
    path.mkdir(mode=0o755, exist_ok=True)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
            f'untrusted fixed directory: {path}')


def make_scope(run_id):
    safe_root_dir(CGROOT)
    require(read(CGROOT / 'cgroup.type') == 'domain', 'fixed cgroup root is not domain')
    require(not read(CGROOT / 'cgroup.procs'), 'fixed cgroup parent already populated')
    scope = CGROOT / f'scope-{run_id}'
    scope.mkdir(mode=0o755)
    require(read(scope / 'cgroup.type') == 'domain', 'new scope is not domain')
    require((scope / 'cgroup.kill').exists(), 'kernel lacks cgroup.kill')
    for name in ('cgroup.procs', 'cgroup.threads', 'cgroup.subtree_control'):
        info = (scope / name).stat()
        require(info.st_uid == 0 and not info.st_mode & 0o022, f'delegated cgroup file: {name}')
    return scope


def spawn(scope, profile, script, mode=None, *, controller=False):
    def child_setup():
        # Move before dropping privileges or exec/fork; no post-spawn attachment race.
        with open(scope / 'cgroup.procs', 'w') as target:
            target.write(str(os.getpid()))
        os.setgroups([])
        os.setgid(WORK_UID)
        os.setuid(WORK_UID)
    args = ['/usr/bin/aa-exec', '-p', profile, '--', '/usr/bin/python3', '-I', '-S', str(INSTALL / script)]
    if mode:
        args.append(mode)
    return subprocess.Popen(args, cwd=INSTALL, preexec_fn=child_setup,
                            stdin=subprocess.PIPE if controller else subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, close_fds=True, env={'PATH': '/usr/bin:/bin'})


def stop_scope(scope, timeout=15):
    before = parse_events(read(scope / 'cgroup.events'))
    started = time.monotonic()
    (scope / 'cgroup.kill').write_text('1\n')
    samples = []
    while True:
        values = parse_events(read(scope / 'cgroup.events'))
        samples.append({'elapsed_seconds': round(time.monotonic() - started, 4), **values})
        if values['populated'] == 0:
            break
        require(time.monotonic() - started < timeout, 'cgroup.kill timeout: execution state unknown')
        time.sleep(0.05)
    return {'scope': str(scope), 'kill_write': '1', 'before': before, 'samples': samples,
            'after': samples[-1], 'status': 'passed', 'meaning': 'scope subtree has no live processes'}


def prepare_state():
    safe_root_dir(STATE)
    require(not RUN.exists(), f'{RUN} already exists; preserve evidence and investigate before removing it')
    RUN.mkdir(mode=0o755)
    (RUN / 'control-sentinel').write_bytes(CONTROL_BYTES)
    os.chown(RUN / 'control-sentinel', WORK_UID, WORK_UID)
    (RUN / 'control-sentinel').chmod(0o600)
    for name in ('work-identities.jsonl', 'work-writes.jsonl'):
        (RUN / name).touch(mode=0o600)
        os.chown(RUN / name, WORK_UID, WORK_UID)


def isolation(scope):
    control = spawn(scope, PROFILES[1], 'controller.py', controller=True)
    try:
        ready = read_message(control, 'ready')
        t = ready['target']
        require(t['uid'] == WORK_UID and t['label'] == 'claude-poc-control (enforce)', 'control actual identity mismatch')
        require(no_ptrace_cap(t['caps']), 'controller unexpectedly has ptrace capability')
        require(identity(t['pid'])['starttime'] == t['starttime'], 'target replaced before binding')
        require(read(f"/proc/{t['pid']}/cgroup") == f'0::{str(scope).removeprefix("/sys/fs/cgroup")}', 'controller outside fixed scope')
        (RUN / 'target.json').write_text(json.dumps(t))
        (RUN / 'target.json').chmod(0o644)
        positive = command(control, 'positive_control', 'positive_control')
        require(all(positive[k] is True for k in ('message_received', 'memory_matches', 'file_matches')), 'fake target positive control failed')
        worker = spawn(scope, PROFILES[2], 'work_probe.py', 'attack')
        out, err = worker.communicate(timeout=10)
        require(worker.returncode == 0, f'attack probe failed: {err[:2000]}')
        messages = json_lines(out)
        require(len(messages) == 1, 'missing/ambiguous attack evidence')
        attacks = messages[0]
        require(attacks['target_pid'] == t['pid'] and attacks['target_starttime'] == t['starttime'], 'attack target binding mismatch')
        inheritance = command(control, 'spawn_inheritance_probe', 'inheritance_result')
        require(inheritance['returncode'] == 0, f'inheritance probe failed: {inheritance["stderr"][:2000]}')
        inherited_messages = json_lines(inheritance['stdout'])
        require(len(inherited_messages) == 1, 'missing child FD evidence')
        inherited = inherited_messages[0]
        grandchild = inherited['grandchild']
        require(grandchild['returncode'] == 0, f'grandchild probe failed: {grandchild["stderr"][:2000]}')
        child_messages = json_lines(grandchild['stdout'])
        require(len(child_messages) == 1, 'missing grandchild FD evidence')
        inherited['grandchild_parsed'] = child_messages[0]
        time.sleep(0.15)
        snapshot = command(control, 'snapshot', 'snapshot')
        failures = [p for p in attacks['probes'] if p['outcome'] != 'denied']
        leaked = [fd for report in (inherited, child_messages[0]) for fd in report['fds'] if fd.get('matches_control_identity')]
        healthy = snapshot['memory_unchanged'] and snapshot['file_unchanged'] and snapshot['fake_approvals_received'] == 0
        passed = not failures and not leaked and healthy
        return {'status': 'passed' if passed else 'blocked', 'target': t, 'positive_control': positive,
                'attacks': attacks, 'inheritance': inherited, 'controller_snapshot': snapshot,
                'non_denied_probes': failures, 'leaked_control_fd_identities': leaked,
                'boundary': 'toy controller/ctypes worker only; native SDK/Claude CLI FD behavior untested'}
    finally:
        if sys.exc_info()[0] is None and control.poll() is None:
            try:
                command(control, 'exit')
                control.wait(timeout=2)
            except (BrokenPipeError, subprocess.TimeoutExpired) as ex:
                # Fixed scope cleanup is always performed by main; never arbitrary PID kill.
                raise ProcessDiagnosticError(control, 'exit', 'graceful exit failed') from ex


def stop_test(scope):
    process = spawn(scope, PROFILES[2], 'work_probe.py', 'toy-cli')
    deadline = time.monotonic() + 8
    identities = []
    while time.monotonic() < deadline:
        identities = json_lines(read(RUN / 'work-identities.jsonl'))
        if {row['role'] for row in identities} == {'toy-cli', 'daemonized-grandchild'}:
            break
        if process.poll() is not None:
            raise RuntimeError(f'toy CLI failed: {process.stderr.read()[:2000]}')
        time.sleep(0.05)
    require(len(identities) == 2, 'CLI + daemonized grandchild identities missing')
    expected_cgroup = f'0::{str(scope).removeprefix("/sys/fs/cgroup")}'
    for row in identities:
        require(row['cgroup'] == expected_cgroup and row['label'] == 'claude-poc-work (enforce)', 'work process escaped scope/profile')
        require(identity(row['pid'])['starttime'] == row['starttime'], 'work process identity replaced')
    before_data = (RUN / 'work-writes.jsonl').read_bytes()
    while {row['role'] for row in json_lines(before_data.decode())} != {'toy-cli', 'daemonized-grandchild'}:
        require(time.monotonic() < deadline, 'both workload roles must write before stop')
        time.sleep(0.01)
        before_data = (RUN / 'work-writes.jsonl').read_bytes()
    stopped = stop_scope(scope)
    # Establish the baseline after populated=0, allowing writes made before kill completion.
    baseline = (RUN / 'work-writes.jsonl').read_bytes()
    observation_start = time.monotonic()
    time.sleep(3.0)  # exceeds each worker's 2s delayed-write timer
    after = (RUN / 'work-writes.jsonl').read_bytes()
    live = []
    for row in identities:
        try:
            current = identity(row['pid'])
            if current['starttime'] == row['starttime'] and current['state'] not in ('Z', 'X'):
                live.append(current)
        except FileNotFoundError:
            continue
    process.wait(timeout=2)
    require(after == baseline and not live, 'post-stop writing/live workload observed')
    require(parse_events(read(scope / 'cgroup.events'))['populated'] == 0, 'scope repopulated after stop')
    return {'status': 'passed', 'workload_identities': identities, 'cgroup_stop': stopped,
            'before_stop_bytes': len(before_data), 'after_populated_zero_bytes': len(baseline),
            'after_observation_bytes': len(after), 'write_digest_before_observation': hashlib.sha256(baseline).hexdigest(),
            'write_digest_after_observation': hashlib.sha256(after).hexdigest(),
            'observation_seconds': round(time.monotonic() - observation_start, 3),
            'delayed_write_seconds': 2, 'live_original_processes': [],
            'boundary': 'local fixed scope; file/API effects before stop are not rolled back'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('preflight', 'all', 'isolation', 'stop-scope'))
    args = parser.parse_args()
    report = {'schema': SCHEMA, 'run_id': uuid.uuid4().hex, 'platform': sys.platform,
              'kernel_release': platform.release(), 'machine': platform.machine(),
              'data_classification': 'fake_only', 'claim_scope': 'toy_guest_only',
              'native_sdk_cli_status': 'not_executed', 'external_delegation_status': 'not_executed',
              'preflight': preflight(), 'tests': {}, 'cleanup': {}}
    report['status'] = report['preflight']['status']
    if args.command != 'preflight' and report['status'] == 'passed':
        scope = None
        lock = None
        try:
            safe_root_dir(STATE)
            lock = open(STATE / 'harness.lock', 'a')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            prepare_state()
            scope = make_scope(report['run_id'])
            if args.command in ('all', 'isolation'):
                report['tests']['isolation'] = isolation(scope)
                # Ensure toy control/worker generation gone before the stop workload.
                report['cleanup']['isolation_scope_empty'] = stop_scope(scope)
            if args.command in ('all', 'stop-scope'):
                report['tests']['stop_scope'] = stop_test(scope)
            report['status'] = 'passed' if all(t['status'] == 'passed' for t in report['tests'].values()) else 'blocked'
        except (OSError, RuntimeError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as ex:
            report['status'] = 'blocked'
            report['error'] = {'type': type(ex).__name__, 'message': str(ex)}
            if isinstance(ex, ProcessDiagnosticError):
                report['error']['process_diagnostics'] = ex.diagnostics
        finally:
            if scope is not None:
                try:
                    report['cleanup']['final_scope_empty'] = stop_scope(scope)
                    scope.rmdir()
                except (OSError, ValueError, RuntimeError) as ex:
                    report['cleanup']['status'] = 'unknown'
                    report['cleanup']['error'] = str(ex)
                    report['status'] = 'unknown'
            if lock:
                lock.close()
    if sys.platform == 'linux' and os.geteuid() == 0 and report['preflight']['status'] == 'passed':
        # Only a fixed root-owned local evidence directory is writable by this interface.
        try:
            evidence = STATE / 'evidence'
            safe_root_dir(evidence)
            destination = evidence / f"{report['run_id']}.json"
            report['evidence_file'] = str(destination)
            destination.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
            destination.chmod(0o600)
            require(json.loads(destination.read_text()) == report, 'persisted JSON differs from report')
        except (OSError, ValueError, RuntimeError) as ex:
            report['status'] = 'unknown'
            report['evidence_write_error'] = str(ex)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report['status'] == 'passed' else 2


if __name__ == '__main__':
    sys.exit(main())
