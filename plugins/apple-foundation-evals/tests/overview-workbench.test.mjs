import test from 'node:test';
import assert from 'node:assert/strict';
import { renderNativeOverview } from '../ui/native-overview.js';

function element(tag, text, className = '') {
  return { tag, text, className, children: [], attributes: {},
    append(...items) { this.children.push(...items); },
    prepend(...items) { this.children.unshift(...items); },
    replaceChildren(...items) { this.children = items; },
    setAttribute(name, value) { this.attributes[name] = value; }
  };
}
function find(root, predicate) {
  return [root, ...root.children.flatMap(child => find(child, predicate))].filter(predicate);
}
test('suite table keeps filtering, suite actions and completed reports tied to their records', () => {
  const passing = { id: 'passing', name: 'Passing suite', cases: [{}], scoringMode: 'exact' };
  const failed = { id: 'failed', name: 'Failed suite', cases: [{}, {}], scoringMode: 'rubric' };
  const untouched = { id: 'untouched', name: 'New suite', cases: [], scoringMode: 'none' };
  const state = { projectId: 'project', projects: [{ id: 'project', name: 'My project' }], suites: [passing, failed, untouched],
    runs: [{ id: 'live', suiteId: 'untouched', status: 'running' },
      { id: 'report', suiteId: 'failed', suiteName: failed.name, status: 'completed', failed: 1, passed: 0 },
      { id: 'good', suiteId: 'passing', status: 'completed', failed: 0, passed: 1 }] };
  const opened = [], started = [], reports = [];
  let page;
  const ctx = { state, node: element, icon: name => element('svg', name),
    button: (label, onclick, cls, disabled) => Object.assign(element('button', label, cls), { onclick, disabled }),
    active: () => true, scoringLabel: value => value, date: () => 'Today',
    selectSuite: suite => opened.push(suite.id), runSuite: suite => started.push(suite.id),
    selectRun: (...args) => reports.push(args), renderMain: () => { page = renderNativeOverview(ctx); } };
  ctx.renderMain();
  const search = find(page, node => node.attributes['aria-label'] === 'Find a suite')[0];
  search.value = 'FAILED'; search.oninput();
  const rows = find(page, node => node.className === 'suite-name');
  assert.deepEqual(rows.map(row => row.text), ['Failed suite']);
  rows[0].onclick(); assert.deepEqual(opened, ['failed']);
  assert.equal(find(page, node => node.className === 'run-suite-button')[0].disabled, true);
  find(page, node => node.className === 'run-suite-button')[0].onclick();
  assert.deepEqual(started, ['failed']);
  search.value = 'missing'; search.oninput();
  assert.equal(find(page, node => node.text === 'No matching suites.')[0].hidden, false);
  state.suiteSearch = ''; find(page, node => node.className === 'list-filter')[0].onclick();
  assert.deepEqual(find(page, node => node.className === 'suite-name').map(row => row.text), ['Failed suite', 'New suite']);
  find(page, node => node.className === 'recent-run-row')[0].onclick();
  assert.deepEqual(reports, [['report', 'report']]);
});
