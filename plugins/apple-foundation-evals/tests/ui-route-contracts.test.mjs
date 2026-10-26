import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { readFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { newAppSuite } from '../ui/native-suite.js';

/** Supplies host-browser services used by the actual workspace entry and its React controls. */
function installDOM(dom) {
  for (const key of ['window', 'document', 'navigator', 'HTMLElement', 'Element', 'Node', 'Event', 'MouseEvent', 'KeyboardEvent', 'MutationObserver', 'CustomEvent', 'HTMLInputElement', 'HTMLFormElement', 'SVGElement', 'DocumentFragment', 'NodeFilter', 'Option']) {
    Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] });
  }
  globalThis.parent = dom.window;
  globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  globalThis.requestAnimationFrame = dom.window.requestAnimationFrame.bind(dom.window);
  globalThis.cancelAnimationFrame = dom.window.cancelAnimationFrame.bind(dom.window);
  const media = { matches: false, addEventListener() {}, removeEventListener() {} };
  globalThis.matchMedia = dom.window.matchMedia = () => media;
  dom.window.HTMLElement.prototype.scrollIntoView = function () {};
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  return media;
}

test('actual entry mounts React navigation, preserves case contracts and guards project changes with autosave', async () => {
  const html = await readFile(new URL('../ui/workspace.html', import.meta.url), 'utf8');
  const dom = new JSDOM(html, { url: 'http://localhost', pretendToBeVisual: true });
  assert.equal(dom.window.document.getElementById('workspace-sidebar').children.length, 0);
  const media = installDOM(dom);
  const output = new URL(`../.route-test-${process.pid}.mjs`, import.meta.url);
  let app, act;
  try {
    const source = await readFile(new URL('../ui/app.js', import.meta.url), 'utf8');
    await build({ stdin: { contents: `${source}\nexport { state, context, acceptResult, render, transport, autosave, statusPoller, unmountUI };`, resolveDir: fileURLToPath(new URL('../ui/', import.meta.url)), sourcefile: 'route-test-entry.js' }, outfile: fileURLToPath(output), bundle: true, platform: 'node', format: 'esm', packages: 'external', jsx: 'automatic', logLevel: 'silent' });
    const testing = await import('@testing-library/react');
    ({ act } = testing);
    const { fireEvent, within } = testing;
    await act(async () => {
      app = await import(output.href);
      // An early shortcut before React commits must not dereference a missing input.
      fireEvent.keyDown(document, { key: 'f', ctrlKey: true });
    });
    const sidebar = document.getElementById('workspace-sidebar'), main = document.getElementById('main');
    assert.ok(within(sidebar).getByRole('button', { name: 'Overview' }));
    assert.equal(document.querySelectorAll('#workspace-search').length, 1);
    assert.equal(document.getElementById('project-select'), null);
    assert.ok(within(main).getByRole('heading', { name: 'My evaluations' }));
    const dialogOpener = within(sidebar).getByRole('button', { name: 'Overview' });
    dialogOpener.focus();
    let dialogBody, dialogClosed = 0;
    await act(async () => {
      const ctx = app.context();
      dialogBody = ctx.dialog('Workspace details', body => body.append(ctx.node('p', 'Shared dialog content')));
      dialogBody.addEventListener('close', () => dialogClosed++);
    });
    assert.ok(within(document.body).getByRole('dialog', { name: 'Workspace details' }));
    assert.equal(dialogBody.textContent, 'Shared dialog content');
    await act(async () => { dialogBody.close(); await new Promise(resolve => setTimeout(resolve, 10)); });
    assert.equal(document.activeElement, dialogOpener);
    assert.equal(dialogClosed, 1);
    dialogBody.close();
    assert.equal(dialogClosed, 1);
    let saveResponse;
    const savedRequests = [];
    app.transport.request = async (_method, params) => {
      assert.equal(params.name, 'eval_save_suite');
      savedRequests.push(structuredClone(params.arguments));
      return { structuredContent: { suite: await saveResponse(params.arguments) } };
    };
    const original = newAppSuite('project-a'); original.name = 'Native suite'; original.revision = 'r1';
    original.cases[0].name = 'Apple'; original.cases[0].prompt = 'Only JSON';
    original.releasePolicy = { required: true, criticalCaseIDs: [original.cases[0].id.toUpperCase()] };
    original.cases[0].fieldAssertions = [{ id: 'check', pointer: '/fruit', operation: 'equals', expectedValue: '"apple"' }];
    original.cases[0].conversation.setupTurns = [{ id: 'turn', prompt: 'Remember apple' }];
    const workspace = { page: 'workspace', defaultProjectId: 'project-a', projects: [{ id: 'project-a', name: 'Project A' }, { id: 'project-b', name: 'Project B' }], suites: [original], runs: [] };
    await act(async () => app.acceptResult({ structuredContent: workspace }));
    const search = within(sidebar).getByLabelText('Search workspace');
    search.focus();
    await act(async () => fireEvent.change(search, { target: { value: 'missing' } }));
    assert.equal(document.activeElement, search);
    assert.equal(within(sidebar).queryByRole('button', { name: original.name }), null);
    await act(async () => fireEvent.change(search, { target: { value: '' } }));
    await act(async () => fireEvent.click(within(sidebar).getByRole('button', { name: original.name })));
    const draft = app.state.draft, first = draft.cases[0];
    assert.ok(within(main).getByLabelText('Case inspector'));
    assert.equal(main.classList.contains('legacy-view'), false);
    assert.equal(document.getElementById('view-tabs').hidden, false);
    assert.ok(within(document.getElementById('toolbar-actions')).getByRole('button', { name: 'Run' }));
    await act(async () => fireEvent.click(within(main).getByRole('button', { name: /Field checks/ })));
    await act(async () => fireEvent.change(within(main).getByLabelText('JSON pointer'), { target: { value: '/answer' } }));
    await act(async () => fireEvent.change(within(main).getByLabelText('Expected value'), { target: { value: '"pear"' } }));
    await act(async () => fireEvent.click(within(main).getByRole('button', { name: 'Conversation setup' })));
    await act(async () => fireEvent.change(within(main).getByLabelText('Setup turn 1'), { target: { value: 'Remember pear' } }));
    await act(async () => fireEvent.click(within(main).getByRole('button', { name: 'Add setup turn' })));
    await act(async () => fireEvent.change(within(main).getByLabelText('Setup turn 2'), { target: { value: 'Use JSON' } }));
    await act(async () => fireEvent.change(within(main).getByLabelText('Restored transcript JSON'), { target: { value: '{"entries":[]}' } }));
    assert.deepEqual(first.fieldAssertions.map(check => [check.pointer, check.expectedValue]), [['/answer', '"pear"']]);
    assert.deepEqual(first.conversation.setupTurns.map(turn => turn.prompt), ['Remember pear', 'Use JSON']);
    assert.equal(first.conversation.restoredTranscriptJSON, '{"entries":[]}');
    const caseSearch = within(main).getByLabelText('Find a case'); caseSearch.focus();
    await act(async () => fireEvent.change(caseSearch, { target: { value: 'missing' } }));
    assert.equal(document.activeElement, caseSearch); assert.ok(within(main).getByText('No matching cases'));
    await act(async () => fireEvent.change(caseSearch, { target: { value: '' } }));
    await act(async () => fireEvent.keyDown(within(main).getByRole('button', { name: 'Case actions' }), { key: 'Enter' }));
    await act(async () => fireEvent.click(within(document.body).getByRole('menuitem', { name: 'Duplicate case' })));
    assert.equal(draft.cases.length, 2); const copy = draft.cases[1];
    assert.equal(app.state.caseId, copy.id); assert.deepEqual(copy.fieldAssertions, first.fieldAssertions); assert.deepEqual(copy.conversation, first.conversation);
    await act(async () => fireEvent.change(within(main).getByLabelText('Prompt'), { target: { value: 'Changed copy' } }));
    assert.equal(first.prompt, 'Only JSON');
    await act(async () => fireEvent.click(within(main).getByRole('button', { name: 'Conversation setup' })));
    await act(async () => fireEvent.change(within(main).getByLabelText('Setup turn 1'), { target: { value: 'Copy memory' } }));
    assert.equal(first.conversation.setupTurns[0].prompt, 'Remember pear');
    await act(async () => fireEvent.keyDown(within(main).getByRole('button', { name: 'Case actions' }), { key: 'Enter' }));
    await act(async () => fireEvent.click(within(document.body).getByRole('menuitem', { name: 'Delete case' })));
    assert.equal(draft.cases.length, 1); assert.equal(app.state.caseId, first.id);
    assert.deepEqual(draft.releasePolicy.criticalCaseIDs, [first.id.toUpperCase()]);

    // Current tabs preserve the remaining native setup/history routes and keyboard navigation.
    await act(async () => fireEvent.mouseDown(within(document.getElementById('view-tabs')).getByRole('tab', { name: 'Results' }), { button: 0, ctrlKey: false }));
    assert.equal(app.state.suiteTab, 'results'); assert.equal(main.classList.contains('legacy-view'), true);
    assert.ok(within(main).getByRole('heading', { name: /^Run history/ }));
    await act(async () => { const results = within(document.getElementById('view-tabs')).getByRole('tab', { name: 'Results' }); results.focus(); fireEvent.keyDown(results, { key: 'End' }); await new Promise(resolve => setTimeout(resolve, 0)); });
    assert.equal(app.state.suiteTab, 'setup'); assert.ok(main.querySelector('.setup-page'));
    await act(async () => { fireEvent.keyDown(within(document.getElementById('view-tabs')).getByRole('tab', { name: 'Setup' }), { key: 'Home' }); await new Promise(resolve => setTimeout(resolve, 0)); });
    assert.equal(app.state.suiteTab, 'cases'); assert.equal(main.classList.contains('legacy-view'), false);
    assert.ok(within(main).getByLabelText('Prompt'));

    let resolveSave;
    saveResponse = args => new Promise(resolve => { resolveSave = () => resolve({ ...args.suite, projectId: args.projectId, revision: 'r2' }); });
    await act(async () => fireEvent.keyDown(within(sidebar).getByRole('combobox', { name: 'Project' }), { key: 'ArrowDown' }));
    await act(async () => fireEvent.click(within(document.body).getByRole('option', { name: 'Project B' })));
    assert.equal(savedRequests.length, 1); assert.equal(app.state.projectId, 'project-a'); assert.equal(app.state.draft, draft);
    assert.equal(savedRequests[0].expectedRevision, 'r1');
    await act(async () => resolveSave());
    assert.equal(app.state.projectId, 'project-b'); assert.equal(app.state.page, 'overview'); assert.equal(app.state.draft, null);
    assert.ok(within(main).getByRole('heading', { name: 'Project B' })); assert.equal(document.getElementById('view-tabs').hidden, true);
    await act(async () => { await app.context().actions.changeProject('project-a'); await app.context().selectSuite(original); });
    await act(async () => fireEvent.change(within(main).getByLabelText('Prompt'), { target: { value: 'Unsaved edit' } }));
    const failedDraft = app.state.draft;
    saveResponse = async () => { throw Error('Revision conflict'); };
    await act(async () => fireEvent.keyDown(within(sidebar).getByRole('combobox', { name: 'Project' }), { key: 'ArrowDown' }));
    await act(async () => fireEvent.click(within(document.body).getByRole('option', { name: 'Project B' })));
    assert.equal(app.state.projectId, 'project-a'); assert.equal(app.state.draft, failedDraft); assert.equal(failedDraft.cases[0].prompt, 'Unsaved edit');
    assert.match(within(sidebar).getByRole('combobox', { name: 'Project' }).textContent, /Project A/);
    assert.equal(document.getElementById('save-state').textContent, 'Could not save');
    assert.match(document.getElementById('notice').textContent, /Revision conflict/);

    media.matches = true;
    await act(async () => fireEvent.click(document.getElementById('sidebar-toggle')));
    assert.equal(document.getElementById('sidebar-toggle').getAttribute('aria-expanded'), 'true'); assert.equal(sidebar.inert, false);
    fireEvent.keyDown(document, { key: 'Escape' }); assert.equal(sidebar.inert, true);
    fireEvent.keyDown(document, { key: 'f', metaKey: true }); assert.equal(sidebar.inert, false); assert.equal(document.activeElement, within(sidebar).getByLabelText('Search workspace'));
    fireEvent.keyDown(document, { key: 'Escape' }); assert.equal(sidebar.inert, true);
  } finally {
    if (app) {
      app.autosave.dispose(); app.statusPoller.dispose(); app.transport.dispose();
      await act(async () => { for (const id of ['workspace-sidebar', 'toolbar-actions', 'toolbar-context', 'view-tabs', 'main']) app.unmountUI(document.getElementById(id)); });
    }
    await rm(output, { force: true }); dom.window.close();
  }
});
