#!/usr/bin/env python3
"""Compile frozen Swift inputs and test actual AppKit quit against bundled VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--evidence-dir', type=Path, required=True)
    args = parser.parse_args()
    tests = Path(__file__).resolve().parent
    source_root = tests.parent / 'Sources' / 'ClaudeIsolationPoC'
    runtime = args.bundle.resolve() / 'Contents' / 'Resources' / 'Runtime'
    bundle_config = json.loads((args.bundle / 'Contents' / 'Resources' / 'ProjectConfiguration.json').read_text())
    module = runtime / 'sdk' / 'vm-text-chat.mjs'
    if not module.is_file() or not Path(bundle_config['nodeExecutable']).is_file():
        raise RuntimeError('bundled_runtime_unavailable')
    args.evidence_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='appkit-vm-quit-fixture-') as temporary:
        fixture = Path(temporary)
        snapshots = fixture / 'swift-snapshot'
        snapshots.mkdir(mode=0o700)
        digests = {}
        files = [p for p in sorted(source_root.glob('*.swift')) if p.name != 'main.swift']
        files.append(tests / 'VMQuitFixture.swift')
        for source in files:
            data = source.read_bytes()
            (snapshots / source.name).write_bytes(data)
            digests[source.name] = hashlib.sha256(data).hexdigest()
        (args.evidence_dir / 'source-snapshot.json').write_text(json.dumps({
            'schema': 'appkit-vm-quit-source-snapshot/v1', 'main_swift_excluded': True,
            'bundled_broker_sha256': hashlib.sha256(module.read_bytes()).hexdigest(),
            'swift_files_sha256': digests,
        }, indent=2, sort_keys=True) + '\n')
        executable = fixture / 'VMQuitFixture'
        build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macosx14.0',
            '-module-name', 'VMQuitFixture',
            '-o', str(executable), *[str(snapshots / p.name) for p in files]],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=150)
        if build.returncode != 0:
            # Compiler diagnostics contain only copied source; never capture env.
            print(build.stderr)
            (args.evidence_dir / 'build-result.json').write_text(json.dumps({
                'schema': 'appkit-vm-quit-build/v1', 'compiled': False, 'exit_code': build.returncode}) + '\n')
            return build.returncode
        (args.evidence_dir / 'build-result.json').write_text(json.dumps({
            'schema': 'appkit-vm-quit-build/v1', 'compiled': True, 'production_source_mutated': False}) + '\n')
        sdk = fixture / 'sdk'
        sdk.mkdir(mode=0o700)
        marker = fixture / 'vm-marker.json'
        wrapper = r'''
import { writeFileSync, renameSync } from 'node:fs';
import { registerHooks } from 'node:module';
import { pathToFileURL } from 'node:url';
let hostSDKImports = 0;
const hooks = registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier.includes('@anthropic-ai/')) { hostSDKImports++; throw new Error('HOST_SDK_IMPORT_FORBIDDEN'); }
  return nextResolve(specifier, context);
} });
const { runVMTextChat, productionLauncher, readVMInput } = await import(pathToFileURL(MODULE_PATH).href);
const receipt = {schema:'appkit-vm-quit-marker/v1',native_init_observed:false,transport_entered:false,
  vm_stopped_observed:false,vm_cleanup_complete:false,python_child_closed:false,python_child_signal:null,
  host_key_absent_from_guest_frames:true,old_history_absent_from_guest_frames:true,
  sigterm_observed:false,real_provider_calls:false,host_sdk_import_attempts:0};
const save = () => { const partial=MARKER_PATH+'.partial'; writeFileSync(partial, JSON.stringify(receipt), {mode:0o600}); renameSync(partial, MARKER_PATH); };
const controller = new AbortController();
process.on('SIGTERM', () => { receipt.sigterm_observed=true; save(); controller.abort(); });
process.on('SIGINT', () => { receipt.sigterm_observed=true; save(); controller.abort(); });
const input = await readVMInput();
const terminal = await runVMTextChat(input, event => {
  if (event.type === 'error' || event.type === 'completed') {
    receipt.terminal_type=event.type; receipt.terminal_code=event.code ?? null;
    receipt.host_sdk_import_attempts=hostSDKImports; save();
  }
  process.stdout.write(JSON.stringify(event)+'\n');
}, {testOnly:true,signal:controller.signal,timeoutMs:40000,launch:async () => {
  const child = await productionLauncher();
  receipt.python_child_pid=child.pid;
  const write = child.stdin.write.bind(child.stdin);
  child.stdin.write = (...values) => {
    const frame=String(values[0]);
    receipt.host_key_absent_from_guest_frames &&= !frame.includes(input.apiKey);
    receipt.old_history_absent_from_guest_frames &&= !frame.includes('EARLIER_APPKIT_FIXTURE_');
    return write(...values);
  };
  let pending='';
  child.stdout.on('data', chunk => {
    pending += chunk;
    while (pending.includes('\n')) {
      const at=pending.indexOf('\n'), frame=JSON.parse(pending.slice(0,at)); pending=pending.slice(at+1);
      if (frame.kind === 'native_init') receipt.native_init_observed=true;
      if (frame.kind === 'vm_stopped') {
        receipt.vm_stopped_observed=true; receipt.vm_cleanup_complete=frame.cleanup_complete === true;
        receipt.vm_exit_code=frame.exit_code;
      }
      save();
    }
  });
  child.on('close', (code, signal) => {
    receipt.python_child_closed=true; receipt.python_child_exit_code=code; receipt.python_child_signal=signal; save();
  });
  save(); return child;
},transport:async ({signal}) => {
  receipt.transport_entered=true; save();
  await new Promise((resolve, reject) => {
    const cancel=() => reject(Object.assign(new Error('OFFLINE_TRANSPORT_ABORTED'), {code:'PROCESS_INTERRUPTED'}));
    if (signal.aborted) cancel(); else signal.addEventListener('abort', cancel, {once:true});
  });
}});
receipt.broker_run_complete=true; receipt.host_sdk_import_attempts=hostSDKImports; save();
hooks.deregister();
'''
        wrapper = wrapper.replace('MODULE_PATH', json.dumps(str(module))).replace('MARKER_PATH', json.dumps(str(marker)))
        (sdk / 'vm-text-chat.mjs').write_text(wrapper)
        config = fixture / 'fixture-config.json'
        config.write_text(json.dumps({'projectRoot': str(fixture), 'nodeExecutable': bundle_config['nodeExecutable']}))
        result = args.evidence_dir / 'result.json'
        started = time.monotonic()
        process = subprocess.Popen([str(executable), '--fixture-config', str(config), str(marker), str(result)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=48)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate(timeout=1)
            (args.evidence_dir / 'runner-result.json').write_text(json.dumps({
                'schema':'appkit-vm-quit-runner/v1','status':'overall_timeout','real_credentials_read':False,
                'real_provider_calls':False,
                'fixture_progress':[line for line in stdout.splitlines() if line.startswith('VM_QUIT_FIXTURE_')],
                'vm_receipt':json.loads(marker.read_text()) if marker.is_file() else None}) + '\n')
            return 1
        evidence = json.loads(result.read_text()) if result.is_file() else {'status':'missing_fixture_result'}
        evidence['runner_exit_code'] = process.returncode
        evidence['runner_duration_seconds'] = round(time.monotonic()-started, 3)
        (args.evidence_dir / 'runner-result.json').write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
        print(json.dumps(evidence, indent=2, sort_keys=True))
        return 0 if process.returncode == 0 and evidence.get('status') == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
