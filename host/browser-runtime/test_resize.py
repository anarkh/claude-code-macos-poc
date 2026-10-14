#!/usr/bin/env python3
"""Isolated preferred-mode and event-loop tests with a deterministic clock."""
from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "guest/browser-runtime/resize.py"
with mock.patch.object(sys, "dont_write_bytecode", True):
    SPEC = importlib.util.spec_from_file_location("guest_browser_resize_tests", SOURCE)
    RESIZE = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = RESIZE
    SPEC.loader.exec_module(RESIZE)


class EventDriver:
    """Advance to queued events or the requested deadline without real select."""
    EVENT_FD = 77
    WAKE_FD = 88

    def __init__(self, case, modes, events):
        self.case = case
        self.now = 0.0
        self.stopped = False
        self.events = list(events)
        self.modes = list(modes)
        self.relevance = []
        self.waits = []
        self.query_times = []
        self.drained_events = 0
        self.backend = mock.Mock()
        self.backend.event_fd = self.EVENT_FD
        self.backend.query_modes.side_effect = self.query
        self.backend.drain_events.side_effect = self.drain

    def query(self):
        self.query_times.append(self.now)
        self.case.assertTrue(self.modes, "unexpected repeated mode query")
        return self.modes.pop(0)

    def drain(self):
        if not self.relevance:
            return False
        self.drained_events += 1
        return self.relevance.pop(0)

    def wait(self, readable, writable, exceptional, timeout=None):
        self.case.assertEqual(set(readable), {self.EVENT_FD, self.WAKE_FD})
        self.case.assertEqual(writable, [])
        self.case.assertEqual(exceptional, [])
        self.waits.append((self.now, timeout))
        self.case.assertLess(len(self.waits), 20, "event loop did not stop or began polling")
        self.case.assertTrue(self.events, "event loop waited after its terminal wake")
        scheduled, descriptor, relevant = self.events[0]
        if timeout is not None and scheduled > self.now + timeout + 1e-10:
            self.case.assertGreater(timeout, 0)
            self.now += timeout
            return [], [], []
        self.events.pop(0)
        self.case.assertGreaterEqual(scheduled + 1e-10, self.now)
        self.now = scheduled
        if descriptor == self.WAKE_FD:
            self.stopped = True
        else:
            self.relevance.append(relevant)
        return [descriptor], [], []

    def run(self):
        with ExitStack() as stack:
            if hasattr(RESIZE, "os"):
                stack.enter_context(mock.patch.object(RESIZE.os, "read", return_value=b"x"))
            loop = RESIZE.ResizeLoop(self.backend, lambda: self.stopped,
                                    wait=self.wait, clock=lambda: self.now)
            with redirect_stdout(io.StringIO()):
                loop.run(self.WAKE_FD)


class PreferredMode(unittest.TestCase):
    def test_equal_mode_is_one_query_with_no_command(self):
        backend = mock.Mock()
        backend.query_modes.return_value = (101, 101)
        RESIZE.apply_preferred(backend)
        backend.query_modes.assert_called_once_with()
        backend.apply_mode.assert_not_called()

    def test_changed_mode_is_applied_once_then_confirmed(self):
        backend = mock.Mock()
        backend.query_modes.side_effect = [(101, 202), (202, 202)]
        RESIZE.apply_preferred(backend)
        self.assertEqual(backend.method_calls, [mock.call.query_modes(), mock.call.apply_mode(), mock.call.query_modes()])

    def test_unchanged_mismatch_fails_once_without_retry(self):
        backend = mock.Mock()
        backend.query_modes.side_effect = [(101, 202), (101, 202)]
        with self.assertRaisesRegex(RESIZE.ResizeError, "^preferred_mode_not_applied$"):
            RESIZE.apply_preferred(backend)
        self.assertEqual(backend.query_modes.call_count, 2)
        backend.apply_mode.assert_called_once_with()

    def test_disappeared_preferred_mode_is_an_explicit_error(self):
        backend = mock.Mock()
        backend.query_modes.return_value = (101, None)
        with self.assertRaisesRegex(RESIZE.ResizeError, "^preferred_mode_missing$"):
            RESIZE.apply_preferred(backend)
        backend.apply_mode.assert_not_called()

    def test_preferred_disappearing_during_confirmation_fails_explicitly(self):
        backend = mock.Mock()
        backend.query_modes.side_effect = [(101, 202), (101, None)]
        with self.assertRaisesRegex(RESIZE.ResizeError, "^preferred_mode_missing$"):
            RESIZE.apply_preferred(backend)
        backend.apply_mode.assert_called_once_with()
        self.assertEqual(backend.query_modes.call_count, 2)

    def test_changed_mode_still_mismatching_preferred_is_not_accepted(self):
        backend = mock.Mock()
        backend.query_modes.side_effect = [(101, 202), (303, 202)]
        with self.assertRaisesRegex(RESIZE.ResizeError, "^preferred_mode_not_applied$"):
            RESIZE.apply_preferred(backend)
        backend.apply_mode.assert_called_once_with()
        self.assertEqual(backend.query_modes.call_count, 2)

    def test_command_error_is_fixed_and_is_not_retried(self):
        backend = mock.Mock()
        backend.query_modes.return_value = (101, 202)
        backend.apply_mode.side_effect = RESIZE.ResizeError("fixed_command_failed")
        with self.assertRaisesRegex(RESIZE.ResizeError, "^fixed_command_failed$"):
            RESIZE.apply_preferred(backend)
        backend.query_modes.assert_called_once_with()
        backend.apply_mode.assert_called_once_with()


class ResizeEvents(unittest.TestCase):
    def test_initial_application_follows_subscription_and_confirms_mode(self):
        driver = EventDriver(self, [(101, 202), (202, 202)], [(10, EventDriver.WAKE_FD, False)])
        driver.run()
        self.assertEqual(driver.backend.method_calls[:4], [
            mock.call.subscribe(), mock.call.query_modes(), mock.call.apply_mode(), mock.call.query_modes(),
        ])
        self.assertEqual(driver.waits, [(0, None)])
        self.assertEqual(driver.drained_events, 0)

    def test_idle_has_no_periodic_query_or_timeout(self):
        driver = EventDriver(self, [(101, 101)], [(3600, EventDriver.WAKE_FD, False)])
        driver.run()
        driver.backend.query_modes.assert_called_once_with()
        driver.backend.apply_mode.assert_not_called()
        self.assertEqual(driver.waits, [(0, None)])

    def test_irrelevant_event_keeps_idle_wait_without_requery(self):
        driver = EventDriver(self, [(101, 101)], [
            (1, EventDriver.EVENT_FD, False), (100, EventDriver.WAKE_FD, False),
        ])
        driver.run()
        driver.backend.query_modes.assert_called_once_with()
        driver.backend.apply_mode.assert_not_called()
        self.assertEqual(driver.drained_events, 1)
        self.assertEqual(driver.waits, [(0, None), (1, None)])

    def test_burst_keeps_original_deadline_and_self_feedback_does_not_reapply(self):
        self.assertEqual(RESIZE.DEBOUNCE_SECONDS, 0.1)
        driver = EventDriver(self, [(101, 101), (101, 202), (202, 202), (202, 202)], [
            (1, EventDriver.EVENT_FD, True),
            (1.04, EventDriver.EVENT_FD, True),
            (1.09, EventDriver.EVENT_FD, True),
            (1.11, EventDriver.EVENT_FD, True),
            (2, EventDriver.WAKE_FD, False),
        ])
        driver.run()
        driver.backend.apply_mode.assert_called_once_with()
        self.assertEqual(driver.backend.query_modes.call_count, 4)
        self.assertEqual(driver.drained_events, 4)
        self.assertEqual(len(driver.query_times), 4)
        for actual, expected in zip(driver.query_times, (0, 1.1, 1.1, 1.21)):
            self.assertAlmostEqual(actual, expected, places=8)
        timeouts = [timeout for _, timeout in driver.waits if timeout is not None]
        for expected in (0.1, 0.06, 0.01):
            self.assertTrue(any(abs(timeout - expected) < 1e-8 for timeout in timeouts), timeouts)
        self.assertIsNone(driver.waits[-1][1])

    def test_stop_wake_interrupts_pending_debounce_without_applying(self):
        driver = EventDriver(self, [(101, 101)], [
            (1, EventDriver.EVENT_FD, True), (1.05, EventDriver.WAKE_FD, False),
        ])
        driver.run()
        self.assertEqual(driver.now, 1.05)
        driver.backend.query_modes.assert_called_once_with()
        driver.backend.apply_mode.assert_not_called()
        self.assertEqual(driver.drained_events, 1)
        self.assertEqual(len(driver.waits), 2)

    def test_new_preferred_id_during_command_is_applied_on_the_next_randr_event(self):
        driver = EventDriver(self, [
            (101, 101), (101, 202), (202, 303), (202, 303), (303, 303),
        ], [
            (1, EventDriver.EVENT_FD, True),
            (1.11, EventDriver.EVENT_FD, True),
            (2, EventDriver.WAKE_FD, False),
        ])
        driver.run()
        self.assertEqual(driver.backend.apply_mode.call_count, 2)
        self.assertEqual(driver.backend.query_modes.call_count, 5)
        self.assertEqual(driver.drained_events, 2)
        for actual, expected in zip(driver.query_times, (0, 1.1, 1.1, 1.21, 1.21)):
            self.assertAlmostEqual(actual, expected, places=8)
        self.assertIsNone(driver.waits[-1][1])

    def test_already_stopped_subscribes_then_exits_without_query_or_wait(self):
        driver = EventDriver(self, [], [])
        driver.stopped = True
        driver.run()
        driver.backend.subscribe.assert_called_once_with()
        driver.backend.query_modes.assert_not_called()
        driver.backend.apply_mode.assert_not_called()
        self.assertEqual(driver.waits, [])


class DisplayDriverBoundaries(unittest.TestCase):
    def make_driver(self):
        driver = RESIZE.DisplayDriver.__new__(RESIZE.DisplayDriver)
        driver.x, driver.r = mock.Mock(), mock.Mock()
        driver.display, driver.root, driver.errors = 1, 100, False
        driver.previous_handler = 123
        outputs = (RESIZE.C.c_ulong * 1)(42)
        modes = (RESIZE.C.c_ulong * 2)(202, 303)
        name = RESIZE.C.create_string_buffer(b"Virtual-1")
        resources = RESIZE.C.pointer(RESIZE.Resources(noutput=1, outputs=outputs))
        output = RESIZE.C.pointer(RESIZE.OutputInfo(
            crtc=77, name=RESIZE.C.cast(name, RESIZE.C.c_void_p), nameLen=9,
            connection=0, nmode=2, npreferred=1, modes=modes))
        crtc = RESIZE.C.pointer(RESIZE.CrtcInfo(mode=101))
        # Keep all Python-owned backing allocations alive for the ctypes views.
        driver.fixture = (outputs, modes, name, resources, output, crtc)
        driver.r.XRRGetScreenResourcesCurrent.return_value = resources
        driver.r.XRRGetOutputInfo.return_value = output
        driver.r.XRRGetCrtcInfo.return_value = crtc
        return driver, resources, output, crtc

    def assert_resources_freed(self, driver, resources, output, crtc):
        driver.r.XRRFreeCrtcInfo.assert_called_once_with(crtc)
        driver.r.XRRFreeOutputInfo.assert_called_once_with(output)
        driver.r.XRRFreeScreenResources.assert_called_once_with(resources)

    def test_randr_abi_has_the_expected_sizes_and_short_fields(self):
        self.assertEqual([RESIZE.C.sizeof(kind) for kind in
                          (RESIZE.Resources, RESIZE.OutputInfo, RESIZE.CrtcInfo)], [64, 96, 64])
        self.assertIs(dict(RESIZE.OutputInfo._fields_)["connection"], RESIZE.C.c_ushort)
        self.assertIs(dict(RESIZE.CrtcInfo._fields_)["rotation"], RESIZE.C.c_ushort)

    def test_successful_query_frees_all_acquired_randr_resources(self):
        driver, resources, output, crtc = self.make_driver()
        self.assertEqual(driver.query_modes(), (101, 202))
        self.assert_resources_freed(driver, resources, output, crtc)

    def test_x11_error_after_query_frees_all_acquired_randr_resources(self):
        driver, resources, output, crtc = self.make_driver()
        driver.errors = True
        with self.assertRaisesRegex(RESIZE.ResizeError, "^randr_request_failed$"):
            driver.query_modes()
        self.assert_resources_freed(driver, resources, output, crtc)

    def test_missing_preferred_in_real_driver_is_fixed_and_releases_resources(self):
        driver, resources, output, _ = self.make_driver()
        output.contents.npreferred = 0
        with self.assertRaisesRegex(RESIZE.ResizeError, "^preferred_mode_missing$"):
            driver.query_modes()
        driver.r.XRRGetCrtcInfo.assert_not_called()
        driver.r.XRRFreeCrtcInfo.assert_not_called()
        driver.r.XRRFreeOutputInfo.assert_called_once_with(output)
        driver.r.XRRFreeScreenResources.assert_called_once_with(resources)

    def test_xrandr_failures_use_only_the_fixed_command_and_error_codes(self):
        timeout = RESIZE.subprocess.TimeoutExpired
        cases = (
            ([7], "xrandr_apply_failed", False),
            ([timeout("private command", 2, output=b"private output"), 0], "xrandr_apply_timeout", True),
            ([timeout("private command", 2), timeout("private command", 1)], "xrandr_stop_timeout", True),
        )
        for waits, code, terminated in cases:
            with self.subTest(code=code):
                driver, _, _, _ = self.make_driver()
                process = mock.Mock()
                process.wait.side_effect = waits
                with mock.patch.object(RESIZE.subprocess, "Popen", return_value=process) as popen:
                    with self.assertRaisesRegex(RESIZE.ResizeError, "^" + code + "$") as raised:
                        driver.apply_mode()
                self.assertNotIn("private", str(raised.exception))
                popen.assert_called_once_with(
                    ["/usr/bin/xrandr", "--output", "Virtual-1", "--auto"],
                    stdout=RESIZE.subprocess.DEVNULL, stderr=RESIZE.subprocess.DEVNULL)
                self.assertEqual(process.wait.call_args_list,
                                 [mock.call(timeout=2), mock.call(timeout=1)] if terminated else [mock.call(timeout=2)])
                self.assertEqual(process.terminate.call_count, int(terminated))
                process.kill.assert_not_called()

    def test_close_releases_display_and_restores_previous_error_handler(self):
        driver, _, _, _ = self.make_driver()
        driver.close()
        self.assertEqual(driver.x.method_calls, [mock.call.XCloseDisplay(1), mock.call.XSetErrorHandler(123)])

    def test_main_error_closes_driver_wake_pipe_and_restores_wakeup_fd(self):
        driver = mock.Mock()
        loop = mock.Mock()
        loop.run.side_effect = RESIZE.ResizeError("fixed_loop_error")
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(RESIZE, "DisplayDriver", return_value=driver))
            stack.enter_context(mock.patch.object(RESIZE, "ResizeLoop", return_value=loop))
            stack.enter_context(mock.patch.object(RESIZE.os, "pipe", return_value=(10, 11)))
            stack.enter_context(mock.patch.object(RESIZE.os, "set_blocking"))
            close = stack.enter_context(mock.patch.object(RESIZE.os, "close"))
            wakeup = stack.enter_context(mock.patch.object(RESIZE.signal, "set_wakeup_fd", side_effect=[123, 11]))
            stack.enter_context(mock.patch.object(RESIZE.signal, "signal"))
            with self.assertRaisesRegex(RESIZE.ResizeError, "^fixed_loop_error$"):
                RESIZE.main()
        driver.close.assert_called_once_with()
        self.assertEqual(close.call_args_list, [mock.call(10), mock.call(11)])
        self.assertEqual(wakeup.call_args_list, [mock.call(11), mock.call(123)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
