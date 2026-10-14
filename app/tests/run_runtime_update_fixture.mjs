#!/usr/bin/env node
// Test-only TLS publisher + CONNECT proxy. No public service or host proxy is used.
import { constants, readFileSync } from 'node:fs';
import { lstat, mkdir, open, readdir, readFile, realpath } from 'node:fs/promises';
import dns from 'node:dns';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import { syncBuiltinESMExports } from 'node:module';
import { pipeline } from 'node:stream/promises';
import { createSecureContext } from 'node:tls';
import { fileURLToPath, pathToFileURL } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const fixtureRoot = path.join(projectRoot, 'network/fixtures');
const CA = readFileSync(path.join(fixtureRoot, 'test-ca.pem'));
const CERT = readFileSync(path.join(fixtureRoot, 'test-server-cert.pem'));
const KEY = readFileSync(path.join(fixtureRoot, 'test-server-key.pem'));
const dnsMethods = ['lookup', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCname',
  'resolveTxt', 'resolveMx', 'resolveNs', 'resolvePtr', 'resolveSoa', 'resolveSrv', 'resolveNaptr', 'reverse'];

function installDNSTrap(observed) {
  const failure = () => Object.assign(new Error('FIXTURE_LOCAL_DNS_FORBIDDEN'), { code: 'ENOTFOUND' });
  for (const name of dnsMethods) {
    if (typeof dns[name] === 'function') dns[name] = (...args) => {
      const callback = args.at(-1);
      // Node's listen(host) asks lookup even for numeric IPs. Answer that exact
      // loopback literal locally rather than calling the system resolver.
      if (name === 'lookup' && args[0] === '127.0.0.1' && typeof callback === 'function') {
        observed.numericLoopbackLookupBypasses++;
        queueMicrotask(() => args[1]?.all
          ? callback(null, [{ address: '127.0.0.1', family: 4 }])
          : callback(null, '127.0.0.1', 4));
        return;
      }
      observed.localDNSCalls++;
      if (typeof callback !== 'function') throw failure();
      queueMicrotask(() => callback(failure()));
    };
    if (typeof dns.promises[name] === 'function') dns.promises[name] = async () => {
      observed.localDNSCalls++; throw failure();
    };
  }
  syncBuiltinESMExports();
}

function argumentsForFixture(args) {
  if (args.length !== 4) throw new Error('FIXTURE_USAGE');
  const values = {};
  for (let at = 0; at < args.length; at += 2) {
    const key = args[at]; const value = args[at + 1];
    if (!['--layout', '--output'].includes(key) || values[key] || !path.isAbsolute(value) ||
        path.normalize(value) !== value || /[\x00-\x1f\x7f]/.test(value)) throw new Error('FIXTURE_USAGE');
    values[key] = value;
  }
  if (!values['--layout'] || !values['--output'] || values['--output'] === '/') throw new Error('FIXTURE_USAGE');
  return { layout: values['--layout'], output: values['--output'] };
}

async function directoryAncestors(directory) {
  for (let current = directory;; current = path.dirname(current)) {
    const metadata = await lstat(current);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error('FIXTURE_DIRECTORY_INVALID');
    if (current === '/') return;
  }
}

async function privateDirectory(directory, existingAllowed = false) {
  await directoryAncestors(path.dirname(directory));
  try { await mkdir(directory, { mode: 0o700 }); }
  catch (error) { if (!existingAllowed || error.code !== 'EEXIST') throw error; }
  const metadata = await lstat(directory);
  if (!metadata.isDirectory() || metadata.isSymbolicLink() || metadata.uid !== process.getuid?.() ||
      (metadata.mode & 0o777) !== 0o700) throw new Error('FIXTURE_OUTPUT_INVALID');
}

async function exclusiveFile(filename, bytes) {
  const handle = await open(filename, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { await handle.writeFile(bytes); await handle.sync(); }
  finally { await handle.close(); }
}

function workerWrapper(dnsReceipts) {
  const workerURL = pathToFileURL(path.join(projectRoot, 'updates/stdio.mjs')).href;
  return `// Generated test-only wrapper: production worker, explicit fixture CA, DNS trap.\n` +
    `import { runStdio } from ${JSON.stringify(workerURL)};\n` +
    `import dns from 'node:dns';\n` +
    `import { syncBuiltinESMExports } from 'node:module';\n` +
    `import { constants, openSync, writeFileSync, fsyncSync, closeSync } from 'node:fs';\n` +
    `import path from 'node:path';\n` +
    `let localDNSCalls = 0;\n` +
    `const forbidden = () => Object.assign(new Error('FIXTURE_LOCAL_DNS_FORBIDDEN'), {code:'ENOTFOUND'});\n` +
    `for (const name of ${JSON.stringify(dnsMethods)}) {\n` +
    `  if (typeof dns[name] === 'function') dns[name] = (...args) => {\n` +
    `    localDNSCalls++; const callback = args.at(-1);\n` +
    `    if (typeof callback !== 'function') throw forbidden();\n` +
    `    queueMicrotask(() => callback(forbidden()));\n` +
    `  };\n` +
    `  if (typeof dns.promises[name] === 'function') dns.promises[name] = async () => {localDNSCalls++; throw forbidden();};\n` +
    `}\n` +
    `syncBuiltinESMExports();\n` +
    `const controller = new AbortController();\n` +
    `const interrupt = () => controller.abort();\n` +
    `process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);\n` +
    `try {\n` +
    `  const terminal = await runStdio({signal:controller.signal,testOnly:true,transportDependencies:{testOnly:true,ca:Buffer.from(${JSON.stringify(CA.toString('base64'))},'base64')}});\n` +
    `  process.exitCode = terminal.type === 'error' ? 1 : 0;\n` +
    `} finally {\n` +
    `  process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt);\n` +
    `  let descriptor;\n` +
    `  try {\n` +
    `    descriptor = openSync(path.join(${JSON.stringify(dnsReceipts)}, String(process.pid)+'.json'), constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW, 0o600);\n` +
    `    writeFileSync(descriptor, JSON.stringify({schema:'runtime-update-fixture-worker-dns/v1',localDNSCalls})+'\\n'); fsyncSync(descriptor);\n` +
    `  } catch { process.stderr.write('FIXTURE_DNS_RECEIPT_FAILED\\n'); process.exitCode = 1; }\n` +
    `  finally { if (descriptor !== undefined) closeSync(descriptor); }\n` +
    `}\n`;
}

function healthWrapper() {
  return `// Generated fixture wrapper for the real trusted health worker.\n` +
    `import { runHealthStdio } from ${JSON.stringify(pathToFileURL(path.join(projectRoot, 'updates/health.mjs')).href)};\n` +
    `const controller = new AbortController();\n` +
    `const interrupt = () => controller.abort();\n` +
    `process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);\n` +
    `try {\n` +
    `  const terminal = await runHealthStdio({signal:controller.signal});\n` +
    `  process.exitCode = terminal.type === 'error' ? 1 : 0;\n` +
    `} finally { process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt); }\n`;
}

function listen(server) {
  return new Promise((resolve, reject) => {
    const onError = error => reject(error);
    server.once('error', onError);
    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', onError); resolve(server.address().port);
    });
  });
}

function staticSegments(rawPath) {
  if (typeof rawPath !== 'string' || rawPath.length > 4096 || !rawPath.startsWith('/') || /[?#\\\x00-\x20\x7f]/.test(rawPath)) return null;
  if (rawPath === '/channel.json') return ['channel.json'];
  const segments = rawPath.slice(1).split('/');
  if (segments.length < 5 || segments[0] !== 'packages' || !/^runtime-[a-f0-9]{64}$/.test(segments[1]) ||
      segments[2] !== 'Contents') return null;
  try {
    const decoded = segments.map(segment => decodeURIComponent(segment));
    if (decoded.some(segment => !segment || segment === '.' || segment === '..' || !/^[\x21-\x7e]+$/.test(segment) || /[\/\\:%]/.test(segment))) return null;
    if (!['Resources', 'Helpers'].includes(decoded[3]) || (decoded[3] === 'Resources' && decoded[4] !== 'Runtime')) return null;
    return decoded;
  } catch { return null; }
}

async function openStaticFile(layout, segments) {
  let current = layout;
  for (const segment of segments.slice(0, -1)) {
    current = path.join(current, segment);
    const metadata = await lstat(current);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error('FIXTURE_STATIC_INVALID');
  }
  const filename = path.join(current, segments.at(-1));
  const metadata = await lstat(filename);
  if (!metadata.isFile() || metadata.isSymbolicLink()) throw new Error('FIXTURE_STATIC_INVALID');
  const handle = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  const actual = await handle.stat();
  if (!actual.isFile() || actual.dev !== metadata.dev || actual.ino !== metadata.ino || !Number.isSafeInteger(actual.size)) {
    await handle.close(); throw new Error('FIXTURE_STATIC_INVALID');
  }
  return { handle, size: actual.size };
}

async function main() {
  const args = argumentsForFixture(process.argv.slice(2));
  const layout = await realpath(args.layout);
  const output = path.join(await realpath(path.dirname(args.output)), path.basename(args.output));
  await directoryAncestors(layout);
  if (output === layout || output.startsWith(layout + '/')) throw new Error('FIXTURE_OUTPUT_INVALID');
  const channel = await openStaticFile(layout, ['channel.json']);
  await channel.handle.close();
  await privateDirectory(output, true);
  const wrapperRoot = path.join(output, 'project');
  const wrapperUpdates = path.join(wrapperRoot, 'updates');
  const dnsReceipts = path.join(output, 'worker-dns');
  await privateDirectory(wrapperRoot); await privateDirectory(wrapperUpdates); await privateDirectory(dnsReceipts);
  await exclusiveFile(path.join(wrapperUpdates, 'stdio.mjs'), workerWrapper(dnsReceipts));
  await exclusiveFile(path.join(wrapperUpdates, 'health.mjs'), healthWrapper());

  const observed = { schema: 'runtime-update-fixture-evidence/v1', stopped: false, proxyConnectCount: 0,
    proxyConnectAcceptedCount: 0, proxyConnectRejectedCount: 0, establishedTunnelCount: 0,
    proxyHTTPRejectedCount: 0, originRequestCount: 0, originSuccessCount: 0, originRejectedRequestCount: 0,
    channelRequestCount: 0, payloadRequestCount: 0, bytesServed: 0, streamFailureCount: 0,
    localDNSCalls: 0, numericLoopbackLookupBypasses: 0, workerDNSReceipts: 0, socketErrorCount: 0, tlsHandshakeErrorCount: 0,
    externalConnectionCount: 0, allUpstreamConnectionsLoopback: true, streamedPayloads: true };
  installDNSTrap(observed);
  const sockets = new Set(); const tunnelPorts = new Set(); const activeRequests = new Set();
  const configPath = path.join(output, 'fixture-config.json');
  const evidencePath = path.join(output, 'fixture-evidence.json');
  let stopping = false; let authority; let originPort;
  let origin; let proxy; let shutdownPromise;
  const capture = socket => {
    sockets.add(socket);
    socket.on('error', () => { observed.socketErrorCount++; });
    socket.once('close', () => sockets.delete(socket));
  };
  const context = createSecureContext({ key: KEY, cert: CERT });
  origin = https.createServer({ key: KEY, cert: CERT, maxHeaderSize: 16 * 1024,
    SNICallback: (name, callback) => callback(name === 'fixture.invalid' ? null : new Error('FIXTURE_SNI_REFUSED'), context) },
  (request, response) => {
    const task = (async () => {
      observed.originRequestCount++;
      const segments = staticSegments(request.url);
      if (stopping || request.method !== 'GET' || request.headers.host !== authority ||
          request.socket.servername !== 'fixture.invalid' || !tunnelPorts.has(request.socket.remotePort) ||
          request.headers['transfer-encoding'] !== undefined ||
          (request.headers['content-length'] !== undefined && request.headers['content-length'] !== '0') || !segments) {
        observed.originRejectedRequestCount++; request.resume(); response.writeHead(403); response.end(); return;
      }
      let handle; let stream;
      try {
        const file = await openStaticFile(layout, segments); handle = file.handle;
        if (segments.length === 1) observed.channelRequestCount++; else observed.payloadRequestCount++;
        response.writeHead(200, { 'content-type': segments.length === 1 ? 'application/json' : 'application/octet-stream',
          'content-length': file.size, 'cache-control': 'no-store', connection: 'close' });
        stream = handle.createReadStream({ autoClose: false });
        await pipeline(stream, response); observed.originSuccessCount++;
      } catch {
        observed.streamFailureCount++;
        if (!response.headersSent) { response.writeHead(404); response.end(); } else response.destroy();
      } finally {
        if (stream) { observed.bytesServed += stream.bytesRead; stream.destroy(); }
        if (handle) await handle.close();
      }
    })().catch(() => { observed.streamFailureCount++; response.destroy(); });
    activeRequests.add(task);
    void task.then(() => activeRequests.delete(task));
  });
  origin.on('connection', capture);
  origin.on('tlsClientError', () => { observed.tlsHandshakeErrorCount++; });
  origin.on('error', () => { process.exitCode = 1; void shutdown(); });
  proxy = http.createServer({ maxHeaderSize: 16 * 1024 }, (request, response) => {
    observed.proxyHTTPRejectedCount++; request.resume(); response.writeHead(405); response.end();
  });
  proxy.on('connection', capture);
  proxy.on('connect', (request, socket, head) => {
    observed.proxyConnectCount++;
    if (stopping || request.url !== authority) {
      observed.proxyConnectRejectedCount++;
      socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'); return;
    }
    observed.proxyConnectAcceptedCount++;
    const upstream = net.connect({ host: '127.0.0.1', port: originPort });
    let upstreamPort;
    capture(upstream);
    socket.once('close', () => upstream.destroy());
    upstream.once('close', () => { tunnelPorts.delete(upstreamPort); socket.destroy(); });
    upstream.once('error', () => socket.destroy());
    upstream.once('connect', () => {
      if (stopping || socket.destroyed) { upstream.destroy(); return; }
      upstreamPort = upstream.localPort;
      tunnelPorts.add(upstreamPort); observed.establishedTunnelCount++;
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      socket.pipe(upstream); upstream.pipe(socket);
    });
  });
  proxy.on('error', () => { process.exitCode = 1; void shutdown(); });
  function shutdown() {
    if (shutdownPromise) return shutdownPromise;
    stopping = true;
    shutdownPromise = (async () => {
      const closes = [origin, proxy].filter(Boolean).map(server => new Promise(resolve => server.close(resolve)));
      for (const socket of sockets) socket.destroy();
      await Promise.all(closes);
      await Promise.all([...activeRequests]);
      for (const name of await readdir(dnsReceipts)) {
        if (!/^\d+\.json$/.test(name)) throw new Error('FIXTURE_DNS_RECEIPT_INVALID');
        const receipt = JSON.parse(await readFile(path.join(dnsReceipts, name), 'utf8'));
        if (receipt.schema !== 'runtime-update-fixture-worker-dns/v1' || !Number.isSafeInteger(receipt.localDNSCalls) ||
            receipt.localDNSCalls < 0) throw new Error('FIXTURE_DNS_RECEIPT_INVALID');
        observed.localDNSCalls += receipt.localDNSCalls; observed.workerDNSReceipts++;
      }
      observed.stopped = true;
      await exclusiveFile(evidencePath, JSON.stringify(observed, null, 2) + '\n');
    })().catch(() => { process.stderr.write('FIXTURE_SHUTDOWN_FAILED\n'); process.exitCode = 1; });
    return shutdownPromise;
  }
  process.once('SIGINT', shutdown); process.once('SIGTERM', shutdown);
  try {
    originPort = await listen(origin); authority = `fixture.invalid:${originPort}`;
    const proxyPort = await listen(proxy);
    const config = { projectRoot: wrapperRoot, nodeExecutable: process.execPath,
      networkPolicy: { schema: 'app-network-policy/v1', proxyURL: `http://127.0.0.1:${proxyPort}`, dnsPolicy: 'proxy-only' },
      feedURL: `https://${authority}/channel.json` };
    await exclusiveFile(configPath, JSON.stringify(config, null, 2) + '\n');
    process.stdout.write(JSON.stringify({ schema: 'runtime-update-fixture-ready/v1', ready: true, configPath, evidencePath }) + '\n');
  } catch (error) { await shutdown(); throw error; }
}

try { await main(); }
catch { process.stderr.write('FIXTURE_START_FAILED\n'); process.exitCode = 1; }
