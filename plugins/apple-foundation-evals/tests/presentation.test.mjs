import test from 'node:test';
import assert from 'node:assert/strict';
import { resultKey, outcome, caseTitle, resultTitle, comparisonMatches, runMetrics, visibleResults, selectedResult, transcriptEntries } from '../ui/presentation.js';
const result = (caseId, passed, durationMs, extra = {}) => ({ caseId, repetition: 1, prompt: `Prompt ${caseId}`, response: `Answer ${caseId}`, passed, durationMs, trace: { transcript: [] }, ...extra });
const run = { suite: { cases: ['exact', 'wrong', 'capture', 'error'].map(id => ({ id })), repetitions: 1 }, results: [
  result('exact', true, 100), result('wrong', false, 300), result('capture', null, 200), result('error', false, 50, { trace: { error: { message: 'Unavailable' }, transcript: [] } })
] };
test('report counts errors once and calculates pass rate from persisted boolean outcomes', () => {
  const metrics = runMetrics(run);
  assert.deepEqual(metrics, { total: 4, planned: 4, passed: 1, failed: 1, errors: 1, unscored: 1, passRate: 1 / 3, averageLatency: 162.5, longestLatency: 300 });
  assert.equal(outcome(run.results[3]), 'Error');
});
test('empty/unscored runs have no pass rate and missing durations are not invented', () => {
  const metrics = runMetrics({ results: [result('capture', null, undefined)] });
  assert.equal(metrics.passRate, null); assert.equal(metrics.averageLatency, null); assert.equal(metrics.longestLatency, null);
  assert.equal(runMetrics({}).total, 0);
});
test('result filters and search compose across case names, prompts and responses', () => {
  assert.deepEqual(visibleResults(run, 'Passed').map(resultKey), ['exact:1']);
  assert.deepEqual(visibleResults(run, 'Failed').map(resultKey), ['wrong:1']);
  assert.deepEqual(visibleResults(run, 'Issues').map(resultKey), ['capture:1', 'error:1']);
  assert.deepEqual(visibleResults(run, 'All', ' ANSWER wrong ').map(resultKey), ['wrong:1']);
  assert.equal(visibleResults(run, 'Passed', 'wrong').length, 0);
});
test('inspector falls back within the visible filter, never to a hidden result', () => {
  const visible = visibleResults(run, 'Issues');
  assert.equal(selectedResult(run, 'exact:1', visible).caseId, 'capture');
  assert.equal(selectedResult(run, 'error:1', visible).caseId, 'error');
  assert.equal(selectedResult(run, 'exact:1', []), null);
});
test('case IDs retain meaningful names and UUID cases get readable stable-position labels', () => {
  assert.equal(caseTitle({ id: 'instruction-following' }), 'Instruction Following');
  assert.equal(caseTitle({ id: 'case-2' }, 1), 'Case 2');
  assert.equal(caseTitle({ caseId: 'aa6e969a-b685-4c0b-90f4-ba05c66c927b' }, 2), 'Case 3');
});
test('transcript renders real Apple text entries and retains non-text evidence in raw data', () => {
  const asset = { role: 'response', contents: [{ text: 'Actual response' }, { asset: 'opaque' }] };
  const entries = transcriptEntries({ trace: { transcript: [{ role: 'instructions', contents: [{ text: 'Instruction' }] }, { role: 'user', contents: [{ text: 'Prompt' }] }, asset] } });
  assert.deepEqual(entries.map(entry => entry.role), ['Instructions', 'User', 'Model']);
  assert.deepEqual(entries.map(entry => entry.text), ['Instruction', 'Prompt', 'Actual response']);
  assert.equal(entries[2].raw, asset);
});

test('repeated UUID case names resolve against the saved suite for display and search', () => {
  const one = 'aa6e969a-b685-4c0b-90f4-ba05c66c927b', two = '221a75f9-616e-4143-98a1-71912400660f';
  const repeated = { suite: { cases: [{ id: one }, { id: two }], repetitions: 2 }, results: [result(one, true, 10), result(one, true, 20, { repetition: 2 }), result(two, true, 30), result(two, true, 40, { repetition: 2 })] };
  assert.equal(resultTitle(repeated, repeated.results[1]), 'Case 1');
  assert.deepEqual(visibleResults(repeated, 'All', 'Case 2').map(resultKey), [`${two}:1`, `${two}:2`]);
});
test('pending comparison data cannot replace newer suite or run selections', () => {
  const request = { sequence: 1, suiteId: 'suite-a', runIds: ['first', 'second'] };
  assert.equal(comparisonMatches(request, { ...request }), true);
  assert.equal(comparisonMatches(request, { ...request, sequence: 2 }), false);
  assert.equal(comparisonMatches(request, { ...request, suiteId: 'suite-b' }), false);
  assert.equal(comparisonMatches(request, { ...request, runIds: ['first', 'third'] }), false);
});
