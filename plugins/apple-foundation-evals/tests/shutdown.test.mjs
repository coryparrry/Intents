import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, readFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { Store, processAlive } from '../server/store.mjs';

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function bounded(promise, description, milliseconds = 5000) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out: ${description}`)), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}
async function marker(path) {
  for (let attempt = 0; attempt < 300; attempt++) {
    try { return JSON.parse(await readFile(path, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    await delay(10);
  }
  throw new Error(`Timed out waiting for ${path}`);
}
async function server(t) {
  const directory = await mkdtemp(join(tmpdir(), 'eval-stdio-shutdown-'));
  const binary = join(directory, 'native');
  const started = join(directory, 'started.json');
  const stopping = join(directory, 'stopping.json');
  const launches = join(directory, 'launches.jsonl');
  await writeFile(binary, `#!${process.execPath}
const fs = require('node:fs');
let input = '';
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  JSON.parse(input);
  const keepAlive = setInterval(() => {}, 1000);
  process.once('SIGTERM', () => {
    fs.writeFileSync(${JSON.stringify(stopping)}, JSON.stringify({ pid: process.pid }));
    setTimeout(() => { clearInterval(keepAlive); process.exit(0); }, 400);
  });
  fs.appendFileSync(${JSON.stringify(launches)}, JSON.stringify({ pid: process.pid }) + '\\n');
  fs.writeFileSync(${JSON.stringify(started)}, JSON.stringify({ pid: process.pid }));
});
`);
  await chmod(binary, 0o700);
  const dataDir = join(directory, 'data');
  const child = spawn(process.execPath, [fileURLToPath(new URL('../server/main.mjs', import.meta.url))], {
    env: { ...process.env, FOUNDATION_EVALS_PLUGIN_DATA: dataDir, FOUNDATION_EVALS_NATIVE_BINARY: binary },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let errors = '', nativePid, nextId = 0;
  const responses = [], calls = new Map();
  child.stderr.on('data', chunk => errors += chunk);
  child.stdin.on('error', () => {});
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => {
    const response = JSON.parse(line); responses.push(response);
    calls.get(response.id)?.(response); calls.delete(response.id);
  });
  const closed = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal, nativeAlive: nativePid ? processAlive(nativePid) : false }));
  });
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    await bounded(closed, 'server cleanup');
    if (nativePid && processAlive(nativePid)) {
      process.kill(nativePid, 'SIGKILL');
      for (let attempt = 0; attempt < 300 && processAlive(nativePid); attempt++) await delay(10);
    }
    lines.close();
    await rm(directory, { recursive: true, force: true });
  });
  return {
    child, closed, responses, started, stopping, launches, dataDir,
    setNativePid(pid) { nativePid = pid; },
    call(name, args = {}) {
      const id = ++nextId;
      const response = new Promise(resolve => calls.set(id, resolve));
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } }) + '\n');
      return response;
    },
    errors: () => errors,
  };
}

for (const mode of ['EOF', 'SIGTERM', 'repeated signals']) {
  test(`stdio ${mode} cancels an active preview and releases its worker lease before exit`, { timeout: 12000 }, async t => {
    const client = await server(t);
    const workspace = await bounded(client.call('eval_open_workspace'), 'workspace');
    const preview = client.call('eval_preview_response', { suite: workspace.result.structuredContent.suites[0], prompt: 'Synthetic shutdown fixture' });
    const { pid } = await marker(client.started); client.setNativePid(pid);
    assert.equal(processAlive(pid), true);
    const queued = client.call('eval_preview_response', { suite: workspace.result.structuredContent.suites[0], prompt: 'Must never launch during shutdown' });
    const accepted = client.call('eval_open_workspace');
    // The bypass control proves earlier input has been admitted while the preview owns the queue.
    await bounded(client.call('eval_preview_status'), 'queued input admission');
    if (mode === 'EOF') client.child.stdin.end(); else client.child.kill('SIGTERM');
    await marker(client.stopping);
    if (mode === 'repeated signals') {
      client.child.kill('SIGTERM');
      await delay(30);
      client.child.kill('SIGINT');
    }
    const exit = await bounded(client.closed, 'preview cancellation and server exit');
    assert.equal(exit.code, 0, client.errors());
    assert.equal(exit.nativeAlive, false, 'Server exit must wait for native worker termination');
    assert.equal(processAlive(pid), false);
    const result = await bounded(preview, 'preview terminal response');
    assert.equal(result.result.isError, true);
    assert.match(result.result.content[0].text, /cancel/i);
    assert.equal((await bounded(queued, 'queued preview cancellation')).result.isError, true);
    assert.equal((await bounded(accepted, 'accepted ordinary request')).result.structuredContent.page, 'workspace');
    assert.equal((await readFile(client.launches, 'utf8')).trim().split('\n').length, 1, 'Queued preview must not start a second worker');
    const store = new Store(client.dataDir);
    await store.init();
    const leaseId = 'shutdown-reacquire';
    await bounded(store.acquireRunLock(leaseId), 'released inference lease');
    await store.releaseRunLock(leaseId);
  });
}

test('stdio EOF drains accepted tools including a final unterminated input line', { timeout: 10000 }, async t => {
  const client = await server(t);
  const first = client.call('eval_open_workspace');
  client.child.stdin.end(JSON.stringify({ jsonrpc: '2.0', id: 'final', method: 'tools/call', params: { name: 'eval_open_workspace', arguments: {} } }));
  const exit = await bounded(client.closed, 'final input drain');
  assert.equal(exit.code, 0, client.errors());
  assert.equal((await bounded(first, 'accepted workspace')).result.isError, undefined);
  const final = client.responses.find(response => response.id === 'final');
  assert.equal(final?.result.isError, undefined);
  assert.equal(final?.result.structuredContent.page, 'workspace');
});
