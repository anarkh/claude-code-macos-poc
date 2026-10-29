import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { NETWORK_ERROR_CODES, proxyHttpsBufferRequest, validateNetworkPolicy } from '../network/proxy-transport.mjs';

export const QUOTA_REQUEST_SCHEMA = 'claude-subscription-quota-request/v1';
export const QUOTA_RESPONSE_SCHEMA = 'claude-subscription-quota-response/v1';
export const QUOTA_URL = 'https://api.anthropic.com/api/oauth/usage';
export const QUOTA_WINDOW_IDS = Object.freeze(['five_hour', 'seven_day', 'seven_day_opus', 'seven_day_sonnet', 'seven_day_oauth_apps']);
export const QUOTA_MAX_RESPONSE_BYTES = 65_536;
const MAX_INPUT_BYTES = 16_384;
const ERROR_CODES = new Set(['QUOTA_INPUT_INVALID', 'QUOTA_INPUT_TIMEOUT', 'QUOTA_TOKEN_INVALID',
  'QUOTA_UNAUTHORIZED', 'QUOTA_FORBIDDEN', 'QUOTA_RATE_LIMITED', 'QUOTA_SERVICE_UNAVAILABLE',
  'QUOTA_HTTP_REJECTED', 'QUOTA_RESPONSE_INVALID', 'QUOTA_CANCELLED', 'QUOTA_QUERY_FAILED', ...NETWORK_ERROR_CODES]);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const failure = code => Object.assign(new Error(code), { code });

export function safeQuotaCode(error) {
  return ERROR_CODES.has(error?.code) ? error.code : 'QUOTA_QUERY_FAILED';
}

export function validateQuotaInput(input) {
  if (!object(input) || Object.keys(input).length !== 3 ||
      Object.keys(input).some(key => !['schema', 'subscriptionToken', 'network'].includes(key)) ||
      input.schema !== QUOTA_REQUEST_SCHEMA) throw failure('QUOTA_INPUT_INVALID');
  const token = input.subscriptionToken;
  if (typeof token !== 'string' || Buffer.byteLength(token) < 16 || Buffer.byteLength(token) > 4096 ||
      !/^sk-ant-oat01-[A-Za-z0-9_-]+$/.test(token)) throw failure('QUOTA_TOKEN_INVALID');
  return { subscriptionToken: token, network: validateNetworkPolicy(input.network) };
}

function resetTime(value) {
  if (value === undefined || value === null) return null;
  // The upstream usage endpoint uses an ISO-8601 timestamp, unlike statusline's epoch seconds.
  const parts = typeof value === 'string' && value.length <= 64
    ? /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|[+-](\d{2}):(\d{2}))$/.exec(value) : null;
  if (!parts || Number(parts[1]) < 1970 || Number(parts[2]) < 1 || Number(parts[2]) > 12 ||
      Number(parts[3]) < 1 || Number(parts[3]) > new Date(Date.UTC(Number(parts[1]), Number(parts[2]), 0)).getUTCDate() ||
      Number(parts[4]) > 23 || Number(parts[5]) > 59 || Number(parts[6]) > 59 ||
      (parts[7] !== undefined && (Number(parts[7]) > 23 || Number(parts[8]) > 59))) {
    throw failure('QUOTA_RESPONSE_INVALID');
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || milliseconds < 0) throw failure('QUOTA_RESPONSE_INVALID');
  return milliseconds / 1000;
}

export function parseQuotaUsage(payload, queriedAt) {
  if (!object(payload) || !Number.isFinite(queriedAt) || queriedAt < 0) throw failure('QUOTA_RESPONSE_INVALID');
  const windows = [];
  for (const id of QUOTA_WINDOW_IDS) {
    const window = payload[id];
    if (window === undefined || window === null) continue;
    if (object(window) && window.utilization === null) continue;
    if (!object(window) || typeof window.utilization !== 'number' || !Number.isFinite(window.utilization) ||
        window.utilization < 0 || window.utilization > 100) throw failure('QUOTA_RESPONSE_INVALID');
    windows.push({ id, usedPercentage: window.utilization, resetsAt: resetTime(window.resets_at) });
  }
  // A successful response can legitimately omit every window. Do not manufacture zero usage.
  return { schema: QUOTA_RESPONSE_SCHEMA, ok: true, windows, queriedAt };
}

// Compatibility adapter for the usage endpoint used by the official CLI. This endpoint
// is not a versioned public personal-quota API; permission or format failures stay visible.
// The transport owns all egress: fixed destination, CONNECT proxy, TLS, no redirects.
export async function querySubscriptionQuota(input, { transport = proxyHttpsBufferRequest,
  signal, now = () => Date.now() } = {}) {
  const { subscriptionToken, network } = validateQuotaInput(input);
  if (signal?.aborted) throw failure('QUOTA_CANCELLED');
  const response = await transport({ url: QUOTA_URL, method: 'GET', network, signal,
    timeoutMs: 20_000, maxResponseBytes: QUOTA_MAX_RESPONSE_BYTES,
    headers: { authorization: `Bearer ${subscriptionToken}`, accept: 'application/json',
      'content-type': 'application/json', 'anthropic-beta': 'oauth-2025-04-20' }, body: '' });
  if (signal?.aborted) throw failure('QUOTA_CANCELLED');
  if (response.status !== 200) {
    if (response.status === 401) throw failure('QUOTA_UNAUTHORIZED');
    if (response.status === 403) throw failure('QUOTA_FORBIDDEN');
    if (response.status === 429) throw failure('QUOTA_RATE_LIMITED');
    if (response.status >= 500 && response.status <= 599) throw failure('QUOTA_SERVICE_UNAVAILABLE');
    throw failure('QUOTA_HTTP_REJECTED');
  }
  if (!Buffer.isBuffer(response.body) || response.body.length > QUOTA_MAX_RESPONSE_BYTES ||
      !/^application\/json(?:\s*;|$)/i.test(String(response.headers?.['content-type'] ?? ''))) {
    throw failure('QUOTA_RESPONSE_INVALID');
  }
  let payload;
  try { payload = JSON.parse(response.body.toString('utf8')); }
  catch { throw failure('QUOTA_RESPONSE_INVALID'); }
  return parseQuotaUsage(payload, now() / 1000);
}

async function readInput(stream) {
  let size = 0;
  const chunks = [];
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > MAX_INPUT_BYTES) throw failure('QUOTA_INPUT_INVALID');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw failure('QUOTA_INPUT_INVALID'); }
}

async function main() {
  const controller = new AbortController();
  const cancel = () => { controller.abort(); process.stdin.destroy(failure('QUOTA_CANCELLED')); };
  process.once('SIGTERM', cancel);
  process.once('SIGINT', cancel);
  const inputTimeout = setTimeout(() => process.stdin.destroy(failure('QUOTA_INPUT_TIMEOUT')), 15_000);
  let response;
  try {
    const input = await readInput(process.stdin);
    clearTimeout(inputTimeout);
    response = await querySubscriptionQuota(input, { signal: controller.signal });
  } catch (error) {
    response = { schema: QUOTA_RESPONSE_SCHEMA, ok: false, code: safeQuotaCode(error) };
    process.exitCode = 1;
  } finally {
    clearTimeout(inputTimeout);
    process.removeListener('SIGTERM', cancel);
    process.removeListener('SIGINT', cancel);
  }
  process.stdout.write(JSON.stringify(response) + '\n');
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) await main();
