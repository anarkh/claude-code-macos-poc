"""Fixed native fixture broker; root cgroup termination is independent of SDK."""
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys
import time

INSTALL = Path('/opt/claude-code-poc/native')
RUNTIME = Path('/opt/claude-code-poc/native-runtime/sdk')
CURRENT = Path('/var/lib/claude-code-native-poc/current')
CGROOT = Path('/sys/fs/cgroup/claude-code-native-poc')
SCOPE = CGROOT / 'current'
UID = 29998
CLI = RUNTIME / 'node_modules/@anthropic-ai/claude-agent-sdk-linux-arm64/claude'
RELAY_INSTALL = Path('/opt/claude-code-poc/relay/relay.py')
RELAY_CONFIG = Path('/etc/claude-code-poc/relay.json')
RELAY_SCOPE = CGROOT / 'relay'


def read(path):
    return Path(path).read_text().strip()


def owned(path, directory=False):
    value = Path(path).lstat()
    if value.st_uid != 0 or value.st_mode & 0o022 or stat.S_ISLNK(value.st_mode):
        raise RuntimeError(f'root-owned immutable path required: {path}')
    if directory and not stat.S_ISDIR(value.st_mode):
        raise RuntimeError(f'directory required: {path}')
    return value


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, value, mode=0o644):
    with open(path, 'x') as output:
        output.write(json.dumps(value, sort_keys=True, indent=2) + '\n')
    os.chmod(path, mode)


def preflight():
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise RuntimeError('fixed Linux root guest required')
    if Path(__file__).resolve() != INSTALL / 'manager.py':
        raise RuntimeError('fixed installed manager required')
    marker = Path('/etc/claude-code-poc/isolated-test-vm.json')
    info = owned(marker)
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise RuntimeError('marker must be 0600')
    value = json.loads(read(marker))
    if any(value.get(k) is not True for k in ('isolated_test_vm', 'fake_data_only', 'no_host_mounts')) or value.get('vm_id') != 'vm-poc-001':
        raise RuntimeError('isolated fake-only VM marker mismatch')
    interfaces = sorted(p.name for p in Path('/sys/class/net').iterdir())
    if interfaces != ['lo']:
        raise RuntimeError('no NIC required: only lo allowed')
    mounts = read('/proc/self/mountinfo')
    if ' - virtiofs ' in mounts or ' - 9p ' in mounts:
        raise RuntimeError('host share filesystem present')
    if read('/proc/sys/kernel/yama/ptrace_scope') != '2':
        raise RuntimeError('Yama 2 required; broker does not alter it')
    if read('/sys/module/apparmor/parameters/enabled') != 'Y' or 'apparmor' not in read('/sys/kernel/security/lsm').split(','):
        raise RuntimeError('AppArmor enforcing capability required')
    if not Path('/sys/fs/cgroup/cgroup.controllers').is_file():
        raise RuntimeError('cgroup v2 required')
    for base in (INSTALL, RUNTIME):
        owned(base, directory=True)
        for entry in base.rglob('*'):
            owned(entry)
    for path in (Path('/opt/claude-code-poc/node'), CLI, Path('/etc/apparmor.d/abi/4.0')):
        owned(path)
    if RELAY_CONFIG.exists():
        owned(RELAY_CONFIG); owned(RELAY_INSTALL)
    return interfaces


def prepare():
    interfaces = preflight()
    # Seed gives files 0700. Only fixed published sources need nonroot reads.
    for p in INSTALL.iterdir():
        if p.is_file():
            p.chmod(0o644 if p.suffix in ('.py', '.profile', '.json', '.md') else 0o755)
    for p in RUNTIME.rglob('*'):
        if p.is_dir():
            p.chmod(0o755)
        elif p.is_file():
            p.chmod(0o755 if p == CLI else 0o644)
    manifest = {'schema': 'native-guest-pin/v1', 'kernel': platform.release(),
                'architecture': platform.machine(), 'network_interfaces': interfaces,
                'node_sha256': digest('/opt/claude-code-poc/node'), 'cli_sha256': digest(CLI),
                'sdk_version': json.loads(read(RUNTIME / 'node_modules/@anthropic-ai/claude-agent-sdk/package.json'))['version'],
                'source_sha256': {p.name: digest(p) for p in INSTALL.iterdir() if p.is_file() and p.name != 'installed-manifest.json'},
                'runner_sha256': digest(RUNTIME / 'run-native-admission.mjs'),
                'origin_contract_sha256': digest(RUNTIME / 'origin-contract.mjs'),
                'apparmor_abi_sha256': digest('/etc/apparmor.d/abi/4.0')}
    if RELAY_CONFIG.exists():
        manifest['relay_source_sha256'] = digest(RELAY_INSTALL)
    pin = INSTALL / 'installed-manifest.json'
    if pin.exists():
        owned(pin)
        if json.loads(read(pin)) != manifest:
            raise RuntimeError('native pin mismatch; no automatic re-pin')
    else:
        write_json(pin, manifest)
    print(json.dumps({'kind': 'native_preflight', 'status': 'ready', 'manifest': manifest}), flush=True)


def identity(pid):
    text = read(f'/proc/{pid}/stat')
    suffix = text[text.rfind(')') + 2:].split()
    status = dict(line.split(':', 1) for line in read(f'/proc/{pid}/status').splitlines() if ':' in line)
    return {'pid': pid, 'starttime': int(suffix[19]), 'state': suffix[0],
            'ppid': int(suffix[1]), 'pgrp': int(suffix[2]), 'session': int(suffix[3]),
            'uid': int(status['Uid'].split()[0]), 'label': read(f'/proc/{pid}/attr/current'),
            'cgroup': read(f'/proc/{pid}/cgroup'), 'cap_eff': status['CapEff'].strip()}


def fds(pid, owner):
    result = []
    for path in sorted(Path(f'/proc/{pid}/fd').iterdir(), key=lambda p: int(p.name)):
        try:
            value = path.stat()
            link = os.readlink(path)
        except FileNotFoundError:
            continue  # The process can legitimately close an FD during snapshot.
        result.append({'owner': owner, 'fd': int(path.name), 'device': value.st_dev,
                       'inode': value.st_ino, 'type': stat.S_IFMT(value.st_mode), 'path': link})
    return result


def events():
    return dict(line.split() for line in read(SCOPE / 'cgroup.events').splitlines())


class RelaySession:
    def __init__(self):
        self.child = None
        self.log = None
        self.stopped = None
        self.configuration = None

    def start(self):
        info = owned(RELAY_CONFIG)
        if stat.S_IMODE(info.st_mode) != 0o600:
            raise RuntimeError('root-only relay configuration required')
        self.configuration = json.loads(read(RELAY_CONFIG))
        if self.configuration.get('schema') != 'guest-relay-fixture/v1':
            raise RuntimeError('fixed relay fixture config required')
        if RELAY_SCOPE.exists():
            raise RuntimeError('fresh root relay scope required')
        RELAY_SCOPE.mkdir(mode=0o755)
        self.log = open(CURRENT.parent / 'relay.log', 'xb', buffering=0)
        def relay_setup():
            (RELAY_SCOPE / 'cgroup.procs').write_text(str(os.getpid()))
        self.child = subprocess.Popen(['/usr/bin/aa-exec', '-p', 'claude-native-relay', '--',
                                       '/usr/bin/python3', '-I', '-S', str(RELAY_INSTALL), str(RELAY_CONFIG)],
                                      stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log, close_fds=True,
                                      env={'PATH': '/usr/bin:/bin', 'TZ': 'Asia/Tokyo'}, preexec_fn=relay_setup)
        ready = CURRENT.parent / 'relay-ready.json'
        deadline = time.monotonic() + 10
        while not ready.is_file():
            if self.child.poll() is not None or time.monotonic() >= deadline:
                tail = (CURRENT.parent / 'relay.log').read_text(errors='replace')[-1200:]
                raise RuntimeError('fixed root relay did not publish ready marker; ' + tail.strip())
            time.sleep(.05)
        value = json.loads(read(ready))
        if value.get('ready') is not True or any(value.get(k) != self.configuration.get(k) for k in ('session_id', 'boot_epoch')):
            raise RuntimeError('root relay readiness epoch mismatch')
        actual = identity(self.child.pid)
        if actual['uid'] != 0 or actual['label'] != 'claude-native-relay (enforce)' or actual['cgroup'] != '0::/claude-code-native-poc/relay':
            raise RuntimeError('root relay identity/scope mismatch')
        client = CURRENT / 'controller' / 'relay-client.json'
        write_json(client, {'schema': 'relay-client/v1', **{k: self.configuration[k] for k in ('session_id', 'boot_epoch', 'client_token')}}, 0o400)
        os.chown(client, UID, UID)
        return actual

    def close(self):
        if self.stopped is not None:
            return self.stopped
        errors = []
        if self.child is not None:
            if self.child.poll() is None:
                self.child.terminate()
            try:
                self.child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                errors.append('relay_graceful_stop_timeout')
        if RELAY_SCOPE.exists():
            (RELAY_SCOPE / 'cgroup.kill').write_text('1')
            deadline = time.monotonic() + 3
            while 'populated 0' not in read(RELAY_SCOPE / 'cgroup.events') and time.monotonic() < deadline:
                time.sleep(.01)
            if self.child is not None:
                self.child.wait(timeout=3)
            scope_events = dict(line.split() for line in read(RELAY_SCOPE / 'cgroup.events').splitlines())
        else:
            scope_events = {'populated': 'not_created'}
        if self.log:
            self.log.close()
        self.stopped = {'events': scope_events, 'exit': self.child.returncode if self.child else None,
                        'ready_marker_removed': not (CURRENT.parent / 'relay-ready.json').exists(), 'errors': errors}
        return self.stopped


def run(mode, relay=None):
    preflight()
    if read('/proc/self/attr/current') != 'claude-native-manager (enforce)':
        raise RuntimeError('native manager must enforce')
    if CURRENT.exists() or SCOPE.exists():
        raise RuntimeError('fresh native fixture state/scope required; reset disposable VM')
    base = CURRENT.parent
    base.mkdir(mode=0o755, exist_ok=True)
    CURRENT.mkdir(mode=0o755)
    for name in ('controller', 'home', 'tmp', 'work'):
        directory = CURRENT / name
        directory.mkdir(mode=0o700)
        os.chown(directory, UID, UID)
    protected_value = {'fake_control_receipt': 'NATIVE-POC-SECRET-NOT-A-CREDENTIAL'}
    write_json(CURRENT / 'controller' / 'protected-fake.json', protected_value, 0o600)
    # Keep controller file root-owned despite same UID everywhere else.
    CGROOT.mkdir(mode=0o755, exist_ok=True)
    SCOPE.mkdir(mode=0o755)
    owned(CGROOT, directory=True); owned(SCOPE, directory=True)
    if not (SCOPE / 'cgroup.kill').is_file():
        raise RuntimeError('kernel cgroup.kill unavailable')
    relay_identity = relay.start() if relay else None
    log = open(CURRENT / 'controller' / 'runner.log', 'xb', buffering=0)
    def child_setup():
        (SCOPE / 'cgroup.procs').write_text(str(os.getpid()))
        os.setgroups([])
        os.setgid(UID)
        os.setuid(UID)
    command = ['/usr/bin/aa-exec', '-p', 'claude-native-controller', '--',
               '/opt/claude-code-poc/node', str(RUNTIME / 'run-native-admission.mjs'), mode]
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                             close_fds=True, env={'PATH': '/usr/bin:/bin', 'HOME': str(CURRENT / 'home'),
                             'TMPDIR': str(CURRENT / 'tmp'), 'TZ': 'Asia/Tokyo'}, preexec_fn=child_setup)
    evidence = {'schema': 'claude-native-admission/v1', 'mode': mode,
                'simulation': 'fake local Messages API; genuine SDK/CLI/Bash',
                'manager': identity(os.getpid()), 'scope': str(SCOPE),
                'strict_origin_status': 'pending', 'native_attack_probes': 'not_executed_due_to_automatic_review_rejection',
                'admission_status': 'blocked_pending_full_native_security_validation'}
    if relay:
        evidence['relay_identity'] = relay_identity
        evidence['fixed_egress_rules'] = json.loads(read('/etc/claude-code-poc/egress-rules.json'))
    deadline = time.monotonic() + 100
    try:
        info_path = CURRENT / 'controller' / 'process-info.json'
        while not info_path.is_file():
            if child.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('native controller did not publish CLI identity')
            time.sleep(.05)
        value = json.loads(read(info_path))
        if value.get('controller_pid') != child.pid or type(value.get('cli_pid')) is not int:
            raise RuntimeError('controller spawn identity mismatch')
        profile_deadline = time.monotonic() + 3
        while True:
            node = identity(child.pid); cli = identity(value['cli_pid'])
            if cli['label'] == 'claude-native-cli (enforce)':
                break
            if time.monotonic() >= profile_deadline:
                raise RuntimeError('native CLI mandatory profile transition deadline')
            time.sleep(.02)
        if node['uid'] != UID or cli['uid'] != UID or node['label'] != 'claude-native-controller (enforce)' or cli['label'] != 'claude-native-cli (enforce)':
            raise RuntimeError('native UID/profile transitions not enforced')
        if node['cgroup'] != '0::/claude-code-native-poc/current' or cli['cgroup'] != node['cgroup']:
            raise RuntimeError('controller/CLI escaped fixed scope')
        node_fds = fds(child.pid, 'node'); cli_fds = fds(cli['pid'], 'cli')
        # libuv may implement stdio "pipes" using socketpair. Socketpair endpoint
        # inode values differ, so compare work FDs against both actual endpoints.
        # Node supplies its exact stdin/stdout handle numbers at spawn; root
        # independently resolves those and CLI FD 0/1 at fixed PID/starttime.
        cli_control = [x for x in cli_fds if x['fd'] in (0, 1) and x['type'] in (stat.S_IFIFO, stat.S_IFSOCK)]
        handles = value.get('node_control_fds')
        if not isinstance(handles, list) or len(handles) != 2 or {h.get('role') for h in handles} != {'stdin', 'stdout'} or any(type(h.get('fd')) is not int for h in handles):
            raise RuntimeError('native SDK exact control handle numbers missing')
        bound = [x for x in node_fds if x['fd'] in [h['fd'] for h in handles] and x['type'] in (stat.S_IFIFO, stat.S_IFSOCK)]
        if len(cli_control) != 2 or len(bound) != 2:
            raise RuntimeError('SDK control descriptors not bound at both actual endpoints')
        targets = {'run_id': mode, 'controller': node, 'cli': cli,
                   'control_fd_identities': [*bound, *cli_control],
                   'all_controller_fds': node_fds, 'all_cli_fds': cli_fds,
                   'scope': str(SCOPE), 'fake_api_port': 41417,
                   'control_endpoint_binding': 'spawn handle numbers plus root PID/starttime/fstat of Node and CLI endpoints; socketpair endpoints have different inodes'}
        write_json(CURRENT / 'targets.json', targets)
        write_json(CURRENT / 'target-ready.json', {'ready': True})
        evidence['actual_targets'] = targets
        evidence['observed_work_processes'] = []
        observed = set()
        complete = CURRENT / 'controller' / 'summary.json'
        while not complete.is_file():
            if child.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('native runner did not finish bounded fixture')
            # Passive metadata for this fixed broker-owned scope only. No
            # memory, control-FD I/O, or arbitrary PID targets are accepted.
            for pid_text in read(SCOPE / 'cgroup.procs').splitlines():
                pid = int(pid_text)
                if pid in (node['pid'], cli['pid']) or pid in observed:
                    continue
                try:
                    own = identity(pid)
                    if own['label'] != 'claude-native-work (enforce)':
                        continue
                    if own['cgroup'] != node['cgroup']:
                        raise RuntimeError('observed work process scope mismatch')
                    evidence['observed_work_processes'].append({'identity': own, 'cmdline': read(f'/proc/{pid}/cmdline').replace('\0', ' ')[:1800], 'fds': fds(pid, 'work')})
                    observed.add(pid)
                except (FileNotFoundError, ProcessLookupError) as error:
                    evidence.setdefault('observer_exit_races', []).append({'pid': pid, 'error': type(error).__name__})
            time.sleep(.01)
        evidence['runner'] = json.loads(read(complete))
        evidence['strict_origin_status'] = evidence['runner'].get('strict_origin_status', 'blocked')
        if evidence['runner'].get('error'):
            raise RuntimeError('native runner failed: ' + evidence['runner']['error'] + '; ' + evidence['runner'].get('stderr', '').strip()[:2000])
        writes = CURRENT / 'work' / 'daemon-writes.jsonl'
        if mode in ('isolation', 'contract', 'relay'):
            daemon_deadline = time.monotonic() + 8
            while not writes.exists() or 'delayed-write' not in writes.read_text():
                if time.monotonic() >= daemon_deadline:
                    raise RuntimeError('real Bash daemon did not establish delayed writes')
                time.sleep(.1)
        evidence['pre_kill'] = {'events': events(), 'writes_bytes': writes.stat().st_size if writes.exists() else 0,
                                'delayed_write_seen': writes.exists() and 'delayed-write' in writes.read_text()}
    except Exception as error:
        evidence['error'] = f'{type(error).__name__}: {error}'
        evidence['runner_log_tail'] = (CURRENT / 'controller' / 'runner.log').read_text(errors='replace')[-12000:]
    finally:
        # No SDK interrupt precondition. This root fixed broker always closes scope.
        stop_started = time.monotonic()
        (SCOPE / 'cgroup.kill').write_text('1')
        stop_deadline = time.monotonic() + 3
        while events().get('populated') != '0' and time.monotonic() < stop_deadline:
            time.sleep(.01)
        child.wait(timeout=3)
        kill_elapsed_ms = round((time.monotonic() - stop_started) * 1000)
        writes = CURRENT / 'work' / 'daemon-writes.jsonl'
        before = writes.read_bytes() if writes.exists() else b''
        observation_started = time.monotonic()
        time.sleep(3)
        after = writes.read_bytes() if writes.exists() else b''
        evidence['root_stop'] = {'cgroup_kill_elapsed_ms': kill_elapsed_ms,
                                 'events': events(), 'controller_exit': child.returncode,
                                 'writes_stable_for_3_seconds': before == after,
                                 'final_writes_bytes': len(after), 'sdk_interrupt_required': False,
                                 'observation_seconds': round(time.monotonic() - observation_started, 3),
                                 'writes_sha256_before': hashlib.sha256(before).hexdigest(),
                                 'writes_sha256_after': hashlib.sha256(after).hexdigest()}
        if relay:
            evidence['relay_stop'] = relay.close()
            relay_evidence = CURRENT.parent / 'relay-evidence.json'
            if relay_evidence.is_file():
                evidence['relay'] = json.loads(read(relay_evidence))
            else:
                evidence['error'] = evidence.get('error', 'root relay stopped without evidence')
            if evidence['relay_stop']['errors'] or evidence['relay_stop']['events'].get('populated') != '0' or not evidence['relay_stop']['ready_marker_removed']:
                evidence['error'] = evidence.get('error', 'root relay lifecycle validation failed')
        fixture = CURRENT / 'work' / 'fixture-results.jsonl'
        evidence['work_fixture'] = [json.loads(line) for line in fixture.read_text().splitlines() if line.strip()] if fixture.exists() else []
        inheritance = [x for x in evidence['work_fixture'] if x.get('kind') == 'inheritance_fixture']
        boundaries = [x for x in evidence['work_fixture'] if x.get('kind') == 'boundaries_fixture']
        work_identities = [x['worker'] for x in evidence['work_fixture'] if 'worker' in x]
        expected_profile = all(x.get('label') == 'claude-native-work (enforce)' and x.get('uid') == UID and x.get('cgroup') == '0::/claude-code-native-poc/current' for x in work_identities) and bool(work_identities)
        no_leak = {x.get('generation') for x in inheritance} == {'child', 'grandchild'} and all(not x.get('leaked_control_fd_identities') for x in inheritance)
        protected_unchanged = json.loads(read(CURRENT / 'controller' / 'protected-fake.json')) == protected_value
        evidence['verified_subset'] = {
            'real_native_controller_cli_work_domains': expected_profile and bool(evidence.get('actual_targets')),
            'passive_control_fd_inheritance_child_and_grandchild': no_leak,
            'fixed_work_boundaries': boundaries[-1]['status'] if boundaries else 'not_executed',
            'protected_fake_file_unchanged': protected_unchanged,
            'builtin_protected_create_absent': not (CURRENT / 'controller' / 'forbidden-create.txt').exists(),
            'actual_builtin_write_read_edit': evidence.get('runner', {}).get('actual_builtin_fixture_content') == 'native fixture edited\n',
            'root_scope_empty_after_stop': evidence['root_stop']['events'].get('populated') == '0',
            'real_daemon_writes_stable_after_stop': evidence['root_stop']['writes_stable_for_3_seconds'] and evidence['root_stop']['final_writes_bytes'] > 0,
            'production_business_key_isolation': 'host_gateway_fake_provider_key_only' if relay else 'not_qualified_fake_key_presence_only',
        }
        if relay:
            token_sha = evidence.get('runner', {}).get('relay_session', {}).get('client_token_sha256')
            evidence['verified_subset']['work_key_is_limited_session_token'] = bool(token_sha and work_identities) and all(x.get('ANTHROPIC_API_KEY_sha256') == token_sha for x in work_identities)
        evidence['known_blockers'] = ['Native cross-process memory and foreign control-FD reopening probes were not executed after automatic review rejection.',
                                     'Production real API/proxy and CLI internal messaging channel remain unqualified.'] if relay else [
                                     'Native cross-process memory and foreign control-FD reopening probes were not executed after automatic review rejection.',
                                     'AppArmor protocol rule does not enforce exact local TCP destination.',
                                     'Work environment may inherit the fake API key; production credentials require a host gateway.']
        log.close()
    out = base / 'native-admission-summary.json'
    write_json(out, evidence)
    print('POC_NATIVE_BEGIN', flush=True)
    print(json.dumps(evidence, sort_keys=True, indent=2), flush=True)
    print('POC_NATIVE_END', flush=True)
    return 2 if evidence.get('error') else 0


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['prepare']:
            prepare(); sys.exit(0)
        if len(sys.argv) != 2 or sys.argv[1] not in ('isolation', 'contract', 'relay'):
            raise RuntimeError('only fixed native fixture modes permitted')
        relay = RelaySession() if sys.argv[1] == 'relay' else None
        try:
            code = run(sys.argv[1], relay)
        finally:
            if relay:
                relay.close()
        sys.exit(code)
    except Exception as error:
        fatal = {'schema': 'claude-native-admission/v1', 'status': 'blocked', 'error': f'{type(error).__name__}: {error}'}
        # The fixed root bootstrap relays persisted evidence even if an exec
        # transition revalidates or discards an inherited output descriptor.
        if platform.system() == 'Linux' and os.geteuid() == 0 and Path(__file__).resolve() == INSTALL / 'manager.py' and CURRENT.parent.is_dir():
            output = CURRENT.parent / 'native-admission-summary.json'
            if not output.exists():
                write_json(output, fatal)
        print('POC_NATIVE_BEGIN', flush=True)
        print(json.dumps(fatal), flush=True)
        print('POC_NATIVE_END', flush=True)
        sys.exit(2)
