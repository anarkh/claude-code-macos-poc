"""Bounded privacy facts from a supervisor-created Linux guest probe.

This module performs no probes on import.  It deliberately reports neither an
overall privacy verdict nor host/guest identifiers, paths, environment values,
mount names, interface names, or raw exception messages.  The environment and
inherited-descriptor checks describe this probe process, not the SDK process.
All destinations and fake fixture paths are fixed synthetic test targets.
The caller creates fake host fixtures at the same public synthetic paths.
Absence describes those paths in the guest namespace; the caller must separately
establish host fixture existence.  These observations are no privacy verdict.
"""
from __future__ import annotations

import errno
import json
import os
import platform
import re
import socket
from typing import Callable


_TIMEOUT = 0.4
_CANARY = "/private/tmp/claude-text-host-fixture/canary.txt"
_HOST_IPC = "/private/tmp/claude-text-host-fixture/broker.sock"
_ENV_ALLOWLIST = frozenset({
    "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR",
    "PYTHONUNBUFFERED",
})
_CLIPBOARD_ENV = frozenset({
    "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS",
    "SSH_AUTH_SOCK",
})
_SHARED_FS = frozenset({"virtiofs", "fuse.virtiofs", "9p", "cifs", "nfs", "nfs4"})
_UNSUPPORTED_SOCKET = frozenset({
    errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT, errno.ENOSYS,
    errno.EOPNOTSUPP,
})
_NO_ROUTE = frozenset({errno.ENETUNREACH, errno.EHOSTUNREACH})
_CHECK_NAMES = (
    "linux", "guestHostname", "machineIdShape", "aarch64", "nonRootUid",
    "interfacesLoopbackOnly", "noSharedMounts", "noMacosPaths",
    "noClipboardEnv", "noMacosFrameworks", "environmentAllowlisted", "noProviderCredentialEnv",
    "noUnapprovedInheritedFds", "hostCanaryAbsent", "hostIpcPathAbsent",
)
_ATTEMPT_NAMES = (
    "ipv4Tcp", "ipv6Tcp", "ipv4DnsUdp", "ipv6DnsUdp",
    "hostLoopbackHttp", "hostIpcSocket", "vsockPort1", "vsockPort40125",
)


class _ProbeUnavailable(Exception):
    """A fixed classification for an observation that could not be completed."""

    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)


def _read_bounded(path: str, maximum: int) -> bytes:
    with open(path, "rb") as handle:
        value = handle.read(maximum + 1)
    if len(value) > maximum:
        raise _ProbeUnavailable("observation_too_large")
    return value


def _machine_id_shape() -> bool:
    # Only a shape predicate escapes this function, never the machine ID.
    return re.fullmatch(rb"[0-9a-fA-F]{32}", _read_bounded("/etc/machine-id", 128).strip()) is not None


def _interfaces_loopback_only() -> bool:
    names = os.listdir("/sys/class/net")
    if len(names) > 64:
        raise _ProbeUnavailable("observation_too_large")
    return set(names) == {"lo"}


def _no_shared_mounts() -> bool:
    contents = _read_bounded("/proc/self/mountinfo", 262144)
    for line in contents.splitlines():
        left, separator, right = line.partition(b" - ")
        fields = right.split()
        if not separator or not left or len(fields) < 3:
            raise _ProbeUnavailable("invalid_mountinfo")
        if fields[0].decode("ascii", errors="strict") in _SHARED_FS:
            return False
    if not contents.strip():
        raise _ProbeUnavailable("empty_mountinfo")
    return True


def _path_absent(path: str) -> bool:
    try:
        os.lstat(path)
    except FileNotFoundError:
        return True
    return False


def _no_credential_environment() -> bool:
    # Inspect names only.  Values are never read or included in the evidence.
    for name in os.environ:
        normalized = name.upper()
        if any(part in normalized for part in ("TOKEN", "SECRET", "PASSWORD", "CREDENTIAL")):
            return False
        if "KEY" in normalized and normalized.startswith((
            "ANTHROPIC_", "OPENAI_", "AWS_", "AZURE_", "GOOGLE_", "GEMINI_",
        )):
            return False
    return True


def _no_unapproved_inherited_fds() -> bool:
    # Keep our procfs directory FD identifiable.  listdir may briefly duplicate
    # it; entries whose FDs have already closed are not inherited descriptors.
    directory_fd = os.open("/proc/self/fd", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        entries = os.listdir(directory_fd)
        if len(entries) > 256:
            raise _ProbeUnavailable("observation_too_large")
        for entry in entries:
            if not entry.isdecimal():
                raise _ProbeUnavailable("invalid_fd_directory")
            descriptor = int(entry)
            if descriptor in (0, 1, 2, directory_fd):
                continue
            try:
                os.fstat(descriptor)
            except OSError as error:
                if error.errno == errno.EBADF:
                    continue
                raise
            return False
        return True
    finally:
        os.close(directory_fd)


def _unavailable(reason: str, error_number: int | None = None) -> dict:
    return {"available": False, "denied": None, "errno": error_number, "reason": reason}


def _socket_attempt(family: int | None, address: object, *, udp: bool = False) -> dict:
    if family is None:
        return _unavailable("socket_family_unavailable")
    try:
        connection = socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
    except OSError as error:
        if error.errno in _UNSUPPORTED_SOCKET:
            return _unavailable("socket_family_unavailable", error.errno)
        return _unavailable("socket_creation_failed", error.errno)
    with connection:
        try:
            connection.settimeout(_TIMEOUT)
            if udp:
                # A fixed DNS query for privacy-probe.invalid; no user payload.
                query = (b"\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
                         b"\x0dprivacy-probe\x07invalid\x00\x00\x01\x00\x01")
                connection.sendto(query, address)
            else:
                connection.connect(address)
        except TimeoutError:
            result = {"available": True, "denied": True, "errno": None, "reason": "timeout"}
        except OSError as error:
            result = {
                "available": True, "denied": True, "errno": error.errno,
                "reason": "sendto_failed" if udp else "connect_failed",
            }
        else:
            result = {
                "available": True, "denied": False, "errno": None,
                "reason": "sendto_succeeded" if udp else "connect_succeeded",
            }
    if udp:
        # A send timeout or permission error does not establish no route.
        result["noRoute"] = result["errno"] in _NO_ROUTE
    return result


def collect() -> dict:
    """Collect boolean facts and fixed failure classifications, never a verdict."""
    linux = platform.system() == "Linux"
    evidence = {
        "kind": "privacy", "schemaVersion": 1,
        "process_scope": "supervisor_probe", "available": linux,
        "checks": {name: None for name in _CHECK_NAMES},
        "unavailable": {},
        "attempts": {},
    }
    evidence["checks"]["linux"] = linux
    if not linux:
        evidence["unavailable"] = {
            name: {"errno": None, "reason": "non_linux"}
            for name in _CHECK_NAMES if name != "linux"
        }
        evidence["attempts"] = {name: _unavailable("non_linux") for name in _ATTEMPT_NAMES}
        return evidence

    observations: dict[str, Callable[[], bool]] = {
        "guestHostname": lambda: socket.gethostname() == "claude-text-guest",
        "machineIdShape": _machine_id_shape,
        "aarch64": lambda: platform.machine() == "aarch64",
        "nonRootUid": lambda: os.getuid() != 0 and os.geteuid() != 0,
        "interfacesLoopbackOnly": _interfaces_loopback_only,
        "noSharedMounts": _no_shared_mounts,
        "noMacosPaths": lambda: _path_absent("/System") and _path_absent("/Applications"),
        "noClipboardEnv": lambda: not any(
            name in _CLIPBOARD_ENV or "CLIPBOARD" in name.upper() for name in os.environ
        ),
        "noMacosFrameworks": lambda: _path_absent("/System/Library/Frameworks/Security.framework")
            and _path_absent("/usr/lib/libSystem.B.dylib"),
        "environmentAllowlisted": lambda: set(os.environ).issubset(_ENV_ALLOWLIST),
        "noProviderCredentialEnv": _no_credential_environment,
        "noUnapprovedInheritedFds": _no_unapproved_inherited_fds,
        "hostCanaryAbsent": lambda: _path_absent(_CANARY),
        "hostIpcPathAbsent": lambda: _path_absent(_HOST_IPC),
    }
    for name, observe in observations.items():
        try:
            evidence["checks"][name] = observe()
        except _ProbeUnavailable as error:
            evidence["unavailable"][name] = {"errno": None, "reason": error.reason}
        except OSError as error:
            evidence["unavailable"][name] = {"errno": error.errno, "reason": "observation_failed"}
        except UnicodeError:
            evidence["unavailable"][name] = {"errno": None, "reason": "invalid_observation_encoding"}

    evidence["attempts"] = {
        "ipv4Tcp": _socket_attempt(socket.AF_INET, ("198.51.100.1", 443)),
        "ipv6Tcp": _socket_attempt(socket.AF_INET6, ("2001:db8::1", 443, 0, 0)),
        "ipv4DnsUdp": _socket_attempt(socket.AF_INET, ("198.51.100.1", 53), udp=True),
        "ipv6DnsUdp": _socket_attempt(socket.AF_INET6, ("2001:db8::1", 53, 0, 0), udp=True),
        "hostLoopbackHttp": _socket_attempt(socket.AF_INET, ("127.0.0.1", 45789)),
        "hostIpcSocket": _socket_attempt(socket.AF_UNIX, _HOST_IPC),
        # The approved mediation port 40124 is deliberately never contacted.
        "vsockPort1": _socket_attempt(getattr(socket, "AF_VSOCK", None), (2, 1)),
        "vsockPort40125": _socket_attempt(getattr(socket, "AF_VSOCK", None), (2, 40125)),
    }
    return evidence


if __name__ == "__main__":
    print(json.dumps(collect(), sort_keys=True, separators=(",", ":")), flush=True)
