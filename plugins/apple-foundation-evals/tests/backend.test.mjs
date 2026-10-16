import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, chmod, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { EvaluationApp } from '../server/app.mjs';
import { Store, processAlive } from '../server/store.mjs';
import { suite, MAX_REQUEST_BYTES } from '../server/validation.mjs';
import { TOOLS, UI_URI } from '../server/catalog.mjs';
import { nativeBinary } from '../scripts/launch.mjs';

const sample = { name: 'Regression', instructions: 'Be concise', cases: [{ id: 'one', prompt: 'apple', expected: 'apple', scoring: 'exact' }, { id: 'two', prompt: 'banana', scoring: 'none' }], repetitions: 1, maxTokens: 64, temperature: 0 };
const mock = `#!/usr/bin/env node
let input='';process.stdin.on('data',x=>input+=x);process.stdin.on('end',()=>{
const request=JSON.parse(input);const mode=process.argv[1].split('/').pop();
if(request.operation==='availability'){console.log(JSON.stringify({available:true,model:'Mock on-device model',osVersion:'26.0'}));return;}
if(mode==='slow'){setTimeout(()=>{},10000);return;}
if(mode==='crash'){process.exit(9);return;}
if(mode==='bad'){console.log('not json');return;}
const results=[];for(let rep=1;rep<=request.repetitions;rep++)for(const item of request.cases)results.push({caseId:item.id,repetition:rep,prompt:item.prompt,expected:item.expected,response:item.prompt,passed:item.scoring==='none'?null:true,score:item.scoring==='none'?null:1,durationMs:3,trace:{transcript:[{role:'user',content:item.prompt},{role:'assistant',content:item.prompt}]}});
console.log(JSON.stringify({status:'completed',model:'Mock on-device model',startedAt:new Date().toISOString(),finishedAt:new Date().toISOString(),durationMs:10,results}));});`;
async function fixture(t, mode = 'normal', options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'foundation-evals-test-'));
  const binary = join(directory, mode);
  await writeFile(binary, mock);
  await chmod(binary, 0o700);
  const dataDir = join(directory, 'data');
  const app = new EvaluationApp({ dataDir, env: { FOUNDATION_EVALS_NATIVE_BINARY: binary }, ...options });
  await app.init();
  t.after(async () => { await app.shutdown(); await rm(directory, { recursive: true, force: true }); });
  return { app, directory, binary, dataDir };
}
async function completed(app, runId) {
  for (let attempt = 0; attempt < 300; attempt++) {
    const { run } = await app.call('eval_get_run', { runId });
    if (run.status !== 'running') return run;
    await new Promise((accept) => setTimeout(accept, 10));
  }
  throw new Error('Run did not finish');
}
async function saved(app) { return (await app.call('eval_save_suite', { suite: sample })).suite; }

test('workspace and catalog remain local, do not compile, and advertise precise entrypoints', async (t) => {
  let resolutions = 0;
  const { app } = await fixture(t, 'normal', { resolveBinary: async () => { resolutions++; throw new Error('should not run'); } });
  const workspace = await app.call('eval_open_workspace');
  assert.equal(workspace.page, 'workspace');
  assert.equal(workspace.model.available, null);
  assert.equal(workspace.suites.length, 1);
  assert.equal(workspace.runs.length, 0);
  assert.equal(resolutions, 0);
  const tool = TOOLS.find((item) => item.name === 'eval_open_workspace');
  assert.equal(tool._meta.ui.resourceUri, UI_URI);
  assert.deepEqual(tool._meta['openai/ui'].entrypoints, [{ type: 'global' }, { type: 'thread' }]);
  assert(TOOLS.every((item) => item.annotations.openWorldHint === false));
  assert(!TOOLS.some((item) => /intent|provider/.test(item.name)));
  await assert.rejects(app.call('intents_list_projects'), /Unknown tool/);
});
test('suite save, update, delete, and disk persistence use UUID identities', async (t) => {
  const { app, dataDir } = await fixture(t);
  const first = await saved(app);
  const { suite: updated } = await app.call('eval_save_suite', { suite: { ...first, name: 'Renamed' } });
  assert.equal(updated.id, first.id);
  const reopened = new Store(dataDir);
  assert.equal((await reopened.read('suites', first.id)).name, 'Renamed');
  await app.call('eval_delete_suite', { suiteId: first.id });
  await assert.rejects(reopened.read('suites', first.id), /not found/);
  await assert.rejects(app.call('eval_get_run', { runId: '../secret' }), /UUID/);
});
test('invalid suites and expanded workloads are rejected before writing', async (t) => {
  const { app } = await fixture(t);
  for (const invalid of [
    { ...sample, provider: 'remote' }, { ...sample, maxTokens: 0 }, { ...sample, temperature: 3 },
    { ...sample, repetitions: 11 }, { ...sample, cases: [] },
    { ...sample, cases: [sample.cases[0], sample.cases[0]] },
    { ...sample, cases: [{ ...sample.cases[0], expected: '' }] },
    { ...sample, cases: [{ ...sample.cases[0], prompt: 'x'.repeat(8193) }] },
    { ...sample, cases: Array.from({ length: 11 }, (_, index) => ({ ...sample.cases[0], id: String(index) })), repetitions: 10 },
    { ...sample, repetitions: 10, maxTokens: 4096 },
    { ...sample, instructions: '😀'.repeat(5000) },
    { ...sample, cases: [{ ...sample.cases[0], id: '😀'.repeat(100) }] },
    { ...sample, instructions: 'x'.repeat(16384), cases: Array.from({ length: 32 }, (_, index) => ({ ...sample.cases[0], id: String(index) })) },
  ]) await assert.rejects(app.call('eval_save_suite', { suite: invalid }));
  assert.equal(suite(sample, randomUUID).repetitions, 1);
});
test('availability invokes the native worker only when requested', async (t) => {
  const { app } = await fixture(t);
  assert.deepEqual(await app.call('eval_model_status'), { available: true, model: 'Mock on-device model', osVersion: '26.0' });
});
test('real worker responses, scores, trace, and snapshot persist and compare', async (t) => {
  const { app, dataDir } = await fixture(t);
  const savedSuite = await saved(app);
  const first = (await app.call('eval_start_run', { suiteId: savedSuite.id })).run;
  assert.equal(first.status, 'running');
  assert.equal(first.results.length, 0);
  assert.equal('ownerPid' in first, false);
  const run = await completed(app, first.id);
  assert.equal(run.status, 'completed');
  assert.equal(run.results[0].passed, true);
  assert.equal(run.results[1].passed, null);
  assert.equal(run.results[0].trace.transcript.length, 2);
  assert.equal((await new Store(dataDir).read('runs', run.id)).results[0].response, 'apple');
  const second = (await app.call('eval_start_run', { suiteId: savedSuite.id })).run;
  await completed(app, second.id);
  const compare = await app.call('eval_compare_runs', { runIds: [run.id, second.id] });
  assert.equal(compare.cases.length, 2);
  assert.equal(compare.cases[0].results.length, 2);
  const ids=[run.id, second.id];
  for(let index=0; index<2; index++){const next=(await app.call('eval_start_run',{suiteId:savedSuite.id})).run;await completed(app,next.id);ids.push(next.id);}
  for(const count of [3,4]){const comparison=await app.call('eval_compare_runs',{runIds:ids.slice(0,count)});assert.equal(comparison.runs.length,count);assert.equal(comparison.cases[0].results.length,count);}
  await assert.rejects(app.call('eval_compare_runs',{runIds:[run.id,run.id]}), /unique|duplicate|different/i);
  await app.call('eval_delete_suite', { suiteId: savedSuite.id });
  assert.equal((await app.call('eval_get_run', { runId: run.id })).run.suite.name, 'Regression');
  const trace = await app.resource('foundation-evals://runs/' + run.id);
  assert.equal(JSON.parse(trace.contents[0].text).results.length, 2);
  await app.call('eval_delete_run', { runId: second.id });
  await assert.rejects(app.call('eval_get_run', { runId: second.id }), /not found/);
});
test('a published terminal run permits immediate restart after releasing its worker lease', async (t) => {
  const { app } = await fixture(t);
  const item = await saved(app);
  const write = app.store.write.bind(app.store);
  let resumePersistence;
  const persistence = new Promise((accept) => { resumePersistence = accept; });
  let paused = false;
  app.store.write = async (kind, value) => {
    await write(kind, value);
    if (kind === 'runs' && value.status !== 'running' && !paused) {
      paused = true;
      await persistence;
    }
  };
  try {
    const first = (await app.call('eval_start_run', { suiteId: item.id })).run;
    assert.equal((await completed(app, first.id)).status, 'completed');
    assert.equal(app.store.leases.size, 0, 'terminal state must follow release of the worker lease');
    const start = app.start.bind(app);
    let enteredRestart;
    const restartEntered = new Promise((accept) => { enteredRestart = accept; });
    app.start = (...args) => { const next = start(...args); enteredRestart(); return next; };
    const next = app.call('eval_start_run', { suiteId: item.id });
    next.catch(() => {});
    await restartEntered;
    resumePersistence();
    const second = (await next).run;
    assert.notEqual(second.id, first.id);
    assert.equal((await completed(app, second.id)).status, 'completed');
  } finally { resumePersistence(); }
});
test('one active run, cancellation, cross-server exclusion, and availability avoid concurrent inference', async (t) => {
  const { app, dataDir, binary } = await fixture(t, 'slow');
  const savedSuite = await saved(app);
  const { run } = await app.call('eval_start_run', { suiteId: savedSuite.id });
  await assert.rejects(app.call('eval_start_run', { suiteId: savedSuite.id }), /already active/);
  await assert.rejects(app.call('eval_delete_run', { runId: run.id }), /Cancel/);
  assert.match((await app.call('eval_model_status')).reason, /active/);
  const other = new EvaluationApp({ dataDir, env: { FOUNDATION_EVALS_NATIVE_BINARY: binary } });
  await other.init();
  t.after(() => other.shutdown());
  await assert.rejects(other.call('eval_start_run', { suiteId: savedSuite.id }), /already active/);
  await other.shutdown();
  assert.equal((await app.call('eval_cancel_run', { runId: run.id })).run.status, 'cancelled');
  assert.equal((await app.call('eval_list_runs')).runs[0].status, 'cancelled');
});
for (const mode of ['bad', 'crash']) test(`native ${mode} output becomes durable failed run`, async (t) => {
  const { app } = await fixture(t, mode);
  const item = await saved(app);
  const { run } = await app.call('eval_start_run', { suiteId: item.id });
  const result = await completed(app, run.id);
  assert.equal(result.status, 'failed');
  assert(result.error);
});
test('native timeout and shutdown persist terminal state', async (t) => {
  const { app } = await fixture(t, 'slow', { timeoutMs: 40 });
  const item = await saved(app);
  const { run } = await app.call('eval_start_run', { suiteId: item.id });
  assert.match((await completed(app, run.id)).error, /time limit/);
  const second = (await app.call('eval_start_run', { suiteId: item.id })).run;
  await app.shutdown();
  assert.equal((await app.store.read('runs', second.id)).status, 'cancelled');
});
test('interrupted run recovery does not invent case results', async (t) => {
  const { app } = await fixture(t);
  const item = await saved(app);
  const runId = randomUUID();
  await app.store.write('runs', { id: runId, suiteId: item.id, suite: item, status: 'running', startedAt: new Date().toISOString(), ownerPid: 2147483647, results: [] });
  const { runs } = await app.call('eval_list_runs');
  assert.equal(runs[0].status, 'failed');
  assert.equal(runs[0].totalResults, 0);
});
test('file entrypoint uses host resource reference without filesystem access', async (t) => {
  const { app } = await fixture(t);
  const file = { name: 'export.afevaltrace', resourceUri: 'host-resource://export' };
  assert.deepEqual(await app.call('eval_open_trace', { file }), { page: 'trace', file });
  assert.deepEqual(TOOLS.find((item) => item.name === 'eval_open_trace')._meta['openai/ui'].entrypoints, [{ type: 'file', extensions: ['.afevaltrace'] }]);
  await assert.rejects(app.call('eval_open_trace', { file: { ...file, path: '/etc/passwd' } }), /Unknown field/);
  await assert.rejects(app.resource('file:///etc/passwd'), /Unknown resource/);
  await assert.rejects(app.resource('foundation-evals://runs/../../secret'), /Unknown resource/);
  const resource = (await app.resource(UI_URI)).contents[0];
  assert.equal(resource.mimeType, 'text/html;profile=mcp-app');
  assert.match(resource.text, /<!doctype html>/i);
  assert.deepEqual(resource._meta.ui.csp, { connectDomains: [], resourceDomains: [] });
  assert.equal(resource._meta['openai/ui'].preferredDisplayMode, 'fullscreen');
});
test('native unavailable errors retain their message and details', async (t) => {
  const { app } = await fixture(t, 'normal', { invoke: async () => ({ status: 'failed', model: 'Apple Foundation Models', durationMs: 1, results: [], error: { kind: 'modelUnavailable', message: 'Enable Apple Intelligence' } }) });
  const item = await saved(app);
  const { run } = await app.call('eval_start_run', { suiteId: item.id });
  const final = await completed(app, run.id);
  assert.equal(final.error, 'Enable Apple Intelligence');
  assert.equal(final.errorDetails.kind, 'modelUnavailable');
});
test('invalid native case identities and incomplete completion cannot masquerade as successful runs', async (t) => {
  const { app } = await fixture(t, 'normal', { invoke: async () => ({ status: 'completed', results: [] }) });
  const item = await saved(app);
  const { run } = await app.call('eval_start_run', { suiteId: item.id });
  const final = await completed(app, run.id);
  assert.equal(final.status, 'failed');
  assert.match(final.error, /without all case results/);
});
test('symlinked stores and records cannot expose other files', async (t) => {
  const { app, directory } = await fixture(t);
  const key = randomUUID();
  const outside = join(directory, 'outside.json');
  await writeFile(outside, JSON.stringify({ id: key, secret: true }));
  await symlink(outside, app.store.path('runs', key));
  await assert.rejects(app.store.read('runs', key), /Invalid stored record/);
  const link = join(directory, 'linked');
  await symlink(app.store.root, link);
  await assert.rejects(new Store(link).init(), /symlink/);
});
test('native resolver accepts explicit executable override without compiling', async (t) => {
  const { binary, directory } = await fixture(t);
  assert.equal(await nativeBinary({ dataDir: directory, env: { FOUNDATION_EVALS_NATIVE_BINARY: binary } }), binary);
});
test('stdio protocol accepts host metadata while rejecting unknown methods, fields and malformed input', async (t) => {
  const { directory, binary } = await fixture(t);
  const child = spawn(process.execPath, [fileURLToPath(new URL('../server/main.mjs', import.meta.url))], { cwd: directory, env: { ...process.env, FOUNDATION_EVALS_PLUGIN_DATA: join(directory, 'stdio'), FOUNDATION_EVALS_NATIVE_BINARY: binary }, stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '', errors = '';
  child.stdout.on('data', (chunk) => output += chunk);
  child.stderr.on('data', (chunk) => errors += chunk);
  const input = [
    '{malformed',
    JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2026-07-28', capabilities: {}, clientInfo: { name: 'test', version: '1' } } }),
    JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
    JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'server/discover' }),
    JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'intents/projects' }),
    JSON.stringify({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'intents_list_projects' } }),
    JSON.stringify({ jsonrpc: '2.0', id: 5, method: 'resources/read', params: { uri: 'file:///etc/passwd' } }),
    ...['ping', 'tools/list', 'resources/list', 'resources/templates/list'].map((method, index) => JSON.stringify({ jsonrpc: '2.0', id: 6 + index, method, params: { _meta: { progressToken: 'host-discovery', 'openai/ui': { entrypoint: 'global' } } } })),
    JSON.stringify({ jsonrpc: '2.0', id: 10, method: 'tools/list', params: { _meta: [] } }),
    JSON.stringify({ jsonrpc: '2.0', id: 11, method: 'resources/list', params: { _meta: {}, unexpected: true } }),
    JSON.stringify({ jsonrpc: '2.0', id: 12, method: 'tools/call', params: { _meta: { progressToken: 'workspace' }, name: 'eval_open_workspace', arguments: {} } }),
  ].join('\n') + '\n';
  child.stdin.end(input);
  const code = await new Promise((accept) => child.once('close', accept));
  assert.equal(code, 0, errors);
  const responses = output.trim().split('\n').map((line) => JSON.parse(line));
  assert.equal(responses.find((item) => item.id === 1).result.protocolVersion, '2026-07-28');
  assert.equal(responses.find((item) => item.id === 2).result.resultType, 'complete');
  assert.equal(responses.find((item) => item.id === 3).error.code, -32601);
  assert.equal(responses.find((item) => item.id === 4).result.isError, true);
  assert.equal(responses.find((item) => item.id === 5).error.code, -32602);
  for (let id = 6; id <= 9; id++) assert.ok(responses.find(item => item.id === id).result, `Host metadata rejected for request ${id}`);
  assert.ok(responses.find(item => item.id === 7).result.tools.some(tool => tool.name === 'eval_open_workspace'));
  assert.ok(responses.find(item => item.id === 8).result.resources.some(resource => resource.uri === UI_URI));
  assert.equal(responses.find(item => item.id === 10).error.code, -32602);
  assert.equal(responses.find(item => item.id === 11).error.code, -32602);
  assert.equal(responses.find(item => item.id === 12).result.structuredContent.suites.length, 1);
  assert(responses.some((item) => item.error?.code === -32700));
});

function processLines(child) {
  const received = [], waiting = [];
  createInterface({ input: child.stdout }).on('line', (line) => {
    received.push(line);
    for (const waiter of [...waiting]) if (received.length >= waiter.count) { waiting.splice(waiting.indexOf(waiter), 1); waiter.accept(received[waiter.count - 1]); }
  });
  return (count) => received.length >= count ? Promise.resolve(received[count - 1]) : new Promise((accept) => waiting.push({ count, accept }));
}
test('simultaneous independent processes elect exactly one owner with stale lock contents', { timeout: 30000 }, async (t) => {
  const { dataDir } = await fixture(t);
  const storeURL = new URL('../server/store.mjs', import.meta.url).href;
  const helper = `import { Store } from ${JSON.stringify(storeURL)}; import { createInterface } from 'node:readline';
    const store=new Store(process.env.TEST_STORE);await store.init();let held=false;
    const lines=createInterface({input:process.stdin});
    lines.on('line',async command=>{if(command==='acquire'){try{await store.acquireRunLock('trial');held=true;console.log('owned');}catch{console.log('denied');process.exit(0);}}
    if(command==='release'){await store.releaseRunLock('trial');held=false;process.exit(0);}});
    lines.on('close',async()=>{if(held)await store.releaseRunLock('trial');process.exit(0);});console.log('ready');`;
  for (let trial = 0; trial < 3; trial++) {
    await writeFile(join(dataDir, 'active-run.lock'), JSON.stringify({ pid: 2147483647, runId: randomUUID() }));
    const contenders = Array.from({ length: 8 }, () => {
      const child = spawn(process.execPath, ['--input-type=module', '-e', helper], { env: { ...process.env, TEST_STORE: dataDir }, stdio: ['pipe', 'pipe', 'pipe'] });
      const lines = processLines(child);
      const closed = new Promise((accept) => child.once('close', accept));
      t.after(async () => { child.stdin.end(); await closed; });
      return { child, lines, closed };
    });
    assert((await Promise.all(contenders.map((item) => item.lines(1)))).every((line) => line === 'ready'));
    for (const item of contenders) item.child.stdin.write('acquire\n');
    const ownership = await Promise.all(contenders.map((item) => item.lines(2)));
    assert.equal(ownership.filter((result) => result === 'owned').length, 1, `trial ${trial}: ${ownership}`);
    contenders[ownership.indexOf('owned')].child.stdin.end('release\n');
    await Promise.all(contenders.map((item) => item.closed));
  }
});

function stdioClient(dataDir, binary) {
  const child = spawn(process.execPath, [fileURLToPath(new URL('../server/main.mjs', import.meta.url))], { env: { ...process.env, FOUNDATION_EVALS_PLUGIN_DATA: dataDir, FOUNDATION_EVALS_NATIVE_BINARY: binary }, stdio: ['pipe', 'pipe', 'pipe'] });
  const calls = new Map(); let nextId = 0;
  const closed = new Promise((accept) => child.once('close', accept));
  createInterface({ input: child.stdout }).on('line', (line) => {
    const response = JSON.parse(line); const call = calls.get(response.id);
    if (call) { calls.delete(response.id); call(response); }
  });
  return { child, closed, call(name, args = {}) {
    const requestId = ++nextId;
    return new Promise((accept) => {
      calls.set(requestId, accept);
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: requestId, method: 'tools/call', params: { name, arguments: args } }) + '\n');
    });
  } };
}
test('abrupt server death kills and reaps its live native child before another inference starts', { timeout: 15000 }, async (t) => {
  const { directory, dataDir } = await fixture(t);
  const marker = join(directory, 'native-starts.jsonl');
  const binary = join(directory, 'live-native');
  await writeFile(binary, `#!/usr/bin/env node\nconst fs=require('node:fs');let input='';process.stdin.on('data',x=>input+=x);process.stdin.on('end',()=>{const request=JSON.parse(input);if(request.operation==='availability'){console.log(JSON.stringify({available:true}));return;}fs.appendFileSync(${JSON.stringify(marker)},JSON.stringify({pid:process.pid})+'\\n');setInterval(()=>{},10000);});`);
  await chmod(binary, 0o700);
  const first = stdioClient(dataDir, binary);
  t.after(async () => { first.child.stdin.end(); if (first.child.exitCode === null) first.child.kill(); await first.closed; });
  const suites = (await first.call('eval_list_suites')).result.structuredContent.suites;
  const started = await first.call('eval_start_run', { suiteId: suites[0].id });
  assert.equal(started.result.structuredContent.run.status, 'running');
  let initialPid;
  for (let attempt = 0; attempt < 300 && !initialPid; attempt++) {
    try { initialPid = JSON.parse((await readFile(marker, 'utf8')).trim().split('\n')[0]).pid; } catch {}
    if (!initialPid) await new Promise((accept) => setTimeout(accept, 10));
  }
  assert(initialPid && processAlive(initialPid));
  first.child.kill('SIGKILL'); await first.closed;
  const second = stdioClient(dataDir, binary);
  t.after(async () => { second.child.stdin.end(); await second.closed; });
  let next;
  for (let attempt = 0; attempt < 100; attempt++) {
    next = await second.call('eval_start_run', { suiteId: suites[0].id });
    if (!next.result.isError) break;
    assert.match(next.result.content[0].text, /already active/);
    await new Promise((accept) => setTimeout(accept, 10));
  }
  assert.equal(next.result.isError, undefined);
  assert.equal(processAlive(initialPid), false, 'The original native child must be gone before a new run is accepted');
  const runId = next.result.structuredContent.run.id;
  const cancelled = await second.call('eval_cancel_run', { runId });
  assert.equal(cancelled.result.structuredContent.run.status, 'cancelled');
  const recovered = await second.call('eval_get_run', { runId: started.result.structuredContent.run.id });
  assert.equal(recovered.result.structuredContent.run.status, 'failed');
});

test('stdio rejects requests beyond the bounded base64 envelope and resumes at the next line', async (t) => {
  const { directory } = await fixture(t);
  const child = spawn(process.execPath, [fileURLToPath(new URL('../server/main.mjs', import.meta.url))], { cwd: directory, env: { ...process.env, FOUNDATION_EVALS_PLUGIN_DATA: join(directory, 'large-stdio') }, stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '', errors = ''; child.stdout.on('data', (chunk) => output += chunk); child.stderr.on('data', (chunk) => errors += chunk);
  const oversized = JSON.stringify({ jsonrpc: '2.0', id: 'oversized', method: 'ping', params: { _meta: { oversized: 'x'.repeat(MAX_REQUEST_BYTES) } } });
  child.stdin.end(oversized + '\n' + JSON.stringify({ jsonrpc: '2.0', id: 'after-limit', method: 'ping' }) + '\n');
  const code = await new Promise((accept) => child.once('close', accept)); assert.equal(code, 0, errors);
  const responses = output.trim().split('\n').map((line) => JSON.parse(line)); assert.equal(responses.length, 2); assert.equal(responses[0].error.code, -32600); assert.match(responses[0].error.message, /65 MiB/); assert.deepEqual(responses[1], { jsonrpc: '2.0', id: 'after-limit', result: {} });
});
