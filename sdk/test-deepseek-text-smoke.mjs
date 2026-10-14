// Fake-only tests: SDK query/spawn and HTTPS transport are injected. The local
// HTTP frontend is real; no native CLI, sandbox-exec, Keychain, or provider runs.
import assert from 'node:assert/strict';
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { access, readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { runDeepSeekTextSmoke, inspectInstalledNativeMetadata, SMOKE_SCHEMA, SMOKE_ACK, SMOKE_PROMPT } from './deepseek-text-smoke.mjs';

const FAKE_KEY = 'FAKE-only-DeepSeek-provider-key-NOT-VALID';
const SHA = 'f'.repeat(64);
const INPUT = { schema: SMOKE_SCHEMA, apiKey: FAKE_KEY, model: 'deepseek-flash[1m]' };
const NETWORK = { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:7890', dnsPolicy: 'proxy-only' };
const RUNTIME = { schema: 'app-runtime-profile/v1', timeZone: 'Asia/Tokyo', language: 'ja' };
let checks = 0;
async function check(name, test) { await test(); checks++; process.stdout.write(`PASS ${name}\n`); }

function messageResponse({ ack = SMOKE_ACK, tool = false, status = 200, stream = false } = {}) {
  const usage = { input_tokens: 11, output_tokens: 7 };
  const content = tool ? [{ type: 'tool_use', id: 'fake-tool', name: 'Bash', input: { command: 'must-never-run' } }] : [{ type: 'text', text: ack }];
  if (!stream) return { statusCode: status, contentType: 'application/json',
    body: Buffer.from(JSON.stringify({ type: 'message', content, usage })) };
  const frames = [
    ['message_start', { type: 'message_start', message: { type: 'message', content: [], usage: { ...usage, output_tokens: 0 } } }],
    ['content_block_start', { type: 'content_block_start', content_block: tool ? content[0] : { type: 'text', text: '' }, index: 0 }],
    ['content_block_delta', { type: 'content_block_delta', delta: { type: 'text_delta', text: ack }, index: 0 }],
    ['message_delta', { type: 'message_delta', usage: { output_tokens: 7 } }],
    ['message_stop', { type: 'message_stop' }],
  ];
  return { statusCode: status, contentType: 'text/event-stream',
    body: Buffer.from(frames.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('')) };
}

async function localRequest(baseURL, { token, route = '/v1/messages?beta=true', body, method = 'POST' }) {
  const payload = Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  return await new Promise((resolve, reject) => {
    const request = http.request(new URL(route, baseURL), { method,
      headers: { 'x-api-key': token, 'content-type': 'application/json', 'content-length': payload.length } }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.once('error', reject);
      response.once('end', () => resolve({ status: response.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
    });
    request.once('error', reject);
    request.end(payload);
  });
}

function fixture({ requests = 1, requestChange, providerChange, initChange, resultChange,
  toolEvent = false, missingSpawn = false, exitCode = 0, transportError = false, stream = true,
  queryError = false, iterationError = false, diagnostic = null } = {}) {
  const observed = { launches: [], upstream: [], configuration: null, cwd: null, local: [] };
  let fakeChild;
  let closed = false;
  const dependencies = {
    testOnly: true, cliPath: '/fake/official-native-cli', cliSha256: SHA,
    spawn(command, args, options) {
      observed.launches.push({ command, args, options });
      observed.profile = readFileSync(args[1], 'utf8');
      fakeChild = new EventEmitter();
      fakeChild.stdin = new PassThrough(); fakeChild.stdout = new PassThrough(); fakeChild.stderr = new PassThrough();
      return fakeChild;
    },
    async transport(parameters) {
      observed.upstream.push(parameters);
      if (transportError) throw new Error(`fake diagnostic must redact ${FAKE_KEY}`);
      return providerChange ? providerChange(parameters) : messageResponse({ stream: parameters.body.stream });
    },
    query({ prompt, options }) {
      if (queryError) throw new Error(`fake query exception: ${FAKE_KEY}`);
      observed.configuration = { prompt, options };
      observed.cwd = options.cwd;
      if (!missingSpawn) options.spawnClaudeCodeProcess({ command: dependencies.cliPath, cwd: options.cwd,
        args: ['--setting-sources=', '--tools', ''], env: options.env, signal: options.abortController.signal });
      async function* events() {
        if (diagnostic) fakeChild.stderr.write(diagnostic);
        if (iterationError) throw new Error(`fake iteration exception: ${FAKE_KEY}`);
        const init = { type: 'system', subtype: 'init', claude_code_version: '2.1.295', cwd: options.cwd,
          permissionMode: 'default', tools: [], mcp_servers: [], skills: [], plugins: [] };
        yield initChange ? initChange(init) : init;
        for (let index = 0; index < requests; index++) {
          const request = { token: options.env.ANTHROPIC_API_KEY,
            body: { model: options.model.replace('[1m]', ''), stream, max_tokens: 32768,
              system: `discard-runtime-path:${options.cwd}`, messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] }], tools: [] } };
          observed.local.push(await localRequest(options.env.ANTHROPIC_BASE_URL,
            requestChange ? requestChange(request, index) : request));
        }
        if (toolEvent) yield { type: 'assistant', message: { content: [{ type: 'tool_use', name: 'Bash' }] } };
        const result = { type: 'result', subtype: 'success', is_error: false, result: SMOKE_ACK, num_turns: 1 };
        yield resultChange ? resultChange(result) : result;
      }
      const iterator = events();
      iterator.close = () => {
        if (closed) return;
        closed = true;
        if (fakeChild) queueMicrotask(() => fakeChild.emit('exit', exitCode, null));
      };
      return iterator;
    },
  };
  return { dependencies, observed };
}

async function run(options, input = INPUT) {
  const value = fixture(options);
  const reply = await runDeepSeekTextSmoke(input, value.dependencies);
  assert.equal(JSON.stringify(reply).includes(FAKE_KEY), false, 'output must not echo a provider credential');
  assert.deepEqual(reply.cleanup, { temporary_removed: true, proxy_closed: true });
  if (value.observed.cwd) await assert.rejects(access(value.observed.cwd), { code: 'ENOENT' });
  return { ...value, reply };
}
await check('explicit network policy is forwarded and malformed policy rejects before native initialization', async () => {
  const accepted = await run(undefined, { ...INPUT, network: NETWORK });
  assert.equal(accepted.reply.ok, true);
  assert.deepEqual(accepted.observed.upstream[0].network, NETWORK);
  const rejected = await run(undefined, { ...INPUT, network: { ...NETWORK, dnsPolicy: 'direct' } });
  assert.equal(rejected.reply.code, 'NETWORK_POLICY_INVALID');
  assert.deepEqual(rejected.observed.launches, []);
  assert.deepEqual(rejected.observed.upstream, []);
});
await check('production smoke rejects missing network before importing SDK or starting native CLI', async () => {
  const reply = await runDeepSeekTextSmoke(INPUT);
  assert.equal(reply.ok, false);
  assert.equal(reply.code, 'NETWORK_POLICY_REQUIRED');
  assert.equal(reply.request_count, 0);
  assert.equal(reply.ack, null);
});
await check('Japan fixture default reaches both SDK query and actual native spawn environment', async () => {
  const { observed, reply } = await run();
  assert.equal(reply.ok, true);
  const env = observed.configuration.options.env;
  assert.equal(env.TZ, 'Asia/Tokyo');
  for (const key of ['LANG', 'LC_ALL', 'LC_MESSAGES']) assert.equal(env[key], 'ja_JP.UTF-8');
  assert.equal(observed.launches[0].options.env, env);
  assert.equal(Object.values(env).includes(FAKE_KEY), false);
});
await check('configured language and time zone reach native launch without entering provider payload', async () => {
  for (const [timeZone, language, locale] of [['Asia/Tokyo', 'ja', 'ja_JP.UTF-8'],
    ['America/New_York', 'en', 'en_US.UTF-8'], ['UTC', 'zh', 'zh_CN.UTF-8']]) {
    const { observed, reply } = await run(undefined, { ...INPUT, runtime: { ...RUNTIME, timeZone, language } });
    assert.equal(reply.ok, true);
    const env = observed.configuration.options.env;
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
    { ...RUNTIME, apiKey: FAKE_KEY }, { schema: RUNTIME.schema, timeZone: RUNTIME.timeZone }, []]) {
    const { observed, reply } = await run(undefined, { ...INPUT, runtime });
    assert.equal(reply.code, 'RUNTIME_PROFILE_INVALID');
    assert.equal(observed.configuration, null);
    assert.deepEqual(observed.launches, []);
    assert.deepEqual(observed.upstream, []);
  }
  assert.equal((await run(undefined, { ...INPUT, runtime: null })).reply.code, 'RUNTIME_PROFILE_REQUIRED');
});
await check('production smoke requires profile after valid network before initializing native runtime', async () => {
  const reply = await runDeepSeekTextSmoke({ ...INPUT, network: NETWORK });
  assert.equal(reply.ok, false);
  assert.equal(reply.code, 'RUNTIME_PROFILE_REQUIRED');
  assert.equal(reply.request_count, 0);
  assert.equal(reply.ack, null);
});

await check('success uses bounded SSE transport and removes temporary workspace', async () => {
  const { reply } = await run();
  assert.equal(reply.ok, true); assert.equal(reply.code, 'PASSED_TEXT_ONLY');
  assert.equal(reply.no_tools, true); assert.equal(reply.ack, SMOKE_ACK);
  assert.equal(reply.request_count, 1); assert.deepEqual(reply.usage, { input_tokens: 11, output_tokens: 7 });
  assert.deepEqual(reply.cli, { sha256: SHA, exit_code: 0, signal: null });
});
await check('official CLI spawn contract, settings and feature filters are explicit', async () => {
  const { observed } = await run();
  const { prompt, options } = observed.configuration;
  assert.equal(prompt, SMOKE_PROMPT);
  for (const property of ['tools', 'allowedTools', 'plugins', 'skills', 'settingSources']) assert.deepEqual(options[property], []);
  assert.deepEqual(options.mcpServers, {}); assert.deepEqual(options.agents, {});
  assert.equal(options.strictMcpConfig, true); assert.equal(options.persistSession, false);
  assert.equal(options.maxTurns, 1); assert.equal(options.verbatimPrompts, true);
  assert.equal(options.permissionPrompts, 'none'); assert.equal(options.allowDangerouslySkipPermissions, false);
  assert.deepEqual(options.thinking, { type: 'disabled' }); assert.equal(options.settings.disableAllHooks, true);
  assert.deepEqual(options.extraArgs, { 'disable-slash-commands': null });
  assert.deepEqual(options.settings.enabledPlugins, {
    'cc-plugin-agents-md@builtin': false, 'cc-plugin-plugin-authoring@builtin': false,
  });
  const launch = observed.launches[0];
  assert.equal(launch.command, '/usr/bin/sandbox-exec');
  assert.equal(launch.args[2], '/fake/official-native-cli');
  assert.equal(launch.options.detached, true);
});
await check('provider key stays host-only and environment does not inherit proxy or auth variables', async () => {
  const { observed } = await run();
  const env = observed.launches[0].options.env;
  assert.equal(Object.values(env).includes(FAKE_KEY), false);
  assert.match(env.ANTHROPIC_API_KEY, /^[a-f0-9]{64}$/);
  assert.equal(env.HTTPS_PROXY, undefined); assert.equal(env.ANTHROPIC_AUTH_TOKEN, undefined);
  assert.equal(env.HOME.startsWith('/Users/'), false);
  assert.equal(observed.upstream[0].apiKey, FAKE_KEY);
});
await check('Seatbelt allow paths use physical temporary and runtime paths', async () => {
  const { observed } = await run();
  const temporary = observed.cwd.replace(/\/empty-workspace$/, '');
  assert.equal(observed.profile.includes(`(subpath ${JSON.stringify(temporary)})`), true);
  assert.equal(observed.profile.includes('"/tmp/claude-deepseek-text-'), false);
  assert.equal(observed.profile.includes('"/var/folders/'), false);
  assert.equal(observed.profile.includes('(subpath "/Library/Application Support/ClaudeCode")'), false);
});
await check('provider payload is rebuilt from fixed strings and max_tokens is capped', async () => {
  const { observed } = await run();
  const body = observed.upstream[0].body;
  assert.equal(body.model, 'deepseek-flash'); assert.equal(body.max_tokens, 128);
  assert.deepEqual(body.messages, [{ role: 'user', content: SMOKE_PROMPT }]); assert.deepEqual(body.tools, []);
  assert.equal(JSON.stringify(body).includes(observed.cwd), false);
});
await check('lightweight allowed selector and JSON response work', async () => {
  const { reply } = await run({ stream: false }, { ...INPUT, model: 'deepseek-flash' });
  assert.equal(reply.ok, true); assert.equal(reply.model, 'deepseek-flash');
});
await check('unknown fields, model and missing key fail before runtime activity', async () => {
  for (const [input, code] of [[{ ...INPUT, endpoint: 'https://example.invalid' }, 'INVALID_INPUT'],
    [{ ...INPUT, model: 'claude-sonnet-4-6' }, 'MODEL_NOT_ALLOWED'], [{ ...INPUT, apiKey: '' }, 'INVALID_API_KEY']]) {
    const { reply, observed } = await run(undefined, input);
    assert.equal(reply.code, code); assert.equal(observed.upstream.length, 0); assert.equal(observed.launches.length, 0);
  }
});
await check('non-fixed user input and tools never reach the upstream', async () => {
  for (const change of [request => ({ ...request, body: { ...request.body, messages: [{ role: 'user', content: 'private project data' }] } }),
    request => ({ ...request, body: { ...request.body, tools: [{ name: 'Bash' }] } })]) {
    const { reply, observed } = await run({ requestChange: change });
    assert.equal(reply.code, 'NON_FIXED_REQUEST'); assert.equal(observed.upstream.length, 0);
  }
});
await check('one bounded native system envelope is discarded without forwarding its context', async () => {
  const { reply, observed } = await run({ requestChange: request => ({ ...request, body: {
    ...request.body, messages: [...request.body.messages,
      { role: 'system', content: [{ type: 'text', text: `Native runtime envelope: ${FAKE_KEY} /private/fake-runtime-path` }] }],
  } }) });
  assert.equal(reply.ok, true); assert.equal(reply.system_envelope_discarded, true);
  assert.equal(reply.request_diagnostic, null);
  assert.equal(observed.upstream.length, 1);
  assert.deepEqual(observed.upstream[0].body.messages, [{ role: 'user', content: SMOKE_PROMPT }]);
  assert.equal(JSON.stringify(observed.upstream[0].body).includes(FAKE_KEY), false);
  assert.equal(JSON.stringify(observed.upstream[0].body).includes('/private/fake-runtime-path'), false);
});
await check('extra user or assistant history, tool blocks and unknown system schemas remain forbidden', async () => {
  const extras = [
    { role: 'user', content: [{ type: 'text', text: 'extra user' }] },
    { role: 'assistant', content: [{ type: 'text', text: 'previous reply' }] },
    { role: 'system', content: [{ type: 'tool_result', text: 'not a text envelope' }] },
    { role: 'system', content: [{ type: 'text', text: 'x'.repeat(2049) }] },
    { role: 'system', content: [{ type: 'text', text: 'first' }, { type: 'text', text: 'second' }] },
    { role: 'system', content: [{ type: 'text', text: 'context', unexpected: true }] },
    { role: 'system', content: [{ type: 'text', text: 'context' }], unexpected: true },
  ];
  for (const extra of extras) {
    const { reply, observed } = await run({ requestChange: request => ({ ...request, body: {
      ...request.body, messages: [...request.body.messages, extra],
    } }) });
    assert.equal(reply.code, 'NON_FIXED_REQUEST'); assert.equal(reply.system_envelope_discarded, false);
    assert.equal(observed.upstream.length, 0); assert.equal(reply.request_diagnostic.request_index, 1);
  }
  const thirdMessage = await run({ requestChange: request => ({ ...request, body: { ...request.body,
    messages: [...request.body.messages, { role: 'system', content: [{ type: 'text', text: 'one' }] },
      { role: 'system', content: [{ type: 'text', text: 'two' }] }],
  } }) });
  assert.equal(thirdMessage.reply.code, 'NON_FIXED_REQUEST');
});
await check('only the first rejected request shape is retained and contains no arbitrary content or keys', async () => {
  const { reply } = await run({ requests: 2, requestChange: (request, index) => ({ ...request, body: {
    ...request.body, [FAKE_KEY]: true,
    messages: [{ role: 'user', content: [{ type: 'text', text: index === 0 ? `${FAKE_KEY} /private/fake-secret-path` : 'later unrelated retry' }] }],
  } }) });
  assert.equal(reply.request_diagnostic.request_index, 1);
  assert.equal(reply.request_diagnostic.other_key_count, 1);
  assert.equal(reply.request_diagnostic.messages[0].blocks[0].text_length, `${FAKE_KEY} /private/fake-secret-path`.length);
  assert.equal(JSON.stringify(reply).includes(FAKE_KEY), false);
  assert.equal(JSON.stringify(reply).includes('/private/fake-secret-path'), false);
});
await check('count_tokens and arbitrary local routes are rejected', async () => {
  for (const route of ['/v1/messages/count_tokens', '/v1/messages?secret=anything', '/other']) {
    const { reply, observed } = await run({ requestChange: request => ({ ...request, route }) });
    assert.equal(reply.code, 'LOCAL_ROUTE_REJECTED'); assert.equal(observed.upstream.length, 0);
  }
});
await check('wrong local token is rejected before provider access', async () => {
  const { reply, observed } = await run({ requestChange: request => ({ ...request, token: 'not-the-session-token' }) });
  assert.equal(reply.code, 'LOCAL_AUTH_REJECTED'); assert.equal(observed.upstream.length, 0);
});
await check('request budget is three fixed provider calls', async () => {
  const { reply, observed } = await run({ requests: 4 });
  assert.equal(reply.code, 'REQUEST_LIMIT'); assert.equal(observed.upstream.length, 3); assert.equal(reply.ok, false);
});
await check('request body bound is enforced without provider contact', async () => {
  const { reply, observed } = await run({ requestChange: request => ({ ...request, body: 'x'.repeat(1_048_577) }) });
  assert.equal(reply.code, 'REQUEST_BODY_LIMIT'); assert.equal(observed.upstream.length, 0);
});
await check('redirects and provider error bodies are not forwarded or displayed', async () => {
  for (const [status, code] of [[302, 'PROVIDER_REDIRECT_REJECTED'], [401, 'PROVIDER_HTTP_401']]) {
    const { reply } = await run({ providerChange: () => ({ statusCode: status, contentType: 'application/json', body: Buffer.from(FAKE_KEY) }) });
    assert.equal(reply.code, code); assert.equal(reply.ack, null);
  }
});
await check('provider text mismatch and tool-use response fail closed', async () => {
  for (const [parameters, code] of [[{ ack: 'unexpected' }, 'PROVIDER_ACK_MISMATCH'], [{ tool: true }, 'PROVIDER_TOOL_RESPONSE']]) {
    const { reply } = await run({ providerChange: () => messageResponse(parameters) });
    assert.equal(reply.code, code); assert.equal(reply.ok, false);
  }
});
await check('provider response size and usage bounds are enforced', async () => {
  const oversized = await run({ providerChange: () => ({ statusCode: 200, contentType: 'application/json', body: Buffer.alloc(262_145) }) });
  assert.equal(oversized.reply.code, 'INVALID_PROVIDER_RESPONSE');
  const excessTokens = await run({ providerChange: () => ({ statusCode: 200, contentType: 'application/json',
    body: Buffer.from(JSON.stringify({ content: [{ type: 'text', text: SMOKE_ACK }], usage: { input_tokens: 1, output_tokens: 129 } })) }) });
  assert.equal(excessTokens.reply.code, 'PROVIDER_OUTPUT_LIMIT');
});
await check('init feature leakage and unexpected SDK tool messages fail no-tools contract', async () => {
  for (const options of [{ initChange: init => ({ ...init, tools: ['Bash'] }) },
    { initChange: init => ({ ...init, plugins: [{ name: 'cc-plugin-agents-md', path: 'builtin', source: 'cc-plugin-agents-md@builtin' }] }) },
    { initChange: init => ({ ...init, skills: ['managed-skill'] }) },
    { initChange: init => ({ ...init, permissionMode: 'acceptEdits' }) }, { toolEvent: true }]) {
    const { reply } = await run(options); assert.equal(reply.code, 'NO_TOOLS_CONTRACT'); assert.equal(reply.no_tools, false);
  }
});
await check('missing native spawn, result error and child failure cannot report success', async () => {
  for (const [options, code] of [[{ missingSpawn: true }, 'CLI_NOT_STARTED'],
    [{ resultChange: result => ({ ...result, is_error: true }) }, 'CLI_ACK_MISMATCH'], [{ exitCode: 1 }, 'CLI_EXIT_FAILED']]) {
    const { reply } = await run(options); assert.equal(reply.ok, false); assert.equal(reply.code, code); assert.equal(reply.ack, null);
  }
});
await check('arbitrary transport exceptions do not expose diagnostic text or credentials', async () => {
  const { reply } = await run({ transportError: true });
  assert.equal(reply.code, 'PROVIDER_CONNECTION_FAILED'); assert.equal(JSON.stringify(reply).includes('fake diagnostic'), false);
});
await check('SDK start and iteration failures have safe, distinct stage codes', async () => {
  const started = await run({ queryError: true });
  assert.equal(started.reply.code, 'SDK_QUERY_START_FAILED');
  const iterated = await run({ iterationError: true, exitCode: 1 });
  assert.equal(iterated.reply.code, 'CLI_INITIALIZATION_FAILED');
  assert.equal(iterated.reply.request_count, 0);
});
await check('native child diagnostics are classified without echoing arbitrary text', async () => {
  for (const [text, code] of [[`EACCES: permission denied ${FAKE_KEY}`, 'CLI_PERMISSION_DENIED'],
    [`sandbox-exec: syntax error ${FAKE_KEY}`, 'SANDBOX_PROFILE_REJECTED'],
    [`unknown option ${FAKE_KEY}`, 'CLI_ARGUMENT_REJECTED'],
    [`not allowed by managed policy ${FAKE_KEY}`, 'CLI_MANAGED_POLICY_REJECTED'],
    [`unrecognized private diagnostic ${FAKE_KEY}`, 'CLI_INITIALIZATION_FAILED']]) {
    const { reply } = await run({ iterationError: true, exitCode: 1, diagnostic: text });
    assert.equal(reply.code, code); assert.equal(JSON.stringify(reply).includes(text), false);
  }
});
await check('native package metadata uses fixed identity, version and executable access', async () => {
  const observed = [];
  const dependencies = { testOnly: true, platform: 'darwin', arch: 'arm64',
    async access(file, mode) { observed.push([file, mode]); },
    async readFile(file) {
      if (file.endsWith('/claude')) return Buffer.from('fake-native-binary');
      return JSON.stringify({ name: file.includes('darwin-arm64') ? '@anthropic-ai/claude-agent-sdk-darwin-arm64' : '@anthropic-ai/claude-agent-sdk', version: '0.3.295' });
    } };
  const metadata = await inspectInstalledNativeMetadata(dependencies);
  assert.equal(metadata.sdkVersion, '0.3.295'); assert.equal(metadata.expectedCliVersion, '2.1.295');
  assert.match(metadata.cliSha256, /^[a-f0-9]{64}$/);
  assert.equal(observed[0][0], '/usr/bin/sandbox-exec');
  assert.match(observed[1][0], /node_modules\/@anthropic-ai\/claude-agent-sdk-darwin-arm64\/claude$/);
  await assert.rejects(inspectInstalledNativeMetadata({ ...dependencies, arch: 'x64' }), { code: 'MAC_ARM64_REQUIRED' });
  await assert.rejects(inspectInstalledNativeMetadata({ ...dependencies, access: async () => { throw new Error(FAKE_KEY); } }), { code: 'SANDBOX_UNAVAILABLE' });
  await assert.rejects(inspectInstalledNativeMetadata({ ...dependencies, readFile: async () => '{bad-json' }), { code: 'CLI_PACKAGE_METADATA_FAILED' });
  await assert.rejects(inspectInstalledNativeMetadata({ ...dependencies, readFile: async () => JSON.stringify({ name: 'untrusted', version: '0.3.295' }) }), { code: 'CLI_PACKAGE_IDENTITY_MISMATCH' });
  await assert.rejects(inspectInstalledNativeMetadata({ ...dependencies, readFile: async file => JSON.stringify({ name: file.includes('darwin-arm64') ? '@anthropic-ai/claude-agent-sdk-darwin-arm64' : '@anthropic-ai/claude-agent-sdk', version: '0.3.999' }) }), { code: 'SDK_VERSION_MISMATCH' });
  await assert.rejects(inspectInstalledNativeMetadata({ ...dependencies, access: async file => { if (file.endsWith('/claude')) throw new Error(FAKE_KEY); } }), { code: 'CLI_BINARY_UNAVAILABLE' });
});
await check('standalone source contains no fixture or endpoint argument switches', async () => {
  const source = await readFile(new URL('./deepseek-text-smoke.mjs', import.meta.url), 'utf8');
  assert.equal(source.includes("const UPSTREAM_URL = 'https://api.deepseek.com/anthropic/v1/messages'"), true);
  assert.equal(source.includes('process.env.'), false);
  assert.equal(source.includes("process.once('SIGTERM', interrupt)"), true);
});

process.stdout.write(`${JSON.stringify({ schema: 'deepseek-text-smoke-fake-tests/v1', passed: checks,
  provider_calls: false, native_cli_executed: false, sandbox_executed: false, keychain_access: false })}\n`);
