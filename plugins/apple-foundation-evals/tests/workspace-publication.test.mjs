import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { createWorkspaceScope, resetSuiteEvidence, mutateSuiteDraft } from '../ui/workspace-state.js';
import { createDraftAutosave } from '../ui/autosave.js';
import { createStatusPoller } from '../ui/polling.js';
import { newAppSuite } from '../ui/native-suite.js';
import { comparisonSelection } from '../ui/workspace-controls.js';

// Execute complete production functions; DOM/transport are in-memory records.
// Assertions exercise effects and saved data rather than matching source snippets.
const source = await readFile(new URL('../ui/app.js', import.meta.url), 'utf8');
const declarations = [...source.matchAll(/^(?:async )?function (\w+)\(/gm)];
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function node(tag, text) { return { tag, text, children: [], value: text || '', attributes: {}, append(...items) { this.children.push(...items); }, setAttribute(key, value) { this.attributes[key] = value; } }; }
const walk = item => [item, ...(item.children || []).flatMap(walk)];
function load(names, state, overrides = {}) {
  const scope = createWorkspaceScope(state);
  const sandbox = { state, workspaceScope: scope, resetSuiteEvidence, createStatusPoller, fail() {}, clone: structuredClone, structuredClone,
    flush: async () => {}, render() {}, renderMain() {}, renderSidebar() {}, renderToolbar() {}, notice() {}, filterProject() {}, schedulePoll() {}, active: () => false,
    newAppSuite, comparisonSelection, $: () => ({ scrollTop: 0 }), node, button: (text, action) => ({ ...node('button', text), action }),
    panelHeader: () => node('header'), empty: () => node('empty'), renderExperiment() {}, context: () => ({}),
    date: value => value, rate: () => '', Option: function(text, value) { this.text = text; this.value = value; },
    comparisonSequence: 0, ...overrides };
  vm.createContext(sandbox);
  for (const name of names) {
    const index = declarations.findIndex(item => item[1] === name);
    assert.notEqual(index, -1, `Missing production function ${name}`);
    vm.runInContext(source.slice(declarations[index].index, declarations[index + 1]?.index ?? source.length), sandbox);
  }
  return sandbox;
}

test('saved-run open does not override a later project selection', async () => {
  const response = deferred(), started = deferred(), state = { projectId: 'P', page: 'overview' };
  const app = load(['selectRun'], state, { call: async () => { started.resolve(); return response.promise; } });
  const pending = app.selectRun('A'); await started.promise;
  app.workspaceScope.navigate(); state.projectId = 'Q'; state.draft = { id: 'B' };
  response.resolve({ run: { id: 'A', projectId: 'P' } }); await pending;
  assert.equal(state.projectId, 'Q'); assert.equal(state.page, 'overview'); assert.equal(state.run, undefined);
});

test('dismissed deletion cannot discard another suite and its pending autosave', async t => {
  const response = deferred(), started = deferred(), saved = [], state = { draft: { id: 'A', name: 'A', cases: [] }, allSuites: [{ id: 'B', cases: [{ id: 'b', prompt: 'saved' }] }], page: 'suites' };
  const autosave = createDraftAutosave({ read: () => state.draft, save: async value => { saved.push(value); return value; }, applied() {}, status() {}, error(error) { throw error; }, delay: 10000 }); t.after(() => autosave.dispose());
  let action; const app = load(['deleteSuite', 'selectSuite'], state, { flush: () => autosave.flush(), confirmRemoval: (_a, _b, callback) => { action = callback; }, refresh: async () => {}, call: async () => { started.resolve(); return response.promise; } });
  app.deleteSuite(); const pending = action(); await started.promise;
  await app.selectSuite(state.allSuites[0]); state.draft.cases[0].prompt = 'B edited'; autosave.changed();
  response.resolve({ deleted: true }); await pending; await autosave.flush();
  assert.equal(state.draft.id, 'B'); assert.equal(state.page, 'suites'); assert.equal(saved.at(-1).cases[0].prompt, 'B edited');
});

test('late experiment polling updates global running status without restoring old suite evidence', async () => {
  const response = deferred(), started = deferred(), state = { projectId: 'P', allSuites: [{ id: 'B', cases: [] }], draft: { id: 'A' }, experiment: { id: 'experiment-A', status: 'running' }, page: 'suites' };
  const app = load(['refresh', 'selectSuite', 'trackExperiment'], state, { call: async name => {
    if (name === 'eval_list_projects') return { projects: [] };
    if (name === 'eval_list_suites') return { suites: state.allSuites };
    if (name === 'eval_list_runs') return { runs: [] };
    started.resolve(); return response.promise;
  } });
  const pending = app.refresh(); await started.promise; await app.selectSuite(state.allSuites[0]);
  response.resolve({ experiment: { id: 'experiment-A', status: 'completed' }, summary: { from: 'A' } }); await pending;
  assert.equal(state.draft.id, 'B'); assert.equal(state.experiment, null); assert.equal(state.experimentSummary, null); assert.equal(state.activeExperiment, null);
});

test('new suite clears both completed comparison and experiment state', async () => {
  const state = { projectId: 'P', comparison: { old: true }, compareIds: ['a'], experiment: { id: 'old', status: 'completed' }, experiments: [{}], experimentSummary: {} };
  const app = load(['createSuite'], state, { markDirty() {} }); await app.createSuite();
  assert.equal(state.comparison, null); assert.deepEqual(state.compareIds, []); assert.equal(state.experiment, null); assert.equal(state.experimentSummary, null); assert.equal(state.suiteTab, 'cases');
});

test('comparison completing after a project change neither publishes nor dereferences a missing draft', async () => {
  const response = deferred(), state = { draft: { id: 'A' }, runs: [{ id: 'one', suiteId: 'A' }, { id: 'two', suiteId: 'A' }], compareCount: 2, compareIds: [], comparison: null };
  const app = load(['renderCompare'], state, { call: async () => response.promise, comparisonMatches: () => { throw Error('Old-context comparison must short circuit'); } });
  const page = node('page'); app.renderCompare(page); const pending = walk(page).find(item => item.text === 'Compare').action();
  app.workspaceScope.navigate(); state.draft = null; resetSuiteEvidence(state);
  response.resolve({ runs: [] }); await pending; assert.equal(state.comparison, null);
});

test('reference import flow preserves edits in the same suite and saves the returned revision', async t => {
  const response = deferred(), started = deferred(), saved = [], state = { allSuites: [], draft: { id: 'A', revision: 'r1', cases: [{ id: 'a', prompt: 'saved' }], attachments: [] } };
  const autosave = createDraftAutosave({ read: () => state.draft, save: async value => { saved.push(value); return value; }, applied() {}, status() {}, error(error) { throw error; }, delay: 10000 }); t.after(() => autosave.dispose());
  let onFiles; const app = load(['addReferences'], state, { chooseFiles: (_a, _b, callback) => { onFiles = callback; }, fileBase64: () => '', refresh: async () => {},
    mutateDraft: mutate => mutateSuiteDraft({ autosave, read: () => state.draft, mutate, applied() {}, changed: () => autosave.changed() }),
    call: async () => { started.resolve(); return response.promise; } });
  app.addReferences(); const pending = onFiles([{ name: 'notes.txt', size: 1, type: 'text/plain', arrayBuffer: async () => new ArrayBuffer(0) }]); await started.promise;
  const base = structuredClone(state.draft); state.draft.cases[0].prompt = 'typed during extraction'; autosave.changed();
  response.resolve({ suite: { ...base, revision: 'r2', attachments: [{ id: 'new-reference' }] } }); await pending; await autosave.flush();
  assert.equal(saved.at(-1).cases[0].prompt, 'typed during extraction'); assert.equal(saved.at(-1).revision, 'r2'); assert.equal(state.draft.attachments[0].id, 'new-reference');
});

test('a superseded run-suite navigation never starts the subsequently selected suite', async () => {
  const flush = deferred(), state = { draft: { id: 'old' }, allSuites: [{ id: 'A', cases: [] }] }; let starts = 0;
  const app = load(['selectSuite', 'runSuite'], state, { flush: () => flush.promise, startRun: async () => { starts++; } });
  const pending = app.runSuite(state.allSuites[0]); app.workspaceScope.navigate(); state.draft = { id: 'B' }; flush.resolve(); await pending;
  assert.equal(starts, 0); assert.equal(state.draft.id, 'B');
});
