// Real Linux SDK/CLI and no-NIC VM; only synthetic credentials/local provider.
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { performance } from 'node:perf_hooks';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { SUBSCRIPTION_INPUT, subscriptionSSE } from './subscription-test-fixtures.mjs';

let blockedHostSDKImports = 0;
const hooks = registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier.includes('@anthropic-ai/')) { blockedHostSDKImports++; throw new Error('HOST_SDK_IMPORT_FORBIDDEN'); }
  return nextResolve(specifier, context);
} });
const bundled = process.argv.length === 4 && process.argv[2] === '--runtime-root';
if (process.argv.length !== 2 && !bundled) throw new Error('INVALID_TEST_ARGUMENTS');
const moduleURL = name => bundled ? pathToFileURL(path.resolve(process.argv[3], 'sdk', name)).href : new URL(name, import.meta.url).href;
const baseURL = bundled ? pathToFileURL(path.resolve(process.argv[3], 'host/text-runtime/images/base.json')) : new URL('../host/text-runtime/images/base.json', import.meta.url);
const runtimeVersions = JSON.parse(await readFile(baseURL, 'utf8'));
const cliVersion = bundled ? runtimeVersions.cli_version : JSON.parse(await readFile(new URL('node_modules/@anthropic-ai/claude-agent-sdk/package.json', import.meta.url), 'utf8')).claudeCodeVersion;
if (!/^\d+\.\d+\.\d+$/.test(runtimeVersions.sdk_version ?? '') ||
    !/^\d+\.\d+\.\d+$/.test(cliVersion ?? '')) throw new Error('INVALID_RUNTIME_VERSION_METADATA');
const { runVMTextChat, productionLauncher } = await import(moduleURL('vm-text-chat.mjs'));
const { officialTransport } = await import(moduleURL('deepseek-text-chat.mjs'));
const receipts = [], deviceIDs = [], sessionIDs = [];
const ACK = 'VM_NATIVE_PRIVATE_OK';
const deepseek = { ...SUBSCRIPTION_INPUT, provider: 'deepseek-api', model: 'deepseek-flash[1m]',
  apiKey: 'sk-HOST-ONLY-INERT-VM-PRIVACY-FIXTURE' };
delete deepseek.subscriptionToken;

async function run(input, mode = 'success') {
  const start = performance.now();
  let sent = '', kinds = [], providerCalls = 0, beta = [], identity;
  const events = [], controller = new AbortController();
  const dependencies = { testOnly: true, signal: controller.signal, launch: async () => {
    const child = await productionLauncher();
    const originalWrite = child.stdin.write.bind(child.stdin);
    child.stdin.write = (...args) => { sent += String(args[0]); return originalWrite(...args); };
    let pending = '';
    child.stdout.on('data', chunk => {
      pending += chunk;
      while (pending.includes('\n')) {
        const at = pending.indexOf('\n'); const frame = JSON.parse(pending.slice(0, at)); pending = pending.slice(at + 1);
        kinds.push(frame.kind);
      }
    });
    return child;
  }, transport: async parameters => {
    providerCalls++;
    if (mode === 'proxy-failure') return officialTransport(parameters);
    if (mode === 'cancel-active') {
      controller.abort();
      throw Object.assign(new Error('CHAT_CANCELLED'), { code: 'CHAT_CANCELLED' });
    }
    assert.deepEqual(parameters.body.messages, input.messages.map(({ role, text }) => ({ role, content: text })));
    assert.equal(parameters.body.tools.length, 0);
    assert.equal(JSON.stringify(parameters.body).includes('/Users/'), false);
    assert.equal(JSON.stringify(parameters.body).includes('/home/claude'), false);
    if (input.provider === 'claude-subscription') {
      identity = JSON.parse(parameters.body.metadata.user_id);
      beta = parameters.headers['anthropic-beta'].split(',');
      assert.equal(identity.account_uuid, '');
    } else assert.equal('metadata' in parameters.body, false);
    return subscriptionSSE(ACK, parameters.body.model);
  } };
  const terminal = await runVMTextChat(input, event => events.push(event), dependencies);
  const receipt = { provider: input.provider, selector: input.model, mode, terminal: terminal.type,
    error_code: terminal.code ?? null, duration_seconds: +((performance.now() - start) / 1000).toFixed(2),
    guest_frame_kinds: [...new Set(kinds)], provider_calls: providerCalls, native_beta_tags: beta,
    host_credential_absent_from_guest_frames: !sent.includes(input.apiKey ?? input.subscriptionToken),
    guest_receives_current_prompt_only: !sent.includes('Earlier question.') && !sent.includes('Earlier answer.'),
    vm_stop_receipt: kinds.includes('vm_stopped'), real_provider_calls: false };
  receipts.push(receipt);
  console.error(JSON.stringify(receipt));
  assert.equal(receipt.host_credential_absent_from_guest_frames, true);
  assert.equal(receipt.guest_receives_current_prompt_only, true);
  assert.equal(receipt.vm_stop_receipt, true);
  if (mode === 'success') {
    assert.equal(terminal.type, 'completed'); assert.equal(terminal.text, ACK);
    assert.equal(terminal.temporary_removed, true); assert.equal(terminal.proxy_closed, true);
    if (identity) { deviceIDs.push(identity.device_id); sessionIDs.push(identity.session_id); }
  } else {
    assert.equal(terminal.type, 'error');
    assert.equal(terminal.code, mode === 'cancel-active' ? 'PROCESS_INTERRUPTED' : 'PROXY_CONNECT_FAILED');
  }
}

try {
  await run(deepseek);
  for (const model of ['sonnet', 'sonnet', 'opus', 'haiku']) await run({ ...SUBSCRIPTION_INPUT, model });
  const reserved = createServer(); reserved.listen(0, '127.0.0.1'); await once(reserved, 'listening');
  const port = reserved.address().port; await new Promise(resolve => reserved.close(resolve));
  await run({ ...deepseek, network: { ...deepseek.network, proxyURL: `http://127.0.0.1:${port}` } }, 'proxy-failure');
  await run(deepseek, 'cancel-active');
  assert.equal(new Set(deviceIDs).size, deviceIDs.length);
  assert.equal(new Set(sessionIDs).size, sessionIDs.length);
  assert.equal(blockedHostSDKImports, 0);
  console.log(JSON.stringify({ schema: 'vm-native-privacy-gate/v1', status: 'passed_local_native_vm',
    artifact: bundled ? 'bundled_runtime' : 'source_runtime',
    runs: receipts.length, sdk_version: runtimeVersions.sdk_version, cli_version: cliVersion,
    host_sdk_import_forbidden_by_test_hook: true, host_sdk_import_attempts: blockedHostSDKImports,
    fresh_config_device_ids_differ: true, fresh_sessions_differ: true,
    real_credentials_read: false, real_provider_calls: false, real_subscription_verified: false, receipts }, null, 2));
} finally { hooks.deregister(); }
