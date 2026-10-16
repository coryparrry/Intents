import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { JSDOM } from 'jsdom';
import { removeCase } from '../ui/react/case-actions.js';
import { caseEditorDetails, commitCaseEditorDetails, isAppSuiteFormat } from '../ui/suite-form-state.js';
import { appSchemaEditor, newAppSuite, renderNativeCases } from '../ui/native-suite.js';
import { renderNativeSetup } from '../ui/native-setup.js';
import { suite } from '../server/validation.mjs';

function context(draft, setupPage = 'instructions') {
  const dom = new JSDOM('<!doctype html><body></body>');
  globalThis.Option = dom.window.Option;
  const doc = dom.window.document;
  let changes = 0;
  const ctx = {
    state: { draft, caseId: draft.cases[0].id, caseSearch: '', setupPage },
    node(tag, text, className) { const el = doc.createElement(tag); if (text != null) el.textContent = text; if (className) el.className = className; return el; },
    button(text, action, className, disabled = false) { const el = ctx.node('button', text, className); el.disabled = disabled; el.onclick = action; return el; },
    field(label, value, change) { const wrap = ctx.node('label', label), input = ctx.node('textarea'); input.value = value || ''; input.setAttribute('aria-label', label); input.oninput = () => { change(input.value); ctx.changed(); }; wrap.append(input); return wrap; },
    changed() { changes++; }, renderMain() {}, icon: () => doc.createElement('span'), panelHeader: title => ctx.node('h2', title), caseTitle: item => item.name || item.id,
    active: () => false, empty: title => ctx.node('p', title), importCases() {}, addReferences() {}, createExperiment() {},
  };
  return { ctx, changes: () => changes, close: () => dom.window.close() };
}
function input(root, label) { const found = [...root.querySelectorAll('[aria-label]')].find(el => el.getAttribute('aria-label') === label); assert.ok(found, label); return found; }
function change(control, value) { control.value = String(value); control.onchange(); }

test('deleting a critical case removes only its release requirement in both case handlers', () => {
  for (const legacyHandler of [false, true]) {
    const draft = newAppSuite(randomUUID()), removed = draft.cases[0].id, kept = randomUUID();
    draft.cases.push({ ...structuredClone(draft.cases[0]), id: kept });
    draft.releasePolicy = { required: true, criticalCaseIDs: [removed.toUpperCase(), kept], maximumErrorCount: 0 };
    if (legacyHandler) {
      const h = context(draft); const view = renderNativeCases(h.ctx);
      [...view.querySelectorAll('button')].find(el => el.textContent === 'Delete Case').click(); h.close();
    } else removeCase(draft, removed);
    assert.deepEqual(draft.releasePolicy.criticalCaseIDs, [kept]);
    assert.equal(draft.cases[0].id, kept);
    assert.doesNotThrow(() => suite(draft, randomUUID));
    assert.throws(() => removeCase(draft, kept), /at least one/);
    assert.deepEqual(draft.releasePolicy.criticalCaseIDs, [kept]);
  }
});

test('schema Type and Optional controls discard hidden incompatible metadata only on transitions', () => {
  const draft = newAppSuite(randomUUID());
  const field = { id: randomUUID(), name: 'answer', description: '', type: 'object', isOptional: true, children: [{ id: randomUUID(), name: 'child', type: 'string' }], enumValues: [{ id: randomUUID(), value: 'old' }], constraints: { integerMinimum: 4 }, referenceName: 'OldType', representNilExplicitlyInGeneratedContent: true };
  draft.features.outputFields = [field];
  const h = context(draft);
  let view = appSchemaEditor(h.ctx, [field]);
  change(input(view, 'Type'), 'string');
  assert.deepEqual(field.children, []); assert.deepEqual(field.enumValues, []);
  assert.deepEqual(field.constraints, { stringPattern: '' }); assert.equal(field.referenceName, ''); assert.equal(field.representNilExplicitlyInGeneratedContent, false);
  assert.doesNotThrow(() => suite(draft, randomUUID));
  for (const [type, children, choices] of [['array', 1, 0], ['union', 2, 0], ['enumeration', 0, 1]]) {
    view = appSchemaEditor(h.ctx, [field]); change(input(view, 'Type'), type);
    assert.equal(field.children.length, children); assert.equal(field.enumValues.length, choices);
    const before = structuredClone(field); view = appSchemaEditor(h.ctx, [field]); change(input(view, 'Type'), type); assert.deepEqual(field, before);
    assert.doesNotThrow(() => suite(draft, randomUUID));
  }
  field.representNilExplicitlyInGeneratedContent = true;
  view = appSchemaEditor(h.ctx, [field]); const optional = [...view.querySelectorAll('input[type=checkbox]')][0]; optional.checked = false; optional.onchange();
  assert.equal(field.representNilExplicitlyInGeneratedContent, false); h.close();
});

test('rendering or editing supported flat suites preserves named IDs and independent scoring', () => {
  for (const id of [randomUUID(), 'named-exact-case']) {
    const draft = suite({ name: 'Legacy', instructions: '', cases: [{ id, name: 'Exact', prompt: 'Apple', expected: 'Apple', scoring: 'exact' }, { id: 'contains-case', prompt: 'Fruit', expected: 'apple', scoring: 'contains' }] }, randomUUID);
    const before = structuredClone(draft); const h = context(draft);
    const details = caseEditorDetails(draft.cases[0]);
    renderNativeCases(h.ctx); renderNativeSetup(h.ctx);
    assert.deepEqual(draft, before); assert.equal(isAppSuiteFormat(draft), false);
    details.checks.push({ id: randomUUID(), operation: 'exists' }); commitCaseEditorDetails(draft, draft.cases[0], details);
    draft.name = 'Renamed'; const saved = suite(draft, randomUUID, { draft: true });
    assert.equal(isAppSuiteFormat(saved), false); assert.deepEqual(saved.cases.map(item => [item.id, item.scoring]), [[id, 'exact'], ['contains-case', 'contains']]); h.close();
  }
});

test('app case editor details stay detached until an actual edit is committed', () => {
  const draft = newAppSuite(randomUUID()), before = structuredClone(draft), details = caseEditorDetails(draft.cases[0]);
  details.conversation.setupTurns.push({ id: randomUUID(), prompt: 'Remember apple' });
  assert.deepEqual(draft, before); commitCaseEditorDetails(draft, draft.cases[0], details);
  assert.equal(draft.cases[0].conversation.setupTurns[0].prompt, 'Remember apple');
  assert.doesNotThrow(() => suite(draft, randomUUID));
});

test('model and profile controls enforce native numeric ranges before changing the saved draft', () => {
  const ranges = [
    ['model', 'Maximum response tokens', 'maximumResponseTokens', 128, 4096],
    ['model', 'Maximum input tokens', 'maximumInputTokens', 512, 32768],
    ['model', 'Top-K', 'topK', 1, 1000],
    ['model', 'Temperature', 'temperature', 0, 1],
    ['model', 'Probability threshold', 'probabilityThreshold', .01, 1],
    ['tools', 'Maximum tool calls', 'maximumToolCalls', 1, 4],
    ['profile', 'Maximum response tokens after a tool call', 'afterToolMaximumResponseTokens', 128, 4096],
    ['profile', 'Top-K', 'afterToolTopK', 1, 1000],
    ['profile', 'Temperature', 'afterToolTemperature', 0, 1],
    ['profile', 'Probability threshold', 'afterToolProbabilityThreshold', .01, 1],
  ];
  for (const [page, label, key, min, max] of ranges) {
    const draft = newAppSuite(randomUUID()); draft.modelConfiguration.samplingMode = key === 'topK' ? 'topK' : 'probability'; draft.modelConfiguration.temperatureEnabled = true;
    draft.features.profile = { enabled: true, name: 'After tool', afterToolSamplingMode: key === 'afterToolTopK' ? 'topK' : 'probability', afterToolTemperatureEnabled: true };
    const h = context(draft, page), view = renderNativeSetup(h.ctx), control = input(view, label), object = page === 'profile' ? draft.features.profile : draft.modelConfiguration;
    assert.equal(Number(control.min), min); assert.equal(Number(control.max), max);
    for (const value of [min, max]) { control.value = String(value); control.oninput(); assert.equal(object[key], value); assert.equal(control.validity.valid, true); assert.doesNotThrow(() => suite(draft, randomUUID)); }
    const previous = object[key], changes = h.changes();
    for (const value of [min - 1, max + 1]) { control.value = String(value); control.oninput(); assert.equal(object[key], previous); assert.equal(control.validity.valid, false); }
    assert.equal(h.changes(), changes); h.close();
  }
});
