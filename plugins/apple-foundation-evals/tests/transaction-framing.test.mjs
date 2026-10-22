import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Store } from '../server/store.mjs';
import { EvaluationApp } from '../server/app.mjs';
import { MAX_OUTPUT_BYTES } from '../server/validation.mjs';

const jsonBytes = value => Buffer.byteLength(JSON.stringify(value));
// Exercise quote/backslash/control escaping and multibyte UTF-8 together.
// Stream limits must count bytes correctly even when pipe chunks split Unicode.
const escapedUnit = '\0\\"é😃';
const escapedUnitBytes = jsonBytes(escapedUnit) - 2;
function fillToSize(value, setPayload, bytes) {
  setPayload('');
  const remaining = bytes - jsonBytes(value);
  assert.ok(remaining >= 0);
  setPayload(escapedUnit.repeat(Math.floor(remaining / escapedUnitBytes)) + 'x'.repeat(remaining % escapedUnitBytes));
  assert.equal(jsonBytes(value), bytes);
  return value;
}
async function directory(t) {
  const root = await mkdtemp(join(tmpdir(), 'transaction-framing-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}
async function appFixture(t) {
  const app = new EvaluationApp({ dataDir: await directory(t), invoke: async () => { throw Error('Unexpected inference'); } });
  await app.init();
  t.after(() => app.shutdown());
  const { suite } = await app.call('eval_save_suite', { suite: {
    name: 'Escaped run import', cases: [{ id: 'case-one', prompt: 'fruit', expected: 'apple', scoring: 'exact' }],
  } });
  const run = { id: randomUUID(), suiteId: suite.id, suite, projectId: app.defaultProjectId,
    suiteRevision: suite.revision, status: 'completed', startedAt: '2026-10-20T12:00:00.000Z',
    finishedAt: '2026-10-20T12:00:01.000Z', results: [{ caseId: 'case-one', repetition: 1,
      prompt: 'fruit', expected: 'apple', response: 'apple', passed: true, score: 1, durationMs: 1,
      trace: { transcript: [{ role: 'assistant', content: '' }] } }] };
  return { app, run, setPayload: value => { run.results[0].trace.transcript[0].content = value; } };
}

test('an exactly 32 MiB heavily escaped record crosses locked request and response framing once', { timeout: 30000 }, async (t) => {
  const store = new Store(await directory(t)); await store.init();
  const record = { id: randomUUID(), payload: '' };
  fillToSize(record, value => { record.payload = value; }, MAX_OUTPUT_BYTES);
  const metadata = { root: store.root, saved: null, operation: 'writeRecord', kind: 'runs' };
  const framingBytes = jsonBytes(metadata) - jsonBytes(null);
  assert.equal(jsonBytes({ ...metadata, saved: record }), MAX_OUTPUT_BYTES + framingBytes);
  assert.ok(framingBytes < 4096);
  assert.equal(jsonBytes({ suite: record }), MAX_OUTPUT_BYTES + 10);
  await store.write('runs', record);
  assert.equal((await readFile(store.path('runs', record.id))).length, MAX_OUTPUT_BYTES);
  assert.deepEqual(await store.read('runs', record.id), record);
  // A rejected replacement must leave the acknowledged boundary-size record intact.
  await assert.rejects(store.write('runs', { ...record, payload: record.payload + 'x' }), /Record exceeds local storage limit/);
  assert.equal((await readFile(store.path('runs', record.id))).length, MAX_OUTPUT_BYTES);
});

test('public import preserves near-limit escaped trace evidence through create-only transactions', { timeout: 30000 }, async (t) => {
  const { app, run, setPayload } = await appFixture(t);
  fillToSize(run, setPayload, MAX_OUTPUT_BYTES - 1024);
  const imported = await app.call('eval_import_run', { run });
  const saved = await app.store.read('runs', run.id);
  const storedBytes = (await readFile(app.store.path('runs', run.id))).length;
  assert.ok(storedBytes >= MAX_OUTPUT_BYTES - 4096 && storedBytes <= MAX_OUTPUT_BYTES);
  assert.equal(imported.run.results[0].trace.transcript[0].content, run.results[0].trace.transcript[0].content);
  assert.equal(saved.results[0].trace.transcript[0].content, run.results[0].trace.transcript[0].content);
  await assert.rejects(app.call('eval_import_run', { run }), /already exists/);
  assert.equal((await readFile(app.store.path('runs', run.id))).length, storedBytes);
});

test('public import rejects escaped evidence over the record limit before creating a run', { timeout: 30000 }, async (t) => {
  const { app, run, setPayload } = await appFixture(t);
  fillToSize(run, setPayload, MAX_OUTPUT_BYTES + 1);
  await assert.rejects(app.call('eval_import_run', { run }), /Run import exceeds size limit/);
  await assert.rejects(app.store.read('runs', run.id), /not found/);
});
