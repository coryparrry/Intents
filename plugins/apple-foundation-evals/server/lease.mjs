import { spawn } from 'node:child_process';
import { lstat, open } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { StringDecoder } from 'node:string_decoder';
import { MAX_OUTPUT_BYTES } from './validation.mjs';
import { constants } from 'node:fs';

/** The kernel lock is held by a guardian that owns inference children, including after server death. */
export async function acquireLease(root) {
  const path = join(root, 'active-run.lock');
  const handle = await open(path, constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
  await handle.close();
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Invalid active-run lock');
  const helper = fileURLToPath(new URL('./lease-guardian.mjs', import.meta.url));
  const executable = process.platform === 'darwin' ? '/usr/bin/lockf' : '/usr/bin/flock';
  const args = process.platform === 'darwin' ? ['-n', '-k', '-s', '-t', '0', path, process.execPath, helper] : ['-n', path, process.execPath, helper];
  const child = spawn(executable, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  const decoder = new StringDecoder('utf8');
  let buffer = '', diagnostic = '', ready = false, nextId = 0, pending;
  let resolveReady, rejectReady, resolveClosed;
  const closed = new Promise((accept) => { resolveClosed = accept; });
  const acquired = new Promise((accept, reject) => { resolveReady = accept; rejectReady = reject; });
  /** Writes one newline-delimited command to the lock-owning guardian. */
  const send = (value) => child.stdin.write(JSON.stringify(value) + '\n');
  const lease = {
    guardianPid: null, nativePid: null,
    /** Admits one native request through the guardian, forwards progress, and converts signal aborts into cancellation commands. */
    async invoke(binary, input, { signal, timeoutMs, onEvent } = {}) {
      if (pending) throw new Error('An evaluation is already active');
      if (signal?.aborted) throw new Error('Evaluation cancelled');
      const requestId = ++nextId;
      /** Requests cancellation of this invocation without ending the guardian's lock ownership. */
      const abort = () => send({ kind: 'cancel', requestId });
      return new Promise((accept, reject) => {
        pending = { requestId, accept, reject, onEvent, /** Detaches this request's abort listener after completion or guardian failure. */ cleanup: () => signal?.removeEventListener('abort', abort) };
        signal?.addEventListener('abort', abort, { once: true });
        send({ kind: 'invoke', requestId, binary, input, timeoutMs });
      });
    },
    /** Closes command input and waits for guardian exit, including any active worker cleanup. */
    async release() { child.stdin.end(); await closed; },
  };
  child.stdin.on('error', () => {});
  child.stderr.on('data', (chunk) => { if (diagnostic.length < 4096) diagnostic += chunk.toString(); });
  child.stdout.on('data', (chunk) => {
    buffer += decoder.write(chunk);
    if (Buffer.byteLength(buffer) > MAX_OUTPUT_BYTES) { child.stdin.end(); return; }
    let boundary;
    while ((boundary = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, boundary); buffer = buffer.slice(boundary + 1);
      let message;
      try { message = JSON.parse(line); } catch { child.stdin.end(); continue; }
      if (message.kind === 'ready') { ready = true; lease.guardianPid = message.pid; resolveReady(lease); }
      if (message.kind === 'native') lease.nativePid = message.pid;
      if (message.kind === 'event' && pending?.requestId === message.requestId) pending.onEvent?.(message.event);
      if (message.kind === 'result' && pending?.requestId === message.requestId) {
        const operation = pending; pending = null; lease.nativePid = null; operation.cleanup();
        if (message.error) operation.reject(new Error(message.error)); else operation.accept(message.result);
      }
    }
  });
  child.once('error', (error) => { rejectReady(error); });
  child.once('close', () => {
    if (!ready) rejectReady(new Error('An evaluation is already active' + (diagnostic.trim() ? `: ${diagnostic.trim()}` : '')));
    if (pending) { pending.cleanup(); pending.reject(new Error('Native guardian exited before completion')); pending = null; }
    resolveClosed();
  });
  return acquired;
}
