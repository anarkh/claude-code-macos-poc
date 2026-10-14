// Real loopback CONNECT + TLS tests. No public DNS, provider, API key, CLI,
// Keychain, or host proxy configuration is used.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import dns from 'node:dns';
import { readFileSync } from 'node:fs';
import { once } from 'node:events';
import { NETWORK_POLICY_SCHEMA, ProxyTransportError, validateNetworkPolicy,
  proxyHttpsRequest, proxyHttpsBufferRequest } from './proxy-transport.mjs';

const FAKE_KEY = 'FAKE-local-proxy-test-key-NOT-VALID';
const CA = readFileSync(new URL('./fixtures/test-ca.pem', import.meta.url));
const CERT = readFileSync(new URL('./fixtures/test-server-cert.pem', import.meta.url));
const KEY = readFileSync(new URL('./fixtures/test-server-key.pem', import.meta.url));
const TEST = { testOnly: true, ca: CA, timeoutMs: 1500 };
const policy = port => ({ schema: NETWORK_POLICY_SCHEMA, proxyURL: `http://127.0.0.1:${port}`, dnsPolicy: 'proxy-only' });
const headers = { authorization: `Bearer ${FAKE_KEY}`, 'content-type': 'application/json' };
const body = JSON.stringify({ message: '中文・日本語 🧑‍💻' });

async function listen(server, host = '127.0.0.1') {
  server.listen(0, host);
  await once(server, 'listening');
  return server.address().port;
}

async function fixture(t, { mode = 'tunnel', proxyHost = '127.0.0.1', originHandler } = {}) {
  const sockets = new Set();
  const observed = { connects: [], origin: [], http: [], servernames: [], ciphertext: [] };
  const capture = socket => {
    sockets.add(socket);
    socket.on('error', () => {}); // Fixture-owned sockets may be deliberately destroyed.
    socket.once('close', () => sockets.delete(socket));
  };
  let resolveConnect;
  let resolveOrigin;
  const connected = new Promise(resolve => { resolveConnect = resolve; });
  const originReceived = new Promise(resolve => { resolveOrigin = resolve; });
  const origin = https.createServer({ key: KEY, cert: CERT }, async (request, response) => {
    const parts = [];
    for await (const chunk of request) parts.push(chunk);
    observed.origin.push({ url: request.url, method: request.method, headers: request.headers,
      body: Buffer.concat(parts).toString('utf8') });
    resolveOrigin();
    if (originHandler) { originHandler(request, response); return; }
    if (request.url === '/sse') {
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      response.write('event: message_start\ndata: {"type":"message_start"}\n\n');
      response.end('event: message_stop\ndata: {"type":"message_stop"}\n\n');
    } else if (request.url === '/redirect') {
      response.writeHead(307, { location: 'https://must-not-follow.invalid/private' });
      response.end('redirect');
    } else if (request.url === '/large') {
      response.writeHead(200, { 'content-type': 'application/json' }); response.end('界'.repeat(100));
    } else if (request.url === '/hold') {
      response.writeHead(200, { 'content-type': 'text/event-stream' }); response.write('data: partial\n\n');
    } else {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ choices: [{ message: { content: '中文译文' } }] }));
    }
  });
  origin.on('connection', capture);
  origin.on('secureConnection', socket => observed.servernames.push(socket.servername));
  origin.on('tlsClientError', () => {}); // Expected for certificate rejection tests.
  const originPort = await listen(origin);
  const proxy = http.createServer((request, response) => {
    observed.http.push({ url: request.url, headers: request.headers }); response.writeHead(405); response.end();
  });
  proxy.on('connection', capture);
  proxy.on('connect', (request, socket, head) => {
    observed.connects.push({ target: request.url, headers: request.headers });
    resolveConnect();
    if (mode === 'reject') {
      socket.end(`HTTP/1.1 403 Forbidden\r\nContent-Length: ${FAKE_KEY.length}\r\n\r\n${FAKE_KEY}`); return;
    }
    if (mode === 'disconnect') { socket.destroy(); return; }
    if (mode === 'malformed') { socket.end('THIS IS NOT HTTP\r\n\r\n'); return; }
    if (mode === 'oversized-header') { socket.end(`HTTP/1.1 200 Connection Established\r\nX-Fill: ${'x'.repeat(20000)}\r\n\r\n`); return; }
    if (mode === 'bad-head') { socket.end('HTTP/1.1 200 Connection Established\r\n\r\nNOT-TLS'); return; }
    if (mode === 'established-close') { socket.end('HTTP/1.1 200 Connection Established\r\n\r\n'); return; }
    if (mode === 'hang') return;
    if (mode === 'tls-hang') { socket.write('HTTP/1.1 200 Connection Established\r\n\r\n'); return; }
    const upstream = net.connect({ host: '127.0.0.1', port: originPort });
    capture(upstream);
    upstream.once('connect', () => {
      if (mode === 'split-header') {
        socket.write('HTTP/1.1 200 Connection ');
        setImmediate(() => socket.write('Established\r\n\r\n'));
      } else socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      socket.on('data', chunk => observed.ciphertext.push(chunk));
      socket.pipe(upstream); upstream.pipe(socket);
    });
  });
  const proxyPort = await listen(proxy, proxyHost);
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await Promise.all([new Promise(resolve => proxy.close(resolve)), new Promise(resolve => origin.close(resolve))]);
  });
  const network = proxyHost === '::1' ? { ...policy(proxyPort), proxyURL: `http://[::1]:${proxyPort}` } : policy(proxyPort);
  return { observed, connected, originReceived, network, url: route => `https://fixture.invalid:${originPort}${route}`,
    ipv6URL: route => `https://[2001:db8::1]:${originPort}${route}`, originPort };
}

async function withoutDNS(fn) {
  const calls = [];
  const methods = ['lookup', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCname', 'resolveTxt'];
  const originals = methods.map(name => [name, dns[name]]);
  const promiseOriginals = methods.filter(name => typeof dns.promises[name] === 'function').map(name => [name, dns.promises[name]]);
  const error = () => Object.assign(new Error('LOCAL_DNS_MUST_NOT_RUN'), { code: 'ENOTFOUND' });
  for (const [name] of originals) dns[name] = (hostname, ...args) => {
    calls.push({ method: name, hostname });
    const callback = args.at(-1);
    queueMicrotask(() => callback(error()));
  };
  for (const [name] of promiseOriginals) dns.promises[name] = async hostname => {
    calls.push({ method: `promises.${name}`, hostname }); throw error();
  };
  try {
    const result = await fn();
    assert.deepEqual(calls, [], 'All connections must use numeric loopback or an existing tunnel; target DNS is delegated to CONNECT.');
    return result;
  } finally {
    for (const [name, original] of originals) dns[name] = original;
    for (const [name, original] of promiseOriginals) dns.promises[name] = original;
  }
}

async function rejectsSafe(promise, expected) {
  const error = await promise.then(() => assert.fail('Expected proxy failure'), error => error);
  assert.ok(error instanceof ProxyTransportError);
  assert.match(error.code, /^[A-Z][A-Z0-9_]{1,63}$/);
  if (expected) assert.equal(error.code, expected);
  assert.equal(`${error.message} ${JSON.stringify(error)}`.includes(FAKE_KEY), false);
  return error;
}

const parameters = (f, route = '/json', changes = {}) => ({ url: f.url(route), network: f.network, headers, body, ...changes });

test('network policy accepts only explicit numeric IPv4 loopback HTTP proxy and proxy-only DNS', () => {
  for (const proxyURL of ['http://127.0.0.1:7890']) {
    const input = { ...policy(7890), proxyURL };
    assert.deepEqual(validateNetworkPolicy(input), input);
  }
});

test('missing and malformed network policy rejects before any connection', async () => {
  const invalid = [undefined, null, [], {}, { ...policy(7890), schema: 'unknown' },
    { ...policy(7890), dnsPolicy: 'direct' }, { ...policy(7890), extra: FAKE_KEY },
    ...['http://localhost:7890', 'http://example.invalid:7890', 'http://192.168.1.1:7890',
      'https://127.0.0.1:7890', 'socks5://127.0.0.1:7890', 'http://secret:password@127.0.0.1:7890',
      'http://127.0.0.1', 'http://127.0.0.1:0', 'http://127.0.0.1:7890/private',
      'http://127.0.0.1:7890?secret', 'http://127.0.0.1:7890#secret'].map(proxyURL => ({ ...policy(7890), proxyURL }))];
  for (const network of invalid) {
    assert.throws(() => validateNetworkPolicy(network), ProxyTransportError);
    await withoutDNS(() => rejectsSafe(proxyHttpsRequest({ url: 'https://fixture.invalid/json', network, headers, body }, TEST)));
  }
});

test('CONNECT carries target hostname and verified TLS carries authorization only inside the tunnel', async t => {
  const f = await fixture(t);
  const response = await withoutDNS(() => proxyHttpsBufferRequest(parameters(f), TEST));
  assert.equal(response.status, 200);
  assert.equal(JSON.parse(response.body).choices[0].message.content, '中文译文');
  assert.equal(f.observed.connects.length, 1);
  assert.equal(f.observed.connects[0].target, `fixture.invalid:${f.originPort}`);
  assert.equal(f.observed.connects[0].headers.authorization, undefined);
  assert.equal(f.observed.connects[0].headers['proxy-authorization'], undefined);
  assert.equal(f.observed.origin.length, 1);
  assert.equal(f.observed.origin[0].headers.authorization, `Bearer ${FAKE_KEY}`);
  assert.equal(f.observed.origin[0].headers.host, `fixture.invalid:${f.originPort}`);
  assert.equal(f.observed.origin[0].body, body);
  assert.deepEqual(f.observed.servernames, ['fixture.invalid']);
  assert.equal(Buffer.concat(f.observed.ciphertext).includes(Buffer.from(FAKE_KEY)), false);
  assert.deepEqual(f.observed.http, []);
});

test('SSE bytes stream through the same verified tunnel without local target resolution', async t => {
  const f = await fixture(t);
  const response = await withoutDNS(() => proxyHttpsRequest(parameters(f, '/sse'), TEST));
  const chunks = [];
  for await (const chunk of response.stream) chunks.push(chunk);
  assert.equal(response.statusCode, 200);
  assert.equal(response.headers['content-type'], 'text/event-stream');
  assert.match(Buffer.concat(chunks).toString('utf8'), /event: message_start/);
  assert.match(Buffer.concat(chunks).toString('utf8'), /event: message_stop/);
  assert.equal(f.observed.origin.length, 1);
});

test('fragmented CONNECT headers establish exactly one tunnel before TLS starts', async t => {
  const f = await fixture(t, { mode: 'split-header' });
  const response = await withoutDNS(() => proxyHttpsBufferRequest(parameters(f), TEST));
  assert.equal(response.status, 200);
  assert.equal(f.observed.connects.length, 1);
  assert.equal(f.observed.origin.length, 1);
});

test('ambient proxy and no_proxy variables cannot bypass the explicit App policy', async t => {
  const f = await fixture(t);
  const names = ['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'no_proxy'];
  const previous = names.map(name => [name, process.env[name]]);
  for (const name of names) process.env[name] = name.toLowerCase().includes('no_proxy') ? '*' : 'http://must-not-use.invalid:9999';
  try {
    const response = await withoutDNS(() => proxyHttpsBufferRequest(parameters(f), TEST));
    assert.equal(response.status, 200);
    assert.equal(f.observed.connects.length, 1);
    assert.equal(f.observed.origin.length, 1);
  } finally {
    for (const [name, value] of previous) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  }
});

test('IPv6 target authority is bracketed in CONNECT and verified against certificate IP SAN', async t => {
  const f = await fixture(t);
  const response = await withoutDNS(() => proxyHttpsBufferRequest(parameters(f, '/json', { url: f.ipv6URL('/json') }), TEST));
  assert.equal(response.status, 200);
  assert.equal(f.observed.connects[0].target, `[2001:db8::1]:${f.originPort}`);
  assert.equal(f.observed.origin[0].headers.host, `[2001:db8::1]:${f.originPort}`);
});

test('first-version unsupported IPv6 loopback proxy fails before DNS or any proxy request', async t => {
  const f = await fixture(t, { proxyHost: '::1' });
  await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest(parameters(f), TEST), 'NETWORK_POLICY_INVALID'));
  assert.deepEqual(f.observed.connects, []);
});

test('test CA is never automatically trusted on the production transport path', async t => {
  const f = await fixture(t);
  await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest(parameters(f))));
  assert.equal(f.observed.connects.length, 1);
  assert.deepEqual(f.observed.origin, []);
});

test('trusted CA still requires the target hostname to match the certificate', async t => {
  const f = await fixture(t);
  const url = f.url('/json').replace('fixture.invalid', 'wrong-host.invalid');
  await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest(parameters(f, '/json', { url }), TEST)));
  assert.equal(f.observed.connects[0].target, `wrong-host.invalid:${f.originPort}`);
  assert.deepEqual(f.observed.origin, []);
});

test('unsafe TLS options or non-test injection cannot weaken production trust', async t => {
  const f = await fixture(t);
  for (const overrides of [{ ca: CA }, { testOnly: false, ca: CA }, { testOnly: true, ca: CA, rejectUnauthorized: false },
    { testOnly: true, ca: CA, lookup: () => {} }]) {
    await rejectsSafe(proxyHttpsBufferRequest(parameters(f), overrides));
  }
  assert.deepEqual(f.observed.connects, []);
  assert.deepEqual(f.observed.origin, []);
});

for (const mode of ['reject', 'disconnect', 'malformed', 'oversized-header', 'bad-head', 'established-close']) {
  test(`proxy ${mode} fails closed with no direct lookup or authorization on CONNECT`, async t => {
    const f = await fixture(t, { mode });
    await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest(parameters(f), TEST)));
    assert.equal(f.observed.connects.length, 1);
    assert.equal(f.observed.connects[0].headers.authorization, undefined);
    assert.deepEqual(f.observed.origin, []);
  });
}

test('unavailable numeric proxy fails closed without target lookup', async () => {
  const server = http.createServer();
  const port = await listen(server);
  await new Promise(resolve => server.close(resolve));
  await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest({ url: 'https://fixture.invalid:443/json', network: policy(port), headers, body }, TEST)));
});

for (const mode of ['hang', 'tls-hang']) {
  test(`proxy ${mode} respects a bounded timeout with no direct fallback`, async t => {
    const f = await fixture(t, { mode });
    const started = Date.now();
    await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest(parameters(f), { ...TEST, timeoutMs: 80 })));
    assert.ok(Date.now() - started < 1500);
    assert.equal(f.observed.connects.length, 1);
    assert.deepEqual(f.observed.origin, []);
  });
}

test('cancellation while CONNECT is pending destroys the tunnel and never opens a direct socket', async t => {
  const f = await fixture(t, { mode: 'hang' });
  const abort = new AbortController();
  await withoutDNS(async () => {
    const pending = proxyHttpsBufferRequest(parameters(f, '/json', { signal: abort.signal }), TEST);
    await f.connected;
    abort.abort(new Error(`private reason ${FAKE_KEY}`));
    await rejectsSafe(pending);
  });
  assert.equal(f.observed.connects.length, 1);
  assert.deepEqual(f.observed.origin, []);
});

test('pre-aborted caller never contacts the proxy or DNS', async t => {
  const f = await fixture(t);
  const abort = new AbortController(); abort.abort();
  await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest(parameters(f, '/json', { signal: abort.signal }), TEST)));
  assert.deepEqual(f.observed.connects, []);
  assert.deepEqual(f.observed.origin, []);
});

test('cancellation during SSE rejects the response stream and closes the connection', async t => {
  const f = await fixture(t);
  const abort = new AbortController();
  await withoutDNS(async () => {
    const response = await proxyHttpsRequest(parameters(f, '/hold', { signal: abort.signal }), TEST);
    const reading = (async () => { for await (const chunk of response.stream) assert.ok(chunk.length); })();
    abort.abort(new Error(`private stream reason ${FAKE_KEY}`));
    await rejectsSafe(reading);
  });
  assert.equal(f.observed.origin.length, 1);
});

test('timeout continues to cover response-body stalls after TLS and headers', async t => {
  const f = await fixture(t);
  const started = Date.now();
  await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest(parameters(f, '/hold'), { ...TEST, timeoutMs: 100 })));
  assert.ok(Date.now() - started < 1500);
  assert.equal(f.observed.origin.length, 1);
});

test('redirect response is returned once and never follows another host', async t => {
  const f = await fixture(t);
  const response = await withoutDNS(() => proxyHttpsBufferRequest(parameters(f, '/redirect'), TEST));
  assert.equal(response.status, 307);
  assert.equal(response.headers.location, 'https://must-not-follow.invalid/private');
  assert.equal(f.observed.origin.length, 1);
  assert.equal(f.observed.connects.length, 1);
});

test('buffer response limits count UTF-8 bytes and sanitize failures', async t => {
  const f = await fixture(t);
  await withoutDNS(() => rejectsSafe(proxyHttpsBufferRequest(parameters(f, '/large', { maxResponseBytes: 100 }), TEST)));
  assert.equal(f.observed.origin.length, 1);
});

test('complete large response survives TLS peer closure while a slow consumer applies backpressure', async t => {
  const payload = Buffer.alloc(512 * 1024 + 37, 0x5a);
  const f = await fixture(t, { originHandler: (_request, response) => {
    response.writeHead(200, { 'content-type': 'application/octet-stream',
      'content-length': payload.length, connection: 'close' });
    response.end(payload);
  } });
  await withoutDNS(async () => {
    const response = await proxyHttpsRequest(parameters(f, '/large-file'), TEST);
    assert.equal(response.statusCode, 200);
    const chunks = [];
    for await (const chunk of response.stream) {
      chunks.push(chunk);
      // Like the updater's awaited disk writes, this pauses the HTTP reader
      // after TLS already has the complete closing response in its buffer.
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert.deepEqual(Buffer.concat(chunks), payload);
  });
  assert.equal(f.observed.connects.length, 1);
  assert.equal(f.observed.origin.length, 1);
});

test('truncated Content-Length still rejects a slow response consumer after TLS peer closure', async t => {
  const partial = Buffer.alloc(192 * 1024, 0x52);
  const f = await fixture(t, { originHandler: (_request, response) => {
    response.writeHead(200, { 'content-type': 'application/octet-stream',
      'content-length': partial.length + 1, connection: 'close' });
    response.end(partial);
  } });
  const started = Date.now();
  await withoutDNS(async () => {
    const response = await proxyHttpsRequest(parameters(f, '/truncated-file'), TEST);
    const reading = (async () => {
      for await (const chunk of response.stream) {
        assert.ok(chunk.length);
        await new Promise(resolve => setTimeout(resolve, 5));
      }
    })();
    await rejectsSafe(reading, 'PROXY_REQUEST_FAILED');
  });
  assert.ok(Date.now() - started < 1500, 'HTTP truncation must fail without waiting for the timeout.');
  assert.equal(f.observed.connects.length, 1);
  assert.equal(f.observed.origin.length, 1);
});
