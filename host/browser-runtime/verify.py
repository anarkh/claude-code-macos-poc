#!/usr/bin/env python3
"""Two production-layout boots prove RFP behavior and persistent profile disk.

The base never changes. Each boot gets a fresh APFS root clone, the same test
profile disk, zero NICs and a tiny read-only typed config ISO. No user profile
or external site is touched. Successful test scratch disks are removed.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import re

from prepare import HERE, extract_evidence, run_vm, digest, validate_verification_serial
from check_filesystems import check_public_disk


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image-dir", type=Path, default=HERE / "images")
    parser.add_argument("--runner", type=Path, default=HERE / ".build/prepare-browser-vm")
    parser.add_argument("--resume-staging", type=Path)
    parser.add_argument("--short-standard", action="store_true")
    parser.add_argument("--rfp-first", action="store_true")
    parser.add_argument("--evidence-dir", type=Path, default=HERE / "evidence")
    args = parser.parse_args()
    image = args.image_dir.absolute()
    evidence = args.evidence_dir.resolve()
    if evidence != HERE / 'evidence' and HERE / 'evidence' not in evidence.parents:
        raise RuntimeError('owned_verification_evidence_required')
    evidence.mkdir(parents=True, exist_ok=True)
    baseline_seconds = 0
    if args.short_standard:
        baseline_log = evidence / "standard-full150.serial.log"
        validate_verification_serial(baseline_log)
        baseline = json.loads((evidence / "standard-full150.json").read_text())
        clock = re.search(r"systemd.clock-usec=([0-9]+)", baseline_log.read_text(errors="replace"))
        if not clock:
            raise RuntimeError("standard_baseline_boot_clock_missing")
        baseline_seconds = baseline["utc_epoch_seconds"] - int(clock.group(1)) // 1000000
        if (baseline_seconds < 150 or not baseline["system_root_owned"] or baseline["timezone"] != "Asia/Tokyo"
                or baseline["network_interfaces"] != ["lo"] or any(baseline["system_paths_browser_writable"].values())):
            raise RuntimeError("standard_baseline_not_valid")
    staging = args.resume_staging.resolve() if args.resume_staging else Path(tempfile.mkdtemp(prefix=".browser-verify-", dir=HERE))
    if staging.parent != HERE or not staging.name.startswith(".browser-verify-"):
        raise RuntimeError("owned_verification_staging_required")
    print(json.dumps({"kind": "browser_verify_staging", "directory": str(staging)}), flush=True)
    try:
        for name in ("kernel", "initrd"):
            shutil.copyfile(image / name, staging / name)
        if not args.resume_staging:
            with (staging / "profile.raw").open("xb") as profile:
                profile.truncate(2 * 1024 ** 3)
        elif (staging / "profile.raw").stat().st_size != 2 * 1024 ** 3:
            raise RuntimeError("resumed_public_profile_size_invalid")
        seed = staging / "seed"
        seed.mkdir(exist_ok=bool(args.resume_staging))
        receipts = []
        for index, mode in enumerate((True, False) if args.rfp_first else (False, True)):
            name = "rfp" if mode else "standard"
            log = evidence / (name + ".serial.log")
            if not args.resume_staging or mode or args.short_standard:
                disk = staging / "guest.raw"
                if disk.exists():
                    disk.unlink()
                subprocess.run(["/bin/cp", "-c", str(image / "guest.raw"), str(disk)], check=True)
                disk.chmod(0o600)
                (seed / "browser-config.json").write_text(json.dumps({"schema": "browser-session-config/v1", "resist_fingerprinting": mode,
                    "boot_epoch_seconds": int(time.time())}) + "\n")
                iso = staging / "seed.iso"
                if iso.exists():
                    iso.unlink()
                subprocess.run(["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "browsercfg", "-o", str(iso), str(seed)], check=True, capture_output=True)
                if log.exists():
                    raise RuntimeError("verification_evidence_already_exists:" + name)
                run_vm(args.runner.absolute(), "verify-short" if args.short_standard and not mode else "verify", staging, log, 240)
            validate_verification_serial(log)
            lines = set(log.read_text(errors="replace").replace("\r", "").splitlines())
            if "BROWSER_SESSION_STOP_FAILED" in lines or "BROWSER_SESSION_STOP_COMPLETE" not in lines:
                raise RuntimeError("ordered_session_stop_not_verified:" + name)
            if 'BROWSER_FIREFOX_EXIT=0' not in lines or 'BROWSER_CHECKPOINT_COMPLETE=1' not in lines:
                raise RuntimeError('firefox_clean_shutdown_not_verified:' + name)
            receipt = extract_evidence(log, name, evidence)
            if receipt["network_interfaces"] != ["lo"]:
                raise RuntimeError("verification_nic_present")
            if receipt["timezone"] != "Asia/Tokyo":
                raise RuntimeError("verification_system_timezone_mismatch")
            if any(receipt["system_paths_browser_writable"].values()):
                raise RuntimeError("verification_browser_can_modify_system")
            if not receipt["web_observations"]:
                raise RuntimeError("verification_web_hardware_observation_missing")
            for web in receipt["web_observations"]:
                # Firefox 157 normal protection buckets a <8-core Linux guest
                # to 4; the full RFP Linux constant is also 4.
                if not web["platform"].startswith("Linux") or web["hardware_concurrency"] != 4:
                    raise RuntimeError("verification_web_hardware_contract_failed:" + name)
                valid_renderer = web["webgl_renderer"] == "Mozilla" if mode else "llvmpipe" in web["webgl_renderer"].lower()
                if not valid_renderer or web["utc_offset_minutes"] != (0 if mode else 540):
                    raise RuntimeError("verification_unexpected_gpu_renderer:" + name)
            expected = "TZ=Atlantic/Reykjavik LANG=en-US" if mode else "TZ=Asia/Tokyo LANG=ja"
            if not any(expected in window for window in receipt["windows"]):
                raise RuntimeError("web_locale_timezone_contract_failed:" + name)
            content = [process for process in receipt["processes"] if process["content_process"] and process["name"] in ("Web Content", "file:// Content")]
            if not content or not any(process["security"]["Seccomp"] == "2" and process["security"]["NoNewPrivs"] == "1" for process in content):
                raise RuntimeError("content_sandbox_missing:" + name)
            if index and not receipt["build_profile_marker_preexisting"]:
                raise RuntimeError("persistent_profile_not_retained")
            receipts.append({"mode": name, "network_devices": 0, "web": expected,
                             "sandbox_seccomp": True, "profile_preexisting": receipt["build_profile_marker_preexisting"],
                             "cpu_count": 2, "memory_gib": 3, "native_vz_view": True,
                             "gui_observation_seconds": receipt["gui_observation_seconds"], "acpi_stop": True,
                             "ordered_session_stop": True,
                             "firefox_exit_code": 0, "checkpoint_complete": True,
                             "checkpoint_fresh": True, "firefox_close_method": "ewmh-net-close-window",
                             "standard_baseline_observed_seconds": baseline_seconds if not mode else 0,
                             "web_hardware": receipt["web_observations"]})
            print(json.dumps({"kind": "browser_mode_verified", "mode": name, "web_hardware": receipt["web_observations"]}), flush=True)
        filesystems = [check_public_disk(staging / disk, evidence / ("post-acpi-" + disk + ".serial.log"), args.runner.absolute())
                       for disk in ("guest.raw", "profile.raw")]
        (evidence / "verification.json").write_text(json.dumps({"schema": "browser-production-layout-check/v1", "boots": receipts, "filesystems": filesystems,
            "image_sha256": {name: digest(image / name) for name in ("kernel", "initrd", "guest.raw")}}, indent=2) + "\n")
        shutil.rmtree(staging)
        print(json.dumps({"kind": "browser_production_layout_verified", "boots": receipts}), flush=True)
    except BaseException:
        print(json.dumps({"kind": "browser_verification_failed_preserved", "directory": str(staging)}), flush=True)
        raise


if __name__ == "__main__":
    main()
