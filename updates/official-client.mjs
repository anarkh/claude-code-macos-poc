// Official paired SDK/CLI updater. Every remote byte uses the App's numeric
// loopback CONNECT transport; no host npm install, CLI launch or DNS fallback.
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, rmdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { proxyHttpsRequest, validateNetworkPolicy, ProxyTransportError } from '../network/proxy-transport.mjs';
import { verifyOfficialManifest, inspectNativeArchive, OfficialIntegrityError, OFFICIAL_KEY_FINGERPRINT, OFFICIAL_KEY_SHA256 } from './official-integrity.mjs';

export const OFFICIAL_REQUEST_SCHEMA = 'official-runtime-request/v1';
export const OFFICIAL_RELEASE_SCHEMA = 'official-paired-release/v1';
export const OFFICIAL_RECEIPT_SCHEMA = 'official-runtime-receipt/v1';
export const MAX_OFFICIAL_INPUT_BYTES = 65536;
export const MAX_OFFICIAL_ARCHIVE_BYTES = 160 * 1024 ** 2;
export const OFFICIAL_ERROR_CODES = Object.freeze([
  'OFFICIAL_INVALID_REQUEST', 'OFFICIAL_NETWORK_POLICY_INVALID', 'OFFICIAL_NETWORK_FAILED',
  'OFFICIAL_REDIRECT_REFUSED', 'OFFICIAL_HTTP_FAILED', 'OFFICIAL_METADATA_TOO_LARGE',
  'OFFICIAL_METADATA_INVALID', 'OFFICIAL_SIGNATURE_INVALID', 'OFFICIAL_MANIFEST_INVALID',
  'OFFICIAL_INCOMPATIBLE_RELEASE', 'OFFICIAL_RELEASE_CHANGED', 'OFFICIAL_STAGING_INVALID',
  'OFFICIAL_DOWNLOAD_SIZE', 'OFFICIAL_DOWNLOAD_HASH', 'OFFICIAL_ARTIFACT_INVALID',
  'OFFICIAL_SAVE_FAILED', 'OFFICIAL_CLEANUP_FAILED', 'OFFICIAL_CANCELLED',
  'OFFICIAL_INPUT_TIMEOUT', 'OFFICIAL_INPUT_TOO_LARGE',
]);
export class OfficialFailure extends Error {
  constructor(code) { super(OFFICIAL_ERROR_CODES.includes(code) ? code : 'OFFICIAL_NETWORK_FAILED'); this.name = 'OfficialFailure'; this.code = this.message; }
}
const fail = code => { throw new OfficialFailure(code); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exact = (value, keys) => object(value) && Object.keys(value).length === keys.length && Object.keys(value).every(key => keys.includes(key));
const version = value => typeof value === 'string' && /^\d{1,9}\.\d{1,9}\.\d{1,9}$/.test(value);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const SDK = '@anthropic-ai/claude-agent-sdk', NATIVE = SDK + '-linux-arm64';
const registry = (name, ver) => `https://registry.npmjs.org/${name}/${ver}`;
const tarball = (name, ver) => `https://registry.npmjs.org/${name}/-/${name.slice(name.indexOf('/') + 1)}-${ver}.tgz`;
const manifestURL = ver => `https://downloads.claude.ai/claude-code-releases/${ver}/manifest.json`;
const stableURL = 'https://downloads.claude.ai/claude-code-releases/stable';
const FILES = ['root-sdk.tgz', 'native-cli.tgz', 'sdk-metadata.json', 'native-metadata.json', 'cli-manifest.json', 'cli-manifest.sig', 'receipt.json'];
const cancelled = signal => { if (signal?.aborted) fail('OFFICIAL_CANCELLED'); };
export function sanitizeOfficialError(error, signal) {
  if (signal?.aborted || error?.code === 'NETWORK_CANCELLED' || error?.code === 'OFFICIAL_CANCELLED') return new OfficialFailure('OFFICIAL_CANCELLED');
  if (error instanceof OfficialFailure) return error;
  if (error instanceof OfficialIntegrityError) return new OfficialFailure(error.code);
  if (error instanceof ProxyTransportError) return new OfficialFailure(['NETWORK_POLICY_REQUIRED', 'NETWORK_POLICY_INVALID'].includes(error.code) ? 'OFFICIAL_NETWORK_POLICY_INVALID' : 'OFFICIAL_NETWORK_FAILED');
  return new OfficialFailure('OFFICIAL_NETWORK_FAILED');
}
function parse(bytes) { try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail('OFFICIAL_METADATA_INVALID'); } }
function declaredLength(response) {
  const value = response.headers['content-length'];
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || !/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) fail('OFFICIAL_DOWNLOAD_SIZE');
  return Number(value);
}
function responseOK(response) {
  if (response.statusCode >= 300 && response.statusCode < 400) fail('OFFICIAL_REDIRECT_REFUSED');
  if (response.statusCode !== 200) fail('OFFICIAL_HTTP_FAILED');
  if (response.headers['content-encoding'] !== undefined && response.headers['content-encoding'] !== 'identity') fail('OFFICIAL_ARTIFACT_INVALID');
}
async function bytesFrom(url, context, maximum = 65536) {
  const response = await proxyHttpsRequest({ url, method: 'GET', network: context.network, signal: context.signal,
    headers: { accept: 'application/json, application/octet-stream', 'accept-encoding': 'identity' }, timeoutMs: 30000 }, context.transportDependencies);
  try {
    responseOK(response); const declared = declaredLength(response);
    if (declared !== undefined && declared > maximum) fail('OFFICIAL_METADATA_TOO_LARGE');
    const chunks = []; let size = 0;
    for await (const chunk of response.stream) { cancelled(context.signal); size += chunk.length; if (size > maximum) fail('OFFICIAL_METADATA_TOO_LARGE'); chunks.push(chunk); }
    if (declared !== undefined && size !== declared) fail('OFFICIAL_METADATA_INVALID');
    return Buffer.concat(chunks, size);
  } finally { response.stream.destroy(); }
}
function metadata(raw, name, requestedVersion) {
  const value = parse(raw);
  if (!object(value) || value.name !== name || !version(value.version) || (requestedVersion && value.version !== requestedVersion) ||
      !object(value.dist) || value.dist.tarball !== tarball(name, value.version) ||
      typeof value.dist.integrity !== 'string' || !/^sha512-[A-Za-z0-9+/]{86}==$/.test(value.dist.integrity) ||
      Buffer.from(value.dist.integrity.slice(7), 'base64').toString('base64') !== value.dist.integrity.slice(7) ||
      !Number.isSafeInteger(value.dist.unpackedSize) || value.dist.unpackedSize < 1 ||
      value.dist.unpackedSize > (name === SDK ? 16 : 320) * 1024 ** 2) fail('OFFICIAL_METADATA_INVALID');
  if (name === NATIVE && (!Array.isArray(value.os) || value.os.length !== 1 || value.os[0] !== 'linux' ||
      !Array.isArray(value.cpu) || value.cpu.length !== 1 || value.cpu[0] !== 'arm64' || value.dist.fileCount !== 4)) fail('OFFICIAL_INCOMPATIBLE_RELEASE');
  return value;
}
function artifact(value) { return { name: value.name, version: value.version, integrity: value.dist.integrity, unpackedSize: value.dist.unpackedSize }; }
async function paired(sdkVersion, context, informational = {}) {
  const sdkRaw = await bytesFrom(registry(SDK, sdkVersion), context), sdk = metadata(sdkRaw, SDK, sdkVersion);
  if (!version(sdk.claudeCodeVersion) || sdk.optionalDependencies?.[NATIVE] !== sdk.version ||
      (sdk.dependencies !== undefined && (!object(sdk.dependencies) || Object.keys(sdk.dependencies).length !== 0))) fail('OFFICIAL_INCOMPATIBLE_RELEASE');
  const engine = sdk.engines?.node;
  if (typeof engine !== 'string' || !/^>=\d{1,9}\.\d{1,9}\.\d{1,9}$/.test(engine)) fail('OFFICIAL_INCOMPATIBLE_RELEASE');
  const nativeRaw = await bytesFrom(registry(NATIVE, sdk.version), context), native = metadata(nativeRaw, NATIVE, sdk.version);
  const manifestRaw = await bytesFrom(manifestURL(sdk.claudeCodeVersion), context), signatureRaw = await bytesFrom(manifestURL(sdk.claudeCodeVersion) + '.sig', context, 4096);
  const verified = verifyOfficialManifest(manifestRaw, signatureRaw);
  if (verified.manifest.version !== sdk.claudeCodeVersion || native.dist.unpackedSize < verified.platform.size ||
      native.dist.unpackedSize > verified.platform.size + 65536) fail('OFFICIAL_INCOMPATIBLE_RELEASE');
  return { sdk, native, sdkRaw, nativeRaw, manifestRaw, signatureRaw,
    release: { schema: OFFICIAL_RELEASE_SCHEMA, sdkVersion: sdk.version, cliVersion: sdk.claudeCodeVersion,
      nodeMinimum: engine.slice(2), officialStableCLI: informational.officialStableCLI ?? null,
      stableChannelStatus: informational.stableChannelStatus ?? 'unavailable',
      artifacts: { sdk: artifact(sdk), nativeCLI: artifact(native), cli: { platform: 'linux-arm64', size: verified.platform.size, sha256: verified.platform.sha256 } },
      metadataSHA256: { sdk: sha(sdkRaw), nativeCLI: sha(nativeRaw), manifest: verified.manifestSHA256 }, signingKeyFingerprint: OFFICIAL_KEY_FINGERPRINT } };
}
function validateRelease(value) {
  if (!exact(value, ['schema', 'sdkVersion', 'cliVersion', 'nodeMinimum', 'officialStableCLI', 'stableChannelStatus', 'artifacts', 'metadataSHA256', 'signingKeyFingerprint']) ||
      value.schema !== OFFICIAL_RELEASE_SCHEMA || !['sdkVersion', 'cliVersion', 'nodeMinimum'].every(key => version(value[key])) ||
      !(value.officialStableCLI === null || version(value.officialStableCLI)) || !['verified', 'unavailable'].includes(value.stableChannelStatus) ||
      (value.stableChannelStatus === 'verified') !== (value.officialStableCLI !== null) || value.signingKeyFingerprint !== OFFICIAL_KEY_FINGERPRINT ||
      !exact(value.artifacts, ['sdk', 'nativeCLI', 'cli']) || !exact(value.metadataSHA256, ['sdk', 'nativeCLI', 'manifest']) ||
      Object.values(value.metadataSHA256).some(item => typeof item !== 'string' || !/^[a-f0-9]{64}$/.test(item))) fail('OFFICIAL_INVALID_REQUEST');
  for (const [key, name] of [['sdk', SDK], ['nativeCLI', NATIVE]]) {
    const item = value.artifacts[key];
    if (!exact(item, ['name', 'version', 'integrity', 'unpackedSize']) || item.name !== name || item.version !== value.sdkVersion ||
        typeof item.integrity !== 'string' || !/^sha512-[A-Za-z0-9+/]{86}==$/.test(item.integrity) ||
        !Number.isSafeInteger(item.unpackedSize) || item.unpackedSize < 1 || item.unpackedSize > 320 * 1024 ** 2) fail('OFFICIAL_INVALID_REQUEST');
  }
  const cli = value.artifacts.cli;
  if (!exact(cli, ['platform', 'size', 'sha256']) || cli.platform !== 'linux-arm64' || !Number.isSafeInteger(cli.size) || cli.size < 1 || cli.size > 320 * 1024 ** 2 ||
      typeof cli.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(cli.sha256)) fail('OFFICIAL_INVALID_REQUEST');
}
const canonical = value => JSON.stringify(value, (_key, item) => object(item) ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
function samePair(a, b) { return a.sdkVersion === b.sdkVersion && a.cliVersion === b.cliVersion && a.nodeMinimum === b.nodeMinimum &&
  canonical(a.artifacts) === canonical(b.artifacts) && canonical(a.metadataSHA256) === canonical(b.metadataSHA256); }
async function physical(directory) {
  for (let current = directory;; current = path.dirname(current)) {
    let stat; try { stat = await lstat(current); } catch { fail('OFFICIAL_STAGING_INVALID'); }
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail('OFFICIAL_STAGING_INVALID');
    if (current === directory && (stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o700)) fail('OFFICIAL_STAGING_INVALID');
    if (current === '/') return;
  }
}
async function staging(directory) {
  if (typeof directory !== 'string' || directory.length > 4096 || !path.isAbsolute(directory) || path.normalize(directory) !== directory || /[\x00-\x1f\x7f]/.test(directory) || path.dirname(directory) === directory) fail('OFFICIAL_STAGING_INVALID');
  await physical(path.dirname(directory));
  try { await lstat(directory); fail('OFFICIAL_STAGING_INVALID'); } catch (error) { if (error.code !== 'ENOENT') throw sanitizeOfficialError(error); }
}
async function writeAll(handle, chunk) { let offset = 0; while (offset < chunk.length) { const result = await handle.write(chunk, offset, chunk.length - offset); if (!result.bytesWritten) fail('OFFICIAL_SAVE_FAILED'); offset += result.bytesWritten; } }
async function file(directory, name, body) {
  let handle;
  try { handle = await open(path.join(directory, name), constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600); await writeAll(handle, body); await handle.sync(); }
  catch { fail('OFFICIAL_SAVE_FAILED'); }
  finally { if (handle) await handle.close(); }
}
async function archive(url, name, integrity, directory, context, budget, report) {
  const response = await proxyHttpsRequest({ url, method: 'GET', network: context.network, signal: context.signal,
    timeoutMs: 300000, headers: { accept: 'application/octet-stream', 'accept-encoding': 'identity' } }, context.transportDependencies);
  let handle;
  try {
    responseOK(response); const declared = declaredLength(response), maximum = name === 'root-sdk.tgz' ? 16 * 1024 ** 2 : MAX_OFFICIAL_ARCHIVE_BYTES;
    if (declared !== undefined && (declared < 1 || declared > maximum || budget.bytes + declared > MAX_OFFICIAL_ARCHIVE_BYTES)) fail('OFFICIAL_DOWNLOAD_SIZE');
    handle = await open(path.join(directory, name), constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
    const sha256 = createHash('sha256'), sha512 = createHash('sha512'); let size = 0;
    for await (const chunk of response.stream) { cancelled(context.signal); size += chunk.length; budget.bytes += chunk.length;
      if (size > maximum || budget.bytes > MAX_OFFICIAL_ARCHIVE_BYTES) fail('OFFICIAL_DOWNLOAD_SIZE');
      await writeAll(handle, chunk); sha256.update(chunk); sha512.update(chunk); report(0.1 + 0.75 * budget.bytes / MAX_OFFICIAL_ARCHIVE_BYTES, 'download'); }
    if (size < 1 || (declared !== undefined && size !== declared)) fail('OFFICIAL_DOWNLOAD_SIZE');
    if ('sha512-' + sha512.digest('base64') !== integrity) fail('OFFICIAL_DOWNLOAD_HASH');
    await handle.sync(); return { sha256: sha256.digest('hex'), bytes: size };
  } catch (error) { if (error instanceof OfficialFailure || error instanceof ProxyTransportError) throw error; fail('OFFICIAL_SAVE_FAILED'); }
  finally { response.stream.destroy(); if (handle) await handle.close(); }
}
async function cleanup(directory, identity) {
  const current = await lstat(directory);
  if (!current.isDirectory() || current.isSymbolicLink() || current.dev !== identity.dev || current.ino !== identity.ino) fail('OFFICIAL_CLEANUP_FAILED');
  for (const name of FILES) { try { await unlink(path.join(directory, name)); } catch (error) { if (error.code !== 'ENOENT') fail('OFFICIAL_CLEANUP_FAILED'); } }
  try { await rmdir(directory); } catch { fail('OFFICIAL_CLEANUP_FAILED'); }
}
function optionsChecked(options) {
  if (!object(options) || Object.keys(options).some(key => !['signal', 'testOnly', 'transportDependencies'].includes(key)) ||
      (options.signal !== undefined && !(options.signal instanceof AbortSignal)) || (options.testOnly !== undefined && options.testOnly !== true) ||
      (options.transportDependencies !== undefined && options.testOnly !== true)) fail('OFFICIAL_INVALID_REQUEST');
  if (options.transportDependencies !== undefined && (!object(options.transportDependencies) || options.transportDependencies.testOnly !== true ||
      Object.keys(options.transportDependencies).some(key => !['testOnly', 'ca', 'timeoutMs'].includes(key)))) fail('OFFICIAL_INVALID_REQUEST');
}
export async function runOfficialRequest(request, emit = () => {}, options = {}) {
  let context, owned;
  try {
    optionsChecked(options); if (typeof emit !== 'function') fail('OFFICIAL_INVALID_REQUEST');
    cancelled(options.signal);
    const keys = request?.operation === 'check' ? ['schema', 'operation', 'network', 'currentCLI', 'currentSDK'] : ['schema', 'operation', 'network', 'release', 'artifactDirectory'];
    if (!exact(request, keys) || request.schema !== OFFICIAL_REQUEST_SCHEMA || !['check', 'download'].includes(request.operation)) fail('OFFICIAL_INVALID_REQUEST');
    context = { network: validateNetworkPolicy(request.network), signal: options.signal, transportDependencies: options.transportDependencies };
    let lastTime = -Infinity, lastFraction = -1;
    const report = (fraction, phase, force = false) => { const now = performance.now(); if (force || (fraction > lastFraction && now - lastTime >= 250)) {
      lastFraction = fraction; lastTime = now; emit({ type: 'progress', fraction, phase }); } };
    if (request.operation === 'check') {
      if (![request.currentCLI, request.currentSDK].every(value => value === null || version(value))) fail('OFFICIAL_INVALID_REQUEST');
      report(0, 'metadata', true);
      const latestRaw = await bytesFrom(registry(SDK, 'latest'), context), latest = metadata(latestRaw, SDK);
      const data = await paired(latest.version, context);
      try { const stableBytes = await bytesFrom(stableURL, context, 64); const stable = new TextDecoder('utf-8', { fatal: true }).decode(stableBytes).trim(); if (!version(stable)) fail('OFFICIAL_METADATA_INVALID');
        data.release.officialStableCLI = stable; data.release.stableChannelStatus = 'verified';
      } catch (error) { if (context.signal?.aborted || error?.code === 'NETWORK_CANCELLED') throw error; /* Informational channel explicitly remains unavailable. */ }
      cancelled(context.signal); report(1, 'metadata', true);
      const newer = (a, b) => { if (b === null) return true; const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < 3; i++) { if (x[i] !== y[i]) return x[i] > y[i]; } return false; };
      return { type: 'checked', release: data.release, updateAvailable: newer(data.release.sdkVersion, request.currentSDK) || newer(data.release.cliVersion, request.currentCLI) };
    }
    validateRelease(request.release); await staging(request.artifactDirectory); cancelled(context.signal); report(0, 'metadata', true);
    const data = await paired(request.release.sdkVersion, context, request.release);
    if (!samePair(data.release, request.release)) fail('OFFICIAL_RELEASE_CHANGED');
    cancelled(context.signal);
    try { await mkdir(request.artifactDirectory, { mode: 0o700 }); owned = await lstat(request.artifactDirectory); } catch { fail('OFFICIAL_SAVE_FAILED'); }
    for (const [name, bytes] of [['sdk-metadata.json', data.sdkRaw], ['native-metadata.json', data.nativeRaw], ['cli-manifest.json', data.manifestRaw], ['cli-manifest.sig', data.signatureRaw]]) await file(request.artifactDirectory, name, bytes);
    report(0.1, 'download', true); const budget = { bytes: 0 };
    const sdkArchive = await archive(tarball(SDK, data.sdk.version), 'root-sdk.tgz', data.sdk.dist.integrity, request.artifactDirectory, context, budget, report);
    const nativeArchive = await archive(tarball(NATIVE, data.native.version), 'native-cli.tgz', data.native.dist.integrity, request.artifactDirectory, context, budget, report);
    cancelled(context.signal); report(0.9, 'verify', true);
    const inspection = await inspectNativeArchive(path.join(request.artifactDirectory, 'native-cli.tgz'), { version: data.sdk.version,
      cliSHA256: data.release.artifacts.cli.sha256, cliBytes: data.release.artifacts.cli.size, signal: context.signal });
    const receipt = { schema: OFFICIAL_RECEIPT_SCHEMA, sdkVersion: data.sdk.version, cliVersion: data.sdk.claudeCodeVersion, nodeMinimum: data.release.nodeMinimum,
      sdkArchiveSHA256: sdkArchive.sha256, nativeArchiveSHA256: nativeArchive.sha256, cliSHA256: inspection.cliSHA256,
      cliManifestSHA256: data.release.metadataSHA256.manifest, cliSigningKeySHA256: OFFICIAL_KEY_SHA256, cliSigningKeyFingerprint: OFFICIAL_KEY_FINGERPRINT,
      sdkMetadataSHA256: sha(data.sdkRaw), nativeMetadataSHA256: sha(data.nativeRaw), sdkIntegrity: data.sdk.dist.integrity, nativeIntegrity: data.native.dist.integrity,
      cliBytes: inspection.cliBytes, sdkArchiveBytes: sdkArchive.bytes, nativeArchiveBytes: nativeArchive.bytes,
      installationScriptsExecuted: false, cliExecuted: false, binaryMatchesSignedManifest: true, provenance: 'official-npm-and-anthropic-signature' };
    await file(request.artifactDirectory, 'receipt.json', Buffer.from(JSON.stringify(receipt, null, 2) + '\n'));
    cancelled(context.signal); report(1, 'verify', true); return { type: 'downloaded', receipt };
  } catch (error) {
    const failure = sanitizeOfficialError(error, options?.signal);
    if (owned) { try { await cleanup(request.artifactDirectory, owned); } catch { throw new OfficialFailure('OFFICIAL_CLEANUP_FAILED'); } }
    throw failure;
  }
}
