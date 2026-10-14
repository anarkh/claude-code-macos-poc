import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { Readable, PassThrough } from 'node:stream';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { MAX_METADATA_BYTES } from './client.mjs';
import { runStdio } from './stdio.mjs';

async function read(bytes, options = {}) {
  const events = [];
  const terminal = await runStdio({ input: Readable.from([bytes]), emit: value => events.push(value), ...options });
  assert.deepEqual(events, [terminal]);
  assert.equal(JSON.stringify(events).includes('private-fixture-secret'), false);
  return terminal;
}
test('stdio emits one sanitized error for malformed and non-UTF8 input', async () => {
  for (const input of [Buffer.from('{"secret":"private-fixture-secret"'), Buffer.from([0xff, 0xfe]), Buffer.from('null'), Buffer.from('[]')]) {
    assert.deepEqual(await read(input), { type: 'error', code: 'UPDATE_INVALID_REQUEST' });
  }
});
test('stdio rejects oversized requests without echoing input', async () => {
  assert.deepEqual(await read(Buffer.alloc(MAX_METADATA_BYTES + 1, 32)), { type: 'error', code: 'UPDATE_INPUT_TOO_LARGE' });
});
test('stdin cannot inject a CA, test seam, credential or environment', async () => {
  const base = { schema: 'runtime-update-request/v1', operation: 'check', feedURL: 'https://fixture.invalid/channel.json',
    network: { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:1', dnsPolicy: 'proxy-only' } };
  for (const field of ['ca', 'testOnly', 'rejectUnauthorized', 'transport', 'environment', 'apiKey']) {
    assert.deepEqual(await read(Buffer.from(JSON.stringify({ ...base, [field]: 'private-fixture-secret' }))),
      { type: 'error', code: 'UPDATE_INVALID_REQUEST' });
  }
});
test('cancellation while input is pending settles once and destroys only that input', async () => {
  const input = new PassThrough(), abort = new AbortController(), events = [];
  const pending = runStdio({ input, signal: abort.signal, emit: value => events.push(value) });
  input.write('{"secret":"private-fixture-secret"');
  abort.abort(new Error('private-fixture-secret'));
  assert.deepEqual(await pending, { type: 'error', code: 'UPDATE_CANCELLED' });
  assert.deepEqual(events, [{ type: 'error', code: 'UPDATE_CANCELLED' }]);
  assert.equal(input.destroyed, true);
});
test('production CLI rejects arguments with nonzero status and bounded NDJSON', async () => {
  const executable = fileURLToPath(new URL('./stdio.mjs', import.meta.url));
  const child = spawn(process.execPath, [executable, '--ca=private-fixture-secret'], {
    stdio: ['pipe', 'pipe', 'pipe'], env: { PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' },
  });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.stdin.end();
  const [code, signal] = await once(child, 'close');
  assert.equal(code, 1); assert.equal(signal, null); assert.equal(stderr, '');
  assert.deepEqual(stdout, JSON.stringify({ type: 'error', code: 'UPDATE_INVALID_REQUEST' }) + '\n');
});
test('production CLI cancellation is a sanitized error and nonzero exit', async () => {
  const executable = fileURLToPath(new URL('./stdio.mjs', import.meta.url));
  const child = spawn(process.execPath, [executable], {
    stdio: ['pipe', 'pipe', 'pipe'], env: { PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' },
  });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  // Observe the script's stdin listener before sending a signal. A trivial
  // request is kept incomplete, so no transport can have been requested.
  child.stdin.write('{"secret":"private-fixture-secret"');
  await new Promise(resolve => setTimeout(resolve, 250));
  child.kill('SIGTERM');
  const [code, signal] = await once(child, 'close');
  assert.equal(code, 1); assert.equal(signal, null); assert.equal(stderr, '');
  assert.deepEqual(stdout, JSON.stringify({ type: 'error', code: 'UPDATE_CANCELLED' }) + '\n');
});
