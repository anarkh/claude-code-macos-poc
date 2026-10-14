#!/usr/bin/python3
"""Mount only the dedicated browser profile block device; never repair data.

Unknown nonzero media fails closed. The only formatting admission is an exact
2-GiB raw disk whose every byte is zero, created by the app for first use.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

DEVICE = "/dev/vdb"
SIZE = 2 * 1024 ** 3
HOME = Path("/home/browser")


def run(arguments):
    return subprocess.run(arguments, capture_output=True, text=True, check=True).stdout.strip()


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "unmount":
        run(["/usr/bin/umount", str(HOME)])
        return
    if int(run(["/usr/sbin/blockdev", "--getsize64", DEVICE])) != SIZE:
        raise RuntimeError("profile_disk_size_invalid")
    result = subprocess.run(["/usr/sbin/blkid", "-p", "-o", "export", DEVICE], capture_output=True, text=True)
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    fresh = False
    if result.returncode == 2 and not fields:
        zero = bytes(1024 * 1024)
        with open(DEVICE, "rb", buffering=0) as disk:
            remaining = SIZE
            while remaining:
                block = disk.read(min(len(zero), remaining))
                if not block or block != zero[:len(block)]:
                    raise RuntimeError("nonzero_unknown_profile_disk")
                remaining -= len(block)
            if disk.read(1):
                raise RuntimeError("profile_disk_size_changed")
        run(["/usr/sbin/mkfs.ext4", "-q", "-m", "0", "-L", "browser-profile", DEVICE])
        fresh = True
    elif result.returncode != 0 or fields.get("TYPE") != "ext4" or fields.get("LABEL") != "browser-profile":
        raise RuntimeError("profile_disk_identity_invalid")
    HOME.mkdir(mode=0o700, parents=True, exist_ok=True)
    run(["/usr/bin/mount", "-o", "nodev,nosuid", DEVICE, str(HOME)])
    if fresh:
        os.chown(HOME, 59998, 59998)
        HOME.chmod(0o700)
        lost = HOME / "lost+found"
        if lost.exists():
            lost.chmod(0o700)
    elif HOME.stat().st_uid != 59998 or HOME.stat().st_gid != 59998:
        run(["/usr/bin/umount", str(HOME)])
        raise RuntimeError("profile_home_owner_invalid")
    with open("/dev/hvc0", "w") as serial:
        serial.write("BROWSER_PROFILE_READY\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # The diagnostic contains a fixed error class/code, never profile data.
        with open("/dev/hvc0", "w") as serial:
            serial.write("BROWSER_PROFILE_FAILED\n")
        print(json.dumps({"kind": "browser_profile_failed", "error": str(error)}), file=sys.stderr)
        raise SystemExit(1)
