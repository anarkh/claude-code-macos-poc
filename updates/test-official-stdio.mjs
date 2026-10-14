// Offline stdio contract tests. No public/loopback transport, downloaded CLI,
// credential store or artifact directory is used.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { Readable, PassThrough } from 'node:stream';
import { once } from 'node:events';
import { setImmediate as nextTurn } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { MAX_OFFICIAL_INPUT_BYTES, OFFICIAL_ERROR_CODES } from './official-client.mjs';
import { runOfficialStdio, runStdio } from './official-stdio.mjs';

const PRIVATE = '/Users/private-fixture-secret/credential.json';
const ERROR = code => ({ type: 'error', code });
const CHECK = {
  schema: 'official-runtime-request/v1', operation: 'check',
  network: { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:1', dnsPolicy: 'proxy-only' },
  currentCLI: null, currentSDK: null,
};
function assertSanitized(events) {
  const output = JSON.stringify(events);
  assert.equal(output.includes(PRIVATE), false);
  assert.equal(output.includes('private-fixture-secret'), false);
  for (const event of events) {
    if (event.type === 'error') {
      assert.deepEqual(Object.keys(event).sort(), ['code', 'type']);
      assert.ok(OFFICIAL_ERROR_CODES.includes(event.code));
    }
  }
}
async function read(chunks, options = {}) {
  const events = [];
  const terminal = await runOfficialStdio({
    input: Readable.from(Array.isArray(chunks) ? chunks : [chunks]),
    emit: value => events.push(value), ...options,
  });
  assert.deepEqual(events, [terminal]);
  assertSanitized(events);
  return terminal;
}

test('stdio alias retains the same request implementation', () => {
  assert.equal(runStdio, runOfficialStdio);
  assert.equal(MAX_OFFICIAL_INPUT_BYTES, 65536);
});

test('malformed JSON, non-UTF8, nonobject and multiple requests emit one fixed error', async () => {
  for (const input of [
    Buffer.from(''), Buffer.from('{"credential":"' + PRIVATE),
    Buffer.from([0xff, 0xfe]), Buffer.from('null'), Buffer.from('[]'),
    Buffer.from('{}\n{}\n'), Buffer.from(JSON.stringify({ ...CHECK, schema: 'unknown/v1' })),
  ]) {
    assert.deepEqual(await read(input), ERROR('OFFICIAL_INVALID_REQUEST'));
  }
});

test('the byte limit accepts 65536 bytes and rejects larger cumulative input', async () => {
  assert.deepEqual(await read(Buffer.from('{}' + ' '.repeat(MAX_OFFICIAL_INPUT_BYTES - 2))),
    ERROR('OFFICIAL_INVALID_REQUEST'));
  for (const chunks of [
    Buffer.alloc(MAX_OFFICIAL_INPUT_BYTES + 1, 32),
    [Buffer.alloc(MAX_OFFICIAL_INPUT_BYTES, 32), Buffer.from('x')],
    ['界'.repeat(21845), '界'],
  ]) {
    assert.deepEqual(await read(chunks), ERROR('OFFICIAL_INPUT_TOO_LARGE'));
  }
});

test('stdin cannot inject credentials, a CA, transport, environment or test seams', async () => {
  for (const field of [
    'apiKey', 'credentials', 'credentialPath', 'ca', 'testOnly',
    'rejectUnauthorized', 'transportDependencies', 'transport', 'environment', 'url',
  ]) {
    assert.deepEqual(await read(Buffer.from(JSON.stringify({ ...CHECK, [field]: PRIVATE }))),
      ERROR('OFFICIAL_INVALID_REQUEST'));
  }
  for (const field of ['ca', 'apiKey', 'credentials', 'testOnly', 'rejectUnauthorized']) {
    assert.deepEqual(await read(Buffer.from(JSON.stringify({
      ...CHECK, network: { ...CHECK.network, [field]: PRIVATE },
    }))), ERROR('OFFICIAL_NETWORK_POLICY_INVALID'));
  }
});

test('invalid JS option shapes and unauthorized test dependencies fail before dispatch', async () => {
  for (const options of [
    { ca: PRIVATE }, { apiKey: PRIVATE }, { environment: { TOKEN: PRIVATE } },
    { signal: PRIVATE }, { input: {} }, { testOnly: false },
    { transportDependencies: { testOnly: true, ca: PRIVATE } },
    { testOnly: true, transportDependencies: { testOnly: true, apiKey: PRIVATE } },
  ]) {
    assert.deepEqual(await read(Buffer.from(JSON.stringify(CHECK)), options),
      ERROR('OFFICIAL_INVALID_REQUEST'));
  }
  const events = [];
  const options = Object.assign([], { emit: event => events.push(event) });
  assert.deepEqual(await runOfficialStdio(options), ERROR('OFFICIAL_INVALID_REQUEST'));
  assert.deepEqual(events, [ERROR('OFFICIAL_INVALID_REQUEST')]);
});

test('input waits for EOF before starting one operation, then active abort settles once', async () => {
  const input = new PassThrough(), abort = new AbortController(), events = [];
  const pending = runOfficialStdio({
    input, signal: abort.signal,
    emit: event => {
      events.push(event);
      if (event.type === 'progress') abort.abort(new Error(PRIVATE));
    },
  });
  input.write(JSON.stringify(CHECK));
  await nextTurn();
  assert.deepEqual(events, []);
  input.end();
  assert.deepEqual(await pending, ERROR('OFFICIAL_CANCELLED'));
  assert.deepEqual(events, [
    { type: 'progress', fraction: 0, phase: 'metadata' },
    ERROR('OFFICIAL_CANCELLED'),
  ]);
  assert.equal(input.destroyed, true);
  assertSanitized(events);
});

test('external cancellation while input is pending destroys that input and emits once', async () => {
  const input = new PassThrough(), abort = new AbortController(), events = [];
  const pending = runOfficialStdio({ input, signal: abort.signal, emit: event => events.push(event) });
  input.write('{"credential":"' + PRIVATE);
  abort.abort(new Error(PRIVATE));
  assert.deepEqual(await pending, ERROR('OFFICIAL_CANCELLED'));
  assert.deepEqual(events, [ERROR('OFFICIAL_CANCELLED')]);
  assert.equal(input.destroyed, true);
  assertSanitized(events);
});

test('an already aborted external signal cancels before parsing or dispatching', async () => {
  const input = new PassThrough(), abort = new AbortController(), events = [];
  abort.abort(new Error(PRIVATE));
  assert.deepEqual(await runOfficialStdio({ input, signal: abort.signal, emit: event => events.push(event) }),
    ERROR('OFFICIAL_CANCELLED'));
  assert.deepEqual(events, [ERROR('OFFICIAL_CANCELLED')]);
  assert.equal(input.destroyed, true);
  assertSanitized(events);
});

test('input stream failure is reduced to a fixed code without echoing its path or message', async () => {
  const input = new PassThrough(), events = [];
  const pending = runOfficialStdio({ input, emit: event => events.push(event) });
  input.destroy(new Error(PRIVATE));
  assert.deepEqual(await pending, ERROR('OFFICIAL_NETWORK_FAILED'));
  assert.deepEqual(events, [ERROR('OFFICIAL_NETWORK_FAILED')]);
  assertSanitized(events);
});

function bridgeChild(t, args = [], { readiness = false } = {}) {
  const executable = fileURLToPath(new URL('./official-stdio.mjs', import.meta.url));
  // Observe the actual production bridge beginning to read stdin. The production
  // SIGTERM listener is installed before this readable listener is added.
  const preload = 'import { writeSync, closeSync } from "node:fs"; let sent = false; process.stdin.on("newListener", kind => { if (kind === "readable" && !sent) { sent = true; writeSync(3, "ready\\n"); closeSync(3); } });';
  const child = spawn(process.execPath, [
    ...(readiness ? ['--import', 'data:text/javascript,' + encodeURIComponent(preload)] : []),
    executable, ...args,
  ], {
    stdio: readiness ? ['pipe', 'pipe', 'pipe', 'pipe'] : ['pipe', 'pipe', 'pipe'],
    env: { PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' },
  });
  let stdout = '', stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  t.after(() => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  });
  const closed = once(child, 'close', { signal: AbortSignal.timeout(5000) });
  return { child, closed, output: () => ({ stdout, stderr }) };
}
function assertChildError(result, output, code) {
  assert.deepEqual(result, [1, null]);
  assert.equal(output.stderr, '');
  assert.equal(output.stdout, JSON.stringify(ERROR(code)) + '\n');
  assertSanitized([JSON.parse(output.stdout)]);
}

test('production bridge rejects argv injection with one fixed NDJSON error and nonzero exit', async t => {
  const child = bridgeChild(t, ['--ca=' + PRIVATE]);
  child.child.stdin.end();
  assertChildError(await child.closed, child.output(), 'OFFICIAL_INVALID_REQUEST');
});

test('production SIGTERM while input is held returns the fixed cancellation code', async t => {
  const child = bridgeChild(t, [], { readiness: true });
  const ready = once(child.child.stdio[3], 'data', { signal: AbortSignal.timeout(3000) });
  child.child.stdin.write('{"credential":"' + PRIVATE);
  assert.equal((await ready)[0].toString(), 'ready\n');
  assert.equal(child.child.kill('SIGTERM'), true);
  assertChildError(await child.closed, child.output(), 'OFFICIAL_CANCELLED');
});

