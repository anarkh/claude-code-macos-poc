#!/usr/bin/env python3
"""Build a clean browser base; refuse to overwrite an existing browser disk.

Only immutable public artifacts enter the preparation VM. The disposable build
runner uses NAT for signed Ubuntu packages, then boots a clone with zero NICs.
No host mounts, user credentials, user profiles, or host browser data are used.
Failures preserve the staging directory and exact serial log for diagnosis.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request
import uuid

from kernel_image import extract_kernel

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
GUEST = ROOT / "guest/browser-runtime"
DISK_BYTES = 8 * 1024 ** 3
PINS = {
    "disk.tar.gz": "1800eb56b6b839a08c020551e16fbd8c95b2772452ecce3737a9ad25fe594126",
    "kernel": "e989ab36e015f982493402632ec2b01031e70fad892e182797a82b442a301914",
    "initrd": "f77f65eccd619be537e44a7bb2664048e27f20fc8c8e7d4eeb5cf63d0c8cd213",
}
VERSION = "157.0.1"
FIREFOX_BASE = "https://archive.mozilla.org/pub/firefox/releases/" + VERSION + "/"
FIREFOX_PATH = "linux-aarch64/ja/firefox-" + VERSION + ".tar.xz"
FIREFOX_SHA256 = "78bc164f2b16f9f066718576ecbe1b6a59b004aa9a0ab7766878c76a9b8e627c"
KERNEL_ABI = "7.0.0-38-generic"


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("regular_artifact_required:" + str(path))
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def download(url, path, maximum=100 * 1024 * 1024):
    partial = path.with_suffix(path.suffix + ".partial")
    count = 0
    with urllib.request.urlopen(url, timeout=30) as source, partial.open("wb") as target:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            count += len(block)
            if count > maximum:
                raise RuntimeError("public_artifact_too_large")
            target.write(block)
    partial.replace(path)


def run_vm(runner, mode, staging, log, timeout):
    print(json.dumps({"kind": "browser_vm_boot", "mode": mode, "serial_log": str(log)}), flush=True)
    result = subprocess.run([str(runner), mode, str(staging), str(log), str(timeout)],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout + 30)
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise RuntimeError("browser_vm_failed:" + mode + ":" + str(result.returncode) + ":" + result.stderr[-1000:])
    return result.stdout


def extract_evidence(log, prefix, evidence):
    serial = log.read_text(errors="replace").replace("\r", "")
    begin, end = "BROWSER_DIAGNOSTIC_BEGIN\n", "\nBROWSER_DIAGNOSTIC_END"
    receipt = json.loads(serial.split(begin)[-1].split(end)[0])
    (evidence / (prefix + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
    screenshot = serial.split("BROWSER_SCREENSHOT_BEGIN\n")[-1].split("\nBROWSER_SCREENSHOT_END")[0]
    (evidence / (prefix + ".png")).write_bytes(base64.b64decode(screenshot, validate=True))
    if not receipt["system_root_owned"] or not receipt["sandbox_not_disabled"] or not receipt["processes"]:
        raise RuntimeError("browser_guest_diagnostic_failed")
    if any(process["security"]["Uid"].split()[0] != "59998" for process in receipt["processes"]):
        raise RuntimeError("browser_not_unprivileged")
    if "1280x800" not in receipt["display"] or not any("firefox" in window.lower() for window in receipt["windows"]):
        raise RuntimeError("browser_graphical_window_missing")
    return receipt


def extract_kernel_packages(log):
    serial = log.read_text(errors="replace").replace("\r", "")
    begin, end = "BROWSER_KERNEL_PROVENANCE_BEGIN\n", "\nBROWSER_KERNEL_PROVENANCE_END"
    if serial.count(begin) != 1 or serial.count(end) != 1:
        raise RuntimeError("browser_kernel_package_receipt_missing")
    payload = serial.split(begin, 1)[1].split(end, 1)[0]
    if len(payload) > 16384:
        raise RuntimeError("browser_kernel_package_receipt_too_large")
    receipt = json.loads(payload)
    if (type(receipt) is not dict or set(receipt) != {"schema", "abi", "packages"}
            or receipt["schema"] != "browser-kernel-packages/v1" or receipt["abi"] != KERNEL_ABI
            or type(receipt["packages"]) is not list or len(receipt["packages"]) != 2):
        raise RuntimeError("browser_kernel_package_receipt_invalid")
    expected = {"linux-image-" + KERNEL_ABI, "linux-modules-" + KERNEL_ABI}
    found = set()
    for package in receipt["packages"]:
        if (type(package) is not dict or set(package) != {"name", "version", "architecture", "apt_policy"}
                or type(package["name"]) is not str or package["name"] not in expected or package["name"] in found
                or type(package["version"]) is not str or not 1 <= len(package["version"]) <= 128
                or package["architecture"] != "arm64" or type(package["apt_policy"]) is not str
                or not 1 <= len(package["apt_policy"]) <= 8192):
            raise RuntimeError("browser_kernel_package_receipt_invalid")
        found.add(package["name"])
    if len({package["version"] for package in receipt["packages"]}) != 1:
        raise RuntimeError("browser_kernel_module_package_version_mismatch")
    return receipt


def validate_verification_serial(log):
    serial = log.read_text(errors="replace").replace("\r", "")
    if re.search(r"\b(?:BUG:|Oops:|Kernel panic\b|kernel BUG at\b|Internal error:)", serial, re.IGNORECASE):
        raise RuntimeError("browser_verification_kernel_fault")
    lines = set(serial.splitlines())
    for marker in ("BROWSER_SESSION_READY", "BROWSER_ACPI_STOP_READY"):
        if marker not in lines:
            raise RuntimeError("browser_verification_marker_missing:" + marker)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=HERE / "images")
    parser.add_argument("--public-image-dir", type=Path, default=ROOT / "host/images")
    parser.add_argument("--runner", type=Path, default=HERE / ".build/prepare-browser-vm")
    arguments = parser.parse_args()
    output = arguments.output_dir.absolute()
    if output.exists():
        raise RuntimeError("output_directory_already_exists")
    for name, expected in PINS.items():
        if digest(arguments.public_image_dir / name) != expected:
            raise RuntimeError("public_artifact_pin_mismatch:" + name)
    cache = HERE / "downloads"
    cache.mkdir(parents=True, exist_ok=True)
    checksum = cache / "firefox-SHA256SUMS"
    download(FIREFOX_BASE + "SHA256SUMS", checksum, 2 * 1024 * 1024)
    sums = {line.split()[1].lstrip("*"): line.split()[0] for line in checksum.read_text().splitlines() if len(line.split()) == 2}
    if sums.get(FIREFOX_PATH) != FIREFOX_SHA256:
        raise RuntimeError("official_firefox_checksum_pin_changed")
    firefox = cache / "firefox.tar.xz"
    if not firefox.exists() or digest(firefox) != FIREFOX_SHA256:
        download(FIREFOX_BASE + FIREFOX_PATH, firefox)
    if digest(firefox) != FIREFOX_SHA256:
        raise RuntimeError("official_firefox_artifact_digest_mismatch")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".browser-base-", dir=output.parent))
    print(json.dumps({"kind": "browser_build_staging", "path": str(staging)}), flush=True)
    began = time.monotonic()
    try:
        for name in ("kernel", "initrd"):
            shutil.copyfile(arguments.public_image_dir / name, staging / name)
        with tarfile.open(arguments.public_image_dir / "disk.tar.gz", "r:gz") as archive:
            members = [member for member in archive.getmembers() if member.isfile() and member.name.endswith(".img")]
            if len(members) != 1 or members[0].size > DISK_BYTES:
                raise RuntimeError("pristine_raw_archive_invalid")
            with archive.extractfile(members[0]) as source, (staging / "guest.raw").open("xb") as target:
                shutil.copyfileobj(source, target)
        with (staging / "guest.raw").open("r+b") as disk:
            disk.truncate(DISK_BYTES)
        with (staging / "profile.raw").open("xb") as profile:
            profile.truncate(2 * 1024 ** 3)
        seed = staging / "seed"
        seed.mkdir(mode=0o700)
        # ISO 9660 allows only one dot; keep this immutable public payload name
        # portable instead of relying on macOS's Joliet name handling in Linux.
        shutil.copyfile(firefox, seed / "firefox.txz")
        with tarfile.open(seed / "runtime.tar", "w") as archive:
            for file in sorted(GUEST.iterdir()):
                if file.is_file() and not file.is_symlink():
                    archive.add(file, arcname=file.name)
        prepare = GUEST / "prepare.sh"
        configuration = {
            "hostname": "browser-guest", "manage_etc_hosts": False,
            "growpart": {"mode": "off"}, "resize_rootfs": False,
            "ssh_deletekeys": True, "ssh_genkeytypes": [], "disable_root": True, "users": [],
            "write_files": [{"path": "/opt/browser-prepare.sh", "owner": "root:root", "permissions": "0700",
                             "encoding": "b64", "content": base64.b64encode(prepare.read_bytes()).decode("ascii")}],
            "runcmd": [["bash", "/opt/browser-prepare.sh"]],
            "power_state": {"mode": "poweroff", "timeout": 5, "condition": True},
        }
        (seed / "user-data").write_text("#cloud-config\n" + json.dumps(configuration) + "\n")
        (seed / "meta-data").write_text("instance-id: browser-build-" + str(uuid.uuid4()) + "\nlocal-hostname: browser-guest\n")
        (seed / "browser-config.json").write_text(json.dumps({"schema": "browser-session-config/v1", "resist_fingerprinting": False, "boot_epoch_seconds": int(time.time())}) + "\n")
        (seed / "build-utc-epoch").write_text(str(int(time.time())) + "\n")
        # Only the disposable preparation VM is allowed to receive a DHCP NIC.
        (seed / "network-config").write_text("version: 2\nethernets:\n  preparation:\n    match:\n      name: 'en*'\n    dhcp4: true\n")
        subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata",
                        "-o", str(staging / "seed.iso"), str(seed)], check=True, capture_output=True)
        evidence = staging / "evidence"
        evidence.mkdir()
        # Check and expand the target filesystem while unmounted, inside a
        # disposable public-only Linux VM. The helper root is its own APFS clone.
        check = staging / "offline-check"
        check.mkdir()
        for name in ("kernel", "initrd"):
            shutil.copyfile(staging / name, check / name)
        subprocess.run(["/bin/cp", "-c", str(staging / "guest.raw"), str(check / "guest.raw")], check=True)
        os.link(staging / "guest.raw", check / "profile.raw")
        check_seed = check / "seed"
        check_seed.mkdir()
        check_config = {"hostname": "browser-offline-check", "users": [], "ssh_genkeytypes": [],
            "growpart": {"mode": "off"}, "resize_rootfs": False,
            "runcmd": [["sh", "-c", "e2fsck -fn /dev/vdb > /dev/hvc0 2>&1 && resize2fs /dev/vdb > /dev/hvc0 2>&1 && e2fsck -fn /dev/vdb > /dev/hvc0 2>&1 && echo BROWSER_OFFLINE_FS_READY > /dev/hvc0"]],
            "power_state": {"mode": "poweroff", "timeout": 5, "condition": True}}
        (check_seed / "user-data").write_text("#cloud-config\n" + json.dumps(check_config) + "\n")
        (check_seed / "meta-data").write_text("instance-id: browser-offline-" + str(uuid.uuid4()) + "\n")
        subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata",
                        "-o", str(check / "seed.iso"), str(check_seed)], check=True, capture_output=True)
        run_vm(arguments.runner.absolute(), "check", check, evidence / "offline-check.serial.log", 180)
        if "BROWSER_OFFLINE_FS_READY" not in (evidence / "offline-check.serial.log").read_text(errors="replace"):
            raise RuntimeError("browser_pristine_offline_filesystem_check_failed")
        shutil.rmtree(check)
        run_vm(arguments.runner.absolute(), "prepare", staging, evidence / "prepare.serial.log", 1800)
        if "BROWSER_BASE_READY" not in (evidence / "prepare.serial.log").read_text(errors="replace"):
            raise RuntimeError("browser_base_ready_missing")
        kernel_packages = extract_kernel_packages(evidence / "prepare.serial.log")
        exports = staging / "exports"
        original_kernel_sha256 = digest(exports / "kernel")
        exported_initrd_sha256 = digest(exports / "initrd")
        kernel_extraction = extract_kernel(exports / "kernel", staging / "kernel")
        shutil.copyfile(exports / "initrd", staging / "initrd")
        if (kernel_extraction["container_hash"] != original_kernel_sha256
                or kernel_extraction["derived_hash"] != digest(staging / "kernel")
                or digest(staging / "initrd") != exported_initrd_sha256):
            raise RuntimeError("browser_exported_boot_artifact_digest_mismatch")
        # Actual no-NIC boot validation uses a disposable root clone, blank
        # profile and the same bounded configuration ISO as production.
        verification = staging / "verification"
        verification.mkdir()
        for name in ("kernel", "initrd"):
            shutil.copyfile(staging / name, verification / name)
        subprocess.run(["/bin/cp", "-c", str(staging / "guest.raw"), str(verification / "guest.raw")], check=True)
        with (verification / "profile.raw").open("xb") as profile:
            profile.truncate(2 * 1024 ** 3)
        verify_seed = verification / "seed"
        verify_seed.mkdir()
        shutil.copyfile(seed / "browser-config.json", verify_seed / "browser-config.json")
        subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "browsercfg",
                        "-o", str(verification / "seed.iso"), str(verify_seed)], check=True, capture_output=True)
        run_vm(arguments.runner.absolute(), "verify", verification, evidence / "no-nic.serial.log", 240)
        validate_verification_serial(evidence / "no-nic.serial.log")
        verify_receipt = extract_evidence(evidence / "no-nic.serial.log", "no-nic", evidence)
        if verify_receipt["network_interfaces"] != ["lo"]:
            raise RuntimeError("production_verification_nic_present")
        shutil.rmtree(verification)
        provenance = {
            "schema": "browser-source-provenance/v1",
            "ubuntu": {"release": "noble/release-20260926", "source": "https://cloud-images.ubuntu.com/releases/noble/release-20260926/",
                       "sha256": PINS, "apt_dependency_integrity": "Ubuntu archive InRelease signatures checked by apt-get",
                       "base_integrity": "Pinned artifact SHA256; original cloud-image GPG signature was not verified"},
            "kernel": {"abi": KERNEL_ABI, "source": "Signed Ubuntu apt archive; actual installed package versions and repository policy below",
                       "packages": kernel_packages["packages"],
                       "apt_integrity": "apt-get rejects insecure repositories and unauthenticated packages; Ubuntu InRelease signatures and package hashes checked by apt",
                       "independent_signature_verification": "Kernel Authenticode signature and archive key fingerprint were not independently verified",
                       "source_artifact": "/boot/vmlinuz-" + KERNEL_ABI,
                       "source_vmlinuz_sha256": original_kernel_sha256,
                       "derived_image_sha256": kernel_extraction["derived_hash"],
                       "initrd_source_artifact": "/boot/initrd.img-" + KERNEL_ABI,
                       "initrd_sha256": exported_initrd_sha256, "extraction": kernel_extraction,
                       "export": {"transport": "preparation-only vsock", "host_cid": 2, "port": 40126}},
            "firefox": {"version": VERSION, "locale": "ja", "architecture": "linux-aarch64",
                        "artifact": FIREFOX_BASE + FIREFOX_PATH, "sha256": FIREFOX_SHA256,
                        "checksum_source": FIREFOX_BASE + "SHA256SUMS", "checksum_verification": "HTTPS official SHA256SUMS plus immutable pin; detached GPG signature not verified",
                        "license": "MPL 2.0 and additional licenses; bundled license notices retained. This local managed image is not a redistribution license grant.",
                        "source_archive": FIREFOX_BASE + "source/firefox-" + VERSION + ".source.tar.xz"},
            "build": {"user_data": False, "host_mounts": 0, "nat_only_for_public_dependencies": True},
        }
        (staging / "source-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        (HERE / "source-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        shutil.rmtree(seed)
        (staging / "seed.iso").unlink()
        (staging / "profile.raw").unlink()
        metadata = {"schema": "browser-vm-base/v1", "firefox_version": VERSION, "kernel_abi": KERNEL_ABI,
                    "sha256": {name: digest(staging / name) for name in ("kernel", "initrd", "guest.raw")},
                    "disk_bytes": DISK_BYTES, "locale": "ja", "timezone": "Asia/Tokyo",
                    "prepared": True, "no_user_data": True, "production_network_devices": 0,
                    "production_directory_shares": 0, "vsock_host_cid": 2, "vsock_port": 40125,
                    "display": {"width": 1280, "height": 800}, "profile": "/home/browser/.mozilla/browser",
                    "profile_disk": {"device": "/dev/vdb", "bytes": 2147483648, "label": "browser-profile", "mount": "/home/browser"},
                    "full_resist_fingerprinting": False, "session_config": {"device": "/dev/vdc", "schema": "browser-session-config/v1", "resist_fingerprinting_default": False},
                    "preparation_seconds": round(time.monotonic() - began, 2)}
        (staging / "browser.json").write_text(json.dumps(metadata, indent=2) + "\n")
        for name in ("kernel", "initrd", "guest.raw", "browser.json"):
            (staging / name).chmod(0o400)
        staging.rename(output)
        print(json.dumps({"kind": "browser_base_prepared", "directory": str(output), "firefox_version": VERSION}), flush=True)
    except BaseException:
        print(json.dumps({"kind": "browser_build_failed_preserved", "directory": str(staging)}), flush=True)
        raise


if __name__ == "__main__":
    main()
