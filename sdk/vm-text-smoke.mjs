import { randomUUID } from 'node:crypto';
import { readVMInput, runVMTextChat } from './vm-text-chat.mjs';

let input;
try {
  input = await readVMInput();
  if (!input || input.schema !== 'deepseek-text-smoke/v1' ||
      Object.keys(input).some(key => !['schema', 'apiKey', 'model', 'network', 'runtime'].includes(key))) {
    throw Object.assign(new Error('INVALID_INPUT'), { code: 'INVALID_INPUT' });
  }
  const terminal = await runVMTextChat({ ...input, schema: 'deepseek-text-chat/v1',
    request_id: randomUUID(), provider: 'deepseek-api', messages: [{ role: 'user',
      text: 'Reply with exactly DEEPSEEK_CLI_OK and nothing else.' }] }, () => {});
  const ok = terminal.type === 'completed' && terminal.text.trim() === 'DEEPSEEK_CLI_OK';
  process.stdout.write(JSON.stringify({ ok, code: ok ? 'OK' : terminal.code ?? 'PROVIDER_ACK_MISMATCH',
    model: input.model, ack: ok ? 'DEEPSEEK_CLI_OK' : null, no_tools: ok,
    request_count: terminal.request_count ?? 0, cli: { exit_code: ok ? 0 : null, signal: null },
    cleanup: { temporary_removed: terminal.temporary_removed === true, proxy_closed: terminal.proxy_closed === true } }) + '\n');
} catch (error) {
  process.stdout.write(JSON.stringify({ ok: false, code: error.code ?? 'VM_FAILED', model: input?.model ?? '',
    no_tools: false, cli: { exit_code: null, signal: null }, cleanup: { temporary_removed: false, proxy_closed: false } }) + '\n');
}
