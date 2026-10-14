import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable, Writable } from 'node:stream';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { handleRequest, runStdio } from './stdio.mjs';
import { textHash } from './protected-text.mjs';

const config = { endpoint: 'https://api.deepseek.com', model: 'fixture-only', apiKey: 'fake-user-configured-key' };
const runtime = { schema: 'app-runtime-profile/v1', timeZone: 'Asia/Tokyo', language: 'ja' };
const network = { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:7890', dnsPolicy: 'proxy-only' };

test('bridge mock protocol translates EN/JA input and Chinese display, requiring input confirmation', async () => {
  for (const target of ['en', 'ja']) {
    const original = '请解释 `foo()`';
    const response = await handleRequest({ operation: 'translate_input', text: original, target }, { fixtureOnly: true });
    assert.equal(response.ok, true);
    assert.equal(response.original, original);
    assert.equal(response.translated, target === 'en' ? 'Please explain `foo()`' : '説明してください `foo()`');
    assert.equal(response.requires_confirmation, true);
    assert.equal(response.fixture_only, true);
    assert.equal(response.revision, 1);
    assert.match(response.request_id, /^[0-9a-f-]{36}$/);
    assert.equal(response.translation_sha256, textHash(response.translated));
  }
  const response = await handleRequest({ operation: 'translate_output', text: 'Finished: `foo()`', target: 'zh' }, { fixtureOnly: true });
  assert.equal(response.translated, '已完成: `foo()`');
  assert.equal(response.requires_confirmation, false);
});

test('bridge explicit config uses injected real-shaped completion and never echoes key', async () => {
  let requests = 0;
  const response = await handleRequest({ operation: 'translate_input', text: '请解释', target: 'en', model: config, runtime }, {
    testOnly: true,
    transport: async ({ body, headers }) => {
      requests += 1;
      assert.equal(headers.authorization, `Bearer ${config.apiKey}`);
      assert.equal(body.includes(runtime.timeZone), false);
      assert.equal(JSON.parse(body).runtime, undefined);
      const data = JSON.parse(JSON.parse(body).messages[1].content);
      return { status: 200, headers: { 'content-type': 'application/json' }, body: JSON.stringify({
        object: 'chat.completion', id: 'fake-completion', model: 'fixture-only',
        choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: JSON.stringify({ segment_id: data.segment_id, translation: 'Please explain' }) } }],
      }) };
    },
  });
  assert.equal(response.ok, true);
  assert.equal(requests, 1);
  assert(!JSON.stringify(response).includes(config.apiKey));
});

test('bridge rejects missing config, wrong operation/target, malformed placeholder and API tool calls', async () => {
  assert.deepEqual(await handleRequest({ operation: 'translate_input', text: '请解释', target: 'en' }), { ok: false, error_code: 'INVALID_CONFIG' });
  for (const request of [null, [], { operation: 'send_cli', text: 'x', target: 'en' }, { operation: 'translate_input', text: 'x', target: 'zh' }, { operation: 'translate_output', text: 'x', target: 'en' }]) {
    assert.deepEqual(await handleRequest(request, { fixtureOnly: true }), { ok: false, error_code: 'INVALID_REQUEST' });
  }
  const damaged = await handleRequest({ operation: 'translate_input', text: '请解释 `foo()`', target: 'en', model: config }, {
    testOnly: true,
    transport: async ({ body }) => {
      const data = JSON.parse(JSON.parse(body).messages[1].content);
      return { status: 200, headers: { 'content-type': 'application/json' }, body: JSON.stringify({
        object: 'chat.completion', id: 'fake-completion', model: 'fixture-only',
        choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: JSON.stringify({ segment_id: data.segment_id, translation: 'Please explain' }) } }],
      }) };
    },
  });
  assert.deepEqual(damaged, { ok: false, error_code: 'PLACEHOLDER_MISMATCH' });
  const failure = await handleRequest({ operation: 'translate_output', text: 'Finished', target: 'zh', model: config }, {
    testOnly: true,
    transport: async () => { throw new Error(`must not leak ${config.apiKey}`); },
  });
  assert.deepEqual(failure, { ok: false, error_code: 'TRANSPORT_ERROR' });
});

test('production bridge refuses missing or malformed network policy before provider work', async () => {
  const request = { operation: 'translate_input', text: '请解释', target: 'en', model: config, runtime };
  assert.deepEqual(await handleRequest(request), { ok: false, error_code: 'NETWORK_POLICY_REQUIRED' });
  assert.deepEqual(await handleRequest({ ...request, network: { schema: 'app-network-policy/v1',
    proxyURL: 'http://localhost:7890', dnsPolicy: 'proxy-only' } }), { ok: false, error_code: 'NETWORK_POLICY_INVALID' });
  let requests = 0;
  assert.deepEqual(await handleRequest(request, { transport: async () => { requests++; } }),
    { ok: false, error_code: 'NETWORK_TEST_DEPENDENCIES_INVALID' });
  assert.equal(requests, 0);
});

test('production bridge requires runtime profile before provider work and emits a safe code', async () => {
  const request = { operation: 'translate_input', text: '请解释', target: 'en', model: config, network };
  assert.deepEqual(await handleRequest(request), { ok: false, error_code: 'RUNTIME_PROFILE_REQUIRED' });
});

test('explicit test fixtures validate present runtime and reject unsafe values before transport', async () => {
  let requests = 0;
  const request = { operation: 'translate_input', text: '请解释', target: 'en', model: config };
  for (const profile of [{ ...runtime, timeZone: 'asia/tokyo' }, { ...runtime, language: 'ja-JP' },
    { ...runtime, schema: 'other' }, { ...runtime, apiKey: config.apiKey },
    { schema: runtime.schema, timeZone: runtime.timeZone }, []]) {
    const result = await handleRequest({ ...request, runtime: profile }, {
      testOnly: true, transport: async () => { requests++; },
    });
    assert.deepEqual(result, { ok: false, error_code: 'RUNTIME_PROFILE_INVALID' });
    assert.equal(JSON.stringify(result).includes(config.apiKey), false);
  }
  assert.deepEqual(await handleRequest({ ...request, runtime: null }, { fixtureOnly: true }),
    { ok: false, error_code: 'RUNTIME_PROFILE_REQUIRED' });
  assert.equal(requests, 0);
});

test('language profile is independent of translation target and does not mutate parent locale', async () => {
  const before = Object.fromEntries(['TZ', 'LANG', 'LC_ALL', 'LC_MESSAGES'].map(key => [key, process.env[key]]));
  for (const language of ['ja', 'en', 'zh']) {
    const result = await handleRequest({ operation: 'translate_input', text: '请解释', target: 'en',
      runtime: { ...runtime, timeZone: 'UTC', language } }, { fixtureOnly: true });
    assert.equal(result.ok, true);
    assert.equal(result.translated, 'Please explain');
  }
  assert.deepEqual(Object.fromEntries(Object.keys(before).map(key => [key, process.env[key]])), before);
});

test('stdin bridge emits exactly one bounded JSON; malformed UTF8 and oversized body fail safely', async () => {
  for (const [payload, expected] of [[Buffer.from('{'), 'INVALID_REQUEST'], [Buffer.from([0xc0, 0xaf]), 'INVALID_REQUEST'], [Buffer.alloc(1_048_577, 0x78), 'REQUEST_TOO_LARGE']]) {
    let stdout = '';
    const output = new Writable({ write(chunk, encoding, done) { stdout += chunk.toString(); done(); } });
    const response = await runStdio({ input: Readable.from([payload]), output, fixtureOnly: true });
    assert.deepEqual(response, { ok: false, error_code: expected });
    assert.equal(stdout.trim().split('\n').length, 1);
    assert.deepEqual(JSON.parse(stdout), response);
  }
});

test('actual Node stdin/stdout child fixture succeeds without stderr or network config', async () => {
  const path = fileURLToPath(new URL('./stdio.mjs', import.meta.url));
  const result = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path, '--fixture'], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = ''; let stderr = '';
    child.stdout.on('data', (bytes) => { stdout += bytes.toString(); });
    child.stderr.on('data', (bytes) => { stderr += bytes.toString(); });
    child.on('error', reject);
    child.on('close', (exitCode) => resolve({ exitCode, stdout, stderr }));
    child.stdin.end(JSON.stringify({ operation: 'translate_input', text: '请解释 `foo()`', target: 'en' }));
  });
  assert.equal(result.exitCode, 0);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout.trim().split('\n').length, 1);
  const response = JSON.parse(result.stdout);
  assert.equal(response.translated, 'Please explain `foo()`');
  assert.equal(response.requires_confirmation, true);
  assert.equal(response.fixture_only, true);
});
