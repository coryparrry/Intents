import { mkdir, lstat, readFile, readdir, rename, unlink, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { id, MAX_OUTPUT_BYTES } from './validation.mjs';
import { acquireLease } from './lease.mjs';
import { saveSuiteTransaction } from './suite-transaction.mjs';

export const dataDirectory = (env = process.env) => resolve(env.FOUNDATION_EVALS_PLUGIN_DATA || env.PLUGIN_DATA || join(homedir(), '.local/share/apple-foundation-evals'));
export const processAlive = (pid) => {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
};
export class CatalogLimitError extends Error {
  constructor(kind) { super('Local catalog exceeds 32 MiB; open catalog recovery to export or remove records.'); this.kind = kind; }
}
export class Store {
  constructor(root = dataDirectory()) { this.root = resolve(root); this.leases = new Map(); }
  async init() {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    if ((await lstat(this.root)).isSymbolicLink()) throw new Error('Data directory must not be a symlink');
    for (const kind of ['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections', '.suite-locks']) {
      const path = join(this.root, kind);
      await mkdir(path, { recursive: true, mode: 0o700 });
      if ((await lstat(path)).isSymbolicLink()) throw new Error('Data subdirectories must not be symlinks');
    }
  }
  path(kind, key) {
    if (!['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections'].includes(kind)) throw new Error('Unknown store');
    return join(this.root, kind, `${id(key)}.json`);
  }
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
  async read(kind, key) { return (await this.readRecord(kind, key)).value; }
  async recordNames(kind) {
    this.path(kind, '00000000-0000-4000-8000-000000000001');
    const names = await readdir(join(this.root, kind));
    if (names.length > 5000) throw new Error('Local history exceeds 5000 entries; archive old records');
    return names.filter((name) => /^[0-9a-f-]+\.json$/i.test(name)).sort();
  }
  // Startup and recovery consume one validated record at a time. This does not
  // relax the existing per-record, directory-count or returned-payload limits.
  async *scan(kind) {
    for (const name of await this.recordNames(kind)) yield await this.read(kind, name.slice(0, -5));
  }
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
  async write(kind, value, { createOnly = false, expectedRevision } = {}) {
    this.path(kind, value.id);
    if (Buffer.byteLength(JSON.stringify(value)) > MAX_OUTPUT_BYTES) throw new Error('Record exceeds local storage limit');
    await saveSuiteTransaction(this, value, expectedRevision, { operation: createOnly ? 'createRecord' : 'writeRecord', kind });
  }
  // Only the kernel-locked transaction worker calls this mutation primitive.
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
  async saveSuite(value, expectedRevision) { return saveSuiteTransaction(this, value, expectedRevision); }
  async restoreSuite(value, expectedRevision) {
    if (typeof expectedRevision !== 'string') throw new Error('Suite restore requires an expected revision');
    return saveSuiteTransaction(this, value, expectedRevision, { operation: 'restore' });
  }
  async migrateSuite(key, projectId) { return saveSuiteTransaction(this, { id: id(key) }, undefined, { operation: 'migrate', projectId: id(projectId) }); }
  async delete(kind, key, expectedRevision, expectedRecordRevision) {
    if (kind === 'suites') { await saveSuiteTransaction(this, { id: id(key) }, expectedRevision, { operation: 'delete', expectedRecordRevision }); return; }
    this.path(kind, key);
    await saveSuiteTransaction(this, { id: id(key) }, undefined, { operation: 'deleteRecord', kind, expectedRecordRevision });
  }
  async acquireRunLock(runId) {
    if (this.leases.size) throw new Error('An evaluation is already active');
    const lease = await acquireLease(this.root);
    this.leases.set(runId, lease);
  }
  lease(runId) { return this.leases.get(runId); }
  async releaseRunLock(runId) {
    const lease = this.leases.get(runId);
    if (lease) { await lease.release(); this.leases.delete(runId); }
  }
}
