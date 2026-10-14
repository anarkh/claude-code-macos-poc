// Fixed-version public artifact preparation. Never imports SDK or executes CLI.
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { lstat, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const NAME = '@anthropic-ai/claude-agent-sdk-linux-arm64';
const VERSION = '0.3.295';
const REGISTRY = `https://registry.npmjs.org/${NAME}/${VERSION}`;
const TARBALL_URL = `https://registry.npmjs.org/${NAME}/-/claude-agent-sdk-linux-arm64-${VERSION}.tgz`;
const FILES = ['claude', 'package.json', 'LICENSE.md', 'README.md'];
const ARCHIVE_FILES = FILES.map(file => `package/${file}`);
const CACHE = path.join(ROOT, 'downloads', `anthropic-ai-claude-agent-sdk-linux-arm64-${VERSION}.tgz`);
const TARGET = path.join(ROOT, 'node_modules', '@anthropic-ai', 'claude-agent-sdk-linux-arm64');
const exec = promisify(execFile);
const signal = AbortSignal.timeout(150_000);
const receipt = { schema: 1, package: NAME, version: VERSION, registry_url: REGISTRY, checked_at: new Date().toISOString(), installation_scripts_executed: false, cli_executed: false, global_install: false };
let stage;
let partial;

async function fileStat(file) {
  try { return await lstat(file); } catch (error) { if (error.code === 'ENOENT') return undefined; throw error; }
}
async function ensureDirectory(directory) {
  const s = await fileStat(directory);
  if (s && (!s.isDirectory() || s.isSymbolicLink())) throw new Error(`Preparation path must be a real directory: ${directory}`);
  if (!s) await mkdir(directory);
}
async function digestFile(file) {
  const s = await fileStat(file);
  if (!s?.isFile() || s.isSymbolicLink()) throw new Error(`Expected a regular package file: ${file}`);
  const sha512 = createHash('sha512'), sha256 = createHash('sha256');
  for await (const chunk of createReadStream(file)) { sha512.update(chunk); sha256.update(chunk); }
  return { integrity: `sha512-${sha512.digest('base64')}`, sha256: sha256.digest('hex'), bytes: s.size };
}
async function fetchChecked(url, timeoutMs) {
  const response = await fetch(url, { signal: AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]), redirect: 'error' });
  if (!response.ok) throw new Error(`Official artifact HTTP ${response.status}: ${url}`);
  return response;
}

try {
  const metadataResponse = await fetchChecked(REGISTRY, 15_000);
  const metadataBytes = await metadataResponse.text();
  const metadata = JSON.parse(metadataBytes);
  if (metadata.name !== NAME || metadata.version !== VERSION || metadata.dist?.tarball !== TARBALL_URL || !/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(metadata.dist?.integrity ?? '') || !metadata.os?.includes('linux') || !metadata.cpu?.includes('arm64')) {
    throw new Error('Official fixed-version metadata identity, platform or SHA512 integrity is invalid');
  }
  receipt.metadata_sha256 = createHash('sha256').update(metadataBytes).digest('hex');
  receipt.official_integrity = metadata.dist.integrity;
  receipt.tarball_url = TARBALL_URL;
  await ensureDirectory(path.join(ROOT, 'downloads'));
  await ensureDirectory(path.join(ROOT, 'node_modules'));
  await ensureDirectory(path.join(ROOT, 'node_modules', '@anthropic-ai'));
  await ensureDirectory(path.join(ROOT, 'evidence'));

  const cached = await fileStat(CACHE);
  receipt.tarball_cache_reused = !!cached;
  if (!cached) {
    partial = `${CACHE}.partial-${randomUUID()}`;
    const response = await fetchChecked(TARBALL_URL, 120_000);
    const sha512 = createHash('sha512');
    const hashing = new Transform({ transform(chunk, encoding, callback) { sha512.update(chunk); callback(null, chunk); } });
    await pipeline(Readable.fromWeb(response.body), hashing, createWriteStream(partial, { flags: 'wx', mode: 0o600 }), { signal });
    if (`sha512-${sha512.digest('base64')}` !== metadata.dist.integrity) throw new Error('Downloaded package SHA512 mismatch; refusing to install');
    await rename(partial, CACHE);
    partial = undefined;
  }
  const tarballDigest = await digestFile(CACHE);
  if (tarballDigest.integrity !== metadata.dist.integrity) throw new Error('Cached package SHA512 mismatch; existing cache kept untouched, refusing extraction');
  receipt.actual_integrity = tarballDigest.integrity;
  receipt.integrity_equal = true;
  receipt.tarball_sha256 = tarballDigest.sha256;
  receipt.tarball_bytes = tarballDigest.bytes;

  const tarOptions = { timeout: 15_000, maxBuffer: 128 * 1024, env: { PATH: '/usr/bin:/bin', HOME: process.env.HOME, TMPDIR: process.env.TMPDIR } };
  const names = (await exec('/usr/bin/tar', ['-tzf', CACHE], tarOptions)).stdout.trim().split('\n');
  const verbose = (await exec('/usr/bin/tar', ['-tvzf', CACHE], tarOptions)).stdout.trim().split('\n');
  if (names.length !== FILES.length || [...names].sort().join('\n') !== [...ARCHIVE_FILES].sort().join('\n') || verbose.length !== FILES.length || verbose.some(line => !line.startsWith('-'))) {
    throw new Error('Archive must contain exactly the four approved regular files; refusing extraction');
  }
  stage = await mkdtemp(path.join(ROOT, '.prepare-linux-'));
  await exec('/usr/bin/tar', ['-xzf', CACHE, '-C', stage, '--strip-components=1', ...ARCHIVE_FILES], tarOptions);
  const packageJson = JSON.parse(await readFile(path.join(stage, 'package.json'), 'utf8'));
  if (packageJson.name !== NAME || packageJson.version !== VERSION || !packageJson.os?.includes('linux') || !packageJson.cpu?.includes('arm64')) throw new Error('Extracted native package identity mismatch');
  receipt.extraction_allowlist = ARCHIVE_FILES;
  receipt.extracted_files = {};
  for (const file of FILES) receipt.extracted_files[file] = await digestFile(path.join(stage, file));
  const existing = await fileStat(TARGET);
  receipt.installed_package_cache_reused = !!existing;
  if (existing) {
    if (!existing.isDirectory() || existing.isSymbolicLink()) throw new Error('Existing native package location is not a real directory; preserved');
    for (const file of FILES) {
      const actual = await digestFile(path.join(TARGET, file));
      if (actual.sha256 !== receipt.extracted_files[file].sha256) throw new Error(`Existing native package differs from verified archive: ${file}; existing files preserved`);
    }
  } else {
    await rename(stage, TARGET);
    stage = undefined;
  }
  receipt.target = '<SDK_DIR>/node_modules/@anthropic-ai/claude-agent-sdk-linux-arm64';
  receipt.status = 'prepared';
  await writeFile(path.join(ROOT, 'evidence/linux-native-preparation.json'), JSON.stringify(receipt, null, 2));
  console.log(JSON.stringify({ status: receipt.status, package: NAME, version: VERSION, tarball_cache_reused: receipt.tarball_cache_reused, installed_package_cache_reused: receipt.installed_package_cache_reused, integrity_equal: true, cli_sha256: receipt.extracted_files.claude.sha256, cli_bytes: receipt.extracted_files.claude.bytes, evidence: path.join(ROOT, 'evidence/linux-native-preparation.json') }));
} finally {
  if (partial) await rm(partial, { force: true });
  if (stage) await rm(stage, { recursive: true, force: true });
}
