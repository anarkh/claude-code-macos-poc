#!/bin/bash
set -euo pipefail
# Fixed guest paths only; no values from host environment or provider credentials.
test "$(id -u)" = 0
test -f /opt/claude-text/sdk/runtime.mjs
test -x /usr/bin/node
test -f /opt/claude-text/supervisor.py
test "$(hostname)" = claude-text-guest
install -d -o 59999 -g 59999 -m 0700 /home/claude /home/claude/tmp /home/claude/work /home/claude/.claude
if test -e /etc/claude-text/project-enabled; then
  test ! -L /etc/claude-text/project-enabled
  test "$(cat /etc/claude-text/project-enabled)" = project-v1
  install -d -o 59999 -g 59999 -m 0700 /home/claude/project
  # VZ performs host I/O as its host user. Never chown/chmod the mounted data.
  # nosuid/nodev retain unprivileged guest execution while allowing project tools.
  modprobe virtiofs
  mount -t virtiofs -o rw,nosuid,nodev claude-project /home/claude/project
fi
sysctl -w kernel.yama.ptrace_scope=2 >/dev/null
exec /usr/bin/python3 /opt/claude-text/supervisor.py
