import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { createPocSandboxProfile, serializePocSummary } from './poc-host-privacy.mjs';

async function scratch(t) {
  const directory = await realpath(await mkdtemp(path.join(os.tmpdir(), 'poc-home-privacy-')));
  t.after(async () => {
    await rm(directory, { recursive: true, force: true });
    await assert.rejects(stat(directory), { code: 'ENOENT' });
  });
  return directory;
}

test('host home resolution ignores the isolated launcher HOME', async t => {
  const root = await scratch(t);
  const launcherHome = path.join(root, 'isolated-launcher-home');
  await mkdir(launcherHome);
  const moduleURL = new URL('./poc-host-privacy.mjs', import.meta.url).href;
  const code = `
    import assert from 'node:assert/strict';
    import { userInfo, homedir } from 'node:os';
    import { realpath } from 'node:fs/promises';
    import { resolveHostHome } from ${JSON.stringify(moduleURL)};
    const declared = userInfo().homedir;
    const resolved = await resolveHostHome();
    assert.equal(resolved.path === await realpath(declared), true);
    assert.equal(resolved.aliases.includes(declared), true);
    assert.equal(resolved.aliases.includes(resolved.path), true);
    assert.equal(new Set(resolved.aliases).size, resolved.aliases.length);
    assert.equal(homedir() === process.env.HOME, true);
    assert.equal(resolved.path !== process.env.HOME, true);
    console.log('HOST_HOME_SOURCE_OK');
  `;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', code], {
    env: { PATH: '/usr/bin:/bin', HOME: launcherHome, TMPDIR: root },
    encoding: 'utf8', timeout: 5_000,
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), 'HOST_HOME_SOURCE_OK');
});

test('Seatbelt denies synthetic host files while preserving SDK read/write access', {
  skip: process.platform !== 'darwin',
}, async t => {
  const root = await scratch(t);
  const hostHome = path.join(root, 'Host home "quoted" \\segment');
  const sdkRoot = path.join(hostHome, 'SDK directory "quoted" \\segment');
  await mkdir(sdkRoot, { recursive: true });
  const privateFile = path.join(hostHome, 'private-sentinel.txt');
  const allowedFile = path.join(sdkRoot, 'allowed-sentinel.txt');
  await writeFile(privateFile, 'SYNTHETIC_HOST_PRIVATE');
  await writeFile(allowedFile, 'SYNTHETIC_SDK_ALLOWED');
  const profile = createPocSandboxProfile({ sdkRoot, hostHome, port: 1 });
  const run = (command, args) => {
    const result = spawnSync('/usr/bin/sandbox-exec', ['-p', profile, command, ...args], {
      cwd: sdkRoot, env: { PATH: '/usr/bin:/bin', HOME: hostHome, TMPDIR: root },
      encoding: 'utf8', timeout: 5_000,
    });
    assert.ifError(result.error);
    return result;
  };

  const allowedRead = run('/bin/cat', [allowedFile]);
  assert.equal(allowedRead.status, 0, allowedRead.stderr);
  assert.equal(allowedRead.stdout, 'SYNTHETIC_SDK_ALLOWED');
  const deniedRead = run('/bin/cat', [privateFile]);
  assert.notEqual(deniedRead.status, 0);
  assert.equal(deniedRead.stdout, '');

  const allowedWritePath = path.join(sdkRoot, 'written.txt');
  const write = destination => run('/bin/sh', ['-c', 'printf "%s" "$2" > "$1"',
    'synthetic-write', destination, 'SYNTHETIC_WRITE']);
  const allowedWrite = write(allowedWritePath);
  assert.equal(allowedWrite.status, 0, allowedWrite.stderr);
  assert.equal(await readFile(allowedWritePath, 'utf8'), 'SYNTHETIC_WRITE');
  const outsideWritePath = path.join(root, 'outside-write.txt');
  assert.notEqual(write(outsideWritePath).status, 0);
  await assert.rejects(stat(outsideWritePath), { code: 'ENOENT' });
});

test('summary redacts both declared and canonical home paths, including object keys', () => {
  const declaredHome = '/Users/fixture-home';
  const canonicalHome = '/Volumes/Fixture Users/fixture-home';
  const sdkRoot = `${canonicalHome}/project/sdk`;
  const summary = {
    homeFile: `${declaredHome}/private.txt`, canonicalFile: `${canonicalHome}/private.txt`,
    sdkFile: `${sdkRoot}/evidence/summary.json`,
    [`${declaredHome}/key`]: `${canonicalHome}/value`,
  };
  const serialized = serializePocSummary(summary, sdkRoot, [declaredHome, canonicalHome]);
  assert.deepEqual(JSON.parse(serialized), {
    homeFile: '<HOST_USER_HOME>/private.txt', canonicalFile: '<HOST_USER_HOME>/private.txt',
    sdkFile: '<SDK_DIR>/evidence/summary.json',
    '<HOST_USER_HOME>/key': '<HOST_USER_HOME>/value',
  });
  assert.equal(serialized.includes(declaredHome), false);
  assert.equal(serialized.includes(canonicalHome), false);
});

test('summary removes escaped paths from nested JSON and sandbox profiles', () => {
  const hostHome = '/Users/Fixture "quoted" \\segment';
  const sdkRoot = `${hostHome}/SDK "quoted" \\segment`;
  const summary = {
    plain: `${hostHome}/private.txt`,
    nestedJSON: JSON.stringify({ home: `${hostHome}/private.txt`, sdk: `${sdkRoot}/input.txt` }),
    sandbox_profile: createPocSandboxProfile({ sdkRoot, hostHome, port: 1 }),
    [`${hostHome}/key`]: `${sdkRoot}/value`,
  };
  const serialized = serializePocSummary(summary, sdkRoot, [hostHome]);
  const decoded = JSON.parse(serialized);
  assert.equal(decoded.plain, '<HOST_USER_HOME>/private.txt');
  assert.deepEqual(JSON.parse(decoded.nestedJSON), {
    home: '<HOST_USER_HOME>/private.txt', sdk: '<SDK_DIR>/input.txt',
  });
  assert.equal(decoded['<HOST_USER_HOME>/key'], '<SDK_DIR>/value');
  assert.equal(decoded.sandbox_profile.includes('(subpath "<HOST_USER_HOME>")'), true);
  assert.equal(decoded.sandbox_profile.includes('(subpath "<SDK_DIR>")'), true);
  assert.equal(decoded.sandbox_profile.includes('Fixture'), false);
  assert.equal(serialized.includes('quoted'), false);
});
