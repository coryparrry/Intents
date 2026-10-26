import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { suite } from '../server/validation.mjs';
import { appSuite } from '../server/app-format.mjs';

test('both plugin normalization routes explicitly reject document evidence and rubric overrides', () => {
  for (const marker of [
    { documentEvidence: { formatVersion: 1 } },
    { criteriaOverride: ['A case-specific requirement'] },
    { prompt: { format: 'document-case-v1', text: 'Question' } },
  ]) {
    const input = { name: 'Document suite', cases: [{ id: randomUUID(), name: 'Question', prompt: 'Question', expected: 'Answer', ...marker }] };
    assert.throws(() => suite(input, randomUUID), /Document suites.*native Intents app/);
    assert.throws(() => appSuite(input, randomUUID), /Document suites.*native Intents app/);
    assert.deepEqual(input.cases[0], { id: input.cases[0].id, name: 'Question', prompt: 'Question', expected: 'Answer', ...marker });
  }
});
