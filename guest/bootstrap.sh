#!/bin/sh
# Run ONLY in the disposable Linux VM, from this fixed root-owned installation.
# No package installation, security-setting downgrade, host mount or network.
set -eu
if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' '{"schema":"claude-code-guest-poc/v1","status":"unavailable","reason":"Linux guest required; no probes executed"}'
  exit 2
fi
if [ "$(id -u)" != 0 ] || [ "$(readlink -f "$0")" != /opt/claude-code-poc/guest/bootstrap.sh ]; then
  printf '%s\n' '{"status":"blocked","reason":"root and fixed installed bootstrap entry required"}'
  exit 2
fi
if [ "$#" -gt 1 ]; then
  printf '%s\n' '{"status":"blocked","reason":"only one fixed test mode allowed"}'
  exit 2
fi
poc_test_mode=${1:-all}
case "$poc_test_mode" in
  all|stop-scope) ;;
  *) printf '%s\n' '{"status":"blocked","reason":"test mode must be all or stop-scope"}'; exit 2 ;;
esac
if [ ! -x /usr/sbin/apparmor_parser ] || [ ! -x /usr/bin/aa-exec ] || [ ! -f /etc/apparmor.d/abi/4.0 ]; then
  printf '%s\n' '{"status":"blocked","reason":"AppArmor parser, aa-exec or pinned ABI 4.0 missing; no fallback"}'
  exit 2
fi
/usr/bin/python3 -I -S - <<'PY'
import json, os, pathlib, platform, subprocess, sys
sys.path.insert(0, '/opt/claude-code-poc/guest')
from common import INSTALL, digest, owned, read
from harness import FILES, vm_marker
if os.geteuid() != 0:
    raise RuntimeError('root required')
vm_marker()
for name in FILES:
    owned(INSTALL / name)
# cloud-init can deliver all .py files as root-only 0700. Only these fixed,
# already trusted sources must be readable after the controller/work UID drop.
for name in ('common.py', 'controller.py', 'work_probe.py'):
    (INSTALL / name).chmod(0o644)
    owned(INSTALL / name, mode=0o644)
if pathlib.Path('/proc/sys/kernel/yama/ptrace_scope').read_text().strip() != '2':
    raise RuntimeError('ptrace_scope=2 required; bootstrap does not change security settings')
manifest = {
    'files': {name: digest(INSTALL / name) for name in FILES},
    'kernel_release': platform.release(),
    'kernel_version': read('/proc/version'),
    'lsm': read('/sys/kernel/security/lsm'),
    'apparmor_parser': subprocess.check_output(['/usr/sbin/apparmor_parser', '--version'], text=True, stderr=subprocess.STDOUT).strip(),
    'apparmor_abi': digest('/etc/apparmor.d/abi/4.0'),
    'scope': 'toy_fixture_only', 'native_sdk_cli': 'not_executed'
}
pin = INSTALL / 'installed-manifest.json'
if pin.exists():
    owned(pin)
    if json.loads(pin.read_text()) != manifest:
        raise RuntimeError('installed manifest mismatch; preserve evidence, do not silently re-pin')
else:
    fd = os.open(pin, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    with os.fdopen(fd, 'w') as output:
        output.write(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
# Candidate parser/ABI mismatch is blocked. Only these three PoC profiles loaded.
/usr/sbin/apparmor_parser --skip-kernel-load --skip-read-cache /opt/claude-code-poc/guest/apparmor.profile
/usr/sbin/apparmor_parser --replace --skip-read-cache /opt/claude-code-poc/guest/apparmor.profile
exec /usr/bin/aa-exec -p claude-poc-manager -- /usr/bin/python3 -I -S /opt/claude-code-poc/guest/harness.py "$poc_test_mode"
