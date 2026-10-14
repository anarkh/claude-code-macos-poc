#!/usr/bin/env python3
"""Isolated browser paste protocol tests; no VM, GUI, or profile is used."""
from contextlib import contextmanager, redirect_stderr, redirect_stdout
import importlib.util
import errno
import io
from pathlib import Path
import socket
import struct
import sys
import threading
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "guest" / "browser-runtime" / "paste.py"
with mock.patch.object(sys, "dont_write_bytecode", True):
    SPEC = importlib.util.spec_from_file_location("guest_browser_paste_tests", SOURCE)
    PASTE = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(PASTE)


def frame(payload, declared=None, magic=b"BPT1"):
    return magic + struct.pack("!I", len(payload) if declared is None else declared) + payload


class PasteProtocol(unittest.TestCase):
    @contextmanager
    def channel(self, wire, *, eof=True):
        client, server = socket.socketpair()
        client.settimeout(2)
        errors = []

        def send():
            try:
                client.sendall(wire)
                if eof:
                    client.shutdown(socket.SHUT_WR)
            except OSError as error:
                errors.append(error)

        sender = threading.Thread(target=send, daemon=True)
        sender.start()
        try:
            yield server, client
        finally:
            server.close()
            sender.join(2)
            client.close()
            self.assertFalse(sender.is_alive(), "socketpair writer did not finish")
            # Refusing a non-host CID may close the peer before its write ends.
            self.assertTrue(all(error.errno in (errno.EPIPE, errno.ECONNRESET, errno.ENOTCONN) for error in errors), errors)

    def assert_rejected(self, wire):
        with self.channel(wire) as (channel, _):
            with self.assertRaises(PASTE.PasteError) as raised:
                PASTE.read_frame(channel)
        self.assertIs(type(raised.exception.status), int)
        self.assertEqual(raised.exception.status, 1)
        return raised.exception

    def receive_reply(self, client):
        parts = []
        while True:
            try:
                part = client.recv(1024)
            except ConnectionResetError:
                # A rejected request may close with unread inbound bytes. The
                # complete fixed ACK must still have been received first.
                self.assertTrue(parts, "peer reset before fixed ACK")
                break
            if not part:
                break
            parts.append(part)
        return b"".join(parts)

    def handle(self, wire, *, cid=2, deliver=None, stopped=lambda: False):
        output = io.StringIO()
        with self.channel(wire) as (channel, client):
            with redirect_stdout(output), redirect_stderr(output):
                PASTE.handle_connection(channel, cid, deliver or (lambda payload: None), stopped=stopped)
            self.assertEqual(channel.fileno(), -1, "handler must close the connection")
            reply = self.receive_reply(client)
        self.assertEqual(reply[:4], b"BPR1")
        self.assertEqual(len(reply), 5, "ACK must contain only magic and a one-byte fixed status")
        self.assertIn(reply[4], range(6))
        return reply, output.getvalue()

    def test_chinese_emoji_and_multiline_are_preserved(self):
        payload = "你好，Firefox！\n第二行🙂🚀\n".encode("utf-8")
        with self.channel(frame(payload)) as (channel, _):
            received = PASTE.read_frame(channel)
        self.assertIs(type(received), bytearray)
        self.assertEqual(received, payload)

    def test_one_byte_boundary_is_accepted(self):
        with self.channel(frame(b"x")) as (channel, _):
            self.assertEqual(PASTE.read_frame(channel), bytearray(b"x"))

    def test_exact_65536_byte_boundary_is_accepted(self):
        payload = ("中" * 21845 + "x").encode("utf-8")
        self.assertEqual(len(payload), 65536)
        with self.channel(frame(payload)) as (channel, _):
            self.assertEqual(PASTE.read_frame(channel), bytearray(payload))

    def test_empty_payload_is_rejected(self):
        self.assert_rejected(frame(b""))

    def test_oversized_declared_length_is_rejected_before_body(self):
        self.assert_rejected(frame(b"", declared=65537))

    def test_maximum_uint32_declared_length_is_rejected(self):
        self.assert_rejected(frame(b"", declared=0xFFFFFFFF))

    def test_unknown_protocol_magic_is_rejected(self):
        self.assert_rejected(frame(b"x", magic=b"BPT2"))

    def test_invalid_utf8_is_rejected(self):
        for payload in (b"\xff", b"\xc0\xaf", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xe4\xb8"):
            with self.subTest(payload=payload):
                self.assert_rejected(frame(payload))

    def test_nul_is_rejected(self):
        self.assert_rejected(frame(b"before\0after"))

    def test_truncated_magic_length_and_payload_are_rejected(self):
        for wire in (b"", b"BPT", b"BPT1\0\0", frame(b"xy", declared=3)):
            with self.subTest(wire=wire):
                self.assert_rejected(wire)

    def test_trailing_bytes_after_payload_are_rejected(self):
        self.assert_rejected(frame(b"x") + b"unexpected second frame")

    def test_absent_write_eof_times_out(self):
        with self.channel(frame(b"x"), eof=False) as (channel, _):
            with mock.patch.object(PASTE, "READ_SECONDS", 0.02):
                with self.assertRaises(PASTE.PasteError) as raised:
                    PASTE.read_frame(channel)
        self.assertEqual(raised.exception.status, 5)
        self.assertEqual(str(raised.exception), "request_timeout")

    def test_three_second_deadline_applies_to_the_whole_frame(self):
        self.assertEqual(PASTE.READ_SECONDS, 3)
        channel = mock.Mock(spec=socket.socket)
        wire = frame(b"x")
        now, cursor = [0.0], [0]

        def slow_read(buffer):
            buffer[0] = wire[cursor[0]]
            cursor[0] += 1
            now[0] += 1
            return 1

        channel.recv_into.side_effect = slow_read
        with mock.patch.object(PASTE.time, "monotonic", side_effect=lambda: now[0]):
            with self.assertRaises(PASTE.PasteError) as raised:
                PASTE.read_frame(channel)
        self.assertEqual(raised.exception.status, 5)
        self.assertEqual(channel.recv_into.call_count, 3, "each fragment must share the original deadline")

    def test_cancellation_before_read_is_rejected(self):
        channel = mock.Mock(spec=socket.socket)
        with self.assertRaises(PASTE.PasteError) as raised:
            PASTE.read_frame(channel, stopped=lambda: True)
        self.assertEqual(raised.exception.status, 5)
        channel.recv_into.assert_not_called()
        channel.recv.assert_not_called()

    def test_cancellation_during_frame_is_rejected(self):
        channel = mock.Mock(spec=socket.socket)
        cancelled = [False]
        allocated = []

        def receive(buffer):
            allocated.append(buffer.obj)
            value = frame(b"", declared=4) if len(allocated) == 1 else b"x"
            buffer[:len(value)] = value
            return len(value)

        channel.recv_into.side_effect = receive

        def stopped():
            if channel.recv_into.call_count >= 2:
                cancelled[0] = True
            return cancelled[0]

        with self.assertRaises(PASTE.PasteError) as raised:
            PASTE.read_frame(channel, stopped=stopped)
        self.assertEqual(raised.exception.status, 5)
        self.assertTrue(cancelled[0])
        self.assertEqual(allocated[-1], bytearray(4), "partially received payload must be wiped on cancellation")

    def test_success_ack_is_fixed_and_never_echoes_payload(self):
        original = "不应出现在应答中🙂\nsecret-paste".encode("utf-8")
        seen = []

        def deliver(payload):
            self.assertIs(type(payload), bytearray)
            self.assertEqual(payload, original)
            seen.append(payload)

        reply, output = self.handle(frame(original), deliver=deliver)
        self.assertEqual(reply, b"BPR1\0")
        self.assertNotIn("secret-paste", output)
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0], bytearray(len(original)), "delivered payload must be zeroized when handling ends")

    def test_rejected_host_cid_never_delivers(self):
        for cid in (0, 1, 3, 0xFFFFFFFF):
            with self.subTest(cid=cid):
                deliver = mock.Mock()
                reply, _ = self.handle(frame(b"private-payload"), cid=cid, deliver=deliver)
                self.assertEqual(reply, b"BPR1\x01")
                deliver.assert_not_called()

    def test_invalid_frame_ack_is_fixed_and_payload_is_not_delivered(self):
        deliver = mock.Mock()
        wire = frame(b"private-payload\0")
        first, output = self.handle(wire, deliver=deliver)
        second, _ = self.handle(wire, deliver=deliver)
        self.assertEqual(first, second)
        self.assertEqual(first, b"BPR1\x01")
        self.assertNotIn("private-payload", output)
        deliver.assert_not_called()

    def test_delivery_error_zeroizes_payload_and_returns_fixed_ack(self):
        seen = []

        def deliver(payload):
            seen.append(payload)
            raise RuntimeError("private-payload exception must not be echoed")

        first, output = self.handle(frame(b"private-payload"), deliver=deliver)
        second, _ = self.handle(frame(b"private-payload"), deliver=deliver)
        self.assertEqual(first, second)
        self.assertEqual(first, b"BPR1\x04")
        self.assertNotIn("private-payload", output)
        self.assertEqual(len(seen), 2)
        for payload in seen:
            self.assertEqual(payload, bytearray(len(b"private-payload")))

    def test_cancelled_handler_never_delivers_and_returns_fixed_ack(self):
        deliver = mock.Mock()
        first, output = self.handle(frame(b"private-payload"), deliver=deliver, stopped=lambda: True)
        second, _ = self.handle(frame(b"private-payload"), deliver=deliver, stopped=lambda: True)
        self.assertEqual(first, second)
        self.assertEqual(first, b"BPR1\x05")
        self.assertNotIn("private-payload", output)
        deliver.assert_not_called()

    def test_invalid_payload_buffers_are_zeroized(self):
        for wire in (frame(b"private\xff"), frame(b"private\0"), frame(b"private") + b"x"):
            with self.subTest(wire=wire):
                allocations = []

                def allocate(length):
                    result = bytearray(length)
                    allocations.append(result)
                    return result

                with mock.patch.object(PASTE, "bytearray", side_effect=allocate, create=True):
                    self.assert_rejected(wire)
                self.assertEqual(allocations[-1], bytearray(len(allocations[-1])))

    def test_busy_and_focus_errors_emit_fixed_status_without_echo(self):
        for status in (2, 3):
            with self.subTest(status=status):
                seen = []

                def deliver(payload):
                    seen.append(payload)
                    raise PASTE.PasteError(status, "private-code-must-not-be-returned")

                reply, output = self.handle(frame(b"private-payload"), deliver=deliver)
                self.assertEqual(reply, b"BPR1" + bytes([status]))
                self.assertNotIn("private", output)
                self.assertEqual(seen, [bytearray(len(b"private-payload"))])

    def test_ack_write_failure_still_zeroizes_payload_and_closes(self):
        payload = bytearray(b"private-payload")
        channel = mock.Mock(spec=socket.socket)
        channel.sendall.side_effect = OSError("private write error")
        output = io.StringIO()
        with mock.patch.object(PASTE, "read_frame", return_value=payload), redirect_stderr(output):
            PASTE.handle_connection(channel, 2, lambda received: None)
        self.assertEqual(payload, bytearray(len(b"private-payload")))
        channel.sendall.assert_called_once_with(b"BPR1\0")
        channel.close.assert_called_once()
        self.assertEqual(output.getvalue(), "BROWSER_PASTE_PEER_CLOSED\n")


class X11Boundaries(unittest.TestCase):
    def setUp(self):
        self.paste = PASTE.X11Paste.__new__(PASTE.X11Paste)
        self.paste.pid = 2468
        self.paste.stopped = lambda: False
        self.paste.x = mock.Mock()
        self.paste.xt = mock.Mock()
        self.paste.display = 1
        self.paste.root = 100
        self.paste.errors = False
        self.paste.previous_handler = None
        self.paste.atoms = {"_NET_ACTIVE_WINDOW": 1, "_NET_WM_PID": 2,
                            "CLIPBOARD": 3, "TARGETS": 4, "UTF8_STRING": 5}

    def set_focus(self, focus):
        def query(_display, window_pointer, _revert):
            PASTE.C.cast(window_pointer, PASTE.C.POINTER(PASTE.C.c_ulong))[0] = focus
            return 1
        self.paste.x.XGetInputFocus.side_effect = query

    def test_focus_requires_the_running_firefox_main_pid(self):
        self.set_focus(101)
        self.paste.property32 = mock.Mock(side_effect=lambda window, name, _type:
                                         101 if name == "_NET_ACTIVE_WINDOW" else 2468)
        with mock.patch.object(PASTE.os, "readlink", return_value="/opt/firefox/firefox"):
            self.paste.check_focus()
        self.paste.x.XSync.assert_called_once_with(1, False)

    def test_foreign_or_missing_window_pid_rejects_focus(self):
        for pid in (None, 9999):
            with self.subTest(pid=pid):
                self.paste.property32 = mock.Mock(side_effect=lambda window, name, _type:
                                                 101 if name == "_NET_ACTIVE_WINDOW" else pid)
                with mock.patch.object(PASTE.os, "readlink", return_value="/opt/firefox/firefox"):
                    with self.assertRaises(PASTE.PasteError) as raised:
                        self.paste.check_focus()
                self.assertEqual(raised.exception.status, 3)
        self.paste.xt.XTestFakeKeyEvent.assert_not_called()

    def test_non_firefox_executable_rejects_focus(self):
        with mock.patch.object(PASTE.os, "readlink", return_value="/usr/bin/other"):
            with self.assertRaises(PASTE.PasteError) as raised:
                self.paste.check_focus()
        self.assertEqual(raised.exception.status, 3)
        self.paste.x.XGetInputFocus.assert_not_called()

    def modifier_clock(self, keymap):
        now = [0.0]
        self.paste.x.XKeysymToKeycode.return_value = 37
        self.paste.x.XQueryKeymap.side_effect = keymap
        return mock.patch.object(PASTE.time, "monotonic", side_effect=lambda: now[0]), \
            mock.patch.object(PASTE.time, "sleep", side_effect=lambda seconds: now.__setitem__(0, now[0] + seconds))

    def test_modifiers_wait_for_release_without_injecting_keys(self):
        queries = [0]

        def keymap(_display, pressed):
            if queries[0] == 0:
                pressed[37 // 8] |= 1 << (37 % 8)
            queries[0] += 1

        monotonic, sleep = self.modifier_clock(keymap)
        with monotonic, sleep:
            self.paste.wait_modifiers()
        self.assertEqual(queries[0], 2)
        self.paste.xt.XTestFakeKeyEvent.assert_not_called()

    def test_held_modifiers_expire_without_forcing_release(self):
        self.assertEqual(PASTE.MODIFIER_SECONDS, 1)
        def keymap(_display, pressed):
            pressed[37 // 8] |= 1 << (37 % 8)

        monotonic, sleep = self.modifier_clock(keymap)
        with monotonic, sleep, mock.patch.object(PASTE, "MODIFIER_SECONDS", 0.02):
            with self.assertRaises(PASTE.PasteError) as raised:
                self.paste.wait_modifiers()
        self.assertEqual(raised.exception.status, 5)
        self.paste.xt.XTestFakeKeyEvent.assert_not_called()

    def test_failed_key_injection_releases_only_the_key_it_pressed(self):
        self.paste.x.XKeysymToKeycode.side_effect = [37, 55]
        self.paste.xt.XTestFakeKeyEvent.side_effect = [1, 0, 1]
        with self.assertRaises(PASTE.PasteError) as raised:
            self.paste.inject_paste()
        self.assertEqual(raised.exception.status, 4)
        self.assertEqual(self.paste.xt.XTestFakeKeyEvent.call_args_list, [
            mock.call(1, 37, True, 0), mock.call(1, 55, True, 0), mock.call(1, 37, False, 0),
        ])

    def selection_request(self, property_atom, target=None, requestor=101):
        event = PASTE.Event()
        event.request = PASTE.SelectionRequest(30, 0, 0, 1, 999, requestor, 3,
                                               5 if target is None else target, property_atom, 0)
        return event

    def property_deleted(self, property_atom, window=101):
        event = PASTE.Event()
        event.property = PASTE.PropertyNotify(28, 0, 0, 1, window, property_atom, 0, 1)
        return event

    def prepare_selection(self, requestor_pid, events=None, ownership_delay=0):
        self.paste.check_focus = mock.Mock()
        self.paste.wait_modifiers = mock.Mock()
        self.paste.inject_paste = mock.Mock()
        self.paste.property32 = mock.Mock(return_value=requestor_pid)
        self.paste.notify = mock.Mock()
        self.paste.x.XCreateSimpleWindow.return_value = 999
        owner = [0]
        now = [0.0]
        self.selection_now = now
        self.owner_changes = []

        def set_owner(_display, _atom, window, _time):
            owner[0] = window
            self.owner_changes.append((now[0], window))
            if window:
                now[0] += ownership_delay

        self.paste.x.XSetSelectionOwner.side_effect = set_owner
        self.paste.x.XGetSelectionOwner.side_effect = lambda _display, _atom: owner[0]
        pending = list(events if events is not None else [(0, self.selection_request(88))])
        self.selection_events = pending
        self.paste.x.XPending.side_effect = lambda _display: int(bool(pending) and pending[0][0] <= now[0])

        def next_event(_display, pointer):
            scheduled, event = pending.pop(0)
            self.assertLessEqual(scheduled, now[0])
            PASTE.C.memmove(pointer, PASTE.C.byref(event), PASTE.C.sizeof(PASTE.Event))
            return 0

        self.paste.x.XNextEvent.side_effect = next_event
        return owner, mock.patch.object(PASTE.time, "monotonic", side_effect=lambda: now[0]), \
            mock.patch.object(PASTE.time, "sleep", side_effect=lambda seconds: now.__setitem__(0, now[0] + 0.25))

    def test_selection_expiry_deletes_text_property_and_releases_owner(self):
        self.assertEqual(PASTE.SELECTION_SECONDS, 3)
        owner, monotonic, sleep = self.prepare_selection(2468)
        with monotonic, sleep:
            with self.assertRaises(PASTE.PasteError) as raised:
                self.paste.deliver(bytearray(b"private-payload"))
        self.assertEqual(raised.exception.status, 5)
        self.assertEqual(str(raised.exception), "selection_timeout")
        self.paste.x.XChangeProperty.assert_called_once()
        self.paste.x.XDeleteProperty.assert_called_once_with(1, 101, 88)
        self.assertEqual(owner[0], 0)
        self.paste.x.XDestroyWindow.assert_called_once_with(1, 999)
        self.paste.x.XCloseDisplay.assert_called_once_with(1)

    def test_repeat_utf8_reads_continue_after_first_delete_until_expiry(self):
        events = [
            (0, self.selection_request(88)),
            (0.25, self.property_deleted(88)),
            (0.5, self.selection_request(88)),
            (1, self.property_deleted(88)),
        ]
        owner, monotonic, sleep = self.prepare_selection(2468, events)
        payload = bytearray("中文🙂\n第二次读取".encode())
        with monotonic, sleep:
            self.paste.deliver(payload)
        writes = self.paste.x.XChangeProperty.call_args_list
        self.assertEqual(len(writes), 2, "first Delete must not end the controlled repeat-read lease")
        self.assertEqual([call.args[2] for call in writes], [88, 88])
        self.assertTrue(all(bytes(call.args[6]) == payload for call in writes))
        self.assertEqual(self.selection_now[0], 3)
        self.assertEqual(self.owner_changes[-1], (3, 0))
        self.assertEqual(owner[0], 0)
        self.paste.x.XDeleteProperty.assert_not_called()

    def test_selection_lease_never_renews_and_starts_before_setting_owner(self):
        events = [
            (0.75, self.selection_request(88)),
            (1, self.property_deleted(88)),
            (2.5, self.selection_request(89)),
            (3, self.selection_request(90)),
        ]
        owner, monotonic, sleep = self.prepare_selection(2468, events, ownership_delay=0.5)
        with monotonic, sleep:
            self.paste.deliver(bytearray(b"same-payload"))
        self.assertEqual([call.args[2] for call in self.paste.x.XChangeProperty.call_args_list], [88, 89])
        self.assertEqual(len(self.selection_events), 1, "a request at the fixed deadline must not be served")
        self.assertEqual(self.selection_now[0], 3)
        self.assertEqual(self.owner_changes[-1], (3, 0))
        self.assertEqual(owner[0], 0)
        self.paste.x.XDeleteProperty.assert_called_once_with(1, 101, 89)

    def test_expiry_deletes_only_broker_written_properties_still_present(self):
        events = [
            (0, self.selection_request(77, target=4)),
            (0, self.selection_request(88)),
            (0.25, self.property_deleted(88)),
            (0.5, self.property_deleted(66)),
            (0.5, self.property_deleted(77, window=202)),
            (0.75, self.selection_request(89)),
        ]
        _, monotonic, sleep = self.prepare_selection(2468, events)
        with monotonic, sleep:
            self.paste.deliver(bytearray(b"same-payload"))
        self.assertEqual(self.paste.x.XDeleteProperty.call_args_list, [
            mock.call(1, 101, 77), mock.call(1, 101, 89),
        ])
        self.assertEqual(self.owner_changes[-1], (3, 0))

    def test_cancellation_after_consumption_still_fails_and_releases_owner(self):
        events = [(0, self.selection_request(88)), (0.25, self.property_deleted(88))]
        owner, monotonic, sleep = self.prepare_selection(2468, events)
        self.paste.stopped = lambda: self.selection_now[0] >= 0.5
        with monotonic, sleep:
            with self.assertRaises(PASTE.PasteError) as raised:
                self.paste.deliver(bytearray(b"same-payload"))
        self.assertEqual(raised.exception.status, 5)
        self.assertEqual(owner[0], 0)
        self.assertEqual(self.owner_changes[-1], (0.5, 0))
        self.paste.x.XDeleteProperty.assert_not_called()

    def test_non_firefox_or_missing_selection_requestor_pid_never_gets_text(self):
        for pid in (None, 9999):
            with self.subTest(pid=pid):
                self.paste.x.reset_mock()
                owner, monotonic, sleep = self.prepare_selection(pid)
                with monotonic, sleep:
                    with self.assertRaises(PASTE.PasteError) as raised:
                        self.paste.deliver(bytearray(b"private-payload"))
                self.assertEqual(raised.exception.status, 5)
                self.paste.x.XChangeProperty.assert_not_called()
                self.paste.notify.assert_called_once()
                self.assertEqual(self.paste.notify.call_args.args[1], 0)
                self.assertEqual(owner[0], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
