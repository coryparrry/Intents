import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Store } from '../server/store.mjs';
import { recoveryPage } from '../server/catalog-recovery.mjs';

/** Creates an isolated initialized store and removes its records and permanent locks after the test. */
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'catalog-capacity-'));
  const store = new Store(root); await store.init();
  t.after(() => rm(root, { recursive: true, force: true }));
  return store;
}

/** Populates valid project records in bounded filesystem batches without thousands of transaction subprocesses. */
async function seedProjects(store, count) {
  const projects = Array.from({ length: count }, (_, index) => ({ id: randomUUID(), name: `Project ${index}` }));
  for (let offset = 0; offset < projects.length; offset += 64) {
    await Promise.all(projects.slice(offset, offset + 64).map((project) => writeFile(store.path('projects', project.id), JSON.stringify(project))));
  }
  return projects;
}

/** Holds an existing kernel lock in a detached process group until test cleanup kills and reaps its owner. */
async function holdLock(t, path) {
  const executable = process.platform === 'darwin' ? '/usr/bin/lockf' : '/usr/bin/flock';
  const args = process.platform === 'darwin' ? ['-k', '-s', '-t', '1', path] : ['-w', '1', path];
  const child = spawn(executable, [...args, process.execPath, '-e', 'process.stdout.write("locked\\n"); setInterval(() => {}, 1000)'], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(async () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    const closed = once(child, 'close');
    try { process.kill(-child.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    await closed;
  });
  const [chunk] = await once(child.stdout, 'data');
  assert.equal(chunk.toString(), 'locked\n');
  return child;
}

test('distinct record creates share capacity admission and retain usable recovery at 5000 records', { timeout: 30000 }, async (t) => {
  const store = await fixture(t), existing = await seedProjects(store, 4999);
  const results = await Promise.allSettled(Array.from({ length: 2 }, (_, index) => new Store(store.root).write('projects', { id: randomUUID(), name: `Concurrent ${index}` })));
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
  for (const result of results.filter((result) => result.status === 'rejected')) assert.match(result.reason.message, /Local history is full/);
  assert.equal((await store.recordNames('projects')).length, 5000);
  assert.equal((await recoveryPage({ store }, 'projects')).totalRecords, 5000);

  // Replacing a record at capacity creates a temporary file, not another record.
  const transient = `${store.path('projects', existing[0].id)}.in-flight.tmp`;
  await writeFile(transient, 'pending atomic replacement');
  assert.equal((await store.recordNames('projects')).length, 5000);
  await store.write('projects', { ...existing[0], name: 'Updated at capacity' });
  assert.equal((await store.read('projects', existing[0].id)).name, 'Updated at capacity');
  await rm(transient);
  await store.delete('projects', existing[1].id);
  await store.write('projects', { id: randomUUID(), name: 'Replacement after removal' });
  assert.equal((await store.recordNames('projects')).length, 5000);

  // A real extra JSON record still trips the limit, even when its bytes are corrupt.
  const overflow = randomUUID();
  await writeFile(store.path('projects', overflow), '{invalid JSON');
  await assert.rejects(store.recordNames('projects'), /Local history exceeds 5000 entries/);
  await rm(store.path('projects', overflow));
  await writeFile(store.path('projects', existing[0].id), '{invalid JSON');
  const names = await store.recordNames('projects');
  assert.equal(names.length, 5000);
  assert.ok(names.includes(`${existing[0].id}.json`));
  await assert.rejects(store.readRecord('projects', existing[0].id), SyntaxError);
});

test('catalog lock contention is bounded and holder death preserves the same admission lock inode', { timeout: 20000 }, async (t) => {
  const store = await fixture(t), first = { id: randomUUID(), name: 'Original project' };
  await store.write('projects', first);
  const lock = join(store.root, '.suite-locks', 'catalog-projects.lock'), inode = (await stat(lock)).ino;
  const holder = await holdLock(t, lock), candidate = { id: randomUUID(), name: 'Blocked project' };
  await assert.rejects(store.write('projects', candidate), /transaction failed/);
  assert.deepEqual(await store.recordNames('projects'), [`${first.id}.json`]);
  assert.equal(await readFile(store.path('projects', first.id), 'utf8'), JSON.stringify(first));
  const closed = once(holder, 'close'); process.kill(-holder.pid, 'SIGKILL'); await closed;
  await store.write('projects', candidate);
  assert.equal((await stat(lock)).ino, inode);
  assert.deepEqual(await store.read('projects', candidate.id), candidate);
});
