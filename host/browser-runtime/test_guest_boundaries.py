#!/usr/bin/env python3
"""Isolated guest admission tests; no subprocess or block device is used.

The profile scanner uses a temporary regular file and a smaller SIZE to exercise
full chunks, the partial tail, EOF, and extra bytes. A separate test keeps the
production disk-size contract at exactly 2 GiB.
"""
import builtins
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
GUEST = ROOT / "guest" / "browser-runtime"


def load_guest(name):
    spec = importlib.util.spec_from_file_location("boundary_" + name, GUEST / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    with mock.patch.object(sys, "dont_write_bytecode", True):
        spec.loader.exec_module(module)
    return module


CONFIG = load_guest("config")
PROFILE = load_guest("profile")


class ConfigBoundaries(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.mount = self.root / "config-mount"
        self.mount.mkdir()
        self.source = self.mount / "browser-config.json"
        self.firefox = self.root / "browser.cfg"
        self.initial = (GUEST / "browser.cfg").read_text()
        self.firefox.write_text(self.initial)
        self.serial = self.root / "serial.txt"
        self.settings = {
            "schema": "browser-session-config/v1",
            "resist_fingerprinting": True,
            "boot_epoch_seconds": 1791849600,
        }
        self.commands = []

    def path(self, value):
        paths = {
            "/run/browser-config": self.mount,
            "/opt/firefox/browser.cfg": self.firefox,
        }
        self.assertIn(value, paths, "unexpected guest filesystem path")
        return paths[value]

    def open_serial(self, value, *args, **kwargs):
        self.assertEqual(value, "/dev/hvc0", "unexpected guest file opened")
        return builtins.open(self.serial, *args, **kwargs)

    def mock_run(self, arguments, **kwargs):
        self.assertIsInstance(arguments, list)
        self.assertNotIn("shell", kwargs)
        allowed = {
            ("/usr/bin/mount", "-t", "iso9660", "-o", "ro,nosuid,nodev,noexec", "/dev/vdc", str(self.mount)),
            ("/usr/bin/umount", str(self.mount)),
            ("/usr/bin/date", "-u", "-s", "@" + str(self.settings["boot_epoch_seconds"])),
        }
        self.assertIn(tuple(arguments), allowed, "unexpected command or untrusted command argument")
        self.assertTrue(kwargs.get("check"))
        self.commands.append(arguments)
        return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")

    def invoke(self):
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(CONFIG, "Path", side_effect=self.path))
            stack.enter_context(mock.patch.object(CONFIG, "open", side_effect=self.open_serial, create=True))
            stack.enter_context(mock.patch.object(CONFIG.subprocess, "run", side_effect=self.mock_run))
            CONFIG.main()

    def reject(self, value, message):
        self.source.write_text(value)
        with self.assertRaisesRegex(ValueError, "^" + message + "$"):
            self.invoke()
        self.assertEqual(self.firefox.read_text(), self.initial)
        self.assertFalse(self.serial.exists())
        self.assertEqual(self.commands, [
            ["/usr/bin/mount", "-t", "iso9660", "-o", "ro,nosuid,nodev,noexec", "/dev/vdc", str(self.mount)],
            ["/usr/bin/umount", str(self.mount)],
        ])

    def test_unknown_command_field_fails_without_executing_content(self):
        value = dict(self.settings, command="$(touch /tmp/browser-boundary-unsafe)")
        self.reject(json.dumps(value), "session_config_fields_invalid")

    def test_duplicate_config_key_fails(self):
        value = json.dumps(self.settings)[:-1] + ', "resist_fingerprinting": false}'
        self.reject(value, "duplicate_config_key")

    def test_missing_config_field_fails(self):
        value = dict(self.settings)
        del value["boot_epoch_seconds"]
        self.reject(json.dumps(value), "session_config_fields_invalid")

    def test_non_object_config_fails(self):
        self.reject("[]", "session_config_fields_invalid")

    def test_wrong_schema_values_fail(self):
        for value in (1, True, None, "browser-session-config/v2"):
            with self.subTest(schema=value):
                self.commands.clear()
                settings = dict(self.settings, schema=value)
                self.reject(json.dumps(settings), "session_config_value_invalid")

    def test_rfp_requires_a_boolean(self):
        for value in (0, 1, "true", None, [], {}):
            with self.subTest(rfp=value):
                self.commands.clear()
                settings = dict(self.settings, resist_fingerprinting=value)
                self.reject(json.dumps(settings), "session_config_value_invalid")

    def test_boot_epoch_boolean_is_rejected(self):
        for value in (True, False):
            with self.subTest(epoch=value):
                self.commands.clear()
                settings = dict(self.settings, boot_epoch_seconds=value)
                self.reject(json.dumps(settings), "session_clock_value_invalid")

    def test_boot_epoch_wrong_types_and_out_of_range_fail(self):
        for value in (1791849600.0, "1791849600", None, 1735689599, 4102444801):
            with self.subTest(epoch=value):
                self.commands.clear()
                settings = dict(self.settings, boot_epoch_seconds=value)
                self.reject(json.dumps(settings), "session_clock_value_invalid")

    def assert_rfp_toggle(self, enabled):
        self.settings["resist_fingerprinting"] = enabled
        before = self.initial.replace(
            'lockPref("privacy.resistFingerprinting", false);',
            'lockPref("privacy.resistFingerprinting", ' + json.dumps(not enabled) + ');',
        ).replace(
            'lockPref("privacy.spoof_english", 0);',
            'lockPref("privacy.spoof_english", ' + str(0 if enabled else 2) + ');',
        ).replace(
            'lockPref("intl.accept_languages", "ja,en-US,en");',
            'lockPref("intl.accept_languages", ' + json.dumps("ja,en-US,en" if enabled else "en-US,en") + ');',
        )
        self.firefox.write_text(before)
        self.source.write_text(json.dumps(self.settings))
        self.invoke()
        after = self.firefox.read_text()
        old_lines, new_lines = before.splitlines(), after.splitlines()
        self.assertEqual(len(old_lines), len(new_lines))
        changes = [(old, new) for old, new in zip(old_lines, new_lines) if old != new]
        self.assertEqual(changes, [
            ('lockPref("privacy.resistFingerprinting", ' + json.dumps(not enabled) + ');',
             'lockPref("privacy.resistFingerprinting", ' + json.dumps(enabled) + ');'),
            ('lockPref("privacy.spoof_english", ' + str(0 if enabled else 2) + ');',
             'lockPref("privacy.spoof_english", ' + str(2 if enabled else 0) + ');'),
            ('lockPref("intl.accept_languages", ' + json.dumps("ja,en-US,en" if enabled else "en-US,en") + ');',
             'lockPref("intl.accept_languages", ' + json.dumps("en-US,en" if enabled else "ja,en-US,en") + ');'),
        ])
        self.assertEqual(self.serial.read_text(), "BROWSER_CONFIG_READY\n")
        self.assertEqual(self.commands, [
            ["/usr/bin/mount", "-t", "iso9660", "-o", "ro,nosuid,nodev,noexec", "/dev/vdc", str(self.mount)],
            ["/usr/bin/date", "-u", "-s", "@1791849600"],
            ["/usr/bin/umount", str(self.mount)],
        ])

    def test_enable_rfp_changes_only_three_known_preferences(self):
        self.assert_rfp_toggle(True)

    def test_disable_rfp_changes_only_three_known_preferences(self):
        self.assert_rfp_toggle(False)

    def test_oversized_config_fails(self):
        self.reject(" " * 257, "session_config_file_invalid")

    def test_symlink_config_fails(self):
        target = self.root / "other-config.json"
        target.write_text(json.dumps(self.settings))
        self.source.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "^session_config_file_invalid$"):
            self.invoke()
        self.assertEqual(self.firefox.read_text(), self.initial)
        self.assertEqual(self.commands[-1], ["/usr/bin/umount", str(self.mount)])

    def test_missing_local_preference_contract_fails_without_writing(self):
        self.initial = self.initial.replace('lockPref("privacy.spoof_english", 0);\n', "")
        self.firefox.write_text(self.initial)
        self.source.write_text(json.dumps(self.settings))
        with self.assertRaisesRegex(ValueError, "^local_config_contract_missing$"):
            self.invoke()
        self.assertEqual(self.firefox.read_text(), self.initial)
        self.assertFalse(self.serial.exists())
        self.assertEqual(self.commands[-1], ["/usr/bin/umount", str(self.mount)])


class ProfileBoundaries(unittest.TestCase):
    TEST_SIZE = 2 * 1024 * 1024 + 17

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.device = self.root / "profile.raw"
        self.device.write_bytes(bytes(self.TEST_SIZE))
        self.home = self.root / "browser-home"
        self.serial = self.root / "serial.txt"
        self.commands = []
        self.reported_size = self.TEST_SIZE
        self.blkid_code = 2
        self.blkid_output = ""
        self.allow_disk_read = True
        self.disk_reads = 0

    def mock_run(self, arguments, **kwargs):
        self.assertIsInstance(arguments, list)
        self.assertNotIn("shell", kwargs)
        self.assertTrue(kwargs.get("capture_output"))
        self.assertTrue(kwargs.get("text"))
        self.commands.append(arguments)
        if arguments == ["/usr/sbin/blockdev", "--getsize64", str(self.device)]:
            self.assertTrue(kwargs.get("check"))
            return subprocess.CompletedProcess(arguments, 0, str(self.reported_size), "")
        if arguments == ["/usr/sbin/blkid", "-p", "-o", "export", str(self.device)]:
            return subprocess.CompletedProcess(arguments, self.blkid_code, self.blkid_output, "")
        allowed = [
            ["/usr/sbin/mkfs.ext4", "-q", "-m", "0", "-L", "browser-profile", str(self.device)],
            ["/usr/bin/mount", "-o", "nodev,nosuid", str(self.device), str(self.home)],
            ["/usr/bin/umount", str(self.home)],
        ]
        self.assertIn(arguments, allowed, "unexpected profile command")
        self.assertTrue(kwargs.get("check"))
        return subprocess.CompletedProcess(arguments, 0, "", "")

    def open_file(self, value, *args, **kwargs):
        if str(value) == str(self.device):
            self.assertTrue(self.allow_disk_read, "existing filesystem was opened for zero-media scanning")
            self.assertEqual(args, ("rb",))
            self.assertEqual(kwargs, {"buffering": 0})
            self.disk_reads += 1
            return builtins.open(self.device, *args, **kwargs)
        self.assertEqual(value, "/dev/hvc0", "unexpected profile file opened")
        return builtins.open(self.serial, *args, **kwargs)

    def invoke(self, owner=(59998, 59998)):
        real_stat = Path.stat

        def stat_with_owner(path, *args, **kwargs):
            result = real_stat(path, *args, **kwargs)
            if path == self.home:
                fields = list(result)
                fields[4], fields[5] = owner
                return os.stat_result(fields)
            return result

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(PROFILE, "DEVICE", str(self.device)))
            stack.enter_context(mock.patch.object(PROFILE, "SIZE", self.TEST_SIZE))
            stack.enter_context(mock.patch.object(PROFILE, "HOME", self.home))
            stack.enter_context(mock.patch.object(PROFILE.sys, "argv", ["profile.py"]))
            stack.enter_context(mock.patch.object(PROFILE, "open", side_effect=self.open_file, create=True))
            stack.enter_context(mock.patch.object(PROFILE.subprocess, "run", side_effect=self.mock_run))
            self.chown = stack.enter_context(mock.patch.object(PROFILE.os, "chown"))
            stack.enter_context(mock.patch.object(Path, "stat", new=stat_with_owner))
            PROFILE.main()

    def assert_no_format_or_mount(self):
        self.assertFalse(any(command[0] in ("/usr/sbin/mkfs.ext4", "/usr/bin/mount")
                             for command in self.commands))
        self.assertFalse(self.serial.exists())

    def test_production_size_contract_is_exactly_two_gib(self):
        self.assertEqual(PROFILE.SIZE, 2 * 1024 ** 3)

    def test_unknown_media_nonzero_first_byte_never_formats(self):
        with self.device.open("r+b") as disk:
            disk.write(b"X")
        with self.assertRaisesRegex(RuntimeError, "^nonzero_unknown_profile_disk$"):
            self.invoke()
        self.assert_no_format_or_mount()

    def test_unknown_media_nonzero_last_byte_never_formats(self):
        with self.device.open("r+b") as disk:
            disk.seek(self.TEST_SIZE - 1)
            disk.write(b"X")
        with self.assertRaisesRegex(RuntimeError, "^nonzero_unknown_profile_disk$"):
            self.invoke()
        self.assert_no_format_or_mount()

    def test_wrong_reported_size_fails_before_probe_or_format(self):
        self.reported_size -= 1
        with self.assertRaisesRegex(RuntimeError, "^profile_disk_size_invalid$"):
            self.invoke()
        self.assertEqual(self.commands, [["/usr/sbin/blockdev", "--getsize64", str(self.device)]])
        self.assertEqual(self.disk_reads, 0)
        self.assert_no_format_or_mount()

    def test_unknown_short_media_never_formats(self):
        with self.device.open("r+b") as disk:
            disk.truncate(self.TEST_SIZE - 1)
        with self.assertRaisesRegex(RuntimeError, "^nonzero_unknown_profile_disk$"):
            self.invoke()
        self.assert_no_format_or_mount()

    def test_unknown_extra_media_byte_never_formats(self):
        with self.device.open("ab") as disk:
            disk.write(b"\0")
        with self.assertRaisesRegex(RuntimeError, "^profile_disk_size_changed$"):
            self.invoke()
        self.assert_no_format_or_mount()

    def test_wrong_filesystem_identity_never_formats_or_mounts(self):
        values = (
            (0, "TYPE=ext4\nLABEL=other\n"),
            (0, "TYPE=xfs\nLABEL=browser-profile\n"),
            (0, "TYPE=ext4\n"),
            (2, "TYPE=ext4\nLABEL=browser-profile\n"),
            (4, ""),
        )
        for code, output in values:
            with self.subTest(code=code, probe=output):
                self.commands.clear()
                self.blkid_code, self.blkid_output = code, output
                self.allow_disk_read = False
                with self.assertRaisesRegex(RuntimeError, "^profile_disk_identity_invalid$"):
                    self.invoke()
                self.assert_no_format_or_mount()

    def test_valid_ext4_mounts_without_formatting_or_zero_scan(self):
        self.blkid_code = 0
        self.blkid_output = "TYPE=ext4\nLABEL=browser-profile\nUUID=unit-test\n"
        self.allow_disk_read = False
        self.invoke()
        self.assertEqual(self.commands, [
            ["/usr/sbin/blockdev", "--getsize64", str(self.device)],
            ["/usr/sbin/blkid", "-p", "-o", "export", str(self.device)],
            ["/usr/bin/mount", "-o", "nodev,nosuid", str(self.device), str(self.home)],
        ])
        self.assertEqual(self.disk_reads, 0)
        self.chown.assert_not_called()
        self.assertEqual(self.serial.read_text(), "BROWSER_PROFILE_READY\n")

    def test_existing_profile_wrong_owner_unmounts_and_fails(self):
        self.blkid_code = 0
        self.blkid_output = "TYPE=ext4\nLABEL=browser-profile\n"
        with self.assertRaisesRegex(RuntimeError, "^profile_home_owner_invalid$"):
            self.invoke(owner=(0, 0))
        self.assertFalse(any(command[0] == "/usr/sbin/mkfs.ext4" for command in self.commands))
        self.assertEqual(self.commands[-1], ["/usr/bin/umount", str(self.home)])
        self.assertFalse(self.serial.exists())

    def test_fully_zero_fresh_media_formats_exactly_once_then_mounts(self):
        self.invoke()
        self.assertEqual(self.commands, [
            ["/usr/sbin/blockdev", "--getsize64", str(self.device)],
            ["/usr/sbin/blkid", "-p", "-o", "export", str(self.device)],
            ["/usr/sbin/mkfs.ext4", "-q", "-m", "0", "-L", "browser-profile", str(self.device)],
            ["/usr/bin/mount", "-o", "nodev,nosuid", str(self.device), str(self.home)],
        ])
        self.assertEqual(self.disk_reads, 1)
        self.chown.assert_called_once_with(self.home, 59998, 59998)
        self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.serial.read_text(), "BROWSER_PROFILE_READY\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
