// Recovery shows bounded metadata only; complete records remain on disk.
export function renderCatalogRecovery({ node, button, data, onPage, onRetry, onExport, onRemove }) {
  const panel = node('section', null, 'page catalog-recovery-page');
  panel.setAttribute('aria-label', 'Catalog recovery');
  panel.append(node('h1', 'Recover a large workspace'), node('p', data.message),
    node('p', 'All records remain saved. Export needed evidence, then explicitly remove records to reduce catalog size. Full editing resumes when the workspace fits its response limit.'));
  const page = data.catalogRecovery;
  panel.append(node('p', `${page.kind}: ${page.totalRecords} saved records. Showing ${page.records.length} on this page.`));
  const select = node('select');
  select.setAttribute('aria-label', 'Recovery catalog');
  for (const kind of ['suites', 'runs', 'experiments', 'baselines', 'corrections', 'projects']) {
    const option = node('option', kind); option.value = kind; option.selected = kind === page.kind; select.append(option);
  }
  select.onchange = () => onPage(select.value, '0');
  panel.append(select);
  for (const record of page.records) {
    const row = node('article', null, 'catalog-recovery-record');
    row.append(node('h2', record.name), node('p', `${record.id} · ${record.byteCount.toLocaleString()} bytes${record.status ? ` · ${record.status}` : ''}`));
    row.append(button('Export exact saved JSON', () => onExport(page.kind, record)));
    if (record.canRemove) {
      const label = node('label'), check = node('input'); check.type = 'checkbox';
      const remove = button('Remove this saved record', () => onRemove(page.kind, record), 'secondary', true);
      check.onchange = () => { remove.disabled = !check.checked; };
      label.append(check, node('span', 'I reviewed this record and preserved the evidence I need.'));
      row.append(label, remove);
    }
    panel.append(row);
  }
  const actions = node('div', null, 'actions catalog-recovery-actions');
  actions.append(button('First page', () => onPage(page.kind, '0')),
    button('Next page', () => onPage(page.kind, page.nextCursor), 'secondary', page.nextCursor === null),
    button('Reopen workspace', onRetry));
  panel.append(actions);
  return panel;
}

export async function exportRecoveryRecord(call, kind, record) {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let offset = 0, output = '', filename;
  // The store accepts at most 32 MiB per record: at most 128 normal chunks.
  for (let page = 0; page < 129; page++) {
    const chunk = await call('eval_catalog_export_chunk', { kind, recordId: record.id,
      recordRevision: record.recordRevision, offset, bytes: 262144 });
    if (chunk.totalBytes !== record.byteCount || chunk.totalBytes > 33554432 || chunk.recordRevision !== record.recordRevision) throw Error('Record changed during export; refresh recovery.');
    const bytes = Uint8Array.from(atob(chunk.dataBase64), (character) => character.charCodeAt(0));
    if (bytes.length > 262144 || offset + bytes.length > chunk.totalBytes) throw Error('Invalid recovery export chunk.');
    output += decoder.decode(bytes, { stream: chunk.nextOffset !== null }); filename = chunk.filename;
    if (chunk.nextOffset === null) {
      if (offset + bytes.length !== chunk.totalBytes) throw Error('Incomplete recovery export.');
      return { filename, text: output };
    }
    if (chunk.nextOffset !== offset + bytes.length || chunk.nextOffset <= offset) throw Error('Recovery export did not advance.');
    offset = chunk.nextOffset;
  }
  throw Error('Recovery export exceeded its record limit.');
}

export function forgetRemovedRecoveryRecord(state, kind, id) {
  if (kind === 'suites' && state.draft?.id === id) {
    state.draft = null; state.dirty = false; state.page = 'overview';
    return true;
  }
  if (kind === 'runs' && state.run?.id === id) {
    state.run = null; state.page = 'overview'; state.imported = false;
  }
  if (kind === 'experiments' && state.experiment?.id === id) return true;
  return false;
}

// Keep grid placement separate from the sidebar's user preference. Hiding a
// grid item alone would place the content shell in the former sidebar column.
export function setCatalogRecoveryLayout(document, recovering) {
  document.querySelector('.app-shell').classList.toggle('catalog-recovery', recovering);
  document.getElementById('sidebar-toggle').hidden = recovering;
}
