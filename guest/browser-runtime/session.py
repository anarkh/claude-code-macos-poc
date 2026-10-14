#!/usr/bin/python3
"""Keep the X client alive until Firefox and then Openbox have exited."""
import os
import json
import ctypes
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

RESULT = Path('/run/browser-session/stop-result')
DIAGNOSTIC = Path('/run/browser-session/stop-diagnostic')
CHECKPOINT_LIMIT = 16384
stopping = False


class ShutdownError(RuntimeError):
    """A fixed diagnostic code owned by this supervisor."""


def request_stop(_number, _frame):
    global stopping
    stopping = True


def _stamp(info):
    return (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_ctime_ns, info.st_size)


def checkpoint_stamp(path):
    try:
        return _stamp(path.lstat())
    except FileNotFoundError:
        return None


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate_checkpoint_key')
        result[key] = value
    return result


def validate_shutdown_checkpoint(profile, previous_stamp, launched_ns):
    """Read only bounded shutdown booleans; never expose browsing state."""
    checkpoint = profile / 'sessionCheckpoints.json'
    try:
        descriptor = os.open(checkpoint, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise ShutdownError('checkpoint_missing') from None
    except OSError:
        raise ShutdownError('checkpoint_open_failed') from None
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ShutdownError('checkpoint_not_regular')
        if not 0 < info.st_size <= CHECKPOINT_LIMIT:
            raise ShutdownError('checkpoint_size_invalid')
        current_stamp = _stamp(info)
        if current_stamp == previous_stamp or info.st_mtime_ns < launched_ns:
            raise ShutdownError('checkpoint_not_fresh')
        content = bytearray()
        while len(content) <= CHECKPOINT_LIMIT:
            block = os.read(descriptor, CHECKPOINT_LIMIT + 1 - len(content))
            if not block:
                break
            content.extend(block)
        if len(content) != info.st_size or _stamp(os.fstat(descriptor)) != current_stamp:
            raise ShutdownError('checkpoint_changed_during_read')
    finally:
        os.close(descriptor)
    try:
        data = json.loads(content, object_pairs_hook=_unique_object)
    except (ValueError, UnicodeError):
        raise ShutdownError('checkpoint_invalid_json') from None
    if type(data) is not dict:
        raise ShutdownError('checkpoint_invalid_json')
    if data.get('sessionstore-final-state-write-complete') is not True:
        raise ShutdownError('checkpoint_incomplete')


def check_firefox_exit(code):
    if code != 0:
        raise ShutdownError('firefox_exit_not_clean')


class _ClientData(ctypes.Union):
    _fields_ = [('bytes', ctypes.c_char * 20), ('shorts', ctypes.c_short * 10),
                ('longs', ctypes.c_long * 5)]


class _ClientMessage(ctypes.Structure):
    _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong),
                ('send_event', ctypes.c_int), ('display', ctypes.c_void_p),
                ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                ('format', ctypes.c_int), ('data', _ClientData)]


class _Event(ctypes.Union):
    _fields_ = [('client', _ClientMessage), ('padding', ctypes.c_long * 24)]


def request_firefox_close(pid):
    """Ask Openbox to close only this Firefox's windows using WM_DELETE_WINDOW."""
    x11 = ctypes.CDLL('libX11.so.6')
    display_type, window_type = ctypes.c_void_p, ctypes.c_ulong
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = display_type
    x11.XDefaultRootWindow.argtypes = [display_type]
    x11.XDefaultRootWindow.restype = window_type
    x11.XInternAtom.argtypes = [display_type, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = window_type
    x11.XGetWindowProperty.argtypes = [display_type, window_type, window_type,
        ctypes.c_long, ctypes.c_long, ctypes.c_int, window_type,
        ctypes.POINTER(window_type), ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte))]
    x11.XGetWindowProperty.restype = ctypes.c_int
    x11.XFree.argtypes = [ctypes.c_void_p]
    x11.XSendEvent.argtypes = [display_type, window_type, ctypes.c_int, ctypes.c_long,
                              ctypes.POINTER(_Event)]
    x11.XSendEvent.restype = ctypes.c_int
    x11.XSync.argtypes = [display_type, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [display_type]
    handler_type = ctypes.CFUNCTYPE(ctypes.c_int, display_type, ctypes.c_void_p)
    x11.XSetErrorHandler.argtypes = [handler_type]
    x11.XSetErrorHandler.restype = ctypes.c_void_p
    errors = []
    @handler_type
    def handle_error(_display, _error):
        errors.append(True)
        return 0
    old_handler = x11.XSetErrorHandler(handle_error)
    display = x11.XOpenDisplay(None)
    if not display:
        x11.XSetErrorHandler(ctypes.cast(old_handler, handler_type))
        raise ShutdownError('firefox_close_display_unavailable')
    try:
        root = x11.XDefaultRootWindow(display)
        def property_values(window, name, expected_type, maximum):
            atom = x11.XInternAtom(display, name, True)
            actual, format_ = window_type(), ctypes.c_int()
            count, remaining = ctypes.c_ulong(), ctypes.c_ulong()
            content = ctypes.POINTER(ctypes.c_ubyte)()
            status = x11.XGetWindowProperty(display, window, atom, 0, maximum, False,
                expected_type, ctypes.byref(actual), ctypes.byref(format_),
                ctypes.byref(count), ctypes.byref(remaining), ctypes.byref(content))
            try:
                x11.XSync(display, False)
                if (errors or status != 0 or actual.value != expected_type
                        or format_.value != 32 or count.value > maximum or remaining.value):
                    raise ShutdownError('firefox_close_property_invalid')
                values = ctypes.cast(content, ctypes.POINTER(ctypes.c_ulong))
                return [values[index] for index in range(count.value)]
            finally:
                if content:
                    x11.XFree(content)
        windows = property_values(root, b'_NET_CLIENT_LIST', 33, 64)  # XA_WINDOW
        owned = [window for window in windows
                 if property_values(window, b'_NET_WM_PID', 6, 1) == [pid]]  # XA_CARDINAL
        if not owned:
            raise ShutdownError('firefox_close_window_missing')
        atom = x11.XInternAtom(display, b'_NET_CLOSE_WINDOW', False)
        for window in owned:
            event = _Event()
            event.client.type = 33  # ClientMessage
            event.client.display = display
            event.client.window = window
            event.client.message_type = atom
            event.client.format = 32
            event.client.data.longs[0] = 0  # CurrentTime
            event.client.data.longs[1] = 2  # External window-management request
            if not x11.XSendEvent(display, root, False, (1 << 20) | (1 << 19), ctypes.byref(event)):
                raise ShutdownError('firefox_close_request_failed')
        x11.XSync(display, False)
        if errors:
            raise ShutdownError('firefox_close_request_failed')
    finally:
        x11.XCloseDisplay(display)
        x11.XSetErrorHandler(ctypes.cast(old_handler, handler_type))


def validate_window_manager_config():
    try:
        root = ET.fromstring(Path('/opt/browser/openbox.xml').read_bytes())
    except (OSError, ET.ParseError):
        raise ShutdownError('openbox_config_invalid') from None
    if root.tag != '{http://openbox.org/3.4/rc}openbox_config':
        raise ShutdownError('openbox_config_invalid')


def stop_background_component(process, name):
    try:
        if process.poll() is None:
            process.terminate()
        if process.wait(timeout=5) not in (0, -signal.SIGTERM):
            raise ShutdownError(name + '_shutdown_failed')
    except subprocess.TimeoutExpired:
        raise ShutdownError(name + '_shutdown_timeout') from None


def main():
    os.umask(0o077)
    RESULT.unlink(missing_ok=True)
    DIAGNOSTIC.unlink(missing_ok=True)
    profile = Path.home() / '.mozilla/browser'
    profile.mkdir(parents=True, exist_ok=True)
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, request_stop)
    paste = None
    resize = None
    diagnostic = {'schema': 'browser-shutdown-check/v1', 'firefox_exit_code': None,
                  'checkpoint_complete': False}
    try:
        validate_window_manager_config()
        window_manager = subprocess.Popen(['/usr/bin/openbox', '--config-file', '/opt/browser/openbox.xml'])
        previous_stamp = checkpoint_stamp(profile / 'sessionCheckpoints.json')
        launched_ns = time.time_ns()
        firefox = subprocess.Popen(['/opt/firefox/firefox', '--no-remote', '--profile', str(profile),
                                    'file:///opt/browser/privacy-check.html'])
        resize = subprocess.Popen(['/usr/bin/python3', '/opt/browser/resize.py'])
        paste = subprocess.Popen(['/usr/bin/python3', '/opt/browser/paste.py',
                                  '--firefox-pid', str(firefox.pid)])
        component_error = None
        while firefox.poll() is None and not stopping:
            if component_error is None and resize.poll() is not None:
                component_error = ShutdownError('display_adaptation_failed')
                print('BROWSER_DISPLAY_ADAPTER_UNEXPECTED_EXIT', file=sys.stderr, flush=True)
            time.sleep(0.1)
        for process, name in ((resize, 'resize'), (paste, 'paste')):
            try:
                stop_background_component(process, name)
            except ShutdownError as error:
                if component_error is None:
                    component_error = error
        if firefox.poll() is None:
            request_firefox_close(firefox.pid)
        try:
            firefox_code = firefox.wait(timeout=20)
        except subprocess.TimeoutExpired:
            raise ShutdownError('firefox_shutdown_timeout') from None
        diagnostic['firefox_exit_code'] = firefox_code
        print('BROWSER_FIREFOX_EXIT=' + str(firefox_code), flush=True)
        check_firefox_exit(firefox_code)
        validate_shutdown_checkpoint(profile, previous_stamp, launched_ns)
        diagnostic['checkpoint_complete'] = True
        print('BROWSER_CHECKPOINT_COMPLETE=1', flush=True)
        if window_manager.poll() is None:
            window_manager.terminate()
        manager_code = window_manager.wait(timeout=5)
        print('BROWSER_OPENBOX_EXIT=' + str(manager_code), flush=True)
        if manager_code not in (0, -signal.SIGTERM):
            raise ShutdownError('openbox_shutdown_failed')
        if component_error:
            raise component_error
        DIAGNOSTIC.write_text(json.dumps(diagnostic) + '\n')
        RESULT.write_text('success\n')
    except Exception as error:
        DIAGNOSTIC.write_text(json.dumps(diagnostic) + '\n')
        RESULT.write_text('failed\n')
        code = str(error) if type(error) is ShutdownError else type(error).__name__
        print('BROWSER_SESSION_STOP_FAILED:' + code, file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
