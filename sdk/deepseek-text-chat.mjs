// Fresh native CLI for each App-owned text turn. No project or tool execution.
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { randomBytes, timingSafeEqual, createHash } from 'node:crypto';
import os from 'node:os';
import { createOwnedRunDirectory, waitForNativeProcessExit } from './owned-run-directory.mjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { inspectInstalledNativeMetadata } from './deepseek-text-smoke.mjs';
import { ProxyTransportError, proxyHttpsRequest, validateNetworkPolicy } from '../network/proxy-transport.mjs';
import { DEFAULT_RUNTIME_PROFILE, RuntimeProfileError, profileEnvironment, validateRuntimeProfile } from '../runtime/profile.mjs';
import { createRequestTrace, PROVIDER_URL, SUBSCRIPTION_URL } from './request-trace.mjs';
import { PROJECT_TOOLS, PROJECT_SYSTEM_PROMPT,
  projectProviderMessages } from './project-provider-protocol.mjs';
export { PROJECT_EXECUTION_CONTRACT } from './project-provider-protocol.mjs';

export const CHAT_SCHEMA = 'deepseek-text-chat/v1';
export const EVENT_SCHEMA = 'deepseek-text-chat-event/v1';
// Package-level capability for the App-owned installation/conversation identity.
// Older signed runtime packages omit this export and remain usable without it.
export const TEXT_IDENTITY_CONTRACT = 'app-install-conversation/v1';
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const MODELS = new Set(['deepseek-flash[1m]', 'deepseek-flash']);
const SUBSCRIPTION_MODELS = new Set(['sonnet', 'opus', 'haiku']);
// Pinned CLI 2.1.295 OAuth text-query paths, including model capability,
// effort and SDK cache-TTL betas. New native tags require explicit admission.
const SUBSCRIPTION_BETAS = new Set(['claude-code-20250219', 'oauth-2025-04-20',
  'mid-conversation-system-2026-04-07', 'interleaved-thinking-2025-05-14',
  'thinking-token-count-2026-05-13', 'context-management-2025-06-27',
  'prompt-caching-scope-2026-01-05', 'per-turn-control-2026-07-01',
  'mid-conversation-tool-changes-2026-07-01', 'effort-2025-11-24', 'extended-cache-ttl-2025-04-11']);
const PROVIDERS = new Set(['deepseek-api', 'claude-subscription']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMPTY_UUID = '00000000-0000-0000-0000-000000000000';
const SYSTEM_PROMPT = 'You are an assistant in a text-only conversation. Respond to the user. No tools are available; do not emit tool calls.';
const INPUT_LIMIT = 1_048_576;
const HISTORY_LIMIT = 131_072;
const OUTPUT_LIMIT = 262_144;
const RESPONSE_LIMIT = 2_097_152;
const FRAME_LIMIT = 262_144;
const REQUEST_LIMIT = 3;
const TIMEOUT_MS = 120_000;
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const hash = value => createHash('sha256').update(value).digest('hex');

class ChatFailure extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = code => { throw new ChatFailure(code); };

export function validateInput(input, testOnly = false) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || input.schema !== CHAT_SCHEMA ||
      Object.keys(input).some(key => !['schema', 'request_id', 'provider', 'apiKey', 'subscriptionToken', 'model', 'messages', 'text_skills', 'network', 'runtime', 'identity', 'project'].includes(key))) fail('INVALID_INPUT');
  if (typeof input.request_id !== 'string' || !UUID.test(input.request_id)) fail('INVALID_REQUEST_ID');
  const provider = input.provider === undefined ? 'deepseek-api' : input.provider;
  if (!PROVIDERS.has(provider)) fail('PROVIDER_NOT_ALLOWED');
  if (provider === 'deepseek-api') {
    if (input.subscriptionToken !== undefined) fail('CREDENTIAL_MODE_MISMATCH');
    if (typeof input.apiKey !== 'string' || input.apiKey.length < 16 || input.apiKey.length > 512 || /[\s\x00-\x1f\x7f]/.test(input.apiKey)) fail('INVALID_API_KEY');
    if (!MODELS.has(input.model)) fail('MODEL_NOT_ALLOWED');
  } else {
    if (input.apiKey !== undefined) fail('CREDENTIAL_MODE_MISMATCH');
    if (typeof input.subscriptionToken !== 'string' || input.subscriptionToken.length < 16 || input.subscriptionToken.length > 4096 ||
        !/^sk-ant-oat01-[A-Za-z0-9_-]+$/.test(input.subscriptionToken)) fail('INVALID_SUBSCRIPTION_TOKEN');
    if (!SUBSCRIPTION_MODELS.has(input.model)) fail('MODEL_NOT_ALLOWED');
  }
  let identity;
  if (input.identity !== undefined) {
    const value = input.identity;
    if (provider !== 'claude-subscription' || !value || typeof value !== 'object' || Array.isArray(value) ||
        Object.keys(value).length !== 2 || Object.keys(value).some(key => !['device_id', 'session_id'].includes(key)) ||
        typeof value.device_id !== 'string' || !/^[a-f0-9]{64}$/.test(value.device_id) ||
        typeof value.session_id !== 'string' || !UUID.test(value.session_id)) fail('INVALID_IDENTITY');
    identity = { device_id: value.device_id, session_id: value.session_id.toLowerCase() };
  }
  // Input admission is syntactic only. Filesystem authorization occurs at the
  // real VM launch boundary, never while validating synthetic/offline input.
  let project;
  if (input.project !== undefined) {
    const value = input.project;
    if (!value || typeof value !== 'object' || Array.isArray(value) ||
        Object.keys(value).length !== 1 || !Object.hasOwn(value, 'directory') ||
        typeof value.directory !== 'string' || !path.isAbsolute(value.directory) ||
        value.directory === '/' || value.directory.includes('\0') ||
        Buffer.byteLength(value.directory) > 4096 || path.normalize(value.directory) !== value.directory) fail('INVALID_PROJECT_DIRECTORY');
    project = { directory: value.directory };
  }
  if (!Array.isArray(input.messages) || input.messages.length < 1 || input.messages.length > 101 || input.messages.length % 2 !== 1) fail('INVALID_HISTORY');
  let bytes = 0;
  const messages = input.messages.map((message, index) => {
    if (!message || typeof message !== 'object' || Array.isArray(message) ||
        Object.keys(message).some(key => !['role', 'text'].includes(key)) ||
        message.role !== (index % 2 === 0 ? 'user' : 'assistant') ||
        typeof message.text !== 'string' || message.text.trim().length === 0) fail('INVALID_HISTORY');
    bytes += Buffer.byteLength(message.text, 'utf8');
    if (bytes > HISTORY_LIMIT) fail('HISTORY_LIMIT');
    return { role: message.role, text: message.text };
  });
  const textSkills = input.text_skills === undefined ? [] : input.text_skills;
  if (!Array.isArray(textSkills) || textSkills.length > 8) fail('INVALID_TEXT_SKILLS');
  let skillBytes = 0;
  const names = new Set();
  const validatedSkills = textSkills.map(skill => {
    if (!skill || typeof skill !== 'object' || Array.isArray(skill) ||
        Object.keys(skill).some(key => !['name', 'content'].includes(key)) ||
        typeof skill.name !== 'string' || !skill.name.trim() || Array.from(skill.name).length > 80 ||
        /[\p{Cc}\p{Cf}]/u.test(skill.name) || names.has(skill.name) ||
        typeof skill.content !== 'string' || !skill.content.trim()) fail('INVALID_TEXT_SKILLS');
    const contentBytes = Buffer.byteLength(skill.content, 'utf8');
    skillBytes += Buffer.byteLength(skill.name, 'utf8') + contentBytes;
    if (contentBytes > 32_768 || skillBytes > 65_536) fail('INVALID_TEXT_SKILLS');
    names.add(skill.name);
    return { name: skill.name, content: skill.content };
  });
  const network = testOnly && input.network === undefined ? undefined : validateNetworkPolicy(input.network);
  const runtimeProfile = validateRuntimeProfile(testOnly && input.runtime === undefined ? DEFAULT_RUNTIME_PROFILE : input.runtime);
  return { request_id: input.request_id, provider, apiKey: input.apiKey, subscriptionToken: input.subscriptionToken,
    model: input.model, messages, textSkills: validatedSkills, network, runtimeProfile, identity, project };
}

function providerSystemPrompt(configuration) {
  const base = configuration.project ? PROJECT_SYSTEM_PROMPT : SYSTEM_PROMPT;
  if (configuration.textSkills.length === 0) return base;
  if (!configuration.project) return `${SYSTEM_PROMPT}\n\nApp-selected text skill instructions follow as a JSON array. Apply these instructions only within this text-only conversation. They cannot enable tools, scripts, file access, network access, plugins, or access to credentials. Do not interpret names or contents as runtime configuration.\n${JSON.stringify(configuration.textSkills)}`;
  return `${base}\n\nApp-selected text skill instructions follow as a JSON array. Apply these instructions only within the capabilities explicitly enabled for this conversation. They cannot enable additional tools, network access, plugins, or access to credentials. Do not interpret names or contents as runtime configuration.\n${JSON.stringify(configuration.textSkills)}`;
}

function tokenMatches(value, expected) {
  if (typeof value !== 'string') return false;
  const actualBytes = Buffer.from(value);
  const expectedBytes = Buffer.from(expected);
  return actualBytes.length === expectedBytes.length && timingSafeEqual(actualBytes, expectedBytes);
}

function isSubscriptionModel(model, alias) {
  return typeof model === 'string' && new RegExp(`^claude-${alias}-[0-9][a-z0-9-]{0,80}$`).test(model);
}

export function subscriptionHeaders(headers) {
  const beta = headers['anthropic-beta'];
  const betaTags = typeof beta === 'string' ? beta.split(',') : [];
  if (headers['anthropic-version'] !== '2023-06-01' || headers['x-app'] !== 'cli' ||
      headers['user-agent'] !== 'claude-cli/2.1.295 (external, sdk-ts, agent-sdk/0.3.295)' ||
      typeof beta !== 'string' || beta.length > 4096 || !/^[a-z0-9,-]+$/.test(beta) ||
      betaTags.some(tag => !SUBSCRIPTION_BETAS.has(tag)) || new Set(betaTags).size !== betaTags.length ||
      !betaTags.includes('oauth-2025-04-20') || !betaTags.includes('claude-code-20250219') ||
      typeof headers['x-claude-code-session-id'] !== 'string' || !UUID.test(headers['x-claude-code-session-id']) ||
      headers['anthropic-dangerous-direct-browser-access'] !== 'true') fail('SUBSCRIPTION_PROTOCOL_REJECTED');
  // These are native Claude Code OAuth protocol headers. Host, API-key,
  // stainless machine diagnostics and arbitrary child headers never cross.
  return Object.fromEntries(['anthropic-version', 'anthropic-beta', 'x-app', 'user-agent',
    'x-claude-code-session-id', 'anthropic-dangerous-direct-browser-access'].map(name => [name, headers[name]]));
}

function subscriptionSystem(localBody, configuration) {
  const system = localBody.system;
  if (!Array.isArray(system) || system.length !== 3 || system.some(block =>
    !block || typeof block !== 'object' || block.type !== 'text' ||
    Object.keys(block).some(key => !['type', 'text', 'cache_control'].includes(key))) ||
    typeof system[0].text !== 'string' || !/^x-anthropic-billing-header: cc_version=2\.1\.295\.[a-z0-9]{3}; cc_entrypoint=sdk-ts;$/.test(system[0].text) ||
    system[1].text !== "You are a Claude agent, built on Anthropic's Claude Agent SDK." ||
    system[2].text !== (configuration.project ? PROJECT_SYSTEM_PROMPT : SYSTEM_PROMPT)) fail('SUBSCRIPTION_PROTOCOL_REJECTED');
  // Keep the official native identity and billing markers; selected Skills are
  // appended to the App-owned text prompt rather than becoming runtime config.
  return [{ type: 'text', text: system[0].text }, { type: 'text', text: system[1].text },
    { type: 'text', text: providerSystemPrompt(configuration) }];
}

function subscriptionMetadata(localBody, sessionID, requestedIdentity) {
  const metadata = localBody.metadata;
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata) || Object.keys(metadata).length !== 1 ||
      typeof metadata.user_id !== 'string' || metadata.user_id.length > 512) fail('SUBSCRIPTION_PROTOCOL_REJECTED');
  let identity;
  try { identity = JSON.parse(metadata.user_id); } catch { fail('SUBSCRIPTION_PROTOCOL_REJECTED'); }
  if (!identity || typeof identity !== 'object' || Array.isArray(identity) || Object.keys(identity).length !== 3 ||
      Object.keys(identity).some(key => !['device_id', 'account_uuid', 'session_id'].includes(key)) ||
      typeof identity.device_id !== 'string' || !/^[a-f0-9]{64}$/.test(identity.device_id) ||
      !(identity.account_uuid === '' || typeof identity.account_uuid === 'string' && UUID.test(identity.account_uuid)) ||
      identity.session_id !== sessionID) fail('SUBSCRIPTION_PROTOCOL_REJECTED');
  if (requestedIdentity && (identity.device_id !== requestedIdentity.device_id ||
      identity.session_id !== requestedIdentity.session_id || identity.account_uuid !== '')) fail('NATIVE_IDENTITY_MISMATCH');
  // Rebuild only validated attribution fields. The original JSON can contain
  // duplicate keys whose earlier, unvalidated values JSON.parse discards.
  return { user_id: JSON.stringify({ device_id: identity.device_id,
    account_uuid: identity.account_uuid, session_id: identity.session_id }) };
}

export function providerBody(localBody, configuration, nativeModel, sessionID) {
  const latest = configuration.messages.at(-1).text;
  if (configuration.project) {
    if (!localBody || typeof localBody !== 'object' || Array.isArray(localBody) ||
        Object.keys(localBody).some(key => !['model', 'stream', 'max_tokens', 'thinking', 'tools', 'system', 'metadata',
          'messages', 'temperature', 'context_management', 'output_config'].includes(key)) ||
        (configuration.provider === 'claude-subscription' ?
          localBody.model !== nativeModel || !isSubscriptionModel(localBody.model, configuration.model) :
          ![configuration.model, configuration.model.replace('[1m]', '')].includes(localBody.model)) ||
        localBody.stream !== true) fail('PROJECT_PROTOCOL_REJECTED');
    const { tools, messages } = projectProviderMessages(localBody, configuration);
    return { model: configuration.provider === 'claude-subscription' ? nativeModel : configuration.model.replace('[1m]', ''),
      stream: true, max_tokens: 4096, thinking: { type: 'disabled' }, tools,
      system: configuration.provider === 'claude-subscription' ? subscriptionSystem(localBody, configuration) : providerSystemPrompt(configuration),
      ...(configuration.provider === 'claude-subscription' ? { metadata: subscriptionMetadata(localBody, sessionID, configuration.identity) } : {}), messages };
  }
  if (!localBody || typeof localBody !== 'object' || Array.isArray(localBody) ||
      (configuration.provider === 'claude-subscription' ?
        localBody.model !== nativeModel || !isSubscriptionModel(localBody.model, configuration.model) :
        ![configuration.model, configuration.model.replace('[1m]', '')].includes(localBody.model)) ||
      localBody.stream !== true ||
      (localBody.tools !== undefined && (!Array.isArray(localBody.tools) || localBody.tools.length !== 0)) ||
      !Array.isArray(localBody.messages) || localBody.messages.length < 1 || localBody.messages.length > 2 ||
      localBody.messages[0]?.role !== 'user') fail('CLI_REQUEST_REJECTED');
  const content = localBody.messages[0].content;
  const text = typeof content === 'string' ? content :
    Array.isArray(content) && content.length === 1 && content[0]?.type === 'text' ? content[0].text : undefined;
  if (text !== latest) fail('CLI_REQUEST_REJECTED');
  if (localBody.messages.length === 2) {
    const envelope = localBody.messages[1];
    const blocks = envelope?.content;
    const envelopeKeys = configuration.provider === 'claude-subscription' ? ['role', 'content', 'output_config'] : ['role', 'content'];
    if (envelope?.role !== 'system' || Object.keys(envelope).some(key => !envelopeKeys.includes(key)) ||
        !Array.isArray(blocks) || blocks.length !== 1 || blocks[0]?.type !== 'text' ||
        Object.keys(blocks[0]).some(key => !['type', 'text', 'cache_control'].includes(key)) ||
        typeof blocks[0].text !== 'string' || blocks[0].text.length < 1 || blocks[0].text.length > 2048) fail('CLI_REQUEST_REJECTED');
    if (envelope.output_config !== undefined && (!envelope.output_config || typeof envelope.output_config !== 'object' ||
        Array.isArray(envelope.output_config) || Object.keys(envelope.output_config).length !== 1 ||
        !['low', 'medium', 'high', 'max'].includes(envelope.output_config.effort))) fail('CLI_REQUEST_REJECTED');
  }
  // Only the validated App snapshot supplies history. The dynamic environment
  // envelope, cache hints and paths are discarded; subscription identity
  // markers are retained by the bounded helpers below.
  return { model: configuration.provider === 'claude-subscription' ? nativeModel : configuration.model.replace('[1m]', ''), stream: true, max_tokens: 4096,
    thinking: { type: 'disabled' }, tools: [], system: configuration.provider === 'claude-subscription' ?
      subscriptionSystem(localBody, configuration) : providerSystemPrompt(configuration),
    ...(configuration.provider === 'claude-subscription' ? { metadata: subscriptionMetadata(localBody, sessionID, configuration.identity) } : {}),
    messages: configuration.messages.map(message => ({ role: message.role, content: message.text })) };
}

function classifyCliDiagnostic(text) {
  if (/sandbox-exec:[^\n]*(?:syntax|parse|invalid profile)/i.test(text)) return 'SANDBOX_PROFILE_REJECTED';
  if (/unknown option|unrecognized option|invalid argument/i.test(text)) return 'CLI_ARGUMENT_REJECTED';
  if (/managed[^\n]*policy[^\n]*(?:denied|blocked)|not allowed by[^\n]*managed/i.test(text)) return 'CLI_MANAGED_POLICY_REJECTED';
  if (/EACCES|EPERM|permission denied|operation not permitted/i.test(text)) return 'CLI_PERMISSION_DENIED';
  if (/ENOENT|no such file or directory/i.test(text)) return 'CLI_PATH_UNAVAILABLE';
  if (/unknown model|unsupported model|invalid model/i.test(text)) return 'CLI_MODEL_REJECTED';
  return null;
}

export async function officialTransport({ body, apiKey, provider, subscriptionToken, headers = {}, signal, network, serializedBody }) {
  const payload = serializedBody ?? Buffer.from(JSON.stringify(body));
  const response = await proxyHttpsRequest({ url: provider === 'claude-subscription' ? SUBSCRIPTION_URL : PROVIDER_URL, method: 'POST', signal, network,
    headers: { ...headers, authorization: `Bearer ${provider === 'claude-subscription' ? subscriptionToken : apiKey}`, 'anthropic-version': '2023-06-01',
      'content-type': 'application/json', 'content-length': String(payload.length) }, body: payload });
  return { statusCode: response.statusCode, contentType: String(response.headers['content-type'] ?? ''), stream: response.stream };
}

// Serialize and capture the exact wire request before officialTransport inserts
// the credential. Offline transports receive the unchanged existing test API.
export async function tracedProviderRequest(parameters, { emit, requestID, attempt, project = false, transport = officialTransport, secrets = [] }) {
  const payload = Buffer.from(JSON.stringify(parameters.body));
  const headers = { ...parameters.headers, 'anthropic-version': '2023-06-01',
    'content-type': 'application/json', 'content-length': String(payload.length) };
  const trace = createRequestTrace({ requestID, attempt, project, provider: parameters.provider,
    url: parameters.provider === 'claude-subscription' ? SUBSCRIPTION_URL : PROVIDER_URL,
    wireModel: parameters.body.model, payload, headers, network: parameters.network,
    secrets: [parameters.apiKey, parameters.subscriptionToken, ...secrets], emit });
  trace.start();
  try {
    const upstream = await transport(transport === officialTransport ? { ...parameters, serializedBody: payload } : parameters);
    trace.receivedStatus(upstream?.statusCode);
    return { upstream, trace };
  } catch (error) { trace.error(error, parameters.signal); throw error; }
}

async function productionRuntime() {
  const metadata = await inspectInstalledNativeMetadata();
  let query;
  try { ({ query } = await import('@anthropic-ai/claude-agent-sdk')); } catch { fail('SDK_IMPORT_FAILED'); }
  if (typeof query !== 'function') fail('SDK_IMPORT_FAILED');
  return { ...metadata, query, spawn, transport: officialTransport };
}

function fixtureRuntime(dependencies) {
  if (!dependencies || dependencies.testOnly !== true || typeof dependencies.query !== 'function' ||
      typeof dependencies.spawn !== 'function' || typeof dependencies.transport !== 'function' ||
      typeof dependencies.cliPath !== 'string' || !/^[a-f0-9]{64}$/.test(dependencies.cliSha256) ||
      (dependencies.emitTrace !== undefined && typeof dependencies.emitTrace !== 'boolean') ||
      (dependencies.timeoutMs !== undefined && (!Number.isInteger(dependencies.timeoutMs) || dependencies.timeoutMs < 20 ||
        dependencies.timeoutMs > (dependencies.nativeFixture === true ? TIMEOUT_MS : 1000)))) fail('INVALID_TEST_DEPENDENCIES');
  return dependencies;
}

export async function relaySse(upstream, response, onText, signal, options) {
  if (options !== undefined && (!options || options.project !== true || typeof options.onTool !== 'function' ||
      Object.keys(options).some(key => !['project', 'onTool'].includes(key)))) fail('PROVIDER_PROTOCOL_REJECTED');
  if (!upstream.stream || typeof upstream.stream[Symbol.asyncIterator] !== 'function') fail('PROVIDER_PROTOCOL_REJECTED');
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let pending = '';
  let receivedBytes = 0;
  let frameCount = 0;
  let started = false;
  let stopped = false;
  const openBlocks = new Map();
  const usedBlocks = new Set(), toolIDs = new Set();
  let stopReason;
  const consume = frame => {
    if (++frameCount > 8192 || Buffer.byteLength(frame, 'utf8') > FRAME_LIMIT) fail('PROVIDER_RESPONSE_LIMIT');
    const data = frame.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('\n');
    if (!data) return;
    let value;
    try { value = JSON.parse(data); } catch { fail('PROVIDER_PROTOCOL_REJECTED'); }
    if (!value || typeof value !== 'object' || Array.isArray(value)) fail('PROVIDER_PROTOCOL_REJECTED');
    if (value.type === 'error') fail('PROVIDER_STREAM_ERROR');
    if (stopped && value.type !== 'ping') fail('PROVIDER_PROTOCOL_REJECTED');
    if (value.type === 'message_start') {
      if (started || value.message?.type !== 'message' || value.message?.role !== 'assistant' ||
          !Array.isArray(value.message.content) || value.message.content.length !== 0) fail('PROVIDER_PROTOCOL_REJECTED');
      started = true;
    } else if (value.type === 'content_block_start') {
      const block = value.content_block;
      if (!started || stopReason !== undefined || !Number.isSafeInteger(value.index) || value.index < 0 ||
          usedBlocks.has(value.index)) fail('PROVIDER_PROTOCOL_REJECTED');
      usedBlocks.add(value.index);
      if (block?.type === 'text' && typeof block.text === 'string') {
        openBlocks.set(value.index, { type: 'text' });
        if (block.text.length) onText(block.text);
      } else if (block?.type === 'tool_use') {
        if (!options?.project) fail('PROVIDER_TOOL_RESPONSE');
        if (!block || Object.keys(block).some(key => !['type', 'id', 'name', 'input', 'caller'].includes(key)) ||
            typeof block.id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(block.id) || toolIDs.has(block.id) ||
            !PROJECT_TOOLS.includes(block.name) || !block.input || typeof block.input !== 'object' || Array.isArray(block.input) ||
            Object.keys(block.input).length !== 0 || (block.caller !== undefined &&
              (!block.caller || Object.keys(block.caller).length !== 1 || block.caller.type !== 'direct'))) fail('PROVIDER_TOOL_RESPONSE');
        toolIDs.add(block.id);
        if (toolIDs.size > 64) fail('PROVIDER_RESPONSE_LIMIT');
        openBlocks.set(value.index, { type: 'tool_use', id: block.id, name: block.name, json: '' });
      } else fail('PROVIDER_PROTOCOL_REJECTED');
    } else if (value.type === 'content_block_delta') {
      const block = openBlocks.get(value.index);
      if (!started || stopReason !== undefined || !block) fail('PROVIDER_PROTOCOL_REJECTED');
      if (block.type === 'text' && value.delta?.type === 'text_delta' && typeof value.delta.text === 'string') {
        if (value.delta.text.length) onText(value.delta.text);
      } else if (block.type === 'tool_use' && value.delta?.type === 'input_json_delta' && typeof value.delta.partial_json === 'string') {
        block.json += value.delta.partial_json;
        if (Buffer.byteLength(block.json) > FRAME_LIMIT) fail('PROVIDER_RESPONSE_LIMIT');
      } else fail(value.delta?.type === 'input_json_delta' ? 'PROVIDER_TOOL_RESPONSE' : 'PROVIDER_PROTOCOL_REJECTED');
    } else if (value.type === 'content_block_stop') {
      const block = openBlocks.get(value.index);
      if (!block || !openBlocks.delete(value.index)) fail('PROVIDER_PROTOCOL_REJECTED');
      if (block.type === 'tool_use') {
        let input;
        try { input = JSON.parse(block.json || '{}'); } catch { fail('PROVIDER_TOOL_RESPONSE'); }
        if (!input || typeof input !== 'object' || Array.isArray(input)) fail('PROVIDER_TOOL_RESPONSE');
        options.onTool({ id: block.id, name: block.name, input });
      }
    } else if (value.type === 'message_delta') {
      if (!started || (!options?.project && value.delta?.stop_reason === 'tool_use')) fail(value.delta?.stop_reason === 'tool_use' ? 'PROVIDER_TOOL_RESPONSE' : 'PROVIDER_PROTOCOL_REJECTED');
      if (options?.project) {
        if (openBlocks.size || stopReason !== undefined ||
            !['end_turn', 'max_tokens', 'tool_use'].includes(value.delta?.stop_reason) ||
            (value.delta.stop_reason === 'tool_use') !== (toolIDs.size > 0)) fail('PROVIDER_PROTOCOL_REJECTED');
        stopReason = value.delta.stop_reason;
      }
      if (Number.isSafeInteger(value.usage?.output_tokens) && value.usage.output_tokens > 4096) fail('PROVIDER_OUTPUT_LIMIT');
    } else if (value.type === 'message_stop') {
      if (!started || openBlocks.size || (options?.project && stopReason === undefined)) fail('PROVIDER_PROTOCOL_REJECTED');
      stopped = true;
    } else if (value.type !== 'ping') fail('PROVIDER_PROTOCOL_REJECTED');
    // Forward only fully decoded, validated protocol frames.
    response.write(`${frame}\n\n`);
  };
  for await (const chunk of upstream.stream) {
    if (signal.aborted) fail('CHAT_CANCELLED');
    if (!(chunk instanceof Uint8Array)) fail('PROVIDER_PROTOCOL_REJECTED');
    receivedBytes += chunk.byteLength;
    if (receivedBytes > RESPONSE_LIMIT) fail('PROVIDER_RESPONSE_LIMIT');
    try { pending += decoder.decode(chunk, { stream: true }); } catch { fail('PROVIDER_PROTOCOL_REJECTED'); }
    for (;;) {
      const separator = /\r?\n\r?\n/.exec(pending);
      if (!separator) break;
      const frame = pending.slice(0, separator.index);
      pending = pending.slice(separator.index + separator[0].length);
      consume(frame);
    }
    if (Buffer.byteLength(pending, 'utf8') > FRAME_LIMIT) fail('PROVIDER_RESPONSE_LIMIT');
  }
  try { pending += decoder.decode(); } catch { fail('PROVIDER_PROTOCOL_REJECTED'); }
  if (pending.trim()) consume(pending);
  if (!started || !stopped) fail('PROVIDER_STREAM_INCOMPLETE');
}

export async function runDeepSeekTextChat(input, emit, testDependencies) {
  if (typeof emit !== 'function') throw new ChatFailure('MISSING_EVENT_SINK');
  let configuration;
  let runtime;
  let temporary;
  let ownedRun;
  let server;
  let child;
  let query;
  let exitPromise;
  let exitCode = null;
  let exitSignal = null;
  let childExited = false;
  let requestCount = 0;
  let fullText = '';
  let outputBytes = 0;
  let sdkAssistantText = '';
  let nativeVerified = false;
  let nativeModel;
  let nativeSessionID;
  let toolAttempted = false;
  let phaseCode = 'INPUT_VALIDATION_FAILED';
  let failureCode;
  let diagnosticCode;
  let success = false;
  let interrupted = false;
  let temporaryRemoved = false;
  let proxyClosed = false;
  let resolveNativeReady;
  const nativeReady = new Promise(resolve => { resolveNativeReady = resolve; });
  const abort = new AbortController();
  const sockets = new Set();
  const send = (type, fields = {}) => emit({ schema: EVENT_SCHEMA,
    request_id: configuration?.request_id ?? (typeof input?.request_id === 'string' && UUID.test(input.request_id) ? input.request_id : EMPTY_UUID),
    model: configuration?.model ?? (MODELS.has(input?.model) || SUBSCRIPTION_MODELS.has(input?.model) ? input.model : 'deepseek-flash[1m]'),
    type, fixture_only: false, ...fields });
  const terminate = code => {
    failureCode ??= code;
    resolveNativeReady(false);
    abort.abort();
    try { query?.close(); } catch { failureCode = 'QUERY_CLEANUP_FAILED'; }
    for (const socket of sockets) socket.destroy();
  };
  const interrupt = () => {
    interrupted = true;
    terminate('PROCESS_INTERRUPTED');
    if (child?.pid && !childExited) {
      try { process.kill(-child.pid, 'SIGTERM'); }
      catch (error) { if (error.code !== 'ESRCH') failureCode = 'CLI_CLEANUP_FAILED'; }
    }
  };
  if (testDependencies === undefined) { process.once('SIGTERM', interrupt); process.once('SIGINT', interrupt); }
  const timeoutMs = testDependencies?.testOnly === true && Number.isInteger(testDependencies.timeoutMs) && testDependencies.timeoutMs >= 20 &&
    testDependencies.timeoutMs <= (testDependencies.nativeFixture === true ? TIMEOUT_MS : 1000) ? testDependencies.timeoutMs : TIMEOUT_MS;
  const timer = setTimeout(() => terminate('TOTAL_TIMEOUT'), timeoutMs);
  try {
    configuration = validateInput(input, testDependencies?.testOnly === true);
    if (configuration.project) fail('VM_PROJECT_REQUIRED');
    // Stable identity is implemented by the isolated guest, not this legacy
    // host-native execution path. Never accept it and silently generate another.
    if (configuration.identity) fail('VM_IDENTITY_UNSUPPORTED');
    phaseCode = 'RUNTIME_INITIALIZATION_FAILED';
    runtime = testDependencies === undefined ? await productionRuntime() : fixtureRuntime(testDependencies);
    phaseCode = 'TEMPORARY_SETUP_FAILED';
    ownedRun = await createOwnedRunDirectory('chat');
    temporary = ownedRun.directory;
    const home = path.join(temporary, 'home');
    const cwd = path.join(temporary, 'empty-workspace');
    const temporaryFiles = path.join(temporary, 'tmp');
    await Promise.all([mkdir(path.join(home, '.claude'), { recursive: true }), mkdir(cwd), mkdir(temporaryFiles)]);
    const nativeRuntimeDirectory = await realpath(path.join(ROOT, 'node_modules'));
    const hostHome = await realpath(os.homedir());
    const localToken = randomBytes(32).toString('hex');
    phaseCode = 'LOCAL_PROXY_START_FAILED';
    server = http.createServer(async (request, response) => {
      let trace;
      try {
        const localAuthenticated = configuration.provider === 'claude-subscription' ?
          request.headers['x-api-key'] === undefined && tokenMatches(request.headers.authorization, `Bearer ${configuration.subscriptionToken}`) :
          tokenMatches(request.headers['x-api-key'], localToken) || tokenMatches(request.headers.authorization, `Bearer ${localToken}`);
        if (request.socket.remoteAddress !== '127.0.0.1' || !localAuthenticated) fail('LOCAL_AUTH_REJECTED');
        const route = new URL(request.url ?? '/', 'http://127.0.0.1');
        if (request.method !== 'POST' || route.pathname !== '/v1/messages' ||
            [...route.searchParams.entries()].some(([key, value]) => key !== 'beta' || value !== 'true')) fail('LOCAL_ROUTE_REJECTED');
        if (requestCount >= REQUEST_LIMIT) fail('REQUEST_LIMIT');
        const chunks = [];
        let size = 0;
        for await (const chunk of request) {
          size += chunk.length;
          if (size > INPUT_LIMIT) fail('REQUEST_BODY_LIMIT');
          chunks.push(chunk);
        }
        let body;
        try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { fail('INVALID_REQUEST_JSON'); }
        if (!(await nativeReady) || abort.signal.aborted) fail(failureCode ?? 'NO_TOOLS_CONTRACT');
        const headers = configuration.provider === 'claude-subscription' ? subscriptionHeaders(request.headers) : {};
        if (configuration.provider === 'claude-subscription' && headers['x-claude-code-session-id'] !== nativeSessionID) fail('SUBSCRIPTION_PROTOCOL_REJECTED');
        const outbound = providerBody(body, configuration, nativeModel, nativeSessionID);
        requestCount++;
        const traced = await tracedProviderRequest({ body: outbound, provider: configuration.provider, headers,
          ...(configuration.provider === 'claude-subscription' ? { subscriptionToken: configuration.subscriptionToken } : { apiKey: configuration.apiKey }),
          signal: abort.signal, network: configuration.network }, { requestID: configuration.request_id, attempt: requestCount,
          transport: runtime.transport, secrets: [localToken],
          emit: value => { if (testDependencies?.emitTrace !== false) send('request_trace', { trace: value }); } });
        const upstream = traced.upstream; trace = traced.trace;
        if (upstream.statusCode !== 200) {
          if (Number.isInteger(upstream.statusCode) && upstream.statusCode >= 100 && upstream.statusCode <= 599) trace.response();
          upstream.stream?.destroy?.();
          fail(Number.isInteger(upstream.statusCode) && upstream.statusCode >= 300 && upstream.statusCode < 400 ? 'PROVIDER_REDIRECT_REJECTED' :
          Number.isInteger(upstream.statusCode) && upstream.statusCode >= 400 && upstream.statusCode <= 599 ?
            `${configuration.provider === 'claude-subscription' ? 'SUBSCRIPTION' : 'PROVIDER'}_HTTP_${upstream.statusCode}` : 'PROVIDER_INVALID_HTTP_STATUS');
        }
        if (typeof upstream.contentType !== 'string' || !upstream.contentType.includes('text/event-stream')) fail('PROVIDER_PROTOCOL_REJECTED');
        response.writeHead(200, { 'content-type': 'text/event-stream', connection: 'close' });
        await relaySse(upstream, response, text => {
          outputBytes += Buffer.byteLength(text, 'utf8');
          if (outputBytes > OUTPUT_LIMIT) fail('PROVIDER_OUTPUT_LIMIT');
          fullText += text;
          send('delta', { text });
        }, abort.signal);
        trace.response();
        response.end();
      } catch (error) {
        trace?.error(error, abort.signal);
        failureCode ??= error instanceof ChatFailure || error instanceof ProxyTransportError ? error.code : abort.signal.aborted ? 'CHAT_CANCELLED' : 'PROVIDER_CONNECTION_FAILED';
        if (!response.headersSent) {
          response.writeHead(502, { 'content-type': 'application/json', connection: 'close' });
          response.end('{"type":"error","error":{"type":"invalid_request_error","message":"Text chat bridge rejected request"}}');
        } else response.destroy();
        terminate(failureCode);
      }
    });
    server.requestTimeout = 10_000; server.headersTimeout = 10_000; server.maxHeadersCount = 32;
    server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const port = server.address().port;
    phaseCode = 'SANDBOX_PROFILE_SETUP_FAILED';
    const profile = `(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip "localhost:${port}"))\n(deny file-write*)\n(allow file-write* (subpath ${JSON.stringify(temporary)}) (literal "/dev/null") (literal "/dev/tty"))\n(deny file-read* (subpath ${JSON.stringify(hostHome)}) (subpath "/Library/Keychains"))\n(allow file-read* (subpath ${JSON.stringify(nativeRuntimeDirectory)}) (subpath ${JSON.stringify(temporary)}))\n(deny process-exec (literal "/usr/bin/security"))\n`;
    const profilePath = path.join(temporary, 'cli.sb');
    await writeFile(profilePath, profile, { flag: 'wx', mode: 0o600 });
    const env = { PATH: '/usr/bin:/bin:/usr/sbin', HOME: home, TMPDIR: temporaryFiles,
      CLAUDE_CODE_TMPDIR: temporaryFiles, CLAUDE_CONFIG_DIR: path.join(home, '.claude'), ...profileEnvironment(configuration.runtimeProfile),
      ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
      ...(configuration.provider === 'claude-subscription' ? { CLAUDE_CODE_OAUTH_TOKEN: configuration.subscriptionToken } : {
        ANTHROPIC_API_KEY: localToken, ANTHROPIC_MODEL: configuration.model, ANTHROPIC_DEFAULT_OPUS_MODEL: configuration.model,
        ANTHROPIC_DEFAULT_SONNET_MODEL: configuration.model, ANTHROPIC_DEFAULT_HAIKU_MODEL: 'deepseek-flash',
        CLAUDE_CODE_SUBAGENT_MODEL: 'deepseek-flash' }), CLAUDE_CODE_ENTRYPOINT: 'sdk-ts',
      CLAUDE_AGENT_SDK_VERSION: '0.3.295', CLAUDE_CODE_SDK_READS_SESSION_STATE: '1',
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1',
      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1', CLAUDE_CODE_DISABLE_CRON: '1', CLAUDE_CODE_DISABLE_AGENT_VIEW: '1',
      CLAUDE_CODE_SKIP_BASH_ENVIRONMENT_SNAPSHOT: '1', CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1' };
    if (abort.signal.aborted) fail(failureCode ?? 'TOTAL_TIMEOUT');
    phaseCode = 'SDK_QUERY_START_FAILED';
    query = runtime.query({ prompt: configuration.messages.at(-1).text, options: {
      cwd, env, pathToClaudeCodeExecutable: runtime.cliPath, model: configuration.model,
      tools: [], allowedTools: [], agents: {}, mcpServers: {}, strictMcpConfig: true, plugins: [], skills: [],
      settingSources: [], settings: { disableAllHooks: true, enabledPlugins: {
        'cc-plugin-agents-md@builtin': false, 'cc-plugin-plugin-authoring@builtin': false,
      } }, extraArgs: { 'disable-slash-commands': null }, persistSession: false, maxTurns: 1,
      thinking: { type: 'disabled' }, systemPrompt: SYSTEM_PROMPT, verbatimPrompts: true,
      permissionMode: 'default', permissionPrompts: 'none', allowDangerouslySkipPermissions: false,
      includePartialMessages: true, abortController: abort,
      canUseTool: async () => { toolAttempted = true; return { behavior: 'deny', message: 'Text chat has no tools' }; },
      spawnClaudeCodeProcess: options => {
        if (child || options.command !== runtime.cliPath || options.cwd !== cwd || !options.args.includes('--setting-sources=')) fail('CLI_LAUNCH_CONTRACT');
        ownedRun.markNativeLaunchPending();
        child = runtime.spawn('/usr/bin/sandbox-exec', ['-f', profilePath, runtime.cliPath, ...options.args],
          { cwd, env, stdio: ['pipe', 'pipe', 'pipe'], detached: true, signal: options.signal });
        exitPromise = new Promise(resolve => {
          child.once('exit', (code, signal) => { childExited = true; exitCode = code; exitSignal = signal; resolve(); });
          child.once('error', error => {
            if (error.code !== 'ABORT_ERR' || !abort.signal.aborted) failureCode ??= 'CLI_PROCESS_ERROR';
            if (!child.pid) resolve();
          });
        });
        if (child.pid) ownedRun.registerNativePID(child.pid);
        let diagnosticTail = '';
        child.stderr.on('data', chunk => {
          diagnosticTail = (diagnosticTail + chunk.toString('utf8')).slice(-4096);
          diagnosticCode ??= classifyCliDiagnostic(diagnosticTail);
        });
        return child;
      }, stderr: () => {} } });
    phaseCode = 'SDK_ITERATION_FAILED';
    let result;
    for await (const event of query) {
      if (event.type === 'system' && event.subtype === 'init') {
        if (nativeVerified) fail('DUPLICATE_NATIVE_INIT');
        nativeVerified = event.claude_code_version === '2.1.295' && event.cwd === cwd && event.permissionMode === 'default' &&
          Array.isArray(event.tools) && event.tools.length === 0 && Array.isArray(event.mcp_servers) && event.mcp_servers.length === 0 &&
          Array.isArray(event.skills) && event.skills.length === 0 && Array.isArray(event.plugins) && event.plugins.length === 0;
        if (configuration.provider === 'claude-subscription') {
          nativeVerified &&= event.apiKeySource === 'none' && isSubscriptionModel(event.model, configuration.model) &&
            typeof event.session_id === 'string' && UUID.test(event.session_id);
          nativeModel = event.model;
          nativeSessionID = event.session_id;
        }
        resolveNativeReady(nativeVerified);
        if (!nativeVerified) fail('NO_TOOLS_CONTRACT');
        send('started', { no_tools: true });
      }
      const blocks = event.message?.content;
      if (Array.isArray(blocks)) {
        if (blocks.some(block => block.type === 'tool_use' || block.type === 'tool_result')) toolAttempted = true;
        if (event.type === 'assistant') sdkAssistantText += blocks.filter(block => block.type === 'text').map(block => block.text).join('');
      }
      if (event.type === 'result') { result = event; break; }
    }
    if (failureCode) fail(failureCode);
    if (!child) fail('CLI_NOT_STARTED');
    if (!nativeVerified || toolAttempted) fail('NO_TOOLS_CONTRACT');
    if (!result || result.subtype !== 'success' || result.is_error || result.num_turns !== 1 ||
        typeof result.result !== 'string' || !fullText.trim() || result.result.trim() !== fullText.trim() ||
        sdkAssistantText !== fullText || requestCount < 1) fail('CLI_TEXT_MISMATCH');
    success = true;
  } catch (error) { failureCode ??= error instanceof ChatFailure || error instanceof ProxyTransportError || error instanceof RuntimeProfileError ? error.code : diagnosticCode ?? phaseCode; }
  finally {
    clearTimeout(timer);
    resolveNativeReady(false);
    try { query?.close(); } catch { failureCode = 'QUERY_CLEANUP_FAILED'; }
    abort.abort();
    for (const socket of sockets) socket.destroy();
    if (server) { await new Promise(resolve => server.close(() => resolve())); proxyClosed = !server.listening; }
    else proxyClosed = true;
    if (exitPromise) {
      await Promise.race([exitPromise, delay(interrupted ? 400 : 2500)]);
      if (!childExited && child?.pid) {
        try { process.kill(-child.pid, 'SIGKILL'); }
        catch (error) { if (error.code !== 'ESRCH') failureCode = 'CLI_CLEANUP_FAILED'; }
        await Promise.race([exitPromise, delay(interrupted ? 400 : 1000)]);
      }
    }
    if (child && (exitCode !== 0 || exitSignal !== null)) failureCode ??= 'CLI_EXIT_FAILED';
    if (runtime && testDependencies === undefined) {
      try { if (hash(await readFile(runtime.cliPath)) !== runtime.cliSha256) failureCode = 'CLI_CHANGED'; }
      catch { failureCode = 'CLI_READBACK_FAILED'; }
    }
    if (temporary) {
      try {
        if (child?.pid && (!childExited || !(await waitForNativeProcessExit(child.pid)))) throw new Error('OWNED_NATIVE_STILL_RUNNING');
        await rm(temporary, { recursive: true, force: true }); temporaryRemoved = true; }
      catch { failureCode = 'TEMPORARY_CLEANUP_FAILED'; }
    } else temporaryRemoved = true;
    if (testDependencies === undefined) { process.removeListener('SIGTERM', interrupt); process.removeListener('SIGINT', interrupt); }
  }
  const terminal = success && !failureCode && temporaryRemoved && proxyClosed ? {
    schema: EVENT_SCHEMA, request_id: configuration.request_id, model: configuration.model,
    type: 'completed', fixture_only: false, text: fullText, no_tools: true,
    cli_exit: exitCode, cli_signal: exitSignal, temporary_removed: temporaryRemoved, proxy_closed: proxyClosed, request_count: requestCount,
  } : {
    schema: EVENT_SCHEMA, request_id: configuration?.request_id ?? (typeof input?.request_id === 'string' && UUID.test(input.request_id) ? input.request_id : EMPTY_UUID),
    model: configuration?.model ?? (MODELS.has(input?.model) || SUBSCRIPTION_MODELS.has(input?.model) ? input.model : 'deepseek-flash[1m]'),
    type: 'error', fixture_only: false, code: failureCode ?? 'CHAT_FAILED',
  };
  emit(terminal);
  return terminal;
}

async function readStdin() {
  let size = 0;
  const chunks = [];
  const timer = setTimeout(() => process.stdin.destroy(new ChatFailure('INPUT_TIMEOUT')), 10_000);
  try {
    for await (const chunk of process.stdin) {
      size += chunk.length;
      if (size > INPUT_LIMIT) fail('INPUT_LIMIT');
      chunks.push(chunk);
    }
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { fail('INVALID_INPUT_JSON'); }
  } finally { clearTimeout(timer); }
}

async function runOfflineFixture(input, emit) {
  const configuration = validateInput(input, true);
  if (configuration.project) fail('VM_PROJECT_REQUIRED');
  const base = { schema: EVENT_SCHEMA, request_id: configuration.request_id, model: configuration.model, fixture_only: true };
  emit({ ...base, type: 'started', no_tools: true });
  const chunks = ['Offline text fixture. ',
    ...(configuration.textSkills.length ? [`Applied text skills: ${configuration.textSkills.map(skill => skill.name).join(', ')}\n`] : []),
    '离线测试回复：', '你好，世界 🌏。'];
  for (const text of chunks) { await delay(25); emit({ ...base, type: 'delta', text }); }
  emit({ ...base, type: 'completed', text: chunks.join(''), no_tools: true,
    cli_exit: 0, cli_signal: null, temporary_removed: true, proxy_closed: true, request_count: 1 });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const fixture = process.argv.length === 3 && process.argv[2] === '--fixture';
  const emit = value => process.stdout.write(`${JSON.stringify(value)}\n`);
  let input;
  try {
    if (process.argv.length > (fixture ? 3 : 2)) fail('INVALID_ARGUMENTS');
    input = await readStdin();
    if (fixture) await runOfflineFixture(input, emit); else await runDeepSeekTextChat(input, emit);
  } catch (error) {
    emit({ schema: EVENT_SCHEMA, request_id: typeof input?.request_id === 'string' && UUID.test(input.request_id) ? input.request_id : EMPTY_UUID,
      model: MODELS.has(input?.model) || SUBSCRIPTION_MODELS.has(input?.model) ? input.model : 'deepseek-flash[1m]', type: 'error', fixture_only: fixture,
      code: error instanceof ChatFailure || error instanceof ProxyTransportError || error instanceof RuntimeProfileError ? error.code : 'CHAT_FAILED' });
  }
}
