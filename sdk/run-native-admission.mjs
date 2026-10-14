// Linux native-domain fixture. Local SSE responses and per-call approvals are
// simulated; the SDK, official CLI, its builtins and Bash are genuine.
import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { readFile, writeFile, readdir } from 'node:fs/promises';
import { writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { OriginContract, inputHash } from './origin-contract.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const CURRENT = '/var/lib/claude-code-native-poc/current';
const CWD = `${CURRENT}/work`;
const MODE = process.argv[2];
const CLI = `${ROOT}/node_modules/@anthropic-ai/claude-agent-sdk-linux-arm64/claude`;
const PORT = 41417;
if (process.platform !== 'linux' || process.arch !== 'arm64' || process.getuid() !== 29998 || !['isolation', 'contract', 'relay'].includes(MODE) || ROOT !== '/opt/claude-code-poc/native-runtime/sdk') throw new Error('Fixed native no-NIC Linux fixture entry required');
if (JSON.stringify((await readdir('/sys/class/net')).sort()) !== '["lo"]') throw new Error('Only lo allowed');
if ((await readFile('/proc/self/attr/current', 'utf8')).trim() !== 'claude-native-controller (enforce)') throw new Error('Native controller profile must enforce');
const hash = value => createHash('sha256').update(value).digest('hex');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const FAKE_KEY = 'sk-ant-api03-NATIVE-POC-FAKE-NOT-VALID';
const relayClient = MODE === 'relay' ? JSON.parse(await readFile(`${CURRENT}/controller/relay-client.json`, 'utf8')) : null;
if (relayClient && (!/^[0-9a-f]{64}$/.test(relayClient.client_token) || relayClient.schema !== 'relay-client/v1')) throw new Error('Pinned relay session token required');
const CLIENT_KEY = relayClient?.client_token ?? FAKE_KEY;
const USE_CONTRACT = MODE !== 'isolation';
const TOOLS = ['Write', 'Read', 'Edit', 'Bash'];
const command = '/usr/bin/python3 -I -S /opt/claude-code-poc/native/work_fixture.py inheritance; /usr/bin/python3 -I -S /opt/claude-code-poc/native/work_fixture.py boundaries; /usr/bin/python3 -I -S /opt/claude-code-poc/native/work_fixture.py daemon; printf "native-fixture-started\\n"';
const fixtureFile = `${CWD}/native-fixture.txt`;
const protectedFile = `${CURRENT}/controller/protected-fake.json`;
const plan = [
  { name: 'Write', input: { file_path: fixtureFile, content: 'native fixture original\n' } },
  { name: 'Read', input: { file_path: fixtureFile } },
  { name: 'Edit', input: { file_path: fixtureFile, old_string: 'original', new_string: 'edited', replace_all: false } },
  { name: 'Bash', input: { command, description: 'Fixed no-network native lifecycle fixture', timeout: 10000 } },
  { name: 'Read', input: { file_path: protectedFile } },
  { name: 'Write', input: { file_path: `${CURRENT}/controller/forbidden-create.txt`, content: 'DENIED-NATIVE-FIXTURE\n' } },
];
const contract = new OriginContract({ body: `NATIVE_${MODE.toUpperCase()}: fixed local simulated-model fixture only.`, approvedTools: TOOLS });
const evidence = { schema: 'native-sdk-runner/v1', mode: MODE, fake_key: true, fake_api: '127.0.0.1:41417', sdk_version: '0.3.295', cli_expected: '2.1.295', cli_sha256: hash(await readFile(CLI)), requests: [], hooks: [], permissions: [], raw: [], events: [], simulation: true, diagnostic_boundary: MODE === 'isolation' ? 'Explicit native confinement diagnostic. Fixture-only permissions cannot qualify production origin authorization.' : 'App-owned exact one-time receipt and native hook JOIN, with fixture-only permissions.' };
let apiIndex = 0;
evidence.supplied_key_role = MODE === 'relay' ? 'limited_boot_session_token_not_provider_key' : 'guest_local_fake_provider_key';
if (relayClient) evidence.relay_session = { session_id: relayClient.session_id, boot_epoch: relayClient.boot_epoch, client_token_sha256: hash(CLIENT_KEY) };
if (MODE === 'relay') {
  // No application data or credentials: a fixed local destination outside the
  // permitted frontend must be rejected by the UID's installed egress chain.
  evidence.fixed_egress_negative_control = await new Promise(resolve => {
    const socket = net.createConnection({ host: '127.0.0.1', port: 41419 });
    socket.setTimeout(1500);
    socket.once('connect', () => { socket.destroy(); resolve({ rejected: false, sent_application_data: false }); });
    socket.once('error', error => resolve({ rejected: true, error_code: error.code, sent_application_data: false }));
    socket.once('timeout', () => { socket.destroy(); resolve({ rejected: false, timeout: true, sent_application_data: false }); });
  });
  if (evidence.fixed_egress_negative_control.rejected !== true) throw new Error('Fixed destination egress negative control failed');
}
let child;
let q;
let rawInput = '';
let rawOutput = '';
let policyResolve;
const policyReady = new Promise(resolve => { policyResolve = resolve; });
const env = { PATH: '/usr/bin:/bin', HOME: `${CURRENT}/home`, TMPDIR: `${CURRENT}/tmp`, CLAUDE_CODE_TMPDIR: `${CURRENT}/tmp`, TZ: 'Asia/Tokyo', LANG: 'C.UTF-8', CLAUDE_CONFIG_DIR: `${CURRENT}/home/.claude`, ANTHROPIC_API_KEY: CLIENT_KEY, ANTHROPIC_BASE_URL: `http://127.0.0.1:${PORT}`, CLAUDE_CODE_ENTRYPOINT: 'sdk-ts', CLAUDE_AGENT_SDK_VERSION: '0.3.295', CLAUDE_CODE_SDK_READS_SESSION_STATE: '1', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1', CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1', CLAUDE_CODE_DISABLE_CRON: '1', CLAUDE_CODE_DISABLE_AGENT_VIEW: '1', CLAUDE_CODE_SKIP_BASH_ENVIRONMENT_SNAPSHOT: '1', CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1' };

function sse(res, block, stopReason) {
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const send = (event, value) => res.write(`event: ${event}\ndata: ${JSON.stringify(value)}\n\n`);
  send('message_start', { type: 'message_start', message: { id: `native-msg-${++apiIndex}`, type: 'message', role: 'assistant', model: 'claude-sonnet-4-6', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } } });
  send('content_block_start', { type: 'content_block_start', index: 0, content_block: block.type === 'text' ? { type: 'text', text: '' } : { ...block, input: {} } });
  send('content_block_delta', { type: 'content_block_delta', index: 0, delta: block.type === 'text' ? { type: 'text_delta', text: block.text } : { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } });
  send('content_block_stop', { type: 'content_block_stop', index: 0 });
  send('message_delta', { type: 'message_delta', delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 10 } });
  send('message_stop', { type: 'message_stop' }); res.end();
}
const server = http.createServer(async (req, res) => {
  let bytes = '';
  for await (const chunk of req) { bytes += chunk; if (bytes.length > 3_000_000) { res.writeHead(413); res.end(); return; } }
  let body;
  try { body = bytes ? JSON.parse(bytes) : {}; } catch { res.writeHead(400); res.end(); return; }
  if (req.url?.startsWith('/v1/messages/count_tokens')) { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"input_tokens":10}'); return; }
  if (!req.url?.startsWith('/v1/messages')) { res.writeHead(404); res.end(); return; }
  const results = (body.messages ?? []).flatMap(m => Array.isArray(m.content) ? m.content.filter(b => b.type === 'tool_result') : []);
  const completed = new Set(results.map(x => x.tool_use_id));
  const index = plan.findIndex((_, i) => !completed.has(`native-fixture-${i}`));
  evidence.requests.push({ method: req.method, url: req.url, remote: req.socket.remoteAddress, fake_auth_present: req.headers['x-api-key'] === FAKE_KEY, tool_names: (body.tools ?? []).map(t => t.name), tool_result_ids: [...completed], stage: index });
  if (req.socket.remoteAddress !== '127.0.0.1' || req.headers['x-api-key'] !== FAKE_KEY) { res.writeHead(403); res.end(); return; }
  const block = index >= 0 ? { type: 'tool_use', id: `native-fixture-${index}`, ...plan[index] } : { type: 'text', text: 'Native confinement fixture completed with local simulated response.' };
  if (body.stream) sse(res, block, index >= 0 ? 'tool_use' : 'end_turn');
  else { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ id: `native-msg-${++apiIndex}`, type: 'message', role: 'assistant', model: body.model, content: [block], stop_reason: index >= 0 ? 'tool_use' : 'end_turn', stop_sequence: null, usage: { input_tokens: 10, output_tokens: 10 } })); }
});
if (MODE !== 'relay') await new Promise(resolve => server.listen(PORT, '127.0.0.1', resolve));
const { query } = await import('@anthropic-ai/claude-agent-sdk');
function fixtureMatch(name, input, toolID) {
  const index = Number(toolID?.replace('native-fixture-', ''));
  const expected = plan[index];
  return Number.isInteger(index) && expected?.name === name && inputHash(expected.input) === inputHash(input);
}
function spawnNative(options) {
  if (options.command !== CLI || !options.args.includes('--setting-sources=')) throw new Error('Pinned native CLI and explicit empty setting sources required');
  child = spawn(CLI, options.args, { cwd: CWD, env, stdio: ['pipe', 'pipe', 'pipe'], detached: true, signal: options.signal });
  evidence.launch = { command: CLI, args: options.args, environment_names: Object.keys(env), supplied_api_key_present: true, controller_pid: process.pid, cli_pid: child.pid };
  writeFileSync(`${CURRENT}/controller/process-info.json`, JSON.stringify({ controller_pid: process.pid, cli_pid: child.pid, node_control_fds: [{ role: 'stdin', fd: child.stdin._handle.fd }, { role: 'stdout', fd: child.stdout._handle.fd }] }) + '\n', { flag: 'wx', mode: 0o600 });
  const originalWrite = child.stdin.write;
  child.stdin.write = function(chunk, ...rest) {
    rawInput += typeof chunk === 'string' ? chunk : chunk.toString();
    const lines = rawInput.split('\n'); rawInput = lines.pop();
    for (const line of lines) if (line.trim()) {
      try { const m = JSON.parse(line); if (m.type === 'control_request' && m.request?.subtype === 'initialize') evidence.initialize_request = m; }
      catch (error) { evidence.invalid_outgoing_frame = String(error); }
    }
    return Reflect.apply(originalWrite, this, [chunk, ...rest]);
  };
  child.stdout.on('data', chunk => {
    rawOutput += chunk; const lines = rawOutput.split('\n'); rawOutput = lines.pop();
    for (const line of lines) if (line.trim()) {
      let m; try { m = JSON.parse(line); } catch (error) { evidence.invalid_cli_frame = String(error); continue; }
      evidence.raw.push(m);
      if (m.type === 'control_response' && m.response?.request_id === evidence.initialize_request?.request_id && m.response?.response?.hooks_applied !== undefined) evidence.initialize_response = m.response.response;
      if (m.type === 'system' && m.subtype === 'init') { evidence.native_init = m; contract.markInit(m, CWD); }
      if (m.type === 'result') contract.seal('native_result');
    }
  });
  child.stderr.on('data', chunk => { evidence.stderr = (evidence.stderr ?? '') + chunk; });
  child.on('exit', (code, signal) => { evidence.cli_exit = { code, signal }; contract.seal('native_exit'); });
  return child;
}
async function* input() {
  await policyReady;
  const deadline = Date.now() + 15000;
  for (;;) {
    try { if (JSON.parse(await readFile(`${CURRENT}/target-ready.json`, 'utf8')).ready === true) break; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (Date.now() >= deadline) throw new Error('Root broker target binding deadline');
    await delay(50);
  }
  yield { type: 'user', uuid: contract.clientUuid, session_id: '', parent_tool_use_id: null, message: { role: 'user', content: contract.prompt } };
  await new Promise(() => {}); // One foreground turn. Root broker owns termination.
}
q = query({ prompt: input(), options: { cwd: CWD, env, pathToClaudeCodeExecutable: CLI, model: 'claude-sonnet-4-6', maxTurns: 10, permissionMode: 'default', permissionPrompts: 'host', settingSources: [], tools: TOOLS, allowedTools: [], allowDangerouslySkipPermissions: false, includePartialMessages: true, persistSession: true, spawnClaudeCodeProcess: spawnNative,
  hooks: {
    UserPromptSubmit: [{ hooks: [async value => { const output = contract.onUserPrompt(value); evidence.hooks.push({ kind: 'UserPromptSubmit', input: value, output }); return USE_CONTRACT ? output : (value.prompt === contract.prompt ? {} : { decision: 'block', reason: 'Unregistered diagnostic input' }); }] }],
    PreToolUse: [{ hooks: [async value => {
      const output = USE_CONTRACT ? contract.onPreTool(value) : { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: fixtureMatch(value.tool_name, value.tool_input, value.tool_use_id) ? 'ask' : 'deny', permissionDecisionReason: 'Explicit isolation-only fixed fixture' } };
      evidence.hooks.push({ kind: 'PreToolUse', input: value, output }); return output;
    }] }],
    PostToolUse: [{ hooks: [async value => { evidence.hooks.push({ kind: 'PostToolUse', input: value }); return {}; }] }],
    PostToolUseFailure: [{ hooks: [async value => { evidence.hooks.push({ kind: 'PostToolUseFailure', input: value }); return {}; }] }],
    Stop: [{ hooks: [async value => { contract.seal('Stop'); evidence.hooks.push({ kind: 'Stop', input: value }); return {}; }] }],
    StopFailure: [{ hooks: [async value => { contract.seal('StopFailure'); evidence.hooks.push({ kind: 'StopFailure', input: value }); return {}; }] }],
  }, canUseTool: async (name, value, options) => {
    const match = fixtureMatch(name, value, options.toolUseID);
    const output = USE_CONTRACT ? await contract.onCanUseTool(name, value, options, { fixtureDecision: match ? 'allow' : 'deny', updatedInput: value }) : (match ? { behavior: 'allow', updatedInput: value, toolUseID: options.toolUseID } : { behavior: 'deny', message: 'Outside fixed diagnostic fixture', toolUseID: options.toolUseID });
    evidence.permissions.push({ name, input: value, request_id: options.requestId, tool_use_id: options.toolUseID, fixture_only: true, output }); return output;
  } } });
const policy = (async () => {
  try {
    evidence.settings = await q.getSettings();
    const events = Object.keys(evidence.initialize_request?.request?.hooks ?? {});
    evidence.handshake_verified = contract.markHandshake({ hooksApplied: evidence.initialize_response?.hooks_applied, hookEvents: events, permissionMode: evidence.initialize_response?.current_permission_mode, settingSourcesVerified: evidence.launch.args.includes('--setting-sources=') && Array.isArray(evidence.settings.sources) && evidence.settings.sources.length === 0 });
  } catch (error) { evidence.policy_error = String(error); contract.seal('policy_failure'); }
  finally { policyResolve(); }
})();
try { for await (const message of q) { evidence.events.push(message); if (message.type === 'result') { evidence.result = message; break; } } }
catch (error) { evidence.error = String(error); }
await policy;
evidence.contract = contract.snapshot();
evidence.cli_sha256_after = hash(await readFile(CLI));
let fixtureContent;
try { fixtureContent = await readFile(fixtureFile, 'utf8'); } catch (error) { evidence.fixture_read_error = String(error); }
evidence.actual_builtin_fixture_content = fixtureContent;
evidence.strict_origin_status = USE_CONTRACT && evidence.contract.handshake_verified && evidence.contract.init_verified && evidence.permissions.length > 0 && evidence.contract.audit.some(x => x.kind === 'permission_join' && x.valid) && fixtureContent === 'native fixture edited\n' ? 'passed_local_fixture' : MODE === 'isolation' ? 'not_tested_isolation_diagnostic' : 'blocked';
evidence.controller_hang_fixture = 'After writing summary, Atomics.wait prevents SDK cooperation. Root cgroup.kill must terminate it.';
await writeFile(`${CURRENT}/controller/summary.json`, JSON.stringify(evidence, null, 2), { flag: 'wx', mode: 0o600 });
// Deliberately unresponsive controller is contained in root-owned fixed cgroup.
// No process group or SDK cancellation can be the root broker's only stop path.
Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
