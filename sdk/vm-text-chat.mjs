// Trusted host broker. Anthropic SDK/native code runs only in the no-NIC VM.
import { spawn } from 'node:child_process';
import { access, open, readFile, realpath, rm, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createOwnedRunDirectory, waitForNativeProcessExit } from './owned-run-directory.mjs';
import { validateInput, providerBody, subscriptionHeaders, officialTransport, tracedProviderRequest, relaySse,
  EVENT_SCHEMA, TEXT_IDENTITY_CONTRACT, PROJECT_EXECUTION_CONTRACT } from './deepseek-text-chat.mjs';
import { PROJECT_TOOLS, PROJECT_MOUNT } from './project-provider-protocol.mjs';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const FRAME_LIMIT = 1_048_576;
const STOP_DRAIN_TIMEOUT_MS = 20_000;
const EMPTY_UUID = '00000000-0000-0000-0000-000000000000';
export class VMFailure extends Error { constructor(code) { super(code); this.code = code; } }
const fail = code => { throw new VMFailure(code); };
async function waitUntilOrTimeout(promise, milliseconds) {
  let timer;
  try { await Promise.race([promise, new Promise(resolve => { timer = setTimeout(resolve, milliseconds); })]); }
  finally { clearTimeout(timer); }
}
function only(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(k => keys.includes(k));
}
function verifyRequestedIdentity(body, headers, expected) {
  let identity;
  try { identity = JSON.parse(body?.metadata?.user_id); } catch { fail('NATIVE_IDENTITY_MISMATCH'); }
  if (identity?.device_id !== expected.device_id || identity.session_id !== expected.session_id ||
      identity.account_uuid !== '' || headers?.['x-claude-code-session-id'] !== expected.session_id) fail('NATIVE_IDENTITY_MISMATCH');
}

export async function validateProjectDirectory(project) {
  if (!only(project, ['directory']) || typeof project.directory !== 'string' ||
      !path.isAbsolute(project.directory) || project.directory === '/' || project.directory.includes('\0') ||
      Buffer.byteLength(project.directory) > 4096 || path.normalize(project.directory) !== project.directory) fail('INVALID_PROJECT_DIRECTORY');
  let handle;
  try {
    const directory = await realpath(project.directory);
    if (directory !== project.directory) fail('PROJECT_DIRECTORY_CHANGED');
    const home = await realpath(os.homedir());
    const privateRoot = path.join(home, 'Library/Application Support/ClaudeIsolationPoC');
    const within = (candidate, parent) => candidate === parent || candidate.startsWith(parent + path.sep);
    if (directory === home || within(directory, privateRoot) || within(privateRoot, directory)) fail('PROJECT_DIRECTORY_FORBIDDEN');
    handle = await open(directory, 'r');
    const before = await handle.stat({ bigint: true });
    if (!before.isDirectory()) fail('PROJECT_DIRECTORY_UNAVAILABLE');
    await access(directory, constants.R_OK | constants.W_OK | constants.X_OK);
    const after = await stat(directory, { bigint: true });
    if (await realpath(directory) !== directory || before.dev !== after.dev || before.ino !== after.ino) fail('PROJECT_DIRECTORY_CHANGED');
    return { directory, dev: before.dev.toString(), ino: before.ino.toString() };
  } catch (error) {
    if (error instanceof VMFailure) throw error;
    fail('PROJECT_DIRECTORY_UNAVAILABLE');
  } finally { await handle?.close(); }
}

export async function productionLauncher(runtimeRoot = ROOT, project) {
  let config;
  const base = path.join(runtimeRoot, 'host/text-runtime');
  try { config = JSON.parse(await readFile(path.join(base, 'runtime-config.json'), 'utf8')); }
  catch { fail('VM_RUNTIME_UNAVAILABLE'); }
  if (!only(config, ['schema', 'image_dir', 'runner', 'guest_runtime_dir', 'python']) ||
      config.schema !== 'claude-vm-runtime/v1' || typeof config.python !== 'string' ||
      !path.isAbsolute(config.python)) fail('VM_RUNTIME_INVALID');
  const resolve = key => {
    if (typeof config[key] !== 'string' || !config[key]) fail('VM_RUNTIME_INVALID');
    return path.resolve(base, config[key]);
  };
  const image = resolve('image_dir'), runner = resolve('runner'), guest = resolve('guest_runtime_dir');
  const selected = project ? await validateProjectDirectory(project) : undefined;
  const ownedRun = await createOwnedRunDirectory('chat');
  ownedRun.markNativeLaunchPending();
  const child = spawn(config.python, [path.join(base, 'launch.py'), '--image-dir', image,
    '--runner', runner, '--guest-runtime-dir', guest, '--run-root', ownedRun.directory,
    ...(selected ? ['--project-directory', selected.directory, '--timeout', '540'] : [])], {
    stdio: ['pipe', 'pipe', 'pipe'], env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      LANG: 'en_US.UTF-8', PYTHONDONTWRITEBYTECODE: '1' }, detached: true,
  });
  if (child.pid) ownedRun.registerNativePID(child.pid);
  child.vmOwnedRun = ownedRun;
  return child;
}

// Test seams require explicit local-only injection; the executable has no such option.
export async function runVMTextChat(input, emit, dependencies, runtimeRoot = ROOT) {
  if (dependencies !== undefined && (dependencies.testOnly !== true ||
      typeof dependencies.launch !== 'function' || typeof dependencies.transport !== 'function' ||
      (dependencies.emitTrace !== undefined && typeof dependencies.emitTrace !== 'boolean'))) fail('INVALID_TEST_DEPENDENCIES');
  let configuration, child, ready = false, isolated = false, initialized = false, stopped = false;
  let model, sessionID, result, requests = 0, fullText = '', failure, inFlight;
  const toolActivities = new Map();
  let childCode, childSignal, childClosed = false, inputClosed = false, stopDrainTimer;
  let protocol = { providerBody, subscriptionHeaders }, selectedRuntimeRoot = ROOT;
  const abort = new AbortController();
  const controller = dependencies?.signal;
  const send = (type, extra = {}) => emit({ schema: EVENT_SCHEMA,
    request_id: configuration?.request_id ?? (UUID.test(input?.request_id ?? '') ? input.request_id : EMPTY_UUID),
    model: configuration?.model ?? 'deepseek-flash[1m]', fixture_only: false, type, ...extra });
  const write = value => {
    if (!child || childClosed || inputClosed || child.stdin.destroyed) fail('VM_CHANNEL_CLOSED');
    const frame = JSON.stringify(value) + '\n';
    if (Buffer.byteLength(frame) > FRAME_LIMIT) fail('VM_FRAME_LIMIT');
    // Bounded responses (<=2MiB total) also bound pipe buffering.
    child.stdin.write(frame);
  };
  const stop = code => {
    failure ??= code;
    abort.abort();
    // Allow the launcher to stop the VM and print its cleanup receipt before
    // closing stdout. A stuck guest/pipe must still enter process cleanup.
    if (child && !stopDrainTimer) {
      stopDrainTimer = setTimeout(() => child.stdout.destroy(new VMFailure('VM_CLEANUP_FAILED')),
        dependencies?.stopDrainTimeoutMs ?? STOP_DRAIN_TIMEOUT_MS);
    }
    if (child && !childClosed && !inputClosed) {
      try { write({ kind: 'cancel' }); }
      catch (error) { failure ??= error.code ?? 'VM_CHANNEL_CLOSED'; }
      inputClosed = true; child.stdin.end();
    }
  };
  const interrupt = () => stop('PROCESS_INTERRUPTED');
  let timer;
  if (!dependencies) { process.once('SIGTERM', interrupt); process.once('SIGINT', interrupt); }
  controller?.addEventListener('abort', interrupt, { once: true });
  let closed;
  const request = async frame => {
    if (!initialized || result || !only(frame, ['kind', 'id', 'headers', 'body']) ||
        !UUID.test(frame.id ?? '') || ++requests > (configuration.project ? 24 : 3) ||
        (configuration.project && [...toolActivities.values()].some(value => !['completed', 'failed'].includes(value.phase)))) fail('VM_REQUEST_REJECTED');
    const headers = configuration.provider === 'claude-subscription' ? protocol.subscriptionHeaders(frame.headers ?? {}) : {};
    if (configuration.provider === 'claude-subscription' && headers['x-claude-code-session-id'] !== sessionID) fail('SUBSCRIPTION_PROTOCOL_REJECTED');
    if (configuration.identity) verifyRequestedIdentity(frame.body, frame.headers, configuration.identity);
    const body = protocol.providerBody(frame.body, configuration, model, sessionID);
    if (configuration.identity) verifyRequestedIdentity(body, headers, configuration.identity);
    const { upstream, trace } = await tracedProviderRequest({ body,
      provider: configuration.provider, apiKey: configuration.apiKey, subscriptionToken: configuration.subscriptionToken,
      headers, signal: abort.signal, network: configuration.network }, { requestID: configuration.request_id, attempt: requests,
      project: Boolean(configuration.project),
      transport: dependencies?.transport ?? officialTransport,
      emit: value => { if (dependencies?.emitTrace !== false) send('request_trace', { trace: value }); } });
    try {
      if (!Number.isInteger(upstream.statusCode) || upstream.statusCode < 100 || upstream.statusCode > 599) fail('PROVIDER_INVALID_HTTP_STATUS');
      if (upstream.statusCode !== 200) {
        trace.response();
        upstream.stream?.destroy?.();
        if (upstream.statusCode >= 300 && upstream.statusCode < 400) fail('PROVIDER_REDIRECT_REJECTED');
        fail(`${configuration.provider === 'claude-subscription' ? 'SUBSCRIPTION' : 'PROVIDER'}_HTTP_${upstream.statusCode}`);
      }
      if (!String(upstream.contentType).includes('text/event-stream')) fail('PROVIDER_PROTOCOL_REJECTED');
      write({ kind: 'provider_response', id: frame.id, status: 200, content_type: 'text/event-stream' });
      await relaySse(upstream, { write(text) {
        const bytes = Buffer.from(text);
        for (let offset = 0; offset < bytes.length; offset += 65_536) {
          write({ kind: 'provider_chunk', id: frame.id, data: bytes.subarray(offset, offset + 65_536).toString('base64') });
        }
      } }, text => {
        if (Buffer.byteLength(fullText) + Buffer.byteLength(text) > 262_144) fail('PROVIDER_OUTPUT_LIMIT');
        fullText += text; send('delta', { text });
      }, abort.signal, configuration.project ? { project: true, onTool(tool) {
        if (toolActivities.has(tool.id) || toolActivities.size >= 64) fail('PROJECT_TOOL_PROTOCOL_REJECTED');
        toolActivities.set(tool.id, { tool: tool.name, phase: 'requested' });
      } } : undefined);
      trace.response();
      write({ kind: 'provider_end', id: frame.id });
    } catch (error) { trace.error(error, abort.signal); throw error; }
  };
  try {
    configuration = validateInput(input);
    timer = setTimeout(() => stop('VM_TIMEOUT'), dependencies?.timeoutMs ?? (configuration.project ? 560_000 : 240_000));
    if (controller?.aborted) fail('PROCESS_INTERRUPTED');
    if (typeof runtimeRoot !== 'string' || !path.isAbsolute(runtimeRoot)) fail('VM_RUNTIME_INVALID');
    try { selectedRuntimeRoot = await realpath(runtimeRoot); }
    catch { fail('VM_RUNTIME_INVALID'); }
    if (selectedRuntimeRoot !== runtimeRoot) fail('VM_RUNTIME_INVALID');
    // Swift verifies this installed package's signature and inventory before
    // passing the active root. Only its version-pinned body/header admission
    // helpers are reused; App-bundled transport and tracing remain authoritative.
    if (selectedRuntimeRoot !== ROOT) {
      let active;
      try { active = await import(pathToFileURL(path.join(selectedRuntimeRoot, 'sdk/deepseek-text-chat.mjs')).href); }
      catch { fail('VM_RUNTIME_INVALID'); }
      if (typeof active.providerBody !== 'function' || typeof active.subscriptionHeaders !== 'function') fail('VM_RUNTIME_INVALID');
      if (configuration.identity && active.TEXT_IDENTITY_CONTRACT !== TEXT_IDENTITY_CONTRACT) fail('VM_IDENTITY_UNSUPPORTED');
      if (configuration.project && active.PROJECT_EXECUTION_CONTRACT !== PROJECT_EXECUTION_CONTRACT) fail('VM_PROJECT_UNSUPPORTED');
      protocol = { providerBody: active.providerBody, subscriptionHeaders: active.subscriptionHeaders };
    }
    child = await (dependencies?.launch ?? productionLauncher)(selectedRuntimeRoot, configuration.project);
    closed = new Promise(resolve => {
      child.once('error', () => { failure ??= 'VM_START_FAILED'; resolve(); });
      child.once('close', (code, signal) => { childClosed = true; childCode = code; childSignal = signal; resolve(); });
    });
    child.stdin.on('error', () => { failure ??= 'VM_CHANNEL_CLOSED'; abort.abort(); });
    // Diagnostics never contain user text and are not forwarded to UI or providers.
    let diagnostics = 0;
    child.stderr?.on('data', data => { diagnostics += data.length; if (diagnostics > FRAME_LIMIT) stop('VM_DIAGNOSTIC_LIMIT'); });
    let pending = Buffer.alloc(0), frames = 0;
    for await (const chunk of child.stdout) {
      pending = Buffer.concat([pending, chunk]);
      for (;;) {
        const index = pending.indexOf(10);
        if (index < 0) break;
        if (index > FRAME_LIMIT || ++frames > 16384) fail('VM_FRAME_LIMIT');
        let frame;
        try { frame = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(pending.subarray(0, index))); }
        catch { fail('VM_PROTOCOL_REJECTED'); }
        pending = pending.subarray(index + 1);
        if (failure && frame?.kind !== 'vm_stopped') continue;
        switch (frame?.kind) {
          case 'vm_config':
            if (isolated || ready || frame.network_devices !== 0 || frame.directory_shares !== (configuration.project ? 1 : 0) ||
                frame.socket_devices !== 1 || (configuration.project ?
                  !only(frame, ['kind', 'network_devices', 'host_directory_shares', 'directory_shares',
                    'clipboard_devices', 'graphics_devices', 'socket_devices', 'cpu_count', 'memory_bytes',
                    'disposable_disk', 'vsock_port', 'project_mount', 'project_read_only']) ||
                  frame.host_directory_shares !== 1 || frame.clipboard_devices !== 0 || frame.graphics_devices !== 0 ||
                  !Number.isSafeInteger(frame.cpu_count) || frame.cpu_count < 1 || frame.cpu_count > 2 ||
                  frame.memory_bytes !== 2 * 1024 * 1024 * 1024 || frame.disposable_disk !== true || frame.vsock_port !== 40124 ||
                  frame.project_mount !== PROJECT_MOUNT || frame.project_read_only !== false :
                  frame.project_mount !== undefined || frame.project_read_only !== undefined)) fail('VM_ISOLATION_REJECTED');
            isolated = true; break;
          case 'ready':
            if (!isolated || ready || !only(frame, ['kind'])) fail('VM_PROTOCOL_REJECTED');
            ready = true;
            write({ kind: 'start', provider: configuration.provider, model: configuration.model,
              prompt: configuration.messages.at(-1).text, runtime: configuration.runtimeProfile,
              ...(configuration.project ? { project: { contract: PROJECT_EXECUTION_CONTRACT } } : {}),
              ...(configuration.identity ? { identity: configuration.identity } : {}) });
            break;
          case 'native_init':
            if (!ready || initialized || !only(frame, ['kind', 'model', 'session_id', 'no_tools', ...(configuration.project ? ['tools', 'project_mount'] : [])]) ||
                frame.no_tools !== !configuration.project || (configuration.project &&
                  (frame.project_mount !== PROJECT_MOUNT || !Array.isArray(frame.tools) || frame.tools.length !== PROJECT_TOOLS.length ||
                   new Set(frame.tools).size !== PROJECT_TOOLS.length || frame.tools.some(tool => !PROJECT_TOOLS.includes(tool)))) ||
                !UUID.test(frame.session_id ?? '') || typeof frame.model !== 'string' ||
                (configuration.provider === 'deepseek-api' ? ![configuration.model, configuration.model.replace('[1m]', '')].includes(frame.model) :
                  !new RegExp(`^claude-${configuration.model}-[0-9][a-z0-9-]{0,80}$`).test(frame.model))) fail('NO_TOOLS_CONTRACT');
            if (configuration.identity && frame.session_id !== configuration.identity.session_id) fail('NATIVE_IDENTITY_MISMATCH');
            initialized = true; model = frame.model; sessionID = frame.session_id;
            send('started', { no_tools: !configuration.project }); break;
          case 'tool_activity': {
            const activity = toolActivities.get(frame.tool_id);
            if (!configuration.project || !initialized || result || !only(frame, ['kind', 'tool_id', 'tool', 'phase']) ||
                !activity || frame.tool !== activity.tool ||
                (frame.phase === 'started' ? activity.phase !== 'requested' :
                  !['completed', 'failed'].includes(frame.phase) || activity.phase !== 'started')) fail('PROJECT_TOOL_PROTOCOL_REJECTED');
            activity.phase = frame.phase;
            send('tool_activity', { tool_id: frame.tool_id, tool: frame.tool, phase: frame.phase });
            break;
          }
          case 'provider_request':
            if (inFlight) fail('VM_REQUEST_REJECTED');
            inFlight = request(frame).catch(error => stop(error.code ?? 'PROVIDER_CONNECTION_FAILED')).finally(() => { inFlight = undefined; });
            break;
          case 'result':
            if (inFlight) await inFlight;
            if (!only(frame, ['kind', 'text', 'ok', 'error_code']) || result) fail('VM_PROTOCOL_REJECTED');
            if (!frame.ok) {
              if (typeof frame.error_code !== 'string' || !/^[A-Z_]{1,80}$/.test(frame.error_code)) fail('VM_GUEST_FAILED');
              stop(frame.error_code);
              break;
            }
            if (!initialized || requests < 1 || !fullText.trim() || frame.text !== fullText ||
                (configuration.project && [...toolActivities.values()].some(value => !['completed', 'failed'].includes(value.phase)))) fail('CLI_TEXT_MISMATCH');
            result = frame;
            inputClosed = true; child.stdin.end();
            break;
          case 'vm_stopped':
            if (stopped || frame.cleanup_complete !== true) fail('VM_CLEANUP_FAILED');
            stopped = true; break;
          default: fail('VM_PROTOCOL_REJECTED');
        }
      }
      if (pending.length > FRAME_LIMIT) fail('VM_FRAME_LIMIT');
    }
    if (pending.length) fail('VM_PROTOCOL_REJECTED');
    await waitUntilOrTimeout(closed, 6000);
    if (!childClosed) fail(failure ?? 'VM_CLEANUP_FAILED');
    if (!result || !stopped || childCode !== 0 || childSignal) fail(failure ?? 'VM_CLEANUP_FAILED');
  } catch (error) {
    stop(typeof error?.code === 'string' && /^[A-Z_0-9]{1,80}$/.test(error.code) ? error.code : 'VM_FAILED');
  } finally {
    abort.abort();
    if (inFlight) await inFlight;
    if (child && !childClosed) {
      if (!inputClosed) { inputClosed = true; child.stdin.end(); }
      await waitUntilOrTimeout(closed, 6000);
      if (!childClosed) {
        child.kill('SIGTERM');
        await waitUntilOrTimeout(closed, 1000);
        if (!childClosed) {
          try { if (child.pid) process.kill(-child.pid, 'SIGKILL'); else child.kill('SIGKILL'); }
          catch (error) { if (error.code !== 'ESRCH') failure = 'VM_CLEANUP_FAILED'; }
          await waitUntilOrTimeout(closed, 500);
          failure = 'VM_CLEANUP_FAILED';
        }
      }
    }
    if (child?.vmOwnedRun) {
      try {
        if (child.pid && (!childClosed || !(await waitForNativeProcessExit(child.pid)))) fail('VM_CLEANUP_FAILED');
        await rm(child.vmOwnedRun.directory, { recursive: true });
      } catch { failure = 'VM_CLEANUP_FAILED'; }
    }
    clearTimeout(timer);
    clearTimeout(stopDrainTimer);
    controller?.removeEventListener('abort', interrupt);
    if (!dependencies) { process.removeListener('SIGTERM', interrupt); process.removeListener('SIGINT', interrupt); }
  }
  const terminal = !failure && result && stopped && childClosed ? {
    type: 'completed', text: fullText, no_tools: !configuration.project, cli_exit: 0, cli_signal: null,
    temporary_removed: true, proxy_closed: true, request_count: requests,
  } : { type: 'error', code: failure ?? 'VM_CLEANUP_FAILED' };
  const { type, ...fields } = terminal; send(type, fields);
  return { schema: EVENT_SCHEMA, request_id: configuration?.request_id, model: configuration?.model,
    fixture_only: false, ...terminal };
}

export async function readVMInput() {
  let size = 0; const chunks = [];
  const timer = setTimeout(() => process.stdin.destroy(new VMFailure('INPUT_TIMEOUT')), 10_000);
  try {
    for await (const chunk of process.stdin) { size += chunk.length; if (size > FRAME_LIMIT) fail('INPUT_LIMIT'); chunks.push(chunk); }
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { fail('INVALID_INPUT_JSON'); }
  } finally { clearTimeout(timer); }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let input;
  const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
  try {
    const runtimeRoot = process.argv.length === 2 ? ROOT :
      process.argv.length === 4 && process.argv[2] === '--runtime-root' && path.isAbsolute(process.argv[3]) ? process.argv[3] : null;
    if (runtimeRoot === null) fail('INVALID_ARGUMENTS');
    input = await readVMInput(); await runVMTextChat(input, emit, undefined, runtimeRoot);
  } catch (error) {
    emit({ schema: EVENT_SCHEMA, request_id: UUID.test(input?.request_id ?? '') ? input.request_id : EMPTY_UUID,
      model: input?.model ?? 'deepseek-flash[1m]', fixture_only: false, type: 'error', code: error.code ?? 'VM_FAILED' });
  }
}
