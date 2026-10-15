import { randomUUID } from 'node:crypto';
import { suite, id, object, nativeResult, MAX_OUTPUT_BYTES } from './validation.mjs';
import { isAppSuite, revision, portableSuite, parseImport, sampleEnvelope, applyAssessment, validateAppEvidence } from './app-format.mjs';
import { addReferenceFile, exportReferences, importReferences } from './references.mjs';
import { importCases } from './case-import.mjs';
import { SPOTLIGHT_DEFAULTS } from './app-defaults.mjs';
const DEFAULT_PROJECT_ID = '00000000-0000-4000-8000-000000000001';
export async function initProjects(app) {
  if (!(await app.store.list('projects')).length) await app.store.write('projects', { id: DEFAULT_PROJECT_ID, name: 'My evaluations', description: '', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
  const projects = await app.store.list('projects');
  app.defaultProjectId = projects.find((item) => item.id === DEFAULT_PROJECT_ID)?.id || projects[0].id;
  for (const saved of await app.store.list('suites')) if (!saved.projectId || !saved.revision) await app.store.write('suites', { ...saved, projectId: saved.projectId || app.defaultProjectId, revision: revision(saved) });
  for (const run of await app.store.list('runs')) if (!run.projectId && run.status !== 'running') await app.store.write('runs', { ...run, projectId: run.suite?.projectId || app.defaultProjectId, suiteRevision: run.suiteRevision || (run.suite ? revision(run.suite) : undefined) });
}
async function project(app, value) { const projectId = id(value || app.defaultProjectId, 'projectId'); await app.store.read('projects', projectId); return projectId; }
async function existing(app, kind, key) {
  try { return await app.store.read(kind, key); } catch (error) { if (/not found$/.test(error.message)) return null; throw error; }
}
export async function saveSuite(app, args, { imported = false } = {}) {
  const value = args.suite;
  const saved = suite(value?.formatVersion === 1 ? Object.fromEntries(Object.entries(value).filter(([key]) => key !== 'formatVersion')) : value, randomUUID, { draft: true });
  // Imported configuration cannot authorize access to this Mac's indexed data.
  if (imported && isAppSuite(saved)) saved.features.spotlightSearch = structuredClone(SPOTLIGHT_DEFAULTS);
  const old = await existing(app, 'suites', saved.id);
  const expected = args.expectedRevision ?? value.revision;
  if (expected !== undefined && expected !== (old?.revision || (old ? revision(old) : undefined))) throw new Error('Suite revision conflict: reload the current suite before saving');
  saved.projectId = await project(app, args.projectId || saved.projectId || old?.projectId);
  saved.revision = revision(saved);
  saved.updatedAt = saved.revision === old?.revision ? old.updatedAt : new Date().toISOString();
  await app.store.write('suites', saved);
  return { suite: saved };
}
export function health(run, saved) {
  const sourceRevision = run.suiteRevision || (run.suite ? revision(run.suite) : null);
  const staleEvidence = !saved || !sourceRevision || sourceRevision !== (saved.revision || revision(saved));
  const appRun = run.appRun;
  const selected = appRun?.assessments?.find((assessment) => assessment.id?.toLowerCase() === appRun.selectedAssessmentID?.toLowerCase()) || (!appRun?.selectedAssessmentID ? appRun?.assessments?.at(-1) : null);
  return { staleEvidence, suiteMissing: !saved, currentAssessment: staleEvidence ? 'stale' : run.status !== 'completed' ? 'incomplete' : appRun?.selectedAssessmentID && !selected ? 'missing' : selected?.samples?.some((item) => item.errorCategory || item.errorMessage) ? 'error' : 'current', suiteRevision: sourceRevision, currentSuiteRevision: saved?.revision || null, ...(selected ? { assessmentId: selected.id } : {}) };
}
export async function overview(app, projectId) {
  const owner = await project(app, projectId);
  const suites = (await app.store.list('suites')).filter((item) => item.projectId === owner);
  const summaries = await app.runs(owner);
  return { project: await app.store.read('projects', owner), suiteCount: suites.length, runCount: summaries.length, activeRuns: summaries.filter((run) => run.status === 'running').length, currentSuites: summaries.filter((run) => run.status === 'completed' && !run.health.staleEvidence).reduce((set, run) => set.add(run.suiteId), new Set()).size, staleRuns: summaries.filter((run) => run.health.staleEvidence).length, suites: suites.map((item) => ({ id: item.id, name: item.name, revision: item.revision, caseCount: item.cases.length, latestRun: summaries.find((run) => run.suiteId === item.id) || null })), runs: summaries };
}
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
    case 'eval_import_suite': { const imported = parseImport(args, 'suite'); let definition = imported.suite || imported; const files = args.referenceFiles || imported.referenceFiles; if (files) definition = await importReferences(app, definition, files); return saveSuite(app, { ...args, suite: definition }, { imported: true }); }
    case 'eval_export_suite': { const saved = await app.store.read('suites', id(args.suiteId, 'suiteId')); const value = portableSuite(saved); const referenceFiles = await exportReferences(app, saved); return { suite: value, ...(referenceFiles.length ? { referenceFiles } : {}), revision: saved.revision, json: JSON.stringify(referenceFiles.length ? { suite: value, referenceFiles } : value, null, 2), filename: `${saved.name.replace(/[^a-z0-9_-]/gi, '-')}.json` }; }
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
      const ids = new Set(args.caseIds || run.results.map((item) => item.caseId));
      if ([...ids].some((key) => !run.results.some((item) => item.caseId === key))) throw new Error('Unknown case in run');
      return { runId: run.id, health: health(run, await existing(app, 'suites', run.suiteId)), cases: run.results.filter((item) => ids.has(item.caseId)).map((result) => ({ ...result, appSample: result.appSample || result.trace?.appSample || null })), assessments: run.appRun?.assessments || [] };
    }
    default: return undefined;
  }
}
async function importRun(app, args, { persist = true } = {}) {
  let value = object(parseImport(args, 'run'), 'run'); value = value.run || value;
  const evidence = value.appRun || value;
  if (evidence.developerExecution || (evidence.execution?.configuration?.provider && evidence.execution.configuration.provider !== 'onDevice') || evidence.results?.some((sample) => sample.judgeIdentity?.mode === 'connection') || evidence.assessments?.some((assessment) => assessment.judge?.mode === 'connection')) throw new Error('Only local on-device evaluation evidence is supported');
  if (Buffer.byteLength(JSON.stringify(value)) > MAX_OUTPUT_BYTES) throw new Error('Run import exceeds size limit');
  let saved;
  if (value.suite && value.status && value.results) {
    const snapshot = suite(value.suite, randomUUID);
    nativeResult({ ...value, status: value.status === 'completed' ? 'completed' : 'failed' }, snapshot, { allowAssessmentProjection: true });
    if (!['completed', 'failed', 'cancelled'].includes(value.status)) throw new Error('Only terminal runs can be imported');
    if (!Number.isFinite(Date.parse(value.startedAt)) || !Number.isFinite(Date.parse(value.finishedAt))) throw new Error('Run import requires valid timestamps');
    if (id(args.suiteId || value.suiteId, 'suiteId') !== snapshot.id) throw new Error('Run suite identity does not match its snapshot');
    const { ownerPid, ...safeValue } = value;
    saved = { ...safeValue, id: id(value.id, 'run id'), suiteId: id(args.suiteId || value.suiteId, 'suiteId'), suite: snapshot, projectId: await project(app, args.projectId || value.projectId || snapshot.projectId), suiteRevision: revision(snapshot) };
  } else {
    if (value.developerExecution || value.execution?.configuration?.provider && value.execution.configuration.provider !== 'onDevice' || value.results?.some((sample) => sample.judgeIdentity?.mode === 'connection') || value.assessments?.some((assessment) => assessment.judge?.mode === 'connection')) throw new Error('Only local on-device evaluation evidence is supported');
    validateAppEvidence(value);
    const suiteId = id(args.suiteId || value.suiteID, 'suiteId');
    let snapshot = await existing(app, 'suites', suiteId);
    const definition = value.suiteDefinition;
    if (definition) snapshot = suite(Object.fromEntries(Object.entries({ ...definition, attachments: definition.attachments || snapshot?.attachments?.filter((item) => value.attachments?.some((evidence) => evidence.name === item.name && evidence.sha256 === item.sha256 && evidence.kind === item.kind)) || value.attachments?.filter((item) => typeof item.text === 'string') || [] }).filter(([key]) => key !== 'formatVersion')), randomUUID);
    if (snapshot && snapshot.id !== suiteId) throw new Error('Run suite identity does not match its definition');
    if (!snapshot) {
      if (!Array.isArray(value.plannedCases) || !value.plannedCases.length) throw new Error('App run requires suiteDefinition, plannedCases, or an existing suite');
      snapshot = suite({ id: suiteId, name: value.suiteName, version: value.suiteVersion || 'v1', instructions: value.instructions, criteria: value.criteria, scoringMode: value.scoringMode, repetitions: value.repetitions, modelConfiguration: value.execution?.configuration, features: value.execution?.features, cases: value.plannedCases }, randomUUID);
    }
    let results = value.results?.map((sample) => { id(sample.id, 'sample id'); if (!['passed', 'failed', 'unscored', 'error'].includes(sample.status)) throw new Error('Invalid app sample status'); return sampleEnvelope(sample, snapshot.cases); });
    if (!results) throw new Error('App run requires sample results');
    const status = value.cancelled ? 'cancelled' : value.terminationReason || results.some((result) => result.appSample.status === 'error') ? 'failed' : 'completed';
    nativeResult({ status: status === 'completed' ? 'completed' : 'failed', results }, snapshot);
    results = applyAssessment(value, results);
    const startedAt = typeof value.startedAt === 'number' ? new Date((value.startedAt + 978307200) * 1000).toISOString() : value.startedAt;
    const finishedAt = typeof value.completedAt === 'number' ? new Date((value.completedAt + 978307200) * 1000).toISOString() : value.completedAt;
    if (!Number.isFinite(Date.parse(startedAt)) || !Number.isFinite(Date.parse(finishedAt))) throw new Error('App run requires valid timestamps');
    saved = { id: id(value.id, 'run id'), suiteId, projectId: await project(app, args.projectId || snapshot.projectId), suite: snapshot, suiteRevision: revision(snapshot), status, startedAt, finishedAt, durationMs: Math.max(0, Date.parse(finishedAt) - Date.parse(startedAt)), model: value.environment?.model, results, appRun: value, importedAt: new Date().toISOString() };
  }
  if (persist && await existing(app, 'runs', saved.id)) throw new Error('A run with this id already exists; imports never overwrite evidence');
  if (persist) await app.store.write('runs', saved); const { ownerPid, ...publicRun } = saved; return { run: publicRun };
}
