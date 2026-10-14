// New host broker + independently selected immutable runtime; inert credentials
// and a local fake SSE only. No provider request or runtime catalog mutation.
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { createServer } from 'node:net';
import { createReadStream } from 'node:fs';
import { readFile, realpath, stat, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { performance } from 'node:perf_hooks';
import { setTimeout as delay } from 'node:timers/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { FAKE_SUBSCRIPTION_TOKEN, SUBSCRIPTION_INPUT, subscriptionSSE } from './subscription-test-fixtures.mjs';

const SOURCE_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const options = new Map();
const allowed = ['--broker-root', '--runtime-root', '--rollback-runtime-root', '--output'];
for (let index = 2; index < process.argv.length; index += 2) {
  const option = process.argv[index], value = process.argv[index + 1];
  assert(allowed.includes(option) && value && !options.has(option), 'INVALID_TEST_ARGUMENTS');
  options.set(option, value);
}
async function canonicalRoot(value) {
  assert(typeof value === 'string' && path.isAbsolute(value), 'ABSOLUTE_RUNTIME_ROOT_REQUIRED');
  assert.equal(await realpath(value), value, 'CANONICAL_RUNTIME_ROOT_REQUIRED');
  return value;
}
const brokerRoot = await canonicalRoot(options.get('--broker-root') ?? SOURCE_ROOT);
const runtimeRoot = await canonicalRoot(options.get('--runtime-root'));
const rollbackRoot = options.has('--rollback-runtime-root') ? await canonicalRoot(options.get('--rollback-runtime-root')) : null;
const output = options.get('--output');
if (output) assert(path.isAbsolute(output), 'ABSOLUTE_OUTPUT_REQUIRED');
const moduleURL = name => pathToFileURL(path.join(brokerRoot, 'sdk', name)).href;
let blockedHostSDKImports = 0;
const hooks = registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier.includes('@anthropic-ai/')) { blockedHostSDKImports++; throw new Error('HOST_SDK_IMPORT_FORBIDDEN'); }
  return nextResolve(specifier, context);
} });
const { runVMTextChat, productionLauncher } = await import(moduleURL('vm-text-chat.mjs'));
const { officialTransport } = await import(moduleURL('deepseek-text-chat.mjs'));
const { REQUEST_TRACE_HEADERS, PROVIDER_URL, SUBSCRIPTION_URL } = await import(moduleURL('request-trace.mjs'));
const FAKE_API_KEY = 'sk-HOST-ONLY-INERT-REQUEST-TRACE-NATIVE-FIXTURE';
const ACK = 'REQUEST_TRACE_NATIVE_OK';
const SSE_END_DELAY_MS = 180;
const knownSecrets = [FAKE_API_KEY, FAKE_SUBSCRIPTION_TOKEN];
const receipts = [], artifacts = [];
const hashBytes = bytes => createHash('sha256').update(bytes).digest('hex');

async function hashFile(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
async function inventory(root) {
  const base = path.join(root, 'host/text-runtime');
  const config = JSON.parse(await readFile(path.join(base, 'runtime-config.json'), 'utf8'));
  const images = path.resolve(base, config.image_dir), guest = path.resolve(base, config.guest_runtime_dir);
  const files = [path.join(base, 'runtime-config.json'), path.join(base, 'launch.py'), path.join(base, 'common.py'),
    path.resolve(base, config.runner), ...['base.json', 'kernel', 'initrd', 'guest.raw'].map(name => path.join(images, name)),
    ...['bootstrap.sh', 'supervisor.py', 'runtime.mjs'].map(name => path.join(guest, name)),
    path.join(root, 'sdk/deepseek-text-chat.mjs')];
  const values = [];
  for (const file of files) {
    const info = await stat(file, { bigint: true });
    values.push({ path: path.relative(root, file), bytes: String(info.size), mode: String(info.mode),
      mtime_ns: String(info.mtimeNs), ctime_ns: String(info.ctimeNs), sha256: await hashFile(file) });
  }
  const versions = JSON.parse(await readFile(path.join(images, 'base.json'), 'utf8'));
  assert(/^\d+\.\d+\.\d+$/.test(versions.cli_version) && /^\d+\.\d+\.\d+$/.test(versions.sdk_version), 'INVALID_RUNTIME_VERSION_METADATA');
  assert.equal(values.find(value => value.path.endsWith('/guest.raw')).sha256, versions.disk_sha256, 'RUNTIME_DISK_DIGEST_MISMATCH');
  return { cli_version: versions.cli_version, sdk_version: versions.sdk_version, files: values };
}
function sanitized(value, credential) {
  if (typeof value === 'string') return value.split(credential).join('[REDACTED]');
  if (Array.isArray(value)) return value.map(child => sanitized(child, credential));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, child]) => [key.split(credential).join('[REDACTED]'), sanitized(child, credential)]));
  return value;
}
function inputFor(provider, model) {
  const credential = provider === 'deepseek-api' ? FAKE_API_KEY : FAKE_SUBSCRIPTION_TOKEN;
  const input = { ...SUBSCRIPTION_INPUT, request_id: randomUUID(), provider, model,
    text_skills: [{ name: 'Local trace fixture', content: `Answer the latest question. Inert host-only marker: ${credential}` }] };
  if (provider === 'deepseek-api') { delete input.subscriptionToken; input.apiKey = credential; }
  return input;
}

async function run(root, label, input, mode = 'success') {
  const began = performance.now(), controller = new AbortController();
  let sent = '', providerCalls = 0, observedBody, observedHeaders, nativeModel;
  let sseStarted, sseEnded, terminalTraceAt;
  const kinds = [], events = [];
  const dependencies = { testOnly: true, signal: controller.signal,
    launch: async () => {
      const child = await productionLauncher(root);
      const originalWrite = child.stdin.write.bind(child.stdin);
      child.stdin.write = (...args) => { sent += String(args[0]); return originalWrite(...args); };
      let pending = '';
      child.stdout.on('data', chunk => {
        pending += chunk;
        while (pending.includes('\n')) {
          const at = pending.indexOf('\n'), frame = JSON.parse(pending.slice(0, at));
          pending = pending.slice(at + 1); kinds.push(frame.kind);
          if (frame.kind === 'native_init') nativeModel = frame.model;
        }
      });
      return child;
    },
    transport: async parameters => {
      providerCalls++;
      observedBody = JSON.stringify(parameters.body); observedHeaders = parameters.headers;
      assert.deepEqual(parameters.body.messages, input.messages.map(({ role, text }) => ({ role, content: text })));
      assert.equal(parameters.body.tools.length, 0);
      assert(!observedBody.includes('/Users/') && !observedBody.includes('/home/claude'), 'HOST_OR_GUEST_PATH_IN_PROVIDER_BODY');
      if (mode === 'proxy-failure') return officialTransport(parameters);
      if (mode === 'cancel-active') return { statusCode: 200, contentType: 'text/event-stream', stream: (async function* () {
        sseStarted = performance.now(); await delay(75); controller.abort();
        throw Object.assign(new Error(`Private cancelled diagnostic ${FAKE_API_KEY}`), { code: 'CHAT_CANCELLED' });
      })() };
      const upstream = subscriptionSSE(ACK, parameters.body.model);
      return { ...upstream, stream: (async function* () {
        sseStarted = performance.now();
        for await (const chunk of upstream.stream) yield chunk;
        // The final SSE frame has already arrived; completion still must wait
        // for the entire stream, rather than timing only response headers.
        await delay(SSE_END_DELAY_MS); sseEnded = performance.now();
      })() };
    } };
  const terminal = await runVMTextChat(input, event => {
    events.push(event);
    if (event.type === 'request_trace' && event.trace.phase !== 'request') terminalTraceAt = performance.now();
  }, dependencies, root);
  const traces = events.filter(event => event.type === 'request_trace').map(event => event.trace);
  assert.equal(providerCalls, 1, 'EXPECTED_ONE_PROVIDER_ATTEMPT');
  assert.equal(traces.length, 2, 'EXPECTED_REQUEST_AND_TERMINAL_TRACE');
  const [request, final] = traces;
  const credential = input.apiKey ?? input.subscriptionToken;
  const expected = JSON.stringify(sanitized(JSON.parse(observedBody), credential));
  for (const trace of traces) {
    assert.equal(trace.schema, 'claude-request-trace/v1');
    assert.equal(trace.attempt_id, `${input.request_id}:1`);
    assert.equal(trace.provider, input.provider);
    assert.equal(trace.method, 'POST');
    assert.equal(trace.url, input.provider === 'claude-subscription' ? SUBSCRIPTION_URL : PROVIDER_URL);
    assert.equal(trace.body === expected, true, 'TRACE_AND_TRANSPORT_BODY_BYTES_DIFFER');
    assert.equal(trace.body_bytes, Buffer.byteLength(observedBody));
    assert.equal(trace.body_truncated, false); assert.equal(trace.secrets_redacted, true);
    assert.equal(trace.wire_model, JSON.parse(observedBody).model);
    assert.deepEqual(trace.proxy, { mode: 'http-connect', url: input.network.proxyURL });
    assert(Object.keys(trace.headers).every(name => REQUEST_TRACE_HEADERS.includes(name)), 'UNSAFE_TRACE_HEADER');
    assert.equal(trace.headers['content-type'], 'application/json');
    assert.equal(trace.headers['content-length'], String(Buffer.byteLength(observedBody)));
    assert.equal(trace.headers['anthropic-version'], '2023-06-01');
    assert.equal(Object.keys(trace.headers).some(name => /authorization|cookie|api.key/i.test(name)), false);
    for (const [name, value] of Object.entries(observedHeaders)) assert.equal(trace.headers[name], value);
  }
  assert.equal(request.phase, 'request'); assert.equal(request.status, null); assert.equal(request.duration_ms, null);
  assert.equal(request.outcome, null); assert.equal(request.error_code, null);
  assert(final.duration_ms >= 0, 'INVALID_TRACE_DURATION');
  const serializedEvents = JSON.stringify(events);
  assert(knownSecrets.every(secret => !serializedEvents.includes(secret)), 'FAKE_CREDENTIAL_IN_TRACE_OR_UI_EVENT');
  assert(knownSecrets.every(secret => !sent.includes(secret)), 'HOST_CREDENTIAL_IN_GUEST_FRAME');
  assert(!sent.includes('Earlier question.') && !sent.includes('Earlier answer.'), 'GUEST_RECEIVED_HISTORY');
  assert(kinds.includes('vm_stopped'), 'VM_STOP_RECEIPT_MISSING');
  if (mode === 'success') {
    assert.equal(terminal.type, 'completed'); assert.equal(terminal.text, ACK);
    assert.equal(terminal.temporary_removed, true); assert.equal(terminal.proxy_closed, true);
    assert.equal(final.phase, 'response'); assert.equal(final.status, 200); assert.equal(final.outcome, 'http');
    assert.equal(final.error_code, null);
    assert(sseEnded - sseStarted >= SSE_END_DELAY_MS - 5, 'SSE_END_DELAY_NOT_OBSERVED');
    assert(final.duration_ms >= sseEnded - sseStarted - 2, 'TRACE_DURATION_OMITS_SSE');
    assert(terminalTraceAt >= sseEnded, 'TRACE_COMPLETED_BEFORE_SSE_END');
  } else {
    assert.equal(terminal.type, 'error');
    assert.equal(terminal.code, mode === 'cancel-active' ? 'PROCESS_INTERRUPTED' : 'PROXY_CONNECT_FAILED');
    assert.equal(final.phase, 'error'); assert.equal(final.status, mode === 'cancel-active' ? 200 : null);
    assert.equal(final.outcome, mode === 'cancel-active' ? 'cancelled' : 'network_error');
    assert.equal(final.error_code, mode === 'cancel-active' ? 'CHAT_CANCELLED' : 'PROVIDER_NETWORK_ERROR');
  }
  const receipt = { runtime: label, provider: input.provider, selector: input.model, mode,
    native_model: nativeModel, terminal: terminal.type, error_code: terminal.code ?? null,
    duration_seconds: +((performance.now() - began) / 1000).toFixed(2), provider_calls: providerCalls,
    guest_frame_kinds: [...new Set(kinds)], vm_stop_receipt: true,
    host_credential_absent_from_guest_frames: true, guest_receives_current_prompt_only: true,
    fake_credentials_absent_from_trace_and_ui_events: true,
    trace_body_equals_transport_json_except_known_secret: true,
    transport_body_bytes: Buffer.byteLength(observedBody),
    sanitized_transport_body_sha256: hashBytes(expected),
    delayed_sse_ms: sseEnded === undefined ? null : +(sseEnded - sseStarted).toFixed(3),
    trace_duration_includes_full_sse: mode === 'success' ? true : null,
    trace_event_phases: traces.map(trace => trace.phase), traces, real_provider_calls: false };
  receipts.push(receipt);
  console.error(JSON.stringify({ runtime: label, provider: input.provider, selector: input.model,
    mode, terminal: receipt.terminal, error_code: receipt.error_code, wire_model: final.wire_model,
    trace_status: final.status, trace_duration_ms: final.duration_ms, vm_stop_receipt: true }));
}

try {
  const roots = [{ root: runtimeRoot, label: 'active' }, ...(rollbackRoot ? [{ root: rollbackRoot, label: 'rollback' }] : [])];
  for (const { root, label } of roots) {
    const before = await inventory(root);
    await run(root, label, inputFor('deepseek-api', 'deepseek-flash[1m]'));
    for (const model of ['sonnet', 'opus', 'haiku']) await run(root, label, inputFor('claude-subscription', model));
    if (label === 'active') {
      const reserved = createServer(); reserved.listen(0, '127.0.0.1'); await once(reserved, 'listening');
      const port = reserved.address().port; await new Promise(resolve => reserved.close(resolve));
      const input = inputFor('deepseek-api', 'deepseek-flash[1m]');
      input.network = { ...input.network, proxyURL: `http://127.0.0.1:${port}` };
      await run(root, label, input, 'proxy-failure');
      await run(root, label, inputFor('deepseek-api', 'deepseek-flash[1m]'), 'cancel-active');
    }
    const after = await inventory(root);
    assert.deepEqual(after, before, 'IMMUTABLE_RUNTIME_ARTIFACT_CHANGED');
    artifacts.push({ runtime: label, root, cli_version: before.cli_version, sdk_version: before.sdk_version,
      launcher_guest_runner_kernel_initrd_disk_and_admission_helpers_unchanged: true,
      before_and_after_sha256_equal: true, files: before.files });
  }
  assert.equal(blockedHostSDKImports, 0);
  const brokerFiles = {};
  for (const name of ['vm-text-chat.mjs', 'deepseek-text-chat.mjs', 'request-trace.mjs', 'owned-run-directory.mjs'])
    brokerFiles[name] = await hashFile(path.join(brokerRoot, 'sdk', name));
  const evidence = { schema: 'request-trace-native-compatibility/v1', status: 'passed_local_native_vm',
    date: '2026-10-13', broker_root: brokerRoot, broker_source: brokerRoot === SOURCE_ROOT ? 'new_source_host_broker' : 'new_app_bundled_host_broker',
    broker_files_sha256: brokerFiles, host_node_version: process.versions.node, host_node_path: process.execPath,
    runtime_context_argument: 'fourth_parameter_absolute_runtime_root', runs: receipts.length,
    host_sdk_import_forbidden_by_test_hook: true, host_sdk_import_attempts: blockedHostSDKImports,
    runtime_catalog_read: false, runtime_catalog_written: false,
    real_credentials_read: false, real_provider_calls: false, real_subscription_verified: false,
    active_and_rollback_artifacts: artifacts, receipts };
  const bytes = JSON.stringify(evidence, null, 2) + '\n';
  assert(knownSecrets.every(secret => !bytes.includes(secret)), 'FAKE_CREDENTIAL_IN_EVIDENCE');
  if (output) { await writeFile(output, bytes); assert.equal(await readFile(output, 'utf8'), bytes, 'EVIDENCE_READBACK_MISMATCH'); }
  console.log(bytes);
} finally { hooks.deregister(); }
