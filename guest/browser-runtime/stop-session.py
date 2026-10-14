#!/usr/bin/python3
"""Request bounded ordered shutdown; never force-kill guest processes."""
import os
import json
from pathlib import Path
import signal
import stat
import sys
import time


def read_diagnostic():
    descriptor = os.open('/run/browser-session/stop-diagnostic', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 59998 or not 0 < info.st_size <= 256:
            raise RuntimeError('shutdown_diagnostic_invalid')
        content = os.read(descriptor, 257)
        after = os.fstat(descriptor)
        if (len(content) != info.st_size or info.st_mtime_ns != after.st_mtime_ns
                or info.st_ctime_ns != after.st_ctime_ns or info.st_size != after.st_size):
            raise RuntimeError('shutdown_diagnostic_changed')
    finally:
        os.close(descriptor)
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate_diagnostic_key')
            result[key] = value
        return result
    try:
        result = json.loads(content, object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        raise RuntimeError('shutdown_diagnostic_invalid_json') from None
    if (type(result) is not dict or set(result) != {'schema', 'firefox_exit_code', 'checkpoint_complete'}
            or result['schema'] != 'browser-shutdown-check/v1'
            or type(result['checkpoint_complete']) is not bool
            or (result['firefox_exit_code'] is not None
                and (type(result['firefox_exit_code']) is not int or not -255 <= result['firefox_exit_code'] <= 255))):
        raise RuntimeError('shutdown_diagnostic_invalid')
    return result


def main():
    group = Path('/proc/self/cgroup').read_text().strip()
    if not group.startswith('0::/') or '\n' in group:
        raise RuntimeError('session_cgroup_missing')
    group_path = Path('/sys/fs/cgroup' + group[3:])
    while group_path.name != 'browser-session.service':
        if group_path == Path('/sys/fs/cgroup'):
            raise RuntimeError('browser_session_unit_cgroup_missing')
        group_path = group_path.parent
    own_pid = os.getpid()
    if 'browser.verify=1' in Path('/proc/cmdline').read_text().split():
        with open('/dev/hvc0', 'w') as serial:
            serial.write('BROWSER_SESSION_RUNTIME_UID=' + str(Path('/run/browser-session').stat().st_uid) + '\n')
    def pids():
        result = set()
        for members in group_path.rglob('cgroup.procs'):
            try:
                result.update(int(value) for value in members.read_text().split())
            except FileNotFoundError:
                continue
        return result - {own_pid}
    found = 0
    for pid in pids():
        try:
            descriptor = os.pidfd_open(pid)
        except ProcessLookupError:
            continue
        try:
            process = Path('/proc') / str(pid)
            arguments = process.joinpath('cmdline').read_bytes().split(b'\0')
            if arguments[:2] != [b'/usr/bin/python3', b'/opt/browser/session.py']:
                continue
            if process.stat().st_uid != 59998:
                raise RuntimeError('session_uid_invalid')
            if 'browser.verify=1' in Path('/proc/cmdline').read_text().split():
                location = process.joinpath('cgroup').read_text().strip()
                relative = location[3:].removeprefix(str(group_path).removeprefix('/sys/fs/cgroup'))
                with open('/dev/hvc0', 'w') as serial:
                    serial.write('BROWSER_SESSION_SUPERVISOR_GROUP=' + ('unit-root' if not relative else 'unit-child') + '\n')
            signal.pidfd_send_signal(descriptor, signal.SIGTERM)
            found += 1
        except FileNotFoundError:
            continue
        finally:
            os.close(descriptor)
    with open('/dev/hvc0', 'w') as serial:
        serial.write('BROWSER_SESSION_STOP_TARGETS=' + str(found) + '\n')
    if found != 1:
        raise RuntimeError('browser_supervisor_count_invalid')
    deadline = time.monotonic() + 35
    while pids():
        if time.monotonic() >= deadline:
            raise RuntimeError('ordered_session_shutdown_timeout')
        time.sleep(0.1)
    diagnostic = read_diagnostic()
    with open('/dev/hvc0', 'w') as serial:
        code = diagnostic['firefox_exit_code']
        serial.write('BROWSER_FIREFOX_EXIT=' + ('unavailable' if code is None else str(code)) + '\n')
        serial.write('BROWSER_CHECKPOINT_COMPLETE=' + str(int(diagnostic['checkpoint_complete'])) + '\n')
    if diagnostic['firefox_exit_code'] != 0 or diagnostic['checkpoint_complete'] is not True:
        raise RuntimeError('firefox_shutdown_incomplete')
    descriptor = os.open('/run/browser-session/stop-result', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 59998 or info.st_size != 8 or os.read(descriptor, 9) != b'success\n':
            raise RuntimeError('ordered_session_shutdown_failed')
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    try:
        main()
        with open('/dev/hvc0', 'w') as serial:
            serial.write('BROWSER_SESSION_STOP_COMPLETE\n')
    except Exception as error:
        with open('/dev/hvc0', 'w') as serial:
            serial.write('BROWSER_SESSION_STOP_FAILED\n')
            code = str(error) if type(error) is RuntimeError else type(error).__name__
            serial.write('BROWSER_SESSION_STOP_ERROR=' + code + '\n')
        print('Ordered browser shutdown failed: ' + code, file=sys.stderr)
        raise SystemExit(1)
