// Fake SDK/process/provider checks. The loopback gateway is real; OAuth tokens
// are inert and no native CLI, Keychain or remote provider is used here.
import assert from 'node:assert/strict';
import { access } from 'node:fs/promises';
import { runDeepSeekTextChat } from './deepseek-text-chat.mjs';
import { FAKE_SUBSCRIPTION_TOKEN, SUBSCRIPTION_ACK, SUBSCRIPTION_INPUT, SUBSCRIPTION_SESSION_ID, subscriptionFixture } from './subscription-test-fixtures.mjs';

let checks = 0;
async function check(name, fn) { await fn(); checks++; console.log(`PASS ${name}`); }
async function run(options, input = SUBSCRIPTION_INPUT) {
  const fixture = subscriptionFixture(options), events = [];
  const terminal = await runDeepSeekTextChat(input, event => events.push(structuredClone(event)), fixture.dependencies);
  assert.equal(JSON.stringify({ terminal, events }).includes(FAKE_SUBSCRIPTION_TOKEN), false);
  assert.deepEqual(events.at(-1), terminal);
  if (fixture.observed.cwd) await assert.rejects(access(fixture.observed.cwd), { code: 'ENOENT' });
  return { ...fixture, terminal, events };
}

await check('subscription OAuth is the only native credential and API billing credentials are absent', async () => {
  const { observed, terminal } = await run();
  assert.equal(terminal.type, 'completed'); assert.equal(terminal.text, SUBSCRIPTION_ACK); assert.equal(terminal.model, 'sonnet');
  const env = observed.query.options.env;
  assert.equal(env.CLAUDE_CODE_OAUTH_TOKEN, FAKE_SUBSCRIPTION_TOKEN);
  for (const key of ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX',
    'CLAUDE_CODE_USE_FOUNDRY', 'HTTPS_PROXY']) assert.equal(env[key], undefined);
  assert.equal(observed.upstream[0].provider, 'claude-subscription');
  assert.equal(observed.upstream[0].subscriptionToken, FAKE_SUBSCRIPTION_TOKEN);
  assert.equal('apiKey' in observed.upstream[0], false);
});
await check('App history and text Skills survive while native runtime environment is discarded', async () => {
  const { observed, terminal } = await run(); assert.equal(terminal.type, 'completed');
  const body = observed.upstream[0].body;
  assert.deepEqual(body.messages, SUBSCRIPTION_INPUT.messages.map(({ role, text }) => ({ role, content: text })));
  assert.equal(body.model, 'claude-sonnet-5-5'); assert.equal(body.max_tokens, 4096); assert.deepEqual(body.tools, []);
  assert.match(body.system[0].text, /^x-anthropic-billing-header:/);
  assert.equal(body.system[1].text, "You are a Claude agent, built on Anthropic's Claude Agent SDK.");
  assert.ok(body.system[2].text.includes('Text fixture')); assert.ok(body.system[2].text.includes('Answer the latest user question.'));
  assert.equal(JSON.stringify(body).includes('/private/temporary-native-workspace'), false);
  assert.equal(JSON.stringify(body).includes(observed.cwd), false);
});
await check('only native OAuth protocol headers and bounded temporary attribution survive', async () => {
  const { observed, terminal } = await run(); assert.equal(terminal.type, 'completed');
  assert.deepEqual(Object.keys(observed.upstream[0].headers).sort(), ['anthropic-beta', 'anthropic-dangerous-direct-browser-access',
    'anthropic-version', 'user-agent', 'x-app', 'x-claude-code-session-id'].sort());
  assert.match(observed.upstream[0].headers['anthropic-beta'], /oauth-2025-04-20/);
  assert.equal(observed.upstream[0].headers.authorization, undefined);
  assert.equal(observed.upstream[0].headers['x-api-key'], undefined);
  const metadata = JSON.parse(observed.upstream[0].body.metadata.user_id);
  assert.match(metadata.device_id, /^[a-f0-9]{64}$/); assert.equal(metadata.account_uuid, '');
  assert.equal(metadata.session_id, observed.upstream[0].headers['x-claude-code-session-id']);
});
await check('pinned OAuth model capability betas survive while arbitrary or malformed tags fail closed', async () => {
  const nativeBetaTags = ['claude-code-20250219', 'oauth-2025-04-20', 'mid-conversation-system-2026-04-07',
    'interleaved-thinking-2025-05-14', 'thinking-token-count-2026-05-13', 'context-management-2025-06-27',
    'prompt-caching-scope-2026-01-05', 'per-turn-control-2026-07-01', 'mid-conversation-tool-changes-2026-07-01',
    'effort-2025-11-24', 'extended-cache-ttl-2025-04-11'];
  for (const model of ['sonnet', 'opus', 'haiku']) {
    const beta = nativeBetaTags.slice().reverse().join(',');
    const { observed, terminal } = await run({ requestChange: request => ({ ...request,
      headers: { ...request.headers, 'anthropic-beta': beta } }) }, { ...SUBSCRIPTION_INPUT, model });
    assert.equal(terminal.type, 'completed');
    assert.equal(observed.upstream[0].headers['anthropic-beta'], beta);
  }
  const required = 'claude-code-20250219,oauth-2025-04-20';
  for (const beta of [`${required},synthetic-private-host-context`, `${required},inline-tools-2026-09-15`,
    `${required},oauth-2025-04-20`, `${required},`, `${required},,mid-conversation-system-2026-04-07`,
    'oauth-2025-04-20,mid-conversation-system-2026-04-07']) {
    const { observed, terminal } = await run({ requestChange: request => ({ ...request,
      headers: { ...request.headers, 'anthropic-beta': beta } }) });
    assert.equal(terminal.code, 'SUBSCRIPTION_PROTOCOL_REJECTED');
    assert.equal(observed.upstream.length, 0);
  }
});
await check('duplicate attribution keys cannot forward discarded private plaintext', async () => {
  const canonical = { device_id: 'b'.repeat(64), account_uuid: '', session_id: SUBSCRIPTION_SESSION_ID };
  for (const key of Object.keys(canonical)) {
    const privateMarker = `synthetic-private-${key}`;
    const original = `{${JSON.stringify(key)}:${JSON.stringify(privateMarker)},${JSON.stringify(canonical).slice(1)}`;
    const { observed, terminal } = await run({ requestChange: request => ({ ...request,
      body: { ...request.body, metadata: { user_id: original } } }) });
    assert.equal(terminal.type, 'completed');
    assert.equal(observed.upstream[0].body.metadata.user_id, JSON.stringify(canonical));
    assert.equal(JSON.stringify(observed.upstream).includes(privateMarker), false);
    const rejected = await run({ requestChange: request => ({ ...request,
      body: { ...request.body, metadata: { user_id: `${JSON.stringify(canonical).slice(0, -1)},${JSON.stringify(key)}:${JSON.stringify(privateMarker)}}` } } }) });
    assert.equal(rejected.terminal.code, 'SUBSCRIPTION_PROTOCOL_REJECTED');
    assert.equal(rejected.observed.upstream.length, 0);
  }
});
await check('harmless attribution ordering and whitespace serialize to the same validated fields', async () => {
  const canonical = { device_id: 'b'.repeat(64), account_uuid: '', session_id: SUBSCRIPTION_SESSION_ID };
  const original = JSON.stringify({ session_id: canonical.session_id,
    account_uuid: canonical.account_uuid, device_id: canonical.device_id }, null, 2);
  const { observed, terminal } = await run({ requestChange: request => ({ ...request,
    body: { ...request.body, metadata: { user_id: original } } }) });
  assert.equal(terminal.type, 'completed');
  assert.equal(observed.upstream[0].body.metadata.user_id, JSON.stringify(canonical));
});
await check('every configured subscription alias binds the matching native resolved model', async () => {
  for (const model of ['sonnet', 'opus', 'haiku']) {
    const { observed, terminal } = await run(undefined, { ...SUBSCRIPTION_INPUT, model });
    assert.equal(terminal.type, 'completed'); assert.equal(terminal.model, model);
    assert.equal(observed.upstream[0].body.model, `claude-${model}-5-5`);
  }
  for (const model of ['deepseek-flash', 'sonnet', 'claude-opus-5-5', 'claude-sonnet-untrusted']) {
    const { observed, terminal } = await run({ initChange: init => ({ ...init, model }) });
    assert.equal(terminal.code, 'NO_TOOLS_CONTRACT'); assert.equal(observed.upstream.length, 0);
  }
});
await check('unsupported providers, cross-mode keys, malformed Tokens and models fail before native launch', async () => {
  for (const [input, code] of [[{ ...SUBSCRIPTION_INPUT, provider: 'unknown' }, 'PROVIDER_NOT_ALLOWED'],
    [{ ...SUBSCRIPTION_INPUT, provider: null }, 'PROVIDER_NOT_ALLOWED'],
    [{ ...SUBSCRIPTION_INPUT, apiKey: 'FAKE-unused-api-key' }, 'CREDENTIAL_MODE_MISMATCH'],
    [{ ...SUBSCRIPTION_INPUT, subscriptionToken: 'sk-ant-api-key' }, 'INVALID_SUBSCRIPTION_TOKEN'],
    [{ ...SUBSCRIPTION_INPUT, subscriptionToken: `${FAKE_SUBSCRIPTION_TOKEN}\n` }, 'INVALID_SUBSCRIPTION_TOKEN'],
    [{ ...SUBSCRIPTION_INPUT, subscriptionToken: undefined }, 'INVALID_SUBSCRIPTION_TOKEN'],
    [{ ...SUBSCRIPTION_INPUT, model: 'deepseek-flash' }, 'MODEL_NOT_ALLOWED'],
    [{ ...SUBSCRIPTION_INPUT, provider: 'deepseek-api' }, 'CREDENTIAL_MODE_MISMATCH']]) {
    const { observed, terminal } = await run(undefined, input); assert.equal(terminal.code, code);
    assert.equal(observed.launches.length, 0); assert.equal(observed.upstream.length, 0);
  }
});
await check('local subscription gateway rejects API-key auth, wrong Bearer and altered native model', async () => {
  for (const [change, code] of [[request => ({ ...request, headers: { ...request.headers, 'x-api-key': 'FAKE' } }), 'LOCAL_AUTH_REJECTED'],
    [request => ({ ...request, headers: { ...request.headers, authorization: 'Bearer FAKE' } }), 'LOCAL_AUTH_REJECTED'],
    [request => ({ ...request, body: { ...request.body, model: 'deepseek-flash' } }), 'CLI_REQUEST_REJECTED'],
    [request => ({ ...request, body: { ...request.body, model: 'claude-sonnet-5-6' } }), 'CLI_REQUEST_REJECTED']]) {
    const { observed, terminal } = await run({ requestChange: change }); assert.equal(terminal.code, code); assert.equal(observed.upstream.length, 0);
  }
});
await check('missing OAuth protocol and altered official identity, attribution or arbitrary metadata fail closed', async () => {
  const changes = [request => ({ ...request, headers: { ...request.headers, 'anthropic-beta': 'claude-code-20250219' } }),
    request => ({ ...request, headers: { ...request.headers, 'x-claude-code-session-id': 'fc950802-41cb-4af3-a442-cee67ed257c5' } }),
    request => ({ ...request, body: { ...request.body, system: 'fake identity' } }),
    request => ({ ...request, body: { ...request.body, system: request.body.system.map((block, index) => index === 1 ? { ...block, text: 'fake identity' } : block) } }),
    request => ({ ...request, body: { ...request.body, metadata: { user_id: '/Users/private/path' } } }),
    request => ({ ...request, body: { ...request.body, metadata: { ...request.body.metadata, additional: 'private' } } })];
  for (const requestChange of changes) {
    const { observed, terminal } = await run({ requestChange }); assert.equal(terminal.code, 'SUBSCRIPTION_PROTOCOL_REJECTED');
    assert.equal(observed.upstream.length, 0);
  }
});
await check('expired, denied and exhausted subscription responses have safe codes and no API fallback', async () => {
  for (const status of [401, 403, 429]) {
    const { observed, terminal, events } = await run({ status }); assert.equal(terminal.code, `SUBSCRIPTION_HTTP_${status}`);
    assert.equal(observed.upstream.length, 1); assert.equal(events.filter(event => event.type === 'delta').length, 0);
    assert.equal(observed.upstream[0].provider, 'claude-subscription');
  }
});
await check('proxy policy, runtime language, Seatbelt and no-tools admission remain unchanged in subscription mode', async () => {
  const { observed, terminal } = await run(); assert.equal(terminal.type, 'completed');
  assert.deepEqual(observed.upstream[0].network, SUBSCRIPTION_INPUT.network);
  assert.equal(observed.query.options.env.TZ, 'Asia/Tokyo'); assert.equal(observed.query.options.env.LANG, 'ja_JP.UTF-8');
  assert.match(observed.profile, /\(deny network\*\)/); assert.match(observed.profile, /\(allow network-outbound \(remote ip "localhost:[0-9]+"\)\)/);
  assert.match(observed.profile, /\(subpath "\/Library\/Keychains"\)/); assert.match(observed.profile, /\(deny process-exec \(literal "\/usr\/bin\/security"\)\)/);
  for (const field of ['tools', 'allowedTools', 'plugins', 'skills', 'settingSources']) assert.deepEqual(observed.query.options[field], []);
  assert.deepEqual(observed.query.options.mcpServers, {}); assert.equal(observed.query.options.persistSession, false);
  for (const field of ['tools', 'mcp_servers', 'skills', 'plugins']) {
    const rejected = await run({ initChange: init => ({ ...init, [field]: ['unexpected'] }) });
    assert.equal(rejected.terminal.code, 'NO_TOOLS_CONTRACT'); assert.equal(rejected.observed.upstream.length, 0);
  }
});
await check('subscription request budget, cancellation and diagnostic redaction keep their bounds', async () => {
  assert.equal((await run({ requests: 4 })).terminal.code, 'REQUEST_LIMIT');
  assert.equal((await run({ transportError: true })).terminal.code, 'PROVIDER_CONNECTION_FAILED');
  const { observed, terminal } = await run({ blockedUntilAbort: true, timeoutMs: 30 });
  assert.equal(terminal.code, 'TOTAL_TIMEOUT'); assert.ok(observed.closed > 0); assert.equal(observed.upstream.length, 0);
});
console.log(JSON.stringify({ schema: 'claude-subscription-fake-tests/v1', passed: checks,
  remote_provider_calls: false, native_cli_executed: false, real_subscription_verified: false, keychain_access: false }));
