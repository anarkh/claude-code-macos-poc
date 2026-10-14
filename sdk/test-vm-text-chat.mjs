import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import { access, mkdir, mkdtemp, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { runVMTextChat } from './vm-text-chat.mjs';
import { SUBSCRIPTION_INPUT, SUBSCRIPTION_SESSION_ID, subscriptionSSE,
  nativeSubscriptionBody, nativeSubscriptionHeaders } from './subscription-test-fixtures.mjs';

const ACK = 'VM_ONLY_TEXT_OK';
const requestID = '22222222-2222-4222-8222-222222222222';
const TRACE_SCHEMA = 'claude-request-trace/v1';
const TRACE_LIMIT = 2_097_152;
const TRACE_HEADERS = ['content-type', 'content-length', 'anthropic-version', 'anthropic-beta',
  'x-app', 'user-agent', 'x-claude-code-session-id', 'anthropic-dangerous-direct-browser-access'];
const deepseek = { ...SUBSCRIPTION_INPUT, provider: 'deepseek-api', model: 'deepseek-flash[1m]',
  apiKey: 'sk-SYNTHETIC-HOST-ONLY-KEY-DO-NOT-SEND-TO-VM' };
delete deepseek.subscriptionToken;

function fixture(input = deepseek, options = {}) {
  const received = [], events = [], outbound = [];
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  const lifecycle = { stopReceiptRead: false, stdoutDestroyedBeforeStop: false, closed: false, launches: 0 };
  const read = child.stdout.read.bind(child.stdout);
  child.stdout.read = size => {
    const chunk = read(size);
    if (chunk?.includes('"kind":"vm_stopped"')) lifecycle.stopReceiptRead = true;
    return chunk;
  };
  let ended = false, pending = '', prompt, requestIndex = 0;
  const responseTexts = options.responseTexts ?? Array(options.requests ?? 1).fill(ACK);
  const send = frame => child.stdout.write(JSON.stringify(frame) + '\n');
  const sendRequest = () => {
    const index = requestIndex++;
    const headers = input.provider === 'claude-subscription' ? nativeSubscriptionHeaders() : {};
    const body = input.provider === 'claude-subscription' ? nativeSubscriptionBody(prompt) : {
      model: input.model, stream: true, tools: [], messages: [{ role: 'user', content: prompt }],
      metadata: { private: 'GUEST_CONTEXT_MUST_NOT_REACH_DEEPSEEK' } };
    if (options.badPrompt) body.messages[0].content = 'REPLACED_PROMPT';
    const request = { kind: 'provider_request', id: requestID.replace(/2$/, String(index + 2)), headers, body };
    send(options.requestChange ? options.requestChange(request, index) : request);
  };
  const finish = () => {
    if (ended) return; ended = true;
    const complete = () => {
      lifecycle.stdoutDestroyedBeforeStop = child.stdout.destroyed;
      if (!options.noStopAck && !options.noStopEOF) send({ kind: 'vm_stopped', cleanup_complete: true, exit_code: 0 });
      if (!options.noStopEOF) child.stdout.end();
      child.stderr.end();
      setImmediate(() => { lifecycle.closed = true; child.emit('close', options.exitCode ?? 0, null); });
    };
    if (options.stopDelayMs) setTimeout(complete, options.stopDelayMs);
    else complete();
  };
  child.kill = () => { finish(); return true; };
  child.stdin = new Writable({ write(chunk, encoding, callback) {
    pending += chunk;
    while (pending.includes('\n')) {
      const index = pending.indexOf('\n'); const frame = JSON.parse(pending.slice(0, index)); pending = pending.slice(index + 1);
      received.push(frame);
      if (frame.kind === 'start') {
        if (options.stall) continue;
        prompt = frame.prompt;
        send({ kind: 'native_init', model: input.provider === 'claude-subscription' ? 'claude-sonnet-5-5' : input.model,
          session_id: SUBSCRIPTION_SESSION_ID, no_tools: options.tools ? false : true });
        if (options.guestError) {
          send({ kind: 'result', ok: false, error_code: options.guestError });
          continue;
        }
        sendRequest();
      } else if (frame.kind === 'provider_end') {
        // A new request starts after the previous host request has left inFlight.
        // The final guest result mirrors the accumulated provider text.
        setImmediate(() => {
          if (ended) return;
          if (requestIndex < (options.requests ?? 1)) sendRequest();
          else send({ kind: 'result', ok: true,
            text: options.badResult ? 'FORGED_RESULT' : responseTexts.join('') });
        });
      }
    }
    callback();
  }, final(callback) { finish(); callback(); } });
  const dependencies = { testOnly: true, timeoutMs: 1000,
    launch: async () => {
      lifecycle.launches++;
      setImmediate(() => {
        send({ kind: 'vm_config', network_devices: options.nic ? 1 : 0, directory_shares: 0, socket_devices: 1 });
        if (options.malformedGuest) child.stdout.write('{"kind":"ready"\n');
        else send({ kind: 'ready' });
      }); return child;
    }, transport: async parameters => {
      outbound.push(parameters);
      const index = outbound.length - 1;
      return options.providerChange ? options.providerChange(parameters, index) : {
        ...subscriptionSSE(responseTexts[index]), statusCode: options.httpStatus ?? 200 };
    }, ...(options.signal ? { signal: options.signal } : {}),
    ...(options.emitTrace === undefined ? {} : { emitTrace: options.emitTrace }),
    ...(options.stopDrainTimeoutMs ? { stopDrainTimeoutMs: options.stopDrainTimeoutMs } : {}) };
  return { child, lifecycle, received, events, outbound, dependencies,
    run: () => runVMTextChat(input, event => events.push(structuredClone(event)), dependencies, options.runtimeRoot) };
}

const traceEvents = f => f.events.filter(event => event.type === 'request_trace');
function assertTraceShape(event, input) {
  assert.equal(event.schema, 'deepseek-text-chat-event/v1');
  assert.equal(event.request_id, input.request_id);
  assert.equal(event.model, input.model);
  const trace = event.trace;
  assert.deepEqual(Object.keys(trace).sort(), ['schema', 'attempt_id', 'attempt', 'phase', 'provider', 'url',
    'method', 'wire_model', 'headers', 'proxy', 'body', 'body_bytes', 'body_truncated', 'secrets_redacted',
    'status', 'duration_ms', 'outcome', 'error_code'].sort());
  assert.equal(trace.schema, TRACE_SCHEMA);
  assert.ok(Number.isInteger(trace.attempt) && trace.attempt >= 1 && trace.attempt <= 3);
  assert.equal(trace.attempt_id, `${input.request_id}:${trace.attempt}`);
  assert.ok(['request', 'response', 'error'].includes(trace.phase));
  assert.equal(trace.provider, input.provider);
  assert.equal(trace.url, input.provider === 'claude-subscription' ?
    'https://api.anthropic.com/v1/messages?beta=true' : 'https://api.deepseek.com/anthropic/v1/messages');
  assert.equal(trace.method, 'POST');
  assert.equal(trace.wire_model, input.provider === 'claude-subscription' ? 'claude-sonnet-5-5' : 'deepseek-flash');
  assert.deepEqual(trace.proxy, { mode: 'http-connect', url: input.network.proxyURL });
  assert.ok(trace.headers && typeof trace.headers === 'object' && !Array.isArray(trace.headers));
  assert.ok(Object.keys(trace.headers).every(name => TRACE_HEADERS.includes(name)));
  assert.ok(Object.values(trace.headers).every(value => typeof value === 'string' && Buffer.byteLength(value) <= 4096));
  assert.ok(Buffer.byteLength(JSON.stringify(trace.headers)) <= 16384);
  assert.equal(typeof trace.body, 'string');
  assert.ok(Buffer.byteLength(trace.body) <= TRACE_LIMIT);
  assert.doesNotThrow(() => JSON.parse(trace.body));
  assert.ok(Number.isInteger(trace.body_bytes) && trace.body_bytes > 0 && trace.body_bytes <= TRACE_LIMIT);
  assert.equal(trace.body_truncated, false);
  assert.equal(typeof trace.secrets_redacted, 'boolean');
  assert.ok(trace.status === null || Number.isInteger(trace.status) && trace.status >= 100 && trace.status <= 599);
  assert.ok(trace.duration_ms === null || Number.isFinite(trace.duration_ms) && trace.duration_ms >= 0);
  assert.ok([null, 'http', 'network_error', 'cancelled'].includes(trace.outcome));
  assert.ok([null, 'PROVIDER_NETWORK_ERROR', 'PROVIDER_TIMEOUT', 'CHAT_CANCELLED', 'PROVIDER_PROTOCOL_ERROR'].includes(trace.error_code));
  return trace;
}

function assertAttempt(f, input, attempt = 1, finalPhase = 'response') {
  const events = traceEvents(f).filter(event => event.trace.attempt === attempt);
  assert.equal(events.length, 2, 'each outbound attempt has one request and one final trace');
  const [request, final] = events.map(event => assertTraceShape(event, input));
  assert.equal(request.phase, 'request');
  assert.equal(request.status, null); assert.equal(request.duration_ms, null);
  assert.equal(request.outcome, null); assert.equal(request.error_code, null);
  assert.equal(final.phase, finalPhase);
  assert.ok(Number.isFinite(final.duration_ms) && final.duration_ms >= 0);
  for (const field of ['attempt_id', 'attempt', 'provider', 'url', 'method', 'wire_model', 'headers',
    'proxy', 'body', 'body_bytes', 'body_truncated', 'secrets_redacted']) {
    assert.deepEqual(final[field], request[field], `${field} stays attached to the same attempt`);
  }
  return { request, final };
}

test('host-only credentials and history; VM gets latest prompt and locale only', async () => {
  const f = fixture(); const terminal = await f.run();
  assert.equal(terminal.type, 'completed'); assert.equal(terminal.text, ACK);
  const start = f.received.find(frame => frame.kind === 'start');
  assert.deepEqual(Object.keys(start).sort(), ['kind', 'model', 'prompt', 'provider', 'runtime']);
  assert.equal(start.prompt, deepseek.messages.at(-1).text);
  assert.equal(JSON.stringify(f.received).includes(deepseek.apiKey), false);
  assert.equal(JSON.stringify(f.received).includes('Earlier answer'), false);
  assert.deepEqual(f.outbound[0].body.messages, deepseek.messages.map(({ role, text }) => ({ role, content: text })));
  assert.equal('metadata' in f.outbound[0].body, false);
  assert.equal(f.outbound[0].apiKey, deepseek.apiKey);
  assert.equal(f.events.map(e => e.text ?? '').join('').includes('GUEST_CONTEXT'), false);
});
test('subscription token stays host and bounded identity passes existing protocol', async () => {
  const f = fixture(SUBSCRIPTION_INPUT); const terminal = await f.run();
  assert.equal(terminal.type, 'completed');
  assert.equal(JSON.stringify(f.received).includes(SUBSCRIPTION_INPUT.subscriptionToken), false);
  assert.equal(f.outbound[0].subscriptionToken, SUBSCRIPTION_INPUT.subscriptionToken);
  assert.equal('x-untrusted-header' in f.outbound[0].headers, false);
  assert.equal(JSON.stringify(f.outbound[0].body).includes('/private/temporary'), false);
});
for (const [name, options, code] of [
  ['NIC configured', { nic: true }, 'VM_ISOLATION_REJECTED'],
  ['tools enabled', { tools: true }, 'NO_TOOLS_CONTRACT'],
  ['prompt replaced', { badPrompt: true }, 'CLI_REQUEST_REJECTED'],
  ['guest forged answer', { badResult: true }, 'CLI_TEXT_MISMATCH'],
  ['missing VM stop receipt', { noStopAck: true }, 'VM_CLEANUP_FAILED'],
  ['launcher failed after receipt', { exitCode: 2 }, 'VM_CLEANUP_FAILED'],
  ['upstream authorization failure', { httpStatus: 401 }, 'PROVIDER_HTTP_401'],
]) test(name + ' fails closed', async () => {
  const f = fixture(deepseek, options); const terminal = await f.run();
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, code);
  assert.equal(f.events.some(e => e.type === 'completed'), false);
});
test('cancellation closes VM channel and waits cleanup', async () => {
  const controller = new AbortController(); const f = fixture(deepseek, { stall: true, signal: controller.signal });
  const promise = f.run(); setTimeout(() => controller.abort(), 20);
  const terminal = await promise;
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'PROCESS_INTERRUPTED');
  assert.equal(f.received.some(frame => frame.kind === 'cancel'), true);
  assert.equal(f.outbound.length, 0);
});
test('legal guest error waits for stop receipt and close, then removes owned data', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'vm-chat-guest-error-test-'));
  const f = fixture(SUBSCRIPTION_INPUT, { guestError: 'SUBSCRIPTION_PROTOCOL_REJECTED', stopDelayMs: 20 });
  f.child.vmOwnedRun = { directory };
  try {
    await writeFile(path.join(directory, 'synthetic-guest-data'), 'synthetic only');
    const terminal = await f.run();
    assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'SUBSCRIPTION_PROTOCOL_REJECTED');
    assert.deepEqual(f.events.filter(event => ['completed', 'error'].includes(event.type)), [
      { ...terminal, request_id: SUBSCRIPTION_INPUT.request_id, model: SUBSCRIPTION_INPUT.model },
    ]);
    assert.equal(f.received.filter(frame => frame.kind === 'cancel').length, 1);
    assert.equal(f.lifecycle.stdoutDestroyedBeforeStop, false);
    assert.equal(f.lifecycle.stopReceiptRead, true); assert.equal(f.lifecycle.closed, true);
    assert.equal(f.outbound.length, 0);
    await assert.rejects(access(directory), { code: 'ENOENT' });
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test('legal guest error with no stdout EOF is bounded and retains its error', { timeout: 1000 }, async () => {
  const f = fixture(SUBSCRIPTION_INPUT, { guestError: 'SUBSCRIPTION_PROTOCOL_REJECTED',
    noStopEOF: true, stopDrainTimeoutMs: 30 });
  const terminal = await f.run();
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'SUBSCRIPTION_PROTOCOL_REJECTED');
  assert.equal(f.events.filter(event => ['completed', 'error'].includes(event.type)).length, 1);
  assert.equal(f.lifecycle.stopReceiptRead, false); assert.equal(f.lifecycle.closed, true);
  assert.equal(f.child.stdout.destroyed, true); assert.equal(f.outbound.length, 0);
});
test('malformed guest frame before native initialization fails closed', async () => {
  const f = fixture(deepseek, { malformedGuest: true }); const terminal = await f.run();
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'VM_PROTOCOL_REJECTED');
  assert.equal(f.outbound.length, 0); assert.equal(f.events.some(event => event.type === 'completed'), false);
});
test('invalid runtime rejected before any VM launch', async () => {
  let launches = 0; const events = [];
  const terminal = await runVMTextChat({ ...deepseek, runtime: { ...deepseek.runtime, timeZone: 'Not/AZone' } },
    event => events.push(event), {
    testOnly: true, launch: async () => { launches++; }, transport: async () => {},
  });
  assert.equal(terminal.type, 'error'); assert.equal(launches, 0);
  assert.equal(events.some(event => event.type === 'request_trace'), false);
});

test('trace contains the final DeepSeek wire body and headers before transport, then records completed SSE', async () => {
  const f = fixture(deepseek, { providerChange: async () => {
    assert.equal(traceEvents(f).length, 1);
    assert.equal(traceEvents(f)[0].trace.phase, 'request');
    return subscriptionSSE(ACK);
  } });
  const terminal = await f.run();
  assert.equal(terminal.type, 'completed');
  const { request, final } = assertAttempt(f, deepseek);
  const serialized = JSON.stringify(f.outbound[0].body);
  assert.equal(request.body, serialized);
  assert.equal(request.body_bytes, Buffer.byteLength(serialized));
  assert.equal(request.secrets_redacted, false);
  assert.deepEqual(request.headers, { 'content-type': 'application/json',
    'content-length': String(Buffer.byteLength(serialized)), 'anthropic-version': '2023-06-01' });
  const body = JSON.parse(request.body);
  assert.equal(body.model, 'deepseek-flash');
  assert.deepEqual(body.messages, deepseek.messages.map(({ role, text }) => ({ role, content: text })));
  assert.equal(body.system, f.outbound[0].body.system);
  assert.ok(body.system.includes(deepseek.text_skills[0].content));
  assert.equal(request.body.includes('GUEST_CONTEXT_MUST_NOT_REACH_DEEPSEEK'), false);
  assert.equal(final.status, 200); assert.equal(final.outcome, 'http'); assert.equal(final.error_code, null);
  const finalIndex = f.events.findIndex(event => event.type === 'request_trace' && event.trace.phase === 'response');
  const lastDelta = f.events.findLastIndex(event => event.type === 'delta');
  assert.ok(finalIndex > lastDelta, 'response trace is emitted after SSE has completed');
  assert.ok(finalIndex < f.events.findIndex(event => event.type === 'completed'));
});

test('known API keys pasted into history and skill text are masked without altering other final body fields', async () => {
  const input = { ...deepseek, messages: [
    { role: 'user', text: `Earlier key: ${deepseek.apiKey}; keep this context.` },
    { role: 'assistant', text: 'Earlier answer with 普通内容.' },
    { role: 'user', text: `Current key: ${deepseek.apiKey}; keep 🧑‍💻 and newlines.\n` },
  ], text_skills: [{ name: 'Credential fixture', content: `Do not repeat ${deepseek.apiKey}; explain in 中文.` }] };
  const f = fixture(input); const terminal = await f.run();
  assert.equal(terminal.type, 'completed');
  const { request } = assertAttempt(f, input);
  const serialized = JSON.stringify(f.outbound[0].body);
  assert.equal(request.body, serialized.split(input.apiKey).join('[REDACTED]'));
  assert.equal(request.body_bytes, Buffer.byteLength(serialized));
  assert.equal(request.secrets_redacted, true);
  assert.equal(request.headers['content-length'], String(Buffer.byteLength(serialized)));
  assert.equal(JSON.stringify(f.events).includes(input.apiKey), false);
  assert.equal(f.outbound[0].body.messages[0].content, input.messages[0].text);
});

test('a known API key containing JSON escapes stays masked and the trace body remains valid JSON', async () => {
  const key = 'sk-SYNTHETIC-"QUOTED"-\\BACKSLASH-KEY-NOT-VALID';
  const input = { ...deepseek, apiKey: key,
    messages: [{ role: 'user', text: `Do not echo ${key}; preserve "ordinary quotes" and \\paths.` }] };
  const f = fixture(input); const terminal = await f.run();
  assert.equal(terminal.type, 'completed');
  const { request } = assertAttempt(f, input);
  const serialized = JSON.stringify(f.outbound[0].body);
  const escapedKey = JSON.stringify(key).slice(1, -1);
  assert.equal(request.body, serialized.split(escapedKey).join('[REDACTED]').split(key).join('[REDACTED]'));
  assert.equal(JSON.parse(request.body).messages[0].content,
    'Do not echo [REDACTED]; preserve "ordinary quotes" and \\paths.');
  assert.equal(request.secrets_redacted, true);
  assert.equal(JSON.stringify(f.events).includes(escapedKey), false);
});

test('subscription trace keeps validated billing identity and headers while excluding tokens and private native context', async () => {
  const identity = { device_id: 'a1'.repeat(32), account_uuid: '44444444-4444-4444-8444-444444444444',
    session_id: SUBSCRIPTION_SESSION_ID };
  const input = { ...SUBSCRIPTION_INPUT, messages: [{ role: 'user',
    text: `Token pasted as context: ${SUBSCRIPTION_INPUT.subscriptionToken}; keep this wording.` }] };
  const f = fixture(input, { requestChange: request => {
    request.body.metadata.user_id = JSON.stringify(identity);
    request.headers['x-untrusted-header'] = input.subscriptionToken;
    request.headers['x-api-key'] = input.subscriptionToken;
    return request;
  } });
  const terminal = await f.run(); assert.equal(terminal.type, 'completed');
  const { request, final } = assertAttempt(f, input);
  const serialized = JSON.stringify(f.outbound[0].body);
  assert.equal(request.body, serialized.split(input.subscriptionToken).join('[REDACTED]'));
  assert.equal(request.body_bytes, Buffer.byteLength(serialized));
  const body = JSON.parse(request.body);
  assert.equal(body.metadata.user_id, JSON.stringify(identity));
  assert.deepEqual(JSON.parse(body.metadata.user_id), identity);
  assert.equal(body.system[0].text, nativeSubscriptionBody('').system[0].text);
  assert.equal(body.system[1].text, nativeSubscriptionBody('').system[1].text);
  const headers = nativeSubscriptionHeaders();
  const expectedHeaders = Object.fromEntries(TRACE_HEADERS.filter(name => name in headers).map(name => [name, headers[name]]));
  assert.deepEqual(request.headers, { ...expectedHeaders, 'content-type': 'application/json',
    'content-length': String(Buffer.byteLength(serialized)) });
  assert.equal('authorization' in request.headers, false); assert.equal('x-api-key' in request.headers, false);
  assert.equal('x-untrusted-header' in request.headers, false); assert.equal('x-stainless-os' in request.headers, false);
  assert.equal(request.body.includes('/private/temporary'), false);
  assert.equal(JSON.stringify(f.events).includes(input.subscriptionToken), false);
  assert.equal(final.status, 200); assert.equal(final.outcome, 'http');
});

test('a valid escaped Unicode body larger than 256 KiB is preserved as complete JSON within the 2 MiB trace limit', async () => {
  const input = { ...deepseek, messages: [{ role: 'user', text: '\u0001'.repeat(43_600) + '🧑‍💻'.repeat(1000) }] };
  const f = fixture(input); const terminal = await f.run();
  assert.equal(terminal.type, 'completed');
  const { request } = assertAttempt(f, input);
  const serialized = JSON.stringify(f.outbound[0].body);
  assert.ok(Buffer.byteLength(serialized) > 262_144);
  assert.equal(request.body, serialized);
  assert.equal(request.body_bytes, Buffer.byteLength(serialized));
  assert.equal(request.body_truncated, false);
  assert.equal(JSON.parse(request.body).messages[0].content, input.messages[0].text);
});

test('non-200 HTTP responses end the same trace attempt with the returned status', async () => {
  const f = fixture(deepseek, { httpStatus: 401 }); const terminal = await f.run();
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'PROVIDER_HTTP_401');
  const { final } = assertAttempt(f, deepseek);
  assert.equal(final.status, 401); assert.equal(final.outcome, 'http'); assert.equal(final.error_code, null);
  assert.equal(f.events.some(event => event.type === 'delta'), false);
});

for (const [name, transportCode, traceCode] of [
  ['private network failure', 'PROXY_REQUEST_FAILED', 'PROVIDER_NETWORK_ERROR'],
  ['proxy timeout', 'PROXY_TIMEOUT', 'PROVIDER_TIMEOUT'],
]) test(`${name} ends the attempt with a stable trace error and no private diagnostics`, async () => {
  const f = fixture(deepseek, { providerChange: async () => {
    const error = new Error(`PRIVATE_DIAGNOSTIC ${deepseek.apiKey}`); error.code = transportCode; throw error;
  } });
  const terminal = await f.run(); assert.equal(terminal.type, 'error');
  const { final } = assertAttempt(f, deepseek, 1, 'error');
  assert.equal(final.status, null); assert.equal(final.outcome, 'network_error'); assert.equal(final.error_code, traceCode);
  assert.equal(JSON.stringify(f.events).includes('PRIVATE_DIAGNOSTIC'), false);
  assert.equal(JSON.stringify(f.events).includes(deepseek.apiKey), false);
});

test('cancellation after a request trace ends that attempt and waits for VM cleanup', async () => {
  const controller = new AbortController();
  const f = fixture(deepseek, { signal: controller.signal, providerChange: ({ signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => {
      const error = new Error(`PRIVATE_CANCEL ${deepseek.apiKey}`); error.code = 'NETWORK_CANCELLED'; reject(error);
    }, { once: true });
    queueMicrotask(() => controller.abort());
  }) });
  const terminal = await f.run(); assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'PROCESS_INTERRUPTED');
  const { final } = assertAttempt(f, deepseek, 1, 'error');
  assert.equal(final.status, null); assert.equal(final.outcome, 'cancelled'); assert.equal(final.error_code, 'CHAT_CANCELLED');
  assert.equal(f.outbound.length, 1);
  assert.equal(f.received.filter(frame => frame.kind === 'cancel').length, 1);
  assert.equal(f.lifecycle.closed, true);
  assert.equal(JSON.stringify(f.events).includes('PRIVATE_CANCEL'), false);
});

test('late SSE protocol failure emits only a final error trace and retains HTTP 200', async () => {
  const f = fixture(deepseek, { providerChange: async () => ({ statusCode: 200, contentType: 'text/event-stream',
    stream: (async function* () {
      for await (const chunk of subscriptionSSE(ACK).stream) yield chunk;
      yield Buffer.from('event: error\ndata: {"type":"error"}\n\n');
    })() }) });
  const terminal = await f.run(); assert.equal(terminal.type, 'error');
  const { final } = assertAttempt(f, deepseek, 1, 'error');
  assert.equal(final.status, 200); assert.equal(final.outcome, 'network_error');
  assert.equal(final.error_code, 'PROVIDER_PROTOCOL_ERROR');
  assert.equal(f.events.filter(event => event.type === 'delta').map(event => event.text).join(''), ACK);
  assert.equal(traceEvents(f).some(event => event.trace.phase === 'response'), false);
});

test('premature SSE EOF is a protocol error on the attempt whose HTTP 200 was already received', async () => {
  const f = fixture(deepseek, { providerChange: async () => ({ statusCode: 200, contentType: 'text/event-stream',
    stream: (async function* () {
      yield Buffer.from('event: message_start\ndata: {"type":"message_start","message":{"type":"message","role":"assistant","content":[]}}\n\n');
    })() }) });
  const terminal = await f.run(); assert.equal(terminal.type, 'error');
  const { final } = assertAttempt(f, deepseek, 1, 'error');
  assert.equal(final.status, 200); assert.equal(final.outcome, 'network_error');
  assert.equal(final.error_code, 'PROVIDER_PROTOCOL_ERROR');
});

test('three sequential VM requests have separate attempt IDs and one final trace each', async () => {
  const texts = ['FIRST_中文', 'SECOND_日本語', 'THIRD_🧑‍💻'];
  const f = fixture(deepseek, { requests: 3, responseTexts: texts }); const terminal = await f.run();
  assert.equal(terminal.type, 'completed'); assert.equal(terminal.request_count, 3);
  assert.equal(terminal.text, texts.join('')); assert.equal(f.outbound.length, 3);
  const events = traceEvents(f);
  assert.equal(events.length, 6);
  assert.deepEqual(events.map(event => [event.trace.attempt_id, event.trace.phase]), [1, 2, 3].flatMap(attempt =>
    ['request', 'response'].map(phase => [`${deepseek.request_id}:${attempt}`, phase])));
  for (let attempt = 1; attempt <= 3; attempt++) {
    const { final } = assertAttempt(f, deepseek, attempt);
    assert.equal(final.status, 200); assert.equal(final.outcome, 'http');
  }
  const endIDs = f.received.filter(frame => frame.kind === 'provider_end').map(frame => frame.id);
  assert.equal(new Set(endIDs).size, 3);
  assert.deepEqual(f.received.filter(frame => frame.kind === 'provider_response').map(frame => frame.id), endIDs);
});

test('a fourth VM request is rejected before transport and does not allocate an extra trace attempt', async () => {
  const f = fixture(deepseek, { requests: 4 }); const terminal = await f.run();
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'VM_REQUEST_REJECTED');
  assert.equal(f.outbound.length, 3); assert.equal(traceEvents(f).length, 6);
  assert.deepEqual([...new Set(traceEvents(f).map(event => event.trace.attempt))], [1, 2, 3]);
});

for (const [name, input, options] of [
  ['isolation rejection', deepseek, { nic: true }],
  ['native no-tools rejection', deepseek, { tools: true }],
  ['replaced prompt rejection', deepseek, { badPrompt: true }],
  ['subscription identity rejection', SUBSCRIPTION_INPUT, { requestChange: request => ({ ...request,
    headers: { ...request.headers, 'x-claude-code-session-id': '44444444-4444-4444-8444-444444444444' } }) }],
]) test(`${name} emits no trace before an accepted provider request`, async () => {
  const f = fixture(input, options); const terminal = await f.run();
  assert.equal(terminal.type, 'error'); assert.equal(f.outbound.length, 0);
  assert.equal(traceEvents(f).length, 0);
});

test('test-only health probing can omit trace events while preserving the VM text chat result', async () => {
  const f = fixture(deepseek, { emitTrace: false }); const terminal = await f.run();
  assert.equal(terminal.type, 'completed'); assert.equal(terminal.text, ACK);
  assert.equal(terminal.request_count, 1); assert.equal(f.outbound.length, 1);
  assert.deepEqual(f.outbound[0].body.messages, deepseek.messages.map(({ role, text }) => ({ role, content: text })));
  assert.equal(traceEvents(f).length, 0);
  assert.ok(f.events.every(event => ['started', 'delta', 'completed'].includes(event.type)));
  assert.equal(f.lifecycle.stopReceiptRead, true); assert.equal(f.lifecycle.closed, true);
});

for (const kind of ['relative root', 'missing root', 'missing module', 'missing exports', 'symlink root']) {
  test(`active runtime ${kind} is rejected before any VM launch or trace`, async () => {
    const directory = await realpath(await mkdtemp(path.join(os.tmpdir(), 'vm-chat-runtime-root-test-')));
    try {
      let runtimeRoot = directory;
      if (kind === 'relative root') runtimeRoot = 'relative-runtime-root';
      else if (kind === 'missing root') runtimeRoot = path.join(directory, 'missing');
      else if (kind === 'missing exports') {
        await mkdir(path.join(directory, 'sdk'));
        await writeFile(path.join(directory, 'sdk/deepseek-text-chat.mjs'), 'export function providerBody() {}\n');
      } else if (kind === 'symlink root') {
        const selected = path.join(directory, 'selected');
        await mkdir(path.join(selected, 'sdk'), { recursive: true });
        await writeFile(path.join(selected, 'sdk/deepseek-text-chat.mjs'),
          'export function providerBody() {}\nexport function subscriptionHeaders() {}\n');
        runtimeRoot = path.join(directory, 'linked'); await symlink(selected, runtimeRoot);
      }
      const f = fixture(deepseek, { runtimeRoot }); const terminal = await f.run();
      assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'VM_RUNTIME_INVALID');
      assert.equal(f.lifecycle.launches, 0); assert.equal(f.outbound.length, 0);
      assert.equal(traceEvents(f).length, 0);
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
}

test('an injected active runtime uses its admission helper and fails without falling back to bundled helpers', async () => {
  const directory = await realpath(await mkdtemp(path.join(os.tmpdir(), 'vm-chat-runtime-helper-test-')));
  try {
    await mkdir(path.join(directory, 'sdk'));
    await writeFile(path.join(directory, 'sdk/deepseek-text-chat.mjs'), [
      'export function providerBody() {',
      "  const error = new Error('Synthetic runtime admission failure');",
      "  error.code = 'ACTIVE_RUNTIME_BODY_REJECTED'; throw error;",
      '}',
      'export function subscriptionHeaders(headers) { return headers; }',
    ].join('\n'));
    const f = fixture(deepseek, { runtimeRoot: directory }); const terminal = await f.run();
    assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'ACTIVE_RUNTIME_BODY_REJECTED');
    assert.equal(f.lifecycle.launches, 1); assert.equal(f.outbound.length, 0);
    assert.equal(traceEvents(f).length, 0); assert.equal(f.lifecycle.closed, true);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
