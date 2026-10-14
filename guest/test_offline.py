"""Parser/verdict tests only; these never prove Linux isolation."""
import errno
import json
from pathlib import Path
import sys
import subprocess
import unittest
from unittest import mock
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common
import harness


class OfflineTests(unittest.TestCase):
    def test_events_exact_populated(self):
        self.assertEqual(common.parse_events('populated 0\nfrozen 0\n'), {'populated': 0, 'frozen': 0})
        for text in ('', 'populated 2', 'populated 0\npopulated 1', 'populated 0 extra'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                common.parse_events(text)

    def test_proc_stat_comm_with_parentheses(self):
        # starttime is field 22, counted relative to the final ')' in comm.
        text = '123 (toy ) name) S ' + ' '.join(['0'] * 18 + ['4242', '0'])
        self.assertEqual(common.parse_proc_stat(text), {'pid': 123, 'state': 'S', 'starttime': 4242})

    def test_errno_does_not_claim_success(self):
        self.assertEqual(common.syscall_result('test', -1, errno.EPERM)['outcome'], 'denied')
        self.assertEqual(common.syscall_result('test', -1, errno.ENOSYS)['outcome'], 'unsupported')
        self.assertEqual(common.syscall_result('test', -1, errno.ESRCH)['outcome'], 'inconclusive')
        self.assertEqual(common.syscall_result('test', 0)['outcome'], 'allowed')

    def test_mac_preflight_never_reads_linux_paths(self):
        with mock.patch.object(harness.sys, 'platform', 'darwin'), mock.patch.object(harness, 'vm_marker', side_effect=AssertionError('must not run')):
            result = harness.preflight()
        self.assertEqual(result['status'], 'unavailable')

    def test_capability_check_includes_ambient_and_permitted(self):
        caps = {key: 0 for key in ('CapInh', 'CapPrm', 'CapEff', 'CapBnd', 'CapAmb')}
        self.assertTrue(common.no_ptrace_cap(caps))
        caps['CapPrm'] = 1 << common.CAP_SYS_PTRACE
        self.assertFalse(common.no_ptrace_cap(caps))

    def test_cgroup_root_does_not_require_non_root_type_file(self):
        def fixture_read(path):
            if path == '/proc/self/mountinfo':
                return '1 0 0:1 / /sys/fs/cgroup rw - cgroup2 cgroup rw'
            if path == '/sys/fs/cgroup/cgroup.controllers':
                return 'cpu memory pids'
            raise FileNotFoundError(path)
        with mock.patch.object(harness, 'read', side_effect=fixture_read), mock.patch.object(harness.os, 'stat', return_value=SimpleNamespace(st_uid=0)):
            result = harness.cgroup_preflight()
        self.assertEqual(result['root_type_file'], 'not_applicable')
        self.assertEqual(result['non_root_domain_validation'], 'required_before_any_process_start')

    def test_child_startup_error_keeps_real_exit_and_stderr(self):
        process = subprocess.Popen([sys.executable, '-I', '-S', '-c',
                                    'import sys; sys.stderr.write("fixture permission denied\\n"); sys.exit(7)'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with self.assertRaises(harness.ProcessDiagnosticError) as error:
                harness.read_message(process, 'ready', timeout=3)
            self.assertEqual(error.exception.diagnostics['returncode'], 7)
            self.assertIn('fixture permission denied', error.exception.diagnostics['stderr_tail'])
        finally:
            process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()

    def test_fake_stdio_is_not_json_control_protocol(self):
        messages = harness.json_lines('FAKE_APPROVAL_TEST_ONLY\n' + json.dumps({'kind': 'inheritance_probe'}) + '\n')
        self.assertEqual(messages, [{'kind': 'inheritance_probe'}])

    def test_profile_has_no_unconfined_execution_fallback(self):
        profile = '\n'.join(line for line in Path(__file__).with_name('apparmor.profile').read_text().splitlines() if not line.lstrip().startswith('#'))
        for forbidden in (' ux,', ' Ux,', ' pix,', ' cix,', 'flags=(complain)', 'flags=(unconfined)', 'flags=(default_allow)'):
            self.assertNotIn(forbidden, profile)
        self.assertIn('deny ptrace (read, trace) peer=claude-poc-control', profile)
        self.assertIn('deny ptrace (readby, tracedby) peer=claude-poc-work', profile)


if __name__ == '__main__':
    unittest.main()
