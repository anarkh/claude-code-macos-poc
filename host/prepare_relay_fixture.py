#!/usr/bin/env python3
"""Create one disposable fake-only relay identity; never import user credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import tempfile
import time
import uuid

HOST = Path(__file__).resolve().parent
PROVIDER_KEY = 'host-only-FAKE-provider-NOT-VALID'


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        output.write(value)


def prepare(run):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,47}', run):
        raise ValueError('new lowercase fixture run name required')
    (HOST / 'runs').mkdir(exist_ok=True)
    context_path = HOST / 'runs' / (run + '.relay-context.json')
    if context_path.exists():
        raise ValueError('relay run context already exists')
    directory = Path(tempfile.mkdtemp(prefix='ccr-' + run + '-', dir='/private/tmp'))
    os.chmod(directory, 0o700)
    session = str(uuid.uuid4())
    epoch = int(time.time())
    token = secrets.token_hex(32)
    def openssl(*args):
        result = subprocess.run(['/usr/bin/openssl', *args], cwd=directory,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError('fixture PKI generation failed at ' + args[0])
    for name in ('ca', 'server', 'client'):
        openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', name + '.key')
        os.chmod(directory / (name + '.key'), 0o600)
    write_private(directory / 'ca.cnf', '[req]\ndistinguished_name=dn\n[dn]\nCN=Fixture\n'
                  '[ca_ext]\nbasicConstraints=critical,CA:TRUE,pathlen:0\n'
                  'keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n')
    openssl('req', '-new', '-x509', '-sha256', '-key', 'ca.key', '-days', '1',
            '-config', 'ca.cnf', '-extensions', 'ca_ext',
            '-subj', '/CN=Claude-Code-Disposable-PoC-CA', '-out', 'ca.pem')
    for name, cn, usage in [('server', 'claude-code-host-gateway', 'serverAuth'),
                            ('client', 'claude-code-guest-relay', 'clientAuth')]:
        write_private(directory / (name + '.ext'),
                      'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
                      'extendedKeyUsage=' + usage + '\nsubjectAltName=DNS:' + cn + '\n')
        openssl('req', '-new', '-sha256', '-key', name + '.key', '-subj', '/CN=' + cn, '-out', name + '.csr')
        openssl('x509', '-req', '-sha256', '-in', name + '.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
                '-set_serial', str(secrets.randbits(120) + 1), '-days', '1',
                '-extfile', name + '.ext', '-out', name + '.pem')
    for file in directory.iterdir():
        os.chmod(file, 0o600)
    fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert((directory / 'client.pem').read_text())).hexdigest()
    common = {'session_id': session, 'boot_epoch': epoch, 'lease_seconds': 600}
    gateway = {'schema': 'gateway-fixture/v1', **common,
               'socket_path': str(directory / 'gateway.sock'),
               'ca_file': str(directory / 'ca.pem'), 'server_cert': str(directory / 'server.pem'),
               'server_key': str(directory / 'server.key'), 'allowed_client_sha256': fingerprint,
               'upstream_origin': 'http://127.0.0.1:41419', 'provider_key': PROVIDER_KEY,
               'model_allowlist': ['claude-sonnet-4-6'],
               'evidence_path': str(HOST / 'evidence' / (run + '-gateway.json'))}
    transport = {'schema': 'vsock-transport-fixture/v1', 'gateway_socket_path': gateway['socket_path'],
                 'vsock_port': 40123, 'session_id': session, 'boot_epoch': epoch}
    guest = {'schema': 'guest-relay-fixture/v1', **common, 'client_token': token,
             'ca_file': '/etc/claude-code-poc/relay/ca.pem',
             'client_cert': '/etc/claude-code-poc/relay/client.pem',
             'client_key': '/etc/claude-code-poc/relay/client.key',
             'evidence_path': '/var/lib/claude-code-native-poc/relay-evidence.json',
             'server_hostname': 'claude-code-host-gateway', 'vsock_cid': 2, 'vsock_port': 40123,
             'listen_host': '127.0.0.1', 'listen_port': 41417}
    for name, config in [('config.json', gateway), ('transport.json', transport), ('guest-relay.json', guest)]:
        write_private(directory / name, json.dumps(config, sort_keys=True, indent=2) + '\n')
    write_private(context_path, json.dumps({'schema': 'relay-run-context/v1', 'private_directory': str(directory)}) + '\n')
    return directory


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('run')
    args = parser.parse_args()
    directory = prepare(args.run)
    print(json.dumps({'kind': 'relay_fixture_prepared', 'run': args.run,
                      'private_directory': str(directory), 'credentials': 'disposable_fake_only'}))
