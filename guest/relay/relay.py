"""Root-owned, fake-fixture guest HTTP -> authenticated TLS/vsock relay.

Core transport injection is for offline tests. Only main() enforces installed
guest paths, root identity, no NIC and the dedicated AppArmor profile.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import http.server
import json
import os
from pathlib import Path
import platform
import re
import select
import signal
import socket
import socketserver
import ssl
import stat
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from typing import Callable

CONFIG_PATH = Path('/etc/claude-code-poc/relay.json')
INSTALL_PATH = Path('/opt/claude-code-poc/relay/relay.py')
EVIDENCE_PATH = Path('/var/lib/claude-code-native-poc/relay-evidence.json')
READY_PATH = Path('/var/lib/claude-code-native-poc/relay-ready.json')
SERVER_NAME = 'claude-code-host-gateway'
PROTOCOL = 'cc-relay/v1'
MAX_BODY = 3 * 1024 * 1024
MAX_FRAME = 4_200_000
MAX_CHUNK = 16 * 1024
MAX_RESPONSE = 16 * 1024 * 1024
CONNECT_TIMEOUT = 8.0
STREAM_TIMEOUT = 60.0
PATHS = frozenset(('/v1/messages', '/v1/messages?beta=true',
                   '/v1/messages/count_tokens', '/v1/messages/count_tokens?beta=true'))
REQUEST_HEADERS = frozenset(('content-type', 'anthropic-version', 'anthropic-beta'))
CONFIG_FIELDS = frozenset(('schema', 'session_id', 'boot_epoch', 'client_token',
                           'ca_file', 'client_cert', 'client_key', 'evidence_path',
                           'server_hostname', 'vsock_cid', 'vsock_port',
                           'listen_host', 'listen_port', 'lease_seconds'))
DIAGNOSTIC_STAGES = frozenset(('arguments', 'guest_preflight', 'config_load',
                              'config_metadata', 'config_read', 'config_validate',
                              'ca_metadata', 'client_cert_metadata', 'client_key_metadata',
                              'tls_context', 'tls_client_chain_load', 'gateway_client',
                              'relay_state_check', 'server_bind', 'ready_publish',
                              'evidence_publish', 'signal_setup', 'start', 'running',
                              'stop', 'cleanup_stop'))


class RelayError(Exception):
    """Public error code contains no raw remote/client content."""

    def __init__(self, code: str):
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,63}', code):
            raise ValueError('invalid relay error code')
        self.code = code
        super().__init__(code)


def error_diagnostic(stage, exc):
    """Return fixed, actionable fields without copying exception text or paths."""
    if stage not in DIAGNOSTIC_STAGES:
        raise ValueError('invalid relay diagnostic stage')
    error_type = type(exc).__name__
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,79}', error_type):
        error_type = 'UnclassifiedError'
    value = {'schema': 'guest-relay-diagnostic/v1', 'kind': 'guest_relay_diagnostic',
             'stage': stage, 'error_type': error_type,
             'error_code': exc.code if isinstance(exc, RelayError) else 'operation_failed'}
    errno = getattr(exc, 'errno', None)
    value['errno'] = errno if _integer(errno, 0, 4095) else None
    reason = getattr(exc, 'reason', None)
    value['ssl_reason'] = reason if isinstance(reason, str) and re.fullmatch(r'[A-Z][A-Z0-9_]{0,79}', reason) else None
    verify_code = getattr(exc, 'verify_code', None)
    if _integer(verify_code, 0, 4095):
        value['ssl_verify_code'] = verify_code
    return value


def _emit_diagnostic(stage, exc):
    print(json.dumps(error_diagnostic(stage, exc), sort_keys=True), file=sys.stderr, flush=True)


def _integer(value, minimum, maximum):
    return isinstance(value, int) and not isinstance(value, bool) and minimum <= value <= maximum


def _sha(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def _json_object(raw, error='invalid_json'):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise RelayError(error)
            result[key] = value
        return result
    try:
        value = json.loads(raw, object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(RelayError(error)))
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise RelayError(error) from exc
    if not isinstance(value, dict):
        raise RelayError(error)
    return value


@dataclass(frozen=True, repr=False)
class RelayConfig:
    session_id: str
    boot_epoch: int
    client_token: str
    ca_file: Path
    client_cert: Path
    client_key: Path
    evidence_path: Path
    lease_seconds: int
    server_hostname: str = SERVER_NAME
    vsock_cid: int = 2
    vsock_port: int = 40123
    listen_host: str = '127.0.0.1'
    listen_port: int = 41417

    @classmethod
    def from_mapping(cls, value):
        if set(value) != CONFIG_FIELDS or value.get('schema') != 'guest-relay-fixture/v1':
            raise RelayError('config_schema')
        try:
            session = value['session_id']
            if not isinstance(session, str) or str(uuid.UUID(session)) != session:
                raise RelayError('config_session')
        except (ValueError, AttributeError) as exc:
            raise RelayError('config_session') from exc
        if not _integer(value['boot_epoch'], 1, 2**63 - 1):
            raise RelayError('config_boot_epoch')
        if not _sha(value['client_token']):
            raise RelayError('config_token')
        if not _integer(value['lease_seconds'], 1, 600):
            raise RelayError('config_lease')
        fixed = {'server_hostname': SERVER_NAME, 'vsock_cid': 2, 'vsock_port': 40123,
                 'listen_host': '127.0.0.1', 'listen_port': 41417,
                 'ca_file': '/etc/claude-code-poc/relay/ca.pem',
                 'client_cert': '/etc/claude-code-poc/relay/client.pem',
                 'client_key': '/etc/claude-code-poc/relay/client.key',
                 'evidence_path': str(EVIDENCE_PATH)}
        if any(value[k] != expected for k, expected in fixed.items()):
            raise RelayError('config_fixed_endpoint')
        return cls(session_id=session, boot_epoch=value['boot_epoch'],
                   client_token=value['client_token'], ca_file=Path(value['ca_file']),
                   client_cert=Path(value['client_cert']), client_key=Path(value['client_key']),
                   evidence_path=Path(value['evidence_path']), lease_seconds=value['lease_seconds'])


def _owned_file(path: Path, mode=None):
    # Validate each fixed path component: no symlink at any depth.
    for component in (path, *path.parents):
        info = component.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RelayError('file_ownership')
        if component == path:
            if not stat.S_ISREG(info.st_mode) or (mode is not None and stat.S_IMODE(info.st_mode) != mode):
                raise RelayError('file_mode')


def load_fixed_config(path=CONFIG_PATH, on_stage=None):
    stage = on_stage or (lambda _: None)
    if Path(path) != CONFIG_PATH:
        raise RelayError('config_fixed_path')
    stage('config_metadata')
    _owned_file(CONFIG_PATH, 0o600)
    stage('config_read')
    if CONFIG_PATH.stat().st_size > 8192:
        raise RelayError('config_size')
    raw = CONFIG_PATH.read_bytes()
    stage('config_validate')
    config = RelayConfig.from_mapping(_json_object(raw, 'config_json'))
    stage('ca_metadata')
    _owned_file(config.ca_file)
    stage('client_cert_metadata')
    _owned_file(config.client_cert)
    stage('client_key_metadata')
    _owned_file(config.client_key, 0o600)
    return config


def guest_preflight():
    if platform.system() != 'Linux' or os.geteuid() != 0 or Path(__file__).resolve() != INSTALL_PATH:
        raise RelayError('fixed_linux_root_required')
    if sorted(p.name for p in Path('/sys/class/net').iterdir()) != ['lo']:
        raise RelayError('unexpected_network_interface')
    if Path('/proc/self/attr/current').read_text().strip() != 'claude-native-relay (enforce)':
        raise RelayError('relay_profile_required')
    if ' - virtiofs ' in Path('/proc/self/mountinfo').read_text() or ' - 9p ' in Path('/proc/self/mountinfo').read_text():
        raise RelayError('host_mount_present')
    _owned_file(INSTALL_PATH)
    marker = Path('/etc/claude-code-poc/isolated-test-vm.json')
    _owned_file(marker, 0o600)
    value = _json_object(marker.read_bytes(), 'fixture_marker')
    if value.get('vm_id') != 'vm-poc-001' or any(value.get(k) is not True for k in
            ('isolated_test_vm', 'fake_data_only', 'no_host_mounts')):
        raise RelayError('fixture_marker')
    parent = EVIDENCE_PATH.parent
    info = parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise RelayError('evidence_parent')


def make_tls_context(config: RelayConfig, on_stage=None):
    stage = on_stage or (lambda _: None)
    stage('tls_context')
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=str(config.ca_file))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    stage('tls_client_chain_load')
    context.load_cert_chain(str(config.client_cert), str(config.client_key))
    return context


def dial_vsock(config: RelayConfig):
    sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect((config.vsock_cid, config.vsock_port))
        return sock
    except BaseException:
        sock.close()
        raise


class _FrameReader:
    def __init__(self, sock, deadline, cancel):
        self.sock, self.deadline, self.cancel = sock, deadline, cancel
        self.buffer = bytearray()

    def read(self):
        while True:
            if self.cancel():
                raise RelayError('client_disconnected')
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise RelayError('stream_timeout')
            newline = self.buffer.find(b'\n')
            if newline >= 0:
                if newline + 1 > MAX_FRAME:
                    raise RelayError('frame_too_large')
                raw = bytes(self.buffer[:newline])
                del self.buffer[:newline + 1]
                return _json_object(raw, 'invalid_frame')
            if len(self.buffer) >= MAX_FRAME:
                raise RelayError('frame_too_large')
            pending = self.sock.pending() if isinstance(self.sock, ssl.SSLSocket) else 0
            if not pending and not select.select([self.sock], [], [], min(.1, remaining))[0]:
                continue
            self.sock.settimeout(remaining)
            try:
                block = self.sock.recv(16 * 1024)
            except (ssl.SSLWantReadError, BlockingIOError):
                continue
            except socket.timeout as exc:
                raise RelayError('stream_timeout') from exc
            if not block:
                raise RelayError('upstream_truncated')
            self.buffer.extend(block)


def _send_frame(sock, value, deadline):
    raw = json.dumps(value, separators=(',', ':'), allow_nan=False).encode() + b'\n'
    if len(raw) > MAX_FRAME:
        raise RelayError('frame_too_large')
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RelayError('stream_timeout')
    sock.settimeout(remaining)
    sock.sendall(raw)


def _response_headers(value):
    if not isinstance(value, dict) or len(value) > 32:
        raise RelayError('invalid_response_headers')
    result = {}
    for name, text in value.items():
        if not isinstance(name, str) or not isinstance(text, str) or len(name) > 80 or len(text) > 4096:
            raise RelayError('invalid_response_headers')
        if not re.fullmatch(r'[a-z0-9-]+', name) or '\r' in text or '\n' in text:
            raise RelayError('invalid_response_headers')
        if name in ('content-type', 'request-id', 'x-request-id', 'retry-after') or name.startswith('anthropic-ratelimit-'):
            result[name] = text
        elif name in ('connection', 'content-length', 'transfer-encoding', 'trailer', 'upgrade'):
            raise RelayError('invalid_response_headers')
        else:
            raise RelayError('invalid_response_headers')
    return result


class GatewayClient:
    def __init__(self, config: RelayConfig, dial_socket=None, tls_context=None,
                 stream_timeout=STREAM_TIMEOUT):
        self.config = config
        self._is_vsock = dial_socket is None
        self.dial_socket = dial_socket or (lambda: dial_vsock(config))
        self.context = tls_context if tls_context is not None else make_tls_context(config)
        self.stream_timeout = stream_timeout
        self._lock = threading.Lock()
        self._sockets = set()
        self._closed = threading.Event()

    def _register(self, sock):
        with self._lock:
            if self._closed.is_set():
                sock.close()
                raise RelayError('relay_stopping')
            self._sockets.add(sock)

    def active_count(self):
        with self._lock:
            return len(self._sockets)

    def close(self):
        self._closed.set()
        with self._lock:
            sockets = list(self._sockets)
        for sock in sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass  # Closing an already-disconnected managed socket is expected.
            sock.close()

    def forward(self, method, path, headers, body, on_start, on_chunk, cancel=lambda: False):
        if method != 'POST' or path not in PATHS or set(headers) - REQUEST_HEADERS:
            raise RelayError('invalid_forward_request')
        if not isinstance(body, bytes) or len(body) > MAX_BODY:
            raise RelayError('request_body_limit')
        request_id = str(uuid.uuid4())
        evidence = {'request_id': request_id, 'request_bytes': len(body),
                    'request_sha256': hashlib.sha256(body).hexdigest(), 'response_started': False,
                    'response_bytes': 0, 'status': 'pending'}
        # Evidence labels are explicit and do not infer AF_VSOCK from socketpair tests.
        evidence['transport'] = 'fixed_vsock' if self._default_transport else 'injected_transport'
        sock = None
        sha = hashlib.sha256()
        total = 0
        started = False
        try:
            if cancel() or self._closed.is_set():
                raise RelayError('client_disconnected')
            connect_deadline = time.monotonic() + CONNECT_TIMEOUT
            sock = self.dial_socket()
            remaining = connect_deadline - time.monotonic()
            if remaining <= 0:
                raise RelayError('connect_timeout')
            sock.settimeout(remaining)
            self._register(sock)
            raw_sock = sock
            try:
                sock = self.context.wrap_socket(raw_sock, server_hostname=self.config.server_hostname)
            finally:
                with self._lock:
                    self._sockets.discard(raw_sock)
            self._register(sock)
            if isinstance(sock, ssl.SSLSocket):
                evidence['tls_version'] = sock.version()
            deadline = time.monotonic() + self.stream_timeout
            reader = _FrameReader(sock, deadline, lambda: cancel() or self._closed.is_set())
            _send_frame(sock, {'type': 'hello', 'protocol': PROTOCOL,
                              'session_id': self.config.session_id, 'boot_epoch': self.config.boot_epoch,
                              'role': 'proxy'}, deadline)
            ready = reader.read()
            if not _integer(ready.get('boot_epoch'), 1, 2**63 - 1) or ready != {'type': 'ready', 'protocol': PROTOCOL, 'session_id': self.config.session_id,
                         'boot_epoch': self.config.boot_epoch}:
                raise RelayError('invalid_ready')
            _send_frame(sock, {'type': 'request', 'request_id': request_id, 'method': method,
                              'path': path, 'headers': headers,
                              'body_base64': base64.b64encode(body).decode('ascii')}, deadline)
            while True:
                frame = reader.read()
                kind = frame.get('type')
                if kind == 'response_start':
                    if started or set(frame) != {'type', 'status', 'headers'} or not _integer(frame['status'], 200, 599):
                        raise RelayError('invalid_response_start')
                    response_headers = _response_headers(frame['headers'])
                    on_start(frame['status'], response_headers)
                    started = True
                    evidence['response_started'] = True
                    evidence['http_status'] = frame['status']
                elif kind == 'response_chunk':
                    if not started or set(frame) != {'type', 'data_base64'} or not isinstance(frame['data_base64'], str):
                        raise RelayError('invalid_response_chunk')
                    try:
                        block = base64.b64decode(frame['data_base64'], validate=True)
                    except (ValueError, binascii.Error) as exc:
                        raise RelayError('invalid_response_chunk') from exc
                    if not block or len(block) > MAX_CHUNK or total + len(block) > MAX_RESPONSE:
                        raise RelayError('response_body_limit')
                    on_chunk(block)
                    sha.update(block)
                    total += len(block)
                elif kind == 'response_end':
                    if not started or set(frame) != {'type', 'total_bytes', 'sha256'} or not _integer(frame['total_bytes'], 0, MAX_RESPONSE) or not _sha(frame['sha256']):
                        raise RelayError('invalid_response_end')
                    if total != frame['total_bytes'] or not hmac.compare_digest(sha.hexdigest(), frame['sha256']):
                        raise RelayError('response_digest_mismatch')
                    evidence['status'] = 'completed'
                    break
                elif kind == 'error':
                    # Do not copy arbitrary remote error data into evidence or HTTP.
                    raise RelayError('gateway_error')
                else:
                    raise RelayError('invalid_frame')
        except RelayError as exc:
            evidence.update(status='truncated' if started else 'rejected', error_code=exc.code)
        except (BrokenPipeError, ConnectionResetError) as exc:
            evidence.update(status='truncated' if started else 'rejected', error_code='connection_closed')
        except socket.timeout:
            evidence.update(status='truncated' if started else 'rejected', error_code='connect_timeout' if not started else 'stream_timeout')
        except (OSError, ssl.SSLError):
            evidence.update(status='truncated' if started else 'rejected', error_code='transport_error')
        except ValueError:
            # select() can race with stop() closing this managed socket.
            evidence.update(status='truncated' if started else 'rejected',
                            error_code='relay_stopping' if self._closed.is_set() else 'invalid_transport')
        finally:
            evidence.update(response_bytes=total, response_sha256=sha.hexdigest())
            if sock is not None:
                with self._lock:
                    self._sockets.discard(sock)
                sock.close()
        return evidence

    @property
    def _default_transport(self):
        return getattr(self, '_is_vsock', False)


class _HTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = False
    block_on_close = True
    allow_reuse_address = False
    request_queue_size = 8

    def process_request(self, request, client_address):
        if not self.relay._slots.acquire(blocking=False):
            self.shutdown_request(request)
            self.relay.record({'status': 'rejected', 'error_code': 'concurrency_limit', 'authenticated': False})
            return
        with self.relay._lock:
            self.relay._http_sockets.add(request)
        try:
            super().process_request(request, client_address)
        except BaseException:
            with self.relay._lock:
                self.relay._http_sockets.discard(request)
            self.relay._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.relay._lock:
                self.relay._http_sockets.discard(request)
            self.relay._slots.release()

    def handle_error(self, request, client_address):
        self.relay.record({'status': 'rejected', 'error_code': 'http_handler_error', 'authenticated': False})


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'GuestRelay'
    sys_version = ''

    def setup(self):
        self.request.settimeout(CONNECT_TIMEOUT)
        super().setup()

    def log_message(self, *_):
        # Raw HTTP fields are deliberately excluded; structured evidence is recorded below.
        return

    def send_error(self, code, message=None, explain=None):
        self._reject(code, 'http_parse_error')

    def handle_expect_100(self):
        self._reject(417, 'expect_continue_unsupported')
        return False

    def _reject(self, status, code, authenticated=False):
        self.close_connection = True
        body = json.dumps({'error': {'type': 'relay_error', 'message': code}}, separators=(',', ':')).encode()
        try:
            self.send_response(status)
            self.send_header('content-type', 'application/json')
            self.send_header('content-length', str(len(body)))
            self.send_header('connection', 'close')
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
        except OSError:
            pass  # Evidence remains even when the rejecting client is already gone.
        self.server.relay.record({'status': 'rejected', 'error_code': code, 'authenticated': authenticated})

    def _disconnected(self):
        if self.server.relay._stopping.is_set():
            return True
        try:
            if select.select([self.connection], [], [], 0)[0]:
                return self.connection.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b''
        except (OSError, ValueError):
            return True
        return False

    def do_POST(self):
        relay = self.server.relay
        self.close_connection = True
        auth = self.headers.get_all('x-api-key', [])
        if len(auth) != 1 or not hmac.compare_digest(auth[0].encode(), relay.config.client_token.encode()):
            self._reject(401, 'invalid_session_token')
            return
        if relay.lease_expired() or relay._stopping.is_set():
            self._reject(503, 'session_expired', True)
            return
        if self.path not in PATHS:
            self._reject(404, 'unsupported_path', True)
            return
        if self.headers.get_all('transfer-encoding', []):
            self._reject(400, 'chunked_request_unsupported', True)
            return
        lengths = self.headers.get_all('content-length', [])
        if len(lengths) != 1 or not re.fullmatch(r'0|[1-9][0-9]*', lengths[0]) or len(lengths[0]) > 10:
            self._reject(400, 'invalid_content_length', True)
            return
        length = int(lengths[0])
        if length > MAX_BODY:
            self._reject(413, 'request_body_limit', True)
            return
        forwarded = {}
        for name in REQUEST_HEADERS:
            values = self.headers.get_all(name, [])
            if len(values) > 1 or any(len(v) > 4096 or '\r' in v or '\n' in v for v in values):
                self._reject(400, 'invalid_request_headers', True)
                return
            if values:
                forwarded[name] = values[0]
        if forwarded.get('content-type', '').split(';', 1)[0].strip().lower() != 'application/json':
            self._reject(415, 'json_content_type_required', True)
            return
        try:
            body = self.rfile.read(length)
            if len(body) != length or self._disconnected():
                raise RelayError('client_disconnected')
            _json_object(body, 'invalid_request_json')
        except RelayError as exc:
            self._reject(400, exc.code, True)
            return
        except OSError:
            self._reject(400, 'client_disconnected', True)
            return
        started = False

        def on_start(status, headers):
            nonlocal started
            self.send_response(status)
            for name, value in headers.items():
                self.send_header(name, value)
            self.send_header('connection', 'close')
            self.end_headers()
            self.wfile.flush()
            started = True

        def on_chunk(block):
            if self._disconnected():
                raise RelayError('client_disconnected')
            self.wfile.write(block)
            self.wfile.flush()

        evidence = relay.client.forward('POST', self.path, forwarded, body, on_start, on_chunk, self._disconnected)
        evidence['authenticated'] = True
        relay.record(evidence)
        if not started:
            # Do not claim SSE completion when upstream framing/integrity failed.
            self._reject(504 if evidence.get('error_code') in ('stream_timeout', 'connect_timeout') else 502,
                         evidence.get('error_code', 'gateway_error'), True)

    def _method_rejected(self):
        self._reject(405, 'unsupported_method')

    do_GET = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = do_CONNECT = do_TRACE = _method_rejected


class RelayServer:
    """Core server. Tests may supply an ephemeral port and temporary ready path."""

    def __init__(self, config: RelayConfig, client: GatewayClient, address=None, ready_path=READY_PATH, on_stage=None):
        stage = on_stage or (lambda _: None)
        self.config, self.client = config, client
        self.ready_path = Path(ready_path)
        self._lock = threading.Lock()
        self._stopping = threading.Event()
        self._slots = threading.BoundedSemaphore(8)
        self._http_sockets = set()
        self._records = []
        self._discarded_records = 0
        self._thread = None
        self._closed = False
        self._ready_published = False
        self._start_time = time.monotonic()
        stage('relay_state_check')
        if self.config.evidence_path.exists() or self.ready_path.exists():
            raise RelayError('fresh_relay_state_required')
        stage('server_bind')
        self.http = _HTTPServer(address or (config.listen_host, config.listen_port), _Handler)
        self.http.relay = self
        self.http.timeout = .1
        try:
            stage('ready_publish')
            self._write_exclusive(self.ready_path, {'ready': True, 'session_id': config.session_id,
                                                    'boot_epoch': config.boot_epoch})
            self._ready_published = True
            stage('evidence_publish')
            self._persist()
        except BaseException:
            self.http.server_close()
            if self._ready_published:
                self.ready_path.unlink()
            raise

    @property
    def address(self):
        return self.http.server_address

    def lease_expired(self):
        return time.monotonic() - self._start_time >= self.config.lease_seconds

    @staticmethod
    def _write_exclusive(path, value):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, sort_keys=True, indent=2)
            output.write('\n')

    def _persist_locked(self):
        value = {'schema': 'guest-relay-evidence/v1', 'session_id': self.config.session_id,
                 'boot_epoch': self.config.boot_epoch,
                 'state': 'stopped' if self._stopping.is_set() else 'listening',
                 'live_gateway_sockets': self.client.active_count(),
                 'live_http_sockets': len(self._http_sockets),
                 'request_records': self._records,
                 'discarded_record_count': self._discarded_records,
                 'sensitive_fields_recorded': False}
        temporary = self.config.evidence_path.with_name(self.config.evidence_path.name + '.tmp')
        self._write_exclusive(temporary, value)
        try:
            os.replace(temporary, self.config.evidence_path)
        except BaseException:
            temporary.unlink()
            raise

    def _persist(self):
        with self._lock:
            self._persist_locked()

    def record(self, value):
        with self._lock:
            if len(self._records) >= 128:
                self._discarded_records += 1
            else:
                self._records.append(value)
            self._persist_locked()

    def _serve(self):
        while not self._stopping.is_set() and not self.lease_expired():
            try:
                self.http.handle_request()
            except OSError:
                if not self._stopping.is_set():
                    self.record({'status': 'rejected', 'error_code': 'listener_error', 'authenticated': False})
                    self._stopping.set()
        self._stopping.set()

    def start(self):
        if self._thread is not None:
            raise RelayError('relay_already_started')
        self._thread = threading.Thread(target=self._serve, name='guest-relay-listener', daemon=False)
        self._thread.start()
        return self._thread

    def request_stop(self):
        self._stopping.set()

    def stop(self):
        self._stopping.set()
        if self._closed:
            return
        self.client.close()
        with self._lock:
            sockets = list(self._http_sockets)
        for sock in sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass  # Managed HTTP sockets can already be disconnected.
            sock.close()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(2)
            if self._thread.is_alive():
                raise RelayError('listener_stop_timeout')
        self.http.server_close()
        if self._ready_published:
            self.ready_path.unlink()
            self._ready_published = False
        self._closed = True
        self._persist()


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv != [str(CONFIG_PATH)]:
        _emit_diagnostic('arguments', RelayError('config_fixed_path'))
        return 2
    server = None
    result = 0
    stage = 'guest_preflight'
    def set_stage(value):
        nonlocal stage
        if value not in DIAGNOSTIC_STAGES:
            raise ValueError('invalid relay diagnostic stage')
        stage = value
    try:
        guest_preflight()
        set_stage('config_load')
        config = load_fixed_config(on_stage=set_stage)
        set_stage('tls_context')
        context = make_tls_context(config, on_stage=set_stage)
        set_stage('gateway_client')
        client = GatewayClient(config, tls_context=context)
        set_stage('server_bind')
        server = RelayServer(config, client, on_stage=set_stage)
        set_stage('signal_setup')
        signal.signal(signal.SIGTERM, lambda *_: server.request_stop())
        signal.signal(signal.SIGINT, lambda *_: server.request_stop())
        set_stage('start')
        thread = server.start()
        set_stage('running')
        while thread.is_alive() and not server._stopping.is_set():
            thread.join(.2)
        set_stage('stop')
        server.stop()
    except RelayError as exc:
        _emit_diagnostic(stage, exc)
        result = 2
    except (OSError, ssl.SSLError, ValueError, RuntimeError) as exc:
        _emit_diagnostic(stage, exc)
        result = 2
    finally:
        if server is not None and not server._closed:
            try:
                set_stage('cleanup_stop')
                server.stop()
            except RelayError as exc:
                _emit_diagnostic(stage, exc)
                result = 2
            except (OSError, ValueError, RuntimeError) as exc:
                _emit_diagnostic(stage, exc)
                result = 2
    return result


if __name__ == '__main__':
    raise SystemExit(main())
