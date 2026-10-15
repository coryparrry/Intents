import { randomUUID } from 'node:crypto';
function csv(text) {
  const rows = []; let row = []; let cell = ''; let quoted = false; let closed = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) { if (ch === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else { quoted = false; closed = true; } } else cell += ch; }
    else if (ch === '"') { if (cell || closed) throw new Error('Invalid CSV quoting'); quoted = true; }
    else if (ch === ',' || ch === '\n' || ch === '\r') {
      row.push(cell); cell = ''; closed = false;
      if (ch !== ',') { if (ch === '\r' && text[i + 1] === '\n') i++; rows.push(row); row = []; if (rows.length > 101) throw new Error('Case import exceeds 100 rows'); }
    } else { if (closed) throw new Error('Invalid CSV text after closing quote'); cell += ch; }
  }
  if (quoted) throw new Error('Unclosed CSV quote');
  if (cell || row.length || closed) { row.push(cell); rows.push(row); }
  const header = rows.shift()?.map((item) => item.trim());
  if (!header?.length || header.some((item) => !item) || new Set(header).size !== header.length) throw new Error('CSV requires unique non-empty column names');
  return rows.filter((row) => row.some((item) => item.trim())).map((row) => { if (row.length !== header.length) throw new Error('CSV row has incorrect column count'); return Object.fromEntries(header.map((name, index) => [name, row[index]])); });
}
export function importCases({ format, text, mapping }, appFormat) {
  if (typeof text !== 'string' || Buffer.byteLength(text) > 5000000) throw new Error('Case import exceeds the app 5 MB text file limit');
  if (!['json', 'jsonl', 'csv'].includes(format)) throw new Error('Unknown case import format');
  let rows;
  if (format === 'csv') rows = csv(text.replace(/^\uFEFF/, ''));
  else { try { rows = format === 'json' ? JSON.parse(text) : text.split(/\r?\n/).filter((line) => line.trim()).map((line) => JSON.parse(line)); } catch { throw new Error('Case import must contain valid JSON'); } }
  if (!Array.isArray(rows) || !rows.length || rows.length > 100) throw new Error('Case import requires 1 to 100 rows');
  const columns = { promptColumn: 'prompt', nameColumn: 'name', expectedColumn: 'expected', ...mapping };
  return rows.map((row, index) => {
    if (!row || typeof row !== 'object' || Array.isArray(row)) throw new Error('Each imported row must be an object');
    if (format !== 'json') for (const value of Object.values(row)) if (value !== null && typeof value !== 'string') throw new Error('CSV/JSONL columns must be strings or null');
    const prompt = row[columns.promptColumn]?.trim();
    if (!prompt) throw new Error(`Imported row ${index + 1} has an empty prompt`);
    if (mapping) for (const key of Object.values(mapping)) if (key && !(key in row)) throw new Error(`Missing mapped column ${key}`);
    const name = row[columns.nameColumn]?.trim() || `Imported case ${index + 1}`;
    const expected = row[columns.expectedColumn] ?? '';
    if (typeof expected !== 'string') throw new Error('Expected text must be a string');
    if (appFormat) return { ...(format === 'json' ? row : {}), id: row.id || randomUUID(), name, prompt, expected };
    return { id: row.id || randomUUID(), prompt, expected, scoring: row.scoring || 'none' };
  });
}
