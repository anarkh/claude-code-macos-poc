#!/usr/bin/env python3
"""Fixture-only, mutually authenticated host provider gateway.

The only permitted provider is the local fake HTTP fixture.  This program does
not implement a production key store or an Internet-facing provider adapter.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import stat
import sys
import threading
import time
import uuid


PROTOCOL = "cc-relay/v1"
CONFIG_SCHEMA = "gateway-fixture/v1"
FAKE_ORIGIN = "http://127.0.0.1:41419"
FAKE_PROVIDER_KEY = "host-only-FAKE-provider-NOT-VALID"
MAX_FRAME = 4_200_000
MAX_REQUEST_BODY = 3_000_000
MAX_RESPONSE_BODY = 16 * 1024 * 1024
RESPONSE_CHUNK = 16 * 1024
UPSTREAM_TIMEOUT = 60.0
REQUEST_PATHS = frozenset(
    path + suffix
    for path in ("/v1/messages", "/v1/messages/count_tokens")
    for suffix in ("", "?beta=true")
)
REQUEST_HEADERS = frozenset(("anthropic-version", "anthropic-beta", "content-type"))
RESPONSE_HEADERS = frozenset(
    (
        "content-type", "retry-after", "request-id", "x-request-id",
        "anthropic-ratelimit-requests-limit", "anthropic-ratelimit-requests-remaining",
        "anthropic-ratelimit-requests-reset", "anthropic-ratelimit-tokens-limit",
        "anthropic-ratelimit-tokens-remaining", "anthropic-ratelimit-tokens-reset",
    )
)


class GatewayError(Exception):
    """A fixed, non-sensitive protocol error code."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _hash(value: str | bytes) -> str:
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def _absolute_path(value: object) -> Path:
    if not isinstance(value, str) or not value or not Path(value).is_absolute():
        raise GatewayError("CONFIG_PATH_INVALID")
    path = Path(value)
    if str(path) != value or ".." in path.parts:
        raise GatewayError("CONFIG_PATH_INVALID")
    return path


def _private_file(path: Path, *, secret: bool = False) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise GatewayError("CONFIG_FILE_UNAVAILABLE") from error
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise GatewayError("CONFIG_FILE_INVALID")
    if info.st_uid != os.getuid():
        raise GatewayError("CONFIG_FILE_OWNER_INVALID")
    mode = stat.S_IMODE(info.st_mode)
    if (secret and mode != 0o600) or (not secret and mode & 0o022):
        raise GatewayError("CONFIG_FILE_MODE_INVALID")


def load_config(config_path: str | Path) -> dict:
    """Read a private fixture config; reject production origins and key values."""
    path = _absolute_path(str(config_path))
    parent = path.parent
    try:
        info = parent.lstat()
    except OSError as error:
        raise GatewayError("CONFIG_DIRECTORY_UNAVAILABLE") from error
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700:
        raise GatewayError("CONFIG_DIRECTORY_MODE_INVALID")
    if info.st_uid != os.getuid():
        raise GatewayError("CONFIG_DIRECTORY_OWNER_INVALID")
    if parent.resolve() != parent:
        raise GatewayError("CONFIG_DIRECTORY_INVALID")
    _private_file(path, secret=True)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as stream:
            raw = stream.read(32_769)
        if len(raw) > 32_768:
            raise GatewayError("CONFIG_TOO_LARGE")
        config = json.loads(raw)
    except (OSError, ValueError, UnicodeError) as error:
        raise GatewayError("CONFIG_INVALID") from error
    required = {
        "schema", "session_id", "boot_epoch", "lease_seconds", "socket_path",
        "ca_file", "server_cert", "server_key", "allowed_client_sha256",
        "upstream_origin", "provider_key", "model_allowlist", "evidence_path",
    }
    if not isinstance(config, dict) or set(config) != required or config["schema"] != CONFIG_SCHEMA:
        raise GatewayError("CONFIG_SCHEMA_INVALID")
    try:
        if str(uuid.UUID(config["session_id"])) != config["session_id"]:
            raise ValueError("noncanonical")
    except (ValueError, TypeError, AttributeError) as error:
        raise GatewayError("CONFIG_SESSION_INVALID") from error
    if type(config["boot_epoch"]) is not int or config["boot_epoch"] <= 0:
        raise GatewayError("CONFIG_EPOCH_INVALID")
    if type(config["lease_seconds"]) is not int or not 1 <= config["lease_seconds"] <= 600:
        raise GatewayError("CONFIG_LEASE_INVALID")
    if config["upstream_origin"] != FAKE_ORIGIN or config["provider_key"] != FAKE_PROVIDER_KEY:
        raise GatewayError("CONFIG_FIXTURE_ONLY")
    if config["model_allowlist"] != ["claude-sonnet-4-6"]:
        raise GatewayError("CONFIG_MODEL_INVALID")
    if not isinstance(config["allowed_client_sha256"], str) or not re.fullmatch(
        r"[0-9a-f]{64}", config["allowed_client_sha256"]
    ):
        raise GatewayError("CONFIG_CERTIFICATE_PIN_INVALID")
    for name in ("socket_path", "ca_file", "server_cert", "server_key"):
        candidate = _absolute_path(config[name])
        if candidate.parent != parent:
            raise GatewayError("CONFIG_PRIVATE_PATH_INVALID")
        if name != "socket_path":
            _private_file(candidate, secret=name == "server_key")
    if Path(config["socket_path"]).name != "gateway.sock":
        raise GatewayError("CONFIG_SOCKET_INVALID")
    if len(os.fsencode(config["socket_path"])) >= 104:
        raise GatewayError("CONFIG_SOCKET_PATH_TOO_LONG")
    evidence = _absolute_path(config["evidence_path"])
    if not evidence.parent.is_dir() or evidence.parent.resolve() != evidence.parent:
        raise GatewayError("CONFIG_EVIDENCE_DIRECTORY_INVALID")
    for candidate in (Path(config["socket_path"]), evidence):
        if os.path.lexists(candidate):
            raise GatewayError("CONFIG_OUTPUT_EXISTS")
    return config


class _FramedConnection:
    def __init__(self, stream: ssl.SSLSocket, remaining_lease):
        self.stream = stream
        self.remaining_lease = remaining_lease
        self.pending = bytearray()

    def read(self) -> dict:
        deadline = time.monotonic() + 10
        while True:
            newline = self.pending.find(b"\n")
            if newline >= 0:
                if newline > MAX_FRAME:
                    raise GatewayError("FRAME_TOO_LARGE")
                line = bytes(self.pending[:newline])
                del self.pending[:newline + 1]
                try:
                    value = json.loads(line)
                except (ValueError, UnicodeError) as error:
                    raise GatewayError("FRAME_INVALID") from error
                if not isinstance(value, dict):
                    raise GatewayError("FRAME_INVALID")
                return value
            if len(self.pending) > MAX_FRAME:
                raise GatewayError("FRAME_TOO_LARGE")
            remaining = min(deadline - time.monotonic(), self.remaining_lease())
            if remaining <= 0:
                raise GatewayError("FRAME_TIMEOUT")
            self.stream.settimeout(min(0.25, remaining))
            try:
                chunk = self.stream.recv(min(65_536, MAX_FRAME + 1 - len(self.pending)))
            except socket.timeout:
                continue
            if not chunk:
                raise GatewayError("CONNECTION_CLOSED")
            self.pending.extend(chunk)

    def write(self, value: dict) -> None:
        frame = json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode() + b"\n"
        if len(frame) - 1 > MAX_FRAME:
            raise GatewayError("FRAME_TOO_LARGE")
        self.stream.settimeout(min(10.0, self.remaining_lease()))
        self.stream.sendall(frame)


class GatewayServer:
    """One leased fixture session, accepting one provider request per TLS link."""

    def __init__(self, config: dict):
        # Callers should pass the result of load_config.  start() rechecks outputs
        # and the CLI always validates the complete configuration first.
        if config.get("schema") != CONFIG_SCHEMA or config.get("upstream_origin") != FAKE_ORIGIN or config.get("provider_key") != FAKE_PROVIDER_KEY or config.get("model_allowlist") != ["claude-sonnet-4-6"]:
            raise GatewayError("CONFIG_FIXTURE_ONLY")
        self.config = dict(config)
        self.address = self.config["socket_path"]
        self._lock = threading.RLock()
        self._stop_lock = threading.Lock()
        self._stopped = threading.Event()
        self._listener: socket.socket | None = None
        self._server_thread: threading.Thread | None = None
        self._workers: set[threading.Thread] = set()
        self._connections: set[socket.socket] = set()
        self._upstreams: set[http.client.HTTPConnection] = set()
        self._upstream_sockets: dict[http.client.HTTPConnection, socket.socket] = {}
        self._seen_request_ids: set[str] = set()
        self._started_at: float | None = None
        self._deadline: float | None = None
        self._events: list[dict] = []
        self._stop_reason: str | None = None
        self._evidence_saved = False
        self._context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self._context.minimum_version = ssl.TLSVersion.TLSv1_2
        self._context.options |= ssl.OP_NO_COMPRESSION
        self._context.verify_mode = ssl.CERT_REQUIRED
        self._context.load_verify_locations(cafile=self.config["ca_file"])
        self._context.load_cert_chain(self.config["server_cert"], self.config["server_key"])

    @property
    def evidence(self) -> dict:
        with self._lock:
            return {
                "schema": "host-gateway-evidence/v1",
                "fixture_only": True,
                "session_sha256": _hash(self.config["session_id"]),
                "boot_epoch_sha256": _hash(str(self.config["boot_epoch"])),
                "allowed_client_sha256": self.config["allowed_client_sha256"],
                "stop_reason": self._stop_reason,
                "events": [dict(event) for event in self._events],
                "active_connections": len(self._connections),
                "active_upstreams": len(self._upstreams),
                "active_workers": sum(worker.is_alive() for worker in self._workers),
                "unique_request_count": len(self._seen_request_ids),
            }

    def _event(self, decision: str, **metadata: object) -> None:
        with self._lock:
            self._events.append({"decision": decision, **metadata})

    def _remaining_lease(self) -> float:
        if self._deadline is None:
            raise GatewayError("SESSION_NOT_STARTED")
        remaining = self._deadline - time.monotonic()
        if self._stopped.is_set() or remaining <= 0:
            raise GatewayError("LEASE_EXPIRED")
        return remaining

    def start(self) -> "GatewayServer":
        if self._server_thread is not None:
            raise GatewayError("SESSION_ALREADY_STARTED")
        if os.path.lexists(self.address) or os.path.lexists(self.config["evidence_path"]):
            raise GatewayError("CONFIG_OUTPUT_EXISTS")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(self.address)
            os.chmod(self.address, 0o600)
            listener.listen(8)
            listener.settimeout(0.1)
        except BaseException:
            listener.close()
            raise
        self._listener = listener
        self._started_at = time.monotonic()
        self._deadline = self._started_at + self.config["lease_seconds"]
        self._server_thread = threading.Thread(target=self._serve, name="fixture-gateway", daemon=True)
        self._server_thread.start()
        return self

    def serve_forever(self) -> None:
        if self._server_thread is None:
            self.start()
        self._server_thread.join()

    def _serve(self) -> None:
        try:
            while not self._stopped.is_set():
                if self._deadline is not None and time.monotonic() >= self._deadline:
                    self.stop("lease_expired")
                    return
                try:
                    raw, _ = self._listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if not self._stopped.is_set():
                        self.stop("listener_error")
                    return
                with self._lock:
                    if len(self._connections) >= 4:
                        raw.close()
                        self._event("connection_rejected", code="CONNECTION_LIMIT")
                        continue
                    self._connections.add(raw)
                    worker = threading.Thread(target=self._handle, args=(raw,), daemon=True)
                    self._workers.add(worker)
                    worker.start()
        except Exception:
            self._event("server_error", code="INTERNAL_ERROR")
            self.stop("internal_error")

    def _validate_hello(self, hello: dict) -> None:
        self._remaining_lease()
        required = {"type", "protocol", "session_id", "boot_epoch", "role"}
        if set(hello) != required or hello.get("type") != "hello" or hello.get("protocol") != PROTOCOL:
            raise GatewayError("HELLO_INVALID")
        if hello.get("session_id") != self.config["session_id"] or type(hello.get("boot_epoch")) is not int or hello.get("boot_epoch") != self.config["boot_epoch"]:
            raise GatewayError("SESSION_BINDING_INVALID")
        if hello.get("role") != "proxy":
            raise GatewayError("ROLE_INVALID")

    def _validate_request(self, request: dict) -> tuple[str, dict[str, str], bytes]:
        self._remaining_lease()
        required = {"type", "request_id", "method", "path", "headers", "body_base64"}
        if set(request) != required or request.get("type") != "request":
            raise GatewayError("REQUEST_INVALID")
        request_id = request.get("request_id")
        try:
            if str(uuid.UUID(request_id)) != request_id:
                raise ValueError("noncanonical")
        except (ValueError, TypeError, AttributeError) as error:
            raise GatewayError("REQUEST_ID_INVALID") from error
        if request.get("method") != "POST" or not isinstance(request.get("path"), str) or request["path"] not in REQUEST_PATHS:
            raise GatewayError("REQUEST_ROUTE_INVALID")
        incoming = request.get("headers")
        if not isinstance(incoming, dict) or len(incoming) > 64:
            raise GatewayError("REQUEST_HEADERS_INVALID")
        normalized: dict[str, str] = {}
        for name, value in incoming.items():
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", name) or not isinstance(value, str) or len(value) > 8192 or any(ord(char) < 32 or ord(char) > 126 for char in value):
                raise GatewayError("REQUEST_HEADERS_INVALID")
            lower = name.lower()
            if lower in normalized:
                raise GatewayError("REQUEST_HEADERS_INVALID")
            normalized[lower] = value
        encoded = request.get("body_base64")
        if not isinstance(encoded, str) or len(encoded) > (MAX_REQUEST_BODY + 2) // 3 * 4:
            raise GatewayError("REQUEST_BODY_TOO_LARGE")
        try:
            body = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error) as error:
            raise GatewayError("REQUEST_BODY_INVALID") from error
        if len(body) > MAX_REQUEST_BODY:
            raise GatewayError("REQUEST_BODY_TOO_LARGE")
        try:
            content = json.loads(body)
        except (ValueError, UnicodeError) as error:
            raise GatewayError("REQUEST_BODY_INVALID") from error
        if not isinstance(content, dict) or content.get("model") not in self.config["model_allowlist"]:
            raise GatewayError("MODEL_NOT_ALLOWED")
        outgoing = {name: value for name, value in normalized.items() if name in REQUEST_HEADERS}
        if outgoing.get("content-type", "application/json").split(";", 1)[0].strip().lower() != "application/json":
            raise GatewayError("REQUEST_CONTENT_TYPE_INVALID")
        outgoing.setdefault("content-type", "application/json")
        outgoing["x-api-key"] = self.config["provider_key"]
        with self._lock:
            if request_id in self._seen_request_ids:
                raise GatewayError("REQUEST_ID_REPLAY")
            self._seen_request_ids.add(request_id)
        self._event(
            "request_accepted", request_id_sha256=_hash(request_id),
            request_field_names=sorted(request), input_header_names=sorted(normalized),
            upstream_header_names=sorted(outgoing), request_body_bytes=len(body),
            request_body_sha256=_hash(body), route_sha256=_hash(request["path"]),
        )
        return request["path"], outgoing, body

    def _forward(self, framed: _FramedConnection, route: str, headers: dict[str, str], body: bytes) -> None:
        deadline = time.monotonic() + UPSTREAM_TIMEOUT
        timeout = min(UPSTREAM_TIMEOUT, self._remaining_lease())
        upstream = http.client.HTTPConnection("127.0.0.1", 41419, timeout=timeout)
        try:
            upstream.connect()
            upstream.auto_open = 0
            upstream_socket = upstream.sock
            with self._lock:
                self._remaining_lease()
                self._upstreams.add(upstream)
                self._upstream_sockets[upstream] = upstream_socket
            # HTTPConnection never consults HTTP(S)_PROXY and does not follow redirects.
            upstream_socket.settimeout(min(deadline - time.monotonic(), self._remaining_lease()))
            upstream.request("POST", route, body=body, headers=headers)
            upstream_socket.settimeout(min(deadline - time.monotonic(), self._remaining_lease()))
            response = upstream.getresponse()
            self._remaining_lease()
            if 300 <= response.status < 400:
                raise GatewayError("UPSTREAM_REDIRECT_REFUSED")
            response_headers: dict[str, str] = {}
            for name, value in response.getheaders():
                lower = name.lower()
                if lower in RESPONSE_HEADERS and not any(ord(char) < 32 or ord(char) == 127 for char in value):
                    response_headers[lower] = value
            framed.write({"type": "response_start", "status": response.status, "headers": response_headers})
            total = 0
            digest = hashlib.sha256()
            while True:
                remaining = min(deadline - time.monotonic(), self._remaining_lease())
                if remaining <= 0:
                    raise GatewayError("UPSTREAM_TIMEOUT")
                upstream_socket.settimeout(remaining)
                # read1 returns available data rather than waiting for a full
                # 16 KiB buffer.  This matters for small, open SSE events.
                chunk = response.read1(RESPONSE_CHUNK)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_RESPONSE_BODY:
                    raise GatewayError("RESPONSE_BODY_TOO_LARGE")
                digest.update(chunk)
                framed.write({"type": "response_chunk", "data_base64": base64.b64encode(chunk).decode("ascii")})
            framed.write({"type": "response_end", "total_bytes": total, "sha256": digest.hexdigest()})
            self._event("response_completed", status=response.status, response_header_names=sorted(response_headers), response_bytes=total, response_sha256=digest.hexdigest())
        except socket.timeout as error:
            raise GatewayError("UPSTREAM_TIMEOUT") from error
        except (http.client.HTTPException, OSError) as error:
            raise GatewayError("UPSTREAM_UNAVAILABLE") from error
        finally:
            upstream.close()
            with self._lock:
                self._upstreams.discard(upstream)
                self._upstream_sockets.pop(upstream, None)

    def _handle(self, raw: socket.socket) -> None:
        stream: ssl.SSLSocket | None = None
        framed: _FramedConnection | None = None
        try:
            # Register the SSL socket before the handshake so revocation also
            # closes a client which stops halfway through TLS negotiation.  The
            # transfer detaches raw's descriptor, so make that transfer atomic
            # with respect to the stop() connection snapshot.
            with self._lock:
                raw.settimeout(min(10.0, self._remaining_lease()))
                stream = self._context.wrap_socket(raw, server_side=True, do_handshake_on_connect=False)
                self._connections.discard(raw)
                self._connections.add(stream)
                self._remaining_lease()
            handshake_deadline = time.monotonic() + 10
            while True:
                remaining = min(handshake_deadline - time.monotonic(), self._remaining_lease())
                if remaining <= 0:
                    raise GatewayError("TLS_HANDSHAKE_TIMEOUT")
                stream.settimeout(min(0.25, remaining))
                try:
                    stream.do_handshake()
                    break
                except socket.timeout:
                    continue
            fingerprint = _hash(stream.getpeercert(binary_form=True))
            framed = _FramedConnection(stream, self._remaining_lease)
            if fingerprint != self.config["allowed_client_sha256"]:
                raise GatewayError("CLIENT_CERTIFICATE_PIN_MISMATCH")
            self._event("client_authenticated", client_certificate_sha256=fingerprint, tls_version=stream.version())
            self._validate_hello(framed.read())
            framed.write({"type": "ready", "protocol": PROTOCOL, "session_id": self.config["session_id"], "boot_epoch": self.config["boot_epoch"]})
            route, headers, body = self._validate_request(framed.read())
            self._forward(framed, route, headers, body)
        except GatewayError as error:
            self._event("request_rejected", code=error.code)
            if framed is not None:
                try:
                    framed.write({"type": "error", "code": error.code})
                except (OSError, GatewayError):
                    self._event("error_delivery_unavailable", code=error.code)
        except ssl.SSLError:
            self._event("client_rejected", code="TLS_AUTHENTICATION_FAILED")
        except (OSError, ValueError):
            self._event("connection_closed", code="CONNECTION_IO_FAILED")
        finally:
            if stream is not None:
                stream.close()
            raw.close()
            with self._lock:
                self._connections.discard(raw)
                if stream is not None:
                    self._connections.discard(stream)
                self._workers.discard(threading.current_thread())

    def stop(self, reason: str = "revoked") -> None:
        """Revoke the lease, close active streams, persist evidence, unlink socket."""
        with self._stop_lock:
            if self._stopped.is_set():
                return
            self._stop_reason = reason
            self._stopped.set()
            if self._listener is not None:
                self._listener.close()
            with self._lock:
                connections = list(self._connections)
                upstreams = list(self._upstreams)
                upstream_sockets = list(self._upstream_sockets.values())
                workers = list(self._workers)
            for connection in connections:
                try:
                    # Bypass SSLSocket.shutdown's mutation of _sslobj while
                    # another thread may be inside do_handshake or recv.
                    socket.socket.shutdown(connection, socket.SHUT_RDWR)
                except OSError:
                    self._event("connection_already_closed")
            for upstream_socket in upstream_sockets:
                try:
                    upstream_socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    self._event("upstream_already_closed")
            current = threading.current_thread()
            if self._server_thread is not None and self._server_thread is not current:
                self._server_thread.join(timeout=2.0)
            for worker in workers:
                if worker is not current:
                    worker.join(timeout=2.0)
            for connection in connections:
                connection.close()
            # shutdown interrupts reads without concurrently mutating the
            # HTTPResponse's buffered reader.  Only close after workers finish.
            for upstream in upstreams:
                upstream.close()
            if os.path.lexists(self.address):
                os.unlink(self.address)
            descriptor = os.open(self.config["evidence_path"], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                json.dump(self.evidence, stream, indent=2, sort_keys=True)
                stream.write("\n")
            self._evidence_saved = True


def main(arguments: list[str] | None = None) -> int:
    args = sys.argv[1:] if arguments is None else arguments
    if len(args) != 1:
        print("usage: gateway.py CONFIG", file=sys.stderr)
        return 2
    server: GatewayServer | None = None
    try:
        config = load_config(args[0])
        server = GatewayServer(config)
        signal.signal(signal.SIGTERM, lambda _number, _frame: server.stop("sigterm"))
        signal.signal(signal.SIGINT, lambda _number, _frame: server.stop("sigint"))
        server.start()
        print(json.dumps({"kind": "gateway_ready", "protocol": PROTOCOL, "socket_path": server.address}), flush=True)
        server.serve_forever()
        return 0
    except (GatewayError, OSError, ssl.SSLError) as error:
        code = error.code if isinstance(error, GatewayError) else "GATEWAY_START_OR_STOP_FAILED"
        print(json.dumps({"kind": "gateway_error", "code": code}), file=sys.stderr, flush=True)
        if server is not None and not server._stopped.is_set():
            server.stop("main_error")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
