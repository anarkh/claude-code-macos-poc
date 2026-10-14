#!/usr/bin/env python3
"""Check stopped public build/test disks inside a disposable no-NIC helper."""
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import uuid

from prepare import HERE, ROOT, PINS, digest, run_vm


def check_public_disk(disk, log, runner=None):
    disk = Path(disk).resolve()
    if (disk.parent.parent != HERE or not disk.parent.name.startswith(
            (".browser-base-", ".browser-verify-", ".browser-hwe-", ".browser-patched-"))
            or disk.name not in ("guest.raw", "profile.raw") or not disk.is_file()):
        raise RuntimeError("owned_stopped_public_build_disk_required")
    for name, expected in PINS.items():
        if digest(ROOT / "host/images" / name) != expected:
            raise RuntimeError("public_artifact_pin_mismatch")
    staging = Path(tempfile.mkdtemp(prefix=".browser-fsck-", dir=HERE))
    for name in ("kernel", "initrd"):
        shutil.copyfile(ROOT / "host/images" / name, staging / name)
    with tarfile.open(ROOT / "host/images/disk.tar.gz", "r:gz") as archive:
        member = [m for m in archive.getmembers() if m.isfile() and m.name.endswith(".img")][0]
        with archive.extractfile(member) as inp, (staging / "guest.raw").open("xb") as out:
            shutil.copyfileobj(inp, out)
    subprocess.run(["/bin/cp", "-c", str(disk), str(staging / "profile.raw")], check=True)
    (staging / "profile.raw").chmod(0o600)
    seed = staging / "seed"
    seed.mkdir()
    cfg = {"users": [], "ssh_genkeytypes": [], "growpart": {"mode": "off"}, "resize_rootfs": False,
           "runcmd": [["sh", "-c", "e2fsck -fn /dev/vdb > /dev/hvc0 2>&1 && echo BROWSER_FS_CHECK_READY > /dev/hvc0"]],
           "power_state": {"mode": "poweroff", "timeout": 5, "condition": True}}
    (seed / "user-data").write_text("#cloud-config\n" + json.dumps(cfg) + "\n")
    (seed / "meta-data").write_text("instance-id: browser-fsck-" + str(uuid.uuid4()) + "\n")
    subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata",
                    "-o", str(staging / "seed.iso"), str(seed)], check=True, capture_output=True)
    run_vm(Path(runner or HERE / ".build/prepare-browser-vm"), "check", staging, Path(log), 180)
    serial = Path(log).read_text(errors="replace")
    if "BROWSER_FS_CHECK_READY" not in serial:
        raise RuntimeError("public_build_disk_fsck_failed:" + str(staging))
    shutil.rmtree(staging)
    return {"disk": disk.name, "bytes": disk.stat().st_size, "e2fsck": "-fn", "result": "clean", "repair": False}


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("disk", type=Path)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    print(json.dumps(check_public_disk(args.disk, args.log)), flush=True)
