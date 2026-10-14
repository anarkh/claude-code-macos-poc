#!/usr/bin/env python3
"""Qualify one complete fake-only run; never unlock full native admission."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

HOST = Path(__file__).resolve().parent


def sha(value):
    return hashlib.sha256(value).hexdigest()


def validate(run):
    if not re.fullmatch(r'native-[0-9]+', run):
        raise ValueError('fixed native run basename required')
    paths = {name: HOST / 'evidence' / (run + suffix) for name, suffix in
             [('native', '.json'), ('gateway', '-gateway.json'),
              ('upstream', '-upstream.json'), ('chain', '-relay-chain.json')]}
    data = {k: json.loads(p.read_text()) for k, p in paths.items()}
    e, g, u, c = (data[k] for k in ('native', 'gateway', 'upstream', 'chain'))
    n = e['native_admission_fixture']
    post = e['native_postflight']['files']
    r = n['runner']; contract = r['contract']; relay = n['relay']
    records = relay['request_records']
    auth = [x for x in g['events'] if x['decision'] == 'client_authenticated']
    accepted = [x for x in g['events'] if x['decision'] == 'request_accepted']
    completed = [x for x in g['events'] if x['decision'] == 'response_completed']
    transports = [x for x in e['host_events'] if x['kind'] == 'transport_shutdown']
    joins = [x for x in contract['audit'] if x['kind'] == 'permission_join']
    raw_inputs = {name: {'size': p.stat().st_size, 'sha256': sha(p.read_bytes())} for name, p in paths.items()}
    checks = {
        'same_run': e['run'] == c['run'] == run,
        'native_main_equals_root_postflight': n == post['native-admission-summary.json']['evidence'],
        'no_nic_no_host_shares': e['assessment']['no_nic_no_shares_boot_and_normal_shutdown'] == 'passed',
        'native_and_vm_exit_zero': e['script_exit_markers']['NATIVE'] == [0] and c['vm_exit'] == 0,
        'strict_source_six_native_joins': n['strict_origin_status'] == 'passed_local_fixture' and len(joins) == len(r['permissions']) == 6 and all(x['valid'] for x in joins),
        'native_epoch_sealed': contract['state'] == 'sealed' and contract['pending_permission_count'] == contract['pending_tool_count'] == 0,
        'session_epoch_match': relay['session_id'] == r['relay_session']['session_id'] and relay['boot_epoch'] == r['relay_session']['boot_epoch'] and g['session_sha256'] == sha(relay['session_id'].encode()) and g['boot_epoch_sha256'] == sha(str(relay['boot_epoch']).encode()),
        'seven_pinned_mtls_authentications': len(auth) == 7 and all(x['client_certificate_sha256'] == g['allowed_client_sha256'] and x['tls_version'] in ('TLSv1.2', 'TLSv1.3') for x in auth),
        'seven_fixed_vsock_responses': len(records) == len(accepted) == len(completed) == g['unique_request_count'] == 7 and all(x['status'] == 'completed' and x['authenticated'] and x['transport'] == 'fixed_vsock' and x['http_status'] == 200 for x in records),
        'request_ids_join': Counter(sha(x['request_id'].encode()) for x in records) == Counter(x['request_id_sha256'] for x in accepted),
        'request_bytes_join': Counter((x['request_sha256'], x['request_bytes']) for x in records) == Counter((x['request_body_sha256'], x['request_body_bytes']) for x in accepted),
        'response_bytes_join': Counter((x['response_sha256'], x['response_bytes']) for x in records) == Counter((x['response_sha256'], x['response_bytes']) for x in completed),
        'host_replaces_auth_for_fixed_fake_upstream': len(u['requests']) == 7 and u['origin'] == 'http://127.0.0.1:41419' and all(x['provider_auth_replaced'] and x['authorization_header_absent'] for x in u['requests']),
        'host_upstream_body_join': Counter((x['request_sha256'], x['request_bytes']) for x in u['requests']) == Counter((x['request_sha256'], x['request_bytes']) for x in records),
        'no_provider_key_in_guest_payload': c['host_provider_key_absent_from_guest_payload'] is True and r['supplied_key_role'] == 'limited_boot_session_token_not_provider_key' and n['verified_subset']['work_key_is_limited_session_token'] is True,
        'protected_builtin_files': n['verified_subset']['actual_builtin_write_read_edit'] is True and n['verified_subset']['protected_fake_file_unchanged'] is True and n['verified_subset']['builtin_protected_create_absent'] is True,
        'work_domains_fd_and_boundaries': n['verified_subset']['real_native_controller_cli_work_domains'] is True and n['verified_subset']['passive_control_fd_inheritance_child_and_grandchild'] is True and n['verified_subset']['fixed_work_boundaries'] == 'passed',
        'root_scope_and_writer_stopped': n['root_stop']['events']['populated'] == '0' and n['root_stop']['writes_stable_for_3_seconds'] and n['root_stop']['observation_seconds'] >= 3 and n['root_stop']['final_writes_bytes'] > 0,
        'relay_scope_and_connections_stopped': n['relay_stop']['events']['populated'] == '0' and n['relay_stop']['exit'] == 0 and n['relay_stop']['ready_marker_removed'] and not n['relay_stop']['errors'] and relay['state'] == 'stopped' and relay['live_http_sockets'] == relay['live_gateway_sockets'] == 0,
        'host_gateway_revoked_and_closed': c['gateway_socket_removed'] and g['active_connections'] == g['active_upstreams'] == g['active_workers'] == 0 and g['stop_reason'] == 'vm_scope_finished',
        'host_transport_drained': len(transports) == 1 and transports[0]['accepted_count'] == transports[0]['closed_count'] == 7 and transports[0]['active_connections'] == transports[0]['rejected_count'] == 0 and transports[0]['guest_to_gateway_bytes'] > 0 and transports[0]['gateway_to_guest_bytes'] > 0,
        'gate_remains_closed': e['assessment']['project_execution_enabled'] is False and c['project_execution_enabled'] is False and n['admission_status'] == 'blocked_pending_full_native_security_validation',
    }
    rules = n['fixed_egress_rules']
    counters = post['egress-evidence.json']['evidence']
    counts = {x['target']: x['packets'] for x in counters['rules']}
    negative = r['fixed_egress_negative_control']
    checks['exact_uid_destination_rules_readback'] = rules['uid'] == 29998 and rules['allowed_destination'] == '127.0.0.1:41417' and '-A OUTPUT -m owner --uid-owner 29998 -j CLAUDE_POC_EGRESS' in rules['ipv4'] and '-A CLAUDE_POC_EGRESS -d 127.0.0.1/32 -p tcp -m tcp --dport 41417 -j ACCEPT' in rules['ipv4'] and '-A CLAUDE_POC_EGRESS -j REJECT --reject-with icmp-port-unreachable' in rules['ipv4'] and '-A OUTPUT -m owner --uid-owner 29998 -j REJECT --reject-with icmp6-port-unreachable' in rules['ipv6']
    checks['exact_egress_accept_and_reject_observed'] = counts.get('ACCEPT', 0) > 0 and counts.get('REJECT', 0) >= 1 and negative['rejected'] and negative['sent_application_data'] is False
    checks['original_raw_logs_unchanged'] = all((HOST / 'runs' / name).stat().st_size == pin['size'] and sha((HOST / 'runs' / name).read_bytes()) == pin['sha256'] for name, pin in e['inputs'].items())
    return {'schema': 'relay-chain-validation/v1', 'run': run, 'fixture_only': True,
            'status': 'passed_local_fixture' if all(checks.values()) else 'blocked', 'checks': checks,
            'inputs': raw_inputs, 'metrics': {'native_permission_joins': len(joins), 'mtls_requests': len(records),
            'tls_versions': sorted({x['tls_version'] for x in auth}), 'egress_packet_counts': counts,
            'root_scope_kill_ms': n['root_stop']['cgroup_kill_elapsed_ms'], 'post_stop_observation_seconds': n['root_stop']['observation_seconds'],
            'final_writer_bytes': n['root_stop']['final_writes_bytes']},
            'full_native_admission': n['admission_status'], 'project_execution_enabled': False,
            'real_provider_proxy_translation_pipeline': 'not_executed'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('run'); args = parser.parse_args()
    result = validate(args.run)
    path = HOST / 'evidence' / (args.run + '-qualified.json')
    with path.open('x') as output:
        json.dump(result, output, sort_keys=True, indent=2); output.write('\n')
    print(json.dumps({'file': str(path.relative_to(HOST)), 'status': result['status'], 'checks': len(result['checks']), 'failed': [k for k, v in result['checks'].items() if not v]}))
    raise SystemExit(0 if result['status'] == 'passed_local_fixture' else 2)
