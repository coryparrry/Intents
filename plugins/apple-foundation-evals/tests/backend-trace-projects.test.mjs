import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { portableSuite } from '../server/app-format.mjs';

/** Creates an isolated app whose native execution path must remain unused during portable trace parsing. */
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'trace-project-preview-'));
  const app = new EvaluationApp({ dataDir: root,
    /** Fails if trace parsing attempts compilation or inference instead of inspecting saved evidence. */
    resolveBinary: async () => { throw new Error('Trace parsing must not invoke native execution'); },
  });
  await app.init(); t.after(async () => { await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  return app;
}

/** Captures every saved file and lock byte so read-only preview can prove it made no persistent changes. */
async function savedFiles(root) {
  const entries = [];
  for (const name of (await readdir(root, { recursive: true })).sort()) {
    const path = join(root, name);
    if ((await stat(path)).isFile()) entries.push([name, await readFile(path)]);
  }
  return entries;
}

test('a legacy trace exported from a foreign project previews without writes and imports into an explicitly chosen local project', async (t) => {
  const source = await fixture(t), destination = await fixture(t);
  const { project } = await source.call('eval_create_project', { name: 'Source-only project' });
  const { suite } = await source.call('eval_save_suite', { projectId: project.id, suite: { name: 'Portable legacy trace', cases: [{ id: 'case-one', prompt: 'Say apple', scoring: 'none' }] } });
  const now = new Date().toISOString(), record = { id: randomUUID(), suiteId: suite.id, projectId: project.id, suite, status: 'completed', startedAt: now, finishedAt: now,
    results: [{ caseId: 'case-one', repetition: 1, prompt: 'Say apple', response: 'apple', passed: null, score: null, durationMs: 1, trace: { transcript: [] } }] };
  const { run } = await source.call('eval_import_run', { run: record });
  const exported = await source.call('eval_export_run', { runId: run.id }), before = await savedFiles(destination.store.root);
  const parsed = (await destination.call('eval_parse_trace', { json: exported.json })).run;
  assert.equal(parsed.id, run.id); assert.equal(parsed.projectId, project.id); assert.deepEqual(parsed.results, run.results);
  assert.deepEqual(await savedFiles(destination.store.root), before);
  await assert.rejects(destination.call('eval_import_run', { json: exported.json }), /Project not found/);
  const imported = (await destination.call('eval_import_run', { json: exported.json, projectId: destination.defaultProjectId })).run;
  assert.equal(imported.projectId, destination.defaultProjectId);
  assert.deepEqual(imported.results, run.results);
});

test('raw app trace previews preserve foreign suite ownership without requiring a local project', async (t) => {
  const source = await fixture(t), destination = await fixture(t), foreignProject = randomUUID();
  const { suite } = await source.call('eval_save_suite', { suite: { name: 'Portable raw trace', version: 'v1', cases: [{ prompt: 'Say apple' }] } });
  const now = new Date().toISOString(), sample = suite.cases[0], record = { id: randomUUID(), suiteID: suite.id, suiteName: suite.name, startedAt: now, completedAt: now,
    suiteDefinition: { formatVersion: 1, ...portableSuite(suite), projectId: foreignProject }, results: [{ id: randomUUID(), caseID: sample.id, repetition: 1, prompt: sample.prompt, expected: sample.expected, response: 'apple', status: 'unscored', durationMilliseconds: 1 }] };
  const before = await savedFiles(destination.store.root), parsed = (await destination.call('eval_parse_trace', { json: JSON.stringify(record) })).run;
  assert.equal(parsed.projectId, foreignProject); assert.equal(parsed.results[0].response, 'apple');
  assert.deepEqual(await savedFiles(destination.store.root), before);
});
