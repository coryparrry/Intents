import { mkdir, lstat, readFile, readdir, rename, unlink, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { id, MAX_OUTPUT_BYTES } from './validation.mjs';
import { acquireLease } from './lease.mjs';

export const dataDirectory = (env = process.env) => resolve(env.FOUNDATION_EVALS_PLUGIN_DATA || env.PLUGIN_DATA || join(homedir(), '.local/share/apple-foundation-evals'));
export const processAlive = (pid) => {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
};
export class Store {
  constructor(root = dataDirectory()) { this.root = resolve(root); this.leases = new Map(); }
  async init() {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    if ((await lstat(this.root)).isSymbolicLink()) throw new Error('Data directory must not be a symlink');
    for (const kind of ['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections']) {
      const path = join(this.root, kind);
      await mkdir(path, { recursive: true, mode: 0o700 });
      if ((await lstat(path)).isSymbolicLink()) throw new Error('Data subdirectories must not be symlinks');
    }
  }
  path(kind, key) {
    if (!['suites', 'runs', 'projects', 'experiments', 'baselines', 'corrections'].includes(kind)) throw new Error('Unknown store');
    return join(this.root, kind, `${id(key)}.json`);
  }
  async read(kind, key) {
    const path = this.path(kind, key);
    let stat;
    try { stat = await lstat(path); } catch (error) { if (error.code === 'ENOENT') throw new Error(`${kind === 'runs' ? 'Run' : kind === 'projects' ? 'Project' : kind === 'experiments' ? 'Experiment' : kind === 'baselines' ? 'Baseline' : kind === 'corrections' ? 'Correction' : 'Suite'} not found`); throw error; }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_OUTPUT_BYTES) throw new Error('Invalid stored record');
    const value = JSON.parse(await readFile(path, 'utf8'));
    if (value.id !== id(key)) throw new Error('Stored record id mismatch');
    return value;
  }
  async list(kind, project = (value) => value) {
    const names = await readdir(join(this.root, kind));
    if (names.length > 5000) throw new Error('Local history exceeds 5000 entries; archive old records');
    const results = [];
    let totalBytes = 0;
    for (const name of names) {
      if (!/^[0-9a-f-]+\.json$/i.test(name)) continue;
      const result = project(await this.read(kind, name.slice(0, -5)));
      totalBytes += Buffer.byteLength(JSON.stringify(result));
      if (totalBytes > MAX_OUTPUT_BYTES) throw new Error('Local catalog exceeds 32 MiB; archive old records');
      results.push(result);
    }
    return results;
  }
  async write(kind, value) {
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
  async delete(kind, key) {
    await this.read(kind, key);
    await unlink(this.path(kind, key));
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
