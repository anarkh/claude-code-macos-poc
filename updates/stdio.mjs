import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MAX_METADATA_BYTES, UpdateFailure, runUpdateRequest, sanitizeUpdateError } from './client.mjs';

export async function runStdio(options = {}) {
  const defaultEmit = value => process.stdout.write(JSON.stringify(value) + '\n');
  if (!options || typeof options !== 'object' || Array.isArray(options) ||
      Object.keys(options).some(key => !['input', 'emit', 'signal', 'testOnly', 'transportDependencies'].includes(key)) ||
      (options.signal !== undefined && !(options.signal instanceof AbortSignal)) ||
      (options.emit !== undefined && typeof options.emit !== 'function') ||
      (options.input !== undefined && (typeof options.input?.[Symbol.asyncIterator] !== 'function' || typeof options.input.destroy !== 'function')) ||
      (options.testOnly !== undefined && options.testOnly !== true) ||
      (options.transportDependencies !== undefined && options.testOnly !== true)) {
    const terminal = { type: 'error', code: 'UPDATE_INVALID_REQUEST' };
    (typeof options?.emit === 'function' ? options.emit : defaultEmit)(terminal);
    return terminal;
  }
  const { input = process.stdin, emit = defaultEmit, signal, testOnly, transportDependencies } = options;
  const abort = new AbortController();
  let inputFailure;
  const onAbort = () => { abort.abort(); input.destroy(); };
  signal?.addEventListener('abort', onAbort, { once: true });
  const timer = setTimeout(() => {
    inputFailure = new UpdateFailure('UPDATE_INPUT_TIMEOUT'); input.destroy(inputFailure);
  }, 10_000);
  let terminal;
  try {
    if (signal?.aborted) onAbort();
    const chunks = []; let size = 0;
    for await (const chunk of input) {
      if (abort.signal.aborted) throw new UpdateFailure('UPDATE_CANCELLED');
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += bytes.length;
      if (size > MAX_METADATA_BYTES) { input.destroy(); throw new UpdateFailure('UPDATE_INPUT_TOO_LARGE'); }
      chunks.push(bytes);
    }
    clearTimeout(timer);
    let request;
    try { request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size))); }
    catch { throw new UpdateFailure('UPDATE_INVALID_REQUEST'); }
    terminal = await runUpdateRequest(request, emit, { signal: abort.signal,
      ...(testOnly === true ? { testOnly: true, transportDependencies } : {}) });
  } catch (error) {
    terminal = { type: 'error', code: sanitizeUpdateError(inputFailure ?? error, abort.signal).code };
  } finally {
    clearTimeout(timer); signal?.removeEventListener('abort', onAbort);
  }
  emit(terminal); return terminal;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const abort = new AbortController();
  const interrupt = () => abort.abort();
  process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
  try {
    if (process.argv.length !== 2) {
      process.stdout.write(JSON.stringify({ type: 'error', code: 'UPDATE_INVALID_REQUEST' }) + '\n');
      process.exitCode = 1;
    } else {
      const terminal = await runStdio({ signal: abort.signal });
      process.exitCode = terminal.type === 'error' ? 1 : 0;
    }
  } finally {
    process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt);
  }
}
