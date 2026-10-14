#!/usr/bin/env python3
"""Apply current guest runtime to an owned public candidate while unmounted."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import uuid

from prepare import HERE, ROOT, GUEST, PINS, digest, run_vm


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()
    source = args.candidate.resolve()
    if source.parent != HERE or not source.name.startswith((".browser-hwe-", ".browser-patched-", ".browser-base-")):
        raise RuntimeError("owned_public_candidate_required")
    for name, expected in PINS.items():
        if digest(ROOT / "host/images" / name) != expected:
            raise RuntimeError("public_artifact_pin_mismatch")
    staging = Path(tempfile.mkdtemp(prefix=".browser-patched-", dir=HERE))
    for name in ("kernel", "initrd"):
        shutil.copyfile(ROOT / "host/images" / name, staging / name)
    with tarfile.open(ROOT / "host/images/disk.tar.gz", "r:gz") as archive:
        member = [m for m in archive.getmembers() if m.isfile() and m.name.endswith(".img")][0]
        with archive.extractfile(member) as inp, (staging / "guest.raw").open("xb") as out:
            shutil.copyfileobj(inp, out)
    subprocess.run(["/bin/cp", "-c", str(source / "guest.raw"), str(staging / "profile.raw")], check=True)
    seed = staging / "seed"
    seed.mkdir()
    with tarfile.open(seed / "runtime.tar", "w") as archive:
        for file in sorted(GUEST.iterdir()):
            if file.is_file() and not file.is_symlink():
                archive.add(file, arcname=file.name)
    script = """set -eux
trap 'echo BROWSER_PUBLIC_PATCH_EXIT=$?' EXIT
e2fsck -fn /dev/vdb
mkdir -p /mnt/public /mnt/seed
mount /dev/vdb /mnt/public
mount -o ro /dev/vdc /mnt/seed
tar -xf /mnt/seed/runtime.tar -C /mnt/public/opt/browser
chown -R root:root /mnt/public/opt/browser /mnt/public/opt/firefox
chmod -R go-w /mnt/public/opt/browser
chmod 0755 /mnt/public/opt/browser/*.sh /mnt/public/opt/browser/proxy.py
python3 /mnt/public/opt/browser/openbox-config.py --root /mnt/public
install -m 0644 /mnt/public/opt/browser/*.service /mnt/public/etc/systemd/system/
rm -f /mnt/public/etc/apparmor.d/browser-firefox
install -m 0644 /mnt/public/opt/browser/firefox.apparmor /mnt/public/etc/apparmor.d/firefox
cat /mnt/public/etc/apparmor.d/firefox
rm -f /mnt/public/usr/lib/locale/locale-archive
chroot /mnt/public locale-gen ja_JP.UTF-8
chroot /mnt/public update-locale LANG=ja_JP.UTF-8
printf 'Asia/Tokyo\\n' > /mnt/public/etc/timezone
ln -sf /usr/share/zoneinfo/Asia/Tokyo /mnt/public/etc/localtime
install -m 0644 /mnt/public/opt/browser/browser.cfg /mnt/public/opt/firefox/browser.cfg
install -m 0644 /mnt/public/opt/browser/policies.json /mnt/public/opt/firefox/distribution/policies.json
python3 -u - <<'VERIFY_PACKAGES'
import re
import subprocess
print('BROWSER_PACKAGE_VERIFY_START', flush=True)
result = subprocess.run(['chroot', '/mnt/public', 'dpkg', '--verify'], capture_output=True, text=True)
print('BROWSER_PACKAGE_VERIFY_EXIT=' + str(result.returncode), flush=True)
print(result.stdout, end='', flush=True)
print(result.stderr, end='', flush=True)
if result.returncode not in (0, 1) or result.stderr:
    raise RuntimeError('public_package_verification_failed')
for line in result.stdout.splitlines():
    if re.fullmatch(r'missing\\s+/(?:var/cache/apt(?:/.*)?|var/lib/apt/lists/partial|var/log(?:/.*)?)', line):
        continue
    if line.startswith('??5') and line.endswith(' /etc/apparmor.d/firefox'):
        continue
    raise RuntimeError('unexpected_public_package_digest_mismatch:' + line)
VERIFY_PACKAGES
rm -rf /mnt/public/var/log/* /mnt/public/var/lib/cloud/*
truncate -s 0 /mnt/public/etc/machine-id
sync
umount /mnt/public
e2fsck -fn /dev/vdb
echo BROWSER_PUBLIC_PATCH_READY
"""
    import base64
    cfg = {"users": [], "ssh_genkeytypes": [], "growpart": {"mode": "off"}, "resize_rootfs": False,
        "write_files": [{"path": "/opt/public-patch.sh", "permissions": "0700", "encoding": "b64", "content": base64.b64encode(script.encode()).decode()}],
        "runcmd": [["sh", "-c", "sh /opt/public-patch.sh > /var/log/browser-public-patch.log 2>&1; code=$?; cat /var/log/browser-public-patch.log > /dev/hvc0; echo BROWSER_PUBLIC_PATCH_WRAPPER_EXIT=$code > /dev/hvc0; exit $code"]],
        "power_state": {"mode": "poweroff", "timeout": 5, "condition": True}}
    (seed / "user-data").write_text("#cloud-config\n" + json.dumps(cfg) + "\n")
    (seed / "meta-data").write_text("instance-id: public-patch-" + str(uuid.uuid4()) + "\n")
    subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", str(staging / "seed.iso"), str(seed)], check=True, capture_output=True)
    run_vm(HERE / ".build/prepare-browser-vm", "check", staging, staging / "patch.serial.log", 180)
    if "BROWSER_PUBLIC_PATCH_READY" not in (staging / "patch.serial.log").read_text(errors="replace"):
        raise RuntimeError("public_candidate_patch_failed:" + str(staging))
    (staging / "guest.raw").unlink()
    (staging / "profile.raw").rename(staging / "guest.raw")
    for name in ("kernel", "initrd"):
        shutil.copyfile(source / name, staging / name)
    if (source / "candidate.json").exists():
        shutil.copyfile(source / "candidate.json", staging / "candidate.json")
    print(json.dumps({"kind": "browser_public_patch_ready", "directory": str(staging)}), flush=True)


if __name__ == "__main__":
    main()
