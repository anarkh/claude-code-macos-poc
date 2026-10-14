#!/usr/bin/python3
"""Apply the virtual display's preferred mode on RandR events, without polling."""
import ctypes as C
import os
import select
import signal
import subprocess
import sys
import time

OUTPUT = b'Virtual-1'
DEBOUNCE_SECONDS = 0.1
COMMAND = ['/usr/bin/xrandr', '--output', 'Virtual-1', '--auto']


class ResizeError(RuntimeError):
    pass


class Resources(C.Structure):
    _fields_ = [('timestamp', C.c_ulong), ('configTimestamp', C.c_ulong),
                ('ncrtc', C.c_int), ('crtcs', C.POINTER(C.c_ulong)),
                ('noutput', C.c_int), ('outputs', C.POINTER(C.c_ulong)),
                ('nmode', C.c_int), ('modes', C.c_void_p)]


class OutputInfo(C.Structure):
    _fields_ = [('timestamp', C.c_ulong), ('crtc', C.c_ulong),
                ('name', C.c_void_p), ('nameLen', C.c_int),
                ('mm_width', C.c_ulong), ('mm_height', C.c_ulong),
                ('connection', C.c_ushort), ('subpixel_order', C.c_ushort),
                ('ncrtc', C.c_int), ('crtcs', C.POINTER(C.c_ulong)),
                ('nclone', C.c_int), ('clones', C.POINTER(C.c_ulong)),
                ('nmode', C.c_int), ('npreferred', C.c_int), ('modes', C.POINTER(C.c_ulong))]


class CrtcInfo(C.Structure):
    _fields_ = [('timestamp', C.c_ulong), ('x', C.c_int), ('y', C.c_int),
                ('width', C.c_uint), ('height', C.c_uint), ('mode', C.c_ulong),
                ('rotation', C.c_ushort), ('noutput', C.c_int), ('outputs', C.POINTER(C.c_ulong)),
                ('rotations', C.c_ushort), ('npossible', C.c_int), ('possible', C.POINTER(C.c_ulong))]


class Event(C.Union):
    _fields_ = [('type', C.c_int), ('pad', C.c_long * 24)]


class DisplayDriver:
    def __init__(self):
        if [C.sizeof(kind) for kind in (Resources, OutputInfo, CrtcInfo)] != [64, 96, 64]:
            raise ResizeError('randr_abi_unsupported')
        self.x = C.CDLL('libX11.so.6')
        self.r = C.CDLL('libXrandr.so.2')
        pointer, window = C.c_void_p, C.c_ulong
        self.handler_type = C.CFUNCTYPE(C.c_int, pointer, pointer)
        for name, arguments, result in (
                ('XOpenDisplay', [C.c_char_p], pointer), ('XCloseDisplay', [pointer], C.c_int),
                ('XDefaultRootWindow', [pointer], window), ('XConnectionNumber', [pointer], C.c_int),
                ('XPending', [pointer], C.c_int), ('XNextEvent', [pointer, C.POINTER(Event)], C.c_int),
                ('XSync', [pointer, C.c_int], C.c_int), ('XSetErrorHandler', [pointer], pointer)):
            function = getattr(self.x, name)
            function.argtypes, function.restype = arguments, result
        for name, arguments, result in (
                ('XRRQueryExtension', [pointer, C.POINTER(C.c_int), C.POINTER(C.c_int)], C.c_int),
                ('XRRQueryVersion', [pointer, C.POINTER(C.c_int), C.POINTER(C.c_int)], C.c_int),
                ('XRRSelectInput', [pointer, window, C.c_int], None),
                ('XRRGetScreenResourcesCurrent', [pointer, window], C.POINTER(Resources)),
                ('XRRGetOutputInfo', [pointer, C.POINTER(Resources), window], C.POINTER(OutputInfo)),
                ('XRRGetCrtcInfo', [pointer, C.POINTER(Resources), window], C.POINTER(CrtcInfo)),
                ('XRRFreeScreenResources', [C.POINTER(Resources)], None),
                ('XRRFreeOutputInfo', [C.POINTER(OutputInfo)], None),
                ('XRRFreeCrtcInfo', [C.POINTER(CrtcInfo)], None)):
            function = getattr(self.r, name)
            function.argtypes, function.restype = arguments, result
        self.display = self.x.XOpenDisplay(None)
        if not self.display:
            raise ResizeError('display_unavailable')
        self.errors = False
        self.handler = self.handler_type(self.on_error)
        self.previous_handler = self.x.XSetErrorHandler(C.cast(self.handler, pointer))
        self.root = self.x.XDefaultRootWindow(self.display)
        self.event_fd = self.x.XConnectionNumber(self.display)

    def on_error(self, _display, _event):
        self.errors = True
        return 0

    def check_errors(self):
        if self.errors:
            raise ResizeError('randr_request_failed')

    def subscribe(self):
        event_base, error_base, major, minor = C.c_int(), C.c_int(), C.c_int(), C.c_int()
        if not self.r.XRRQueryExtension(self.display, C.byref(event_base), C.byref(error_base)):
            raise ResizeError('randr_extension_missing')
        if not self.r.XRRQueryVersion(self.display, C.byref(major), C.byref(minor)) or (major.value, minor.value) < (1, 4):
            raise ResizeError('randr_version_unsupported')
        self.event_base = event_base.value
        # Screen/crtc/output/property changes and RandR 1.4 resource changes.
        self.r.XRRSelectInput(self.display, self.root, 1 | 2 | 4 | 8 | 64)
        self.x.XSync(self.display, False)
        self.check_errors()

    def drain_events(self):
        changed = False
        while self.x.XPending(self.display):
            event = Event()
            self.x.XNextEvent(self.display, C.byref(event))
            changed = changed or event.type in (self.event_base, self.event_base + 1)
        self.check_errors()
        return changed

    def query_modes(self):
        resources = self.r.XRRGetScreenResourcesCurrent(self.display, self.root)
        if not resources:
            raise ResizeError('randr_resources_unavailable')
        try:
            if not 0 <= resources.contents.noutput <= 64 or not resources.contents.outputs:
                raise ResizeError('randr_outputs_invalid')
            for index in range(resources.contents.noutput):
                output = self.r.XRRGetOutputInfo(self.display, resources, resources.contents.outputs[index])
                if not output:
                    raise ResizeError('randr_output_unavailable')
                try:
                    info = output.contents
                    if info.nameLen != len(OUTPUT) or not info.name or C.string_at(info.name, info.nameLen) != OUTPUT:
                        continue
                    if info.connection != 0:
                        raise ResizeError('virtual_output_disconnected')
                    if not info.modes or not 0 < info.npreferred <= info.nmode:
                        raise ResizeError('preferred_mode_missing')
                    preferred = int(info.modes[0])
                    current = 0
                    if info.crtc:
                        crtc = self.r.XRRGetCrtcInfo(self.display, resources, info.crtc)
                        if not crtc:
                            raise ResizeError('randr_crtc_unavailable')
                        try:
                            current = int(crtc.contents.mode)
                        finally:
                            self.r.XRRFreeCrtcInfo(crtc)
                    self.check_errors()
                    return current, preferred
                finally:
                    self.r.XRRFreeOutputInfo(output)
            raise ResizeError('virtual_output_missing')
        finally:
            self.r.XRRFreeScreenResources(resources)

    def apply_mode(self):
        process = subprocess.Popen(COMMAND, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            result = process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                raise ResizeError('xrandr_stop_timeout') from None
            raise ResizeError('xrandr_apply_timeout') from None
        if result != 0:
            raise ResizeError('xrandr_apply_failed')

    def close(self):
        self.x.XCloseDisplay(self.display)
        self.x.XSetErrorHandler(self.previous_handler)


def apply_preferred(backend):
    before = backend.query_modes()
    current, preferred = before
    if not preferred:
        raise ResizeError('preferred_mode_missing')
    if current == preferred:
        return False
    backend.apply_mode()
    after = backend.query_modes()
    if not after[1]:
        raise ResizeError('preferred_mode_missing')
    if after[0] != after[1] and after[1] == preferred:
        raise ResizeError('preferred_mode_not_applied')
    # A new host preference can arrive during xrandr; its queued RandR event
    # schedules another bounded pass rather than a retry or a polling loop.
    return True


class ResizeLoop:
    def __init__(self, backend, stopped, wait=None, clock=None):
        self.backend, self.stopped = backend, stopped
        self.wait, self.clock = wait or select.select, clock or time.monotonic

    def run(self, wake_fd):
        self.backend.subscribe()
        if self.stopped():
            return
        apply_preferred(self.backend)
        print('BROWSER_DISPLAY_ADAPTER_READY', flush=True)
        deadline = None
        while not self.stopped():
            if self.backend.drain_events() and deadline is None:
                deadline = self.clock() + DEBOUNCE_SECONDS
            now = self.clock()
            if deadline is not None and now >= deadline:
                apply_preferred(self.backend)
                deadline = None
                continue
            timeout = None if deadline is None else max(0, deadline - now)
            try:
                readable, _, _ = self.wait([self.backend.event_fd, wake_fd], [], [], timeout)
            except InterruptedError:
                continue
            if self.stopped():
                return
            if wake_fd in readable:
                os.read(wake_fd, 4096)


def main():
    wake_read, wake_write = os.pipe()
    os.set_blocking(wake_read, False)
    os.set_blocking(wake_write, False)
    stopped = False
    def stop(_number, _frame):
        nonlocal stopped
        stopped = True
    previous = signal.set_wakeup_fd(wake_write)
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, stop)
    driver = None
    try:
        driver = DisplayDriver()
        ResizeLoop(driver, lambda: stopped).run(wake_read)
        return 0
    finally:
        if driver:
            driver.close()
        signal.set_wakeup_fd(previous)
        os.close(wake_read)
        os.close(wake_write)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        code = str(error) if type(error) is ResizeError else type(error).__name__
        print('BROWSER_DISPLAY_ADAPTER_FAILED:' + code, file=sys.stderr)
        raise SystemExit(1)
