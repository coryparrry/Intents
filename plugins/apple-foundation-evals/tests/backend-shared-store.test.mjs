import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, readdir, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, fork } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { portableSuite } from '../server/app-format.mjs';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'shared-suite-'));
  const app = new EvaluationApp({ dataDir: root, invoke: async () => { throw new Error('Unexpected inference'); } });
  await app.init();
  t.after(async () => { await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'shared', cases: [{ id: 'case-one', prompt: 'fruit', expected: 'apple', scoring: 'exact' }] } });
  return { root, app, suite };
}
const worker = fileURLToPath(new URL('./helpers/suite-save-worker.mjs', import.meta.url));
async function session(t, root) {
  const child = fork(worker, [root], { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
  t.after(() => child.kill());
  const [message] = await once(child, 'message');
  assert.equal(message.ready, true);
  return child;
}
function save(child, args) {
  const result = once(child, 'message').then(([message]) => message);
  child.send(args); return result;
}
async function holder(t, lockPath) {
  const executable = process.platform === 'darwin' ? '/usr/bin/lockf' : '/usr/bin/flock';
  const args = process.platform === 'darwin' ? ['-k', '-s', '-t', '1', lockPath] : ['-w', '1', lockPath];
  const child = spawn(executable, [...args, process.execPath, worker, '--hold'], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} });
  const [chunk] = await once(child.stdout, 'data');
  assert.equal(chunk.toString(), 'locked\n');
  return child;
}

test('two EvaluationApp instances atomically reject the second stale save', async (t) => {
  const { root, app, suite } = await fixture(t);
  const other = new EvaluationApp({ dataDir: root }); await other.init(); t.after(() => other.shutdown());
  const results = await Promise.allSettled([app, other].map((session, index) => session.call('eval_save_suite', { suite: { ...suite, name: `edit-${index}` }, expectedRevision: suite.revision })));
  assert.equal(results.filter((item) => item.status === 'fulfilled').length, 1);
  const rejected = results.find((item) => item.status === 'rejected');
  assert.match(rejected.reason.message, /revision conflict/);
  assert.deepEqual(await app.store.read('suites', suite.id), results.find((item) => item.status === 'fulfilled').value.suite);
});
test('independent server processes cannot both acknowledge the same expected revision', async (t) => {
  const { root, app, suite } = await fixture(t);
  const children = await Promise.all([session(t, root), session(t, root)]);
  const results = await Promise.all(children.map((child, index) => save(child, { suite: { ...suite, name: `process-${index} 🍏` }, expectedRevision: suite.revision })));
  assert.equal(results.filter((item) => item.suite).length, 1);
  assert.match(results.find((item) => item.error).error, /revision conflict/);
  const saved = results.find((item) => item.suite).suite;
  assert.deepEqual(await app.store.read('suites', suite.id), saved);
  const unchanged = await app.call('eval_save_suite', { suite: saved, expectedRevision: saved.revision });
  assert.equal(unchanged.suite.updatedAt, saved.updatedAt);
});
test('suite lock acquisition is bounded and process death safely releases the same lock inode', async (t) => {
  const { app, suite } = await fixture(t);
  const lockPath = join(app.store.root, '.suite-locks', `${suite.id}.lock`);
  const inode = (await stat(lockPath)).ino;
  const owner = await holder(t, lockPath);
  await assert.rejects(app.call('eval_save_suite', { suite: { ...suite, name: 'blocked' }, expectedRevision: suite.revision }), /transaction failed/);
  assert.equal((await app.store.read('suites', suite.id)).revision, suite.revision);
  process.kill(owner.pid, 0); // A live owner is never removed as a stale lock.
  const closed = once(owner, 'close'); process.kill(-owner.pid, 'SIGKILL'); await closed;
  const changed = await app.call('eval_save_suite', { suite: { ...suite, name: 'recovered' }, expectedRevision: suite.revision });
  assert.equal(changed.suite.name, 'recovered');
  assert.equal((await stat(lockPath)).ino, inode);
  assert.ok((await readdir(join(app.store.root, 'suites'))).every((name) => name.endsWith('.json')), 'persistent locks do not consume catalog entries');
});
test('suite transactions keep the independent inference lease held', async (t) => {
  const { app, suite } = await fixture(t);
  const other = new EvaluationApp({ dataDir: app.store.root }); await other.init(); t.after(() => other.shutdown());
  const runId = randomUUID(); await app.store.acquireRunLock(runId);
  try {
    await app.call('eval_save_suite', { suite: { ...suite, name: 'during lease' }, expectedRevision: suite.revision });
    await assert.rejects(other.store.acquireRunLock(randomUUID()), /already active/);
  } finally { await app.store.releaseRunLock(runId); }
});

test('invalid flat imported dates fail before persistence and ISO dates normalize', async (t) => {
  const { app, suite } = await fixture(t);
  const results = [{ caseId: 'case-one', repetition: 1, prompt: 'fruit', expected: 'apple', response: 'apple', passed: true, score: 1, durationMs: 1, trace: { transcript: [] } }];
  for (const date of [0, 1, null, [], {}, '0', '2026-02-30T00:00:00Z', 'invalid']) {
    const run = { id: randomUUID(), suite, suiteId: suite.id, status: 'completed', startedAt: date, finishedAt: date, results };
    await assert.rejects(app.call('eval_import_run', { run }), /timestamps/);
    await assert.rejects(app.store.read('runs', run.id), /not found/);
  }
  for (let index = 0; index < 2; index++) {
    const { run } = await app.call('eval_import_run', { run: { id: randomUUID(), suite, suiteId: suite.id, status: 'completed', startedAt: '2026-10-15T12:00:00+01:00', finishedAt: '2026-10-15T12:00:01+01:00', results } });
    assert.equal(run.startedAt, '2026-10-15T11:00:00.000Z');
  }
  assert.equal((await app.call('eval_list_runs')).runs.length, 2);
  assert.equal((await app.call('eval_open_workspace')).runs.length, 2);
});

test('malformed existing run timestamps stay visible without mutating or hiding evidence', async (t) => {
  const { app, suite } = await fixture(t);
  const records = [];
  for (const startedAt of [0, { unexpected: 'date' }]) {
    const record = { id: randomUUID(), suite, suiteId: suite.id, projectId: suite.projectId, status: 'completed', startedAt, finishedAt: 0, results: [] };
    await app.store.write('runs', record);
    records.push({ record, contents: await readFile(app.store.path('runs', record.id), 'utf8') });
  }
  for (const tool of ['eval_list_runs', 'eval_open_workspace']) {
    const { runs } = await app.call(tool);
    assert.equal(runs.length, records.length);
    for (const { record } of records) {
      const summary = runs.find((run) => run.id === record.id);
      assert.equal(summary.startedAt, '');
      assert.match(summary.timestampWarning, /invalid timestamps/);
      assert.deepEqual(summary.invalidTimestamps, { startedAt: record.startedAt, finishedAt: 0 });
    }
  }
  for (const { record, contents } of records) {
    const exported = await app.call('eval_export_run', { runId: record.id });
    assert.deepEqual(exported.run.startedAt, record.startedAt);
    assert.equal(await readFile(app.store.path('runs', record.id), 'utf8'), contents);
  }
});

test('native Codable epoch dates normalize explicitly and malformed native dates never persist', async (t) => {
  const { app } = await fixture(t);
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'native dates', version: 'v1', cases: [{ id: randomUUID(), name: 'one', prompt: 'fruit' }] } });
  const source = { id: randomUUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version, startedAt: 0, completedAt: 1, cancelled: false, suiteDefinition: portableSuite(suite), results: [{ id: randomUUID(), caseID: suite.cases[0].id, caseName: 'one', repetition: 1, prompt: 'fruit', expected: '', response: 'apple', status: 'unscored', durationMilliseconds: 1, usage: {}, workflowTrace: { spans: [] } }] };
  const { run } = await app.call('eval_import_run', { run: source });
  assert.equal(run.startedAt, '2001-01-01T00:00:00.000Z');
  assert.equal(run.finishedAt, '2001-01-01T00:00:01.000Z');
  assert.equal(run.appRun.startedAt, 0, 'original native evidence is preserved');
  for (const startedAt of [[], {}, null, 1e20, '2026-02-30T00:00:00Z']) {
    const malformed = { ...source, id: randomUUID(), startedAt };
    await assert.rejects(app.call('eval_import_run', { run: malformed }), /timestamps/);
    await assert.rejects(app.store.read('runs', malformed.id), /not found/);
  }
  assert.equal((await app.call('eval_list_runs')).runs.length, 1);
});

function deferred() { let resolve; const promise = new Promise((accept) => { resolve = accept; }); return { promise, resolve }; }
async function delayedMigration(t, root, suiteId) {
  const app = new EvaluationApp({ dataDir: root });
  const arrived = deferred(); const resume = deferred();
  const migrate = app.store.migrateSuite.bind(app.store);
  app.store.migrateSuite = async (key, projectId) => {
    if (key === suiteId) { arrived.resolve(); await resume.promise; }
    return migrate(key, projectId);
  };
  t.after(() => { resume.resolve(); return app.shutdown(); });
  const startup = app.init(); await arrived.promise;
  return { app, startup, resume };
}
test('two actual app startups migrate current suite state without overwriting an acknowledged edit', async (t) => {
  const { root, app, suite } = await fixture(t);
  const { revision, projectId, ...legacyStored } = suite;
  await app.store.write('suites', legacyStored);
  const delayed = await delayedMigration(t, root, suite.id);
  const other = new EvaluationApp({ dataDir: root }); t.after(() => other.shutdown()); await other.init();
  const migrated = await other.store.read('suites', suite.id);
  assert.equal(migrated.projectId, projectId); assert.equal(typeof migrated.revision, 'string');
  const { suite: acknowledged } = await other.call('eval_save_suite', { suite: { ...migrated, name: 'Acknowledged edit' }, expectedRevision: migrated.revision });
  delayed.resume.resolve(); await delayed.startup;
  assert.deepEqual(await app.store.read('suites', suite.id), acknowledged);
  await delayed.app.init(); await other.init();
  assert.deepEqual(await app.store.read('suites', suite.id), acknowledged, 'startup migration is idempotent');
});
test('startup migration cannot recreate a suite deleted after its catalog snapshot', async (t) => {
  const { root, app, suite } = await fixture(t);
  const { revision, projectId, ...legacyStored } = suite;
  await app.store.write('suites', legacyStored);
  const delayed = await delayedMigration(t, root, suite.id);
  await app.call('eval_delete_suite', { suiteId: suite.id });
  delayed.resume.resolve(); await delayed.startup;
  await assert.rejects(app.store.read('suites', suite.id), /not found/);
});
test('failed adoption rollback preserves a second session acknowledged save', async (t) => {
  const { root, app, suite } = await fixture(t);
  const other = new EvaluationApp({ dataDir: root }); await other.init(); t.after(() => other.shutdown());
  const runIDs = [randomUUID(), randomUUID()];
  for (const runId of runIDs) await app.store.write('runs', { id: runId, suite, suiteId: suite.id, status: 'completed', results: [] });
  const experimentId = randomUUID();
  await app.store.write('experiments', { id: experimentId, suiteId: suite.id, sourceRevision: suite.revision, status: 'completed', experiment: { runIDs, candidate: { instructions: 'Candidate adopted' } } });
  const arrived = deferred(); const resume = deferred(); const originalWrite = app.store.write.bind(app.store);
  app.store.write = async (kind, value) => {
    if (kind === 'experiments' && value.experiment.decision) { arrived.resolve(); await resume.promise; throw new Error('disk full fixture'); }
    return originalWrite(kind, value);
  };
  const adoption = app.call('eval_decide_experiment', { experimentId, decision: 'adoptCandidate' });
  const rejected = assert.rejects(adoption, /disk full fixture; suite rollback was not applied: Suite revision conflict/);
  await arrived.promise;
  const adopted = await other.store.read('suites', suite.id);
  assert.equal(adopted.instructions, 'Candidate adopted');
  const { suite: acknowledged } = await other.call('eval_save_suite', { suite: { ...adopted, name: 'Acknowledged after adoption' }, expectedRevision: adopted.revision });
  resume.resolve(); await rejected;
  assert.deepEqual(await app.store.read('suites', suite.id), acknowledged);
});

test('concurrent run imports never overwrite evidence with an already committed identity', async (t) => {
  const { root, app, suite } = await fixture(t);
  const other = new EvaluationApp({ dataDir: root }); await other.init(); t.after(() => other.shutdown());
  const runId = randomUUID();
  let missingReads = 0, releaseReads;
  const bothMissing = new Promise((resolve) => { releaseReads = resolve; });
  for (const session of [app, other]) {
    const read = session.store.read.bind(session.store);
    session.store.read = async (kind, key) => {
      try { return await read(kind, key); }
      catch (error) {
        if (kind === 'runs' && key === runId && /not found$/.test(error.message)) {
          if (++missingReads === 2) releaseReads();
          await bothMissing;
        }
        throw error;
      }
    };
  }
  const imports = await Promise.allSettled([app, other].map((session, index) => session.call('eval_import_run', { run: {
    id: runId, suite, suiteId: suite.id, status: 'completed', startedAt: '2026-10-15T12:00:00Z', finishedAt: '2026-10-15T12:00:01Z',
    results: [{ caseId: 'case-one', repetition: 1, prompt: 'fruit', expected: 'apple', response: `evidence-${index}`, passed: false, score: 0, durationMs: 1, trace: { transcript: [] } }],
  } })));
  assert.equal(imports.filter((result) => result.status === 'fulfilled').length, 1);
  assert.match(imports.find((result) => result.status === 'rejected').reason.message, /already exists/);
  assert.deepEqual(await app.store.read('runs', runId), imports.find((result) => result.status === 'fulfilled').value.run);
});
