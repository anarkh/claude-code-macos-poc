#!/usr/bin/env python3
"""Offline CLI regression tests: pass an absolute runtime-package-tool path.

All inputs are inert files in a temporary directory. These tests neither read
an installed App or user data nor execute any fixture payload or start a VM.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


RUNTIME_PREFIX = "Resources/Runtime/"
IMAGE_PREFIX = RUNTIME_PREFIX + "host/text-runtime/images/"
PACKAGE_VERSION = "1.7.9"

# Keep this fixture inventory explicit, independent of the production parser.
PAYLOAD_PATHS = (
    "Helpers/vm-text-runtime",
    RUNTIME_PREFIX + "sdk/vm-text-chat.mjs",
    RUNTIME_PREFIX + "sdk/vm-text-smoke.mjs",
    RUNTIME_PREFIX + "sdk/deepseek-text-chat.mjs",
    RUNTIME_PREFIX + "sdk/deepseek-text-smoke.mjs",
    RUNTIME_PREFIX + "sdk/owned-run-directory.mjs",
    RUNTIME_PREFIX + "sdk/package.json",
    RUNTIME_PREFIX + "translation/stdio.mjs",
    RUNTIME_PREFIX + "translation/client.mjs",
    RUNTIME_PREFIX + "translation/pipeline.mjs",
    RUNTIME_PREFIX + "translation/protected-text.mjs",
    RUNTIME_PREFIX + "translation/errors.mjs",
    RUNTIME_PREFIX + "network/proxy-transport.mjs",
    RUNTIME_PREFIX + "runtime/profile.mjs",
    RUNTIME_PREFIX + "host/text-runtime/launch.py",
    RUNTIME_PREFIX + "host/text-runtime/common.py",
    RUNTIME_PREFIX + "host/text-runtime/runtime-config.json",
    IMAGE_PREFIX + "base.json",
    IMAGE_PREFIX + "kernel",
    IMAGE_PREFIX + "initrd",
    IMAGE_PREFIX + "guest.raw",
    RUNTIME_PREFIX + "guest/text-runtime/runtime.mjs",
    RUNTIME_PREFIX + "guest/text-runtime/bootstrap.sh",
    RUNTIME_PREFIX + "guest/text-runtime/supervisor.py",
)


def json_bytes(value):
    return json.dumps(value, sort_keys=True).encode("utf-8")


class BundledManifestTests(unittest.TestCase):
    tool = None

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="runtime-package-tool-tests-")
        self.addCleanup(temporary.cleanup)
        # The tool rejects symlink ancestors, including macOS's /var alias.
        self.root = Path(temporary.name).resolve()
        self.contents = self.root / "Fixture.app" / "Contents"
        self.output = self.contents / "Resources" / "BundledRuntimeManifest.json"
        payload = {path: ("inert fixture: " + path + "\n").encode("utf-8")
                   for path in PAYLOAD_PATHS}
        disk = payload[IMAGE_PREFIX + "guest.raw"]
        payload[IMAGE_PREFIX + "base.json"] = json_bytes({
            "schema": "claude-text-vm-base/v1",
            "prepared": True,
            "no_user_data": True,
            "network_devices": 0,
            "directory_shares": 0,
            "node_version": "26.7.0",
            "sdk_version": "0.3.295",
            "cli_version": "2.1.295",
            "disk_bytes": len(disk),
            "disk_sha256": hashlib.sha256(disk).hexdigest(),
            "kernel_sha256": hashlib.sha256(payload[IMAGE_PREFIX + "kernel"]).hexdigest(),
            "initrd_sha256": hashlib.sha256(payload[IMAGE_PREFIX + "initrd"]).hexdigest(),
        })
        payload[RUNTIME_PREFIX + "host/text-runtime/runtime-config.json"] = json_bytes({
            "schema": "claude-vm-runtime/v1",
            "image_dir": "images",
            "runner": "../../../../Helpers/vm-text-runtime",
            "guest_runtime_dir": "../../guest/text-runtime",
            "python": "/usr/bin/python3",
        })
        payload[RUNTIME_PREFIX + "sdk/package.json"] = json_bytes({
            "name": "runtime-package-tool-offline-fixture",
            "version": PACKAGE_VERSION,
            "dependencies": {"@anthropic-ai/claude-agent-sdk": "0.3.295"},
        })
        for relative, data in payload.items():
            path = self.contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            executable = relative == "Helpers/vm-text-runtime" or relative.endswith(".sh")
            path.chmod(0o700 if executable else 0o600)

    def write_app_version(self, version):
        (self.contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.claude-isolation-poc.runtime-tool-fixture",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
        }))

    def run_tool(self):
        return subprocess.run(
            [str(self.tool), "bundled-manifest", "--contents-root", str(self.contents),
             "--output", str(self.output), "--version", PACKAGE_VERSION],
            cwd=self.root, capture_output=True, text=True, timeout=15, check=False,
        )

    def assert_compatible(self, app_version):
        self.write_app_version(app_version)
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(manifest["minimumAppVersion"], "0.12.0")
        self.assertEqual(manifest["maximumAppVersionExclusive"], "0.14.0")
        self.assertEqual(manifest["version"], PACKAGE_VERSION)
        self.assertEqual({entry["path"] for entry in manifest["files"]}, set(PAYLOAD_PATHS))
        summary = json.loads(result.stdout)
        self.assertEqual(summary["status"], "bundled_manifest_written")

    def assert_incompatible(self, app_version):
        self.write_app_version(app_version)
        result = self.run_tool()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("RUNTIME_PACKAGE_INCOMPATIBLE:", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.output.exists(), "Rejected App version published a manifest")

    def test_minimum_app_version_is_accepted(self):
        self.assert_compatible("0.12.0")

    def test_current_app_version_is_accepted(self):
        self.assert_compatible("0.13.2")

    def test_next_patch_app_version_is_accepted(self):
        self.assert_compatible("0.13.3")

    def test_below_minimum_app_version_is_rejected(self):
        self.assert_incompatible("0.11.9")

    def test_exclusive_maximum_app_version_is_rejected(self):
        self.assert_incompatible("0.14.0")

    def test_malformed_app_version_is_rejected(self):
        self.write_app_version("0.13.bad")
        result = self.run_tool()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Bundled runtime requires a valid CFBundleShortVersionString in Contents/Info.plist.",
                      result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.output.exists(), "Malformed App version published a manifest")

    def test_missing_info_plist_is_rejected(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("RUNTIME_PACKAGE_INVALID:", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.output.exists(), "Missing App metadata published a manifest")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test_runtime_package_tool.py /ABS/PATH/TO/runtime-package-tool")
    tool = Path(sys.argv.pop())
    if not tool.is_absolute() or not tool.is_file() or not os.access(tool, os.X_OK):
        raise SystemExit("runtime-package-tool must be an existing executable at an absolute path")
    BundledManifestTests.tool = tool.resolve()
    unittest.main(verbosity=2)
