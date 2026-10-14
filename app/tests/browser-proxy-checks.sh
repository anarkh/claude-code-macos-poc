#!/bin/bash
set -euo pipefail

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
app_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
sources="$app_root/Sources/ClaudeIsolationPoC"
for source in "$sources/BrowserProxyGateway.swift" "$sources/BrowserProxyGatewayChecks.swift" "$script_dir/browser-proxy-checks.swift"; do
  if [ ! -f "$source" ]; then
    printf 'FAIL missing_source: %s\n' "$source" >&2
    exit 2
  fi
done
if [ ! -x /usr/bin/python3 ] || [ ! -x /usr/bin/xcrun ]; then
  printf 'FAIL macos_python_or_xcrun_unavailable\n' >&2
  exit 2
fi

exec /usr/bin/python3 - "$sources/BrowserProxyGateway.swift" "$sources/BrowserProxyGatewayChecks.swift" "$script_dir/browser-proxy-checks.swift" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

timeout_seconds = 120
deadline = time.monotonic() + timeout_seconds
sources = sys.argv[1:]
active_process = None


def stop_process_group():
    if active_process is None:
        return
    try:
        os.killpg(active_process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    active_process.wait()


def interrupted(signum, _frame):
    stop_process_group()
    raise SystemExit(128 + signum)


signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)


def run(command, environment):
    global active_process
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise subprocess.TimeoutExpired(command, timeout_seconds)
    active_process = subprocess.Popen(command, start_new_session=True, env=environment)
    try:
        returncode = active_process.wait(timeout=remaining)
    except subprocess.TimeoutExpired:
        stop_process_group()
        raise
    finally:
        if active_process.poll() is not None:
            active_process = None
    return returncode if returncode >= 0 else 128 - returncode


try:
    with tempfile.TemporaryDirectory(prefix="claude-browser-proxy-checks.") as temporary_dir:
        binary = str(Path(temporary_dir) / "browser-proxy-checks")
        child_environment = dict(os.environ, TMPDIR=temporary_dir)
        try:
            compile_status = run([
                "/usr/bin/xcrun", "swiftc", "-parse-as-library",
                "-module-name", "BrowserProxyChecksHarness",
                "-module-cache-path", str(Path(temporary_dir) / "module-cache"),
                *sources, "-o", binary,
            ], child_environment)
            if compile_status:
                print("FAIL browser_proxy_checks_compile_failed", file=sys.stderr)
                raise SystemExit(compile_status)
            raise SystemExit(run([binary], child_environment))
        finally:
            stop_process_group()
except subprocess.TimeoutExpired:
    print(f"FAIL browser_proxy_checks_timeout: {timeout_seconds} seconds", file=sys.stderr)
    raise SystemExit(124)
except OSError as error:
    print(f"FAIL browser_proxy_checks_launch_failed: {error}", file=sys.stderr)
    raise SystemExit(2)
PY
