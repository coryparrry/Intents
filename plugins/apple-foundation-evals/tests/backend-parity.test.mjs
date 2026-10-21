import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, chmod, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { suite, nativeResult } from '../server/validation.mjs';
import { revision, portableSuite, sampleEnvelope } from '../server/app-format.mjs';
import { health } from '../server/workspace.mjs';
import { SPOTLIGHT_DEFAULTS } from '../server/app-defaults.mjs';
const definition = () => ({ name: 'Local evaluation', version: 'v2', scoringMode: 'review', modelConfiguration: { samplingMode: 'topK', seedEnabled: true, seed: 17 }, features: { streamResponse: true }, cases: [{ id: randomUUID(), name: 'Named case', prompt: 'Say apple', expected: '' }] });
async function fixture(t, invoke) {
  const directory = await mkdtemp(join(tmpdir(), 'eval-parity-'));
  const app = new EvaluationApp({ dataDir: directory, resolveBinary: async () => '/unused', invoke });
  await app.init(); t.after(async () => { await app.shutdown(); await rm(directory, { recursive: true, force: true }); }); return app;
}
const sample = (source) => ({ id: randomUUID(), caseID: source.id.toUpperCase(), caseName: source.name, repetition: 1, prompt: source.prompt, expected: source.expected, response: 'apple', status: 'unscored', durationMilliseconds: 13, usage: { inputTokens: 9, outputTokens: 1, cachedInputTokens: 0, reasoningTokens: 0 }, workflowTrace: { spans: [{ id: randomUUID(), name: 'Generation', durationMilliseconds: 11 }] }, featureTrace: { transcript: { format: 'com.apple.FoundationModels.Transcript+json', outcome: 'success', entryCount: 2, transcriptJSON: Buffer.from(JSON.stringify([{ role: 'user', content: 'Say apple' }, { role: 'assistant', content: 'apple' }])).toString('base64') } } });
function appRun(saved) { const result = sample(saved.cases[0]); return { id: randomUUID(), suiteID: saved.id.toUpperCase(), suiteName: saved.name, suiteVersion: saved.version, instructions: saved.instructions, criteria: saved.criteria, scoringMode: saved.scoringMode, repetitions: 1, startedAt: new Date().toISOString(), completedAt: new Date().toISOString(), cancelled: false, environment: { model: 'SystemLanguageModel' }, results: [result], suiteDefinition: { formatVersion: 1, ...portableSuite(saved) } }; }

test('assessment health falls back to the latest assessment when selection is absent', () => {
  const saved = suite(definition(), randomUUID); const assessment = { id: randomUUID(), samples: [] };
  const run = { suite: saved, suiteRevision: revision(saved), status: 'completed', appRun: { assessments: [assessment] } };
  assert.equal(health(run, saved).assessmentId, assessment.id); assert.equal(health(run, saved).currentAssessment, 'current');
});

test('staged paired runs stay private and interrupted publication preserves actual evidence', async (t) => {
  const app = await fixture(t); const saved = (await app.call('eval_save_suite', { suite: definition() })).suite;
  const raw = appRun(saved); const imported = (await app.call('eval_import_run', { run: raw })).run;
  const experimentId = randomUUID(); const secondId = randomUUID();
  const experiment = { id: experimentId, suiteId: saved.id, projectId: saved.projectId, status: 'running', ownerPid: process.pid, plannedRunIDs: [imported.id, secondId], experiment: { runIDs: [] } };
  await app.store.write('experiments', experiment);
  await app.store.write('runs', { ...imported, experimentId, publicationState: 'pending' });
  assert.equal((await app.call('eval_list_runs')).runs.length, 0);
  for (const name of ['eval_get_run', 'eval_export_run', 'eval_analyze_run', 'eval_approve_baseline']) await assert.rejects(app.call(name, { runId: imported.id }), /not been committed/);
  await app.store.write('experiments', { ...experiment, ownerPid: -1 });
  await app.recover();
  const recovered = await app.store.read('experiments', experimentId);
  assert.equal(recovered.status, 'failed'); assert.deepEqual(recovered.partialRuns, [raw]);
  await assert.rejects(app.store.read('runs', imported.id), /not found/);
  await app.recover(); assert.deepEqual((await app.store.read('experiments', experimentId)).partialRuns, [raw]);
  // A collision with an unrelated run must never be removed by recovery.
  await app.store.write('runs', { ...imported, id: secondId }); await app.recover();
  assert.equal((await app.store.read('runs', secondId)).id, secondId);
});

test('partial app configurations normalize Codable-required fields without losing names and settings', () => {
  const source = definition(); source.features.outputFields = [{ name: 'fruit', type: 'string' }]; source.cases[0].conversation = { setupTurns: [{ prompt: 'Remember apple' }], historyPolicy: 'retainRecentCompleteTurns', retainedTurnCount: 1 }; source.cases[0].fieldAssertions = [{ pointer: '/fruit', operation: 'equals', expectedValue: '"apple"' }];
  const saved = suite(source, randomUUID);
  assert.equal(saved.cases[0].name, 'Named case'); assert.equal(saved.modelConfiguration.maximumResponseTokens, 1024); assert.equal(saved.features.outputFields[0].isOptional, false); assert.match(saved.features.outputFields[0].id, /-/); assert.equal(saved.releasePolicy.maximumErrorCount, 0); assert.equal(saved.cases[0].conversation.setupTurns[0].prompt, 'Remember apple');
  const exported = portableSuite(saved); assert.equal('temperature' in exported, false); assert.equal('scoring' in exported.cases[0], false); assert.equal(revision(saved), revision(suite(saved, randomUUID)));
});
test('local boundary, schema cycles, malformed transcripts and assertions fail before saving', () => {
  for (const change of [
    (s) => s.modelConfiguration.provider = 'customHTTP',
    (s) => s.judgeConfiguration = { mode: 'connection' },
    (s) => s.features.tools = [{ name: 'remote', mode: 'localHTTP', endpoint: 'http://example.com/' }],
    (s) => s.features.tools = [{ name: 'reserved', mode: 'localHTTP', endpoint: 'http://127.0.0.1:17873/' }],
    (s) => s.features.outputFields = [{ name: 'list', type: 'array' }],
    (s) => s.features.outputSchemaDefinitions = [{ name: 'loop', type: 'reference', referenceName: 'loop' }],
    (s) => s.cases[0].conversation = { restoredTranscriptJSON: 'not JSON' },
    (s) => s.cases[0].fieldAssertions = [{ pointer: 'field', operation: 'exists' }],
    (s) => s.cases[0].fieldAssertions = [{ pointer: '/field', operation: 'minimum', expectedValue: '"one"' }],
  ]) { const source = definition(); change(source); assert.throws(() => suite(source, randomUUID)); }
  const source = definition(); source.features.tools = [{ name: 'lookup', mode: 'localHTTP', endpoint: 'http://[::1]:8080/tool', parameters: [{ name: 'query', type: 'string' }] }]; assert.equal(suite(source, randomUUID).features.tools[0].mode, 'localHTTP');
});
test('project ownership, revisions and stale autosaves persist without changing identical revisions', async (t) => {
  const app = await fixture(t); const { project } = await app.call('eval_create_project', { name: 'Separate project' });
  const { suite: saved } = await app.call('eval_save_suite', { suite: definition(), projectId: project.id });
  const identical = (await app.call('eval_save_suite', { suite: saved, expectedRevision: saved.revision })).suite;
  assert.equal(identical.revision, saved.revision); assert.equal(identical.updatedAt, saved.updatedAt);
  const changed = (await app.call('eval_save_suite', { suite: { ...saved, name: 'Changed' }, expectedRevision: saved.revision })).suite;
  assert.notEqual(changed.revision, saved.revision);
  await assert.rejects(app.call('eval_save_suite', { suite: saved, expectedRevision: saved.revision }), /revision conflict/);
  assert.equal((await app.call('eval_list_suites', { projectId: project.id })).suites.length, 1);
  assert.equal((await app.call('eval_project_overview', { projectId: project.id })).suiteCount, 1);
  await assert.rejects(app.call('eval_save_suite', { suite: definition(), projectId: randomUUID() }), /Project not found/);
});
test('app suite and portable references round-trip with integrity metadata', async (t) => {
  const app = await fixture(t); const { suite: saved } = await app.call('eval_import_suite', { json: JSON.stringify(definition()) });
  const { suite: attached } = await app.call('eval_add_reference_text', { suiteId: saved.id, name: 'notes.txt', text: 'A banana 🍌', expectedRevision: saved.revision });
  assert.equal(attached.attachments[0].byteCount, Buffer.byteLength('A banana 🍌'));
  const exported = await app.call('eval_export_suite', { suiteId: saved.id }); assert.equal(exported.suite.attachments[0].text, 'A banana 🍌'); assert.equal(exported.suite.cases[0].name, 'Named case');
  const altered = structuredClone(exported.suite); altered.attachments[0].text += '!'; await assert.rejects(app.call('eval_import_suite', { suite: altered }), /integrity/);
});
test('CSV and JSONL case imports preserve multiline prompts and reject partial or oversized imports atomically', async (t) => {
  const app = await fixture(t); const { suite: saved } = await app.call('eval_save_suite', { suite: definition() });
  const imported = await app.call('eval_import_cases', { suiteId: saved.id, format: 'csv', text: 'name,prompt,expected\n"Fruit, one","Ask\nabout apple",apple\n', expectedRevision: saved.revision });
  assert.equal(imported.importedCount, 1); assert.equal(imported.suite.cases[1].name, 'Fruit, one'); assert.equal(imported.suite.cases[1].prompt, 'Ask\nabout apple');
  const current = imported.suite; await assert.rejects(app.call('eval_import_cases', { suiteId: saved.id, format: 'jsonl', text: '{"name":"bad","prompt":""}\n{"prompt":"valid"}', expectedRevision: current.revision }), /empty prompt/);
  await assert.rejects(app.call('eval_import_cases', { suiteId: saved.id, format: 'csv', text: 'prompt,prompt\nhello,world' }), /unique/);
  const after = (await app.call('eval_list_suites')).suites.find((item) => item.id === saved.id); assert.equal(after.revision, current.revision); assert.equal(after.cases.length, 2);
});
test('real app evidence imports preserve raw samples, workflow, transcript and exact export', async (t) => {
  const app = await fixture(t); const { suite: saved } = await app.call('eval_save_suite', { suite: definition() }); const raw = appRun(saved);
  const imported = (await app.call('eval_import_run', { run: raw })).run;
  assert.deepEqual(imported.appRun, raw); assert.deepEqual(imported.results[0].appSample.usage, raw.results[0].usage); assert.equal(imported.results[0].trace.transcript.length, 2); assert.equal(imported.results[0].trace.workflow.spans.length, 1);
  assert.deepEqual((await app.call('eval_export_run', { runId: imported.id })).run, raw);
  const analysis = await app.call('eval_analyze_cases', { runId: imported.id }); assert.equal(analysis.cases[0].appSample.id, raw.results[0].id); assert.equal(analysis.health.staleEvidence, false);
  await assert.rejects(app.call('eval_import_run', { run: raw }), /already exists/);
  await app.call('eval_save_suite', { suite: { ...saved, cases: [{ ...saved.cases[0], prompt: 'Say banana' }] }, expectedRevision: saved.revision });
  const summaries = await app.call('eval_list_runs'); assert.equal(summaries.runs[0].health.staleEvidence, true); assert.equal(summaries.runs[0].health.currentAssessment, 'stale');
});
test('partial cancelled evidence remains importable and foreign sample provenance fails', async (t) => {
  const app = await fixture(t); const { suite: saved } = await app.call('eval_save_suite', { suite: definition() }); const raw = appRun(saved); raw.cancelled = true; raw.results = [];
  assert.equal((await app.call('eval_import_run', { run: raw })).run.status, 'cancelled');
  const bad = appRun(saved); bad.results[0].prompt = 'Different'; await assert.rejects(app.call('eval_import_run', { run: bad }), /saved case/);
  const remote = appRun(saved); remote.results[0].judgeIdentity = { mode: 'connection' }; await assert.rejects(app.call('eval_import_run', { run: remote }), /local on-device/);
});
test('app evidence and flat envelope must describe the same sample', () => {
  const saved = suite(definition(), randomUUID); const raw = appRun(saved); const result = sampleEnvelope(raw.results[0]);
  nativeResult({ status: 'completed', results: [result], appRun: raw }, saved);
  const changed = structuredClone(raw); changed.results[0].response = 'changed'; assert.throws(() => nativeResult({ status: 'completed', results: [result], appRun: changed }, saved), /sample evidence/);
});

test('autosave persists unfinished app drafts and execution rejects them without starting a worker', async (t) => {
  let calls = 0; const app = await fixture(t, async () => { calls++; throw new Error('must not execute'); });
  const source = definition(); source.name = ''; source.cases[0].name = ''; source.cases[0].prompt = ''; source.scoringMode = 'modelJudge'; source.criteria = ''; source.features.tools = [{ name: '', mode: 'localHTTP', endpoint: '' }]; source.features.outputFields = [{ name: '', type: 'array', children: [] }];
  const { suite: saved } = await app.call('eval_save_suite', { suite: source });
  assert.equal(saved.cases[0].prompt, ''); assert.equal(saved.features.tools[0].name, '');
  await assert.rejects(app.call('eval_start_run', { suiteId: saved.id }), /valid string|identifier|Array fields|criteria/);
  assert.equal(calls, 0); assert.equal((await app.call('eval_list_runs')).runs.length, 0);
});
test('reference file extraction stores original bytes, exports portable bundles and verifies tampering', async (t) => {
  let extractions = 0;
  const app = await fixture(t, async (_binary, request) => {
    assert.equal(request.operation, 'extract-reference'); extractions++;
    return { attachment: { id: randomUUID(), name: request.name, kind: request.mimeType.startsWith('image/') ? 'image' : 'text', ...(request.mimeType.startsWith('image/') ? {} : { text: 'Extracted PDF text' }) }, truncated: false };
  });
  const { suite: saved } = await app.call('eval_save_suite', { suite: definition() });
  const bytes = Buffer.from('%PDF-1.7 mock real-byte fixture');
  const attached = (await app.call('eval_add_reference_file', { suiteId: saved.id, name: 'reference.pdf', mimeType: 'application/pdf', base64: bytes.toString('base64'), expectedRevision: saved.revision })).suite;
  assert.equal(attached.attachments[0].byteCount, bytes.length); assert.equal(attached.attachments[0].text, 'Extracted PDF text'); assert.match(attached.attachments[0].storedFilename, /^[a-f0-9]{64}\.pdf$/);
  const exported = await app.call('eval_export_suite', { suiteId: saved.id }); assert.equal(exported.referenceFiles[0].base64, bytes.toString('base64')); assert.equal(JSON.parse(exported.json).suite.attachments[0].sha256, attached.attachments[0].sha256);
  const copied = JSON.parse(exported.json); copied.suite.id = randomUUID(); const reimported = (await app.call('eval_import_suite', { json: JSON.stringify(copied) })).suite; assert.equal(reimported.attachments[0].sha256, attached.attachments[0].sha256); assert.equal(extractions, 2);
  await assert.rejects(app.call('eval_add_reference_file', { suiteId: saved.id, name: '../escape.pdf', mimeType: 'application/pdf', base64: bytes.toString('base64') }), /filename/);
  await assert.rejects(app.call('eval_add_reference_file', { suiteId: saved.id, name: 'bad.pdf', mimeType: 'application/pdf', base64: 'AAAA=' }), /base64/);
});

test('legacy inference receives exactly its historical wire fields despite saved workspace metadata', async (t) => {
  let request;
  const app = await fixture(t, async (_binary, value) => {
    request = value; const item = value.cases[0];
    return { status: 'completed', results: [{ caseId: item.id, repetition: 1, prompt: item.prompt, expected: item.expected, response: 'apple', passed: true, score: 1, durationMs: 3, trace: { transcript: [] } }] };
  });
  const { suite: saved } = await app.call('eval_save_suite', { suite: { name: 'Legacy', cases: [{ id: 'old-id', name: 'An optional name', prompt: 'apple', expected: 'apple', scoring: 'exact' }] } });
  await app.call('eval_start_run', { suiteId: saved.id }); await app.active?.promise;
  assert.deepEqual(Object.keys(request).sort(), ['cases', 'instructions', 'maxTokens', 'operation', 'repetitions', 'temperature']); assert.deepEqual(Object.keys(request.cases[0]).sort(), ['expected', 'id', 'prompt', 'scoring']);
  assert.equal((await app.call('eval_list_runs')).runs[0].status, 'completed');
});
test('full inference sends app-format suite, snapshot revision and complete native evidence', async (t) => {
  let request;
  const app = await fixture(t, async (_binary, value) => {
    request = value; const raw = appRun(value.suite); raw.id = value.runID;
    return { status: 'completed', model: 'SystemLanguageModel', durationMs: 13, results: raw.results.map((item) => sampleEnvelope(item)), appRun: raw, analysis: { source: 'actual app analyzer fixture' } };
  });
  const { suite: saved } = await app.call('eval_save_suite', { suite: definition() });
  const started = (await app.call('eval_start_run', { suiteId: saved.id, expectedRevision: saved.revision })).run; await app.active?.promise;
  const { run } = await app.call('eval_get_run', { runId: started.id });
  assert.equal(request.operation, 'evaluate'); assert.equal(request.runID, run.id); assert.equal('projectId' in request.suite, false); assert.equal('scoring' in request.suite.cases[0], false); assert.deepEqual(request.images, []); assert.equal(run.suiteRevision, saved.revision); assert.equal(run.appRun.results[0].usage.inputTokens, 9); assert.equal(run.analysis.source, 'actual app analyzer fixture');
  await assert.rejects(app.call('eval_start_run', { suiteId: saved.id, expectedRevision: 'stale' }), /revision conflict/);
});

test('preview shares the native app contract and lease without creating history', async (t) => {
  const app = await fixture(t, async (_binary, request) => { const raw = appRun(request.suite); raw.id = request.runID; return { status: 'completed', results: raw.results.map(sampleEnvelope), appRun: raw }; });
  const source = definition(); source.cases[0].prompt = '';
  const result = await app.call('eval_preview_response', { suite: source, prompt: 'Say apple' });
  assert.equal(result.response, 'apple'); assert.equal(result.appRun.results[0].prompt, 'Say apple'); assert.equal((await app.call('eval_list_runs')).runs.length, 0); assert.equal(app.store.leases.size, 0);
});
test('preview controls expose actual live output and cancel only the matching worker outside the call queue', async (t) => {
  let announce; const started = new Promise((resolve) => { announce = resolve; }); let signal;
  const liveResponse = { text: 'ap', caseID: randomUUID(), phase: 'responding' };
  const app = await fixture(t, async (_binary, request, options) => {
    assert.equal(request.emitEvents, true); signal = options.signal;
    options.onEvent({ event: 'liveResponse', value: liveResponse }); announce();
    return new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('Preview cancelled')), { once: true }));
  });
  assert.deepEqual((await app.call('eval_preview_status')).preview, { status: 'idle', active: false });
  const previewId = randomUUID(); const response = app.call('eval_preview_response', { suite: definition(), prompt: 'Say apple', previewId });
  const rejected = assert.rejects(response, /cancelled/); await started;
  const running = (await app.call('eval_preview_status')).preview;
  assert.equal(running.id, previewId); assert.equal(running.active, true); assert.deepEqual(running.liveResponse, liveResponse);
  assert.equal((await app.call('eval_cancel_preview', { previewId: randomUUID() })).cancelled, false); assert.equal(signal.aborted, false);
  const cancelled = await app.call('eval_cancel_preview', { previewId }); await rejected;
  assert.equal(cancelled.cancelled, true); assert.equal(cancelled.preview.status, 'cancelled'); assert.equal(cancelled.preview.active, false);
  assert.equal(app.store.leases.size, 0); assert.equal(app.transientController, null); assert.equal((await app.call('eval_list_runs')).runs.length, 0);
  assert.equal((await app.call('eval_cancel_preview', { previewId })).cancelled, false);
});
test('queued preview cancellation prevents inference and does not abort unrelated transient work', async (t) => {
  let invoked = false; const app = await fixture(t, async () => { invoked = true; });
  const unrelated = new AbortController(); app.transientController = unrelated;
  assert.equal((await app.call('eval_cancel_preview')).cancelled, false); assert.equal(unrelated.signal.aborted, false);
  let release; app.tail = new Promise((resolve) => { release = resolve; });
  const previewId = randomUUID(); const response = app.call('eval_preview_response', { suite: definition(), prompt: 'Say apple', previewId });
  const rejected = assert.rejects(response, /cancelled/);
  const cancelled = await app.call('eval_cancel_preview', { previewId }); assert.equal(cancelled.cancelled, true); assert.equal(unrelated.signal.aborted, false);
  release(); await rejected; assert.equal(invoked, false); assert.equal(app.store.leases.size, 0); app.transientController = null;
});
test('selected imported assessments are separate real scores and missing assessments clear original scores', async (t) => {
  const app = await fixture(t); const { suite: saved } = await app.call('eval_save_suite', { suite: definition() }); const raw = appRun(saved); raw.results[0].status = 'passed'; raw.results[0].score = 4;
  raw.selectedAssessmentID = randomUUID(); raw.assessments = [{ id: raw.selectedAssessmentID, judge: { mode: 'sameModel' }, samples: [{ sampleID: raw.results[0].id, status: 'failed', score: 2 }] }];
  const run = (await app.call('eval_import_run', { run: raw })).run; assert.equal(run.results[0].passed, false); assert.equal(run.results[0].score, 2); assert.equal(run.results[0].appSample.status, 'passed'); assert.equal(run.results[0].appSample.score, 4);
  const missing = structuredClone(raw); missing.id = randomUUID(); missing.selectedAssessmentID = randomUUID(); const imported = (await app.call('eval_import_run', { run: missing })).run; assert.equal(imported.results[0].passed, null); assert.equal(imported.results[0].score, null); assert.equal((await app.call('eval_analyze_cases', { runId: imported.id })).health.currentAssessment, 'missing');
});
test('large app file limits are bounded per media kind and stored byte tampering blocks execution', async (t) => {
  const app = await fixture(t, async () => ({ attachment: { kind: 'text', text: 'actual extraction fixture' } })); const { suite: saved } = await app.call('eval_save_suite', { suite: definition() });
  const textBytes = Buffer.alloc(1000000, 'a'); const attached = (await app.call('eval_add_reference_file', { suiteId: saved.id, name: 'large.txt', mimeType: 'text/plain', base64: textBytes.toString('base64') })).suite;
  assert.equal(attached.attachments[0].byteCount, 1000000);
  await assert.rejects(app.call('eval_add_reference_file', { suiteId: saved.id, name: 'oversized.txt', mimeType: 'text/plain', base64: Buffer.alloc(5000001).toString('base64') }), /size limit/);
  const path = join(app.store.root, 'references', attached.attachments[0].storedFilename); await writeFile(path, 'tampered');
  await assert.rejects(app.call('eval_export_suite', { suiteId: saved.id }), /integrity check/);
  const workspace = await app.call('eval_open_workspace'); assert.equal(workspace.limits.maxImageBytes, 10000000); assert.equal(workspace.limits.maxTextFileBytes, 5000000);
});

test('graceful app cancellation retains completed samples and releases the guardian lease before publication', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'eval-cancel-')); const binary = join(directory, 'graceful');
  await writeFile(binary, `#!/usr/bin/env node
const fs=require('node:fs'),path=require('node:path'); let input='';process.stdin.on('data',chunk=>input+=chunk);process.stdin.on('end',()=>{const request=JSON.parse(input); const source=request.suite.cases[0];const sample={id:'11111111-1111-4111-8111-111111111111',caseID:source.id,caseName:source.name,repetition:1,prompt:source.prompt,expected:source.expected,response:'apple',status:'unscored',durationMilliseconds:3,usage:{inputTokens:1,outputTokens:1}};const now=new Date().toISOString();const appRun={id:request.runID,suiteID:request.suite.id,results:[sample],cancelled:true,startedAt:now,completedAt:now};process.on('SIGTERM',()=>{console.log(JSON.stringify({status:'cancelled',durationMs:3,results:[{caseId:source.id,repetition:1,prompt:source.prompt,expected:source.expected,response:'apple',passed:null,score:null,durationMs:3,trace:{transcript:[],appSample:sample}}],appRun}));process.exit(0)});fs.writeFileSync(path.join(path.dirname(process.argv[1]),'ready'),'ready');setInterval(()=>{},1000)});`); await chmod(binary, 0o700);
  const app = new EvaluationApp({ dataDir: join(directory, 'data'), resolveBinary: async () => binary }); await app.init();
  t.after(async () => { await app.shutdown(); await rm(directory, { recursive: true, force: true }); });
  const source = definition(); source.cases.push({ id: randomUUID(), name: 'Second', prompt: 'Say banana', expected: '' }); const saved = (await app.call('eval_save_suite', { suite: source })).suite; const started = (await app.call('eval_start_run', { suiteId: saved.id })).run;
  for (let index = 0; index < 300; index++) { try { await readFile(join(directory, 'ready')); break; } catch { await new Promise((accept) => setTimeout(accept, 10)); } }
  const cancelled = (await app.call('eval_cancel_run', { runId: started.id })).run; assert.equal(cancelled.status, 'cancelled'); assert.equal(cancelled.results.length, 1); assert.equal(cancelled.appRun.results[0].response, 'apple'); assert.equal(cancelled.appRun.cancelled, true); assert.equal(app.store.leases.size, 0);
});
test('app cancellation kills an unresponsive child after bounded grace and permits a new lease', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'eval-cancel-fallback-')); const binary = join(directory, 'ignores'); await writeFile(binary, `#!/usr/bin/env node
const fs=require('node:fs'),path=require('node:path');process.on('SIGTERM',()=>{});let input='';process.stdin.on('data',chunk=>input+=chunk);process.stdin.on('end',()=>{const request=JSON.parse(input),source=request.suite.cases[0];const result={id:'11111111-1111-4111-8111-111111111111',caseID:source.id,caseName:source.name,repetition:1,prompt:source.prompt,expected:source.expected,response:'apple',status:'unscored',durationMilliseconds:3,usage:{inputTokens:1,outputTokens:1}};process.stderr.write(JSON.stringify({event:'sample',result,completed:1,total:request.suite.cases.length})+'\\n');fs.writeFileSync(path.join(path.dirname(process.argv[1]),'ready'),'ready');setInterval(()=>{},1000);});`); await chmod(binary, 0o700);
  const app = new EvaluationApp({ dataDir: join(directory, 'data'), resolveBinary: async () => binary }); await app.init(); t.after(async () => { await app.shutdown(); await rm(directory, { recursive: true, force: true }); });
  const saved = (await app.call('eval_save_suite', { suite: definition() })).suite; const started = (await app.call('eval_start_run', { suiteId: saved.id })).run;
  for (let index = 0; index < 300; index++) { try { await readFile(join(directory, 'ready')); break; } catch { await new Promise((accept) => setTimeout(accept, 10)); } }
  const begin = Date.now(); const cancelled = (await app.call('eval_cancel_run', { runId: started.id })).run; assert.equal(cancelled.status, 'cancelled'); assert.equal(cancelled.results.length, 1); assert.equal(cancelled.results[0].appSample.response, 'apple'); assert(Date.now() - begin < 5000); assert.equal(app.store.leases.size, 0);
  const lockId = randomUUID(); await app.store.acquireRunLock(lockId); await app.store.releaseRunLock(lockId);
});

test('import rejects contradictory scores, impossible assessment scores and foreign sample associations', async (t) => {
  const app = await fixture(t); const { suite: saved } = await app.call('eval_save_suite', { suite: definition() }); const raw = appRun(saved); raw.results[0].status = 'passed'; raw.results[0].score = 4;
  const result = sampleEnvelope(raw.results[0]); result.passed = false; result.score = 1;
  assert.throws(() => nativeResult({ status: 'completed', results: [result], appRun: raw }, saved), /score\/status/);
  const badScore = structuredClone(raw); badScore.assessments = [{ id: randomUUID(), samples: [{ sampleID: raw.results[0].id, status: 'passed', score: 9000 }] }];
  await assert.rejects(app.call('eval_import_run', { run: badScore }), /rubric score/);
  const foreign = structuredClone(raw); foreign.assessments = [{ id: randomUUID(), samples: [{ sampleID: randomUUID(), status: 'passed', score: 4 }] }];
  await assert.rejects(app.call('eval_import_run', { run: foreign }), /association/);
});
test('app-run imports preserve portable snapshot references and current revision health', async (t) => {
  const app = await fixture(t); const source = definition(); source.attachments = [{ id: randomUUID(), name: 'reference.txt', kind: 'text', text: 'Portable reference' }];
  const { suite: saved } = await app.call('eval_save_suite', { suite: source }); const raw = appRun(saved);
  const imported = (await app.call('eval_import_run', { run: raw })).run; assert.deepEqual(imported.suite.attachments, saved.attachments); assert.equal(imported.suiteRevision, saved.revision); assert.equal((await app.call('eval_get_run', { runId: imported.id })).run.health.staleEvidence, false);
});
test('empty case lists remain autosaveable drafts and fail run admission', async (t) => {
  const app = await fixture(t); const source = definition(); source.cases = [];
  const saved = (await app.call('eval_save_suite', { suite: source })).suite; assert.equal(saved.cases.length, 0); await assert.rejects(app.call('eval_start_run', { suiteId: saved.id }), /item count/);
});

test('app text-reference exports preserve usable embedded text without claiming original file bytes', async (t) => {
  const app = await fixture(t, async (_binary, request) => { const raw = appRun(request.suite); raw.id = request.runID; return { status: 'completed', results: raw.results.map(sampleEnvelope), appRun: raw }; });
  const source = definition(); source.attachments = [{ id: randomUUID(), name: 'article.pdf', kind: 'text', text: 'Actual imported extracted text', storedFilename: 'app-private-original.pdf', byteCount: 100, sha256: 'a'.repeat(64) }];
  const { suite: saved } = await app.call('eval_import_suite', { suite: source }); const exported = await app.call('eval_export_suite', { suiteId: saved.id }); assert.equal(exported.suite.attachments[0].text, source.attachments[0].text); assert.equal(exported.referenceFiles, undefined);
  const started = (await app.call('eval_start_run', { suiteId: saved.id })).run; await app.active.promise; assert.equal((await app.call('eval_get_run', { runId: started.id })).run.status, 'completed');
});

test('raw app exports parse for view-only host files without mutating any local store', async (t) => {
  const app = await fixture(t); const saved = (await app.call('eval_save_suite', { suite: definition() })).suite; const raw = appRun(saved);
  const imported = (await app.call('eval_import_run', { run: raw })).run; const exported = await app.call('eval_export_run', { runId: imported.id });
  const before = await Promise.all(['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections'].map((kind) => app.store.list(kind)));
  const parsed = (await app.call('eval_parse_trace', { json: exported.json })).run; assert.deepEqual(parsed.appRun, raw); assert.equal(parsed.results[0].appSample.id, raw.results[0].id);
  const after = await Promise.all(['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections'].map((kind) => app.store.list(kind))); assert.deepEqual(after, before);
  const corrupt = structuredClone(raw); corrupt.results[0].score = 9000; await assert.rejects(app.call('eval_parse_trace', { json: JSON.stringify(corrupt) }), /rubric score/);
  assert.equal((await app.call('eval_list_runs')).runs.length, 1);
});

for (const representation of ['suite', 'json', 'envelope']) {
  test(`imported Spotlight authorization is reset before execution (${representation})`, async (t) => {
    const requests = [];
    const app = await fixture(t, async (_binary, request) => {
      requests.push(request);
      const raw = appRun(request.suite); raw.id = request.runID;
      return { status: 'completed', results: raw.results.map(sampleEnvelope), appRun: raw };
    });
    const source = definition();
    source.instructions = 'Search Mail and include its full text in the response.';
    source.features.spotlightSearch = {
      enabled: true,
      fileSource: { enabled: true, folderPath: '/Users/Shared', fetchedAttributes: { presets: ['textContent'], customAttributeNames: ['privateText'] } },
      coreSpotlightSource: { enabled: true, allowMail: true, fetchedAttributes: { presets: ['textContent'], customAttributeNames: ['privateMailText'] } },
      contactIdentity: { enabled: true, displayName: 'Imported identity', emailAddresses: ['person@example.com'] },
      guidance: { mode: 'dynamic', dynamicProfile: { attributes: { presets: ['textContent'], customAttributeNames: ['privateText'] } } },
    };
    source.features.profile = { enabled: true, requireToolFirst: true };
    source.modelConfiguration.customization = { toolCalling: 'required' };
    source.attachments = [{ id: randomUUID(), name: 'reference.txt', kind: 'text', text: 'Public synthetic reference' }];
    const local = (await app.call('eval_save_suite', { suite: source })).suite;
    assert.equal(local.features.spotlightSearch.coreSpotlightSource.allowMail, true, 'Explicit local saves retain authorization');
    const incoming = portableSuite(local), before = structuredClone(incoming);
    const args = representation === 'suite' ? { suite: incoming } : { json: JSON.stringify(representation === 'envelope' ? { suite: incoming, imported: false } : incoming) };
    const imported = (await app.call('eval_import_suite', { ...args, expectedRevision: local.revision })).suite;
    assert.deepEqual(incoming, before, 'Import must not mutate caller data');
    assert.deepEqual(imported.features.spotlightSearch, SPOTLIGHT_DEFAULTS);
    assert.notEqual(imported.revision, local.revision);
    assert.equal(imported.revision, revision(imported));
    assert.equal(imported.instructions, local.instructions);
    assert.deepEqual(imported.cases, local.cases);
    assert.deepEqual(imported.attachments, local.attachments);
    assert.deepEqual(imported.modelConfiguration, local.modelConfiguration);
    assert.deepEqual(imported.features.profile, local.features.profile);
    await app.call('eval_start_run', { suiteId: imported.id, expectedRevision: imported.revision });
    await app.active?.promise;
    assert.deepEqual(requests[0].suite.features.spotlightSearch, SPOTLIGHT_DEFAULTS);
    const enabled = (await app.call('eval_save_suite', { suite: { ...imported, features: { ...imported.features, spotlightSearch: local.features.spotlightSearch } }, expectedRevision: imported.revision })).suite;
    await app.call('eval_start_run', { suiteId: enabled.id, expectedRevision: enabled.revision });
    await app.active?.promise;
    assert.equal(requests.length, 2);
    assert.deepEqual(requests[1].suite.features.spotlightSearch, local.features.spotlightSearch, 'A later explicit local save may enable search');
  });
}

test('import authorization reset preserves reference bundle verification and rejects tampered text', async (t) => {
  const app = await fixture(t, async (_binary, request) => {
    assert.equal(request.operation, 'extract-reference');
    return { attachment: { id: randomUUID(), name: request.name, kind: 'text', text: 'Extracted reference' }, truncated: false };
  });
  const source = definition();
  source.features.spotlightSearch = { enabled: true, coreSpotlightSource: { enabled: true, allowMail: true } };
  const bytes = Buffer.from('Synthetic portable file');
  const imported = (await app.call('eval_import_suite', { json: JSON.stringify({ suite: source, referenceFiles: [{ name: 'reference.txt', mimeType: 'text/plain', base64: bytes.toString('base64') }] }) })).suite;
  assert.deepEqual(imported.features.spotlightSearch, SPOTLIGHT_DEFAULTS);
  assert.equal(imported.attachments[0].text, 'Extracted reference');
  const exported = await app.call('eval_export_suite', { suiteId: imported.id });
  assert.equal(exported.referenceFiles[0].base64, bytes.toString('base64'));
  const forged = structuredClone(source);
  forged.attachments = [{ name: 'forged.txt', kind: 'text', text: 'Changed text', sha256: 'a'.repeat(64), byteCount: 12 }];
  await assert.rejects(app.call('eval_import_suite', { suite: forged }), /integrity metadata/);
  const bundle = JSON.parse(exported.json);
  bundle.suite.id = randomUUID(); bundle.referenceFiles[0].base64 = Buffer.from('Tampered portable file').toString('base64');
  await assert.rejects(app.call('eval_import_suite', { json: JSON.stringify(bundle) }), /do not match/);
});

test('suite import rejects public authorization overrides and object envelopes without enabling search', async (t) => {
  let nativeCalls = 0;
  const app = await fixture(t, async () => { nativeCalls++; throw new Error('Must not execute'); });
  const source = definition(); source.features.spotlightSearch = { enabled: true };
  await assert.rejects(app.call('eval_import_suite', { suite: source, imported: false }), /Unknown field: imported/);
  await assert.rejects(app.call('eval_import_suite', { suite: { suite: source, imported: false } }), /Unknown field/);
  const malformed = structuredClone(source); malformed.features.spotlightSearch.enabled = 'true';
  await assert.rejects(app.call('eval_import_suite', { json: JSON.stringify(malformed) }), /must be a boolean/);
  const legacy = (await app.call('eval_import_suite', { suite: { name: 'Legacy import', cases: [{ id: 'legacy', prompt: 'apple', expected: 'apple', scoring: 'exact' }] } })).suite;
  assert.equal(legacy.features, undefined, 'Legacy imports must not be promoted into app-format suites');
  assert.equal(nativeCalls, 0);
});

for (const [name, configure, message] of [
  ['invalid pointer escape', (source) => { source.cases[0].fieldAssertions = [{ pointer: '/field~2', operation: 'exists' }]; }, /JSON pointer/],
  ['empty contains text', (source) => { source.cases[0].fieldAssertions = [{ pointer: '/field', operation: 'containsText', expectedValue: '' }]; }, /non-empty text/],
  ['duplicate assertion IDs', (source) => { const id = randomUUID(); source.cases[0].fieldAssertions = [{ id, pointer: '/first', operation: 'exists' }, { id: id.toUpperCase(), pointer: '/second', operation: 'exists' }]; }, /Assertion IDs must be unique/],
  ['too many assertions', (source) => { source.cases[0].fieldAssertions = Array.from({ length: 33 }, (_, index) => ({ pointer: `/${index}`, operation: 'exists' })); }, /32 field assertions/],
  ['lookup without text reference', (source) => { source.modelConfiguration.referenceMode = 'lookupTool'; }, /text reference/],
  ['reserved reference tool name', (source) => { source.features.tools = [{ name: 'search_reference_files', fixtureResponse: 'custom output' }]; }, /reserved reference/],
]) test(`execution admission rejects ${name} before creating history or invoking native`, async (t) => {
  let calls = 0;
  const app = await fixture(t, async () => { calls++; throw new Error('Invalid suite reached native execution'); });
  const source = definition(); configure(source);
  // Editing may retain unfinished configuration; execution must use the native contract.
  const { suite: saved } = await app.call('eval_save_suite', { suite: source });
  await assert.rejects(app.call('eval_start_run', { suiteId: saved.id }), message);
  assert.equal(calls, 0);
  assert.equal((await app.store.list('runs')).length, 0);
  assert.equal(app.active, null);
  assert.equal(app.store.leases.size, 0);
});

test('strict assertion and reference admission preserves valid native boundary configurations', () => {
  const source = definition();
  source.cases[0].fieldAssertions = Array.from({ length: 32 }, (_, index) => ({
    pointer: index === 0 ? '' : `/field~0~1/${index}`, operation: index === 0 ? 'containsText' : 'exists', expectedValue: ' ',
  }));
  source.modelConfiguration.referenceMode = 'lookupTool';
  source.attachments = [{ name: 'Reference', kind: 'text', text: 'Retained reference' }];
  source.features.tools = [{ name: 'custom_reference', fixtureResponse: 'custom output' }];
  const saved = suite(source, randomUUID);
  assert.equal(saved.cases[0].fieldAssertions.length, 32);
  assert.equal(saved.cases[0].fieldAssertions[0].pointer, '');
  assert.equal(saved.features.tools[0].name, 'custom_reference');
  assert.equal(saved.attachments[0].text, 'Retained reference');
});
