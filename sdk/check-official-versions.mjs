// Public package/official changelog reads only. Does not import or launch Claude.
import { writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const digest = text => createHash('sha256').update(text).digest('hex');
const signal = AbortSignal.timeout(15_000);
const higher = (v, base) => {
  const a = v.split('.').map(Number), b = base.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
};
const sdkUrl = 'https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk';
const cliUrl = 'https://registry.npmjs.org/@anthropic-ai/claude-code';
const changelogUrl = 'https://raw.githubusercontent.com/anthropics/claude-agent-sdk-typescript/main/CHANGELOG.md';
async function fetchText(url) { const r = await fetch(url, { signal }); if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`); return r.text(); }
const [sdkRaw, cliRaw, log] = await Promise.all([fetchText(sdkUrl), fetchText(cliUrl), fetchText(changelogUrl)]);
const sdk = JSON.parse(sdkRaw), cli = JSON.parse(cliRaw);
const out = {
  checked_at: new Date().toISOString(),
  sdk: { url: sdkUrl, sha256: digest(sdkRaw), dist_tags: sdk['dist-tags'], stable_versions_above_baseline: Object.keys(sdk.versions).filter(v => /^\d+\.\d+\.\d+$/.test(v) && higher(v, '0.3.295')), baseline: { version: sdk.versions['0.3.295'].version, cli_version: sdk.versions['0.3.295'].claudeCodeVersion, integrity: sdk.versions['0.3.295'].dist.integrity, tarball: sdk.versions['0.3.295'].dist.tarball } },
  cli: { url: cliUrl, sha256: digest(cliRaw), dist_tags: cli['dist-tags'], stable_versions_above_baseline: Object.keys(cli.versions).filter(v => /^\d+\.\d+\.\d+$/.test(v) && higher(v, '2.1.295')) },
  official_changelog: { url: changelogUrl, sha256: digest(log), first_version_heading: log.match(/^## .+$/m)?.[0], baseline_heading_present: log.includes('## 0.3.295'), baseline_cli_parity_line: log.match(/^.*Updated to parity with Claude Code v2\.1\.295.*$/m)?.[0], source_field_mentioned_in_baseline_section: log.split('## 0.3.294')[0].includes('UserPromptSubmit') },
  installed_or_switched_version: false,
};
await mkdir(path.join(root, 'evidence'), { recursive: true });
await writeFile(path.join(root, 'evidence', 'official-version-check.json'), JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 2));
