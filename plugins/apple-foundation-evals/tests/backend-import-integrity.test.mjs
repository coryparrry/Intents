import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { portableSuite, sampleEnvelope } from '../server/app-format.mjs';
import { suite as validateSuite } from '../server/validation.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'eval-import-integrity-'));
  const app = new EvaluationApp({ dataDir: directory, resolveBinary: async () => '/unused', invoke: async (_binary, request) => ({ attachment: { kind: 'text', text: request.name } }) });
  await app.init();
  t.after(async () => { await app.shutdown(); await rm(directory, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'Import identity', version: 'v1', cases: [{ id: randomUUID(), name: 'Case', prompt: 'Say apple', expected: '' }] } });
  const now = new Date().toISOString();
  const source = suite.cases[0];
  const raw = { id: randomUUID(), suiteID: suite.id, suiteName: suite.name, startedAt: now, completedAt: now, cancelled: false, suiteDefinition: { formatVersion: 1, ...portableSuite(suite) }, results: [{ id: randomUUID(), caseID: source.id, caseName: source.name, repetition: 1, prompt: source.prompt, expected: source.expected, response: 'apple', status: 'unscored', durationMilliseconds: 1 }] };
  return { app, suite, raw };
}

test('run import and trace parsing reject an envelope with a different native run identity', async t => {
  const { app, suite, raw } = await fixture(t);
  const envelope = { id: randomUUID(), suiteId: suite.id, suite, status: 'completed', startedAt: raw.startedAt, finishedAt: raw.completedAt, results: raw.results.map(sampleEnvelope), appRun: raw };
  for (const tool of ['eval_import_run', 'eval_parse_trace']) {
    await assert.rejects(app.call(tool, { json: JSON.stringify(envelope) }), /run identity/i);
  }
  assert.equal((await app.call('eval_list_runs')).runs.length, 0);
  envelope.id = raw.id.toUpperCase();
  assert.equal((await app.call('eval_import_run', { run: envelope })).run.id, raw.id);
});

test('a suite override cannot relabel raw app evidence with or without a definition', async t => {
  const { app, suite, raw } = await fixture(t);
  const foreignId = randomUUID();
  for (const hasDefinition of [true, false]) {
    const changed = { ...raw, suiteID: foreignId };
    if (!hasDefinition) delete changed.suiteDefinition;
    await assert.rejects(app.call('eval_import_run', { json: JSON.stringify(changed), suiteId: suite.id }), /suite identity/i);
  }
  assert.equal((await app.call('eval_list_runs')).runs.length, 0);
  assert.equal((await app.call('eval_import_run', { run: raw, suiteId: suite.id.toUpperCase() })).run.suiteId, suite.id);
});

test('portable reference attachment UUID matching is case insensitive', async t => {
  const { app, suite } = await fixture(t);
  const { suite: attached } = await app.call('eval_add_reference_file', { suiteId: suite.id, name: 'notes.txt', mimeType: 'text/plain', base64: Buffer.from('Reference').toString('base64') });
  const exported = await app.call('eval_export_suite', { suiteId: suite.id });
  const bundle = JSON.parse(exported.json);
  bundle.suite.id = randomUUID();
  bundle.referenceFiles[0].attachmentId = bundle.referenceFiles[0].attachmentId.toUpperCase();
  const imported = (await app.call('eval_import_suite', { json: JSON.stringify(bundle) })).suite;
  assert.deepEqual(imported.attachments, attached.attachments);
});

for (const [label, configure] of [
  ['attachments', (source, ids) => { source.attachments = ids.map(id => ({ id, name: 'Notes', kind: 'text', text: 'reference' })); }],
  ['tools', (source, ids) => { source.features = { tools: ids.map((id, index) => ({ id, name: `tool${index}` })) }; }],
  ['output fields', (source, ids) => { source.features = { outputFields: ids.map((id, index) => ({ id, name: `field${index}`, type: 'string' })) }; }],
  ['setup turns', (source, ids) => { source.cases[0].conversation = { setupTurns: ids.map(id => ({ id, prompt: 'Setup' })) }; }],
]) {
  test(`app suite rejects duplicate ${label} UUIDs with different casing`, () => {
    const id = 'abcdefab-1234-4567-89ab-abcdefabcdef';
    const source = { name: 'Identity validation', version: 'v1', cases: [{ prompt: 'Say apple' }] };
    configure(source, [id, id.toUpperCase()]);
    assert.throws(() => validateSuite(source, randomUUID), /unique/);
  });
}
