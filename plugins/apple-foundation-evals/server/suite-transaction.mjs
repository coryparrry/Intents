import { spawn } from 'node:child_process';
import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { id } from './validation.mjs';
import { MAX_OUTPUT_BYTES } from './validation.mjs';

// These lock files are permanent: unlinking one could create two independent locks.
// The kernel releases the lock on process death; no PID/mtime stale-lock guessing.
export async function saveSuiteTransaction(store, saved, expectedRevision, { operation = 'save', projectId } = {}) {
  const lockPath = join(store.root, '.suite-locks', `${id(saved.id)}.lock`);
  const handle = await open(lockPath, constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
  try { if (!(await handle.stat()).isFile()) throw new Error('Invalid suite transaction lock'); }
  finally { await handle.close(); }
  const worker = fileURLToPath(new URL('./suite-transaction-worker.mjs', import.meta.url));
  const executable = process.platform === 'darwin' ? '/usr/bin/lockf' : '/usr/bin/flock';
  const arguments_ = process.platform === 'darwin'
    ? ['-k', '-s', '-t', '5', lockPath, process.execPath, worker]
    : ['-w', '5', lockPath, process.execPath, worker];
  const child = spawn(executable, arguments_, { detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
  child.stdout.setEncoding('utf8');
  return new Promise((accept, reject) => {
    let output = '', diagnostic = '', failed;
    const stop = (message) => {
      failed ||= new Error(message);
      try { process.kill(-child.pid, 'SIGKILL'); } catch { /* Already exited. */ }
    };
    // Acquisition and execution have independent bounds. The entire process group
    // is stopped before rejecting, so an expired writer cannot commit afterwards.
    const timeout = setTimeout(() => stop('Suite save transaction timed out'), 15000);
    child.stdout.on('data', (chunk) => {
      output += chunk.toString();
      if (Buffer.byteLength(output) > MAX_OUTPUT_BYTES + 1024) stop('Suite transaction output exceeds limit');
    });
    child.stderr.on('data', (chunk) => { if (diagnostic.length < 4096) diagnostic += chunk.toString(); });
    child.stdin.on('error', () => {});
    child.once('error', (error) => { clearTimeout(timeout); reject(error); });
    child.once('close', (code) => {
      clearTimeout(timeout);
      if (failed) { reject(failed); return; }
      let result;
      try { result = JSON.parse(output); } catch { reject(new Error(`Suite save transaction failed${diagnostic.trim() ? `: ${diagnostic.trim()}` : ''}`)); return; }
      if (code !== 0 || result.error) reject(new Error(result.error || 'Suite save transaction failed'));
      else accept(result.suite);
    });
    child.stdin.end(JSON.stringify({ root: store.root, saved, expectedRevision, operation, projectId }));
  });
}
