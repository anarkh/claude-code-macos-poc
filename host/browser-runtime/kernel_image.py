"""Extract a Linux ARM64 Image without adding host Python dependencies.

``extract_kernel(source, target, node=...)`` returns JSON-compatible provenance.
For EFI zboot images, Node's built-in zstd decoder is discovered from PATH or
the current user's bundled Codex runtime; BROWSER_KERNEL_NODE overrides discovery.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib


ARM64_MAGIC = b"ARM\x64"
ARM64_FORMAT_URL = "https://docs.kernel.org/arch/arm64/booting.html"
ZBOOT_FORMAT_URL = (
    "https://raw.githubusercontent.com/torvalds/linux/master/"
    "drivers/firmware/efi/libstub/zboot-header.S"
)
# Bound decompression memory at the external container boundary.
MAX_IMAGE_BYTES = 512 * 1024 * 1024


def _find_node(node):
    override = node if node is not None else os.environ.get("BROWSER_KERNEL_NODE")
    if override is not None:
        if not str(override).strip():
            raise ValueError("Node override must name an executable")
        candidates = [str(override)]
    else:
        candidates = [
            shutil.which("node"),
            str(Path.home() / ".cache/codex-runtimes/codex-primary-runtime/"
                "dependencies/node/bin/node"),
        ]

    errors = []
    for candidate in dict.fromkeys(candidates):
        if candidate is None:
            continue
        candidate = os.path.expanduser(candidate)
        probe = (
            "if (typeof require('node:zlib').zstdDecompressSync !== 'function') "
            "{ throw new Error('zstdDecompressSync is unavailable'); }"
        )
        try:
            result = subprocess.run(
                [candidate, "-e", probe], capture_output=True, timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            errors.append(f"{candidate}: {exc}")
            continue
        if result.returncode == 0:
            return candidate
        reason = result.stderr.decode("utf-8", errors="replace").strip()
        errors.append(f"{candidate}: {reason or 'capability probe failed'}")

    detail = "; ".join(errors)
    raise ValueError(
        "EFI zboot extraction needs Node with node:zlib.zstdDecompressSync "
        "(available in Node 24). Pass node=..., --node, or BROWSER_KERNEL_NODE. "
        + detail
    )


def _decompress_zstd(payload, node):
    executable = _find_node(node)
    script = (
        "const fs = require('node:fs'); const z = require('node:zlib'); "
        "try { fs.writeFileSync(1, z.zstdDecompressSync(fs.readFileSync(0), "
        f"{{maxOutputLength: {MAX_IMAGE_BYTES}}}"
        ")); } catch (e) { console.error(e.message); process.exit(1); }"
    )
    try:
        result = subprocess.run(
            [executable, "-e", script], input=payload, capture_output=True,
            timeout=60, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValueError(f"Could not run Node's zstd decoder: {exc}") from exc
    if result.returncode != 0:
        reason = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"Invalid zstd kernel payload: {reason or 'decoder failed'}")
    return result.stdout


def extract_kernel(source, target, *, node=None):
    """Validate and atomically write raw Image, gzip Image, or zstd EFI zboot.

    Invalid input leaves an existing target unchanged. Hashes are SHA-256 of
    the full source container and the exact Image written to target.
    """
    source = Path(source)
    target = Path(target)
    if source.resolve() == target.resolve():
        raise ValueError("Source container and target Image must be different files")
    container = source.read_bytes()
    payload_offset = None
    payload_size = None

    if len(container) >= 64 and container[56:60] == ARM64_MAGIC:
        image = container
        image_format = "arm64-image"
        compression = "none"
        format_reference = ARM64_FORMAT_URL
    elif container.startswith(b"\x1f\x8b"):
        try:
            with gzip.GzipFile(fileobj=io.BytesIO(container)) as compressed:
                image = compressed.read(MAX_IMAGE_BYTES + 1)
        except (OSError, EOFError, zlib.error) as exc:
            raise ValueError(f"Invalid gzip kernel container: {exc}") from exc
        image_format = "gzip"
        compression = "gzip"
        format_reference = ARM64_FORMAT_URL
    elif container.startswith(b"MZ\x00\x00zimg"):
        if len(container) < 64:
            raise ValueError("Truncated EFI zboot header (requires 64 bytes)")
        payload_offset, payload_size = struct.unpack_from("<II", container, 8)
        if payload_offset < 64 or payload_offset > len(container):
            raise ValueError("EFI zboot payload offset is outside the container")
        if payload_size == 0 or payload_size > len(container) - payload_offset:
            raise ValueError("EFI zboot payload size is outside the container")
        compression_field = container[24:56]
        if b"\x00" not in compression_field:
            raise ValueError("EFI zboot compression type is not NUL-terminated")
        try:
            compression = compression_field.split(b"\x00", 1)[0].decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError("EFI zboot compression type must be ASCII") from exc
        if compression != "zstd":
            raise ValueError(f"Unsupported EFI zboot compression: {compression!r}")
        image = _decompress_zstd(
            container[payload_offset:payload_offset + payload_size], node,
        )
        image_format = "efi-zboot"
        format_reference = ZBOOT_FORMAT_URL
    else:
        raise ValueError("Unsupported kernel container: expected ARM64 Image, gzip, or EFI zboot")

    if len(image) > MAX_IMAGE_BYTES:
        raise ValueError(f"Derived kernel Image exceeds {MAX_IMAGE_BYTES} bytes")
    if len(image) < 64 or image[56:60] != ARM64_MAGIC:
        raise ValueError("Derived kernel lacks the 64-byte ARM64 Image header/magic at offset 56")

    metadata = {
        "format": image_format,
        "compression": compression,
        "container_size": len(container),
        "derived_size": len(image),
        "container_hash": hashlib.sha256(container).hexdigest(),
        "derived_hash": hashlib.sha256(image).hexdigest(),
        "hash_algorithm": "sha256",
        "format_reference": format_reference,
        "zboot_format_reference": ZBOOT_FORMAT_URL,
    }
    if payload_offset is not None:
        metadata.update(payload_offset=payload_offset, payload_size=payload_size)

    target.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
            temporary_path = Path(output.name)
            output.write(image)
        os.replace(temporary_path, target)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("--node", help="Node executable providing zstdDecompressSync")
    args = parser.parse_args()
    try:
        metadata = extract_kernel(args.source, args.target, node=args.node)
    except (OSError, ValueError) as exc:
        print(f"kernel extraction failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(metadata, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
