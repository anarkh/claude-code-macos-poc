// A fixed, text-only connectivity diagnostic. This never opens the App's
// project/tool execution gate and does not qualify the VM isolation boundary.
import http from 'node:http';
import { spawn } from 'node:child_process';
import { readFile, mkdir, rm, writeFile, access, realpath } from 'node:fs/promises';
import { constants } from 'node:fs';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import os from 'node:os';
import { createOwnedRunDirectory, waitForNativeProcessExit } from './owned-run-directory.mjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ProxyTransportError, proxyHttpsBufferRequest, validateNetworkPolicy } from '../network/proxy-transport.mjs';
import { DEFAULT_RUNTIME_PROFILE, RuntimeProfileError, profileEnvironment, validateRuntimeProfile } from '../runtime/profile.mjs';

export const SMOKE_SCHEMA = 'deepseek-text-smoke/v1';
export const SMOKE_ACK = 'DEEPSEEK_CLI_OK';
export const SMOKE_PROMPT = 'Reply with exactly DEEPSEEK_CLI_OK and nothing else.';
const SYSTEM_PROMPT = 'This is a fixed text-only connectivity test. Return the requested acknowledgement verbatim. Do not use tools.';
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const MODELS = new Set(['deepseek-flash[1m]', 'deepseek-flash']);
const UPSTREAM_URL = 'https://api.deepseek.com/anthropic/v1/messages';
const REQUEST_LIMIT = 3;
const BODY_LIMIT = 1_048_576;
const RESPONSE_LIMIT = 262_144;
const TOTAL_TIMEOUT_MS = 85_000; // Cleanup gets at most another four seconds.
const hash = value => createHash('sha256').update(value).digest('hex');
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

class SmokeFailure extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = code => { throw new SmokeFailure(code); };

function classifyCliDiagnostic(text) {
  // Match only known failure classes. Never return, persist, or interpolate
  // the diagnostic text (which is controlled by the native child).
  if (/sandbox-exec:[^\n]*(?:syntax|parse|invalid profile)/i.test(text)) return 'SANDBOX_PROFILE_REJECTED';
  if (/unknown option|unrecognized option|invalid argument/i.test(text)) return 'CLI_ARGUMENT_REJECTED';
  if (/managed[^\n]*policy[^\n]*(?:denied|blocked)|not allowed by[^\n]*managed/i.test(text)) return 'CLI_MANAGED_POLICY_REJECTED';
  if (/EACCES|EPERM|permission denied|operation not permitted/i.test(text)) return 'CLI_PERMISSION_DENIED';
  if (/ENOENT|no such file or directory/i.test(text)) return 'CLI_PATH_UNAVAILABLE';
  if (/unknown model|unsupported model|invalid model/i.test(text)) return 'CLI_MODEL_REJECTED';
  if (/not logged in|authentication required|invalid api key/i.test(text)) return 'CLI_LOCAL_AUTH_FAILED';
  return null;
}

function validateInput(input, testOnly = false) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || input.schema !== SMOKE_SCHEMA ||
      Object.keys(input).some(key => !['schema', 'apiKey', 'model', 'network', 'runtime'].includes(key))) fail('INVALID_INPUT');
  if (typeof input.apiKey !== 'string' || input.apiKey.length < 16 || input.apiKey.length > 512 ||
      /[\s\x00-\x1f\x7f]/.test(input.apiKey)) fail('INVALID_API_KEY');
  const model = input.model ?? 'deepseek-flash[1m]';
  if (!MODELS.has(model)) fail('MODEL_NOT_ALLOWED');
  const network = testOnly && input.network === undefined ? undefined : validateNetworkPolicy(input.network);
  const runtimeProfile = validateRuntimeProfile(testOnly && input.runtime === undefined ? DEFAULT_RUNTIME_PROFILE : input.runtime);
  return { apiKey: input.apiKey, model, network, runtimeProfile };
}

function tokenMatches(value, token) {
  if (typeof value !== 'string') return false;
  const supplied = Buffer.from(value);
  const expected = Buffer.from(token);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

function safeRequestShape(body, model) {
  const kind = value => value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
  const knownKeys = ['model', 'stream', 'max_tokens', 'messages', 'system', 'tools', 'tool_choice', 'thinking', 'metadata', 'temperature', 'top_p', 'stop_sequences', 'context_management', 'output_config'];
  const bodyObject = body !== null && typeof body === 'object' && !Array.isArray(body);
  const keys = bodyObject ? Object.keys(body) : [];
  const messages = Array.isArray(body?.messages) ? body.messages : [];
  return { body_kind: kind(body), known_keys: keys.filter(key => knownKeys.includes(key)).sort(),
    other_key_count: keys.filter(key => !knownKeys.includes(key)).length,
    model_kind: kind(body?.model), model_length: typeof body?.model === 'string' ? body.model.length : null,
    model_is_selector: body?.model === model, model_is_base: body?.model === model.replace('[1m]', ''),
    tools_kind: kind(body?.tools), tools_count: Array.isArray(body?.tools) ? body.tools.length : null,
    stream_kind: kind(body?.stream), stream_value: typeof body?.stream === 'boolean' ? body.stream : null,
    message_count: Array.isArray(body?.messages) ? messages.length : null,
    messages: messages.slice(0, 4).map(message => {
      const content = message?.content;
      const blocks = Array.isArray(content) ? content : typeof content === 'string' ? [{ type: 'text', text: content }] : [];
      return { role_kind: kind(message?.role), role_length: typeof message?.role === 'string' ? message.role.length : null,
        role_is_user: message?.role === 'user', role_is_assistant: message?.role === 'assistant',
        role_is_system: message?.role === 'system', role_is_developer: message?.role === 'developer',
        role_is_harness: message?.role === 'harness', role_is_tool_hints: message?.role === 'tool_hints',
        known_keys: message && typeof message === 'object' ? Object.keys(message).filter(key => ['role', 'type', 'content', 'cache_control'].includes(key)).sort() : [],
        type_is_system: message?.type === 'system', type_is_tool_hints: message?.type === 'tool_hints',
        content_kind: kind(content), block_count: blocks.length,
        blocks: blocks.slice(0, 6).map(block => {
          const text = block?.text;
          const promptIndex = typeof text === 'string' ? text.indexOf(SMOKE_PROMPT) : -1;
          return { kind: ['text', 'tool_use', 'tool_result', 'image', 'thinking', 'redacted_thinking'].includes(block?.type) ? block.type : 'other',
            text_kind: kind(text), text_length: typeof text === 'string' ? text.length : null,
            exact_prompt: text === SMOKE_PROMPT, contains_prompt: promptIndex >= 0,
            prefix_length: promptIndex >= 0 ? promptIndex : null,
            suffix_length: promptIndex >= 0 ? text.length - promptIndex - SMOKE_PROMPT.length : null,
            has_system_reminder_tag: typeof text === 'string' && text.includes('<system-reminder>') };
        }) };
    }) };
}

async function markNativeLiteralFacts(diagnostic, body, cliPath) {
  let binary;
  try { binary = await readFile(cliPath); }
  catch { diagnostic.native_literal_check = 'unavailable'; return; }
  diagnostic.native_literal_check = 'checked';
  diagnostic.messages.forEach((message, messageIndex) => {
    const originalContent = body.messages[messageIndex]?.content;
    const originalBlocks = Array.isArray(originalContent) ? originalContent : [{ text: originalContent }];
    message.blocks.forEach((block, blockIndex) => {
      const text = originalBlocks[blockIndex]?.text;
      block.matches_static_native_literal = typeof text === 'string' && text.length > 0 &&
        (binary.includes(Buffer.from(text)) || binary.includes(Buffer.from(JSON.stringify(text).slice(1, -1))));
    });
  });
}

function fixedProviderBody(body, model) {
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      ![model, model.replace('[1m]', '')].includes(body.model) ||
      (body.tools !== undefined && (!Array.isArray(body.tools) || body.tools.length !== 0)) ||
      !Array.isArray(body.messages) || body.messages.length < 1 || body.messages.length > 2 || body.messages[0]?.role !== 'user') fail('NON_FIXED_REQUEST');
  const content = body.messages[0].content;
  const text = typeof content === 'string' ? content :
    Array.isArray(content) && content.length === 1 && content[0]?.type === 'text' ? content[0].text : undefined;
  if (text !== SMOKE_PROMPT || typeof body.stream !== 'boolean') fail('NON_FIXED_REQUEST');
  if (body.messages.length === 2) {
    const envelope = body.messages[1];
    const blocks = envelope?.content;
    // CLI 2.1.295 appends a system/text runtime envelope even with a custom
    // systemPrompt and verbatimPrompts. Discard this bounded envelope entirely.
    // Additional user messages, assistant history and every tool block remain
    // outside this one-shot diagnostic contract.
    if (envelope?.role !== 'system' || Object.keys(envelope).some(key => !['role', 'content'].includes(key)) ||
        !Array.isArray(blocks) || blocks.length !== 1 || blocks[0]?.type !== 'text' ||
        Object.keys(blocks[0]).some(key => !['type', 'text', 'cache_control'].includes(key)) ||
        typeof blocks[0].text !== 'string' || blocks[0].text.length < 1 || blocks[0].text.length > 2048) fail('NON_FIXED_REQUEST');
  }
  // Rebuild the body to avoid sending CLI metadata, cache hints, or machine
  // paths. The long-context CLI selector is not a provider model ID.
  return { model: model.replace('[1m]', ''), max_tokens: 128, stream: body.stream,
    system: SYSTEM_PROMPT, messages: [{ role: 'user', content: SMOKE_PROMPT }],
    tools: [], thinking: { type: 'disabled' } };
}

function inspectProviderResponse(bytes, contentType) {
  const text = bytes.toString('utf8');
  let values;
  try {
    if (contentType.includes('text/event-stream')) {
      values = text.split(/\r?\n\r?\n/).flatMap(frame => {
        const data = frame.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('\n');
        return data && data !== '[DONE]' ? [JSON.parse(data)] : [];
      });
    } else values = [JSON.parse(text)];
  } catch { fail('INVALID_PROVIDER_RESPONSE'); }
  let output = '';
  let inputTokens = 0;
  let outputTokens = 0;
  const walk = value => {
    if (!value || typeof value !== 'object') return;
    if (value.type === 'tool_use' || value.type === 'tool_result' || value.type === 'input_json_delta') fail('PROVIDER_TOOL_RESPONSE');
    if (value.type === 'text' && typeof value.text === 'string') output += value.text;
    if (value.type === 'text_delta' && typeof value.text === 'string') output += value.text;
    if (value.usage && typeof value.usage === 'object') {
      const usage = value.usage;
      if (Number.isSafeInteger(usage.input_tokens) && usage.input_tokens >= 0) inputTokens = Math.max(inputTokens, usage.input_tokens);
      if (Number.isSafeInteger(usage.output_tokens) && usage.output_tokens >= 0) outputTokens = Math.max(outputTokens, usage.output_tokens);
    }
    for (const [key, child] of Object.entries(value)) if (key !== 'usage') {
      if (Array.isArray(child)) child.forEach(walk); else if (child && typeof child === 'object') walk(child);
    }
  };
  values.forEach(walk);
  if (output.trim() !== SMOKE_ACK) fail('PROVIDER_ACK_MISMATCH');
  if (outputTokens > 128) fail('PROVIDER_OUTPUT_LIMIT');
  return { input_tokens: inputTokens, output_tokens: outputTokens };
}

async function officialTransport({ body, apiKey, signal, network }) {
  const payload = Buffer.from(JSON.stringify(body));
  const response = await proxyHttpsBufferRequest({ url: UPSTREAM_URL, method: 'POST', signal, network, timeoutMs: 45000,
    headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json',
      'content-length': String(payload.length), 'anthropic-version': '2023-06-01' }, body: payload, maxResponseBytes: RESPONSE_LIMIT });
  return { statusCode: response.status, contentType: String(response.headers['content-type'] ?? ''), body: response.body };
}

export async function inspectInstalledNativeMetadata(testDependencies) {
  if (testDependencies !== undefined && (!testDependencies || testDependencies.testOnly !== true ||
      typeof testDependencies.readFile !== 'function' || typeof testDependencies.access !== 'function')) fail('INVALID_METADATA_TEST_DEPENDENCIES');
  const platform = testDependencies?.platform ?? process.platform;
  const architecture = testDependencies?.arch ?? process.arch;
  if (platform !== 'darwin' || architecture !== 'arm64') fail('MAC_ARM64_REQUIRED');
  const read = testDependencies?.readFile ?? readFile;
  const verifyAccess = testDependencies?.access ?? access;
  const cliPath = path.join(ROOT, 'node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude');
  try { await verifyAccess('/usr/bin/sandbox-exec', constants.X_OK); } catch { fail('SANDBOX_UNAVAILABLE'); }
  let packageInfo;
  let sdkPackageInfo;
  try {
    packageInfo = JSON.parse(await read(path.join(path.dirname(cliPath), 'package.json'), 'utf8'));
    sdkPackageInfo = JSON.parse(await read(path.join(ROOT, 'node_modules/@anthropic-ai/claude-agent-sdk/package.json'), 'utf8'));
  } catch { fail('CLI_PACKAGE_METADATA_FAILED'); }
  if (packageInfo.name !== '@anthropic-ai/claude-agent-sdk-darwin-arm64' ||
      sdkPackageInfo.name !== '@anthropic-ai/claude-agent-sdk') fail('CLI_PACKAGE_IDENTITY_MISMATCH');
  if (packageInfo.version !== '0.3.295' || sdkPackageInfo.version !== '0.3.295') fail('SDK_VERSION_MISMATCH');
  let cliSha256;
  try { await verifyAccess(cliPath, constants.X_OK); cliSha256 = hash(await read(cliPath)); }
  catch { fail('CLI_BINARY_UNAVAILABLE'); }
  return { cliPath, cliSha256, sdkVersion: '0.3.295', expectedCliVersion: '2.1.295' };
}

async function productionRuntime() {
  const metadata = await inspectInstalledNativeMetadata();
  let query;
  try { ({ query } = await import('@anthropic-ai/claude-agent-sdk')); } catch { fail('SDK_IMPORT_FAILED'); }
  if (typeof query !== 'function') fail('SDK_IMPORT_FAILED');
  return { query, spawn, transport: officialTransport, ...metadata };
}

function fixtureRuntime(dependencies) {
  // Dependency injection is exclusively for local fake tests. The executable
  // entrypoint has no argument or environment switch to select this path.
  if (!dependencies || dependencies.testOnly !== true || typeof dependencies.query !== 'function' ||
      typeof dependencies.spawn !== 'function' || typeof dependencies.transport !== 'function' ||
      typeof dependencies.cliPath !== 'string' || !/^[a-f0-9]{64}$/.test(dependencies.cliSha256)) fail('INVALID_TEST_DEPENDENCIES');
  return dependencies;
}

export async function runDeepSeekTextSmoke(input, testDependencies) {
  const result = { schema: SMOKE_SCHEMA, ok: false, code: 'NOT_STARTED', model: null, ack: null,
    usage: { input_tokens: 0, output_tokens: 0 }, no_tools: false, request_count: 0,
    request_diagnostic: null,
    system_envelope_discarded: false,
    init_diagnostic: null,
    cli: { sha256: null, exit_code: null, signal: null },
    cleanup: { temporary_removed: false, proxy_closed: false } };
  let temporary;
  let ownedRun;
  let server;
  let child;
  let childExited = false;
  let query;
  let exitPromise;
  let initVerified = false;
  let toolAttempted = false;
  let proxyFailure;
  let timer;
  let runtime;
  let interrupted = false;
  let phaseCode = 'INPUT_VALIDATION_FAILED';
  let cliDiagnosticCode;
  let unexpectedFailure = false;
  let localRequestIndex = 0;
  const abort = new AbortController();
  const sockets = new Set();
  const interrupt = () => {
    interrupted = true;
    proxyFailure ??= 'PROCESS_INTERRUPTED';
    abort.abort();
    try { query?.close(); } catch { proxyFailure = 'QUERY_CLEANUP_FAILED'; }
    // Only the detached process group created by this invocation is ours.
    if (child?.pid) {
      try { process.kill(-child.pid, 'SIGTERM'); }
      catch (error) { if (error.code !== 'ESRCH') proxyFailure = 'CLI_CLEANUP_FAILED'; }
    }
    for (const socket of sockets) socket.destroy();
  };
  // Unit tests do not install process-wide signal listeners.
  if (testDependencies === undefined) {
    process.once('SIGTERM', interrupt);
    process.once('SIGINT', interrupt);
  }
  timer = setTimeout(() => { proxyFailure ??= 'TOTAL_TIMEOUT'; abort.abort();
    try { query?.close(); } catch { proxyFailure = 'QUERY_CLEANUP_FAILED'; }
  }, TOTAL_TIMEOUT_MS);
  try {
    const configuration = validateInput(input, testDependencies?.testOnly === true);
    result.model = configuration.model;
    phaseCode = 'RUNTIME_INITIALIZATION_FAILED';
    runtime = testDependencies === undefined ? await productionRuntime() : fixtureRuntime(testDependencies);
    result.cli.sha256 = runtime.cliSha256;
    phaseCode = 'TEMPORARY_SETUP_FAILED';
    ownedRun = await createOwnedRunDirectory('text-smoke');
    temporary = ownedRun.directory;
    const home = path.join(temporary, 'home');
    const cwd = path.join(temporary, 'empty-workspace');
    const temporaryFiles = path.join(temporary, 'tmp');
    await Promise.all([mkdir(path.join(home, '.claude'), { recursive: true }), mkdir(cwd), mkdir(temporaryFiles)]);
    const localToken = randomBytes(32).toString('hex');
    phaseCode = 'LOCAL_PROXY_START_FAILED';
    server = http.createServer(async (request, response) => {
      const rejectRequest = (code, status = 400) => {
        proxyFailure ??= code;
        // A rejected fixed diagnostic is terminal. Do not let the CLI spend
        // its retry window repeating a request that this contract forbids.
        response.once('finish', () => {
          abort.abort();
          try { query?.close(); } catch { proxyFailure = 'QUERY_CLEANUP_FAILED'; }
        });
        response.writeHead(status, { 'content-type': 'application/json', connection: 'close' });
        response.end('{"type":"error","error":{"type":"invalid_request_error","message":"Fixed text diagnostic rejected request"}}');
      };
      try {
        if (request.socket.remoteAddress !== '127.0.0.1' ||
            !(tokenMatches(request.headers['x-api-key'], localToken) || tokenMatches(request.headers.authorization, `Bearer ${localToken}`))) {
          rejectRequest('LOCAL_AUTH_REJECTED', 403); return;
        }
        const route = new URL(request.url ?? '/', 'http://127.0.0.1');
        if (request.method !== 'POST' || route.pathname !== '/v1/messages' ||
            [...route.searchParams.entries()].some(([key, value]) => key !== 'beta' || value !== 'true')) {
          rejectRequest('LOCAL_ROUTE_REJECTED', 404); return;
        }
        localRequestIndex++;
        if (result.request_count >= REQUEST_LIMIT) { rejectRequest('REQUEST_LIMIT', 429); return; }
        const chunks = [];
        let size = 0;
        for await (const chunk of request) {
          size += chunk.length;
          if (size > BODY_LIMIT) { rejectRequest('REQUEST_BODY_LIMIT', 413); return; }
          chunks.push(chunk);
        }
        let body;
        try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { fail('INVALID_REQUEST_JSON'); }
        let providerBody;
        try { providerBody = fixedProviderBody(body, configuration.model); }
        catch (error) {
          if (error instanceof SmokeFailure && error.code === 'NON_FIXED_REQUEST' && result.request_diagnostic === null) {
            result.request_diagnostic = { request_index: localRequestIndex, ...safeRequestShape(body, configuration.model) };
            await markNativeLiteralFacts(result.request_diagnostic, body, runtime.cliPath);
          }
          throw error;
        }
        result.system_envelope_discarded ||= body.messages.length === 2;
        result.request_count++;
        const provider = await runtime.transport({ body: providerBody, apiKey: configuration.apiKey, signal: abort.signal, network: configuration.network });
        if (provider.statusCode !== 200) {
          fail(Number.isInteger(provider.statusCode) && provider.statusCode >= 300 && provider.statusCode < 400 ? 'PROVIDER_REDIRECT_REJECTED' :
            Number.isInteger(provider.statusCode) && provider.statusCode >= 400 && provider.statusCode <= 599 ? `PROVIDER_HTTP_${provider.statusCode}` : 'PROVIDER_INVALID_HTTP_STATUS');
        }
        if (!Buffer.isBuffer(provider.body) || provider.body.length > RESPONSE_LIMIT || typeof provider.contentType !== 'string') fail('INVALID_PROVIDER_RESPONSE');
        const usage = inspectProviderResponse(provider.body, provider.contentType);
        result.usage.input_tokens += usage.input_tokens;
        result.usage.output_tokens += usage.output_tokens;
        response.writeHead(200, { 'content-type': provider.contentType.includes('text/event-stream') ? 'text/event-stream' : 'application/json', connection: 'close' });
        response.end(provider.body);
      } catch (error) { rejectRequest(error instanceof SmokeFailure || error instanceof ProxyTransportError ? error.code : abort.signal.aborted ? 'TOTAL_TIMEOUT' : 'PROVIDER_CONNECTION_FAILED', 502); }
    });
    server.requestTimeout = 10_000;
    server.headersTimeout = 10_000;
    server.maxHeadersCount = 32;
    server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const port = server.address().port;
    phaseCode = 'SANDBOX_PROFILE_SETUP_FAILED';
    // Machine-managed policy remains readable; it can still reject this test.
    const nativeRuntimeDirectory = await realpath(path.join(ROOT, 'node_modules'));
    const hostHome = await realpath(os.homedir());
    const profile = `(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip "localhost:${port}"))\n(deny file-write*)\n(allow file-write* (subpath ${JSON.stringify(temporary)}) (literal "/dev/null") (literal "/dev/tty"))\n(deny file-read* (subpath ${JSON.stringify(hostHome)}) (subpath "/Library/Keychains"))\n(allow file-read* (subpath ${JSON.stringify(nativeRuntimeDirectory)}) (subpath ${JSON.stringify(temporary)}))\n(deny process-exec (literal "/usr/bin/security"))\n`;
    const profilePath = path.join(temporary, 'cli.sb');
    await writeFile(profilePath, profile, { mode: 0o600, flag: 'wx' });
    const environment = { PATH: '/usr/bin:/bin:/usr/sbin', HOME: home, TMPDIR: temporaryFiles,
      CLAUDE_CODE_TMPDIR: temporaryFiles, CLAUDE_CONFIG_DIR: path.join(home, '.claude'), ...profileEnvironment(configuration.runtimeProfile),
      ANTHROPIC_API_KEY: localToken, ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
      ANTHROPIC_MODEL: configuration.model, CLAUDE_CODE_SUBAGENT_MODEL: 'deepseek-flash',
      ANTHROPIC_DEFAULT_OPUS_MODEL: configuration.model, ANTHROPIC_DEFAULT_SONNET_MODEL: configuration.model,
      ANTHROPIC_DEFAULT_HAIKU_MODEL: 'deepseek-flash',
      CLAUDE_CODE_ENTRYPOINT: 'sdk-ts', CLAUDE_AGENT_SDK_VERSION: '0.3.295', CLAUDE_CODE_SDK_READS_SESSION_STATE: '1',
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1',
      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1', CLAUDE_CODE_DISABLE_CRON: '1', CLAUDE_CODE_DISABLE_AGENT_VIEW: '1',
      CLAUDE_CODE_SKIP_BASH_ENVIRONMENT_SNAPSHOT: '1', CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1' };
    if (abort.signal.aborted) fail(proxyFailure ?? 'TOTAL_TIMEOUT');
    phaseCode = 'SDK_QUERY_START_FAILED';
    query = runtime.query({ prompt: SMOKE_PROMPT, options: { cwd, env: environment,
      pathToClaudeCodeExecutable: runtime.cliPath, model: configuration.model,
      tools: [], allowedTools: [], agents: {}, mcpServers: {}, strictMcpConfig: true, plugins: [], skills: [],
      settingSources: [], settings: { disableAllHooks: true, enabledPlugins: {
        'cc-plugin-agents-md@builtin': false, 'cc-plugin-plugin-authoring@builtin': false,
      } }, persistSession: false, maxTurns: 1, thinking: { type: 'disabled' },
      extraArgs: { 'disable-slash-commands': null },
      systemPrompt: SYSTEM_PROMPT, verbatimPrompts: true, permissionMode: 'default', permissionPrompts: 'none',
      allowDangerouslySkipPermissions: false, abortController: abort,
      canUseTool: async () => { toolAttempted = true; return { behavior: 'deny', message: 'Text diagnostic has no tools' }; },
      spawnClaudeCodeProcess: options => {
        if (child || options.command !== runtime.cliPath || options.cwd !== cwd || !options.args.includes('--setting-sources=')) fail('CLI_LAUNCH_CONTRACT');
        ownedRun.markNativeLaunchPending();
        child = runtime.spawn('/usr/bin/sandbox-exec', ['-f', profilePath, runtime.cliPath, ...options.args],
          { cwd, env: environment, stdio: ['pipe', 'pipe', 'pipe'], detached: true, signal: options.signal });
        exitPromise = new Promise(resolve => {
          child.once('exit', (code, signal) => { childExited = true; result.cli.exit_code = code; result.cli.signal = signal; resolve(); });
          child.once('error', error => {
            // Node emits AbortError before the subsequent exit event. Expected
            // cancellation must not resolve the exit receipt prematurely.
            if (error.code !== 'ABORT_ERR' || !abort.signal.aborted) proxyFailure ??= 'CLI_PROCESS_ERROR';
            if (!child.pid) resolve();
          });
        });
        if (child.pid) ownedRun.registerNativePID(child.pid);
        let diagnosticTail = '';
        child.stderr.on('data', chunk => {
          diagnosticTail = (diagnosticTail + chunk.toString('utf8')).slice(-4096);
          cliDiagnosticCode ??= classifyCliDiagnostic(diagnosticTail);
        });
        return child;
      }, stderr: () => {} } });
    let finished;
    phaseCode = 'SDK_ITERATION_FAILED';
    for await (const event of query) {
      if (event.type === 'system' && event.subtype === 'init') {
        result.init_diagnostic = {
          version_matches: event.claude_code_version === '2.1.295',
          reported_version: typeof event.claude_code_version === 'string' && /^\d{1,5}\.\d{1,5}\.\d{1,5}$/.test(event.claude_code_version) ? event.claude_code_version : null,
          cwd_matches: event.cwd === cwd, permission_mode_default: event.permissionMode === 'default',
          tools_array: Array.isArray(event.tools), tools_count: Array.isArray(event.tools) ? event.tools.length : null,
          mcp_array: Array.isArray(event.mcp_servers), mcp_count: Array.isArray(event.mcp_servers) ? event.mcp_servers.length : null,
          skills_array: Array.isArray(event.skills), skills_count: Array.isArray(event.skills) ? event.skills.length : null,
          plugins_array: Array.isArray(event.plugins), plugins_count: Array.isArray(event.plugins) ? event.plugins.length : null,
          plugin_metadata: Array.isArray(event.plugins) ? event.plugins.slice(0, 8).map(plugin => {
            const pluginPath = typeof plugin.path === 'string' ? plugin.path : '';
            return { id: typeof plugin.name === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9@./_-]{0,127}$/.test(plugin.name) ? plugin.name : null,
              source: ['cc-plugin-agents-md@builtin', 'cc-plugin-plugin-authoring@builtin'].includes(plugin.source) ? 'builtin' :
                ['builtin', 'sdk', 'user', 'project', 'local', 'dynamic', 'managed', 'enterprise', 'claudeai', 'plugin', 'inline', 'skills-dir', 'synced'].includes(plugin.source) ? plugin.source : 'other',
              path_has_builtin_tag: pluginPath.includes('@builtin'),
              origin: pluginPath === 'builtin' || plugin.source === 'builtin' || pluginPath.startsWith('/$bunfs/') || pluginPath.includes('@builtin') ? 'bundled_native' : pluginPath.startsWith(nativeRuntimeDirectory + '/') ? 'bundled_sdk' :
                pluginPath.startsWith('/Library/Application Support/ClaudeCode/') ? 'system_managed' :
                  pluginPath.startsWith(temporary + '/') ? 'temporary' : pluginPath.startsWith(hostHome + '/') ? 'host_home' : 'other' };
          }) : [],
        };
        initVerified = event.claude_code_version === '2.1.295' && event.cwd === cwd && event.permissionMode === 'default' &&
          Array.isArray(event.tools) && event.tools.length === 0 && Array.isArray(event.mcp_servers) && event.mcp_servers.length === 0 &&
          Array.isArray(event.skills) && event.skills.length === 0 && Array.isArray(event.plugins) && event.plugins.length === 0;
      }
      const blocks = event.message?.content;
      if (Array.isArray(blocks) && blocks.some(block => block.type === 'tool_use' || block.type === 'tool_result')) toolAttempted = true;
      if (event.type === 'result') { finished = event; break; }
    }
    result.no_tools = initVerified && !toolAttempted;
    if (proxyFailure) fail(proxyFailure);
    if (!child) fail('CLI_NOT_STARTED');
    if (!result.no_tools) fail('NO_TOOLS_CONTRACT');
    if (!finished || finished.subtype !== 'success' || finished.is_error || finished.result?.trim() !== SMOKE_ACK ||
        finished.num_turns !== 1 || result.request_count < 1) fail('CLI_ACK_MISMATCH');
    result.ok = true;
    result.code = 'PASSED_TEXT_ONLY';
    result.ack = SMOKE_ACK;
  } catch (error) {
    unexpectedFailure = !(error instanceof SmokeFailure || error instanceof ProxyTransportError || error instanceof RuntimeProfileError);
    result.code = error instanceof SmokeFailure || error instanceof ProxyTransportError || error instanceof RuntimeProfileError ? error.code : proxyFailure ?? cliDiagnosticCode ?? phaseCode;
  } finally {
    clearTimeout(timer);
    try { query?.close(); } catch { result.ok = false; result.code = 'QUERY_CLEANUP_FAILED'; }
    abort.abort();
    for (const socket of sockets) socket.destroy();
    if (server) {
      await new Promise(resolve => server.close(() => resolve()));
      result.cleanup.proxy_closed = !server.listening;
    } else result.cleanup.proxy_closed = true;
    if (exitPromise) {
      await Promise.race([exitPromise, pause(interrupted ? 400 : 2500)]);
      if (result.cli.exit_code === null && result.cli.signal === null && child?.pid) {
        try { process.kill(-child.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') { result.ok = false; result.code = 'CLI_CLEANUP_FAILED'; } }
        await Promise.race([exitPromise, pause(interrupted ? 400 : 1000)]);
      }
    }
    if (child && (result.cli.exit_code !== 0 || result.cli.signal !== null)) {
      result.ok = false;
      if (result.code === 'PASSED_TEXT_ONLY') result.code = 'CLI_EXIT_FAILED';
      else if (unexpectedFailure && !proxyFailure) result.code = cliDiagnosticCode ??
        (!initVerified ? 'CLI_INITIALIZATION_FAILED' : phaseCode);
    }
    if (runtime && testDependencies === undefined) {
      try {
        if (hash(await readFile(runtime.cliPath)) !== result.cli.sha256) { result.ok = false; result.code = 'CLI_CHANGED'; }
      } catch { result.ok = false; result.code = 'CLI_READBACK_FAILED'; }
    }
    if (temporary) {
      try {
        if (child?.pid && (!childExited || !(await waitForNativeProcessExit(child.pid)))) throw new Error('OWNED_NATIVE_STILL_RUNNING');
        await rm(temporary, { recursive: true, force: true }); result.cleanup.temporary_removed = true; }
      catch { result.ok = false; result.code = 'TEMPORARY_CLEANUP_FAILED'; }
    } else result.cleanup.temporary_removed = true;
    if (!result.ok) result.ack = null;
    if (testDependencies === undefined) {
      process.removeListener('SIGTERM', interrupt);
      process.removeListener('SIGINT', interrupt);
    }
  }
  return result;
}

async function readStdin() {
  let size = 0;
  const chunks = [];
  const timer = setTimeout(() => process.stdin.destroy(new SmokeFailure('INPUT_TIMEOUT')), 10_000);
  try {
    for await (const chunk of process.stdin) {
      size += chunk.length;
      if (size > 16_384) fail('INPUT_LIMIT');
      chunks.push(chunk);
    }
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { fail('INVALID_INPUT_JSON'); }
  } finally { clearTimeout(timer); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let reply;
  try { reply = await runDeepSeekTextSmoke(await readStdin()); }
  catch (error) { reply = { schema: SMOKE_SCHEMA, ok: false, code: error instanceof SmokeFailure || error instanceof ProxyTransportError || error instanceof RuntimeProfileError ? error.code : 'INVALID_INPUT',
    model: null, ack: null, usage: { input_tokens: 0, output_tokens: 0 }, no_tools: false, request_count: 0,
    cli: { sha256: null, exit_code: null, signal: null }, cleanup: { temporary_removed: true, proxy_closed: true } }; }
  process.stdout.write(`${JSON.stringify(reply)}\n`);
}
