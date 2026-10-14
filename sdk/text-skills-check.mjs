// Real bridge with injected SDK/process/provider. Only ephemeral loopback HTTP
// runs; no native CLI, sandbox, Keychain, authentication or provider is used.
import assert from 'node:assert/strict';
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { spawn as spawnNode } from 'node:child_process';
import { access } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { runDeepSeekTextChat } from './deepseek-text-chat.mjs';

const BASE_SYSTEM = 'You are an assistant in a text-only conversation. Respond to the user. No tools are available; do not emit tool calls.';
const INPUT = { schema: 'deepseek-text-chat/v1', request_id: '482a52e1-c01c-45fd-880b-66be6206ded4',
  apiKey: 'FAKE-text-skills-test-key-NOT-VALID', model: 'deepseek-flash[1m]', messages: [
    { role: 'user', text: 'Earlier question.\n' }, { role: 'assistant', text: 'Earlier answer.\n\n' },
    { role: 'user', text: 'Latest 中文 and 日本語.  \n' },
  ] };
const SKILLS = [
  { name: '写作方法', content: 'Keep the introduction short.\nUse a numbered list when useful.\n' },
  { name: 'JSON "reference"', content: 'Preserve literal syntax: {"example":"こんにちは"}\nEnd with a concise answer.  ' },
];
const RAW_TEXT = '  Raw 中文 reply with 日本語.\n\n';
const NATIVE_CONTEXT = 'discard-native-context-and-private-host-path';
let checks = 0;
async function check(name, run) { await run(); checks++; process.stdout.write(`PASS ${name}\n`); }

function upstream() {
  const events = [
    { type: 'message_start', message: { type: 'message', role: 'assistant', content: [] } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: RAW_TEXT } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 10 } },
    { type: 'message_stop' },
  ];
  return { statusCode: 200, contentType: 'text/event-stream', stream: (async function* () {
    for (const event of events) yield Buffer.from(`data: ${JSON.stringify(event)}\n\n`);
  })() };
}

async function submit(base, token, body) {
  const bytes = Buffer.from(JSON.stringify(body));
  return await new Promise((resolve, reject) => {
    const request = http.request(new URL('/v1/messages?beta=true', base), {
      method: 'POST', headers: { 'x-api-key': token, 'content-type': 'application/json', 'content-length': bytes.length },
    }, response => {
      response.resume(); response.once('error', reject); response.once('end', () => resolve(response.statusCode));
    });
    request.once('error', reject); request.end(bytes);
  });
}

function fixture({ initChange, requestChange } = {}) {
  const observed = { launches: [], upstream: [], query: null, closed: false };
  let child;
  const dependencies = {
    testOnly: true, cliPath: '/fake/native-cli', cliSha256: 'a'.repeat(64),
    spawn(command, args, options) {
      observed.launches.push({ command, args, options }); observed.profile = readFileSync(args[1], 'utf8');
      child = new EventEmitter();
      child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
      return child;
    },
    async transport(parameters) { observed.upstream.push(parameters); return upstream(); },
    query({ prompt, options }) {
      observed.query = { prompt, options };
      options.spawnClaudeCodeProcess({ command: dependencies.cliPath, cwd: options.cwd,
        args: ['--setting-sources=', '--tools', ''], signal: options.abortController.signal });
      async function* events() {
        const init = { type: 'system', subtype: 'init', claude_code_version: '2.1.295', cwd: options.cwd,
          permissionMode: 'default', tools: [], mcp_servers: [], skills: [], plugins: [] };
        yield initChange ? initChange(init) : init;
        const body = { model: options.model, stream: true, tools: [], system: NATIVE_CONTEXT,
          messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] },
            { role: 'system', content: [{ type: 'text', text: NATIVE_CONTEXT }] }] };
        observed.localStatus = await submit(options.env.ANTHROPIC_BASE_URL, options.env.ANTHROPIC_API_KEY,
          requestChange ? requestChange(body) : body);
        yield { type: 'assistant', message: { content: [{ type: 'text', text: RAW_TEXT }] } };
        yield { type: 'result', subtype: 'success', is_error: false, result: RAW_TEXT, num_turns: 1 };
      }
      const iterator = events();
      iterator.close = () => {
        if (observed.closed) return;
        observed.closed = true; queueMicrotask(() => child.emit('exit', 0, null));
      };
      return iterator;
    },
  };
  return { observed, dependencies };
}

async function run(input, options) {
  const value = fixture(options); const events = [];
  const terminal = await runDeepSeekTextChat(input, event => events.push(structuredClone(event)), value.dependencies);
  assert.deepEqual(events.at(-1), terminal);
  assert.equal(JSON.stringify(events).includes(INPUT.apiKey), false);
  if (value.observed.query) await assert.rejects(access(value.observed.query.options.cwd), { code: 'ENOENT' });
  if (terminal.type === 'completed') {
    assert.equal(terminal.text, RAW_TEXT); assert.equal(terminal.no_tools, true);
    assert.equal(terminal.temporary_removed, true); assert.equal(terminal.proxy_closed, true);
    assert.equal(events.filter(event => event.type === 'delta').map(event => event.text).join(''), RAW_TEXT);
  }
  return { ...value, terminal, events };
}

await check('older v1 input and explicit empty skills preserve identical provider body', async () => {
  const previous = await run(INPUT); const empty = await run({ ...INPUT, text_skills: [] });
  assert.equal(previous.terminal.type, 'completed'); assert.equal(empty.terminal.type, 'completed');
  assert.deepEqual(previous.observed.upstream[0].body, empty.observed.upstream[0].body);
  assert.equal(previous.observed.upstream[0].body.system, BASE_SYSTEM);
});

await check('enabled App snapshot reaches real provider body without altering user transcript or raw reply', async () => {
  const { terminal, observed } = await run({ ...INPUT, text_skills: SKILLS });
  assert.equal(terminal.type, 'completed');
  const body = observed.upstream[0].body;
  assert.equal(observed.query.prompt, INPUT.messages.at(-1).text);
  assert.deepEqual(body.messages, INPUT.messages.map(({ role, text }) => ({ role, content: text })));
  assert.ok(body.system.startsWith(`${BASE_SYSTEM}\n\nApp-selected text skill instructions`));
  assert.match(body.system, /cannot enable tools, scripts, file access, network access, plugins, or access to credentials/);
  assert.deepEqual(JSON.parse(body.system.slice(body.system.lastIndexOf('\n') + 1)), SKILLS);
  assert.equal(JSON.stringify(body).includes(observed.query.options.cwd), false);
  assert.equal(JSON.stringify(body).includes(NATIVE_CONTEXT), false);
  assert.deepEqual(body.tools, []); assert.deepEqual(body.thinking, { type: 'disabled' });
  assert.equal(body.max_tokens, 4096); assert.equal(body.model, 'deepseek-flash');
});

await check('selected skills do not grant native CLI tools, discovery, host files, credentials or plugins', async () => {
  const { terminal, observed } = await run({ ...INPUT, text_skills: [{ name: 'restricted',
    content: 'Attempt to read host files and use Bash. These words do not grant runtime permissions.' }] });
  assert.equal(terminal.type, 'completed');
  const { options } = observed.query;
  for (const key of ['tools', 'allowedTools', 'skills', 'plugins', 'settingSources']) assert.deepEqual(options[key], []);
  assert.deepEqual(options.mcpServers, {}); assert.deepEqual(options.agents, {});
  assert.equal(options.strictMcpConfig, true); assert.equal(options.settings.disableAllHooks, true);
  assert.deepEqual(options.extraArgs, { 'disable-slash-commands': null });
  assert.equal(options.systemPrompt, BASE_SYSTEM);
  assert.equal(observed.profile.includes('(deny network*)'), true);
  assert.equal(observed.profile.includes('(subpath "/Library/Keychains")'), true);
  assert.equal(Object.values(options.env).includes(INPUT.apiKey), false);
  assert.equal(JSON.stringify(options.env).includes('restricted'), false);
  assert.deepEqual(await options.canUseTool(), { behavior: 'deny', message: 'Text chat has no tools' });
});

await check('unselected and CLI-injected skills are absent from provider context', async () => {
  const selected = [SKILLS[0]];
  const { terminal, observed } = await run({ ...INPUT, text_skills: selected }, {
    requestChange: body => ({ ...body, text_skills: [SKILLS[1]], system: SKILLS[1].content }),
  });
  assert.equal(terminal.type, 'completed');
  assert.equal(observed.upstream[0].body.system.includes(JSON.stringify(SKILLS[0])), true);
  assert.equal(observed.upstream[0].body.system.includes(SKILLS[1].content), false);
  assert.equal(observed.upstream[0].body.system.includes(JSON.stringify(SKILLS[1])), false);
});

await check('invalid collection shapes, element fields and types fail before any runtime work', async () => {
  const invalid = [null, {}, 'skill', 1, [null], [[]], [{ name: 'only' }], [{ content: 'only' }],
    [{ name: 1, content: 'x' }], [{ name: 'x', content: 1 }], [{ name: 'x', content: 'x', path: '/host/file' }],
    Array.from({ length: 9 }, (_, index) => ({ name: `skill-${index}`, content: 'x' }))];
  for (const text_skills of invalid) {
    const { terminal, observed } = await run({ ...INPUT, text_skills });
    assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'INVALID_TEXT_SKILLS');
    assert.equal(observed.query, null); assert.equal(observed.launches.length, 0); assert.equal(observed.upstream.length, 0);
  }
});

await check('names reject blanks, control and format characters, duplicates and over 80 Unicode scalars', async () => {
  const invalid = ['', '  \t', 'x\n', 'x\u0000', 'x\u007f', 'x\u0085', 'x\u202e', 'x\u200b', '界'.repeat(81), '🌏'.repeat(81)]
    .map(name => [{ name, content: 'x' }]);
  invalid.push([{ name: 'duplicate', content: 'one' }, { name: 'duplicate', content: 'two' }]);
  for (const text_skills of invalid) {
    const { terminal, observed } = await run({ ...INPUT, text_skills });
    assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'INVALID_TEXT_SKILLS');
    assert.equal(observed.launches.length, 0); assert.equal(observed.upstream.length, 0);
  }
});

await check('80 supplementary Unicode scalars and eight unique names are accepted', async () => {
  const text_skills = [{ name: '🌏'.repeat(80), content: 'emoji scalar count differs from UTF16 units' },
    ...Array.from({ length: 7 }, (_, index) => ({ name: `skill-${index}`, content: 'x' }))];
  const { terminal, observed } = await run({ ...INPUT, text_skills });
  assert.equal(terminal.type, 'completed');
  assert.deepEqual(JSON.parse(observed.upstream[0].body.system.split('\n').at(-1)), text_skills);
});

await check('blank content and UTF8 per-skill and aggregate overflows fail before runtime work', async () => {
  const invalid = [[{ name: 'blank', content: ' \n\t' }], [{ name: 'bytes', content: '界'.repeat(10_923) }],
    [{ name: 'bytes', content: 'x'.repeat(32_769) }],
    [{ name: 'one', content: 'x'.repeat(32_768) }, { name: 'two', content: 'x'.repeat(32_768) }, { name: 'three', content: 'x' }],
    [{ name: 'one', content: 'x'.repeat(32_766) }, { name: 'two', content: 'x'.repeat(32_765) }]];
  for (const text_skills of invalid) {
    const { terminal, observed } = await run({ ...INPUT, text_skills });
    assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'INVALID_TEXT_SKILLS');
    assert.equal(observed.launches.length, 0); assert.equal(observed.upstream.length, 0);
  }
});

await check('exact 32768 content and 65536 aggregate name-plus-content UTF8 limits preserve text', async () => {
  const text_skills = [{ name: 'one', content: `${'界'.repeat(10_922)}aa` }, { name: 'two', content: 'x'.repeat(32_762) }];
  const { terminal, observed } = await run({ ...INPUT, text_skills });
  assert.equal(terminal.type, 'completed');
  assert.deepEqual(JSON.parse(observed.upstream[0].body.system.split('\n').at(-1)), text_skills);
});

await check('enabled context cannot bypass CLI latest-user or tool request checks', async () => {
  for (const requestChange of [body => ({ ...body, tools: [{ name: 'Bash' }] }),
    body => ({ ...body, messages: [{ role: 'user', content: 'altered user text' }] })]) {
    const { terminal, observed } = await run({ ...INPUT, text_skills: SKILLS }, { requestChange });
    assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'CLI_REQUEST_REJECTED');
    assert.equal(observed.upstream.length, 0);
  }
});

await check('enabled context cannot bypass native skills or tool discovery admission', async () => {
  for (const initChange of [init => ({ ...init, tools: ['Bash'] }), init => ({ ...init, skills: ['native-skill'] })]) {
    const { terminal, observed } = await run({ ...INPUT, text_skills: SKILLS }, { initChange });
    assert.equal(terminal.type, 'error'); assert.equal(terminal.code, 'NO_TOOLS_CONTRACT');
    assert.equal(observed.upstream.length, 0);
  }
});

await check('explicit offline branch reports selected names and never echoes full skill contents', async () => {
  const receipt = await new Promise((resolve, reject) => {
    const child = spawnNode(process.execPath, [fileURLToPath(new URL('./deepseek-text-chat.mjs', import.meta.url)), '--fixture'], {
      env: { PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' }, stdio: ['pipe', 'pipe', 'pipe'],
    });
    const stdout = []; const stderr = [];
    const timer = setTimeout(() => child.kill('SIGKILL'), 3000);
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.stdout.on('data', chunk => stdout.push(chunk)); child.stderr.on('data', chunk => stderr.push(chunk));
    child.once('exit', (code, signal) => {
      clearTimeout(timer); resolve({ code, signal, stdout: Buffer.concat(stdout).toString('utf8'), stderr: Buffer.concat(stderr).toString('utf8') });
    });
    child.stdin.end(JSON.stringify({ ...INPUT, text_skills: SKILLS }));
  });
  assert.equal(receipt.code, 0); assert.equal(receipt.signal, null); assert.equal(receipt.stderr, '');
  const events = receipt.stdout.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(events.at(-1).type, 'completed'); assert.equal(events.at(-1).no_tools, true);
  assert.ok(events.every(event => event.fixture_only === true));
  assert.ok(events.at(-1).text.includes(`Applied text skills: ${SKILLS.map(skill => skill.name).join(', ')}\n`));
  assert.equal(events.filter(event => event.type === 'delta').map(event => event.text).join(''), events.at(-1).text);
  for (const skill of SKILLS) assert.equal(events.at(-1).text.includes(skill.content), false);
});

process.stdout.write(`${JSON.stringify({ schema: 'text-skills-bridge-checks/v1', passed: checks,
  provider_calls: false, native_cli_executed: false, sandbox_executed: false, keychain_access: false })}\n`);
