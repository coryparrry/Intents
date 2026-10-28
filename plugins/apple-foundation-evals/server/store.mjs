import { mkdir, lstat, readFile, readdir, rename, unlink, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { id, MAX_OUTPUT_BYTES } from './validation.mjs';
import { acquireLease } from './lease.mjs';
import { saveSuiteTransaction } from './suite-transaction.mjs';

/** Resolves the plugin data root from explicit plugin environment paths or the user-local default. */
export const dataDirectory = (env = process.env) => resolve(env.FOUNDATION_EVALS_PLUGIN_DATA || env.PLUGIN_DATA || join(homedir(), '.local/share/apple-foundation-evals'));
/** Checks a positive integer PID; permission-denied probes count as alive and other probe failures count as absent. */
export const processAlive = (pid) => {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
};
export class CatalogLimitError extends Error {
  /** Identifies the overflowing record catalog so callers can open bounded recovery instead of returning a partial list. */
  constructor(kind) { super('Local catalog exceeds 32 MiB; open catalog recovery to export or remove records.'); this.kind = kind; }
}
export class Store {
  /** Resolves the storage root and initializes this instance's run-to-lease ownership map. */
  constructor(root = dataDirectory()) { this.root = resolve(root); this.leases = new Map(); }
  /** Creates private record and transaction-lock directories, rejecting symlink roots and subdirectories. */
  async init() {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    if ((await lstat(this.root)).isSymbolicLink()) throw new Error('Data directory must not be a symlink');
    for (const kind of ['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections', '.suite-locks']) {
      const path = join(this.root, kind);
      await mkdir(path, { recursive: true, mode: 0o700 });
      if ((await lstat(path)).isSymbolicLink()) throw new Error('Data subdirectories must not be symlinks');
    }
  }
  /** Returns a UUID-qualified JSON record path after rejecting unknown catalogs and invalid identities. */
  path(kind, key) {
    if (!['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections'].includes(kind)) throw new Error('Unknown store');
    return join(this.root, kind, `${id(key)}.json`);
  }
  /** Reads a bounded regular JSON record, validates its stored identity, and returns both parsed content and exact bytes for revision checks. */
  async readRecord(kind, key) {
    const path = this.path(kind, key);
    let stat;
    try { stat = await lstat(path); } catch (error) { if (error.code === 'ENOENT') throw new Error(`${kind === 'runs' ? 'Run' : kind === 'projects' ? 'Project' : kind === 'experiments' ? 'Experiment' : kind === 'baselines' ? 'Baseline' : kind === 'corrections' ? 'Correction' : 'Suite'} not found`); throw error; }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_OUTPUT_BYTES) throw new Error('Invalid stored record');
    const bytes = await readFile(path);
    if (bytes.length > MAX_OUTPUT_BYTES) throw new Error('Invalid stored record');
    const value = JSON.parse(bytes.toString('utf8'));
    if (value.id !== id(key)) throw new Error('Stored record id mismatch');
    return { value, bytes };
  }
  /** Returns the validated parsed record while propagating missing, malformed, or oversized-record errors. */
  async read(kind, key) { return (await this.readRecord(kind, key)).value; }
  /** Returns a validated record or null only when its read reports a not-found error; malformed evidence and I/O failures still reject. */
  async readOptional(kind, key) {
    try { return await this.read(kind, key); } catch (error) { if (/not found$/.test(error.message)) return null; throw error; }
  }
  /** Returns sorted JSON record names and enforces the 5,000-record limit without counting in-flight atomic-write temporary files. */
  async recordNames(kind) {
    this.path(kind, '00000000-0000-4000-8000-000000000001');
    const names = (await readdir(join(this.root, kind))).filter((name) => /^[0-9a-f-]+\.json$/i.test(name));
    if (names.length > 5000) throw new Error('Local history exceeds 5000 entries; archive old records');
    return names.sort();
  }
  // Startup and recovery consume one validated record at a time. This does not
  // relax the existing per-record, directory-count or returned-payload limits.
  /** Yields one validated record at a time without constructing a full catalog payload. */
  async *scan(kind) {
    for (const name of await this.recordNames(kind)) yield await this.read(kind, name.slice(0, -5));
  }
  /** Projects scanned records and rejects serialized results exceeding 32 MiB instead of returning a truncated catalog. */
  async list(kind, project = (value) => value) {
    const results = [];
    let totalBytes = 2;
    for await (const value of this.scan(kind)) {
      const result = project(value);
      totalBytes += Buffer.byteLength(JSON.stringify(result)) + (results.length ? 1 : 0);
      if (totalBytes > MAX_OUTPUT_BYTES) throw new CatalogLimitError(kind);
      results.push(result);
    }
    return results;
  }
  /** Checks record size and delegates a create-only or revision-checked write to the per-record kernel-locked transaction worker. */
  async write(kind, value, { createOnly = false, expectedRevision } = {}) {
    this.path(kind, value.id);
    if (Buffer.byteLength(JSON.stringify(value)) > MAX_OUTPUT_BYTES) throw new Error('Record exceeds local storage limit');
    await saveSuiteTransaction(this, value, expectedRevision, { operation: createOnly ? 'createRecord' : 'writeRecord', kind });
  }
  // Only the kernel-locked transaction worker calls this mutation primitive.
  /** Atomically replaces a bounded record through a private temporary file; only a transaction worker holding the catalog and record locks may call this primitive. */
  async writeUnlocked(kind, value) {
    const path = this.path(kind, value.id);
    try { await lstat(path); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      if ((await readdir(join(this.root, kind))).filter((name) => name.endsWith('.json')).length >= 5000) throw new Error('Local history is full; delete or archive old records');
    }
    const contents = JSON.stringify(value);
    if (Buffer.byteLength(contents) > MAX_OUTPUT_BYTES) throw new Error('Record exceeds local storage limit');
    const temporary = `${path}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, contents, { flag: 'wx', mode: 0o600 });
      await rename(temporary, path);
    } finally { await unlink(temporary).catch(() => {}); }
  }
  /** Saves a suite under its record lock, checking an optional expected revision and updating definition revision metadata. */
  async saveSuite(value, expectedRevision) { return saveSuiteTransaction(this, value, expectedRevision); }
  /** Restores a prior suite snapshot only when the current suite still matches the required expected revision. */
  async restoreSuite(value, expectedRevision) {
    if (typeof expectedRevision !== 'string') throw new Error('Suite restore requires an expected revision');
    return saveSuiteTransaction(this, value, expectedRevision, { operation: 'restore' });
  }
  /** Fills missing suite ownership/revision from the latest locked record without recreating a deleted suite. */
  async migrateSuite(key, projectId) { return saveSuiteTransaction(this, { id: id(key) }, undefined, { operation: 'migrate', projectId: id(projectId) }); }
  /** Fills missing ownership and suite revision on the latest terminal run without replacing active or deleted evidence. */
  async migrateRun(key, projectId) { return saveSuiteTransaction(this, { id: id(key) }, undefined, { operation: 'migrateRun', kind: 'runs', projectId: id(projectId) }); }
  /** Deletes under the record lock with optional suite-definition and exact-byte revision guards. */
  async delete(kind, key, expectedRevision, expectedRecordRevision) {
    if (kind === 'suites') { await saveSuiteTransaction(this, { id: id(key) }, expectedRevision, { operation: 'delete', expectedRecordRevision }); return; }
    this.path(kind, key);
    await saveSuiteTransaction(this, { id: id(key) }, undefined, { operation: 'deleteRecord', kind, expectedRecordRevision });
  }
  /** Rejects local concurrent admission and acquires the cross-process inference lease associated with runId. */
  async acquireRunLock(runId) {
    if (this.leases.size) throw new Error('An evaluation is already active');
    const lease = await acquireLease(this.root);
    this.leases.set(runId, lease);
  }
  /** Returns this instance's guardian lease for an admitted run, or undefined when it owns no such lease. */
  lease(runId) { return this.leases.get(runId); }
  /** Waits for guardian and worker exit before removing the run's lease from local ownership. */
  async releaseRunLock(runId) {
    const lease = this.leases.get(runId);
    if (lease) { await lease.release(); this.leases.delete(runId); }
  }
}
