import { spawn } from 'node:child_process';
import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { id } from './validation.mjs';
import { MAX_OUTPUT_BYTES } from './validation.mjs';

// These lock files are permanent: unlinking one could create two independent locks.
// The kernel releases the lock on process death; no PID/mtime stale-lock guessing.
/** Executes a record mutation under permanent catalog-then-record kernel locks. expectedRevision guards logical content; expectedRecordRevision guards exact saved bytes. Returns the saved or removed record and rejects lock, revision, I/O, or timeout failures. */
export async function saveSuiteTransaction(store, saved, expectedRevision, { operation = 'save', projectId, expectedRecordRevision, kind = 'suites' } = {}) {
  store.path(kind, saved.id);
  // Preserve existing suite lock inodes; all writes/deletes of another record
  // share its kind-qualified lock, including recovery revision checks.
  const lockName = `${kind === 'suites' ? '' : kind + '-'}${id(saved.id)}.lock`;
  const lockPath = join(store.root, '.suite-locks', lockName);
  const catalogLockPath = join(store.root, '.suite-locks', `catalog-${kind}.lock`);
  for (const path of [catalogLockPath, lockPath]) {
    const handle = await open(path, constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
    try { if (!(await handle.stat()).isFile()) throw new Error('Invalid suite transaction lock'); }
    finally { await handle.close(); }
  }
  const worker = fileURLToPath(new URL('./suite-transaction-worker.mjs', import.meta.url));
  const executable = process.platform === 'darwin' ? '/usr/bin/lockf' : '/usr/bin/flock';
  // Match inference admission order when a caller also holds its lease:
  // inference -> catalog -> record. The catalog lock makes distinct-ID capacity
  // checks atomic, while the existing record lock preserves revision fencing.
  const recordArguments = process.platform === 'darwin'
    ? ['-k', '-s', '-t', '5', lockPath, process.execPath, worker]
    : ['-w', '5', lockPath, process.execPath, worker];
  const arguments_ = process.platform === 'darwin'
    ? ['-k', '-s', '-t', '5', catalogLockPath, executable, ...recordArguments]
    : ['-w', '5', catalogLockPath, executable, ...recordArguments];
  const child = spawn(executable, arguments_, { detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
  child.stdout.setEncoding('utf8');
  return new Promise((accept, reject) => {
    const outputChunks = [];
    let outputBytes = 0, diagnostic = '', failed;
    /** Retains the transaction failure and kills its entire process group so an expired writer cannot commit later. */
    const stop = (message) => {
      failed ||= new Error(message);
      try { process.kill(-child.pid, 'SIGKILL'); } catch { /* Already exited. */ }
    };
    // Acquisition and execution have independent bounds. The entire process group
    // is stopped before rejecting, so an expired writer cannot commit afterwards.
    const timeout = setTimeout(() => stop('Suite save transaction timed out'), 20000);
    child.stdout.on('data', (chunk) => {
      if (failed) return;
      outputBytes += Buffer.byteLength(chunk);
      if (outputBytes > MAX_OUTPUT_BYTES + 1024) { stop('Suite transaction output exceeds limit'); return; }
      outputChunks.push(chunk);
    });
    child.stderr.on('data', (chunk) => { if (diagnostic.length < 4096) diagnostic += chunk.toString(); });
    child.stdin.on('error', () => {});
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
    child.once('close', (code) => {
      clearTimeout(timeout);
      if (failed) { reject(failed); return; }
      let result;
      try { result = JSON.parse(outputChunks.join('')); } catch { reject(new Error(`Suite save transaction failed${diagnostic.trim() ? `: ${diagnostic.trim()}` : ''}`)); return; }
      if (code !== 0 || result.error) reject(new Error(result.error || 'Suite save transaction failed'));
      else accept(result.suite);
    });
    child.stdin.end(JSON.stringify({ root: store.root, saved, expectedRevision, operation, projectId, expectedRecordRevision, kind }));
  });
}
