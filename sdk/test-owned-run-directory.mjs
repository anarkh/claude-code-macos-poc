import assert from 'node:assert/strict';
import { mkdtemp, lstat, readFile, readdir, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createOwnedRunDirectory, nativeProcessMayBeRunning, waitForNativeProcessExit, OWNED_RUN_MANIFEST, OWNED_RUN_SCHEMA } from './owned-run-directory.mjs';

test('owned runtime receipt is bounded, private, identity-bound and has no host path or credential fields', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'owned-run-unit-'));
  try {
    for (const kind of ['chat', 'text-smoke']) {
      const run = await createOwnedRunDirectory(kind, { temporaryRoot: root });
      const directory = await lstat(run.directory, { bigint: true });
      const file = path.join(run.directory, OWNED_RUN_MANIFEST);
      const data = await readFile(file, 'utf8');
      const receipt = JSON.parse(data);
      assert.deepEqual(Object.keys(receipt).sort(), ['schema', 'run_id', 'uid', 'pid', 'kind', 'directory_dev', 'directory_ino', 'native_state', 'native_pid'].sort());
      assert.equal(receipt.schema, OWNED_RUN_SCHEMA);
      assert.match(receipt.run_id, /^[0-9a-f-]{36}$/);
      assert.equal(receipt.uid, process.getuid()); assert.equal(receipt.pid, process.pid);
      assert.equal(receipt.kind, kind);
      assert.equal(receipt.directory_dev, String(directory.dev)); assert.equal(receipt.directory_ino, String(directory.ino));
      assert.equal(receipt.native_state, 'not-started'); assert.equal(receipt.native_pid, null);
      assert.equal(Number(directory.mode & 0o777n), 0o700);
      assert.equal((await lstat(file)).mode & 0o777, 0o600);
      assert.ok(Buffer.byteLength(data) < 4096); assert.ok(!data.includes(root));
      run.markNativeLaunchPending();
      assert.equal(JSON.parse(await readFile(file, 'utf8')).native_state, 'pending');
      assert.equal(JSON.parse(await readFile(file, 'utf8')).native_pid, null);
      run.registerNativePID(process.pid);
      assert.equal(JSON.parse(await readFile(file, 'utf8')).native_state, 'registered');
      assert.equal(JSON.parse(await readFile(file, 'utf8')).native_pid, process.pid);
      assert.deepEqual(await readdir(run.directory), [OWNED_RUN_MANIFEST]);
      for (const invalid of [null, undefined, -1, 0, 1, 2.5, '55', 2_147_483_648]) {
        assert.throws(() => run.registerNativePID(invalid), /OWNED_RUN_PID_INVALID/);
      }
      assert.equal(JSON.parse(await readFile(file, 'utf8')).native_pid, process.pid);
    }
    await assert.rejects(createOwnedRunDirectory('other', { temporaryRoot: root }), /OWNED_RUN_KIND_INVALID/);
    assert.equal((await readdir(root)).length, 2);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('native exit check is conservative about live processes and unknown IDs', () => {
  assert.equal(nativeProcessMayBeRunning(process.pid), true);
  for (const pid of [undefined, null, -1, 0, 1, '123', 2.5]) assert.equal(nativeProcessMayBeRunning(pid), true);
});

test('bounded native exit wait retains live processes and admits a confirmed exit', async () => {
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 10000)'], { detached: true, stdio: 'ignore' });
  const exited = once(child, 'exit');
  try {
    await once(child, 'spawn');
    assert.equal(await waitForNativeProcessExit(child.pid, 20), false);
  } finally {
    child.kill('SIGTERM');
    await exited;
  }
  assert.equal(await waitForNativeProcessExit(child.pid), true);
});

test('an exited leader with a finishing helper group must wait before cleanup', async () => {
  const child = spawn('/bin/sh', ['-c', '/bin/sleep 0.15 & exit 0'], { detached: true, stdio: 'ignore' });
  await once(child, 'exit');
  assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' });
  assert.equal(nativeProcessMayBeRunning(child.pid), true);
  assert.equal(await waitForNativeProcessExit(child.pid), true);
});
