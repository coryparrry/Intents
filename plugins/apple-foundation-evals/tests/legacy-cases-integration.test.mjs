import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { suite } from '../server/validation.mjs';
import { isAppSuiteFormat } from '../ui/suite-form-state.js';

test('actual React Cases render and edits preserve supported flat suite format and scoring', async () => {
  const dom = new JSDOM('<!doctype html><body></body>', { url: 'http://localhost', pretendToBeVisual: true });
  for (const key of ['window', 'document', 'navigator', 'HTMLElement', 'Element', 'Node', 'Event', 'MouseEvent', 'KeyboardEvent', 'MutationObserver', 'CustomEvent', 'HTMLInputElement', 'HTMLFormElement', 'SVGElement', 'DocumentFragment', 'NodeFilter']) {
    Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] });
  }
  globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  globalThis.requestAnimationFrame = dom.window.requestAnimationFrame.bind(dom.window);
  globalThis.cancelAnimationFrame = dom.window.cancelAnimationFrame.bind(dom.window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const output = new URL(`../.legacy-cases-test-${process.pid}.mjs`, import.meta.url);
  let cleanup;
  try {
    await build({ entryPoints: [fileURLToPath(new URL('../ui/react/cases.tsx', import.meta.url))], outfile: fileURLToPath(output), bundle: true, platform: 'node', format: 'esm', packages: 'external', jsx: 'automatic', logLevel: 'silent' });
    const { Cases } = await import(output.href);
    const { createElement } = await import('react');
    const testing = await import('@testing-library/react');
    cleanup = testing.cleanup;
    for (const caseId of [randomUUID(), 'legacy-named-exact']) {
      const draft = suite({ name: 'Legacy', instructions: '', cases: [{ id: caseId, name: 'Exact', prompt: 'Apple', expected: 'Apple', scoring: 'exact' }, { id: 'contains-case', name: 'Contains', prompt: 'Fruit', expected: 'apple', scoring: 'contains' }] }, randomUUID);
      const before = structuredClone(draft), state = { draft, caseId, caseSearch: '', dirty: false };
      let changes = 0;
      const ctx = { state, actions: { suiteDetails() {} }, changed() { changes++; }, active: () => false, caseTitle: item => item.name, scoringLabel: () => 'Unused app scoring', importCases() {}, fail: error => { throw error; }, renderToolbar() {}, renderMain() {} };
      const view = testing.render(createElement(Cases, { ctx }));
      assert.deepEqual(draft, before, 'rendering must not add application format markers');
      assert.equal(view.queryByLabelText('Case inspector'), null);
      testing.fireEvent.change(view.getByLabelText('Suite name'), { target: { value: 'Renamed legacy suite' } });
      testing.fireEvent.change(view.getByLabelText('Prompt'), { target: { value: 'Edited apple' } });
      assert.equal(changes, 2);
      const saved = suite(draft, randomUUID, { draft: true });
      assert.equal(isAppSuiteFormat(saved), false);
      assert.equal(saved.cases[0].prompt, 'Edited apple');
      assert.deepEqual(saved.cases.map(item => [item.id, item.scoring]), [[caseId, 'exact'], ['contains-case', 'contains']]);
      view.unmount(); cleanup();
    }
  } finally {
    cleanup?.(); await rm(output, { force: true }); dom.window.close();
  }
});
