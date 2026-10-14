// Local-only fake SDK/process fixtures. No official SDK import, native CLI,
// credential lookup, VM, external request or package installation is performed.
import assert from 'node:assert/strict';
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { LIMITS, SYSTEM_PROMPT, runGuestTextRuntime, validateStart } from './runtime.mjs';

const SESSION = '00000000-0000-4000-8000-000000000001';
const PROFILE = { schema: 'app-runtime-profile/v1', timeZone: 'Asia/Tokyo', language: 'ja' };
const START = { kind: 'start', provider: 'deepseek-api', model: 'deepseek-flash[1m]', prompt: 'hello 中文 日本語 🧑‍💻\n', runtime: PROFILE };
const TEXT = '  中文と日本語 🧑‍💻\n\n';
const PRIVATE = '/Users/private-host/secret credential-do-not-output';
const RUNTIME_PATH = fileURLToPath(new URL('./runtime.mjs', import.meta.url));
let checks = 0;
async function check(name, callback) { await callback(); checks++; process.stdout.write(`PASS ${name}\n`); }

function sse(text = TEXT, mutate) {
  let frames = [
    { type: 'message_start', message: { id: 'fake-message', type: 'message', role: 'assistant', model: 'deepseek-flash', content: [], usage: { input_tokens: 10, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 20 } },
    { type: 'message_stop' },
  ];
  if (mutate) frames = mutate(frames);
  return Buffer.from(frames.map(frame => `event: ${frame.type}\ndata: ${JSON.stringify(frame)}\n\n`).join(''));
}

function localRequest(baseURL, headers, body, route = '/v1/messages?beta=true') {
  return new Promise((resolve, reject) => {
    const bytes = Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
    const request = http.request(new URL(route, baseURL), { method: 'POST', headers: {
      ...headers, 'content-type': 'application/json', 'content-length': bytes.length,
    } }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.once('end', () => resolve({ status: response.statusCode, bytes: Buffer.concat(chunks) }));
      response.once('error', reject);
    });
    request.once('error', reject); request.end(bytes);
  });
}

function fixture({ initChange, bodyChange, headerChange, route, resultChange, assistantChange,
  text = TEXT, queryError = false, iteratorError = false, missingSpawn = false, missingInit = false,
  duplicateInit = false, requests = 1, exitCode = 0, blocked = false, timeoutMs = 300 } = {}) {
  const observed = { launch: [], query: undefined, closed: 0, local: [], token: undefined };
  let child, closed = false;
  const dependencies = { testOnly: true, cliPath: '/fixture/official-linux-cli', cwd: '/fixture/empty-workspace',
    env: { PATH: '/usr/bin:/bin', HOME: '/home/claude', TMPDIR: '/home/claude/tmp', CLAUDE_CONFIG_DIR: '/home/claude/.claude' }, timeoutMs,
    spawn(command, args, options) {
      observed.launch.push({ command, args, options });
      child = new EventEmitter(); child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
      child.kill = () => true; child.killed = false; child.exitCode = null;
      child.stderr.write(PRIVATE);
      return child;
    },
    query(request) {
      if (queryError) throw new Error(PRIVATE);
      observed.query = request;
      const { prompt, options } = request;
      const subscription = options.env.CLAUDE_CODE_OAUTH_TOKEN !== undefined;
      observed.token = subscription ? options.env.CLAUDE_CODE_OAUTH_TOKEN : options.env.ANTHROPIC_API_KEY;
      if (!missingSpawn) options.spawnClaudeCodeProcess({ command: dependencies.cliPath, cwd: options.cwd,
        env: { ...options.env, PRIVATE }, args: ['--setting-sources=', '--tools', ''], signal: options.abortController.signal });
      const model = subscription ? `claude-${options.model}-4-6` : options.model;
      const submit = async index => {
        let headers = subscription ? { authorization: `Bearer ${observed.token}`, 'anthropic-version': '2023-06-01',
          'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20', 'x-app': 'cli',
          'user-agent': 'claude-cli/2.1.295 (external, sdk-ts, agent-sdk/0.3.295)',
          'x-claude-code-session-id': SESSION, 'anthropic-dangerous-direct-browser-access': 'true' } :
          { 'x-api-key': observed.token, 'x-private-machine-path': PRIVATE };
        if (headerChange) headers = headerChange(headers);
        let body = { model, stream: true, max_tokens: 32000, thinking: { type: 'enabled' }, tools: [],
          system: subscription ? [
            { type: 'text', text: 'x-anthropic-billing-header: cc_version=2.1.295.abc; cc_entrypoint=sdk-ts;' },
            { type: 'text', text: "You are a Claude agent, built on Anthropic's Claude Agent SDK." },
            { type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } },
          ] : PRIVATE,
          metadata: subscription ? { user_id: JSON.stringify({ device_id: 'a'.repeat(64), account_uuid: '', session_id: SESSION }) } : { private: PRIVATE },
          messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] },
            { role: 'system', content: [{ type: 'text', text: PRIVATE }] }] };
        if (bodyChange) body = bodyChange(body, index);
        observed.local.push(await localRequest(options.env.ANTHROPIC_BASE_URL, headers, body, route));
      };
      async function* events() {
        if (iteratorError) throw new Error(PRIVATE);
        const init = { type: 'system', subtype: 'init', claude_code_version: '2.1.295', cwd: options.cwd,
          permissionMode: 'default', tools: [], mcp_servers: [], skills: [], plugins: [], session_id: SESSION,
          model, apiKeySource: subscription ? 'none' : 'ANTHROPIC_API_KEY' };
        if (!missingInit) yield initChange ? initChange(init) : init;
        if (duplicateInit) yield init;
        if (blocked) await new Promise(() => {});
        for (let index = 0; index < requests; index++) await submit(index);
        const assistant = { type: 'assistant', message: { content: [{ type: 'text', text: text.repeat(requests) }] } };
        yield assistantChange ? assistantChange(assistant) : assistant;
        const result = { type: 'result', subtype: 'success', is_error: false, num_turns: 1, result: text.repeat(requests).trim() };
        yield resultChange ? resultChange(result) : result;
      }
      const iterator = events();
      iterator.close = () => {
        observed.closed++;
        if (closed) return;
        closed = true;
        if (child) queueMicrotask(() => { child.exitCode = exitCode; child.emit('exit', exitCode, null); child.stdout.end(); child.stderr.end(); });
      };
      return iterator;
    } };
  return { dependencies, observed };
}

async function run(options = {}, start = START, control = {}) {
  const { dependencies, observed } = fixture(options);
  const input = new PassThrough(), output = new PassThrough(), events = [];
  let pending = '';
  const write = value => input.write(`${JSON.stringify(value)}\n`);
  output.on('data', chunk => {
    pending += chunk.toString('utf8');
    for (;;) {
      const end = pending.indexOf('\n'); if (end < 0) break;
      const event = JSON.parse(pending.slice(0, end)); pending = pending.slice(end + 1); events.push(event);
      if (event.kind === 'ready') {
        if (control.raw !== undefined) input.write(control.raw);
        else write(start);
        if (control.afterStart) queueMicrotask(() => control.afterStart({ write, input }));
      }
      if (event.kind === 'native_init' && control.afterInit) control.afterInit({ write, input });
      if (event.kind === 'provider_request') {
        if (control.provider) { control.provider(event, { write, input }); continue; }
        write({ kind: 'provider_response', id: event.id, status: 200, content_type: 'text/event-stream; charset=utf-8' });
        const bytes = sse(options.text ?? TEXT, control.sseChange);
        for (let index = 0; index < bytes.length; index += control.bytesPerChunk ?? 3) {
          write({ kind: 'provider_chunk', id: event.id, data: bytes.subarray(index, index + (control.bytesPerChunk ?? 3)).toString('base64') });
        }
        write({ kind: 'provider_end', id: event.id });
      }
    }
  });
  const result = await runGuestTextRuntime({ input, output }, dependencies);
  assert.deepEqual(events.at(-1), result);
  assert.equal(events.filter(event => event.kind === 'result').length, 1);
  assert.ok(events.every(event => ['ready', 'native_init', 'provider_request', 'result'].includes(event.kind)));
  assert.equal(JSON.stringify(events).includes(PRIVATE), false);
  if (observed.token) assert.equal(JSON.stringify(events).includes(observed.token), false);
  input.destroy(); output.destroy();
  return { result, observed, events };
}

await check('DeepSeek text bridge preserves Unicode/whitespace, removes native metadata and uses owned process group', async () => {
  const { result, observed, events } = await run();
  assert.deepEqual(result, { kind: 'result', text: TEXT, ok: true });
  assert.deepEqual(events[0], { kind: 'ready' });
  assert.deepEqual(events[1], { kind: 'native_init', model: START.model, session_id: SESSION, no_tools: true });
  const request = events.find(event => event.kind === 'provider_request');
  assert.deepEqual(request.headers, {});
  assert.deepEqual(request.body, { model: 'deepseek-flash', stream: true, max_tokens: 4096, thinking: { type: 'disabled' },
    tools: [], system: SYSTEM_PROMPT, messages: [{ role: 'user', content: START.prompt }] });
  assert.equal(observed.launch.length, 1); assert.equal(observed.launch[0].command, '/fixture/official-linux-cli');
  assert.equal(observed.launch[0].options.detached, true); assert.equal(observed.launch[0].options.env.PRIVATE, undefined);
  assert.equal(observed.launch[0].options.env.HOME, '/home/claude');
  assert.equal(observed.launch[0].options.env.TZ, 'Asia/Tokyo'); assert.equal(observed.launch[0].options.env.LANG, 'ja_JP.UTF-8');
  assert.equal(observed.launch[0].options.env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
  assert.deepEqual(observed.query.options.tools, []); assert.deepEqual(observed.query.options.settingSources, []);
  assert.deepEqual(observed.query.options.mcpServers, {}); assert.deepEqual(observed.query.options.plugins, []);
  assert.equal(observed.query.options.persistSession, false); assert.equal(observed.query.options.settings.disableAllHooks, true);
  assert.equal(observed.local[0].status, 200); assert.equal(observed.local[0].bytes.toString('utf8'), sse().toString('utf8'));
});
await check('subscription aliases retain bounded OAuth protocol fields with a random guest-only token', async () => {
  for (const model of ['sonnet', 'opus', 'haiku']) {
    const { result, observed, events } = await run({}, { ...START, provider: 'claude-subscription', model });
    assert.equal(result.ok, true);
    assert.match(observed.token, /^sk-ant-oat01-[A-Za-z0-9_-]+$/);
    assert.equal(observed.query.options.env.ANTHROPIC_API_KEY, undefined);
    const request = events.find(event => event.kind === 'provider_request');
    assert.equal(request.headers.authorization, undefined); assert.equal(request.headers['x-api-key'], undefined);
    assert.equal(request.headers['x-claude-code-session-id'], SESSION);
    assert.equal(request.body.model, `claude-${model}-4-6`);
    assert.equal(request.body.system[2].text, SYSTEM_PROMPT);
    assert.deepEqual(JSON.parse(request.body.metadata.user_id), { device_id: 'a'.repeat(64), account_uuid: '', session_id: SESSION });
  }
});
await check('runtime profiles reach child env and never provider body', async () => {
  for (const [timeZone, language, locale] of [['UTC', 'en', 'en_US.UTF-8'], ['Asia/Shanghai', 'zh', 'zh_CN.UTF-8']]) {
    const { result, observed, events } = await run({}, { ...START, runtime: { ...PROFILE, timeZone, language } });
    assert.equal(result.ok, true); assert.equal(observed.query.options.env.TZ, timeZone);
    for (const key of ['LANG', 'LC_ALL', 'LC_MESSAGES']) assert.equal(observed.query.options.env[key], locale);
    assert.equal(JSON.stringify(events.find(event => event.kind === 'provider_request')).includes(timeZone), false);
  }
});
await check('invalid start/profile/credential keys fail before query or native launch', async () => {
  const values = [{ ...START, apiKey: PRIVATE }, { ...START, provider: 'direct' }, { ...START, model: 'arbitrary' },
    { ...START, prompt: '  ' }, { ...START, runtime: { ...PROFILE, language: 'ja-JP' } },
    { ...START, runtime: { ...PROFILE, timeZone: '/Users/private' } }, { ...START, runtime: { ...PROFILE, timeZone: 'Mars/City' } },
    { ...START, runtime: { ...PROFILE, timeZone: 'asia/tokyo' } },
    { ...START, runtime: { ...PROFILE, extra: PRIVATE } }, { ...START, runtime: null }];
  for (const start of values) {
    const { result, observed } = await run({}, start);
    assert.equal(result.ok, false); assert.equal(observed.query, undefined); assert.deepEqual(observed.launch, []);
  }
  assert.throws(() => validateStart({ ...START, prompt: 'x'.repeat(LIMITS.input + 1) }), /INVALID_PROMPT/);
});
await check('NDJSON rejects invalid UTF8, invalid JSON, blank lines and oversized frames', async () => {
  for (const raw of [Buffer.from([0xff, 10]), '{bad}\n', '\n', `${'x'.repeat(LIMITS.input + 1)}\n`]) {
    const { result, observed } = await run({}, START, { raw });
    assert.equal(result.ok, false); assert.equal(observed.query, undefined);
  }
});
await check('a second start cancels a running turn', async () => {
  const { result } = await run({ blocked: true }, START, { afterInit: ({ write }) => write(START) });
  assert.equal(result.error_code, 'DUPLICATE_START');
});
await check('cancel before start emits safe terminal and cancellation unblocks stuck iterator', async () => {
  const early = await run({}, { kind: 'cancel' }); assert.equal(early.result.error_code, 'CHAT_CANCELLED');
  const running = await run({ blocked: true }, START, { afterInit: ({ write }) => write({ kind: 'cancel' }) });
  assert.equal(running.result.error_code, 'CHAT_CANCELLED'); assert.ok(running.observed.closed > 0);
});
await check('total timeout unblocks an iterator that never resolves', async () => {
  const before = performance.now(); const { result } = await run({ blocked: true, timeoutMs: 25 });
  assert.equal(result.error_code, 'TOTAL_TIMEOUT'); assert.ok(performance.now() - before < 1000);
});
await check('input EOF during turn cancels without requiring provider completion', async () => {
  const { result } = await run({ blocked: true }, START, { afterInit: ({ input }) => input.end() });
  assert.equal(result.error_code, 'TRANSPORT_CLOSED');
});
await check('init cannot enable tools/MCP/plugins/skills or change cwd/version/model/session', async () => {
  for (const change of [init => ({ ...init, tools: ['Bash'] }), init => ({ ...init, mcp_servers: ['private'] }),
    init => ({ ...init, plugins: ['private'] }), init => ({ ...init, skills: ['private'] }),
    init => ({ ...init, cwd: PRIVATE }), init => ({ ...init, claude_code_version: '2.1.294' }),
    init => ({ ...init, model: 'arbitrary' }), init => ({ ...init, session_id: PRIVATE }),
    init => ({ ...init, apiKeySource: 'file' })]) {
    const { result, events } = await run({ initChange: change });
    assert.equal(result.error_code, 'NO_TOOLS_CONTRACT'); assert.equal(events.filter(event => event.kind === 'provider_request').length, 0);
  }
  assert.equal((await run({ duplicateInit: true })).result.error_code, 'DUPLICATE_NATIVE_INIT');
});
await check('malformed localhost auth/route/request cannot reach provider broker', async () => {
  for (const options of [{ headerChange: headers => ({ ...headers, 'x-api-key': 'wrong' }) }, { route: '/v1/messages?leak=true' },
    { bodyChange: body => ({ ...body, tools: [{ name: 'Bash' }] }) },
    { bodyChange: body => ({ ...body, messages: [{ role: 'user', content: PRIVATE }] }) },
    { bodyChange: () => '{bad}' }, { bodyChange: body => ({ ...body, padding: 'x'.repeat(LIMITS.request) }) }]) {
    const { result, events } = await run(options);
    assert.equal(result.ok, false); assert.equal(events.filter(event => event.kind === 'provider_request').length, 0);
  }
});
await check('subscription native request identity and header contracts fail closed', async () => {
  for (const options of [{ headerChange: headers => ({ ...headers, 'anthropic-beta': 'claude-code-20250219' }) },
    { headerChange: headers => ({ ...headers, 'x-claude-code-session-id': '00000000-0000-4000-8000-000000000002' }) },
    { bodyChange: body => ({ ...body, system: [] }) },
    { bodyChange: body => ({ ...body, metadata: { user_id: JSON.stringify({ device_id: 'a'.repeat(64), account_uuid: '', session_id: PRIVATE }) } }) }]) {
    const { result } = await run(options, { ...START, provider: 'claude-subscription', model: 'sonnet' });
    assert.equal(result.error_code, 'SUBSCRIPTION_PROTOCOL_REJECTED');
  }
});
await check('at most three provider requests are accepted', async () => {
  const accepted = await run({ requests: 3 }); assert.equal(accepted.result.ok, true);
  assert.equal(accepted.events.filter(event => event.kind === 'provider_request').length, 3);
  const refused = await run({ requests: 4 }); assert.equal(refused.result.error_code, 'REQUEST_LIMIT');
  assert.equal(refused.events.filter(event => event.kind === 'provider_request').length, 3);
});
await check('provider response id/order/header/status are enforced', async () => {
  const controls = [
    (event, { write }) => write({ kind: 'provider_response', id: 'wrong', status: 200, content_type: 'text/event-stream' }),
    (event, { write }) => write({ kind: 'provider_chunk', id: event.id, data: 'YQ==' }),
    (event, { write }) => write({ kind: 'provider_response', id: event.id, status: 302, content_type: 'text/event-stream' }),
    (event, { write }) => write({ kind: 'provider_response', id: event.id, status: 401, content_type: 'application/json' }),
    (event, { write }) => write({ kind: 'provider_response', id: event.id, status: 200, content_type: 'application/json' }),
    (event, { write }) => { const header = { kind: 'provider_response', id: event.id, status: 200, content_type: 'text/event-stream' }; write(header); write(header); },
  ];
  for (const provider of controls) assert.equal((await run({}, START, { provider })).result.ok, false);
});
await check('invalid base64/chunk sizes are rejected', async () => {
  for (const data of ['?', 'YQ=', 'YR==', Buffer.alloc(LIMITS.chunk + 1).toString('base64')]) {
    const { result } = await run({}, START, { provider(event, { write }) {
      write({ kind: 'provider_response', id: event.id, status: 200, content_type: 'text/event-stream' });
      write({ kind: 'provider_chunk', id: event.id, data });
    } });
    assert.equal(result.error_code, 'PROVIDER_PROTOCOL_REJECTED');
  }
});
await check('provider SSE rejects tools, malformed lifecycle and incomplete stream', async () => {
  for (const sseChange of [frames => frames.slice(0, -1), frames => frames.slice(1),
    frames => frames.map(frame => frame.type === 'content_block_start' ? { ...frame, content_block: { type: 'tool_use', id: 'fake', name: 'Bash', input: {} } } : frame),
    frames => frames.map(frame => frame.type === 'message_delta' ? { ...frame, delta: { stop_reason: 'tool_use' } } : frame),
    frames => [...frames, frames[0]],
    frames => frames.map(frame => frame.type === 'message_delta' ? { ...frame, usage: { output_tokens: 4097 } } : frame)]) {
    const { result } = await run({}, START, { sseChange }); assert.equal(result.ok, false);
  }
});
await check('response bytes, SSE frame size and text output all remain bounded', async () => {
  const hugeFrame = await run({}, START, { provider(event, { write }) {
    write({ kind: 'provider_response', id: event.id, status: 200, content_type: 'text/event-stream' });
    const bytes = Buffer.from(`data: ${'x'.repeat(LIMITS.frame + 1)}`);
    for (let index = 0; index < bytes.length; index += LIMITS.chunk) write({ kind: 'provider_chunk', id: event.id, data: bytes.subarray(index, index + LIMITS.chunk).toString('base64') });
  } });
  assert.equal(hugeFrame.result.error_code, 'PROVIDER_RESPONSE_LIMIT');
  const hugeText = await run({ text: 'x'.repeat(LIMITS.text + 1) }, START, { bytesPerChunk: LIMITS.chunk });
  assert.equal(hugeText.result.ok, false);
  const hugeResponse = await run({}, START, { provider(event, { write }) {
    write({ kind: 'provider_response', id: event.id, status: 200, content_type: 'text/event-stream' });
    const bytes = Buffer.from(`:${'x'.repeat(60000)}\n\n`);
    for (let index = 0; index < 36; index++) write({ kind: 'provider_chunk', id: event.id, data: bytes.toString('base64') });
  } });
  assert.equal(hugeResponse.result.error_code, 'PROVIDER_RESPONSE_LIMIT');
});
await check('SDK text and result must match provider text with no tool events', async () => {
  for (const options of [{ assistantChange: event => ({ ...event, message: { content: [{ type: 'text', text: 'different' }] } }) },
    { assistantChange: event => ({ ...event, message: { content: [{ type: 'tool_use', name: 'Bash' }] } }) },
    { resultChange: event => ({ ...event, result: 'different' }) }, { resultChange: event => ({ ...event, num_turns: 2 }) },
    { resultChange: event => ({ ...event, is_error: true }) }, { missingSpawn: true }, { exitCode: 1 }]) {
    assert.equal((await run(options)).result.ok, false);
  }
});
await check('arbitrary SDK diagnostics never appear in protocol output', async () => {
  for (const options of [{ queryError: true }, { iteratorError: true }]) {
    const { result, events } = await run(options);
    assert.equal(result.ok, false); assert.equal(JSON.stringify(events).includes(PRIVATE), false);
  }
});
await check('production entrypoint refuses this host before importing SDK or launching native CLI', async () => {
  const output = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [RUNTIME_PATH], { stdio: ['pipe', 'pipe', 'pipe'], env: { PATH: '/usr/bin:/bin' } });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; }); child.stderr.on('data', chunk => { stderr += chunk; });
    child.once('error', reject); child.once('exit', code => resolve({ code, stdout, stderr }));
    child.stdin.write(`${JSON.stringify(START)}\n`);
  });
  const events = output.stdout.trim().split('\n').map(line => JSON.parse(line));
  assert.deepEqual(events, [{ kind: 'ready' }, { kind: 'result', text: '', ok: false, error_code: 'GUEST_PLATFORM_REQUIRED' }]);
  assert.equal(output.code, 1); assert.equal(output.stderr, '');
});
process.stdout.write(`${JSON.stringify({ schema: 'guest-text-runtime-local-checks/v1', passed: checks,
  official_sdk_imported: false, native_cli_executed: false, external_requests: false, real_credentials_used: false })}\n`);
