// Fake SDK, process and provider tests. Only the ephemeral loopback frontend is
// real. No native CLI, sandbox, Keychain, authentication or provider runs.
import assert from 'node:assert/strict';
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { spawn as spawnNode } from 'node:child_process';
import { access } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { runDeepSeekTextChat } from './deepseek-text-chat.mjs';

const KEY = 'FAKE-only-DeepSeek-chat-provider-key-NOT-VALID';
const SHA = 'd'.repeat(64);
const REQUEST_ID = '48bcdcf4-107d-4c91-9eae-43acbecc46ca';
const SCHEMA = 'deepseek-text-chat/v1';
const EVENT_SCHEMA = 'deepseek-text-chat-event/v1';
const NETWORK = { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:7890', dnsPolicy: 'proxy-only' };
const RUNTIME = { schema: 'app-runtime-profile/v1', timeZone: 'Asia/Tokyo', language: 'ja' };
const INPUT = { schema: SCHEMA, request_id: REQUEST_ID, apiKey: KEY, model: 'deepseek-flash[1m]',
  messages: [{ role: 'user', text: '请解释这句话。\n' }, { role: 'assistant', text: 'Previous response.\n' },
    { role: 'user', text: '继续：日本語と中文  \n' }] };
const PARTS = ['  中文', 'と日本語', '\n', ' emoji 🧑‍💻  ', '\n\n'];
const RAW_TEXT = PARTS.join('');
let checks = 0;
async function check(name, fn) { await fn(); checks++; process.stdout.write(`PASS ${name}\n`); }

function sseResponse({ parts = PARTS, status = 200, framesChange, contentType = 'text/event-stream',
  bytesPerChunk = 3, outputTokens = 19 } = {}) {
  let frames = [
    ['message_start', { type: 'message_start', message: { id: 'fake-response', type: 'message', role: 'assistant',
      model: 'deepseek-flash', content: [], usage: { input_tokens: 23, output_tokens: 0 } } }],
    ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
    ...parts.map(text => ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } }]),
    ['content_block_stop', { type: 'content_block_stop', index: 0 }],
    ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: outputTokens } }],
    ['message_stop', { type: 'message_stop' }],
  ];
  if (framesChange) frames = framesChange(frames);
  const bytes = Buffer.from(frames.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join(''));
  return { statusCode: status, contentType, stream: (async function* () {
    for (let index = 0; index < bytes.length; index += bytesPerChunk) yield bytes.subarray(index, index + bytesPerChunk);
  })() };
}

async function requestLocal(baseURL, { token, route = '/v1/messages?beta=true', body, method = 'POST' }) {
  const bytes = Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  return await new Promise((resolve, reject) => {
    const request = http.request(new URL(route, baseURL), { method,
      headers: { 'x-api-key': token, 'content-type': 'application/json', 'content-length': bytes.length } }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.once('error', reject);
      response.once('end', () => resolve({ status: response.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
    });
    request.once('error', reject);
    request.end(bytes);
  });
}

function fixture({ requests = 1, requestChange, providerChange, initChange, resultChange, assistantChange,
  sdkTool = false, missingInit = false, duplicateInit = false, missingSpawn = false, exitCode = 0,
  queryError = false, iterationError = false, transportError = false, beforeInitRequest = false,
  blockedUntilAbort = false, timeoutMs, text = RAW_TEXT, diagnostic = null } = {}) {
  const observed = { launches: [], upstream: [], local: [], query: null, cwd: null, closed: 0 };
  let child;
  let closed = false;
  const dependencies = {
    testOnly: true, cliPath: '/fake/official-native-cli', cliSha256: SHA,
    ...(timeoutMs === undefined ? {} : { timeoutMs }),
    spawn(command, args, options) {
      observed.launches.push({ command, args, options });
      observed.profile = readFileSync(args[1], 'utf8');
      child = new EventEmitter();
      child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
      return child;
    },
    async transport(parameters) {
      observed.upstream.push(parameters);
      if (transportError) throw new Error(`private transport diagnostic ${KEY}`);
      return providerChange ? providerChange(parameters) : sseResponse({ parts: [text.slice(0, 4), text.slice(4)] });
    },
    query({ prompt, options }) {
      if (queryError) throw new Error(`private query diagnostic ${KEY}`);
      observed.query = { prompt, options }; observed.cwd = options.cwd;
      if (!missingSpawn) options.spawnClaudeCodeProcess({ command: dependencies.cliPath, cwd: options.cwd,
        args: ['--setting-sources=', '--tools', ''], env: options.env, signal: options.abortController.signal });
      const submit = async index => {
        const request = { token: options.env.ANTHROPIC_API_KEY,
          body: { model: options.model.replace('[1m]', ''), stream: true, max_tokens: 32768,
            system: `discard-native-context:${options.cwd}`, tools: [],
            messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] }] } };
        observed.local.push(await requestLocal(options.env.ANTHROPIC_BASE_URL,
          requestChange ? requestChange(request, index) : request));
      };
      async function* events() {
        if (diagnostic) child?.stderr.write(diagnostic);
        if (iterationError) throw new Error(`private iteration diagnostic ${KEY}`);
        if (beforeInitRequest) await submit(0);
        const init = { type: 'system', subtype: 'init', claude_code_version: '2.1.295', cwd: options.cwd,
          permissionMode: 'default', tools: [], mcp_servers: [], skills: [], plugins: [] };
        if (!missingInit) yield initChange ? initChange(init) : init;
        if (duplicateInit) yield init;
        if (blockedUntilAbort) {
          await new Promise(resolve => {
            if (options.abortController.signal.aborted) resolve();
            else options.abortController.signal.addEventListener('abort', resolve, { once: true });
          });
          throw new Error(`private abort diagnostic ${KEY}`);
        }
        for (let index = 0; index < requests; index++) await submit(index);
        // SDK deltas must not be rendered a second time; the validated provider
        // parser owns visible incremental text.
        yield { type: 'stream_event', event: { type: 'content_block_delta', index: 0,
          delta: { type: 'text_delta', text: 'SDK delta must not duplicate' } } };
        const assistant = { type: 'assistant', message: { content: [{ type: 'text', text }] } };
        yield assistantChange ? assistantChange(assistant) : assistant;
        if (sdkTool) yield { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'must never run' } }] } };
        const result = { type: 'result', subtype: 'success', is_error: false, result: text.trim(), num_turns: 1 };
        yield resultChange ? resultChange(result) : result;
      }
      const iterator = events();
      iterator.close = () => {
        observed.closed++;
        if (closed) return;
        closed = true;
        if (child) queueMicrotask(() => child.emit('exit', exitCode, null));
      };
      return iterator;
    },
  };
  return { observed, dependencies };
}

async function run(options, input = INPUT) {
  const value = fixture(options);
  const events = [];
  const terminal = await runDeepSeekTextChat(input, event => events.push(structuredClone(event)), value.dependencies);
  assert.equal(JSON.stringify({ terminal, events }).includes(KEY), false, 'events must not expose provider credentials');
  assert.equal(terminal.schema, EVENT_SCHEMA);
  assert.ok(['completed', 'error'].includes(terminal.type));
  assert.deepEqual(events.at(-1), terminal, 'terminal event is emitted after cleanup');
  if (terminal.type === 'completed') {
    assert.equal(terminal.temporary_removed, true); assert.equal(terminal.proxy_closed, true);
    assert.equal(terminal.cli_exit, 0); assert.equal(terminal.cli_signal, null);
  }
  if (value.observed.cwd) await assert.rejects(access(value.observed.cwd), { code: 'ENOENT' });
  for (const event of events) {
    assert.equal(event.schema, EVENT_SCHEMA);
    assert.ok(['started', 'delta', 'completed', 'error', 'request_trace'].includes(event.type));
  }
  return { ...value, terminal, events };
}

await check('multi-turn history is rebuilt for the provider while CLI sees only latest user text', async () => {
  const { terminal, observed, events } = await run();
  assert.equal(terminal.type, 'completed'); assert.equal(terminal.no_tools, true);
  assert.equal(terminal.text, RAW_TEXT); assert.equal(terminal.request_count, 1);
  assert.equal(observed.query.prompt, INPUT.messages.at(-1).text);
  const body = observed.upstream[0].body;
  assert.deepEqual(body.messages, INPUT.messages.map(({ role, text }) => ({ role, content: text })));
  assert.equal(body.model, 'deepseek-flash'); assert.equal(body.max_tokens, 4096);
  assert.equal(body.stream, true); assert.deepEqual(body.tools, []); assert.deepEqual(body.thinking, { type: 'disabled' });
  assert.equal(JSON.stringify(body).includes(observed.cwd), false);
  const traces = events.filter(event => event.type === 'request_trace');
  assert.deepEqual(traces.map(event => event.trace.phase), ['request', 'response']);
  for (const { trace } of traces) {
    assert.equal(trace.body, JSON.stringify(body));
    assert.equal(trace.body_bytes, Buffer.byteLength(JSON.stringify(body)));
    assert.equal(trace.wire_model, 'deepseek-flash');
    assert.equal(trace.url, 'https://api.deepseek.com/anthropic/v1/messages');
    assert.equal(trace.method, 'POST');
    assert.equal(trace.attempt_id, `${REQUEST_ID}:1`);
    assert.equal(trace.headers.authorization, undefined);
    assert.equal(trace.headers['x-api-key'], undefined);
    assert.equal(trace.headers['content-length'], String(trace.body_bytes));
  }
  assert.equal(traces[1].trace.status, 200);
  assert.ok(traces[1].trace.duration_ms >= 0);
});
await check('user-pasted credential is masked only in trace and original provider body is sent', async () => {
  const input = { ...INPUT, messages: [{ role: 'user', text: `Compare ${KEY} with literal [REDACTED].` }] };
  const { observed, events, terminal } = await run(undefined, input);
  assert.equal(terminal.type, 'completed');
  assert.equal(observed.upstream[0].body.messages[0].content, input.messages[0].text);
  const traces = events.filter(event => event.type === 'request_trace');
  assert.equal(traces.length, 2);
  for (const { trace } of traces) {
    assert.equal(trace.secrets_redacted, true);
    assert.equal(trace.body_truncated, false);
    assert.equal(JSON.parse(trace.body).messages[0].content, 'Compare [REDACTED] with literal [REDACTED].');
  }
});
await check('transport failure trace is finite and excludes raw diagnostics', async () => {
  const { events, terminal } = await run({ transportError: true });
  assert.equal(terminal.type, 'error');
  const traces = events.filter(event => event.type === 'request_trace');
  assert.deepEqual(traces.map(event => event.trace.phase), ['request', 'error']);
  assert.equal(traces[1].trace.status, null);
  assert.equal(traces[1].trace.error_code, 'PROVIDER_NETWORK_ERROR');
  assert.equal(traces[1].trace.outcome, 'network_error');
  assert.equal(JSON.stringify(traces).includes('private transport diagnostic'), false);
});
await check('explicit network policy is forwarded and malformed policy rejects before native initialization', async () => {
  const accepted = await run(undefined, { ...INPUT, network: NETWORK });
  assert.equal(accepted.terminal.type, 'completed');
  assert.deepEqual(accepted.observed.upstream[0].network, NETWORK);
  const rejected = await run(undefined, { ...INPUT, network: { ...NETWORK, dnsPolicy: 'direct' } });
  assert.equal(rejected.terminal.code, 'NETWORK_POLICY_INVALID');
  assert.deepEqual(rejected.observed.launches, []);
  assert.deepEqual(rejected.observed.upstream, []);
});
await check('production chat rejects missing network before importing SDK or starting native CLI', async () => {
  const events = [];
  const terminal = await runDeepSeekTextChat(INPUT, event => events.push(event));
  assert.equal(terminal.type, 'error');
  assert.equal(terminal.code, 'NETWORK_POLICY_REQUIRED');
  assert.equal(terminal.text, undefined);
  assert.equal(events.length, 1);
});
await check('Japan fixture default reaches both SDK query and actual spawn environment', async () => {
  const { observed, terminal } = await run();
  assert.equal(terminal.type, 'completed');
  const env = observed.query.options.env;
  assert.equal(env.TZ, 'Asia/Tokyo');
  for (const key of ['LANG', 'LC_ALL', 'LC_MESSAGES']) assert.equal(env[key], 'ja_JP.UTF-8');
  assert.equal(observed.launches[0].options.env, env);
  assert.equal(Object.values(env).includes(KEY), false);
});
await check('configured language and time zone reach native launch without entering provider payload', async () => {
  for (const [timeZone, language, locale] of [['Asia/Tokyo', 'ja', 'ja_JP.UTF-8'],
    ['America/New_York', 'en', 'en_US.UTF-8'], ['UTC', 'zh', 'zh_CN.UTF-8']]) {
    const { observed, terminal } = await run(undefined, { ...INPUT, runtime: { ...RUNTIME, timeZone, language } });
    assert.equal(terminal.type, 'completed');
    const env = observed.query.options.env;
    assert.equal(env.TZ, timeZone);
    for (const key of ['LANG', 'LC_ALL', 'LC_MESSAGES']) assert.equal(env[key], locale);
    assert.equal(observed.launches[0].options.env, env);
    assert.equal(observed.upstream[0].runtime, undefined);
    assert.equal(observed.upstream[0].runtimeProfile, undefined);
    assert.equal(JSON.stringify(observed.upstream[0].body).includes(timeZone), false);
  }
});
await check('malformed profile is refused before SDK query, spawn or provider with fixed safe error', async () => {
  for (const runtime of [{ ...RUNTIME, timeZone: 'asia/tokyo' }, { ...RUNTIME, language: 'ja-JP' },
    { ...RUNTIME, schema: 'other' }, { ...RUNTIME, timeZone: 'GMT+09:00' },
    { ...RUNTIME, apiKey: KEY }, { schema: RUNTIME.schema, timeZone: RUNTIME.timeZone }, []]) {
    const { observed, terminal } = await run(undefined, { ...INPUT, runtime });
    assert.equal(terminal.code, 'RUNTIME_PROFILE_INVALID');
    assert.equal(observed.query, null);
    assert.deepEqual(observed.launches, []);
    assert.deepEqual(observed.upstream, []);
  }
  assert.equal((await run(undefined, { ...INPUT, runtime: null })).terminal.code, 'RUNTIME_PROFILE_REQUIRED');
});
await check('production chat requires profile after valid network before initializing native runtime', async () => {
  const events = [];
  const terminal = await runDeepSeekTextChat({ ...INPUT, network: NETWORK }, event => events.push(event));
  assert.equal(terminal.type, 'error');
  assert.equal(terminal.code, 'RUNTIME_PROFILE_REQUIRED');
  assert.equal(terminal.text, undefined);
  assert.equal(events.length, 1);
});
await check('validated SSE preserves Unicode and whitespace when every UTF8 byte is split', async () => {
  const { events, terminal } = await run({ providerChange: () => sseResponse({ bytesPerChunk: 1 }) });
  assert.equal(events[0].type, 'started'); assert.equal(events[0].no_tools, true);
  const incremental = events.filter(event => event.type === 'delta').map(event => event.text).join('');
  assert.equal(incremental, RAW_TEXT); assert.equal(terminal.text, RAW_TEXT);
  assert.equal(incremental.includes('\uFFFD'), false); assert.equal(incremental.includes('SDK delta'), false);
  for (const event of events) { assert.equal(event.request_id, REQUEST_ID); assert.equal(event.model, INPUT.model); }
});
await check('lightweight selector keeps actual provider model unchanged', async () => {
  const { terminal, observed } = await run(undefined, { ...INPUT, model: 'deepseek-flash' });
  assert.equal(terminal.type, 'completed'); assert.equal(terminal.model, 'deepseek-flash');
  assert.equal(observed.upstream[0].body.model, 'deepseek-flash');
});
await check('CLI feature settings and separate clean environment stay explicit', async () => {
  const { observed } = await run();
  const { options } = observed.query;
  for (const field of ['tools', 'allowedTools', 'plugins', 'skills', 'settingSources']) assert.deepEqual(options[field], []);
  assert.deepEqual(options.mcpServers, {}); assert.deepEqual(options.agents, {});
  assert.equal(options.strictMcpConfig, true); assert.equal(options.persistSession, false); assert.equal(options.maxTurns, 1);
  assert.equal(options.verbatimPrompts, true); assert.deepEqual(options.thinking, { type: 'disabled' });
  assert.deepEqual(options.extraArgs, { 'disable-slash-commands': null });
  assert.equal(options.settings.disableAllHooks, true);
  assert.deepEqual(options.settings.enabledPlugins, { 'cc-plugin-agents-md@builtin': false, 'cc-plugin-plugin-authoring@builtin': false });
  const launch = observed.launches[0];
  assert.equal(launch.command, '/usr/bin/sandbox-exec'); assert.equal(launch.args[2], '/fake/official-native-cli');
  assert.equal(launch.options.detached, true); assert.equal(Object.values(launch.options.env).includes(KEY), false);
  assert.match(launch.options.env.ANTHROPIC_API_KEY, /^[a-f0-9]{64}$/);
  assert.equal(launch.options.env.HTTPS_PROXY, undefined); assert.equal(launch.options.env.ANTHROPIC_AUTH_TOKEN, undefined);
  assert.equal(observed.upstream[0].apiKey, KEY);
  assert.equal(observed.profile.includes('(subpath "/Library/Application Support/ClaudeCode")'), false);
});
await check('input schema, credentials and selectors fail before spawning or provider activity', async () => {
  const inputs = [{ ...INPUT, schema: 'other' }, { ...INPUT, request_id: 'not-a-uuid' }, { ...INPUT, apiKey: '' },
    { ...INPUT, model: 'claude-sonnet-4-6' }, { ...INPUT, endpoint: 'https://untrusted.invalid' },
    { ...INPUT, messages: [] }, { ...INPUT, messages: [{ role: 'user', text: '' }] }];
  for (const input of inputs) {
    const { terminal, observed } = await run(undefined, input);
    assert.equal(terminal.type, 'error'); assert.equal(observed.launches.length, 0); assert.equal(observed.upstream.length, 0);
  }
});
await check('transcript must alternate and start and finish with user; tool and unknown properties are rejected', async () => {
  const histories = [[{ role: 'assistant', text: 'first' }], [{ role: 'user', text: 'one' }, { role: 'assistant', text: 'last' }],
    [{ role: 'user', text: 'one' }, { role: 'user', text: 'two' }], [{ role: 'system', text: 'system' }],
    [{ role: 'tool', text: 'tool' }], [{ role: 'user', text: 'one', extra: KEY }],
    [{ role: 'user', text: 'one', content: [] }], [{ role: 'user', text: 12 }]];
  for (const messages of histories) {
    const { terminal, observed } = await run(undefined, { ...INPUT, messages });
    assert.equal(terminal.type, 'error'); assert.equal(observed.launches.length, 0); assert.equal(observed.upstream.length, 0);
  }
});
await check('message count and total transcript bound apply to UTF8 bytes', async () => {
  const overCount = Array.from({ length: 103 }, (_, index) => ({ role: index % 2 ? 'assistant' : 'user', text: 'x' }));
  for (const messages of [overCount, [{ role: 'user', text: '界'.repeat(43_691) }]]) {
    const { terminal, observed } = await run(undefined, { ...INPUT, messages });
    assert.equal(terminal.type, 'error'); assert.equal(observed.launches.length, 0);
  }
});
await check('one bounded system text envelope is discarded from latest-only native payload', async () => {
  const { terminal, observed } = await run({ requestChange: request => ({ ...request, body: { ...request.body,
    messages: [...request.body.messages, { role: 'system', content: [{ type: 'text', text: 'private runtime metadata' }] }],
  } }) });
  assert.equal(terminal.type, 'completed');
  assert.deepEqual(observed.upstream[0].body.messages, INPUT.messages.map(({ role, text }) => ({ role, content: text })));
  assert.equal(JSON.stringify(observed.upstream[0].body).includes('private runtime metadata'), false);
});
await check('unknown native user/assistant history, altered latest text and non-text system blocks never reach provider', async () => {
  const changes = [
    request => ({ ...request, body: { ...request.body, messages: [{ role: 'user', content: 'altered' }] } }),
    request => ({ ...request, body: { ...request.body, messages: [...request.body.messages, { role: 'user', content: 'extra' }] } }),
    request => ({ ...request, body: { ...request.body, messages: [...request.body.messages, { role: 'assistant', content: 'extra' }] } }),
    request => ({ ...request, body: { ...request.body, messages: [...request.body.messages, { role: 'system', content: [{ type: 'tool_result', text: KEY }] }] } }),
    request => ({ ...request, body: { ...request.body, messages: [...request.body.messages, { role: 'system', content: [{ type: 'text', text: 'x'.repeat(2049) }] }] } }),
    request => ({ ...request, body: { ...request.body, tools: [{ name: 'Bash' }] } }),
    request => ({ ...request, body: { ...request.body, model: 'claude-sonnet-4-6' } }),
    request => ({ ...request, body: { ...request.body, stream: false } }),
  ];
  for (const requestChange of changes) {
    const { terminal, observed } = await run({ requestChange });
    assert.equal(terminal.type, 'error'); assert.equal(observed.upstream.length, 0);
  }
});
await check('native init must be strict and precede any provider request', async () => {
  const mutations = [init => ({ ...init, tools: ['Bash'] }), init => ({ ...init, skills: ['skill'] }),
    init => ({ ...init, plugins: [{ name: 'builtin' }] }), init => ({ ...init, mcp_servers: ['server'] }),
    init => ({ ...init, permissionMode: 'acceptEdits' }), init => ({ ...init, claude_code_version: '2.1.999' }),
    init => ({ ...init, cwd: '/private/unmatched' }), init => ({ ...init, tools: undefined })];
  for (const initChange of mutations) {
    const { terminal, events, observed } = await run({ initChange });
    assert.equal(terminal.type, 'error'); assert.equal(events.some(event => event.type === 'started'), false);
    assert.equal(observed.upstream.length, 0);
  }
  for (const options of [{ missingInit: true, timeoutMs: 30 }, { beforeInitRequest: true, timeoutMs: 30 }]) {
    const { terminal, observed } = await run(options);
    assert.equal(terminal.type, 'error'); assert.equal(observed.upstream.length, 0);
  }
});
await check('duplicate native init is rejected with a fixed code and started is emitted only once', async () => {
  const { terminal, events, observed } = await run({ duplicateInit: true });
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'DUPLICATE_NATIVE_INIT');
  assert.equal(events.filter(event => event.type === 'started').length, 1);
  assert.equal(events.some(event => event.type === 'completed'), false);
  assert.equal(observed.upstream.length, 0);
});
await check('local route and token bounds protect provider access', async () => {
  const changes = [request => ({ ...request, token: 'wrong-token' }), request => ({ ...request, route: '/v1/messages/count_tokens' }),
    request => ({ ...request, route: '/v1/messages?secret=anything' }), request => ({ ...request, route: '/other' }),
    request => ({ ...request, method: 'GET' })];
  for (const requestChange of changes) {
    const { terminal, observed } = await run({ requestChange });
    assert.equal(terminal.type, 'error'); assert.equal(observed.upstream.length, 0);
  }
});
await check('provider request budget caps native retries at three', async () => {
  const { terminal, observed } = await run({ requests: 4 });
  assert.equal(terminal.type, 'error'); assert.equal(observed.upstream.length, 3);
});
await check('request body bound rejects oversized data without provider contact', async () => {
  const { terminal, observed } = await run({ requestChange: request => ({ ...request, body: 'x'.repeat(1_048_577) }) });
  assert.equal(terminal.type, 'error'); assert.equal(observed.upstream.length, 0);
});
await check('provider redirects and HTTP error bodies never become display text', async () => {
  for (const status of [302, 401, 429, 500]) {
    const { terminal, events } = await run({ providerChange: () => sseResponse({ status, parts: [KEY] }) });
    assert.equal(terminal.type, 'error'); assert.equal(events.some(event => event.type === 'delta'), false);
    assert.equal(terminal.text, undefined);
  }
});
await check('provider tool response fails before rendering any untrusted tool parameters', async () => {
  const { terminal, events } = await run({ providerChange: () => sseResponse({ framesChange: frames => frames.map(([event, data]) =>
    event === 'content_block_start' ? [event, { ...data, content_block: { type: 'tool_use', name: 'Bash', input: { command: KEY } } }] : [event, data]) }) });
  assert.equal(terminal.type, 'error'); assert.equal(events.some(event => event.type === 'delta'), false);
});
await check('provider streams without a closing message cannot produce completed events', async () => {
  const { terminal, events } = await run({ providerChange: () => sseResponse({
    framesChange: frames => frames.filter(([event]) => event !== 'message_stop'),
  }) });
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'PROVIDER_STREAM_INCOMPLETE');
  assert.equal(events.some(event => event.type === 'completed'), false);
});
await check('SDK tool attempts and assistant/result disagreement cannot complete successfully', async () => {
  for (const options of [{ sdkTool: true }, { assistantChange: assistant => ({ ...assistant, message: { content: [{ type: 'text', text: 'mismatch' }] } }) },
    { resultChange: result => ({ ...result, result: 'mismatch' }) }, { resultChange: result => ({ ...result, is_error: true }) },
    { resultChange: result => ({ ...result, num_turns: 2 }) }, { missingSpawn: true }, { exitCode: 1 }]) {
    const { terminal } = await run(options); assert.equal(terminal.type, 'error');
  }
});
await check('provider output tokens and displayed UTF8 bytes are bounded', async () => {
  for (const providerChange of [() => sseResponse({ outputTokens: 4097 }),
    () => sseResponse({ parts: ['界'.repeat(87_382)], bytesPerChunk: 4096 })]) {
    const { terminal } = await run({ providerChange }); assert.equal(terminal.type, 'error');
  }
});
await check('transport and SDK diagnostic errors expose finite codes without raw details', async () => {
  for (const options of [{ queryError: true }, { iterationError: true }, { transportError: true },
    { iterationError: true, diagnostic: `EACCES permission denied ${KEY}` }]) {
    const { terminal, events } = await run(options);
    assert.equal(terminal.type, 'error'); assert.match(terminal.code, /^[A-Z][A-Z0-9_]{1,63}$/);
    assert.equal(JSON.stringify(events).includes('private'), false);
  }
});
await check('short injected deadline aborts SDK and cleans loopback plus temporary workspace', async () => {
  const before = Date.now();
  const { terminal, observed } = await run({ blockedUntilAbort: true, timeoutMs: 30 });
  assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'TOTAL_TIMEOUT');
  assert.equal(observed.query.options.abortController.signal.aborted, true);
  assert.ok(observed.closed >= 1); assert.equal(observed.upstream.length, 0);
  assert.ok(Date.now() - before < 1500);
});
await check('explicit CLI offline fixture emits only fixture events and preserves incremental raw text', async () => {
  // Execute only this Node entrypoint's explicit offline branch; the native SDK
  // query, native process and official transport are never used by this branch.
  const receipt = await new Promise((resolve, reject) => {
    const child = spawnNode(process.execPath, [fileURLToPath(new URL('./deepseek-text-chat.mjs', import.meta.url)), '--fixture'], {
      cwd: fileURLToPath(new URL('.', import.meta.url)), env: { PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const stdout = []; const stderr = [];
    let bytes = 0; let settled = false;
    const timer = setTimeout(() => { child.kill('SIGKILL'); }, 3000);
    const complete = value => { if (!settled) { settled = true; clearTimeout(timer); resolve(value); } };
    child.once('error', () => { clearTimeout(timer); reject(new Error('OFFLINE_FIXTURE_PROCESS_FAILED')); });
    child.stdout.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > 16_384) { child.kill('SIGKILL'); return; }
      stdout.push(chunk);
    });
    child.stderr.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > 16_384) { child.kill('SIGKILL'); return; }
      stderr.push(chunk);
    });
    child.once('exit', (code, signal) => complete({ code, signal,
      stdout: Buffer.concat(stdout).toString('utf8'), stderr: Buffer.concat(stderr).toString('utf8') }));
    child.stdin.end(JSON.stringify(INPUT));
  });
  assert.equal(receipt.code, 0); assert.equal(receipt.signal, null); assert.equal(receipt.stderr, '');
  assert.equal(receipt.stdout.includes(KEY), false);
  const events = receipt.stdout.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(events[0].type, 'started'); assert.equal(events.at(-1).type, 'completed');
  assert.equal(events.filter(event => event.type === 'started').length, 1);
  for (const event of events) {
    assert.equal(event.schema, EVENT_SCHEMA); assert.equal(event.request_id, REQUEST_ID);
    assert.equal(event.model, INPUT.model); assert.equal(event.fixture_only, true);
  }
  const deltas = events.filter(event => event.type === 'delta');
  assert.ok(deltas.length >= 2);
  assert.equal(deltas.map(event => event.text).join(''), events.at(-1).text);
  assert.equal(events.at(-1).text.includes('\uFFFD'), false);
  assert.equal(events.at(-1).no_tools, true); assert.equal(events.at(-1).temporary_removed, true);
  assert.equal(events.at(-1).proxy_closed, true);
});

process.stdout.write(`${JSON.stringify({ schema: 'deepseek-text-chat-fake-tests/v1', passed: checks,
  provider_calls: false, native_cli_executed: false, sandbox_executed: false, keychain_access: false })}\n`);
