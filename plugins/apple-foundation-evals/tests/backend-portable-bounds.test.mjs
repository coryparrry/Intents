import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { EvaluationApp } from '../server/app.mjs';
import { MAX_REQUEST_BYTES, MAX_SUITE_BUNDLE_BYTES } from '../server/validation.mjs';

/** Creates an isolated app with deterministic text extraction while retaining real reference storage, leases, and transactions. */
async function fixture(t, texts = new Map()) {
  const root = await mkdtemp(join(tmpdir(), 'portable-suite-bounds-'));
  const app = new EvaluationApp({ dataDir: root,
    /** Bypasses native compilation because the fixture supplies its extraction response directly. */
    resolveBinary: async () => '/unused',
    /** Returns the fixture's extracted text while exercising real portable reference storage and metadata. */
    invoke: async (_binary, request) => ({ attachment: { kind: 'text', text: texts.get(request.name) || '' } }),
  });
  await app.init();
  t.after(async () => { await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  return app;
}

/** Creates distinct text-file payloads with controlled decoded sizes and canonical per-file base64 padding. */
function referenceFiles(byteCounts) {
  return byteCounts.map((count, index) => ({ name: `file${index}.txt`, mimeType: 'text/plain', base64: Buffer.alloc(count, 65 + index).toString('base64') }));
}

/** Builds a bounded leaf tree so accepted nested draft fields expose serialization growth from indentation. */
function outputFieldTree(depth, root = false) {
  if (!depth) return { name: 'leaf', type: 'string', description: 'Retain draft leaf content' };
  return { name: 'node', type: 'object', children: Array.from({ length: root ? 4 : 8 }, () => outputFieldTree(depth - 1)) };
}

for (const [label, byteCounts, encodedBytes] of [
  ['three individually valid files', [4999998, 4999998, 4999998], 19999992],
  ['four encoded bytes above the boundary with per-file padding', [4000000, 4000000, 3999997], 16000004],
]) {
  test(`portable reference imports reject ${label} before extraction or persistence`, { timeout: 30000 }, async (t) => {
    const app = await fixture(t), before = await readdir(app.store.root), saved = await app.store.list('suites');
    let invocations = 0;
    /** Records and rejects extraction so aggregate rejection must precede native work and reference writes. */
    app.invoke = async () => { invocations++; throw new Error('Oversized reference bundles must not invoke extraction'); };
    const files = referenceFiles(byteCounts), definition = { name: 'Oversized reference aggregate', version: 'v1', cases: [{ prompt: 'Read references' }] };
    assert.ok(byteCounts.every((count) => count < 5000000));
    assert.equal(files.reduce((total, file) => total + file.base64.length, 0), encodedBytes);
    assert.ok(Buffer.byteLength(JSON.stringify({ suite: definition, referenceFiles: files })) < MAX_SUITE_BUNDLE_BYTES);
    await assert.rejects(app.call('eval_import_suite', { suite: definition, referenceFiles: files }), /Portable reference bundle exceeds the 16,000,000-byte base64 limit/);
    assert.equal(invocations, 0);
    assert.deepEqual(await readdir(app.store.root), before);
    assert.deepEqual(await app.store.list('suites'), saved);
  });
}

test('the exact 16,000,000-byte reference budget roundtrips and exports reject four additional encoded bytes', { timeout: 30000 }, async (t) => {
  const source = await fixture(t), destination = await fixture(t);
  const files = referenceFiles([4000000, 4000000, 3999996]);
  assert.ok(files[0].base64.endsWith('==') && files[1].base64.endsWith('=='));
  assert.equal(files.reduce((total, file) => total + file.base64.length, 0), 16000000);
  const { suite } = await source.call('eval_import_suite', { suite: { name: 'Exact reference aggregate', version: 'v1', cases: [{ prompt: 'Read references' }] }, referenceFiles: files });
  const exported = await source.call('eval_export_suite', { suiteId: suite.id });
  assert.deepEqual(exported.referenceFiles.map(({ attachmentId, ...file }) => file), files);
  const imported = (await destination.call('eval_import_suite', { json: exported.json })).suite;
  assert.deepEqual(imported.attachments, suite.attachments);
  assert.deepEqual((await destination.call('eval_export_suite', { suiteId: imported.id })).referenceFiles, exported.referenceFiles);
  await source.call('eval_add_reference_file', { suiteId: suite.id, name: 'extra.txt', mimeType: 'text/plain', base64: Buffer.from('x').toString('base64') });
  await assert.rejects(source.call('eval_export_suite', { suiteId: suite.id }), /Portable reference bundle exceeds the 16,000,000-byte base64 limit/);
});

test('portable suites above the former 16 MiB JSON ceiling roundtrip with all reference bytes', { timeout: 30000 }, async (t) => {
  const texts = new Map(), source = await fixture(t, texts), destination = await fixture(t, texts);
  const attachments = [];
  await mkdir(join(source.store.root, 'references'));
  for (const [index, count] of [4999998, 4999998, 1999998].entries()) {
    const bytes = Buffer.alloc(count, 65 + index), sha256 = createHash('sha256').update(bytes).digest('hex');
    const name = `file${index}.txt`, storedFilename = `${sha256}.txt`, text = String.fromCharCode(65 + index).repeat(16000);
    texts.set(name, text); await writeFile(join(source.store.root, 'references', storedFilename), bytes);
    attachments.push({ id: randomUUID(), name, kind: 'text', text, storedFilename, byteCount: count, sha256 });
  }
  const { suite } = await source.call('eval_save_suite', { suite: { name: 'Portable boundary', version: 'v1', attachments,
    cases: Array.from({ length: 30 }, () => ({ id: randomUUID(), prompt: 'p'.repeat(31000) })) } });
  const exported = await source.call('eval_export_suite', { suiteId: suite.id });
  assert.ok(Buffer.byteLength(exported.json) > 16 * 1024 * 1024);
  assert.ok(Buffer.byteLength(exported.json) <= MAX_SUITE_BUNDLE_BYTES);
  assert.ok(Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'eval_import_suite', arguments: { json: exported.json } } })) < MAX_REQUEST_BYTES);
  const imported = (await destination.call('eval_import_suite', { json: exported.json })).suite;
  assert.deepEqual(imported.attachments, suite.attachments);
  assert.deepEqual(imported.cases, suite.cases);
  const roundtrip = await destination.call('eval_export_suite', { suiteId: imported.id });
  assert.deepEqual(roundtrip.referenceFiles, exported.referenceFiles);
});

test('accepted deep drafts export compact JSON and reimport with all retained content', { timeout: 30000 }, async (t) => {
  const source = await fixture(t), destination = await fixture(t);
  let field = outputFieldTree(4, true);
  for (let depth = 0; depth < 400; depth++) field = { name: 'branch', type: 'object', children: [field] };
  const { suite } = await source.call('eval_import_suite', { suite: { name: 'Deep draft', version: 'v1', cases: [{ prompt: 'Retain draft fields' }], features: { outputFields: [field] } } });
  assert.ok(Buffer.byteLength(JSON.stringify(suite)) < 1024 * 1024);
  assert.ok(Buffer.byteLength(JSON.stringify(suite, null, 2)) > MAX_SUITE_BUNDLE_BYTES);
  const exported = await source.call('eval_export_suite', { suiteId: suite.id });
  assert.equal(exported.json, JSON.stringify(exported.suite));
  assert.ok(Buffer.byteLength(exported.json) < MAX_SUITE_BUNDLE_BYTES);
  assert.equal(exported.filename, 'Deep-draft.json');
  assert.equal(exported.revision, suite.revision);
  const imported = (await destination.call('eval_import_suite', { json: exported.json })).suite;
  assert.equal(imported.id, suite.id);
  assert.equal(imported.revision, suite.revision);
  assert.equal(JSON.stringify(imported.features.outputFields), JSON.stringify(suite.features.outputFields));
  assert.equal((await destination.call('eval_export_suite', { suiteId: imported.id })).json, exported.json);
});

test('the complete structured portable bundle is bounded before extraction or reference writes', { timeout: 30000 }, async (t) => {
  const app = await fixture(t), before = await readdir(app.store.root), saved = await app.store.list('suites');
  let invocations = 0;
  /** Records and rejects extraction so the test proves bundle admission fails before any native work. */
  app.invoke = async () => { invocations++; throw new Error('Oversized bundles must not invoke extraction'); };
  const base64 = Buffer.alloc(4999998, 65).toString('base64');
  const files = Array.from({ length: 6 }, (_, index) => ({ name: `file${index}.txt`, mimeType: 'text/plain', base64 }));
  await assert.rejects(app.call('eval_import_suite', { suite: { name: 'Oversized references', version: 'v1', cases: [{ prompt: 'Read references' }] }, referenceFiles: files }), /Portable suite bundle exceeds 32 MiB/);
  assert.equal(invocations, 0);
  assert.deepEqual(await readdir(app.store.root), before);
  assert.deepEqual(await app.store.list('suites'), saved);
});
