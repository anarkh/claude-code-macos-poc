"""Local fake-only core tests; TLS over Unix sockets does not qualify VZ/vsock."""
import base64
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock
import uuid

from relay import (CONNECT_TIMEOUT, MAX_BODY, PROTOCOL, SERVER_NAME, GatewayClient,
                   RelayConfig, RelayError, RelayServer, error_diagnostic, main,
                   make_tls_context, CONFIG_PATH)

FAKE_TOKEN = 'ab' * 32
BODY = b'{"model":"fake-fixture-model","messages":[],"max_tokens":8,"stream":true}'
SSE_BLOCKS = (b'event: message_start\ndata: {"fixture":true}\n\n',
              b'event: message_stop\ndata: {}\n\n')


def certificates(directory):
    executable = shutil.which('openssl')
    if executable is None:
        raise RuntimeError('openssl fixture certificate generator unavailable')
    def run(args):
        value = subprocess.run([executable, *args], cwd=directory, capture_output=True, timeout=15)
        if value.returncode:
            raise RuntimeError('fixture certificate generation failed')
    run(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
         '-subj', '/CN=Fake Relay Fixture CA', '-keyout', 'ca.key', '-out', 'ca.pem',
         '-addext', 'basicConstraints=critical,CA:TRUE'])
    for name, subject, usage in (('server', SERVER_NAME, 'serverAuth'), ('client', 'fixture-guest', 'clientAuth')):
        run(['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=' + subject,
             '-keyout', name + '.key', '-out', name + '.csr'])
        extension = directory / (name + '.ext')
        extension.write_text('basicConstraints=CA:FALSE\nextendedKeyUsage=' + usage +
                             '\nsubjectAltName=DNS:' + subject + '\n')
        run(['x509', '-req', '-in', name + '.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
             '-CAcreateserial', '-days', '1', '-out', name + '.pem', '-extfile', name + '.ext'])


class FakeGateway:
    def __init__(self, directory, cert_directory, behavior='normal', pause=False):
        self.path = directory / 'gateway.sock'
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.path))
        self.listener.listen(8)
        self.listener.settimeout(.1)
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.verify_mode = ssl.CERT_REQUIRED
        self.context.load_verify_locations(str(cert_directory / 'ca.pem'))
        self.context.load_cert_chain(str(cert_directory / 'server.pem'), str(cert_directory / 'server.key'))
        self.behavior, self.pause = behavior, pause
        self.stop_event = threading.Event()
        self.release = threading.Event()
        self.request_received = threading.Event()
        self.peer_authenticated = threading.Event()
        self.received = []
        self.failures = []
        self.connections = []
        self.thread = threading.Thread(target=self._run, name='fake-mtls-gateway')
        self.thread.start()

    def dial(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(str(self.path))
        return sock

    @staticmethod
    def _send(sock, frame):
        sock.sendall(json.dumps(frame, separators=(',', ':')).encode() + b'\n')

    def _run(self):
        while not self.stop_event.is_set():
            try:
                raw, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if not self.stop_event.is_set():
                    self.failures.append('unexpected_listener_error')
                break
            raw.settimeout(2)
            sock = raw
            self.connections.append(raw)
            try:
                sock = self.context.wrap_socket(raw, server_side=True)
                self.connections.append(sock)
                self.peer_authenticated.set()
                reader = sock.makefile('rb')
                try:
                    hello = json.loads(reader.readline())
                    self.received.append(hello)
                    session = hello['session_id'] if self.behavior != 'bad_ready' else str(uuid.uuid4())
                    epoch = hello['boot_epoch'] if self.behavior != 'bad_epoch' else hello['boot_epoch'] - 1
                    self._send(sock, {'type': 'ready', 'protocol': PROTOCOL, 'session_id': session,
                                      'boot_epoch': epoch})
                    if self.behavior in ('bad_ready', 'bad_epoch'):
                        continue
                    request = json.loads(reader.readline())
                    self.received.append(request)
                    self.request_received.set()
                    if self.behavior == 'invalid_frame':
                        sock.sendall(b'{"type": "response_start", broken}\n')
                        continue
                    if self.behavior == 'duplicate_json_key':
                        sock.sendall(b'{"type":"response_start","type":"response_end"}\n')
                        continue
                    self._send(sock, {'type': 'response_start', 'status': 200,
                                      'headers': {'content-type': 'text/event-stream', 'request-id': 'fake-request-id'}})
                    if self.behavior == 'timeout':
                        self.release.wait(2)
                        continue
                    if self.behavior == 'oversized_chunk':
                        self._send(sock, {'type': 'response_chunk',
                                          'data_base64': base64.b64encode(b'x' * (16 * 1024 + 1)).decode()})
                        continue
                    self._send(sock, {'type': 'response_chunk', 'data_base64': base64.b64encode(SSE_BLOCKS[0]).decode()})
                    if self.pause:
                        self.release.wait(2)
                    if self.behavior == 'missing_end':
                        continue
                    self._send(sock, {'type': 'response_chunk', 'data_base64': base64.b64encode(SSE_BLOCKS[1]).decode()})
                    combined = b''.join(SSE_BLOCKS)
                    digest = hashlib.sha256(combined).hexdigest()
                    if self.behavior == 'bad_hash':
                        digest = '0' * 64
                    self._send(sock, {'type': 'response_end', 'total_bytes': len(combined), 'sha256': digest})
                finally:
                    reader.close()
            except (OSError, ValueError, KeyError):
                # Missing client cert, malformed handshakes and deliberate close are test cases.
                self.failures.append('connection_rejected_or_closed')
            finally:
                sock.close()
                raw.close()

    def stop(self):
        self.stop_event.set()
        self.release.set()
        self.listener.close()
        for connection in self.connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        self.thread.join(3)
        if self.thread.is_alive():
            raise RuntimeError('fake gateway thread did not stop')


class RelayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certificate_temp = tempfile.TemporaryDirectory(prefix='relay-certs-')
        cls.cert_directory = Path(cls.certificate_temp.name)
        certificates(cls.cert_directory)

    @classmethod
    def tearDownClass(cls):
        cls.certificate_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='relay-test-')
        self.directory = Path(self.temp.name)
        self.config = RelayConfig(session_id=str(uuid.uuid4()), boot_epoch=1760000000,
                                  client_token=FAKE_TOKEN, ca_file=self.cert_directory / 'ca.pem',
                                  client_cert=self.cert_directory / 'client.pem',
                                  client_key=self.cert_directory / 'client.key',
                                  evidence_path=self.directory / 'evidence.json', lease_seconds=30)
        self.gateway = None
        self.server = None
        self.client = None

    def tearDown(self):
        if self.server is not None:
            self.server.stop()
        if self.client is not None:
            self.client.close()
        if self.gateway is not None:
            self.gateway.stop()
        self.temp.cleanup()

    def start(self, behavior='normal', pause=False, timeout=60, context=None):
        self.gateway = FakeGateway(self.directory, self.cert_directory, behavior, pause)
        self.client = GatewayClient(self.config, dial_socket=self.gateway.dial,
                                    tls_context=context, stream_timeout=timeout)
        self.server = RelayServer(self.config, self.client, address=('127.0.0.1', 0),
                                  ready_path=self.directory / 'ready.json')
        self.server.start()

    def request(self, token=FAKE_TOKEN, path='/v1/messages?beta=true', body=BODY, headers=None):
        connection = http.client.HTTPConnection(*self.server.address, timeout=3)
        value = {'x-api-key': token, 'content-type': 'application/json', 'anthropic-version': '2023-06-01'}
        if headers:
            value.update(headers)
        connection.request('POST', path, body, value)
        response = connection.getresponse()
        return connection, response

    def records(self):
        return json.loads(self.config.evidence_path.read_text())['request_records']

    def completed_record(self):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            values = [r for r in self.records() if 'request_id' in r]
            if values:
                return values[-1]
            time.sleep(.01)
        self.fail('request evidence not persisted')

    def test_mtls_sse_is_incremental_and_auth_never_forwarded(self):
        self.start(pause=True)
        connection, response = self.request(headers={'authorization': 'Bearer FAKE-DO-NOT-FORWARD',
                                                      'x-extra-secret': 'FAKE-EXTRA'})
        self.assertEqual(response.status, 200)
        self.assertIsNone(response.getheader('content-length'))
        first = response.read(len(SSE_BLOCKS[0]))
        self.assertEqual(first, SSE_BLOCKS[0])
        self.assertFalse(self.gateway.release.is_set())
        self.gateway.release.set()
        self.assertEqual(response.read(), SSE_BLOCKS[1])
        connection.close()
        evidence = self.completed_record()
        self.assertEqual(evidence['status'], 'completed')
        self.assertEqual(evidence['transport'], 'injected_transport')
        self.assertIn(evidence['tls_version'], ('TLSv1.2', 'TLSv1.3'))
        self.assertTrue(self.gateway.peer_authenticated.is_set())
        request = self.gateway.received[1]
        self.assertEqual(set(request['headers']), {'content-type', 'anthropic-version'})
        self.assertEqual(base64.b64decode(request['body_base64']), BODY)
        wire = json.dumps(self.gateway.received)
        self.assertNotIn(FAKE_TOKEN, wire)
        self.assertNotIn('DO-NOT-FORWARD', wire)
        self.assertNotIn('FAKE-EXTRA', wire)
        evidence_text = self.config.evidence_path.read_text()
        self.assertNotIn(FAKE_TOKEN, evidence_text)
        self.assertNotIn('fake-fixture-model', evidence_text)
        self.assertNotIn('BEGIN PRIVATE KEY', evidence_text)

    def test_bad_or_missing_token_never_dials_gateway(self):
        self.start()
        connection, response = self.request(token='wrong-token')
        self.assertEqual(response.status, 401)
        response.read()
        connection.close()
        self.assertFalse(self.gateway.peer_authenticated.is_set())
        deadline = time.monotonic() + 2
        while not self.records() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.records()[-1]['authenticated'], False)
        connection = http.client.HTTPConnection(*self.server.address, timeout=3)
        connection.request('POST', '/v1/messages', BODY, {'content-type': 'application/json'})
        response = connection.getresponse()
        self.assertEqual(response.status, 401)
        response.read()
        connection.close()

    def test_request_method_path_json_and_size_rejected(self):
        self.start()
        for path, body, status in (('/v1/unknown', BODY, 404), ('/v1/messages', b'not-json', 400),
                                   ('/v1/messages', b'{"x":1,"x":2}', 400)):
            with self.subTest(status=status, path=path, size=len(body)):
                connection, response = self.request(path=path, body=body)
                self.assertEqual(response.status, status)
                response.read()
                connection.close()
        # Reject the declared size before uploading a body, rather than relying
        # on a client's sendall race against the server closing its connection.
        connection = http.client.HTTPConnection(*self.server.address, timeout=3)
        connection.putrequest('POST', '/v1/messages')
        connection.putheader('x-api-key', FAKE_TOKEN)
        connection.putheader('content-type', 'application/json')
        connection.putheader('content-length', str(MAX_BODY + 1))
        connection.endheaders()
        response = connection.getresponse()
        self.assertEqual(response.status, 413)
        response.read()
        connection.close()
        connection = http.client.HTTPConnection(*self.server.address, timeout=3)
        connection.request('GET', '/v1/messages')
        response = connection.getresponse()
        self.assertEqual(response.status, 405)
        response.read()
        connection.close()
        self.assertFalse(self.gateway.peer_authenticated.is_set())

    def test_duplicate_content_length_chunked_and_duplicate_token_rejected(self):
        self.start()
        extras = [b'Content-Length: 2\r\nContent-Length: 2\r\n',
                  b'Transfer-Encoding: chunked\r\nContent-Length: 2\r\n',
                  ('X-Api-Key: ' + FAKE_TOKEN + '\r\nContent-Length: 2\r\n').encode()]
        for extra in extras:
            with self.subTest(extra_kind=extra.split(b':', 1)[0]):
                sock = socket.create_connection(self.server.address, timeout=3)
                sock.sendall(('POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nX-Api-Key: ' + FAKE_TOKEN +
                              '\r\nContent-Type: application/json\r\n').encode() + extra + b'\r\n{}')
                raw = sock.recv(4096)
                self.assertTrue(raw.startswith((b'HTTP/1.1 400 ', b'HTTP/1.1 401 ')))
                sock.close()
        self.assertFalse(self.gateway.peer_authenticated.is_set())

    def test_bad_hash_and_missing_end_are_truncated(self):
        for behavior, expected in (('bad_hash', 'response_digest_mismatch'), ('missing_end', 'upstream_truncated')):
            with self.subTest(behavior=behavior):
                self.start(behavior=behavior)
                connection, response = self.request()
                self.assertEqual(response.status, 200)
                self.assertTrue(response.read().startswith(SSE_BLOCKS[0]))
                connection.close()
                evidence = self.completed_record()
                self.assertEqual(evidence['status'], 'truncated')
                self.assertEqual(evidence['error_code'], expected)
                self.server.stop()
                self.gateway.stop()
                self.temp.cleanup()
                self.setUp()

    def test_invalid_frame_duplicate_key_and_bad_ready_reject(self):
        for behavior in ('invalid_frame', 'duplicate_json_key', 'bad_ready', 'bad_epoch'):
            with self.subTest(behavior=behavior):
                self.start(behavior=behavior)
                connection, response = self.request()
                self.assertEqual(response.status, 502)
                response.read()
                connection.close()
                self.assertEqual(self.completed_record()['status'], 'rejected')
                self.server.stop()
                self.gateway.stop()
                self.temp.cleanup()
                self.setUp()

    def test_stream_timeout_and_oversized_chunk_never_complete(self):
        for behavior in ('timeout', 'oversized_chunk'):
            with self.subTest(behavior=behavior):
                self.start(behavior=behavior, timeout=.15)
                connection, response = self.request()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), b'')
                connection.close()
                evidence = self.completed_record()
                self.assertEqual(evidence['status'], 'truncated')
                self.assertEqual(evidence['error_code'], 'stream_timeout' if behavior == 'timeout' else 'response_body_limit')
                self.server.stop()
                self.gateway.stop()
                self.temp.cleanup()
                self.setUp()

    def test_mtls_client_certificate_required(self):
        context = ssl.create_default_context(cafile=str(self.config.ca_file))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.start(context=context)
        connection, response = self.request()
        self.assertEqual(response.status, 502)
        response.read()
        connection.close()
        self.assertFalse(self.gateway.peer_authenticated.is_set())
        self.assertEqual(self.completed_record()['status'], 'rejected')

    def test_hostname_verification_required(self):
        context = make_tls_context(self.config)
        wrong_name_config = RelayConfig(**{**self.config.__dict__, 'server_hostname': 'wrong-fixture-host'})
        self.gateway = FakeGateway(self.directory, self.cert_directory)
        self.client = GatewayClient(wrong_name_config, dial_socket=self.gateway.dial, tls_context=context)
        record = self.client.forward('POST', '/v1/messages', {'content-type': 'application/json'}, BODY,
                                     lambda *_: self.fail('unexpected response'), lambda *_: self.fail('unexpected data'))
        self.assertEqual(record['status'], 'rejected')
        self.assertEqual(record['error_code'], 'transport_error')

    def test_client_disconnect_cancels_active_stream(self):
        self.start(behavior='timeout', timeout=3)
        connection, response = self.request()
        self.assertEqual(response.status, 200)
        response.close()
        connection.close()
        evidence = self.completed_record()
        self.assertEqual(evidence['status'], 'truncated')
        self.assertEqual(evidence['error_code'], 'client_disconnected')
        self.assertEqual(self.client.active_count(), 0)

    def test_stop_cleans_active_connections_ready_and_threads(self):
        self.start(behavior='timeout', timeout=3)
        connection, response = self.request()
        self.assertEqual(response.status, 200)
        self.assertTrue(self.gateway.request_received.wait(2))
        ready = json.loads((self.directory / 'ready.json').read_text())
        self.assertEqual(ready, {'ready': True, 'session_id': self.config.session_id, 'boot_epoch': self.config.boot_epoch})
        self.assertEqual(stat.S_IMODE((self.directory / 'ready.json').stat().st_mode), 0o600)
        before = time.monotonic()
        self.server.stop()
        self.assertLess(time.monotonic() - before, 2)
        self.assertFalse((self.directory / 'ready.json').exists())
        self.assertFalse(self.server._thread.is_alive())
        self.assertEqual(self.client.active_count(), 0)
        evidence = json.loads(self.config.evidence_path.read_text())
        self.assertEqual(evidence['state'], 'stopped')
        self.assertEqual(evidence['live_http_sockets'], 0)
        self.assertEqual(evidence['live_gateway_sockets'], 0)
        response.close()
        connection.close()

    def test_existing_ready_file_is_never_replaced(self):
        self.gateway = FakeGateway(self.directory, self.cert_directory)
        self.client = GatewayClient(self.config, dial_socket=self.gateway.dial)
        path = self.directory / 'ready.json'
        path.write_text('prior-run')
        with self.assertRaisesRegex(RelayError, 'fresh_relay_state_required'):
            RelayServer(self.config, self.client, address=('127.0.0.1', 0), ready_path=path)
        self.assertEqual(path.read_text(), 'prior-run')

    def test_fixed_config_rejects_endpoint_changes_and_redacts_repr(self):
        mapping = {'schema': 'guest-relay-fixture/v1', 'session_id': self.config.session_id,
                   'boot_epoch': self.config.boot_epoch, 'client_token': FAKE_TOKEN,
                   'ca_file': '/etc/claude-code-poc/relay/ca.pem',
                   'client_cert': '/etc/claude-code-poc/relay/client.pem',
                   'client_key': '/etc/claude-code-poc/relay/client.key',
                   'evidence_path': '/var/lib/claude-code-native-poc/relay-evidence.json',
                   'server_hostname': SERVER_NAME, 'vsock_cid': 2, 'vsock_port': 40123,
                   'listen_host': '127.0.0.1', 'listen_port': 41417, 'lease_seconds': 600}
        self.assertNotIn(FAKE_TOKEN, repr(RelayConfig.from_mapping(mapping)))
        for name, value in (('vsock_cid', 3), ('vsock_port', 40124), ('listen_host', '0.0.0.0'),
                            ('lease_seconds', 601), ('boot_epoch', True), ('client_token', 'bad'),
                            ('evidence_path', '/tmp/relay.json')):
            with self.subTest(field=name):
                with self.assertRaises(RelayError):
                    RelayConfig.from_mapping({**mapping, name: value})

    def test_stage_diagnostic_is_actionable_and_never_copies_exception_text(self):
        sensitive = 'SECRET-TOKEN-AND-PRIVATE-PATH'
        def fail_config(path=CONFIG_PATH, on_stage=None):
            on_stage('client_key_metadata')
            raise PermissionError(13, sensitive)
        output = io.StringIO()
        with mock.patch('relay.guest_preflight', return_value=None), \
                mock.patch('relay.load_fixed_config', side_effect=fail_config), \
                mock.patch('sys.stderr', output):
            self.assertEqual(main([str(CONFIG_PATH)]), 2)
        record = json.loads(output.getvalue())
        self.assertEqual(record['stage'], 'client_key_metadata')
        self.assertEqual(record['error_type'], 'PermissionError')
        self.assertEqual(record['errno'], 13)
        self.assertNotIn(sensitive, output.getvalue())
        error = ssl.SSLError(1, sensitive)
        error.reason = 'PEM_LIB'
        self.assertEqual(error_diagnostic('tls_client_chain_load', error)['ssl_reason'], 'PEM_LIB')
        error.reason = sensitive + '/private.key'
        record = error_diagnostic('tls_client_chain_load', error)
        self.assertIsNone(record['ssl_reason'])
        self.assertNotIn(sensitive, json.dumps(record))


if __name__ == '__main__':
    unittest.main(verbosity=2)
