// Loopback-only updater coverage. The fixture never starts downloaded code and
// uses no public DNS, provider, real credentials, or host proxy configuration.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import dns from 'node:dns';
import os from 'node:os';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { once } from 'node:events';
import { Readable } from 'node:stream';
import { MAX_METADATA_BYTES, REQUEST_SCHEMA, UPDATE_ERROR_CODES, UpdateFailure, runUpdateRequest, validateFeedURL } from './client.mjs';
import { runStdio } from './stdio.mjs';

const CA = readFileSync(new URL('../network/fixtures/test-ca.pem', import.meta.url));
const CERT = readFileSync(new URL('../network/fixtures/test-server-cert.pem', import.meta.url));
const KEY = readFileSync(new URL('../network/fixtures/test-server-key.pem', import.meta.url));
const TEST_OPTIONS = { testOnly: true, transportDependencies: { testOnly: true, ca: CA, timeoutMs: 1500 } };
const FAKE_SECRET = 'FAKE_update_test_credential_DO_NOT_USE';
const DISK = 'Resources/Runtime/host/text-runtime/images/guest.raw';
const HELPER = 'Helpers/vm-text-runtime';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const signingKey = generateKeyPairSync('ed25519');
const publicKeyBytes = signingKey.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
const policy = port => ({ schema: 'app-network-policy/v1', proxyURL: `http://127.0.0.1:${port}`, dnsPolicy: 'proxy-only' });

// Include the native importer's required paths, with internally consistent
// version/digest metadata. These are tiny fixtures, never runnable VM images.
const requiredPaths = [
  HELPER, 'Resources/Runtime/sdk/vm-text-chat.mjs', 'Resources/Runtime/sdk/vm-text-smoke.mjs',
  'Resources/Runtime/sdk/deepseek-text-chat.mjs', 'Resources/Runtime/sdk/deepseek-text-smoke.mjs',
  'Resources/Runtime/sdk/owned-run-directory.mjs', 'Resources/Runtime/sdk/package.json',
  'Resources/Runtime/translation/stdio.mjs', 'Resources/Runtime/translation/client.mjs',
  'Resources/Runtime/translation/pipeline.mjs', 'Resources/Runtime/translation/protected-text.mjs',
  'Resources/Runtime/translation/errors.mjs', 'Resources/Runtime/network/proxy-transport.mjs',
  'Resources/Runtime/runtime/profile.mjs', 'Resources/Runtime/host/text-runtime/launch.py',
  'Resources/Runtime/host/text-runtime/common.py', 'Resources/Runtime/host/text-runtime/runtime-config.json',
  'Resources/Runtime/host/text-runtime/images/base.json', 'Resources/Runtime/host/text-runtime/images/kernel',
  'Resources/Runtime/host/text-runtime/images/initrd', DISK,
  'Resources/Runtime/guest/text-runtime/runtime.mjs', 'Resources/Runtime/guest/text-runtime/bootstrap.sh',
  'Resources/Runtime/guest/text-runtime/supervisor.py',
  'Resources/Runtime/sdk/url+hash#?.mjs',
];

function packageFixture(mutator = () => {}) {
  const payloads = new Map(requiredPaths.map(name => [name, Buffer.from(`local fixture: ${name}\n`)]));
  payloads.set(HELPER, Buffer.from('#!/bin/sh\n# Test bytes only; do not execute.\nexit 0\n'));
  payloads.set(DISK, Buffer.alloc(192 * 1024, 0x52));
  const manifest = {
    schema: 'claude-runtime-package/v1', version: '0.12.1', cliVersion: '2.1.295', sdkVersion: '0.3.295',
    nodeVersion: '26.7.0', hostProtocol: 1, platform: 'macOS-arm64', minimumOSVersion: '14.0.0',
    minimumAppVersion: '0.12.0', maximumAppVersionExclusive: '0.13.0', files: [],
  };
  payloads.set('Resources/Runtime/sdk/package.json', Buffer.from(JSON.stringify({
    dependencies: { '@anthropic-ai/claude-agent-sdk': manifest.sdkVersion },
  })));
  payloads.set('Resources/Runtime/host/text-runtime/runtime-config.json', Buffer.from(JSON.stringify({
    schema: 'claude-vm-runtime/v1', image_dir: 'images', runner: '../../../../Helpers/vm-text-runtime',
    guest_runtime_dir: '../../guest/text-runtime', python: '/usr/bin/python3',
  })));
  payloads.set('Resources/Runtime/host/text-runtime/images/base.json', Buffer.from(JSON.stringify({
    schema: 'claude-text-vm-base/v1', prepared: true, no_user_data: true, network_devices: 0,
    directory_shares: 0, node_version: manifest.nodeVersion, sdk_version: manifest.sdkVersion,
    cli_version: manifest.cliVersion, disk_sha256: sha(payloads.get(DISK)),
    kernel_sha256: sha(payloads.get('Resources/Runtime/host/text-runtime/images/kernel')),
    initrd_sha256: sha(payloads.get('Resources/Runtime/host/text-runtime/images/initrd')),
    disk_bytes: payloads.get(DISK).length,
  })));
  manifest.files = [...payloads].map(([name, bytes]) => ({
    path: name, size: bytes.length, sha256: sha(bytes), executable: name === HELPER,
  }));
  mutator(manifest, payloads);
  const manifestBytes = Buffer.from(`${JSON.stringify(manifest, null, '\t')}\n`);
  const signatureBytes = Buffer.from(`${JSON.stringify({ schema: 'claude-runtime-signature/v1',
    keyID: sha(publicKeyBytes), signature: sign(null, manifestBytes, signingKey.privateKey).toString('base64'),
  }, null, 2)}\n`);
  const manifestBase64 = manifestBytes.toString('base64');
  const signatureBase64 = signatureBytes.toString('base64');
  const channelBytes = Buffer.from(` \n${JSON.stringify({ schema: 'claude-runtime-channel/v1', manifestBase64, signatureBase64 }, null, '\t')}\n\t`);
  return { manifest, payloads, manifestBytes, signatureBytes, manifestBase64, signatureBase64, channelBytes,
    id: `runtime-${sha(manifestBytes)}` };
}

async function listen(server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return server.address().port;
}

async function fixture(t, { data = packageFixture(), mode = 'good', channelBytes = data.channelBytes,
  proxyMode = 'tunnel', responseHandler } = {}) {
  const sockets = new Set();
  const proxySockets = new Set();
  const observed = { connects: [], requests: [], plainHTTP: [], servernames: [], closedResponses: 0 };
  const capture = socket => {
    sockets.add(socket);
    socket.on('error', () => {}); // Fixture-owned sockets are deliberately destroyed during failure tests.
    socket.once('close', () => sockets.delete(socket));
  };
  let resolveConnected, resolveHeld;
  const connected = new Promise(resolve => { resolveConnected = resolve; });
  const held = new Promise(resolve => { resolveHeld = resolve; });
  const routes = new Map([...data.payloads].map(([name, bytes]) => [
    `/updates/packages/${data.id}/Contents/${name.split('/').map(encodeURIComponent).join('/')}`, bytes,
  ]));
  const origin = https.createServer({ key: KEY, cert: CERT }, (request, response) => {
    observed.requests.push({ method: request.method, url: request.url, headers: request.headers });
    response.once('close', () => { observed.closedResponses++; });
    if (responseHandler?.(request, response)) return;
    if (request.url === '/updates/channel.json') {
      if (mode === 'channel-redirect') {
        response.writeHead(302, { location: 'https://must-not-follow.invalid/channel.json' }); response.end(FAKE_SECRET); return;
      }
      response.writeHead(200, { 'content-type': 'application/json', 'content-length': channelBytes.length,
        connection: 'close' }); response.end(channelBytes); return;
    }
    const bytes = routes.get(request.url);
    if (bytes === undefined) { response.writeHead(404); response.end(FAKE_SECRET); return; }
    // Fault the first payload so every failure proves later files were skipped.
    const isFirst = request.url === routes.keys().next().value;
    if (isFirst && mode === 'payload-redirect') {
      response.writeHead(307, { location: 'https://must-not-follow.invalid/private' }); response.end(FAKE_SECRET); return;
    }
    if (isFirst && mode === 'http-failure') { response.writeHead(503); response.end(FAKE_SECRET); return; }
    if (isFirst && mode === 'compressed') {
      response.writeHead(200, { 'content-encoding': 'gzip' }); response.end(bytes); return;
    }
    if (isFirst && mode === 'hold') {
      response.writeHead(200, { 'content-length': bytes.length, connection: 'close' });
      response.write(bytes.subarray(0, 1)); resolveHeld(); return;
    }
    if (isFirst && mode === 'oversize') {
      response.writeHead(200, { connection: 'close' });
      response.write(bytes); response.end(Buffer.from('extra byte')); return;
    }
    if (isFirst && mode === 'truncated') {
      response.writeHead(200, { connection: 'close' }); response.end(bytes.subarray(0, bytes.length - 1)); return;
    }
    if (isFirst && mode === 'declared-oversize') {
      response.writeHead(200, { 'content-length': bytes.length + 1, connection: 'close' }); response.end(bytes); return;
    }
    const body = isFirst && mode === 'corrupt' ? Buffer.from(bytes) : bytes;
    if (isFirst && mode === 'corrupt') body[0] ^= 0xff;
    response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': body.length,
      connection: 'close' });
    // Chunk boundaries differ from both file lengths and filesystem writes.
    response.write(body.subarray(0, 13));
    setImmediate(() => response.end(body.subarray(13)));
  });
  origin.on('connection', capture);
  origin.on('secureConnection', socket => observed.servernames.push(socket.servername));
  origin.on('tlsClientError', () => {}); // Intentional CA/hostname rejection.
  const originPort = await listen(origin);
  const proxy = http.createServer((request, response) => {
    observed.plainHTTP.push({ url: request.url, headers: request.headers }); response.writeHead(405); response.end();
  });
  proxy.on('connection', socket => {
    capture(socket); proxySockets.add(socket);
    socket.once('close', () => proxySockets.delete(socket));
    socket.on('end', () => socket.destroy()); // Close the proxy side after a client tunnel FIN.
  });
  proxy.on('connect', (request, socket, head) => {
    observed.connects.push({ target: request.url, headers: request.headers }); resolveConnected();
    if (proxyMode === 'hang') { socket.resume(); return; }
    if (proxyMode === 'reject') {
      socket.end(`HTTP/1.1 403 Forbidden\r\nContent-Length: ${FAKE_SECRET.length}\r\n\r\n${FAKE_SECRET}`); return;
    }
    const upstream = net.connect({ host: '127.0.0.1', port: originPort }); capture(upstream);
    socket.once('close', () => upstream.destroy());
    // pipe() pauses its source when the destination disappears. Keep reading
    // the client's FIN after an origin has sent its complete closing response.
    upstream.once('close', () => socket.resume());
    upstream.once('connect', () => {
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      socket.pipe(upstream); upstream.pipe(socket);
    });
  });
  const proxyPort = await listen(proxy);
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await Promise.all([new Promise(resolve => proxy.close(resolve)), new Promise(resolve => origin.close(resolve))]);
  });
  return { data, observed, sockets: proxySockets, connected, held, routes, network: policy(proxyPort), originPort,
    feedURL: `https://fixture.invalid:${originPort}/updates/channel.json` };
}

async function scratch(t) {
  const created = await mkdtemp(path.join(os.tmpdir(), 'runtime-update-test-'));
  const root = await realpath(created); // macOS /var may itself be a symlink.
  await chmod(root, 0o700);
  t.after(() => rm(root, { recursive: true, force: true }));
  return { root, packageDirectory: path.join(root, 'download.clauderuntime') };
}

function checkRequest(f, changes = {}) {
  return { schema: REQUEST_SCHEMA, operation: 'check', feedURL: f.feedURL, network: f.network, ...changes };
}
function downloadRequest(f, destination, changes = {}) {
  return { ...checkRequest(f), operation: 'download', manifestBase64: f.data.manifestBase64,
    signatureBase64: f.data.signatureBase64, packageDirectory: destination, ...changes };
}

async function rejectsSafe(promise, code) {
  const error = await promise.then(() => assert.fail('Expected updater failure'), error => error);
  assert.ok(error instanceof UpdateFailure);
  assert.ok(UPDATE_ERROR_CODES.includes(error.code));
  assert.equal(error.message, error.code);
  if (code) assert.equal(error.code, code);
  assert.equal(`${error.message} ${JSON.stringify(error)}`.includes(FAKE_SECRET), false);
  return error;
}

async function withoutDNS(fn) {
  const calls = [];
  const methods = ['lookup', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCname', 'resolveTxt'];
  const originals = methods.map(name => [name, dns[name]]);
  const promises = methods.filter(name => typeof dns.promises[name] === 'function').map(name => [name, dns.promises[name]]);
  for (const [name] of originals) dns[name] = (hostname, ...args) => {
    calls.push({ name, hostname });
    queueMicrotask(() => args.at(-1)(Object.assign(new Error('LOCAL_DNS_MUST_NOT_RUN'), { code: 'ENOTFOUND' })));
  };
  for (const [name] of promises) dns.promises[name] = async hostname => {
    calls.push({ name, hostname }); throw new Error('LOCAL_DNS_MUST_NOT_RUN');
  };
  try {
    const result = await fn();
    assert.deepEqual(calls, [], 'Target DNS belongs to CONNECT; updater must never resolve or fall back directly.');
    return result;
  } finally {
    for (const [name, original] of originals) dns[name] = original;
    for (const [name, original] of promises) dns.promises[name] = original;
  }
}

async function waitFor(predicate, message) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.fail(message);
}

async function assertPrivateTree(directory) {
  const metadata = await lstat(directory);
  assert.ok(metadata.isDirectory()); assert.equal(metadata.mode & 0o777, 0o700);
  for (const name of await readdir(directory)) {
    const filename = path.join(directory, name), info = await lstat(filename);
    assert.equal(info.isSymbolicLink(), false);
    if (info.isDirectory()) await assertPrivateTree(filename);
    else { assert.ok(info.isFile()); assert.ok([0o400, 0o500].includes(info.mode & 0o777)); assert.equal(info.nlink, 1); }
  }
}

test('feed URL requires an explicit HTTPS channel.json location without credentials or traversal', () => {
  const good = 'https://fixture.invalid:8443/updates/channel.json';
  assert.equal(validateFeedURL(good).href, good);
  for (const url of [undefined, '', 'http://fixture.invalid/channel.json', ' https://fixture.invalid/channel.json',
    'https://fixture.invalid/channel.json ', 'https://user:password@fixture.invalid/channel.json',
    'https://fixture.invalid/updates/channel.json?key=secret', 'https://fixture.invalid/channel.json#fragment',
    'https://fixture.invalid/stable.json', 'https://fixture.invalid/a/../channel.json',
    'https://fixture.invalid/%2e%2e/channel.json', 'https://fixture.invalid/a%2fb/channel.json',
    'https://fixture.invalid/a%5cb/channel.json', 'https://fixture.invalid/a%20b/channel.json']) {
    assert.throws(() => validateFeedURL(url), error => error instanceof UpdateFailure && error.code === 'UPDATE_INVALID_FEED');
  }
});

test('check preserves the exact channel bytes through verified TLS and proxy-only DNS', async t => {
  const f = await fixture(t);
  const events = [];
  const terminal = await withoutDNS(() => runUpdateRequest(checkRequest(f), event => events.push(event), TEST_OPTIONS));
  assert.deepEqual(terminal, { type: 'checked', channelBase64: f.data.channelBytes.toString('base64') });
  assert.deepEqual(Buffer.from(terminal.channelBase64, 'base64'), f.data.channelBytes);
  assert.deepEqual(events, []);
  assert.equal(f.observed.connects.length, 1);
  assert.equal(f.observed.connects[0].target, `fixture.invalid:${f.originPort}`);
  assert.deepEqual(f.observed.servernames, ['fixture.invalid']);
  assert.equal(f.observed.requests[0].url, '/updates/channel.json');
  assert.equal(f.observed.requests[0].method, 'GET');
  assert.deepEqual(f.observed.plainHTTP, []);
});

test('download streams every signed file to deterministic encoded URLs and preserves signed metadata', async t => {
  const f = await fixture(t), destination = await scratch(t), events = [];
  const terminal = await withoutDNS(() => runUpdateRequest(downloadRequest(f, destination.packageDirectory),
    event => events.push(event), TEST_OPTIONS));
  assert.deepEqual(terminal, { type: 'downloaded' });
  assert.deepEqual(f.observed.requests.map(request => request.url), [...f.routes.keys()]);
  assert.ok(f.observed.requests.some(request => request.url.endsWith('/url%2Bhash%23%3F.mjs')));
  assert.equal(f.observed.connects.length, f.data.manifest.files.length);
  assert.ok(f.observed.connects.every(request => request.target === `fixture.invalid:${f.originPort}`));
  assert.deepEqual(await readFile(path.join(destination.packageDirectory, 'manifest.json')), f.data.manifestBytes);
  assert.deepEqual(await readFile(path.join(destination.packageDirectory, 'signature.json')), f.data.signatureBytes);
  for (const file of f.data.manifest.files) {
    const filename = path.join(destination.packageDirectory, 'Contents', file.path);
    assert.deepEqual(await readFile(filename), f.data.payloads.get(file.path));
    assert.equal((await lstat(filename)).mode & 0o777, file.executable ? 0o500 : 0o400);
  }
  await assertPrivateTree(destination.packageDirectory);
  assert.ok(events.length >= 2);
  assert.ok(events.every(event => event.type === 'progress' && event.phase === 'download' &&
    Number.isFinite(event.fraction) && event.fraction >= 0 && event.fraction <= 1));
  assert.equal(events[0].fraction, 0); assert.equal(events.at(-1).fraction, 1);
  assert.ok(events.every((event, index) => index === 0 || event.fraction >= events[index - 1].fraction));
});

test('ambient proxy bypass and provider credentials never enter updater requests or CONNECT', async t => {
  const f = await fixture(t);
  const names = ['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'no_proxy',
    'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_AUTH_TOKEN'];
  const previous = names.map(name => [name, process.env[name]]);
  for (const name of names) process.env[name] = name.toLowerCase().includes('no_proxy') ? '*' : FAKE_SECRET;
  try {
    await withoutDNS(() => runUpdateRequest(checkRequest(f), () => {}, TEST_OPTIONS));
    for (const request of [...f.observed.connects, ...f.observed.requests]) {
      assert.equal(request.headers.authorization, undefined);
      assert.equal(request.headers['proxy-authorization'], undefined);
      assert.equal(request.headers.cookie, undefined);
      assert.equal(JSON.stringify(request).includes(FAKE_SECRET), false);
    }
    assert.equal(f.observed.connects.length, 1); assert.deepEqual(f.observed.plainHTTP, []);
  } finally {
    for (const [name, value] of previous) { if (value === undefined) delete process.env[name]; else process.env[name] = value; }
  }
});

for (const [mode, code] of [['corrupt', 'UPDATE_DOWNLOAD_HASH'], ['truncated', 'UPDATE_DOWNLOAD_SIZE'],
  ['oversize', 'UPDATE_DOWNLOAD_SIZE'], ['declared-oversize', 'UPDATE_DOWNLOAD_SIZE'],
  ['payload-redirect', 'UPDATE_REDIRECT_REFUSED'], ['http-failure', 'UPDATE_HTTP_FAILED'],
  ['compressed', 'UPDATE_DOWNLOAD_INVALID']]) {
  test(`download ${mode} fails closed before another file or a success event`, async t => {
    const f = await fixture(t, { mode }), destination = await scratch(t), events = [];
    await withoutDNS(() => rejectsSafe(runUpdateRequest(downloadRequest(f, destination.packageDirectory),
      event => events.push(event), TEST_OPTIONS), code));
    assert.equal(f.observed.requests.length, 1); assert.equal(f.observed.connects.length, 1);
    assert.equal(events.some(event => event.type === 'downloaded' || event.fraction === 1), false);
    await waitFor(() => f.sockets.size === 0, 'Failed download must close its CONNECT/TLS sockets.');
  });
}

test('channel redirects are refused without contacting their destination', async t => {
  const f = await fixture(t, { mode: 'channel-redirect' });
  await withoutDNS(() => rejectsSafe(runUpdateRequest(checkRequest(f), () => {}, TEST_OPTIONS), 'UPDATE_REDIRECT_REFUSED'));
  assert.equal(f.observed.connects.length, 1); assert.equal(f.observed.requests.length, 1);
});

test('channel bytes are bounded before JSON parsing and metadata errors are sanitized', async t => {
  const oversized = await fixture(t, { channelBytes: Buffer.alloc(MAX_METADATA_BYTES + 1, 0x20) });
  await rejectsSafe(runUpdateRequest(checkRequest(oversized), () => {}, TEST_OPTIONS), 'UPDATE_METADATA_TOO_LARGE');
  const invalidChannels = [Buffer.from('{broken'), Buffer.from([0xff, 0xfe]),
    Buffer.from(JSON.stringify({ schema: 'claude-runtime-channel/v1', manifestBase64: 'not-base64', signatureBase64: 'no' })),
    Buffer.from(JSON.stringify({ schema: 'claude-runtime-channel/v1', manifestBase64: packageFixture().manifestBase64,
      signatureBase64: packageFixture().signatureBase64, authorization: FAKE_SECRET }))];
  for (const channelBytes of invalidChannels) {
    const f = await fixture(t, { channelBytes });
    await rejectsSafe(runUpdateRequest(checkRequest(f), () => {}, TEST_OPTIONS));
    assert.equal(f.observed.requests.length, 1);
  }
});

test('missing network policy and unrecognized request fields reject before any connection', async t => {
  const f = await fixture(t);
  const invalid = [undefined, null, {}, { ...checkRequest(f), schema: 'unknown' },
    { ...checkRequest(f), operation: 'install' }, { ...checkRequest(f), network: undefined },
    { ...checkRequest(f), network: { ...f.network, dnsPolicy: 'direct' } },
    { ...checkRequest(f), network: { ...f.network, proxyURL: 'http://localhost:7890' } },
    { ...checkRequest(f), authorization: FAKE_SECRET },
    { ...checkRequest(f), transportDependencies: TEST_OPTIONS.transportDependencies },
    { ...checkRequest(f), testOnly: true }];
  for (const request of invalid) await withoutDNS(() => rejectsSafe(runUpdateRequest(request, () => {}, TEST_OPTIONS)));
  assert.deepEqual(f.observed.connects, []); assert.deepEqual(f.observed.requests, []);
});

test('test transport dependencies require trusted module options and cannot weaken TLS', async t => {
  const f = await fixture(t);
  for (const options of [{ transportDependencies: TEST_OPTIONS.transportDependencies },
    { testOnly: false, transportDependencies: TEST_OPTIONS.transportDependencies },
    { testOnly: true, transportDependencies: { ...TEST_OPTIONS.transportDependencies, rejectUnauthorized: false } },
    { testOnly: true, transportDependencies: { ...TEST_OPTIONS.transportDependencies, lookup: () => {} } },
    { ...TEST_OPTIONS, ca: CA }]) {
    await rejectsSafe(runUpdateRequest(checkRequest(f), () => {}, options));
  }
  assert.deepEqual(f.observed.connects, []);
});

test('production stdin cannot inject a CA, TLS bypass or ambient credential into the updater', async t => {
  const f = await fixture(t);
  for (const changes of [{ testOnly: true }, { ca: CA.toString('utf8') },
    { rejectUnauthorized: false }, { transportDependencies: { testOnly: true, ca: CA.toString('utf8') } },
    { ANTHROPIC_API_KEY: FAKE_SECRET }]) {
    const events = [];
    const terminal = await withoutDNS(() => runStdio({
      input: Readable.from([JSON.stringify(checkRequest(f, changes))]), emit: event => events.push(event),
    }));
    assert.deepEqual(terminal, { type: 'error', code: 'UPDATE_INVALID_REQUEST' });
    assert.deepEqual(events, [terminal]);
    assert.equal(JSON.stringify(events).includes(FAKE_SECRET), false);
  }
  assert.deepEqual(f.observed.connects, []); assert.deepEqual(f.observed.requests, []);
});

test('production TLS never trusts the fixture CA and a trusted CA still checks hostname', async t => {
  const f = await fixture(t);
  await withoutDNS(() => rejectsSafe(runUpdateRequest(checkRequest(f)), 'UPDATE_NETWORK_FAILED'));
  await withoutDNS(() => rejectsSafe(runUpdateRequest(checkRequest(f, {
    feedURL: f.feedURL.replace('fixture.invalid', 'wrong-host.invalid'),
  }), () => {}, TEST_OPTIONS), 'UPDATE_NETWORK_FAILED'));
  assert.equal(f.observed.connects.length, 2); assert.deepEqual(f.observed.requests, []);
});

test('invalid manifest paths, links-as-paths, case collisions and size bounds fail before networking', async t => {
  const destination = await scratch(t);
  const mutations = [
    manifest => { manifest.files[0].path = '../outside'; },
    manifest => { manifest.files[0].path = 'Helpers/../outside'; },
    manifest => { manifest.files[0].path = 'Helpers//outside'; },
    manifest => { manifest.files[0].path = '/Helpers/outside'; },
    manifest => { manifest.files[0].path = 'Helpers/outside\\secret'; },
    manifest => { manifest.files[0].path = 'Helpers/outside%2fsecret'; },
    manifest => { manifest.files[0].path = 'Helpers/file with space'; },
    manifest => { manifest.files[0].path = 'Helpers/' + 'x'.repeat(129); },
    manifest => { manifest.files.push({ ...manifest.files[0] }); },
    manifest => { manifest.files.push({ ...manifest.files[0], path: 'Helpers/VM-TEXT-RUNTIME' }); },
    manifest => { manifest.files.push({ ...manifest.files[0], path: 'helpers/other' }); },
    manifest => { manifest.files.push({ ...manifest.files[0], path: 'Resources/Runtime/sdk' }); },
    manifest => { manifest.files.push({ ...manifest.files[0], path: 'Resources/Runtime/SDK/other.mjs' }); },
    manifest => { manifest.files[0].size = -1; },
    manifest => { manifest.files[0].size = 128 * 1024 ** 2 + 1; },
    manifest => { manifest.files.find(file => file.path === DISK).size = 10 * 1024 ** 3 + 1; },
    manifest => { manifest.files[0].sha256 = 'A'.repeat(64); },
    manifest => { manifest.files[0].executable = false; },
    manifest => { manifest.files.find(file => file.path === DISK).executable = true; },
    manifest => { manifest.files[0].url = `https://${FAKE_SECRET}.invalid/private`; },
    manifest => { manifest.files = Array.from({ length: 4097 }, (_, index) => ({
      ...manifest.files[0], path: `Helpers/fixture-${index}`,
    })); },
    manifest => { manifest.files.find(file => file.path === DISK).size = 10 * 1024 ** 3;
      for (let index = 0; index < 17; index++) manifest.files.push({ ...manifest.files[0],
        path: `Helpers/total-${index}`, size: 128 * 1024 ** 2 }); },
  ];
  for (const mutate of mutations) {
    const f = await fixture(t, { data: packageFixture(mutate) });
    await withoutDNS(() => rejectsSafe(runUpdateRequest(downloadRequest(f, destination.packageDirectory),
      () => {}, TEST_OPTIONS), 'UPDATE_PACKAGE_INVALID'));
    assert.deepEqual(f.observed.connects, []); assert.deepEqual(f.observed.requests, []);
  }
  await assert.rejects(lstat(destination.packageDirectory), { code: 'ENOENT' });
});

test('malformed signatures and noncanonical base64 fail before package creation or networking', async t => {
  const f = await fixture(t), destination = await scratch(t);
  const signature = JSON.parse(f.data.signatureBytes);
  const changes = [
    { manifestBase64: `${f.data.manifestBase64}\n` }, { manifestBase64: '' },
    { signatureBase64: Buffer.from(JSON.stringify({ ...signature, signature: Buffer.alloc(63).toString('base64') })).toString('base64') },
    { signatureBase64: Buffer.from(JSON.stringify({ ...signature, keyID: 'BAD' })).toString('base64') },
    { signatureBase64: Buffer.from(JSON.stringify({ ...signature, extra: FAKE_SECRET })).toString('base64') },
  ];
  for (const change of changes) await rejectsSafe(runUpdateRequest(downloadRequest(f, destination.packageDirectory, change),
    () => {}, TEST_OPTIONS), 'UPDATE_PACKAGE_INVALID');
  assert.deepEqual(f.observed.connects, []);
  await assert.rejects(lstat(destination.packageDirectory), { code: 'ENOENT' });
});

test('staging rejects existing paths, symlink ancestors and public parents without changing outside files', async t => {
  const f = await fixture(t), destination = await scratch(t);
  const outside = path.join(destination.root, 'outside'); await mkdir(outside, { mode: 0o700 });
  const sentinel = path.join(outside, 'keep.txt'); await writeFile(sentinel, FAKE_SECRET, { mode: 0o600 });
  const existing = path.join(destination.root, 'existing.clauderuntime'); await mkdir(existing, { mode: 0o700 });
  await writeFile(path.join(existing, 'keep.txt'), FAKE_SECRET);
  const linkedParent = path.join(destination.root, 'linked-parent'); await symlink(outside, linkedParent);
  const linkedPackage = path.join(destination.root, 'linked.clauderuntime'); await symlink(outside, linkedPackage);
  const publicParent = path.join(destination.root, 'public-parent'); await mkdir(publicParent, { mode: 0o755 });
  for (const packageDirectory of [existing, linkedPackage, path.join(linkedParent, 'download.clauderuntime'),
    path.join(publicParent, 'download.clauderuntime'), 'relative.clauderuntime', path.join(destination.root, 'wrong-extension'),
    `${destination.root}/child/../download.clauderuntime`]) {
    await withoutDNS(() => rejectsSafe(runUpdateRequest(downloadRequest(f, packageDirectory), () => {}, TEST_OPTIONS),
      'UPDATE_STAGING_INVALID'));
  }
  assert.equal(await readFile(sentinel, 'utf8'), FAKE_SECRET);
  assert.equal(await readFile(path.join(existing, 'keep.txt'), 'utf8'), FAKE_SECRET);
  assert.deepEqual(f.observed.connects, []); assert.deepEqual(await readdir(outside), ['keep.txt']);
});

test('cancellation during a streamed download closes the tunnel and preserves unrelated scratch contents', async t => {
  const f = await fixture(t, { mode: 'hold' }), destination = await scratch(t), events = [];
  const sentinel = path.join(destination.root, 'keep.txt'); await writeFile(sentinel, FAKE_SECRET, { mode: 0o600 });
  const abort = new AbortController();
  await withoutDNS(async () => {
    const pending = runUpdateRequest(downloadRequest(f, destination.packageDirectory), event => events.push(event),
      { ...TEST_OPTIONS, signal: abort.signal });
    await f.held; abort.abort(new Error(`private cancellation ${FAKE_SECRET}`));
    await rejectsSafe(pending, 'UPDATE_CANCELLED');
  });
  await waitFor(() => f.sockets.size === 0, 'Cancellation must destroy the active TLS and CONNECT sockets.');
  assert.equal(f.observed.requests.length, 1);
  assert.equal(events.some(event => event.fraction === 1 || event.type === 'downloaded'), false);
  assert.equal(await readFile(sentinel, 'utf8'), FAKE_SECRET);
  assert.ok((await lstat(destination.root)).isDirectory());
});

test('cancellation while CONNECT is pending and pre-aborted requests never fall back directly', async t => {
  const f = await fixture(t, { proxyMode: 'hang' }), abort = new AbortController();
  await withoutDNS(async () => {
    const pending = runUpdateRequest(checkRequest(f), () => {}, { ...TEST_OPTIONS, signal: abort.signal });
    await f.connected; abort.abort(); await rejectsSafe(pending, 'UPDATE_CANCELLED');
  });
  await waitFor(() => f.sockets.size === 0, 'Cancelled CONNECT socket must close.');
  const previous = f.observed.connects.length;
  await rejectsSafe(runUpdateRequest(checkRequest(f), () => {}, { ...TEST_OPTIONS, signal: abort.signal }), 'UPDATE_CANCELLED');
  assert.equal(f.observed.connects.length, previous); assert.deepEqual(f.observed.requests, []);
});

test('proxy failure and streamed body timeout remain bounded with no direct fallback', async t => {
  const rejected = await fixture(t, { proxyMode: 'reject' });
  await withoutDNS(() => rejectsSafe(runUpdateRequest(checkRequest(rejected), () => {}, TEST_OPTIONS), 'UPDATE_NETWORK_FAILED'));
  assert.equal(rejected.observed.connects.length, 1); assert.deepEqual(rejected.observed.requests, []);
  const stalled = await fixture(t, { mode: 'hold' }), destination = await scratch(t);
  const started = Date.now();
  await withoutDNS(() => rejectsSafe(runUpdateRequest(downloadRequest(stalled, destination.packageDirectory), () => {}, {
    testOnly: true, transportDependencies: { testOnly: true, ca: CA, timeoutMs: 100 },
  }), 'UPDATE_NETWORK_FAILED'));
  assert.ok(Date.now() - started < 1500); assert.equal(stalled.observed.requests.length, 1);
  await waitFor(() => stalled.sockets.size === 0, 'Timed-out download sockets must close.');
});
