#!/bin/sh
# Fixed, disposable no-NIC guest entry. Never run this on the host.
set -eu
case "${1:-}" in isolation|contract|relay) mode=$1 ;; *) echo '{"status":"blocked","reason":"fixed isolation, contract or relay mode required"}'; exit 2 ;; esac
if [ "$#" != 1 ] || [ "$(uname -s)" != Linux ] || [ "$(id -u)" != 0 ] || [ "$(readlink -f "$0")" != /opt/claude-code-poc/native/bootstrap.sh ]; then
  echo '{"status":"blocked","reason":"fixed root Linux guest entry required"}'; exit 2
fi
if [ "$mode" = relay ]; then
  # These fixed rules affect only this disposable guest's dedicated work UID.
  /usr/sbin/iptables -w -N CLAUDE_POC_EGRESS
  /usr/sbin/iptables -w -A OUTPUT -m owner --uid-owner 29998 -j CLAUDE_POC_EGRESS
  /usr/sbin/iptables -w -A CLAUDE_POC_EGRESS -p tcp -d 127.0.0.1/32 --dport 41417 -j ACCEPT
  /usr/sbin/iptables -w -A CLAUDE_POC_EGRESS -j REJECT
  /usr/sbin/ip6tables -w -A OUTPUT -m owner --uid-owner 29998 -j REJECT
  /usr/bin/python3 -I -S - <<'PY'
import json,os,subprocess
result={'schema':'fixed-guest-egress/v1','uid':29998,'allowed_destination':'127.0.0.1:41417','ipv4':subprocess.check_output(['/usr/sbin/iptables','-S']).decode().splitlines(),'ipv6':subprocess.check_output(['/usr/sbin/ip6tables','-S','OUTPUT']).decode().splitlines()}
fd=os.open('/etc/claude-code-poc/egress-rules.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as output:json.dump(result,output)
PY
fi
/usr/bin/python3 -I -S /opt/claude-code-poc/native/manager.py prepare
/usr/sbin/apparmor_parser --skip-kernel-load --skip-read-cache /opt/claude-code-poc/native/apparmor.profile
/usr/sbin/apparmor_parser --replace --skip-read-cache /opt/claude-code-poc/native/apparmor.profile
# Keep root's fixed bootstrap as the serial logger. A profile-transition failure
# must not silently discard the original inherited console descriptors.
mkdir -p /var/lib/claude-code-native-poc
phase=manager-start
trap 'result=$?; printf "phase=%s exit=%s\n" "$phase" "$result" > /var/lib/claude-code-native-poc/bootstrap-state.log' EXIT
printf 'POC_NATIVE_BOOTSTRAP manager-start pid=%s\n' "$$" > /dev/hvc0
if /usr/bin/aa-exec -p claude-native-manager -- /usr/bin/python3 -I -S /opt/claude-code-poc/native/manager.py "$mode" > /var/lib/claude-code-native-poc/manager-output.log 2>&1; then
  code=0
else
  code=$?
fi
phase=manager-finished
printf 'POC_NATIVE_BOOTSTRAP manager-finished exit=%s\n' "$code" > /dev/hvc0
summary=/var/lib/claude-code-native-poc/native-admission-summary.json
if [ -f "$summary" ]; then
  phase=summary-relay
  echo POC_NATIVE_BEGIN > /dev/hvc0
  cat "$summary" > /dev/hvc0
  echo POC_NATIVE_END > /dev/hvc0
else
  echo POC_NATIVE_BEGIN > /dev/hvc0
  printf '{"schema":"claude-native-admission/v1","status":"blocked","error":"manager exited without persisted summary","manager_exit":%s}\n' "$code" > /dev/hvc0
  echo POC_NATIVE_END > /dev/hvc0
  echo POC_NATIVE_MANAGER_LOG_BEGIN > /dev/hvc0
  tail -n 50 /var/lib/claude-code-native-poc/manager-output.log > /dev/hvc0
  echo POC_NATIVE_MANAGER_LOG_END > /dev/hvc0
fi
if [ "$code" != 0 ] && [ -f /var/lib/claude-code-native-poc/current/controller/runner.log ]; then
  echo POC_NATIVE_RUNNER_LOG_BEGIN > /dev/hvc0
  tail -n 50 /var/lib/claude-code-native-poc/current/controller/runner.log > /dev/hvc0
  echo POC_NATIVE_RUNNER_LOG_END > /dev/hvc0
fi
if [ "$mode" = relay ]; then
  phase=egress-counter-readback
  /usr/bin/python3 -I -S - <<'PY'
import json,os,subprocess
lines=subprocess.check_output(['/usr/sbin/iptables','-w','-L','CLAUDE_POC_EGRESS','-n','-v','-x']).decode().splitlines()
rows=[]
for line in lines:
    parts=line.split()
    if len(parts)>3 and parts[0].isdigit():rows.append({'packets':int(parts[0]),'bytes':int(parts[1]),'target':parts[2]})
value={'schema':'fixed-egress-counter-evidence/v1','uid':29998,'chain':'CLAUDE_POC_EGRESS','rules':rows,'allowed_destination':'127.0.0.1:41417'}
fd=os.open('/var/lib/claude-code-native-poc/egress-evidence.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as output:json.dump(value,output)
PY
fi
phase=complete
exit "$code"
