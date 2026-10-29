import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { relaySse } from './deepseek-text-chat.mjs';

test('offline fixture refuses projects explicitly before touching their directory', () => {
  const child = spawnSync(process.execPath, [new URL('./deepseek-text-chat.mjs', import.meta.url).pathname, '--fixture'], {
    input: JSON.stringify({ schema: 'deepseek-text-chat/v1', request_id: 'e279c431-2d15-46ca-8c58-cf9106eac6a4',
      apiKey: 'synthetic-not-a-real-credential', model: 'deepseek-flash[1m]',
      messages: [{ role: 'user', text: 'Synthetic test' }], project: { directory: '/synthetic/not-accessed' } }),
    encoding: 'utf8', env: { PATH: '/usr/bin:/bin' },
  });
  assert.equal(child.status, 0);
  const events = child.stdout.trim().split('\n').map(value => JSON.parse(value));
  assert.equal(events.length, 1); assert.equal(events[0].fixture_only, true);
  assert.equal(events[0].type, 'error'); assert.equal(events[0].code, 'VM_PROJECT_REQUIRED');
});

function frames() {
  return [
    { type: 'message_start', message: { type: 'message', role: 'assistant', content: [] } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: 'Checking. ' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Working. ' } },
    { type: 'content_block_stop', index: 0 },
    { type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 'tool_fixture_1', name: 'Bash', input: {} } },
    { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"command":"printf' } },
    { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: ' SYNTHETIC"}' } },
    { type: 'content_block_stop', index: 1 },
    { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 30 } },
    { type: 'message_stop' },
  ];
}

async function run(values, project = true) {
  const text = [], tools = [], forwarded = [];
  const upstream = { stream: (async function* () {
    const bytes = Buffer.from(values.map(value => `data: ${JSON.stringify(value)}\n\n`).join(''));
    for (let offset = 0; offset < bytes.length; offset += 7) yield bytes.subarray(offset, offset + 7);
  })() };
  await relaySse(upstream, { write: value => forwarded.push(value) }, value => text.push(value),
    new AbortController().signal, project ? { project: true, onTool: value => tools.push(value) } : undefined);
  return { text: text.join(''), tools, forwarded };
}

test('project SSE retains text and forwards the complete tool input chain to the guest', async () => {
  const result = await run(frames());
  assert.equal(result.text, 'Checking. Working. ');
  assert.deepEqual(result.tools, [{ id: 'tool_fixture_1', name: 'Bash', input: { command: 'printf SYNTHETIC' } }]);
  assert.equal(result.forwarded.length, frames().length);
});

test('text SSE still rejects every tool block', async () => {
  await assert.rejects(run(frames(), false), { code: 'PROVIDER_TOOL_RESPONSE' });
});

for (const [name, mutate, code] of [
  ['unknown tool', values => { values[4].content_block.name = 'WebFetch'; }, 'PROVIDER_TOOL_RESPONSE'],
  ['invalid id', values => { values[4].content_block.id = 'tool/path'; }, 'PROVIDER_TOOL_RESPONSE'],
  ['alternate caller', values => { values[4].content_block.caller = { type: 'code_execution_20250825' }; }, 'PROVIDER_TOOL_RESPONSE'],
  ['prefilled input', values => { values[4].content_block.input = { command: 'hidden' }; }, 'PROVIDER_TOOL_RESPONSE'],
  ['array input', values => { values[5].delta.partial_json = '['; values[6].delta.partial_json = ']'; }, 'PROVIDER_TOOL_RESPONSE'],
  ['invalid json', values => { values[6].delta.partial_json = '!'; }, 'PROVIDER_TOOL_RESPONSE'],
  ['tool ended as text', values => { values[8].delta.stop_reason = 'end_turn'; }, 'PROVIDER_PROTOCOL_REJECTED'],
  ['unknown stop reason', values => { values[8].delta.stop_reason = 'pause_turn'; }, 'PROVIDER_PROTOCOL_REJECTED'],
  ['missing stop reason', values => { values.splice(8, 1); }, 'PROVIDER_PROTOCOL_REJECTED'],
  ['reused block index', values => { values[4].index = 0; }, 'PROVIDER_PROTOCOL_REJECTED'],
]) test(`project SSE rejects ${name}`, async () => {
  const values = frames(); mutate(values);
  await assert.rejects(run(values), { code });
});
