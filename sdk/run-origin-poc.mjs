// Real official SDK/native CLI; fake key and local simulated model responses only.
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdir, writeFile, readFile, readdir, stat } from 'node:fs/promises';
import { randomUUID, createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveHostHome, createPocSandboxProfile, serializePocSummary } from './poc-host-privacy.mjs';
import { OriginContract, inputHash } from './origin-contract.mjs';
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const hostHome = await resolveHostHome();
const RUN = path.join(ROOT, 'runs', `origin-${new Date().toISOString().replaceAll(':', '-')}`);
const HOME = path.join(RUN, 'home'), CWD = path.join(RUN, 'workspace');
const platformPackage = process.platform === 'darwin' ? 'darwin' : process.platform === 'linux' ? 'linux' : undefined;
if (!platformPackage || !['arm64', 'x64'].includes(process.arch)) throw new Error('Unsupported platform');
if (process.platform === 'linux' && JSON.stringify(await readdir('/sys/class/net')) !== '["lo"]') throw new Error('Linux runner requires no-NIC VM; only lo permitted');
const CLI = path.join(ROOT, `node_modules/@anthropic-ai/claude-agent-sdk-${platformPackage}-${process.arch}/claude`);
const FAKE_KEY = 'sk-ant-api03-POC-FAKE-NOT-VALID';
const hash = v => createHash('sha256').update(v).digest('hex');
const delay = ms => new Promise(r => setTimeout(r, ms));
const evidence = { schema: 1, fixture: true, simulation: true, started_at: new Date().toISOString(), platform: process.platform, cli_sha256: hash(await readFile(CLI)), origin_contract_sha256: hash(await readFile(path.join(ROOT, 'origin-contract.mjs'))), scenarios: {}, local_api_requests: [], children: [], limitations: [] };
const children = new Set(), sockets = new Set();
let currentScenario = '', apiIndex = 0, q, expired = false;
await mkdir(HOME, { recursive: true }); await mkdir(CWD, { recursive: true }); await mkdir(path.join(RUN, 'tmp'), { recursive: true });
function killGroup(c, signal) { if (!c?.pid) return; try { process.kill(-c.pid, signal); } catch (e) { if (e.code !== 'ESRCH') throw e; } }
function hasGroup(pid) { try { process.kill(-pid, 0); return true; } catch(e) { if (e.code === 'ESRCH') return false; throw e; } }
async function exists(p) { try { await stat(p); return true; } catch(e) { if (e.code === 'ENOENT') return false; throw e; } }
function text(message) { return typeof message.content === 'string' ? message.content : (message.content ?? []).filter(x => x.type === 'text').map(x => x.text).join('\n'); }
function respond(res, body, blocks) {
  const stop = blocks[0].type === 'tool_use' ? 'tool_use' : 'end_turn';
  const message = { id: `msg_origin_${++apiIndex}`, type: 'message', role: 'assistant', model: body.model, content: blocks, stop_reason: stop, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 10 } };
  if (!body.stream) { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(message)); return; }
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const send = (event, obj) => res.write(`event: ${event}\ndata: ${JSON.stringify(obj)}\n\n`);
  send('message_start', { type: 'message_start', message: { ...message, content: [], stop_reason: null, usage: { input_tokens: 10, output_tokens: 0 } } });
  blocks.forEach((b, index) => { send('content_block_start', { type: 'content_block_start', index, content_block: b.type === 'text' ? { type: 'text', text: '' } : { ...b, input: {} } }); send('content_block_delta', { type: 'content_block_delta', index, delta: b.type === 'text' ? { type: 'text_delta', text: b.text } : { type: 'input_json_delta', partial_json: JSON.stringify(b.input) } }); send('content_block_stop', { type: 'content_block_stop', index }); });
  send('message_delta', { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 10 } }); send('message_stop', { type: 'message_stop' }); res.end();
}
const server = http.createServer(async (req, res) => {
  let bytes = ''; for await (const chunk of req) { bytes += chunk; if (bytes.length > 3_000_000) { res.writeHead(413); res.end(); return; } }
  let body; try { body = JSON.parse(bytes || '{}'); } catch { res.writeHead(400); res.end(); return; }
  if (req.url?.startsWith('/v1/messages/count_tokens')) { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"input_tokens":10}'); return; }
  if (!req.url?.startsWith('/v1/messages')) { res.writeHead(404); res.end(); return; }
  const messages = body.messages ?? [];
  const users = messages.filter(m => m.role === 'user').map(text);
  const marker = [...users.join('\n').matchAll(/ORIGIN_(FIRST|SECOND|DENY|ASK|UNKNOWN|STALE|DUPLICATE)/g)].at(-1)?.[1];
  const results = messages.flatMap(m => Array.isArray(m.content) ? m.content.filter(x => x.type === 'tool_result') : []);
  const tools = messages.flatMap(m => Array.isArray(m.content) ? m.content.filter(x => x.type === 'tool_use') : []);
  evidence.local_api_requests.push({ scenario: currentScenario, remote: req.socket.remoteAddress, auth_is_fake: req.headers['x-api-key'] === FAKE_KEY, marker, user_text_sha256: users.map(inputHash), tool_use_ids: tools.map(t => t.id), tool_result_ids: results.map(t => t.tool_use_id), requested_tools: (body.tools ?? []).map(t => t.name) });
  const id = `origin-tool-${marker}`;
  let block;
  if (!marker || results.some(r => r.tool_use_id === id)) block = { type: 'text', text: `ORIGIN_${marker ?? 'HELPER'} fixture completed.` };
  else if (marker === 'ASK') block = { type: 'tool_use', id, name: 'AskUserQuestion', input: { questions: [{ question: 'Fixture only: select a local option?', header: 'Fixture', options: [{ label: 'Alpha', description: 'Fixture Alpha' }, { label: 'Beta', description: 'Fixture Beta' }], multiSelect: false }] } };
  else block = { type: 'tool_use', id, name: 'Write', input: { file_path: path.join(CWD, `${marker.toLowerCase()}.txt`), content: `actual-native-${marker}\n` } };
  respond(res, body, [block]);
});
server.on('connection', s => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
await new Promise(r => server.listen(0, '127.0.0.1', r)); const port = server.address().port;
const sb = createPocSandboxProfile({ sdkRoot: ROOT, hostHome: hostHome.path, port });
const profile = path.join(RUN, 'cli.sb'); await writeFile(profile, sb);
const env = { PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin`, HOME, TMPDIR: path.join(RUN, 'tmp'), CLAUDE_CONFIG_DIR: path.join(HOME, '.claude'), ANTHROPIC_API_KEY: FAKE_KEY, ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1', CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1', CLAUDE_CODE_DISABLE_CRON: '1', CLAUDE_CODE_DISABLE_AGENT_VIEW: '1', CLAUDE_CODE_SKIP_BASH_ENVIRONMENT_SNAPSHOT: '1', CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1' };
evidence.launch_manifest = { environment_keys: Object.keys(env), base_url: env.ANTHROPIC_BASE_URL, fake_key: true, setting_sources: [], permission_mode: 'default', tools: ['Write', 'AskUserQuestion'], allowed_tools: [], sdk_version: '0.3.295', cli_expected: '2.1.295', total_timeout_ms: 120_000, seatbelt_profile_sha256: process.platform === 'darwin' ? hash(sb) : null, linux_no_nic_checked: process.platform === 'linux' };
const totalTimer = setTimeout(() => { expired = true; evidence.total_timeout = true; q?.close(); for (const c of children) killGroup(c, 'SIGKILL'); server.closeAllConnections(); }, 120_000);
const { query } = await import('@anthropic-ai/claude-agent-sdk');

function spawnNative(options, record, contract) {
  const cliEnv = { ...env, CLAUDE_CODE_ENTRYPOINT: 'sdk-ts', CLAUDE_AGENT_SDK_VERSION: '0.3.295', CLAUDE_CODE_SDK_READS_SESSION_STATE: '1' };
  if (options.command !== CLI) throw new Error('Refusing non-pinned CLI');
  const child = process.platform === 'darwin' ? spawn('/usr/bin/sandbox-exec', ['-f', profile, CLI, ...options.args], { cwd: CWD, env: cliEnv, stdio: ['pipe', 'pipe', 'pipe'], detached: true }) : spawn(CLI, options.args, { cwd: CWD, env: cliEnv, stdio: ['pipe', 'pipe', 'pipe'], detached: true });
  record.child = child; record.pid = child.pid; children.add(child); evidence.children.push({ scenario: currentScenario, pid: child.pid });
  record.launch = { command: CLI, args: options.args, env_keys: Object.keys(cliEnv), dropped_sdk_env_keys: Object.keys(options.env).filter(k => !(k in cliEnv)) };
  let outgoing = '';
  const originalWrite = child.stdin.write;
  child.stdin.write = function(chunk, ...rest) {
    outgoing += typeof chunk === 'string' ? chunk : chunk.toString();
    const lines = outgoing.split('\n'); outgoing = lines.pop();
    for (const line of lines) if (line.trim()) { try { const m = JSON.parse(line); record.raw_outgoing ??= []; record.raw_outgoing.push(m); if (m.type === 'control_request' && m.request?.subtype === 'initialize') record.initialize_request = m; } catch { record.outgoing_unparsed ??= []; record.outgoing_unparsed.push(line); } }
    return Reflect.apply(originalWrite, this, [chunk, ...rest]);
  };
  let buf = '';
  child.stdout.on('data', chunk => { buf += chunk; const lines = buf.split('\n'); buf = lines.pop(); for (const line of lines) { if (!line.trim()) continue; let m; try { m = JSON.parse(line); } catch { record.unparsed ??= []; record.unparsed.push(line); continue; } record.raw.push(m); if (m.type === 'control_response' && m.response?.request_id === record.initialize_request?.request_id && m.response?.response?.hooks_applied !== undefined) { record.initialize_response = m.response.response; record.initialize_ack_request_id = m.response.request_id; } if (m.type === 'system' && m.subtype === 'init') { record.raw_init = m; contract.markInit(m, CWD); } if (m.type === 'result') contract.seal('native_result'); } });
  child.stderr.on('data', chunk => { record.stderr += chunk; });
  child.on('exit', (code, signal) => { contract.seal('native_exit'); record.process_exit = { code, signal }; children.delete(child); });
  return child;
}
async function runTurn(name, { resume, deny = false, oldPrompt, duplicate = false } = {}) {
  if (expired) throw new Error('Total deadline expired'); currentScenario = name;
  const c = new OriginContract({ requestId: randomUUID(), revision: 1, clientUuid: randomUUID(), epoch: randomUUID(), expectedSession: resume, body: `ORIGIN_${name.toUpperCase()}: local fake-response fixture only.` });
  const record = evidence.scenarios[name] = { fixture: true, raw: [], events: [], hooks: [], permissions: [], stderr: '' };
  let doneInput; const end = new Promise(r => { doneInput = r; });
  let policyReadyResolve; const policyReady = new Promise(r => { policyReadyResolve = r; });
  async function* input() { await policyReady; yield { type: 'user', uuid: c.clientUuid, session_id: resume ?? '', parent_tool_use_id: null, message: { role: 'user', content: oldPrompt ?? (name === 'unknown' ? 'ORIGIN_UNKNOWN unregistered input' : c.prompt) } }; if (duplicate) yield { type: 'user', uuid: randomUUID(), session_id: resume ?? '', parent_tool_use_id: null, message: { role: 'user', content: c.prompt } }; await end; }
  q = query({ prompt: input(), options: { cwd: CWD, env, pathToClaudeCodeExecutable: CLI, model: 'claude-sonnet-4-6', maxTurns: 3, permissionMode: 'default', permissionPrompts: 'host', settingSources: [], tools: ['Write', 'AskUserQuestion'], allowedTools: [], allowDangerouslySkipPermissions: false, perTaskStopAffordance: true, persistSession: true, includePartialMessages: true, ...(resume ? { resume } : {}), spawnClaudeCodeProcess: options => spawnNative(options, record, c), hooks: {
    UserPromptSubmit: [{ hooks: [async input => { const output = c.onUserPrompt(input); record.hooks.push({ kind: 'UserPromptSubmit', input, output }); return output; }] }],
    PreToolUse: [{ hooks: [async input => { const output = c.onPreTool(input); record.hooks.push({ kind: 'PreToolUse', input, output }); return output; }] }],
    PostToolUse: [{ hooks: [async input => { record.hooks.push({ kind: 'PostToolUse', input }); return {}; }] }],
    Stop: [{ hooks: [async input => { c.seal('Stop'); record.hooks.push({ kind: 'Stop', input }); return {}; }] }],
    StopFailure: [{ hooks: [async input => { c.seal('StopFailure'); record.hooks.push({ kind: 'StopFailure', input }); return {}; }] }],
  }, canUseTool: async (name, input, options) => {
    const permission = { toolName: name, input, request_id: options.requestId, tool_use_id: options.toolUseID, fixture: true, decision: deny ? 'deny' : 'allow' }; record.permissions.push(permission);
    const isWrite = name === 'Write' && input.file_path === path.join(CWD, `${currentScenario}.txt`) && input.content === `actual-native-${currentScenario.toUpperCase()}\n`;
    const isAsk = currentScenario === 'ask' && name === 'AskUserQuestion' && input.questions?.[0]?.question === 'Fixture only: select a local option?';
    const updatedInput = isAsk ? { ...input, answers: { [input.questions[0].question]: 'Alpha' } } : input;
    const result = await c.onCanUseTool(name, input, options, { fixtureDecision: deny || !(isWrite || isAsk) ? 'deny' : 'allow', updatedInput, beforeDecision: async () => { await delay(150); permission.target_exists_while_pending = await exists(input.file_path ?? path.join(CWD, 'ask.txt')); } });
    permission.output = result; return result;
  } } });
  const timer = setTimeout(() => { c.seal('turn_deadline'); record.timeout = true; doneInput(); q.close(); killGroup(record.child, 'SIGKILL'); }, 20_000);
  const policyPromise = (async () => {
    try {
      record.hooks_listing = await q.getHooksListing();
      record.settings = await q.getSettings();
      record.permission_rules = await q.listPermissionRules();
      const hookEvents = Object.keys(record.initialize_request?.request?.hooks ?? {});
      record.extracted_hook_events = hookEvents;
      c.markHandshake({ hooksApplied: record.initialize_response?.hooks_applied, hookEvents, permissionMode: record.initialize_response?.current_permission_mode, settingSourcesVerified: record.launch.args.includes('--setting-sources=') && Array.isArray(record.settings.sources) && record.settings.sources.length === 0 });
    } catch (error) { record.policy_error = String(error); c.seal('policy_probe_failed'); }
    finally { policyReadyResolve(); }
  })();
  try { for await (const m of q) { record.events.push(m); if (m.type === 'result') { record.result = m; doneInput(); break; } } } catch (error) { record.error = String(error); }
  finally { clearTimeout(timer); doneInput(); c.seal('adapter_finally'); q.close(); await policyPromise; await delay(150); if (record.child && hasGroup(record.child.pid)) { killGroup(record.child, 'SIGTERM'); await delay(250); } if (record.child && hasGroup(record.child.pid)) { killGroup(record.child, 'SIGKILL'); await delay(100); } record.process_group_empty = !record.child || !hasGroup(record.child.pid); delete record.child; record.contract = c.snapshot(); console.log(JSON.stringify({ scenario: name, result: record.result?.subtype, turns: record.result?.num_turns, permission_count: record.permissions.length, hooks: record.hooks.map(x => x.kind), sealed_reason: record.contract.sealed_reason, empty: record.process_group_empty })); }
  return { record, prompt: c.prompt };
}

try {
  const first = await runTurn('first'); const firstPath = path.join(CWD, 'first.txt'); const before = await exists(firstPath) ? await stat(firstPath) : null;
  const session = first.record.result?.session_id;
  if (session && first.record.process_group_empty) { const second = await runTurn('second', { resume: session }); const after = await exists(firstPath) ? await stat(firstPath) : null; evidence.resume = { same_session: second.record.result?.session_id === session, new_cli: second.record.pid !== first.record.pid, first_group_empty: first.record.process_group_empty, actual_first_write: !!before, first_mtime_unchanged: before && after ? before.mtimeMs === after.mtimeMs : null, first_post_tool_count: Object.values(evidence.scenarios).flatMap(s => s.hooks).filter(h => h.kind === 'PostToolUse' && h.input.tool_use_id === 'origin-tool-FIRST').length, second_post_tool_count: second.record.hooks.filter(h => h.kind === 'PostToolUse' && h.input.tool_use_id === 'origin-tool-SECOND').length }; }
  await runTurn('deny', { deny: true }); await runTurn('ask'); await runTurn('unknown'); await runTurn('stale', { resume: session, oldPrompt: first.prompt }); await runTurn('duplicate', { duplicate: true });
} catch (error) { evidence.fatal_error = String(error); }
finally {
  q?.close(); for (const c of children) killGroup(c, 'SIGKILL'); for (const s of sockets) s.destroy(); server.closeAllConnections(); await new Promise(r => server.close(r)); clearTimeout(totalTimer);
  evidence.finished_at = new Date().toISOString(); evidence.cli_sha256_after = hash(await readFile(CLI)); evidence.surviving_groups = evidence.children.filter(c => hasGroup(c.pid)); evidence.files = {};
  for (const name of ['first', 'second', 'deny', 'unknown', 'stale', 'duplicate']) { const p = path.join(CWD, `${name}.txt`); evidence.files[name] = await exists(p) ? { exists: true, sha256: hash(await readFile(p)), content: await readFile(p, 'utf8') } : { exists: false }; }
  const s = evidence.scenarios; const passedWrites = evidence.files.first.exists && evidence.files.second.exists && !evidence.files.deny.exists;
  const registeredPromptBlocked = name => s[name]?.hooks.find(h => h.kind === 'UserPromptSubmit')?.output.decision === 'block' && !evidence.local_api_requests.some(r => r.scenario === name);
  const askJoined = s.ask?.permissions.length === 1 && s.ask.permissions[0].output.behavior === 'allow' && s.ask.hooks.some(h => h.kind === 'PostToolUse' && h.input.tool_name === 'AskUserQuestion');
  const duplicateHooks = s.duplicate?.hooks.filter(h => h.kind === 'UserPromptSubmit') ?? [];
  const duplicateRejected = duplicateHooks.length === 2 && duplicateHooks[1].output.decision === 'block' && s.duplicate.hooks.filter(h => h.kind === 'PostToolUse').length === 1;
  evidence.native_acceptance = { write_allow_deny: !!passedWrites, ask_joined: !!askJoined, unknown_rejected_before_api: registeredPromptBlocked('unknown'), stale_rejected_before_api: registeredPromptBlocked('stale'), duplicate_second_input_rejected: !!duplicateRejected, raw_source_present: Object.fromEntries(Object.entries(s).map(([name,r]) => [name,r.hooks.filter(h => h.kind === 'UserPromptSubmit').map(h => Object.hasOwn(h.input,'source'))])) };
  const allNative = passedWrites && askJoined && evidence.native_acceptance.unknown_rejected_before_api && evidence.native_acceptance.stale_rejected_before_api && duplicateRejected;
  evidence.conclusion = { origin_contract_native_status: allNative && evidence.resume?.first_post_tool_count === 1 && evidence.resume?.second_post_tool_count === 1 && evidence.resume?.first_mtime_unchanged ? 'passed_local_native_fixture' : 'blocked_or_failed', raw_source_not_fabricated: true, authoritative_identity: 'App exact one-time registration; optional CLI source is advisory and restrictive if present', permission_binding: 'actual native UserPromptSubmit.prompt_id JOIN PreToolUse.prompt_id/session/tool_use_id/input hash to canUseTool.toolUseID/requestId', native_scope_isolation: 'not_proved_by_this_runner', real_auth_or_billing: 'not_tested_fake_key', passed_writes: !!passedWrites, empty_process_groups: evidence.surviving_groups.length === 0 };
  await writeFile(path.join(RUN, 'evidence.json'), JSON.stringify(evidence, null, 2)); await mkdir(path.join(ROOT, 'evidence'), { recursive: true });
  const slim = { schema: 1, generated_at: evidence.finished_at, platform: evidence.platform, full_local_evidence: path.join(RUN, 'evidence.json'), launch_manifest: evidence.launch_manifest, cli_sha256: evidence.cli_sha256, origin_contract_sha256: evidence.origin_contract_sha256, cli_sha256_after: evidence.cli_sha256_after, conclusion: evidence.conclusion, local_api_requests: evidence.local_api_requests, scenarios: Object.fromEntries(Object.entries(s).map(([name, r]) => [name, { pid: r.pid, initialize_request: r.initialize_request, initialize_ack_request_id: r.initialize_ack_request_id, initialize_verified: r.initialize_response ? { hooks_applied: r.initialize_response.hooks_applied, permission_mode: r.initialize_response.current_permission_mode } : null, hooks_listing: r.hooks_listing, extracted_hook_events: r.extracted_hook_events, native_init: r.raw_init ? { session_id: r.raw_init.session_id, tools: r.raw_init.tools, permissionMode: r.raw_init.permissionMode, cli_version: r.raw_init.claude_code_version, apiKeySource: r.raw_init.apiKeySource } : null, contract: r.contract, native_hooks: r.hooks, permissions: r.permissions, result: r.result ? { subtype: r.result.subtype, num_turns: r.result.num_turns, session_id: r.result.session_id, result: r.result.result, permission_denials: r.result.permission_denials } : null, process_group_empty: r.process_group_empty, error: r.error, policy_error: r.policy_error }])), native_acceptance: evidence.native_acceptance, files: evidence.files, resume: evidence.resume, surviving_groups: evidence.surviving_groups, fatal_error: evidence.fatal_error };
  const summary = path.join(ROOT, 'evidence', `origin-native-${process.platform}-summary.json`); await writeFile(summary, serializePocSummary(slim, ROOT, hostHome.aliases));
  await writeFile(path.join(ROOT, 'origin-latest-run.json'), JSON.stringify({ run: RUN, evidence: path.join(RUN, 'evidence.json'), summary }, null, 2)); console.log(JSON.stringify({ summary, conclusion: evidence.conclusion, files: evidence.files, resume: evidence.resume, fatal_error: evidence.fatal_error }));
}
