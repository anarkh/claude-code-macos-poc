#!/bin/bash
set -euo pipefail
app_root=$(cd "$(dirname "$0")" && pwd)
project_root=$(cd "$app_root/.." && pwd)
app_version=0.13.5
app_build=27
node_executable=${1:-}
browser_images=${3:-"$project_root/host/browser-runtime/images"}
if [ -z "$node_executable" ]; then
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -x "$candidate" ]; then node_executable=$candidate; break; fi
  done
fi
if [ -z "$node_executable" ] || [ "${node_executable:0:1}" != "/" ] || [ ! -x "$node_executable" ]; then
  echo 'Supply an absolute, executable Node path; no user-home scanning is performed.' >&2
  exit 2
fi
app_icon="$app_root/.build/AppIcon.icns"
bash "$app_root/tools/build_app_icon.sh" "$app_root/Resources/AppIcon.png" "$app_icon" >/dev/null
bash "$project_root/host/text-runtime/build.sh"
python3 - "$project_root" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / 'host/text-runtime'))
from common import validate_base
validate_base(root / 'host/text-runtime/images')
PY
"$node_executable" --test "$project_root/sdk/test-vm-text-chat.mjs" "$project_root/sdk/test-request-trace.mjs" "$project_root/sdk/test-project-provider-protocol.mjs" "$project_root/sdk/test-project-relay.mjs" "$project_root/sdk/test-subscription-quota.mjs" "$project_root/guest/text-runtime/test-runtime.mjs"
python3 -m unittest discover -s "$project_root/host/text-runtime" -p 'test_project_launch.py'
"$node_executable" --test "$project_root"/updates/test-*.mjs
swift build --package-path "$app_root" -c release --arch arm64
binary="$app_root/.build/arm64-apple-macosx/release/ClaudeIsolationPoC"
"$binary" --self-test --fixture-project-root "$project_root" --fixture-node "$node_executable"
bundle=${2:-"$app_root/dist/ClaudeIsolationPoC.app"}
if [ -e "$bundle" ]; then
  echo 'App bundle already exists; preserve it or remove only this generated bundle before rebuilding.' >&2
  exit 2
fi
staging_root=$(mktemp -d "$app_root/dist/.conversation-build.XXXXXX")
final_bundle=$bundle
bundle="$staging_root/ClaudeIsolationPoC.app"
trap 'rm -rf "$staging_root"' EXIT
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/ClaudeIsolationPoC"
cp "$app_icon" "$bundle/Contents/Resources/AppIcon.icns"
python3 "$app_root/tools/package_browser_runtime.py" "$browser_images" "$bundle/Contents/Resources/BrowserRuntime/images"
python3 - "$bundle" "$project_root" "$node_executable" "$app_version" "$app_build" <<'PY'
import hashlib, json, pathlib, plistlib, re, shutil, subprocess, sys
bundle, project_root, node, app_version, app_build = sys.argv[1:]
contents = pathlib.Path(bundle) / 'Contents'
source = pathlib.Path(project_root)
runtime = contents / 'Resources' / 'Runtime'
# The host contains our broker only. The official SDK and Linux CLI exist
# inside the verified guest disk, not as importable host node_modules.
for directory, files in {
    'translation': ['stdio.mjs', 'client.mjs', 'pipeline.mjs', 'protected-text.mjs', 'errors.mjs'],
    'sdk': ['vm-text-chat.mjs', 'vm-text-smoke.mjs', 'deepseek-text-chat.mjs', 'deepseek-text-smoke.mjs', 'owned-run-directory.mjs', 'request-trace.mjs', 'project-provider-protocol.mjs', 'subscription-quota.mjs', 'package.json'],
    'network': ['proxy-transport.mjs'],
    'runtime': ['profile.mjs'],
    'updates': ['stdio.mjs', 'client.mjs', 'health.mjs', 'official-stdio.mjs', 'official-client.mjs', 'official-integrity.mjs', 'local-builder.mjs'],
}.items():
    (runtime / directory).mkdir(parents=True)
    for name in files:
        shutil.copy2(source / directory / name, runtime / directory / name)
vm = runtime / 'host/text-runtime'
(vm / 'images').mkdir(parents=True)
for name in ['launch.py', 'common.py', 'local_build.py']:
    shutil.copy2(source / 'host/text-runtime' / name, vm / name)
for name in ['kernel', 'initrd', 'base.json']:
    shutil.copy2(source / 'host/text-runtime/images' / name, vm / 'images' / name)
subprocess.run(['/bin/cp', '-c', str(source / 'host/text-runtime/images/guest.raw'), str(vm / 'images/guest.raw')], check=True)
(vm / 'images/guest.raw').chmod(0o444)
helpers = contents / 'Helpers'
helpers.mkdir()
shutil.copy2(source / 'host/.build/release/vm-text-runtime', helpers / 'vm-text-runtime')
guest = runtime / 'guest/text-runtime'
guest.mkdir(parents=True)
for name in ['runtime.mjs', 'bootstrap.sh', 'supervisor.py']:
    shutil.copy2(source / 'guest/text-runtime' / name, guest / name)
guest_source = (guest / 'runtime.mjs').read_text()
def pinned_constant(name, pattern):
    matches = re.findall(r"^const " + re.escape(name) + r" = '([^']+)';$", guest_source, re.MULTILINE)
    if len(matches) != 1 or re.fullmatch(pattern, matches[0]) is None:
        raise RuntimeError('runtime_package_metadata_invalid')
    return matches[0]
sdk_version = pinned_constant('SDK_VERSION', r'[0-9]+\.[0-9]+\.[0-9]+')
cli_version = pinned_constant('CLI_VERSION', r'[0-9]+\.[0-9]+\.[0-9]+')
cli_hash = pinned_constant('CLI_SHA256', r'[a-f0-9]{64}')
base_path = vm / 'images/base.json'
base = json.loads(base_path.read_text())
sdk_pin = json.loads((runtime / 'sdk/package.json').read_text())['dependencies']['@anthropic-ai/claude-agent-sdk']
if base.get('sdk_version') != sdk_version or sdk_pin != sdk_version or base.get('linux_cli_sha256') != cli_hash:
    raise RuntimeError('runtime_package_metadata_mismatch')
# SDK and native CLI have distinct versions. This is an explicit guest pin,
# never an inferred CLI version from the SDK package number.
base['cli_version'] = cli_version
base_path.write_text(json.dumps(base, sort_keys=True, indent=2) + '\n')
(vm / 'runtime-config.json').write_text(json.dumps({
    'schema': 'claude-vm-runtime/v1', 'image_dir': 'images',
    'runner': '../../../../Helpers/vm-text-runtime',
    'guest_runtime_dir': '../../guest/text-runtime', 'python': '/usr/bin/python3'
}, indent=2) + '\n')
manifest = {str(p.relative_to(contents)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in runtime.rglob('*') if p.is_file() and p.name != 'guest.raw'}
(contents / 'Resources/PrivacyRuntimeManifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
config = {'projectRoot': project_root, 'nodeExecutable': node}
(contents / 'Resources' / 'ProjectConfiguration.json').write_text(json.dumps(config, ensure_ascii=False, indent=2) + '\n')
info = {'CFBundleName': 'ClaudeIsolationPoC', 'CFBundleDisplayName': 'Claude 隔离工作台', 'CFBundleIdentifier': 'com.claude-isolation-poc.app', 'CFBundleExecutable': 'ClaudeIsolationPoC', 'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon', 'CFBundleVersion': app_build, 'CFBundleShortVersionString': app_version, 'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
        'CFBundleDocumentTypes': [{'CFBundleTypeName': 'Claude Runtime Package', 'CFBundleTypeRole': 'Viewer', 'LSHandlerRank': 'Owner', 'LSTypeIsPackage': True, 'LSItemContentTypes': ['com.claude-isolation.runtime-package']}],
        'UTExportedTypeDeclarations': [{'UTTypeIdentifier': 'com.claude-isolation.runtime-package', 'UTTypeDescription': 'Claude Runtime Package', 'UTTypeConformsTo': ['com.apple.package'], 'UTTypeTagSpecification': {'public.filename-extension': ['clauderuntime']}}]}
with (contents / 'Info.plist').open('wb') as handle:
    plistlib.dump(info, handle)
PY
bash "$app_root/tools/build_runtime_package_tool.sh"
runtime_package_tool="$app_root/.build/runtime-package-tool"
runtime_signing_key="$HOME/Library/Application Support/ClaudeIsolationBuild/Signing/runtime-ed25519.key"
"$runtime_package_tool" prepare-key --key-file "$runtime_signing_key" \
  --trust-output "$bundle/Contents/Resources/RuntimeTrust.json"
"$runtime_package_tool" bundled-manifest --contents-root "$bundle/Contents" \
  --output "$bundle/Contents/Resources/BundledRuntimeManifest.json" --version "$app_version"
codesign --force --sign - --entitlements "$app_root/browser.entitlements" --identifier com.claude-isolation-poc.app "$bundle"
codesign --verify --strict "$bundle"
mv "$bundle" "$final_bundle"
bundle=$final_bundle
printf '%s\n' "$bundle"
