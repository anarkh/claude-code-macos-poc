// Native CLI/SDK capability experiment. Responses below are local API simulations.
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdir, writeFile, readFile, readdir, stat } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveHostHome, createPocSandboxProfile, serializePocSummary } from './poc-host-privacy.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const hostHome = await resolveHostHome();
const RUN = path.join(ROOT, 'runs', new Date().toISOString().replaceAll(':', '-'));
const HOME = path.join(RUN, 'home');
const CWD = path.join(RUN, 'workspace');
const platformPackage = process.platform === 'darwin' ? 'darwin' : process.platform === 'linux' ? 'linux' : undefined;
if (!platformPackage || !['arm64', 'x64'].includes(process.arch)) throw new Error('PoC supports darwin/linux arm64/x64 only');
const CLI = path.join(ROOT, `node_modules/@anthropic-ai/claude-agent-sdk-${platformPackage}-${process.arch}/claude`);
const FAKE_KEY = 'sk-ant-api03-POC-FAKE-NOT-VALID';
const hash = v => createHash('sha256').update(typeof v === 'string' || Buffer.isBuffer(v) ? v : JSON.stringify(v)).digest('hex');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const evidence = { schema: 1, simulation: true, root: ROOT, run: RUN, started_at: new Date().toISOString(), requests: [], scenarios: {}, children: [], limitations: [] };
const children = new Set();
const sockets = new Set();
let apiIndex = 0;
let currentScenario = '';
let q;
let totalExpired = false;
const totalTimer = setTimeout(() => { totalExpired = true; evidence.total_timeout = true; q?.close(); for (const c of children) killGroup(c, 'SIGKILL'); server.closeAllConnections(); }, 120_000);
await mkdir(HOME, { recursive: true });
await mkdir(CWD, { recursive: true });
await mkdir(path.join(RUN, 'tmp'), { recursive: true });

function killGroup(child, signal) {
  if (!child?.pid) return;
  try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') evidence.kill_errors ??= [], evidence.kill_errors.push(String(error)); }
}
function hasGroup(pid) { try { process.kill(-pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } }
function extractContent(message) {
  if (typeof message.content === 'string') return message.content;
  return (message.content ?? []).filter(x => x.type === 'text').map(x => x.text).join('\n');
}
function sse(res, blocks, stopReason = 'end_turn') {
  const id = `msg_poc_${++apiIndex}`;
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', 'request-id': `req_poc_${apiIndex}` });
  const send = (event, value) => res.write(`event: ${event}\ndata: ${JSON.stringify(value)}\n\n`);
  send('message_start', { type: 'message_start', message: { id, type: 'message', role: 'assistant', model: 'claude-sonnet-4-6', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } } });
  blocks.forEach((block, index) => {
    send('content_block_start', { type: 'content_block_start', index, content_block: block.type === 'text' ? { type: 'text', text: '' } : { ...block, input: {} } });
    send('content_block_delta', { type: 'content_block_delta', index, delta: block.type === 'text' ? { type: 'text_delta', text: block.text } : { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } });
    send('content_block_stop', { type: 'content_block_stop', index });
  });
  send('message_delta', { type: 'message_delta', delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 10 } });
  send('message_stop', { type: 'message_stop' });
  res.end();
}
const server = http.createServer(async (req, res) => {
  let bytes = '';
  for await (const chunk of req) { bytes += chunk; if (bytes.length > 3_000_000) { res.writeHead(413); res.end(); return; } }
  let body;
  try { body = bytes ? JSON.parse(bytes) : {}; } catch { res.writeHead(400); res.end(); return; }
  const messages = body.messages ?? [];
  const users = messages.filter(m => m.role === 'user');
  const userText = users.map(extractContent).join('\n');
  const marker = [...userText.matchAll(/POC_(TEXTFIRST|TEXTSECOND|FIRST|SECOND|DENY|SYSTEM|UNREGISTERED|HOLD|ASK)/g)].at(-1)?.[1];
  const tools = messages.flatMap(m => Array.isArray(m.content) ? m.content.filter(b => b.type === 'tool_use') : []);
  const results = messages.flatMap(m => Array.isArray(m.content) ? m.content.filter(b => b.type === 'tool_result') : []);
  evidence.requests.push({ scenario: currentScenario, method: req.method, url: req.url, remote: req.socket.remoteAddress, auth_is_fake: req.headers['x-api-key'] === FAKE_KEY, body_hash: hash(body), marker, message_roles: messages.map(m => m.role), user_texts: users.map(extractContent), historical_tool_ids: tools.map(t => t.id), tool_result_ids: results.map(r => r.tool_use_id), stream: body.stream, tool_names: (body.tools ?? []).map(t => t.name) });
  if (req.url?.startsWith('/v1/messages/count_tokens')) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ input_tokens: 10 })); return; }
  if (!req.url?.startsWith('/v1/messages')) { res.writeHead(404); res.end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: 'Local PoC server only implements Messages API' } })); return; }
  if (marker === 'HOLD') { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.write('event: ping\ndata: {"type":"ping"}\n\n'); evidence.hold_request_at = Date.now(); return; }
  const id = `tool_poc_${marker ?? 'helper'}`;
  const target = path.join(CWD, `${(marker ?? 'helper').toLowerCase()}.txt`);
  const tool = marker === 'ASK'
    ? { type: 'tool_use', id, name: 'AskUserQuestion', input: { questions: [{ question: 'Choose a local test option?', header: 'Local test', options: [{ label: 'Alpha', description: 'Select Alpha' }, { label: 'Beta', description: 'Select Beta' }], multiSelect: false }] } }
    : { type: 'tool_use', id, name: 'Write', input: { file_path: target, content: `native-${marker}\n` } };
  const blocks = !marker || marker.startsWith('TEXT') || results.some(r => r.tool_use_id === id) ? [{ type: 'text', text: marker ? `POC ${marker} completed using local simulated model response.` : 'Local helper response.' }] : [tool];
  if (body.stream) sse(res, blocks, blocks[0].type === 'tool_use' ? 'tool_use' : 'end_turn');
  else { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ id: `msg_poc_${++apiIndex}`, type: 'message', role: 'assistant', model: body.model, content: blocks, stop_reason: blocks[0].type === 'tool_use' ? 'tool_use' : 'end_turn', stop_sequence: null, usage: { input_tokens: 10, output_tokens: 10 } })); }
});
server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
const profile = createPocSandboxProfile({ sdkRoot: ROOT, hostHome: hostHome.path, port });
const profilePath = path.join(RUN, 'cli.sb');
await writeFile(profilePath, profile);
const env = {
  PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin`, HOME, TMPDIR: path.join(RUN, 'tmp'),
  CLAUDE_CONFIG_DIR: path.join(HOME, '.claude'), ANTHROPIC_API_KEY: FAKE_KEY, ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1',
  CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1', CLAUDE_CODE_DISABLE_CRON: '1', CLAUDE_CODE_DISABLE_AGENT_VIEW: '1',
  CLAUDE_CODE_SKIP_BASH_ENVIRONMENT_SNAPSHOT: '1', CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1',
};
const networkInterfaces = process.platform === 'linux' ? await readdir('/sys/class/net') : undefined;
if (process.platform === 'linux' && (networkInterfaces.length !== 1 || networkInterfaces[0] !== 'lo')) {
  server.closeAllConnections(); server.close(); clearTimeout(totalTimer);
  throw new Error('Linux entry requires a VM with no NIC: /sys/class/net must contain only lo');
}
const nativeLaunchCommand = command => process.platform === 'darwin' ? { command: '/usr/bin/sandbox-exec', prefix: ['-f', profilePath, command] } : { command, prefix: [] };
evidence.launch_manifest = { platform: process.platform, arch: process.arch, linux_network_interfaces: networkInterfaces, sdk_version: '0.3.295', cli_expected: '2.1.295', cli_path: CLI, cli_sha256: hash(await readFile(CLI)), home: HOME, config_dir: env.CLAUDE_CONFIG_DIR, environment_keys: Object.keys(env), base_url: env.ANTHROPIC_BASE_URL, fake_api_key: true, setting_sources: [], permission_mode: 'default', permission_prompts: 'host', allowed_tools: [], background_disabled: true, ...(process.platform === 'darwin' ? { sandbox_profile_sha256: hash(profile), sandbox_profile: profile } : { network_isolation: 'no-NIC guest; only lo interface verified; no host seatbelt' }), total_timeout_ms: 120_000 };
const { query } = await import('@anthropic-ai/claude-agent-sdk');

function spawnNative(options, record) {
  const cliEnv = { ...env, CLAUDE_CODE_ENTRYPOINT: 'sdk-ts', CLAUDE_AGENT_SDK_VERSION: '0.3.295', CLAUDE_CODE_SDK_READS_SESSION_STATE: '1' };
  const launch = nativeLaunchCommand(options.command);
  const child = spawn(launch.command, [...launch.prefix, ...options.args], { cwd: options.cwd ?? CWD, env: cliEnv, stdio: ['pipe', 'pipe', 'pipe'], detached: true });
  children.add(child);
  record.pid = child.pid;
  record.launch = { command: options.command, args: options.args, env_keys: Object.keys(cliEnv), sdk_supplied_env_keys: Object.keys(options.env), dropped_sdk_env_keys: Object.keys(options.env).filter(k => !(k in cliEnv)) };
  let pending = '';
  child.stdout.on('data', chunk => {
    pending += chunk;
    const lines = pending.split('\n'); pending = lines.pop();
    for (const line of lines) if (line.trim()) { try { record.raw.push(JSON.parse(line)); } catch { record.raw_unparsed ??= []; record.raw_unparsed.push(line); } }
  });
  child.stderr.on('data', chunk => { record.stderr += chunk; });
  child.on('exit', (code, signal) => { record.process_exit = { code, signal, at: Date.now() }; children.delete(child); });
  evidence.children.push({ scenario: currentScenario, pid: child.pid });
  record.child = child;
  return child;
}

function gateRegisteredPrompt(input, registration, record) {
  const reasons = [];
  if (input.source !== 'sdk') reasons.push('source_not_sdk');
  if (input.prompt !== registration.prompt) reasons.push('prompt_not_registered');
  if (!input.prompt_id) reasons.push('prompt_id_missing');
  if (registration.session && input.session_id !== registration.session) reasons.push('session_mismatch');
  if (registration.consumed) reasons.push('already_consumed');
  const decision = reasons.length ? { decision: 'block', reason: `PoC registered-input gate: ${reasons.join(',')}` } : {};
  if (!reasons.length) { registration.consumed = true; registration.promptId = input.prompt_id; registration.session = input.session_id; }
  record.gates.push({ input, decision, client_uuid: registration.uuid, execution_epoch: registration.epoch });
  return decision;
}

async function runTurn(name, { resume, origin = { kind: 'human' }, synthetic = false, deny = false, unregister = false, textOnly = false, freezeOnHook = false } = {}) {
  if (totalExpired) throw new Error('PoC total timeout expired; refusing to spawn another CLI');
  currentScenario = name;
  const record = evidence.scenarios[name] = { events: [], raw: [], hooks: [], gates: [], permissions: [], stderr: '', started_at: Date.now(), fixture: false };
  const registration = { prompt: `POC_${name.toUpperCase()}: execute only the local simulation fixture.`, uuid: randomUUID(), epoch: randomUUID(), session: resume, consumed: false };
  record.registration = registration;
  if (textOnly) record.diagnostic_boundary = { authorization_contract_enabled: false, tools_disabled: true, purpose: 'Native text-only transport/session diagnostic; cannot qualify the execution design' };
  let initVerified = false;
  let pending;
  let doneInput;
  const inputDone = new Promise(resolve => { doneInput = resolve; });
  async function* input() { yield { type: 'user', uuid: registration.uuid, origin, isSynthetic: synthetic, session_id: resume ?? '', parent_tool_use_id: null, message: { role: 'user', content: registration.prompt } }; await inputDone; }
  q = query({ prompt: input(), options: {
    cwd: CWD, env, pathToClaudeCodeExecutable: CLI, model: 'claude-sonnet-4-6', maxTurns: 4,
    permissionMode: 'default', permissionPrompts: 'host', settingSources: [], allowedTools: [], allowDangerouslySkipPermissions: false,
    ...(textOnly ? { tools: [] } : {}),
    perTaskStopAffordance: true, persistSession: true, includePartialMessages: true,
    ...(resume ? { resume } : {}),
    spawnClaudeCodeProcess: options => spawnNative(options, record),
    hooks: {
      UserPromptSubmit: [{ hooks: [async input => {
        record.hooks.push({ kind: 'UserPromptSubmit', input });
        if (freezeOnHook) {
          record.stop_test = { fixture: true, injection: 'SIGSTOP native child group to force unresponsive CLI', started_at: Date.now(), execution_gate_invalidated: true };
          killGroup(record.child, 'SIGSTOP');
          setTimeout(() => {
            const start = Date.now();
            let settled = false;
            q.interrupt().then(response => { settled = true; record.stop_test.interrupt_response = response; record.stop_test.interrupt_settled_at = Date.now(); }, error => { settled = true; record.stop_test.interrupt_error = String(error); record.stop_test.interrupt_settled_at = Date.now(); });
            setTimeout(() => {
              record.stop_test.interrupt_settled_before_deadline = settled;
              record.stop_test.force_stop_at = Date.now();
              record.stop_test.force_stop_after_ms = Date.now() - start;
              record.stop_test.bound_target = { session_id: input.session_id, execution_epoch: registration.epoch, pid: record.child.pid };
              killGroup(record.child, 'SIGKILL');
              doneInput();
            }, 2_000);
          }, 0);
        }
        if (textOnly) { record.observed_prompt_hook_only = input; return {}; }
        return gateRegisteredPrompt(input, unregister ? { ...registration, prompt: 'not-registered' } : registration, record);
      }] }],
      PreToolUse: [{ hooks: [async input => {
        const valid = initVerified && registration.consumed && input.session_id === registration.session && input.prompt_id === registration.promptId;
        const decision = { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: valid ? 'ask' : 'deny', permissionDecisionReason: valid ? 'PoC requires explicit fixture approval' : 'PoC execution gate closed or binding mismatch' } };
        record.hooks.push({ kind: 'PreToolUse', input, decision, initVerified }); return decision;
      }] }],
      PostToolUse: [{ hooks: [async input => { record.hooks.push({ kind: 'PostToolUse', input }); return {}; }] }],
    },
    canUseTool: async (toolName, toolInput, options) => {
      const binding = { session: registration.session, execution_epoch: registration.epoch, requestId: options.requestId, toolUseID: options.toolUseID };
      const p = { toolName, input: toolInput, input_hash: hash(toolInput), binding, signal_initially_aborted: options.signal.aborted, started_at: Date.now(), fixture_decision: deny ? 'deny' : 'allow' };
      record.permissions.push(p);
      // These are explicit test-fixture choices within the delegated local-only scope.
      // They simulate App decisions; they do not prove human UI or broker authenticity.
      pending = p;
      await delay(150);
      p.target_exists_while_pending = await exists(toolInput.file_path ?? path.join(CWD, 'ask.txt'));
      if (options.signal.aborted) { p.resolved_at = Date.now(); return { behavior: 'deny', message: 'PoC request cancelled', toolUseID: options.toolUseID }; }
      const expectedWrite = toolName === 'Write' && options.toolUseID === `tool_poc_${name.toUpperCase()}` && toolInput.file_path === path.join(CWD, `${name}.txt`) && toolInput.content === `native-${name.toUpperCase()}\n`;
      const expectedQuestion = name === 'ask' && toolName === 'AskUserQuestion' && options.toolUseID === 'tool_poc_ASK' && toolInput.questions?.[0]?.question === 'Choose a local test option?';
      if (deny || textOnly || !(expectedWrite || expectedQuestion) || !initVerified || !registration.consumed) { p.resolved_at = Date.now(); return { behavior: 'deny', message: 'Explicit local fixture denial or fixture/binding mismatch', toolUseID: options.toolUseID }; }
      const updatedInput = toolName === 'AskUserQuestion' ? { ...toolInput, answers: { [toolInput.questions[0].question]: 'Alpha' } } : toolInput;
      p.updated_input_hash = hash(updatedInput); p.resolved_at = Date.now(); pending = undefined;
      return { behavior: 'allow', updatedInput, toolUseID: options.toolUseID };
    },
    stderr: text => { record.sdk_stderr = (record.sdk_stderr ?? '') + text; },
  } });
  const timer = setTimeout(() => { record.timeout = true; doneInput(); q.close(); killGroup(record.child, 'SIGKILL'); }, 25_000);
  try {
    for await (const message of q) {
      record.events.push(message);
      if (message.type === 'system' && message.subtype === 'init') {
        record.init = message;
        initVerified = message.permissionMode === 'default' && message.claude_code_version === '2.1.295' && message.apiKeySource === 'ANTHROPIC_API_KEY' && message.cwd === CWD && message.mcp_servers.length === 0;
      }
      if (message.type === 'result') { record.result = message; doneInput(); break; }
    }
  } catch (error) { record.error = String(error); }
  finally {
    clearTimeout(timer); doneInput(); q.close();
    await delay(250);
    if (record.child && hasGroup(record.child.pid)) { killGroup(record.child, 'SIGTERM'); await delay(300); }
    if (record.child && hasGroup(record.child.pid)) { killGroup(record.child, 'SIGKILL'); await delay(100); }
    record.process_group_empty = !record.child || !hasGroup(record.child.pid);
    record.pending_at_end = !!pending;
    record.finished_at = Date.now();
    delete record.child;
    console.log(JSON.stringify({ scenario: name, result: record.result?.subtype, error: record.error, hooks: record.hooks.length, gates: record.gates.map(g => ({ source: g.input.source, prompt_id: g.input.prompt_id, client_uuid: g.client_uuid, decision: g.decision })), permissions: record.permissions.length, group_empty: record.process_group_empty }));
  }
  return record;
}
async function exists(file) { try { await stat(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; } }
async function walk(dir) { const out = []; for (const entry of await readdir(dir, { withFileTypes: true })) { const p = path.join(dir, entry.name); if (entry.isDirectory()) out.push(...await walk(p)); else out.push(p); } return out; }

try {
  const version = await new Promise((resolve, reject) => {
    const launch = nativeLaunchCommand(CLI);
    const c = spawn(launch.command, [...launch.prefix, '--version'], { cwd: CWD, env, detached: true }); children.add(c);
    const versionTimer = setTimeout(() => killGroup(c, 'SIGKILL'), 5_000); versionTimer.unref();
    let output = ''; c.stdout.on('data', x => { output += x; }); c.stderr.on('data', x => { output += x; }); c.on('error', error => { clearTimeout(versionTimer); reject(error); }); c.on('exit', (code, signal) => { clearTimeout(versionTimer); children.delete(c); resolve({ code, signal, output: output.trim() }); });
  });
  evidence.cli_version = version;
  const first = await runTurn('first');
  const firstFile = path.join(CWD, 'first.txt');
  const before = await exists(firstFile) ? { content: await readFile(firstFile, 'utf8'), stat: await stat(firstFile) } : undefined;
  const session = first.result?.session_id ?? first.init?.session_id;
  if (session && first.result?.subtype === 'success' && first.process_group_empty) {
    const second = await runTurn('second', { resume: session });
    const after = await exists(firstFile) ? { content: await readFile(firstFile, 'utf8'), stat: await stat(firstFile) } : undefined;
    evidence.resume_assertions = { same_session: second.result?.session_id === session, first_process_ended_before_resume: first.process_group_empty, first_task_was_blocked: first.result.num_turns === 0, old_tool_reexecution_status: before ? 'observed' : 'blocked_no_first_tool_execution', old_file_content_unchanged: before && after ? before.content === after.content : null, old_file_mtime_unchanged: before && after ? before.stat.mtimeMs === after.stat.mtimeMs : null, old_tool_execution_count: Object.values(evidence.scenarios).flatMap(s => s.hooks).filter(h => h.kind === 'PostToolUse' && h.input.tool_use_id === 'tool_poc_FIRST').length, second_tool_execution_count: second.hooks.filter(h => h.kind === 'PostToolUse' && h.input.tool_use_id === 'tool_poc_SECOND').length };
  } else evidence.limitations.push('Native first turn failed; resume precondition not met.');
  await runTurn('deny', { deny: true });
  await runTurn('ask');
  await runTurn('unregistered', { unregister: true });
  await runTurn('system', { origin: { kind: 'task-notification' }, synthetic: true });
  const textFirst = await runTurn('textfirst', { textOnly: true });
  const textSession = textFirst.result?.session_id;
  if (textSession && textFirst.result?.num_turns > 0 && textFirst.process_group_empty) {
    const textSecond = await runTurn('textsecond', { resume: textSession, textOnly: true });
    evidence.text_session_assertions = { native: true, tools_disabled: true, first_result: textFirst.result?.result, second_result: textSecond.result?.result, same_session: textSecond.result?.session_id === textSession, new_cli_process: textSecond.pid !== textFirst.pid, first_group_empty_before_resume: textFirst.process_group_empty, first_client_uuid: textFirst.registration.uuid, second_client_uuid: textSecond.registration.uuid };
  }
  await runTurn('stop', { freezeOnHook: true });
  // A missing-source payload cannot be requested from the current native CLI.
  // This is a unit fixture only, and is labelled separately from native evidence.
  const fixtureRecord = { gates: [] };
  const fixtureRegistration = { prompt: 'fixture', uuid: randomUUID(), epoch: randomUUID(), session: 'fixture-session', consumed: false };
  const fixtureCases = [undefined, 'system'].map(source => {
    const input = { hook_event_name: 'UserPromptSubmit', prompt: 'fixture', prompt_id: 'fixture-prompt', session_id: 'fixture-session', ...(source ? { source } : {}) };
    return { source: source ?? 'missing', result: gateRegisteredPrompt(input, { ...fixtureRegistration }, fixtureRecord) };
  });
  evidence.gate_unit_fixtures = { fixture: true, cases: fixtureCases, native_missing_source: 'actually_observed_and_blocked; native_system_source_field_not_observed' };
} catch (error) { evidence.fatal_error = String(error); }
finally {
  if (q) q.close();
  for (const c of children) killGroup(c, 'SIGKILL');
  for (const socket of sockets) socket.destroy();
  server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  clearTimeout(totalTimer);
  const files = await walk(HOME);
  evidence.persisted_sessions = [];
  for (const file of files.filter(f => f.endsWith('.jsonl'))) {
    const bytes = await readFile(file, 'utf8');
    evidence.persisted_sessions.push({ relative_path: path.relative(RUN, file), sha256: hash(bytes), lines: bytes.trim().split('\n').length });
  }
  evidence.file_assertions = {};
  for (const name of ['first', 'second', 'deny', 'system', 'unregistered']) { const file = path.join(CWD, `${name}.txt`); evidence.file_assertions[name] = await exists(file) ? { exists: true, content: await readFile(file, 'utf8'), sha256: hash(await readFile(file)) } : { exists: false }; }
  evidence.finished_at = new Date().toISOString();
  evidence.surviving_process_groups = evidence.children.filter(c => hasGroup(c.pid));
  const sourceMissing = !Object.hasOwn(evidence.scenarios.first?.hooks.find(h => h.kind === 'UserPromptSubmit')?.input ?? {}, 'source');
  const toolHooks = Object.values(evidence.scenarios).flatMap(s => s.hooks.filter(h => h.kind === 'PreToolUse' || h.kind === 'PostToolUse'));
  const permissionCount = Object.values(evidence.scenarios).reduce((count, s) => count + s.permissions.length, 0);
  const systemHook = evidence.scenarios.system?.hooks.find(h => h.kind === 'UserPromptSubmit')?.input;
  evidence.conclusion = {
    supported_execution_combination: false,
    status: sourceMissing ? 'incompatible' : 'partial_native_capabilities_require_remaining_acceptance',
    blocker: sourceMissing ? 'Native CLI UserPromptSubmit hook_callback.input omits source, including first and resumed prompts' : 'Production scope and isolation acceptance not established by this fixture',
    actual_missing_source_rejection: evidence.scenarios.first?.gates[0]?.decision.decision === 'block' && !evidence.requests.some(r => r.scenario === 'first'),
    permission_pending_flow: permissionCount ? 'native_canUseTool_observed_with_explicit_local_fixture_decisions; see scenario evidence' : 'blocked_before_tool; no native canUseTool request observed',
    old_tool_not_reexecuted: evidence.resume_assertions?.old_tool_execution_count === 1 && evidence.resume_assertions?.second_tool_execution_count === 1 && evidence.resume_assertions.old_file_mtime_unchanged ? 'passed_local_fixture; scope_isolation_not_proved' : 'blocked_or_failed; zero observed tools is not proof',
    hook_prompt_id_to_tool_binding: toolHooks.length ? 'native_tool_hooks_observed; see scenario evidence' : 'blocked_before_tool',
    native_system_source_rejection: systemHook?.source === 'system' && evidence.scenarios.system?.gates[0]?.decision.decision === 'block' ? 'passed_native_system_source_rejection' : 'not_observed; see raw task-notification-origin input',
    process_group_stop_adapter: evidence.scenarios.stop?.process_group_empty && evidence.scenarios.stop?.stop_test?.interrupt_settled_before_deadline === false ? 'passed_local_failure_injection' : 'failed_or_missing',
    linux_cgroup_scope_stop: 'not_tested_by_process_group_fixture',
    real_authentication_and_billing: 'not_tested; fake_key_loopback_only',
  };
  await writeFile(path.join(RUN, 'evidence.json'), JSON.stringify(evidence, null, 2));
  await writeFile(path.join(ROOT, 'latest-run.json'), JSON.stringify({ run: RUN, evidence: path.join(RUN, 'evidence.json') }, null, 2));
  await mkdir(path.join(ROOT, 'evidence'), { recursive: true });
  const slim = {
    schema: 1, generated_at: evidence.finished_at, conclusion: evidence.conclusion,
    launch_manifest: evidence.launch_manifest, cli_version: evidence.cli_version,
    native_hook_samples: Object.fromEntries(['first', 'second', 'system', 'textfirst', 'textsecond'].map(name => {
      const s = evidence.scenarios[name];
      const raw = s?.raw.find(m => m.type === 'control_request' && m.request?.subtype === 'hook_callback')?.request.input;
      const sdk = s?.hooks.find(h => h.kind === 'UserPromptSubmit')?.input;
      return [name, { raw_cli_input: raw, sdk_callback_input: sdk, same_raw_sdk_input: JSON.stringify(raw) === JSON.stringify(sdk), native_source_present: raw ? Object.hasOwn(raw, 'source') : null, hooks_applied: s?.raw.find(m => m.type === 'control_response' && m.response?.response?.hooks_applied !== undefined)?.response.response.hooks_applied, client_uuid: s?.registration.uuid, prompt_id_differs_from_client_uuid: raw?.prompt_id !== s?.registration.uuid, result: s?.result ? { subtype: s.result.subtype, num_turns: s.result.num_turns, result: s.result.result, user_message_uuid: s.result.user_message_uuid, user_message_uuids: s.result.user_message_uuids, session_id: s.result.session_id, reported_cost_usd: s.result.total_cost_usd, cost_is_simulated_not_billing: true } : undefined, init: s?.init ? { permissionMode: s.init.permissionMode, cli_version: s.init.claude_code_version, apiKeySource: s.init.apiKeySource, tools: s.init.tools, capabilities: s.init.capabilities, mcp_servers: s.init.mcp_servers } : undefined, gate: s?.gates[0]?.decision, process_group_empty: s?.process_group_empty }];
    })),
    local_api_requests: evidence.requests.map(r => ({ scenario: r.scenario, url: r.url, remote: r.remote, auth_is_fake: r.auth_is_fake, body_hash: r.body_hash, marker: r.marker, prompt_markers: r.user_texts.map(t => [...t.matchAll(/POC_[A-Z]+/g)].map(m => m[0])), message_roles: r.message_roles, historical_tool_ids: r.historical_tool_ids, tool_result_ids: r.tool_result_ids, requested_tools: r.tool_names })),
    blocked_resume_assertions: evidence.resume_assertions, text_session_assertions: evidence.text_session_assertions,
    native_tool_permission_evidence: Object.fromEntries(Object.entries(evidence.scenarios).filter(([, s]) => s.permissions.length || s.hooks.some(h => h.kind !== 'UserPromptSubmit')).map(([name, s]) => [name, { registration: s.registration, hooks: s.hooks.filter(h => h.kind !== 'UserPromptSubmit'), permissions: s.permissions, assistant_tool_events: s.events.filter(m => m.type === 'assistant' && m.message?.content?.some(c => c.type === 'tool_use')), user_tool_results: s.events.filter(m => m.type === 'user' && Array.isArray(m.message?.content) && m.message.content.some(c => c.type === 'tool_result')) }])),
    stop_test: { ...evidence.scenarios.stop?.stop_test, sdk_result_present: !!evidence.scenarios.stop?.result, process_exit: evidence.scenarios.stop?.process_exit, process_group_empty: evidence.scenarios.stop?.process_group_empty },
    gate_unit_fixtures: evidence.gate_unit_fixtures, persisted_sessions: evidence.persisted_sessions,
    file_assertions: evidence.file_assertions, surviving_process_groups: evidence.surviving_process_groups,
    full_local_evidence: path.join(RUN, 'evidence.json'),
  };
  await writeFile(path.join(ROOT, 'evidence', 'native-session-summary.json'), serializePocSummary(slim, ROOT, hostHome.aliases));
  console.log(JSON.stringify({ evidence: path.join(RUN, 'evidence.json'), cli_version: evidence.cli_version, resume: evidence.resume_assertions, file_assertions: evidence.file_assertions, fatal_error: evidence.fatal_error, surviving_groups: evidence.surviving_process_groups }));
}
