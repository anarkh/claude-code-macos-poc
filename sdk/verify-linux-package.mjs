// Verify the exact public native package before extracting fixed entries.
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { writeFile, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const url = 'https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk-linux-arm64/0.3.295';
const response = await fetch(url, { signal: AbortSignal.timeout(15_000) });
if (!response.ok) throw new Error(`registry HTTP ${response.status}`);
const meta = await response.json();
const file = path.join(root, 'downloads/anthropic-ai-claude-agent-sdk-linux-arm64-0.3.295.tgz');
const sha512 = createHash('sha512'), sha256 = createHash('sha256');
for await (const chunk of createReadStream(file)) { sha512.update(chunk); sha256.update(chunk); }
const actual = `sha512-${sha512.digest('base64')}`;
if (actual !== meta.dist.integrity) throw new Error('Official npm SHA512 integrity mismatch; refusing extraction');
const darwinCli = path.join(root, 'node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude');
const darwin = createHash('sha256').update(await readFile(darwinCli)).digest('hex');
const evidence = { checked_at: new Date().toISOString(), registry_url: url, package: meta.name, version: meta.version, tarball: meta.dist.tarball, official_integrity: meta.dist.integrity, actual_integrity: actual, integrity_equal: true, tarball_sha256: sha256.digest('hex'), darwin_cli_sha256_before_extract: darwin, extraction_allowlist: ['package/claude', 'package/package.json', 'package/LICENSE.md', 'package/README.md'] };
await writeFile(path.join(root, 'evidence/linux-package-integrity.json'), JSON.stringify(evidence, null, 2));
console.log(JSON.stringify(evidence, null, 2));
