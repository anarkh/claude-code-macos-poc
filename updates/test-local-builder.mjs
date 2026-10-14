import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { LocalBuildFailure, rewriteTemplatePins, runLocalBuild, validateBuildRequest } from './local-builder.mjs';

const execute = promisify(execFile);
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const old = { sdkVersion: '0.3.295', cliVersion: '2.1.295', cliSHA256: 'cfb9dc1332fb6f92a683f835823e91b3179a803398ca7852cd2381a3cb1dea3b' };
const next = { sdkVersion: '0.3.296', cliVersion: '2.1.296', cliSHA256: 'f1f6e96e0d8342b9dbf41d7e88255397a6a52ce3d8736ad6a4c6b59c9b62fefa' };
function fixture() {
  const integrity = 'sha512-' + Buffer.alloc(64).toString('base64');
  const release = { schema: 'official-paired-release/v1', sdkVersion: next.sdkVersion, cliVersion: next.cliVersion, nodeMinimum: '18.0.0',
    artifacts: { sdk: { name: '@anthropic-ai/claude-agent-sdk', version: next.sdkVersion, integrity, unpackedSize: 8 }, nativeCLI: { name: '@anthropic-ai/claude-agent-sdk-linux-arm64', version: next.sdkVersion, integrity, unpackedSize: 8 }, cli: { platform: 'linux-arm64', sha256: next.cliSHA256, size: 8 } } };
  const receipt = { schema: 'official-runtime-receipt/v1', sdkVersion: next.sdkVersion, cliVersion: next.cliVersion, nodeMinimum: '18.0.0',
    sdkArchiveSHA256: '1'.repeat(64), nativeArchiveSHA256: '2'.repeat(64), cliSHA256: next.cliSHA256, cliManifestSHA256: '3'.repeat(64), cliSigningKeySHA256: '4'.repeat(64),
    sdkIntegrity: integrity, nativeIntegrity: integrity, cliBytes: 8, sdkArchiveBytes: 8, nativeArchiveBytes: 8, installationScriptsExecuted: false, cliExecuted: false, binaryMatchesSignedManifest: true };
  return { schema: 'official-runtime-build/v1', templateContents: '/private/template.app/Contents', artifactDirectory: '/private/build/artifacts', candidateDirectory: '/private/build/candidate', release, receipt };
}
const failure = code => error => error instanceof LocalBuildFailure && error.code === code;

test('paired request keeps CLI and SDK versions distinct and rejects changed trust or resource bounds', () => {
  const request = fixture(); assert.equal(validateBuildRequest(request), request);
  for (const mutate of [
    value => { value.release.cliVersion = value.release.sdkVersion; },
    value => { value.receipt.cliSHA256 = '0'.repeat(64); },
    value => { value.receipt.installationScriptsExecuted = true; },
    value => { value.receipt.cliExecuted = true; },
    value => { value.receipt.binaryMatchesSignedManifest = false; },
    value => { value.release.artifacts.nativeCLI.version = '0.3.295'; },
    value => { value.release.artifacts.cli.platform = 'darwin-arm64'; },
    value => { value.release.artifacts.sdk.unpackedSize = 320 * 1024 ** 2; },
    value => { value.receipt.nativeArchiveBytes = 160 * 1024 ** 2 + 1; },
    value => { value.release.nodeMinimum = '>=18'; },
    value => { value.modulePath = '/private/downloaded.mjs'; },
  ]) { const value = structuredClone(request); mutate(value); assert.throws(() => validateBuildRequest(value), failure('UPDATE_BUILD_INVALID_REQUEST')); }
});

test('build destinations reject aliases, traversal, controls and overlapping input trees', () => {
  for (const mutation of [
    { candidateDirectory: 'relative/candidate' }, { candidateDirectory: '/private/build/../outside' },
    { candidateDirectory: '/private/build/candidate\n' }, { templateContents: '/private/template.app/Resources' },
    { candidateDirectory: '/private/build/artifacts/child' }, { artifactDirectory: '/private/template.app/Contents/input' },
  ]) assert.throws(() => validateBuildRequest({ ...fixture(), ...mutation }), failure('UPDATE_BUILD_INVALID_REQUEST'));
});

test('pre-aborted builds produce no progress or disk/VM work; executable rejects function injection', async () => {
  const abort = new AbortController(); abort.abort(); const events = [];
  await assert.rejects(runLocalBuild(fixture(), value => events.push(value), { signal: abort.signal }), failure('UPDATE_CANCELLED'));
  assert.deepEqual(events, []);
  await assert.rejects(runLocalBuild(fixture(), () => {}, { prepare: async () => {} }), failure('UPDATE_BUILD_INVALID_REQUEST'));
});

test('physical template and private staging checks fail before archives or VM execution', async () => {
  const root = await realpath(await mkdtemp('/private/tmp/local-build-paths-'));
  try {
    await mkdir(path.join(root, 'real/Contents'), { recursive: true, mode: 0o700 });
    await mkdir(path.join(root, 'inputs'), { mode: 0o700 });
    await symlink(path.join(root, 'real'), path.join(root, 'alias'));
    await assert.rejects(runLocalBuild({ ...fixture(), templateContents: path.join(root, 'alias/Contents'), artifactDirectory: path.join(root, 'inputs'), candidateDirectory: path.join(root, 'candidate') }), failure('UPDATE_BUILD_TEMPLATE_INVALID'));
    await chmod(root, 0o755);
    await assert.rejects(runLocalBuild({ ...fixture(), templateContents: path.join(root, 'real/Contents'), artifactDirectory: path.join(root, 'inputs'), candidateDirectory: path.join(root, 'candidate') }), failure('UPDATE_BUILD_INVALID_REQUEST'));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('pin transformations preserve every protocol shape and explicit beta allowlist', async () => {
  for (const [filename, kind] of [['guest/text-runtime/runtime.mjs', 'guest'], ['host/text-runtime/common.py', 'common'], ['sdk/deepseek-text-chat.mjs', 'chat'], ['sdk/deepseek-text-smoke.mjs', 'smoke']]) {
    const before = await readFile(path.join(project, filename), 'utf8');
    const after = rewriteTemplatePins(before, kind, old, next);
    assert.equal(rewriteTemplatePins(after, kind, next, old), before, filename);
    if (kind === 'chat') {
      const betas = source => source.match(/const SUBSCRIPTION_BETAS = new Set\([\s\S]*?\);/)[0];
      assert.equal(betas(after), betas(before));
      assert.ok(after.includes('cc_version=2\\.1\\.296\\.[a-z0-9]{3}'));
      assert.ok(after.includes("headers['user-agent'] !== 'claude-cli/2.1.296 (external, sdk-ts, agent-sdk/0.3.296)'"));
    }
    assert.throws(() => rewriteTemplatePins(before + before, kind, old, next), failure('UPDATE_BUILD_TEMPLATE_INVALID'));
  }
});

test('guest billing header advances its exact version pin and refuses missing or duplicate placeholders', async () => {
  const before = await readFile(path.join(project, 'guest/text-runtime/runtime.mjs'), 'utf8');
  const oldBilling = `cc_version=${old.cliVersion.replaceAll('.', '\\.')}\\.`;
  const newBilling = `cc_version=${next.cliVersion.replaceAll('.', '\\.')}\\.`;
  const after = rewriteTemplatePins(before, 'guest', old, next);
  assert.equal(after.includes(oldBilling), false, 'no old guest billing version may remain');
  assert.equal(after.split(newBilling).length - 1, 1);
  const billingPattern = source => source.match(/!\/(\^x-anthropic-billing-header:[^/]+)\/\.test/)[1];
  assert.equal(billingPattern(after), billingPattern(before).replace(oldBilling, newBilling));
  const pattern = new RegExp(billingPattern(after));
  assert.ok(pattern.test('x-anthropic-billing-header: cc_version=2.1.296.c4e; cc_entrypoint=sdk-ts;'));
  for (const value of [
    'x-anthropic-billing-header: cc_version=2.1.295.c4e; cc_entrypoint=sdk-ts;',
    'x-anthropic-billing-header: cc_version=2.1.296.c4e; cc_entrypoint=cli;',
    'x-anthropic-billing-header: cc_version=2.1.296.c4e1; cc_entrypoint=sdk-ts;',
    'x-anthropic-billing-header: cc_version=2x1x296.c4e; cc_entrypoint=sdk-ts;',
  ]) assert.equal(pattern.test(value), false, value);
  assert.throws(() => rewriteTemplatePins(before.replace(oldBilling, newBilling), 'guest', old, next), failure('UPDATE_BUILD_TEMPLATE_INVALID'));
  assert.throws(() => rewriteTemplatePins(before + `\n// unexpected duplicated ${oldBilling}\n`, 'guest', old, next), failure('UPDATE_BUILD_TEMPLATE_INVALID'));
});

// The production archive parser is tested through the system Python interpreter.
// All archives are locally synthesized bytes; no downloaded file is executed.
const archiveTest = String.raw`
import gzip, importlib.util, io, json, pathlib, shutil, tarfile, tempfile, sys
spec=importlib.util.spec_from_file_location('local_build',sys.argv[1]);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
root=pathlib.Path(tempfile.mkdtemp(prefix='local-build-archive-',dir='/private/tmp'))
def archive(entries):
 out=io.BytesIO()
 with tarfile.open(fileobj=out,mode='w',format=tarfile.USTAR_FORMAT) as tar:
  for name,kind,data in entries:
   info=tarfile.TarInfo(name);info.type=kind
   if kind==tarfile.REGTYPE:info.size=len(data);tar.addfile(info,io.BytesIO(data))
   elif kind in (tarfile.SYMTYPE,tarfile.LNKTYPE):info.linkname='../../outside';tar.addfile(info)
   else:tar.addfile(info)
 return gzip.compress(out.getvalue())
def run(label,entries,expected=2,cancel=False,transform=None):
 source=root/(label+'.tgz');payload=archive(entries);source.write_bytes(transform(payload) if transform else payload)
 budget={'bytes':0,'decoded':0,'members':0};dest=root/label
 def check():
  if cancel:mod.fail('UPDATE_CANCELLED')
 try:return {'files':mod.extract_archive(source,dest,expected,budget,check),'bytes':budget['bytes']}
 except (mod.BuildError,OSError,EOFError) as err:return {'error':getattr(err,'code',type(err).__name__)}
cases={}
regular=[('package/package.json',tarfile.REGTYPE,b'{}')]
cases['regular']=run('regular',regular)
for label,name in [('traversal','package/../outside'),('absolute','/package/outside'),('backslash','package/a\outside'),('empty','package//outside')]:
 cases[label]=run(label,[(name,tarfile.REGTYPE,b'{}')])
for label,kind in [('symlink',tarfile.SYMTYPE),('hardlink',tarfile.LNKTYPE),('device',tarfile.CHRTYPE),('pax',tarfile.XHDTYPE),('sparse',tarfile.GNUTYPE_SPARSE)]:
 cases[label]=run(label,regular+[('package/unsafe',kind,b'')])
cases['duplicate']=run('duplicate',regular+regular,4)
cases['caseAlias']=run('caseAlias',regular+[('package/PACKAGE.JSON',tarfile.REGTYPE,b'{}')],4)
cases['directoryCaseAlias']=run('directoryCaseAlias',regular+[('package/Foo/a',tarfile.REGTYPE,b'a'),('package/foo/b',tarfile.REGTYPE,b'b')],4)
cases['fileParent']=run('fileParent',regular+[('package/package.json/child',tarfile.REGTYPE,b'{}')],4)
cases['bound']=run('bound',regular,1)
cases['cancel']=run('cancel',regular,cancel=True)
def badChecksum(payload):
 raw=bytearray(gzip.decompress(payload));raw[10]^=1;return gzip.compress(raw)
cases['checksum']=run('checksum',regular,transform=badChecksum)
cases['crc']=run('crc',regular,transform=lambda payload:payload[:-4]+b'bad!')
print(json.dumps(cases));shutil.rmtree(root)
`;
test('safe archive parser accepts exact regular payloads and rejects archive attacks and cancellation', async () => {
  const { stdout } = await execute('/usr/bin/python3', ['-c', archiveTest, path.join(project, 'host/text-runtime/local_build.py')], { env: { PATH: '/usr/bin:/bin', PYTHONDONTWRITEBYTECODE: '1' }, timeout: 10_000 });
  const results = JSON.parse(stdout); assert.deepEqual(results.regular, { files: ['package.json'], bytes: 2 });
  assert.equal(results.cancel.error, 'UPDATE_CANCELLED');
  for (const [label, result] of Object.entries(results)) if (!['regular', 'cancel'].includes(label)) assert.ok(result.error, label);
});

const prepareFixture = String.raw`
import gzip,hashlib,io,json,pathlib,tarfile,sys
container=pathlib.Path(sys.argv[1]);parent=int(sys.argv[2]);scratch=container/'.runtime-build-fixture';scratch.mkdir(mode=0o700)
(scratch/'.owner.json').write_text(json.dumps({'schema':'runtime-build-scratch/v1','parentPID':parent}))
images=scratch/'payload/Contents/Resources/Runtime/host/text-runtime/images';images.mkdir(parents=True)
with (images/'guest.raw').open('wb') as disk:disk.truncate(8*1024**3)
(images/'guest.raw').chmod(0o600)
artifacts=container/'artifacts';artifacts.mkdir(mode=0o700)
sdk={'package.json':json.dumps({'name':'@anthropic-ai/claude-agent-sdk','version':'0.3.296','claudeCodeVersion':'2.1.296','engines':{'node':'>=18.0.0'},'optionalDependencies':{'@anthropic-ai/claude-agent-sdk-linux-arm64':'0.3.296'}}).encode(),'sdk.mjs':b'throw Error("downloaded SDK must never run on host");'}
native={'package.json':json.dumps({'name':'@anthropic-ai/claude-agent-sdk-linux-arm64','version':'0.3.296','os':['linux'],'cpu':['arm64'],'libc':['glibc']}).encode(),'claude':b'c','README.md':b'public','LICENSE.md':b'public'}
def archive(name,files):
 out=io.BytesIO()
 with tarfile.open(fileobj=out,mode='w',format=tarfile.USTAR_FORMAT) as tar:
  for filename,data in files.items():
   info=tarfile.TarInfo('package/'+filename);info.size=len(data);tar.addfile(info,io.BytesIO(data))
 payload=gzip.compress(out.getvalue());(artifacts/name).write_bytes(payload)
 return hashlib.sha256(payload).hexdigest(),sum(map(len,files.values()))
sdk_hash,sdk_bytes=archive('root-sdk.tgz',sdk);native_hash,native_bytes=archive('native-cli.tgz',native)
helper=scratch/'payload/Contents/Helpers/vm-text-runtime';helper.parent.mkdir(parents=True)
helper.write_text('#!/usr/bin/python3\nimport json,os,pathlib,signal,sys,time\npathlib.Path('+repr(str(container/'helper-pid'))+').write_text(str(os.getpid()))\nprint(json.dumps({"kind":"vm_config","network_devices":0,"host_directory_shares":0,"directory_shares":0,"socket_devices":0,"vsock_port":0}),file=sys.stderr,flush=True)\nwhile True: time.sleep(0.1)\n');helper.chmod(0o700)
config={'schema':'official-runtime-prepare/v1','scratchRoot':str(scratch),'imageDirectory':str(images),'runner':str(helper),'artifactDirectory':str(artifacts),'sdkVersion':'0.3.296','cliVersion':'2.1.296','cliSHA256':hashlib.sha256(b'c').hexdigest(),'cliBytes':1,'nodeVersion':'26.7.0','nodeMinimum':'18.0.0','sdkUnpackedBytes':sdk_bytes,'nativeUnpackedBytes':native_bytes,'sdkArchiveSHA256':sdk_hash,'nativeArchiveSHA256':native_hash}
print(json.dumps(config))
`;
const waitFor = async (predicate, maximum = 10_000) => {
  const began = Date.now(); while (!await predicate()) { if (Date.now() - began > maximum) throw new Error('fixture deadline'); await new Promise(resolve => setTimeout(resolve, 30)); }
};
const exists = async filename => { try { await stat(filename); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; } };
const running = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };

test('preparation cancellation terminates its helper and removes its owned seed/package scratch', async () => {
  const container = await realpath(await mkdtemp('/private/tmp/local-build-cancel-')); await chmod(container, 0o700);
  let child;
  try {
    const { stdout } = await execute('/usr/bin/python3', ['-c', prepareFixture, container, String(process.pid)], { timeout: 10_000 });
    child = spawn('/usr/bin/python3', [path.join(project, 'host/text-runtime/local_build.py')], { env: { PATH: '/usr/bin:/bin', PYTHONDONTWRITEBYTECODE: '1' }, stdio: ['pipe', 'pipe', 'pipe'] });
    let output = ''; child.stdout.on('data', chunk => { output += chunk; }); child.stderr.resume();
    const closed = new Promise(resolve => child.once('close', resolve)); child.stdin.end(stdout);
    await waitFor(() => exists(path.join(container, 'helper-pid')));
    const helper = Number(await readFile(path.join(container, 'helper-pid'), 'utf8')); assert.ok(running(helper));
    child.kill('SIGTERM'); assert.equal(await closed, 2);
    assert.ok(output.includes('UPDATE_CANCELLED')); await waitFor(() => !running(helper));
    assert.equal(await exists(path.join(container, '.runtime-build-fixture/prepare')), false);
    assert.equal(await exists(path.join(container, '.runtime-build-fixture/.owner.json')), true);
  } finally { child?.kill('SIGKILL'); await rm(container, { recursive: true, force: true }); }
});

test('preparation parent-exit watchdog stops the helper and removes the full owned build scratch', async () => {
  const container = await realpath(await mkdtemp('/private/tmp/local-build-parent-')); await chmod(container, 0o700);
  let wrapper;
  try {
    const configuration = path.join(container, 'config.json');
    const wrapperSource = String.raw`
      const {spawn}=require('node:child_process');const fs=require('node:fs');
      const fixture=spawn('/usr/bin/python3',['-c',process.env.FIXTURE,process.env.CONTAINER,String(process.pid)],{stdio:['ignore','pipe','inherit']});let input='';fixture.stdout.on('data',x=>input+=x);fixture.on('close',code=>{if(code!==0)process.exit(2);fs.writeFileSync(process.env.CONFIG,input);const child=spawn('/usr/bin/python3',[process.env.RECIPE],{stdio:['pipe','ignore','ignore']});fs.writeFileSync(process.env.CONTAINER+'/prepare-pid',String(child.pid));child.stdin.end(input);});setInterval(()=>{},1000);
    `;
    wrapper = spawn(process.execPath, ['-e', wrapperSource], { env: { PATH: '/usr/bin:/bin', FIXTURE: prepareFixture, CONTAINER: container, CONFIG: configuration, RECIPE: path.join(project, 'host/text-runtime/local_build.py'), PYTHONDONTWRITEBYTECODE: '1' }, stdio: ['ignore', 'ignore', 'pipe'] }); wrapper.stderr.resume();
    await waitFor(() => exists(path.join(container, 'helper-pid')));
    const helper = Number(await readFile(path.join(container, 'helper-pid'), 'utf8'));
    wrapper.kill('SIGKILL'); await waitFor(() => !running(helper));
    await waitFor(async () => !await exists(path.join(container, '.runtime-build-fixture')));
    assert.equal(await exists(path.join(container, 'artifacts/root-sdk.tgz')), true, 'external downloaded inputs are preserved');
  } finally { wrapper?.kill('SIGKILL'); await rm(container, { recursive: true, force: true }); }
});
