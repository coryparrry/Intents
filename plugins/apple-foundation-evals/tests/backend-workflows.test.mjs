import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { workflowDispatch } from '../server/workflows.mjs';
import { WORKFLOW_TOOLS } from '../server/workflow-tools.mjs';
import { portableSuite, revision } from '../server/app-format.mjs';
import { validateSchema } from '../server/app-schema.mjs';

async function fixture(t, invoke = async () => { throw new Error('Unexpected native call'); }) {
  const directory = await mkdtemp(join(tmpdir(), 'eval-workflows-'));
  const app = new EvaluationApp({ dataDir: directory, resolveBinary: async () => '/fixture', invoke });
  await app.init(); t.after(async () => { await app.shutdown(); await rm(directory, { recursive: true, force: true }); });
  const { suite } = await app.call('eval_save_suite', { suite: { name: 'Instruction quality', version: 'v1', instructions: 'Answer briefly', scoringMode: 'review', cases: [{ id: randomUUID(), name: 'Fruit', prompt: 'Name a fruit', expected: '' }] } });
  return { app, suite };
}
function rawRun(source, instructions = source.instructions, runID = randomUUID()) {
  const result = { id: randomUUID(), caseID: source.cases[0].id, caseName: 'Fruit', repetition: 1, prompt: 'Name a fruit', expected: '', response: 'apple', status: 'unscored', durationMilliseconds: 8, usage: { inputTokens: 5, outputTokens: 1 }, workflowTrace: { spans: [] } };
  const run = { id: runID, suiteID: source.id, suiteName: source.name, suiteVersion: source.version, instructions, criteria: '', scoringMode: 'review', repetitions: 1, startedAt: new Date().toISOString(), completedAt: new Date().toISOString(), cancelled: false, results: [result], suiteDefinition: { formatVersion: 1, ...portableSuite(source), instructions } };
  const assessment = { id: randomUUID(), runID: run.id, createdAt: new Date().toISOString(), origin: 'initialRun', judge: { mode: 'sameModel' }, promptVersion: 'fixture', rubric: 'Correct answer', passingScore: 3, samples: [{ id: randomUUID(), sampleID: result.id, status: 'failed', score: 2 }], durationMilliseconds: 4, cost: { amount: 0 } };
  run.assessments = [assessment]; run.selectedAssessmentID = assessment.id;
  return run;
}
async function importRun(app, source) { const raw = rawRun(source); const { run } = await app.call('eval_import_run', { run: raw }); return { raw, run }; }
const dispatch = (app, name, args) => app.call(name, args);

test('workflow schemas bound IDs, corrected app scores and unknown arguments', () => {
  assert.equal(new Set(WORKFLOW_TOOLS.map((item) => item.name)).size, WORKFLOW_TOOLS.length);
  const schema = WORKFLOW_TOOLS.find((item) => item.name === 'eval_correct_judgment').inputSchema;
  const value = { runId: randomUUID(), sampleId: randomUUID(), correctedStatus: 'passed', reason: 'The response matched', correctedScore: 4 };
  validateSchema(value, schema);
  assert.throws(() => validateSchema({ ...value, correctedScore: 5 }, schema));
  assert.throws(() => validateSchema({ ...value, remoteJudge: true }, schema));
});
test('assessment selection preserves original evidence and guards public revisions', async (t) => {
  const { app, suite } = await fixture(t); const { raw, run } = await importRun(app, suite);
  const second = { ...raw.assessments[0], id: randomUUID(), samples: [{ ...raw.assessments[0].samples[0], status: 'passed', score: 4 }] };
  const stored = { ...run, ownerPid: process.pid, appRun: { ...raw, assessments: [...raw.assessments, second] } };
  await app.store.write('runs', stored);
  const { ownerPid, ...visible } = stored;
  const selected = await dispatch(app, 'eval_select_assessment', { runId: run.id, assessmentId: second.id, expectedRevision: revision(visible) });
  assert.equal(selected.run.results[0].passed, true);
  assert.deepEqual(selected.run.appRun.results, raw.results);
  assert.deepEqual(selected.run.appRun.assessments[0], raw.assessments[0]);
  await assert.rejects(dispatch(app, 'eval_select_assessment', { runId: run.id, assessmentId: raw.assessments[0].id, expectedRevision: revision(visible) }), /Revision conflict/);
  await assert.rejects(dispatch(app, 'eval_select_assessment', { runId: run.id, assessmentId: randomUUID() }), /Assessment not found/);
});
test('human correction records native validation and never overwrites original judgment', async (t) => {
  let requests = 0;
  const { app, suite } = await fixture(t, async (_binary, request, options) => {
    requests++; assert.equal(request.operation, 'correct-judgment'); assert.ok(options.lease);
    const sample = request.run.assessments[0].samples[0];
    return { run: request.run, correction: { id: randomUUID(), runID: request.run.id, assessmentID: request.assessmentID, sampleID: request.sampleID, originalStatus: sample.status, originalScore: sample.score, correctedStatus: request.correctedStatus, correctedScore: request.correctedScore, reason: request.reason, createdAt: new Date().toISOString() } };
  });
  const { raw, run } = await importRun(app, suite);
  const args = { runId: run.id, sampleId: raw.results[0].id, correctedStatus: 'passed', correctedScore: 4, reason: 'Contains the requested fruit' };
  const result = await dispatch(app, 'eval_correct_judgment', args);
  assert.equal(result.correction.originalScore, 2); assert.equal(result.correction.correctedScore, 4);
  assert.deepEqual((await app.store.read('runs', run.id)).appRun, raw);
  assert.equal((await app.store.list('corrections')).length, 1); assert.equal(app.store.leases.size, 0);
  await assert.rejects(dispatch(app, 'eval_correct_judgment', { ...args, reason: '   ' }), /Explain why|reason must be a valid string/);
  await assert.rejects(dispatch(app, 'eval_correct_judgment', { ...args, sampleId: randomUUID() }), /Judgment not found/);
  assert.equal(requests, 1);
});
test('analysis forwards exact immutable app evidence and releases the lease on failure', async (t) => {
  let fail = false; const requests = [];
  const { app, suite } = await fixture(t, async (_binary, request, options) => {
    requests.push(request); assert.ok(options.lease);
    if (fail) return { status: 'failed', error: { message: 'native analysis failed', category: 'validation' } };
    return request.operation === 'analyze-run' ? { repeatability: { caseCount: 1 }, usage: { outputTokens: 1 } } : { compatible: true };
  });
  const { raw, run } = await importRun(app, suite); const baseline = await importRun(app, suite);
  const result = await dispatch(app, 'eval_analyze_run', { runId: run.id, baselineRunId: baseline.run.id });
  assert.deepEqual(requests[0].run, raw); assert.deepEqual(requests[1].baseline, baseline.raw);
  assert.equal(result.analysis.repeatability.caseCount, 1); assert.equal(result.comparison.compatible, true);
  fail = true; await assert.rejects(dispatch(app, 'eval_analyze_run', { runId: run.id }), /native analysis failed/);
  assert.equal(app.store.leases.size, 0); assert.equal(app.transientController, null);
});
test('stale baseline approval is rejected before native execution', async (t) => {
  const { app, suite } = await fixture(t); const { run } = await importRun(app, suite);
  await app.call('eval_save_suite', { suite: { ...suite, instructions: 'Answer in detail' }, expectedRevision: suite.revision });
  await assert.rejects(dispatch(app, 'eval_approve_baseline', { runId: run.id }), /complete current/);
});
test('baseline approvals preserve native contract, revoke older approval and feed release policy', async (t) => {
  const { app, suite } = await fixture(t, async (_binary, request) => request.operation === 'approve-baseline' ? { id: randomUUID(), runID: request.run.id, assessmentID: request.run.selectedAssessmentID, suiteRevision: 'native-revision', approvedAt: new Date().toISOString(), scoringContract: { digest: 'frozen-contract' } } : { report: { outcome: 0, runID: request.run.id, suiteID: request.suite.id, projectID: request.projectID }, markdown: 'Release passed', approval: request.approvedBaseline });
  const { run } = await importRun(app, suite);
  const first = await dispatch(app, 'eval_approve_baseline', { runId: run.id });
  const second = await dispatch(app, 'eval_approve_baseline', { runId: run.id });
  assert.ok((await app.store.read('baselines', first.baseline.id)).revokedAt);
  assert.deepEqual(second.baseline.scoringContract, { digest: 'frozen-contract' });
  const current = await dispatch(app, 'eval_get_baseline', { suiteId: suite.id }); assert.equal(current.baseline.id, second.baseline.id);
  const report = await dispatch(app, 'eval_release_report', { runId: run.id }); assert.equal(report.approval.id, second.baseline.id); assert.equal(report.markdown, 'Release passed');
});
function experiment(source, candidateInstructions) {
  const current = { id: randomUUID(), name: 'Current', instructions: source.instructions };
  const candidate = { id: randomUUID(), name: 'Candidate', instructions: candidateInstructions };
  return { id: randomUUID(), name: 'A/B', suiteRevision: 'native-revision', casesDigest: 'cases', scoringDigest: 'scoring', judgeDigest: 'judge', current, candidate, executionOrder: [current.id, candidate.id], runIDs: [] };
}
test('frozen experiment persists complete paired evidence only after lease release', async (t) => {
  let source; const { app, suite } = await fixture(t, async (_binary, request, options) => {
    if (request.operation === 'create-experiment') return experiment(source, request.candidateInstructions);
    assert.equal(request.operation, 'run-experiment');
    options.onEvent({ event: 'sample', runID: request.currentRunID, completed: 1, total: 2, result: rawRun(source).results[0] });
    return { current: rawRun(source, source.instructions, request.currentRunID), candidate: rawRun(source, request.experiment.candidate.instructions, request.candidateRunID), summary: { suggestedDecision: 'collectMoreEvidence', distinctCaseCoverage: 1 } };
  }); source = suite;
  const created = await dispatch(app, 'eval_create_experiment', { suiteId: suite.id, name: 'A/B', candidateInstructions: 'Return just the fruit', expectedRevision: suite.revision });
  const originalWrite = app.store.write.bind(app.store);
  app.store.write = async (kind, value) => { if (kind === 'runs' && value.appRun || kind === 'experiments' && value.status === 'completed') assert.equal(app.store.leases.size, 0); return originalWrite(kind, value); };
  const started = await dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id }); assert.equal(started.experiment.status, 'running');
  await app.active.promise;
  const complete = await dispatch(app, 'eval_get_experiment', { experimentId: created.experiment.id });
  assert.equal(complete.experiment.status, 'completed'); assert.equal(complete.runs.length, 2); assert.equal(complete.experiment.progress.completed, 1);
  const listed = await dispatch(app, 'eval_list_experiments', { suiteId: suite.id, projectId: suite.projectId }); assert.equal(listed.experiments[0].id, complete.experiment.id);
  assert.equal(complete.runs[0].suite.instructions, 'Answer briefly'); assert.equal(complete.runs[1].suite.instructions, 'Return just the fruit');
  await assert.rejects(dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id }), /new experiment/);
  await app.call('eval_save_suite', { suite: { ...suite, instructions: 'Edited during review' }, expectedRevision: suite.revision });
  await assert.rejects(dispatch(app, 'eval_decide_experiment', { experimentId: created.experiment.id, decision: 'adoptCandidate' }), /suite changed/);
});
test('cancelled native experiment releases lease and does not publish a partial pair', async (t) => {
  let source; const { app, suite } = await fixture(t, async (_binary, request, { signal }) => {
    if (request.operation === 'create-experiment') return experiment(source, request.candidateInstructions);
    return new Promise((resolve, reject) => { if (signal.aborted) reject(new Error('Cancelled')); else signal.addEventListener('abort', () => reject(new Error('Cancelled')), { once: true }); });
  }); source = suite;
  const created = await dispatch(app, 'eval_create_experiment', { suiteId: suite.id, name: 'A/B', candidateInstructions: 'Just fruit' });
  await dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id });
  const cancelled = await dispatch(app, 'eval_cancel_experiment', { experimentId: created.experiment.id });
  assert.equal(cancelled.experiment.status, 'cancelled'); assert.equal(cancelled.runs.length, 0); assert.equal(app.store.leases.size, 0); assert.equal(app.active, null);
});
test('paired publication rollback removes one-sided evidence on failure', async (t) => {
  let source; const { app, suite } = await fixture(t, async (_binary, request) => request.operation === 'create-experiment' ? experiment(source, request.candidateInstructions) : { current: rawRun(source, source.instructions, request.currentRunID), candidate: rawRun(source, request.experiment.candidate.instructions, request.candidateRunID), summary: {} }); source = suite;
  const created = await dispatch(app, 'eval_create_experiment', { suiteId: suite.id, name: 'A/B', candidateInstructions: 'Just fruit' });
  const originalWrite = app.store.write.bind(app.store); let count = 0;
  app.store.write = async (kind, value) => { if (kind === 'runs' && ++count === 2) throw new Error('disk full'); return originalWrite(kind, value); };
  await dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id }); await app.active.promise;
  const failed = await dispatch(app, 'eval_get_experiment', { experimentId: created.experiment.id });
  assert.equal(failed.experiment.status, 'failed'); assert.match(failed.experiment.error, /disk full/); assert.equal((await app.store.list('runs')).length, 0);
});
test('adoption guards revisions and restores the suite if saving the decision fails', async (t) => {
  let source; const { app, suite } = await fixture(t, async (_binary, request) => request.operation === 'create-experiment' ? experiment(source, request.candidateInstructions) : { current: rawRun(source, source.instructions, request.currentRunID), candidate: rawRun(source, request.experiment.candidate.instructions, request.candidateRunID), summary: {} }); source = suite;
  const created = await dispatch(app, 'eval_create_experiment', { suiteId: suite.id, name: 'A/B', candidateInstructions: 'Just fruit' });
  await dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id }); await app.active.promise;
  const completed = await dispatch(app, 'eval_get_experiment', { experimentId: created.experiment.id });
  const originalWrite = app.store.write.bind(app.store);
  app.store.write = async (kind, value) => { if (kind === 'experiments' && value.experiment.decision) throw new Error('disk full'); return originalWrite(kind, value); };
  await assert.rejects(dispatch(app, 'eval_decide_experiment', { experimentId: created.experiment.id, decision: 'adoptCandidate', expectedRevision: completed.experiment.revision }), /disk full/);
  assert.deepEqual(await app.store.read('suites', suite.id), suite);
  app.store.write = originalWrite;
  const adopted = await dispatch(app, 'eval_decide_experiment', { experimentId: created.experiment.id, decision: 'adoptCandidate', expectedRevision: completed.experiment.revision });
  assert.equal(adopted.suite.instructions, 'Just fruit'); assert.equal(adopted.experiment.experiment.decision, 'adoptCandidate');
});
test('project release reports include missing evidence and delegate app aggregation', async (t) => {
  const requests = []; const { app, suite } = await fixture(t, async (_binary, request) => {
    requests.push(request);
    if (request.operation === 'release-check') return { report: { suiteID: request.suite.id, projectID: request.projectID, outcome: request.run ? 0 : 20, summary: 'Evidence missing' }, markdown: 'Suite report' };
    assert.equal(request.operation, 'project-release-check'); return { report: { projectID: request.projectID, outcome: 0, suites: request.suites }, markdown: 'Project report' };
  });
  const result = await dispatch(app, 'eval_project_release_report', { projectId: suite.projectId });
  assert.equal(result.markdown, 'Project report'); assert.ok(result.report.suites.some((item) => item.suiteID === suite.id && item.report.outcome === 20));
  assert.equal(requests.at(-1).suites.some((item) => 'markdown' in item), false);
  assert.equal(await workflowDispatch(app, 'unknown', {}), undefined);
});
for (const cooperative of [false, true]) test(`experiment cancellation retains actual sample evidence (${cooperative ? 'cooperative terminal' : 'forced fallback'})`, async (t) => {
  let source; let announce; let rawCurrent; let rawCandidate;
  const started = new Promise((resolve) => { announce = resolve; });
  const { app, suite } = await fixture(t, async (_binary, request, options) => {
    if (request.operation === 'create-experiment') return experiment(source, request.candidateInstructions);
    rawCurrent = rawRun(source, source.instructions, request.currentRunID);
    rawCandidate = rawRun(source, request.experiment.candidate.instructions, request.candidateRunID);
    options.onEvent({ event: 'liveResponse', runID: request.currentRunID, value: { text: 'ap', caseID: source.cases[0].id } });
    const event = { event: 'sample', runID: request.currentRunID, completed: 1, total: 2, result: rawCurrent.results[0] };
    options.onEvent(event); options.onEvent(event);
    announce();
    return new Promise((resolve, reject) => options.signal.addEventListener('abort', () => {
      if (cooperative) { rawCurrent.cancelled = true; rawCandidate.cancelled = true; rawCandidate.results = []; rawCandidate.assessments = []; delete rawCandidate.selectedAssessmentID; resolve({ current: rawCurrent, candidate: rawCandidate, summary: { suggestedDecision: 'inconclusive' } }); }
      else reject(new Error('Evaluation cancelled after worker fallback'));
    }, { once: true }));
  }); source = suite;
  const created = await dispatch(app, 'eval_create_experiment', { suiteId: suite.id, name: 'A/B', candidateInstructions: 'Just fruit' });
  await dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id }); await started;
  const cancelled = await dispatch(app, 'eval_cancel_experiment', { experimentId: created.experiment.id });
  const record = cancelled.experiment;
  assert.equal(record.status, 'cancelled'); assert.equal(record.partialResults.length, 1);
  assert.deepEqual(record.partialResults[0].appSample, rawCurrent.results[0]); assert.equal(record.partialResults[0].result.response, 'apple');
  assert.equal(record.partialResults[0].runID, rawCurrent.id); assert.equal(record.liveResponse.text, 'ap');
  if (cooperative) assert.deepEqual(record.partialRuns, [rawCurrent, rawCandidate]); else assert.equal(record.partialRuns, undefined);
  assert.equal(cancelled.runs.length, 0); assert.equal((await app.store.list('runs')).length, 0); assert.equal(app.store.leases.size, 0); assert.equal(app.active, null);
});
test('retry clears current partial state and preserves bounded previous attempt evidence', async (t) => {
  let source; let attempt = 0; let previous;
  const { app, suite } = await fixture(t, async (_binary, request, options) => {
    if (request.operation === 'create-experiment') return experiment(source, request.candidateInstructions);
    const current = rawRun(source, source.instructions, request.currentRunID); const candidate = rawRun(source, request.experiment.candidate.instructions, request.candidateRunID);
    const durable = await app.store.read('experiments', request.experiment.id);
    assert.deepEqual(durable.plannedRunIDs, [request.currentRunID, request.candidateRunID]);
    options.onEvent({ event: 'sample', runID: request.currentRunID, completed: 1, total: 2, result: current.results[0] });
    options.onEvent({ event: 'sample', runID: request.candidateRunID, completed: 2, total: 2, result: candidate.results[0] });
    if (++attempt === 1) { previous = [current.results[0], candidate.results[0]]; throw new Error('Worker failure after both samples'); }
    assert.equal(durable.partialResults, undefined); assert.equal(durable.partialRuns, undefined); assert.equal(durable.error, undefined); assert.equal(durable.finishedAt, undefined); assert.equal(durable.progress, undefined);
    return { current, candidate, summary: {} };
  }); source = suite;
  const created = await dispatch(app, 'eval_create_experiment', { suiteId: suite.id, name: 'A/B', candidateInstructions: 'Just fruit' });
  await dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id }); await app.active.promise;
  await dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id }); await app.active.promise;
  const result = await dispatch(app, 'eval_get_experiment', { experimentId: created.experiment.id });
  assert.equal(result.experiment.status, 'completed'); assert.equal(result.experiment.partialResults.length, 2);
  assert.deepEqual(result.experiment.attemptHistory[0].partialResults.map((item) => item.appSample), previous);
  assert.notEqual(result.experiment.partialResults[0].appSample.id, previous[0].id);
});
test('staged variants stay private until both writes commit and deleted variants remain discoverable', async (t) => {
  let source; const { app, suite } = await fixture(t, async (_binary, request) => request.operation === 'create-experiment' ? experiment(source, request.candidateInstructions) : { current: rawRun(source, source.instructions, request.currentRunID), candidate: rawRun(source, request.experiment.candidate.instructions, request.candidateRunID), summary: {} }); source = suite;
  const created = await dispatch(app, 'eval_create_experiment', { suiteId: suite.id, name: 'A/B', candidateInstructions: 'Just fruit' });
  const originalWrite = app.store.write.bind(app.store); let writes = 0;
  app.store.write = async (kind, value) => {
    await originalWrite(kind, value);
    if (kind === 'runs') {
      writes++; assert.equal(value.experimentId, created.experiment.id); assert.equal(value.publicationState, 'pending');
      await assert.rejects(app.readPublicRun(value.id), /not been committed/); assert.equal((await app.runs()).length, 0);
      const record = await app.store.read('experiments', created.experiment.id); assert.ok(record.plannedRunIDs.includes(value.id));
    }
  };
  await dispatch(app, 'eval_run_experiment', { experimentId: created.experiment.id }); await app.active.promise;
  app.store.write = originalWrite;
  const completed = await dispatch(app, 'eval_get_experiment', { experimentId: created.experiment.id }); assert.equal(writes, 2); assert.equal((await app.runs()).length, 2);
  await dispatch(app, 'eval_delete_run', { runId: completed.runs[0].id });
  const retained = await dispatch(app, 'eval_get_experiment', { experimentId: created.experiment.id }); assert.deepEqual(retained.missingRunIds, [completed.runs[0].id]); assert.equal(retained.runs.length, 1);
  await assert.rejects(dispatch(app, 'eval_decide_experiment', { experimentId: created.experiment.id, decision: 'adoptCandidate' }), /Both committed experiment runs/);
});
