import { randomUUID } from 'node:crypto';
import { TranslationError, fail } from './errors.mjs';
import { protectText, textHash } from './protected-text.mjs';

function freeze(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

function copy(value) { return freeze(structuredClone(value)); }

function validateText(text) {
  if (typeof text !== 'string' || !text.trim()) fail('EMPTY_SOURCE', '请输入非空原文。');
}

function validateTarget(targetLanguage) {
  if (!['en', 'ja'].includes(targetLanguage)) fail('INVALID_TARGET', '发送语言必须明确选择英语 en 或日语 ja。');
}

function publicError(error) {
  return Object.freeze({
    code: typeof error?.code === 'string' ? error.code : 'TRANSLATION_FAILED',
    message: error instanceof TranslationError || error?.name === 'DeepSeekClientError'
      ? error.message : '翻译失败；未提交 Claude，请检查翻译服务后重试。',
    retryable: error?.retryable === true,
  });
}

export class TranslationPipeline {
  #client;
  #records = new Map();
  #pending = new Map();
  #outputs = new Map();

  constructor({ client }) {
    if (!client || typeof client.translate !== 'function' || typeof client.getPublicConfig !== 'function') {
      fail('INVALID_CLIENT', '翻译客户端必须提供 translate 与不含密钥的 getPublicConfig。');
    }
    this.#client = client;
  }

  #get(requestId) {
    const value = this.#records.get(requestId);
    if (!value) fail('UNKNOWN_REQUEST', '找不到当前草稿，请重新建立翻译请求。');
    return value;
  }

  record({ requestId = randomUUID(), source, targetLanguage, keepRanges = [] }) {
    if (typeof requestId !== 'string' || !requestId.trim() || requestId.length > 256) {
      fail('INVALID_REQUEST_ID', 'requestId 必须为 1 至 256 字符的非空字符串。');
    }
    if (this.#records.has(requestId)) fail('DUPLICATE_REQUEST', '此 requestId 已存在；编辑原文请调用 edit。');
    validateText(source);
    validateTarget(targetLanguage);
    protectText(source, { keepRanges });
    const record = {
      requestId, revision: 1, source, sourceHash: textHash(source), targetLanguage,
      keepRanges: structuredClone(keepRanges), modelConfig: structuredClone(this.#client.getPublicConfig()),
      state: 'draft', translation: null, translationHash: null, confirmed: null,
      wirePrepared: false, usage: null, error: null,
    };
    this.#records.set(requestId, record);
    return copy(record);
  }

  getRecord(requestId) { return copy(this.#get(requestId)); }

  edit(requestId, changes) {
    const record = this.#get(requestId);
    if (!changes || typeof changes !== 'object' || Array.isArray(changes)) fail('INVALID_EDIT', '草稿修改必须为结构化对象。');
    if (record.wirePrepared) fail('WIRE_ALREADY_PREPARED', '此输入已交付发送意图；请先由会话协调器核对实际接收状态。');
    const source = changes.source ?? record.source;
    const targetLanguage = changes.targetLanguage ?? record.targetLanguage;
    const keepRanges = changes.keepRanges ?? (changes.source === undefined ? record.keepRanges : []);
    validateText(source);
    validateTarget(targetLanguage);
    protectText(source, { keepRanges });
    this.#pending.get(requestId)?.abort();
    Object.assign(record, {
      revision: record.revision + 1, source, sourceHash: textHash(source), targetLanguage,
      keepRanges: structuredClone(keepRanges), state: 'draft', translation: null,
      translationHash: null, confirmed: null, usage: null, error: null,
    });
    return copy(record);
  }

  async translate(requestId, { signal } = {}) {
    const record = this.#get(requestId);
    if (record.wirePrepared) fail('WIRE_ALREADY_PREPARED', '已准备提交的输入不能重新翻译。');
    if (this.#pending.has(requestId)) fail('TRANSLATION_IN_PROGRESS', '当前草稿正在翻译；请等待或取消。');
    const revision = record.revision;
    const controller = new AbortController();
    const abort = () => controller.abort();
    if (signal?.aborted) controller.abort();
    else signal?.addEventListener('abort', abort, { once: true });
    this.#pending.set(requestId, controller);
    Object.assign(record, { state: 'translating', translation: null, translationHash: null, confirmed: null, error: null });
    try {
      const protectedText = protectText(record.source, { keepRanges: record.keepRanges });
      if (controller.signal.aborted) fail('TRANSLATION_CANCELLED', '翻译已取消；未提交 Claude。');
      const result = protectedText.hasTranslatableText
        ? await this.#client.translate({
          segmentId: `${requestId}:r${revision}`, text: protectedText.masked,
          targetLanguage: record.targetLanguage, signal: controller.signal,
        }) : { translation: protectedText.masked, usage: null };
      if (record.revision !== revision) fail('STALE_TRANSLATION', '原文或发送语言已更新；旧译文不可提交，请翻译当前版本。');
      if (controller.signal.aborted) fail('TRANSLATION_CANCELLED', '翻译已取消；未提交 Claude。');
      const translation = protectedText.restore(result.translation);
      Object.assign(record, {
        state: 'translated', translation, translationHash: textHash(translation),
        usage: structuredClone(result.usage ?? null), error: null,
      });
      return copy(record);
    } catch (error) {
      if (record.revision !== revision) {
        throw new TranslationError('STALE_TRANSLATION', '原文或发送语言已更新；旧译文不可提交，请翻译当前版本。');
      }
      if (record.revision === revision) {
        Object.assign(record, { state: controller.signal.aborted ? 'cancelled' : 'translation_failed', error: publicError(error) });
      }
      if (error instanceof TranslationError || error?.name === 'DeepSeekClientError') throw error;
      const safe = publicError(error);
      throw new TranslationError(safe.code, safe.message, { retryable: safe.retryable });
    } finally {
      signal?.removeEventListener('abort', abort);
      if (this.#pending.get(requestId) === controller) this.#pending.delete(requestId);
    }
  }

  cancel(requestId) { this.#get(requestId); this.#pending.get(requestId)?.abort(); }

  confirm({ requestId, revision, translationHash }) {
    const record = this.#get(requestId);
    if (record.state !== 'translated' || revision !== record.revision
      || translationHash !== record.translationHash) {
      fail('CONFIRMATION_MISMATCH', '只能确认当前完整译文；请刷新预览并确认对应版本。');
    }
    record.confirmed = { revision, sourceHash: record.sourceHash, translationHash };
    record.state = 'confirmed';
    return copy(record);
  }

  wireText({ requestId, revision, translationHash }) {
    const record = this.#get(requestId);
    if (record.wirePrepared) fail('WIRE_ALREADY_PREPARED', '该发送意图已消费；接收状态未知时不能自动重发。');
    if (record.state !== 'confirmed' || revision !== record.revision
      || translationHash !== record.translationHash || record.confirmed?.revision !== revision
      || record.confirmed?.sourceHash !== record.sourceHash
      || record.confirmed?.translationHash !== textHash(record.translation)) {
      fail('UNCONFIRMED_TRANSLATION', '发送前必须由用户确认当前版本译文；不会回退发送原文。');
    }
    record.wirePrepared = true;
    record.state = 'wire_prepared';
    return record.translation;
  }

  async translateOutputBlock(block, { signal, keepRanges = [], retry = false } = {}) {
    if (!block || typeof block !== 'object' || Array.isArray(block)) fail('INVALID_BLOCK', '输出块必须为结构化对象。');
    const raw = copy(block);
    if (block.type !== 'text') return freeze({ kind: 'passthrough', raw });
    block = raw;
    if (typeof block.blockId !== 'string' || !block.blockId.trim()
      || !Number.isSafeInteger(block.revision) || block.revision < 1
      || typeof block.text !== 'string' || (block.partial !== undefined && typeof block.partial !== 'boolean')) {
      fail('INVALID_TEXT_BLOCK', '文本输出需要 blockId、正整数 revision 和完整 text。');
    }
    if (block.complete !== true) fail('INCOMPLETE_TEXT_BLOCK', '请先收尾当前文本块；增量只能保留原文，不能提前翻译。');
    const sourceHash = textHash(block.text);
    const protectionFingerprint = JSON.stringify(keepRanges);
    const key = JSON.stringify([block.blockId, block.revision]);
    const previous = this.#outputs.get(key);
    if (previous && (previous.sourceHash !== sourceHash || previous.partial !== (block.partial === true)
      || previous.protectionFingerprint !== protectionFingerprint)) {
      fail('OUTPUT_REVISION_MISMATCH', '相同输出块版本的原文发生变化；请建立新 revision 后再翻译。');
    }
    if (previous && (!retry || previous.result?.state !== 'translation_failed')) return previous.promise;
    const entry = { sourceHash, partial: block.partial === true, protectionFingerprint, result: null, promise: null };
    entry.promise = (async () => {
      try {
        if (signal?.aborted) fail('TRANSLATION_CANCELLED', '输出翻译已取消；原文仍可查看。');
        const protectedText = block.text.trim() ? protectText(block.text, { keepRanges }) : null;
        const result = protectedText?.hasTranslatableText
          ? await this.#client.translate({
            segmentId: `${block.blockId}:r${block.revision}`, text: protectedText.masked,
            targetLanguage: 'zh-CN', signal,
          }) : { translation: protectedText?.masked ?? block.text, usage: null };
        if (signal?.aborted) fail('TRANSLATION_CANCELLED', '输出翻译已取消；原文仍可查看。');
        const displayZh = protectedText ? protectedText.restore(result.translation) : block.text;
        entry.result = freeze({
          kind: 'translated_text', raw, source: block.text, sourceHash,
          displayZh, displayHash: textHash(displayZh), state: 'translated', partial: block.partial === true,
          usage: structuredClone(result.usage ?? null),
        });
      } catch (error) {
        entry.result = freeze({
          kind: 'translated_text', raw, source: block.text, sourceHash, displayZh: null,
          state: 'translation_failed', partial: block.partial === true, error: publicError(error),
        });
      }
      return entry.result;
    })();
    this.#outputs.set(key, entry);
    return entry.promise;
  }
}
