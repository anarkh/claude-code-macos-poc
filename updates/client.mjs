// Trusted App updater. Payload locations are derived from signed paths; all
// remote bytes use the App's CONNECT transport with strict TLS and proxy DNS.
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open } from 'node:fs/promises';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { ProxyTransportError, proxyHttpsRequest, validateNetworkPolicy } from '../network/proxy-transport.mjs';

export const REQUEST_SCHEMA = 'runtime-update-request/v1';
export const CHANNEL_SCHEMA = 'claude-runtime-channel/v1';
export const MAX_METADATA_BYTES = 3 * 1024 * 1024;
export const UPDATE_ERROR_CODES = Object.freeze([
  'UPDATE_INVALID_REQUEST', 'UPDATE_INVALID_FEED', 'UPDATE_NETWORK_POLICY_INVALID',
  'UPDATE_NETWORK_FAILED', 'UPDATE_REDIRECT_REFUSED', 'UPDATE_HTTP_FAILED',
  'UPDATE_METADATA_TOO_LARGE', 'UPDATE_METADATA_INVALID', 'UPDATE_PACKAGE_INVALID',
  'UPDATE_STAGING_INVALID', 'UPDATE_DOWNLOAD_SIZE', 'UPDATE_DOWNLOAD_HASH',
  'UPDATE_DOWNLOAD_INVALID', 'UPDATE_SAVE_FAILED', 'UPDATE_CANCELLED',
  'UPDATE_INPUT_TIMEOUT', 'UPDATE_INPUT_TOO_LARGE', 'UPDATE_HEALTH_FAILED',
]);
const CODES = new Set(UPDATE_ERROR_CODES);
export class UpdateFailure extends Error {
  constructor(code) {
    super(CODES.has(code) ? code : 'UPDATE_NETWORK_FAILED');
    this.name = 'UpdateFailure';
    this.code = this.message;
  }
}
const fail = code => { throw new UpdateFailure(code); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exact = (value, keys) => object(value) && Object.keys(value).length === keys.length &&
  Object.keys(value).every(key => keys.includes(key));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const isDigest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const isVersion = value => typeof value === 'string' && value.length <= 64 && /^\d{1,9}\.\d{1,9}\.\d{1,9}$/.test(value);
const DISK = 'Resources/Runtime/host/text-runtime/images/guest.raw';
function checkCancelled(signal) { if (signal?.aborted) fail('UPDATE_CANCELLED'); }

export function sanitizeUpdateError(error, signal) {
  if (signal?.aborted || error?.code === 'NETWORK_CANCELLED') return new UpdateFailure('UPDATE_CANCELLED');
  if (error instanceof UpdateFailure) return error;
  if (error instanceof ProxyTransportError) return new UpdateFailure(
    ['NETWORK_POLICY_REQUIRED', 'NETWORK_POLICY_INVALID'].includes(error.code)
      ? 'UPDATE_NETWORK_POLICY_INVALID' : 'UPDATE_NETWORK_FAILED');
  return new UpdateFailure('UPDATE_NETWORK_FAILED');
}

export function validateFeedURL(value) {
  if (typeof value !== 'string' || value.length > 4096 || /[\s\\\x00-\x1f\x7f]/.test(value)) fail('UPDATE_INVALID_FEED');
  let url;
  try { url = new URL(value); } catch { fail('UPDATE_INVALID_FEED'); }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.search || url.hash ||
      !url.pathname.endsWith('/channel.json')) fail('UPDATE_INVALID_FEED');
  const rawPath = value.slice(value.indexOf('://') + 3).replace(/^[^/]+/, '');
  if (!rawPath.startsWith('/') || rawPath !== url.pathname) fail('UPDATE_INVALID_FEED');
  for (const segment of url.pathname.split('/').slice(1)) {
    let decoded;
    try { decoded = decodeURIComponent(segment); } catch { fail('UPDATE_INVALID_FEED'); }
    if (!decoded || decoded === '.' || decoded === '..' || /[\/\\\s\x00-\x1f\x7f]/.test(decoded)) fail('UPDATE_INVALID_FEED');
  }
  return url;
}

function decodeBase64(value, maximum, code) {
  if (typeof value !== 'string' || value.length > Math.ceil(maximum / 3) * 4 || value.length % 4 !== 0 ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) fail(code);
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length === 0 || bytes.length > maximum || bytes.toString('base64') !== value) fail(code);
  return bytes;
}
function json(bytes, code) {
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { fail(code); }
}
function payloadPath(value) {
  return typeof value === 'string' && Buffer.byteLength(value) <= 512 && /^[\x21-\x7e]+$/.test(value) &&
    !/[\\:%]/.test(value) && /^(Resources\/Runtime|Helpers)\//.test(value) &&
    value.split('/').every(segment => segment && segment !== '.' && segment !== '..' && segment.length <= 128);
}

function decodePackage(manifestBase64, signatureBase64) {
  const manifestBytes = decodeBase64(manifestBase64, 2 * 1024 * 1024, 'UPDATE_PACKAGE_INVALID');
  const signatureBytes = decodeBase64(signatureBase64, 4096, 'UPDATE_PACKAGE_INVALID');
  const manifest = json(manifestBytes, 'UPDATE_PACKAGE_INVALID');
  const signature = json(signatureBytes, 'UPDATE_PACKAGE_INVALID');
  if (!exact(signature, ['schema', 'keyID', 'signature']) || signature.schema !== 'claude-runtime-signature/v1' ||
      !isDigest(signature.keyID) || decodeBase64(signature.signature, 64, 'UPDATE_PACKAGE_INVALID').length !== 64 ||
      !exact(manifest, ['schema', 'version', 'cliVersion', 'sdkVersion', 'nodeVersion', 'hostProtocol', 'platform',
        'minimumOSVersion', 'minimumAppVersion', 'maximumAppVersionExclusive', 'files']) ||
      manifest.schema !== 'claude-runtime-package/v1' || manifest.hostProtocol !== 1 || manifest.platform !== 'macOS-arm64' ||
      !['version', 'cliVersion', 'sdkVersion', 'nodeVersion', 'minimumOSVersion', 'minimumAppVersion',
        'maximumAppVersionExclusive'].every(key => isVersion(manifest[key])) ||
      !Array.isArray(manifest.files) || manifest.files.length === 0 || manifest.files.length > 4096) fail('UPDATE_PACKAGE_INVALID');
  const versions = value => value.split('.').map(Number);
  const minimum = versions(manifest.minimumAppVersion), maximum = versions(manifest.maximumAppVersionExclusive);
  const differing = minimum.findIndex((value, index) => value !== maximum[index]);
  if (differing < 0 || minimum[differing] >= maximum[differing]) fail('UPDATE_PACKAGE_INVALID');
  const files = new Map(), folded = new Map(), directories = new Set(['Resources', 'Resources/Runtime', 'Helpers']);
  let total = 0;
  for (const file of manifest.files) {
    if (!exact(file, ['path', 'size', 'sha256', 'executable']) || !payloadPath(file.path) ||
        !Number.isSafeInteger(file.size) || file.size < 0 || file.size > 10 * 1024 ** 3 ||
        (file.path !== DISK && file.size > 128 * 1024 ** 2) || !isDigest(file.sha256) ||
        typeof file.executable !== 'boolean' || files.has(file.path) || folded.has(file.path.toLowerCase())) fail('UPDATE_PACKAGE_INVALID');
    files.set(file.path, file); folded.set(file.path.toLowerCase(), file.path);
    total += file.size;
    if (total > 12 * 1024 ** 3) fail('UPDATE_PACKAGE_INVALID');
    let directory = path.posix.dirname(file.path);
    while (directory !== '.') { directories.add(directory); directory = path.posix.dirname(directory); }
  }
  const foldedDirectories = new Map();
  for (const directory of directories) {
    const foldedPath = directory.toLowerCase();
    if (folded.has(foldedPath) || (foldedDirectories.has(foldedPath) && foldedDirectories.get(foldedPath) !== directory)) fail('UPDATE_PACKAGE_INVALID');
    foldedDirectories.set(foldedPath, directory);
  }
  if (files.get('Helpers/vm-text-runtime')?.executable !== true || files.get(DISK)?.executable !== false) fail('UPDATE_PACKAGE_INVALID');
  return { manifest, manifestBytes, signatureBytes, directories, total,
    id: `runtime-${digest(manifestBytes)}` };
}

function contentLength(headers, code) {
  const value = headers['content-length'];
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || !/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) fail(code);
  return Number(value);
}
function validateResponse(response) {
  if (response.statusCode >= 300 && response.statusCode < 400) { response.stream.destroy(); fail('UPDATE_REDIRECT_REFUSED'); }
  if (response.statusCode !== 200) { response.stream.destroy(); fail('UPDATE_HTTP_FAILED'); }
  if (response.headers['content-encoding'] !== undefined && response.headers['content-encoding'] !== 'identity') {
    response.stream.destroy(); fail('UPDATE_DOWNLOAD_INVALID');
  }
}

async function validateAncestors(directory, code = 'UPDATE_STAGING_INVALID') {
  let current = directory;
  try {
    for (;;) {
      const metadata = await lstat(current);
      if (!metadata.isDirectory() || metadata.isSymbolicLink()) fail(code);
      if (current === '/') return metadata;
      current = path.dirname(current);
    }
  } catch (error) {
    if (error instanceof UpdateFailure) throw error;
    fail(code);
  }
}
async function validateStaging(value) {
  if (typeof value !== 'string' || value.length > 4096 || !path.isAbsolute(value) || path.normalize(value) !== value ||
      /[\x00-\x1f\x7f]/.test(value) || !path.basename(value).endsWith('.clauderuntime') || path.basename(value) === '.clauderuntime') fail('UPDATE_STAGING_INVALID');
  const parent = path.dirname(value);
  await validateAncestors(parent);
  let metadata;
  try { metadata = await lstat(parent); } catch { fail('UPDATE_STAGING_INVALID'); }
  if (metadata.uid !== process.getuid?.() || (metadata.mode & 0o777) !== 0o700) fail('UPDATE_STAGING_INVALID');
  try { await lstat(value); fail('UPDATE_STAGING_INVALID'); }
  catch (error) { if (error.code !== 'ENOENT') fail('UPDATE_STAGING_INVALID'); }
  return parent;
}
async function syncDirectory(directory) {
  let handle;
  try {
    handle = await open(directory, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    await handle.sync();
  } catch { fail('UPDATE_SAVE_FAILED'); }
  finally { if (handle) await handle.close().catch(() => fail('UPDATE_SAVE_FAILED')); }
}
async function createDirectory(directory) {
  await validateAncestors(path.dirname(directory));
  try { await mkdir(directory, { mode: 0o700 }); }
  catch { fail('UPDATE_SAVE_FAILED'); }
}
async function openPayload(filename) {
  await validateAncestors(path.dirname(filename));
  try { return await open(filename, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600); }
  catch { fail('UPDATE_SAVE_FAILED'); }
}
async function writeBytes(handle, bytes) {
  let offset = 0;
  try {
    while (offset < bytes.length) {
      const { bytesWritten } = await handle.write(bytes, offset, bytes.length - offset);
      if (!bytesWritten) fail('UPDATE_SAVE_FAILED');
      offset += bytesWritten;
    }
  } catch { fail('UPDATE_SAVE_FAILED'); }
}
async function finishFile(handle, executable) {
  try { await handle.chmod(executable ? 0o500 : 0o400); await handle.sync(); }
  catch { fail('UPDATE_SAVE_FAILED'); }
}
async function writeMetadata(filename, bytes) {
  const handle = await openPayload(filename);
  try { await writeBytes(handle, bytes); await finishFile(handle, false); }
  finally { await handle.close().catch(() => fail('UPDATE_SAVE_FAILED')); }
}
function progressReporter(emit, total) {
  let reported = 0, lastTime = performance.now();
  emit({ type: 'progress', fraction: 0, phase: 'download' });
  return (bytes, final = false) => {
    const fraction = final ? 1 : Math.min(0.999, bytes / Math.max(1, total));
    const now = performance.now();
    if (final || (fraction - reported >= 0.001 && now - lastTime >= 250)) {
      reported = fraction; lastTime = now; emit({ type: 'progress', fraction, phase: 'download' });
    }
  };
}

// The only injectable transport options are module-local test CA/timeout data;
// stdin cannot select them or a replacement transport/resolver.
export async function runUpdateRequest(request, emit = () => {}, options = {}) {
  let signal;
  try {
    if (!object(options) || Object.keys(options).some(key => !['signal', 'testOnly', 'transportDependencies'].includes(key)) ||
        (options.signal !== undefined && !(options.signal instanceof AbortSignal)) ||
        (options.transportDependencies !== undefined && options.testOnly !== true) ||
        (options.testOnly !== undefined && options.testOnly !== true) || typeof emit !== 'function') fail('UPDATE_INVALID_REQUEST');
    signal = options.signal;
    checkCancelled(signal);
    const keys = ['schema', 'operation', 'feedURL', 'network'];
    if (request?.operation === 'download') keys.push('manifestBase64', 'signatureBase64', 'packageDirectory');
    if (!exact(request, keys) || request.schema !== REQUEST_SCHEMA || !['check', 'download'].includes(request.operation)) fail('UPDATE_INVALID_REQUEST');
    const feed = validateFeedURL(request.feedURL);
    const network = validateNetworkPolicy(request.network);
    const transportDependencies = options.transportDependencies;
    if (request.operation === 'check') {
      const response = await proxyHttpsRequest({ url: feed.href, method: 'GET', network, signal,
        timeoutMs: 90_000, headers: { accept: 'application/json', 'accept-encoding': 'identity' } }, transportDependencies);
      let bytes;
      try {
        validateResponse(response);
        const length = contentLength(response.headers, 'UPDATE_METADATA_INVALID');
        if (length !== undefined && length > MAX_METADATA_BYTES) fail('UPDATE_METADATA_TOO_LARGE');
        const chunks = []; let size = 0;
        for await (const chunk of response.stream) {
          checkCancelled(signal); size += chunk.length;
          if (size > MAX_METADATA_BYTES) fail('UPDATE_METADATA_TOO_LARGE');
          chunks.push(chunk);
        }
        bytes = Buffer.concat(chunks, size);
        if (length !== undefined && length !== size) fail('UPDATE_METADATA_INVALID');
      } finally { response.stream.destroy(); }
      const channel = json(bytes, 'UPDATE_METADATA_INVALID');
      if (!exact(channel, ['schema', 'manifestBase64', 'signatureBase64']) || channel.schema !== CHANNEL_SCHEMA) fail('UPDATE_METADATA_INVALID');
      // Signature authority is checked by Swift before any download request.
      decodePackage(channel.manifestBase64, channel.signatureBase64);
      checkCancelled(signal);
      return { type: 'checked', channelBase64: bytes.toString('base64') };
    }
    const packageData = decodePackage(request.manifestBase64, request.signatureBase64);
    const scratch = await validateStaging(request.packageDirectory);
    checkCancelled(signal);
    const packageRoot = request.packageDirectory, contents = path.join(packageRoot, 'Contents');
    await createDirectory(packageRoot); await createDirectory(contents);
    const directories = [...packageData.directories].sort((a, b) => a.split('/').length - b.split('/').length || a.localeCompare(b));
    for (const directory of directories) { checkCancelled(signal); await createDirectory(path.join(contents, directory)); }
    await writeMetadata(path.join(packageRoot, 'manifest.json'), packageData.manifestBytes);
    await writeMetadata(path.join(packageRoot, 'signature.json'), packageData.signatureBytes);
    const base = new URL(`packages/${packageData.id}/Contents/`, new URL('.', feed));
    const report = progressReporter(emit, packageData.total);
    let completed = 0;
    for (const file of packageData.manifest.files) {
      checkCancelled(signal);
      const url = new URL(file.path.split('/').map(encodeURIComponent).join('/'), base);
      const response = await proxyHttpsRequest({ url: url.href, method: 'GET', network, signal,
        timeoutMs: 1_800_000, headers: { accept: 'application/octet-stream', 'accept-encoding': 'identity' } }, transportDependencies);
      let handle;
      try {
        validateResponse(response);
        const declared = contentLength(response.headers, 'UPDATE_DOWNLOAD_INVALID');
        if (declared !== undefined && declared !== file.size) fail('UPDATE_DOWNLOAD_SIZE');
        handle = await openPayload(path.join(contents, file.path));
        const hasher = createHash('sha256'); let size = 0;
        for await (const chunk of response.stream) {
          checkCancelled(signal); size += chunk.length;
          if (size > file.size) fail('UPDATE_DOWNLOAD_SIZE');
          await writeBytes(handle, chunk); hasher.update(chunk);
          completed += chunk.length; report(completed);
        }
        checkCancelled(signal);
        if (size !== file.size) fail('UPDATE_DOWNLOAD_SIZE');
        if (hasher.digest('hex') !== file.sha256) fail('UPDATE_DOWNLOAD_HASH');
        await finishFile(handle, file.executable);
      } finally {
        response.stream.destroy();
        if (handle) await handle.close().catch(() => fail('UPDATE_SAVE_FAILED'));
      }
    }
    // Persist child entries before their parent. Swift verifies this complete
    // package again, then owns its installation, sealing and scratch cleanup.
    for (const directory of directories.reverse()) { checkCancelled(signal); await syncDirectory(path.join(contents, directory)); }
    await syncDirectory(contents); await syncDirectory(packageRoot); await syncDirectory(scratch);
    checkCancelled(signal); report(completed, true);
    return { type: 'downloaded' };
  } catch (error) { throw sanitizeUpdateError(error, signal); }
}
