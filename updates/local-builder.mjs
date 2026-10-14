// App-owned offline recipe. Downloaded JavaScript and native code are data on
// the host; the native CLI is first executed by the isolated health probe.
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { chmod, copyFile, lstat, mkdir, mkdtemp, open, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MODULE = fileURLToPath(import.meta.url);
const PYTHON = path.resolve(path.dirname(MODULE), '../host/text-runtime/local_build.py');
const RUNTIME = 'Resources/Runtime';
const IMAGES = `${RUNTIME}/host/text-runtime/images`;
const DISK = `${IMAGES}/guest.raw`;
const MAX_DISK = 8 * 1024 ** 3;
const MAX_SMALL = 128 * 1024 ** 2;
const MAX_ARCHIVE = 160 * 1024 ** 2;
const MAX_UNPACKED = 320 * 1024 ** 2;
const REQUIRED = [
  'Helpers/vm-text-runtime', `${RUNTIME}/sdk/vm-text-chat.mjs`, `${RUNTIME}/sdk/vm-text-smoke.mjs`,
  `${RUNTIME}/sdk/deepseek-text-chat.mjs`, `${RUNTIME}/sdk/deepseek-text-smoke.mjs`,
  `${RUNTIME}/sdk/owned-run-directory.mjs`, `${RUNTIME}/sdk/package.json`,
  ...['stdio.mjs', 'client.mjs', 'pipeline.mjs', 'protected-text.mjs', 'errors.mjs'].map(name => `${RUNTIME}/translation/${name}`),
  `${RUNTIME}/network/proxy-transport.mjs`, `${RUNTIME}/runtime/profile.mjs`,
  `${RUNTIME}/host/text-runtime/launch.py`, `${RUNTIME}/host/text-runtime/common.py`,
  `${RUNTIME}/host/text-runtime/runtime-config.json`, `${IMAGES}/base.json`, `${IMAGES}/kernel`, `${IMAGES}/initrd`, DISK,
  ...['runtime.mjs', 'bootstrap.sh', 'supervisor.py'].map(name => `${RUNTIME}/guest/text-runtime/${name}`),
];
const CODES = new Set(['UPDATE_BUILD_INVALID_REQUEST', 'UPDATE_BUILD_TEMPLATE_INVALID', 'UPDATE_BUILD_ARCHIVE_INVALID',
  'UPDATE_BUILD_NODE_UNSUPPORTED', 'UPDATE_BUILD_PREPARE_FAILED', 'UPDATE_BUILD_FAILED', 'UPDATE_CANCELLED']);
export class LocalBuildFailure extends Error {
  constructor(code) { super(CODES.has(code) ? code : 'UPDATE_BUILD_FAILED'); this.code = this.message; }
}
const fail = code => { throw new LocalBuildFailure(code); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exact = (value, keys) => object(value) && Object.keys(value).length === keys.length && Object.keys(value).every(key => keys.includes(key));
const version = value => typeof value === 'string' && /^\d{1,9}\.\d{1,9}\.\d{1,9}$/.test(value);
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const check = signal => { if (signal?.aborted) fail('UPDATE_CANCELLED'); };
const canonical = value => JSON.stringify(value, (_key, item) => object(item) ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
const compare = (a, b) => { const aa = a.split('.').map(Number), bb = b.split('.').map(Number); for (let i = 0; i < 3; i++) if (aa[i] !== bb[i]) return aa[i] - bb[i]; return 0; };
function physicalPath(value, code) {
  if (typeof value !== 'string' || Buffer.byteLength(value) > 4096 || !path.isAbsolute(value) || path.normalize(value) !== value || /[\x00-\x1f\x7f]/.test(value)) fail(code);
  return value;
}
async function ancestors(filename, directory = false, code = 'UPDATE_BUILD_INVALID_REQUEST') {
  let current = path.parse(filename).root;
  const components = filename.slice(current.length).split(path.sep).filter(Boolean);
  for (let i = 0; i < components.length; i++) {
    current = path.join(current, components[i]); const metadata = await lstat(current);
    if (metadata.isSymbolicLink() || ((i < components.length - 1 || directory) && !metadata.isDirectory())) fail(code);
  }
}
async function regular(filename, maximum, code) {
  await ancestors(filename, false, code); const metadata = await lstat(filename);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > maximum) fail(code);
  return metadata;
}
async function smallJSON(filename, code) {
  await regular(filename, 64 * 1024, code);
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await readFile(filename))); }
  catch { fail(code); }
}
async function fileDigest(filename, signal, maximum = MAX_SMALL, code = 'UPDATE_BUILD_TEMPLATE_INVALID') {
  await regular(filename, maximum, code); check(signal);
  const handle = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const hasher = createHash('sha256'), buffer = Buffer.alloc(1024 * 1024); let size = 0;
    for (;;) { check(signal); const { bytesRead } = await handle.read(buffer, 0, buffer.length, null); if (!bytesRead) break; size += bytesRead; if (size > maximum) fail(code); hasher.update(buffer.subarray(0, bytesRead)); }
    check(signal); return hasher.digest('hex');
  } finally { await handle.close(); }
}

export function validateBuildRequest(request) {
  if (!exact(request, ['schema', 'templateContents', 'artifactDirectory', 'candidateDirectory', 'release', 'receipt']) || request.schema !== 'official-runtime-build/v1') fail('UPDATE_BUILD_INVALID_REQUEST');
  for (const key of ['templateContents', 'artifactDirectory', 'candidateDirectory']) physicalPath(request[key], 'UPDATE_BUILD_INVALID_REQUEST');
  if (path.basename(request.templateContents) !== 'Contents') fail('UPDATE_BUILD_INVALID_REQUEST');
  const roots = ['templateContents', 'artifactDirectory', 'candidateDirectory'].map(key => request[key]);
  for (let i = 0; i < roots.length; i++) for (let j = i + 1; j < roots.length; j++) if (roots[i] === roots[j] || roots[i].startsWith(roots[j] + '/') || roots[j].startsWith(roots[i] + '/')) fail('UPDATE_BUILD_INVALID_REQUEST');
  const release = request.release, receipt = request.receipt;
  if (!object(release) || release.schema !== 'official-paired-release/v1' || !version(release.sdkVersion) || !version(release.cliVersion) || !version(release.nodeMinimum) ||
      !object(release.artifacts) || !object(release.artifacts.sdk) || !object(release.artifacts.nativeCLI) || !object(release.artifacts.cli) ||
      release.artifacts.sdk.name !== '@anthropic-ai/claude-agent-sdk' || release.artifacts.sdk.version !== release.sdkVersion ||
      release.artifacts.nativeCLI.name !== '@anthropic-ai/claude-agent-sdk-linux-arm64' || release.artifacts.nativeCLI.version !== release.sdkVersion ||
      release.artifacts.cli.platform !== 'linux-arm64' || !digest(release.artifacts.cli.sha256) || !Number.isSafeInteger(release.artifacts.cli.size) || release.artifacts.cli.size <= 0 || release.artifacts.cli.size > MAX_UNPACKED ||
      ![release.artifacts.sdk, release.artifacts.nativeCLI].every(item => typeof item.integrity === 'string' && /^sha512-[A-Za-z0-9+/]{86}==$/.test(item.integrity) && Number.isSafeInteger(item.unpackedSize) && item.unpackedSize > 0 && item.unpackedSize <= MAX_UNPACKED) ||
      release.artifacts.sdk.unpackedSize + release.artifacts.nativeCLI.unpackedSize > MAX_UNPACKED ||
      !object(receipt) || receipt.schema !== 'official-runtime-receipt/v1' || receipt.sdkVersion !== release.sdkVersion || receipt.cliVersion !== release.cliVersion || receipt.nodeMinimum !== release.nodeMinimum ||
      !['sdkArchiveSHA256', 'nativeArchiveSHA256', 'cliSHA256', 'cliManifestSHA256', 'cliSigningKeySHA256'].every(key => digest(receipt[key])) ||
      receipt.cliSHA256 !== release.artifacts.cli.sha256 || receipt.cliBytes !== release.artifacts.cli.size || receipt.sdkIntegrity !== release.artifacts.sdk.integrity || receipt.nativeIntegrity !== release.artifacts.nativeCLI.integrity ||
      !['sdkArchiveBytes', 'nativeArchiveBytes'].every(key => Number.isSafeInteger(receipt[key]) && receipt[key] > 0 && receipt[key] <= MAX_ARCHIVE) ||
      receipt.installationScriptsExecuted !== false || receipt.cliExecuted !== false || receipt.binaryMatchesSignedManifest !== true) fail('UPDATE_BUILD_INVALID_REQUEST');
  return request;
}

// Replace exactly the admitted version/hash placeholders in trusted sources.
// Protocol shape, beta tags, model/tool checks and settings restrictions remain
// byte-for-byte unchanged; a changed upstream protocol must fail health.
export function rewriteTemplatePins(source, kind, old, next) {
  const replace = (before, after, expected = 1) => { const count = source.split(before).length - 1; if (count !== expected) fail('UPDATE_BUILD_TEMPLATE_INVALID'); source = source.split(before).join(after); };
  if (kind === 'guest') {
    for (const [name, key] of [['SDK_VERSION', 'sdkVersion'], ['CLI_VERSION', 'cliVersion'], ['CLI_SHA256', 'cliSHA256']]) replace(`const ${name} = '${old[key]}';`, `const ${name} = '${next[key]}';`);
    replace(`cc_version=${old.cliVersion.replaceAll('.', '\\.')}\\.`, `cc_version=${next.cliVersion.replaceAll('.', '\\.')}\\.`);
  } else if (kind === 'common') replace(`CLI_SHA256 = '${old.cliSHA256}'`, `CLI_SHA256 = '${next.cliSHA256}'`);
  else if (kind === 'chat') {
    replace(`claude-cli/${old.cliVersion} (external, sdk-ts, agent-sdk/${old.sdkVersion})`, `claude-cli/${next.cliVersion} (external, sdk-ts, agent-sdk/${next.sdkVersion})`);
    replace(`CLAUDE_AGENT_SDK_VERSION: '${old.sdkVersion}'`, `CLAUDE_AGENT_SDK_VERSION: '${next.sdkVersion}'`);
    replace(`event.claude_code_version === '${old.cliVersion}'`, `event.claude_code_version === '${next.cliVersion}'`);
    replace(`cc_version=${old.cliVersion.replaceAll('.', '\\.')}\\.`, `cc_version=${next.cliVersion.replaceAll('.', '\\.')}\\.`);
    replace(`// Pinned CLI ${old.cliVersion} OAuth`, `// Pinned CLI ${next.cliVersion} OAuth`);
  } else if (kind === 'smoke') {
    replace(`packageInfo.version !== '${old.sdkVersion}' || sdkPackageInfo.version !== '${old.sdkVersion}'`, `packageInfo.version !== '${next.sdkVersion}' || sdkPackageInfo.version !== '${next.sdkVersion}'`);
    replace(`sdkVersion: '${old.sdkVersion}', expectedCliVersion: '${old.cliVersion}'`, `sdkVersion: '${next.sdkVersion}', expectedCliVersion: '${next.cliVersion}'`);
    replace(`CLAUDE_AGENT_SDK_VERSION: '${old.sdkVersion}'`, `CLAUDE_AGENT_SDK_VERSION: '${next.sdkVersion}'`);
    replace(`event.claude_code_version === '${old.cliVersion}'`, `event.claude_code_version === '${next.cliVersion}'`, 2);
    replace(`// CLI ${old.cliVersion} appends`, `// CLI ${next.cliVersion} appends`);
  } else fail('UPDATE_BUILD_TEMPLATE_INVALID');
  return source;
}

async function inventory(template, signal) {
  const files = [], folded = new Set(); let total = 0;
  async function walk(relative) {
    check(signal); const filename = path.join(template, relative); await ancestors(filename, false, 'UPDATE_BUILD_TEMPLATE_INVALID');
    const metadata = await lstat(filename);
    if (metadata.isSymbolicLink() || !/^[A-Za-z0-9_.+@/-]+$/.test(relative) || relative.split('/').some(component => !component || component.startsWith('.') || component === 'node_modules') || folded.has(relative.toLowerCase())) fail('UPDATE_BUILD_TEMPLATE_INVALID');
    folded.add(relative.toLowerCase());
    if (metadata.isDirectory()) { for (const name of (await readdir(filename)).sort()) await walk(`${relative}/${name}`); }
    else if (metadata.isFile()) {
      if (metadata.size > (relative === DISK ? MAX_DISK : MAX_SMALL) || files.length >= 4096) fail('UPDATE_BUILD_TEMPLATE_INVALID');
      total += metadata.size; if (total > 12 * 1024 ** 3) fail('UPDATE_BUILD_TEMPLATE_INVALID');
      files.push({ relative, size: metadata.size, executable: Boolean(metadata.mode & 0o111) });
    } else fail('UPDATE_BUILD_TEMPLATE_INVALID');
  }
  await walk('Helpers'); await walk(RUNTIME);
  if (!REQUIRED.every(name => files.some(file => file.relative === name)) || files.some(file => file.relative.startsWith('Helpers/') && file.relative !== 'Helpers/vm-text-runtime')) fail('UPDATE_BUILD_TEMPLATE_INVALID');
  return files;
}

async function prepareVM(input, emit, signal) {
  await regular(PYTHON, MAX_SMALL, 'UPDATE_BUILD_TEMPLATE_INVALID');
  check(signal);
  return await new Promise((resolve, reject) => {
    const child = spawn('/usr/bin/python3', [PYTHON], { env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C.UTF-8', PYTHONDONTWRITEBYTECODE: '1' }, stdio: ['pipe', 'pipe', 'pipe'] });
    let pending = '', size = 0, stderrBytes = 0, result, invalid = false, stopped = false, timeout;
    const terminate = () => { if (!stopped) { child.kill('SIGTERM'); timeout ??= setTimeout(() => child.kill('SIGKILL'), 15_000); } };
    const onAbort = () => terminate(); signal?.addEventListener('abort', onAbort, { once: true });
    const deadline = setTimeout(() => { invalid = true; terminate(); }, 360_000);
    child.on('error', () => { invalid = true; });
    child.stdout.on('data', chunk => {
      size += chunk.length; pending += chunk.toString('utf8'); if (size > 64 * 1024 || pending.length > 16 * 1024) { invalid = true; terminate(); return; }
      for (;;) {
        const index = pending.indexOf('\n'); if (index < 0) break; const line = pending.slice(0, index); pending = pending.slice(index + 1);
        try {
          const value = JSON.parse(line);
          if (value.type === 'progress' && ['extract', 'prepare'].includes(value.phase) && typeof value.fraction === 'number' && value.fraction >= 0 && value.fraction <= 1) emit(value);
          else if (value.type === 'prepared' && result === undefined) result = value;
          else if (value.type === 'error' && CODES.has(value.code)) { result = value; }
          else { invalid = true; terminate(); }
        } catch { invalid = true; terminate(); }
      }
    });
    child.stderr.on('data', chunk => { stderrBytes += chunk.length; if (stderrBytes > 64 * 1024) { invalid = true; terminate(); } });
    child.on('close', code => {
      stopped = true; clearTimeout(deadline); clearTimeout(timeout); signal?.removeEventListener('abort', onAbort);
      if (signal?.aborted) reject(new LocalBuildFailure('UPDATE_CANCELLED'));
      else if (result?.type === 'error') reject(new LocalBuildFailure(result.code));
      else if (code !== 0 || invalid || pending.length || !exact(result, ['type', 'nodeVersion', 'preparationSeconds', 'isolation']) || result.nodeVersion !== input.nodeVersion || !exact(result.isolation, ['networkDevices', 'directoryShares', 'socketDevices', 'noUserData']) || result.isolation.networkDevices !== 0 || result.isolation.directoryShares !== 0 || result.isolation.socketDevices !== 0 || result.isolation.noUserData !== true) reject(new LocalBuildFailure('UPDATE_BUILD_PREPARE_FAILED'));
      else resolve(result);
    });
    child.stdin.on('error', () => { invalid = true; terminate(); }); child.stdin.end(JSON.stringify(input));
    if (signal?.aborted) terminate();
  });
}

async function cloneDisk(source, target, signal) {
  // Some bundled Node distributions do not implement COPYFILE_FICLONE_FORCE
  // on macOS. cp -c invokes Apple's clonefile and refuses a normal copy.
  check(signal);
  await new Promise((resolve, reject) => {
    const child = spawn('/bin/cp', ['-c', source, target], { env: { PATH: '/usr/bin:/bin', LANG: 'C' }, stdio: ['ignore', 'ignore', 'ignore'] });
    const cancel = () => child.kill('SIGTERM'); signal?.addEventListener('abort', cancel, { once: true });
    child.once('error', () => reject(new LocalBuildFailure('UPDATE_BUILD_FAILED')));
    child.once('close', code => { signal?.removeEventListener('abort', cancel); if (signal?.aborted) reject(new LocalBuildFailure('UPDATE_CANCELLED')); else if (code !== 0) reject(new LocalBuildFailure('UPDATE_BUILD_FAILED')); else resolve(); });
    if (signal?.aborted) cancel();
  });
}

export async function runLocalBuild(request, emit = () => {}, options = {}) {
  let owned, signal, published = false;
  try {
    if (!object(options) || Object.keys(options).some(key => !['signal', 'testOnly', 'prepare'].includes(key)) || (options.signal !== undefined && !(options.signal instanceof AbortSignal)) || (options.testOnly !== undefined && options.testOnly !== true) || (options.prepare !== undefined && (options.testOnly !== true || typeof options.prepare !== 'function')) || typeof emit !== 'function') fail('UPDATE_BUILD_INVALID_REQUEST');
    signal = options.signal; check(signal); validateBuildRequest(request);
    emit({ type: 'progress', phase: 'validate', fraction: 0 });
    const { templateContents: template, artifactDirectory: artifacts, candidateDirectory: candidate, release, receipt } = request;
    await ancestors(template, true, 'UPDATE_BUILD_TEMPLATE_INVALID'); await ancestors(artifacts, true);
    const parent = path.dirname(candidate); await ancestors(parent, true); const parentMeta = await lstat(parent);
    if (parentMeta.uid !== process.getuid?.() || (parentMeta.mode & 0o777) !== 0o700) fail('UPDATE_BUILD_INVALID_REQUEST');
    try { await lstat(candidate); fail('UPDATE_BUILD_INVALID_REQUEST'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const persistedReceipt = await smallJSON(path.join(artifacts, 'receipt.json'), 'UPDATE_BUILD_ARCHIVE_INVALID');
    if (canonical(persistedReceipt) !== canonical(receipt)) fail('UPDATE_BUILD_ARCHIVE_INVALID');
    for (const [name, bytesKey, hashKey] of [['root-sdk.tgz', 'sdkArchiveBytes', 'sdkArchiveSHA256'], ['native-cli.tgz', 'nativeArchiveBytes', 'nativeArchiveSHA256']]) {
      const filename = path.join(artifacts, name), metadata = await regular(filename, MAX_ARCHIVE, 'UPDATE_BUILD_ARCHIVE_INVALID');
      if (metadata.size !== receipt[bytesKey] || await fileDigest(filename, signal, MAX_ARCHIVE, 'UPDATE_BUILD_ARCHIVE_INVALID') !== receipt[hashKey]) fail('UPDATE_BUILD_ARCHIVE_INVALID');
    }
    const files = await inventory(template, signal), base = await smallJSON(path.join(template, IMAGES, 'base.json'), 'UPDATE_BUILD_TEMPLATE_INVALID');
    if (base.schema !== 'claude-text-vm-base/v1' || base.prepared !== true || base.no_user_data !== true || base.network_devices !== 0 || base.directory_shares !== 0 || !version(base.sdk_version) || !version(base.cli_version) || !version(base.node_version) || base.disk_bytes !== MAX_DISK || !['disk_sha256', 'kernel_sha256', 'initrd_sha256', 'linux_cli_sha256'].every(key => digest(base[key]))) fail('UPDATE_BUILD_TEMPLATE_INVALID');
    if (compare(base.node_version, release.nodeMinimum) < 0) fail('UPDATE_BUILD_NODE_UNSUPPORTED');
    const disk = await regular(path.join(template, DISK), MAX_DISK, 'UPDATE_BUILD_TEMPLATE_INVALID');
    if (disk.size !== MAX_DISK || disk.mode & 0o222) fail('UPDATE_BUILD_TEMPLATE_INVALID');
    for (const [name, key] of [['guest.raw', 'disk_sha256'], ['kernel', 'kernel_sha256'], ['initrd', 'initrd_sha256']]) if (await fileDigest(path.join(template, IMAGES, name), signal, name === 'guest.raw' ? MAX_DISK : MAX_SMALL) !== base[key]) fail('UPDATE_BUILD_TEMPLATE_INVALID');
    owned = await mkdtemp(path.join(parent, '.runtime-build-')); await chmod(owned, 0o700);
    await writeFile(path.join(owned, '.owner.json'), JSON.stringify({ schema: 'runtime-build-scratch/v1', parentPID: process.pid }), { mode: 0o600, flag: 'wx' });
    const payload = path.join(owned, 'payload'), contents = path.join(payload, 'Contents'); await mkdir(contents, { recursive: true, mode: 0o700 });
    emit({ type: 'progress', phase: 'clone', fraction: 0.12 });
    for (const file of files) {
      check(signal); const target = path.join(contents, file.relative); await mkdir(path.dirname(target), { recursive: true, mode: 0o700 });
      if (file.relative === DISK) await cloneDisk(path.join(template, file.relative), target, signal);
      else await copyFile(path.join(template, file.relative), target, constants.COPYFILE_EXCL);
      await chmod(target, file.relative === DISK ? 0o600 : file.executable ? 0o500 : 0o400);
    }
    const old = { sdkVersion: base.sdk_version, cliVersion: base.cli_version, cliSHA256: base.linux_cli_sha256 };
    const next = { sdkVersion: release.sdkVersion, cliVersion: release.cliVersion, cliSHA256: receipt.cliSHA256 };
    for (const [relative, kind] of [[`${RUNTIME}/guest/text-runtime/runtime.mjs`, 'guest'], [`${RUNTIME}/host/text-runtime/common.py`, 'common'], [`${RUNTIME}/sdk/deepseek-text-chat.mjs`, 'chat'], [`${RUNTIME}/sdk/deepseek-text-smoke.mjs`, 'smoke']]) {
      const filename = path.join(contents, relative), source = await readFile(filename, 'utf8'); await chmod(filename, 0o600);
      await writeFile(filename, rewriteTemplatePins(source, kind, old, next)); await chmod(filename, 0o400);
    }
    const sdkPath = path.join(contents, RUNTIME, 'sdk/package.json'), sdk = await smallJSON(sdkPath, 'UPDATE_BUILD_TEMPLATE_INVALID');
    if (sdk.dependencies?.['@anthropic-ai/claude-agent-sdk'] !== old.sdkVersion) fail('UPDATE_BUILD_TEMPLATE_INVALID');
    sdk.dependencies['@anthropic-ai/claude-agent-sdk'] = next.sdkVersion; await chmod(sdkPath, 0o600); await writeFile(sdkPath, JSON.stringify(sdk, null, 2) + '\n'); await chmod(sdkPath, 0o400);
    const configuration = await smallJSON(path.join(contents, RUNTIME, 'host/text-runtime/runtime-config.json'), 'UPDATE_BUILD_TEMPLATE_INVALID');
    if (!exact(configuration, ['schema', 'image_dir', 'runner', 'guest_runtime_dir', 'python']) || configuration.schema !== 'claude-vm-runtime/v1' || configuration.image_dir !== 'images' || configuration.runner !== '../../../../Helpers/vm-text-runtime' || configuration.guest_runtime_dir !== '../../guest/text-runtime' || configuration.python !== '/usr/bin/python3') fail('UPDATE_BUILD_TEMPLATE_INVALID');
    const preparation = await (options.prepare ?? prepareVM)({ schema: 'official-runtime-prepare/v1', imageDirectory: path.join(contents, IMAGES), runner: path.join(contents, 'Helpers/vm-text-runtime'), artifactDirectory: artifacts, scratchRoot: owned,
      sdkVersion: next.sdkVersion, cliVersion: next.cliVersion, cliSHA256: next.cliSHA256, cliBytes: receipt.cliBytes,
      nodeVersion: base.node_version, nodeMinimum: release.nodeMinimum, sdkUnpackedBytes: release.artifacts.sdk.unpackedSize, nativeUnpackedBytes: release.artifacts.nativeCLI.unpackedSize,
      sdkArchiveSHA256: receipt.sdkArchiveSHA256, nativeArchiveSHA256: receipt.nativeArchiveSHA256 }, emit, signal);
    check(signal); emit({ type: 'progress', phase: 'hash', fraction: 0.86 });
    const digests = { linuxCLI: next.cliSHA256, disk: await fileDigest(path.join(contents, DISK), signal, MAX_DISK), kernel: base.kernel_sha256, initrd: base.initrd_sha256 };
    const baseMetadata = { ...base, sdk_version: next.sdkVersion, cli_version: next.cliVersion, linux_cli_sha256: next.cliSHA256, cli_sha256: next.cliSHA256, disk_sha256: digests.disk,
      preparation_seconds: preparation.preparationSeconds, prepared: true, no_user_data: true, network_devices: 0, directory_shares: 0, socket_devices: 0 };
    const baseFile = path.join(contents, IMAGES, 'base.json'); await chmod(baseFile, 0o600); await writeFile(baseFile, JSON.stringify(baseMetadata, null, 2) + '\n'); await chmod(baseFile, 0o400); await chmod(path.join(contents, DISK), 0o400);
    const recipe = createHash('sha256'); for (const filename of [MODULE, PYTHON]) { const bytes = await readFile(filename); recipe.update(String(bytes.length) + '\n'); recipe.update(bytes); }
    check(signal); await rename(payload, candidate); published = true;
    const result = { schema: 'official-runtime-build-result/v1', contentsRoot: path.join(candidate, 'Contents'), versions: { sdkVersion: next.sdkVersion, cliVersion: next.cliVersion, nodeVersion: base.node_version },
      digests, baseMetadata, provenance: { release, receipt, builderRecipeSHA256: recipe.digest('hex') } };
    emit({ type: 'progress', phase: 'built', fraction: 1 }); return { type: 'built', result };
  } catch (error) {
    if (published) await rm(request.candidateDirectory, { recursive: true, force: true });
    if (signal?.aborted) throw new LocalBuildFailure('UPDATE_CANCELLED');
    if (error instanceof LocalBuildFailure) throw error;
    throw new LocalBuildFailure('UPDATE_BUILD_FAILED');
  } finally { if (owned) await rm(owned, { recursive: true, force: true }); }
}

export async function runLocalBuildStdio() {
  const abort = new AbortController(), emit = value => process.stdout.write(JSON.stringify(value) + '\n');
  const parent = process.ppid, watchdog = setInterval(() => { if (process.ppid !== parent) { abort.abort(); process.stdin.destroy(); } }, 250);
  const interrupt = () => abort.abort(); process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
  const timer = setTimeout(() => { abort.abort(); process.stdin.destroy(); }, 10_000);
  let terminal;
  try {
    const chunks = []; let size = 0;
    for await (const chunk of process.stdin) { check(abort.signal); size += chunk.length; if (size > 64 * 1024) fail('UPDATE_BUILD_INVALID_REQUEST'); chunks.push(chunk); }
    clearTimeout(timer); check(abort.signal);
    let request; try { request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); } catch { fail('UPDATE_BUILD_INVALID_REQUEST'); }
    terminal = await runLocalBuild(request, emit, { signal: abort.signal });
  } catch (error) { terminal = { type: 'error', code: error instanceof LocalBuildFailure ? error.code : 'UPDATE_BUILD_FAILED' }; }
  finally { clearTimeout(timer); clearInterval(watchdog); process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt); }
  emit(terminal); return terminal;
}
if (process.argv[1] && path.resolve(process.argv[1]) === MODULE) {
  if (process.argv.length !== 2) { process.stdout.write(JSON.stringify({ type: 'error', code: 'UPDATE_BUILD_INVALID_REQUEST' }) + '\n'); process.exitCode = 2; }
  else { const terminal = await runLocalBuildStdio(); process.exitCode = terminal.type === 'built' ? 0 : 2; }
}
