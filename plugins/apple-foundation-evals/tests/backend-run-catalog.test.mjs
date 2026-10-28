import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, symlink, unlink, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { EvaluationApp, summary } from '../server/app.mjs';
import { health } from '../server/workspace.mjs';
import { revision } from '../server/app-format.mjs';

/** Creates real isolated store records without native inference and counts full run reads. */
async function fixture(t, count = 2) {
  const root = await mkdtemp(join(tmpdir(), 'run-catalog-'));
  const app = new EvaluationApp({ dataDir: root }); await app.store.init();
  t.after(async () => { await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  const suite = { id: randomUUID(), name: 'Synthetic history', repetitions: 1, cases: [{ id: 'one', prompt: 'Synthetic', scoring: 'none' }] };
  await writeFile(app.store.path('suites', suite.id), JSON.stringify(suite));
  const runs = Array.from({ length: count }, () => ({ id: randomUUID(), suiteId: suite.id, suite, status: 'completed', startedAt: '2026-10-28T00:00:00Z', finishedAt: '2026-10-28T00:00:01Z',
    results: [{ caseId: 'one', passed: null, response: 'x'.repeat(16000) }] }));
  for (const run of runs) await writeFile(app.store.path('runs', run.id), JSON.stringify(run));
  const original = app.store.readRecord.bind(app.store); let reads = 0;
  /** Counts validated full run reads while preserving the real store result and errors. */
  app.store.readRecord = async (kind, key) => { const record = await original(kind, key); if (kind === 'runs') reads++; return record; };
  return { app, suite, runs,
    /** Returns the number of full run reads since the last counter reset. */
    reads: () => reads,
    /** Starts an independent read-count assertion without clearing the production cache. */
    reset: () => { reads = 0; } };
}

test('unchanged terminal history reuses bounded summaries without rereading response payloads', async t => {
  const f = await fixture(t, 50);
  const first = (await f.app.call('eval_list_runs')).runs; assert.equal(first.length, 50); assert.equal(f.reads(), 50);
  f.reset(); assert.deepEqual((await f.app.call('eval_list_runs')).runs, first); assert.equal(f.reads(), 0);
  assert.deepEqual(first.find(run => run.id === f.runs[0].id), { ...summary(f.runs[0]), health: health(f.runs[0], { ...f.suite, revision: revision(f.suite) }) });
  assert.ok(f.app.runCatalog.cacheBytes < 100000); assert.ok(!JSON.stringify([...f.app.runCatalog.cache.values()]).includes('x'.repeat(100)));
});

test('external same-size edits with restored mtime, additions, deletions and suite freshness invalidate the right metadata', async t => {
  const f = await fixture(t); await f.app.runs(); f.reset();
  const path = f.app.store.path('runs', f.runs[0].id), before = await stat(path);
  const changed = { ...f.runs[0], results: [{ ...f.runs[0].results[0], response: 'y'.repeat(16000) }] };
  await writeFile(path, JSON.stringify(changed)); await utimes(path, before.atime, before.mtime);
  let listed = await f.app.runs(); assert.equal(f.reads(), 1); assert.equal(listed.find(run => run.id === changed.id).revision, summary(changed).revision);
  f.reset(); const added = { ...changed, id: randomUUID() }; await writeFile(f.app.store.path('runs', added.id), JSON.stringify(added));
  listed = await f.app.runs(); assert.equal(listed.length, 3); assert.equal(f.reads(), 1);
  f.reset(); await unlink(path); listed = await f.app.runs(); assert.equal(listed.length, 2); assert.equal(f.reads(), 0); assert.equal(f.app.runCatalog.cache.has(changed.id), false);
  await writeFile(f.app.store.path('suites', f.suite.id), JSON.stringify({ ...f.suite, name: 'Changed definition' }));
  listed = await f.app.runs(); assert.ok(listed.every(run => run.health.staleEvidence)); assert.equal(f.reads(), 0);
});

test('cached history still rejects malformed, identity-mismatched and symlink replacements even outside the requested project', async t => {
  const f = await fixture(t, 1); await f.app.runs(); const path = f.app.store.path('runs', f.runs[0].id);
  await writeFile(path, '{'); await assert.rejects(f.app.runs(randomUUID()), SyntaxError);
  await writeFile(path, JSON.stringify({ ...f.runs[0], id: randomUUID() })); await assert.rejects(f.app.runs(), /Stored record id mismatch/);
  await unlink(path); await symlink(f.app.store.path('suites', f.suite.id), path); await assert.rejects(f.app.runs(), /Invalid stored record/);
});

test('returned warning metadata cannot mutate cached evidence summaries', async t => {
  const f = await fixture(t, 1), path = f.app.store.path('runs', f.runs[0].id);
  await writeFile(path, JSON.stringify({ ...f.runs[0], startedAt: { invalid: 'original saved value' } }));
  const listed = await f.app.runs(); listed[0].invalidTimestamps.startedAt.invalid = 'caller edit'; f.reset();
  assert.equal((await f.app.runs())[0].invalidTimestamps.startedAt.invalid, 'original saved value'); assert.equal(f.reads(), 0);
});

test('evidence replaced during a scan is not cached under the replacement fingerprint', async t => {
  const f = await fixture(t, 1), original = f.app.store.readRecord.bind(f.app.store), path = f.app.store.path('runs', f.runs[0].id);
  const changed = { ...f.runs[0], results: [{ ...f.runs[0].results[0], passed: true }] }; let replaced = false;
  /** Replaces one run immediately after its bytes are read to exercise the cache's fingerprint race. */
  f.app.store.readRecord = async (kind, key) => { const record = await original(kind, key); if (kind === 'runs' && !replaced) { replaced = true; await writeFile(path, JSON.stringify(changed)); } return record; };
  const listed = await f.app.runs(); assert.equal(listed[0].passed, 1); assert.equal(f.reads(), 2);
  f.reset(); assert.equal((await f.app.runs())[0].passed, 1); assert.equal(f.reads(), 0);
});

test('cached running records still recover abandoned owners and observe live progress and reassessment health', async t => {
  const f = await fixture(t, 1), path = f.app.store.path('runs', f.runs[0].id);
  let run = { ...f.runs[0], status: 'running', ownerPid: process.pid, results: [] }; await writeFile(path, JSON.stringify(run));
  assert.equal((await f.app.runs())[0].totalResults, 0);
  run = { ...run, results: f.runs[0].results }; await writeFile(path, JSON.stringify(run)); f.reset();
  assert.equal((await f.app.runs())[0].totalResults, 1); assert.equal(f.reads(), 1);
  run = { ...run, ownerPid: 2147483647 }; await writeFile(path, JSON.stringify(run));
  assert.equal((await f.app.runs())[0].status, 'failed'); assert.match(JSON.parse(await readFile(path, 'utf8')).error, /interrupted/);
  run = { ...run, status: 'completed', appRun: { selectedAssessmentID: 'chosen', assessments: [{ id: 'chosen', samples: [{ errorMessage: 'Synthetic failed reassessment' }] }] } };
  await writeFile(path, JSON.stringify(run)); assert.equal((await f.app.runs())[0].health.currentAssessment, 'error');
  run.appRun.selectedAssessmentID = 'missing'; await writeFile(path, JSON.stringify(run)); assert.equal((await f.app.runs())[0].health.currentAssessment, 'missing');
});
