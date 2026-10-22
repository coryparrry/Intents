import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { importCases } from '../server/case-import.mjs';

function source(format, prompt, expected = '\rExact answer\r') {
  const row = { prompt, expected };
  if (format === 'json') return JSON.stringify([row]);
  if (format === 'jsonl') return JSON.stringify(row);
  const quoted = (value) => `"${value.replaceAll('"', '""')}"`;
  return `prompt,expected\r\n${quoted(prompt)},${quoted(expected)}\r\n`;
}
for (const format of ['json', 'jsonl', 'csv']) {
  test(`${format} case imports preserve prompt content while still rejecting blank prompts`, () => {
    const prompt = '\t  print("READY")  \n';
    for (const appFormat of [true, false]) {
      const imported = importCases({ format, text: source(format, prompt) }, appFormat);
      assert.equal(imported[0].prompt, prompt);
      assert.equal(imported[0].expected, '\rExact answer\r');
      assert.throws(() => importCases({ format, text: source(format, ' \t\r\n ') }, appFormat), /empty prompt/);
    }
  });
}
for (const appFormat of [true, false]) {
  test(`${appFormat ? 'app' : 'legacy'} public case imports validate the preserved prompt and retain the suite on rejection`, async (t) => {
    const directory = await mkdtemp(join(tmpdir(), 'case-import-content-'));
    const app = new EvaluationApp({ dataDir: directory, invoke: async () => { throw new Error('Unexpected inference'); } });
    await app.init();
    t.after(async () => { await app.shutdown(); await rm(directory, { recursive: true, force: true }); });
    const definition = { name: 'Preserved import', ...(appFormat ? { version: 'v1', scoringMode: 'review' } : {}),
      cases: [{ id: randomUUID(), prompt: 'Existing prompt', expected: '', ...(appFormat ? {} : { scoring: 'none' }) }] };
    const { suite } = await app.call('eval_save_suite', { suite: definition });
    const maximum = appFormat ? 32000 : 8192;
    const oversized = ' '.repeat(maximum) + 'x';
    await assert.rejects(app.call('eval_import_cases', {
      suiteId: suite.id, format: 'csv', text: source('csv', oversized), expectedRevision: suite.revision,
    }), /prompt/);
    assert.deepEqual(await app.store.read('suites', suite.id), suite);
    const prompt = '\n  Retain indentation and trailing space  \t';
    const imported = await app.call('eval_import_cases', {
      suiteId: suite.id, format: 'csv', text: source('csv', prompt), expectedRevision: suite.revision,
    });
    assert.equal(imported.importedCount, 1);
    assert.equal(imported.suite.cases[1].prompt, prompt);
    assert.equal(imported.suite.cases[1].expected, '\rExact answer\r');
    const exported = await app.call('eval_export_suite', { suiteId: suite.id });
    assert.equal(exported.suite.cases[1].prompt, prompt);
    assert.equal(exported.suite.cases[1].expected, '\rExact answer\r');
  });
}

test('CSV blank separator rows do not consume the 100-case import budget', () => {
  const rows = Array.from({ length: 100 }, (_, index) => `Case ${index},READY`);
  const text = `prompt,expected\r\n${rows.join('\r\n\r\n')}\r\n`;
  const imported = importCases({ format: 'csv', text }, true);
  assert.equal(imported.length, 100);
  assert.equal(imported[99].prompt, 'Case 99');
  assert.throws(() => importCases({ format: 'csv', text: `${text}One too many,READY\r\n` }, true), /100 rows/);
});
