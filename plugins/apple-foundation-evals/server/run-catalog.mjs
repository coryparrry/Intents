import { lstat } from 'node:fs/promises';
import { MAX_OUTPUT_BYTES } from './validation.mjs';

/** Keeps bounded derived run metadata while revalidating filesystem identity on every catalog scan. */
export class RunCatalog {
  /** Retains the store and projection; raw responses and traces are never retained in the cache. */
  constructor(store, project) { this.store = store; this.project = project; this.cache = new Map(); this.cacheBytes = 0; }

  /** Rejects nonregular/oversized evidence and binds cached metadata to inode, size and both filesystem timestamps. */
  async fingerprint(key) {
    let stat;
    try { stat = await lstat(this.store.path('runs', key), { bigint: true }); }
    catch (error) { if (error.code === 'ENOENT') throw new Error('Run not found'); throw error; }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > BigInt(MAX_OUTPUT_BYTES)) throw new Error('Invalid stored record');
    return [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs].join(':');
  }

  /** Drops one stale projection and its accounted bytes. */
  forget(key) {
    const prior = this.cache.get(key);
    if (prior) { this.cacheBytes -= prior.bytes; this.cache.delete(key); }
  }

  /**
   * Yields current derived metadata, rereading changed evidence through the store's ordinary validation.
   * Timestamp-preserving edits still change ctime; records replaced during a read are deliberately not cached.
   */
  async *scan() {
    const names = await this.store.recordNames('runs'), keys = new Set(names.map(name => name.slice(0, -5)));
    for (const key of this.cache.keys()) if (!keys.has(key)) this.forget(key);
    for (const key of keys) {
      const before = await this.fingerprint(key), cached = this.cache.get(key);
      if (cached?.fingerprint === before) { yield cached.value; continue; }
      this.forget(key);
      const { value } = await this.store.readRecord('runs', key);
      const projected = this.project(value), after = await this.fingerprint(key);
      const bytes = Buffer.byteLength(JSON.stringify(projected));
      if (before === after && bytes <= MAX_OUTPUT_BYTES) {
        // Pathological metadata must not grow a process-wide cache beyond one response budget.
        if (this.cacheBytes + bytes > MAX_OUTPUT_BYTES) { this.cache.clear(); this.cacheBytes = 0; }
        this.cache.set(key, { fingerprint: after, value: projected, bytes }); this.cacheBytes += bytes;
      }
      yield projected;
    }
  }
}
