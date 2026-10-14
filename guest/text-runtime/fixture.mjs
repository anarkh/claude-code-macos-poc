// Synthetic transport fixture only; production launch requires runtime.mjs.
import readline from 'node:readline';
import { existsSync, writeFileSync } from 'node:fs';
const input = readline.createInterface({ input: process.stdin });
process.stdout.write(JSON.stringify({ kind: 'ready' }) + '\n');
input.on('line', line => {
  const value = JSON.parse(line);
  if (value.kind === 'start') {
    const disposable_state_clean = !existsSync('/home/claude/work/one-shot-marker');
    writeFileSync('/home/claude/work/one-shot-marker', 'synthetic guest state only', { flag: 'wx', mode: 0o600 });
    process.stdout.write(JSON.stringify({ kind: 'native_init', model: 'synthetic-fixture', session_id: 'fixture-guest-only', no_tools: true }) + '\n');
    process.stdout.write(JSON.stringify({ kind: 'result', ok: true, text: 'VM fixture completed', disposable_state_clean }) + '\n');
    input.close();
    process.exit(0);
  }
});
