import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { sampleEnvelope } from '../server/app-format.mjs';

async function fixture(t, failures = Infinity) {
  const root = await mkdtemp(join(tmpdir(), 'standalone-recovery-'));
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const result = { caseId: 'one', repetition: 1, prompt: 'apple', expected: 'apple', response: 'apple', passed: true, score: 1, durationMs: 1, trace: { transcript: [{ role: 'assistant', content: 'apple' }] } };
  const app = new EvaluationApp({ dataDir: root, resolveBinary: async () => '/explicit-callback', invoke: async () => { await gate; return { status: 'completed', model: 'Fixture', durationMs: 1, results: [result] }; } });
  await app.init();
  const other = new EvaluationApp({ dataDir: root, invoke: async () => { throw new Error('Unexpected inference'); } });
  await other.init();
  t.after(async () => { release(); await app.shutdown(); await other.shutdown(); await rm(root, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'Recovery', cases: [{ id: 'one', prompt: 'apple', expected: 'apple', scoring: 'exact' }] } });
  const write = app.store.write.bind(app.store);
  let remaining = failures;
  app.store.write = async (kind, value) => {
    if (kind === 'runs' && value.status !== 'running' && remaining > 0) { remaining--; throw new Error('transient terminal storage failure'); }
    return write(kind, value);
  };
  const { run } = await app.call('eval_start_run', { suiteId: suite.id });
  const completion = app.active.promise;
  release(); await completion;
  assert.equal(app.active, null);
  assert.equal(app.store.leases.size, 0);
  return { app, other, suite, run, result, restore: () => { remaining = 0; } };
}

for (const route of ['read', 'list', 'start']) {
  test(`standalone failed publication recovers via ${route}, retaining evidence and instance ownership`, async (t) => {
    const { app, other, suite, run, result, restore } = await fixture(t);
    const interrupted = await app.store.read('runs', run.id);
    assert.equal(interrupted.status, 'running');
    await other.recover();
    assert.equal((await other.call('eval_get_run', { runId: run.id })).run.status, 'running');
    assert.deepEqual(await app.store.read('runs', run.id), interrupted);
    for (let i = 0; i < 2; i++) {
      await assert.rejects(app.call('eval_get_run', { runId: run.id }), /transient terminal storage failure/);
      assert.equal(app.store.leases.size, 0);
    }
    restore();
    if (route === 'read') await app.call('eval_get_run', { runId: run.id });
    if (route === 'list') await app.call('eval_list_runs');
    if (route === 'start') {
      await app.call('eval_start_run', { suiteId: suite.id });
      await app.active.promise;
    }
    const recovered = (await app.call('eval_get_run', { runId: run.id })).run;
    assert.equal(recovered.status, 'failed');
    assert.match(recovered.error, /Could not save native result/);
    assert.deepEqual(recovered.results, [result]);
    assert.equal(recovered.model, 'Fixture');
    await app.call('eval_cancel_run', { runId: run.id });
    await app.call('eval_delete_run', { runId: run.id });
    assert.equal(app.pendingRunRecovery.size, 0);
  });
}

test('standalone primary publication failure retains final evidence in successful fallback', async (t) => {
  const { app, run, result } = await fixture(t, 1);
  const recovered = (await app.call('eval_get_run', { runId: run.id })).run;
  assert.equal(recovered.status, 'failed');
  assert.deepEqual(recovered.results, [result]);
  assert.equal(app.pendingRunRecovery.size, 0);
});

for (const status of ['running', 'completed']) {
  test(`standalone recovery fresh read preserves newer ${status} record after lease acquisition`, async (t) => {
    const { app, other, run, restore } = await fixture(t);
    restore();
    const current = await app.store.read('runs', run.id);
    const newer = { ...current, status, error: 'Newer authoritative record' };
    const acquire = app.store.acquireRunLock.bind(app.store);
    app.store.acquireRunLock = async (...args) => {
      // Model a writer committing after recovery decided to run but before it
      // owns the shared lease. The fresh read must protect the new record.
      await other.store.write('runs', newer);
      return acquire(...args);
    };
    await app.call('eval_get_run', { runId: run.id });
    assert.deepEqual(await app.store.read('runs', run.id), newer);
    assert.equal(app.pendingRunRecovery.size, 0);
  });
}

test('standalone recovery waits for the shared lease and retains pending evidence', async (t) => {
  const { app, other, run, result, restore } = await fixture(t);
  restore();
  const owner = randomUUID();
  await other.store.acquireRunLock(owner);
  try {
    assert.equal((await app.call('eval_get_run', { runId: run.id })).run.status, 'running');
    assert.equal(app.pendingRunRecovery.size, 1);
  } finally { await other.store.releaseRunLock(owner); }
  const recovered = (await app.call('eval_get_run', { runId: run.id })).run;
  assert.equal(recovered.status, 'failed');
  assert.deepEqual(recovered.results, [result]);
});

async function postLeaseReadFixture(t, { progress = true, failProgress = false, partial = false, readFailures = Infinity } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'postlease-read-recovery-'));
  const sample = { id: randomUUID(), caseID: randomUUID(), caseName: 'Fruit', repetition: 1, prompt: 'apple', expected: 'apple', response: 'apple', status: 'passed', score: 1, durationMilliseconds: 1 };
  const result = sampleEnvelope(sample);
  let release, observedProgress;
  const gate = new Promise(resolve => { release = resolve; });
  const progressWritten = new Promise(resolve => { observedProgress = resolve; });
  const app = new EvaluationApp({ dataDir: root, resolveBinary: async () => '/explicit-callback', invoke: async (_binary, _request, { onEvent }) => {
    await gate;
    if (progress) {
      onEvent({ event: 'liveResponse', value: { text: 'Before sample' } });
      onEvent({ event: 'sample', result: sample });
      await progressWritten;
    }
    // This mutation is not persisted, so hashing the mutable run at completion
    // would no longer identify either the initial or last saved progress record.
    onEvent({ event: 'liveResponse', value: { text: 'After last sample' } });
    if (partial) throw new Error('Native callback interrupted after sample');
    return { status: 'completed', model: 'Fixture', durationMs: 1, results: [result] };
  } });
  await app.init();
  const other = new EvaluationApp({ dataDir: root, invoke: async () => { throw new Error('Unexpected inference'); } });
  await other.init();
  t.after(async () => { release(); await app.shutdown(); await other.shutdown(); await rm(root, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'Read recovery', cases: [{ id: sample.caseID, prompt: 'apple', expected: 'apple', scoring: 'exact' }] } });
  const write = app.store.write.bind(app.store);
  app.store.write = async (kind, value) => {
    if (kind === 'runs' && value.status === 'running' && value.completedSamples) {
      try {
        if (failProgress) throw new Error('Injected progress write failure');
        return await write(kind, value);
      } finally { observedProgress(); }
    }
    return write(kind, value);
  };
  const read = app.store.read.bind(app.store);
  const releaseLock = app.store.releaseRunLock.bind(app.store);
  let released = false, remaining = readFailures, failures = 0;
  app.store.releaseRunLock = async key => { await releaseLock(key); released = true; };
  app.store.read = async (kind, key) => {
    if (released && kind === 'runs' && remaining > 0) {
      remaining--; failures++;
      throw Object.assign(new Error('Injected post-lease read outage'), { code: 'EIO' });
    }
    return read(kind, key);
  };
  const { run } = await app.call('eval_start_run', { suiteId: suite.id });
  const completion = app.active.promise;
  release(); await completion;
  assert.equal(app.active, null);
  assert.equal(app.store.leases.size, 0);
  return { app, other, suite, run, result: JSON.parse(JSON.stringify(result)), read, failures: () => failures, restore: () => { remaining = 0; } };
}

for (const route of ['read', 'list', 'start']) {
  test(`post-lease read outage recovers completed output via ${route} with saved progress`, async (t) => {
    const { app, other, suite, run, result, read, failures, restore } = await postLeaseReadFixture(t);
    const interrupted = await read('runs', run.id);
    assert.equal(interrupted.status, 'running');
    assert.equal(interrupted.completedSamples, 1);
    assert.deepEqual(interrupted.results, [result]);
    await other.recover();
    assert.equal((await other.call('eval_get_run', { runId: run.id })).run.status, 'running');
    for (let i = 0; i < 2; i++) {
      await assert.rejects(app.call('eval_get_run', { runId: run.id }), /post-lease read outage/);
      assert.equal(app.store.leases.size, 0);
      assert.equal(app.pendingRunRecovery.size, 1);
    }
    assert.equal(failures(), 3);
    restore();
    if (route === 'read') await app.call('eval_get_run', { runId: run.id });
    if (route === 'list') await app.call('eval_list_runs');
    if (route === 'start') {
      await app.call('eval_start_run', { suiteId: suite.id });
      await app.active.promise;
    }
    const recovered = (await app.call('eval_get_run', { runId: run.id })).run;
    assert.equal(recovered.status, 'completed');
    assert.deepEqual(recovered.results, [result]);
    assert.equal(recovered.model, 'Fixture');
    assert.equal(recovered.liveResponse.text, 'After last sample');
    assert.equal(app.pendingRunRecovery.size, 0);
    await app.call('eval_cancel_run', { runId: run.id });
    await app.call('eval_delete_run', { runId: run.id });
  });
}

for (const options of [{ progress: false }, { failProgress: true }, { partial: true }, { readFailures: 1 }, { readFailures: 0 }]) {
  test(`post-lease read recovery retains the last saved revision and output: ${JSON.stringify(options)}`, async (t) => {
    const { app, run, result, restore, read } = await postLeaseReadFixture(t, options);
    const current = await read('runs', run.id);
    if (options.failProgress || options.progress === false) assert.equal(current.results.length, 0);
    restore();
    const recovered = (await app.call('eval_get_run', { runId: run.id })).run;
    assert.equal(recovered.status, options.partial ? 'failed' : 'completed');
    assert.deepEqual(recovered.results, [result]);
    if (options.partial) assert.match(recovered.error, /Native callback interrupted/);
    assert.equal(app.pendingRunRecovery.size, 0);
    assert.equal(app.store.leases.size, 0);
  });
}

for (const status of ['running', 'completed']) {
  test(`post-lease read recovery preserves a newer ${status} record acquired before recovery lease`, async (t) => {
    const { app, other, run, read, restore } = await postLeaseReadFixture(t);
    restore();
    const newer = { ...await read('runs', run.id), status, error: 'New authoritative record' };
    const acquire = app.store.acquireRunLock.bind(app.store);
    app.store.acquireRunLock = async key => { await other.store.write('runs', newer); return acquire(key); };
    await app.call('eval_get_run', { runId: run.id });
    assert.deepEqual(await read('runs', run.id), newer);
    assert.equal(app.pendingRunRecovery.size, 0);
  });
}

test('post-lease read recovery waits for another instance shared lease', async (t) => {
  const { app, other, run, result, restore } = await postLeaseReadFixture(t);
  restore();
  const owner = randomUUID();
  await other.store.acquireRunLock(owner);
  try {
    assert.equal((await app.call('eval_get_run', { runId: run.id })).run.status, 'running');
    assert.equal(app.pendingRunRecovery.size, 1);
  } finally { await other.store.releaseRunLock(owner); }
  const recovered = (await app.call('eval_get_run', { runId: run.id })).run;
  assert.equal(recovered.status, 'completed');
  assert.deepEqual(recovered.results, [result]);
});

test('startup recovers experiment histories exceeding the aggregate catalog limit', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'large-experiment-recovery-'));
  const app = new EvaluationApp({ dataDir: root });
  const reopened = new EvaluationApp({ dataDir: root });
  t.after(async () => { await app.shutdown(); await reopened.shutdown(); await rm(root, { recursive: true, force: true }); });
  await app.init();
  const ids = [randomUUID(), randomUUID()];
  for (const id of ids) {
    await app.store.write('experiments', { id, status: 'completed', partialEvidence: 'x'.repeat(17 * 1024 * 1024) });
  }
  await assert.rejects(app.store.list('experiments'), /catalog/i);
  await reopened.init();
  for (const id of ids) {
    const saved = await reopened.store.read('experiments', id);
    assert.equal(saved.status, 'completed');
    assert.equal(saved.partialEvidence.length, 17 * 1024 * 1024);
  }
});
