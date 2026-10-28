import { randomUUID } from 'node:crypto';
import { suite, id, object, nativeResult, MAX_OUTPUT_BYTES, MAX_SUITE_BUNDLE_BYTES } from './validation.mjs';
import { isAppSuite, revision, portableSuite, parseImport, sampleEnvelope, applyAssessment, validateAppEvidence, importedTimestamp } from './app-format.mjs';
import { addReferenceFile, exportReferences, importReferences } from './references.mjs';
import { importCases } from './case-import.mjs';
import { SPOTLIGHT_DEFAULTS } from './app-defaults.mjs';
const DEFAULT_PROJECT_ID = '00000000-0000-4000-8000-000000000001';
/** Seeds a default project when needed and transactionally fills missing suite/run ownership metadata from current saved records. */
export async function initProjects(app) {
  if (!(await app.store.recordNames('projects')).length) await app.store.write('projects', { id: DEFAULT_PROJECT_ID, name: 'My evaluations', description: '', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
  const projects = await app.store.list('projects', ({ id }) => ({ id }));
  app.defaultProjectId = projects.find((item) => item.id === DEFAULT_PROJECT_ID)?.id || projects[0].id;
  for await (const saved of app.store.scan('suites')) if (!saved.projectId || !saved.revision) await app.store.migrateSuite(saved.id, app.defaultProjectId);
  for await (const run of app.store.scan('runs')) if (!run.projectId && run.status !== 'running') await app.store.migrateRun(run.id, app.defaultProjectId);
}
/** Resolves an explicit or default project UUID and requires the owning project record to exist. */
async function project(app, value) { const projectId = id(value || app.defaultProjectId, 'projectId'); await app.store.read('projects', projectId); return projectId; }
/** Serializes and measures compact portable JSON identically for imports and exports, rejecting oversized bundles before extraction or export. */
function suiteBundleJSON(definition, files) {
  const value = files?.length ? { suite: definition, referenceFiles: files } : definition;
  const json = JSON.stringify(value);
  if (Buffer.byteLength(json) > MAX_SUITE_BUNDLE_BYTES) throw new Error('Portable suite bundle exceeds 32 MiB; export or import fewer reference files');
  return json;
}
/** Normalizes an editor draft, resets imported Spotlight authorization, verifies project ownership, and transactionally saves against the supplied or embedded revision. */
export async function saveSuite(app, args, { imported = false } = {}) {
  const value = args.suite;
  const saved = suite(value?.formatVersion === 1 ? Object.fromEntries(Object.entries(value).filter(([key]) => key !== 'formatVersion')) : value, randomUUID, { draft: true });
  // Imported configuration cannot authorize access to this Mac's indexed data.
  if (imported && isAppSuite(saved)) saved.features.spotlightSearch = structuredClone(SPOTLIGHT_DEFAULTS);
  const old = await app.store.readOptional('suites', saved.id);
  const expected = args.expectedRevision ?? value.revision;
  saved.projectId = await project(app, args.projectId || saved.projectId || old?.projectId);
  return { suite: await app.store.saveSuite(saved, expected) };
}
/** Reports suite freshness and selected-assessment availability without changing saved run or judge evidence. */
export function health(run, saved) {
  const sourceRevision = run.suiteRevision || (run.suite ? revision(run.suite) : null);
  const staleEvidence = !saved || !sourceRevision || sourceRevision !== (saved.revision || revision(saved));
  const appRun = run.appRun;
  const selected = appRun?.assessments?.find((assessment) => assessment.id?.toLowerCase() === appRun.selectedAssessmentID?.toLowerCase()) || (!appRun?.selectedAssessmentID ? appRun?.assessments?.at(-1) : null);
  return { staleEvidence, suiteMissing: !saved, currentAssessment: staleEvidence ? 'stale' : run.status !== 'completed' ? 'incomplete' : appRun?.selectedAssessmentID && !selected ? 'missing' : selected?.samples?.some((item) => item.errorCategory || item.errorMessage) ? 'error' : 'current', suiteRevision: sourceRevision, currentSuiteRevision: saved?.revision || null, ...(selected ? { assessmentId: selected.id } : {}) };
}
/** Returns a project's suite/run counts, current and stale evidence totals, and latest public run per suite. */
export async function overview(app, projectId) {
  const owner = await project(app, projectId);
  const suites = (await app.store.list('suites', ({ id, name, revision, projectId, cases }) => ({ id, name, revision, projectId, caseCount: cases.length }))).filter((item) => item.projectId === owner);
  const summaries = await app.runs(owner);
  return { project: await app.store.read('projects', owner), suiteCount: suites.length, runCount: summaries.length, activeRuns: summaries.filter((run) => run.status === 'running').length, currentSuites: summaries.filter((run) => run.status === 'completed' && !run.health.staleEvidence).reduce((set, run) => set.add(run.suiteId), new Set()).size, staleRuns: summaries.filter((run) => run.health.staleEvidence).length, suites: suites.map((item) => ({ id: item.id, name: item.name, revision: item.revision, caseCount: item.caseCount, latestRun: summaries.find((run) => run.suiteId === item.id) || null })), runs: summaries };
}
/** Handles project edits, suite/case/reference imports and exports, and trace analysis; returns undefined for tools owned by other dispatchers. */
export async function workspaceDispatch(app, name, args) {
  switch (name) {
    case 'eval_list_projects': return { projects: await app.store.list('projects') };
    case 'eval_create_project': case 'eval_update_project': {
      const old = name === 'eval_update_project' ? await app.store.read('projects', id(args.projectId, 'projectId')) : null;
      const saved = { id: old?.id || randomUUID(), name: args.name ?? old?.name, description: args.description ?? old?.description ?? '', createdAt: old?.createdAt || new Date().toISOString(), updatedAt: new Date().toISOString() };
      if (typeof saved.name !== 'string' || !saved.name.trim() || saved.name.length > 160 || typeof saved.description !== 'string' || saved.description.length > 4096) throw new Error('Invalid project name or description');
      await app.store.write('projects', saved); return { project: saved };
    }
    case 'eval_project_overview': return overview(app, args.projectId);
    case 'eval_import_suite': { const imported = parseImport(args, 'suite'); let definition = imported.suite || imported; const files = args.referenceFiles || imported.referenceFiles; suiteBundleJSON(definition, files); if (files) definition = await importReferences(app, definition, files); return saveSuite(app, { ...args, suite: definition }, { imported: true }); }
    case 'eval_export_suite': { const saved = await app.store.read('suites', id(args.suiteId, 'suiteId')); const value = portableSuite(saved); const referenceFiles = await exportReferences(app, saved); return { suite: value, ...(referenceFiles.length ? { referenceFiles } : {}), revision: saved.revision, json: suiteBundleJSON(value, referenceFiles), filename: `${saved.name.replace(/[^a-z0-9_-]/gi, '-')}.json` }; }
    case 'eval_import_cases': {
      const saved = await app.store.read('suites', id(args.suiteId, 'suiteId'));
      const cases = importCases(args, isAppSuite(saved));
      return { ...await saveSuite(app, { suite: { ...saved, cases: [...saved.cases, ...cases] }, expectedRevision: args.expectedRevision }), importedCount: cases.length };
    }
    case 'eval_add_reference_text': {
      const saved = await app.store.read('suites', id(args.suiteId, 'suiteId'));
      if (!isAppSuite(saved)) throw new Error('Reference text requires an app-format suite');
      return saveSuite(app, { suite: { ...saved, attachments: [...(saved.attachments || []), { id: randomUUID(), name: args.name, kind: 'text', text: args.text }] }, expectedRevision: args.expectedRevision });
    }
    case 'eval_add_reference_file': {
      const saved = await app.store.read('suites', id(args.suiteId, 'suiteId'));
      if (!isAppSuite(saved)) throw new Error('Reference files require an app-format suite');
      if (args.expectedRevision !== undefined && args.expectedRevision !== saved.revision) throw new Error('Suite revision conflict: reload before attaching a file');
      const extracted = await addReferenceFile(app, args);
      return { ...await saveSuite(app, { suite: { ...saved, attachments: [...(saved.attachments || []), extracted.attachment] }, expectedRevision: args.expectedRevision }), truncated: extracted.truncated };
    }
    case 'eval_import_run': return importRun(app, args);
    case 'eval_parse_trace': return importRun(app, args, { persist: false });
    case 'eval_export_run': {
      const saved = await app.readPublicRun(id(args.runId, 'runId')); const { ownerPid, ...publicRun } = saved; const value = saved.appRun || publicRun;
      return { run: value, json: JSON.stringify(value, null, 2), filename: `${saved.id}.afevaltrace` };
    }
    case 'eval_analyze_cases': {
      const run = await app.readPublicRun(id(args.runId, 'runId'));
      if (args.caseIds !== undefined && (!Array.isArray(args.caseIds) || args.caseIds.some((item) => typeof item !== 'string') || new Set(args.caseIds).size !== args.caseIds.length)) throw new Error('caseIds must be unique strings');
      const caseIds = args.caseIds?.map((key) => isAppSuite(run.suite) ? key.toLowerCase() : key);
      if (caseIds && new Set(caseIds).size !== caseIds.length) throw new Error('caseIds must be unique strings');
      const ids = new Set(caseIds || run.results.map((item) => item.caseId));
      if ([...ids].some((key) => !run.results.some((item) => item.caseId === key))) throw new Error('Unknown case in run');
      return { runId: run.id, health: health(run, await app.store.readOptional('suites', run.suiteId)), cases: run.results.filter((item) => ids.has(item.caseId)).map((result) => ({ ...result, appSample: result.appSample || result.trace?.appSample || null })), assessments: run.appRun?.assessments || [] };
    }
    default: return undefined;
  }
}
/** Derives a conservative terminal status from native cancellation, termination reason, and sample errors. */
function importedAppRunStatus(run) {
  return run.cancelled ? 'cancelled' : run.terminationReason || run.results?.some((sample) => sample.status === 'error') ? 'failed' : 'completed';
}
/** Validates local terminal trace identity, timestamps, suite snapshots, and sample evidence. persist=false previews external ownership without local project requirements or writes; persistence requires local ownership and never overwrites an existing run. */
async function importRun(app, args, { persist = true } = {}) {
  let value = object(parseImport(args, 'run'), 'run'); value = value.run || value;
  const evidence = value.appRun || value;
  if (evidence.developerExecution || (evidence.execution?.configuration?.provider && evidence.execution.configuration.provider !== 'onDevice') || evidence.results?.some((sample) => sample.judgeIdentity?.mode === 'connection') || evidence.assessments?.some((assessment) => assessment.judge?.mode === 'connection')) throw new Error('Only local on-device evaluation evidence is supported');
  if (Buffer.byteLength(JSON.stringify(value)) > MAX_OUTPUT_BYTES) throw new Error('Run import exceeds size limit');
  let saved;
  if (value.suite && value.status && value.results) {
    if (value.appRun) {
      if (id(value.id, 'run id') !== id(value.appRun.id, 'app run id')) throw new Error('Run identity does not match its app evidence');
      // Outer cancellation/failure can conservatively downgrade a native
      // result, but a completed envelope cannot promote stopped raw evidence.
      if (value.status === 'completed' && importedAppRunStatus(value.appRun) !== 'completed') throw new Error('Completed run status does not match its app evidence');
    }
    const snapshot = suite(value.suite, randomUUID);
    if (value.appRun && id(value.appRun.id, 'app run id') !== id(value.id, 'run id')) throw new Error('App run identity does not match its imported envelope');
    nativeResult({ ...value, status: value.status === 'completed' ? 'completed' : 'failed' }, snapshot, { allowAssessmentProjection: true });
    if (!['completed', 'failed', 'cancelled'].includes(value.status)) throw new Error('Only terminal runs can be imported');
    const startedAt = importedTimestamp(value.startedAt);
    const finishedAt = importedTimestamp(value.finishedAt);
    if (id(args.suiteId || value.suiteId, 'suiteId') !== snapshot.id) throw new Error('Run suite identity does not match its snapshot');
    const { ownerPid, ...safeValue } = value;
    const owner = args.projectId || value.projectId || snapshot.projectId;
    saved = { ...safeValue, startedAt, finishedAt, id: id(value.id, 'run id'), suiteId: id(args.suiteId || value.suiteId, 'suiteId'), suite: snapshot, projectId: persist ? await project(app, owner) : id(owner || app.defaultProjectId, 'projectId'), suiteRevision: revision(snapshot) };
  } else {
    if (value.developerExecution || value.execution?.configuration?.provider && value.execution.configuration.provider !== 'onDevice' || value.results?.some((sample) => sample.judgeIdentity?.mode === 'connection') || value.assessments?.some((assessment) => assessment.judge?.mode === 'connection')) throw new Error('Only local on-device evaluation evidence is supported');
    validateAppEvidence(value);
    const suiteId = id(value.suiteID, 'suiteId');
    if (args.suiteId !== undefined && id(args.suiteId, 'suiteId') !== suiteId) throw new Error('App run suite identity does not match the requested suite');
    let snapshot = await app.store.readOptional('suites', suiteId);
    const definition = value.suiteDefinition;
    if (definition) snapshot = suite(Object.fromEntries(Object.entries({ ...definition, attachments: definition.attachments || snapshot?.attachments?.filter((item) => value.attachments?.some((evidence) => evidence.name === item.name && evidence.sha256 === item.sha256 && evidence.kind === item.kind)) || value.attachments?.filter((item) => typeof item.text === 'string') || [] }).filter(([key]) => key !== 'formatVersion')), randomUUID);
    if (snapshot && snapshot.id !== suiteId) throw new Error('Run suite identity does not match its definition');
    if (!snapshot) {
      if (!Array.isArray(value.plannedCases) || !value.plannedCases.length) throw new Error('App run requires suiteDefinition, plannedCases, or an existing suite');
      snapshot = suite({ id: suiteId, name: value.suiteName, version: value.suiteVersion || 'v1', instructions: value.instructions, criteria: value.criteria, scoringMode: value.scoringMode, repetitions: value.repetitions, modelConfiguration: value.execution?.configuration, features: value.execution?.features, cases: value.plannedCases }, randomUUID);
    }
    let results = value.results?.map((sample) => { id(sample.id, 'sample id'); if (!['passed', 'failed', 'unscored', 'error'].includes(sample.status)) throw new Error('Invalid app sample status'); return sampleEnvelope(sample, snapshot.cases); });
    if (!results) throw new Error('App run requires sample results');
    const status = importedAppRunStatus(value);
    nativeResult({ status: status === 'completed' ? 'completed' : 'failed', results }, snapshot);
    results = applyAssessment(value, results);
    const startedAt = importedTimestamp(value.startedAt, { apple: true });
    const finishedAt = importedTimestamp(value.completedAt, { apple: true });
    const owner = args.projectId || snapshot.projectId;
    saved = { id: id(value.id, 'run id'), suiteId, projectId: persist ? await project(app, owner) : id(owner || app.defaultProjectId, 'projectId'), suite: snapshot, suiteRevision: revision(snapshot), status, startedAt, finishedAt, durationMs: Math.max(0, Date.parse(finishedAt) - Date.parse(startedAt)), model: value.environment?.model, results, appRun: value, importedAt: new Date().toISOString() };
  }
  if (persist && await app.store.readOptional('runs', saved.id)) throw new Error('A run with this id already exists; imports never overwrite evidence');
  if (persist) await app.store.write('runs', saved, { createOnly: true }); const { ownerPid, ...publicRun } = saved; return { run: publicRun };
}
