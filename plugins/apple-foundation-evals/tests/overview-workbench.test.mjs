import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { appSuiteHealth } from '../ui/native-overview.js';

test('suite health uses the latest run and preserves stale, running and unassessed states', () => {
  const suite = { id: 'suite' };
  assert.equal(appSuiteHealth(suite, []).kind, 'unassessed');
  const passing = { suiteId: suite.id, status: 'completed', passed: 1, startedAt: '2026-10-25' };
  for (const [run, kind, title] of [
    [passing, 'passing', 'Responses passed'],
    [{ ...passing, health: { staleEvidence: true } }, 'attention', 'Definition changed'],
    [{ ...passing, status: 'running' }, 'attention', 'Running'],
    [{ ...passing, failed: 1 }, 'attention', 'Needs attention'],
    [{ ...passing, passed: 0 }, 'unassessed', 'Not yet assessed'],
  ]) {
    const health = appSuiteHealth(suite, [{ ...passing, startedAt: '2026-10-24' }, run]);
    assert.equal(health.kind, kind); assert.equal(health.title, title); assert.equal(health.latest, run);
  }
});

test('React overview keeps filtering, suite actions and completed reports tied to their records', async () => {
  const dom = new JSDOM('<!doctype html><body></body>', { url: 'http://localhost', pretendToBeVisual: true });
  for (const key of ['window', 'document', 'navigator', 'HTMLElement', 'Element', 'Node', 'Event', 'MouseEvent', 'MutationObserver', 'CustomEvent', 'HTMLInputElement', 'SVGElement', 'DocumentFragment']) {
    Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] });
  }
  globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const output = new URL(`../.overview-test-${process.pid}.mjs`, import.meta.url);
  let cleanup;
  try {
    await build({ entryPoints: [fileURLToPath(new URL('../ui/react/overview.tsx', import.meta.url))], outfile: fileURLToPath(output), bundle: true, platform: 'node', format: 'esm', packages: 'external', jsx: 'automatic', logLevel: 'silent' });
    const { Overview } = await import(output.href);
    const { createElement } = await import('react');
    const testing = await import('@testing-library/react'); cleanup = testing.cleanup;
    const passing = { id: 'passing', name: 'Passing suite', cases: [{}], scoringMode: 'exact' };
    const failed = { id: 'failed', name: 'Failed suite', cases: [{}, {}], scoringMode: 'rubric' };
    const untouched = { id: 'untouched', name: 'New suite', cases: [], scoringMode: 'none' };
    const state = { projectId: 'project', projects: [{ id: 'project', name: 'My project' }], suites: [passing, failed, untouched],
      runs: [{ id: 'live', suiteId: 'untouched', status: 'running' },
        { id: 'report', suiteId: 'failed', suiteName: failed.name, status: 'completed', failed: 1, passed: 0 },
        { id: 'good', suiteId: 'passing', status: 'completed', failed: 0, passed: 1 }] };
    const opened = [], started = [], reports = [];
    const ctx = { state, active: () => true, scoringLabel: value => value, date: () => 'Today', createSuite() {},
      selectSuite: suite => opened.push(suite.id), runSuite: suite => started.push(suite.id), selectRun: (...args) => reports.push(args), fail: error => { throw error; } };
    const view = testing.render(createElement(Overview, { ctx }));
    const search = view.getByLabelText('Find a suite'); search.focus();
    testing.fireEvent.change(search, { target: { value: 'FAILED' } });
    assert.equal(document.activeElement, search);
    assert.equal(view.queryByRole('button', { name: 'Passing suite' }), null);
    await testing.act(async () => testing.fireEvent.click(view.getByRole('button', { name: 'Failed suite' })));
    assert.deepEqual(opened, ['failed']);
    const run = view.getByRole('button', { name: 'Run Failed suite' }); assert.equal(run.disabled, true);
    ctx.active = () => false; view.rerender(createElement(Overview, { ctx }));
    await testing.act(async () => testing.fireEvent.click(view.getByRole('button', { name: 'Run Failed suite' })));
    assert.deepEqual(started, ['failed']);
    testing.fireEvent.change(search, { target: { value: 'missing' } }); assert.ok(view.getByText('No matching suites'));
    testing.fireEvent.change(search, { target: { value: '' } }); testing.fireEvent.click(view.getByRole('button', { name: 'Needs attention' }));
    assert.ok(view.getByRole('button', { name: 'Failed suite' })); assert.ok(view.getByRole('button', { name: 'New suite' })); assert.equal(view.queryByRole('button', { name: 'Passing suite' }), null);
    await testing.act(async () => testing.fireEvent.click(view.getByRole('button', { name: /Failed suite.*Today/ })));
    assert.deepEqual(reports, [['report', 'report']]);
  } finally {
    cleanup?.(); await rm(output, { force: true }); dom.window.close();
  }
});
