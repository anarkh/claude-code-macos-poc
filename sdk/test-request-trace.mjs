import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequestTrace, requestTraceErrorCode } from './request-trace.mjs';

const REQUEST_ID = 'e279c431-2d15-46ca-8c58-cf9106eac6a4';
const MODEL = 'deepseek-chat';
const PROVIDER_URL = 'https://api.deepseek.com/anthropic/v1/messages';
const SUBSCRIPTION_URL = 'https://api.anthropic.com/v1/messages?beta=true';
const BODY_LIMIT = 2_097_152;
const HEADER_VALUE_LIMIT = 4096;
const HEADER_LIMIT = 16_384;
const REDACTED = '[REDACTED]';
const ALLOWED_HEADERS = ['content-type', 'content-length', 'anthropic-version',
  'anthropic-beta', 'x-app', 'user-agent', 'x-claude-code-session-id',
  'anthropic-dangerous-direct-browser-access'];

function options(overrides = {}) {
  return {
    requestID: REQUEST_ID, attempt: 1, provider: 'deepseek-api', url: PROVIDER_URL,
    wireModel: MODEL, headers: { 'content-type': 'application/json' },
    payload: Buffer.from(JSON.stringify({ model: MODEL, messages: [] })),
    network: { proxyURL: 'http://127.0.0.1:8080' }, emit() {}, now: () => 100,
    ...overrides,
  };
}

function fixture(overrides = {}) {
  const events = [];
  const clock = { ms: 100 };
  const input = options({ emit: event => events.push(event), now: () => clock.ms, ...overrides });
  return { trace: createRequestTrace(input), events, clock, input };
}

function rejected(overrides) {
  const events = [];
  assert.throws(() => createRequestTrace(options({ ...overrides, emit: event => events.push(event) })),
    { code: 'REQUEST_TRACE_REJECTED', message: 'REQUEST_TRACE_REJECTED' });
  assert.deepEqual(events, [], 'a rejected snapshot must never be published');
}

function payloadOfSize(bytes, suffix = '') {
  const empty = JSON.stringify({ model: MODEL, text: suffix });
  return Buffer.from(JSON.stringify({ model: MODEL, text: 'x'.repeat(bytes - Buffer.byteLength(empty)) + suffix }));
}

function assertNoSecrets(value, secrets) {
  const serialized = JSON.stringify(value);
  for (const secret of secrets) {
    assert.equal(serialized.includes(secret), false, 'raw credential leaked');
    assert.equal(serialized.includes(JSON.stringify(secret).slice(1, -1)), false,
      'JSON-escaped credential leaked');
  }
}

test('project attempts extend to 24 only with explicit request context', () => {
  for (const attempt of [4, 12, 24]) {
    const { trace, events } = fixture({ attempt, project: true });
    trace.start(); trace.receivedStatus(200); trace.response();
    assert.equal(events.length, 2); assert.equal(events[1].attempt, attempt);
  }
  rejected({ attempt: 4 }); rejected({ attempt: 25, project: true }); rejected({ project: 'true' });
});

test('the final compact serialized request is exact and byte counts use UTF-8', () => {
  const body = JSON.stringify({ model: MODEL, system: '中文 🚲', messages: [
    { role: 'user', content: [{ type: 'text', text: 'quote " and slash \\ and\nnewline' }] },
  ], stream: true, max_tokens: 4096, temperature: 0, metadata: { turn: null } });
  const payload = Buffer.from(body);
  const before = Buffer.from(payload);
  const { trace, events } = fixture({ payload });
  trace.start();
  trace.receivedStatus(201);
  trace.response();
  assert.equal(events.length, 2);
  for (const event of events) {
    assert.equal(event.body, body);
    assert.equal(event.body_bytes, Buffer.byteLength(body, 'utf8'));
    assert.ok(event.body_bytes > body.length);
    assert.equal(event.body_truncated, false);
    assert.equal(event.secrets_redacted, false);
  }
  assert.deepEqual(payload, before);
});

test('all known credentials are scrubbed from strings, object keys and nested JSON metadata', () => {
  const secrets = ['sk-api-"quoted"\\path', 'subscription-"quoted"\\token', 'local-"quoted"\\token'];
  const identity = { device_id: 'b'.repeat(64), account_uuid: '8e92f3b7-ad49-40b9-b766-9dd5c4c09e90', session_id: REQUEST_ID };
  const embedded = JSON.stringify({ ...identity, access_token: secrets[1], [secrets[2]]: secrets[0] });
  const request = { model: MODEL, messages: [{ role: 'user', content: secrets.map(secret => ({
    type: 'text', text: `prefix "${secret}" \\ ${secret} suffix`,
  })) }], [secrets[0]]: { [secrets[1]]: [secrets[2], false, 7, null] },
  metadata: { user_id: embedded, plain: secrets.join(' / ') } };
  const payload = Buffer.from(JSON.stringify(request));
  const before = Buffer.from(payload);
  const { trace, events } = fixture({ payload, secrets });
  trace.start();
  trace.receivedStatus(200);
  trace.response();
  for (const event of events) {
    assertNoSecrets(event, secrets);
    const body = JSON.parse(event.body);
    assert.deepEqual(body.messages[0].content, secrets.map(() => ({
      type: 'text', text: `prefix "${REDACTED}" \\ ${REDACTED} suffix`,
    })));
    assert.deepEqual(body[REDACTED], { [REDACTED]: [REDACTED, false, 7, null] });
    assert.deepEqual(JSON.parse(body.metadata.user_id), {
      ...identity, access_token: REDACTED, [REDACTED]: REDACTED,
    });
    assert.equal(body.metadata.plain, secrets.map(() => REDACTED).join(' / '));
    assert.equal(event.secrets_redacted, true);
    assert.equal(event.body_bytes, payload.length);
  }
  assert.deepEqual(payload, before, 'trace creation and terminal emission must leave wire bytes unchanged');
  assert.equal(JSON.parse(payload).metadata.user_id, embedded);
});

test('subscription attribution metadata retains its legitimate device, account and session identity', () => {
  const userID = JSON.stringify({ device_id: 'b'.repeat(64),
    account_uuid: '8e92f3b7-ad49-40b9-b766-9dd5c4c09e90', session_id: REQUEST_ID });
  const body = JSON.stringify({ model: 'claude-sonnet-4-5', messages: [], metadata: { user_id: userID } });
  const { trace, events } = fixture({ provider: 'claude-subscription', url: SUBSCRIPTION_URL,
    wireModel: 'claude-sonnet-4-5', payload: Buffer.from(body), secrets: ['subscription-access-token'] });
  trace.start();
  trace.receivedStatus(200);
  trace.response();
  assert.equal(events[1].body, body);
  assert.equal(JSON.parse(events[1].body).metadata.user_id, userID);
  assert.equal(events[1].provider, 'claude-subscription');
  assert.equal(events[1].url, SUBSCRIPTION_URL);
  assert.equal(events[1].secrets_redacted, false);
});

test('only allowlisted request headers survive and allowed values are scrubbed without mutating input', () => {
  const secret = 'local-auth-token';
  const allowed = Object.fromEntries(ALLOWED_HEADERS.map(name => [name, `${name}-value`]));
  allowed['user-agent'] = `claude-code ${secret}`;
  const headers = { ...allowed, authorization: `Bearer ${secret}`, 'x-api-key': secret,
    cookie: 'private-cookie', 'proxy-authorization': `Basic ${secret}`, 'x-secret': secret,
    'x-arbitrary': 'private detail', 'x-stainless-os': 'MacOS', 'x-stainless-package-version': '1.2.3',
    'x-stainless-retry-count': '2', 'set-cookie': 'private response detail' };
  const before = structuredClone(headers);
  const { trace, events } = fixture({ headers, secrets: [secret] });
  trace.start();
  events[0].headers['user-agent'] = 'consumer mutation';
  trace.receivedStatus(200);
  trace.response();
  assert.deepEqual(Object.keys(events[1].headers), ALLOWED_HEADERS);
  assert.deepEqual(events[1].headers, { ...allowed, 'user-agent': `claude-code ${REDACTED}` });
  assertNoSecrets(events[1], [secret]);
  assert.deepEqual(headers, before);
});

test('the full 2 MiB body is admitted without truncation and oversized bodies fail closed', () => {
  const payload = payloadOfSize(BODY_LIMIT);
  assert.equal(payload.length, BODY_LIMIT);
  const { trace, events } = fixture({ payload });
  trace.start();
  assert.equal(Buffer.byteLength(events[0].body), BODY_LIMIT);
  assert.equal(events[0].body, payload.toString('utf8'));
  assert.equal(events[0].body_bytes, BODY_LIMIT);
  assert.equal(events[0].body_truncated, false);
  rejected({ payload: payloadOfSize(BODY_LIMIT + 1) });
  rejected({ payload: payloadOfSize(BODY_LIMIT, '!'), secrets: ['!'] });
});

test('header values have a 4096-byte UTF-8 bound and reject control characters', () => {
  const value = '界'.repeat(1365) + 'a';
  assert.equal(Buffer.byteLength(value), HEADER_VALUE_LIMIT);
  const { trace, events } = fixture({ headers: { 'user-agent': value } });
  trace.start();
  assert.equal(events[0].headers['user-agent'], value);
  for (const bad of ['x'.repeat(HEADER_VALUE_LIMIT + 1), '界'.repeat(1366),
    'user\ragent', 'user\nagent', 'user\0agent', 123]) {
    rejected({ headers: { 'user-agent': bad } });
  }
});

test('secret replacement cannot expand a header past its per-value byte bound', () => {
  rejected({ headers: { 'user-agent': 'x'.repeat(HEADER_VALUE_LIMIT - 1) + '!' }, secrets: ['!'] });
});

test('the total admitted header budget includes names and fails closed above 16384 bytes', () => {
  const names = ALLOWED_HEADERS.slice(0, 4);
  const nameBytes = names.reduce((total, name) => total + Buffer.byteLength(name), 0);
  const headers = Object.fromEntries(names.map((name, index) => [name,
    'x'.repeat(index < 3 ? HEADER_VALUE_LIMIT : HEADER_LIMIT - nameBytes - 3 * HEADER_VALUE_LIMIT)]));
  assert.equal(Object.entries(headers).reduce((total, [name, value]) =>
    total + Buffer.byteLength(name) + Buffer.byteLength(value), 0), HEADER_LIMIT);
  const { trace, events } = fixture({ headers });
  trace.start();
  assert.deepEqual(events[0].headers, headers);
  rejected({ headers: { ...headers, [names[3]]: headers[names[3]] + 'x' } });
});

test('three attempts get stable distinct IDs and duplicate terminal calls emit nothing more', () => {
  const all = [];
  for (let attempt = 1; attempt <= 3; attempt++) {
    const { trace, events } = fixture({ attempt });
    trace.start();
    trace.receivedStatus([200, 429, 503][attempt - 1]);
    trace.response();
    trace.response();
    trace.error(new Error('late duplicate error'));
    assert.equal(events.length, 2);
    assert.deepEqual(events.map(event => event.phase), ['request', 'response']);
    assert.ok(events.every(event => event.attempt_id === `${REQUEST_ID}:${attempt}` && event.attempt === attempt));
    assert.equal(events[1].status, [200, 429, 503][attempt - 1]);
    assert.equal(events[1].outcome, 'http');
    assert.equal(events[1].error_code, null);
    all.push(...events);
  }
  assert.equal(new Set(all.map(event => event.attempt_id)).size, 3);
  for (const attempt of [0, 4, 1.5]) rejected({ attempt });
});

test('terminal duration includes simulated stream time after HTTP headers arrive', () => {
  const { trace, events, clock } = fixture();
  trace.start();
  clock.ms = 125;
  trace.receivedStatus(202);
  assert.equal(events.length, 1, 'headers must not end the request trace');
  clock.ms = 1125.4567;
  trace.response();
  assert.equal(events[0].duration_ms, null);
  assert.equal(events[1].duration_ms, 1025.457);
  assert.equal(events[1].status, 202);
});

test('errors retain any received status but publish only fixed codes and no raw errors or response headers', () => {
  const secret = 'provider-response-secret';
  const { trace, events, clock } = fixture({ secrets: [secret] });
  trace.start();
  clock.ms = 120;
  trace.receivedStatus(502);
  clock.ms = 910;
  const error = Object.assign(new Error(`socket rejected ${secret}`), {
    code: `UNRECOGNIZED_${secret}`, headers: { 'set-cookie': secret }, status: 401,
  });
  trace.error(error);
  trace.error(error);
  trace.response();
  assert.equal(events.length, 2);
  assert.deepEqual({ phase: events[1].phase, status: events[1].status, duration: events[1].duration_ms,
    outcome: events[1].outcome, code: events[1].error_code },
  { phase: 'error', status: 502, duration: 810, outcome: 'network_error', code: 'PROVIDER_NETWORK_ERROR' });
  assertNoSecrets(events, [secret]);
  assert.equal(JSON.stringify(events).includes('socket rejected'), false);
  assert.equal(JSON.stringify(events).includes('set-cookie'), false);
  assert.deepEqual(Object.keys(events[1]).sort(), ['schema', 'attempt_id', 'attempt', 'provider', 'url',
    'method', 'wire_model', 'headers', 'proxy', 'body', 'body_bytes', 'body_truncated',
    'secrets_redacted', 'phase', 'status', 'duration_ms', 'outcome', 'error_code'].sort());
});

test('cancellation, timeout and protocol failures map to the fixed public error enum', () => {
  const groups = {
    CHAT_CANCELLED: ['NETWORK_CANCELLED', 'CHAT_CANCELLED', 'PROCESS_INTERRUPTED'],
    PROVIDER_TIMEOUT: ['PROXY_TIMEOUT', 'TOTAL_TIMEOUT', 'VM_TIMEOUT'],
    PROVIDER_PROTOCOL_ERROR: ['PROVIDER_PROTOCOL_REJECTED', 'PROVIDER_INVALID_HTTP_STATUS',
      'PROVIDER_RESPONSE_LIMIT', 'PROVIDER_OUTPUT_LIMIT', 'PROVIDER_STREAM_ERROR',
      'PROVIDER_STREAM_INCOMPLETE', 'PROVIDER_TOOL_RESPONSE'],
    PROVIDER_NETWORK_ERROR: ['ECONNRESET', 'unknown', undefined],
  };
  for (const [expected, codes] of Object.entries(groups)) for (const code of codes) {
    const error = { code, message: 'private error text', headers: { authorization: 'private header' } };
    assert.equal(requestTraceErrorCode(error), expected);
    const { trace, events } = fixture();
    trace.start();
    trace.error(error);
    assert.equal(events[1].error_code, expected);
    assert.equal(events[1].status, null);
    assert.equal(events[1].outcome, expected === 'CHAT_CANCELLED' ? 'cancelled' : 'network_error');
    assert.equal(JSON.stringify(events).includes('private'), false);
  }
  assert.equal(requestTraceErrorCode({ code: 'PROXY_TIMEOUT' }, { aborted: true }), 'CHAT_CANCELLED');
});

test('proxy trace admits only the local HTTP CONNECT URL and offline fixtures may omit it', () => {
  for (const proxyURL of ['http://127.0.0.1:1', 'http://127.0.0.1:65535', null]) {
    const { trace, events } = fixture({ network: proxyURL === null ? undefined : { proxyURL } });
    trace.start();
    assert.deepEqual(events[0].proxy, { mode: 'http-connect', url: proxyURL });
  }
  for (const proxyURL of ['https://127.0.0.1:8080', 'http://localhost:8080', 'http://[::1]:8080',
    'http://10.0.0.1:8080', 'http://127.0.0.1:0', 'http://127.0.0.1:65536',
    'http://127.0.0.1:8080/', 'http://127.0.0.1:8080?token=private-token',
    'http://private-token@127.0.0.1:8080', 'http://127.0.0.1:8080/private-token']) {
    rejected({ network: { proxyURL }, secrets: ['private-token'] });
  }
  rejected({ url: `${PROVIDER_URL}?token=private-token`, secrets: ['private-token'] });
  rejected({ secrets: ['http-connect'] });
  rejected({ secrets: [REQUEST_ID] });
});

test('invalid wire JSON, UTF-8 or mismatched request metadata cannot emit partial traces', () => {
  for (const payload of [Buffer.from('{'), Buffer.from('null'), Buffer.from('[]'),
    Buffer.from(JSON.stringify({ model: 'other-model' })), Buffer.from([0xff, 0xfe]), 'not a buffer']) {
    rejected({ payload });
  }
  rejected({ requestID: 'not-a-uuid' });
  rejected({ method: 'GET' });
  rejected({ provider: 'unknown' });
  rejected({ secrets: ['secret', 123] });
});

test('a terminal trace requires start and a response requires a valid received status', () => {
  const { trace, events } = fixture();
  assert.throws(() => trace.response(), { code: 'REQUEST_TRACE_REJECTED' });
  assert.throws(() => trace.error(new Error('not started')), { code: 'REQUEST_TRACE_REJECTED' });
  trace.start();
  assert.throws(() => trace.start(), { code: 'REQUEST_TRACE_REJECTED' });
  for (const invalid of [99, 600, 200.5, '200']) trace.receivedStatus(invalid);
  assert.throws(() => trace.response(), { code: 'REQUEST_TRACE_REJECTED' });
  trace.receivedStatus(204);
  trace.response();
  assert.equal(events.length, 2);
  assert.equal(events[1].status, 204);
});
