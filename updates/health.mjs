// Trusted App-owned probe: candidate native code stays inside the no-NIC VM.
import { lstat, readFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HEALTH_SCHEMA = 'runtime-update-health/v1';
const EVENT_SCHEMA = 'deepseek-text-chat-event/v1';
const INPUT_LIMIT = 16_384;
const FRAME_LIMIT = 1_048_576;
const DEADLINE_MS = 90_000;
const ACK = 'RUNTIME_UPDATE_HEALTH_OK';
const PROMPT = `Reply with exactly ${ACK} and nothing else.`;
const API_KEY = 'sk-UPDATE-HEALTH-INERT-NOT-A-REAL-CREDENTIAL';
const SUBSCRIPTION_TOKEN = 'sk-ant-oat01-UPDATE-HEALTH-INERT-NOT-A-REAL-CREDENTIAL';
const GATES = Object.freeze([
  { provider: 'deepseek-api', model: 'deepseek-flash[1m]', requestID: '06701978-4a06-4b97-802f-b5d2e2d84066' },
  { provider: 'claude-subscription', model: 'sonnet', requestID: '06701978-4a06-4b97-802f-b5d2e2d84067' },
  { provider: 'claude-subscription', model: 'opus', requestID: '06701978-4a06-4b97-802f-b5d2e2d84068' },
  { provider: 'claude-subscription', model: 'haiku', requestID: '06701978-4a06-4b97-802f-b5d2e2d84069' },
]);
const SYSTEM_PROMPT = 'You are an assistant in a text-only conversation. Respond to the user. No tools are available; do not emit tool calls.';
const SDK_IDENTITY = "You are a Claude agent, built on Anthropic's Claude Agent SDK.";
const SUBSCRIPTION_BETAS = new Set(['claude-code-20250219', 'oauth-2025-04-20',
  'mid-conversation-system-2026-04-07', 'interleaved-thinking-2025-05-14',
  'thinking-token-count-2026-05-13', 'context-management-2025-06-27',
  'prompt-caching-scope-2026-01-05', 'per-turn-control-2026-07-01',
  'mid-conversation-tool-changes-2026-07-01', 'effort-2025-11-24', 'extended-cache-ttl-2025-04-11']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const healthy = () => ({ type: 'healthy' });
const failed = () => ({ type: 'error', code: 'UPDATE_HEALTH_FAILED' });
const reject = () => { throw new Error('UPDATE_HEALTH_FAILED'); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exactKeys = (value, keys) => object(value) && Object.keys(value).length === keys.length &&
  Object.keys(value).every(key => keys.includes(key));
const version = value => typeof value === 'string' && /^\d{1,9}\.\d{1,9}\.\d{1,9}$/.test(value);

async function candidateModulePath(input) {
  if (!exactKeys(input, ['schema', 'contentsRoot']) || input.schema !== HEALTH_SCHEMA ||
      typeof input.contentsRoot !== 'string' || Buffer.byteLength(input.contentsRoot) > 4096 ||
      /[\x00-\x1f\x7f]/.test(input.contentsRoot) || !path.isAbsolute(input.contentsRoot) ||
      path.resolve(input.contentsRoot) !== input.contentsRoot || path.basename(input.contentsRoot) !== 'Contents') reject();
  return await checkedCandidateFile(input.contentsRoot, 'Resources/Runtime/sdk/vm-text-chat.mjs');
}

async function checkedCandidateFile(contentsRoot, relative) {
  const modulePath = path.join(contentsRoot, relative);
  let current = path.parse(modulePath).root;
  // Swift verifies the complete candidate. The probe independently rejects a
  // symlink in the selected path, including macOS /var and /tmp aliases.
  const root = await lstat(current);
  if (root.isSymbolicLink() || !root.isDirectory()) reject();
  const components = modulePath.slice(current.length).split(path.sep);
  for (let index = 0; index < components.length; index++) {
    current = path.join(current, components[index]);
    const metadata = await lstat(current);
    if (metadata.isSymbolicLink() || (index === components.length - 1 ? !metadata.isFile() : !metadata.isDirectory())) reject();
  }
  return modulePath;
}

async function candidateVersions(contentsRoot) {
  const filename = await checkedCandidateFile(contentsRoot, 'Resources/Runtime/host/text-runtime/images/base.json');
  const metadata = await lstat(filename);
  if (metadata.nlink !== 1 || metadata.size < 1 || metadata.size > 65_536) reject();
  const bytes = await readFile(filename);
  if (bytes.length > 65_536) reject();
  const base = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  if (!object(base) || base.schema !== 'claude-text-vm-base/v1' || !version(base.sdk_version) || !version(base.cli_version)) reject();
  return { sdkVersion: base.sdk_version, cliVersion: base.cli_version };
}

function chatInput(gate) {
  return { schema: 'deepseek-text-chat/v1', request_id: gate.requestID, provider: gate.provider,
    ...(gate.provider === 'deepseek-api' ? { apiKey: API_KEY } : { subscriptionToken: SUBSCRIPTION_TOKEN }),
    model: gate.model, messages: [{ role: 'user', text: PROMPT }], text_skills: [],
    network: { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:1', dnsPolicy: 'proxy-only' },
    runtime: { schema: 'app-runtime-profile/v1', timeZone: 'UTC', language: 'en' } };
}

function localSSE(signal, model) {
  // The production health path owns this fixed stream; no fixture module,
  // socket, credential store, environment setting or provider is consulted.
  const frames = [
    ['message_start', { type: 'message_start', message: { id: 'msg_runtime_update_health', type: 'message',
      role: 'assistant', model, content: [], usage: { input_tokens: 20, output_tokens: 0 } } }],
    ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
    ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: ACK } }],
    ['content_block_stop', { type: 'content_block_stop', index: 0 }],
    ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 10 } }],
    ['message_stop', { type: 'message_stop' }],
  ];
  const bytes = Buffer.from(frames.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join(''));
  return { statusCode: 200, contentType: 'text/event-stream', stream: (async function* () {
    for (let offset = 0; offset < bytes.length; offset += 64) {
      if (signal.aborted) reject();
      yield bytes.subarray(offset, offset + 64);
    }
  })() };
}

function validProviderRequest(parameters, gate, versions, nativeModel, nativeSession) {
  const body = parameters?.body, network = parameters?.network;
  if (!(exactKeys(parameters, ['body', 'provider', 'apiKey', 'subscriptionToken', 'headers', 'signal', 'network']) &&
    parameters.provider === gate.provider && parameters.signal instanceof AbortSignal && !parameters.signal.aborted &&
    exactKeys(network, ['schema', 'proxyURL', 'dnsPolicy']) && network.schema === 'app-network-policy/v1' &&
    network.proxyURL === 'http://127.0.0.1:1' && network.dnsPolicy === 'proxy-only' &&
    body?.model === nativeModel && body.stream === true && body.max_tokens === 4096 &&
    exactKeys(body.thinking, ['type']) && body.thinking.type === 'disabled' &&
    Array.isArray(body.tools) && body.tools.length === 0 &&
    Array.isArray(body.messages) && body.messages.length === 1 &&
    exactKeys(body.messages[0], ['role', 'content']) && body.messages[0].role === 'user' && body.messages[0].content === PROMPT)) return false;
  if (gate.provider === 'deepseek-api') {
    return parameters.apiKey === API_KEY && parameters.subscriptionToken === undefined && exactKeys(parameters.headers, []) &&
      exactKeys(body, ['model', 'stream', 'max_tokens', 'thinking', 'tools', 'system', 'messages']) && body.system === SYSTEM_PROMPT;
  }
  const headers = parameters.headers;
  const beta = headers?.['anthropic-beta'], tags = typeof beta === 'string' ? beta.split(',') : [];
  if (parameters.apiKey !== undefined || parameters.subscriptionToken !== SUBSCRIPTION_TOKEN ||
      !exactKeys(headers, ['anthropic-version', 'anthropic-beta', 'x-app', 'user-agent',
        'x-claude-code-session-id', 'anthropic-dangerous-direct-browser-access']) ||
      headers['anthropic-version'] !== '2023-06-01' || headers['x-app'] !== 'cli' ||
      headers['user-agent'] !== `claude-cli/${versions.cliVersion} (external, sdk-ts, agent-sdk/${versions.sdkVersion})` ||
      typeof beta !== 'string' || beta.length > 4096 || !/^[a-z0-9,-]+$/.test(beta) ||
      tags.some(tag => !SUBSCRIPTION_BETAS.has(tag)) || new Set(tags).size !== tags.length ||
      !tags.includes('oauth-2025-04-20') || !tags.includes('claude-code-20250219') ||
      headers['x-claude-code-session-id'] !== nativeSession || headers['anthropic-dangerous-direct-browser-access'] !== 'true' ||
      !exactKeys(body, ['model', 'stream', 'max_tokens', 'thinking', 'tools', 'system', 'messages', 'metadata']) ||
      !Array.isArray(body.system) || body.system.length !== 3 || body.system.some(block => !exactKeys(block, ['type', 'text']) || block.type !== 'text') ||
      typeof body.system[0].text !== 'string' ||
      !new RegExp(`^x-anthropic-billing-header: cc_version=${versions.cliVersion.replaceAll('.', '\\.')}\\.[a-z0-9]{3}; cc_entrypoint=sdk-ts;$`).test(body.system[0].text) ||
      body.system[1].text !== SDK_IDENTITY || body.system[2].text !== SYSTEM_PROMPT ||
      !exactKeys(body.metadata, ['user_id']) || typeof body.metadata.user_id !== 'string' || body.metadata.user_id.length > 512) return false;
  let identity;
  try { identity = JSON.parse(body.metadata.user_id); } catch { return false; }
  return exactKeys(identity, ['device_id', 'account_uuid', 'session_id']) &&
    typeof identity.device_id === 'string' && /^[a-f0-9]{64}$/.test(identity.device_id) &&
    identity.account_uuid === '' && identity.session_id === nativeSession;
}

const BASE_FIELDS = ['schema', 'request_id', 'model', 'fixture_only', 'type'];
const COMPLETED_FIELDS = ['text', 'no_tools', 'cli_exit', 'cli_signal', 'temporary_removed', 'proxy_closed', 'request_count'];
function validEventBase(value, gate) {
  return object(value) && value.schema === EVENT_SCHEMA && value.request_id === gate.requestID &&
    value.model === gate.model && value.fixture_only === false;
}
function validCompletion(value, gate) {
  return validEventBase(value, gate) && exactKeys(value, [...BASE_FIELDS, ...COMPLETED_FIELDS]) &&
    value.type === 'completed' && value.text === ACK && value.no_tools === true && value.cli_exit === 0 &&
    value.cli_signal === null && value.temporary_removed === true && value.proxy_closed === true && value.request_count === 1;
}

// Function-only seams require explicit testOnly; the executable exposes none.
// Cancellation aborts the broker and awaits its native-process cleanup before
// returning the fixed receipt. The deadline begins before path validation.
export async function runHealthProbe(input, options = {}) {
  const controller = new AbortController();
  let timer, outsideSignal, listener;
  try {
    if (!object(options) || Object.keys(options).some(key => !['signal', 'testOnly', 'runtimeModule', 'timeoutMs'].includes(key)) ||
        (options.signal !== undefined && !(options.signal instanceof AbortSignal)) ||
        (options.testOnly !== undefined && options.testOnly !== true) ||
        ((options.runtimeModule !== undefined || options.timeoutMs !== undefined) && options.testOnly !== true) ||
        (options.timeoutMs !== undefined && (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 20 || options.timeoutMs > DEADLINE_MS))) reject();
    outsideSignal = options.signal;
    listener = () => controller.abort();
    outsideSignal?.addEventListener('abort', listener, { once: true });
    if (outsideSignal?.aborted) controller.abort();
    const timeoutMs = options.timeoutMs ?? DEADLINE_MS;
    const deadline = performance.now() + timeoutMs;
    timer = setTimeout(() => controller.abort(), timeoutMs);
    if (controller.signal.aborted) reject();
    const modulePath = await candidateModulePath(input);
    const versions = await candidateVersions(input.contentsRoot);
    if (controller.signal.aborted) reject();
    const runtime = options.runtimeModule ?? await import(pathToFileURL(modulePath).href);
    if (typeof runtime?.runVMTextChat !== 'function' || typeof runtime?.productionLauncher !== 'function' || controller.signal.aborted) reject();
    for (const gate of GATES) {
      if (controller.signal.aborted || performance.now() >= deadline ||
          !(await runProviderGate(runtime, gate, versions, controller, Math.max(20, Math.floor(deadline - performance.now()))))) return failed();
    }
    return healthy();
  } catch {
    // Paths, candidate diagnostics and credential-shaped data never leave this boundary.
    return failed();
  } finally {
    controller.abort();
    clearTimeout(timer);
    outsideSignal?.removeEventListener('abort', listener);
  }
}

async function runProviderGate(runtime, gate, versions, controller, timeoutMs) {
  let invalid = false, removeObserver, restoreWrite;
  let launchCount = 0, nativeInitCount = 0, stoppedCount = 0, startedCount = 0, completedCount = 0, providerCalls = 0;
  let deltaText = '', nativeModel, nativeSession;
  try {
    const markInvalid = () => { invalid = true; controller.abort(); };
    const launch = async () => {
      if (++launchCount !== 1 || controller.signal.aborted) reject();
      const child = await runtime.productionLauncher();
      if (!child?.stdout || typeof child.stdout.on !== 'function' || typeof child.stdout.removeListener !== 'function' ||
          !child.stdin || typeof child.stdin.write !== 'function') reject();
      // Provider credentials stay in the host broker. Check every outbound
      // guest frame before allowing it onto the isolated VM channel.
      const originalWrite = child.stdin.write;
      child.stdin.write = function(chunk, ...arguments_) {
        const bytes = typeof chunk === 'string' ? Buffer.from(chunk) : chunk instanceof Uint8Array ? Buffer.from(chunk) : undefined;
        if (!bytes || bytes.length > FRAME_LIMIT || bytes.includes(API_KEY) || bytes.includes(SUBSCRIPTION_TOKEN)) {
          markInvalid(); reject();
        }
        return originalWrite.call(this, chunk, ...arguments_);
      };
      restoreWrite = () => { child.stdin.write = originalWrite; };
      let pending = Buffer.alloc(0), frames = 0;
      const observe = chunk => {
        if (invalid) return;
        if (!(chunk instanceof Uint8Array) || pending.length + chunk.length > FRAME_LIMIT) { markInvalid(); return; }
        pending = Buffer.concat([pending, chunk]);
        for (;;) {
          const index = pending.indexOf(10);
          if (index < 0) break;
          if (++frames > 16384) { markInvalid(); return; }
          let frame;
          try { frame = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(pending.subarray(0, index))); }
          catch { markInvalid(); return; }
          pending = pending.subarray(index + 1);
          if (frame?.kind === 'native_init') {
            if (++nativeInitCount !== 1 || !exactKeys(frame, ['kind', 'model', 'session_id', 'no_tools']) ||
                !(gate.provider === 'deepseek-api' ? [gate.model, 'deepseek-flash'].includes(frame.model) :
                  typeof frame.model === 'string' && new RegExp(`^claude-${gate.model}-[0-9][a-z0-9-]{0,80}$`).test(frame.model)) ||
                !UUID.test(frame.session_id ?? '') || frame.no_tools !== true) markInvalid();
            else { nativeModel = frame.model.replace('[1m]', ''); nativeSession = frame.session_id; }
          } else if (frame?.kind === 'vm_stopped') {
            if (++stoppedCount !== 1 || frame.cleanup_complete !== true) markInvalid();
          }
        }
      };
      child.stdout.on('data', observe);
      removeObserver = () => { child.stdout.removeListener('data', observe); if (pending.length) invalid = true; };
      return child;
    };
    const emit = event => {
      if (!validEventBase(event, gate)) { markInvalid(); return; }
      if (event.type === 'started') {
        if (++startedCount !== 1 || nativeInitCount !== 1 || completedCount ||
            !exactKeys(event, [...BASE_FIELDS, 'no_tools']) || event.no_tools !== true) markInvalid();
      } else if (event.type === 'delta') {
        if (startedCount !== 1 || completedCount || !exactKeys(event, [...BASE_FIELDS, 'text']) ||
            typeof event.text !== 'string' || deltaText.length + event.text.length > ACK.length) markInvalid();
        else deltaText += event.text;
      } else if (event.type === 'completed') {
        if (++completedCount !== 1 || !validCompletion(event, gate) || startedCount !== 1 || deltaText !== ACK) markInvalid();
      } else markInvalid();
    };
    const terminal = await runtime.runVMTextChat(chatInput(gate), emit, { testOnly: true, signal: controller.signal,
      timeoutMs, launch, emitTrace: false, transport: async parameters => {
        if (++providerCalls !== 1 || nativeInitCount !== 1 || controller.signal.aborted ||
            !validProviderRequest(parameters, gate, versions, nativeModel, nativeSession)) reject();
        return localSSE(parameters.signal, parameters.body.model);
      } });
    removeObserver?.(); removeObserver = undefined;
    return !controller.signal.aborted && !invalid && launchCount === 1 && nativeInitCount === 1 && stoppedCount === 1 &&
      startedCount === 1 && completedCount === 1 && providerCalls === 1 && validCompletion(terminal, gate);
  } catch {
    // Paths, candidate diagnostics and credential-shaped data never leave this boundary.
    return false;
  } finally {
    removeObserver?.();
    restoreWrite?.();
  }
}

async function readInput(input, signal) {
  if (!input || typeof input[Symbol.asyncIterator] !== 'function' || typeof input.destroy !== 'function') reject();
  let size = 0;
  const chunks = [];
  const stop = () => input.destroy(new Error('UPDATE_HEALTH_FAILED'));
  const timer = setTimeout(stop, 10_000);
  signal.addEventListener('abort', stop, { once: true });
  try {
    if (signal.aborted) reject();
    for await (const chunk of input) {
      if (!(chunk instanceof Uint8Array)) reject();
      size += chunk.byteLength;
      if (size > INPUT_LIMIT) reject();
      chunks.push(chunk);
    }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
  } finally {
    clearTimeout(timer);
    signal.removeEventListener('abort', stop);
  }
}

export async function runHealthStdio({ input = process.stdin,
  emit = receipt => process.stdout.write(JSON.stringify(receipt) + '\n'), signal } = {}) {
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  const timer = setTimeout(interrupt, DEADLINE_MS);
  let receipt;
  try {
    if (typeof emit !== 'function' || (signal !== undefined && !(signal instanceof AbortSignal))) reject();
    signal?.addEventListener('abort', interrupt, { once: true });
    if (signal?.aborted) controller.abort();
    receipt = await runHealthProbe(await readInput(input, controller.signal), { signal: controller.signal });
  } catch {
    receipt = failed();
  } finally {
    clearTimeout(timer);
    if (signal instanceof AbortSignal) signal.removeEventListener('abort', interrupt);
  }
  if (typeof emit !== 'function') reject();
  emit(receipt);
  return receipt;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.once('SIGTERM', interrupt);
  process.once('SIGINT', interrupt);
  let receipt;
  try {
    if (process.argv.length !== 2) reject();
    // The trusted Swift launcher owns the explicit environment and its private
    // HOME/TMPDIR. The probe never reads credentials or adds inherited values
    // to native launch options; productionLauncher fixes that environment.
    receipt = await runHealthStdio({ signal: controller.signal, emit: value => { receipt = value; } });
  } catch {
    receipt = failed();
  } finally {
    process.removeListener('SIGTERM', interrupt);
    process.removeListener('SIGINT', interrupt);
  }
  process.stdout.write(JSON.stringify(receipt) + '\n');
  process.exitCode = receipt.type === 'healthy' ? 0 : 1;
}
