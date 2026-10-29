"""Offline checks for the selected project boundary; no VM or user data."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from launch import ProjectDirectory, ROOT, runtime_files


class ProjectDirectoryChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='claude-project-check-')
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / 'selected'
        self.project.mkdir(mode=0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def test_pins_directory_and_preserves_contents_permissions(self):
        content = self.project / 'private.txt'
        content.write_text('synthetic project input')
        content.chmod(0o600)
        before = (self.project.stat(), content.stat(), content.read_bytes())
        selected = ProjectDirectory(self.project)
        try:
            arguments = selected.arguments()
            self.assertEqual(arguments, ['project', str(self.project), str(before[0].st_dev), str(before[0].st_ino)])
            self.assertFalse(os.get_inheritable(selected.descriptor))
            selected.verify()
        finally:
            selected.close()
        self.assertIsNone(selected.descriptor)
        self.assertEqual(content.read_bytes(), before[2])
        for current, original in ((self.project.stat(), before[0]), (content.stat(), before[1])):
            self.assertEqual((current.st_mode, current.st_uid, current.st_gid),
                             (original.st_mode, original.st_uid, original.st_gid))

    def test_rejects_replaced_directory_even_if_original_is_kept_open(self):
        selected = ProjectDirectory(self.project)
        try:
            self.project.rename(self.root / 'original')
            self.project.mkdir(mode=0o700)
            with self.assertRaisesRegex(RuntimeError, 'project_directory_changed'):
                selected.verify()
        finally:
            selected.close()

    def test_rejects_replacement_symlink(self):
        selected = ProjectDirectory(self.project)
        try:
            self.project.rename(self.root / 'original')
            self.project.symlink_to(self.root / 'original', target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, 'project_directory_changed'):
                selected.verify()
        finally:
            selected.close()

    def test_rejects_relative_path_file_missing_and_final_symlink(self):
        file = self.root / 'file'
        file.write_text('synthetic')
        symlink = self.root / 'link'
        symlink.symlink_to(self.project, target_is_directory=True)
        for path in (Path('relative'), file, self.root / 'missing', symlink, self.project / '..'):
            with self.subTest(path=path.name), self.assertRaises((RuntimeError, OSError)):
                ProjectDirectory(path)

    def test_rejects_access_denied_without_changing_permissions(self):
        with mock.patch('launch.os.access', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'project_directory_access'):
                ProjectDirectory(self.project)
        self.assertEqual(stat.S_IMODE(self.project.stat().st_mode), 0o700)

    def test_seed_contains_only_fixed_project_marker(self):
        guest = ROOT / 'guest/text-runtime'
        plain = runtime_files(guest)
        project = runtime_files(guest, project=True)
        self.assertEqual(project[:-1], plain)
        self.assertEqual(project[-1], {'path': '/etc/claude-text/project-enabled',
                                      'owner': 'root:root', 'permissions': '0644', 'content': 'project-v1\n'})
        self.assertNotIn(str(self.project), json.dumps(project))
        self.assertFalse(any(item['path'] == '/etc/claude-text/project-enabled' for item in plain))

    def test_supervisor_allows_tool_activity_but_rejects_host_commands(self):
        spec = importlib.util.spec_from_file_location('guest_supervisor', ROOT / 'guest/text-runtime/supervisor.py')
        supervisor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(supervisor)
        value = supervisor.frame(b'{"kind":"tool_activity","tool":"Read"}\n', supervisor.GUEST_OUTPUT)
        self.assertEqual(value['kind'], 'tool_activity')
        with self.assertRaisesRegex(ValueError, 'frame_kind'):
            supervisor.frame(b'{"kind":"host_shell","command":"example"}\n', supervisor.GUEST_OUTPUT)

    @unittest.skipUnless(sys.platform == 'darwin' and (ROOT / 'host/.build/release/vm-text-runtime').is_file(),
                         'requires the compiled macOS helper, never starts a VM')
    def test_helper_checks_identity_and_prepare_before_opening_missing_image(self):
        helper = ROOT / 'host/.build/release/vm-text-runtime'
        selected = self.project.stat()
        prefix = [str(helper), 'boot', str(self.root / 'missing-image'), str(self.root / 'missing-seed'),
                  str(self.root / 'unused-serial'), '60']
        cases = [(['project', str(self.project), str(selected.st_dev), str(selected.st_ino + 1)],
                  'project_directory_changed_or_inaccessible'),
                 (['prepare', 'project', str(self.project), str(selected.st_dev), str(selected.st_ino)], 'arguments'),
                 (['project', str(self.project), str(selected.st_dev), str(selected.st_ino)], None)]
        for suffix, reason in cases:
            with self.subTest(reason=reason):
                completed = subprocess.run(prefix + suffix, capture_output=True, timeout=5)
                self.assertEqual(completed.returncode, 2)
                self.assertEqual(completed.stdout, b'')
                diagnostic = json.loads(completed.stderr)
                self.assertEqual(diagnostic['error_code'], 'configuration_failed')
                # A valid /private/tmp path reaches the deliberately missing
                # boot file. Foundation's /tmp alias is not the canonical path.
                self.assertEqual(diagnostic.get('reason'), reason)
        self.assertFalse((self.root / 'unused-serial').exists())


if __name__ == '__main__':
    unittest.main()
