import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { renderNativeInspector } from '../ui/native-results.js';
import { applyAssessment } from '../server/app-format.mjs';

function render(t, tab, run, result) {
  const dom = new JSDOM('<!doctype html><main></main>');
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'Option');
  Object.defineProperty(globalThis, 'Option', { configurable: true, value: dom.window.Option });
  t.after(() => {
    dom.window.close();
    if (previous) Object.defineProperty(globalThis, 'Option', previous);
    else delete globalThis.Option;
  });
  const node = (tag, text, className) => {
    const element = dom.window.document.createElement(tag);
    if (text != null) element.textContent = String(text);
    if (className) element.className = className;
    return element;
  };
  const ctx = {
    state: { inspectorTab: tab, imported: false, run }, node,
    segmented: () => node('nav'), button: text => node('button', text),
    duration: value => value == null ? '—' : `${value} ms`, date: value => value,
  };
  const inspector = dom.window.document.querySelector('main');
  renderNativeInspector(ctx, inspector, run, result);
  return inspector;
}
const details = element => Object.fromEntries([...element.querySelectorAll('dt')]
  .map(label => [label.textContent, label.nextElementSibling.textContent]));
const original = () => ({
  id: 'sample-id', caseID: 'case-id', repetition: 1, response: 'Subject response',
  rationale: 'Original rationale', judgeIdentity: { requestedModelID: 'old-model' },
  judgeTrace: { prompt: 'Original judge prompt' },
  judgeUsage: { inputTokens: 101, outputTokens: 102 }, judgeDurationMilliseconds: 103,
});
function fixture(assessment) {
  const sample = original();
  const appRun = { results: [sample], assessments: [assessment], selectedAssessmentID: assessment.id };
  const results = applyAssessment(appRun, [{ caseId: 'case-id', repetition: 1, score: 1,
    passed: false, response: sample.response, appSample: sample }]);
  return { run: { appRun, results, suite: { scoringMode: 'modelJudge' } }, result: results[0], sample };
}

test('Tools inspector displays captured reference, custom, builtin and Spotlight evidence', t => {
  const sample = original();
  sample.toolCalls = [{ toolName: 'reference_lookup', outcome: 'completed' }];
  sample.featureTrace = {
    customToolCalls: [{ toolName: 'lookup_inventory', output: 'custom-output', outcome: 'succeeded' }],
    builtinToolCalls: [{ toolName: 'inspect_image', output: 'builtin-output' }],
    spotlightSearch: { queryCount: 1, replyCount: 1, collectionComplete: true },
  };
  const before = structuredClone(sample);
  const inspector = render(t, 'tools', {}, { appSample: sample });
  for (const text of ['reference_lookup', 'lookup_inventory', 'custom-output', 'inspect_image',
    'builtin-output', 'Spotlight search evidence', 'queryCount']) assert.ok(inspector.textContent.includes(text), text);
  assert.ok(!inspector.textContent.includes('No tool'));
  assert.deepEqual(sample, before, 'Rendering must preserve the saved subject evidence');
});

test('A custom-tool-only sample never claims that no tools were called', t => {
  const inspector = render(t, 'tools', {}, { appSample: {
    featureTrace: { customToolCalls: [{ toolName: 'lookup_inventory', outcome: 'rejected' }] },
  } });
  assert.ok(inspector.textContent.includes('lookup_inventory'));
  assert.ok(inspector.textContent.includes('rejected'));
  assert.ok(!inspector.textContent.includes('No tool'));
});

test('Selected assessment displays its own judge, duration, usage and prompt alongside its score', t => {
  const { run, result, sample } = fixture({ id: 'assessment-id', judge: { requestedModelID: 'new-model' },
    scoringContract: { scoringMode: 'modelJudge' }, samples: [{ sampleID: 'sample-id', status: 'passed', score: 4,
      rationale: 'New rationale', trace: { prompt: 'New judge prompt' },
      usage: { inputTokens: 201, outputTokens: 202 }, durationMilliseconds: 203 }] });
  const before = structuredClone(sample);
  const inspector = render(t, 'judge', run, result), rows = details(inspector);
  assert.equal(rows.Score, '4/4'); assert.equal(rows.Rationale, 'New rationale');
  assert.equal(rows.Duration, '203 ms'); assert.equal(rows.inputTokens, '201');
  assert.equal(rows.outputTokens, '202'); assert.match(rows.Judge, /new-model/);
  assert.ok(inspector.textContent.includes('New judge prompt'));
  for (const stale of ['old-model', 'Original rationale', 'Original judge prompt'])
    assert.ok(!inspector.textContent.includes(stale), stale);
  assert.deepEqual(sample, before);
});

test('Missing selected sample evidence stays explicitly unavailable without falling back to original judge data', t => {
  const { run, result } = fixture({ id: 'assessment-id', judge: { requestedModelID: 'new-model' }, samples: [] });
  const inspector = render(t, 'judge', run, result), rows = details(inspector);
  assert.equal(rows.Score, '—'); assert.equal(rows.Duration, '—');
  assert.equal(rows.inputTokens, undefined);
  assert.ok(inspector.textContent.includes('no recorded rationale'));
  assert.ok(inspector.textContent.includes('No judge trace was recorded'));
  for (const stale of ['old-model', 'Original rationale', 'Original judge prompt'])
    assert.ok(!inspector.textContent.includes(stale), stale);
});

test('Unavailable selected assessment and mixed observed judges are never mislabeled as the original single judge', t => {
  const { run, result } = fixture({ id: 'assessment-id', judge: { requestedModelID: 'new-model' },
    observedJudgeIdentities: [{ reportedModelID: 'provider-a' }, { reportedModelID: 'provider-b' }],
    samples: [{ sampleID: 'sample-id', status: 'passed', score: 4 }] });
  const inspector = render(t, 'judge', run, result), rows = details(inspector);
  assert.match(rows.Judge, /per-sample association is unavailable/);
  assert.match(rows['Assessment judge identities'], /provider-a/);
  assert.match(rows['Assessment judge identities'], /provider-b/);
  const missing = { ...run, appRun: { ...run.appRun, assessments: [] } };
  const missingResult = { ...result, trace: {}, assessmentSample: null };
  const unavailable = render(t, 'judge', missing, missingResult);
  assert.ok(unavailable.textContent.includes('selected assessment is unavailable'));
  assert.ok(!unavailable.textContent.includes('old-model'));
});

test('Historical samples without assessment selection continue to show their original recorded judge evidence', t => {
  const inspector = render(t, 'judge', { suite: { scoringMode: 'modelJudge' } }, { appSample: original(), score: 1 });
  const rows = details(inspector);
  assert.match(rows.Judge, /old-model/); assert.equal(rows.Duration, '103 ms');
  assert.equal(rows.inputTokens, '101'); assert.ok(inspector.textContent.includes('Original judge prompt'));
});
