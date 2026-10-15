import { spawn } from 'node:child_process';
import { MAX_NATIVE_OUTPUT_BYTES } from './validation.mjs';
import { StringDecoder } from 'node:string_decoder';

export function invokeNative(binary, input, { signal, timeoutMs = 1800000, lease, onSpawn, onEvent } = {}) {
  if (lease) return lease.invoke(binary, input, { signal, timeoutMs, onEvent });
  return new Promise((accept, reject) => {
    if (signal?.aborted) return reject(new Error('Evaluation cancelled'));
    const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    if (child.pid) onSpawn?.(child.pid);
    let size = 0, output = '', stderr = '', failure, cancelled = false, graceTimer;
    const appEvaluation = ['evaluate', 'run-experiment'].includes(input.operation) && !!input.suite;
    const decoder = new StringDecoder('utf8');
    const eventDecoder = new StringDecoder('utf8'); let eventBuffer = '';
    const eventLine = (line) => {
      if (Buffer.byteLength(line) > MAX_NATIVE_OUTPUT_BYTES) { stop('Native event exceeded its size limit'); return; }
      try { const value = JSON.parse(line); if (value && ['sample', 'liveResponse'].includes(value.event)) { onEvent?.(value); return; } } catch {}
      if (stderr.length < 4096) stderr += line.slice(0, 4096 - stderr.length);
    };
    const stop = (message) => { failure ??= new Error(message); child.kill('SIGKILL'); };
    const abort = () => {
      if (!appEvaluation) { stop('Evaluation cancelled'); return; }
      cancelled = true; child.kill('SIGTERM');
      graceTimer = setTimeout(() => stop('Evaluation cancelled'), 3000);
    };
    signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(() => stop('Native evaluation exceeded its time limit'), timeoutMs);
    child.stdout.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_NATIVE_OUTPUT_BYTES) stop('Native output exceeded its size limit');
      else output += decoder.write(chunk);
    });
    child.stderr.on('data', (chunk) => {
      if (!appEvaluation || !input.emitEvents) { if (stderr.length < 4096) stderr += chunk.toString('utf8'); return; }
      eventBuffer += eventDecoder.write(chunk);
      let boundary; while ((boundary = eventBuffer.indexOf('\n')) >= 0) { eventLine(eventBuffer.slice(0, boundary)); eventBuffer = eventBuffer.slice(boundary + 1); }
      if (Buffer.byteLength(eventBuffer) > MAX_NATIVE_OUTPUT_BYTES) stop('Native event exceeded its size limit');
    });
    child.stdin.on('error', () => {});
    child.once('error', (error) => { failure ??= error; });
    child.once('close', (code) => {
      clearTimeout(timer); clearTimeout(graceTimer);
      signal?.removeEventListener('abort', abort);
      output += decoder.end();
      eventBuffer += eventDecoder.end(); if (eventBuffer) eventLine(eventBuffer);
      if (failure) return reject(failure);
      if (cancelled && code !== 0) return reject(new Error('Evaluation cancelled'));
      if (code !== 0) return reject(new Error(`Native worker exited with status ${code}${stderr.trim() ? ': ' + stderr.trim() : ''}`));
      try {
        const value = JSON.parse(output);
        if (cancelled && !['completed', 'cancelled', 'failed'].includes(value.status) && !(input.operation === 'run-experiment' && Array.isArray(value.current?.results) && Array.isArray(value.candidate?.results))) return reject(new Error('Evaluation cancelled'));
        accept(value);
      } catch { reject(new Error(cancelled ? 'Evaluation cancelled' : 'Native worker returned invalid JSON')); }
    });
    child.stdin.end(JSON.stringify(input));
  });
}
