import { randomUUID } from 'node:crypto';
import { id, nativeResult, suite } from './validation.mjs';
import { applyAssessment, portableSuite, revision, sampleEnvelope, validateAppEvidence } from './app-format.mjs';
import { health, saveSuite } from './workspace.mjs';
import { imageInputs } from './references.mjs';

const equalID = (left, right) => typeof left === 'string' && typeof right === 'string' && left.toLowerCase() === right.toLowerCase();
const timestamp = (value) => typeof value === 'number' ? (value + 978307200) * 1000 : Date.parse(value);
const publicRecord = ({ ownerPid, ...record }) => ({ ...record, revision: revision(record) });
const conflict = (record, expected) => { if (expected !== undefined && expected !== publicRecord(record).revision) throw new Error('Revision conflict: reload the current evidence before changing it'); };
const requireIdle = (app) => { if (app.active || app.transientController) throw new Error('An evaluation is already active'); };
const nativeValue = (value) => {
  if (!value || typeof value !== 'object') throw new Error('Invalid native workflow response');
  if (value.status === 'failed' && value.error) throw new Error(String(typeof value.error === 'object' ? value.error.message || 'Native workflow failed' : value.error).slice(0, 4096));
  return value;
};
async function readRun(app, key) {
  const run = await app.readPublicRun(id(key, 'runId'));
  if (!run.appRun) throw new Error('This workflow requires saved app-format evaluation evidence');
  validateAppEvidence(run.appRun);
  const evidence = run.appRun;
  if (evidence.developerExecution || evidence.execution?.configuration?.provider && evidence.execution.configuration.provider !== 'onDevice' || evidence.assessments?.some((item) => item.judge?.mode === 'connection')) throw new Error('Only local on-device evaluation evidence is supported');
  return run;
}
async function optional(app, kind, key) {
  try { return await app.store.read(kind, key); } catch (error) { if (/not found$/.test(error.message)) return null; throw error; }
}
async function native(app, request) {
  requireIdle(app);
  const key = randomUUID(); const controller = new AbortController();
  await app.store.acquireRunLock(key);
  app.transientController = controller;
  try {
    const binary = await app.resolveBinary({ dataDir: app.store.root, env: app.env, signal: controller.signal });
    return nativeValue(await app.invoke(binary, request, { signal: controller.signal, timeoutMs: app.timeoutMs, lease: app.store.lease(key) }));
  } finally {
    await app.store.releaseRunLock(key);
    if (app.transientController === controller) app.transientController = null;
  }
}
async function baselineFor(app, suiteId) {
  const approvals = (await app.store.list('baselines')).filter((item) => equalID(item.suiteId, suiteId) && !item.revokedAt);
  return approvals.sort((a, b) => timestamp(b.approvedAt) - timestamp(a.approvedAt))[0] || null;
}
async function experimentView(app, record) {
  const runIDs = record.experiment.runIDs || [];
  const runs = await Promise.all(runIDs.map((key) => optional(app, 'runs', id(key))));
  return { experiment: publicRecord(record), summary: record.summary || null, runs: runs.filter(Boolean).map(publicRecord), missingRunIds: runIDs.filter((_key, index) => !runs[index]) };
}
function runRecord(raw, source) {
  validateAppEvidence(raw);
  const results = raw.results.map((item) => sampleEnvelope(item, source.cases));
  const status = raw.cancelled ? 'cancelled' : raw.terminationReason || raw.results.some((item) => item.status === 'error') ? 'failed' : 'completed';
  nativeResult({ status: status === 'completed' ? status : 'failed', results, appRun: raw }, source);
  const date = (value) => typeof value === 'number' ? new Date((value + 978307200) * 1000).toISOString() : value;
  const startedAt = date(raw.startedAt); const finishedAt = date(raw.completedAt);
  if (!Number.isFinite(Date.parse(startedAt)) || !Number.isFinite(Date.parse(finishedAt))) throw new Error('Experiment runs require valid timestamps');
  return { id: id(raw.id), suiteId: source.id, projectId: source.projectId, suite: source, suiteRevision: source.revision || revision(source), status, startedAt, finishedAt, durationMs: Math.max(0, Date.parse(finishedAt) - Date.parse(startedAt)), results: applyAssessment(raw, results), appRun: raw };
}
async function executeExperiment(app, record, source, controller, lockId) {
  let terminal; let progress = Promise.resolve();
  const [currentRunID, candidateRunID] = record.plannedRunIDs;
  const onEvent = (event) => {
    if (!['sample', 'liveResponse'].includes(event.event)) return;
    progress = progress.then(async () => {
      if (!equalID(event.runID, currentRunID) && !equalID(event.runID, candidateRunID)) throw new Error('Experiment progress belongs to an unknown variant');
      if (event.event === 'sample') {
        const result = sampleEnvelope(event.result, source.cases);
        nativeResult({ status: 'failed', results: [result] }, source);
        if (!Number.isInteger(event.completed) || event.completed < 1 || event.completed > record.experiment.executionOrder.length || event.total !== record.experiment.executionOrder.length) throw new Error('Invalid experiment progress count');
        const samples = record.partialResults || [];
        if (samples.some((item) => equalID(item.runID, event.runID) && item.result.caseId === result.caseId && item.result.repetition === result.repetition)) return;
        if (samples.length >= record.experiment.executionOrder.length) throw new Error('Experiment progress exceeds its frozen sample count');
        record.partialResults = [...samples, { runID: event.runID, result, appSample: event.result }];
        record.progress = { completed: event.completed, total: event.total, runId: event.runID };
      } else if (event.value && typeof event.value === 'object') { record.liveResponse = event.value; return; }
      await app.store.write('experiments', record);
    }).catch((error) => { process.stderr.write(`Could not save experiment progress: ${error.message}\n`); });
  };
  try {
    const binary = await app.resolveBinary({ dataDir: app.store.root, env: app.env, signal: controller.signal });
    const value = nativeValue(await app.invoke(binary, { operation: 'run-experiment', suite: portableSuite(source), experiment: record.experiment, currentRunID, candidateRunID, emitEvents: true, images: await imageInputs(app, source) }, { signal: controller.signal, timeoutMs: app.timeoutMs, lease: app.store.lease(lockId), onEvent }));
    await progress;
    const candidate = suite({ ...source, instructions: record.experiment.candidate.instructions }, randomUUID);
    candidate.projectId = source.projectId; candidate.revision = revision(candidate);
    const currentRun = { ...runRecord(value.current, source), experimentId: record.id, publicationState: 'pending' }; const candidateRun = { ...runRecord(value.candidate, candidate), experimentId: record.id, publicationState: 'pending' };
    if (!equalID(currentRun.id, currentRunID) || !equalID(candidateRun.id, candidateRunID) || !equalID(currentRun.appRun.suiteID, source.id) || !equalID(candidateRun.appRun.suiteID, source.id)) throw new Error('Experiment run identities do not match the frozen suite');
    if (await optional(app, 'runs', currentRun.id) || await optional(app, 'runs', candidateRun.id)) throw new Error('Experiment run identity already exists');
    const cancelled = controller.signal.aborted || currentRun.status === 'cancelled' || candidateRun.status === 'cancelled';
    const incomplete = currentRun.status !== 'completed' || candidateRun.status !== 'completed';
    terminal = cancelled || incomplete
      ? { record: { ...record, partialRuns: [value.current, value.candidate], status: cancelled ? 'cancelled' : 'failed', ...(!cancelled ? { error: 'Both experiment variants must complete before publishing paired evidence.' } : {}), finishedAt: new Date().toISOString() }, runs: [] }
      : { record: { ...record, experiment: { ...record.experiment, runIDs: [currentRun.id, candidateRun.id] }, summary: value.summary, status: 'completed', finishedAt: new Date().toISOString() }, runs: [currentRun, candidateRun] };
  } catch (error) {
    await progress;
    terminal = { record: { ...record, status: controller.signal.aborted ? 'cancelled' : 'failed', finishedAt: new Date().toISOString(), error: error.message.slice(0, 4096) }, runs: [] };
  }
  if (app.active?.runId === lockId) app.active.finishing = true;
  const failedPublication = (error) => ({ ...terminal.record, experiment: record.experiment,
    ...(terminal.runs.length ? { partialRuns: terminal.runs.map((run) => run.appRun) } : {}),
    status: 'failed', finishedAt: new Date().toISOString(), error: `Could not save paired experiment evidence: ${error.message}` });
  try {
    await app.store.releaseRunLock(lockId);
    const saved = [];
    try {
      for (const run of terminal.runs) { await app.store.write('runs', run); saved.push(run.id); }
      await app.store.write('experiments', terminal.record);
    } catch (error) {
      // Retain both native outputs before removing any staged variant. Recovery
      // can finish cleanup if deletion fails after this checkpoint is durable.
      await app.store.write('experiments', failedPublication(error));
      for (const key of saved) {
        try { await app.store.delete('runs', key); }
        catch (error) { if (!/not found$/.test(error.message) && error.code !== 'ENOENT') throw error; }
      }
    }
  } catch (error) {
    // Keep this instance's outputs available for retry after storage recovers.
    // A live PID alone cannot identify a still-running experiment.
    app.pendingExperimentRecovery.set(record.id, failedPublication(error));
    throw error;
  } finally { if (app.active?.runId === lockId) app.active = null; }
}
async function releaseReport(app, source, run, baselineRunId) {
  const approved = await baselineFor(app, source.id);
  const baseline = baselineRunId ? await readRun(app, baselineRunId) : approved ? await readRun(app, approved.runID) : null;
  if (baseline && baseline.suiteId !== source.id) throw new Error('Baseline belongs to another suite');
  if (baselineRunId && baseline.status !== 'completed') throw new Error('Only completed run evidence can be used as a release baseline');
  // Retained native output remains inspectable after publication fails, but its
  // wrapper must be complete before it can qualify as release evidence.
  const result = await native(app, { operation: 'release-check', projectID: source.projectId, suite: portableSuite(source), ...(run?.status === 'completed' ? { run: run.appRun } : {}), ...(baseline?.status === 'completed' ? { baseline: baseline.appRun } : {}), ...(approved ? { approvedBaseline: approved } : {}) });
  return { ...result, health: run ? health(run, source) : null };
}
export async function workflowDispatch(app, name, args) {
  switch (name) {
    case 'eval_create_experiment': {
      requireIdle(app);
      const source = await app.store.read('suites', id(args.suiteId));
      if (args.expectedRevision !== undefined && args.expectedRevision !== source.revision) throw new Error('Suite revision conflict: reload before freezing an experiment');
      const experiment = await native(app, { operation: 'create-experiment', suite: portableSuite(source), name: args.name, candidateInstructions: args.candidateInstructions });
      const record = { id: id(experiment.id, 'experiment id'), suiteId: source.id, projectId: source.projectId, sourceRevision: source.revision, experiment, status: 'ready', createdAt: new Date().toISOString() };
      if (await optional(app, 'experiments', record.id)) throw new Error('Experiment identity already exists');
      await app.store.write('experiments', record);
      return experimentView(app, record);
    }
    case 'eval_get_experiment': {
      if (app.pendingExperimentRecovery.has(id(args.experimentId))) await app.recover();
      return experimentView(app, await app.store.read('experiments', id(args.experimentId)));
    }
    case 'eval_list_experiments': {
      if (args.suiteId) await app.store.read('suites', id(args.suiteId));
      if (args.projectId) await app.store.read('projects', id(args.projectId));
      const experiments = (await app.store.list('experiments')).filter((record) => (!args.suiteId || equalID(record.suiteId, args.suiteId)) && (!args.projectId || equalID(record.projectId, args.projectId))).sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
      return { experiments: experiments.map(publicRecord) };
    }
    case 'eval_cancel_experiment': {
      if (app.pendingExperimentRecovery.has(id(args.experimentId))) await app.recover();
      const record = await app.store.read('experiments', id(args.experimentId));
      if (record.status === 'running') {
        if (app.active?.experimentId !== record.id) throw new Error('This experiment is owned by another evaluation server');
        app.active.controller.abort(); await app.active.promise;
      }
      return experimentView(app, await app.store.read('experiments', record.id));
    }
    case 'eval_run_experiment': {
      requireIdle(app);
      await app.recover();
      const record = await app.store.read('experiments', id(args.experimentId)); conflict(record, args.expectedRevision);
      const source = await app.store.read('suites', record.suiteId);
      if (record.sourceRevision !== source.revision) throw new Error('The suite changed after this experiment was frozen');
      if (record.status === 'running' || record.experiment.runIDs.length) throw new Error('Create a new experiment to collect another pair of runs');
      if (record.startedAt && (record.attemptHistory || []).length >= 2) throw new Error('Create a new experiment after three unsuccessful attempts');
      const { partialResults, partialRuns, progress, liveResponse, error, finishedAt, plannedRunIDs, startedAt, ownerPid, ...frozen } = record;
      const attemptHistory = [...(record.attemptHistory || []), ...(startedAt ? [{ status: record.status, startedAt, finishedAt, plannedRunIDs, ...(error ? { error } : {}), ...(partialResults ? { partialResults } : {}), ...(partialRuns ? { partialRuns } : {}) }] : [])];
      const lockId = randomUUID(); await app.store.acquireRunLock(lockId);
      const running = { ...frozen, attemptHistory, plannedRunIDs: [randomUUID(), randomUUID()], status: 'running', ownerPid: process.pid, startedAt: new Date().toISOString() };
      try {
        // Another server may have finished this experiment while this caller
        // was reading its snapshot, before it acquired the execution lease.
        if (revision(await app.store.read('experiments', record.id)) !== revision(record)) throw new Error('The experiment changed before execution; reload it before retrying');
        if ((await app.store.read('suites', source.id)).revision !== source.revision) throw new Error('The suite changed after this experiment was frozen');
        await app.store.write('experiments', running);
      } catch (error) { await app.store.releaseRunLock(lockId); throw error; }
      const controller = new AbortController();
      app.active = { runId: lockId, experimentId: record.id, controller, promise: null };
      app.active.promise = executeExperiment(app, running, source, controller, lockId).catch((error) => { process.stderr.write(`Could not finalize experiment: ${error.message}\n`); });
      return experimentView(app, running);
    }
    case 'eval_decide_experiment': {
      requireIdle(app);
      const record = await app.store.read('experiments', id(args.experimentId)); conflict(record, args.expectedRevision);
      const source = await app.store.read('suites', record.suiteId);
      const updated = { ...record, experiment: { ...record.experiment, decision: args.decision } };
      let adoptedRevision;
      if (args.decision === 'adoptCandidate') {
        if (record.sourceRevision !== source.revision) throw new Error('The suite changed after this experiment was frozen');
        if (record.status !== 'completed' || record.experiment.runIDs.length !== 2 || (await experimentView(app, record)).missingRunIds.length) throw new Error('Both committed experiment runs are required before adopting the candidate');
        const adopted = await saveSuite(app, { suite: { ...source, instructions: record.experiment.candidate.instructions }, expectedRevision: source.revision });
        adoptedRevision = adopted.suite.revision;
      }
      try { await app.store.write('experiments', updated, { expectedRevision: publicRecord(record).revision }); } catch (error) {
        if (adoptedRevision) {
          try { await app.store.restoreSuite(source, adoptedRevision); }
          catch (rollbackError) { throw new Error(`${error.message}; suite rollback was not applied: ${rollbackError.message}`, { cause: error }); }
        }
        throw error;
      }
      return { ...await experimentView(app, updated), suite: await app.store.read('suites', record.suiteId) };
    }
    case 'eval_select_assessment': {
      requireIdle(app);
      const run = await readRun(app, args.runId); conflict(run, args.expectedRevision);
      if (run.status === 'running') throw new Error('Wait for the run to finish before selecting an assessment');
      const selected = run.appRun.assessments?.find((item) => equalID(item.id, args.assessmentId));
      if (!selected) throw new Error('Assessment not found in this run');
      const appRun = { ...run.appRun, selectedAssessmentID: selected.id };
      const saved = { ...run, appRun, results: applyAssessment(appRun, run.results) };
      await app.store.write('runs', saved, { expectedRevision: publicRecord(run).revision });
      return { run: publicRecord(saved), health: health(saved, await optional(app, 'suites', saved.suiteId)) };
    }
    case 'eval_correct_judgment': {
      requireIdle(app);
      const run = await readRun(app, args.runId); conflict(run, args.expectedRevision);
      if (run.status === 'running') throw new Error('Wait for the run to finish before correcting a judgment');
      const selectedID = args.assessmentId || run.appRun.selectedAssessmentID || run.appRun.assessments?.at(-1)?.id;
      const assessment = run.appRun.assessments?.find((item) => equalID(item.id, selectedID));
      const sample = assessment?.samples.find((item) => equalID(item.sampleID, args.sampleId));
      if (!sample) throw new Error('Judgment not found in this assessment');
      if (!args.reason.trim()) throw new Error('Explain why the judgment is incorrect');
      if (args.correctedScore !== undefined && (!Number.isInteger(args.correctedScore) || args.correctedScore < 1 || args.correctedScore > 4)) throw new Error('Corrected score must be an integer from 1 to 4');
      const source = await app.store.read('suites', run.suiteId);
      const corrected = await native(app, { operation: 'correct-judgment', suite: portableSuite(source), run: run.appRun, assessmentID: assessment.id, sampleID: sample.sampleID, correctedStatus: args.correctedStatus, ...(args.correctedScore !== undefined ? { correctedScore: args.correctedScore } : {}), reason: args.reason.trim(), ...(args.reviewer ? { reviewer: args.reviewer } : {}) });
      const correction = { ...corrected.correction, id: id(corrected.correction.id), suiteId: run.suiteId, projectId: run.projectId };
      if (!equalID(correction.runID, run.id) || !equalID(correction.assessmentID, assessment.id) || !equalID(correction.sampleID, sample.sampleID) || correction.originalStatus !== sample.status || correction.originalScore !== sample.score && !(correction.originalScore == null && sample.score == null)) throw new Error('Human correction does not match the original judgment');
      await app.store.write('corrections', correction);
      return { run: publicRecord(run), correction, corrections: (await app.store.list('corrections')).filter((item) => equalID(item.runID, run.id)) };
    }
    case 'eval_approve_baseline': {
      requireIdle(app);
      const run = await readRun(app, args.runId); conflict(run, args.expectedRevision);
      const source = await app.store.read('suites', run.suiteId);
      if (run.status !== 'completed' || health(run, source).staleEvidence) throw new Error('Only complete current run evidence can become a baseline');
      const assessmentID = args.assessmentId || run.appRun.selectedAssessmentID || run.appRun.assessments?.at(-1)?.id;
      const baseline = await native(app, { operation: 'approve-baseline', suite: portableSuite(source), run: run.appRun, ...(assessmentID ? { assessmentID } : {}), ...(args.note ? { note: args.note } : {}) });
      if (!equalID(baseline.runID, run.id) || !baseline.scoringContract || typeof baseline.scoringContract !== 'object') throw new Error('Baseline approval does not match the saved run and scoring contract');
      const record = { ...baseline, id: id(baseline.id), suiteId: source.id, projectId: source.projectId };
      const old = await baselineFor(app, source.id);
      await app.store.write('baselines', record);
      try { if (old) await app.store.write('baselines', { ...old, revokedAt: new Date().toISOString() }); } catch (error) { await app.store.delete('baselines', record.id); throw error; }
      return { baseline: record, run: publicRecord(run) };
    }
    case 'eval_get_baseline': {
      const source = await app.store.read('suites', id(args.suiteId)); const baseline = await baselineFor(app, source.id);
      const run = baseline ? await app.readPublicRun(id(baseline.runID)).catch((error) => { if (/not found$/.test(error.message)) return null; throw error; }) : null;
      return { baseline, run: run ? publicRecord(run) : null, health: run ? health(run, source) : null };
    }
    case 'eval_release_report': {
      const run = await readRun(app, args.runId);
      return releaseReport(app, await app.store.read('suites', run.suiteId), run, args.baselineRunId);
    }
    case 'eval_project_release_report': {
      const projectId = id(args.projectId); await app.store.read('projects', projectId);
      const sources = (await app.store.list('suites')).filter((item) => item.projectId === projectId);
      const history = await app.runs(projectId);
      const reports = [];
      for (const source of sources) {
        const latest = history.find((item) => item.suiteId === source.id && item.status !== 'running');
        const run = latest ? await app.readPublicRun(latest.id) : null;
        const result = await releaseReport(app, source, run?.appRun ? await readRun(app, run.id) : null);
        reports.push({ suiteID: source.id, suiteName: source.name, required: source.releasePolicy?.required === true, report: result.report, markdown: result.markdown });
      }
      return native(app, { operation: 'project-release-check', projectID: projectId, suites: reports.map(({ markdown, ...item }) => item) });
    }
    case 'eval_analyze_run': {
      const run = await readRun(app, args.runId);
      const analysis = await native(app, { operation: 'analyze-run', run: run.appRun });
      const baseline = args.baselineRunId ? await readRun(app, args.baselineRunId) : null;
      const comparison = baseline ? await native(app, { operation: 'compare-runs', current: run.appRun, baseline: baseline.appRun }) : undefined;
      return { runId: run.id, analysis, ...(comparison ? { comparison } : {}), health: health(run, await optional(app, 'suites', run.suiteId)), revision: publicRecord(run).revision, corrections: (await app.store.list('corrections')).filter((item) => equalID(item.runID, run.id)) };
    }
    default: return undefined;
  }
}
