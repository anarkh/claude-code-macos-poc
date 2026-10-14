#!/usr/bin/env python3
"""Publish a fresh public candidate only after both production-layout checks."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

from prepare import HERE, PINS, VERSION, DISK_BYTES, KERNEL_ABI, FIREFOX_BASE, FIREFOX_PATH, FIREFOX_SHA256, digest, extract_kernel_packages
from kernel_image import extract_kernel


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--fresh-build", type=Path, required=True)
    parser.add_argument("--shutdown-verification", type=Path)
    parser.add_argument("--current-shutdown-verification", type=Path)
    parser.add_argument("--shutdown-baseline", type=Path)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    candidate, build = args.candidate.resolve(), args.fresh_build.resolve()
    if (candidate.parent != HERE or not candidate.name.startswith(".browser-patched-")
            or build.parent != HERE or not build.name.startswith(".browser-base-")):
        raise RuntimeError("owned_fresh_public_build_required")
    output = HERE / "images"
    if output.exists() and not args.replace:
        raise RuntimeError("published_images_already_exist")
    if args.replace and not args.shutdown_verification:
        raise RuntimeError('clean_shutdown_verification_required_for_replacement')
    baseline_receipt_path = HERE / "evidence/verification.json"
    verification = json.loads(baseline_receipt_path.read_text())
    if ({boot["mode"] for boot in verification["boots"]} != {"standard", "rfp"}
            or not all(boot["acpi_stop"] and boot["ordered_session_stop"] and (boot["gui_observation_seconds"] >= 150
                or boot["mode"] == "standard" and boot["gui_observation_seconds"] >= 8
                    and boot["standard_baseline_observed_seconds"] >= 150) for boot in verification["boots"])
            or len(verification["filesystems"]) != 2
            or any(fs["result"] != "clean" or fs["repair"] for fs in verification["filesystems"])):
        raise RuntimeError("production_checks_not_complete")
    shutdown = None
    current_shutdown = None
    if bool(args.current_shutdown_verification) != bool(args.shutdown_baseline):
        raise RuntimeError('shutdown_diagnostic_derivation_arguments_required_together')
    if args.shutdown_verification:
        receipt_path = args.shutdown_verification.resolve()
        if HERE / 'evidence' not in receipt_path.parents:
            raise RuntimeError('owned_shutdown_receipt_required')
        shutdown = json.loads(receipt_path.read_text())
        if (shutdown['schema'] != 'browser-clean-shutdown-check/v1'
                or {boot['mode'] for boot in shutdown['boots']} != {'standard', 'rfp'}
                or not all(boot['firefox_exit_code'] == 0 and boot['checkpoint_complete'] is True
                    and boot['checkpoint_fresh'] is True and boot['acpi_stop'] is True
                    and boot['native_vz_view'] is True and boot['gui_observation_seconds'] >= 150
                    and boot['diagnostic_scrot_enabled'] is False
                    and boot['firefox_close_method'] == 'ewmh-net-close-window' for boot in shutdown['boots'])
                or len(shutdown['filesystems']) != 2
                or any(fs['result'] != 'clean' or fs['repair'] for fs in shutdown['filesystems'])
                or shutdown['profile_contents_collected'] is not False):
            raise RuntimeError('clean_shutdown_checks_not_complete')
    if args.current_shutdown_verification:
        if not shutdown:
            raise RuntimeError('long_shutdown_baseline_receipt_required')
        current_receipt_path = args.current_shutdown_verification.resolve()
        if HERE / 'evidence' not in current_receipt_path.parents:
            raise RuntimeError('owned_current_shutdown_receipt_required')
        current_shutdown = json.loads(current_receipt_path.read_text())
        if (current_shutdown['schema'] != 'browser-clean-shutdown-check/v1'
                or len(current_shutdown['boots']) != 1 or current_shutdown['boots'][0]['mode'] != 'standard'
                or not all(boot['firefox_exit_code'] == 0 and boot['checkpoint_complete'] is True
                    and boot['checkpoint_fresh'] is True and boot['acpi_stop'] is True
                    and boot['native_vz_view'] is True and boot['gui_observation_seconds'] >= 8
                    and boot['diagnostic_scrot_enabled'] is False
                    and boot['firefox_close_method'] == 'ewmh-net-close-window' for boot in current_shutdown['boots'])
                or len(current_shutdown['filesystems']) != 2
                or any(fs['result'] != 'clean' or fs['repair'] for fs in current_shutdown['filesystems'])
                or current_shutdown['profile_contents_collected'] is not False):
            raise RuntimeError('current_shutdown_checks_not_complete')
        shutdown_baseline = args.shutdown_baseline.resolve()
        if shutdown_baseline.parent != HERE or not shutdown_baseline.name.startswith('.browser-patched-'):
            raise RuntimeError('owned_shutdown_baseline_required')
        baseline_hashes = {name: digest(shutdown_baseline / name) for name in ('kernel', 'initrd', 'guest.raw')}
        if baseline_hashes != shutdown['image_sha256']:
            raise RuntimeError('long_shutdown_baseline_artifact_hash_mismatch')
        def runtime_files(directory):
            with tarfile.open(directory / 'seed/runtime.tar') as archive:
                return {member.name: archive.extractfile(member).read() for member in archive.getmembers() if member.isfile()}
        baseline_runtime, current_runtime = runtime_files(shutdown_baseline), runtime_files(candidate)
        if (set(baseline_runtime) != set(current_runtime)
                or [name for name in baseline_runtime if baseline_runtime[name] != current_runtime[name]] != ['stop-session.py']
                or current_runtime['stop-session.py'] != baseline_runtime['stop-session.py'].replace(
                    b"print('Ordered browser shutdown failed: ' + str(error), file=sys.stderr)",
                    b"print('Ordered browser shutdown failed: ' + code, file=sys.stderr)", 1)):
            raise RuntimeError('shutdown_fixed_diagnostic_only_derivation_required')
    if (candidate / "guest.raw").stat().st_size != DISK_BYTES:
        raise RuntimeError("public_root_disk_size_mismatch")
    stage = Path(tempfile.mkdtemp(prefix=".browser-publish-", dir=HERE))
    extraction = extract_kernel(build / "exports/kernel", stage / "kernel")
    if digest(stage / "kernel") != digest(candidate / "kernel"):
        raise RuntimeError("fresh_kernel_lineage_mismatch")
    shutil.copyfile(candidate / "initrd", stage / "initrd")
    if digest(stage / "initrd") != digest(build / "exports/initrd"):
        raise RuntimeError("fresh_initrd_lineage_mismatch")
    subprocess.run(["/bin/cp", "-c", str(candidate / "guest.raw"), str(stage / "guest.raw")], check=True)
    hashes = {name: digest(stage / name) for name in ("kernel", "initrd", "guest.raw")}
    active_verification = current_shutdown or shutdown or verification
    if hashes != active_verification["image_sha256"]:
        raise RuntimeError("verified_candidate_artifact_hash_mismatch")
    if current_shutdown and any(hashes[name] != baseline_hashes[name] for name in ('kernel', 'initrd')):
        raise RuntimeError('shutdown_derivation_kernel_initrd_changed')
    provenance = {
        "schema": "browser-source-provenance/v1",
        "ubuntu": {"release": "noble/release-20260926", "source": "https://cloud-images.ubuntu.com/releases/noble/release-20260926/",
                   "sha256": PINS, "base_integrity": "Immutable SHA256 pins over HTTPS; cloud-image detached GPG signature not independently verified",
                   "apt_dependency_integrity": "Ubuntu InRelease signatures and package hashes verified by apt; insecure/unauthenticated repositories rejected"},
        "kernel": {"abi": KERNEL_ABI, "packages": extract_kernel_packages(build / "evidence/prepare.serial.log")["packages"],
                   "source": "https://packages.ubuntu.com/noble-updates/arm64/linux-image-7.0.0-38-generic",
                   "source_vmlinuz_sha256": extraction["container_hash"], "derived_image_sha256": extraction["derived_hash"],
                   "initrd_sha256": hashes["initrd"], "extraction": extraction,
                   "license": "Linux GPL-2.0 and package-specific notices retained in /usr/share/doc; kernel source provided by Ubuntu archive"},
        "firefox": {"version": VERSION, "locale": "ja", "architecture": "linux-aarch64", "artifact": FIREFOX_BASE + FIREFOX_PATH,
                    "sha256": FIREFOX_SHA256, "checksum_source": FIREFOX_BASE + "SHA256SUMS",
                    "checksum_verification": "Official HTTPS SHA256SUMS plus immutable SHA256 pin; detached GPG signature not independently verified",
                    "source_archive": FIREFOX_BASE + "source/firefox-" + VERSION + ".source.tar.xz",
                    "license": "MPL-2.0 and bundled additional notices retained; local managed image does not grant Mozilla trademark redistribution rights"},
        "build": {"fresh_pristine_root": True, "prior_panic_root_reused": False, "public_dependencies_only": True,
                  "host_mounts": 0, "user_data": False, "nat_only_for_public_dependencies": True,
                  "offline_runtime_normalization": ["root ownership", "Asia/Tokyo", "Japanese locale", "local privacy check"],
                  "verified_artifact_sha256": hashes, "verification": active_verification},
    }
    if shutdown:
        receipt_reference = {
            'path': str((current_receipt_path if current_shutdown else receipt_path).relative_to(HERE.parents[1])),
            'sha256': digest(current_receipt_path if current_shutdown else receipt_path),
            'image_sha256': hashes,
            'scope': 'Strict Firefox exit 0 and fresh final checkpoint, two native VZ graphical cold boots, ACPI stop and filesystem checks; no diagnostic/scrot',
        }
        provenance['build']['verification_receipt'] = receipt_reference
        if current_shutdown:
            receipt_reference['scope'] = 'Current image: strict Firefox exit 0 and fresh final checkpoint, one 8-second native VZ standard cold boot, ACPI stop and filesystem checks; no diagnostic/scrot'
            provenance['build']['long_shutdown_baseline_verification'] = shutdown
            provenance['build']['long_shutdown_baseline_receipt'] = {
                'path': str(receipt_path.relative_to(HERE.parents[1])),
                'sha256': digest(receipt_path), 'image_sha256': baseline_hashes,
            }
            provenance['build']['long_shutdown_baseline_derivation'] = {
                'from_image_sha256': baseline_hashes, 'to_image_sha256': hashes,
                'runtime_changed_files': ['stop-session.py'],
                'exact_change': 'Failure-only stderr: str(error) replaced by already-computed fixed code',
                'runtime_tar_exact_change_verified': True,
                'success_path_changed': False,
                'current_image_two_mode_150_second_retest': False,
                'current_image_actual_app_retest': 'pending_root_release_bundle_validation',
            }
        provenance['build']['functional_baseline_verification'] = verification
        provenance['build']['functional_baseline_receipt'] = {
            'path': str(baseline_receipt_path.relative_to(HERE.parents[1])),
            'sha256': digest(baseline_receipt_path),
            'image_sha256': verification['image_sha256'],
        }
        provenance['build']['functional_baseline_artifact_sha256'] = verification['image_sha256']
        provenance['build']['actual_app_baseline_reference'] = {
            'path': 'app/evidence/browser-app-acceptance-2026-10-13.json',
            'checks': ['standard_mode_actual_app', 'app_rfp_toggle', 'proxy_failure', 'proxy_recovery'],
            'status_at_reference': 'in_progress_on_prior_root',
            'image_sha256': verification['image_sha256'],
            'current_image_app_revalidation': 'pending_root_release_bundle_validation',
            'contents_collected_by_image_builder': False,
        }
        provenance['build']['known_verification_boundary'] = {
            'debug_harness_diagnostic_scrot_kernel_faults': [
                {'path': 'host/browser-runtime/evidence/checkpoint-term-standard.serial.log',
                 'sha256': digest(HERE / 'evidence/checkpoint-term-standard.serial.log'),
                 'phase': 'After SIGTERM returned -15 and strict shutdown rejected the session'},
                {'path': 'host/browser-runtime/evidence/checkpoint-window-standard.serial.log',
                 'sha256': digest(HERE / 'evidence/checkpoint-window-standard.serial.log'),
                 'phase': 'After session readiness, before ACPI or window-close request'},
            ],
            'kernel_fault_root_cause': 'Unconfirmed; passing shutdown-only harness does not establish a kernel root-cause fix',
            'current_shutdown_harness_diagnostic_scrot_enabled': False,
            'current_shutdown_checks_read_cookie_history_or_url_contents': False,
            'tab_session_restoration_guaranteed': False,
        }
    metadata = {"schema": "browser-vm-base/v1", "firefox_version": VERSION, "kernel_abi": KERNEL_ABI,
        "sha256": hashes, "disk_bytes": DISK_BYTES, "locale": "ja", "timezone": "Asia/Tokyo", "prepared": True,
        "no_user_data": True, "production_network_devices": 0, "production_directory_shares": 0,
        "vsock_host_cid": 2, "vsock_port": 40125, "display": {"width": 1280, "height": 800},
        "profile": "/home/browser/.mozilla/browser", "profile_disk": {"device": "/dev/vdb", "bytes": 2147483648,
            "label": "browser-profile", "mount": "/home/browser"}, "full_resist_fingerprinting": False,
        "session_config": {"device": "/dev/vdc", "schema": "browser-session-config/v1", "resist_fingerprinting_default": False,
            "fields": ["schema", "resist_fingerprinting", "boot_epoch_seconds"]},
        "verification": {"cpu_count": 2, "memory_gib": 3, "native_vz_view": True,
            "gui_observation_seconds": {boot["mode"]: boot["gui_observation_seconds"] for boot in verification["boots"]},
            "standard_baseline_observed_seconds": next(boot["standard_baseline_observed_seconds"] for boot in verification["boots"] if boot["mode"] == "standard"),
            "acpi_stop": True, "ordered_session_stop": True, "persistent_profile": True, "kernel_pac_default": True},
        "terms_of_use": "Native Firefox notification retained; no consent state fabricated"}
    if shutdown:
        metadata['verification']['firefox_exit_code'] = 0
        metadata['verification']['checkpoint_complete'] = True
        metadata['verification']['checkpoint_fresh'] = True
        metadata['verification']['firefox_close_method'] = 'ewmh-net-close-window'
        metadata['verification']['diagnostic_scrot_enabled'] = False
        metadata['verification']['receipt'] = receipt_reference
        del metadata['verification']['standard_baseline_observed_seconds']
        metadata['verification']['gui_observation_seconds'] = {
            boot['mode']: boot['gui_observation_seconds'] for boot in active_verification['boots']}
        if current_shutdown:
            metadata['verification']['long_shutdown_baseline_receipt'] = provenance['build']['long_shutdown_baseline_receipt']
    (stage / "browser.json").write_text(json.dumps(metadata, indent=2) + "\n")
    provenance_bytes = (json.dumps(provenance, indent=2) + "\n").encode()
    for name in ("kernel", "initrd", "guest.raw", "browser.json"):
        (stage / name).chmod(0o400)
    with tempfile.NamedTemporaryFile(prefix=".browser-provenance-", dir=HERE, delete=False) as file:
        provenance_temp = Path(file.name)
        file.write(provenance_bytes)
    provenance_temp.chmod(0o400)
    backup = HERE / 'images-before-shutdown-checkpoint'
    provenance_backup = HERE / 'source-provenance-before-shutdown-checkpoint.json'
    if args.replace and (backup.exists() or provenance_backup.exists()):
        raise RuntimeError('browser_replacement_backup_already_exists')
    if args.replace:
        shutil.copyfile(HERE / 'source-provenance.json', provenance_backup)
        provenance_backup.chmod(0o400)
    provenance_temp.replace(HERE / "source-provenance.json")
    if output.exists():
        # Darwin's atomic exchange keeps a complete immutable directory visible.
        # RENAME_SWAP is declared as 0x2 in the host SDK's sys/stdio.h.
        libc = ctypes.CDLL(None, use_errno=True)
        libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        libc.renamex_np.restype = ctypes.c_int
        if libc.renamex_np(os.fsencode(stage), os.fsencode(output), 2) != 0:
            shutil.copyfile(provenance_backup, provenance_temp)
            provenance_temp.chmod(0o400)
            provenance_temp.replace(HERE / 'source-provenance.json')
            raise OSError(ctypes.get_errno(), 'atomic_browser_images_exchange_failed')
        stage.rename(backup)
    else:
        stage.rename(output)
    print(json.dumps({"kind": "browser_images_published", "directory": str(output), "sha256": hashes}), flush=True)


if __name__ == "__main__":
    main()
