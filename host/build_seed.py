#!/usr/bin/env python3
"""Make a fake-data-only cloud-init seed for this isolated, no-NIC VM."""
import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import shutil
import tarfile
import uuid

HOST = Path(__file__).resolve().parent
GUEST = HOST.parent / "guest"
DIAGNOSTIC = r'''
import json,os,platform,shutil,time
from pathlib import Path
def read(p):
    try: return Path(p).read_text().strip()
    except OSError as e: return {"unavailable": type(e).__name__}
e = {"kind":"guest_boot_diagnostic","architecture":platform.machine(),"kernel":platform.release(),
     "uid":os.getuid(),"network_interfaces":sorted(p.name for p in Path('/sys/class/net').iterdir()),
     "cgroup_fs":read('/proc/filesystems'),"cgroup_controllers":read('/sys/fs/cgroup/cgroup.controllers'),
     "lsm":read('/sys/kernel/security/lsm'),"apparmor_enabled":read('/sys/module/apparmor/parameters/enabled'),
     "ptrace_scope":read('/proc/sys/kernel/yama/ptrace_scope'),
     "timezone":read('/etc/timezone'), "guest_utc_epoch":time.time(),
     "tools":{x:shutil.which(x) for x in ['python3','apparmor_parser','aa-exec','gcc','cc']}}
print('POC_DIAGNOSTIC_BEGIN')
print(json.dumps(e,sort_keys=True))
print('POC_DIAGNOSTIC_END')
'''
AUDIT = r'''
import subprocess
result = subprocess.run(['/usr/bin/dmesg'], capture_output=True, text=True)
print('POC_KERNEL_AUDIT_BEGIN')
if result.returncode:
    print('dmesg unavailable, exit=' + str(result.returncode))
else:
    for line in [s for s in result.stdout.splitlines() if 'apparmor' in s.lower()][-80:]:
        print(line)
print('POC_KERNEL_AUDIT_END')
'''
NATIVE_POST = r'''
import json
from pathlib import Path
base = Path('/var/lib/claude-code-native-poc')
value = {'schema':'native-postflight/v1','files':{}}
for name in ['native-admission-summary.json','relay-evidence.json','egress-evidence.json','bootstrap-state.log','relay.log','manager-output.log','current/controller/runner.log']:
    path = base / name
    if not path.is_file():
        value['files'][name] = {'exists':False}
        continue
    content = path.read_text(errors='replace')
    value['files'][name] = {'exists':True,'size':path.stat().st_size}
    if name.endswith(('summary.json','evidence.json')):
        value['files'][name]['evidence'] = json.loads(content)
    else:
        value['files'][name]['tail'] = content[-4000:]
print('POC_NATIVE_POST_BEGIN')
print(json.dumps(value,sort_keys=True))
print('POC_NATIVE_POST_END')
'''

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--mode',choices=['diagnostic','guest','combined','native'],default='diagnostic')
    parser.add_argument('--guest-test',choices=['all','stop-scope'],default='all')
    parser.add_argument('--native-test',choices=['isolation','contract','relay'],default='isolation')
    parser.add_argument('--relay-fixture',type=Path)
    args=parser.parse_args()
    if (args.native_test=='relay') != (args.relay_fixture is not None) or (args.relay_fixture and args.mode!='native'):
        raise RuntimeError('relay mode requires exactly one fake relay fixture directory')
    running=subprocess.run(['/usr/bin/pgrep','-x','vm-poc'],stdout=subprocess.DEVNULL)
    if running.returncode==0:raise RuntimeError('stop vm-poc before replacing its seed')
    if running.returncode!=1:raise RuntimeError('cannot verify that vm-poc is stopped')
    seed=HOST/'seed';seed.mkdir(exist_ok=True)
    # Only generated fixture payloads; keep simple ISO 9660 names (one dot).
    for name in ('sdk.tar.gz', 'sdk.tgz', 'node', 'atomic.deb'):
        path=seed/name
        if path.exists():path.unlink()
    iso=HOST/('seed-'+args.mode+'.iso')
    if iso.exists():iso.unlink()
    manifest={"isolated_test_vm":True,"fake_data_only":True,"no_host_mounts":True,"vm_id":"vm-poc-001"}
    files=[{"path":"/etc/claude-code-poc/isolated-test-vm.json","owner":"root:root","permissions":"0600","content":json.dumps(manifest)},
           {"path":"/opt/claude-code-poc/diagnostic.py","owner":"root:root","permissions":"0700","content":DIAGNOSTIC},
           {"path":"/opt/claude-code-poc/audit.py","owner":"root:root","permissions":"0700","content":AUDIT}]
    if args.relay_fixture:
        private=args.relay_fixture.resolve()
        if private.parent != Path('/private/tmp') or not private.name.startswith('ccr-') or private.stat().st_uid != os.getuid() or private.stat().st_mode & 0o077:
            raise RuntimeError('fixed private relay fixture directory required')
        config=json.loads((private/'guest-relay.json').read_text())
        if config.get('schema')!='guest-relay-fixture/v1' or config.get('vsock_cid')!=2 or config.get('vsock_port')!=40123:
            raise RuntimeError('fixed guest relay config required')
        files.append({'path':'/etc/claude-code-poc/relay.json','owner':'root:root','permissions':'0600','content':json.dumps(config)})
        for name in ('ca.pem','client.pem','client.key'):
            files.append({'path':'/etc/claude-code-poc/relay/'+name,'owner':'root:root','permissions':'0600','encoding':'b64','content':base64.b64encode((private/name).read_bytes()).decode()})
        relay=GUEST/'relay'/'relay.py'
        if not relay.is_file():raise RuntimeError('guest relay implementation is not ready')
        files.append({'path':'/opt/claude-code-poc/relay/relay.py','owner':'root:root','permissions':'0755','encoding':'b64','content':base64.b64encode(relay.read_bytes()).decode()})
        seed.chmod(0o700)
    if args.mode in {'guest','combined'}:
        bootstrap=GUEST/'bootstrap.sh'
        if not bootstrap.is_file():raise RuntimeError('guest bootstrap is not ready')
        for p in sorted(GUEST.iterdir()):
            if p.is_file() and p.suffix in {'.py','.sh','.profile','.c','.json'}:
                files.append({"path":"/opt/claude-code-poc/guest/"+p.name,"owner":"root:root","permissions":"0700" if p.suffix in {'.sh','.py'} else "0600","encoding":"b64","content":base64.b64encode(p.read_bytes()).decode()})
    if args.mode=='native':
        files.append({"path":"/opt/claude-code-poc/native-postflight.py","owner":"root:root","permissions":"0700","content":NATIVE_POST})
        native=GUEST/'native'
        if not (native/'bootstrap.sh').is_file():raise RuntimeError('native bootstrap is not ready')
        for p in sorted(native.iterdir()):
            if p.is_file() and p.suffix in {'.py','.sh','.profile','.json'}:
                files.append({"path":"/opt/claude-code-poc/native/"+p.name,"owner":"root:root","permissions":"0755" if p.suffix in {'.sh','.py'} else "0644","encoding":"b64","content":base64.b64encode(p.read_bytes()).decode()})
    command='python3 /opt/claude-code-poc/diagnostic.py > /dev/hvc0 2>&1'
    commands=[['sh','-c',command]]
    if args.mode in {'guest','combined'}:
        commands.append(['sh','-c','sysctl -w kernel.yama.ptrace_scope=2 > /dev/hvc0 2>&1'])
        commands.append(['sh','-c',f'echo POC_GUEST_BEGIN > /dev/hvc0; bash /opt/claude-code-poc/guest/bootstrap.sh {args.guest_test} > /dev/hvc0 2>&1; code=$?; echo POC_GUEST_END > /dev/hvc0; echo POC_BOOTSTRAP_EXIT=$code > /dev/hvc0'])
        commands.append(['sh','-c','python3 /opt/claude-code-poc/audit.py > /dev/hvc0 2>&1'])
    if args.mode=='native':
        commands.append(['sh','-c','sysctl -w kernel.yama.ptrace_scope=2 > /dev/hvc0 2>&1'])
    if args.mode in {'combined','native'}:
        sdk=HOST.parent/'sdk'
        platform=sdk/'node_modules/@anthropic-ai/claude-agent-sdk-linux-arm64'
        if not (platform/'claude').is_file():raise RuntimeError('official Linux CLI package is not ready')
        node=HOST/'images/node-linux-arm64'
        if not node.is_file():raise RuntimeError('verified Linux Node is not ready')
        shutil.copyfile(node,seed/'node')
        atomic=HOST/'images/atomic.deb'
        if not atomic.is_file():raise RuntimeError('verified official libatomic package is not ready')
        shutil.copyfile(atomic,seed/'atomic.deb')
        # Only public runtime/code files enter the payload, never Mac runs/HOME/config.
        entrypoints=['package.json','run-isolated.sh','run-poc.mjs'] if args.mode=='combined' else ['package.json','origin-contract.mjs','run-native-admission.mjs','run-native-isolated.sh']
        with tarfile.open(seed/'sdk.tgz','w:gz') as archive:
            for name in entrypoints+['node_modules/@anthropic-ai/claude-agent-sdk','node_modules/@anthropic-ai/claude-agent-sdk-linux-arm64']:
                archive.add(sdk/name,arcname=name)
        runtime='/var/lib/claude-code-poc-sdk' if args.mode=='combined' else '/opt/claude-code-poc/native-runtime/sdk'
        commands.append(['sh','-c',
            f'mkdir -p /mnt/claude-poc-seed {runtime}; '
            'mount -o ro /dev/vdb /mnt/claude-poc-seed && '
            'mkdir -p /opt/claude-code-poc/runtime && '
            'dpkg-deb -x /mnt/claude-poc-seed/atomic.deb /opt/claude-code-poc/runtime && '
            'install -m 0644 /opt/claude-code-poc/runtime/usr/lib/aarch64-linux-gnu/libatomic.so.1.2.0 /usr/lib/aarch64-linux-gnu/libatomic.so.1 && '
            'install -m 0755 /mnt/claude-poc-seed/node /opt/claude-code-poc/node && '
            f'tar -xzf /mnt/claude-poc-seed/sdk.tgz -C {runtime} && '+
            ('chown -R root:root /opt/claude-code-poc/native-runtime && ' if args.mode=='native' else '')+
            'umount /mnt/claude-poc-seed'])
    if args.mode=='combined':
        commands.append(['sh','-c',
            'chown -R ubuntu:ubuntu /var/lib/claude-code-poc-sdk && '
            'runuser -u ubuntu -- env POC_NODE_BIN=/opt/claude-code-poc/node sh /var/lib/claude-code-poc-sdk/run-isolated.sh > /var/lib/claude-code-poc-sdk/run.log 2>&1; '
            'code=$?; echo POC_LINUX_SDK_EXIT=$code > /dev/hvc0; '
            'echo POC_LINUX_SDK_SUMMARY_BEGIN > /dev/hvc0; '
            'if test -f /var/lib/claude-code-poc-sdk/evidence/native-session-summary.json; then '
            'cat /var/lib/claude-code-poc-sdk/evidence/native-session-summary.json > /dev/hvc0; '
            'else tail -n 30 /var/lib/claude-code-poc-sdk/run.log > /dev/hvc0; fi; '
            'echo POC_LINUX_SDK_SUMMARY_END > /dev/hvc0'])
    if args.mode=='native':
        commands.append(['sh','-c',f'bash /opt/claude-code-poc/native/bootstrap.sh {args.native_test} > /dev/hvc0 2>&1; code=$?; echo POC_NATIVE_EXIT=$code > /dev/hvc0'])
        commands.append(['sh','-c','python3 /opt/claude-code-poc/native-postflight.py > /dev/hvc0 2>&1'])
        commands.append(['sh','-c','python3 /opt/claude-code-poc/audit.py > /dev/hvc0 2>&1'])
    host_epoch=int(datetime.now(timezone.utc).timestamp())
    (seed/'clock.json').write_text(json.dumps({'host_utc_epoch_at_seed_creation':host_epoch,'boundary':'one-time offline fixture initialization, not NTP or resume clock validation'})+'\n')
    config={"bootcmd":[['sh','-c',f'date -u -s @{host_epoch} > /dev/hvc0 2>&1'],['sh','-c','resize2fs /dev/vda > /dev/hvc0 2>&1']],
            "timezone":"Asia/Tokyo",
            "write_files":files,"runcmd":commands,"power_state":{"mode":"poweroff","timeout":30,"condition":True}}
    (seed/'user-data').write_text('#cloud-config\n'+json.dumps(config,indent=2)+'\n')
    if args.relay_fixture:(seed/'user-data').chmod(0o600)
    (seed/'meta-data').write_text('instance-id: claude-poc-'+str(uuid.uuid4())+'\nlocal-hostname: claude-poc\n')
    subprocess.run(['/usr/bin/hdiutil','makehybrid','-iso','-joliet','-default-volume-name','cidata','-o',str(iso),str(seed)],check=True)
    if args.relay_fixture:iso.chmod(0o600)
    print(json.dumps({"kind":"seed_created","mode":args.mode,"files":len(files),"iso":iso.name}))

if __name__=='__main__':main()
