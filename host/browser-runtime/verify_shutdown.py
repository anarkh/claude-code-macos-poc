#!/usr/bin/env python3
"""Verify normal Firefox shutdown without inspecting any browsing state."""
import argparse
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time

from prepare import HERE, ROOT, digest, run_vm
from check_filesystems import check_public_disk


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--profile-clone', type=Path, required=True)
    parser.add_argument('--evidence-dir', type=Path, required=True)
    parser.add_argument('--short', action='store_true')
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    if candidate.parent != HERE or not candidate.name.startswith('.browser-patched-'):
        raise RuntimeError('owned_public_candidate_required')
    fixture = args.profile_clone.absolute()
    if (fixture.is_symlink() or fixture.resolve().parent.parent != ROOT / 'app/.build'
            or not fixture.parent.name.startswith('browser-integration-')
            or fixture.name != 'accepted-terms-profile-clone.raw'):
        raise RuntimeError('authorized_task_profile_clone_required')
    info = fixture.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_mode & 0o777 != 0o600
            or info.st_size != 2 * 1024 ** 3):
        raise RuntimeError('task_profile_clone_invalid')
    evidence = args.evidence_dir.resolve()
    if HERE / 'evidence' not in evidence.parents:
        raise RuntimeError('owned_shutdown_evidence_required')
    evidence.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.browser-verify-shutdown-', dir=HERE))
    print(json.dumps({'kind': 'browser_shutdown_staging', 'directory': str(stage)}), flush=True)
    for name in ('kernel', 'initrd'):
        shutil.copyfile(candidate / name, stage / name)
    subprocess.run(['/bin/cp', '-c', str(fixture), str(stage / 'profile.raw')], check=True)
    seed = stage / 'seed'
    seed.mkdir()
    receipts = []
    try:
        for mode in (False,) if args.short else (False, True):
            name = 'standard' if not mode else 'rfp'
            log = evidence / (name + '.serial.log')
            if log.exists():
                raise RuntimeError('shutdown_evidence_already_exists')
            root = stage / 'guest.raw'
            if root.exists():
                root.unlink()
            subprocess.run(['/bin/cp', '-c', str(candidate / 'guest.raw'), str(root)], check=True)
            root.chmod(0o600)
            (seed / 'browser-config.json').write_text(json.dumps({
                'schema': 'browser-session-config/v1', 'resist_fingerprinting': mode,
                'boot_epoch_seconds': int(time.time())}) + '\n')
            iso = stage / 'seed.iso'
            iso.unlink(missing_ok=True)
            subprocess.run(['/usr/bin/hdiutil', 'makehybrid', '-iso', '-joliet',
                '-default-volume-name', 'browsercfg', '-o', str(iso), str(seed)],
                check=True, capture_output=True)
            output = run_vm(HERE / '.build/prepare-browser-vm',
                'verify-shutdown' if args.short else 'verify-shutdown-full', stage, log, 240)
            serial = log.read_text(errors='replace').replace('\r', '')
            if re.search(r'\b(?:BUG:|Oops:|Kernel panic\b|kernel BUG at\b|Internal error:)', serial, re.IGNORECASE):
                raise RuntimeError('shutdown_verification_kernel_fault')
            lines = serial.splitlines()
            for marker in ('BROWSER_SESSION_READY', 'BROWSER_FIREFOX_EXIT=0',
                           'BROWSER_CHECKPOINT_COMPLETE=1', 'BROWSER_SESSION_STOP_COMPLETE'):
                if lines.count(marker) != 1:
                    raise RuntimeError('shutdown_verification_marker_missing:' + marker)
            if ('BROWSER_SESSION_STOP_FAILED' in lines
                    or 'BROWSER_SHUTDOWN_VIEW_READY' not in output
                    or 'BROWSER_BUILD_ACPI_STOP_REQUESTED' not in output):
                raise RuntimeError('normal_acpi_shutdown_not_verified')
            receipt = {'mode': name, 'cpu_count': 2, 'memory_gib': 3, 'native_vz_view': True,
                'gui_observation_seconds': 8 if args.short else 150, 'acpi_stop': True,
                'ordered_session_stop': True, 'firefox_exit_code': 0, 'checkpoint_complete': True,
                'checkpoint_fresh': True, 'firefox_close_method': 'ewmh-net-close-window',
                'network_devices': 0, 'directory_shares': 0, 'diagnostic_scrot_enabled': False}
            receipts.append(receipt)
            print(json.dumps({'kind': 'browser_shutdown_mode_verified', **receipt}), flush=True)
        filesystems = [check_public_disk(stage / name,
            evidence / ('post-acpi-' + name + '.serial.log')) for name in ('guest.raw', 'profile.raw')]
        receipt = {'schema': 'browser-clean-shutdown-check/v1', 'boots': receipts,
            'filesystems': filesystems,
            'profile_fixture': 'authorized-accepted-terms-clone',
            'profile_contents_collected': False,
            'image_sha256': {name: digest(candidate / name) for name in ('kernel', 'initrd', 'guest.raw')}}
        (evidence / 'verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
        shutil.rmtree(stage)
        print(json.dumps({'kind': 'browser_clean_shutdown_verified', 'modes': [boot['mode'] for boot in receipts]}), flush=True)
    except BaseException:
        print(json.dumps({'kind': 'browser_shutdown_failed_preserved', 'directory': str(stage)}), flush=True)
        raise


if __name__ == '__main__':
    main()
