import { EvaluationApp } from './app.mjs';
import { TOOLS, UI_URI, UI_MIME, UI_META, SERVER_INFO, CAPABILITIES } from './catalog.mjs';
import { MAX_REQUEST_BYTES, only, object } from './validation.mjs';

const versions = ['2026-07-28', '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const app = new EvaluationApp();
await app.init();
let pending = Buffer.alloc(0), discarding = false, ending = false;
const tasks = new Set();
let shutdownPromise;
/** Writes one newline-delimited JSON-RPC response to the MCP transport. */
const send = (message) => process.stdout.write(JSON.stringify(message) + '\n');
/** Sends a JSON-RPC error associated with the request identity, or null for transport errors. */
const error = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

/** Validates and dispatches a JSON-RPC request; notifications receive no response and tool failures become MCP error content. */
async function request(message) {
  const requestId = message?.id;
  const hasId = Object.hasOwn(message || {}, 'id');
  if (!message || typeof message !== 'object' || Array.isArray(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string' || (hasId && typeof requestId !== 'string' && typeof requestId !== 'number' && requestId !== null)) {
    error(null, -32600, 'Invalid JSON-RPC request'); return;
  }
  if (!hasId) return; // Client notifications have no response.
  try {
    const params = message.params ?? {};
    object(params, 'params');
    if (params._meta !== undefined) object(params._meta, '_meta');
    let result;
    switch (message.method) {
      case 'initialize':
        result = { protocolVersion: versions.includes(params.protocolVersion) ? params.protocolVersion : '2025-11-25', capabilities: CAPABILITIES, serverInfo: SERVER_INFO, instructions: 'Evaluate only the local Apple Foundation Models system model. Saved suites and real runs are local. Projects organize local suites and real evidence. App Intents and remote model providers are excluded.' };
        break;
      case 'server/discover':
        result = { resultType: 'complete', supportedVersions: versions, _meta: { 'io.modelcontextprotocol/serverInfo': SERVER_INFO }, capabilities: CAPABILITIES };
        break;
      case 'ping': only(params, ['_meta']); result = {}; break;
      case 'tools/list': only(params, ['cursor', '_meta']); if (params.cursor) throw new Error('Invalid cursor'); result = { tools: TOOLS }; break;
      case 'tools/call': {
        only(params, ['name', 'arguments', '_meta']);
        try {
          const structuredContent = await app.call(params.name, params.arguments ?? {});
          result = { content: [{ type: 'text', text: JSON.stringify(structuredContent) }], structuredContent };
        } catch (failure) { result = { isError: true, content: [{ type: 'text', text: failure.message }] }; }
        break;
      }
      case 'resources/list':
        only(params, ['cursor', '_meta']);
        if (params.cursor) throw new Error('Invalid cursor');
        result = { resources: [{ uri: UI_URI, name: 'evaluation-workspace', title: 'Evaluation Workspace', mimeType: UI_MIME, _meta: UI_META }, ...(await app.runs()).map((run) => ({ uri: `foundation-evals://runs/${run.id}`, name: run.id, title: `${run.suiteName} — ${run.status}`, mimeType: 'application/json' }))] };
        break;
      case 'resources/templates/list': only(params, ['cursor', '_meta']); if (params.cursor) throw new Error('Invalid cursor'); result = { resourceTemplates: [{ uriTemplate: 'foundation-evals://runs/{runId}', name: 'evaluation-run', title: 'Saved evaluation trace', mimeType: 'application/json' }] }; break;
      case 'resources/read': only(params, ['uri', '_meta']); if (typeof params.uri !== 'string') throw new Error('uri must be a string'); result = await app.resource(params.uri); break;
      default: error(requestId, -32601, 'Method not found'); return;
    }
    send({ jsonrpc: '2.0', id: requestId, result });
  } catch (failure) { error(requestId, -32602, failure.message); }
}
/** Parses one bounded nonblank request line and tracks its asynchronous dispatch for shutdown draining. */
function line(buffer) {
  if (!buffer.toString('utf8').trim()) return;
  if (buffer.length > MAX_REQUEST_BYTES) { error(null, -32600, 'Request exceeds 65 MiB limit'); return; }
  let message;
  try { message = JSON.parse(buffer.toString('utf8')); } catch { error(null, -32700, 'Parse error'); return; }
  const task = request(message).catch((failure) => { process.stderr.write(`Request failed: ${failure.message}\n`); }).finally(() => tasks.delete(task));
  tasks.add(task);
}
process.stdin.on('data', (chunk) => {
  if (ending) return;
  for (const part of chunk.toString('binary').split('\n').entries()) {
    const [index, segment] = part;
    if (index > 0) {
      if (!discarding) line(pending);
      pending = Buffer.alloc(0); discarding = false;
    }
    if (!discarding) {
      pending = Buffer.concat([pending, Buffer.from(segment, 'binary')]);
      if (pending.length > MAX_REQUEST_BYTES) { pending = Buffer.alloc(0); discarding = true; error(null, -32600, 'Request exceeds 65 MiB limit'); }
    }
  }
});
/** Memoizes transport shutdown, admits a final buffered request, and waits for all request tasks and app cleanup before pausing input. */
function shutdown() {
  if (shutdownPromise) return shutdownPromise;
  ending = true;
  if (pending.length && !discarding) line(pending);
  pending = Buffer.alloc(0);
  shutdownPromise = (async () => {
    const closing = app.shutdown();
    await Promise.allSettled([...tasks, closing]);
    await closing;
    process.stdin.pause();
  })();
  return shutdownPromise;
}
process.stdin.on('end', () => { shutdown().catch((failure) => { process.stderr.write(`${failure.message}\n`); process.exitCode = 1; }); });
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { shutdown().then(() => process.exit(0), () => process.exit(1)); });
