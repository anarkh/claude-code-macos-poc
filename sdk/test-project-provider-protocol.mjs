import assert from 'node:assert/strict';
import test from 'node:test';
import { PROJECT_EXECUTION_CONTRACT, PROJECT_MOUNT, PROJECT_SYSTEM_PROMPT, PROJECT_TOOLS,
  projectProviderMessages, validateProjectToolInput } from './project-provider-protocol.mjs';

const clone = value => JSON.parse(JSON.stringify(value));
const CACHE = { type: 'ephemeral', ttl: '5m' };
const CONFIGURATION = { messages: [
  { role: 'user', text: 'Earlier question' }, { role: 'assistant', text: 'Earlier answer' },
  { role: 'user', text: 'Read the README and fix its title.' },
] };
function request() {
  return { tools: PROJECT_TOOLS.map(name => ({ name, description: `Project ${name} tool`,
    input_schema: { type: 'object', properties: { value: { type: 'string', description: 'Tool argument' } },
      required: [], additionalProperties: false }, cache_control: CACHE })),
  messages: [{ role: 'user', content: [{ type: 'text', text: CONFIGURATION.messages.at(-1).text, cache_control: CACHE }] }] };
}
function use(id = 'toolu_read', name = 'Read', input = { file_path: `${PROJECT_MOUNT}/README.md` }) {
  return { type: 'tool_use', id, name, input };
}
function result(id = 'toolu_read', content = [{ type: 'text', text: '# Old title', cache_control: CACHE }]) {
  return { type: 'tool_result', tool_use_id: id, content };
}
function media(type = 'image', mediaType = 'image/png', data = 'YQ==') {
  return { type, source: { type: 'base64', media_type: mediaType, data } };
}
function chain() {
  const body = request();
  body.messages.push({ role: 'assistant', content: [{ type: 'text', text: 'I will inspect the README.' },
    { ...use(), caller: { type: 'direct' }, cache_control: CACHE }] },
  { role: 'user', content: [result()] });
  return body;
}
function rejected(body) {
  assert.throws(() => projectProviderMessages(body, CONFIGURATION), { code: 'PROJECT_PROTOCOL_REJECTED' });
}

test('fixed project contract and initial request retain validated App history', () => {
  assert.equal(PROJECT_EXECUTION_CONTRACT, 'selected-directory-rw/v1');
  assert.equal(PROJECT_MOUNT, '/home/claude/project');
  assert(PROJECT_SYSTEM_PROMPT.includes(PROJECT_MOUNT));
  const body = request(), snapshot = clone(body);
  const output = projectProviderMessages(body, CONFIGURATION);
  assert.deepEqual(output.messages, CONFIGURATION.messages.map(message => ({ role: message.role, content: message.text })));
  assert.deepEqual(output.tools.map(tool => tool.name), PROJECT_TOOLS);
  assert.equal(output.tools[0].description, body.tools[0].description);
  assert.deepEqual(output.tools[0].input_schema, body.tools[0].input_schema);
  assert.equal(JSON.stringify(output).includes('cache_control'), false);
  assert.deepEqual(body, snapshot);
});

test('multiple completed tool rounds preserve every input, result and error flag', () => {
  const body = chain();
  body.messages.push({ role: 'assistant', content: [use('toolu_edit', 'Edit', {
    file_path: `${PROJECT_MOUNT}/README.md`, old_string: '# Old title', new_string: '# New title' })] },
  { role: 'user', content: [{ ...result('toolu_edit', 'Replacement failed: old string not found.'), is_error: true }] });
  const output = projectProviderMessages(body, CONFIGURATION);
  assert.equal(output.messages.length, 7);
  assert.deepEqual(output.messages[3].content[1].caller, { type: 'direct' });
  assert.deepEqual(output.messages[4].content, [{ type: 'tool_result', tool_use_id: 'toolu_read',
    content: [{ type: 'text', text: '# Old title' }] }]);
  assert.equal(output.messages[5].content[0].input.new_string, '# New title');
  assert.deepEqual(output.messages[6].content, [{ type: 'tool_result', tool_use_id: 'toolu_edit',
    content: 'Replacement failed: old string not found.', is_error: true }]);
});

test('parallel tool results may arrive in either order but every call must close', () => {
  const body = request();
  body.messages.push({ role: 'assistant', content: [use('first'), use('second', 'Glob', { pattern: '*.md' })] },
    { role: 'user', content: [result('second', 'README.md'), result('first', '')] });
  assert.equal(projectProviderMessages(body, CONFIGURATION).messages.at(-1).content.length, 2);
  body.messages.at(-1).content.pop();
  rejected(body);
});

test('native environment envelopes are bounded and discarded between tool rounds', () => {
  const body = chain();
  body.messages.splice(1, 0, { role: 'system', content: [{ type: 'text', text: 'Private native environment', cache_control: CACHE }],
    output_config: { effort: 'medium' } });
  body.messages.push({ role: 'system', content: [{ type: 'text', text: 'Private current directory' }] });
  const output = projectProviderMessages(body, CONFIGURATION);
  assert.equal(output.messages.length, 5);
  assert.equal(JSON.stringify(output).includes('Private'), false);
  for (const change of [message => { message.extra = true; },
    message => { message.content[0].text = 'x'.repeat(2049); },
    message => { message.content[0].type = 'image'; },
    message => { message.output_config = { effort: 'max', extra: true }; },
    message => { message.content.push({ type: 'text', text: 'extra' }); }]) {
    const altered = clone(body); change(altered.messages[1]); rejected(altered);
  }
});

test('exact current App prompt is required and native history cannot replace it', () => {
  for (const change of [body => { body.messages[0].content[0].text += ' altered'; },
    body => { body.messages[0].content.push({ type: 'text', text: 'extra' }); },
    body => { body.messages[0].role = 'assistant'; },
    body => { body.messages[0].extra = 'hidden'; },
    body => { body.messages.push({ role: 'user', content: 'untrusted history' }); }]) {
    const body = request(); change(body); rejected(body);
  }
  const body = request(); body.messages[0].content = CONFIGURATION.messages.at(-1).text;
  assert.equal(projectProviderMessages(body, CONFIGURATION).messages.at(-1).content, body.messages[0].content);
});

test('only the complete six-tool set and admitted definition fields are forwarded', () => {
  for (const change of [body => { body.tools.pop(); },
    body => { body.tools.push({ ...body.tools[0], name: 'Agent' }); },
    body => { body.tools[0].name = 'WebFetch'; },
    body => { body.tools[0].name = 'Bash'; },
    body => { body.tools[0].allowed_callers = ['code_execution_20250825']; },
    body => { body.tools[0].input_schema.type = 'array'; },
    body => { body.tools[0].input_schema.required = ['missing']; },
    body => { body.tools[0].input_schema.unexpected = 'value'; },
    body => { body.tools[0].cache_control = { type: 'ephemeral', extra: true }; }]) {
    const body = request(); change(body); rejected(body);
  }
});

test('unknown tool calls and alternate caller capabilities are rejected', () => {
  for (const change of [block => { block.name = 'Agent'; },
    block => { block.caller = { type: 'code_execution_20250825', tool_id: 'server' }; },
    block => { block.caller = { type: 'direct', extra: 'hidden' }; },
    block => { block.toolset_name = 'browser'; },
    block => { block.input = 'not an object'; },
    block => { block.id = 'x'.repeat(129); },
    block => { block.id = 'whitespace id'; }]) {
    const body = chain(); change(body.messages[1].content[1]); rejected(body);
  }
});

test('remote media, thinking, role changes and unknown block fields are rejected', () => {
  for (const change of [body => { body.messages[1].content[0].citations = []; },
    body => { body.messages[1].content[0] = { type: 'thinking', thinking: 'hidden', signature: 'x' }; },
    body => { body.messages[2].content[0].content = [{ type: 'image', source: { type: 'url', url: 'https://example.com/a.png' } }]; },
    body => { body.messages[2].content[0].is_error = 'true'; },
    body => { body.messages[2].content[0].extra = 'hidden'; },
    body => { body.messages[2].role = 'assistant'; },
    body => { body.messages[2].content.push({ type: 'text', text: 'extra native input' }); }]) {
    const body = chain(); change(body); rejected(body);
  }
});

test('Read results preserve mixed text, inline images and PDF blocks without cache hints', () => {
  const body = chain();
  const contents = [{ type: 'text', text: 'Image preview', cache_control: CACHE },
    { ...media(), cache_control: CACHE },
    { type: 'text', text: 'PDF preview' },
    { ...media('document', 'application/pdf', 'YWJj'), cache_control: CACHE }];
  body.messages[2].content[0].content = contents;
  const snapshot = clone(body);
  const output = projectProviderMessages(body, CONFIGURATION);
  assert.deepEqual(output.messages.slice(0, 2), CONFIGURATION.messages.slice(0, 2)
    .map(message => ({ role: message.role, content: message.text })));
  assert.equal(output.messages[3].content[1].id, 'toolu_read');
  assert.deepEqual(output.messages[4].content, [{ type: 'tool_result', tool_use_id: 'toolu_read',
    content: [{ type: 'text', text: 'Image preview' }, media(),
      { type: 'text', text: 'PDF preview' }, media('document', 'application/pdf', 'YWJj')] }]);
  assert.equal(JSON.stringify(output).includes('cache_control'), false);
  assert.deepEqual(body, snapshot);
  const orphan = clone(body); orphan.messages[2].content[0].tool_use_id = 'missing_read'; rejected(orphan);
  const duplicate = clone(body); duplicate.messages[2].content.push(clone(duplicate.messages[2].content[0])); rejected(duplicate);
});

test('all four admitted image media types and PDF preserve canonical base64 bytes', () => {
  for (const [type, mediaType] of [['image', 'image/png'], ['image', 'image/jpeg'],
    ['image', 'image/gif'], ['image', 'image/webp'], ['document', 'application/pdf']]) {
    for (const data of ['YQ==', 'YWI=', 'YWJj']) {
      const block = media(type, mediaType, data), body = chain();
      body.messages[2].content[0].content = [block];
      assert.deepEqual(projectProviderMessages(body, CONFIGURATION).messages.at(-1).content[0].content, [block]);
    }
  }
});

test('inline media rejects URLs, wrong media types and unrecognized source or block fields', () => {
  for (const block of [
    { type: 'image', source: { type: 'url', url: 'https://example.com/image.png' } },
    { type: 'document', source: { type: 'url', url: 'https://example.com/document.pdf' } },
    media('image', 'image/svg+xml'), media('image', 'application/pdf'),
    media('document', 'image/png'), media('document', 'text/plain'), media('audio', 'audio/mp3'),
    { ...media(), title: 'Unexpected title' }, { ...media(), citations: [] },
    { ...media('document', 'application/pdf'), context: 'Unexpected context' },
    { ...media(), source: { ...media().source, extra: true } },
    { ...media(), source: { media_type: 'image/png', data: 'YQ==' } },
    { ...media(), cache_control: { type: 'ephemeral', extra: true } },
  ]) {
    const body = chain(); body.messages[2].content[0].content = [block]; rejected(body);
  }
});

test('inline media requires nonempty canonical base64 and stays within the complete payload bound', () => {
  for (const data of ['', 'YQ', 'YQ=', 'YQ===', 'YQ==\n', ' YQ==', 'Y Q==', 'YR==', 'YWJ=',
    '-w==', '_w==', 'YQ==YQ==', 1, null]) {
    const body = chain(); body.messages[2].content[0].content = [media('image', 'image/png', data)]; rejected(body);
  }
  const body = chain();
  body.messages[2].content[0].content = [media('document', 'application/pdf', 'YWJj'.repeat(131_072))];
  rejected(body);
});

test('inline media is admitted only within completed tool results', () => {
  const first = request(); first.messages[0].content = [media()]; rejected(first);
  const assistant = chain(); assistant.messages[1].content.unshift(media()); rejected(assistant);
  const user = chain(); user.messages[2].content.push(media()); rejected(user);
  const unclosed = chain(); unclosed.messages.pop(); rejected(unclosed);
});

test('orphaned, duplicate, reused and unclosed tool IDs are rejected', () => {
  for (const change of [body => { body.messages.pop(); },
    body => { body.messages[2].content[0].tool_use_id = 'unknown'; },
    body => { body.messages[2].content.push(clone(body.messages[2].content[0])); },
    body => { body.messages[1].content.push(use()); },
    body => { body.messages.push({ role: 'assistant', content: [use()] }, { role: 'user', content: [result()] }); },
    body => { body.messages[1].content = [{ type: 'text', text: 'already final' }]; }]) {
    const body = chain(); change(body); rejected(body);
  }
});

test('oversized payloads, message lists, block lists and deeply nested inputs are rejected', () => {
  const oversized = chain(); oversized.messages[2].content[0].content = 'x'.repeat(524_288); rejected(oversized);
  const messages = request(); messages.messages.push(...Array.from({ length: 100 }, () =>
    ({ role: 'system', content: [{ type: 'text', text: 'envelope' }] }))); rejected(messages);
  const blocks = chain(); blocks.messages[2].content[0].content = Array.from({ length: 65 }, () => ({ type: 'text', text: '' })); rejected(blocks);
  let nested = {}; for (let index = 0; index < 18; index++) nested = { nested };
  assert.throws(() => validateProjectToolInput('Read', nested), { code: 'PROJECT_PROTOCOL_REJECTED' });
  assert.throws(() => validateProjectToolInput('Write', { content: 'x'.repeat(262_144) }), { code: 'PROJECT_PROTOCOL_REJECTED' });
});

test('tool input validation admits only bounded JSON objects and does not alter optional official inputs', () => {
  const input = { command: 'pwd', timeout: 12000, description: 'Show project directory', run_in_background: false };
  assert.deepEqual(validateProjectToolInput('Bash', input), input);
  for (const invalid of [null, [], 'shell', { bad: undefined }, { bad: Infinity }, { bad: () => 'hidden' }]) {
    assert.throws(() => validateProjectToolInput('Bash', invalid), { code: 'PROJECT_PROTOCOL_REJECTED' });
  }
  const circular = {}; circular.self = circular;
  assert.throws(() => validateProjectToolInput('Bash', circular), { code: 'PROJECT_PROTOCOL_REJECTED' });
  assert.throws(() => validateProjectToolInput('WebFetch', {}), { code: 'PROJECT_PROTOCOL_REJECTED' });
});
