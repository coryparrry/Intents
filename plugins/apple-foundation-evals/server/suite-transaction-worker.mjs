import { Store } from './store.mjs';
import { createHash } from 'node:crypto';
import { unlink } from 'node:fs/promises';
import { revision } from './app-format.mjs';
import { MAX_OUTPUT_BYTES } from './validation.mjs';

// Runs only while lockf/flock holds this suite's kernel lock. A crashed caller
// cannot leave a live lock owner indefinitely, and this worker owns every write.
const timeout = setTimeout(() => process.exit(1), 8000);
try {
  process.stdin.setEncoding('utf8');
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk.toString();
    if (Buffer.byteLength(input) > MAX_OUTPUT_BYTES + 4096) throw new Error('Suite transaction input exceeds limit');
  }
  let { root, saved, expectedRevision, operation, projectId, expectedRecordRevision, kind = 'suites' } = JSON.parse(input);
  const store = new Store(root);
  let old, oldBytes;
  try { ({ value: old, bytes: oldBytes } = await store.readRecord(kind, saved.id)); }
  catch (error) { if (!/not found$/.test(error.message)) throw error; }
  if (expectedRecordRevision !== undefined && (!oldBytes || createHash('sha256').update(oldBytes).digest('hex') !== expectedRecordRevision)) throw new Error('Record changed; refresh catalog recovery before removing it');
  if (expectedRevision !== undefined && expectedRevision !== (old?.revision || (old ? revision(old) : undefined))) throw new Error('Suite revision conflict: reload the current suite before saving');
  if (operation === 'writeRecord') {
    await store.writeUnlocked(kind, saved);
  } else if (operation === 'deleteRecord') {
    if (!old) throw new Error('Record not found');
    await unlink(store.path(kind, saved.id)); saved = old;
  } else if (kind !== 'suites') {
    throw new Error('Suite operation requires a suite record');
  } else if (operation === 'migrate') {
    // Startup snapshots may be stale. Fill missing metadata on the latest record
    // under the lock; never restore deleted suites or overwrite an editor's save.
    saved = old ? { ...old, projectId: old.projectId || projectId, revision: old.revision || revision(old) } : null;
    if (saved && (!old.projectId || !old.revision)) await store.writeUnlocked('suites', saved);
  } else if (operation === 'delete') {
    if (!old) throw new Error('Suite not found');
    await unlink(store.path('suites', saved.id));
    saved = old;
  } else if (operation === 'restore') {
    if (typeof expectedRevision !== 'string') throw new Error('Suite restore requires an expected revision');
    await store.writeUnlocked('suites', saved);
  } else if (operation === 'save') {
    saved.revision = revision(saved);
    saved.updatedAt = saved.revision === old?.revision ? old.updatedAt : new Date().toISOString();
    await store.writeUnlocked('suites', saved);
  } else throw new Error('Unknown suite transaction');
  process.stdout.write(JSON.stringify({ suite: saved }));
} catch (error) {
  process.stdout.write(JSON.stringify({ error: error.message }));
  process.exitCode = 1;
} finally { clearTimeout(timeout); }
