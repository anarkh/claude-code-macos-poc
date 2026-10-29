// Real Linux SDK/CLI and no-NIC VM. All projects, credentials and provider
// responses are synthetic; this script never opens a real provider connection.
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { randomUUID } from 'node:crypto';
import { chmod, lstat, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';

const bundled = process.argv.length === 4 && process.argv[2] === '--runtime-root';
if (process.argv.length !== 2 && !bundled) throw new Error('INVALID_TEST_ARGUMENTS');
const runtimeRoot = bundled ? path.resolve(process.argv[3]) : fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
assert.equal(await realpath(runtimeRoot), runtimeRoot, 'runtime path must be canonical');
let blockedHostSDKImports = 0;
const hooks = registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier.includes('@anthropic-ai/')) { blockedHostSDKImports++; throw new Error('HOST_SDK_IMPORT_FORBIDDEN'); }
  return nextResolve(specifier, context);
} });
const moduleURL = name => pathToFileURL(path.join(runtimeRoot, 'sdk', name)).href;
const { runVMTextChat, productionLauncher } = await import(moduleURL('vm-text-chat.mjs'));
const { PROJECT_EXECUTION_CONTRACT } = await import(moduleURL('deepseek-text-chat.mjs'));
assert.equal(PROJECT_EXECUTION_CONTRACT, 'selected-directory-rw/v1');
const versions = JSON.parse(await readFile(path.join(runtimeRoot, 'host/text-runtime/images/base.json'), 'utf8'));
const TOOLS = ['Read', 'Write', 'Edit', 'Bash', 'Glob', 'Grep'];
const ACK = 'VM_PROJECT_NATIVE_OK';
const ORIGINAL = 'VM_PROJECT_ORIGINAL\n';
const EDITED = 'VM_PROJECT_EDITED\n';
const WRITTEN = 'VM_PROJECT_WRITTEN\n';
const BASH = 'VM_PROJECT_BASH_OK\n';
const OUTSIDE = 'VM_PROJECT_OUTSIDE_UNCHANGED\n';
const DEVICE_ID = '8'.repeat(64);
const SESSION_ID = '1fca2866-ad40-4dc2-bfeb-4f11403b0c6d';
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const receipts = [];
const FRAME_KINDS = new Set(['vm_config', 'ready', 'native_init', 'provider_request', 'tool_activity', 'result', 'vm_stopped', 'vm_launch_error']);
const safeCode = value => typeof value === 'string' && /^[A-Z0-9_]{1,80}$/.test(value) ? value : null;
const safeNumber = value => Number.isSafeInteger(value) ? value : null;
const safeBoolean = value => typeof value === 'boolean' ? value : null;
function safeConfig(frame) {
  return { network_devices: safeNumber(frame.network_devices), host_directory_shares: safeNumber(frame.host_directory_shares),
    directory_shares: safeNumber(frame.directory_shares), clipboard_devices: safeNumber(frame.clipboard_devices),
    graphics_devices: safeNumber(frame.graphics_devices), socket_devices: safeNumber(frame.socket_devices),
    cpu_count: safeNumber(frame.cpu_count), memory_bytes: safeNumber(frame.memory_bytes),
    disposable_disk: safeBoolean(frame.disposable_disk), vsock_port: safeNumber(frame.vsock_port),
    project_mount_matches: frame.project_mount === '/home/claude/project', project_read_only: safeBoolean(frame.project_read_only) };
}
function safeNative(frame, requestedSession) {
  return { no_tools: safeBoolean(frame.no_tools), project_mount_matches: frame.project_mount === '/home/claude/project',
    tools: Array.isArray(frame.tools) ? frame.tools.slice(0, 16).map(tool => TOOLS.includes(tool) ? tool : 'unknown') : null,
    model: typeof frame.model === 'string' && /^(?:deepseek-flash(?:\[1m\])?|claude-(?:sonnet|opus|haiku)-[a-z0-9-]{1,80})$/.test(frame.model) ? frame.model : 'unknown',
    session_id_is_uuid: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(frame.session_id ?? ''),
    ...(requestedSession ? { requested_session_preserved: frame.session_id === requestedSession } : {}) };
}

function response(model, tool) {
  const frames = [
    { type: 'message_start', message: { id: `msg_${tool?.id ?? 'project_final'}`, type: 'message', role: 'assistant',
      model, content: [], usage: { input_tokens: 20, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: tool ?
      { type: 'tool_use', id: tool.id, name: tool.name, input: {} } : { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: tool ?
      { type: 'input_json_delta', partial_json: JSON.stringify(tool.input) } : { type: 'text_delta', text: ACK } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: tool ? 'tool_use' : 'end_turn', stop_sequence: null }, usage: { output_tokens: 10 } },
    { type: 'message_stop' },
  ];
  const bytes = Buffer.from(frames.map(frame => `event: ${frame.type}\ndata: ${JSON.stringify(frame)}\n\n`).join(''));
  return { statusCode: 200, contentType: 'text/event-stream', stream: (async function* () {
    for (let offset = 0; offset < bytes.length; offset += 37) yield bytes.subarray(offset, offset + 37);
  })() };
}

function stepsFor(mode) {
  if (mode === 'symlink-escape') return [{ id: 'toolu_project_escape', name: 'Write',
    input: { file_path: '/home/claude/project/outside-link', content: 'MUST_NOT_REACH_HOST_OUTSIDE\n' } }];
  if (mode === 'cancel-bash') return [{ id: 'toolu_project_cancel', name: 'Bash', input: {
    command: "i=0\nwhile [ \"$i\" -lt 300 ]; do\n  printf 'tick\\n' >> cancel.txt\n  i=$((i + 1))\n  sleep 0.1\ndone",
  } }];
  return [
    { id: 'toolu_project_read', name: 'Read', input: { file_path: '/home/claude/project/input.txt' } },
    { id: 'toolu_project_edit', name: 'Edit', input: { file_path: '/home/claude/project/input.txt',
      old_string: ORIGINAL.trim(), new_string: EDITED.trim() } },
    { id: 'toolu_project_write', name: 'Write', input: { file_path: '/home/claude/project/output.txt', content: WRITTEN } },
    { id: 'toolu_project_bash', name: 'Bash', input: { command: "printf '%s\\n' VM_PROJECT_BASH_OK > bash.txt\ncat bash.txt" } },
    { id: 'toolu_project_glob', name: 'Glob', input: { pattern: 'output.txt', path: '/home/claude/project' } },
    { id: 'toolu_project_grep', name: 'Grep', input: { pattern: WRITTEN.trim(), path: '/home/claude/project/output.txt', output_mode: 'content' } },
  ];
}

async function run(provider, mode = 'success', model = provider === 'deepseek-api' ? 'deepseek-flash[1m]' : 'sonnet') {
  const root = await mkdtemp(path.join(await realpath(os.tmpdir()), 'vm-project-native-'));
  await chmod(root, 0o700);
  const projectDirectory = path.join(root, 'project');
  await mkdir(projectDirectory, { mode: 0o700 });
  await writeFile(path.join(projectDirectory, 'input.txt'), ORIGINAL, { mode: 0o600 });
  await writeFile(path.join(root, 'outside.txt'), OUTSIDE, { mode: 0o600 });
  await symlink('../outside.txt', path.join(projectDirectory, 'outside-link'));
  const projectBefore = await lstat(projectDirectory, { bigint: true });
  const input = { schema: 'deepseek-text-chat/v1', request_id: randomUUID(), provider,
    ...(provider === 'deepseek-api' ? { apiKey: 'sk-VM-PROJECT-INERT-NOT-A-REAL-CREDENTIAL' } : {
      subscriptionToken: 'sk-ant-oat01-VM-PROJECT-INERT-NOT-A-REAL-CREDENTIAL',
      identity: { device_id: DEVICE_ID, session_id: SESSION_ID },
    }), model,
    messages: [{ role: 'user', text: 'Exercise the selected project and report the requested synthetic acknowledgement.' }],
    text_skills: [], project: { directory: projectDirectory },
    network: { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:1', dnsPolicy: 'proxy-only' },
    runtime: { schema: 'app-runtime-profile/v1', timeZone: 'UTC', language: 'en' } };
  const controller = new AbortController(), steps = stepsFor(mode), events = [], frames = [];
  let stopped = false, launched = false, completed = false, providerCalls = 0, sentCredential = false, sentHostPath = false;
  let cancellationWriteObserved = false, cancellationTask, cancellationFailure, nativeSession, terminal, stage = 'runtime';
  let providerDiagnostic;
  const start = performance.now();
  const cancellationWatcher = async () => {
    const deadline = performance.now() + 15_000;
    try {
      while (!completed && performance.now() < deadline) {
        try {
          if ((await readFile(path.join(projectDirectory, 'cancel.txt'), 'utf8')).length > 0) {
            cancellationWriteObserved = true; controller.abort(); return;
          }
        } catch (error) { if (error.code !== 'ENOENT') throw error; }
        await delay(50);
      }
      if (!completed) throw new Error('SYNTHETIC_BASH_DID_NOT_START');
    } catch (error) { cancellationFailure = error; controller.abort(); }
  };
  try {
    terminal = await runVMTextChat(input, event => events.push(event), { testOnly: true,
      timeoutMs: 90_000, signal: controller.signal, emitTrace: false,
      launch: async (...arguments_) => {
        launched = true;
        const child = await productionLauncher(...arguments_);
        const originalWrite = child.stdin.write;
        child.stdin.write = function(chunk, ...rest) {
          const bytes = Buffer.from(chunk);
          sentCredential ||= bytes.includes(input.apiKey ?? input.subscriptionToken);
          sentHostPath ||= bytes.includes(projectDirectory);
          return originalWrite.call(this, chunk, ...rest);
        };
        let pending = '';
        child.stdout.on('data', chunk => {
          pending += chunk.toString('utf8');
          for (;;) {
            const newline = pending.indexOf('\n');
            if (newline < 0) break;
            const frame = JSON.parse(pending.slice(0, newline)); pending = pending.slice(newline + 1);
            frames.push(frame);
            if (frame.kind === 'vm_stopped' && frame.cleanup_complete === true) stopped = true;
            if (frame.kind === 'native_init') nativeSession = frame.session_id;
          }
        });
        return child;
      }, transport: async parameters => {
        stage = 'provider_contract';
        const turn = providerCalls++;
        providerDiagnostic = { request: turn + 1, previous_tool: steps[turn - 1]?.name ?? null,
          next_tool: steps[turn]?.name ?? null, last_assertion: null, assertion_tool: null,
          assertion_failed: false, results: [] };
        const check = (name, callback, tool = null) => {
          providerDiagnostic.last_assertion = name; providerDiagnostic.assertion_tool = tool;
          callback();
        };
        try {
          check('bounded_request_count', () => assert.ok(turn <= steps.length));
          check('enabled_tool_names', () => assert.deepEqual(parameters.body.tools.map(tool => tool.name).sort(), [...TOOLS].sort()));
          check('host_path_absent', () => assert.equal(JSON.stringify(parameters.body).includes(projectDirectory), false));
          check('network_policy', () => assert.equal(parameters.network.proxyURL, 'http://127.0.0.1:1'));
          if (provider === 'claude-subscription') {
            check('subscription_metadata_identity', () => assert.deepEqual(JSON.parse(parameters.body.metadata.user_id), { ...input.identity, account_uuid: '' }));
            check('subscription_header_identity', () => assert.equal(parameters.headers['x-claude-code-session-id'], SESSION_ID));
            check('native_session_identity', () => assert.equal(nativeSession, SESSION_ID));
          }
          if (turn) {
            const expectedContent = new Map([
              ['toolu_project_read', ORIGINAL.trim()], ['toolu_project_bash', BASH.trim()],
              ['toolu_project_glob', 'output.txt'], ['toolu_project_grep', WRITTEN.trim()],
            ]);
            const results = parameters.body.messages.flatMap(message => Array.isArray(message.content) ? message.content : [])
              .filter(block => block.type === 'tool_result');
            providerDiagnostic.results = results.map(result => ({
              tool: steps.find(step => step.id === result.tool_use_id)?.name ?? 'unknown',
              is_error: safeBoolean(result.is_error), is_error_present: Object.hasOwn(result, 'is_error'),
              content_type: typeof result.content === 'string' ? 'string' : Array.isArray(result.content) ? 'array' : 'other',
              content_bytes: Buffer.byteLength(JSON.stringify(result.content) ?? ''),
              ...(expectedContent.has(result.tool_use_id) ? {
                expected_marker_found: JSON.stringify(result.content)?.includes(expectedContent.get(result.tool_use_id)) === true,
              } : {}),
            }));
            check('tool_result_count', () => assert.equal(results.length, turn));
            check('last_tool_result_identity', () => assert.equal(results.at(-1).tool_use_id, steps[turn - 1].id), steps[turn - 1].name);
            if (mode === 'success') {
              for (const result of results) {
                const tool = steps.find(step => step.id === result.tool_use_id)?.name ?? 'unknown';
                check('tool_result_not_error', () => assert.notEqual(result.is_error, true), tool);
                const expected = expectedContent.get(result.tool_use_id);
                if (expected) check('tool_result_expected_content', () => assert.ok(JSON.stringify(result.content).includes(expected)), tool);
              }
            }
          }
          if (mode === 'cancel-bash' && turn === 0) cancellationTask = cancellationWatcher();
          return response(parameters.body.model, steps[turn]);
        } catch (error) {
          providerDiagnostic.assertion_failed = true;
          providerDiagnostic.error_code = safeCode(error?.code);
          providerDiagnostic.assertion_type = ['strictEqual', 'notStrictEqual', 'deepStrictEqual', '=='].includes(error?.operator) ? error.operator : 'other';
          throw error;
        }
      } });
    completed = true;
    stage = 'cancellation_watcher';
    await cancellationTask;
    if (cancellationFailure) throw cancellationFailure;
    stage = 'host_directory_preservation';
    const projectAfter = await lstat(projectDirectory, { bigint: true });
    assert.deepEqual([projectAfter.dev, projectAfter.ino], [projectBefore.dev, projectBefore.ino]);
    assert.equal(await readFile(path.join(root, 'outside.txt'), 'utf8'), OUTSIDE);
    assert.equal(sentCredential, false);
    assert.equal(sentHostPath, false);
    stage = 'vm_stop_receipt';
    assert.equal(stopped, true, 'VM cleanup receipt must confirm stop');
    stage = 'vm_isolation_configuration';
    const configs = frames.filter(frame => frame.kind === 'vm_config');
    assert.equal(configs.length, 1);
    assert.ok([1, 2].includes(configs[0].cpu_count));
    assert.deepEqual(configs[0], { kind: 'vm_config', network_devices: 0, host_directory_shares: 1, directory_shares: 1,
      clipboard_devices: 0, graphics_devices: 0, socket_devices: 1, cpu_count: configs[0].cpu_count,
      memory_bytes: 2_147_483_648, disposable_disk: true, vsock_port: 40124,
      project_mount: '/home/claude/project', project_read_only: false });
    stage = 'native_initialization';
    const native = frames.find(frame => frame.kind === 'native_init');
    assert.equal(native?.no_tools, false);
    assert.deepEqual([...native.tools].sort(), [...TOOLS].sort());
    assert.equal(events.filter(event => event.type === 'started' && event.no_tools === false).length, 1);
    if (mode === 'success') {
      stage = 'successful_completion';
      assert.equal(terminal.type, 'completed'); assert.equal(terminal.text, ACK); assert.equal(terminal.no_tools, false);
      assert.equal(terminal.temporary_removed, true); assert.equal(terminal.proxy_closed, true);
      assert.equal(terminal.request_count, steps.length + 1); assert.equal(providerCalls, steps.length + 1);
      stage = 'host_project_readback';
      assert.equal(await readFile(path.join(projectDirectory, 'input.txt'), 'utf8'), EDITED);
      assert.equal(await readFile(path.join(projectDirectory, 'output.txt'), 'utf8'), WRITTEN);
      assert.equal(await readFile(path.join(projectDirectory, 'bash.txt'), 'utf8'), BASH);
      stage = 'tool_activity_receipts';
      for (const step of steps) {
        assert.deepEqual(events.filter(event => event.type === 'tool_activity' && event.tool_id === step.id)
          .map(event => [event.tool, event.phase]), [[step.name, 'started'], [step.name, 'completed']]);
      }
    } else if (mode === 'symlink-escape') {
      stage = 'symlink_escape_rejection';
      assert.equal(terminal.type, 'error');
      assert.equal(providerCalls, 1, 'the escaped tool call must not continue into another provider turn');
      assert.equal(await readFile(path.join(projectDirectory, 'input.txt'), 'utf8'), ORIGINAL);
    } else {
      stage = 'active_command_cancellation';
      assert.equal(cancellationWriteObserved, true, 'cancel a running command, not merely an idle VM');
      assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'PROCESS_INTERRUPTED');
      assert.equal(providerCalls, 1);
      const atStop = await readFile(path.join(projectDirectory, 'cancel.txt'), 'utf8');
      assert.ok(atStop.length > 0);
      await delay(750);
      assert.equal(await readFile(path.join(projectDirectory, 'cancel.txt'), 'utf8'), atStop, 'VM stop must end project writes');
    }
    const receipt = { provider, model: input.model, mode, terminal: terminal.type, error_code: terminal.code ?? null,
      provider_calls: providerCalls, duration_seconds: +((performance.now() - start) / 1000).toFixed(2),
      no_network_interfaces: true, only_selected_directory_shared: true, selected_directory_retained: true,
      outside_sentinel_unchanged: true, host_credential_absent_from_guest: true, host_path_absent_from_provider: true,
      vm_stopped: true, ...(mode === 'success' ? { host_read_edit_write_bash_verified: true, glob_grep_results_verified: true } : {}),
      ...(mode === 'cancel-bash' ? { active_bash_cancelled: true, no_writes_after_vm_stop: true } : {}),
      real_provider_calls: false };
    receipts.push(receipt); console.error(JSON.stringify(receipt));
  } catch (error) {
    // Diagnostics contain fixed protocol fields only. Do not print assertion
    // operands, provider bodies, native tool results or exception messages.
    console.error(JSON.stringify({ schema: 'vm-project-native-failure/v1', provider, model: input.model, mode, stage,
      terminal: ['completed', 'error'].includes(terminal?.type) ? terminal.type : null,
      error_code: safeCode(terminal?.code), assertion_code: safeCode(error?.code),
      frame_kinds: frames.map(frame => FRAME_KINDS.has(frame.kind) ? frame.kind : 'unknown').slice(0, 256),
      vm_config: frames.filter(frame => frame.kind === 'vm_config').map(safeConfig),
      native_init: frames.filter(frame => frame.kind === 'native_init').map(frame => safeNative(frame, input.identity?.session_id)),
      provider_diagnostic: providerDiagnostic ?? null,
      tool_activities: events.filter(event => event.type === 'tool_activity').map(event => ({
        tool: TOOLS.includes(event.tool) ? event.tool : 'unknown',
        phase: ['started', 'completed', 'failed'].includes(event.phase) ? event.phase : 'unknown',
      })),
      provider_calls: providerCalls, vm_stopped: stopped, active_bash_write_observed: cancellationWriteObserved,
      real_provider_calls: false }));
    throw new Error(`VM_PROJECT_GATE_FAILED:${stage}`);
  } finally {
    completed = true; controller.abort(); await cancellationTask;
    // A missing VM-stop receipt retains this restricted synthetic directory for
    // diagnosis. Never delete a directory an unconfirmed VM may still be using.
    if (!launched || stopped) await rm(root, { recursive: true, force: true });
  }
}

try {
  await run('deepseek-api');
  for (const model of ['sonnet', 'opus', 'haiku']) await run('claude-subscription', 'success', model);
  await run('deepseek-api', 'symlink-escape');
  await run('deepseek-api', 'cancel-bash');
  assert.equal(receipts.length, 6);
  assert.equal(blockedHostSDKImports, 0);
  console.log(JSON.stringify({ schema: 'vm-project-native-gate/v1', status: 'passed_local_native_vm',
    artifact: bundled ? 'bundled_runtime' : 'source_runtime', runs: receipts.length,
    sdk_version: versions.sdk_version, cli_version: versions.cli_version,
    host_sdk_import_attempts: blockedHostSDKImports, real_credentials_read: false,
    real_provider_calls: false, real_subscription_verified: false, receipts }, null, 2));
} finally { hooks.deregister(); }
