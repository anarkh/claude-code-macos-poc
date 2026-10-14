import { createHash, randomBytes } from 'node:crypto';
import { fail } from './errors.mjs';

export const textHash = (text) => createHash('sha256').update(text, 'utf8').digest('hex');
const malformedUnicode = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
const splitsSurrogate = (text, index) => index > 0 && index < text.length
  && text.charCodeAt(index - 1) >= 0xD800 && text.charCodeAt(index - 1) <= 0xDBFF
  && text.charCodeAt(index) >= 0xDC00 && text.charCodeAt(index) <= 0xDFFF;

function spansFor(text, keepRanges) {
  const spans = [];
  const add = (start, end, kind) => spans.push({ start, end, kind });
  for (const range of keepRanges) {
    if (!range || !Number.isSafeInteger(range.start) || !Number.isSafeInteger(range.end)
      || range.start < 0 || range.end <= range.start || range.end > text.length) {
      fail('INVALID_KEEP_RANGE', '保持原文范围无效；请按当前草稿重新选择 UTF-16 起止位置。');
    }
    if (splitsSurrogate(text, range.start) || splitsSurrogate(text, range.end)) {
      fail('INVALID_KEEP_RANGE', '保持原文范围不能从 Unicode 字符中间切开；请重新选择完整字符。');
    }
    add(range.start, range.end, 'explicit');
  }

  const lines = [...text.matchAll(/[^\r\n]*(?:\r\n|\n|\r|$)/g)].filter((m) => m[0].length);
  let fence = null;
  for (const line of lines) {
    const start = line.index;
    const content = line[0].replace(/[\r\n]+$/, '');
    if (fence) {
      const close = new RegExp(`^ {0,3}${fence.character}{${fence.length},}[ \\t]*$`);
      if (close.test(content)) {
        add(fence.start, start + line[0].length, 'fenced_code');
        fence = null;
      }
      continue;
    }
    const opening = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(content);
    if (opening && !(opening[1][0] === '`' && opening[2].includes('`'))) {
      fence = { start, character: opening[1][0], length: opening[1].length };
    } else if (/^(?: {4,}|\t)/.test(content)) {
      add(start, start + line[0].length, 'indented_code');
    } else if (/^ {0,3}\$ \S/.test(content)) {
      add(start, start + line[0].length, 'shell_command');
    }
  }
  if (fence) add(fence.start, text.length, 'fenced_code_eof');

  const covered = (start, end) => spans.some((s) => start < s.end && end > s.start);
  for (let index = 0; index < text.length;) {
    if (text[index] !== '`') { index += 1; continue; }
    let length = 1;
    while (text[index + length] === '`') length += 1;
    const opening = index;
    index += length;
    if (covered(opening, index)) continue;
    let closing = index;
    while (closing < text.length) {
      closing = text.indexOf('`', closing);
      if (closing < 0) break;
      let run = 1;
      while (text[closing + run] === '`') run += 1;
      if (run === length && !covered(closing, closing + run)) {
        add(opening, closing + run, 'inline_code');
        index = closing + run;
        break;
      }
      closing += run;
    }
  }

  const patterns = [
    ['url', /(?:[a-z][a-z0-9+.-]*:\/\/|mailto:|www\.)[^\s<>"'`，。；！？]+/gi],
    ['path', /(?:[A-Za-z]:\\|(?:~|\.{1,2})?\/)[^\s<>"'`，。；！？]+|\b(?:[\w.-]+\/)+[\w.-]+/g],
    ['uuid', /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi],
    ['number', /(?<![A-Za-z0-9_])[-+]?\d+(?:\.\d+)?(?:%|ms|s|MB|GB|KiB|MiB|GiB)?(?![A-Za-z0-9_])/g],
  ];
  for (const [kind, pattern] of patterns) {
    for (const match of text.matchAll(pattern)) {
      let value = match[0];
      if (kind === 'path' || kind === 'url') {
        value = value.replace(/[.,;!?:]+$/, '');
        for (const [closing, opening] of [[')', '('], [']', '['], ['}', '{']]) {
          while (value.endsWith(closing)
            && value.split(closing).length > value.split(opening).length) value = value.slice(0, -1);
        }
      }
      if (value) add(match.index, match.index + value.length, kind);
    }
  }

  spans.sort((a, b) => a.start - b.start || b.end - a.end);
  const merged = [];
  for (const span of spans) {
    const previous = merged.at(-1);
    if (previous && span.start < previous.end) {
      previous.end = Math.max(previous.end, span.end);
      previous.kinds.add(span.kind);
    } else merged.push({ ...span, kinds: new Set([span.kind]) });
  }
  return merged;
}

export function protectText(text, { keepRanges = [] } = {}) {
  if (typeof text !== 'string' || !text.trim()) fail('EMPTY_SOURCE', '待译文本不能为空。');
  if (malformedUnicode.test(text)) fail('INVALID_SOURCE', '原文包含不完整 Unicode 字符；请修正后再翻译。');
  if (!Array.isArray(keepRanges)) fail('INVALID_KEEP_RANGE', '保持原文范围必须为数组。');
  if (text.includes('[[CCP:')) fail('RESERVED_PLACEHOLDER', '原文包含内部占位符前缀；请调整文本后重新翻译。');
  const nonce = randomBytes(16).toString('hex');
  const spans = spansFor(text, keepRanges);
  const fragments = spans.map((span, index) => Object.freeze({
    token: `[[CCP:${nonce}:${index}]]`,
    text: text.slice(span.start, span.end),
    hash: textHash(text.slice(span.start, span.end)),
    start: span.start,
    end: span.end,
    kinds: Object.freeze([...span.kinds]),
  }));
  let cursor = 0;
  let masked = '';
  for (const fragment of fragments) {
    masked += text.slice(cursor, fragment.start) + fragment.token;
    cursor = fragment.end;
  }
  masked += text.slice(cursor);

  return Object.freeze({
    masked,
    fragments: Object.freeze(fragments),
    sourceHash: textHash(text),
    hasTranslatableText: masked.replace(/\[\[CCP:[^\]]+\]\]/g, '').trim().length > 0,
    restore(translation) {
      if (typeof translation !== 'string' || !translation.trim()) {
        fail('EMPTY_TRANSLATION', '模型返回空译文；未提交 Claude，请重新翻译。');
      }
      if (malformedUnicode.test(translation)) fail('INVALID_TRANSLATION', '译文包含不完整 Unicode 字符；未提交 Claude，请重新翻译。');
      const tokens = translation.match(/\[\[CCP:[^\]]*\]\]/g) ?? [];
      if (tokens.length !== fragments.length
        || tokens.some((token, index) => token !== fragments[index].token)) {
        fail('PLACEHOLDER_MISMATCH', '译文的保护片段缺失、重复、改写或顺序变化；未提交 Claude，请重新翻译。');
      }
      const natural = translation.replace(/\[\[CCP:[^\]]*\]\]/g, ' ');
      if (natural.includes('[[CCP:') || spansFor(natural, []).length) {
        fail('UNEXPECTED_PROTECTED_CONTENT', '译文新增了代码、路径、URL、ID 或数值；未提交 Claude，请核对原文并重新翻译。');
      }
      let restored = translation;
      for (const fragment of fragments) {
        if (textHash(fragment.text) !== fragment.hash) fail('FRAGMENT_INTEGRITY', '本地保护片段摘要不一致。');
        restored = restored.replace(fragment.token, () => fragment.text);
      }
      return restored;
    },
  });
}
