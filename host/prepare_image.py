#!/usr/bin/env python3
"""Download official test images, verify SHA256, extract only one regular raw disk."""
import concurrent.futures
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent / "images"
BASE = "https://cloud-images.ubuntu.com/releases/noble/release-20260926/"
FILES = {
    "disk.tar.gz": ("", "ubuntu-24.04-server-cloudimg-arm64.tar.gz"),
    "kernel.download": ("unpacked/", "ubuntu-24.04-server-cloudimg-arm64-vmlinuz-generic"),
    "initrd": ("unpacked/", "ubuntu-24.04-server-cloudimg-arm64-initrd-generic"),
}

def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()

def fetch_text(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode("utf-8")

def download(item, sums):
    local, (prefix, name) = item
    expected = sums[prefix].get(name)
    if expected is None:
        raise RuntimeError("official checksum missing for " + name)
    target = ROOT / local
    if not target.exists() or sha(target) != expected:
        partial = target.with_suffix(target.suffix + ".partial")
        size = 0
        with urllib.request.urlopen(BASE + prefix + name, timeout=30) as response, partial.open("wb") as output:
            for data in iter(lambda: response.read(1024 * 1024), b""):
                size += len(data)
                if size > 700 * 1024 * 1024:
                    raise RuntimeError("download exceeds the PoC size limit")
                output.write(data)
        if sha(partial) != expected:
            raise RuntimeError("download SHA256 mismatch for " + name)
        partial.replace(target)
    print(json.dumps({"kind": "image_download_verified", "file": local, "sha256": expected}), flush=True)
    return {"file": local, "source": BASE + prefix + name, "sha256": expected, "size": target.stat().st_size}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reset-test-disk', action='store_true', help='discard this PoC guest disk and create a fresh 8 GiB test disk')
    args = parser.parse_args()
    running = subprocess.run(['/usr/bin/pgrep', '-x', 'vm-poc'], stdout=subprocess.DEVNULL)
    if running.returncode == 0:
        raise RuntimeError('stop vm-poc before preparing its disk')
    if running.returncode != 1:
        raise RuntimeError('cannot verify that vm-poc is stopped')
    ROOT.mkdir(parents=True, exist_ok=True)
    raw = ROOT / 'guest.raw'
    if raw.exists() and not args.reset_test_disk:
        raise RuntimeError('guest.raw already exists; stop the PoC VM and explicitly pass --reset-test-disk to discard it')
    sums = {}
    for prefix in ("", "unpacked/"):
        text = fetch_text(BASE + prefix + "SHA256SUMS")
        sums[prefix] = {line.split()[1].lstrip("*"): line.split()[0] for line in text.splitlines() if len(line.split()) == 2}
        (ROOT / ("unpacked.SHA256SUMS" if prefix else "SHA256SUMS")).write_text(text)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        artifacts = list(pool.map(lambda item: download(item, sums), FILES.items()))
    kernel_download = ROOT / "kernel.download"
    with kernel_download.open("rb") as source:
        magic = source.read(2)
    if magic == b"\x1f\x8b":
        with gzip.open(kernel_download, "rb") as source, (ROOT / "kernel").open("wb") as output:
            shutil.copyfileobj(source, output)
    else:
        shutil.copyfile(kernel_download, ROOT / "kernel")
    with tarfile.open(ROOT / "disk.tar.gz", "r:gz") as archive:
        candidates = [m for m in archive.getmembers() if m.isfile() and m.name.endswith(".img")]
        if len(candidates) != 1:
            raise RuntimeError("expected exactly one regular .img member: " + repr([m.name for m in candidates]))
        member = candidates[0]
        if member.size > 20 * 1024**3:
            raise RuntimeError("raw image exceeds the PoC disk size limit")
        source = archive.extractfile(member)
        if source is None:
            raise RuntimeError("raw member is unavailable")
        first = source.read(4096)
        if first[:4] == b"QFI\xfb":
            raise RuntimeError("archive contains QCow2, a verified RAW conversion is required")
        # Never use extractall: no archive paths/symlinks are installed on the host.
        with raw.open("wb") as output:
            output.write(first)
            shutil.copyfileobj(source, output)
        if raw.stat().st_size != member.size:
            raise RuntimeError("raw image extraction is incomplete")
    original_raw_sha256 = sha(raw)
    with raw.open('r+b') as output:
        output.truncate(8 * 1024**3)
    evidence = {"source": "Ubuntu HTTPS SHA256SUMS; GPG signature not verified", "artifacts": artifacts,
                "raw_archive_member": member.name, "raw_archive_size": member.size,
                "raw_archive_sha256": original_raw_sha256, "test_disk_size": raw.stat().st_size,
                "test_disk_change": "zero-extend disposable raw ext4 disk to 8 GiB; resize2fs inside guest before test payload installation",
                "kernel_sha256": sha(ROOT / "kernel")}
    (ROOT / "provenance.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"kind": "image_prepared", "raw_size": raw.stat().st_size, "raw_member": member.name}), flush=True)

if __name__ == "__main__":
    main()
