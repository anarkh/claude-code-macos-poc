// Local-only fake SDK/process fixtures. No official SDK import, native CLI,
// credential lookup, VM, external request or package installation is performed.
import assert from 'node:assert/strict';
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { lstat, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { LIMITS, SYSTEM_PROMPT, PROJECT_EXECUTION_CONTRACT, PROJECT_MOUNT, PROJECT_TOOLS, PROJECT_SYSTEM_PROMPT, PROJECT_LIMITS, runGuestTextRuntime, seedNativeIdentity, validateStart, validateProjectMount, validateProjectTool } from './runtime.mjs';

const SESSION = '00000000-0000-4000-8000-000000000001';
const IDENTITY = { device_id: 'a'.repeat(64), session_id: '00000000-0000-4000-8000-000000000020' };
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
      const sessionID = options.sessionId ?? SESSION;
      const subscription = options.env.CLAUDE_CODE_OAUTH_TOKEN !== undefined;
      observed.token = subscription ? options.env.CLAUDE_CODE_OAUTH_TOKEN : options.env.ANTHROPIC_API_KEY;
      if (!missingSpawn) options.spawnClaudeCodeProcess({ command: dependencies.cliPath, cwd: options.cwd,
        env: { ...options.env, PRIVATE }, args: ['--setting-sources=', '--tools', ''], signal: options.abortController.signal });
      const model = subscription ? `claude-${options.model}-4-6` : options.model;
      const submit = async index => {
        let headers = subscription ? { authorization: `Bearer ${observed.token}`, 'anthropic-version': '2023-06-01',
          'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20', 'x-app': 'cli',
          'user-agent': 'claude-cli/2.1.295 (external, sdk-ts, agent-sdk/0.3.295)',
          'x-claude-code-session-id': sessionID, 'anthropic-dangerous-direct-browser-access': 'true' } :
          { 'x-api-key': observed.token, 'x-private-machine-path': PRIVATE };
        if (headerChange) headers = headerChange(headers);
        let body = { model, stream: true, max_tokens: 32000, thinking: { type: 'enabled' }, tools: [],
          system: subscription ? [
            { type: 'text', text: 'x-anthropic-billing-header: cc_version=2.1.295.abc; cc_entrypoint=sdk-ts;' },
            { type: 'text', text: "You are a Claude agent, built on Anthropic's Claude Agent SDK." },
            { type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } },
          ] : PRIVATE,
          metadata: subscription ? { user_id: JSON.stringify({ device_id: 'a'.repeat(64), account_uuid: '', session_id: sessionID }) } : { private: PRIVATE },
          messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] },
            { role: 'system', content: [{ type: 'text', text: PRIVATE }] }] };
        if (bodyChange) body = bodyChange(body, index);
        observed.local.push(await localRequest(options.env.ANTHROPIC_BASE_URL, headers, body, route));
      };
      async function* events() {
        if (iteratorError) throw new Error(PRIVATE);
        const init = { type: 'system', subtype: 'init', claude_code_version: '2.1.295', cwd: options.cwd,
          permissionMode: 'default', tools: [], mcp_servers: [], skills: [], plugins: [], session_id: sessionID,
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

const PROJECT_START = { ...START, project: { contract: PROJECT_EXECUTION_CONTRACT } };
const PROJECT_MOUNTINFO = `23 1 0:21 / ${PROJECT_MOUNT} rw,nosuid,nodev,relatime - virtiofs claude-project rw\n`;
const PROJECT_ROUNDS = [
  [{ type: 'text', text: 'Inspecting the project.\n' }, { type: 'tool_use', id: 'toolu_read_1', name: 'Read', input: { file_path: 'note.txt' } }],
  [{ type: 'text', text: 'The project contains a note.\n' }],
];
function projectSse(blocks) {
  const frames = [{ type: 'message_start', message: { id: 'project-message', type: 'message', role: 'assistant', model: 'deepseek-flash', content: [], usage: { input_tokens: 10, output_tokens: 0 } } }];
  blocks.forEach((block, index) => {
    frames.push({ type: 'content_block_start', index, content_block: block.type === 'tool_use' ? { ...block, input: {} } : { ...block, text: '' } });
    frames.push({ type: 'content_block_delta', index, delta: block.type === 'tool_use' ?
      { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } : { type: 'text_delta', text: block.text } });
    frames.push({ type: 'content_block_stop', index });
  });
  frames.push({ type: 'message_delta', delta: { stop_reason: blocks.some(block => block.type === 'tool_use') ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 20 } }, { type: 'message_stop' });
  return Buffer.from(frames.map(frame => `event: ${frame.type}\ndata: ${JSON.stringify(frame)}\n\n`).join(''));
}

function projectFixture(settings = {}) {
  const { dependencies, observed } = fixture(settings);
  dependencies.cwd = PROJECT_MOUNT;
  dependencies.projectToolRoot = settings.projectToolRoot;
  dependencies.projectMount = settings.projectMount ?? { marker: 'project-v1\n', mountinfo: PROJECT_MOUNTINFO };
  dependencies.query = request => {
    observed.query = request;
    const { prompt, options } = request;
    const subscription = options.env.CLAUDE_CODE_OAUTH_TOKEN !== undefined;
    observed.token = subscription ? options.env.CLAUDE_CODE_OAUTH_TOKEN : options.env.ANTHROPIC_API_KEY;
    const sessionID = options.sessionId ?? SESSION;
    const model = subscription ? `claude-${options.model}-4-6` : options.model;
    const child = options.spawnClaudeCodeProcess({ command: dependencies.cliPath, cwd: options.cwd, env: options.env,
      args: ['--setting-sources=', '--tools', PROJECT_TOOLS.join(',')], signal: options.abortController.signal });
    const transcript = [{ role: 'user', content: [{ type: 'text', text: prompt }] }];
    const rounds = settings.rounds ?? PROJECT_ROUNDS;
    async function* events() {
      const init = { type: 'system', subtype: 'init', claude_code_version: '2.1.295', cwd: options.cwd,
        permissionMode: 'default', tools: [...PROJECT_TOOLS], mcp_servers: [], skills: [], plugins: [], session_id: sessionID,
        model, apiKeySource: subscription ? 'none' : 'ANTHROPIC_API_KEY' };
      yield settings.initChange ? settings.initChange(init) : init;
      if (settings.blocked) await new Promise(() => {});
      for (let index = 0; index < rounds.length; index++) {
        let body = { model, stream: true, tools: PROJECT_TOOLS.map(name => ({ name, description: `${name} the selected project`, input_schema: { type: 'object', properties: {} } })),
          system: subscription ? [
            { type: 'text', text: 'x-anthropic-billing-header: cc_version=2.1.295.abc; cc_entrypoint=sdk-ts;' },
            { type: 'text', text: "You are a Claude agent, built on Anthropic's Claude Agent SDK." },
            { type: 'text', text: PROJECT_SYSTEM_PROMPT },
          ] : PROJECT_SYSTEM_PROMPT,
          metadata: subscription ? { user_id: JSON.stringify({ device_id: 'a'.repeat(64), account_uuid: '', session_id: sessionID }) } : undefined,
          messages: structuredClone(transcript) };
        if (settings.bodyChange) body = settings.bodyChange(body, index);
        const headers = subscription ? { authorization: `Bearer ${observed.token}`, 'anthropic-version': '2023-06-01',
          'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20', 'x-app': 'cli',
          'user-agent': 'claude-cli/2.1.295 (external, sdk-ts, agent-sdk/0.3.295)',
          'x-claude-code-session-id': sessionID, 'anthropic-dangerous-direct-browser-access': 'true' } : { 'x-api-key': observed.token };
        const response = await localRequest(options.env.ANTHROPIC_BASE_URL, headers, body);
        observed.local.push(response);
        if (response.status !== 200) return;
        const blocks = rounds[index].map(block => block.type === 'tool_use' && settings.nativeToolInput ?
          { ...block, input: settings.nativeToolInput(block.name, structuredClone(block.input)) } : block);
        for (const block of blocks) {
          const event = { type: 'assistant', message: { id: `assistant-${index}`, content: [structuredClone(block)] } };
          yield settings.assistantChange ? settings.assistantChange(event, index) : event;
        }
        transcript.push({ role: 'assistant', content: structuredClone(blocks) });
        const results = [];
        for (const block of blocks.filter(block => block.type === 'tool_use')) {
          if (settings.permission !== false) {
            const permission = await options.canUseTool(block.name, block.input, { toolUseID: block.id, signal: options.abortController.signal });
            observed.permissions ??= []; observed.permissions.push(permission);
            if (permission.behavior !== 'allow') return;
          }
          const result = { type: 'tool_result', tool_use_id: block.id, content: settings.toolContent ?? 'synthetic project output', ...(settings.toolError ? { is_error: true } : {}) };
          const event = { type: 'user', message: { role: 'user', content: [result] } };
          yield settings.userChange ? settings.userChange(event, index) : event;
          results.push(result);
        }
        if (results.length) transcript.push({ role: 'user', content: results });
      }
      const finalText = rounds.at(-1).filter(block => block.type === 'text').map(block => block.text).join('');
      const result = { type: 'result', subtype: 'success', is_error: false, num_turns: rounds.length, result: finalText.trim() };
      yield settings.resultChange ? settings.resultChange(result) : result;
    }
    const iterator = events();
    let closed = false;
    iterator.close = () => {
      observed.closed++;
      if (!closed) { closed = true; queueMicrotask(() => { child.exitCode = 0; child.emit('exit', 0, null); child.stdout.end(); child.stderr.end(); }); }
    };
    return iterator;
  };
  return { dependencies, observed };
}

async function run(options = {}, start = START, control = {}) {
  const { dependencies, observed } = options.projectFixture ? projectFixture(options) : fixture(options);
  const input = new PassThrough(), output = new PassThrough(), events = [];
  let pending = '', providerIndex = 0;
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
        const bytes = options.projectFixture ? projectSse((control.rounds ?? options.rounds ?? PROJECT_ROUNDS)[providerIndex++]) : sse(options.text ?? TEXT, control.sseChange);
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
  assert.ok(events.every(event => ['ready', 'native_init', 'provider_request', 'result', ...(start.project ? ['tool_activity'] : [])].includes(event.kind)));
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
  assert.equal(observed.query.options.settings.attribution, undefined);
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
await check('requested conversation identity is supplied to native session creation and verified before broker output', async () => {
  const start = { ...START, provider: 'claude-subscription', model: 'sonnet', identity: IDENTITY };
  const { result, observed, events } = await run({}, start);
  assert.equal(result.ok, true);
  assert.equal(observed.query.options.sessionId, IDENTITY.session_id);
  assert.equal(observed.query.options.persistSession, false);
  assert.equal(observed.query.options.resume, undefined);
  assert.equal(events.find(event => event.kind === 'native_init').session_id, IDENTITY.session_id);
  const request = events.find(event => event.kind === 'provider_request');
  assert.equal(request.headers['x-claude-code-session-id'], IDENTITY.session_id);
  assert.deepEqual(JSON.parse(request.body.metadata.user_id), { ...IDENTITY, account_uuid: '' });
  for (const options of [
    { initChange: init => ({ ...init, session_id: SESSION }) },
    { bodyChange: body => ({ ...body, metadata: { user_id: JSON.stringify({ ...IDENTITY, account_uuid: '', device_id: 'b'.repeat(64) }) } }) },
    { bodyChange: body => ({ ...body, metadata: { user_id: JSON.stringify({ ...IDENTITY, account_uuid: SESSION }) } }) },
  ]) {
    const refused = await run(options, start);
    assert.equal(refused.result.error_code, 'NATIVE_IDENTITY_MISMATCH');
    assert.equal(refused.events.some(event => event.kind === 'provider_request'), false);
  }
});
await check('identity config seed uses the official global userID field and never replaces existing config', async () => {
  const directory = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-identity-seed-')));
  const file = path.join(directory, '.claude.json');
  try {
    await seedNativeIdentity(directory, IDENTITY.device_id);
    const bytes = await readFile(file, 'utf8');
    assert.deepEqual(JSON.parse(bytes), { userID: IDENTITY.device_id });
    assert.equal((await lstat(file)).mode & 0o777, 0o600);
    await assert.rejects(seedNativeIdentity(directory, 'b'.repeat(64)), { code: 'GUEST_IDENTITY_CONFIG_FAILED' });
    assert.equal(await readFile(file, 'utf8'), bytes);
    await rm(file);
    const legacy = path.join(directory, '.config.json');
    await writeFile(legacy, '{"userID":"synthetic-existing-state"}', { mode: 0o600 });
    await assert.rejects(seedNativeIdentity(directory, IDENTITY.device_id), { code: 'GUEST_IDENTITY_CONFIG_FAILED' });
    assert.equal(await readFile(legacy, 'utf8'), '{"userID":"synthetic-existing-state"}');
    await rm(legacy);
    await symlink(directory, path.join(directory, 'linked'));
    await assert.rejects(seedNativeIdentity(path.join(directory, 'linked'), IDENTITY.device_id), { code: 'GUEST_IDENTITY_CONFIG_FAILED' });
  } finally { await rm(directory, { recursive: true, force: true }); }
});
await check('identity rejects extra fields, other providers and invalid IDs before native launch', async () => {
  const start = { ...START, provider: 'claude-subscription', model: 'sonnet' };
  for (const identity of [null, {}, { ...IDENTITY, device_id: 'A'.repeat(64) }, { ...IDENTITY, session_id: PRIVATE },
    { ...IDENTITY, account_uuid: SESSION }, { ...IDENTITY, token: PRIVATE }]) {
    const { result, observed } = await run({}, { ...start, identity });
    assert.equal(result.error_code, 'INVALID_IDENTITY'); assert.equal(observed.query, undefined);
  }
  assert.equal((await run({}, { ...START, identity: IDENTITY })).result.error_code, 'INVALID_IDENTITY');
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
await check('project mount requires the explicit seed marker and exactly one writable matching VirtioFS share', async () => {
  validateProjectMount(PROJECT_START.project, 'project-v1\n', PROJECT_MOUNTINFO);
  validateProjectMount(undefined, null, '1 0 0:1 / / rw - ext4 /dev/vda rw\n');
  for (const [project, marker, mountinfo] of [
    [PROJECT_START.project, null, PROJECT_MOUNTINFO], [PROJECT_START.project, 'project-v1', PROJECT_MOUNTINFO],
    [PROJECT_START.project, 'project-v1\n', PROJECT_MOUNTINFO.replace('claude-project', 'wrong-tag')],
    [PROJECT_START.project, 'project-v1\n', PROJECT_MOUNTINFO.replace('virtiofs', '9p')],
    [PROJECT_START.project, 'project-v1\n', PROJECT_MOUNTINFO.replace('rw,nosuid', 'ro,nosuid')],
    [PROJECT_START.project, 'project-v1\n', PROJECT_MOUNTINFO.replace(PROJECT_MOUNT, '/home/claude/other')],
    [PROJECT_START.project, 'project-v1\n', PROJECT_MOUNTINFO + PROJECT_MOUNTINFO.replace(PROJECT_MOUNT, '/extra')],
    [PROJECT_START.project, 'project-v1\n', PROJECT_MOUNTINFO + '24 23 0:22 / /home/claude/project/nested rw - ext4 /dev/vdc rw\n'],
    [undefined, null, PROJECT_MOUNTINFO], [undefined, 'project-v1\n', ''],
  ]) assert.throws(() => validateProjectMount(project, marker, mountinfo), /PROJECT_MOUNT_REJECTED/);
  for (const project of [null, {}, { contract: 'old' }, { contract: PROJECT_EXECUTION_CONTRACT, path: PRIVATE }]) {
    const { result, observed } = await run({}, { ...START, project });
    assert.equal(result.error_code, 'PROJECT_CONTRACT_REJECTED'); assert.equal(observed.query, undefined);
  }
  const refused = await run({ projectFixture: true, projectMount: { marker: 'project-v1\n', mountinfo: '' } }, PROJECT_START);
  assert.equal(refused.result.error_code, 'PROJECT_MOUNT_REJECTED'); assert.equal(refused.observed.query, undefined);
});
await check('project file tools reject escapes and symlinks while permitting in-mount paths and new targets', async () => {
  const directory = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-path-')));
  const root = path.join(directory, 'project'); await mkdir(root);
  try {
    await writeFile(path.join(root, 'note.txt'), 'synthetic');
    await writeFile(path.join(directory, 'outside'), 'sentinel');
    await symlink(path.join(directory, 'outside'), path.join(root, 'escape'));
    await symlink(path.join(directory, 'missing'), path.join(root, 'dangling'));
    await symlink(path.join(root, 'note.txt'), path.join(root, 'inside'));
    for (const name of ['Read', 'Write', 'Edit']) {
      await validateProjectTool(name, { file_path: 'note.txt' }, root);
      await validateProjectTool(name, { file_path: path.join(root, 'inside') }, root);
      for (const file_path of ['../outside', path.join(directory, 'outside'), 'escape', 'dangling', '', 'a\0b'])
        await assert.rejects(validateProjectTool(name, { file_path }, root), /PROJECT_PATH_REJECTED/);
    }
    await validateProjectTool('Write', { file_path: 'new/note.txt' }, root);
    await validateProjectTool('Glob', { pattern: '**/*' }, root);
    await validateProjectTool('Grep', { pattern: 'example', path: root }, root);
    await validateProjectTool('Bash', { command: 'printf synthetic', run_in_background: false }, root);
    for (const input of [{ command: 'pwd', run_in_background: true }, { command: 'pwd', dangerouslyDisableSandbox: true }, { command: '' }, {}])
      await assert.rejects(validateProjectTool('Bash', input, root), /PROJECT_TOOL_REJECTED/);
    await assert.rejects(validateProjectTool('Agent', {}, root), /PROJECT_TOOL_REJECTED/);
    assert.equal(await readFile(path.join(directory, 'outside'), 'utf8'), 'sentinel');
  } finally { await rm(directory, { recursive: true, force: true }); }
});
await check('Glob patterns and Grep file globs stay relative without restricting Grep regular expressions', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-glob-')));
  try {
    for (const glob of ['**/*', '**/src/[x]', './src/*.{js,ts}', 'file..name', 'src/**/test?.mjs']) {
      await validateProjectTool('Glob', { pattern: glob }, root);
      await validateProjectTool('Grep', { pattern: '^../(foo|bar)$', glob }, root);
    }
    await validateProjectTool('Grep', { pattern: '/absolute/regex/../is-not-a-path' }, root);
    for (const glob of ['', '   ', '../*', 'src/../../*', '**/../secret', '/etc/*', '..', 'a\0b', 'x'.repeat(4097), null]) {
      await assert.rejects(validateProjectTool('Glob', { pattern: glob }, root), /PROJECT_PATH_REJECTED/);
      await assert.rejects(validateProjectTool('Grep', { pattern: 'valid regex', glob }, root), /PROJECT_PATH_REJECTED/);
    }
    await assert.rejects(validateProjectTool('Glob', {}, root), /PROJECT_PATH_REJECTED/);
    for (const call of [
      { type: 'tool_use', id: 'glob_escape', name: 'Glob', input: { pattern: '../outside/*' } },
      { type: 'tool_use', id: 'grep_escape', name: 'Grep', input: { pattern: 'text', glob: '/etc/*' } },
    ]) {
      const refused = await run({ projectFixture: true, projectToolRoot: root, rounds: [[call], PROJECT_ROUNDS[1]] }, PROJECT_START);
      assert.equal(refused.result.error_code, 'PROJECT_PATH_REJECTED');
      assert.equal(refused.events.filter(event => event.kind === 'tool_activity').length, 0);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
await check('project tool multiround preserves all text, exact native tools, and final-result semantics', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-turn-')));
  try {
    for (const provider of ['deepseek-api', 'claude-subscription']) {
      const start = { ...PROJECT_START, provider, ...(provider === 'claude-subscription' ? { model: 'sonnet', identity: IDENTITY } : {}) };
      const { result, observed, events } = await run({ projectFixture: true, projectToolRoot: root }, start);
      assert.deepEqual(result, { kind: 'result', ok: true, text: PROJECT_ROUNDS.flat().filter(block => block.type === 'text').map(block => block.text).join('') });
      const init = events.find(event => event.kind === 'native_init');
      assert.equal(init.no_tools, false); assert.deepEqual(init.tools, PROJECT_TOOLS); assert.equal(init.project_mount, PROJECT_MOUNT);
      assert.deepEqual(events.filter(event => event.kind === 'tool_activity'), [
        { kind: 'tool_activity', tool_id: 'toolu_read_1', tool: 'Read', phase: 'started' },
        { kind: 'tool_activity', tool_id: 'toolu_read_1', tool: 'Read', phase: 'completed' },
      ]);
      assert.equal(observed.query.options.cwd, PROJECT_MOUNT); assert.equal(observed.query.options.maxTurns, 12);
      assert.equal(observed.query.options.permissionMode, 'default'); assert.equal(observed.query.options.permissionPrompts, 'host');
      assert.deepEqual(observed.query.options.tools, PROJECT_TOOLS); assert.deepEqual(observed.query.options.allowedTools, PROJECT_TOOLS);
      assert.deepEqual(observed.query.options.settingSources, []); assert.equal(observed.query.options.settings.disableAllHooks, true);
      assert.deepEqual(observed.query.options.settings.attribution, { commit: '', pr: '' });
      assert.deepEqual(observed.query.options.mcpServers, {}); assert.deepEqual(observed.query.options.agents, {});
      assert.equal(observed.permissions[0].behavior, 'allow');
      const requests = events.filter(event => event.kind === 'provider_request');
      assert.equal(requests.length, 2); assert.equal(requests[1].body.messages.length, 3);
      assert.equal(requests[1].body.messages[2].content[0].tool_use_id, 'toolu_read_1');
      assert.equal(requests[0].body.system instanceof Array ? requests[0].body.system[2].text : requests[0].body.system, PROJECT_SYSTEM_PROMPT);
    }
    const failedTool = await run({ projectFixture: true, projectToolRoot: root, toolError: true }, PROJECT_START);
    assert.equal(failedTool.result.ok, true); assert.equal(failedTool.events.filter(event => event.kind === 'tool_activity').at(-1).phase, 'failed');
    const autoAllowed = await run({ projectFixture: true, projectToolRoot: root, permission: false }, PROJECT_START);
    assert.equal(autoAllowed.result.ok, true);
  } finally { await rm(root, { recursive: true, force: true }); }
});
await check('project rejects unknown tools, malformed IDs and duplicate provider calls before native execution', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-refuse-')));
  try {
    for (const changed of [
      { ...PROJECT_ROUNDS[0][1], name: 'Agent' }, { ...PROJECT_ROUNDS[0][1], id: '../secret' },
      { ...PROJECT_ROUNDS[0][1], id: null }, { ...PROJECT_ROUNDS[0][1], input: { file_path: '../escape' } },
      { type: 'tool_use', id: 'toolu_bash', name: 'Bash', input: { command: 'true', run_in_background: true } },
    ]) {
      const result = await run({ projectFixture: true, projectToolRoot: root, rounds: [[changed], PROJECT_ROUNDS[1]] }, PROJECT_START);
      assert.equal(result.result.ok, false); assert.equal(result.events.filter(event => event.kind === 'tool_activity').length, 0);
    }
    const repeated = await run({ projectFixture: true, projectToolRoot: root,
      rounds: [[PROJECT_ROUNDS[0][1]], [PROJECT_ROUNDS[0][1]], PROJECT_ROUNDS[1]] }, PROJECT_START);
    assert.equal(repeated.result.error_code, 'PROJECT_TOOL_REJECTED');
    for (const initChange of [init => ({ ...init, tools: ['Read'] }), init => ({ ...init, tools: [...PROJECT_TOOLS, 'Agent'] }),
      init => ({ ...init, tools: PROJECT_TOOLS.map(() => 'Read') }), init => ({ ...init, mcp_servers: ['server'] }),
      init => ({ ...init, cwd: '/home/claude/work' }), init => ({ ...init, permissionMode: 'bypassPermissions' })])
      assert.equal((await run({ projectFixture: true, projectToolRoot: root, initChange }, PROJECT_START)).result.ok, false);
  } finally { await rm(root, { recursive: true, force: true }); }
});
await check('project disables native attribution and rejects added prompt wrappers for both providers', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-native-prompt-')));
  // Captured from the pinned CLI in a synthetic no-network VM with Bash enabled.
  const attribution = "<system-reminder>\nAttribution for git commits and pull requests you create from here on (this replaces Claude Code's own earlier attribution guidance, such as a previous copy of this reminder; the user's own instructions about these lines, such as a CLAUDE.md or memory rule, take precedence over this reminder, but do not add attribution lines this reminder leaves out):\n- End git commit messages with:\nCo-Authored-By: Claude Code <noreply@anthropic.com>\n- End pull request descriptions with:\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n</system-reminder>\n";
  const wrap = (body, extra = attribution) => ({ ...body, messages: [{ ...body.messages[0],
    content: [{ type: 'text', text: extra }, ...body.messages[0].content] }, ...body.messages.slice(1)] });
  try {
    for (const provider of ['deepseek-api', 'claude-subscription']) {
      const start = { ...PROJECT_START, provider, ...(provider === 'claude-subscription' ? { model: 'sonnet', identity: IDENTITY } : {}) };
      const accepted = await run({ projectFixture: true, projectToolRoot: root }, start);
      assert.equal(accepted.result.ok, true);
      assert.deepEqual(accepted.observed.query.options.settings.attribution, { commit: '', pr: '' });
      for (const request of accepted.events.filter(event => event.kind === 'provider_request'))
        assert.deepEqual(request.body.messages[0], { role: 'user', content: start.prompt });
    }
    for (const extra of [attribution, attribution.replace('Co-Authored-By: Claude Code', 'Co-Authored-By: Claude Sonnet 5.5'),
      '<system-reminder>arbitrary native text</system-reminder>\n', attribution.trim(), attribution.replace('Claude Code', 'untrusted source'), START.prompt]) {
      const refused = await run({ projectFixture: true, projectToolRoot: root, bodyChange: body => wrap(body, extra) }, PROJECT_START);
      assert.equal(refused.result.error_code, 'CLI_REQUEST_REJECTED');
      assert.equal(refused.events.filter(event => event.kind === 'provider_request').length, 0);
    }
    const textOnly = await run({ bodyChange: body => wrap(body) });
    assert.equal(textOnly.result.error_code, 'CLI_REQUEST_REJECTED');
  } finally { await rm(root, { recursive: true, force: true }); }
});
await check('project bounds and strips native system metadata without changing the provider transcript', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-native-system-')));
  const marker = 'NATIVE_METADATA_ONLY';
  const envelope = text => ({ role: 'system', content: [{ type: 'text', text, cache_control: { type: 'ephemeral', ttl: '1h' } }] });
  const bodies = [
    `${marker}: environment text from native`,
    `${marker}: accounting and progress may vary independently by model`,
    `${marker}: arbitrary instructions must never become provider instructions`,
  ];
  const rounds = [PROJECT_ROUNDS[0], [{ ...PROJECT_ROUNDS[0][1], id: 'toolu_read_2' }], PROJECT_ROUNDS[1]];
  try {
    const accepted = await run({ projectFixture: true, projectToolRoot: root, rounds, bodyChange: (body, index) => {
      const messages = [body.messages[0], index ? { role: 'system', content: bodies[0] } : envelope(bodies[0])];
      for (let cursor = 1; cursor < body.messages.length; cursor += 2) {
        messages.push(body.messages[cursor], body.messages[cursor + 1], cursor === 1 ?
          { role: 'system', content: bodies[1], output_config: { effort: 'medium' } } : envelope(bodies[2]));
      }
      return { ...body, messages };
    } }, PROJECT_START);
    assert.equal(accepted.result.ok, true);
    const requests = accepted.events.filter(event => event.kind === 'provider_request');
    assert.equal(requests.length, 3);
    assert.deepEqual(requests.map(event => event.body.messages.length), [1, 3, 5]);
    for (const { body } of requests) {
      assert.equal(body.system, PROJECT_SYSTEM_PROMPT);
      assert.equal(JSON.stringify(body).includes(marker), false);
      assert.ok(body.messages.every(message => message.role !== 'system'));
      assert.deepEqual(body.messages[0], { role: 'user', content: PROJECT_START.prompt });
    }
    assert.deepEqual(requests[2].body.messages[1].content, rounds[0]);
    assert.deepEqual(requests[2].body.messages[3].content, rounds[1]);
    for (const content of ['x'.repeat(2048), [{ type: 'text', text: 'single bounded text block' }]]) {
      const bounded = await run({ projectFixture: true, projectToolRoot: root, bodyChange: body => ({ ...body,
        messages: [body.messages[0], { role: 'system', content }, ...body.messages.slice(1)] }) }, PROJECT_START);
      assert.equal(bounded.result.ok, true);
    }
    const invalid = [
      { role: 'system', content: '' }, { role: 'system', content: 'x'.repeat(2049) },
      { role: 'system', content: null }, { role: 'system', content: [] },
      { role: 'system', content: [{ type: 'text', text: 'one' }, { type: 'text', text: 'two' }] },
      { role: 'system', content: [{ type: 'image', source: { type: 'url', url: 'https://invalid.example/' } }] },
      { role: 'system', content: [{ type: 'text', text: 1 }] },
      { role: 'system', content: [{ type: 'text', text: 'text', unknown: true }] },
      { ...envelope('text'), unknown: true },
      { ...envelope('text'), output_config: { effort: 'unbounded' } },
      { ...envelope('text'), output_config: { effort: 'medium', unknown: true } },
    ];
    for (const changed of invalid) {
      for (const position of ['initial', 'tool']) {
        const refused = await run({ projectFixture: true, projectToolRoot: root, bodyChange: (body, index) => {
          const messages = [...body.messages];
          if (position === 'initial') messages.splice(1, 0, changed);
          else if (index) messages.push(changed);
          return { ...body, messages };
        } }, PROJECT_START);
        assert.equal(refused.result.error_code, 'CLI_REQUEST_REJECTED');
      }
    }
    for (const misplaced of [
      body => [envelope('before prompt'), ...body.messages],
      body => [body.messages[0], envelope('duplicate'), envelope('duplicate'), ...body.messages.slice(1)],
      body => [body.messages[0], body.messages[1], envelope('before tool result'), body.messages[2]],
      body => [...body.messages, envelope('duplicate'), envelope('duplicate')],
    ]) {
      const refused = await run({ projectFixture: true, projectToolRoot: root, bodyChange: (body, index) => index ?
        { ...body, messages: misplaced(body) } : body }, PROJECT_START);
      assert.equal(refused.result.error_code, 'CLI_REQUEST_REJECTED');
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
await check('native Edit omitted replace_all matches only the pinned false default', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-edit-default-')));
  const edit = { type: 'tool_use', id: 'toolu_edit_default', name: 'Edit', input: { file_path: 'note.txt', old_string: 'old', new_string: 'new' } };
  const rounds = [[edit], PROJECT_ROUNDS[1]];
  try {
    const accepted = await run({ projectFixture: true, projectToolRoot: root, rounds,
      nativeToolInput: (name, input) => name === 'Edit' ? { replace_all: false, ...input } : input }, PROJECT_START);
    assert.equal(accepted.result.ok, true);
    assert.equal(accepted.observed.permissions[0].behavior, 'allow');
    assert.equal(accepted.events.filter(event => event.kind === 'provider_request')[1].body.messages[1].content[0].input.replace_all, false);
    for (const nativeToolInput of [
      (name, input) => ({ ...input, replace_all: true }),
      (name, input) => ({ ...input, replace_all: null }),
      (name, input) => ({ ...input, replace_all: false, unrelated: false }),
      (name, input) => ({ ...input, replace_all: false, new_string: 'different' }),
    ]) {
      const rejected = await run({ projectFixture: true, projectToolRoot: root, rounds, nativeToolInput }, PROJECT_START);
      assert.equal(rejected.result.error_code, 'PROJECT_TOOL_REJECTED');
      assert.equal(rejected.events.filter(event => event.kind === 'tool_activity').length, 0);
    }
    const readWithUnknownDefault = await run({ projectFixture: true, projectToolRoot: root,
      nativeToolInput: (name, input) => ({ ...input, replace_all: false }) }, PROJECT_START);
    assert.equal(readWithUnknownDefault.result.error_code, 'PROJECT_TOOL_REJECTED');
  } finally { await rm(root, { recursive: true, force: true }); }
});
await check('project SDK and provider transcripts require exact call/result IDs, order and content', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-transcript-')));
  try {
    for (const changes of [
      { assistantChange: event => event.message.content[0].type === 'tool_use' ? { ...event, type: 'user' } : event },
      { assistantChange: event => ({ ...event, parent_tool_use_id: 'unexpected-subagent' }) },
      { assistantChange: event => ({ ...event, session_id: '00000000-0000-4000-8000-000000000002' }) },
      { userChange: event => ({ ...event, message: { ...event.message, role: 'assistant' } }) },
      { assistantChange: event => event.message.content[0].type === 'tool_use' ? { ...event, message: { content: [{ ...event.message.content[0], id: 'unknown' }] } } : event },
      { userChange: event => ({ ...event, message: { content: [{ ...event.message.content[0], tool_use_id: 'unknown' }] } }) },
      { userChange: event => ({ ...event, message: { content: [event.message.content[0], event.message.content[0]] } }) },
      { userChange: event => ({ ...event, message: { content: [{ ...event.message.content[0], content: 'tampered' }] } }) },
      { bodyChange: (body, index) => index ? { ...body, messages: body.messages.slice(0, -1) } : body },
      { bodyChange: (body, index) => index ? { ...body, messages: body.messages.map(message => message.role === 'user' && Array.isArray(message.content) && message.content[0]?.type === 'tool_result' ? { ...message, content: [{ ...message.content[0], tool_use_id: 'unknown' }] } : message) } : body },
      { bodyChange: body => ({ ...body, tools: [...body.tools.slice(1), { ...body.tools[0], name: 'Agent' }] }) },
      { resultChange: event => ({ ...event, result: 'Inspecting the project.\n' + event.result }) },
      { resultChange: event => ({ ...event, num_turns: 1 }) },
    ]) assert.equal((await run({ projectFixture: true, projectToolRoot: root, ...changes }, PROJECT_START)).result.ok, false);
  } finally { await rm(root, { recursive: true, force: true }); }
});
await check('project Read results preserve bounded embedded images and PDFs but reject URL sources', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-media-')));
  try {
    for (const media_type of ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'application/pdf']) {
      const media = { type: media_type === 'application/pdf' ? 'document' : 'image', source: { type: 'base64', media_type, data: Buffer.from('synthetic media').toString('base64') } };
      const accepted = await run({ projectFixture: true, projectToolRoot: root, toolContent: [{ type: 'text', text: 'synthetic attachment' }, media] }, PROJECT_START);
      assert.equal(accepted.result.ok, true);
      assert.deepEqual(accepted.events.filter(event => event.kind === 'provider_request')[1].body.messages[2].content[0].content[1], media);
    }
    for (const media of [
      { type: 'image', source: { type: 'url', url: 'https://example.invalid/image.png' } },
      { type: 'document', source: { type: 'base64', media_type: 'text/html', data: 'YQ==' } },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'YR==' } },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'YQ==', extra: 'denied' } },
    ]) {
      const denied = await run({ projectFixture: true, projectToolRoot: root, toolContent: [media] }, PROJECT_START);
      assert.equal(denied.result.error_code, 'PROJECT_TOOL_RESULT_REJECTED');
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
await check('project cancellation and timeout close the owned query without touching the selected directory', async () => {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'guest-project-cancel-')));
  await writeFile(path.join(root, 'sentinel'), 'preserved');
  try {
    const cancelled = await run({ projectFixture: true, projectToolRoot: root, blocked: true }, PROJECT_START, { afterInit: ({ write }) => write({ kind: 'cancel' }) });
    assert.equal(cancelled.result.error_code, 'CHAT_CANCELLED'); assert.ok(cancelled.observed.closed > 0);
    const timeout = await run({ projectFixture: true, projectToolRoot: root, blocked: true, timeoutMs: 25 }, PROJECT_START);
    assert.equal(timeout.result.error_code, 'TOTAL_TIMEOUT'); assert.ok(timeout.observed.closed > 0);
    assert.equal(await readFile(path.join(root, 'sentinel'), 'utf8'), 'preserved');
    assert.equal(PROJECT_LIMITS.timeoutMs, 480_000); assert.equal(PROJECT_LIMITS.requests, 24);
  } finally { await rm(root, { recursive: true, force: true }); }
});
process.stdout.write(`${JSON.stringify({ schema: 'guest-text-runtime-local-checks/v1', passed: checks,
  official_sdk_imported: false, native_cli_executed: false, external_requests: false, real_credentials_used: false })}\n`);
