#!/usr/bin/python3
"""Opaque byte bridge: guest loopback HTTP proxy -> host CID 2 / port 40125.

HTTP CONNECT parsing, domain admission, DNS and egress policy belong to the
host gateway. This service never resolves a name or opens an Internet socket.
"""
import logging
import socket
import threading

logging.basicConfig(level=logging.WARNING, format="browser-proxy: %(message)s")
LIMIT = threading.BoundedSemaphore(128)


def copy_stream(source, target):
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            target.sendall(data)
    except OSError as error:
        logging.warning("connection stream ended: %s", type(error).__name__)
    finally:
        try:
            target.shutdown(socket.SHUT_WR)
        except OSError as error:
            # Peer termination is expected, but never silently hides a failure.
            logging.debug("half-close ended: %s", type(error).__name__)


def handle(client):
    upstream = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        upstream.settimeout(10)
        upstream.connect((2, 40125))
        upstream.settimeout(None)
        reader = threading.Thread(target=copy_stream, args=(client, upstream), daemon=True)
        reader.start()
        copy_stream(upstream, client)
        client.shutdown(socket.SHUT_RD)
        reader.join(timeout=5)
    except OSError as error:
        logging.warning("host channel unavailable: %s", type(error).__name__)
        try:
            client.sendall(b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        except OSError as send_error:
            logging.debug("unavailable response ended: %s", type(send_error).__name__)
    finally:
        upstream.close()
        client.close()
        LIMIT.release()


def main():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 7890))
        server.listen(64)
        while True:
            client, _ = server.accept()
            if not LIMIT.acquire(blocking=False):
                client.close()
                logging.warning("connection capacity reached")
                continue
            threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
