import { spawn } from 'node:child_process';

/** Keep build ownership until the compiler and its output streams have closed. */
export function runBuildCommand(command, args, { signal, timeoutMs = 180000 } = {}) {
  if (signal?.aborted) return Promise.reject(new Error('Native build cancelled'));
  return new Promise((accept, reject) => {
    const grouped = process.platform !== 'win32';
    const child = spawn(command, args, { stdio: ['ignore', 'ignore', 'pipe'], detached: grouped });
    let diagnostics = '', failure, graceTimer;
    const terminate = (signal) => {
      if (!grouped || !child.pid) { child.kill(signal); return; }
      try { process.kill(-child.pid, signal); }
      catch (error) { if (error.code !== 'ESRCH') failure ??= error; }
    };
    child.stderr.on('data', (chunk) => {
      if (diagnostics.length < 16384) diagnostics += chunk.toString().slice(0, 16384 - diagnostics.length);
    });
    const timer = setTimeout(() => {
      failure ??= new Error('Native build exceeded its time limit');
      terminate('SIGKILL');
    }, timeoutMs);
    const abort = () => {
      failure ??= Object.assign(new Error('Native build cancelled', { cause: signal?.reason }),
        { name: 'AbortError', code: 'ABORT_ERR' });
      terminate('SIGTERM');
      graceTimer ??= setTimeout(() => terminate('SIGKILL'), 3000);
    };
    // The driver can exit while subprocesses still own stderr. Keep cancellation
    // attached until close, including that drain window.
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    child.once('error', (error) => { failure ??= error; });
    child.once('close', (code) => {
      clearTimeout(timer); clearTimeout(graceTimer);
      signal?.removeEventListener('abort', abort);
      if (failure) reject(failure);
      else if (code === 0) accept();
      else {
        if (diagnostics) process.stderr.write(diagnostics);
        reject(new Error('Native runner could not compile. Install Xcode 27 or newer and select its command line tools.'));
      }
    });
  });
}
