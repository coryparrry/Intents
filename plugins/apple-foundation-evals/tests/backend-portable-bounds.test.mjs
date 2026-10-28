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

test('the complete structured portable bundle is bounded before extraction or reference writes', { timeout: 30000 }, async (t) => {
  const app = await fixture(t), before = await readdir(app.store.root);
  let invocations = 0;
  /** Records and rejects extraction so the test proves bundle admission fails before any native work. */
  app.invoke = async () => { invocations++; throw new Error('Oversized bundles must not invoke extraction'); };
  const base64 = Buffer.alloc(4999998, 65).toString('base64');
  const files = Array.from({ length: 6 }, (_, index) => ({ name: `file${index}.txt`, mimeType: 'text/plain', base64 }));
  await assert.rejects(app.call('eval_import_suite', { suite: { name: 'Oversized references', version: 'v1', cases: [{ prompt: 'Read references' }] }, referenceFiles: files }), /Portable suite bundle exceeds 32 MiB/);
  assert.equal(invocations, 0);
  assert.deepEqual(await readdir(app.store.root), before);
});
