#!/usr/bin/env python3
"""Real-VM local fixtures; fake canaries only, never real account/hardware probes."""
import argparse
import json
from pathlib import Path
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

from common import ROOT


def run_once(output, *, cancel=False, invalid_kind=False, oversized=False):
    command = [sys.executable, str(ROOT / 'host/text-runtime/launch.py'),
               '--image-dir', str(ROOT / 'host/text-runtime/images'),
               '--runner', str(ROOT / 'host/.build/release/vm-text-runtime'),
               '--guest-runtime-dir', str(ROOT / 'guest/text-runtime'),
               '--timeout', '90', '--fixture', '--probe', '--evidence-dir', str(output)]
    run_root = Path(tempfile.mkdtemp(prefix='claude-text-test-run-root-', dir='/private/tmp'))
    run_root.chmod(0o700)
    command += ['--run-root', str(run_root)]
    before = set(Path('/private/tmp').glob('claude-text-vm-*'))
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stderr = []

    def errors():
        for line in child.stderr:
            if sum(len(part) for part in stderr) < 65536:
                stderr.append(line)

    drain = threading.Thread(target=errors, daemon=True)
    drain.start()
    events = []
    begin = time.monotonic()
    ready_at = None
    try:
        while time.monotonic() - begin < 120:
            if not select.select([child.stdout], [], [], 2)[0]:
                if child.poll() is not None:
                    break
                continue
            raw = child.stdout.readline(1024 * 1024 + 2)
            if not raw:
                break
            value = json.loads(raw)
            events.append(value)
            if value['kind'] == 'vm_config' and cancel:
                child.terminate()
            if value['kind'] == 'ready':
                ready_at = round(time.monotonic() - begin, 2)
                raw = (b'{"kind":"shell","command":"synthetic forbidden fixture"}\n' if invalid_kind else
                       b'{"kind":"start","prompt":"' + b'x' * (1024 * 1024) + b'"}\n' if oversized else
                       b'{"kind":"start","provider":"synthetic","model":"synthetic","prompt":"VM fixture only","runtime":{}}\n')
                try:
                    child.stdin.write(raw)
                    child.stdin.flush()
                except BrokenPipeError:
                    if not oversized:
                        raise
            if value['kind'] == 'result':
                child.stdin.close()
        code = child.wait(timeout=15)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
    drain.join(timeout=2)
    if output.exists():
        (output / 'helper-diagnostics.ndjson').write_bytes(b''.join(stderr))
        (output / 'frames.json').write_text(json.dumps(events, indent=2) + '\n')
    owned_clean = not (set(Path('/private/tmp').glob('claude-text-vm-*')) - before)
    owned_clean = owned_clean and not list(run_root.iterdir())
    shutil.rmtree(run_root)
    config = next((event for event in events if event.get('kind') == 'vm_config'), None)
    stopped = next((event for event in events if event.get('kind') == 'vm_stopped'), None)
    result = next((event for event in events if event.get('kind') == 'result'), None)
    privacy = next((event for event in events if event.get('kind') == 'privacy'), None)
    if not config or config.get('network_devices') != 0 or config.get('directory_shares') != 0:
        raise AssertionError('isolation_configuration_missing')
    if not stopped or stopped.get('cleanup_complete') is not True or not owned_clean:
        raise AssertionError('vm_stop_or_owned_cleanup_missing')
    if cancel or invalid_kind or oversized:
        if code == 0 or result is not None:
            raise AssertionError('cancel_claimed_success')
    else:
        if code != 0 or not result or result.get('ok') is not True or result.get('disposable_state_clean') is not True:
            raise AssertionError('fresh_fixture_result_missing')
        if not privacy or privacy.get('available') is not True:
            raise AssertionError('privacy_evidence_missing')
        if not all(value is True for value in privacy['checks'].values()):
            raise AssertionError('guest_privacy_observation_failed:' + json.dumps(privacy['checks']))
        if not all(value.get('available') is True and value.get('denied') is True for value in privacy['attempts'].values()):
            raise AssertionError('guest_negative_attempt_failed:' + json.dumps(privacy['attempts']))
        for name in ('ipv4DnsUdp', 'ipv6DnsUdp'):
            if privacy['attempts'][name].get('noRoute') is not True:
                raise AssertionError('dns_no_route_unproven')
    return {'cancel': cancel, 'invalid_kind': invalid_kind, 'oversized': oversized,
            'exit_code': code, 'ready_seconds': ready_at,
            'duration_seconds': round(time.monotonic() - begin, 2), 'config': config,
            'cleanup_complete': stopped['cleanup_complete'], 'owned_private_directory_removed': owned_clean,
            'privacy': privacy, 'disposable_state_clean': result.get('disposable_state_clean') if result else None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    fake = Path('/private/tmp/claude-text-host-fixture')
    fake.mkdir(mode=0o700, exist_ok=False)
    canary = fake / 'canary.txt'
    canary.write_text('SYNTHETIC-HOST-ONLY-CANARY-NOT-A-SECRET\n')
    canary.chmod(0o600)
    ipc = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    ipc.bind(str(fake / 'broker.sock'))
    ipc.listen(1)
    http = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    http.bind(('127.0.0.1', 45789))
    http.listen(1)
    try:
        values = [run_once(args.output_dir / ('boot-' + str(index))) for index in (1, 2)]
        values.append(run_once(args.output_dir / 'cancel', cancel=True))
        values.append(run_once(args.output_dir / 'invalid-kind', invalid_kind=True))
        values.append(run_once(args.output_dir / 'oversized', oversized=True))
        result = {'schema': 'text-vm-privacy-tests/v1', 'status': 'passed_local_vm_fixtures',
                  'synthetic_host_file_and_socket_exist': canary.is_file(),
                  'canary_bytes_enter_guest': False,
                  'host_fixture_path_mapping': 'same fixed public synthetic path exists only in host namespace',
                  'real_credentials_or_hardware_identifiers_read': False,
                  'runs': values}
        (args.output_dir / 'privacy-summary.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({'kind': 'privacy_tests_complete', 'status': result['status'],
                          'boot_ready_seconds': [value['ready_seconds'] for value in values],
                          'all_owned_directories_removed': all(value['owned_private_directory_removed'] for value in values)}))
    finally:
        ipc.close()
        http.close()
        shutil.rmtree(fake)


if __name__ == '__main__':
    main()
