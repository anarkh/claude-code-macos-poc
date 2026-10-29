import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { proxyHttpsBufferRequest } from '../network/proxy-transport.mjs';
import { QUOTA_REQUEST_SCHEMA, QUOTA_RESPONSE_SCHEMA, QUOTA_URL, QUOTA_MAX_RESPONSE_BYTES,
  validateQuotaInput, parseQuotaUsage, querySubscriptionQuota, safeQuotaCode } from './subscription-quota.mjs';

const token = 'sk-ant-oat01-SYNTHETIC-QUOTA-TEST-ONLY';
const network = { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:7897', dnsPolicy: 'proxy-only' };
const input = { schema: QUOTA_REQUEST_SCHEMA, subscriptionToken: token, network };
const now = Date.parse('2026-10-27T04:00:00Z');
const usage = { five_hour: { utilization: 23.5, resets_at: '2026-10-27T06:30:00+00:00' },
  seven_day: { utilization: 74, resets_at: '2026-10-30T07:30:00.123456Z' },
  seven_day_sonnet: null, extra_usage: { used_credits: 100 }, unknown_window: { utilization: 100 } };
const response = (body = usage, changes = {}) => ({ status: 200,
  headers: { 'content-type': 'application/json; charset=utf-8' }, body: Buffer.from(JSON.stringify(body)), ...changes });
const rejectsCode = (promise, code) => assert.rejects(promise, error => error.code === code && !String(error).includes(token));

test('quota makes one fixed GET with only query headers and no model payload', async () => {
  const calls = [];
  const result = await querySubscriptionQuota(input, { now: () => now, transport: async options => {
    calls.push(options); return response();
  } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, QUOTA_URL);
  assert.equal(calls[0].method, 'GET');
  assert.equal(calls[0].body, '');
  assert.equal(calls[0].maxResponseBytes, QUOTA_MAX_RESPONSE_BYTES);
  assert.deepEqual(calls[0].network, network);
  assert.deepEqual(calls[0].headers, { authorization: `Bearer ${token}`, accept: 'application/json',
    'content-type': 'application/json', 'anthropic-beta': 'oauth-2025-04-20' });
  assert.deepEqual(result, { schema: QUOTA_RESPONSE_SCHEMA, ok: true, queriedAt: now / 1000,
    windows: [{ id: 'five_hour', usedPercentage: 23.5, resetsAt: Date.parse(usage.five_hour.resets_at) / 1000 },
      { id: 'seven_day', usedPercentage: 74, resetsAt: Date.parse(usage.seven_day.resets_at) / 1000 }] });
  assert.equal(JSON.stringify(result).includes(token), false);
  assert.equal(JSON.stringify(result).includes('extra_usage'), false);
});

test('missing windows stay absent while explicit zero and unknown reset remain distinct', () => {
  assert.deepEqual(parseQuotaUsage({ five_hour: null, seven_day: null }, now / 1000).windows, []);
  assert.deepEqual(parseQuotaUsage({ five_hour: { utilization: null, resets_at: null } }, now / 1000).windows, []);
  assert.deepEqual(parseQuotaUsage({ five_hour: { utilization: 0, resets_at: null } }, now / 1000).windows,
    [{ id: 'five_hour', usedPercentage: 0, resetsAt: null }]);
  assert.equal(parseQuotaUsage({ five_hour: { utilization: 100 } }, now / 1000).windows[0].resetsAt, null);
});

test('expired reset remains observed data and is never turned into a fresh zero', () => {
  const result = parseQuotaUsage({ five_hour: { utilization: 100, resets_at: '2026-10-27T03:00:00Z' } }, now / 1000);
  assert.equal(result.windows[0].usedPercentage, 100);
  assert.ok(result.windows[0].resetsAt < result.queriedAt);
});

test('malformed known windows reject instead of supplying estimates', () => {
  for (const value of [undefined, '23', true, -1, 100.001, NaN, Infinity]) {
    assert.throws(() => parseQuotaUsage({ five_hour: { utilization: value } }, now / 1000), { code: 'QUOTA_RESPONSE_INVALID' });
  }
  for (const resets_at of [123, '', 'tomorrow', '2026-10-27', '2026-99-27T04:00:00Z', '2026-02-30T04:00:00Z', '2026-10-27T24:00:00Z']) {
    assert.throws(() => parseQuotaUsage({ five_hour: { utilization: 10, resets_at } }, now / 1000), { code: 'QUOTA_RESPONSE_INVALID' });
  }
  for (const payload of [null, [], 'string', { five_hour: [] }, { five_hour: 5 }]) {
    assert.throws(() => parseQuotaUsage(payload, now / 1000), { code: 'QUOTA_RESPONSE_INVALID' });
  }
});

test('request validation rejects credentials, overrides and invalid proxy before transport', async () => {
  let calls = 0;
  for (const change of [{ subscriptionToken: 'not-a-token' }, { subscriptionToken: token + '\n' },
    { subscriptionToken: 'sk-ant-oat01-' + 'x'.repeat(4096) }, { network: { ...network, proxyURL: 'https://outside.invalid' } },
    { schema: 'bad' }, { url: 'https://other.invalid' }]) {
    await assert.rejects(querySubscriptionQuota({ ...input, ...change }, { transport: async () => { calls++; return response(); } }));
  }
  assert.equal(calls, 0);
  assert.deepEqual(validateQuotaInput(input), { subscriptionToken: token, network });
});

test('HTTP failures are separate and untrusted response bodies never become diagnostics', async () => {
  for (const [status, code] of [[401, 'QUOTA_UNAUTHORIZED'], [403, 'QUOTA_FORBIDDEN'], [429, 'QUOTA_RATE_LIMITED'],
    [500, 'QUOTA_SERVICE_UNAVAILABLE'], [503, 'QUOTA_SERVICE_UNAVAILABLE'], [302, 'QUOTA_HTTP_REJECTED'], [404, 'QUOTA_HTTP_REJECTED']]) {
    let calls = 0;
    await rejectsCode(querySubscriptionQuota(input, { transport: async () => {
      calls++; return response({ secret: token }, { status, headers: { location: 'https://do-not-follow.invalid' } });
    } }), code);
    assert.equal(calls, 1);
  }
  assert.equal(safeQuotaCode({ code: token, message: token }), 'QUOTA_QUERY_FAILED');
  assert.equal(safeQuotaCode(new Error(token)), 'QUOTA_QUERY_FAILED');
});

test('invalid JSON, HTML, missing body and oversized bodies cannot become quota data', async () => {
  for (const change of [{ body: Buffer.from('{bad') }, { body: Buffer.from('null') },
    { headers: { 'content-type': 'text/html' } }, { body: undefined },
    { body: Buffer.alloc(QUOTA_MAX_RESPONSE_BYTES + 1, 32) }]) {
    await rejectsCode(querySubscriptionQuota(input, { transport: async () => response(usage, change) }), 'QUOTA_RESPONSE_INVALID');
  }
});

async function proxyFixture(t, handler) {
  const sockets = new Set();
  const server = http.createServer();
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  server.on('connect', handler);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => { for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve)); });
  return { ...network, proxyURL: `http://127.0.0.1:${server.address().port}` };
}

test('real proxy transport enforces timeout and cancellation without a model request', async t => {
  let connected;
  const connection = new Promise(resolve => { connected = resolve; });
  const policy = await proxyFixture(t, (request, socket) => {
    assert.equal(request.url, 'api.anthropic.com:443');
    assert.equal(request.headers.authorization, undefined);
    socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    connected();
  });
  const shortTransport = options => proxyHttpsBufferRequest(options, { testOnly: true, timeoutMs: 50 });
  await rejectsCode(querySubscriptionQuota({ ...input, network: policy }, { transport: shortTransport }), 'PROXY_TIMEOUT');
  const controller = new AbortController();
  const pending = querySubscriptionQuota({ ...input, network: policy }, { signal: controller.signal });
  await connection;
  controller.abort();
  await rejectsCode(pending, 'NETWORK_CANCELLED');
  await rejectsCode(querySubscriptionQuota(input, { signal: controller.signal }), 'QUOTA_CANCELLED');
});

async function runCLI(payload) {
  const child = spawn(process.execPath, [fileURLToPath(new URL('./subscription-quota.mjs', import.meta.url))],
    { env: { PATH: '/usr/bin:/bin' }, stdio: ['pipe', 'pipe', 'pipe'] });
  const stdout = [], stderr = [];
  child.stdout.on('data', chunk => stdout.push(chunk));
  child.stderr.on('data', chunk => stderr.push(chunk));
  child.stdin.end(payload);
  const [code] = await once(child, 'close');
  return { code, stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString() };
}

test('CLI only emits sanitized structured errors for malformed or rejected queries', async t => {
  const policy = await proxyFixture(t, (_request, socket) => socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'));
  for (const [payload, expected] of [['{bad ' + token, 'QUOTA_INPUT_INVALID'],
    [JSON.stringify({ ...input, network: policy }), 'PROXY_CONNECT_REJECTED']]) {
    const result = await runCLI(payload);
    assert.equal(result.code, 1);
    assert.equal(result.stderr, '');
    assert.equal(result.stdout.includes(token), false);
    assert.deepEqual(JSON.parse(result.stdout), { schema: QUOTA_RESPONSE_SCHEMA, ok: false, code: expected });
  }
});
