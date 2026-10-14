#!/usr/bin/env python3
"""Real local Unix/mTLS tests; every provider request targets the fake fixture."""

from __future__ import annotations

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

from gateway import FAKE_ORIGIN, FAKE_PROVIDER_KEY, GatewayError, GatewayServer, load_config


class _FakeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *arguments):
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        content = json.loads(body)
        with self.server.record_lock:
            self.server.records.append({"path": self.path, "headers": dict(self.headers), "body": body})
        mode = content.get("fixture_mode")
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/not-followed")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if mode == "stream":
            first = b'event: fixture\ndata: {"first":true}\n\n'
            last = b'event: fixture\ndata: {"last":true}\n\n'
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(first) + len(last)))
            self.send_header("Set-Cookie", "fake-cookie-is-not-forwarded")
            self.end_headers()
            self.wfile.write(first)
            self.wfile.flush()
            self.server.first_chunk.set()
            self.server.release_stream.wait(timeout=5)
            try:
                self.wfile.write(last)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                self.server.revoked_stream.set()
            return
        response = b'{"input_tokens":7}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


class _Client:
    def __init__(self, socket_path: str, certificates: Path, certificate="client", *, no_certificate=False):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_verify_locations(cafile=str(certificates / "ca.crt"))
        if not no_certificate:
            context.load_cert_chain(str(certificates / f"{certificate}.crt"), str(certificates / f"{certificate}.key"))
        raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        raw.settimeout(3)
        raw.connect(socket_path)
        try:
            self.stream = context.wrap_socket(raw, server_hostname="fixture-gateway")
        except BaseException:
            raw.close()
            raise
        self.pending = bytearray()

    def send(self, value):
        self.stream.sendall(json.dumps(value, separators=(",", ":")).encode() + b"\n")

    def read(self):
        while b"\n" not in self.pending:
            chunk = self.stream.recv(65_536)
            if not chunk:
                return None
            self.pending.extend(chunk)
        line, _, rest = self.pending.partition(b"\n")
        self.pending = bytearray(rest)
        return json.loads(line)

    def close(self):
        self.stream.close()


def _run_openssl(folder: Path, *arguments):
    subprocess.run(["openssl", *arguments], cwd=folder, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def _generate_certificates(folder: Path):
    _run_openssl(folder, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.crt", "-days", "1", "-subj", "/CN=Fixture CA", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    for name, usage in (("server", "serverAuth"), ("client", "clientAuth"), ("other-client", "clientAuth")):
        _run_openssl(folder, "req", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{name}.key", "-out", f"{name}.csr", "-subj", "/CN=fixture-gateway" if name == "server" else f"/CN={name}")
        extensions = "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=" + usage + "\n"
        if name == "server":
            extensions += "subjectAltName=DNS:fixture-gateway\n"
        (folder / f"{name}.ext").write_text(extensions)
        _run_openssl(folder, "x509", "-req", "-in", f"{name}.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-out", f"{name}.crt", "-days", "1", "-extfile", f"{name}.ext")
    _run_openssl(folder, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "untrusted-client.key", "-out", "untrusted-client.crt", "-days", "1", "-subj", "/CN=Untrusted fixture client")
    for path in folder.glob("*.key"):
        path.chmod(0o600)


class GatewayTests(unittest.TestCase):
    metrics = {"fixture_only": True}

    @classmethod
    def setUpClass(cls):
        cls.thread_errors = []
        cls.original_thread_hook = threading.excepthook
        threading.excepthook = lambda error: cls.thread_errors.append(error.exc_type.__name__)
        cls.temporary = tempfile.TemporaryDirectory(prefix="cc-gw-", dir="/tmp")
        cls.root = Path(cls.temporary.name).resolve()
        cls.root.chmod(0o700)
        cls.certificates = cls.root / "certificates"
        cls.certificates.mkdir(mode=0o700)
        _generate_certificates(cls.certificates)
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 41419), _FakeHandler)
        cls.upstream.daemon_threads = True
        cls.upstream.records = []
        cls.upstream.record_lock = threading.Lock()
        cls.upstream.first_chunk = threading.Event()
        cls.upstream.release_stream = threading.Event()
        cls.upstream.revoked_stream = threading.Event()
        cls.upstream_thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        cls.upstream_thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.upstream.release_stream.set()
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.upstream_thread.join(timeout=2)
        cls.temporary.cleanup()
        threading.excepthook = cls.original_thread_hook
        if cls.thread_errors:
            raise AssertionError("unhandled worker exceptions: " + ",".join(cls.thread_errors))

    def setUp(self):
        self.private = self.root / str(uuid.uuid4())
        self.private.mkdir(mode=0o700)
        for name in ("ca.crt", "server.crt", "server.key"):
            shutil.copyfile(self.certificates / name, self.private / name)
            (self.private / name).chmod(0o600 if name.endswith(".key") else 0o644)
        cert_der = ssl.PEM_cert_to_DER_cert((self.certificates / "client.crt").read_text())
        self.config = {
            "schema": "gateway-fixture/v1", "session_id": str(uuid.uuid4()),
            "boot_epoch": 1_791_500_000, "lease_seconds": 30,
            "socket_path": str(self.private / "gateway.sock"),
            "ca_file": str(self.private / "ca.crt"), "server_cert": str(self.private / "server.crt"),
            "server_key": str(self.private / "server.key"),
            "allowed_client_sha256": hashlib.sha256(cert_der).hexdigest(),
            "upstream_origin": FAKE_ORIGIN, "provider_key": FAKE_PROVIDER_KEY,
            "model_allowlist": ["claude-sonnet-4-6"], "evidence_path": str(self.private / "evidence.json"),
        }
        self.config_path = self.private / "config.json"
        self._write_config()
        self.server = None
        self.clients = []
        self.upstream.first_chunk.clear()
        self.upstream.release_stream.clear()
        self.upstream.revoked_stream.clear()

    def _write_config(self):
        self.config_path.write_text(json.dumps(self.config))
        self.config_path.chmod(0o600)

    def _start(self):
        self.server = GatewayServer(load_config(self.config_path)).start()

    def _client(self, **options):
        client = _Client(self.config["socket_path"], self.certificates, **options)
        self.clients.append(client)
        return client

    def _hello(self, client, **changes):
        hello = {"type": "hello", "protocol": "cc-relay/v1", "session_id": self.config["session_id"], "boot_epoch": self.config["boot_epoch"], "role": "proxy"}
        hello.update(changes)
        client.send(hello)
        return client.read()

    def _request(self, **changes):
        body = {"model": "claude-sonnet-4-6", "messages": [{"role": "user", "content": "fixed fixture text"}], "max_tokens": 32}
        request = {"type": "request", "request_id": str(uuid.uuid4()), "method": "POST", "path": "/v1/messages", "headers": {"anthropic-version": "2023-06-01", "content-type": "application/json"}, "body_base64": base64.b64encode(json.dumps(body).encode()).decode()}
        request.update(changes)
        return request

    def _body_request(self, **body_changes):
        request = self._request()
        body = json.loads(base64.b64decode(request["body_base64"]))
        body.update(body_changes)
        request["body_base64"] = base64.b64encode(json.dumps(body).encode()).decode()
        return request

    def _complete(self, client):
        frames = []
        while True:
            frame = client.read()
            if frame is None:
                break
            frames.append(frame)
            if frame["type"] in ("response_end", "error"):
                break
        return frames

    def tearDown(self):
        self.upstream.release_stream.set()
        for client in self.clients:
            client.close()
        if self.server is not None:
            self.server.stop("test_cleanup")
            self.assertFalse(Path(self.config["socket_path"]).exists())
            evidence = json.loads(Path(self.config["evidence_path"]).read_text())
            self.assertEqual(evidence["active_connections"], 0)
            self.assertEqual(evidence["active_upstreams"], 0)
            self.assertEqual(evidence["active_workers"], 0)
            serialized = json.dumps(evidence)
            self.assertNotIn(FAKE_PROVIDER_KEY, serialized)
            self.assertNotIn("fixed fixture text", serialized)
            self.assertNotIn("CLIENT_FAKE_AUTH", serialized)

    def test_mutual_tls_and_host_auth_replacement(self):
        self._start()
        self.assertEqual(Path(self.config["socket_path"]).stat().st_mode & 0o777, 0o600)
        client = self._client()
        self.assertEqual(self._hello(client)["type"], "ready")
        request = self._request(path="/v1/messages/count_tokens?beta=true", headers={
            "Authorization": "Bearer CLIENT_FAKE_AUTH", "x-api-key": "CLIENT_FAKE_AUTH",
            "Cookie": "CLIENT_FAKE_AUTH", "Host": "untrusted-host.invalid",
            "anthropic-version": "2023-06-01", "anthropic-beta": "fixture", "content-type": "application/json",
        })
        with unittest.mock.patch.dict(os.environ, {"HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1"}):
            client.send(request)
            frames = self._complete(client)
        self.assertEqual(frames[0]["status"], 200)
        body = b"".join(base64.b64decode(frame["data_base64"]) for frame in frames if frame["type"] == "response_chunk")
        self.assertEqual(frames[-1]["sha256"], hashlib.sha256(body).hexdigest())
        with self.upstream.record_lock:
            recorded = self.upstream.records[-1]
        headers = {name.lower(): value for name, value in recorded["headers"].items()}
        self.assertEqual(headers["x-api-key"], FAKE_PROVIDER_KEY)
        self.assertNotIn("authorization", headers)
        self.assertNotIn("cookie", headers)
        self.assertEqual(headers["host"], "127.0.0.1:41419")
        self.metrics["auth_replacement"] = "passed"
        self.metrics["environment_proxy_ignored"] = "passed"

    def test_sse_first_chunk_arrives_before_upstream_completion(self):
        self._start()
        client = self._client()
        self.assertEqual(self._hello(client)["type"], "ready")
        started = time.monotonic()
        client.send(self._body_request(fixture_mode="stream"))
        first = client.read()
        chunk = client.read()
        elapsed = time.monotonic() - started
        self.assertEqual(first["type"], "response_start")
        self.assertEqual(chunk["type"], "response_chunk")
        self.assertIn(b'"first":true', base64.b64decode(chunk["data_base64"]))
        self.assertNotIn("set-cookie", first["headers"])
        self.assertFalse(self.upstream.release_stream.is_set())
        self.assertLess(elapsed, 1.0)
        self.upstream.release_stream.set()
        frames = self._complete(client)
        self.assertEqual(frames[-1]["type"], "response_end")
        self.metrics["sse_first_chunk_ms"] = round(elapsed * 1000, 3)

    def test_valid_ca_wrong_certificate_pin(self):
        self._start()
        client = self._client(certificate="other-client")
        self.assertEqual(client.read(), {"type": "error", "code": "CLIENT_CERTIFICATE_PIN_MISMATCH"})

    def test_untrusted_certificate_and_missing_certificate(self):
        self._start()
        for options in ({"certificate": "untrusted-client"}, {"no_certificate": True}):
            with self.subTest(options=sorted(options)):
                client = None
                try:
                    client = self._client(**options)
                    with self.assertRaises(ssl.SSLError):
                        client.read()
                except ssl.SSLError:
                    pass  # TLS may reject during connect or during the first read.

    def test_hello_role_epoch_session_contract(self):
        self._start()
        for change, code in (({"role": "controller"}, "ROLE_INVALID"), ({"boot_epoch": self.config["boot_epoch"] + 1}, "SESSION_BINDING_INVALID"), ({"boot_epoch": str(self.config["boot_epoch"])}, "SESSION_BINDING_INVALID"), ({"session_id": str(uuid.uuid4())}, "SESSION_BINDING_INVALID")):
            with self.subTest(field=next(iter(change))):
                client = self._client()
                self.assertEqual(self._hello(client, **change), {"type": "error", "code": code})
                client.close()

    def test_method_path_model_and_body_limits(self):
        self._start()
        cases = [
            (self._request(method="GET"), "REQUEST_ROUTE_INVALID"),
            (self._request(path="http://127.0.0.1:41419/v1/messages"), "REQUEST_ROUTE_INVALID"),
            (self._request(path="/v1/messages?beta=true&other=true"), "REQUEST_ROUTE_INVALID"),
            (self._body_request(model="arbitrary-model"), "MODEL_NOT_ALLOWED"),
            (self._request(body_base64="%%%"), "REQUEST_BODY_INVALID"),
            (self._request(body_base64="A" * 4_000_004), "REQUEST_BODY_TOO_LARGE"),
        ]
        for request, code in cases:
            with self.subTest(code=code):
                client = self._client()
                self.assertEqual(self._hello(client)["type"], "ready")
                client.send(request)
                self.assertEqual(client.read(), {"type": "error", "code": code})
                client.close()

    def test_request_id_replay(self):
        self._start()
        request = self._request()
        client = self._client()
        self.assertEqual(self._hello(client)["type"], "ready")
        client.send(request)
        self.assertEqual(self._complete(client)[-1]["type"], "response_end")
        again = self._client()
        self.assertEqual(self._hello(again)["type"], "ready")
        again.send(request)
        self.assertEqual(again.read(), {"type": "error", "code": "REQUEST_ID_REPLAY"})

    def test_redirect_is_refused(self):
        self._start()
        client = self._client()
        self.assertEqual(self._hello(client)["type"], "ready")
        client.send(self._body_request(fixture_mode="redirect"))
        self.assertEqual(client.read(), {"type": "error", "code": "UPSTREAM_REDIRECT_REFUSED"})

    def test_revocation_closes_active_sse_and_upstream(self):
        self._start()
        client = self._client()
        self.assertEqual(self._hello(client)["type"], "ready")
        client.send(self._body_request(fixture_mode="stream"))
        self.assertEqual(client.read()["type"], "response_start")
        self.assertEqual(client.read()["type"], "response_chunk")
        started = time.monotonic()
        self.server.stop("revoked")
        elapsed = time.monotonic() - started
        self.assertIsNone(client.read())
        self.assertLess(elapsed, 1.0)
        self.assertEqual(self.server.evidence["stop_reason"], "revoked")
        self.metrics["revocation_cleanup_ms"] = round(elapsed * 1000, 3)

    def test_lease_expiration_closes_idle_authenticated_link(self):
        self.config["lease_seconds"] = 1
        self._write_config()
        self._start()
        client = self._client()
        self.assertEqual(self._hello(client)["type"], "ready")
        self.server._server_thread.join(timeout=2)
        self.assertIsNone(client.read())
        self.assertEqual(self.server.evidence["stop_reason"], "lease_expired")

    def test_revocation_closes_incomplete_tls_handshake(self):
        self._start()
        raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        raw.settimeout(2)
        raw.connect(self.config["socket_path"])
        try:
            deadline = time.monotonic() + 1
            while self.server.evidence["active_workers"] == 0 and time.monotonic() < deadline:
                threading.Event().wait(0.005)
            self.assertEqual(self.server.evidence["active_workers"], 1)
            self.server.stop("revoked")
            self.assertEqual(raw.recv(1), b"")
        finally:
            raw.close()

    def test_config_rejects_production_output_overwrite_and_loose_permissions(self):
        for change, code in (({"upstream_origin": "https://api.anthropic.com"}, "CONFIG_FIXTURE_ONLY"), ({"provider_key": "real-looking-but-not-a-key"}, "CONFIG_FIXTURE_ONLY"), ({"lease_seconds": 601}, "CONFIG_LEASE_INVALID")):
            self.config.update(change)
            self._write_config()
            with self.assertRaises(GatewayError) as result:
                load_config(self.config_path)
            self.assertEqual(result.exception.code, code)
            self.config["upstream_origin"] = FAKE_ORIGIN
            self.config["provider_key"] = FAKE_PROVIDER_KEY
            self.config["lease_seconds"] = 30
        self._write_config()
        self.config_path.chmod(0o644)
        with self.assertRaises(GatewayError) as result:
            load_config(self.config_path)
        self.assertEqual(result.exception.code, "CONFIG_FILE_MODE_INVALID")
        self.config_path.chmod(0o600)
        Path(self.config["evidence_path"]).write_text("existing evidence")
        with self.assertRaises(GatewayError) as result:
            load_config(self.config_path)
        self.assertEqual(result.exception.code, "CONFIG_OUTPUT_EXISTS")
        self.assertEqual(Path(self.config["evidence_path"]).read_text(), "existing evidence")


def main():
    # Importing mock explicitly is needed on Python versions which do not expose
    # the submodule through unittest until it has been imported.
    import unittest.mock  # noqa: F401
    evidence_path = Path(__file__).resolve().parent / "evidence" / "gateway-local.json"
    if len(sys.argv) == 3 and sys.argv[1] == "--evidence":
        evidence_path = Path(sys.argv[2]).resolve()
    elif len(sys.argv) != 1:
        print("usage: test_gateway.py [--evidence NEW_ABSOLUTE_PATH]", file=sys.stderr)
        return 2
    if os.path.lexists(evidence_path):
        print("evidence output exists; use a new --evidence path", file=sys.stderr)
        return 2
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(GatewayTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        return 1
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(evidence_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump({"schema": "host-gateway-local-tests/v1", "tests_run": result.testsRun, "status": "passed", **GatewayTests.metrics}, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print(json.dumps({"status": "passed", "tests_run": result.testsRun, "evidence_path": str(evidence_path)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
