import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { readFile } from 'node:fs/promises';
import { renderCatalogRecovery, exportRecoveryRecord, forgetRemovedRecoveryRecord, setCatalogRecoveryLayout } from '../ui/catalog-recovery.js';
function node(tag, text, className = '') {
  return { tag, text, className, children: [], attributes: {}, append(...items) { this.children.push(...items); }, setAttribute(key, value) { this.attributes[key] = value; } };
}
const find = (root, match) => [root, ...root.children.flatMap((child) => find(child, match))].filter(match);
test('recovery UI shows counts and pagination and requires record review before removal', async () => {
  const removed = [], pages = [], exported = [];
  const record = { id: 'record', name: 'Saved suite', byteCount: 42, recordRevision: 'revision', canRemove: true };
  const panel = renderCatalogRecovery({ node, button: (text, onclick, cls, disabled) => Object.assign(node('button', text, cls), { onclick, disabled }),
    canDownload: true, data: { message: 'Size limit reached', catalogRecovery: { kind: 'suites', totalRecords: 30, records: [record], nextCursor: '25' } },
    onPage: (...args) => pages.push(args), onRetry: () => {}, onExport: (...args) => exported.push(args), onRemove: (...args) => removed.push(args) });
  assert.equal(panel.attributes['aria-label'], 'Catalog recovery');
  assert.ok(find(panel, (item) => item.text === 'suites: 30 saved records. Showing 1 on this page.').length);
  const remove = find(panel, (item) => item.text === 'Remove this saved record')[0]; assert.equal(remove.disabled, true);
  const checkbox = find(panel, (item) => item.type === 'checkbox')[0]; checkbox.checked = true; checkbox.onchange();
  assert.equal(remove.disabled, false); await remove.onclick(); assert.deepEqual(removed, [['suites', record]]);
  await find(panel, (item) => item.text === 'Next page')[0].onclick(); assert.deepEqual(pages, [['suites', '25']]);
  await find(panel, (item) => item.text === 'Export exact saved JSON')[0].onclick(); assert.deepEqual(exported, [['suites', record]]);
});
test('bounded recovery export preserves multibyte text across chunk boundaries and refuses stale/incomplete data', async () => {
  const text = JSON.stringify({ evidence: '😀'.repeat(70000) }); const bytes = Buffer.from(text);
  const record = { id: 'record', recordRevision: 'revision', byteCount: bytes.length }; let calls = 0;
  const read = async (_name, args) => {
    calls++; const chunk = bytes.subarray(args.offset, args.offset + args.bytes), next = args.offset + chunk.length;
    return { dataBase64: chunk.toString('base64'), totalBytes: bytes.length, nextOffset: next < bytes.length ? next : null, recordRevision: record.recordRevision, filename: 'saved.json' };
  };
  assert.deepEqual(await exportRecoveryRecord(read, 'suites', record), { filename: 'saved.json', text }); assert.equal(calls, 2);
  await assert.rejects(exportRecoveryRecord(async () => ({ dataBase64: '', totalBytes: bytes.length, recordRevision: 'changed', nextOffset: null }), 'suites', record), /changed/);
  await assert.rejects(exportRecoveryRecord(async () => ({ dataBase64: '', totalBytes: bytes.length, recordRevision: record.recordRevision, nextOffset: null }), 'suites', record), /Incomplete/);
});

test('successful recovery removal forgets selected records without dropping another suite draft', () => {
  const state = { draft: { id: 'removed' }, dirty: true, page: 'suites', run: { id: 'run' } };
  assert.equal(forgetRemovedRecoveryRecord(state, 'suites', 'other'), false);
  assert.equal(state.draft.id, 'removed'); assert.equal(state.dirty, true);
  assert.equal(forgetRemovedRecoveryRecord(state, 'suites', 'removed'), true);
  assert.equal(state.draft, null); assert.equal(state.dirty, false); assert.equal(state.page, 'overview');
  forgetRemovedRecoveryRecord(state, 'runs', 'run'); assert.equal(state.run, null);
});

test('recovery uses the full content grid and hides irrelevant navigation, then restores the normal layout and sidebar preference', async (t) => {
  const css = await readFile(new URL('../ui/react/layout.css', import.meta.url), 'utf8');
  const dom = new JSDOM(`<style>${css}</style><div class="app-shell"><aside id="workspace-sidebar"></aside><div class="content-shell"><header class="toolbar"><button id="sidebar-toggle"></button></header><main></main></div></div>`);
  t.after(() => dom.window.close());
  const { document } = dom.window, shell = document.querySelector('.app-shell');
  const normalGrid = dom.window.getComputedStyle(shell).gridTemplateColumns;
  assert.match(normalGrid, /240px/);
  document.body.classList.add('sidebar-open');
  setCatalogRecoveryLayout(document, true);
  assert.equal(dom.window.getComputedStyle(shell).gridTemplateColumns, 'minmax(0,1fr)');
  assert.equal(dom.window.getComputedStyle(document.querySelector('.content-shell')).gridColumn, '1 / -1');
  for (const selector of ['#workspace-sidebar', '#sidebar-toggle', '.toolbar']) assert.equal(dom.window.getComputedStyle(document.querySelector(selector)).display, 'none');
  assert.equal(document.getElementById('sidebar-toggle').hidden, true);
  setCatalogRecoveryLayout(document, false);
  assert.equal(dom.window.getComputedStyle(shell).gridTemplateColumns, normalGrid);
  assert.equal(dom.window.getComputedStyle(document.querySelector('.content-shell')).gridColumn, '');
  assert.equal(document.getElementById('sidebar-toggle').hidden, false);
  assert.equal(dom.window.getComputedStyle(document.querySelector('.toolbar')).display, 'flex');
  assert.equal(document.body.classList.contains('sidebar-open'), true);
  document.body.classList.add('sidebar-hidden');
  setCatalogRecoveryLayout(document, true); setCatalogRecoveryLayout(document, false);
  assert.equal(document.body.classList.contains('sidebar-hidden'), true);
  assert.equal(dom.window.getComputedStyle(shell).gridTemplateColumns, 'minmax(0,1fr)');
});

test('hosts without downloads show actionable MCP chunk export guidance without offering or fetching a download', () => {
  const exported = [], record = { id: 'saved-record', name: 'Saved suite', byteCount: 42, recordRevision: 'exact-revision', canRemove: true };
  const options = { node, button: (text, onclick, cls, disabled) => Object.assign(node('button', text, cls), { onclick, disabled }),
    data: { message: 'Size limit reached', catalogRecovery: { kind: 'suites', totalRecords: 1, records: [record], nextCursor: null } },
    onPage() {}, onRetry() {}, onRemove() {}, onExport: (...args) => exported.push(args) };
  for (const canDownload of [undefined, false]) {
    const panel = renderCatalogRecovery({ ...options, canDownload });
    assert.equal(find(panel, (item) => item.text === 'Export exact saved JSON').length, 0);
    assert.ok(find(panel, (item) => item.text?.includes('This host does not support file downloads.')).length);
    const instructions = find(panel, (item) => item.text?.startsWith('Start eval_catalog_export_chunk'))[0].text;
    assert.ok(instructions.includes(JSON.stringify({ kind: 'suites', recordId: record.id, recordRevision: record.recordRevision, offset: 0, bytes: 262144 })));
    assert.match(instructions, /nextOffset until it is null/);
    assert.equal(find(panel, (item) => item.text === 'Remove this saved record')[0].disabled, true);
  }
  assert.deepEqual(exported, []);
  const supported = renderCatalogRecovery({ ...options, canDownload: true });
  assert.equal(find(supported, (item) => item.text === 'Export exact saved JSON').length, 1);
  assert.equal(find(supported, (item) => item.text?.includes('This host does not support file downloads.')).length, 0);
});
