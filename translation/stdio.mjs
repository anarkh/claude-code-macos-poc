import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { DeepSeekClient } from './client.mjs';
import { TranslationPipeline } from './pipeline.mjs';
import { textHash } from './protected-text.mjs';
import { fail } from './errors.mjs';
import { NETWORK_ERROR_CODES } from '../network/proxy-transport.mjs';
import { DEFAULT_RUNTIME_PROFILE, RUNTIME_ERROR_CODES, validateRuntimeProfile } from '../runtime/profile.mjs';

const MAX_STDIN_BYTES = 1_048_576;
const SAFE_CODES = new Set([
  ...NETWORK_ERROR_CODES,
  ...RUNTIME_ERROR_CODES,
  'INVALID_REQUEST', 'REQUEST_TOO_LARGE', 'INVALID_CONFIG', 'INVALID_INPUT', 'INPUT_TOO_LARGE',
  'EMPTY_SOURCE', 'INVALID_TARGET', 'INVALID_KEEP_RANGE', 'RESERVED_PLACEHOLDER',
  'INVALID_SOURCE', 'INVALID_TRANSLATION',
  'BUSY', 'RATE_LIMITED', 'TIMEOUT', 'ABORTED', 'TRANSPORT_ERROR', 'RESPONSE_TOO_LARGE',
  'RESPONSE_SCHEMA', 'INVALID_CONTENT_TYPE', 'INVALID_JSON', 'INCOMPLETE_COMPLETION',
  'INVALID_TRANSLATION_JSON', 'TRANSLATION_SCHEMA', 'HTTP_ERROR', 'REDIRECT_REFUSED',
  'EMPTY_TRANSLATION', 'PLACEHOLDER_MISMATCH', 'UNEXPECTED_PROTECTED_CONTENT',
  'FRAGMENT_INTEGRITY', 'TRANSLATION_CANCELLED', 'STALE_TRANSLATION', 'TRANSLATION_FAILED',
]);

function safeFailure(error) {
  return { ok: false, error_code: SAFE_CODES.has(error?.code) ? error.code : 'TRANSLATION_FAILED' };
}

function fixtureTransport({ body }) {
  const request = JSON.parse(body);
  const data = JSON.parse(request.messages[1].content);
  const system = request.messages[0].content;
  let translation;
  if (system.includes('into English.')) {
    translation = data.text.replaceAll('请解释这个函数，但不要修改文件。', 'Please explain this function, but do not modify any files.')
      .replaceAll('请解释', 'Please explain');
    if (translation === data.text) translation = `English fixture translation: ${data.text}`;
  } else if (system.includes('into Japanese.')) {
    translation = data.text.replaceAll('请解释这个函数，但不要修改文件。', 'この関数を説明してください。ただし、ファイルは変更しないでください。')
      .replaceAll('请解释', '説明してください');
    if (translation === data.text) translation = `日本語の固定応答: ${data.text}`;
  } else {
    translation = data.text.replaceAll('Finished', '已完成').replaceAll('完了しました', '已完成');
    if (translation === data.text) translation = `中文固定响应：${data.text}`;
  }
  return Promise.resolve({
    status: 200, headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      object: 'chat.completion', id: 'fixture-completion', model: request.model,
      choices: [{ index: 0, finish_reason: 'stop', message: {
        role: 'assistant', content: JSON.stringify({ segment_id: data.segment_id, translation }),
      } }], usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
    }),
  });
}

export async function handleRequest(request, { fixtureOnly = false, transport, testOnly = false } = {}) {
  try {
    if (!request || typeof request !== 'object' || Array.isArray(request)
      || !['translate_input', 'translate_output'].includes(request.operation)
      || typeof request.text !== 'string' || !request.text.trim()
      || (request.operation === 'translate_input' && !['en', 'ja'].includes(request.target))
      || (request.operation === 'translate_output' && request.target !== 'zh')) {
      fail('INVALID_REQUEST', '桥请求需要有效 operation、非空 text 与匹配的 target。');
    }
    if (Buffer.byteLength(JSON.stringify(request), 'utf8') > MAX_STDIN_BYTES) fail('REQUEST_TOO_LARGE', 'JSON 请求不能超过 1 MiB。');
    const model = request.model ?? (fixtureOnly ? {} : null);
    if (!model || typeof model !== 'object' || Array.isArray(model)) fail('INVALID_CONFIG', '请显式配置翻译模型。');
    // Swift starts the host bridge with the same profile. Validate the request
    // snapshot before client creation without mutating the parent process env.
    validateRuntimeProfile((fixtureOnly === true || testOnly === true) && request.runtime === undefined
      ? DEFAULT_RUNTIME_PROFILE : request.runtime);
    const client = new DeepSeekClient({
      endpoint: model.endpoint ?? 'https://api.deepseek.com',
      model: model.model ?? (fixtureOnly ? 'fixture-only' : undefined),
      key: fixtureOnly ? 'fake-translation-fixture-key' : model.apiKey,
      network: request.network,
    }, { transport: fixtureOnly ? fixtureTransport : transport, testOnly: fixtureOnly === true || testOnly === true });
    const pipeline = new TranslationPipeline({ client });
    const requestId = randomUUID();
    let translated;
    if (request.operation === 'translate_input') {
      pipeline.record({ requestId, source: request.text, targetLanguage: request.target });
      const record = await pipeline.translate(requestId);
      translated = record.translation;
    } else {
      const output = await pipeline.translateOutputBlock({
        type: 'text', blockId: requestId, revision: 1, complete: true, text: request.text,
      });
      if (output.state !== 'translated') return safeFailure(output.error);
      translated = output.displayZh;
    }
    return {
      ok: true, original: request.text, translated, revision: 1, request_id: requestId,
      translation_sha256: textHash(translated), requires_confirmation: request.operation === 'translate_input',
      fixture_only: fixtureOnly,
    };
  } catch (error) { return safeFailure(error); }
}

export async function runStdio({ input = process.stdin, output = process.stdout, fixtureOnly = false, transport, testOnly = false } = {}) {
  let response;
  try {
    const chunks = [];
    let size = 0;
    for await (const chunk of input) {
      const bytes = typeof chunk === 'string' ? Buffer.from(chunk, 'utf8') : chunk;
      size += bytes.byteLength;
      if (size > MAX_STDIN_BYTES) fail('REQUEST_TOO_LARGE', 'stdin JSON 不能超过 1 MiB。');
      chunks.push(bytes);
    }
    let request;
    try { request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size))); }
    catch { fail('INVALID_REQUEST', 'stdin 必须为一个完整的 UTF-8 JSON 对象。'); }
    response = await handleRequest(request, { fixtureOnly, transport, testOnly });
  } catch (error) { response = safeFailure(error); }
  output.write(`${JSON.stringify(response)}\n`);
  return response;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (args.length > 1 || (args.length === 1 && args[0] !== '--fixture')) {
    process.stdout.write(`${JSON.stringify({ ok: false, error_code: 'INVALID_REQUEST' })}\n`);
    process.exitCode = 1;
  } else {
    const response = await runStdio({ fixtureOnly: args[0] === '--fixture' });
    process.exitCode = response.ok ? 0 : 1;
  }
}
