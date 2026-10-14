// Real pinned official CLI + real SDK + macOS Seatbelt. Provider transport is
// local-only and tokens are inert. This does not validate a real subscription.
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { access, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { query as officialQuery } from '@anthropic-ai/claude-agent-sdk';
import { inspectInstalledNativeMetadata } from './deepseek-text-smoke.mjs';
import { runDeepSeekTextChat } from './deepseek-text-chat.mjs';
import { FAKE_SUBSCRIPTION_TOKEN, SUBSCRIPTION_ACK, SUBSCRIPTION_INPUT, subscriptionSSE } from './subscription-test-fixtures.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const metadata = await inspectInstalledNativeMetadata();
const receipts = [];
let checks = 0;
async function check(name, fn) { await fn(); checks++; console.log(`PASS ${name}`); }

for (const model of ['sonnet', 'opus', 'haiku']) await check(`official native ${model} OAuth path streams under unchanged Seatbelt and removes temporary state`, async () => {
  let options, outbound, profile, childEnvironment;
  const events = [];
  const dependencies = { ...metadata, testOnly: true, nativeFixture: true, timeoutMs: 20000,
    query(request) { options = request.options; return officialQuery(request); },
    spawn(command, args, launchOptions) {
      assert.equal(command, '/usr/bin/sandbox-exec');
      assert.equal(args[2], metadata.cliPath);
      childEnvironment = launchOptions.env;
      return spawn(command, args, launchOptions);
    },
    async transport(parameters) {
      assert.equal(outbound, undefined, 'only one native provider request expected'); outbound = parameters;
      const launchProfilePath = options.cwd.replace(/\/empty-workspace$/, '/cli.sb');
      profile = await readFile(launchProfilePath, 'utf8');
      return subscriptionSSE(SUBSCRIPTION_ACK, parameters.body.model);
    } };
  const terminal = await runDeepSeekTextChat({ ...SUBSCRIPTION_INPUT, model }, event => events.push(event), dependencies);
  assert.equal(terminal.type, 'completed', JSON.stringify(terminal));
  assert.equal(terminal.text, SUBSCRIPTION_ACK); assert.equal(terminal.model, model);
  assert.equal(terminal.no_tools, true); assert.equal(terminal.cli_exit, 0); assert.equal(terminal.cli_signal, null);
  assert.equal(terminal.temporary_removed, true); assert.equal(terminal.proxy_closed, true); assert.equal(terminal.request_count, 1);
  assert.equal(childEnvironment.CLAUDE_CODE_OAUTH_TOKEN, FAKE_SUBSCRIPTION_TOKEN);
  assert.equal(childEnvironment.ANTHROPIC_API_KEY, undefined); assert.equal(childEnvironment.ANTHROPIC_AUTH_TOKEN, undefined);
  assert.equal(childEnvironment.TZ, 'Asia/Tokyo'); assert.equal(childEnvironment.LANG, 'ja_JP.UTF-8');
  assert.equal(outbound.provider, 'claude-subscription'); assert.equal(outbound.subscriptionToken, FAKE_SUBSCRIPTION_TOKEN);
  assert.equal('apiKey' in outbound, false); assert.match(outbound.body.model, new RegExp(`^claude-${model}-[0-9]`));
  assert.deepEqual(outbound.body.messages, SUBSCRIPTION_INPUT.messages.map(({ role, text }) => ({ role, content: text })));
  assert.match(outbound.headers['anthropic-beta'], /oauth-2025-04-20/); assert.equal(outbound.headers['x-app'], 'cli');
  assert.equal(outbound.headers['x-api-key'], undefined); assert.equal(outbound.headers.authorization, undefined);
  assert.equal(outbound.body.system[1].text, "You are a Claude agent, built on Anthropic's Claude Agent SDK.");
  assert.ok(outbound.body.system[2].text.includes('Text fixture'));
  assert.equal(JSON.stringify(outbound.body).includes(options.cwd), false);
  assert.match(profile, /\(deny network\*\)/); assert.match(profile, /\(allow network-outbound \(remote ip "localhost:[0-9]+"\)\)/);
  assert.match(profile, /\(subpath "\/Library\/Keychains"\)/); assert.match(profile, /\(deny process-exec \(literal "\/usr\/bin\/security"\)\)/);
  await assert.rejects(access(options.cwd), { code: 'ENOENT' });
  assert.equal(JSON.stringify(events).includes(FAKE_SUBSCRIPTION_TOKEN), false);
  receipts.push({ selector: model, resolved_model: outbound.body.model, oauth_beta_present: true,
    native_beta_tags: outbound.headers['anthropic-beta'].split(','),
    native_api_key_absent: true, request_count: terminal.request_count, no_tools: terminal.no_tools,
    cli_exit: terminal.cli_exit, cli_signal: terminal.cli_signal,
    temporary_removed: terminal.temporary_removed, gateway_closed: terminal.proxy_closed });
});

await check('production subscription transport sends Anthropic CONNECT through configured proxy and fails closed', async () => {
  // Refuse CONNECT locally. No DNS, TLS or remote network connection occurs.
  // This runs the production transport, not a mocked endpoint selector.
  const targets = [];
  const proxy = http.createServer();
  proxy.on('connect', (request, socket) => {
    targets.push(request.url);
    socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
  });
  await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
  const network = { ...SUBSCRIPTION_INPUT.network, proxyURL: `http://127.0.0.1:${proxy.address().port}` };
  try {
    const events = [];
    const terminal = await runDeepSeekTextChat({ ...SUBSCRIPTION_INPUT, network }, event => events.push(event));
    assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'PROXY_CONNECT_REJECTED');
    assert.deepEqual(targets, ['api.anthropic.com:443']);
    assert.equal(events.filter(event => event.type === 'delta').length, 0);
    assert.equal(JSON.stringify(events).includes(FAKE_SUBSCRIPTION_TOKEN), false);
  } finally { await new Promise(resolve => proxy.close(resolve)); }
});

await check('official native binary is unchanged after all fixture and production refusal runs', async () => {
  assert.equal(hash(await readFile(metadata.cliPath)), metadata.cliSha256);
});
console.log(JSON.stringify({ schema: 'claude-subscription-native-local-checks/v1', passed: checks,
  native_cli_executed: true, sdk_version: '0.3.295', cli_version: '2.1.295', sandbox_executed: true,
  real_subscription_verified: false, remote_provider_calls: false,
  auth: 'CLAUDE_CODE_OAUTH_TOKEN -> native Bearer -> local gateway',
  production_proxy_connect_target: 'api.anthropic.com:443', direct_fallback: false,
  keychain_checks: { verification_type: 'sandbox_profile_static_assertions',
    keychain_file_read_deny_rule_present: true, security_process_exec_deny_rule_present: true,
    direct_keychain_api_access: 'unverified', securityd_ipc_access: 'unverified' }, receipts }));
