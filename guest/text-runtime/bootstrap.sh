#!/bin/bash
set -euo pipefail
# Fixed guest paths only; no values from host environment or provider credentials.
test "$(id -u)" = 0
test -f /opt/claude-text/sdk/runtime.mjs
test -x /usr/bin/node
test -f /opt/claude-text/supervisor.py
test "$(hostname)" = claude-text-guest
install -d -o 59999 -g 59999 -m 0700 /home/claude /home/claude/tmp /home/claude/work /home/claude/.claude
sysctl -w kernel.yama.ptrace_scope=2 >/dev/null
exec /usr/bin/python3 /opt/claude-text/supervisor.py
