#!/usr/bin/env python3
"""Fresh no-NIC VM plus fake-only mTLS gateway, with independent shutdown."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from fake_messages import FakeMessages
from prepare_relay_fixture import prepare, write_private

HOST = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('run')
    args = parser.parse_args()
    run = args.run
    paths = [HOST / 'runs' / (run + suffix) for suffix in ('.serial.log', '.host.jsonl', '.stdout.log')]
    outputs = [HOST / 'evidence' / (run + suffix) for suffix in ('.json', '-gateway.json', '-upstream.json', '-relay-chain.json')]
    if any(p.exists() for p in paths + outputs):
        raise RuntimeError('fresh run basename required')
    running = subprocess.run(['/usr/bin/pgrep', '-x', 'vm-poc'], stdout=subprocess.DEVNULL)
    if running.returncode != 1:
        raise RuntimeError('stop any existing PoC VM before preparing a new test disk')
    private = prepare(run)
    subprocess.run([sys.executable, str(HOST / 'prepare_image.py'), '--reset-test-disk'], check=True)
    subprocess.run([sys.executable, str(HOST / 'build_seed.py'), '--mode', 'native', '--native-test', 'relay', '--relay-fixture', str(private)], check=True)
    seed_content = (HOST / 'seed/user-data').read_bytes()
    if b'host-only-FAKE-provider-NOT-VALID' in seed_content:
        raise RuntimeError('host provider fixture key must not enter guest payload')
    from gateway import GatewayServer, load_config
    gateway = GatewayServer(load_config(private / 'config.json'))
    upstream = FakeMessages()
    vm = None
    def interrupted(signum, _frame):
        raise InterruptedError('fixture interrupted by signal ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    started = time.monotonic()
    outcome = {'schema': 'relay-chain-orchestration/v1', 'run': run, 'fake_only': True,
               'host_provider_key_absent_from_guest_payload': True, 'project_execution_enabled': False}
    try:
        upstream.start()
        gateway.start()
        with paths[1].open('xb') as host_log, paths[2].open('xb') as stdout:
            command = [str(HOST / '.build/debug/vm-poc'), 'boot', str(HOST / 'images'),
                       str(HOST / 'seed-native.iso'), str(paths[0]), '300', str(private / 'transport.json')]
            vm = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=host_log, close_fds=True)
            outcome['vm_exit'] = vm.wait(timeout=330)
    except Exception as error:
        outcome['error'] = type(error).__name__
        raise
    finally:
        if vm is not None and vm.poll() is None:
            vm.terminate()
            try:
                vm.wait(timeout=8)
            except subprocess.TimeoutExpired:
                vm.kill(); vm.wait(timeout=3)
        gateway.stop('vm_scope_finished')
        upstream.stop()
        write_private(outputs[2], json.dumps(upstream.snapshot(), sort_keys=True, indent=2) + '\n')
        outcome['gateway_socket_removed'] = not Path(gateway.address).exists()
        outcome['elapsed_seconds'] = round(time.monotonic() - started, 3)
        outcome['gateway'] = gateway.evidence
        outcome['private_material_retained_for_local_debug_only'] = True
        write_private(outputs[3], json.dumps(outcome, sort_keys=True, indent=2) + '\n')
    if outcome.get('vm_exit') != 0:
        raise RuntimeError('VM failed; raw logs and blocked evidence retained')
    subprocess.run([sys.executable, str(HOST / 'extract_evidence.py'), run], check=True)
    extracted = json.loads(outputs[0].read_text())
    if extracted['script_exit_markers']['NATIVE'] != [0]:
        raise RuntimeError('native relay fixture blocked; see persisted evidence')
    print(json.dumps({'kind': 'relay_fixture_complete', 'run': run, 'project_execution_enabled': False}))


if __name__ == '__main__':
    main()
