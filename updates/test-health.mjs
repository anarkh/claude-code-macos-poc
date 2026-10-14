import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { link, mkdtemp, mkdir, realpath, rename, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { PassThrough, Readable } from 'node:stream';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { runHealthProbe, runHealthStdio } from './health.mjs';

const HEALTH_SCHEMA = 'runtime-update-health/v1';
const EVENT_SCHEMA = 'deepseek-text-chat-event/v1';
const ACK = 'RUNTIME_UPDATE_HEALTH_OK';
const ERROR = { type: 'error', code: 'UPDATE_HEALTH_FAILED' };
const SESSION_ID = 'fcbcb8dd-8564-4e5a-a574-2203a5a54c8c';
const SCRIPT = fileURLToPath(new URL('./health.mjs', import.meta.url));
const SYSTEM = 'You are an assistant in a text-only conversation. Respond to the user. No tools are available; do not emit tool calls.';
const IDENTITY = "You are a Claude agent, built on Anthropic's Claude Agent SDK.";
const SUBSCRIPTION_TOKEN = 'sk-ant-oat01-UPDATE-HEALTH-INERT-NOT-A-REAL-CREDENTIAL';
const VERSIONS = { sdk: '0.3.295', cli: '2.1.295' };
const GATES = [
  { provider: 'deepseek-api', model: 'deepseek-flash[1m]', request_id: '06701978-4a06-4b97-802f-b5d2e2d84066' },
  { provider: 'claude-subscription', model: 'sonnet', request_id: '06701978-4a06-4b97-802f-b5d2e2d84067' },
  { provider: 'claude-subscription', model: 'opus', request_id: '06701978-4a06-4b97-802f-b5d2e2d84068' },
  { provider: 'claude-subscription', model: 'haiku', request_id: '06701978-4a06-4b97-802f-b5d2e2d84069' },
];
const SUBSCRIPTION_HEADERS = ['anthropic-version', 'anthropic-beta', 'x-app', 'user-agent',
  'x-claude-code-session-id', 'anthropic-dangerous-direct-browser-access'];

async function contentsFixture(callback) {
  // /var is a symlink on macOS. Production admission checks every ancestor.
  const temporaryRoot = await realpath(os.tmpdir());
  const root = await mkdtemp(path.join(temporaryRoot, 'runtime-health-unit-'));
  const contentsRoot = path.join(root, 'Candidate.app', 'Contents');
  const sdk = path.join(contentsRoot, 'Resources', 'Runtime', 'sdk');
  await mkdir(sdk, { recursive: true });
  const runtimeFile = path.join(sdk, 'vm-text-chat.mjs');
  await writeFile(runtimeFile, 'export {};\n');
  const baseFile = path.join(contentsRoot, 'Resources', 'Runtime', 'host', 'text-runtime', 'images', 'base.json');
  await mkdir(path.dirname(baseFile), { recursive: true });
  await writeFile(baseFile, JSON.stringify({ schema: 'claude-text-vm-base/v1',
    sdk_version: VERSIONS.sdk, cli_version: VERSIONS.cli }));
  try {
    return await callback({ root, contentsRoot, sdk, runtimeFile, baseFile,
      input: { schema: HEALTH_SCHEMA, contentsRoot } });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

function deferred() {
  let resolve;
  const promise = new Promise(value => { resolve = value; });
  return { promise, resolve };
}

function runtimeFixture(options = {}) {
  const observed = { launches: 0, runs: 0, input: null, inputs: [], outbound: [], sse: '', sses: [],
    dependencies: [], children: [], originalWrites: [], stdinWrites: [], sessions: [], cleanups: 0, cleaned: false };
  let child;
  const makeChild = () => {
    const value = new EventEmitter();
    value.stdout = new PassThrough(); value.stderr = new PassThrough(); value.stdin = new PassThrough();
    value.kill = () => true;
    observed.children.push(value); observed.originalWrites.push(value.stdin.write);
    const writes = []; observed.stdinWrites.push(writes);
    value.stdin.on('data', bytes => writes.push(Buffer.from(bytes).toString('utf8')));
    return value;
  };
  const productionLauncher = async () => {
    observed.launches++;
    child ??= makeChild();
    return child;
  };
  const runVMTextChat = async (input, emit, dependencies) => {
    child = makeChild();
    const selected = (!options.targetProvider || input.provider === options.targetProvider) &&
      (!options.targetModel || input.model === options.targetModel) ? options : {};
    const versions = options.versions ?? VERSIONS;
    const sessionID = randomUUID(); observed.sessions.push(sessionID);
    const nativeModel = input.provider === 'claude-subscription' ? `claude-${input.model}-5-5` : input.model;
    observed.runs++;
    observed.input ??= input; observed.inputs.push(input); observed.dependencies.push(dependencies);
    if (selected.throwError) throw new Error('PRIVATE_RUNTIME_DIAGNOSTIC_MUST_NOT_LEAK');
    if (selected.earlyError) return { type: 'error', code: 'PRIVATE_PROVIDER_ERROR' };
    if (!selected.noLaunch) await dependencies.launch();
    if (selected.doubleLaunch) await dependencies.launch();
    child.stdin.write(JSON.stringify({ kind: 'health-fixture', model: input.model,
      ...(selected.stdinCredential ? { private: input.apiKey ?? input.subscriptionToken } : {}) }) + '\n');
    if (selected.stdinBytes !== undefined) child.stdin.write(selected.stdinBytes);
    const frame = value => {
      const bytes = Buffer.from(JSON.stringify(value) + '\n');
      for (let index = 0; index < bytes.length; index += selected.frameChunkBytes ?? bytes.length) {
        child.stdout.write(bytes.subarray(index, index + (selected.frameChunkBytes ?? bytes.length)));
      }
    };
    const init = { kind: 'native_init', model: nativeModel, session_id: sessionID, no_tools: true,
      ...selected.initChange };
    if (!selected.missingInit) {
      frame(init);
      if (selected.doubleInit) frame(init);
    }
    const event = (type, fields = {}) => ({ schema: EVENT_SCHEMA, request_id: input.request_id,
      model: input.model, fixture_only: false, type, ...fields, ...selected.eventChange });
    if (!selected.missingStarted) emit(event('started', { no_tools: true }));
    if (selected.doubleStarted) emit(event('started', { no_tools: true }));
    if (!selected.noTransport) {
      const subscription = input.provider === 'claude-subscription';
      let parameters = { provider: input.provider, apiKey: input.apiKey, subscriptionToken: input.subscriptionToken,
        headers: subscription ? {
          'anthropic-version': '2023-06-01', 'x-app': 'cli',
          'user-agent': `claude-cli/${versions.cli} (external, sdk-ts, agent-sdk/${versions.sdk})`,
          'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20,mid-conversation-system-2026-04-07',
          'x-claude-code-session-id': sessionID, 'anthropic-dangerous-direct-browser-access': 'true',
        } : {}, network: input.network, signal: dependencies.signal,
        body: { model: subscription ? nativeModel : 'deepseek-flash', stream: true, max_tokens: 4096,
          thinking: { type: 'disabled' }, tools: [], system: subscription ? [
            { type: 'text', text: `x-anthropic-billing-header: cc_version=${versions.cli}.c4e; cc_entrypoint=sdk-ts;` },
            { type: 'text', text: IDENTITY }, { type: 'text', text: SYSTEM },
          ] : SYSTEM,
          messages: [{ role: 'user', content: input.messages[0].text }],
          ...(subscription ? { metadata: { user_id: JSON.stringify({ device_id: 'b'.repeat(64),
            account_uuid: '', session_id: sessionID }) } } : {}) },
        ...selected.transportChange };
      if (selected.bodyChange) parameters.body = { ...parameters.body, ...selected.bodyChange };
      if (selected.headersChange) parameters.headers = { ...parameters.headers, ...selected.headersChange };
      if (selected.requestChange) parameters = selected.requestChange(parameters, input);
      const upstream = await dependencies.transport(parameters);
      observed.outbound.push(parameters);
      assert.equal(upstream.statusCode, 200);
      assert.match(upstream.contentType, /^text\/event-stream(?:;|$)/);
      let sse = '';
      for await (const bytes of upstream.stream) sse += Buffer.from(bytes).toString('utf8');
      observed.sses.push(sse); observed.sse += sse;
      if (selected.doubleTransport) await dependencies.transport(parameters);
    }
    if (!selected.missingDelta) emit(event('delta', { text: selected.deltaText ?? ACK }));
    if (!selected.missingStop) frame({ kind: 'vm_stopped', cleanup_complete: true, ...selected.stopChange });
    if (selected.doubleStop) frame({ kind: 'vm_stopped', cleanup_complete: true });
    if (selected.rawFrame) child.stdout.write(selected.rawFrame);
    child.stdout.end();
    child.stderr.end();
    observed.cleanups++; observed.cleaned = true;
    const terminal = event('completed', { text: ACK, no_tools: true, cli_exit: 0, cli_signal: null,
      temporary_removed: true, proxy_closed: true, request_count: 1, ...selected.terminalChange });
    if (!selected.missingCompleted) emit(terminal);
    if (selected.doubleCompleted) emit(terminal);
    return terminal;
  };
  return { observed, module: { runVMTextChat, productionLauncher } };
}

async function runFixture(input, options = {}, probeOptions = {}) {
  const fixture = runtimeFixture(options);
  const result = await runHealthProbe(input, { testOnly: true, runtimeModule: fixture.module,
    timeoutMs: 1000, ...probeOptions });
  return { ...fixture, result };
}

test('health requires all four isolated native text gates, bounded transport and cleanup receipts', async () => {
  await contentsFixture(async ({ input }) => {
    const fixture = await runFixture(input);
    assert.deepEqual(fixture.result, { type: 'healthy' });
    assert.equal(fixture.observed.runs, 4);
    assert.equal(fixture.observed.launches, 4);
    assert.equal(fixture.observed.cleanups, 4);
    assert.equal(fixture.observed.cleaned, true);
    assert.equal(fixture.observed.outbound.length, 4);
    assert.equal(new Set(fixture.observed.children).size, 4);
    assert.equal(new Set(fixture.observed.sessions).size, 4);
    assert.deepEqual(fixture.observed.inputs.map(({ provider, model, request_id }) => ({ provider, model, request_id })), GATES);
    const runtimeInput = fixture.observed.input;
    assert.equal(runtimeInput.schema, 'deepseek-text-chat/v1');
    assert.equal(runtimeInput.provider, 'deepseek-api');
    assert.equal(runtimeInput.model, 'deepseek-flash[1m]');
    assert.equal(runtimeInput.apiKey, 'sk-UPDATE-HEALTH-INERT-NOT-A-REAL-CREDENTIAL');
    assert.match(runtimeInput.request_id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    assert.deepEqual(runtimeInput.messages.map(message => message.role), ['user']);
    assert.equal(typeof runtimeInput.messages[0].text, 'string');
    assert.ok(runtimeInput.messages[0].text.includes(ACK));
    assert.equal(runtimeInput.subscriptionToken, undefined);
    assert.deepEqual(runtimeInput.text_skills, []);
    assert.deepEqual(runtimeInput.network, { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:1', dnsPolicy: 'proxy-only' });
    assert.deepEqual(runtimeInput.runtime, { schema: 'app-runtime-profile/v1', timeZone: 'UTC', language: 'en' });
    for (let index = 0; index < GATES.length; index++) {
      const input = fixture.observed.inputs[index], outbound = fixture.observed.outbound[index];
      assert.deepEqual(input.network, runtimeInput.network);
      assert.deepEqual(input.runtime, runtimeInput.runtime);
      assert.deepEqual(input.text_skills, []);
      assert.deepEqual(input.messages, runtimeInput.messages);
      assert.equal(fixture.observed.dependencies[index].testOnly, true);
      assert.equal(fixture.observed.dependencies[index].signal instanceof AbortSignal, true);
      assert.equal(fixture.observed.children[index].stdin.write, fixture.observed.originalWrites[index], 'stdin observer must be restored');
      assert.doesNotMatch(fixture.observed.stdinWrites[index].join(''), /sk-UPDATE|sk-ant-oat01/);
      const frames = fixture.observed.sses[index].split('\n').filter(line => line.startsWith('data: '))
        .map(line => JSON.parse(line.slice(6)));
      assert.equal(frames.find(frame => frame.type === 'message_start').message.model, outbound.body.model);
      assert.ok(frames.some(frame => frame.type === 'content_block_delta' && frame.delta.text === ACK));
      assert.ok(frames.some(frame => frame.type === 'message_stop'));
      if (index === 0) continue;
      assert.equal(input.apiKey, undefined);
      assert.equal(input.subscriptionToken, SUBSCRIPTION_TOKEN);
      assert.deepEqual(Object.keys(outbound.headers).sort(), [...SUBSCRIPTION_HEADERS].sort());
      assert.equal(outbound.headers['x-claude-code-session-id'], fixture.observed.sessions[index]);
      assert.equal(outbound.headers['user-agent'], `claude-cli/${VERSIONS.cli} (external, sdk-ts, agent-sdk/${VERSIONS.sdk})`);
      assert.equal(outbound.body.model, `claude-${input.model}-5-5`);
      assert.deepEqual(outbound.body.system, [
        { type: 'text', text: `x-anthropic-billing-header: cc_version=${VERSIONS.cli}.c4e; cc_entrypoint=sdk-ts;` },
        { type: 'text', text: IDENTITY }, { type: 'text', text: SYSTEM },
      ]);
      assert.deepEqual(JSON.parse(outbound.body.metadata.user_id), { device_id: 'b'.repeat(64),
        account_uuid: '', session_id: fixture.observed.sessions[index] });
    }
  });
});

test('split native frames pass without changing the process environment', async () => {
  await contentsFixture(async ({ input }) => {
    const environmentBefore = JSON.stringify(process.env);
    assert.deepEqual((await runFixture(input, { frameChunkBytes: 1 })).result, { type: 'healthy' });
    assert.equal(JSON.stringify(process.env) === environmentBefore, true, 'probe must preserve the process environment');
  });
});

const proofFailures = [
  ['runtime error', { earlyError: true }],
  ['runtime exception', { throwError: true }],
  ['no VM launch', { noLaunch: true }],
  ['duplicate VM launches', { doubleLaunch: true }],
  ['missing native initialization', { missingInit: true }],
  ['duplicate native initialization', { doubleInit: true }],
  ['native tools enabled', { initChange: { no_tools: false } }],
  ['wrong native model', { initChange: { model: 'OTHER_MODEL' } }],
  ['invalid native session identity', { initChange: { session_id: 'not-a-uuid' } }],
  ['missing native cleanup receipt', { missingStop: true }],
  ['native cleanup incomplete', { stopChange: { cleanup_complete: false } }],
  ['duplicate native cleanup receipt', { doubleStop: true }],
  ['malformed native frame', { rawFrame: Buffer.from('PRIVATE_INVALID_JSON\n') }],
  ['unterminated native frame', { rawFrame: Buffer.from('{"kind":"vm_stopped"}') }],
  ['missing started event', { missingStarted: true }],
  ['duplicate started event', { doubleStarted: true }],
  ['missing delta event', { missingDelta: true }],
  ['wrong delta text', { deltaText: 'FORGED_RESPONSE' }],
  ['missing completed event', { missingCompleted: true }],
  ['duplicate completed event', { doubleCompleted: true }],
  ['fixture event', { eventChange: { fixture_only: true } }],
  ['wrong event schema', { eventChange: { schema: 'other/v1' } }],
  ['wrong event request identity', { eventChange: { request_id: SESSION_ID } }],
  ['wrong event model', { eventChange: { model: 'OTHER_MODEL' } }],
  ['wrong completed text', { terminalChange: { text: 'FORGED_RESPONSE' } }],
  ['completed tools enabled', { terminalChange: { no_tools: false } }],
  ['nonzero native exit', { terminalChange: { cli_exit: 1 } }],
  ['native exit by signal', { terminalChange: { cli_signal: 'SIGTERM' } }],
  ['temporary run remains', { terminalChange: { temporary_removed: false } }],
  ['provider proxy remains open', { terminalChange: { proxy_closed: false } }],
  ['no provider request receipt', { terminalChange: { request_count: 0 } }],
  ['multiple provider request receipts', { terminalChange: { request_count: 2 } }],
  ['missing transport request', { noTransport: true }],
  ['multiple transport requests', { doubleTransport: true }],
  ['wrong transport provider', { transportChange: { provider: 'OTHER_PROVIDER' } }],
  ['wrong transport credential', { transportChange: { apiKey: 'PRIVATE_UNEXPECTED_KEY' } }],
  ['subscription credential supplied', { transportChange: { subscriptionToken: 'PRIVATE_UNEXPECTED_TOKEN' } }],
  ['untrusted provider header', { transportChange: { headers: { 'x-untrusted': 'private' } } }],
  ['network policy replaced', { transportChange: { network: undefined } }],
  ['provider model replaced', { bodyChange: { model: 'OTHER_MODEL' } }],
  ['provider tools supplied', { bodyChange: { tools: [{ name: 'Bash' }] } }],
  ['provider prompt replaced', { bodyChange: { messages: [{ role: 'user', content: 'FORGED_PROMPT' }] } }],
  ['credential sent to VM stdin', { stdinCredential: true }],
];
for (const [index, gate] of GATES.entries()) {
  for (const [name, options] of proofFailures) {
    test(`${gate.provider}/${gate.model}: ${name} cannot produce a healthy result`, async () => {
      await contentsFixture(async ({ input }) => {
        const fixture = await runFixture(input, { ...options, targetProvider: gate.provider, targetModel: gate.model });
        assert.deepEqual(fixture.result, ERROR);
        assert.deepEqual(fixture.observed.inputs.map(({ provider, model, request_id }) => ({ provider, model, request_id })), GATES.slice(0, index + 1),
          'the failing gate must preserve earlier successful probes and stop subsequent probes');
        fixture.observed.children.forEach((child, childIndex) => {
          assert.equal(child.stdin.write, fixture.observed.originalWrites[childIndex], 'failure must restore the stdin observer');
        });
      });
    });
  }
}

test('candidate versions determine subscription user-agent and billing markers for every alias', async () => {
  await contentsFixture(async ({ input, baseFile }) => {
    const versions = { sdk: '0.3.296', cli: '2.1.296' };
    await writeFile(baseFile, JSON.stringify({ schema: 'claude-text-vm-base/v1',
      sdk_version: versions.sdk, cli_version: versions.cli }));
    const stale = await runFixture(input);
    assert.deepEqual(stale.result, ERROR);
    assert.deepEqual(stale.observed.inputs.map(value => value.model), ['deepseek-flash[1m]', 'sonnet']);
    const compatible = await runFixture(input, { versions });
    assert.deepEqual(compatible.result, { type: 'healthy' });
    for (const outbound of compatible.observed.outbound.slice(1)) {
      assert.equal(outbound.headers['user-agent'], 'claude-cli/2.1.296 (external, sdk-ts, agent-sdk/0.3.296)');
      assert.equal(outbound.body.system[0].text, 'x-anthropic-billing-header: cc_version=2.1.296.c4e; cc_entrypoint=sdk-ts;');
    }
  });
});

const subscriptionFailures = [
  ['missing OAuth beta', { headersChange: { 'anthropic-beta': 'claude-code-20250219' } }],
  ['missing CLI beta', { headersChange: { 'anthropic-beta': 'oauth-2025-04-20' } }],
  ['unknown beta', { headersChange: { 'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20,untrusted-20260101' } }],
  ['duplicate beta', { headersChange: { 'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20,oauth-2025-04-20' } }],
  ['oversized beta', { headersChange: { 'anthropic-beta': 'a'.repeat(4097) } }],
  ['wrong user-agent', { headersChange: { 'user-agent': 'claude-cli/2.1.296 (external, sdk-ts, agent-sdk/0.3.295)' } }],
  ['wrong header session', { headersChange: { 'x-claude-code-session-id': SESSION_ID } }],
  ['wrong API revision', { headersChange: { 'anthropic-version': '2026-01-01' } }],
  ['wrong app identity', { headersChange: { 'x-app': 'other' } }],
  ['missing direct-browser declaration', { headersChange: { 'anthropic-dangerous-direct-browser-access': 'false' } }],
  ['arbitrary child header', { headersChange: { 'x-stainless-os': 'PRIVATE_MACHINE_DIAGNOSTIC' } }],
  ['unsanitized authorization header', { headersChange: { authorization: 'Bearer PRIVATE_TOKEN' } }],
  ['raw model alias', { bodyChange: { model: 'sonnet' } }],
  ['wrong thinking mode', { bodyChange: { thinking: { type: 'enabled' } } }],
  ['larger response token budget', { bodyChange: { max_tokens: 4097 } }],
  ['non-streaming request', { bodyChange: { stream: false } }],
  ['arbitrary request field', { bodyChange: { private: 'PRIVATE_BODY_DIAGNOSTIC' } }],
  ['missing billing block', { requestChange: parameters => ({ ...parameters,
    body: { ...parameters.body, system: parameters.body.system.slice(1) } }) }],
  ['stale billing version', { requestChange: parameters => ({ ...parameters, body: { ...parameters.body,
    system: parameters.body.system.map((block, index) => index === 0 ? { ...block,
      text: 'x-anthropic-billing-header: cc_version=2.1.294.c4e; cc_entrypoint=sdk-ts;' } : block) } }) }],
  ['altered official identity', { requestChange: parameters => ({ ...parameters, body: { ...parameters.body,
    system: parameters.body.system.map((block, index) => index === 1 ? { ...block, text: 'PRIVATE_IDENTITY' } : block) } }) }],
  ['extra system block field', { requestChange: parameters => ({ ...parameters, body: { ...parameters.body,
    system: parameters.body.system.map((block, index) => index === 0 ? { ...block, cache_control: { type: 'ephemeral' } } : block) } }) }],
  ['arbitrary metadata field', { requestChange: parameters => ({ ...parameters, body: { ...parameters.body,
    metadata: { ...parameters.body.metadata, private: 'PRIVATE_METADATA' } } }) }],
  ['malformed metadata identity', { bodyChange: { metadata: { user_id: 'PRIVATE_NOT_JSON' } } }],
  ['unbounded metadata identity', { bodyChange: { metadata: { user_id: 'a'.repeat(513) } } }],
  ['non-inert account identity', { requestChange: parameters => ({ ...parameters, body: { ...parameters.body,
    metadata: { user_id: JSON.stringify({ ...JSON.parse(parameters.body.metadata.user_id), account_uuid: SESSION_ID }) } } }) }],
  ['wrong metadata session', { requestChange: parameters => ({ ...parameters, body: { ...parameters.body,
    metadata: { user_id: JSON.stringify({ ...JSON.parse(parameters.body.metadata.user_id), session_id: SESSION_ID }) } } }) }],
  ['invalid device identity', { requestChange: parameters => ({ ...parameters, body: { ...parameters.body,
    metadata: { user_id: JSON.stringify({ ...JSON.parse(parameters.body.metadata.user_id), device_id: 'PRIVATE_DEVICE' }) } } }) }],
  ['oversized VM stdin frame', { stdinBytes: Buffer.alloc(1_048_577, 0x20) }],
];
for (const [index, gate] of GATES.entries()) {
  if (index === 0) continue;
  for (const [name, options] of subscriptionFailures) {
    test(`${gate.model}: ${name} keeps subscription health closed`, async () => {
      await contentsFixture(async ({ input }) => {
        const fixture = await runFixture(input, { ...options, targetProvider: gate.provider, targetModel: gate.model });
        assert.deepEqual(fixture.result, ERROR);
        assert.deepEqual(fixture.observed.inputs.map(value => value.model), GATES.slice(0, index + 1).map(value => value.model));
      });
    });
  }
}

test('subscription health permits the existing bounded beta list for each model', async () => {
  await contentsFixture(async ({ input }) => {
    const beta = ['claude-code-20250219', 'oauth-2025-04-20', 'mid-conversation-system-2026-04-07',
      'interleaved-thinking-2025-05-14', 'thinking-token-count-2026-05-13', 'context-management-2025-06-27',
      'prompt-caching-scope-2026-01-05', 'per-turn-control-2026-07-01', 'mid-conversation-tool-changes-2026-07-01',
      'effort-2025-11-24', 'extended-cache-ttl-2025-04-11'].join(',');
    const fixture = await runFixture(input, { targetProvider: 'claude-subscription', headersChange: { 'anthropic-beta': beta } });
    assert.deepEqual(fixture.result, { type: 'healthy' });
    assert.deepEqual(fixture.observed.outbound.slice(1).map(value => value.headers['anthropic-beta']), [beta, beta, beta]);
  });
});

test('each gate receives the remaining deadline budget', async () => {
  await contentsFixture(async ({ input }) => {
    const fixture = runtimeFixture();
    const module = { ...fixture.module, async runVMTextChat(...arguments_) {
      await new Promise(resolve => setTimeout(resolve, 20));
      return await fixture.module.runVMTextChat(...arguments_);
    } };
    assert.deepEqual(await runHealthProbe(input, { testOnly: true, runtimeModule: module, timeoutMs: 1000 }), { type: 'healthy' });
    const budgets = fixture.observed.dependencies.map(value => value.timeoutMs);
    assert.equal(budgets.length, 4);
    for (let index = 1; index < budgets.length; index++) assert.ok(budgets[index] < budgets[index - 1] - 10, 'later probes cannot reset the deadline');
  });
});

test('cancellation between gates preserves cleanup and stops remaining model probes', async () => {
  await contentsFixture(async ({ input }) => {
    const controller = new AbortController(), fixture = runtimeFixture();
    const module = { ...fixture.module, async runVMTextChat(...arguments_) {
      const terminal = await fixture.module.runVMTextChat(...arguments_);
      controller.abort(); return terminal;
    } };
    assert.deepEqual(await runHealthProbe(input, { testOnly: true, runtimeModule: module,
      signal: controller.signal, timeoutMs: 1000 }), ERROR);
    assert.equal(fixture.observed.cleanups, 1);
    assert.equal(fixture.observed.runs, 1);
    assert.equal(fixture.observed.children[0].stdin.write, fixture.observed.originalWrites[0]);
  });
});

test('candidate base versions must be valid before any runtime gate starts', async () => {
  await contentsFixture(async ({ input, baseFile }) => {
    const valid = { schema: 'claude-text-vm-base/v1', sdk_version: VERSIONS.sdk, cli_version: VERSIONS.cli };
    for (const bytes of [Buffer.from('PRIVATE_INVALID_JSON'), Buffer.from([0xff, 0xfe]), Buffer.alloc(0),
      Buffer.alloc(65_537, 0x20), ...[[], null, {}, { ...valid, schema: 'other/v1' },
        { ...valid, sdk_version: '0.3.295-beta' }, { ...valid, cli_version: '2.1' },
        { ...valid, sdk_version: true }, { ...valid, cli_version: undefined }].map(value => Buffer.from(JSON.stringify(value)))]) {
      await writeFile(baseFile, bytes);
      const fixture = await runFixture(input);
      assert.deepEqual(fixture.result, ERROR);
      assert.equal(fixture.observed.runs, 0);
    }
    const encoded = JSON.stringify(valid);
    await writeFile(baseFile, encoded + ' '.repeat(65_536 - Buffer.byteLength(encoded)));
    assert.deepEqual((await runFixture(input)).result, { type: 'healthy' });
  });
});

test('missing, directory and multiply linked candidate base files reject before runtime execution', async () => {
  await contentsFixture(async ({ input, baseFile, root }) => {
    await link(baseFile, path.join(root, 'hardlinked-base.json'));
    assert.equal((await runFixture(input)).observed.runs, 0);
    await rm(baseFile);
    const missing = await runFixture(input);
    assert.deepEqual(missing.result, ERROR); assert.equal(missing.observed.runs, 0);
    await mkdir(baseFile);
    const directory = await runFixture(input);
    assert.deepEqual(directory.result, ERROR); assert.equal(directory.observed.runs, 0);
  });
});

test('malformed input is rejected before runtime execution and returns only the fixed error', async () => {
  await contentsFixture(async ({ input }) => {
    for (const invalid of [undefined, null, [], 'PRIVATE_INPUT', {},
      { ...input, schema: 'other/v1' }, { contentsRoot: input.contentsRoot },
      { ...input, apiKey: 'PRIVATE_KEY' }, { ...input, testOnly: true },
      { ...input, contentsRoot: 'Candidate.app/Contents' },
      { ...input, contentsRoot: input.contentsRoot + '/' },
      { ...input, contentsRoot: input.contentsRoot + '/.' },
      { ...input, contentsRoot: path.join(input.contentsRoot, '..', 'Other') },
      { ...input, contentsRoot: input.contentsRoot.replace('/Candidate.app/', '//Candidate.app/') },
      { ...input, contentsRoot: input.contentsRoot + '\u0000PRIVATE_PATH' },
      { ...input, contentsRoot: 42 }]) {
      const fixture = await runFixture(invalid);
      assert.deepEqual(fixture.result, ERROR);
      assert.equal(fixture.observed.runs, 0);
      assert.equal(fixture.observed.launches, 0);
    }
  });
});

test('runtime injection and deadline overrides require explicit test-only admission', async () => {
  await contentsFixture(async ({ input }) => {
    for (const options of [
      { runtimeModule: runtimeFixture().module },
      { testOnly: false, runtimeModule: runtimeFixture().module },
      { testOnly: true, runtimeModule: {} },
      { testOnly: true, runtimeModule: { runVMTextChat() {} } },
      { testOnly: true, runtimeModule: { productionLauncher() {} } },
      { timeoutMs: 20 },
      ...[19, 90_001, 20.5, NaN, Infinity, '20', null].map(timeoutMs =>
        ({ testOnly: true, runtimeModule: runtimeFixture().module, timeoutMs })),
    ]) assert.deepEqual(await runHealthProbe(input, options), ERROR);
  });
});

for (const location of ['ancestor', 'Contents', 'Resources', 'Runtime', 'sdk', 'vm-text-chat.mjs', 'host', 'text-runtime', 'images', 'base.json']) {
  test(`a symlink at ${location} rejects before runtime execution`, async () => {
    await contentsFixture(async ({ root, contentsRoot, sdk, runtimeFile, baseFile, input }) => {
      let candidate = contentsRoot;
      if (location === 'ancestor') {
        const link = path.join(root, 'Linked.app');
        await symlink(path.dirname(contentsRoot), link);
        candidate = path.join(link, 'Contents');
      } else {
        const target = location === 'Contents' ? contentsRoot : location === 'Resources' ?
          path.join(contentsRoot, 'Resources') : location === 'Runtime' ?
            path.join(contentsRoot, 'Resources', 'Runtime') : location === 'sdk' ? sdk : location === 'vm-text-chat.mjs' ? runtimeFile :
              location === 'base.json' ? baseFile : path.join(contentsRoot, 'Resources', 'Runtime', 'host',
                ...(location === 'host' ? [] : location === 'text-runtime' ? ['text-runtime'] : ['text-runtime', 'images']));
        const real = target + '.real';
        // Preserve the complete fixture so only symlink admission changes.
        await rename(target, real);
        await symlink(real, target);
      }
      const fixture = await runFixture({ ...input, contentsRoot: candidate });
      assert.deepEqual(fixture.result, ERROR);
      assert.equal(fixture.observed.runs, 0);
    });
  });
}

test('a missing runtime or a directory in place of its module rejects before execution', async () => {
  await contentsFixture(async ({ input, runtimeFile }) => {
    await rm(runtimeFile);
    const missing = await runFixture(input);
    assert.deepEqual(missing.result, ERROR);
    assert.equal(missing.observed.runs, 0);
    await mkdir(runtimeFile);
    const directory = await runFixture(input);
    assert.deepEqual(directory.result, ERROR);
    assert.equal(directory.observed.runs, 0);
  });
});

test('an already cancelled probe never launches the VM', async () => {
  await contentsFixture(async ({ input }) => {
    const controller = new AbortController();
    controller.abort();
    const fixture = await runFixture(input, {}, { signal: controller.signal });
    assert.deepEqual(fixture.result, ERROR);
    assert.equal(fixture.observed.launches, 0);
  });
});

test('cancellation waits for runtime cleanup before returning its fixed error', async () => {
  await contentsFixture(async ({ input }) => {
    const controller = new AbortController();
    const started = deferred(), abortSeen = deferred(), cleanupAllowed = deferred();
    const fixture = runtimeFixture();
    let cleaned = false, settled = false;
    const module = { productionLauncher: fixture.module.productionLauncher,
      async runVMTextChat(_input, _emit, dependencies) {
        await dependencies.launch();
        dependencies.signal.addEventListener('abort', () => abortSeen.resolve(), { once: true });
        started.resolve();
        await abortSeen.promise;
        await cleanupAllowed.promise;
        cleaned = true;
        return { type: 'error', code: 'PROCESS_INTERRUPTED' };
      } };
    const probe = runHealthProbe(input, { testOnly: true, runtimeModule: module,
      signal: controller.signal, timeoutMs: 1000 }).then(value => { settled = true; return value; });
    await started.promise;
    controller.abort();
    await abortSeen.promise;
    await new Promise(resolve => setImmediate(resolve));
    try {
      assert.equal(settled, false, 'health must not race ahead of VM cleanup');
      assert.equal(cleaned, false);
    } finally { cleanupAllowed.resolve(); }
    assert.deepEqual(await probe, ERROR);
    assert.equal(cleaned, true);
    assert.equal(fixture.observed.launches, 1);
  });
});

test('deadline aborts the runtime and still awaits its cleanup', async () => {
  await contentsFixture(async ({ input }) => {
    const fixture = runtimeFixture();
    let cleaned = false, aborted = false;
    const module = { productionLauncher: fixture.module.productionLauncher,
      async runVMTextChat(_input, _emit, dependencies) {
        await dependencies.launch();
        await new Promise(resolve => {
          dependencies.signal.addEventListener('abort', () => { aborted = true; resolve(); }, { once: true });
        });
        await new Promise(resolve => setTimeout(resolve, 20));
        cleaned = true;
        return { type: 'error', code: 'VM_TIMEOUT' };
      } };
    assert.deepEqual(await runHealthProbe(input, { testOnly: true, runtimeModule: module, timeoutMs: 20 }), ERROR);
    assert.equal(aborted, true);
    assert.equal(cleaned, true);
  });
});

async function runCLI(input, args = []) {
  return await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [SCRIPT, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = [], stderr = [];
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('health CLI did not finish')); }, 5000);
    child.stdout.on('data', chunk => stdout.push(chunk));
    child.stderr.on('data', chunk => stderr.push(chunk));
    child.stdin.on('error', error => { if (error.code !== 'EPIPE') reject(error); });
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ stdout: Buffer.concat(stdout).toString('utf8'), stderr: Buffer.concat(stderr).toString('utf8'), code, signal });
    });
    child.stdin.end(input);
  });
}

test('CLI rejects malformed input, oversized stdin and arguments with one sanitized JSON result', async () => {
  await contentsFixture(async ({ input, root }) => {
    for (const [body, args] of [
      ['', []], ['PRIVATE_NOT_JSON', []], ['{', []], ['null', []], ['[]', []],
      [JSON.stringify({ ...input, private: 'PRIVATE_INPUT_DIAGNOSTIC' }), []],
      [JSON.stringify({ ...input, testOnly: true, runtimeModule: {} }), []],
      [JSON.stringify({ ...input, contentsRoot: path.join(root, 'Missing.app', 'Contents') }), []],
      [JSON.stringify(input), ['--test-only']],
      [JSON.stringify(input), ['PRIVATE_ARGUMENT']],
      [Buffer.alloc(16_385, 0x20), []],
      [Buffer.from([0xff, 0xfe, 0x7b]), []],
    ]) {
      const result = await runCLI(body, args);
      assert.equal(result.stdout, JSON.stringify(ERROR) + '\n');
      assert.equal(result.stderr, '');
      assert.equal(result.signal, null);
      assert.ok([0, 1].includes(result.code));
    }
  });
});

test('stdio consumes the exact byte limit and stops before reading beyond oversized input', async () => {
  const boundary = Buffer.from('null' + ' '.repeat(16_384 - 4));
  let completedRead = false;
  const allowedInput = { destroy() {}, async *[Symbol.asyncIterator]() {
    yield boundary.subarray(0, 8192);
    yield boundary.subarray(8192);
    completedRead = true;
  } };
  const allowedReceipts = [];
  assert.deepEqual(await runHealthStdio({ input: allowedInput, emit: receipt => allowedReceipts.push(receipt) }), ERROR);
  assert.equal(completedRead, true, 'exactly 16384 bytes must finish reading before schema rejection');
  assert.deepEqual(allowedReceipts, [ERROR]);
  let extraRead = false, iteratorClosed = false;
  const oversizedInput = { destroy() {}, async *[Symbol.asyncIterator]() {
    try {
      yield boundary;
      yield Buffer.from(' ');
      extraRead = true;
      yield Buffer.from('PRIVATE_TRAILING_DATA');
    } finally { iteratorClosed = true; }
  } };
  const oversizedReceipts = [];
  assert.deepEqual(await runHealthStdio({ input: oversizedInput, emit: receipt => oversizedReceipts.push(receipt) }), ERROR);
  assert.equal(extraRead, false);
  assert.equal(iteratorClosed, true);
  assert.deepEqual(oversizedReceipts, [ERROR]);
});

test('stdio malformed JSON, non-byte chunks and invalid UTF-8 return one fixed receipt', async () => {
  for (const bytes of [Buffer.from('PRIVATE_NOT_JSON'), Buffer.from([0xff, 0xfe]), 'null']) {
    const receipts = [];
    assert.deepEqual(await runHealthStdio({ input: Readable.from([bytes]), emit: receipt => receipts.push(receipt) }), ERROR);
    assert.deepEqual(receipts, [ERROR]);
  }
});

test('stdio cancellation while awaiting input destroys its stream and emits once', async () => {
  const controller = new AbortController();
  const input = new PassThrough();
  const receipts = [];
  const probe = runHealthStdio({ input, signal: controller.signal, emit: receipt => receipts.push(receipt) });
  controller.abort();
  assert.deepEqual(await probe, ERROR);
  assert.equal(input.destroyed, true);
  assert.deepEqual(receipts, [ERROR]);
});
