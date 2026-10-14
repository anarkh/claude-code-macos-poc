// Installed and executed only inside the disposable, networkless Linux VM.
// The executable has no fixture flag, external transport or credential input.
import http from 'node:http';
import { spawn } from 'node:child_process';
import { createReadStream, constants } from 'node:fs';
import { access, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm } from 'node:fs/promises';
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SYSTEM_PROMPT = 'You are an assistant in a text-only conversation. Respond to the user. No tools are available; do not emit tool calls.';
export const LIMITS = Object.freeze({ input: 1_048_576, request: 524_288, response: 2_097_152,
  text: 262_144, frame: 262_144, chunk: 65_536, requests: 3, timeoutMs: 120_000 });
const INSTALL = '/opt/claude-text/sdk';
const HOME = '/home/claude';
const SDK_VERSION = '0.3.295';
const CLI_VERSION = '2.1.295';
const CLI_SHA256 = 'cfb9dc1332fb6f92a683f835823e91b3179a803398ca7852cd2381a3cb1dea3b';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MODELS = new Set(['deepseek-flash[1m]', 'deepseek-flash']);
const SUBSCRIPTION_MODELS = new Set(['sonnet', 'opus', 'haiku']);
const LOCALES = Object.freeze({ ja: 'ja_JP.UTF-8', en: 'en_US.UTF-8', zh: 'zh_CN.UTF-8' });
// Keep the App's existing spelling contract across Foundation and Node ICU.
const TIME_ZONES = new Set(['UTC', ...Intl.supportedValuesOf('timeZone'),
  'Africa/Asmara', 'America/Argentina/Buenos_Aires', 'America/Argentina/Catamarca',
  'America/Argentina/Cordoba', 'America/Argentina/Jujuy', 'America/Argentina/Mendoza',
  'America/Atikokan', 'America/Indiana/Indianapolis', 'America/Kentucky/Louisville',
  'America/Montreal', 'America/Nipigon', 'America/Nuuk', 'America/Pangnirtung',
  'America/Rainy_River', 'America/Santa_Isabel', 'America/Shiprock', 'America/Thunder_Bay',
  'America/Yellowknife', 'Antarctica/South_Pole', 'Asia/Choibalsan', 'Asia/Chongqing',
  'Asia/Harbin', 'Asia/Ho_Chi_Minh', 'Asia/Kashgar', 'Asia/Kathmandu', 'Asia/Yangon',
  'Atlantic/Faroe', 'Australia/Currie', 'Europe/Kyiv', 'Europe/Uzhgorod',
  'Europe/Zaporozhye', 'Pacific/Chuuk', 'Pacific/Johnston', 'Pacific/Kanton', 'Pacific/Pohnpei']);
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

class RuntimeFailure extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = code => { throw new RuntimeFailure(code); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exactKeys = (value, keys) => object(value) && Object.keys(value).length === keys.length &&
  Object.keys(value).every(key => keys.includes(key));
const safeCode = (error, fallback) => error instanceof RuntimeFailure ? error.code : fallback;

export function validateStart(value) {
  if (!exactKeys(value, ['kind', 'provider', 'model', 'prompt', 'runtime']) || value.kind !== 'start') fail('INVALID_START');
  if (!['deepseek-api', 'claude-subscription'].includes(value.provider)) fail('PROVIDER_NOT_ALLOWED');
  if (!(value.provider === 'deepseek-api' ? MODELS : SUBSCRIPTION_MODELS).has(value.model)) fail('MODEL_NOT_ALLOWED');
  if (typeof value.prompt !== 'string' || !value.prompt.trim() || Buffer.byteLength(value.prompt) > LIMITS.input) fail('INVALID_PROMPT');
  const profile = value.runtime;
  if (!exactKeys(profile, ['schema', 'timeZone', 'language']) || profile.schema !== 'app-runtime-profile/v1' ||
      !Object.hasOwn(LOCALES, profile.language) || typeof profile.timeZone !== 'string' || profile.timeZone.length > 128 ||
      !/^(?:UTC|[A-Za-z][A-Za-z0-9._+-]*(?:\/[A-Za-z0-9._+-]+)+)$/.test(profile.timeZone) || !TIME_ZONES.has(profile.timeZone)) fail('RUNTIME_PROFILE_INVALID');
  try { new Intl.DateTimeFormat('en-US', { timeZone: profile.timeZone }).format(0); }
  catch { fail('RUNTIME_PROFILE_INVALID'); }
  return { provider: value.provider, model: value.model, prompt: value.prompt,
    runtime: { schema: profile.schema, timeZone: profile.timeZone, language: profile.language } };
}

function profileEnvironment(profile) {
  return { TZ: profile.timeZone, LANG: LOCALES[profile.language], LC_ALL: LOCALES[profile.language],
    LC_MESSAGES: LOCALES[profile.language] };
}

async function checkedDirectory(directory, uid, empty = false) {
  const metadata = await lstat(directory);
  if (!metadata.isDirectory() || metadata.isSymbolicLink() || await realpath(directory) !== directory ||
      uid !== undefined && metadata.uid !== uid || empty && (await readdir(directory)).length !== 0) fail('GUEST_PATH_REJECTED');
}

async function productionRuntime(configuration, signal) {
  if (process.platform !== 'linux' || process.arch !== 'arm64' || typeof process.getuid !== 'function' || process.getuid() <= 0) fail('GUEST_PLATFORM_REQUIRED');
  if (path.dirname(fileURLToPath(import.meta.url)) !== INSTALL || process.cwd() !== `${HOME}/work` ||
      process.env.HOME !== HOME || process.env.TMPDIR !== `${HOME}/tmp` ||
      process.env.CLAUDE_CONFIG_DIR !== `${HOME}/.claude`) fail('GUEST_PATH_REJECTED');
  await checkedDirectory(INSTALL);
  for (const directory of [HOME, `${HOME}/tmp`, `${HOME}/.claude`]) await checkedDirectory(directory, process.getuid());
  await checkedDirectory(`${HOME}/work`, process.getuid(), true);
  // SDK module initialization inherits this environment, never a host process
  // environment. No user settings, credential or executable override survives.
  for (const name of Object.keys(process.env)) delete process.env[name];
  Object.assign(process.env, { PATH: '/usr/bin:/bin', HOME, USER: 'claude', LOGNAME: 'claude',
    TMPDIR: `${HOME}/tmp`, CLAUDE_CONFIG_DIR: `${HOME}/.claude`, ...profileEnvironment(configuration.runtime) });
  const cliPath = `${INSTALL}/node_modules/@anthropic-ai/claude-agent-sdk-linux-arm64/claude`;
  let sdk, native;
  try {
    sdk = JSON.parse(await readFile(`${INSTALL}/node_modules/@anthropic-ai/claude-agent-sdk/package.json`, 'utf8'));
    native = JSON.parse(await readFile(`${path.dirname(cliPath)}/package.json`, 'utf8'));
  } catch { fail('PACKAGE_METADATA_REJECTED'); }
  if (sdk.name !== '@anthropic-ai/claude-agent-sdk' || native.name !== '@anthropic-ai/claude-agent-sdk-linux-arm64' ||
      sdk.version !== SDK_VERSION || native.version !== SDK_VERSION || sdk.claudeCodeVersion !== CLI_VERSION ||
      !native.os?.includes('linux') || !native.cpu?.includes('arm64')) fail('SDK_VERSION_MISMATCH');
  const cliStat = await lstat(cliPath);
  if (!cliStat.isFile() || cliStat.isSymbolicLink() || await realpath(cliPath) !== cliPath) fail('CLI_BINARY_REJECTED');
  await access(cliPath, constants.X_OK);
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(cliPath, { signal })) hash.update(chunk);
  if (hash.digest('hex') !== CLI_SHA256) fail('CLI_VERSION_MISMATCH');
  if (signal.aborted) fail('CHAT_CANCELLED');
  let query;
  try { ({ query } = await import('@anthropic-ai/claude-agent-sdk')); }
  catch { fail('SDK_IMPORT_FAILED'); }
  if (typeof query !== 'function') fail('SDK_IMPORT_FAILED');
  if (signal.aborted) fail('CHAT_CANCELLED');
  const directory = await mkdtemp(`${HOME}/tmp/claude-text-`);
  const cwd = path.join(directory, 'workspace');
  const tmp = path.join(directory, 'tmp');
  try {
    await mkdir(cwd, { mode: 0o700 }); await mkdir(tmp, { mode: 0o700 });
    if (signal.aborted) fail('CHAT_CANCELLED');
  }
  catch { await rm(directory, { recursive: true, force: true }); fail('GUEST_WORKSPACE_FAILED'); }
  return { query, spawn, cliPath, cwd, directory, env: { ...process.env, TMPDIR: tmp, CLAUDE_CODE_TMPDIR: tmp } };
}

function fixtureRuntime(dependencies, configuration) {
  // This path is reachable only through an explicit function argument in local
  // tests, never through stdin, argv or an environment flag in the executable.
  if (!dependencies || dependencies.testOnly !== true || typeof dependencies.query !== 'function' ||
      typeof dependencies.spawn !== 'function' || typeof dependencies.cliPath !== 'string' ||
      typeof dependencies.cwd !== 'string' || !object(dependencies.env) ||
      dependencies.timeoutMs !== undefined && (!Number.isInteger(dependencies.timeoutMs) || dependencies.timeoutMs < 20 || dependencies.timeoutMs > 1000)) fail('INVALID_TEST_DEPENDENCIES');
  return { ...dependencies, env: { ...dependencies.env, ...profileEnvironment(configuration.runtime) } };
}

function tokenMatches(actual, expected) {
  if (typeof actual !== 'string') return false;
  const left = Buffer.from(actual), right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}

const subscriptionModel = (model, alias) => typeof model === 'string' &&
  new RegExp(`^claude-${alias}-[0-9][a-z0-9-]{0,80}$`).test(model);

function nativeInit(event, configuration, cwd) {
  if (event.claude_code_version !== CLI_VERSION || event.cwd !== cwd || event.permissionMode !== 'default' ||
      !Array.isArray(event.tools) || event.tools.length || !Array.isArray(event.mcp_servers) || event.mcp_servers.length ||
      !Array.isArray(event.skills) || event.skills.length || !Array.isArray(event.plugins) || event.plugins.length ||
      typeof event.session_id !== 'string' || !UUID.test(event.session_id) ||
      (configuration.provider === 'claude-subscription' ? event.apiKeySource !== 'none' || !subscriptionModel(event.model, configuration.model) :
        event.apiKeySource !== 'ANTHROPIC_API_KEY' || ![configuration.model, configuration.model.replace('[1m]', '')].includes(event.model))) fail('NO_TOOLS_CONTRACT');
  return { kind: 'native_init', model: event.model, session_id: event.session_id, no_tools: true };
}

function providerHeaders(headers, configuration, initialization) {
  if (configuration.provider === 'deepseek-api') return {};
  const beta = headers['anthropic-beta'];
  if (headers['anthropic-version'] !== '2023-06-01' || headers['x-app'] !== 'cli' ||
      headers['user-agent'] !== `claude-cli/${CLI_VERSION} (external, sdk-ts, agent-sdk/${SDK_VERSION})` ||
      typeof beta !== 'string' || beta.length > 4096 || !/^[a-z0-9,-]+$/.test(beta) ||
      !beta.split(',').includes('oauth-2025-04-20') || !beta.split(',').includes('claude-code-20250219') ||
      headers['x-claude-code-session-id'] !== initialization.session_id ||
      headers['anthropic-dangerous-direct-browser-access'] !== 'true') fail('SUBSCRIPTION_PROTOCOL_REJECTED');
  return Object.fromEntries(['anthropic-version', 'anthropic-beta', 'x-app', 'user-agent',
    'x-claude-code-session-id', 'anthropic-dangerous-direct-browser-access'].map(key => [key, headers[key]]));
}

function providerBody(body, configuration, initialization) {
  if (!object(body) || body.stream !== true || body.model !== initialization.model &&
      !(configuration.provider === 'deepseek-api' && [configuration.model, configuration.model.replace('[1m]', '')].includes(body.model)) ||
      body.tools !== undefined && (!Array.isArray(body.tools) || body.tools.length) ||
      !Array.isArray(body.messages) || body.messages.length < 1 || body.messages.length > 2 || body.messages[0]?.role !== 'user') fail('CLI_REQUEST_REJECTED');
  const content = body.messages[0].content;
  const text = typeof content === 'string' ? content : Array.isArray(content) && content.length === 1 &&
    content[0]?.type === 'text' ? content[0].text : undefined;
  if (text !== configuration.prompt) fail('CLI_REQUEST_REJECTED');
  if (body.messages.length === 2) {
    const envelope = body.messages[1], blocks = envelope?.content;
    const keys = configuration.provider === 'claude-subscription' ? ['role', 'content', 'output_config'] : ['role', 'content'];
    if (!object(envelope) || envelope.role !== 'system' || Object.keys(envelope).some(key => !keys.includes(key)) ||
        !Array.isArray(blocks) || blocks.length !== 1 || !object(blocks[0]) || blocks[0].type !== 'text' ||
        Object.keys(blocks[0]).some(key => !['type', 'text', 'cache_control'].includes(key)) ||
        typeof blocks[0].text !== 'string' || !blocks[0].text.length || blocks[0].text.length > 2048 ||
        envelope.output_config !== undefined && (!exactKeys(envelope.output_config, ['effort']) ||
          !['low', 'medium', 'high', 'max'].includes(envelope.output_config.effort))) fail('CLI_REQUEST_REJECTED');
  }
  let system = SYSTEM_PROMPT, metadata;
  if (configuration.provider === 'claude-subscription') {
    if (!Array.isArray(body.system) || body.system.length !== 3 || body.system.some(block => !object(block) || block.type !== 'text' ||
        Object.keys(block).some(key => !['type', 'text', 'cache_control'].includes(key))) ||
        typeof body.system[0].text !== 'string' || !/^x-anthropic-billing-header: cc_version=2\.1\.295\.[a-z0-9]{3}; cc_entrypoint=sdk-ts;$/.test(body.system[0].text) ||
        body.system[1].text !== "You are a Claude agent, built on Anthropic's Claude Agent SDK." || body.system[2].text !== SYSTEM_PROMPT ||
        !exactKeys(body.metadata, ['user_id']) || typeof body.metadata.user_id !== 'string' || body.metadata.user_id.length > 512) fail('SUBSCRIPTION_PROTOCOL_REJECTED');
    let identity;
    try { identity = JSON.parse(body.metadata.user_id); } catch { fail('SUBSCRIPTION_PROTOCOL_REJECTED'); }
    if (!exactKeys(identity, ['device_id', 'account_uuid', 'session_id']) || typeof identity.device_id !== 'string' ||
        !/^[a-f0-9]{64}$/.test(identity.device_id) || !(identity.account_uuid === '' || UUID.test(identity.account_uuid)) ||
        identity.session_id !== initialization.session_id) fail('SUBSCRIPTION_PROTOCOL_REJECTED');
    metadata = { user_id: JSON.stringify({ device_id: identity.device_id, account_uuid: identity.account_uuid, session_id: identity.session_id }) };
    system = body.system.map(block => ({ type: 'text', text: block.text }));
  }
  return { model: configuration.provider === 'claude-subscription' ? initialization.model : configuration.model.replace('[1m]', ''),
    stream: true, max_tokens: 4096, thinking: { type: 'disabled' }, tools: [], system,
    ...(metadata ? { metadata } : {}), messages: [{ role: 'user', content: configuration.prompt }] };
}

class SseReader {
  constructor(onText, onFrame) {
    this.onText = onText; this.onFrame = onFrame; this.decoder = new TextDecoder('utf-8', { fatal: true });
    this.pending = ''; this.bytes = 0; this.frames = 0; this.started = false; this.stopped = false; this.blocks = new Set();
  }
  async frame(frame) {
    if (++this.frames > 8192 || Buffer.byteLength(frame) > LIMITS.frame) fail('PROVIDER_RESPONSE_LIMIT');
    const data = frame.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('\n');
    if (!data) return;
    let value;
    try { value = JSON.parse(data); } catch { fail('PROVIDER_PROTOCOL_REJECTED'); }
    if (!object(value)) fail('PROVIDER_PROTOCOL_REJECTED');
    if (value.type === 'error') fail('PROVIDER_STREAM_ERROR');
    if (this.stopped && value.type !== 'ping') fail('PROVIDER_PROTOCOL_REJECTED');
    if (value.type === 'message_start') {
      if (this.started || value.message?.type !== 'message' || value.message?.role !== 'assistant' ||
          !Array.isArray(value.message.content) || value.message.content.length) fail('PROVIDER_PROTOCOL_REJECTED');
      this.started = true;
    } else if (value.type === 'content_block_start') {
      if (!this.started || !Number.isSafeInteger(value.index) || value.index < 0 || this.blocks.has(value.index) ||
          value.content_block?.type !== 'text' || typeof value.content_block.text !== 'string') fail(value.content_block?.type === 'tool_use' ? 'PROVIDER_TOOL_RESPONSE' : 'PROVIDER_PROTOCOL_REJECTED');
      this.blocks.add(value.index); this.onText(value.content_block.text);
    } else if (value.type === 'content_block_delta') {
      if (!this.blocks.has(value.index) || value.delta?.type !== 'text_delta' || typeof value.delta.text !== 'string') fail(value.delta?.type === 'input_json_delta' ? 'PROVIDER_TOOL_RESPONSE' : 'PROVIDER_PROTOCOL_REJECTED');
      this.onText(value.delta.text);
    } else if (value.type === 'content_block_stop') {
      if (!this.blocks.delete(value.index)) fail('PROVIDER_PROTOCOL_REJECTED');
    } else if (value.type === 'message_delta') {
      if (!this.started || value.delta?.stop_reason === 'tool_use') fail(value.delta?.stop_reason === 'tool_use' ? 'PROVIDER_TOOL_RESPONSE' : 'PROVIDER_PROTOCOL_REJECTED');
      if (Number.isSafeInteger(value.usage?.output_tokens) && value.usage.output_tokens > 4096) fail('PROVIDER_OUTPUT_LIMIT');
    } else if (value.type === 'message_stop') {
      if (!this.started || this.blocks.size) fail('PROVIDER_PROTOCOL_REJECTED');
      this.stopped = true;
    } else if (value.type !== 'ping') fail('PROVIDER_PROTOCOL_REJECTED');
    await this.onFrame(`${frame}\n\n`);
  }
  async feed(bytes, final = false) {
    this.bytes += bytes.length;
    if (this.bytes > LIMITS.response) fail('PROVIDER_RESPONSE_LIMIT');
    try { this.pending += this.decoder.decode(bytes, { stream: !final }); } catch { fail('PROVIDER_PROTOCOL_REJECTED'); }
    for (;;) {
      const separator = /\r?\n\r?\n/.exec(this.pending);
      if (!separator) break;
      const frame = this.pending.slice(0, separator.index);
      this.pending = this.pending.slice(separator.index + separator[0].length);
      await this.frame(frame);
    }
    if (Buffer.byteLength(this.pending) > LIMITS.frame) fail('PROVIDER_RESPONSE_LIMIT');
    if (final) {
      if (this.pending.trim()) await this.frame(this.pending);
      this.pending = '';
      if (!this.started || !this.stopped) fail('PROVIDER_STREAM_INCOMPLETE');
    }
  }
}

function processGroupExists(pid) {
  for (const target of [pid, -pid]) {
    try { process.kill(target, 0); return true; }
    catch (error) { if (error.code !== 'ESRCH') fail('CLI_CLEANUP_FAILED'); }
  }
  return false;
}

// Owns both streams for one turn. Its only injectable dependencies are local
// fake SDK/process objects; production always uses the pinned Linux package.
export async function runGuestTextRuntime({ input, output }, dependencies) {
  if (!input?.on || !output?.write) fail('INVALID_STREAMS');
  if (dependencies !== undefined && dependencies?.testOnly !== true) fail('INVALID_TEST_DEPENDENCIES');
  let configuration, runtime, child, query, server, initialization, active, timer, exitPromise;
  let childExited = false, exitCode = null, exitSignal = null, requestCount = 0, assistantText = '', providerText = '', outputBytes = 0;
  let failure, completed = false, settled = false, queryClosed = false, pending = Buffer.alloc(0), messageCount = 0;
  const abort = new AbortController(), sockets = new Set();
  let resolveDone, resolveNative;
  const done = new Promise(resolve => { resolveDone = resolve; });
  const nativeReady = new Promise(resolve => { resolveNative = resolve; });
  async function abortable(promise) {
    if (abort.signal.aborted) fail(failure ?? 'CHAT_CANCELLED');
    let onAbort;
    const interrupted = new Promise((resolve, reject) => {
      onAbort = () => reject(new RuntimeFailure(failure ?? 'CHAT_CANCELLED'));
      abort.signal.addEventListener('abort', onAbort, { once: true });
    });
    try { return await Promise.race([promise, interrupted]); }
    finally { abort.signal.removeEventListener('abort', onAbort); }
  }
  const send = event => new Promise((resolve, reject) => {
    const bytes = `${JSON.stringify(event)}\n`;
    if (Buffer.byteLength(bytes) > LIMITS.input) return reject(new RuntimeFailure('OUTPUT_FRAME_LIMIT'));
    try { output.write(bytes, error => error ? reject(new RuntimeFailure('TRANSPORT_CLOSED')) : resolve()); }
    catch { reject(new RuntimeFailure('TRANSPORT_CLOSED')); }
  });
  function signalGroup(signal) {
    if (!child?.pid) return;
    try { process.kill(-child.pid, signal); }
    catch (error) { if (error.code !== 'ESRCH') failure = 'CLI_CLEANUP_FAILED'; }
  }
  function closeQuery() {
    if (!query || queryClosed) return;
    queryClosed = true;
    try { query.close(); } catch { failure = 'QUERY_CLEANUP_FAILED'; }
  }
  function terminate(code) {
    failure ??= code;
    abort.abort(); resolveNative(false); active?.reject(new RuntimeFailure(failure)); active = undefined;
    signalGroup('SIGTERM'); closeQuery();
    for (const socket of sockets) socket.destroy();
  }
  async function cleanup() {
    clearTimeout(timer); resolveNative(false); closeQuery(); abort.abort();
    active?.reject(new RuntimeFailure(failure ?? 'CHAT_CANCELLED')); active = undefined;
    for (const socket of sockets) socket.destroy();
    if (server) await new Promise(resolve => server.close(resolve));
    if (exitPromise) {
      await Promise.race([exitPromise, delay(failure ? 400 : 2500)]);
      if (!childExited) { signalGroup('SIGTERM'); await Promise.race([exitPromise, delay(400)]); }
      if (!childExited) { signalGroup('SIGKILL'); await Promise.race([exitPromise, delay(1000)]); }
      if (!childExited) failure = 'CLI_CLEANUP_FAILED';
    }
    if (child?.pid && dependencies === undefined) {
      const deadline = performance.now() + 1000;
      try {
        while (processGroupExists(child.pid) && performance.now() < deadline) { signalGroup('SIGKILL'); await delay(25); }
        if (processGroupExists(child.pid)) failure = 'CLI_CLEANUP_FAILED';
      } catch { failure = 'CLI_CLEANUP_FAILED'; }
    }
    if (completed && (exitCode !== 0 || exitSignal !== null)) failure ??= 'CLI_EXIT_FAILED';
    if (runtime?.directory && (!child?.pid || childExited) && failure !== 'CLI_CLEANUP_FAILED') {
      try { await rm(runtime.directory, { recursive: true, force: true }); }
      catch { failure = 'GUEST_CLEANUP_FAILED'; }
    }
  }
  async function finish() {
    if (settled) return;
    settled = true;
    await cleanup();
    const event = completed && !failure ? { kind: 'result', text: providerText, ok: true } :
      { kind: 'result', text: '', ok: false, error_code: failure ?? 'CHAT_FAILED' };
    try { await send(event); } catch { event.ok = false; event.text = ''; event.error_code = 'TRANSPORT_CLOSED'; }
    input.removeListener('data', onData); input.removeListener('end', onEnd); input.removeListener('error', onInputError);
    output.removeListener('error', onOutputError); input.pause();
    if (dependencies === undefined) { process.removeListener('SIGTERM', onInterrupt); process.removeListener('SIGINT', onInterrupt); }
    resolveDone(event);
  }
  async function turn() {
    let phase = 'RUNTIME_INITIALIZATION_FAILED';
    try {
      runtime = dependencies === undefined ? await productionRuntime(configuration, abort.signal) : fixtureRuntime(dependencies, configuration);
      if (abort.signal.aborted) fail(failure ?? 'CHAT_CANCELLED');
      const token = configuration.provider === 'claude-subscription' ? `sk-ant-oat01-${randomBytes(32).toString('base64url')}` : randomBytes(32).toString('hex');
      phase = 'LOCAL_GATEWAY_FAILED';
      server = http.createServer(async (request, response) => {
        try {
          const authenticated = configuration.provider === 'claude-subscription' ? request.headers['x-api-key'] === undefined &&
            tokenMatches(request.headers.authorization, `Bearer ${token}`) : tokenMatches(request.headers['x-api-key'], token) || tokenMatches(request.headers.authorization, `Bearer ${token}`);
          if (request.socket.remoteAddress !== '127.0.0.1' || !authenticated) fail('LOCAL_AUTH_REJECTED');
          const route = new URL(request.url ?? '/', 'http://127.0.0.1');
          if (request.method !== 'POST' || route.pathname !== '/v1/messages' ||
              [...route.searchParams.entries()].some(([key, value]) => key !== 'beta' || value !== 'true')) fail('LOCAL_ROUTE_REJECTED');
          if (active || requestCount >= LIMITS.requests) fail(active ? 'CONCURRENT_PROVIDER_REQUEST' : 'REQUEST_LIMIT');
          let size = 0;
          const chunks = [];
          for await (const chunk of request) {
            size += chunk.length;
            if (size > LIMITS.request) fail('REQUEST_BODY_LIMIT');
            chunks.push(chunk);
          }
          let local;
          try { local = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); }
          catch { fail('INVALID_REQUEST_JSON'); }
          if (!(await nativeReady) || abort.signal.aborted) fail(failure ?? 'NO_TOOLS_CONTRACT');
          const headers = providerHeaders(request.headers, configuration, initialization);
          const body = providerBody(local, configuration, initialization);
          if (Buffer.byteLength(JSON.stringify(body)) > LIMITS.request) fail('REQUEST_BODY_LIMIT');
          const id = randomUUID();
          let resolveResponse, rejectResponse;
          const responseDone = new Promise((resolve, reject) => { resolveResponse = resolve; rejectResponse = reject; });
          const parser = new SseReader(text => {
            outputBytes += Buffer.byteLength(text);
            if (outputBytes > LIMITS.text) fail('PROVIDER_OUTPUT_LIMIT');
            providerText += text;
          }, frame => new Promise((resolve, reject) => {
            response.write(frame, error => error ? reject(new RuntimeFailure('LOCAL_GATEWAY_CLOSED')) : resolve());
          }));
          active = { id, response, parser, receivedHeaders: false, resolve: resolveResponse, reject: rejectResponse };
          requestCount++;
          await Promise.all([send({ kind: 'provider_request', id, headers, body }), responseDone]);
          response.end();
        } catch (error) {
          if (!response.headersSent && !response.destroyed) {
            response.writeHead(502, { 'content-type': 'application/json', connection: 'close' });
            response.end('{"type":"error","error":{"type":"invalid_request_error","message":"Text runtime rejected request"}}');
          } else response.destroy();
          terminate(safeCode(error, abort.signal.aborted ? 'CHAT_CANCELLED' : 'LOCAL_GATEWAY_FAILED'));
        }
      });
      server.requestTimeout = 10_000; server.headersTimeout = 10_000; server.maxHeadersCount = 32;
      server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
      const env = { ...runtime.env, ANTHROPIC_BASE_URL: `http://127.0.0.1:${server.address().port}`,
        ...(configuration.provider === 'claude-subscription' ? { CLAUDE_CODE_OAUTH_TOKEN: token } : {
          ANTHROPIC_API_KEY: token, ANTHROPIC_MODEL: configuration.model, ANTHROPIC_DEFAULT_OPUS_MODEL: configuration.model,
          ANTHROPIC_DEFAULT_SONNET_MODEL: configuration.model, ANTHROPIC_DEFAULT_HAIKU_MODEL: 'deepseek-flash', CLAUDE_CODE_SUBAGENT_MODEL: 'deepseek-flash' }),
        CLAUDE_CODE_ENTRYPOINT: 'sdk-ts', CLAUDE_AGENT_SDK_VERSION: SDK_VERSION, CLAUDE_CODE_SDK_READS_SESSION_STATE: '1',
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1',
        CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1', CLAUDE_CODE_DISABLE_CRON: '1', CLAUDE_CODE_DISABLE_AGENT_VIEW: '1',
        CLAUDE_CODE_SKIP_BASH_ENVIRONMENT_SNAPSHOT: '1', CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1' };
      phase = 'SDK_QUERY_FAILED';
      query = runtime.query({ prompt: configuration.prompt, options: {
        cwd: runtime.cwd, env, pathToClaudeCodeExecutable: runtime.cliPath, model: configuration.model,
        tools: [], allowedTools: [], agents: {}, mcpServers: {}, strictMcpConfig: true, plugins: [], skills: [],
        settingSources: [], settings: { disableAllHooks: true, enabledPlugins: { 'cc-plugin-agents-md@builtin': false, 'cc-plugin-plugin-authoring@builtin': false } },
        extraArgs: { 'disable-slash-commands': null }, persistSession: false, maxTurns: 1, thinking: { type: 'disabled' },
        systemPrompt: SYSTEM_PROMPT, verbatimPrompts: true, permissionMode: 'default', permissionPrompts: 'none',
        allowDangerouslySkipPermissions: false, includePartialMessages: true, abortController: abort,
        canUseTool: async () => { terminate('NO_TOOLS_CONTRACT'); return { behavior: 'deny', message: 'Text runtime has no tools' }; },
        stderr: () => {}, spawnClaudeCodeProcess: options => {
          if (child || options.command !== runtime.cliPath || options.cwd !== runtime.cwd || !Array.isArray(options.args) ||
              !options.args.includes('--setting-sources=')) fail('CLI_LAUNCH_CONTRACT');
          child = runtime.spawn(runtime.cliPath, options.args, { cwd: runtime.cwd, env,
            stdio: ['pipe', 'pipe', 'pipe'], detached: true, signal: options.signal });
          exitPromise = new Promise(resolve => {
            child.once('exit', (code, signal) => { childExited = true; exitCode = code; exitSignal = signal; resolve(); });
            child.once('error', error => { if (error.code !== 'ABORT_ERR' || !abort.signal.aborted) failure ??= 'CLI_PROCESS_ERROR'; if (!child.pid) { childExited = true; resolve(); } });
          });
          child.stderr?.resume();
          return child;
        } } });
      let result;
      phase = 'SDK_ITERATION_FAILED';
      const iterator = query[Symbol.asyncIterator]();
      for (;;) {
        const next = await abortable(iterator.next());
        if (next.done) break;
        const event = next.value;
        if (abort.signal.aborted) fail(failure ?? 'CHAT_CANCELLED');
        if (event.type === 'system' && event.subtype === 'init') {
          if (initialization) fail('DUPLICATE_NATIVE_INIT');
          initialization = nativeInit(event, configuration, runtime.cwd);
          await send(initialization); resolveNative(true);
        }
        const blocks = event.message?.content;
        if (Array.isArray(blocks)) {
          if (blocks.some(block => block?.type === 'tool_use' || block?.type === 'tool_result')) fail('NO_TOOLS_CONTRACT');
          if (event.type === 'assistant') {
            if (blocks.some(block => block?.type !== 'text' || typeof block.text !== 'string')) fail('CLI_TEXT_MISMATCH');
            assistantText += blocks.map(block => block.text).join('');
            if (Buffer.byteLength(assistantText) > LIMITS.text) fail('PROVIDER_OUTPUT_LIMIT');
          }
        }
        if (event.type === 'result') { result = event; break; }
      }
      if (failure) fail(failure);
      if (!child || !initialization || active || !requestCount) fail('CLI_NOT_STARTED');
      if (!result || result.subtype !== 'success' || result.is_error || result.num_turns !== 1 || typeof result.result !== 'string' ||
          !providerText.trim() || result.result.trim() !== providerText.trim() || assistantText !== providerText) fail('CLI_TEXT_MISMATCH');
      completed = true;
    } catch (error) { terminate(safeCode(error, phase)); }
    await finish();
  }
  async function message(value) {
    if (++messageCount > 8192 || !object(value)) fail('INPUT_PROTOCOL_REJECTED');
    if (value.kind === 'cancel') {
      if (!exactKeys(value, ['kind'])) fail('INPUT_PROTOCOL_REJECTED');
      terminate('CHAT_CANCELLED'); if (!configuration) await finish(); return;
    }
    if (value.kind === 'start') {
      if (configuration) fail('DUPLICATE_START');
      configuration = validateStart(value);
      timer = setTimeout(() => terminate('TOTAL_TIMEOUT'), dependencies?.timeoutMs ?? LIMITS.timeoutMs);
      void turn(); return;
    }
    if (!configuration || !active || value.id !== active.id) fail('PROVIDER_RESPONSE_UNEXPECTED');
    if (value.kind === 'provider_response') {
      if (!exactKeys(value, ['kind', 'id', 'status', 'content_type']) || active.receivedHeaders ||
          !Number.isInteger(value.status) || value.status < 100 || value.status > 599 ||
          typeof value.content_type !== 'string' || value.content_type.length > 128 || /[\r\n]/.test(value.content_type)) fail('PROVIDER_PROTOCOL_REJECTED');
      if (value.status !== 200) fail(value.status >= 300 && value.status < 400 ? 'PROVIDER_REDIRECT_REJECTED' :
        value.status >= 400 ? `${configuration.provider === 'claude-subscription' ? 'SUBSCRIPTION' : 'PROVIDER'}_HTTP_${value.status}` : 'PROVIDER_INVALID_HTTP_STATUS');
      if (!/^text\/event-stream(?:\s*;.*)?$/i.test(value.content_type)) fail('PROVIDER_PROTOCOL_REJECTED');
      active.receivedHeaders = true;
      active.response.writeHead(200, { 'content-type': 'text/event-stream', connection: 'close' }); return;
    }
    if (!active.receivedHeaders) fail('PROVIDER_PROTOCOL_REJECTED');
    if (value.kind === 'provider_chunk') {
      if (!exactKeys(value, ['kind', 'id', 'data']) || typeof value.data !== 'string' || !value.data.length ||
          value.data.length > Math.ceil(LIMITS.chunk / 3) * 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.data)) fail('PROVIDER_PROTOCOL_REJECTED');
      const bytes = Buffer.from(value.data, 'base64');
      if (bytes.length > LIMITS.chunk || bytes.toString('base64') !== value.data) fail('PROVIDER_PROTOCOL_REJECTED');
      await active.parser.feed(bytes); return;
    }
    if (value.kind === 'provider_end') {
      if (!exactKeys(value, ['kind', 'id'])) fail('PROVIDER_PROTOCOL_REJECTED');
      await active.parser.feed(Buffer.alloc(0), true);
      const ended = active; active = undefined; ended.resolve(); return;
    }
    fail('INPUT_PROTOCOL_REJECTED');
  }
  let inputWork = Promise.resolve();
  function onData(chunk) {
    input.pause();
    inputWork = inputWork.then(async () => {
      if (settled) return;
      pending = Buffer.concat([pending, Buffer.from(chunk)]);
      for (;;) {
        const newline = pending.indexOf(10);
        if (newline < 0) break;
        if (newline > LIMITS.input) fail('INPUT_LIMIT');
        const line = pending.subarray(0, newline); pending = pending.subarray(newline + 1);
        if (!line.length) fail('INPUT_PROTOCOL_REJECTED');
        let value;
        try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line)); }
        catch { fail('INVALID_INPUT_JSON'); }
        await message(value);
        if (settled) return;
      }
      if (pending.length > LIMITS.input) fail('INPUT_LIMIT');
      if (!settled) input.resume();
    }).catch(async error => { terminate(safeCode(error, 'INPUT_PROTOCOL_REJECTED')); if (!configuration) await finish(); });
  }
  function onEnd() { inputWork.then(async () => { if (!settled) { terminate(pending.length ? 'INPUT_PROTOCOL_REJECTED' : 'TRANSPORT_CLOSED'); if (!configuration) await finish(); } }); }
  function onInputError() { terminate('TRANSPORT_CLOSED'); if (!configuration) void finish(); }
  function onOutputError() { terminate('TRANSPORT_CLOSED'); if (!configuration) void finish(); }
  function onInterrupt() { terminate('CHAT_CANCELLED'); if (!configuration) void finish(); }
  input.on('data', onData); input.once('end', onEnd); input.once('error', onInputError); output.once('error', onOutputError);
  if (dependencies === undefined) { process.once('SIGTERM', onInterrupt); process.once('SIGINT', onInterrupt); }
  try { await send({ kind: 'ready' }); } catch { terminate('TRANSPORT_CLOSED'); if (!configuration) await finish(); }
  return done;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 2) {
    process.stdout.write('{"kind":"result","text":"","ok":false,"error_code":"INVALID_ARGUMENTS"}\n');
    process.exitCode = 1;
  } else {
    const result = await runGuestTextRuntime({ input: process.stdin, output: process.stdout });
    process.exitCode = result.ok ? 0 : 1;
    process.stdin.destroy();
  }
}
