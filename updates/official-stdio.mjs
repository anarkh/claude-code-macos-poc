import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runOfficialRequest, OfficialFailure, sanitizeOfficialError, MAX_OFFICIAL_INPUT_BYTES } from './official-client.mjs';

// One bounded request per process. Host cancellation is SIGTERM/SIGINT; it
// aborts both the active CONNECT tunnel and owned artifact cleanup.
export async function runOfficialStdio(options = {}) {
  const defaultEmit = event => process.stdout.write(JSON.stringify(event) + '\n');
  const valid = options && typeof options === 'object' && !Array.isArray(options) &&
    Object.keys(options).every(key => ['input', 'emit', 'signal', 'testOnly', 'transportDependencies'].includes(key)) &&
    (options.signal === undefined || options.signal instanceof AbortSignal) &&
    (options.emit === undefined || typeof options.emit === 'function') &&
    (options.input === undefined || (typeof options.input?.[Symbol.asyncIterator] === 'function' && typeof options.input.destroy === 'function')) &&
    (options.testOnly === undefined || options.testOnly === true) && (options.transportDependencies === undefined || options.testOnly === true);
  if (!valid) { const terminal = { type: 'error', code: 'OFFICIAL_INVALID_REQUEST' }; (typeof options?.emit === 'function' ? options.emit : defaultEmit)(terminal); return terminal; }
  const { input = process.stdin, emit = defaultEmit, signal } = options;
  const abort = new AbortController(); let inputFailure, terminal;
  const onAbort = () => { abort.abort(); input.destroy(); };
  signal?.addEventListener('abort', onAbort, { once: true });
  const timer = setTimeout(() => { inputFailure = new OfficialFailure('OFFICIAL_INPUT_TIMEOUT'); input.destroy(inputFailure); }, 10000);
  try {
    if (signal?.aborted) onAbort();
    const chunks = []; let size = 0;
    for await (const chunk of input) {
      if (abort.signal.aborted) throw new OfficialFailure('OFFICIAL_CANCELLED');
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk); size += bytes.length;
      if (size > MAX_OFFICIAL_INPUT_BYTES) { input.destroy(); throw new OfficialFailure('OFFICIAL_INPUT_TOO_LARGE'); }
      chunks.push(bytes);
    }
    clearTimeout(timer);
    if (abort.signal.aborted) throw new OfficialFailure('OFFICIAL_CANCELLED');
    let request; try { request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size))); }
    catch { throw new OfficialFailure('OFFICIAL_INVALID_REQUEST'); }
    terminal = await runOfficialRequest(request, emit, { signal: abort.signal,
      ...(options.testOnly === true ? { testOnly: true, transportDependencies: options.transportDependencies } : {}) });
  } catch (error) { terminal = { type: 'error', code: sanitizeOfficialError(inputFailure ?? error, abort.signal).code }; }
  finally { clearTimeout(timer); signal?.removeEventListener('abort', onAbort); }
  emit(terminal); return terminal;
}
export const runStdio = runOfficialStdio;
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const abort = new AbortController(), interrupt = () => abort.abort();
  process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
  try {
    if (process.argv.length !== 2) { process.stdout.write(JSON.stringify({ type: 'error', code: 'OFFICIAL_INVALID_REQUEST' }) + '\n'); process.exitCode = 1; }
    else { const terminal = await runOfficialStdio({ signal: abort.signal }); process.exitCode = terminal.type === 'error' ? 1 : 0; }
  } finally { process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt); }
}
