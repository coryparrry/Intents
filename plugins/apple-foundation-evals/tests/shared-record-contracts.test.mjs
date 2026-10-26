import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { EvaluationApp, summary } from '../server/app.mjs';
import { publicRecord } from '../server/app-format.mjs';
import { Store } from '../server/store.mjs';

const evidence = {
  id: '00000000-0000-4000-8000-000000000010', ownerPid: 42,
  revision: 'stored-revision', updatedAt: '2026-10-26T12:00:00Z',
  projectId: '00000000-0000-4000-8000-000000000020',
  startedAt: 'historical-invalid-date', finishedAt: 813000000,
  status: 'completed', results: [{ response: 'apple', trace: { ownerPid: 7 } }],
};
const evidenceRevision = '4691a9e7ce864a2ea15b7a43f1c4d24cbc5eef8b18b89a6b6dee544354998244';

/** Creates an isolated initialized record store and removes its files after the test. */
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'shared-record-contract-'));
  const store = new Store(root);
  await store.init();
  t.after(() => rm(root, { recursive: true, force: true }));
  return store;
}

test('public records preserve evidence and replace stored revisions without exposing process ownership', () => {
  const original = structuredClone(evidence);
  const projected = publicRecord(evidence);
  const { ownerPid, ...expected } = evidence;
  assert.deepEqual(projected, { ...expected, revision: evidenceRevision });
  assert.deepEqual(evidence, original);
  assert.equal(projected.results[0].trace.ownerPid, 7, 'only top-level ownership is private');
  assert.equal(projected.startedAt, 'historical-invalid-date');
  assert.equal(projected.finishedAt, 813000000);
});

test('public revisions retain the established metadata exclusions and evidence field set', async (t) => {
  const cases = [
    { name: 'owner process', change: { ownerPid: 999 }, stable: true },
    { name: 'stored revision', change: { revision: 'replacement' }, stable: true },
    { name: 'update timestamp', change: { updatedAt: 'invalid-update-time' }, stable: true },
    { name: 'project ownership', change: { projectId: randomUUID() }, stable: true },
    { name: 'start timestamp', change: { startedAt: '2026-10-26T00:00:00Z' }, stable: false },
    { name: 'finish timestamp', change: { finishedAt: 813000001 }, stable: false },
    { name: 'status', change: { status: 'failed' }, stable: false },
    { name: 'nested ownership evidence', change: { results: [{ response: 'apple', trace: { ownerPid: 8 } }] }, stable: false },
    { name: 'result content', change: { results: [{ response: 'pear', trace: { ownerPid: 7 } }] }, stable: false },
  ];
  for (const { name, change, stable } of cases) await t.test(name, () => {
    const projected = publicRecord({ ...evidence, ...change });
    assert.equal(projected.revision === evidenceRevision, stable);
    assert.equal(Object.hasOwn(projected, 'ownerPid'), false);
    for (const [key, value] of Object.entries(change)) if (!['ownerPid', 'revision'].includes(key)) assert.deepEqual(projected[key], value);
  });
  const reordered = Object.fromEntries(Object.entries(evidence).reverse());
  assert.equal(publicRecord(reordered).revision, evidenceRevision);
  const { ownerPid, ...unowned } = evidence;
  assert.equal(publicRecord(unowned).revision, evidenceRevision);
});

for (const kind of ['runs', 'experiments']) test(`${kind} public revisions remain valid across process changes and reject stale evidence writes`, async (t) => {
  const store = await fixture(t);
  await store.write(kind, evidence);
  await store.write(kind, { ...evidence, ownerPid: 999 });
  const changed = { ...evidence, ownerPid: 999, status: 'failed' };
  await store.write(kind, changed, { expectedRevision: evidenceRevision });
  await assert.rejects(store.write(kind, { ...changed, status: 'cancelled' }, { expectedRevision: evidenceRevision }), /Revision conflict: reload the current evidence before changing it/);
  assert.deepEqual(await store.read(kind, evidence.id), changed);
});

test('optional reads return existing evidence and null for missing records in each catalog', async (t) => {
  const store = await fixture(t);
  for (const kind of ['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections']) await t.test(kind, async () => {
    assert.equal(await store.readOptional(kind, evidence.id), null);
    await writeFile(store.path(kind, evidence.id), JSON.stringify(evidence));
    assert.deepEqual(await store.readOptional(kind, evidence.id), evidence);
  });
});

test('optional reads preserve corrupt JSON and invalid stored-record failures', async (t) => {
  const store = await fixture(t);
  for (const { name, contents, message } of [
    { name: 'corrupt JSON', contents: '{', message: /JSON|property name/i },
    { name: 'identity mismatch', contents: JSON.stringify({ id: randomUUID() }), message: /Stored record id mismatch/ },
  ]) await t.test(name, async () => {
    await writeFile(store.path('runs', evidence.id), contents);
    await assert.rejects(store.readOptional('runs', evidence.id), message);
  });
  const directoryId = randomUUID();
  await mkdir(store.path('runs', directoryId));
  await assert.rejects(store.readOptional('runs', directoryId), /Invalid stored record/);
  await assert.rejects(store.readOptional('runs', 'invalid-id'), /UUID/);
  await assert.rejects(store.readOptional('unknown', evidence.id), /Unknown store/);
});

test('optional reads suppress only the established not-found message suffix and propagate other read errors unchanged', async (t) => {
  const store = await fixture(t);
  const cases = [
    { name: 'permission failure', message: 'Permission denied', code: 'EACCES', missing: false },
    { name: 'read I/O failure', message: 'Input/output error', code: 'EIO', missing: false },
    { name: 'file disappears during read', message: 'File disappeared during read', code: 'ENOENT', missing: false },
    { name: 'not-found text without suffix', message: 'Run not found; recovery failed', missing: false },
    { name: 'not-found suffix', message: 'Run not found', missing: true },
  ];
  for (const { name, message, code, missing } of cases) await t.test(name, async (child) => {
    const failure = Object.assign(new Error(message), { code });
    const read = child.mock.method(store, 'read', async () => { throw failure; });
    if (missing) assert.equal(await store.readOptional('runs', evidence.id), null);
    else await assert.rejects(store.readOptional('runs', evidence.id), (error) => error === failure);
    assert.deepEqual(read.mock.calls[0].arguments, ['runs', evidence.id]);
  });
});

test('run and workflow APIs share public revisions while public readers retain experiment publication checks', async (t) => {
  const store = await fixture(t);
  const app = new EvaluationApp({ dataDir: store.root });
  t.after(() => app.shutdown());
  const source = { id: randomUUID(), name: 'Public evidence', cases: [{ id: 'one' }], repetitions: 1 };
  const experimentId = randomUUID();
  const run = { ...evidence, suiteId: source.id, suite: source, experimentId };
  const experiment = { id: experimentId, ownerPid: 42, status: 'ready', createdAt: '2026-10-26T12:00:00Z', experiment: { runIDs: [run.id] } };
  await store.write('suites', source);
  await store.write('runs', run);
  await store.write('experiments', experiment);
  await store.write('baselines', { id: randomUUID(), suiteId: source.id, runID: run.id, approvedAt: '2026-10-26T12:00:00Z' });
  for (const [name, args] of [
    ['eval_get_run', { runId: run.id }],
    ['eval_export_run', { runId: run.id }],
    ['eval_get_baseline', { suiteId: source.id }],
  ]) await assert.rejects(app.call(name, args), /Paired experiment evidence has not been committed/, name);
  await store.write('experiments', { ...experiment, status: 'completed' });
  const { run: published } = await app.call('eval_get_run', { runId: run.id });
  const baseline = await app.call('eval_get_baseline', { suiteId: source.id });
  const paired = await app.call('eval_get_experiment', { experimentId });
  assert.equal(published.revision, publicRecord(run).revision);
  assert.equal(summary(run).revision, published.revision);
  assert.deepEqual(baseline.run, publicRecord(run));
  assert.deepEqual(paired.runs, [publicRecord(run)]);
  const listed = await app.call('eval_list_experiments', {});
  assert.deepEqual(listed.experiments, [publicRecord({ ...experiment, status: 'completed' })]);
  assert.equal(Object.hasOwn(published, 'ownerPid'), false);
  const exported = await app.call('eval_export_run', { runId: run.id });
  assert.equal(exported.run.revision, evidence.revision, 'exported evidence retains its stored revision');
  assert.equal(exported.run.startedAt, evidence.startedAt);
  assert.equal(exported.run.finishedAt, evidence.finishedAt);
});
