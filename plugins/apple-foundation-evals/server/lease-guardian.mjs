import { createInterface } from 'node:readline';
import { invokeNative } from './runtime.mjs';
import { MAX_REQUEST_BYTES } from './validation.mjs';

let active = null, closing = false;
/** Writes one guardian protocol message unless shutdown has already begun. */
const send = (value) => { if (!closing) process.stdout.write(JSON.stringify(value) + '\n'); };
/** Aborts and reaps the active native invocation before exiting so the kernel lock outlives its worker. */
async function close() {
  if (closing) return;
  closing = true;
  if (active) { active.controller.abort(); await active.done; }
  // The native child has exited and been reaped before the OS lock holder exits.
  process.exit(0);
}
process.stdout.on('error', () => { close().catch(() => process.exit(1)); });
process.stdin.on('error', () => { close().catch(() => process.exit(1)); });
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on('line', (line) => {
  if (closing) return;
  if (Buffer.byteLength(line) > MAX_REQUEST_BYTES + 8192) { close().catch(() => process.exit(1)); return; }
  let message;
  try { message = JSON.parse(line); } catch { close().catch(() => process.exit(1)); return; }
  if (message.kind === 'cancel' && active?.requestId === message.requestId) { active.controller.abort(); return; }
  if (message.kind !== 'invoke' || active) return;
  const controller = new AbortController();
  active = { controller, requestId: message.requestId, done: null };
  active.done = invokeNative(message.binary, message.input, { signal: controller.signal, timeoutMs: message.timeoutMs, /** Forwards native progress with its request identity to the lease owner. */ onEvent: (event) => send({ kind: 'event', requestId: message.requestId, event }), /** Reports the native worker PID while the guardian retains process and lock ownership. */ onSpawn: (pid) => send({ kind: 'native', pid }) })
    .then((result) => send({ kind: 'result', requestId: message.requestId, result }), (error) => send({ kind: 'result', requestId: message.requestId, error: error.message }))
    .finally(() => { active = null; });
});
lines.on('close', () => { close().catch(() => process.exit(1)); });
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { close().catch(() => process.exit(1)); });
send({ kind: 'ready', pid: process.pid });
