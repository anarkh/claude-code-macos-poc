// The only provider egress for the App's Node bridges. The proxy receives the
// destination hostname in CONNECT; this process never resolves it locally.
import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';
import net from 'node:net';
import { PassThrough } from 'node:stream';

export const NETWORK_POLICY_SCHEMA = 'app-network-policy/v1';
export const NETWORK_ERROR_CODES = Object.freeze([
  'NETWORK_POLICY_REQUIRED', 'NETWORK_POLICY_INVALID', 'NETWORK_REQUEST_INVALID',
  'NETWORK_TEST_DEPENDENCIES_INVALID', 'NETWORK_CANCELLED', 'PROXY_CONNECT_FAILED',
  'PROXY_CONNECT_REJECTED', 'PROXY_TIMEOUT', 'PROXY_TLS_FAILED',
  'PROXY_REQUEST_FAILED', 'PROXY_RESPONSE_TOO_LARGE',
]);

export class ProxyTransportError extends Error {
  constructor(code) {
    super(NETWORK_ERROR_CODES.includes(code) ? code : 'PROXY_REQUEST_FAILED');
    this.name = 'ProxyTransportError';
    this.code = this.message;
  }
}
const failure = code => new ProxyTransportError(code);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

export function validateNetworkPolicy(policy) {
  if (policy === undefined || policy === null) throw failure('NETWORK_POLICY_REQUIRED');
  if (!object(policy) || Object.keys(policy).length !== 3 ||
      Object.keys(policy).some(key => !['schema', 'proxyURL', 'dnsPolicy'].includes(key)) ||
      policy.schema !== NETWORK_POLICY_SCHEMA || policy.dnsPolicy !== 'proxy-only' ||
      typeof policy.proxyURL !== 'string' ||
      !/^http:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}$/.test(policy.proxyURL)) {
    throw failure('NETWORK_POLICY_INVALID');
  }
  let proxy;
  try { proxy = new URL(policy.proxyURL); } catch { throw failure('NETWORK_POLICY_INVALID'); }
  const port = Number(policy.proxyURL.slice(policy.proxyURL.lastIndexOf(':') + 1));
  if (port < 1 || port > 65535 || String(port) !== policy.proxyURL.slice(policy.proxyURL.lastIndexOf(':') + 1) ||
      proxy.protocol !== 'http:' || proxy.username || proxy.password || proxy.pathname !== '/' || proxy.search || proxy.hash) {
    throw failure('NETWORK_POLICY_INVALID');
  }
  return Object.freeze({ schema: NETWORK_POLICY_SCHEMA, proxyURL: policy.proxyURL, dnsPolicy: 'proxy-only' });
}

function destination(input) {
  if (typeof input !== 'string' || input.length > 4096 || input !== input.trim()) throw failure('NETWORK_REQUEST_INVALID');
  let url;
  try { url = new URL(input); } catch { throw failure('NETWORK_REQUEST_INVALID'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || !url.hostname) throw failure('NETWORK_REQUEST_INVALID');
  const hostname = url.hostname.replace(/^\[|\]$/g, '');
  if (/[\s\x00-\x1f\x7f]/.test(hostname)) throw failure('NETWORK_REQUEST_INVALID');
  const port = Number(url.port || 443);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw failure('NETWORK_REQUEST_INVALID');
  return { url, hostname, port, authority: `${net.isIP(hostname) === 6 ? `[${hostname}]` : hostname}:${port}` };
}

function testOptions(dependencies) {
  if (dependencies === undefined) return {};
  if (!object(dependencies) || dependencies.testOnly !== true ||
      Object.keys(dependencies).some(key => !['testOnly', 'ca', 'timeoutMs'].includes(key)) ||
      (dependencies.ca !== undefined && typeof dependencies.ca !== 'string' && !Buffer.isBuffer(dependencies.ca)) ||
      (dependencies.timeoutMs !== undefined && (!Number.isInteger(dependencies.timeoutMs) || dependencies.timeoutMs < 10 || dependencies.timeoutMs > 10000))) {
    throw failure('NETWORK_TEST_DEPENDENCIES_INVALID');
  }
  return dependencies;
}

// Returns a sanitized stream, so connection diagnostics cannot become chat
// events or translation errors. No redirect handling or direct fallback exists.
export async function proxyHttpsRequest({ url, method = 'POST', headers = {}, body = '', signal, network, timeoutMs = 90000 } = {}, dependencies) {
  const policy = validateNetworkPolicy(network);
  const target = destination(url);
  const fixture = testOptions(dependencies);
  timeoutMs = fixture.timeoutMs ?? timeoutMs;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 2_147_483_647 ||
      !['POST', 'GET', 'HEAD'].includes(method) || !object(headers) ||
      (typeof body !== 'string' && !Buffer.isBuffer(body)) ||
      (signal !== undefined && !(signal instanceof AbortSignal))) throw failure('NETWORK_REQUEST_INVALID');
  if (signal?.aborted) throw failure('NETWORK_CANCELLED');
  const proxy = new URL(policy.proxyURL);
  const proxyHost = proxy.hostname.replace(/^\[|\]$/g, '');
  const proxyPort = Number(policy.proxyURL.slice(policy.proxyURL.lastIndexOf(':') + 1));
  return await new Promise((resolve, reject) => {
    let connectRequest;
    let providerRequest;
    let tunnel;
    let secure;
    let agent;
    let output;
    let settled = false;
    let ended = false;
    let stage = 'connect';
    const cleanupListeners = () => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
    };
    const stop = code => {
      if (ended) return;
      ended = true;
      cleanupListeners();
      const error = failure(code);
      if (!settled) { settled = true; reject(error); }
      else if (output && !output.destroyed) output.destroy(error);
      connectRequest?.destroy();
      providerRequest?.destroy();
      secure?.destroy();
      tunnel?.destroy();
      agent?.destroy();
    };
    const onAbort = () => stop('NETWORK_CANCELLED');
    const timer = setTimeout(() => stop('PROXY_TIMEOUT'), timeoutMs);
    signal?.addEventListener('abort', onAbort, { once: true });
    const forbiddenLookup = (_hostname, _options, callback) => callback(failure('NETWORK_POLICY_INVALID'));
    try {
      // Numeric loopback is deliberate. Neither environment proxy variables nor
      // no_proxy, system DNS, or a user-controlled target resolver are consulted.
      connectRequest = http.request({ hostname: proxyHost, port: proxyPort, method: 'CONNECT',
        path: target.authority, headers: { host: target.authority, connection: 'close' },
        agent: false, lookup: forbiddenLookup, maxHeaderSize: 16384 });
      connectRequest.once('error', () => stop(stage === 'connect' ? 'PROXY_CONNECT_FAILED' : 'PROXY_REQUEST_FAILED'));
      connectRequest.once('response', response => {
        response.resume();
        stop('PROXY_CONNECT_REJECTED');
      });
      connectRequest.once('connect', (response, socket, head) => {
        tunnel = socket;
        if (ended) { socket.destroy(); return; }
        if (response.statusCode !== 200) { stop('PROXY_CONNECT_REJECTED'); return; }
        stage = 'tls';
        socket.once('error', () => stop(stage === 'tls' ? 'PROXY_TLS_FAILED' : 'PROXY_REQUEST_FAILED'));
        // HTTP may consume a few bytes past its header delimiter. Preserve them
        // for TLS rather than dropping them or treating them as plaintext HTTP.
        if (head.length) socket.unshift(head);
        try {
          secure = tls.connect({ socket, servername: net.isIP(target.hostname) ? undefined : target.hostname,
            rejectUnauthorized: true, ALPNProtocols: ['http/1.1'],
            checkServerIdentity: (_servername, certificate) => tls.checkServerIdentity(target.hostname, certificate),
            ...(fixture.ca === undefined ? {} : { ca: fixture.ca }) });
          secure.once('error', () => stop(stage === 'tls' ? 'PROXY_TLS_FAILED' : 'PROXY_REQUEST_FAILED'));
          secure.once('close', () => {
            // After headers, HTTP may still hold a complete body behind stream
            // backpressure when the peer closes TLS. IncomingMessage's error/
            // aborted events detect truncation; its end event detects success.
            // The existing request deadline also covers a stalled consumer.
            if (!ended && ['tls', 'request'].includes(stage)) stop(stage === 'tls' ? 'PROXY_TLS_FAILED' : 'PROXY_REQUEST_FAILED');
          });
          secure.once('secureConnect', () => {
            if (ended) return;
            if (!secure.authorized) { stop('PROXY_TLS_FAILED'); return; }
            stage = 'request';
            // This Agent can only return the already-authenticated tunnel. It
            // cannot create a fresh socket or resolve the target hostname.
            agent = new https.Agent({ keepAlive: false, maxSockets: 1 });
            agent.createConnection = () => secure;
            try {
              providerRequest = https.request(target.url, { method, headers, agent, lookup: forbiddenLookup }, response => {
                if (ended) { response.destroy(); return; }
                stage = 'response';
                output = new PassThrough();
                // Consumers may reject status/content-type before reading. Keep
                // the sanitized stream's destruction safe in that case too.
                output.on('error', error => {
                  if (!ended) stop(error instanceof ProxyTransportError ? error.code : 'PROXY_REQUEST_FAILED');
                });
                output.once('close', () => { if (!ended && stage !== 'response-ended') stop('PROXY_REQUEST_FAILED'); });
                response.once('error', () => stop('PROXY_REQUEST_FAILED'));
                response.once('aborted', () => stop('PROXY_REQUEST_FAILED'));
                response.once('end', () => {
                  stage = 'response-ended'; ended = true; cleanupListeners();
                  agent.destroy();
                });
                response.pipe(output);
                settled = true;
                resolve({ statusCode: response.statusCode, headers: response.headers, stream: output });
              });
              providerRequest.once('error', () => stop('PROXY_REQUEST_FAILED'));
              providerRequest.end(body);
            } catch { stop('PROXY_REQUEST_FAILED'); }
          });
        } catch { stop('PROXY_TLS_FAILED'); }
      });
      connectRequest.end();
    } catch { stop('PROXY_CONNECT_FAILED'); }
  });
}

export async function proxyHttpsBufferRequest(options = {}, dependencies) {
  const { maxResponseBytes = 1048576 } = options;
  if (!Number.isSafeInteger(maxResponseBytes) || maxResponseBytes < 1) throw failure('NETWORK_REQUEST_INVALID');
  const response = await proxyHttpsRequest(options, dependencies);
  const declared = Number(response.headers['content-length']);
  if (Number.isFinite(declared) && declared > maxResponseBytes) {
    response.stream.destroy();
    throw failure('PROXY_RESPONSE_TOO_LARGE');
  }
  const chunks = [];
  let size = 0;
  try {
    for await (const chunk of response.stream) {
      size += chunk.length;
      if (size > maxResponseBytes) { response.stream.destroy(); throw failure('PROXY_RESPONSE_TOO_LARGE'); }
      chunks.push(chunk);
    }
  } catch (error) {
    throw error instanceof ProxyTransportError ? error : failure('PROXY_REQUEST_FAILED');
  }
  return { status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks, size) };
}
