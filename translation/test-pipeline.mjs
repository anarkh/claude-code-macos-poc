import test from 'node:test';
import assert from 'node:assert/strict';
import { TranslationPipeline } from './pipeline.mjs';
import { protectText, textHash } from './protected-text.mjs';

function client(translate = async ({ text }) => ({ translation: text, usage: { total_tokens: 10 } })) {
  return { translate, getPublicConfig: () => ({ endpoint: 'https://api.deepseek.com/chat/completions', model: 'fixture-only' }) };
}

const confirmation = (record) => ({ requestId: record.requestId, revision: record.revision, translationHash: record.translationHash });
const code = (expected) => (error) => error.code === expected;

test('fences, inline code, paths, URLs, UUIDs, numbers and explicit ranges remain byte-identical', () => {
  const source = '请解释 `a(15)`，不要改 src/index.js 或 /tmp/中文.txt。\r\n'
    + '参考 https://example.com/a?q=日本。最多15秒。ID 73c5b8bd-1394-4e46-b5d0-b74f7e346c54。\r\n'
    + '```diff\r\n-const x = "中文";\r\n+const x = 2;\r\n```\r\n'
    + '$ node app.mjs --dry-run\n固定术语';
  const keepStart = source.indexOf('固定术语');
  const protectedText = protectText(source, { keepRanges: [{ start: keepStart, end: keepStart + 4 }] });
  assert(!protectedText.masked.includes('const x'));
  assert(!protectedText.masked.includes('example.com'));
  assert(protectedText.masked.includes('最多'));
  assert(!protectedText.masked.includes('固定术语'));
  const restored = protectedText.restore(protectedText.masked.replace('请解释', 'Please explain').replace('不要改', 'do not change'));
  for (const fragment of protectedText.fragments) assert(restored.includes(fragment.text));
  assert(restored.includes('```diff\r\n-const x = "中文";\r\n+const x = 2;\r\n```\r\n'));
  assert.equal(protectedText.sourceHash, textHash(source));
});

test('unclosed fenced code is protected through EOF; fences are scoped to one block', () => {
  const original = '解释如下。\n~~~python\nx = "中文"\n';
  const protectedText = protectText(original);
  assert.equal(protectedText.fragments.at(-1).kinds.includes('fenced_code_eof'), true);
  assert.equal(protectedText.restore(protectedText.masked), original);
  assert.equal(protectText('另一个独立块').fragments.length, 0);
});

test('missing, duplicated, rewritten, reordered and unknown placeholders fail closed', () => {
  const protectedText = protectText('解释 `a` 和 `b`。');
  const [a, b] = protectedText.fragments.map((fragment) => fragment.token);
  const invalid = [
    protectedText.masked.replace(a, ''), protectedText.masked + a,
    protectedText.masked.replace(a, a.replace('CCP', 'CCQ')),
    protectedText.masked.replace(a, 'FIRST').replace(b, a).replace('FIRST', b),
    protectedText.masked + '[[CCP:unknown:0]]',
  ];
  for (const value of invalid) assert.throws(() => protectedText.restore(value), code('PLACEHOLDER_MISMATCH'));
});

test('invented executable content, URL, path, UUID or numeric literal is not accepted', () => {
  const protectedText = protectText('请只解释，不执行。');
  for (const value of ['Run `rm -rf x`', '```sh\nexit\n```', 'Open /etc/passwd', 'See https://evil.invalid', 'Wait 25ms']) {
    assert.throws(() => protectedText.restore(value), code('UNEXPECTED_PROTECTED_CONTENT'));
  }
  assert.throws(() => protectText('[[CCP:forged]]'), code('RESERVED_PLACEHOLDER'));
  assert.throws(() => protectText('x', { keepRanges: [{ start: 0, end: 2 }] }), code('INVALID_KEEP_RANGE'));
  assert.throws(() => protectText('😀', { keepRanges: [{ start: 0, end: 1 }] }), code('INVALID_KEEP_RANGE'));
  assert.throws(() => protectText('\uD800'), code('INVALID_SOURCE'));
  assert.throws(() => protectedText.restore('\uD800'), code('INVALID_TRANSLATION'));
});

test('current translation requires explicit matching confirmation and one wire consumption', async () => {
  const pipeline = new TranslationPipeline({ client: client(async ({ text }) => ({ translation: text.replace('请解释', 'Please explain') })) });
  const original = pipeline.record({ source: '请解释 `函数()`', targetLanguage: 'en' });
  assert.throws(() => pipeline.wireText({ requestId: original.requestId, revision: 1 }), code('UNCONFIRMED_TRANSLATION'));
  const translated = await pipeline.translate(original.requestId);
  assert.equal(translated.state, 'translated');
  assert.equal(translated.translation, 'Please explain `函数()`');
  assert.throws(() => pipeline.confirm({ ...confirmation(translated), translationHash: 'wrong' }), code('CONFIRMATION_MISMATCH'));
  pipeline.confirm(confirmation(translated));
  assert.equal(pipeline.wireText(confirmation(translated)), translated.translation);
  assert.throws(() => pipeline.wireText(confirmation(translated)), code('WIRE_ALREADY_PREPARED'));
  assert.throws(() => pipeline.edit(original.requestId, { source: '新的输入' }), code('WIRE_ALREADY_PREPARED'));
  assert.equal(pipeline.getRecord(original.requestId).source, '请解释 `函数()`');
});

test('source and language edits revoke old translation and old confirmation', async () => {
  const pipeline = new TranslationPipeline({ client: client() });
  const original = pipeline.record({ source: '请解释', targetLanguage: 'en' });
  const translated = await pipeline.translate(original.requestId);
  pipeline.confirm(confirmation(translated));
  const updated = pipeline.edit(original.requestId, { source: '不要修改', targetLanguage: 'ja' });
  assert.equal(updated.revision, 2);
  assert.equal(updated.translation, null);
  assert.equal(updated.confirmed, null);
  assert.throws(() => pipeline.wireText(confirmation(translated)), code('UNCONFIRMED_TRANSLATION'));
  assert.throws(() => pipeline.confirm(confirmation(translated)), code('CONFIRMATION_MISMATCH'));
});

test('in-flight edit prevents stale model result from becoming sendable', async () => {
  let resolve;
  const pipeline = new TranslationPipeline({ client: client(() => new Promise((done) => { resolve = done; })) });
  const record = pipeline.record({ source: '请解释', targetLanguage: 'en' });
  const pending = pipeline.translate(record.requestId);
  pipeline.edit(record.requestId, { source: '新草稿' });
  resolve({ translation: 'Please explain' });
  await assert.rejects(pending, code('STALE_TRANSLATION'));
  const current = pipeline.getRecord(record.requestId);
  assert.equal(current.state, 'draft');
  assert.equal(current.source, '新草稿');
  assert.equal(current.translation, null);
});

test('cancelled or failed input never silently falls back to source', async () => {
  const pipeline = new TranslationPipeline({ client: client(async () => { throw new Error('private response or credential'); }) });
  const record = pipeline.record({ source: '请解释', targetLanguage: 'en' });
  await assert.rejects(pipeline.translate(record.requestId), (error) => error.code === 'TRANSLATION_FAILED' && !error.message.includes('private'));
  assert.equal(pipeline.getRecord(record.requestId).state, 'translation_failed');
  assert.throws(() => pipeline.wireText({ requestId: record.requestId, revision: 1 }), code('UNCONFIRMED_TRANSLATION'));
  const abort = new AbortController(); abort.abort();
  await assert.rejects(pipeline.translate(record.requestId, { signal: abort.signal }), code('TRANSLATION_CANCELLED'));
});

test('fully protected source bypasses model and still requires confirmation', async () => {
  let calls = 0;
  const pipeline = new TranslationPipeline({ client: client(async () => { calls += 1; throw new Error('must not call'); }) });
  const record = pipeline.record({ source: '```sh\necho 中文\n```', targetLanguage: 'ja' });
  const result = await pipeline.translate(record.requestId);
  assert.equal(result.translation, record.source);
  assert.equal(calls, 0);
  assert.throws(() => pipeline.wireText(confirmation(result)), code('UNCONFIRMED_TRANSLATION'));
});

test('tool, permission, IDs, errors, unknown and thinking blocks bypass translator without deep changes', async () => {
  const pipeline = new TranslationPipeline({ client: client(async () => { throw new Error('must not translate controls'); }) });
  for (const type of ['tool_use', 'input_json_delta', 'permission_request', 'tool_result', 'error', 'usage', 'thinking', 'unknown']) {
    const original = { type, id: '原始ID', request_id: 'request-original', input: { command: 'echo 中文', options: ['允许', '拒绝'] }, error: { code: 'EACCES', raw: '报错' } };
    const result = await pipeline.translateOutputBlock(original);
    assert.deepEqual(result.raw, original);
    assert.notEqual(result.raw, original);
    assert.equal(Object.isFrozen(result.raw.input.options), true);
    assert.equal(Object.isFrozen(original), false);
    assert.equal(result.kind, 'passthrough');
  }
});

test('EN and JA inputs and Chinese output form a mock-only bilingual loop', async () => {
  const targets = [];
  const pipeline = new TranslationPipeline({ client: client(async ({ text, targetLanguage }) => {
    targets.push(targetLanguage);
    return { translation: text.replace('请解释', targetLanguage === 'en' ? 'Please explain' : '説明してください').replace('Finished', '已完成').replace('完了しました', '已完成') };
  }) });
  for (const targetLanguage of ['en', 'ja']) {
    const record = pipeline.record({ source: '请解释 `foo()`', targetLanguage });
    const translated = await pipeline.translate(record.requestId);
    pipeline.confirm(confirmation(translated));
    assert(pipeline.wireText(confirmation(translated)).includes('`foo()`'));
    const raw = { type: 'text', blockId: `output-${targetLanguage}`, revision: 1, complete: true, text: `${targetLanguage === 'en' ? 'Finished' : '完了しました'}: \`foo()\`` };
    const output = await pipeline.translateOutputBlock(raw);
    assert.equal(output.displayZh, '已完成: `foo()`');
    assert.equal(output.source, raw.text);
    assert.deepEqual(output.raw, raw);
  }
  assert.deepEqual(targets, ['en', 'zh-CN', 'ja', 'zh-CN']);
});

test('completed duplicate output is cached; failure retry only repeats translator', async () => {
  let calls = 0;
  const pipeline = new TranslationPipeline({ client: client(async ({ text }) => {
    calls += 1;
    if (calls === 1) throw new Error('offline');
    return { translation: text.replace('Finished', '完成') };
  }) });
  const block = { type: 'text', blockId: 'answer', revision: 1, complete: true, partial: true, text: 'Finished \n```sh\necho partial' };
  const failed = await pipeline.translateOutputBlock(block);
  assert.equal(failed.state, 'translation_failed');
  assert.equal(failed.source, block.text);
  assert.equal(failed.displayZh, null);
  await pipeline.translateOutputBlock(block);
  assert.equal(calls, 1);
  const result = await pipeline.translateOutputBlock(block, { retry: true });
  assert.equal(calls, 2);
  assert.equal(result.partial, true);
  assert.equal(result.displayZh, '完成 \n```sh\necho partial');
  assert.deepEqual(await pipeline.translateOutputBlock(block), result);
  assert.equal(calls, 2);
  await assert.rejects(pipeline.translateOutputBlock({ ...block, text: 'changed' }), code('OUTPUT_REVISION_MISMATCH'));
  await assert.rejects(pipeline.translateOutputBlock({ ...block, partial: false }), code('OUTPUT_REVISION_MISMATCH'));
  await assert.rejects(pipeline.translateOutputBlock(block, { keepRanges: [{ start: 0, end: 8 }] }), code('OUTPUT_REVISION_MISMATCH'));
  await assert.rejects(pipeline.translateOutputBlock({ ...block, blockId: 'incomplete', complete: false }), code('INCOMPLETE_TEXT_BLOCK'));
});

test('output retains captured original when caller mutates its object during translation', async () => {
  let resolve;
  const pipeline = new TranslationPipeline({ client: client(() => new Promise((done) => { resolve = done; })) });
  const block = { type: 'text', blockId: 'immutable', revision: 1, complete: true, text: 'Finished' };
  const pending = pipeline.translateOutputBlock(block);
  block.text = 'MUTATED';
  resolve({ translation: '完成' });
  const result = await pending;
  assert.equal(result.raw.text, 'Finished');
  assert.equal(result.source, 'Finished');
});
