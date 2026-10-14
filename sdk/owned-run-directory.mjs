// This receipt contains ownership and process lifecycle only, never credentials.
// A missing/partial receipt is deliberately not permission to delete a directory.
import { constants, closeSync, fchmodSync, fsyncSync, openSync, renameSync, writeFileSync } from 'node:fs';
import { chmod, lstat, mkdtemp, realpath, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';

export const OWNED_RUN_MANIFEST = '.claude-isolation-owner.json';
export const OWNED_RUN_SCHEMA = 'claude-isolation-owned-run/v1';
const PREFIX = { chat: 'claude-deepseek-chat-', 'text-smoke': 'claude-deepseek-text-' };

export function nativeProcessMayBeRunning(pid) {
  if (!Number.isInteger(pid) || pid <= 1 || pid > 2_147_483_647) return true;
  for (const target of [pid, -pid]) {
    try { process.kill(target, 0); return true; }
    catch (error) { if (error.code !== 'ESRCH') return true; }
  }
  return false;
}

// An exited leader can leave its process group alive briefly while native
// helper processes finish. Delete only after both identities are absent;
// a live group or uncertain probe still retains the ownership receipt.
export async function waitForNativeProcessExit(pid, timeoutMs = 1000) {
  const deadline = performance.now() + timeoutMs;
  while (nativeProcessMayBeRunning(pid)) {
    const remaining = deadline - performance.now();
    if (remaining <= 0) return false;
    await new Promise(resolve => setTimeout(resolve, Math.min(25, remaining)));
  }
  return true;
}

export async function createOwnedRunDirectory(kind, { temporaryRoot = os.tmpdir() } = {}) {
  if (!Object.hasOwn(PREFIX, kind)) throw new Error('OWNED_RUN_KIND_INVALID');
  const directory = await realpath(await mkdtemp(path.join(temporaryRoot, PREFIX[kind])));
  try {
    await chmod(directory, 0o700);
    const identity = await lstat(directory, { bigint: true });
    const manifest = { schema: OWNED_RUN_SCHEMA, run_id: randomUUID(), uid: process.getuid(), pid: process.pid,
      kind, directory_dev: String(identity.dev), directory_ino: String(identity.ino),
      native_state: 'not-started', native_pid: null };
    function persist() {
      const staging = path.join(directory, `.owner-${randomUUID()}.tmp`);
      let descriptor;
      try {
        descriptor = openSync(staging, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        fchmodSync(descriptor, 0o600);
        writeFileSync(descriptor, JSON.stringify(manifest));
        fsyncSync(descriptor);
      } finally { if (descriptor !== undefined) closeSync(descriptor); }
      renameSync(staging, path.join(directory, OWNED_RUN_MANIFEST));
    }
    persist();
    return { directory,
      // Persist synchronously BEFORE spawn. A crash in the spawn/register gap
      // leaves a blocking, uncertain run, not an apparently inactive run.
      markNativeLaunchPending() { manifest.native_state = 'pending'; manifest.native_pid = null; persist(); },
      registerNativePID(pid) {
        if (!Number.isInteger(pid) || pid <= 1 || pid > 2_147_483_647) throw new Error('OWNED_RUN_PID_INVALID');
        manifest.native_state = 'registered'; manifest.native_pid = pid; persist();
      },
    };
  } catch (error) {
    // No child has been launched while this factory is initializing.
    try { await rm(directory, { recursive: true, force: true }); }
    catch { throw new Error('OWNED_RUN_INITIALIZATION_CLEANUP_FAILED'); }
    throw error;
  }
}
