// Real production Node -> pinned CLI cancellation. The configured proxy is a
// local CONNECT sink; it never resolves or connects to the remote target.
import assert from 'node:assert/strict';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { access, lstat, mkdtemp, readFile, readdir, realpath, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { OWNED_RUN_MANIFEST, OWNED_RUN_SCHEMA, nativeProcessMayBeRunning, waitForNativeProcessExit } from './owned-run-directory.mjs';
import { FAKE_SUBSCRIPTION_TOKEN, SUBSCRIPTION_INPUT } from './subscription-test-fixtures.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const temporaryRoot = await realpath(await mkdtemp(path.join(os.tmpdir(), 'owned-native-cancel-')));
const sockets = new Set();
const targets = [];
const events = [];
const proxy = http.createServer();
let child, receipt, nativeExited = false, nodeExited = false;
let output = '', diagnostic = '', interrupted = false;
let connectionResolve;
const connected = new Promise(resolve => { connectionResolve = resolve; });
function bounded(promise, milliseconds, code) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(code)), milliseconds); })])
    .finally(() => clearTimeout(timer));
}
proxy.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
proxy.on('connect', (request, socket) => {
  targets.push(request.url);
  // No CONNECT response, TLS handshake or upstream connection. SIGTERM must
  // cancel this pending production transport and the native process group.
  connectionResolve();
});
try {
  await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
  child = spawn(process.execPath, [path.join(directory, 'deepseek-text-chat.mjs')], {
    cwd: directory, stdio: ['pipe', 'pipe', 'pipe'],
    env: { PATH: '/usr/bin:/bin:/usr/sbin', TZ: 'Asia/Tokyo', LANG: 'ja_JP.UTF-8',
      LC_ALL: 'ja_JP.UTF-8', LC_MESSAGES: 'ja_JP.UTF-8', TMPDIR: temporaryRoot },
  });
  const exited = once(child, 'exit').then(([code, signal]) => { nodeExited = true; return { code, signal }; });
  child.stdout.on('data', chunk => {
    output += chunk.toString('utf8');
    assert.ok(Buffer.byteLength(output) <= 16_384, 'bounded bridge output');
    for (;;) {
      const separator = output.indexOf('\n');
      if (separator < 0) break;
      events.push(JSON.parse(output.slice(0, separator)));
      output = output.slice(separator + 1);
    }
  });
  child.stderr.on('data', chunk => { diagnostic = (diagnostic + chunk.toString('utf8')).slice(-4096); });
  child.stdin.end(JSON.stringify({ ...SUBSCRIPTION_INPUT,
    network: { ...SUBSCRIPTION_INPUT.network, proxyURL: `http://127.0.0.1:${proxy.address().port}` } }));
  await bounded(Promise.race([connected, exited.then(() => { throw new Error('BRIDGE_EXITED_BEFORE_LOCAL_CONNECT'); })]),
    20_000, 'LOCAL_NATIVE_START_TIMEOUT');
  assert.deepEqual(targets, ['api.anthropic.com:443']);
  assert.equal(events.filter(event => event.type === 'started').length, 1);
  const names = await readdir(temporaryRoot);
  assert.equal(names.length, 1);
  assert.match(names[0], /^claude-deepseek-chat-[A-Za-z0-9]{6}$/);
  const runDirectory = path.join(temporaryRoot, names[0]);
  receipt = JSON.parse(await readFile(path.join(runDirectory, OWNED_RUN_MANIFEST), 'utf8'));
  const identity = await lstat(runDirectory, { bigint: true });
  assert.equal(receipt.schema, OWNED_RUN_SCHEMA); assert.equal(receipt.pid, child.pid);
  assert.equal(receipt.uid, process.getuid()); assert.equal(receipt.native_state, 'registered');
  assert.equal(receipt.directory_dev, String(identity.dev)); assert.equal(receipt.directory_ino, String(identity.ino));
  assert.equal(nativeProcessMayBeRunning(receipt.native_pid), true);
  assert.equal(child.kill('SIGTERM'), true); interrupted = true;
  const exit = await bounded(exited, 10_000, 'NODE_CANCEL_TIMEOUT');
  assert.deepEqual(exit, { code: 0, signal: null });
  assert.equal(events.at(-1)?.type, 'error'); assert.equal(events.at(-1)?.code, 'PROCESS_INTERRUPTED');
  assert.equal(events.some(event => event.type === 'completed' || event.type === 'delta'), false);
  nativeExited = await waitForNativeProcessExit(receipt.native_pid);
  assert.equal(nativeExited, true, 'native leader and process group must be absent');
  await assert.rejects(access(runDirectory), { code: 'ENOENT' });
  assert.equal(JSON.stringify(events).includes(FAKE_SUBSCRIPTION_TOKEN), false);
  assert.equal(diagnostic.includes(FAKE_SUBSCRIPTION_TOKEN), false);
  assert.deepEqual(await readdir(temporaryRoot), []);
  console.log('PASS production Node SIGTERM cancels a locally pending transport, exits pinned native group and removes owned runtime');
  console.log(JSON.stringify({ schema: 'owned-native-cancel-local-checks/v1', passed: 1,
    production_node_bridge_executed: true, native_cli_executed: true, sandbox_executed: true,
    remote_provider_calls: false, real_subscription_verified: false, host_credentials_read: false,
    minimal_app_environment: true, controlled_temporary_root_verified: true,
    local_connect_count: targets.length, native_group_exited: true, owned_temporary_removed: true,
    terminal_code: 'PROCESS_INTERRUPTED', output_contains_credentials: false }));
} finally {
  if (child && !nodeExited) {
    if (!interrupted) child.kill('SIGTERM');
    try { await bounded(once(child, 'exit'), 5000, 'FIXTURE_NODE_TEARDOWN_TIMEOUT'); nodeExited = true; }
    catch { child.kill('SIGKILL'); }
  }
  for (const socket of sockets) socket.destroy();
  await new Promise(resolve => proxy.close(resolve));
  // A failed cancellation keeps the receipt and files for safe recovery.
  if (receipt) nativeExited = await waitForNativeProcessExit(receipt.native_pid);
  if (nodeExited && (receipt ? nativeExited : (await readdir(temporaryRoot)).length === 0)) {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
}
