import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
async function fixture(t, contents = ['First reference', 'Different second reference']) {
  const root = await mkdtemp(join(tmpdir(), 'reference-identity-'));
  const app = new EvaluationApp({ dataDir: root, resolveBinary: async () => '/unused-extractor', invoke: async (_binary, request) => {
    assert.equal(request.operation, 'extract-reference');
    return { attachment: { id: randomUUID(), name: request.name, kind: 'text', text: await readFile(fileURLToPath(request.fileURL), 'utf8') }, truncated: false };
  }});
  await app.init(); t.after(async () => { await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  let { suite } = await app.call('eval_save_suite', { suite: { name: 'References', version: 'v1', cases: [{ id: randomUUID(), prompt: 'Read references' }] } });
  for (const text of contents) ({ suite } = await app.call('eval_add_reference_file', { suiteId: suite.id, expectedRevision: suite.revision, name: 'reference.txt', mimeType: 'text/plain', base64: Buffer.from(text).toString('base64') }));
  return { root, app, suite, exported: await app.call('eval_export_suite', { suiteId: suite.id }) };
}
test('duplicate filenames round-trip by exact ID, including case-insensitive UUID spelling', async (t) => {
  const { app, suite, exported } = await fixture(t);
  const files = exported.referenceFiles.map((file) => ({ ...file, attachmentId: file.attachmentId.toUpperCase() })).reverse();
  const imported = await app.call('eval_import_suite', { suite: exported.suite, referenceFiles: files, expectedRevision: suite.revision });
  assert.deepEqual(imported.suite.attachments, suite.attachments);
});
test('ambiguous legacy names, duplicate IDs, unknown IDs and tampered bytes reject without suite or reference changes', async (t) => {
  const { root, app, suite, exported } = await fixture(t);
  const before = await readFile(app.store.path('suites', suite.id));
  const referenceNames = await readdir(join(root, 'references'));
  const first = exported.referenceFiles[0];
  const cases = [
    { files: [{ name: first.name, mimeType: first.mimeType, base64: first.base64 }], error: /ambiguous/ },
    { files: [first, first], error: /distinct attachments/ },
    { files: [{ ...first, attachmentId: randomUUID() }], error: /ID is not present/ },
    { files: [{ ...first, base64: Buffer.from('Tampered bytes').toString('base64') }], error: /do not match/ }
  ];
  for (const { files, error } of cases) {
    await assert.rejects(app.call('eval_import_suite', { suite: exported.suite, referenceFiles: files, expectedRevision: suite.revision }), error);
    assert.deepEqual(await readFile(app.store.path('suites', suite.id)), before);
    assert.deepEqual(await readdir(join(root, 'references')), referenceNames);
  }
});
test('legacy filename fallback remains available for one unambiguous attachment', async (t) => {
  const { app, suite, exported } = await fixture(t);
  const definition = { ...exported.suite, id: randomUUID(), attachments: [exported.suite.attachments[0]] };
  const { attachmentId, ...legacy } = exported.referenceFiles[0];
  const imported = await app.call('eval_import_suite', { suite: definition, referenceFiles: [legacy] });
  assert.deepEqual(imported.suite.attachments, [suite.attachments[0]]);
});

test('identical bytes with duplicate filenames preserve both distinct attachment IDs', async (t) => {
  const { app, suite, exported } = await fixture(t, ['Same bytes', 'Same bytes']);
  const imported = await app.call('eval_import_suite', { json: exported.json, expectedRevision: suite.revision });
  assert.deepEqual(imported.suite.attachments, suite.attachments);
  assert.notEqual(imported.suite.attachments[0].id, imported.suite.attachments[1].id);
});
test('duplicate IDs in the imported definition reject before reference extraction', async (t) => {
  const { root, app, suite, exported } = await fixture(t);
  const before = await readFile(app.store.path('suites', suite.id));
  const referenceNames = await readdir(join(root, 'references'));
  const definition = structuredClone(exported.suite); definition.attachments[1].id = definition.attachments[0].id;
  await assert.rejects(app.call('eval_import_suite', { suite: definition, referenceFiles: exported.referenceFiles, expectedRevision: suite.revision }), /IDs must be unique/);
  assert.deepEqual(await readFile(app.store.path('suites', suite.id)), before);
  assert.deepEqual(await readdir(join(root, 'references')), referenceNames);
});
