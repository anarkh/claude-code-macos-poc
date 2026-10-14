#!/usr/bin/env python3
"""Extract bounded, fake-only PoC evidence without promoting missing tests to pass."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def section(text, name):
    start, end = 'POC_' + name + '_BEGIN', 'POC_' + name + '_END'
    starts = list(re.finditer(r'(?m)^' + re.escape(start) + r'[ \t]*$', text))
    ends = list(re.finditer(r'(?m)^' + re.escape(end) + r'[ \t]*$', text))
    if len(starts) != 1 or len(ends) != 1 or ends[0].start() <= starts[0].end():
        return {'status': 'unavailable', 'reason': 'expected one complete ' + name + ' marker pair'}
    value = text[starts[0].end():ends[0].start()].strip()
    decoder = json.JSONDecoder()
    candidates = []
    cursor = 0
    while (start_index := value.find('{', cursor)) >= 0:
        try:
            obj, consumed = decoder.raw_decode(value[start_index:])
        except json.JSONDecodeError:
            cursor = start_index + 1
            continue
        # Nested evidence schemas belong to this object, not another result.
        cursor = start_index + consumed
        if isinstance(obj, dict) and ('schema' in obj or obj.get('kind') == 'guest_boot_diagnostic'):
            candidates.append(obj)
    if len(candidates) != 1:
        return {'status': 'blocked', 'reason': 'expected one complete evidence JSON object',
                'candidate_count': len(candidates), 'diagnostic_tail': value[-2500:]}
    return candidates[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('run', help='run basename under host/runs, e.g. combined-02')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9-]+', args.run):
        parser.error('run must be a fixed basename')
    serial = ROOT / 'runs' / (args.run + '.serial.log')
    host = ROOT / 'runs' / (args.run + '.host.jsonl')
    text = ANSI.sub('', serial.read_text()).replace('\r', '')
    events = [json.loads(line) for line in host.read_text().splitlines() if line.strip()]
    configs = [e for e in events if e.get('kind') == 'vm_config_validated']
    host_pass = len(configs) == 1 and configs[0].get('nic_count') == 0 and configs[0].get('host_directory_shares') == 0
    host_pass = host_pass and any(e.get('kind') == 'vm_started' for e in events) and any(e.get('kind') == 'guest_stopped' for e in events)
    diagnostic, guest, sdk = (section(text, name) for name in ('DIAGNOSTIC', 'GUEST', 'LINUX_SDK_SUMMARY'))
    native = section(text, 'NATIVE')
    native_preflights = []
    for line in text.splitlines():
        if not line.startswith('{'):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get('kind') == 'native_preflight':
            native_preflights.append(value)
    exits = {name: [int(x) for x in re.findall('POC_' + name + '_EXIT=(-?[0-9]+)', text)]
             for name in ('BOOTSTRAP', 'LINUX_SDK', 'NATIVE')}
    loopback_only = diagnostic.get('network_interfaces') == ['lo']
    evidence = {
        'schema': 'claude-code-macos-poc/combined-v1',
        'generated_at_host': datetime.now(timezone.utc).isoformat(),
        'data_classification': 'fake_only', 'run': args.run,
        'inputs': {p.name: {'sha256': digest(p), 'size': p.stat().st_size} for p in (serial, host)},
        'host_events': events, 'guest_boot_diagnostic': diagnostic, 'guest_toy_harness': guest,
        'linux_native_sdk': sdk, 'script_exit_markers': exits,
        'native_admission_fixture': native,
        'native_postflight': section(text, 'NATIVE_POST'),
        'native_install_preflight': native_preflights[0] if len(native_preflights) == 1 else {'status': 'unavailable', 'count': len(native_preflights)},
        'assessment': {
            'no_nic_no_shares_boot_and_normal_shutdown': 'passed' if host_pass and loopback_only else 'blocked_or_incomplete',
            'guest_toy_harness': guest.get('status', 'unavailable'),
            'linux_native_source_contract': native.get('strict_origin_status', sdk.get('conclusion', {}).get('status', 'unavailable')),
            'project_execution_enabled': False,
            'native_cli_apparmor_cgroup_admission': native.get('admission_status', native.get('status', 'not_executed')),
            'native_verified_subset': native.get('verified_subset', {}),
            'vsock_relay_proxy_translation_real_api': 'not_executed',
            'guest_clock_synchronization': 'not_verified',
            'boundary': 'Kernel toy, legacy native protocol, and native admission runs are separate. Only explicitly recorded native checks carry native scope; incomplete admission never enables project execution.'
        }
    }
    out = ROOT / 'evidence'
    out.mkdir(exist_ok=True)
    target = out / (args.run + '.json')
    if target.exists():
        raise RuntimeError('refusing to replace an existing extracted evidence file')
    target.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'file': str(target.relative_to(ROOT.parent)), 'assessment': evidence['assessment']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
