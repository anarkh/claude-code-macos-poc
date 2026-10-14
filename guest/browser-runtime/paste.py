#!/usr/bin/python3
"""One requested host-to-Firefox UTF-8 paste; never read a clipboard value."""
import argparse
import ctypes as C
import os
import signal
import socket
import struct
import sys
import threading
import time

PORT = 40127
LIMIT = 65536
READ_SECONDS = 3
SELECTION_SECONDS = 3
MODIFIER_SECONDS = 1


class PasteError(RuntimeError):
    def __init__(self, status, code):
        super().__init__(code)
        self.status = status


def wipe(payload):
    payload[:] = b'\0' * len(payload)


def read_exact(channel, length, deadline, stopped):
    result = bytearray(length)
    cursor = 0
    try:
        while cursor < length:
            remaining = deadline - time.monotonic()
            if stopped() or remaining <= 0:
                raise PasteError(5, 'request_timeout')
            channel.settimeout(min(remaining, 0.1))
            try:
                count = channel.recv_into(memoryview(result)[cursor:])
            except socket.timeout:
                continue
            if not count:
                raise PasteError(1, 'frame_truncated')
            cursor += count
        return result
    except Exception:
        wipe(result)
        raise


def read_frame(channel, stopped=lambda: False):
    deadline = time.monotonic() + READ_SECONDS
    header = read_exact(channel, 8, deadline, stopped)
    if header[:4] != b'BPT1':
        raise PasteError(1, 'frame_magic')
    length = struct.unpack('!I', header[4:])[0]
    if not 1 <= length <= LIMIT:
        raise PasteError(1, 'frame_length')
    payload = read_exact(channel, length, deadline, stopped)
    try:
        if b'\0' in payload:
            raise PasteError(1, 'text_nul')
        try:
            payload.decode('utf-8', errors='strict')
        except UnicodeError:
            raise PasteError(1, 'text_utf8') from None
        while True:
            remaining = deadline - time.monotonic()
            if stopped() or remaining <= 0:
                raise PasteError(5, 'request_timeout')
            channel.settimeout(min(remaining, 0.1))
            try:
                trailing = channel.recv(1)
            except socket.timeout:
                continue
            if trailing:
                raise PasteError(1, 'frame_trailing')
            return payload
    except Exception:
        wipe(payload)
        raise


def handle_connection(channel, peer_cid, deliver, stopped=lambda: False):
    payload = None
    status = 1
    try:
        if peer_cid != 2:
            raise PasteError(1, 'peer_not_host')
        payload = read_frame(channel, stopped)
        deliver(payload)
        status = 0
    except PasteError as error:
        status = error.status
    except Exception:
        status = 4
    finally:
        if payload is not None:
            wipe(payload)
        try:
            channel.settimeout(0.2)
            channel.sendall(b'BPR1' + bytes([status]))
        except OSError:
            # A fixed failure response was attempted; peer disconnection has no retry.
            print('BROWSER_PASTE_PEER_CLOSED', file=sys.stderr)
        channel.close()


class SelectionRequest(C.Structure):
    _fields_ = [('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
                ('display', C.c_void_p), ('owner', C.c_ulong), ('requestor', C.c_ulong),
                ('selection', C.c_ulong), ('target', C.c_ulong), ('property', C.c_ulong),
                ('time', C.c_ulong)]


class SelectionNotify(C.Structure):
    _fields_ = [('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
                ('display', C.c_void_p), ('requestor', C.c_ulong), ('selection', C.c_ulong),
                ('target', C.c_ulong), ('property', C.c_ulong), ('time', C.c_ulong)]


class PropertyNotify(C.Structure):
    _fields_ = [('type', C.c_int), ('serial', C.c_ulong), ('send_event', C.c_int),
                ('display', C.c_void_p), ('window', C.c_ulong), ('atom', C.c_ulong),
                ('time', C.c_ulong), ('state', C.c_int)]


class Event(C.Union):
    _fields_ = [('type', C.c_int), ('request', SelectionRequest),
                ('selection', SelectionNotify), ('property', PropertyNotify),
                ('pad', C.c_long * 24)]


class X11Paste:
    def __init__(self, firefox_pid, stopped=lambda: False):
        self.pid, self.stopped = firefox_pid, stopped
        self.x = C.CDLL('libX11.so.6')
        self.xt = C.CDLL('libXtst.so.6')
        pointer, window, atom = C.c_void_p, C.c_ulong, C.c_ulong
        signatures = {
            'XOpenDisplay': ([C.c_char_p], pointer),
            'XCloseDisplay': ([pointer], C.c_int),
            'XDefaultRootWindow': ([pointer], window),
            'XInternAtom': ([pointer, C.c_char_p, C.c_int], atom),
            'XGetWindowProperty': ([pointer, window, atom, C.c_long, C.c_long, C.c_int,
                atom, C.POINTER(atom), C.POINTER(C.c_int), C.POINTER(C.c_ulong),
                C.POINTER(C.c_ulong), C.POINTER(pointer)], C.c_int),
            'XFree': ([pointer], C.c_int),
            'XGetInputFocus': ([pointer, C.POINTER(window), C.POINTER(C.c_int)], C.c_int),
            'XQueryTree': ([pointer, window, C.POINTER(window), C.POINTER(window),
                C.POINTER(pointer), C.POINTER(C.c_uint)], C.c_int),
            'XQueryKeymap': ([pointer, pointer], C.c_int),
            'XKeysymToKeycode': ([pointer, C.c_ulong], C.c_ubyte),
            'XCreateSimpleWindow': ([pointer, window, C.c_int, C.c_int, C.c_uint,
                C.c_uint, C.c_uint, C.c_ulong, C.c_ulong], window),
            'XDestroyWindow': ([pointer, window], C.c_int),
            'XSetSelectionOwner': ([pointer, atom, window, C.c_ulong], C.c_int),
            'XGetSelectionOwner': ([pointer, atom], window),
            'XChangeProperty': ([pointer, window, atom, atom, C.c_int, C.c_int,
                pointer, C.c_int], C.c_int),
            'XDeleteProperty': ([pointer, window, atom], C.c_int),
            'XSelectInput': ([pointer, window, C.c_long], C.c_int),
            'XSendEvent': ([pointer, window, C.c_int, C.c_long, C.POINTER(Event)], C.c_int),
            'XSync': ([pointer, C.c_int], C.c_int),
            'XPending': ([pointer], C.c_int),
            'XNextEvent': ([pointer, C.POINTER(Event)], C.c_int),
            'XSetErrorHandler': ([pointer], pointer),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.x, name)
            function.argtypes, function.restype = arguments, result
        self.xt.XTestFakeKeyEvent.argtypes = [pointer, C.c_uint, C.c_int, C.c_ulong]
        self.xt.XTestFakeKeyEvent.restype = C.c_int
        self.display = self.x.XOpenDisplay(None)
        if not self.display:
            raise PasteError(4, 'display_unavailable')
        self.root = self.x.XDefaultRootWindow(self.display)
        self.atoms = {name: self.x.XInternAtom(self.display, name.encode(), False)
                      for name in ('_NET_ACTIVE_WINDOW', '_NET_WM_PID', 'CLIPBOARD', 'TARGETS', 'UTF8_STRING')}
        self.errors = False
        self.callback_type = C.CFUNCTYPE(C.c_int, pointer, pointer)
        self.error_handler = self.callback_type(self.on_error)
        self.previous_handler = self.x.XSetErrorHandler(C.cast(self.error_handler, pointer))

    def on_error(self, _display, _event):
        self.errors = True
        return 0

    def sync(self):
        self.x.XSync(self.display, False)
        if self.errors:
            raise PasteError(4, 'x11_request_failed')

    def property32(self, window, name, expected_type):
        actual, fmt, count, remaining, content = C.c_ulong(), C.c_int(), C.c_ulong(), C.c_ulong(), C.c_void_p()
        try:
            status = self.x.XGetWindowProperty(self.display, window, self.atoms[name], 0, 1,
                False, expected_type, C.byref(actual), C.byref(fmt), C.byref(count),
                C.byref(remaining), C.byref(content))
            if (status != 0 or actual.value != expected_type or fmt.value != 32
                    or count.value != 1 or remaining.value or not content):
                return None
            return C.cast(content, C.POINTER(C.c_ulong))[0]
        finally:
            if content:
                self.x.XFree(content)

    def owned(self, window):
        return bool(window) and self.property32(window, '_NET_WM_PID', 6) == self.pid

    def check_focus(self):
        try:
            executable = os.readlink('/proc/' + str(self.pid) + '/exe')
            if executable not in ('/opt/firefox/firefox', '/opt/firefox/firefox-bin'):
                raise PasteError(3, 'firefox_not_running')
        except OSError:
            raise PasteError(3, 'firefox_not_running') from None
        active = self.property32(self.root, '_NET_ACTIVE_WINDOW', 33)
        if not active or not self.owned(active):
            raise PasteError(3, 'focus_not_firefox')
        focus, revert = C.c_ulong(), C.c_int()
        self.x.XGetInputFocus(self.display, C.byref(focus), C.byref(revert))
        current = focus.value
        for _ in range(16):
            if current == active or self.owned(current):
                self.sync()
                return
            if current in (0, 1, self.root):
                break
            root, parent, children, count = C.c_ulong(), C.c_ulong(), C.c_void_p(), C.c_uint()
            try:
                if not self.x.XQueryTree(self.display, current, C.byref(root), C.byref(parent), C.byref(children), C.byref(count)):
                    break
                current = parent.value
            finally:
                if children:
                    self.x.XFree(children)
        raise PasteError(3, 'focus_not_firefox')

    def wait_modifiers(self):
        symbols = (0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe7, 0xffe8,
                   0xffe9, 0xffea, 0xffeb, 0xffec)
        keys = {self.x.XKeysymToKeycode(self.display, symbol) for symbol in symbols} - {0}
        deadline = time.monotonic() + MODIFIER_SECONDS
        while not self.stopped() and time.monotonic() < deadline:
            pressed = (C.c_ubyte * 32)()
            self.x.XQueryKeymap(self.display, pressed)
            self.sync()
            if not any(pressed[key // 8] & (1 << (key % 8)) for key in keys):
                return
            time.sleep(0.01)
        raise PasteError(5, 'modifiers_still_pressed')

    def inject_paste(self):
        control = self.x.XKeysymToKeycode(self.display, 0xffe3)
        letter = self.x.XKeysymToKeycode(self.display, ord('v'))
        if not control or not letter:
            raise PasteError(4, 'paste_keys_unavailable')
        pressed = []
        try:
            for key in (control, letter):
                if not self.xt.XTestFakeKeyEvent(self.display, key, True, 0):
                    raise PasteError(4, 'paste_key_failed')
                pressed.append(key)
            self.sync()
        finally:
            for key in reversed(pressed):
                self.xt.XTestFakeKeyEvent(self.display, key, False, 0)
            self.sync()

    def notify(self, request, property_atom):
        response = Event()
        response.selection = SelectionNotify(31, 0, True, self.display, request.requestor,
            request.selection, request.target, property_atom, request.time)
        if not self.x.XSendEvent(self.display, request.requestor, False, 0, C.byref(response)):
            raise PasteError(4, 'selection_notify_failed')
        self.sync()

    def deliver(self, payload):
        owner, written_properties, consumed = 0, {}, False
        try:
            self.check_focus()
            self.wait_modifiers()
            self.check_focus()
            owner = self.x.XCreateSimpleWindow(self.display, self.root, 0, 0, 1, 1, 0, 0, 0)
            deadline = time.monotonic() + SELECTION_SECONDS
            self.x.XSetSelectionOwner(self.display, self.atoms['CLIPBOARD'], owner, 0)
            self.sync()
            if self.x.XGetSelectionOwner(self.display, self.atoms['CLIPBOARD']) != owner:
                raise PasteError(4, 'selection_owner_failed')
            self.inject_paste()
            # Firefox's paste handler and default editor can read the same text
            # separately. PropertyDelete acknowledges a read, not DOM insertion.
            while not self.stopped() and time.monotonic() < deadline:
                if not self.x.XPending(self.display):
                    time.sleep(0.01)
                    continue
                event = Event()
                self.x.XNextEvent(self.display, C.byref(event))
                if event.type == 29:
                    raise PasteError(4, 'selection_replaced')
                if event.type == 28 and event.property.state == 1:
                    pair = (event.property.window, event.property.atom)
                    kind = written_properties.pop(pair, None)
                    if kind == 'text':
                        consumed = True
                    continue
                if event.type != 30:
                    continue
                request = event.request
                target = request.property or request.target
                if (request.owner != owner or request.selection != self.atoms['CLIPBOARD']
                        or not self.owned(request.requestor)):
                    self.notify(request, 0)
                    continue
                self.check_focus()
                if request.target == self.atoms['TARGETS']:
                    targets = (C.c_ulong * 2)(self.atoms['TARGETS'], self.atoms['UTF8_STRING'])
                    self.x.XSelectInput(self.display, request.requestor, 1 << 22)
                    self.x.XChangeProperty(self.display, request.requestor, target, 4, 32, 0, targets, 2)
                    written_properties[(request.requestor, target)] = 'targets'
                elif request.target == self.atoms['UTF8_STRING']:
                    self.x.XSelectInput(self.display, request.requestor, 1 << 22)
                    content = (C.c_ubyte * len(payload)).from_buffer(payload)
                    self.x.XChangeProperty(self.display, request.requestor, target,
                        self.atoms['UTF8_STRING'], 8, 0, content, len(payload))
                    written_properties[(request.requestor, target)] = 'text'
                else:
                    self.notify(request, 0)
                    continue
                self.notify(request, target)
            if not self.stopped() and consumed:
                return
            raise PasteError(5, 'selection_timeout')
        finally:
            for pair in written_properties:
                self.x.XDeleteProperty(self.display, *pair)
            if owner:
                if self.x.XGetSelectionOwner(self.display, self.atoms['CLIPBOARD']) == owner:
                    self.x.XSetSelectionOwner(self.display, self.atoms['CLIPBOARD'], 0, 0)
                self.x.XDestroyWindow(self.display, owner)
            self.x.XSync(self.display, False)
            self.x.XCloseDisplay(self.display)
            self.x.XSetErrorHandler(self.previous_handler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--firefox-pid', type=int, required=True)
    arguments = parser.parse_args()
    stop = threading.Event()
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, lambda _number, _frame: stop.set())
    busy = threading.Lock()
    worker = None
    def run(channel, cid):
        try:
            handle_connection(channel, cid,
                lambda payload: X11Paste(arguments.firefox_pid, stop.is_set).deliver(payload), stop.is_set)
        finally:
            busy.release()
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as server:
        server.bind((socket.VMADDR_CID_ANY, PORT))
        server.listen(1)
        server.settimeout(0.2)
        print('BROWSER_PASTE_READY', flush=True)
        while not stop.is_set():
            try:
                channel, peer = server.accept()
            except socket.timeout:
                continue
            if not busy.acquire(blocking=False):
                try:
                    channel.settimeout(0.2)
                    channel.sendall(b'BPR1\x02')
                except OSError:
                    print('BROWSER_PASTE_PEER_CLOSED', file=sys.stderr)
                finally:
                    channel.close()
                continue
            worker = threading.Thread(target=run, args=(channel, peer[0]), daemon=True)
            worker.start()
    if worker:
        worker.join(timeout=4)
        if worker.is_alive():
            raise PasteError(5, 'worker_shutdown_timeout')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        code = str(error) if type(error) is PasteError else type(error).__name__
        print('BROWSER_PASTE_FAILED:' + code, file=sys.stderr)
        raise SystemExit(1)
