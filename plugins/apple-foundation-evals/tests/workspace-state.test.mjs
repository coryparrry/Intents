import test from 'node:test';
import assert from 'node:assert/strict';
import { createDraftAutosave } from '../ui/autosave.js';
import { createWorkspaceScope, resetSuiteEvidence, mutateSuiteDraft } from '../ui/workspace-state.js';
import { renderExperiment, createInstructionExperiment, nativeCorrectJudgment } from '../ui/workflows.js';
import { renderNativeInspector } from '../ui/native-results.js';

const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
function element(tag, text) {
  return { tag, text, value: text || '', children: [], attributes: {}, style: {},
    append(...items) { this.children.push(...items); }, setAttribute(key, value) { this.attributes[key] = value; }, close() { this.closed = true; } };
}
const walk = root => [root, ...(root.children || []).flatMap(walk)];
function fixture(t) {
  const state = { draft: { id: 'A', name: 'Saved', revision: 'r1', cases: [{ id: 'a', prompt: 'saved' }], attachments: [] } }, saved = [];
  const autosave = createDraftAutosave({ read: () => state.draft, delay: 10000,
    save: async snapshot => { saved.push(snapshot); return { ...snapshot, revision: `save-${saved.length}` }; },
    applied: (draft, result) => { draft.revision = result.revision; }, status() {}, error(error) { throw error; } });
  t.after(() => autosave.dispose());
  return { state, saved, autosave, mutate: mutate => mutateSuiteDraft({ autosave, read: () => state.draft, mutate, applied() {}, changed: () => autosave.changed() }) };
}
function context(state, overrides = {}) {
  const scope = createWorkspaceScope(state);
  return { state, scope, node: element, button: (text, action) => ({ ...element('button', text), action }),
    panelHeader: () => element('header'), flush: async () => {}, refresh: async () => {}, render() {}, renderMain() {}, active: () => false,
    trackExperiment(record) { state.activeExperiment = record.status === 'running' ? record : null; },
    dialog(_title, body) { this.body = element('dialog'); body(this.body); }, ...overrides };
}

test('reference mutation retains concurrent prompt edits and saves them using the advanced revision', async t => {
  const { state, saved, autosave, mutate } = fixture(t), response = deferred(), started = deferred();
  const operation = mutate(async base => { started.resolve(base); return response.promise; });
  const base = await started.promise;
  state.draft.cases[0].prompt = 'typed while extracting'; autosave.changed();
  let flushed = false; const navigationSave = autosave.flush().then(() => { flushed = true; });
  await tick(); assert.equal(flushed, false); assert.equal(saved.length, 0);
  response.resolve({ suite: { ...base, revision: 'r2', attachments: [{ id: 'reference', text: 'extracted' }] } });
  await operation; await navigationSave;
  assert.equal(state.draft.cases[0].prompt, 'typed while extracting');
  assert.deepEqual(saved.at(-1).attachments, [{ id: 'reference', text: 'extracted' }]);
  assert.equal(saved.at(-1).revision, 'r2');
});

test('case import preserves concurrent removals/additions and existing case edits', async t => {
  const { state, autosave, mutate } = fixture(t), response = deferred(), started = deferred();
  state.draft.cases.push({ id: 'removed', prompt: 'remove me' });
  const operation = mutate(async base => { started.resolve(base); return response.promise; }); const base = await started.promise;
  state.draft.name = 'Renamed'; state.draft.cases[0].prompt = 'edited'; state.draft.cases.splice(1, 1);
  state.draft.cases.push({ id: 'local', prompt: 'local new case' }); autosave.changed();
  response.resolve({ suite: { ...base, revision: 'r2', cases: [...base.cases, { id: 'imported', prompt: 'file case' }] } });
  await operation; await autosave.flush();
  assert.equal(state.draft.name, 'Renamed');
  assert.deepEqual(state.draft.cases.map(item => [item.id, item.prompt]), [['a', 'edited'], ['local', 'local new case'], ['imported', 'file case']]);
});

test('failed suite mutation releases blocked autosave without dropping pending input', async t => {
  const { state, saved, autosave, mutate } = fixture(t), response = deferred(), started = deferred();
  const operation = mutate(async () => { started.resolve(); return response.promise; }); await started.promise;
  state.draft.name = 'Still mine'; autosave.changed(); const flushing = autosave.flush();
  response.reject(Error('Extraction failed')); await assert.rejects(operation, /Extraction failed/); await flushing;
  assert.equal(saved.at(-1).name, 'Still mine'); assert.equal(saved.at(-1).revision, 'r1');
});

test('successive file mutations serialize and each uses the preceding server revision', async t => {
  const { state, mutate } = fixture(t), response = deferred(), started = deferred();
  const first = mutate(async base => { started.resolve(); await response.promise; return { suite: { ...base, revision: 'r2', attachments: [{ id: 'one' }] } }; }); await started.promise;
  let secondBase; const second = mutate(async base => { secondBase = base; return { suite: { ...base, revision: 'r3', attachments: [...base.attachments, { id: 'two' }] } }; });
  await tick(); assert.equal(secondBase, undefined); response.resolve(); await first; await second;
  assert.equal(secondBase.revision, 'r2'); assert.deepEqual(state.draft.attachments.map(item => item.id), ['one', 'two']);
});

test('switching suite clears displayed evidence while retaining global active-experiment ownership', () => {
  const experiment = { id: 'old-experiment', status: 'running' };
  const state = { comparison: { runs: ['old'] }, compareIds: ['old'], experiment, experiments: [experiment], experimentSummary: { old: true } };
  resetSuiteEvidence(state);
  assert.equal(state.comparison, null); assert.deepEqual(state.compareIds, []); assert.equal(state.experiment, null);
  assert.equal(state.experiments, null); assert.equal(state.experimentSummary, null); assert.equal(state.activeExperiment, experiment);
});

test('late experiment refresh cannot republish old suite evidence after navigation', async () => {
  const record = { id: 'experiment-A', status: 'completed' }, state = { draft: { id: 'A' }, experiment: record }, response = deferred();
  const ctx = context(state, { call: async () => response.promise }), page = element('main'); renderExperiment(ctx, page);
  const pending = walk(page).find(item => item.text === 'Refresh experiment').action();
  ctx.scope.navigate(); state.draft = { id: 'B' }; resetSuiteEvidence(state);
  response.resolve({ experiment: record, summary: { from: 'A' } }); await pending;
  assert.equal(state.experiment, null); assert.equal(state.experimentSummary, null); assert.equal(state.draft.id, 'B');
});

test('a previously rendered experiment decision cannot mutate a different suite', async () => {
  const record = { id: 'experiment-A', status: 'completed' }, state = { draft: { id: 'A' }, experiment: record }; let mutations = 0;
  const ctx = context(state, { mutateSuite: async () => { mutations++; } }), page = element('main'); renderExperiment(ctx, page);
  ctx.scope.navigate(); state.draft = { id: 'B' }; resetSuiteEvidence(state);
  await walk(page).find(item => item.text === 'Adopt candidate').action(); assert.equal(mutations, 0); assert.equal(state.draft.id, 'B');
});

test('experiment creation completion respects a project switch after its dialog closes', async () => {
  const state = { draft: { id: 'A', instructions: 'A' } }, response = deferred(), started = deferred();
  const ctx = context(state, { call: async () => { started.resolve(); return response.promise; } }); createInstructionExperiment(ctx);
  const pending = walk(ctx.body).find(item => item.text === 'Create experiment').action(); await started.promise;
  ctx.body.close(); ctx.scope.navigate(); state.draft = { id: 'B' }; resetSuiteEvidence(state);
  response.resolve({ experiment: { id: 'experiment-A', status: 'ready' } }); await pending;
  assert.equal(state.experiment, null); assert.equal(state.draft.id, 'B');
});

test('human correction completion cannot replace another selected run', async () => {
  globalThis.Option = function(text, value) { this.text = text; this.value = value; };
  const run = { id: 'run-A' }, state = { run }, response = deferred();
  const ctx = context(state, { call: async () => response.promise }); nativeCorrectJudgment(ctx, run, { appSample: { id: 'sample-A' } });
  const pending = walk(ctx.body).find(item => item.text === 'Record correction').action();
  ctx.scope.navigate(); state.run = { id: 'run-B' }; response.resolve({ run: { id: 'run-A', corrected: true } }); await pending;
  assert.equal(state.run.id, 'run-B');
});

test('assessment selection completion cannot replace another selected run', async () => {
  globalThis.Option = function(text, value) { this.text = text; this.value = value; };
  const run = { id: 'run-A', suite: { cases: [] }, appRun: { assessments: [{ id: 'assessment-A' }], selectedAssessmentID: 'assessment-A' } };
  const state = { run, inspectorTab: 'judge' }, response = deferred();
  const ctx = context(state, { call: async () => response.promise, date: () => '', duration: () => '', segmented: () => element('tabs'), pill: () => element('pill') }), page = element('main');
  renderNativeInspector(ctx, page, run, { caseId: 'case', repetition: 1, appSample: { id: 'sample' } });
  const pending = walk(page).find(item => item.attributes?.['aria-label'] === 'Selected assessment').onchange();
  ctx.scope.navigate(); state.run = { id: 'run-B' }; response.resolve({ run: { ...run, selected: true } }); await pending;
  assert.equal(state.run.id, 'run-B');
});

test('mutations waiting on the same save serialize their snapshots and preserve additions plus interleaved edits', async t => {
  const state = { draft: { id: 'A', name: 'original', revision: 'r1', cases: [{ id: 'a', prompt: 'original' }], attachments: [] } };
  let server = structuredClone(state.draft), revision = 1, saveCount = 0, active = 0, maximumActive = 0;
  const initialSave = deferred(), saveStarted = deferred(), firstGate = deferred(), firstStarted = deferred(), secondGate = deferred(), secondStarted = deferred(), seen = [];
  const autosave = createDraftAutosave({ read: () => state.draft, delay: 10000,
    save: async snapshot => {
      if (++saveCount === 1) { saveStarted.resolve(); await initialSave.promise; }
      assert.equal(snapshot.revision, server.revision, 'ordinary saves use the latest mutation revision');
      server = { ...structuredClone(snapshot), revision: `r${++revision}` };
      return structuredClone(server);
    }, applied: (draft, result) => { draft.revision = result.revision; }, status() {}, error(error) { throw error; } });
  t.after(() => autosave.dispose());
  state.draft.name = 'before shared save'; autosave.changed(); const saving = autosave.flush(); await saveStarted.promise;
  const mutate = (gate, started, update) => mutateSuiteDraft({ autosave, read: () => state.draft,
    mutate: async base => {
      active++; maximumActive = Math.max(maximumActive, active); seen.push(base.revision); started.resolve();
      try {
        await gate.promise;
        assert.equal(base.revision, server.revision, 'each server mutation must pass CAS');
        server = { ...update(structuredClone(base)), revision: `r${++revision}` };
        return { suite: structuredClone(server) };
      } finally { active--; }
    }, applied() {}, changed: () => autosave.changed() });
  const first = mutate(firstGate, firstStarted, base => ({ ...base, attachments: [{ id: 'reference' }] }));
  const second = mutate(secondGate, secondStarted, base => ({ ...base, cases: [...base.cases, { id: 'imported', prompt: 'file case' }] }));
  initialSave.resolve(); await saving; await firstStarted.promise; await tick();
  assert.equal(maximumActive, 1, 'a shared flush wakeup must not start two mutations');
  state.draft.name = 'typed during first mutation'; autosave.changed(); firstGate.resolve(); await first; await secondStarted.promise;
  assert.equal(seen.length, 2); assert.notEqual(seen[0], seen[1]);
  state.draft.cases[0].prompt = 'typed during second mutation'; autosave.changed();
  let navigationReady = false; const navigationFlush = autosave.flush().then(() => { navigationReady = true; }); await tick(); assert.equal(navigationReady, false);
  secondGate.resolve(); await second; await navigationFlush;
  assert.equal(maximumActive, 1); assert.equal(server.name, 'typed during first mutation');
  assert.deepEqual(server.attachments, [{ id: 'reference' }]);
  assert.deepEqual(server.cases.map(item => [item.id, item.prompt]), [['a', 'typed during second mutation'], ['imported', 'file case']]);
  assert.deepEqual(state.draft, server);
});

test('a queued mutation continues after its predecessor fails and flushes intervening edits', async t => {
  const { state, saved, autosave, mutate } = fixture(t), response = deferred(), started = deferred();
  const first = mutate(async () => { started.resolve(); return response.promise; }); await started.promise;
  const firstFailure = assert.rejects(first, /First import failed/);
  let nextRevision;
  const second = mutate(async base => { nextRevision = base.revision; return { suite: { ...base, revision: 'second-import', attachments: [{ id: 'second' }] } }; });
  state.draft.name = 'edited despite first failure'; autosave.changed();
  response.reject(Error('First import failed')); await firstFailure; await second; await autosave.flush();
  assert.equal(saved[0].name, 'edited despite first failure'); assert.equal(nextRevision, 'save-1');
  assert.equal(state.draft.name, 'edited despite first failure'); assert.deepEqual(state.draft.attachments, [{ id: 'second' }]);
});
