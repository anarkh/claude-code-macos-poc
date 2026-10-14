#!/usr/bin/env python3
"""Synthetic shutdown checks: temporary checkpoints and mocked processes only."""
from contextlib import ExitStack, nullcontext, redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import signal
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "browser_session_shutdown", ROOT / "guest/browser-runtime/session.py"
)
SESSION = importlib.util.module_from_spec(SPEC)
with mock.patch.object(sys, "dont_write_bytecode", True):
    SPEC.loader.exec_module(SESSION)
STOP_SPEC = importlib.util.spec_from_file_location(
    "browser_session_stop", ROOT / "guest/browser-runtime/stop-session.py"
)
STOP = importlib.util.module_from_spec(STOP_SPEC)
with mock.patch.object(sys, "dont_write_bytecode", True):
    STOP_SPEC.loader.exec_module(STOP)

COMPLETE = "sessionstore-final-state-write-complete"
LAUNCHED_NS = 1_790_000_000_000_000_000


class CheckpointBoundaries(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.profile = Path(temporary.name)
        self.checkpoint = self.profile / "sessionCheckpoints.json"

    def write(self, value=None, *, raw=None, modified_ns=LAUNCHED_NS + 100):
        if raw is None:
            raw = json.dumps({COMPLETE: True} if value is None else value).encode()
        self.checkpoint.write_bytes(raw)
        os.utime(self.checkpoint, ns=(modified_ns, modified_ns))

    def validate(self, previous=None, launched_ns=LAUNCHED_NS):
        SESSION.validate_shutdown_checkpoint(self.profile, previous, launched_ns)

    def reject(self, code, previous=None, launched_ns=LAUNCHED_NS):
        with self.assertRaisesRegex(RuntimeError, "^" + code + "$"):
            self.validate(previous, launched_ns)

    def test_missing_stamp_is_none(self):
        self.assertIsNone(SESSION.checkpoint_stamp(self.checkpoint))

    def test_stamp_matches_lstat_metadata(self):
        self.write()
        metadata = self.checkpoint.lstat()
        self.assertEqual(SESSION.checkpoint_stamp(self.checkpoint), (
            metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns,
            metadata.st_ctime_ns, metadata.st_size,
        ))

    def test_fresh_true_checkpoint_is_accepted(self):
        self.write()
        self.assertIsNone(self.validate())

    def test_rewritten_checkpoint_is_accepted(self):
        self.write({COMPLETE: False}, modified_ns=LAUNCHED_NS - 100)
        previous = SESSION.checkpoint_stamp(self.checkpoint)
        self.write({COMPLETE: True})
        self.assertIsNone(self.validate(previous))

    def test_missing_checkpoint_fails(self):
        self.reject("checkpoint_missing")

    def test_unchanged_checkpoint_is_not_fresh(self):
        self.write()
        self.reject("checkpoint_not_fresh", SESSION.checkpoint_stamp(self.checkpoint))

    def test_old_checkpoint_with_no_previous_stamp_is_not_fresh(self):
        self.write(modified_ns=LAUNCHED_NS - 1)
        self.reject("checkpoint_not_fresh")

    def test_changed_checkpoint_older_than_launch_is_not_fresh(self):
        self.write({COMPLETE: False}, modified_ns=LAUNCHED_NS - 100)
        previous = SESSION.checkpoint_stamp(self.checkpoint)
        self.write(modified_ns=LAUNCHED_NS - 1)
        self.reject("checkpoint_not_fresh", previous)

    def test_launch_time_boundary_is_accepted(self):
        self.write(modified_ns=LAUNCHED_NS)
        self.assertIsNone(self.validate())

    def test_directory_is_not_regular(self):
        self.checkpoint.mkdir()
        self.reject("checkpoint_not_regular")

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_fifo_is_rejected_without_waiting_for_a_writer(self):
        os.mkfifo(self.checkpoint)
        self.reject("checkpoint_not_regular")

    def test_symlink_is_not_followed(self):
        target = self.profile / "other-checkpoint.json"
        target.write_text(json.dumps({COMPLETE: True}))
        self.checkpoint.symlink_to(target)
        self.reject("checkpoint_open_failed")

    def test_empty_checkpoint_fails(self):
        self.write(raw=b"")
        self.reject("checkpoint_size_invalid")

    def test_oversized_checkpoint_fails(self):
        self.write(raw=b" " * (SESSION.CHECKPOINT_LIMIT + 1))
        self.reject("checkpoint_size_invalid")

    def test_exact_size_limit_is_accepted(self):
        payload = json.dumps({COMPLETE: True}).encode()
        self.write(raw=payload + b" " * (SESSION.CHECKPOINT_LIMIT - len(payload)))
        self.assertIsNone(self.validate())

    def test_malformed_json_and_invalid_utf8_fail(self):
        for payload in (b"{", b"\xff", b'{"unterminated":'):
            with self.subTest(payload=payload):
                self.write(raw=payload)
                self.reject("checkpoint_invalid_json")

    def test_non_object_json_fails(self):
        for payload in (b"[]", b"null", b"true", b"1", b'"text"'):
            with self.subTest(payload=payload):
                self.write(raw=payload)
                self.reject("checkpoint_invalid_json")

    def test_duplicate_keys_fail_even_when_values_match(self):
        for payload in (
            '{"' + COMPLETE + '":true,"' + COMPLETE + '":true}',
            '{"' + COMPLETE + '":true,"extra":{"flag":true,"flag":true}}',
        ):
            with self.subTest(payload=payload):
                self.write(raw=payload.encode())
                self.reject("checkpoint_invalid_json")

    def test_completion_requires_literal_true(self):
        for value in (False, None, 0, 1, "true", [], {}):
            with self.subTest(value=value):
                self.write({COMPLETE: value})
                self.reject("checkpoint_incomplete")

    def test_missing_completion_field_fails(self):
        self.write({"profile-after-change": True})
        self.reject("checkpoint_incomplete")

    def test_checkpoint_mutation_during_read_fails(self):
        self.write()
        real_read = os.read
        changed = False

        def mutate_after_read(descriptor, size):
            nonlocal changed
            data = real_read(descriptor, size)
            if not changed:
                changed = True
                os.utime(self.checkpoint, ns=(LAUNCHED_NS + 200, LAUNCHED_NS + 200))
            return data

        with mock.patch.object(SESSION.os, "read", side_effect=mutate_after_read):
            self.reject("checkpoint_changed_during_read")
        self.assertTrue(changed, "test must mutate the checkpoint during its actual read")


class FirefoxExit(unittest.TestCase):
    def test_only_zero_exit_is_clean(self):
        self.assertIsNone(SESSION.check_firefox_exit(0))
        for code in (-signal.SIGTERM, -signal.SIGKILL, 1, 2, 15):
            with self.subTest(code=code):
                with self.assertRaisesRegex(RuntimeError, "^firefox_exit_not_clean$"):
                    SESSION.check_firefox_exit(code)


class WindowManagerConfig(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.config = Path(temporary.name) / "openbox.xml"

    def validate(self):
        real_read_bytes = Path.read_bytes

        def read_config(path):
            self.assertEqual(path, Path("/opt/browser/openbox.xml"))
            return real_read_bytes(self.config)

        with mock.patch.object(SESSION.Path, "read_bytes", autospec=True,
                               side_effect=read_config):
            return SESSION.validate_window_manager_config()

    def test_valid_xml_is_accepted(self):
        self.config.write_bytes(
            b'<openbox_config xmlns="http://openbox.org/3.4/rc"><keyboard/></openbox_config>'
        )
        self.assertIsNone(self.validate())

    def test_missing_config_has_fixed_failure_code(self):
        with self.assertRaisesRegex(SESSION.ShutdownError, "^openbox_config_invalid$"):
            self.validate()

    def test_malformed_xml_has_fixed_failure_code(self):
        self.config.write_bytes(b"<openbox_config>")
        with self.assertRaisesRegex(SESSION.ShutdownError, "^openbox_config_invalid$"):
            self.validate()

    def test_wrong_namespace_or_root_has_fixed_failure_code(self):
        for xml in (
            b"<openbox_config/>",
            b'<openbox_config xmlns="urn:synthetic-invalid"/>',
            b'<other_root xmlns="http://openbox.org/3.4/rc"/>',
        ):
            with self.subTest(xml=xml):
                self.config.write_bytes(xml)
                with self.assertRaisesRegex(SESSION.ShutdownError, "^openbox_config_invalid$"):
                    self.validate()


class FakeProcess:
    def __init__(self, name, code, events, on_wait=None):
        self.name = name
        self.code = code
        self.events = events
        self.on_wait = on_wait
        self.terminated = False
        self.pid = 321 if name == "firefox" else 123

    def poll(self):
        return self.code if self.terminated else None

    def terminate(self):
        self.terminated = True
        self.events.append(self.name + ":terminate")

    def wait(self, timeout):
        self.events.append(self.name + ":wait")
        if self.on_wait:
            self.on_wait()
        return self.code


class ShutdownOrdering(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.profile = self.home / ".mozilla/browser"
        self.profile.mkdir(parents=True)
        self.checkpoint = self.profile / "sessionCheckpoints.json"
        self.result = self.home / "stop-result"
        self.diagnostic = self.home / "stop-diagnostic"
        self.events = []

    def complete_checkpoint(self):
        self.checkpoint.write_text(json.dumps({COMPLETE: True}))
        os.utime(self.checkpoint, ns=(LAUNCHED_NS + 100, LAUNCHED_NS + 100))

    def invoke(self, firefox_code=0, on_wait=None, close_error=None,
               paste_code=-signal.SIGTERM, paste_on_wait=None, config_error=None,
               resize_code=-signal.SIGTERM, resize_on_wait=None,
               resize_exited_during_run=False):
        firefox = FakeProcess("firefox", firefox_code, self.events, on_wait)
        manager = FakeProcess("openbox", -signal.SIGTERM, self.events)
        paste = FakeProcess("paste", paste_code, self.events, paste_on_wait)
        resize = FakeProcess("resize", resize_code, self.events, resize_on_wait)
        resize.terminated = resize_exited_during_run
        stdout, stderr = io.StringIO(), io.StringIO()
        configuration_validated = False
        run_ticks = 0

        def validate_config():
            nonlocal configuration_validated
            if config_error:
                raise config_error
            configuration_validated = True

        def popen(arguments):
            self.assertTrue(configuration_validated, "validate config before starting any process")
            if arguments[0] == "/usr/bin/openbox":
                self.assertEqual(arguments, ["/usr/bin/openbox", "--config-file",
                                             "/opt/browser/openbox.xml"])
                return manager
            if arguments[0] == "/opt/firefox/firefox":
                return firefox
            if arguments == ["/usr/bin/python3", "/opt/browser/resize.py"]:
                return resize
            self.assertEqual(arguments, ["/usr/bin/python3", "/opt/browser/paste.py",
                                         "--firefox-pid", str(firefox.pid)])
            return paste

        def wait_running_browser(delay):
            nonlocal run_ticks
            self.assertEqual(delay, 0.1)
            self.assertFalse(firefox.terminated, "adapter exit must keep Firefox running")
            self.assertEqual(self.events, [], "adapter exit must not initiate browser shutdown")
            run_ticks += 1
            if run_ticks == 2:
                SESSION.request_stop(signal.SIGTERM, None)

        def close_window(pid):
            self.assertEqual(pid, firefox.pid)
            self.events.append("firefox:window-close")
            if close_error:
                raise close_error
            firefox.terminated = True

        validate_checkpoint = SESSION.validate_shutdown_checkpoint

        def validate(*arguments):
            self.events.append("firefox:checkpoint")
            return validate_checkpoint(*arguments)

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(SESSION, "RESULT", self.result))
            stack.enter_context(mock.patch.object(SESSION, "DIAGNOSTIC", self.diagnostic))
            stack.enter_context(mock.patch.object(SESSION, "stopping", not resize_exited_during_run))
            stack.enter_context(mock.patch.object(SESSION.Path, "home", return_value=self.home))
            stack.enter_context(mock.patch.object(SESSION.os, "umask"))
            stack.enter_context(mock.patch.object(SESSION.signal, "signal"))
            stack.enter_context(mock.patch.object(SESSION.time, "time_ns", return_value=LAUNCHED_NS))
            stack.enter_context(mock.patch.object(SESSION.time, "sleep", side_effect=wait_running_browser))
            process_start = stack.enter_context(
                mock.patch.object(SESSION.subprocess, "Popen", side_effect=popen)
            )
            stack.enter_context(mock.patch.object(SESSION, "validate_window_manager_config",
                                                 side_effect=validate_config))
            stack.enter_context(mock.patch.object(SESSION, "request_firefox_close", side_effect=close_window))
            stack.enter_context(mock.patch.object(SESSION, "validate_shutdown_checkpoint", side_effect=validate))
            stack.enter_context(redirect_stdout(stdout))
            stack.enter_context(redirect_stderr(stderr))
            code = SESSION.main()
        if config_error:
            process_start.assert_not_called()
        if resize_exited_during_run:
            self.assertEqual(run_ticks, 2, "keep running until the synthetic stop request")
        return code, stdout.getvalue(), stderr.getvalue()

    def test_clean_exit_and_fresh_checkpoint_close_openbox_then_succeed(self):
        code, stdout, stderr = self.invoke(on_wait=self.complete_checkpoint)
        self.assertEqual(code, 0)
        self.assertEqual(self.result.read_text(), "success\n")
        self.assertEqual(self.events, [
            "resize:terminate", "resize:wait",
            "paste:terminate", "paste:wait",
            "firefox:window-close", "firefox:wait", "firefox:checkpoint",
            "openbox:terminate", "openbox:wait",
        ])
        self.assertIn("BROWSER_FIREFOX_EXIT=0", stdout)
        self.assertEqual(json.loads(self.diagnostic.read_text()), {
            "schema": "browser-shutdown-check/v1",
            "firefox_exit_code": 0,
            "checkpoint_complete": True,
        })
        self.assertEqual(stderr, "")

    def test_sigterm_exit_fails_even_with_complete_checkpoint(self):
        code, _, stderr = self.invoke(-signal.SIGTERM, self.complete_checkpoint)
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertEqual(self.events, ["resize:terminate", "resize:wait", "paste:terminate", "paste:wait",
                                      "firefox:window-close", "firefox:wait"])
        self.assertIn("firefox_exit_not_clean", stderr)
        self.assertEqual(json.loads(self.diagnostic.read_text()), {
            "schema": "browser-shutdown-check/v1",
            "firefox_exit_code": -signal.SIGTERM,
            "checkpoint_complete": False,
        })

    def test_missing_checkpoint_keeps_openbox_alive_and_fails(self):
        code, _, stderr = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertEqual(self.events, ["resize:terminate", "resize:wait", "paste:terminate", "paste:wait",
                                      "firefox:window-close", "firefox:wait", "firefox:checkpoint"])
        self.assertIn("checkpoint_missing", stderr)

    def test_previous_true_checkpoint_does_not_satisfy_new_shutdown(self):
        self.complete_checkpoint()
        code, _, stderr = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertEqual(self.events, ["resize:terminate", "resize:wait", "paste:terminate", "paste:wait",
                                      "firefox:window-close", "firefox:wait", "firefox:checkpoint"])
        self.assertIn("checkpoint_not_fresh", stderr)

    def test_unexpected_error_is_not_written_to_diagnostics(self):
        def fail_wait():
            raise RuntimeError("synthetic_private_error_do_not_log")

        code, stdout, stderr = self.invoke(on_wait=fail_wait)
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertNotIn("synthetic_private_error_do_not_log", stdout + stderr)
        self.assertEqual(self.events, ["resize:terminate", "resize:wait", "paste:terminate", "paste:wait",
                                      "firefox:window-close", "firefox:wait"])

    def test_close_protocol_failure_keeps_processes_alive_and_reports_fixed_code(self):
        code, stdout, stderr = self.invoke(
            close_error=SESSION.ShutdownError("firefox_close_request_failed")
        )
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertEqual(self.events, ["resize:terminate", "resize:wait",
                                      "paste:terminate", "paste:wait", "firefox:window-close"])
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "BROWSER_SESSION_STOP_FAILED:firefox_close_request_failed\n")
        self.assertEqual(json.loads(self.diagnostic.read_text()), {
            "schema": "browser-shutdown-check/v1",
            "firefox_exit_code": None,
            "checkpoint_complete": False,
        })

    def test_firefox_wait_timeout_does_not_force_kill_and_reports_fixed_code(self):
        def timeout():
            raise SESSION.subprocess.TimeoutExpired("synthetic_private_arguments", 20)

        code, stdout, stderr = self.invoke(on_wait=timeout)
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertEqual(self.events, ["resize:terminate", "resize:wait", "paste:terminate", "paste:wait",
                                      "firefox:window-close", "firefox:wait"])
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "BROWSER_SESSION_STOP_FAILED:firefox_shutdown_timeout\n")

    def assert_saved_firefox_despite_component_failure(self, expected_error, **arguments):
        code, stdout, stderr = self.invoke(on_wait=self.complete_checkpoint, **arguments)
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertEqual(self.events, [
            "resize:terminate", "resize:wait",
            "paste:terminate", "paste:wait",
            "firefox:window-close", "firefox:wait", "firefox:checkpoint",
            "openbox:terminate", "openbox:wait",
        ])
        self.assertIn("BROWSER_FIREFOX_EXIT=0", stdout)
        self.assertIn("BROWSER_CHECKPOINT_COMPLETE=1", stdout)
        self.assertEqual(stderr, "BROWSER_SESSION_STOP_FAILED:" + expected_error + "\n")
        self.assertEqual(json.loads(self.diagnostic.read_text()), {
            "schema": "browser-shutdown-check/v1",
            "firefox_exit_code": 0,
            "checkpoint_complete": True,
        })

    def test_broker_timeout_still_saves_firefox_before_fixed_failure(self):
        def timeout():
            raise SESSION.subprocess.TimeoutExpired("synthetic_private_broker_arguments", 5)

        self.assert_saved_firefox_despite_component_failure(
            "paste_shutdown_timeout", paste_on_wait=timeout
        )

    def test_broker_abnormal_exit_still_saves_firefox_before_fixed_failure(self):
        self.assert_saved_firefox_despite_component_failure("paste_shutdown_failed", paste_code=1)

    def test_broker_zero_exit_allows_ordered_success(self):
        code, _, stderr = self.invoke(on_wait=self.complete_checkpoint, paste_code=0)
        self.assertEqual(code, 0)
        self.assertEqual(self.result.read_text(), "success\n")
        self.assertEqual(self.events, [
            "resize:terminate", "resize:wait",
            "paste:terminate", "paste:wait",
            "firefox:window-close", "firefox:wait", "firefox:checkpoint",
            "openbox:terminate", "openbox:wait",
        ])
        self.assertEqual(stderr, "")

    def test_resize_zero_exit_allows_ordered_success(self):
        code, _, stderr = self.invoke(on_wait=self.complete_checkpoint, resize_code=0)
        self.assertEqual(code, 0)
        self.assertEqual(self.result.read_text(), "success\n")
        self.assertEqual(self.events, [
            "resize:terminate", "resize:wait", "paste:terminate", "paste:wait",
            "firefox:window-close", "firefox:wait", "firefox:checkpoint",
            "openbox:terminate", "openbox:wait",
        ])
        self.assertEqual(stderr, "")

    def test_resize_timeout_still_saves_firefox_before_fixed_failure(self):
        def timeout():
            raise SESSION.subprocess.TimeoutExpired("synthetic_private_resize_arguments", 5)

        self.assert_saved_firefox_despite_component_failure(
            "resize_shutdown_timeout", resize_on_wait=timeout
        )

    def test_resize_abnormal_exit_still_saves_firefox_before_fixed_failure(self):
        self.assert_saved_firefox_despite_component_failure("resize_shutdown_failed", resize_code=1)

    def test_resize_runtime_exit_keeps_browser_running_then_saves_before_fixed_failure(self):
        code, stdout, stderr = self.invoke(
            on_wait=self.complete_checkpoint, resize_code=0, resize_exited_during_run=True
        )
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertEqual(self.events, [
            "resize:wait", "paste:terminate", "paste:wait",
            "firefox:window-close", "firefox:wait", "firefox:checkpoint",
            "openbox:terminate", "openbox:wait",
        ])
        self.assertEqual(stderr, "BROWSER_DISPLAY_ADAPTER_UNEXPECTED_EXIT\n"
                                 "BROWSER_SESSION_STOP_FAILED:display_adaptation_failed\n")
        self.assertIn("BROWSER_FIREFOX_EXIT=0", stdout)
        self.assertIn("BROWSER_CHECKPOINT_COMPLETE=1", stdout)
        self.assertEqual(json.loads(self.diagnostic.read_text()), {
            "schema": "browser-shutdown-check/v1",
            "firefox_exit_code": 0,
            "checkpoint_complete": True,
        })

    def test_invalid_window_manager_config_fails_before_any_process_starts(self):
        code, stdout, stderr = self.invoke(
            config_error=SESSION.ShutdownError("openbox_config_invalid")
        )
        self.assertEqual(code, 1)
        self.assertEqual(self.result.read_text(), "failed\n")
        self.assertEqual(self.events, [])
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "BROWSER_SESSION_STOP_FAILED:openbox_config_invalid\n")
        self.assertEqual(json.loads(self.diagnostic.read_text()), {
            "schema": "browser-shutdown-check/v1",
            "firefox_exit_code": None,
            "checkpoint_complete": False,
        })


class DiagnosticBoundaries(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.diagnostic = self.root / "stop-diagnostic"
        self.uid = 59998
        self.value = {
            "schema": "browser-shutdown-check/v1",
            "firefox_exit_code": 0,
            "checkpoint_complete": True,
        }

    def write(self, value=None, *, raw=None):
        if raw is None:
            raw = json.dumps(self.value if value is None else value).encode()
        self.diagnostic.write_bytes(raw)

    def invoke(self, mutate=False):
        real_open, real_fstat, real_read = os.open, os.fstat, os.read
        changed = False

        def redirect_open(path, flags):
            self.assertEqual(path, "/run/browser-session/stop-diagnostic")
            return real_open(self.diagnostic, flags)

        def owned_fstat(descriptor):
            info = real_fstat(descriptor)
            return SimpleNamespace(
                st_mode=info.st_mode, st_uid=self.uid, st_size=info.st_size,
                st_mtime_ns=info.st_mtime_ns, st_ctime_ns=info.st_ctime_ns,
            )

        def read(descriptor, size):
            nonlocal changed
            content = real_read(descriptor, size)
            if mutate:
                info = real_fstat(descriptor)
                os.utime(self.diagnostic, ns=(info.st_mtime_ns + 1_000_000,
                                              info.st_mtime_ns + 1_000_000))
                changed = True
            return content

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(STOP.os, "open", side_effect=redirect_open))
            stack.enter_context(mock.patch.object(STOP.os, "fstat", side_effect=owned_fstat))
            stack.enter_context(mock.patch.object(STOP.os, "read", side_effect=read))
            try:
                return STOP.read_diagnostic()
            finally:
                if mutate:
                    self.assertTrue(changed, "test must change metadata during the actual read")

    def reject(self, code):
        with self.assertRaisesRegex(RuntimeError, "^" + code + "$"):
            self.invoke()

    def test_fixed_success_diagnostic_is_accepted(self):
        self.write()
        self.assertEqual(self.invoke(), self.value)

    def test_failure_or_unavailable_diagnostic_is_accepted_as_data(self):
        for code in (None, -255, -15, 0, 255):
            with self.subTest(code=code):
                value = dict(self.value, firefox_exit_code=code, checkpoint_complete=False)
                self.write(value)
                self.assertEqual(self.invoke(), value)

    def test_diagnostic_owner_must_be_browser(self):
        self.write()
        self.uid = 0
        self.reject("shutdown_diagnostic_invalid")

    def test_directory_is_not_a_diagnostic(self):
        self.diagnostic.mkdir()
        self.reject("shutdown_diagnostic_invalid")

    def test_symlink_diagnostic_is_not_followed(self):
        target = self.root / "other-diagnostic"
        target.write_text(json.dumps(self.value))
        self.diagnostic.symlink_to(target)
        with self.assertRaises(OSError):
            self.invoke()

    def test_empty_or_oversized_diagnostic_fails(self):
        for payload in (b"", b" " * 257):
            with self.subTest(size=len(payload)):
                self.write(raw=payload)
                self.reject("shutdown_diagnostic_invalid")

    def test_exact_diagnostic_size_limit_is_accepted(self):
        payload = json.dumps(self.value).encode()
        self.write(raw=payload + b" " * (256 - len(payload)))
        self.assertEqual(self.invoke(), self.value)

    def test_malformed_or_invalid_utf8_diagnostic_fails(self):
        for payload in (b"{", b"\xff"):
            with self.subTest(payload=payload):
                self.write(raw=payload)
                self.reject("shutdown_diagnostic_invalid_json")

    def test_duplicate_diagnostic_keys_fail(self):
        payload = json.dumps(self.value)[:-1] + ', "checkpoint_complete": true}'
        self.write(raw=payload.encode())
        self.reject("shutdown_diagnostic_invalid_json")

    def test_non_object_diagnostic_fails(self):
        for payload in (b"[]", b"null", b"true", b"1"):
            with self.subTest(payload=payload):
                self.write(raw=payload)
                self.reject("shutdown_diagnostic_invalid")

    def test_diagnostic_requires_exact_fields_and_schema(self):
        missing = dict(self.value)
        del missing["checkpoint_complete"]
        for value in (missing, dict(self.value, extra=True), dict(self.value, schema="other")):
            with self.subTest(value=value):
                self.write(value)
                self.reject("shutdown_diagnostic_invalid")

    def test_exit_code_requires_bounded_integer_or_none(self):
        for code in (True, False, -256, 256, 0.0, "0", [], {}):
            with self.subTest(code=code):
                self.write(dict(self.value, firefox_exit_code=code))
                self.reject("shutdown_diagnostic_invalid")

    def test_checkpoint_complete_requires_boolean(self):
        for value in (None, 0, 1, "true", [], {}):
            with self.subTest(value=value):
                self.write(dict(self.value, checkpoint_complete=value))
                self.reject("shutdown_diagnostic_invalid")

    def test_diagnostic_changed_during_read_fails(self):
        self.write()
        with self.assertRaisesRegex(RuntimeError, "^shutdown_diagnostic_changed$"):
            self.invoke(mutate=True)


class HelperEntrypoint(unittest.TestCase):
    def test_os_error_reports_only_fixed_code_to_stderr_and_serial(self):
        marker = "synthetic_private_marker"
        stdout, stderr, serial = io.StringIO(), io.StringIO(), io.StringIO()

        def fail_cgroup_read(path, *arguments, **keywords):
            self.assertEqual(path, Path("/proc/self/cgroup"))
            raise OSError(marker)

        def open_serial(path, mode):
            self.assertEqual(path, "/dev/hvc0")
            self.assertEqual(mode, "w")
            return nullcontext(serial)

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(Path, "read_text", autospec=True,
                                                 side_effect=fail_cgroup_read))
            stack.enter_context(mock.patch("builtins.open", side_effect=open_serial))
            stack.enter_context(redirect_stdout(stdout))
            stack.enter_context(redirect_stderr(stderr))
            with self.assertRaises(SystemExit) as exit_result:
                runpy.run_path(str(ROOT / "guest/browser-runtime/stop-session.py"),
                               run_name="__main__")

        self.assertEqual(exit_result.exception.code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "Ordered browser shutdown failed: OSError\n")
        self.assertEqual(serial.getvalue(),
                         "BROWSER_SESSION_STOP_FAILED\nBROWSER_SESSION_STOP_ERROR=OSError\n")
        self.assertNotIn(marker, stdout.getvalue() + stderr.getvalue() + serial.getvalue())


if __name__ == "__main__":
    unittest.main()
