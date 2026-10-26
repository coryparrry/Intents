import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Store, processAlive, CatalogLimitError } from './store.mjs';
import { id, only, object, suite, nativeResult } from './validation.mjs';
import { TOOLS, UI_URI, UI_MIME, UI_META } from './catalog.mjs';
import { nativeBinary } from '../scripts/launch.mjs';
import { invokeNative } from './runtime.mjs';
import { workflowDispatch } from './workflows.mjs';
import { initProjects, saveSuite, workspaceDispatch, health, overview } from './workspace.mjs';
import { isAppSuite, portableSuite, revision, publicRecord, applyAssessment, sampleEnvelope, validateAppEvidence, importedTimestamp } from './app-format.mjs';
import { imageInputs, REFERENCE_LIMITS } from './references.mjs';
import { validateSchema } from './app-schema.mjs';
import { recoveryResponse, recoveryDispatch } from './catalog-recovery.mjs';
import { MAX_OUTPUT_BYTES } from './validation.mjs';

const pluginURL = new URL('../', import.meta.url);
const UNCHECKED = { available: null, reason: 'Check model availability' };
/** Summarizes saved result counts and public revision, preserving invalid historical timestamps as explicit catalog warnings. */
export function summary(run) {
  const results = run.results || [];
  const timestamps = {}; const invalidTimestamps = {};
  for (const key of ['startedAt', 'finishedAt']) {
    if (key === 'finishedAt' && run[key] === undefined) continue;
    try { timestamps[key] = importedTimestamp(run[key]); }
    catch { timestamps[key] = ''; invalidTimestamps[key] = run[key] ?? null; }
  }
  // Preserve malformed historical evidence on disk and in exports, while keeping
  // the catalog usable and showing exactly which original values need attention.
  const timestampIssue = Object.keys(invalidTimestamps).length ? { timestampWarning: 'Stored run has invalid timestamps', invalidTimestamps } : {};
  return { id: run.id, suiteId: run.suiteId, suiteName: run.suite.name, projectId: run.projectId || run.suite.projectId, suiteRevision: run.suiteRevision, revision: publicRecord(run).revision, status: run.status, ...timestamps, ...timestampIssue, ...(run.durationMs !== undefined ? { durationMs: run.durationMs } : {}), ...(run.model ? { model: run.model } : {}), totalResults: results.length, plannedResults: run.suite.cases.length * run.suite.repetitions, passed: results.filter((item) => item.passed === true).length, failed: results.filter((item) => item.passed === false).length, unscored: results.filter((item) => item.passed === null).length, ...(run.error ? { error: run.error } : {}) };
}
/** Rejects unknown tools, unexpected or missing arguments, and values outside the tool input schema. */
function validateCall(name, args) {
  const tool = TOOLS.find((entry) => entry.name === name);
  if (!tool) throw new Error(`Unknown tool: ${name}`);
  only(args, Object.keys(tool.inputSchema.properties));
  for (const key of tool.inputSchema.required) if (!(key in args)) throw new Error(`Missing argument: ${key}`);
  validateSchema(args, tool.inputSchema, 'arguments', tool.inputSchema);
}
export class EvaluationApp {
  /** Creates a local store and injectable native execution dependencies without starting storage or inference. */
  constructor({ dataDir, env = process.env, resolveBinary = nativeBinary, invoke = invokeNative, timeoutMs } = {}) {
    this.store = new Store(dataDir);
    this.env = env;
    this.resolveBinary = resolveBinary;
    this.invoke = invoke;
    this.timeoutMs = timeoutMs;
    this.model = { ...UNCHECKED };
    this.active = null;
    this.pendingExperimentRecovery = new Map();
    this.pendingRunRecovery = new Map();
    this.closed = false;
    this.tail = Promise.resolve();
  }
  /** Initializes private storage, seeds an empty suite catalog, migrates project metadata, and recovers interrupted evidence. */
  async init() {
    await this.store.init();
    const saved = await this.store.recordNames('suites');
    if (!saved.length) {
      const starter = JSON.parse(await readFile(new URL('samples/starter-suite.json', pluginURL), 'utf8'));
      await this.store.saveSuite(suite(starter, randomUUID));
    }
    await initProjects(this);
    await this.recover();
  }
  /** Retries this instance's unpublished terminal output under an inference lease only while the saved running record still matches its last known revision. */
  async recoverPendingRuns(runId) {
    if (this.active || !this.pendingRunRecovery.size) return;
    const candidates = runId ? [runId] : [...this.pendingRunRecovery.keys()];
    const recoveryID = randomUUID();
    try { await this.store.acquireRunLock(recoveryID); }
    catch (error) { if (/An evaluation is already active/.test(error.message)) return; throw error; }
    try {
      for (const key of candidates) {
        const pending = this.pendingRunRecovery.get(key);
        if (!pending) continue;
        let current;
        try { current = await this.store.read('runs', key); }
        catch (error) { if (/not found$/.test(error.message)) { this.pendingRunRecovery.delete(key); continue; } throw error; }
        // Only this instance retains these outputs. Re-read under the admission
        // lease, and never replace a record changed since publication failed.
        if (current.status === 'running' && current.ownerPid === process.pid
            && revision({ run: current }) === pending.expectedRevision) {
          await this.store.write('runs', pending.record);
        }
        this.pendingRunRecovery.delete(key);
      }
    } finally { await this.store.releaseRunLock(recoveryID); }
  }
  /** Marks abandoned runs failed and retains interrupted paired outputs before removing staged public runs; experiment cleanup rereads records under the inference lease. */
  async recover() {
    await this.recoverPendingRuns();
    for (const run of await this.store.list('runs', ({ id, status, ownerPid }) => ({ id, status, ownerPid }))) {
      if (run.status === 'running' && !processAlive(run.ownerPid)) {
        const fullRun = await this.store.read('runs', run.id);
        await this.store.write('runs', { ...fullRun, status: 'failed', finishedAt: new Date().toISOString(), durationMs: Date.now() - Date.parse(fullRun.startedAt), error: 'Evaluation interrupted before completion' });
      }
    }
    const candidates = [];
    for await (const record of this.store.scan('experiments')) {
      if (['failed', 'cancelled'].includes(record.status)
          || record.status === 'running' && (!processAlive(record.ownerPid) || this.pendingExperimentRecovery.has(record.id))) {
        candidates.push({ id: record.id });
      }
    }
    if (!candidates.length) return;
    const recoveryID = randomUUID();
    try { await this.store.acquireRunLock(recoveryID); }
    catch (error) { if (/An evaluation is already active/.test(error.message)) return; throw error; }
    try {
      for (const candidate of candidates) {
        // A retry may have completed since the catalog read. Hold the same
        // lease as run admission and re-read before writing or deleting evidence.
        let experiment;
        try { experiment = await this.store.read('experiments', candidate.id); }
        catch (error) { if (/not found$/.test(error.message)) { this.pendingExperimentRecovery.delete(candidate.id); continue; } throw error; }
        if (this.active?.experimentId === experiment.id) continue;
        const pending = this.pendingExperimentRecovery.get(experiment.id);
        const ownedPending = experiment.status === 'running' && pending
          && JSON.stringify(pending.plannedRunIDs) === JSON.stringify(experiment.plannedRunIDs) ? pending : null;
        const interrupted = experiment.status === 'running' && (!processAlive(experiment.ownerPid) || ownedPending);
        if (!interrupted && !['failed', 'cancelled'].includes(experiment.status)) {
          this.pendingExperimentRecovery.delete(experiment.id); continue;
        }
        const staged = [];
        for (const key of experiment.plannedRunIDs || []) {
          let run;
          try { run = await this.store.read('runs', id(key, 'planned run id')); } catch (error) { if (/not found$/.test(error.message)) continue; throw error; }
          // Never remove an unrelated record occupying a planned identity.
          if (run.experimentId?.toLowerCase() === experiment.id) staged.push(run);
        }
        if (interrupted || staged.length || ownedPending) {
          const recovered = ownedPending || experiment;
          const partialRuns = [...(recovered.partialRuns || [])];
          for (const run of staged) if (run.appRun && !partialRuns.some((item) => item.id?.toLowerCase() === run.id)) partialRuns.push(run.appRun);
          await this.store.write('experiments', { ...recovered, ...(partialRuns.length ? { partialRuns } : {}), ...(interrupted ? { status: 'failed', finishedAt: new Date().toISOString(), error: ownedPending?.error || 'Instruction experiment interrupted before completion' } : {}) });
          // Persist recovered evidence before removing public history candidates.
          for (const run of staged) {
            try { await this.store.delete('runs', run.id); }
            catch (error) { if (!/not found$/.test(error.message) && error.code !== 'ENOENT') throw error; }
          }
        }
        this.pendingExperimentRecovery.delete(experiment.id);
      }
    } finally { await this.store.releaseRunLock(recoveryID); }
  }
  /** Validates and serializes tool calls, leaving preview status/cancellation reachable during generation and converting catalog overflow into recovery responses. */
  async call(name, args = {}) {
    if (this.closed || this.closing) throw new Error('Evaluation server is shutting down');
    // Preview controls must remain reachable while its response call holds the queue.
    if (['eval_preview_status', 'eval_cancel_preview'].includes(name)) {
      if (this.closed) throw new Error('Evaluation server is shutting down');
      validateCall(name, args);
      return this.dispatch(name, args);
    }
    let pendingPreview;
    if (name === 'eval_preview_response') {
      validateCall(name, args);
      args = { ...args, previewId: args.previewId ? id(args.previewId, 'previewId') : randomUUID() };
      this.pendingPreviews ||= new Map();
      if (this.pendingPreviews.has(args.previewId) || this.previewState?.id === args.previewId) throw new Error('Preview identity has already been used');
      pendingPreview = { cancelled: false }; this.pendingPreviews.set(args.previewId, pendingPreview);
    }
    const previous = this.tail;
    let release;
    this.tail = new Promise((accept) => { release = accept; });
    await previous;
    try {
      if (this.closed) throw new Error('Evaluation server is shutting down');
      validateCall(name, args);
      if (pendingPreview?.cancelled) throw new Error('Preview cancelled');
      return await this.dispatch(name, args);
    } catch (error) {
      if (error instanceof CatalogLimitError) return recoveryResponse(this, error.kind, error.message);
      throw error;
    } finally { if (pendingPreview) this.pendingPreviews.delete(args.previewId); release(); }
  }
  /** Routes validated tool arguments to workspace reads, persisted mutations, or native operations and rejects unhandled tool names. */
  async dispatch(name, args) {
    switch (name) {
      case 'eval_open_workspace': { const workspace = { page: 'workspace', projects: await this.store.list('projects'), defaultProjectId: this.defaultProjectId, limits: { ...REFERENCE_LIMITS, maxRequestBytes: 68157440 }, suites: await this.store.list('suites'), runs: await this.runs(), model: this.model, experiments: await this.store.list('experiments', publicRecord), overview: await overview(this, this.defaultProjectId) };
        if (Buffer.byteLength(JSON.stringify(workspace)) > MAX_OUTPUT_BYTES) return recoveryResponse(this, 'suites', 'The combined workspace exceeds its 32 MiB response limit. Export or remove records before reopening.');
        return workspace;
      }
      case 'eval_open_trace': {
        only(args.file, ['name', 'resourceUri']);
        for (const key of ['name', 'resourceUri']) if (typeof args.file[key] !== 'string' || !args.file[key].trim() || args.file[key].length > (key === 'name' ? 1024 : 4096)) throw new Error(`Invalid file ${key}`);
        if (/[\\/]/.test(args.file.name)) throw new Error('File name must not contain a path');
        return { page: 'trace', file: args.file };
      }
      case 'eval_model_status': return this.status();
      case 'eval_preview_response': return this.preview(args.suite, args.prompt, args.previewId);
      case 'eval_preview_status': return { preview: this.previewStatus() };
      case 'eval_cancel_preview': return this.cancelPreview(args.previewId);
      case 'eval_list_suites': { const projectId = args.projectId === undefined ? null : id(args.projectId, 'projectId'); return { suites: (await this.store.list('suites')).filter((item) => !projectId || item.projectId === projectId) }; }
      case 'eval_save_suite': return saveSuite(this, args);
      case 'eval_delete_suite': {
        const suiteId = id(args.suiteId, 'suiteId');
        await this.store.delete('suites', suiteId);
        return { deleted: true, suiteId };
      }
      case 'eval_start_run': return this.start(id(args.suiteId, 'suiteId'), args.expectedRevision);
      case 'eval_list_runs': return { runs: await this.runs(args.projectId === undefined ? null : id(args.projectId, 'projectId')) };
      case 'eval_get_run': { const run = await this.readPublicRun(id(args.runId, 'runId')); let saved; try { saved = await this.store.read('suites', run.suiteId); } catch (error) { if (!/not found$/.test(error.message)) throw error; } return { run: { ...publicRecord(run), health: health(run, saved), ...(this.active?.runId === run.id && this.active.liveResponse ? { liveResponse: this.active.liveResponse } : {}) } }; }
      case 'eval_cancel_run': return this.cancel(id(args.runId, 'runId'));
      case 'eval_delete_run': {
        const runId = id(args.runId, 'runId');
        const run = await this.readPublicRun(runId);
        if (run.status === 'running') throw new Error('Cancel an active run before deleting it');
        await this.store.delete('runs', runId);
        return { deleted: true, runId };
      }
      case 'eval_compare_runs': return this.compare(args.runIds);
      default: { const result = await recoveryDispatch(this, name, args) ?? await workspaceDispatch(this, name, args) ?? await workflowDispatch(this, name, args); if (result === undefined) throw new Error('Unknown tool'); return result; }
    }
  }
  /** Retries pending publication and returns a run only after any owning experiment has committed that run identity. */
  async readPublicRun(runId) {
    if (this.pendingRunRecovery.has(runId)) await this.recoverPendingRuns(runId);
    const run = await this.store.read('runs', runId);
    if (run.experimentId) {
      const experiment = await this.store.read('experiments', id(run.experimentId, 'experiment id'));
      if (experiment.status !== 'completed' || !experiment.experiment?.runIDs?.some((key) => key.toLowerCase() === run.id)) throw new Error('Paired experiment evidence has not been committed');
    }
    return run;
  }
  /** Recovers interrupted work, then returns newest-first public run summaries with suite freshness and optional project filtering. */
  async runs(projectId = null) {
    await this.recover();
    const experiments = new Map((await this.store.list('experiments', ({ id, status, experiment }) => ({ id, status, experiment: { runIDs: experiment?.runIDs } }))).map((item) => [item.id, item]));
    const suites = new Map((await this.store.list('suites', (saved) => ({ id: saved.id, revision: saved.revision || revision(saved) }))).map((item) => [item.id, item]));
    return (await this.store.list('runs', (run) => { const experiment = run.experimentId ? experiments.get(run.experimentId) : null; return run.experimentId && (experiment?.status !== 'completed' || !experiment.experiment?.runIDs?.some((key) => key.toLowerCase() === run.id)) ? null : { ...summary(run), health: health(run, suites.get(run.suiteId)) }; })).filter(Boolean).filter((run) => !projectId || run.projectId === projectId).sort((a, b) => b.startedAt.localeCompare(a.startedAt));
  }
  /** Runs one unscored prompt under a guarded lease, exposes live preview state, and waits for lease release before settling. */
  async preview(source, prompt, previewId) {
    if (this.active) throw new Error('Wait for the active evaluation before previewing a response');
    const savedSuite = suite({ ...source, id: randomUUID(), name: source.name || 'Preview', version: source.version || 'v1', scoringMode: 'review', criteria: '', repetitions: 1, cases: [{ id: randomUUID(), name: 'Preview', prompt, expected: '' }], ...(source.modelConfiguration ? {} : { modelConfiguration: { temperatureEnabled: true, temperature: source.temperature ?? 0, maximumResponseTokens: source.maxTokens ?? 256 } }) }, randomUUID);
    const lockId = previewId || randomUUID(); const controller = new AbortController();
    let finish; const done = new Promise((resolve) => { finish = resolve; });
    const state = { id: lockId, status: 'running', startedAt: new Date().toISOString(), controller, done };
    this.previewState = state;
    let locked = false;
    try {
      await this.store.acquireRunLock(lockId); locked = true; this.transientController = controller;
      if (controller.signal.aborted) throw new Error('Preview cancelled');
      const binary = await this.resolveBinary({ dataDir: this.store.root, env: this.env, signal: controller.signal });
      const value = nativeResult(await this.invoke(binary, { operation: 'evaluate', suite: portableSuite(savedSuite), runID: lockId, emitEvents: true, images: await imageInputs(this, savedSuite) }, { signal: controller.signal, timeoutMs: this.timeoutMs, lease: this.store.lease(lockId), /** Captures native live-response objects for preview polling while generation remains active. */ onEvent: (event) => { if (event.event === 'liveResponse' && event.value && typeof event.value === 'object') state.liveResponse = event.value; } }), savedSuite);
      if (controller.signal.aborted) throw new Error('Preview cancelled');
      if (value.status !== 'completed' || !value.results.length) throw new Error(value.error?.message || value.error || 'Preview did not complete');
      state.status = 'completed';
      return { response: value.results[0].response, result: value.results[0], model: value.model, ...(value.appRun ? { appRun: value.appRun } : {}), ...(value.analysis ? { analysis: value.analysis } : {}) };
    } catch (error) { state.status = controller.signal.aborted ? 'cancelled' : 'failed'; throw error;
    } finally {
      try { if (locked) await this.store.releaseRunLock(lockId); }
      finally { if (this.transientController === controller) this.transientController = null; state.finishedAt = new Date().toISOString(); finish(); }
    }
  }
  /** Returns serializable preview state with an active flag, excluding its controller and completion promise. */
  previewStatus() {
    if (!this.previewState) return { status: 'idle', active: false };
    const { controller, done, ...state } = this.previewState;
    return { ...state, active: !state.finishedAt };
  }
  /** Cancels an identified queued or active preview, waiting for active cleanup before returning its final public state. */
  async cancelPreview(previewId) {
    const state = this.previewState;
    if (previewId && state?.id !== id(previewId, 'previewId')) {
      const pending = this.pendingPreviews?.get(id(previewId, 'previewId'));
      if (pending) { pending.cancelled = true; return { cancelled: true, preview: { id: id(previewId), status: 'cancelled', active: false } }; }
      return { cancelled: false, preview: this.previewStatus() };
    }
    if (!state || state.finishedAt || state.status !== 'running') return { cancelled: false, preview: this.previewStatus() };
    state.controller.abort(); await state.done;
    return { cancelled: true, preview: this.previewStatus() };
  }
  /** Checks native availability under a temporary lease when idle, caches bounded model metadata, and reports failures as availability reasons. */
  async status() {
    if (this.active || (await this.store.list('runs', ({ status, ownerPid }) => ({ status, ownerPid }))).some((run) => run.status === 'running' && processAlive(run.ownerPid))) return this.model.available === null ? { ...UNCHECKED, reason: 'An evaluation is active; check model availability after it finishes' } : this.model;
    const lockId = randomUUID(); const controller = new AbortController();
    this.transientController = controller;
    if (this.closing) controller.abort();
    let locked = false;
    try {
      if (controller.signal.aborted) throw new Error('Evaluation cancelled');
      await this.store.acquireRunLock(lockId);
      locked = true;
      if (controller.signal.aborted) throw new Error('Evaluation cancelled');
      const binary = await this.resolveBinary({ dataDir: this.store.root, env: this.env, signal: controller.signal });
      const value = object(await this.invoke(binary, { operation: 'availability' }, { timeoutMs: 60000, signal: controller.signal, lease: this.store.lease(lockId) }), 'availability');
      if (typeof value.available !== 'boolean') throw new Error('Native worker returned invalid availability');
      this.model = { available: value.available, ...(typeof value.reason === 'string' ? { reason: value.reason.slice(0, 4096) } : {}), ...(typeof value.model === 'string' ? { model: value.model.slice(0, 256) } : {}), ...(typeof value.osVersion === 'string' ? { osVersion: value.osVersion.slice(0, 256) } : {}), ...(value.capabilities && typeof value.capabilities === 'object' ? { capabilities: value.capabilities } : {}) };
    } catch (error) { this.model = { available: false, reason: error.message }; }
    finally {
      try { if (locked) await this.store.releaseRunLock(lockId); }
      finally { if (this.transientController === controller) this.transientController = null; }
    }
    return this.model;
  }
  /** Validates a saved suite and optional revision, durably records an admitted running job, and returns while guarded execution continues. */
  async start(suiteId, expectedRevision) {
    if (this.active?.finishing) await this.active.promise;
    if (this.active) throw new Error('An evaluation is already active');
    await this.recoverPendingRuns();
    const savedSuite = suite(await this.store.read('suites', suiteId), randomUUID);
    if (expectedRevision !== undefined && expectedRevision !== savedSuite.revision) throw new Error('Suite revision conflict: reload before running');
    const run = { id: randomUUID(), suiteId, projectId: savedSuite.projectId || this.defaultProjectId, suiteRevision: savedSuite.revision || revision(savedSuite), suite: savedSuite, status: 'running', startedAt: new Date().toISOString(), ownerPid: process.pid, results: [] };
    await this.store.acquireRunLock(run.id);
    try { await this.store.write('runs', run); } catch (error) { await this.store.releaseRunLock(run.id); throw error; }
    const controller = new AbortController();
    this.active = { runId: run.id, controller, promise: null };
    this.active.promise = this.execute(run, controller).catch((error) => { process.stderr.write(`Could not finalize evaluation: ${error.message}\n`); });
    return { run: publicRecord(run) };
  }
  /** Validates and saves native progress, drains the worker lease, then publishes terminal evidence or retains it for revision-checked recovery. */
  async execute(run, controller) {
    let finished; let progress = Promise.resolve();
    let expectedRevision = revision({ run });
    /** Updates live output immediately and queues validated, deduplicated sample snapshots so final publication waits for progress writes. */
    const onEvent = (event) => {
      if (event.event === 'liveResponse' && event.value && typeof event.value === 'object') {
        run.liveResponse = event.value;
        if (this.active?.runId === run.id) this.active.liveResponse = event.value;
        return;
      }
      progress = progress.then(async () => {
        if (event.event === 'sample') {
          validateAppEvidence({ results: [event.result] });
          const result = sampleEnvelope(event.result);
          nativeResult({ status: 'failed', results: [result] }, run.suite);
          if (run.results.some((item) => item.caseId === result.caseId && item.repetition === result.repetition)) return;
          run.results.push(result);
          run.completedSamples = run.results.length;
          // Live responses can mutate run while storage is awaiting I/O. Keep
          // the exact last saved record for recovery if the final read fails.
          const snapshot = structuredClone(run);
          await this.store.write('runs', snapshot);
          expectedRevision = revision({ run: snapshot });
        }
      }).catch((error) => { process.stderr.write(`Could not save evaluation progress: ${error.message}\n`); });
    };
    try {
      const binary = await this.resolveBinary({ dataDir: this.store.root, env: this.env, signal: controller.signal });
      if (controller.signal.aborted) throw new Error('Evaluation cancelled');
      const settings = { instructions: run.suite.instructions, cases: run.suite.cases.map(({ name, ...item }) => item), repetitions: run.suite.repetitions, temperature: run.suite.temperature, maxTokens: run.suite.maxTokens };
      const request = isAppSuite(run.suite) ? { operation: 'evaluate', suite: portableSuite(run.suite), runID: run.id, emitEvents: true, images: await imageInputs(this, run.suite) } : { operation: 'evaluate', ...settings };
      const value = nativeResult(await this.invoke(binary, request, { signal: controller.signal, timeoutMs: this.timeoutMs, lease: this.store.lease(run.id), onEvent }), run.suite);
      if (value.appRun && id(value.appRun.id, 'app run id') !== run.id) throw new Error('App run identity does not match the active run');
      await progress;
      const nativeError = typeof value.error === 'object' && value.error ? value.error.message : value.error;
      finished = { ...run, status: controller.signal.aborted ? 'cancelled' : value.status, model: value.model, finishedAt: new Date().toISOString(), durationMs: Number.isFinite(value.durationMs) && value.durationMs >= 0 ? value.durationMs : Date.now() - Date.parse(run.startedAt), totalDurationMs: Date.now() - Date.parse(run.startedAt), results: applyAssessment(value.appRun, value.results), ...(value.appRun ? { appRun: value.appRun } : {}), ...(value.analysis ? { analysis: value.analysis } : {}), ...(value.error ? { error: String(nativeError).slice(0, 4096), errorDetails: value.error } : {}) };
      this.model = { ...this.model, available: value.status === 'completed' || value.results.length > 0 ? true : this.model.available, ...(value.model ? { model: value.model } : {}) };
    } catch (error) {
      await progress;
      finished = { ...run, status: controller.signal.aborted ? 'cancelled' : 'failed', finishedAt: new Date().toISOString(), durationMs: Date.now() - Date.parse(run.startedAt), error: error.message.slice(0, 4096) };
    }
    if (this.active?.runId === run.id) this.active.finishing = true;
    try {
      // Publish completion only after the guardian has reaped its worker and released the lease.
      await this.store.releaseRunLock(run.id);
      let current;
      try { current = await this.store.read('runs', run.id); }
      catch (error) {
        this.pendingRunRecovery.set(run.id, { record: finished, expectedRevision });
        throw error;
      }
      if (current.status === 'running') {
        try { await this.store.write('runs', finished); }
        catch (error) {
          const record = { ...finished, status: 'failed', error: `Could not save native result: ${error.message}` };
          this.pendingRunRecovery.set(run.id, { record, expectedRevision: revision({ run: current }) });
          await this.store.write('runs', record);
          this.pendingRunRecovery.delete(run.id);
        }
      }
    } finally {
      if (this.active?.runId === run.id) this.active = null;
    }
  }
  /** Aborts a locally owned running job and waits for final persistence; rejects cancellation of another server's active run. */
  async cancel(runId) {
    let run = await this.readPublicRun(runId);
    if (run.status === 'running') {
      if (this.active?.runId !== runId) throw new Error('This run is owned by another evaluation server');
      this.active.controller.abort();
      await this.active.promise;
      run = await this.store.read('runs', runId);
    }
    return { run: publicRecord(run) };
  }
  /** Loads two to four distinct committed runs and groups their saved results by case identity and repetition. */
  async compare(runIds) {
    if (!Array.isArray(runIds) || runIds.length < 2 || runIds.length > 4) throw new Error('runIds must contain 2 to 4 UUIDs');
    const ids = runIds.map((key) => id(key, 'runId'));
    if (new Set(ids).size !== ids.length) throw new Error('runIds must be unique');
    const runs = await Promise.all(ids.map((key) => this.readPublicRun(key)));
    const cases = new Map();
    for (const run of runs) for (const result of run.results) {
      const key = JSON.stringify([result.caseId, result.repetition]);
      if (!cases.has(key)) cases.set(key, { caseId: result.caseId, repetition: result.repetition, results: [] });
      cases.get(key).results.push({ runId: run.id, response: result.response, passed: result.passed, score: result.score, durationMs: result.durationMs });
    }
    return { runs: runs.map(summary), cases: [...cases.values()] };
  }
  /** Reads the bundled workspace HTML or a validated committed run resource; rejects unknown resource URIs. */
  async resource(uri) {
    if (uri === UI_URI) return { contents: [{ uri, mimeType: UI_MIME, text: await readFile(fileURLToPath(new URL('ui/app.html', pluginURL)), 'utf8'), _meta: UI_META }] };
    const match = /^foundation-evals:\/\/runs\/([^/]+)$/.exec(uri);
    if (!match) throw new Error('Unknown resource');
    return { contents: [{ uri, mimeType: 'application/json', text: JSON.stringify(publicRecord(await this.readPublicRun(id(match[1], 'runId')))) }] };
  }
  /** Stops new admission, cancels previews and transient work, drains queued calls, then waits for any active run to finalize. */
  async shutdown() {
    this.closing = true;
    for (const preview of this.pendingPreviews?.values() || []) preview.cancelled = true;
    this.previewState?.controller.abort();
    this.transientController?.abort();
    // Calls admitted before shutdown may finish, but queued previews cannot launch.
    await this.tail;
    this.closed = true;
    if (this.active) { this.active.controller.abort(); await this.active.promise; }
  }
}
