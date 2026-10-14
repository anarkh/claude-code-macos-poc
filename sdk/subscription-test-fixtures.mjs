// Test helpers contain only inert credentials. They never contact a provider.
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { readFileSync } from 'node:fs';

export const FAKE_SUBSCRIPTION_TOKEN = 'sk-ant-oat01-FAKE-local-subscription-fixture-NOT-VALID';
export const SUBSCRIPTION_SESSION_ID = 'b6eaa231-7a86-4789-a67d-84c3f1a7968e';
export const SUBSCRIPTION_ACK = 'CLAUDE_SUBSCRIPTION_CLI_OK';
export const SUBSCRIPTION_INPUT = Object.freeze({ schema: 'deepseek-text-chat/v1',
  request_id: '43e06d6f-eaf4-4f2a-8fb4-d5401b47aee1', provider: 'claude-subscription',
  subscriptionToken: FAKE_SUBSCRIPTION_TOKEN, model: 'sonnet',
  messages: [{ role: 'user', text: 'Earlier question.' }, { role: 'assistant', text: 'Earlier answer.' },
    { role: 'user', text: `Reply with exactly ${SUBSCRIPTION_ACK} and nothing else.` }],
  text_skills: [{ name: 'Text fixture', content: 'Answer the latest user question.' }],
  network: { schema: 'app-network-policy/v1', proxyURL: 'http://127.0.0.1:7897', dnsPolicy: 'proxy-only' },
  runtime: { schema: 'app-runtime-profile/v1', timeZone: 'Asia/Tokyo', language: 'ja' } });

export function subscriptionSSE(text = SUBSCRIPTION_ACK, model = 'claude-sonnet-5-5') {
  const frames = [
    ['message_start', { type: 'message_start', message: { id: 'msg_local_fixture', type: 'message', role: 'assistant',
      model, content: [], usage: { input_tokens: 20, output_tokens: 0 } } }],
    ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
    ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } }],
    ['content_block_stop', { type: 'content_block_stop', index: 0 }],
    ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 10 } }],
    ['message_stop', { type: 'message_stop' }],
  ];
  const bytes = Buffer.from(frames.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join(''));
  return { statusCode: 200, contentType: 'text/event-stream', stream: (async function* () {
    for (let index = 0; index < bytes.length; index += 11) yield bytes.subarray(index, index + 11);
  })() };
}

export function nativeSubscriptionHeaders(token = FAKE_SUBSCRIPTION_TOKEN) {
  return { authorization: `Bearer ${token}`, 'anthropic-version': '2023-06-01', 'x-app': 'cli',
    'user-agent': 'claude-cli/2.1.295 (external, sdk-ts, agent-sdk/0.3.295)',
    'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20,mid-conversation-system-2026-04-07',
    'anthropic-dangerous-direct-browser-access': 'true', 'x-claude-code-session-id': SUBSCRIPTION_SESSION_ID,
    'x-stainless-os': 'Must not reach provider', 'x-untrusted-header': 'Must not reach provider' };
}

export function nativeSubscriptionBody(prompt, model = 'claude-sonnet-5-5') {
  return { model, stream: true, max_tokens: 128000, tools: [],
    system: [{ type: 'text', text: 'x-anthropic-billing-header: cc_version=2.1.295.c4e; cc_entrypoint=sdk-ts;' },
      { type: 'text', text: "You are a Claude agent, built on Anthropic's Claude Agent SDK." },
      { type: 'text', text: 'You are an assistant in a text-only conversation. Respond to the user. No tools are available; do not emit tool calls.' }],
    metadata: { user_id: JSON.stringify({ device_id: 'b'.repeat(64), account_uuid: '', session_id: SUBSCRIPTION_SESSION_ID }) },
    messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] },
      { role: 'system', content: [{ type: 'text', text: '# Environment\n/private/temporary-native-workspace' }],
        output_config: { effort: 'medium' } }] };
}

export function subscriptionFixture({ requestChange, initChange, requests = 1, status = 200,
  transportError, timeoutMs, blockedUntilAbort = false, providerChange } = {}) {
  const observed = { launches: [], upstream: [], local: [], query: null, closed: 0 };
  let child, closed = false;
  const dependencies = { testOnly: true, cliPath: '/fake/official-native-cli', cliSha256: 'd'.repeat(64),
    ...(timeoutMs === undefined ? {} : { timeoutMs }),
    spawn(command, args, options) {
      observed.launches.push({ command, args, options });
      observed.profile = readFileSync(args[1], 'utf8');
      child = new EventEmitter(); child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
      return child;
    },
    async transport(parameters) {
      observed.upstream.push(parameters);
      if (transportError) throw new Error(`Private transport error ${FAKE_SUBSCRIPTION_TOKEN}`);
      return providerChange ? providerChange(parameters) : { ...subscriptionSSE(), statusCode: status };
    },
    query({ prompt, options }) {
      observed.query = { prompt, options }; observed.cwd = options.cwd;
      options.spawnClaudeCodeProcess({ command: dependencies.cliPath, cwd: options.cwd,
        args: ['--setting-sources=', '--tools', ''], signal: options.abortController.signal });
      async function* events() {
        const resolved = `claude-${options.model}-5-5`;
        const init = { type: 'system', subtype: 'init', claude_code_version: '2.1.295', cwd: options.cwd,
          permissionMode: 'default', tools: [], mcp_servers: [], skills: [], plugins: [], apiKeySource: 'none',
          model: resolved, session_id: SUBSCRIPTION_SESSION_ID };
        yield initChange ? initChange(init) : init;
        if (blockedUntilAbort) {
          await new Promise(resolve => options.abortController.signal.addEventListener('abort', resolve, { once: true }));
          throw new Error(`Private cancelled diagnostic ${FAKE_SUBSCRIPTION_TOKEN}`);
        }
        for (let index = 0; index < requests; index++) {
          const request = { headers: nativeSubscriptionHeaders(options.env.CLAUDE_CODE_OAUTH_TOKEN),
            body: nativeSubscriptionBody(prompt, resolved), route: '/v1/messages?beta=true' };
          const changed = requestChange ? requestChange(request, index) : request;
          const bytes = Buffer.from(JSON.stringify(changed.body));
          observed.local.push(await new Promise((resolve, reject) => {
            const req = http.request(new URL(changed.route, options.env.ANTHROPIC_BASE_URL), { method: 'POST',
              headers: { ...changed.headers, 'content-type': 'application/json', 'content-length': bytes.length } }, response => {
              const chunks = []; response.on('data', chunk => chunks.push(chunk)); response.once('error', reject);
              response.once('end', () => resolve({ status: response.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
            }); req.once('error', reject); req.end(bytes);
          }));
        }
        const text = SUBSCRIPTION_ACK.repeat(requests);
        yield { type: 'assistant', message: { content: [{ type: 'text', text }] } };
        yield { type: 'result', subtype: 'success', is_error: false, result: text, num_turns: 1 };
      }
      const iterator = events();
      iterator.close = () => { observed.closed++; if (closed) return; closed = true; queueMicrotask(() => child.emit('exit', 0, null)); };
      return iterator;
    } };
  return { observed, dependencies };
}
