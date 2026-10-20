import { createHash, randomUUID } from 'node:crypto';
import { id } from './validation.mjs';

export const RECOVERY_KINDS = ['suites', 'runs', 'experiments', 'baselines', 'corrections', 'projects'];
const removable = new Set(['suites', 'runs', 'experiments', 'baselines', 'corrections']);
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
const text = (value, maximum = 160) => typeof value === 'string' ? value.slice(0, maximum) : '';

export async function recoveryPage(app, kind, cursor = '0', limit = 25) {
  if (!RECOVERY_KINDS.includes(kind) || !/^(0|[1-9][0-9]{0,3})$/.test(cursor) || !Number.isInteger(limit) || limit < 1 || limit > 50) throw new Error('Invalid catalog recovery page');
  const names = await app.store.recordNames(kind);
  const offset = Number(cursor);
  if (offset > names.length) throw new Error('Catalog changed; restart recovery from the first page');
  const records = [];
  for (const name of names.slice(offset, offset + limit)) {
    const { value, bytes } = await app.store.readRecord(kind, name.slice(0, -5));
    let canRemove = removable.has(kind) && value.status !== 'running';
    if (canRemove) {
      try { await requirePublishedRun(app, kind, value); } catch { canRemove = false; }
    }
    records.push({ id: value.id, name: text(value.name || value.suiteName || value.id), status: text(value.status, 32),
      byteCount: bytes.length, recordRevision: digest(bytes), canRemove });
  }
  const next = offset + records.length;
  return { kind, records, totalRecords: names.length, nextCursor: next < names.length ? String(next) : null, pageLimit: limit };
}
export async function recoveryResponse(app, kind, message) {
  return { page: 'catalogRecovery', message, catalogRecovery: await recoveryPage(app, kind),
    recoveryTools: { list: 'eval_catalog_recovery', export: 'eval_catalog_export_chunk', remove: 'eval_catalog_remove' } };
}
export async function recoveryDispatch(app, name, args) {
  if (name === 'eval_catalog_recovery') return recoveryResponseForPage(app, args);
  if (!['eval_catalog_export_chunk', 'eval_catalog_remove'].includes(name)) return undefined;
  if (!RECOVERY_KINDS.includes(args.kind)) throw new Error('Unknown catalog');
  const key = id(args.recordId, 'recordId');
  if (name === 'eval_catalog_remove') {
    // Match native admission order: inference lease, then per-record transaction.
    // Saved status alone can be stale after another server updates an experiment.
    const lockId = randomUUID();
    await app.store.acquireRunLock(lockId);
    try { return await removeRecord(app, args, key); }
    finally { await app.store.releaseRunLock(lockId); }
  }
  const { bytes } = await app.store.readRecord(args.kind, key);
  if (digest(bytes) !== args.recordRevision) throw new Error('Record changed; refresh catalog recovery before exporting or removing it');
  if (name === 'eval_catalog_export_chunk') {
    const offset = args.offset ?? 0, count = args.bytes ?? 262144;
    if (!Number.isInteger(offset) || offset < 0 || offset > bytes.length || !Number.isInteger(count) || count < 1 || count > 262144) throw new Error('Invalid record chunk');
    const chunk = bytes.subarray(offset, offset + count), next = offset + chunk.length;
    return { dataBase64: chunk.toString('base64'), totalBytes: bytes.length, nextOffset: next < bytes.length ? next : null,
      recordRevision: args.recordRevision, filename: `${args.kind}-${key}.json` };
  }
}
async function removeRecord(app, args, key) {
  const { value, bytes } = await app.store.readRecord(args.kind, key);
  if (digest(bytes) !== args.recordRevision) throw new Error('Record changed; refresh catalog recovery before exporting or removing it');
  if (args.confirm !== true) throw new Error('Explicit confirmation is required to remove a record');
  if (!removable.has(args.kind)) throw new Error('Project records must be retained while they own local evidence');
  if (value.status === 'running' || app.active?.runId === key || app.active?.experimentId === key) throw new Error('Cancel active evidence before removing it');
  await requirePublishedRun(app, args.kind, value);
  if (args.kind === 'experiments') {
    for await (const run of app.store.scan('runs')) if (run.experimentId?.toLowerCase() === key) throw new Error('Export and remove the experiment’s dependent runs before removing its record');
  }
  await app.store.delete(args.kind, key, args.kind === 'suites' ? value.revision : undefined, args.recordRevision);
  return { deleted: true, kind: args.kind, recordId: key };
}
async function requirePublishedRun(app, kind, value) {
  if (kind !== 'runs' || value.publicationState !== 'pending') return;
  try {
    if (!value.experimentId) throw new Error('Missing experiment identity');
    await app.readPublicRun(value.id);
  } catch (cause) {
    throw new Error('Paired experiment evidence has not been committed. Export the saved bytes, then reopen the workspace after the experiment finishes or its interrupted evidence is recovered.', { cause });
  }
}
async function recoveryResponseForPage(app, args) {
  return { page: 'catalogRecovery', message: 'Records remain saved. Export needed evidence before explicitly removing records to reduce the workspace size.',
    catalogRecovery: await recoveryPage(app, args.kind, args.cursor ?? '0', args.limit ?? 25),
    recoveryTools: { list: 'eval_catalog_recovery', export: 'eval_catalog_export_chunk', remove: 'eval_catalog_remove' } };
}
