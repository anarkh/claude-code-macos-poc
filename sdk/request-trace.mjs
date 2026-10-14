// Bounded, credential-free snapshots of the final CLI provider request. The
// caller retains the wire bytes and adds authentication only after this snapshot.
export const REQUEST_TRACE_SCHEMA = 'claude-request-trace/v1';
export const REQUEST_TRACE_BODY_LIMIT = 2_097_152;
export const REQUEST_TRACE_HEADER_LIMIT = 16_384;
export const REQUEST_TRACE_HEADER_VALUE_LIMIT = 4096;
export const REQUEST_TRACE_HEADERS = Object.freeze(['content-type', 'content-length',
  'anthropic-version', 'anthropic-beta', 'x-app', 'user-agent',
  'x-claude-code-session-id', 'anthropic-dangerous-direct-browser-access']);
export const PROVIDER_URL = 'https://api.deepseek.com/anthropic/v1/messages';
export const SUBSCRIPTION_URL = 'https://api.anthropic.com/v1/messages?beta=true';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REDACTED = '[REDACTED]';

export class RequestTraceError extends Error {
  constructor() { super('REQUEST_TRACE_REJECTED'); this.code = 'REQUEST_TRACE_REJECTED'; }
}
const reject = () => { throw new RequestTraceError(); };

function secretRedactor(secrets) {
  if (!Array.isArray(secrets) || secrets.some(secret => secret !== undefined && typeof secret !== 'string')) reject();
  const known = [...new Set(secrets.filter(secret => typeof secret === 'string' && secret.length))]
    .sort((left, right) => right.length - left.length);
  const variants = new Set(known);
  // A user can paste a credential as JSON text, and subscription metadata is
  // itself encoded JSON. Include bounded JSON-escaped spellings so these nested
  // strings are cleaned without changing unrelated request content.
  for (const secret of known) {
    let value = secret;
    for (let level = 0; level < 20; level++) {
      const escaped = JSON.stringify(value).slice(1, -1);
      if (escaped === value || Buffer.byteLength(escaped) > REQUEST_TRACE_BODY_LIMIT) break;
      variants.add(escaped); value = escaped;
    }
  }
  const spellings = [...variants].sort((left, right) => right.length - left.length);
  let changed = false;
  const redact = value => {
    let output = value;
    for (const secret of spellings) {
      if (output.includes(secret)) { output = output.split(secret).join(REDACTED); changed = true; }
    }
    return output;
  };
  const json = value => {
    if (typeof value === 'string') return redact(value);
    if (Array.isArray(value)) return value.map(json);
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, child]) => [redact(key), json(child)]));
    return value;
  };
  return { redact, json, changed: () => changed,
    safe: value => spellings.every(secret => !value.includes(secret)) };
}

export function requestTraceErrorCode(error, signal) {
  if (signal?.aborted || ['NETWORK_CANCELLED', 'CHAT_CANCELLED', 'PROCESS_INTERRUPTED'].includes(error?.code)) return 'CHAT_CANCELLED';
  if (['PROXY_TIMEOUT', 'TOTAL_TIMEOUT', 'VM_TIMEOUT'].includes(error?.code)) return 'PROVIDER_TIMEOUT';
  if (['PROVIDER_PROTOCOL_REJECTED', 'PROVIDER_INVALID_HTTP_STATUS', 'PROVIDER_RESPONSE_LIMIT',
    'PROVIDER_OUTPUT_LIMIT', 'PROVIDER_STREAM_ERROR', 'PROVIDER_STREAM_INCOMPLETE', 'PROVIDER_TOOL_RESPONSE'].includes(error?.code)) return 'PROVIDER_PROTOCOL_ERROR';
  return 'PROVIDER_NETWORK_ERROR';
}

// Nothing from response headers or an error message enters this interface.
// Each attempt emits one request and one terminal snapshot; the App upserts it
// by attempt_id and holds at most the existing three admitted CLI requests.
export function createRequestTrace({ requestID, attempt, provider, url, method = 'POST', wireModel,
  headers = {}, payload, network, secrets = [], emit, now = () => performance.now() }) {
  if (!UUID.test(requestID ?? '') || !Number.isInteger(attempt) || attempt < 1 || attempt > 3 ||
      !['deepseek-api', 'claude-subscription'].includes(provider) || method !== 'POST' ||
      url !== (provider === 'claude-subscription' ? SUBSCRIPTION_URL : PROVIDER_URL) ||
      typeof wireModel !== 'string' || !wireModel || Buffer.byteLength(wireModel) > 128 ||
      !Buffer.isBuffer(payload) || payload.length > REQUEST_TRACE_BODY_LIMIT ||
      typeof emit !== 'function' || typeof now !== 'function' ||
      !headers || typeof headers !== 'object' || Array.isArray(headers)) reject();
  const scrub = secretRedactor(secrets);
  let decoded;
  try { decoded = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(payload)); }
  catch { reject(); }
  if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded) || decoded.model !== wireModel) reject();
  // JSON.stringify of this parsed value preserves the actual serializer's
  // order and formatting, while redacting credentials inside strings (even
  // JSON-escaped user text or embedded subscription attribution JSON).
  const body = JSON.stringify(scrub.json(decoded));
  if (Buffer.byteLength(body) > REQUEST_TRACE_BODY_LIMIT) reject();
  const safeHeaders = {};
  let headerBytes = 0;
  for (const name of REQUEST_TRACE_HEADERS) {
    if (!Object.hasOwn(headers, name)) continue;
    if (typeof headers[name] !== 'string' || /[\r\n\x00]/.test(headers[name]) ||
        Buffer.byteLength(headers[name]) > REQUEST_TRACE_HEADER_VALUE_LIMIT) reject();
    const value = scrub.redact(headers[name]);
    if (Buffer.byteLength(value) > REQUEST_TRACE_HEADER_VALUE_LIMIT) reject();
    headerBytes += Buffer.byteLength(name) + Buffer.byteLength(value);
    if (headerBytes > REQUEST_TRACE_HEADER_LIMIT) reject();
    safeHeaders[name] = value;
  }
  // Production always supplies the admitted CONNECT policy. A missing policy
  // is possible only in the explicitly injected legacy offline test seam.
  const proxyURL = network?.proxyURL ?? null;
  if (proxyURL !== null && (!/^http:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}$/.test(proxyURL) ||
      Number(proxyURL.slice(proxyURL.lastIndexOf(':') + 1)) > 65535)) reject();
  const base = { schema: REQUEST_TRACE_SCHEMA, attempt_id: `${requestID}:${attempt}`, attempt,
    provider, url: scrub.redact(url), method, wire_model: scrub.redact(wireModel),
    headers: safeHeaders, proxy: { mode: 'http-connect', url: proxyURL === null ? null : scrub.redact(proxyURL) },
    body, body_bytes: payload.length, body_truncated: false, secrets_redacted: scrub.changed() };
  // Unusual credentials that collide with structural metadata must fail closed
  // rather than escaping the trace through an identifier or serialized value.
  if (!scrub.safe(JSON.stringify(base))) reject();
  let started, settled = false, status = null;
  const elapsed = () => {
    const value = Math.round((now() - started) * 1000) / 1000;
    if (!Number.isFinite(value)) reject();
    return Math.max(0, value);
  };
  const publish = fields => emit({ ...structuredClone(base), ...fields });
  return {
    start() {
      if (started !== undefined || settled) reject();
      started = now(); if (!Number.isFinite(started)) reject();
      publish({ phase: 'request', status: null, duration_ms: null, outcome: null, error_code: null });
    },
    receivedStatus(value) {
      if (started === undefined || settled) reject();
      if (Number.isInteger(value) && value >= 100 && value <= 599) status = value;
    },
    response() {
      if (settled) return;
      if (started === undefined || status === null) reject();
      settled = true;
      publish({ phase: 'response', status, duration_ms: elapsed(), outcome: 'http', error_code: null });
    },
    error(error, signal) {
      if (settled) return;
      if (started === undefined) reject();
      settled = true;
      const error_code = requestTraceErrorCode(error, signal);
      publish({ phase: 'error', status, duration_ms: elapsed(),
        outcome: error_code === 'CHAT_CANCELLED' ? 'cancelled' : 'network_error', error_code });
    },
  };
}
