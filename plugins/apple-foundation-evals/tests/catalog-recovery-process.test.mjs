import test from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';

async function server(root) {
  const child = fork(fileURLToPath(new URL('./helpers/catalog-recovery-server.mjs', import.meta.url)), [root], { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
  let nextId = 0;
  const pending = new Map();
  const ready = once(child, 'message');
  child.on('message', (message) => {
    const request = pending.get(message.requestId);
    if (!request) return;
    pending.delete(message.requestId);
    if (message.error) request.reject(Error(message.error)); else request.resolve(message.result);
  });
  const request = (command, args) => new Promise((resolve, reject) => {
    const requestId = ++nextId; pending.set(requestId, { resolve, reject }); child.send({ requestId, command, args });
  });
  const close = async () => { if (child.connected) await request('shutdown'); child.kill(); };
  assert.equal((await ready)[0].ready, true);
  return { child, request, close, call: (name, args) => request('call', { name, arguments: args }) };
}

test('recovery cannot delete active cross-process evidence even after a concurrent public decision saves a stale failed status', { timeout: 20000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'recovery-process-'));
  const app = new EvaluationApp({ dataDir: root }); await app.init();
  const servers = [];
  t.after(async () => { for (const server of servers) await server.close(); await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'Cross-process experiment', scoringMode: 'review', cases: [{ id: randomUUID(), prompt: 'fruit', expected: '' }] } });
  const runner = await server(root); servers.push(runner);
  const decider = await server(root); servers.push(decider);
  const created = await runner.call('eval_create_experiment', { suiteId: suite.id, name: 'Compare instructions', candidateInstructions: 'Answer briefly' });
  const key = created.experiment.id;
  await runner.call('eval_run_experiment', { experimentId: key });
  await runner.request('finishNative');
  assert.equal((await app.store.read('experiments', key)).status, 'failed');
  const decisionRead = once(decider.child, 'message').then(([message]) => assert.equal(message.event, 'decisionRead'));
  const decision = decider.request('pauseDecision', { experimentId: key });
  await decisionRead;
  const active = await runner.call('eval_run_experiment', { experimentId: key });
  assert.equal(active.experiment.status, 'running');
  assert.equal((await app.call('eval_catalog_recovery', { kind: 'experiments' })).catalogRecovery.records.find((record) => record.id === key).canRemove, false);
  await decider.request('resumeDecision'); await decision;
  // These bytes were saved by the public decision API, not injected into the store.
  assert.equal((await app.store.read('experiments', key)).status, 'failed');
  const record = (await app.call('eval_catalog_recovery', { kind: 'experiments' })).catalogRecovery.records.find((record) => record.id === key);
  assert.equal(record.canRemove, true, 'the stale saved status alone permits removal');
  const before = await readFile(app.store.path('experiments', key));
  await assert.rejects(app.call('eval_catalog_remove', { kind: 'experiments', recordId: key, recordRevision: record.recordRevision, confirm: true }), /already active/);
  assert.deepEqual(await readFile(app.store.path('experiments', key)), before);
  assert.equal(app.store.leases.size, 0, 'rejected acquisition retains no lease');
  const chunk = await app.call('eval_catalog_export_chunk', { kind: 'experiments', recordId: key, recordRevision: record.recordRevision });
  assert.deepEqual(Buffer.from(chunk.dataBase64, 'base64'), before, 'export stays available during native execution');
  await runner.request('finishNative');
  const terminal = (await app.call('eval_catalog_recovery', { kind: 'experiments' })).catalogRecovery.records.find((record) => record.id === key);
  await assert.rejects(app.call('eval_catalog_remove', { kind: 'experiments', recordId: key, recordRevision: record.recordRevision, confirm: true }), /Record changed/);
  assert.equal(app.store.leases.size, 0, 'validation failure releases the lease');
  assert.equal((await app.call('eval_catalog_remove', { kind: 'experiments', recordId: key, recordRevision: terminal.recordRevision, confirm: true })).deleted, true);
  assert.equal(app.store.leases.size, 0, 'successful deletion releases the lease');
  const probe = randomUUID(); await app.store.acquireRunLock(probe); await app.store.releaseRunLock(probe);
});

test('recovery holds the inference lease through deletion and releases it after storage failure', { timeout: 20000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'recovery-admission-'));
  const app = new EvaluationApp({ dataDir: root }); await app.init();
  let runner, resume;
  t.after(async () => { resume?.(); await runner?.close(); await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'Admission lock', scoringMode: 'review', cases: [{ id: randomUUID(), prompt: 'fruit', expected: '' }] } });
  runner = await server(root);
  const { experiment } = await runner.call('eval_create_experiment', { suiteId: suite.id, name: 'Compare', candidateInstructions: 'Answer briefly' });
  const record = (await app.call('eval_catalog_recovery', { kind: 'suites' })).catalogRecovery.records.find((record) => record.id === suite.id);
  let entered;
  const inDelete = new Promise((resolve) => { entered = resolve; });
  const continueDelete = new Promise((resolve) => { resume = resolve; });
  const remove = app.store.delete.bind(app.store);
  app.store.delete = async () => { entered(); await continueDelete; throw Error('Controlled storage failure'); };
  const deleting = app.call('eval_catalog_remove', { kind: 'suites', recordId: suite.id, recordRevision: record.recordRevision, confirm: true });
  const rejected = assert.rejects(deleting, /Controlled storage failure/);
  await inDelete;
  await assert.rejects(runner.call('eval_run_experiment', { experimentId: experiment.id }), /already active/);
  assert.equal((await app.store.read('experiments', experiment.id)).status, 'ready');
  resume(); await rejected; app.store.delete = remove;
  assert.equal(app.store.leases.size, 0);
  assert.equal((await app.store.read('suites', suite.id)).revision, suite.revision);
  assert.equal((await runner.call('eval_run_experiment', { experimentId: experiment.id })).experiment.status, 'running');
  await runner.request('finishNative');
});

test('recovery retains staged paired-run bytes until terminal experiment publication commits', { timeout: 20000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'recovery-publication-'));
  const app = new EvaluationApp({ dataDir: root }); await app.init();
  let runner;
  t.after(async () => { await runner?.close(); await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'Paired publication', scoringMode: 'review', cases: [{ id: randomUUID(), name: 'Fruit', prompt: 'fruit', expected: '' }] } });
  runner = await server(root);
  const { experiment } = await runner.call('eval_create_experiment', { suiteId: suite.id, name: 'Compare', candidateInstructions: 'Answer briefly' });
  await runner.call('eval_run_experiment', { experimentId: experiment.id });
  await runner.request('pausePublication');
  const staged = once(runner.child, 'message');
  const finishing = runner.request('finishNative', { success: true });
  const [event] = await staged; assert.equal(event.event, 'variantStaged');
  const record = (await app.call('eval_catalog_recovery', { kind: 'runs' })).catalogRecovery.records.find((record) => record.id === event.runId);
  const bytes = await readFile(app.store.path('runs', record.id));
  assert.equal(JSON.parse(bytes).publicationState, 'pending');
  assert.equal(record.canRemove, false);
  // Inference has ended, so only the publication guard protects the saved variant.
  const probe = randomUUID(); await app.store.acquireRunLock(probe); await app.store.releaseRunLock(probe);
  await assert.rejects(app.call('eval_catalog_remove', { kind: 'runs', recordId: record.id, recordRevision: record.recordRevision, confirm: true }), /not been committed/);
  assert.equal(app.store.leases.size, 0);
  assert.deepEqual(await readFile(app.store.path('runs', record.id)), bytes);
  const chunk = await app.call('eval_catalog_export_chunk', { kind: 'runs', recordId: record.id, recordRevision: record.recordRevision });
  assert.deepEqual(Buffer.from(chunk.dataBase64, 'base64'), bytes);
  await runner.request('resumePublication'); await finishing;
  const completed = await app.call('eval_get_experiment', { experimentId: experiment.id });
  assert.equal(completed.experiment.status, 'completed'); assert.equal(completed.runs.length, 2); assert.deepEqual(completed.missingRunIds, []);
  assert.equal((await app.call('eval_catalog_remove', { kind: 'runs', recordId: record.id, recordRevision: record.recordRevision, confirm: true })).deleted, true);
});

test('legacy nonpending orphan runs remain explicitly removable while missing-parent pending evidence stays exportable', { timeout: 20000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'recovery-orphan-'));
  const app = new EvaluationApp({ dataDir: root }); await app.init();
  t.after(async () => { await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  const suite = (await app.call('eval_list_suites')).suites[0];
  const source = { id: randomUUID(), suite, suiteId: suite.id, experimentId: randomUUID(), status: 'failed', startedAt: '2026-10-20T12:00:00Z', finishedAt: '2026-10-20T12:00:01Z', results: [] };
  const { run: legacy } = await app.call('eval_import_run', { run: source });
  const { run: pending } = await app.call('eval_import_run', { run: { ...source, id: randomUUID(), publicationState: 'pending' } });
  const records = (await app.call('eval_catalog_recovery', { kind: 'runs' })).catalogRecovery.records;
  const oldRecord = records.find((record) => record.id === legacy.id), pendingRecord = records.find((record) => record.id === pending.id);
  assert.equal(oldRecord.canRemove, true); assert.equal(pendingRecord.canRemove, false);
  await assert.rejects(app.call('eval_catalog_remove', { kind: 'runs', recordId: pending.id, recordRevision: pendingRecord.recordRevision, confirm: true }), /Export the saved bytes.*reopen/);
  const chunk = await app.call('eval_catalog_export_chunk', { kind: 'runs', recordId: pending.id, recordRevision: pendingRecord.recordRevision });
  assert.deepEqual(Buffer.from(chunk.dataBase64, 'base64'), await readFile(app.store.path('runs', pending.id)));
  assert.equal((await app.call('eval_catalog_remove', { kind: 'runs', recordId: legacy.id, recordRevision: oldRecord.recordRevision, confirm: true })).deleted, true);
  assert.equal(app.store.leases.size, 0);
});
