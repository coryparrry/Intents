import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, symlink, writeFile, truncate } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { Store, CatalogLimitError } from '../server/store.mjs';
import { MAX_OUTPUT_BYTES } from '../server/validation.mjs';
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'catalog-recovery-'));
  const app = new EvaluationApp({ dataDir: root, resolveBinary: async () => { throw Error('Unexpected native invocation'); } });
  await app.init();
  t.after(async () => { await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  return { root, app };
}
const definition = (name = 'Recovery case') => ({ name, version: 'v1', scoringMode: 'review', cases: [{ id: randomUUID(), name: 'Case', prompt: 'Read the evidence', expected: '' }] });

test('valid public suite growth survives restart and supports bounded export, deletion and complete recovery', { timeout: 120000 }, async (t) => {
  const { root, app } = await fixture(t);
  const preserved = new Map(); let aggregate = 0;
  for (let index = 0; index < 40 && aggregate <= MAX_OUTPUT_BYTES; index++) {
    const source = definition(`Large suite ${index}`);
    source.cases = Array.from({ length: 60 }, (_, position) => ({ id: randomUUID(), name: `Case ${position}`, prompt: 'x'.repeat(15000), expected: '' }));
    const { suite } = await app.call('eval_save_suite', { suite: source });
    const bytes = await readFile(app.store.path('suites', suite.id));
    assert.ok(bytes.length < 1024 * 1024);
    aggregate += bytes.length; preserved.set(suite.id, hash(bytes));
  }
  assert.ok(aggregate > MAX_OUTPUT_BYTES);
  await app.shutdown();
  const reopened = new EvaluationApp({ dataDir: root });
  t.after(() => reopened.shutdown()); await reopened.init();
  const workspace = await reopened.call('eval_open_workspace');
  assert.equal(workspace.page, 'catalogRecovery');
  assert.match(workspace.message, /32 MiB/);
  assert.ok(Buffer.byteLength(JSON.stringify(workspace)) < 32768);
  const records = []; let cursor = '0';
  do {
    const response = await reopened.call('eval_catalog_recovery', { kind: 'suites', cursor, limit: 7 });
    assert.ok(response.catalogRecovery.records.length <= 7);
    assert.ok(Buffer.byteLength(JSON.stringify(response)) < 32768);
    records.push(...response.catalogRecovery.records); cursor = response.catalogRecovery.nextCursor;
    assert.equal(response.catalogRecovery.totalRecords, preserved.size + 1);
  } while (cursor !== null);
  assert.equal(new Set(records.map((record) => record.id)).size, preserved.size + 1);
  const target = records.find((record) => preserved.has(record.id));
  const chunks = []; let offset = 0;
  do {
    const chunk = await reopened.call('eval_catalog_export_chunk', { kind: 'suites', recordId: target.id, recordRevision: target.recordRevision, offset, bytes: 65536 });
    const bytes = Buffer.from(chunk.dataBase64, 'base64'); assert.ok(bytes.length <= 65536);
    chunks.push(bytes); offset = chunk.nextOffset;
  } while (offset !== null);
  assert.deepEqual(Buffer.concat(chunks), await readFile(reopened.store.path('suites', target.id)));
  for (const record of records.filter((record) => preserved.has(record.id)).slice(0, 3)) {
    assert.equal((await reopened.call('eval_catalog_remove', { kind: 'suites', recordId: record.id, recordRevision: record.recordRevision, confirm: true })).deleted, true);
    preserved.delete(record.id);
  }
  const recovered = await reopened.call('eval_open_workspace');
  assert.equal(recovered.page, 'workspace'); assert.equal(recovered.suites.length, preserved.size + 1);
  for (const [key, digest] of preserved) assert.equal(hash(await readFile(reopened.store.path('suites', key))), digest);
});

test('recovery requires confirmation and current exact record bytes; ordinary APIs keep their shape', async (t) => {
  const { app } = await fixture(t);
  const { suite } = await app.call('eval_save_suite', { suite: definition() });
  assert.ok(Array.isArray((await app.call('eval_list_suites')).suites));
  const page = await app.call('eval_catalog_recovery', { kind: 'suites', limit: 50 });
  const record = page.catalogRecovery.records.find((record) => record.id === suite.id);
  await assert.rejects(app.call('eval_catalog_remove', { kind: 'suites', recordId: suite.id, recordRevision: record.recordRevision, confirm: false }), /confirmation/);
  await app.call('eval_save_suite', { suite: { ...suite, name: 'Changed after inspection' }, expectedRevision: suite.revision });
  for (const name of ['eval_catalog_remove', 'eval_catalog_export_chunk']) await assert.rejects(app.call(name, { kind: 'suites', recordId: suite.id, recordRevision: record.recordRevision, ...(name.endsWith('remove') ? { confirm: true } : {}) }), /Record changed/);
  await assert.rejects(app.call('eval_catalog_recovery', { kind: 'suites', cursor: '../' }), /Invalid catalog recovery/);
  assert.equal((await app.store.read('suites', suite.id)).name, 'Changed after inspection');
});

test('bounded startup scans retain per-record, returned-payload and symlink guards', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'catalog-guards-')); t.after(() => rm(root, { recursive: true, force: true }));
  const store = new Store(root); await store.init();
  const key = randomUUID(), target = join(root, 'outside.json'); await writeFile(target, JSON.stringify({ id: key }));
  await symlink(target, store.path('suites', key));
  await assert.rejects(store.readRecord('suites', key), /Invalid stored record/);
  await rm(store.path('suites', key)); await writeFile(store.path('suites', key), ''); await truncate(store.path('suites', key), MAX_OUTPUT_BYTES + 1);
  await assert.rejects(store.readRecord('suites', key), /Invalid stored record/);
  await assert.rejects(async () => { for await (const record of store.scan('suites')) void record; }, /Invalid stored record/);
  // The returned aggregate limit remains enforced rather than silently truncating.
  await rm(store.path('suites', key)); await store.write('suites', { id: key, name: 'bounded' });
  await assert.rejects(store.list('suites', () => 'x'.repeat(MAX_OUTPUT_BYTES)), CatalogLimitError);
});

test('a concurrent normal write between recovery preflight and deletion cannot delete newer non-suite evidence', async (t) => {
  const { root, app } = await fixture(t);
  const key = randomUUID();
  await app.store.write('runs', { id: key, name: 'Original evidence', status: 'completed' });
  const response = await app.call('eval_catalog_recovery', { kind: 'runs' });
  const record = response.catalogRecovery.records.find((item) => item.id === key);
  let entered, resume;
  const enteredDelete = new Promise((resolve) => { entered = resolve; });
  const resumeDelete = new Promise((resolve) => { resume = resolve; });
  const remove = app.store.delete.bind(app.store);
  app.store.delete = async (...args) => { entered(); await resumeDelete; return remove(...args); };
  const deleting = app.call('eval_catalog_remove', { kind: 'runs', recordId: key, recordRevision: record.recordRevision, confirm: true });
  const outcome = assert.rejects(deleting, /Record changed/);
  try {
    await enteredDelete;
    // Store.write itself executes in a distinct kernel-locked worker process.
    const writer = new Store(root);
    await writer.write('runs', { id: key, name: 'Acknowledged newer evidence', status: 'completed' });
    resume(); await outcome;
    assert.equal((await writer.read('runs', key)).name, 'Acknowledged newer evidence');
    const fresh = (await app.call('eval_catalog_recovery', { kind: 'runs' })).catalogRecovery.records.find((item) => item.id === key);
    app.store.delete = remove;
    assert.equal((await app.call('eval_catalog_remove', { kind: 'runs', recordId: key, recordRevision: fresh.recordRevision, confirm: true })).deleted, true);
  } finally { resume(); app.store.delete = remove; await Promise.allSettled([deleting, outcome]); }
});
