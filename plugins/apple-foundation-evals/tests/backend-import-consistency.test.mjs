import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { portableSuite, sampleEnvelope } from '../server/app-format.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'eval-import-consistency-'));
  const app = new EvaluationApp({ dataDir: directory });
  await app.init();
  t.after(async () => { await app.shutdown(); await rm(directory, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'Import evidence', scoringMode: 'review',
    cases: [{ id: randomUUID(), name: 'Case', prompt: 'Say apple', expected: '' }] } });
  return { app, suite };
}
function envelope(suite, kind) {
  const now = new Date().toISOString();
  const source = suite.cases[0];
  const appRun = { id: randomUUID(), suiteID: suite.id, startedAt: now, completedAt: now,
    cancelled: kind === 'cancelled', suiteDefinition: { formatVersion: 1, ...portableSuite(suite) },
    results: [{ id: randomUUID(), caseID: source.id, caseName: source.name, repetition: 1,
      prompt: source.prompt, expected: source.expected, response: 'apple', status: 'unscored', durationMilliseconds: 1 }] };
  if (kind === 'stopped') { appRun.terminationReason = 'contextWindowOverflow'; appRun.results = []; }
  if (kind === 'error') appRun.results[0].status = 'error';
  return { id: appRun.id, suiteId: suite.id, suite, startedAt: now, finishedAt: now,
    status: kind === 'cancelled' || kind === 'outer-cancelled' ? 'cancelled' : ['stopped', 'error'].includes(kind) ? 'failed' : 'completed',
    results: appRun.results.map((sample) => sampleEnvelope(sample)), appRun };
}

test('valid completed, cancelled, stopped and conservative outer-cancelled imports retain exact raw evidence', async (t) => {
  const { app, suite } = await fixture(t);
  for (const kind of ['completed', 'cancelled', 'stopped', 'error', 'outer-cancelled']) {
    const value = envelope(suite, kind);
    value.appRun.id = value.appRun.id.toUpperCase();
    const imported = (await app.call('eval_import_run', { run: value })).run;
    assert.equal(imported.id, value.id);
    assert.equal(imported.status, value.status);
    assert.deepEqual((await app.call('eval_export_run', { runId: imported.id })).run, value.appRun);
    const parsed = (await app.call('eval_parse_trace', { json: JSON.stringify(value) })).run;
    assert.equal(parsed.status, value.status);
  }
  // Older flat traces have no embedded app run to contradict their envelope.
  const legacy = envelope(suite, 'completed'); delete legacy.appRun;
  assert.equal((await app.call('eval_import_run', { run: legacy })).run.id, legacy.id);
});

test('inconsistent run identity or promoted terminal status is rejected without creating a record', async (t) => {
  const { app, suite } = await fixture(t);
  for (const kind of ['identity', 'cancelled', 'stopped', 'error']) {
    const value = envelope(suite, kind === 'identity' ? 'completed' : kind);
    if (kind === 'identity') value.id = randomUUID();
    else value.status = 'completed';
    const expected = kind === 'identity' ? /identity does not match/ : /status does not match/;
    await assert.rejects(app.call('eval_import_run', { run: value }), expected);
    await assert.rejects(app.call('eval_parse_trace', { json: JSON.stringify(value) }), expected);
    await assert.rejects(app.store.read('runs', value.id), /not found/);
  }
  assert.deepEqual((await app.call('eval_list_runs')).runs, []);
});
