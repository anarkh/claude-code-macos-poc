#!/usr/bin/env python3
"""Reconstruct a public-only interrupted build and install signed Ubuntu HWE.

Requires an explicit staging root argument; never reads or modifies profile
disks from the app. Produces a new staging candidate, not a published image.
"""
import argparse
import base64
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import uuid

from prepare import HERE, ROOT, GUEST, PINS, digest, run_vm
from kernel_image import extract_kernel


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--public-build-root", type=Path, required=True)
    args = parser.parse_args()
    source = args.public_build_root.resolve()
    if source.parent != HERE or not source.name.startswith(".browser-base-"):
        raise RuntimeError("only_owned_public_build_staging_allowed")
    for name, expected in PINS.items():
        if digest(ROOT / "host/images" / name) != expected:
            raise RuntimeError("public_artifact_pin_mismatch")
    staging = Path(tempfile.mkdtemp(prefix=".browser-hwe-", dir=HERE))
    print(json.dumps({"kind": "browser_hwe_staging", "directory": str(staging)}), flush=True)
    for name in ("kernel", "initrd"):
        shutil.copyfile(ROOT / "host/images" / name, staging / name)
    # Helper root is pristine and independent; target is an interrupted public
    # build clone. No data-bearing browser profile disk is attached to this VM.
    with tarfile.open(ROOT / "host/images/disk.tar.gz", "r:gz") as archive:
        member = [m for m in archive.getmembers() if m.isfile() and m.name.endswith(".img")][0]
        with archive.extractfile(member) as stream, (staging / "guest.raw").open("xb") as output:
            shutil.copyfileobj(stream, output)
    subprocess.run(["/bin/cp", "-c", str(source / "guest.raw"), str(staging / "profile.raw")], check=True)
    seed = staging / "seed"
    seed.mkdir()
    shutil.copyfile(HERE / "downloads/firefox.tar.xz", seed / "firefox.txz")
    shutil.copyfile(GUEST / "export-public.py", seed / "export-public.py")
    with tarfile.open(seed / "runtime.tar", "w") as archive:
        for file in sorted(GUEST.iterdir()):
            if file.is_file() and not file.is_symlink():
                archive.add(file, arcname=file.name)
    script = GUEST / "recover-hwe.sh"
    config = {"hostname": "browser-public-hwe-builder", "growpart": {"mode": "off"}, "resize_rootfs": False,
              "users": [], "ssh_genkeytypes": [],
              "write_files": [{"path": "/opt/recover-hwe.sh", "owner": "root:root", "permissions": "0700", "encoding": "b64",
                               "content": base64.b64encode(script.read_bytes()).decode()}],
              "runcmd": [["bash", "/opt/recover-hwe.sh"]],
              "power_state": {"mode": "poweroff", "timeout": 5, "condition": True}}
    (seed / "user-data").write_text("#cloud-config\n" + json.dumps(config) + "\n")
    (seed / "meta-data").write_text("instance-id: browser-public-hwe-" + str(uuid.uuid4()) + "\n")
    (seed / "network-config").write_text("version: 2\nethernets:\n  preparation:\n    match:\n      name: 'en*'\n    dhcp4: true\n")
    subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", str(staging / "seed.iso"), str(seed)], check=True, capture_output=True)
    evidence = staging / "evidence"
    evidence.mkdir()
    run_vm(HERE / ".build/prepare-browser-vm", "prepare", staging, evidence / "hwe.serial.log", 1800)
    serial = (evidence / "hwe.serial.log").read_text(errors="replace")
    if "BROWSER_HWE_BASE_READY" not in serial:
        raise RuntimeError("browser_hwe_preparation_failed:" + str(staging))
    exports = staging / "exports"
    (staging / "guest.raw").unlink()
    (staging / "profile.raw").rename(staging / "guest.raw")
    kernel = exports / "kernel"
    extraction = extract_kernel(kernel, staging / "kernel")
    shutil.copyfile(exports / "initrd", staging / "initrd")
    (staging / "candidate.json").write_text(json.dumps({"schema": "browser-public-hwe-candidate/v1", "kernel_release": "7.0.0-38-generic",
        "kernel_package": "linux-image-7.0.0-38-generic", "package_integrity": "Ubuntu apt signature/hash verification", "kernel_extraction": extraction,
        "sha256": {name: digest(staging / name) for name in ("kernel", "initrd", "guest.raw")}}, indent=2) + "\n")
    print(json.dumps({"kind": "browser_hwe_candidate_ready", "directory": str(staging)}), flush=True)


if __name__ == "__main__":
    main()
